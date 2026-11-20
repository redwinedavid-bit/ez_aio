local consumables = {}

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type simple_movement
local movement = require("common/utility/simple_movement")

---@type izi_api
local izi = require("common/izi_sdk")

local spell_data = require("rotations/rogue/era/spell_data")

local last_target_dummy_use_time = 0.0

local function get_menu_elements(helpers)
    return helpers._menu_elements
end

function consumables.register(helpers)
    local log_throttled = helpers._log_throttled
    local get_item_diag_id = helpers._get_item_diag_id
    local has_item_in_inventory = helpers._has_item_in_inventory

    -- ============================================================================
    -- AUTO CONSUMABLES (Health Pots & Healthstones)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_use_health_potion(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_pot_enabled then
            return false
        end

        if not menu_elements.auto_pot_enabled:get_state() then
            return false
        end

        -- Check HP threshold
        local hp_percent = local_player:get_health_percentage()
        local threshold = menu_elements.auto_pot_threshold and menu_elements.auto_pot_threshold:get() or 25

        if hp_percent > threshold then
            return false
        end

        -- Try to use health potion (highest available)
        local potions = spell_data.consumables.health_potions
        for i = #potions, 1, -1 do
            local item_id = potions[i][1]
            local item_name = potions[i][2]

            if has_item_in_inventory(local_player, item_id) then
                local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
                local diag_id = get_item_diag_id("health_potion")
                if diag_enabled then
                    log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
                end

                local ok_queue = pcall(function()
                    spell_queue:queue_item_self(item_id, 10, "Health Pot: " .. item_name)
                end)
                if diag_enabled then
                    if ok_queue then
                        log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
                    else
                        log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
                    end
                end
                return ok_queue
            end
        end

        return false
    end

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_use_healthstone(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_healthstone_enabled then
            return false
        end

        if not menu_elements.auto_healthstone_enabled:get_state() then
            return false
        end

        -- Check HP threshold
        local hp_percent = local_player:get_health_percentage()
        local threshold = menu_elements.auto_healthstone_threshold and menu_elements.auto_healthstone_threshold:get() or 35

        if hp_percent > threshold then
            return false
        end

        -- Try to use healthstone (highest available)
        local healthstones = spell_data.consumables.healthstones
        for i = #healthstones, 1, -1 do
            local item_id = healthstones[i][1]
            local item_name = healthstones[i][2]

            if has_item_in_inventory(local_player, item_id) then
                local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
                local diag_id = get_item_diag_id("healthstone")
                if diag_enabled then
                    log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
                end

                local ok_queue = pcall(function()
                    spell_queue:queue_item_self(item_id, 10, "Healthstone: " .. item_name)
                end)
                if diag_enabled then
                    if ok_queue then
                        log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
                    else
                        log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
                    end
                end
                return ok_queue
            end
        end

        return false
    end

    -- ============================================================================
    -- AUTO TARGET DUMMY (Emergency Decoy)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_use_target_dummy(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_target_dummy_enabled then
            return false
        end

        if not menu_elements.auto_target_dummy_enabled:get_state() then
            return false
        end

        if not unit_helper:is_in_combat(local_player) then
            return false
        end

        local cast_end_time = local_player:get_active_spell_cast_end_time()
        if cast_end_time and cast_end_time > 0.0 then
            return false
        end

        local channel_end_time = local_player:get_active_channel_cast_end_time()
        if channel_end_time and channel_end_time > 0.0 then
            return false
        end

        local hp_percent = local_player:get_health_percentage()
        local threshold = menu_elements.auto_target_dummy_threshold and menu_elements.auto_target_dummy_threshold:get() or 15
        if hp_percent > threshold then
            return false
        end

        local now = core.time()
        if (now - last_target_dummy_use_time) < 1.0 then
            return false
        end

        local dummies = (spell_data.consumables and spell_data.consumables.target_dummies) or {}
        for i = #dummies, 1, -1 do
            local item_id = dummies[i][1]
            local item_name = dummies[i][2]

            if has_item_in_inventory(local_player, item_id) then
                local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
                local diag_id = get_item_diag_id("target_dummy")
                if diag_enabled then
                    log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
                end

                local pos = local_player:get_position()
                local ok_queue = pcall(function()
                    if pos then
                        spell_queue:queue_item_position(item_id, pos, 10, "Target Dummy: " .. item_name)
                    else
                        spell_queue:queue_item_self(item_id, 10, "Target Dummy: " .. item_name)
                    end
                end)

                if diag_enabled then
                    if ok_queue then
                        log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
                    else
                        log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
                    end
                end

                if ok_queue then
                    last_target_dummy_use_time = now
                end
                return ok_queue
            end
        end

        return false
    end

    -- ============================================================================
    -- AUTO BANDAGE (Hardcore Safe Mechanics)
    -- ============================================================================

    --- Attempts to use a bandage during safe windows
    --- Bandages restore health over 8 seconds (channeled), breaks on movement or damage
    --- Recently Bandaged debuff: 11196 (60 second cooldown)
    ---
    --- @param local_player game_object Player character
    --- @return boolean true if bandage was used successfully
    function helpers:try_use_bandage(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_bandage_enabled then
            return false
        end

        if not menu_elements.auto_bandage_enabled:get_state() then
            return false
        end

        -- PRE-CONDITION 1: HP threshold check (default 40%)
        local hp_percent = local_player:get_health_percentage()
        local threshold = menu_elements.auto_bandage_threshold and menu_elements.auto_bandage_threshold:get() or 40

        if hp_percent > threshold then
            return false
        end

        -- PRE-CONDITION 2: Check for "Recently Bandaged" debuff (60s cooldown)
        if local_player:debuff_up({11196}) then
            return false
        end

        -- PRE-CONDITION 3: Must be standing still (channeling breaks on movement)
        if not local_player:is_standing_still() then
            return false
        end

        -- PRE-CONDITION 4: Not already casting/channeling
        if local_player:is_channeling_or_casting() then
            return false
        end

        -- PRE-CONDITION 5: Check for damage-over-time effects (breaks bandaging)
        local all_dot_ids = spell_data.get_all_dot_ids()
        if local_player:debuff_up(all_dot_ids) then
            return false
        end

        -- SAFE WINDOW DETECTION: Only bandage during safe windows
        local is_safe = false
        local current_target = local_player:get_target()

        -- Safe window 1: Current target is GOUGED (not Blind/Sap) and within 5 yards
        if current_target and current_target:is_valid() then
            -- Check if target has Gouge debuff (specific check, not generic incap)
            local gouge = spell_data.cc.gouge
            if gouge and gouge.ids then
                local debuff_data = buff_manager:get_debuff_data(current_target, gouge.ids)
                local has_gouge = debuff_data and debuff_data.is_active or false

                if has_gouge then
                    -- Check distance: Target must be within 5 yards (close range for emergency bandage)
                    local player_pos = local_player:get_position()
                    local target_pos = current_target:get_position()
                    if player_pos and target_pos then
                        local distance = player_pos:dist_to(target_pos)
                        if distance <= 5 then
                            is_safe = true
                        end
                    end
                end
            end
        end

        -- If no Gouge detected, abort (only safe window is Gouge in 5y)
        if not is_safe then
            return false
        end

        -- PRE-CONDITION 6: Find highest tier bandage in inventory
        local bandage_id = nil
        if spell_data.consumables and spell_data.consumables.bandages then
            for i = #spell_data.consumables.bandages, 1, -1 do
                local bandage_data = spell_data.consumables.bandages[i]
                local item_id = bandage_data[1]

                if local_player:has_item(item_id) then
                    bandage_id = item_id
                    break
                end
            end
        end

        if not bandage_id then
            return false
        end

        if menu_elements.auto_bandage_movement_stop and menu_elements.auto_bandage_movement_stop:get_state() then
            movement:stop()
        end

        local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
        local diag_id = get_item_diag_id("bandage")
        if diag_enabled then
            log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
        end

        local ok_queue = pcall(function()
            spell_queue:queue_item_self(bandage_id, 10, "Bandage")
        end)

        if diag_enabled then
            if ok_queue then
                log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
            else
                log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
            end
        end
        return ok_queue
    end

    -- ============================================================================
    -- THISTLE TEA
    -- ============================================================================

    --- Attempts to use Thistle Tea consumable (restores 100 energy).
    --- Only uses when energy is below threshold and cooldowns toggle is enabled.
    --- Requires item in inventory.
    ---
    --- @param local_player game_object Player character
    --- @return boolean true if Thistle Tea was used successfully
    function helpers:try_use_thistle_tea(local_player)
        if not local_player then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not menu_elements or not menu_elements.auto_thistle_tea_enabled then
            return false
        end

        if not menu_elements.auto_thistle_tea_enabled:get_state() then
            return false
        end

        if not self:is_cooldowns_toggle_active() then
            return false
        end

        local thistle_tea = spell_data.consumables.thistle_tea
        if not thistle_tea then
            return false
        end

        local energy = local_player:energy_current()
        local energy_threshold = menu_elements.auto_thistle_tea_energy_threshold and
                                 menu_elements.auto_thistle_tea_energy_threshold:get() or 20

        if energy > energy_threshold then
            return false
        end

        local thistle_tea_item = izi.item(thistle_tea.item_id)

        local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
        local diag_id = get_item_diag_id("thistle_tea")
        if diag_enabled then
            log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
        end

        local ok_use = thistle_tea_item:use_self_safe("Thistle Tea", {
            skip_usable = false,
            skip_cooldown = false,
            skip_moving = true,
            skip_casting = true,
            skip_gcd = true
        })

        if diag_enabled then
            if ok_use then
                log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
            else
                log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
            end
        end

        return ok_use
    end
end

return consumables

