-- ============================================================================
-- Druid Helpers Module - TBC (2.4.3)
-- Central utility module for form detection, spell wrappers, state tracking
-- ============================================================================

local helpers = {}

---@type enums
local enums = require("common/enums")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type rotation_pause
local rotation_pause = require("shared/rotation_pause")

local spells = require("rotations/druid/tbc/spells")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

-- ============================================================================
-- STATE
-- ============================================================================

local _menu = nil
local _last_form_change_time = 0
local _last_cast_times = {}

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function helpers:init(menu_elements)
    _menu = menu_elements
end

function helpers:get_player()
    local ok, player = pcall(function() return core.get_local_player() end)
    return ok and player or nil
end

function helpers:get_menu()
    return _menu
end

-- ============================================================================
-- SAFE WRAPPERS (pcall for all external calls)
-- ============================================================================

function helpers:safe_call(fn, fallback)
    local ok, res = pcall(fn)
    return ok and res or fallback
end

function helpers:get_energy(player)
    if not player then return 0 end
    -- power_type.ENERGY is 3
    local ok, val = pcall(function() return player:get_power(3) end)
    return (ok and val) and val or 0
end

function helpers:get_rage(player)
    if not player then return 0 end
    -- power_type.RAGE is 1
    local ok, val = pcall(function() return player:get_power(1) end)
    return (ok and val) and val or 0
end

function helpers:get_mana(player)
    if not player then return 0 end
    -- power_type.MANA is 0
    local ok, val = pcall(function() return player:get_power(0) end)
    return (ok and val) and val or 0
end

function helpers:get_mana_pct(player)
    if not player then return 0 end
    local health = self:get_mana(player)
    local max_health = self:safe_call(function() return player:get_max_power(0) end, 100)
    if max_health <= 0 then return 0 end
    return (health / max_health) * 100
end

function helpers:get_combo_points(player)
    if not player then return 0 end
    
    -- Try modern CP (4)
    local cp = 0
    local ok, val = pcall(function() return player:get_power(4) end)
    if ok and val and val > 0 then cp = val end
    
    -- Try TBC CP (51)
    if cp == 0 then
        local ok2, val2 = pcall(function() return player:get_power(51) end)
        if ok2 and val2 and val2 > 0 then cp = val2 end
    end
    
    -- Try native combo_points_current
    if cp == 0 then
        local ok3, val3 = pcall(function() return player:combo_points_current() end)
        if ok3 and val3 and val3 > 0 then cp = val3 end
    end
    
    if cp > 0 and self:is_debug_logging() then
        self:log_debug("Detected CP: " .. cp)
    end
    
    return cp
end

function helpers:get_level(player)
    if not player then return 1 end
    local ok, val = pcall(function() return player:get_level() end)
    return (ok and val) and val or 1
end

function helpers:get_hp_pct(unit)
    if not unit then return 100 end
    
    local ok, health = pcall(function() return unit:get_health() end)
    local ok2, max_health = pcall(function() return unit:get_max_health() end)
    
    if ok and ok2 and health and max_health and max_health > 0 then
        return (health / max_health) * 100
    end
    
    -- Fallback: try get_health_percentage if it exists on some SDK versions
    local ok3, pct = pcall(function() return unit:get_health_percentage() end)
    if ok3 and pct and pct > 0 then return pct end

    return 100
end

function helpers:is_valid_enemy(unit)
    if not unit then return false end
    
    local player = self:get_player()
    if not player then return false end
    
    -- Never target self as an enemy
    local ok_id, my_id = pcall(function() return player:get_id() end)
    local ok_uid, unit_id = pcall(function() return unit:get_id() end)
    if ok_id and ok_uid and my_id == unit_id then 
        self:log_debug("is_valid_enemy: Rejection (Self)")
        return false 
    end

    -- Basic validation
    local ok, alive = pcall(function() return not unit:is_dead() end)
    if not (ok and alive) then 
        self:log_debug("is_valid_enemy: Rejection (Dead)")
        return false 
    end
    
    local ok2, attackable = pcall(function() return unit:is_attackable() end)
    if not (ok2 and attackable) then 
        self:log_debug("is_valid_enemy: Rejection (Not Attackable)")
        return false 
    end
    
    -- Additional check: is_enemy_with(player)
    local ok3, is_enemy = pcall(function() return player:is_enemy_with(unit) end)
    if ok3 and not is_enemy then 
        self:log_debug("is_valid_enemy: Rejection (Not Enemy With Player)")
        return false 
    end

    return true
end

function helpers:safe_ttd(target)
    if not target then return 999 end
    -- Some units return 0 if they haven't been tracked long enough; default to high number
    local ok, val = pcall(function() return target:get_time_to_death() end)
    if ok and val and val > 0 then return val end
    return 999
end

function helpers:is_casting(player)
    if not player then return false end
    local ok, val = pcall(function() return player:is_casting_spell() or player:is_channelling_spell() end)
    return ok and val == true
end

function helpers:is_moving(player)
    if not player then return false end
    local ok, val = pcall(function() return player:is_moving() end)
    return ok and val == true
end

function helpers:is_in_combat(player)
    if not player then return false end
    -- FIX: Use native is_in_combat() instead of affecting_combat()
    local ok, val = pcall(function() return player:is_in_combat() end)
    return ok and val == true
end

function helpers:is_behind(player, target)
    if not player or not target then return false end
    -- Some versions of the API provide a native is_behind(target)
    local ok, val = pcall(function() return player:is_behind(target) end)
    if ok then return val end
    
    -- Fallback: Manual calculation if native fails
    local p_pos = player:get_position()
    local t_pos = target:get_position()
    local t_rot = target:get_rotation()
    if not p_pos or not t_pos or not t_rot then return false end
    
    local dx = p_pos.x - t_pos.x
    local dy = p_pos.y - t_pos.y
    local angle_to_player = math.atan2(dy, dx)
    local angle_diff = math.abs(angle_to_player - t_rot)
    if angle_diff > math.pi then angle_diff = 2 * math.pi - angle_diff end
    return angle_diff > (math.pi / 2)
end

function helpers:has_buff(unit, buff_ids)
    if not unit then return false end
    -- Use get_buff_data which returns a table with .is_active
    local ok, data = pcall(function() return unit:get_buff_data(buff_ids) end)
    return ok and data and data.is_active == true
end

function helpers:has_debuff(unit, debuff_ids)
    if not unit then return false end
    local ok, data = pcall(function() return unit:get_debuff_data(debuff_ids) end)
    return ok and data and data.is_active == true
end

function helpers:get_buff_remaining_ms(unit, buff_ids)
    if not unit then return 0 end
    local ok, data = pcall(function() return unit:get_buff_data(buff_ids) end)
    if ok and data and data.is_active then return data.remaining end
    return 0
end

function helpers:get_debuff_remaining_ms(unit, debuff_ids)
    if not unit then return 0 end
    local ok, data = pcall(function() return unit:get_debuff_data(debuff_ids) end)
    if ok and data and data.is_active then return data.remaining end
    return 0
end

function helpers:get_buff_stacks(unit, buff_ids)
    if not unit then return 0 end
    local ok, data = pcall(function() return unit:get_buff_data(buff_ids) end)
    if ok and data and data.is_active then return data.count end
    return 0
end

function helpers:get_debuff_stacks(unit, debuff_ids)
    if not unit then return 0 end
    local ok, data = pcall(function() return unit:get_debuff_data(debuff_ids) end)
    if ok and data and data.is_active then return data.count end
    return 0
end

-- ============================================================================
-- FORM DETECTION
-- ============================================================================

function helpers:get_current_form(player)
    if self:has_buff(player, spells.CAT_FORM_BUFF_IDS) then return "cat" end
    if self:has_buff(player, spells.ANY_BEAR_FORM_BUFF_IDS) then return "bear" end
    if self:has_buff(player, spells.TRAVEL_FORM_BUFF_IDS) then return "travel" end
    if self:has_buff(player, spells.MOONKIN_FORM_BUFF_IDS) then return "moonkin" end
    if self:has_buff(player, spells.TREE_FORM_BUFF_IDS) then return "tree" end
    return "caster"
end

function helpers:is_in_form(player, form_name)
    return self:get_current_form(player) == form_name
end

function helpers:is_in_any_form(player)
    return self:get_current_form(player) ~= "caster"
end

function helpers:try_enter_form(player, form_name)
    local spell_obj = nil
    if form_name == "cat" then 
        spell_obj = spells.cat_form
    elseif form_name == "bear" then 
        if self:is_spell_learned(spells.dire_bear_form) then
            spell_obj = spells.dire_bear_form
        else
            spell_obj = spells.bear_form
        end
    elseif form_name == "travel" then 
        spell_obj = spells.travel_form
    end

    if not spell_obj then return false end
    
    local ok, learned = pcall(function() return spell_obj:is_learned() end)
    if not ok or not learned then return false end

    if self:try_cast(spell_obj, player, "Enter " .. form_name) then
        _last_form_change_time = core.game_time()
        return true
    end
    return false
end

function helpers:try_leave_form(player)
    -- Safety: Never leave form while eating or drinking
    if player and rotation_pause.is_eating_or_drinking(player) then
        return false
    end

    -- Powershifting logic: cancel current form buff
    local form = self:get_current_form(player)
    if form == "caster" then return false end

    local buff_ids = nil
    if form == "cat" then buff_ids = spells.CAT_FORM_BUFF_IDS
    elseif form == "bear" then buff_ids = spells.BEAR_FORM_BUFF_IDS
    end

    if buff_ids then
        pcall(function() player:cancel_buff(buff_ids[1]) end)
        _last_form_change_time = core.game_time()
        return true
    end
    return false
end

function helpers:get_last_form_change_time()
    return _last_form_change_time
end

function helpers:set_last_form_change_time(t)
    _last_form_change_time = t
end

function helpers:is_form_gcd_active()
    -- Form changes trigger a short GCD (typically 1s)
    local now = core.game_time()
    return (now - _last_form_change_time) < 1000
end

-- ============================================================================
-- SPELL CASTING
-- ============================================================================

function helpers:try_cast(spell_obj, target, msg)
    if not spell_obj then return false end

    -- Safety: Never cast while eating or drinking
    local player = self:get_player()
    if player and rotation_pause.is_eating_or_drinking(player) then
        return false
    end

    local ok, result = pcall(function()
        return spell_obj:cast_safe(target, msg)
    end)

    if ok and result then
        local spell_id = self:safe_call(function() return spell_obj:id() end, 0)
        if spell_id and spell_id > 0 then
            _last_cast_times[spell_id] = core.game_time()
        end
        if msg and self:is_debug_logging() then
            self:log_checkpoint("cast", 1.0, "[Druid] " .. (msg or "cast"))
        end
        return true
    end

    return false
end

function helpers:is_spell_learned(spell_obj)
    if not spell_obj then return false end
    local ok, val = pcall(function() return spell_obj:is_learned() end)
    return ok and val == true
end

function helpers:is_spell_ready(spell_obj)
    if not spell_obj then return false end
    local ok, val = pcall(function() return spell_obj:cooldown_up() end)
    return ok and val == true
end

function helpers:get_spell_cooldown_ms(spell_obj)
    if not spell_obj then return 99999 end
    local ok, val = pcall(function() return spell_obj:cooldown_remains() end)
    if ok and val then return val * 1000 end
    return 0
end

function helpers:get_last_cast_time(spell_obj)
    if not spell_obj then return 0 end
    local spell_id = self:safe_call(function() return spell_obj:id() end, 0)
    return _last_cast_times[spell_id] or 0
end

function helpers:ensure_auto_attack(player, target)
    if not player or not target then return end
    pcall(function()
        if not player:is_auto_attacking() then
            player:attack(target)
        end
    end)
end

function helpers:stop_auto_attack(player, target)
    if not player or not target then return end
    pcall(function()
        if player:is_auto_attacking() then
            player:attack(target) -- Toggles off
        end
    end)
end

-- ============================================================================
-- TARGETING
-- ============================================================================

function helpers:get_target(player)
    if not player then return nil end
    local ok, target = pcall(function()
        return player:get_target()
    end)
    return (ok and target) and target or nil
end

function helpers:is_valid_enemy(target)
    if not target then return false end
    local ok, val = pcall(function()
        return target:is_valid() and target:is_unit() and not target:is_dead() and target:is_visible()
    end)
    return ok and val == true
end

function helpers:get_enemy_count(player, range)
    if not player then return 0 end
    range = range or 8
    local ok, val = pcall(function()
        -- Note: check if this method exists in your API
        return player:get_enemies_in_splash_range_count(range)
    end)
    if ok and val then return val end
    return 0
end

function helpers:is_target_casting(target)
    if not target then return false end
    local ok, val = pcall(function()
        return target:is_casting_spell() or target:is_channelling_spell()
    end)
    return ok and val == true
end

function helpers:get_target_cast_remaining_ms(target)
    if not target then return 0 end
    -- Add implementation if needed
    return 0
end

-- ============================================================================
-- MENU HELPERS
-- ============================================================================

function helpers:get_menu_state(element, fallback)
    if not element then return fallback end
    local ok, val = pcall(function() return element:get_state() end)
    if ok then return val end
    return fallback
end

function helpers:get_menu_value(element, fallback)
    if not element then return fallback end
    local ok, val = pcall(function() return element:get() end)
    if ok and type(val) == "number" then return val end
    return fallback
end

function helpers:is_pvp_mode()
    if not _menu then return false end
    if not _menu.pvp_mode_toggle then return false end
    return plugin_helper:is_toggle_enabled(_menu.pvp_mode_toggle)
end

function helpers:is_cooldowns_active()
    if not _menu then return false end
    if not _menu.use_cooldowns then return false end
    return plugin_helper:is_toggle_enabled(_menu.use_cooldowns)
end

function helpers:is_debug_logging()
    if not _menu then return false end
    return self:get_menu_state(_menu.debug_logging, false)
end

function helpers:log_checkpoint(key, probability, message)
    if not message then return end
    core.log(message)
end

function helpers:log_debug(message)
    if self:is_debug_logging() then
        core.log("[DEBUG] " .. (message or ""))
    end
end

-- ============================================================================
-- UNIT STATUS
-- ============================================================================

function helpers:is_stunned(unit)
    if not unit then return false end
    local ok, val = pcall(function() return unit:is_stunned() end)
    return ok and val == true
end

function helpers:is_rooted(unit)
    if not unit then return false end
    local ok, val = pcall(function() return unit:is_rooted() end)
    return ok and val == true
end

function helpers:is_in_range(player, target, range)
    if not player or not target then return false end
    local ok, val = pcall(function() return target:is_in_range(range) end)
    return ok and val == true
end

function helpers:is_in_melee_range(player, target)
    if not player or not target then return false end
    -- Melee range is typically 5yd + combat reach
    local ok, val = pcall(function() return target:is_in_melee_range(5) end)
    return ok and val == true
end

function helpers:get_distance(player, target)
    if not player or not target then return 0 end
    local ok, val = pcall(function() return target:distance() end)
    if ok and val then return val end
    return 0
end

return helpers
