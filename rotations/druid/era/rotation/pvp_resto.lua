local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Druid Resto PvP Rotation (Classic ERA)
-- HoT rolling, Bear form for Bash, Travel Form kiting, NS+HT emergency
-- ============================================================================

local pvp_resto = {}

local common = require("rotations/druid/era/rotation/common")

-- ============================================================================
-- MAIN PVP RESTO EXECUTION
-- ============================================================================

function pvp_resto.execute(player, target, helpers, level)
    local hp = helpers:get_player_hp(player)
    local lowest, lowest_hp = helpers:get_lowest_ally()

    -- Self-preservation is priority in PvP
    -- Travel Form escape when very low
    if hp < 20 and level >= 30 then
        if helpers:try_travel_form_escape(player) then
            return true
        end
    end

    -- Bear Form when focused by melee (Bash + Frenzied Regen)
    if hp < 40 and target and helpers:is_valid_enemy(target) then
        -- Check if we're being attacked
        local ok, target_target = pcall(function() return target:get_target() end)
        local being_focused = ok and target_target and (__object_safety.same(target_target,player))

        if being_focused then
            if helpers:is_in_bear_form(player) then
                -- In bear: Bash the attacker
                if helpers:get_menu_state("tank_use_bash") then
                    local rage = helpers:get_rage(player)
                    if rage >= 10 and helpers:is_cooldown_ready("bear", "bash") then
                        if helpers:try_cast("bear", "bash", target) then
                            helpers:log_checkpoint("pvp_resto_bash", 3.0, "[Druid][Resto][PvP] Bash attacker")
                            return true
                        end
                    end
                end

                -- Feral Charge if available
                if helpers:get_menu_state("pvp_use_feral_charge") then
                    if helpers:is_spell_learned("bear", "feral_charge") then
                        if helpers:is_target_casting(target) then
                            local rage = helpers:get_rage(player)
                            if rage >= 15 and helpers:is_cooldown_ready("bear", "feral_charge") then
                                if helpers:try_cast("bear", "feral_charge", target) then return true end
                            end
                        end
                    end
                end

                -- Frenzied Regen
                if hp < 30 then
                    if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
                        if helpers:try_cast("bear", "frenzied_regeneration", player) then return true end
                    end
                end

                -- Shift back to caster for heals
                if helpers:ensure_form(player, "caster") then return true end
            else
                -- Shift TO bear for stun
                if level >= 10 and hp < 35 then
                    if helpers:ensure_form(player, "bear") then
                        helpers:log_checkpoint("pvp_resto_bear", 3.0, "[Druid][Resto][PvP] Bear Form for CC")
                        return true
                    end
                end
            end
        end
    end

    -- Ensure caster form for healing
    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    -- Barkskin when taking damage
    if helpers:get_menu_state("resto_use_barkskin") and hp < 60 then
        if not helpers:has_buff(player, "barkskin") then
            if helpers:is_cooldown_ready("buffs_utility", "barkskin") then
                if helpers:try_cast("buffs_utility", "barkskin", player) then return true end
            end
        end
    end

    -- Nature's Grasp (root melee attackers)
    if helpers:get_menu_state("use_natures_grasp") then
        if not helpers:has_buff(player, "natures_grasp") then
            if helpers:is_spell_learned("balance", "natures_grasp") then
                if helpers:is_cooldown_ready("balance", "natures_grasp") then
                    if helpers:try_cast("balance", "natures_grasp", player) then return true end
                end
            end
        end
    end

    -- NS+HT emergency (self or ally)
    local heal_target = (hp < (lowest_hp or 100)) and player or (lowest or player)
    local emergency_hp = math.min(hp, lowest_hp or 100)

    if helpers:get_menu_state("resto_use_ns") and emergency_hp < 30 then
        if helpers:is_spell_learned("restoration", "natures_swiftness") then
            if helpers:has_buff(player, "natures_swiftness") then
                if helpers:try_cast("restoration", "healing_touch", heal_target) then return true end
            elseif helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                if helpers:try_cast("restoration", "natures_swiftness", player) then return true end
            end
        end
    end

    -- Swiftmend emergency
    if emergency_hp < 35 and heal_target then
        if helpers:is_spell_learned("restoration", "swiftmend") then
            if helpers:has_buff(heal_target, "rejuvenation") or helpers:has_buff(heal_target, "regrowth") then
                if helpers:is_cooldown_ready("restoration", "swiftmend") then
                    if helpers:try_cast("restoration", "swiftmend", heal_target) then return true end
                end
            end
        end
    end

    -- HoT rolling: Rejuvenation on self (instant, can shift after)
    if hp < 80 and not helpers:has_buff(player, "rejuvenation") then
        if helpers:try_cast("restoration", "rejuvenation", player) then return true end
    end

    -- Regrowth on self
    if hp < 60 and not helpers:has_buff(player, "regrowth") then
        if helpers:try_cast("restoration", "regrowth", player) then return true end
    end

    -- Heal allies
    if lowest and lowest_hp < 80 then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
        if lowest_hp < 50 then
            if helpers:try_cast("restoration", "regrowth", lowest) then return true end
        end
    end

    -- Healing Touch if really needed
    if emergency_hp < 45 then
        if helpers:try_cast("restoration", "healing_touch", heal_target) then return true end
    end

    -- Entangling Roots on attacker (if targeting us)
    if target and helpers:is_valid_enemy(target) and helpers:get_menu_state("pvp_use_entangling_roots") then
        if not helpers:has_debuff(target, "entangling_roots") then
            if helpers:try_cast("balance", "entangling_roots", target) then
                helpers:log_checkpoint("pvp_resto_roots", 3.0, "[Druid][Resto][PvP] Roots on attacker")
                return true
            end
        end
    end

    return false
end

return pvp_resto
