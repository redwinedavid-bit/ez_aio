-- ============================================================================
-- Druid PvP Overlay - TBC (2.4.3)
-- Handles Feral PvP (stealth openers, burst, bear defensive, cyclone chains)
-- and Resto PvP (form-dancing, CC chains, travel kiting)
-- ============================================================================

local pvp = {}

local spells = require("rotations/druid/tbc/spells")
local cc = require("rotations/druid/tbc/rotation/cc")
local common = require("rotations/druid/tbc/rotation/common")

---@type enums
local enums = require("common/enums")

-- DR helper for Cyclone/Bash DR tracking
local dr_helper_loaded, dr_helper = pcall(function()
    return require("shared/dr_helper")
end)
if not dr_helper_loaded then dr_helper = nil end

-- ============================================================================
-- STATE
-- ============================================================================

local _last_cyclone_time = 0
local _last_root_time = 0
local CYCLONE_COOLDOWN_MS = 500
local ROOT_COOLDOWN_MS = 500

-- ============================================================================
-- SHARED PVP UTILITIES
-- ============================================================================

--- Check Cyclone DR before casting
local function can_cyclone(target)
    if not dr_helper then return true end
    local ok, dr = pcall(function()
        return dr_helper.get_dr(target, "cyclone")
    end)
    if ok and dr and dr <= 0.25 then return false end
    return true
end

--- Check Stun DR before Bash
local function can_stun(target)
    if not dr_helper then return true end
    local ok, dr = pcall(function()
        return dr_helper.get_dr(target, "stun")
    end)
    if ok and dr and dr <= 0.25 then return false end
    return true
end

--- Check Root DR before Entangling Roots
local function can_root(target)
    if not dr_helper then return true end
    local ok, dr = pcall(function()
        return dr_helper.get_dr(target, "root")
    end)
    if ok and dr and dr <= 0.25 then return false end
    return true
end

--- Try Cyclone on a target (requires caster form)
local function try_cyclone(player, target, helpers, menu)
    if not helpers:get_menu_state(menu.pvp_use_cyclone, true) then return false end
    if not helpers:is_spell_learned(spells.cyclone) then return false end
    if cc.is_cycloned(target) then return false end
    if not can_cyclone(target) then return false end

    local now = core.game_time()
    if (now - _last_cyclone_time) < CYCLONE_COOLDOWN_MS then return false end

    -- Must be in caster form or moonkin form to cast Cyclone
    local form = helpers:get_current_form(player)
    if form ~= "caster" and form ~= "moonkin" then
        -- Need to leave current form to cast Cyclone
        if helpers:try_leave_form(player) then return true end
        return false
    end

    -- Must be standing still (Cyclone has 1.5s cast time)
    if helpers:is_moving(player) then return false end

    local success = helpers:try_cast(spells.cyclone, target, "[PvP] Cyclone")
    if success then
        _last_cyclone_time = now
    end
    return success
end

--- Try Entangling Roots on melee attacker (requires caster form)
local function try_entangling_roots(player, target, helpers, menu)
    if not helpers:get_menu_state(menu.pvp_use_roots, true) then return false end
    if not helpers:is_spell_learned(spells.entangling_roots) then return false end
    if not can_root(target) then return false end

    -- Don't root if target already rooted
    if helpers:has_debuff(target, spells.ENTANGLING_ROOTS_DEBUFF_IDS) then return false end

    local now = core.game_time()
    if (now - _last_root_time) < ROOT_COOLDOWN_MS then return false end

    -- Must be in caster form
    local form = helpers:get_current_form(player)
    if form ~= "caster" and form ~= "moonkin" then return false end

    -- Must be standing still
    if helpers:is_moving(player) then return false end

    local success = helpers:try_cast(spells.entangling_roots, target, "[PvP] Entangling Roots")
    if success then
        _last_root_time = now
    end
    return success
end

--- Try Nature's Grasp (instant, usable in caster form, roots melee attackers)
local function try_natures_grasp(player, helpers, menu)
    if not helpers:get_menu_state(menu.pvp_use_natures_grasp, true) then return false end
    if not helpers:is_spell_learned(spells.natures_grasp) then return false end
    if not helpers:is_spell_ready(spells.natures_grasp) then return false end
    if helpers:has_buff(player, spells.NATURES_GRASP_BUFF_IDS) then return false end

    return helpers:try_cast(spells.natures_grasp, player, "[PvP] Nature's Grasp")
end

--- Faerie Fire on stealthed/enemy druids/rogues (prevent re-stealth)
local function try_faerie_fire_anti_stealth(player, target, helpers, menu)
    if not helpers:get_menu_state(menu.pvp_faerie_fire_stealth, true) then return false end

    -- Check if target already has FF debuff
    if helpers:has_debuff(target, spells.FAERIE_FIRE_DEBUFF_IDS) then return false end
    if helpers:has_debuff(target, spells.FERAL_FAERIE_FIRE_DEBUFF_IDS) then return false end

    -- Check target class (Rogue or Druid - classes that stealth)
    local ok, target_class = pcall(function() return target:get_class() end)
    if not ok or not target_class then return false end

    if target_class ~= enums.class_id.ROGUE and target_class ~= enums.class_id.DRUID then
        return false
    end

    return common.try_faerie_fire(player, target, helpers, menu)
end

-- ============================================================================
-- FERAL PVP
-- ============================================================================

local function execute_feral_pvp(player, helpers, menu)
    local target = helpers:get_target(player)
    if not target or not helpers:is_valid_enemy(target) then return false end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)
    local form = helpers:get_current_form(player)

    -- ============================
    -- 1. BARKSKIN (usable in any form, even while stunned)
    -- ============================
    local barkskin_hp = helpers:get_menu_value(menu.pvp_barkskin_hp, 40)
    if hp < barkskin_hp then
        if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end
    end

    -- ============================
    -- 2. BEAR FORM DEFENSIVE (when focused by melee at low HP)
    -- ============================
    local bear_hp = helpers:get_menu_value(menu.pvp_bear_hp, 30)
    if hp < bear_hp and form == "cat" then
        if helpers:try_enter_form(player, "bear") then return true end
    end

    -- ============================
    -- 3. BEAR FORM: DEFENSIVE ABILITIES
    -- ============================
    if form == "bear" then
        -- Frenzied Regeneration (emergency heal)
        if hp < 40 then
            if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end
        end

        -- Bash interrupt on enemy casters
        if helpers:is_target_casting(target) and can_stun(target) then
            if common.try_bash_interrupt(player, target, helpers, menu) then return true end
        end

        -- Feral Charge on distant casters
        if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

        -- If HP recovered, switch back to cat for DPS
        if hp > 60 then
            if helpers:try_enter_form(player, "cat") then return true end
        end

        -- Demoralizing Roar (damage reduction on melee attackers)
        local rage = helpers:get_rage(player)
        if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

        -- Maul (rage dump while in bear)
        if common.try_maul(player, target, helpers, menu, rage) then return true end

        return false
    end

    -- ============================
    -- 4. CYCLONE (CC healer or secondary target)
    -- Requires leaving form → caster form → cast
    -- ============================
    -- Only cyclone if we're in a stable position (not critically low HP)
    if hp > 50 and helpers:is_spell_learned(spells.cyclone) then
        local ok, target_class = pcall(function() return target:get_class() end)
        if ok and target_class then
            local is_healer = (target_class == enums.class_id.PRIEST or
                              target_class == enums.class_id.PALADIN or
                              target_class == enums.class_id.SHAMAN or
                              target_class == enums.class_id.DRUID)
            -- Cyclone healers to prevent them from healing our kill target
            if is_healer then
                if try_cyclone(player, target, helpers, menu) then return true end
            end
        end
    end

    -- ============================
    -- 5. FAERIE FIRE (anti-stealth on rogues/druids)
    -- ============================
    if try_faerie_fire_anti_stealth(player, target, helpers, menu) then return true end

    -- ============================
    -- 6. STEALTH OPENER (if in prowl)
    -- ============================
    if helpers:has_buff(player, spells.PROWL_BUFF_IDS) then
        -- Pounce (stun opener) - preferred for CC chain setup
        if helpers:is_spell_learned(spells.pounce) and helpers:is_in_melee_range(player, target) then
            if helpers:try_cast(spells.pounce, target, "[PvP] Pounce (opener)") then return true end
        end
        -- Ravage (damage opener) - if Pounce not available
        if helpers:is_spell_learned(spells.ravage) and helpers:is_in_melee_range(player, target) then
            if helpers:try_cast(spells.ravage, target, "[PvP] Ravage (opener)") then return true end
        end
        return false -- Stay in stealth until in range
    end

    -- ============================
    -- 7. CAT FORM BURST ROTATION
    -- ============================
    if form ~= "cat" then
        -- Enter cat for DPS
        if helpers:try_enter_form(player, "cat") then return true end
        return false
    end

    common.ensure_auto_attack(player, target, helpers)

    local energy = helpers:get_energy(player)
    local cp = helpers:get_combo_points(player)

    -- Mangle debuff maintenance
    if common.try_mangle_cat(player, target, helpers, energy) then return true end

    -- Finisher: Ferocious Bite (PvP prefers burst damage over Rip on most targets)
    if cp >= 4 and energy >= 35 then
        -- Rip only on high-armor targets (Warriors, Paladins)
        local ok, target_class = pcall(function() return target:get_class() end)
        local use_rip = false
        if ok and target_class then
            use_rip = (target_class == enums.class_id.WARRIOR or target_class == enums.class_id.PALADIN)
        end

        if use_rip and not helpers:has_debuff(target, spells.RIP_DEBUFF_IDS) then
            if helpers:try_cast(spells.rip, target, "[PvP] Rip (high armor)") then return true end
        else
            if common.try_ferocious_bite(player, target, helpers, menu, cp, energy) then return true end
        end
    end

    -- Builder: Shred (behind) > Mangle
    if cp < 5 then
        if common.try_shred(player, target, helpers, energy) then return true end
        if helpers:is_spell_learned(spells.mangle_cat) and energy >= 45 then
            if helpers:try_cast(spells.mangle_cat, target, "[PvP] Mangle (builder)") then return true end
        end
        if common.try_claw(player, target, helpers, energy) then return true end
    end

    return false
end

-- ============================================================================
-- RESTO PVP
-- ============================================================================

local function execute_resto_pvp(player, helpers, menu)
    local hp = helpers:get_hp_pct(player)
    local form = helpers:get_current_form(player)

    -- ============================
    -- 1. BARKSKIN (usable in any form, even while stunned)
    -- ============================
    local barkskin_hp = helpers:get_menu_value(menu.pvp_barkskin_hp, 40)
    if hp < barkskin_hp then
        if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end
    end

    -- ============================
    -- 2. BEAR FORM when focused by melee at low HP
    -- ============================
    local bear_hp = helpers:get_menu_value(menu.pvp_bear_hp, 30)
    if hp < bear_hp and form ~= "bear" then
        if helpers:try_enter_form(player, "bear") then return true end
    end

    -- ============================
    -- 3. BEAR FORM abilities
    -- ============================
    if form == "bear" then
        local target = helpers:get_target(player)

        -- Bash interrupt on enemy casters
        if target and helpers:is_valid_enemy(target) then
            if helpers:is_target_casting(target) and can_stun(target) then
                if common.try_bash_interrupt(player, target, helpers, menu) then return true end
            end
        end

        -- Frenzied Regeneration
        if hp < 40 then
            if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end
        end

        -- Switch back to caster/tree when safe
        if hp > 70 then
            if helpers:is_spell_learned(spells.tree_of_life) then
                if helpers:try_enter_form(player, "tree") then return true end
            else
                if helpers:try_leave_form(player) then return true end
            end
        end

        return false
    end

    -- ============================
    -- 4. SHIFT to break roots/snares
    -- In TBC, entering a new form breaks roots (leaving alone does not)
    -- ============================
    if helpers:is_rooted(player) then
        if form == "tree" or form == "caster" then
            -- Shift into Cat Form to break root (instant), then back to Tree on next frame
            if helpers:try_enter_form(player, "cat") then return true end
        elseif form == "cat" then
            -- Cat → Bear to break root (entering a new form breaks roots in TBC)
            if helpers:try_enter_form(player, "bear") then return true end
        elseif form == "bear" then
            -- Bear → Cat to break root
            if helpers:try_enter_form(player, "cat") then return true end
        end
    end

    -- ============================
    -- 5. CYCLONE on enemy target
    -- ============================
    local target = helpers:get_target(player)
    if target and helpers:is_valid_enemy(target) then
        -- Cyclone enemy DPS that's focusing our team
        if try_cyclone(player, target, helpers, menu) then return true end

        -- Faerie Fire on rogues/druids
        if try_faerie_fire_anti_stealth(player, target, helpers, menu) then return true end

        -- Entangling Roots on melee attackers
        if helpers:is_in_melee_range(player, target) then
            if try_entangling_roots(player, target, helpers, menu) then return true end
        end
    end

    -- ============================
    -- 6. NATURE'S GRASP (passive root on melee attackers)
    -- ============================
    if try_natures_grasp(player, helpers, menu) then return true end

    -- ============================
    -- 7. HEALING (use standard resto rotation for healing)
    -- ============================
    -- Fall through to PvE resto logic (the main dispatcher handles this)
    -- PvP overlay only adds CC/defensive on top

    return false
end

-- ============================================================================
-- BEAR PVP (stays in bear form, defensive + threat + CC)
-- ============================================================================

local function execute_bear_pvp(player, helpers, menu)
    local target = helpers:get_target(player)
    local hp = helpers:get_hp_pct(player)
    local form = helpers:get_current_form(player)

    -- ============================
    -- 1. BARKSKIN (usable in any form, even while stunned)
    -- ============================
    local barkskin_hp = helpers:get_menu_value(menu.pvp_barkskin_hp, 40)
    if hp < barkskin_hp then
        if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end
    end

    -- ============================
    -- 2. ENTER BEAR FORM (always stay in bear)
    -- ============================
    if form ~= "bear" then
        if helpers:try_enter_form(player, "bear") then return true end
        return false
    end

    local rage = helpers:get_rage(player)

    -- ============================
    -- 3. FRENZIED REGENERATION (emergency heal)
    -- ============================
    if hp < 40 then
        if common.try_frenzied_regeneration(player, helpers, menu, hp) then return true end
    end

    if target and helpers:is_valid_enemy(target) then
        -- ============================
        -- 4. BASH INTERRUPT on enemy casters
        -- ============================
        if helpers:is_target_casting(target) and can_stun(target) then
            if common.try_bash_interrupt(player, target, helpers, menu) then return true end
        end

        -- ============================
        -- 5. FERAL CHARGE on distant casters
        -- ============================
        if common.try_feral_charge_interrupt(player, target, helpers, menu) then return true end

        -- ============================
        -- 6. FAERIE FIRE (anti-stealth on rogues/druids)
        -- ============================
        if try_faerie_fire_anti_stealth(player, target, helpers, menu) then return true end

        common.ensure_auto_attack(player, target, helpers)

        -- ============================
        -- 7. MANGLE BEAR (highest threat)
        -- ============================
        if common.try_mangle_bear(player, target, helpers, menu, rage) then return true end

        -- ============================
        -- 8. DEMORALIZING ROAR (damage reduction)
        -- ============================
        if common.try_demoralizing_roar(player, target, helpers, menu, rage) then return true end

        -- ============================
        -- 9. LACERATE / SWIPE / MAUL
        -- ============================
        if common.try_lacerate(player, target, helpers, menu, rage) then return true end
        if common.try_swipe(player, target, helpers, menu, rage) then return true end
        if common.try_maul(player, target, helpers, menu, rage) then return true end
    end

    -- Enrage for rage generation
    if common.try_enrage(player, helpers, menu, rage) then return true end

    return false
end

-- ============================================================================
-- BALANCE PVP
-- ============================================================================

local function execute_balance_pvp(player, helpers, menu)
    local hp = helpers:get_hp_pct(player)
    local form = helpers:get_current_form(player)

    -- Barkskin
    local barkskin_hp = helpers:get_menu_value(menu.pvp_barkskin_hp, 40)
    if hp < barkskin_hp then
        if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end
    end

    -- Bear form at very low HP
    local bear_hp = helpers:get_menu_value(menu.pvp_bear_hp, 30)
    if hp < bear_hp and form ~= "bear" then
        if helpers:try_enter_form(player, "bear") then return true end
    end

    -- Nature's Grasp
    if try_natures_grasp(player, helpers, menu) then return true end

    local target = helpers:get_target(player)
    if target and helpers:is_valid_enemy(target) then
        -- Cyclone
        if try_cyclone(player, target, helpers, menu) then return true end

        -- Faerie Fire anti-stealth
        if try_faerie_fire_anti_stealth(player, target, helpers, menu) then return true end

        -- Entangling Roots
        if helpers:is_in_range(player, target, 15) then
            if try_entangling_roots(player, target, helpers, menu) then return true end
        end
    end

    -- Fall through to standard balance rotation
    return false
end

-- ============================================================================
-- MAIN PVP DISPATCHER
-- ============================================================================

function pvp:execute(player, helpers, menu, spec)
    if not player then return false end

    -- spec: 1=Resto, 2=Cat, 3=Bear, 4=Balance
    if spec == 2 then
        return execute_feral_pvp(player, helpers, menu)
    elseif spec == 1 then
        return execute_resto_pvp(player, helpers, menu)
    elseif spec == 3 then
        return execute_bear_pvp(player, helpers, menu)
    elseif spec == 4 then
        return execute_balance_pvp(player, helpers, menu)
    end

    return false
end

return pvp
