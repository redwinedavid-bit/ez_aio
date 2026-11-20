local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Druid Helpers - Group State Tracking (Classic ERA)
-- Party/raid member tracking, tank detection, heal target selection, dispels
-- ============================================================================

local group = {}

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

-- ============================================================================
-- GROUP STATE
-- ============================================================================

local GroupState = {
    members = {},
    lowest_ally = nil,
    lowest_hp = 100,
    tank = nil,
    tank_hp = 100,
    below_aoe_count = 0,
    last_member_refresh = 0,
    last_dispel_refresh = 0,
    dispel_poison = {},
    dispel_curse = {},
    member_count = 0,
    is_raid = false,
    allies_below = {}, -- cached: allies below various thresholds
}

local MEMBER_REFRESH_INTERVAL_MS = 1000
local DISPEL_CHECK_INTERVAL_MS = 500
local AOE_HEAL_THRESHOLD = 60 -- HP% threshold for counting AoE heal targets

-- ============================================================================
-- REGISTRATION
-- ============================================================================

function group.register(helpers)

    -- ========================================================================
    -- PRIVATE: Get group members
    -- ========================================================================

    local function get_group_members(player)
        -- Try range-limited party first
        local ok_range, party_range = pcall(function()
            return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
        end)
        if ok_range and party_range and #party_range > 0 then return party_range end

        -- Fallback: all party members
        local ok_party, party = pcall(function() return performance:get_unit_list(player, "get_party_members") end)
        if ok_party and party and #party > 0 then return party end

        -- Solo: just the player
        return { player }
    end

    -- ========================================================================
    -- REFRESH GROUP STATE
    -- ========================================================================

    function helpers:refresh_group_state(player)
        if not player then return end

        local now = core.time()

        -- Throttled member refresh
        if (now - GroupState.last_member_refresh) >= MEMBER_REFRESH_INTERVAL_MS or #GroupState.members == 0 then
            GroupState.members = get_group_members(player)
            GroupState.last_member_refresh = now
            GroupState.member_count = #GroupState.members
            GroupState.is_raid = GroupState.member_count > 5
        end

        -- Reset state
        GroupState.lowest_ally = player
        GroupState.lowest_hp = player:get_health_percentage() or 100
        GroupState.tank = player
        GroupState.tank_hp = GroupState.lowest_hp
        GroupState.below_aoe_count = 0
        GroupState.allies_below = {}

        local best_tank_priority = 100 -- Lower = better tank candidate

        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if ally and ally:is_alive() then
                local hp = ally:get_health_percentage() or 100

                -- Lowest HP detection
                if hp < GroupState.lowest_hp then
                    GroupState.lowest_hp = hp
                    GroupState.lowest_ally = ally
                end

                -- AoE heal counting
                if hp < AOE_HEAL_THRESHOLD then
                    GroupState.below_aoe_count = GroupState.below_aoe_count + 1
                end

                -- Tank detection (Warrior > Druid > Paladin)
                local ok_class, class = pcall(function() return ally:get_class() end)
                if ok_class and class then
                    local priority = 100
                    if class == enums.class_id.WARRIOR then priority = 1
                    elseif class == enums.class_id.DRUID then priority = 2
                    elseif class == enums.class_id.PALADIN then priority = 3
                    end

                    if priority < best_tank_priority then
                        best_tank_priority = priority
                        GroupState.tank = ally
                        GroupState.tank_hp = hp
                    end
                end
            end
        end

        -- Throttled dispel detection
        if (now - GroupState.last_dispel_refresh) >= DISPEL_CHECK_INTERVAL_MS then
            GroupState.last_dispel_refresh = now
            GroupState.dispel_poison = {}
            GroupState.dispel_curse = {}

            for _, ally in __object_safety.live_ipairs(GroupState.members) do
                if ally and ally:is_alive() and ally.get_debuffs then
                    local ok, debuffs = pcall(function() return ally:get_debuffs() end)
                    if ok and type(debuffs) == "table" then
                        for _, debuff in ipairs(debuffs) do
                            if debuff.type == enums.buff_type.POISON then
                                table.insert(GroupState.dispel_poison, ally)
                                break
                            end
                        end
                        for _, debuff in ipairs(debuffs) do
                            if debuff.type == enums.buff_type.CURSE then
                                table.insert(GroupState.dispel_curse, ally)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- ACCESSORS
    -- ========================================================================

    function helpers:get_lowest_ally()
        return GroupState.lowest_ally, GroupState.lowest_hp
    end

    function helpers:get_tank()
        return GroupState.tank, GroupState.tank_hp
    end

    function helpers:get_tank_hp()
        return GroupState.tank_hp
    end

    function helpers:get_dispel_poison_targets()
        return GroupState.dispel_poison
    end

    function helpers:get_dispel_curse_targets()
        return GroupState.dispel_curse
    end

    function helpers:get_aoe_heal_count()
        return GroupState.below_aoe_count
    end

    function helpers:get_group_members_list()
        return GroupState.members
    end

    function helpers:get_member_count()
        return GroupState.member_count
    end

    function helpers:is_in_raid()
        return GroupState.is_raid
    end

    --- Get count of allies below a specific HP threshold
    --- @param threshold number HP percentage threshold
    --- @return number count
    function helpers:get_allies_below_hp(threshold)
        local count = 0
        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if ally and ally:is_alive() then
                local hp = ally:get_health_percentage() or 100
                if hp < threshold then
                    count = count + 1
                end
            end
        end
        return count
    end

    --- Get the most injured ally that doesn't have a specific buff
    --- Useful for HoT blanket healing in raids
    --- @param buff_key string Key from spell_data.buff_ids
    --- @param threshold number Only consider allies below this HP%
    --- @return game_object|nil ally, number hp
    function helpers:get_injured_without_buff(buff_key, threshold)
        local best_ally = nil
        local best_hp = 100

        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if ally and ally:is_alive() then
                local hp = ally:get_health_percentage() or 100
                if hp < threshold and hp < best_hp then
                    if not helpers:has_buff(ally, buff_key) then
                        best_ally = ally
                        best_hp = hp
                    end
                end
            end
        end

        return best_ally, best_hp
    end

    --- Get all party members that need Mark of the Wild
    --- @return table List of allies without MotW buff
    function helpers:get_members_without_motw()
        local need_buff = {}
        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if ally and ally:is_alive() then
                if not helpers:has_buff(ally, "mark_of_the_wild") then
                    table.insert(need_buff, ally)
                end
            end
        end
        return need_buff
    end

    --- Get the tank or first party member without Thorns
    --- @return game_object|nil
    function helpers:get_member_without_thorns()
        -- Priority: tank first
        local tank = GroupState.tank
        if tank and tank:is_alive() and not helpers:has_buff(tank, "thorns") then
            return tank
        end

        -- Then self
        -- (Self is handled via buff management in common.lua)
        return nil
    end

end -- group.register

return group
