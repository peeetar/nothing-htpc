/* =========================================================
   THEME LOADER

   Reads launcher/theme.json, folds in a hardware profile, and stamps the
   token half onto :root as CSS custom properties. Everything else in the
   UI reads `THEME.motion`, `THEME.layout` and `THEME.copy` from here.

   Naming: colours keep their bare key (--ink, --red), every other group is
   prefixed by its group name (--size-base, --space-3, --motion-view). That
   asymmetry is deliberate — colours are referenced constantly and the short
   name is what makes the stylesheet readable.

   No build step and no bundler (CLAUDE.md conventions): this is a plain
   module loaded before the UI, and it fails loudly rather than silently
   falling back to a hardcoded palette. A box with no theme is a bug worth
   seeing, not a thing to paper over.
   ========================================================= */

export const THEME = {
  tokens: {}, motion: {}, layout: {}, copy: {}, name: "?", profile: null,
};

/* Deep-merge a profile over the base. Objects merge, scalars replace —
   which is exactly what a profile is: `pi3` names only the handful of
   values it wants to change and inherits the rest. */
function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) {
    out[k] = (v && typeof v === "object" && !Array.isArray(v) &&
              base[k] && typeof base[k] === "object" && !Array.isArray(base[k]))
      ? merge(base[k], v)
      : v;
  }
  return out;
}

/* _note keys are documentation, not values. They must never reach the DOM. */
function stamp(root, group, obj, prefix) {
  for (const [k, v] of Object.entries(obj)) {
    if (k === "_note" || v === null || typeof v === "object") continue;
    const name = prefix ? `--${prefix}-${k}` : `--${k}`;
    root.style.setProperty(name, String(v));
  }
}

/* Durations are numbers in the file (JS needs them as numbers for
   setTimeout) but CSS needs units, so they get stamped twice: --motion-view
   for JS-free CSS transitions, in ms. */
function stampMotion(root, motion) {
  for (const [k, v] of Object.entries(motion)) {
    if (k === "_note") continue;
    root.style.setProperty(`--motion-${k}`, typeof v === "number" ? `${v}ms` : String(v));
  }
}

export async function loadTheme(url = "theme.json", profileName = null) {
  const res = await fetch(url, { cache: "no-cache" });
  if (!res.ok) throw new Error(`theme.json: HTTP ${res.status}`);
  let t = await res.json();

  /* Profile precedence mirrors the config precedence in CLAUDE.md:
     an explicit ?profile= wins, then whatever the caller passed. */
  const want = new URLSearchParams(location.search).get("profile") || profileName;
  if (want && t.profiles && t.profiles[want]) {
    t = merge(t, t.profiles[want]);
    THEME.profile = want;
  }

  const root = document.documentElement;
  stamp(root, "color", t.tokens.color, "");
  stamp(root, "font",  t.tokens.font,  "font");
  stamp(root, "size",  t.tokens.size,  "size");
  stamp(root, "track", t.tokens.track, "track");
  stamp(root, "space", t.tokens.space, "space");
  stamp(root, "line",  t.tokens.line,  "line");
  stampMotion(root, t.motion);

  /* Layout values are read by JS (grid counts, dot sizes) and by CSS
     (heights, gaps), so they get stamped raw and kept as data. */
  stamp(root, "layout", t.layout, "layout");

  THEME.name = t.name;
  THEME.tokens = t.tokens;
  THEME.motion = t.motion;
  THEME.layout = t.layout;
  THEME.copy = t.copy;
  return THEME;
}

/* copy("state.offline") — one lookup for every user-facing string, so a
   missing key shows up as the key itself rather than as blank space. */
export function copy(path) {
  let cur = THEME.copy;
  for (const part of path.split(".")) {
    if (!cur || typeof cur !== "object") return path;
    cur = cur[part];
  }
  return typeof cur === "string" ? cur : path;
}
