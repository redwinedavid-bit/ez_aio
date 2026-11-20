-- Rogue: Adrenaline Rush timing state (shared between rotation + visuals)

local resource_ticks = require("shared/resource_ticks")

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

local state = {
    armed = false,
    armed_at_ms = 0,
    safety_ms = 150
}

local api = {}

---@param safety_ms number|nil
function api.arm(safety_ms)
    state.armed = true
    state.armed_at_ms = now_ms()
    if type(safety_ms) == "number" and safety_ms >= 0 then
        state.safety_ms = math.floor(safety_ms + 0.5)
    end
end

function api.clear()
    state.armed = false
end

---@return boolean
function api.is_armed()
    return state.armed == true
end

---@return number
function api.armed_age_ms()
    if not state.armed then
        return 0
    end
    return math.max(0, now_ms() - (state.armed_at_ms or 0))
end

---@return number
function api.safety_ms()
    return state.safety_ms or 150
end

---@return number
function api.ms_to_next_energy_tick()
    return resource_ticks.get():energy_ms_to_next_tick()
end

---@return boolean
function api.should_cast_now()
    if not state.armed then
        return false
    end
    return api.ms_to_next_energy_tick() <= (state.safety_ms or 150)
end

return api

