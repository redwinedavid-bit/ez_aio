-- ============================================================================
-- Druid Rotation - Main Dispatcher (Classic ERA)
-- Spec selection -> Level dispatch -> PvE/PvP routing
-- ============================================================================

local rotation_logic = {}

local common = require("rotations/druid/era/rotation/common")
local cc = require("rotations/druid/era/rotation/cc")
local levels_cat = require("rotations/druid/era/rotation/levels_cat")
local levels_bear = require("rotations/druid/era/rotation/levels_bear")
local levels_balance = require("rotations/druid/era/rotation/levels_balance")
local levels_resto = require("rotations/druid/era/rotation/levels_resto")
local pvp = require("rotations/druid/era/rotation/pvp")

-- ============================================================================
-- CC CHECK (exported for main.lua auto-attack suppression)
-- ============================================================================

function rotation_logic:is_breakable_cc_active(target)
    return cc.is_breakable_cc_active(target)
end

-- ============================================================================
-- MAIN DISPATCHER
-- ============================================================================

function rotation_logic:execute(player, helpers)
    if not player then return false end

    -- Don't act while casting or channeling
    if helpers:is_player_casting(player) then return false end

    -- Refresh group state (used by healing and buff management)
    helpers:refresh_group_state(player)

    local level = helpers:get_player_level(player)
    local spec = helpers:get_spec()
    local in_combat = helpers:is_in_combat(player)
    local target = helpers:get_target(player)

    -- ====================================================================
    -- PRIORITY 1: Emergency Survival (all specs, in combat)
    -- ====================================================================
    if in_combat then
        if common.try_emergency_survival(player, helpers) then
            return true
        end
    end

    -- ====================================================================
    -- PRIORITY 2: PvP Priority Actions (root breaking, escape)
    -- ====================================================================
    if helpers:is_pvp_mode() then
        -- Root breaking is highest PvP priority
        if helpers:try_break_roots(player) then
            return true
        end
    end

    -- ====================================================================
    -- PRIORITY 3: Powershift continuation (don't interrupt mid-shift)
    -- ====================================================================
    if helpers:is_powershifting() then
        if helpers:try_powershift(player) then
            return true
        end
    end

    -- ====================================================================
    -- PRIORITY 4: OOC Actions (buffs, healing between pulls)
    -- ====================================================================
    if not in_combat then
        if common.try_buff_management(player, helpers) then
            return true
        end
        if common.try_ooc_healing(player, helpers) then
            return true
        end
    end

    -- ====================================================================
    -- PRIORITY 5: Innervate (when mana critically low, any spec)
    -- ====================================================================
    if in_combat then
        if common.try_innervate(player, helpers) then
            return true
        end
    end

    -- ====================================================================
    -- PRIORITY 6: Spec-specific rotation
    -- ====================================================================
    if spec == 1 then
        -- Restoration: always has caster spells from level 1
        return self:execute_resto(player, helpers, level)
    elseif spec == 2 then
        -- Cat DPS: needs Cat Form (level 20+)
        return self:execute_cat(player, target, helpers, level)
    elseif spec == 3 then
        -- Bear Tank: needs Bear Form (level 10+)
        return self:execute_bear(player, target, helpers, level)
    elseif spec == 4 then
        -- Balance: always has caster spells from level 1
        return self:execute_balance(player, target, helpers, level)
    end

    return false
end

-- ============================================================================
-- CAT DPS DISPATCH (with intelligent fallback)
-- ============================================================================

function rotation_logic:execute_cat(player, target, helpers, level)
    local is_pvp = helpers:is_pvp_mode() and target and helpers:is_player_target(target)

    -- Intelligent Fallback: before Cat Form is available
    if level < 10 then
        -- Level 1-9: use caster/balance rotation as fallback
        return levels_balance.level_1_9(player, target, helpers)
    elseif level < 20 then
        -- Level 10-19: use bear rotation as fallback (Bear Form available at 10)
        return levels_bear.level_10_19(player, target, helpers)
    end

    -- PvP routing
    if is_pvp then
        local pvp_cat = require("rotations/druid/era/rotation/pvp_cat")
        return pvp_cat.execute(player, target, helpers, level)
    end

    -- PvE Cat rotation by level
    if level < 30 then
        return levels_cat.level_20_29(player, target, helpers)
    elseif level < 40 then
        return levels_cat.level_30_39(player, target, helpers)
    elseif level < 50 then
        return levels_cat.level_40_49(player, target, helpers)
    else
        return levels_cat.level_50_60(player, target, helpers)
    end
end

-- ============================================================================
-- BEAR TANK DISPATCH (with intelligent fallback)
-- ============================================================================

function rotation_logic:execute_bear(player, target, helpers, level)
    local is_pvp = helpers:is_pvp_mode() and target and helpers:is_player_target(target)

    -- Intelligent Fallback: before Bear Form is available
    if level < 10 then
        -- Level 1-9: use caster/balance rotation as fallback
        return levels_balance.level_1_9(player, target, helpers)
    end

    -- PvP routing
    if is_pvp then
        local pvp_bear = require("rotations/druid/era/rotation/pvp_bear")
        return pvp_bear.execute(player, target, helpers, level)
    end

    -- PvE Bear rotation by level
    if level < 20 then
        return levels_bear.level_10_19(player, target, helpers)
    elseif level < 30 then
        return levels_bear.level_20_29(player, target, helpers)
    elseif level < 40 then
        return levels_bear.level_30_39(player, target, helpers)
    elseif level < 50 then
        return levels_bear.level_40_49(player, target, helpers)
    else
        return levels_bear.level_50_60(player, target, helpers)
    end
end

-- ============================================================================
-- BALANCE DPS DISPATCH
-- ============================================================================

function rotation_logic:execute_balance(player, target, helpers, level)
    local is_pvp = helpers:is_pvp_mode() and target and helpers:is_player_target(target)

    -- PvP routing
    if is_pvp then
        local pvp_balance = require("rotations/druid/era/rotation/pvp_balance")
        return pvp_balance.execute(player, target, helpers, level)
    end

    -- PvE Balance rotation by level
    if level < 10 then
        return levels_balance.level_1_9(player, target, helpers)
    elseif level < 20 then
        return levels_balance.level_10_19(player, target, helpers)
    elseif level < 30 then
        return levels_balance.level_20_29(player, target, helpers)
    elseif level < 40 then
        return levels_balance.level_30_39(player, target, helpers)
    elseif level < 50 then
        return levels_balance.level_40_49(player, target, helpers)
    else
        return levels_balance.level_50_60(player, target, helpers)
    end
end

-- ============================================================================
-- RESTORATION DISPATCH
-- ============================================================================

function rotation_logic:execute_resto(player, helpers, level)
    local is_pvp = helpers:is_pvp_mode()

    -- PvP routing
    if is_pvp then
        local pvp_resto = require("rotations/druid/era/rotation/pvp_resto")
        local target = helpers:get_target(player)
        return pvp_resto.execute(player, target, helpers, level)
    end

    -- PvE Resto rotation by level
    if level < 10 then
        return levels_resto.level_1_9(player, helpers)
    elseif level < 20 then
        return levels_resto.level_10_19(player, helpers)
    elseif level < 30 then
        return levels_resto.level_20_29(player, helpers)
    elseif level < 40 then
        return levels_resto.level_30_39(player, helpers)
    elseif level < 50 then
        return levels_resto.level_40_49(player, helpers)
    else
        return levels_resto.level_50_60(player, helpers)
    end
end

return rotation_logic
