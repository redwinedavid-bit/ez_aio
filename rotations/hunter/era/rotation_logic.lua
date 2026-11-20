local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Hunter APL (Action Priority List) - IZI Library Edition
-- Refactored to use izi libraries for cleaner, more maintainable code
-- ============================================================================

local rotation_logic = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

local swing_timer = require("shared/swing_timer")

---@type pet_handler
local pet_handler = require("common/utility/pet_handler")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@param queue spell_queue|any
---@param spell_id number|nil
---@param target game_object|any|nil
local function safe_spell_queue_purge(queue, spell_id, target)
    if not queue or not spell_id then
        return
    end

    local candidates = { "purge_by_spell", "purge_by_spell_id", "purge_spell", "purge_spell_target" }
    for i = 1, #candidates do
        local fn = queue[candidates[i]]
        if type(fn) == "function" then
            pcall(fn, queue, spell_id, target)
            return
        end
    end
end

-- Import izi-based spells
local spells = require("rotations/hunter/era/spells")

local hunter_pet_engage = require("shared/hunter_pet_engage")
local pet_engage = hunter_pet_engage.new()

local healthstone_item = izi.item({ 9421, 19013, 19012, 19011, 19010, 19009, 19008, 19007, 19006, 19005, 19004, 5510, 5509, 5511, 5512 })

-- State tracking
local last_enrage_check = 0
local boss_is_enraged = false
local enrage_count = 0

-- Aspect management state tracking
local last_aspect_switch = 0
local ASPECT_SWITCH_THROTTLE = 3000  -- 3 seconds (milliseconds)
local monkey_aspect_active = false
local last_movement_state = false
local last_movement_change_time = 0
local MOVEMENT_STABILIZATION_TIME = 2000  -- 2 seconds

local last_dismount_request_ms = 0
local DISMOUNT_THROTTLE_MS = 1000

local last_pet_attack_request_ms = 0
local PET_ATTACK_THROTTLE_MS = 500

local last_pet_state = nil
local last_pet_state_request_ms = 0
local PET_STATE_THROTTLE_MS = 750

local last_pet_call_request_ms = 0
local PET_CALL_THROTTLE_MS = 2500
local last_pet_revive_request_ms = 0
local PET_REVIVE_THROTTLE_MS = 2500
local PET_CALL_VERIFY_MS = 1500

local last_pet_missing_since_ms = nil
local PET_MISSING_CONFIRM_MS = 1200

-- Pet recovery anti-spam (stateful backoff, handles "pet dead but get_pet() == nil")
local pet_recover_lockout_until_ms = 0
local pet_recover_fail_count = 0
local pet_recover_last_state_key = nil
local PET_RECOVER_MAX_BACKOFF_MS = 30000

---@param menu table|nil
---@return boolean
local function save_intimidation_for_interrupt_enabled(menu)
    return menu
        and menu.save_intimidation_for_interrupt
        and menu.save_intimidation_for_interrupt.get_state
        and menu.save_intimidation_for_interrupt:get_state() == true
end

---@param player game_object
---@param target game_object|nil
---@param pet game_object|nil
---@param menu table
---@return boolean
local function try_intimidation_interrupt(player, target, pet, menu)
    if not save_intimidation_for_interrupt_enabled(menu) then
        return false
    end

    if not (menu and menu.use_intimidation and menu.use_intimidation.get_state and menu.use_intimidation:get_state() == true) then
        return false
    end

    if not player or player:is_dead() or player:is_ghost() then
        return false
    end

    if not pet or pet:is_dead() then
        return false
    end

    if not target or target:is_dead() or not target:is_valid_enemy() then
        return false
    end

    if not spells.intimidation or not spells.intimidation.is_learned or spells.intimidation:is_learned() ~= true then
        return false
    end

    if not target:is_casting_spell() or target:is_active_spell_interruptable() ~= true then
        return false
    end

    local pet_distance = 99
    pcall(function()
        pet_distance = pet:distance_to(target) or 99
    end)
    if pet_distance > 5 then
        return false
    end

    if spells.intimidation:is_castable() and spells.intimidation:cast(target) then
        return true
    end

    return false
end

---@param fail_count integer
---@return integer
local function compute_pet_recover_backoff_ms(fail_count)
    if fail_count <= 0 then
        return PET_REVIVE_THROTTLE_MS
    end

    local pow = math.min(fail_count - 1, 4)
    local delay = PET_REVIVE_THROTTLE_MS * (2 ^ pow)
    if delay > PET_RECOVER_MAX_BACKOFF_MS then
        delay = PET_RECOVER_MAX_BACKOFF_MS
    end
    return delay
end

---@param now_ms integer
---@param state_key string
local function maybe_reset_pet_recover_state(now_ms, state_key)
    if pet_recover_last_state_key ~= state_key then
        pet_recover_last_state_key = state_key
        pet_recover_fail_count = 0
        pet_recover_lockout_until_ms = now_ms
    end
end

---@param player game_object
---@param pet game_object|nil
---@param menu table
---@param is_casting boolean
---@param now_ms integer
---@return boolean
local function try_pet_recovery(player, pet, menu, is_casting, now_ms)
    if not menu or is_casting then
        return false
    end

    if pet and not pet:is_dead() then
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
            core.log(string.format("[HunterPetMgmt] recovery: pet alive -> reset recovery state"))
        end
        pet_recover_lockout_until_ms = 0
        pet_recover_fail_count = 0
        pet_recover_last_state_key = nil
        return false
    end

    if now_ms < pet_recover_lockout_until_ms then
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() and menu.pet_debug_verbose and menu.pet_debug_verbose.get_state and menu.pet_debug_verbose:get_state() then
            core.log(string.format("[HunterPetMgmt] recovery: lockout active now=%d until=%d", tonumber(now_ms) or -1, tonumber(pet_recover_lockout_until_ms) or -1))
        end
        return false
    end

    local revive_possible = menu.auto_revive_pet:get_state()
        and spells.revive_pet:is_castable_to_unit(player)

    -- Only allow Call Pet when pet is actually missing.
    local call_missing_confirmed = (not pet)
        and last_pet_missing_since_ms
        and (now_ms - last_pet_missing_since_ms) >= PET_MISSING_CONFIRM_MS

    local call_possible = call_missing_confirmed
        and menu.auto_call_pet:get_state()
        and spells.call_pet:is_castable_to_unit(player)

    local call_throttle_ready = (now_ms - last_pet_call_request_ms) >= PET_CALL_THROTTLE_MS
    local call_wait_elapsed = last_pet_call_request_ms > 0
        and (now_ms - last_pet_call_request_ms) >= PET_CALL_VERIFY_MS

    local intent = nil
    if call_possible and call_throttle_ready then
        intent = "call"
    elseif revive_possible then
        if pet and pet:is_dead() then
            intent = "revive"
        elseif not pet then
            if call_wait_elapsed or not call_possible then
                intent = "revive"
            end
        end
    end

    if not intent then
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() and menu.pet_debug_verbose and menu.pet_debug_verbose.get_state and menu.pet_debug_verbose:get_state() then
            core.log(string.format("[HunterPetMgmt] recovery: no intent (pet=%s missing_confirmed=%s revive_possible=%s call_possible=%s call_throttle_ready=%s call_wait_elapsed=%s)",
                pet and "present" or "missing",
                call_missing_confirmed and "1" or "0",
                revive_possible and "1" or "0",
                call_possible and "1" or "0",
                call_throttle_ready and "1" or "0",
                call_wait_elapsed and "1" or "0"
            ))
        end
        return false
    end

    local state_key = intent
        .. "|pet:" .. (pet and "present" or "missing")
        .. "|missing_confirmed:" .. (call_missing_confirmed and "1" or "0")
        .. "|call_wait:" .. (call_wait_elapsed and "1" or "0")
    maybe_reset_pet_recover_state(now_ms, state_key)
    if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
        core.log(string.format("[HunterPetMgmt] recovery: intent=%s state=%s fail_count=%d", tostring(intent), tostring(state_key), tonumber(pet_recover_fail_count) or 0))
    end

    if intent == "revive" then
        last_pet_revive_request_ms = now_ms
        local ok = spells.revive_pet:is_castable({ skip_facing = true }) and spells.revive_pet:cast(player)
        if ok then
            if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                core.log(string.format("[HunterPetMgmt] recovery: Revive Pet cast OK -> lockout %dms", PET_REVIVE_THROTTLE_MS))
            end
            pet_recover_fail_count = 0
            pet_recover_lockout_until_ms = now_ms + PET_REVIVE_THROTTLE_MS
            return true
        end
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
            core.log(string.format("[HunterPetMgmt] recovery: Revive Pet cast FAIL"))
        end
    else
        last_pet_call_request_ms = now_ms
        local ok = spells.call_pet:is_castable({ skip_facing = true }) and spells.call_pet:cast(player)
        if ok then
            if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                core.log(string.format("[HunterPetMgmt] recovery: Call Pet cast OK -> verify %dms", PET_CALL_VERIFY_MS))
            end
            pet_recover_fail_count = 0
            pet_recover_lockout_until_ms = now_ms + PET_CALL_VERIFY_MS
            return true
        end
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
            core.log(string.format("[HunterPetMgmt] recovery: Call Pet cast FAIL"))
        end
    end

    pet_recover_fail_count = math.min((pet_recover_fail_count or 0) + 1, 10)
    pet_recover_lockout_until_ms = now_ms + compute_pet_recover_backoff_ms(pet_recover_fail_count)
    if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
        core.log(string.format("[HunterPetMgmt] recovery: backoff fail_count=%d next_lockout_ms=%d", tonumber(pet_recover_fail_count) or 0, tonumber(pet_recover_lockout_until_ms) or -1))
    end
    return false
end

-- Range handling (Classic-style deadzone jitter protection)
local MELEE_RANGE_YDS = 5.0
local MELEE_RANGE_GRACE_YDS = 0.6
local RANGED_MIN_YDS = 8.0
local BASE_RANGED_MAX_YDS = 35.0
local melee_range_latched = false
local MELEE_FACING_HALF_ANGLE = math.pi / 2

-- Track welcher Auto-Attack Typ gerade aktiv ist (fÃƒÂ¼r Mode-Switching)
local current_auto_attack_type = nil  -- nil, MELEE, oder RANGED

local melee_strikes = {
    last_raptor_attempt_ms = 0,
    last_raptor_queued_swing_ms = 0,
    last_mongoose_attempt_ms = 0,
    raptor_attempt_throttle_ms = 350,
    raptor_queue_window_ms = 650,
    mongoose_attempt_throttle_ms = 1200,
    swing_timer = nil,
}

local CONCUSSIVE_APPROACH_ANGLE_DEG = 35
local CONCUSSIVE_FLEE_TIME_SEC = 1.0
local CONCUSSIVE_FLEE_DISTANCE_DELTA = 0.6

local hawk_eye_bonus_cache_yards = 0
local hawk_eye_bonus_last_check_ms = 0

local RANGED_SWING_BUFFER_MS = 250

local VOLLEY_SPLASH_RADIUS_YDS = 8.0
local VOLLEY_MIN_OTHER_TARGETS = 1
local VOLLEY_CLUSTER_EVAL_THROTTLE_MS = 350

local last_volley_cluster_eval_ms = 0
local cached_volley_cluster_center = nil
local cached_volley_cluster_score = 0

local FLARE_SCAN_THROTTLE_MS = 250
local last_flare_scan_ms = 0

local DISENGAGE_THROTTLE_MS = 900
local last_disengage_request_ms = 0

local DISTRACTING_SHOT_THROTTLE_MS = 900
local last_distracting_shot_request_ms = 0

---@param enemy game_object|nil
---@return boolean
local function is_valid_volley_cluster_center(enemy)
    if not enemy then
        return false
    end

    if enemy.is_dead and enemy:is_dead() then
        return false
    end

    if enemy.is_valid_enemy and not enemy:is_valid_enemy() then
        return false
    end

    if enemy.is_moving and enemy:is_moving() then
        return false
    end

    return true
end

---@param player game_object
---@param scan_range number
---@param now_ms integer
---@return game_object|nil
---@return number
local function find_best_volley_cluster_center(player, scan_range, now_ms)
    if not player or not scan_range or scan_range <= 0 then
        return nil, 0
    end

    local cached_distance = nil
    if cached_volley_cluster_center then
        cached_distance = player:distance_to(cached_volley_cluster_center)
    end

    local cached_ok = cached_volley_cluster_center
        and (now_ms - last_volley_cluster_eval_ms) < VOLLEY_CLUSTER_EVAL_THROTTLE_MS
        and is_valid_volley_cluster_center(cached_volley_cluster_center)
        and cached_distance
        and cached_distance <= scan_range

    if cached_ok then
        return cached_volley_cluster_center, cached_volley_cluster_score
    end

    last_volley_cluster_eval_ms = now_ms
    cached_volley_cluster_center = nil
    cached_volley_cluster_score = 0

    local enemies = performance:get_unit_list(player, "get_enemies_in_range", scan_range, false)
    if not enemies then
        return nil, 0
    end

    local best_enemy = nil
    local best_score = 0

    for i = 1, #enemies do
        local enemy = enemies[i]
        if is_valid_volley_cluster_center(enemy) then
            local score = enemy:get_enemies_in_splash_range_count(VOLLEY_SPLASH_RADIUS_YDS)
            if score and score > best_score then
                best_enemy = enemy
                best_score = score
            end
        end
    end

    cached_volley_cluster_center = best_enemy
    cached_volley_cluster_score = best_score

    return best_enemy, best_score
end

---@param player game_object
---@param menu table
---@param now_ms integer
---@return boolean
local function try_cast_flare_anti_stealth(player, menu, now_ms)
    if not menu or not menu.use_flare_anti_stealth or not menu.use_flare_anti_stealth:get_state() then
        return false
    end

    if not spells.flare:is_learned() then
        return false
    end

    if now_ms < last_flare_scan_ms or (now_ms - last_flare_scan_ms) < FLARE_SCAN_THROTTLE_MS then
        return false
    end
    last_flare_scan_ms = now_ms

    if player:is_channeling_or_casting() then
        return false
    end

    local scan_range = spells.flare.maximum_range and spells.flare.maximum_range > 0 and spells.flare.maximum_range or 35.0
    local enemies = performance:get_unit_list(player, "get_enemies_in_range_if", scan_range, true)
    if not enemies then
        return false
    end

    local best_enemy = nil
    local best_dist = 999999

    for i = 1, #enemies do
        local enemy = enemies[i]
        if enemy and enemy.is_dead and not enemy:is_dead() and enemy.is_valid_enemy and enemy:is_valid_enemy() then
            if enemy.stealth_up and enemy:stealth_up(false, true) then
                local dist = player:distance_to(enemy)
                if dist and dist < best_dist then
                    best_enemy = enemy
                    best_dist = dist
                end
            end
        end
    end

    if not best_enemy then
        return false
    end

    local cast_pos = best_enemy:get_position()
    if not cast_pos then
        return false
    end

    local opts = { use_prediction = false, check_los = true }
    if spells.flare:is_castable_to_position(best_enemy, cast_pos, opts) then
        if spells.flare:cast_position(cast_pos, "Flare", opts) then
            return true
        end
    end

    return false
end

---@param party game_objects_table
---@param unit game_object|nil
---@return boolean
local function is_unit_in_party(party, unit)
    if not party or not unit then
        return false
    end

    for i = 1, #party do
        if (__object_safety.same(party[i],unit)) then
            return true
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@param now_ms integer
---@return boolean
local function try_cast_disengage(player, menu, now_ms)
    if not menu or not menu.use_disengage or not menu.use_disengage:get_state() then
        return false
    end

    if not spells.disengage:is_learned() then
        return false
    end

    -- Requirement: Have a pet or be in a group
    local pet = player:get_pet()
    local has_pet = pet and not pet:is_dead()
    local party = izi.party(40)
    local in_group = party and #party > 0

    if not (has_pet or in_group) then
        return false
    end

    if now_ms < last_disengage_request_ms or (now_ms - last_disengage_request_ms) < DISENGAGE_THROTTLE_MS then
        return false
    end

    if player:is_channeling_or_casting() then
        return false
    end

    local range = menu.disengage_range and menu.disengage_range:get() or 5
    local enemies = performance:get_unit_list(player, "get_enemies_in_range", range, false)
    if not enemies then
        return false
    end

    local best_enemy = nil
    local best_dist = 999999

    for i = 1, #enemies do
        local enemy = enemies[i]
        if enemy and enemy.is_dead and not enemy:is_dead() and enemy.is_valid_enemy and enemy:is_valid_enemy() then
            local enemy_target = enemy.get_target and enemy:get_target()
            if enemy_target and (__object_safety.same(enemy_target,player)) then
                local dist = player:distance_to(enemy)
                if dist and dist < best_dist then
                    best_enemy = enemy
                    best_dist = dist
                end
            end
        end
    end

    if not best_enemy then
        return false
    end

    last_disengage_request_ms = now_ms
    if spells.disengage:is_castable() and spells.disengage:cast(best_enemy) then
        return true
    end

    return false
end

---@param player game_object
---@param menu table
---@param now_ms integer
---@return boolean
local function try_cast_distracting_shot(player, menu, now_ms)
    if not menu or not menu.use_distracting_shot or not menu.use_distracting_shot:get_state() then
        return false
    end

    if not spells.distracting_shot:is_learned() then
        return false
    end

    if now_ms < last_distracting_shot_request_ms or (now_ms - last_distracting_shot_request_ms) < DISTRACTING_SHOT_THROTTLE_MS then
        return false
    end

    if player:is_channeling_or_casting() then
        return false
    end

    local party_range = menu.distracting_party_range and menu.distracting_party_range:get() or 40
    local party = izi.party(party_range)
    if not party or #party <= 0 then
        return false
    end

    local scan_range = menu.distracting_shot_range and menu.distracting_shot_range:get() or 35
    local enemies = performance:get_unit_list(player, "get_enemies_in_range", scan_range, false)
    if not enemies then
        return false
    end

    local only_healers = menu.distracting_only_healers and menu.distracting_only_healers:get_state() or true
    local require_not_tanking = menu.distracting_require_not_tanking and menu.distracting_require_not_tanking:get_state() or true

    local best_enemy = nil
    local best_dist = 999999

    for i = 1, #enemies do
        local enemy = enemies[i]
        if enemy and enemy.is_dead and not enemy:is_dead() and enemy.is_valid_enemy and enemy:is_valid_enemy() then
            if enemy.is_in_combat and not enemy:is_in_combat() then
                goto continue
            end

            local enemy_target = enemy.get_target and enemy:get_target()
            if not is_unit_in_party(party, enemy_target) then
                goto continue
            end

            if only_healers and enemy_target and enemy_target.is_healer and not enemy_target:is_healer() then
                goto continue
            end

            if require_not_tanking and player.get_threat_situation then
                local threat_info = player:get_threat_situation(enemy)
                if threat_info and threat_info.is_tanking then
                    goto continue
                end
            end

            local dist = player:distance_to(enemy)
            if dist and dist < best_dist then
                best_enemy = enemy
                best_dist = dist
            end
        end
        ::continue::
    end

    if not best_enemy then
        return false
    end

    last_distracting_shot_request_ms = now_ms
    if spells.distracting_shot:is_castable() and spells.distracting_shot:cast(best_enemy) then
        return true
    end

    return false
end

local ranged_swing_timer = swing_timer.new({
    id = "hunter_rotation_ranged",
    label = "Hunter Ranged Swing Timer",
    attack_mode = "ranged",
    enable_window = false,
    always_enabled = true,
    menu_prefix = "hunter_rotation_ranged_swing"
})

melee_strikes.swing_timer = melee_strikes.swing_timer or swing_timer.new({
    id = "hunter_rotation_melee",
    label = "Hunter Melee Swing Timer",
    attack_mode = "melee",
    enable_window = false,
    always_enabled = true,
    menu_prefix = "hunter_rotation_melee_swing"
})

---@param player game_object
---@return boolean
local function can_cast_instant_ranged_shot(player)
    if not player then
        return true
    end

    if player:is_moving() then
        return true
    end

    if current_auto_attack_type ~= auto_attack_helper.ATTACK_TYPE.RANGED then
        return true
    end

    ranged_swing_timer:on_update()
    local timer_state = ranged_swing_timer:get_state()
    if not timer_state or not timer_state.is_auto_attacking then
        return true
    end

    if not timer_state.remaining_ms then
        return true
    end

    return timer_state.remaining_ms >= RANGED_SWING_BUFFER_MS
end

---@param player game_object
---@param menu table
---@param now_ms number
---@return boolean
local function allow_unclipped_instant_after_auto(player, menu, now_ms)
    if not menu or not menu.post_swing_instants_only or not menu.post_swing_instants_only.get_state then
        return true
    end
    if menu.use_clipped_rotation and menu.use_clipped_rotation.get_state and menu.use_clipped_rotation:get_state() then
        return true
    end
    if menu.post_swing_instants_only:get_state() ~= true then
        return true
    end
    if not player or player:is_moving() then
        return true
    end
    if current_auto_attack_type ~= auto_attack_helper.ATTACK_TYPE.RANGED then
        return true
    end

    ranged_swing_timer:on_update()
    local timer_state = ranged_swing_timer:get_state()
    if not timer_state or not timer_state.is_auto_attacking or not timer_state.last_swing then
        return true
    end

    local window_ms = 350
    if menu.post_swing_window_ms and menu.post_swing_window_ms.get then
        local v = tonumber(menu.post_swing_window_ms:get())
        if v and v > 0 then
            window_ms = v
        end
    end

    return (now_ms - timer_state.last_swing) <= window_ms
end

local function get_hunter_hawk_eye_bonus_yards(now_ms)
    if hawk_eye_bonus_last_check_ms > 0 and (now_ms - hawk_eye_bonus_last_check_ms) < 2000 then
        return hawk_eye_bonus_cache_yards
    end

    local bonus = 0
    if core.spell_book and core.spell_book.is_spell_learned then
        if core.spell_book.is_spell_learned(19500) then
            bonus = 6
        elseif core.spell_book.is_spell_learned(19499) then
            bonus = 4
        elseif core.spell_book.is_spell_learned(19498) then
            bonus = 2
        end
    end

    hawk_eye_bonus_cache_yards = bonus
    hawk_eye_bonus_last_check_ms = now_ms
    return bonus
end

local function get_hunter_max_range_yards(now_ms)
    return BASE_RANGED_MAX_YDS + get_hunter_hawk_eye_bonus_yards(now_ms)
end

local function resolve_pet_combat_state()
    if pet_handler and pet_handler.pet_state then
        return pet_handler.pet_state.ASSIST or pet_handler.pet_state.DEFENSIVE
    end
    return nil
end

---Check if target is within player's frontal arc
---@param local_player game_object
---@param target game_object
---@param half_angle_rad number|nil
---@return boolean
local function is_in_front_arc(local_player, target, half_angle_rad)
    if not local_player or not target then
        return false
    end

    local player_pos = local_player:get_position()
    local target_pos = target:get_position()
    if not player_pos or not target_pos then
        return false
    end

    local facing = local_player:get_direction()
    if not facing then
        return false
    end

    local dx = target_pos.x - player_pos.x
    local dy = target_pos.y - player_pos.y
    local dist_sq = (dx * dx) + (dy * dy)
    if dist_sq <= 0.0001 then
        return true
    end

    local facing_len_sq = (facing.x * facing.x) + (facing.y * facing.y)
    if facing_len_sq <= 0.0001 then
        return false
    end

    local dot = (facing.x * dx) + (facing.y * dy)
    local cos_angle = dot / (math.sqrt(facing_len_sq) * math.sqrt(dist_sq))
    if cos_angle > 1 then
        cos_angle = 1
    elseif cos_angle < -1 then
        cos_angle = -1
    end

    local angle = math.acos(cos_angle)
    local half_angle = half_angle_rad or MELEE_FACING_HALF_ANGLE
    return angle <= half_angle
end

---@param player game_object
---@param enemy game_object
---@return boolean
local function is_in_combat_with_player(player, enemy)
    if not player or not enemy then
        return false
    end

    return player:is_in_combat() and enemy:is_in_combat()
end

---@param player game_object
---@param enemy game_object
---@return boolean
local function is_moving_towards_player(player, enemy)
    if not player or not enemy then
        return false
    end

    if not enemy.is_moving_towards_me then
        return false
    end

    local ok, is_towards = pcall(function()
        return enemy:is_moving_towards_me(player, CONCUSSIVE_APPROACH_ANGLE_DEG)
    end)

    return ok and is_towards == true
end

---@param player game_object
---@param enemy game_object
---@return boolean
local function is_fleeing_from_player(player, enemy)
    if not player or not enemy then
        return false
    end

    if not enemy:is_moving() then
        return false
    end

    local distance = player:distance_to(enemy)
    if not distance then
        return false
    end

    local ok, predicted = pcall(function()
        return enemy:predict_distance(CONCUSSIVE_FLEE_TIME_SEC, player)
    end)
    if not ok or not predicted then
        return false
    end

    return predicted >= (distance + CONCUSSIVE_FLEE_DISTANCE_DELTA)
end

---@param player game_object
---@param enemy game_object
---@param min_distance number
---@param max_distance number
---@return boolean
local function is_concussive_candidate(player, enemy, min_distance, max_distance)
    if not player or not enemy then
        return false
    end

    if enemy:is_dead() then
        return false
    end

    if not is_in_combat_with_player(player, enemy) then
        return false
    end

    local distance = player:distance_to(enemy)
    if not distance or distance <= min_distance or distance > max_distance then
        return false
    end

    local enemy_target = enemy:get_target()
    local moving_towards_me = enemy_target and (__object_safety.same(enemy_target,player)) and is_moving_towards_player(player, enemy)
    if moving_towards_me then
        return true
    end

    return is_fleeing_from_player(player, enemy)
end

---@param player game_object
---@param current_target game_object|nil
---@param min_distance number
---@param max_distance number
---@return game_object|nil
local function find_concussive_target(player, current_target, min_distance, max_distance)
    if current_target and is_concussive_candidate(player, current_target, min_distance, max_distance) then
        return current_target
    end

    local enemies = performance:get_unit_list(player, "get_enemies_in_range", max_distance, false)
    if not enemies then
        return nil
    end

    for i = 1, #enemies do
        local enemy = enemies[i]
        if enemy and is_concussive_candidate(player, enemy, min_distance, max_distance) then
            return enemy
        end
    end

    return nil
end

---@param player game_object
---@param radius number
---@return number
local function count_aggro_enemies(player, radius)
    if not player or not radius or radius <= 0 then
        return 0
    end

    local enemies = performance:get_unit_list(player, "get_enemies_in_range", radius, false)
    if not enemies then
        return 0
    end

    local count = 0
    for i = 1, #enemies do
        local enemy = enemies[i]
        if enemy then
            if enemy.is_dead and enemy:is_dead() then
                goto continue
            end

            if enemy.is_valid_enemy and not enemy:is_valid_enemy() then
                goto continue
            end

            local threat_info = player.get_threat_situation and player:get_threat_situation(enemy)
            if threat_info and threat_info.is_tanking then
                count = count + 1
                goto continue
            end

            local enemy_target = enemy.get_target and enemy:get_target()
            if enemy_target and (__object_safety.same(enemy_target,player)) then
                count = count + 1
            end
        end
        ::continue::
    end

    return count
end


---Check if we should wait for pet aggro before attacking
---@param combat_time number Seconds in combat
---@param target_hp_percent number Target HP percentage (1-100)
---@param wait_time number Max seconds to wait (0 = disabled)
---@param wait_hp number HP threshold (100 = disabled)
---@return boolean should_wait True if we should wait
local function should_wait_for_pet_aggro(combat_time, target_hp_percent, wait_time, wait_hp)
    local time_gate = wait_time > 0
    local hp_gate = wait_hp < 100

    if time_gate and hp_gate then
        return combat_time < wait_time and target_hp_percent > wait_hp
    elseif time_gate then
        return combat_time < wait_time
    elseif hp_gate then
        return target_hp_percent > wait_hp
    end

    return false
end

-- ============================================================================
-- MANA MANAGEMENT HELPER
-- ============================================================================

---Check if player has enough mana for ability
---@param player game_object
---@param menu table
---@param min_mana_pct number Minimum mana percentage required
---@return boolean
local function has_enough_mana(player, menu, min_mana_pct)
    local mana_pct = player:mana_pct()

    -- Reserve 15% mana fÃƒÂ¼r Tranq Shot wenn aktiviert
    if menu.save_mana_for_tranq:get_state() then
        return mana_pct >= (min_mana_pct + 15)
    end

    return mana_pct >= min_mana_pct
end

local SERPENT_MIN_MANA_PCT = 25
local SERPENT_STING_DEBUFF_IDS = { 1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295 }
local VIPER_STING_DEBUFF_IDS = { 3034, 14279, 14280 }

local function resolve_serpent_thresholds(menu, classification)
    local normal = enums.classification.NORMAL
    local elite = enums.classification.ELITE
    local rare = (enums.classification.RARE or enums.classification.RARE_ELITE)

    if rare and classification == rare then
        return menu.serpent_min_ttd_rare:get(), menu.serpent_min_hp_rare:get()
    end

    if classification >= elite then
        return menu.serpent_min_ttd_elite:get(), menu.serpent_min_hp_elite:get()
    end

    return menu.serpent_min_ttd_normal:get(), menu.serpent_min_hp_normal:get()
end

local function resolve_arcane_min_ttd(menu, classification)
    local normal = enums.classification.NORMAL
    local elite = enums.classification.ELITE
    local rare = (enums.classification.RARE or enums.classification.RARE_ELITE)

    if rare and classification == rare then
        return menu.arcane_min_ttd_rare:get()
    end

    if classification >= elite then
        return menu.arcane_min_ttd_elite:get()
    end

    return menu.arcane_min_ttd_normal:get()
end

local function should_cast_serpent(player, target, menu)
    if not menu.use_serpent_sting:get_state() then
        return false
    end

    if not spells.serpent_sting:is_learned() then
        return false
    end

    local serpent_spec = SERPENT_STING_DEBUFF_IDS
    if not target:debuff_down(serpent_spec) then
        return false
    end

    -- Only one hunter sting per target (Serpent/Viper are mutually exclusive).
    if not target:debuff_down(VIPER_STING_DEBUFF_IDS) then
        return false
    end

    if not has_enough_mana(player, menu, SERPENT_MIN_MANA_PCT) then
        return false
    end

    local creature_type = target:get_creature_type()
    if creature_type == 9 or creature_type == 4 then
        return false
    end

    local classification = target:get_classification() or enums.classification.NORMAL
    local min_ttd, min_hp = resolve_serpent_thresholds(menu, classification)

    local target_hp_percent = target:get_health_percentage() or 0
    if min_hp and min_hp > 0 and target_hp_percent < min_hp then
        return false
    end

    local ttd = target:time_to_die() or 0
    if min_ttd and min_ttd > 0 and ttd > 0 and ttd < min_ttd then
        return false
    end

    return true
end

-- ============================================================================
-- MAIN APL EXECUTION
-- ============================================================================

---@param local_player game_object
---@param menu table
---@return boolean
function rotation_logic:execute(local_player, menu)
    if not local_player then
        return false
    end

    -- Use izi naming convention
    local player = local_player
    ranged_swing_timer:on_update()
    if spells and spells.refresh then
        spells:refresh()
    end
    local target = izi.target()
    local pet = player:get_pet()

    if try_intimidation_interrupt(player, target, pet, menu) then
        return true
    end
    local pullback_active = false

    -- Player state
    local hp_percent = player:get_health_percentage()
    local is_moving = player:is_moving()
    local in_combat = player:is_in_combat()
    local game_time = core.game_time()
    local pet_in_combat = pet and pet:is_in_combat()
    if not in_combat and pet_in_combat then
        in_combat = true
    end

    if try_cast_flare_anti_stealth(player, menu, game_time) then
        return true
    end

    -- ========================================================================
    -- OUT OF COMBAT: Buffs & Pet Management
    -- ========================================================================

    if not in_combat then
        -- Reset Auto-Attack Tracking wenn nicht im Combat
        current_auto_attack_type = nil

        -- Pet management (avoid spam + avoid "call pet" while dead)
        local is_casting = player:is_channeling_or_casting()

        if pet then
            last_pet_missing_since_ms = nil
        elseif not last_pet_missing_since_ms then
            last_pet_missing_since_ms = game_time
        end

        -- Pet recovery (no spam): prefers revive over call, with stateful backoff/lockout.
        if try_pet_recovery(player, pet, menu, is_casting, game_time) then
            return true
        end

        -- Trueshot Aura (Level 40+, Beast Mastery talent)
        if menu.use_trueshot_aura:get_state() then
            if player:buff_down(spells.trueshot_aura:id()) then
                if spells.trueshot_aura:is_castable({ skip_facing = true }) and spells.trueshot_aura:cast(player) then
                    return true
                end
            end
        end

        -- Movement state detection for aspect stabilization
        if is_moving ~= last_movement_state then
            last_movement_change_time = game_time
            last_movement_state = is_moving
        end
        local movement_stable_duration = game_time - last_movement_change_time

        -- Aspect of the Cheetah (traveling, Level 20+) with Movement Stabilization
        if menu.use_aspect_cheetah:get_state() and is_moving then
            if movement_stable_duration >= MOVEMENT_STABILIZATION_TIME then
                if player:buff_down(spells.aspect_cheetah:id()) then
                    if not player:is_channeling_or_casting() then
                        if spells.aspect_cheetah:is_castable({ skip_facing = true }) and spells.aspect_cheetah:cast(player) then
                            return true
                        end
                    end
                end
            end
        end

        -- Aspect of the Hawk (default, Level 10+) with Movement Stabilization
        if menu.use_aspect_hawk:get_state() and not is_moving then
            if movement_stable_duration >= MOVEMENT_STABILIZATION_TIME then
                if player:buff_down(spells.aspect_hawk:id()) then
                    if not player:is_channeling_or_casting() then
                        if spells.aspect_hawk:is_castable({ skip_facing = true }) and spells.aspect_hawk:cast(player) then
                            return true
                        end
                    end
                end
            end
        end

        return false
    end

    -- ========================================================================
    -- AUTO-DISMOUNT (Before Combat)
    -- ========================================================================

    if menu.auto_dismount:get_state() then
        if player:is_mounted() and target and target:is_valid_enemy() then
            -- Player is mounted and has valid enemy target
            local distance = player:distance_to(target)
            if distance <= 40 then
                -- Within combat range - dismount (throttled to avoid input spam)
                local game_time = core.game_time()
                if (game_time - last_dismount_request_ms) >= DISMOUNT_THROTTLE_MS then
                    last_dismount_request_ms = game_time
                    if core.input and core.input.dismount then
                        core.input.dismount()
                    end
                end
                return false -- Wait one frame for dismount to complete
            end
        end
    end

    -- ========================================================================
    -- IN COMBAT: Priority List
    -- ========================================================================

    if not target or not target:is_alive() then
        return false
    end

    local target_hp_percent = target:get_health_percentage()
    local distance = player:distance_to(target)
    local now_ms = core.game_time()
    local max_ranged_yards = get_hunter_max_range_yards(now_ms)

    -- ========================================================================
    -- AUTO ATTACK / AUTO SHOOT MANAGEMENT
    -- ========================================================================

    -- Bestimme den gewÃƒÂ¼nschten Attack-Typ basierend auf Distance
    local desired_attack_type = nil

    if distance >= 0 and distance <= MELEE_RANGE_YDS then
        desired_attack_type = auto_attack_helper.ATTACK_TYPE.MELEE
    elseif distance >= RANGED_MIN_YDS and distance <= max_ranged_yards then
        desired_attack_type = auto_attack_helper.ATTACK_TYPE.RANGED
    end
    -- 5-8 yards (Deadzone) oder > max_ranged_yards: desired_attack_type bleibt nil

    -- Safety Checks: Nur Auto-Attack starten/switchen wenn mÃƒÂ¶glich
    local can_auto_attack = true

    -- Check 1: Nicht wÃƒÂ¤hrend Casting (wÃƒÂ¼rde den Cast abbrechen)
    if player:is_casting() or player:is_channeling() then
        can_auto_attack = false
    end

    -- Check 2: Target muss in Frontal Arc sein (gilt fÃƒÂ¼r Melee und Ranged)
    if desired_attack_type and not is_in_front_arc(player, target, MELEE_FACING_HALF_ANGLE) then
        can_auto_attack = false
    end

    -- Check 3: Nicht wÃƒÂ¤hrend Movement fÃƒÂ¼r Ranged (Melee geht auch beim Laufen)
    if desired_attack_type == auto_attack_helper.ATTACK_TYPE.RANGED and is_moving then
        -- Allow toggling ranged auto-shot while moving (it will only fire once stationary).
    end

    -- Jetzt entscheiden: Start, Switch, oder Stop
    if can_auto_attack and desired_attack_type then
        -- Fall 1: Auto-Attack nicht aktiv Ã¢â€ â€™ Starten
        if not auto_attack_helper:is_auto_attacking(player) then
            if auto_attack_helper:start_attack(target, desired_attack_type) then
                current_auto_attack_type = desired_attack_type
            else
                current_auto_attack_type = nil
            end

        -- Fall 2: Anderer Attack-Typ aktiv Ã¢â€ â€™ Switchen
        elseif current_auto_attack_type ~= desired_attack_type then
            -- Beide Modi stoppen
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.RANGED)
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)

            -- Neuen Modus starten
            if auto_attack_helper:start_attack(target, desired_attack_type) then
                current_auto_attack_type = desired_attack_type
            else
                current_auto_attack_type = nil
            end
        end
        -- Fall 3: Gleicher Typ bereits aktiv Ã¢â€ â€™ Nichts tun

    elseif not desired_attack_type then
        -- Deadzone oder Out-of-Range Ã¢â€ â€™ Stoppen falls aktiv
        if auto_attack_helper:is_auto_attacking(player) then
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.RANGED)
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
            current_auto_attack_type = nil
        end
    end

    -- Hysteresis to avoid bouncing between melee and deadzone at ~5y due to jitter.
    if melee_range_latched then
        if distance > (MELEE_RANGE_YDS + MELEE_RANGE_GRACE_YDS) then
            melee_range_latched = false
        end
    else
        if distance <= MELEE_RANGE_YDS then
            melee_range_latched = true
        end
    end

    if distance > max_ranged_yards then
        if auto_attack_helper:is_auto_attacking(player) then
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.RANGED)
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
        end
    end


    -- Pet stats
    local pet_hp_percent = pet and not pet:is_dead() and pet:get_health_percentage() or 0

    -- Combat time for pet aggro delay
    local combat_time = player:time_in_combat()

    -- ========================================================================
    -- PRIORITY 1: Pet Management (Always Active)
    -- ========================================================================

    -- Get player level and pet ability status for safety checks
    local player_level = player:get_level()
    local has_pet_ability = spells.call_pet:is_learned() -- Level 10+

    -- Mend Pet if low HP (Level 12+)
    if menu.auto_mend_pet:get_state() and pet and not pet:is_dead() and has_pet_ability then
        if pet_hp_percent <= menu.mend_pet_hp:get() and not is_moving then
            if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                core.log(string.format("[HunterPetMgmt] mend_pet: attempt pet_hp=%.1f%% threshold=%d%%", tonumber(pet_hp_percent) or -1, tonumber(menu.mend_pet_hp:get()) or -1))
            end
            if spells.mend_pet:is_castable() and spells.mend_pet:cast(pet) then
                if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                    core.log(string.format("[HunterPetMgmt] mend_pet: cast OK"))
                end
                return true
            end
            if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() and menu.pet_debug_verbose and menu.pet_debug_verbose.get_state and menu.pet_debug_verbose:get_state() then
                core.log(string.format("[HunterPetMgmt] mend_pet: cast FAIL (castable=%s)", spells.mend_pet:is_castable() and "1" or "0"))
            end
        end
    end

    -- Pet Pullback (Safety)
    if menu.enable_pet_pullback:get_state() and pet and not pet:is_dead() and has_pet_ability then
        if pet_hp_percent < menu.pet_pullback_hp:get() then
            pullback_active = true
            local game_time = core.game_time()
            if (game_time - last_pet_state_request_ms) >= PET_STATE_THROTTLE_MS and last_pet_state ~= pet_handler.pet_state.PASSIVE then
                if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                    core.log(string.format("[HunterPetMgmt] pullback: set PASSIVE pet_hp=%.1f%% < %d%%", tonumber(pet_hp_percent) or -1, tonumber(menu.pet_pullback_hp:get()) or -1))
                end
                last_pet_state_request_ms = game_time
                last_pet_state = pet_handler.pet_state.PASSIVE
                pet_handler:set_pet_state(pet_handler.pet_state.PASSIVE, 0)
            end
        elseif pet_hp_percent >= menu.pet_send_back_hp:get() then
            pullback_active = false
            local desired_state = resolve_pet_combat_state()
            if desired_state then
                local game_time = core.game_time()
                if (game_time - last_pet_state_request_ms) >= PET_STATE_THROTTLE_MS and last_pet_state ~= desired_state then
                    if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                        core.log(string.format("[HunterPetMgmt] pullback: restore state=%s pet_hp=%.1f%% >= %d%%", tostring(desired_state), tonumber(pet_hp_percent) or -1, tonumber(menu.pet_send_back_hp:get()) or -1))
                    end
                    last_pet_state_request_ms = game_time
                    last_pet_state = desired_state
                    pet_handler:set_pet_state(desired_state, 0)
                end
            end
        end
    end

    -- Pet Engage (Workaround): drive pet via casting pet abilities (Bite/Claw/etc.)
    if pet and not pet:is_dead() and not pullback_active then
        local game_time = core.game_time()
        if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() and menu.pet_debug_verbose and menu.pet_debug_verbose.get_state and menu.pet_debug_verbose:get_state() then
            core.log(string.format("[HunterPetMgmt] pet_engage: tick"))
        end
        if pet_engage:try_pet_engage(player, target, menu, spells, game_time) then
            if menu.pet_debug_logs and menu.pet_debug_logs.get_state and menu.pet_debug_logs:get_state() then
                core.log(string.format("[HunterPetMgmt] pet_engage: issued command"))
            end
            return true
        end
    end

    -- ========================================================================
    -- PRIORITY 1.1: Threat Utility (Disengage / Distracting Shot)
    -- ========================================================================

    if try_cast_disengage(player, menu, game_time) then
        return true
    end

    if try_cast_distracting_shot(player, menu, game_time) then
        return true
    end

    -- ========================================================================
    -- PRIORITY 1.5: Survival (Feign Death)
    -- ========================================================================

    if target and not target:is_dead() then
        local pet_ready = pet and not pet:is_dead()
        local can_cast_feign = pet_ready and spells.feign_death:is_learned()
        if can_cast_feign then
            local current_hp = hp_percent or 0

            local emergency_enabled = menu.use_feign_death_emergency and menu.use_feign_death_emergency:get_state() or false
            local emergency_hp = menu.feign_death_emergency_hp and menu.feign_death_emergency_hp:get() or 0
            local emergency_min_aggro = menu.feign_death_emergency_min_aggro and menu.feign_death_emergency_min_aggro:get() or 1
            local emergency_range = menu.feign_death_emergency_range and menu.feign_death_emergency_range:get() or 20

            local multi_enabled = menu.use_feign_death_multi and menu.use_feign_death_multi:get_state() or false
            local multi_hp = menu.feign_death_multi_hp and menu.feign_death_multi_hp:get() or 0
            local multi_min_aggro = menu.feign_death_multi_min_aggro and menu.feign_death_multi_min_aggro:get() or 3
            local multi_range = menu.feign_death_multi_range and menu.feign_death_multi_range:get() or 20

            local check_range = math.max(emergency_range or 0, multi_range or 0)
            local aggro_count = count_aggro_enemies(player, check_range)

            local should_cast = false
            if emergency_enabled and current_hp <= emergency_hp and aggro_count >= emergency_min_aggro then
                should_cast = true
            elseif multi_enabled and current_hp <= multi_hp and aggro_count >= multi_min_aggro then
                should_cast = true
            end

            if should_cast then
                if spells.feign_death:is_castable({ skip_facing = true }) and spells.feign_death:cast(player) then
                    return true
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 2: Health Emergency (HP Potions)
    -- ========================================================================

    if menu.use_healthstones and menu.use_healthstones.get_state and menu.use_healthstones:get_state() then
        local threshold = (menu.healthstone_hp_pct and menu.healthstone_hp_pct.get and menu.healthstone_hp_pct:get()) or 35
        if hp_percent and hp_percent <= threshold then
            if healthstone_item and healthstone_item.in_inventory and healthstone_item:in_inventory() then
                if healthstone_item:use_self_safe("Healthstone") then
                    return true
                end
            end
        end
    end

    if menu.use_hp_potions:get_state() then
        if hp_percent <= menu.hp_potion_at:get() then
            if izi.use_best_health_potion_safe() then
                return true
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 2.5: Mana Emergency (Mana Potions)
    -- ========================================================================

    if menu.use_mana_potions:get_state() then
        if player:mana_pct() <= menu.mana_potion_at:get() then
            -- Only use in combat against boss/elite to avoid wasting on trash
            local classification = target:get_classification() or enums.classification.NORMAL
            if classification >= enums.classification.ELITE then
                if izi.use_best_mana_potion_safe() then
                    return true
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 2.6: Deterrence (Defensive CD)
    -- ========================================================================

    if menu.use_deterrence:get_state() then
        if spells.deterrence:is_learned() then
            if hp_percent <= menu.deterrence_hp:get() then
                -- Emergency: Low HP + Elite/Boss
                local classification = target:get_classification() or enums.classification.NORMAL
                if classification >= enums.classification.ELITE then
                    if spells.deterrence:is_castable({ skip_facing = true }) and spells.deterrence:cast(player) then
                        return true
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 3: Aspect Switching (Combat)
    -- ========================================================================

    local game_time = core.game_time()
    local can_handle_aspects = true

    -- Early exit if channeling/casting
    if player:is_channeling_or_casting() then
        can_handle_aspects = false
    end

    -- Early exit if throttled
    if can_handle_aspects and (game_time - last_aspect_switch) < ASPECT_SWITCH_THROTTLE then
        can_handle_aspects = false
    end

    -- Early exit if saving mana for tranq
    if can_handle_aspects and menu.save_mana_for_tranq:get_state() then
        local current_mana = player:get_power(enums.power_type.MANA)
        if current_mana < 200 then
            can_handle_aspects = false
        end
    end

    if can_handle_aspects then
        local function try_cast_aspect(spell)
            local ok = spell:is_castable({ skip_facing = true }) and spell:cast(player)
            last_aspect_switch = game_time
            return ok
        end

        -- Sync local state with actual buff to keep hysteresis sane
        monkey_aspect_active = player:buff_up(spells.aspect_monkey:id())

        -- Aspect of the Pack Detection (Safety)
        if menu.prevent_pack_combat:get_state() then
            if player:buff_up(spells.aspect_pack:id()) then
                if spells.aspect_hawk:is_learned() then
                    if try_cast_aspect(spells.aspect_hawk) then
                        return true
                    end
                end
            end
        end

        -- Aspect of the Monkey (melee range, low HP) with Hysteresis
        if menu.use_aspect_monkey:get_state() then
            local should_use_monkey = false
            local monkey_threshold = menu.aspect_monkey_hp:get()

            if not monkey_aspect_active then
                if distance <= 8 and hp_percent < monkey_threshold then
                    should_use_monkey = true
                end
            else
                local exit_hp = math.min(100, monkey_threshold + 10)
                if hp_percent >= exit_hp or distance > 10 then
                    should_use_monkey = false
                else
                    should_use_monkey = true
                end
            end

            if should_use_monkey and player:buff_down(spells.aspect_monkey:id()) then
                if try_cast_aspect(spells.aspect_monkey) then
                    monkey_aspect_active = true
                    return true
                end
            elseif not should_use_monkey and monkey_aspect_active then
                monkey_aspect_active = false
            end
        end

        -- Aspect of the Hawk (ranged)
        if menu.use_aspect_hawk:get_state() then
            if distance > 8 or player:buff_up(spells.aspect_cheetah:id()) then
                if player:buff_down(spells.aspect_hawk:id()) then
                    if not player:buff_up(spells.aspect_monkey:id()) then
                        if try_cast_aspect(spells.aspect_hawk) then
                            return true
                        end
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 4: Boss Enrage Detection
    -- ========================================================================

    -- Check boss enrage every 0.5 seconds
    local game_time = core.game_time()
    if game_time - last_enrage_check > 500 then
        last_enrage_check = game_time
        local was_enraged = boss_is_enraged
        boss_is_enraged = false

        -- Check if boss has enrage buff (using izi buff checking)
        for _, enrage_id in ipairs(spells.ENRAGE_BUFFS) do
            if target:buff_up(enrage_id) then
                boss_is_enraged = true
                if not was_enraged then
                    enrage_count = enrage_count + 1
                end
                break
            end
        end
    end

    -- ========================================================================
    -- EARLY LEVEL ROTATION (1-9) - No Pet
    -- ========================================================================

    if distance >= RANGED_MIN_YDS and player_level < 10 then
        -- Hunter's Mark (Level 6+, >20% HP to avoid wasting on dying mobs)
        if menu.use_hunters_mark:get_state() then
            if target:debuff_down(spells.hunters_mark:id()) and target_hp_percent > 20 then
                if not can_cast_instant_ranged_shot(player) then
                    return false
                end
                if spells.hunters_mark:is_castable() and spells.hunters_mark:cast(target) then
                    return true
                end
            end
        end

        -- Concussive Shot for kiting (Level 8+)
        if menu.use_concussive_shot:get_state() then
            if spells.concussive_shot:is_learned() then
                local concussive_target = find_concussive_target(player, target, 8, 15)
                if concussive_target and concussive_target:debuff_down(spells.concussive_shot:id()) then
                    if spells.concussive_shot:is_castable() and spells.concussive_shot:cast(concussive_target) then
                        return true
                    end
                end
            end
        end

        -- Serpent Sting (Level 4+) with TTD/HP thresholds
        if should_cast_serpent(player, target, menu) then
            if not can_cast_instant_ranged_shot(player) then
                return false
            end
            if spells.serpent_sting:is_castable() and spells.serpent_sting:cast(target) then
                return true
            end
        end

        -- Arcane Shot as instant damage (Level 6+, mana >25%)
        if menu.use_arcane_shot:get_state() then
            if spells.arcane_shot:is_learned() then
                if has_enough_mana(player, menu, 25) then
                    if not can_cast_instant_ranged_shot(player) then
                        return false
                    end
                    if spells.arcane_shot:is_castable() and spells.arcane_shot:cast(target) then
                        return true
                    end
                end
            end
        end

        -- Auto Shot wird zentral am Anfang der Rotation gehandhabt

        return false
    end

    -- Concussive Shot (Any Target) when current target is not in ranged rotation
    if distance < RANGED_MIN_YDS then
        if menu.use_concussive_shot:get_state() and spells.concussive_shot:is_learned() then
            local max_distance = player_level < 10 and 15 or menu.concussive_distance:get()
            local concussive_target = find_concussive_target(player, target, RANGED_MIN_YDS, max_distance)
            if concussive_target and concussive_target:debuff_down(spells.concussive_shot:id()) then
                if spells.concussive_shot:is_castable() and spells.concussive_shot:cast(concussive_target) then
                    return true
                end
            end
        end
    end

    -- ========================================================================
    -- RANGED ROTATION (>= 8 Yards)
    -- ========================================================================

    if distance >= RANGED_MIN_YDS then

        -- ====================================================================
        -- PRIORITY 5: Hunter's Mark (Level 6+)
        -- ====================================================================
        -- Cast early for max uptime, but skip on low-HP trash mobs

        if menu.use_hunters_mark:get_state() then
            if target:debuff_down(spells.hunters_mark:id()) then
                -- Only cast on targets with >20% HP to avoid wasting GCD on dying mobs
                if target_hp_percent > 20 then
                    if not can_cast_instant_ranged_shot(player) then
                        return false
                    end
                    if spells.hunters_mark:is_castable() and spells.hunters_mark:cast(target) then
                        return true
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 5.5: Intimidation (Pet Stun + Threat, BM Talent Level 30+)
        -- ====================================================================
        -- 3-second stun that massively increases pet threat
        -- Use early in combat to let pet establish aggro safely

        if (not save_intimidation_for_interrupt_enabled(menu))
            and menu.use_intimidation:get_state() and pet and not pet:is_dead() and has_pet_ability then
            if spells.intimidation:is_learned() then
                -- Only use if pet is in range and target is alive
                local pet_distance = pet:distance_to(target)
                if pet_distance and pet_distance <= 5 then  -- Pet must be in melee range
                    -- Use on targets with >30% HP to maximize value
                    if target_hp_percent > 30 then
                        if spells.intimidation:is_castable() and spells.intimidation:cast(target) then
                            return true
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 6: Tranquilizing Shot (Boss Enrage, Level 26+)
        -- ====================================================================

        if menu.use_tranq_shot:get_state() and boss_is_enraged then
            if spells.tranq_shot:is_learned() then
                -- Check if it's our turn to tranq
                local hunters_tranqing = menu.hunters_that_tranq:get()
                local my_order = menu.tranq_order:get()
                local should_tranq = false

                if hunters_tranqing == 1 then
                    should_tranq = true
                elseif hunters_tranqing == 2 then
                    should_tranq = (enrage_count % 2 == my_order - 1)
                elseif hunters_tranqing == 3 then
                    should_tranq = (enrage_count % 3 == my_order - 1)
                end

                if should_tranq then
                    if spells.tranq_shot:is_castable() and spells.tranq_shot:cast(target) then
                        boss_is_enraged = false
                        return true
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 7: Serpent Sting (DoT, Level 4+)
        -- ====================================================================

        if should_cast_serpent(player, target, menu) then
            if not can_cast_instant_ranged_shot(player) then
                return false
            end
            local ok, meta = (spells.serpent_sting:is_castable() and spells.serpent_sting:cast(target)) or false
            if ok then
                return true
            end

            local reason = meta and meta.reason or "unknown"
            local in_range = target and target.is_spell_in_range and target:is_spell_in_range(spells.serpent_sting) or false
            local has_los = player and player.los_to and target and player:los_to(target) or false
            local serpent_id_active = spells.serpent_sting:id()

            if reason == "not_castable_unit" and spell_queue and serpent_id_active and in_range and has_los then
                safe_spell_queue_purge(spell_queue, serpent_id_active, target)
                spell_queue:queue_spell_target(serpent_id_active, target, 1, nil, true)
                return true
            end
        end

        -- ====================================================================
        -- PRIORITY 7.5: Viper Sting (Mana Drain, Level 12+)
        -- ====================================================================

        if menu.use_viper_sting:get_state() then
            if spells.viper_sting:is_learned() then
                -- Only one hunter sting per target (Serpent/Viper are mutually exclusive).
                if target:debuff_down(VIPER_STING_DEBUFF_IDS) and target:debuff_down(SERPENT_STING_DEBUFF_IDS) then
                    -- Only use on targets with mana (casters/healers)
                    local target_mana = target:get_power(enums.power_type.MANA)
                    if target_mana and target_mana > 0 then
                        if not can_cast_instant_ranged_shot(player) then
                            return false
                        end
                        if spells.viper_sting:is_castable() and spells.viper_sting:cast(target) then
                            return true
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 8: Wait for Pet Aggro (Safety)
        -- ====================================================================

        if menu.wait_for_pet_aggro:get_state() then
            if should_wait_for_pet_aggro(combat_time, target_hp_percent,
                                          menu.pet_aggro_wait_time:get(),
                                          menu.pet_aggro_hp_threshold:get()) then
            return false  -- Don't shoot yet, wait for pet aggro
        end
    end

        -- ====================================================================
        -- PRIORITY 9: Cooldowns (Boss/Elite)
        -- ====================================================================

        if menu.use_cooldowns:get_state() then
            local use_on = menu.use_cds_on:get()
            local classification = target:get_classification() or enums.classification.NORMAL
            local should_use_cds = false

            if use_on == 1 then -- Boss only
                should_use_cds = (classification >= enums.classification.WORLD_BOSS)
            elseif use_on == 2 then -- Elite+
                should_use_cds = (classification >= enums.classification.ELITE)
            else -- Always
                should_use_cds = true
            end

            if should_use_cds then
                -- Bestial Wrath (Level 40+, Beast Mastery talent)
                if pet and not pet:is_dead() then
                    if spells.bestial_wrath:is_learned() then
                        if spells.bestial_wrath:is_castable({ skip_facing = true }) and spells.bestial_wrath:cast(player) then
                            return true
                        end
                    end
                end

                -- Rapid Fire (Level 26+)
                if spells.rapid_fire:is_learned() then
                    if spells.rapid_fire:is_castable({ skip_facing = true }) and spells.rapid_fire:cast(player) then
                        return true
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 10: Aimed Shot (Level 20+)
        -- ====================================================================

        if menu.use_aimed_shot:get_state() and not is_moving then
            local aimed_mana_ok = spells.aimed_shot:is_learned() and has_enough_mana(player, menu, 20)
            if aimed_mana_ok then
                if menu.use_clipped_rotation:get_state() then
                    -- Clipped rotation: cast on CD (good for slow weapons >2.8s)
                    if spells.aimed_shot:is_castable() and spells.aimed_shot:cast(target) then
                        return true
                    end
                else
                    -- Full rotation: cast only if it won't clip the next auto shot
                    local aimed_cast_ms = spells.aimed_shot:cast_time_ms()
                    local buffer_ms = 250
                    local timer_state = ranged_swing_timer:get_state()
                    local time_to_next_auto = timer_state and timer_state.remaining_ms or nil

                    if not time_to_next_auto or not aimed_cast_ms then
                        if spells.aimed_shot:is_castable() and spells.aimed_shot:cast(target) then
                            return true
                        end
                    else
                        if time_to_next_auto >= (aimed_cast_ms + buffer_ms) then
                            if spells.aimed_shot:is_castable() and spells.aimed_shot:cast(target) then
                                return true
                            end
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 11: Volley (Ground AoE, Level 40+)
        -- ====================================================================

        if menu.use_volley and menu.use_volley:get_state() and menu.enable_aoe:get_state() and not is_moving then
            if spells.volley:is_learned() and has_enough_mana(player, menu, 25) then
                local scan_range = max_ranged_yards
                local volley_max = spells.volley.maximum_range
                if volley_max and volley_max > 0 then
                    scan_range = math.min(scan_range, volley_max)
                end

                local center, targets_in_splash = find_best_volley_cluster_center(player, scan_range, now_ms)
                if center and targets_in_splash and targets_in_splash >= (VOLLEY_MIN_OTHER_TARGETS + 1) and not center:is_moving() then
                    local cast_pos = center:get_position()
                    if cast_pos and spells.volley:is_castable_to_position(center, cast_pos, { use_prediction = false, check_los = true }) then
                        if spells.volley:cast_position(cast_pos, "Volley", { use_prediction = false, check_los = true }) then
                            return true
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 11.5: Multi-Shot (AoE, Level 12+)
        -- ====================================================================

        if menu.use_multi_shot:get_state() and not is_moving then
            if spells.multi_shot:is_learned() and has_enough_mana(player, menu, 15) then
                -- Use izi function for cleave detection
                local enemies_nearby = target:get_enemies_in_splash_range_count(8)
                local should_multi = false

                -- Smart AoE Logic:
                -- Single Target (1 enemy): Use Multi-Shot on bosses for max DPS (no AoE toggle needed)
                -- Multi Target (2+ enemies): Require AoE toggle to prevent unwanted aggro
                if enemies_nearby >= 2 then
                    -- Multi-target: Only use if AoE mode is enabled
                    should_multi = menu.enable_aoe:get_state()
                else
                    -- Single target: Use on bosses for DPS optimization
                    if menu.multi_on_boss:get_state() then
                        local classification = target:get_classification() or enums.classification.NORMAL
                        if classification >= enums.classification.WORLD_BOSS then
                            should_multi = true
                        end
                    end
                end

                if should_multi then
                    if not allow_unclipped_instant_after_auto(player, menu, now_ms) then
                        -- Wait for auto-shot to fire before using instants (reduces clipping in unclipped mode).
                        return false
                    end
                    if not can_cast_instant_ranged_shot(player) then
                        return false
                    end
                    if spells.multi_shot:is_castable() and spells.multi_shot:cast(target) then
                        return true
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 12: Arcane Shot (Filler / Moving, Level 6+)
        -- ====================================================================

        if menu.use_arcane_shot:get_state() then
            if spells.arcane_shot:is_learned() and has_enough_mana(player, menu, menu.arcane_shot_min_mana:get()) then
                local aimed_enabled = menu.use_aimed_shot:get_state()
                local aimed_learned = spells.aimed_shot:is_learned()

                -- Use while moving OR as filler if Aimed Shot is not available
                if is_moving or (not aimed_enabled) or (not aimed_learned) then
                    local classification = target:get_classification() or enums.classification.NORMAL
                    local min_ttd = resolve_arcane_min_ttd(menu, classification)
                    local allow_arcane = true
                    if min_ttd and min_ttd > 0 then
                        local ttd = target:time_to_die() or 0
                        if ttd > 0 and ttd < min_ttd then
                            allow_arcane = false
                        end
                    end

                    -- Use is_spell_castable with skip_facing and skip_range for movement
                    if allow_arcane then
                        if (not is_moving) and (not allow_unclipped_instant_after_auto(player, menu, now_ms)) then
                            return false
                        end
                        if not can_cast_instant_ranged_shot(player) then
                            return false
                        end
                        local spell_id = spells.arcane_shot:id()
                        if spell_helper:is_spell_castable(spell_id, player, target, true, true) then
                            if spells.arcane_shot:is_castable() and spells.arcane_shot:cast(target) then
                                return true
                            end
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 13: Concussive Shot (Kiting, Level 8+)
        -- ====================================================================

        if menu.use_concussive_shot:get_state() then
            if spells.concussive_shot:is_learned() then
                local max_distance = menu.concussive_distance:get()
                local concussive_target = find_concussive_target(player, target, 8, max_distance)
                if concussive_target and concussive_target:debuff_down(spells.concussive_shot:id()) then
                    if spells.concussive_shot:is_castable() and spells.concussive_shot:cast(concussive_target) then
                        return true
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 13.5: Scare Beast (Emergency CC, Level 14+)
        -- ====================================================================

        if menu.use_scare_beast:get_state() then
            if spells.scare_beast:is_learned() then
                -- Check if target is a Beast
                local creature_type = target:get_creature_type()
                if creature_type == 1 then -- 1 = Beast
                    -- Emergency CC: only when we're low HP
                    if hp_percent < menu.scare_beast_hp:get() then
                        if spells.scare_beast:is_castable() and spells.scare_beast:cast(target) then
                            return true
                        end
                    end
                end
            end
        end

        -- ====================================================================
        -- PRIORITY 14: Auto Shot (Always Active in Ranged)
        -- ====================================================================

        -- Auto Shot wird zentral am Anfang der Rotation gehandhabt

        return false
    end

    -- ========================================================================
    -- DEAD ZONE (5-8 Yards) - Stop All Attacks
    -- Note: melee latch is still used elsewhere, but auto attacks are always stopped here.
    -- ========================================================================

    if distance > MELEE_RANGE_YDS and distance < RANGED_MIN_YDS then
        -- Stop all auto attacks in deadzone
        if auto_attack_helper:is_auto_attacking(player) then
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.RANGED)
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
        end
        -- Let bot handle movement to get out of deadzone
        return false
    end

    -- ========================================================================
    -- MELEE ROTATION (latched at ~5y)
    -- ========================================================================

    if melee_range_latched then

        -- ====================================================================
        -- PRIORITY 15: Melee Auto Attack (Always Active in Melee)
        -- ====================================================================

        -- Melee Auto Attack wird zentral am Anfang der Rotation gehandhabt

        -- ====================================================================
        -- PRIORITY 16: Wing Clip (Level 12+)
        -- Moved above Raptor Strike to ensure slow is applied before damage filler
        if menu.use_wing_clip:get_state() then
            if spells.wing_clip:is_learned() then
                if target:debuff_down(spells.wing_clip:id()) then
                    if spells.wing_clip:is_castable() and spells.wing_clip:cast(target) then
                        return true
                    end
                end
            end
        end

        -- PRIORITY 17: Raptor Strike (Level 1+)
        if menu.use_raptor_strike:get_state() then
            if spells.raptor_strike:is_learned() and spells.raptor_strike:cooldown_up() then
                local now = core.game_time()
                local attempt_throttle_ms = melee_strikes.raptor_attempt_throttle_ms or 350
                if (now - (melee_strikes.last_raptor_attempt_ms or 0)) >= attempt_throttle_ms then
                    local melee_swing_timer = melee_strikes.swing_timer
                    if melee_swing_timer then
                        melee_swing_timer:on_update()
                        local melee_state = melee_swing_timer:get_state()
                        local swing_ok = true
                        if melee_state and melee_state.is_auto_attacking and melee_state.last_swing and melee_state.remaining_ms then
                            if melee_state.last_swing == (melee_strikes.last_raptor_queued_swing_ms or 0) then
                                swing_ok = false
                            else
                                local window_ms = melee_strikes.raptor_queue_window_ms or 650
                                if melee_state.remaining_ms > window_ms then
                                    swing_ok = false
                                end
                            end
                        end

                        if swing_ok then
                            melee_strikes.last_raptor_attempt_ms = now
                            if melee_state and melee_state.last_swing then
                                melee_strikes.last_raptor_queued_swing_ms = melee_state.last_swing
                            end

                            -- Prefer spell_queue for "next swing" abilities (more reliable than is_castable/cast here)
                            local spell_id = spells.raptor_strike:id()
                            if spell_id and spell_queue then
                                if melee_range_latched and distance <= (MELEE_RANGE_YDS + MELEE_RANGE_GRACE_YDS) and is_in_front_arc(player, target, MELEE_FACING_HALF_ANGLE) then
                                    safe_spell_queue_purge(spell_queue, spell_id, target)
                                    spell_queue:queue_spell_target_fast(spell_id, target, 1, nil, true)
                                    return true
                                end
                            end

                            local ok = spells.raptor_strike:is_castable() and spells.raptor_strike:cast(target)
                            if ok then
                                return true
                            end
                        end
                    end
                end
            end
        end

        -- PRIORITY 18: Mongoose Bite (Level 16+)
        if menu.use_mongoose_bite:get_state() then
            if spells.mongoose_bite:is_learned() then
                local now = core.game_time()
                local attempt_throttle_ms = melee_strikes.mongoose_attempt_throttle_ms or 1200
                if (now - (melee_strikes.last_mongoose_attempt_ms or 0)) >= attempt_throttle_ms then
                    melee_strikes.last_mongoose_attempt_ms = now
                    if not (spells.mongoose_bite.cooldown_up and not spells.mongoose_bite:cooldown_up()) then
                        if spells.mongoose_bite:is_castable() and spells.mongoose_bite:cast(target) then
                            return true
                        end
                    end
                end
            end
        end

        return false
    end

    return false
end

return rotation_logic
