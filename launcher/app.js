/* =========================================================
   NOTHING-HTPC LAUNCHER

   One page, one renderer, every screen. mpv runs underneath and is driven
   over server.py's IPC bridge; nothing in this file spawns a process.

   Screens: HOME, TV (live channels), MOVIES, SHOWS, NEWS, WEATHER, MUSIC.
   Every colour, size, duration and string comes from theme.json — see
   theme.js. If you find yourself typing a hex value or an English word
   here, it belongs in the theme instead.

   There is no demo mode. `?fixtures=1` is an explicit developer flag that
   feeds the screens canned data so the UI can be looked at on a laptop with
   no backend; without it a missing backend says so and retries. A real Ⓐ
   press is always a real action. (CLAUDE.md: the preview path was removed
   deliberately and must not come back.)
   ========================================================= */

import { loadTheme, THEME, copy } from "./theme.js";

const BACKEND = location.port === "8484" ? "" : "http://localhost:8484";
const FIXTURES = new URLSearchParams(location.search).has("fixtures");

/* =========================================================
   DOT-MATRIX ENGINE
   5x7 glyphs drawn as round dots. Latin, digits and the punctuation that
   shows up in titles — this face is display-only, so Cyrillic and Greek
   deliberately never reach it (they go through the body font instead).
   ========================================================= */
const GLYPHS = {
  "0":["01110","10001","10011","10101","11001","10001","01110"],
  "1":["00100","01100","00100","00100","00100","00100","01110"],
  "2":["01110","10001","00001","00010","00100","01000","11111"],
  "3":["11111","00010","00100","00010","00001","10001","01110"],
  "4":["00010","00110","01010","10010","11111","00010","00010"],
  "5":["11111","10000","11110","00001","00001","10001","01110"],
  "6":["00110","01000","10000","11110","10001","10001","01110"],
  "7":["11111","00001","00010","00100","01000","01000","01000"],
  "8":["01110","10001","10001","01110","10001","10001","01110"],
  "9":["01110","10001","10001","01111","00001","00010","01100"],
  ":":["00000","00100","00100","00000","00100","00100","00000"],
  "A":["01110","10001","10001","11111","10001","10001","10001"],
  "B":["11110","10001","10001","11110","10001","10001","11110"],
  "C":["01110","10001","10000","10000","10000","10001","01110"],
  "D":["11100","10010","10001","10001","10001","10010","11100"],
  "E":["11111","10000","10000","11110","10000","10000","11111"],
  "F":["11111","10000","10000","11110","10000","10000","10000"],
  "G":["01110","10001","10000","10111","10001","10001","01111"],
  "H":["10001","10001","10001","11111","10001","10001","10001"],
  "I":["01110","00100","00100","00100","00100","00100","01110"],
  "J":["00111","00010","00010","00010","00010","10010","01100"],
  "K":["10001","10010","10100","11000","10100","10010","10001"],
  "L":["10000","10000","10000","10000","10000","10000","11111"],
  "M":["10001","11011","10101","10101","10001","10001","10001"],
  "N":["10001","11001","10101","10011","10001","10001","10001"],
  "O":["01110","10001","10001","10001","10001","10001","01110"],
  "P":["11110","10001","10001","11110","10000","10000","10000"],
  "Q":["01110","10001","10001","10001","10101","10010","01101"],
  "R":["11110","10001","10001","11110","10100","10010","10001"],
  "S":["01111","10000","10000","01110","00001","00001","11110"],
  "T":["11111","00100","00100","00100","00100","00100","00100"],
  "U":["10001","10001","10001","10001","10001","10001","01110"],
  "V":["10001","10001","10001","10001","10001","01010","00100"],
  "W":["10001","10001","10001","10101","10101","11011","10001"],
  "X":["10001","10001","01010","00100","01010","10001","10001"],
  "Y":["10001","10001","01010","00100","00100","00100","00100"],
  "Z":["11111","00001","00010","00100","01000","10000","11111"],
  "°":["01100","10010","10010","01100","00000","00000","00000"],
  " ":["00000","00000","00000","00000","00000","00000","00000"],
  "-":["00000","00000","00000","11111","00000","00000","00000"],
  ".":["00000","00000","00000","00000","00000","01100","01100"],
  ",":["00000","00000","00000","00000","01100","01100","11000"],
  "'":["01100","01100","11000","00000","00000","00000","00000"],
  "!":["00100","00100","00100","00100","00100","00000","00100"],
  "?":["01110","10001","00001","00110","00100","00000","00100"],
  "&":["01100","10010","10100","01000","10101","10010","01101"],
  "(":["00010","00100","01000","01000","01000","00100","00010"],
  ")":["01000","00100","00010","00010","00010","00100","01000"],
  "/":["00001","00010","00010","00100","01000","01000","10000"],
  "+":["00000","00100","00100","11111","00100","00100","00000"],
  "*":["00000","10101","01110","11111","01110","10101","00000"],
};

const DOT_STEP = 1.55;          // dotPx -> advance per dot, incl. the 0.55 gap
export function dotSVG(text, dotPx, opts = {}) {
  const gap = dotPx * (opts.gap ?? 0.55);
  const step = dotPx + gap;
  const charGap = step * (opts.charGap ?? 1.4);
  const ghost = opts.ghost ?? false;
  const color = opts.color ?? "var(--ink)";
  /* `assemble` staggers each dot's fade-in so a value doesn't just appear —
     it builds. This is the signature motion of the whole UI, and it is a
     theme value, so the pi3 profile can turn it off by setting it to 0. */
  const stagger = opts.assemble ? (THEME.motion["dot-stagger"] || 0) : 0;
  const dur = THEME.motion["dot-assemble"] || 0;
  let x = 0, dots = "", n = 0;
  for (const raw of String(text).toUpperCase()) {
    const g = GLYPHS[raw] || GLYPHS[" "];
    for (let r = 0; r < 7; r++) {
      for (let c = 0; c < 5; c++) {
        const on = g[r][c] === "1";
        if (!on && !ghost) continue;
        const cx = x + c * step + dotPx / 2;
        const cy = r * step + dotPx / 2;
        const anim = (on && stagger)
          ? `<animate attributeName="opacity" from="0" to="1" dur="${dur}ms" begin="${n++ * stagger}ms" fill="freeze"/>`
          : "";
        const op = (on && stagger) ? ' opacity="0"' : "";
        dots += `<circle cx="${cx}" cy="${cy}" r="${dotPx / 2}" fill="${on ? color : "var(--dot-off)"}"${op}>${anim}</circle>`;
      }
    }
    x += 5 * step + charGap;
  }
  const w = Math.max(1, x - charGap);
  const h = 7 * step - gap;
  /* aria-label carries the text the dots spell. Without it this glyph is a
     pile of circles: unreadable to a screen reader, and invisible to any test
     that asks what the screen says. */
  const label = String(text).toUpperCase().replace(/[&<>"]/g, "");
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" ` +
         `role="img" aria-label="${label}" xmlns="http://www.w3.org/2000/svg">${dots}</svg>`;
}

/* Solve a dot size so `text` fits `avail` px wide, rather than picking a
   viewport fraction and hoping. dotSVG advances step*(5+charGap) per glyph
   with step = dotPx * DOT_STEP. */
export function fitDots(text, avail, { max = 40, min = 2, charGap = 1.4 } = {}) {
  const n = Math.max(1, String(text).length);
  const per = DOT_STEP * (5 + charGap);
  return Math.max(min, Math.min(max, avail / (n * per)));
}

/* =========================================================
   TOAST
   ========================================================= */
const toastEl = document.getElementById("toast");
const toastText = document.getElementById("toasttext");
let toastTimer;
function showToast(msg, ms = 2200) {
  toastText.textContent = msg;
  toastEl.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove("show"), ms);
}

/* =========================================================
   VIEW ROUTER
   Views are stacked and cross-dissolved; the outgoing one stays opaque
   until the incoming one is fully up. TV is the one transparent view —
   it lets mpv through, so the body loses its background while it is on.
   ========================================================= */
let view = "home";
const VIEW_STACK = [];

function showView(name, { push = true } = {}) {
  if (view === name) return;
  const from = document.getElementById(view + "view");
  const to = document.getElementById(name + "view");
  if (push) VIEW_STACK.push(view);
  view = name;

  /* TV is the one view that lets mpv through. Under fixtures there is no
     mpv, and a transparent body renders as the browser's white default —
     so the dev flag keeps it black and the bar stays readable. */
  document.body.classList.toggle("transparent", name === "tv" && !FIXTURES);

  to.style.display = "flex";
  to.classList.add("front");
  requestAnimationFrame(() => requestAnimationFrame(() => to.classList.add("on")));
  setTimeout(() => {
    from.classList.remove("on");
    from.style.display = "none";
    to.classList.remove("front");
  }, THEME.motion.view);

  onEnterView(name);
}

function goBack() {
  const prev = VIEW_STACK.pop() || "home";
  const cur = view;
  view = "__";                       // force showView past its equality guard
  view = cur;
  showView(prev, { push: false });
}

function onEnterView(name) {
  if (name === "music") pollMusic();
  if (name === "tv") { tvEnter(); }
  if (name === "news") newsEnter();
  if (name === "weather") weatherEnter();
  if (name === "grid") gridEnter();
}

/* =========================================================
   CLOCK
   ========================================================= */
const clockEl = document.getElementById("clock");
const dateEl = document.getElementById("datetext");
const greetEl = document.getElementById("greeting");
const DAYS = ["SUNDAY","MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY","SATURDAY"];
const MONTHS = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];
let lastClock = "";

function hhmm(d = new Date()) {
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
}
function drawClock(force) {
  const d = new Date();
  const face = hhmm(d).replace(":", d.getSeconds() % 2 === 0 ? ":" : " ");
  document.getElementById("chanclock").textContent = hhmm(d);
  document.getElementById("wxclock").textContent = hhmm(d);
  if (face === lastClock && !force) return;
  lastClock = face;
  const size = Math.max(6, Math.round(Math.min(
    innerWidth * (THEME.layout["clock-dot-scale"] || 0.019), innerHeight * 0.034)));
  clockEl.innerHTML = dotSVG(face, size, { ghost: true });
  dateEl.textContent = `${DAYS[d.getDay()]} · ${MONTHS[d.getMonth()]} ${String(d.getDate()).padStart(2, "0")}`;
  const h = d.getHours();
  greetEl.textContent = copy(
    h < 5 ? "greeting.night" : h < 12 ? "greeting.morning" :
    h < 18 ? "greeting.afternoon" : "greeting.evening");
}

/* =========================================================
   WEATHER — Open-Meteo, no key (CLAUDE.md constraint 8)
   The home screen shows one line for the box's own coordinates; the
   WEATHER screen shows three cities that are identities of their own and
   deliberately not the box's location.
   ========================================================= */
const WMO = {
  0:"CLEAR", 1:"MOSTLY CLEAR", 2:"PARTLY CLOUDY", 3:"OVERCAST",
  45:"FOG", 48:"FOG", 51:"DRIZZLE", 53:"DRIZZLE", 55:"DRIZZLE",
  61:"LIGHT RAIN", 63:"RAIN", 65:"HEAVY RAIN", 66:"FREEZING RAIN", 67:"FREEZING RAIN",
  71:"LIGHT SNOW", 73:"SNOW", 75:"HEAVY SNOW", 77:"SNOW",
  80:"SHOWERS", 81:"SHOWERS", 82:"HEAVY SHOWERS",
  85:"SNOW SHOWERS", 86:"SNOW SHOWERS", 95:"THUNDERSTORM", 96:"THUNDERSTORM", 99:"THUNDERSTORM",
};
/* Icons are drawn, not typed — same reason the type is. Five shapes cover
   every WMO code the box will ever show. */
const WX_ICON = {
  clear: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"/><path d="M12 1v3M12 20v3M1 12h3M20 12h3M4.2 4.2l2 2M17.8 17.8l2 2M19.8 4.2l-2 2M6.2 17.8l-2 2"/></svg>',
  cloud: '<svg viewBox="0 0 24 24"><path d="M7 18h10a4 4 0 0 0 0-8 6 6 0 0 0-11.6 2A3.5 3.5 0 0 0 7 18z"/></svg>',
  rain:  '<svg viewBox="0 0 24 24"><path d="M7 15h10a4 4 0 0 0 0-8 6 6 0 0 0-11.6 2A3.5 3.5 0 0 0 7 15z"/><path d="M8 19l-1 2M12 19l-1 2M16 19l-1 2"/></svg>',
  snow:  '<svg viewBox="0 0 24 24"><path d="M7 15h10a4 4 0 0 0 0-8 6 6 0 0 0-11.6 2A3.5 3.5 0 0 0 7 15z"/><path d="M8 19v2M12 19v2M16 19v2M7 20h2M11 20h2M15 20h2"/></svg>',
  storm: '<svg viewBox="0 0 24 24"><path d="M7 15h10a4 4 0 0 0 0-8 6 6 0 0 0-11.6 2A3.5 3.5 0 0 0 7 15z"/><path d="M13 17l-3 5h4l-2 3"/></svg>',
};
function wxKind(code) {
  if (code <= 1) return "clear";
  if (code <= 48) return "cloud";
  if (code >= 71 && code <= 77 || code === 85 || code === 86) return "snow";
  if (code >= 95) return "storm";
  return "rain";
}

const WX_CITIES = [
  { name: "Скопје",       lat: 41.9973, lon: 21.4280 },
  { name: "Ljubljana",    lat: 46.0569, lon: 14.5058 },
  { name: "Θεσσαλονίκη",  lat: 40.6401, lon: 22.9444 },
];

let cfg = { weather: { lat: 41.117, lon: 20.802 } };

async function loadBriefWeather() {
  if (FIXTURES) {
    document.getElementById("wtemp").innerHTML = dotSVG("24°", 4);
    document.getElementById("wcond").textContent = "PARTLY CLOUDY";
    document.getElementById("wtag").textContent = "FIXTURES";
    return;
  }
  try {
    const { lat, lon } = cfg.weather;
    const j = await fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code`,
      { signal: AbortSignal.timeout(4000) }).then(r => r.json());
    document.getElementById("wtemp").innerHTML =
      dotSVG(`${Math.round(j.current.temperature_2m)}°`, Math.max(3, innerWidth * 0.004));
    document.getElementById("wcond").textContent = WMO[j.current.weather_code] || "—";
    document.getElementById("wtag").textContent = "";
  } catch (_) {
    document.getElementById("wcond").textContent = copy("state.offline");
  }
}

let wxLoaded = false;
async function weatherEnter() {
  document.getElementById("wxhead").textContent = copy("tiles.weather");
  if (wxLoaded) return;
  const grid = document.getElementById("wxgrid");
  const days = THEME.layout["weather-days"] || 3;

  const rows = await Promise.all(WX_CITIES.map(async (city) => {
    let daily;
    if (FIXTURES) {
      daily = { time: ["", "", ""], weather_code: [0, 3, 61],
                temperature_2m_max: [31, 28, 22], temperature_2m_min: [18, 17, 15] };
    } else {
      try {
        const j = await fetch(
          `https://api.open-meteo.com/v1/forecast?latitude=${city.lat}&longitude=${city.lon}` +
          `&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=${days}&timezone=auto`,
          { signal: AbortSignal.timeout(6000) }).then(r => r.json());
        daily = j.daily;
      } catch (_) { return `<div class="wxcity"><div class="wxname">${city.name}</div>
        <div class="wxdays"><div class="wxday"><span class="when">${copy("state.offline")}</span></div></div></div>`; }
    }
    const cells = [];
    for (let i = 0; i < days; i++) {
      const when = i === 0 ? copy("weather.today")
        : (daily.time[i] ? DAYS[new Date(daily.time[i]).getDay()].slice(0, 3) : `+${i}`);
      cells.push(`<div class="wxday">
        <span class="icon">${WX_ICON[wxKind(daily.weather_code[i])]}</span>
        <span>
          <div class="when">${when}</div>
          <div class="temps">${Math.round(daily.temperature_2m_max[i])}°
            <span class="lo">${Math.round(daily.temperature_2m_min[i])}°</span></div>
        </span></div>`);
    }
    return `<div class="wxcity"><div class="wxname">${city.name}</div>
              <div class="wxdays">${cells.join("")}</div></div>`;
  }));

  grid.innerHTML = rows.join("");
  wxLoaded = true;
}

/* =========================================================
   NEWS
   Time.mk on top with one scrolling row per category, Θεσσαλονίκη on the
   bottom. Headlines are never wrapped — one row each, always. The old
   teletext page learned that the hard way when a wrapped headline split
   across a subpage break.
   ========================================================= */
const NEWS_TOP_CATS = [
  { slug: "makedonija", label: "МАКЕДОНИЈА" },
  { slug: "skopje",     label: "СКОПЈЕ" },
  { slug: "sport",      label: "СПОРТ" },
  { slug: "kultura",    label: "КУЛТУРА" },
  { slug: "svet",       label: "СВЕТ" },
  { slug: "ekonomija",  label: "ЕКОНОМИЈА" },
];

const FIXTURE_HEADLINES = [
  "Владата ги објави мерките за енергетската криза",
  "Нов кружен тек на булеварот Партизански одреди",
  "Вардар со убедлива победа во дербито",
  "Отворена изложбата во Музејот на современата уметност",
];

/* A marquee needs its content twice: the keyframe translates -50%, so the
   second copy is what is on screen as the first scrolls off. Duration comes
   from the theme in px/s, measured against the real width, so a long row
   and a short row scroll at the same speed rather than the same duration. */
function marqueeRow(label, items) {
  const inner = items.map(t => `<span class="item">${escapeHTML(t)}</span>`).join("");
  return `<div class="catrow">
            <span class="cat">${label}</span>
            <span class="track" data-count="${items.length}">${inner}${inner}</span>
          </div>`;
}
function escapeHTML(s) {
  return String(s).replace(/[&<>"]/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;" }[c]));
}
function startMarquees(scope) {
  const speed = THEME.motion["marquee-px-per-s"] || 40;
  scope.querySelectorAll(".track").forEach(el => {
    const w = el.scrollWidth / 2;             // one copy
    if (!w) return;
    el.style.animationDuration = `${Math.max(8, w / speed)}s`;
  });
}

async function fetchRSS(url) {
  /* The backend proxies feeds: a browser cannot read time.mk directly
     (no CORS header), and routing through server.py also means one place
     to cache them rather than one per screen repaint. */
  const r = await fetch(`${BACKEND}/news?url=${encodeURIComponent(url)}`,
                        { signal: AbortSignal.timeout(8000) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

let newsLoaded = false;
async function newsEnter() {
  if (newsLoaded) return;
  const top = document.getElementById("newstop");
  const bottom = document.getElementById("newsbottom");
  const nTop = THEME.layout["news-rows-top"] || 4;

  const head = (name, region) =>
    `<div class="sourcehead"><span class="name">${dotSVG(name, 5, { charGap: 1.2 })}</span>` +
    (region ? `<span class="region">${region}</span>` : "") + `</div>`;

  top.innerHTML = head(copy("news.top-source"), "");
  bottom.innerHTML = head(copy("news.bottom-source"), copy("news.bottom-region"));

  const cats = NEWS_TOP_CATS.slice(0, nTop);
  for (const c of cats) {
    let items;
    if (FIXTURES) items = FIXTURE_HEADLINES;
    else {
      try { items = (await fetchRSS(`https://time.mk/rss/${c.slug}`)).items.map(i => i.title); }
      catch (_) { items = [copy("state.offline")]; }
    }
    top.insertAdjacentHTML("beforeend", marqueeRow(c.label, items));
  }

  let bItems;
  if (FIXTURES) bItems = ["Βελτιωμένος ο Ηρακλής, 1-1 με την Παλέρμο",
                          "Νέα μέτρα για την κυκλοφορία στο κέντρο"];
  else {
    /* thestival.gr went behind a Cloudflare challenge in July 2026 — the
       third Greek source to break. makthes.gr answers, but publishes no
       category tags and no section feeds, so this half is one row. */
    try { bItems = (await fetchRSS("https://www.makthes.gr/feed")).items.map(i => i.title); }
    catch (_) { bItems = [copy("state.offline")]; }
  }
  bottom.insertAdjacentHTML("beforeend", marqueeRow(copy("news.bottom-region"), bItems));

  startMarquees(document.getElementById("newsview"));
  newsLoaded = true;
}

/* =========================================================
   TV — live channels only. Numbers belong here and nowhere else.
   The bar shows number, name and the clock, then fades. Zapping does not
   wait for a stream: the number moves on the keypress and the load is
   debounced, which is what makes running up the dial usable.
   ========================================================= */
const FIXTURE_CHANNELS = [
  { no: 101, name: "MRT 1" }, { no: 102, name: "MRT 2" },
  { no: 103, name: "TELMA" }, { no: 104, name: "KANAL 5" },
  { no: 105, name: "SITEL" }, { no: 201, name: "ERT 1" },
];

const tv = {
  channels: [],
  idx: 0,
  digits: "",
  digitTimer: null,
  barTimer: null,
  loadTimer: null,
  state: null,        // null | "loading" | "no-signal"
};

async function loadChannels() {
  if (FIXTURES) { tv.channels = FIXTURE_CHANNELS; return; }
  try {
    tv.channels = await fetch(`${BACKEND}/channels`, { signal: AbortSignal.timeout(3000) })
      .then(r => r.json());
  } catch (_) { tv.channels = []; showToast(copy("state.offline")); }
}

function tvEnter() {
  if (!tv.channels.length) { loadChannels().then(() => tvShow()); return; }
  tvShow();
}

function tvShow() {
  const ch = tv.channels[tv.idx];
  if (!ch) { setChanState("empty"); return; }
  const bar = document.getElementById("chanbar");
  document.getElementById("channum").innerHTML =
    dotSVG(String(ch.no), THEME.layout["bar-number-dot"] || 5.5, { assemble: true });
  document.getElementById("channame").textContent = ch.name;
  bar.classList.add("show");
  clearTimeout(tv.barTimer);
  tv.barTimer = setTimeout(() => bar.classList.remove("show"), THEME.motion["bar-hold"]);

  /* Debounced load — the picture cuts to the indicator immediately, but the
     stream is not opened until the number has sat still. */
  setChanState("loading");
  clearTimeout(tv.loadTimer);
  tv.loadTimer = setTimeout(() => tvLoad(ch), 450);
}

function setChanState(key) {
  const el = document.getElementById("chanstate");
  if (!key) { el.classList.remove("on"); tv.state = null; return; }
  tv.state = key;
  document.getElementById("chanstatetext").textContent = copy(`state.${key}`);
  el.classList.add("on");
}

async function tvLoad(ch) {
  if (FIXTURES) { setTimeout(() => setChanState(null), 700); return; }
  try {
    const r = await fetch(`${BACKEND}/player/load`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ url: ch.url, kind: "live" }),
    }).then(r => r.json());
    setChanState(r.ok ? null : "no-signal");
    if (!r.ok && r.msg) showToast(String(r.msg).toUpperCase());
  } catch (_) { setChanState("no-signal"); showToast(copy("state.offline")); }
}

function tvZap(dir) {
  if (!tv.channels.length) return;
  tv.idx = (tv.idx + dir + tv.channels.length) % tv.channels.length;
  tvShow();
}

function tvDigit(d) {
  tv.digits = (tv.digits + d).slice(-4);
  const el = document.getElementById("digits");
  el.innerHTML = dotSVG(tv.digits, THEME.layout["bar-number-dot"] || 5.5);
  el.classList.add("on");
  clearTimeout(tv.digitTimer);
  const commit = () => {
    el.classList.remove("on");
    const n = parseInt(tv.digits, 10);
    tv.digits = "";
    const i = tv.channels.findIndex(c => c.no === n);
    if (i >= 0) { tv.idx = i; tvShow(); }
    else showToast(copy("state.empty"));
  };
  /* Three digits tunes instantly; fewer waits, the way a cable box does. */
  if (tv.digits.length >= 3) commit();
  else tv.digitTimer = setTimeout(commit, 2000);
}

async function tvStop() {
  clearTimeout(tv.loadTimer);
  setChanState(null);
  if (!FIXTURES) { try { await fetch(`${BACKEND}/player/stop`, { method: "POST" }); } catch (_) {} }
}

/* =========================================================
   MOVIES / SHOWS — one poster grid, switched by kind.
   Catalogue comes from the backend's Stremio-shaped client (Cinemeta);
   pressing OK resolves a stream and hands it to mpv.
   ========================================================= */
const FIXTURE_LIBRARY = [
  { title: "Dune: Part Two", year: "2024", runtime: 166, rating: "8.5", poster: "", plot: "Paul Atreides unites with the Fremen to wage war against House Harkonnen." },
  { title: "Poor Things", year: "2023", runtime: 141, rating: "8.0", poster: "", plot: "A young woman brought back to life by an unorthodox scientist runs away with a lawyer." },
  { title: "Oppenheimer", year: "2023", runtime: 180, rating: "8.4", poster: "", plot: "The story of the American scientist who helped develop the atomic bomb." },
  { title: "The Zone of Interest", year: "2023", runtime: 105, rating: "7.4", poster: "", plot: "The commandant of Auschwitz and his wife build a life beside the camp wall." },
  { title: "Anatomy of a Fall", year: "2023", runtime: 152, rating: "7.7", poster: "", plot: "A woman is suspected of her husband's death; their blind son faces a moral dilemma." },
  { title: "Past Lives", year: "2023", runtime: 105, rating: "7.8", poster: "", plot: "Two childhood friends reunite in New York two decades after being separated." },
  { title: "Killers of the Flower Moon", year: "2023", runtime: 206, rating: "7.6", poster: "", plot: "Members of the Osage tribe are murdered under mysterious circumstances." },
  { title: "The Holdovers", year: "2023", runtime: 133, rating: "7.9", poster: "", plot: "A teacher remains at a New England prep school over the winter holidays." },
  { title: "Fallen Leaves", year: "2023", runtime: 81, rating: "7.4", poster: "", plot: "Two lonely people meet by chance in the Helsinki night." },
  { title: "Perfect Days", year: "2023", runtime: 124, rating: "7.9", poster: "", plot: "A Tokyo toilet cleaner finds beauty in his structured daily routine." },
  { title: "May December", year: "2023", runtime: 117, rating: "6.7", poster: "", plot: "An actress studies the woman she will portray in a film about a scandal." },
  { title: "Godzilla Minus One", year: "2023", runtime: 125, rating: "7.7", poster: "", plot: "Postwar Japan faces a new devastation in the form of a giant monster." },
];

const gridState = { kind: "movie", items: [], sel: 0, detail: false, loaded: {} };

async function gridEnter() {
  document.getElementById("gridtitle").innerHTML =
    dotSVG(copy(gridState.kind === "movie" ? "tiles.movies" : "tiles.shows"), 6, { assemble: true });
  if (gridState.loaded[gridState.kind]) { renderGrid(); return; }

  if (FIXTURES) gridState.items = FIXTURE_LIBRARY;
  else {
    try {
      gridState.items = await fetch(`${BACKEND}/catalog/${gridState.kind}`,
        { signal: AbortSignal.timeout(8000) }).then(r => r.json());
    } catch (_) { gridState.items = []; showToast(copy("state.offline")); }
  }
  gridState.loaded[gridState.kind] = true;
  gridState.sel = 0;
  renderGrid();
}

function renderGrid() {
  const el = document.getElementById("grid");
  const cap = THEME.layout["posters-in-flight"] || 24;
  const items = gridState.items.slice(0, cap);
  document.getElementById("gridcount").textContent =
    gridState.items.length ? `${gridState.items.length}` : copy("state.empty");

  el.innerHTML = items.map((it, i) => `
    <div class="card${i === gridState.sel ? " sel" : ""}" data-i="${i}">
      ${it.poster ? `<img src="${escapeHTML(it.poster)}" alt="" loading="lazy">` : ""}
      <div class="stub"><span>${escapeHTML(it.title)}</span>${it.year ? `<span class="y">${escapeHTML(it.year)}</span>` : ""}</div>
    </div>`).join("");

  el.querySelectorAll(".card").forEach(c =>
    c.addEventListener("click", () => { gridState.sel = +c.dataset.i; renderGrid(); openDetail(); }));
}

function gridMove(dx, dy) {
  const cols = THEME.layout["grid-columns"] || 6;
  const cap = Math.min(gridState.items.length, THEME.layout["posters-in-flight"] || 24);
  if (!cap) return;
  let n = gridState.sel + dx + dy * cols;
  if (n < 0 || n >= cap) return;
  gridState.sel = n;
  renderGrid();
}

function openDetail() {
  const it = gridState.items[gridState.sel];
  if (!it) return;
  gridState.detail = true;
  document.getElementById("dposter").innerHTML =
    it.poster ? `<img src="${escapeHTML(it.poster)}" alt="">` : "";
  const w = innerWidth * 0.5;
  document.getElementById("dtitle").innerHTML =
    dotSVG(it.title, fitDots(it.title, w, { max: 9 }), { assemble: true });
  const meta = [];
  if (it.year) meta.push(escapeHTML(it.year));
  if (it.runtime) meta.push(`${Math.floor(it.runtime / 60)}H ${it.runtime % 60}M`);
  if (it.rating) meta.push(`<span class="rating">★ ${escapeHTML(it.rating)}</span>`);
  document.getElementById("dmeta").innerHTML = meta.map(m => `<span>${m}</span>`).join("");
  document.getElementById("dplot").textContent = it.plot || "";
  document.getElementById("detail").classList.add("on");
}
function closeDetail() {
  gridState.detail = false;
  document.getElementById("detail").classList.remove("on");
}

async function playSelected() {
  const it = gridState.items[gridState.sel];
  if (!it) return;
  if (FIXTURES) { showToast(`${copy("state.resolving")} · ${it.title.toUpperCase()}`); return; }
  showToast(copy("state.resolving"), 30000);
  try {
    const r = await fetch(`${BACKEND}/play`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ kind: gridState.kind, id: it.id }),
    }).then(r => r.json());
    if (r.ok) { closeDetail(); showToast(`${copy("state.playing")}`, 1500); showView("tv"); }
    else showToast(String(r.msg || "").toUpperCase() || copy("state.no-signal"), 4000);
  } catch (_) { showToast(copy("state.offline"), 4000); }
}

/* =========================================================
   MENU
   ========================================================= */
const ICONS = {
  tv:       '<svg viewBox="0 0 40 40"><rect x="4" y="12" width="32" height="22" rx="1"/><path d="M13 12 20 5l7 7"/><circle cx="30" cy="18" r="1.4" fill="currentColor"/></svg>',
  movies:   '<svg viewBox="0 0 40 40"><rect x="5" y="8" width="30" height="24"/><path d="M5 14h30M5 26h30M12 8v6M20 8v6M28 8v6M12 26v6M20 26v6M28 26v6"/></svg>',
  shows:    '<svg viewBox="0 0 40 40"><rect x="4" y="10" width="32" height="21"/><path d="M14 35h12M20 31v4M12 4l8 6 8-6"/></svg>',
  news:     '<svg viewBox="0 0 40 40"><rect x="5" y="9" width="30" height="22"/><path d="M10 15h11M10 20h11M10 25h11M25 15h5M25 20h5M25 25h5"/></svg>',
  weather:  '<svg viewBox="0 0 40 40"><circle cx="15" cy="15" r="5"/><path d="M15 5v3M15 22v3M5 15h3M22 15h3M8 8l2 2M20 20l2 2M22 8l-2 2M10 20l-2 2"/><path d="M18 32h12a4.5 4.5 0 0 0 0-9 6.5 6.5 0 0 0-12.5 1.5A4 4 0 0 0 18 32z"/></svg>',
  music:    '<svg viewBox="0 0 40 40"><path d="M14 30V9l18-3v20"/><circle cx="10" cy="30" r="4"/><circle cx="28" cy="26" r="4"/></svg>',
};

/* Screens, not processes. Every one of these is a view in this page — the
   clean split put channel numbers behind TV and gave everything else its
   own screen, so there is no launch and no black frame anywhere. */
const TILES = [
  { id: "tv",      view: "tv" },
  { id: "movies",  view: "grid", kind: "movie" },
  { id: "shows",   view: "grid", kind: "show" },
  { id: "news",    view: "news" },
  { id: "weather", view: "weather" },
  { id: "music",   view: "music" },
];
let sel = 0;
const menuEl = document.getElementById("menu");

function buildMenu() {
  menuEl.innerHTML = "";
  TILES.forEach((t, i) => {
    const label = copy(`tiles.${t.id}`);
    const el = document.createElement("div");
    el.className = "tile" + (i === sel ? " sel" : "");
    el.innerHTML = `
      <div class="icon">${ICONS[t.id] || ICONS.tv}</div>
      <div class="label">${label}</div>
      <div class="dotlabel">${dotSVG(label, Math.max(1.6, innerWidth * (THEME.layout["menu-dot-scale"] || 0.0018)), { charGap: 1.1 })}</div>
      <div class="marker"></div>`;
    el.addEventListener("click", () => { sel = i; refreshSel(); openSelected(); });
    menuEl.appendChild(el);
  });
}
function refreshSel() {
  [...menuEl.children].forEach((t, i) => t.classList.toggle("sel", i === sel));
}
function openSelected() {
  const t = TILES[sel];
  if (t.kind) gridState.kind = t.kind;
  showView(t.view);
}

/* =========================================================
   MUSIC — spotifyd over MPRIS. Unchanged in behaviour; every value it
   draws with now comes from the theme.
   ========================================================= */
const mArt = document.getElementById("mart");
const mTitle = document.getElementById("mtitle");
const mArtist = document.getElementById("martist");
const mAlbum = document.getElementById("malbum");
const mState = document.getElementById("mstate");
const mBar = document.getElementById("mbar");
const mFill = document.getElementById("mfill");
const mHead = document.getElementById("mhead2");
const mPos = document.getElementById("mpos");
const mLen = document.getElementById("mlen");
const npEl = document.getElementById("nowplaying");
const npText = document.getElementById("nptext");

const music = { available: true, playing: false, trackKey: "", title: "",
                length: 0, posBase: 0, posAt: 0, seq: null };

function mmss(s) {
  s = Math.max(0, Math.floor(s || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

const ART_N = 34;
function artPlaceholder() {
  const step = 100 / ART_N;
  let s = "";
  for (let y = 0; y < ART_N; y++)
    for (let x = 0; x < ART_N; x++)
      s += `<circle cx="${(x + .5) * step}" cy="${(y + .5) * step}" r="${step * .16}"/>`;
  return `<svg viewBox="0 0 100 100" fill="var(--dot-off)">${s}</svg>`;
}
function drawArt(img) {
  const c = document.createElement("canvas");
  c.width = c.height = ART_N;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.drawImage(img, 0, 0, ART_N, ART_N);
  let d;
  try { d = g.getImageData(0, 0, ART_N, ART_N).data; }
  catch (_) { return artPlaceholder(); }
  const step = 100 / ART_N;
  let s = "";
  for (let y = 0; y < ART_N; y++) {
    for (let x = 0; x < ART_N; x++) {
      const i = (y * ART_N + x) * 4;
      const lum = (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255;
      const r = (step / 2) * (0.14 + 0.86 * lum);
      if (r < 0.1) continue;
      s += `<circle cx="${(x + .5) * step}" cy="${(y + .5) * step}" r="${r.toFixed(2)}"/>`;
    }
  }
  return `<svg viewBox="0 0 100 100" fill="var(--ink)">${s}</svg>`;
}
function loadArt(hasArt) {
  if (!hasArt) { mArt.innerHTML = artPlaceholder(); return; }
  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => { mArt.innerHTML = drawArt(img); };
  img.onerror = () => { mArt.innerHTML = artPlaceholder(); };
  img.src = `${BACKEND}/music/art?t=${Date.now()}`;
}

function titleDots(text) {
  const MAX = 28;
  let t = (text || "").toUpperCase();
  if (t.length > MAX) t = t.slice(0, MAX - 3).trimEnd() + "...";
  const avail = (mTitle.clientWidth || innerWidth * 0.55) * 0.98;
  return dotSVG(t, fitDots(t, avail, { max: innerHeight * 0.013, charGap: 1.6 }), { charGap: 1.6 });
}

function applyMusic(s) {
  if (music.seq !== null && s.home_seq !== music.seq && view === "music") showView("home");
  music.seq = s.home_seq;
  music.available = s.available !== false;
  music.playing = !!s.playing;
  document.getElementById("mhead").textContent = copy("music.header");

  if (!music.available) {
    mState.textContent = copy("state.unavailable");
    mTitle.innerHTML = titleDots(copy("music.no-player"));
    mArtist.textContent = copy("music.no-playerctl");
    mAlbum.textContent = "";
    mArt.innerHTML = artPlaceholder();
    npEl.classList.remove("on");
    return;
  }
  if (!s.status) {
    mState.textContent = copy("state.idle");
    mTitle.innerHTML = titleDots(copy("music.nothing"));
    mArtist.textContent = copy("music.prompt");
    mAlbum.textContent = copy("music.speaker");
    mArt.innerHTML = artPlaceholder();
    music.trackKey = ""; music.length = 0;
    mFill.style.width = "0%"; mHead.style.transform = "translateX(0)";
    mPos.textContent = mLen.textContent = "0:00";
    npEl.classList.remove("on");
    return;
  }
  const key = `${s.artist} — ${s.title}`;
  if (key !== music.trackKey) {
    music.trackKey = key; music.title = s.title;
    mTitle.innerHTML = titleDots(s.title);
    loadArt(s.art);
  }
  mArtist.textContent = (s.artist || "").toUpperCase();
  mAlbum.textContent = (s.album || "").toUpperCase();
  mState.textContent = copy(s.playing ? "state.playing" : "state.paused");
  music.length = s.length || 0;
  music.posBase = s.position || 0;
  music.posAt = performance.now();
  mLen.textContent = mmss(music.length);
  tickProgress();
  npText.innerHTML =
    `<span class="nplabel">${copy(s.playing ? "music.now" : "state.paused")}</span>&nbsp;&nbsp;` +
    `${(s.title || "").toUpperCase()} · ${(s.artist || "").toUpperCase()}`;
  npEl.classList.add("on");
}

function tickProgress() {
  if (view !== "music" || !music.length) return;
  const drift = music.playing ? (performance.now() - music.posAt) / 1000 : 0;
  const pos = Math.min(music.length, music.posBase + drift);
  const pct = (pos / music.length) * 100;
  mFill.style.width = `${pct}%`;
  mHead.style.transform = `translateX(${mBar.clientWidth * pct / 100}px)`;
  mPos.textContent = mmss(pos);
}

async function pollMusic() {
  if (FIXTURES) {
    applyMusic({ available: true, status: "Playing", playing: true, title: "Ceremony",
                 artist: "New Order", album: "Substance", length: 265, position: 71, art: false });
    return;
  }
  if (!music.available) return;
  try {
    applyMusic(await fetch(`${BACKEND}/music/status`, { signal: AbortSignal.timeout(2500) })
      .then(r => r.json()));
  } catch (_) {}
}
function musicLoop() {
  if (FIXTURES || !music.available) return;
  setTimeout(async () => { await pollMusic(); musicLoop(); }, view === "music" ? 1000 : 6000);
}
async function musicCmd(cmd) {
  if (FIXTURES) return;
  try {
    const r = await fetch(`${BACKEND}/music/${cmd}`, { method: "POST" }).then(r => r.json());
    if (!r.ok) showToast(String(r.msg || "").toUpperCase() || copy("state.unavailable"));
  } catch (_) { showToast(copy("state.offline")); }
  pollMusic();
}

/* =========================================================
   INPUT — one set of intents, routed by whichever view is up.
   The same gestures arrive from the gamepad, a keyboard, and the TV remote
   (cecd.py turns CEC presses into these very keys).
   ========================================================= */
function onNav(dx, dy) {
  if (view === "home") { sel = (sel + dx + TILES.length) % TILES.length; refreshSel(); }
  else if (view === "tv") { if (dy) tvZap(dy); }
  else if (view === "grid") { if (!gridState.detail) gridMove(dx, dy); }
  else if (view === "music") { if (dx) musicCmd(dx > 0 ? "next" : "previous"); }
}
function onOk() {
  if (view === "home") openSelected();
  else if (view === "grid") { gridState.detail ? playSelected() : openDetail(); }
  else if (view === "music") musicCmd("playpause");
  else if (view === "tv") tvShow();          // re-show the bar
}
function onBack() {
  if (view === "grid" && gridState.detail) { closeDetail(); return; }
  if (view === "tv") tvStop();
  if (view !== "home") goBack();
}
function onDigit(d) { if (view === "tv") tvDigit(d); }

addEventListener("keydown", (e) => {
  if (e.key === "ArrowRight") onNav(1, 0);
  else if (e.key === "ArrowLeft") onNav(-1, 0);
  else if (e.key === "ArrowDown") onNav(0, 1);
  else if (e.key === "ArrowUp") onNav(0, -1);
  else if (e.key === "PageUp") onNav(0, -1);
  else if (e.key === "PageDown") onNav(0, 1);
  else if (e.key === "Enter") onOk();
  else if (e.key === "Escape" || e.key === "Backspace") onBack();
  else if (/^[0-9]$/.test(e.key)) onDigit(e.key);
});

const pad = { l: false, r: false, u: false, d: false, a: false, b: false };
function pollPads() {
  for (const gp of (navigator.getGamepads ? navigator.getGamepads() : [])) {
    if (!gp) continue;
    const ax = gp.axes[0] || 0, ay = gp.axes[1] || 0;
    const l = (gp.buttons[14]?.pressed) || ax < -0.5;
    const r = (gp.buttons[15]?.pressed) || ax > 0.5;
    const u = (gp.buttons[12]?.pressed) || ay < -0.5;
    const d = (gp.buttons[13]?.pressed) || ay > 0.5;
    const a = gp.buttons[0]?.pressed, b = gp.buttons[1]?.pressed;
    if (l && !pad.l) onNav(-1, 0);
    if (r && !pad.r) onNav(1, 0);
    if (u && !pad.u) onNav(0, -1);
    if (d && !pad.d) onNav(0, 1);
    if (a && !pad.a) onOk();
    if (b && !pad.b) onBack();
    Object.assign(pad, { l, r, u, d, a, b });
    break;
  }
}

/* =========================================================
   BOOT
   ========================================================= */
function drawHints() {
  const H = (pairs) => pairs.map(([k, v]) => `<span><b>${k}</b>&nbsp;&nbsp;${v}</span>`).join("");
  document.getElementById("homehints").innerHTML =
    H([["◂ ▸", copy("hints.navigate")], ["Ⓐ", copy("hints.open")], ["HOLD ⌂", copy("hints.home")]]);
  document.getElementById("gridhints").innerHTML =
    H([["◂ ▸ ▴ ▾", copy("hints.navigate")], ["Ⓐ", copy("hints.open")], ["Ⓑ", copy("hints.back")]]);
  document.getElementById("detailhints").innerHTML =
    H([["Ⓐ", copy("hints.play")], ["Ⓑ", copy("hints.back")]]);
  document.getElementById("mhints").innerHTML =
    H([["◂ ▸", copy("hints.track")], ["Ⓐ", copy("hints.playpause")], ["Ⓑ", copy("hints.back")]]);
  document.getElementById("wxhints").innerHTML = H([["Ⓑ", copy("hints.back")]]);
}

async function loadConfig() {
  if (FIXTURES) return;
  try { cfg = await fetch(BACKEND + "/config", { signal: AbortSignal.timeout(2500) }).then(r => r.json()); }
  catch (_) { showToast(copy("state.offline"), 4000); }
}

async function boot() {
  await loadTheme();
  /* Only the active view is in the layout; the rest are display:none so a
     hidden marquee is not animating behind a channel. */
  document.querySelectorAll(".view").forEach(v => {
    if (v.id !== "homeview") v.style.display = "none";
  });
  drawHints();
  buildMenu();
  drawClock(true);
  await loadConfig();
  loadBriefWeather();
  pollMusic();
  musicLoop();

  setInterval(drawClock, 1000);
  setInterval(tickProgress, 250);
  setInterval(pollPads, 50);          // 20Hz — rAF pins a core to read a d-pad
  setInterval(loadBriefWeather, 15 * 60 * 1000);
  addEventListener("resize", () => { drawClock(true); buildMenu(); });

  if (FIXTURES) showToast("FIXTURES · DEVELOPER MODE", 3000);

  /* ?view=grid&kind=show jumps straight to a screen. This exists for the
     render tests and for looking at one screen while working on it — it is
     navigation, not a data path, so it cannot fake anything the UI would
     otherwise have to fetch. */
  const q = new URLSearchParams(location.search);
  const want = q.get("view");
  if (want) {
    if (q.get("kind")) gridState.kind = q.get("kind");
    const i = TILES.findIndex(t => t.view === want && (!q.get("kind") || t.kind === q.get("kind")));
    if (i >= 0) sel = i;
    refreshSel();
    showView(want);
  }
}
boot();

/* Exposed for the headless render test (test/render.mjs) — it drives the
   real module rather than a copy, so the test cannot drift from the UI. */
Object.assign(globalThis, { showView, onNav, onOk, onBack, onDigit, THEME, dotSVG, fitDots });
