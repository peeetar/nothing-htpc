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
local FONT            = "Press Start 2P"
local BANNER_SECONDS  = 5
local STATIC_FPS      = 12
local STATIC_NFRAMES  = 6
local RETRY_SECONDS   = 12          -- dead channel retry interval
local DIGIT_TIMEOUT   = 2.0         -- seconds after last digit before tuning
local RSS_CACHE_SECS  = 300
local LINES_PER_PAGE  = 11          -- teletext headlines per subpage

local TELETEXT = {
  [991] = { type = "guide", title = "TV GUIDE" },
  [992] = { type = "rss", title = "ВЕСТИ",
            url = "https://time.mk/rss/all",
            clean = function(t) return (t:gsub("%s*|[^|]*$", "")) end },
  [993] = { type = "rss", title = "ΕΙΔΗΣΕΙΣ",
            url = "https://www.pressdisplay.com/pressdisplay/services/rss.ashx?cid=1142&type=full",
            clean = function(t)
              t = t:gsub("^%d+/%d+/%d+:%s*", "")
              t = t:gsub("^[A-Z][A-Z%s]-:%s*", "")
              return t
            end },
}

-- state -----------------------------------------------------------------------
local channels = {}        -- chno -> {name=, url=}
local chnos = {}           -- sorted list of all numbers incl. teletext
local current = nil        -- current channel number
local loading = false      -- waiting for stream to start
local dead = false         -- channel failed, static + retry
local retry_timer = nil
local digit_buf = ""
local digit_timer = nil
local keypad = nil         -- {r=,c=} when open
local tt = nil             -- {no=, sub=, lines=} when teletext active
local rss_cache = {}       -- url -> {t=, lines=}

-- ass colors (BGR!) -------------------------------------------------------------
local C_GREEN  = "&H33FF33&"
local C_WHITE  = "&HFFFFFF&"
local C_YELLOW = "&H00FFFF&"
local C_CYAN   = "&HFFFF00&"
local C_GRAY   = "&H888888&"
local C_BLACK  = "&H000000&"

-- overlays ---------------------------------------------------------------------
local ov_banner  = mp.create_osd_overlay("ass-events")
local ov_keypad  = mp.create_osd_overlay("ass-events")
local ov_tt      = mp.create_osd_overlay("ass-events")
for _, ov in pairs({ov_banner, ov_keypad, ov_tt}) do
  ov.res_x, ov.res_y = 1280, 720
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
local static = { on = false, timer = nil, frame = 0, dir = nil, w = 0, h = 0 }

local function static_frames_ready()
  local w = mp.get_property_number("osd-width", 0)
  local h = mp.get_property_number("osd-height", 0)
  if w == 0 or h == 0 then w, h = 1280, 720 end
  local dir = (os.getenv("HOME") or "/tmp") .. ("/.cache/cabletv/%dx%d"):format(w, h)
  local probe = io.open(dir .. "/f0.raw", "rb")
  if probe then probe:close()
  else
    mp.command_native({ name = "subprocess", playback_only = false,
      args = { "python3", DIR .. "/gen_static.py",
               tostring(w), tostring(h), tostring(STATIC_NFRAMES), dir } })
  end
  static.dir, static.w, static.h = dir, w, h
  return true
end

local function static_tick()
  if not static.on then return end
  static.frame = (static.frame + 1) % STATIC_NFRAMES
  mp.commandv("overlay-add", "60", "0", "0",
              static.dir .. "/f" .. static.frame .. ".raw",
              "0", "bgra", tostring(static.w), tostring(static.h),
              tostring(static.w * 4))
end

local function static_on()
  if static.on then return end
  static_frames_ready()
  static.on = true
  if not static.timer then
    static.timer = mp.add_periodic_timer(1 / STATIC_FPS, static_tick)
  else
    static.timer:resume()
  end
  static_tick()
end

local function static_off()
  if not static.on then return end
  static.on = false
  if static.timer then static.timer:stop() end
  mp.commandv("overlay-remove", "60")
end

------------------------------------------------------------------- banner -----
local banner_timer = nil

local function show_banner(no, name)
  local num = tostring(no)
  if #num < 2 then num = "0" .. num end
  ov_banner.data = table.concat({
    ("{\\an7\\pos(52,42)\\fn%s\\fs52\\bord4\\3c%s\\1c%s\\shad0}%s"):format(FONT, C_BLACK, C_GREEN, num),
    ("{\\an7\\pos(52,112)\\fn%s\\fs26\\bord3\\3c%s\\1c%s\\shad0}%s"):format(FONT, C_BLACK, C_GREEN, name),
  }, "\n")
  ov_banner:update()
  if banner_timer then banner_timer:kill() end
  banner_timer = mp.add_timeout(BANNER_SECONDS, function()
    ov_banner.data = ""
    ov_banner:update()
  end)
end

------------------------------------------------------------------- teletext ---
local function ulen(s)
  -- UTF-8 codepoint count (Lua 5.1 compatible)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

local function tt_wrap(text, width)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    if cur == "" then cur = word
    elseif ulen(cur) + ulen(word) + 1 <= width then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

local function tt_decode(t)
  t = t:gsub("^%s*<!%[CDATA%[(.-)%]%]>?%s*$", "%1")
  t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  t = t:gsub("&quot;", '"'):gsub("&#0?39;", "'"):gsub("&nbsp;", " ")
  t = t:gsub("&#8217;", "'"):gsub("&#8216;", "'")
  return t
end

local function tt_render()
  if not tt then ov_tt.data = ""; ov_tt:update(); return end
  local page = TELETEXT[tt.no]
  local ev = {}
  -- opaque black screen
  ev[#ev + 1] = ("{\\an7\\pos(0,0)\\p1\\1c%s\\bord0\\shad0}m 0 0 l 1280 0 l 1280 720 l 0 720{\\p0}")
                :format(C_BLACK)
  -- header row: page number + clock
  ev[#ev + 1] = ("{\\an7\\pos(52,30)\\fn%s\\fs22\\1c%s\\bord0\\shad0}P%d"):format(FONT, C_WHITE, tt.no)
  ev[#ev + 1] = ("{\\an9\\pos(1228,30)\\fn%s\\fs22\\1c%s\\bord0\\shad0}%s")
                :format(FONT, C_WHITE, os.date("%H:%M"))
  -- big yellow title
  ev[#ev + 1] = ("{\\an7\\pos(52,80)\\fn%s\\fs44\\1c%s\\bord0\\shad0}%s"):format(FONT, C_YELLOW, page.title)
  -- body
  local lines = tt.lines or {}
  local nsub = math.max(1, math.ceil(#lines / LINES_PER_PAGE))
  tt.sub = math.max(1, math.min(tt.sub, nsub))
  local y = 170
  local first = (tt.sub - 1) * LINES_PER_PAGE + 1
  for i = first, math.min(first + LINES_PER_PAGE - 1, #lines) do
    local l = lines[i]
    ev[#ev + 1] = ("{\\an7\\pos(52,%d)\\fn%s\\fs%d\\1c%s\\bord0\\shad0}%s")
                  :format(y, FONT, l.big and 24 or 18, l.color, l.text)
    y = y + (l.big and 44 or 40)
  end
  -- footer: fastext-style colored row + subpage indicator
  ev[#ev + 1] = ("{\\an7\\pos(52,684)\\fn%s\\fs18\\bord0\\shad0}" ..
                 "{\\1c&H3333FF&}991 GUIDE  {\\1c&H33FF33&}992 ВЕСТИ  {\\1c&H00FFFF&}993 NEWS")
                :format(FONT)
  ev[#ev + 1] = ("{\\an9\\pos(1228,684)\\fn%s\\fs18\\1c%s\\bord0\\shad0}%d/%d")
                :format(FONT, C_GRAY, tt.sub, nsub)
  ov_tt.data = table.concat(ev, "\n")
  ov_tt:update()
end

local function tt_set_lines(lines)
  if tt then tt.lines = lines; tt_render() end
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

local function tt_rss_fetch(pageno)
  local page = TELETEXT[pageno]
  local cached = rss_cache[page.url]
  if cached and (os.time() - cached.t) < RSS_CACHE_SECS then
    tt_set_lines(cached.lines)
    return
  end
  tt_set_lines({ { text = "LOADING . . .", color = C_GRAY } })
  mp.command_native_async(
    { name = "subprocess", playback_only = false, capture_stdout = true,
      args = { "curl", "-sL", "--max-time", "10", page.url } },
    function(ok, result)
      if not (tt and tt.no == pageno) then return end
      local body = ok and result.status == 0 and result.stdout or ""
      local lines = {}
      for item in body:gmatch("<item>(.-)</item>") do
        local title = item:match("<title>%s*(.-)%s*</title>")
        if title then
          title = tt_decode(title)
          if page.clean then title = page.clean(title) end
          local wrapped = tt_wrap(title, 52)
          for wi, wl in ipairs(wrapped) do
            lines[#lines + 1] = { text = wl,
                                  color = (wi == 1) and C_CYAN or C_WHITE }
          end
        end
        if #lines > 120 then break end
      end
      if #lines == 0 then
        lines = { { text = "PAGE NOT AVAILABLE", color = C_GRAY },
                  { text = "CHECK NETWORK - RETRYING SOON", color = C_GRAY } }
      else
        rss_cache[page.url] = { t = os.time(), lines = lines }
      end
      tt_set_lines(lines)
    end)
end

local function tt_open(no)
  tt = { no = no, sub = 1, lines = nil }
  local page = TELETEXT[no]
  if page.type == "guide" then
    tt_set_lines(tt_guide_lines())
  else
    tt_render()          -- draw frame instantly
    tt_rss_fetch(no)
  end
end

local function tt_close()
  tt = nil
  ov_tt.data = ""
  ov_tt:update()
end

------------------------------------------------------------------- tuning -----
local function stop_retry()
  if retry_timer then retry_timer:kill(); retry_timer = nil end
end

local function tune(no)
  stop_retry()
  digit_buf = ""
  current = no
  show_banner(no, chan_name(no))

  if TELETEXT[no] then
    -- teletext replaces the picture; last channel's audio keeps running
    static_off()
    tt_open(no)
    return
  end
  tt_close()

  local ch = channels[no]
  if not ch then
    -- empty channel number: pure static, like it should be
    dead, loading = true, false
    static_on()
    mp.commandv("stop")
    return
  end
  dead, loading = false, true
  static_on()
  mp.commandv("loadfile", ch.url, "replace")
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
  retry_timer = mp.add_timeout(RETRY_SECONDS, function()
    if dead and current and channels[current] then tune(current) end
  end)
end

-- stream events
mp.register_event("playback-restart", function()
  if loading or dead then
    loading, dead = false, false
    stop_retry()
    static_off()
  end
end)

mp.register_event("end-file", function(ev)
  if TELETEXT[current or -1] then return end
  if ev.reason == "error" or ev.reason == "eof" or ev.reason == "unknown" then
    mark_dead()
  end
end)

mp.observe_property("paused-for-cache", "bool", function(_, v)
  if loading or dead or not current or TELETEXT[current] then return end
  if v then
    mp.add_timeout(1.0, function()
      if mp.get_property_bool("paused-for-cache") then static_on() end
    end)
  else
    static_off()
  end
end)

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
    digit_timer = mp.add_timeout(DIGIT_TIMEOUT, digit_commit)
  end
end

------------------------------------------------------------------- keypad -----
local PAD = {
  { "1", "2", "3" },
  { "4", "5", "6" },
  { "7", "8", "9" },
  { "C", "0", "OK" },
}

local function keypad_render()
  if not keypad then ov_keypad.data = ""; ov_keypad:update(); return end
  local ev = {}
  local x0, y0, cw, chh = 980, 210, 84, 74
  -- backdrop
  ev[#ev + 1] = ("{\\an7\\pos(%d,%d)\\p1\\1c%s\\1a&H30&\\bord0\\shad0}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}")
                :format(x0 - 34, y0 - 74, 3 * cw + 66, 3 * cw + 66, 4 * chh + 118, 4 * chh + 118)
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
  elseif tt and dr ~= 0 then
    tt.sub = tt.sub + dr
    tt_render()
  elseif dr ~= 0 then
    tune_relative(-dr)     -- dpad up = channel up
  end
end

local function select_press()
  if keypad then keypad_select() end
end

local function back_press()
  if keypad then
    keypad = nil
    keypad_render()
  elseif tt then
    -- leave teletext back to the last real channel's picture
    tt_close()
    if current and TELETEXT[current] then
      show_banner(current, chan_name(current))
    end
  end
end

mp.add_key_binding(nil, "ch-up",    function() tune_relative(1)  end)
mp.add_key_binding(nil, "ch-down",  function() tune_relative(-1) end)
mp.add_key_binding(nil, "keypad",   keypad_toggle)
mp.add_key_binding(nil, "nav-up",    function() nav(-1, 0) end, { repeatable = true })
mp.add_key_binding(nil, "nav-down",  function() nav(1, 0)  end, { repeatable = true })
mp.add_key_binding(nil, "nav-left",  function() nav(0, -1) end, { repeatable = true })
mp.add_key_binding(nil, "nav-right", function() nav(0, 1)  end, { repeatable = true })
mp.add_key_binding(nil, "select",   select_press)
mp.add_key_binding(nil, "back",     back_press)
mp.add_key_binding(nil, "guide",    function() tune(991) end)
for d = 0, 9 do
  mp.add_key_binding(nil, "digit-" .. d, function() digit_press(d) end)
end

------------------------------------------------------------------- boot -------
load_channels()
mp.register_event("file-loaded", function() end)
mp.add_timeout(0.4, function()
  local first = nil
  for _, no in ipairs(chnos) do
    if channels[no] then first = no; break end
  end
  if first then tune(first) else tune(991) end
end)
