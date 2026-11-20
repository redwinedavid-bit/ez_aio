-- ============================================================================
-- Shared Auto Consumables Module
-- Handles automatic usage of food and drink based on configurable thresholds.
-- ============================================================================

local auto_consumables = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type rotation_pause
local rotation_pause = require("shared/rotation_pause")

-- ============================================================================
-- COMMON ITEM IDS (TBC & CLASSIC FALLBACKS)
-- ============================================================================

-- Drinks (Mana recovery)
local DRINK_IDS = {
    -- TBC (Level 65/70)
    27860, -- Purified Draenic Water
    28355, -- Filtered Draenic Water
    32453, -- Star's Tears
    21356, -- Conjured Glacier Water (Mage)
    22018, -- Conjured Mana Strudel (Mage - both food/drink)
    -- Classic (Level 55/60)
    8079,  -- Conjured Crystal Water (Mage)
    1645,  -- Moonberry Juice
    1708,  -- Sweet Nectar
    8077,  -- Conjured Fresh Water
    8078,  -- Conjured Purified Water
    -- Lower Levels
    1179,  -- Ice Cold Milk
    1205,  -- Melon Juice
    159,   -- Refreshing Spring Water
    1644,  -- Morning Glory Dew
}

-- Foods (Health recovery)
local FOOD_IDS = {
    -- TBC (Level 65/70)
    27663, -- Roasted Clefthoof
    27650, -- Talbuk Steak
    27854, -- Smoked Talbuk Venison
    27855, -- Sunspring Carp
    27856, -- Mag'har Grainbread
    27857, -- Garadar Cheddar
    27858, -- Nagrand Cherry
    27664, -- Poached Bluefish
    27657, -- Blackened Basilisk
    27659, -- Warp Burger
    27667, -- Blackened Basilisk (Wait, alternate ID?)
    22018, -- Conjured Mana Strudel (Mage - both food/drink)
    -- Classic (Level 55/60)
    21023, -- Dirge's Kickin' Chimaerok Chops
    11542, -- Monster Omelet
    1177,  -- Roasted Quail
    21235, -- Smoked Sagefish Delight (Mana/HP)
    -- Classic (Lower Levels)
    4599,  -- Cured Ham Steak
    3771,  -- Wild Hog Shank
    3770,  -- Mutton Chop
    2287,  -- Haunch of Meat
    117,   -- Tough Jerky
    1082,  -- Redridge Goulash
    2687,  -- Raccary Pickled Herring
}

local drink_item = izi.item(DRINK_IDS)
local food_item = izi.item(FOOD_IDS)

-- ============================================================================
-- STATE / THROTTLES
-- ============================================================================

local last_usage_ms = 0
local USAGE_THROTTLE_MS = 2500

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Main update function for auto consumables.
---@param player game_object
---@param menu table Requires .auto_food_pct and optionally .auto_drink_pct (with .get sliders) and .auto_consumables_enabled (with .get_state)
---@return boolean acted
function auto_consumables:on_update(player, menu)
    if not player or not menu then
        return false
    end

    -- Check if enabled
    if menu.auto_consumables_enabled and menu.auto_consumables_enabled.get_state then
        if not menu.auto_consumables_enabled:get_state() then
            return false
        end
    end

    -- Basic status checks with robust method names
    local in_combat = false
    local pcall_combat, combat_val = pcall(function() return player:affecting_combat() end)
    if pcall_combat then in_combat = combat_val end

    local is_moving = false
    local pcall_moving, moving_val = pcall(function() return not player:is_standing_still() end)
    if pcall_moving then is_moving = moving_val end

    local is_mounted = false
    local pcall_mounted, mount_val = pcall(function() return player:is_mounted() end)
    if pcall_mounted then is_mounted = mount_val end

    if in_combat or is_moving or is_mounted then
        return false
    end

    -- Don't spam usage
    local now = core.game_time()
    if (now - last_usage_ms) < USAGE_THROTTLE_MS then
        return false
    end

    -- Check if already eating or drinking
    if rotation_pause.is_eating_or_drinking(player) then
        return false
    end

    -- Check DRINK (Mana)
    if menu.auto_drink_pct and menu.auto_drink_pct.get then
        local threshold = menu.auto_drink_pct:get() or 0
        local mana_pct = player:mana_pct() or 100
        if threshold > 0 and mana_pct <= threshold then
            if drink_item:in_inventory() then
                last_usage_ms = now
                core.log("[AutoConsumables] Using Drink (Mana="..tostring(math.floor(mana_pct)).."% Threshold="..tostring(threshold).."%)")
                return drink_item:use_self_safe("Drinking (Auto)")
            end
        end
    end

    -- Check FOOD (Health)
    if menu.auto_food_pct and menu.auto_food_pct.get then
        local threshold = menu.auto_food_pct:get() or 0
        local hp_pct = player:get_health_percentage() or 100
        if threshold > 0 and hp_pct <= threshold then
            if food_item:in_inventory() then
                last_usage_ms = now
                core.log("[AutoConsumables] Using Food (HP="..tostring(math.floor(hp_pct)).."% Threshold="..tostring(threshold).."%)")
                return food_item:use_self_safe("Eating (Auto)")
            end
        end
    end

    return false
end

return auto_consumables
