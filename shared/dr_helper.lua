-- ============================================================================
-- DR (Diminishing Returns) Helper Module
-- Wraps native Project Sylvanas API for rotation-friendly DR queries.
-- Usage: local dr = require("shared/dr_helper")
--        if dr.should_fear(target) then ...
-- ============================================================================

local dr_helper = {}

---@type color
local color = require("common/color")

-- DR categories relevant to Warlock
dr_helper.CATEGORY = {
    FEAR    = "fear",
    HORROR  = "horror",
    STUN    = "stun",
    SILENCE = "silence",
    ROOT    = "root",
}

-- DR multiplier thresholds
dr_helper.DR_FULL    = 1.0
dr_helper.DR_HALF    = 0.5
dr_helper.DR_QUARTER = 0.25
dr_helper.DR_IMMUNE  = 0.0

-- ============================================================================
-- CORE QUERIES
-- ============================================================================

--- Get current DR multiplier for target + category.
--- Returns 1.0 on failure (safe default = "no diminishing").
---@param target game_object
---@param category string  e.g. "fear", "horror", "stun"
---@return number  1.0 / 0.5 / 0.25 / 0.0
function dr_helper.get_dr(target, category)
    if not target or not target.get_dr then return 1.0 end
    local ok, dr = pcall(function() return target:get_dr(category) end)
    return (ok and type(dr) == "number" and dr) or 1.0
end

--- Seconds until DR resets for target + category.
---@param target game_object
---@param category string
---@return number
function dr_helper.get_dr_reset_time(target, category)
    if not target or not target.get_dr_time then return 0 end
    local ok, t = pcall(function() return target:get_dr_time(category) end)
    return (ok and type(t) == "number" and t) or 0
end

-- ============================================================================
-- HIGH-LEVEL ROTATION HELPERS
-- ============================================================================

--- Should we Fear this target?  Returns true when DR >= 50% (duration >= half).
---@param target game_object
---@param min_dr? number  optional override (default 0.5)
---@return boolean
function dr_helper.should_fear(target, min_dr)
    return dr_helper.get_dr(target, "fear") >= (min_dr or 0.5)
end

--- Should we Death Coil (Horror) this target?
---@param target game_object
---@return boolean
function dr_helper.should_death_coil(target)
    return dr_helper.get_dr(target, "horror") >= 0.5
end

--- Should we Howl of Terror? Same DR category as Fear.
---@param target game_object
---@return boolean
function dr_helper.should_howl(target)
    return dr_helper.get_dr(target, "fear") >= 0.5
end

--- Get the best available CC option for a target.
--- Returns "fear", "death_coil", "howl", or nil if all DR'd out.
---@param target game_object
---@return string|nil
function dr_helper.get_best_cc(target)
    local fear_dr   = dr_helper.get_dr(target, "fear")
    local horror_dr = dr_helper.get_dr(target, "horror")
    -- Prefer Fear (longer duration, more flexible)
    if fear_dr >= 0.5 then return "fear" end
    -- Fall back to Death Coil (separate DR category)
    if horror_dr >= 0.5 then return "death_coil" end
    -- Howl shares fear DR but is instant AoE - useful as last resort at 0.25 DR
    if fear_dr >= 0.25 then return "howl" end
    return nil
end

--- Is the target currently under CC?
---@param target game_object
---@param min_remaining_ms? number  default 500
---@return boolean
function dr_helper.is_cc_active(target, min_remaining_ms)
    if not target then return false end
    min_remaining_ms = min_remaining_ms or 500
    -- Check Fear + Horror categories
    local ok1, feared = pcall(function() return target:is_cc(min_remaining_ms, target.CC and target.CC.FEAR) end)
    if ok1 and feared then return true end
    local ok2, horrified = pcall(function() return target:is_cc(min_remaining_ms, target.CC and target.CC.HORROR) end)
    if ok2 and horrified then return true end
    return false
end

-- ============================================================================
-- OVERLAY / VISUALIZATION HELPERS
-- ============================================================================

--- Returns a color object based on DR value.
--- Green = full, Yellow = half, Orange = quarter, Red = immune.
---@param dr_value number
---@return userdata  color object
function dr_helper.get_dr_color(dr_value)
    if dr_value >= 1.0  then return color.new(0,   255, 0,   255) end -- Green
    if dr_value >= 0.5  then return color.new(255, 255, 0,   255) end -- Yellow
    if dr_value >= 0.25 then return color.new(255, 128, 0,   255) end -- Orange
    return color.new(255, 0, 0, 255)                                   -- Red
end

--- Formatted string for DR display (e.g. "100%", "50%", "IMMUNE").
---@param dr_value number
---@return string
function dr_helper.format_dr(dr_value)
    if dr_value <= 0 then return "IMMUNE" end
    return string.format("%.0f%%", dr_value * 100)
end

return dr_helper
