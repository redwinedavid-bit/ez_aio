-- ============================================================================
-- Druid Common Rotation Helpers - TBC (2.4.3)
-- Shared rotation functions used across all specs and level ranges
-- ============================================================================

local common = {}

local spells = require("rotations/druid/tbc/spells")
local cc = require("rotations/druid/tbc/rotation/cc")
local dot_apply_guard = require("shared/dot_apply_guard")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

-- ============================================================================
-- DOT GUARD (shared across all specs)
-- ============================================================================

common.dot_guard = dot_apply_guard.new({ default_grace_ms = 250 })

-- ============================================================================
-- AUTO ATTACK
-- ============================================================================

function common.ensure_auto_attack(player, target, helpers)
    if not player or not target then return end
    helpers:ensure_auto_attack(player, target)
end

-- ============================================================================
-- EMERGENCY SURVIVAL
-- ============================================================================

--- Barkskin: usable in any form, even while stunned. 20% damage reduction, 1min CD.
function common.try_emergency_barkskin(player, helpers, menu, hp_pct)
    if not helpers:is_spell_learned(spells.barkskin) then return false end
    if not helpers:is_spell_ready(spells.barkskin) then return false end

    -- PvP threshold from menu, or default 40%
    local threshold = 40
    if menu and menu.pvp_barkskin_hp then
        threshold = helpers:get_menu_value(menu.pvp_barkskin_hp, 40)
    end

    if hp_pct > threshold then return false end

    return helpers:try_cast(spells.barkskin, player, "[Survival] Barkskin")
end

--- Emergency bear form: switch to bear when HP is critically low
function common.try_emergency_bear_form(player, helpers, hp_pct, threshold)
    threshold = threshold or 20
    if hp_pct > threshold then return false end

    local form = helpers:get_current_form(player)
    if form == "bear" then return false end

    -- Don't switch if already casting
    if helpers:is_casting(player) then return false end

    return helpers:try_enter_form(player, "bear")
end

--- Frenzied Regeneration: bear only, converts rage to HP
function common.try_frenzied_regeneration(player, helpers, menu, hp_pct)
    if not helpers:is_in_form(player, "bear") then return false end
    if not helpers:is_spell_learned(spells.frenzied_regeneration) then return false end
    if not helpers:is_spell_ready(spells.frenzied_regeneration) then return false end

    local threshold = helpers:get_menu_value(menu.tank_frenzied_reg_hp, 25)
    if hp_pct > threshold then return false end

    return helpers:try_cast(spells.frenzied_regeneration, player, "[Survival] Frenzied Regeneration")
end

--- Nature's Swiftness + Healing Touch combo (instant emergency heal)
function common.try_ns_healing_touch(player, helpers, menu, target_ally, hp_pct)
    if not helpers:is_spell_learned(spells.nature_swiftness) then return false end
    if not helpers:is_spell_ready(spells.nature_swiftness) then return false end

    local threshold = 25
    if menu and menu.resto_ns_hp then
        threshold = helpers:get_menu_value(menu.resto_ns_hp, 25)
    end
    if hp_pct > threshold then return false end

    -- Must leave form to cast healing spells (unless in Tree of Life)
    local form = helpers:get_current_form(player)
    if form == "cat" or form == "bear" or form == "moonkin" then
        -- Leave form this frame; on next frame we'll be in caster form and NS+HT will execute
        return helpers:try_leave_form(player)
    end

    -- Cast Nature's Swiftness first
    if not helpers:has_buff(player, spells.NATURES_SWIFTNESS_BUFF_IDS) then
        return helpers:try_cast(spells.nature_swiftness, player, "[Survival] Nature's Swiftness")
    end

    -- NS buff is up, cast instant Healing Touch
    return helpers:try_cast(spells.healing_touch, target_ally, "[Survival] NS + Healing Touch")
end

-- ============================================================================
-- INTERRUPTS (form-aware)
-- ============================================================================

--- Try to interrupt with Bash (bear form, melee range)
function common.try_bash_interrupt(player, target, helpers, menu)
    if not menu or not helpers:get_menu_state(menu.interrupt_bash, true) then return false end
    if not helpers:is_spell_learned(spells.bash) then return false end
    if not helpers:is_spell_ready(spells.bash) then return false end

    -- Must be in bear form
    if not helpers:is_in_form(player, "bear") then return false end

    -- Target must be casting
    if not helpers:is_target_casting(target) then return false end

    -- Must be in melee range
    if not helpers:is_in_melee_range(player, target) then return false end

    local rage = helpers:get_rage(player)
    if rage < (spells.RAGE_COSTS.bash or 10) then return false end

    return helpers:try_cast(spells.bash, target, "[Interrupt] Bash")
end

--- Try to interrupt with Feral Charge (bear form, 8-25yd range)
function common.try_feral_charge_interrupt(player, target, helpers, menu)
    if not menu or not helpers:get_menu_state(menu.interrupt_feral_charge, true) then return false end
    if not helpers:is_spell_learned(spells.feral_charge) then return false end
    if not helpers:is_spell_ready(spells.feral_charge) then return false end

    -- Must be in bear form
    if not helpers:is_in_form(player, "bear") then return false end

    -- Target must be casting
    if not helpers:is_target_casting(target) then return false end

    -- Feral Charge range: 8-25 yards
    local dist = helpers:get_distance(player, target)
    if dist < 8 or dist > 25 then return false end

    local rage = helpers:get_rage(player)
    if rage < (spells.RAGE_COSTS.feral_charge or 15) then return false end

    return helpers:try_cast(spells.feral_charge, target, "[Interrupt] Feral Charge")
end

--- Combined interrupt logic: try Bash first (melee), then Feral Charge (ranged)
function common.try_interrupt(player, target, helpers, menu)
    if not menu or not helpers:get_menu_state(menu.interrupt_enabled, true) then return false end
    if not target then return false end
    if not helpers:is_target_casting(target) then return false end

    -- Only interrupt if in bear form already (don't switch forms just to interrupt in PvE)
    if not helpers:is_in_form(player, "bear") then return false end

    if common.try_bash_interrupt(player, target, helpers, menu) then return true end
    if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

    return false
end

-- ============================================================================
-- FAERIE FIRE MAINTENANCE
-- ============================================================================

--- Apply Faerie Fire (Feral) in cat/bear form, or regular Faerie Fire in caster form
function common.try_faerie_fire(player, target, helpers, menu)
    if not target then return false end

    local form = helpers:get_current_form(player)

    if form == "cat" or form == "bear" then
        -- Feral Faerie Fire (instant, no GCD in TBC for feral version)
        if not helpers:is_spell_learned(spells.faerie_fire_feral) then return false end
        if helpers:has_debuff(target, spells.FERAL_FAERIE_FIRE_DEBUFF_IDS) then return false end
        -- Also check normal FF debuff (another druid may have applied it)
        if helpers:has_debuff(target, spells.FAERIE_FIRE_DEBUFF_IDS) then return false end
        return helpers:try_cast(spells.faerie_fire_feral, target, "[Debuff] Feral Faerie Fire")
    elseif form == "caster" or form == "moonkin" then
        if not helpers:is_spell_learned(spells.faerie_fire) then return false end
        if helpers:has_debuff(target, spells.FAERIE_FIRE_DEBUFF_IDS) then return false end
        if helpers:has_debuff(target, spells.FERAL_FAERIE_FIRE_DEBUFF_IDS) then return false end
        return helpers:try_cast(spells.faerie_fire, target, "[Debuff] Faerie Fire")
    end

    return false
end

-- ============================================================================
-- DOT MANAGEMENT (with dot_apply_guard)
-- ============================================================================

--- Rip finisher (cat form, combo point spender)
function common.try_rip(player, target, helpers, menu, cp, energy)
    local min_cp = helpers:get_menu_value(menu.cat_rip_cp, 5)
    if cp < min_cp then return false end
    if energy < (spells.ENERGY_COSTS.rip or 30) then return false end

    -- Don't Rip if target will die before it finishes (12s duration)
    local min_ttd = helpers:get_menu_value(menu.cat_rip_min_ttd, 12)
    local ttd = helpers:safe_ttd(target)
    if ttd < min_ttd then return false end

    -- Check if Rip is already on target
    if helpers:has_debuff(target, spells.RIP_DEBUFF_IDS) then return false end

    -- DoT guard check
    local spell_id = helpers:safe_call(function() return spells.rip:id() end, 0)
    if spell_id > 0 and common.dot_guard:should_block(spell_id, target) then return false end

    local success = helpers:try_cast(spells.rip, target, "[Cat] Rip")
    if success and spell_id > 0 then
        common.dot_guard:on_cast_requested(spell_id, target, 250)
    end
    return success
end

--- Rake DoT (cat form)
function common.try_rake(player, target, helpers, energy)
    if energy < (spells.ENERGY_COSTS.rake or 40) then return false end
    if not helpers:is_spell_learned(spells.rake) then return false end
    if helpers:has_debuff(target, spells.RAKE_DEBUFF_IDS) then return false end

    -- Optimization: Don't Rake if the target will die before it ticks sufficiently
    local ttd = helpers:safe_ttd(target)
    if ttd < 6 then return false end

    local spell_id = helpers:safe_call(function() return spells.rake:id() end, 0)
    if spell_id > 0 and common.dot_guard:should_block(spell_id, target) then return false end

    local success = helpers:try_cast(spells.rake, target, "[Cat] Rake")
    if success and spell_id > 0 then
        common.dot_guard:on_cast_requested(spell_id, target, 250)
    end
    return success
end

--- Moonfire DoT (balance/caster form)
function common.try_moonfire(player, target, helpers)
    if not helpers:is_spell_learned(spells.moonfire) then return false end
    if helpers:has_debuff(target, spells.MOONFIRE_DEBUFF_IDS) then return false end

    local spell_id = helpers:safe_call(function() return spells.moonfire:id() end, 0)
    if spell_id > 0 and common.dot_guard:should_block(spell_id, target) then return false end

    local success = helpers:try_cast(spells.moonfire, target, "[Balance] Moonfire")
    if success and spell_id > 0 then
        common.dot_guard:on_cast_requested(spell_id, target, 300)
    end
    return success
end

--- Insect Swarm DoT (balance talent)
function common.try_insect_swarm(player, target, helpers, menu)
    if not helpers:get_menu_state(menu.balance_use_insect_swarm, true) then return false end
    if not helpers:is_spell_learned(spells.insect_swarm) then return false end
    if helpers:has_debuff(target, spells.INSECT_SWARM_DEBUFF_IDS) then return false end

    local spell_id = helpers:safe_call(function() return spells.insect_swarm:id() end, 0)
    if spell_id > 0 and common.dot_guard:should_block(spell_id, target) then return false end

    local success = helpers:try_cast(spells.insect_swarm, target, "[Balance] Insect Swarm")
    if success and spell_id > 0 then
        common.dot_guard:on_cast_requested(spell_id, target, 300)
    end
    return success
end

-- ============================================================================
-- MANGLE DEBUFF MAINTENANCE
-- ============================================================================

--- Mangle (Cat) - apply/refresh the 30% bleed debuff
function common.try_mangle_cat(player, target, helpers, energy)
    if not helpers:is_spell_learned(spells.mangle_cat) then return false end
    if energy < (spells.ENERGY_COSTS.mangle_cat or 45) then return false end

    -- Check if Mangle debuff is already on target
    if helpers:has_debuff(target, spells.MANGLE_DEBUFF_IDS) then
        -- Check remaining time - refresh below 3s
        local remaining = helpers:get_debuff_remaining_ms(target, spells.MANGLE_DEBUFF_IDS)
        if remaining > 3000 then return false end
    end

    return helpers:try_cast(spells.mangle_cat, target, "[Cat] Mangle")
end

--- Mangle (Bear) - highest threat ability, 6s CD
function common.try_mangle_bear(player, target, helpers, menu, rage)
    if not helpers:get_menu_state(menu.tank_use_mangle, true) then return false end
    if not helpers:is_spell_learned(spells.mangle_bear) then return false end
    if not helpers:is_spell_ready(spells.mangle_bear) then return false end
    if rage < (spells.RAGE_COSTS.mangle_bear or 20) then return false end

    return helpers:try_cast(spells.mangle_bear, target, "[Bear] Mangle")
end

-- ============================================================================
-- FINISHERS
-- ============================================================================

--- Ferocious Bite - damage finisher for bite weave or execute
function common.try_ferocious_bite(player, target, helpers, menu, cp, energy)
    if not helpers:is_spell_learned(spells.ferocious_bite) then return false end
    
    local ttd = helpers:safe_ttd(target)
    local min_cp = 4
    
    -- If target is dying fast, use at any CP to avoid waste
    if ttd < 5 then min_cp = 1 end

    if cp < min_cp then return false end
    if energy < (spells.ENERGY_COSTS.ferocious_bite or 35) then return false end

    return helpers:try_cast(spells.ferocious_bite, target, "[Cat] Ferocious Bite (CP: " .. cp .. ")")
end

-- ============================================================================
-- BUILDERS
-- ============================================================================

--- Shred - primary builder (requires behind target, 42 energy with talent)
function common.try_shred(player, target, helpers, energy)
    if not helpers:is_spell_learned(spells.shred) then return false end
    if energy < (spells.ENERGY_COSTS.shred or 42) then return false end
    if not helpers:get_menu_state(helpers:get_menu().cat_use_shred, true) then return false end

    -- Shred requires being behind the target
    if not helpers:is_behind(player, target) then return false end

    return helpers:try_cast(spells.shred, target, "[Cat] Shred")
end

--- Claw - fallback builder (no positional requirement)
function common.try_claw(player, target, helpers, energy)
    if not helpers:is_spell_learned(spells.claw) then return false end
    if energy < (spells.ENERGY_COSTS.claw or 45) then return false end

    return helpers:try_cast(spells.claw, target, "[Cat] Claw")
end

-- ============================================================================
-- BEAR ABILITIES
-- ============================================================================

--- Lacerate (stacking bleed, up to 5 stacks)
function common.try_lacerate(player, target, helpers, menu, rage)
    if not helpers:get_menu_state(menu.tank_use_lacerate, true) then return false end
    if not helpers:is_spell_learned(spells.lacerate) then return false end
    if rage < (spells.RAGE_COSTS.lacerate or 15) then return false end

    -- Stack to 5, then refresh before it falls off
    local stacks = helpers:get_debuff_stacks(target, spells.LACERATE_DEBUFF_IDS[1])
    if stacks >= 5 then
        local remaining = helpers:get_debuff_remaining_ms(target, spells.LACERATE_DEBUFF_IDS)
        if remaining > 3000 then return false end
    end

    return helpers:try_cast(spells.lacerate, target, "[Bear] Lacerate (" .. stacks .. " stacks)")
end

--- Swipe (AoE threat)
function common.try_swipe(player, target, helpers, menu, rage)
    if not helpers:get_menu_state(menu.tank_use_swipe, true) then return false end
    if not helpers:is_spell_learned(spells.swipe) then return false end
    if rage < (spells.RAGE_COSTS.swipe or 20) then return false end

    -- Only use if enough enemies nearby
    local min_count = helpers:get_menu_value(menu.tank_swipe_count, 2)
    local enemy_count = helpers:get_enemy_count(player, 8)
    if enemy_count < min_count then
        -- Optimization: Single target rage dump check
        if rage < 60 then return false end
    end

    return helpers:try_cast(spells.swipe, target, "[Bear] Swipe (" .. enemy_count .. " enemies)")
end

--- Maul (rage dump, next-swing ability)
function common.try_maul(player, target, helpers, menu, rage)
    if not helpers:is_spell_learned(spells.maul) then return false end

    local min_rage = helpers:get_menu_value(menu.tank_maul_rage, 15)
    
    -- Smart Rage Check: Don't starve Mangle. If Mangle is ready or almost ready (<1.5s), require more rage.
    if helpers:is_spell_learned(spells.mangle_bear) then
        local mangle_cd = helpers:get_spell_cooldown_ms(spells.mangle_bear)
        if mangle_cd < 1500 then
            min_rage = math.max(min_rage, 35) -- Ensure we have enough for Maul (15) + Mangle (20)
        end
    end

    if rage < min_rage then return false end

    return helpers:try_cast(spells.maul, target, "[Bear] Maul")
end

--- Demoralizing Roar (debuff maintenance)
function common.try_demoralizing_roar(player, target, helpers, menu, rage)
    if not helpers:get_menu_state(menu.tank_use_demo_roar, true) then return false end
    if not helpers:is_spell_learned(spells.demoralizing_roar) then return false end
    if rage < (spells.RAGE_COSTS.demoralizing_roar or 10) then return false end

    if helpers:has_debuff(target, spells.DEMO_ROAR_DEBUFF_IDS) then
        local remaining = helpers:get_debuff_remaining_ms(target, spells.DEMO_ROAR_DEBUFF_IDS)
        if remaining > 3000 then return false end
    end

    return helpers:try_cast(spells.demoralizing_roar, player, "[Bear] Demoralizing Roar")
end

--- Enrage (pre-pull rage generation)
function common.try_enrage(player, helpers, menu, rage)
    if not helpers:get_menu_state(menu.tank_enrage_prepull, true) then return false end
    if not helpers:is_spell_learned(spells.enrage) then return false end
    if not helpers:is_spell_ready(spells.enrage) then return false end

    -- Only use out of combat or when rage is very low
    if helpers:is_in_combat(player) and rage > 20 then return false end

    return helpers:try_cast(spells.enrage, player, "[Bear] Enrage")
end

-- ============================================================================
-- INNERVATE
-- ============================================================================

function common.try_innervate(player, helpers, menu, mana_pct, threshold_key)
    if not helpers:is_spell_learned(spells.innervate) then return false end
    if not helpers:is_spell_ready(spells.innervate) then return false end

    local threshold = 20
    if menu and menu[threshold_key] then
        threshold = helpers:get_menu_value(menu[threshold_key], 20)
    end

    if mana_pct > threshold then return false end

    -- Innervate can be used in any form
    return helpers:try_cast(spells.innervate, player, "[Utility] Innervate (mana: " .. math.floor(mana_pct) .. "%)")
end

return common
