-- ============================================================================
-- Mage Rotation Logic (TBC Classic)
-- Arcane / Fire / Frost Support
-- Based on Priest rotation patterns for API compatibility
-- ============================================================================

local rotation_logic = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

local spells = require("rotations/mage/tbc/spells")
local pvp = require("rotations/mage/tbc/pvp")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

-- Helper to check for any mana gem in inventory with fresh item objects
local last_gem_use_ms = 0
local GEM_THROTTLE_MS = 5000 -- 5 second safety throttle
local last_slow_tick_ms = 0
local SLOW_TICK_MS = 2000 -- Run maintenance once every 2s

-- Helper to check if any mana gem is on cooldown (robust loop)
local function get_any_mana_gem_cooldown(player)
    if not spells.MANA_GEM_IDS then return 0 end
    if not player then return 0 end

    local max_cd = 0
    for _, id in ipairs(spells.MANA_GEM_IDS) do
        local ok, cd = pcall(function()
            return player:get_item_cooldown_ms(id)
        end)
        if ok and cd then
            max_cd = math.max(max_cd, cd)
        end
    end
    return max_cd / 1000
end

-- Helper to check for any mana gem in inventory
local function has_any_mana_gem(player)
    if not spells.MANA_GEM_IDS then return false end
    if not player then return false end
    
    for _, id in ipairs(spells.MANA_GEM_IDS) do
        if player:has_item(id) then return true end
    end
    return false
end

---@param player game_object
---@param target game_object|nil
---@param menu table
---@return boolean
local function try_arcane_torrent_interrupt(player, target, menu)
    if not menu or not menu.use_arcane_torrent_interrupt or not menu.use_arcane_torrent_interrupt.get_state then
        return false
    end

    if menu.use_arcane_torrent_interrupt:get_state() ~= true then
        return false
    end

    if not spells.arcane_torrent or not spells.arcane_torrent.is_learned or spells.arcane_torrent:is_learned() ~= true then
        return false
    end

    if not player or player:is_dead() or player:is_ghost() then
        return false
    end

    if not target or target:is_dead() or not target:is_valid_enemy() then
        return false
    end

    if not target:is_casting_spell() or target:is_active_spell_interruptable() ~= true then
        return false
    end

    local cast_pct = 0
    pcall(function()
        cast_pct = target:get_cast_pct() or 0
    end)
    local threshold_pct = menu.arcane_torrent_interrupt_pct and menu.arcane_torrent_interrupt_pct.get and menu.arcane_torrent_interrupt_pct:get() or 25
    if cast_pct < threshold_pct then
        return false
    end

    local dist_ok = false
    pcall(function()
        dist_ok = target:distance() <= 8.0
    end)
    if not dist_ok then
        return false
    end

    if player:is_channeling_or_casting() then
        return false
    end

    if spells.arcane_torrent:is_castable({ skip_facing = true }) and spells.arcane_torrent:cast(player) then
        return true
    end

    return false
end

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- WAND STATE TRACKING (Following Warlock patterns)
-- ============================================================================

local last_wand_toggle_ms = 0
local WAND_TOGGLE_THROTTLE_MS = 350
local wand_auto_active = false
local last_wand_stop_ms = 0
local WAND_STOP_THROTTLE_MS = 100

-- ============================================================================
-- PET ATTACK STATE TRACKING
-- ============================================================================

local last_pet_attack_ms = 0
local PET_ATTACK_THROTTLE_MS = 500

-- ============================================================================
-- UTILITY FUNCTIONS (Following Priest patterns)
-- ============================================================================

---Safe number conversion
---@param v any
---@param fallback number
---@return number
local function num(v, fallback)
    return tonumber(v) or fallback
end

---Safe menu checkbox access
---@param menu table
---@param key string
---@param fallback boolean
---@return boolean
local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then
        return fallback
    end
    return menu[key]:get_state() == true
end

---Safe menu slider access
---@param menu table
---@param key string
---@param fallback number
---@return number
local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then
        return fallback
    end
    return num(menu[key]:get(), fallback)
end

---Get HP percentage safely
---@param unit game_object
---@return number
local function hp_pct(unit)
    if not unit then return 0 end
    local ok, result = pcall(function()
        return unit:get_health_percentage()
    end)
    return ok and num(result, 0) or 0
end

---Get Mana percentage safely
---@param player game_object
---@return number
local function mana_pct(player)
    if not player then return 0 end
    local ok, result = pcall(function()
        return player:mana_pct()
    end)
    return ok and num(result, 0) or 0
end

---Check if player is casting or channeling
---@param player game_object
---@return boolean
local function is_casting_or_channeling(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_channeling_or_casting()
    end)
    return ok and result == true
end

---Check if player is moving
---@param player game_object
---@return boolean
local function is_moving(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_moving()
    end)
    return ok and result == true
end

---Check if player is mounted
---@param player game_object
---@return boolean
local function is_mounted(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_mounted()
    end)
    return ok and result == true
end

---Count enemies around a position
---@param pos table
---@param radius number
---@return table, number
local function get_enemies_around(pos, radius)
    if not pos or not unit_helper then return {}, 0 end
    local ok, enemies = pcall(function()
        return unit_helper:get_enemy_list_around(pos, radius, false, false)
    end)
    if not ok or type(enemies) ~= "table" then return {}, 0 end
    return enemies, #enemies
end

---Check if player is in combat
---@param player game_object
---@return boolean
local function is_in_combat(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_in_combat()
    end)
    return ok and result == true
end

---Check if spell is learned and ready (Priest pattern)
---@param spell any
---@return boolean
local function spell_ready(spell)
    if not spell then return false end
    
    local ok_learned, is_learned = pcall(function()
        return spell:is_learned()
    end)
    if not ok_learned or not is_learned then return false end
    
    local ok_cd, cd_up = pcall(function()
        return spell:cooldown_up()
    end)
    if not ok_cd or not cd_up then return false end
    
    return true
end

---Check if unit has a specific buff (accepts single ID or array of IDs)
---@param unit game_object
---@param buff_ids number|table
---@return boolean
local function has_buff(unit, buff_ids)
    if not unit or not buff_ids then return false end
    
    local ok_alive, is_alive = pcall(function()
        return unit:is_alive()
    end)
    if not ok_alive or not is_alive then return false end
    
    -- Convert single ID to table
    local ids = type(buff_ids) == "table" and buff_ids or {buff_ids}
    
    for _, id in ipairs(ids) do
        local ok, result = pcall(function()
            return unit:buff_up(id)
        end)
        if ok and result == true then
            return true
        end
    end
    return false
end

---Check if unit is missing a buff (accepts single ID or array of IDs)
---@param unit game_object
---@param buff_ids number|table
---@return boolean
local function buff_missing(unit, buff_ids)
    if not unit or not buff_ids then return true end
    
    local ok_alive, is_alive = pcall(function()
        return unit:is_alive()
    end)
    if not ok_alive or not is_alive then return true end
    
    -- Convert single ID to table
    local ids = type(buff_ids) == "table" and buff_ids or {buff_ids}
    
    for _, id in ipairs(ids) do
        local ok, result = pcall(function()
            return unit:buff_up(id)
        end)
        if ok and result == true then
            return false -- Found the buff
        end
    end
    return true -- Buff missing
end

---Check if unit has a specific debuff (accepts single ID or array of IDs)
---@param unit game_object
---@param debuff_ids number|table
---@return boolean
local function has_debuff(unit, debuff_ids)
    if not unit or not debuff_ids then return false end
    
    local ok_alive, is_alive = pcall(function()
        return unit:is_alive()
    end)
    if not ok_alive or not is_alive then return false end
    
    local ids = type(debuff_ids) == "table" and debuff_ids or {debuff_ids}
    
    for _, id in ipairs(ids) do
        local ok, result = pcall(function()
            return unit:debuff_up(id)
        end)
        if ok and result == true then
            return true
        end
    end
    return false
end
---Get debuff stacks
---@param unit game_object
---@param debuff_id number
---@return number
local function debuff_stacks(unit, debuff_id)
    if not unit or not debuff_id then return 0 end
    local ok, result = pcall(function()
        return unit:debuff_count(debuff_id)
    end)
    return ok and num(result, 0) or 0
end

---Get debuff remaining time in ms
---@param unit game_object
---@param debuff_id number
---@return number
local function debuff_remains(unit, debuff_id)
    if not unit or not debuff_id then return 0 end
    local ok, result = pcall(function()
        return unit:debuff_remains(debuff_id)
    end)
    return ok and num(result, 0) or 0
end

---Get buff stacks
---@param unit game_object
---@param buff_id number
---@return number
local function buff_stacks(unit, buff_id)
    if not unit or not buff_id then return 0 end
    local ok, result = pcall(function()
        return unit:buff_count(buff_id)
    end)
    return ok and num(result, 0) or 0
end

-- ============================================================================
-- WAND LOGIC (Following Warlock patterns)
-- ============================================================================

---Sync wand auto-attack state
---@param player game_object
local function sync_wand_auto_active(player)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then
        wand_auto_active = false
        return
    end
    local ok, is_attacking = pcall(function()
        return auto_attack_helper:is_auto_attacking(player)
    end)
    wand_auto_active = ok and is_attacking == true
end

---Stop wand if active (prevents wand from blocking spell casts)
---@param player game_object
---@param target game_object
local function stop_wand_if_active(player, target)
    if not auto_attack_helper or not auto_attack_helper.stop_attack then
        return
    end
    sync_wand_auto_active(player)
    if not wand_auto_active then
        return
    end
    local now_ms = core.game_time()
    if (now_ms - last_wand_stop_ms) < WAND_STOP_THROTTLE_MS then
        return
    end
    wand_auto_active = false
    last_wand_stop_ms = now_ms
    auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
end

---Try to use wand as filler
---@param state table
---@param menu table
---@return boolean
local function try_use_wand(state, menu)
    if not menu_enabled(menu, "use_wand", true) then return false end
    if not auto_attack_helper or not auto_attack_helper.start_attack then return false end
    local player = state.player
    local target = state.target
    if not target or state.is_moving then return false end
    
    -- Check conditions: mana below threshold OR target HP below threshold
    local mana_threshold = menu_number(menu, "wand_mana_threshold", 20)
    local target_hp_threshold = menu_number(menu, "wand_target_hp", 25)
    
    -- Wand when mana is low OR when target is low HP (finishing)
    local should_wand = state.player_mana <= mana_threshold or hp_pct(target) <= target_hp_threshold
    if not should_wand then return false end
    
    local now = state.now
    if (now - last_wand_toggle_ms) < WAND_TOGGLE_THROTTLE_MS then
        return false
    end
    
    -- Don't restart wand if we just stopped it (prevents stop-start loop)
    if (now - last_wand_stop_ms) < 200 then
        return false
    end
    
    -- Don't start if already active
    sync_wand_auto_active(player)
    if wand_auto_active then
        return true -- Already wanding, occupy the tick
    end
    
    last_wand_toggle_ms = now
    return auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) == true
end

---Safe spell cast
---@param spell any
---@param target game_object
---@param player game_object|nil  Optional cached player for wand stop
---@return boolean
local function cast_spell(spell, target, player)
    if not spell or not target then return false end
    if not spell_ready(spell) then return false end
    
    -- Stop wand right before we actually cast a real spell
    local p = player or izi.me()
    if p then stop_wand_if_active(p, target) end
    
    local ok, result = pcall(function()
        return (spell:is_castable() and spell:cast(target)) == true
    end)
    return ok and result == true
end

-- ============================================================================
-- BUFF MAINTENANCE
-- ============================================================================

---Maintain appropriate armor buff
---@param state table
---@param menu table
---@return boolean
local function maintain_armor(state, menu)
    local player = state.player
    if not menu_enabled(menu, "maintain_armor", true) then return false end
    if state.is_moving or state.is_mounted then return false end

    -- Check if ANY armor buff is already active
    if not buff_missing(player, spells.ALL_ARMOR_BUFF_IDS) then
        return false
    end

    local armor_mode = menu_number(menu, "armor_mode", 1) -- 1=Auto, 2=Molten, 3=Mage, 4=Ice
    local desired_armor = nil

    -- Select armor based on mode
    if armor_mode == 2 then
        desired_armor = spells.molten_armor
    elseif armor_mode == 3 then
        desired_armor = spells.mage_armor
    elseif armor_mode == 4 then
        desired_armor = spells.ice_armor
    else
        -- Auto-detect based on learned talents
        if spells.combustion and spells.combustion:is_learned() then
            desired_armor = spells.molten_armor
        elseif spells.arcane_power and spells.arcane_power:is_learned() then
            desired_armor = spells.mage_armor
        else
            desired_armor = spells.ice_armor
        end
    end

    -- Fallback chain if desired armor not available/learned
    if not desired_armor or not spell_ready(desired_armor) then
        if spell_ready(spells.mage_armor) then
            desired_armor = spells.mage_armor
        elseif spell_ready(spells.ice_armor) then
            desired_armor = spells.ice_armor
        elseif spell_ready(spells.fallback_armor) then
            desired_armor = spells.fallback_armor
        else
            return false
        end
    end

    return cast_spell(desired_armor, player)
end

---Maintain Arcane Intellect
---@param state table
---@param menu table
---@return boolean
local function maintain_intellect(state, menu)
    local player = state.player
    if not menu_enabled(menu, "maintain_intellect", true) then return false end
    if state.is_moving or state.is_mounted then return false end

    -- Check if already buffed with any single-target OR group intellect buff
    if not buff_missing(player, spells.ALL_INTELLECT_BUFF_IDS) then
        return false
    end

    -- Intellect is very expensive, ensure we have at least 25% mana
    if state.player_mana < 25 then return false end

    -- Default to single target Arcane Intellect
    local target_spell = spells.arcane_intellect
    
    -- If we are in a group and know Arcane Brilliance, we could use that, 
    -- but single target is safer for the "self maintenance" loop.
    
    return cast_spell(target_spell, player)
end

-- ============================================================================
-- MANA MANAGEMENT (No is_ready calls - use cooldown_up pattern)
-- ============================================================================

---Use Mana Gem if available
---@param state table
---@param menu table
---@return boolean
local function use_mana_gem(state, menu)
    local player = state.player
    if not menu_enabled(menu, "use_mana_gem", true) then return false end
    if not state.in_combat then return false end

    if (state.now - last_gem_use_ms) < GEM_THROTTLE_MS then return false end

    -- Deterministic check: Is the item category on cooldown?
    if get_any_mana_gem_cooldown(player) > 0.5 then return false end

    local threshold = menu_number(menu, "mana_gem_threshold", 80)
    if state.player_mana >= threshold then return false end

    -- Check for mana gems in inventory and use the first one found
    if not spells.MANA_GEM_IDS then return false end
    for _, id in ipairs(spells.MANA_GEM_IDS) do
        if player:has_item(id) then
            -- Use the specific ID found in inventory via spell_queue
            local ok_use = pcall(function()
                spell_queue:queue_item_self(id, 10, "Mana Gem")
            end)
            
            if ok_use then
                last_gem_use_ms = state.now
                return true
            end
        end
    end

    return false
end

---Conjure Mana Gem out of combat
---@param state table
---@param menu table
---@return boolean
local function conjure_mana_gem(state, menu)
    if state.in_combat or state.is_moving or state.is_mounted then return false end
    if not menu_enabled(menu, "conjure_gems", true) then return false end

    -- Check if we already have any mana gem
    if has_any_mana_gem(state.player) then
        return false
    end

    return cast_spell(spells.conjure_mana_gem, state.player)
end

---Use Evocation for mana recovery
---@param state table
---@param menu table
---@return boolean
local function use_evocation(state, menu)
    if not menu_enabled(menu, "use_evocation", true) then return false end
    if not state.in_combat then return false end

    local threshold = menu_number(menu, "evocation_threshold", 15)
    if state.player_mana >= threshold then return false end

    return cast_spell(spells.evocation, state.player)
end

-- ============================================================================
-- DEFENSIVE ABILITIES
-- ============================================================================

---Use Ice Block at critical HP
---@param state table
---@param menu table
---@return boolean
local function try_ice_block(state, menu)
    if not menu_enabled(menu, "use_ice_block", true) then return false end
    if not spell_ready(spells.ice_block) then return false end
    
    local threshold = menu_number(menu, "ice_block_hp_threshold", 15)
    if state.player_hp > threshold then return false end
    
    return cast_spell(spells.ice_block, state.player)
end

---Use Frost Nova for kiting/defense
---@param state table
---@param menu table
---@return boolean
local function try_frost_nova(state, menu)
    if not menu_enabled(menu, "use_frost_nova", false) then return false end
    if not spell_ready(spells.frost_nova) then return false end
    
    local threshold = menu_number(menu, "frost_nova_hp_threshold", 35)
    if state.player_hp > threshold then return false end
    
    -- Check if target is in melee range (use self cast for instant)
    return cast_spell(spells.frost_nova, state.player)
end

---Use Blink for escape
---@param state table
---@param menu table
---@return boolean
local function try_blink(state, menu)
    if not menu_enabled(menu, "use_blink", false) then return false end
    if not spell_ready(spells.blink) then return false end
    
    -- Blink is typically used manually, but can auto if very low HP
    if state.player_hp > 20 then return false end
    
    return cast_spell(spells.blink, state.player)
end

-- ============================================================================
-- UTILITY ABILITIES
-- ============================================================================

---Use Counterspell to interrupt
---@param state table
---@param menu table
---@return boolean
local function try_counterspell(state, menu)
    local target = state.target
    if not target or not menu_enabled(menu, "use_counterspell", false) then return false end
    if not spell_ready(spells.counterspell) then return false end
    
    -- Check if target is casting and interruptable
    local ok_casting, is_casting = pcall(function()
        return target:is_casting_spell()
    end)
    if not ok_casting or not is_casting then return false end
    
    local ok_int, interruptable = pcall(function()
        return target:is_active_spell_interruptable()
    end)
    if not ok_int or interruptable ~= true then return false end
    
    -- Cast at 30-80% of cast progress
    local ok_pct, cast_pct = pcall(function()
        return target:get_cast_pct()
    end)
    cast_pct = ok_pct and num(cast_pct, 0) or 0
    if cast_pct < 30 or cast_pct > 80 then return false end
    
    return cast_spell(spells.counterspell, target)
end

---Try to use Fire Blast as instant damage
---@param state table
---@param menu table
---@return boolean
local function try_fire_blast(state, menu)
    local player = state.player
    local target = state.target
    if not target or not menu_enabled(menu, "use_fireblast", true) then return false end
    if not spell_ready(spells.fire_blast) then return false end

    local target_hp = hp_pct(target)
    local threshold = menu_number(menu, "fireblast_hp_threshold", 10)
    
    -- 1. Finisher (Highest priority for Fire Blast)
    if target_hp <= threshold then
        return cast_spell(spells.fire_blast, target)
    end
    
    -- 2. Movement filler
    if state.is_moving and menu_enabled(menu, "use_fireblast_moving", true) then
        return cast_spell(spells.fire_blast, target)
    end

    -- 3. Always off cooldown (if enabled and enough mana)
    if menu_enabled(menu, "use_fireblast_off_cd", false) and state.player_mana > 30 then
        return cast_spell(spells.fire_blast, target)
    end

    return false
end

-- ============================================================================
-- PET ATTACK LOGIC
-- ============================================================================

---Try to command pet to attack the target
---@param state table
---@param menu table
---@return boolean
local function try_pet_attack(state, menu)
    if not menu_enabled(menu, "auto_pet_attack", true) then return false end
    local target = state.target
    local player = state.player
    if not target or not player then return false end
    
    -- Get the pet
    local ok_pet, pet = pcall(function() return player:get_pet() end)
    if not ok_pet or not pet then return false end
    
    -- Check if pet is alive
    local ok_dead, is_dead = pcall(function()
        return pet:is_dead()
    end)
    if ok_dead and is_dead then return false end
    
    -- Throttle pet attack commands
    local now_ms = core.game_time()
    if (now_ms - last_pet_attack_ms) < PET_ATTACK_THROTTLE_MS then
        return false
    end
    
    -- Check if pet is already attacking the correct target
    local pet_target = nil
    local ok_target, target_result = pcall(function()
        return pet:get_target()
    end)
    if ok_target and target_result then
        pet_target = target_result
    end
    
    -- Don't spam if pet is already on the correct target
    if pet_target then
        local ok_guid, pet_target_guid = pcall(function()
            return pet_target:get_guid()
        end)
        local ok_target_guid, target_guid = pcall(function()
            return target:get_guid()
        end)
        if ok_guid and ok_target_guid and pet_target_guid == target_guid then
            return false
        end
    end
    
    -- Command the pet to attack
    if core and core.input and core.input.pet_attack then
        local ok, result = pcall(function()
            return core.input.pet_attack(target)
        end)
        if ok and result then
            last_pet_attack_ms = now_ms
            return true
        end
    end
    
    return false
end

-- ============================================================================
-- SMART DECURSE (Tongues / Exhaustion only)
-- ============================================================================

-- Curse of Tongues (all ranks), Curse of Exhaustion
local PRIORITY_CURSE_IDS = {
    1714,  -- Curse of Tongues (Rank 1)
    11719, -- Curse of Tongues (Rank 2)
    18223, -- Curse of Exhaustion
}

---Remove high-priority curses from self, pet, or party members
---@param state table
---@param menu table
---@return boolean
local function try_smart_decurse(state, menu)
    if not menu_enabled(menu, "use_remove_curse_smart", true) then return false end
    if not spells.remove_curse then return false end
    if not spell_ready(spells.remove_curse) then return false end
    if state.is_casting or state.is_moving then return false end
    
    local player = state.player
    if not player then return false end
    
    -- Helper: check if a unit has any priority curse
    local function has_priority_curse(unit)
        if not unit or not unit:is_alive() then return false end
        for _, curse_id in ipairs(PRIORITY_CURSE_IDS) do
            local ok, has_it = pcall(function() return unit:debuff_up(curse_id) end)
            if ok and has_it then return true end
        end
        return false
    end
    
    -- 1. Check self
    if has_priority_curse(player) then
        return cast_spell(spells.remove_curse, player)
    end
    
    -- 2. Check pet
    local ok_pet, pet = pcall(function() return player:get_pet() end)
    if ok_pet and pet and pet:is_alive() and has_priority_curse(pet) then
        return cast_spell(spells.remove_curse, pet)
    end
    
    -- 3. Check party members
    local ok_party, party = pcall(function() return izi.get_party_members() end)
    if ok_party and party then
        for _, member in ipairs(party) do
            if member and member:is_alive() and has_priority_curse(member) then
                local dist = get_distance(player, member)
                if dist and dist <= 40 then
                    return cast_spell(spells.remove_curse, member)
                end
            end
        end
    end
    
    return false
end

-- ============================================================================
-- ARCANE ROTATION
-- ============================================================================

---Execute Arcane rotation
---@param state table
---@param menu table
---@return boolean
local function execute_arcane(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target then return false end
    
    local mana = state.player_mana
    local burst_active = has_buff(player, spells.ARCANE_POWER_BUFF_ID) or has_buff(player, spells.ICY_VEINS_BUFF_ID)

    -- Cooldowns during burn phase
    if not burst_active and mana > 90 and menu_enabled(menu, "use_cooldowns", true) then
        if cast_spell(spells.icy_veins, player, player) then return true end
        if cast_spell(spells.arcane_power, player, player) then return true end
    end

    -- Presence of Mind: instant Arcane Blast
    if menu_enabled(menu, "use_presence_of_mind", true) and burst_active then
        if cast_spell(spells.presence_of_mind, player, player) then return true end
    end

    -- Arcane Missiles on Clearcasting proc (free cast, don't waste it)
    if has_buff(player, spells.CLEARCASTING_BUFF_ID) then
        if menu_enabled(menu, "use_arcane_missiles", true) then
            if cast_spell(spells.arcane_missiles, target, player) then return true end
        end
    end

    -- Burn rotation: Arcane Blast spam
    if burst_active or (mana > menu_number(menu, "arcane_conserve_mana", 30)) then
        if cast_spell(spells.arcane_blast, target, player) then return true end
    end

    -- Conserve rotation: Check AB stacks
    local ab_stacks = buff_stacks(player, spells.ARCANE_BLAST_DEBUFF_ID)

    if ab_stacks >= 3 then
        -- Clear stacks with Frostbolt or Arcane Missiles
        if menu_enabled(menu, "use_arcane_missiles", true) then
            if cast_spell(spells.arcane_missiles, target, player) then return true end
        end
        if cast_spell(spells.frostbolt, target, player) then return true end
    else
        if cast_spell(spells.arcane_blast, target, player) then return true end
    end

    -- Fallback
    if cast_spell(spells.frostbolt, target, player) then return true end

    return false
end

-- ============================================================================
-- FIRE ROTATION
-- ============================================================================

---Execute Fire rotation
---@param state table
---@param menu table
---@return boolean
local function execute_fire(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target then return false end
    
    -- Improved Scorch maintenance (keep 5 stacks, refresh at < 4s remaining)
    if menu_enabled(menu, "maintain_scorch", true) then
        local scorch_stacks = debuff_stacks(target, spells.IMPROVED_SCORCH_DEBUFF_ID)
        local scorch_remains = debuff_remains(target, spells.IMPROVED_SCORCH_DEBUFF_ID)

        if scorch_stacks < 5 or scorch_remains < 4000 then
            if cast_spell(spells.scorch, target, player) then return true end
        end
    end

    -- Combustion: Pop early when Scorch stacks are full (maximizes crit stacking)
    if menu_enabled(menu, "use_cooldowns", true) then
        if spell_ready(spells.combustion) then
            local scorch_stacks = debuff_stacks(target, spells.IMPROVED_SCORCH_DEBUFF_ID)
            if scorch_stacks >= 5 then
                if cast_spell(spells.combustion, player, player) then return true end
            end
        end
        if cast_spell(spells.icy_veins, player, player) then return true end
    end

    -- Fire Blast while moving
    if state.is_moving then
        if try_fire_blast(state, menu) then return true end
        return false
    end

    -- Fireball spam (Primary)
    if cast_spell(spells.fireball, target, player) then return true end

    -- Low level fallback
    if not spells.fireball or not spells.fireball:is_learned() then
        if cast_spell(spells.frostbolt, target, player) then return true end
    end

    return false
end

-- ============================================================================
-- FROST ROTATION
-- ============================================================================

---Execute Frost rotation
---@param state table
---@param menu table
---@return boolean
local function execute_frost(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target then return false end
    
    -- Summon Water Elemental (OOC or in combat if dead)
    if menu_enabled(menu, "use_water_elemental", true) then
        if spell_ready(spells.summon_water_elemental) then
            local ok_pet, pet = pcall(function() return player:get_pet() end)
            local need_pet = not ok_pet or not pet or not pet:is_alive()
            if need_pet then
                if cast_spell(spells.summon_water_elemental, player, player) then return true end
            end
        end
    end

    -- Cooldowns
    if menu_enabled(menu, "use_cooldowns", true) then
        if cast_spell(spells.icy_veins, player, player) then return true end
        -- Cold Snap: reset Icy Veins / Water Elemental if both are on CD
        if menu_enabled(menu, "use_cold_snap", true) then
            if spell_ready(spells.cold_snap) then
                local iv_ready = spell_ready(spells.icy_veins)
                local we_ready = spell_ready(spells.summon_water_elemental)
                if not iv_ready and not we_ready then
                    if cast_spell(spells.cold_snap, player, player) then return true end
                end
            end
        end
    end

    -- Ice Lance while moving (instant cast)
    if state.is_moving then
        if menu_enabled(menu, "use_ice_lance", true) then
            if cast_spell(spells.ice_lance, target, player) then return true end
        end
        return false -- Don't try to cast Frostbolt while moving
    end

    -- Frostbolt (Primary nuke)
    if cast_spell(spells.frostbolt, target, player) then return true end

    -- Fallback if Frostbolt not learned (low level)
    if not spells.frostbolt or not spells.frostbolt:is_learned() then
        if cast_spell(spells.fireball, target, player) then return true end
    end

    return false
end

-- ============================================================================
-- SPEC DETECTION
-- ============================================================================

---Detect player spec based on learned talents
---@return number 2=Arcane, 3=Fire, 4=Frost
local function detect_spec()
    -- Check for signature talents / spells
    if spells.arcane_power and spells.arcane_power:is_learned() then
        return 2 -- Arcane
    elseif spells.combustion and spells.combustion:is_learned() then
        return 3 -- Fire
    elseif spells.summon_water_elemental and spells.summon_water_elemental:is_learned() then
        return 4 -- Frost
    end

    -- Low level logic
    local has_fireball = spells.fireball and spells.fireball:is_learned()
    local has_frostbolt = spells.frostbolt and spells.frostbolt:is_learned()

    if has_fireball and not has_frostbolt then
        return 3 -- Fire (Level 1-4)
    end

    -- Default to Frost
    return 4 
end

-- ============================================================================
-- AOE ROTATION (Frost AoE Farming / Leveling Tool)
-- ============================================================================

---Execute AoE rotation
---@param state table
---@param menu table
---@return boolean
local function execute_aoe_rotation(state, menu)
    local player = state.player
    local target = state.target
    if not player then return false end
    
    -- 1. Defensive Maintenance
    if menu_enabled(menu, "use_ice_barrier_aoe", true) then
        if not has_buff(player, spells.ICE_BARRIER_BUFF_IDS) and cast_spell(spells.ice_barrier, player) then
            return true
        end
    end
    
    if menu_enabled(menu, "use_mana_shield_aoe", false) then
        if not has_buff(player, spells.MANA_SHIELD_BUFF_IDS) and cast_spell(spells.mana_shield, player) then
            return true
        end
    end

    -- 2. Environmental / Position check
    
    -- Count enemies in melee range
    local player_pos = player:get_position()
    local _, enemies_melee = get_enemies_around(player_pos, 8.0)
    
    -- 3. Crowd Control (Frost Nova if enemies are in melee)
    if enemies_melee >= 1 and spell_ready(spells.frost_nova) then
        if cast_spell(spells.frost_nova, player) then return true end
    end
    
    -- 4. AoE Spells
    -- Blizzard is the main tool
    if menu_enabled(menu, "use_blizzard", true) then
        if cast_spell(spells.blizzard, target) then return true end
    end
    
    -- Cone of Cold if targets are close and Blizzard is not possible
    if menu_enabled(menu, "use_coc", true) and spell_ready(spells.cone_of_cold) then
        if cast_spell(spells.cone_of_cold, target) then return true end
    end

    -- Flamestrike (expensive filler)
    if menu_enabled(menu, "use_flamestrike", false) then
        if cast_spell(spells.flamestrike, target) then return true end
    end

    return false
end

-- ============================================================================
-- MAIN ENTRY
-- ============================================================================

---Main rotation entry point
---@param local_player game_object
---@param menu table
function rotation_logic:execute(local_player, menu)
    if not local_player then return end

    -- Centralized Cache (Snapshots for this tick)
    local target = izi.target()
    local focus = nil
    if izi.focus then
        pcall(function() focus = izi.focus() end)
    end

    local state = {
        player = local_player,
        target = target,
        focus = focus,
        now = core.game_time(),
        in_combat = is_in_combat(local_player),
        player_hp = hp_pct(local_player),
        player_mana = mana_pct(local_player),
        is_casting = is_casting_or_channeling(local_player),
        is_moving = is_moving(local_player),
        is_mounted = is_mounted(local_player)
    }

    -- Out of combat buffs
    if not state.in_combat then
        if (state.now - last_slow_tick_ms) >= SLOW_TICK_MS then
            last_slow_tick_ms = state.now
            if maintain_armor(state, menu) then return end
            if maintain_intellect(state, menu) then return end
            if conjure_mana_gem(state, menu) then return end
        end
    end

    -- MANA MANAGEMENT (Independent of target)
    if state.is_casting then return end
    if use_mana_gem(state, menu) then return end
    if use_evocation(state, menu) then return end

    if try_arcane_torrent_interrupt(state, menu) then
        return true
    end
    if not target then return end
    
    local ok_valid, is_valid = pcall(function()
        return target:is_valid_enemy()
    end)
    if not ok_valid or not is_valid then return end
    
    local ok_alive, is_alive = pcall(function()
        return target:is_alive()
    end)
    if not ok_alive or not is_alive then return end
    
    -- ATTACK ON TARGET CHECK:
    -- If disabled and NOT in combat, don't start the rotation (just target selection)
    -- If enabled OR already in combat, continue with rotation
    if not state.in_combat then
        if not menu_enabled(menu, "attack_on_target", true) then
            return -- Attack on target disabled - don't attack until we're in combat
        end
    end

    -- Command Pet to attack
    try_pet_attack(state, menu)

    -- Don't cast while already casting
    if state.is_casting then return end

    -- DEFENSIVES (highest priority in combat)
    if try_ice_block(state, menu) then return end
    if try_frost_nova(state, menu) then return end
    if try_blink(state, menu) then return end
    
    -- UTILITY (interrupt / steal / decurse)
    if try_counterspell(state, menu) then return end
    if pvp.handle_spellsteal(state, menu) then return end
    if try_smart_decurse(state, menu) then return end

    -- PVP MODULE (Control, Burst, Survival)
    if pvp.execute(state, menu) then return end

    -- Fire Blast (Instant/Finisher)
    if try_fire_blast(state, menu) then return end
    
    -- WAND PRIORITY CHECK: Use wand when mana is low or target is low HP
    -- This runs BEFORE rotation to ensure wand is used when conditions are met
    if menu_enabled(menu, "use_wand", true) then
        local mana_threshold = menu_number(menu, "wand_mana_threshold", 20)
        local target_hp_threshold = menu_number(menu, "wand_target_hp", 25)
        
        -- Use wand when mana is very low (below threshold) OR target is dying
        if state.player_mana <= mana_threshold or hp_pct(target) <= target_hp_threshold then
            try_use_wand(state, menu)
            return -- Always return to avoid casting during wand-save phase
        end
    end

    -- Spec detection / selection
    local spec = menu_number(menu, "rotation_mode", 1)

    if spec == 1 then
        spec = detect_spec()
    end

    -- AOE MODE BRANCH
    if menu_enabled(menu, "enable_aoe_mode", false) then
        local player_pos = state.player:get_position()
        local _, enemy_count = get_enemies_around(player_pos, 35.0)
        local threshold = menu_number(menu, "aoe_target_threshold", 3)
        
        if enemy_count >= threshold then
            if execute_aoe_rotation(state, menu) then return end
        end
    end

    -- Execute rotation based on spec
    if spec == 2 then
        execute_arcane(state, menu)
    elseif spec == 3 then
        execute_fire(state, menu)
    else
        execute_frost(state, menu)
    end
end

return rotation_logic



