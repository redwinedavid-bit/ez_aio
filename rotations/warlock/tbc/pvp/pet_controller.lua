local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock PvP Pet Controller (TBC)
-- Intelligent pet ability management for PvP:
--   - Spell Lock: Priority interrupt (heals > CC > damage)
--   - Devour Magic: Self-purge + enemy buff removal
--   - Seduction: CC secondary target
--   - Fel Domination + Resummon: Pet dies -> instant resummon
--   - Voidwalker Sacrifice: Emergency shield
-- ============================================================================

local pet_controller = {}

---@type izi_sdk
local izi = require("common/izi_sdk")
---@type enums
local enums = require("common/enums")

local spells = require("rotations/warlock/tbc/spells")

-- Pet NPC IDs
local PET_IMP         = 416
local PET_VOIDWALKER  = 1860
local PET_SUCCUBUS    = 1863
local PET_FELHUNTER   = 417
local PET_FELGUARD    = 17252

-- Pet Spell IDs
local SPELL_LOCK_ID    = 19244
local DEVOUR_MAGIC_ID  = 19746
local SEDUCTION_ID     = 6358
local VW_SACRIFICE_IDS = { 27273, 19443, 19442, 19441, 19440, 19438, 7812 }

-- Caster classes (for Spell Lock priority)
local CLASS_PRIEST  = 5
local CLASS_MAGE    = 8
local CLASS_WARLOCK = 9
local CLASS_DRUID   = 11
local CLASS_SHAMAN  = 7
local CLASS_PALADIN = 2

-- Important enemy buffs to purge with Devour Magic
local PURGEABLE_BUFFS = {
    17,     -- Power Word: Shield
    1022,   -- Hand of Protection / Blessing of Protection
    13031,  -- Ice Barrier (Mage)
    11426,  -- Ice Barrier rank
    33405,  -- Ice Barrier TBC rank
    6346,   -- Fear Ward
    1020,   -- Divine Shield (Paladin) -- can't actually devour, but try
}

-- State
local last_spell_lock_ms = 0
local SPELL_LOCK_THROTTLE_MS = 1500  -- Don't spam Spell Lock faster than 1.5s
local last_resummon_ms = 0
local RESUMMON_THROTTLE_MS = 5000
local last_pet_seen_alive_ms = 0

local last_pet_utility_ms = 0
local PET_UTILITY_THROTTLE_MS = 2000
local last_seduce_ms = 0
local SEDUCE_THROTTLE_MS = 2000

-- ============================================================================
-- PVP DEBUG LOGGING
-- ============================================================================
local pvp_log_last_times = {}
local pvp_log_menu_ref = nil

local function pvp_log(key, interval, message)
    if not pvp_log_menu_ref or not pvp_log_menu_ref.pvp_debug_logging then return end
    if pvp_log_menu_ref.pvp_debug_logging:get_state() ~= true then return end
    local now = core.time()
    if interval > 0 then
        local last = pvp_log_last_times[key] or 0
        if (now - last) < interval then return end
        pvp_log_last_times[key] = now
    end
    core.log(message)
end

local function safe_name(unit)
    if not unit or not unit.get_name then return "nil" end
    return unit:get_name() or "unknown"
end

-- Pet action timing (helps spot downtime caused by pet ability spam/throttles)
local last_pet_action_ms = 0
local last_pet_action_label = "none"
local last_pet_action_ability_id = 0

local function pet_action(label, ability_id, target)
    local now = core.game_time()
    local dt = last_pet_action_ms > 0 and (now - last_pet_action_ms) or 0
    local tname = target and safe_name(target) or "none"
    local aid = tonumber(ability_id) or 0
    pvp_log("pet.action." .. tostring(label) .. "." .. tostring(aid), 0, string.format(
        "[Warlock][PvP][Pet][ACTION] dt=%dms label=%s ability_id=%d target=%s (prev=%s/%d)",
        dt, tostring(label), aid, tname, tostring(last_pet_action_label), tonumber(last_pet_action_ability_id) or 0
    ))
    last_pet_action_ms = now
    last_pet_action_label = tostring(label)
    last_pet_action_ability_id = aid
end

local PET_NAMES = {
    [416] = "Imp", [1860] = "Voidwalker", [1863] = "Succubus",
    [417] = "Felhunter", [17252] = "Felguard",
}

-- ============================================================================
-- UTILITY
-- ============================================================================

local function get_pet_info(player)
    local pet = player:get_pet()
    if not pet or not pet:is_valid() then return nil, nil, false end
    local alive = pet:is_alive()
    local ok, npc_id = pcall(function() return pet:get_npc_id() end)
    if alive then
        last_pet_seen_alive_ms = core.game_time()
    end
    return pet, (ok and tonumber(npc_id) or nil), alive
end

local function is_caster_class(class_id)
    return class_id == CLASS_PRIEST or class_id == CLASS_MAGE
        or class_id == CLASS_WARLOCK or class_id == CLASS_DRUID
        or class_id == CLASS_SHAMAN or class_id == CLASS_PALADIN
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

local function hp_pct(unit)
    if not unit or not unit.get_health_percentage then return 0 end
    return tonumber(unit:get_health_percentage()) or 0
end

local function get_pet_spell_id_by_name_keywords(keywords)
    if not core.spell_book or not core.spell_book.get_pet_spells then return nil end
    local ok, pet_spells = pcall(core.spell_book.get_pet_spells)
    if not ok or type(pet_spells) ~= "table" then return nil end

    local function norm(s)
        s = tostring(s or ""):lower()
        s = s:gsub("%s+", " ")
        return s
    end

    local want = {}
    for _, k in ipairs(keywords or {}) do
        want[#want + 1] = norm(k)
    end

    local function match(name)
        local n = norm(name)
        for _, w in ipairs(want) do
            if w ~= "" and n:find(w, 1, true) ~= nil then
                return true
            end
        end
        return false
    end

    for k, v in pairs(pet_spells) do
        if type(v) == "table" then
            local id = tonumber(v.id or v.spell_id or v[1])
            local name = v.name or v[2]
            if id and name and match(name) then return id end
        elseif type(k) == "number" and type(v) == "string" then
            if match(v) then return tonumber(k) end
        end
    end

    return nil
end

local function try_pet_utility(player, menu)
    local pet, npc_id, alive = get_pet_info(player)
    if not alive or not pet or not npc_id then return false end
    if not core.input or not core.input.pet_cast_target_spell then return false end

    local now = core.game_time()
    if (now - last_pet_utility_ms) < PET_UTILITY_THROTTLE_MS then return false end

    -- Voidwalker: Consume Shadows (out of combat only, keep pet healthy)
    if npc_id == PET_VOIDWALKER and menu_enabled(menu, "pvp_pet_consume_shadows", true) then
        if player:is_in_combat() ~= true and hp_pct(pet) < 95 then
            local consume_id = get_pet_spell_id_by_name_keywords({
                "consume shadows", "schatten verzehren", "consume", "verzehren"
            })
            if consume_id then
                local ok_cast, result = pcall(core.input.pet_cast_target_spell, consume_id, pet)
                if ok_cast and result then
                    last_pet_utility_ms = now
                    pvp_log("pet.utility.consume", 0, "[Warlock][PvP][Pet] Consume Shadows")
                    pet_action("consume_shadows", consume_id, pet)
                    return true
                end
            end
        end
    end

    -- Imp: Phase Shift (keep it safe) / Fire Shield
    if npc_id == PET_IMP then
        if menu_enabled(menu, "pvp_pet_phase_shift", false) then
            local phase_id = get_pet_spell_id_by_name_keywords({
                "phase shift", "phasenverschiebung", "phase"
            })
            if phase_id then
                local ok_cast, result = pcall(core.input.pet_cast_target_spell, phase_id, pet)
                if ok_cast and result then
                    last_pet_utility_ms = now
                    pvp_log("pet.utility.phase", 0, "[Warlock][PvP][Pet] Phase Shift")
                    pet_action("phase_shift", phase_id, pet)
                    return true
                end
            end
        end

        if menu_enabled(menu, "pvp_pet_fire_shield", false) then
            local fire_id = get_pet_spell_id_by_name_keywords({
                "fire shield", "feuerschild", "shield"
            })
            if fire_id then
                local ok_cast, result = pcall(core.input.pet_cast_target_spell, fire_id, player)
                if ok_cast and result then
                    last_pet_utility_ms = now
                    pvp_log("pet.utility.fire", 0, "[Warlock][PvP][Pet] Fire Shield")
                    pet_action("fire_shield", fire_id, player)
                    return true
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- SPELL LOCK (Felhunter Interrupt)
-- ============================================================================

--- Try to interrupt the target with Spell Lock.
--- Priority: Heal casts > CC casts > any interruptable cast/channel.
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
function pet_controller.try_spell_lock(player, target, menu)
    if not menu_enabled(menu, "auto_spell_lock", true) then
        pvp_log("pet.spelllock.guard", 2000, "[Warlock][PvP][Pet] Spell Lock disabled in menu")
        return false
    end
    if not target then return false end

    local now = core.game_time()
    if (now - last_spell_lock_ms) < SPELL_LOCK_THROTTLE_MS then
        pvp_log("pet.spelllock.guard", 2000, "[Warlock][PvP][Pet] Spell Lock throttled")
        return false
    end

    local _, npc_id, alive = get_pet_info(player)
    if not alive or npc_id ~= PET_FELHUNTER then
        pvp_log("pet.spelllock.guard", 30000, string.format("[Warlock][PvP][Pet] Spell Lock blocked: pet=%s alive=%s", PET_NAMES[npc_id] or "none", tostring(alive)))
        return false
    end

    local ok_cast, is_casting = pcall(function() return target:is_casting_spell() end)
    local ok_chan, is_channeling = pcall(function() return target:is_channelling_spell() end)

    local should_interrupt = false
    if ok_cast and is_casting then
        local ok_int, interruptable = pcall(function() return target:is_active_spell_interruptable() end)
        if ok_int and interruptable then should_interrupt = true end
    elseif ok_chan and is_channeling then
        should_interrupt = true
    end

    if not should_interrupt then
        pvp_log("pet.spelllock.guard", 2000, "[Warlock][PvP][Pet] Spell Lock: target not casting/channeling interruptable spell")
        return false
    end

    -- Also scan nearby enemies - interrupt healers first
    local enemies = izi.enemies(30)
    if enemies then
        for _, enemy in __object_safety.live_ipairs(enemies) do
            if enemy:is_valid_enemy() and enemy:is_alive() then
                local eclass = 0
                pcall(function() eclass = enemy:get_class() end)
                if (eclass == CLASS_PRIEST or eclass == CLASS_DRUID or eclass == CLASS_PALADIN or eclass == CLASS_SHAMAN) then
                    local e_casting = false
                    pcall(function() e_casting = enemy:is_casting_spell() end)
                    local e_interruptable = false
                    pcall(function() e_interruptable = enemy:is_active_spell_interruptable() end)
                    if e_casting and e_interruptable and core.input and core.input.pet_cast_target_spell then
                        local ok, result = pcall(core.input.pet_cast_target_spell, SPELL_LOCK_ID, enemy)
                        if ok and result then
                            last_spell_lock_ms = now
                            pvp_log("pet.spelllock", 0, "[Warlock][PvP][Pet] Spell Lock interrupted " .. safe_name(enemy) .. " (healer priority)")
                            pet_action("spell_lock", SPELL_LOCK_ID, enemy)
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Fall back to interrupting current target
    if core.input and core.input.pet_cast_target_spell then
        local ok, result = pcall(core.input.pet_cast_target_spell, SPELL_LOCK_ID, target)
        if ok and result then
            last_spell_lock_ms = now
            pvp_log("pet.spelllock", 0, "[Warlock][PvP][Pet] Spell Lock interrupted " .. safe_name(target) .. " (current target)")
            pet_action("spell_lock", SPELL_LOCK_ID, target)
            return true
        end
    end

    return false
end

-- ============================================================================
-- DEVOUR MAGIC (Felhunter Purge)
-- ============================================================================

--- Try to self-purge harmful Magic/Curse debuffs, or remove important enemy buffs.
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
function pet_controller.try_devour_magic(player, target, menu)
    local _, npc_id, alive = get_pet_info(player)
    if not alive or npc_id ~= PET_FELHUNTER then
        pvp_log("pet.devour.guard", 30000, string.format("[Warlock][PvP][Pet] Devour Magic blocked: pet=%s alive=%s", PET_NAMES[npc_id] or "none", tostring(alive)))
        return false
    end
    if not core.input or not core.input.pet_cast_target_spell then return false end

    -- 1. Self-purge: Remove Magic (1) or Curse (4) debuffs from player
    local ok_debuff, debuffs = pcall(function() return player:get_all_debuffs() end)
    if ok_debuff and debuffs then
        for _, d in ipairs(debuffs) do
            local dtype = d.type or d.dispel_type
            if dtype == enums.buff_type.MAGIC or dtype == enums.buff_type.CURSE then
                local ok, result = pcall(core.input.pet_cast_target_spell, DEVOUR_MAGIC_ID, player)
                if ok and result then
                    local dtype_label = (dtype == enums.buff_type.MAGIC) and "Magic" or "Curse"
                    pvp_log("pet.devour", 0, "[Warlock][PvP][Pet] Devour Magic self-purge (" .. dtype_label .. " debuff)")
                    pet_action("devour_self", DEVOUR_MAGIC_ID, player)
                    return true
                end
            end
        end
    end

    -- 2. Enemy purge: Remove important buffs
    if target and target:is_valid_enemy() and target:is_alive() then
        for _, buff_id in ipairs(PURGEABLE_BUFFS) do
            local ok_buff, has_buff = pcall(function() return target:buff_up(buff_id) end)
            if ok_buff and has_buff then
                local ok, result = pcall(core.input.pet_cast_target_spell, DEVOUR_MAGIC_ID, target)
                if ok and result then
                    pvp_log("pet.devour", 0, string.format("[Warlock][PvP][Pet] Devour Magic purged buff %d from %s", buff_id, safe_name(target)))
                    pet_action("devour_enemy", DEVOUR_MAGIC_ID, target)
                    return true
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- SEDUCTION (Succubus CC)
-- ============================================================================

--- CC a secondary target (not the main target) with Seduction.
---@param player game_object
---@param target game_object  main target (will NOT be seduced)
---@param menu table
---@return boolean
function pet_controller.try_seduce(player, target, menu)
    if not menu_enabled(menu, "use_seduce_pvp", true) then
        pvp_log("pet.seduce.guard", 2000, "[Warlock][PvP][Pet] Seduce disabled in menu")
        return false
    end

    local now = core.game_time()
    if (now - last_seduce_ms) < SEDUCE_THROTTLE_MS then
        pvp_log("pet.seduce.guard", 2000, "[Warlock][PvP][Pet] Seduce throttled")
        return false
    end

    local _, npc_id, alive = get_pet_info(player)
    if not alive or npc_id ~= PET_SUCCUBUS then
        pvp_log("pet.seduce.guard", 30000, string.format("[Warlock][PvP][Pet] Seduce blocked: pet=%s alive=%s", PET_NAMES[npc_id] or "none", tostring(alive)))
        return false
    end
    if not core.input or not core.input.pet_cast_target_spell then return false end

    local enemies = izi.enemies(30)
    if not enemies then
        pvp_log("pet.seduce.guard", 2000, "[Warlock][PvP][Pet] Seduce: no enemies in range")
        return false
    end

    -- Separate healers from other targets (healers are higher priority for Seduce)
    local healer_targets = {}
    local other_targets = {}
    for _, enemy in __object_safety.live_ipairs(enemies) do
        -- Compare by GUID, not Lua reference (enemies list returns fresh objects each call)
        local same_as_target = false
        if target and target.get_guid and enemy.get_guid then
            local ok1, g1 = pcall(function() return enemy:get_guid() end)
            local ok2, g2 = pcall(function() return target:get_guid() end)
            if ok1 and ok2 and g1 and g2 and g1 == g2 then same_as_target = true end
        end
        if enemy:is_valid_enemy() and enemy:is_alive() and not same_as_target then
            -- Don't seduce already CC'd targets
            local is_cc = false
            pcall(function()
                if enemy.CC then
                    is_cc = enemy:is_cc(1000, enemy.CC.ANY)
                end
            end)
            if not is_cc then
                local eclass = 0
                pcall(function() eclass = enemy:get_class() end)
                if eclass == CLASS_PRIEST or eclass == CLASS_DRUID or eclass == CLASS_PALADIN or eclass == CLASS_SHAMAN then
                    table.insert(healer_targets, enemy)
                else
                    table.insert(other_targets, enemy)
                end
            end
        end
    end

    -- Try healers first
    for _, e in ipairs(healer_targets) do
        local ok, result = pcall(core.input.pet_cast_target_spell, SEDUCTION_ID, e)
        if ok and result then
            last_seduce_ms = now
            pvp_log("pet.seduce", 0, "[Warlock][PvP][Pet] Seduce on " .. safe_name(e) .. " (healer priority)")
            pet_action("seduce", SEDUCTION_ID, e)
            return true
        end
    end
    -- Then other targets
    for _, e in ipairs(other_targets) do
        local ok, result = pcall(core.input.pet_cast_target_spell, SEDUCTION_ID, e)
        if ok and result then
            last_seduce_ms = now
            pvp_log("pet.seduce", 0, "[Warlock][PvP][Pet] Seduce on " .. safe_name(e) .. " (secondary)")
            pet_action("seduce", SEDUCTION_ID, e)
            return true
        end
    end

    pvp_log("pet.seduce.guard", 2000, string.format("[Warlock][PvP][Pet] Seduce: no valid targets (healers=%d others=%d)", #healer_targets, #other_targets))
    return false
end

-- ============================================================================
-- FEL DOMINATION + RESUMMON
-- ============================================================================

--- When pet dies, use Fel Domination for instant resummon.
---@param player game_object
---@param menu table
---@return boolean
function pet_controller.try_fel_domination_resummon(player, menu)
    if not menu_enabled(menu, "use_fel_domination", true) then
        pvp_log("pet.resummon.guard", 2000, "[Warlock][PvP][Pet] Fel Domination disabled in menu")
        return false
    end

    local now = core.game_time()
    if (now - last_resummon_ms) < RESUMMON_THROTTLE_MS then
        pvp_log("pet.resummon", 1000, "[Warlock][PvP][Pet] Resummon throttled")
        return false
    end

    -- Only if pet is dead or missing
    local pet = player:get_pet()
    if pet and pet:is_valid() and pet:is_alive() then
        pvp_log("pet.resummon.guard", 2000, "[Warlock][PvP][Pet] Resummon skipped: pet alive")
        return false
    end

    -- Smooth out transient "pet missing" frames (common during arena load / UI hiccups)
    if last_pet_seen_alive_ms > 0 and (now - last_pet_seen_alive_ms) < 1500 then
        pvp_log("pet.resummon.guard", 2000, "[Warlock][PvP][Pet] Resummon skipped: pet missing transiently")
        return false
    end

    -- Try Fel Domination first (makes next summon instant)
    if spells.fel_domination:is_learned() and spells.fel_domination:is_castable() then
        if spells.fel_domination:cast(player) then
            pvp_log("pet.resummon", 0, "[Warlock][PvP][Pet] Fel Domination cast (instant summon)")
            last_resummon_ms = now
            pet_action("fel_dom", spells.fel_domination:id(), player)
            return true
        end
    end

    -- Summon preferred pet
    if player:is_moving() then
        pvp_log("pet.resummon", 1000, "[Warlock][PvP][Pet] Resummon blocked: moving")
        return false
    end
    local preferred = menu_number(menu, "preferred_pet", 4)
    if menu and menu.pvp_preferred_pet and menu.pvp_preferred_pet.get then
        local ok, v = pcall(function() return menu.pvp_preferred_pet:get() end)
        if ok and tonumber(v) then
            preferred = tonumber(v)
        end
    end
    local candidates = {
        [1] = spells.summon_felguard,
        [2] = spells.summon_imp,
        [3] = spells.summon_succubus,
        [4] = spells.summon_felhunter,
        [5] = spells.summon_voidwalker,
    }
    local summon = candidates[preferred] or spells.summon_felhunter
    local pet_name = PET_NAMES[({[1]=17252,[2]=416,[3]=1863,[4]=417,[5]=1860})[preferred] or 417] or "pet"
    if summon and summon:is_learned() and summon:is_castable({ skip_facing = true }) then
        if summon:cast(player) then
            pvp_log("pet.resummon", 0, "[Warlock][PvP][Pet] Summoning " .. pet_name)
            last_resummon_ms = now
            pet_action("summon." .. tostring(pet_name), summon:id(), player)
            return true
        end
    end

    return false
end

-- ============================================================================
-- VOIDWALKER SACRIFICE (Emergency Shield)
-- ============================================================================

--- Sacrifice Voidwalker for an emergency absorb shield.
---@param player game_object
---@param menu table
---@return boolean
function pet_controller.try_voidwalker_sacrifice(player, menu)
    if not menu_enabled(menu, "use_vw_sacrifice", true) then
        pvp_log("pet.vwsac.guard", 2000, "[Warlock][PvP][Pet] VW Sacrifice disabled in menu")
        return false
    end

    local vw_sac_hp = menu_number(menu, "vw_sacrifice_hp_pct", 20)
    local p_hp = hp_pct(player)
    if p_hp > vw_sac_hp then
        pvp_log("pet.vwsac.guard", 2000, string.format("[Warlock][PvP][Pet] VW Sacrifice: HP=%d%% > threshold=%d%%", p_hp, vw_sac_hp))
        return false
    end

    local pet, npc_id, alive = get_pet_info(player)
    if not alive or npc_id ~= PET_VOIDWALKER then
        pvp_log("pet.vwsac.guard", 2000, string.format("[Warlock][PvP][Pet] VW Sacrifice blocked: pet=%s alive=%s", PET_NAMES[npc_id] or "none", tostring(alive)))
        return false
    end
    if not core.input or not core.input.pet_cast_target_spell then return false end

    -- Try each rank of Sacrifice (highest first)
    for _, sac_id in ipairs(VW_SACRIFICE_IDS) do
        local ok, result = pcall(core.input.pet_cast_target_spell, sac_id, player)
        if ok and result then
            pvp_log("pet.vwsac", 0, string.format("[Warlock][PvP][Pet] VW Sacrifice at hp=%d%% (thresh=%d%%)", p_hp, vw_sac_hp))
            pet_action("vw_sac", sac_id, player)
            return true
        end
    end

    return false
end

-- ============================================================================
-- COMBINED PET UPDATE (call from pvp/init.lua each frame)
-- ============================================================================

--- Run all pet PvP logic. Returns true if any action was taken.
---@param player game_object
---@param target game_object
---@param menu table
---@return boolean
function pet_controller.execute(player, target, menu)
    pvp_log_menu_ref = menu
    -- 1. VW Sacrifice (highest emergency priority)
    if pet_controller.try_voidwalker_sacrifice(player, menu) then return true end

    -- 2. Spell Lock (interrupt)
    if pet_controller.try_spell_lock(player, target, menu) then return true end

    -- 3. Devour Magic (purge)
    if pet_controller.try_devour_magic(player, target, menu) then return true end

    -- 4. Seduction (CC secondary)
    if pet_controller.try_seduce(player, target, menu) then return true end

    -- 4.5 Pet utility (Consume Shadows / Phase Shift / Fire Shield)
    if try_pet_utility(player, menu) then return true end

    -- 5. Fel Domination Resummon (pet died)
    if pet_controller.try_fel_domination_resummon(player, menu) then return true end

    return false
end

return pet_controller
