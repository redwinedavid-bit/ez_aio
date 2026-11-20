local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock PvP Module (TBC) - SL/SL ONLY
-- Complete rewrite: practical Arena/BG APL with heavy logging hooks.
--
-- Notes / constraints (Project Sylvanas API):
-- - We can cast spells, use items, manage pet + focus, track DR/CC, and render overlays.
-- - We cannot "bind every spell on your keyboard"; we can only expose in-script keybind
--   toggles and act while they are held/toggled.
-- - We cannot guarantee pillar play / LOS micro or human-like fake casts.
-- ============================================================================

local pvp = {}

---@type izi_sdk
local izi = require("common/izi_sdk")
---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")
---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")
---@type inventory_helper
local inventory_helper = require("common/utility/inventory_helper")
---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

local spells = require("rotations/warlock/tbc/spells")
local dr_helper = require("shared/dr_helper")
local dot_apply_guard = require("shared/dot_apply_guard")

local pet_controller = require("rotations/warlock/tbc/pvp/pet_controller")
local trinket_tracker = require("rotations/warlock/tbc/pvp/trinket_tracker")
local lockout_tracker = require("rotations/warlock/tbc/pvp/lockout_tracker")

-- PvP Trinket / Spellstone items (Warlock-specific + common epic variants)
local pvp_trinket_item = izi.item({ 30343, 30348, 37865, 37864 }) -- Medallion of the Horde/Alliance (Warlock) + epic upgrades
local SPELLSTONE_IDS = { 22646, 13603, 13602, 5522 }             -- Master/Major/Greater/Spellstone
local spellstone_item = izi.item(SPELLSTONE_IDS)
local spellstone_item_by_id = {}

-- Healthstone ITEM IDs (highest rank first) -- includes Improved Healthstone variants
local HEALTHSTONE_IDS = {
    22103, 22104, 22105, -- Master Healthstone (base, imp1, imp2)
    9421, 19012, 19013, -- Major Healthstone
    5510, 19010, 19011, -- Greater Healthstone
    5509, 19008, 19009, -- Healthstone
    5511, 19006, 19007, -- Lesser Healthstone
    5512, 19004, 19005, -- Minor Healthstone
}

local healthstone_item = izi.item(HEALTHSTONE_IDS)
local healthstone_item_by_id = {}

-- Bag cache (for reliable item existence checks; avoids item API false positives)
local bag_cache = {
    last_update_ms = 0,
    ids = {},   -- [item_id]=true
    counts = {}, -- [item_id]=count
}

local function update_bag_cache(interval_ms)
    interval_ms = interval_ms or 1500
    local now = core.game_time()
    if (now - (bag_cache.last_update_ms or 0)) < interval_ms then
        return
    end
    bag_cache.last_update_ms = now
    bag_cache.ids = {}
    bag_cache.counts = {}

    local ok, slots = pcall(function() return inventory_helper:get_character_bag_slots() end)
    if not ok or type(slots) ~= "table" then
        return
    end

    for _, slot in ipairs(slots) do
        local item = slot and slot.item
        if item and item.get_item_id then
            local ok_id, item_id = pcall(function() return item:get_item_id() end)
            local id = ok_id and tonumber(item_id) or nil
            if id and id > 0 then
                bag_cache.ids[id] = true
                local c = tonumber(slot.stack_count) or 1
                bag_cache.counts[id] = (bag_cache.counts[id] or 0) + math.max(1, c)
            end
        end
    end
end

local function has_item_id_in_bags(item_id)
    if not item_id or item_id <= 0 then return false end
    return bag_cache.ids[item_id] == true
end

local function best_healthstone_id_in_bags()
    for _, id in ipairs(HEALTHSTONE_IDS) do
        if has_item_id_in_bags(id) then
            return id
        end
    end
    return nil
end

local function get_healthstone_item_from_bags()
    local id = best_healthstone_id_in_bags()
    if not id then return nil end
    if not healthstone_item_by_id[id] then
        healthstone_item_by_id[id] = izi.item(id)
    end
    return healthstone_item_by_id[id]
end

local function best_spellstone_id_in_bags()
    for _, id in ipairs(SPELLSTONE_IDS) do
        if has_item_id_in_bags(id) then
            return id
        end
    end
    return nil
end

local function get_spellstone_item_from_bags()
    local id = best_spellstone_id_in_bags()
    if not id then return nil end
    if not spellstone_item_by_id[id] then
        spellstone_item_by_id[id] = izi.item(id)
    end
    return spellstone_item_by_id[id]
end

-- Soul Link: aura id(s) are not always equal to cast id. Keep a list + pet check.
local SOUL_LINK_BUFFS = { 19028, 25228 }
local last_soul_link_attempt_ms = 0
local SOUL_LINK_THROTTLE_MS = 2000
local soul_link_assumed_until_ms = 0

-- Throttles
local last_cc_attempt_ms = 0
local CC_ATTEMPT_THROTTLE_MS = 1200
local last_focus_set_ms = 0
local FOCUS_SET_THROTTLE_MS = 3000
local last_target_set_ms = 0
local TARGET_SET_THROTTLE_MS = 1500

-- When aura cache is unreliable (common in PvP), we keep a short "assumed applied" window after a successful cast
-- to avoid re-casting the same curse/DoT endlessly.
local assumed_debuff_until_ms = {} -- [spell_id][target_guid]=until_ms

-- DoT guard (prevents double-casts when aura cache is late)
local dot_guard = dot_apply_guard.new({ default_grace_ms = 250 })

-- Pet attack ordering (pet_attack is off-GCD; don't spam it every frame)
local last_pet_attack_order_ms = 0
local PET_ATTACK_ORDER_THROTTLE_MS = 900

-- Amplify Curse timing (avoid GCD waste / loops)
local last_amplify_curse_ms = 0
local AMPLIFY_CURSE_THROTTLE_MS = 2000
local recent_dot_cast_ms = {} -- [spell_id][guid] = last_ms
local last_team_buff_ms = {}  -- [spell_id][guid] = last_ms
local last_item_request_ms = {} -- [item_id]=last_ms (blocks repeated queue spam)

-- Internal init gates
local initialized = false
local last_menu_ref = nil

-- ============================================================================
-- Logging (throttled + gated by menu toggles)
-- ============================================================================

local log_last = {}
local function log_enabled()
    return last_menu_ref and last_menu_ref.pvp_debug_logging and last_menu_ref.pvp_debug_logging:get_state() == true
end

local function vlog_enabled()
    return log_enabled()
        and last_menu_ref.pvp_debug_verbose
        and last_menu_ref.pvp_debug_verbose:get_state() == true
end

local function log_throttled(key, every_s, msg)
    if not log_enabled() then return end
    if last_menu_ref and last_menu_ref.pvp_ooc_prep_logs and last_menu_ref.pvp_ooc_prep_logs.get_state then
        -- Allow disabling noisy out-of-combat prep warnings (shards/stone creation).
        if key:find("^prep%.", 1, false) ~= nil and last_menu_ref.pvp_ooc_prep_logs:get_state() ~= true then
            return
        end
    end
    local now = core.time()
    local last = log_last[key] or 0
    if every_s and every_s > 0 and (now - last) < every_s then return end
    log_last[key] = now
    core.log(msg)
end

local function vlog(key, every_s, msg)
    if not vlog_enabled() then return end
    log_throttled(key, every_s, msg)
end

local function safe_name(unit)
    if not unit or not unit.get_name then return "nil" end
    return unit:get_name() or "unknown"
end

local function hp_pct(unit)
    if not unit or not unit.get_health_percentage then return 0 end
    return tonumber(unit:get_health_percentage()) or 0
end

local function mana_pct(unit)
    if not unit or not unit.mana_pct then return 0 end
    return tonumber(unit:mana_pct()) or 0
end

local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then return fallback end
    local ok, v = pcall(function() return menu[key]:get_state() end)
    if ok then return v end
    return fallback
end

local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then return fallback end
    local ok, v = pcall(function() return menu[key]:get() end)
    return ok and (tonumber(v) or fallback) or fallback
end

local function item_cooldown_s(item)
    if not item then return 0 end
    if item.cooldown_remains then
        local ok, v = pcall(function() return item:cooldown_remains() end)
        return ok and (tonumber(v) or 0) or 0
    end
    if item.cooldown then
        local ok, v = pcall(function() return item:cooldown() end)
        return ok and (tonumber(v) or 0) or 0
    end
    return 0
end

local function item_in_bags(item)
    if not item or not item.in_inventory then return false end
    local ok, v = pcall(function() return item:in_inventory() end)
    return ok and v == true
end

local function use_item_self_best_effort(item, player, message)
    if not item then return false end
    local item_id = nil
    pcall(function()
        if item.id then item_id = item:id() end
    end)
    if item_id and item_id > 0 then
        local last = last_item_request_ms[item_id] or 0
        -- Default spam guard: prevent re-queuing the same item too fast (client can accept queue multiple times).
        if (core.game_time() - last) < 1500 then
            return false
        end
        last_item_request_ms[item_id] = core.game_time()
    end

    local ok_used, used = pcall(function()
        if item.use_self then
            -- fast=true to avoid GCD related false negatives for off-GCD items
            if item:use_self(message, true) then return true end
        end
        if item.use then
            if item:use() then return true end
        end
        if item.use_on and player then
            if item:use_on(player, message, true) then return true end
        end
        return false
    end)
    return ok_used and used == true
end

local function get_teammates(max_range)
    local res = {}
    local me = core.object_manager.get_local_player()
    if me and me.is_valid and me:is_valid() then
        res[#res + 1] = me
    end
    local party = nil
    pcall(function()
        if izi.party then party = izi.party(max_range or 40) end
    end)
    if type(party) == "table" then
        for _, u in __object_safety.live_ipairs(party) do
            if u and u.is_valid and u:is_valid() then
                res[#res + 1] = u
            end
        end
    end
    return res
end

local function guid_key(unit)
    if not unit or not unit.get_guid then return nil end
    local ok, g = pcall(function() return unit:get_guid() end)
    return ok and g and tostring(g) or nil
end

local function team_buff_throttle_ok(spell_id, unit, interval_ms)
    if not spell_id or spell_id <= 0 then return false end
    local g = guid_key(unit)
    if not g then return false end
    local per_spell = last_team_buff_ms[spell_id]
    if not per_spell then
        per_spell = {}
        last_team_buff_ms[spell_id] = per_spell
    end
    local last_ms = per_spell[g] or 0
    if (core.game_time() - last_ms) < (interval_ms or 2000) then
        return false
    end
    per_spell[g] = core.game_time()
    return true
end

local function try_maintain_detect_invisibility(player, menu)
    if not menu_enabled(menu, "pvp_team_detect_invis", true) then return false end
    if not spells.detect_invisibility or spells.detect_invisibility:is_learned() ~= true then return false end
    if spells.detect_invisibility:is_castable() ~= true then return false end

    local in_combat = player:is_in_combat() == true
    if in_combat and menu_enabled(menu, "pvp_team_detect_invis_in_combat", false) ~= true then
        return false
    end
    if player:is_moving() or player:is_channeling_or_casting() then return false end

    local spell_id = spells.detect_invisibility:id()
    for _, u in __object_safety.live_ipairs(get_teammates(40)) do
        if u and u.buff_down and u:buff_down(spell_id) then
            if team_buff_throttle_ok(spell_id, u, 3000) then
                log_throttled("prep.detect_invis", 0, string.format("[Warlock][PvP][Prep] Detect Invisibility on %s", safe_name(u)))
                if spells.detect_invisibility:cast(u, "Detect Invisibility") then
                    return true
                end
            end
        end
    end
    return false
end

local function is_in_arena()
    local ok, v = pcall(function()
        return (izi.is_in_arena and izi.is_in_arena()) or (izi.is_arena and izi.is_arena()) or false
    end)
    return ok and v == true
end

local function in_arena_prep()
    if not is_in_arena() then return false end
    local ok_state, state = pcall(function() return core.game_ui.get_battlefield_state() end)
    return ok_state and state == 2 -- 2 = Prep
end

local function soul_link_is_up(player)
    local now = core.game_time()
    if soul_link_assumed_until_ms > now then return true end
    if player then
        for _, id in ipairs(SOUL_LINK_BUFFS) do
            if player:buff_up(id) then return true end
        end
    end
    local pet = player and player:get_pet()
    if pet and pet:is_valid() and pet:is_alive() then
        for _, id in ipairs(SOUL_LINK_BUFFS) do
            if pet:buff_up(id) then return true end
        end
    end
    return false
end

local function set_focus(unit, why)
    if not core.input or not core.input.set_focus or not unit then return false end
    local now = core.game_time()
    if (now - last_focus_set_ms) < FOCUS_SET_THROTTLE_MS then return false end
    local ok, result = pcall(core.input.set_focus, unit)
    if ok and result then
        last_focus_set_ms = now
        log_throttled("focus.set." .. tostring(why), 0, string.format("[Warlock][PvP][FOCUS] set=%s (%s)", safe_name(unit), tostring(why)))
        return true
    end
    return false
end

local function get_focus()
    if not core.input or not core.input.get_focus then return nil end
    local ok, u = pcall(core.input.get_focus)
    if ok and u and u.is_valid and u:is_valid() then return u end
    return nil
end

-- ============================================================================
-- Target / Focus selection (best-effort)
-- ============================================================================

local CLASS_HEALERS = {
    [2] = true,  -- Paladin
    [5] = true,  -- Priest
    [7] = true,  -- Shaman
    [11] = true, -- Druid
}

local function is_enemy_player(u)
    if not u or not u.is_valid_enemy or not u:is_valid_enemy() or not u:is_alive() then return false end
    local ok, is_player = pcall(function() return pvp_helper:is_player(u) end)
    return ok and is_player == true
end

local function select_kill_target(current_target, enemies, menu)
    if is_enemy_player(current_target) then return current_target end
    if not enemies then return current_target end

    local mode = menu_number(menu, "pvp_target_selector", 1) -- 1=Lowest HP, 2=Closest, 3=Healer first
    local best = nil
    local best_score = -1e9
    local me = core.object_manager.get_local_player()

    for _, e in ipairs(enemies) do
        if is_enemy_player(e) then
            local hp = hp_pct(e)
            local dist = 0
            if me and me.is_valid and me:is_valid() then
                pcall(function() dist = e:distance_to(me) end)
            end
            local class_id = 0
            pcall(function() class_id = e:get_class() end)

            local score = 0
            if mode == 1 then
                score = (100 - hp) * 10 - dist
            elseif mode == 2 then
                score = -dist * 10 + (100 - hp)
            else
                score = (CLASS_HEALERS[class_id] and 10000 or 0) + (100 - hp) * 5 - dist
            end

            if score > best_score then
                best_score = score
                best = e
            end
        end
    end

    return best or current_target
end

local function select_focus_target(enemies, current_target)
    if not enemies then return nil end

    local healer = nil
    local caster = nil
    for _, e in ipairs(enemies) do
        if is_enemy_player(e) then
            local class_id = 0
            pcall(function() class_id = e:get_class() end)
            if CLASS_HEALERS[class_id] then
                healer = healer or e
            elseif caster == nil then
                local mp = mana_pct(e)
                if mp > 0 then caster = e end
            end
        end
    end

    if healer and current_target and healer.get_guid and current_target.get_guid then
        local ok1, g1 = pcall(function() return healer:get_guid() end)
        local ok2, g2 = pcall(function() return current_target:get_guid() end)
        if ok1 and ok2 and g1 == g2 then
            return caster
        end
    end

    return healer or caster
end

local function set_player_target(unit, reason)
    if not core.input or not core.input.set_target then return false end
    if not unit or not unit.is_valid or not unit:is_valid() then return false end
    local now = core.game_time()
    if (now - last_target_set_ms) < TARGET_SET_THROTTLE_MS then return false end
    last_target_set_ms = now
    local ok, r = pcall(core.input.set_target, unit)
    if ok and r == true then
        vlog("target.set", 0.8, string.format("[Warlock][PvP] Target set: %s (%s)", safe_name(unit), tostring(reason or "")))
        return true
    end
    return false
end

local function ensure_pet_attack(player, target)
    if not core.input or not core.input.pet_attack then return end
    if not player or not target or not is_enemy_player(target) then return end

    local pet = nil
    pcall(function() pet = player:get_pet() end)
    if not pet or not pet.is_valid or not pet:is_valid() or not pet.is_alive or not pet:is_alive() then return end

    local now = core.game_time()
    if (now - last_pet_attack_order_ms) < PET_ATTACK_ORDER_THROTTLE_MS then return end
    last_pet_attack_order_ms = now

    pcall(function() core.input.pet_attack(target) end)
end

-- ============================================================================
-- Core actions
-- ============================================================================

-- Auto-creation of Healthstone/Spellstone intentionally removed (user request).

local function try_use_healthstone(player, menu)
    if not menu_enabled(menu, "use_healthstone", true) then return false end
    update_bag_cache()
    local hs_item = get_healthstone_item_from_bags()
    if not hs_item then
        vlog("def.hs.none", 15.0, "[Warlock][PvP][DEF] No Healthstone in bags (skipping)")
        return false
    end

    local hp_threshold = menu_number(menu, "healthstone_hp_pct", 35)
    if hp_pct(player) > hp_threshold then return false end

    -- Hard block repeated HS requests for the duration of the stone CD (2 min) after we queued one.
    if not pvp._last_hs_request_ms then pvp._last_hs_request_ms = 0 end
    local now = core.game_time()
    local HS_BLOCK_MS = 120000
    if (now - pvp._last_hs_request_ms) < HS_BLOCK_MS then
        return false
    end

    if use_item_self_best_effort(hs_item, player, "Healthstone") then
        -- Force a bag refresh soon so we don't re-attempt if the cache lags.
        bag_cache.last_update_ms = 0
        pvp._last_hs_request_ms = now
        log_throttled("def.hs", 0, string.format("[Warlock][PvP][DEF] Healthstone requested at hp=%d%% (<=%d%%)", hp_pct(player), hp_threshold))
        return true
    end
    vlog("def.hs.fail", 1.0, string.format("[Warlock][PvP][DEF] Healthstone wanted but not usable (hp=%d%% thresh=%d%% in_bags=%s cd=%.1fs)",
        hp_pct(player), hp_threshold,
        tostring(item_in_bags(hs_item)),
        item_cooldown_s(hs_item)))
    return false
end

local last_trinket_attempt_ms = 0
local TRINKET_THROTTLE_MS = 1200
local last_spellstone_attempt_ms = 0
local SPELLSTONE_THROTTLE_MS = 1500

local last_off_racial_ms = 0
local OFF_RACIAL_THROTTLE_MS = 20000

local function try_use_spellstone(player, menu)
    if not menu_enabled(menu, "use_spellstone_pvp", true) then return false end
    if not player then return false end

    update_bag_cache()
    local ss_item = get_spellstone_item_from_bags()
    if not ss_item then
        vlog("def.ss.none", 15.0, "[Warlock][PvP][DEF] No Spellstone in bags (skipping)")
        return false
    end

    local now = core.game_time()
    if (now - last_spellstone_attempt_ms) < SPELLSTONE_THROTTLE_MS then return false end

    if not pvp._last_spellstone_request_ms then pvp._last_spellstone_request_ms = 0 end
    local SPELLSTONE_BLOCK_MS = 120000
    if (now - pvp._last_spellstone_request_ms) < SPELLSTONE_BLOCK_MS then
        return false
    end

    -- Optional: allow "low HP" usage even when not silenced (user-configured).
    local hp_gate = menu_number(menu, "pvp_spellstone_hp_pct", 0)
    if hp_gate > 0 and hp_pct(player) <= hp_gate then
        if use_item_self_best_effort(ss_item, player, "Spellstone (low HP)") then
            last_spellstone_attempt_ms = now
            pvp._last_spellstone_request_ms = now
            log_throttled("def.spellstone.hp", 0, string.format("[Warlock][PvP][DEF] Spellstone used at hp=%d%% (<=%d%%)", hp_pct(player), hp_gate))
            return true
        end
    end

    local silenced = false
    pcall(function()
        local cc, _, _ = pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.SILENCE, 50)
        silenced = cc == true
    end)
    if not silenced then return false end

    if use_item_self_best_effort(ss_item, player, "Spellstone") then
        last_spellstone_attempt_ms = now
        pvp._last_spellstone_request_ms = now
        log_throttled("def.spellstone", 0, "[Warlock][PvP][DEF] Spellstone used while silenced")
        return true
    end
    vlog("def.spellstone.fail", 1.0, string.format("[Warlock][PvP][DEF] Spellstone wanted but not usable (equipped=%s in_bags=%s cd=%.1fs)",
        tostring(ss_item:equipped() == true),
        tostring(has_item_id_in_bags(best_spellstone_id_in_bags() or 0)),
        item_cooldown_s(ss_item)))
    return false
end

local function try_offensive_racials(player, kill_target, menu)
    if not menu_enabled(menu, "use_racials_pvp", true) then return false end
    if not player or not kill_target then return false end
    if player:is_channeling_or_casting() then return false end

    local now = core.game_time()
    if (now - last_off_racial_ms) < OFF_RACIAL_THROTTLE_MS then return false end

    local t_hp = hp_pct(kill_target)
    if t_hp > 65 then return false end

    -- Orc / Troll / Blood Elf: use as a generic "execute/burst" helper
    if spells.blood_fury and spells.blood_fury:is_learned() and spells.blood_fury:is_castable() then
        if spells.blood_fury:cast(player, "Blood Fury") then
            last_off_racial_ms = now
            log_throttled("racial.blood_fury", 0, "[Warlock][PvP][Racial] Blood Fury")
            return true
        end
    end

    if spells.berserking and spells.berserking:is_learned() and spells.berserking:is_castable() then
        if spells.berserking:cast(player, "Berserking") then
            last_off_racial_ms = now
            log_throttled("racial.berserking", 0, "[Warlock][PvP][Racial] Berserking")
            return true
        end
    end

    if spells.arcane_torrent and spells.arcane_torrent:is_learned() and spells.arcane_torrent:is_castable() then
        if mana_pct(player) < 60 then
            if spells.arcane_torrent:cast(player, "Arcane Torrent") then
                last_off_racial_ms = now
                log_throttled("racial.arcane_torrent", 0, "[Warlock][PvP][Racial] Arcane Torrent")
                return true
            end
        end
    end

    return false
end

local function try_break_cc(player, menu)
    if not menu_enabled(menu, "use_pvp_trinket", true) then return false end
    if not player then return false end

    local is_cc, remaining_ms = false, 0
    pcall(function()
        local cc, _, rem = pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.ANY_BUT_SLOW, 50)
        is_cc = cc == true
        remaining_ms = tonumber(rem) or 0
    end)
    if is_cc ~= true then return false end

    local hp_gate = menu_number(menu, "pvp_trinket_hp_pct", 30)
    local require_damage = menu_enabled(menu, "pvp_trinket_require_damage", true)
    local ignore_hp_for_hard_cc = menu_enabled(menu, "pvp_trinket_always_hard_cc", false)

    if ignore_hp_for_hard_cc ~= true and hp_pct(player) > hp_gate then
        return false
    end

    if require_damage then
        local incoming = 0
        pcall(function()
            incoming = tonumber(player:get_incoming_damage(0.8)) or 0
        end)
        if incoming <= 0 then
            vlog("def.trinket.guard.no_dmg", 1.0, "[Warlock][PvP][DEF] Trinket blocked (no incoming damage predicted)")
            return false
        end
    end

    local now = core.game_time()
    if (now - last_trinket_attempt_ms) < TRINKET_THROTTLE_MS then return false end

    -- 1) Racials first (when possible)
    if menu_enabled(menu, "use_racials_pvp", true) then
        local is_fear = false
        pcall(function()
            is_fear = pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.FEAR, 50) == true
        end)
        if is_fear and spells.will_of_the_forsaken and spells.will_of_the_forsaken:is_learned() and spells.will_of_the_forsaken:is_castable() then
            if spells.will_of_the_forsaken:cast(player, "WotF") then
                last_trinket_attempt_ms = now
                log_throttled("def.wotf", 0, "[Warlock][PvP][DEF] Used Will of the Forsaken to break Fear")
                return true
            end
        end

        if spells.escape_artist and spells.escape_artist:is_learned() and spells.escape_artist:is_castable() then
            local rooted = false
            pcall(function()
                rooted = pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.ROOT, 50) == true
            end)
            if rooted and spells.escape_artist:cast(player, "Escape Artist") then
                last_trinket_attempt_ms = now
                log_throttled("def.escape", 0, "[Warlock][PvP][DEF] Used Escape Artist to break Root")
                return true
            end
        end
    end

    -- 2) PvP trinket
    if pvp_trinket_item then
        local ok_usable, usable = pcall(function() return pvp_trinket_item:is_usable() end)
        if ok_usable and usable then
            local ok_use, used = pcall(function() return pvp_trinket_item:use() end)
            if ok_use and used then
                last_trinket_attempt_ms = now
                log_throttled("def.trinket", 0, string.format("[Warlock][PvP][DEF] PvP Trinket used (cc_remaining=%dms)", tonumber(remaining_ms) or 0))
                return true
            end
        end
    end

    return false
end

local function try_soul_link(player, menu)
    if not menu_enabled(menu, "use_soul_link", true) then return false end
    if not spells.soul_link or not spells.soul_link:is_learned() then return false end
    if soul_link_is_up(player) then return false end
    if player:is_moving() or player:is_channeling_or_casting() then return false end
    if not spells.soul_link:is_castable() then return false end

    -- Soul Link requires an active pet. Do not waste GCD / queue attempts without one.
    local pet = nil
    pcall(function() pet = player:get_pet() end)
    if not pet or not pet.is_valid or not pet:is_valid() or not pet.is_alive or pet:is_alive() ~= true then
        vlog("maint.soullink.nopet", 10.0, "[Warlock][PvP][MAINT] Soul Link skipped (no pet)")
        return false
    end

    local now = core.game_time()
    if (now - last_soul_link_attempt_ms) < SOUL_LINK_THROTTLE_MS then return false end
    last_soul_link_attempt_ms = now

    local ok = spells.soul_link:cast(player, "Soul Link")
    if ok == true then
        -- Aura cache can lag in PvP; keep a short assumed window to prevent spam re-casts.
        soul_link_assumed_until_ms = now + 8000
        log_throttled("maint.soullink", 0, "[Warlock][PvP][MAINT] Soul Link cast")
        return true
    end
    vlog("maint.soullink.fail", 1.0, "[Warlock][PvP][MAINT] Soul Link cast failed (not queued)")
    return false
end

local function is_wanding_active(player)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then return false end
    if not player then return false end
    local ok, v = pcall(function()
        return auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND) == true
    end)
    return ok and v == true
end

local function stop_wand_if_active(player, target)
    if not auto_attack_helper or not auto_attack_helper.stop_attack then return end
    if not player or not target then return end
    if not is_wanding_active(player) then return end
    pcall(function() auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) end)
end

local function try_wand_filler(player, target, menu, force)
    if not menu_enabled(menu, "use_wand", true) then return false end
    if not auto_attack_helper or not auto_attack_helper.start_attack then return false end
    if not player or not target or not is_enemy_player(target) then return false end
    if player:is_moving() or player:is_channeling_or_casting() then return false end
    if is_wanding_active(player) then return false end

    local wand_gate = menu_number(menu, "pvp_wand_max_mana_pct", 25)
    if force ~= true and mana_pct(player) > wand_gate then
        return false
    end

    local ok, r = pcall(function()
        return auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) == true
    end)
    if ok and r then
        vlog("wand.start", 1.5, string.format("[Warlock][PvP] Wand filler on %s", safe_name(target)))
        return true
    end
    return false
end

local function needs_debuff_refresh(target, spell, pandemic_ms)
    if not target or not spell then return false end
    -- IMPORTANT (PvP): some clients report debuff aura IDs that differ from the cast ID.
    -- To make this reliable, match against all known ranks/IDs from the spell wrapper.
    local ids = nil
    if type(spell) == "table" and type(spell.ids) == "table" then
        ids = spell.ids
    else
        local ok_id, id = pcall(function() return spell:id() end)
        if ok_id and id and id > 0 then
            ids = { id }
        end
    end
    if not ids or #ids == 0 then return false end

    -- Preferred path: use aura_spec table directly (SDK supports "single spell ID or table of spell IDs").
    do
        local ok_down, is_down = pcall(function() return target:debuff_down(ids) end)
        if ok_down then
            if is_down == true then return true end
            if not pandemic_ms or pandemic_ms <= 0 then return false end
            local ok_rem, rem = pcall(function() return target:debuff_remains_ms(ids) end)
            if ok_rem and rem then
                return rem > 0 and rem < pandemic_ms
            end
            -- If remains query fails, fall through to snapshot scan.
        end
    end

    local wanted = {}
    for _, id in ipairs(ids) do
        if type(id) == "number" and id > 0 then
            wanted[id] = true
        end
    end

    local ok_all, debuffs = pcall(function() return target:get_all_debuffs() end)
    if not ok_all or type(debuffs) ~= "table" then
        -- Fallback: best-effort check each id directly.
        local any_up = false
        for id, _ in pairs(wanted) do
            local ok_up, up = pcall(function() return target:debuff_up(id) end)
            if ok_up and up == true then
                any_up = true
                -- If we can't read remains, assume it's fine (avoid spam).
                if not pandemic_ms or pandemic_ms <= 0 then return false end
                local ok_rem, rem = pcall(function() return target:debuff_remains_ms(id) end)
                return ok_rem and rem and rem > 0 and rem < pandemic_ms or false
            end
        end
        return any_up == false
    end

    local found_id = nil
    local function scan_entry(entry)
        if found_id then return end
        local t = type(entry)
        local did = nil
        if t == "number" then
            did = tonumber(entry)
        elseif t == "table" then
            did = tonumber(entry.spell_id or entry.buff_id or entry.id or entry.aura_id or entry.spellId)
        end
        if did and wanted[did] then
            found_id = did
        end
    end

    for _, entry in ipairs(debuffs) do
        scan_entry(entry)
        if found_id then break end
    end
    if not found_id then
        for _, entry in pairs(debuffs) do
            scan_entry(entry)
            if found_id then break end
        end
    end

    if not found_id then
        return true
    end

    if not pandemic_ms or pandemic_ms <= 0 then
        return false
    end

    local ok_rem, rem = pcall(function() return target:debuff_remains_ms(found_id) end)
    if not ok_rem or not rem then return false end
    return rem > 0 and rem < pandemic_ms
end

local function dot_recently_cast_block(sid, target, min_recast_ms)
    if not sid or sid <= 0 or not target or not min_recast_ms or min_recast_ms <= 0 then return false end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end
    guid = tostring(guid)
    local per_spell = recent_dot_cast_ms[sid]
    if not per_spell then return false end
    local last_ms = per_spell[guid]
    if not last_ms then return false end
    return (core.game_time() - last_ms) < min_recast_ms
end

local function mark_dot_cast(sid, target)
    if not sid or sid <= 0 or not target then return end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return end
    guid = tostring(guid)
    local per_spell = recent_dot_cast_ms[sid]
    if not per_spell then
        per_spell = {}
        recent_dot_cast_ms[sid] = per_spell
    end
    per_spell[guid] = core.game_time()
end

local function assumed_debuff_active(sid, target)
    if not sid or sid <= 0 or not target then return false end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return false end
    guid = tostring(guid)
    local per_spell = assumed_debuff_until_ms[sid]
    if not per_spell then return false end
    local until_ms = per_spell[guid]
    if not until_ms or until_ms <= 0 then return false end
    return core.game_time() < until_ms
end

local function mark_assumed_debuff(sid, target, duration_ms)
    if not sid or sid <= 0 or not target or not duration_ms or duration_ms <= 0 then return end
    local ok_guid, guid = pcall(function() return target:get_guid() end)
    if not ok_guid or not guid then return end
    guid = tostring(guid)
    local per_spell = assumed_debuff_until_ms[sid]
    if not per_spell then
        per_spell = {}
        assumed_debuff_until_ms[sid] = per_spell
    end
    per_spell[guid] = core.game_time() + duration_ms
end

-- Forward declaration so helpers defined above can reference it without creating a global.
local try_apply_dot = nil

try_apply_dot = function(target, spell, label, pandemic_ms)
    if not target or not spell then return false end
    local ok_id, sid = pcall(function() return spell:id() end)
    if not ok_id or not sid then return false end

    if (not pandemic_ms or pandemic_ms <= 0) and assumed_debuff_active(sid, target) then
        return false
    end

    local min_recast_ms = menu_number(last_menu_ref, "pvp_dot_min_recast_ms", 2500)
    if dot_recently_cast_block(sid, target, min_recast_ms) then
        vlog("dot.recast.block." .. tostring(sid), 3.0, string.format("[Warlock][PvP][DoT] min-recast block spell_id=%d target=%s (%dms)", sid, safe_name(target), min_recast_ms))
        return false
    end

    if dot_guard:should_block(sid, target) then
        vlog("dot.guard." .. tostring(sid), 1.5, string.format("[Warlock][PvP][DoT] guard active spell_id=%d target=%s", sid, safe_name(target)))
        return false
    end
    if not needs_debuff_refresh(target, spell, pandemic_ms) then return false end
    if not spell:is_castable() then return false end

    -- Only stop wand when we're ACTUALLY about to cast a DoT (all guards passed).
    stop_wand_if_active(core.object_manager.get_local_player(), target)

    dot_guard:on_cast_requested(spell, target)
    local ok = spell:cast_safe(target, label)
    if ok then
        mark_dot_cast(sid, target)
        -- Prevent re-cast loops when aura cache lags. Keep this short so dispels are handled.
        mark_assumed_debuff(sid, target, 12000)
        log_throttled("dot.cast." .. tostring(sid), 0, string.format("[Warlock][PvP][DoT] %s on %s", tostring(label), safe_name(target)))
        return true
    end
    return false
end

local function try_dot_stealthed_units(player, enemies, menu)
    -- Kept menu key name for backward compatibility; feature now applies to ALL stealthed enemies.
    if not menu_enabled(menu, "pvp_anti_stealth_rogue", true) then return false end
    if not enemies or type(enemies) ~= "table" then return false end
    if player:is_channeling_or_casting() then return false end

    for _, e in ipairs(enemies) do
        if is_enemy_player(e) then
            local stealthed = false
            pcall(function() stealthed = e:stealth_up() == true end)
            if stealthed then
                -- High priority: instant DoTs to break stealth
                if spells.corruption and spells.corruption:is_learned() and spells.corruption:is_castable() then
                    if try_apply_dot(e, spells.corruption, "Corruption (anti-stealth)", 0) then return true end
                end
                if spells.siphon_life and spells.siphon_life:is_learned() and spells.siphon_life:is_castable() then
                    if try_apply_dot(e, spells.siphon_life, "Siphon Life (anti-stealth)", 0) then return true end
                end
                if spells.curse_of_agony and spells.curse_of_agony:is_learned() and spells.curse_of_agony:is_castable() then
                    if menu_enabled(menu, "pvp_use_coa", true) and try_apply_dot(e, spells.curse_of_agony, "Curse of Agony (anti-stealth)", 0) then return true end
                end
            end
        end
    end
    return false
end

local function try_apply_curse(player, kill_target, focus, menu)
    if not kill_target then return false end

    local want_tongues = menu_enabled(menu, "auto_curse_tongues_pvp", true)
    local want_exhaust = menu_enabled(menu, "pvp_use_coex", true)
    local want_agony = menu_enabled(menu, "pvp_use_coa", true)
    local want_amplify = menu_enabled(menu, "pvp_use_amplify_curse", true)

    local function maybe_amplify(curse_target, curse_spell, pandemic_ms)
        if not want_amplify then return false end
        if not player or not spells.amplify_curse or not spells.amplify_curse:is_learned() then return false end
        if player:is_moving() or player:is_channeling_or_casting() then return false end
        if not spells.amplify_curse:is_castable() then return false end

        -- Only amplify if we're actually going to (re)apply the curse.
        if not needs_debuff_refresh(curse_target, curse_spell, pandemic_ms) then return false end

        local now = core.game_time()
        if (now - last_amplify_curse_ms) < AMPLIFY_CURSE_THROTTLE_MS then return false end
        last_amplify_curse_ms = now

        if spells.amplify_curse:cast(player, "Amplify Curse") then
            log_throttled("curse.amplify", 0, "[Warlock][PvP][CURSE] Amplify Curse")
            return true
        end
        return false
    end

    local function is_melee_class(u)
        local class_id = 0
        pcall(function() class_id = u:get_class() end)
        return class_id == 1 or class_id == 4 or class_id == 3 -- warrior/rogue/hunter
    end

    local function is_caster_or_healer(u)
        local class_id = 0
        pcall(function() class_id = u:get_class() end)
        if CLASS_HEALERS[class_id] then return true end
        return class_id == 8 or class_id == 9 or class_id == 7 or class_id == 11 or class_id == 5
    end

    local tongues_target = focus and is_enemy_player(focus) and focus or nil

    -- Prevent curse flip-flopping on the same target (e.g. Tongues <-> Agony) which can look like "DoT spam"
    -- and wastes GCDs due to curse exclusivity.
    if tongues_target and want_tongues and want_agony and is_enemy_player(kill_target) then
        local ok1, g1 = pcall(function() return tongues_target:get_guid() end)
        local ok2, g2 = pcall(function() return kill_target:get_guid() end)
        if ok1 and ok2 and g1 and g2 and g1 == g2 and is_caster_or_healer(tongues_target) then
            want_agony = false
        end
    end

    if want_tongues and tongues_target and is_caster_or_healer(tongues_target) and spells.curse_of_tongues:is_learned() then
        if maybe_amplify(tongues_target, spells.curse_of_tongues, 1500) then return true end
        if try_apply_dot(tongues_target, spells.curse_of_tongues, "Curse of Tongues", 1500) then return true end
    end

    if want_exhaust and spells.curse_of_exhaustion:is_learned() then
        if is_melee_class(kill_target) then
            if maybe_amplify(kill_target, spells.curse_of_exhaustion, 1500) then return true end
            if try_apply_dot(kill_target, spells.curse_of_exhaustion, "Curse of Exhaustion", 1500) then return true end
        end
    end

    if want_agony and spells.curse_of_agony:is_learned() then
        if maybe_amplify(kill_target, spells.curse_of_agony, 0) then return true end
        if try_apply_dot(kill_target, spells.curse_of_agony, "Curse of Agony", 0) then return true end
    end

    return false
end

local function can_attempt_cc(now)
    return (now - last_cc_attempt_ms) >= CC_ATTEMPT_THROTTLE_MS
end

local function record_cc_attempt(now)
    last_cc_attempt_ms = now
end

local function try_death_coil_defensive(player, kill_target, menu)
    if not menu_enabled(menu, "auto_death_coil_pvp", true) then return false end
    if not spells.death_coil:is_learned() or not spells.death_coil:is_castable() then return false end
    if not kill_target then return false end
    if not dr_helper.should_death_coil(kill_target) then
        vlog("cc.coil.dr", 1.0, "[Warlock][PvP][CC] Death Coil skipped (horror DR too low)")
        return false
    end

    local hp_threshold = menu_number(menu, "death_coil_hp_pct", 20)
    if hp_pct(player) > hp_threshold then return false end

    local now = core.game_time()
    if not can_attempt_cc(now) then return false end
    record_cc_attempt(now)

    if spells.death_coil:cast(kill_target, "Death Coil (def)") then
        trinket_tracker:on_cc_applied(kill_target, "death_coil", now)
        log_throttled("cc.coil.def", 0, string.format("[Warlock][PvP][CC] Death Coil defensive on %s (hp=%d%%)", safe_name(kill_target), hp_pct(player)))
        return true
    end
    return false
end

local function try_howl_defensive(player, kill_target, menu)
    if not menu_enabled(menu, "use_emergency_cc", true) then return false end
    if not spells.howl_of_terror:is_learned() or not spells.howl_of_terror:is_castable() then return false end
    local hp_threshold = menu_number(menu, "howl_hp_pct", 25)
    if hp_pct(player) > hp_threshold then return false end
    if kill_target and not dr_helper.should_howl(kill_target) then
        vlog("cc.howl.dr", 1.0, "[Warlock][PvP][CC] Howl skipped (fear DR too low)")
        return false
    end

    local now = core.game_time()
    if not can_attempt_cc(now) then return false end
    record_cc_attempt(now)

    if spells.howl_of_terror:cast(player, "Howl (def)") then
        log_throttled("cc.howl.def", 0, string.format("[Warlock][PvP][CC] Howl of Terror defensive (hp=%d%%)", hp_pct(player)))
        return true
    end
    return false
end

local function try_fear(unit, label, menu)
    if not menu_enabled(menu, "use_fear_pvp", true) then return false end
    if not spells.fear:is_learned() or not spells.fear:is_castable() then return false end
    if not unit then return false end

    local ok_cc, feared = pcall(function()
        return unit.CC and unit:is_cc(500, unit.CC.FEAR)
    end)
    if ok_cc and feared then return false end

    local dr_thresh_pct = menu_number(menu, "pvp_fear_dr_threshold", 50)
    local min_dr = math.max(0, math.min(100, dr_thresh_pct)) / 100
    if dr_helper.get_dr(unit, "fear") < min_dr then return false end

    local now = core.game_time()
    if not can_attempt_cc(now) then return false end
    record_cc_attempt(now)

    if spells.fear:cast_safe(unit, label or "Fear") then
        trinket_tracker:on_cc_applied(unit, "fear", now)
        log_throttled("cc.fear", 0, string.format("[Warlock][PvP][CC] Fear on %s", safe_name(unit)))
        return true
    end
    return false
end

local function try_life_tap(player, menu)
    if not menu_enabled(menu, "use_life_tap", true) then return false end
    if not spells.life_tap:is_learned() or not spells.life_tap:is_castable() then return false end
    if player:is_moving() then return false end

    local mana_low = menu_number(menu, "pvp_life_tap_mana_pct", 35)
    local hp_safe = menu_number(menu, "pvp_life_tap_min_hp_pct", 60)

    if mana_pct(player) >= mana_low then return false end
    if hp_pct(player) <= hp_safe then return false end

    -- Block Life Tap when taking damage (don't sacrifice HP while being pressured)
    local under_pressure = false
    pcall(function()
        local incoming = tonumber(player:get_incoming_damage(1.5)) or 0
        under_pressure = incoming > 0
    end)
    if under_pressure then return false end

    if spells.life_tap:cast_safe(player, "Life Tap (safe)") then
        log_throttled("mana.tap", 0, string.format("[Warlock][PvP][Mana] Life Tap at hp=%d%% mana=%d%%", hp_pct(player), mana_pct(player)))
        return true
    end
    return false
end

local function try_drain_mana(player, target, menu)
    if not menu_enabled(menu, "use_drain_mana_pvp", true) then return false end
    if not spells.drain_mana:is_learned() or not spells.drain_mana:is_castable() then return false end
    if not target or not is_enemy_player(target) then return false end
    if mana_pct(target) <= 0 then return false end
    if player:is_moving() then return false end

    local min_self_mana = menu_number(menu, "pvp_drain_mana_when_below_mana_pct", 55)
    if mana_pct(player) >= min_self_mana then return false end

    if spells.drain_mana:cast_safe(target, "Drain Mana") then
        log_throttled("mana.drain", 0, string.format("[Warlock][PvP][Mana] Drain Mana on %s (self mana=%d%%)", safe_name(target), mana_pct(player)))
        return true
    end
    return false
end

local function try_shadow_bolt_nightfall(player, target)
    if not spells.shadow_bolt:is_learned() or not spells.shadow_bolt:is_castable() then return false end
    if not target then return false end
    local SHADOW_TRANCE_BUFF = 17941
    if player:buff_down(SHADOW_TRANCE_BUFF) then return false end
    return spells.shadow_bolt:cast_safe(target, "Shadow Bolt (Nightfall)")
end

local function unit_is_feared(unit)
    if not unit then return false end
    local ok_cc, feared = pcall(function()
        return unit.CC and unit:is_cc(500, unit.CC.FEAR)
    end)
    return ok_cc and feared == true
end

local function try_shadow_bolt_freecast(player, target, menu)
    if not menu_enabled(menu, "use_shadow_bolt", true) then return false end
    if not spells.shadow_bolt:is_learned() or not spells.shadow_bolt:is_castable() then return false end
    if not target or not is_enemy_player(target) then return false end
    if player:is_moving() then return false end

    -- Keep hard-casts conservative in PvP: only freecast while target is feared.
    if not unit_is_feared(target) then return false end

    if mana_pct(player) < 10 then return false end
    return spells.shadow_bolt:cast_safe(target, "Shadow Bolt (freecast)")
end

local function try_shadow_bolt_pressure(player, target, menu)
    if not menu_enabled(menu, "use_shadow_bolt", true) then return false end
    if not spells.shadow_bolt:is_learned() or not spells.shadow_bolt:is_castable() then return false end
    if not player or not target or not is_enemy_player(target) then return false end
    if player:is_moving() or player:is_channeling_or_casting() then return false end

    local min_mana = menu_number(menu, "pvp_shadow_bolt_min_mana_pct", 45)
    if mana_pct(player) < min_mana then return false end

    -- Prefer SB when target is not training us AND we have some distance (reduces pushback risk).
    local safe_dist = menu_number(menu, "pvp_shadow_bolt_safe_distance", 12)
    local dist = 0
    pcall(function() dist = target:distance_to(player) end)
    if dist < safe_dist then return false end

    local on_me = false
    pcall(function()
        local t = target:get_target()
        if t and t.get_guid and player.get_guid then
            on_me = (__object_safety.same(t,player))
        end
    end)
    if on_me then return false end

    return spells.shadow_bolt:cast_safe(target, "Shadow Bolt")
end

local function try_opener_ooc(player, kill_target, focus, menu)
    if not menu_enabled(menu, "pvp_ooc_opener", true) then return false end
    if in_arena_prep() then return false end
    if not kill_target or not is_enemy_player(kill_target) then return false end
    if not kill_target:is_alive() then return false end
    if player:is_channeling_or_casting() then return false end

    -- Allow starting combat: curses + dots only (no fear)
    if try_apply_curse(player, kill_target, focus, menu) then return true end
    if menu_enabled(menu, "use_corruption", true) then
        if try_apply_dot(kill_target, spells.corruption, "Corruption", 2000) then return true end
    end
    if menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned() then
        if try_apply_dot(kill_target, spells.siphon_life, "Siphon Life", 3000) then return true end
    end
    return false
end

local function try_maintain_personal_buffs(player, menu)
    if not player or player:is_moving() or player:is_channeling_or_casting() then return false end

    -- Armor
    if menu_enabled(menu, "use_fel_armor", true) then
        local armor = (spells.fel_armor and spells.fel_armor:is_learned()) and spells.fel_armor or spells.demon_armor
        if armor and armor.is_learned and armor:is_learned() then
            local sid = armor:id()
            if sid and sid > 0 and player:buff_down(sid) and armor:is_castable() then
                log_throttled("prep.armor", 1.5, "[Warlock][PvP][Prep] Applying armor")
                if armor:cast(player, "Armor") then return true end
            end
        end
    end

    -- Soul Link (buff)
    if try_soul_link(player, menu) then return true end

    return false
end

-- ============================================================================
-- Arena prep APL
-- ============================================================================

local function try_prep(player, menu, enemies)
    if not in_arena_prep() then return false end
    if player:is_channeling_or_casting() or player:is_moving() then return false end

    -- Per user request: keep prep logic minimal (buffs only).
    return try_maintain_personal_buffs(player, menu)
end

-- ============================================================================
-- Main PvP execute
-- ============================================================================

function pvp.execute(player, target, menu)
    if not player or not player:is_valid() then return false end
    last_menu_ref = menu

    if not initialized then
        initialized = true
        lockout_tracker.init(spells)
        lockout_tracker.set_log_fn(function(m) log_throttled("lockout", 0, m) end)
        trinket_tracker:set_log_fn(function(m) log_throttled("trinket", 0, m) end)
        log_throttled("init", 0, "[Warlock][PvP] SL/SL module initialized")
    end

    local enemies = izi.enemies(40)
    local kill_target = select_kill_target(target, enemies, menu)
    local focus = get_focus()

    -- Auto-targeting: keep a real target selected (helps users + some spell implementations).
    -- Default selector is lowest HP; we set target to the selected kill target when different/missing.
    if kill_target and (not is_enemy_player(target)) then
        set_player_target(kill_target, "auto")
    else
        if kill_target and target and target.get_guid and kill_target.get_guid then
            local ok1, g1 = pcall(function() return target:get_guid() end)
            local ok2, g2 = pcall(function() return kill_target:get_guid() end)
            if ok1 and ok2 and g1 and g2 and g1 ~= g2 then
                set_player_target(kill_target, "auto_lowest_hp")
            end
        end
    end

    if player:is_in_combat() and kill_target then
        ensure_pet_attack(player, kill_target)
    end

    if menu and menu.pvp_spec_mode and menu.pvp_spec_mode.get then
        local ok, v = pcall(function() return menu.pvp_spec_mode:get() end)
        if ok and tonumber(v) and tonumber(v) ~= 1 then
            log_throttled("spec.warn", 5, "[Warlock][PvP] PvP Spec is not SL/SL, but this module only supports SL/SL (ignoring selection).")
        end
    end

    local grace = menu_number(menu, "pvp_dot_grace_ms", 250)
    dot_guard:set_default_grace_ms(grace)

    -- Make curse/DoT grace a bit higher by default to tolerate aura cache lag in PvP
    pcall(function()
        if spells.curse_of_agony then dot_guard:set_spell_grace_ms(spells.curse_of_agony:id(), math.max(grace, 1200)) end
        if spells.curse_of_tongues then dot_guard:set_spell_grace_ms(spells.curse_of_tongues:id(), math.max(grace, 1200)) end
        if spells.curse_of_exhaustion then dot_guard:set_spell_grace_ms(spells.curse_of_exhaustion:id(), math.max(grace, 1200)) end
        if spells.corruption then dot_guard:set_spell_grace_ms(spells.corruption:id(), math.max(grace, 1000)) end
        if spells.siphon_life then dot_guard:set_spell_grace_ms(spells.siphon_life:id(), math.max(grace, 1000)) end
    end)

    -- Highest PvP utility priority: keep Detect Invisibility on team (when enabled)
    if try_maintain_detect_invisibility(player, menu) then return true end

    -- Highest PvP combat priority: if an enemy is stealthed in our enemy list, instant DoT it.
    if try_dot_stealthed_units(player, enemies, menu) then return true end

    if try_prep(player, menu, enemies) then return true end

    if not player:is_in_combat() then
        if try_maintain_personal_buffs(player, menu) then return true end
        if kill_target and try_opener_ooc(player, kill_target, focus, menu) then return true end
        return false
    end

    lockout_tracker.on_update(player)

    local now = core.game_time()
    if focus then trinket_tracker:check(focus, now) end
    if kill_target then trinket_tracker:check(kill_target, now) end

    -- Actions allowed while casting/channeling (pet + items only)
    if pet_controller.execute and pet_controller.execute(player, kill_target, menu) then return true end

    if try_break_cc(player, menu) then return true end
    if try_use_spellstone(player, menu) then return true end
    if try_use_healthstone(player, menu) then return true end

    if player:is_channeling_or_casting() then
        vlog("cast.block", 0.8, "[Warlock][PvP] player is casting/channeling - skipping spell casts")
        return false
    end

    if menu_enabled(menu, "pvp_auto_set_focus", true) and not focus then
        local f = select_focus_target(enemies, kill_target)
        if f and set_focus(f, "combat_auto") then return true end
    end

    if menu and menu.pvp_focus_fear_key and plugin_helper:is_toggle_enabled(menu.pvp_focus_fear_key) then
        if focus and try_fear(focus, "Focus Fear (manual)", menu) then return true end
    end
    if menu and menu.pvp_focus_spell_lock_key and plugin_helper:is_toggle_enabled(menu.pvp_focus_spell_lock_key) then
        if focus and pet_controller.try_spell_lock and pet_controller.try_spell_lock(player, focus, menu) then return true end
    end
    if menu and menu.pvp_use_healthstone_key and plugin_helper:is_toggle_enabled(menu.pvp_use_healthstone_key) then
        if try_use_healthstone(player, menu) then return true end
    end
    if menu and menu.pvp_use_spellstone_key and plugin_helper:is_toggle_enabled(menu.pvp_use_spellstone_key) then
        update_bag_cache()
        local ss_item = get_spellstone_item_from_bags()
        if ss_item and use_item_self_best_effort(ss_item, player, "Spellstone (manual)") then
            last_spellstone_attempt_ms = core.game_time()
            log_throttled("def.spellstone.manual", 0, "[Warlock][PvP][DEF] Spellstone used (manual key)")
            return true
        end
    end

    if try_howl_defensive(player, kill_target, menu) then return true end
    if kill_target and try_death_coil_defensive(player, kill_target, menu) then return true end

    if try_soul_link(player, menu) then return true end

    local shadow_locked = false
    if lockout_tracker.is_shadow_locked then
        local ok, v = pcall(function() return lockout_tracker.is_shadow_locked(now) end)
        shadow_locked = ok and v == true
    end
    if shadow_locked then
        vlog("lockout.shadow", 1.5, "[Warlock][PvP] Shadow school locked; using filler only")
        if kill_target and try_wand_filler(player, kill_target, menu, true) then return true end
        return false
    end

    if try_life_tap(player, menu) then return true end
    if focus and try_drain_mana(player, focus, menu) then return true end
    if kill_target and try_drain_mana(player, kill_target, menu) then return true end

    if try_apply_curse(player, kill_target, focus, menu) then return true end

    if menu_enabled(menu, "pvp_auto_cc", true) and focus and is_enemy_player(focus) then
        local is_healer = false
        pcall(function()
            local cid = focus:get_class()
            is_healer = CLASS_HEALERS[cid] == true
        end)
        if is_healer and try_fear(focus, "Fear (focus healer)", menu) then return true end
    end

    -- If we don't have a healer focus (double DPS / no healer visible), fear the kill target as peel/setup.
    if menu_enabled(menu, "pvp_auto_cc", true) and kill_target and is_enemy_player(kill_target) then
        local focus_is_healer = false
        if focus and is_enemy_player(focus) then
            pcall(function()
                local cid = focus:get_class()
                focus_is_healer = CLASS_HEALERS[cid] == true
            end)
        end
        if not focus_is_healer then
            -- Don't Fear a target with our DoTs on it - they break instantly from damage ticks.
            -- SL/SL strategy: Fear off-targets (healers), DoT the kill target.
            local has_dots_on_target = false
            pcall(function()
                if spells.corruption and not kill_target:debuff_down(spells.corruption:id()) then has_dots_on_target = true end
                if not has_dots_on_target and spells.curse_of_agony and not kill_target:debuff_down(spells.curse_of_agony:id()) then has_dots_on_target = true end
                if not has_dots_on_target and spells.siphon_life and not kill_target:debuff_down(spells.siphon_life:id()) then has_dots_on_target = true end
            end)
            if not has_dots_on_target then
                if try_fear(kill_target, "Fear (kill target)", menu) then return true end
            else
                vlog("cc.fear.skip_dotted", 8.0, "[Warlock][PvP][CC] Fear skipped on kill target (DoTs active, would break instantly)")
            end
        end
    end

    if menu_enabled(menu, "use_corruption", true) and kill_target then
        if try_apply_dot(kill_target, spells.corruption, "Corruption", 2000) then return true end
    end
    if menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned() and kill_target then
        if try_apply_dot(kill_target, spells.siphon_life, "Siphon Life", 3000) then return true end
    end

    if menu_enabled(menu, "pvp_auto_dot_spread", true) and enemies then
        local min_mana = menu_number(menu, "pvp_dot_spread_min_mana_pct", 40)
        if mana_pct(player) >= min_mana then
            local limit = menu_number(menu, "pvp_dot_spread_limit", 3)
            local spread_count = 0
            for _, e in ipairs(enemies) do
                if spread_count >= limit then break end
                if is_enemy_player(e) then
                    -- Skip CC'd enemies to avoid breaking Fear/Seduce/etc.
                    local is_cc = false
                    pcall(function()
                        if e.CC then
                            is_cc = e:is_cc(1000, e.CC.ANY)
                        end
                    end)
                    if not is_cc then
                        -- Spread is for coverage, not refreshes; only count enemies that actually need DoTs.
                        local corr_missing = menu_enabled(menu, "use_corruption", true) and needs_debuff_refresh(e, spells.corruption, 0)
                        local sl_missing = menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned() and needs_debuff_refresh(e, spells.siphon_life, 0)
                        if corr_missing or sl_missing then
                            spread_count = spread_count + 1
                            if corr_missing and try_apply_dot(e, spells.corruption, "Corruption (spread)", 0) then return true end
                            if sl_missing and try_apply_dot(e, spells.siphon_life, "Siphon Life (spread)", 0) then return true end
                        end
                    end
                end
            end
        else
            vlog("dot.spread.mana", 3.0, string.format("[Warlock][PvP][DoT] Spread skipped (mana=%d%% < %d%%)", mana_pct(player), min_mana))
        end
    end

    if kill_target and try_offensive_racials(player, kill_target, menu) then return true end

    if kill_target and try_shadow_bolt_nightfall(player, kill_target) then return true end
    if kill_target and try_shadow_bolt_freecast(player, kill_target, menu) then return true end
    if kill_target and try_shadow_bolt_pressure(player, kill_target, menu) then return true end
 
    if kill_target and spells.drain_life:is_learned() and spells.drain_life:is_castable() and not player:is_moving() then
        local dl_hp = menu_number(menu, "pvp_drain_life_below_hp_pct", 90)
        if hp_pct(player) <= dl_hp then
            if spells.drain_life:cast_safe(kill_target, "Drain Life") then return true end
        end
    end

    -- Nothing else to do: wand filler to prevent dead time.
    if kill_target and try_wand_filler(player, kill_target, menu, true) then return true end

    return false
end

return pvp
