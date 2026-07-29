-- shim.lua — what is left of cabletv.lua.
--
-- The old script was 2,105 lines and drew the entire cable-TV interface in
-- ASS subtitles: banner, teletext, weather icons, poster panels, animated
-- static. All of that is HTML now. This file draws NOTHING. If you find
-- yourself writing an ass_ function in here, the change belongs in the
-- launcher instead.
--
-- What survives is the handful of jobs that are genuinely awkward to do from
-- the other side of an IPC socket, because they are about events mpv knows
-- first:
--
--   * a stream that fails to open, or dies mid-play
--   * retrying a dead live channel on a timer
--   * telling the UI which of those just happened
--
-- The UI could poll for all of this, but polling a socket to discover that a
-- channel died four seconds ago is worse than being told, and each poll on a
-- 1GB Pi is real work.
--
-- Communication is one-way and cheap: properties on mpv that server.py reads
-- through /player/state. No script-message handshake, because a shim that can
-- be waited on is a shim that can hang the UI.

local mp = require "mp"
local msg = require "mp.msg"

-- How long a live channel stays dead before we try it again. The old script
-- used 12s and that was right: long enough not to hammer a stream that is
-- genuinely off air, short enough that a channel coming back is noticed
-- before the viewer gives up on it.
local RETRY_S = tonumber(os.getenv("HTPC_RETRY_SECONDS") or "12")

local state = {
  url = nil,        -- what we were last asked to play
  failed = false,   -- did it fail
  retry = nil,      -- pending retry timer
  attempts = 0,
}

-- Everything the UI needs to know, as one user-data property. server.py reads
-- it in the same round trip as position and cache state, so the channel bar
-- costs no extra IPC.
local function publish()
  mp.set_property_native("user-data/htpc", {
    failed = state.failed,
    attempts = state.attempts,
    url = state.url,
  })
end

local function cancel_retry()
  if state.retry then
    state.retry:kill()
    state.retry = nil
  end
end

-- A guard around every handler. The old script froze the whole box once
-- because a :format() argument-count mismatch raised inside a key handler and
-- took the script with it. There are no format strings left in here, but the
-- rule that earned that scar is cheap to keep: a handler that raises must not
-- be able to stop the player.
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      msg.error("handler error: " .. tostring(err))
    end
  end
end

local function try_again()
  state.retry = nil
  if not state.url or not state.failed then return end
  state.attempts = state.attempts + 1
  msg.info(("retrying (attempt %d): %s"):format(state.attempts, state.url))
  mp.commandv("loadfile", state.url, "replace")
end

-- mpv could not open it, or it died on its own.
mp.register_event("end-file", guard(function(ev)
  if ev.reason ~= "error" then return end
  state.failed = true
  publish()
  msg.warn("stream failed: " .. tostring(state.url))
  cancel_retry()
  -- Live streams come back; a film that failed to open will not fix itself,
  -- but retrying one costs a request every 12s and nothing else, and the UI
  -- is what decides to give up by loading something different.
  state.retry = mp.add_timeout(RETRY_S, guard(try_again))
end))

-- A successful open clears the failure and stops the retry loop.
mp.register_event("file-loaded", guard(function()
  state.url = mp.get_property("path") or state.url
  if state.failed or state.attempts > 0 then
    msg.info("recovered: " .. tostring(state.url))
  end
  state.failed = false
  state.attempts = 0
  cancel_retry()
  publish()
end))

-- A new loadfile from the UI resets everything: whatever was failing is no
-- longer what we are watching.
mp.observe_property("path", "string", guard(function(_, value)
  if value and value ~= state.url then
    state.url = value
    state.failed = false
    state.attempts = 0
    cancel_retry()
    publish()
  end
end))

publish()
msg.info("htpc shim loaded — this script draws no UI")
