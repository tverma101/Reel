//
// Reel TV — sidebar webview.
// Talks to the plugin entry over postMessage; owns no IINA API access itself.
//

const rowsEl = document.getElementById("rows");
const detailEl = document.getElementById("detail");
const emptyEl = document.getElementById("empty");

let LIBRARY = { shows: [], continueWatching: [], recentlyPlayed: [] };

document.getElementById("rescan").addEventListener("click", () => {
  iina.postMessage("refresh");
});

iina.onMessage("library", (data) => {
  LIBRARY = data;
  renderHome();
});

iina.onMessage("progress", (data) => {
  const updatedAt = Date.now();
  for (const show of LIBRARY.shows) {
    const ep = show.episodes.find((e) => e.path === data.path);
    if (ep) {
      ep.progress = data.progress;
      ep.watched = data.watched;
      ep.lastPlayed = updatedAt;
    }
  }
  const episodes = LIBRARY.shows.flatMap((show) => show.episodes.map((ep) => ({
    show: show.name, key: show.key, ep,
  })));
  LIBRARY.continueWatching = episodes
    .filter((item) => !item.ep.watched && item.ep.progress > 0.02)
    .sort((a, b) => b.ep.lastPlayed - a.ep.lastPlayed)
    .slice(0, 12);
  LIBRARY.recentlyPlayed = episodes
    .filter((item) => item.ep.lastPlayed > 0)
    .sort((a, b) => b.ep.lastPlayed - a.ep.lastPlayed)
    .slice(0, 12);
  const list = document.querySelectorAll(`.ep[data-path="${CSS.escape(data.path)}"]`);
  list.forEach((el) => {
    const badge = el.querySelector(".badge");
    if (data.watched) { badge.textContent = "watched"; badge.className = "badge watched"; }
    else if (data.progress > 0.02) { badge.textContent = Math.round(data.progress * 100) + "%"; badge.className = "badge progress"; }
  });
  if (detailEl.classList.contains("hidden")) renderHome();
});

iina.onMessage("error", (message) => alert(message));

function posterStyle(item, fallback) {
  const url = item.poster || "";
  if (url) return `background-image:url('${url.replace(/'/g, "%27")}')`;
  return "";
}

function tile(item, { showPoster = true, showProgress = false, onClick }) {
  const div = document.createElement("div");
  div.className = "tile";
  const poster = document.createElement("div");
  poster.className = "poster";
  if (showPoster && item.poster) poster.style.backgroundImage = `url('${item.poster.replace(/'/g, "%27")}')`;
  const shade = document.createElement("div");
  shade.className = "shade";
  shade.textContent = item.poster ? "" : (item.name || item.title || "—");
  poster.appendChild(shade);
  div.appendChild(poster);
  const label = document.createElement("div");
  label.className = "label";
  label.textContent = item.label || item.title || "";
  div.appendChild(label);
  if (showProgress && item.progress > 0.02 && item.progress < 0.9) {
    const bar = document.createElement("div");
    bar.className = "progress";
    const fill = document.createElement("div");
    fill.style.width = Math.round(item.progress * 100) + "%";
    bar.appendChild(fill);
    div.appendChild(bar);
  }
  div.addEventListener("click", onClick);
  return div;
}

function row(title, items, buildTile) {
  if (!items.length) return;
  const t = document.createElement("div");
  t.className = "row-title";
  t.textContent = title;
  rowsEl.appendChild(t);
  const scroller = document.createElement("div");
  scroller.className = "scroller";
  items.forEach((item) => scroller.appendChild(buildTile(item)));
  rowsEl.appendChild(scroller);
}

function play(key, path) {
  iina.postMessage("play", { key, path });
}

function renderHome() {
  detailEl.classList.add("hidden");
  detailEl.innerHTML = "";
  rowsEl.classList.remove("hidden");
  rowsEl.innerHTML = "";

  const hasShows = LIBRARY.shows.length > 0;
  emptyEl.classList.toggle("hidden", hasShows);
  if (!hasShows) return;

  row(
    "Continue watching",
    LIBRARY.continueWatching.map((c) => ({
      poster: c.ep.poster || posterFor(c.key),
      label: c.show + " · S" + c.ep.season + "E" + c.ep.episode,
      progress: c.ep.progress,
      key: c.key,
      path: c.ep.path,
    })),
    (item) => tile(item, { showProgress: true, onClick: () => play(item.key, item.path) })
  );

  row(
    "Recently played",
    LIBRARY.recentlyPlayed.map((c) => ({
      poster: c.ep.poster || posterFor(c.key),
      label: c.show + " · S" + c.ep.season + "E" + c.ep.episode,
      progress: c.ep.progress,
      key: c.key,
      path: c.ep.path,
    })),
    (item) => tile(item, { showProgress: true, onClick: () => play(item.key, item.path) })
  );

  const showsTitle = document.createElement("div");
  showsTitle.className = "row-title";
  showsTitle.textContent = "All shows";
  rowsEl.appendChild(showsTitle);
  const grid = document.createElement("div");
  grid.className = "grid";
  LIBRARY.shows.forEach((show) => {
    const poster = document.createElement("div");
    poster.className = "poster";
    if (show.poster) poster.style.backgroundImage = `url('${show.poster.replace(/'/g, "%27")}')`;
    const shade = document.createElement("div");
    shade.className = "shade";
    shade.textContent = show.poster ? "" : show.name;
    poster.appendChild(shade);
    const item = document.createElement("div");
    item.className = "tile show-item";
    item.appendChild(poster);
    const label = document.createElement("div");
    label.className = "label";
    const unwatched = show.episodes.filter((e) => !e.watched).length;
    label.textContent = show.name + (show.year ? " · " + show.year : "") + " · " + unwatched + " left";
    item.appendChild(label);
    item.addEventListener("click", () => renderShow(show));
    grid.appendChild(item);
  });
  rowsEl.appendChild(grid);
}

function posterFor(showKey) {
  const show = LIBRARY.shows.find((s) => s.key === showKey);
  return show ? show.poster : "";
}

function renderShow(show) {
  rowsEl.classList.add("hidden");
  detailEl.classList.remove("hidden");
  detailEl.innerHTML = "";

  const back = document.createElement("button");
  back.className = "back";
  back.textContent = "‹ All shows";
  back.addEventListener("click", renderHome);
  detailEl.appendChild(back);

  const head = document.createElement("div");
  head.className = "show-head";
  const poster = document.createElement("div");
  poster.className = "poster";
  if (show.poster) poster.style.backgroundImage = `url('${show.poster.replace(/'/g, "%27")}')`;
  head.appendChild(poster);
  const meta = document.createElement("div");
  meta.className = "meta";
  const h2 = document.createElement("h2");
  h2.textContent = show.name;
  meta.appendChild(h2);
  const sub = document.createElement("div");
  sub.className = "sub";
  const unwatched = show.episodes.filter((e) => !e.watched).length;
  sub.textContent = [show.year, show.episodes.length + " episodes", unwatched + " unwatched"].join(" · ");
  meta.appendChild(sub);
  if (show.overview) {
    const overview = document.createElement("div");
    overview.className = "overview";
    overview.textContent = show.overview;
    meta.appendChild(overview);
  }
  head.appendChild(meta);
  detailEl.appendChild(head);

  const toolbar = document.createElement("div");
  toolbar.className = "toolbar";
  const playNext = document.createElement("button");
  playNext.className = "primary";
  playNext.textContent = "▶ Play next";
  playNext.addEventListener("click", () => {
    const ep = nextUnwatchedEp(show);
    if (ep) play(show.key, ep.path);
  });
  toolbar.appendChild(playNext);
  const reveal = document.createElement("button");
  reveal.textContent = "Show in Finder";
  reveal.addEventListener("click", () => iina.postMessage("reveal", { path: show.episodes[0].path }));
  toolbar.appendChild(reveal);
  detailEl.appendChild(toolbar);

  const list = document.createElement("div");
  list.className = "ep-list";
  show.episodes.forEach((ep) => {
    const el = document.createElement("div");
    el.className = "ep";
    el.dataset.path = ep.path;
    const num = document.createElement("div");
    num.className = "num";
    num.textContent = "S" + String(ep.season).padStart(2, "0") + "E" + String(ep.episode).padStart(2, "0");
    el.appendChild(num);
    const title = document.createElement("div");
    title.className = "title";
    const t = document.createElement("div");
    t.className = "t";
    t.textContent = ep.title || ep.file;
    title.appendChild(t);
    const s = document.createElement("div");
    s.className = "s";
    s.textContent = ep.file;
    title.appendChild(s);
    el.appendChild(title);
    const badge = document.createElement("div");
    badge.className = "badge";
    if (ep.watched) { badge.textContent = "watched"; badge.classList.add("watched"); }
    else if (ep.progress > 0.02) { badge.textContent = Math.round(ep.progress * 100) + "%"; badge.classList.add("progress"); }
    el.appendChild(badge);
    el.addEventListener("click", () => play(show.key, ep.path));
    list.appendChild(el);
  });
  detailEl.appendChild(list);
}

function nextUnwatchedEp(show) {
  const inProgress = show.episodes.find((e) => !e.watched && e.progress > 0.02 && e.progress < 0.9);
  return inProgress || show.episodes.find((e) => !e.watched) || null;
}

iina.postMessage("ready");
