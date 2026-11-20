local racials = {}

---@type pvp_helper
local pvp_utiltiy = require("common/utility/pvp_helper")

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

local spell_data = require("rotations/rogue/era/spell_data")

local cached_stoneform_bleed_ids = nil

local function get_menu_elements(helpers)
    return helpers._menu_elements
end

---@return number[] bleed_ids
local function get_stoneform_bleed_ids()
    if cached_stoneform_bleed_ids then
        return cached_stoneform_bleed_ids
    end

    local bleed_ids = {}
    local seen = {}

    if spell_data and spell_data.damage_over_time then
        local bleed_groups = {
            spell_data.damage_over_time.rogue_bleeds,
            spell_data.damage_over_time.warrior_bleeds,
            spell_data.damage_over_time.druid_bleeds
        }

        for _, group in ipairs(bleed_groups) do
            if type(group) == "table" then
                for _, id in ipairs(group) do
                    if id and not seen[id] then
                        seen[id] = true
                        table.insert(bleed_ids, id)
                    end
                end
            end
        end
    end

    cached_stoneform_bleed_ids = bleed_ids
    return cached_stoneform_bleed_ids
end

function racials.register(helpers)
    local try_cast_spell_generic = helpers._try_cast_spell_generic

    -- ============================================================================
    -- RACIAL ABILITIES (Defensive & Utility)
    -- ============================================================================

    --- Attempts to use defensive racial abilities (CC/DoT removal).
    --- Handles: Will of the Forsaken (Undead), Stoneform (Dwarf).
    ---
    --- @param local_player game_object Player character
    --- @param target game_object Current target
    --- @return boolean true if defensive racial was used successfully
    function helpers:try_use_defensive_racial(local_player, target)
        if not local_player then return false end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_defensive_racial_enabled then
            return false
        end
        if not menu_elements.auto_defensive_racial_enabled:get_state() then
            return false
        end

        -- Will of the Forsaken (Fear/Charm break)
        local loc = local_player:get_loss_of_control_info()
        if loc and loc.valid then
            local loc_type = loc.type
            if loc_type == enums.loss_of_control_type.FEAR or
                loc_type == enums.loss_of_control_type.FEAR_MECHANIC or
                loc_type == enums.loss_of_control_type.CHARM then
                return try_cast_spell_generic(spell_data.racials, "will_of_the_forsaken", local_player, nil, {
                    throttle_time = 0.2,
                    queue_priority = 6,
                    skip_facing = true,
                    skip_range = true
                })
            end
        end

        -- Stoneform (Poison/Disease/Bleed removal)
        local threshold = menu_elements.stoneform_hp_threshold and
            menu_elements.stoneform_hp_threshold:get() or 60
        local hp_pct = local_player:get_health_percentage()

        if hp_pct < threshold then
            local has_poison_or_disease = false
            local debuffs = local_player:get_debuffs()
            if debuffs and type(debuffs) == "table" then
                for _, debuff in ipairs(debuffs) do
                    if debuff and (debuff.type == enums.buff_type.POISON or debuff.type == enums.buff_type.DISEASE) then
                        has_poison_or_disease = true
                        break
                    end
                end
            end

            local bleed_ids = get_stoneform_bleed_ids()
            local has_bleed = #bleed_ids > 0 and local_player:debuff_up(bleed_ids) or false

            if has_poison_or_disease or has_bleed then
                return try_cast_spell_generic(spell_data.racials, "stoneform", local_player, nil, {
                    throttle_time = 0.2,
                    queue_priority = 6,
                    skip_facing = true,
                    skip_range = true
                })
            end
        end

        return false
    end

    --- Attempts to use utility racial abilities (movement, stealth).
    --- Handles: Escape Artist (Gnome).
    ---
    --- @param local_player game_object Player character
    --- @param target game_object Current target
    --- @return boolean true if utility racial was used successfully
    function helpers:try_use_utility_racial(local_player, target)
        if not local_player then return false end

        local menu_elements = get_menu_elements(helpers)
        if menu_elements and menu_elements.auto_escape_artist_enabled and not menu_elements.auto_escape_artist_enabled:get_state() then
            return false
        end

        if pvp_utiltiy and pvp_utiltiy.is_pvp_scenario and pvp_utiltiy:is_pvp_scenario() then
            return false
        end

        if target and target.is_player and target:is_player() then
            return false
        end

        local should_cast = false
        local queue_priority = 5

        local loc = local_player:get_loss_of_control_info()
        if loc and loc.valid and loc.type == enums.loss_of_control_type.ROOT then
            should_cast = true
            queue_priority = 6
        else
            local max_speed = local_player:get_movement_speed_max() or 0
            local current_speed = local_player:get_movement_speed() or 0

            if max_speed > 0 then
                local speed_ratio = current_speed / max_speed
                local is_slowed = speed_ratio > 0 and speed_ratio <= 0.6

                if is_slowed then
                    local movement_direction = local_player:get_movement_direction()
                    local is_trying_to_move = movement_direction and
                        ((movement_direction.x or 0) ~= 0 or (movement_direction.y or 0) ~= 0 or (movement_direction.z or 0) ~= 0)

                    local is_outside_melee = false
                    if target and target.is_valid and target:is_valid() then
                        local player_pos = local_player:get_position()
                        local target_pos = target:get_position()
                        if player_pos and target_pos then
                            is_outside_melee = player_pos:dist_to(target_pos) > 5
                        end
                    end

                    if is_trying_to_move or is_outside_melee then
                        should_cast = true
                        queue_priority = 5
                    end
                end
            end
        end

        if should_cast then
            return try_cast_spell_generic(spell_data.racials, "escape_artist", local_player, nil, {
                throttle_time = 0.2,
                queue_priority = queue_priority,
                skip_facing = true,
                skip_range = true
            })
        end

        return false
    end

    -- ============================================================================
    -- RACIAL ABILITIES (DPS Cooldowns)
    -- ============================================================================

    --- Attempts to use racial DPS cooldown (Blood Fury for Orc, Berserking for Troll).
    --- Only casts when stacking with Adrenaline Rush or fighting Elite/Boss.
    --- Requires cooldowns toggle to be enabled.
    ---
    --- @param local_player game_object Player character
    --- @return boolean true if racial was queued successfully
    function helpers:try_use_racial_dps_cooldown(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_racial_enabled then
            return false
        end

        if not menu_elements.auto_racial_enabled:get_state() then
            return false
        end

        if not self:is_cooldowns_toggle_active() then
            return false
        end

        local smart_mode_enabled = menu_elements.auto_racial_smart_mode and menu_elements.auto_racial_smart_mode:get_state()

        if smart_mode_enabled then
            local ar_spell_id = 13750
            local ar_learned = core.spell_book.is_spell_learned(ar_spell_id)
            local cooldowns_enabled = self:is_cooldowns_toggle_active()

            if ar_learned and cooldowns_enabled then
                local has_ar_buff = self:has_buff(local_player, "adrenaline_rush")
                if not has_ar_buff then
                    return false
                end
            end
        end

        local target = local_player:get_target()
        if not target or not target:is_valid() then
            return false
        end

        local classification = target:get_classification()
        if not classification then
            classification = enums.classification.NORMAL
        end

        local use_on_boss = menu_elements.auto_racial_on_boss and menu_elements.auto_racial_on_boss:get_state()
        local use_on_elite = menu_elements.auto_racial_on_elite and menu_elements.auto_racial_on_elite:get_state()
        local use_on_normal = menu_elements.auto_racial_on_normal and menu_elements.auto_racial_on_normal:get_state()

        if not menu_elements.auto_racial_on_boss then
            use_on_boss = true
            use_on_elite = true
            use_on_normal = true
        end

        local is_boss = (classification == enums.classification.WORLD_BOSS or
                         classification == enums.classification.RARE_ELITE)
        local is_elite = (classification == enums.classification.ELITE or
                          classification == enums.classification.RARE)
        local is_normal = (classification == enums.classification.NORMAL)

        local target_allowed = false
        if is_boss and use_on_boss then
            target_allowed = true
        elseif is_elite and use_on_elite then
            target_allowed = true
        elseif is_normal and use_on_normal then
            target_allowed = true
        end

        if not target_allowed then
            return false
        end

        -- Blood Fury (Orc)
        local blood_fury_spell = izi.spell(spell_data.racials.blood_fury.ids)
        if blood_fury_spell and blood_fury_spell:is_castable({ skip_facing = true }) then
            local blood_fury_success = try_cast_spell_generic(spell_data.racials, "blood_fury", local_player, nil, {
                throttle_time = 0.2,
                queue_priority = 2,
                skip_facing = true,
                skip_range = true
            })
            if blood_fury_success then
                return true
            end
        end

        -- Berserking (Troll)
        local berserking_spell = izi.spell(spell_data.racials.berserking.ids)
        if berserking_spell and berserking_spell:is_castable({ skip_facing = true }) then
            local berserking_success = try_cast_spell_generic(spell_data.racials, "berserking", local_player, nil, {
                throttle_time = 0.2,
                queue_priority = 2,
                skip_facing = true,
                skip_range = true
            })
            if berserking_success then
                return true
            end
        end

        return false
    end
end

return racials

