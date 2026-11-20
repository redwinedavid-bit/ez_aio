local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Druid Bear Tank Rotation - Level Brackets (Classic ERA)
-- Priority-based tanking rotation with threat management
-- ============================================================================

local levels_bear = {}

local common = require("rotations/druid/era/rotation/common")
local cc = require("rotations/druid/era/rotation/cc")

-- ============================================================================
-- LEVEL 10-19: BASIC BEAR TANKING
-- Available: Bear Form(10), Maul(10), Growl(10), Demo Roar(10),
--            Bash(14), Swipe(16), Enrage(18)
-- ============================================================================

function levels_bear.level_10_19(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Bear Form
    if not helpers:is_in_bear_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "bear") then return true end
        end
        return false
    end

    helpers:ensure_auto_attack(target)

    local rage = helpers:get_rage(player)
    local level = helpers:get_player_level(player)

    -- CC check: don't break breakable CC
    if cc.should_pause_for_cc(target) then return true end

    -- Growl: taunt if target is not targeting us
    if helpers:get_menu_state("bear_use_growl") then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (not __object_safety.same(target_target,player)) then
            if helpers:is_cooldown_ready("bear", "growl") then
                if helpers:try_cast("bear", "growl", target) then
                    helpers:log_checkpoint("growl", 2.0, "[Druid][Bear] Growl - regaining aggro")
                    return true
                end
            end
        end
    end

    -- Bash: interrupt casting targets (level 14+)
    if level >= 14 and helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then
                    helpers:log_checkpoint("bash", 2.0, "[Druid][Bear] Bash interrupt")
                    -- @claude fix this
                    return true
                end
            end
        end
    end

    -- Enrage: generate rage when low (level 18+)
    if level >= 18 and helpers:get_menu_state("bear_use_enrage") then
        if rage < 15 then
            if helpers:is_cooldown_ready("bear", "enrage") then
                if helpers:try_cast("bear", "enrage", player) then
                    helpers:log_checkpoint("enrage", 3.0, "[Druid][Bear] Enrage for rage generation")
                    return true
                end
            end
        end
    end

    -- Demoralizing Roar: maintain debuff
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then
                helpers:log_checkpoint("demo_roar", 3.0, "[Druid][Bear] Demoralizing Roar applied")
                return true
            end
        end
    end

    -- Maul: primary threat (next-melee, not on GCD)
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then
            return true
        end
    end

    -- Swipe: AoE filler (level 16+)
    if level >= 16 and helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then
            return true
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: + FAERIE FIRE
-- ============================================================================

function levels_bear.level_20_29(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Bear Form
    if not helpers:is_in_bear_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "bear") then return true end
        end
        return false
    end

    helpers:ensure_auto_attack(target)

    local rage = helpers:get_rage(player)

    if cc.should_pause_for_cc(target) then return true end

    -- Growl
    if helpers:get_menu_state("bear_use_growl") then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (not __object_safety.same(target_target,player)) then
            if helpers:is_cooldown_ready("bear", "growl") then
                if helpers:try_cast("bear", "growl", target) then return true end
            end
        end
    end

    -- Bash interrupt
    if helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then return true end
            end
        end
    end

    -- Faerie Fire (Feral) - talent check inside try_faerie_fire
    common.try_faerie_fire(player, target, helpers, true)

    -- Enrage
    if helpers:get_menu_state("bear_use_enrage") and rage < 15 then
        if helpers:is_cooldown_ready("bear", "enrage") then
            if helpers:try_cast("bear", "enrage", player) then return true end
        end
    end

    -- Demoralizing Roar
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then return true end
        end
    end

    -- Maul
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then return true end
    end

    -- Swipe
    if helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 30-39: + FRENZIED REGEN, FERAL CHARGE (talent), FF FERAL (talent)
-- ============================================================================

function levels_bear.level_30_39(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Bear Form (or Dire Bear at 40 which isn't this bracket)
    if not helpers:is_in_bear_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "bear") then return true end
        end
        return false
    end

    helpers:ensure_auto_attack(target)

    local rage = helpers:get_rage(player)
    local hp = helpers:get_player_hp(player)

    if cc.should_pause_for_cc(target) then return true end

    -- Frenzied Regeneration (emergency self-heal)
    if hp < helpers:get_menu_value("tank_frenzied_reg_hp", 25) then
        if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
            if helpers:try_cast("bear", "frenzied_regeneration", player) then
                helpers:log_checkpoint("frenzied", 5.0, "[Druid][Bear] Frenzied Regen at HP=" .. math.floor(hp))
                return true
            end
        end
    end

    -- Feral Charge (talent): interrupt + root
    if helpers:is_spell_learned("bear", "feral_charge") then
        if helpers:is_target_casting(target) and rage >= 15 then
            if helpers:is_cooldown_ready("bear", "feral_charge") then
                if helpers:try_cast("bear", "feral_charge", target) then
                    helpers:log_checkpoint("feral_charge", 3.0, "[Druid][Bear] Feral Charge interrupt")
                    return true
                end
            end
        end
    end

    -- Growl
    if helpers:get_menu_state("bear_use_growl") then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (not __object_safety.same(target_target,player)) then
            if helpers:is_cooldown_ready("bear", "growl") then
                if helpers:try_cast("bear", "growl", target) then return true end
            end
        end
    end

    -- Bash interrupt
    if helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then return true end
            end
        end
    end

    -- Faerie Fire Feral (free, no rage cost, in bear form)
    common.try_faerie_fire(player, target, helpers, true)

    -- Enrage
    if helpers:get_menu_state("bear_use_enrage") and rage < 20 then
        if helpers:is_cooldown_ready("bear", "enrage") then
            if helpers:try_cast("bear", "enrage", player) then return true end
        end
    end

    -- Demoralizing Roar
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then return true end
        end
    end

    -- Maul
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then return true end
    end

    -- Swipe
    if helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 40-49: + DIRE BEAR FORM, BARKSKIN(44)
-- ============================================================================

function levels_bear.level_40_49(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Dire Bear Form (prefer over Bear Form)
    if not helpers:is_in_bear_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "bear") then return true end
        end
        return false
    end

    helpers:ensure_auto_attack(target)

    local rage = helpers:get_rage(player)
    local hp = helpers:get_player_hp(player)

    if cc.should_pause_for_cc(target) then return true end

    -- Frenzied Regeneration
    if hp < helpers:get_menu_value("tank_frenzied_reg_hp", 25) then
        if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
            if helpers:try_cast("bear", "frenzied_regeneration", player) then return true end
        end
    end

    -- Feral Charge interrupt
    if helpers:is_spell_learned("bear", "feral_charge") then
        if helpers:is_target_casting(target) and rage >= 15 then
            if helpers:is_cooldown_ready("bear", "feral_charge") then
                if helpers:try_cast("bear", "feral_charge", target) then return true end
            end
        end
    end

    -- Growl
    if helpers:get_menu_state("bear_use_growl") then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (not __object_safety.same(target_target,player)) then
            if helpers:is_cooldown_ready("bear", "growl") then
                if helpers:try_cast("bear", "growl", target) then return true end
            end
        end
    end

    -- Bash interrupt
    if helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then return true end
            end
        end
    end

    -- Faerie Fire Feral
    common.try_faerie_fire(player, target, helpers, true)

    -- Enrage
    if helpers:get_menu_state("bear_use_enrage") and rage < 20 then
        if helpers:is_cooldown_ready("bear", "enrage") then
            if helpers:try_cast("bear", "enrage", player) then return true end
        end
    end

    -- Demoralizing Roar
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then return true end
        end
    end

    -- Maul
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then return true end
    end

    -- Swipe
    if helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 50-60: FULL BEAR ROTATION
-- Full kit: Maul queue, FF Feral on CD, Growl aggro, Bash interrupt,
-- Demo Roar maintain, Swipe AoE, Enrage rage gen, Frenzied Regen emergency
-- ============================================================================

function levels_bear.level_50_60(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Dire Bear Form
    if not helpers:is_in_bear_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "bear") then return true end
        end
        return false
    end

    helpers:ensure_auto_attack(target)

    local rage = helpers:get_rage(player)
    local hp = helpers:get_player_hp(player)

    if cc.should_pause_for_cc(target) then return true end

    -- 1. Frenzied Regeneration (emergency)
    if hp < helpers:get_menu_value("tank_frenzied_reg_hp", 25) then
        if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
            if helpers:try_cast("bear", "frenzied_regeneration", player) then
                helpers:log_checkpoint("frenzied", 5.0, "[Druid][Bear] Frenzied Regen at HP=" .. math.floor(hp))
                return true
            end
        end
    end

    -- 2. Feral Charge (interrupt priority)
    if helpers:is_spell_learned("bear", "feral_charge") then
        if helpers:is_target_casting(target) and rage >= 15 then
            if helpers:is_cooldown_ready("bear", "feral_charge") then
                if helpers:try_cast("bear", "feral_charge", target) then
                    helpers:log_checkpoint("feral_charge", 3.0, "[Druid][Bear] Feral Charge interrupt")
                    return true
                end
            end
        end
    end

    -- 3. Growl (taunt on aggro loss)
    if helpers:get_menu_state("bear_use_growl") then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (not __object_safety.same(target_target,player)) then
            if helpers:is_cooldown_ready("bear", "growl") then
                if helpers:try_cast("bear", "growl", target) then
                    helpers:log_checkpoint("growl", 2.0, "[Druid][Bear] Growl - regaining aggro")
                    return true
                end
            end
        end
    end

    -- 4. Bash (interrupt)
    if helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then
                    helpers:log_checkpoint("bash", 2.0, "[Druid][Bear] Bash interrupt")
                    return true
                end
            end
        end
    end

    -- 5. Faerie Fire Feral (free threat, on CD)
    if common.try_faerie_fire(player, target, helpers, true) then
        return true
    end

    -- 6. Enrage (rage generation when low)
    if helpers:get_menu_state("bear_use_enrage") and rage < 20 then
        local enrage_safe = hp > 60 -- Don't enrage when low HP (reduces armor)
        if enrage_safe then
            if helpers:is_cooldown_ready("bear", "enrage") then
                if helpers:try_cast("bear", "enrage", player) then
                    helpers:log_checkpoint("enrage", 5.0, "[Druid][Bear] Enrage for rage gen")
                    return true
                end
            end
        end
    end

    -- 7. Demoralizing Roar (maintain debuff)
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then return true end
        end
    end

    -- 8. Maul (primary threat, queue on every swing)
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then return true end
    end

    -- 9. Swipe (AoE filler / multi-target threat)
    if helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then return true end
    end

    return false
end

return levels_bear
