local __object_safety=require("shared/object_safety")
local pvp = {}

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")

---@type enums
local enums = require("common/enums")

local spell_data = require("rotations/rogue/tbc/spell_data")

-- Arena mechanic modules
local pvp_reset_cycle = require("rotations/rogue/tbc/rotation/pvp_reset_cycle")
local pvp_trinket_tracker = require("rotations/rogue/tbc/rotation/pvp_trinket_tracker")
local pvp_gouge_restealth = require("rotations/rogue/tbc/rotation/pvp_gouge_restealth")

local last_focus_update_time = 0.0
local FOCUS_UPDATE_COOLDOWN = 1.0

local last_target_switch_time = 0.0
local TARGET_SWITCH_COOLDOWN = 0.35

local last_premeditation_time = 0.0
local PREMEDITATION_THROTTLE = 2.0

local last_vanish_queue_time = 0.0
local last_sprint_queue_time = 0.0
local last_shadowstep_gap_time = 0.0
local COOLDOWN_QUEUE_THROTTLE = 1.5

local last_face_target_time = 0.0
local FACE_TARGET_THROTTLE = 0.1

-- ============================================================================
-- PVP DEBUG LOGGING
-- ============================================================================
local pvp_log_last_times = {}
local pvp_log_menu_ref = nil -- cached each frame in execute()

local pvp_log_file_name = nil
local pvp_log_file_ready = false

local function ensure_pvp_log_file()
    if pvp_log_file_ready then
        return true
    end

    local now = core.time()
    pvp_log_file_name = string.format("rogue_pvp_%d.txt", math.floor(now or 0))

    local ok_create = pcall(function()
        core.create_log_file(pvp_log_file_name)
    end)
    if not ok_create then
        return false
    end

    pcall(function()
        core.write_log_file(pvp_log_file_name, string.format("[PVP] Log start t=%d\n", math.floor(now or 0)))
    end)

    pvp_log_file_ready = true
    return true
end

local function pvp_log(key, interval, message)
    if not pvp_log_menu_ref or not pvp_log_menu_ref.pvp_debug_logging then
        return
    end
    if pvp_log_menu_ref.pvp_debug_logging:get_state() ~= true then
        return
    end
    local now = core.time()
    if interval > 0 then
        local last = pvp_log_last_times[key] or 0
        if (now - last) < interval then return end
        pvp_log_last_times[key] = now
    end
    if ensure_pvp_log_file() then
        pcall(function()
            core.write_log_file(pvp_log_file_name, string.format("[%d] %s\n", math.floor(now or 0), tostring(message)))
        end)
    end
    core.log(message)
end

---@param local_player game_object
---@param target game_object|nil
---@param spell_id number
---@return table
local function get_castability_breakdown(local_player, target, spell_id)
    local out = {
        spell_id = spell_id,
        learned = false,
        on_cd = false,
        los = false,
        in_range = false,
        in_angle = false,
        can_afford = false,
    }

    local ok_learned, learned = pcall(function()
        return spell_helper:has_spell_equipped(spell_id) == true
    end)
    out.learned = ok_learned and learned or false

    local ok_cd, on_cd = pcall(function()
        return spell_helper:is_spell_on_cooldown(spell_id)
    end)
    out.on_cd = ok_cd and on_cd or false

    if local_player and target then
        local ok_los, los = pcall(function()
            return spell_helper:is_spell_in_line_of_sight(spell_id, local_player, target) == true
        end)
        out.los = ok_los and los or false

        local ok_p1, p1 = pcall(function() return local_player:get_position() end)
        local ok_p2, p2 = pcall(function() return target:get_position() end)

        local ok_range, in_range = pcall(function()
            if not ok_p1 or not ok_p2 or not p1 or not p2 then return false end
            return spell_helper:is_spell_in_range(spell_id, target, p1, p2) == true
        end)
        out.in_range = ok_range and in_range or false

        local ok_ang, in_ang = pcall(function()
            if not ok_p1 or not ok_p2 or not p1 or not p2 then return false end
            return spell_helper:is_spell_within_angle(spell_id, local_player, target, p1, p2) == true
        end)
        out.in_angle = ok_ang and in_ang or false
    end

    local ok_cost, costs = pcall(function()
        return spell_helper:get_spell_cost(spell_id)
    end)
    if ok_cost and costs then
        local ok_aff, aff = pcall(function()
            return spell_helper:can_afford_spell(local_player, spell_id, costs) == true
        end)
        out.can_afford = ok_aff and aff or false
    end

    return out
end

--- Safe name getter for logging
local function safe_name(unit)
    if not unit then return "nil" end
    local ok, name = pcall(function() return unit:get_name() end)
    return (ok and name) or "?"
end

---@param local_player game_object
---@param target game_object
local function maybe_face_target(local_player, target)
    if not local_player or not target then
        return
    end
    local now = core.time()
    if (now - last_face_target_time) < FACE_TARGET_THROTTLE then
        return
    end
    last_face_target_time = now
    local ok_pos, tpos = pcall(function() return target:get_position() end)
    if ok_pos and tpos then
        pcall(function() core.input.look_at(tpos) end)
    end
end

---@param helpers table|nil
---@param local_player game_object
---@param target game_object|nil
local function pvp_log_frame_state(helpers, local_player, target)
    local now = core.time()
    local ok_combat, in_combat = pcall(function() return local_player:affecting_combat() end)
    local ok_gcd, gcd = pcall(function() return local_player:gcd_remains() end)
    local ok_cast, casting = pcall(function() return local_player:is_channeling_or_casting() end)
    local ok_stealth, stealthed = pcall(function()
        return helpers and helpers.is_in_stealth and helpers:is_in_stealth(local_player)
    end)

    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    local hp = local_player:get_health_percentage() or 0
    local cp = helpers and helpers.get_combo_points and helpers:get_combo_points(local_player) or 0

    local dist = -1
    local thp = -1
    if target and target.is_valid and target:is_valid() then
        local ok_dist, d = pcall(function() return target:distance() end)
        if ok_dist and type(d) == "number" then dist = d end
        local ok_thp, v = pcall(function() return target:get_health_percentage() end)
        if ok_thp and type(v) == "number" then thp = v end
    end

    local queued_n = -1
    local ok_snap, snap = pcall(function() return spell_queue:get_queue_snapshot() end)
    if ok_snap and type(snap) == "table" then
        queued_n = #snap
    end

    local lastq = (helpers and helpers._last_spell_queued_time) or 0.0
    local lastq_key = (helpers and helpers._last_spell_queued_key) or "nil"
    local lastq_id = (helpers and helpers._last_spell_queued_id) or 0

    pvp_log(
        "diag.frame",
        0.35,
        string.format(
            "[PVP][FRAME] t=%.1f combat=%s stealth=%s gcd=%.2f casting=%s hp=%.0f%% e=%d cp=%d target=%s thp=%.0f%% dist=%.1f queued=%d lastq=%.1fs(%s/%d)",
            now,
            tostring(ok_combat and in_combat),
            tostring(ok_stealth and stealthed),
            (ok_gcd and type(gcd) == "number" and gcd) or -1,
            tostring(ok_cast and casting),
            hp,
            energy,
            cp,
            safe_name(target),
            thp,
            dist,
            queued_n,
            (now - lastq),
            tostring(lastq_key),
            tonumber(lastq_id) or 0
        )
    )
end

---@param local_player game_object
---@param target game_object
---@param label string
---@param ids number[]|nil
local function pvp_log_spell_family(local_player, target, label, ids)
    if not ids or #ids == 0 then
        return
    end

    local inspect_id = nil
    for i = #ids, 1, -1 do
        local id = ids[i]
        local ok_learned, learned = pcall(function() return spell_helper:has_spell_equipped(id) end)
        if ok_learned and learned == true then
            inspect_id = id
            break
        end
    end
    inspect_id = inspect_id or ids[#ids]
    local b = get_castability_breakdown(local_player, target, inspect_id)

    pvp_log(
        "diag.cast." .. tostring(label),
        0.75,
        string.format(
            "[PVP][CAST] %s id=%d learned=%s cd=%s los=%s range=%s angle=%s afford=%s",
            tostring(label),
            tonumber(b.spell_id) or 0,
            tostring(b.learned),
            tostring(b.on_cd),
            tostring(b.los),
            tostring(b.in_range),
            tostring(b.in_angle),
            tostring(b.can_afford)
        )
    )
end

local HEAL_SPELL_IDS = {
    -- Priest
    [2060] = true, [2061] = true, [2054] = true, [2055] = true, [6063] = true, [6064] = true, [596] = true,
    -- Paladin
    [635] = true, [639] = true, [647] = true, [1026] = true, [1042] = true, [3472] = true, [10328] = true,
    [19750] = true, [19939] = true, [19940] = true,
    -- Druid
    [5185] = true, [5186] = true, [5187] = true, [5188] = true, [5189] = true,
    [8936] = true, [8938] = true, [8939] = true, [8940] = true, [8941] = true,
    [33763] = true, -- Lifebloom
    -- Shaman
    [331] = true, [332] = true, [547] = true, [913] = true, [939] = true, [959] = true, [8004] = true, [8005] = true,
    [1064] = true -- Chain Heal
}

local HEALER_CLASSES = {
    [enums.class_id.PRIEST] = true,
    [enums.class_id.PALADIN] = true,
    [enums.class_id.DRUID] = true,
    [enums.class_id.SHAMAN] = true
}

-- Classes where Rupture (bleed) is especially valuable in PvP
local RUPTURE_PRIORITY_CLASSES = {
    [enums.class_id.WARRIOR] = true, -- Bleed ignores armor, avoids Second Wind stun heal
    [enums.class_id.ROGUE] = true,   -- Prevents restealth
    [enums.class_id.DRUID] = true    -- Prevents restealth (cat prowl)
}

-- Class-awareness adjustments for PvP decision-making
-- prefer_bleeds: use Rupture over Eviscerate
-- avoid_stun: avoid Kidney Shot (Second Wind heals on stun)
-- prevent_restealth: maintain bleeds to prevent stealth
-- track_immunity: be aware of immunity abilities (BoP, Divine Shield, Ice Block)
local CLASS_ADJUSTMENTS = {
    [enums.class_id.WARRIOR] = { prefer_bleeds = true, avoid_stun = true },
    [enums.class_id.ROGUE]   = { prevent_restealth = true },
    [enums.class_id.DRUID]   = { prevent_restealth = true },
    [enums.class_id.PALADIN] = { track_immunity = true },
    [enums.class_id.MAGE]    = { track_immunity = true },
}

--- Get class adjustments for the given target (returns empty table if unknown or disabled)
local function get_class_adjustments(target)
    local ok, class_id = pcall(function() return target:get_class() end)
    if ok and class_id and CLASS_ADJUSTMENTS[class_id] then
        return CLASS_ADJUSTMENTS[class_id]
    end
    return {}
end

-- Lightweight CC-chain state tracker
local cc_chain_state = {
    last_kidney_time = 0,
    last_kidney_target_guid = nil,
}

---@param target game_object
---@param debuff_ids number[]
---@return boolean
local function has_any_debuff(target, debuff_ids)
    if not target or not debuff_ids then
        return false
    end
    for _, id in ipairs(debuff_ids) do
        local ok, up = pcall(function()
            return target:debuff_up(id) == true
        end)
        if ok and up then
            return true
        end
    end
    return false
end

local function menu(helpers)
    return helpers and helpers._menu_elements or nil
end

---@param unit game_object
---@param local_player game_object
---@return boolean
local function is_valid_enemy_player(unit, local_player)
    if not unit or not local_player then
        return false
    end

    if not unit:is_valid() or unit:is_dead() then
        return false
    end

    if not pvp_helper:is_player(unit) then
        return false
    end

    if unit:is_friend_with(local_player) then
        return false
    end

    if not local_player:can_attack(unit) then
        return false
    end

    return true
end

local function is_enabled(helpers, local_player)
    if not helpers or not helpers.is_pvp_mode_active or not helpers:is_pvp_mode_active() then
        return false
    end

    local m = menu(helpers)
    if not m then
        return false
    end

    local require_scenario = m.pvp_require_pvp_scenario and m.pvp_require_pvp_scenario.get_state and m.pvp_require_pvp_scenario:get_state() == true
    if require_scenario and helpers.is_pvp_scenario and not helpers:is_pvp_scenario() then
        -- Open-world PvP fallback:
        -- Even if "Require PvP Scenario" is enabled, still run when we're actually
        -- engaged with an enemy player (stealthed opener or in-combat).
        if local_player and local_player.is_valid and local_player:is_valid() then
            local ok_target, t = pcall(function() return local_player:get_target() end)
            if ok_target and t and is_valid_enemy_player(t, local_player) then
                local ok_combat, in_combat = pcall(function() return local_player:affecting_combat() end)
                if (ok_combat and in_combat) or (helpers.is_in_stealth and helpers:is_in_stealth(local_player)) then
                    return true
                end
            end
        end
        return false
    end

    return true
end

---@param unit game_object
---@return boolean
local function has_casting_heal(unit)
    if not unit or not unit:is_valid() then
        return false
    end

    if not unit:is_casting_spell() then
        return false
    end

    local spell_id = unit:get_active_spell_id()
    if not spell_id then
        return false
    end

    return HEAL_SPELL_IDS[spell_id] == true
end

---@param unit game_object
---@param local_player game_object
---@return number
local function score_focus_candidate(unit, local_player)
    if not is_valid_enemy_player(unit, local_player) then
        return -1
    end

    local score = 0

    local ok_dist, dist = pcall(function()
        return unit:distance()
    end)
    if ok_dist and type(dist) == "number" then
        if dist <= 10 then
            score = score + 10
        elseif dist <= 30 then
            score = score + 5
        end
    end

    local ok_class, class_id = pcall(function()
        return unit:get_class()
    end)
    if ok_class and class_id and HEALER_CLASSES[class_id] then
        score = score + 30
    end

    if has_casting_heal(unit) then
        score = score + 100
    elseif unit:is_casting_spell() then
        score = score + 15
    end

    return score
end

---@param local_player game_object
---@param helpers table
---@param targets_list game_object[]|nil
local function maybe_auto_focus(local_player, helpers, targets_list)
    local m = menu(helpers)
    if not m or not m.pvp_auto_focus or not m.pvp_auto_focus.get_state then
        return
    end
    if m.pvp_auto_focus:get_state() ~= true then
        return
    end

    local now = core.time()
    if (now - last_focus_update_time) < FOCUS_UPDATE_COOLDOWN then
        return
    end

    local focus = nil
    local ok_focus, current_focus = pcall(function()
        return core.input.get_focus()
    end)
    if ok_focus then
        focus = current_focus
    end

    local override = m.pvp_focus_override and m.pvp_focus_override.get_state and m.pvp_focus_override:get_state() == true
    if not override and focus and is_valid_enemy_player(focus, local_player) then
        last_focus_update_time = now
        return
    end

    local best = nil
    local best_score = -1

    for _, unit in __object_safety.live_ipairs(targets_list or {}) do
        local score = score_focus_candidate(unit, local_player)
        if score > best_score then
            best_score = score
            best = unit
        end
    end

    if not best then
        local player_pos = local_player:get_position()
        if player_pos then
            local enemies = unit_helper:get_enemy_list_around(player_pos, 30.0, true, false, false, false) or {}
            for _, unit in __object_safety.live_ipairs(enemies) do
                local score = score_focus_candidate(unit, local_player)
                if score > best_score then
                    best_score = score
                    best = unit
                end
            end
        end
    end

    if best and best_score > 0 then
        pcall(function()
            core.input.set_focus(best)
        end)
    end

    last_focus_update_time = now
end

---@param helpers table
---@return number
local function dr_min_mult(helpers)
    local m = menu(helpers)
    if not m or not m.pvp_cc_min_dr or not m.pvp_cc_min_dr.get then
        return 0.5
    end
    local v = m.pvp_cc_min_dr:get()
    if v == 1 then
        return 1.0
    end
    if v == 2 then
        return 0.5
    end
    return 0.0
end

---@param target game_object
---@param type_flags number
---@param min_mult number
---@return boolean
local function dr_allows(target, type_flags, min_mult)
    if not target or not pvp_helper or not pvp_helper.get_unit_dr then
        return true
    end
    local now = core.time()
    local ok, mult = pcall(function()
        return pvp_helper:get_unit_dr(target, type_flags, now)
    end)
    if not ok or type(mult) ~= "number" then
        return true
    end
    return mult >= min_mult
end

local OPENER_THROTTLE = 0.35
local opener_last_attempt_time = {}

local PVP_BUILD_ID = "2026-02-11.verbose_diag_v6"

local keybind_last_down = {
    vanish = false,
    blind = false,
    prep = false
}

local KEYBIND_THROTTLE = 0.75
local last_keybind_action_time = {
    vanish = 0.0,
    blind = 0.0,
    prep = 0.0
}

---@param label string
---@param target game_object
---@return string
local function opener_throttle_key(label, target)
    local guid = nil
    if target and target.get_guid then
        local ok_guid, v = pcall(function()
            return target:get_guid()
        end)
        if ok_guid then
            guid = v
        end
    end
    if guid then
        return tostring(label) .. ":" .. tostring(guid)
    end
    return tostring(label)
end

---@param local_player game_object
---@param target game_object
---@param ids number[]
---@param label string
---@param priority number
---@param helpers table
---@param require_behind boolean
---@return boolean
local function try_cast_highest_rank_opener(local_player, target, ids, label, priority, helpers, require_behind)
    if not local_player or not target or not ids then
        return false
    end

    -- Safety: openers are PvP-only and should never fire on non-player objects (e.g., Battle Standards).
    if not is_valid_enemy_player(target, local_player) then
        pvp_log("opener.npc_reject", 2.0, "[PVP][OPENER] Rejected: target is not a valid enemy player")
        return false
    end

    -- Throttle: prevent queue-spam before the server confirms state changes (stealth break, GCD, etc.).
    local now = core.time()
    local key = opener_throttle_key(label, target)
    local last = opener_last_attempt_time[key] or 0.0
    if (now - last) < OPENER_THROTTLE then
        pvp_log("opener.throttle", 1.0, string.format("[PVP][STEALTH] Opener throttled: %s (%.2fs)", tostring(label), (now - last)))
        return false
    end
    opener_last_attempt_time[key] = now

    if require_behind and helpers and helpers.is_behind_target and not helpers:is_behind_target(local_player, target) then
        local ok_dist, dist = pcall(function() return target:distance() end)
        pvp_log("opener.behind", 1.0, string.format("[PVP][STEALTH] Opener behind-required but not behind: %s (dist=%.1f)", tostring(label), (ok_dist and dist) or -1))
        return false
    end

    -- In open world we often end up slightly off-facing; try to face before attempting openers.
    maybe_face_target(local_player, target)

    for i = #ids, 1, -1 do
        local spell_id = ids[i]
        local ok_castable, castable = pcall(function()
            return spell_helper:is_spell_castable(spell_id, local_player, target, false, false, false, false, false)
        end)
        if not ok_castable then
            pvp_log("opener.err.castable", 1.0, string.format("[PVP][STEALTH] Opener castable check errored: %s id=%d", tostring(label), spell_id))
            castable = false
        end
        if castable then
            -- NOTE: queue_spell_target() is VOID (returns nil). pcall success = spell accepted.
            local ok_queue = pcall(function()
                -- allow_movement=true: open-world targets move a lot; ensure queue doesn't reject while moving.
                spell_queue:queue_spell_target(spell_id, target, priority, label, true)
            end)
            if ok_queue then
                if helpers then
                    helpers._last_spell_queued_time = core.time()
                    helpers._last_spell_queued_key = tostring(label)
                    helpers._last_spell_queued_id = spell_id
                end
                return true
            end
            pvp_log("opener.err.queue", 1.0, string.format("[PVP][STEALTH] Opener queue failed: %s id=%d", tostring(label), spell_id))

            -- Fallback: attempt direct cast if queueing fails (rare engine edge-case).
            local ok_direct, direct = pcall(function()
                return core.input.cast_target_spell(spell_id, target)
            end)
            if ok_direct and direct ~= false then
                if helpers then
                    helpers._last_spell_queued_time = core.time()
                    helpers._last_spell_queued_key = tostring(label) .. ".direct"
                    helpers._last_spell_queued_id = spell_id
                end
                pvp_log("opener.direct", 0.5, string.format("[PVP][STEALTH] Opener direct-cast success: %s id=%d", tostring(label), spell_id))
                return true
            end
            pvp_log("opener.direct.fail", 1.0, string.format("[PVP][STEALTH] Opener direct-cast failed: %s id=%d", tostring(label), spell_id))
        end
    end

    do
        local behind_txt = "?"
        if require_behind and helpers and helpers.is_behind_target then
            local ok_b, b = pcall(function() return helpers:is_behind_target(local_player, target) end)
            behind_txt = tostring(ok_b and b or false)
        end

        local ok_dist, dist = pcall(function() return target:distance() end)
        local ok_gcd, gcd = pcall(function() return local_player:gcd_remains() end)
        local ok_cast, casting = pcall(function() return local_player:is_channeling_or_casting() end)

        -- Deep castability breakdown (best-effort): pick highest learned rank for inspection.
        local inspect_id = nil
        for i = #ids, 1, -1 do
            local id = ids[i]
            local ok_learned, learned = pcall(function() return spell_helper:has_spell_equipped(id) end)
            if ok_learned and learned == true then
                inspect_id = id
                break
            end
        end
        if not inspect_id then
            inspect_id = ids[#ids]
        end

        local ok_los, in_los = pcall(function() return spell_helper:is_spell_in_line_of_sight(inspect_id, local_player, target) end)
        local ok_p1, p1 = pcall(function() return local_player:get_position() end)
        local ok_p2, p2 = pcall(function() return target:get_position() end)
        local ok_range, in_range = pcall(function()
            if not ok_p1 or not ok_p2 or not p1 or not p2 then return false end
            return spell_helper:is_spell_in_range(inspect_id, target, p1, p2)
        end)
        local ok_ang, in_ang = pcall(function()
            if not ok_p1 or not ok_p2 or not p1 or not p2 then return false end
            return spell_helper:is_spell_within_angle(inspect_id, local_player, target, p1, p2)
        end)
        local ok_cd, on_cd = pcall(function() return spell_helper:is_spell_on_cooldown(inspect_id) end)

        pvp_log(
            "opener.no_castable",
            1.0,
            string.format(
                "[PVP][STEALTH] Opener not castable: %s id=%d (dist=%.1f gcd=%.2f casting=%s behind=%s los=%s range=%s angle=%s cd=%s)",
                tostring(label),
                tonumber(inspect_id) or 0,
                (ok_dist and type(dist) == "number" and dist) or -1,
                (ok_gcd and type(gcd) == "number" and gcd) or -1,
                tostring(ok_cast and casting),
                behind_txt,
                tostring(ok_los and in_los),
                tostring(ok_range and in_range),
                tostring(ok_ang and in_ang),
                tostring(ok_cd and on_cd)
            )
        )
    end

    return false
end

---@param local_player game_object
---@param target game_object
---@param helpers table
---@return boolean
local function try_premeditation(local_player, target, helpers, cp)
    local m = menu(helpers)
    if not m or not m.pvp_use_premeditation or m.pvp_use_premeditation:get_state() ~= true then
        return false
    end

    -- Throttle: prevent spam-queueing before server confirms cooldown
    local now = core.time()
    if (now - last_premeditation_time) < PREMEDITATION_THROTTLE then
        return false
    end

    -- CP guard: Premed adds +2 CP, skip if we'd overcap
    if cp and cp >= 4 then
        return false
    end

    local premed = spell_data.utility and spell_data.utility.premeditation
    if not premed or not premed.ids then
        return false
    end

    local learned_id = nil
    for i = #premed.ids, 1, -1 do
        local id = premed.ids[i]
        local is_learned = spell_helper:is_spell_castable(id, local_player, target, true, true, true, true, false)
        if is_learned then
            learned_id = id
            break
        end
    end
    if not learned_id then
        return false
    end

    if spell_helper:is_spell_on_cooldown(learned_id) then
        return false
    end

    if spell_helper:is_spell_castable(learned_id, local_player, target, false, false, false, false, true) then
        spell_queue:queue_spell_target(learned_id, target, 9, premed.name)
        last_premeditation_time = now
        return true
    end

    return false
end

---@param local_player game_object
---@param unit game_object
---@param helpers table
---@param cp number
---@return boolean
local function try_deadly_throw_interrupt(local_player, unit, helpers, cp)
    local m = menu(helpers)
    if not m or not m.pvp_use_deadly_throw_interrupt or m.pvp_use_deadly_throw_interrupt:get_state() ~= true then
        return false
    end

    if not unit or not unit:is_valid() then
        return false
    end

    if not unit:is_casting_spell() or not unit:is_active_spell_interruptable() then
        return false
    end

    if (unit:get_cast_pct() or 0) < 85 then
        return false
    end

    if cp < 1 then
        return false
    end

    if m.pvp_dt_requires_gloves and m.pvp_dt_requires_gloves.get_state and m.pvp_dt_requires_gloves:get_state() == true then
        if not helpers or not helpers.has_deadly_throw_interrupt_gloves_equipped or not helpers:has_deadly_throw_interrupt_gloves_equipped(local_player) then
            return false
        end
    end

    local dt = spell_data.finishers and spell_data.finishers.deadly_throw
    if not dt or not dt.ids then
        return false
    end

    if local_player:get_power(enums.power_type.ENERGY) < (dt.energy_cost or 35) then
        return false
    end

    for i = #dt.ids, 1, -1 do
        local spell_id = dt.ids[i]
        if spell_helper:is_spell_castable(spell_id, local_player, unit, false, false, false, false, false) then
            spell_queue:queue_spell_target(spell_id, unit, 9, "Deadly Throw (Interrupt)")
            return true
        end
    end

    return false
end

---@param ids number[]
---@param local_player game_object
---@param target game_object
---@return number|nil
local function get_highest_learned_spell_id(ids, local_player, target)
    if not ids then
        return nil
    end

    for i = #ids, 1, -1 do
        local spell_id = ids[i]
        local is_learned = spell_helper:is_spell_castable(
            spell_id,
            local_player,
            target,
            true,  -- skip_facing
            true,  -- skip_range
            true,  -- skip_usable
            true,  -- skip_controller
            false  -- skip_learned = FALSE
        )
        if is_learned then
            return spell_id
        end
    end

    return nil
end

---@param local_player game_object
---@param unit game_object
---@param helpers table
---@return boolean
local function try_shadowstep_interrupt(local_player, unit, helpers)
    local m = menu(helpers)
    if not m or not m.pvp_use_shadowstep_interrupt or m.pvp_use_shadowstep_interrupt:get_state() ~= true then
        return false
    end

    if helpers and helpers.is_in_stealth and helpers:is_in_stealth(local_player) then
        if not m.pvp_step_interrupt_in_stealth or m.pvp_step_interrupt_in_stealth:get_state() ~= true then
            return false
        end
    end

    if not unit or not unit:is_valid() or unit:is_dead() then
        return false
    end
    if not unit:is_casting_spell() or not unit:is_active_spell_interruptable() then
        return false
    end

    -- Only step if Kick is learned + ready and we're out of melee range.
    local kick = spell_data.cc and spell_data.cc.kick
    local kick_id = kick and kick.ids and get_highest_learned_spell_id(kick.ids, local_player, unit) or nil
    if not kick_id or spell_helper:is_spell_on_cooldown(kick_id) then
        return false
    end

    local dist_ok, dist = pcall(function()
        return unit:distance()
    end)
    if not dist_ok or type(dist) ~= "number" then
        return false
    end
    if dist <= 5.5 or dist > 25.0 then
        return false
    end

    -- Check if we can realistically have Kick energy by the time the cast finishes.
    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    local remaining_ms = unit:get_cast_remaining_ms() or 0
    local regen_rate = 20
    if helpers and helpers.has_buff and helpers:has_buff(local_player, "adrenaline_rush") then
        regen_rate = 40
    end
    local needed_ms = math.max(0, 25 - energy) / regen_rate * 1000
    if remaining_ms < (needed_ms + 150) then
        return false
    end

    local step = spell_data.cooldowns and spell_data.cooldowns.shadowstep
    local step_id = step and step.ids and get_highest_learned_spell_id(step.ids, local_player, unit) or nil
    if not step_id or spell_helper:is_spell_on_cooldown(step_id) then
        return false
    end

    if spell_helper:is_spell_castable(step_id, local_player, unit, false, false, false, false, false) then
        spell_queue:queue_spell_target(step_id, unit, 10, "Shadowstep (Interrupt)")
        return true
    end

    return false
end

---@param local_player game_object
---@param current_target game_object|nil
---@param helpers table
---@param targets_list game_object[]|nil
---@return game_object|nil
local function select_pvp_target(local_player, current_target, helpers, targets_list)
    local m = menu(helpers)
    if not m or not m.pvp_targeting_mode or not m.pvp_targeting_mode.get then
        return current_target
    end

    local mode = m.pvp_targeting_mode:get()
    if mode == 1 then
        return current_target
    end

    for _, unit in __object_safety.live_ipairs(targets_list or {}) do
        if is_valid_enemy_player(unit, local_player) then
            return unit
        end
    end

    return current_target
end

---@param local_player game_object
---@param desired game_object
---@param current game_object|nil
---@return boolean
local function maybe_switch_target(local_player, desired, current)
    if not local_player or not desired or desired == current then
        return false
    end

    local now = core.time()
    if (now - last_target_switch_time) < TARGET_SWITCH_COOLDOWN then
        return false
    end

    local ok = pcall(function()
        return core.input.set_target(desired)
    end)
    if ok then
        last_target_switch_time = now
        return true
    end

    return false
end

---@param local_player game_object
---@param helpers table
---@param targets_list game_object[]|nil
---@return boolean
function pvp:execute(local_player, helpers, targets_list)
    if not local_player or not helpers then
        return false
    end

    if not is_enabled(helpers, local_player) then
        pvp_log("exec.disabled", 2.0, "[PVP] DISABLED (pvp mode off / scenario gated)")
        return false
    end

    -- Cache menu ref for pvp_log
    pvp_log_menu_ref = helpers and helpers._menu_elements or nil
    pvp_log("build.id", 5.0, "[PVP] Build " .. PVP_BUILD_ID)
    pvp_log_frame_state(helpers, local_player, local_player:get_target())
    -- Inject log function into sub-modules
    if pvp_trinket_tracker and pvp_trinket_tracker.set_log_fn then
        pvp_trinket_tracker:set_log_fn(pvp_log)
    end

    maybe_auto_focus(local_player, helpers, targets_list)

    local current_target = local_player:get_target()
    local desired_target = select_pvp_target(local_player, current_target, helpers, targets_list)
    if desired_target and (not __object_safety.same(desired_target,current_target)) then
        if maybe_switch_target(local_player, desired_target, current_target) then
            pvp_log("exec.switch", 0.5, "[PVP] Target switch to " .. safe_name(desired_target))
            return true
        end
    end

    local target = desired_target or current_target
    if not target or not target:is_valid() or target:is_dead() then
        pvp_log("exec.no_target", 1.0, "[PVP] No valid target")
        return false
    end

    -- Open world QoL: if we're not in an actual PvP scenario (Arena/BG) and the
    -- current target isn't an enemy player, do not claim the frame. Let the PvE
    -- leveling lists run instead (prevents "does nothing" when you accidentally
    -- target NPCs/pets while PvP mode is enabled).
    if helpers and helpers.is_pvp_scenario and not helpers:is_pvp_scenario() then
        if not is_valid_enemy_player(target, local_player) then
            pvp_log("exec.fallthrough", 1.0, "[PVP] Open world non-player target: allow PvE fallthrough")
            return false
        end
    end

    local m = menu(helpers)

    pvp_log_frame_state(helpers, local_player, target)
    do
        local opener_mode = (m and m.pvp_opener_mode and m.pvp_opener_mode.get and m.pvp_opener_mode:get()) or -1
        local targeting_mode = (m and m.pvp_targeting_mode and m.pvp_targeting_mode.get and m.pvp_targeting_mode:get()) or -1
        local require_scenario = (m and m.pvp_require_pvp_scenario and m.pvp_require_pvp_scenario.get_state and m.pvp_require_pvp_scenario:get_state() == true) or false
        local cc_min_dr = (m and m.pvp_cc_min_dr and m.pvp_cc_min_dr.get and m.pvp_cc_min_dr:get()) or -1
        pvp_log(
            "diag.menu",
            2.0,
            string.format(
                "[PVP][MENU] opener_mode=%d targeting_mode=%d require_scenario=%s cc_min_dr=%d",
                opener_mode,
                targeting_mode,
                tostring(require_scenario),
                cc_min_dr
            )
        )
    end

    -- Spell castability telemetry (throttled)
    do
        local openers = spell_data.openers or {}
        pvp_log_spell_family(local_player, target, "Garrote", (openers.garrote and openers.garrote.ids) or nil)
        pvp_log_spell_family(local_player, target, "CheapShot", (openers.cheap_shot and openers.cheap_shot.ids) or nil)
        local builders = spell_data.builders or {}
        pvp_log_spell_family(local_player, target, "Hemorrhage", (builders.hemorrhage and builders.hemorrhage.ids) or nil)
        pvp_log_spell_family(local_player, target, "SinisterStrike", (builders.sinister_strike and builders.sinister_strike.ids) or nil)
        local finishers = spell_data.finishers or {}
        pvp_log_spell_family(local_player, target, "Eviscerate", (finishers.eviscerate and finishers.eviscerate.ids) or nil)
        local cc = spell_data.cc or {}
        pvp_log_spell_family(local_player, target, "Kick", (cc.kick and cc.kick.ids) or nil)
        pvp_log_spell_family(local_player, target, "Gouge", (cc.gouge and cc.gouge.ids) or nil)
    end

    -- Keep facing the target in melee range (helps prevent castable=false stalls
    -- when auto-attacking but slightly off-facing due to movement/camera).
    do
        local ok_dist, dist = pcall(function() return target:distance() end)
        if ok_dist and type(dist) == "number" and dist <= 6.0 then
            maybe_face_target(local_player, target)
        end
    end
    local cp = helpers.get_combo_points and helpers:get_combo_points(local_player) or 0
    local energy_log = local_player:get_power(enums.power_type.ENERGY) or 0
    local hp_log = local_player:get_health_percentage()
    local target_hp_log = target:get_health_percentage()
    pvp_log("exec.start", 0.5, string.format("[PVP] EXEC target=%s t_hp=%d%% hp=%d%% cp=%d e=%d",
        safe_name(target), target_hp_log, hp_log, cp, energy_log))

    -- CC-chain state reset: clear stale data on target change or timeout (Fix 8)
    do
        local now = core.time()
        local ok_guid, target_guid = pcall(function() return target:get_guid() end)
        local guid = ok_guid and target_guid or nil
        -- Reset if target changed (also fires when last_kidney_target_guid is nil after timeout)
        if guid and guid ~= cc_chain_state.last_kidney_target_guid then
            cc_chain_state.last_kidney_time = 0
            cc_chain_state.last_kidney_target_guid = nil
        end
        -- Reset if last KS was more than 10s ago (well beyond any CC-chain window)
        if (now - cc_chain_state.last_kidney_time) > 10.0 then
            cc_chain_state.last_kidney_time = 0
            cc_chain_state.last_kidney_target_guid = nil
        end
    end

    -- ===================================================================
    -- GOUGE RESTEALTH: If active, override all other logic
    -- ===================================================================
    if m and m.pvp_gouge_restealth and m.pvp_gouge_restealth.get_state and m.pvp_gouge_restealth:get_state() == true then
        if pvp_gouge_restealth:execute(local_player, target, helpers, pvp_log) then
            pvp_log("gouge_rs.active", 0.5, "[PVP][GOUGE_RS] Active, claiming frame")
            return true
        end
    end

    -- ===================================================================
    -- BLIND RESET CYCLE: Blind → Bandage → Restealth → Sap → Opener
    -- ===================================================================
    if pvp_reset_cycle:is_active() or (m and m.pvp_reset_cycle and m.pvp_reset_cycle.get_state and m.pvp_reset_cycle:get_state() == true) then
        if pvp_reset_cycle:execute(local_player, target, helpers, m, pvp_log) then
            pvp_log("reset.active", 0.5, "[PVP][RESET] Active phase=" .. tostring(pvp_reset_cycle:get_phase()))
            return true
        end
    end

    -- ===================================================================
    -- TRINKET TRACKER: Check for early CC breaks (trinket detection)
    -- ===================================================================
    if m and m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
        local now_tt = core.time()
        local trinket_just_used = pvp_trinket_tracker:check(target, now_tt)
        if trinket_just_used then
            pvp_log("trinket.detected", 0, "[PVP][TRINKET] Trinket detected on " .. safe_name(target) .. "!")
            -- Reactive: trinket detected! Immediately Blind if available
            if local_player:get_power(enums.power_type.ENERGY) >= 30 then
                local min_mult = dr_min_mult(helpers)
                local ok_immune_b, immune_b = pcall(function()
                    return pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.DISORIENT, 1000)
                end)
                if not (ok_immune_b and immune_b) and dr_allows(target, pvp_helper.cc_flags.DISORIENT, min_mult) then
                    if helpers:try_cast_cc(local_player, target, "blind") then
                        pvp_log("trinket.blind", 0, "[PVP][TRINKET] Reactive Blind on " .. safe_name(target))
                        return true
                    end
                end
            end
        end
    end

    -- ===================================================================
    -- DAMAGE IMMUNITY CHECK: Detect immune / heavily reduced targets
    -- ===================================================================
    local target_is_immune = false
    local target_heavy_reduction = false
    do
        local ok_immune, immune_result = pcall(function()
            return pvp_helper:is_damage_immune(target)
        end)
        if ok_immune and immune_result then
            target_is_immune = true
            pvp_log("immune", 1.0, "[PVP][IMMUNE] Target " .. safe_name(target) .. " is damage immune")
        end

        if not target_is_immune then
            local ok_dr, has_dr = pcall(function()
                return pvp_helper:has_damage_reduction(target, 50)
            end)
            if ok_dr and has_dr then
                target_heavy_reduction = true
                pvp_log("dmg_red", 1.0, "[PVP][IMMUNE] Target " .. safe_name(target) .. " has heavy damage reduction")
            end
        end
    end

    -- Focus interrupt priority (does not require target swapping)
    if m and m.pvp_auto_kick_focus and m.pvp_auto_kick_focus.get_state and m.pvp_auto_kick_focus:get_state() == true then
        local ok_focus, focus = pcall(function()
            return core.input.get_focus()
        end)
        if ok_focus and focus and is_valid_enemy_player(focus, local_player) and focus:is_casting_spell() and focus:is_active_spell_interruptable() then
            pvp_log("focus.casting", 0.5, "[PVP][FOCUS] Focus " .. safe_name(focus) .. " casting interruptible spell")
            if helpers:try_interrupt_cast(local_player, focus) then
                pvp_log("focus.kick", 0, "[PVP][FOCUS] Kick on Focus=" .. safe_name(focus))
                return true
            end
            if try_shadowstep_interrupt(local_player, focus, helpers) then
                pvp_log("focus.step", 0, "[PVP][FOCUS] Shadowstep interrupt on Focus=" .. safe_name(focus))
                return true
            end
            -- Gouge as interrupt fallback on focus (if in melee range)
            if m.pvp_use_gouge and m.pvp_use_gouge.get_state and m.pvp_use_gouge:get_state() == true then
                local focus_dist_ok, focus_dist = pcall(function() return focus:distance() end)
                if focus_dist_ok and type(focus_dist) == "number" and focus_dist <= 5.5 then
                    if helpers:try_cast_cc(local_player, focus, "gouge") then
                        pvp_log("focus.gouge", 0, "[PVP][FOCUS] Gouge interrupt on Focus=" .. safe_name(focus))
                        return true
                    end
                end
            end
            if try_deadly_throw_interrupt(local_player, focus, helpers, cp) then
                pvp_log("focus.dt", 0, "[PVP][FOCUS] Deadly Throw interrupt on Focus=" .. safe_name(focus))
                return true
            end
        end
    end

    -- Target interrupt priority
    if target:is_casting_spell() and target:is_active_spell_interruptable() then
        pvp_log("target.casting", 0.5, "[PVP][KICK] Target " .. safe_name(target) .. " casting interruptible spell")
        if helpers:try_interrupt_cast(local_player, target) then
            pvp_log("target.kick", 0, "[PVP][KICK] Kick on Target=" .. safe_name(target))
            return true
        end
        if try_shadowstep_interrupt(local_player, target, helpers) then
            pvp_log("target.step", 0, "[PVP][KICK] Shadowstep interrupt on Target=" .. safe_name(target))
            return true
        end
        -- Gouge as interrupt fallback on target
        if m and m.pvp_use_gouge and m.pvp_use_gouge.get_state and m.pvp_use_gouge:get_state() == true then
            if helpers:try_cast_cc(local_player, target, "gouge") then
                pvp_log("target.gouge", 0, "[PVP][KICK] Gouge interrupt on Target=" .. safe_name(target))
                return true
            end
        end
        if try_deadly_throw_interrupt(local_player, target, helpers, cp) then
            pvp_log("target.dt", 0, "[PVP][KICK] Deadly Throw interrupt on Target=" .. safe_name(target))
            return true
        end
    end

    -- Stealth/Openers
    if helpers:is_in_stealth(local_player) then
        pvp_log("stealth.enter", 0.5, string.format("[PVP][STEALTH] In stealth, cp=%d energy=%d", cp or 0, (local_player:get_power(enums.power_type.ENERGY) or 0)))
        if not m or not m.pvp_auto_opener or m.pvp_auto_opener:get_state() ~= true then
            pvp_log("stealth.no_auto", 2.0, "[PVP][STEALTH] Auto-opener disabled, claiming frame")
            return true
        end

        -- Attempt Sap on Focus first (if enabled)
        if m.pvp_auto_sap_focus and m.pvp_auto_sap_focus.get_state and m.pvp_auto_sap_focus:get_state() == true then
            local ok_focus, focus = pcall(function()
                return core.input.get_focus()
            end)
            if ok_focus and focus and (not __object_safety.same(focus,target)) and is_valid_enemy_player(focus, local_player) then
                local can_sap = true
                local min_mult = dr_min_mult(helpers)
                if pvp_helper and pvp_helper.is_cc_immune then
                    local immune = pvp_helper:is_cc_immune(focus, pvp_helper.cc_flags.SAP, 1000)
                    if immune then
                        can_sap = false
                        pvp_log("stealth.sap_immune", 1.0, "[PVP][STEALTH] Sap blocked: Focus=" .. safe_name(focus) .. " immune")
                    end
                end
                if can_sap and dr_allows(focus, pvp_helper.cc_flags.SAP, min_mult) then
                    local sap = spell_data.openers and spell_data.openers.sap
                    if sap and sap.ids and not focus:affecting_combat() then
                        if try_cast_highest_rank_opener(local_player, focus, sap.ids, sap.name, 9, helpers, false) then
                            pvp_log("stealth.sap", 0, "[PVP][STEALTH] Sap on Focus=" .. safe_name(focus))
                            return true
                        end
                    end
                end
            end
        end

        -- Fire-and-forget: queue Premed but don't block opener logic
        local premed_result = try_premeditation(local_player, target, helpers, cp)
        if premed_result then
            pvp_log("stealth.premed", 0, string.format("[PVP][STEALTH] Premed queued (cp=%d)", cp or 0))
        end

        local opener_mode = (m and m.pvp_opener_mode and m.pvp_opener_mode.get and m.pvp_opener_mode:get()) or 3
        local use_garrote = opener_mode == 2
        local use_ambush = opener_mode == 4
        local use_expose_armor = opener_mode == 5
         if opener_mode == 3 then
             -- Auto: use Garrote against mana users (caster/healer leaning), otherwise Cheap Shot.
             local ok_mana, mana_max = pcall(function()
                 return target:get_max_power(0)
             end)
             use_garrote = ok_mana and type(mana_max) == "number" and mana_max > 0

            -- Class awareness: vs Warriors prefer Garrote opener (avoid Second Wind stun-heal value)
            if not use_garrote and m and m.pvp_class_awareness and m.pvp_class_awareness.get_state and m.pvp_class_awareness:get_state() == true then
                local ok_class, class_id = pcall(function() return target:get_class() end)
                if ok_class and class_id == enums.class_id.WARRIOR then
                    use_garrote = true
                end
            end

            -- Auto opener safety: only attempt Garrote when we're actually behind.
            if use_garrote and helpers and helpers.is_behind_target then
                local ok_behind, behind = pcall(function()
                    return helpers:is_behind_target(local_player, target)
                end)
                if not ok_behind or behind ~= true then
                    use_garrote = false
                end
            end
         end

        local mode_names = {[1]="CS",[2]="Garrote",[3]="Auto",[4]="Ambush",[5]="ExposeArmor"}
        pvp_log("stealth.opener", 0.5, "[PVP][OPENER] Mode=" .. (mode_names[opener_mode] or "?") .. " garrote=" .. tostring(use_garrote) .. " ambush=" .. tostring(use_ambush) .. " target=" .. safe_name(target))

        local min_mult = dr_min_mult(helpers)

        -- Expose Armor opener: Preme → CS → EA(5cp) → continue rotation
        -- Best with physical DPS partners (Feral, Warrior, Hunter)
        if use_expose_armor then
            local ea_debuff_ids = spell_data.debuffs and spell_data.debuffs.expose_armor
            local has_ea = ea_debuff_ids and has_any_debuff(target, ea_debuff_ids)
            if not has_ea then
                -- Step 1: CS to stun (if we still need CP for EA)
                if cp < 5 then
                    local cs_ea = spell_data.openers and spell_data.openers.cheap_shot
                    if cs_ea and cs_ea.ids and dr_allows(target, pvp_helper.cc_flags.STUN, min_mult) then
                        if try_cast_highest_rank_opener(local_player, target, cs_ea.ids, cs_ea.name, 9, helpers, false) then
                            pvp_log("stealth.opener_ok", 0, "[PVP][OPENER] CS (for EA) on " .. safe_name(target))
                            if m and m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
                                pvp_trinket_tracker:on_cc_applied(target, "cheap_shot", 0, core.time())
                            end
                            return true
                        end
                    else
                        pvp_log("stealth.opener_dr", 0.5, "[PVP][OPENER] CS (for EA) blocked by DR on " .. safe_name(target))
                    end
                end
                -- Step 2: If we have 5 CP, cast Expose Armor (only when out of stealth - CS must have landed first)
                if cp >= 5 and not helpers:is_in_stealth(local_player) then
                    if helpers:try_cast_finisher(local_player, target, "expose_armor") then
                        pvp_log("stealth.opener_ok", 0, "[PVP][OPENER] Expose Armor at 5cp on " .. safe_name(target))
                        return true
                    end
                end
            end
            -- EA already up or can't apply: fallthrough to Cheap Shot
        end

        -- Ambush: highest burst opener (requires behind target, no DR category)
        if use_ambush then
            local ambush = spell_data.openers and spell_data.openers.ambush
            if ambush and ambush.ids then
                if try_cast_highest_rank_opener(local_player, target, ambush.ids, ambush.name, 9, helpers, true) then
                    pvp_log("stealth.opener_ok", 0, "[PVP][OPENER] Ambush on " .. safe_name(target))
                    return true
                end
            end
            pvp_log("stealth.opener_fail", 0.5, "[PVP][OPENER] Ambush failed (not behind?), fallthrough to CS")
            -- Fallthrough to Cheap Shot if Ambush fails (not behind target)
        end

        if use_garrote then
            local garrote = spell_data.openers and spell_data.openers.garrote
            if garrote and garrote.ids and dr_allows(target, pvp_helper.cc_flags.SILENCE, min_mult) then
                if try_cast_highest_rank_opener(local_player, target, garrote.ids, garrote.name, 9, helpers, true) then
                    pvp_log("stealth.opener_ok", 0, "[PVP][OPENER] Garrote on " .. safe_name(target))
                    return true
                end
            else
                pvp_log("stealth.opener_dr", 0.5, "[PVP][OPENER] Garrote blocked by DR, fallthrough to CS")
            end
        end

        local cs = spell_data.openers and spell_data.openers.cheap_shot
        if cs and cs.ids and dr_allows(target, pvp_helper.cc_flags.STUN, min_mult) then
            if try_cast_highest_rank_opener(local_player, target, cs.ids, cs.name, 9, helpers, false) then
                pvp_log("stealth.opener_ok", 0, "[PVP][OPENER] Cheap Shot on " .. safe_name(target))
                -- Track Cheap Shot for trinket detection
                if m and m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
                    pvp_trinket_tracker:on_cc_applied(target, "cheap_shot", 0, core.time())
                end
                return true
            end
        else
            pvp_log("stealth.opener_dr", 0.5, "[PVP][OPENER] CS blocked by DR on " .. safe_name(target))
        end

        if not is_valid_enemy_player(target, local_player) then
            pvp_log("stealth.no_opener", 1.0, "[PVP][STEALTH] No opener on NPC target, PvE fallthrough")
            return false
        end
        pvp_log("stealth.no_opener", 1.0, "[PVP][STEALTH] No opener available, claiming frame")
        return true
    end

    -- ===================================================================
    -- STUN-WINDOW BURST MODE: When target is stunned, skip all utility
    -- and dump pure damage (Hemo→Evis). Guide-validated stunlock:
    -- CS → Hemo → Hemo → KS → Hemo → Hemo → Evis
    -- ===================================================================
    local ok_stunned, target_is_stunned = pcall(function() return target:is_stunned(500) end)
    if ok_stunned and target_is_stunned then
        local burst_energy = local_player:get_power(enums.power_type.ENERGY) or 0
        local burst_cp = cp
        pvp_log("stun.enter", 0.5, string.format("[PVP][STUN] Target stunned, burst mode cp=%d e=%d", burst_cp or 0, burst_energy or 0))

        -- Anti-trinket + Anti-restealth Shiv: Apply poisons ONCE early in stun window
        -- Crippling: if they trinket the stun, they're still snared
        -- Wound: vs Rogue/Druid prevents restealth via damage ticks
        if burst_energy >= 20 and burst_cp < 5 then
            local needs_crippling = not has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.crippling_poison)
            local needs_wound = false
            -- Class awareness: prioritize Wound on restealth classes
            if m and m.pvp_class_awareness and m.pvp_class_awareness.get_state and m.pvp_class_awareness:get_state() == true then
                local adj_stun = get_class_adjustments(target)
                if adj_stun.prevent_restealth then
                    needs_wound = not has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.wound_poison)
                end
            end
            if needs_crippling or needs_wound then
                if helpers:try_cast_builder(local_player, target, "shiv") then
                    pvp_log("stun.shiv", 0, "[PVP][STUN] Shiv for poison (crippling=" .. tostring(needs_crippling) .. " wound=" .. tostring(needs_wound) .. ")")
                    return true
                end
            end
        end

        -- Cold Blood activation (instant, off-GCD, no waste)
        if burst_cp >= 4 and burst_energy >= 35 then
            local cb_ready = helpers:is_cooldown_ready("cold_blood")
            local has_cb = helpers:has_buff(local_player, "cold_blood")
            if cb_ready and not has_cb and helpers:is_cooldowns_toggle_active() then
                if helpers:try_cast_cooldown(local_player, "cold_blood") then
                    pvp_log("stun.cb", 0, "[PVP][STUN] Cold Blood activated")
                    return true
                end
            end
        end

        -- Finisher at 5CP (or 4+ with Cold Blood)
        if burst_energy >= 35 then
            local has_cb = helpers:has_buff(local_player, "cold_blood")
            if burst_cp >= 5 or (has_cb and burst_cp >= 4) then
                -- Envenom if Deadly Poison active (higher damage than Evis)
                if spell_data.finishers and spell_data.finishers.envenom then
                    local dp_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.deadly_poison)
                    if dp_active then
                        if helpers:try_cast_finisher(local_player, target, "envenom") then
                            pvp_log("stun.finish", 0, string.format("[PVP][STUN] Envenom at %dcp (CB=%s)", burst_cp, tostring(has_cb)))
                            return true
                        end
                    end
                end
                if helpers:try_cast_finisher(local_player, target, "eviscerate") then
                    pvp_log("stun.finish", 0, string.format("[PVP][STUN] Eviscerate at %dcp (CB=%s)", burst_cp, tostring(has_cb)))
                    return true
                end
            end
            -- Execute path: low HP target, don't wait for 5CP
            if burst_cp >= 3 and target:get_health_percentage() < 20 then
                if helpers:try_cast_finisher(local_player, target, "eviscerate") then
                    pvp_log("stun.finish", 0, string.format("[PVP][STUN] Execute Evis at %dcp (hp<20%%)", burst_cp))
                    return true
                end
            end
        end

        -- Aggressive Hemo spam (lowest threshold: 35 Energy base cost)
        if burst_cp < 5 and burst_energy >= 35 then
            if helpers:try_cast_builder(local_player, target, "hemorrhage") then
                pvp_log("stun.build", 0.35, string.format("[PVP][STUN] Hemo (cp=%d, e=%d)", burst_cp, burst_energy))
                return true
            end
            -- Fallback: Sinister Strike if Hemo not learned
            if helpers:try_cast_builder(local_player, target, "sinister_strike") then
                pvp_log("stun.build", 0.35, string.format("[PVP][STUN] SS fallback (cp=%d, e=%d)", burst_cp, burst_energy))
                return true
            end
        end

        pvp_log("stun.pool", 0.5, string.format("[PVP][STUN] Pooling energy (e=%d, cp=%d)", burst_energy, burst_cp))
        return true -- Claim frame, pool energy for next GCD
    end

    -- ===================================================================
    -- HYBRID KEYBIND OVERRIDES: Force-cast critical CDs on keypress
    -- ===================================================================
    if m then
        -- Force Vanish keybind
        if m.pvp_vanish_keybind and m.pvp_vanish_keybind.get_state and m.pvp_vanish_keybind:get_state() == true then
            local now_key = core.time()
            local throttled = (now_key - (last_keybind_action_time.vanish or 0.0)) < KEYBIND_THROTTLE
            if not throttled and not keybind_last_down.vanish then
                keybind_last_down.vanish = true
                last_keybind_action_time.vanish = now_key
                pvp_log("key.vanish", 0, "[PVP][KEY] Force Vanish pressed")
                pcall(function()
                    if m.pvp_vanish_keybind.set_state then
                        m.pvp_vanish_keybind:set_state(false)
                    end
                end)
                if helpers:is_cooldown_ready("vanish") and (core.time() - last_vanish_queue_time) >= COOLDOWN_QUEUE_THROTTLE then
                    if helpers:try_cast_cooldown(local_player, "vanish") then
                        last_vanish_queue_time = core.time()
                        pvp_log("key.vanish_ok", 0, "[PVP][KEY] Vanish queued")
                        return true
                    end
                end
            end
        else
            if keybind_last_down.vanish then
                pvp_log("keybind.vanish_off", 5.0, "[PVP][KB] Vanish keybind disabled")
            end
            keybind_last_down.vanish = false
        end

        -- Force Blind keybind
        if m.pvp_blind_keybind and m.pvp_blind_keybind.get_state and m.pvp_blind_keybind:get_state() == true then
            local now_key = core.time()
            local throttled = (now_key - (last_keybind_action_time.blind or 0.0)) < KEYBIND_THROTTLE
            if not throttled and not keybind_last_down.blind then
                keybind_last_down.blind = true
                last_keybind_action_time.blind = now_key
                pvp_log("key.blind", 0, "[PVP][KEY] Force Blind pressed")
                pcall(function()
                    if m.pvp_blind_keybind.set_state then
                        m.pvp_blind_keybind:set_state(false)
                    end
                end)
                if helpers:try_cast_cc(local_player, target, "blind") then
                    pvp_log("key.blind_ok", 0, "[PVP][KEY] Blind queued on " .. safe_name(target))
                    return true
                end
            end
        else
            if keybind_last_down.blind then
                pvp_log("keybind.blind_off", 5.0, "[PVP][KB] Blind keybind disabled")
            end
            keybind_last_down.blind = false
        end

        -- Force Preparation keybind
        if m.pvp_prep_keybind and m.pvp_prep_keybind.get_state and m.pvp_prep_keybind:get_state() == true then
            local now_key = core.time()
            local throttled = (now_key - (last_keybind_action_time.prep or 0.0)) < KEYBIND_THROTTLE
            if not throttled and not keybind_last_down.prep then
                keybind_last_down.prep = true
                last_keybind_action_time.prep = now_key
                pvp_log("key.prep", 0, "[PVP][KEY] Force Preparation pressed")
                pcall(function()
                    if m.pvp_prep_keybind.set_state then
                        m.pvp_prep_keybind:set_state(false)
                    end
                end)
                if helpers:is_cooldown_ready("preparation") then
                    if helpers:try_cast_cooldown(local_player, "preparation") then
                        pvp_log("key.prep_ok", 0, "[PVP][KEY] Preparation queued")
                        return true
                    end
                end
            end
        else
            if keybind_last_down.prep then
                pvp_log("keybind.prep_off", 5.0, "[PVP][KB] Prep keybind disabled")
            end
            keybind_last_down.prep = false
        end
    end

    -- ===================================================================
    -- PVP COOLDOWNS: Proactive Evasion, Sprint gap-close, Offensive Vanish, Preparation
    -- ===================================================================

    -- PROACTIVE EVASION (vs melee cleaves: trigger when N+ melee enemies in range)
    if m and m.pvp_proactive_evasion and m.pvp_proactive_evasion.get_state and m.pvp_proactive_evasion:get_state() == true then
        if helpers:is_cooldown_ready("evasion") then
            local melee_count = 0
            local melee_threshold = (m.pvp_evasion_melee_count and m.pvp_evasion_melee_count.get and m.pvp_evasion_melee_count:get()) or 2
            for _, unit in __object_safety.live_ipairs(targets_list or {}) do
                if is_valid_enemy_player(unit, local_player) then
                    local ok_melee, is_melee = pcall(function() return pvp_helper:is_melee(unit) end)
                    if ok_melee and is_melee then
                        local ok_dist, dist = pcall(function() return unit:distance() end)
                        if ok_dist and type(dist) == "number" and dist <= 8 then
                            melee_count = melee_count + 1
                        end
                    end
                end
            end
            if melee_count >= melee_threshold then
                if helpers:try_cast_cooldown(local_player, "evasion") then
                    pvp_log("cd.evasion", 0, string.format("[PVP][CD] Proactive Evasion (melee_count=%d)", melee_count))
                    return true
                end
            end
        end
    end

    -- CLOAK OF SHADOWS OFFENSIVE: Remove slows/roots before gap-closing
    if m and m.pvp_react_to_burst and m.pvp_react_to_burst.get_state and m.pvp_react_to_burst:get_state() == true then
        local ok_tdist, target_dist = pcall(function() return target:distance() end)
        if ok_tdist and type(target_dist) == "number" and target_dist > 8 then
            local ok_slowed, is_slowed = pcall(function()
                return local_player:is_movement_impaired()
            end)
            if ok_slowed and is_slowed then
                if not helpers:has_buff(local_player, "cloak_of_shadows") and helpers:is_cooldown_ready("cloak_of_shadows") then
                    if helpers:try_cast_cooldown(local_player, "cloak_of_shadows") then
                        pvp_log("cd.clos", 0, string.format("[PVP][CD] CloS offensive (movement impaired, target dist=%.0f)", target_dist))
                        return true
                    end
                end
            end
        end
    end

    -- SHADOWSTEP GAP-CLOSE (primary gap-closer: 30s CD, teleports behind target)
    -- TBC PvP guides: Shadowstep is the #1 tool for re-engaging after target escapes.
    do
        local ok_dist, dist = pcall(function() return target:distance() end)
        if ok_dist and type(dist) == "number" and dist > 6 and dist <= 25 then
            local step = spell_data.cooldowns and spell_data.cooldowns.shadowstep
            if step and step.ids then
                local step_id = get_highest_learned_spell_id(step.ids, local_player, target)
                if step_id and not spell_helper:is_spell_on_cooldown(step_id) and (core.time() - last_shadowstep_gap_time) >= COOLDOWN_QUEUE_THROTTLE then
                    if spell_helper:is_spell_castable(step_id, local_player, target, false, false, false, false, false) then
                        spell_queue:queue_spell_target(step_id, target, 8, "Shadowstep (Gap-Close)")
                        last_shadowstep_gap_time = core.time()
                        pvp_log("cd.step_gap", 0, string.format("[PVP][CD] Shadowstep gap-close (dist=%.0f)", dist))
                        return true
                    else
                        pvp_log("cd.step_gap_fail", 2.0, string.format("[PVP][CD] Shadowstep castable=false (dist=%.0f)", dist))
                    end
                end
            end
        end
    end

    -- SPRINT GAP-CLOSE (when target out of melee and Shadowstep on CD)
    if m and m.pvp_use_sprint_gap_close and m.pvp_use_sprint_gap_close.get_state and m.pvp_use_sprint_gap_close:get_state() == true then
        local ok_dist, dist = pcall(function() return target:distance() end)
        if ok_dist and type(dist) == "number" and dist > 8 and dist <= 30 then
            -- Check if Shadowstep is on cooldown
            local step_on_cd = true
            local step = spell_data.cooldowns and spell_data.cooldowns.shadowstep
            if step and step.ids then
                local step_id = get_highest_learned_spell_id(step.ids, local_player, target)
                if step_id and not spell_helper:is_spell_on_cooldown(step_id) then
                    step_on_cd = false
                end
            end
            if step_on_cd and helpers:is_cooldown_ready("sprint") and (core.time() - last_sprint_queue_time) >= COOLDOWN_QUEUE_THROTTLE then
                if helpers:try_cast_cooldown(local_player, "sprint") then
                    last_sprint_queue_time = core.time()
                    pvp_log("cd.sprint", 0, string.format("[PVP][CD] Sprint gap-close (dist=%.0f, step on CD)", dist))
                    return true
                end
            end
        end
    end

    -- OFFENSIVE VANISH (re-opener for kill pressure when target is low)
    if m and m.pvp_offensive_vanish and m.pvp_offensive_vanish.get_state and m.pvp_offensive_vanish:get_state() == true then
        local cooldowns_active = helpers:is_cooldowns_toggle_active()
        if cooldowns_active and helpers:is_cooldown_ready("vanish") then
            local vanish_hp_th = (m.pvp_vanish_hp_threshold and m.pvp_vanish_hp_threshold.get and m.pvp_vanish_hp_threshold:get()) or 40
            local target_hp = target:get_health_percentage()
            if target_hp <= vanish_hp_th then
                -- Safety: check no bleeds/dots on self that would break stealth immediately
                local has_dots_on_self = false
                if spell_data and spell_data.damage_over_time then
                    local dot_groups = {
                        spell_data.damage_over_time.warrior_bleeds,
                        spell_data.damage_over_time.druid_bleeds,
                        spell_data.damage_over_time.druid_dots,
                        spell_data.damage_over_time.warlock_dots,
                        spell_data.damage_over_time.hunter_dots,
                        spell_data.damage_over_time.priest_dots,
                        spell_data.damage_over_time.mage_dots,
                        spell_data.damage_over_time.shaman_dots
                    }
                    for _, group in ipairs(dot_groups) do
                        if type(group) == "table" then
                            for _, dot_id in ipairs(group) do
                                local ok_dot, has_dot = pcall(function()
                                    return local_player:debuff_up(dot_id) == true
                                end)
                                if ok_dot and has_dot then
                                    has_dots_on_self = true
                                    break
                                end
                            end
                        end
                        if has_dots_on_self then break end
                    end
                end
                if not has_dots_on_self then
                    -- DR pre-check: ensure at least one opener would land after Vanish
                    local min_mult = dr_min_mult(helpers)
                    local cs_ok = dr_allows(target, pvp_helper.cc_flags.STUN, min_mult)
                    local garrote_ok = dr_allows(target, pvp_helper.cc_flags.SILENCE, min_mult)
                    if cs_ok or garrote_ok then
                        if (core.time() - last_vanish_queue_time) >= COOLDOWN_QUEUE_THROTTLE then
                            if helpers:try_cast_cooldown(local_player, "vanish") then
                                last_vanish_queue_time = core.time()
                                pvp_log("cd.vanish", 0, string.format("[PVP][CD] Offensive Vanish (target hp=%.0f%%)", target_hp))
                                return true -- Next frame enters stealth opener logic
                            end
                        end
                    end
                else
                    pvp_log("cd.vanish_block", 1.0, "[PVP][CD] Vanish blocked (DoTs on self)")
                end
            end
        end
    end

    -- PREPARATION (PvP: reset Vanish primarily -- Vanish alone is worth Prep in Arena)
    if m and m.pvp_use_preparation and m.pvp_use_preparation.get_state and m.pvp_use_preparation:get_state() == true then
        if helpers:is_cooldown_ready("preparation") then
            -- Check if Vanish is on cooldown (the primary reason to Prep in PvP)
            local vanish = spell_data.cooldowns and spell_data.cooldowns.vanish
            local vanish_on_cd = false
            if vanish and vanish.ids then
                for i = #vanish.ids, 1, -1 do
                    if spell_helper:is_spell_on_cooldown(vanish.ids[i]) then
                        vanish_on_cd = true
                        break
                    end
                end
            end
            if vanish_on_cd then
                if helpers:try_cast_cooldown(local_player, "preparation") then
                    pvp_log("cd.prep", 0, "[PVP][CD] Preparation (Vanish on CD)")
                    return true
                end
            end
        end
    end

    -- ===================================================================
    -- ENEMY BURST DETECTION: Reactive Evasion / CloS when enemy pops CDs
    -- ===================================================================
    if m and m.pvp_react_to_burst and m.pvp_react_to_burst.get_state and m.pvp_react_to_burst:get_state() == true then
        for _, unit in __object_safety.live_ipairs(targets_list or {}) do
            if is_valid_enemy_player(unit, local_player) then
                local ok_dist, dist = pcall(function() return unit:distance() end)
                if ok_dist and type(dist) == "number" and dist <= 15 then
                    local ok_burst, has_burst = pcall(function()
                        return pvp_helper:has_burst_active(unit)
                    end)
                    if ok_burst and has_burst then
                        pvp_log("cd.burst_detect", 0.5, "[PVP][CD] Enemy burst detected on " .. safe_name(unit))
                        -- Melee burst: reactive Evasion (if not already up)
                        local ok_melee, is_melee = pcall(function() return pvp_helper:is_melee(unit) end)
                        if ok_melee and is_melee then
                            if not helpers:has_buff(local_player, "evasion") and helpers:is_cooldown_ready("evasion") then
                                if helpers:try_cast_cooldown(local_player, "evasion") then
                                    pvp_log("cd.burst_react", 0, "[PVP][CD] Reactive Evasion (melee burst from " .. safe_name(unit) .. ")")
                                    return true
                                end
                            end
                        else
                            -- Caster burst: reactive CloS (if not already up)
                            if not helpers:has_buff(local_player, "cloak_of_shadows") and helpers:is_cooldown_ready("cloak_of_shadows") then
                                if helpers:try_cast_cooldown(local_player, "cloak_of_shadows") then
                                    pvp_log("cd.burst_react", 0, "[PVP][CD] Reactive CloS (caster burst from " .. safe_name(unit) .. ")")
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- SHADOWSTEP DEFENSIVE (escape melee trains when low HP by stepping to distant focus/ally)
    if m and m.pvp_shadowstep_defensive and m.pvp_shadowstep_defensive.get_state and m.pvp_shadowstep_defensive:get_state() == true then
        local player_hp_def = local_player:get_health_percentage()
        local def_hp_th = (m.pvp_shadowstep_defensive_hp and m.pvp_shadowstep_defensive_hp.get and m.pvp_shadowstep_defensive_hp:get()) or 30
        if player_hp_def <= def_hp_th then
            local melee_count_def = 0
            for _, unit in __object_safety.live_ipairs(targets_list or {}) do
                if is_valid_enemy_player(unit, local_player) then
                    local ok_melee, is_melee = pcall(function() return pvp_helper:is_melee(unit) end)
                    if ok_melee and is_melee then
                        local ok_dist, dist = pcall(function() return unit:distance() end)
                        if ok_dist and type(dist) == "number" and dist <= 8 then
                            melee_count_def = melee_count_def + 1
                        end
                    end
                end
            end
            if melee_count_def >= 2 then
                local ok_focus, focus_def = pcall(function() return core.input.get_focus() end)
                if ok_focus and focus_def and focus_def:is_valid() and not focus_def:is_dead() then
                    local ok_friend, is_friend = pcall(function() return focus_def:is_friend_with(local_player) end)
                    if ok_friend and is_friend then
                        local ok_fdist, focus_dist = pcall(function() return focus_def:distance() end)
                        if ok_fdist and type(focus_dist) == "number" and focus_dist >= 15 and focus_dist <= 25 then
                            local step = spell_data.cooldowns and spell_data.cooldowns.shadowstep
                            if step and step.ids then
                                local step_id = get_highest_learned_spell_id(step.ids, local_player, focus_def)
                                if step_id and not spell_helper:is_spell_on_cooldown(step_id) then
                                    if spell_helper:is_spell_castable(step_id, local_player, focus_def, false, false, false, false, false) then
                                        spell_queue:queue_spell_target(step_id, focus_def, 10, "Shadowstep (Defensive)")
                                        pvp_log("cd.step_def", 0, string.format("[PVP][CD] Defensive Shadowstep to %s (hp=%.0f%%, melee=%d)", safe_name(focus_def), player_hp_def, melee_count_def))
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- RIPOSTE (PvP: reactive after parry, 6s Disarm -- extremely strong vs Warrior/Rogue)
    -- Only 10 energy, no menu toggle needed (PvE already has auto_riposte, PvP always attempts)
    local riposte_energy = local_player:get_power(enums.power_type.ENERGY) or 0
    if riposte_energy >= 10 then
        if helpers:try_cast_riposte(local_player, target) then
            pvp_log("cc.riposte", 0, "[PVP][CC] Riposte (6s Disarm) on " .. safe_name(target))
            return true
        end
    end

    -- Setup: Kidney Shot windows (DR-aware, class-aware)
    if m and m.pvp_use_kidney and m.pvp_use_kidney.get_state and m.pvp_use_kidney:get_state() == true then
        local burst_only = m.pvp_kidney_burst_only and m.pvp_kidney_burst_only.get_state and m.pvp_kidney_burst_only:get_state() == true
        if (not burst_only) or helpers:is_cooldowns_toggle_active() then
            -- Class awareness: skip KS on Warriors (Second Wind heals on stun)
            local class_aware = m.pvp_class_awareness and m.pvp_class_awareness.get_state and m.pvp_class_awareness:get_state() == true
            local adj = class_aware and get_class_adjustments(target) or {}
            local skip_stun = adj.avoid_stun == true

            if skip_stun then
                pvp_log("cc.kidney_skip", 1.0, "[PVP][CC] KS skipped (class awareness: avoid_stun)")
            end
            if not skip_stun then
                local min_cp = (m.pvp_kidney_min_cp and m.pvp_kidney_min_cp.get and m.pvp_kidney_min_cp:get()) or 5
                if cp >= min_cp and local_player:get_power(enums.power_type.ENERGY) >= 25 then
                    local min_mult = dr_min_mult(helpers)
                    local immune = pvp_helper and pvp_helper.is_cc_immune and pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.STUN, 1000)
                    if not immune and dr_allows(target, pvp_helper.cc_flags.STUN, min_mult) then
                        if helpers:try_cast_finisher(local_player, target, "kidney_shot") then
                            pvp_log("cc.kidney", 0, string.format("[PVP][CC] Kidney Shot at %dcp on %s", cp, safe_name(target)))
                            -- Track for CC-chain sequencing
                            cc_chain_state.last_kidney_time = core.time()
                            local ok_guid, guid = pcall(function() return target:get_guid() end)
                            cc_chain_state.last_kidney_target_guid = ok_guid and guid or nil
                            -- Trinket tracker: record KS application
                            if m and m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
                                pvp_trinket_tracker:on_cc_applied(target, "kidney_shot", cp, core.time())
                            end
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Conservative Blind (peel/reset), DR-aware and HP-gated.
    if m and m.pvp_use_blind and m.pvp_use_blind.get_state and m.pvp_use_blind:get_state() == true then
        local hp = local_player:get_health_percentage()
        local hp_th = (m.pvp_blind_hp_threshold and m.pvp_blind_hp_threshold.get and m.pvp_blind_hp_threshold:get()) or 25
        if hp <= hp_th and local_player:get_power(enums.power_type.ENERGY) >= 30 then
            local min_mult = dr_min_mult(helpers)
            local immune = pvp_helper and pvp_helper.is_cc_immune and pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.DISORIENT, 1000)
            if not immune and dr_allows(target, pvp_helper.cc_flags.DISORIENT, min_mult) then
                -- CP dump before Blind for maximum value
                if helpers:dump_combo_points_before_blind(local_player, target) then
                    return true -- Wait for GCD, Blind next frame
                end
                if helpers:try_cast_cc(local_player, target, "blind") then
                    pvp_log("cc.blind_def", 0, string.format("[PVP][CC] Blind defensive (hp=%.0f%%) on %s", hp, safe_name(target)))
                    -- Track Blind for trinket detection
                    if m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
                        pvp_trinket_tracker:on_cc_applied(target, "blind", 0, core.time())
                    end
                    return true
                end
            end
        end
    end

    -- OFFENSIVE BLIND on Focus/Healer (create kill window on DPS target)
    if m and m.pvp_offensive_blind and m.pvp_offensive_blind.get_state and m.pvp_offensive_blind:get_state() == true then
        if helpers:is_cooldowns_toggle_active() and local_player:get_power(enums.power_type.ENERGY) >= 30 then
            local ok_focus, focus = pcall(function() return core.input.get_focus() end)
            if ok_focus and focus and (not __object_safety.same(focus,target)) and is_valid_enemy_player(focus, local_player) then
                local min_mult = dr_min_mult(helpers)
                local ok_immune, immune = pcall(function()
                    return pvp_helper:is_cc_immune(focus, pvp_helper.cc_flags.DISORIENT, 1000)
                end)
                local is_immune_disorient = ok_immune and immune
                if not is_immune_disorient and dr_allows(focus, pvp_helper.cc_flags.DISORIENT, min_mult) then
                    -- CC-chain awareness: Blind after Kidney Shot for maximum CC uptime
                    local cc_chain_ok = true
                    if m.pvp_cc_chain_enabled and m.pvp_cc_chain_enabled.get_state and m.pvp_cc_chain_enabled:get_state() == true then
                        -- Only chain Blind if we recently KS'd the DPS target (within 6s)
                        local now = core.time()
                        local ok_guid, focus_guid = pcall(function() return focus:get_guid() end)
                        -- For offensive Blind on focus: we want to Blind the healer while KS is on the kill target
                        -- So check if we recently KS'd the KILL target (not the focus)
                        local recently_ks = (now - cc_chain_state.last_kidney_time) <= 6000
                        if not recently_ks then
                            cc_chain_ok = false -- Wait for KS on kill target first
                        end
                        -- Suppress unused warning for focus_guid (reserved for future DR tracking)
                        local _ = ok_guid and focus_guid
                    end
                    if not cc_chain_ok then
                        pvp_log("cc.blind_off_wait", 1.0, "[PVP][CC] Offensive Blind waiting for KS chain on kill target")
                    end
                    if cc_chain_ok then
                        if helpers:try_cast_cc(local_player, focus, "blind") then
                            pvp_log("cc.blind_off", 0, "[PVP][CC] Offensive Blind on Focus=" .. safe_name(focus))
                            -- Track Blind on focus for trinket detection
                            if m.pvp_trinket_tracking and m.pvp_trinket_tracking.get_state and m.pvp_trinket_tracking:get_state() == true then
                                pvp_trinket_tracker:on_cc_applied(focus, "blind", 0, core.time())
                            end
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Gouge (CC chain / utility -- beyond interrupt fallback)
    if m and m.pvp_use_gouge and m.pvp_use_gouge.get_state and m.pvp_use_gouge:get_state() == true then
        local gouge_mode = (m.pvp_gouge_mode and m.pvp_gouge_mode.get and m.pvp_gouge_mode:get()) or 1
        if gouge_mode >= 2 then
            local gouge_energy = local_player:get_power(enums.power_type.ENERGY) or 0
            if gouge_energy >= 45 then
                local min_mult = dr_min_mult(helpers)
                local ok_immune, immune = pcall(function()
                    return pvp_helper:is_cc_immune(target, pvp_helper.cc_flags.INCAPACITATE, 1000)
                end)
                local is_immune_incap = ok_immune and immune
                if not is_immune_incap and dr_allows(target, pvp_helper.cc_flags.INCAPACITATE, min_mult) then
                    local should_gouge = false
                    if gouge_mode == 3 then
                        -- Full utility: gouge when low CP to set up re-opener or peel
                        should_gouge = cp <= 2 or (local_player:get_health_percentage() <= 35)
                    elseif gouge_mode == 2 then
                        -- CC chain: gouge to extend a stun chain (low CP, target not currently stunned)
                        local ok_stunned_g, target_stunned = pcall(function() return target:is_stunned(500) end)
                        if not ok_stunned_g then
                            pvp_log("cc.gouge_stun_err", 2.0, "[PVP][CC] Gouge is_stunned() pcall failed, defaulting to not-stunned")
                        end
                        target_stunned = ok_stunned_g and target_stunned or false
                        should_gouge = cp <= 1 and not target_stunned
                    end
                    if should_gouge then
                        if helpers:try_cast_cc(local_player, target, "gouge") then
                            pvp_log("cc.gouge", 0, string.format("[PVP][CC] Gouge (mode=%d, cp=%d) on %s", gouge_mode, cp, safe_name(target)))
                            -- Track Gouge for restealth attempt
                            if m and m.pvp_gouge_restealth and m.pvp_gouge_restealth.get_state and m.pvp_gouge_restealth:get_state() == true then
                                pvp_gouge_restealth:on_gouge_cast(local_player, target, core.time())
                            end
                            return true
                        end
                    end
                end
            end
        end
    end

    -- ===================================================================
    -- PVP COMBAT ROTATION (builders / finishers / cooldowns)
    -- Replaces PvE fallthrough with PvP-appropriate priorities.
    -- ===================================================================

    -- DAMAGE IMMUNITY GATE: If target is fully immune, skip all damage.
    -- Still allow self-buffs (SnD, AR, Cold Blood activation) below.
    if target_is_immune then
        pvp_log("rot.immune_gate", 1.0, "[PVP][ROT] Target immune, self-buff only mode")
        -- Pool energy, maintain self-buffs only
        local energy = local_player:get_power(enums.power_type.ENERGY) or 0
        local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
        local has_ar_buff = helpers:has_buff(local_player, "adrenaline_rush")
        local cooldowns_enabled = helpers:is_cooldowns_toggle_active()

        -- ADRENALINE RUSH (self-buff, fine during immunity)
        if cooldowns_enabled and helpers:is_cooldown_ready("adrenaline_rush") then
            if helpers:try_cast_adrenaline_rush(local_player) then
                pvp_log("rot.ar_immune", 0, "[PVP][ROT] Adrenaline Rush (during immunity)")
                return true
            end
        end

        -- SLICE AND DICE refresh (self-buff, fine during immunity)
        if energy >= 25 then
            if snd_remaining > 0 and snd_remaining <= 1000 and cp >= 1 then
                if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                    pvp_log("rot.snd_immune", 0, string.format("[PVP][ROT] SnD refresh during immunity (remaining=%dms, cp=%d)", snd_remaining, cp))
                    return true
                end
            end
            if snd_remaining <= 3000 and cp >= 2 then
                if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                    pvp_log("rot.snd_immune", 0, string.format("[PVP][ROT] SnD refresh during immunity (remaining=%dms, cp=%d)", snd_remaining, cp))
                    return true
                end
            end
        end

        return true -- Claim frame, do not waste energy on immune target
    end

    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    local target_hp_percent = target:get_health_percentage()
    local snd_remaining = helpers:get_buff_remaining(local_player, "slice_and_dice")
    local has_ar_buff = helpers:has_buff(local_player, "adrenaline_rush")
    local cooldowns_enabled = helpers:is_cooldowns_toggle_active()

    -- COLD BLOOD (PvP: no Elite/Boss gate, just requires Burst toggle + 5CP)
    local cb_available = helpers:is_cooldown_ready("cold_blood")
    local has_cb_buff = helpers:has_buff(local_player, "cold_blood")

    if cooldowns_enabled and cb_available and cp >= 5 and energy >= 35 and not has_cb_buff then
        if helpers:try_cast_cooldown(local_player, "cold_blood") then
            pvp_log("rot.cb", 0, string.format("[PVP][ROT] Cold Blood (%dcp, burst toggle on)", cp))
            return true
        end
    end

    -- Consume Cold Blood with Eviscerate immediately (exception: goes through heavy reduction)
    if has_cb_buff and cp >= 5 and energy >= 35 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            pvp_log("rot.evis_cb", 0, string.format("[PVP][ROT] Eviscerate (Cold Blood) at %dcp", cp))
            return true
        end
    end

    -- ADRENALINE RUSH (PvP: no Elite/Boss or HP% gate, just Burst toggle)
    if cooldowns_enabled and helpers:is_cooldown_ready("adrenaline_rush") then
        if helpers:try_cast_adrenaline_rush(local_player) then
            pvp_log("rot.ar", 0, "[PVP][ROT] Adrenaline Rush activated")
            return true
        end
    end

    -- SLICE AND DICE refresh (pandemic logic -- always allowed, self-buff)
    if energy >= 25 then
        -- SnD not active at all: apply even at 1cp (9s duration better than 0s)
        if snd_remaining == 0 and cp >= 1 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                pvp_log("rot.snd_fresh", 0, string.format("[PVP][ROT] SnD fresh apply (cp=%d)", cp))
                return true
            end
        end
        if snd_remaining > 0 and snd_remaining <= 1000 and cp >= 1 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                pvp_log("rot.snd", 0, string.format("[PVP][ROT] SnD refresh (remaining=%dms, cp=%d)", snd_remaining, cp))
                return true
            end
        end
        if snd_remaining <= 3000 and cp >= 2 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                pvp_log("rot.snd", 0, string.format("[PVP][ROT] SnD refresh (remaining=%dms, cp=%d)", snd_remaining, cp))
                return true
            end
        end
    end

    -- PVP RUPTURE: Bleed for armor-heavy targets, anti-bandage, anti-restealth
    if m and m.pvp_use_rupture and m.pvp_use_rupture.get_state and m.pvp_use_rupture:get_state() == true then
        if energy >= 25 and not target_heavy_reduction then
            local rupture_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.rupture)
            if not rupture_active then
                local ok_class, target_class = pcall(function() return target:get_class() end)
                if ok_class and target_class and RUPTURE_PRIORITY_CLASSES[target_class] then
                    -- Class awareness: lower CP threshold for anti-restealth and bleed-priority targets
                    local class_aware = m.pvp_class_awareness and m.pvp_class_awareness.get_state and m.pvp_class_awareness:get_state() == true
                    local adj = class_aware and get_class_adjustments(target) or {}
                    local min_rupture_cp = 3
                    if adj.prevent_restealth then
                        min_rupture_cp = 2 -- Urgent: prevent Rogue/Druid restealth with lower CP Rupture
                    end
                    if cp >= min_rupture_cp then
                        if helpers:try_cast_finisher(local_player, target, "rupture") then
                            pvp_log("rot.rupture", 0, string.format("[PVP][ROT] Rupture at %dcp on %s (anti-restealth=%s)", cp, safe_name(target), tostring(adj.prevent_restealth or false)))
                            return true
                        end
                    end
                end
            end
        end
    end

    -- HEAVY DAMAGE REDUCTION GATE: Hold burst finishers, still allow builders + maintenance
    if target_heavy_reduction then
        pvp_log("rot.dmg_red_gate", 1.0, "[PVP][ROT] Heavy dmg reduction, skipping burst finishers")
        -- Skip Eviscerate (waste of CP into damage reduction)
        -- Continue to builders below to build CP for when reduction drops
    else
        -- Class-awareness: prefer_bleeds redirects 5CP Evis to Rupture (vs Warriors)
        local class_aware_fin = m and m.pvp_class_awareness and m.pvp_class_awareness.get_state and m.pvp_class_awareness:get_state() == true
        local adj_fin = class_aware_fin and get_class_adjustments(target) or {}

        -- track_immunity: hold finishers on Paladin/Mage above 30% HP (avoid wasting into Bubble/Block)
        local hold_finisher = false
        if adj_fin.track_immunity and target_hp_percent > 30 and cp >= 5 and not has_cb_buff then
            if not cooldowns_enabled then
                hold_finisher = true -- Pool CPs, wait for target to drop or burst toggle
            end
        end

        if hold_finisher then
            pvp_log("rot.hold_fin", 1.0, string.format("[PVP][ROT] Holding finisher (track_immunity, hp=%.0f%%, cp=%d)", target_hp_percent, cp))
        end
        if not hold_finisher then
            -- EVISCERATE at 5 CP (or 3+ at <20% HP for execute)
            if energy >= 35 then
                if cp >= 5 then
                    -- prefer_bleeds: Rupture instead of Evis on Warriors (ignores armor, no Second Wind proc)
                    if adj_fin.prefer_bleeds and not has_cb_buff then
                        local rupture_up = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.rupture)
                        if not rupture_up then
                            if helpers:try_cast_finisher(local_player, target, "rupture") then
                                pvp_log("rot.rupture_bleed", 0, string.format("[PVP][ROT] Rupture (prefer_bleeds) at %dcp on %s", cp, safe_name(target)))
                                return true
                            end
                        end
                    end
                    -- Envenom: if Deadly Poison active on target, Envenom > Eviscerate
                    if spell_data.finishers and spell_data.finishers.envenom then
                        local dp_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.deadly_poison)
                        if dp_active then
                            if helpers:try_cast_finisher(local_player, target, "envenom") then
                                pvp_log("rot.envenom", 0, string.format("[PVP][ROT] Envenom at %dcp (DP active)", cp))
                                return true
                            end
                        end
                    end
                    if helpers:try_cast_finisher(local_player, target, "eviscerate") then
                        pvp_log("rot.evis", 0, string.format("[PVP][ROT] Eviscerate at %dcp", cp))
                        return true
                    end
                end
                -- PvP kill window: 4cp at <35% HP (don't wait for 5cp, target may escape)
                if cp >= 4 and target_hp_percent < 35 then
                    if spell_data.finishers and spell_data.finishers.envenom then
                        local dp_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.deadly_poison)
                        if dp_active then
                            if helpers:try_cast_finisher(local_player, target, "envenom") then
                                pvp_log("rot.envenom_kill", 0, string.format("[PVP][ROT] Envenom kill window at %dcp (hp<35%%)", cp))
                                return true
                            end
                        end
                    end
                    if helpers:try_cast_finisher(local_player, target, "eviscerate") then
                        pvp_log("rot.evis_kill", 0, string.format("[PVP][ROT] Eviscerate kill window at %dcp (hp<35%%)", cp))
                        return true
                    end
                end
                if cp >= 3 and target_hp_percent < 20 then
                    -- Envenom execute path
                    if spell_data.finishers and spell_data.finishers.envenom then
                        local dp_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.deadly_poison)
                        if dp_active then
                            if helpers:try_cast_finisher(local_player, target, "envenom") then
                                pvp_log("rot.envenom_exec", 0, string.format("[PVP][ROT] Envenom execute at %dcp (hp<20%%)", cp))
                                return true
                            end
                        end
                    end
                    if helpers:try_cast_finisher(local_player, target, "eviscerate") then
                        pvp_log("rot.evis_exec", 0, string.format("[PVP][ROT] Eviscerate execute at %dcp (hp<20%%)", cp))
                        return true
                    end
                end
            end
        end
    end

    -- PVP SHIV: Apply missing poison debuffs (Wound / Crippling / Mind-Numbing) -- costs 20 energy, generates 1 CP
    if m and m.pvp_use_shiv and m.pvp_use_shiv.get_state and m.pvp_use_shiv:get_state() == true then
        if energy >= 20 and cp <= 4 then
            local needs_wound = not has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.wound_poison)
            local needs_crippling = not has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.crippling_poison)
            -- Mind-Numbing Poison: slow cast speed on casters (mana users)
            local needs_mind_numbing = false
            if not needs_wound and not needs_crippling then
                local ok_mana, mana_max = pcall(function() return target:get_max_power(0) end)
                if ok_mana and type(mana_max) == "number" and mana_max > 0 then
                    needs_mind_numbing = not has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.mind_numbing_poison)
                end
            end
            if needs_wound or needs_crippling or needs_mind_numbing then
                if helpers:try_cast_builder(local_player, target, "shiv") then
                    pvp_log("rot.shiv", 0, string.format("[PVP][ROT] Shiv (wound=%s crip=%s mn=%s)", tostring(needs_wound), tostring(needs_crippling), tostring(needs_mind_numbing)))
                    return true
                end
            end
        end
    end

    -- PVP BUILDERS (Hemorrhage-first priority for Subtlety PvP)
    local should_pool = energy >= 90 and energy < 95 and cp >= 4 and not has_ar_buff
    if should_pool then
        pvp_log("build.pool", 0.5, string.format("[PVP][BUILD] Pooling (e=%d, cp=%d)", energy, cp))
    end
    if not should_pool then
        -- Energy reserve for Kick: raise builder thresholds by 25 when an interruptible cast is detected
        local kick_reserve = 0
        if m and m.pvp_pool_for_kick and m.pvp_pool_for_kick.get_state and m.pvp_pool_for_kick:get_state() == true then
            local needs_kick = false
            -- Check target for interruptible cast
            if target:is_casting_spell() and target:is_active_spell_interruptable() then
                needs_kick = true
            end
            -- Check focus for interruptible cast
            if not needs_kick then
                local ok_focus, focus = pcall(function() return core.input.get_focus() end)
                if ok_focus and focus and is_valid_enemy_player(focus, local_player) then
                    local ok_cast, is_casting = pcall(function()
                        return focus:is_casting_spell() and focus:is_active_spell_interruptable()
                    end)
                    if ok_cast and is_casting then
                        needs_kick = true
                    end
                end
            end
            if needs_kick then
                -- Only reserve energy when a cast is progressing (past 40%) to avoid
                -- long "does nothing" gaps when focus healer chain-casts short spells.
                local cast_pct = 0
                local ok_pct, pct = pcall(function()
                    if target:is_casting_spell() and target:is_active_spell_interruptable() then
                        return target:get_cast_pct()
                    end
                    return 0
                end)
                if ok_pct and type(pct) == "number" and pct >= 40 then
                    cast_pct = pct
                end
                if cast_pct < 40 then
                    local ok_fp, fp = pcall(function()
                        local f = core.input.get_focus()
                        if f and f:is_casting_spell() and f:is_active_spell_interruptable() then
                            return f:get_cast_pct()
                        end
                        return 0
                    end)
                    if ok_fp and type(fp) == "number" and fp >= 40 then
                        cast_pct = fp
                    end
                end
                if cast_pct >= 40 then
                    kick_reserve = 15
                    pvp_log("build.kick_res", 1.0, string.format("[PVP][BUILD] Kick reserve +15 (cast at %d%%)", cast_pct))
                end
            end
        end

        local hemo_threshold = (has_ar_buff and 25 or 35) + kick_reserve
        local bs_threshold = (has_ar_buff and 40 or 60) + kick_reserve
        local ss_threshold = (has_ar_buff and 25 or 45) + kick_reserve

        -- Check if Hemorrhage debuff is already active on target
        local hemo_debuff_active = has_any_debuff(target, spell_data.debuffs and spell_data.debuffs.hemorrhage)

        -- PRIORITY 1: Hemorrhage (if debuff NOT active - apply/refresh it)
        if not hemo_debuff_active and energy >= hemo_threshold then
            if helpers:try_cast_builder(local_player, target, "hemorrhage") then
                pvp_log("build.hemo_p1", 0.35, string.format("[PVP][BUILD] Hemo P1 (debuff missing, e=%d, cp=%d)", energy, cp))
                return true
            end
        end

        -- PRIORITY 2: Backstab (opportunistic - only if behind AND hemo debuff already up)
        if hemo_debuff_active and energy >= bs_threshold then
            if helpers:try_cast_builder(local_player, target, "backstab") then
                pvp_log("build.bs_p2", 0.35, string.format("[PVP][BUILD] BS P2 (hemo up, behind, e=%d, cp=%d)", energy, cp))
                return true
            end
        end

        -- PRIORITY 3: Hemorrhage (even if debuff active - still the best PvP builder)
        if hemo_debuff_active and energy >= hemo_threshold then
            if helpers:try_cast_builder(local_player, target, "hemorrhage") then
                pvp_log("build.hemo_p3", 0.35, string.format("[PVP][BUILD] Hemo P3 (debuff active, e=%d, cp=%d)", energy, cp))
                return true
            end
        end

        -- PRIORITY 4: Sinister Strike fallback (if Hemorrhage not learned)
        if energy >= ss_threshold then
            if helpers:try_cast_builder(local_player, target, "sinister_strike") then
                pvp_log("build.ss_p4", 0.35, string.format("[PVP][BUILD] SS P4 fallback (e=%d, cp=%d)", energy, cp))
                return true
            end
        end
    end

    -- =========================================================================
    -- FAILSAFE: If we are in combat on a valid melee target but haven't queued
    -- any spell for a while, force a basic action (prevents "auto-attack only"
    -- stalls in open world PvP / engine edge cases).
    -- =========================================================================
    do
        local now_fs = core.time()
        local lastq = (helpers and helpers._last_spell_queued_time) or 0.0
        local since = now_fs - lastq

        local ok_combat, in_combat = pcall(function()
            return local_player:affecting_combat()
        end)

        if ok_combat and in_combat and since > 1.5 then
            if not helpers:is_in_stealth(local_player) and not pvp_reset_cycle:is_active() and not pvp_gouge_restealth:is_active() then
                local ok_dist, dist = pcall(function() return target:distance() end)
                if ok_dist and type(dist) == "number" and dist <= 5.5 then
                    local ok_gcd, gcd = pcall(function() return local_player:gcd_remains() end)
                    if not ok_gcd or type(gcd) ~= "number" then gcd = 0 end

                    local ok_casting, is_casting = pcall(function() return local_player:is_channeling_or_casting() end)
                    if gcd <= 0 and not (ok_casting and is_casting) then
                        local ok_pos, tpos = pcall(function() return target:get_position() end)
                        if ok_pos and tpos then
                            pcall(function() core.input.look_at(tpos) end)
                        end

                        local did = false
                        if cp >= 4 and energy >= 35 then
                            did = helpers:try_cast_finisher(local_player, target, "eviscerate") == true
                        end
                        if not did and energy >= 35 then
                            did = helpers:try_cast_builder(local_player, target, "hemorrhage") == true
                                or helpers:try_cast_builder(local_player, target, "sinister_strike") == true
                        end

                        if did then
                            pvp_log("failsafe.action", 0.5, string.format("[PVP][FAILSAFE] Forced action after %.1fs idle (cp=%d e=%d)", since, cp, energy))
                            return true
                        end
                    end
                end
            end
        end
    end

    pvp_log("exec.claim", 1.0, string.format("[PVP] Frame claimed, no action (e=%d, cp=%d, hp=%.0f%%)", energy, cp, target_hp_percent))
    do
        if energy >= 35 then
            local ok_dist, dist = pcall(function() return target:distance() end)
            local ok_gcd, gcd = pcall(function() return local_player:gcd_remains() end)
            local ok_cast, casting = pcall(function() return local_player:is_channeling_or_casting() end)
            local queued_n = -1
            local ok_snap, snap = pcall(function() return spell_queue:get_queue_snapshot() end)
            if ok_snap and type(snap) == "table" then
                queued_n = #snap
            end
            pvp_log(
                "diag.no_action",
                1.0,
                string.format(
                    "[PVP][DIAG] No action (dist=%.1f gcd=%.2f casting=%s queued=%d lastq=%.1fs)",
                    (ok_dist and type(dist) == "number" and dist) or -1,
                    (ok_gcd and type(gcd) == "number" and gcd) or -1,
                    tostring(ok_cast and casting),
                    queued_n,
                    (core.time() - ((helpers and helpers._last_spell_queued_time) or 0.0))
                )
            )
        end
    end
    -- Claim frame in PvP mode (prevents PvE fallthrough with wrong priorities)
    return true
end

return pvp
