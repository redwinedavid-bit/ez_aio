local __object_safety=require("shared/object_safety")
-- PvP Gouge → Restealth Module
-- After landing Gouge on the only enemy in combat, waits for combat drop
-- and attempts to restealth for a fresh opener.
-- Fallback: uses Vanish if combat doesn't drop within the Gouge window.

local pvp_gouge_restealth = {}

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")

-- State tracking
local state = {
    active = false,
    gouge_cast_time = 0,
    gouge_target_guid = nil,
    gouge_verified = false,
    stealth_attempted = false,
    vanish_attempted = false,
}

-- Gouge lasts 4s base (5.5s improved). We allow a window for combat drop.
-- NOTE: core.time() is seconds.
local GOUGE_MAX_WINDOW_MS = 5.5
-- Minimum time after Gouge to start checking for combat drop (GCD)
local GOUGE_MIN_DELAY_MS = 0.5

-- Logging function reference (injected from pvp.lua)
local _log_fn = nil

local function gr_log(key, interval, message)
    if _log_fn then _log_fn(key, interval, message) end
end

--- Reset state to idle
local function reset_state()
    state.active = false
    state.gouge_cast_time = 0
    state.gouge_target_guid = nil
    state.gouge_verified = false
    state.stealth_attempted = false
    state.vanish_attempted = false
end

--- Count enemy players currently in combat with us within range
---@param local_player game_object
---@return number
local function count_combat_enemies(local_player)
    local count = 0
    local ok_pos, player_pos = pcall(function()
        return local_player:get_position()
    end)
    if not ok_pos or not player_pos then
        return 99 -- Assume many enemies if we can't check
    end

    local enemies = unit_helper:get_enemy_list_around(player_pos, 40.0, true, false, false, false) or {}
    for _, unit in __object_safety.live_ipairs(enemies) do
        if unit and unit:is_valid() and not unit:is_dead() then
            local ok_player, is_player = pcall(function()
                return pvp_helper:is_player(unit)
            end)
            if ok_player and is_player then
                local ok_combat, in_combat = pcall(function()
                    return unit:affecting_combat()
                end)
                if ok_combat and in_combat then
                    count = count + 1
                end
            end
        end
    end

    return count
end

--- Called when Gouge is successfully cast on a target.
---@param local_player game_object
---@param target game_object
---@param now number core.time()
function pvp_gouge_restealth:on_gouge_cast(local_player, target, now)
    if not local_player or not target then return end

    -- Only attempt restealth if there's <= 1 enemy in combat (the gouged one)
    local enemy_count = count_combat_enemies(local_player)
    if enemy_count > 1 then
        gr_log("gouge_rs.skip", 0, string.format("[PVP][GOUGE_RS] Skipped (%d enemies in combat)", enemy_count))
        return -- Can't restealth with multiple enemies
    end

    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return end

    state.active = true
    state.gouge_cast_time = now
    state.gouge_target_guid = guid
    state.gouge_verified = false
    state.stealth_attempted = false
    state.vanish_attempted = false
    gr_log("gouge_rs.start", 0, string.format("[PVP][GOUGE_RS] Started (%d enemy in combat)", enemy_count))
end

--- Called each frame. Returns true if the module is actively handling restealth
--- (caller should yield the frame).
---@param local_player game_object
---@param target game_object|nil
---@param helpers table
---@param log_fn function|nil optional logging function(key, interval, message)
---@return boolean active True if restealth sequence is in progress
function pvp_gouge_restealth:execute(local_player, target, helpers, log_fn)
    _log_fn = log_fn -- Store for helper functions
    if not state.active then
        return false
    end

    if not local_player or not helpers then
        reset_state()
        return false
    end

    local now = core.time()
    local elapsed = now - state.gouge_cast_time

    -- Timeout: Gouge window expired
    if elapsed > GOUGE_MAX_WINDOW_MS then
        gr_log("gouge_rs.timeout", 0, string.format("[PVP][GOUGE_RS] ABORT: timeout (%.1fs elapsed)", elapsed))
        reset_state()
        return false
    end

    -- Too early, wait for GCD
    if elapsed < GOUGE_MIN_DELAY_MS then
        -- Stop auto-attack during this window
        pcall(function() core.input.stop_attack() end)
        return true
    end

    -- Verify Gouge actually landed (not missed/dodged/parried/immune)
    if not state.gouge_verified then
        if target and target:is_valid() then
            local ok_cc, is_cc = pcall(function()
                return pvp_helper:is_crowd_controlled(target, pvp_helper.cc_flags.INCAPACITATE, 500)
            end)
            if ok_cc and is_cc then
                state.gouge_verified = true
                gr_log("gouge_rs.verified", 0, "[PVP][GOUGE_RS] Gouge verified (incapacitate confirmed)")
            elseif elapsed > 1.0 then
                -- Gouge didn't land after 1s, abort
                gr_log("gouge_rs.miss", 0, "[PVP][GOUGE_RS] ABORT: Gouge didn't land (1s elapsed)")
                reset_state()
                return false
            else
                pcall(function() core.input.stop_attack() end)
                return true -- Wait a bit longer for server confirmation
            end
        elseif elapsed > 1.0 then
            gr_log("gouge_rs.no_target", 0, "[PVP][GOUGE_RS] ABORT: no valid target after 1s")
            reset_state()
            return false
        end
    end

    -- If already stealthed, we're done
    if helpers:is_in_stealth(local_player) then
        gr_log("gouge_rs.stealth_ok", 0, "[PVP][GOUGE_RS] Stealth success!")
        reset_state()
        return false -- Let normal opener logic handle it
    end

    -- Abort if more enemies entered combat
    local enemy_count = count_combat_enemies(local_player)
    if enemy_count > 1 then
        gr_log("gouge_rs.abort_enemies", 0, string.format("[PVP][GOUGE_RS] ABORT: %d enemies in combat", enemy_count))
        reset_state()
        return false
    end

    -- Stop auto-attack (critical: don't break our own Gouge)
    pcall(function() core.input.stop_attack() end)

    -- Check if we've dropped combat
    local ok_combat, in_combat = pcall(function()
        return local_player:affecting_combat()
    end)

    if ok_combat and not in_combat then
        gr_log("gouge_rs.ooc", 0.5, "[PVP][GOUGE_RS] Combat dropped, stealth attempt")
        -- Out of combat! Try to stealth
        if not state.stealth_attempted then
            state.stealth_attempted = true
            if helpers:try_cast_stealth(local_player) then
                -- Stealth queued, next frame should enter stealth opener
                return true
            end
        end

        -- Stealth failed (maybe still on CD), retry next frame
        if helpers:try_cast_stealth(local_player) then
            return true
        end

        -- If stealth keeps failing and we have Vanish, use it
        if not state.vanish_attempted and elapsed > 3.0 then
            state.vanish_attempted = true
            if helpers:is_cooldown_ready("vanish") then
                if helpers:try_cast_cooldown(local_player, "vanish") then
                    gr_log("gouge_rs.vanish", 0, "[PVP][GOUGE_RS] Vanish fallback (stealth failed, 3s elapsed)")
                    reset_state()
                    return true
                end
            end
        end

        return true -- Keep claiming frame, waiting for stealth
    end

    -- Still in combat during Gouge window
    gr_log("gouge_rs.waiting", 1.0, string.format("[PVP][GOUGE_RS] In combat, waiting (%.1fs elapsed)", elapsed))
    -- If we're past 3.5s and still in combat, try Vanish as fallback
    if elapsed > 3.5 and not state.vanish_attempted then
        state.vanish_attempted = true
        if helpers:is_cooldown_ready("vanish") then
            -- Only Vanish if no DoTs on self
            if not helpers:has_stealth_breaking_debuffs(local_player) then
                if helpers:try_cast_cooldown(local_player, "vanish") then
                    gr_log("gouge_rs.vanish", 0, "[PVP][GOUGE_RS] Vanish fallback (3.5s elapsed, still in combat)")
                    reset_state()
                    return true
                end
            else
                gr_log("gouge_rs.vanish_block", 0, "[PVP][GOUGE_RS] Vanish blocked (DoTs on self)")
            end
        end
    end

    return true -- Claim frame, pool energy while waiting
end

--- Returns true if the module is currently active.
---@return boolean
function pvp_gouge_restealth:is_active()
    return state.active
end

--- Force abort the restealth attempt.
function pvp_gouge_restealth:abort()
    reset_state()
end

return pvp_gouge_restealth
