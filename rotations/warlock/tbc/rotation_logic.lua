local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock APL (TBC Classic) - Guide-Conformant Implementation
-- Sources: Wowhead PvE, Icy-Veins Destruction, Wowhead PvP Arena
-- ============================================================================

local rotation_logic = {}

---@type izi_sdk
local izi = require("common/izi_sdk")
---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")
---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

local spells = require("rotations/warlock/tbc/spells")
local pvp_module = require("rotations/warlock/tbc/pvp/init")
local dot_apply_guard = require("shared/dot_apply_guard")

local create_healthstone_spells = {
    spells.create_healthstone_master,
    spells.create_healthstone_major,
    spells.create_healthstone_greater,
    spells.create_healthstone_normal,
    spells.create_healthstone_lesser,
    spells.create_healthstone_minor,
    spells.create_healthstone, -- fallback for older/odd clients / sdk rank selection
}

local SOUL_SHARD_ITEM_ID = 6265
local soul_shard = izi.item(SOUL_SHARD_ITEM_ID)

-- Healthstone ITEM IDs (highest rank first) -- includes Improved Healthstone talent variants
local healthstone_item = izi.item({
    22103, 22104, 22105, -- Master Healthstone (base, imp1, imp2)
    9421,  19012, 19013, -- Major Healthstone
    5510,  19010, 19011, -- Greater Healthstone
    5509,  19008, 19009, -- Healthstone
    5511,  19006, 19007, -- Lesser Healthstone
    5512,  19004, 19005, -- Minor Healthstone
})

-- Spellstone ITEM IDs (highest rank first)
-- Create Spellstone (2362/17727/17728) can conjure different ranks depending on what you know.
-- Include the low-rank "Spellstone" item id (5522) so OOC creation doesn't spam forever at low levels.
local spellstone_item = izi.item({ 22646, 13603, 13602, 5522 }) -- Master, Major, Greater, Spellstone

-- Soulstone ITEM IDs (highest rank first). Used to avoid spamming Create Soulstone when one is already in bags.
local soulstone_item = izi.item({ 22116, 16896, 16895, 16893, 16892, 5232 }) -- Master, Major, Greater, Soulstone, Lesser, Minor

-- ============================================================================
-- STATE TRACKING
-- ============================================================================
local last_summon_finish_ms = 0
local last_pet_attack_ms = 0
local PET_ATTACK_THROTTLE_MS = 2000 -- Nur alle 2 Sekunden pet_attack aufrufen

-- Soul Link: raw buff ID (like ERA code) + cast throttle to prevent spam
-- Some clients report Soul Link aura with a different spell id than the cast id.
-- Keep a small list and also fall back to pet aura to avoid re-casting forever.
local SOUL_LINK_BUFFS = { 19028, 25228 }
local last_soul_link_attempt_ms = 0
local SOUL_LINK_THROTTLE_MS = 2000
local soul_link_assumed_until_ms = 0

-- Arena prep: VW Sacrifice buff/spell ids (check on player buff + pet cast)
local VW_SACRIFICE_IDS = { 27273, 19443, 19442, 19441, 19440, 19438, 7812 }
local arena_prep_last_attempt_ms = 0
local ARENA_PREP_THROTTLE_MS = 1500

-- DoT refresh windows (ms) for TBC.
-- Note: TBC does NOT have "Pandemic". Most DoTs should be refreshed at/after expiry to avoid clipping.
-- We still allow a small leeway to account for cast time + latency so we don't drop uptime on casted DoTs.
local DOT_REFRESH_LEEWAY_MS_INSTANT = 250

-- DoT apply guard (spell_id + target_guid). Prevents duplicate casts when the debuff cache updates late.
-- NOTE: Must be per-target; a global per-spell gate breaks multi-dotting and can be cleared by other units casting the same spell id.
local dot_guard = dot_apply_guard.new({ default_grace_ms = DOT_REFRESH_LEEWAY_MS_INSTANT + 250 })

-- Buff IDs
local SHADOW_TRANCE_BUFF = 17941       -- Nightfall proc: instant Shadow Bolt
local ISB_BUFF = 17800                 -- Improved Shadow Bolt: +20% shadow damage on target
local SACRIFICE_SUCCUBUS_BUFF = 18791  -- Demonic Sacrifice (Succubus): +15% shadow damage
local SACRIFICE_IMP_BUFF = 18789       -- Demonic Sacrifice (Imp): +15% fire damage
local SACRIFICE_VW_BUFF = 18790        -- Demonic Sacrifice (Voidwalker): HP regen
local SACRIFICE_FH_BUFF = 18792        -- Demonic Sacrifice (Felhunter): mana regen

-- Pet NPC IDs (for sacrifice setup checks)
local PET_IMP = 416
local PET_VOIDWALKER = 1860
local PET_FELHUNTER = 417
local PET_SUCCUBUS = 1863

-- On-use trinkets (equipped) / drums
local TRINKET_SLOT_1 = 13
local TRINKET_SLOT_2 = 14
local TRINKET_CACHE_INTERVAL_MS = 5000
local trinket_cache = { last_ms = 0, items = {} }

-- Drums of Battle (TBC) - optional burst item
local drums_battle_item = izi.item(29529)

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function num(v, fallback) return tonumber(v) or fallback end

-- Forward declarations (Lua locals are not visible before declaration)
local pve_sacrifice_plan

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

local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then return fallback end
    local ok, v = pcall(function() return menu[key]:get() end)
    return ok and num(v, fallback) or fallback
end

local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then return fallback end
    local ok, v = pcall(function() return menu[key]:get_state() end)
    if ok then return v end
    return fallback
end

local function now_ms()
    local ok, v = pcall(function() return core.game_time() end)
    return ok and num(v, 0) or 0
end

local function ping_ms()
    local ok, v = pcall(function() return core.get_ping() end)
    return ok and num(v, 0) or 0
end

---@param spell izi_spell|number
---@param target game_object
---@param is_instant boolean
local function dot_guard_after_cast(spell, target, is_instant)
    if not target then return end

    local grace_ms = DOT_REFRESH_LEEWAY_MS_INSTANT + (ping_ms() * 2) + 150

    if is_instant == true then
        dot_guard:on_cast_requested(spell, target, grace_ms)
        return
    end

    local cast_ms = 0
    if type(spell) == "table" and spell.cast_time_ms then
        pcall(function()
            cast_ms = num(spell:cast_time_ms(), 0)
        end)
    end

    if cast_ms and cast_ms > 0 then
        dot_guard:on_casting(spell, target, core.game_time() + cast_ms, grace_ms)
    else
        dot_guard:on_cast_requested(spell, target, grace_ms)
    end
end

local function keybind_toggle_enabled(menu, key, fallback)
    if not menu or not menu[key] then return fallback end
    local ok, v = pcall(function()
        return plugin_helper:is_toggle_enabled(menu[key]) == true
    end)
    if ok then return v end
    return fallback
end

local function want_single_target(menu)
    return keybind_toggle_enabled(menu, "single_target_toggle", false) == true
end

local function want_force_aoe(menu)
    return keybind_toggle_enabled(menu, "aoe_dot_toggle", false) == true
end

local function want_burst(menu)
    if keybind_toggle_enabled(menu, "burst_toggle", false) ~= true then
        return false
    end
    if menu and menu.use_burst_cooldowns and menu.use_burst_cooldowns.get_state then
        return menu.use_burst_cooldowns:get_state() == true
    end
    return true
end

local function dot_min_ttd_sec(menu)
    return menu_number(menu, "dot_min_ttd_sec", 8)
end

---@param target game_object
---@param spell izi_spell
---@param refresh_window_ms integer
---@param never_refresh_early boolean|nil
---@return boolean
local function needs_refresh(target, spell, refresh_window_ms, never_refresh_early)
    if not target or not spell or not spell.id then return false end
    local spell_id = spell:id()
    if target:debuff_down(spell_id) then
        return true
    end
    if never_refresh_early == true then
        return false
    end
    local ok, remains = pcall(function() return target:debuff_remains_ms(spell_id) end)
    return ok and remains and remains > 0 and remains <= (refresh_window_ms or DOT_REFRESH_LEEWAY_MS_INSTANT)
end

---@param spell izi_spell
---@param is_instant boolean|nil
---@return integer
local function dot_refresh_window_ms(spell, is_instant)
    if is_instant == true then
        return DOT_REFRESH_LEEWAY_MS_INSTANT + (ping_ms() * 2)
    end

    local cast_ms = 0
    pcall(function()
        cast_ms = num(spell:cast_time_ms(), 0)
    end)
    if cast_ms <= 0 then
        return DOT_REFRESH_LEEWAY_MS_INSTANT + (ping_ms() * 2)
    end
    return cast_ms + (ping_ms() * 2) + 150
end

---@param player game_object
---@return table<any>
local function get_usable_trinkets(player)
    local now = now_ms()
    if (now - (trinket_cache.last_ms or 0)) < TRINKET_CACHE_INTERVAL_MS then
        return trinket_cache.items or {}
    end
    trinket_cache.last_ms = now
    trinket_cache.items = {}

    if not player or not player.get_equipped_items then
        return trinket_cache.items
    end

    local ok, equipped = pcall(function()
        return player:get_equipped_items()
    end)
    if not ok or type(equipped) ~= "table" then
        return trinket_cache.items
    end

    for _, entry in ipairs(equipped) do
        if entry and entry.slot_id and entry.object then
            local slot_id = entry.slot_id
            if slot_id == TRINKET_SLOT_1 or slot_id == TRINKET_SLOT_2 then
                local item_id = nil
                pcall(function()
                    item_id = entry.object:get_item_id()
                end)
                if type(item_id) == "number" and item_id > 0 then
                    local it = izi.item(item_id)
                    if it and it.is_usable and it.cooldown_up and it:is_usable() and it:cooldown_up() then
                        table.insert(trinket_cache.items, it)
                    end
                end
            end
        end
    end

    return trinket_cache.items
end

local prep_log_last_times = {}
local function prep_log(menu, key, interval, message)
    if not menu or not menu.pvp_debug_logging or menu.pvp_debug_logging:get_state() ~= true then return end
    if menu.pvp_debug_verbose and menu.pvp_debug_verbose:get_state() ~= true then return end
    local now = core.time()
    if interval and interval > 0 then
        local last = prep_log_last_times[key] or 0
        if (now - last) < interval then return end
        prep_log_last_times[key] = now
    end
    core.log(message)
end

local function soul_link_is_up(player)
    local now = core.game_time()
    if soul_link_assumed_until_ms > now then return true end
    if player and player:buff_up(SOUL_LINK_BUFFS) then return true end

    local pet = player and player:get_pet()
    if pet and pet:is_valid() and pet:is_alive() and pet:buff_up(SOUL_LINK_BUFFS) then
        return true
    end

    return false
end

local function has_vw_sacrifice(player)
    if not player then return false end
    return player:buff_up(VW_SACRIFICE_IDS)
end

local function in_arena_prep()
    local ok_arena, arena = pcall(function()
        return (izi.is_in_arena and izi.is_in_arena()) or (izi.is_arena and izi.is_arena()) or false
    end)
    if not ok_arena or arena ~= true then return false end

    local ok_state, state = pcall(function() return core.game_ui.get_battlefield_state() end)
    return ok_state and state == 2 -- 2=Prep
end

local function try_arena_prep(player, menu)
    if not menu_enabled(menu, "arena_prep_enabled", true) then return false end
    if not in_arena_prep() then return false end
    if not player or player:is_moving() or player:is_channeling_or_casting() then return false end

    local now = core.game_time()
    if (now - arena_prep_last_attempt_ms) < ARENA_PREP_THROTTLE_MS then return false end

    prep_log(menu, "arena.entry", 500, string.format("[Warlock][ArenaPrep] enter hp=%d%% mana=%d%%", hp_pct(player), mana_pct(player)))

    -- 0) Trash buffs for dispel protection (Detect Invisibility / Unending Breath) on self + party
    if menu_enabled(menu, "arena_prep_trash_buffs", true) then
        local units = { player }
        local party = izi.party and izi.party(40) or nil
        if party then
            for _, u in __object_safety.live_ipairs(party) do
                if u and u.is_valid and u:is_valid() then
                    table.insert(units, u)
                end
            end
        end

        if spells.detect_invisibility:is_learned() then
            for _, u in __object_safety.live_ipairs(units) do
                if u and u:buff_down(spells.detect_invisibility:id()) and spells.detect_invisibility:is_castable() then
                    prep_log(menu, "arena.buff.detect", 250, "[Warlock][ArenaPrep] Cast Detect Invisibility")
                    arena_prep_last_attempt_ms = now
                    if spells.detect_invisibility:cast(u) then return true end
                end
            end
        end
        if spells.unending_breath:is_learned() then
            for _, u in __object_safety.live_ipairs(units) do
                if u and u:buff_down(spells.unending_breath:id()) and spells.unending_breath:is_castable() then
                    prep_log(menu, "arena.buff.breath", 250, "[Warlock][ArenaPrep] Cast Unending Breath")
                    arena_prep_last_attempt_ms = now
                    if spells.unending_breath:cast(u) then return true end
                end
            end
        end
    end

    -- 1) Ensure armor up (fast / safe)
    if menu_enabled(menu, "use_fel_armor", true) then
        local armor = spells.fel_armor:is_learned() and spells.fel_armor or spells.demon_armor
        if armor:is_learned() and player:buff_down(armor:id()) then
            prep_log(menu, "arena.armor", 250, "[Warlock][ArenaPrep] Apply armor")
            arena_prep_last_attempt_ms = now
            if armor:is_castable() and armor:cast(player) then return true end
        end
    end

    local want_sac = menu_enabled(menu, "arena_prep_vw_sacrifice", true)
    if want_sac and not has_vw_sacrifice(player) then
        local pet = player:get_pet()
        local pet_is_vw = false
        pcall(function()
            if pet and pet:is_valid() and pet:is_alive() then
                pet_is_vw = tonumber(pet:get_npc_id()) == 1860
            end
        end)
        prep_log(menu, "arena.vw.state", 500, string.format("[Warlock][ArenaPrep] want_sac=%s pet_is_vw=%s has_sac=%s", tostring(want_sac), tostring(pet_is_vw), tostring(has_vw_sacrifice(player))))

        -- 2) Summon Voidwalker for Sacrifice
        if not pet_is_vw then
            if spells.summon_voidwalker:is_learned() and spells.summon_voidwalker:is_castable({ skip_facing = true }) then
                prep_log(menu, "arena.vw.summon", 250, "[Warlock][ArenaPrep] Summon Voidwalker")
                arena_prep_last_attempt_ms = now
                if spells.summon_voidwalker:cast(player) then
                    last_summon_finish_ms = now + 6000
                    return true
                end
            end
        else
            -- 3) Cast Sacrifice regardless of HP during prep
            if core.input and core.input.pet_cast_target_spell then
                for _, sac_id in ipairs(VW_SACRIFICE_IDS) do
                    local ok, result = pcall(core.input.pet_cast_target_spell, sac_id, player)
                    if ok and result then
                        prep_log(menu, "arena.vw.sac", 250, "[Warlock][ArenaPrep] VW Sacrifice cast")
                        arena_prep_last_attempt_ms = now
                        return true
                    end
                end
                prep_log(menu, "arena.vw.sac.fail", 500, "[Warlock][ArenaPrep] VW Sacrifice attempt failed (no rank succeeded)")
            end
        end
    end

    -- 4) After Sacrifice: summon preferred PvP pet (default Felhunter) if currently VW
    if want_sac and has_vw_sacrifice(player) then
        local pet = player:get_pet()
        local pet_is_vw = false
        pcall(function()
            if pet and pet:is_valid() and pet:is_alive() then
                pet_is_vw = tonumber(pet:get_npc_id()) == 1860
            end
        end)
        if pet_is_vw then
            local preferred = menu_number(menu, "arena_prep_pet_after_sac", menu_number(menu, "preferred_pet", 4))
            local candidates = { spells.summon_felguard, spells.summon_imp, spells.summon_succubus, spells.summon_felhunter, spells.summon_voidwalker }
            local summon = candidates[preferred] or spells.summon_felhunter
            if summon and summon:is_learned() and summon:is_castable({ skip_facing = true }) then
                prep_log(menu, "arena.pet.after", 250, string.format("[Warlock][ArenaPrep] Summon pet after Sac (idx=%d)", preferred))
                arena_prep_last_attempt_ms = now
                if summon:cast(player) then
                    last_summon_finish_ms = now + 6000
                    return true
                end
            end
        end
    end

    -- 5) Ensure Soul Link up once pet is alive
    if menu_enabled(menu, "use_soul_link", true) and spells.soul_link:is_learned() and not soul_link_is_up(player) then
        local pet = player:get_pet()
        if pet and pet:is_valid() and pet:is_alive() then
            prep_log(menu, "arena.sl", 250, "[Warlock][ArenaPrep] Apply Soul Link")
            arena_prep_last_attempt_ms = now
            if spells.soul_link:is_castable() and spells.soul_link:cast(player) then
                soul_link_assumed_until_ms = now + 1500
                return true
            end
        end
    end

    return false
end

local function hp_pct(unit)
    if not unit or not unit.get_health_percentage then return 0 end
    return num(unit:get_health_percentage(), 0)
end

local function mana_pct(unit)
    if not unit or not unit.mana_pct then return 100 end
    return num(unit:mana_pct(), 100)
end

local function ttd_sec(unit)
    if not unit or not unit.time_to_die then return 999 end
    local v = num(unit:time_to_die(), 999)
    return v <= 0 and 999 or v
end

-- DoT/cast spam prevention is handled by dot_guard (per spell + target).

local function stop_wand_if_active(player, target)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then return end
    local is_attacking = false
    pcall(function() is_attacking = auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND) end)
    if not is_attacking then return end
    auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
end

local function is_wanding_active(player)
    if not auto_attack_helper then return false end
    if auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND) then return true end
    local ok, pid = pcall(function() return player:get_active_channel_spell_id() end)
    return ok and pid == 5019
end

local function try_pet_attack(player, target)
    local pet = player:get_pet()
    if not pet or not pet:is_valid() or not pet:is_alive() then return end
    if not target or not target:is_valid_enemy() then return end

    -- Throttle: Only call pet_attack every 2 seconds
    local now = core.game_time()
    if (now - last_pet_attack_ms) < PET_ATTACK_THROTTLE_MS then return end

    -- Check if pet is already attacking the same target
    local pet_target = nil
    pcall(function() pet_target = pet:get_target() end)
    if pet_target and pet_target:is_valid() and (__object_safety.same(pet_target,target)) then
        return
    end

    -- Send Pet Attack
    if core.input and core.input.pet_attack then
        local ok = pcall(core.input.pet_attack, target)
        if ok then
            last_pet_attack_ms = now
        end
    end
end

local last_pet_ability_ms = 0
local PET_ABILITY_THROTTLE_MS = 1500

local function handle_pet_automation(player, target, menu)
    local pet = player:get_pet()
    if not pet or not pet:is_valid() or not pet:is_alive() then return false end
    if not target or not target:is_valid_enemy() or not target:is_alive() then return false end

    local now = core.game_time()
    if (now - last_pet_ability_ms) < PET_ABILITY_THROTTLE_MS then return false end

    local pet_npc_id = 0
    pcall(function() pet_npc_id = tonumber(pet:get_npc_id()) end)

    -- FELGUARD AUTOMATION
    if pet_npc_id == 17252 or pet_npc_id == PET_FELGUARD then -- TBC Felguard NPC ID
        -- 1. Intercept (Gap Closer)
        local dist = 0
        pcall(function() dist = target:distance() end)
        if dist >= 8 and dist <= 25 then
            if core.input and core.input.pet_cast_target_spell then
                local ok = pcall(core.input.pet_cast_target_spell, 30151, target)
                if ok then
                    last_pet_ability_ms = now
                    core.log("[Pet] Intercept -> " .. target:get_name())
                    return true
                end
            end
        end

        -- 2. Cleave (AoE)
        local enemies = izi.enemies(8)
        if enemies and #enemies >= 2 then
            if core.input and core.input.pet_cast_target_spell then
                local ok = pcall(core.input.pet_cast_target_spell, 30213, target)
                if ok then
                    last_pet_ability_ms = now
                    core.log("[Pet] Cleave (" .. #enemies .. " targets)")
                    return true
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- SHARED CURSE LOGIC
-- ============================================================================

local function try_assigned_curse(player, target, menu)
    local ttd = ttd_sec(target)
    local preferred = menu_number(menu, "preferred_curse", 1)
    -- preferred: 1=Elements, 2=Agony, 3=Doom, 4=Tongues, 5=Recklessness
    local min_ttd = dot_min_ttd_sec(menu)

    local function try_curse(spell)
        if not spell or spell:is_learned() ~= true then return false end
        local id = spell:id()
        if target:debuff_down(id) ~= true then return false end
        if dot_guard:should_block(id, target) == true then return false end
        if spell:is_castable() and spell:cast(target) then
            dot_guard_after_cast(spell, target, true)
            return true
        end
        return false
    end

    local function try_curse_of_doom()
        if spells.curse_of_doom:is_learned() ~= true then return false end
        if ttd <= 60 then return false end
        if dot_guard:should_block(spells.curse_of_doom:id(), target) == true then return false end
        if target:debuff_down(spells.curse_of_doom:id()) ~= true then return false end

        if want_burst(menu)
            and spells.amplify_curse:is_learned()
            and spells.amplify_curse.cooldown_up
            and spells.amplify_curse:cooldown_up() then
            if spells.amplify_curse:is_castable({ skip_facing = true }) and spells.amplify_curse:cast(player) then
                return true
            end
        end

        if spells.curse_of_doom:is_castable() and spells.curse_of_doom:cast(target) then
            dot_guard_after_cast(spells.curse_of_doom, target, true)
            return true
        end

        return false
    end

    -- Preferred Curse handling
    if preferred == 1 then
        local coe_enabled = menu_enabled(menu, "use_curse_of_elements", true) == true
        local coe_learned = spells.curse_of_elements:is_learned() == true

        -- If CoE is missing and we're allowed to apply it, do so.
        if coe_enabled and coe_learned and target:debuff_down(spells.curse_of_elements:id()) == true then
            return try_curse(spells.curse_of_elements)
        end

        -- If CoE is already present (another warlock) or user disabled it:
        -- apply Doom on long-lived targets, otherwise Agony (trash/leveling).
        if try_curse_of_doom() then return true end
        preferred = 2
    end

    if preferred == 3 then
        if try_curse_of_doom() then return true end
        -- If target won't live long enough, fall back to Agony.
        preferred = 2
    end

    if preferred == 2 then
        if spells.curse_of_agony:is_learned() == true and ttd >= math.max(min_ttd, 8) then
            if dot_guard:should_block(spells.curse_of_agony:id(), target) ~= true then
                -- CoA: never refresh early (damage ramps); re-apply only when it falls off.
                if needs_refresh(target, spells.curse_of_agony, DOT_REFRESH_LEEWAY_MS_INSTANT, true) then
                    if spells.curse_of_agony:is_castable() and spells.curse_of_agony:cast(target) then
                        dot_guard_after_cast(spells.curse_of_agony, target, true)
                        return true
                    end
                end
            end
        end
        return false
    end

    if preferred == 4 then
        return try_curse(spells.curse_of_tongues)
    end

    if preferred == 5 then
        return try_curse(spells.curse_of_recklessness)
    end

    return false
end

local function try_pve_kiting_coex(player, target, menu)
    if not menu_enabled(menu, "use_coex_pve", false) then return false end
    if not spells.curse_of_exhaustion:is_learned() then return false end
    if not player or not target then return false end
    if not target:is_valid_enemy() or not target:is_alive() then return false end

    -- CoEx occupies the curse slot: use only as a kiting tool, not as a DPS curse.
    -- Heuristics: target is close OR we are moving (likely kiting), and target is moving.
    local dist = 999
    pcall(function() dist = num(target:distance(), 999) end)
    local close = dist <= 12.0

    if not close and player:is_moving() ~= true then
        return false
    end

    local target_moving = false
    pcall(function() target_moving = target:is_moving() == true end)
    if target_moving ~= true then
        return false
    end

    if target:debuff_up(spells.curse_of_exhaustion:id()) then
        return false
    end
    if dot_guard:should_block(spells.curse_of_exhaustion:id(), target) then
        return false
    end

    if spells.curse_of_exhaustion:is_castable() and spells.curse_of_exhaustion:cast(target) then
        dot_guard_after_cast(spells.curse_of_exhaustion, target, true)
        return true
    end

    return false
end

-- ============================================================================
-- DESTRO SHARED: Corruption on Pull (apply once, don't refresh)
-- ============================================================================

local function try_corruption_on_pull(player, target)
    if player:is_moving() then return false end
    if not spells.corruption:is_learned() then return false end
    if target:debuff_up(spells.corruption:id()) then return false end
    if dot_guard:should_block(spells.corruption:id(), target) then return false end
    -- "On pull" heuristic: only apply while target is still high HP (avoid re-applying mid-fight).
    if hp_pct(target) < 85 then return false end
    if spells.corruption:is_castable() and spells.corruption:cast(target) then
        dot_guard_after_cast(spells.corruption, target, true)
        return true
    end
    return false
end

-- ============================================================================
-- DEFENSIVE LOGIC
-- ============================================================================

-- Buff cast throttle: prevent re-casting buffs every frame between cast and server confirm
local last_buff_cast = {}
local BUFF_CAST_THROTTLE_MS = 3000

local function try_buff_cast(spell, player)
    local id = spell:id()
    local now = core.game_time()
    if last_buff_cast[id] and (now - last_buff_cast[id]) < BUFF_CAST_THROTTLE_MS then
        return false
    end
    if spell:is_learned() and player:buff_down(id) then
        if spell:is_castable() and spell:cast(player) then
            last_buff_cast[id] = now
            return true
        end
    end
    return false
end

local function try_defensives(player, target, menu)
    local hp = hp_pct(player)
    local threshold = menu_number(menu, "healthstone_hp_pct", 35)

    -- 0. Health Potion + Healthstone
    do
        local is_pvp = plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) or menu_enabled(menu, "pvp_mode", false)
        if is_pvp and menu and menu.pvp_debug_logging and menu.pvp_debug_logging:get_state() == true and menu.pvp_debug_verbose and menu.pvp_debug_verbose:get_state() == true then
            local has_hs = false
            pcall(function() has_hs = healthstone_item and healthstone_item:in_inventory() end)
            prep_log(menu, "def.hs.chk", 750, string.format("[Warlock][Def][HS] hp=%d%% thresh=%d%% has_hs=%s", hp, threshold, tostring(has_hs)))
        end
    end
    if hp <= threshold then
        if izi.use_best_health_potion_safe({ skip_moving = false, skip_casting = true }) then return true end
        if healthstone_item and healthstone_item:in_inventory() then
            if healthstone_item:use_self_safe("Healthstone") then return true end
        end
    end

    -- 1. Shadow Ward (absorb shadow damage)
    if menu_enabled(menu, "use_shadow_ward", false) and spells.shadow_ward:is_learned() then
        local sw_threshold = menu_number(menu, "shadow_ward_hp_pct", 50)
        if hp <= sw_threshold and player:buff_down(spells.shadow_ward:id()) then
            if spells.shadow_ward:is_castable() and spells.shadow_ward:cast(player) then return true end
        end
    end

    -- 2. Emergency CC: Death Coil (instant, heals + horrifies)
    if menu_enabled(menu, "use_emergency_cc", true) and spells.death_coil:is_learned() then
        local dc_threshold = menu_number(menu, "death_coil_hp_pct", 20)
        if hp <= dc_threshold and target and target:is_valid_enemy() and target:is_alive() then
            if spells.death_coil:is_castable() and spells.death_coil:cast(target) then return true end
        end
    end

    -- 3. Emergency CC: Howl of Terror (AoE fear)
    if menu_enabled(menu, "use_emergency_cc", true) and spells.howl_of_terror:is_learned() then
        local howl_threshold = menu_number(menu, "howl_hp_pct", 25)
        if hp <= howl_threshold then
            if spells.howl_of_terror:is_castable() and spells.howl_of_terror:cast(player) then return true end
        end
    end

    -- 4. Drain Life (self-heal when low HP, in combat)
    if menu_enabled(menu, "use_drain_life", true) and spells.drain_life:is_learned() then
        local dl_threshold = menu_number(menu, "drain_life_hp_pct", 45)
        if hp <= dl_threshold and not player:is_moving() and target and target:is_valid_enemy() then
            if spells.drain_life:is_castable() and spells.drain_life:cast(target) then return true end
        end
    end

    -- 5. Fel Armor Maintenance (instant cast, castable while moving)
    if menu_enabled(menu, "use_fel_armor", true) then
        if spells.fel_armor:is_learned() and player:buff_down(spells.fel_armor:id()) then
            if spells.fel_armor:is_castable() and spells.fel_armor:cast(player) then return true end
        elseif spells.demon_armor:is_learned() and player:buff_down(spells.demon_armor:id()) and not spells.fel_armor:is_learned() then
            if spells.demon_armor:is_castable() and spells.demon_armor:cast(player) then return true end
        end
    end

    -- 6. Health Funnel (heal pet)
    if menu_enabled(menu, "use_health_funnel", true) and spells.health_funnel:is_learned() and not player:is_moving() then
        local hf_threshold = menu_number(menu, "health_funnel_pet_hp_pct", 40)
        local pet = player:get_pet()
        if pet and pet:is_valid() and pet:is_alive() then
            local pet_hp = hp_pct(pet)
            local is_emergency = pet_hp <= 25
            local out_of_combat = not player:is_in_combat()

            -- Use more aggressively out of combat or in emergencies
            if (out_of_combat and pet_hp < 80) or (is_emergency) or (pet_hp <= hf_threshold and hp > 50) then
                if spells.health_funnel:is_castable() and spells.health_funnel:cast(pet) then return true end
            end
        end
    end

    -- 7. PvP Dispel Protection Buffs (throttled to prevent spam between cast and server confirm)
    if (plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) or menu_enabled(menu, "pvp_mode", false)) and not player:is_moving() then
        if try_buff_cast(spells.detect_invisibility, player) then return true end
        if try_buff_cast(spells.unending_breath, player) then return true end
    end

    return false
end

-- ============================================================================
-- AOE LOGIC
-- ============================================================================

local function try_aoe(player, target, menu)
    if player:is_moving() then return false end

    local aoe_limit = menu_number(menu, "aoe_target_count", 3)
    local enemies = izi.enemies(30)
    if not enemies or #enemies < 2 then return false end
    if want_single_target(menu) and want_force_aoe(menu) ~= true then
        return false
    end
    if want_force_aoe(menu) ~= true and #enemies < aoe_limit then
        return false
    end

    -- 1. Shadowfury (stun + burst) - Destruction Talent
    if menu_enabled(menu, "use_shadowfury", true) and spells.shadowfury:is_learned() then
        if spells.shadowfury:is_castable({ skip_facing = true }) then
            if spells.shadowfury:cast(target:get_position()) then return true end
        end
    end

    -- 2. Seed of Corruption
    if menu_enabled(menu, "use_seed_aoe", true) and spells.seed_of_corruption:is_learned() then
        if izi.spread_dot(spells.seed_of_corruption, enemies, 1500, 5, "Seed Spreading") then
            return true
        end
    end

    -- 3. Hellfire (sustained channel AoE, self-damage)
    if menu_enabled(menu, "use_hellfire_aoe", false) and spells.hellfire:is_learned() then
        if hp_pct(player) > 50 then
            if not player:is_channeling() then
                if spells.hellfire:cast() then return true end
            else
                return true -- stay channeling
            end
        end
    end

    return false
end

-- ============================================================================
-- AFFLICTION ROTATION
-- Guide: Assigned Curse > UA > Corruption > Siphon Life > Immolate > Shadow Bolt
-- ============================================================================

local function execute_affliction(player, target, menu)
    local is_moving = player:is_moving()
    local ttd = ttd_sec(target)
    local mana = mana_pct(player)
    local min_sb_mana = menu_number(menu, "shadow_bolt_min_mana_pct", 60)
    local min_ttd = dot_min_ttd_sec(menu)

    -- 1. Assigned Curse
    if try_pve_kiting_coex(player, target, menu) then return true end
    if try_assigned_curse(player, target, menu) then return true end

    -- 2. Unstable Affliction
    if not is_moving and menu_enabled(menu, "use_ua", true) and spells.unstable_affliction:is_learned() then
        if ttd >= math.max(min_ttd, 8) and dot_guard:should_block(spells.unstable_affliction:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.unstable_affliction, false)
            if needs_refresh(target, spells.unstable_affliction, refresh_window, false) then
            if not (is_wanding_active(player) and ttd < 12) then
                if spells.unstable_affliction:is_castable() and spells.unstable_affliction:cast(target) then
                    dot_guard_after_cast(spells.unstable_affliction, target, false)
                    return true
                end
            end
            end
        end
    end

    -- 3. Corruption (apply or near-expiry refresh)
    if menu_enabled(menu, "use_corruption", true) and spells.corruption:is_learned() then
        if ttd >= math.max(min_ttd, 6) and dot_guard:should_block(spells.corruption:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.corruption, true)
            if needs_refresh(target, spells.corruption, refresh_window, false) then
            if not (is_wanding_active(player) and ttd < 12) then
                if spells.corruption:is_castable() and spells.corruption:cast(target) then
                    dot_guard_after_cast(spells.corruption, target, true)
                    return true
                end
            end
            end
        end
    end

    -- 4. Siphon Life
    if menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned() then
        if ttd >= math.max(min_ttd, 12) and dot_guard:should_block(spells.siphon_life:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.siphon_life, true)
            if needs_refresh(target, spells.siphon_life, refresh_window, false) then
            if not is_wanding_active(player) then
                if spells.siphon_life:is_castable() and spells.siphon_life:cast(target) then
                    dot_guard_after_cast(spells.siphon_life, target, true)
                    return true
                end
            end
            end
        end
    end

    -- 5. Immolate (Guide says Affliction also uses Immolate after other DoTs)
    if not is_moving and menu_enabled(menu, "use_immolate", false) and spells.immolate:is_learned() then
        if ttd >= math.max(min_ttd, 8) and dot_guard:should_block(spells.immolate:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.immolate, false)
            if needs_refresh(target, spells.immolate, refresh_window, false) then
            if not is_wanding_active(player) then
                if spells.immolate:is_castable() and spells.immolate:cast(target) then
                    dot_guard_after_cast(spells.immolate, target, false)
                    return true
                end
            end
            end
        end
    end

    -- 5.5 Multi-DoT (secondary targets): Corruption (+ optional Siphon Life / UA)
    if menu_enabled(menu, "multi_dot_enabled", false) and not want_single_target(menu) then
        local limit = menu_number(menu, "multi_dot_limit", 3)
        if limit >= 2 then
            local enemies = izi.enemies(40)
            if enemies and #enemies >= 2 then
                local max_secondary = limit - 1
                local applied = 0
                for _, u in __object_safety.live_ipairs(enemies) do
                    if applied >= max_secondary then break end
                    if u and u:is_valid_enemy() and u:is_alive() and (not __object_safety.same(u,target)) then
                        local u_ttd = ttd_sec(u)
                        if u_ttd >= math.max(min_ttd, 6) then
                            if menu_enabled(menu, "multi_dot_include_ua", false)
                                and spells.unstable_affliction:is_learned()
                                and not player:is_moving()
                                and u_ttd >= math.max(min_ttd, 8)
                                and dot_guard:should_block(spells.unstable_affliction:id(), u) ~= true
                                and needs_refresh(u, spells.unstable_affliction, dot_refresh_window_ms(spells.unstable_affliction, false), false) then
                                if spells.unstable_affliction:is_castable() and spells.unstable_affliction:cast(u) then
                                    dot_guard_after_cast(spells.unstable_affliction, u, false)
                                    applied = applied + 1
                                    return true
                                end
                            end

                            if spells.corruption:is_learned()
                                and dot_guard:should_block(spells.corruption:id(), u) ~= true
                                and needs_refresh(u, spells.corruption, dot_refresh_window_ms(spells.corruption, true), false) then
                                if spells.corruption:is_castable() and spells.corruption:cast(u) then
                                    dot_guard_after_cast(spells.corruption, u, true)
                                    applied = applied + 1
                                    return true
                                end
                            end

                            if menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned()
                                and dot_guard:should_block(spells.siphon_life:id(), u) ~= true
                                and u_ttd >= math.max(min_ttd, 12)
                                and needs_refresh(u, spells.siphon_life, dot_refresh_window_ms(spells.siphon_life, true), false) then
                                if spells.siphon_life:is_castable() and spells.siphon_life:cast(u) then
                                    dot_guard_after_cast(spells.siphon_life, u, true)
                                    applied = applied + 1
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 6. Shadow Bolt Filler (check mana threshold)
    if not is_moving and menu_enabled(menu, "use_shadow_bolt", true) and mana >= min_sb_mana then
        if spells.shadow_bolt:is_castable() then
            stop_wand_if_active(player, target)
            if spells.shadow_bolt:cast(target) then return true end
        end
    end

    return false
end

-- ============================================================================
-- SHADOW DESTRUCTION ROTATION
-- Guide: Curse of Doom > Immolate > Corruption (on pull) > Shadow Bolt > Shadowburn (move)
-- ============================================================================

local function execute_shadow_destruction(player, target, menu)
    local is_moving = player:is_moving()
    local ttd = ttd_sec(target)
    local mana = mana_pct(player)
    local min_sb_mana = menu_number(menu, "shadow_bolt_min_mana_pct", 60)
    local min_ttd = dot_min_ttd_sec(menu)

    -- Optional: maintain Demonic Sacrifice (Succubus) if specced
    do
        local plan = pve_sacrifice_plan(menu)
        if plan and plan.buff_id == SACRIFICE_SUCCUBUS_BUFF and player:buff_down(plan.buff_id) then
            local pet = player:get_pet()
            local pet_id = 0
            if pet and pet:is_valid() and pet:is_alive() then
                pcall(function() pet_id = num(pet:get_npc_id(), 0) end)
            end
            if pet_id == plan.pet_npc and spells.demonic_sacrifice:is_castable({ skip_facing = true }) then
                if spells.demonic_sacrifice:cast(pet) then return true end
            end
        end
    end

    -- 1. Assigned Curse (CoD if TTD>60, else CoE)
    if try_pve_kiting_coex(player, target, menu) then return true end
    if try_assigned_curse(player, target, menu) then return true end

    -- 2. Immolate (mandatory for Shadow Destruction - DPS gain per guide)
    if not is_moving and spells.immolate:is_learned() then
        if ttd >= math.max(min_ttd, 8) and dot_guard:should_block(spells.immolate:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.immolate, false)
            if needs_refresh(target, spells.immolate, refresh_window, false) then
                if spells.immolate:is_castable() and spells.immolate:cast(target) then
                    dot_guard_after_cast(spells.immolate, target, false)
                    return true
                end
            end
        end
    end

    -- 3. Corruption on Pull (apply once when target is near full HP)
    if menu_enabled(menu, "use_corruption", true) then
        if try_corruption_on_pull(player, target) then return true end
    end

    -- 4. Shadow Bolt (primary filler, check mana)
    if not is_moving and menu_enabled(menu, "use_shadow_bolt", true) and mana >= min_sb_mana then
        if spells.shadow_bolt:is_castable() then
            stop_wand_if_active(player, target)
            if spells.shadow_bolt:cast(target) then return true end
        end
    end

    -- 5. Shadowburn (movement / execute)
    if spells.shadowburn:is_learned() and (hp_pct(target) < 15 or is_moving) then
        if spells.shadowburn:is_castable() and spells.shadowburn:cast(target) then return true end
    end

    return false
end

-- ============================================================================
-- FIRE DESTRUCTION ROTATION
-- Guide: Curse of Doom > Immolate > Corruption (on pull) > Incinerate > Conflagrate (MOVE ONLY)
-- ============================================================================

local function execute_fire_destruction(player, target, menu)
    local is_moving = player:is_moving()
    local ttd = ttd_sec(target)
    local min_ttd = dot_min_ttd_sec(menu)

    -- Optional: maintain Demonic Sacrifice (Imp) if specced
    do
        local plan = pve_sacrifice_plan(menu)
        if plan and plan.buff_id == SACRIFICE_IMP_BUFF and player:buff_down(plan.buff_id) then
            local pet = player:get_pet()
            local pet_id = 0
            if pet and pet:is_valid() and pet:is_alive() then
                pcall(function() pet_id = num(pet:get_npc_id(), 0) end)
            end
            if pet_id == plan.pet_npc and spells.demonic_sacrifice:is_castable({ skip_facing = true }) then
                if spells.demonic_sacrifice:cast(pet) then return true end
            end
        end
    end

    -- 1. Assigned Curse (CoD if TTD>60, else CoE)
    if try_pve_kiting_coex(player, target, menu) then return true end
    if try_assigned_curse(player, target, menu) then return true end

    -- 2. Immolate (mandatory for Incinerate bonus)
    if not is_moving and spells.immolate:is_learned() then
        if ttd >= math.max(min_ttd, 4) and dot_guard:should_block(spells.immolate:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.immolate, false)
            if needs_refresh(target, spells.immolate, refresh_window, false) then
                if spells.immolate:is_castable() and spells.immolate:cast(target) then
                    dot_guard_after_cast(spells.immolate, target, false)
                    return true
                end
            end
        end
    end

    -- 3. Corruption on Pull
    if menu_enabled(menu, "use_corruption", true) then
        if try_corruption_on_pull(player, target) then return true end
    end

    -- 4. Incinerate (primary filler)
    if not is_moving and spells.incinerate:is_learned() and spells.incinerate:is_castable() then
        stop_wand_if_active(player, target)
        if spells.incinerate:cast(target) then return true end
    end

    -- 5. Conflagrate
    -- Default: only while moving (per common raid guidance).
    -- Burst toggle: allow using it even while standing still for frontloaded damage.
    if (is_moving or want_burst(menu)) and menu_enabled(menu, "use_conflagrate", true) and spells.conflagrate:is_learned() then
        if target:debuff_up(spells.immolate:id()) then
            if spells.conflagrate:is_castable() and spells.conflagrate:cast(target) then return true end
        end
    end

    -- 6. Shadowburn (movement fallback when Conflagrate unavailable)
    if is_moving and spells.shadowburn:is_learned() then
        if spells.shadowburn:is_castable() and spells.shadowburn:cast(target) then return true end
    end

    return false
end

-- ============================================================================
-- DEMONOLOGY ROTATION
-- Guide: Assigned Curse > Corruption > Immolate > Shadow Bolt
-- Uses Felguard as primary pet with full pet automation
-- ============================================================================

local function execute_demonology(player, target, menu)
    local is_moving = player:is_moving()
    local ttd = ttd_sec(target)
    local mana = mana_pct(player)
    local min_sb_mana = menu_number(menu, "shadow_bolt_min_mana_pct", 60)
    local min_ttd = dot_min_ttd_sec(menu)

    -- 1. Assigned Curse
    if try_pve_kiting_coex(player, target, menu) then return true end
    if try_assigned_curse(player, target, menu) then return true end

    -- 2. Corruption (apply or near-expiry refresh)
    if menu_enabled(menu, "use_corruption", true) and spells.corruption:is_learned() then
        if ttd >= math.max(min_ttd, 6) and dot_guard:should_block(spells.corruption:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.corruption, true)
            if needs_refresh(target, spells.corruption, refresh_window, false) then
                if spells.corruption:is_castable() and spells.corruption:cast(target) then
                    dot_guard_after_cast(spells.corruption, target, true)
                    return true
                end
            end
        end
    end

    -- 3. Immolate (DPS gain for Demonology per guide)
    if not is_moving and spells.immolate:is_learned() then
        if ttd >= math.max(min_ttd, 8) and dot_guard:should_block(spells.immolate:id(), target) ~= true then
            local refresh_window = dot_refresh_window_ms(spells.immolate, false)
            if needs_refresh(target, spells.immolate, refresh_window, false) then
                if spells.immolate:is_castable() and spells.immolate:cast(target) then
                    dot_guard_after_cast(spells.immolate, target, false)
                    return true
                end
            end
        end
    end

    -- 4. Shadow Bolt Filler (check mana)
    if not is_moving and menu_enabled(menu, "use_shadow_bolt", true) and mana >= min_sb_mana then
        if spells.shadow_bolt:is_castable() then
            stop_wand_if_active(player, target)
            if spells.shadow_bolt:cast(target) then return true end
        end
    end

    -- 5. Shadowburn (movement / execute)
    if spells.shadowburn:is_learned() and (hp_pct(target) < 15 or is_moving) then
        if spells.shadowburn:is_castable() and spells.shadowburn:cast(target) then return true end
    end

    return false
end

-- ============================================================================
-- DS/RUIN ROTATION (Demonic Sacrifice + Shadow Bolt spam)
-- Sacrifice Succubus for +15% shadow damage, then Curse > Corruption > SB spam
-- ============================================================================

local function execute_ds_ruin(player, target, menu)
    local is_moving = player:is_moving()
    local ttd = ttd_sec(target)

    -- Maintain Demonic Sacrifice buff (+15% shadow damage from Succubus)
    if menu_enabled(menu, "use_pet_sacrifice", true) and spells.demonic_sacrifice:is_learned() and player:buff_down(SACRIFICE_SUCCUBUS_BUFF) then
        local pet = player:get_pet()
        local pet_id = 0
        if pet and pet:is_valid() and pet:is_alive() then
            pcall(function() pet_id = num(pet:get_npc_id(), 0) end)
        end
        -- Only sacrifice succubus (prevents accidentally sacrificing Felguard/VW etc.)
        if pet and pet_id == PET_SUCCUBUS then
            if spells.demonic_sacrifice:is_castable({ skip_facing = true }) and spells.demonic_sacrifice:cast(pet) then return true end
        end
    end

    -- 1. Assigned Curse
    if try_pve_kiting_coex(player, target, menu) then return true end
    if try_assigned_curse(player, target, menu) then return true end

    -- 2. Corruption (apply once, don't refresh -- DS/Ruin focuses on Shadow Bolt)
    if menu_enabled(menu, "use_corruption", true) and spells.corruption:is_learned() then
        if target:debuff_down(spells.corruption:id()) and ttd > 10 and dot_guard:should_block(spells.corruption:id(), target) ~= true then
            if spells.corruption:is_castable() and spells.corruption:cast(target) then
                dot_guard_after_cast(spells.corruption, target, true)
                return true
            end
        end
    end

    -- 3. Shadow Bolt spam (primary filler, the core of DS/Ruin)
    local mana = mana_pct(player)
    local min_sb_mana = menu_number(menu, "shadow_bolt_min_mana_pct", 35)
    if not is_moving and mana >= min_sb_mana and spells.shadow_bolt:is_castable() then
        stop_wand_if_active(player, target)
        if spells.shadow_bolt:cast(target) then return true end
    end

    -- 4. Shadowburn (movement / execute)
    if spells.shadowburn:is_learned() and (hp_pct(target) < 15 or is_moving) then
        if spells.shadowburn:is_castable() and spells.shadowburn:cast(target) then return true end
    end

    return false
end

-- ============================================================================
-- PVP LOGIC (delegated to rotations/warlock/tbc/pvp/init.lua)
-- ============================================================================
-- The full PvP rotation with DR-aware CC chains, SL/SL and UA Affliction
-- spec modes, intelligent pet control, and multi-DoT spreading is in the
-- pvp/ submodule. See pvp/init.lua for the entry point.

-- ============================================================================
-- DRAIN SOUL (Execute / Shard Farming)
-- ============================================================================

local function try_drain_soul(player, target, menu)
    if not menu_enabled(menu, "use_drain_soul", true) then return false end
    if not spells.drain_soul:is_learned() then return false end
    if player:is_moving() then return false end

    local t_hp = hp_pct(target)
    local execute_threshold = menu_number(menu, "drain_soul_execute_hp_pct", 20)
    local min_shards = menu_number(menu, "min_soul_shards", 3)
    local current_shards = soul_shard:count()
    local mana = mana_pct(player)

    -- Leveling Optimization: Improved Drain Soul Proc
    -- Even if we have enough shards, finish mobs with Drain Soul if mana is low (< 75%)
    -- This procs 100% mana regen for 10 seconds.
    local need_mana_regen = mana < 75
    local enough_shards = current_shards >= min_shards

    if enough_shards and not need_mana_regen then return false end

    -- Shard-snipe window:
    local ttd = ttd_sec(target)
    local in_hp_window = t_hp <= execute_threshold
    local dying_soon = (ttd < 5) or (t_hp < 15)

    if in_hp_window and dying_soon then
        -- Use Rank 1 for mana-regen snipes if we have many shards to save mana
        local ds_spell = (enough_shards and need_mana_regen) and izi.spell(1120) or spells.drain_soul
        if ds_spell:is_castable() and ds_spell:cast(target) then
            core.log("[Leveling] Drain Soul Snipe -> " .. target:get_name() .. (need_mana_regen and " (Mana Regen)" or ""))
            return true
        end
    end

    return false
end

-- ============================================================================
-- RESOURCE MANAGEMENT
-- ============================================================================

local function try_resources(player, target, menu)
    local mana = mana_pct(player)
    local hp = hp_pct(player)
    local life_tap_mana_threshold = menu_number(menu, "life_tap_mana_pct", 40)
    local life_tap_min_hp = menu_number(menu, "life_tap_min_hp_pct", 60)
    local is_moving = player:is_moving()

    -- 1. Dark Pact (drain pet mana - FREE mana, always prefer over Life Tap)
    if spells.dark_pact:is_learned() and mana < life_tap_mana_threshold then
        local pet = player:get_pet()
        if pet and pet:is_valid() and pet:is_alive() and mana_pct(pet) > 30 then
            if spells.dark_pact:is_castable() and spells.dark_pact:cast(player) then return true end
        end
    end

    -- 1.5 Mana Potion (TBC: strong for burst / long fights, but optional)
    if menu_enabled(menu, "use_mana_potion", false) then
        local mp_threshold = menu_number(menu, "mana_potion_mana_pct", 15)
        if mana <= mp_threshold then
            if izi.use_best_mana_potion_safe({ skip_moving = false, skip_casting = true }) then
                return true
            end
        end
    end

    -- 2. Life Tap during movement (zero DPS loss - guides recommend this)
    if is_moving and menu_enabled(menu, "use_life_tap", true) and spells.life_tap:is_learned() then
        -- While moving, tap more aggressively to pre-load mana for standing phases
        if mana < 90 and hp > life_tap_min_hp then
            if spells.life_tap:is_castable() and spells.life_tap:cast(player) then
                core.log("[Movement] Life Tap (Pre-loading Mana)")
                return true
            end
        end
    end

    -- 3. Life Tap (uses menu values)
    if menu_enabled(menu, "use_life_tap", true) and spells.life_tap:is_learned() then
        if mana < life_tap_mana_threshold and hp > life_tap_min_hp then
            -- Don't break wand for Life Tap unless critical
            if is_wanding_active(player) and mana > 10 then return false end
            if spells.life_tap:is_castable() and spells.life_tap:cast(player) then return true end
        end
    end
    return false
end

-- ============================================================================
-- OUT OF COMBAT
-- ============================================================================

pve_sacrifice_plan = function(menu)
    if not menu_enabled(menu, "use_pet_sacrifice", true) then return nil end
    if not spells.demonic_sacrifice:is_learned() then return nil end
    local mode = menu_number(menu, "rotation_mode", 1)

    -- Shadow Destro + DS/Ruin: Succubus sacrifice (shadow dmg)
    if mode == 2 or mode == 5 then
        return { buff_id = SACRIFICE_SUCCUBUS_BUFF, pet_npc = PET_SUCCUBUS, summon = spells.summon_succubus }
    end

    -- Fire Destro: Imp sacrifice (fire dmg)
    if mode == 3 then
        return { buff_id = SACRIFICE_IMP_BUFF, pet_npc = PET_IMP, summon = spells.summon_imp }
    end

    return nil
end

local function try_pve_sacrifice_ooc(player, menu)
    local plan = pve_sacrifice_plan(menu)
    if not plan then return false end

    if player:buff_up(plan.buff_id) then
        return false
    end

    local pet = player:get_pet()
    local pet_id = 0
    if pet and pet:is_valid() and pet:is_alive() then
        pcall(function() pet_id = num(pet:get_npc_id(), 0) end)
    end

    -- Summon correct demon first (don’t fight the normal auto-summon logic)
    if pet_id ~= plan.pet_npc then
        if plan.summon and plan.summon:is_learned() and plan.summon:is_castable({ skip_facing = true }) then
            if plan.summon:cast(player) then
                last_summon_finish_ms = now_ms() + 6000
                return true
            end
        end
        return false
    end

    if spells.demonic_sacrifice:is_castable({ skip_facing = true }) and spells.demonic_sacrifice:cast(pet) then
        return true
    end

    return false
end

local function try_auto_summon_pet(player, menu)
    if not menu_enabled(menu, "auto_summon_pet", true) or player:is_moving() then return false end

    local now = core.game_time()
    if (now - last_summon_finish_ms) < 5000 then return false end

    -- DS builds: once sacrificed, do not auto-resummon in PvE modes.
    local plan = pve_sacrifice_plan(menu)
    if plan and player:buff_up(plan.buff_id) then
        return false
    end

    local pet = player:get_pet()
    if pet and pet:is_valid() and pet:is_alive() then return false end

    local preferred = menu_number(menu, "preferred_pet", 1)
    -- 1=Felguard, 2=Imp, 3=Succubus, 4=Felhunter, 5=VW

    -- Smart pet selection (optional): pick sensible defaults for PvE by spec/context.
    if menu_enabled(menu, "smart_pet", true) then
        local mode = menu_number(menu, "rotation_mode", 1)
        local instance_type = ""
        pcall(function() instance_type = tostring(core.get_instance_type() or "") end)
        local in_instance = instance_type == "party" or instance_type == "raid"

        -- Demonology -> Felguard; Affliction in dungeons/raids -> Imp (Blood Pact)
        if mode == 4 then
            preferred = 1
        elseif mode == 1 and in_instance then
            preferred = 2
        end
    end
    local candidates = { spells.summon_felguard, spells.summon_imp, spells.summon_succubus, spells.summon_felhunter, spells.summon_voidwalker }
    if preferred == 2 then candidates = { spells.summon_imp, spells.summon_felguard, spells.summon_succubus, spells.summon_felhunter, spells.summon_voidwalker }
    elseif preferred == 3 then candidates = { spells.summon_succubus, spells.summon_felguard, spells.summon_imp, spells.summon_felhunter, spells.summon_voidwalker }
    elseif preferred == 4 then candidates = { spells.summon_felhunter, spells.summon_felguard, spells.summon_imp, spells.summon_succubus, spells.summon_voidwalker }
    elseif preferred == 5 then candidates = { spells.summon_voidwalker, spells.summon_felguard, spells.summon_imp, spells.summon_succubus, spells.summon_felhunter }
    end

    for _, summon in ipairs(candidates) do
        if summon and summon:is_learned() then
            if summon:is_castable({ skip_facing = true }) and summon:cast(player) then
                last_summon_finish_ms = now + 6000
                return true
            end
        end
    end
    return false
end

local function try_out_of_combat(player, menu)
    if player:is_moving() or player:is_channeling_or_casting() then return false end

    -- Arena prep sequence (VW Sacrifice -> summon pet -> Soul Link + consumable setup)
    if try_arena_prep(player, menu) then return true end

    -- PvE Demonic Sacrifice setup (spec-dependent, OOC only)
    if try_pve_sacrifice_ooc(player, menu) then return true end

    -- 1. Armor Buff
    if menu_enabled(menu, "use_fel_armor", true) then
        local armor = spells.fel_armor:is_learned() and spells.fel_armor or spells.demon_armor
        if armor:is_learned() and player:buff_down(armor:id()) then
            if armor:is_castable() and armor:cast(player) then return true end
        end
    end

    -- 2. Soul Link (maintain if talented and pet alive)
    -- Uses raw buff ID 19028 (not spells.soul_link:id()) to ensure buff_down works reliably
    if menu_enabled(menu, "use_soul_link", true) and spells.soul_link:is_learned() and not soul_link_is_up(player) then
        local now = core.game_time()
        if (now - last_soul_link_attempt_ms) > SOUL_LINK_THROTTLE_MS then
            local pet = player:get_pet()
            if pet and pet:is_valid() and pet:is_alive() then
                last_soul_link_attempt_ms = now
                if spells.soul_link:is_castable() and spells.soul_link:cast(player) then
                    soul_link_assumed_until_ms = now + 1500
                    return true
                end
            end
        end
    end

    -- 3. Pet Summoning
    if try_auto_summon_pet(player, menu) then return true end

    -- 4. Creation (Healthstone / Spellstone / Soulstone)
    if mana_pct(player) > 70 and soul_shard:count() > 0 then
        -- Healthstone (create if enabled and none exists)
        if menu_enabled(menu, "use_healthstone", true) then
            local has_hs = false
            pcall(function() has_hs = healthstone_item and healthstone_item:in_inventory() end)
            if not has_hs then
                for _, create_spell in ipairs(create_healthstone_spells) do
                    if create_spell and create_spell:is_learned() and create_spell:is_castable({ skip_facing = true }) then
                        if create_spell:cast(player) then return true end
                    end
                end
            end
        end

        -- Spellstone (create if enabled and none exists)
        if menu_enabled(menu, "use_spellstone_ooc", true) and spells.create_spellstone:is_learned() then
            local has_ss = false
            pcall(function() has_ss = spellstone_item and spellstone_item:in_inventory() end)
            if not has_ss and spells.create_spellstone:is_castable({ skip_facing = true }) then
                if spells.create_spellstone:cast(player) then return true end
            end
        end
    end

    -- 5. Soulstone (create if none exists in bags)
    if mana_pct(player) > 70 and soul_shard:count() > 0 and spells.create_soulstone:is_learned() then
        local has_soulstone = false
        pcall(function() has_soulstone = soulstone_item and soulstone_item:in_inventory() end)
        if not has_soulstone and spells.create_soulstone:is_castable({ skip_facing = true }) then
            if spells.create_soulstone:cast(player) then return true end
        end
    end

    return false
end

-- ============================================================================
-- MAIN ENTRY
-- ============================================================================

local function try_soulshatter(player, target, menu)
    if not menu_enabled(menu, "use_soulshatter", true) then return false end
    if not spells.soulshatter:is_learned() then return false end
    if not player or player:is_dead() or player:is_ghost() then return false end
    if not target or not target:is_valid_enemy() or not target:is_alive() then return false end

    local ok, info = pcall(function() return player:get_threat_situation(target) end)
    if not ok or type(info) ~= "table" then return false end
    if info.is_tanking == true then return false end

    local threat_pct = num(info.threat_percent, 0)
    local threshold = menu_number(menu, "soulshatter_threat_pct", 90)
    if threat_pct < threshold then return false end

    if spells.soulshatter:is_castable({ skip_facing = true }) and spells.soulshatter:cast(player) then
        return true
    end

    return false
end

local function try_burst_cooldowns(player, target, menu)
    if not want_burst(menu) then return false end
    if not player or player:is_dead() or player:is_ghost() then return false end
    if not target or not target:is_valid_enemy() or not target:is_alive() then return false end

    local min_ttd = menu_number(menu, "burst_min_ttd_sec", 15)
    local ttd = ttd_sec(target)
    if min_ttd > 0 and ttd > 0 and ttd < min_ttd then
        return false
    end

    if menu_enabled(menu, "use_trinkets", true) then
        for _, tr in ipairs(get_usable_trinkets(player)) do
            if tr then
                if tr.use_self_safe then
                    if tr:use_self_safe("Trinket") then return true end
                else
                    local ok_use, used = pcall(function() return tr:use() end)
                    if ok_use and used == true then return true end
                end
            end
        end
    end

    if menu_enabled(menu, "use_drums", false) and drums_battle_item then
        local has = false
        pcall(function() has = drums_battle_item:in_inventory() end)
        if has and drums_battle_item.cooldown_up and drums_battle_item:cooldown_up() then
            if drums_battle_item.use_self_safe and drums_battle_item:use_self_safe("Drums of Battle") then
                return true
            end
            local ok_use, used = pcall(function() return drums_battle_item:use() end)
            if ok_use and used == true then return true end
        end
    end

    if menu_enabled(menu, "use_racials", true) then
        if spells.blood_fury and spells.blood_fury.is_learned and spells.blood_fury:is_learned() then
            if spells.blood_fury.cooldown_up and spells.blood_fury:cooldown_up() and spells.blood_fury:is_castable({ skip_facing = true }) then
                if spells.blood_fury:cast(player) then return true end
            end
        end
        if spells.berserking and spells.berserking.is_learned and spells.berserking:is_learned() then
            if spells.berserking.cooldown_up and spells.berserking:cooldown_up() and spells.berserking:is_castable({ skip_facing = true }) then
                if spells.berserking:cast(player) then return true end
            end
        end
    end

    return false
end

function rotation_logic:execute(player, menu)
    -- Defense-in-depth: block all rotation logic when toggle is off
    -- Primary gate is in main.lua:on_update, this is a safety net
    if menu.enable_toggle and plugin_helper:is_toggle_enabled(menu.enable_toggle) ~= true then
        return false
    end

    local pvp_enabled = plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) or menu_enabled(menu, "pvp_mode", false)
    local target = izi.target()

    if try_arcane_torrent_interrupt(player, target, menu) then
        return true
    end

    -- PvP: delegate completely (handles OOC prep + in-combat APL)
    -- Important: do this BEFORE PvE defensives/maintenance to avoid double-casts (e.g. Soul Link).
    if pvp_enabled then
        return pvp_module.execute(player, target, menu) == true
    end

    if not player:is_in_combat() then
        if player:is_channeling_or_casting() then return false end
        return try_out_of_combat(player, menu)
    end

    -- 1. Defensive / Maintenance (BEFORE casting check - emergency survival during casts)
    if try_defensives(player, target, menu) then return true end

    -- 2. Let current cast/channel finish
    if player:is_channeling_or_casting() then return false end

    if not target or not target:is_valid_enemy() or not target:is_alive() then return false end

    -- 2. Pet Attack & Automation
    try_pet_attack(player, target)
    handle_pet_automation(player, target, menu)

    -- 2.5 Threat drop (before committing to more damage)
    if try_soulshatter(player, target, menu) then return true end

    -- 3. Drain Soul (execute phase, before rotation)
    if try_drain_soul(player, target, menu) then return true end

    -- 3.5 Burst cooldowns (keybind-driven)
    if try_burst_cooldowns(player, target, menu) then return true end

    -- 3. AoE (Seed of Corruption) - not in PvP
    if not pvp_enabled then
        if try_aoe(player, target, menu) then return true end
    end

    -- 4. Rotation Mode
    do
        -- Nightfall proc: instant Shadow Bolt (highest priority after defensives in all PvE modes)
        if player:buff_up(SHADOW_TRANCE_BUFF) and spells.shadow_bolt:is_castable() then
            stop_wand_if_active(player, target)
            if spells.shadow_bolt:cast(target) then return true end
        end

        local mode = menu_number(menu, "rotation_mode", 1)
        if mode == 1 then
            if execute_affliction(player, target, menu) then return true end
        elseif mode == 2 then
            if execute_shadow_destruction(player, target, menu) then return true end
        elseif mode == 3 then
            if execute_fire_destruction(player, target, menu) then return true end
        elseif mode == 4 then
            if execute_demonology(player, target, menu) then return true end
        elseif mode == 5 then
            if execute_ds_ruin(player, target, menu) then return true end
        end
    end

    -- 5. Resources
    if try_resources(player, target, menu) then return true end

    -- 6. Wand Fallback (when nothing else to do)
    if target and not player:is_moving() and menu_enabled(menu, "use_wand", true) and auto_attack_helper then
        if not is_wanding_active(player) and not player:is_channeling_or_casting() then
            if auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) then
                return true
            end
        end
    end

    return false
end

return rotation_logic
