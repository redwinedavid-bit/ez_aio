local __object_safety=require("shared/object_safety")

-- ============================================================================
-- Warrior APL (TBC, Tank Mode override)
-- Project Sylvanas / izi SDK only (no WoW Classic Lua API usage).
-- ============================================================================


local rotation_logic = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

local interrupt_targeting = require("shared/interrupt_targeting")
local spells = require("rotations/warrior/tbc/spells")

---@type shield_swap_helper
local shield_swap_helper = require("rotations/warrior/tbc/shield_swap_helper")

local healthstone_item = izi.item({ 9421, 5510, 5509, 5511, 5512, 19004 })

-- ============================================================================
-- State / throttles
-- ============================================================================
---@alias warrior_content '"open_world"'|'"dungeon"'|'"raid"'

---@param menu table
---@return warrior_content
local function resolve_content_profile(menu)
    local profile = menu and menu.content_profile and menu.content_profile.get and menu.content_profile:get() or 1
    if profile == 2 then
        return "dungeon"
    end
    if profile == 3 then
        return "raid"
    end
    return "open_world"
end

---@param menu table
---@return boolean
local function is_cooldowns_toggle_enabled(menu)
    if not menu or not menu.cooldowns_toggle then
        return true
    end
    return plugin_helper:is_toggle_enabled(menu.cooldowns_toggle) == true
end

local last_offensive_cooldown_check_ms = 0
local OFFENSIVE_COOLDOWN_THROTTLE_MS = 250

local last_stance_request_ms = 0
local STANCE_THROTTLE_MS = 450

local emergency_defensive_hold = false
local EMERGENCY_DEFENSIVE_EXIT_BUFFER_PCT = 10

local last_rage_dump_request_ms = 0
local RAGE_DUMP_THROTTLE_MS = 450

local last_sunder_leveling_request_ms = 0
local SUNDER_LEVELING_THROTTLE_MS = 650

local last_rampage_request_ms = 0
local RAMPAGE_THROTTLE_MS = 1200

local last_tank_aoe_opener_ms = 0
local TANK_AOE_OPENER_THROTTLE_MS = 2500
local TANK_THUNDER_CLAP_MIN_RAGE = 10
local SWEEPING_STRIKES_MIN_RAGE = 30

local last_tank_next_melee_request_ms = 0
local TANK_NEXT_MELEE_THROTTLE_MS = 400

local last_tank_intervene_ms = 0

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

-- Debug logging throttles
local debug_last_log_ms = {}

-- Forward declarations (used by debug helpers before definition)
local rage

-- ============================================================================
-- Helpers
-- ============================================================================

---@param unit game_object|nil
---@return string
local function safe_unit_name(unit)
    if not unit then
        return "nil"
    end
    local ok, name = pcall(function()
        if unit.get_name then
            return unit:get_name()
        end
        return nil
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return tostring(unit)
end

---@param menu table|nil
---@return boolean
local function debug_enabled(menu)
    return menu
        and menu.debug_enabled
        and menu.debug_enabled.get_state
        and menu.debug_enabled:get_state() == true
end

---@param menu table|nil
---@return integer
local function debug_action_interval_ms(menu)
    if not menu or not menu.debug_log_interval_ms or not menu.debug_log_interval_ms.get then
        return 400
    end
    local v = menu.debug_log_interval_ms:get() or 400
    if v < 0 then
        v = 0
    end
    if v > 5000 then
        v = 5000
    end
    return v
end

---@param menu table|nil
---@return integer
local function debug_castability_interval_ms(menu)
    if not menu or not menu.debug_castability_interval_ms or not menu.debug_castability_interval_ms.get then
        return 1200
    end
    local v = menu.debug_castability_interval_ms:get() or 1200
    if v < 0 then
        v = 0
    end
    if v > 5000 then
        v = 5000
    end
    return v
end

---@param menu table|nil
---@param key string
---@param every_ms integer
---@param msg string
local function debug_log_throttled(menu, key, every_ms, msg)
    if not debug_enabled(menu) then
        return
    end
    if not (menu.debug_log_actions and menu.debug_log_actions.get_state and menu.debug_log_actions:get_state() == true) then
        return
    end
    local now = core.game_time()
    local last = debug_last_log_ms[key] or 0
    if every_ms and every_ms > 0 and (now - last) < every_ms then
        return
    end
    debug_last_log_ms[key] = now
    core.log(msg)
end

---@param menu table|nil
---@param key string
---@param every_ms integer
---@param msg string
local function debug_log_castability_throttled(menu, key, every_ms, msg)
    if not debug_enabled(menu) then
        return
    end
    if not (menu.debug_log_castability and menu.debug_log_castability.get_state and menu.debug_log_castability:get_state() == true) then
        return
    end
    local now = core.game_time()
    local last = debug_last_log_ms[key] or 0
    if every_ms and every_ms > 0 and (now - last) < every_ms then
        return
    end
    debug_last_log_ms[key] = now
    core.log(msg)
end

---@param spell izi_spell
---@param caster game_object
---@param target game_object
---@param opts table|nil
---@return boolean
local function can_cast_spell_to_unit(spell, caster, target, opts)
    if not spell or not caster or not target then
        return false
    end

    if not spell.is_learned or spell:is_learned() ~= true then
        return false
    end

    if not spell.id then
        return false
    end

    local spell_id = spell:id()
    if not spell_id or spell_id <= 0 then
        return false
    end

    opts = opts or {}
    local skip_facing = opts.skip_facing == true
    local skip_range = opts.skip_range == true
    local skip_usable = opts.skip_usable == true
    local skip_controller = opts.skip_controller == true
    local skip_learned = opts.skip_learned == true

    return spell_helper:is_spell_castable(spell_id, caster, target, skip_facing, skip_range, skip_usable, skip_controller, skip_learned) == true
end

---@param menu table
---@param spell izi_spell
---@param caster game_object
---@param target game_object
---@param label string
---@param opts table|nil
local function debug_spell_castability(menu, spell, caster, target, label, opts)
    if not debug_enabled(menu) then
        return
    end

    local focus_devastate = menu.debug_focus_devastate and menu.debug_focus_devastate.get_state and menu.debug_focus_devastate:get_state() == true
    local focus_shield_slam = menu.debug_focus_shield_slam and menu.debug_focus_shield_slam.get_state and menu.debug_focus_shield_slam:get_state() == true
    local focus_tc = menu.debug_focus_thunder_clap and menu.debug_focus_thunder_clap.get_state and menu.debug_focus_thunder_clap:get_state() == true
    local focus_interrupt = menu.debug_focus_interrupt and menu.debug_focus_interrupt.get_state and menu.debug_focus_interrupt:get_state() == true
    if label == "Devastate" and not focus_devastate then
        return
    end
    if label == "Shield Slam" and not focus_shield_slam then
        return
    end
    if label == "Thunder Clap" and not focus_tc then
        return
    end
    if (label == "Shield Bash" or label == "Pummel") and not focus_interrupt then
        return
    end
    local focus_revenge = menu.debug_focus_revenge and menu.debug_focus_revenge.get_state and menu.debug_focus_revenge:get_state() == true
    local focus_demo_shout = menu.debug_focus_demo_shout and menu.debug_focus_demo_shout.get_state and menu.debug_focus_demo_shout:get_state() == true
    if label == "Revenge" and not focus_revenge then
        return
    end
    if label == "Demo Shout" and not focus_demo_shout then
        return
    end

    if not spell or not caster or not target then
        return
    end

    local spell_id = spell.id and spell:id() or 0
    if not spell_id or spell_id <= 0 then
        return
    end

    opts = opts or {}
    local skip_facing = opts.skip_facing == true
    local skip_range = opts.skip_range == true
    local skip_usable = opts.skip_usable == true
    local skip_controller = opts.skip_controller == true
    local skip_learned = opts.skip_learned == true

    local can_cast = spell_helper:is_spell_castable(spell_id, caster, target, skip_facing, skip_range, skip_usable, skip_controller, skip_learned) == true
    if can_cast then
        return
    end

    local caster_pos = caster:get_position()
    local target_pos = target:get_position()

    local equipped = false
    local ok_equipped, has_equipped = pcall(function()
        return spell_helper:has_spell_equipped(spell_id)
    end)
    if ok_equipped and has_equipped == true then
        equipped = true
    end

    local on_cd = false
    local ok_cd, cd = pcall(function()
        return spell_helper:is_spell_on_cooldown(spell_id, skip_usable, skip_controller)
    end)
    if ok_cd and cd == true then
        on_cd = true
    end

    local in_los = true
    local ok_los, los = pcall(function()
        return spell_helper:is_spell_in_line_of_sight(spell_id, caster, target)
    end)
    if ok_los and los == false then
        in_los = false
    end

    local in_range = true
    local ok_range, range_ok = pcall(function()
        if not caster_pos or not target_pos then
            return true
        end
        return spell_helper:is_spell_in_range(spell_id, target, caster_pos, target_pos)
    end)
    if ok_range and range_ok == false then
        in_range = false
    end

    local within_angle = true
    local ok_ang, ang_ok = pcall(function()
        if skip_facing then
            return true
        end
        if not caster_pos or not target_pos then
            return true
        end
        return spell_helper:is_spell_within_angle(spell_id, caster, target, caster_pos, target_pos)
    end)
    if ok_ang and ang_ok == false then
        within_angle = false
    end

    local affordable = true
    local ok_cost, costs = pcall(function()
        return spell_helper:get_spell_cost(spell_id)
    end)
    if ok_cost and costs then
        local ok_aff, aff = pcall(function()
            return spell_helper:can_afford_spell(caster, spell_id, costs)
        end)
        if ok_aff and aff == false then
            affordable = false
        end
    end

    debug_log_castability_throttled(
        menu,
        "castability." .. tostring(label) .. "." .. tostring(spell_id),
        debug_castability_interval_ms(menu),
        string.format(
            "[Warrior][Debug][Castability] %s(%d) -> false target=%s equipped=%s cd=%s los=%s range=%s facing=%s afford=%s rage=%d",
            tostring(label),
            tonumber(spell_id) or 0,
            safe_unit_name(target),
            tostring(equipped),
            tostring(on_cd),
            tostring(in_los),
            tostring(in_range),
            tostring(within_angle),
            tostring(affordable),
            tonumber(rage(caster)) or 0
        )
    )
end

---@param unit game_object
---@param aura_id integer
---@return boolean
local function has_aura_id(unit, aura_id)
    if not unit or not aura_id then
        return false
    end

    local ok, auras = pcall(function()
        return unit:get_auras()
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

---@param element table|nil
---@param default_enabled boolean|nil
---@return boolean
local function checkbox_enabled(element, default_enabled)
    if not element then
        return default_enabled == true
    end

    local getter = element.get_state or element.get
    if not getter then
        return default_enabled == true
    end

    local ok, state = pcall(function()
        return getter(element)
    end)
    if not ok or state == nil then
        return default_enabled == true
    end

    if state == true or state == 1 then
        return true
    end
    if state == false or state == 0 then
        return false
    end

    return state ~= false
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
    if not menu or not menu.emergency_defensive_stance then
        emergency_defensive_hold = false
        return false, 0, 0
    end

    if not checkbox_enabled(menu.emergency_defensive_stance, false) then
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
rage = function(player)
    return player:get_power(enums.power_type.RAGE) or 0
end

---@return boolean
local function is_arms_spec()
    return spells.mortal_strike and spells.mortal_strike:is_learned()
        and not (spells.bloodthirst and spells.bloodthirst:is_learned())
end

---@param unit game_object
---@param aura_ids integer[]
---@return boolean
local function has_any_aura_id(unit, aura_ids)
    if not unit or not aura_ids then
        return false
    end

    local ok, auras = pcall(function()
        return unit:get_auras()
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

---@param player game_object
---@param target game_object
---@param menu table
---@param now_ms integer
---@return boolean
local function try_whirlwind_with_optional_stance_dance(player, target, menu, now_ms)
    if not player or not target or not menu then
        return false
    end

    if not spells.whirlwind or not spells.whirlwind:is_learned() then
        return false
    end

    local allow = menu.allow_stance_dance_for_whirlwind_arms
        and menu.allow_stance_dance_for_whirlwind_arms.get_state
        and menu.allow_stance_dance_for_whirlwind_arms:get_state() == true

    if allow and spells.berserker_stance:is_learned() and planned_stance_return_spell == nil and not in_berserker_stance(player) then
        local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste.get
            and menu.interrupt_stance_dance_max_rage_waste:get()) or 0
        max_waste = clamp(max_waste, 0, 100)

        if allow_stance_dance_with_rage(player, menu, max_waste, 25) then
            local current = current_stance_spell(player)
            if current and current ~= spells.berserker_stance and current:is_learned() then
                planned_stance_return_spell = current
                planned_stance_return_until_ms = now_ms + 2500
            else
                planned_stance_return_spell = nil
                planned_stance_return_until_ms = 0
            end

            if try_set_stance(player, spells.berserker_stance) == true then
                return true
            end

            planned_stance_return_spell = nil
            planned_stance_return_until_ms = 0
        end
    end

    if can_cast_spell_to_unit(spells.whirlwind, player, target) then
        if spells.whirlwind:cast(target) then
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
        return local_player:get_party_members_in_range(40, true)
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

    local enemies = unit_helper:get_enemy_list_around(pos, radius or 8, true, false, false, false)
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

    local enemies = unit_helper:get_enemy_list_around(player_pos, range, true, false, false, false)
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

        if should_trigger and can_cast_spell_to_unit(spells.hamstring, player, enemy) then
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

    local enemies = unit_helper:get_enemy_list_around(player_pos, humanoid_range, true, false, false, false)
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

        if can_cast_spell_to_unit(spells.hamstring, player, enemy) then
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
        return player:get_party_members_in_range(40, true)
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

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function should_use_cooldowns(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.use_cooldowns and menu.use_cooldowns.get_state and menu.use_cooldowns:get_state() == true) then
        return false
    end

    if not is_cooldowns_toggle_enabled(menu) then
        return false
    end

    local min_ttd = menu.cooldowns_min_ttd and menu.cooldowns_min_ttd.get and menu.cooldowns_min_ttd:get() or 0
    local ttd = target:time_to_die() or 0
    if min_ttd and min_ttd > 0 and ttd > 0 and ttd < min_ttd then
        return false
    end

    local use_on = menu.use_cds_on and menu.use_cds_on.get and menu.use_cds_on:get() or 1
    if use_on == 3 then
        return true
    end

    if use_on == 1 then
        if unit_helper and unit_helper.is_boss then
            local ok_boss, boss = pcall(function()
                return unit_helper:is_boss(target)
            end)
            if ok_boss and boss == true then
                return true
            end
        end

        local ok_class, classification = pcall(function()
            return target:get_classification()
        end)
        return ok_class and classification and classification >= enums.classification.WORLD_BOSS
    end

    return is_elite_or_boss(target)
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_use_racials(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.use_racials and menu.use_racials.get_state and menu.use_racials:get_state() == true) then
        return false
    end

    local sync = menu.racials_sync_with_cds and menu.racials_sync_with_cds.get_state and menu.racials_sync_with_cds:get_state() == true
    if sync and not should_use_cooldowns(player, target, menu) then
        return false
    end

    local min_ttd = menu.racials_min_ttd and menu.racials_min_ttd.get and menu.racials_min_ttd:get() or 0
    local ttd = target:time_to_die() or 0
    if min_ttd and min_ttd > 0 and ttd > 0 and ttd < min_ttd then
        return false
    end

    if spells.blood_fury and spells.blood_fury:is_learned() then
        if spells.blood_fury:is_castable({ skip_facing = true }) and spells.blood_fury:cast(player) then
            return true
        end
    end

    if spells.berserking and spells.berserking:is_learned() then
        if spells.berserking:is_castable({ skip_facing = true }) and spells.berserking:cast(player) then
            return true
        end
    end

    if spells.arcane_torrent and spells.arcane_torrent:is_learned() then
        local rage_below = menu.arcane_torrent_rage_below and menu.arcane_torrent_rage_below.get and menu.arcane_torrent_rage_below:get() or 25
        if rage(player) <= rage_below then
            if spells.arcane_torrent:is_castable({ skip_facing = true }) and spells.arcane_torrent:cast(player) then
                return true
            end
        end
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

    -- Always prefer direct cast when possible.
    -- This is the most robust "shield equipped?" check (especially for Prot, who already has a shield)
    -- and prevents false-negatives if the equipped shield item_id isn't present in shield_item_ids.lua.
    if can_cast_spell_to_unit(ability_spell, player, target) then
        local ok = ability_spell:cast(target) == true
        if ok then
            -- If the state machine equipped the shield, signal to trigger swap-back.
            local swap_info = shield_swap_helper:get_swap_state()
            if swap_info and swap_info.state == 2 then -- STATE_SHIELD_EQUIPPED
                shield_swap_helper:signal_ability_cast()
            end
            debug_log_throttled(
                menu,
                "shield_ability.cast." .. tostring(ability_name) .. ".direct_precheck",
                debug_action_interval_ms(menu),
                string.format("[Warrior][Debug][Cast] %s -> %s (direct_precheck)", tostring(ability_name),
                    safe_unit_name(target))
            )
        end
        return ok
    end

    -- Feature disabled? Fallback to direct cast
    if not (menu.enable_shield_weapon_swap and menu.enable_shield_weapon_swap.get_state and menu.enable_shield_weapon_swap:get_state()) then
        debug_log_throttled(menu, "shield_ability.disabled." .. tostring(ability_name),
            debug_action_interval_ms(menu),
            string.format("[Warrior][Debug][ShieldSwap] %s: swap disabled, not castable directly", tostring(ability_name)))
        debug_spell_castability(menu, ability_spell, player, target, ability_name)
        return false
    end

    -- Pre-check: Shield already equipped → direct cast, skip swap logic entirely
    local current_equip = shield_swap_helper:detect_current_equipment(player)
    if current_equip and current_equip.has_shield_equipped then
        if can_cast_spell_to_unit(ability_spell, player, target) then
            local ok = ability_spell:cast(target) == true
            if ok then
                -- If state machine equipped this shield (swap in progress), signal to trigger swap back
                local swap_info = shield_swap_helper:get_swap_state()
                if swap_info.state == 2 then  -- STATE_SHIELD_EQUIPPED
                    shield_swap_helper:signal_ability_cast()
                end
                debug_log_throttled(
                    menu,
                    "shield_ability.cast." .. tostring(ability_name),
                    debug_action_interval_ms(menu),
                    string.format("[Warrior][Debug][Cast] %s -> %s (direct)", tostring(ability_name), safe_unit_name(target))
                )
            end
            return ok
        end
        -- Shield equipped but not castable (CD/range/rage) → skip, no swap needed
        debug_log_throttled(menu, "shield_ability.equipped_not_castable." .. tostring(ability_name),
            debug_castability_interval_ms(menu),
            string.format("[Warrior][Debug][ShieldSwap] %s: shield equipped but not castable", tostring(ability_name)))
        debug_spell_castability(menu, ability_spell, player, target, ability_name)
        return false
    end

    -- Shield NOT equipped → check if swap is possible
    local _, reason = shield_swap_helper:needs_swap(player)

    -- No shield available in inventory → Skip ability
    if reason == "no_shield_available" then
        debug_log_throttled(menu, "shield_ability.no_shield." .. tostring(ability_name),
            2000,
            string.format("[Warrior][Debug][ShieldSwap] %s: no shield in inventory", tostring(ability_name)))
        return false
    end

    -- Pre-check: Ability on cooldown? Don't waste time swapping
    if ability_spell.cooldown_up and ability_spell:cooldown_up() == false then
        debug_log_throttled(menu, "shield_ability.on_cd." .. tostring(ability_name),
            debug_castability_interval_ms(menu),
            string.format("[Warrior][Debug][ShieldSwap] %s: on CD, skipping swap", tostring(ability_name)))
        return false
    end

    -- Swap required → State Machine Logic
    local swap_state = shield_swap_helper:get_swap_state()

    if swap_state.state == 0 then  -- STATE_IDLE
        -- Start swap sequence
        if shield_swap_helper:equip_shield_setup(player) then
            debug_log_throttled(menu, "shield_ability.swap_start." .. tostring(ability_name),
                debug_action_interval_ms(menu),
                string.format("[Warrior][Debug][ShieldSwap] %s: swap initiated", tostring(ability_name)))
            return true  -- Processing started
        end
        return false

    elseif swap_state.state == 2 then  -- STATE_SHIELD_EQUIPPED
        -- Ready to cast ability
        if can_cast_spell_to_unit(ability_spell, player, target) then
            if ability_spell:cast(target) then
                -- Signal ability was cast (triggers swap back)
                shield_swap_helper:signal_ability_cast()
                debug_log_throttled(
                    menu,
                    "shield_ability.cast." .. tostring(ability_name),
                    debug_action_interval_ms(menu),
                    string.format("[Warrior][Debug][Cast] %s -> %s (after swap)", tostring(ability_name), safe_unit_name(target))
                )
                return true
            end
        end
        debug_log_throttled(menu, "shield_ability.swap_cast_fail." .. tostring(ability_name),
            debug_action_interval_ms(menu),
            string.format("[Warrior][Debug][ShieldSwap] %s: shield swapped but cast failed", tostring(ability_name)))
        debug_spell_castability(menu, ability_spell, player, target, ability_name)
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
    if not can_cast_spell_to_unit(spells.sunder_armor, player, target) then
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
local function try_tank_thunder_clap(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_thunder_clap and menu.tank_use_thunder_clap:get_state()) then
        return false
    end

    if not spells.thunder_clap:is_learned() then
        return false
    end

    local enemy_count = count_enemies_around_player(player, 8)
    local min_enemies = (menu.tank_thunder_clap_min_enemies and menu.tank_thunder_clap_min_enemies.get and menu.tank_thunder_clap_min_enemies:get()) or 1
    if min_enemies < 1 then
        min_enemies = 1
    end
    if enemy_count < min_enemies then
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

    local refresh_sec = (menu.tank_thunder_clap_refresh_sec and menu.tank_thunder_clap_refresh_sec.get and menu.tank_thunder_clap_refresh_sec:get()) or 3
    refresh_sec = clamp(refresh_sec, 0, 30)
    local refresh_ms = refresh_sec * 1000

    -- Check if ANY enemy in Thunder Clap range (8 yards) needs the debuff refresh
    local player_pos = player:get_position()
    local any_needs_refresh = false
    if player_pos then
        local enemies = unit_helper:get_enemy_list_around(player_pos, 8, true, false, false, false)
        if enemies and #enemies > 0 then
            local tc_id = spells.thunder_clap:id()
            for _, enemy in __object_safety.live_ipairs(enemies) do
                if enemy and enemy:is_valid_enemy() and enemy:is_alive() then
                    local remains = enemy:debuff_remains_ms(tc_id)
                    if remains <= refresh_ms then
                        any_needs_refresh = true
                        break
                    end
                end
            end
        else
            -- Fallback to main target check if no enemies found via helper
            any_needs_refresh = target:debuff_remains_ms(spells.thunder_clap:id()) <= refresh_ms
        end
    else
        -- Fallback if position unavailable
        any_needs_refresh = target:debuff_remains_ms(spells.thunder_clap:id()) <= refresh_ms
    end

    -- Multi-target: bypass debuff check — cast TC on cooldown for AoE threat
    -- Single-target: only cast when debuff needs refreshing
    local aoe_priority = enemy_count >= 2
    if not aoe_priority and not any_needs_refresh then
        return false
    end

    local min_rage = (menu.tank_thunder_clap_min_rage and menu.tank_thunder_clap_min_rage.get and menu.tank_thunder_clap_min_rage:get()) or TANK_THUNDER_CLAP_MIN_RAGE
    min_rage = clamp(min_rage, 0, 100)
    if rage(player) < min_rage then
        debug_log_castability_throttled(
            menu,
            "tank.tc.guard.rage",
            debug_castability_interval_ms(menu),
            string.format(
                "[Warrior][Debug][Tank][Thunder Clap] blocked: rage=%d < min_rage=%d needs_refresh=true enemies=%d",
                tonumber(rage(player)) or 0,
                tonumber(min_rage) or 0,
                tonumber(enemy_count) or 0
            )
        )
        return false
    end

    if (now_ms - last_thunder_clap_request_ms) < THUNDER_CLAP_THROTTLE_MS then
        return false
    end

    local allow_dance = menu.tank_allow_stance_dance_for_thunder_clap and menu.tank_allow_stance_dance_for_thunder_clap:get_state() == true
    local max_waste = (menu.tank_stance_dance_max_rage_waste and menu.tank_stance_dance_max_rage_waste.get and menu.tank_stance_dance_max_rage_waste:get()) or 0
    max_waste = clamp(max_waste, 0, 100)

    -- TBC: Thunder Clap can be used in Defensive Stance. Prefer casting in current stance;
    -- stance-dance is only an optional fallback for niche servers/edge cases.
    -- Range guard: only cast TC when target is within 8 yards (prevents TC during charge flight)
    local target_pos = target:get_position()
    if player_pos and target_pos and dist2(player_pos, target_pos) <= 64 and can_cast_spell_to_unit(spells.thunder_clap, player, target) then
        last_thunder_clap_request_ms = now_ms
        if spells.thunder_clap:cast(target) then
            debug_log_throttled(
                menu,
                "tank.cast.tc",
                debug_action_interval_ms(menu),
                string.format(
                    "[Warrior][Debug][Cast] Thunder Clap -> %s (enemies=%d refresh<=%dms rage=%d)",
                    safe_unit_name(target),
                    tonumber(enemy_count) or 0,
                    tonumber(refresh_ms) or 0,
                    tonumber(rage(player)) or 0
                )
            )
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

    if any_needs_refresh then
        debug_spell_castability(menu, spells.thunder_clap, player, target, "Thunder Clap", nil)
    end

    -- If we're already in Defensive Stance and Thunder Clap wasn't castable, stance-dancing won't help in TBC;
    -- return and let other priorities run (the castability debug above tells why it was blocked).
    if in_defensive_stance(player) then
        return false
    end

    -- Optional fallback: stance-dance into Battle Stance if enabled (for edge cases / server differences).
    if not allow_dance then
        return false
    end

    if not in_battle_stance(player) then
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

    return false
end

-- ============================================================================
-- Additional Tank Abilities (Phase 2)
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function try_berserker_rage_fear_break(player, menu)
    if not player or not menu then
        return false
    end

    if not (menu.tank_use_berserker_rage_fear_break and menu.tank_use_berserker_rage_fear_break:get_state()) then
        return false
    end

    if not spells.berserker_rage or not spells.berserker_rage:is_learned() then
        return false
    end

    -- Check if player has fear, sap, or incapacitate effect
    -- Common fear/CC spell IDs in TBC
    local fear_debuffs = {
        5782,   -- Fear (Warlock)
        6215,   -- Fear (Warlock rank 2)
        6213,   -- Fear (Warlock rank 3)
        5484,   -- Howl of Terror
        8122,   -- Psychic Scream
        10888,  -- Psychic Scream rank 2
        10890,  -- Psychic Scream rank 3
        27610,  -- Psychic Scream rank 4
        1513,   -- Scare Beast
        14327,  -- Scare Beast rank 2
        14328,  -- Scare Beast rank 3
        5246,   -- Intimidating Shout
    }

    local has_fear = false
    for _, debuff_id in ipairs(fear_debuffs) do
        if player:has_debuff(debuff_id) then
            has_fear = true
            break
        end
    end

    if not has_fear then
        return false
    end

    -- Berserker Rage can be cast in any stance but requires Berserker Stance for full effect
    -- However, the fear-break component works from any stance
    if spells.berserker_rage:is_castable() then
        return spells.berserker_rage:cast() == true
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_spell_reflection(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_spell_reflection and menu.tank_use_spell_reflection:get_state()) then
        return false
    end

    if not spells.spell_reflection or not spells.spell_reflection:is_learned() then
        return false
    end

    -- Check if target is casting a spell at us
    local is_casting = false
    local ok_casting, casting = pcall(function()
        if target.is_casting_spell and target.is_channelling_spell then
            return target:is_casting_spell() or target:is_channelling_spell()
        end
        if target.is_casting and target.is_channeling then
            return target:is_casting() or target:is_channeling()
        end
        if target.is_casting then
            return target:is_casting()
        end
        if target.is_channeling then
            return target:is_channeling()
        end
        return false
    end)
    if ok_casting and casting == true then
        is_casting = true
    end
    if not is_casting then
        return false
    end

    -- Check if the spell target is the player
    local ok, cast_target = pcall(function()
        if target.get_active_spell_target then
            return target:get_active_spell_target()
        end
        if target.get_spell_target then
            return target:get_spell_target()
        end
        return nil
    end)

    if not ok or not cast_target or (not __object_safety.same(cast_target,player)) then
        return false
    end

    -- Spell Reflection requires a shield - use shield swap helper
    if try_shield_ability_with_swap(player, player, menu, spells.spell_reflection, "Spell Reflection") then
        return true
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param enemy_count number
---@return boolean
local function try_tank_challenging_shout(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_challenging_shout and menu.tank_use_challenging_shout:get_state()) then
        return false
    end

    if not spells.challenging_shout or not spells.challenging_shout:is_learned() then
        return false
    end

    -- Only use when 3+ enemies and emergency situation
    if enemy_count < 3 then
        return false
    end

    -- Check if multiple enemies are NOT targeting the player (threat loss)
    local player_pos = player:get_position()
    if not player_pos then
        return false
    end

    local enemies = unit_helper:get_enemy_list_around(player_pos, 10, true, false, false, false)
    if not enemies or #enemies < 3 then
        return false
    end

    local not_targeting_player = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy:is_valid_enemy() and enemy:is_alive() then
            local ok, enemy_target = pcall(function()
                return enemy:get_target()
            end)
            if ok and enemy_target and (not __object_safety.same(enemy_target,player)) then
                not_targeting_player = not_targeting_player + 1
            end
        end
    end

    -- Only use if 2+ enemies are not targeting the player (threat emergency)
    if not_targeting_player < 2 then
        return false
    end

    -- Challenging Shout has 10 min CD - only use in emergencies
    if spells.challenging_shout:is_castable() then
        return spells.challenging_shout:cast() == true
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_concussion_blow(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_concussion_blow and menu.tank_use_concussion_blow:get_state()) then
        return false
    end

    if not spells.concussion_blow or not spells.concussion_blow:is_learned() then
        return false
    end

    -- Use on high-priority targets (elites, bosses, or casters)
    local is_elite = is_elite_or_boss(target)
    local is_casting = false
    local ok_casting, casting = pcall(function()
        if target.is_casting and target.is_channeling then
            return target:is_casting() or target:is_channeling()
        end
        if target.is_casting then
            return target:is_casting()
        end
        if target.is_channeling then
            return target:is_channeling()
        end
        return false
    end)
    if ok_casting and casting == true then
        is_casting = true
    end

    -- Only use if target is elite/boss OR is casting (interrupt via stun)
    if not is_elite and not is_casting then
        return false
    end

    -- Check if target is stunnable (not immune)
    -- Basic check: bosses in TBC are often stun-immune, but we try anyway
    if try_shield_ability_with_swap(player, target, menu, spells.concussion_blow, "Concussion Blow") then
        return true
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_disarm(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_disarm and menu.tank_use_disarm.get_state and menu.tank_use_disarm:get_state() == true) then
        return false
    end

    if not spells.disarm or not spells.disarm:is_learned() then
        return false
    end

    do
        local player_pos = player:get_position()
        local target_pos = target:get_position()
        if not player_pos or not target_pos then
            return false
        end
        if dist2(player_pos, target_pos) > (8 * 8) then
            return false
        end
    end

    local players_only = (menu.tank_disarm_players_only and menu.tank_disarm_players_only.get_state and menu.tank_disarm_players_only:get_state() == true)
    if players_only then
        local ok_p, is_p = pcall(function()
            return target.is_player and target:is_player()
        end)
        if not ok_p or is_p ~= true then
            return false
        end
    end

    local melee_only = (menu.tank_disarm_melee_classes_only and menu.tank_disarm_melee_classes_only.get_state and menu.tank_disarm_melee_classes_only:get_state() == true)
    if melee_only then
        local ok_p, is_p = pcall(function()
            return target.is_player and target:is_player()
        end)
        if ok_p and is_p == true then
            local ok_c, cls = pcall(function()
                return target:get_class()
            end)
            if ok_c and cls then
                local is_melee = (cls == enums.class_id.WARRIOR)
                    or (cls == enums.class_id.ROGUE)
                    or (cls == enums.class_id.PALADIN)
                    or (cls == enums.class_id.HUNTER)
                if not is_melee then
                    return false
                end
            end
        end
    end

    if can_cast_spell_to_unit(spells.disarm, player, target) then
        return spells.disarm:cast(target) == true
    end

    debug_spell_castability(menu, spells.disarm, player, target, "Disarm")
    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_mocking_blow(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_mocking_blow and menu.tank_use_mocking_blow:get_state()) then
        return false
    end

    if not spells.mocking_blow:is_learned() then
        return false
    end

    -- Nur wenn Taunt NICHT verfügbar (auf CD oder nicht gelernt)
    if spells.taunt:is_learned() and can_cast_spell_to_unit(spells.taunt, player, target) then
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
    if can_cast_spell_to_unit(spells.mocking_blow, player, target) then
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
    local enemies = unit_helper:get_enemy_list_around(pos, range, true, false, false, false)
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
local function find_best_tab_sunder_target(player, current_target, menu)
    if not player or not current_target or not menu then
        return nil
    end

    if not (menu.tank_tab_sunder_enabled and menu.tank_tab_sunder_enabled:get_state()) then
        return nil
    end

    if not spells.sunder_armor:is_learned() then
        return nil
    end

    local enemy_count = count_enemies_around_player(player, 8)
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

    if use_shield_bash and spells.shield_bash:is_learned() then
        if try_shield_ability_with_swap(player, target, menu, spells.shield_bash, "Shield Bash") then
            last_interrupt_request_ms = now_ms
            return true, true
        else
            local equip = shield_swap_helper:detect_current_equipment(player)
            local needs_swap, reason = shield_swap_helper:needs_swap(player)
            local shield_bash_id = (spells.shield_bash and spells.shield_bash.id and spells.shield_bash:id()) or 0
            debug_log_castability_throttled(menu, "interrupt.shield_bash.details", debug_castability_interval_ms(menu),
                string.format(
                    "[Warrior][Debug][Interrupt] Shield Bash failed: spell_id=%d offhand_id=%d has_shield_equipped=%s needs_swap=%s reason=%s swap_state=%d target=%s",
                    tonumber(shield_bash_id) or 0,
                    tonumber(equip and equip.offhand_id) or 0,
                    tostring(equip and equip.has_shield_equipped == true),
                    tostring(needs_swap == true),
                    tostring(reason),
                    tonumber((shield_swap_helper:get_swap_state() or {}).state) or -1,
                    safe_unit_name(target)
                ))
            debug_spell_castability(menu, spells.shield_bash, player, target, "Shield Bash")
            debug_log_throttled(menu, "interrupt.shield_bash_failed", debug_action_interval_ms(menu),
                string.format("[Warrior][Debug][Interrupt] Shield Bash failed: %s", safe_unit_name(target)))
        end
    end

    if use_pummel and spells.pummel:is_learned() and can_cast_spell_to_unit(spells.pummel, player, target) then
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
            debug_log_throttled(menu, "interrupt.pummel_ok", debug_action_interval_ms(menu),
                string.format("[Warrior][Debug][Interrupt] Pummel -> %s", safe_unit_name(target)))
            return true, true
        end
        debug_log_throttled(menu, "interrupt.pummel_fail", debug_action_interval_ms(menu),
            string.format("[Warrior][Debug][Interrupt] Pummel cast failed: %s", safe_unit_name(target)))
        return false, true
    end

    do
        local use_concussion = false
        if is_tank_mode == true then
            use_concussion = menu.tank_use_concussion_blow
                and menu.tank_use_concussion_blow.get_state
                and menu.tank_use_concussion_blow:get_state() == true
        else
            use_concussion = menu.use_concussion_blow_interrupt
                and menu.use_concussion_blow_interrupt.get_state
                and menu.use_concussion_blow_interrupt:get_state() == true
        end

        if use_concussion then
            if not (spells.concussion_blow and spells.concussion_blow.is_learned and spells.concussion_blow:is_learned() == true) then
                debug_log_throttled(menu, "interrupt.concussion_blow.not_learned", 2000,
                    "[Warrior][Debug][Interrupt] Concussion Blow enabled but not learned (Protection talent)")
            else
                if try_shield_ability_with_swap(player, target, menu, spells.concussion_blow, "Concussion Blow") then
                    last_interrupt_request_ms = now_ms
                    debug_log_throttled(menu, "interrupt.concussion_blow_ok", debug_action_interval_ms(menu),
                        string.format("[Warrior][Debug][Interrupt] Concussion Blow -> %s", safe_unit_name(target)))
                    return true, true
                end
            end
        end
    end

    if not use_pummel or not spells.pummel:is_learned() then
        return false, false
    end

    local allow_dance = menu.allow_stance_dance_for_pummel and menu.allow_stance_dance_for_pummel:get_state() == true
    local allow_dance_tank = menu.allow_stance_dance_for_pummel_in_tank_mode and menu.allow_stance_dance_for_pummel_in_tank_mode:get_state() == true
    if is_tank_mode and not allow_dance_tank then
        debug_log_throttled(menu, "interrupt.tank_pummel_blocked", 2000,
            "[Warrior][Debug][Interrupt] Pummel blocked: tank mode, stance dance disabled")
        return false, false
    end

    if allow_dance and not in_berserker_stance(player) and spells.berserker_stance:is_learned() then
        local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste.get and menu.interrupt_stance_dance_max_rage_waste:get()) or 0
        max_waste = clamp(max_waste, 0, 100)
        if not allow_stance_dance_with_rage(player, menu, max_waste, 10) then
            debug_log_throttled(menu, "interrupt.dance_rage_waste", debug_action_interval_ms(menu),
                "[Warrior][Debug][Interrupt] Pummel stance dance skipped: too much rage waste")
            return false, false
        end

        debug_log_throttled(menu, "interrupt.dance_start", debug_action_interval_ms(menu),
            "[Warrior][Debug][Interrupt] Stance dance to Berserker for Pummel")
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

    debug_log_throttled(menu, "interrupt.target_found", debug_action_interval_ms(menu),
        string.format("[Warrior][Debug][Interrupt] Target: %s casting", safe_unit_name(target)))

    local pct, time_left, cast_end = get_cast_pct_and_time_left(target)
    if cast_end <= 0.0 then
        return false
    end

    debug_log_throttled(menu, "interrupt.timing", debug_action_interval_ms(menu),
        string.format("[Warrior][Debug][Interrupt] %s: pct=%.0f%% threshold=%.0f%% time_left=%.1fs",
            safe_unit_name(target), pct, pending_interrupt_pct, time_left))

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
local function try_rage_dump(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    local current_rage = rage(player)
    local threshold = (menu.rage_dump_threshold and menu.rage_dump_threshold.get and menu.rage_dump_threshold:get()) or 55

    -- Rage-cap prevention: queue HS/Cleave if next swing would cap rage
    local rage_cap_prevention = menu.rage_dump_prevent_cap
        and menu.rage_dump_prevent_cap.get_state
        and menu.rage_dump_prevent_cap:get_state() == true
    if rage_cap_prevention then
        local est_rage = menu.rage_dump_estimated_rage_per_hit
            and menu.rage_dump_estimated_rage_per_hit.get
            and menu.rage_dump_estimated_rage_per_hit:get() or 20
        est_rage = clamp(est_rage, 5, 50)
        if (current_rage + est_rage) >= 100 then
            goto rage_dump_proceed
        end
    end

    if current_rage < threshold then
        return false
    end
    ::rage_dump_proceed::

    local now_ms = core.game_time()
    if (now_ms - last_rage_dump_request_ms) < RAGE_DUMP_THROTTLE_MS then
        return false
    end

    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true
    local aoe_min = (menu.aoe_min_enemies and menu.aoe_min_enemies.get and menu.aoe_min_enemies:get()) or 2
    if aoe_min < 2 then
        aoe_min = 2
    end
    local enemy_count = count_enemies_around_player(player, 8)

    if aoe_enabled and enemy_count >= aoe_min then
        if menu.use_cleave and menu.use_cleave:get_state() and spells.cleave:is_learned() then
            if can_cast_spell_to_unit(spells.cleave, player, target) then
                last_rage_dump_request_ms = now_ms
                return spells.cleave:cast(target) == true
            end
        end
    end

    if menu.use_heroic_strike and menu.use_heroic_strike:get_state() and spells.heroic_strike:is_learned() then
        if can_cast_spell_to_unit(spells.heroic_strike, player, target) then
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

    if checkbox_enabled(menu.use_healthstones, false) then
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

    if checkbox_enabled(menu.use_hp_potions, false) then
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

    if checkbox_enabled(menu.use_last_stand, false) and spells.last_stand:is_learned() then
        local threshold = (menu.last_stand_hp_pct and menu.last_stand_hp_pct:get()) or 25
        if hp_below(hp_pct, threshold) then
            if can_cast_spell_to_unit(spells.last_stand, player, player, { skip_facing = true, skip_range = true }) then
                if spells.last_stand:cast(player) then
                    return true
                end
            elseif spells.defensive_stance and spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
                return try_set_stance(player, spells.defensive_stance)
            end
        end
    end

    if checkbox_enabled(menu.use_shield_wall, false) and spells.shield_wall:is_learned() then
        local threshold = (menu.shield_wall_hp_pct and menu.shield_wall_hp_pct:get()) or 18
        if hp_below(hp_pct, threshold) then
            if can_cast_spell_to_unit(spells.shield_wall, player, player, { skip_facing = true, skip_range = true }) then
                if try_shield_ability_with_swap(player, player, menu, spells.shield_wall, "Shield Wall") then
                    return true
                end
            elseif spells.defensive_stance and spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
                return try_set_stance(player, spells.defensive_stance)
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
local within_melee_range
local function try_keep_battle_shout(player, menu)
    if not player or not menu then
        return false
    end

    local cb_exists = menu.keep_battle_shout ~= nil
    local cb_state = cb_exists and menu.keep_battle_shout:get_state()
    if not cb_state then
        debug_log_throttled(menu, "battle_shout.disabled", 5000,
            string.format("[Warrior][Debug][BattleShout] checkbox disabled (exists=%s state=%s)",
                tostring(cb_exists), tostring(cb_state)))
        return false
    end

    local shout = spells.battle_shout
    local mode = menu.shout_mode and menu.shout_mode.get and menu.shout_mode:get() or 1
    if mode == 2 then
        if spells.commanding_shout and spells.commanding_shout:is_learned() then
            shout = spells.commanding_shout
        end
    elseif mode == 3 then
        if spells.commanding_shout and spells.commanding_shout:is_learned() then
            shout = spells.commanding_shout
        end
    end

    local shout_nil = shout == nil
    local has_is_learned = not shout_nil and shout.is_learned ~= nil
    local is_learned = has_is_learned and shout:is_learned()
    if shout_nil or not has_is_learned or is_learned ~= true then
        debug_log_throttled(menu, "battle_shout.not_learned", 5000,
            string.format("[Warrior][Debug][BattleShout] not learned (nil=%s has_method=%s learned=%s mode=%d)",
                tostring(shout_nil), tostring(has_is_learned), tostring(is_learned), mode))
        return false
    end

    local shout_id = shout:id()
    local ok_down, is_down = pcall(function() return player:buff_down(shout_id) end)
    local ok_up, has_buff = pcall(function() return player:has_buff(shout_id) end)
    local ok_r, remains = pcall(function() return player:buff_remains_ms(shout_id) end)

    debug_log_throttled(menu, "battle_shout.state", 3000,
        string.format("[Warrior][Debug][BattleShout] id=%d mode=%d buff_down=%s has_buff=%s remains=%s rage=%d",
            shout_id, mode,
            ok_down and tostring(is_down) or "err",
            ok_up and tostring(has_buff) or "err",
            ok_r and tostring(remains) or "err",
            rage(player)))

    if not (ok_down and is_down) then
        return false
    end

    -- Buff is down — try to cast
    local castable = shout:is_castable({ skip_facing = true })
    if not castable then
        debug_log_throttled(menu, "battle_shout.not_castable", 2000,
            string.format("[Warrior][Debug][BattleShout] buff_down but NOT castable id=%d rage=%d",
                shout_id, rage(player)))
        return false
    end

    core.log(string.format("[Warrior][Debug][BattleShout] CASTING id=%d rage=%d", shout_id, rage(player)))
    local cast_ok = shout:cast(player)
    core.log(string.format("[Warrior][Debug][BattleShout] cast result=%s id=%d", tostring(cast_ok), shout_id))
    return cast_ok == true
end

---@param time_value number|nil
---@return number|nil
local function normalize_time_ms(time_value)
    if not time_value then
        return nil
    end
    if time_value < 10000 then
        return time_value * 1000
    end
    return time_value
end

---@param player game_object
---@return number|nil
local function get_next_swing_remaining_ms(player)
    if not player then
        return nil
    end

    local ok_next, next_swing = pcall(function()
        return auto_attack_helper:get_next_attack_game_time(player, 1)
    end)
    if not ok_next then
        return nil
    end

    local now = core.game_time()
    next_swing = normalize_time_ms(next_swing)
    now = normalize_time_ms(now)
    if not next_swing or not now then
        return nil
    end

    local remaining = next_swing - now
    if remaining < 0 then
        remaining = 0
    end
    return remaining
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_arms_slam_weave(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.use_slam_arms and menu.use_slam_arms.get_state and menu.use_slam_arms:get_state() == true) then
        return false
    end

    if not spells.slam or not spells.slam:is_learned() then
        return false
    end

    if player:is_moving() then
        return false
    end

    local min_rage = menu.slam_min_rage and menu.slam_min_rage.get and menu.slam_min_rage:get() or 25
    min_rage = clamp(min_rage, 0, 100)
    if rage(player) < min_rage then
        return false
    end

    if not within_melee_range(player, target) then
        return false
    end

    local assumed_cast_ms = menu.slam_assumed_cast_ms and menu.slam_assumed_cast_ms.get and menu.slam_assumed_cast_ms:get() or 550
    assumed_cast_ms = clamp(assumed_cast_ms, 200, 1500)
    local buffer_ms = menu.slam_swing_buffer_ms and menu.slam_swing_buffer_ms.get and menu.slam_swing_buffer_ms:get() or 120
    buffer_ms = clamp(buffer_ms, 0, 300)

    local remaining = get_next_swing_remaining_ms(player)
    if not remaining then
        return false
    end
    if remaining and remaining > 0 and remaining < (assumed_cast_ms + buffer_ms) then
        return false
    end

    -- Post-swing window: only cast Slam immediately after an auto-attack lands
    local ok_last, last_swing = pcall(function()
        return auto_attack_helper:get_last_attack_game_time(player, 1)
    end)
    if ok_last and last_swing then
        last_swing = normalize_time_ms(last_swing)
        local now_norm = normalize_time_ms(core.game_time())
        if last_swing and now_norm then
            local since_swing = now_norm - last_swing
            local window = menu.slam_post_swing_window_ms
                and menu.slam_post_swing_window_ms.get
                and menu.slam_post_swing_window_ms:get() or 400
            window = clamp(window, 100, 800)
            if since_swing < 0 or since_swing > window then
                return false
            end
        end
    end

    if can_cast_spell_to_unit(spells.slam, player, target) then
        return spells.slam:cast(target) == true
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_intervene(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_intervene and menu.tank_use_intervene.get_state and menu.tank_use_intervene:get_state() == true) then
        return false
    end

    if not spells.intervene or not spells.intervene:is_learned() then
        return false
    end

    local now_ms = core.game_time()
    local throttle = menu.tank_intervene_throttle_ms and menu.tank_intervene_throttle_ms.get and menu.tank_intervene_throttle_ms:get() or 1200
    throttle = clamp(throttle, 300, 5000)
    if (now_ms - last_tank_intervene_ms) < throttle then
        return false
    end

    -- Prefer Taunt when available.
    if spells.taunt and spells.taunt:is_learned() and can_cast_spell_to_unit(spells.taunt, player, target) then
        return false
    end

    local ok_t, enemy_target = pcall(function()
        return target:get_target()
    end)
    if not ok_t or not enemy_target or (__object_safety.same(enemy_target,player)) then
        return false
    end

    local ok_pm, is_party = pcall(function()
        return enemy_target:is_party_member()
    end)
    if not ok_pm or is_party ~= true then
        return false
    end

    local hp_pct = enemy_target:get_health_percentage() or 100
    local hp_threshold = menu.tank_intervene_hp_pct and menu.tank_intervene_hp_pct.get and menu.tank_intervene_hp_pct:get() or 35
    hp_threshold = clamp(hp_threshold, 0, 100)
    if (hp_pct or 100) > hp_threshold then
        return false
    end

    if can_cast_spell_to_unit(spells.intervene, player, enemy_target) then
        last_tank_intervene_ms = now_ms
        return spells.intervene:cast(enemy_target) == true
    end

    return false
end

within_melee_range = function(player, unit)
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
            if can_cast_spell_to_unit(spells.demoralizing_shout, player, target) then
                if spells.demoralizing_shout:cast(target) then
                    last_tank_aoe_opener_ms = now_ms
                    return true
                end
            end
        end
    end

    if menu.keep_battle_shout and menu.keep_battle_shout:get_state() and spells.battle_shout and spells.battle_shout:is_learned() then
        local ok_party, party_members = pcall(function()
            return player:get_party_members_in_range(40, true)
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

local function try_tank_tabbed_revenge(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    if not (menu.tank_use_revenge and menu.tank_use_revenge:get_state()) then
        return false
    end

    if not spells.revenge or not spells.revenge:is_learned() then
        debug_log_castability_throttled(menu, "tank.revenge.not_learned",
            debug_castability_interval_ms(menu),
            string.format("[Warrior][Debug][Tank][Revenge] NOT LEARNED: resolved_id=%d",
                (spells.revenge and spells.revenge.id and spells.revenge:id()) or 0))
        return false
    end

    local ordered = { target }
    local candidates = get_nearest_engaged_enemies(player, target, menu, 12, 6)
    if candidates then
        for _, enemy in __object_safety.live_ipairs(candidates) do
            if enemy and (not __object_safety.same(enemy,target)) then
                ordered[#ordered + 1] = enemy
            end
        end
    end

    local seen = {}
    for _, enemy in __object_safety.live_ipairs(ordered) do
        if enemy and not seen[enemy] then
            seen[enemy] = true
            if can_cast_spell_to_unit(spells.revenge, player, enemy) then
                if spells.revenge:cast(enemy) then
                    debug_log_throttled(menu, "tank.cast.revenge", debug_action_interval_ms(menu),
                        string.format("[Warrior][Debug][Cast] Revenge -> %s (id=%d)",
                            safe_unit_name(enemy), (spells.revenge:id()) or 0))
                    return true
                end
            else
                debug_spell_castability(menu, spells.revenge, player, enemy, "Revenge", nil)
            end
        end
    end

    return false
end

---@param player game_object
---@param target game_object
---@return boolean
local function try_cast_devastate(player, target, menu)
    if not player or not target or not spells.devastate then
        return false
    end

    if not spells.devastate:is_learned() then
        return false
    end

    if not can_cast_spell_to_unit(spells.devastate, player, target) then
        debug_spell_castability(menu, spells.devastate, player, target, "Devastate", nil)
        return false
    end

    local ok = spells.devastate:cast(target) == true
    if ok then
        debug_log_throttled(
            menu,
            "cast.devastate",
            debug_action_interval_ms(menu),
            string.format("[Warrior][Debug][Cast] Devastate -> %s", safe_unit_name(target))
        )
    end
    return ok
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_shield_slam(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    local enabled = menu.tank_use_shield_slam and menu.tank_use_shield_slam.get_state and menu.tank_use_shield_slam:get_state() == true
    if not enabled then
        debug_log_castability_throttled(
            menu,
            "tank.shield_slam.guard.off",
            debug_castability_interval_ms(menu),
            "[Warrior][Debug][Tank][ShieldSlam] skipped: tank_use_shield_slam is OFF"
        )
        return false
    end

    local learned = spells.shield_slam and spells.shield_slam.is_learned and spells.shield_slam:is_learned() == true
    if not learned then
        debug_log_castability_throttled(
            menu,
            "tank.shield_slam.guard.not_learned",
            debug_castability_interval_ms(menu),
            string.format(
                "[Warrior][Debug][Tank][ShieldSlam] skipped: not learned (resolved_id=%d)",
                (spells.shield_slam and spells.shield_slam.id and spells.shield_slam:id()) or 0
            )
        )
        if spells.devastate and spells.devastate.is_learned and spells.devastate:is_learned() == true then
            debug_log_castability_throttled(
                menu,
                "tank.shield_slam.anomaly.devastate_learned",
                math.max(debug_castability_interval_ms(menu), 1500),
                "[Warrior][Debug][Tank][ShieldSlam] anomaly: Devastate learned but Shield Slam not learned/could not resolve"
            )
        end
        debug_spell_castability(menu, spells.shield_slam, player, target, "Shield Slam", nil)
        return false
    end

    if try_shield_ability_with_swap(player, target, menu, spells.shield_slam, "Shield Slam") then
        return true
    end

    local equip = nil
    local needs_swap = false
    local reason = "unknown"
    pcall(function()
        equip = shield_swap_helper:detect_current_equipment(player)
    end)
    pcall(function()
        local ns, why = shield_swap_helper:needs_swap(player)
        needs_swap = ns == true
        reason = why or "unknown"
    end)

    local stance = "unknown"
    if in_defensive_stance(player) then
        stance = "defensive"
    elseif in_battle_stance(player) then
        stance = "battle"
    elseif in_berserker_stance(player) then
        stance = "berserker"
    end

    debug_log_castability_throttled(
        menu,
        "tank.shield_slam.failure.details",
        debug_castability_interval_ms(menu),
        string.format(
            "[Warrior][Debug][Tank][ShieldSlam] failed: spell_id=%d learned=%s enabled=%s rage=%d stance=%s offhand_id=%d has_shield_equipped=%s needs_swap=%s reason=%s swap_state=%d target=%s",
            tonumber((spells.shield_slam and spells.shield_slam.id and spells.shield_slam:id()) or 0) or 0,
            tostring(learned),
            tostring(enabled),
            tonumber(rage(player)) or 0,
            tostring(stance),
            tonumber(equip and equip.offhand_id) or 0,
            tostring(equip and equip.has_shield_equipped == true),
            tostring(needs_swap == true),
            tostring(reason),
            tonumber((shield_swap_helper:get_swap_state() or {}).state) or -1,
            safe_unit_name(target)
        )
    )
    debug_spell_castability(menu, spells.shield_slam, player, target, "Shield Slam", nil)
    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_leveling_rotation(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    local enemy_count = count_enemies_around_player(player, 8)

    if try_defensives(player, target, menu, enemy_count) then
        return true
    end

    if try_hamstring_on_humanoid_low_hp(player, menu) then
        return true
    end

    if try_hamstring_on_target_loss(player, menu) then
        return true
    end

    if menu.auto_battle_stance and menu.auto_battle_stance:get_state() then
        if not emergency_defensive_hold and spells.battle_stance:is_learned() and not in_battle_stance(player) then
            if try_set_stance(player, spells.battle_stance) then
                return true
            end
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
        if can_cast_spell_to_unit(spells.overpower, player, target) then
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
            if hp_pct <= pool_start then
                execute_pooling = true
            end
        end
    end

    if try_sunder_leveling(player, target, menu, execute_pooling) then
        return true
    end

    if menu.use_execute and menu.use_execute:get_state() and spells.execute:is_learned() then
        local hp_pct = target:get_health_percentage() or 100
        local threshold = (menu.execute_hp_pct and menu.execute_hp_pct:get()) or 20
        if hp_pct <= threshold then
            if execute_pooling then
                local min_rage = (menu.execute_pool_min_rage and menu.execute_pool_min_rage.get and menu.execute_pool_min_rage:get()) or 60
                if rage(player) < min_rage then
                    -- Hold rage; do not spend on dumps below.
                    goto execute_skip
                end
            end
            if can_cast_spell_to_unit(spells.execute, player, target) then
                if spells.execute:cast(target) then
                    return true
                end
            end
        end
        ::execute_skip::
    end

    if menu.use_mortal_strike and menu.use_mortal_strike:get_state() and spells.mortal_strike:is_learned() then
        if not execute_pooling or not (menu.execute_pool_skip_mortal_strike and menu.execute_pool_skip_mortal_strike.get_state and menu.execute_pool_skip_mortal_strike:get_state()) then
        if can_cast_spell_to_unit(spells.mortal_strike, player, target) then
            if spells.mortal_strike:cast(target) then
                return true
            end
        end
        end
    end

    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true
    local aoe_min = (menu.aoe_min_enemies and menu.aoe_min_enemies.get and menu.aoe_min_enemies:get()) or 2

    if aoe_enabled and enemy_count >= aoe_min then
        if menu.use_sweeping_strikes and menu.use_sweeping_strikes:get_state() and spells.sweeping_strikes:is_learned() then
            if execute_pooling and (menu.execute_pool_skip_aoe and menu.execute_pool_skip_aoe.get_state and menu.execute_pool_skip_aoe:get_state()) then
                goto skip_sweeping
            end
            local sweep_id = spells.sweeping_strikes:id()
            local ok_down, down = pcall(function() return player:buff_down(sweep_id) end)
            down = (ok_down and down == true) or (not ok_down)
            if down ~= true then
                goto skip_sweeping
            end

            -- TBC: On some servers, Sweeping Strikes is usable in Battle OR Berserker Stance.
            if not (in_battle_stance(player) or in_berserker_stance(player)) then
                local allow_dance = menu.allow_stance_dance_for_sweeping_strikes
                    and menu.allow_stance_dance_for_sweeping_strikes.get_state
                    and menu.allow_stance_dance_for_sweeping_strikes:get_state() == true

                if allow_dance and spells.battle_stance:is_learned() and planned_stance_return_spell == nil and rage(player) >= SWEEPING_STRIKES_MIN_RAGE then
                    local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste.get
                        and menu.interrupt_stance_dance_max_rage_waste:get()) or 0
                    max_waste = clamp(max_waste, 0, 100)

                    if allow_stance_dance_with_rage(player, menu, max_waste, SWEEPING_STRIKES_MIN_RAGE) then
                        local now_ms = core.game_time()
                        local current = current_stance_spell(player)
                        if current and current ~= spells.battle_stance and current:is_learned() then
                            planned_stance_return_spell = current
                            planned_stance_return_until_ms = now_ms + 2500
                        else
                            planned_stance_return_spell = nil
                            planned_stance_return_until_ms = 0
                        end

                        if try_set_stance(player, spells.battle_stance) == true then
                            return true
                        end

                        planned_stance_return_spell = nil
                        planned_stance_return_until_ms = 0
                    end
                end

                debug_log_castability_throttled(
                    menu,
                    "level.sweeping.block.stance",
                    debug_castability_interval_ms(menu),
                    string.format(
                        "[Warrior][Debug][Sweeping Strikes] blocked: not in Battle/Berserker Stance (rage=%d enemies=%d)",
                        tonumber(rage(player)) or 0,
                        tonumber(enemy_count) or 0
                    )
                )
                goto skip_sweeping
            end

            if can_cast_spell_to_unit(spells.sweeping_strikes, player, player, { skip_facing = true, skip_range = true }) then
                if spells.sweeping_strikes:cast(player) then
                    if planned_stance_return_spell then
                        local now_ms = core.game_time()
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
            debug_spell_castability(menu, spells.sweeping_strikes, player, player, "Sweeping Strikes", { skip_facing = true, skip_range = true })
            ::skip_sweeping::
        end
    end

    if aoe_enabled and enemy_count >= aoe_min then
        if menu.use_whirlwind and menu.use_whirlwind:get_state() and spells.whirlwind:is_learned() then
            if execute_pooling and (menu.execute_pool_skip_aoe and menu.execute_pool_skip_aoe.get_state and menu.execute_pool_skip_aoe:get_state()) then
                goto skip_whirlwind
            end
            if can_cast_spell_to_unit(spells.whirlwind, player, target) then
                if spells.whirlwind:cast(target) then
                    return true
                end
            end
            ::skip_whirlwind::
        end
    end

    if menu.use_rend and menu.use_rend:get_state() and spells.rend:is_learned() then
        -- Rend is a bleed and will fail on Mechanical / Elemental targets (e.g. Harvest Watchers).
        do
            local ok_ct, ct = pcall(function()
                return target:get_creature_type()
            end)
            if ok_ct and ct then
                if ct == enums.creature_type.MECHANICAL or ct == enums.creature_type.ELEMENTAL then
                    goto rend_skip
                end
            end
        end
        if target:debuff_down(spells.rend:id()) then
            local min_ttd = (menu.rend_min_ttd and menu.rend_min_ttd.get and menu.rend_min_ttd:get()) or 6
            local ttd = target:time_to_die() or 0
            if min_ttd <= 0 or ttd <= 0 or ttd >= min_ttd then
                if can_cast_spell_to_unit(spells.rend, player, target) then
                    if spells.rend:cast(target) then
                        return true
                    end
                end
            end
        end
        ::rend_skip::
    end

    if menu.use_demoralizing_shout and menu.use_demoralizing_shout:get_state()
        and spells.demoralizing_shout:is_learned()
        and within_melee_range(player, target) then
        if target:debuff_down(spells.demoralizing_shout:id()) then
            if can_cast_spell_to_unit(spells.demoralizing_shout, player, target) then
                if spells.demoralizing_shout:cast(target) then
                    return true
                end
            end
        end
    end

    if menu.use_devastate and menu.use_devastate:get_state() then
        if try_cast_devastate(player, target, menu) then
            return true
        end
    end

    if not execute_pooling then
        if try_rage_dump(player, target, menu) then
        return true
    end
    end

    return false
end

---@param player game_object
---@param menu table
---@return boolean
local function try_pvp_disarm_shield_swap(player, menu)
    if not player or not menu then return false end
    if not checkbox_enabled(menu.pvp_disarm_shield_swap, true) then return false end
    
    -- Check for common Disarm debuffs (Disarm, Riposte, etc.)
    local disarm_ids = { 676, 23349, 14177, 14288, 18529, 20584 }
    if has_any_aura_id(player, disarm_ids) then
        if shield_swap_helper:needs_swap(player) then
            if shield_swap_helper:equip_shield_setup(player) then
                debug_log_throttled(menu, "pvp.disarm_swap", 2000, "[Warrior][PvP] Disarmed! Swapping to shield.")
                return true
            end
        end
    end
    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param now_ms number
---@return boolean
local function try_pvp_overpower_with_dance(player, target, menu, now_ms)
    if not player or not target or not menu then return false end
    if not checkbox_enabled(menu.pvp_auto_overpower_dance, true) then return false end
    if not spells.overpower or not spells.overpower:is_learned() then return false end

    -- Check if it's usable (proc'd) regardless of stance
    if can_cast_spell_to_unit(spells.overpower, player, target, { skip_controller = true }) then
        if in_battle_stance(player) then
            if can_cast_spell_to_unit(spells.overpower, player, target) then
                if spells.overpower:cast(target) then
                    if planned_stance_return_spell then
                        local delay_ms = (menu.stance_dance_return_delay_ms and menu.stance_dance_return_delay_ms:get()) or 900
                        schedule_stance_return(planned_stance_return_spell, now_ms, 2500, now_ms + delay_ms)
                        planned_stance_return_spell = nil
                    end
                    return true
                end
            end
        else
            -- Proc'd but in wrong stance -> Dance to Battle Stance
            if spells.battle_stance:is_learned() then
                local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste:get()) or 10
                if allow_stance_dance_with_rage(player, menu, max_waste, 5) then
                    local current = current_stance_spell(player)
                    if current and current ~= spells.battle_stance then
                        planned_stance_return_spell = current
                        planned_stance_return_until_ms = now_ms + 2500
                        if try_set_stance(player, spells.battle_stance) then
                            debug_log_throttled(menu, "pvp.overpower_dance", 1000, "[Warrior][PvP] Overpower proc! Dancing to Battle Stance.")
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param now_ms number
---@return boolean
local function try_pvp_smart_intercept(player, target, menu, now_ms)
    if not player or not target or not menu then return false end
    if not checkbox_enabled(menu.pvp_smart_intercept, true) then return false end
    if not spells.intercept or not spells.intercept:is_learned() then return false end
    
    -- Only intercept if we are out of melee range but in intercept range
    if not within_melee_range(player, target) then
        if can_cast_spell_to_unit(spells.intercept, player, target, { skip_controller = true }) then
            if in_berserker_stance(player) then
                if can_cast_spell_to_unit(spells.intercept, player, target) then
                    return spells.intercept:cast(target) == true
                end
            else
                -- Dance for Intercept
                if spells.berserker_stance:is_learned() then
                    local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste:get()) or 10
                    if allow_stance_dance_with_rage(player, menu, max_waste, 10) then
                        local current = current_stance_spell(player)
                        if current and current ~= spells.berserker_stance then
                            planned_stance_return_spell = current
                            planned_stance_return_until_ms = now_ms + 2500
                            if try_set_stance(player, spells.berserker_stance) then
                                debug_log_throttled(menu, "pvp.intercept_dance", 1000, "[Warrior][PvP] Target kiting. Dancing for Intercept.")
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param now_ms number
---@return boolean
local function handle_pvp_logic(player, target, menu, now_ms)
    if not checkbox_enabled(menu.enable_pvp_mode, false) then return false end
    
    if try_pvp_disarm_shield_swap(player, menu) then return true end
    
    -- Mortal Strike Priority (Arms only)
    if is_arms_spec() and checkbox_enabled(menu.pvp_priority_ms, true) then
        local ms_id = spells.mortal_strike:id()
        local remains = target:aura_remains_ms(ms_id)
        if (remains < 1500 or not target:has_aura(ms_id)) then
            if can_cast_spell_to_unit(spells.mortal_strike, player, target) then
                if spells.mortal_strike:cast(target) then return true end
            end
        end
    end

    if try_pvp_overpower_with_dance(player, target, menu, now_ms) then return true end
    if try_pvp_smart_intercept(player, target, menu, now_ms) then return true end
    
    -- Anti-Stealth / Peel Piercing Howl
    if is_arms_spec() and checkbox_enabled(menu.pvp_auto_piercing_howl, true) and spells.piercing_howl:is_learned() then
        local enemy_count = count_enemies_around_player(player, 10)
        if enemy_count >= 2 and rage(player) >= 10 then
            if spells.piercing_howl:is_castable({ skip_facing = true }) then
                if spells.piercing_howl:cast(player) then return true end
            end
        end
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@param content warrior_content
---@return boolean
local function try_dps_rotation(player, target, menu, content)
    if not player or not target or not menu then
        return false
    end

    local now_ms = core.game_time()
    local enemy_count = count_enemies_around_player(player, 8)
    -- Queue next-melee rage dump early. HS/Cleave are off-GCD, so we should not block the GCD rotation by returning.
    local queued_dump = false
    do
        local in_execute_phase = false
        if menu.use_execute and menu.use_execute.get_state and menu.use_execute:get_state() and spells.execute and spells.execute:is_learned() then
            local ok_hp, hp_pct = pcall(function() return target:get_health_percentage() end)
            hp_pct = ok_hp and hp_pct or 100
            local threshold = (menu.execute_hp_pct and menu.execute_hp_pct.get and menu.execute_hp_pct:get()) or 20
            if (hp_pct or 100) <= threshold then
                in_execute_phase = true
            end
        end
        if not in_execute_phase then
            queued_dump = try_rage_dump(player, target, menu) == true
        end
    end

    -- PvP logic integration
    if handle_pvp_logic(player, target, menu, now_ms) then
        return true
    end

    if try_defensives(player, target, menu, enemy_count) then
        return true
    end

    if not emergency_defensive_hold then
        if menu.auto_berserker_stance_fury and menu.auto_berserker_stance_fury.get_state
            and menu.auto_berserker_stance_fury:get_state() == true
            and spells.bloodthirst
            and spells.bloodthirst:is_learned() then
            if spells.berserker_stance:is_learned() and not in_berserker_stance(player) then
                if try_set_stance(player, spells.berserker_stance) then
                    return true
                end
            end
        elseif menu.auto_defensive_stance_prot_dps and menu.auto_defensive_stance_prot_dps.get_state
            and menu.auto_defensive_stance_prot_dps:get_state() == true
            and spells.shield_slam
            and spells.shield_slam:is_learned() then
            if spells.defensive_stance:is_learned() and not in_defensive_stance(player) then
                if try_set_stance(player, spells.defensive_stance) then
                    return true
                end
            end
        elseif menu.auto_battle_stance and menu.auto_battle_stance.get_state and menu.auto_battle_stance:get_state() == true then
            if spells.battle_stance:is_learned() and not in_battle_stance(player) then
                if try_set_stance(player, spells.battle_stance) then
                    return true
                end
            end
        end
    end

    if try_keep_battle_shout(player, menu) then
        return true
    end

    -- Rage tool
    if menu.use_bloodrage and menu.use_bloodrage:get_state() and spells.bloodrage:is_learned() then
        local min_rage = (menu.bloodrage_rage_below and menu.bloodrage_rage_below:get()) or 10
        local min_hp = (menu.bloodrage_min_hp_pct and menu.bloodrage_min_hp_pct:get()) or 65
        if rage(player) <= min_rage and (player:get_health_percentage() or 100) >= min_hp then
            if spells.bloodrage:is_castable({ skip_facing = true }) and spells.bloodrage:cast(player) then
                return true
            end
        end
    end

    -- Rampage maintenance (Fury buff): cast only when missing or about to expire.
    -- NOTE: Some servers expose Rampage only via the "aura" cache (not the "buff" cache),
    -- so we MUST check auras (and fallback-scan raw aura tables) to prevent spam.
    if menu.use_rampage and menu.use_rampage.get_state and menu.use_rampage:get_state()
        and spells.rampage and spells.rampage:is_learned() then
        local RAMPAGE_BUFF_ID = spells.RAMPAGE_BUFF_ID or 30033
        local refresh_before_expire_ms = 7000

        ---@param ids number[]|number
        ---@param spell_name_lower string|nil
        ---@return boolean active
        ---@return number remaining_ms
        ---@return number stacks
        local function aura_state(ids, spell_name_lower)
            local ok_up, up = pcall(function() return player:has_aura(ids) end)
            local ok_rem, rem = pcall(function() return player:aura_remains_ms(ids) end)
            local ok_st, st = pcall(function() return player:get_aura_stacks(ids) end)

            local active = ok_up and up == true
            local remaining_ms = (ok_rem and type(rem) == "number") and rem or 0
            local stacks = (ok_st and type(st) == "number") and st or 0

            if active or remaining_ms > 0 then
                return true, remaining_ms, stacks
            end

            -- Fallback: raw aura scan (covers builds where has_aura/aura_remains_ms are unreliable)
            if player.get_auras then
                local ok_raw, auras = pcall(function() return player:get_auras() end)
                if ok_raw and type(auras) == "table" then
                    local id_set = {}
                    if type(ids) == "table" then
                        for _, id in ipairs(ids) do id_set[id] = true end
                    else
                        id_set[ids] = true
                    end

                    for _, aura in ipairs(auras) do
                        local matches_id = aura and aura.buff_id and id_set[aura.buff_id] == true
                        local matches_name = false
                        if not matches_id and spell_name_lower and aura and aura.buff_name then
                            local n = aura.buff_name
                            if type(n) == "string" and string.lower(n) == spell_name_lower then
                                matches_name = true
                            end
                        end
                        if matches_id or matches_name then
                            local raw_remaining_ms = 0
                            if aura.expire_time and aura.duration then
                                local game_time = 0
                                pcall(function() game_time = core.game_time() or 0 end)
                                if game_time > 0 and aura.expire_time > game_time then
                                    raw_remaining_ms = (aura.expire_time - game_time) * 1000
                                end
                            end
                            local raw_stacks = (type(aura.count) == "number" and aura.count > 0) and aura.count or 1
                            return true, raw_remaining_ms, raw_stacks
                        end
                    end
                end
            end

            -- Last fallback: raw buff scan (some builds classify it as buff only)
            if player.get_buffs then
                local ok_raw, buffs = pcall(function() return player:get_buffs() end)
                if ok_raw and type(buffs) == "table" then
                    local id_set = {}
                    if type(ids) == "table" then
                        for _, id in ipairs(ids) do id_set[id] = true end
                    else
                        id_set[ids] = true
                    end
                    for _, buff in ipairs(buffs) do
                        local matches_id = buff and buff.buff_id and id_set[buff.buff_id] == true
                        local matches_name = false
                        if not matches_id and spell_name_lower and buff and buff.buff_name then
                            local n = buff.buff_name
                            if type(n) == "string" and string.lower(n) == spell_name_lower then
                                matches_name = true
                            end
                        end
                        if matches_id or matches_name then
                            local raw_remaining_ms = 0
                            if buff.expire_time and buff.duration then
                                local game_time = 0
                                pcall(function() game_time = core.game_time() or 0 end)
                                if game_time > 0 and buff.expire_time > game_time then
                                    raw_remaining_ms = (buff.expire_time - game_time) * 1000
                                end
                            end
                            local raw_stacks = (type(buff.count) == "number" and buff.count > 0) and buff.count or 1
                            return true, raw_remaining_ms, raw_stacks
                        end
                    end
                end
            end

            return false, 0, 0
        end

        local spell_id = spells.rampage:id()
        local aura_ids = { RAMPAGE_BUFF_ID }
        if spell_id and spell_id > 0 and spell_id ~= RAMPAGE_BUFF_ID then
            table.insert(aura_ids, spell_id)
        end

        local spell_name_lower = nil
        if core.spell_book and core.spell_book.get_spell_name and spell_id and spell_id > 0 then
            local ok_n, n = pcall(core.spell_book.get_spell_name, spell_id)
            if ok_n and type(n) == "string" and n ~= "" then
                spell_name_lower = string.lower(n)
            end
        end

        local rampage_up, rampage_remaining_ms = aura_state(aura_ids, spell_name_lower)
        if rampage_up and (not rampage_remaining_ms or rampage_remaining_ms <= 0) then
            -- Prefer "do not refresh" over spamming when we can't read remaining time.
            rampage_remaining_ms = 999999
        end

        debug_log_throttled(menu, "rampage.state", 2000,
            string.format("[Warrior][Debug][Rampage] up=%s rem_ms=%d rage=%d spell_id=%s aura_ids=%s name=%s",
                tostring(rampage_up),
                tonumber(rampage_remaining_ms or 0) or 0,
                rage(player),
                tostring(spell_id),
                type(aura_ids) == "table" and table.concat(aura_ids, ",") or tostring(aura_ids),
                tostring(spell_name_lower)))

        if (not rampage_up or rampage_remaining_ms < refresh_before_expire_ms)
            and rage(player) >= 20
            and (now_ms - last_rampage_request_ms) >= RAMPAGE_THROTTLE_MS then
            last_rampage_request_ms = now_ms
            if spells.rampage:is_castable({ skip_facing = true }) and spells.rampage:cast(player) then
                return true
            end
        end
    end

    -- Execute (Fury/Prot only here; Arms handles Execute inside its own priority block)
    if not is_arms_spec() then
        if menu.use_execute and menu.use_execute:get_state() and spells.execute:is_learned() then
            local hp_pct = target:get_health_percentage() or 100
            local threshold = (menu.execute_hp_pct and menu.execute_hp_pct:get()) or 20
            if hp_pct <= threshold then
                if can_cast_spell_to_unit(spells.execute, player, target) then
                    if spells.execute:cast(target) then
                        return true
                    end
                end
            end
        end
    end

    -- Offensive cooldowns (gated by cooldown toggle + menu)
    if (now_ms - last_offensive_cooldown_check_ms) >= OFFENSIVE_COOLDOWN_THROTTLE_MS then
        last_offensive_cooldown_check_ms = now_ms

        if should_use_cooldowns(player, target, menu) then
            if menu.use_death_wish and menu.use_death_wish.get_state and menu.use_death_wish:get_state() == true then
                if spells.death_wish and spells.death_wish:is_learned() then
                    if spells.death_wish:is_castable({ skip_facing = true }) and spells.death_wish:cast(player) then
                        return true
                    end
                end
            end

            if menu.use_recklessness and menu.use_recklessness.get_state and menu.use_recklessness:get_state() == true then
                if spells.recklessness and spells.recklessness:is_learned() then
                    if spells.recklessness:is_castable({ skip_facing = true }) and spells.recklessness:cast(player) then
                        return true
                    end
                end
            end
        end

        if try_use_racials(player, target, menu) then
            return true
        end
    end

    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true
    local aoe_min = (menu.aoe_min_enemies and menu.aoe_min_enemies.get and menu.aoe_min_enemies:get()) or 2
    local should_aoe = aoe_enabled and enemy_count >= aoe_min

    -- Sweeping Strikes cleave (talent; learned-check is sufficient)
    if should_aoe and menu.use_sweeping_strikes and menu.use_sweeping_strikes:get_state() and spells.sweeping_strikes:is_learned() then
        local sweep_id = spells.sweeping_strikes:id()
        local ok_down, down = pcall(function() return player:buff_down(sweep_id) end)
        down = (ok_down and down == true) or (not ok_down)
        if down == true then
            -- TBC: On some servers, Sweeping Strikes is usable in Battle OR Berserker Stance.
            if not (in_battle_stance(player) or in_berserker_stance(player)) then
                local allow_dance = menu.allow_stance_dance_for_sweeping_strikes
                    and menu.allow_stance_dance_for_sweeping_strikes.get_state
                    and menu.allow_stance_dance_for_sweeping_strikes:get_state() == true

                if allow_dance and spells.battle_stance:is_learned() and planned_stance_return_spell == nil and rage(player) >= SWEEPING_STRIKES_MIN_RAGE then
                    local max_waste = (menu.interrupt_stance_dance_max_rage_waste and menu.interrupt_stance_dance_max_rage_waste.get
                        and menu.interrupt_stance_dance_max_rage_waste:get()) or 0
                    max_waste = clamp(max_waste, 0, 100)

                    if allow_stance_dance_with_rage(player, menu, max_waste, SWEEPING_STRIKES_MIN_RAGE) then
                        local current = current_stance_spell(player)
                        if current and current ~= spells.battle_stance and current:is_learned() then
                            planned_stance_return_spell = current
                            planned_stance_return_until_ms = now_ms + 2500
                        else
                            planned_stance_return_spell = nil
                            planned_stance_return_until_ms = 0
                        end

                        if try_set_stance(player, spells.battle_stance) == true then
                            return true
                        end

                        planned_stance_return_spell = nil
                        planned_stance_return_until_ms = 0
                    end
                end

                debug_log_castability_throttled(
                    menu,
                    "dps.sweeping.block.stance",
                    debug_castability_interval_ms(menu),
                    string.format(
                        "[Warrior][Debug][Sweeping Strikes] blocked: not in Battle/Berserker Stance (rage=%d enemies=%d)",
                        tonumber(rage(player)) or 0,
                        tonumber(enemy_count) or 0
                    )
                )
            elseif can_cast_spell_to_unit(spells.sweeping_strikes, player, player, { skip_facing = true, skip_range = true }) then
                if spells.sweeping_strikes:cast(player) then
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
            else
                debug_spell_castability(menu, spells.sweeping_strikes, player, player, "Sweeping Strikes", { skip_facing = true, skip_range = true })
            end
        end
    end

    -- AoE Whirlwind
    if should_aoe and menu.use_whirlwind and menu.use_whirlwind:get_state() and spells.whirlwind:is_learned() then
        if try_whirlwind_with_optional_stance_dance(player, target, menu, now_ms) then
            return true
        end
    end

    -- Unified core buttons (only cast what is learned/castable)
    if menu.use_overpower and menu.use_overpower:get_state() and spells.overpower:is_learned() then
        if can_cast_spell_to_unit(spells.overpower, player, target) then
            if spells.overpower:cast(target) then
                return true
            end
        end
    end

    -- ======= ARMS SPEC PRIORITY =======
    if is_arms_spec() then
        -- Arms 1: Mortal Strike (highest priority)
        if menu.use_mortal_strike and menu.use_mortal_strike:get_state() and spells.mortal_strike:is_learned() then
            if can_cast_spell_to_unit(spells.mortal_strike, player, target) then
                if spells.mortal_strike:cast(target) then
                    return true
                end
            end
        end

        -- Arms 2: Execute (during execute phase; spam when MS on CD)
        if menu.use_execute and menu.use_execute:get_state() and spells.execute:is_learned() then
            local hp_pct = target:get_health_percentage() or 100
            local threshold = (menu.execute_hp_pct and menu.execute_hp_pct:get()) or 20
            if hp_pct <= threshold then
                if can_cast_spell_to_unit(spells.execute, player, target) then
                    if spells.execute:cast(target) then
                        return true
                    end
                end
            end
        end

        -- Arms AoE: Cleave (between Execute and WW in AoE)
        if should_aoe and menu.use_cleave and menu.use_cleave:get_state() and spells.cleave:is_learned() then
            if can_cast_spell_to_unit(spells.cleave, player, target) then
                if spells.cleave:cast(target) then
                    return true
                end
            end
        end

        -- Arms 3: Whirlwind (ST + AoE filler, no BT gate)
        if menu.use_whirlwind and menu.use_whirlwind:get_state() and spells.whirlwind:is_learned() then
            if try_whirlwind_with_optional_stance_dance(player, target, menu, now_ms) then
                return true
            end
        end

        -- Arms 4: Slam (post-swing window only; AoE: only with spare rage)
        if should_aoe then
            local aoe_slam_min = math.max((menu.slam_min_rage and menu.slam_min_rage.get and menu.slam_min_rage:get() or 25), 40)
            if rage(player) >= aoe_slam_min then
                if try_arms_slam_weave(player, target, menu) then
                    return true
                end
            end
        else
            if try_arms_slam_weave(player, target, menu) then
                return true
            end
        end

    -- ======= FURY / PROT PRIORITY (unchanged) =======
    else
        if menu.use_bloodthirst and menu.use_bloodthirst.get_state and menu.use_bloodthirst:get_state() and spells.bloodthirst and spells.bloodthirst:is_learned() then
            if can_cast_spell_to_unit(spells.bloodthirst, player, target) then
                if spells.bloodthirst:cast(target) then
                    return true
                end
            end
        end

        if menu.use_mortal_strike and menu.use_mortal_strike:get_state() and spells.mortal_strike:is_learned() then
            if can_cast_spell_to_unit(spells.mortal_strike, player, target) then
                if spells.mortal_strike:cast(target) then
                    return true
                end
            end
        end

        if menu.tank_use_shield_slam and menu.tank_use_shield_slam:get_state() and spells.shield_slam:is_learned() then
            if try_shield_ability_with_swap(player, target, menu, spells.shield_slam, "Shield Slam") then
                return true
            end
        end

        if menu.use_devastate and menu.use_devastate.get_state and menu.use_devastate:get_state() then
            if try_cast_devastate(player, target, menu) then
                return true
            end
        end

        -- Fury single-target Whirlwind (only if Bloodthirst is learned)
        if not should_aoe
            and menu.use_whirlwind
            and menu.use_whirlwind:get_state()
            and spells.whirlwind:is_learned()
            and spells.bloodthirst
            and spells.bloodthirst:is_learned() then
            if try_whirlwind_with_optional_stance_dance(player, target, menu, now_ms) then
                return true
            end
        end

        if not should_aoe then
            if try_arms_slam_weave(player, target, menu) then
                return true
            end
        end
    end

    -- Content heuristics
    if content ~= "raid" then
        if menu.use_rend and menu.use_rend:get_state() and spells.rend:is_learned() then
            if target:debuff_down(spells.rend:id()) then
                local ttd = target:time_to_die() or 0
                local min_ttd = menu.rend_min_ttd and menu.rend_min_ttd.get and menu.rend_min_ttd:get() or 6
                if ttd <= 0 or ttd >= min_ttd then
                    if can_cast_spell_to_unit(spells.rend, player, target) then
                        if spells.rend:cast(target) then
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Maintain Demoralizing Shout in non-tank DPS mode when explicitly enabled.
    -- TBC Fury guides generally recommend keeping this up when assigned.
    if menu.use_demoralizing_shout and menu.use_demoralizing_shout:get_state()
        and spells.demoralizing_shout and spells.demoralizing_shout:is_learned()
        and within_melee_range(player, target) then
        if target:debuff_down(spells.demoralizing_shout:id()) then
            if can_cast_spell_to_unit(spells.demoralizing_shout, player, target) then
                if spells.demoralizing_shout:cast(target) then
                    return true
                end
            end
        end
    end

    return queued_dump
end

---@param player game_object
---@param target game_object
---@param menu table
---@param enemy_count number
---@return boolean
local function try_tank_next_melee(player, target, menu, enemy_count)
    if not player or not target or not menu then
        return false
    end

    if not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_tank_next_melee_request_ms) < TANK_NEXT_MELEE_THROTTLE_MS then
        return false
    end

    local threshold = (menu.tank_cleave_rage_threshold
        and menu.tank_cleave_rage_threshold.get
        and menu.tank_cleave_rage_threshold:get()) or 30
    threshold = clamp(threshold, 0, 100)

    local current_rage = rage(player)
    if current_rage < threshold then
        return false
    end

    -- Preserve GCD priorities when a high-value tank button is immediately available.
    if menu.tank_use_shield_slam and menu.tank_use_shield_slam.get_state and menu.tank_use_shield_slam:get_state() == true
        and spells.shield_slam and spells.shield_slam:is_learned()
        and can_cast_spell_to_unit(spells.shield_slam, player, target) then
        debug_log_throttled(
            menu,
            "tank.next_melee.skip_for_shield_slam",
            debug_castability_interval_ms(menu),
            string.format(
                "[Warrior][Debug][Tank][NextMelee] skip HS/Cleave queue: preserving Shield Slam (rage=%d target=%s)",
                tonumber(current_rage) or 0,
                safe_unit_name(target)
            )
        )
        return false
    end

    if menu.tank_use_revenge and menu.tank_use_revenge.get_state and menu.tank_use_revenge:get_state() == true
        and spells.revenge and spells.revenge:is_learned()
        and can_cast_spell_to_unit(spells.revenge, player, target) then
        debug_log_throttled(
            menu,
            "tank.next_melee.skip_for_revenge",
            debug_castability_interval_ms(menu),
            string.format(
                "[Warrior][Debug][Tank][NextMelee] skip HS/Cleave queue: preserving Revenge (rage=%d target=%s)",
                tonumber(current_rage) or 0,
                safe_unit_name(target)
            )
        )
        return false
    end

    -- Tank next-melee spenders are rage dumps (off the GCD priority): Cleave for AoE, otherwise Heroic Strike.
    local aoe_enabled = menu.enable_aoe and menu.enable_aoe.get_state and menu.enable_aoe:get_state() == true

    if aoe_enabled and enemy_count >= 2 then
        if menu.use_cleave and menu.use_cleave:get_state() and spells.cleave and spells.cleave:is_learned() then
            if can_cast_spell_to_unit(spells.cleave, player, target) then
                last_tank_next_melee_request_ms = now_ms
                local ok = spells.cleave:cast(target) == true
                if ok then
                    debug_log_throttled(
                        menu,
                        "tank.cast.cleave",
                        debug_action_interval_ms(menu),
                        string.format(
                            "[Warrior][Debug][Cast] Cleave (next melee) -> %s (enemies=%d rage=%d)",
                            safe_unit_name(target),
                            tonumber(enemy_count) or 0,
                            tonumber(current_rage) or 0
                        )
                    )
                end
                return ok
            end
        end
    end

    if menu.use_heroic_strike and menu.use_heroic_strike:get_state() and spells.heroic_strike and spells.heroic_strike:is_learned() then
        if can_cast_spell_to_unit(spells.heroic_strike, player, target) then
            last_tank_next_melee_request_ms = now_ms
            local ok = spells.heroic_strike:cast(target) == true
            if ok then
                debug_log_throttled(
                    menu,
                    "tank.cast.hs",
                    debug_action_interval_ms(menu),
                    string.format(
                        "[Warrior][Debug][Cast] Heroic Strike (next melee) -> %s (rage=%d)",
                        safe_unit_name(target),
                        tonumber(current_rage) or 0
                    )
                )
            end
            return ok
        end
    end

    return false
end

---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
local function try_tank_rotation(player, target, menu)
    if not player or not target or not menu then
        return false
    end

    local enemy_count = count_enemies_around_player(player, 8)
    debug_log_throttled(
        menu,
        "tank.status",
        math.max(debug_action_interval_ms(menu), 500),
        string.format(
            "[Warrior][Debug][Tank] target=%s enemies=%d rage=%d hp=%.0f%% tank_mode=true",
            safe_unit_name(target),
            tonumber(enemy_count) or 0,
            tonumber(rage(player)) or 0,
            tonumber(player:get_health_percentage() or 100) or 100
        )
    )

    debug_log_throttled(
        menu,
        "tank.toggles",
        math.max(debug_castability_interval_ms(menu), 1200),
        string.format(
            "[Warrior][Debug][Tank][Toggles] dev=%s sunder=%s tc=%s tc_dance=%s tc_min_rage=%d tc_refresh=%ds",
            tostring(menu.tank_use_devastate and menu.tank_use_devastate.get_state and menu.tank_use_devastate:get_state() == true),
            tostring(menu.tank_use_sunder and menu.tank_use_sunder.get_state and menu.tank_use_sunder:get_state() == true),
            tostring(menu.tank_use_thunder_clap and menu.tank_use_thunder_clap.get_state and menu.tank_use_thunder_clap:get_state() == true),
            tostring(menu.tank_allow_stance_dance_for_thunder_clap and menu.tank_allow_stance_dance_for_thunder_clap.get_state and menu.tank_allow_stance_dance_for_thunder_clap:get_state() == true),
            tonumber((menu.tank_thunder_clap_min_rage and menu.tank_thunder_clap_min_rage.get and menu.tank_thunder_clap_min_rage:get()) or TANK_THUNDER_CLAP_MIN_RAGE) or 0,
            tonumber((menu.tank_thunder_clap_refresh_sec and menu.tank_thunder_clap_refresh_sec.get and menu.tank_thunder_clap_refresh_sec:get()) or 3) or 0
        )
    )

    -- Queue next-melee ability (off-GCD: Cleave/HS don't use the GCD, they modify the next auto-attack)
    -- This runs independently of the GCD rotation below; we intentionally do NOT return true here.
    -- Queue HS/Cleave as a rage dump before GCD checks; this does not replace Shield Slam/Revenge/Devastate priority.
    try_tank_next_melee(player, target, menu, enemy_count)

    -- ========================================
    -- EMERGENCY / CC BREAK (Highest Priority)
    -- ========================================

    -- Berserker Rage Fear Break (break CC immediately)
    if try_berserker_rage_fear_break(player, menu) then
        return true
    end

    -- Spell Reflection (when target is casting at us)
    if try_tank_spell_reflection(player, target, menu) then
        return true
    end

    if try_defensives(player, target, menu, enemy_count) then
        return true
    end

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

    if menu.tank_auto_taunt and menu.tank_auto_taunt:get_state() and spells.taunt:is_learned() then
        local ok, enemy_target = pcall(function()
            return target:get_target()
        end)
        if ok and enemy_target and (not __object_safety.same(enemy_target,player)) then
            if can_cast_spell_to_unit(spells.taunt, player, target) then
                if spells.taunt:cast(target) then
                    debug_log_throttled(
                        menu,
                        "tank.cast.taunt",
                        debug_action_interval_ms(menu),
                        string.format("[Warrior][Debug][Cast] Taunt -> %s", safe_unit_name(target))
                    )
                    return true
                end
            end
        end
    end

    -- Challenging Shout (AoE Taunt Emergency - 10 min CD)
    if try_tank_challenging_shout(player, target, menu, enemy_count) then
        return true
    end

    if try_tank_intervene(player, target, menu) then
        return true
    end

    -- Mocking Blow als Backup wenn Taunt auf CD (erfordert Stance-Dance zu Battle Stance)
    if try_tank_mocking_blow(player, target, menu) then
        return true
    end

    -- ========================================
    -- CORE TANK ROTATION (TBC Prot)
    -- Single-target priority: Shield Slam > Revenge > Devastate
    -- Thunder Clap is maintained when enabled/needed, but Sunder is not part of normal Prot priority once Devastate is learned.
    -- Multi-target (2+): Thunder Clap for AoE threat/debuff upkeep, then Shield Slam > Revenge > Devastate
    -- Heroic Strike/Cleave are handled as next-melee rage dumps in try_tank_next_melee().
    -- Per TBC Prot Warrior guides (Wowhead, Icy Veins, Warcraft Tavern)
    -- ========================================

    -- Multi-target: TC is #1 priority for AoE threat
    -- TC on cooldown provides more total threat than single-target abilities with 2+ enemies
    if enemy_count >= 2 then
        if try_tank_thunder_clap(player, target, menu) then
            return true
        end
    end

    -- 1. Shield Slam (highest threat per rage - top priority)
    if try_tank_shield_slam(player, target, menu) then
        return true
    end

    -- 2. Revenge (high threat when proc available)
    if try_tank_tabbed_revenge(player, target, menu) then
        return true
    end

    -- Concussion Blow (optional stun/interrupt; only if enabled)
    if try_tank_concussion_blow(player, target, menu) then
        return true
    end

    -- 3. Thunder Clap (maintain attack speed debuff - higher priority than Devastate)
    -- The function has internal guards: refresh check, min_enemies, min_rage, throttle.
    -- Returns false quickly when TC doesn't need refreshing.
    if try_tank_thunder_clap(player, target, menu) then
        return true
    end

    -- 4. Devastate (core Prot filler - spam between Shield Slam and Revenge cooldowns)
    if not (menu.tank_use_devastate and menu.tank_use_devastate.get_state and menu.tank_use_devastate:get_state() == true) then
        debug_log_throttled(
            menu,
            "tank.devastate.guard.off",
            debug_castability_interval_ms(menu),
            "[Warrior][Debug][Tank][Devastate] skipped: tank_use_devastate is OFF"
        )
    elseif not (spells.devastate and spells.devastate:is_learned() == true) then
        debug_log_throttled(
            menu,
            "tank.devastate.guard.notlearned",
            debug_castability_interval_ms(menu),
            "[Warrior][Debug][Tank][Devastate] skipped: Devastate not learned"
        )
    else
        if try_cast_devastate(player, target, menu) then
            return true
        end
    end

    -- ========================================
    -- UTILITY / CC
    -- ========================================

    -- Disarm (optional utility; mostly PvP / specific mob mechanics)
    if try_tank_disarm(player, target, menu) then
        return true
    end

    -- ========================================
    -- DEBUFF MAINTENANCE
    -- ========================================

    -- Demoralizing Shout (maintain damage reduction debuff)
    if menu.tank_use_demoralizing_shout and menu.tank_use_demoralizing_shout:get_state() then
        if not spells.demoralizing_shout:is_learned() then
            debug_log_castability_throttled(menu, "tank.demo_shout.not_learned",
                debug_castability_interval_ms(menu),
                string.format("[Warrior][Debug][Tank][DemoShout] NOT LEARNED: resolved_id=%d",
                    (spells.demoralizing_shout and spells.demoralizing_shout.id and spells.demoralizing_shout:id()) or 0))
        elseif within_melee_range(player, target) then
            local demo_debuff_down = target:debuff_down(spells.demoralizing_shout:id())
            debug_log_castability_throttled(menu, "tank.demo_shout.debuff_check",
                debug_castability_interval_ms(menu),
                string.format("[Warrior][Debug][Tank][DemoShout] debuff_down=%s resolved_id=%d target=%s",
                    tostring(demo_debuff_down),
                    (spells.demoralizing_shout:id()) or 0,
                    safe_unit_name(target)))
            if demo_debuff_down then
                if can_cast_spell_to_unit(spells.demoralizing_shout, player, target) then
                    if spells.demoralizing_shout:cast(target) then
                        debug_log_throttled(
                            menu,
                            "tank.cast.demo",
                            debug_action_interval_ms(menu),
                            string.format("[Warrior][Debug][Cast] Demoralizing Shout -> %s (id=%d)", safe_unit_name(target), (spells.demoralizing_shout:id()) or 0)
                        )
                        return true
                    end
                end
            end
        end
    end

    -- ========================================
    -- UTILITY / DEFENSE
    -- ========================================

    -- 6. Shield Block (when buff is down and we have spare rage)
    if menu.tank_use_shield_block and menu.tank_use_shield_block:get_state() and spells.shield_block:is_learned() then
        local min_rage = (menu.tank_shield_block_min_rage and menu.tank_shield_block_min_rage.get and menu.tank_shield_block_min_rage:get()) or 20
        min_rage = clamp(min_rage, 0, 100)
        if rage(player) >= min_rage then
            if not has_aura_id(player, spells.shield_block:id()) then
                if try_shield_ability_with_swap(player, player, menu, spells.shield_block, "Shield Block") then
                    return true
                end
            end
        end
    end

    -- 7. Sunder Armor / Tab-Sunder fallback (ONLY if Devastate is NOT learned - low-level tanks)
    -- This is not part of the normal TBC Prot endgame priority.
    -- When Devastate is learned, it replaces Sunder in the rotation (Devastate applies Sunder effect).
    if menu.tank_use_sunder and menu.tank_use_sunder:get_state() and spells.sunder_armor:is_learned() then
        local devastate_learned = spells.devastate and spells.devastate:is_learned() == true

        if not devastate_learned then
            -- Tab-Sunder for AoE threat (only without Devastate)
            local tab_target = find_best_tab_sunder_target(player, target, menu)
            if tab_target and tab_target:is_valid_enemy() and tab_target:is_alive() then
                if can_cast_spell_to_unit(spells.sunder_armor, player, tab_target) then
                    if spells.sunder_armor:cast(tab_target) then
                        return true
                    end
                end
            end

            -- Main target Sunder
            local desired = (menu.tank_sunder_stacks and menu.tank_sunder_stacks.get and menu.tank_sunder_stacks:get()) or 5
            desired = clamp(desired, 0, 5)
            if desired > 0 then
                local stacks = get_debuff_stacks(target, spells.sunder_armor:id())
                if stacks < desired then
                    if can_cast_spell_to_unit(spells.sunder_armor, player, target) then
                        if spells.sunder_armor:cast(target) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- Entry point
-- ============================================================================

---@param local_player game_object
---@param menu table
---@param is_tank_mode boolean
---@param allow_ooc_charge boolean|nil
---@return boolean
function rotation_logic:execute(local_player, menu, is_tank_mode, allow_ooc_charge)
    if not local_player or not menu then
        return false
    end

    if spells and spells.refresh then
        spells:refresh()
    end

    local player = local_player

    -- V3: Update shield swap mode from menu (before any swap operations)
    if menu.shield_swap_mode then
        local shield_swap_mode = menu.shield_swap_mode:get() or 1
        shield_swap_helper:set_mode(shield_swap_mode == 1 and "auto" or "manual")

        if menu.shield_swap_verbose_logging and menu.shield_swap_verbose_logging.get_state and shield_swap_helper.set_verbose_logging then
            shield_swap_helper:set_verbose_logging(menu.shield_swap_verbose_logging:get_state() == true)
        end

        if menu.shield_swap_require_onehand and menu.shield_swap_require_onehand.get_state and shield_swap_helper.set_require_onehand then
            shield_swap_helper:set_require_onehand(menu.shield_swap_require_onehand:get_state() == true)
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

    local target = izi.target()
    if not target or not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    -- Do not start combat actions just because a target is selected.
    -- Rotation only runs once the player is actually in combat (Hardcore-safe).
    do
        local ok_combat, combat = pcall(function()
            return player:is_in_combat()
        end)
        local in_combat = ok_combat and combat == true
        if not in_combat and unit_helper and unit_helper.is_in_combat then
            local ok_fallback, fb = pcall(function()
                return unit_helper:is_in_combat(player)
            end)
            in_combat = ok_fallback and fb == true
        end
        if not in_combat then
            if allow_ooc_charge == true and spells.charge and spells.charge:is_learned() then
                if menu.auto_battle_stance and menu.auto_battle_stance.get_state and menu.auto_battle_stance:get_state() == true then
                    if not in_battle_stance(player) and spells.battle_stance and spells.battle_stance:is_learned() then
                        if try_set_stance(player, spells.battle_stance) then
                            return true
                        end
                    end
                end
                if can_cast_spell_to_unit(spells.charge, player, target) then
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

    if try_emergency_items(player, menu) then
        return true
    end

    if process_pending_stance_return(player) then
        return true
    end

    if is_tank_mode == true then
        return try_tank_rotation(player, target, menu)
    end

    local now_ms = core.game_time()
    local content = resolve_content_profile(menu)
    return try_dps_rotation(player, target, menu, content)
end

return rotation_logic
