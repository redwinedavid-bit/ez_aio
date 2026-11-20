-- ============================================================================
-- Druid Powershifting State Machine - TBC (2.4.3)
-- Core DPS mechanic: Leave Cat Form → Re-enter → Gain 60 energy (Furor+Wolfshead)
-- ============================================================================

local powershift = {}

local spells = require("rotations/druid/tbc/spells")

-- ============================================================================
-- STATE
-- ============================================================================

powershift.state = "idle" -- "idle" | "leaving" | "entering"

local _last_shift_time = 0
local _shift_start_time = 0
local SHIFT_COOLDOWN_MS = 1500   -- GCD between form shifts
local SHIFT_TIMEOUT_MS = 2500    -- Max time to complete a shift cycle
local MIN_MANA_PCT = 8           -- Need mana to shift back into cat form

-- ============================================================================
-- DECISION: Should we powershift?
-- ============================================================================

---@param player any
---@param energy number Current energy
---@param mana_pct number Current mana percentage
---@param menu table Menu elements
---@param helpers table Helpers module
---@param tick_tracker any Resource tick tracker (optional)
---@return boolean
function powershift:should_powershift(player, energy, mana_pct, menu, helpers, tick_tracker)
    -- Only from idle state
    if self.state ~= "idle" then return false end

    -- Must be enabled
    if not helpers:get_menu_state(menu.cat_powershift_enabled, true) then return false end

    -- Must be in cat form
    if not helpers:is_in_form(player, "cat") then return false end

    -- Energy threshold from menu (default 30)
    local energy_threshold = helpers:get_menu_value(menu.cat_powershift_energy, 30)
    if energy > energy_threshold then return false end

    -- Need mana to shift back
    if mana_pct < MIN_MANA_PCT then return false end

    -- Respect GCD cooldown
    local now = core.game_time()
    if (now - _last_shift_time) < SHIFT_COOLDOWN_MS then return false end

    -- Don't powershift at very low HP (survival first)
    local hp = helpers:get_hp_pct(player)
    if hp < 20 then return false end

    -- Don't powershift if stunned/incapacitated
    if helpers:is_stunned(player) then return false end

    -- Optional: Check energy tick timing
    -- If next energy tick is coming soon, wait for it instead of shifting
    if tick_tracker then
        local ok, next_tick_ms = pcall(function()
            return tick_tracker:get_next_energy_tick_ms()
        end)
        if ok and next_tick_ms and next_tick_ms > 0 and next_tick_ms < 500 then
            -- Energy tick coming in <500ms, wait instead of shifting
            return false
        end
    end

    return true
end

-- ============================================================================
-- EXECUTION: Run the powershift state machine
-- ============================================================================

---@param player any
---@param helpers table
---@return boolean did_action (true = block rotation this frame)
function powershift:execute(player, helpers)
    local now = core.game_time()

    -- ========================================
    -- STATE: IDLE → Start leaving form
    -- ========================================
    if self.state == "idle" then
        _shift_start_time = now

        -- Leave cat form by re-casting Cat Form (toggles it off)
        local success = helpers:try_leave_form(player)
        if success then
            self.state = "leaving"
            _last_shift_time = now
            helpers:log_checkpoint("powershift.leave", 0.2, "[Druid][Powershift] Leaving cat form")
            return true
        end

        -- Failed to leave, stay idle
        return false
    end

    -- ========================================
    -- STATE: LEAVING → Wait for form drop, then re-enter
    -- ========================================
    if self.state == "leaving" then
        -- Timeout check
        if (now - _shift_start_time) > SHIFT_TIMEOUT_MS then
            helpers:log_checkpoint("powershift.timeout", 1.0, "[Druid][Powershift] Timeout in leaving state, resetting")
            self.state = "idle"
            return false
        end

        -- Check if we successfully left cat form
        if not helpers:is_in_form(player, "cat") then
            self.state = "entering"
            -- Fall through to entering immediately
        else
            -- Still in cat form, waiting for form drop
            return true
        end
    end

    -- ========================================
    -- STATE: ENTERING → Re-enter cat form
    -- ========================================
    if self.state == "entering" then
        -- Timeout check
        if (now - _shift_start_time) > SHIFT_TIMEOUT_MS then
            helpers:log_checkpoint("powershift.timeout", 1.0, "[Druid][Powershift] Timeout in entering state, resetting")
            self.state = "idle"
            return false
        end

        -- Cast Cat Form to re-enter (gains Furor energy + Wolfshead bonus)
        local success = helpers:try_cast(spells.cat_form, player, "[Powershift] → Cat Form")
        if success then
            helpers:set_last_form_change_time(now)
            helpers:log_checkpoint("powershift.enter", 0.2, "[Druid][Powershift] Re-entering cat form")
            self.state = "idle"
            return true
        end

        -- Form GCD may still be active, block rotation while we wait
        return true
    end

    return false
end

-- ============================================================================
-- RESET
-- ============================================================================

function powershift:reset()
    self.state = "idle"
    _last_shift_time = 0
    _shift_start_time = 0
end

--- Check if powershift is actively in progress
function powershift:is_active()
    return self.state ~= "idle"
end

return powershift
