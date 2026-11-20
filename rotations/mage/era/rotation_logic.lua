local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Mage Rotation Logic (Classic ERA)
-- Fire / Frost Support (No Arcane Blast in Classic)
-- Based on Priest rotation patterns for API compatibility
-- ============================================================================

local rotation_logic = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

local spells = require("rotations/mage/era/spells")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

-- Helper to check for any mana gem in inventory with fresh item objects
local last_gem_use_ms = 0
local GEM_THROTTLE_MS = 5000 -- 5 second safety throttle

-- Helper to check if any mana gem is on cooldown (robust loop)
local function get_any_mana_gem_cooldown()
    if not spells.MANA_GEM_IDS then return 0 end
    local player = izi.me()
    if not player then return 0 end

    for _, id in ipairs(spells.MANA_GEM_IDS) do
        -- Check if player has the item and its cooldown
        if player:has_item(id) then
            local cd = player:get_item_cooldown(id)
            if cd and cd > 0 then return cd end
        end
    end
    return 0
end

local function has_any_mana_gem()
    if not spells.MANA_GEM_IDS then return false end
    local player = izi.me()
    if not player then return false end

    for _, id in ipairs(spells.MANA_GEM_IDS) do
        if player:has_item(id) then
            return true
        end
    end
    return false
end

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- WAND STATE TRACKING
-- ============================================================================

local last_wand_toggle_ms = 0
local WAND_TOGGLE_THROTTLE_MS = 350
local wand_auto_active = false
local last_wand_stop_ms = 0
local WAND_STOP_THROTTLE_MS = 100

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

---Count enemies around a position
---@param pos table
---@param radius number
---@return table, number
local function get_enemies_around(pos, radius)
    if not pos or not unit_helper then return {}, 0 end
    local ok, enemies = pcall(function()
        return performance:get_enemy_list_around(unit_helper, pos, radius, false, false)
    end)
    if not ok or type(enemies) ~= "table" then return {}, 0 end
    return enemies, #enemies
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

-- ============================================================================
-- WAND LOGIC
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
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_use_wand(player, target, menu)
    if not menu_enabled(menu, "use_wand", true) then return false end
    if not auto_attack_helper or not auto_attack_helper.start_attack then return false end
    if is_moving(player) then return false end
    
    -- Check conditions: mana below threshold OR target HP below threshold
    local mana_threshold = menu_number(menu, "wand_mana_threshold", 20)
    local target_hp_threshold = menu_number(menu, "wand_target_hp", 25)
    local player_mana = mana_pct(player)
    local target_hp = hp_pct(target)
    
    -- Use wand when mana is very low (below threshold) OR target is dying
    local should_wand = player_mana <= mana_threshold or target_hp <= target_hp_threshold
    if not should_wand then return false end
    
    local now = core.game_time()
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
---@return boolean
local function cast_spell(spell, target)
    if not spell or not target then return false end
    if not spell_ready(spell) then return false end
    
    -- Stop wand right before we actually cast a real spell
    stop_wand_if_active(izi.me(), target)
    
    local ok, result = pcall(function()
        return (spell:is_castable() and spell:cast(target)) == true
    end)
    return ok and result == true
end

-- ============================================================================
-- DEFENSIVE ABILITIES
-- ============================================================================

---Use Ice Block at critical HP
---@param player game_object
---@param menu table
---@return boolean
local function try_ice_block(player, menu)
    if not menu_enabled(menu, "use_ice_block", true) then return false end
    if not spell_ready(spells.ice_block) then return false end
    
    local threshold = menu_number(menu, "ice_block_hp_threshold", 15)
    if hp_pct(player) > threshold then return false end
    
    return cast_spell(spells.ice_block, player)
end

---Use Frost Nova for kiting/defense
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_frost_nova(player, target, menu)
    if not menu_enabled(menu, "use_frost_nova", false) then return false end
    
    -- Always use R1 Nova if enabled in menu (saves mana, same root)
    local nova_spell = spells.frost_nova
    if menu_enabled(menu, "use_r1_nova_always", true) and spells.frost_nova_r1 and spells.frost_nova_r1:is_learned() then
        nova_spell = spells.frost_nova_r1
    end
 

    if not spell_ready(nova_spell) then return false end
    
    local threshold = menu_number(menu, "frost_nova_hp_threshold", 35)
    if hp_pct(player) > threshold then return false end
    
    -- Check if target is in melee range (use self cast for instant)
    return cast_spell(nova_spell, player)
end

-- ============================================================================
-- UTILITY ABILITIES
-- ============================================================================

---Use Counterspell to interrupt
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_counterspell(player, target, menu)
    if not menu_enabled(menu, "use_counterspell", false) then return false end
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
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_fire_blast(player, target, menu)
    if not menu_enabled(menu, "use_fireblast", true) then return false end
    if not spell_ready(spells.fire_blast) then return false end

    local target_hp = hp_pct(target)
    local threshold = menu_number(menu, "fireblast_hp_threshold", 10)
    
    -- 1. Finisher (Highest priority for Fire Blast)
    if target_hp <= threshold then
        return cast_spell(spells.fire_blast, target)
    end
    
    -- 2. Movement filler
    if is_moving(player) and menu_enabled(menu, "use_fireblast_moving", true) then
        return cast_spell(spells.fire_blast, target)
    end

    -- 3. Always off cooldown (if enabled and enough mana)
    if menu_enabled(menu, "use_fireblast_off_cd", false) and mana_pct(player) > 30 then
        return cast_spell(spells.fire_blast, target)
    end

    return false
end

local last_stealth_check_ms = 0
local STEALTH_CHECK_INTERVAL_MS = 3000

---Use R1 Arcane Explosion to reveal stealth
---@param player game_object
---@param menu table
---@return boolean
local function try_reveal_stealth(player, menu)
    if not menu_enabled(menu, "enable_script_check", true) then return false end
    if not spells.arcane_explosion_r1 or not spells.arcane_explosion_r1:is_learned() then return false end
    
    -- This is a niche tactic, maybe add a checkbox if it gets annoying
    -- For now, let's just make it part of the "Smart Downranking" suite or a hidden feature
    -- Actually, I'll only do it if the user explicitly wants "Stealth Alert" pulses (future UI item)
    -- OR just add it to the AoE loop.
    return false
end

-- ============================================================================
-- BUFF MAINTENANCE
-- ============================================================================

---Maintain appropriate armor buff
---@param player game_object
---@param menu table
---@return boolean
local function maintain_armor(player, menu)
    if not menu_enabled(menu, "maintain_armor", true) then return false end
    if is_moving(player) or is_mounted(player) then return false end

    -- Check if ANY armor buff is already active
    if not buff_missing(player, spells.ALL_ARMOR_BUFF_IDS) then
        return false
    end

    local armor_mode = menu_number(menu, "armor_mode", 1) -- 1=Auto, 3=Mage, 4=Ice
    local desired_armor = nil

    -- Select armor based on mode (Classic has no Molten Armor)
    if armor_mode == 3 then
        desired_armor = spells.mage_armor
    elseif armor_mode == 4 then
        desired_armor = spells.ice_armor
    else
        -- Auto-detect: Mage Armor preferred if learned, otherwise Ice Armor
        if spells.mage_armor and spell_ready(spells.mage_armor) then
            desired_armor = spells.mage_armor
        else
            desired_armor = spells.ice_armor
        end
    end

    -- Fallback chain if desired armor not available/learned
    if not desired_armor or not spell_ready(desired_armor) then
        if spell_ready(spells.ice_armor) then
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
---@param player game_object
---@param menu table
---@return boolean
local function maintain_intellect(player, menu)
    if not menu_enabled(menu, "maintain_intellect", true) then return false end
    if is_moving(player) or is_mounted(player) then return false end

    -- Check if already buffed with any single-target OR group intellect buff
    if not buff_missing(player, spells.ALL_INTELLECT_BUFF_IDS) then
        return false
    end

    -- Intellect is very expensive, ensure we have at least 25% mana
    if mana_pct(player) < 25 then return false end

    -- Default to single target Arcane Intellect
    local target_spell = spells.arcane_intellect
    
    return cast_spell(target_spell, player)
end

-- ============================================================================
-- AOE ROTATION (Classic AoE Tool)
-- ============================================================================

---Execute AoE rotation
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function execute_aoe_rotation(player, target, menu)
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
    local player_pos = player:get_position()
    
    -- Count enemies in melee range
    local _, enemies_melee = get_enemies_around(player_pos, 8.0)
    
    -- 3. Crowd Control (Frost Nova if enemies are in melee)
    if enemies_melee >= 1 then
        local nova_spell = spells.frost_nova
        if menu_enabled(menu, "use_r1_nova_always", true) and spells.frost_nova_r1 and spells.frost_nova_r1:is_learned() then
            nova_spell = spells.frost_nova_r1
        end
        if spell_ready(nova_spell) and cast_spell(nova_spell, player) then return true end
    end
    
    -- 4. AoE Spells
    -- Blizzard is the main tool
    if menu_enabled(menu, "use_blizzard", true) then
        local blizz_spell = spells.blizzard
        local mana = mana_pct(player)
        local downrank_threshold = menu_number(menu, "downrank_mana_threshold", 20)
        
        -- Downrank Blizzard if mana is low
        if menu_enabled(menu, "use_r1_blizzard_aoe", true) and mana < downrank_threshold then
            if spells.blizzard_r1 and spells.blizzard_r1:is_learned() then
                blizz_spell = spells.blizzard_r1
            end
        end
        
        if cast_spell(blizz_spell, target) then return true end
    end
    
    -- Cone of Cold filler
    if menu_enabled(menu, "use_coc", true) and spell_ready(spells.cone_of_cold) then
        local coc_spell = spells.cone_of_cold
        -- We could downrank CoC too if needed
        if cast_spell(coc_spell, target) then return true end
    end

    -- Flamestrike filler
    if menu_enabled(menu, "use_flamestrike", false) then
        if cast_spell(spells.flamestrike, target) then return true end
    end

    return false
end

-- ============================================================================
-- MANA MANAGEMENT
-- ============================================================================

---Use Mana Gem if available
---@param player game_object
---@param menu table
---@return boolean
local function use_mana_gem(player, menu)
    if not menu_enabled(menu, "use_mana_gem", true) then return false end
    if not is_in_combat(player) then return false end

    local now = izi.now_ms()
    if (now - last_gem_use_ms) < GEM_THROTTLE_MS then return false end

    -- Deterministic check: Is the item category on cooldown?
    if get_any_mana_gem_cooldown() > 0.5 then return false end

    local threshold = menu_number(menu, "mana_gem_threshold", 80)
    if mana_pct(player) >= threshold then return false end

    -- Check for mana gems in inventory and use the first one found
    if not spells.MANA_GEM_IDS then return false end
    for _, id in ipairs(spells.MANA_GEM_IDS) do
        if player:has_item(id) then
            -- Use the specific ID found in inventory via spell_queue
            local ok_use = pcall(function()
                spell_queue:queue_item_self(id, 10, "Mana Gem")
            end)
            
            if ok_use then
                last_gem_use_ms = now
                return true
            end
        end
    end

    return false
end

---Conjure Mana Gem out of combat
---@param player game_object
---@param menu table
---@return boolean
local function conjure_mana_gem(player, menu)
    if is_in_combat(player) or is_moving(player) or is_mounted(player) then return false end
    if not menu_enabled(menu, "conjure_gems", true) then return false end

    -- Check if we already have any mana gem
    if has_any_mana_gem() then
        return false
    end

    -- Pick the best spell (or fallback to nil check)
    local target_spell = spells.conjure_mana_gem
    if not target_spell or not target_spell:is_learned() then
        return false
    end

    return cast_spell(target_spell, player)
end

---Use Evocation for mana recovery
---@param player game_object
---@param menu table
---@return boolean
local function use_evocation(player, menu)
    if not menu_enabled(menu, "use_evocation", true) then return false end
    if is_moving(player) then return false end

    local threshold = menu_number(menu, "evocation_threshold", 15)
    if mana_pct(player) > threshold then return false end

    return cast_spell(spells.evocation, player)
end

-- ============================================================================
-- FROST ROTATION (Classic Era main spec)
-- ============================================================================

---Execute Frost rotation
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
-- A nearby enemy alone is not a reason to sacrifice damage for Rank 1.
-- If the runtime cannot confirm pursuit and slow state, use the normal rotation.
local function needs_kiting_slow(player, target)
    local ok, needed = pcall(function()
        return (__object_safety.same(target:get_target(),player))
            and target:is_moving()
            and not target:is_rooted()
            and target:is_slowed(0.10) == false
    end)
    return ok and needed == true
end

local function execute_frost(player, target, menu)
    -- Arcane Power if talented (Arcane/Frost hybrid)
    if menu_enabled(menu, "use_cooldowns", true) then
        if cast_spell(spells.arcane_power, player) then return true end
    end

    -- Downranking Logic
    local mana = mana_pct(player)
    local downrank_threshold = menu_number(menu, "downrank_mana_threshold", 20)
    local target_dist = 0
    pcall(function() target_dist = target:distance() end)

    -- Apply the fast slow only to an unslowed enemy pursuing the player.
    if menu_enabled(menu, "use_r1_frostbolt_kiting", true)
        and target_dist < 15 and target_dist > 5
        and needs_kiting_slow(player, target) then
        if cast_spell(spells.frostbolt_r1, target) then return true end
    end

    -- Frostbolt spam (Primary)
    local frostbolt_spell = spells.frostbolt
    if menu_enabled(menu, "enable_downranking", true) and mana < downrank_threshold then
        if spells.frostbolt_r1 and spells.frostbolt_r1:is_learned() then
            -- We might not want to always use R1 as DPS, but if mana is CRITICAL (e.g. < 5%)
            if mana < 5 then
                frostbolt_spell = spells.frostbolt_r1
            end
        end
    end

    if cast_spell(frostbolt_spell, target) then return true end

    -- Fire Blast as filler/mover
    if try_fire_blast(player, target, menu) then return true end
    
    -- Low level fallback: Fireball if Frostbolt isn't learned yet (usually level 1-4)
    if spells.fireball and spells.fireball:is_learned() and not spells.frostbolt:is_learned() then
        if cast_spell(spells.fireball, target) then return true end
    end

    return false
end

-- ============================================================================
-- FIRE ROTATION
-- ============================================================================

---Execute Fire rotation
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local IMPROVED_SCORCH_TALENT_IDS = { 11095, 12872, 12873 }

local function has_improved_scorch()
    if not core or not core.spell_book or not core.spell_book.is_spell_learned then
        return false
    end
    -- Check every rank; do not cache across talent changes.
    for _, id in ipairs(IMPROVED_SCORCH_TALENT_IDS) do
        local ok, learned = pcall(core.spell_book.is_spell_learned, id)
        if ok and learned == true then return true end
    end
    return false
end

local function execute_fire(player, target, menu)
    -- Improved Scorch maintenance (if talented)
    if menu_enabled(menu, "maintain_scorch", true) and has_improved_scorch() then
        local scorch_stacks = debuff_stacks(target, spells.IMPROVED_SCORCH_DEBUFF_ID)
        local scorch_remains = debuff_remains(target, spells.IMPROVED_SCORCH_DEBUFF_ID)

        if scorch_stacks < 5 or scorch_remains < 4000 then
            if cast_spell(spells.scorch, target) then return true end
        end
    end

    -- Combustion
    if menu_enabled(menu, "use_cooldowns", true) then
        if cast_spell(spells.combustion, player) then return true end
    end

    -- Fireball spam (Primary)
    local fireball_spell = spells.fireball
    local mana = mana_pct(player)
    local downrank_threshold = menu_number(menu, "downrank_mana_threshold", 20)

    if menu_enabled(menu, "enable_downranking", true) and mana < 5 then
        if spells.fireball_r1 and spells.fireball_r1:is_learned() then
            fireball_spell = spells.fireball_r1
        end
    end

    if cast_spell(fireball_spell, target) then return true end

    -- Fire Blast as filler/mover
    if try_fire_blast(player, target, menu) then return true end

    -- Fallback
    if cast_spell(spells.frostbolt, target) then return true end

    return false
end

-- ============================================================================
-- SPEC DETECTION
-- ============================================================================

---Detect player spec based on learned talents
---@return number 3=Fire, 4=Frost
local function detect_spec()
    -- Prioritize Fire if Combustion talent is learned (Signature Fire talent)
    if spells.combustion and spells.combustion:is_learned() then
        return 3 -- Fire
    end

    -- If no signature talents, look at base spam spells
    -- Generally, Fireball is the level 1 starter, Frostbolt at level 4.
    -- If we ONLY have Fireball, we are Fire.
    local has_fireball = spells.fireball and spells.fireball:is_learned()
    local has_frostbolt = spells.frostbolt and spells.frostbolt:is_learned()

    if has_fireball and not has_frostbolt then
        return 3 -- Fire (Level 1-4)
    end

    -- Default to Frost (Classic standard leveling spec)
    return 4 
end

-- ============================================================================
-- MAIN ENTRY
-- ============================================================================

---Main rotation entry point
---@param local_player game_object
---@param menu table
function rotation_logic:execute(local_player, menu)
    if not local_player then return end

    -- Out of combat buffs
    if not is_in_combat(local_player) then
        if maintain_armor(local_player, menu) then return end
        if maintain_intellect(local_player, menu) then return end
        if conjure_mana_gem(local_player, menu) then return end
    end

    -- MANA MANAGEMENT (Independent of target)
    if is_casting_or_channeling(local_player) then return end
    if use_mana_gem(local_player, menu) then return end
    if use_evocation(local_player, menu) then return end

    -- Get target
    local target = izi.target()
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
    if not is_in_combat(local_player) then
        if not menu_enabled(menu, "attack_on_target", true) then
            return -- Attack on target disabled - don't attack until we're in combat
        end
    end

    -- Don't cast while already casting
    if is_casting_or_channeling(local_player) then return end

    -- DEFENSIVES (highest priority in combat)
    if try_ice_block(local_player, menu) then return end
    if try_frost_nova(local_player, target, menu) then return end
    
    -- UTILITY (interrupt)
    if try_counterspell(local_player, target, menu) then return end

    -- Fire Blast (Instant/Finisher)
    if try_fire_blast(local_player, target, menu) then return end
    
    -- WAND PRIORITY CHECK: Use wand when mana is low or target is low HP
    -- This runs BEFORE rotation to ensure wand is used when conditions are met
    if menu_enabled(menu, "use_wand", true) then
        local mana_threshold = menu_number(menu, "wand_mana_threshold", 20)
        local target_hp_threshold = menu_number(menu, "wand_target_hp", 25)
        local player_mana = mana_pct(local_player)
        local target_hp = hp_pct(target)
        
        -- Use wand when mana is very low (below threshold) OR target is dying
        if player_mana <= mana_threshold or target_hp <= target_hp_threshold then
            if try_use_wand(local_player, target, menu) then
                return -- Stop other casts if wanding started
            end
        end
    end

    -- Spec detection / selection
    local spec = menu_number(menu, "rotation_mode", 1)

    if spec == 1 then
        spec = detect_spec()
    end

    -- AOE MODE BRANCH
    if menu_enabled(menu, "enable_aoe_mode", false) then
        local player_pos = local_player:get_position()
        local _, enemy_count = get_enemies_around(player_pos, 35.0)
        local threshold = menu_number(menu, "aoe_target_threshold", 3)
        
        if enemy_count >= threshold then
            if execute_aoe_rotation(local_player, target, menu) then return end
        end
    end

    -- Execute rotation based on spec
    if spec == 3 then
        execute_fire(local_player, target, menu)
    else
        execute_frost(local_player, target, menu)
    end
end

return rotation_logic
