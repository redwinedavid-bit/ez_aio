-- ============================================================================
-- Druid Balance PvP Rotation (Classic ERA)
-- Root + DoT kiting, Nature's Grasp, re-rooting
-- ============================================================================

local pvp_balance = {}

local common = require("rotations/druid/era/rotation/common")

-- ============================================================================
-- MAIN PVP BALANCE EXECUTION
-- ============================================================================

function pvp_balance.execute(player, target, helpers, level)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local mana_pct = helpers:get_mana_pct(player)
    local hp = helpers:get_player_hp(player)
    local min_mana = helpers:get_menu_value("balance_min_mana", 15)

    -- Moonkin Form if talented
    if helpers:is_spell_learned("forms", "moonkin_form") then
        if not helpers:is_in_moonkin_form(player) then
            if helpers:ensure_form(player, "moonkin") then return true end
        end
    end

    -- Nature's Grasp (self-buff: root melee attackers)
    if helpers:get_menu_state("use_natures_grasp") then
        if not helpers:has_buff(player, "natures_grasp") then
            if helpers:is_spell_learned("balance", "natures_grasp") then
                if helpers:is_cooldown_ready("balance", "natures_grasp") then
                    if helpers:try_cast("balance", "natures_grasp", player) then
                        helpers:log_checkpoint("pvp_ng", 5.0, "[Druid][Balance][PvP] Nature's Grasp")
                        return true
                    end
                end
            end
        end
    end

    -- Entangling Roots (CC/kiting - root target at range)
    if helpers:get_menu_state("pvp_use_entangling_roots") and level >= 8 then
        if not helpers:has_debuff(target, "entangling_roots") then
            if helpers:try_cast("balance", "entangling_roots", target) then
                helpers:log_checkpoint("pvp_roots", 3.0, "[Druid][Balance][PvP] Entangling Roots")
                return true
            end
        end
    end

    if mana_pct < min_mana then
        helpers:start_melee_attack(target)
        return true
    end

    -- Faerie Fire (anti-stealth, armor reduction)
    if common.try_faerie_fire(player, target, helpers, false) then return true end

    -- Insect Swarm DoT
    if helpers:get_menu_state("balance_use_insect_swarm") then
        if helpers:is_spell_learned("balance", "insect_swarm") then
            if not helpers:has_debuff(target, "insect_swarm") then
                if common.try_apply_dot(target, "balance", "insect_swarm", "insect_swarm", helpers, 12000) then
                    return true
                end
            end
        end
    end

    -- Moonfire DoT (instant, apply while rooted target is at range)
    if not helpers:has_debuff(target, "moonfire") then
        if common.try_apply_dot(target, "balance", "moonfire", "moonfire", helpers, 12000) then
            return true
        end
    end

    -- Starfire (cast while target is rooted)
    if helpers:has_debuff(target, "entangling_roots") then
        if helpers:get_menu_state("balance_use_starfire") then
            if not helpers:is_player_casting(player) and mana_pct > min_mana then
                if helpers:try_cast("balance", "starfire", target) then return true end
            end
        end
    end

    -- Wrath (shorter cast, use when target is moving)
    if not helpers:is_player_casting(player) and mana_pct > min_mana then
        if helpers:try_cast("balance", "wrath", target) then return true end
    end

    return false
end

return pvp_balance
