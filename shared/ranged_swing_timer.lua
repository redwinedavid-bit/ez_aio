local __object_safety=require("shared/object_safety")
-- Ranged Swing Timer (Shared)
-- Lightweight ranged auto-attack timer using only auto_attack_helper.
-- Usage:
--   local ranged_swing_timer = require("shared/ranged_swing_timer")
--   local timer = ranged_swing_timer.new({ id = "my_ranged", label = "Ranged" })
--   -- in on_update:
--   timer:on_update(player)
--   -- state:
--   local state = timer:get_state()

---@type color
local color = require("common/color")

---@type enums
local enums = require("common/enums")

---@type vec2
local vec2 = require("common/geometry/vector_2")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

-- ============================================================================
-- Helpers
-- ============================================================================

local function clamp(value, min_val, max_val)
    if value < min_val then return min_val end
    if value > max_val then return max_val end
    return value
end

local function format_ms(ms)
    if not ms or ms <= 0 then
        return "0.00s"
    end
    return string.format("%.2fs", ms / 1000)
end

-- ============================================================================
-- RangedSwingTimer class
-- ============================================================================

local RangedSwingTimer = {}
RangedSwingTimer.__index = RangedSwingTimer

function RangedSwingTimer:on_update(unit)
    if not unit then
        self._state = nil
        return
    end

    local ok_auto, is_auto = pcall(function()
        return auto_attack_helper:is_auto_attacking(unit)
    end)

    local last_swing = nil
    local next_swing = nil

    local ok_last, last_val = pcall(function()
        return auto_attack_helper:get_last_attack_game_time(unit)
    end)
    if ok_last and last_val and last_val > 0 then
        last_swing = last_val
    end

    local ok_next, next_val = pcall(function()
        return auto_attack_helper:get_next_attack_game_time(unit)
    end)
    if ok_next and next_val and next_val > 0 then
        next_swing = next_val
    end

    local now = core.game_time()

    -- Normalize: if helper returns seconds instead of ms
    if next_swing and next_swing > 0 and next_swing < 10000 and now > 10000 then
        if last_swing then last_swing = last_swing * 1000 end
        next_swing = next_swing * 1000
    end

    if not last_swing or not next_swing then
        self._state = nil
        return
    end

    local duration = next_swing - last_swing
    if duration <= 0 then
        self._state = nil
        return
    end

    local remaining = next_swing - now
    if remaining < 0 then remaining = 0 end

    local progress = clamp((now - last_swing) / duration, 0, 1)
    local is_attacking = (ok_auto and is_auto == true)

    self._state = {
        is_auto_attacking = is_attacking,
        now               = now,
        last_swing        = last_swing,
        next_swing        = next_swing,
        duration          = duration,
        remaining_ms      = remaining,
        progress          = progress,
    }
end

function RangedSwingTimer:get_state()
    return self._state
end

-- ============================================================================
-- Window rendering
-- ============================================================================

function RangedSwingTimer:_render_window()
    local unit = nil
    if self._unit_provider then
        unit = self._unit_provider()
    else
        unit = core.object_manager.get_local_player()
    end
    if not unit then
        return
    end

    -- Recompute state for render (in case on_update wasn't called this frame)
    self:on_update(unit)
    local state = self._state

    self._window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_WIDTH,
        false,
        self._window_bg,
        self._window_border,
        enums.window_enums.window_cross_visuals.NO_BACKGROUND_AND_NO_BORDER,
        function()
            local size = self._window:get_size()
            local padding = 8
            local label = self.label

            -- Label on the left
            self._window:render_text(
                enums.window_enums.font_id.FONT_SMALL,
                vec2.new(padding, 4),
                self._text_color,
                label
            )

            -- Time text on the right
            local time_text = "N/A"
            if state then
                if not state.is_auto_attacking then
                    time_text = "Idle"
                elseif state.remaining_ms and state.remaining_ms > 0 then
                    time_text = format_ms(state.remaining_ms)
                else
                    time_text = "0.00s"
                end
            end

            local text_size = self._window:get_text_size(time_text)
            local text_x = math.max(padding, size.x - padding - text_size.x)
            self._window:render_text(
                enums.window_enums.font_id.FONT_SMALL,
                vec2.new(text_x, 4),
                self._text_color,
                time_text
            )

            -- Progress bar
            local header_height = 12
            local bar_top = padding + header_height
            local bar_height = math.max(8, size.y - bar_top - padding)
            local bar_width = math.max(40, size.x - (padding * 2))

            local bar_start = vec2.new(padding, bar_top)
            local bar_end = vec2.new(padding + bar_width, bar_top + bar_height)

            -- Background
            self._window:render_rect_filled(bar_start, bar_end, self._bar_bg_color, 1.0)

            -- Fill
            local prog = (state and state.progress) or 0
            local fill_width = bar_width * prog
            if fill_width > 0 then
                local fill_end = vec2.new(bar_start.x + fill_width, bar_end.y)
                self._window:render_rect_filled(bar_start, fill_end, self._bar_color, 1.0)
            end

            -- Border
            self._window:render_rect(bar_start, bar_end, self._text_color, 1.0, 1.0)
        end
    )
end

-- ============================================================================
-- Constructor
-- ============================================================================

local ranged_swing_timer = {}

---@param opts table|nil
---@return table
function ranged_swing_timer.new(opts)
    opts = opts or {}

    local self = setmetatable({}, RangedSwingTimer)
    self.id    = opts.id or "ranged_swing_timer"
    self.label = opts.label or "Ranged"

    self._unit_provider = opts.unit_provider
    self._state = nil

    -- Colors (customizable via opts)
    self._bar_color     = opts.bar_color or color.orange(200)
    self._bar_bg_color  = opts.bar_bg_color or color.new(40, 40, 40, 180)
    self._text_color    = opts.text_color or color.white(230)
    self._window_bg     = opts.window_bg or color.new(0, 0, 0, 120)
    self._window_border = opts.window_border or color.new(0, 0, 0, 160)

    -- Window setup
    local enable_window = opts.enable_window ~= false
    local window_id = (opts.window_id or self.label) .. "##" .. self.id
    self._window = core.menu.window(window_id)
    self._window:set_initial_position(vec2.new(opts.default_x or 600, opts.default_y or 580))
    self._window:set_initial_size(vec2.new(opts.default_w or 240, opts.default_h or 50))

    if enable_window then
        core.register_on_render_window_callback(__object_safety.callback(function()
            self:_render_window()
        end,"shared/ranged_swing_timer.lua:232"))
    end

    return self
end

return ranged_swing_timer
