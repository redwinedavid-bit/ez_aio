-- PvP Trinket Tracker
-- Detects enemy PvP trinket usage via CC duration mismatch.
-- When we apply CC, we track expected duration. If it breaks early (<1s),
-- we assume trinket was used and record a 2-minute cooldown.

local pvp_trinket_tracker = {}

---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")

-- Per-GUID tracking data
-- { [guid] = { last_trinket_time = 0, cc_pending = nil } }
local tracking_data = {}

-- CC pending entry: { cc_type = "kidney_shot", applied_time = 0, expected_duration_ms = 0, cc_flag = flag }
-- Trinket CD is 2 minutes (120,000 ms)
local TRINKET_COOLDOWN_MS = 120000

-- If CC breaks within this window after application, we assume trinket
local TRINKET_DETECTION_WINDOW_MS = 1500

-- Cleanup stale entries older than 5 minutes
local STALE_CLEANUP_MS = 300000
local last_cleanup_time = 0

-- Logging function reference (injected from pvp.lua via set_log_fn)
local _log_fn = nil

local function tt_log(key, interval, message)
    if _log_fn then _log_fn(key, interval, message) end
end

--- Set the logging function (called from pvp.lua)
---@param log_fn function|nil
function pvp_trinket_tracker:set_log_fn(log_fn)
    _log_fn = log_fn
end

-- Expected CC durations (ms) by type and CP (where applicable)
local CC_DURATIONS = {
    kidney_shot = { [1] = 2000, [2] = 3000, [3] = 4000, [4] = 5000, [5] = 6000 },
    blind       = { [0] = 10000 },
    cheap_shot  = { [0] = 4000 },
    gouge       = { [0] = 4000 },  -- 5500 with Improved Gouge
}

--- Clean up stale tracking data periodically
local function cleanup_stale(now)
    if (now - last_cleanup_time) < STALE_CLEANUP_MS then
        return
    end
    last_cleanup_time = now

    for guid, data in pairs(tracking_data) do
        local trinket_stale = (now - (data.last_trinket_time or 0)) > TRINKET_COOLDOWN_MS + 10000
        local no_pending = data.cc_pending == nil
        if trinket_stale and no_pending then
            tracking_data[guid] = nil
        end
    end
end

--- Get or create tracking entry for a GUID
---@param guid string
---@return table
local function get_entry(guid)
    if not tracking_data[guid] then
        tracking_data[guid] = {
            last_trinket_time = 0,
            cc_pending = nil
        }
    end
    return tracking_data[guid]
end

--- Called immediately after applying a CC ability to an enemy.
--- Stores the expected CC duration for trinket detection.
---@param target game_object The CC'd target
---@param cc_type string One of: "kidney_shot", "blind", "cheap_shot", "gouge"
---@param cp number Combo points used (for Kidney Shot duration calc)
---@param now number Current time from core.time()
function pvp_trinket_tracker:on_cc_applied(target, cc_type, cp, now)
    if not target then return end

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return end

    local durations = CC_DURATIONS[cc_type]
    if not durations then return end

    local expected_ms = durations[cp or 0] or durations[0]
    if not expected_ms then return end

    -- Determine the CC flag for pvp_helper checks
    local cc_flag = nil
    if cc_type == "kidney_shot" or cc_type == "cheap_shot" then
        cc_flag = pvp_helper.cc_flags and pvp_helper.cc_flags.STUN
    elseif cc_type == "blind" then
        cc_flag = pvp_helper.cc_flags and pvp_helper.cc_flags.DISORIENT
    elseif cc_type == "gouge" then
        cc_flag = pvp_helper.cc_flags and pvp_helper.cc_flags.INCAPACITATE
    end

    local entry = get_entry(guid)
    entry.cc_pending = {
        cc_type = cc_type,
        applied_time = now,
        expected_duration_ms = expected_ms,
        cc_flag = cc_flag
    }
    tt_log("trinket.cc_applied", 0, string.format("[PVP][TRINKET] CC applied: %s (cp=%d, expected %dms)", cc_type, cp or 0, expected_ms))
end

--- Called each frame to check if the pending CC broke early (trinket detection).
--- Should be called BEFORE normal rotation logic.
---@param target game_object The target to check
---@param now number Current time from core.time()
---@return boolean trinket_just_used True if trinket was detected THIS frame
function pvp_trinket_tracker:check(target, now)
    if not target then return false end

    cleanup_stale(now)

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end

    local entry = tracking_data[guid]
    if not entry or not entry.cc_pending then return false end

    local pending = entry.cc_pending
    local elapsed = now - pending.applied_time

    -- Too early to check (give 200ms for CC to register)
    if elapsed < 200 then
        return false
    end

    -- Past the detection window - CC lasted long enough, no trinket
    if elapsed > TRINKET_DETECTION_WINDOW_MS then
        tt_log("trinket.cc_held", 0, string.format("[PVP][TRINKET] CC held past detection window (%s, %dms)", pending.cc_type, elapsed))
        entry.cc_pending = nil
        return false
    end

    -- Past expected duration - CC expired naturally
    if elapsed > pending.expected_duration_ms then
        tt_log("trinket.cc_expired", 0, string.format("[PVP][TRINKET] CC expired naturally (%s, %dms)", pending.cc_type, elapsed))
        entry.cc_pending = nil
        return false
    end

    -- Check if CC is still active on the target
    local cc_still_active = false
    if pending.cc_flag and pvp_helper and pvp_helper.is_crowd_controlled then
        local ok, is_cc = pcall(function()
            return pvp_helper:is_crowd_controlled(target, pending.cc_flag, 500)
        end)
        if ok and is_cc then
            cc_still_active = true
        end
    end

    -- Fallback: check if target is stunned (for stun types)
    if not cc_still_active and (pending.cc_type == "kidney_shot" or pending.cc_type == "cheap_shot") then
        local ok, stunned = pcall(function()
            return target:is_stunned(500)
        end)
        if ok and stunned then
            cc_still_active = true
        end
    end

    if cc_still_active then
        -- CC still up, no trinket yet
        return false
    end

    -- CC broke early! Trinket detected.
    tt_log("trinket.detected", 0, string.format("[PVP][TRINKET] CC broke early! Trinket detected (%s, elapsed=%dms, expected=%dms)", pending.cc_type, elapsed, pending.expected_duration_ms))
    entry.last_trinket_time = now
    entry.cc_pending = nil

    return true
end

--- Returns true if the target's PvP trinket is known to be on cooldown.
---@param target game_object
---@param now number Current time from core.time()
---@return boolean
function pvp_trinket_tracker:is_trinket_on_cooldown(target, now)
    if not target then return false end

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end

    local entry = tracking_data[guid]
    if not entry or entry.last_trinket_time == 0 then return false end

    return (now - entry.last_trinket_time) < TRINKET_COOLDOWN_MS
end

--- Returns the remaining trinket cooldown in ms (0 if unknown or ready).
---@param target game_object
---@param now number Current time from core.time()
---@return number
function pvp_trinket_tracker:get_trinket_cd_remaining(target, now)
    if not target then return 0 end

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return 0 end

    local entry = tracking_data[guid]
    if not entry or entry.last_trinket_time == 0 then return 0 end

    local elapsed = now - entry.last_trinket_time
    if elapsed >= TRINKET_COOLDOWN_MS then return 0 end

    return TRINKET_COOLDOWN_MS - elapsed
end

--- Resets all tracking data (e.g., on arena reset).
function pvp_trinket_tracker:reset()
    tracking_data = {}
    last_cleanup_time = 0
end

return pvp_trinket_tracker
