--[[
Shield Swap Helper
Manages automatic weapon swapping for Warrior shield abilities (Shield Bash, Shield Block, Shield Slam)
Performance-optimized with smart caching and reverse lookup (400x faster than naive approach)
]]

---@class shield_swap_helper
local shield_swap_helper = {}

-- Dependencies
---@type inventory_helper
local inventory_helper = require("common/utility/inventory_helper")

-- Shield IDs Database (injected for reusability)
local shield_ids_db = nil  -- Lazy-loaded on first use

-- Weapon IDs Databases (shared with TBC lists; used for 1H fallback + 2H detection)
local one_hand_ids_db = nil
local two_hand_ids_db = nil
local main_hand_ids_db = nil
local off_hand_ids_db = nil

-- Auto mode: runtime-only preferred shields (NOT persisted in settings)
local preferred_shield_ids = {} -- [item_id]=true

---Lazy-loads shield IDs database (dependency injection pattern)
---@param db_path string|nil Optional path to shield_ids module
---@return table shield_ids {list, set}
local function get_shield_ids_db(db_path)
    if not shield_ids_db then
        local path = db_path or "rotations/warrior/era/shield_item_ids"
        shield_ids_db = require(path)
    end
    return shield_ids_db
end

---@param db_path string|nil
---@return table ids {list, set}
local function get_one_hand_ids_db(db_path)
    if not one_hand_ids_db then
        local path = db_path or "rotations/warrior/tbc/one_hand_ids"
        one_hand_ids_db = require(path)
    end
    return one_hand_ids_db
end

---@param db_path string|nil
---@return table ids {list, set}
local function get_two_hand_ids_db(db_path)
    if not two_hand_ids_db then
        local path = db_path or "rotations/warrior/tbc/two_hand_ids"
        two_hand_ids_db = require(path)
    end
    return two_hand_ids_db
end

---@param db_path string|nil
---@return table ids {list, set}
local function get_main_hand_ids_db(db_path)
    if not main_hand_ids_db then
        local path = db_path or "rotations/warrior/tbc/main_hand_ids"
        main_hand_ids_db = require(path)
    end
    return main_hand_ids_db
end

---@param db_path string|nil
---@return table ids {list, set}
local function get_off_hand_ids_db(db_path)
    if not off_hand_ids_db then
        local path = db_path or "rotations/warrior/tbc/off_hand_ids"
        off_hand_ids_db = require(path)
    end
    return off_hand_ids_db
end

---@param item_id number
---@return boolean
local function is_two_hand_weapon(item_id)
    local id = tonumber(item_id) or 0
    if id <= 0 then
        return false
    end
    local db = get_two_hand_ids_db()
    return db and db.set and db.set[id] == true
end

---@param item_id number
---@return boolean
local function is_one_hand_weapon(item_id)
    local id = tonumber(item_id) or 0
    if id <= 0 then
        return false
    end
    local db = get_one_hand_ids_db()
    if db and db.set and db.set[id] == true then
        return true
    end
    local mh = get_main_hand_ids_db()
    return mh and mh.set and mh.set[id] == true
end

---@param item_id number
---@return boolean
local function is_offhand_weapon(item_id)
    local id = tonumber(item_id) or 0
    if id <= 0 then
        return false
    end
    local db = get_off_hand_ids_db()
    return db and db.set and db.set[id] == true
end

-- ============================================================================
-- Constants
-- ============================================================================

-- State Machine States
local STATE_IDLE = 0
local STATE_SWAPPING_TO_SHIELD = 1
local STATE_SHIELD_EQUIPPED = 2
local STATE_ABILITY_CAST = 3
local STATE_SWAPPING_BACK = 4

-- Equipment Slots (Classic WoW)
local SLOT_MAINHAND_2H = 15
local SLOT_MAINHAND_1H = 16
local SLOT_OFFHAND = 17

-- Timing Constants (ms)
local SWAP_THROTTLE_MS = 150              -- Anti-spam between item uses
local ABILITY_CAST_DELAY_MS = 1500        -- GCD default
local SWAP_BACK_DELAY_MS = 300            -- Buffer after ability
local FALLBACK_TIMEOUT_MS = 5000          -- Safety: force back to IDLE
local EQUIP_VERIFY_RETRY_MS = 900         -- Wait for equipment to update before fallback/abort
local INVENTORY_SCAN_INTERVAL_OOC = 30000 -- 30s out of combat
local INVENTORY_SCAN_INTERVAL_COMBAT = 0  -- NEVER during combat

-- ============================================================================
-- State & Cache
-- ============================================================================

-- Shield Inventory Cache (Smart Caching)
local shield_cache = {
    -- Timing
    last_scan_time = 0,
    scan_interval_ooc = INVENTORY_SCAN_INTERVAL_OOC,
    scan_interval_combat = INVENTORY_SCAN_INTERVAL_COMBAT,

    -- Found Shields in Inventory
    found_shields = {},  -- { {id, name, bag_id, bag_slot}, ... }

    -- User Selection (from UI)
    selected_shield_id = nil,       -- User's choice
    auto_selected_shield_id = nil,  -- First found (fallback)

    -- 1H Weapon Cache
    found_onehand_weapons = {},  -- { {id, name, bag_id, bag_slot}, ... }
    selected_onehand_id = nil,
    auto_selected_onehand_id = nil,

    -- Validity
    is_valid = false,
    force_rescan = false -- Manual refresh from UI
}

-- Swap State Machine
local swap_state = {
    current_state = STATE_IDLE,
    state_start_time = 0,

    -- Original Equipment (to restore)
    original_mainhand = { id = 0, slot = 0 },
    original_offhand = { id = 0, slot = 0 },
    original_mainhand_is_2h = false,

    -- Target Equipment
    target_shield_id = 0,
    target_onehand_id = 0,
    tried_onehand_fallback = false,
    swap_step = 0,

    -- Timing
    last_swap_time = 0,
    ability_cast_time = 0,

    -- Settings (from menu)
    ability_delay_ms = ABILITY_CAST_DELAY_MS,
    swap_back_delay_ms = SWAP_BACK_DELAY_MS,
    fallback_timeout_ms = FALLBACK_TIMEOUT_MS,
    require_onehand = false,
    verbose_logging = false,

    -- Restore flow (avoid double-equip in same tick)
    pending_restore_offhand = false,
    restore_offhand_id = 0,
    restore_not_before_ms = 0
}

-- Frame-based Equipment Cache (Performance Optimization)
local equipment_cache = {
    frame_time = 0,
    equipment = nil
}

-- Mode State (Auto vs Manual) - V3
local swap_mode = "auto"  -- "auto" or "manual"
local manual_shield_id = 0
local manual_weapon_id = 0

-- ============================================================================
-- Helper Functions
-- ============================================================================

---@param message string
local function log_verbose(message)
    if swap_state.verbose_logging then
        core.log("[Shield Swap] " .. message)
    end
end

local log_throttle = {}

---@param key string
---@param message string
---@param interval_ms number
local function log_verbose_throttled(key, message, interval_ms)
    if not swap_state.verbose_logging then
        return
    end
    local now_ms = 0
    do
        local ok_time, t = pcall(function()
            return core.game_time()
        end)
        if ok_time and t then
            now_ms = t
        end
    end
    local next_allowed = log_throttle[key] or 0
    if now_ms < next_allowed then
        return
    end
    log_throttle[key] = now_ms + (tonumber(interval_ms) or 0)
    core.log("[Shield Swap] " .. message)
end

---@param message string
local function log_error(message)
    core.log("[Shield Swap ERROR] " .. message)
end

---@param player game_object
---@return boolean
local function is_in_combat(player)
    if not player then return false end

    local ok, combat = pcall(function()
        return player:is_in_combat()
    end)
    return ok and combat == true
end

---@return number
local function now()
    return core.game_time()
end

-- ============================================================================
-- Inventory Scanning (Performance-Optimized)
-- ============================================================================

---Scans inventory for shields using reverse lookup (Inventory → Shield-IDs)
---Performance: O(100) instead of O(40,000) = 400x faster!
---@param player game_object
---@param force boolean|nil
---@return boolean success
function shield_swap_helper:scan_inventory(player, force)
    if not player then return false end

    local now_ms = now()

    -- Manual Mode: Skip scan (unless forced)
    if swap_mode == "manual" and not force then
        log_verbose("Skipping scan: Manual Mode active")
        return true  -- Manual mode uses manual IDs, no scan needed
    end

    -- Combat Check: NEVER scan during combat
    if is_in_combat(player) and not force then
        log_verbose("Skipping scan: in combat")
        return shield_cache.is_valid
    end

    -- Cache-Hit?
    if not force and not shield_cache.force_rescan then
        local elapsed = now_ms - shield_cache.last_scan_time
        if elapsed < shield_cache.scan_interval_ooc and shield_cache.is_valid then
            log_verbose_throttled("scan_cache_hit", "Cache hit (age: " .. math.floor(elapsed / 1000) .. "s)", 2000)
            return true
        end
    end

    log_verbose_throttled("scan_start", "Scanning inventory for shields... (force=" .. tostring(force == true) .. ", mode=" .. tostring(swap_mode) .. ")", 1500)

    -- NOTE: Character bags only (no bank). Bank scanning is intentionally disabled.
    local ok_slots, all_slots = pcall(function()
        return inventory_helper:get_character_bag_slots()
    end)
    if not ok_slots or type(all_slots) ~= "table" then
        log_error("inventory_helper:get_character_bag_slots() failed: " .. tostring(all_slots))
        return false
    end

    if #all_slots == 0 then
        log_error("inventory_helper:get_character_bag_slots() returned empty")
        return false
    end

    log_verbose_throttled("scan_slots_acquired", "Bag slots acquired (count=" .. tostring(tonumber(#all_slots) or 0) .. ")", 2000)

    -- Load shield IDs (hash-set for O(1) lookup - dependency injection)
    local ok_db, shield_ids = pcall(function()
        return get_shield_ids_db()
    end)
    if not ok_db or not shield_ids or not shield_ids.set then
        log_error("Failed to load shield DB (ok=" .. tostring(ok_db) .. ", has_set=" .. tostring(shield_ids and shield_ids.set ~= nil) .. ")")
        return false
    end

    local shield_list_count = 0
    pcall(function()
        shield_list_count = shield_ids.list and #shield_ids.list or 0
    end)
    log_verbose_throttled("shield_db_loaded", "Shield DB loaded (list=" .. tostring(shield_list_count) .. ")", 3000)

    -- Reset cache
    shield_cache.found_shields = {}
    shield_cache.found_onehand_weapons = {}

    local slots_with_item = 0
    local ids_read = 0
    local shield_matches = 0

    -- REVERSE LOOKUP: Iterate inventory, check shield-set
    -- Complexity: O(inventory_size) = O(100) instead of O(shield_count × inventory) = O(40,000)
    local ok_scan, scan_err = pcall(function()
        local total = tonumber(#all_slots) or 0
        for i = 1, total do
            local slot_data = all_slots[i]
            local item_obj = slot_data and (slot_data.object or slot_data.item) or nil
            if item_obj then
                slots_with_item = slots_with_item + 1
                local ok_id, item_id = pcall(function()
                    return item_obj:get_item_id()
                end)

                if ok_id and item_id then
                    local numeric_id = tonumber(item_id) or 0
                    ids_read = ids_read + 1

                    if numeric_id > 0 and shield_ids.set[numeric_id] then
                        local ok_name, item_name = pcall(function()
                            return item_obj:get_name()
                        end)

                        table.insert(shield_cache.found_shields, {
                            id = numeric_id,
                            name = ok_name and item_name or ("Shield " .. item_id),
                            bag_id = slot_data.bag_id or 0,
                            bag_slot = slot_data.bag_slot or 0
                        })

                        log_verbose("Found shield: " .. (ok_name and item_name or item_id))
                        shield_matches = shield_matches + 1
                    elseif numeric_id > 0 and is_one_hand_weapon(numeric_id) and not is_offhand_weapon(numeric_id) then
                        local ok_name, item_name = pcall(function()
                            return item_obj:get_name()
                        end)

                        table.insert(shield_cache.found_onehand_weapons, {
                            id = numeric_id,
                            name = ok_name and item_name or ("Weapon " .. item_id),
                            bag_id = slot_data.bag_id or 0,
                            bag_slot = slot_data.bag_slot or 0
                        })
                    end
                end
            end
        end
    end)

    if not ok_scan then
        log_error("Inventory scan crashed: " .. tostring(scan_err) .. " (all_slots_type=" .. tostring(type(all_slots)) .. ")")
        return false
    end

    -- Update cache
    shield_cache.last_scan_time = now_ms
    shield_cache.is_valid = true
    shield_cache.force_rescan = false

    -- Prune preferred shields that are no longer in bags (runtime-only state)
    if next(preferred_shield_ids) ~= nil then
        local present = {}
        for _, shield in ipairs(shield_cache.found_shields) do
            if shield and shield.id then
                present[shield.id] = true
            end
        end
        for id, _ in pairs(preferred_shield_ids) do
            if not present[id] then
                preferred_shield_ids[id] = nil
            end
        end
    end

    -- Prune selected 1H weapon if no longer present
    if shield_cache.selected_onehand_id and shield_cache.selected_onehand_id > 0 then
        local present = false
        for _, w in ipairs(shield_cache.found_onehand_weapons or {}) do
            if w and w.id == shield_cache.selected_onehand_id then
                present = true
                break
            end
        end
        if not present then
            shield_cache.selected_onehand_id = nil
        end
    end

    -- Auto-select first shield if none selected
    if #shield_cache.found_shields > 0 then
        shield_cache.auto_selected_shield_id = shield_cache.found_shields[1].id
        if not shield_cache.selected_shield_id then
            shield_cache.selected_shield_id = shield_cache.found_shields[1].id
        end
        log_verbose_throttled("auto_selected_shield", "Auto-selected shield: " .. shield_cache.found_shields[1].name, 2000)
    else
        log_verbose_throttled("no_shields_found", "No shields found in bags", 2000)
    end

    -- Auto-select first 1H weapon if none selected
    if #shield_cache.found_onehand_weapons > 0 then
        shield_cache.auto_selected_onehand_id = shield_cache.found_onehand_weapons[1].id
        if not shield_cache.selected_onehand_id then
            shield_cache.selected_onehand_id = shield_cache.found_onehand_weapons[1].id
        end
    else
        shield_cache.auto_selected_onehand_id = nil
    end

    log_verbose_throttled("scan_complete", "Scan complete: found " .. #shield_cache.found_shields .. " shield(s)", 2000)

    return true
end

---Gets the shield to use (manual ID or auto-selected)
---@return number|nil shield_id
function shield_swap_helper:get_selected_shield_id()
    -- Manual Mode: Return manual ID
    if swap_mode == "manual" then
        return manual_shield_id > 0 and manual_shield_id or nil
    end

    -- Auto Mode: Prefer checked shields (runtime-only)
    if next(preferred_shield_ids) ~= nil and shield_cache.found_shields and #shield_cache.found_shields > 0 then
        for _, shield in ipairs(shield_cache.found_shields) do
            if shield and shield.id and preferred_shield_ids[shield.id] then
                return shield.id
            end
        end
    end

    -- Auto Mode: Return user-selected or auto-selected
    return shield_cache.selected_shield_id or shield_cache.auto_selected_shield_id
end

---Gets all found shields (for UI dropdown)
---@return table found_shields
function shield_swap_helper:get_found_shields()
    return shield_cache.found_shields
end

---Gets all found 1H weapons (for UI)
---@return table found_onehand_weapons
function shield_swap_helper:get_found_onehand_weapons()
    return shield_cache.found_onehand_weapons
end

---Gets the 1H weapon to use (manual uses manual_weapon_id, auto uses selected/auto-selected)
---@return number|nil onehand_id
function shield_swap_helper:get_selected_onehand_id()
    if swap_mode == "manual" then
        return manual_weapon_id > 0 and manual_weapon_id or nil
    end
    return shield_cache.selected_onehand_id or shield_cache.auto_selected_onehand_id
end

---Sets user-selected 1H weapon (from UI)
---@param onehand_id number
function shield_swap_helper:set_selected_onehand(onehand_id)
    local id = tonumber(onehand_id) or 0
    if id <= 0 then
        shield_cache.selected_onehand_id = nil
        return
    end
    shield_cache.selected_onehand_id = id
end

---Sets user-selected shield (from UI)
---@param shield_id number
function shield_swap_helper:set_selected_shield(shield_id)
    shield_cache.selected_shield_id = shield_id
    log_verbose("User selected shield: " .. shield_id)
end

---@param shield_id number
---@param enabled boolean
function shield_swap_helper:set_preferred_shield(shield_id, enabled)
    local id = tonumber(shield_id) or 0
    if id <= 0 then
        return
    end
    if enabled == true then
        preferred_shield_ids[id] = true
    else
        preferred_shield_ids[id] = nil
    end
end

---@param shield_id number
---@return boolean
function shield_swap_helper:is_preferred_shield(shield_id)
    local id = tonumber(shield_id) or 0
    if id <= 0 then
        return false
    end
    return preferred_shield_ids[id] == true
end

---Forces a rescan on next call
function shield_swap_helper:force_rescan()
    shield_cache.force_rescan = true
    shield_cache.is_valid = false
end

-- ============================================================================
-- Equipment Management
-- ============================================================================

---Helper: Gets item ID from inventory slot (deduplicates pcall boilerplate)
---@param player game_object
---@param slot_id number
---@return number item_id (0 if not found)
local function get_item_id_at_slot(player, slot_id)
    local ok_slot, slot_data = pcall(function()
        return player:get_item_at_inventory_slot(slot_id)
    end)

    if not ok_slot or not slot_data or not slot_data.object then
        return 0
    end

    local ok_id, item_id = pcall(function()
        return slot_data.object:get_item_id()
    end)

    return (ok_id and item_id) or 0
end

---Detects currently equipped setup and determines if shield is already equipped
---PERFORMANCE: Frame-cached to avoid redundant calls per frame
---@param player game_object
---@return table current_setup
local function detect_current_equipment(player)
    local now_time = now()

    -- Frame cache hit (same frame = same equipment state)
    if equipment_cache.frame_time == now_time and equipment_cache.equipment then
        return equipment_cache.equipment
    end

    local setup = {
        has_shield_equipped = false,
        shield_id = 0,
        mainhand_id = 0,
        mainhand_slot = 0,
        offhand_id = 0,
        is_2h = false,
        is_1h = false
    }

    if not player then
        return setup
    end

    -- Check Off-Hand (Shield)
    local oh_id = get_item_id_at_slot(player, SLOT_OFFHAND)
    if oh_id > 0 then
        setup.offhand_id = oh_id

        -- Check if it's a shield (dependency injection)
        local shield_ids = get_shield_ids_db()
        if shield_ids.set[oh_id] then
            setup.has_shield_equipped = true
            setup.shield_id = oh_id
            log_verbose_throttled("equip_oh_shield_" .. tostring(oh_id), "Detected shield equipped: " .. oh_id, 1500)
        end
    end

    -- Check Main-Hand (try slot 16 first, then fallback slot 15 for engines that expose 2H there)
    local mh_id = get_item_id_at_slot(player, SLOT_MAINHAND_1H)
    local mh_slot = SLOT_MAINHAND_1H
    if (tonumber(mh_id) or 0) <= 0 then
        mh_id = get_item_id_at_slot(player, SLOT_MAINHAND_2H)
        mh_slot = SLOT_MAINHAND_2H
    end

    if (tonumber(mh_id) or 0) > 0 then
        setup.mainhand_id = mh_id
        setup.mainhand_slot = mh_slot
        setup.is_2h = is_two_hand_weapon(mh_id)
        setup.is_1h = (setup.is_2h ~= true) and is_one_hand_weapon(mh_id)
    end

    -- Cache result for this frame
    equipment_cache.frame_time = now_time
    equipment_cache.equipment = setup

    return setup
end

---Saves current equipment for restore later (uses detect_current_equipment)
---@param player game_object
---@return boolean success
local function save_original_equipment(player)
    if not player then return false end

    local current = detect_current_equipment(player)

    -- Save Main-Hand (2H or 1H)
    swap_state.original_mainhand.id = current.mainhand_id
    swap_state.original_mainhand.slot = current.mainhand_slot
    swap_state.original_mainhand_is_2h = current.is_2h == true

    -- Save Off-Hand (could be shield, empty, or other)
    swap_state.original_offhand.id = current.offhand_id

    log_verbose(string.format(
        "Saved equipment: MH=%d (slot %d, 2H=%s), OH=%d (shield=%s)",
        current.mainhand_id, current.mainhand_slot, tostring(current.is_2h),
        current.offhand_id, tostring(current.has_shield_equipped)
    ))

    return true
end

---Equips an item by ID (simulates right-click)
---@param item_id number
---@return boolean success
local function equip_item(item_id)
    if not item_id or item_id == 0 then
        return false
    end

    local ok = pcall(function()
        core.input.use_item(item_id)
    end)

    if ok then
        log_verbose("Equipped item: " .. item_id)
    else
        log_error("Failed to equip item: " .. item_id)
    end

    return ok
end

---Verifies shield is equipped in offhand slot
---@param player game_object
---@param expected_shield_id number
---@return boolean is_equipped
local function verify_shield_equipped(player, expected_shield_id)
    if not player or not expected_shield_id or expected_shield_id == 0 then
        return false
    end

    local ok, offhand = pcall(function()
        return player:get_item_at_inventory_slot(SLOT_OFFHAND)
    end)

    if not ok or not offhand or not offhand.object then
        return false
    end

    local ok_id, current_id = pcall(function()
        return offhand.object:get_item_id()
    end)

    return ok_id and (tonumber(current_id) or 0) == (tonumber(expected_shield_id) or 0)
end

-- ============================================================================
-- State Machine
-- ============================================================================

---Resets state machine to IDLE
local function reset_state()
    swap_state.current_state = STATE_IDLE
    swap_state.state_start_time = 0
    swap_state.target_shield_id = 0
    swap_state.target_onehand_id = 0
    swap_state.tried_onehand_fallback = false
    swap_state.swap_step = 0
    swap_state.ability_cast_time = 0
    swap_state.pending_restore_offhand = false
    swap_state.restore_offhand_id = 0
    swap_state.restore_not_before_ms = 0
    log_verbose("State: IDLE")
end

---Updates state machine settings from menu
---@param menu table
local function update_settings_from_menu(menu)
    if not menu then return end

    if menu.shield_swap_delay_ms and menu.shield_swap_delay_ms.get then
        swap_state.ability_delay_ms = menu.shield_swap_delay_ms:get()
    end

    if menu.shield_swap_back_delay_ms and menu.shield_swap_back_delay_ms.get then
        swap_state.swap_back_delay_ms = menu.shield_swap_back_delay_ms:get()
    end

    if menu.shield_swap_fallback_timeout_ms and menu.shield_swap_fallback_timeout_ms.get then
        swap_state.fallback_timeout_ms = menu.shield_swap_fallback_timeout_ms:get()
    end

    if menu.shield_swap_require_onehand and menu.shield_swap_require_onehand.get_state then
        swap_state.require_onehand = menu.shield_swap_require_onehand:get_state()
    end

    if menu.shield_swap_verbose_logging and menu.shield_swap_verbose_logging.get_state then
        swap_state.verbose_logging = menu.shield_swap_verbose_logging:get_state()
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

---Checks if shield abilities can be used (shield available or already equipped)
---@param player game_object
---@return boolean can_use
function shield_swap_helper:can_use_shield_abilities(player)
    if not player then return false end

    -- Ensure inventory scanned
    self:scan_inventory(player, false)

    -- Check current equipment
    local current = detect_current_equipment(player)

    -- Shield already equipped? Can use directly!
    if current.has_shield_equipped then
        log_verbose("Shield already equipped (ID: " .. current.shield_id .. "), no swap needed")
        return true
    end

    -- Shield in inventory?
    local shield_id = self:get_selected_shield_id()
    return shield_id ~= nil and shield_id > 0
end

---Determines if weapon swap is needed
---@param player game_object
---@return boolean needs_swap, string reason
function shield_swap_helper:needs_swap(player)
    if not player then
        return false, "no_player"
    end

    local current = detect_current_equipment(player)

    -- Shield already equipped → no swap needed
    if current.has_shield_equipped then
        return false, "shield_already_equipped"
    end

    -- Check if shield available in inventory
    -- If the cache is invalid and we're already in combat (e.g. rotation enabled mid-fight),
    -- do a minimal throttled force-scan so shield abilities can still work.
    do
        local now_ms = now()
        if swap_mode ~= "manual" and is_in_combat(player) and shield_cache.is_valid ~= true then
            local last_scan = tonumber(shield_cache.last_scan_time) or 0
            if (now_ms - last_scan) > 2000 then
                self:scan_inventory(player, true)
            end
        else
            self:scan_inventory(player, false)
        end
    end
    local shield_id = self:get_selected_shield_id()

    if not shield_id or shield_id == 0 then
        return false, "no_shield_available"
    end

    return true, "swap_required"
end

---Gets current equipment setup (public wrapper)
---@param player game_object
---@return table current_setup
function shield_swap_helper:detect_current_equipment(player)
    return detect_current_equipment(player)
end

---Initiates shield swap (saves original equipment, equips shield)
---@param player game_object
---@return boolean success
function shield_swap_helper:equip_shield_setup(player)
    if not player then return false end

    -- Already swapping?
    if swap_state.current_state ~= STATE_IDLE then
        log_verbose("Already swapping, state: " .. swap_state.current_state)
        return false
    end

    -- Throttle
    local now_ms = now()
    if (now_ms - swap_state.last_swap_time) < SWAP_THROTTLE_MS then
        log_verbose("Swap throttled")
        return false
    end

    -- Get shield to equip (auto or manual)
    local shield_id = self:get_selected_shield_id()
    if not shield_id or shield_id == 0 then
        log_error("No shield ID available (check mode and settings)")
        return false
    end

    -- Manual Mode: Validate shield ID before equipping
    if swap_mode == "manual" then
        local is_valid, message = self:validate_manual_shield_id(shield_id)
        if not is_valid then
            log_error("Manual shield ID " .. shield_id .. " invalid: " .. message)
            return false
        end
    end

    -- Save original equipment
    if not save_original_equipment(player) then
        log_error("Failed to save original equipment")
        return false
    end

    -- Set 1H fallback target (manual uses manual weapon id, auto uses selected 1H)
    local onehand_id = 0
    if swap_mode == "manual" then
        onehand_id = tonumber(manual_weapon_id) or 0
    else
        onehand_id = tonumber(self:get_selected_onehand_id() or 0) or 0
    end
    swap_state.target_onehand_id = onehand_id
    swap_state.tried_onehand_fallback = false
    swap_state.swap_step = 0

    -- Attempt shield-only first (may unequip 2H automatically on some engines)
    if not equip_item(shield_id) then
        log_error("Failed to equip shield ID " .. shield_id)
        return false
    end

    -- Update state
    swap_state.current_state = STATE_SWAPPING_TO_SHIELD
    swap_state.state_start_time = now_ms
    swap_state.target_shield_id = shield_id
    swap_state.last_swap_time = now_ms
    swap_state.swap_step = 1

    log_verbose("State: SWAPPING_TO_SHIELD (id: " .. shield_id .. ", mode: " .. swap_mode .. ")")

    return true
end

---Restores original equipment (swaps back to 2H)
---@param player game_object
---@return boolean success
function shield_swap_helper:restore_original_equipment(player)
    if not player then return false end

    -- Throttle
    local now_ms = now()
    if (now_ms - swap_state.last_swap_time) < SWAP_THROTTLE_MS then
        return false
    end

    -- Restore mainhand
    if swap_state.original_mainhand.id > 0 then
        if not equip_item(swap_state.original_mainhand.id) then
            log_error("Failed to restore mainhand")
            return false
        end
    end

    swap_state.last_swap_time = now_ms
    swap_state.pending_restore_offhand = false
    swap_state.restore_offhand_id = 0
    swap_state.restore_not_before_ms = 0

    -- Only restore offhand if original was a concrete item and mainhand isn't 2H.
    -- 2H equips typically clear the offhand automatically.
    if swap_state.original_mainhand_is_2h ~= true and (tonumber(swap_state.original_offhand.id) or 0) > 0 then
        swap_state.pending_restore_offhand = true
        swap_state.restore_offhand_id = swap_state.original_offhand.id
        swap_state.restore_not_before_ms = now_ms + SWAP_THROTTLE_MS
    end

    log_verbose("State: SWAPPING_BACK")

    return true
end

---Checks if currently swapped (not in IDLE state)
---@return boolean is_swapped
function shield_swap_helper:is_currently_swapped()
    return swap_state.current_state ~= STATE_IDLE
end

---Gets current swap state info
---@return table state_info
function shield_swap_helper:get_swap_state()
    return {
        state = swap_state.current_state,
        is_swapped = swap_state.current_state ~= STATE_IDLE,
        state_start_time = swap_state.state_start_time,
        target_shield_id = swap_state.target_shield_id
    }
end

---State machine update (called every frame during swap)
---@param player game_object
---@param menu table
---@return boolean is_processing
function shield_swap_helper:update(player, menu)
    if not player then
        reset_state()
        return false
    end

    -- Update settings
    update_settings_from_menu(menu)

    local now_ms = now()
    local state = swap_state.current_state

    -- Safety: Timeout check (force back to IDLE after configured timeout)
    if state ~= STATE_IDLE then
        local elapsed = now_ms - swap_state.state_start_time
        local timeout_ms = tonumber(swap_state.fallback_timeout_ms) or FALLBACK_TIMEOUT_MS
        if elapsed > timeout_ms then
            log_error("State timeout! Forcing back to IDLE (elapsed: " .. elapsed .. "ms)")
            self:restore_original_equipment(player)
            if swap_state.pending_restore_offhand == true and (tonumber(swap_state.restore_offhand_id) or 0) > 0 then
                equip_item(swap_state.restore_offhand_id)
            end
            reset_state()
            return false
        end
    end

    -- State Machine
    if state == STATE_SWAPPING_TO_SHIELD then
        -- Multi-step: shield-only attempt, then fallback to 1H+shield if available
        if (now_ms - swap_state.last_swap_time) < SWAP_THROTTLE_MS then
            return true
        end

        if swap_state.swap_step == 1 then
            if verify_shield_equipped(player, swap_state.target_shield_id) then
                swap_state.current_state = STATE_SHIELD_EQUIPPED
                log_verbose("State: SHIELD_EQUIPPED (verified)")
                return true
            end

            -- Equipment updates can lag a bit; avoid false fallback/abort.
            if (now_ms - swap_state.last_swap_time) < EQUIP_VERIFY_RETRY_MS then
                return true
            end

            if swap_state.tried_onehand_fallback ~= true and (tonumber(swap_state.target_onehand_id) or 0) > 0 then
                swap_state.tried_onehand_fallback = true
                if equip_item(swap_state.target_onehand_id) then
                    swap_state.last_swap_time = now_ms
                    swap_state.swap_step = 2
                    return true
                end
                log_error("Failed to equip 1H fallback weapon: " .. tostring(swap_state.target_onehand_id))
                reset_state()
                return false
            end

            if (tonumber(swap_state.target_onehand_id) or 0) <= 0 then
                log_error("Shield not equipped after shield-only attempt and no 1H fallback available")
            else
                log_error("Shield not equipped after shield-only attempt (fallback already tried)")
            end
            reset_state()
            return false
        end

        if swap_state.swap_step == 2 then
            if equip_item(swap_state.target_shield_id) then
                swap_state.last_swap_time = now_ms
                swap_state.swap_step = 3
                return true
            end
            log_error("Failed to equip shield during fallback attempt: " .. tostring(swap_state.target_shield_id))
            reset_state()
            return false
        end

        if swap_state.swap_step == 3 then
            if verify_shield_equipped(player, swap_state.target_shield_id) then
                swap_state.current_state = STATE_SHIELD_EQUIPPED
                log_verbose("State: SHIELD_EQUIPPED (verified after fallback)")
                return true
            end
            -- Same as step 1: allow some time for the offhand slot to update before aborting.
            if (now_ms - swap_state.last_swap_time) < EQUIP_VERIFY_RETRY_MS then
                return true
            end
            log_error("Shield not equipped after 1H+shield fallback attempt, aborting")
            reset_state()
            return false
        end

        return true  -- Still processing

    elseif state == STATE_SHIELD_EQUIPPED then
        -- Waiting for ability to be cast (handled externally)
        -- This state is exited by try_shield_ability_with_swap when ability is cast.
        -- Return false so execute() continues and the rotation can reach the ability cast.
        return false

    elseif state == STATE_ABILITY_CAST then
        -- Wait GCD, then swap back
        local elapsed = now_ms - swap_state.ability_cast_time
        if elapsed >= swap_state.ability_delay_ms then
            if self:restore_original_equipment(player) then
                swap_state.current_state = STATE_SWAPPING_BACK
                swap_state.state_start_time = now_ms
            else
                log_error("Failed to restore equipment")
                reset_state()
                return false
            end
        end
        return true

    elseif state == STATE_SWAPPING_BACK then
        -- If needed, restore offhand after a short delay to avoid double-equip in the same tick.
        if swap_state.pending_restore_offhand == true and now_ms >= (swap_state.restore_not_before_ms or 0) then
            local oh_id = tonumber(swap_state.restore_offhand_id) or 0
            if oh_id > 0 then
                if equip_item(oh_id) then
                    log_verbose("Restored offhand: " .. tostring(oh_id))
                else
                    log_error("Failed to restore offhand: " .. tostring(oh_id))
                end
                -- Restart buffer timer from the last equip attempt to reduce flakiness.
                swap_state.state_start_time = now_ms
                swap_state.last_swap_time = now_ms
            end
            swap_state.pending_restore_offhand = false
            swap_state.restore_offhand_id = 0
            swap_state.restore_not_before_ms = 0
        end

        -- Wait buffer, then done
        local elapsed = now_ms - swap_state.state_start_time
        if elapsed >= swap_state.swap_back_delay_ms then
            log_verbose("Swap complete!")
            reset_state()
            return false
        end
        return true
    end

    return false
end

---Signals that ability was cast (triggers swap back)
function shield_swap_helper:signal_ability_cast()
    if swap_state.current_state == STATE_SHIELD_EQUIPPED then
        swap_state.current_state = STATE_ABILITY_CAST
        swap_state.ability_cast_time = now()
        log_verbose("State: ABILITY_CAST (waiting GCD)")
    end
end

---Gets cache info for UI
---@return table cache_info
function shield_swap_helper:get_cache_info()
    return {
        last_scan_time = shield_cache.last_scan_time,
        is_valid = shield_cache.is_valid,
        found_count = #shield_cache.found_shields,
        selected_id = shield_cache.selected_shield_id,
        auto_selected_id = shield_cache.auto_selected_shield_id,
        found_onehand_count = #(shield_cache.found_onehand_weapons or {}),
        selected_onehand_id = shield_cache.selected_onehand_id,
        auto_selected_onehand_id = shield_cache.auto_selected_onehand_id
    }
end

---Configures shield IDs database path (for reusability with other classes)
---@param db_path string Path to shield_item_ids module (e.g. "rotations/warrior/era/shield_item_ids")
function shield_swap_helper:set_shield_database(db_path)
    shield_ids_db = nil  -- Clear cache
    shield_ids_db = require(db_path)
    shield_cache.is_valid = false  -- Force rescan
    log_verbose("Shield database configured: " .. db_path)
end

-- ============================================================================
-- V3: Manual Mode API
-- ============================================================================

---Sets the shield swap mode
---@param mode string "auto" or "manual"
function shield_swap_helper:set_mode(mode)
    if mode == "auto" or mode == "manual" then
        if swap_mode == mode then
            return
        end
        swap_mode = mode
        log_verbose("Shield swap mode set to: " .. mode)
    else
        log_error("Invalid mode: " .. tostring(mode))
    end
end

---@param enabled boolean
function shield_swap_helper:set_verbose_logging(enabled)
    swap_state.verbose_logging = enabled == true
end

---Sets manual equipment IDs (Manual Mode)
---@param shield_id number Shield item ID
---@param weapon_id number|nil Optional 1H weapon ID
function shield_swap_helper:set_manual_equipment(shield_id, weapon_id)
    manual_shield_id = shield_id or 0
    manual_weapon_id = weapon_id or 0

    log_verbose(string.format(
        "Manual equipment set: Shield=%d, Weapon=%d",
        manual_shield_id, manual_weapon_id
    ))
end

---Validates if shield ID is valid (exists in shield_item_ids database)
---@param shield_id number
---@return boolean is_valid, string message
function shield_swap_helper:validate_manual_shield_id(shield_id)
    if not shield_id or shield_id == 0 then
        return false, "Shield ID is empty"
    end

    local shield_ids = get_shield_ids_db()
    if not shield_ids or not shield_ids.set then
        return false, "Shield database not loaded"
    end

    if not shield_ids.set[shield_id] then
        return false, string.format("ID %d is not a valid shield", shield_id)
    end

    return true, "Valid Shield"
end

---Gets current mode
---@return string mode "auto" or "manual"
function shield_swap_helper:get_mode()
    return swap_mode
end

return shield_swap_helper
