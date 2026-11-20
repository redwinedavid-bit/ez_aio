-- ============================================================================
-- Druid Bear (Feral Tank) Level-Based Rotation - TBC (2.4.3)
-- Priority: Mangle(6s CD) > Lacerate(stack 5) > Swipe(AoE) > Maul(rage dump)
-- ============================================================================

local levels_bear = {}

local spells = require("rotations/druid/tbc/spells")
local cc = require("rotations/druid/tbc/rotation/cc")
local common = require("rotations/druid/tbc/rotation/common")

-- ============================================================================
-- LEVEL 10-19: BASIC BEAR
-- Bear Form(10), Maul(10), Growl(10), Swipe(16)
-- ============================================================================

function levels_bear.level_10_19(player, target, helpers, menu, rage)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    -- Enter Bear Form
    if not helpers:is_in_form(player, "bear") then
        return helpers:try_enter_form(player, "bear")
    end

    common.ensure_auto_attack(player, target, helpers)

    -- Maul (Off-GCD)
    if rage >= 15 then
        helpers:try_cast(spells.maul, target, "[Bear] Maul")
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: + DEMORALIZING ROAR
-- ============================================================================

function levels_bear.level_20_29(player, target, helpers, menu, rage)
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    if not helpers:is_in_form(player, "bear") then
        return helpers:try_enter_form(player, "bear")
    end

    common.ensure_auto_attack(player, target, helpers)

    -- Demoralizing Roar (debuff maintenance)
    if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

    -- Maul (Off-GCD)
    if rage >= 15 then
        helpers:try_cast(spells.maul, target, "[Bear] Maul")
    end

    -- Swipe (AoE, learned at 16)
    if common.try_swipe(player, target, helpers, menu, rage) then return true end

    return false
end

-- ============================================================================
-- LEVEL 30-39: + BASH, FERAL CHARGE (talent)
-- ============================================================================

function levels_bear.level_30_39(player, target, helpers, menu, rage)
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)

    -- Frenzied Regeneration
    if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end

    if not helpers:is_in_form(player, "bear") then
        return helpers:try_enter_form(player, "bear")
    end

    common.ensure_auto_attack(player, target, helpers)

    -- Interrupt: Bash
    if common.try_bash_interrupt(player, target, helpers, menu) then return true end

    -- Interrupt: Feral Charge
    if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

    -- Demoralizing Roar
    if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

    -- Faerie Fire (Feral)
    if common.try_faerie_fire(player, target, helpers, menu) then return true end

    -- Maul (Off-GCD)
    if rage >= 15 then
        helpers:try_cast(spells.maul, target, "[Bear] Maul")
    end

    -- Swipe (AoE)
    if common.try_swipe(player, target, helpers, menu, rage) then return true end

    return false
end

-- ============================================================================
-- LEVEL 40-49: + DIRE BEAR FORM, ENRAGE, BARKSKIN
-- ============================================================================

function levels_bear.level_40_49(player, target, helpers, menu, rage)
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)

    -- Emergency Barkskin
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- Frenzied Regeneration
    if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end

    -- Enter Dire Bear Form (or Bear Form)
    local has_bear = helpers:is_in_form(player, "bear")
    if not has_bear then
        return helpers:try_enter_form(player, "bear")
    end

    common.ensure_auto_attack(player, target, helpers)

    -- Enrage (pre-pull or low rage)
    if common.try_enrage(player, helpers, menu, rage) then return true end

    -- Interrupt: Bash
    if common.try_bash_interrupt(player, target, helpers, menu) then return true end

    -- Interrupt: Feral Charge
    if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

    -- Demoralizing Roar
    if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

    -- Faerie Fire (Feral)
    if common.try_faerie_fire(player, target, helpers, menu) then return true end

    -- Maul (Off-GCD Rage Dump)
    common.try_maul(player, target, helpers, menu, rage)

    -- Swipe (AoE)
    if common.try_swipe(player, target, helpers, menu, rage) then return true end

    return false
end

-- ============================================================================
-- LEVEL 50-70: FULL ROTATION (Mangle Bear talent, Lacerate at 66)
-- Priority: Mangle(6s CD) → Lacerate(stack 5) → Swipe → Maul(rage dump)
-- ============================================================================

function levels_bear.level_50_70(player, target, helpers, menu, rage)
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)

    -- ============================
    -- SURVIVAL (highest priority)
    -- ============================

    -- Barkskin (usable in any form, even while stunned)
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- Frenzied Regeneration (bear only, converts rage to HP)
    if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end

    -- ============================
    -- FORM CHECK
    -- ============================

    if not helpers:is_in_form(player, "bear") then
        return helpers:try_enter_form(player, "bear")
    end

    helpers:log_debug(string.format("Bear State: Rage=%d", rage))
    common.ensure_auto_attack(player, target, helpers)

    -- ============================
    -- ENRAGE (pre-pull or low rage in combat)
    -- ============================
    if common.try_enrage(player, helpers, menu, rage) then return true end

    -- ============================
    -- INTERRUPTS
    -- ============================

    -- Bash (melee range, 10 rage)
    if common.try_bash_interrupt(player, target, helpers, menu) then return true end

    -- Feral Charge (8-25yd, 15 rage)
    if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

    -- ============================
    -- OFF-GCD: MAUL (Queue)
    -- ============================
    -- Evaluate Maul independently before GCD abilities. It will queue on the next swing.
    common.try_maul(player, target, helpers, menu, rage)

    -- ============================
    -- FAERIE FIRE (FERAL) - Armor reduction (Free, high snap threat)
    -- ============================
    if common.try_faerie_fire(player, target, helpers, menu) then return true end

    -- ============================
    -- MANGLE (BEAR) - Highest threat/damage, 6s CD
    -- ============================
    if common.try_mangle_bear(player, target, helpers, menu, rage) then return true end

    -- ============================
    -- DEMORALIZING ROAR - Debuff maintenance
    -- ============================
    if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

    -- ============================
    -- LACERATE - Stack to 5, then maintain
    -- ============================
    if common.try_lacerate(player, target, helpers, menu, rage) then return true end

    -- ============================
    -- SWIPE - AoE threat (or single-target with high gear)
    -- ============================
    if common.try_swipe(player, target, helpers, menu, rage) then return true end

    return false
end

-- ============================================================================
-- MAIN DISPATCHER
-- ============================================================================

function levels_bear.execute(player, target, helpers, menu, rage)
    local level = helpers:get_level(player)

    if level < 10 then
        -- No bear form, fall back to caster DPS
        local levels_cat = require("rotations/druid/tbc/rotation/levels_cat")
        return levels_cat.level_1_9(player, target, helpers, menu)
    elseif level < 20 then
        return levels_bear.level_10_19(player, target, helpers, menu, rage)
    elseif level < 30 then
        return levels_bear.level_20_29(player, target, helpers, menu, rage)
    elseif level < 40 then
        return levels_bear.level_30_39(player, target, helpers, menu, rage)
    elseif level < 50 then
        return levels_bear.level_40_49(player, target, helpers, menu, rage)
    else
        return levels_bear.level_50_70(player, target, helpers, menu, rage)
    end
end

return levels_bear
