-- ============================================================================
-- Druid Restoration Healing Rotation - Level Brackets (Classic ERA)
-- Dungeon (5-man) and Raid (25/40-man) healing support
-- ============================================================================

local levels_resto = {}

local common = require("rotations/druid/era/rotation/common")

-- ============================================================================
-- LEVEL 1-9: BASIC HEALING
-- Available: Healing Touch(1), Rejuvenation(4)
-- ============================================================================

function levels_resto.level_1_9(player, helpers)
    if not helpers:get_menu_state("enable_healing") then return false end

    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    -- Must be in caster form
    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    local level = helpers:get_player_level(player)

    -- Rejuvenation (level 4+)
    if level >= 4 and lowest_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
    end

    -- Healing Touch
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 10-19: + REGROWTH(12)
-- ============================================================================

function levels_resto.level_10_19(player, helpers)
    if not helpers:get_menu_state("enable_healing") then return false end

    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    local level = helpers:get_player_level(player)

    -- Dispels (non-critical situations)
    if lowest_hp > 40 then
        local poison_targets = helpers:get_dispel_poison_targets()
        if #poison_targets > 0 and level >= 14 then
            if helpers:try_cast("restoration", "abolish_poison", poison_targets[1]) then return true end
        end
        local curse_targets = helpers:get_dispel_curse_targets()
        if #curse_targets > 0 and level >= 24 then
            if helpers:try_cast("restoration", "remove_curse", curse_targets[1]) then return true end
        end
    end

    -- Regrowth (level 12+, flash-style heal with HoT)
    if level >= 12 and lowest_hp < helpers:get_menu_value("regrowth_hp", 60) then
        if not helpers:has_buff(lowest, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", lowest) then return true end
        end
    end

    -- Rejuvenation
    if lowest_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
    end

    -- Healing Touch
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 20-29: + ABOLISH POISON(26), REMOVE CURSE(24)
-- ============================================================================

function levels_resto.level_20_29(player, helpers)
    if not helpers:get_menu_state("enable_healing") then return false end

    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    local level = helpers:get_player_level(player)

    -- Dispels
    if lowest_hp > 40 then
        if level >= 26 then
            local poison_targets = helpers:get_dispel_poison_targets()
            if #poison_targets > 0 then
                if helpers:try_cast("restoration", "abolish_poison", poison_targets[1]) then return true end
            end
        end
        if level >= 24 then
            local curse_targets = helpers:get_dispel_curse_targets()
            if #curse_targets > 0 then
                if helpers:try_cast("restoration", "remove_curse", curse_targets[1]) then return true end
            end
        end
    end

    -- Regrowth
    if lowest_hp < helpers:get_menu_value("regrowth_hp", 60) then
        if not helpers:has_buff(lowest, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", lowest) then return true end
        end
    end

    -- Rejuvenation
    if lowest_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
    end

    -- Healing Touch
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 30-39: + SWIFTMEND(talent), NS(talent), TRANQUILITY(30)
-- ============================================================================

function levels_resto.level_30_39(player, helpers)
    if not helpers:get_menu_state("enable_healing") then return false end

    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    -- Tranquility: party-wide emergency
    if helpers:get_menu_state("resto_use_tranquility") then
        local tranq_count = helpers:get_menu_value("resto_tranq_count", 3)
        local allies_low = helpers:get_allies_below_hp(40)
        if allies_low >= tranq_count then
            if helpers:is_cooldown_ready("restoration", "tranquility") then
                if helpers:try_cast("restoration", "tranquility", player) then
                    helpers:log_checkpoint("tranq", 10.0, "[Druid][Resto] Tranquility - " .. allies_low .. " allies low")
                    return true
                end
            end
        end
    end

    -- Nature's Swiftness + Healing Touch emergency combo
    if helpers:get_menu_state("resto_use_ns") then
        local ns_hp = helpers:get_menu_value("ns_ht_hp", 25)
        if lowest_hp < ns_hp then
            if helpers:is_spell_learned("restoration", "natures_swiftness") then
                if helpers:has_buff(player, "natures_swiftness") then
                    -- NS is active, cast HT
                    if helpers:try_cast("restoration", "healing_touch", lowest) then
                        helpers:log_checkpoint("ns_ht", 5.0, "[Druid][Resto] NS+HT on " .. (lowest.get_name and lowest:get_name() or "ally"))
                        return true
                    end
                elseif helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                    if helpers:try_cast("restoration", "natures_swiftness", player) then
                        helpers:log_checkpoint("ns", 5.0, "[Druid][Resto] Nature's Swiftness activated")
                        return true
                    end
                end
            end
        end
    end

    -- Swiftmend (emergency, consumes HoT)
    if lowest_hp < helpers:get_menu_value("swiftmend_hp", 35) then
        if helpers:is_spell_learned("restoration", "swiftmend") then
            if helpers:has_buff(lowest, "rejuvenation") or helpers:has_buff(lowest, "regrowth") then
                if helpers:is_cooldown_ready("restoration", "swiftmend") then
                    if helpers:try_cast("restoration", "swiftmend", lowest) then
                        helpers:log_checkpoint("swiftmend", 3.0, "[Druid][Resto] Swiftmend emergency")
                        return true
                    end
                end
            end
        end
    end

    -- Dispels
    if lowest_hp > 40 then
        local poison_targets = helpers:get_dispel_poison_targets()
        if #poison_targets > 0 then
            if helpers:try_cast("restoration", "abolish_poison", poison_targets[1]) then return true end
        end
        local curse_targets = helpers:get_dispel_curse_targets()
        if #curse_targets > 0 then
            if helpers:try_cast("restoration", "remove_curse", curse_targets[1]) then return true end
        end
    end

    -- Regrowth
    if lowest_hp < helpers:get_menu_value("regrowth_hp", 60) then
        if not helpers:has_buff(lowest, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", lowest) then return true end
        end
    end

    -- Rejuvenation
    if lowest_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
    end

    -- Healing Touch
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

-- ============================================================================
-- LEVEL 40-49: + INNERVATE(40), BARKSKIN(44)
-- ============================================================================

function levels_resto.level_40_49(player, helpers)
    -- Same as 30-39 but with Innervate + Barkskin handled by common
    return levels_resto.level_30_39(player, helpers)
end

-- ============================================================================
-- LEVEL 50-60: FULL RESTORATION - DUNGEON + RAID
-- Dungeon: NS+HT > Swiftmend > Regrowth > Rejuv rolling > HT > Dispels
-- Raid: Rejuv blanket, Regrowth HoT on tank, Tranquility, Innervate
-- ============================================================================

function levels_resto.level_50_60(player, helpers)
    if not helpers:get_menu_state("enable_healing") then return false end

    local is_raid = helpers:is_in_raid()

    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then return true end
        return false
    end

    -- Barkskin: use while healing under pressure
    if helpers:get_menu_state("resto_use_barkskin") then
        local player_hp = helpers:get_player_hp(player)
        if player_hp < 60 and helpers:is_in_combat(player) then
            if not helpers:has_buff(player, "barkskin") then
                if helpers:is_cooldown_ready("buffs_utility", "barkskin") then
                    if helpers:try_cast("buffs_utility", "barkskin", player) then
                        helpers:log_checkpoint("barkskin_resto", 5.0, "[Druid][Resto] Barkskin while healing")
                        return true
                    end
                end
            end
        end
    end

    if is_raid then
        return levels_resto._raid_healing(player, helpers)
    else
        return levels_resto._dungeon_healing(player, helpers)
    end
end

-- ============================================================================
-- DUNGEON HEALING (5-man)
-- Priority: NS+HT emergency > Swiftmend > Regrowth > Rejuv rolling > HT
-- ============================================================================

function levels_resto._dungeon_healing(player, helpers)
    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    -- Tranquility: party-wide emergency
    if helpers:get_menu_state("resto_use_tranquility") then
        local tranq_count = helpers:get_menu_value("resto_tranq_count", 3)
        local allies_low = helpers:get_allies_below_hp(40)
        if allies_low >= tranq_count then
            if helpers:is_cooldown_ready("restoration", "tranquility") then
                if helpers:try_cast("restoration", "tranquility", player) then
                    helpers:log_checkpoint("tranq", 10.0, "[Druid][Resto] Tranquility - " .. allies_low .. " allies critical")
                    return true
                end
            end
        end
    end

    -- NS+HT Emergency
    if helpers:get_menu_state("resto_use_ns") then
        local ns_hp = helpers:get_menu_value("ns_ht_hp", 25)
        if lowest_hp < ns_hp then
            if helpers:is_spell_learned("restoration", "natures_swiftness") then
                if helpers:has_buff(player, "natures_swiftness") then
                    if helpers:try_cast("restoration", "healing_touch", lowest) then
                        helpers:log_checkpoint("ns_ht", 5.0, "[Druid][Resto] NS+HT emergency")
                        return true
                    end
                elseif helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                    if helpers:try_cast("restoration", "natures_swiftness", player) then return true end
                end
            end
        end
    end

    -- Swiftmend (emergency, requires HoT on target)
    if lowest_hp < helpers:get_menu_value("swiftmend_hp", 35) then
        if helpers:is_spell_learned("restoration", "swiftmend") then
            if helpers:has_buff(lowest, "rejuvenation") or helpers:has_buff(lowest, "regrowth") then
                if helpers:is_cooldown_ready("restoration", "swiftmend") then
                    if helpers:try_cast("restoration", "swiftmend", lowest) then return true end
                end
            end
        end
    end

    -- Dispels (non-critical)
    if lowest_hp > 40 then
        local poison_targets = helpers:get_dispel_poison_targets()
        if #poison_targets > 0 then
            if helpers:try_cast("restoration", "abolish_poison", poison_targets[1]) then return true end
        end
        local curse_targets = helpers:get_dispel_curse_targets()
        if #curse_targets > 0 then
            if helpers:try_cast("restoration", "remove_curse", curse_targets[1]) then return true end
        end
    end

    -- Regrowth (flash heal + HoT)
    if lowest_hp < helpers:get_menu_value("regrowth_hp", 60) then
        if not helpers:has_buff(lowest, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", lowest) then return true end
        end
    end

    -- Rejuvenation rolling on tank
    local tank, tank_hp = helpers:get_tank()
    if tank and tank_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(tank, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", tank) then return true end
        end
    end

    -- Rejuvenation on lowest
    if lowest_hp < helpers:get_menu_value("rejuvenation_hp", 85) then
        if not helpers:has_buff(lowest, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", lowest) then return true end
        end
    end

    -- Healing Touch (sustained big heal)
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

-- ============================================================================
-- RAID HEALING (25/40-man)
-- Priority: NS+HT emergency > Tranquility > Rejuv blanket > Regrowth tank > HT
-- ============================================================================

function levels_resto._raid_healing(player, helpers)
    local lowest, lowest_hp = helpers:get_lowest_ally()
    if not lowest or lowest_hp >= 95 then return false end

    -- Tranquility: raid-wide emergency (only heals your party of 5)
    if helpers:get_menu_state("resto_use_tranquility") then
        local tranq_count = helpers:get_menu_value("resto_tranq_count", 3)
        local allies_low = helpers:get_allies_below_hp(40)
        if allies_low >= tranq_count then
            if helpers:is_cooldown_ready("restoration", "tranquility") then
                if helpers:try_cast("restoration", "tranquility", player) then
                    helpers:log_checkpoint("tranq", 10.0, "[Druid][Resto][Raid] Tranquility")
                    return true
                end
            end
        end
    end

    -- NS+HT Emergency
    if helpers:get_menu_state("resto_use_ns") then
        local ns_hp = helpers:get_menu_value("ns_ht_hp", 25)
        if lowest_hp < ns_hp then
            if helpers:is_spell_learned("restoration", "natures_swiftness") then
                if helpers:has_buff(player, "natures_swiftness") then
                    if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
                elseif helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                    if helpers:try_cast("restoration", "natures_swiftness", player) then return true end
                end
            end
        end
    end

    -- Swiftmend emergency
    if lowest_hp < helpers:get_menu_value("swiftmend_hp", 35) then
        if helpers:is_spell_learned("restoration", "swiftmend") then
            if helpers:has_buff(lowest, "rejuvenation") or helpers:has_buff(lowest, "regrowth") then
                if helpers:is_cooldown_ready("restoration", "swiftmend") then
                    if helpers:try_cast("restoration", "swiftmend", lowest) then return true end
                end
            end
        end
    end

    -- Regrowth HoT on tank (keep rolling)
    local tank, tank_hp = helpers:get_tank()
    if tank and tank_hp < 80 then
        if not helpers:has_buff(tank, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", tank) then return true end
        end
    end

    -- Rejuvenation blanket: spread Rejuv on injured raid members without it
    local rejuv_threshold = helpers:get_menu_value("rejuvenation_hp", 85)
    local rejuv_target, rejuv_hp = helpers:get_injured_without_buff("rejuvenation", rejuv_threshold)
    if rejuv_target then
        if helpers:try_cast("restoration", "rejuvenation", rejuv_target) then
            helpers:log_checkpoint("rejuv_blanket", 1.0, "[Druid][Resto][Raid] Rejuv blanket at HP=" .. math.floor(rejuv_hp))
            return true
        end
    end

    -- Rejuvenation on tank (maintain)
    if tank and tank_hp < rejuv_threshold then
        if not helpers:has_buff(tank, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", tank) then return true end
        end
    end

    -- Dispels
    if lowest_hp > 40 then
        local poison_targets = helpers:get_dispel_poison_targets()
        if #poison_targets > 0 then
            if helpers:try_cast("restoration", "abolish_poison", poison_targets[1]) then return true end
        end
        local curse_targets = helpers:get_dispel_curse_targets()
        if #curse_targets > 0 then
            if helpers:try_cast("restoration", "remove_curse", curse_targets[1]) then return true end
        end
    end

    -- Healing Touch (sustained)
    if lowest_hp < helpers:get_menu_value("healing_touch_hp", 50) then
        if helpers:try_cast("restoration", "healing_touch", lowest) then return true end
    end

    return false
end

return levels_resto
