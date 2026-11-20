local inventory_maintenance=require("rotations/warlock/era/inventory_maintenance")
local cast_guard=require("rotations/warlock/era/cast_guard")
local forever_affliction=require("rotations/warlock/era/forever_affliction")
local forever_client=require("shared/game_client")
local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock APL (Classic ERA) - Strict Mode Rewrite
-- "The Enforcer" - Prioritizes stability, strict toggle adherence, and correct execution.
-- ============================================================================

local rotation_logic = {}

---@type izi_sdk
local izi = require("common/izi_sdk")
---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")
---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

local spells = require("rotations/warlock/era/spells")
local dr_helper = require("shared/dr_helper")

local SOUL_SHARD_ITEM_ID = 6265
local soul_shard = izi.item(SOUL_SHARD_ITEM_ID)

-- Healthstone ITEM IDs (highest rank first) -- includes Improved Healthstone talent variants
local healthstone_item = izi.item({
    9421,  19012, 19013, -- Major Healthstone (base, imp1, imp2)
    5510,  19010, 19011, -- Greater Healthstone
    5509,  19008, 19009, -- Healthstone
    5511,  19006, 19007, -- Lesser Healthstone
    5512,  19004, 19005, -- Minor Healthstone
})

-- ============================================================================
-- STATE TRACKING
-- ============================================================================
-- Buff / Debuff IDs
local SHADOW_TRANCE_BUFF       = 17941  -- Nightfall proc (instant Shadow Bolt)
local ISB_BUFF                 = 17800  -- Improved Shadow Bolt debuff on target
local SACRIFICE_SUCCUBUS_BUFF  = 18791  -- +15% Shadow Damage (Demonic Sacrifice)
local SACRIFICE_IMP_BUFF       = 18789  -- +15% Fire Damage
local SACRIFICE_VW_BUFF        = 18790  -- HP Regen
local SACRIFICE_FH_BUFF        = 18792  -- Mana Regen
-- Some clients report Soul Link aura with a different spell id than the cast id.
-- Keep a small list and also fall back to pet aura to avoid re-casting forever.
local SOUL_LINK_BUFFS          = { 19028, 25228 }
local last_soul_link_attempt_ms = 0
local SOUL_LINK_THROTTLE_MS     = 2000
local soul_link_assumed_until_ms = 0

-- Pet NPC IDs
local PET_VOIDWALKER = 1860
local PET_FELHUNTER  = 417
local PET_SUCCUBUS   = 1863

-- Pet Spell IDs
local SPELL_LOCK_ID   = 19244
local DEVOUR_MAGIC_ID = 19746
local SEDUCTION_ID    = 6358

-- Caster classes
local CLASS_PRIEST  = 5
local CLASS_MAGE    = 8
local CLASS_WARLOCK = 9
local CLASS_DRUID   = 11
local CLASS_SHAMAN  = 7
local CLASS_PALADIN = 2

local last_wand_start_ms = 0
local last_spell_lock_ms = 0

-- Pandemic Refresh Windows (spell-specific)
-- agony = 0: NEVER refresh early, damage ramps in last ticks
local PANDEMIC = {
    corruption = 5400,  -- 18s * 30%
    agony = 0,          -- Never refresh early
    immolate = 4500,    -- 15s * 30%
    siphon = 9000,      -- 30s * 30%
    curse_other = 7200  -- 24s * 30% (for non-agony curses: Elements, Shadow, Tongues, etc.)
}

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

local CLASS_NAMES = {
    [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue",
    [5] = "Priest",  [7] = "Shaman",  [8] = "Mage",   [9] = "Warlock",
    [11] = "Druid",
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function num(v, fallback) return tonumber(v) or fallback end

local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then return fallback end
    local ok, v = pcall(function() return menu[key]:get() end)
    return ok and num(v, fallback) or fallback
end

local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then return fallback end
    local ok, v = pcall(function() return menu[key]:get_state() end)
    if ok then return v end -- Explicit return of boolean state
    return fallback
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

-- ============================================================================
-- CASTING ENGINE (Strict Wand Control)
-- ============================================================================

local function is_wanding(player)
    -- Generic auto-attacking also covers melee. Identify Shoot specifically.
    return player:get_active_channel_spell_id()==5019 or player:get_active_spell_id()==5019
        or core.spell_book.is_current_spell(5019)==true
end

local function stop_wand(player, target)
    if is_wanding(player) then
        if auto_attack_helper then
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
        end
        return true
    end
    return false
end

--- Tries to cast a spell with strict safety checks.
--- @param player game_object
--- @param target game_object target to cast on (can be player for self-buffs)
--- @param spell table The spell object (from spells.lua)
--- @param menu table The menu configuration
--- @param allow_wand_break boolean If true, will interrupt active wanding. If false, fails if wanding.
local legacy_dot_wait=false
local function legacy_damage_filler(player,spell,menu)
    for _,name in ipairs({'shadow_bolt','shadowburn','drain_life','rain_of_fire','hellfire','searing_pain','soul_fire'}) do
        if rawequal(spell,spells[name]) then
            if name=="drain_life" and hp_pct(player)<=menu_number(menu,"drain_life_hp_pct",45) then return false end
            return true
        end
    end
    return false
end
local function try_cast(player, target, spell, menu, allow_wand_break)
    if not spell or not spell:is_learned() then return false end
    if not target then return false end

    local dot_toggles={corruption="use_corruption",curse_of_agony="use_curse_of_agony",siphon_life="use_siphon_life",immolate="use_immolate"}
    for name,toggle in pairs(dot_toggles) do
        if rawequal(spell,spells[name]) and not menu_enabled(menu,toggle,name~="immolate") then return false end
    end
    if rawequal(spell,spells.shadowburn) and soul_shard:count()<=menu_number(menu,"min_soul_shards",3) then return false end
    if legacy_dot_wait and legacy_damage_filler(player,spell,menu) then return false end

    local dot_key
    for name,key in pairs({corruption="corruption",curse_of_agony="bane_of_agony",
        siphon_life="siphon_life",immolate="immolate",curse_of_elements="curse_of_elements",
        curse_of_doom="curse_of_doom",curse_of_weakness="curse_of_weakness",
        curse_of_tongues="curse_of_tongues",curse_of_recklessness="curse_of_recklessness",
        curse_of_shadow="curse_of_shadow",curse_of_exhaustion="curse_of_exhaustion"}) do
        if rawequal(spell,spells[name]) then dot_key=key;break end
    end
    if dot_key then
        local window=(dot_key=="corruption" or dot_key=="siphon_life" or dot_key=="immolate")
            and menu_number(menu,"aff_refresh_window_ms",0) or 0
        if not forever_affliction.dot_ready(player,target,dot_key,spell,window) then return false end
    end

    local guard_key
    for _,name in ipairs({'fear','howl_of_terror','death_coil','banish','enslave_demon'}) do
        if rawequal(spell,spells[name]) then guard_key=name;break end
    end
    guard_key=guard_key or ('spell:'..tostring(spell:id()))
    if not cast_guard.allow(player,target,spell,guard_key) then return false end

    local is_funnel=rawequal(spell,spells.health_funnel)
    if is_funnel and not forever_affliction.pet_heal_allowed(player,target,menu) then return false end

    if forever_affliction.await_spell_start(player) and legacy_damage_filler(player,spell,menu) then return false end

    -- 1. Wand Protection
    local wanding = is_wanding(player)
    if wanding and not allow_wand_break then
        return false -- STRICT: Do not break wand for this spell
    end

    -- 3. Cast
    if spell:is_castable_to_unit(target) then
        forever_affliction.clear_queued_wand()
        if wanding and allow_wand_break then
            stop_wand(player, target)
            return true
        end

        local accepted,meta=spell:cast(target)
        if not (meta and meta.reason=="fast_queue_busy") then
            cast_guard.attempt(target,spell,guard_key,accepted==true)
        end
        if accepted then
            local request_key=guard_key
            for _,name in ipairs({'health_funnel','drain_life','drain_soul','hellfire'}) do
                if rawequal(spell,spells[name]) then request_key=name;break end
            end
            forever_affliction.note_cast_request(player,target,spell,request_key)
            if is_funnel then forever_affliction.record_pet_heal(player,target) end
            if dot_key then forever_affliction.record_dot(target,dot_key,spell) end
            return true
        end
    end
    return false
end

local function own_debuff_down(player,target,spell)
    return forever_affliction.own_dot_remains(player,target,spell.ids or {spell:id()})<=0
end
local function needs_refresh(target,spell_id,refresh_ms)
    local player=core.object_manager.get_local_player()
    if not __object_safety.valid(player) or not __object_safety.valid(target) then return false end
    local spell_ids={spell_id}
    for _,name in ipairs({'corruption','curse_of_agony','siphon_life','immolate','curse_of_elements','curse_of_shadow','curse_of_recklessness','curse_of_tongues','curse_of_weakness','curse_of_doom'}) do
        if spells[name]:id()==spell_id then spell_ids=spells[name].ids or spell_ids;break end
    end
    local remaining=forever_affliction.own_dot_remains(player,target,spell_ids)
    return remaining<=0 or remaining<(refresh_ms or 0)
end

-- ============================================================================
-- LOGIC SUB-ROUTINES
-- ============================================================================

local function get_pet_npc_id(player)
    local pet = player:get_pet()
    if not pet or not pet:is_valid() or not pet:is_alive() then return nil, nil end
    local ok, npc_id = pcall(function() return pet:get_npc_id() end)
    return pet, (ok and tonumber(npc_id) or nil)
end

local function is_caster_class(class_id)
    return class_id == CLASS_PRIEST or class_id == CLASS_MAGE
        or class_id == CLASS_WARLOCK or class_id == CLASS_DRUID
        or class_id == CLASS_SHAMAN or class_id == CLASS_PALADIN
end

local function try_emergency_survival(player, target, menu)
    local hp = hp_pct(player)

    -- 1. Voidwalker Sacrifice (Emergency Shield)
    if menu_enabled(menu, "use_pet_sacrifice", true) then
        local sac_hp = menu_number(menu, "pet_sacrifice_hp_pct", 25)
        if hp <= sac_hp then
            local pet, npc_id = get_pet_npc_id(player)
            if pet and npc_id == PET_VOIDWALKER then
                if spells.sacrifice and spells.sacrifice:is_learned() and spells.sacrifice:is_castable() then
                    if spells.sacrifice:cast(player) then
                        pvp_log("pvp.emergency.vwsac", 0, string.format("[Warlock][PvP][Emergency] VW Sacrifice at hp=%d%%", hp))
                        return true
                    end
                end
            else
                pvp_log("pvp.emergency.vwsac.guard", 2000, string.format("[Warlock][PvP][Emergency] VW Sac needed (hp=%d%%) but pet=%s", hp, npc_id and tostring(npc_id) or "none"))
            end
        end
    end

    -- 2. Healthstone (High Priority)
    local hs_thresh = menu_number(menu, "healthstone_hp_pct", 35)
    if hp <= hs_thresh and menu_enabled(menu, "use_healthstone", true) then
        if izi.use_best_health_potion_safe({ skip_moving = false, skip_casting = true }) then
            pvp_log("pvp.emergency.potion", 0, string.format("[Warlock][PvP][Emergency] Health potion at hp=%d%%", hp))
            return true
        end
        if healthstone_item and healthstone_item:in_inventory() then
            if healthstone_item:use_self_safe("Healthstone") then
                pvp_log("pvp.emergency.hs", 0, string.format("[Warlock][PvP][Emergency] Healthstone at hp=%d%%", hp))
                return true
            end
        end
    end

    -- 3. Emergency CC (Break Wand allowed!)
    if menu_enabled(menu, "use_emergency_cc", true) then
        local cc_thresh = menu_number(menu, "death_coil_hp_pct", 20)
        if hp <= cc_thresh then
            if try_cast(player, target, spells.death_coil, menu, true) then
                pvp_log("pvp.emergency.cc", 0, string.format("[Warlock][PvP][Emergency] Death Coil at hp=%d%%", hp))
                return true
            end
        end
        local howl_thresh = menu_number(menu, "howl_hp_pct", 15)
        if hp <= howl_thresh then
            if try_cast(player, target, spells.howl_of_terror, menu, true) then
                pvp_log("pvp.emergency.cc", 0, string.format("[Warlock][PvP][Emergency] Howl of Terror at hp=%d%%", hp))
                return true
            end
        end
        local fear_thresh = menu_number(menu, "fear_hp_pct", 30)
        if hp <= fear_thresh and not player:is_moving() then
            if try_cast(player, target, spells.fear, menu, true) then
                pvp_log("pvp.emergency.cc", 0, string.format("[Warlock][PvP][Emergency] Fear at hp=%d%%", hp))
                return true
            end
        end
    end

    return false
end

local function try_pet_management(player, target, menu, skip_pet_attack)
    local pet = player:get_pet()
    if not pet or not pet:is_alive() then return false end

    -- 1. Pet Attack
    if not skip_pet_attack and target and target:is_valid_enemy() then
        local is_attacking = false
        pcall(function() is_attacking = pet:is_auto_attacking() end)
        if not is_attacking then
            if core.input and core.input.pet_attack then core.input.pet_attack(target) end
        end
    end

    -- 2. Spell Lock (Felhunter interrupt)
    if menu_enabled(menu, "auto_spell_lock", true) then
        local _, npc_id = get_pet_npc_id(player)
        if npc_id == PET_FELHUNTER and core.input and core.input.pet_cast_target_spell then
            local now = core.game_time()
            if (now - last_spell_lock_ms) > 1500 then
                -- Scan all enemies for healer casts first
                local enemies = izi.enemies(30)
                if enemies then
                    for _, enemy in ipairs(enemies) do
                        if enemy:is_valid_enemy() and enemy:is_alive() then
                            local eclass = 0
                            pcall(function() eclass = enemy:get_class() end)
                            if eclass == CLASS_PRIEST or eclass == CLASS_DRUID or eclass == CLASS_PALADIN or eclass == CLASS_SHAMAN then
                                local e_casting = false
                                pcall(function() e_casting = enemy:is_casting_spell() end)
                                local e_int = false
                                pcall(function() e_int = enemy:is_active_spell_interruptable() end)
                                if e_casting and e_int then
                                    local ok, result = pcall(core.input.pet_cast_target_spell, SPELL_LOCK_ID, enemy)
                                    if ok and result then
                                        pvp_log("pvp.pet.spelllock", 0, "[Warlock][PvP][Pet] Spell Lock on " .. safe_name(enemy) .. " (healer priority)")
                                        last_spell_lock_ms = now
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
                -- Fallback: interrupt current target
                if target then
                    local ok_cast, is_casting = pcall(function() return target:is_casting_spell() end)
                    local ok_int, interruptable = pcall(function() return target:is_active_spell_interruptable() end)
                    if ok_cast and is_casting and ok_int and interruptable then
                        local ok, result = pcall(core.input.pet_cast_target_spell, SPELL_LOCK_ID, target)
                        if ok and result then
                            pvp_log("pvp.pet.spelllock", 0, "[Warlock][PvP][Pet] Spell Lock on " .. safe_name(target) .. " (current target)")
                            last_spell_lock_ms = now
                            return true
                        end
                    end
                end
            else
                pvp_log("pvp.pet.spelllock.guard", 2000, "[Warlock][PvP][Pet] Spell Lock throttled")
            end
        else
            pvp_log("pvp.pet.spelllock.guard", 2000, string.format("[Warlock][PvP][Pet] Spell Lock: no felhunter (pet=%s)", tostring(npc_id)))
        end
    end

    -- 3. Devour Magic (Felhunter purge)
    local _, npc_id2 = get_pet_npc_id(player)
    if npc_id2 == PET_FELHUNTER and core.input and core.input.pet_cast_target_spell then
        -- Self-purge Magic or Curse debuffs
        local ok_deb, debuffs = pcall(function() return player:get_debuffs() end)
        if ok_deb and debuffs then
            for _, d in ipairs(debuffs) do
                if d.type == 1 or d.type == 4 then -- Magic or Curse
                    local ok, result = pcall(core.input.pet_cast_target_spell, DEVOUR_MAGIC_ID, player)
                    if ok and result then
                        local dtype = d.type == 1 and "Magic" or "Curse"
                        pvp_log("pvp.pet.devour", 0, "[Warlock][PvP][Pet] Devour Magic self-purge (" .. dtype .. " debuff)")
                        return true
                    end
                    break
                end
            end
        end
        -- Enemy purge (PW:S, BoP, Ice Barrier, Fear Ward)
        if target and target:is_valid_enemy() and target:is_alive() then
            local purgeable = { 17, 1022, 6346 } -- PW:S, BoP, Fear Ward
            for _, buff_id in ipairs(purgeable) do
                local ok_b, has = pcall(function() return target:buff_up(buff_id) end)
                if ok_b and has then
                    local ok, result = pcall(core.input.pet_cast_target_spell, DEVOUR_MAGIC_ID, target)
                    if ok and result then
                        pvp_log("pvp.pet.devour", 0, string.format("[Warlock][PvP][Pet] Devour Magic purged buff %d from %s", buff_id, safe_name(target)))
                        return true
                    end
                end
            end
        end
    end

    -- 4. Health Funnel (Break Wand allowed)
    if menu_enabled(menu, "use_health_funnel", true) and not player:is_moving() then
        local pet_hp = hp_pct(pet)
        local my_hp = hp_pct(player)
        if pet_hp < menu_number(menu, "health_funnel_pet_hp_pct", 40) and my_hp > 30 then
            if try_cast(player, pet, spells.health_funnel, menu, true) then
                pvp_log("pvp.pet.funnel", 0, string.format("[Warlock][PvP][Pet] Health Funnel (pet_hp=%d%% my_hp=%d%%)", pet_hp, my_hp))
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- PVP LOGIC (DR-Aware)
-- ============================================================================

local function try_pvp_pet_utility(player, target, menu)
    local pet, npc_id = get_pet_npc_id(player)
    if not pet then return false end
    if not core.input or not core.input.pet_cast_target_spell then return false end

    -- Succubus: Seduce secondary target (4b: prioritize healers)
    if npc_id == PET_SUCCUBUS and menu_enabled(menu, "use_seduce_pvp", true) then
        local enemies = izi.enemies(30)
        if enemies then
            -- Sort: healers first for seduce priority
            local healer_targets = {}
            local other_targets = {}
            for _, enemy in ipairs(enemies) do
                if enemy:is_valid_enemy() and enemy:is_alive() and (not __object_safety.same(enemy,target)) then
                    local is_cc = false
                    pcall(function()
                        if enemy.CC then is_cc = enemy:is_cc(1000, enemy.CC.ANY) end
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
            -- Try healers first, then others
            for _, e in ipairs(healer_targets) do
                local ok, result = pcall(core.input.pet_cast_target_spell, SEDUCTION_ID, e)
                if ok and result then
                    pvp_log("pvp.seduce", 0, "[Warlock][PvP][Pet] Seduce on " .. safe_name(e) .. " (healer priority)")
                    return true
                end
            end
            for _, e in ipairs(other_targets) do
                local ok, result = pcall(core.input.pet_cast_target_spell, SEDUCTION_ID, e)
                if ok and result then
                    pvp_log("pvp.seduce", 0, "[Warlock][PvP][Pet] Seduce on " .. safe_name(e) .. " (secondary)")
                    return true
                end
            end
        end
    end

    return false
end

local function try_pvp_logic(player, target, menu)
    local t_hp = hp_pct(target)
    local my_hp = hp_pct(player)

    pvp_log("pvp.entry", 500, string.format("[Warlock][PvP] Priority chain: target=%s t_hp=%d%% my_hp=%d%%", safe_name(target), t_hp, my_hp))

    -- 1. Pet Utility (handled by try_pet_management for Spell Lock / Devour)
    if try_pvp_pet_utility(player, target, menu) then return true end

    -- 2. Soul Link maintenance
    if spells.soul_link:is_learned() and not soul_link_is_up(player) then
        local now = core.game_time()
        if (now - last_soul_link_attempt_ms) > SOUL_LINK_THROTTLE_MS then
            local pet = player:get_pet()
            if pet and pet:is_valid() and pet:is_alive() then
                last_soul_link_attempt_ms = now
                if try_cast(player, player, spells.soul_link, menu, true) then
                    soul_link_assumed_until_ms = now + 1500
                    pvp_log("pvp.soullink", 0, "[Warlock][PvP][Def] Soul Link applied")
                    return true
                end
            else
                pvp_log("pvp.soullink", 1000, "[Warlock][PvP][Def] Soul Link needed but pet dead/missing")
            end
        end
    end

    -- 3. DR-aware CC Chain
    if menu_enabled(menu, "use_fear_pvp", true) and t_hp > 20 then
        local best_cc = dr_helper.get_best_cc(target)
        pvp_log("pvp.cc", 500, string.format("[Warlock][PvP][CC] best_cc=%s for %s", tostring(best_cc), safe_name(target)))
        if best_cc == "fear" and not player:is_moving() then
            if try_cast(player, target, spells.fear, menu, true) then
                pvp_log("pvp.cc", 0, "[Warlock][PvP][CC] Casting Fear on " .. safe_name(target))
                return true
            end
        elseif best_cc == "death_coil" then
            if try_cast(player, target, spells.death_coil, menu, true) then
                pvp_log("pvp.cc", 0, "[Warlock][PvP][CC] Death Coil on " .. safe_name(target))
                return true
            end
        elseif best_cc == "howl" then
            if try_cast(player, target, spells.howl_of_terror, menu, true) then
                pvp_log("pvp.cc", 0, "[Warlock][PvP][CC] Howl of Terror on " .. safe_name(target))
                return true
            end
        end
    end

    -- 4. Curse selection (class-aware)
    local class = 0
    pcall(function() class = target:get_class() end)
    local class_name = CLASS_NAMES[class] or tostring(class)
    if is_caster_class(class) and menu_enabled(menu, "auto_curse_tongues_pvp", true) then
        if own_debuff_down(player,target,spells.curse_of_tongues) then
            if spells.amplify_curse:is_learned() and spells.amplify_curse:is_castable() then
                if spells.amplify_curse:cast(player) then
                    pvp_log("pvp.curse", 0, "[Warlock][PvP][Curse] Amplify Curse before Tongues on " .. safe_name(target))
                    return true
                end
            end
            if try_cast(player, target, spells.curse_of_tongues, menu, true) then
                pvp_log("pvp.curse", 0, string.format("[Warlock][PvP][Curse] Curse of Tongues on %s (%s=caster)", safe_name(target), class_name))
                return true
            end
        end
    else
        if spells.curse_of_exhaustion:is_learned() and own_debuff_down(player,target,spells.curse_of_exhaustion) then
            if spells.amplify_curse:is_learned() and spells.amplify_curse:is_castable() then
                if spells.amplify_curse:cast(player) then
                    pvp_log("pvp.curse", 0, "[Warlock][PvP][Curse] Amplify Curse before Exhaustion on " .. safe_name(target))
                    return true
                end
            end
            if try_cast(player, target, spells.curse_of_exhaustion, menu, true) then
                pvp_log("pvp.curse", 0, string.format("[Warlock][PvP][Curse] Curse of Exhaustion on %s (%s=melee)", safe_name(target), class_name))
                return true
            end
        end
    end

    -- 5. DoT Pressure
    if own_debuff_down(player,target,spells.corruption) then
        if try_cast(player, target, spells.corruption, menu, true) then
            pvp_log("pvp.dots", 0, "[Warlock][PvP][DoT] Corruption on " .. safe_name(target))
            return true
        end
    end
    if spells.siphon_life:is_learned() and own_debuff_down(player,target,spells.siphon_life) then
        if try_cast(player, target, spells.siphon_life, menu, true) then
            pvp_log("pvp.dots", 0, "[Warlock][PvP][DoT] Siphon Life on " .. safe_name(target))
            return true
        end
    end

    -- 5b. Multi-DoT Corruption spreading
    if menu_enabled(menu, "pvp_dot_spread", true) then
        local max_spread = menu_number(menu, "pvp_dot_spread_limit", 3)
        local spread_count = 0
        local enemies = izi.enemies(30)
        if enemies then
            for _, enemy in ipairs(enemies) do
                if spread_count >= max_spread then break end
                if enemy:is_valid_enemy() and enemy:is_alive() and (not __object_safety.same(enemy,target)) then
                    local is_cc = false
                    pcall(function()
                        if enemy.CC then is_cc = enemy:is_cc(1000, enemy.CC.ANY) end
                    end)
                    if not is_cc and own_debuff_down(player,enemy,spells.corruption) then
                        if try_cast(player, enemy, spells.corruption, menu, true) then
                            pvp_log("pvp.spread", 0, string.format("[Warlock][PvP][Spread] Corruption on %s (%d/%d)", safe_name(enemy), spread_count + 1, max_spread))
                            return true
                        end
                        spread_count = spread_count + 1
                    end
                end
            end
        end
    end

    -- 6. Shadowburn Execute
    if spells.shadowburn:is_learned() and (t_hp < 20 or player:is_moving()) then
        if try_cast(player, target, spells.shadowburn, menu, true) then
            local reason = t_hp < 20 and "execute" or "moving"
            pvp_log("pvp.shadowburn", 0, string.format("[Warlock][PvP][Burst] Shadowburn on %s at %d%% (%s)", safe_name(target), t_hp, reason))
            return true
        end
    end

    -- 7. Nightfall proc
    if player:buff_up(SHADOW_TRANCE_BUFF) then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then
            pvp_log("pvp.nightfall", 0, "[Warlock][PvP][Filler] Nightfall proc -> Shadow Bolt on " .. safe_name(target))
            return true
        end
    end

    -- 8. Offensive Howl of Terror
    if menu_enabled(menu, "use_howl_offensive", true) and spells.howl_of_terror:is_learned() then
        local nearby_count = 0
        local nearby_enemies = izi.enemies(8)
        if nearby_enemies then
            for _, e in ipairs(nearby_enemies) do
                if e:is_valid_enemy() and e:is_alive() then
                    nearby_count = nearby_count + 1
                end
            end
        end
        if nearby_count >= 2 then
            local fear_dr = dr_helper.get_dr(target, "fear")
            if fear_dr >= 0.5 then
                if try_cast(player, target, spells.howl_of_terror, menu, true) then
                    pvp_log("pvp.howl", 0, string.format("[Warlock][PvP][CC] Offensive Howl, %d melee, dr=%.2f", nearby_count, fear_dr))
                    return true
                end
            end
        end
    end

    -- 9. Drain Life sustain
    if not player:is_moving() and my_hp < 60 then
        if try_cast(player, target, spells.drain_life, menu, true) then
            pvp_log("pvp.drainlife", 0, string.format("[Warlock][PvP][Filler] Drain Life (hp=%d%%)", my_hp))
            return true
        end
    end

    -- 10. Drain Mana vs healer
    if menu_enabled(menu, "use_drain_mana_pvp", true) and not player:is_moving() then
        local ok_mp, t_mana = pcall(function() return target:mana_pct() end)
        if ok_mp and t_mana and t_mana > 20 then
            local t_class = 0
            pcall(function() t_class = target:get_class() end)
            local is_healer = (t_class == CLASS_PRIEST or t_class == CLASS_DRUID
                or t_class == CLASS_PALADIN or t_class == CLASS_SHAMAN)
            if is_healer then
                if try_cast(player, target, spells.drain_mana, menu, true) then
                    pvp_log("pvp.drainmana", 0, string.format("[Warlock][PvP][Filler] Drain Mana on %s (%s, t_mana=%d%%)",
                        safe_name(target), CLASS_NAMES[t_class] or "healer", t_mana))
                    return true
                end
            end
        end
    end

    -- 11. Shadow Bolt filler
    if menu_enabled(menu, "use_shadow_bolt", true) and not player:is_moving() then
        if try_cast(player, target, spells.shadow_bolt, menu, false) then
            pvp_log("pvp.filler", 500, "[Warlock][PvP][Filler] Shadow Bolt filler on " .. safe_name(target))
            return true
        end
    end

    -- 12. Drain Mana vs any caster (lower priority, mana recovery)
    if menu_enabled(menu, "use_drain_mana_pvp", true) and not player:is_moving() then
        local ok_mp, t_mana = pcall(function() return target:mana_pct() end)
        if ok_mp and t_mana and t_mana > 0 and mana_pct(player) < 70 then
            if try_cast(player, target, spells.drain_mana, menu, true) then
                pvp_log("pvp.drainmana.low", 0, string.format("[Warlock][PvP][Filler] Drain Mana (low prio) on %s, p_mana=%d%%", safe_name(target), mana_pct(player)))
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- MULTI-DOT SPREADING (PvE)
-- ============================================================================

local function try_multi_dot_spread(player, target, menu)
    -- Check checkbox OR keybind toggle
    local toggle_active = false
    if menu.aoe_dot_toggle then
        pcall(function() toggle_active = plugin_helper:is_toggle_enabled(menu.aoe_dot_toggle) end)
    end
    if not menu_enabled(menu, "multi_dot_enabled", false) and not toggle_active then return false end

    local max_targets = menu_number(menu, "multi_dot_limit", 3)
    local min_ttd = menu_number(menu, "dot_min_ttd_sec", 8)
    local dotted = 1

    local enemies = forever_affliction.engaged_targets(player,player:get_pet(),target)
    if not enemies then return false end

    for _, enemy in ipairs(enemies) do
        if dotted >= max_targets then break end
        if enemy:is_valid_enemy() and enemy:is_alive() and (not __object_safety.same(enemy,target)) then
            local ettd = ttd_sec(enemy)
            if ettd >= min_ttd then
                -- Apply Corruption
                if menu_enabled(menu, "use_corruption", true) and own_debuff_down(player,enemy,spells.corruption) then
                    if try_cast(player, enemy, spells.corruption, menu, true) then return true end
                end
                -- Apply Curse of Agony
                if menu_enabled(menu, "use_curse_of_agony", true) and own_debuff_down(player,enemy,spells.curse_of_agony) then
                    if try_cast(player, enemy, spells.curse_of_agony, menu, true) then return true end
                end
                dotted = dotted + 1
            end
        end
    end

    return false
end

-- ============================================================================
-- DS/RUIN MODE (Demonic Sacrifice + Shadow Bolt Spam)
-- ============================================================================

local function execute_ds_ruin(player, target, menu)
    -- Maintain Demonic Sacrifice buff (Succubus = +15% Shadow)
    if not player:buff_up(SACRIFICE_SUCCUBUS_BUFF) then
        if spells.demonic_sacrifice:is_learned() and spells.demonic_sacrifice:is_castable() then
            local pet = player:get_pet()
            if pet and pet:is_valid() and pet:is_alive() then
                if spells.demonic_sacrifice:cast(pet) then return true end
            end
        end
    end

    local ttd = ttd_sec(target)

    -- 1. Nightfall proc
    if player:buff_up(SHADOW_TRANCE_BUFF) then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then return true end
    end

    -- 2. Shadowburn Execute
    if spells.shadowburn:is_learned() and hp_pct(target) < 20 then
        if try_cast(player, target, spells.shadowburn, menu, true) then return true end
    end

    -- 3. Curse (one-time application)
    local curse_choice = menu_number(menu, "preferred_curse", 1)
    local curse_spell = spells.curse_of_agony
    if curse_choice == 2 then curse_spell = spells.curse_of_elements
    elseif curse_choice == 3 then curse_spell = spells.curse_of_shadow
    elseif curse_choice == 4 then curse_spell = spells.curse_of_recklessness
    elseif curse_choice == 5 then curse_spell = spells.curse_of_tongues
    elseif curse_choice == 6 then curse_spell = spells.curse_of_weakness
    end
    if ttd > 10 and own_debuff_down(player,target,curse_spell) then
        if try_cast(player, target, curse_spell, menu, true) then return true end
    end

    -- 4. Corruption (one-time, don't refresh early in DS/Ruin)
    if ttd > 12 and menu_enabled(menu, "use_corruption", true) then
        if own_debuff_down(player,target,spells.corruption) then
            if try_cast(player, target, spells.corruption, menu, true) then return true end
        end
    end

    -- 5. Shadow Bolt spam (main damage source)
    if not player:is_moving() then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then return true end
    end

    return false
end

-- ============================================================================
-- SM/RUIN MODE (Pet alive + Full DoTs + ISB tracking)
-- ============================================================================

local function execute_sm_ruin(player, target, menu)
    local ttd = ttd_sec(target)

    -- 1. Nightfall proc (highest priority)
    if player:buff_up(SHADOW_TRANCE_BUFF) then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then return true end
    end

    -- 2. Shadowburn Execute
    if spells.shadowburn:is_learned() and hp_pct(target) < 20 then
        if try_cast(player, target, spells.shadowburn, menu, true) then return true end
    end

    -- 3. Curse
    local curse_choice = menu_number(menu, "preferred_curse", 1)
    local curse_spell = spells.curse_of_agony
    if curse_choice == 2 then curse_spell = spells.curse_of_elements
    elseif curse_choice == 3 then curse_spell = spells.curse_of_shadow
    elseif curse_choice == 4 then curse_spell = spells.curse_of_recklessness
    elseif curse_choice == 5 then curse_spell = spells.curse_of_tongues
    elseif curse_choice == 6 then curse_spell = spells.curse_of_weakness
    end
    local curse_pandemic = (curse_choice == 1) and PANDEMIC.agony or PANDEMIC.curse_other
    if ttd > 8 and needs_refresh(target, curse_spell:id(), curse_pandemic) then
        if try_cast(player, target, curse_spell, menu, true) then return true end
    end

    -- 4. Corruption
    if ttd > 8 and menu_enabled(menu, "use_corruption", true) then
        if needs_refresh(target, spells.corruption:id(), PANDEMIC.corruption) then
            if try_cast(player, target, spells.corruption, menu, true) then return true end
        end
    end

    -- 5. Siphon Life (ISB snapshotting: refresh when ISB is active to lock in +20% shadow damage)
    if ttd > 10 and menu_enabled(menu, "use_siphon_life", true) and spells.siphon_life:is_learned() then
        local siphon_down = own_debuff_down(player,target,spells.siphon_life)
        local isb_active = false
        pcall(function() isb_active = target:debuff_up(ISB_BUFF) end)

        if siphon_down then
            -- Always apply if missing
            if try_cast(player, target, spells.siphon_life, menu, true) then return true end
        elseif isb_active then
            -- ISB is up: refresh Siphon Life to snapshot the +20% shadow damage bonus
            if needs_refresh(target, spells.siphon_life:id(), PANDEMIC.siphon) then
                if try_cast(player, target, spells.siphon_life, menu, true) then return true end
            end
        end
        -- If ISB not up and Siphon already running: don't refresh (preserve existing snapshot)
    end

    -- 6. Immolate
    if ttd > 8 and menu_enabled(menu, "use_immolate", false) and not player:is_moving() then
        if needs_refresh(target, spells.immolate:id(), PANDEMIC.immolate) then
            if try_cast(player, target, spells.immolate, menu, true) then return true end
        end
    end

    -- 7. Multi-DoT spreading
    if try_multi_dot_spread(player, target, menu) then return true end

    -- 8. Shadow Bolt (main filler)
    if not player:is_moving() and mana_pct(player) > menu_number(menu, "shadow_bolt_min_mana_pct", 35) then
        if try_cast(player, target, spells.shadow_bolt, menu, false) then return true end
    end

    return false
end

-- ============================================================================
-- MAIN OFFENSIVE LOGIC
-- ============================================================================

local function try_finishers(player, target, menu)
    local hp = hp_pct(target)

    -- 1. Drain Soul (Shard-snipe)
    if menu_enabled(menu, "use_drain_soul", true) and not player:is_moving() then
        -- LEVEL CHECK: No Drain Soul on gray mobs (Level diff > 9 usually)
        local p_lvl = player:get_level()
        local t_lvl = target:get_level()
        if not (t_lvl > 0 and (p_lvl - t_lvl) > 8) then
            local execute_pct = menu_number(menu, "drain_soul_execute_hp_pct", 20)
            local shard_limit = menu_number(menu, "min_soul_shards", 3)
            local shards = soul_shard:count()
            local ttd = ttd_sec(target)

            if shards < shard_limit then
                local in_hp_window = hp <= execute_pct
                local dying_soon = (ttd < 5) or (hp < 15)
                if in_hp_window and dying_soon then
                    -- Note: Drain Soul breaks wand
                    if try_cast(player, target, spells.drain_soul, menu, true) then return true end
                end
            end
        end
    end

    -- 2. Shadowburn (avoid stealing shard when shard-farming is active/needed)
    if spells.shadowburn:is_learned() and hp < 20 then
        if try_cast(player, target, spells.shadowburn, menu, true) then return true end
    end

    return false
end

local function try_dots(player, target, menu)
    -- DoT Priority: Curse > Corruption > Siphon > Immolate
    -- Break Wand: YES (High value) - only if TTD allows

    local ttd = ttd_sec(target)
    local min_ttd = menu_number(menu, "dot_min_ttd_sec", 8)

    if ttd < min_ttd then return false end -- Don't DoT standard dying mobs

    -- 1. Curse of Doom (boss fights > 65s, takes priority if enabled)
    if menu_enabled(menu, "use_curse_of_doom", false) and spells.curse_of_doom:is_learned() and ttd > 65 then
        if own_debuff_down(player,target,spells.curse_of_doom) then
            if try_cast(player, target, spells.curse_of_doom, menu, true) then return true end
        end
        -- Doom is up, skip other curses (only one curse at a time)
        goto skip_curse
    end

    -- 2. Preferred Curse
    do
        local curse_choice = menu_number(menu, "preferred_curse", 1) -- 1=Agony default
        local curse_spell = spells.curse_of_agony

        if curse_choice == 2 then
            curse_spell = spells.curse_of_elements
        elseif curse_choice == 3 then
            curse_spell = spells.curse_of_shadow
        elseif curse_choice == 4 then
            curse_spell = spells.curse_of_recklessness
        elseif curse_choice == 5 then
            curse_spell = spells.curse_of_tongues
        elseif curse_choice == 6 then
            curse_spell = spells.curse_of_weakness
        end

        local curse_pandemic = (curse_choice == 1) and PANDEMIC.agony or PANDEMIC.curse_other
        if needs_refresh(target, curse_spell:id(), curse_pandemic) then
            if try_cast(player, target, curse_spell, menu, true) then return true end
        end
    end
    ::skip_curse::

    -- 2. Corruption
    if menu_enabled(menu, "use_corruption", true) then
        if needs_refresh(target, spells.corruption:id(), PANDEMIC.corruption) then
            if try_cast(player, target, spells.corruption, menu, true) then return true end
        end
    end

    -- 3. Siphon Life
    if menu_enabled(menu, "use_siphon_life", true) then
        if needs_refresh(target, spells.siphon_life:id(), PANDEMIC.siphon) then
            if try_cast(player, target, spells.siphon_life, menu, true) then return true end
        end
    end

    -- 4. Immolate (Optional, skip if moving)
    if menu_enabled(menu, "use_immolate", false) and not player:is_moving() then
        if needs_refresh(target, spells.immolate:id(), PANDEMIC.immolate) then
            if try_cast(player, target, spells.immolate, menu, true) then return true end
        end
    end

    return false
end

local function try_fillers(player, target, menu, rotation_mode)
    local is_moving = player:is_moving()
    local mana_ok = mana_pct(player) > menu_number(menu, "shadow_bolt_min_mana_pct", 35)
    local sb_enabled = menu_enabled(menu, "use_shadow_bolt", true)

    -- 1. Nightfall Proc (Instant Shadow Bolt) - high value, break wand, castable while moving
    if sb_enabled and player:buff_up(SHADOW_TRANCE_BUFF) then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then return true end
    end

    -- 2. Drain Tank Mode (Solo/Leveling, level 38+): Drain Life replaces wand and SB as primary filler
    if rotation_mode == 1 and menu_enabled(menu, "use_drain_tank", false) then
        local p_level = player:get_level()
        if p_level >= 38 and not is_moving then
            -- Dark Pact first (free mana from pet)
            if spells.dark_pact and spells.dark_pact:is_learned() and mana_pct(player) < 60 then
                local pet = player:get_pet()
                if pet and pet:is_valid() and pet:is_alive() and mana_pct(pet) > 30 then
                    if try_cast(player, player, spells.dark_pact, menu, true) then return true end
                end
            end

            -- Drain Life as primary filler (heals + damages = zero downtime)
            if spells.drain_life:is_learned() then
                if try_cast(player, target, spells.drain_life, menu, true) then return true end
            end

            -- Life Tap when mana low (Drain Life will heal back the HP)
            if menu_enabled(menu, "use_life_tap", true) and mana_pct(player) < 50 and hp_pct(player) > 40 then
                if try_cast(player, player, spells.life_tap, menu, true) then return true end
            end

            return false -- Don't fall through to wand/SB in drain tank mode
        end
        -- Level < 38: fall through to normal filler logic (wand-based)
    end

    -- 3. Drain Life (Sustain - non-drain-tank mode)
    if not is_moving and menu_enabled(menu, "use_drain_life", true) then
        local drain_hp = menu_number(menu, "drain_life_hp_pct", 45)
        if hp_pct(player) <= drain_hp then
            if try_cast(player, target, spells.drain_life, menu, true) then return true end
        end
    end

    -- 4. Shadow Bolt (Hard Cast) - STRICT CHECK
    if not is_moving and sb_enabled and mana_ok then
        -- WE DO NOT BREAK WAND for generic filler Shadow Bolts.
        if try_cast(player, target, spells.shadow_bolt, menu, false) then return true end
    end

    -- 5. Life Tap (Resource Gen - can tap while moving!)
    if menu_enabled(menu, "use_life_tap", true) then
        local tap_mana = menu_number(menu, "life_tap_mana_pct", 40)
        local min_hp = menu_number(menu, "life_tap_min_hp_pct", 60)

        if (mana_pct(player) < tap_mana or (is_moving and mana_pct(player) < 80)) and hp_pct(player) > min_hp then
            if try_cast(player, player, spells.life_tap, menu, true) then return true end
        end
    end

    return false
end

local function try_wand_start(player, target, menu)
    if forever_affliction.await_spell_start(player) then return true end
    if legacy_dot_wait then
        if is_wanding(player) then stop_wand(player,target) end
        return true -- Outstanding setup, not an empty damage priority.
    end
    if player:is_moving() or not target then return false end
    if not menu_enabled(menu, "use_wand", true) then return false end

    if is_wanding(player) then return true end -- Already doing it

    -- Only start if we are not casting something else
    if player:is_channeling_or_casting() then return false end -- Should have been caught earlier, but safe check

    local now = core.game_time()
    if (now - last_wand_start_ms) > 1500 then -- Throttle re-engages
        if auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) then
            last_wand_start_ms = now
            forever_affliction.trace_filler(player,target,"Wand")
            return true
        end
    end
    return false
end

-- ============================================================================
-- OUT OF COMBAT
-- ============================================================================

local last_summon_finish_ms = 0

local function try_auto_summon_pet_era(player, menu)
    if not menu_enabled(menu, "auto_summon_pet", true) or player:is_moving() then return false end

    local now = core.game_time()
    if (now - last_summon_finish_ms) < 5000 then return false end

    local pet = player:get_pet()
    if pet and pet:is_valid() and pet:is_alive() then return false end

    local preferred = menu_number(menu, "preferred_pet", 1)
    -- ERA: 1=VW, 2=Imp, 3=Felhunter, 4=Succubus
    local candidates
    if preferred == 1 then
        candidates = { spells.summon_voidwalker, spells.summon_imp, spells.summon_felhunter, spells.summon_succubus }
    elseif preferred == 2 then
        candidates = { spells.summon_imp, spells.summon_voidwalker, spells.summon_felhunter, spells.summon_succubus }
    elseif preferred == 3 then
        candidates = { spells.summon_felhunter, spells.summon_voidwalker, spells.summon_imp, spells.summon_succubus }
    elseif preferred==5 and spells.summon_incubus then
        candidates = { spells.summon_incubus, spells.summon_succubus, spells.summon_imp, spells.summon_voidwalker }
    else
        candidates = { spells.summon_succubus, spells.summon_voidwalker, spells.summon_imp, spells.summon_felhunter }
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

local armor_aura_ids={ [706]=true,[1086]=true,[11733]=true,[11734]=true,[11735]=true }
local skin_aura_ids={ [687]=true,[696]=true }
local armor_owner,armor_next_at=nil,0
local armor_purge_owner=nil
local function try_armor_buff(player,menu)
    if not menu_enabled(menu,"use_armor",true) then return false end
    local armor_up,skin_up=false,false
    for _,aura in pairs(player:get_buffs() or {}) do
        if armor_aura_ids[aura.buff_id] then armor_up=true end
        if skin_aura_ids[aura.buff_id] then skin_up=true end
    end
    if armor_up then
        local guid=__object_safety.guid(player)
        if guid and armor_purge_owner~=guid then
            local queue=require("common/modules/spell_queue")
            queue:purge_by_spell(687,player);queue:purge_by_spell(696,player)
            armor_purge_owner=guid
        end
        return false
    end
    armor_purge_owner=nil
    local spell
    if spells.demon_armor:is_learned() then spell=spells.demon_armor
    elseif not skin_up and spells.demon_skin:is_learned() then spell=spells.demon_skin end
    if not spell then return false end
    local guid=__object_safety.guid(player);local now=core.game_time()
    if armor_owner~=guid or now<armor_next_at-3000 then armor_owner=guid;armor_next_at=0 end
    if now<armor_next_at or not spell:is_castable() then return false end
    local accepted,meta=spell:cast(player)
    if not (meta and meta.reason=="fast_queue_busy") then armor_next_at=now+3000 end
    return accepted==true
end

local function try_out_of_combat_era(player, menu)
    if player:is_moving() or player:is_channeling_or_casting() or (player:get_active_spell_id() or 0)>0
        or (player:get_active_channel_spell_id() or 0)>0 then return false end
    if inventory_maintenance.update(player,menu) then
        forever_affliction.status.action="Inventory upkeep"
        forever_affliction.status.reason=inventory_maintenance.status
        return true
    end

    -- Any active Demon Armor rank blocks Demon Skin, regardless of spellbook detection.
    if try_armor_buff(player,menu) then return true end

    -- 2. Soul Link (maintain if talented and pet alive)
    if spells.soul_link:is_learned() and not soul_link_is_up(player) then
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
    if try_auto_summon_pet_era(player, menu) then return true end


    return false
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

local function legacy_setup_due(player,target,menu,mode)
    local choice=menu_number(menu,"preferred_curse",1)
    local names={"curse_of_agony","curse_of_elements","curse_of_shadow","curse_of_recklessness","curse_of_tongues","curse_of_weakness"}
    local curse=names[choice] or "curse_of_agony"
    local entries={}
    if choice~=1 or menu_enabled(menu,"use_curse_of_agony",true) then
        entries[#entries+1]={key=curse=="curse_of_agony" and "bane_of_agony" or curse,spell=spells[curse],minimum=mode==3 and 10 or 8}
    end
    if mode~=3 and menu_enabled(menu,"use_curse_of_doom",false) and spells.curse_of_doom:is_learned()
        and forever_affliction.ttd(target) and forever_affliction.ttd(target)>65 then
        entries={{key="curse_of_doom",spell=spells.curse_of_doom,minimum=65}}
    end
    for _,entry in ipairs({{"corruption","use_corruption",true},{"siphon_life","use_siphon_life",true},{"immolate","use_immolate",false}}) do
        if (mode~=3 or entry[1]=="corruption") and menu_enabled(menu,entry[2],entry[3]) then
            entries[#entries+1]={key=entry[1],spell=spells[entry[1]],minimum=mode==3 and 12 or menu_number(menu,"dot_min_ttd_sec",8)}
        end
    end
    for _,entry in ipairs(entries) do
        if forever_affliction.dot_requirement(player,target,menu,entry.key,entry.spell,0,entry.minimum) then return true end
    end
    local spread=menu_enabled(menu,"multi_dot_enabled",false)
        or (menu.aoe_dot_toggle and plugin_helper:is_toggle_enabled(menu.aoe_dot_toggle))
    if mode~=3 and spread then
        local pack=forever_affliction.engaged_targets(player,player:get_pet(),target)
        local limit=math.max(1,math.min(5,menu_number(menu,"multi_dot_limit",3)))
        for i=2,math.min(limit,#pack) do
            for _,entry in ipairs({{"corruption","use_corruption"},{"bane_of_agony","use_curse_of_agony"}}) do
                local spell=entry[1]=="bane_of_agony" and spells.curse_of_agony or spells.corruption
                if menu_enabled(menu,entry[2],true) and forever_affliction.dot_requirement(player,pack[i],menu,entry[1],spell,0,menu_number(menu,"dot_min_ttd_sec",8)) then return true end
            end
        end
    end
    return false
end

function rotation_logic:execute(player, menu)
    legacy_dot_wait=false
    forever_affliction.status.dot_checks={}
    if not player or not menu then return false end
    if inventory_maintenance.cancel_for_combat(player) then return true end
    if forever_affliction.hold_drain_soul(player) then return true end
    if forever_affliction.handle_pet_heal(player,menu) then return true end

    forever_affliction.observe_cast(player)

    -- Out of combat handling
    if not player:is_in_combat() then
        return try_out_of_combat_era(player, menu)
    end

    local target = izi.target()
    local aff_mode=menu_number(menu,"rotation_mode",1)
    local aff_active=tostring(forever_client.get_game_version_string()):lower():find("forever",1,true)
        and menu_enabled(menu,"affliction_enabled",true) and (aff_mode==1 or aff_mode==2)
        and not plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) and not menu_enabled(menu,"pvp_mode",false)
    if aff_active then
        forever_affliction.status.route="Forever Affliction"
        return forever_affliction.execute(player,player:get_target(),menu,{emergency=try_emergency_survival,
            pet_utility=function(p,t,m) return try_pet_management(p,t,m,true) end,is_wanding=is_wanding,wand=try_wand_start})
    end

    forever_affliction.status.route=(plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) or menu_enabled(menu,"pvp_mode",false)) and "PvP" or ({"Legacy leveling","Legacy dungeon","DS/Ruin","SM/Ruin"})[aff_mode]

    -- Validate Target
    if not target or not target:is_valid_enemy() or not target:is_alive() then
        return false
    end

    -- 0. PvP Bypass
    if plugin_helper:is_toggle_enabled(menu.pvp_mode_toggle) or menu_enabled(menu, "pvp_mode", false) then
        pvp_log_menu_ref = menu
        pvp_log("exec.pvp", 500, string.format("[Warlock][PvP] ERA PvP active target=%s hp=%d%% mana=%d%% t_hp=%d%%",
            safe_name(target), hp_pct(player), mana_pct(player), hp_pct(target)))
        -- Emergency first even in PvP
        if try_emergency_survival(player, target, menu) then
            pvp_log("pvp.emergency", 0, string.format("[Warlock][PvP][Emergency] Survival action at hp=%d%%", hp_pct(player)))
            return true
        end
        if player:is_channeling_or_casting() and not is_wanding(player) then return true end
        if try_pet_management(player, target, menu) then return true end
        if try_pvp_logic(player, target, menu) then return true end
        if try_wand_start(player, target, menu) then return true end
        pvp_log("exec.pvp.idle", 1000, "[Warlock][PvP] ERA -> nothing to do this frame")
        return false
    end

    -- 1. Emergency (Survival) - ALWAYS CHECK
    if try_emergency_survival(player, target, menu) then return true end

    -- 2. Casting Status Check
    if player:is_channeling_or_casting() and not is_wanding(player) then
        return true -- Let cast finish
    end

    legacy_dot_wait=legacy_setup_due(player,target,menu,menu_number(menu,"rotation_mode",1))
    if legacy_dot_wait then forever_affliction.clear_queued_wand() end

    -- 3. Nightfall Proc (highest priority in all PvE modes)
    if player:buff_up(SHADOW_TRANCE_BUFF) then
        if try_cast(player, target, spells.shadow_bolt, menu, true) then return true end
    end

    -- 4. Pet
    if try_pet_management(player, target, menu) then return true end

    -- 5. Mode dispatch
    local mode = menu_number(menu, "rotation_mode", 1)
    -- 1=Solo/Leveling, 2=Dungeon/Raid, 3=DS/Ruin, 4=SM/Ruin
    if mode == 3 then
        if execute_ds_ruin(player, target, menu) then return true end
        if try_wand_start(player, target, menu) then return true end
        return false
    elseif mode == 4 then
        if execute_sm_ruin(player, target, menu) then return true end
        if try_wand_start(player, target, menu) then return true end
        return false
    end

    -- Default: Solo/Leveling (1) and Dungeon/Raid (2) - original flow

    -- 6. Finishers (Drain Soul / Burn)
    if try_finishers(player, target, menu) then return true end

    -- 7. DoTs (Strict Sequence)
    if try_dots(player, target, menu) then return true end

    -- 8. Multi-DoT spreading (PvE)
    if try_multi_dot_spread(player, target, menu) then return true end

    -- 9. Fillers (Shadow Bolt / Drain Life / Drain Tank)
    if try_fillers(player, target, menu, mode) then return true end

    -- 10. Wand (The Final Fallback)
    if try_wand_start(player, target, menu) then return true end

    return false
end

return rotation_logic
