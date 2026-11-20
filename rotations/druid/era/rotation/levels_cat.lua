local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Druid Cat DPS Rotation - Level Brackets (Classic ERA)
-- Stealth openers, combo point management, powershifting at 50+
-- ============================================================================

local levels_cat = {}

local common = require("rotations/druid/era/rotation/common")
local cc = require("rotations/druid/era/rotation/cc")

-- ============================================================================
-- SHARED: Stealth Opener Logic
-- ============================================================================

local function try_stealth_opener(player, target, helpers, has_ravage, has_pounce)
    if not helpers:is_stealthed(player) then return false end
    if not target or not helpers:is_valid_enemy(target) then return false end

    local is_pvp = helpers:is_pvp_mode() and helpers:is_player_target(target)

    -- PvP: prefer Pounce (stun) for control
    if is_pvp and has_pounce then
        local energy = helpers:get_energy(player)
        if energy >= 50 then
            if helpers:try_cast("cat", "pounce", target) then
                helpers:log_checkpoint("opener", 3.0, "[Druid][Cat] Pounce opener (PvP)")
                return true
            end
        end
    end

    -- PvE: prefer Ravage (high damage)
    if has_ravage then
        local energy = helpers:get_energy(player)
        if energy >= 60 then
            if helpers:try_cast("cat", "ravage", target) then
                helpers:log_checkpoint("opener", 3.0, "[Druid][Cat] Ravage opener (PvE)")
                return true
            end
        end
    end

    -- Fallback: Pounce if no Ravage
    if has_pounce then
        local energy = helpers:get_energy(player)
        if energy >= 50 then
            if helpers:try_cast("cat", "pounce", target) then
                helpers:log_checkpoint("opener", 3.0, "[Druid][Cat] Pounce opener")
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- SHARED: Finisher Logic
-- ============================================================================

local function try_finisher(player, target, helpers, cp, energy, has_fb)
    local rip_cp = helpers:get_menu_value("cat_rip_cp", 5)

    if cp < rip_cp then return false end

    -- Ferocious Bite: short-lived targets or when Rip is already up
    if has_fb and helpers:get_menu_state("cat_use_ferocious_bite") then
        local fb_cp = helpers:get_menu_value("cat_fb_cp", 5)
        local target_hp = helpers:get_unit_hp(target)

        -- Use FB if: target HP low (will die before Rip ticks), or Rip already active
        if target_hp < 25 or helpers:has_debuff(target, "rip") then
            if cp >= fb_cp and energy >= 35 then
                if helpers:try_cast("cat", "ferocious_bite", target) then
                    helpers:log_checkpoint("fb", 1.5, "[Druid][Cat] Ferocious Bite at " .. cp .. "CP")
                    return true
                end
            end
        end
    end

    -- Rip: primary finisher for long-lived targets (bleed DoT)
    if energy >= 30 then
        if not helpers:has_debuff(target, "rip") then
            if helpers:try_cast("cat", "rip", target) then
                helpers:log_checkpoint("rip", 1.5, "[Druid][Cat] Rip at " .. cp .. "CP")
                return true
            end
        end
    end

    -- Rip is already up, use FB if available (and enabled)
    if has_fb and helpers:get_menu_state("cat_use_ferocious_bite") and energy >= 35 then
        if helpers:try_cast("cat", "ferocious_bite", target) then
            helpers:log_checkpoint("fb_dump", 1.5, "[Druid][Cat] FB (Rip active) at " .. cp .. "CP")
            return true
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: BASIC CAT DPS
-- Available: Cat Form(20), Claw(20), Rip(20), Prowl(20),
--            Shred(22), Rake(24), Tiger's Fury(24), Dash(26)
-- ============================================================================

function levels_cat.level_20_29(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Cat Form
    if not helpers:is_in_cat_form(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "cat") then return true end
        end
        return false
    end

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)
    local level = helpers:get_player_level(player)

    -- Stealth opener (no Ravage or Pounce yet at this level typically)
    -- Ravage at 32, Pounce at 36 - so no openers here

    if cc.should_pause_for_cc(target) then return true end

    helpers:ensure_auto_attack(target)

    -- Tiger's Fury (level 24+, energy < 30)
    if level >= 24 and helpers:get_menu_state("cat_use_tigers_fury") then
        if energy < 30 and not helpers:has_buff(player, "tigers_fury") then
            if helpers:is_cooldown_ready("cat", "tigers_fury") then
                if helpers:try_cast("cat", "tigers_fury", player) then
                    helpers:log_checkpoint("tf", 3.0, "[Druid][Cat] Tiger's Fury")
                    return true
                end
            end
        end
    end

    -- Finisher: Rip (only finisher available, no FB yet)
    local rip_cp = helpers:get_menu_value("cat_rip_cp", 5)
    if cp >= rip_cp and energy >= 30 then
        if not helpers:has_debuff(target, "rip") then
            if helpers:try_cast("cat", "rip", target) then return true end
        end
    end

    -- Rake DoT (level 24+)
    if level >= 24 and helpers:get_menu_state("cat_use_rake") then
        if cp < 5 and energy >= 35 then
            if not helpers:has_debuff(target, "rake") then
                if common.try_apply_dot(target, "cat", "rake", "rake", helpers, 9000) then
                    return true
                end
            end
        end
    end

    -- Shred (from behind, level 22+) > Claw (fallback)
    if cp < 5 then
        if level >= 22 and helpers:get_menu_state("cat_use_shred") and energy >= 60 then
            if helpers:try_cast("cat", "shred", target) then return true end
        end
        if energy >= 40 then
            if helpers:try_cast("cat", "claw", target) then return true end
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 30-39: + FEROCIOUS BITE(32), FF FERAL(30), RAVAGE(32), POUNCE(36)
-- ============================================================================

function levels_cat.level_30_39(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Cat Form
    if not helpers:is_in_cat_form(player) and not helpers:is_stealthed(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "cat") then return true end
        end
        return false
    end

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)
    local level = helpers:get_player_level(player)
    local has_fb = level >= 32
    local has_ravage = level >= 32 and helpers:is_spell_learned("cat", "ravage")
    local has_pounce = level >= 36 and helpers:is_spell_learned("cat", "pounce")

    -- Stealth opener
    if helpers:get_menu_state("cat_use_prowl") then
        if try_stealth_opener(player, target, helpers, has_ravage, has_pounce) then
            return true
        end
    end

    if cc.should_pause_for_cc(target) then return true end

    helpers:ensure_auto_attack(target)

    -- Faerie Fire Feral (free, on CD)
    if common.try_faerie_fire(player, target, helpers, true) then return true end

    -- Tiger's Fury
    if helpers:get_menu_state("cat_use_tigers_fury") then
        if energy < 30 and not helpers:has_buff(player, "tigers_fury") then
            if helpers:is_cooldown_ready("cat", "tigers_fury") then
                if helpers:try_cast("cat", "tigers_fury", player) then return true end
            end
        end
    end

    -- Finisher logic (Rip / FB)
    if try_finisher(player, target, helpers, cp, energy, has_fb) then
        return true
    end

    -- Rake DoT
    if helpers:get_menu_state("cat_use_rake") then
        if cp < 5 and energy >= 35 then
            if not helpers:has_debuff(target, "rake") then
                if common.try_apply_dot(target, "cat", "rake", "rake", helpers, 9000) then
                    return true
                end
            end
        end
    end

    -- Shred > Claw
    if cp < 5 then
        if helpers:get_menu_state("cat_use_shred") and energy >= 60 then
            if helpers:try_cast("cat", "shred", target) then return true end
        end
        if energy >= 40 then
            if helpers:try_cast("cat", "claw", target) then return true end
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 40-49: + DIRE BEAR emergency, INNERVATE(40), BARKSKIN(44)
-- ============================================================================

function levels_cat.level_40_49(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Ensure Cat Form
    if not helpers:is_in_cat_form(player) and not helpers:is_stealthed(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "cat") then return true end
        end
        return false
    end

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)
    local has_ravage = helpers:is_spell_learned("cat", "ravage")
    local has_pounce = helpers:is_spell_learned("cat", "pounce")

    -- Stealth opener
    if helpers:get_menu_state("cat_use_prowl") then
        if try_stealth_opener(player, target, helpers, has_ravage, has_pounce) then
            return true
        end
    end

    if cc.should_pause_for_cc(target) then return true end

    helpers:ensure_auto_attack(target)

    -- Faerie Fire Feral
    if common.try_faerie_fire(player, target, helpers, true) then return true end

    -- Tiger's Fury
    if helpers:get_menu_state("cat_use_tigers_fury") then
        if energy < 30 and not helpers:has_buff(player, "tigers_fury") then
            if helpers:is_cooldown_ready("cat", "tigers_fury") then
                if helpers:try_cast("cat", "tigers_fury", player) then return true end
            end
        end
    end

    -- Finisher logic
    if try_finisher(player, target, helpers, cp, energy, true) then
        return true
    end

    -- Rake DoT
    if helpers:get_menu_state("cat_use_rake") then
        if cp < 5 and energy >= 35 then
            if not helpers:has_debuff(target, "rake") then
                if common.try_apply_dot(target, "cat", "rake", "rake", helpers, 9000) then
                    return true
                end
            end
        end
    end

    -- Cower (threat reduction, optional)
    if helpers:get_menu_state("cat_use_cower") and energy >= 20 then
        -- Only cower if we have high threat (heuristic: target is targeting us and we're not tank)
        local spec = helpers:get_spec()
        if spec == 2 then -- Cat spec, not tank
            local ok, target_target = pcall(function() return target:get_target() end)
            if ok and target_target and (__object_safety.same(target_target,player)) then
                if helpers:try_cast("cat", "cower", target) then
                    helpers:log_checkpoint("cower", 3.0, "[Druid][Cat] Cower for threat reduction")
                    return true
                end
            end
        end
    end

    -- Shred > Claw
    if cp < 5 then
        if helpers:get_menu_state("cat_use_shred") and energy >= 60 then
            if helpers:try_cast("cat", "shred", target) then return true end
        end
        if energy >= 40 then
            if helpers:try_cast("cat", "claw", target) then return true end
        end
    end

    return false
end

-- ============================================================================
-- LEVEL 50-60: FULL CAT ROTATION WITH POWERSHIFTING
-- Opener: Prowl > Ravage/Pounce > TF > Shred to 5CP
-- Maintenance: FF Feral on CD, Rake (dungeon/solo), Shred > Claw
-- Finisher: Rip (long-lived) / FB (short/raid)
-- Powershift: Energy < 10, shift out+back (Furor+Wolfshead = 60 energy)
-- ============================================================================

function levels_cat.level_50_60(player, target, helpers)
    if not target or not helpers:is_valid_enemy(target) then return false end

    -- Powershift continuation (don't interrupt mid-shift)
    if helpers:is_powershifting() then
        if helpers:try_powershift(player) then return true end
    end

    -- Ensure Cat Form
    if not helpers:is_in_cat_form(player) and not helpers:is_stealthed(player) then
        if helpers:get_menu_state("auto_form") then
            if helpers:ensure_form(player, "cat") then return true end
        end
        return false
    end

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)

    -- Stealth opener
    if helpers:get_menu_state("cat_use_prowl") then
        local has_ravage = helpers:is_spell_learned("cat", "ravage")
        local has_pounce = helpers:is_spell_learned("cat", "pounce")
        if try_stealth_opener(player, target, helpers, has_ravage, has_pounce) then
            return true
        end
    end

    if cc.should_pause_for_cc(target) then return true end

    helpers:ensure_auto_attack(target)

    -- 1. Faerie Fire Feral (free, on CD - highest priority in rotation)
    if common.try_faerie_fire(player, target, helpers, true) then return true end

    -- 2. Tiger's Fury (when energy low, before powershift)
    if helpers:get_menu_state("cat_use_tigers_fury") then
        if energy < 30 and not helpers:has_buff(player, "tigers_fury") then
            if helpers:is_cooldown_ready("cat", "tigers_fury") then
                if helpers:try_cast("cat", "tigers_fury", player) then
                    helpers:log_checkpoint("tf", 3.0, "[Druid][Cat] Tiger's Fury")
                    return true
                end
            end
        end
    end

    -- 3. Finisher logic (Rip / FB)
    if try_finisher(player, target, helpers, cp, energy, true) then
        return true
    end

    -- 4. Rake DoT (dungeon/solo only - not used in raids with debuff limit)
    if helpers:get_menu_state("cat_use_rake") then
        if cp < 5 and energy >= 35 then
            if not helpers:has_debuff(target, "rake") then
                if common.try_apply_dot(target, "cat", "rake", "rake", helpers, 9000) then
                    return true
                end
            end
        end
    end

    -- 5. Cower (optional threat reduction)
    if helpers:get_menu_state("cat_use_cower") and energy >= 20 then
        local ok, target_target = pcall(function() return target:get_target() end)
        if ok and target_target and (__object_safety.same(target_target,player)) then
            if helpers:try_cast("cat", "cower", target) then return true end
        end
    end

    -- 6. Combo Point Builders: Shred > Claw
    if cp < 5 then
        -- Prefer Shred (from behind, higher damage)
        if helpers:get_menu_state("cat_use_shred") and energy >= 60 then
            if helpers:try_cast("cat", "shred", target) then return true end
        end
        -- Claw fallback
        if energy >= 40 then
            if helpers:try_cast("cat", "claw", target) then return true end
        end
    end

    -- 7. POWERSHIFTING: When energy is very low and nothing else to do
    -- Energy < 10, no pending actions, shift out and back for 60 energy
    if helpers:get_menu_state("cat_use_powershift") then
        if energy <= 10 and cp < 5 then
            -- Check that we have enough mana to powershift
            local mana_pct = helpers:get_mana_pct(player)
            if mana_pct >= 10 then
                if helpers:try_powershift(player) then
                    return true
                end
            end
        end
    end

    return false
end

return levels_cat
