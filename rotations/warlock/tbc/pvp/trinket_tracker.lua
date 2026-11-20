-- ============================================================================
-- Warlock PvP Trinket Tracker (TBC)
-- Detects enemy PvP trinket usage via CC duration mismatch.
-- When we apply Fear/Death Coil, we track expected duration.
-- If it breaks early, we assume trinket was used and record a 2-min cooldown.
-- Pattern: modeled after rotations/rogue/tbc/rotation/pvp_trinket_tracker.lua
-- ============================================================================

local trinket_tracker = {}

local dr_helper = require("shared/dr_helper")

-- Per-GUID tracking data
-- { [guid] = { last_trinket_time = 0, cc_pending = nil } }
local tracking_data = {}

-- CC pending entry: { cc_type = "fear"|"death_coil"|"howl", applied_time = 0, expected_duration_ms = 0 }
local TRINKET_COOLDOWN_MS       = 120000  -- 2 minutes
local TRINKET_DETECTION_WINDOW_MS = 1500  -- If CC breaks within 1.5s of application = trinket
local STALE_CLEANUP_MS          = 300000  -- Cleanup entries older than 5 minutes
local last_cleanup_time = 0

-- Base CC durations (ms) before DR scaling
local CC_BASE_DURATIONS = {
    fear       = 15000,  -- Fear max duration (PvP, usually 10-15s depending on rank)
    death_coil = 3000,   -- Death Coil horrify: always 3s
    howl       = 8000,   -- Howl of Terror
    seduce     = 15000,  -- Succubus Seduction
}

-- Optional logging function (injected from pvp/init.lua)
local _log_fn = nil

local function tt_log(message)
    if _log_fn then _log_fn(message) end
end

function trinket_tracker:set_log_fn(fn)
    _log_fn = fn
end

-- ============================================================================
-- INTERNAL
-- ============================================================================

local function cleanup_stale(now)
    if (now - last_cleanup_time) < STALE_CLEANUP_MS then return end
    last_cleanup_time = now
    for guid, data in pairs(tracking_data) do
        local trinket_stale = (now - (data.last_trinket_time or 0)) > TRINKET_COOLDOWN_MS + 10000
        local no_pending = data.cc_pending == nil
        if trinket_stale and no_pending then
            tracking_data[guid] = nil
        end
    end
end

local function get_entry(guid)
    if not tracking_data[guid] then
        tracking_data[guid] = { last_trinket_time = 0, cc_pending = nil }
    end
    return tracking_data[guid]
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Called after successfully applying CC to an enemy.
---@param target game_object
---@param cc_type string  "fear", "death_coil", "howl", "seduce"
---@param now number      core.game_time()
function trinket_tracker:on_cc_applied(target, cc_type, now)
    if not target then return end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return end

    local base_ms = CC_BASE_DURATIONS[cc_type]
    if not base_ms then return end

    -- Scale by DR to get expected duration
    local dr_category = (cc_type == "death_coil") and "horror" or "fear"
    local dr_mult = dr_helper.get_dr(target, dr_category)
    local expected_ms = base_ms * dr_mult

    local entry = get_entry(guid)
    entry.cc_pending = {
        cc_type            = cc_type,
        applied_time       = now,
        expected_duration_ms = expected_ms,
    }
    tt_log(string.format("[Warlock][TRINKET] CC applied: %s (expected %dms, DR %.0f%%)", cc_type, expected_ms, dr_mult * 100))
end

--- Called each frame to detect early CC break (trinket usage).
---@param target game_object
---@param now number
---@return boolean  true if trinket was detected THIS frame
function trinket_tracker:check(target, now)
    if not target then return false end
    cleanup_stale(now)

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end

    local entry = tracking_data[guid]
    if not entry or not entry.cc_pending then return false end

    local pending = entry.cc_pending
    local elapsed = now - pending.applied_time

    -- Too early to check (give 200ms for CC to register on server)
    if elapsed < 200 then return false end

    -- Past detection window -> CC held long enough, no trinket
    if elapsed > TRINKET_DETECTION_WINDOW_MS then
        entry.cc_pending = nil
        return false
    end

    -- Past expected duration -> CC expired naturally
    if elapsed > pending.expected_duration_ms then
        entry.cc_pending = nil
        return false
    end

    -- Check if CC is still active on the target
    local cc_still_active = false
    local cc_flag = (pending.cc_type == "death_coil") and (target.CC and target.CC.HORROR) or (target.CC and target.CC.FEAR)
    if cc_flag then
        local ok, is_cc = pcall(function() return target:is_cc(500, cc_flag) end)
        if ok and is_cc then cc_still_active = true end
    end

    if cc_still_active then return false end

    -- CC broke early -> trinket detected!
    tt_log(string.format("[Warlock][TRINKET] Trinket detected! %s broke after %dms (expected %dms)",
        pending.cc_type, elapsed, pending.expected_duration_ms))
    entry.last_trinket_time = now
    entry.cc_pending = nil
    return true
end

--- Is the target's PvP trinket known to be on cooldown?
---@param target game_object
---@param now number
---@return boolean
function trinket_tracker:is_trinket_on_cooldown(target, now)
    if not target then return false end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end
    local entry = tracking_data[guid]
    if not entry or entry.last_trinket_time == 0 then return false end
    return (now - entry.last_trinket_time) < TRINKET_COOLDOWN_MS
end

--- Remaining trinket cooldown in ms (0 if unknown or ready).
---@param target game_object
---@param now number
---@return number
function trinket_tracker:get_trinket_cd_remaining(target, now)
    if not target then return 0 end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return 0 end
    local entry = tracking_data[guid]
    if not entry or entry.last_trinket_time == 0 then return 0 end
    local elapsed = now - entry.last_trinket_time
    if elapsed >= TRINKET_COOLDOWN_MS then return 0 end
    return TRINKET_COOLDOWN_MS - elapsed
end

--- Reset all tracking (e.g. arena reset).
function trinket_tracker:reset()
    tracking_data = {}
    last_cleanup_time = 0
end

return trinket_tracker
