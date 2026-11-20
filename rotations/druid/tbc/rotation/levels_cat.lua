-- ============================================================================
-- Druid Cat (Feral DPS) Level-Based Rotation - TBC (2.4.3)
-- Level ranges based on when abilities become available
-- ============================================================================

local levels_cat = {}

local spells = require("rotations/druid/tbc/spells")
local cc = require("rotations/druid/tbc/rotation/cc")
local common = require("rotations/druid/tbc/rotation/common")

-- ============================================================================
-- LEVEL 1-9: CASTER ONLY (no forms available)
-- Wrath(1), Moonfire(4), Rejuvenation(4), Thorns(6), Entangling Roots(8)
-- ============================================================================

function levels_cat.level_1_9(player, target, helpers, menu)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    -- Self-heal if low HP
    local hp = helpers:get_hp_pct(player)
    if hp < 50 and helpers:is_spell_learned(spells.rejuvenation) then
        if not helpers:has_buff(player, spells.REJUV_BUFF_IDS) then
            if helpers:try_cast(spells.rejuvenation, player, "[Heal] Rejuvenation (self)") then return true end
        end
    end
    if hp < 35 and helpers:is_spell_learned(spells.healing_touch) then
        if helpers:try_cast(spells.healing_touch, player, "[Heal] Healing Touch (self)") then return true end
    end

    -- Moonfire DoT
    if common.try_moonfire(player, target, helpers) then return true end

    -- Wrath filler (must be standing still)
    if not helpers:is_moving(player) then
        if helpers:try_cast(spells.wrath, target, "[DPS] Wrath") then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 10-19: BEAR FORM AVAILABLE (no Cat Form yet)
-- Bear Form(10), Maul(10), Growl(10), Swipe(16)
-- Still use caster spells to pull, bear to fight
-- ============================================================================

function levels_cat.level_10_19(player, target, helpers, menu)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)

    -- Self-heal in caster form if low and not in bear
    if hp < 40 and not helpers:is_in_form(player, "bear") then
        if helpers:is_spell_learned(spells.rejuvenation) and not helpers:has_buff(player, spells.REJUV_BUFF_IDS) then
            if helpers:try_cast(spells.rejuvenation, player, "[Heal] Rejuvenation (self)") then return true end
        end
        if helpers:is_spell_learned(spells.healing_touch) then
            if not helpers:is_moving(player) then
                if helpers:try_cast(spells.healing_touch, player, "[Heal] Healing Touch (self)") then return true end
            end
        end
    end

    -- Enter bear form for melee
    if not helpers:is_in_form(player, "bear") then
        if helpers:is_in_melee_range(player, target) then
            return helpers:try_enter_form(player, "bear")
        else
            -- Pull with Moonfire at range
            if common.try_moonfire(player, target, helpers) then return true end
            if not helpers:is_moving(player) then
                if helpers:try_cast(spells.wrath, target, "[DPS] Wrath") then return true end
            end
            return false
        end
    end

    -- Bear form rotation
    common.ensure_auto_attack(player, target, helpers)
    local rage = helpers:get_rage(player)

    -- Maul spam
    if rage >= 15 then
        if helpers:try_cast(spells.maul, target, "[Bear] Maul") then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: CAT FORM AVAILABLE
-- Cat Form(20), Claw(20), Rip(20), Shred(22), Rake(24), Tiger's Fury(24)
-- Powershifting starts here (if Furor talent taken)
-- ============================================================================

function levels_cat.level_20_29(player, target, helpers, menu, energy, cp)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)

    -- Emergency survival
    if hp < 30 and not helpers:is_in_form(player, "cat") and not helpers:is_in_form(player, "bear") then
        -- Self-heal in caster form
        if helpers:is_spell_learned(spells.rejuvenation) and not helpers:has_buff(player, spells.REJUV_BUFF_IDS) then
            if helpers:try_cast(spells.rejuvenation, player, "[Heal] Rejuvenation") then return true end
        end
        if not helpers:is_moving(player) and helpers:is_spell_learned(spells.healing_touch) then
            if helpers:try_cast(spells.healing_touch, player, "[Heal] Healing Touch") then return true end
        end
    end

    -- Enter Cat Form
    if not helpers:is_in_form(player, "cat") then
        return helpers:try_enter_form(player, "cat")
    end

    -- Auto-Attack
    common.ensure_auto_attack(player, target, helpers)

    -- Tiger's Fury (pre-combat or very low energy in solo)
    if helpers:get_menu_state(menu.cat_use_tigers_fury, true) then
        if not helpers:is_in_combat(player) and helpers:is_spell_learned(spells.tigers_fury) then
            if helpers:is_spell_ready(spells.tigers_fury) then
                local last_cast = helpers:get_last_cast_time(spells.tigers_fury)
                if (core.game_time() - last_cast) > 2000 then
                    if helpers:try_cast(spells.tigers_fury, player, "[Cat] Tiger's Fury (pre-pull)") then return true end
                end
            end
        end
    end

    -- Finishers
    local ttd = helpers:safe_ttd(target)
    if cp >= 5 or (ttd < 5 and cp >= 1) then
        if common.try_rip(player, target, helpers, menu, cp, energy) then return true end
        if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
    end

    -- Rake DoT (learned at level 24, significant DPS gain)
    if helpers:get_menu_state(menu.cat_use_rake, true) then
        if common.try_rake(player, target, helpers, energy) then return true end
    end

    -- Builder: Energy dump logic
    local dump_energy = (cp >= 5 and energy >= 80)
    local no_bite = (cp >= 5 and not helpers:is_spell_learned(spells.ferocious_bite))
    if cp < 5 or dump_energy or no_bite then
        -- Shred (behind, level 22+)
        if energy >= 42 then
            if common.try_shred(player, target, helpers, energy) then return true end
        end
        -- Claw (no position requirement)
        if energy >= 45 then
            if common.try_claw(player, target, helpers, energy) then return true end
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 30-39: ENHANCED TOOLKIT
-- Travel Form(30), Ferocious Bite(32), Ravage(32), Pounce(36), Bash(30)
-- ============================================================================

function levels_cat.level_30_39(player, target, helpers, menu, energy, cp)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)

    -- Emergency survival: Barkskin (if learned at this level range from talents)
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- Emergency: drop to caster to heal
    if hp < 25 and not helpers:is_in_form(player, "cat") and not helpers:is_in_form(player, "bear") then
        if helpers:is_spell_learned(spells.rejuvenation) and not helpers:has_buff(player, spells.REJUV_BUFF_IDS) then
            if helpers:try_cast(spells.rejuvenation, player, "[Heal] Rejuvenation") then return true end
        end
    end

    -- Enter Cat Form
    if not helpers:is_in_form(player, "cat") then
        return helpers:try_enter_form(player, "cat")
    end

    -- Auto-Attack
    common.ensure_auto_attack(player, target, helpers)

    -- Tiger's Fury (pre-pull)
    if helpers:get_menu_state(menu.cat_use_tigers_fury, true) then
        if not helpers:is_in_combat(player) and helpers:is_spell_learned(spells.tigers_fury) then
            if helpers:is_spell_ready(spells.tigers_fury) then
                local last_cast = helpers:get_last_cast_time(spells.tigers_fury)
                if (core.game_time() - last_cast) > 2000 then
                    if helpers:try_cast(spells.tigers_fury, player, "[Cat] Tiger's Fury") then return true end
                end
            end
        end
    end

    -- Faerie Fire (Feral) if learned from talents
    if helpers:get_menu_state(menu.cat_use_faerie_fire, true) then
        if common.try_faerie_fire(player, target, helpers, menu) then return true end
    end

    -- Rake DoT
    if helpers:get_menu_state(menu.cat_use_rake, true) then
        if common.try_rake(player, target, helpers, energy) then return true end
    end

    -- Finishers
    local ttd = helpers:safe_ttd(target)
    if cp >= 5 or (ttd < 5 and cp >= 1) then
        if common.try_rip(player, target, helpers, menu, cp, energy) then return true end
        if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
    end

    -- Builders
    local dump_energy = (cp >= 5 and energy >= 80)
    local no_bite = (cp >= 5 and not helpers:is_spell_learned(spells.ferocious_bite))
    if cp < 5 or dump_energy or no_bite then
        if common.try_shred(player, target, helpers, energy) then return true end
        if common.try_claw(player, target, helpers, energy) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 40-49: DIRE BEAR + DEFENSIVES
-- Dire Bear Form(40), Feral Charge(40 talent), Barkskin(44)
-- ============================================================================

function levels_cat.level_40_49(player, target, helpers, menu, energy, cp)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)

    -- Emergency Barkskin
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- Emergency bear form
    if hp < 15 then
        if common.try_emergency_bear_form(player, helpers, hp, 15) then return true end
    end

    -- Enter Cat Form
    if not helpers:is_in_form(player, "cat") then
        return helpers:try_enter_form(player, "cat")
    end

    -- Auto-Attack
    common.ensure_auto_attack(player, target, helpers)

    -- Tiger's Fury (pre-pull)
    if helpers:get_menu_state(menu.cat_use_tigers_fury, true) then
        if not helpers:is_in_combat(player) and helpers:is_spell_learned(spells.tigers_fury) then
            if helpers:is_spell_ready(spells.tigers_fury) then
                local last_cast = helpers:get_last_cast_time(spells.tigers_fury)
                if (core.game_time() - last_cast) > 2000 then
                    if helpers:try_cast(spells.tigers_fury, player, "[Cat] Tiger's Fury") then return true end
                end
            end
        end
    end

    -- Faerie Fire (Feral)
    if helpers:get_menu_state(menu.cat_use_faerie_fire, true) then
        if common.try_faerie_fire(player, target, helpers, menu) then return true end
    end

    -- Rake DoT
    if helpers:get_menu_state(menu.cat_use_rake, true) then
        if common.try_rake(player, target, helpers, energy) then return true end
    end

    -- Finishers
    local ttd = helpers:safe_ttd(target)
    if cp >= 4 or (ttd < 5 and cp >= 1) then
        -- 1. Try Rip
        if energy >= 30 then
            if common.try_rip(player, target, helpers, menu, cp, energy) then return true end
        end

        -- 2. Try Ferocious Bite
        if energy >= 35 then
            local has_rip = helpers:has_debuff(target, spells.RIP_DEBUFF_IDS)
            local min_ttd = menu and helpers:get_menu_value(menu.cat_rip_min_ttd, 12) or 12
            if target_hp <= 20 or has_rip or ttd < min_ttd then
                if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
            end
        end
    end

    -- Builders
    local dump_energy = (cp >= 5 and energy >= 80)
    local no_bite = (cp >= 5 and not helpers:is_spell_learned(spells.ferocious_bite))
    if cp < 5 or dump_energy or no_bite then
        if common.try_shred(player, target, helpers, energy) then return true end
        if common.try_claw(player, target, helpers, energy) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 50-70: FULL ROTATION (Mangle talent available)
-- Mangle Cat(50 talent), Lacerate(66), Cyclone(70), Lifebloom(64)
-- This is THE endgame rotation with bite weave and powershifting
-- ============================================================================

function levels_cat.level_50_70(player, target, helpers, menu, energy, cp)
    -- CC check
    if cc.should_pause_for_cc(target) then
        helpers:stop_auto_attack(player, target)
        return true
    end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)

    -- Emergency Barkskin (usable in any form, even while stunned)
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- Emergency bear form at critical HP
    if hp < 15 then
        if common.try_emergency_bear_form(player, helpers, hp, 15) then return true end
    end

    -- Enter Cat Form
    if not helpers:is_in_form(player, "cat") then
        return helpers:try_enter_form(player, "cat")
    end

    -- Auto-Attack
    common.ensure_auto_attack(player, target, helpers)

    -- Tiger's Fury (pre-pull only - DPS loss mid-combat)
    if helpers:get_menu_state(menu.cat_use_tigers_fury, true) then
        if not helpers:is_in_combat(player) and helpers:is_spell_learned(spells.tigers_fury) then
            if helpers:is_spell_ready(spells.tigers_fury) then
                local last_cast = helpers:get_last_cast_time(spells.tigers_fury)
                if (core.game_time() - last_cast) > 2000 then
                    if helpers:try_cast(spells.tigers_fury, player, "[Cat] Tiger's Fury (pre-pull)") then return true end
                end
            end
        end
    end

    -- Faerie Fire (Feral) - instant, maintain debuff
    if helpers:get_menu_state(menu.cat_use_faerie_fire, true) then
        if common.try_faerie_fire(player, target, helpers, menu) then return true end
    end

    -- ============================
    -- MANGLE DEBUFF MAINTENANCE (highest DPS priority)
    -- Mangle debuff = +30% to bleed damage (Rip, Rake, Shred)
    -- ============================
    if common.try_mangle_cat(player, target, helpers, energy) then return true end

    -- ============================
    -- RAKE DOT (significant DPS with Mangle debuff +30% bleed damage)
    -- ============================
    if helpers:get_menu_state(menu.cat_use_rake, true) then
        if common.try_rake(player, target, helpers, energy) then return true end
    end

    -- ============================
    -- FINISHERS
    -- ============================
    helpers:log_debug(string.format("Cat State: CP=%d, Energy=%d", cp, energy))

    local ttd = helpers:safe_ttd(target)
    if cp >= 4 or (ttd < 5 and cp >= 1) then
        -- 1. Try Rip (if not up and will last)
        if energy >= 30 then
            if common.try_rip(player, target, helpers, menu, cp, energy) then return true end
        end

        -- 2. Try Ferocious Bite (bite weave / execute / emergency dump)
        if helpers:is_spell_learned(spells.ferocious_bite) and energy >= 35 then
            local has_rip = helpers:has_debuff(target, spells.RIP_DEBUFF_IDS)
            local rip_remaining = helpers:get_debuff_remaining_ms(target, spells.RIP_DEBUFF_IDS)
            local min_ttd = menu and helpers:get_menu_value(menu.cat_rip_min_ttd, 12) or 12

            -- Execute: target dying soon
            if target_hp <= 20 then
                if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
            end

            -- Short TTD Fallback: Target dies too fast for Rip
            if ttd < min_ttd then
                if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
            end

            -- Bite Weave: Rip is up with plenty of time left
            if helpers:get_menu_state(menu.cat_bite_weave, true) then
                if has_rip and rip_remaining > 8000 and cp >= 5 then
                    if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
                end
            end

            -- Energy Cap Protection: Don't sit at 100 energy doing nothing
            if cp >= 5 and energy >= 80 then
                if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
            end
        end
    end

    -- ============================
    -- BUILDERS (priority: Shred > Mangle > Claw)
    -- ============================
    local dump_energy = (cp >= 5 and energy >= 80)
    local no_bite = (cp >= 5 and not helpers:is_spell_learned(spells.ferocious_bite))
    if cp < 5 or dump_energy or no_bite then
        -- Shred: primary builder (requires behind target)
        if common.try_shred(player, target, helpers, energy) then return true end

        -- Mangle: secondary builder (no position requirement, but check if debuff is already up)
        if helpers:is_spell_learned(spells.mangle_cat) and energy >= 45 then
            if helpers:try_cast(spells.mangle_cat, target, "[Cat] Mangle (builder)") then return true end
        end

        -- Claw: fallback builder (no Mangle talent or energy-starved)
        if common.try_claw(player, target, helpers, energy) then return true end
    end

    return false
end

-- ============================================================================
-- MAIN DISPATCHER
-- ============================================================================

function levels_cat.execute(player, target, helpers, menu, energy, cp)
    local level = helpers:get_level(player)

    if level < 10 then
        return levels_cat.level_1_9(player, target, helpers, menu)
    elseif level < 20 then
        return levels_cat.level_10_19(player, target, helpers, menu)
    elseif level < 30 then
        return levels_cat.level_20_29(player, target, helpers, menu, energy, cp)
    elseif level < 40 then
        return levels_cat.level_30_39(player, target, helpers, menu, energy, cp)
    elseif level < 50 then
        return levels_cat.level_40_49(player, target, helpers, menu, energy, cp)
    else
        return levels_cat.level_50_70(player, target, helpers, menu, energy, cp)
    end
end

return levels_cat
