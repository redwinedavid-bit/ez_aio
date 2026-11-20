-- ============================================================================
-- Druid Cat PvP Rotation (Classic ERA)
-- Pounce opener, burst combo, CC chains, Dash escape
-- ============================================================================

local pvp_cat = {}

local common = require("rotations/druid/era/rotation/common")

-- ============================================================================
-- MAIN PVP CAT EXECUTION
-- ============================================================================

function pvp_cat.execute(player, target, helpers, level)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Stealth: Prowl + Pounce opener
    if helpers:is_stealthed(player) then
        return pvp_cat._stealth_opener(player, target, helpers, level)
    end

    -- Ensure Cat Form
    if not helpers:is_in_cat_form(player) then
        if helpers:ensure_form(player, "cat") then return true end
        return false
    end

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)
    local hp = helpers:get_player_hp(player)

    helpers:ensure_auto_attack(target)

    -- Dash escape when low HP
    if hp < 25 and level >= 26 then
        if helpers:is_cooldown_ready("cat", "dash") then
            if helpers:try_cast("cat", "dash", player) then
                helpers:log_checkpoint("pvp_dash", 5.0, "[Druid][Cat][PvP] Dash escape at HP=" .. math.floor(hp))
                return true
            end
        end
    end

    -- Faerie Fire Feral (prevent stealth on rogues, armor reduction)
    if common.try_faerie_fire(player, target, helpers, true) then return true end

    -- Tiger's Fury
    if helpers:get_menu_state("cat_use_tigers_fury") then
        if energy < 30 and not helpers:has_buff(player, "tigers_fury") then
            if helpers:is_cooldown_ready("cat", "tigers_fury") then
                if helpers:try_cast("cat", "tigers_fury", player) then return true end
            end
        end
    end

    -- Ferocious Bite at 5CP (PvP burst damage)
    if cp >= 5 and energy >= 35 then
        if helpers:is_spell_learned("cat", "ferocious_bite") then
            if helpers:try_cast("cat", "ferocious_bite", target) then
                helpers:log_checkpoint("pvp_fb", 2.0, "[Druid][Cat][PvP] Ferocious Bite burst at 5CP")
                return true
            end
        end
    end

    -- Rip at 5CP if FB not available or target HP high
    if cp >= 5 and energy >= 30 then
        local target_hp = helpers:get_unit_hp(target)
        if target_hp > 40 and not helpers:has_debuff(target, "rip") then
            if helpers:try_cast("cat", "rip", target) then return true end
        end
    end

    -- Rake (bleed pressure)
    if helpers:get_menu_state("cat_use_rake") and cp < 5 and energy >= 35 then
        if not helpers:has_debuff(target, "rake") then
            if helpers:try_cast("cat", "rake", target) then return true end
        end
    end

    -- Shred (from behind) > Claw
    if cp < 5 then
        if helpers:get_menu_state("cat_use_shred") and energy >= 60 then
            if helpers:try_cast("cat", "shred", target) then return true end
        end
        if energy >= 40 then
            if helpers:try_cast("cat", "claw", target) then return true end
        end
    end

    -- Bear shift for Bash on enemy healer (when energy is low and we need CC)
    if energy < 20 and cp < 3 then
        if helpers:is_target_casting(target) then
            -- Shift to bear for Bash interrupt
            if helpers:ensure_form(player, "bear") then
                helpers:log_checkpoint("pvp_bear_bash", 3.0, "[Druid][Cat][PvP] Shifting to Bear for Bash")
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- STEALTH OPENER
-- ============================================================================

function pvp_cat._stealth_opener(player, target, helpers, level)
    local energy = helpers:get_energy(player)

    -- Pounce (PvP preferred: 2sec stun + bleed)
    if level >= 36 and helpers:is_spell_learned("cat", "pounce") then
        if energy >= 50 then
            if helpers:try_cast("cat", "pounce", target) then
                helpers:log_checkpoint("pvp_opener", 5.0, "[Druid][Cat][PvP] Pounce opener")
                return true
            end
        end
        return true -- Wait for energy
    end

    -- Ravage fallback (if no Pounce yet)
    if level >= 32 and helpers:is_spell_learned("cat", "ravage") then
        if energy >= 60 then
            if helpers:try_cast("cat", "ravage", target) then return true end
        end
        return true
    end

    -- No opener available, just open with Claw
    if energy >= 40 then
        if helpers:try_cast("cat", "claw", target) then return true end
    end

    return false
end

return pvp_cat
