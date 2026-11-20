local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Shadow Priest Rotation Module (TBC Classic 2.4.3)
-- Pure Shadow DPS with Self-Healing Only
-- ============================================================================

local shadow_rotation = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

-- Import spells (shared with healer rotation)
local spells = require("rotations/priest/tbc/spells")

-- ============================================================================
-- STATE TRACKING & CACHING
-- ============================================================================

local last_vt_cast = 0
local last_inner_focus_use = 0
local INNER_FOCUS_THROTTLE_MS = 1000

-- Wand state
local last_wand_toggle_ms = 0
local WAND_TOGGLE_THROTTLE_MS = 500
local wand_auto_active = false
local last_wand_stop_ms = 0
local WAND_STOP_THROTTLE_MS = 100
local RANGED_WEAPON_SLOT_ID = 18

-- Facing helper
local last_face_fix_ms = 0
local FACE_FIX_THROTTLE_MS = 150

-- Tick tracker for mana optimization
local active_tick_tracker = nil

-- Throttling for maintenance
local last_maintenance_tick = 0
local MAINTENANCE_THROTTLE_MS = 3000
local last_racial_maint_tick = 0

-- Forward declare
local safe_is_alive

-- ============================================================================
-- POTION HELPER
-- ============================================================================

local function try_use_potion(potion_ids, reason)
    if not potion_ids then return false end
    for _, item_id in ipairs(potion_ids) do
        local ok, item = pcall(function() return izi.item(item_id) end)
        if ok and item then
            local has_it = false
            pcall(function() has_it = item:in_inventory() end)
            if has_it then
                local cd_ok = true
                pcall(function()
                    local cd = item:get_cooldown()
                    if cd and cd > 0 then cd_ok = false end
                end)
                if cd_ok then
                    local used = false
                    pcall(function() used = item:use_self_safe(reason) end)
                    if used then return true end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- DEBUG LOGGING (throttled, checkbox-gated)
-- ============================================================================

local _log_last_times = {}
local _active_menu_ref = nil

local function dbg(key, interval, message)
    if not _active_menu_ref then return end
    if not _active_menu_ref.rotation_log_enabled then return end
    if not _active_menu_ref.rotation_log_enabled:get_state() then return end
    local now = core.time()
    local last = _log_last_times[key] or 0
    if (now - last) < interval then return end
    _log_last_times[key] = now
    core.log("[SPriest] " .. message)
end

local function dbg_now(message)
    if not _active_menu_ref then return end
    if not _active_menu_ref.rotation_log_enabled then return end
    if not _active_menu_ref.rotation_log_enabled:get_state() then return end
    core.log("[SPriest] " .. message)
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function get_current_target(player)
    local target = nil
    pcall(function() target = izi.target() end)
    if target and target.is_valid and target:is_valid() then
        return target
    end
    if player and player.get_target then
        local ok, player_target = pcall(function() return player:get_target() end)
        if ok and player_target and player_target.is_valid and player_target:is_valid() then
            return player_target
        end
    end
    return nil
end

local function ensure_facing_target(player, target)
    if not player or not target or not core or not core.input or not core.input.look_at then
        return false
    end
    if not player.is_looking_at or not target.get_position then
        return false
    end
    local ok_enemy, is_enemy = pcall(function() return target:is_valid_enemy() end)
    if not ok_enemy or is_enemy ~= true then return false end
    local ok_looking, looking = pcall(function() return player:is_looking_at(target) end)
    if ok_looking and looking == true then return false end

    local now_ms = core.game_time()
    if (now_ms - last_face_fix_ms) >= FACE_FIX_THROTTLE_MS then
        local pos = nil
        pcall(function() pos = target:get_position() end)
        if pos then
            last_face_fix_ms = now_ms
            pcall(function() core.input.look_at(pos) end)
        end
    end
    return true
end

safe_is_alive = function(unit)
    if not unit then return false end
    if unit.is_valid then
        local ok_valid, valid = pcall(function() return unit:is_valid() end)
        if not ok_valid or not valid then return false end
    end
    local ok_alive, alive = pcall(function() return unit:is_alive() end)
    return ok_alive and alive == true
end

local function has_buff(unit, buff_ids)
    if not unit or not unit:is_alive() then return false end
    for _, id in ipairs(buff_ids) do
        if unit:buff_up(id) then return true end
    end
    return false
end

local function buff_missing(unit, buff_ids)
    if not unit or not unit:is_alive() then return false end
    for _, id in ipairs(buff_ids) do
        if unit:buff_up(id) then return false end
    end
    return true
end

local function has_weakened_soul(unit)
    if not unit or not unit:is_alive() then return true end
    return unit:debuff_up(spells.WEAKENED_SOUL_ID)
end

local function has_enough_mana(player, min_mana_pct)
    return player:mana_pct() >= min_mana_pct
end

---Check if unit needs magic dispel specifically
---@param unit game_object
---@return boolean
local function needs_magic_dispel(unit)
    if not safe_is_alive(unit) or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, debuff in ipairs(debuffs) do
        if debuff and debuff.type == enums.buff_type.MAGIC then
            return true
        end
    end
    return false
end

local function get_group_members(player)
    local ok_range, party_range = pcall(function()
        return player:get_party_members_in_range(40, true)
    end)
    if ok_range and party_range and #party_range > 0 then
        return party_range
    end

    local ok_party, party = pcall(function()
        return player:get_party_members()
    end)
    if ok_party and party and #party > 0 then
        return party
    end

    return { player }
end

---Check if unit is movement slowed
---@param unit game_object
---@return boolean
local function is_movement_slowed(unit)
    if not unit then return false end
    
    -- Try SDK method first
    local ok, slowed = pcall(function() return unit.is_movement_slowed and unit:is_movement_slowed() end)
    if ok and slowed ~= nil then return slowed end

    -- Fallback: Check for common slow debuffs or Mind Flay
    if unit.debuff_up then
        if unit:debuff_up(spells.mind_flay:id()) then return true end
        -- Common TBC slows: Hamstring (7373), Crippling Poison (3408), Frostbolt (116)
        local common_slows = { 7373, 3408, 116, 120, 20164, 20165, 25809, 31589 }
        for _, id in ipairs(common_slows) do
            if unit:debuff_up(id) then return true end
        end
    end
    
    return false
end

---Check if enemy has a dispellable magic buff
---@param unit game_object
---@return boolean
local function has_dispellable_magic_buff(unit)
    if not unit or not unit.get_buffs then return false end
    local ok, buffs = pcall(function() return unit:get_buffs() end)
    if not ok or type(buffs) ~= "table" then return false end
    for _, buff in ipairs(buffs) do
        if buff and buff.type == enums.buff_type.MAGIC then
            return true
        end
    end
    return false
end

-- ============================================================================
-- WAND LOGIC (from healer rotation)
-- ============================================================================

local function is_wanding_active(player)
    if not auto_attack_helper then return false end
    local ok, attacking = pcall(function()
        return auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    if ok and attacking == true then return true end
    local ok2, pid = pcall(function() return player:get_active_channel_spell_id() end)
    return ok2 and pid == 5019
end

local function stop_wand_if_active(player, target)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then return end
    local is_attacking = false
    pcall(function() is_attacking = auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND) end)
    if not is_attacking then return end
    auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
end

local function sync_wand_auto_active(player)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then
        wand_auto_active = false
        return
    end
    local ok, is_attacking = pcall(function()
        return auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    wand_auto_active = ok and is_attacking == true
end

-- ============================================================================
-- CAST HELPER
-- ============================================================================

local function cast_spell(spell, target, player)
    if not spell or not target then return false end
    if not spell:is_learned() or not spell:cooldown_up() then return false end

    if player and ensure_facing_target(player, target) then
        return true
    end

    stop_wand_if_active(player, target)

    local ok, result = pcall(function() return spell:cast_safe(target) end)
    if ok and result == true then
        local s_name, t_name, s_id = "?", "?", 0
        pcall(function() s_name = spell:get_name() or "?" end)
        pcall(function() t_name = target:get_name() or "?" end)
        pcall(function() s_id = spell:id() or 0 end)
        dbg_now(string.format("CAST OK: %s (id=%d) -> %s", s_name, s_id, t_name))
        return true
    end
    return false
end

-- ============================================================================
-- WAND FILLER
-- ============================================================================

local function try_use_wand(player, target, menu, target_hp_pct, mana_pct)
    if menu.sp_use_wand and not menu.sp_use_wand:get_state() then return false end
    if not auto_attack_helper then return false end
    if player:is_moving() then return false end
    if player:is_channeling_or_casting() then return false end

    local mana_threshold = (menu.sp_wand_mana_threshold and menu.sp_wand_mana_threshold:get()) or 15
    local hp_threshold = (menu.sp_wand_target_hp and menu.sp_wand_target_hp:get()) or 10
    if mana_pct > mana_threshold and target_hp_pct > hp_threshold then
        return false
    end

    if is_wanding_active(player) then return true end

    local ok, result = pcall(function()
        return auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    if ok and result == true then
        dbg_now("Wand: Started auto-shoot on " .. (target:get_name() or "target"))
        return true
    end
    return false
end

-- ============================================================================
-- ENEMY COUNTING
-- ============================================================================

local function count_enemies_in_range(radius)
    local me = izi.me()
    if not me then return 0 end
    local enemies = izi.enemies(radius)
    if not enemies then return 0 end
    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy:is_valid() and enemy:is_alive() then
            count = count + 1
        end
    end
    return count
end

-- ============================================================================
-- SHADOWFORM MANAGEMENT
-- ============================================================================

local function is_in_shadowform(player)
    return has_buff(player, spells.SHADOWFORM_BUFF_IDS)
end

local function ensure_shadowform(player, menu)
    if not menu.sp_maintain_shadowform:get_state() then return false end
    if not spells.shadow_form:is_learned() then return false end
    if is_in_shadowform(player) then return false end
    if player:is_mounted() or player:is_casting_spell() or player:is_channelling_spell() then
        return false
    end
    if spells.shadow_form:cast_safe(player) then
        dbg_now("Entering Shadowform")
        return true
    end
    return false
end

local function cancel_shadowform(player)
    if not is_in_shadowform(player) then return true end
    -- Cancel shadowform by casting it again (toggle)
    if spells.shadow_form:is_learned() then
        local ok = pcall(function() spells.shadow_form:cast_safe(player) end)
        if ok then
            dbg_now("Leaving Shadowform for self-heal")
            return true
        end
    end
    return false
end

-- ============================================================================
-- OUT-OF-COMBAT LOGIC (BUFFS)
-- ============================================================================

local last_buff_check = 0
local BUFF_CHECK_INTERVAL_MS = 1000

local function handle_out_of_combat(player, menu)
    local now = core.game_time()
    if player:is_casting_spell() or player:is_channelling_spell() then
        return false
    end

    -- Maintain Shadowform
    if ensure_shadowform(player, menu) then return true end

    -- Check buffs periodically
    if now - last_buff_check < BUFF_CHECK_INTERVAL_MS then return false end
    last_buff_check = now

    if not has_enough_mana(player, 20) then return false end

    -- Inner Fire
    if buff_missing(player, spells.INNER_FIRE_BUFF_IDS) then
        if spells.inner_fire:is_learned() then
            if cast_spell(spells.inner_fire, player, player) then return true end
        end
    end

    -- Self-only Fortitude
    if buff_missing(player, spells.FORTITUDE_BUFF_IDS) then
        if spells.power_word_fortitude:is_learned() then
            if cast_spell(spells.power_word_fortitude, player, player) then return true end
        end
    end

    -- Self-only Divine Spirit
    if buff_missing(player, spells.DIVINE_SPIRIT_BUFF_IDS) then
        if spells.divine_spirit:is_learned() then
            if cast_spell(spells.divine_spirit, player, player) then return true end
        end
    end

    -- Self Shadow Protection (if configured)
    if menu.sp_use_shadow_protection and menu.sp_use_shadow_protection:get_state() then
        if buff_missing(player, spells.SHADOW_PROTECTION_BUFF_IDS) then
            if spells.shadow_protection:is_learned() then
                if cast_spell(spells.shadow_protection, player, player) then return true end
            end
        end
    end

    return false
end

-- ============================================================================
-- SELF-HEALING LOGIC (Shadow Priest)
-- ============================================================================

local function handle_self_healing(player, menu)
    if not menu.sp_self_heal_enabled:get_state() then return false end

    local hp_pct = player:get_health_percentage() or 100
    local is_moving = player:is_moving()
    local in_shadowform = is_in_shadowform(player)
    local allow_leave_sf = menu.sp_cancel_shadowform_heal:get_state()

    -- Skip healing if above threshold
    local heal_threshold = menu.sp_self_heal_hp:get()
    if hp_pct > heal_threshold then return false end

    dbg("selfheal.check", 1.0, string.format("Self-heal check: HP=%d%% threshold=%d%% shadowform=%s",
        math.floor(hp_pct), heal_threshold, tostring(in_shadowform)))

    -- ========================================================================
    -- P1: Desperate Prayer (Instant, works in Shadowform)
    -- ========================================================================
    if menu.sp_use_desperate_prayer:get_state() then
        local dp_hp = menu.sp_desperate_prayer_hp:get()
        if hp_pct <= dp_hp then
            if spells.desperate_prayer:is_learned() and spells.desperate_prayer:cooldown_up() then
                dbg_now(string.format("SELF-HEAL Desperate Prayer: HP=%d%%", math.floor(hp_pct)))
                if cast_spell(spells.desperate_prayer, player, player) then return true end
            end
        end
    end

    -- ========================================================================
    -- P2: Power Word: Shield (Instant, works in Shadowform)
    -- ========================================================================
    if menu.sp_use_self_shield:get_state() then
        local shield_hp = menu.sp_self_shield_hp:get()
        if hp_pct <= shield_hp then
            if not has_weakened_soul(player) and not has_buff(player, spells.PWS_BUFF_IDS) then
                if spells.power_word_shield:is_learned() then
                    dbg_now(string.format("SELF-HEAL PW:Shield: HP=%d%%", math.floor(hp_pct)))
                    if cast_spell(spells.power_word_shield, player, player) then return true end
                end
            end
        end
    end

    -- ========================================================================
    -- P3: Health Potion (Instant, works in Shadowform)
    -- ========================================================================
    if menu.sp_use_hp_potions:get_state() and player:is_in_combat() then
        local pot_hp = menu.sp_hp_potion_at:get()
        if hp_pct <= pot_hp then
            dbg_now(string.format("SELF-HEAL Health Potion: HP=%d%%", math.floor(hp_pct)))
            if izi.use_best_health_potion_safe() then return true end
            if try_use_potion(spells.HEALTH_POTION_IDS, "Health Potion") then return true end
        end
    end

    -- ========================================================================
    -- Below this point: Spells require leaving Shadowform
    -- ========================================================================
    if in_shadowform and not allow_leave_sf then
        dbg("selfheal.sf_block", 2.0, "Self-heal blocked: in Shadowform and cancel not allowed")
        return false
    end

    -- ========================================================================
    -- P4: Renew (Instant cast, can apply then re-enter Shadowform)
    -- ========================================================================
    if menu.sp_use_self_renew:get_state() then
        local renew_hp = menu.sp_self_renew_hp:get()
        if hp_pct <= renew_hp and buff_missing(player, spells.RENEW_BUFF_IDS) then
            -- Leave Shadowform if needed
            if in_shadowform then
                cancel_shadowform(player)
                return true -- Next tick will cast Renew
            end
            if spells.renew:is_learned() then
                dbg_now(string.format("SELF-HEAL Renew: HP=%d%%", math.floor(hp_pct)))
                if cast_spell(spells.renew, player, player) then return true end
            end
        end
    end

    -- ========================================================================
    -- P5: Flash Heal (Cast time, emergency self-heal)
    -- ========================================================================
    if menu.sp_use_flash_heal and menu.sp_use_flash_heal:get_state() then
        local fh_hp = menu.sp_self_flash_heal_hp:get()
        if hp_pct <= fh_hp and not is_moving then
            -- Leave Shadowform if needed
            if in_shadowform then
                cancel_shadowform(player)
                return true
            end
            if spells.flash_heal:is_learned() then
                dbg_now(string.format("SELF-HEAL Flash Heal: HP=%d%%", math.floor(hp_pct)))
                if cast_spell(spells.flash_heal, player, player) then return true end
            end
        end
    end

    return false
end

-- ============================================================================
-- SHADOW DPS ROTATION (Main Combat Logic)
-- ============================================================================

local function handle_shadow_dps(player, menu, target_override)
    -- Skip if already casting
    if player:is_casting_spell() then
        dbg("dps.cast", 2.0, "DPS: currently casting, waiting")
        return true
    end

    local targets = {}
    if target_override and target_override:is_valid() and target_override:is_alive() then
        targets = { target_override }
    else
        targets = izi.get_ts_targets()
    end

    if (not targets or #targets == 0) then
        local t = get_current_target(player)
        if t and t:is_valid_enemy() and t:is_alive() then
            targets = { t }
        end
    end

    if not targets or #targets == 0 then
        return false
    end

    local now = core.game_time()
    local hp_pct = player:get_health_percentage() or 100
    local mana_pct = player:mana_pct() or 0
    local is_moving = player:is_moving()
    local has_shadowform = is_in_shadowform(player)

    -- 1. SHADOWFORM MAINTENANCE
    if menu.sp_maintain_shadowform and menu.sp_maintain_shadowform:get_state() and not has_shadowform and not is_moving then
        if not player:is_channelling_spell() then
            if cast_spell(spells.shadow_form, player, player) then return true end
        end
    end

    -- 2. CHANNEL DETECT
    local channel_id = player:get_active_channel_spell_id()
    local wanding_now = is_wanding_active(player)
    if wanding_now then
        local wand_enabled = menu.sp_use_wand and menu.sp_use_wand:get_state()
        local mana_threshold = (menu.sp_wand_mana_threshold and menu.sp_wand_mana_threshold:get()) or 15
        local mx_tgt = targets[1]
        local tgt_hp = mx_tgt and mx_tgt:get_health_percentage() or 100
        local hp_threshold = (menu.sp_wand_target_hp and menu.sp_wand_target_hp:get()) or 10
        local should_wand = wand_enabled and (mana_pct <= mana_threshold or tgt_hp <= hp_threshold)
        if should_wand then return true else stop_wand_if_active(player, mx_tgt) end
    elseif channel_id and channel_id > 0 then
        -- Don't break if mind flay, we handle clip logic at the bottom
        if channel_id ~= spells.mind_flay:id() then return true end
    end

    -- 3. WAND FILLER EARLY OUT (OOM / Low HP)
    local mx_tgt = targets[1]
    if mx_tgt then
        local tgt_hp = mx_tgt:get_health_percentage() or 100
        if try_use_wand(player, mx_tgt, menu, tgt_hp, mana_pct) then return true end
    end

    -- 4. COOLDOWNS & MANA
    if menu.sp_use_shadowfiend and menu.sp_use_shadowfiend:get_state() then
        local sf_threshold = (menu.sp_shadowfiend_mana and menu.sp_shadowfiend_mana:get()) or 30
        if mana_pct <= sf_threshold and player:is_in_combat() then
            if spells.shadowfiend:is_learned() and spells.shadowfiend:cooldown_up() then
                if cast_spell(spells.shadowfiend, targets[1], player) then return true end
            end
        end
    end

    if menu.sp_use_inner_focus and menu.sp_use_inner_focus:get_state() then
        local if_threshold = (menu.sp_inner_focus_mana and menu.sp_inner_focus_mana:get()) or 30
        if mana_pct <= if_threshold and not is_moving then
            if spells.inner_focus:is_learned() and spells.inner_focus:cooldown_up() then
                if (now - last_inner_focus_use) > INNER_FOCUS_THROTTLE_MS then
                    if cast_spell(spells.inner_focus, player, player) then last_inner_focus_use = now end
                end
            end
        end
    end

    if menu.sp_use_mana_potions and menu.sp_use_mana_potions:get_state() and player:is_in_combat() then
        local pot_threshold = menu.sp_mana_potion_at and menu.sp_mana_potion_at:get() or 25
        if mana_pct <= pot_threshold then
            if izi.use_best_mana_potion_safe() then return true end
            if try_use_potion(spells.MANA_POTION_IDS, "Mana Potion") then return true end
        end
    end

    -- ==============================================
    -- PHASE 1: PvP CC & Utility (All valid targets)
    -- ==============================================
    for i = 1, #targets do
        local target = targets[i]
        if not target or not target:is_valid() then goto skip_pvp end
        local is_player = false
        pcall(function() is_player = target:is_player() end)

        -- Silence (Enhanced Focus Priority)
        if menu.sp_use_silence and menu.sp_use_silence:get_state() then
            local silence_targets = {}
            local focus = nil
            pcall(function() focus = izi.focus() end)
            if focus and focus:is_valid_enemy() and focus:is_alive() then
                table.insert(silence_targets, focus)
            end
            table.insert(silence_targets, targets[1])

            for _, s_target in ipairs(silence_targets) do
                if s_target and (s_target:is_casting_spell() or s_target:is_channelling_spell()) then
                    local elapsed_cast = 0
                    pcall(function() elapsed_cast = s_target:get_cast_elapsed_ms() or 0 end)
                    local delay = menu.sp_silence_delay_ms and menu.sp_silence_delay_ms:get() or 0
                    if elapsed_cast >= delay then
                        if spells.silence and spells.silence:is_learned() and spells.silence:cooldown_up() then
                            dbg_now("PvP Silence: " .. (s_target:get_name() or "enemy"))
                            if cast_spell(spells.silence, s_target, player) then return true end
                        end
                    end
                end
            end
        end

        -- SW:D CC Breaker (Enhanced)
        if menu.sp_use_swd_breaker and menu.sp_use_swd_breaker:get_state() then
            local enemy_casters = { targets[1] }
            local focus = nil
            pcall(function() focus = izi.focus() end)
            if focus and focus:is_valid_enemy() and focus:is_alive() then
                table.insert(enemy_casters, focus)
            end

            for _, enemy in __object_safety.live_ipairs(enemy_casters) do
                if enemy and enemy:is_casting_spell() then
                    local tg_targ = nil
                    pcall(function() tg_targ = enemy:get_target() end)
                    if tg_targ and tg_targ.get_guid and (__object_safety.same(tg_targ,player)) then
                        local spell_id = 0
                        pcall(function() spell_id = enemy:get_active_spell_id() or 0 end)
                        
                        -- Polymorph, Fear, Seduction, Howl of Terror, Repentance, Wyvern Sting, Freezing Trap, Scatter Shot
                        local cc_ids = { 118, 12824, 12825, 12826, 28271, 28272, 5782, 6213, 6215, 5484, 17928, 6358, 20066, 14311, 19503, 49039 }
                        local is_cc = false
                        for _, id in ipairs(cc_ids) do if spell_id == id then is_cc = true break end end

                        if is_cc then
                            local cast_pct = 0
                            pcall(function() cast_pct = enemy:get_cast_pct() or 0 end)
                            if cast_pct > 85 then
                                if spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up() then
                                    dbg_now("PvP SWD CC-break: enemy=" .. (enemy:get_name() or "?") .. " spell=" .. spell_id)
                                    if cast_spell(spells.shadow_word_death, enemy, player) then return true end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Offensive Purge (Enhanced Priority)
        if menu.sp_use_offensive_dispel and menu.sp_use_offensive_dispel:get_state() then
            local purge_target = target
            local focus = nil
            pcall(function() focus = izi.focus() end)
            if focus and focus:is_valid_enemy() then purge_target = focus end

            if purge_target and purge_target:is_valid_enemy() then
                -- Lust, Hero, Innervate, PI, Ice Barrier, BoP, Fear Ward, Earth Shield, Divine Favor, Nature's Swiftness
                local high_priority_ids = { 2825, 32182, 29166, 10060, 10278, 1022, 6346, 974, 32594, 20216, 16188, 17116 }
                local should_purge = false
                
                for _, id in ipairs(high_priority_ids) do
                    if purge_target:buff_up(id) then
                        should_purge = true
                        break
                    end
                end

                if not should_purge and has_dispellable_magic_buff(purge_target) then
                    should_purge = true
                end
                
                if should_purge then
                    if spells.dispel_magic:is_learned() and spells.dispel_magic:cooldown_up() then
                        dbg_now("PvP Offensive Dispel: " .. (purge_target:get_name() or "?"))
                        if cast_spell(spells.dispel_magic, purge_target, player) then return true end
                    end
                end
            end
        end

        -- Mana Burn (Strategic focus)
        if menu.sp_use_mana_burn and menu.sp_use_mana_burn:get_state() and not is_moving then
            local burn_target = target
            local focus = nil
            pcall(function() focus = izi.focus() end)
            if focus and focus:is_valid_enemy() and focus:get_max_power(0) > 0 then
                burn_target = focus
            end

            local t_mana = burn_target:mana_pct() or 0
            local limit = menu.sp_mana_burn_target_mana and menu.sp_mana_burn_target_mana:get() or 20
            if t_mana > limit then
                if spells.mana_burn:is_learned() and spells.mana_burn:cooldown_up() then
                    dbg_now("PvP Mana Burn: " .. (burn_target:get_name() or "?"))
                    if cast_spell(spells.mana_burn, burn_target, player) then return true end
                end
            end
        end

        ::skip_pvp::
    end

    -- ==============================================
    -- PHASE 2: Execute
    -- ==============================================
    for i = 1, #targets do
        local target = targets[i]
        if not target or not target:is_valid() then goto skip_exec end
        local t_hp = target:get_health_percentage() or 100
        if menu.sp_use_shadow_word_death and menu.sp_use_shadow_word_death:get_state() then
            local swd_limit = menu.sp_swd_target_hp and menu.sp_swd_target_hp:get() or 25
            local swd_min_hp = menu.sp_swd_min_player_hp and menu.sp_swd_min_player_hp:get() or 35
            if t_hp <= swd_limit and hp_pct >= swd_min_hp then
                if spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up() then
                    if cast_spell(spells.shadow_word_death, target, player) then return true end
                end
            end
        end
        ::skip_exec::
    end

    -- ==============================================
    -- PHASE 3: Multi-DoT
    -- ==============================================
    local do_multi = menu.sp_enable_multidot and menu.sp_enable_multidot:get_state()
    local multi_limit = menu.sp_multidot_limit and menu.sp_multidot_limit:get() or 1
    if not do_multi then multi_limit = 1 end
    local applied = 0

    for i = 1, #targets do
        if applied >= multi_limit then break end
        local target = targets[i]
        if not target or not target:is_valid() then goto skip_dot end
        
        local ok_immune, is_immune = pcall(function() return target:is_damage_immune(target.DMG.MAGICAL) end)
        if ok_immune and is_immune then goto skip_dot end
        
        local t_hp = target:get_health_percentage() or 100
        local thresh = menu.sp_dot_refresh_threshold and menu.sp_dot_refresh_threshold:get() or 20

        if t_hp > thresh then
            -- VT
            if has_shadowform and menu.sp_use_vampiric_touch and menu.sp_use_vampiric_touch:get_state() and not is_moving then
                if not target:debuff_up(spells.VT_DEBUFF_IDS) then
                    if (now - last_vt_cast) > 1200 then
                        if cast_spell(spells.vampiric_touch, target, player) then
                            last_vt_cast = now return true
                        end
                    end
                end
            end
            -- SWP
            if menu.sp_use_shadow_word_pain and menu.sp_use_shadow_word_pain:get_state() then
                if not target:debuff_up(spells.SWP_DEBUFF_IDS) then
                    local spell_to_cast = spells.shadow_word_pain
                    if menu.sp_blackout_mode and menu.sp_blackout_mode:get_state() then
                        spell_to_cast = spells.swp_r1
                    end
                    if cast_spell(spell_to_cast, target, player) then return true end
                end
            end
            -- DP
            if menu.sp_use_devouring_plague and menu.sp_use_devouring_plague:get_state() then
                if spells.devouring_plague and spells.devouring_plague:is_learned() and spells.devouring_plague:cooldown_up() then
                    if not target:debuff_up(spells.DP_DEBUFF_IDS) then
                        if cast_spell(spells.devouring_plague, target, player) then return true end
                    end
                end
            end
            
            applied = applied + 1
        end
        ::skip_dot::
    end

    -- ==============================================
    -- PHASE 4: Single Target Fillers (Main Target)
    -- ==============================================
    local main_t = targets[1]
    if main_t and main_t:is_valid() then
        if menu.sp_use_mind_blast and menu.sp_use_mind_blast:get_state() and not is_moving then
            if spells.mind_blast:is_learned() and spells.mind_blast:cooldown_up() then
                if cast_spell(spells.mind_blast, main_t, player) then return true end
            end
        end

        if menu.sp_use_vampiric_embrace and menu.sp_use_vampiric_embrace:get_state() then
            if not main_t:debuff_up(spells.VE_DEBUFF_IDS) then
                if cast_spell(spells.vampiric_embrace, main_t, player) then return true end
            end
        end

        if has_shadowform and menu.sp_use_mind_flay and menu.sp_use_mind_flay:get_state() and not is_moving then
            if player:is_channelling_spell() then
                local ch_id = 0
                pcall(function() ch_id = player:get_active_cast_or_channel_id() end)
                if ch_id == spells.mind_flay:id() then
                    local elapsed = 0
                    pcall(function() elapsed = player:get_channel_elapsed_ms() or 0 end)
                    if elapsed >= 2000 then
                        local mb_ready = spells.mind_blast:is_learned() and spells.mind_blast:cooldown_up()
                        local swd_ready = spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up()
                        if mb_ready or swd_ready then
                            pcall(function() core.input.stop_casting() end)
                            return true
                        end
                    end
                    return true
                end
            end

            -- Mind Flay Kiting priority: if target is close (melee range), ensure slow is active
            local dist = 0
            pcall(function() dist = player:get_distance_to(main_t) or 0 end)
            local needs_slow = dist < 15 and not is_movement_slowed(main_t)

            if not player:is_channelling_spell() then
                stop_wand_if_active(player, main_t)
                if spells.mind_flay:is_learned() and spells.mind_flay:cooldown_up() then
                    if needs_slow or (not spells.mind_blast:cooldown_up() and not spells.shadow_word_death:cooldown_up()) then
                        if spells.mind_flay:cast_safe(main_t) then return true end
                    end
                end
            end
        end

        if not is_moving and cast_spell(spells.starshards, main_t, player) then return true end
    end

    return false
end

-- ============================================================================
-- EMERGENCY UTILITY
-- ============================================================================

local function handle_emergency_utility(player, menu)
    -- Fade (threat reduction)
    if menu.sp_use_fade:get_state() and player:is_in_combat() then
        local target = izi.target()
        if target and target:is_valid_enemy() then
            local ok, threat = pcall(function() return player:get_threat_situation(target) end)
            if ok and threat then
                local is_tanking = threat.is_tanking or false
                local threat_pct = threat.threat_percent or 0
                if is_tanking or threat_pct > 90 then
                    if spells.fade:is_learned() and spells.fade:cooldown_up() then
                        dbg_now(string.format("Fade: tanking=%s threat=%.0f%%", tostring(is_tanking), threat_pct))
                        if cast_spell(spells.fade, player, player) then return true end
                    end
                end
            end
        end
    end

    -- Psychic Scream (emergency fear + peeling)
    if menu.sp_use_psychic_scream:get_state() then
        if spells.psychic_scream:is_learned() and spells.psychic_scream:cooldown_up() then
            local hp_pct = player:get_health_percentage()
            local hp_threshold = menu.sp_scream_hp_threshold:get()
            local mob_threshold = menu.sp_scream_mob_count:get()
            local enemies_in_8yd = count_enemies_in_range(8)

            -- Panic: low HP + enemies close
            if hp_pct <= hp_threshold and enemies_in_8yd >= 1 then
                dbg_now(string.format("PANIC Psychic Scream: hp=%d%% enemies=%d", math.floor(hp_pct), enemies_in_8yd))
                if cast_spell(spells.psychic_scream, player, player) then return true end
            end

            -- AoE CC: many enemies
            if mob_threshold >= 3 and enemies_in_8yd >= mob_threshold then
                dbg_now(string.format("AOE Psychic Scream: %d enemies >= %d", enemies_in_8yd, mob_threshold))
                if cast_spell(spells.psychic_scream, player, player) then return true end
            end

            -- Peel Fear: Help teammates
            local group = get_group_members(player)
            for _, ally in __object_safety.live_ipairs(group) do
                if ally and ally.get_guid and (not __object_safety.same(ally,player)) and ally:is_alive() then
                    local ally_hp = ally:get_health_percentage() or 100
                    if ally_hp < 40 then
                        -- Is there an enemy near this ally?
                        local dist_to_ally = 0
                        pcall(function() dist_to_ally = player:get_distance_to(ally) or 99 end)
                        if dist_to_ally < 8 then
                            local enemies = izi.enemies(30)
                            for _, enemy in __object_safety.live_ipairs(enemies) do
                                if enemy and enemy:is_valid_enemy() and enemy:is_alive() then
                                    local e_target = nil
                                    pcall(function() e_target = enemy:get_target() end)
                                    if e_target and e_target.get_guid and e_target:get_guid() == ally:get_guid() then
                                        dbg_now("PvP Peel Fear for " .. (ally:get_name() or "ally"))
                                        if cast_spell(spells.psychic_scream, player, player) then return true end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Shackle Undead (for Warlock pets/summons)
    if menu.use_shackle_undead and menu.use_shackle_undead:get_state() then
        if spells.shackle_undead:is_learned() and spells.shackle_undead:cooldown_up() and not is_moving then
            local enemies = izi.enemies(30)
            for _, e in ipairs(enemies) do
                if e and e:is_valid_enemy() and e:is_alive() and e:get_creature_type() == enums.creature_type.UNDEAD then
                    if not e:buff_up(spells.shackle_undead:id()) then
                        dbg_now("PvP Shackle Undead on " .. (e:get_name() or "pet"))
                        if cast_spell(spells.shackle_undead, e, player) then return true end
                    end
                end
            end
        end
    end

    -- Inner Fire Maintenance (Combat)
    local now_ms = core.game_time()
    if (now_ms - last_maintenance_tick) > MAINTENANCE_THROTTLE_MS then
        if buff_missing(player, spells.INNER_FIRE_BUFF_IDS) and spells.inner_fire:is_learned() then
            dbg_now("Combat Inner Fire refresh")
            last_maintenance_tick = now_ms
            if cast_spell(spells.inner_fire, player, player) then return true end
        end
    end

    -- Racial Maintenance (Shadow Guard / Touch of Weakness)
    if (now_ms - last_racial_maint_tick) > MAINTENANCE_THROTTLE_MS then
        if spells.shadow_guard and spells.shadow_guard:is_learned() and buff_missing(player, spells.SHADOW_GUARD_BUFF_IDS) then
            dbg_now("Racial Shadow Guard refresh")
            last_racial_maint_tick = now_ms
            if cast_spell(spells.shadow_guard, player, player) then return true end
        end

        if spells.touch_of_weakness and spells.touch_of_weakness:is_learned() and buff_missing(player, spells.TOUCH_OF_WEAKNESS_BUFF_IDS) then
            dbg_now("Racial Touch of Weakness refresh")
            last_racial_maint_tick = now_ms
            if cast_spell(spells.touch_of_weakness, player, player) then return true end
        end
    end

    -- Defensive Dispel (magic/disease on self & teammates)
    if menu.use_dispel and menu.use_dispel:get_state() then
        local group = get_group_members(player)
        for _, ally in __object_safety.live_ipairs(group) do
            if ally and ally:is_alive() then
                local has_magic = needs_magic_dispel(ally)
                if has_magic and spells.dispel_magic:is_learned() then
                    local in_sf = is_in_shadowform(player)
                    if in_sf and menu.sp_cancel_shadowform_heal:get_state() then
                        cancel_shadowform(player)
                        return true
                    elseif not in_sf then
                        dbg_now("Defensive Dispel: Magic on " .. (ally:get_name() or "ally"))
                        if cast_spell(spells.dispel_magic, ally, player) then return true end
                    end
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- MAIN EXECUTE FUNCTION
-- ============================================================================

function shadow_rotation:execute(local_player, menu, tick_tracker)
    if not local_player then return false end

    _active_menu_ref = menu
    active_tick_tracker = tick_tracker

    -- Don't run while ghost or dead
    local ok_ghost, is_ghost = pcall(function() return local_player:is_ghost() end)
    if ok_ghost and is_ghost == true then return false end
    local ok_dead, is_dead = pcall(function() return local_player:is_dead() end)
    if ok_dead and is_dead == true then return false end

    local player = local_player

    -- Sync wand state
    sync_wand_auto_active(player)

    -- Refresh spells
    if spells and spells.refresh then spells:refresh() end

    -- ========================================================================
    -- EMERGENCY UTILITY (Fear, Fade, Self-Dispel)
    -- ========================================================================
    if player:is_in_combat() then
        if handle_emergency_utility(player, menu) then return true end
    end

    -- ========================================================================
    -- SELF-HEALING (Highest priority when HP is low)
    -- ========================================================================
    if handle_self_healing(player, menu) then return true end

    -- ========================================================================
    -- RE-ENTER SHADOWFORM (after leaving for heals/dispels)
    -- ========================================================================
    if ensure_shadowform(player, menu) then return true end

    -- ========================================================================
    -- SELF-PRESERVATION: Potions
    -- ========================================================================
    if player:is_in_combat() then
        local hp_pct = player:get_health_percentage()
        local mana_pct = player:mana_pct()

        if menu.sp_use_hp_potions:get_state() then
            local hp_pot_threshold = menu.sp_hp_potion_at:get()
            if hp_pct <= hp_pot_threshold then
                if izi.use_best_health_potion_safe({ skip_casting = true }) then return true end
            end
        end

        if menu.sp_use_mana_potions:get_state() then
            local pot_threshold = menu.sp_mana_potion_at:get()
            if mana_pct <= pot_threshold then
                if izi.use_best_mana_potion_safe({ skip_casting = true }) then return true end
            end
        end
    end

    -- ========================================================================
    -- OUT OF COMBAT: Buffs & Attack on Target
    -- ========================================================================
    if not player:is_in_combat() then
        -- Attack on Target (engage enemy when selected OOC)
        if menu.sp_attack_on_target and menu.sp_attack_on_target:get_state() then
            local target = get_current_target(player)
            if target and target:is_valid_enemy() and target:is_alive() then
                if handle_shadow_dps(player, menu, target) then return true end
            end
        end
        if handle_out_of_combat(player, menu) then return true end
    end

    -- ========================================================================
    -- SHADOW DPS ROTATION (Main combat loop)
    -- ========================================================================
    if player:is_in_combat() then
        if handle_shadow_dps(player, menu) then return true end
    end

    return false
end

return shadow_rotation
