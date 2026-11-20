-- ============================================================================
-- Druid Helpers - Consumables (Classic ERA)
-- Health potions, mana potions, healthstones, bandages
-- ============================================================================

local consumables = {}

local spell_data = require("rotations/druid/era/spell_data")

-- Cooldown tracking
local last_potion_use = 0
local POTION_COOLDOWN_MS = 120000 -- 2 min shared cooldown
local last_healthstone_use = 0
local HEALTHSTONE_COOLDOWN_MS = 120000

-- ============================================================================
-- REGISTRATION
-- ============================================================================

function consumables.register(helpers)

    --- Check if player has an item by scanning consumable lists
    local function has_item(item_ids)
        for _, item_id in ipairs(item_ids) do
            local ok, count = pcall(function()
                return core.inventory.get_item_count(item_id)
            end)
            if ok and count and count > 0 then
                return true, item_id
            end
        end
        return false, nil
    end

    --- Use an item by ID
    local function use_item(item_id)
        local ok, result = pcall(function()
            return core.inventory.use_item(item_id)
        end)
        return ok and result
    end

    --- Try to use a health potion when HP is low
    --- @param player game_object
    --- @param hp_threshold number HP% below which to use potion (default 30)
    --- @return boolean
    function helpers:try_use_health_potion(player, hp_threshold)
        if not player then return false end
        hp_threshold = hp_threshold or 30

        local hp = self:get_player_hp(player)
        if hp >= hp_threshold then return false end

        local now = core.time()
        if (now - last_potion_use) < POTION_COOLDOWN_MS then return false end

        local has, item_id = has_item(spell_data.consumables.health_potions.item_ids)
        if has and item_id then
            if use_item(item_id) then
                last_potion_use = now
                helpers:log_checkpoint("health_pot", 5.0, "[Druid][Consumable] Used Health Potion at HP=" .. math.floor(hp))
                return true
            end
        end

        return false
    end

    --- Try to use a mana potion when mana is low
    --- @param player game_object
    --- @param mana_threshold number Mana% below which to use potion (default 20)
    --- @return boolean
    function helpers:try_use_mana_potion(player, mana_threshold)
        if not player then return false end
        mana_threshold = mana_threshold or 20

        local mana_pct = self:get_mana_pct(player)
        if mana_pct >= mana_threshold then return false end

        local now = core.time()
        if (now - last_potion_use) < POTION_COOLDOWN_MS then return false end

        local has, item_id = has_item(spell_data.consumables.mana_potions.item_ids)
        if has and item_id then
            if use_item(item_id) then
                last_potion_use = now
                helpers:log_checkpoint("mana_pot", 5.0, "[Druid][Consumable] Used Mana Potion at Mana=" .. math.floor(mana_pct))
                return true
            end
        end

        return false
    end

    --- Try to use a healthstone when HP is low
    --- @param player game_object
    --- @param hp_threshold number HP% below which to use healthstone (default 25)
    --- @return boolean
    function helpers:try_use_healthstone(player, hp_threshold)
        if not player then return false end
        hp_threshold = hp_threshold or 25

        local hp = self:get_player_hp(player)
        if hp >= hp_threshold then return false end

        local now = core.time()
        if (now - last_healthstone_use) < HEALTHSTONE_COOLDOWN_MS then return false end

        local has, item_id = has_item(spell_data.consumables.healthstone.item_ids)
        if has and item_id then
            if use_item(item_id) then
                last_healthstone_use = now
                helpers:log_checkpoint("healthstone", 5.0, "[Druid][Consumable] Used Healthstone at HP=" .. math.floor(hp))
                return true
            end
        end

        return false
    end

end -- consumables.register

return consumables
