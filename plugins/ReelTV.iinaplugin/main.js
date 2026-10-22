//
// Reel TV — main entry.
//
// A zero-server TV library for Reel (the IINA fork). The plugin scans a local
// folder, groups video files into shows and episodes by their names, optionally
// decorates them with TMDB metadata, and plays them through the normal player.
// All state lives in the plugin's own data folder — no media server, no network
// service, and no media ever leaves this Mac except poster requests to TMDB.
//

const { console, core, event, file, http, menu, preferences, sidebar, mpv } = iina;

const DATA_LIBRARY = "@data/library.json";
const VIDEO_EXTS = new Set(["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "mpg", "mpeg", "wmv", "flv"]);
const MAX_SCAN_DEPTH = 3;
const MAX_SCAN_ENTRIES = 20000;
const SCAN_YIELD_BATCH = 400;
const MAX_TMDB_REQUESTS_PER_SCAN = 40;
const MAX_RESUME_RETRIES = 40;
const RESUME_RETRY_DELAY_MS = 250;
const MAX_RESUME_WAIT_MS = 120000;
const PLUGIN_IDENTIFIER = "com.tverma101.reel.tv";
const WATCHED_RATIO = 0.9;
const RESUME_MIN_RATIO = 0.02;

// --- Library state -----------------------------------------------------------

let library = { shows: [], root: "", scannedAt: 0 };
let progressPollTimer = null;
let scanGeneration = 0;
let pendingResume = null;
const dirtyProgressPaths = new Set();
const progressJournal = new Map();

function joinPath(parent, child) {
  const left = String(parent || "").replace(/\/+$/, "");
  const right = String(child || "").replace(/^\/+/, "");
  return (left || "") + "/" + right;
}

function progressFilePath(path) {
  let first = 2166136261;
  let second = 0x9e3779b9;
  for (let index = 0; index < path.length; index += 1) {
    const code = path.charCodeAt(index);
    first = Math.imul(first ^ code, 16777619);
    second = Math.imul(second ^ (code + index), 2246822519);
  }
  const suffix = (first >>> 0).toString(16).padStart(8, "0") +
    (second >>> 0).toString(16).padStart(8, "0");
  return "@data/reel-tv-progress-" + suffix + ".json";
}

function safePoster(path) {
  if (typeof path === "string" &&
      /^https:\/\/image\.tmdb\.org\/t\/p\/w300\/[A-Za-z0-9._/-]+$/.test(path) &&
      !path.includes("..")) return path;
  if (typeof path !== "string" || !/^\/[A-Za-z0-9._/-]+$/.test(path) || path.includes("..")) return "";
  return "https://image.tmdb.org/t/p/w300" + path;
}

function normalizeLibrary(value) {
  if (!value || typeof value !== "object" || !Array.isArray(value.shows)) {
    throw new Error("library must contain a shows array");
  }
  const shows = [];
  for (const raw of value.shows) {
    if (!raw || typeof raw !== "object" || typeof raw.name !== "string" || !Array.isArray(raw.episodes)) continue;
    const episodes = raw.episodes.filter((ep) => ep && typeof ep === "object" &&
      typeof ep.path === "string" && typeof ep.file === "string").map((ep) => ({
      path: ep.path,
      file: ep.file,
      season: Number.isInteger(ep.season) && ep.season >= 0 ? ep.season : 0,
      episode: Number.isInteger(ep.episode) && ep.episode >= 0 ? ep.episode : 0,
      progress: Number.isFinite(ep.progress) ? Math.max(0, Math.min(1, ep.progress)) : 0,
      lastPlayed: Number.isFinite(ep.lastPlayed) ? Math.max(0, ep.lastPlayed) : 0,
      watched: ep.watched === true,
      title: typeof ep.title === "string" ? ep.title : ep.file.replace(/\.[^.]+$/, ""),
    }));
    shows.push({
      name: raw.name,
      key: typeof raw.key === "string" ? raw.key : raw.name,
      episodes,
      tmdbId: Number.isInteger(raw.tmdbId) && raw.tmdbId > 0 ? raw.tmdbId : 0,
      poster: safePoster(raw.poster) || "",
      overview: typeof raw.overview === "string" ? raw.overview : "",
      year: typeof raw.year === "string" ? raw.year : "",
    });
  }
  return {
    shows,
    root: typeof value.root === "string" ? value.root : "",
    scannedAt: Number.isFinite(value.scannedAt) ? Math.max(0, value.scannedAt) : 0,
  };
}

function configuredTVFolder() {
  return String(preferences.get("tvFolder") || "").trim();
}

function tvFolder() {
  const folder = configuredTVFolder();
  // The host expands `~/` for file access, but status URLs use absolute paths.
  // Store one spelling so episode lookup and progress tracking agree.
  if (folder === "~" || folder.startsWith("~/")) return "";
  return folder.replace(/\/+$/, "");
}

function tmdbKey() {
  return String(preferences.get("tmdbKey") || "").trim();
}

function loadData() {
  const messages = [];
  file.withDataLock(() => {
    try {
      if (file.exists(DATA_LIBRARY)) {
        library = normalizeLibrary(JSON.parse(file.read(DATA_LIBRARY, {})));
      }
    } catch (e) {
      messages.push("Reel TV: could not read library data: " + e);
      library = { shows: [], root: "", scannedAt: 0 };
    }
    loadProgressJournal();
    applyProgressJournal();
  });
  messages.forEach((message) => console.log(message));
}

function applyProgressJournal(target = library) {
  for (const show of target.shows) {
    for (const episode of show.episodes) {
      const saved = progressJournal.get(episode.path);
      if (!saved) continue;
      episode.progress = saved.progress;
      episode.lastPlayed = saved.lastPlayed;
      episode.watched = saved.watched;
    }
  }
}

function loadProgressJournal() {
  progressJournal.clear();
  // Read only deterministic journal names for the current library. Listing @data would grow
  // without bound as users switch between folders over time.
  for (const show of library.shows) {
    for (const episode of show.episodes) readEpisodeProgress(episode.path);
  }
}

function readEpisodeProgress(path) {
  return file.withDataLock(() => {
    const storagePath = progressFilePath(path);
    try {
      if (!file.exists(storagePath)) return progressJournal.get(path) || null;
      const saved = JSON.parse(file.read(storagePath, {}));
      if (!saved || saved.path !== path || !Number.isFinite(saved.progress) ||
          !Number.isFinite(saved.lastPlayed)) return null;
      const record = {
        progress: Math.max(0, Math.min(1, saved.progress)),
        lastPlayed: Math.max(0, saved.lastPlayed),
        watched: saved.watched === true,
      };
      progressJournal.set(path, record);
      return record;
    } catch (e) {
      return progressJournal.get(path) || null;
    }
  });
}

function saveData({ snapshot = true } = {}) {
  const messages = [];
  file.withDataLock(() => {
    try {
      for (const path of dirtyProgressPaths) {
        const found = findEpisode(path);
        if (!found) continue;
        const record = {
          path,
          progress: found.ep.progress,
          lastPlayed: found.ep.lastPlayed,
          watched: found.ep.watched,
        };
        const latest = readEpisodeProgress(path);
        if (latest && latest.lastPlayed >= record.lastPlayed) {
          found.ep.progress = latest.progress;
          found.ep.lastPlayed = latest.lastPlayed;
          found.ep.watched = latest.watched;
          progressJournal.set(path, latest);
        } else {
          file.write(progressFilePath(path), JSON.stringify(record));
          progressJournal.set(path, record);
        }
      }
      if (!snapshot) {
        dirtyProgressPaths.clear();
        return;
      }

      // Player contexts share @data. Keep the read, merge and write in one host-side transaction
      // so another window cannot publish a stale snapshot between these steps.
      let saved = null;
      if (file.exists(DATA_LIBRARY)) {
        try {
          saved = normalizeLibrary(JSON.parse(file.read(DATA_LIBRARY, {})));
        } catch (e) {
          // loadData recovers to an empty library. Let the next complete save repair malformed JSON
          // instead of failing while trying to merge the same unreadable file.
          messages.push("Reel TV: repairing unreadable library data: " + e);
        }
      }
      let writeSnapshot = true;
      if (saved && saved.scannedAt > library.scannedAt) {
        library = saved;
        applyProgressJournal();
        writeSnapshot = false;
      } else if (saved) {
        const savedEpisodes = new Map();
        const savedShows = new Map();
        for (const show of saved.shows) {
          savedShows.set(show.key, show);
          for (const episode of show.episodes) savedEpisodes.set(episode.path, episode);
        }
        for (const show of library.shows) {
          const savedShow = savedShows.get(show.key);
          if (savedShow) {
            show.tmdbId = show.tmdbId || savedShow.tmdbId;
            show.poster = show.poster || savedShow.poster;
            show.overview = show.overview || savedShow.overview;
            show.year = show.year || savedShow.year;
          }
          for (const episode of show.episodes) {
            const previous = savedEpisodes.get(episode.path);
            if (previous && !dirtyProgressPaths.has(episode.path)) {
              episode.progress = previous.progress;
              episode.lastPlayed = previous.lastPlayed;
              episode.watched = previous.watched;
            }
            const journal = progressJournal.get(episode.path);
            if (journal && (!previous || journal.lastPlayed >= previous.lastPlayed) &&
                !dirtyProgressPaths.has(episode.path)) {
              episode.progress = journal.progress;
              episode.lastPlayed = journal.lastPlayed;
              episode.watched = journal.watched;
            }
            if (previous && episode.title === episode.file.replace(/\.[^.]+$/, "")) {
              episode.title = previous.title;
            }
          }
        }
        library.scannedAt = Math.max(library.scannedAt, saved.scannedAt);
      }
      if (writeSnapshot) file.write(DATA_LIBRARY, JSON.stringify(library));
      dirtyProgressPaths.clear();
    } catch (e) {
      messages.push("Reel TV: could not save library data: " + e);
    }
  });
  messages.forEach((message) => console.log(message));
}

// --- Episode name parsing ----------------------------------------------------

// Matches S01E02 (including multi-episode S01E02E03), 1x02, and dotted or
// hyphenated spellings. Returns { season, episode } or null.
function parseEpisodeMarker(name) {
  let m = name.match(/\bs(\d{1,2})[\.\-\s]?e(\d{1,3})(?:[\.\-\s]?e(\d{1,3}))?\b/i);
  if (m) return { season: parseInt(m[1], 10), episode: parseInt(m[2], 10) };
  m = name.match(/\b(\d{1,2})x(\d{1,3})\b/i);
  if (m) return { season: parseInt(m[1], 10), episode: parseInt(m[2], 10) };
  return null;
}

function prettyName(raw) {
  return raw
    .replace(/[._]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/[\(\[\{].*?[\)\]\}]/g, "")
    .replace(/\b(720p|1080p|2160p|4k|webrip|webdl|web|hdtv|bluray|bdrip|x264|x265|hevc|h264)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim() || raw;
}

// Show name: prefer the enclosing folder name; fall back to the leading part of
// the filename before the episode marker.
function showNameFor(relSegments, fileName) {
  if (relSegments.length > 1) return prettyName(relSegments[0]);
  const stem = fileName.replace(/\.[^.]+$/, "");
  const m = stem.match(/^(.*?)\s*[\.\-\s]?\b(s\d{1,2}[\.\-\s]?e\d{1,3}|\d{1,2}x\d{1,3})\b/i);
  return prettyName(m ? m[1] : stem);
}

// --- Scanning ----------------------------------------------------------------

async function scanFolder() {
  const generation = ++scanGeneration;
  const scanStartedAt = Date.now();
  loadProgressJournal();
  for (const show of library.shows) {
    for (const episode of show.episodes) {
      const saved = progressJournal.get(episode.path);
      if (!saved) continue;
      episode.progress = saved.progress;
      episode.lastPlayed = saved.lastPlayed;
      episode.watched = saved.watched;
    }
  }
  const configuredRoot = configuredTVFolder();
  const root = tvFolder();
  if (configuredRoot === "~" || configuredRoot.startsWith("~/")) {
    sidebar.postMessage("error", "Use the full folder path (for example /Users/you/TV); Reel TV cannot track paths entered as ~/TV.");
    return;
  }
  if (!root || !file.exists(root)) {
    sidebar.postMessage("error", "Set your TV shows folder in the plugin settings first.");
    return;
  }
  const shows = new Map();
  const queue = [{ path: root, segments: [], depth: 0 }];
  let queueIndex = 0;
  let scannedEntries = 0;
  let scanIncomplete = false;
  while (queueIndex < queue.length) {
    const { path, segments, depth } = queue[queueIndex++];
    let entries;
    try {
      // `limit` makes the host stop enumerating a huge single directory before building a
      // complete JavaScript array. Request one sentinel entry to detect the plugin's total cap.
      entries = file.list(path, { limit: MAX_SCAN_ENTRIES + 1 });
    } catch (e) {
      scanIncomplete = true;
      continue;
    }
    if (!Array.isArray(entries)) {
      scanIncomplete = true;
      continue;
    }
    for (const entry of entries) {
      scannedEntries += 1;
      if (scannedEntries > MAX_SCAN_ENTRIES) {
        if (generation === scanGeneration) {
          sidebar.postMessage("error", "This folder has more than 20,000 entries. Narrow the TV folder and rescan.");
        }
        return;
      }
      if (scannedEntries % SCAN_YIELD_BATCH === 0) {
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (generation !== scanGeneration) return;
      }
      if (entry.filename.startsWith(".")) continue;
      const childSegments = segments.concat(entry.filename);
      const childPath = joinPath(path, entry.path || entry.filename);
      if (entry.isDir) {
        if (depth < MAX_SCAN_DEPTH) queue.push({ path: childPath, segments: childSegments, depth: depth + 1 });
        continue;
      }
      const ext = entry.filename.split(".").pop().toLowerCase();
      if (!VIDEO_EXTS.has(ext)) continue;
      const marker = parseEpisodeMarker(entry.filename);
      if (!marker) continue;
      const name = showNameFor(childSegments, entry.filename);
      // Keep the relative segments so two folders with the same show name stay distinct.
      const key = childSegments.length > 1 ? childSegments[0] : name;
      const showKey = name + "\u0000" + key;
      let show = shows.get(showKey);
      if (!show) {
        show = { name, key, episodes: [] };
        shows.set(showKey, show);
      }
      show.episodes.push({
        path: childPath,
        file: entry.filename,
        season: marker.season,
        episode: marker.episode,
      });
    }
  }
  if (generation !== scanGeneration) return;
  if (scanIncomplete) {
    sidebar.postMessage("error", "Some folders could not be read. The previous library was kept.");
    return;
  }
  const previous = new Map();
  const previousShows = new Map();
  for (const old of library.shows || []) {
    previousShows.set(old.key, old);
    for (const ep of old.episodes || []) previous.set(ep.path, ep);
  }
  library.shows = [...shows.values()].map((show) => {
    const oldShow = previousShows.get(show.key);
    show.episodes.sort((a, b) => a.season - b.season || a.episode - b.episode);
    show.episodes = show.episodes.map((ep) => {
      const old = previous.get(ep.path);
      const journal = progressJournal.get(ep.path) || readEpisodeProgress(ep.path);
      return Object.assign(ep, {
        progress: old ? old.progress : journal ? journal.progress : 0,
        lastPlayed: old ? old.lastPlayed : journal ? journal.lastPlayed : 0,
        watched: old ? old.watched : journal ? journal.watched : false,
        title: old && old.title ? old.title : ep.file.replace(/\.[^.]+$/, ""),
      });
    });
    show.tmdbId = oldShow ? oldShow.tmdbId : 0;
    show.poster = oldShow ? oldShow.poster : "";
    show.overview = oldShow ? oldShow.overview : "";
    show.year = oldShow ? oldShow.year : "";
    return show;
  });
  const currentPaths = new Set(library.shows.flatMap((show) => show.episodes.map((episode) => episode.path)));
  for (const path of progressJournal.keys()) {
    if (!currentPaths.has(path)) progressJournal.delete(path);
  }
  library.shows.sort((a, b) => a.name.localeCompare(b.name));
  library.root = root;
  library.scannedAt = scanStartedAt;
  saveData();
  console.log("Reel TV: found " + library.shows.length + " shows");
  pushLibrary();
  fetchMetadataForMissing(generation).then(() => {
    if (generation === scanGeneration) pushLibrary();
  });
}

// --- TMDB (optional; the library works fully without it) ----------------------

async function tmdbGet(path, params) {
  const key = tmdbKey();
  if (!key) return null;
  try {
    const res = await http.get("https://api.themoviedb.org/3" + path, {
      params: Object.assign({ api_key: key, language: String(preferences.get("tmdbLanguage") || "en-US") }, params || {}),
    });
    const body = res.data || JSON.parse(res.text || "{}");
    return body.success === false ? null : body;
  } catch (e) {
    console.log("Reel TV: TMDB request failed: " + e);
    return null;
  }
}

async function fetchMetadataForMissing(generation) {
  if (!tmdbKey()) return;
  let requestBudget = MAX_TMDB_REQUESTS_PER_SCAN;
  for (const candidate of [...library.shows]) {
    if (generation !== scanGeneration) return;
    if (requestBudget <= 0) break;
    let show = library.shows.find((item) => item.key === candidate.key);
    if (!show) continue;
    if (show.tmdbId) continue;
    requestBudget -= 1;
    const search = await tmdbGet("/search/tv", { query: show.name });
    if (generation !== scanGeneration) return;
    const hit = search && Array.isArray(search.results) ? search.results.find((item) =>
      item && Number.isInteger(item.id) && item.id > 0) : null;
    if (!hit) continue;
    show = library.shows.find((item) => item.key === candidate.key);
    if (!show) continue;
    show.tmdbId = hit.id;
    show.poster = safePoster(hit.poster_path);
    show.overview = typeof hit.overview === "string" ? hit.overview : "";
    show.year = (hit.first_air_date || "").slice(0, 4);
    // Episode titles for seasons we actually have.
    const seasons = [...new Set(show.episodes.map((e) => e.season))];
    for (const seasonNumber of seasons.slice(0, 10)) {
      if (requestBudget <= 0) break;
      requestBudget -= 1;
      const season = await tmdbGet("/tv/" + hit.id + "/season/" + seasonNumber);
      if (generation !== scanGeneration) return;
      if (!season || !Array.isArray(season.episodes)) continue;
      for (const ep of show.episodes.filter((e) => e.season === seasonNumber)) {
        const meta = season.episodes.find((x) => x.episode_number === ep.episode);
        if (meta && meta.name) ep.title = meta.name;
      }
    }
    saveData();
  }
}

// --- Playback tracking ---------------------------------------------------------

function currentEpisodePath() {
  try {
    const url = core.status.url || "";
    if (/^file:\/\//i.test(url)) {
      return url.replace(/^file:\/\/(?:localhost)?/i, "");
    }
    return url;
  } catch (e) {
    return "";
  }
}

function findEpisode(path) {
  for (const show of library.shows) {
    const ep = show.episodes.find((e) => e.path === path);
    if (ep) return { show, ep };
  }
  return null;
}

function recordProgress(path = currentEpisodePath()) {
  if (!path) return;
  if (pendingResume && pendingResume.path === path) return;
  const found = findEpisode(path);
  if (!found) return;
  let position = 0;
  let duration = 0;
  try {
    position = mpv.getNumber("time-pos") || 0;
    duration = mpv.getNumber("duration") || 0;
  } catch (e) {
    return;
  }
  if (!duration) return;
  const ratio = position / duration;
  const { show, ep } = found;
  ep.progress = ratio;
  ep.lastPlayed = Math.max(Date.now(), ep.lastPlayed + 1);
  dirtyProgressPaths.add(path);
  const justFinished = !ep.watched && ratio >= WATCHED_RATIO;
  if (justFinished) ep.watched = true;
  saveData({ snapshot: false });
  sidebar.postMessage("progress", { path: ep.path, progress: ratio, watched: ep.watched });
  if (justFinished) core.osd(show.name + " S" + ep.season + "E" + ep.episode + " — finished");
}

function stopPolling() {
  if (progressPollTimer) clearInterval(progressPollTimer);
  progressPollTimer = null;
}

function startPolling() {
  stopPolling();
  progressPollTimer = setInterval(() => {
    const path = currentEpisodePath();
    if (!findEpisode(path)) {
      stopPolling();
      return;
    }
    recordProgress(path);
  }, 15000);
}

function applyPendingResume(path) {
  const resume = pendingResume;
  if (!resume || resume.path !== path || resume.retryScheduled) return false;
  if (!Number.isFinite(resume.deadline)) resume.deadline = Date.now() + MAX_RESUME_WAIT_MS;
  if (currentEpisodePath() !== path) {
    pendingResume = null;
    return false;
  }
  try {
    const duration = mpv.getNumber("duration") || 0;
    if (Number.isFinite(duration) && duration > 0) {
      // Clear first because setting time-pos may itself produce mpv.seek.
      pendingResume = null;
      mpv.set("time-pos", resume.progress * duration);
      return true;
    }
  } catch (e) {}
  const remaining = resume.deadline - Date.now();
  if (remaining <= 0) {
    // Do not seek far into a file after playback has already continued without a usable duration.
    // The ordinary progress poll can record the current position once mpv exposes duration.
    pendingResume = null;
    return false;
  }
  const retryDelay = Math.min(
    resume.attempts < MAX_RESUME_RETRIES ? RESUME_RETRY_DELAY_MS : 15000,
    remaining
  );
  resume.attempts += 1;
  resume.waitingForDuration = true;
  resume.retryScheduled = true;
  setTimeout(() => {
    if (pendingResume !== resume) return;
    resume.retryScheduled = false;
    applyPendingResume(path);
  }, retryDelay);
  return false;
}

function playEpisode(showKey, path, fromStart) {
  const show = library.shows.find((s) => s.key === showKey || s.name === showKey);
  if (!show) return;
  const ep = show.episodes.find((e) => e.path === path) || show.episodes[0];
  if (!ep) return;
  const journal = readEpisodeProgress(ep.path);
  if (journal) {
    ep.progress = journal.progress;
    ep.lastPlayed = journal.lastPlayed;
    ep.watched = journal.watched;
  }
  const resumeProgress = ep.progress;
  pendingResume = !fromStart && resumeProgress > RESUME_MIN_RATIO && resumeProgress < WATCHED_RATIO
    ? { path: ep.path, progress: resumeProgress, attempts: 0, retryScheduled: false } : null;
  core.open(ep.path);
  ep.lastPlayed = Date.now();
  dirtyProgressPaths.add(ep.path);
  saveData({ snapshot: false });
}

function nextUnwatched(show) {
  const inProgress = show.episodes.find(
    (e) => !e.watched && e.progress > RESUME_MIN_RATIO && e.progress < WATCHED_RATIO
  );
  if (inProgress) return inProgress;
  return show.episodes.find((e) => !e.watched) || null;
}

// --- Sidebar wiring --------------------------------------------------------------

function pushLibrary() {
  sidebar.postMessage("library", {
    shows: library.shows,
    continueWatching: library.shows
      .flatMap((s) => s.episodes.filter((e) => !e.watched && e.progress > RESUME_MIN_RATIO).map((e) => ({ show: s.name, key: s.key, ep: e })))
      .sort((a, b) => b.ep.lastPlayed - a.ep.lastPlayed)
      .slice(0, 12),
    recentlyPlayed: library.shows
      .flatMap((s) => s.episodes.filter((e) => e.lastPlayed > 0)
        .map((e) => ({ show: s.name, key: s.key, ep: e })))
      .sort((a, b) => b.ep.lastPlayed - a.ep.lastPlayed)
      .slice(0, 12),
  });
}

sidebar.onMessage("ready", () => pushLibrary());
sidebar.onMessage("play", (data) => playEpisode(data.key, data.path, false));
sidebar.onMessage("playFromStart", (data) => playEpisode(data.key, data.path, true));
sidebar.onMessage("refresh", () => scanFolder());
sidebar.onMessage("reveal", (data) => file.showInFinder(data.path));

// --- Menu -------------------------------------------------------------------

menu.addItem(
  menu.item("Reel TV: Rescan Library", () => {
    core.osd("Reel TV: rescanning…");
    scanFolder();
  })
);

const playNext = menu.item("Reel TV: Play Next Unwatched", () => {
  for (const show of library.shows) {
    const ep = nextUnwatched(show);
    if (ep) {
      playEpisode(show.key, ep.path, ep.progress <= RESUME_MIN_RATIO);
      return;
    }
  }
  core.osd("Reel TV: nothing left unwatched");
});
menu.addItem(playNext);

// --- Events and start --------------------------------------------------------

event.on("iina.file-loaded", (url) => {
  stopPolling();
  const path = currentEpisodePath();
  if (pendingResume && pendingResume.path !== path) pendingResume = null;
  if (!findEpisode(path)) return;
  if (pendingResume && pendingResume.path === path) {
    applyPendingResume(path);
  } else {
    recordProgress(path);
  }
  startPolling();
});

event.on("mpv.seek", () => {
  // A user seek while duration is still resolving takes precedence over the saved resume point.
  if (pendingResume && pendingResume.waitingForDuration && currentEpisodePath() === pendingResume.path) {
    pendingResume = null;
  }
});

event.on("mpv.end-file", () => {
  recordProgress();
  stopPolling();
});

event.on("iina.plugin-will-unload", (identifier) => {
  if (identifier !== PLUGIN_IDENTIFIER) return;
  // A pending resume suppresses ordinary progress polls until its seek resolves. On unload,
  // record any valid position and duration mpv has exposed so far.
  pendingResume = null;
  recordProgress();
  scanGeneration += 1;
  stopPolling();
});

loadData();
if (tvFolder() && file.exists(tvFolder())) scanFolder();
