local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Warrior APL (Hardcore Leveling + Dungeon, Tank Mode override)
-- Project Sylvanas / izi SDK only (no WoW Classic Lua API usage).
-- ============================================================================

local rotation_logic = {}
rotation_logic.__load_revision = "AF-WAR-20261114-PACK-SHIELD-VERIFY1"

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

local interrupt_targeting = require("shared/interrupt_targeting")
local spells = require("rotations/warrior/era/spells")
local game_client = require("shared/game_client")
local pack_threat = require("rotations/warrior/era/pack_threat")

local function is_forever_client()
    local version = tostring(game_client.get_game_version_string() or ""):lower()
    return version:find("forever", 1, true) ~= nil
end

local function player_in_combat(player)
    local ok, combat = pcall(function() return player:is_in_combat() end)
    if ok and combat == true then return true end
    if unit_helper and unit_helper.is_in_combat then
        local fallback_ok, fallback = pcall(function() return unit_helper:is_in_combat(player) end)
        return fallback_ok and fallback == true
    end
    return false
end

---@type shield_swap_helper
local shield_swap_helper = require("rotations/warrior/era/shield_swap_helper")

local healthstone_item = izi.item({ 9421, 5510, 5509, 5511, 5512, 19004 })

-- ============================================================================
-- State / throttles
-- ============================================================================

local last_stance_request_ms = 0
local STANCE_THROTTLE_MS = 450

local emergency_defensive_hold = false
local EMERGENCY_DEFENSIVE_EXIT_BUFFER_PCT = 10

local last_rage_dump_request_ms = 0
local RAGE_DUMP_THROTTLE_MS = 450

local last_sunder_leveling_request_ms = 0
local SUNDER_LEVELING_THROTTLE_MS = 650

local last_tank_aoe_opener_ms = 0
local TANK_AOE_OPENER_THROTTLE_MS = 2500
local TANK_THUNDER_CLAP_MIN_RAGE = 25
local TANK_CLEAVE_RAGE_THRESHOLD = 40

-- Interrupt scheduler (Rogue-style min/max % delay)
local pending_interrupt_target = nil
local pending_interrupt_cast_end = 0.0
local pending_interrupt_pct = 0.0
local last_interrupt_request_ms = 0
local INTERRUPT_THROTTLE_MS = 350

-- Thunder Clap stance-dance return
local pending_stance_return_spell = nil
local pending_stance_return_until_ms = 0
local pending_stance_return_not_before_ms = 0
local planned_stance_return_spell = nil
local planned_stance_return_until_ms = 0
local planned_interrupt_return_spell = nil
local planned_interrupt_return_until_ms = 0

-- Stance change observation (best-effort Tactical Mastery rage keep inference)
local last_stance_change_request_spell = nil
local last_stance_change_request_ms = 0
local last_stance_change_rage_before = 0
local inferred_stance_change_rage_kept = nil
local last_thunder_clap_request_ms = 0
local THUNDER_CLAP_THROTTLE_MS = 650

local HAMSTRING_MODE_TARGET_LOSS = 1
local HAMSTRING_MODE_ANY = 2

local target_loss_watch = {}
local TARGET_LOSS_WATCH_STALE_MS = 10000
local TARGET_LOSS_WATCH_CLEANUP_INTERVAL_MS = 2000
local last_target_loss_watch_cleanup_ms = 0
local last_target_loss_hamstring_ms = 0

-- ============================================================================
-- Helpers
-- ============================================================================

---@param unit game_object
---@param aura_id integer
---@return boolean
local function has_aura_id(unit, aura_id)
    if not unit or not aura_id then
        return false
    end

    local ok, auras = pcall(function()
        return performance:get_auras(unit)
    end)
    if not ok or not auras or #auras == 0 then
        return false
    end

    for _, aura in ipairs(auras) do
        local buff_id = aura and aura.buff_id
        if buff_id and buff_id == aura_id then
            return true
        end
    end

    return false
end

---@param value number
---@param min_value number
---@param max_value number
---@return number
local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

---@param unit game_object
---@return number cast_pct_0_100, number time_left_s, number cast_end_time
local function get_cast_pct_and_time_left(unit)
    if not unit then
        return 0.0, 0.0, 0.0
    end

    local cast_start = 0.0
    local cast_end = 0.0
    pcall(function() cast_start = unit:get_active_spell_cast_start_time() or 0.0 end)
    pcall(function() cast_end = unit:get_active_spell_cast_end_time() or 0.0 end)
    if cast_start <= 0.0 or cast_end <= 0.0 or cast_end <= cast_start then
        return 0.0, 0.0, cast_end or 0.0
    end

    local now_ms = core.game_time()
    local now_s = core.time()

    local left_ms = cast_end - now_ms
    local left_s = cast_end - now_s

    local use_ms = false
    if left_ms > -1000 and left_ms < 120000 then
        use_ms = true
    elseif left_s > -1 and left_s < 120 then
        use_ms = false
    else
        use_ms = cast_end > 100000
    end

    local time_left_s = 0.0
    if use_ms then
        time_left_s = left_ms > 0 and (left_ms / 1000.0) or 0.0
    else
        time_left_s = left_s > 0 and left_s or 0.0
    end

    local cast_pct = nil
    local ok_pct, pct_val = pcall(function()
        if unit.get_cast_pct then
            return unit:get_cast_pct()
        end
        return nil
    end)
    if ok_pct and pct_val ~= nil then
        cast_pct = tonumber(pct_val)
    end

    if cast_pct == nil then
        local total = cast_end - cast_start
        local elapsed = (use_ms and (now_ms - cast_start) or (now_s - cast_start))
        if total > 0 then
            cast_pct = clamp((elapsed / total) * 100.0, 0.0, 100.0)
        else
            cast_pct = 0.0
        end
    end

    if cast_pct < 0.0 then cast_pct = 0.0 end
    if cast_pct > 100.0 then cast_pct = 100.0 end

    return cast_pct, time_left_s, cast_end
end

---@param hp_pct number
---@param threshold number
---@return boolean
local function hp_below(hp_pct, threshold)
    return (hp_pct or 100) <= (threshold or 0)
end

---@param menu table
---@param hp_pct number
---@return boolean hold
---@return number enter_threshold
---@return number exit_threshold
local function update_emergency_defensive_hold(menu, hp_pct)
    if not menu or not menu.emergency_defensive_stance or not menu.emergency_defensive_stance.get_state then
        emergency_defensive_hold = false
        return false, 0, 0
    end

    if menu.emergency_defensive_stance:get_state() ~= true then
        emergency_defensive_hold = false
        return false, 0, 0
    end

    if not (spells.defensive_stance and spells.defensive_stance.is_learned and spells.defensive_stance:is_learned()) then
        emergency_defensive_hold = false
        return false, 0, 0
    end

    local enter_threshold = (menu.defensive_stance_hp_pct and menu.defensive_stance_hp_pct.get and menu.defensive_stance_hp_pct:get()) or 35
    enter_threshold = clamp(enter_threshold, 0, 100)
    local exit_threshold = clamp(enter_threshold + EMERGENCY_DEFENSIVE_EXIT_BUFFER_PCT, 0, 100)

    if emergency_defensive_hold then
        if (hp_pct or 100) >= exit_threshold then
            emergency_defensive_hold = false
        end
    else
        if hp_below(hp_pct, enter_threshold) then
            emergency_defensive_hold = true
        end
    end

    return emergency_defensive_hold, enter_threshold, exit_threshold
end

---@param player game_object
---@return number
local function rage(player)
    return player:get_power(enums.power_type.RAGE) or 0
end

---@param unit game_object
---@param aura_ids integer[]
---@return boolean
local function has_any_aura_id(unit, aura_ids)
    if not unit or not aura_ids then
        return false
    end

    local ok, auras = pcall(function()
        return performance:get_auras(unit)
    end)
    if not ok or not auras or #auras == 0 then
        return false
    end

    for _, aura in ipairs(auras) do
        local buff_id = aura and aura.buff_id
        if buff_id then
            for _, id in ipairs(aura_ids) do
                if buff_id == id then
                    return true
                end
            end
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@param player game_object
---@return boolean
local function in_battle_stance(player)
    return player and spells.battle_stance and has_aura_id(player, spells.battle_stance:id())
end

---@param player game_object
---@return boolean
local function in_defensive_stance(player)
    return player and spells.defensive_stance and has_aura_id(player, spells.defensive_stance:id())
end

---@param player game_object
---@return boolean
local function in_berserker_stance(player)
    return player and spells.berserker_stance and has_aura_id(player, spells.berserker_stance:id())
end

---@param player game_object
---@param stance_spell izi_spell
---@return boolean
local function try_set_stance(player, stance_spell)
    if not player or not stance_spell then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_stance_request_ms) < STANCE_THROTTLE_MS then
        return false
    end

    local rage_before = rage(player)
    last_stance_request_ms = now_ms
    local ok = (stance_spell:is_castable({ skip_facing = true }) and stance_spell:cast(player)) == true
    if ok then
        last_stance_change_request_spell = stance_spell
        last_stance_change_request_ms = now_ms
        last_stance_change_rage_before = rage_before
    end
    return ok
end

---@param player game_object
---@return izi_spell|nil
local function current_stance_spell(player)
    if in_defensive_stance(player) then
        return spells.defensive_stance
    end
    if in_berserker_stance(player) then
        return spells.berserker_stance
    end
    if in_battle_stance(player) then
        return spells.battle_stance
    end
    return nil
end

---@param menu table
---@return integer
local function stance_dance_rage_kept(menu)
    local fallback = (menu and menu.stance_dance_rage_kept_fallback and menu.stance_dance_rage_kept_fallback.get and menu.stance_dance_rage_kept_fallback:get()) or 0
    fallback = clamp(fallback, 0, 25)
    local auto_detect = (menu and menu.stance_dance_auto_detect_rage_kept and menu.stance_dance_auto_detect_rage_kept.get_state and menu.stance_dance_auto_detect_rage_kept:get_state()) == true
    if auto_detect and inferred_stance_change_rage_kept ~= nil then
        return inferred_stance_change_rage_kept
    end
    return fallback
end

---@param player game_object
---@param menu table
---@return integer predicted_after
local function predict_rage_after_stance_change(player, menu)
    local keep = stance_dance_rage_kept(menu)
    local cur = rage(player)
    if cur < keep then
        return cur
    end
    return keep
end

---@param player game_object
---@param menu table
---@param max_waste integer
---@param min_after integer
---@return boolean
local function allow_stance_dance_with_rage(player, menu, max_waste, min_after)
    if not player then
        return false
    end
    local keep = stance_dance_rage_kept(menu)
    local cur = rage(player)
    local predicted_after = predict_rage_after_stance_change(player, menu)
    if predicted_after < (min_after or 0) then
        return false
    end
    local waste = cur - keep
    if waste < 0 then
        waste = 0
    end
    return waste <= (max_waste or 0)
end

---@param player game_object
local function process_stance_change_observation(player)
    if not player or not last_stance_change_request_spell then
        return
    end

    local now_ms = core.game_time()
    if (now_ms - last_stance_change_request_ms) > 2500 then
        last_stance_change_request_spell = nil
        last_stance_change_request_ms = 0
        last_stance_change_rage_before = 0
        return
    end

    local stance_applied = false
    if last_stance_change_request_spell == spells.defensive_stance then
        stance_applied = in_defensive_stance(player)
    elseif last_stance_change_request_spell == spells.battle_stance then
        stance_applied = in_battle_stance(player)
    elseif last_stance_change_request_spell == spells.berserker_stance then
        stance_applied = in_berserker_stance(player)
    end

    if not stance_applied then
        return
    end

    local after = clamp(rage(player), 0, 25)
    if last_stance_change_rage_before >= 15 and after < last_stance_change_rage_before then
        inferred_stance_change_rage_kept = after
    end

    last_stance_change_request_spell = nil
    last_stance_change_request_ms = 0
    last_stance_change_rage_before = 0
end

local function clear_pending_stance_return()
    pending_stance_return_spell = nil
    pending_stance_return_until_ms = 0
    pending_stance_return_not_before_ms = 0
end

---@param player game_object
---@return boolean acted
local function process_pending_stance_return(player)
    if not player or not pending_stance_return_spell then
        return false
    end

    if emergency_defensive_hold and pending_stance_return_spell ~= spells.defensive_stance then
        clear_pending_stance_return()
        return false
    end

    -- Interrupt stance-dance has priority: do not flip stances while waiting to land Pummel.
    if planned_interrupt_return_spell and in_berserker_stance(player) then
        return false
    end

    local now_ms = core.game_time()
    if now_ms > pending_stance_return_until_ms then
        clear_pending_stance_return()
        return false
    end

    if now_ms < (pending_stance_return_not_before_ms or 0) then
        return false
    end

    if pending_stance_return_spell == spells.defensive_stance and in_defensive_stance(player) then
        clear_pending_stance_return()
        return false
    end
    if pending_stance_return_spell == spells.battle_stance and in_battle_stance(player) then
        clear_pending_stance_return()
        return false
    end
    if pending_stance_return_spell == spells.berserker_stance and in_berserker_stance(player) then
        clear_pending_stance_return()
        return false
    end

    if try_set_stance(player, pending_stance_return_spell) then
        return true
    end

    return false
end

---@param stance_spell izi_spell|nil
---@param now_ms number
---@param duration_ms integer
---@param not_before_ms integer|nil
local function schedule_stance_return(stance_spell, now_ms, duration_ms, not_before_ms)
    if not stance_spell then
        return
    end
    pending_stance_return_spell = stance_spell
    pending_stance_return_until_ms = (now_ms or core.game_time()) + (duration_ms or 2500)
    pending_stance_return_not_before_ms = not_before_ms or 0
end

---@param local_player game_object
---@param enemy game_object
---@param menu table
---@param toggle_field string
---@return boolean
local function engaged_only_filter(local_player, enemy, menu, toggle_field)
    if not local_player or not enemy or not menu then
        return true
    end

    local toggle = toggle_field and menu[toggle_field] or nil
    if not toggle or not toggle.get_state or toggle:get_state() ~= true then
        return true
    end

    -- Do not treat players as "engaged" targets for this filter (PvE-safe interrupts).
    do
        local ok_is_player, is_player = pcall(function()
            return enemy.is_player and enemy:is_player()
        end)
        if ok_is_player and is_player == true then
            return false
        end
    end

    local ok, enemy_target = pcall(function()
        return enemy:get_target()
    end)
    if not ok or not enemy_target then
        -- Fallback: allow if we have any threat on the enemy (engaged), even if it isn't targeting us/party.
        if local_player.get_threat_situation then
            local ok_threat, threat_info = pcall(function()
                return local_player:get_threat_situation(enemy)
            end)
            if ok_threat and threat_info then
                local is_tanking = threat_info.is_tanking == true
                local threat_pct = tonumber(threat_info.threat_percent) or 0
                if is_tanking or threat_pct > 0 then
                    return true
                end
            end
        end
        return false
    end

    if (__object_safety.same(enemy_target,local_player)) then
        return true
    end

    local ok_party, party_members = pcall(function()
        return performance:get_unit_list(local_player, "get_party_members_in_range", 40, true)
    end)
    if ok_party and party_members then
        for _, member in ipairs(party_members) do
            if (__object_safety.same(member,enemy_target)) then
                return true
            end
        end
    end

    -- Fallback: allow if we have any threat on the enemy (engaged), even if it isn't targeting us/party.
    if local_player.get_threat_situation then
        local ok_threat, threat_info = pcall(function()
            return local_player:get_threat_situation(enemy)
        end)
        if ok_threat and threat_info then
            local is_tanking = threat_info.is_tanking == true
            local threat_pct = tonumber(threat_info.threat_percent) or 0
            if is_tanking or threat_pct > 0 then
                return true
            end
        end
    end

    return false
end

---@param player game_object
---@param radius number
---@return integer
local function count_enemies_around_player(player, radius)
    if not player then
        return 0
    end

    local pos = player:get_position()
    if not pos then
        return 0
    end

    local enemies = performance:get_enemy_list_around(unit_helper, pos, radius or 8, true, false, false, false)
    return enemies and #enemies or 0
end

---@param obj game_object
---@return string|nil
local function target_loss_watch_key(obj)
    if not obj then
        return nil
    end

    if obj.get_guid then
        local ok, guid = pcall(function()
            return obj:get_guid()
        end)
        if ok and guid then
            return tostring(guid)
        end
    end

    return tostring(obj)
end

---@param now_ms number
local function cleanup_target_loss_watch(now_ms)
    if not now_ms then
        now_ms = core.game_time()
    end

    if (now_ms - last_target_loss_watch_cleanup_ms) < TARGET_LOSS_WATCH_CLEANUP_INTERVAL_MS then
        return
    end

    for key, entry in pairs(target_loss_watch) do
        if not entry or not entry.last_seen or (now_ms - entry.last_seen) >= TARGET_LOSS_WATCH_STALE_MS then
            target_loss_watch[key] = nil
        end
    end

    last_target_loss_watch_cleanup_ms = now_ms
end

---@param player game_object
---@param menu table
---@return boolean
local function try_hamstring_on_target_loss(player, menu)
    if not player or not menu then
        return false
    end

    if not (menu.auto_hamstring_on_target_loss and menu.auto_hamstring_on_target_loss:get_state()) then
        return false
    end

    local mode = menu.auto_hamstring_mode and menu.auto_hamstring_mode:get() or HAMSTRING_MODE_TARGET_LOSS
    local require_target_loss = mode == HAMSTRING_MODE_TARGET_LOSS

    if not spells.hamstring or not spells.hamstring:is_learned() then
        return false
    end

    local now_ms = core.game_time()

    local throttle = menu.auto_hamstring_on_target_loss_throttle and menu.auto_hamstring_on_target_loss_throttle:get() or 1200
    throttle = clamp(throttle, 100, 5000)
    if (now_ms - last_target_loss_hamstring_ms) < throttle then
        return false
    end

    local range = menu.auto_hamstring_on_target_loss_range and menu.auto_hamstring_on_target_loss_range:get() or 8
    range = clamp(range, 2, 15)

    local player_pos = player:get_position()
    if not player_pos then
        return false
    end

    cleanup_target_loss_watch(now_ms)

    local enemies = performance:get_enemy_list_around(unit_helper, player_pos, range, true, false, false, false)
    if not enemies or #enemies == 0 then
        return false
    end

    for _, enemy in __object_safety.live_ipairs(enemies) do
        if not enemy or not enemy:is_valid_enemy() or not enemy:is_alive() then
            goto continue
        end

        local key = target_loss_watch_key(enemy)
        if not key then
            goto continue
        end

        local ok_target, enemy_target = pcall(function()
            return enemy:get_target()
        end)
        local currently_targeting_player = ok_target and (__object_safety.same(enemy_target,player))

        local entry = target_loss_watch[key]
        if not entry then
            entry = {
                last_targeting_player = false,
                last_seen = now_ms,
                last_hamstring = 0
            }
        end

        local was_targeting = entry.last_targeting_player == true
        entry.last_seen = now_ms

        local should_trigger = not require_target_loss or (was_targeting and not currently_targeting_player)
        entry.last_targeting_player = currently_targeting_player
        target_loss_watch[key] = entry

        if should_trigger and spells.hamstring:is_castable_to_unit(enemy) then
            last_target_loss_hamstring_ms = now_ms
            entry.last_hamstring = now_ms
            if spells.hamstring:cast(enemy) then
                return true
            end
            goto continue
        end

        ::continue::
    end

    return false
end

---@param player game_object
---@param menu table
---@return boolean
local function try_hamstring_on_humanoid_low_hp(player, menu)
    if not player or not menu then
        return false
    end

    if not (menu.auto_hamstring_on_humanoid_lowhp and menu.auto_hamstring_on_humanoid_lowhp:get_state()) then
        return false
    end

    if not spells.hamstring or not spells.hamstring:is_learned() then
        return false
    end

    local humanoid_hp_pct = menu.auto_hamstring_on_humanoid_hp_pct and menu.auto_hamstring_on_humanoid_hp_pct:get() or 20
    humanoid_hp_pct = clamp(humanoid_hp_pct, 0, 40)

    local humanoid_range = menu.auto_hamstring_on_humanoid_range and menu.auto_hamstring_on_humanoid_range:get() or 5
    humanoid_range = clamp(humanoid_range, 2, 15)

    local now_ms = core.game_time()
    local throttle = menu.auto_hamstring_on_target_loss_throttle and menu.auto_hamstring_on_target_loss_throttle:get() or 1200
    throttle = clamp(throttle, 100, 5000)
    if (now_ms - last_target_loss_hamstring_ms) < throttle then
        return false
    end

    local player_pos = player:get_position()
    if not player_pos then
        return false
    end

    local enemies = performance:get_enemy_list_around(unit_helper, player_pos, humanoid_range, true, false, false, false)
    if not enemies or #enemies == 0 then
        return false
    end

    for _, enemy in __object_safety.live_ipairs(enemies) do
        if not enemy or not enemy:is_valid_enemy() or not enemy:is_alive() then
            goto continue
        end

        local ok_ct, creature_type = pcall(function()
            return enemy:get_creature_type()
        end)
        if not ok_ct or creature_type ~= enums.creature_type.HUMANOID then
            goto continue
        end

        local ok_hp, hp_pct = pcall(function()
            return enemy:get_health_percentage()
        end)
        if not ok_hp or not hp_pct or hp_pct > humanoid_hp_pct then
            goto continue
        end

        if spells.hamstring:is_castable_to_unit(enemy) then
            last_target_loss_hamstring_ms = now_ms
            if spells.hamstring:cast(enemy) then
                return true
            end
        end

        ::continue::
    end

    return false
end

---@param player game_object
---@return boolean
local function is_in_party(player)
    if not player or not player.get_party_members_in_range then
        return false
    end
    local ok_party, party_members = pcall(function()
        return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
    end)
    return ok_party and party_members and #party_members > 0
end

---@param unit game_object
---@return boolean
local function is_elite_or_boss(unit)
    if not unit then
        return false
    end

    if unit_helper and unit_helper.is_boss then
        local ok_boss, boss = pcall(function()
            return unit_helper:is_boss(unit)
        end)
        if ok_boss and boss == true then
            return true
        end
    end

    local ok_class, classification = pcall(function()
        return unit:get_classification()
    end)
    if ok_class and classification then
        return classification == enums.classification.ELITE
            or classification == enums.classification.RARE_ELITE
            or classification == enums.classification.RARE
            or classification == enums.classification.WORLD_BOSS
    end

    return false
end

-- forward decl (used by optional leveling Sunder)
local get_debuff_stacks

-- ============================================================================
-- Shield Swap Integration (Dynamic Weapon Swapping)
-- ============================================================================

---Wrapper for shield abilities with automatic weapon swapping (V2: Smart Swap Logic)
---@param player game_object
---@param target game_object
---@param menu table
---@param ability_spell izi_spell
---@param ability_name string
---@return boolean acted
local function try_shield_ability_with_swap(player, target, menu, ability_spell, ability_name)
    if not player or not target or not menu or not ability_spell then
        return false
    end

    -- A cooldown must not trigger an unnecessary weapon swap.
    if ability_spell.cooldown_up and ability_spell:cooldown_up() == false then
        return false
    end

    -- Feature disabled? Fallback to direct cast
    if not (menu.enable_shield_weapon_swap and menu.enable_shield_weapon_swap.get_state and menu.enable_shield_weapon_swap:get_state()) then
        -- Try direct cast (only works if shield already equipped)
        if ability_spell:is_castable_to_unit(target) then
            return ability_spell:cast(target) == true
        end
        return false
    end

    -- Check if swap needed (V2: Smart detection)
    local needs_swap, reason = shield_swap_helper:needs_swap(player)

    -- Shield already equipped → Direct cast (no swap needed!)
    if reason == "shield_already_equipped" then
        if ability_spell:is_castable_to_unit(target) and ability_spell:cast(target) == true then
            -- A temporary swap is ready too: signal success so it restores
            -- the original weapon instead of waiting for its safety timeout.
            if shield_swap_helper:is_currently_swapped() then
                shield_swap_helper:signal_ability_cast()
            end
            return true
        end
        return false
    end

    -- No shield available → Skip ability
    if reason == "no_shield_available" then
        return false
    end

    -- Swap required → State Machine Logic
    local swap_state = shield_swap_helper:get_swap_state()

    if swap_state.state == 0 then  -- STATE_IDLE
        -- Start swap sequence
        if shield_swap_helper:equip_shield_setup(player) then
            return true  -- Processing started
        end
        return false

    elseif swap_state.state == 2 then  -- STATE_SHIELD_EQUIPPED
        -- Ready to cast ability
        if ability_spell:is_castable_to_unit(target) then
            if ability_spell:cast(target) then
                -- Signal ability was cast (triggers swap back)
                shield_swap_helper:signal_ability_cast()
                return true
            end
        end
        return false

    else
        -- Still swapping - wait
        return true  -- Processing
    end
end

---@param player game_object
---@param target game_object
---@param menu table
---@param execute_pooling boolean
---@return boolean
local function try_sunder_leveling(player, target, menu, execute_pooling)
    if not player or not target or not menu then
        return false
    end
    if execute_pooling then
        return false
    end
    if not (menu.use_sunder_leveling and menu.use_sunder_leveling.get_state and menu.use_sunder_leveling:get_state()) then
        return false
    end
    if not spells.sunder_armor:is_learned() then
        return false
    end
    if not spells.sunder_armor:is_castable_to_unit(target) then
        return false
    end

    local min_rage = (menu.sunder_leveling_min_rage and menu.sunder_leveling_min_rage.get and menu.sunder_leveling_min_rage:get()) or 15
    if rage(player) < min_rage then
        return false
    end

    if menu.sunder_leveling_only_in_party and menu.sunder_leveling_only_in_party.get_state and menu.sunder_leveling_only_in_party:get_state() then
        if not is_in_party(player) then
            return false
        end
    end

    if menu.sunder_leveling_only_elite_or_boss and menu.sunder_leveling_only_elite_or_boss.get_state
        and menu.sunder_leveling_only_elite_or_boss:get_state() then
        if not is_elite_or_boss(target) then
            return false
        end
    end

    if menu.sunder_leveling_engaged_only and menu.sunder_leveling_engaged_only.get_state and menu.sunder_leveling_engaged_only:get_state() then
        if not engaged_only_filter(player, target, menu, "sunder_leveling_engaged_only") then
            return false
        end
    end

    local min_ttd = (menu.sunder_leveling_min_ttd and menu.sunder_leveling_min_ttd.get and menu.sunder_leveling_min_ttd:get()) or 0
    if min_ttd and min_ttd > 0 then
        local ttd = target:time_to_die() or 0
        if ttd > 0 and ttd < min_ttd then
            return false
        end
    end

    local desired = (menu.sunder_leveling_stacks and menu.sunder_leveling_stacks.get and menu.sunder_leveling_stacks:get()) or 2
    if desired < 0 then
        desired = 0
    end
    if desired > 5 then
        desired = 5
    end
    if desired <= 0 then
        return false
    end

    local stacks = get_debuff_stacks(target, spells.sunder_armor:id())
    if stacks >= desired then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_sunder_leveling_request_ms) < SUNDER_LEVELING_THROTTLE_MS then
        return false
    end
    last_sunder_leveling_request_ms = now_ms

    return spells.sunder_armor:cast(target) == true
end

---@param a vec3
---@param b vec3
---@return number
local function dist2(a, b)
    if not a or not b then
        return 1e9
    end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return (dx * dx) + (dy * dy) + (dz * dz)
end

---@param unit game_object
---@param debuff_id integer
---@return number stacks
get_debuff_stacks = function(unit, debuff_id)
    if not unit or not debuff_id then
        return 0
    end

    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or not debuffs or #debuffs == 0 then
        return 0
    end

    for _, debuff in ipairs(debuffs) do
        local id = debuff and debuff.buff_id
        if id and id == debuff_id then
            local count = debuff.count
            if type(count) == "number" and count > 0 then
                return count
            end
            return 1
        end
    end

    return 0
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_thunder_clap(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_thunder_clap and menu.tank_use_thunder_clap:get_state()) then
        return false
    end

    if not spells.thunder_clap:is_learned() then
        return false
    end

    enemy_count = enemy_count or count_enemies_around_player(player, 8)
    local min_enemies = (menu.tank_thunder_clap_min_enemies and menu.tank_thunder_clap_min_enemies.get and menu.tank_thunder_clap_min_enemies:get()) or 2
    if min_enemies < 1 then
        min_enemies = 1
    end
    if enemy_count < min_enemies then
        return false
    end

    if rage(player) < TANK_THUNDER_CLAP_MIN_RAGE then
        return false
    end

    local now_ms = core.game_time()
    if planned_stance_return_spell and now_ms > planned_stance_return_until_ms then
        planned_stance_return_spell = nil
        planned_stance_return_until_ms = 0
    end

    if not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    if target:debuff_down(spells.thunder_clap:id()) ~= true then
        return false
    end

    if (now_ms - last_thunder_clap_request_ms) < THUNDER_CLAP_THROTTLE_MS then
        return false
    end

    local allow_dance = menu.tank_allow_stance_dance_for_thunder_clap and menu.tank_allow_stance_dance_for_thunder_clap:get_state() == true
    local max_waste = (menu.tank_stance_dance_max_rage_waste and menu.tank_stance_dance_max_rage_waste.get and menu.tank_stance_dance_max_rage_waste:get()) or 0
    max_waste = clamp(max_waste, 0, 100)

    -- Forever permits Thunder Clap in Defensive Stance. Keep Era's opt-in dance.
    local can_cast_in_defensive = is_forever_client() and in_defensive_stance(player)
    if not in_battle_stance(player) and not can_cast_in_defensive then
        if not allow_dance then
            return false
        end

        if not allow_stance_dance_with_rage(player, menu, max_waste, 20) then
            return false
        end

        local current = current_stance_spell(player)
        if current and current ~= spells.battle_stance and current:is_learned() then
            planned_stance_return_spell = current
            planned_stance_return_until_ms = now_ms + 2500
        else
            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end

        last_thunder_clap_request_ms = now_ms
        local ok = try_set_stance(player, spells.battle_stance)
        if ok ~= true then
            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end
        return ok
    end

    if spells.thunder_clap:is_castable_to_unit(target) then
        last_thunder_clap_request_ms = now_ms
        if spells.thunder_clap:cast(target) then
            if planned_stance_return_spell then
                local delay_ms = (menu.stance_dance_return_delay_ms and menu.stance_dance_return_delay_ms.get and menu.stance_dance_return_delay_ms:get()) or 900
                local timeout_ms = (menu.stance_dance_return_timeout_ms and menu.stance_dance_return_timeout_ms.get and menu.stance_dance_return_timeout_ms:get()) or 2500
                delay_ms = clamp(delay_ms, 200, 2000)
                timeout_ms = clamp(timeout_ms, 800, 6000)
                schedule_stance_return(planned_stance_return_spell, now_ms, timeout_ms, now_ms + delay_ms)
                planned_stance_return_spell = nil
                planned_stance_return_until_ms = 0
            end
            return true
        end
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_mocking_blow(player, target, menu, threat_entry)
    if not player or not target or not menu then
        return false
    end

    -- Apply the same role protection and attack-first grace to forced targeting.
    if not pack_threat.can_taunt(threat_entry, menu) then return false end
    if not (menu.tank_use_mocking_blow and menu.tank_use_mocking_blow:get_state()) then
        return false
    end

    if not spells.mocking_blow:is_learned() then
        return false
    end

    -- Nur wenn Taunt NICHT verfügbar (auf CD oder nicht gelernt)
    if spells.taunt:is_learned() and spells.taunt:is_castable_to_unit(target) then
        return false
    end

    -- Prüfe ob Gegner NICHT uns angreift
    local ok, enemy_target = pcall(function()
        return target:get_target()
    end)
    if not ok or not enemy_target or (__object_safety.same(enemy_target,player)) then
        return false
    end

    -- Rage-Prüfung (für Stance-Dance + 10 Rage Kosten)
    local min_rage = (menu.tank_mocking_blow_min_rage and menu.tank_mocking_blow_min_rage.get and menu.tank_mocking_blow_min_rage:get()) or 20
    if rage(player) < min_rage then
        return false
    end

    local now_ms = core.game_time()
    local allow_dance = menu.tank_allow_stance_dance_for_mocking_blow and menu.tank_allow_stance_dance_for_mocking_blow:get_state() == true
    local max_waste = (menu.tank_stance_dance_max_rage_waste and menu.tank_stance_dance_max_rage_waste.get and menu.tank_stance_dance_max_rage_waste:get()) or 0
    max_waste = clamp(max_waste, 0, 100)

    -- Mocking Blow erfordert Battle Stance
    if not in_battle_stance(player) then
        if not allow_dance then
            return false
        end

        -- Speichere Defensive Stance für Rückkehr
        if not allow_stance_dance_with_rage(player, menu, max_waste, 10) then
            return false
        end

        local current = current_stance_spell(player)
        if current and current ~= spells.battle_stance and current:is_learned() then
            planned_stance_return_spell = current
            planned_stance_return_until_ms = now_ms + 2500
        else
            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end

        local ok = try_set_stance(player, spells.battle_stance)
        if ok ~= true then
            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end
        return ok
    end

    -- In Battle Stance: Cast Mocking Blow
    if spells.mocking_blow:is_castable_to_unit(target) then
        if spells.mocking_blow:cast(target) then
            if planned_stance_return_spell then
                local delay_ms = (menu.stance_dance_return_delay_ms and menu.stance_dance_return_delay_ms.get and menu.stance_dance_return_delay_ms:get()) or 900
                local timeout_ms = (menu.stance_dance_return_timeout_ms and menu.stance_dance_return_timeout_ms.get and menu.stance_dance_return_timeout_ms:get()) or 2500
                delay_ms = clamp(delay_ms, 200, 2000)
                timeout_ms = clamp(timeout_ms, 800, 6000)
                schedule_stance_return(planned_stance_return_spell, now_ms, timeout_ms, now_ms + delay_ms)
                planned_stance_return_spell = nil
                planned_stance_return_until_ms = 0
            end
            return true
        end
    end

    return false
end

---@param player game_object
---@param current_target game_object
---@param menu table
---@param range_yards number
---@param max_targets integer
---@return game_object[] enemies
local function get_nearest_engaged_enemies(player, current_target, menu, range_yards, max_targets)
    local enemies_out = {}
    if not player then
        return enemies_out
    end

    local pos = player:get_position()
    if not pos then
        return enemies_out
    end

    local range = range_yards or 10
    local enemies = performance:get_enemy_list_around(unit_helper, pos, range, true, false, false, false)
    if not enemies or #enemies == 0 then
        return enemies_out
    end

    local engaged_only = (menu.tank_tab_sunder_engaged_only and menu.tank_tab_sunder_engaged_only:get_state()) ~= false

    local tmp = {}
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy:is_valid_enemy() and enemy:is_alive() then
            if (not engaged_only) or engaged_only_filter(player, enemy, menu, "tank_tab_sunder_engaged_only") then
                local epos = enemy:get_position()
                table.insert(tmp, { enemy = enemy, d2 = dist2(pos, epos) })
            end
        end
    end

    table.sort(tmp, function(a, b)
        return (a.d2 or 0) < (b.d2 or 0)
    end)

    local limit = max_targets or 4
    if limit < 1 then
        limit = 1
    end

    -- Ensure current target is included if engaged and valid, even if slightly further.
    local has_current = false
    if current_target and current_target:is_valid_enemy() and current_target:is_alive() then
        if (not engaged_only) or engaged_only_filter(player, current_target, menu, "tank_tab_sunder_engaged_only") then
            has_current = true
        end
    end

    for _, entry in ipairs(tmp) do
        if #enemies_out >= limit then
            break
        end
        enemies_out[#enemies_out + 1] = entry.enemy
    end

    if has_current then
        local present = false
        for _, e in ipairs(enemies_out) do
            if (__object_safety.same(e,current_target)) then
                present = true
                break
            end
        end
        if not present then
            enemies_out[#enemies_out + 1] = current_target
        end
    end

    return enemies_out
end

---@param player game_object
---@param current_target game_object
---@param menu table
---@return game_object|nil
local function find_best_tab_sunder_target(player, current_target, menu, enemy_count, pack)
    if not player or not current_target or not menu then
        return nil
    end

    if not (menu.tank_tab_sunder_enabled and menu.tank_tab_sunder_enabled:get_state()) then
        return nil
    end

    if not spells.sunder_armor:is_learned() then
        return nil
    end

    enemy_count = enemy_count or count_enemies_around_player(player, 8)
    local min_enemies = (menu.tank_tab_sunder_min_enemies and menu.tank_tab_sunder_min_enemies.get and menu.tank_tab_sunder_min_enemies:get()) or 2
    if min_enemies < 2 then
        min_enemies = 2
    end
    if enemy_count < min_enemies then
        return nil
    end

    local desired = (menu.tank_tab_sunder_stacks and menu.tank_tab_sunder_stacks.get and menu.tank_tab_sunder_stacks:get()) or 2
    desired = clamp(desired, 0, 5)

    -- Dynamische Stack-Anpassung: Bei großen Pulls (5+) weniger Stacks pro Mob für bessere Aggro-Verteilung
    if enemy_count >= 5 then
        desired = math.min(desired, 1)
    end

    if desired <= 0 then
        return nil
    end

    local range = (menu.tank_tab_sunder_range and menu.tank_tab_sunder_range.get and menu.tank_tab_sunder_range:get()) or 10
    range = clamp(range, 5, 20)

    local max_targets = (menu.tank_tab_sunder_max_targets and menu.tank_tab_sunder_max_targets.get and menu.tank_tab_sunder_max_targets:get()) or 4
    max_targets = clamp(max_targets, 1, 10)

    if pack then
        -- Threat urgency outranks stack count and current-target preference.
        -- Recovery can refresh a full stack to generate threat immediately.
        for _, entry in ipairs(pack.attacks) do
            if entry.d2 <= range*range then
                local stacks = get_debuff_stacks(entry.unit, spells.sunder_armor:id())
                if (entry.priority>=200 or stacks<desired) and spells.sunder_armor:is_castable_to_unit(entry.unit) then
                    return entry.unit
                end
            end
        end
        return nil
    end

    local candidates = get_nearest_engaged_enemies(player, current_target, menu, range, max_targets)
    if not candidates or #candidates == 0 then
        return nil
    end

    local best = nil
    local best_stacks = nil
    for _, enemy in __object_safety.live_ipairs(candidates) do
        local stacks = get_debuff_stacks(enemy, spells.sunder_armor:id())
        if stacks < desired then
            if (__object_safety.same(enemy,current_target)) then
                return enemy
            end
            if best_stacks == nil or stacks < best_stacks then
                best = enemy
                best_stacks = stacks
            end
        end
    end

    return best
end

---@param menu table
---@return integer, integer
local function get_interrupt_delay_pct_range(menu)
    local min_pct = (menu and menu.interrupt_delay_min_pct and menu.interrupt_delay_min_pct:get()) or 10
    local max_pct = (menu and menu.interrupt_delay_max_pct and menu.interrupt_delay_max_pct:get()) or 35

    min_pct = clamp(min_pct, 0, 100)
    max_pct = clamp(max_pct, 0, 100)
    if max_pct < min_pct then
        max_pct = min_pct
    end

    return min_pct, max_pct
end

---@param menu table
---@return number
local function interrupt_range(menu)
    return (menu and menu.interrupt_range and menu.interrupt_range:get()) or 10
end

---@param menu table
---@return integer
local function interrupt_fast_cast_ms(menu)
    return (menu and menu.interrupt_fast_cast_ms and menu.interrupt_fast_cast_ms:get()) or 450
end

---@param player game_object
---@param target game_object
---@param menu table
---@param is_tank_mode boolean
---@return boolean acted, boolean completed_interrupt
local function try_interrupt(player, target, menu, is_tank_mode)
    if not player or not target or not menu then
        return false, false
    end

    local now_ms = core.game_time()
    if (now_ms - last_interrupt_request_ms) < INTERRUPT_THROTTLE_MS then
        return false, false
    end

    if planned_interrupt_return_spell and now_ms > planned_interrupt_return_until_ms then
        planned_interrupt_return_spell = nil
        planned_interrupt_return_until_ms = 0
    end

    local use_shield_bash = (menu.use_shield_bash and menu.use_shield_bash:get_state()) ~= false
    local use_pummel = (menu.use_pummel and menu.use_pummel:get_state()) ~= false

    -- Prefer an interrupt that works with the equipment/stance already active.
    if use_shield_bash and spells.shield_bash:is_learned() and spells.shield_bash:is_castable_to_unit(target) then
        if try_shield_ability_with_swap(player, target, menu, spells.shield_bash, "Shield Bash") then
            last_interrupt_request_ms = now_ms
            return true, true
        end
    end

    if use_pummel and spells.pummel:is_learned() and spells.pummel:is_castable_to_unit(target) then
        last_interrupt_request_ms = now_ms
        if spells.pummel:cast(target) == true then
            if planned_interrupt_return_spell then
                local delay_ms = (menu.stance_dance_return_delay_ms and menu.stance_dance_return_delay_ms.get and menu.stance_dance_return_delay_ms:get()) or 900
                local timeout_ms = (menu.stance_dance_return_timeout_ms and menu.stance_dance_return_timeout_ms.get and menu.stance_dance_return_timeout_ms:get()) or 2500
                delay_ms = clamp(delay_ms, 200, 2000)
                timeout_ms = clamp(timeout_ms, 800, 6000)
                schedule_stance_return(planned_interrupt_return_spell, now_ms, timeout_ms, now_ms + delay_ms)
                planned_interrupt_return_spell = nil
                planned_interrupt_return_until_ms = 0
            end
            return true, true
        end
        return false, true
    end

    -- A shield swap is a fallback after an already-castable Pummel.
    if use_shield_bash and spells.shield_bash:is_learned() then
        if try_shield_ability_with_swap(player, target, menu, spells.shield_bash, "Shield Bash") then
            last_interrupt_request_ms = now_ms
            return true, true
        end
    end

    if not use_pummel or not spells.pummel:is_learned() then
        return false, false
    end

    local allow_dance = menu.allow_stance_dance_for_pummel and menu.allow_stance_dance_for_pummel:get_state() == true
    local allow_dance_tank = menu.allow_stance_dance_for_pummel_in_tank_mode and menu.allow_stance_dance_for_pummel_in_tank_mode:get_state() == true
    if is_tank_mode and not allow_dance_tank then
        return false, false
    end

    if allow_dance and not in_berserker_stance(player) and spells.berserker_stance:is_learned() then
        local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste.get and menu.interrupt_stance_dance_max_rage_waste:get()) or 0
        max_waste = clamp(max_waste, 0, 100)
        if not allow_stance_dance_with_rage(player, menu, max_waste, 10) then
            return false, false
        end

        local return_to = current_stance_spell(player)
        last_interrupt_request_ms = now_ms
        if return_to and return_to ~= spells.berserker_stance then
            planned_interrupt_return_spell = return_to
            planned_interrupt_return_until_ms = now_ms + 2500
        else
            planned_interrupt_return_spell = nil
            planned_interrupt_return_until_ms = 0
        end

        if try_set_stance(player, spells.berserker_stance) == true then
            return true, false
        end

        planned_interrupt_return_spell = nil
        planned_interrupt_return_until_ms = 0
    end

    return false, false
end

---@param player game_object
---@param current_target game_object|nil
---@param menu table
---@return game_object|nil
local function select_interrupt_target(player, current_target, menu)
    if not player or not menu then
        return nil
    end

    local mode = (menu.interrupt_target_mode and menu.interrupt_target_mode.get and menu.interrupt_target_mode:get()) or 2
    local range = interrupt_range(menu)

    if mode == 1 then
        if current_target and current_target:is_valid_enemy() and current_target:is_alive() then
            if current_target:is_casting_spell() and current_target:is_active_spell_interruptable() then
                if engaged_only_filter(player, current_target, menu, "interrupt_engaged_only") then
                    return current_target
                end
            end
        end
        return nil
    end

    if current_target and current_target:is_valid_enemy() and current_target:is_alive() then
        if current_target:is_casting_spell() and current_target:is_active_spell_interruptable() then
            if engaged_only_filter(player, current_target, menu, "interrupt_engaged_only") then
                return current_target
            end
        end
    end

    local best, _ = interrupt_targeting.find_best_interrupt_target(player, range, function(enemy)
        return engaged_only_filter(player, enemy, menu, "interrupt_engaged_only")
    end)
    return best
end

---@param player game_object
---@param current_target game_object|nil
---@param menu table
---@param is_tank_mode boolean
---@return boolean
local function try_auto_interrupt(player, current_target, menu, is_tank_mode)
    if not player or not menu then
        return false
    end

    if not player:is_in_combat() then
        pending_interrupt_target = nil
        pending_interrupt_cast_end = 0.0
        pending_interrupt_pct = 0.0
        return false
    end

    if not (menu.auto_interrupt and menu.auto_interrupt:get_state()) then
        pending_interrupt_target = nil
        pending_interrupt_cast_end = 0.0
        pending_interrupt_pct = 0.0
        return false
    end

    local target = select_interrupt_target(player, current_target, menu)
    if not target then
        pending_interrupt_target = nil
        pending_interrupt_cast_end = 0.0
        pending_interrupt_pct = 0.0
        return false
    end

    local pct, time_left, cast_end = get_cast_pct_and_time_left(target)
    if cast_end <= 0.0 then
        return false
    end

    local fast_ms = interrupt_fast_cast_ms(menu)
    if (time_left * 1000.0) <= fast_ms then
        local acted, completed = try_interrupt(player, target, menu, is_tank_mode)
        if acted then
            if completed then
                pending_interrupt_target = nil
                pending_interrupt_cast_end = 0.0
                pending_interrupt_pct = 0.0
            else
                pending_interrupt_target = target
                pending_interrupt_cast_end = cast_end
                pending_interrupt_pct = 0.0
            end
            return true
        end
        return false
    end

    if (not __object_safety.same(pending_interrupt_target,target)) or pending_interrupt_cast_end ~= cast_end then
        pending_interrupt_target = target
        pending_interrupt_cast_end = cast_end

        local min_pct, max_pct = get_interrupt_delay_pct_range(menu)
        pending_interrupt_pct = math.random(min_pct, max_pct)
    end

    if pct >= pending_interrupt_pct then
        local acted, completed = try_interrupt(player, target, menu, is_tank_mode)
        if acted then
            if completed then
                pending_interrupt_target = nil
                pending_interrupt_cast_end = 0.0
                pending_interrupt_pct = 0.0
            else
                pending_interrupt_target = target
                pending_interrupt_cast_end = cast_end
                pending_interrupt_pct = 0.0
            end
            return true
        end
        return false
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_rage_dump(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    local current_rage = rage(player)
    local threshold = (menu.rage_dump_threshold and menu.rage_dump_threshold.get and menu.rage_dump_threshold:get()) or 55
    if current_rage < threshold then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_rage_dump_request_ms) < RAGE_DUMP_THROTTLE_MS then
        return false
    end

    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true
    enemy_count = enemy_count or count_enemies_around_player(player, 8)

    if aoe_enabled and enemy_count >= 2 then
        if menu.use_cleave and menu.use_cleave:get_state() and spells.cleave:is_learned() then
            if spells.cleave:is_castable_to_unit(target) then
                last_rage_dump_request_ms = now_ms
                return spells.cleave:cast(target) == true
            end
        end
    end

    if menu.use_heroic_strike and menu.use_heroic_strike:get_state() and spells.heroic_strike:is_learned() then
        if spells.heroic_strike:is_castable_to_unit(target) then
            last_rage_dump_request_ms = now_ms
            return spells.heroic_strike:cast(target) == true
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@return boolean
local function try_emergency_items(player, menu)
    if not player or not menu then
        return false
    end

    if menu.use_healthstones and menu.use_healthstones.get_state and menu.use_healthstones:get_state() then
        local threshold = (menu.healthstone_hp_pct and menu.healthstone_hp_pct.get and menu.healthstone_hp_pct:get()) or 35
        local hp_pct = player:get_health_percentage() or 100
        if hp_below(hp_pct, threshold) then
            if healthstone_item and healthstone_item.in_inventory and healthstone_item:in_inventory() then
                if healthstone_item:use_self_safe("Healthstone") then
                    return true
                end
            end
        end
    end

    if menu.use_hp_potions and menu.use_hp_potions:get_state() then
        local threshold = (menu.hp_potion_hp_pct and menu.hp_potion_hp_pct:get()) or 35
        local hp_pct = player:get_health_percentage() or 100
        if hp_below(hp_pct, threshold) then
            if izi.use_best_health_potion_safe and izi.use_best_health_potion_safe() then
                return true
            end
        end
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param enemy_count integer
---@return boolean
local function try_defensives(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    local hp_pct = player:get_health_percentage() or 100

    local hold_emergency_defensive = update_emergency_defensive_hold(menu, hp_pct)
    if hold_emergency_defensive and not in_defensive_stance(player) then
        return try_set_stance(player, spells.defensive_stance)
    end

    if hold_emergency_defensive then
        if pending_stance_return_spell and pending_stance_return_spell ~= spells.defensive_stance then
            clear_pending_stance_return()
        end
        if planned_stance_return_spell and planned_stance_return_spell ~= spells.defensive_stance then
            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end
        if planned_interrupt_return_spell and planned_interrupt_return_spell ~= spells.defensive_stance then
            planned_interrupt_return_spell = nil
            planned_interrupt_return_until_ms = 0
        end
    end

    if menu.use_last_stand and menu.use_last_stand:get_state() and spells.last_stand:is_learned() then
        local threshold = (menu.last_stand_hp_pct and menu.last_stand_hp_pct:get()) or 25
        if hp_below(hp_pct, threshold) then
            if spells.last_stand:is_castable_to_unit(player) then
                if spells.last_stand:cast(player) then
                    return true
                end
            elseif spells.defensive_stance and spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
                return try_set_stance(player, spells.defensive_stance)
            end
        end
    end

    if menu.use_shield_wall and menu.use_shield_wall:get_state() and spells.shield_wall:is_learned() then
        local threshold = (menu.shield_wall_hp_pct and menu.shield_wall_hp_pct:get()) or 18
        if hp_below(hp_pct, threshold) then
            if spells.defensive_stance and spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
                return try_set_stance(player, spells.defensive_stance)
            end
            -- Let the helper acquire a shield when starting from a two-hander.
            if try_shield_ability_with_swap(player, player, menu, spells.shield_wall, "Shield Wall") then
                return true
            end
        end
    end

    if enemy_count >= 2 then
        if spells.retaliation:is_learned() then
            local threshold = (menu.retaliation_hp_pct and menu.retaliation_hp_pct.get and menu.retaliation_hp_pct:get()) or 55
            if hp_below(hp_pct, threshold) then
                if spells.retaliation:is_castable({ skip_facing = true }) and spells.retaliation:cast(player) then
                    return true
                end
            end
        end
    end

    if (menu.intimidating_shout_enabled ~= false) and spells.intimidating_shout:is_learned() then
        local threshold = (menu.intimidating_shout_hp_pct and menu.intimidating_shout_hp_pct.get and menu.intimidating_shout_hp_pct:get()) or 20
        if hp_below(hp_pct, threshold) then
            if spells.intimidating_shout:is_castable() and spells.intimidating_shout:cast(target) then
                return true
            end
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@return boolean
local function try_keep_battle_shout(player, menu)
    if not player or not menu then
        return false
    end

    if not (menu.keep_battle_shout and menu.keep_battle_shout:get_state()) then
        return false
    end

    if not spells.battle_shout:is_learned() then
        return false
    end

    if player:buff_down(spells.battle_shout:id()) then
        return (spells.battle_shout:is_castable({ skip_facing = true }) and spells.battle_shout:cast(player)) == true
    end

    return false
end

local function within_melee_range(player, unit)
    if not player or not unit then
        return false
    end

    local player_pos = player:get_position()
    local unit_pos = unit:get_position()
    if not player_pos or not unit_pos then
        return false
    end

    local distance_sq = dist2(player_pos, unit_pos)
    return distance_sq <= (8 * 8)
end

local function try_tank_bloodrage(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if enemy_count and enemy_count >= 3 then
        return false
    end

    if not is_elite_or_boss(target) then
        return false
    end

    if not (menu.use_bloodrage and menu.use_bloodrage:get_state()) or not spells.bloodrage or not spells.bloodrage:is_learned() then
        return false
    end

    local min_rage = (menu.bloodrage_rage_below and menu.bloodrage_rage_below:get()) or 10
    local min_hp = (menu.bloodrage_min_hp_pct and menu.bloodrage_min_hp_pct:get()) or 65
    local hp_pct = player:get_health_percentage() or 100

    if hp_pct < min_hp then
        return false
    end

    if rage(player) <= min_rage then
        if spells.bloodrage:is_castable({ skip_facing = true }) and spells.bloodrage:cast(player) then
            return true
        end
    end

    return false
end

local function try_tank_aoe_opener(player, target, menu, enemy_count)
    if not player or not target or not menu or not enemy_count then
        return false
    end

    if enemy_count < 3 then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_tank_aoe_opener_ms) < TANK_AOE_OPENER_THROTTLE_MS then
        return false
    end

    if spells.defensive_stance and spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
        if try_set_stance(player, spells.defensive_stance) then
            last_tank_aoe_opener_ms = now_ms
            return true
        end
    end

    if menu.tank_use_demoralizing_shout and menu.tank_use_demoralizing_shout:get_state() and spells.demoralizing_shout and spells.demoralizing_shout:is_learned() and within_melee_range(player, target) then
        if target:debuff_down(spells.demoralizing_shout:id()) then
            if spells.demoralizing_shout:is_castable_to_unit(target) then
                if spells.demoralizing_shout:cast(target) then
                    last_tank_aoe_opener_ms = now_ms
                    return true
                end
            end
        end
    end

    if menu.keep_battle_shout and menu.keep_battle_shout:get_state() and spells.battle_shout and spells.battle_shout:is_learned() then
        local ok_party, party_members = pcall(function()
            return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
        end)
        local total_members = (ok_party and party_members and #party_members) or 0
        if (total_members + 1) >= 3 then
            if try_keep_battle_shout(player, menu) then
                last_tank_aoe_opener_ms = now_ms
                return true
            end
        end
    end

    return false
end

local function try_tank_tabbed_revenge(player, target, menu, pack)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_revenge and menu.tank_use_revenge:get_state()) then
        return false
    end

    if not spells.revenge or not spells.revenge:is_learned() then
        return false
    end

    local ordered = {}
    if pack then
        for _, entry in ipairs(pack.attacks) do ordered[#ordered+1]=entry.unit end
    else
        ordered[1]=target
        local candidates = get_nearest_engaged_enemies(player, target, menu, 12, 6)
        for _, enemy in __object_safety.live_ipairs(candidates or {}) do
            if enemy and (not __object_safety.same(enemy,target)) then ordered[#ordered+1]=enemy end
        end
    end

    local seen = {}
    for _, enemy in __object_safety.live_ipairs(ordered) do
        if enemy and not seen[enemy] then
            seen[enemy] = true
            if spells.revenge:is_castable_to_unit(enemy) then
                if spells.revenge:cast(enemy) then
                    return true
                end
            end
        end
    end

    return false
end

local function try_tank_cleave_spend(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end
    if not (menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state()) then
        return false
    end
    if enemy_count < 2 then
        return false
    end
    if not (menu.use_cleave and menu.use_cleave:get_state()) then
        return false
    end
    if not spells.cleave or not spells.cleave:is_learned() then
        return false
    end
    if rage(player) <= TANK_CLEAVE_RAGE_THRESHOLD then
        return false
    end
    if spells.cleave:is_castable_to_unit(target) then
        return spells.cleave:cast(target) == true
    end

    return false
end

local try_cast_devastate

local function try_tank_single_target_finish(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if enemy_count >= 3 then
        return false
    end

    if not is_elite_or_boss(target) then
        return false
    end

    if not (menu.tank_use_devastate and menu.tank_use_devastate:get_state()) then
        return false
    end

    if not spells.devastate or not spells.devastate:is_learned() then
        return false
    end

    if not spells.sunder_armor or not spells.sunder_armor:is_learned() then
        return false
    end

    local stacks = get_debuff_stacks(target, spells.sunder_armor:id())
    if stacks < 5 then
        return false
    end

    return try_cast_devastate(player, target)
end

---@param player game_object
---@param target game_object
---@return boolean
try_cast_devastate = function(player, target)
    if not player or not target or not spells.devastate then
        return false
    end

    if not spells.devastate:is_learned() then
        return false
    end

    if not spells.devastate:is_castable_to_unit(target) then
        return false
    end

    return spells.devastate:cast(target) == true
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local last_leveling_rend_ms = -math.huge

local function try_leveling_rend_target(player, target, menu)
    if not target or target:debuff_down(spells.rend:id()) ~= true then return false end
    local ok_ct, creature = pcall(function() return target:get_creature_type() end)
    if ok_ct and creature and (creature==enums.creature_type.MECHANICAL or creature==enums.creature_type.ELEMENTAL) then return false end
    local hp = target:get_health_percentage() or 100
    local execute_hp = (menu.execute_hp_pct and menu.execute_hp_pct:get()) or 20
    if hp<=execute_hp then return false end
    local min_ttd = (menu.rend_min_ttd and menu.rend_min_ttd:get()) or 6
    local ok_ttd, ttd = pcall(function() return tonumber(target:time_to_die()) end)
    if min_ttd>0 and not (ok_ttd and ttd and ttd>0 and ttd<math.huge and ttd>=min_ttd) then return false end
    local now=core.game_time()
    if now-last_leveling_rend_ms<450 then return false end
    if spells.rend:is_castable_to_unit(target) and spells.rend:cast(target)==true then
        last_leveling_rend_ms=now
        return true
    end
    return false
end

local function try_leveling_rend_spread(player, current_target, menu, pack)
    local limit=(menu.leveling_rend_max_targets and menu.leveling_rend_max_targets:get()) or 4
    limit=math.max(1,math.min(8,limit))
    local ordered={}
    local current=pack.by_unit[current_target]
    if current and not current.protected and current.d2<=64 then ordered[1]=current_target end
    for _, entry in ipairs(pack.attacks) do
        if (not __object_safety.same(entry.unit,current_target)) then ordered[#ordered+1]=entry.unit end
    end
    for i=1,math.min(limit,#ordered) do
        if try_leveling_rend_target(player,ordered[i],menu) then return true end
    end
    return false
end

local function try_leveling_pack_thunder_clap(player, menu, pack)
    if not menu.leveling_use_thunder_clap or not menu.leveling_use_thunder_clap:get_state() then return false end
    if not menu.enable_aoe or not menu.enable_aoe:get_state() then return false end
    if not spells.thunder_clap or not spells.thunder_clap:is_learned() then return false end
    local min_enemies=(menu.leveling_thunder_clap_min_enemies and menu.leveling_thunder_clap_min_enemies:get()) or 2
    if not pack.aoe_safe or #pack.attacks<math.max(1,min_enemies) then return false end
    if rage(player)<TANK_THUNDER_CLAP_MIN_RAGE then return false end
    if not in_battle_stance(player) and not (is_forever_client() and in_defensive_stance(player)) then return false end
    local now=core.game_time()
    if now-last_thunder_clap_request_ms<THUNDER_CLAP_THROTTLE_MS then return false end
    for _, entry in ipairs(pack.attacks) do
        local target=entry.unit
        if target:debuff_down(spells.thunder_clap:id())==true and spells.thunder_clap:is_castable_to_unit(target) then
            last_thunder_clap_request_ms=now
            return spells.thunder_clap:cast(target)==true
        end
    end
    return false
end

local function has_equipped_shield(player)
    if not shield_swap_helper.detect_current_equipment then return false end
    local ok, equipment = pcall(function() return shield_swap_helper:detect_current_equipment(player) end)
    return ok and equipment and equipment.has_shield_equipped == true
end

-- Routine offense only uses an equipped shield. Emergency/interrupt swaps keep
-- their separate state machine and restore the original setup afterward.
local function try_leveling_shield_attack(player, target, menu, equipped_shield, pooling)
    if pooling then return false end
    -- Let runtime castability decide Revenge's proc/stance requirements.
    if menu.leveling_use_revenge and menu.leveling_use_revenge:get_state() and spells.revenge and spells.revenge:is_learned() then
        if spells.revenge:is_castable_to_unit(target) and spells.revenge:cast(target) == true then return true end
    end
    if equipped_shield and menu.leveling_use_shield_slam and menu.leveling_use_shield_slam:get_state() and spells.shield_slam and spells.shield_slam:is_learned() then
        if spells.shield_slam:is_castable_to_unit(target) and spells.shield_slam:cast(target) == true then return true end
    end
    return false
end

-- Shield Block is supplementary mitigation, not a reason to swap weapons or
-- delay a ready Revenge/primary strike. Costs below are conservative base rage
-- costs verified against the local Forever SpellPower table (raw cost / 10).
local last_leveling_shield_block_ms=-math.huge
local LEVELING_PRIMARY_RAGE={
    {"leveling_use_shield_slam","shield_slam",20},
    {"use_bloodthirst","bloodthirst",30},
    {"use_mortal_strike","mortal_strike",30}
}
local function try_leveling_shield_block(player,target,menu,equipped_shield,pooling,enemy_count)
    if not equipped_shield or pooling or not menu.leveling_use_shield_block
        or not menu.leveling_use_shield_block:get_state() then return false end
    local block=spells.shield_block
    if not block or not block:is_learned() or not in_defensive_stance(player)
        or enemy_count<1 or has_aura_id(player,block:id()) then return false end
    if block.cooldown_up and block:cooldown_up()==false then return false end
    local now=core.game_time()
    if now>=last_leveling_shield_block_ms and now-last_leveling_shield_block_ms<450 then return false end

    -- Keep a small early-level attack budget (e.g. Rend), then reserve the
    -- most expensive selected primary rather than adding mutually exclusive
    -- talent attacks together. Reserve Revenge separately for a new proc.
    local primary=10
    for _,entry in ipairs(LEVELING_PRIMARY_RAGE) do
        local option,spell=menu[entry[1]],spells[entry[2]]
        if option and option:get_state() and spell and spell:is_learned() then
            primary=math.max(primary,entry[3])
        end
    end
    local min_enemies=(menu.leveling_thunder_clap_min_enemies and menu.leveling_thunder_clap_min_enemies:get()) or 2
    if menu.enable_aoe and menu.enable_aoe:get_state() and menu.leveling_use_thunder_clap
        and menu.leveling_use_thunder_clap:get_state() and enemy_count>=math.max(1,min_enemies)
        and spells.thunder_clap and spells.thunder_clap:is_learned() then
        primary=math.max(primary,TANK_THUNDER_CLAP_MIN_RAGE)
    end
    local revenge=0
    if menu.leveling_use_revenge and menu.leveling_use_revenge:get_state()
        and spells.revenge and spells.revenge:is_learned() then revenge=5 end
    if rage(player)<10+revenge+primary then return false end
    -- Cast directly: this routine must never start a shield/weapon swap.
    if block:is_castable_to_unit(player) and block:cast(player)==true then
        last_leveling_shield_block_ms=now
        return true
    end
    return false
end


local last_next_target_request_ms=-math.huge
local function next_leveling_target(player,menu)
    if not menu.leveling_auto_next_target or not menu.leveling_auto_next_target:get_state() then return nil end
    -- Never override a living selection, including a friendly unit selected
    -- deliberately. This routine is called only while actually in combat.
    local selected=player:get_target()
    if __object_safety.valid(selected) then
        local ok,alive=pcall(selected.is_alive,selected)
        if ok and alive then return nil end
    end
    local now=core.game_time()
    if now>=last_next_target_request_ms and now-last_next_target_request_ms<450 then return nil end
    local pack=pack_threat.assess(player,nil,menu)
    local best,best_ours,best_distance=nil,false,math.huge
    for _,entry in ipairs(pack.attacks or {}) do
        local unit=entry.unit
        local ok,usable=pcall(function()
            return not entry.protected and __object_safety.valid(unit) and unit:is_valid_enemy()
                and unit:is_alive() and not (unit.is_cc_weak and unit:is_cc_weak())
                and not (unit.is_damage_immune and unit.DMG and unit:is_damage_immune(unit.DMG.PHYSICAL))
        end)
        if ok and usable and entry.d2 and entry.d2<=64 then
            local ours=__object_safety.same(entry.victim,player)
            if not best or (ours and not best_ours) or (ours==best_ours and entry.d2<best_distance) then
                best,best_ours,best_distance=unit,ours,entry.d2
            end
        end
    end
    if not best or not core.input or not core.input.set_target then return nil end
    last_next_target_request_ms=now
    local ok,changed=pcall(core.input.set_target,best)
    if not ok then
        if __object_safety.is_invalid_error(changed) then return nil end
        error(changed,0)
    end
    if changed==true then return best end
    return nil
end


local last_victory_rush_request_ms=-math.huge
local function try_victory_rush(player,target,menu)
    if not menu.use_victory_rush or not menu.use_victory_rush:get_state() then return false end
    local spell=spells.victory_rush
    if not spell or not __object_safety.valid(target) then return false end
    if target.is_cc_weak and target:is_cc_weak() then return false end
    local now=core.game_time()
    if now>=last_victory_rush_request_ms and now-last_victory_rush_request_ms<450 then return false end
    -- SDK castability checks learned/granted availability, the kill proc,
    -- range, facing, cooldown and resources. Do not impose an HP threshold:
    -- it is also a free attack and the usable window must not be wasted.
    if spell:is_castable_to_unit(target) then
        last_victory_rush_request_ms=now
        return spell:cast(target)==true
    end
    return false
end


local function try_leveling_rotation(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    local enemy_count = count_enemies_around_player(player, 8)
    local equipped_shield = has_equipped_shield(player)

    if try_defensives(player, target, menu, enemy_count) then
        return true
    end

    if try_victory_rush(player,target,menu) then return true end

    if try_hamstring_on_humanoid_low_hp(player, menu) then
        return true
    end

    if try_hamstring_on_target_loss(player, menu) then
        return true
    end

    if menu.auto_battle_stance and menu.auto_battle_stance:get_state() and not emergency_defensive_hold then
        local shield_defensive = equipped_shield and menu.leveling_shield_defensive_stance
            and menu.leveling_shield_defensive_stance:get_state() and spells.defensive_stance:is_learned()
        local preferred = shield_defensive and spells.defensive_stance or spells.battle_stance
        local already_active = shield_defensive and in_defensive_stance(player) or (not shield_defensive and in_battle_stance(player))
        if preferred and preferred:is_learned() and not already_active then
            if try_set_stance(player, preferred) then return true end
        end
    end

    if try_keep_battle_shout(player, menu) then
        return true
    end

    if menu.use_bloodrage and menu.use_bloodrage:get_state() and spells.bloodrage:is_learned() then
        local min_rage = (menu.bloodrage_rage_below and menu.bloodrage_rage_below:get()) or 10
        local min_hp = (menu.bloodrage_min_hp_pct and menu.bloodrage_min_hp_pct:get()) or 65
        if rage(player) <= min_rage and (player:get_health_percentage() or 100) >= min_hp then
            if spells.bloodrage:is_castable({ skip_facing = true }) and spells.bloodrage:cast(player) then
                return true
            end
        end
    end

    -- Overpower "sniping" - should be used immediately when available.
    if menu.use_overpower and menu.use_overpower:get_state() and spells.overpower:is_learned() then
        if spells.overpower:is_castable_to_unit(target) then
            if spells.overpower:cast(target) then
                return true
            end
        end
    end

    -- Execute pooling (optional): stop spending rage before execute range, then execute with high rage.
    local execute_pooling = false
    if menu.execute_pool_enabled and menu.execute_pool_enabled.get_state and menu.execute_pool_enabled:get_state() then
        if menu.use_execute and menu.use_execute:get_state() and spells.execute:is_learned() then
            local pool_start = (menu.execute_pool_start_hp_pct and menu.execute_pool_start_hp_pct.get and menu.execute_pool_start_hp_pct:get()) or 30
            local hp_pct = target:get_health_percentage() or 100
            local pool_goal = (menu.execute_pool_min_rage and menu.execute_pool_min_rage:get()) or 60
            if hp_pct <= pool_start and rage(player) < pool_goal then
                execute_pooling = true
            end
        end
    end

    if menu.use_execute and menu.use_execute:get_state() and spells.execute:is_learned() then
        local hp_pct = target:get_health_percentage() or 100
        local threshold = (menu.execute_hp_pct and menu.execute_hp_pct:get()) or 20
        if hp_pct <= threshold then
            if execute_pooling then
                local min_rage = (menu.execute_pool_min_rage and menu.execute_pool_min_rage.get and menu.execute_pool_min_rage:get()) or 60
                local ok_ttd, ttd = pcall(function() return target:time_to_die() end)
                ttd = ok_ttd and tonumber(ttd) or nil
                -- Pool only with a usable estimate and time to spend the rage.
                -- Unknown, non-finite, or short lifetimes must not delay Execute.
                local can_wait = hp_pct > 5 and ttd and ttd > 3 and ttd < math.huge
                if rage(player) < min_rage and can_wait then
                    -- Hold rage; do not spend on dumps below.
                    goto execute_skip
                end
            end
            if spells.execute:is_castable_to_unit(target) then
                if spells.execute:cast(target) then
                    return true
                end
            end
        end
        ::execute_skip::
    end

    if try_leveling_shield_attack(player, target, menu, equipped_shield, execute_pooling) then
        return true
    end

    if menu.use_bloodthirst and menu.use_bloodthirst:get_state() and spells.bloodthirst and spells.bloodthirst:is_learned() then
        local hold_primary = execute_pooling and menu.execute_pool_skip_mortal_strike and menu.execute_pool_skip_mortal_strike:get_state()
        if not hold_primary and spells.bloodthirst:is_castable_to_unit(target) and spells.bloodthirst:cast(target) == true then
            return true
        end
    end

    if menu.use_mortal_strike and menu.use_mortal_strike:get_state() and spells.mortal_strike:is_learned() then
        if not execute_pooling or not (menu.execute_pool_skip_mortal_strike and menu.execute_pool_skip_mortal_strike.get_state and menu.execute_pool_skip_mortal_strike:get_state()) then
        if spells.mortal_strike:is_castable_to_unit(target) then
            if spells.mortal_strike:cast(target) then
                return true
            end
        end
        end
    end

    if try_leveling_shield_block(player,target,menu,equipped_shield,execute_pooling,enemy_count) then
        return true
    end

    -- Optional Sunder follows primary attacks instead of delaying them.
    if try_sunder_leveling(player, target, menu, execute_pooling) then return true end

    local leveling_pack=nil
    if equipped_shield and not execute_pooling then
        local want_clap=menu.leveling_use_thunder_clap and menu.leveling_use_thunder_clap:get_state()
        local want_rend=menu.leveling_spread_rend and menu.leveling_spread_rend:get_state()
        if want_clap or want_rend then leveling_pack=pack_threat.assess(player,target,menu) end
        if leveling_pack and try_leveling_pack_thunder_clap(player,menu,leveling_pack) then return true end
    end

    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true
    local aoe_min = (menu.aoe_min_enemies and menu.aoe_min_enemies.get and menu.aoe_min_enemies:get()) or 2

    if aoe_enabled and enemy_count >= aoe_min then
        if menu.use_sweeping_strikes and menu.use_sweeping_strikes:get_state() and spells.sweeping_strikes:is_learned() then
            if execute_pooling and (menu.execute_pool_skip_aoe and menu.execute_pool_skip_aoe.get_state and menu.execute_pool_skip_aoe:get_state()) then
                goto skip_sweeping
            end
            if spells.sweeping_strikes:is_castable({ skip_facing = true }) and spells.sweeping_strikes:cast(player) then
                return true
            end
            ::skip_sweeping::
        end
    end

    if aoe_enabled and enemy_count >= aoe_min then
        if menu.use_whirlwind and menu.use_whirlwind:get_state() and spells.whirlwind:is_learned() then
            if execute_pooling and (menu.execute_pool_skip_aoe and menu.execute_pool_skip_aoe.get_state and menu.execute_pool_skip_aoe:get_state()) then
                goto skip_whirlwind
            end
            if spells.whirlwind:is_castable_to_unit(target) then
                if spells.whirlwind:cast(target) then
                    return true
                end
            end
            ::skip_whirlwind::
        end
    end

    if not execute_pooling and menu.use_rend and menu.use_rend:get_state() and spells.rend:is_learned() then
        local spread=equipped_shield and menu.leveling_spread_rend and menu.leveling_spread_rend:get_state()
        if spread and leveling_pack then
            if try_leveling_rend_spread(player,target,menu,leveling_pack) then return true end
        elseif try_leveling_rend_target(player,target,menu) then return true end
    end

    if not execute_pooling and menu.use_demoralizing_shout and menu.use_demoralizing_shout:get_state() and spells.demoralizing_shout:is_learned() then
        if target:debuff_down(spells.demoralizing_shout:id()) then
            if spells.demoralizing_shout:is_castable_to_unit(target) then
                if spells.demoralizing_shout:cast(target) then
                    return true
                end
            end
        end
    end

    if not execute_pooling and menu.use_devastate and menu.use_devastate:get_state() then
        if try_cast_devastate(player, target) then
            return true
        end
    end

    if not execute_pooling then
        if try_rage_dump(player, target, menu, enemy_count) then
        return true
    end
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_pack_recovery(player, menu, pack)
    if not pack_threat.taunt_attempt_ready() then return false end
    for _, entry in ipairs(pack.entries) do
        if pack_threat.can_taunt(entry, menu) then
            local enemy=entry.unit
            if menu.tank_auto_taunt and menu.tank_auto_taunt:get_state() and spells.taunt:is_learned()
                and spells.taunt:is_castable_to_unit(enemy) then
                pack_threat.note_taunt_attempt()
                if spells.taunt:cast(enemy) == true then return true end
            end
            if try_tank_mocking_blow(player, enemy, menu, entry) then
                pack_threat.note_taunt_attempt()
                return true
            end
        end
    end
    return false
end

local function try_tank_rotation(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    local enemy_count = count_enemies_around_player(player, 8)

    if try_defensives(player, target, menu, enemy_count) then
        return true
    end

    local pack = pack_threat.assess(player, target, menu)
    if try_pack_recovery(player, menu, pack) then return true end

    local focus = pack_threat.focus(pack, target)
    if not focus then return false end -- No engaged, unprotected melee target.
    if (not __object_safety.same(focus,target)) then
        if core.input and core.input.set_target then pcall(core.input.set_target, focus) end
        auto_attack_helper:start_attack(focus, auto_attack_helper.ATTACK_TYPE.MELEE)
        target = focus
    end

    if try_victory_rush(player,target,menu) then return true end

    if try_hamstring_on_humanoid_low_hp(player, menu) then
        return true
    end

    if try_hamstring_on_target_loss(player, menu) then
        return true
    end

    if try_tank_bloodrage(player, target, menu, enemy_count) then
        return true
    end

    if try_tank_aoe_opener(player, target, menu, enemy_count) then
        return true
    end

    if menu.tank_auto_defensive_stance and menu.tank_auto_defensive_stance:get_state() then
        if spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
            if try_set_stance(player, spells.defensive_stance) then
                return true
            end
        end
    end

    if try_keep_battle_shout(player, menu) then
        return true
    end

    -- Pack recovery above is the only source of automatic taunts/Mocking Blow.

    -- Shield Block für Revenge-Procs bei AoE (vor Revenge, um Procs zu erzwingen)
    if enemy_count >= 3 and menu.tank_use_shield_block and menu.tank_use_shield_block:get_state() then
        if spells.shield_block:is_learned() and rage(player) >= 10 then
            if not has_aura_id(player, spells.shield_block:id()) then
                if try_shield_ability_with_swap(player, player, menu, spells.shield_block, "Shield Block") then
                    return true
                end
            end
        end
    end

    if try_tank_tabbed_revenge(player, target, menu, pack) then
        return true
    end

    if try_tank_thunder_clap(player, target, menu, enemy_count) then
        return true
    end

    if menu.tank_use_shield_block and menu.tank_use_shield_block:get_state() and spells.shield_block:is_learned() then
        local min_rage = (menu.tank_shield_block_min_rage and menu.tank_shield_block_min_rage.get and menu.tank_shield_block_min_rage:get()) or 20
        if min_rage < 0 then
            min_rage = 0
        end
        if min_rage > 100 then
            min_rage = 100
        end

        if rage(player) >= min_rage then
            if not has_aura_id(player, spells.shield_block:id()) then
                if try_shield_ability_with_swap(player, player, menu, spells.shield_block, "Shield Block") then
                    return true
                end
            end
        end
    end

    if menu.tank_use_shield_slam and menu.tank_use_shield_slam:get_state() and spells.shield_slam:is_learned() then
        if try_shield_ability_with_swap(player, target, menu, spells.shield_slam, "Shield Slam") then
            return true
        end
    end

    if menu.tank_use_sunder and menu.tank_use_sunder:get_state() and spells.sunder_armor:is_learned() then
        local tab_target = find_best_tab_sunder_target(player, target, menu, enemy_count, pack)
        if tab_target and tab_target:is_valid_enemy() and tab_target:is_alive() then
            if spells.sunder_armor:is_castable_to_unit(tab_target) then
                if spells.sunder_armor:cast(tab_target) then
                    pack_threat.record_attack(tab_target)
                    return true
                end
            end
        end

        local desired = (menu.tank_sunder_stacks and menu.tank_sunder_stacks.get and menu.tank_sunder_stacks:get()) or 5
        if desired < 0 then
            desired = 0
        end
        if desired > 5 then
            desired = 5
        end

        if desired > 0 then
            local stacks = get_debuff_stacks(target, spells.sunder_armor:id())
            local target_threat = pack.by_unit[target]
            if stacks < desired or (target_threat and target_threat.priority >= 200) then
                if spells.sunder_armor:is_castable_to_unit(target) then
                    if spells.sunder_armor:cast(target) then
                        return true
                    end
                end
            end
        end
    end

    if menu.tank_use_demoralizing_shout and menu.tank_use_demoralizing_shout:get_state() and spells.demoralizing_shout:is_learned() and within_melee_range(player, target) then
        if target:debuff_down(spells.demoralizing_shout:id()) then
            if spells.demoralizing_shout:is_castable_to_unit(target) then
                if spells.demoralizing_shout:cast(target) then
                    return true
                end
            end
        end
    end

    if try_tank_single_target_finish(player, target, menu, enemy_count) then
        return true
    end

    if try_tank_cleave_spend(player, target, menu, enemy_count) then
        return true
    end

    if try_rage_dump(player, target, menu, enemy_count) then
        return true
    end

    return false
end

local last_melee_pull_ms=-math.huge
local last_melee_pull_guid=nil
local function try_ooc_melee_pull(player)
    -- Use only the actual selected target, never scan results or a tank focus.
    local ok,selected,guid=pcall(function()
        if not __object_safety.valid(player) or not player:is_alive() or player:is_mounted()
            or player:is_channeling_or_casting() or auto_attack_helper:is_auto_attacking(player) then return nil end
        local unit=player:get_target()
        if not __object_safety.valid(unit) or not unit:is_valid_enemy() or not unit:is_alive() then return nil end
        if unit.is_cc_weak and unit:is_cc_weak() then return nil end
        if unit.is_damage_immune and unit.DMG and unit:is_damage_immune(unit.DMG.PHYSICAL) then return nil end
        local a,b=player:get_position(),unit:get_position()
        if not a or not b then return nil end
        local reach=player:get_melee_reach(unit)
        if type(reach)~='number' or reach~=reach or reach<=0 or reach>=math.huge then return nil end
        local dx,dy,dz=a.x-b.x,a.y-b.y,a.z-b.z
        local distance_sq=dx*dx+dy*dy+dz*dz
        if distance_sq~=distance_sq or distance_sq>reach*reach then return nil end
        if not __object_safety.same(unit,player:get_target()) then return nil end
        return unit,__object_safety.guid(unit)
    end)
    if not ok then
        if __object_safety.is_invalid_error(selected) then return false end
        error(selected,0)
    end
    if not selected or not guid then return false end
    local now=core.game_time()
    if guid==last_melee_pull_guid and now>=last_melee_pull_ms and now-last_melee_pull_ms<450 then return false end
    -- Rate-limit dispatch attempts too: a delivered request may not start a swing.
    last_melee_pull_guid,last_melee_pull_ms=guid,now
    local started,result=pcall(auto_attack_helper.start_attack,auto_attack_helper,selected,auto_attack_helper.ATTACK_TYPE.MELEE)
    if not started then
        if __object_safety.is_invalid_error(result) then return false end
        error(result,0)
    end
    return result==true
end


-- ============================================================================
-- Entry point
-- ============================================================================

---@param local_player game_object
---@param menu table
---@param is_tank_mode boolean
---@param allow_ooc_charge boolean|nil
---@param allow_ooc_melee_pull boolean|nil
---@return boolean
function rotation_logic:execute(local_player, menu, is_tank_mode, allow_ooc_charge, allow_ooc_melee_pull)
    if not local_player or not menu then
        return false
    end

    if spells and spells.refresh then
        spells:refresh()
    end

    local player = local_player
    local ok_alive, alive = pcall(function() return player:is_alive() end)
    if not ok_alive or alive ~= true then return false end

    local in_combat = player_in_combat(player)
    -- Emergency items must not depend on a living enemy target or a completed swap.
    if in_combat and try_emergency_items(player, menu) then return true end

    -- V3: Update shield swap mode from menu (before any swap operations)
    if menu.shield_swap_mode then
        local shield_swap_mode = menu.shield_swap_mode:get() or 1
        shield_swap_helper:set_mode(shield_swap_mode == 1 and "auto" or "manual")

        if menu.shield_swap_verbose_logging and menu.shield_swap_verbose_logging.get_state and shield_swap_helper.set_verbose_logging then
            shield_swap_helper:set_verbose_logging(menu.shield_swap_verbose_logging:get_state() == true)
        end

        -- Manual Mode: Set manual equipment IDs from menu
        if shield_swap_mode == 2 then
            local manual_shield_id = 0
            local manual_weapon_id = 0

            if menu.shield_swap_manual_shield_id and menu.shield_swap_manual_shield_id.get_text_as_number then
                manual_shield_id = menu.shield_swap_manual_shield_id:get_text_as_number() or 0
            end

            if menu.shield_swap_manual_weapon_id and menu.shield_swap_manual_weapon_id.get_text_as_number then
                manual_weapon_id = menu.shield_swap_manual_weapon_id:get_text_as_number() or 0
            end

            shield_swap_helper:set_manual_equipment(manual_shield_id, manual_weapon_id)
        end
    end

    -- Auto mode: keep inventory scan fresh out of combat so UI + swap logic have data.
    if menu.enable_shield_weapon_swap and menu.enable_shield_weapon_swap.get_state and menu.enable_shield_weapon_swap:get_state() == true then
        if shield_swap_helper.get_mode and shield_swap_helper:get_mode() == "auto" then
            pcall(function()
                shield_swap_helper:scan_inventory(player, false)
            end)
        end
    end

    -- Update shield swap state machine (if currently swapping)
    if shield_swap_helper:is_currently_swapped() then
        if shield_swap_helper:update(player, menu) then
            return false  -- Still processing swap, skip rest of rotation
        end
    end

    process_stance_change_observation(player)
    do
        local now_ms = core.game_time()
        if planned_interrupt_return_spell and now_ms > planned_interrupt_return_until_ms then
            planned_interrupt_return_spell = nil
            planned_interrupt_return_until_ms = 0
        end
    end

    if player:is_channeling_or_casting() then
        return false
    end

    local target
    if player.get_target then target=player:get_target() else target=izi.target() end
    if not __object_safety.valid(target) or not target:is_valid_enemy() or not target:is_alive() then
        target=nil
        if is_tank_mode == true and in_combat then
            local pack=pack_threat.assess(player, nil, menu)
            if try_pack_recovery(player, menu, pack) then return true end
            target=pack_threat.focus(pack, nil)
            if target and core.input and core.input.set_target then pcall(core.input.set_target,target) end
        elseif in_combat then
            target=next_leveling_target(player,menu)
        end
        if not target then return false end
    end

    -- Pull options are explicit opt-ins. Normal combat spending still
    -- waits for combat; melee pull only starts attacking the selected in-range unit.
    do
        if not in_combat then
            if allow_ooc_melee_pull==true and try_ooc_melee_pull(player) then return true end
            if allow_ooc_charge == true and spells.charge and spells.charge:is_learned() then
                if menu.auto_battle_stance and menu.auto_battle_stance.get_state and menu.auto_battle_stance:get_state() == true then
                    if not in_battle_stance(player) and spells.battle_stance and spells.battle_stance:is_learned() then
                        if try_set_stance(player, spells.battle_stance) then
                            return true
                        end
                    end
                end
                if spells.charge:is_castable_to_unit(target) then
                    return spells.charge:cast(target) == true
                end
            end
            return false
        end
    end

    if not auto_attack_helper:is_auto_attacking(player) then
        auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
    end

    if try_auto_interrupt(player, target, menu, is_tank_mode == true) then
        return true
    end

    if process_pending_stance_return(player) then
        return true
    end

    if is_tank_mode == true then
        return try_tank_rotation(player, target, menu)
    end

    return try_leveling_rotation(player, target, menu)
end

return rotation_logic
