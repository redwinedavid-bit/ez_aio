local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Druid Caster Level-Based Rotation - TBC (2.4.3)
-- Handles: Balance (Moonkin) DPS + Restoration Healing
-- ============================================================================

local levels_caster = {}

local spells = require("rotations/druid/tbc/spells")
local cc = require("rotations/druid/tbc/rotation/cc")
local common = require("rotations/druid/tbc/rotation/common")

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

-- ============================================================================
-- GROUP STATE (moved from rotation_logic.lua)
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
}

local MEMBER_REFRESH_INTERVAL_MS = 1000
local DISPEL_CHECK_INTERVAL_MS = 500

local function get_group_members(player)
    local ok_range, party_range = pcall(function()
        return player:get_party_members_in_range(40, true)
    end)
    if ok_range and party_range and #party_range > 0 then return party_range end

    local ok_party, party = pcall(function() return player:get_party_members() end)
    if ok_party and party and #party > 0 then return party end

    return { player }
end

function levels_caster.refresh_group_state(player, menu, helpers)
    local now = core.game_time()

    -- Throttled Member Refresh
    if (now - GroupState.last_member_refresh) >= MEMBER_REFRESH_INTERVAL_MS or #GroupState.members == 0 then
        GroupState.members = get_group_members(player)
        GroupState.last_member_refresh = now
    end

    GroupState.lowest_ally = player
    GroupState.lowest_hp = helpers:get_hp_pct(player)
    GroupState.tank = player
    GroupState.tank_hp = GroupState.lowest_hp
    GroupState.below_aoe_count = 0

    local best_tank_priority = 100

    for _, ally in ipairs(GroupState.members) do
        local ok, is_alive = pcall(function() return ally:is_alive() end)
        if ok and is_alive then
            local hp = helpers:get_hp_pct(ally)

            if hp < GroupState.lowest_hp then
                GroupState.lowest_hp = hp
                GroupState.lowest_ally = ally
            end

            -- Count allies below AoE heal threshold
            if hp < 40 then
                GroupState.below_aoe_count = GroupState.below_aoe_count + 1
            end

            -- Tank Detection by class
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

    -- Throttled Dispel Detection
    if (now - GroupState.last_dispel_refresh) >= DISPEL_CHECK_INTERVAL_MS then
        GroupState.last_dispel_refresh = now
        GroupState.dispel_poison = {}
        GroupState.dispel_curse = {}

        for _, ally in ipairs(GroupState.members) do
            local ok, is_alive = pcall(function() return ally:is_alive() end)
            if ok and is_alive and ally.get_debuffs then
                local ok_d, debuffs = pcall(function() return ally:get_debuffs() end)
                if ok_d and type(debuffs) == "table" then
                    for _, debuff in ipairs(debuffs) do
                        if debuff.type == enums.buff_type.POISON then
                            table.insert(GroupState.dispel_poison, ally)
                        end
                        if debuff.type == enums.buff_type.CURSE then
                            table.insert(GroupState.dispel_curse, ally)
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- RESTORATION HEALING
-- ============================================================================

--- Lifebloom 3-stack management on tank
local function try_lifebloom_tank(player, helpers, menu)
    if not helpers:is_spell_learned(spells.lifebloom) then return false end

    local tank = GroupState.tank
    if not tank then return false end

    local tank_hp = GroupState.tank_hp
    local lb_threshold = helpers:get_menu_value(menu.lifebloom_hp, 95)
    if tank_hp > lb_threshold then return false end

    local target_stacks = helpers:get_menu_value(menu.resto_lifebloom_stacks, 3)
    local stacks = helpers:get_buff_stacks(tank, spells.LIFEBLOOM_BUFF_ID)
    local remaining = helpers:get_buff_remaining_ms(tank, spells.LIFEBLOOM_BUFF_ID)

    -- Build stacks
    if stacks < target_stacks then
        return helpers:try_cast(spells.lifebloom, tank, "[Resto] Lifebloom (" .. stacks .. " → " .. (stacks + 1) .. " stacks)")
    end

    -- Refresh before bloom (2s threshold for safety)
    if stacks >= target_stacks and remaining > 0 and remaining < 2000 then
        return helpers:try_cast(spells.lifebloom, tank, "[Resto] Lifebloom (refresh at " .. math.floor(remaining / 1000) .. "s)")
    end

    return false
end

--- Lifebloom on lowest ally (not tank)
local function try_lifebloom_lowest(player, helpers, menu)
    if not helpers:is_spell_learned(spells.lifebloom) then return false end

    local ally = GroupState.lowest_ally
    if not ally then return false end
    -- Skip if this is the tank (handled above)
    if (__object_safety.same(ally,GroupState.tank)) then return false end

    local hp = GroupState.lowest_hp
    local threshold = helpers:get_menu_value(menu.lifebloom_hp, 95)
    if hp > threshold then return false end

    -- Only apply one stack on non-tank targets
    if helpers:has_buff(ally, {spells.LIFEBLOOM_BUFF_ID}) then return false end

    return helpers:try_cast(spells.lifebloom, ally, "[Resto] Lifebloom (lowest)")
end

--- Execute Restoration rotation
function levels_caster.execute_resto(player, helpers, menu)
    if not helpers:get_menu_state(menu.enable_healing, true) then return false end

    levels_caster.refresh_group_state(player, menu, helpers)

    local lowest_ally = GroupState.lowest_ally
    local lowest_hp = GroupState.lowest_hp
    local mana_pct = helpers:get_mana_pct(player)

    -- ============================
    -- 0. TREE OF LIFE FORM (if learned)
    -- ============================
    if helpers:is_spell_learned(spells.tree_of_life) then
        if not helpers:is_in_form(player, "tree") then
            if helpers:try_enter_form(player, "tree") then return true end
        end
    end

    -- ============================
    -- 1. NATURE'S SWIFTNESS + HEALING TOUCH (emergency)
    -- ============================
    if helpers:get_menu_state(menu.resto_use_natures_swiftness, true) then
        if common.try_ns_healing_touch(player, helpers, menu, lowest_ally, lowest_hp) then return true end
    end

    -- ============================
    -- 2. SWIFTMEND (emergency instant heal, consumes HoT)
    -- ============================
    if lowest_hp < helpers:get_menu_value(menu.swiftmend_hp, 35) then
        if helpers:is_spell_learned(spells.swiftmend) and helpers:is_spell_ready(spells.swiftmend) then
            if helpers:has_buff(lowest_ally, spells.REJUV_BUFF_IDS) or helpers:has_buff(lowest_ally, spells.REGROWTH_BUFF_IDS) then
                if helpers:try_cast(spells.swiftmend, lowest_ally, "[Resto] Swiftmend") then return true end
            end
        end
    end

    -- ============================
    -- 3. TRANQUILITY (party-wide emergency heal)
    -- ============================
    local tranq_count = helpers:get_menu_value(menu.resto_tranquility_count, 3)
    if GroupState.below_aoe_count >= tranq_count then
        if helpers:is_spell_learned(spells.tranquility) and helpers:is_spell_ready(spells.tranquility) then
            if helpers:try_cast(spells.tranquility, player, "[Resto] Tranquility (" .. GroupState.below_aoe_count .. " allies low)") then return true end
        end
    end

    -- ============================
    -- 4. DISPELS (when nobody is critically low)
    -- ============================
    if lowest_hp > 40 then
        if #GroupState.dispel_poison > 0 and helpers:is_spell_learned(spells.abolish_poison) then
            if helpers:try_cast(spells.abolish_poison, GroupState.dispel_poison[1], "[Resto] Abolish Poison") then return true end
        end
        if #GroupState.dispel_curse > 0 and helpers:is_spell_learned(spells.remove_curse) then
            if helpers:try_cast(spells.remove_curse, GroupState.dispel_curse[1], "[Resto] Remove Curse") then return true end
        end
    end

    -- ============================
    -- 5. LIFEBLOOM (3-stack on tank, 1-stack on others)
    -- ============================
    if try_lifebloom_tank(player, helpers, menu) then return true end
    if try_lifebloom_lowest(player, helpers, menu) then return true end

    -- ============================
    -- 6. REJUVENATION (pre-HoT on damaged allies)
    -- ============================
    if lowest_hp < helpers:get_menu_value(menu.rejuvenation_hp, 85) then
        if not helpers:has_buff(lowest_ally, spells.REJUV_BUFF_IDS) then
            if helpers:try_cast(spells.rejuvenation, lowest_ally, "[Resto] Rejuvenation") then return true end
        end
    end

    -- ============================
    -- 7. REGROWTH (spot heal + HoT)
    -- ============================
    if lowest_hp < helpers:get_menu_value(menu.regrowth_hp, 60) then
        if not helpers:has_buff(lowest_ally, spells.REGROWTH_BUFF_IDS) then
            if not helpers:is_moving(player) then
                if helpers:try_cast(spells.regrowth, lowest_ally, "[Resto] Regrowth") then return true end
            end
        end
    end

    -- ============================
    -- 8. HEALING TOUCH (filler)
    -- ============================
    if lowest_hp < helpers:get_menu_value(menu.healing_touch_hp, 50) then
        if not helpers:is_moving(player) then
            if helpers:try_cast(spells.healing_touch, lowest_ally, "[Resto] Healing Touch") then return true end
        end
    end

    -- ============================
    -- 9. INNERVATE (mana recovery)
    -- ============================
    if common.try_innervate(player, helpers, menu, mana_pct, "resto_innervate_mana") then return true end

    return false
end

-- ============================================================================
-- BALANCE (MOONKIN) DPS
-- ============================================================================

--- Balance pre-20 (no Moonkin Form, basic caster)
local function balance_early(player, target, helpers, menu)
    if cc.should_pause_for_cc(target) then return true end

    -- Moonfire DoT
    if common.try_moonfire(player, target, helpers) then return true end

    -- Wrath filler
    if not helpers:is_moving(player) then
        if helpers:try_cast(spells.wrath, target, "[Balance] Wrath") then return true end
    end

    return false
end

--- Balance Level 50-70: Full rotation
local function balance_full(player, target, helpers, menu)
    if cc.should_pause_for_cc(target) then return true end

    local hp = helpers:get_hp_pct(player)
    local target_hp = helpers:get_hp_pct(target)
    local mana_pct = helpers:get_mana_pct(player)

    -- Emergency Barkskin
    if common.try_emergency_barkskin(player, helpers, menu, hp) then return true end

    -- ============================
    -- MOONKIN FORM (if talent learned)
    -- ============================
    if helpers:is_spell_learned(spells.moonkin_form) then
        if not helpers:is_in_form(player, "moonkin") then
            if helpers:try_enter_form(player, "moonkin") then return true end
        end
    end

    -- ============================
    -- AUTO ATTACK LOW HP (skip spells when target is about to die)
    -- ============================
    local auto_attack_hp = helpers:get_menu_value(menu.balance_auto_attack_hp, 10)
    if target_hp <= auto_attack_hp and auto_attack_hp > 0 then
        helpers:ensure_auto_attack(player, target)
        return true -- Auto-attack only, skip spells
    end

    -- ============================
    -- INNERVATE (mana recovery)
    -- ============================
    if common.try_innervate(player, helpers, menu, mana_pct, "balance_innervate_mana") then return true end

    -- Stop casting if mana is too low
    local min_mana = helpers:get_menu_value(menu.balance_min_mana, 15)
    if mana_pct < min_mana then return false end

    -- ============================
    -- BARKSKIN + HURRICANE (AoE, 3+ enemies)
    -- ============================
    if helpers:get_menu_state(menu.balance_use_hurricane, true) then
        local enemy_count = helpers:get_enemy_count(player, 10)
        local hurricane_count = helpers:get_menu_value(menu.balance_hurricane_count, 3)
        if enemy_count >= hurricane_count and helpers:is_spell_learned(spells.hurricane) then
            -- Pre-cast Barkskin for pushback immunity
            if helpers:is_spell_learned(spells.barkskin) and helpers:is_spell_ready(spells.barkskin) then
                if not helpers:has_buff(player, spells.BARKSKIN_BUFF_IDS) then
                    if helpers:try_cast(spells.barkskin, player, "[Balance] Barkskin (pre-Hurricane)") then return true end
                end
            end
            if not helpers:is_moving(player) then
                if helpers:try_cast(spells.hurricane, target, "[Balance] Hurricane (" .. enemy_count .. " enemies)") then return true end
            end
        end
    end

    -- ============================
    -- FORCE OF NATURE (treants, cooldown)
    -- ============================
    if helpers:get_menu_state(menu.balance_use_force_of_nature, true) then
        if helpers:is_cooldowns_active() and helpers:is_spell_learned(spells.force_of_nature) then
            if helpers:is_spell_ready(spells.force_of_nature) then
                if helpers:try_cast(spells.force_of_nature, target, "[Balance] Force of Nature") then return true end
            end
        end
    end

    -- ============================
    -- FAERIE FIRE (armor reduction + Improved FF aura)
    -- ============================
    if common.try_faerie_fire(player, target, helpers, menu) then return true end

    -- ============================
    -- INSECT SWARM (DoT, also provides 2% tank avoidance)
    -- ============================
    if common.try_insect_swarm(player, target, helpers, menu) then return true end

    -- ============================
    -- MOONFIRE (DoT maintenance)
    -- ============================
    if common.try_moonfire(player, target, helpers) then return true end

    -- ============================
    -- STARFIRE (main nuke, must be standing still)
    -- ============================
    if not helpers:is_moving(player) then
        if helpers:get_menu_state(menu.balance_use_starfire, true) then
            if helpers:try_cast(spells.starfire, target, "[Balance] Starfire") then return true end
        end

        -- Wrath (shorter cast, fallback)
        if helpers:try_cast(spells.wrath, target, "[Balance] Wrath") then return true end
    end

    return false
end

--- Execute Balance rotation with level dispatch
function levels_caster.execute_balance(player, target, helpers, menu)
    local level = helpers:get_level(player)

    if level < 20 then
        return balance_early(player, target, helpers, menu)
    else
        return balance_full(player, target, helpers, menu)
    end
end

return levels_caster
