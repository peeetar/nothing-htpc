-- cabletv.lua ---------------------------------------------------------------
-- Old-school cable TV mode for mpv.
--   * curated channels.m3u with fixed channel numbers (tvg-chno)
--   * shoulder buttons / dpad up-down zap channels
--   * X opens a keypad grid; digits tune directly (3 digits = instant)
--   * banner: number + name, top-left, pixel font, fades after 5 s
--   * animated static on dead channels and while buffering
--   * teletext: 991 = channel guide, 992/993 = RSS news pages
-- No volume control on purpose - that's the TV's job.
------------------------------------------------------------------------------

local mp = require "mp"
local utils = require "mp.utils"

-- config ---------------------------------------------------------------------
local DIR             = os.getenv("CABLETV_DIR") or (os.getenv("HOME") .. "/nothing-htpc/cabletv")
local CHANNELS_FILE   = DIR .. "/channels.m3u"
local LIBRARY_FILE    = DIR .. "/library.tsv"
local FONT            = "Press Start 2P"
local BANNER_SECONDS  = 5
-- Overridable because static is uncompressed: every tick hands mpv another
-- screenful of BGRA to upload, 8.3MB of it at 1080p. 25fps costs ~200MB/s of
-- memory traffic, which a desktop does not notice and a Pi 3B+ very much
-- does - cabletv.sh lowers the rate on small machines.
local STATIC_FPS      = tonumber(os.getenv("CABLETV_STATIC_FPS")) or 25
local STATIC_SLACK    = 512         -- spare noise rows to scroll through
local RETRY_SECONDS   = 12          -- dead channel retry interval
local ZAP_DELAY       = 0.45        -- how long a number sits before it loads
local DIGIT_TIMEOUT   = 2.0         -- seconds after last digit before tuning
local RSS_CACHE_SECS  = 300
local WX_CACHE_SECS   = 900         -- weather moves slower than news
local LINES_PER_PAGE  = 11          -- rows per subpage on the list pages
-- 991 is paginated by feed, not by row count: one language per subpage, every
-- headline on exactly one line. 15 rows is what fits under the section header
-- without crowding the fastext footer.
local NEWS_ROWS       = 15
-- Press Start 2P advances 0.73em per glyph, so 72 columns at fs20 is 1060px
-- and the body still stops well short of the 1250 right margin. Measured off
-- a rendered page, not guessed: most headlines now survive whole.
local NEWS_COLS       = 72

-- Page 992 is a fixed three-city forecast, not "wherever the box is": these
-- are the three places the owner cares about, so they are identities like
-- channel numbers are. Names are each in their own language - Press Start 2P
-- covers Latin, Cyrillic and Greek (constraint 5).
local WX_CITIES = {
  { name = "СКОПЈЕ",      lat = 41.9973, lon = 21.4280 },
  { name = "LJUBLJANA",   lat = 46.0569, lon = 14.5058 },
  { name = "ΘΕΣΣΑΛΟΝΙΚΗ", lat = 40.6401, lon = 22.9444 },
}
local WX_DAYS = 3

-- Teletext pages live in the same number space as channels, so 991 is typed
-- exactly like 21 is. 990-999 is the reserved block (see channels.m3u).
--   991 NEWS     one language per subpage: 1 = MK, 2 = Thessaloniki
--   992 WEATHER  three cities, three days, Open-Meteo, no API key
--   993 MOVIES   on-demand library, kind=movie
--   994 SHOWS    on-demand library, kind=show
--   995-998      free
--   999 GUIDE    the channel list (was 991 until July 2026)
local TELETEXT = {
  [991] = { type = "news", title = "ВЕСТИ / ΕΙΔΗΣΕΙΣ", feeds = {
              { label = "МАКЕДОНИЈА", url = "https://time.mk/rss/all",
                clean = function(t) return (t:gsub("%s*|[^|]*$", "")) end },
              -- Was pressdisplay's rss.ashx until July 2026; that endpoint now
              -- answers 404 with an IIS error page, which is why the Greek
              -- half of this page had been silently empty. in.gr replaced it
              -- and thestival.gr replaced that: the Greek subpage is meant to
              -- be Thessaloniki news, matching the third weather city.
              { label = "ΘΕΣΣΑΛΟΝΙΚΗ", url = "https://www.thestival.gr/feed/" },
            } },
  [992] = { type = "weather", title = "ВРЕМЕ / ΚΑΙΡΟΣ" },
  [993] = { type = "library", title = "MOVIES", kind = "movie" },
  [994] = { type = "library", title = "TV SHOWS", kind = "show" },
  [999] = { type = "guide", title = "TV GUIDE" },
}

-- state -----------------------------------------------------------------------
local channels = {}        -- chno -> {name=, url=}
local chnos = {}           -- sorted list of all numbers incl. teletext
local current = nil        -- channel number on the banner (may not be loaded)
local playing = nil        -- channel whose stream is actually loaded
local loading = false      -- waiting for stream to start
local dead = false         -- channel failed, static + retry
local retry_timer = nil
local zap_timer = nil      -- pending load while the number is still moving
local digit_buf = ""
local digit_timer = nil
local keypad = nil         -- {r=,c=} when open
local tt = nil             -- {no=, sub=, lines=|pages=|wx=, cur=, gen=} when active
local tt_gen = 0           -- bumped per open; an async reply for an old gen is dropped
local rss_cache = {}       -- key -> {t=, pages=}
local wx_cache = nil       -- {t=, wx=}
local library = nil        -- kind -> sorted list of {title=, year=, url=}
local ondemand = nil       -- the library entry currently playing, if any

-- ass colors (BGR!) -------------------------------------------------------------
local C_GREEN  = "&H33FF33&"
local C_WHITE  = "&HFFFFFF&"
local C_YELLOW = "&H00FFFF&"
local C_CYAN   = "&HFFFF00&"
local C_GRAY   = "&H888888&"
local C_BLACK  = "&H000000&"
local C_DIM    = "&H303030&"   -- grid rules on 992; a hair above the background

-- overlays ---------------------------------------------------------------------
local ov_banner  = mp.create_osd_overlay("ass-events")
local ov_keypad  = mp.create_osd_overlay("ass-events")
local ov_tt      = mp.create_osd_overlay("ass-events")
local OSD_W, OSD_H = 1280, 720
for _, ov in pairs({ov_banner, ov_keypad, ov_tt}) do
  ov.res_x, ov.res_y = OSD_W, OSD_H
end
-- Only the banner needs measuring: it is the one box whose size depends on
-- how long a channel name is. The keypad and teletext know their own.
ov_banner.compute_bounds = true

-- Every key handler and timer callback goes through this. An argument-count
-- slip in one of the :format() calls below raises at runtime, and an
-- unguarded raise out of a binding has frozen the whole box before now.
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then mp.msg.error("handler error: " .. tostring(err)) end
  end
end

------------------------------------------------------------------ channels ----
local function load_channels()
  local f = io.open(CHANNELS_FILE, "r")
  if not f then
    mp.msg.error("channels.m3u not found at " .. CHANNELS_FILE)
    return
  end
  local pending = nil
  for line in f:lines() do
    line = line:gsub("\r$", "")
    local chno, name = line:match('^#EXTINF.-tvg%-chno="(%d+)".-,%s*(.+)$')
    if chno then
      pending = { no = tonumber(chno), name = name }
    elseif line ~= "" and not line:match("^#") and pending then
      channels[pending.no] = { name = pending.name, url = line }
      pending = nil
    end
  end
  f:close()
  chnos = {}
  for no in pairs(channels) do chnos[#chnos + 1] = no end
  for no in pairs(TELETEXT) do chnos[#chnos + 1] = no end
  table.sort(chnos)
  mp.msg.info(("loaded %d channels"):format(#chnos))
end

local function chan_name(no)
  if TELETEXT[no] then return TELETEXT[no].title end
  return channels[no] and channels[no].name or "---"
end

------------------------------------------------------------------- static -----
-- Two things shape this, both learned the hard way against mpv 0.41:
--
-- 1. Raw overlays are composited ON TOP of script ASS overlays, and neither
--    the overlay id nor the ASS overlay's z changes that. A full-screen noise
--    rectangle therefore buries the banner, and since a channel change shows
--    static first, the box looks like it has no UI at all until the stream
--    opens. So the noise is laid down as tiles AROUND whatever OSD is
--    visible, and the banner paints its own black plate into the hole.
-- 2. One noise field, scrolled, beats N frames cycled. Each tick draws from a
--    random pixel offset into a field that is STATIC_SLACK rows taller than
--    the screen, which is ~350k distinct framings off a single file instead
--    of a 4-frame loop the eye picks up in a second.
local STATIC_ID0     = 48    -- overlay ids 48..63 belong to the static
local STATIC_MAXTILE = 16

local static = { on = false, timer = nil, file = nil, w = 0, h = 0,
                 tiles = {}, ntiles = 0, dirty = true }

-- name -> {x0,y0,x1,y1} in ASS coords for every OSD element on screen.
--
-- These are the rectangles each element paints opaquely, stated by the
-- element itself. Not mpv's compute_bounds: that is documented as an
-- approximation and in practice over-reports the right and bottom edges by
-- about 11px, which would leave the picture showing in a bright L around the
-- banner. compute_bounds is only used to measure text, never to punch.
local osd_boxes = {}

local function set_box(name, b)
  local old = osd_boxes[name]
  local new = nil
  if b and b.x0 and b.x1 and b.x1 > b.x0 and b.y1 > b.y0 then
    new = { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 }
  end
  if (old == nil) ~= (new == nil) then
    static.dirty = true
  elseif new and (new.x0 ~= old.x0 or new.y0 ~= old.y0
                  or new.x1 ~= old.x1 or new.y1 ~= old.y1) then
    static.dirty = true
  end
  osd_boxes[name] = new
end

-- Screen minus the OSD boxes, as a list of rectangles. Bands are cut at every
-- box edge, then each band is filled left to right around the boxes crossing
-- it: at most 3 bands x 3 pieces for the two boxes that can coexist.
local function static_tiles()
  local W, H = static.w, static.h
  local sx, sy = W / OSD_W, H / OSD_H
  local holes = {}
  for _, b in pairs(osd_boxes) do
    -- Round inwards, never outwards. A hole even one pixel wider than the
    -- element filling it shows whatever is under the static as a bright ring
    -- around the banner - the last decoded frame of the channel you just
    -- left, which looks far worse than a pixel of noise over a black plate.
    local x0 = math.max(0, math.ceil(b.x0 * sx))
    local y0 = math.max(0, math.ceil(b.y0 * sy))
    local x1 = math.min(W, math.floor(b.x1 * sx))
    local y1 = math.min(H, math.floor(b.y1 * sy))
    if x1 > x0 and y1 > y0 then
      holes[#holes + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end
  end

  local function build(hs)
    local ys, seen = {}, {}
    local function addy(v)
      v = math.max(0, math.min(H, v))
      if not seen[v] then seen[v] = true; ys[#ys + 1] = v end
    end
    addy(0); addy(H)
    for _, r in ipairs(hs) do addy(r.y0); addy(r.y1) end
    table.sort(ys)
    local out = {}
    for i = 1, #ys - 1 do
      local y0, y1 = ys[i], ys[i + 1]
      if y1 > y0 then
        local cov = {}
        for _, r in ipairs(hs) do
          if r.y0 < y1 and r.y1 > y0 then cov[#cov + 1] = r end
        end
        table.sort(cov, function(a, b) return a.x0 < b.x0 end)
        local x = 0
        for _, r in ipairs(cov) do
          if r.x0 > x then
            out[#out + 1] = { x = x, y = y0, w = r.x0 - x, h = y1 - y0 }
          end
          if r.x1 > x then x = r.x1 end
        end
        if x < W then out[#out + 1] = { x = x, y = y0, w = W - x, h = y1 - y0 } end
      end
    end
    return out
  end

  local tiles = build(holes)
  if #tiles > STATIC_MAXTILE and #holes > 1 then
    -- More pieces than overlay ids: cover the lot with one bounding hole
    -- rather than juggle ids. Loses a little noise, never loses the OSD.
    local b = { x0 = W, y0 = H, x1 = 0, y1 = 0 }
    for _, r in ipairs(holes) do
      b.x0 = math.min(b.x0, r.x0); b.y0 = math.min(b.y0, r.y0)
      b.x1 = math.max(b.x1, r.x1); b.y1 = math.max(b.y1, r.y1)
    end
    tiles = build({ b })
  end
  return tiles
end

-- Forward declarations: both of these fill their own hole in the static, so
-- they have to be redrawn whenever the static comes and goes.
local render_banner, keypad_render

local function static_clear_ids(from)
  for i = from, static.ntiles - 1 do
    mp.commandv("overlay-remove", tostring(STATIC_ID0 + i))
  end
end

local function static_ensure()
  local w = math.floor(mp.get_property_number("osd-width", 0) or 0)
  local h = math.floor(mp.get_property_number("osd-height", 0) or 0)
  if w < 16 or h < 16 then w, h = OSD_W, OSD_H end
  if static.file and static.w == w and static.h == h then return end
  static_clear_ids(0)
  static.ntiles, static.dirty = 0, true
  static.file, static.w, static.h = nil, w, h
  -- One spare row on top of the slack: a framing can start at the last spare
  -- row AND be shifted horizontally, which runs the read one row long.
  local bh = h + STATIC_SLACK + 1
  local path = ("%s/.cache/cabletv/noise-%dx%d.bgra")
               :format(os.getenv("HOME") or "/tmp", w, bh)
  local probe = io.open(path, "rb")
  if probe then
    probe:close()
    static.file = path
    return
  end
  -- Async: a 1080p field is 12MB to write and blocking the script here would
  -- hold up the banner of the channel we are tuning to.
  mp.command_native_async(
    { name = "subprocess", playback_only = false,
      args = { "python3", DIR .. "/gen_static.py",
               tostring(w), tostring(bh), path } },
    function(ok, res)
      if ok and res and res.status == 0 then
        static.file = path
      else
        mp.msg.error("static: could not generate " .. path)
      end
    end)
end

local function static_tick()
  if not (static.on and static.file) then return end
  if static.dirty then
    local tiles = static_tiles()
    static_clear_ids(#tiles)
    static.tiles, static.ntiles, static.dirty = tiles, #tiles, false
  end
  -- Random framing of the field, vertical rows plus a horizontal shift that
  -- wraps rows against each other. Every tile reads from the same base so
  -- they stay one continuous field across the holes.
  local base = math.random(0, STATIC_SLACK - 1) * static.w
             + math.random(0, static.w - 1)
  for i, t in ipairs(static.tiles) do
    mp.commandv("overlay-add", tostring(STATIC_ID0 + i - 1),
                tostring(t.x), tostring(t.y), static.file,
                tostring((base + t.y * static.w + t.x) * 4), "bgra",
                tostring(t.w), tostring(t.h), tostring(static.w * 4))
  end
end

local function static_on()
  if static.on then return end
  static_ensure()
  static.on = true
  if not static.timer then
    static.timer = mp.add_periodic_timer(1 / STATIC_FPS, guard(static_tick))
  else
    static.timer:resume()
  end
  render_banner()      -- gains its black plate
  if keypad then keypad_render() end
  static_tick()
end

local function static_off()
  if not static.on then return end
  static.on = false
  if static.timer then static.timer:stop() end
  static_clear_ids(0)
  static.ntiles, static.dirty = 0, true
  render_banner()      -- drops the plate, back to bare text over the picture
  if keypad then keypad_render() end
end

------------------------------------------------------------------- banner -----
local banner_timer = nil
local banner = { num = "", name = "", shown = false }

-- Assigned into the forward declaration made in the static section.
render_banner = function()
  if not banner.shown then
    ov_banner.data = ""
    ov_banner:update()
    set_box("banner", nil)
    return
  end
  local body = table.concat({
    ("{\\an7\\pos(52,42)\\fn%s\\fs52\\bord4\\3c%s\\1c%s\\shad0}%s")
      :format(FONT, C_BLACK, C_GREEN, banner.num),
    ("{\\an7\\pos(52,112)\\fn%s\\fs26\\bord3\\3c%s\\1c%s\\shad0}%s")
      :format(FONT, C_BLACK, C_GREEN, banner.name),
  }, "\n")
  ov_banner.data = body
  local b = ov_banner:update()
  if not (static.on and b and b.x0) then
    -- Over a picture the banner is just letters with a black outline, and
    -- there is no static to punch a hole in.
    set_box("banner", nil)
    return
  end
  -- Static is opaque and sits above us, so the tiles leave this rectangle
  -- empty and the banner fills it with its own black plate - which is what a
  -- cable box banner over a dead channel looked like anyway. The padding is
  -- lopsided on purpose: compute_bounds runs long on the right and bottom,
  -- so equal numbers here would look off-centre on screen.
  local plate = {
    x0 = math.max(0, b.x0 - 18),
    y0 = math.max(0, b.y0 - 22),
    x1 = math.min(OSD_W, b.x1 + 8),
    y1 = math.min(OSD_H, b.y1 + 6),
  }
  ov_banner.data = ("{\\an7\\pos(0,0)\\p1\\1c%s\\bord0\\shad0}" ..
                    "m %d %d l %d %d l %d %d l %d %d{\\p0}\n%s")
                   :format(C_BLACK, plate.x0, plate.y0, plate.x1, plate.y0,
                           plate.x1, plate.y1, plate.x0, plate.y1, body)
  ov_banner:update()
  set_box("banner", plate)
end

local function show_banner(no, name)
  local num = tostring(no)
  if #num < 2 then num = "0" .. num end
  banner.num, banner.name, banner.shown = num, name or "", true
  render_banner()
  if banner_timer then banner_timer:kill() end
  banner_timer = mp.add_timeout(BANNER_SECONDS, guard(function()
    banner.shown = false
    render_banner()
  end))
end

------------------------------------------------------------------- teletext ---
local function ulen(s)
  -- UTF-8 codepoint count (Lua 5.1 compatible)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- Cut to n codepoints. Cutting by bytes splits a Cyrillic or Greek character
-- in half and renders as tofu, which is the whole reason this exists.
local function usub(s, n)
  local i, count = 1, 0
  while i <= #s and count < n do
    local b = s:byte(i)
    i = i + ((b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4)
    count = count + 1
  end
  return s:sub(1, i - 1)
end

local function utf8_char(c)
  if c < 0x80 then return string.char(c) end
  if c < 0x800 then
    return string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40)
  end
  if c < 0x10000 then
    return string.char(0xE0 + math.floor(c / 0x1000),
                       0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
  end
  return string.char(0xF0 + math.floor(c / 0x40000),
                     0x80 + math.floor(c / 0x1000) % 0x40,
                     0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
end

-- Typographic codepoints folded to ASCII rather than passed through. Press
-- Start 2P is the only shipped font covering Cyrillic AND Greek (constraint
-- 5), but it has no en dash or curly quotes — decoding those faithfully
-- would put tofu boxes on the page. Flattening them is also more teletext.
local ENTITY_ASCII = {
  [160] = " ", [8211] = "-", [8212] = "-", [8216] = "'", [8217] = "'",
  [8218] = ",", [8220] = '"', [8221] = '"', [8222] = '"', [8230] = "...",
  [8242] = "'", [8243] = '"', [8722] = "-",
}

local function entity(n)
  return ENTITY_ASCII[n] or utf8_char(n)
end

local function tt_decode(t)
  t = t:gsub("^%s*<!%[CDATA%[(.-)%]%]>?%s*$", "%1")
  t = t:gsub("&#x(%x+);", function(h) return entity(tonumber(h, 16)) end)
  t = t:gsub("&#(%d+);", function(d) return entity(tonumber(d)) end)
  t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  t = t:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&nbsp;", " ")
  t = t:gsub("&laquo;", '"'):gsub("&raquo;", '"'):gsub("&hellip;", "...")
  t = t:gsub("&ndash;", "-"):gsub("&mdash;", "-")
  -- Literal typographic characters the feeds send as real UTF-8, same reason.
  t = t:gsub("\226\128\148", "-"):gsub("\226\128\147", "-")
  return t
end

-- ASS treats { } as override-block delimiters, so a title containing one
-- would silently eat the rest of the row. Library titles come from a file
-- somebody generates, so they are not trusted to be brace-free.
local function ass_escape(s)
  return (s:gsub("{", "("):gsub("}", ")"))
end

-- library.tsv -> library[kind] = sorted { {title=, year=, url=}, ... }
-- Read once, lazily, on the first visit to 993/994. Reading it at boot would
-- cost a file read on every zap into cable mode for a page most sessions
-- never open.
local function load_library()
  if library then return end
  library = { movie = {}, show = {} }
  local f = io.open(LIBRARY_FILE, "r")
  if not f then
    mp.msg.warn("library.tsv not found at " .. LIBRARY_FILE)
    return
  end
  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local kind, title, year, url = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
      if kind and library[kind] and title ~= "" then
        local t = library[kind]
        t[#t + 1] = { title = title,
                      year  = (year or ""):match("^%s*(.-)%s*$"),
                      url   = (url or ""):match("^%s*(.-)%s*$") }
      end
    end
  end
  f:close()
  for _, t in pairs(library) do
    table.sort(t, function(a, b) return a.title:lower() < b.title:lower() end)
  end
end

-- Every text row on a page goes through here, so there is exactly one ASS
-- event format string with exactly seven arguments instead of one per call
-- site (constraint 4). Coordinates are floored because %d on a float raises
-- in Lua 5.4, and a raise inside a render is a frozen page.
local function txt(ev, align, x, y, fs, color, s)
  ev[#ev + 1] = ("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\1c%s\\bord0\\shad0}%s")
                :format(align, math.floor(x), math.floor(y), FONT,
                        math.floor(fs), color, s)
end

-- Vector helpers for the 992 weather icons. Two rules keep them safe:
-- polygons only (a 16-gon is a circle at 60px, and no bezier means no
-- control-point arithmetic to get wrong), and one shape per ASS event, so
-- overlapping parts of the same icon never depend on libass's fill rule.
local function ass_poly(pts)
  local out = {}
  for i = 1, #pts - 1, 2 do
    out[#out + 1] = ((i == 1) and "m " or "l ") ..
                    math.floor(pts[i] + 0.5) .. " " .. math.floor(pts[i + 1] + 0.5)
  end
  return table.concat(out, " ")
end

local function ass_circle(cx, cy, r)
  local pts = {}
  for i = 0, 15 do
    local a = i * math.pi / 8
    pts[#pts + 1] = cx + r * math.cos(a)
    pts[#pts + 1] = cy + r * math.sin(a)
  end
  return ass_poly(pts)
end

local function ass_rect(x0, y0, x1, y1)
  return ass_poly({ x0, y0, x1, y0, x1, y1, x0, y1 })
end

local function draw(ev, color, path)
  ev[#ev + 1] = ("{\\an7\\pos(0,0)\\p1\\1c%s\\bord0\\shad0}%s{\\p0}"):format(color, path)
end

local function icon_sun(ev, cx, cy, w, color)
  local r = w * 0.52
  draw(ev, color, ass_circle(cx, cy, r))
  for i = 0, 7 do
    local a = i * math.pi / 4
    local ca, sa = math.cos(a), math.sin(a)
    local px, py = -sa, ca                       -- unit normal, for the width
    local i0, i1, hw = r * 1.35, r * 1.95, r * 0.17
    draw(ev, color, ass_poly({
      cx + ca * i0 + px * hw,       cy + sa * i0 + py * hw,
      cx + ca * i1 + px * hw * 0.6, cy + sa * i1 + py * hw * 0.6,
      cx + ca * i1 - px * hw * 0.6, cy + sa * i1 - py * hw * 0.6,
      cx + ca * i0 - px * hw,       cy + sa * i0 - py * hw }))
  end
end

local function icon_cloud(ev, cx, cy, w, color)
  draw(ev, color, ass_circle(cx - 0.05 * w, cy - 0.22 * w, 0.52 * w))
  draw(ev, color, ass_circle(cx - 0.62 * w, cy + 0.08 * w, 0.40 * w))
  draw(ev, color, ass_circle(cx + 0.60 * w, cy + 0.12 * w, 0.36 * w))
  draw(ev, color, ass_rect(cx - 1.00 * w, cy + 0.06 * w, cx + 0.96 * w, cy + 0.46 * w))
end

-- Falling things hang off the bottom edge of a cloud drawn at (cx, cy).
local function icon_drops(ev, cx, cy, w, color, len)
  for i = -1, 1 do
    local x = cx + i * 0.58 * w
    draw(ev, color, ass_poly({ x + 0.09 * w,             cy,
                               x + 0.09 * w - 0.14 * w,  cy + len,
                               x - 0.09 * w - 0.14 * w,  cy + len,
                               x - 0.09 * w,             cy }))
  end
end

local function icon_flakes(ev, cx, cy, w, color)
  for i = -1, 1 do
    local x, d = cx + i * 0.58 * w, 0.15 * w
    local y = cy + ((i == 0) and 0.20 * w or 0)
    draw(ev, color, ass_poly({ x, y - d, x + d, y, x, y + d, x - d, y }))
  end
end

local function icon_bolt(ev, cx, cy, w, color)
  draw(ev, color, ass_poly({
    cx + 0.34 * w, cy - 0.10 * w,
    cx - 0.26 * w, cy + 0.36 * w,
    cx + 0.02 * w, cy + 0.36 * w,
    cx - 0.20 * w, cy + 0.92 * w,
    cx + 0.38 * w, cy + 0.26 * w,
    cx + 0.10 * w, cy + 0.26 * w,
    cx + 0.44 * w, cy - 0.10 * w }))
end

local function icon_bars(ev, cx, cy, w, color)
  for i = 0, 2 do
    local half = (i == 1) and 0.62 * w or 0.82 * w
    local y = cy + i * 0.26 * w
    draw(ev, color, ass_rect(cx - half, y, cx + half, y + 0.09 * w))
  end
end

-- kind -> the parts it is made of. Sun first, cloud after: the cloud is meant
-- to sit in front of it.
local function wx_icon(ev, kind, cx, cy, w)
  if kind == "sun" then
    icon_sun(ev, cx, cy, w, C_YELLOW)
  elseif kind == "suncloud" then
    icon_sun(ev, cx - 0.45 * w, cy - 0.45 * w, w * 0.62, C_YELLOW)
    icon_cloud(ev, cx + 0.14 * w, cy + 0.22 * w, w * 0.76, C_WHITE)
  elseif kind == "fog" then
    icon_cloud(ev, cx, cy - 0.34 * w, w * 0.82, C_GRAY)
    icon_bars(ev, cx, cy + 0.24 * w, w, C_GRAY)
  elseif kind == "drizzle" then
    icon_cloud(ev, cx, cy - 0.30 * w, w * 0.86, C_WHITE)
    icon_drops(ev, cx, cy + 0.28 * w, w, C_CYAN, 0.24 * w)
  elseif kind == "rain" then
    icon_cloud(ev, cx, cy - 0.30 * w, w * 0.86, C_WHITE)
    icon_drops(ev, cx, cy + 0.24 * w, w, C_CYAN, 0.48 * w)
  elseif kind == "snow" then
    icon_cloud(ev, cx, cy - 0.30 * w, w * 0.86, C_WHITE)
    icon_flakes(ev, cx, cy + 0.42 * w, w, C_WHITE)
  elseif kind == "storm" then
    icon_cloud(ev, cx, cy - 0.34 * w, w * 0.86, C_GRAY)
    icon_bolt(ev, cx, cy + 0.10 * w, w, C_YELLOW)
  else
    icon_cloud(ev, cx, cy, w * 0.92, C_WHITE)
  end
end

-- 992 layout: cities across, days down. The left gutter (52..240) holds the
-- day, each city owns a 333-wide column after it, and the last column ends at
-- 1249 - the same right margin the header and footer use.
local WX_GRID_X0 = 250
local WX_GRID_W  = 333
local WX_ROW_Y0  = 200
local WX_ROW_H   = 148

local function tt_wx_body(ev)
  local wx = tt.wx
  if not wx then
    txt(ev, 7, 52, 190, 18, C_GRAY, "LOADING . . .")
    return
  end
  if wx.err then
    txt(ev, 7, 52, 190, 18, C_GRAY, "PAGE NOT AVAILABLE")
    txt(ev, 7, 52, 230, 18, C_GRAY, "CHECK NETWORK - RETRYING SOON")
    return
  end
  for ci, city in ipairs(wx.cities) do
    local cx = WX_GRID_X0 + (ci - 0.5) * WX_GRID_W
    txt(ev, 8, cx, 126, 22, C_YELLOW, city.name)
    txt(ev, 8, cx, 160, 15, C_WHITE, city.now)
  end
  draw(ev, C_DIM, ass_rect(52, 192, 1249, 194))
  for d = 1, WX_DAYS do
    local cy  = WX_ROW_Y0 + (d - 0.5) * WX_ROW_H
    local day = wx.days[d] or {}
    txt(ev, 4, 52, cy - 14, 24, (d == 1) and C_YELLOW or C_CYAN, day.name or "---")
    txt(ev, 4, 52, cy + 20, 15, C_GRAY, day.date or "")
    for ci, city in ipairs(wx.cities) do
      local cell = city.days[d]
      local cx = WX_GRID_X0 + (ci - 0.5) * WX_GRID_W
      if cell then
        wx_icon(ev, cell.icon, cx - 104, cy - 4, 36)
        -- Built by concat, not :format - the inline colour overrides are the
        -- kind of thing that turns into a miscounted argument list.
        txt(ev, 4, cx - 46, cy - 16, 24, C_YELLOW,
            cell.hi .. "{\\1c" .. C_GRAY .. "}/{\\1c" .. C_CYAN .. "}" .. cell.lo)
        txt(ev, 4, cx - 46, cy + 20, 13, C_WHITE, cell.desc)
      else
        txt(ev, 4, cx - 46, cy - 4, 18, C_GRAY, "--")
      end
    end
    draw(ev, C_DIM, ass_rect(52, WX_ROW_Y0 + d * WX_ROW_H, 1249,
                             WX_ROW_Y0 + d * WX_ROW_H + 2))
  end
end

-- The list pages and the news pages share this; only the metrics differ.
-- `cur` is relative to the rows handed in, so the caller does the paging.
local function tt_rows(ev, rows, y, pitch, fs, cur)
  for i, l in ipairs(rows) do
    local mark, color = "", l.color
    if cur then
      -- The gutter is the renderer's, not the row's, so a selectable page
      -- and a plain one build their lines exactly the same way.
      mark = (i == cur) and "> " or "  "
      if i == cur then color = C_YELLOW end
    end
    txt(ev, 7, 52, y, l.big and (fs + 6) or fs, color, mark .. l.text)
    y = y + (l.big and (pitch + 10) or pitch)
  end
end

local function tt_render()
  if not tt then ov_tt.data = ""; ov_tt:update(); set_box("tt", nil); return end
  local page = TELETEXT[tt.no]
  -- The body decides how many subpages there are, and the footer prints it,
  -- so the body is built first and appended after the chrome.
  local body, nsub = {}, 1
  if page.type == "weather" then
    tt_wx_body(body)
    tt.sub = 1
  elseif tt.pages then
    -- Pre-paginated: one page per feed, already cut to fit (991).
    nsub = math.max(1, #tt.pages)
    tt.sub = math.max(1, math.min(tt.sub, nsub))
    tt_rows(body, tt.pages[tt.sub] or {}, 170, 30, 20, nil)
  else
    local lines = tt.lines or {}
    nsub = math.max(1, math.ceil(#lines / LINES_PER_PAGE))
    -- On a page with a cursor the cursor owns the subpage, not the other way
    -- round: scrolling off the bottom row turns the page under you.
    if tt.cur and #lines > 0 then
      tt.cur = math.max(1, math.min(tt.cur, #lines))
      tt.sub = math.floor((tt.cur - 1) / LINES_PER_PAGE) + 1
    end
    tt.sub = math.max(1, math.min(tt.sub, nsub))
    local first, slice = (tt.sub - 1) * LINES_PER_PAGE + 1, {}
    for i = first, math.min(first + LINES_PER_PAGE - 1, #lines) do
      slice[#slice + 1] = lines[i]
    end
    tt_rows(body, slice, 170, 40, 18, tt.cur and (tt.cur - first + 1) or nil)
  end

  local ev = {}
  -- opaque black screen
  ev[#ev + 1] = ("{\\an7\\pos(0,0)\\p1\\1c%s\\bord0\\shad0}m 0 0 l 1280 0 l 1280 720 l 0 720{\\p0}")
                :format(C_BLACK)
  -- header row: page number + clock
  txt(ev, 7, 52, 30, 22, C_WHITE, "P" .. tt.no)
  txt(ev, 9, 1228, 30, 22, C_WHITE, os.date("%H:%M"))
  -- big yellow title
  txt(ev, 7, 52, 80, 44, C_YELLOW, page.title)
  for _, e in ipairs(body) do ev[#ev + 1] = e end
  -- footer: fastext-style colored row + subpage indicator.
  -- One format arg (FONT) and no %s — the colours are literal. Adding a
  -- page here means adding literal text, never another %s (constraint 4).
  ev[#ev + 1] = ("{\\an7\\pos(52,684)\\fn%s\\fs18\\bord0\\shad0}" ..
                 "{\\1c&H3333FF&}991 NEWS  {\\1c&H33FF33&}992 WX  " ..
                 "{\\1c&H00FFFF&}993 FILM  {\\1c&HFFFFFF&}994 TV  " ..
                 "{\\1c&H888888&}999 GUIDE")
                :format(FONT)
  txt(ev, 9, 1228, 684, 18, C_GRAY, tt.sub .. "/" .. nsub)
  ov_tt.data = table.concat(ev, "\n")
  ov_tt:update()
  -- A page is an opaque screen: no static gets drawn behind it at all.
  set_box("tt", { x0 = 0, y0 = 0, x1 = OSD_W, y1 = OSD_H })
end

local function tt_set_lines(lines)
  if tt then tt.lines, tt.pages = lines, nil; tt_render() end
end

local function tt_set_pages(pages)
  if tt then tt.pages, tt.lines = pages, nil; tt_render() end
end

local function tt_guide_lines()
  local lines = {}
  for _, no in ipairs(chnos) do
    local mark = TELETEXT[no] and "*" or " "
    lines[#lines + 1] = { text = ("%3d %s %s"):format(no, mark, chan_name(no)),
                          color = (#lines % 2 == 0) and C_CYAN or C_WHITE }
  end
  return lines
end

-- 993 / 994: the on-demand library, rendered as a teletext index.
-- Rows carry their entry in `item`; tt_render ignores the extra field and
-- select_press is what reads it back out.
local function tt_library_lines(kind)
  load_library()
  local items = (library and library[kind]) or {}
  local lines = {}
  for i, it in ipairs(items) do
    -- 2 columns of gutter belong to the renderer, so lay out inside 50.
    local left = ("%3d %s"):format(i, ass_escape(it.title))
    local pad = 46 - ulen(left) - ulen(it.year)
    if pad < 1 then pad = 1 end   -- never truncate: cutting UTF-8 by bytes splits codepoints
    lines[i] = { text = left .. (" "):rep(pad) .. it.year,
                 color = (i % 2 == 1) and C_CYAN or C_WHITE,
                 item = it }
  end
  if #lines == 0 then
    lines[1] = { text = "NO ENTRIES IN library.tsv", color = C_GRAY }
    lines[2] = { text = "", color = C_GRAY }
    lines[3] = { text = "NOTHING GENERATES THAT FILE YET.", color = C_GRAY }
  end
  return lines
end

-- One headline, one row, always. Wrapping was worse than shortening: a
-- two-line headline could be split across a subpage break, so the top of a
-- page was the tail of a sentence whose head you had already scrolled past.
local function tt_headline(text, width)
  if ulen(text) <= width then return text end
  -- An RSS title's " - tail" is nearly always a subtitle, so dropping it
  -- leaves a sentence that still ends where the writer ended it.
  local head = text:match("^(.-)%s+%-%s")
  if head and ulen(head) <= width and ulen(head) >= 20 then return head end
  -- Otherwise cut at a word boundary and say so with the ellipsis. Never
  -- mid-word, and never by bytes (constraint 5).
  local out = ""
  for word in text:gmatch("%S+") do
    local try = (out == "") and word or (out .. " " .. word)
    if ulen(try) > width - 3 then break end
    out = try
  end
  if out == "" then out = usub(text, width - 3) end   -- one absurd word
  return out .. "..."
end

-- 991: one feed per subpage, NEWS_ROWS headlines, alternating colours.
local function tt_feed_rows(feed, body)
  local rows = {}
  for item in body:gmatch("<item>(.-)</item>") do
    local title = item:match("<title>%s*(.-)%s*</title>")
    if title then
      title = tt_decode(title)
      if feed.clean then title = feed.clean(title) end
      title = ass_escape(tt_headline(title, NEWS_COLS))
      if title ~= "" then
        rows[#rows + 1] = { text = title,
                            color = (#rows % 2 == 0) and C_CYAN or C_WHITE }
      end
    end
    if #rows >= NEWS_ROWS then break end
  end
  return rows
end

local function tt_news_fetch(pageno)
  local page = TELETEXT[pageno]
  local key = "news:" .. pageno
  local cached = rss_cache[key]
  if cached and (os.time() - cached.t) < RSS_CACHE_SECS then
    tt_set_pages(cached.pages)
    return
  end
  tt_set_lines({ { text = "LOADING . . .", color = C_GRAY } })
  local gen = tt.gen
  local slots, pending = {}, #page.feeds
  for i, feed in ipairs(page.feeds) do
    mp.command_native_async(
      { name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl", "-sL", "--max-time", "10", feed.url } },
      function(ok, result)
        -- Drop a reply for a page we have since left or reopened.
        if not (tt and tt.no == pageno and tt.gen == gen) then return end
        slots[i] = tt_feed_rows(feed, ok and result.status == 0 and result.stdout or "")
        pending = pending - 1
        if pending > 0 then return end   -- the slower feed assembles the page
        local pages, any = {}, false
        for fi, f in ipairs(page.feeds) do
          local pg = { { text = f.label, color = C_YELLOW, big = true } }
          local got = slots[fi] or {}
          if #got == 0 then
            pg[#pg + 1] = { text = "NOT AVAILABLE", color = C_GRAY }
          else
            any = true
            for _, l in ipairs(got) do pg[#pg + 1] = l end
          end
          pages[fi] = pg
        end
        -- Half a page is still a page; only a total blank is worth retrying.
        if any then rss_cache[key] = { t = os.time(), pages = pages } end
        tt_set_pages(pages)
      end)
  end
end

-- 992: WMO weather codes. Kept to 13 characters because the caption sits in
-- a 320-wide grid cell next to the icon, not on a full-width row.
local WX_CODES = {
  [0] = "CLEAR", [1] = "MOSTLY CLEAR", [2] = "PART CLOUDY", [3] = "OVERCAST",
  [45] = "FOG", [48] = "RIME FOG",
  [51] = "LT DRIZZLE", [53] = "DRIZZLE", [55] = "HVY DRIZZLE",
  [56] = "FRZ DRIZZLE", [57] = "FRZ DRIZZLE",
  [61] = "LIGHT RAIN", [63] = "RAIN", [65] = "HEAVY RAIN",
  [66] = "FRZ RAIN", [67] = "FRZ RAIN",
  [71] = "LIGHT SNOW", [73] = "SNOW", [75] = "HEAVY SNOW", [77] = "SNOW GRAINS",
  [80] = "LT SHOWERS", [81] = "SHOWERS", [82] = "HVY SHOWERS",
  [85] = "SNOW SHOWERS", [86] = "SNOW SHOWERS",
  [95] = "T-STORM", [96] = "T-STORM HAIL", [99] = "T-STORM HAIL",
}

-- Same codes, grouped into the eight shapes wx_icon() knows how to draw.
local WX_ICONS = {
  [0] = "sun", [1] = "suncloud", [2] = "suncloud", [3] = "cloud",
  [45] = "fog", [48] = "fog",
  [51] = "drizzle", [53] = "drizzle", [55] = "drizzle",
  [56] = "drizzle", [57] = "drizzle",
  [61] = "rain", [63] = "rain", [65] = "rain", [66] = "rain", [67] = "rain",
  [71] = "snow", [73] = "snow", [75] = "snow", [77] = "snow",
  [80] = "rain", [81] = "rain", [82] = "rain",
  [85] = "snow", [86] = "snow",
  [95] = "storm", [96] = "storm", [99] = "storm",
}

local function wx_desc(code)
  return WX_CODES[tonumber(code) or -1] or "---"
end

local function wx_kind(code)
  return WX_ICONS[tonumber(code) or -1] or "cloud"
end

-- Open-Meteo hands back a decimal; a forecast grid wants a whole number.
local function wx_temp(v)
  local n = tonumber(v)
  if not n then return "--" end
  return tostring(math.floor(n + 0.5))
end

-- Pull a JSON array's contents out by name. Deliberately not a JSON parser:
-- Open-Meteo's shape is flat and known, and a real parser in Lua patterns is
-- how constraint 4 gets violated. `%[` is what separates the daily arrays
-- from the identically-named scalars in `current`.
local function wx_array(body, name)
  local out = {}
  local raw = body:match('"' .. name .. '":%[(.-)%]')
  if not raw then return out end
  for v in raw:gmatch("[^,]+") do
    out[#out + 1] = (v:gsub('"', ""):gsub("%s", ""))
  end
  return out
end

-- One city's reply -> { now = "NOW 24C", days = {...}, dates = {...} }, or nil
-- if the body is not a forecast (network down, rate limit, error JSON).
local function wx_parse(body)
  -- `"temperature_2m":` cannot match `"temperature_2m_max":`, and the units
  -- block holds a string, so the first numeric hit is `current`.
  local temp = body:match('"temperature_2m":(%-?[%d%.]+)')
  if not temp then return nil end
  local when = wx_array(body, "time")
  local hi   = wx_array(body, "temperature_2m_max")
  local lo   = wx_array(body, "temperature_2m_min")
  local dc   = wx_array(body, "weather_code")
  local out = { now = "NOW " .. wx_temp(temp) .. "C", days = {}, dates = {} }
  for i = 1, WX_DAYS do
    out.days[i] = { hi = wx_temp(hi[i]), lo = wx_temp(lo[i]),
                    desc = wx_desc(dc[i]), icon = wx_kind(dc[i]) }
    out.dates[i] = when[i]
  end
  return out
end

-- The three cities share a date axis, so the row labels come from whichever
-- city answered first rather than being repeated in every column.
local function wx_daylabels(dates)
  local days = {}
  for i = 1, WX_DAYS do
    local yy, mm, dd = (dates[i] or ""):match("(%d+)-(%d+)-(%d+)")
    if yy then
      local t = os.time{ year = tonumber(yy), month = tonumber(mm),
                         day = tonumber(dd), hour = 12 }
      days[i] = { name = os.date("%a", t):upper(), date = os.date("%d.%m", t) }
    else
      days[i] = { name = "---", date = "" }
    end
  end
  return days
end

-- One request per city. Open-Meteo can take a comma-separated list, but it
-- answers with an array of objects and the flat-pattern reader above would
-- read the first city's numbers three times - three curls is the same shape
-- as the two the news page already runs.
local function tt_weather_fetch(pageno)
  if wx_cache and (os.time() - wx_cache.t) < WX_CACHE_SECS then
    tt.wx = wx_cache.wx
    tt_render()
    return
  end
  tt.wx = nil
  tt_render()
  local gen = tt.gen
  local slots, pending = {}, #WX_CITIES
  for i, city in ipairs(WX_CITIES) do
    local url = ("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f" ..
                 "&current=temperature_2m,weather_code" ..
                 "&daily=weather_code,temperature_2m_max,temperature_2m_min" ..
                 "&timezone=auto&forecast_days=%d"):format(city.lat, city.lon, WX_DAYS)
    mp.command_native_async(
      { name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl", "-sL", "--max-time", "10", url } },
      function(ok, result)
        -- Drop a reply for a page we have since left or reopened.
        if not (tt and tt.no == pageno and tt.gen == gen) then return end
        slots[i] = wx_parse(ok and result.status == 0 and result.stdout or "")
        pending = pending - 1
        if pending > 0 then return end   -- the slowest city assembles the page
        local wx, any = { cities = {}, days = nil }, false
        for ci, c in ipairs(WX_CITIES) do
          local p = slots[ci]
          if p then
            any = true
            if not wx.days then wx.days = wx_daylabels(p.dates) end
          end
          wx.cities[ci] = { name = c.name, now = p and p.now or "NO DATA",
                            days = p and p.days or {} }
        end
        if not any then
          tt.wx = { err = true }
          tt_render()
          return
        end
        -- Two cities out of three is still a page; only a total blank retries.
        wx_cache = { t = os.time(), wx = wx }
        tt.wx = wx
        tt_render()
      end)
  end
end

local function tt_open(no)
  tt_gen = tt_gen + 1
  tt = { no = no, sub = 1, lines = nil, gen = tt_gen }
  local page = TELETEXT[no]
  if page.type == "guide" then
    tt_set_lines(tt_guide_lines())
  elseif page.type == "library" then
    tt.cur = 1                      -- a cursor is what makes the page selectable
    tt_set_lines(tt_library_lines(page.kind))
  elseif page.type == "weather" then
    tt_render()          -- draw frame instantly
    tt_weather_fetch(no)
  else
    tt_render()
    tt_news_fetch(no)
  end
end

local function tt_close()
  tt = nil
  ov_tt.data = ""
  ov_tt:update()
  set_box("tt", nil)
end

-- Left/right on a library page jumps a whole initial. Paging a few hundred
-- titles eleven rows at a time with a d-pad is the difference between a
-- catalogue you use and one you don't.
local function tt_letter_jump(dir)
  local lines = tt and tt.lines or {}
  local n = #lines
  if n == 0 or not tt.cur then return end
  local function initial(i)
    local it = lines[i] and lines[i].item
    return it and it.title:sub(1, 1):upper() or ""
  end
  local here, i = initial(tt.cur), tt.cur
  if dir > 0 then
    while i <= n and initial(i) == here do i = i + 1 end
    tt.cur = math.min(i, n)
  else
    -- Back goes to the top of this block first, and only then into the one
    -- above it — the same way holding rewind works on a real box.
    while i > 1 and initial(i - 1) == here do i = i - 1 end
    if i == tt.cur and i > 1 then
      local prev = initial(i - 1)
      i = i - 1
      while i > 1 and initial(i - 1) == prev do i = i - 1 end
    end
    tt.cur = i
  end
  tt_render()
end

local function tt_play_selected()
  local row = tt and tt.lines and tt.lines[tt.cur or -1]
  local it = row and row.item
  if not it then return end
  if it.url == "" then
    -- The catalogue is real, the backend behind it is not wired up yet. Say
    -- so on the banner rather than dropping to silent static.
    show_banner(tt.no, "NO SOURCE - " .. it.title)
    return
  end
  local pageno = tt.no
  ondemand = it
  tt_close()
  dead, loading, playing = false, true, nil
  static_on()
  mp.commandv("loadfile", it.url, "replace")
  show_banner(pageno, it.title)
end

------------------------------------------------------------------- tuning -----
local function stop_retry()
  if retry_timer then retry_timer:kill(); retry_timer = nil end
end

local function stop_zap()
  if zap_timer then zap_timer:kill(); zap_timer = nil end
end

-- What tune() eventually gets round to, once the number stops moving.
local function commit_tune()
  stop_zap()
  local no = current
  if not no then return end

  if TELETEXT[no] then
    -- teletext replaces the picture; last channel's audio keeps running
    static_off()
    tt_open(no)
    playing = nil
    return
  end
  tt_close()

  local ch = channels[no]
  if not ch then
    -- empty channel number: pure static, like it should be
    dead, loading, playing = true, false, nil
    static_on()
    mp.commandv("stop")
    return
  end
  if playing == no and not dead then
    -- Zapped away and straight back: the stream never stopped, so don't
    -- throw away a working one. Still loading means keep waiting on static.
    if not loading then static_off() end
    return
  end
  dead, loading, playing = false, true, no
  static_on()
  mp.commandv("loadfile", ch.url, "replace")
end

local function tune(no)
  stop_retry()
  digit_buf = ""
  -- Zapping abandons a film: from here on end-file is a channel's business
  -- again, not the library's.
  ondemand = nil
  current = no
  show_banner(no, chan_name(no))

  -- A page is text we already have; making it wait would just feel broken.
  if TELETEXT[no] then commit_tune(); return end

  -- The picture cuts to static now, but the stream is not opened until the
  -- number has settled. Holding channel-up used to queue one loadfile per
  -- channel, each taking seconds to open a remote stream and then being
  -- thrown away by the next one - zapping through ten channels meant ten
  -- stalls. The old channel's audio keeps running under the static until the
  -- new one commits, which is also what stops fast zapping sounding gappy.
  static_on()
  stop_zap()
  zap_timer = mp.add_timeout(ZAP_DELAY, guard(commit_tune))
end

local function tune_relative(dir)
  if #chnos == 0 then return end
  local base = current or chnos[1]
  local idx = 1
  for i, no in ipairs(chnos) do
    if no == base then idx = i; break end
    if no > base then idx = (dir > 0) and (i - 1) or i; break end
  end
  idx = ((idx - 1 + dir) % #chnos) + 1
  tune(chnos[idx])
end

local function mark_dead()
  if not current or TELETEXT[current] then return end
  dead, loading = true, false
  static_on()
  stop_retry()
  retry_timer = mp.add_timeout(RETRY_SECONDS, guard(function()
    if dead and current and channels[current] then tune(current) end
  end))
end

-- Stream events. While a zap is pending these all belong to the channel we
-- are leaving, not the one on the banner - acting on them would drop the
-- static off the old channel's picture while the banner reads a new number.
mp.register_event("playback-restart", guard(function()
  if zap_timer then return end
  if loading or dead then
    loading, dead = false, false
    stop_retry()
    static_off()
  end
end))

mp.register_event("end-file", guard(function(ev)
  if zap_timer then return end
  if ondemand then
    -- A film is not a channel. Reaching the end is a normal thing to do, and
    -- a failure is not worth retrying every 12s forever — either way, back to
    -- the page it was picked from.
    local it, failed = ondemand, (ev.reason == "error")
    ondemand = nil
    loading, dead = false, false
    static_off()
    if current and TELETEXT[current] then
      tt_open(current)
      show_banner(current, failed and ("FAILED - " .. it.title) or it.title)
    end
    return
  end
  if TELETEXT[current or -1] then return end
  if ev.reason == "error" or ev.reason == "eof" or ev.reason == "unknown" then
    mark_dead()
  end
end))

mp.observe_property("paused-for-cache", "bool", guard(function(_, v)
  if zap_timer or loading or dead then return end
  -- On-demand buffers behind static too; it just isn't on a channel number.
  if not ondemand and (not current or TELETEXT[current]) then return end
  if v then
    mp.add_timeout(1.0, guard(function()
      if mp.get_property_bool("paused-for-cache") then static_on() end
    end))
  else
    static_off()
  end
end))

------------------------------------------------------------------- digits -----
local function digit_commit()
  if digit_timer then digit_timer:kill(); digit_timer = nil end
  local no = tonumber(digit_buf)
  digit_buf = ""
  if no then tune(no) end
end

local function digit_press(d)
  digit_buf = digit_buf .. tostring(d)
  show_banner(digit_buf .. string.rep("-", math.max(0, 2 - #digit_buf)), "")
  if digit_timer then digit_timer:kill() end
  if #digit_buf >= 3 then
    digit_commit()
  else
    digit_timer = mp.add_timeout(DIGIT_TIMEOUT, guard(digit_commit))
  end
  -- Digits also arrive from the number keys and the TV remote, not just from
  -- the pad's own OK button, and the pad shows the buffer.
  if keypad then keypad_render() end
end

------------------------------------------------------------------- keypad -----
local PAD = {
  { "1", "2", "3" },
  { "4", "5", "6" },
  { "7", "8", "9" },
  { "C", "0", "OK" },
}

keypad_render = function()
  if not keypad then
    ov_keypad.data = ""
    ov_keypad:update()
    set_box("keypad", nil)
    return
  end
  local ev = {}
  local x0, y0, cw, chh = 980, 210, 84, 74
  local pad = { x0 = x0 - 34, y0 = y0 - 74,
                x1 = x0 - 34 + 3 * cw + 66, y1 = y0 - 74 + 4 * chh + 118 }
  -- Backdrop. A scrim over a live picture, but opaque once the static is up:
  -- the static leaves this box empty, so anything less than opaque shows the
  -- frozen last frame of the channel you left through the keypad.
  ev[#ev + 1] = ("{\\an7\\pos(%d,%d)\\p1\\1c%s\\1a%s\\bord0\\shad0}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}")
                :format(pad.x0, pad.y0, C_BLACK, static.on and "&H00&" or "&H30&",
                        3 * cw + 66, 3 * cw + 66, 4 * chh + 118, 4 * chh + 118)
  -- buffer display
  local buf = digit_buf .. string.rep("_", math.max(0, 3 - #digit_buf))
  ev[#ev + 1] = ("{\\an8\\pos(%d,%d)\\fn%s\\fs30\\1c%s\\bord0\\shad0}CH %s")
                :format(x0 + 1.5 * cw - 10, y0 - 58, FONT, C_GREEN, buf)
  for r = 1, 4 do
    for c = 1, 3 do
      local sel = (keypad.r == r and keypad.c == c)
      local label = PAD[r][c]
      ev[#ev + 1] = ("{\\an5\\pos(%d,%d)\\fn%s\\fs%d\\1c%s\\bord%d\\3c%s\\shad0}%s")
                    :format(x0 + (c - 1) * cw + cw / 2 - 10,
                            y0 + (r - 1) * chh + chh / 2,
                            FONT, sel and 34 or 26,
                            sel and C_YELLOW or C_WHITE,
                            sel and 2 or 0, C_BLACK, label)
    end
  end
  ov_keypad.data = table.concat(ev, "\n")
  ov_keypad:update()
  set_box("keypad", static.on and pad or nil)
end

local function keypad_toggle()
  keypad = keypad and nil or { r = 1, c = 1 }
  keypad_render()
end

local function keypad_select()
  if not keypad then return end
  local label = PAD[keypad.r][keypad.c]
  if label == "C" then
    digit_buf = ""
    if digit_timer then digit_timer:kill(); digit_timer = nil end
  elseif label == "OK" then
    keypad = nil
    digit_commit()
  else
    digit_press(label)
    if digit_buf == "" then keypad = nil end   -- 3rd digit auto-tuned
  end
  keypad_render()
end

------------------------------------------------------------------- input ------
local function nav(dr, dc)
  if keypad then
    keypad.r = ((keypad.r - 1 + dr) % 4) + 1
    keypad.c = ((keypad.c - 1 + dc) % 3) + 1
    keypad_render()
  elseif tt and tt.cur then
    -- Selectable page: rows under up/down, initials under left/right.
    if dr ~= 0 then
      tt.cur = tt.cur + dr
      tt_render()
    elseif dc ~= 0 then
      tt_letter_jump(dc)
    end
  elseif tt and (dr ~= 0 or dc ~= 0) then
    -- 991 is two subpages side by side, so left/right turns them too: on a
    -- page-per-language layout, "next page" is a sideways thought.
    tt.sub = tt.sub + ((dr ~= 0) and dr or dc)
    tt_render()
  elseif dr ~= 0 then
    tune_relative(-dr)     -- dpad up = channel up
  end
end

local function select_press()
  if keypad then keypad_select()
  elseif tt and tt.cur then tt_play_selected() end
end

local function back_press()
  if keypad then
    keypad = nil
    keypad_render()
  elseif ondemand then
    -- Stop the film and go back to the page it was picked from, rather than
    -- straight out of cable mode. Backing out of THAT still quits.
    local it = ondemand
    ondemand = nil
    loading, dead = false, false
    mp.commandv("stop")
    static_off()
    if current and TELETEXT[current] then
      tt_open(current)
      show_banner(current, chan_name(current))
    end
    mp.msg.verbose("stopped on-demand: " .. it.title)
  elseif tt then
    -- leave teletext back to the last real channel's picture
    tt_close()
    if current and TELETEXT[current] then
      show_banner(current, chan_name(current))
    end
  else
    -- Nothing left to back out of: leave cable mode. The launcher's Chromium
    -- is still running underneath and cage raises whatever window is newest,
    -- so quitting mpv IS "return to the menu". It is also the only way out
    -- with a keyboard in a dev session, where mpv is a child of server.py in
    -- its own process group and a terminal ctrl+c never reaches it.
    mp.commandv("quit")
  end
end

mp.add_key_binding(nil, "ch-up",    guard(function() tune_relative(1)  end), { repeatable = true })
mp.add_key_binding(nil, "ch-down",  guard(function() tune_relative(-1) end), { repeatable = true })
mp.add_key_binding(nil, "keypad",   guard(keypad_toggle))
mp.add_key_binding(nil, "nav-up",    guard(function() nav(-1, 0) end), { repeatable = true })
mp.add_key_binding(nil, "nav-down",  guard(function() nav(1, 0)  end), { repeatable = true })
mp.add_key_binding(nil, "nav-left",  guard(function() nav(0, -1) end), { repeatable = true })
mp.add_key_binding(nil, "nav-right", guard(function() nav(0, 1)  end), { repeatable = true })
mp.add_key_binding(nil, "select",   guard(select_press))
mp.add_key_binding(nil, "back",     guard(back_press))
mp.add_key_binding(nil, "guide",    guard(function() tune(999) end))
for d = 0, 9 do
  mp.add_key_binding(nil, "digit-" .. d, guard(function() digit_press(d) end))
end

------------------------------------------------------------------- boot -------
math.randomseed(os.time())
load_channels()
mp.add_timeout(0.4, guard(function()
  local first = nil
  for _, no in ipairs(chnos) do
    if channels[no] then first = no; break end
  end
  if first then tune(first) else tune(999) end
end))
