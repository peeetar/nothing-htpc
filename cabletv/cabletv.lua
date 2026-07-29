-- cabletv.lua ---------------------------------------------------------------
-- Old-school cable TV mode for mpv.
--   * curated channels.m3u with fixed channel numbers (tvg-chno)
--   * shoulder buttons / dpad up-down zap channels
--   * X opens a keypad grid; digits tune directly (3 digits = instant)
--   * banner: number + name, top-left, pixel font, fades after 5 s
--   * animated static on dead channels and while buffering
--   * teletext: 991 news, 992 weather, 993/994 the on-demand library,
--     999 the channel guide
-- No volume control on purpose - that's the TV's job.
------------------------------------------------------------------------------

local mp = require "mp"
local utils = require "mp.utils"

-- config ---------------------------------------------------------------------
local DIR             = os.getenv("CABLETV_DIR") or (os.getenv("HOME") .. "/nothing-htpc/cabletv")
local CHANNELS_FILE   = DIR .. "/channels.m3u"
local LIBRARY_FILE    = DIR .. "/library.tsv"
-- library.tsv's url column holds `ee3:<id>`, not a playable URL - the links
-- are minted per playback and would be stale by the time anyone pressed OK.
-- This turns one into a URL, at play time, by asking the daemon on the LXC.
local RESOLVER        = DIR .. "/ee3resolve.py"
local RESOLVE_SECONDS = tonumber(os.getenv("CABLETV_RESOLVE_SECONDS")) or 130
-- /resolve hands back a `magnet:` URI and the Pi does its own downloading.
-- torrentstream.sh runs peerflix/webtorrent in SERVER mode and this script
-- loadfiles the local http url into the mpv it is already running in - never
-- `--mpv`, which would spawn a second player on top of the cable UI.
local TORRENT_SH      = DIR .. "/torrentstream.sh"
local TORRENT_PORT    = tonumber(os.getenv("CABLETV_TORRENT_PORT")) or 8888
-- How long a magnet gets to find peers and buffer its first pieces before the
-- box gives up. Longer than a resolve: this is a real download over a domestic
-- line, and a cold, poorly-seeded torrent genuinely takes a minute.
local TORRENT_SECONDS = tonumber(os.getenv("CABLETV_TORRENT_SECONDS")) or 150
local TORRENT_POLL    = 2           -- seconds between "is it servable yet"
-- Films get transport controls; channels deliberately do not (constraint 3 -
-- the player has cable box buttons only). Seeking live TV means nothing, and
-- pausing it just desyncs the stream, so both are gated on `ondemand`.
local SEEK_STEP       = tonumber(os.getenv("CABLETV_SEEK_STEP")) or 30
-- library.tsv is a CACHE of the daemon's /library.tsv, not hand-maintained
-- state (unlike channels.m3u). Opening 993 with no cache fetches it and shows
-- BUFFERING; opening one older than the TTL shows the cached page instantly
-- and refreshes behind it, because a catalogue you can already read beats a
-- fresher one you have to wait for.
local LIBRARY_SECONDS = tonumber(os.getenv("CABLETV_LIBRARY_SECONDS")) or 90
local LIBRARY_TTL     = tonumber(os.getenv("CABLETV_LIBRARY_TTL")) or 21600  -- 6h
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
-- One word for "this page is waiting on the network", used by every page that
-- fetches: news, weather and the library. Same word the picture uses when a
-- stream is filling its cache, so it means the same thing everywhere.
local LOADING_TEXT    = "BUFFERING . . ."
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
local library = nil        -- kind -> sorted list of entries (see load_library)
local library_urls = 0     -- how many of those have something to play
local library_busy = false -- a /library.tsv fetch is in flight
local library_seq = 0      -- same generation trick as resolve_seq, for the fetch
local ondemand = nil       -- the library entry currently playing, if any
local resolving = nil      -- page number a resolve was started from, while it runs
-- The torrent engine behind an on-demand film: {id=, port=, timer=} while one
-- is running. `id` is the async subprocess handle, which is what kills it -
-- an engine nobody stopped goes on seeding a film nobody is watching.
local torrent = nil
-- Bumped whenever the box decides to watch something else. A resolve can take
-- a minute, and a reply that arrives after the viewer has zapped away must not
-- yank them back - the callback compares against this and drops itself.
local resolve_seq = 0

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
-- The on-demand transport bar. Created BEFORE ov_tt and after ov_banner, and
-- the order is the z order (constraint 20): a teletext page still covers this,
-- which is right - the page is opaque and you are not scrubbing while reading
-- it. It never coexists with the banner; whichever shows hides the other.
local ov_trans   = mp.create_osd_overlay("ass-events")
local ov_tt      = mp.create_osd_overlay("ass-events")
local OSD_W, OSD_H = 1280, 720
for _, ov in pairs({ov_banner, ov_keypad, ov_trans, ov_tt}) do
  ov.res_x, ov.res_y = OSD_W, OSD_H
end
-- Only the banner needs measuring: it is the one box whose size depends on
-- how long a channel name is. The keypad and teletext know their own, and the
-- transport bar works its own out arithmetically - it draws two blocks at
-- opposite ends of the screen, and one bounding box round the pair would be
-- the whole screen, which is not a hole you can punch in the static.
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

-- Forward declarations: all three of these fill their own hole in the static,
-- so they have to be redrawn whenever the static comes and goes.
local render_banner, keypad_render, render_trans

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
  render_trans()
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
  render_trans()
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

-- `sticky` keeps it up until somebody else shows a banner instead of fading
-- after 5 s. Exactly one thing uses it: a resolve can run for a minute, and a
-- screen of silent static with no word on it looks like a broken box. Every
-- exit from a resolve shows a normal banner, which re-arms the fade.
local function show_banner(no, name, sticky)
  local num = tostring(no)
  if #num < 2 then num = "0" .. num end
  banner.num, banner.name, banner.shown = num, name or "", true
  render_banner()
  if banner_timer then banner_timer:kill(); banner_timer = nil end
  if sticky then return end
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

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

-- Split on tabs KEEPING empty fields. gmatch("[^\t]+") drops them, which on a
-- row with no year would shift the url into the year column and every column
-- after it - and the file is full of rows with something missing.
local function split_tabs(line)
  local out, pos = {}, 1
  while true do
    local i = line:find("\t", pos, true)
    if not i then out[#out + 1] = line:sub(pos); return out end
    out[#out + 1] = line:sub(pos, i - 1)
    pos = i + 1
  end
end

-- library.tsv -> library[kind] = sorted list of
--   { title=, year=, url=, runtime=(minutes), rating=, poster=, plot= }
-- Read lazily, on the first visit to 993/994. Reading it at boot would cost a
-- file read on every zap into cable mode for a page most sessions never open.
--
-- Columns 5-8 are what the detail panel draws and they arrive in this same
-- file on purpose: the panel redraws on every cursor move, and asking the
-- daemon per title would put a network round trip under the d-pad.
-- They are all optional - a four-column file written before the panel existed
-- still loads, it just has nothing to show on the right.
local function load_library()
  if library then return end
  library, library_urls = { movie = {}, show = {} }, 0
  local f = io.open(LIBRARY_FILE, "r")
  if not f then
    mp.msg.warn("library.tsv not found at " .. LIBRARY_FILE)
    return
  end
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" and not line:match("^%s*#") then
      local c = split_tabs(line)
      local kind, title = trim(c[1]), trim(c[2])
      if library[kind] and title ~= "" then
        local t = library[kind]
        local url = trim(c[4])
        if url ~= "" then library_urls = library_urls + 1 end
        t[#t + 1] = { title   = title,
                      year    = trim(c[3]),
                      url     = url,
                      runtime = tonumber(trim(c[5])) or 0,
                      rating  = trim(c[6]),
                      poster  = trim(c[7]),
                      plot    = trim(c[8]) }
      end
    end
  end
  f:close()
  -- FILE ORDER IS THE ORDER ON SCREEN. Not sorted here: the daemon sorts by
  -- release date, newest first, so 993 opens on what has just arrived - which
  -- is what a video shop's front rack was for. Sorting by title would throw
  -- that away and put a hundred films starting with "A" in front of it.
end

-- nil when the cache is good, otherwise why it is not:
--   "missing"  no file, no rows, or rows with nothing playable in them
--              (the placeholder shipped in the repo lands here)
--   "stale"    readable, but older than the TTL
local function library_needs_sync()
  load_library()
  if library_urls == 0 then return "missing" end
  local st = utils.file_info(LIBRARY_FILE)
  if not (st and st.is_file and (st.size or 0) > 0) then return "missing" end
  if (os.time() - (st.mtime or 0)) > LIBRARY_TTL then return "stale" end
  return nil
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
    txt(ev, 7, 52, 190, 18, C_GRAY, LOADING_TEXT)
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

------------------------------------------------------------------ transport ---
-- The on-demand transport bar: the film's title top-left, in the same green
-- pixel font and at the same coordinates a channel's banner uses, and a
-- progress bar along the bottom.
--
-- This is the one place the "cable box buttons only" rule bends (constraint 3),
-- and it bends only for films. A channel is live: there is nothing to seek to,
-- and pausing it just desyncs the stream. So every control here is gated on
-- `ondemand` being set, mpv's own OSC and default bindings stay off, and none
-- of this is reachable from a channel.
local TRANS_X0, TRANS_X1 = 52, 1228
local TRANS_BAR_Y  = 646
local TRANS_BAR_H  = 12
local TRANS_COLS   = 42        -- title, cut to fit 1176px at fs34
-- Press Start 2P advances 0.73em per glyph. Same constant the teletext column
-- counts are derived from; it is what lets a box be computed instead of measured.
local GLYPH_ADV    = 0.73

local trans = { shown = false, fade = nil, tick = nil }
local trans_show, trans_hide

local function hms(t)
  t = math.max(0, math.floor(tonumber(t) or 0))
  local h = math.floor(t / 3600)
  if h > 0 then
    return ("%d:%02d:%02d"):format(h, math.floor(t / 60) % 60, t % 60)
  end
  return ("%d:%02d"):format(math.floor(t / 60), t % 60)
end

local function frac(v, total)
  if not (v and total and total > 0) then return nil end
  return math.min(1, math.max(0, v / total))
end

render_trans = function()
  if not (trans.shown and ondemand) then
    ov_trans.data = ""
    ov_trans:update()
    set_box("trans", nil)
    set_box("transbar", nil)
    return
  end

  local pos    = mp.get_property_number("time-pos", 0) or 0
  local dur    = mp.get_property_number("duration", 0) or 0
  local paused = mp.get_property_bool("pause")
  -- Absolute playback time the demuxer has reached, NOT an amount of time
  -- ahead. On a torrent this is the honest answer to "why did it stop": you
  -- can watch the buffer edge fail to keep away from the playhead.
  local cached = mp.get_property_number("demuxer-cache-time", nil)

  local title = ass_escape(usub(ondemand.title:upper(), TRANS_COLS))
  local label = (paused and "PAUSED" or "PLAY") .. "  " ..
                ((dur > 0) and (hms(pos) .. " / " .. hms(dur)) or hms(pos))

  -- Boxes first: the static is opaque and sits above the ASS overlays, so
  -- these are both the hole it leaves and the plate that fills it.
  local tw = math.max(ulen(title) * 34, ulen(label) * 20) * GLYPH_ADV
  local tbox = { x0 = TRANS_X0 - 18, y0 = 20,
                 x1 = math.min(OSD_W, TRANS_X0 + tw + 8), y1 = 126 }
  local bbox = { x0 = TRANS_X0 - 8, y0 = TRANS_BAR_Y - 10,
                 x1 = math.min(OSD_W, TRANS_X1 + 8),
                 y1 = TRANS_BAR_Y + TRANS_BAR_H + 10 }

  local ev = {}
  if static.on then
    draw(ev, C_BLACK, ass_rect(tbox.x0, tbox.y0, tbox.x1, tbox.y1))
    draw(ev, C_BLACK, ass_rect(bbox.x0, bbox.y0, bbox.x1, bbox.y1))
  end

  local y1 = TRANS_BAR_Y + TRANS_BAR_H
  draw(ev, C_DIM, ass_rect(TRANS_X0, TRANS_BAR_Y, TRANS_X1, y1))
  local w = TRANS_X1 - TRANS_X0
  local cf = frac(cached, dur)
  if cf then
    draw(ev, C_GRAY, ass_rect(TRANS_X0, TRANS_BAR_Y, TRANS_X0 + w * cf, y1))
  end
  local pf = frac(pos, dur)
  if pf then
    draw(ev, C_GREEN, ass_rect(TRANS_X0, TRANS_BAR_Y, TRANS_X0 + w * pf, y1))
  end

  txt(ev, 7, TRANS_X0, 42, 34, C_GREEN, title)
  txt(ev, 7, TRANS_X0, 96, 20, C_GREEN, label)

  ov_trans.data = table.concat(ev, "\n")
  ov_trans:update()
  set_box("trans", static.on and tbox or nil)
  set_box("transbar", static.on and bbox or nil)
end

trans_show = function()
  if not ondemand then return end
  -- One thing owns the top-left corner. The banner and this would otherwise
  -- print a channel name straight through a film title.
  if banner.shown then
    banner.shown = false
    render_banner()
  end
  trans.shown = true
  render_trans()
  if trans.tick then trans.tick:kill() end
  trans.tick = mp.add_periodic_timer(1, guard(function() render_trans() end))
  if trans.fade then trans.fade:kill(); trans.fade = nil end
  -- While paused it stays up. A paused film with nothing on screen is
  -- indistinguishable from a frozen box, which is the failure this whole
  -- project keeps designing against.
  if mp.get_property_bool("pause") then return end
  trans.fade = mp.add_timeout(BANNER_SECONDS, guard(function() trans_hide() end))
end

trans_hide = function()
  trans.shown = false
  if trans.fade then trans.fade:kill(); trans.fade = nil end
  if trans.tick then trans.tick:kill(); trans.tick = nil end
  render_trans()
end

------------------------------------------------------- 993/994 layout ---------
-- The library pages split the screen: the list keeps the left side, the detail
-- panel the right. Press Start 2P advances 0.73em per glyph, so at fs18 a
-- 44-column row is 634px and stops short of the divider at 700. Every column
-- count here is that arithmetic, not a guess - the font is fixed-width, so a
-- row that fits on paper fits on the TV.
local LIB_ROWS    = 12              -- rows per subpage (11 elsewhere)
local LIB_Y0      = 168
local LIB_PITCH   = 40
local LIB_FS      = 18
local LIB_COLS    = 44
local PANEL_X     = 700             -- divider
local PANEL_R     = 1249            -- same right margin the header and footer use
-- The poster is not drawn yet: this rectangle is reserved for it, and nothing
-- else may claim those pixels. 2:3 is the TMDB aspect, so a w342 jpeg scaled
-- into it needs no cropping when the second pass wires it up.
local POSTER_X, POSTER_Y = 724, 132
local POSTER_W, POSTER_H = 176, 264
local META_X      = POSTER_X + POSTER_W + 22
local META_COLS   = 24              -- (PANEL_R - META_X) / (0.73 * 18)
local PLOT_COLS   = 51              -- (PANEL_R - POSTER_X) / (0.73 * 14)
local PLOT_LINES  = 9

-- Wrap to `width` CODEPOINTS, not bytes (constraint 5): plot text is whatever
-- the catalogue holds. Returns at most maxlines rows, the last ellipsised if
-- anything was dropped.
local function uwrap(text, width, maxlines)
  width = math.max(8, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    while ulen(word) > width do          -- one absurd word: cut it up
      if line ~= "" then out[#out + 1] = line; line = "" end
      local head = usub(word, width)
      out[#out + 1] = head
      word = word:sub(#head + 1)
    end
    local try = (line == "") and word or (line .. " " .. word)
    if ulen(try) <= width then
      line = try
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  if maxlines and #out > maxlines then
    for i = #out, maxlines + 1, -1 do out[i] = nil end
    out[maxlines] = usub(out[maxlines], width - 3) .. "..."
  end
  return out
end

local function lib_runtime(mins)
  if not mins or mins <= 0 then return "" end
  if mins < 60 then return ("%dM"):format(mins) end
  return ("%dH %02dM"):format(math.floor(mins / 60), mins % 60)
end

-- The right-hand panel. Called on every cursor move, so everything it draws
-- comes off the entry already in memory - no file read, no subprocess, no
-- network. That is the whole reason the metadata rides along in library.tsv.
local function tt_lib_panel(ev, it)
  draw(ev, C_DIM, ass_rect(PANEL_X, 118, PANEL_X + 2, 660))
  if not it then return end

  local x1, y1 = POSTER_X + POSTER_W, POSTER_Y + POSTER_H
  -- Frame as four rules rather than a filled box: the middle stays black, so
  -- an image dropped in later covers exactly the hole and nothing shows
  -- through around it.
  draw(ev, C_GRAY, ass_rect(POSTER_X, POSTER_Y, x1, POSTER_Y + 2))
  draw(ev, C_GRAY, ass_rect(POSTER_X, y1 - 2, x1, y1))
  draw(ev, C_GRAY, ass_rect(POSTER_X, POSTER_Y, POSTER_X + 2, y1))
  draw(ev, C_GRAY, ass_rect(x1 - 2, POSTER_Y, x1, y1))
  txt(ev, 5, (POSTER_X + x1) / 2, (POSTER_Y + y1) / 2, 12, C_GRAY,
      (it.poster ~= "") and "POSTER" or "NO POSTER")

  local y = POSTER_Y
  for _, l in ipairs(uwrap(ass_escape(it.title:upper()), META_COLS, 4)) do
    txt(ev, 7, META_X, y, 18, C_YELLOW, l)
    y = y + 26
  end
  y = y + 8
  if it.year ~= "" then
    txt(ev, 7, META_X, y, 16, C_CYAN, it.year); y = y + 30
  end
  local rt = lib_runtime(it.runtime)
  if rt ~= "" then txt(ev, 7, META_X, y, 14, C_WHITE, rt); y = y + 24 end
  if it.rating ~= "" then
    txt(ev, 7, META_X, y, 14, C_WHITE, "TMDB " .. ass_escape(it.rating))
    y = y + 24
  end
  if it.url == "" then txt(ev, 7, META_X, y, 14, C_GRAY, "NO SOURCE") end

  local py = y1 + 34
  if it.plot == "" then
    txt(ev, 7, POSTER_X, py, 14, C_GRAY, "NO SYNOPSIS")
  else
    for _, l in ipairs(uwrap(ass_escape(it.plot), PLOT_COLS, PLOT_LINES)) do
      txt(ev, 7, POSTER_X, py, 14, C_WHITE, l)
      py = py + 22
    end
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
    -- The library pages give up their right half to the detail panel, so they
    -- page by their own metrics; everything else keeps the full-width ones.
    local lib = (page.type == "library")
    local per = lib and LIB_ROWS or LINES_PER_PAGE
    nsub = math.max(1, math.ceil(#lines / per))
    -- On a page with a cursor the cursor owns the subpage, not the other way
    -- round: scrolling off the bottom row turns the page under you.
    if tt.cur and #lines > 0 then
      tt.cur = math.max(1, math.min(tt.cur, #lines))
      tt.sub = math.floor((tt.cur - 1) / per) + 1
    end
    tt.sub = math.max(1, math.min(tt.sub, nsub))
    local first, slice = (tt.sub - 1) * per + 1, {}
    for i = first, math.min(first + per - 1, #lines) do
      slice[#slice + 1] = lines[i]
    end
    local cur = tt.cur and (tt.cur - first + 1) or nil
    if lib then
      tt_rows(body, slice, LIB_Y0, LIB_PITCH, LIB_FS, cur)
      tt_lib_panel(body, tt.cur and lines[tt.cur] and lines[tt.cur].item or nil)
    else
      tt_rows(body, slice, 170, 40, 18, cur)
    end
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
  -- One line the page can say something on. It has to live here rather than on
  -- the banner: a page paints an opaque black screen and is composited above
  -- the banner overlay, so a banner shown while one is up cannot be seen. Every
  -- "it didn't work" sentence a page produces ends up on this row.
  if tt.note then txt(ev, 7, 52, 654, 14, C_YELLOW, tt.note) end
  ov_tt.data = table.concat(ev, "\n")
  ov_tt:update()
  -- A page is an opaque screen: no static gets drawn behind it at all.
  set_box("tt", { x0 = 0, y0 = 0, x1 = OSD_W, y1 = OSD_H })
end

local function tt_set_lines(lines)
  if tt then tt.lines, tt.pages = lines, nil; tt_render() end
end

-- Put one sentence on the page, if the viewer is still on the page it is
-- about. 63 columns at fs14 is 643px, which keeps the row clear of the
-- library pages' divider at x=700.
local NOTE_COLS = 63

local function tt_note(pageno, text)
  if tt and tt.no == pageno then
    tt.note = text and usub(text, NOTE_COLS) or nil
    tt_render()
  end
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

-- One row: TITLE IN CAPS (YEAR), cut to the column the list owns. Upper() in
-- Lua only touches ASCII, so a Cyrillic title comes through unharmed rather
-- than mangled, and the cut is by codepoint (constraint 5).
local function lib_row_text(it)
  local tail = (it.year ~= "") and (" (" .. it.year .. ")") or ""
  local title = ass_escape(it.title:upper())
  local room = LIB_COLS - ulen(tail)
  if ulen(title) > room then title = trim(usub(title, room - 3)) .. "..." end
  return title .. tail
end

-- 993 / 994: the on-demand library, rendered as a teletext index.
-- Rows carry their entry in `item`; tt_render hands that to the detail panel
-- and select_press is what plays it.
local function tt_library_lines(kind)
  load_library()
  local items = (library and library[kind]) or {}
  local lines = {}
  for i, it in ipairs(items) do
    lines[i] = { text = lib_row_text(it),
                 color = (i % 2 == 1) and C_CYAN or C_WHITE,
                 item = it }
  end
  if #lines == 0 then
    lines[1] = { text = (kind == "show") and "NO SERIES IN library.tsv"
                                          or "NO FILMS IN library.tsv",
                 color = C_GRAY }
    lines[2] = { text = "", color = C_GRAY }
    -- ee3 is a film catalogue, so 994 is empty by construction after a sync.
    -- Say which of the two it is rather than leaving a bare empty page.
    lines[3] = { text = (kind == "show")
                   and "THE ee3 CATALOGUE IS FILMS ONLY."
                   or "TUNE TO 993 AGAIN TO RETRY THE SYNC.",
                 color = C_GRAY }
  end
  return lines
end

-- Pull /library.tsv from the daemon into the local cache.
--
-- Async for the same reason a resolve is: paging a catalogue takes seconds to
-- tens of seconds, and the main thread has to stay free or the box looks
-- frozen. `wait` says whether the viewer is looking at BUFFERING (no cache) or
-- at last night's page (stale cache, refresh underneath).
-- The page a sync redraws is "whichever library page is open when it lands",
-- not the one that started it: the file is shared by 993 and 994, so tuning
-- from one to the other mid-fetch should be answered by the same reply.
local function library_page_kind()
  local page = tt and TELETEXT[tt.no]
  return (page and page.type == "library") and page.kind or nil
end

local function library_fetch(wait)
  -- Show BUFFERING even if this call is a no-op because a fetch is already
  -- running: 994 opened while 993 is syncing is waiting on the same file.
  if wait and tt then
    tt.cur = nil                     -- nothing to select while it is empty
    tt_set_lines({ { text = LOADING_TEXT, color = C_GRAY } })
  end
  if library_busy then return end
  library_busy = true
  library_seq = library_seq + 1
  local myseq = library_seq

  local function done(err)
    if myseq ~= library_seq then return end   -- superseded, or given up on
    library_busy = false
    if not err then
      library = nil                  -- force a reparse of the file just written
      load_library()
    end
    local kind = library_page_kind()
    if kind then
      -- A refresh under a page someone is reading must not move the cursor
      -- out from under them: hold the title, not the row number.
      local row = tt.lines and tt.lines[tt.cur or -1]
      local keep = row and row.item and row.item.title
      local lines = tt_library_lines(kind)
      tt.cur = math.min(tt.cur or 1, math.max(1, #lines))
      if keep then
        for i, l in ipairs(lines) do
          if l.item and l.item.title == keep then tt.cur = i; break end
        end
      end
      -- The sentence goes on the page, not the banner, which the page covers.
      tt.note = err and usub(err:upper(), NOTE_COLS) or nil
      tt_set_lines(lines)
    end
    if err then
      mp.msg.warn("library sync failed: " .. err)
    else
      mp.msg.info(("library: %d films, %d playable")
                  :format(#((library and library.movie) or {}), library_urls))
    end
  end

  mp.command_native_async(
    { name = "subprocess", playback_only = false,
      capture_stdout = true, capture_stderr = true,
      args = { "python3", RESOLVER, "--library", tostring(LIBRARY_SECONDS) } },
    guard(function(ok, result)
      if ok and result and result.status == 0 then
        done(nil)
      else
        local why = (result and result.stderr or ""):match("([^\n]+)%s*$")
        done((why and why ~= "") and why or "LIBRARY SYNC FAILED")
      end
    end))

  -- Backstop, exactly as for a resolve: the fetch has its own deadline inside
  -- ee3resolve.py, so this is for python3 itself never coming back. Bumping
  -- the sequence is what makes the late reply harmless.
  mp.add_timeout(LIBRARY_SECONDS + 20, guard(function()
    if myseq ~= library_seq or not library_busy then return end
    library_busy = false
    library_seq = library_seq + 1
    local kind = library_page_kind()
    if kind then
      tt.cur = tt.cur or 1
      tt.note = "LIBRARY SYNC TIMED OUT"
      tt_set_lines(tt_library_lines(kind))
    end
  end))
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
  tt_set_lines({ { text = LOADING_TEXT, color = C_GRAY } })
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
    local why = library_needs_sync()
    if why == "missing" then
      -- Nothing worth showing: BUFFERING until the daemon answers.
      library_fetch(true)
    else
      tt_set_lines(tt_library_lines(page.kind))
      -- Stale is not empty. Show it now, freshen it behind the page, and let
      -- the reply redraw the rows if the viewer is still here.
      if why == "stale" then library_fetch(false) end
    end
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

-- Left/right on a library page turns a whole subpage. Walking a couple of
-- thousand titles twelve rows at a time on a d-pad is the difference between
-- a catalogue you use and one you don't.
--
-- This used to jump to the next initial letter, which only meant anything
-- while the list was sorted by title. It is in the daemon's order now
-- (newest first), so a screenful is the unit that makes sense.
local function tt_page_jump(dir)
  local lines = tt and tt.lines or {}
  local n = #lines
  if n == 0 or not tt.cur then return end
  tt.cur = math.max(1, math.min(n, tt.cur + dir * LIB_ROWS))
  tt_render()
end

-- Stop the torrent engine, if one is running. Idempotent, and safe to call
-- from anywhere that abandons a film.
local function torrent_stop()
  if not torrent then return end
  local t = torrent
  torrent = nil
  if t.timer then t.timer:kill() end
  -- Killing the subprocess is the whole point: torrentstream.sh execs the
  -- engine, so this reaches the engine itself rather than a shell that has
  -- already forgotten about it.
  if t.id then mp.abort_async_command(t.id) end
  mp.msg.verbose("torrent engine stopped")
end

-- Commit to playing a film once there is a real URL for it.
local function play_ondemand(it, url, pageno)
  ondemand, resolving = it, nil
  dead, loading, playing = false, true, nil
  static_on()
  mp.commandv("loadfile", url, "replace")
  -- The film announces itself with the transport bar rather than a channel
  -- banner: same corner, same font, but it also brings the progress bar and
  -- says what the buttons now do.
  trans_show()
end

-- A magnet is not something mpv can open. torrentstream.sh runs peerflix or
-- webtorrent in server mode and this waits for it to have something servable,
-- then plays the LOCAL http url in the mpv we are already inside.
--
-- Two separate deadlines are at work: the engine subprocess only "returns"
-- when it dies, which is a failure worth reporting, and the probe loop gives
-- up after TORRENT_SECONDS when it is alive but has found no peers.
local function torrent_play(it, magnet, pageno)
  -- Take a fresh generation. This is the handover from resolving to
  -- downloading, and bumping it here is what disarms the resolve's own
  -- RESOLVE_SECONDS backstop — otherwise that timer would fire in the middle
  -- of a perfectly healthy download and tear it down at 130s, while the engine
  -- was still inside its own 150s deadline.
  resolve_seq = resolve_seq + 1
  local myseq = resolve_seq
  torrent_stop()
  local port = TORRENT_PORT
  torrent = { port = port }

  -- Handing over from RESOLVING to BUFFERING: the resolve is done, and what
  -- comes next is a real download that can take a while. `resolving` stays
  -- set so Back still cancels (and now also kills the engine).
  show_banner(pageno, "BUFFERING . . . " .. usub(it.title:upper(), 26), true)

  local function fail(why)
    if myseq ~= resolve_seq or ondemand then return end
    resolve_seq = resolve_seq + 1
    torrent_stop()
    loading, resolving = false, nil
    static_off()
    if TELETEXT[pageno] then
      tt_open(pageno)
      tt_note(pageno, why:upper())          -- tt_note does its own shortening
    else
      show_banner(pageno, usub(why:upper(), 40))
    end
  end

  torrent.id = mp.command_native_async(
    { name = "subprocess", playback_only = false,
      capture_stdout = true, capture_stderr = true,
      args = { "bash", TORRENT_SH, magnet, tostring(port) } },
    guard(function(ok, result)
      -- The engine exiting while we are still waiting is a failure; exiting
      -- after the film is up is just us having killed it.
      if myseq ~= resolve_seq or ondemand then return end
      if result and result.killed_by_us then return end
      local why = (result and result.stderr or ""):match("([^\n]+)%s*$")
      fail((why and why ~= "") and why or "TORRENT ENGINE STOPPED")
    end))

  -- Ask the engine where the film is, rather than assuming: peerflix serves it
  -- at "/" and webtorrent at /<infoHash>/<idx>/<name>, and --probe knows the
  -- difference. `probing` keeps one probe in flight at a time so a slow answer
  -- cannot stack them up.
  local deadline, probing = os.time() + TORRENT_SECONDS, false
  torrent.timer = mp.add_periodic_timer(TORRENT_POLL, guard(function()
    if myseq ~= resolve_seq or ondemand then return end
    if os.time() > deadline then
      fail("NOTHING TO STREAM - NO PEERS?")
      return
    end
    if probing then return end
    probing = true
    mp.command_native_async(
      { name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = { "bash", TORRENT_SH, "--probe", tostring(port) } },
      guard(function(pok, pres)
        probing = false
        if myseq ~= resolve_seq or ondemand then return end
        local url = pok and pres and pres.status == 0
                    and trim(pres.stdout or "") or ""
        if url == "" then return end            -- not serving yet; try again
        if torrent and torrent.timer then
          torrent.timer:kill()
          torrent.timer = nil
        end
        mp.msg.info("torrent ready: " .. url)
        play_ondemand(it, url, pageno)
      end))
  end))
end

-- `ee3:<id>` -> a URL, via ee3resolve.py on the LXC daemon. Async, because
-- the site may still be caching the torrent and this can take a minute; the
-- main thread must stay free or the box looks frozen (constraint 4's cousin).
local function resolve_and_play(it, pageno)
  resolve_seq = resolve_seq + 1
  local myseq = resolve_seq
  dead, loading, playing = false, true, nil
  resolving = pageno
  static_on()
  -- Sticky: this one stays on screen for the whole wait. It is the only
  -- feedback there is between OK and the first frame.
  show_banner(pageno, "RESOLVING . . . " .. usub(it.title:upper(), 32), true)

  mp.command_native_async(
    { name = "subprocess", playback_only = false,
      capture_stdout = true, capture_stderr = true,
      args = { "python3", RESOLVER, it.url } },
    guard(function(ok, result)
      -- Zapped away, or asked for something else, while we were waiting.
      if myseq ~= resolve_seq then return end
      local url = ok and result and result.status == 0
                  and (result.stdout or ""):match("^%s*(.-)%s*$") or nil
      if url and url ~= "" then
        -- /resolve normally answers with a magnet, and a magnet needs an
        -- engine in front of it before mpv can see a stream. A plain http url
        -- (torrentio occasionally serves one) still goes straight to mpv.
        if url:sub(1, 7) == "magnet:" then
          torrent_play(it, url, pageno)
        else
          play_ondemand(it, url, pageno)
        end
        return
      end
      -- ee3resolve.py puts one human sentence on stderr; that is the whole
      -- point of it, so show that rather than a status code.
      local why = (result and result.stderr or ""):match("([^\n]+)%s*$") or ""
      if why == "" then why = "RESOLVE FAILED" end
      loading, resolving = false, nil
      static_off()
      if TELETEXT[pageno] then
        tt_open(pageno)
        tt_note(pageno, why:upper())
      else
        show_banner(pageno, usub(why:upper(), 40))
      end
    end))

  -- A resolve that never comes back would leave static up forever. The daemon
  -- has its own deadline; this is the backstop for the daemon being gone.
  mp.add_timeout(RESOLVE_SECONDS, guard(function()
    if myseq ~= resolve_seq or ondemand then return end
    resolve_seq = resolve_seq + 1
    loading, resolving = false, nil
    static_off()
    if TELETEXT[pageno] then
      tt_open(pageno)
      tt_note(pageno, "RESOLVE TIMED OUT")
    else
      show_banner(pageno, "RESOLVE TIMED OUT")
    end
  end))
end

local function tt_play_selected()
  local row = tt and tt.lines and tt.lines[tt.cur or -1]
  local it = row and row.item
  if not it then return end
  if it.url == "" then
    -- An entry with no url at all: the catalogue knows the title, nothing
    -- knows where to get it. Say so rather than dropping to silent static.
    tt_note(tt.no, "NO SOURCE - " .. it.title:upper())
    return
  end
  local pageno = tt.no
  tt_close()
  if it.url:sub(1, 4) == "ee3:" then
    resolve_and_play(it, pageno)
  else
    resolve_seq = resolve_seq + 1   -- cancel any resolve still in flight
    play_ondemand(it, it.url, pageno)
  end
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
  -- again, not the library's. That includes one still being resolved - the
  -- reply is dropped rather than pulling the viewer off the channel they
  -- just chose.
  ondemand, resolving = nil, nil
  resolve_seq = resolve_seq + 1
  trans_hide()
  torrent_stop()
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
  -- Fires on first frame and again after every seek, which is exactly when the
  -- transport bar wants redrawing: this is the first moment `duration` is
  -- known, so it is also the first moment the progress bar means anything.
  if ondemand then trans_show() end
end))

mp.register_event("end-file", guard(function(ev)
  if zap_timer then return end
  if ondemand then
    -- ONLY the reasons that mean the film itself is over. `loadfile ... replace`
    -- ends the OUTGOING file first, and that arrives here as reason="stop"
    -- AFTER play_ondemand has already set `ondemand` — so treating every
    -- end-file as "the film ended" tore the film down at the instant it
    -- started, killed the torrent engine, and left the box on static. The
    -- channel branch below has always filtered reasons; this one has to too.
    -- "stop" is also what back_press's mp.commandv("stop") produces, and that
    -- path has already cleared `ondemand` and cleaned up for itself.
    if not (ev.reason == "eof" or ev.reason == "error"
            or ev.reason == "unknown") then
      return
    end
    -- A film is not a channel. Reaching the end is a normal thing to do, and
    -- a failure is not worth retrying every 12s forever — either way, back to
    -- the page it was picked from.
    local it, failed = ondemand, (ev.reason == "error")
    ondemand = nil
    trans_hide()
    torrent_stop()
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
    -- Selectable page: rows under up/down, whole subpages under left/right.
    -- Moving the cursor clears the note: it was about the row you were on.
    tt.note = nil
    if dr ~= 0 then
      tt.cur = tt.cur + dr
      tt_render()
    elseif dc ~= 0 then
      tt_page_jump(dc)
    end
  elseif tt and (dr ~= 0 or dc ~= 0) then
    -- 991 is two subpages side by side, so left/right turns them too: on a
    -- page-per-language layout, "next page" is a sideways thought.
    tt.sub = tt.sub + ((dr ~= 0) and dr or dc)
    tt_render()
  elseif ondemand then
    -- A film is not a channel. Left/right scrub instead of turning subpages,
    -- and up/down bring the transport bar up rather than zapping: nudging the
    -- d-pad should not throw away a film you are 40 minutes into. The shoulder
    -- buttons still zap, and Back still returns to the page it came from.
    if dc ~= 0 then
      mp.commandv("seek", tostring(dc * SEEK_STEP), "relative")
    end
    trans_show()
  elseif dr ~= 0 then
    tune_relative(-dr)     -- dpad up = channel up
  end
end

-- Films only. Pausing a live channel does not pause anything - the broadcast
-- carries on without you and the stream comes back desynced - so this is a
-- no-op on a channel rather than a trap (constraint 3).
local function playpause_press()
  if not ondemand then return end
  mp.commandv("cycle", "pause")
  trans_show()
end

local function select_press()
  if keypad then keypad_select()
  elseif tt and tt.cur then tt_play_selected()
  -- Ⓐ during a film is the "info" button: it brings the title and the progress
  -- bar back without changing anything.
  elseif ondemand then trans_show() end
end

local function back_press()
  if keypad then
    keypad = nil
    keypad_render()
  elseif resolving then
    -- Backing out of a wait. Without this, B during a resolve fell through to
    -- the quit at the bottom and dropped the viewer out of cable mode - and a
    -- resolve is the one thing here that can keep you waiting a minute.
    local pageno = resolving
    resolving = nil
    resolve_seq = resolve_seq + 1     -- the reply, if it comes, is dropped
    torrent_stop()                    -- and the engine, if one had started
    loading = false
    static_off()
    if TELETEXT[pageno] then
      tt_open(pageno)
      show_banner(pageno, chan_name(pageno))
    end
  elseif ondemand then
    -- Stop the film and go back to the page it was picked from, rather than
    -- straight out of cable mode. Backing out of THAT still quits.
    local it = ondemand
    ondemand = nil
    trans_hide()
    torrent_stop()
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
mp.add_key_binding(nil, "playpause", guard(playpause_press))
mp.add_key_binding(nil, "guide",    guard(function() tune(999) end))
for d = 0, 9 do
  mp.add_key_binding(nil, "digit-" .. d, guard(function() digit_press(d) end))
end

-- Leaving cable mode must not leave a torrent engine behind. mpv kills its own
-- subprocesses on exit, but Back at the top level quits through `mp.commandv
-- ("quit")` and a seeding engine outliving the player is exactly the kind of
-- thing nobody notices until the box is slow for a week.
mp.register_event("shutdown", function()
  local ok, err = pcall(torrent_stop)
  if not ok then mp.msg.error("shutdown: " .. tostring(err)) end
end)

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
