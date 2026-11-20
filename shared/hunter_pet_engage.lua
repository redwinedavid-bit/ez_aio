local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Hunter Pet Engage
-- Drives pet targeting via pet_attack. Target modes control priority.
-- Designed to be lightweight, throttled, and safe when no pet is present.
-- ============================================================================

local M = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local DEFAULT_SCAN_RANGE_YDS = 35
local DEFAULT_ENGAGE_THROTTLE_MS = 300
local DEFAULT_DEBUG_THROTTLE_MS = 1500
local PET_CC_MIN_REMAINING_MS = 150

local function log_line(msg)
    if core and core.log then
        core.log(msg)
        return
    end
    if izi and izi.print then
        izi.print(msg)
    end
end

local function clamp_int(v, min_v, max_v)
    v = tonumber(v) or min_v
    if v < min_v then
        return min_v
    end
    if v > max_v then
        return max_v
    end
    return v
end

---@param obj game_object|nil
---@return string|nil
local function safe_get_guid(obj)
    if not obj or not obj.get_guid then
        return nil
    end
    local ok, guid = pcall(function()
        return obj:get_guid()
    end)
    if not ok or guid == nil then
        return nil
    end
    return tostring(guid)
end

---@param a game_object|nil
---@param b game_object|nil
---@return boolean
local function same_unit(a, b)
    if not a or not b then
        return false
    end
    if (__object_safety.same(a,b)) then
        return true
    end
    local ga = safe_get_guid(a)
    local gb = safe_get_guid(b)
    return ga ~= nil and ga == gb
end

---@param enemy game_object|nil
---@return boolean
local function is_valid_enemy(enemy)
    if not enemy then
        return false
    end
    if enemy.is_dead and enemy:is_dead() then
        return false
    end
    if enemy.is_valid_enemy and not enemy:is_valid_enemy() then
        return false
    end
    return true
end

---@param enemy game_object|nil
---@return boolean
local function is_enemy_cc_protected(enemy)
    if not enemy then
        return false
    end

    -- Primary guard: weak CC (breaks on damage), e.g. Freezing Trap, Sap, many incap/disorients.
    if enemy.is_cc_weak then
        local ok, active = pcall(function()
            return enemy:is_cc_weak(PET_CC_MIN_REMAINING_MS)
        end)
        if ok and active then
            return true
        end
    end

    -- Fallback for runtimes where is_cc_weak is unavailable or incomplete.
    if enemy.is_cc and enemy.CC then
        local cc = enemy.CC

        local function has_cc(flag)
            if not flag then
                return false
            end
            local ok, active = pcall(function()
                return enemy:is_cc(PET_CC_MIN_REMAINING_MS, flag)
            end)
            return ok and active == true
        end

        if has_cc(cc.INCAPACITATE) then return true end
        if has_cc(cc.DISORIENT) then return true end
        if has_cc(cc.SAP) then return true end
        if has_cc(cc.CYCLONE) then return true end
        if has_cc(cc.MIND_CONTROL) then return true end
    end

    return false
end

---@param enemy game_object|nil
---@return boolean
local function is_valid_pet_enemy(enemy)
    if not is_valid_enemy(enemy) then
        return false
    end
    if is_enemy_cc_protected(enemy) then
        return false
    end
    return true
end

---@param menu any
---@param key string
---@param default boolean
---@return boolean
local function menu_bool(menu, key, default)
    if not menu then
        return default
    end
    local el = menu[key]
    if not el or not el.get_state then
        return default
    end
    local ok, v = pcall(function()
        return el:get_state()
    end)
    if not ok then
        return default
    end
    return v == true
end

---@param menu any
---@param key string
---@param default number
---@return number
local function menu_int(menu, key, default)
    if not menu then
        return default
    end
    local el = menu[key]
    if not el or not el.get then
        return default
    end
    local ok, v = pcall(function()
        return el:get()
    end)
    if not ok then
        return default
    end
    return tonumber(v) or default
end

function M.new()
    local self = {
        _log_last_ms = {},
        _last_pet_attack_ms = 0,
        _last_pet_attack_guid = nil,
        _locked_guid = nil,
        _locked_mode = 0,
        _locked_reason = nil, -- "healer" | "player" | "tank" | "my_target"
    }
    return setmetatable(self, { __index = M })
end

---@param enemies game_objects_table|nil
---@param guid string|nil
---@return game_object|nil
local function find_enemy_by_guid(enemies, guid)
    if not enemies or not guid then
        return nil
    end
    for i = 1, #enemies do
        local e = enemies[i]
        if is_valid_pet_enemy(e) and safe_get_guid(e) == guid then
            return e
        end
    end
    return nil
end

---@param enemies game_objects_table|nil
---@param player game_object|nil
---@param unit game_object|nil
---@return game_object|nil
local function find_closest_enemy_targeting(enemies, player, unit)
    if not enemies or not player or not unit then
        return nil
    end
    local best = nil
    local best_dist = 999999
    for i = 1, #enemies do
        local enemy = enemies[i]
        if not is_valid_pet_enemy(enemy) then
            goto continue_find
        end
        if enemy.is_in_combat and not enemy:is_in_combat() then
            goto continue_find
        end
        local enemy_target = enemy.get_target and enemy:get_target() or nil
        if not same_unit(enemy_target, unit) then
            goto continue_find
        end
        local dist = player.distance_to and player:distance_to(enemy) or nil
        dist = tonumber(dist) or 999999
        if dist < best_dist then
            best = enemy
            best_dist = dist
        end
        ::continue_find::
    end
    return best
end

---@param self hunter_pet_engage
---@param menu any
---@return boolean
function M.debug_enabled(self, menu)
    return menu_bool(menu, "pet_debug_logs", false)
end

---@param self hunter_pet_engage
---@param menu any
---@return boolean
function M.debug_verbose_enabled(self, menu)
    return menu_bool(menu, "pet_debug_verbose", false)
end

---@param self hunter_pet_engage
---@param menu any
---@param now_ms integer
---@param key string
---@param interval_ms integer|nil
---@param fmt string
---@param ... any
function M.debug_log_throttled(self, menu, now_ms, key, interval_ms, fmt, ...)
    if not self:debug_enabled(menu) then
        return
    end
    local last = self._log_last_ms[key] or 0
    local interval = tonumber(interval_ms) or DEFAULT_DEBUG_THROTTLE_MS
    if last > 0 and (now_ms - last) < interval then
        return
    end
    self._log_last_ms[key] = now_ms
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then
        msg = fmt
    end
    log_line("[HunterPet] " .. tostring(msg))
end

---@param self hunter_pet_engage
---@param menu any
---@param fmt string
---@param ... any
function M.debug_log(self, menu, fmt, ...)
    if not self:debug_enabled(menu) then
        return
    end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then
        msg = fmt
    end
    log_line("[HunterPet] " .. tostring(msg))
end

---@param self hunter_pet_engage
---@param menu any
---@param now_ms integer
---@param msg string
function M.debug_log_state(self, menu, now_ms, msg)
    if not self:debug_enabled(menu) then
        return
    end
    if self:debug_verbose_enabled(menu) then
        self:debug_log(menu, "%s", msg)
        return
    end
    -- Non-verbose: throttle state logs so they don't spam every tick.
    self:debug_log_throttled(menu, now_ms, "state", 1500, "%s", msg)
end

local function safe_name(obj)
    if not obj or not obj.get_name then
        return "nil"
    end
    local ok, name = pcall(function()
        return obj:get_name()
    end)
    if not ok then
        return "<?>"
    end
    return tostring(name)
end

local function safe_dist(unit, obj)
    if not unit or not obj or not unit.distance_to then
        return nil
    end
    local ok, d = pcall(function()
        return unit:distance_to(obj)
    end)
    if not ok then
        return nil
    end
    return tonumber(d)
end

local function pet_attack(target)
    if not core or not core.input or not core.input.pet_attack then
        return false
    end
    local ok, res = pcall(function()
        return core.input.pet_attack(target)
    end)
    return ok and res == true
end

local function set_pet_assist()
    if not core or not core.input or not core.input.set_pet_assist then
        return false
    end
    local ok, res = pcall(function()
        return core.input.set_pet_assist()
    end)
    return ok and (res == true or res == nil)
end

---@param player game_object
---@param scan_range number
---@return game_objects_table|nil
local function safe_get_enemies(player, scan_range)
    if not player or not player.get_enemies_in_range then
        return nil
    end
    local ok, enemies = pcall(function()
        return player:get_enemies_in_range(scan_range, false)
    end)
    if not ok then
        return nil
    end
    return enemies
end

---@param self hunter_pet_engage
---@param player game_object
---@param rotation_target game_object|nil
---@param menu table
---@param now_ms integer
---@return game_object|nil
function M.select_pet_target(self, player, rotation_target, menu, now_ms)
    -- Modes: 1=Disabled, 2=Attack My Target, 3=Take Aggro, 4=Smart
    local mode = menu_int(menu, "pet_target_mode", 1)

    if mode == 1 then
        return nil
    end

    if mode == 2 then
        local pt = player and player.get_target and player:get_target() or nil
        if is_valid_pet_enemy(pt) then
            return pt
        end
        return nil
    end

    if mode == 3 then
        local scan_range = clamp_int(menu_int(menu, "pet_target_scan_range", DEFAULT_SCAN_RANGE_YDS), 10, 60)
        local enemies = safe_get_enemies(player, scan_range)

        local best_enemy = nil
        local best_dist = 999999
        if enemies then
            for i = 1, #enemies do
                local enemy = enemies[i]
                if not is_valid_pet_enemy(enemy) then
                    goto continue_take_aggro
                end
                if enemy.is_in_combat and not enemy:is_in_combat() then
                    goto continue_take_aggro
                end
                local enemy_target = enemy.get_target and enemy:get_target() or nil
                if not same_unit(enemy_target, player) then
                    goto continue_take_aggro
                end
                local dist = player.distance_to and player:distance_to(enemy) or nil
                dist = tonumber(dist) or 999999
                if dist < best_dist then
                    best_enemy = enemy
                    best_dist = dist
                end
                ::continue_take_aggro::
            end
        end

        if is_valid_pet_enemy(best_enemy) then
            return best_enemy
        end

        -- fallback to my target
        local pt = player and player.get_target and player:get_target() or nil
        if is_valid_pet_enemy(pt) then
            return pt
        end
        return nil
    end

    if mode == 4 then
        local scan_range = clamp_int(menu_int(menu, "pet_target_scan_range", DEFAULT_SCAN_RANGE_YDS), 10, 60)
        local enemies = safe_get_enemies(player, scan_range)
        if not enemies then
            return nil
        end

        local party = izi.party(scan_range)
        local healer = nil
        local tank = nil
        if party then
            for i = 1, #party do
                local ally = party[i]
                if not healer and ally and ally.is_healer and ally:is_healer() then
                    healer = ally
                end
                if not tank and ally and ally.is_tank and ally:is_tank() then
                    tank = ally
                end
            end
        end

        local function find_enemy_targeting(unit)
            if not unit then
                return nil
            end
            local best = nil
            local best_dist = 999999
            for i = 1, #enemies do
                local enemy = enemies[i]
                if not is_valid_pet_enemy(enemy) then
                    goto continue_find
                end
                if enemy.is_in_combat and not enemy:is_in_combat() then
                    goto continue_find
                end
                local enemy_target = enemy.get_target and enemy:get_target() or nil
                if not same_unit(enemy_target, unit) then
                    goto continue_find
                end
                local dist = player.distance_to and player:distance_to(enemy) or nil
                dist = tonumber(dist) or 999999
                if dist < best_dist then
                    best = enemy
                    best_dist = dist
                end
                ::continue_find::
            end
            return best
        end

        local e = find_enemy_targeting(healer)
        if is_valid_pet_enemy(e) then
            return e
        end

        e = find_enemy_targeting(player)
        if is_valid_pet_enemy(e) then
            return e
        end

        e = find_enemy_targeting(tank)
        if is_valid_pet_enemy(e) then
            return e
        end

        local pt = player and player.get_target and player:get_target() or nil
        if is_valid_pet_enemy(pt) then
            return pt
        end
    end

    return nil
end

---@param self hunter_pet_engage
---@param player game_object
---@param rotation_target game_object|nil
---@param menu table
---@param spells table
---@param now_ms integer
---@return boolean
function M.try_pet_engage(self, player, rotation_target, menu, spells, now_ms)
    if not player or not menu then
        return false
    end

    -- Hard safety gate: never attempt pet commands if we don't have a pet.
    local pet = player.get_pet and player:get_pet() or nil
    if not pet or (pet.is_dead and pet:is_dead()) then
        self._last_pet_attack_guid = nil
        self._locked_guid = nil
        self._locked_mode = 0
        self._locked_reason = nil
        self:debug_log_throttled(menu, now_ms, "no_pet", 2500, "No pet (or pet dead) - skipping")
        return false
    end

    -- Feature gate.
    local enabled = menu_bool(menu, "auto_pet_attack", false)
    if not enabled then
        self._locked_guid = nil
        self._locked_mode = 0
        self._locked_reason = nil
        self:debug_log_throttled(menu, now_ms, "disabled", 2500, "Auto Pet Attack disabled - skipping")
        return false
    end

    -- Desired target selection with hard-lock behavior:
    -- - Mode 2 (Attack My Target): lock to my target guid until my target changes.
    -- - Mode 3 (Take Aggro): lock to the first enemy found targeting me until it no longer targets me;
    --   only then rescan; if none target me, fall back to my target.
    local mode = menu_int(menu, "pet_target_mode", 1)

    if mode == 1 then
        self._locked_mode = 0
        self._locked_guid = nil
        self._locked_reason = nil
        if self:debug_verbose_enabled(menu) then
            self:debug_log_throttled(menu, now_ms, "skip_disabled_mode", 1000, "skip: pet_target_mode=Disabled")
        end
        return false
    end

    local scan_range = clamp_int(menu_int(menu, "pet_target_scan_range", DEFAULT_SCAN_RANGE_YDS), 10, 60)
    local enemies = safe_get_enemies(player, scan_range)
    if self:debug_verbose_enabled(menu) then
        self:debug_log_throttled(menu, now_ms, "scan", 750, "scan: range=%d enemies=%d", tonumber(scan_range) or -1, enemies and #enemies or 0)
    end

    local player_target = player and player.get_target and player:get_target() or nil
    if not is_valid_pet_enemy(player_target) then
        player_target = nil
    end

    local desired = nil
    if mode == 2 then
        local pt_guid = safe_get_guid(player_target)
        if pt_guid then
            if self._locked_mode ~= 2 or self._locked_guid ~= pt_guid then
                self._locked_mode = 2
                self._locked_guid = pt_guid
                self._locked_reason = "my_target"
            end
            desired = player_target
        else
            self._locked_mode = 0
            self._locked_guid = nil
            self._locked_reason = nil
            desired = nil
        end
    elseif mode == 3 then
        -- Validate existing lock (still targeting me?)
        if self._locked_mode == 3 and self._locked_guid then
            local locked_enemy = find_enemy_by_guid(enemies, self._locked_guid)
            local locked_enemy_target = locked_enemy and locked_enemy.get_target and locked_enemy:get_target() or nil
            if is_valid_pet_enemy(locked_enemy) and same_unit(locked_enemy_target, player) then
                desired = locked_enemy
            else
                self._locked_guid = nil
                self._locked_reason = nil
                self:debug_log_state(menu, now_ms, "lock: clear (mode=3) reason=player (no longer targeting player / invalid)")
            end
        else
            if self._locked_mode ~= 3 then
                self._locked_mode = 3
                self._locked_guid = nil
                self._locked_reason = nil
            end
        end

        -- Acquire lock if none.
        if not desired and enemies then
            for i = 1, #enemies do
                local enemy = enemies[i]
                if not is_valid_pet_enemy(enemy) then
                    goto continue_acquire_take_aggro
                end
                if enemy.is_in_combat and not enemy:is_in_combat() then
                    goto continue_acquire_take_aggro
                end
                local enemy_target = enemy.get_target and enemy:get_target() or nil
                if not same_unit(enemy_target, player) then
                    goto continue_acquire_take_aggro
                end

                local eg = safe_get_guid(enemy)
                if eg then
                    self._locked_guid = eg
                    self._locked_reason = "player"
                    desired = enemy
                    self:debug_log_state(menu, now_ms, "lock: acquire (mode=3) reason=player")
                    break
                end

                ::continue_acquire_take_aggro::
            end
        end

        if not desired then
            desired = player_target
            if desired then
                self._locked_mode = 3
                self._locked_guid = safe_get_guid(desired)
                self._locked_reason = "my_target"
                self:debug_log_state(menu, now_ms, "lock: acquire (mode=3) reason=my_target")
            end
        end
    elseif mode == 4 then
        -- Resolve healer/tank once per tick.
        local party = izi.party(scan_range)
        local healer = nil
        local tank = nil
        if party then
            for i = 1, #party do
                local ally = party[i]
                if not healer and ally and ally.is_healer and ally:is_healer() then
                    healer = ally
                end
                if not tank and ally and ally.is_tank and ally:is_tank() then
                    tank = ally
                end
            end
        end

        local function validate_lock_for(reason, enemy)
            if not reason or not is_valid_pet_enemy(enemy) then
                return false
            end
            if reason == "healer" then
                if not healer then
                    return false
                end
                local t = enemy.get_target and enemy:get_target() or nil
                return same_unit(t, healer)
            end
            if reason == "player" then
                local t = enemy.get_target and enemy:get_target() or nil
                return same_unit(t, player)
            end
            if reason == "tank" then
                if not tank then
                    return false
                end
                local t = enemy.get_target and enemy:get_target() or nil
                return same_unit(t, tank)
            end
            if reason == "my_target" then
                return player_target ~= nil and same_unit(enemy, player_target)
            end
            return false
        end

        -- Validate existing lock first.
        if self._locked_mode == 4 and self._locked_guid then
            local locked_enemy = find_enemy_by_guid(enemies, self._locked_guid)
            if validate_lock_for(self._locked_reason, locked_enemy) then
                desired = locked_enemy
            else
                self._locked_guid = nil
                self._locked_reason = nil
                self:debug_log_state(menu, now_ms, "lock: clear (mode=4) reason invalidated")
            end
        else
            self._locked_mode = 4
            self._locked_guid = nil
            self._locked_reason = nil
        end

        -- Acquire lock in priority order: healer > player > tank > my target.
        if not desired then
            local e = find_closest_enemy_targeting(enemies, player, healer)
            if is_valid_pet_enemy(e) then
                local eg = safe_get_guid(e)
                if eg then
                    self._locked_guid = eg
                    self._locked_reason = "healer"
                    desired = e
                    self:debug_log_state(menu, now_ms, "lock: acquire (mode=4) reason=healer")
                end
            end
        end
        if not desired then
            local e = find_closest_enemy_targeting(enemies, player, player)
            if is_valid_pet_enemy(e) then
                local eg = safe_get_guid(e)
                if eg then
                    self._locked_guid = eg
                    self._locked_reason = "player"
                    desired = e
                    self:debug_log_state(menu, now_ms, "lock: acquire (mode=4) reason=player")
                end
            end
        end
        if not desired then
            local e = find_closest_enemy_targeting(enemies, player, tank)
            if is_valid_pet_enemy(e) then
                local eg = safe_get_guid(e)
                if eg then
                    self._locked_guid = eg
                    self._locked_reason = "tank"
                    desired = e
                    self:debug_log_state(menu, now_ms, "lock: acquire (mode=4) reason=tank")
                end
            end
        end
        if not desired and player_target then
            local eg = safe_get_guid(player_target)
            if eg then
                self._locked_guid = eg
                self._locked_reason = "my_target"
                desired = player_target
                self:debug_log_state(menu, now_ms, "lock: acquire (mode=4) reason=my_target")
            end
        end
    else
        -- Default behavior for other modes: keep existing selection logic.
        self._locked_mode = 0
        self._locked_guid = nil
        self._locked_reason = nil
        desired = self:select_pet_target(player, rotation_target, menu, now_ms)
    end

    if not is_valid_pet_enemy(desired) then
        self:debug_log_throttled(menu, now_ms, "no_target", 1500, "No valid desired enemy (mode=%d)", menu_int(menu, "pet_target_mode", 0))
        return false
    end

    local dist_pet = safe_dist(pet, desired) or -1

    self:debug_log_throttled(
        menu,
        now_ms,
        "pet_state",
        1200,
        "Pet target: desired=%s pet_dist=%.1f",
        safe_name(desired),
        dist_pet
    )

    -- Throttle pet_attack commands to avoid spam (still useful if pet_attack fails/gets ignored and we'd retry every tick).
    local throttle_ms = clamp_int(menu_int(menu, "pet_engage_throttle_ms", DEFAULT_ENGAGE_THROTTLE_MS), 0, 2500)
    local desired_guid = safe_get_guid(desired)
    if not desired_guid then
        return false
    end
    local guid_changed = desired_guid and desired_guid ~= self._last_pet_attack_guid

    -- Throttle to avoid input spam; stable gating prevents target flapping spam.
    local dt = now_ms - (self._last_pet_attack_ms or 0)
    if throttle_ms > 0 and dt < throttle_ms then
        if self:debug_verbose_enabled(menu) then
            self:debug_log_throttled(menu, now_ms, "skip_throttle", 500,
                "skip: throttle dt=%dms < %dms (mode=%d lock_mode=%d reason=%s desired=%s guid=%s)",
                tonumber(dt) or -1, tonumber(throttle_ms) or -1, tonumber(mode) or 0, tonumber(self._locked_mode) or 0,
                tostring(self._locked_reason), safe_name(desired), tostring(desired_guid))
        end
        return false
    end

    -- Hard-lock behavior: once we've successfully issued pet_attack for a guid, do not re-issue it every tick.
    -- If pet_attack failed, _last_pet_attack_guid won't update and guid_changed remains true, so we will retry (throttled).
    if not guid_changed then
        if self:debug_verbose_enabled(menu) then
            self:debug_log_throttled(menu, now_ms, "skip_same_guid", 1000,
                "skip: already issued pet_attack for guid=%s (mode=%d lock_mode=%d reason=%s desired=%s)",
                tostring(desired_guid), tonumber(mode) or 0, tonumber(self._locked_mode) or 0, tostring(self._locked_reason),
                safe_name(desired))
        end
        return false
    end

    -- Try pet_attack first, fall back to set_pet_assist.
    -- IMPORTANT: Always update _last_pet_attack_ms on every attempt (not just success).
    -- Without this, a persistent pet_attack FAIL causes dt to grow unbounded, the throttle
    -- never fires, and pet_attack is retried every frame (~300/s) which causes disconnects.
    if core and core.input and core.input.pet_attack then
        self:debug_log(menu,
            "pet_attack attempt mode=%d lock_mode=%d reason=%s desired=%s guid=%s pet_dist=%.1f dt=%dms throttle=%dms",
            tonumber(mode) or 0, tonumber(self._locked_mode) or 0, tostring(self._locked_reason),
            safe_name(desired), tostring(desired_guid), tonumber(dist_pet) or -1,
            tonumber(dt) or -1, tonumber(throttle_ms) or -1)
        self._last_pet_attack_ms = now_ms
        if pet_attack(desired) then
            self._last_pet_attack_guid = desired_guid
            self:debug_log(menu, "pet_attack OK desired=%s guid=%s", safe_name(desired), tostring(desired_guid))
            return true
        end
        self:debug_log(menu, "pet_attack FAIL desired=%s guid=%s", safe_name(desired), tostring(desired_guid))
    elseif core and core.input and core.input.set_pet_assist then
        local pt = player and player.get_target and player:get_target() or nil
        if is_valid_enemy(pt) and same_unit(pt, desired) then
            self:debug_log(menu, "set_pet_assist attempt (desired=%s guid=%s)", safe_name(desired), tostring(desired_guid))
            self._last_pet_attack_ms = now_ms
            if set_pet_assist() then
                self._last_pet_attack_guid = desired_guid
                self:debug_log(menu, "set_pet_assist OK (target=%s)", safe_name(desired))
                return true
            end
            self:debug_log(menu, "set_pet_assist FAIL (target=%s)", safe_name(desired))
        end
    end

    return false
end

return M
