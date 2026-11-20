-- ============================================================================
-- Druid Balance DPS Rotation - Level Brackets (Classic ERA)
-- DoT maintenance, Starfire filler, mana management
-- ============================================================================

local levels_balance = {}

local common = require("rotations/druid/era/rotation/common")
local cc = require("rotations/druid/era/rotation/cc")

-- ============================================================================
-- LEVEL 1-9: BASIC CASTER (also used as fallback for Cat/Bear pre-form)
-- Available: Wrath(1), Moonfire(4), Healing Touch(1), Rejuvenation(4),
--            Thorns(6), Entangling Roots(8)
-- ============================================================================

function levels_balance.level_1_9(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local level = helpers:get_player_level(player)
    local mana_pct = helpers:get_mana_pct(player)
    local min_mana = helpers:get_menu_value("balance_min_mana", 15)

    -- Low mana: just auto-attack
    if mana_pct < min_mana then
        helpers:start_melee_attack(target)
        return true
    end

    -- Moonfire (instant DoT, level 4+)
    if level >= 4 then
        if not helpers:has_debuff(target, "moonfire") then
            if common.try_apply_dot(target, "balance", "moonfire", "moonfire", helpers, 9000) then
                return true
            end
        end
    end

    -- Entangling Roots (CC for kiting, level 8+, solo/HC)
    if level >= 8 and helpers:is_hardcore_mode() then
        local hp = helpers:get_player_hp(player)
        if hp < 50 and not helpers:has_debuff(target, "entangling_roots") then
            if helpers:try_cast("balance", "entangling_roots", target) then
                helpers:log_checkpoint("roots", 3.0, "[Druid][Balance] Entangling Roots for kiting")
                return true
            end
        end
    end

    -- Wrath (main filler)
    if not helpers:is_player_casting(player) then
        if helpers:try_cast("balance", "wrath", target) then
            return true
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 10-19: + FAERIE FIRE(18)
-- ============================================================================

function levels_balance.level_10_19(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local level = helpers:get_player_level(player)
    local mana_pct = helpers:get_mana_pct(player)
    local min_mana = helpers:get_menu_value("balance_min_mana", 15)

    if mana_pct < min_mana then
        helpers:start_melee_attack(target)
        return true
    end

    -- Faerie Fire (armor reduction, level 18+)
    if level >= 18 then
        if common.try_faerie_fire(player, target, helpers, false) then
            return true
        end
    end

    -- Moonfire DoT
    if not helpers:has_debuff(target, "moonfire") then
        if common.try_apply_dot(target, "balance", "moonfire", "moonfire", helpers, 12000) then
            return true
        end
    end

    -- Entangling Roots (HC kiting)
    if helpers:is_hardcore_mode() then
        local hp = helpers:get_player_hp(player)
        if hp < 50 and not helpers:has_debuff(target, "entangling_roots") then
            if helpers:try_cast("balance", "entangling_roots", target) then return true end
        end
    end

    -- Wrath filler
    if not helpers:is_player_casting(player) and mana_pct > min_mana then
        if helpers:try_cast("balance", "wrath", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: + STARFIRE(20) as PRIMARY filler
-- ============================================================================

function levels_balance.level_20_29(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local mana_pct = helpers:get_mana_pct(player)
    local min_mana = helpers:get_menu_value("balance_min_mana", 15)
    local target_hp = helpers:get_unit_hp(target)

    -- Auto-attack finisher for low HP targets
    local auto_attack_hp = helpers:get_menu_value("balance_auto_attack_hp", 10)
    if target_hp <= auto_attack_hp and auto_attack_hp > 0 then
        helpers:start_melee_attack(target)
        return true
    end

    if mana_pct < min_mana then
        helpers:start_melee_attack(target)
        return true
    end

    -- Faerie Fire
    if common.try_faerie_fire(player, target, helpers, false) then return true end

    -- Insect Swarm (talent DoT)
    if helpers:get_menu_state("balance_use_insect_swarm") then
        if helpers:is_spell_learned("balance", "insect_swarm") then
            if not helpers:has_debuff(target, "insect_swarm") then
                if common.try_apply_dot(target, "balance", "insect_swarm", "insect_swarm", helpers, 12000) then
                    return true
                end
            end
        end
    end

    -- Moonfire DoT
    if not helpers:has_debuff(target, "moonfire") then
        if common.try_apply_dot(target, "balance", "moonfire", "moonfire", helpers, 12000) then
            return true
        end
    end

    -- Starfire (primary filler, level 20+)
    if helpers:get_menu_state("balance_use_starfire") then
        if not helpers:is_player_casting(player) and mana_pct > min_mana then
            if helpers:try_cast("balance", "starfire", target) then return true end
        end
    end

    -- Wrath (fallback filler / shorter cast)
    if not helpers:is_player_casting(player) and mana_pct > min_mana then
        if helpers:try_cast("balance", "wrath", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 30-39: + INSECT SWARM (talent)
-- Same as 20-29 but with better spell ranks
-- ============================================================================

function levels_balance.level_30_39(player, target, helpers)
    -- Same priority as 20-29, talents add Insect Swarm
    return levels_balance.level_20_29(player, target, helpers)
end

-- ============================================================================
-- LEVEL 40-49: + HURRICANE(40), INNERVATE(40), BARKSKIN(44), MOONKIN FORM
-- ============================================================================

function levels_balance.level_40_49(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local mana_pct = helpers:get_mana_pct(player)
    local min_mana = helpers:get_menu_value("balance_min_mana", 15)
    local target_hp = helpers:get_unit_hp(target)
    local level = helpers:get_player_level(player)

    -- Auto-attack finisher
    local auto_attack_hp = helpers:get_menu_value("balance_auto_attack_hp", 10)
    if target_hp <= auto_attack_hp and auto_attack_hp > 0 then
        helpers:start_melee_attack(target)
        return true
    end

    -- Moonkin Form (talent, level 40+)
    if helpers:is_spell_learned("forms", "moonkin_form") then
        if not helpers:is_in_moonkin_form(player) then
            if helpers:ensure_form(player, "moonkin") then return true end
        end
    end

    if mana_pct < min_mana then
        helpers:start_melee_attack(target)
        return true
    end

    -- Faerie Fire
    if common.try_faerie_fire(player, target, helpers, false) then return true end

    -- Insect Swarm
    if helpers:get_menu_state("balance_use_insect_swarm") then
        if helpers:is_spell_learned("balance", "insect_swarm") then
            if not helpers:has_debuff(target, "insect_swarm") then
                if common.try_apply_dot(target, "balance", "insect_swarm", "insect_swarm", helpers, 12000) then
                    return true
                end
            end
        end
    end

    -- Moonfire DoT
    if not helpers:has_debuff(target, "moonfire") then
        if common.try_apply_dot(target, "balance", "moonfire", "moonfire", helpers, 12000) then
            return true
        end
    end

    -- Starfire (primary)
    if helpers:get_menu_state("balance_use_starfire") then
        if not helpers:is_player_casting(player) and mana_pct > min_mana then
            if helpers:try_cast("balance", "starfire", target) then return true end
        end
    end

    -- Wrath (fallback)
    if not helpers:is_player_casting(player) and mana_pct > min_mana then
        if helpers:try_cast("balance", "wrath", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 50-60: FULL BALANCE ROTATION
-- FF > IS > Moonfire > Starfire, Innervate at 30%, Barkskin under pressure
-- ============================================================================

function levels_balance.level_50_60(player, target, helpers)
    -- Same structure as 40-49 with full spell ranks
    return levels_balance.level_40_49(player, target, helpers)
end

return levels_balance
