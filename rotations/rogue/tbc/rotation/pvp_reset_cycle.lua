local __object_safety=require("shared/object_safety")
-- PvP Blind → Bandage → Restealth → Sap Reset Cycle
-- The #1 Arena Rogue mechanic. Provides: energy regen, bandage healing,
-- stun DR reset, fresh opener.
--
-- State machine phases:
--   IDLE → PRE_BLIND → BLIND_CAST → COMBAT_DROP → BANDAGE → RESTEALTH → SAP_SETUP
--
-- Each phase has timeout + abort conditions. The entire cycle claims frames
-- (returns true) so the main rotation does not interfere.

local pvp_reset_cycle = {}

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")

---@type enums
local enums = require("common/enums")

local spell_data = require("rotations/rogue/tbc/spell_data")

-- ============================================================================
-- STATE
-- ============================================================================

local PHASE = {
    IDLE        = "IDLE",
    PRE_BLIND   = "PRE_BLIND",
    BLIND_CAST  = "BLIND_CAST",
    COMBAT_DROP = "COMBAT_DROP",
    BANDAGE     = "BANDAGE",
    RESTEALTH   = "RESTEALTH",
    SAP_SETUP   = "SAP_SETUP",
}

local state = {
    phase = PHASE.IDLE,
    started_at = 0,             -- When the cycle began
    phase_started_at = 0,       -- When the current phase began
    blind_target_guid = nil,    -- GUID of the Blinded target
    cp_dump_done = false,       -- Whether we dumped CPs in PRE_BLIND
    bandage_started = false,    -- Whether bandage channel was initiated
    stealth_attempts = 0,       -- Retry counter for stealth cast
    sap_attempted = false,      -- Whether Sap was attempted
}

-- Phase timeouts (seconds; core.time() is seconds)
local TIMEOUTS = {
    [PHASE.PRE_BLIND]   = 3.0,
    [PHASE.BLIND_CAST]  = 2.0,
    [PHASE.COMBAT_DROP] = 8.0,
    [PHASE.BANDAGE]     = 8.0,
    [PHASE.RESTEALTH]   = 4.0,
    [PHASE.SAP_SETUP]   = 3.0,
}

-- Total cycle timeout (seconds)
local TOTAL_TIMEOUT_MS = 25.0

-- ============================================================================
-- HELPERS
-- ============================================================================

local function reset_state()
    state.phase = PHASE.IDLE
    state.started_at = 0
    state.phase_started_at = 0
    state.blind_target_guid = nil
    state.cp_dump_done = false
    state.bandage_started = false
    state.stealth_attempts = 0
    state.sap_attempted = false
end

-- Logging function reference (injected from pvp.lua)
local _log_fn = nil

local function rc_log(key, interval, message)
    if _log_fn then _log_fn(key, interval, message) end
end

local function set_phase(phase, now)
    local old = state.phase
    state.phase = phase
    state.phase_started_at = now
    rc_log("reset.phase", 0, "[PVP][RESET] Phase: " .. old .. " -> " .. phase)
end

local function phase_elapsed(now)
    return now - state.phase_started_at
end

local function total_elapsed(now)
    return now - state.started_at
end

local function is_phase_timed_out(now)
    local timeout = TIMEOUTS[state.phase]
    if not timeout then return false end
    return phase_elapsed(now) > timeout
end

--- Count enemy players in combat within range
local function count_combat_enemy_players(local_player, range)
    local count = 0
    local ok_pos, pos = pcall(function() return local_player:get_position() end)
    if not ok_pos or not pos then return 99 end

    local enemies = unit_helper:get_enemy_list_around(pos, range or 40.0, true, false, false, false) or {}
    for _, unit in __object_safety.live_ipairs(enemies) do
        if unit and unit:is_valid() and not unit:is_dead() then
            local ok_p, is_p = pcall(function() return pvp_helper:is_player(unit) end)
            if ok_p and is_p then
                local ok_c, in_c = pcall(function() return unit:affecting_combat() end)
                if ok_c and in_c then
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Check if Blind is available (off CD, enough energy)
local function is_blind_available(local_player)
    local blind = spell_data.cc and spell_data.cc.blind
    if not blind or not blind.ids then return false end

    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    if energy < (blind.energy_cost or 30) then return false end

    for i = #blind.ids, 1, -1 do
        local id = blind.ids[i]
        if not spell_helper:is_spell_on_cooldown(id) then
            local ok, castable = pcall(function()
                return spell_helper:is_spell_castable(id, local_player, local_player, true, true, true, true, false)
            end)
            if ok and castable then
                return true
            end
        end
    end
    return false
end

--- Try to cast Blind on target
local function try_cast_blind(local_player, target)
    local blind = spell_data.cc and spell_data.cc.blind
    if not blind or not blind.ids then return false end

    for i = #blind.ids, 1, -1 do
        local id = blind.ids[i]
        local ok, castable = pcall(function()
            return spell_helper:is_spell_castable(id, local_player, target, false, false, false, false, false)
        end)
        if ok and castable then
            spell_queue:queue_spell_target(id, target, 10, "Blind (Reset Cycle)")
            return true
        end
    end
    return false
end

--- Try to use best available bandage
local function try_use_bandage(local_player)
    -- Check Recently Bandaged debuff
    local ok_rb, recently_bandaged = pcall(function()
        return local_player:debuff_up({11196})
    end)
    if ok_rb and recently_bandaged then return false end

    -- Check for DoTs (bandage breaks on damage)
    local all_dots = spell_data.get_all_dot_ids()
    local ok_dot, has_dot = pcall(function()
        return local_player:debuff_up(all_dots)
    end)
    if ok_dot and has_dot then return false end

    -- Not already channeling
    local ok_cast, casting = pcall(function()
        return local_player:is_channeling_or_casting()
    end)
    if ok_cast and casting then return false end

    -- Find highest bandage
    local bandages = spell_data.consumables and spell_data.consumables.bandages
    if not bandages then return false end

    for i = #bandages, 1, -1 do
        local item_id = bandages[i][1]
        if item_id then
            local ok, usable = pcall(function()
                return core.spell_cast_safe(item_id, local_player)
            end)
            if ok and usable then
                return true
            end
        end
    end
    return false
end

--- Try to cast Sap on target (DR-aware)
local function try_cast_sap(local_player, target, helpers)
    if not target or not target:is_valid() or target:is_dead() then return false end

    -- Target must not be in combat for Sap
    local ok_combat, in_combat = pcall(function()
        return target:affecting_combat()
    end)
    if ok_combat and in_combat then return false end

    local sap = spell_data.openers and spell_data.openers.sap
    if not sap or not sap.ids then return false end

    -- DR check
    if pvp_helper and pvp_helper.cc_flags and pvp_helper.get_unit_dr then
        local ok_dr, mult = pcall(function()
            return pvp_helper:get_unit_dr(target, pvp_helper.cc_flags.SAP, core.time())
        end)
        if ok_dr and type(mult) == "number" and mult < 0.5 then
            return false -- DR too heavy
        end
    end

    -- CC immune check
    if pvp_helper and pvp_helper.is_cc_immune then
        local ok_immune, immune = pcall(function()
            return pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.SAP, 1000)
        end)
        if ok_immune and immune then return false end
    end

    for i = #sap.ids, 1, -1 do
        local id = sap.ids[i]
        local ok, castable = pcall(function()
            return spell_helper:is_spell_castable(id, local_player, target, false, false, false, false, false)
        end)
        if ok and castable then
            spell_queue:queue_spell_target(id, target, 9, "Sap (Reset DR)")
            return true
        end
    end
    return false
end

-- ============================================================================
-- TRIGGER CHECK: Should we start a reset cycle?
-- ============================================================================

---@param local_player game_object
---@param target game_object
---@param helpers table
---@param m table menu elements
---@return boolean should_start
local function should_trigger(local_player, target, helpers, m)
    if not m or not m.pvp_reset_cycle or not m.pvp_reset_cycle.get_state then
        return false
    end
    if m.pvp_reset_cycle:get_state() ~= true then
        return false
    end

    -- Burst toggle requirement
    if m.pvp_reset_require_burst and m.pvp_reset_require_burst.get_state and m.pvp_reset_require_burst:get_state() == true then
        if not helpers:is_cooldowns_toggle_active() then
            return false
        end
    end

    -- HP threshold
    local hp = local_player:get_health_percentage()
    local threshold = (m.pvp_reset_hp_threshold and m.pvp_reset_hp_threshold.get and m.pvp_reset_hp_threshold:get()) or 50
    if hp > threshold then
        return false
    end

    -- Energy check (need 30 for Blind minimum)
    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    if energy < 30 then
        return false
    end

    -- Blind must be available
    if not is_blind_available(local_player) then
        return false
    end

    -- No DoTs on self (would break stealth after reset)
    if helpers:has_stealth_breaking_debuffs(local_player) then
        return false
    end

    -- Target must be valid enemy player
    if not target or not target:is_valid() or target:is_dead() then
        return false
    end

    -- Check DR on Blind (Disorient category)
    if pvp_helper and pvp_helper.cc_flags and pvp_helper.is_cc_immune then
        local ok_immune, immune = pcall(function()
            return pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.DISORIENT, 1000)
        end)
        if ok_immune and immune then return false end
    end

    if pvp_helper and pvp_helper.get_unit_dr then
        local ok_dr, mult = pcall(function()
            return pvp_helper:get_unit_dr(target, pvp_helper.cc_flags.DISORIENT, core.time())
        end)
        if ok_dr and type(mult) == "number" and mult < 0.5 then
            return false -- DR too heavy on Blind
        end
    end

    -- Safety: at most 1 enemy in combat (the one we'll Blind)
    local enemy_count = count_combat_enemy_players(local_player, 40)
    if enemy_count > 1 then
        return false
    end

    -- Not already stealthed
    if helpers:is_in_stealth(local_player) then
        return false
    end

    -- Recently Bandaged check (no point resetting if we can't bandage)
    local ok_rb, recently_bandaged = pcall(function()
        return local_player:debuff_up({11196})
    end)
    if ok_rb and recently_bandaged then
        return false
    end

    return true
end

-- ============================================================================
-- MAIN EXECUTE: State machine tick
-- ============================================================================

---@param local_player game_object
---@param target game_object
---@param helpers table
---@param m table menu elements
---@param log_fn function|nil optional logging function(key, interval, message)
---@return boolean active True if cycle is in progress (claim frame)
function pvp_reset_cycle:execute(local_player, target, helpers, m, log_fn)
    _log_fn = log_fn -- Store for helper functions
    if not local_player or not helpers then
        reset_state()
        return false
    end

    local now = core.time()

    -- IDLE: check trigger
    if state.phase == PHASE.IDLE then
        if should_trigger(local_player, target, helpers, m) then
            local hp = local_player:get_health_percentage()
            rc_log("reset.trigger", 0, string.format("[PVP][RESET] Triggered (hp=%.0f%%, blind available)", hp))
            state.started_at = now
            set_phase(PHASE.PRE_BLIND, now)
            -- Fall through to PRE_BLIND handling below
        else
            return false
        end
    end

    -- Global timeout
    if total_elapsed(now) > TOTAL_TIMEOUT_MS then
        rc_log("reset.abort", 0, "[PVP][RESET] ABORT: global timeout (" .. TOTAL_TIMEOUT_MS .. "s)")
        reset_state()
        return false
    end

    -- Phase timeout
    if is_phase_timed_out(now) then
        rc_log("reset.timeout", 0, "[PVP][RESET] Phase timeout in " .. state.phase)
        -- Phase-specific timeout handling
        if state.phase == PHASE.PRE_BLIND then
            -- Skip CP dump, go straight to Blind
            set_phase(PHASE.BLIND_CAST, now)
        elseif state.phase == PHASE.BLIND_CAST then
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: Blind failed")
            reset_state()
            return false -- Blind failed
        elseif state.phase == PHASE.COMBAT_DROP then
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: combat didn't drop")
            reset_state()
            return false -- Combat didn't drop
        elseif state.phase == PHASE.BANDAGE then
            -- Skip bandage, go to restealth
            set_phase(PHASE.RESTEALTH, now)
        elseif state.phase == PHASE.RESTEALTH then
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: restealth failed")
            reset_state()
            return false -- Restealth failed
        elseif state.phase == PHASE.SAP_SETUP then
            rc_log("reset.complete", 0, "[PVP][RESET] Cycle complete (sap phase timeout)")
            reset_state()
            return false -- Sap phase done (opener will handle)
        end
    end

    -- Abort if player dies
    local ok_dead, is_dead = pcall(function() return local_player:is_dead() end)
    if ok_dead and is_dead then
        rc_log("reset.abort", 0, "[PVP][RESET] ABORT: player died")
        reset_state()
        return false
    end

    -- Abort if Blind target died or despawned (prevents cycle hanging)
    if state.blind_target_guid and state.phase ~= PHASE.PRE_BLIND and state.phase ~= PHASE.BLIND_CAST then
        local blind_target_alive = false
        if target and target:is_valid() and not target:is_dead() then
            local ok_guid, guid = pcall(function() return target:get_guid() end)
            if ok_guid and guid == state.blind_target_guid then
                blind_target_alive = true
            end
        end
        if not blind_target_alive then
            -- Target died/despawned - skip to restealth if in bandage+ phases, otherwise abort
            if state.phase == PHASE.BANDAGE or state.phase == PHASE.RESTEALTH or state.phase == PHASE.SAP_SETUP then
                rc_log("reset.target_gone", 0.5, "[PVP][RESET] Blind target gone, continuing " .. state.phase)
                -- Continue bandage/restealth even if target died (we still want the heal + stealth)
            else
                rc_log("reset.abort", 0, "[PVP][RESET] ABORT: blind target died/despawned in " .. state.phase)
                reset_state()
                return false
            end
        end
    end

    -- ================================================================
    -- PHASE: PRE_BLIND - Dump combo points before Blind
    -- ================================================================
    if state.phase == PHASE.PRE_BLIND then
        -- Stop auto-attack
        pcall(function() core.input.stop_attack() end)

        if not state.cp_dump_done then
            local dumped = helpers:dump_combo_points_before_blind(local_player, target)
            if dumped then
                state.cp_dump_done = true
                rc_log("reset.cp_dump", 0, "[PVP][RESET] CP dump before Blind")
                return true -- Wait for GCD
            end
            -- No CPs to dump or not enough energy, proceed to Blind
            state.cp_dump_done = true
        end

        -- GCD check before Blind
        local ok_gcd, gcd = pcall(function()
            return local_player:get_gcd_remains_ms()
        end)
        if ok_gcd and type(gcd) == "number" and gcd > 0 then
            return true -- Wait for GCD
        end

        set_phase(PHASE.BLIND_CAST, now)
        -- Fall through
    end

    -- ================================================================
    -- PHASE: BLIND_CAST - Cast Blind on target
    -- ================================================================
    if state.phase == PHASE.BLIND_CAST then
        pcall(function() core.input.stop_attack() end)

        if try_cast_blind(local_player, target) then
            local ok_guid, guid = pcall(function() return target:get_guid() end)
            state.blind_target_guid = ok_guid and guid or nil
            rc_log("reset.blind", 0, "[PVP][RESET] Blind cast on target")
            set_phase(PHASE.COMBAT_DROP, now)
            return true
        end

        rc_log("reset.blind_wait", 0.5, "[PVP][RESET] Blind not castable yet, retrying")
        -- Blind not castable yet (GCD, range, etc.), keep trying
        return true
    end

    -- ================================================================
    -- PHASE: COMBAT_DROP - Wait for combat to drop
    -- ================================================================
    if state.phase == PHASE.COMBAT_DROP then
        pcall(function() core.input.stop_attack() end)

        -- Abort if new DoTs appeared
        if helpers:has_stealth_breaking_debuffs(local_player) then
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: DoTs appeared during COMBAT_DROP")
            reset_state()
            return false
        end

        -- Abort if new enemy entered combat
        local enemy_count = count_combat_enemy_players(local_player, 40)
        if enemy_count > 1 then
            rc_log("reset.abort", 0, string.format("[PVP][RESET] ABORT: %d enemies in combat", enemy_count))
            reset_state()
            return false
        end

        local ok_combat, in_combat = pcall(function()
            return local_player:affecting_combat()
        end)

        if ok_combat and not in_combat then
            -- Combat dropped! Move to bandage
            rc_log("reset.combat_drop", 0, "[PVP][RESET] Combat dropped!")
            set_phase(PHASE.BANDAGE, now)
            return true
        end

        rc_log("reset.waiting", 1.0, "[PVP][RESET] Waiting for combat drop...")
        return true -- Wait for combat drop
    end

    -- ================================================================
    -- PHASE: BANDAGE - Use bandage for healing
    -- ================================================================
    if state.phase == PHASE.BANDAGE then
        pcall(function() core.input.stop_attack() end)

        -- If already channeling a bandage, wait for it
        local ok_cast, is_casting = pcall(function()
            return local_player:is_channeling_or_casting()
        end)
        if ok_cast and is_casting then
            -- Abort if DoTs break the channel
            if helpers:has_stealth_breaking_debuffs(local_player) then
                rc_log("reset.abort", 0, "[PVP][RESET] ABORT: DoTs during bandage channel")
                reset_state()
                return false
            end
            -- Abort if we re-entered combat (someone hit us, bandage will break)
            local ok_combat_b, in_combat_b = pcall(function()
                return local_player:affecting_combat()
            end)
            if ok_combat_b and in_combat_b then
                rc_log("reset.abort", 0, "[PVP][RESET] ABORT: re-entered combat during bandage")
                reset_state()
                return false
            end
            return true -- Keep channeling
        end

        -- If bandage was started and we're no longer casting, channel finished or broke
        if state.bandage_started then
            rc_log("reset.bandage_done", 0, "[PVP][RESET] Bandage finished/broke, moving to restealth")
            set_phase(PHASE.RESTEALTH, now)
            return true
        end

        -- Try to start bandage
        local hp = local_player:get_health_percentage()
        if hp < 95 then -- Only bandage if we actually need healing
            if try_use_bandage(local_player) then
                rc_log("reset.bandage", 0, string.format("[PVP][RESET] Bandage started (hp=%.0f%%)", hp))
                state.bandage_started = true
                return true
            end
        end

        -- Can't bandage (full HP, recently bandaged, DoTs) - skip to restealth
        rc_log("reset.bandage_skip", 0, string.format("[PVP][RESET] Bandage skipped (hp=%.0f%%), moving to restealth", hp))
        set_phase(PHASE.RESTEALTH, now)
        return true
    end

    -- ================================================================
    -- PHASE: RESTEALTH - Cast Stealth spell
    -- ================================================================
    if state.phase == PHASE.RESTEALTH then
        pcall(function() core.input.stop_attack() end)

        -- Already stealthed?
        if helpers:is_in_stealth(local_player) then
            rc_log("reset.stealth_ok", 0, "[PVP][RESET] Stealth success!")
            set_phase(PHASE.SAP_SETUP, now)
            return true
        end

        -- Abort if combat re-entered
        local ok_combat, in_combat = pcall(function()
            return local_player:affecting_combat()
        end)
        if ok_combat and in_combat then
            -- Try Vanish as last resort
            if not helpers:has_stealth_breaking_debuffs(local_player) and helpers:is_cooldown_ready("vanish") then
                rc_log("reset.vanish_fallback", 0, "[PVP][RESET] Combat re-entered, Vanish fallback")
                helpers:try_cast_cooldown(local_player, "vanish")
                return true
            end
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: combat re-entered, no Vanish")
            reset_state()
            return false
        end

        -- If DoTs appeared, try Cloak of Shadows to remove them before aborting
        if helpers:has_stealth_breaking_debuffs(local_player) then
            if helpers:is_cooldown_ready("cloak_of_shadows") then
                rc_log("reset.clos", 0, "[PVP][RESET] DoTs detected, CloS to cleanse")
                helpers:try_cast_cooldown(local_player, "cloak_of_shadows")
                return true -- CloS queued, retry stealth next frame
            end
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: DoTs on self, CloS not available")
            reset_state()
            return false
        end

        state.stealth_attempts = state.stealth_attempts + 1
        rc_log("reset.stealth_try", 0.5, string.format("[PVP][RESET] Stealth attempt #%d", state.stealth_attempts))

        if helpers:try_cast_stealth(local_player) then
            -- Stealth queued, next frame should be stealthed
            return true
        end

        -- After 3 failed attempts, try Vanish
        if state.stealth_attempts >= 3 then
            if helpers:is_cooldown_ready("vanish") and not helpers:has_stealth_breaking_debuffs(local_player) then
                rc_log("reset.vanish_fallback", 0, "[PVP][RESET] 3 stealth fails, Vanish fallback")
                helpers:try_cast_cooldown(local_player, "vanish")
                return true
            end
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: stealth failed 3x, no Vanish")
            reset_state()
            return false
        end

        return true -- Retry next frame
    end

    -- ================================================================
    -- PHASE: SAP_SETUP - Sap the Blinded target to reset stun DRs
    -- ================================================================
    if state.phase == PHASE.SAP_SETUP then
        -- If not stealthed anymore, abort
        if not helpers:is_in_stealth(local_player) then
            rc_log("reset.abort", 0, "[PVP][RESET] ABORT: lost stealth in SAP_SETUP")
            reset_state()
            return false -- Let normal opener logic take over
        end

        pcall(function() core.input.stop_attack() end)

        -- Wait for Blind to expire before attempting Sap (Sap won't work on CC'd targets)
        if target and target:is_valid() and not target:is_dead() then
            local ok_cc, is_cc = pcall(function()
                return pvp_helper:is_crowd_controlled(target, pvp_helper.cc_flags.DISORIENT, 500)
            end)
            if ok_cc and is_cc then
                rc_log("reset.sap_wait", 0.5, "[PVP][RESET] Waiting for Blind to expire before Sap")
                return true -- Blind still active, wait for it to expire
            end
        end

        if not state.sap_attempted and target and target:is_valid() and not target:is_dead() then
            state.sap_attempted = true
            local sap_ok = try_cast_sap(local_player, target, helpers)
            rc_log("reset.sap", 0, "[PVP][RESET] Sap attempted, result=" .. tostring(sap_ok))
        end

        -- Regardless of Sap success, we've reset. Let normal opener take over.
        rc_log("reset.complete", 0, "[PVP][RESET] Cycle complete!")
        reset_state()
        return false
    end

    -- Shouldn't reach here
    reset_state()
    return false
end

--- Returns true if the reset cycle is currently active.
---@return boolean
function pvp_reset_cycle:is_active()
    return state.phase ~= PHASE.IDLE
end

--- Returns the current phase name.
---@return string
function pvp_reset_cycle:get_phase()
    return state.phase
end

--- Force abort the reset cycle.
function pvp_reset_cycle:abort()
    reset_state()
end

return pvp_reset_cycle
