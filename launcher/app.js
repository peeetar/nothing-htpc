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
  // Review ratings are drawn as stars in the same matrix as everything else.
  // Filled and hollow have to be legible at four or five pixels a dot, which
  // is why the hollow one is a ring and not a thin outline of the filled one.
  // Review ratings are drawn as stars in the same matrix as everything else.
  // There is no hollow variant: at four pixels a dot an outline reads as
  // noise, so an unearned star is the same glyph in --faint. Colour carries
  // the distinction, shape does not have to.
  // An eight-point sparkle, not a five-point star: five points need an
  // asymmetric silhouette that a 5-wide matrix cannot hold, and every attempt
  // read as a cross or a blob. This one is symmetric, so it survives being
  // four pixels tall and still says "star".
  "★":["00100","10101","01110","11111","01110","10101","00100"],
};

/* Is every character in this string something the dot face can draw?
   The display matrix is Latin-only by design, and the content here is
   Macedonian Cyrillic and Greek — so a Greek heading handed to dotSVG comes
   out as a row of blank spaces, which is exactly how the bottom half of the
   news screen lost its source name. Anything that might not be Latin has to
   go through heading() instead. */
function dottable(text) {
  return [...String(text).toUpperCase()].every(c => GLYPHS[c] !== undefined);
}

/* A heading in the dot face when it can be, in the body font when it cannot.
   Same visual weight either way; the fallback is what keeps Cyrillic and
   Greek legible instead of silently blank. */
function heading(text, dotPx, opts = {}) {
  if (dottable(text)) return dotSVG(text, dotPx, opts);
  return `<span class="headingtext">${escapeHTML(text)}</span>`;
}

const DOT_STEP = 1.55;          // dotPx -> advance per dot, incl. the 0.55 gap
export function dotSVG(text, dotPx, opts = {}) {
  const gap = dotPx * (opts.gap ?? 0.55);
  const step = dotPx + gap;
  const charGap = step * (opts.charGap ?? 1.4);
  const ghost = opts.ghost ?? false;
  const color = opts.color ?? "var(--ink)";
  /* `assemble` staggers each dot's fade-in so a value doesn't just appear —
     it builds. This is the signature motion of the whole UI, and it is a
     theme value, so the `lite` profile can turn it off by setting it to 0. */
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

/* The inverse: how wide dotSVG will draw `n` characters at this dot size.
   The channel list needs its number column to be one width on every row —
   103 and 7 have to start their names in the same place — and the dot engine
   is the only thing that knows what that comes to in pixels. */
export function dotWidth(n, dotPx, charGap = 1.4) {
  const step = dotPx * DOT_STEP;
  return Math.max(0, n * step * (5 + charGap) - step * charGap);
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

/* Is this page actually composited over the video? Under fixtures there is no
   mpv to show through; ?opaque=1 is the manual override; otherwise the
   backend says, because only the session knows what compositor it is under. */
const FORCE_OPAQUE = new URLSearchParams(location.search).has("opaque");
function canComposite() {
  if (FIXTURES || FORCE_OPAQUE) return false;
  return cfg?.ui?.transparent !== false;
}

function showView(name, { push = true } = {}) {
  if (view === name) return;
  const from = document.getElementById(view + "view");
  const to = document.getElementById(name + "view");
  if (push) VIEW_STACK.push(view);
  view = name;

  /* TV is the one view that lets mpv through — but only where the compositor
     actually blends this page over mpv. Where it does not, a transparent body
     renders as the browser's WHITE default over a stream that is playing
     perfectly well behind it, which reads as a crash rather than as a missing
     feature. So it is a capability, not an assumption: the backend reports it
     (HTPC_UI_TRANSPARENT), fixtures never want it, and ?opaque=1 forces it off
     for a quick look. */
  document.body.classList.toggle("transparent", name === "tv" && canComposite());

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
  // Opening MUSIC is the one moment a player can be found from a standing
  // start, so it both polls now and restarts the loop the idle state stopped.
  if (name === "music") { pollMusic(); musicLoop(); }
  // Only the TV screen shows the picture, so it is the only one that has to
  // know what the picture is doing. Everywhere else the poll is off entirely
  // — the same rule the music loop follows, and for the same reason.
  if (name !== "tv") tvPollStop();
  if (name === "tv") { tvEnter(); tvPollStart(); }
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

let wxAt = 0;
async function weatherEnter() {
  document.getElementById("wxhead").textContent = copy("tiles.weather");
  if (!stale(wxAt)) return;
  const grid = document.getElementById("wxgrid");
  const days = THEME.layout["weather-days"] || 3;

  let failed = 0;
  const rows = await Promise.all(WX_CITIES.map(async (city) => {
    let daily, now;
    if (FIXTURES) {
      daily = { time: ["", "", ""], weather_code: [0, 3, 61],
                temperature_2m_max: [31, 28, 22], temperature_2m_min: [18, 17, 15],
                precipitation_probability_max: [0, 20, 80] };
      now = { temperature_2m: 27, weather_code: 0, wind_speed_10m: 11, apparent_temperature: 29 };
    } else {
      try {
        const j = await fetch(
          `https://api.open-meteo.com/v1/forecast?latitude=${city.lat}&longitude=${city.lon}` +
          `&current=temperature_2m,weather_code,wind_speed_10m,apparent_temperature` +
          `&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max` +
          `&forecast_days=${days}&timezone=auto`,
          { signal: AbortSignal.timeout(6000) }).then(r => r.json());
        daily = j.daily;
        now = j.current;
      } catch (_) {
        failed++;
        return `<div class="wxcity"><div class="wxlead"><div class="wxname">${city.name}</div>
          <div class="wxnow"><span class="cond">${copy("state.offline")}</span></div></div></div>`;
      }
    }

    const cells = [];
    for (let i = 0; i < days; i++) {
      const when = i === 0 ? copy("weather.today")
        : (daily.time[i] ? DAYS[new Date(daily.time[i]).getDay()].slice(0, 3) : `+${i}`);
      const rain = daily.precipitation_probability_max?.[i] ?? null;
      cells.push(`<div class="wxday">
        <span class="icon">${WX_ICON[wxKind(daily.weather_code[i])]}</span>
        <span>
          <div class="when">${when}</div>
          <div class="temps">${Math.round(daily.temperature_2m_max[i])}°
            <span class="lo">${Math.round(daily.temperature_2m_min[i])}°</span></div>
          ${rain !== null && rain > 0 ? `<div class="rain">${rain}%</div>` : ""}
        </span></div>`);
    }

    // What the screen was missing: now. Three days of forecast with no
    // current reading is an almanac, not a weather channel. The current
    // temperature gets the dot-matrix face — it is the number you came for.
    const nowBlock = `
      <div class="wxnow">
        <span class="big">${dotSVG(`${Math.round(now.temperature_2m)}°`, 4.2, { assemble: true })}</span>
        <span class="cond">${WMO[now.weather_code] || ""}</span>
      </div>
      <div class="wxextra">
        <span><b>${copy("weather.feels")}</b> ${Math.round(now.apparent_temperature)}°</span>
        <span><b>${copy("weather.wind")}</b> ${Math.round(now.wind_speed_10m)}</span>
      </div>`;

    return `<div class="wxcity">
              <div class="wxlead"><div class="wxname">${city.name}</div>${nowBlock}</div>
              <div class="wxdays">${cells.join("")}</div>
            </div>`;
  }));

  grid.innerHTML = rows.join("");
  // Every city offline means the network was, not that the forecast is.
  wxAt = failed < WX_CITIES.length ? Date.now() : 0;
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
  /* The label and the headlines are siblings in separate boxes, not layers.
     The headlines' box clips them, so a headline scrolling left stops existing
     at the label's edge instead of sliding out past it. */
  return `<div class="catrow">
            <span class="cat">${label}</span>
            <span class="marquee">
              <span class="track" data-count="${items.length}">${inner}${inner}</span>
            </span>
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

/* Both screens fetch once and remember *when*, not merely *that*.
   The bug this replaces: the latch was set even when every fetch failed, and
   neither screen had a refresh — so a box that reached the launcher before
   DHCP settled showed BACKEND OFFLINE on NEWS and WEATHER for as long as it
   stayed up, and the only cure was a page reload nobody at a sofa can ask
   for. A failed load now leaves the stamp at 0, so the next visit tries
   again, and a stale one is refetched even if it succeeded. */
const CONTENT_TTL = 10 * 60 * 1000;
const stale = (at) => !at || Date.now() - at > CONTENT_TTL;

let newsAt = 0;
async function newsEnter() {
  if (!stale(newsAt)) return;
  const top = document.getElementById("newstop");
  const bottom = document.getElementById("newsbottom");
  const nTop = THEME.layout["news-rows-top"] || 4;

  // heading(), not dotSVG(): the Greek source name has no dot glyphs.
  const head = (name, region) =>
    `<div class="sourcehead"><span class="name">${heading(name, 5, { charGap: 1.2 })}</span>` +
    (region ? `<span class="region">${region}</span>` : "") + `</div>`;

  top.innerHTML = head(copy("news.top-source"), "");
  bottom.innerHTML = head(copy("news.bottom-source"), copy("news.bottom-region"));

  let got = 0;
  const cats = NEWS_TOP_CATS.slice(0, nTop);
  for (const c of cats) {
    let items;
    if (FIXTURES) { items = FIXTURE_HEADLINES; got++; }
    else {
      try {
        items = (await fetchRSS(`https://time.mk/rss/${c.slug}`)).items.map(i => i.title);
        got++;
      } catch (_) { items = [copy("state.offline")]; }
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
    try {
      bItems = (await fetchRSS("https://www.makthes.gr/feed")).items.map(i => i.title);
      got++;
    } catch (_) { bItems = [copy("state.offline")]; }
  }
  bottom.insertAdjacentHTML("beforeend", marqueeRow(copy("news.bottom-region"), bItems));

  startMarquees(document.getElementById("newsview"));
  // One working feed is a screen worth keeping; none is a screen to retry.
  newsAt = got ? Date.now() : 0;
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

/* `mode` is the difference between the two jobs this screen does. It is the
   video-passthrough surface for *everything* mpv plays — a channel, and also
   a film that MOVIES just resolved — but only live TV owns the dial. Without
   the distinction, arriving here after a successful /play ran tvEnter() ->
   tvShow() -> tvLoad() and tuned a channel over the film 450 ms later, which
   is the whole reason a film never played to the end. */
const tv = {
  channels: [],
  idx: 0,
  digits: "",
  digitTimer: null,
  barTimer: null,
  loadTimer: null,
  state: null,        // null | "loading" | "no-signal"
  mode: "live",       // "live" | "ondemand"
  title: "",          // what is playing, when mode is "ondemand"
};

async function loadChannels() {
  if (FIXTURES) { tv.channels = FIXTURE_CHANNELS; return; }
  try {
    tv.channels = await fetch(`${BACKEND}/channels`, { signal: AbortSignal.timeout(3000) })
      .then(r => r.json());
  } catch (_) { tv.channels = []; showToast(copy("state.offline")); }
}

function tvEnter() {
  // The list is summoned, never arrived-at: entering TV shows the picture.
  chanListShow(false);
  /* A film is already playing, so nothing here may touch the player — above
     all not tvShow()'s debounced tvLoad(). The dial still has to be reachable
     though: Ⓐ opens the list over the film the same as it does over a
     channel, and an empty list cannot open, so fetch it and tune nothing. */
  if (tv.mode === "ondemand") {
    if (!tv.channels.length) loadChannels().then(() => { if (chanList.open) renderChanList(); });
    tvNowPlaying();
    return;
  }
  if (!tv.channels.length) { loadChannels().then(() => tvShow()); return; }
  tvShow();
}

/* The same bar the dial uses, saying what is on instead of which number it
   is. The title goes in the body font, never the dot face: it comes from a
   catalogue and can be any script (constraint 5). */
function tvNowPlaying() {
  const bar = document.getElementById("chanbar");
  document.getElementById("channum").innerHTML =
    heading(copy("tv.now-playing"), THEME.layout["bar-number-dot"] || 5.5, { assemble: true });
  document.getElementById("channame").textContent = tv.title;
  bar.classList.add("show");
  clearTimeout(tv.barTimer);
  tv.barTimer = setTimeout(() => bar.classList.remove("show"), THEME.motion["bar-hold"]);
  setChanState(null);
}

function tvShow() {
  const ch = tv.channels[tv.idx];
  if (!ch) { setChanState("empty"); return; }
  // Reaching here at all means the dial was used — zapped, typed or picked —
  // so whatever was playing on demand is being replaced by a channel.
  tv.mode = "live";
  tv.title = "";
  const bar = document.getElementById("chanbar");
  document.getElementById("channum").innerHTML =
    dotSVG(String(ch.no), THEME.layout["bar-number-dot"] || 5.5, { assemble: true });
  document.getElementById("channame").textContent = ch.name;
  bar.classList.add("show");
  clearTimeout(tv.barTimer);
  tv.barTimer = setTimeout(() => bar.classList.remove("show"), THEME.motion["bar-hold"]);
  // Typing a number while the list is open moves what is live under it.
  if (chanList.open) renderChanList();

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

/* What the picture is actually doing, once every second while the TV screen
   is up and never otherwise.

   Everything for this existed and nothing used it: `/player/state` is fully
   implemented and had no caller, `shim.lua` published {failed, attempts, url}
   that nothing read, and `copy("state.buffering")` was unreachable. The cost
   of that was measured on 20 August 2026 — a film resolved to a torrent with
   a dead swarm, `/play` reported success, the box switched to the TV screen
   and sat on black indefinitely with nothing on screen to say why. A stalled
   stream and a working one looked identical.

   Deliberately does not touch the state while the debounced tvLoad() is
   still pending: "LOADING" is what the keypress already said, and mpv is
   still on the previous channel until then. */
let tvPollTimer = null;
async function tvPoll() {
  if (view !== "tv" || FIXTURES) return;
  try {
    const s = await fetch(`${BACKEND}/player/state`, { signal: AbortSignal.timeout(2000) })
      .then(r => r.json());
    if (view !== "tv" || tv.state === "loading") return;
    if (!s.available || s.idle) { setChanState("no-signal"); return; }
    // The shim knows a failure the player itself cannot report: a live URL
    // that opened and then died is retried behind our back.
    if (s.shim && s.shim.failed) { setChanState("no-signal"); return; }
    if (s.buffering || (s.position === 0 && s.duration === 0)) {
      setChanState("buffering");
      return;
    }
    setChanState(null);
  } catch (_) { /* the offline toast covers a backend that went away */ }
}

function tvPollStart() {
  clearInterval(tvPollTimer);
  tvPollTimer = setInterval(tvPoll, 1000);
}
function tvPollStop() {
  clearInterval(tvPollTimer);
  tvPollTimer = null;
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
  chanListShow(false);
  tv.mode = "live";
  tv.title = "";
  if (!FIXTURES) { try { await fetch(`${BACKEND}/player/stop`, { method: "POST" }); } catch (_) {} }
}

/* ---------------------------------------------------------
   THE CHANNEL LIST
   Zapping and the keypad only work if you already know the dial. This is the
   dial made visible: it slides in over the picture, which keeps playing
   behind it — the whole reason the launcher is one transparent page rather
   than a menu that replaces the video.

   Red marks the channel that is on. The glow marks the one the cursor is
   over. They are usually not the same row, which is exactly why the design
   language spends its one accent on state and never on focus.
   --------------------------------------------------------- */
const chanList = { open: false, sel: 0, top: 0 };

function chanListShow(on) {
  chanList.open = on && tv.channels.length > 0;
  document.getElementById("chanlist").classList.toggle("on", chanList.open);
  if (!chanList.open) return;
  chanList.sel = tv.idx;                 // always opens on what is playing
  renderChanList();
}

function renderChanList() {
  const rows = THEME.layout["channel-list-rows"] || 9;
  const n = tv.channels.length;
  chanList.sel = Math.max(0, Math.min(chanList.sel, n - 1));
  if (chanList.sel < chanList.top) chanList.top = chanList.sel;
  if (chanList.sel > chanList.top + rows - 1) chanList.top = chanList.sel - rows + 1;
  chanList.top = Math.max(0, Math.min(chanList.top, Math.max(0, n - rows)));

  const dot = THEME.layout["channel-list-dot"] || 2.8;
  // One number column, wide enough for the longest number on the dial, so
  // every name starts at the same x whether its channel is 7 or 107.
  const noW = Math.ceil(dotWidth(
    Math.max(1, ...tv.channels.map(c => String(c.no).length)), dot));

  document.getElementById("chanrows").innerHTML =
    tv.channels.slice(chanList.top, chanList.top + rows).map((c, i) => {
      const idx = chanList.top + i;
      // Channel names come from a hand-edited m3u and are not all Latin, so
      // only the number goes to the dot face.
      return `<div class="chanrow${idx === chanList.sel ? " sel" : ""}` +
             `${idx === tv.idx && tv.mode === "live" ? " live" : ""}" data-i="${idx}">
        <span class="cno" style="width:${noW}px">${dotSVG(String(c.no), dot)}</span>
        <span class="cname">${escapeHTML(c.name)}</span>
        <span class="clive"></span>
      </div>`;
    }).join("");

  document.getElementById("chanrows").querySelectorAll(".chanrow").forEach(r =>
    r.addEventListener("click", () => { chanList.sel = +r.dataset.i; chanListPick(); }));

  document.getElementById("chancount").textContent = `${chanList.sel + 1}/${n}`;
}

function chanListMove(dy) {
  const n = tv.channels.length;
  if (!n) return;
  // Wraps, like zapping does: the dial is a loop and the list is the dial.
  chanList.sel = (chanList.sel + dy + n) % n;
  renderChanList();
}

function chanListPick() {
  tv.idx = chanList.sel;
  chanListShow(false);
  tvShow();
}

/* =========================================================
   MOVIES / SHOWS — one poster grid, switched by kind.
   Catalogue comes from the backend's Stremio-shaped client (Cinemeta);
   pressing OK resolves a stream and hands it to mpv.
   ========================================================= */
/* Enough fixture titles to span more than one page, so the paging and the
   in-page scroll are both exercised without a backend. */
const FIXTURE_LIBRARY = `Dune: Part Two|2024|166|8.5|Paul Atreides unites with the Fremen to wage war against House Harkonnen.
Poor Things|2023|141|8.0|A young woman brought back to life by an unorthodox scientist runs away with a lawyer.
Oppenheimer|2023|180|8.4|The story of the American scientist who helped develop the atomic bomb.
The Zone of Interest|2023|105|7.4|The commandant of Auschwitz and his wife build a life beside the camp wall.
Anatomy of a Fall|2023|152|7.7|A woman is suspected of her husband's death; their blind son faces a moral dilemma.
Past Lives|2023|105|7.8|Two childhood friends reunite in New York two decades after being separated.
Killers of the Flower Moon|2023|206|7.6|Members of the Osage tribe are murdered under mysterious circumstances.
The Holdovers|2023|133|7.9|A teacher remains at a New England prep school over the winter holidays.
Fallen Leaves|2023|81|7.4|Two lonely people meet by chance in the Helsinki night.
Perfect Days|2023|124|7.9|A Tokyo toilet cleaner finds beauty in his structured daily routine.
May December|2023|117|6.7|An actress studies the woman she will portray in a film about a scandal.
Godzilla Minus One|2023|125|7.7|Postwar Japan faces a new devastation in the form of a giant monster.
The Brutalist|2024|215|8.0|An architect flees postwar Europe to rebuild his life and his practice.
Nickel Boys|2024|140|7.5|Two boys endure a reform school in Jim Crow-era Florida.
Flow|2024|85|7.9|A cat survives a flood aboard a boat with other animals.
Conclave|2024|120|7.4|A cardinal runs the secretive election of a new pope.
The Substance|2024|141|7.3|A fading star takes a black-market drug that generates a younger self.
Challengers|2024|131|7.1|Three tennis players' lives intertwine over years of matches.
La Chimera|2023|130|7.0|A British archaeologist joins a band of Italian grave robbers.
Evil Does Not Exist|2023|106|7.3|A village confronts a glamping development in the woods above it.
All of Us Strangers|2023|105|7.6|A screenwriter meets a neighbour and returns to his childhood home.
Society of the Snow|2023|144|7.8|Survivors of a plane crash in the Andes fight to stay alive.
The Boy and the Heron|2023|124|7.4|A boy enters a fantastical world after losing his mother.
Monster|2023|126|7.9|A single mother, a teacher and a boy tell the same story differently.
Robot Dreams|2023|102|7.6|A dog builds a robot companion in 1980s Manhattan.
The Taste of Things|2023|135|7.1|A cook and a gourmet share thirty years of meals.
Green Border|2023|147|7.5|Migrants are pushed back and forth across a forest frontier.
Do Not Expect Too Much|2023|163|7.0|A production assistant drives across Bucharest for a safety video.
Close Your Eyes|2023|169|7.2|A director confronts an unfinished film and a vanished actor.
The Beast|2023|146|6.8|Lovers meet across three centuries and one purification of feeling.
Dahomey|2024|68|6.9|Twenty-six royal treasures return from Paris to Benin.
Hard Truths|2024|97|7.1|A woman's fury with the world strains her family.
Grand Tour|2024|129|6.6|A colonial officer flees his fiancée across Asia in 1918.
Caught by the Tides|2024|111|6.7|Two decades of a woman's life traced through a changing China.
Universal Language|2024|89|7.4|Strangers in a Winnipeg reimagined as an Iranian city cross paths.
Anora|2024|139|7.5|A Brooklyn sex worker marries the son of a Russian oligarch.`
  .split("\n").map((line, i) => {
    const [title, year, runtime, rating, plot] = line.split("|");
    return { id: `fixture${i}`, title, year, runtime: +runtime, rating, plot, poster: "" };
  });

const FIXTURE_CREDITS = {
  director: ["Denis Villeneuve"],
  producer: ["Mary Parent", "Cale Boyter"],
  writer: ["Jon Spaihts", "Frank Herbert"],
  cast: ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson", "Javier Bardem", "Josh Brolin"],
};
/* The first one is deliberately far longer than the panel — a real TMDB
   review runs to hundreds of words, and a fixture set where everything fits
   in four lines would let the auto-scroll rot without any test noticing. */
const FIXTURE_REVIEWS = [
  { author: "cinemabuff", rating: 9,
    text: "A rare sequel that widens rather than repeats. The sound design does as much narrative work as the script, and the desert is photographed as a character rather than a backdrop. What struck me hardest on a second viewing is how little of it is exposition: the politics are legible entirely through blocking and costume, and a film this large trusting an audience that much is close to unheard of now. The middle hour, which everyone warned me sagged, is where it is doing its most careful work — a slow accumulation of small betrayals that only reads as inevitable in hindsight. Whether the ending lands depends on whether you have understood that it was never going to be a triumph, and the film has been telling you that from its first shot." },
  { author: "marisol_v", rating: 7,
    text: "Visually overwhelming and emotionally cool. I admired almost every frame and felt held at arm's length by all of them, which may well be the point." },
  { author: "j_okafor", rating: 10,
    text: "The best argument for seeing films in a cinema that I have had in a decade. Everything is scaled to overwhelm, and it earns the scale." },
];

/* Shows, with episodes, so the season tabs and the episode window are both
   exercised on a laptop. Season counts are per title — a one-season show and
   a three-season one look different enough that a tab strip bug shows up. */
const FIXTURE_EPISODE_NAMES = [
  "Good News About Hell", "Half Loop", "In Perpetuity", "The You You Are",
  "The Grim Barbarity of Optics", "Hide and Seek", "Defiant Jazz",
  "What's for Dinner?", "The We We Are", "Hello, Ms. Cobel",
  "Goodbye, Mrs. Selvig", "Woe's Hollow",
];

function fixtureEpisodes(id, seasons) {
  const out = [];
  seasons.forEach((n, i) => {
    const season = i + 1;
    for (let e = 1; e <= n; e++) {
      out.push({
        id: `${id}:${season}:${e}`,
        season, episode: e,
        title: FIXTURE_EPISODE_NAMES[(e - 1) % FIXTURE_EPISODE_NAMES.length],
        released: `${2020 + season}-0${1 + (e % 9)}-${String(1 + ((e * 7) % 27)).padStart(2, "0")}`,
      });
    }
  });
  return out;
}

const FIXTURE_SHOWS = `Severance|2022|8.7|9,10|Employees at a biotech firm undergo a procedure that divides their work and personal memories.
Shogun|2024|8.6|10|A English sailor is shipwrecked in feudal Japan as a lord fights for his life.
The Bear|2022|8.6|8,10,10|A fine-dining chef returns to Chicago to run his family's sandwich shop.
Slow Horses|2022|8.2|6,6,6|Rejected MI5 agents work under a brilliant and disgusting boss.
Andor|2022|8.4|12|The birth of a rebellion, five years before the Death Star.
Dark|2017|8.7|10,8,8|Four families search for a missing child and find a town's secret.
The Leftovers|2014|8.3|10,8,8|Three years after two percent of the world vanished, the ones left behind.
Chernobyl|2019|9.3|5|The 1986 nuclear accident and the people who contained it.
Better Call Saul|2015|9.0|10,10,10|A small-time lawyer becomes the criminal attorney Saul Goodman.
Fleabag|2016|8.7|6,6|A woman in London navigates grief, family and a hopeless love life.
Succession|2018|8.9|10,10,9|A media dynasty's children circle their father's failing empire.
Ted Lasso|2020|8.8|10,12|An American football coach is hired to manage an English soccer club.`
  .split("\n").map((line, i) => {
    const [title, year, rating, seasons, plot] = line.split("|");
    const id = `ttfixture${i}`;
    return { id, title, year, rating, plot, poster: "", runtime: 0,
             episodes: fixtureEpisodes(id, seasons.split(",").map(Number)) };
  });

function fixtureItems(kind) {
  return (kind === "movie" ? FIXTURE_LIBRARY : FIXTURE_SHOWS).slice();
}

/* MOVIES and SHOWS are one view switched by `kind`, so this holds the state
   of whichever is on screen — and `shown` records which that is. Everything
   in BROWSE is per-catalogue and gets parked in `gridParked` on the way out;
   `kind`, `detail` and `busy` belong to the view itself and do not.

   Keeping one live object rather than indexing every read by kind is what
   lets the fifty-odd call sites below stay as they are. The bug it replaces:
   `loaded` was per-kind while `items` was shared, so MOVIES -> SHOWS ->
   MOVIES skipped the reset and drew the shows list under the MOVIES title. */
const BROWSE = ["items", "page", "sel", "topRow", "exhausted"];

const gridState = {
  kind: "movie",
  shown: null,         // which kind the BROWSE fields currently describe
  items: [],           // everything loaded so far, across pages
  page: 0,
  sel: 0,              // index into `items`, not into the page
  topRow: 0,           // first row visible inside the viewport
  detail: false,
  busy: false,
  exhausted: false,
};

const gridParked = {};   // kind -> the BROWSE fields, as last seen

/* Park what is on screen and bring back the other catalogue, so switching
   between MOVIES and SHOWS keeps each one's cursor, page and loaded items
   instead of showing one under the other's title. */
function gridSwap(kind) {
  if (gridState.shown === kind) return true;
  if (gridState.shown) {
    gridParked[gridState.shown] = Object.fromEntries(BROWSE.map(k => [k, gridState[k]]));
  }
  const back = gridParked[kind];
  Object.assign(gridState, back || { items: [], page: 0, sel: 0, topRow: 0, exhausted: false });
  gridState.shown = kind;
  return Boolean(back);
}

function perPage() {
  return (THEME.layout["grid-columns"] || 6) * (THEME.layout["grid-rows-per-page"] || 5);
}

/* Fetch until we have at least `upto` items, or upstream runs out. Cinemeta
   pages with `skip`, and a page that comes back empty (or repeats what we
   already have) is the end of the catalogue. */
async function ensureLoaded(upto) {
  if (FIXTURES || gridState.exhausted || gridState.busy) return;
  if (gridState.items.length >= upto) return;
  /* Bound to the catalogue it started on: gridSwap can point gridState at the
     other one mid-fetch, and a page of films appended to the series list is
     the same class of bug as drawing one under the other's title. */
  const kind = gridState.kind;
  gridState.busy = true;
  try {
    while (gridState.items.length < upto && !gridState.exhausted) {
      const skip = gridState.items.length;
      const batch = await fetch(`${BACKEND}/catalog/${kind}?skip=${skip}`,
        { signal: AbortSignal.timeout(10000) }).then(r => r.json());
      if (gridState.shown !== kind) return;
      if (!Array.isArray(batch) || !batch.length) { gridState.exhausted = true; break; }
      const seen = new Set(gridState.items.map(i => i.id));
      const fresh = batch.filter(i => !seen.has(i.id));
      if (!fresh.length) { gridState.exhausted = true; break; }
      gridState.items.push(...fresh);
    }
  } catch (_) {
    if (gridState.shown !== kind) return;
    showToast(copy("state.offline"));
    gridState.exhausted = true;
  } finally {
    gridState.busy = false;
  }
}

async function gridEnter() {
  document.getElementById("gridtitle").innerHTML =
    dotSVG(copy(gridState.kind === "movie" ? "tiles.movies" : "tiles.shows"), 6, { assemble: true });

  if (!gridSwap(gridState.kind)) {
    // First time in this catalogue: gridSwap left the fields blank, so fill
    // them. Coming back to one, it restored them and there is nothing to do.
    gridState.items = FIXTURES ? fixtureItems(gridState.kind) : [];
    gridState.exhausted = FIXTURES;
    await ensureLoaded(perPage());
  }
  renderGrid();
}

/* Rows are measured, not assumed: the card height comes from the poster
   aspect ratio against a column width that is a fraction of the viewport, so
   only the browser knows what it worked out to. */
function rowMetrics() {
  const inner = document.getElementById("gridinner");
  const card = inner.querySelector(".card");
  if (!card) return { row: 0, visible: 1 };
  const gap = parseFloat(getComputedStyle(inner).rowGap) || 0;
  const row = card.getBoundingClientRect().height + gap;
  const box = document.getElementById("grid").clientHeight;
  return { row, visible: Math.max(1, Math.floor((box + gap) / row)) };
}

function renderGrid() {
  const inner = document.getElementById("gridinner");
  const cols = THEME.layout["grid-columns"] || 6;
  const size = perPage();
  const start = gridState.page * size;
  const items = gridState.items.slice(start, start + size);

  document.getElementById("gridcount").textContent =
    gridState.items.length ? String(gridState.items.length) : copy("state.empty");
  const pages = Math.max(1, Math.ceil(gridState.items.length / size));
  document.getElementById("gridpage").textContent =
    pages > 1 ? `${copy("detail.page")} ${gridState.page + 1}/${gridState.exhausted ? pages : "·"}` : "";

  inner.innerHTML = items.map((it, i) => `
    <div class="card${start + i === gridState.sel ? " sel" : ""}" data-i="${start + i}">
      ${it.poster ? `<img src="${escapeHTML(it.poster)}" alt="" loading="lazy">` : ""}
      <div class="stub"><span>${escapeHTML(it.title)}</span>${it.year ? `<span class="y">${escapeHTML(it.year)}</span>` : ""}</div>
    </div>`).join("");

  inner.querySelectorAll(".card").forEach(c =>
    c.addEventListener("click", () => { gridState.sel = +c.dataset.i; renderGrid(); openDetail(); }));

  // Keep the cursor's row inside the viewport, then slide the grid to match.
  const { row, visible } = rowMetrics();
  const cursorRow = Math.floor((gridState.sel - start) / cols);
  if (cursorRow < gridState.topRow) gridState.topRow = cursorRow;
  const lastRow = Math.max(0, Math.ceil(items.length / cols) - 1);
  if (cursorRow > gridState.topRow + visible - 1) gridState.topRow = cursorRow - visible + 1;
  gridState.topRow = Math.max(0, Math.min(gridState.topRow, Math.max(0, lastRow - visible + 1)));
  inner.style.transform = `translateY(${-gridState.topRow * row}px)`;
}

async function gridMove(dx, dy) {
  const cols = THEME.layout["grid-columns"] || 6;
  const size = perPage();
  if (!gridState.items.length) return;

  const start = gridState.page * size;
  const inPage = gridState.sel - start;

  if (dx) {
    const n = inPage + dx;
    // Left/right stays inside the page: a horizontal move that turned a page
    // would make the last card of a row jump the cursor somewhere unrelated.
    if (n < 0 || n >= Math.min(size, gridState.items.length - start)) return;
    gridState.sel = start + n;
    renderGrid();
    return;
  }

  if (dy > 0) {
    const n = inPage + cols;
    if (n < Math.min(size, gridState.items.length - start)) {
      gridState.sel = start + n;
      renderGrid();
      return;
    }
    // Past the bottom of the page — turn to the next one, loading if needed.
    await ensureLoaded((gridState.page + 2) * size);
    if (gridState.items.length <= start + size) return;      // no next page
    gridState.page += 1;
    gridState.topRow = 0;
    gridState.sel = Math.min(gridState.page * size + (inPage % cols),
                             gridState.items.length - 1);
    renderGrid();
    return;
  }

  if (dy < 0) {
    const n = inPage - cols;
    if (n >= 0) {
      gridState.sel = start + n;
      renderGrid();
      return;
    }
    if (gridState.page === 0) return;
    gridState.page -= 1;
    const prevStart = gridState.page * size;
    // Land on the same column in the last row of the previous page, and show
    // that row rather than snapping the viewport back to the top.
    const rows = Math.ceil(size / cols);
    gridState.sel = Math.min(prevStart + (rows - 1) * cols + (inPage % cols),
                             prevStart + size - 1);
    gridState.topRow = rows;      // renderGrid clamps this into range
    renderGrid();
  }
}

/* Stars as dots. A 0-10 score becomes five glyphs, so a rating reads at a
   glance from the sofa instead of being a number to parse. */
function starDots(outOf10, dotPx = 4.4) {
  const filled = Math.max(0, Math.min(5, Math.round((Number(outOf10) || 0) / 2)));
  const on = "★".repeat(filled), off = "★".repeat(5 - filled);
  return (on ? dotSVG(on, dotPx, { charGap: 0.9 }) : "") +
         (off ? dotSVG(off, dotPx, { charGap: 0.9, color: "var(--faint)" }) : "");
}

const reviews = { list: [], i: 0, timers: [] };

function stopReviews() {
  reviews.timers.forEach(clearTimeout);
  reviews.timers = [];
}
function later(fn, ms) { reviews.timers.push(setTimeout(fn, ms)); }

/* One review at a time, held then cross-faded. Same idea as the news
   marquee — the panel is not tall enough for three reviews, but it is tall
   enough for three reviews one after another.

   And if one review is taller than the panel, it scrolls inside it. This used
   to clip at the fourth line and fade the rest out, which loses the end of
   every review long enough to be worth reading. Nothing advances to the next
   review until this one has been all the way down and (if it is the only one)
   back: a fixed hold over a scrolling paragraph is the same bug with extra
   steps. */
function runReview() {
  stopReviews();
  const el = document.getElementById("rstack").children[reviews.i];
  if (!el) return;
  const body = el.querySelector(".rbody");
  const text = el.querySelector(".rtext");
  if (!body || !text) return;

  const hold = THEME.motion["review-hold"] || 7000;
  const pause = THEME.motion["review-scroll-hold"] || 2400;
  const speed = THEME.motion["review-scroll-px-per-s"] || 13;

  text.style.transition = "none";
  text.style.transform = "translateY(0)";
  body.classList.remove("scrolled", "end");

  /* Reading scrollHeight flushes the reset above, so the measurement is of
     this review at the top and not of wherever the last one had crawled to. */
  const over = Math.max(0, text.scrollHeight - body.clientHeight);
  body.classList.toggle("more", over > 1);
  if (over <= 1) { later(nextReview, hold); return; }

  const travel = Math.max(THEME.motion.view || 240, (over / speed) * 1000);
  const glide = (to, ms) => {
    text.style.transition = `transform ${ms}ms linear`;
    text.style.transform = `translateY(${to}px)`;
  };

  later(() => {
    body.classList.add("scrolled");
    glide(-over, travel);
    later(() => {
      body.classList.add("end");              // at the bottom: nothing to fade
      later(() => {
        if (reviews.list.length > 1) { nextReview(); return; }
        body.classList.remove("end");
        glide(0, travel);
        later(() => { body.classList.remove("scrolled"); runReview(); }, travel);
      }, pause);
    }, travel);
  }, pause);
}

function nextReview() {
  if (!reviews.list.length) return;
  reviews.i = (reviews.i + 1) % reviews.list.length;
  showReview();
}

function showReview() {
  const stack = document.getElementById("rstack");
  [...stack.children].forEach((el, i) => el.classList.toggle("on", i === reviews.i));
  document.getElementById("rdots").innerHTML =
    reviews.list.map((_, i) => `<i class="${i === reviews.i ? "on" : ""}"></i>`).join("");
  runReview();
}

function renderReviews(list) {
  const box = document.getElementById("dreviews");
  const stack = document.getElementById("rstack");
  reviews.list = list || [];
  reviews.i = 0;
  stopReviews();

  if (!reviews.list.length) {
    // No key, a film nobody has written about, or a show — which spends this
    // half of the panel on seasons instead. The section disappears rather than
    // showing an empty frame with a heading over it.
    box.style.display = "none";
    stack.innerHTML = "";
    return;
  }
  box.style.display = "flex";
  document.getElementById("rlabel").textContent = copy("detail.reviews");
  // .rtext is what moves; .rbody is the window it moves behind.
  stack.innerHTML = reviews.list.map(r => `
    <div class="review">
      <div class="rtop">
        <span class="rstars">${starDots(r.rating)}</span>
        <span class="rauthor">${escapeHTML(r.author || "")}</span>
      </div>
      <div class="rbody"><div class="rtext">${escapeHTML(r.text || "")}</div></div>
    </div>`).join("");
  showReview();
}

/* =========================================================
   SHOWS — season tabs and an episode chooser, in the space a film spends on
   reviews. Cinemeta hands every episode over with the id Torrentio wants
   ("tt11198330:1:3"), so choosing one here is the whole of the work: /play
   takes that id unchanged.

   ◂ ▸ moves between seasons, ▴ ▾ between episodes. No focus to juggle between
   the two — on a d-pad, an axis that means one thing everywhere is worth more
   than a tab strip you can enter and leave.
   ========================================================= */
const series = { episodes: [], seasons: [], si: 0, ei: 0, top: 0 };

function seasonEpisodes() {
  const s = series.seasons[series.si];
  return series.episodes.filter(e => e.season === s);
}

function hideSeasons() {
  document.getElementById("dseasons").style.display = "none";
}

function loadEpisodes(list) {
  series.episodes = list || [];
  // Specials (season 0) last, wherever the upstream put them.
  series.seasons = [...new Set(series.episodes.map(e => e.season))]
    .sort((a, b) => (a === 0) - (b === 0) || a - b);
  series.si = 0; series.ei = 0; series.top = 0;
  renderSeasons();
}

function renderSeasons() {
  const box = document.getElementById("dseasons");
  const tabs = document.getElementById("stabs");
  const list = document.getElementById("eplist");
  box.style.display = "flex";
  document.getElementById("slabel").textContent = copy("detail.season");

  if (!series.episodes.length) {
    tabs.innerHTML = "";
    list.innerHTML = `<div class="empty">${copy("state.empty")}</div>`;
    document.getElementById("scount").textContent = "";
    return;
  }

  tabs.innerHTML = series.seasons.map((s, i) =>
    `<span class="stab${i === series.si ? " sel" : ""}" data-s="${i}">` +
    `${s === 0 ? copy("detail.specials") : String(s)}</span>`).join("");
  tabs.querySelectorAll(".stab").forEach(t => t.addEventListener("click", () => {
    series.si = +t.dataset.s; series.ei = 0; series.top = 0; renderSeasons();
  }));

  const eps = seasonEpisodes();
  const rows = THEME.layout["detail-episode-rows"] || 7;
  // Windowed, not scrolled: a show with 700 episodes must cost the same to
  // draw as one with 8, and only `rows` of them are ever on screen anyway.
  series.ei = Math.max(0, Math.min(series.ei, eps.length - 1));
  if (series.ei < series.top) series.top = series.ei;
  if (series.ei > series.top + rows - 1) series.top = series.ei - rows + 1;
  series.top = Math.max(0, Math.min(series.top, Math.max(0, eps.length - rows)));

  list.innerHTML = eps.slice(series.top, series.top + rows).map((e, i) => {
    const idx = series.top + i;
    // Episode titles are often missing on a just-aired season; the number is
    // what the box always knows, so it is what the fallback says.
    const name = e.title || `${copy("detail.episode")} ${e.episode}`;
    return `<div class="eprow${idx === series.ei ? " sel" : ""}" data-i="${idx}">
      <span class="epno">${String(e.episode).padStart(2, "0")}</span>
      <span class="epname">${escapeHTML(name)}</span>
      ${e.released ? `<span class="epdate">${escapeHTML(e.released)}</span>` : ""}
    </div>`;
  }).join("");

  list.querySelectorAll(".eprow").forEach(r => r.addEventListener("click", () => {
    series.ei = +r.dataset.i; renderSeasons(); playSelected();
  }));

  document.getElementById("scount").textContent =
    eps.length ? `${copy("detail.episode")} ${series.ei + 1}/${eps.length}` : copy("state.empty");

  // Keep the open season's tab in view when a show has more seasons than fit.
  const selTab = tabs.querySelector(".stab.sel");
  if (selTab) {
    tabs.scrollLeft = Math.max(
      0, selTab.offsetLeft - tabs.clientWidth / 2 + selTab.clientWidth / 2);
  }
}

function seriesMove(dx, dy) {
  if (!series.episodes.length) return;
  if (dx) {
    const n = series.si + dx;
    if (n < 0 || n >= series.seasons.length) return;
    series.si = n; series.ei = 0; series.top = 0;
  }
  if (dy) {
    const n = series.ei + dy;
    if (n < 0 || n >= seasonEpisodes().length) return;
    series.ei = n;
  }
  renderSeasons();
}

function renderCredits(c) {
  const el = document.getElementById("dcredits");
  const rows = [];
  const line = (role, names) => {
    if (!names || !names.length) return;
    const n = names.slice(0, role === "cast" ? (THEME.layout["detail-cast"] || 5) : 3);
    rows.push(`<div class="row"><span class="role">${copy("detail." + role)}</span>` +
              `<span class="who">${escapeHTML(n.join(", "))}</span></div>`);
  };
  line("director", c.director);
  line("producer", c.producer);
  line("writer", c.writer);
  line("cast", c.cast);
  el.innerHTML = rows.join("");
}

async function openDetail() {
  const it = gridState.items[gridState.sel];
  if (!it) return;
  gridState.detail = true;
  document.getElementById("dposter").innerHTML =
    it.poster ? `<img src="${escapeHTML(it.poster)}" alt="">` : "";
  // A film title can be in any script — heading() falls back to the body font
  // rather than drawing a row of blanks.
  const w = innerWidth * 0.5;
  document.getElementById("dtitle").innerHTML =
    heading(it.title, fitDots(it.title, w, { max: 9 }), { assemble: true });
  const meta = [];
  if (it.year) meta.push(escapeHTML(it.year));
  if (it.runtime) meta.push(`${Math.floor(it.runtime / 60)}H ${it.runtime % 60}M`);
  if (it.rating) meta.push(`<span class="rating">★ ${escapeHTML(it.rating)}</span>`);
  document.getElementById("dmeta").innerHTML = meta.map(m => `<span>${m}</span>`).join("");
  document.getElementById("dplot").textContent = it.plot || "";

  /* The bottom half of the panel belongs to whichever of the two the kind
     calls for: a film's reviews, or a show's seasons and episodes. Only ever
     one of them, so renderReviews([]) is how the film half is put away. */
  const isShow = gridState.kind !== "movie";
  drawDetailHints(isShow);

  // Draw what the grid already knows, then fill in credits, reviews and
  // episodes when they arrive. The panel must never wait on the network to
  // appear — a detail screen that opens half a second after Ⓐ feels broken.
  renderCredits(it.credits || {});
  if (isShow) { renderReviews([]); loadEpisodes(it.episodes || []); }
  else { hideSeasons(); renderReviews(it.reviews || []); }
  document.getElementById("detail").classList.add("on");

  if (FIXTURES) {
    renderCredits(FIXTURE_CREDITS);
    if (isShow) loadEpisodes(it.episodes || []);
    else renderReviews(FIXTURE_REVIEWS.slice(0, THEME.layout["detail-reviews"] || 3));
    return;
  }
  if (it.credits) return;                       // already enriched
  try {
    const full = await fetch(`${BACKEND}/meta/${gridState.kind}/${it.id}`,
      { signal: AbortSignal.timeout(9000) }).then(r => r.json());
    Object.assign(it, {
      plot: full.plot || it.plot,
      runtime: full.runtime || it.runtime,
      credits: full.credits || {},
      reviews: (full.reviews || []).slice(0, THEME.layout["detail-reviews"] || 3),
      // Not sliced: the chooser windows them itself, and a show's episode list
      // is the point of the screen rather than a garnish on it.
      episodes: full.episodes || [],
    });
    // The cursor may have moved on while this was in flight.
    if (gridState.detail && gridState.items[gridState.sel] === it) {
      document.getElementById("dplot").textContent = it.plot || "";
      renderCredits(it.credits);
      if (isShow) loadEpisodes(it.episodes);
      else renderReviews(it.reviews);
    }
  } catch (_) { /* keep what the grid gave us */ }
}

function closeDetail() {
  gridState.detail = false;
  stopReviews();
  // The picker belongs to the panel underneath it, so it never outlives it.
  sourcesShow(false);
  document.getElementById("detail").classList.remove("on");
}

/* What Ⓐ is about to play: a film by its own id, an episode by the id the
   chooser is sitting on — "tt11198330:1:3", which is what the stream addons
   index series by, so nothing has to be resolved twice. */
function playTarget() {
  const it = gridState.items[gridState.sel];
  if (!it) return null;
  if (gridState.kind === "movie") return { id: it.id, what: it.title };
  const e = seasonEpisodes()[series.ei];
  if (!e) return null;
  return { id: e.id, what: `${it.title} · S${e.season} E${e.episode}` };
}

async function playSelected(index = 0) {
  const t = playTarget();
  if (!t) { showToast(copy("state.empty")); return; }

  if (FIXTURES) { showToast(`${copy("state.resolving")} · ${t.what.toUpperCase()}`); return; }
  showToast(copy("state.resolving"), 30000);
  try {
    const r = await fetch(`${BACKEND}/play`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ kind: gridState.kind, id: t.id, index }),
    }).then(r => r.json());
    if (r.ok) {
      sources.playing = index;
      sources.forId = t.id;
      sourcesShow(false);
      closeDetail();
      showToast(`${copy("state.playing")}`, 1500);
      /* TV is the passthrough surface, not the live dial — say so before
         going there, or tvEnter() tunes a channel over this in 450 ms. */
      tv.mode = "ondemand";
      tv.title = t.what;
      showView("tv");
      return;
    }
    /* A torrent is not a channel: the copy the ranking picked can simply not
       be there, and the only useful answer to that is the next copy. So a
       failure opens the picker rather than ending at a message — the message
       is still shown, above a list of everything else on offer. */
    showToast(String(r.msg || "").toUpperCase() || copy("state.no-signal"), 4000);
    openSources();
  } catch (_) { showToast(copy("state.offline"), 4000); }
}

/* =========================================================
   THE STREAM PICKER

   The channel list's twin, and built the same way on purpose: windowed rows
   (a popular film comes back with sixty copies and eight of them are ever on
   screen), red for the source that is playing, the glow for the row the
   cursor is over.

   The page never sees an infoHash or a magnet. /streams hands back an index
   per row and /play takes that index back, so resolving — and TorrServer —
   stay entirely on the backend's side of the wire.
   ========================================================= */
/* `playing` is a row index into `list`, and `list` is rebuilt per title — so
   the index only means anything alongside the title it was taken from. That
   is what `forId` is for: without it the red "this one is on" marker carried
   over to whatever film was opened next, and red marks state. */
const sources = { open: false, list: [], sel: 0, top: 0, playing: -1, forId: null, loading: false };

const FIXTURE_STREAMS = [
  { i: 0, label: "Torrentio 1080p Dune.Part.Two.2024.1080p.BluRay.x264", quality: "1080p",
    size: "2.31 GB", seeds: 2081, source: "ThePirateBay", direct: false, outside: false },
  { i: 1, label: "Torrentio 2160p Dune.Part.Two.2024.2160p.WEB-DL.DV.HDR.H265", quality: "2160p",
    size: "18.4 GB", seeds: 431, source: "RARBG", direct: false, outside: false },
  { i: 2, label: "Torrentio 1080p Dune.Part.Two.2024.1080p.WEBRip.x265", quality: "1080p",
    size: "3.05 GB", seeds: 118, source: "1337x", direct: true, outside: false },
  { i: 3, label: "Torrentio 720p Dune.Part.Two.2024.720p.HDTS", quality: "720p",
    size: "1.10 GB", seeds: 44, source: "YTS", direct: false, outside: false },
  { i: 4, label: "Torrentio 2160p Dune.Part.Two.2024.2160p.REMUX.AV1", quality: "2160p",
    size: "61.2 GB", seeds: 6, source: "TorrentGalaxy", direct: false, outside: true },
];

function sourcesShow(on) {
  sources.open = !!on;
  document.getElementById("sources").classList.toggle("on", sources.open);
}

async function openSources() {
  const t = playTarget();
  if (!t) { showToast(copy("state.empty")); return; }

  // A different title means a different list, so nothing in it is playing.
  if (sources.forId !== t.id) { sources.playing = -1; sources.forId = t.id; }

  sources.sel = Math.max(0, sources.playing);
  sources.top = 0;
  sourcesShow(true);

  if (FIXTURES) { sources.list = FIXTURE_STREAMS; renderSources(); return; }

  sources.loading = true;
  sources.list = [];
  renderSources();
  try {
    const r = await fetch(`${BACKEND}/streams/${gridState.kind}/${t.id}`,
      { signal: AbortSignal.timeout(25000) }).then(r => r.json());
    sources.list = r.streams || [];
    if (!sources.list.length && r.msg) showToast(String(r.msg).toUpperCase(), 4000);
  } catch (_) {
    showToast(copy("state.offline"), 4000);
  }
  sources.loading = false;
  renderSources();
}

function renderSources() {
  const rows = THEME.layout["source-list-rows"] || 8;
  const n = sources.list.length;
  sources.sel = Math.max(0, Math.min(sources.sel, n - 1));
  if (sources.sel < sources.top) sources.top = sources.sel;
  if (sources.sel > sources.top + rows - 1) sources.top = sources.sel - rows + 1;
  sources.top = Math.max(0, Math.min(sources.top, Math.max(0, n - rows)));

  const dot = THEME.layout["source-dot"] || 2.6;
  const el = document.getElementById("srcrows");
  const empty = document.getElementById("srcempty");

  empty.textContent = n ? "" :
    (sources.loading ? copy("state.loading") : copy("detail.no-sources"));

  // One quality column, wide enough for the longest tag on the list, so every
  // source name starts at the same x whether its row says 720P or 2160P.
  const qW = Math.ceil(dotWidth(
    Math.max(1, ...sources.list.map(s => (s.quality || "").length)), dot));

  el.innerHTML = sources.list.slice(sources.top, sources.top + rows).map((s, i) => {
    const idx = sources.top + i;
    /* Release names are Latin by construction (scene naming is ASCII), but a
       source name is not guaranteed to be, so only the quality tag — "1080P",
       digits and Latin — is ever handed to the dot face. */
    const tag = s.direct ? copy("detail.direct") : (s.outside ? copy("detail.outside") : "");
    return `<div class="srcrow${idx === sources.sel ? " sel" : ""}` +
           `${idx === sources.playing ? " live" : ""}${s.outside ? " outside" : ""}" data-i="${idx}">
      <span class="sq" style="width:${qW}px">${s.quality ? dotSVG(s.quality.toUpperCase(), dot) : ""}</span>
      <span class="sname">${escapeHTML(s.source || s.label || "")}</span>
      <span class="stag">${escapeHTML(tag)}</span>
      <span class="ssize">${escapeHTML(s.size || "")}</span>
      <span class="sseeds">${s.seeds ? `${s.seeds} ${copy("detail.seeds")}` : ""}</span>
      <span class="slive"></span>
    </div>`;
  }).join("");

  el.querySelectorAll(".srcrow").forEach(r =>
    r.addEventListener("click", () => { sources.sel = +r.dataset.i; sourcesPick(); }));

  document.getElementById("srccount").textContent = n ? `${sources.sel + 1}/${n}` : "";
}

function sourcesMove(dy) {
  const n = sources.list.length;
  if (!n) return;
  sources.sel = (sources.sel + dy + n) % n;      // wraps, like the channel list
  renderSources();
}

function sourcesPick() {
  const s = sources.list[sources.sel];
  if (!s) return;
  playSelected(s.i);
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
  gaming:   '<svg viewBox="0 0 40 40"><path d="M13 13h14a8 8 0 0 1 8 8v2a5 5 0 0 1-9 3l-1.5-2h-9L14 26a5 5 0 0 1-9-3v-2a8 8 0 0 1 8-8z"/><path d="M11 19v4M9 21h4"/><circle cx="27" cy="20" r="1.4" fill="currentColor"/><circle cx="30" cy="23" r="1.4" fill="currentColor"/></svg>',
};

/* Screens, not processes — with one exception.
   Six of these are views in this page: the clean split put channel numbers
   behind TV and gave everything else its own screen, so opening one starts
   nothing and there is no black frame anywhere.

   GAMING is the exception and cannot not be. A game needs the display, so it
   goes through the launch machinery in server.py — `app` instead of `view` —
   which is the one path in the product that starts a process. It came back in
   August 2026 having been cut in July; the tile model was kept general enough
   to take it, which is the whole reason this is a one-line difference. */
const TILES = [
  { id: "tv",      view: "tv" },
  { id: "movies",  view: "grid", kind: "movie" },
  { id: "shows",   view: "grid", kind: "show" },
  { id: "news",    view: "news" },
  { id: "weather", view: "weather" },
  { id: "music",   view: "music" },
  { id: "gaming",  app: "gaming" },
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
  if (t.app) { launchApp(t.app); return; }
  if (t.kind) gridState.kind = t.kind;
  showView(t.view);
}

/* The one path that starts a process. There is no demo mode here either: the
   toast carries whatever the backend says went wrong — "gamescope is not
   installed", "steam is not installed" — rather than a generic failure, and
   the app's own output is already going to the journal tagged with its tile
   id (server.py's pump). Between them, a tile that opens and shuts leaves a
   trace in both places somebody would look. */
async function launchApp(id) {
  const name = copy(`tiles.${id}`);
  if (FIXTURES) { showToast(`${copy("state.launching")} · ${name}`); return; }
  showToast(`${copy("state.launching")} · ${name}`, 30000);
  try {
    const r = await fetch(`${BACKEND}/launch/${id}`, { method: "POST" }).then(r => r.json());
    if (!r.ok) {
      showToast(String(r.msg || "").toUpperCase() || copy("state.unavailable"), 6000);
      return;
    }
    showToast(`${copy("state.running")} · ${name}`, 2000);
    watchApp(id, name);
  } catch (_) { showToast(copy("state.offline"), 4000); }
}

/* A successful POST only means the process started, and "started" is a much
   weaker claim than it sounds: a missing gamescope makes the script exit 127
   a tenth of a second later. Without this the TV says RUNNING and then simply
   sits on the launcher, which is the original tile-that-opens-and-shuts bug
   wearing a toast. So watch /status for a few seconds and say what happened.

   Only the early death is reported. Quitting a game after an hour is not news;
   dying before anything could have been drawn is. */
function watchApp(id, name) {
  let n = 0;
  const tick = async () => {
    if (++n > 6) return;                       // ~3s, then it is genuinely running
    try {
      const s = await fetch(`${BACKEND}/status`, { signal: AbortSignal.timeout(2000) })
        .then(r => r.json());
      if (s.running) { setTimeout(tick, 500); return; }
      const e = s.last_exit || {};
      // `e.code` rather than `e.code != null` missed exit 0 — which is the
      // shape of a launcher script that runs, finds nothing to do and quits
      // cleanly a tenth of a second later. That is precisely the
      // tile-that-opens-and-shuts this function exists to report.
      if (e.id === id && !e.killed && e.code != null) {
        showToast(`${name} · ${copy("state.unavailable")} (${e.code})`, 6000);
      }
    } catch (_) { /* backend went away; the offline toast covers that */ }
  };
  setTimeout(tick, 500);
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
                length: 0, posBase: 0, posAt: 0, seq: null,
                // Is there a player at all — not "is it playing". A paused
                // Spotify session is still connected and still worth showing
                // on the home strip, so this is what keeps the poll alive
                // once you leave the music view.
                connected: false, looping: false };

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
  music.connected = music.available && !!s.status;
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
/* When to ask playerctl again, and when to stop asking.

   Three states, because "is spotifyd there" and "is anything playing" are
   different questions and only one of them is worth a subprocess every few
   seconds:

     on the music view   1s — the progress bar is being watched
     connected, off-view 6s — something is playing (or paused); the home
                              strip shows it, so it has to stay current
     idle, off-view      stop entirely

   The last one is the fix: the old loop polled every 6s forever, so a box
   with no phone connected ran `playerctl` ten times a minute all day and
   filled the journal with "No players found". Entering the music view
   restarts it, which is the only moment a player can be discovered from a
   standing start. */
function musicDelay() {
  if (view === "music") return 1000;
  return music.connected ? 6000 : 0;      // 0 = stop
}

function musicLoop() {
  if (FIXTURES || !music.available || music.looping) return;
  music.looping = true;
  const tick = async () => {
    await pollMusic();
    const next = musicDelay();
    if (!next || !music.available) { music.looping = false; return; }
    setTimeout(tick, next);
  };
  setTimeout(tick, musicDelay() || 6000);
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
  else if (view === "tv") {
    // With the list up the arrows belong to it; with it down they zap.
    if (chanList.open) { if (dy) chanListMove(dy); }
    else if (dy) tvZap(dy);
  }
  else if (view === "grid") {
    // Innermost thing first: the picker sits over the panel, which sits over
    // the grid, and each one claims the arrows while it is up.
    if (sources.open) { if (dy) sourcesMove(dy); }
    else if (!gridState.detail) gridMove(dx, dy);
    // In a show's detail panel the arrows drive the season/episode chooser.
    // A film's has nothing to move through — its reviews scroll themselves.
    else if (gridState.kind !== "movie") seriesMove(dx, dy);
  }
  else if (view === "music") { if (dx) musicCmd(dx > 0 ? "next" : "previous"); }
}
function onOk() {
  if (view === "home") openSelected();
  else if (view === "grid") {
    if (sources.open) sourcesPick();
    else if (gridState.detail) playSelected();
    else openDetail();
  }
  else if (view === "music") musicCmd("playpause");
  else if (view === "tv") { chanList.open ? chanListPick() : chanListShow(true); }
}
function onBack() {
  // One layer at a time, outermost last. Collapsing two at once is how a
  // press meant for the picker also stops the film behind it.
  if (view === "grid" && sources.open) { sourcesShow(false); return; }
  if (view === "grid" && gridState.detail) { closeDetail(); return; }
  // Ⓑ closes the channel list without leaving the channel — one step at a
  // time, or dismissing the list would also stop the picture behind it.
  if (view === "tv" && chanList.open) { chanListShow(false); return; }
  if (view === "tv") tvStop();
  if (view !== "home") goBack();
}
function onDigit(d) { if (view === "tv") tvDigit(d); }

/* "Show me the other copies of this." Only means anything over a title, so
   it is a no-op everywhere else rather than a surprise. */
function onSources() {
  if (view !== "grid") return;
  if (sources.open) { sourcesShow(false); return; }
  if (!gridState.detail) return;
  openSources();
}

/* Back to the launcher from anywhere, including out of a launched app. The
   gamepad does this by holding the guide button (daemon/homebutton.py) and a
   TV remote by its Exit key (daemon/cecd.py); both post /home. The keyboard
   posts the same endpoint, so all three take the identical path — killing the
   running app and stopping the player — rather than three near-copies. */
async function onHome() {
  if (view === "grid") closeDetail();
  if (view === "tv") chanListShow(false);
  // /home stops the player, so the on-demand title on the bar is now a lie.
  tv.mode = "live";
  tv.title = "";
  showView("home");
  if (FIXTURES) return;
  try { await fetch(`${BACKEND}/home`, { method: "POST" }); } catch (_) {}
}

/* The keyboard is the primary input until the gamepad is tested, so every
   intent has a key and nothing is reachable only by controller. Held to the
   same rule as the rest of the input layer: these produce intents, and the
   intents are routed by whichever view is up — there is no per-screen key
   handling anywhere. */
addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  const k = e.key;
  let handled = true;

  if (k === "ArrowRight" || k === "d") onNav(1, 0);
  else if (k === "ArrowLeft" || k === "a") onNav(-1, 0);
  else if (k === "ArrowDown" || k === "s" || k === "PageDown") onNav(0, 1);
  else if (k === "ArrowUp" || k === "w" || k === "PageUp") onNav(0, -1);
  else if (k === "Enter" || k === " ") onOk();
  else if (k === "Escape" || k === "Backspace") onBack();
  else if (k === "Home" || k === "h") onHome();
  // The picker's own key. Not Ⓐ, because Ⓐ already means "play this" here and
  // the picker is the thing you reach for when that did not work.
  else if (k === "o" || k === "F3") onSources();
  else if (/^[0-9]$/.test(k)) onDigit(k);
  else handled = false;

  // Space and the arrows scroll a page by default, and this one is a fixed
  // viewport where that means the whole UI slides out from under the cursor.
  if (handled) e.preventDefault();
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
const H = (pairs) => pairs.map(([k, v]) => `<span><b>${k}</b>&nbsp;&nbsp;${v}</span>`).join("");

/* The detail panel's hints change with the kind: a film is one button, a show
   is a chooser. Drawn per open rather than once at boot for that reason. */
function drawDetailHints(isShow) {
  // The picker is worth naming on the panel: it is the answer to "it did not
  // play", and a key nobody knows about is a key nobody presses.
  const src = ["⊙", copy("hints.sources")];
  document.getElementById("detailhints").innerHTML = isShow
    ? H([["◂ ▸", copy("hints.season")], ["▴ ▾", copy("hints.episode")],
         ["Ⓐ", copy("hints.play")], src, ["Ⓑ", copy("hints.back")]])
    : H([["Ⓐ", copy("hints.play")], src, ["Ⓑ", copy("hints.back")]]);
}

function drawHints() {
  document.getElementById("homehints").innerHTML =
    H([["◂ ▸", copy("hints.navigate")], ["Ⓐ", copy("hints.open")], ["HOLD ⌂", copy("hints.home")]]);
  document.getElementById("gridhints").innerHTML =
    H([["◂ ▸ ▴ ▾", copy("hints.navigate")], ["Ⓐ", copy("hints.open")], ["Ⓑ", copy("hints.back")]]);
  drawDetailHints(false);
  document.getElementById("mhints").innerHTML =
    H([["◂ ▸", copy("hints.track")], ["Ⓐ", copy("hints.playpause")], ["Ⓑ", copy("hints.back")]]);
  document.getElementById("wxhints").innerHTML = H([["Ⓑ", copy("hints.back")]]);

  // TV: the bar carries the one hint that makes the list findable at all,
  // and the list carries its own once it is up.
  document.getElementById("barhint").innerHTML = H([["Ⓐ", copy("hints.channels")]]);
  document.getElementById("chanhead").innerHTML =
    dotSVG(copy("tv.channels"), 4.4, { assemble: true });
  document.getElementById("chanhints").innerHTML =
    H([["▴ ▾", copy("hints.channel")], ["Ⓐ", copy("hints.tune")], ["Ⓑ", copy("hints.back")]]);

  // The stream picker, built to read as the channel list's twin.
  document.getElementById("srchead").innerHTML =
    dotSVG(copy("detail.sources"), 4.4, { assemble: true });
  document.getElementById("srchints").innerHTML =
    H([["▴ ▾", copy("hints.source")], ["Ⓐ", copy("hints.play")], ["Ⓑ", copy("hints.back")]]);
}

async function loadConfig() {
  if (FIXTURES) return;
  try {
    cfg = await withRetry(() => fetch(BACKEND + "/config", { signal: AbortSignal.timeout(2500) })
      .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); }), 6, 500);
  } catch (_) { showToast(copy("state.offline"), 4000); }
}

/* Retry something that only failed because the backend was not up yet.
   `start-session.sh` waits for :8484 before starting Chromium, but a cold box
   can still lose that race — and this page is a kiosk with no address bar and
   no reload button, so one failed fetch at boot is a black screen until
   somebody SSHes in. Bounded, and the last failure is re-thrown so a
   genuinely broken theme.json still fails loudly (the point of loadTheme). */
async function withRetry(what, tries = 10, gap = 400) {
  let last;
  for (let i = 0; i < tries; i++) {
    try { return await what(); } catch (e) { last = e; }
    // Backs off to a couple of seconds: a backend that is slow to bind is
    // worth waiting out, and hammering it while it starts helps nobody.
    await new Promise(r => setTimeout(r, Math.min(gap * (i + 1), 2000)));
  }
  throw last;
}

async function boot() {
  await withRetry(() => loadTheme());
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
  /* A screen left up refreshes itself. Only the one that is up: re-rendering
     NEWS in the background restarts its marquees, and nothing behind a view
     is visible anyway. Both entries are no-ops until their stamp goes
     stale, so this costs a comparison a minute. */
  setInterval(() => {
    if (view === "news") newsEnter();
    else if (view === "weather") weatherEnter();
  }, 60 * 1000);
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

    /* &playing=TITLE is the state a successful /play leaves behind: the TV
       screen as a passthrough surface with the dial standing down. Set before
       showView, exactly as playSelected does — entering TV in "live" mode
       fetches channels and tunes one, and doing that first would race. */
    if (want === "tv" && q.get("playing")) {
      tv.mode = "ondemand";
      tv.title = q.get("playing");
    }

    showView(want);

    // &list=1 pulls the channel list up on the TV screen. Same rule as the
    // grid's flags below: it is the Ⓐ press, not a second way to draw it.
    if (want === "tv" && q.get("list")) setTimeout(() => chanListShow(true), 400);

    // &sel=N puts the grid cursor on an item and &detail=1 opens its panel,
    // so a scrolled grid and the detail screen are both reachable without a
    // gamepad. Navigation only — neither invents data.
    /* &revisit=N leaves the screen and comes back, N times — what a person
       does when something did not load. It is the only way to reach the
       "try again on the way in" behaviour that NEWS and WEATHER rely on, and
       like every flag here it is navigation and invents no data. */
    const revisit = parseInt(q.get("revisit") || "0", 10);
    if (revisit > 0) {
      setTimeout(async () => {
        for (let i = 0; i < revisit; i++) {
          showView("home");
          await new Promise(r => setTimeout(r, 150));
          showView(want);
          await new Promise(r => setTimeout(r, 400));
        }
      }, 500);
    }

    /* &then=KIND,KIND walks out of BROWSE and back in on another catalogue,
       as many times as asked. It takes a list because the sequence that used
       to draw one list under the other's title needed three steps, not two:
       the second visit to a catalogue is the one that skipped its reset.
       Each hop is what openSelected does — set the kind, enter the view — so
       it exercises the real path rather than a test-only one. */
    if (want === "grid" && q.get("then")) {
      setTimeout(async () => {
        await gridEnter();
        for (const k of q.get("then").split(",")) {
          showView("home");
          gridState.kind = k;
          showView("grid");
          await gridEnter();
        }
      }, 300);
    }

    if (want === "grid" && !q.get("then")) {
      setTimeout(async () => {
        if (q.get("sel")) {
          const n = parseInt(q.get("sel"), 10);
          await ensureLoaded(n + 1);
          gridState.sel = Math.min(n, Math.max(0, gridState.items.length - 1));
          gridState.page = Math.floor(gridState.sel / perPage());
          renderGrid();
        }
        if (q.get("detail")) await openDetail();
        // &sources=1 pulls the stream picker up over the panel. Same rule as
        // &list=1 on TV: it is the key press, not a second way to draw it.
        if (q.get("sources")) await openSources();
      }, 400);
    }
  }
}
/* A kiosk has no address bar, no reload button and usually no keyboard, so
   "boot threw" cannot be allowed to mean "black screen until somebody SSHes
   in". After the retries above have genuinely run out, the page reloads
   itself — which is the one recovery action available to it, and it costs
   nothing if the backend is still down because the next boot retries again.
   The reason goes to the console, which start-session.sh pipes to the
   journal in debug mode (constraint 17 in spirit). */
boot().catch((e) => {
  console.error("boot failed, reloading in 5s:", e);
  setTimeout(() => location.reload(), 5000);
});

/* Exposed for the headless render test (test/render.mjs) — it drives the
   real module rather than a copy, so the test cannot drift from the UI. */
Object.assign(globalThis, {
  showView, onNav, onOk, onBack, onDigit, onHome, onSources,
  chanListShow, sourcesShow, openSources, THEME, dotSVG, fitDots,
});
