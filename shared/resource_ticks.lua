local __object_safety=require("shared/object_safety")
-- Resource Tick + 5SR Tracker (Classic-style)
-- Library-only module (no rendering).

---@type enums
local enums = require("common/enums")

local game_client = require("shared/game_client")

---@type izi_sdk|nil
local izi = nil
do
    local ok, mod = pcall(require, "common/izi_sdk")
    if ok then
        izi = mod
    end
end

local function now_ms()
    if izi and izi.now_ms then
        return izi.now_ms()
    end
    return math.floor((core.time() or 0) * 1000 + 0.5)
end

local function clamp(v, min_v, max_v)
    if v < min_v then
        return min_v
    end
    if v > max_v then
        return max_v
    end
    return v
end

---@param unit game_object|nil
---@param power_type integer
---@return number|nil
local function safe_get_power(unit, power_type)
    if not unit then
        return nil
    end
    local ok, v = pcall(function()
        return unit:get_power(power_type)
    end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

---@param unit game_object|nil
---@param power_type integer
---@return number|nil
local function safe_get_power_max(unit, power_type)
    if not unit then
        return nil
    end
    local ok, v = pcall(function()
        return unit:get_max_power(power_type)
    end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

---@param spell_id integer
---@return boolean
local function spell_can_cost_mana(spell_id)
    if not spell_id or spell_id <= 0 then
        return false
    end

    local ok, costs = pcall(function()
        return core.spell_book.get_spell_costs(spell_id)
    end)
    if not ok or not costs then
        return false
    end

    if type(costs) == "table" then
        for _, c in pairs(costs) do
            if type(c) == "table" and type(c.cost_type) == "number" then
                if c.cost_type == enums.power_type.MANA then
                    local cost = tonumber(c.cost or 0) or 0
                    local min_cost = tonumber(c.min_cost or 0) or 0
                    local cost_per_sec = tonumber(c.cost_per_sec or 0) or 0
                    if cost > 0 or min_cost > 0 or cost_per_sec > 0 then
                        return true
                    end
                end
            end
        end
    end

    return false
end

---@class resource_tick_state
---@field last_value number|nil
---@field last_tick_ms number|nil
---@field next_tick_ms number|nil
---@field period_ms integer

---@class resource_ticks_tracker
---@field _energy resource_tick_state
---@field _mana resource_tick_state
---@field _tick_filtering boolean
---@field _pending_mana_cast table|nil
---@field _last_mana_spent_ms number|nil
---@field _fsr_end_ms number|nil
---@field _last_local_player_id string|nil
local ResourceTicks = {}
ResourceTicks.__index = ResourceTicks

function ResourceTicks:_reset_energy(now)
    self._energy.last_value = nil
    self._energy.last_tick_ms = now
    self._energy.next_tick_ms = now + self._energy.period_ms
end

function ResourceTicks:_reset_mana(now)
    self._mana.last_value = nil
    self._mana.last_tick_ms = now
    self._mana.next_tick_ms = now + self._mana.period_ms
end

---@param unit game_object
---@param now number
function ResourceTicks:_update_energy(unit, now)
    local energy = safe_get_power(unit, enums.power_type.ENERGY)
    if energy == nil then
        return
    end

    local energy_max = safe_get_power_max(unit, enums.power_type.ENERGY) or energy

    if self._energy.last_value == nil then
        self._energy.last_value = energy
        if not self._energy.last_tick_ms then
            self:_reset_energy(now)
        end
        return
    end

    local prev = self._energy.last_value
    self._energy.last_value = energy

    local observed_tick = false

    if energy > prev then
        if self._tick_filtering then
            local diff = energy - prev
            if (diff > 18 and diff < 22) or (diff > 38 and diff < 42) or (diff < 42 and energy >= energy_max) then
                observed_tick = true
            end
        else
            observed_tick = true
        end
    end

    if observed_tick then
        self._energy.last_tick_ms = now
        self._energy.next_tick_ms = now + self._energy.period_ms
        return
    end

    -- Free-running fallback to keep a stable phase even if ticks are missed (cap/lag).
    if self._energy.next_tick_ms and now >= self._energy.next_tick_ms then
        while self._energy.next_tick_ms and now >= self._energy.next_tick_ms do
            self._energy.last_tick_ms = self._energy.next_tick_ms
            self._energy.next_tick_ms = self._energy.next_tick_ms + self._energy.period_ms
        end
    elseif self._energy.last_tick_ms and now >= (self._energy.last_tick_ms + self._energy.period_ms) then
        self._energy.last_tick_ms = now
        self._energy.next_tick_ms = now + self._energy.period_ms
    end
end

---@param unit game_object
---@param now number
function ResourceTicks:_update_mana(unit, now)
    local mana = safe_get_power(unit, enums.power_type.MANA)
    if mana == nil then
        return
    end

    local mana_max = safe_get_power_max(unit, enums.power_type.MANA) or mana

    if self._mana.last_value == nil then
        self._mana.last_value = mana
        if not self._mana.last_tick_ms then
            self:_reset_mana(now)
        end
        return
    end

    local prev = self._mana.last_value
    self._mana.last_value = mana

    local observed_tick = false
    local diff = mana - prev

    if diff > 0 then
        -- Ignore large external bursts (potions, innervate-like effects) for sync purposes.
        local abs_limit = 800
        local pct_limit = math.floor((mana_max * 0.08) + 0.5) -- 8% max
        local burst_limit = math.max(abs_limit, pct_limit)
        if diff <= burst_limit then
            observed_tick = true
        end
    end

    if observed_tick then
        self._mana.last_tick_ms = now
        self._mana.next_tick_ms = now + self._mana.period_ms
        return
    end

    -- Free-running fallback to keep a usable phase even when at/near full mana.
    if self._mana.next_tick_ms and now >= self._mana.next_tick_ms then
        while self._mana.next_tick_ms and now >= self._mana.next_tick_ms do
            self._mana.last_tick_ms = self._mana.next_tick_ms
            self._mana.next_tick_ms = self._mana.next_tick_ms + self._mana.period_ms
        end
    elseif self._mana.last_tick_ms and now >= (self._mana.last_tick_ms + self._mana.period_ms) then
        self._mana.last_tick_ms = now
        self._mana.next_tick_ms = now + self._mana.period_ms
    end
end

---@param unit game_object
---@param now number
function ResourceTicks:_update_5sr(unit, now)
    if not self._pending_mana_cast then
        return
    end

    local pending = self._pending_mana_cast
    if pending.deadline_ms and now > pending.deadline_ms then
        self._pending_mana_cast = nil
        return
    end

    local mana_now = safe_get_power(unit, enums.power_type.MANA)
    if mana_now == nil then
        return
    end

    local mana_before = pending.mana_before
    if mana_before ~= nil and mana_now < (mana_before - 0.5) then
        self._last_mana_spent_ms = now
        self._fsr_end_ms = now + 5000
        self._pending_mana_cast = nil
    end
end

---@param unit game_object|nil
function ResourceTicks:on_update(unit)
    local now = now_ms()

    if not unit then
        return
    end

    local id = tostring(unit)
    if not self._last_local_player_id or self._last_local_player_id ~= id then
        self._last_local_player_id = id
    end

    if not self._energy.last_tick_ms then
        self:_reset_energy(now)
    end
    if not self._mana.last_tick_ms then
        self:_reset_mana(now)
    end

    self:_update_energy(unit, now)
    self:_update_mana(unit, now)
    self:_update_5sr(unit, now)
end

---@return number
function ResourceTicks:energy_elapsed_ms()
    local now = now_ms()
    local last = self._energy.last_tick_ms or now
    return math.max(0, now - last)
end

---@return number
function ResourceTicks:energy_ms_to_next_tick()
    local now = now_ms()
    local next_tick = self._energy.next_tick_ms
    if not next_tick then
        return self._energy.period_ms
    end
    return math.max(0, next_tick - now)
end

---@return number
function ResourceTicks:energy_progress_01()
    return clamp(self:energy_elapsed_ms() / self._energy.period_ms, 0, 1)
end

---@return number
function ResourceTicks:mana_elapsed_ms()
    local now = now_ms()
    local last = self._mana.last_tick_ms or now
    return math.max(0, now - last)
end

---@return number
function ResourceTicks:mana_ms_to_next_tick()
    local now = now_ms()
    local next_tick = self._mana.next_tick_ms
    if not next_tick then
        return self._mana.period_ms
    end
    return math.max(0, next_tick - now)
end

---@return number
function ResourceTicks:mana_progress_01()
    return clamp(self:mana_elapsed_ms() / self._mana.period_ms, 0, 1)
end

---@return number
function ResourceTicks:fsr_remaining_ms()
    local now = now_ms()
    local end_ms = self._fsr_end_ms
    if not end_ms or end_ms <= now then
        return 0
    end
    return end_ms - now
end

---@return boolean
function ResourceTicks:fsr_active()
    return self:fsr_remaining_ms() > 0
end

---@return number
function ResourceTicks:fsr_progress_01()
    local rem = self:fsr_remaining_ms()
    if rem <= 0 then
        return 0
    end
    return clamp(rem / 5000, 0, 1)
end

---@param enabled boolean
function ResourceTicks:set_tick_filtering(enabled)
    self._tick_filtering = enabled == true
end

local function handle_spell_event(self, ev)
    if not ev or type(ev) ~= "table" then
        return
    end

    local spell_id = ev.spell_id
    local caster = ev.caster
    if type(spell_id) ~= "number" or spell_id <= 0 or not caster then
        return
    end

    local lp = core.object_manager.get_local_player()
    if not lp then
        return
    end

    local is_me = __object_safety.same(caster,lp)
    if not is_me then
        return
    end

    if not spell_can_cost_mana(spell_id) then
        return
    end

    local mana_before = safe_get_power(lp, enums.power_type.MANA)
    if mana_before == nil then
        return
    end

    local ts = now_ms()
    self._pending_mana_cast = {
        ts_ms = ts,
        deadline_ms = ts + 250,
        spell_id = spell_id,
        mana_before = mana_before
    }
end

local function register_spell_events(self)
    if self._spell_events_registered then
        return
    end
    self._spell_events_registered = true

    if izi and izi.on_spell_success then
        izi.on_spell_success(function(ev)
            handle_spell_event(self, ev)
        end)
    end

    if core.register_on_spell_cast_callback then
        core.register_on_spell_cast_callback(__object_safety.callback(function(ev)
            handle_spell_event(self, ev)
        end,"shared/resource_ticks.lua:408"))
    end

    if core.register_on_legit_spell_cast_callback then
        core.register_on_legit_spell_cast_callback(__object_safety.callback(function(spell_id)
            -- Compat: docs mention "data is filled with spell id" (some builds pass number instead of table)
            if type(spell_id) == "table" then
                handle_spell_event(self, spell_id)
                return
            end
            handle_spell_event(self, { spell_id = spell_id, caster = core.object_manager.get_local_player() })
        end,"shared/resource_ticks.lua:414"))
    end
end

---@return resource_ticks_tracker
local function new_tracker()
    local self = setmetatable({}, ResourceTicks)
    -- Tick filtering assumes classic-style 20/40 energy jumps; TBC can have more frequent smaller gains
    -- (e.g. Combat Potency), which can desync filtering-based detection. Default to no filtering in TBC.
    self._tick_filtering = game_client.get_flavor() == "era"
    self._pending_mana_cast = nil
    self._last_mana_spent_ms = nil
    self._fsr_end_ms = nil

    self._energy = {
        last_value = nil,
        last_tick_ms = nil,
        next_tick_ms = nil,
        period_ms = 2000
    }
    self._mana = {
        last_value = nil,
        last_tick_ms = nil,
        next_tick_ms = nil,
        period_ms = 2000
    }

    register_spell_events(self)
    return self
end

local api = {}
local singleton = nil

---@return resource_ticks_tracker
function api.get()
    if not singleton then
        singleton = new_tracker()
    end
    return singleton
end

return api
