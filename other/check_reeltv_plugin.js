const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "plugins/ReelTV.iinaplugin/main.js"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "plugins/ReelTV.iinaplugin/Info.json"), "utf8"));
const hostFileSource = fs.readFileSync(path.join(root, "iina/JavascriptAPIFile.swift"), "utf8");
assert.ok(hostFileSource.includes("errorHandler: { _, _ in") &&
  hostFileSource.includes("enumerationFailed = true") && hostFileSource.includes("return enumerationFailed ? nil : entries"),
  "a capped host listing reports filesystem enumeration failures instead of returning partial results");

function runPlugin({ tree, savedData = null, savedDataFiles = {}, sharedLibraryStore = null,
  preferences = {}, httpGet = null }) {
  const handlers = {};
  const events = {};
  const messages = [];
  const timers = [];
  const writes = [];
  const clearedIntervals = [];
  const tmdbCalls = [];
  const listCalls = [];
  const clock = { now: 1000000 };
  class TestDate extends Date {
    static now() { return clock.now; }
  }
  const libraryStore = sharedLibraryStore || { data: savedData };
  const output = { dataFiles: savedDataFiles };
  Object.defineProperty(output, "data", {
    get() { return libraryStore.data; },
    set(value) { libraryStore.data = value; },
  });
  const preferenceValues = Object.assign({ tvFolder: "/Shows" }, preferences);
  const state = { url: "", position: 0, duration: 100, opened: [], mpvSets: [] };
  const iina = {
    console: { log() {} },
    core: {
      status: state,
      open(filePath) {
        state.opened.push(filePath);
        state.url = "file://" + filePath;
      },
      osd() {},
    },
    event: { on(name, callback) { events[name] = callback; } },
    file: {
      exists(filePath) {
        return filePath === "/Shows" ||
          (filePath === "@data/library.json" && output.data !== null) ||
          Object.hasOwn(output.dataFiles, filePath);
      },
      list(filePath, options = {}) {
        listCalls.push({ filePath, options });
        if (filePath === "@data/") {
          return Object.keys(output.dataFiles).map((storedPath) => ({
            filename: storedPath.split("/").pop(),
            path: "/" + storedPath.split("/").pop(),
            isDir: false,
          }));
        }
        if (!Object.hasOwn(tree, filePath)) return null;
        const entries = tree[filePath];
        return Number.isInteger(options.limit) ? entries.slice(0, options.limit) : entries;
      },
      read(filePath, options) {
        assert.equal(Object.keys(options).length, 0);
        if (filePath === "@data/library.json") return output.data;
        return output.dataFiles[filePath];
      },
      write(filePath, data) {
        if (filePath === "@data/library.json") output.data = data;
        else output.dataFiles[filePath] = data;
        writes.push(data);
      },
      showInFinder() {},
    },
    http: { async get(url, options) {
      tmdbCalls.push({ url, options });
      if (httpGet) return httpGet(url, options);
      return { data: { results: [] } };
    } },
    menu: { addItem() {}, item(_name, callback) { return callback; } },
    preferences: { get(name) { return preferenceValues[name] || ""; } },
    sidebar: {
      postMessage(name, data) { messages.push({ name, data }); },
      onMessage(name, callback) { handlers[name] = callback; },
    },
    mpv: {
      getNumber(name) { return name === "duration" ? state.duration : state.position; },
      set(name, value) { state.mpvSets.push([name, value]); },
    },
  };
  const sandbox = {
    iina,
    Date: TestDate,
    console: { log() {} },
    setTimeout(callback, delay) {
      if (delay === 0) callback();
      else timers.push(callback);
      return timers.length;
    },
    setInterval() { return 1; },
    clearInterval(value) { clearedIntervals.push(value); },
  };
  vm.runInNewContext(source, sandbox, { filename: "ReelTV/main.js" });
  return { handlers, events, messages, timers, writes, clearedIntervals, tmdbCalls, listCalls, output, state,
    clock, preferenceValues, libraryStore };
}

function journalFor(plugin, episodePath) {
  return Object.values(plugin.output.dataFiles)
    .map((value) => JSON.parse(value))
    .find((record) => record.path === episodePath) || null;
}

async function runChecks() {
  await new Promise(setImmediate);
  assert.deepEqual(manifest.permissions.sort(), ["file-system", "network-request", "show-osd"]);
  assert.deepEqual(manifest.allowedDomains.sort(), ["api.themoviedb.org", "image.tmdb.org"]);
  assert.equal(manifest.author.name, "Tejas Verma", "the manifest uses the host's required author object");

const folderTree = {
  "/Shows": [{ filename: "Series", path: "/Series", isDir: true }],
  "/Shows/Series": [
    { filename: "Pilot S01E01.mp4", path: "/Pilot S01E01.mp4", isDir: false },
    { filename: "Literal%20Title S01E02.mp4", path: "/Literal%20Title S01E02.mp4", isDir: false },
  ],
};
const firstPath = "/Shows/Series/Pilot S01E01.mp4";
const saved = JSON.stringify({
  shows: [{
    name: "Series",
    key: "Series",
    tmdbId: 42,
    poster: "https://image.tmdb.org/t/p/w300/poster.jpg",
    overview: "Keep metadata across rescans",
    year: "2020",
    episodes: [{
      path: firstPath, file: "Pilot S01E01.mp4", season: 1, episode: 1,
      progress: 0.4, lastPlayed: 123, watched: false, title: "Pilot title",
    }],
  }],
  scannedAt: 100,
});
const plugin = runPlugin({ tree: folderTree, savedData: saved });
await new Promise(setImmediate);
assert.ok(plugin.events["mpv.end-file"], "progress cleanup subscribes to a public mpv event");
assert.equal(plugin.events["iina.player-shutdown"], undefined, "the plugin does not request the reserved shutdown event");
plugin.handlers.ready();
const libraryMessage = plugin.messages.filter((message) => message.name === "library").slice(-1)[0];
assert.ok(libraryMessage, "scan posts a library snapshot");
assert.equal(libraryMessage.data.shows.length, 1, "a show folder with episodes scans without crashing");
const show = libraryMessage.data.shows[0];
assert.equal(show.episodes.length, 2, "all matching episodes are grouped into the show");
assert.equal(show.episodes[0].path, firstPath, "relative file.list paths are joined to the parent folder");
assert.equal(show.tmdbId, 42, "existing TMDB metadata survives a rescan");
assert.equal(show.poster, "https://image.tmdb.org/t/p/w300/poster.jpg", "trusted poster metadata survives a rescan");
assert.equal(show.episodes[0].progress, 0.4, "playback progress survives a rescan");
assert.equal(show.episodes[0].title, "Pilot title", "metadata episode title survives a rescan");
assert.equal(libraryMessage.data.recentlyPlayed.map((item) => item.ep.path).join(","), firstPath,
  "episodes with no play history are excluded from Recently played");

plugin.handlers.play({ key: "Series", path: firstPath });
assert.deepEqual(plugin.state.opened, [firstPath], "episode playback opens the joined absolute path");
plugin.state.position = 0;
plugin.state.duration = 0;
plugin.events["iina.file-loaded"]();
const savedBeforeResume = JSON.parse(plugin.output.data);
assert.equal(savedBeforeResume.shows[0].episodes[0].progress, 0.4,
  "file-loaded at time zero does not erase the saved resume position");
assert.equal(plugin.state.mpvSets.length, 0, "resume waits until duration is available");
plugin.state.duration = 100;
plugin.timers[0]();
assert.deepEqual(plugin.state.mpvSets, [["time-pos", 40]], "resume uses the supported mpv.set API");

plugin.state.position = 65;
plugin.events["iina.plugin-will-unload"]("com.tverma101.reel.tv");
assert.equal(journalFor(plugin, firstPath).progress, 0.65,
  "plugin unload flushes the current playback position to its episode journal");
assert.ok(plugin.clearedIntervals.length > 0, "plugin unload stops the playback timer");
assert.ok(Object.keys(plugin.output.dataFiles).some((name) => name.startsWith("@data/reel-tv-progress-")),
  "progress has a per-episode journal separate from the shared library snapshot");

const expiringResume = runPlugin({ tree: folderTree, savedData: saved });
await new Promise(setImmediate);
expiringResume.handlers.play({ key: "Series", path: firstPath });
const unloadingResume = runPlugin({ tree: folderTree, savedData: saved });
await new Promise(setImmediate);
unloadingResume.handlers.play({ key: "Series", path: firstPath });
unloadingResume.state.duration = 0;
unloadingResume.events["iina.file-loaded"]();
unloadingResume.state.duration = 100;
unloadingResume.state.position = 55;
unloadingResume.events["iina.plugin-will-unload"]("com.tverma101.reel.tv");
assert.equal(journalFor(unloadingResume, firstPath).progress, 0.55,
  "unload records a valid position even while a delayed resume is pending");
unloadingResume.timers[0]();
assert.equal(unloadingResume.state.mpvSets.length, 0,
  "unload cancels a pending resume seek before the delayed callback runs");

const slowOpeningResume = runPlugin({ tree: folderTree, savedData: saved });
await new Promise(setImmediate);
slowOpeningResume.handlers.play({ key: "Series", path: firstPath });
slowOpeningResume.state.duration = 0;
slowOpeningResume.clock.now += 600000; // A slow open must not spend the duration-resolution window.
slowOpeningResume.events["iina.file-loaded"]();
assert.equal(slowOpeningResume.state.mpvSets.length, 0,
  "a slow open with unresolved duration waits for the post-load retry window");
assert.ok(slowOpeningResume.timers.length > 0,
  "the duration retry window starts when the matching file-loaded event arrives");
slowOpeningResume.clock.now += 60000;
slowOpeningResume.state.duration = 100;
slowOpeningResume.timers[0]();
assert.deepEqual(slowOpeningResume.state.mpvSets, [["time-pos", 40]],
  "a delayed duration can still resume inside the window after a slow open");
expiringResume.state.duration = 0;
expiringResume.events["iina.file-loaded"]();
expiringResume.clock.now += 120001;
expiringResume.timers[0]();
expiringResume.state.position = 35;
expiringResume.state.duration = 100;
expiringResume.events["iina.file-loaded"]();
assert.equal(expiringResume.state.mpvSets.length, 0, "a resume that expires cannot seek much later");
assert.equal(journalFor(expiringResume, firstPath).progress, 0.35,
  "progress recording resumes when duration becomes available after resume expiry");

const percentPath = "/Shows/Series/Literal%20Title S01E02.mp4";
plugin.state.url = "file://" + percentPath;
plugin.state.position = 25;
plugin.events["iina.file-loaded"]();
assert.equal(journalFor(plugin, percentPath).progress, 0.25,
  "literal percent escapes in file names are not decoded twice and progress matches the literal path");

const corrupt = runPlugin({ tree: folderTree, savedData: JSON.stringify({ shows: {} }) });
await new Promise(setImmediate);
corrupt.handlers.ready();
assert.equal(corrupt.messages.filter((message) => message.name === "library").slice(-1)[0].data.shows.length, 1,
  "malformed saved library data is discarded and the valid folder is scanned");
assert.equal(JSON.parse(corrupt.output.data).shows.length, 1,
  "the next complete scan replaces malformed library JSON with a valid snapshot");

const tildeRoot = runPlugin({ tree: folderTree, preferences: { tvFolder: "~/Shows" } });
await new Promise(setImmediate);
tildeRoot.handlers.refresh();
assert.ok(tildeRoot.messages.some((message) => message.name === "error" &&
  String(message.data).includes("full folder path")), "tilde roots explain the required absolute path");
assert.equal(tildeRoot.messages.filter((message) => message.name === "library").length, 0,
  "a tilde root is rejected before storing paths that cannot match playback URLs");

const keepData = JSON.stringify({
  shows: [{ name: "Keep", key: "Keep", episodes: [] }],
  scannedAt: 1,
});
const manyEntries = Array.from({ length: 20001 }, (_, index) => ({
  filename: ".ignored-" + index,
  path: "/.ignored-" + index,
  isDir: false,
}));
const oversized = runPlugin({ tree: { "/Shows": manyEntries }, savedData: keepData });
await new Promise(setImmediate);
oversized.handlers.ready();
assert.ok(oversized.messages.some((message) => message.name === "error" &&
  String(message.data).includes("20,000")), "the over-limit path reports that the cap was reached");
assert.equal(oversized.messages.filter((message) => message.name === "library").slice(-1)[0].data.shows[0].name, "Keep",
  "an over-limit scan does not replace the last complete library");
assert.equal(oversized.writes.length, 0, "an over-limit scan does not persist a partial result");

const incompleteTree = {
  "/Shows": [
    { filename: "Series", path: "/Series", isDir: true },
    { filename: "Unreadable", path: "/Unreadable", isDir: true },
  ],
  "/Shows/Series": folderTree["/Shows/Series"],
};
const incomplete = runPlugin({ tree: incompleteTree, savedData: keepData });
await new Promise(setImmediate);
incomplete.handlers.ready();
assert.equal(incomplete.messages.filter((message) => message.name === "library").slice(-1)[0].data.shows[0].name, "Keep",
  "a partial scan does not replace the previous library when a directory cannot be read");
assert.equal(incomplete.writes.length, 0, "an incomplete scan does not persist partial results");

const baseForJournal = JSON.stringify({
  shows: [{
    name: "Series", key: "Series", episodes: [{
      path: firstPath, file: "Pilot S01E01.mp4", season: 1, episode: 1,
      progress: 0, lastPlayed: 0, watched: false, title: "Pilot title",
    }],
  }],
  scannedAt: 0,
});
const sharedProgressFiles = {};
const firstWindow = runPlugin({ tree: folderTree, savedData: baseForJournal, savedDataFiles: sharedProgressFiles });
await new Promise(setImmediate);
firstWindow.handlers.playFromStart({ key: "Series", path: firstPath });
firstWindow.state.position = 30;
firstWindow.events["iina.file-loaded"]();
assert.equal(JSON.parse(Object.values(sharedProgressFiles)[0]).progress, 0.3,
  "a window writes progress to the episode journal");
const restartedWindow = runPlugin({
  tree: folderTree,
  savedData: baseForJournal,
  savedDataFiles: sharedProgressFiles,
});
await new Promise(setImmediate);
assert.equal(JSON.parse(restartedWindow.output.data).shows[0].episodes[0].progress, 0.3,
  "the episode journal restores progress even when the shared library snapshot is stale");
assert.equal(restartedWindow.listCalls.some((call) => call.filePath === "@data/"), false,
  "journal startup reads deterministic episode paths without enumerating the growing data folder");
const restoredFolder = runPlugin({
  tree: folderTree,
  savedData: JSON.stringify({ shows: [], scannedAt: 0 }),
  savedDataFiles: sharedProgressFiles,
});
await new Promise(setImmediate);
assert.equal(JSON.parse(restoredFolder.output.data).shows[0].episodes[0].progress, 0.3,
  "scanning a previously used folder restores a journal even when the episode is absent from the prior library snapshot");

const sharedLibraryStore = { data: baseForJournal };
let resolveStaleMetadata;
const staleWindow = runPlugin({
  tree: folderTree,
  sharedLibraryStore,
  preferences: { tvFolder: "", tmdbKey: "configured" },
  httpGet: (url) => url.includes("/search/tv")
    ? new Promise((resolve) => { resolveStaleMetadata = resolve; })
    : Promise.resolve({ data: { episodes: [] } }),
});
await new Promise(setImmediate);
staleWindow.preferenceValues.tvFolder = "/Shows";
await staleWindow.handlers.refresh();
await new Promise(setImmediate);
assert.equal(typeof resolveStaleMetadata, "function", "the older window holds a metadata save open");

const newerEpisodePath = "/Shows/Series/Newer S01E03.mp4";
const newerTree = {
  ...folderTree,
  "/Shows/Series": folderTree["/Shows/Series"].concat({
    filename: "Newer S01E03.mp4", path: "/Newer S01E03.mp4", isDir: false,
  }),
};
const newerWindow = runPlugin({ tree: newerTree, sharedLibraryStore, preferences: { tvFolder: "" } });
await new Promise(setImmediate);
newerWindow.preferenceValues.tvFolder = "/Shows";
newerWindow.clock.now = 1000100;
await newerWindow.handlers.refresh();
assert.ok(JSON.parse(sharedLibraryStore.data).shows[0].episodes.some((ep) => ep.path === newerEpisodePath),
  "the newer window persists its newly scanned episode");

resolveStaleMetadata({ data: { results: [{ id: 99, poster_path: "/stale.jpg" }] } });
await new Promise(setImmediate);
await new Promise(setImmediate);
const afterStaleSave = JSON.parse(sharedLibraryStore.data);
assert.equal(afterStaleSave.scannedAt, 1000100, "an older scan timestamp cannot replace the newer snapshot");
assert.ok(afterStaleSave.shows[0].episodes.some((ep) => ep.path === newerEpisodePath),
  "a delayed save from another player window preserves the newest library structure");

const tmdbTree = { "/Shows": [] };
for (let index = 0; index < 60; index += 1) {
  const folder = "/Shows/Series " + index;
  tmdbTree["/Shows"].push({ filename: "Series " + index, path: "/Series " + index, isDir: true });
  tmdbTree[folder] = [{ filename: "S01E01.mp4", path: "/S01E01.mp4", isDir: false }];
}
const boundedTmdb = runPlugin({ tree: tmdbTree, preferences: { tmdbKey: "configured" } });
boundedTmdb.handlers.ready();
await new Promise(setImmediate);
assert.equal(boundedTmdb.tmdbCalls.length, 40, "metadata traffic is capped at 40 requests per scan");

let resolvePendingTMDB;
const pendingTMDB = runPlugin({
  tree: { "/Shows": [{ filename: "Pending", path: "/Pending", isDir: true }],
    "/Shows/Pending": [{ filename: "Pending S01E01.mp4", path: "/Pending S01E01.mp4", isDir: false }] },
  preferences: { tmdbKey: "configured" },
  httpGet: () => new Promise((resolve) => { resolvePendingTMDB = resolve; }),
});
await new Promise(setImmediate);
assert.equal(pendingTMDB.tmdbCalls.length, 1, "the scan starts its first TMDB lookup");
const writesBeforeUnload = pendingTMDB.writes.length;
pendingTMDB.events["iina.plugin-will-unload"]("com.tverma101.reel.tv");
resolvePendingTMDB({ data: { results: [{ id: 42, poster_path: "/poster.jpg", overview: "late" }] } });
await new Promise(setImmediate);
assert.equal(pendingTMDB.tmdbCalls.length, 1, "an in-flight lookup does not schedule more TMDB work after unload");
assert.equal(pendingTMDB.writes.length, writesBeforeUnload, "an in-flight lookup does not write after unload");

console.log("PASS: Reel TV scan, path, metadata, resume, progress, request, and size-limit checks");
}

runChecks().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
