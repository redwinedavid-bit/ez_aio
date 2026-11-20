-- Rotation logic for WoW TBC Classic Rogue (Level 1-70)
-- Spec-agnostic rotation with level-based priority lists (uses learned spells)

local rotation_logic = {}

local cc = require("rotations/rogue/tbc/rotation/cc")
local levels = require("rotations/rogue/tbc/rotation/levels")
local pvp = require("rotations/rogue/tbc/rotation/pvp")

-- Public function to check if target has breakable CC active
-- Used by main.lua to stop auto-attacks before they break CC
-- Returns true if target is under Gouge/Blind/Sap (damage breaks CC)
-- Returns false if target is stunned (Cheap Shot, Kidney Shot - damage allowed)
---@param target game_object
---@param has_cheap_shot boolean
---@return boolean true if target has breakable CC (Gouge/Blind/Sap)
function rotation_logic:is_breakable_cc_active(target, has_cheap_shot)
    return cc.is_breakable_cc_active(target, has_cheap_shot)
end

-- ============================================================================
-- MAIN EXECUTION DISPATCHER
-- ============================================================================

---@param local_player game_object
---@param target game_object
---@param helpers table
---@return boolean
function rotation_logic:execute(local_player, target, helpers, has_cheap_shot, targets_list)
    if not local_player or not target then
        return false
    end

    -- PvP overlay (Arena/BG focused): runs before PvE lists.
    if pvp and pvp.execute and pvp:execute(local_player, helpers, targets_list) then
        return true
    end

    -- VANISH SAFETY: Do not cast/attack during the post-Vanish lockout window.
    if helpers and helpers.is_vanish_attack_suppressed and helpers:is_vanish_attack_suppressed(local_player) then
        return false
    end

    -- STEALTH SAFETY: Do not execute rotation while stealthed.
    if helpers and helpers.is_in_stealth and helpers:is_in_stealth(local_player) then
        return false
    end

    local level = local_player:level()
    local energy = local_player:energy_current()

    -- FIX: Use get_power(4) instead of combo_points_current()
    -- Power Type 4 = Combo Points
    local cp = 0
    if helpers and helpers.get_combo_points then
        cp = helpers:get_combo_points(local_player)
    end

    -- Nil-safe health calculation with division by zero protection
    local target_hp_percent = target:get_health_percentage()

    -- OPTIMIZATION: Pass has_cheap_shot to sub-rotations to avoid duplicate checks
    has_cheap_shot = has_cheap_shot or false

    if helpers and helpers.log_checkpoint then
        helpers:log_checkpoint("rot.exec", 1.0, string.format("[ROT] EXEC l=%d e=%d cp=%d", level or 0, energy or 0, cp or 0))
    end

    -- Level Range Logic Dispatch
    local did_action = false
    if level >= 1 and level <= 9 then
        did_action = levels.rotation_level_1_9(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 10 and level <= 19 then
        did_action = levels.rotation_level_10_19(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 20 and level <= 29 then
        did_action = levels.rotation_level_20_29(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 30 and level <= 39 then
        did_action = levels.rotation_level_30_39(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 40 and level <= 49 then
        did_action = levels.rotation_level_40_49(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 50 and level <= 60 then
        did_action = levels.rotation_level_50_60(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    elseif level >= 61 then
        -- TBC 61-70: reuse the mature 50-60 priority list; new TBC spells are picked up via spell_data/learned checks.
        did_action = levels.rotation_level_50_60(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    end

    if helpers and helpers.log_checkpoint then
        if did_action then
            helpers:log_checkpoint("rot.exec.action", 0.5, "[ROT] ACTION")
        else
            helpers:log_checkpoint("rot.exec.none", 1.0, "[ROT] NO_ACTION")
        end
    end

    return did_action
end

return rotation_logic
