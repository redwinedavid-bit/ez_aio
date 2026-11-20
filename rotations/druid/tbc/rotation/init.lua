-- ============================================================================
-- Druid Rotation Dispatcher - TBC (2.4.3)
-- Spec-aware + level-aware dispatch to appropriate rotation module
-- ============================================================================

local rotation = {}

local spells = require("rotations/druid/tbc/spells")
local helpers = require("rotations/druid/tbc/helpers/init")
local consumables = require("rotations/druid/tbc/helpers/consumables")
local racials = require("rotations/druid/tbc/helpers/racials")
local levels_cat = require("rotations/druid/tbc/rotation/levels_cat")
local levels_bear = require("rotations/druid/tbc/rotation/levels_bear")
local levels_caster = require("rotations/druid/tbc/rotation/levels_caster")
local powershift = require("rotations/druid/tbc/rotation/powershift")
local common = require("rotations/druid/tbc/rotation/common")

-- PvP module (loaded lazily to avoid circular deps)
local pvp = nil
local function get_pvp()
    if pvp == nil then
        local ok, mod = pcall(function()
            return require("rotations/druid/tbc/rotation/pvp")
        end)
        if ok and mod then
            pvp = mod
        else
            pvp = false -- Mark as failed so we don't retry
        end
    end
    return pvp
end

-- ============================================================================
-- STATE
-- ============================================================================

local _initialized = false
local _last_spec = -1

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function ensure_init(menu)
    if _initialized then return end
    helpers:init(menu)
    _initialized = true
end

-- ============================================================================
-- MAIN EXECUTION
-- ============================================================================

function rotation:execute(player, menu, tick_tracker)
    if not player then return false end

    ensure_init(menu)

    -- Skip if casting or channeling
    if helpers:is_casting(player) then return false end

    -- Skip if form GCD is active (just shifted forms)
    if helpers:is_form_gcd_active() then return false end

    local spec = helpers:get_menu_value(menu.spec_selector, 1)

    -- Reset powershift state if spec changed
    if spec ~= _last_spec then
        powershift:reset()
        _last_spec = spec
    end

    -- ============================
    -- PVP OVERLAY (highest priority, runs before any PvE logic)
    -- ============================
    if helpers:is_pvp_mode() then
        local pvp_mod = get_pvp()
        if pvp_mod and pvp_mod.execute then
            if pvp_mod:execute(player, helpers, menu, spec) then return true end
        end
    end

    -- ============================
    -- CONSUMABLES (all specs, emergency HP/mana recovery)
    -- Individual consumable functions check their own thresholds
    -- ============================
    if helpers:is_in_combat(player) then
        if consumables:try_use_consumables(player, helpers, menu) then return true end
    end

    -- ============================
    -- RACIALS (burst DPS cooldowns when toggle is active)
    -- ============================
    if helpers:is_cooldowns_active() and helpers:is_in_combat(player) then
        if racials:try_use_racial(player, helpers, true) then return true end
    end

    -- ============================
    -- SPEC DISPATCH
    -- ============================

    if spec == 1 then
        -- ========================
        -- RESTORATION (Healing)
        -- No target needed, heals group
        -- ========================
        return levels_caster.execute_resto(player, helpers, menu)

    elseif spec == 2 then
        -- ========================
        -- FERAL CAT (DPS)
        -- ========================
        local target = helpers:get_target(player)
        if not target or not helpers:is_valid_enemy(target) then return false end

        local energy = helpers:get_energy(player)
        local cp = helpers:get_combo_points(player)
        local mana_pct = helpers:get_mana_pct(player)

        -- Powershift check BEFORE level dispatch
        -- Only at level 20+ (when cat form is available)
        local level = helpers:get_level(player)
        if level >= 20 then
            if powershift:should_powershift(player, energy, mana_pct, menu, helpers, tick_tracker) then
                return powershift:execute(player, helpers)
            end
            -- Continue powershift sequence if in progress
            if powershift:is_active() then
                return powershift:execute(player, helpers)
            end
        end

        return levels_cat.execute(player, target, helpers, menu, energy, cp)

    elseif spec == 3 then
        -- ========================
        -- FERAL BEAR (Tank)
        -- ========================
        local target = helpers:get_target(player)
        if not target or not helpers:is_valid_enemy(target) then return false end

        local rage = helpers:get_rage(player)
        return levels_bear.execute(player, target, helpers, menu, rage)

    elseif spec == 4 then
        -- ========================
        -- BALANCE (Moonkin DPS)
        -- ========================
        local target = helpers:get_target(player)
        if not target or not helpers:is_valid_enemy(target) then return false end

        return levels_caster.execute_balance(player, target, helpers, menu)
    end

    return false
end

return rotation
