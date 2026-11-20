local levels = {}

---@type enums
local enums = require("common/enums")

local cc = require("rotations/rogue/tbc/rotation/cc")
local common = require("rotations/rogue/tbc/rotation/common")

-- ========================================================================
-- LEVEL 1-9: BASIC COMBAT
-- ========================================================================

function levels.rotation_level_1_9(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 1-9: BASIC COMBAT
    -- Priority: Interrupt > CC Check > TTD > Eviscerate > Sinister Strike
    -- ========================================================================

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- RACIAL DPS COOLDOWN (Blood Fury/Berserking - available from Level 1)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- Standard Eviscerate logic (5 CP or 3+ CP at <20% HP)
    if common.try_standard_eviscerate(local_player, target, helpers, energy, cp, target_hp_percent) then
        return true
    end

    -- BUILDER: Sinister Strike only (simple pooling)
    local should_pool = common.should_pool_energy(energy, cp, false)
    if not should_pool then
        if energy >= 45 then
            if helpers:try_cast_builder(local_player, target, "sinister_strike") then
                return true
            end
        end
    end

    return false
end

-- ========================================================================
-- LEVEL 10-19: SND AVAILABLE
-- ========================================================================

function levels.rotation_level_10_19(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 10-19: SND AVAILABLE
    -- Priority: Interrupt > CC > TTD > SnD > Eviscerate > Builders
    -- ========================================================================

    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- RACIAL DPS COOLDOWN (Blood Fury/Berserking - available from Level 1)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- Standard SnD refresh logic
    if common.try_standard_snd_refresh(local_player, target, helpers, energy, cp, snd_remaining) then
        return true
    end

    -- Standard Eviscerate logic (5 CP or 3+ CP at <20% HP)
    if common.try_standard_eviscerate(local_player, target, helpers, energy, cp, target_hp_percent) then
        return true
    end

    -- BUILDERS: Backstab + Sinister Strike (simple pooling)
    local should_pool = common.should_pool_energy(energy, cp, false)
    if not should_pool then
        if energy >= 60 then
            if helpers:try_cast_builder(local_player, target, "backstab") then
                return true
            end
        end

        if energy >= 45 then
            if helpers:try_cast_builder(local_player, target, "sinister_strike") then
                return true
            end
        end
    end

    return false
end

-- ========================================================================
-- LEVEL 20-29: COLD BLOOD TALENT
-- ========================================================================

function levels.rotation_level_20_29(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 20-29: COLD BLOOD TALENT
    -- Priority: Interrupt > CC > TTD > Defensive > Cold Blood > SnD > Eviscerate > Builders
    -- ========================================================================

    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
    local cb_available = helpers:is_cooldown_ready("cold_blood")
    local has_cb_buff = helpers:has_buff(local_player, "cold_blood")
    local cooldowns_enabled = helpers:is_cooldowns_toggle_active()
    local cc_enabled = helpers:is_cc_toggle_active()

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- Standard defensive abilities (Riposte, Feint, Kidney Shot)
    if common.try_standard_defensive_abilities(local_player, target, helpers, cp, target_hp_percent, cc_enabled) then
        return true
    end

    -- RACIAL DPS COOLDOWN (Blood Fury/Berserking - available from Level 1)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- COLD BLOOD STATE MACHINE (separate activation from consumption)
    -- STEP 1: Activate Cold Blood (wait for next frame)
    if cooldowns_enabled and cb_available and cp >= 5 and energy >= 35 and not has_cb_buff then
        if helpers:try_cast_cooldown(local_player, "cold_blood") then
            return true
        end
    end

    -- STEP 2: Consume Cold Blood buff with Eviscerate
    if has_cb_buff and cp >= 5 and energy >= 35 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            return true
        end
    end

    -- Standard SnD refresh logic
    if common.try_standard_snd_refresh(local_player, target, helpers, energy, cp, snd_remaining) then
        return true
    end

    -- Standard Eviscerate logic (without Cold Blood)
    if common.try_standard_eviscerate(local_player, target, helpers, energy, cp, target_hp_percent) then
        return true
    end

    -- BUILDERS: Backstab + Sinister Strike (simple pooling)
    local should_pool = common.should_pool_energy(energy, cp, false)
    if not should_pool then
        if energy >= 60 then
            if helpers:try_cast_builder(local_player, target, "backstab") then
                return true
            end
        end

        if energy >= 45 then
            if helpers:try_cast_builder(local_player, target, "sinister_strike") then
                return true
            end
        end
    end

    return false
end

-- ========================================================================
-- LEVEL 30-39: TALENT VARIANTS (HEMORRHAGE/GHOSTLY STRIKE/BLADE FLURRY)
-- ========================================================================

function levels.rotation_level_30_39(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 30-39: TALENT VARIANTS (HEMORRHAGE/GHOSTLY STRIKE/BLADE FLURRY)
    -- Priority: Interrupt > CC > TTD > Defensive > Thistle Tea > Blade Flurry > Cold Blood > Expose Armor > Rupture > SnD > Eviscerate > Builders
    -- ========================================================================

    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
    local enemy_count, enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 4.0)
    local _bf_enemy_count, bf_enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 12.0)
    local is_aoe = enemy_count >= 2
    local cooldowns_enabled = helpers:is_cooldowns_toggle_active()
    local cb_available = helpers:is_cooldown_ready("cold_blood")
    local has_cb_buff = helpers:has_buff(local_player, "cold_blood")
    local is_elite_or_boss = target:get_classification() >= enums.classification.ELITE
    local cc_enabled = helpers:is_cc_toggle_active()

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- Standard defensive abilities (Riposte, Feint, Kidney Shot)
    if common.try_standard_defensive_abilities(local_player, target, helpers, cp, target_hp_percent, cc_enabled) then
        return true
    end

    -- DEFENSIVE RACIALS (Will of the Forsaken, Stoneform)
    if helpers:try_use_defensive_racial(local_player, target) then
        return true
    end

    -- UTILITY RACIALS (Escape Artist)
    if helpers:try_use_utility_racial(local_player, target) then
        return true
    end

    -- THISTLE TEA (Level 30+ - low energy consumable)
    if helpers:try_use_thistle_tea(local_player) then
        return true
    end

    -- RACIAL DPS COOLDOWN (Blood Fury/Berserking - available from Level 1)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- BLADE FLURRY (AoE Toggle - 2+ targets within 5y, independent of Burst Toggle)
    if helpers:is_aoe_toggle_active() and helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
        local player_pos = local_player:get_position()
        if player_pos then
            local enemy_count_5 = helpers:get_enemy_counts_around_position(player_pos, 5, nil)
            if enemy_count_5 >= 2 and helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
                if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                    return true
                end
            end
        end
    end

    -- BLADE FLURRY (Burst - AoE OR long-fight single-target)
    local want_blade_flurry = cooldowns_enabled and common.should_use_blade_flurry_burst(
        target,
        is_aoe,
        bf_enemy_ttd_count,
        is_elite_or_boss,
        target_hp_percent
    )
    if want_blade_flurry then
        -- CC-Safe AoE check before activation (5y melee cleave range)
        local player_pos = local_player:get_position()
        if helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
            if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                return true
            end
        end
    end

    -- COLD BLOOD STATE MACHINE (separate activation from consumption)
    -- STEP 1: Activate Cold Blood (wait for next frame)
    if cooldowns_enabled and cb_available and cp >= 5 and energy >= 35 and not has_cb_buff then
        if helpers:try_cast_cooldown(local_player, "cold_blood") then
            return true
        end
    end

    -- STEP 2: Consume Cold Blood buff with Eviscerate
    if has_cb_buff and cp >= 5 and energy >= 35 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            return true
        end
    end

    -- TBC PVE FINISHERS (SnD > Expose Armor > Rupture > Eviscerate)
    if common.try_tbc_pve_finishers(local_player, target, helpers, energy, cp, target_hp_percent, snd_remaining) then
        return true
    end

    -- CLOAK OF SHADOWS (TBC Defensive)
    if helpers:try_use_cloak_of_shadows(local_player, target) then
        return true
    end

    -- Standard builders (no AR yet at this level)
    if common.try_standard_builders(local_player, target, helpers, energy, cp, false) then
        return true
    end

    return false
end

-- ========================================================================
-- LEVEL 40-49: ADRENALINE RUSH
-- ========================================================================

function levels.rotation_level_40_49(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 40-49: ADRENALINE RUSH
    -- Priority: Interrupt > CC > TTD > Defensive > Thistle Tea > Preparation > AR Timing > Racial > Blade Flurry > Cold Blood > Expose Armor > Rupture > SnD > Eviscerate > Builders
    -- ========================================================================

    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
    local enemy_count, enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 4.0)
    local _bf_enemy_count, bf_enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 12.0)
    local is_aoe = enemy_count >= 2
    local cooldowns_enabled = helpers:is_cooldowns_toggle_active()
    local force_cooldowns_enabled = cooldowns_enabled and helpers:is_burst_mode_always()
    local ar_available = helpers:is_cooldown_ready("adrenaline_rush")
    local has_ar_buff = helpers:has_buff(local_player, "adrenaline_rush")
    local cb_available = helpers:is_cooldown_ready("cold_blood")
    local has_cb_buff = helpers:has_buff(local_player, "cold_blood")
    local is_elite_or_boss = target:get_classification() >= enums.classification.ELITE
    local cc_enabled = helpers:is_cc_toggle_active()

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- Standard defensive abilities (Riposte, Feint, Kidney Shot)
    if common.try_standard_defensive_abilities(local_player, target, helpers, cp, target_hp_percent, cc_enabled) then
        return true
    end

    -- DEFENSIVE RACIALS (Will of the Forsaken, Stoneform)
    if helpers:try_use_defensive_racial(local_player, target) then
        return true
    end

    -- UTILITY RACIALS (Escape Artist)
    if helpers:try_use_utility_racial(local_player, target) then
        return true
    end

    -- THISTLE TEA (Level 30+ - low energy consumable)
    if helpers:try_use_thistle_tea(local_player) then
        return true
    end

    -- PREPARATION (Level 30+ Subtlety - reset major cooldowns)
    if helpers:try_cast_preparation(local_player) then
        return true
    end

    -- ADRENALINE RUSH (pending): once armed, block rotation until tick window and cast.
    if helpers:try_handle_pending_adrenaline_rush(local_player) then
        return true
    end

    -- BLADE FLURRY (AoE Toggle - 2+ targets within 5y, independent of Burst Toggle)
    if helpers:is_aoe_toggle_active() and helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
        local player_pos = local_player:get_position()
        if player_pos then
            local enemy_count_5 = helpers:get_enemy_counts_around_position(player_pos, 5, nil)
            if enemy_count_5 >= 2 and helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
                if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                    return true
                end
            end
        end
    end

    -- FORCE BURST: bypass all AR/BF gating (HP/TTD/SnD/CC-safe AoE checks).
    if force_cooldowns_enabled then
        if helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
            if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                return true
            end
        end

        if ar_available and helpers:try_cast_adrenaline_rush(local_player) then
            return true
        end
    end

    -- ADRENALINE RUSH TIMING (Level 40+ Combat - Elite/Boss with SnD active)
    -- OPTIMIZED: Auto-refresh SnD before AR if it would expire during AR (15s duration)
    if cooldowns_enabled and ar_available and (is_elite_or_boss or target_hp_percent > 80) then
        -- Smart SnD check: refresh if <15s and have CP
        if snd_remaining > 0 and snd_remaining < 15000 and cp >= 2 and energy >= 25 then
            -- Refresh SnD before AR to maintain uptime during burst window
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end

        -- Cast AR if SnD is good (>10s) OR no SnD active
        if snd_remaining > 10000 or snd_remaining == 0 then
            -- BURST STACKING: Prefer Blade Flurry before AR when it's a worthwhile burst window.
            local want_blade_flurry = common.should_use_blade_flurry_burst(
                target,
                is_aoe,
                bf_enemy_ttd_count,
                is_elite_or_boss,
                target_hp_percent
            )
            if want_blade_flurry and helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
                local player_pos = local_player:get_position()
                if helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
                    if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                        return true
                    end
                end
            end

            if helpers:try_cast_adrenaline_rush(local_player) then
                return true
            end
        end
    end

    -- RACIAL DPS COOLDOWN (Level 40+ - Blood Fury/Berserking, stack with AR/BF)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- BLADE FLURRY (Burst - AoE OR long-fight single-target)
    local want_blade_flurry = cooldowns_enabled and common.should_use_blade_flurry_burst(
        target,
        is_aoe,
        bf_enemy_ttd_count,
        is_elite_or_boss,
        target_hp_percent
    )
    if want_blade_flurry then
        -- CC-Safe AoE check before activation (5y melee cleave range)
        local player_pos = local_player:get_position()
        if helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
            if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                return true
            end
        end
    end

    -- COLD BLOOD STATE MACHINE (separate activation from consumption)
    -- STEP 1: Activate Cold Blood (wait for next frame)
    if cooldowns_enabled and cb_available and cp >= 5 and energy >= 35 and not has_cb_buff then
        if helpers:try_cast_cooldown(local_player, "cold_blood") then
            return true
        end
    end

    -- STEP 2: Consume Cold Blood buff with Eviscerate
    if has_cb_buff and cp >= 5 and energy >= 35 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            return true
        end
    end

    -- TBC PVE FINISHERS (SnD > Expose Armor > Rupture > Eviscerate)
    if common.try_tbc_pve_finishers(local_player, target, helpers, energy, cp, target_hp_percent, snd_remaining) then
        return true
    end

    -- CLOAK OF SHADOWS (TBC Defensive)
    if helpers:try_use_cloak_of_shadows(local_player, target) then
        return true
    end

    -- Standard builders (with AR buff support for dynamic thresholds)
    if common.try_standard_builders(local_player, target, helpers, energy, cp, has_ar_buff) then
        return true
    end

    return false
end

-- ========================================================================
-- LEVEL 50-60: FULL ROTATION
-- ========================================================================

function levels.rotation_level_50_60(local_player, target, helpers, energy, cp, target_hp_percent, has_cheap_shot)
    -- ========================================================================
    -- LEVEL 50-60: FULL ROTATION
    -- Priority: Interrupt > CC > TTD > Defensive > Thistle Tea > Preparation > AR Timing > Racial > Blade Flurry > Cold Blood > Expose Armor > Rupture > SnD > Eviscerate > Builders
    -- ========================================================================

    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
    local enemy_count, enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 4.0)
    local _bf_enemy_count, bf_enemy_ttd_count = helpers:get_enemy_counts_cached(target, 8, 12.0)
    local is_aoe = enemy_count >= 2
    local cooldowns_enabled = helpers:is_cooldowns_toggle_active()
    local force_cooldowns_enabled = cooldowns_enabled and helpers:is_burst_mode_always()
    local ar_available = helpers:is_cooldown_ready("adrenaline_rush")
    local has_ar_buff = helpers:has_buff(local_player, "adrenaline_rush")
    local cb_available = helpers:is_cooldown_ready("cold_blood")
    local has_cb_buff = helpers:has_buff(local_player, "cold_blood")
    local is_elite_or_boss = target:get_classification() >= enums.classification.ELITE
    local cc_enabled = helpers:is_cc_toggle_active()

    -- Standard interrupt + CC pause check
    if common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc.should_pause_for_cc) then
        return true
    end

    -- GOUGE ENERGY REGEN / EMERGENCY HEAL (solo only, 80+ energy OR <40% HP)
    local player_hp_pct = local_player:get_health_percentage()
    local should_gouge, should_pause, should_bandage = helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    if should_gouge or should_pause then
        return true
    end

    -- TTD finisher rush
    if common.try_spend_cp_before_death(target, energy, cp, helpers, local_player) then
        return true
    end

    -- Standard defensive abilities (Riposte, Feint, Kidney Shot)
    if common.try_standard_defensive_abilities(local_player, target, helpers, cp, target_hp_percent, cc_enabled) then
        return true
    end

    -- DEFENSIVE RACIALS (Will of the Forsaken, Stoneform)
    if helpers:try_use_defensive_racial(local_player, target) then
        return true
    end

    -- UTILITY RACIALS (Escape Artist)
    if helpers:try_use_utility_racial(local_player, target) then
        return true
    end

    -- THISTLE TEA (Level 30+ - low energy consumable)
    if helpers:try_use_thistle_tea(local_player) then
        return true
    end

    -- PREPARATION (Level 30+ Subtlety - reset major cooldowns)
    if helpers:try_cast_preparation(local_player) then
        return true
    end

    -- ADRENALINE RUSH (pending): once armed, block rotation until tick window and cast.
    if helpers:try_handle_pending_adrenaline_rush(local_player) then
        return true
    end

    -- BLADE FLURRY (AoE Toggle - 2+ targets within 5y, independent of Burst Toggle)
    if helpers:is_aoe_toggle_active() and helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
        local player_pos = local_player:get_position()
        if player_pos then
            local enemy_count_5 = helpers:get_enemy_counts_around_position(player_pos, 5, nil)
            if enemy_count_5 >= 2 and helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
                if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                    return true
                end
            end
        end
    end

    -- FORCE BURST: bypass all AR/BF gating (HP/TTD/SnD/CC-safe AoE checks).
    if force_cooldowns_enabled then
        if helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
            if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                return true
            end
        end

        if ar_available and helpers:try_cast_adrenaline_rush(local_player) then
            return true
        end
    end

    -- ADRENALINE RUSH TIMING (Level 40+ Combat - Elite/Boss with SnD active)
    -- OPTIMIZED: Auto-refresh SnD before AR if it would expire during AR (15s duration)
    if cooldowns_enabled and ar_available and (is_elite_or_boss or target_hp_percent > 80) then
        -- Smart SnD check: refresh if <15s and have CP
        if snd_remaining > 0 and snd_remaining < 15000 and cp >= 2 and energy >= 25 then
            -- Refresh SnD before AR to maintain uptime during burst window
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end

        -- Cast AR if SnD is good (>10s) OR no SnD active
        if snd_remaining > 10000 or snd_remaining == 0 then
            -- BURST STACKING: Prefer Blade Flurry before AR when it's a worthwhile burst window.
            local want_blade_flurry = common.should_use_blade_flurry_burst(
                target,
                is_aoe,
                bf_enemy_ttd_count,
                is_elite_or_boss,
                target_hp_percent
            )
            if want_blade_flurry and helpers:is_cooldown_ready("blade_flurry") and not helpers:has_buff(local_player, "blade_flurry") then
                local player_pos = local_player:get_position()
                if helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
                    if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                        return true
                    end
                end
            end

            if helpers:try_cast_adrenaline_rush(local_player) then
                return true
            end
        end
    end

    -- RACIAL DPS COOLDOWN (Level 40+ - Blood Fury/Berserking, stack with AR/BF)
    if helpers:try_use_racial_dps_cooldown(local_player) then
        return true
    end

    -- BLADE FLURRY (Burst - AoE OR long-fight single-target)
    local want_blade_flurry = cooldowns_enabled and common.should_use_blade_flurry_burst(
        target,
        is_aoe,
        bf_enemy_ttd_count,
        is_elite_or_boss,
        target_hp_percent
    )
    if want_blade_flurry then
        -- CC-Safe AoE check before activation (5y melee cleave range)
        local player_pos = local_player:get_position()
        if helpers:is_aoe_allowed(local_player, player_pos, 5, "BLADE_FLURRY") then
            if helpers:try_cast_cooldown(local_player, "blade_flurry") then
                return true
            end
        end
    end

    -- TBC PVE FINISHERS (SnD > Expose Armor > Rupture > Eviscerate)
    if common.try_tbc_pve_finishers(local_player, target, helpers, energy, cp, target_hp_percent, snd_remaining) then
        return true
    end

    -- CLOAK OF SHADOWS (TBC Defensive)
    if helpers:try_use_cloak_of_shadows(local_player, target) then
        return true
    end

    -- Standard builders (with AR buff support for dynamic thresholds)
    if common.try_standard_builders(local_player, target, helpers, energy, cp, has_ar_buff) then
        return true
    end

    return false
end

return levels

