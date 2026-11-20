-- ============================================================================
-- Druid Bear PvP Rotation (Classic ERA)
-- Flag carrier mode, Bash/Charge interrupt, form cycling for heals
-- ============================================================================

local pvp_bear = {}

local common = require("rotations/druid/era/rotation/common")

-- ============================================================================
-- MAIN PVP BEAR EXECUTION
-- ============================================================================

function pvp_bear.execute(player, target, helpers, level)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local hp = helpers:get_player_hp(player)
    local rage = helpers:get_rage(player)

    -- Flag Carrier mode: cycle Bear -> Caster(heal) -> Bear
    -- When HP is low, shift to caster for emergency heals then back to bear
    if hp < 40 then
        if helpers:is_in_bear_form(player) then
            -- Frenzied Regen first (stay in bear)
            if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
                if helpers:try_cast("bear", "frenzied_regeneration", player) then
                    helpers:log_checkpoint("pvp_frenzied", 5.0, "[Druid][Bear][PvP] Frenzied Regen FC mode")
                    return true
                end
            end

            -- Shift to caster for emergency heal
            if hp < 30 then
                if helpers:ensure_form(player, "caster") then
                    helpers:log_checkpoint("pvp_fc_heal", 3.0, "[Druid][Bear][PvP] Shifting to caster for heals")
                    return true
                end
            end
        elseif helpers:is_in_caster_form(player) then
            -- In caster form: quick heals then back to bear
            -- NS+HT if available
            if helpers:is_spell_learned("restoration", "natures_swiftness") then
                if helpers:has_buff(player, "natures_swiftness") then
                    if helpers:try_cast("restoration", "healing_touch", player) then return true end
                elseif helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                    if helpers:try_cast("restoration", "natures_swiftness", player) then return true end
                end
            end

            -- Rejuvenation (instant, can shift back immediately after)
            if not helpers:has_buff(player, "rejuvenation") then
                if helpers:try_cast("restoration", "rejuvenation", player) then return true end
            end

            -- Regrowth if time allows
            if hp < 25 then
                if helpers:try_cast("restoration", "regrowth", player) then return true end
            end

            -- Back to Bear Form
            if helpers:ensure_form(player, "bear") then return true end
        end
    end

    -- Ensure Bear Form for combat
    if not helpers:is_in_bear_form(player) then
        if helpers:ensure_form(player, "bear") then return true end
        return false
    end

    helpers:ensure_auto_attack(target)

    -- Feral Charge interrupt
    if helpers:get_menu_state("pvp_use_feral_charge") then
        if helpers:is_target_casting(target) then
            if helpers:is_spell_learned("bear", "feral_charge") then
                if helpers:is_cooldown_ready("bear", "feral_charge") and rage >= 15 then
                    if helpers:try_cast("bear", "feral_charge", target) then
                        helpers:log_checkpoint("pvp_charge", 3.0, "[Druid][Bear][PvP] Feral Charge")
                        return true
                    end
                end
            end
        end
    end

    -- Bash interrupt / stun
    if helpers:get_menu_state("tank_use_bash") then
        if helpers:is_target_casting(target) and rage >= 10 then
            if helpers:is_cooldown_ready("bear", "bash") then
                if helpers:try_cast("bear", "bash", target) then
                    helpers:log_checkpoint("pvp_bash", 3.0, "[Druid][Bear][PvP] Bash stun")
                    return true
                end
            end
        end
    end

    -- Faerie Fire Feral (anti-stealth, armor reduction)
    if common.try_faerie_fire(player, target, helpers, true) then return true end

    -- Demoralizing Roar (AoE AP reduction in teamfights)
    if helpers:get_menu_state("tank_use_demo_roar") and rage >= 10 then
        if not helpers:has_debuff(target, "demoralizing_roar") then
            if helpers:try_cast("bear", "demoralizing_roar", player) then return true end
        end
    end

    -- Maul (damage + threat)
    if rage >= helpers:get_menu_value("tank_maul_rage", 15) then
        if helpers:try_cast("bear", "maul", target) then return true end
    end

    -- Swipe
    if helpers:get_menu_state("bear_use_swipe") and rage >= 20 then
        if helpers:try_cast("bear", "swipe", target) then return true end
    end

    return false
end

return pvp_bear
