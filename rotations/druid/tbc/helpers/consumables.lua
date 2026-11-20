-- ============================================================================
-- Druid Consumables Module - TBC (2.4.3)
-- Health potions, mana potions, healthstones, trinkets
-- ============================================================================

local consumables = {}

local spells = require("rotations/druid/tbc/spells")

-- ============================================================================
-- STATE
-- ============================================================================

local _last_potion_time = 0
local _last_healthstone_time = 0
local POTION_COOLDOWN_MS = 120000  -- 2 min shared potion cooldown
local HEALTHSTONE_COOLDOWN_MS = 120000

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

local function try_use_item(item_id, player)
    if not item_id or not player then return false end
    local ok, result = pcall(function()
        return core.use_item(item_id, player)
    end)
    return ok and result == true
end

local function has_item(item_id)
    if not item_id then return false end
    local ok, result = pcall(function()
        return core.has_item(item_id)
    end)
    return ok and result == true
end

-- ============================================================================
-- HEALTH POTIONS
-- ============================================================================

function consumables:try_use_health_potion(player, hp_pct, threshold, helpers)
    if not player or hp_pct > threshold then return false end

    local now = core.game_time()
    if (now - _last_potion_time) < POTION_COOLDOWN_MS then return false end

    -- Must be in combat
    if not helpers:is_in_combat(player) then return false end

    -- Try potions from strongest to weakest
    local pots = spells.CONSUMABLES.health_potions
    local level = helpers:get_level(player)

    for _, pot in ipairs(pots) do
        if level >= pot.min_level and has_item(pot.item_id) then
            if try_use_item(pot.item_id, player) then
                _last_potion_time = now
                helpers:log_checkpoint("consumable.hp_pot", 1.0, "[Druid][Consumable] Used " .. pot.name)
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- MANA POTIONS
-- ============================================================================

function consumables:try_use_mana_potion(player, mana_pct, threshold, helpers)
    if not player or mana_pct > threshold then return false end

    local now = core.game_time()
    if (now - _last_potion_time) < POTION_COOLDOWN_MS then return false end

    -- Must be in combat
    if not helpers:is_in_combat(player) then return false end

    -- Only use mana pots in caster/healer forms
    local form = helpers:get_current_form(player)
    if form == "cat" or form == "bear" then return false end

    local pots = spells.CONSUMABLES.mana_potions
    local level = helpers:get_level(player)

    for _, pot in ipairs(pots) do
        if level >= (pot.min_level or 1) and has_item(pot.item_id) then
            if try_use_item(pot.item_id, player) then
                _last_potion_time = now
                helpers:log_checkpoint("consumable.mp_pot", 1.0, "[Druid][Consumable] Used " .. pot.name)
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- HEALTHSTONES
-- ============================================================================

function consumables:try_use_healthstone(player, hp_pct, threshold, helpers)
    if not player or hp_pct > threshold then return false end

    local now = core.game_time()
    if (now - _last_healthstone_time) < HEALTHSTONE_COOLDOWN_MS then return false end

    -- Must be in combat
    if not helpers:is_in_combat(player) then return false end

    local stones = spells.CONSUMABLES.healthstones
    for _, stone in ipairs(stones) do
        if has_item(stone.item_id) then
            if try_use_item(stone.item_id, player) then
                _last_healthstone_time = now
                helpers:log_checkpoint("consumable.hs", 1.0, "[Druid][Consumable] Used " .. stone.name)
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

function consumables:try_use_consumables(player, helpers, menu)
    if not player or not menu then return false end

    local hp_pct = helpers:get_hp_pct(player)

    -- Health Potion
    if helpers:get_menu_state(menu.use_health_potions, true) then
        local hp_threshold = helpers:get_menu_value(menu.health_potion_hp, 30)
        if self:try_use_health_potion(player, hp_pct, hp_threshold, helpers) then
            return true
        end
    end

    -- Healthstone
    if helpers:get_menu_state(menu.use_healthstone, true) then
        local hs_threshold = helpers:get_menu_value(menu.healthstone_hp, 25)
        if self:try_use_healthstone(player, hp_pct, hs_threshold, helpers) then
            return true
        end
    end

    -- Mana Potion (only for caster specs)
    if helpers:get_menu_state(menu.use_mana_potions, true) then
        local mana_pct = helpers:get_mana_pct(player)
        local mp_threshold = helpers:get_menu_value(menu.mana_potion_pct, 20)
        if self:try_use_mana_potion(player, mana_pct, mp_threshold, helpers) then
            return true
        end
    end

    return false
end

return consumables
