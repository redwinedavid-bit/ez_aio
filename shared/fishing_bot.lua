local __object_safety=require("shared/object_safety")
-- BxA Fishing Bot (Simplified, API-Compliant)

---@type fish_helper
local fish_helper = require("common/utility/fish_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type color
local color = require("common/color")

---@type vec3|nil
local vec3 = nil
do
    local ok, mod = pcall(require, "common/geometry/vector_3")
    if ok then
        vec3 = mod
    end
end

local izi = require("common/izi_sdk")
local ok_astro, rotation_settings_ui = pcall(require, "root/ext_lib_astro_ui/main")
local game_client = require("shared/game_client")
local inventory_helper = require("common/utility/inventory_helper")

-- Module availability check
local function validate_dependencies()
    if not fish_helper then
        core.log_error("[FishBot] fish_helper module not available")
        return false
    end
    if not fish_helper.is_fish_bobber then
        core.log_error("[FishBot] fish_helper.is_fish_bobber not found")
        return false
    end
    return true
end

local DEPENDENCIES_OK = validate_dependencies()

local fishing_bot = {}

-- Bait items with their IDs
local BAIT_PRIORITY = {
    era = {
        { id = 6533, name = "Aquadynamic Fish Attractor" },
        { id = 7307, name = "Flesh Eating Worm" },
        { id = 6532, name = "Bright Baubles" },
        { id = 6530, name = "Nightcrawlers" },
        { id = 6529, name = "Shiny Bauble" },
    },
    tbc = {
        { id = 6533, name = "Aquadynamic Fish Attractor" },
        { id = 7307, name = "Flesh Eating Worm" },
        { id = 6532, name = "Bright Baubles" },
        { id = 6530, name = "Nightcrawlers" },
        { id = 6529, name = "Shiny Bauble" },
    },
    any = {
        { id = 6533,   name = "Aquadynamic Fish Attractor" },
        { id = 7307,   name = "Flesh Eating Worm" },
        { id = 6532,   name = "Bright Baubles" },
        { id = 6530,   name = "Nightcrawlers" },
        { id = 6529,   name = "Shiny Bauble" },
        { id = 34861,  name = "Sharpened Fish Hook" },
        { id = 6811,   name = "Aquadynamic Fish Lens" },
        { id = 46006,  name = "Flesh Eating Worm" },
        { id = 190953, name = "Lost Sole Bait" },
        { id = 190954, name = "Silvergill Pike Bait" },
        { id = 190955, name = "Pocked Bonefish Bait" },
        { id = 190956, name = "Iridescent Amberjack Bait" },
        { id = 190957, name = "Spinefin Piranha Bait" },
        { id = 190958, name = "Elysian Thade Bait" }
    }
}

-- Fishing poles in priority order (best first)
local FISHING_POLES = {
    { id = 19970, name = "Arcanite Fishing Pole" },
    { id = 25978, name = "Seth's Graphite Fishing Pole" },
    { id = 19022, name = "Nat Pagle's Extreme Angler FC-5000" },
    { id = 6367,  name = "Big Iron Fishing Pole" },
    { id = 6366,  name = "Darkwood Fishing Pole" },
    { id = 12225, name = "Blump Family Fishing Pole" },
    { id = 6365,  name = "Strong Fishing Pole" },
    { id = 6256,  name = "Fishing Pole" },
}

-- Lure buff IDs to detect active lures
local lure_buff_ids = {
    8087, -- Shiny Bauble
    8088, -- Nightcrawlers
    8089, -- Aquadynamic Fish Attractor
    8090, -- Bright Baubles
    9092, -- Flesh Eating Worm
    8532, -- Aquadynamic Fish Lens (optional / some clients)
}

-- Menu elements (declared outside callback)
local menu = {
    main_tree = core.menu.tree_node(),
    enable = core.menu.checkbox(false, "fishbot_enable"),
    only_ooc = core.menu.checkbox(true, "fishbot_only_ooc"),
    auto_cast = core.menu.checkbox(true, "fishbot_auto_cast"),
    debug_logging = core.menu.checkbox(false, "fishbot_debug_logging"),
    trace_logging = core.menu.checkbox(false, "fishbot_trace_logging"),
    fish_click_delay_min_ms = core.menu.slider_int(0, 700, 0, "fishbot_fish_click_delay_min_ms"),
    fish_click_delay_max_ms = core.menu.slider_int(0, 700, 0, "fishbot_fish_click_delay_max_ms"),
    post_loot_pause_min_ms = core.menu.slider_int(0, 3000, 600, "fishbot_post_loot_pause_min_ms"),
    post_loot_pause_max_ms = core.menu.slider_int(0, 3000, 1400, "fishbot_post_loot_pause_max_ms"),
    cast_delay_min_ms = core.menu.slider_int(100, 2000, 500, "fishbot_cast_delay_min_ms"),
    cast_delay_max_ms = core.menu.slider_int(100, 2000, 1500, "fishbot_cast_delay_max_ms"),
    anti_afk_mode = core.menu.combobox(1, "fishbot_anti_afk_mode"),  -- 1=Off, 2=Turn, 3=Jump
    anti_afk_interval_s = core.menu.slider_int(60, 300, 180, "fishbot_anti_afk_interval_s"),
    auto_equip_pole = core.menu.checkbox(true, "fishbot_auto_equip_pole"),
    look_at_bobber = core.menu.checkbox(true, "fishbot_look_at_bobber"),
}

-- State tracking
local state = {
    next_cast_time = 0.0,
    last_cast_attempt = 0.0,
    last_equip_attempt = 0.0,
    last_bait_use_time = 0.0,
    lure_pending_until = 0.0,
    last_lure_item_id = 0,
    last_loot_time = 0.0,
    pending_bobber = nil,
    pending_bobber_use_at = 0.0,
    anti_afk_last_action = 0.0,
    anti_afk_turn_stop_at = 0.0,
    was_enabled = false,
    fishing_spell_id = 0,
    fishing_spell_checked_at = 0.0,
    failed_cast_count = 0,
    cast_start_time = 0.0,
}

local ANTI_AFK_TURN_PULSE_S = 0.15

local log_throttle = {}
local trace_throttle = {}

local function debug_enabled()
    return menu.debug_logging and menu.debug_logging.get_state and menu.debug_logging:get_state()
end

local function trace_enabled()
    return menu.trace_logging and menu.trace_logging.get_state and menu.trace_logging:get_state()
end

local function log_throttled(key, interval_s, message)
    if not debug_enabled() then
        return
    end
    local now = core.time()
    local next_allowed = log_throttle[key] or 0.0
    if now < next_allowed then
        return
    end
    log_throttle[key] = now + (tonumber(interval_s) or 1.0)
    core.log("[FishBot] " .. message)
end

local function trace_throttled(key, interval_s, message)
    if not trace_enabled() then
        return
    end
    local now = core.time()
    local next_allowed = trace_throttle[key] or 0.0
    if now < next_allowed then
        return
    end
    trace_throttle[key] = now + (tonumber(interval_s) or 0.1)
    core.log("[FishBot][TRACE] " .. message)
end

---Best-effort conversion to a "real" vec3 instance.
---Avoids relying on `:clone()` being present on position objects in all clients.
---@param pos any
---@return any
local function coerce_vec3(pos)
    if not pos then
        return nil
    end

    if vec3 and vec3.new and pos.x ~= nil and pos.y ~= nil and pos.z ~= nil then
        local ok_new, v = pcall(vec3.new, tonumber(pos.x) or 0, tonumber(pos.y) or 0, tonumber(pos.z) or 0)
        if ok_new and v then
            return v
        end
    end

    if type(pos) == "table" and type(pos.clone) == "function" then
        local ok_clone, v = pcall(pos.clone, pos)
        if ok_clone and v then
            return v
        end
    end

    if pos.x ~= nil and pos.y ~= nil and pos.z ~= nil then
        return { x = tonumber(pos.x) or 0, y = tonumber(pos.y) or 0, z = tonumber(pos.z) or 0 }
    end

    return pos
end

-- Helper: Random number between min and max
local function rand_between(min_val, max_val)
    if max_val < min_val then
        min_val, max_val = max_val, min_val
    end
    local result = min_val + (math.random() * (max_val - min_val))
    log_throttled("rand_between", 1.0, string.format("rand_between(min=%.3f,max=%.3f) -> %.3f", min_val, max_val, result))
    return result
end

-- Helper: Get slider value safely
local function get_slider_value(slider, fallback)
    if not slider then return fallback end
    local val = slider:get()
    local result = val or fallback
    log_throttled("slider_value_" .. tostring(slider), 2.0, "slider_value -> " .. tostring(result))
    return result
end

-- Helper: Get slider ms as seconds
local function get_slider_ms_as_seconds(slider, fallback_s)
    local ms = get_slider_value(slider, fallback_s * 1000)
    local result = ms / 1000.0
    log_throttled("slider_ms_" .. tostring(slider), 2.0, "slider_ms_as_seconds -> " .. tostring(result))
    return result
end

-- Find the fishing spell ID
local function get_fishing_spell_id()
    local now = core.time()
    local function is_position_cast(spell_id)
        local ok, result = pcall(function()
            return core.spell_book.is_spell_position_cast(spell_id)
        end)
        return ok and result
    end

    local function get_cast_time(spell_id)
        local ok, cast_time_s = pcall(function()
            return core.spell_book.get_spell_cast_time(spell_id)
        end)
        return ok and (tonumber(cast_time_s) or 0) or 0
    end

    local function is_learned(spell_id)
        local ok, learned = pcall(function()
            return core.spell_book.is_spell_learned(spell_id)
        end)
        return ok and learned
    end

    -- Cache: in some clients fishing ranks report cast_time=0 and pos_cast=false, but still cast fine (self-target).
    -- Only validate that the cached spell is still learned; don't over-filter.
    if state.fishing_spell_id > 0 then
        if is_learned(state.fishing_spell_id) then
            return state.fishing_spell_id
        end
        state.fishing_spell_id = 0
    end

    local FISHING_BASE_IDS = {
        -- Fishing cast/channel spell IDs (include higher-rank variants used by some clients)
        [7620]  = true, -- Fishing (Apprentice)
        [7731]  = true, -- Fishing (Journeyman)
        [7732]  = true, -- Fishing (Expert)
        [18248] = true, -- Fishing (Artisan) (Era)
        [33095] = true, -- Fishing (Master) (TBC)
    }

    local function is_fishing_name(spell_name)
        if type(spell_name) ~= "string" then return false end
        local lower = tostring(spell_name):lower()
        local function has(token)
            return lower:find(token, 1, true) ~= nil
        end
        return has("fishing")
            or has("angeln")
            or has("peche") or has("pêche")
            or has("pesca")
    end

    local function get_base_id(spell_id)
        local ok, base_id = pcall(function()
            return core.spell_book.get_base_spell_id(spell_id)
        end)
        return ok and tonumber(base_id) or spell_id
    end

    local function extract_spell(spell_id, spell_name)
        local sid = tonumber(spell_id)
        local name = spell_name
        if type(spell_name) == "table" then
            sid = tonumber(spell_name.spell_id or spell_name.id or spell_name[1]) or sid
            name = spell_name.spell_name or spell_name.name or name
        elseif type(spell_name) == "number" and (not sid or sid <= 0) then
            sid = tonumber(spell_name)
            name = nil
        end
        return sid or 0, name
    end

    -- Cheap fallback first (no spellbook scan required)
    local candidates = { 33095, 18248, 7732, 7731, 7620 }
    for _, spell_id in ipairs(candidates) do
        local learned = is_learned(spell_id)
        local is_pos_cast = is_position_cast(spell_id)
        local cast_time_s = get_cast_time(spell_id)
        trace_throttled("spell_candidate_" .. tostring(spell_id), 1.0,
            "learned=" .. tostring(learned)
                .. " pos_cast=" .. tostring(is_pos_cast)
                .. " cast_time=" .. tostring(cast_time_s))
        if debug_enabled() then
            core.log("[FishBot] candidate " .. tostring(spell_id)
                .. " learned=" .. tostring(learned)
                .. " pos_cast=" .. tostring(is_pos_cast)
                .. " cast_time=" .. tostring(cast_time_s))
        end
        -- Some clients report fishing ranks as pos_cast=false and cast_time=0, yet casting still works via cast_target_spell(self).
        if learned then
            state.fishing_spell_id = spell_id
            log_throttled("spell_fallback", 2.0, "get_fishing_spell_id fallback -> " .. tostring(spell_id))
            return spell_id
        end
    end

    -- Throttle spellbook scanning (avoid doing heavy work every frame)
    if (now - (state.fishing_spell_checked_at or 0.0)) < 2.0 then
        return 0
    end
    state.fishing_spell_checked_at = now

    local spells = core.spell_book.get_spells and core.spell_book.get_spells() or nil
    if debug_enabled() then
        core.log("[FishBot] spell_book.get_spells() -> " .. tostring(type(spells)))
    end
    if spells then
        local scan_count = 0
        for spell_id, spell_name in pairs(spells) do
            local sid, name = extract_spell(spell_id, spell_name)
            if sid > 0 and is_learned(sid) then
                local base_id = get_base_id(sid)

                local ok_spell_name, api_name = pcall(function()
                    return core.spell_book.get_spell_name(sid)
                end)

                local name_match = is_fishing_name(name) or (ok_spell_name and is_fishing_name(api_name))
                local base_match = FISHING_BASE_IDS[base_id] or FISHING_BASE_IDS[sid]

                if debug_enabled() then
                    scan_count = scan_count + 1
                    if name_match or base_match then
                        core.log("[FishBot] scan spell " .. tostring(sid)
                            .. " name=" .. tostring(ok_spell_name and api_name or name)
                            .. " base_id=" .. tostring(base_id)
                            .. " base_match=" .. tostring(base_match)
                            .. " name_match=" .. tostring(name_match))
                    end
                end

                if base_match or name_match then
                    state.fishing_spell_id = sid
                    core.log("[FishBot] get_fishing_spell_id scan -> " .. tostring(sid)
                        .. " (name=" .. tostring(ok_spell_name and api_name or name) .. ")")
                    return sid
                end
            end
        end
        if debug_enabled() then
            core.log("[FishBot] spellbook scan done, checked " .. tostring(scan_count) .. " castable spells, no fishing spell found")
        end
    end
    core.log("[FishBot] get_fishing_spell_id -> 0 (FAILED to find any fishing spell)")
    return 0
end

-- Check if player has an active lure buff
---@param local_player game_object
---@return boolean
local function has_lure_aura(local_player)
    local auras = local_player:get_auras()
    if not auras then return false end

    for _, aura in ipairs(auras) do
        if aura and aura.buff_id then
            for _, buff_id in ipairs(lure_buff_ids) do
                if aura.buff_id == buff_id then
                    log_throttled("has_lure_aura", 2.0, "has_lure_aura -> true (buff_id=" .. tostring(buff_id) .. ")")
                    return true
                end
            end
        end
    end
    log_throttled("has_lure_aura", 2.0, "has_lure_aura -> false")
    return false
end

-- Find the player's fishing bobber
---@return game_object|nil
local function find_bobber()
    local objects = core.object_manager.get_all_objects()
    if not objects then return nil end

    trace_throttled("bobber_scan", 1.0, "objects_count=" .. tostring(#objects))
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj:is_valid() then
            local ok, is_bobber = pcall(function() return fish_helper:is_fish_bobber(obj) end)
            if ok and is_bobber then
                log_throttled("find_bobber", 1.5, "find_bobber -> found")
                trace_throttled("bobber_found", 0.75, "found bobber")
                return obj
            end
        end
    end
    log_throttled("find_bobber", 1.5, "find_bobber -> nil")
    trace_throttled("bobber_none", 0.75, "no bobber")
    return nil
end

local function is_fishing_pole_equipped(local_player)
    local mh_slot = local_player:get_item_at_inventory_slot(16)
    if not mh_slot or not mh_slot.object then
        return false
    end

    local ok_id, item_id = pcall(function() return mh_slot.object:get_item_id() end)
    item_id = ok_id and tonumber(item_id) or 0
    trace_throttled("mh_item_id", 1.0, "mainhand_item_id=" .. tostring(item_id))
    if item_id <= 0 then
        return false
    end

    for _, pole in ipairs(FISHING_POLES) do
        if pole.id == item_id then
            return true
        end
    end
    return false
end

-- Try to equip a fishing pole
---@param local_player game_object
---@return boolean
local function try_equip_fishing_pole(local_player)
    if not menu.auto_equip_pole:get_state() then
        trace_throttled("equip_skip_disabled", 1.0, "auto_equip_pole disabled")
        return false
    end

    -- Don't equip while casting/channeling
    if local_player:get_active_spell_cast_end_time() > 0 then
        trace_throttled("equip_skip_casting", 0.5, "skip equip: casting")
        return false
    end
    if local_player:get_active_channel_cast_end_time() > 0 then
        trace_throttled("equip_skip_channeling", 0.5, "skip equip: channeling")
        return false
    end

    local now = core.time()
    if (now - (state.last_equip_attempt or 0.0)) < 1.25 then
        trace_throttled("equip_throttle", 0.5, "equip throttled")
        return false
    end

    if is_fishing_pole_equipped(local_player) then
        trace_throttled("equip_skip_already_pole", 1.0, "pole already equipped; skip equip")
        return false
    end

    -- Check each pole in priority order, equip the best one we have
    for _, pole in ipairs(FISHING_POLES) do
        local item = izi.item(pole.id)
        trace_throttled("equip_check_" .. tostring(pole.id), 1.0,
            "pole=" .. pole.name .. " equipped=" .. tostring(item:equipped()) .. " count=" .. tostring(item:count()))
        if item:count() > 0 then
            state.last_equip_attempt = now
            item:use_self()
            log_throttled("equip_pole", 2.0, "try_equip_fishing_pole -> equipping " .. pole.name)
            state.next_cast_time = core.time() + 1.5
            return true
        end
    end

    log_throttled("equip_pole_none", 5.0, "try_equip_fishing_pole -> no pole found in inventory")
    trace_throttled("equip_none", 2.0, "no pole found in inventory")
    return false
end

local function pole_has_lure(item_obj)
    if not item_obj then
        return false
    end

    local ok_id, enchant_id = pcall(function() return item_obj:item_enchant_id() end)
    enchant_id = ok_id and tonumber(enchant_id) or 0
    if enchant_id and enchant_id > 0 then
        return true
    end

    local ok_has, has_enchant = pcall(function() return item_obj:item_has_enchant() end)
    if ok_has and has_enchant == true then
        local ok_exp, exp = pcall(function() return item_obj:item_enchant_expiration() end)
        exp = ok_exp and tonumber(exp) or 0
        -- Some clients return has_enchant=true with exp=0 briefly; treat as enchanted regardless.
        return true
    end

    return false
end

-- Try to apply bait to fishing pole
---@param local_player game_object
---@return boolean
local function try_apply_bait(local_player)
    local now = core.time()
    if now < (state.lure_pending_until or 0.0) then
        trace_throttled("bait_skip_pending", 0.5, "skip bait: lure pending")
        return false
    end

    if (now - state.last_bait_use_time) < 2.0 then
        log_throttled("bait_skip_cooldown", 1.0, "try_apply_bait -> false (cooldown gate)")
        trace_throttled("bait_skip_gate", 0.75, "skip bait: gate dt=" .. tostring(now - state.last_bait_use_time))
        return false
    end

    -- Get main hand (fishing pole should be equipped)
    local main_hand = local_player:get_item_at_inventory_slot(16)
    if not main_hand or not main_hand.object then
        log_throttled("bait_no_mainhand", 2.0, "try_apply_bait -> false (no main hand)")
        trace_throttled("bait_no_mainhand", 0.75, "no mainhand slot/object")
        return false
    end

    if has_lure_aura(local_player) then
        log_throttled("bait_skip_lure", 2.0, "try_apply_bait -> false (lure aura active)")
        trace_throttled("bait_skip_lure", 0.75, "skip bait: lure aura active")
        return false
    end

    -- Additional check: if the pole already has an enchant (lure), skip
    local ok_enchant, has_enchant = pcall(function() return main_hand.object:item_has_enchant() end)
    if ok_enchant and has_enchant then
        log_throttled("bait_skip_enchant", 2.0, "try_apply_bait -> false (pole already has enchant)")
        trace_throttled("bait_skip_enchant", 0.75, "skip bait: pole has enchant")
        return false
    end
    trace_throttled("bait_enchant_state", 1.0, "item_has_enchant ok=" .. tostring(ok_enchant) .. " has=" .. tostring(has_enchant))

    if pole_has_lure(main_hand.object) then
        log_throttled("bait_skip_enchant_robust", 2.0, "try_apply_bait -> false (pole lure detected)")
        trace_throttled("bait_skip_enchant_robust", 0.75, "skip bait: pole lure detected via enchant_id/has_enchant")
        return false
    end

    local flavor = game_client and game_client.get_flavor and game_client.get_flavor() or "unknown"
    local bait_priority = BAIT_PRIORITY.any
    if flavor == "era" then
        bait_priority = BAIT_PRIORITY.era
    elseif flavor == "tbc" then
        bait_priority = BAIT_PRIORITY.tbc
    end

    -- Find available bait
    for _, bait in ipairs(bait_priority) do
        if local_player:has_item(bait.id) then
            local cooldown = local_player:get_item_cooldown(bait.id)
            trace_throttled("bait_candidate_" .. tostring(bait.id), 1.0,
                "bait id=" .. tostring(bait.id) .. " name=" .. tostring(bait.name) .. " cooldown=" .. tostring(cooldown))
            if cooldown <= 0.0 then
                local ok_use, used = pcall(core.input.use_item_target, bait.id, main_hand.object)
                trace_throttled("bait_use_" .. tostring(bait.id), 0.75,
                    "use_item_target ok=" .. tostring(ok_use) .. " result=" .. tostring(used))
                if ok_use and used then
                    state.last_bait_use_time = now
                    state.lure_pending_until = now + 10.0
                    state.last_lure_item_id = bait.id
                    log_throttled("bait_apply_ok", 2.0, "try_apply_bait -> true (id=" .. tostring(bait.id) .. ")")
                    return true
                end
                log_throttled("bait_apply_fail", 2.0, "try_apply_bait -> false (use_item_target failed id=" .. tostring(bait.id) .. ")")
            end
        end
    end

    log_throttled("bait_not_found", 2.0, "try_apply_bait -> false (no bait)")
    return false
end

-- Try to cast fishing spell
---@param local_player game_object
---@return boolean
local function try_cast_fishing(local_player)
    if not menu.auto_cast:get_state() then
        log_throttled("cast_skip_disabled", 2.0, "try_cast_fishing -> false (auto_cast disabled)")
        trace_throttled("cast_skip_disabled", 0.75, "auto_cast disabled")
        return false
    end

    local spell_id = get_fishing_spell_id()
    if spell_id <= 0 then
        log_throttled("cast_no_spell", 1.0, "try_cast_fishing -> false (no spell_id, get_fishing_spell_id returned 0)")
        trace_throttled("cast_no_spell", 0.75, "no fishing spell_id detected")
        return false
    end

    local now = core.time()
    if now < state.next_cast_time then
        log_throttled("cast_throttle", 1.0, "try_cast_fishing -> false (next_cast_time)")
        trace_throttled("cast_gate_next", 0.5,
            "cast gated by next_cast_time now=" .. tostring(now) .. " next=" .. tostring(state.next_cast_time))
        return false
    end

    if (now - state.last_cast_attempt) < 0.5 then
        log_throttled("cast_attempt_throttle", 1.0, "try_cast_fishing -> false (attempt throttle)")
        trace_throttled("cast_gate_attempt", 0.5, "attempt gated dt=" .. tostring(now - state.last_cast_attempt))
        return false
    end

    local ok_pos_cast, is_pos_cast = pcall(function() return core.spell_book.is_spell_position_cast(spell_id) end)
    is_pos_cast = ok_pos_cast and is_pos_cast == true
    trace_throttled("cast_mode", 0.5, "spell_id=" .. tostring(spell_id) .. " is_position_cast=" .. tostring(is_pos_cast))

    if not is_pos_cast and core.input and core.input.cast_target_spell then
        local ok_cast, cast_ok = pcall(core.input.cast_target_spell, spell_id, local_player)
        trace_throttled("cast_direct_target", 0.25, "cast_target_spell ok=" .. tostring(ok_cast) .. " result=" .. tostring(cast_ok))
        if ok_cast and cast_ok == true then
            state.last_cast_attempt = now
            state.cast_start_time = now
            state.failed_cast_count = 0
            state.next_cast_time = now + rand_between(
                get_slider_ms_as_seconds(menu.cast_delay_min_ms, 0.5),
                get_slider_ms_as_seconds(menu.cast_delay_max_ms, 1.5)
            )
            return true
        end
        state.last_cast_attempt = now
        state.next_cast_time = now + 0.75
        return false
    end

    -- Position cast path
    local player_pos = coerce_vec3(local_player:get_position())
    if not player_pos then return false end

    local cast_pos = coerce_vec3(player_pos)
    if not cast_pos then return false end

    local direction = local_player:get_direction()
    if direction then
        cast_pos.x = cast_pos.x + (direction.x * 12.0)
        cast_pos.y = cast_pos.y + (direction.y * 12.0)
    end

    if core.input and core.input.cast_position_spell then
        local ok_cast, cast_ok = pcall(core.input.cast_position_spell, spell_id, cast_pos)
        trace_throttled("cast_direct_pos", 0.25, "cast_position_spell ok=" .. tostring(ok_cast) .. " result=" .. tostring(cast_ok))
        if ok_cast and cast_ok == true then
            state.last_cast_attempt = now
            state.cast_start_time = now
            state.failed_cast_count = 0
            state.next_cast_time = now + rand_between(
                get_slider_ms_as_seconds(menu.cast_delay_min_ms, 0.5),
                get_slider_ms_as_seconds(menu.cast_delay_max_ms, 1.5)
            )
            return true
        end
        state.last_cast_attempt = now
        state.next_cast_time = now + 0.75
        return false
    end

    -- Queue the fishing spell (fallback)
    if spell_queue and spell_queue.queue_spell_position then
        spell_queue:queue_spell_position(spell_id, cast_pos, 1, "Fishing")
        log_throttled("cast_queue", 1.0, "queue_spell_position id=" .. tostring(spell_id))
        trace_throttled("cast_queue_pos", 0.5, "queued position spell")
    elseif spell_queue and spell_queue.queue_spell_target then
        spell_queue:queue_spell_target(spell_id, local_player, 1, "Fishing")
        log_throttled("cast_queue", 1.0, "queue_spell_target id=" .. tostring(spell_id))
        trace_throttled("cast_queue_target", 0.5, "queued target spell (self)")
    else
        core.log_error("[FishBot] Cannot cast: no cast_* API and no suitable queue_* API")
        state.last_cast_attempt = now
        state.next_cast_time = now + 2.0
        return false
    end

    state.last_cast_attempt = now
    state.cast_start_time = now
    state.failed_cast_count = 0
    state.next_cast_time = now + rand_between(
        get_slider_ms_as_seconds(menu.cast_delay_min_ms, 0.5),
        get_slider_ms_as_seconds(menu.cast_delay_max_ms, 1.5)
    )
    return true
end

-- Anti-AFK modes: 1=Off, 2=Turn, 3=Jump
local ANTI_AFK_OFF = 1
local ANTI_AFK_TURN = 2
local ANTI_AFK_JUMP = 3

---@param local_player game_object
local function do_anti_afk(local_player)
    local mode = menu.anti_afk_mode:get()
    if not mode or mode == ANTI_AFK_OFF then
        return
    end

    local now = core.time()
    local interval = get_slider_value(menu.anti_afk_interval_s, 180)

    if (now - state.anti_afk_last_action) < interval then
        return
    end

    -- Don't act while casting/channeling
    if local_player:get_active_spell_cast_end_time() > 0 then
        return
    end
    if local_player:get_active_channel_cast_end_time() > 0 then
        return
    end

    if mode == ANTI_AFK_TURN then
        if core.input and core.input.turn_right_start and core.input.turn_right_stop then
            core.input.turn_right_start()
            state.anti_afk_last_action = now
            state.anti_afk_turn_stop_at = now + ANTI_AFK_TURN_PULSE_S
        end
    elseif mode == ANTI_AFK_JUMP then
        if core.input and core.input.jump then
            pcall(function() core.input.jump() end)
            state.anti_afk_last_action = now
        end
    end
end

local function update_anti_afk_turn_stop()
    if state.anti_afk_turn_stop_at <= 0.0 then
        return
    end

    local now = core.time()
    if now < state.anti_afk_turn_stop_at then
        return
    end

    state.anti_afk_turn_stop_at = 0.0
    if core.input and core.input.turn_right_stop then
        pcall(function()
            core.input.turn_right_stop()
        end)
    end
end

-- Main update loop
---@param local_player game_object
function fishing_bot:on_update(local_player)
    if not DEPENDENCIES_OK then
        trace_throttled("update_deps_fail", 2.0, "DEPENDENCIES_OK=false")
        return
    end

    if not menu.enable:get_state() then
        -- If the user disables while a turn pulse is active, ensure we stop turning.
        if state.was_enabled then
            state.was_enabled = false
            state.anti_afk_turn_stop_at = 0.0
            if core.input and core.input.turn_right_stop then
                pcall(function()
                    core.input.turn_right_stop()
                end)
            end
        end
        return
    end

    -- Avoid an immediate anti-AFK turn "nudge" right after enabling the module.
    if not state.was_enabled then
        state.was_enabled = true
        state.anti_afk_last_action = core.time()
        state.anti_afk_turn_stop_at = 0.0
    end

    if local_player:is_mounted() then
        trace_throttled("update_skip_mounted", 0.5, "skip: mounted")
        return
    end

    if local_player:is_moving() then
        trace_throttled("update_skip_moving", 0.5, "skip: moving")
        return
    end

    if menu.only_ooc:get_state() and unit_helper:is_in_combat(local_player) then
        log_throttled("update_block_combat", 2.0, "on_update -> blocked (combat)")
        trace_throttled("update_skip_combat", 0.5, "skip: in combat")
        return
    end

    update_anti_afk_turn_stop()

    local now = core.time()
    trace_throttled("update_tick", 0.25,
        "tick now=" .. tostring(now)
            .. " next_cast=" .. tostring(state.next_cast_time)
            .. " last_cast_attempt=" .. tostring(state.last_cast_attempt)
            .. " cast_start=" .. tostring(state.cast_start_time)
            .. " failed=" .. tostring(state.failed_cast_count))

    -- 1. Handle loot (top priority)
    local ok_loot_count, loot_count = pcall(function() return core.game_ui.get_loot_item_count() end)
    if ok_loot_count and loot_count and loot_count > 0 then
        trace_throttled("loot_open", 0.25, "loot_count=" .. tostring(loot_count))
        if (now - state.last_loot_time) > 0.5 then
            for i = 1, loot_count do
                pcall(function() core.input.loot_item(i) end)
            end
            state.last_loot_time = now
            -- Post-loot pause (configurable) + tiny random jitter (10-100ms)
            local min_s = get_slider_ms_as_seconds(menu.post_loot_pause_min_ms, 0.6)
            local max_s = get_slider_ms_as_seconds(menu.post_loot_pause_max_ms, 1.4)
            local jitter_s = rand_between(0.010, 0.100)
            state.next_cast_time = now + rand_between(min_s, max_s) + jitter_s
            log_throttled("loot_items", 0.5, "looted " .. tostring(loot_count) .. " items")
        end
        return
    end

    -- 2. Find bobber
    local bobber = find_bobber()

    -- Anti-AFK nudge (only when not actively fishing)
    if not bobber then
        do_anti_afk(local_player)
    end

    -- 3. Check if bobber has fish
    local has_fish = false
    if bobber then
        state.failed_cast_count = 0

        local ok, result = pcall(function() return bobber:does_bobber_have_fish() end)
        has_fish = ok and result
        log_throttled("bobber_has_fish", 1.0, "does_bobber_have_fish -> ok=" .. tostring(ok) .. " result=" .. tostring(result))

        -- Look at bobber (humanizer)
        if menu.look_at_bobber:get_state() then
            local bpos = bobber:get_position()
            if bpos then
                pcall(function() core.input.look_at(bpos) end)
            end
        end
    end

    -- 4. Fish detected: schedule delayed bobber click
    if has_fish and bobber then
        if not state.pending_bobber then
            local min_s = get_slider_ms_as_seconds(menu.fish_click_delay_min_ms, 0.0)
            local max_s = get_slider_ms_as_seconds(menu.fish_click_delay_max_ms, 0.0)
            local delay_s = rand_between(min_s, max_s)

            state.pending_bobber = __object_safety.guid(bobber)
            state.pending_bobber_use_at = now + delay_s
            trace_throttled("fish_grab_schedule", 0.25,
                "scheduled bobber click in " .. tostring(delay_s) .. "s (min=" .. tostring(min_s) .. ", max=" .. tostring(max_s) .. ")")
        end
    end

    -- If we scheduled a bobber click but the bobber vanished, clear it.
    if state.pending_bobber and (not bobber or not __object_safety.resolve(state.pending_bobber)) then
        trace_throttled("fish_grab_clear", 0.5, "clearing pending bobber click (bobber missing/invalid)")
        state.pending_bobber = nil
        state.pending_bobber_use_at = 0.0
    end

    -- 5. Execute pending bobber click when delay elapsed (independent of current has_fish state)
    if state.pending_bobber and now >= (state.pending_bobber_use_at or 0.0) then
        local pending_bobber=__object_safety.resolve(state.pending_bobber)
        if pending_bobber then
            pcall(function() core.input.use_object(pending_bobber) end)
            log_throttled("fish_grab", 0.5, "use_object(bobber) -> delayed grab")
            state.next_cast_time = now + 1.5
        end
        state.pending_bobber = nil
        state.pending_bobber_use_at = 0.0
        return
    end

    if has_fish and bobber then
        return
    end

    -- Skip if currently casting or channeling
    if local_player:get_active_spell_cast_end_time() > 0 then
        trace_throttled("update_skip_casting", 0.25, "skip: casting")
        return
    end
    if local_player:get_active_channel_cast_end_time() > 0 then
        trace_throttled("update_skip_channeling", 0.25, "skip: channeling")
        return
    end

    -- 6. Failed cast safety: no bobber appeared after casting
    if not bobber and state.cast_start_time > 0 then
        local elapsed = now - state.cast_start_time
        if elapsed > 2.0 then
            state.failed_cast_count = state.failed_cast_count + 1
            state.cast_start_time = 0.0
            core.log("[FishBot] Cast failed / not near water! (" .. tostring(state.failed_cast_count) .. "/3)")
            if state.failed_cast_count >= 3 then
                core.log("[FishBot] Safety: Stopping bot after 3 failed casts.")
                state.failed_cast_count = 0
                menu.enable:set_state(false)
                return
            end
            state.next_cast_time = now + rand_between(2.0, 5.0)
            return
        end
    end

    -- 7. No bobber = need to cast
    if not bobber then
        -- Try to equip fishing pole first
        if try_equip_fishing_pole(local_player) then
            trace_throttled("update_equip", 0.25, "equip attempted")
            return
        end

        -- Try to apply bait
        if try_apply_bait(local_player) then
            trace_throttled("update_bait", 0.25, "bait attempted")
            state.next_cast_time = core.time() + 0.5
            return
        end

        -- Cast fishing
        local cast_ok = try_cast_fishing(local_player)
        trace_throttled("update_cast_result", 0.25, "try_cast_fishing -> " .. tostring(cast_ok))
    end
end

-- Menu render
function fishing_bot:on_menu_render()
    menu.main_tree:render("BxA Fishing", function()
        core.menu.header():render("CORE SETTINGS", color.cyan(220))

        menu.enable:render("Enable BxA Fishing", "Activates the fishing automation")

        if not menu.enable:get_state() then
            core.menu.header():render("Enable to see more settings", color.gray(180))
            return
        end

        menu.only_ooc:render("Only Out of Combat", "Prevents fishing during combat")
        menu.auto_cast:render("Auto Cast Fishing", "Automatically casts fishing spell")
        menu.auto_equip_pole:render("Auto Equip Pole", "Automatically equip best fishing pole from inventory")
        menu.look_at_bobber:render("Look at Bobber", "Face the bobber while fishing (humanizer)")
        menu.debug_logging:render("Debug Logging", "Enable detailed throttled logging")
        menu.trace_logging:render("Trace Logging (Very Verbose)", "High-volume trace logs for diagnosing fishing issues")

        core.menu.header():render("TIMING", color.green(220))

        menu.fish_click_delay_min_ms:render("Fish Click Delay Min (ms)", "Minimum delay before clicking the bobber after a bite")
        menu.fish_click_delay_max_ms:render("Fish Click Delay Max (ms)", "Maximum delay before clicking the bobber after a bite")
        menu.post_loot_pause_min_ms:render("Post Loot Pause Min (ms)", "Minimum delay after looting before recast")
        menu.post_loot_pause_max_ms:render("Post Loot Pause Max (ms)", "Maximum delay after looting before recast")
        menu.cast_delay_min_ms:render("Cast Delay Min (ms)", "Minimum delay between casts")
        menu.cast_delay_max_ms:render("Cast Delay Max (ms)", "Maximum delay between casts")

        core.menu.header():render("ANTI-AFK", color.yellow(220))

        menu.anti_afk_mode:render("Anti-AFK Mode", {"Off", "Turn", "Jump"})
        if menu.anti_afk_mode:get() > 1 then
            menu.anti_afk_interval_s:render("Interval (sec)", "Time between anti-AFK actions")
        end
    end)
end

-- Register with rotation_settings_ui
if ok_astro and rotation_settings_ui and rotation_settings_ui.register_extension_tab then
    rotation_settings_ui.register_extension_tab({
        id = "fishing_bot",
        label = "Fishing Bot"
    }, function(tab)
        tab:checkbox_grid({
            label = "Core Controls",
            columns = 2,
            elements = {
                { element = menu.enable, label = "Enable Fishing Bot" },
                { element = menu.auto_cast, label = "Auto Cast Fishing" },
                { element = menu.auto_equip_pole, label = "Auto Equip Pole" },
                { element = menu.look_at_bobber, label = "Look at Bobber" },
                { element = menu.only_ooc, label = "Only Out Of Combat" },
                { element = menu.debug_logging, label = "Debug Logging" },
                { element = menu.trace_logging, label = "Trace Logging" },
            }
        })
    
        tab:combo_list({
            label = "Anti-AFK",
            elements = {
                {
                    element = menu.anti_afk_mode,
                    label = "Anti-AFK Mode",
                    options = { "Off", "Turn", "Jump" }
                }
            }
        })
    
        tab:slider_list({
            label = "Timing",
            elements = {
                { element = menu.fish_click_delay_min_ms, label = "Fish Click Delay Min (ms)", suffix = "ms", bounds = { min = 0, max = 700 } },
                { element = menu.fish_click_delay_max_ms, label = "Fish Click Delay Max (ms)", suffix = "ms", bounds = { min = 0, max = 700 } },
                { element = menu.post_loot_pause_min_ms, label = "Post Loot Pause Min (ms)", suffix = "ms", bounds = { min = 0, max = 3000 } },
                { element = menu.post_loot_pause_max_ms, label = "Post Loot Pause Max (ms)", suffix = "ms", bounds = { min = 0, max = 3000 } },
                { element = menu.cast_delay_min_ms, label = "Cast Delay Min (ms)", suffix = "ms", bounds = { min = 100, max = 2000 } },
                { element = menu.cast_delay_max_ms, label = "Cast Delay Max (ms)", suffix = "ms", bounds = { min = 100, max = 2000 } },
                { element = menu.anti_afk_interval_s, label = "Anti-AFK Interval (sec)", suffix = "s", bounds = { min = 60, max = 300 } },
            }
        })
    end)
end

return fishing_bot
