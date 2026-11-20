-- TabMenu - A reusable tabbed window UI system
-- Provides animated tabs, window persistence, and content panels
-- Version: 1.0.0

local color = require("common/color")
local vec2 = require("common/geometry/vector_2")
local enums = require("common/enums")

---@class TabMenu
local TabMenu = {}
TabMenu.__index = TabMenu

-- Animation Constants
local TAB_ANIMATION_SPEED = 0.11
local WIDGET_ENTRANCE_ANIMATION_SPEED = 0.06
local WIDGET_ENTRANCE_SLIDE_DISTANCE = 12

-- Default Color Palette (purple gradient theme)
local DEFAULT_COLORS = {
    background = {
        default = color.new(15, 10, 20, 168),
        content_panel = color.new(18, 15, 25, 130)
    },
    borders = {
        default = color.new(100, 67, 150, 179),
        header = color.new(120, 80, 180, 84),
        header_glow = color.new(100, 67, 150, 56),
        content_panel = color.new(90, 60, 135, 119)
    },
    header = {
        gradient_top = color.new(70, 47, 105, 154),
        gradient_bottom = color.new(50, 34, 75, 147)
    },
    tabs = {
        active_top = color.new(100, 67, 150, 179),
        active_bottom = color.new(80, 54, 120, 172),
        inactive_top = color.new(35, 30, 50, 161),
        inactive_bottom = color.new(30, 25, 45, 154),
        hover_glow = color.new(130, 87, 195, 70),
        shadow = color.new(0, 0, 0, 105)
    },
    text = {
        highlight = color.new(220, 200, 255, 179),
        title = color.new(255, 255, 255, 179),
        version = color.white(140),
        inactive = color.new(190, 180, 220, 168)
    }
}

-- ============================================================================
-- Helper Functions
-- ============================================================================

---Deep copies a color palette table
---@param original table
---@return table
local function deep_copy_colors(original)
    local copy = {}
    for key, value in pairs(original) do
        if type(value) == "table" and value.r == nil then
            copy[key] = deep_copy_colors(value)
        else
            copy[key] = value
        end
    end
    return copy
end

---Renders the window header with title and optional version
---@param self TabMenu
---@param window_width number
local function _render_header(self, window_width)
    local base = self.window:get_current_context_dynamic_drawing_offset()
    local at = function(x, y) return vec2.new(base.x + x, base.y + y) end
    local colors = self.colors

    -- Header gradient background
    local header_min = at(10, 4)
    local header_max = at(window_width - 10, 42)
    self.window:render_rect_filled_multicolor(
        header_min, header_max,
        colors.header.gradient_top, colors.header.gradient_top,
        colors.header.gradient_bottom, colors.header.gradient_bottom,
        8.0
    )
    self.window:render_rect(header_min, header_max, colors.borders.header_glow, 8.0, 2)
    self.window:render_rect(header_min, header_max, colors.borders.header, 8.0, 1)

    -- Header Title
    self.window:push_font(enums.window_enums.font_id.FONT_BIG)
    local title_size = self.window:get_text_size(self.title)
    local title_x = (window_width / 2) - (title_size.x / 2)
    self.window:render_text(enums.window_enums.font_id.FONT_BIG, at(title_x, 8), colors.text.title, self.title)
    self.window:pop_font()

    -- Version text (optional)
    if self.version then
        local version_text = "v" .. self.version
        self.window:render_text(
            enums.window_enums.font_id.FONT_SMALL,
            at(title_x + title_size.x + 5, 15),
            colors.text.version,
            version_text
        )
    end
end

---Renders the tab bar with animations
---@param self TabMenu
---@return function|nil active_render_func
---@return number content_start_y
local function _render_tab_bar(self)
    local colors = self.colors
    local base = self.window:get_current_context_dynamic_drawing_offset()
    local at = function(x, y) return vec2.new(base.x + x, base.y + y) end
    local active_render_func = nil

    local layout_x, layout_y = 10, 45
    local window_width = self.window:get_size().x
    local tab_colors = colors.tabs
    local text_colors = colors.text

    for i, tab in ipairs(self.tabs) do
        local tab_key = "tab_" .. i
        local tab_name = tab.name

        -- Calculate button width and handle wrapping
        local button_w = self.window:get_text_size(tab_name).x + 22
        if layout_x + button_w > (window_width - 10) then
            layout_x, layout_y = 10, layout_y + 30
        end

        -- Update tab position animation
        local entry = self._tab_positions[tab_key]
        if not entry then
            entry = { x = layout_x, y = layout_y - 8, target_x = layout_x, target_y = layout_y }
            self._tab_positions[tab_key] = entry
        end

        entry.target_x, entry.target_y = layout_x, layout_y
        entry.x = entry.x + (entry.target_x - entry.x) * TAB_ANIMATION_SPEED
        entry.y = entry.y + (entry.target_y - entry.y) * TAB_ANIMATION_SPEED

        -- Determine tab appearance based on active state
        local is_active = (self._active_tab_index == i)
        local bg_top = is_active and tab_colors.active_top or tab_colors.inactive_top
        local bg_bottom = is_active and tab_colors.active_bottom or tab_colors.inactive_bottom
        local border_col = is_active and color.new(120, 80, 180, 179) or color.new(60, 50, 90, 140)
        local text_color = is_active and text_colors.highlight or text_colors.inactive
        local lift = is_active and 2 or 0
        local pos_min = at(entry.x, entry.y - lift)
        local pos_max = at(entry.x + button_w, entry.y + 24 - lift)

        -- Render tab shadow
        self.window:render_rect_filled(
            vec2.new(pos_min.x - 1, pos_max.y),
            vec2.new(pos_max.x + 1, pos_max.y + 4),
            tab_colors.shadow, 5.0
        )

        -- Render active tab glow
        if is_active then
            self.window:render_rect(
                vec2.new(pos_min.x - 2, pos_min.y - 2),
                vec2.new(pos_max.x + 2, pos_max.y + 2),
                tab_colors.hover_glow, 6.0, 2
            )
        end

        -- Render tab background and border
        self.window:render_rect_filled_multicolor(
            pos_min, pos_max, bg_top, bg_top, bg_bottom, bg_bottom, 5.0
        )
        self.window:render_rect(pos_min, pos_max, border_col, 5.0, 1)
        self.window:render_text(
            enums.window_enums.font_id.FONT_NORMAL,
            at(entry.x + 10, entry.y + 5 - lift),
            text_color, tab_name
        )

        -- Handle tab click
        if self.window:is_rect_clicked(pos_min, pos_max) and self._active_tab_index ~= i then
            self._entrance_anim.progress = 0.0
            self._entrance_anim.last_tab = i
            self._active_tab_index = i
        end

        -- Store active tab render function
        if is_active then
            active_render_func = tab.render
        end

        layout_x = layout_x + button_w + 5
    end

    -- Calculate content start position
    local max_row_y = 45
    for _, pos in pairs(self._tab_positions) do
        max_row_y = math.max(max_row_y, pos.target_y)
    end

    return active_render_func, max_row_y + 34
end

---Renders the content panel for the active tab
---@param self TabMenu
---@param content_start_y number
---@param active_render_func function
local function _render_content_panel(self, content_start_y, active_render_func)
    local colors = self.colors
    local ws = self.window:get_size()
    local base = self.window:get_current_context_dynamic_drawing_offset()
    local at = function(x, y) return vec2.new(base.x + x, base.y + y) end

    -- Render content panel background
    local content_min = at(10, content_start_y)
    local content_max = at(ws.x - 10, ws.y - 10)
    self.window:render_rect_filled(content_min, content_max, colors.background.content_panel, 8.0)
    self.window:render_rect(content_min, content_max, colors.borders.content_panel, 8.0, 1)

    -- Set content offset
    self.window:add_menu_element_pos_offset(vec2.new(20, content_start_y + 15))

    if active_render_func then
        -- Update entrance animation state
        local entrance = self._entrance_anim
        if entrance.last_tab == self._active_tab_index then
            entrance.progress = math.min(1.0, entrance.progress + WIDGET_ENTRANCE_ANIMATION_SPEED)
        else
            entrance.progress = 1.0
            entrance.last_tab = self._active_tab_index
        end

        -- Apply entrance animation offset
        local offset_y = (1 - entrance.progress) * WIDGET_ENTRANCE_SLIDE_DISTANCE
        self.window:add_menu_element_pos_offset(vec2.new(0, offset_y))
        active_render_func(self.window, self)
        self.window:add_menu_element_pos_offset(vec2.new(0, -offset_y))
    else
        self.window:add_text_on_dynamic_pos(color.white(), "No tab content available.")
    end
end

---Persists window state to hidden sliders
---@param self TabMenu
local function _persist_window_state(self)
    if not self._is_visible then
        self._state_saved = false
        return
    end

    local ws = self.window:get_size()
    local wp = self.window:get_position()

    local size_changed = self._last_size and (
        math.abs(self._last_size.x - ws.x) > 1 or
        math.abs(self._last_size.y - ws.y) > 1
    )
    local pos_changed = self._last_pos and (
        math.abs(self._last_pos.x - wp.x) > 1 or
        math.abs(self._last_pos.y - wp.y) > 1
    )

    if not self._state_saved or size_changed or pos_changed then
        self._persist_size_x:set(math.floor(ws.x))
        self._persist_size_y:set(math.floor(ws.y))
        self._persist_pos_x:set(math.floor(wp.x))
        self._persist_pos_y:set(math.floor(wp.y))
        self._last_size = { x = ws.x, y = ws.y }
        self._last_pos = { x = wp.x, y = wp.y }
        self._state_saved = true
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

---Creates a new TabMenu instance
---@param config table Configuration options
---@return TabMenu
function TabMenu.new(config)
    config = config or {}

    local self = setmetatable({}, TabMenu)

    -- Required config
    self.id = config.id or "tab_menu"
    self.title = config.title or "Menu"
    self.version = config.version -- optional

    -- Window setup
    self.window = core.menu.window(self.title)
    self._is_visible = false
    self._active_tab_index = 1
    self.tabs = {}
    self._tab_positions = {}
    self._entrance_anim = { progress = 1.0, last_tab = nil }

    -- Colors (allow customization)
    self.colors = config.colors or deep_copy_colors(DEFAULT_COLORS)

    -- Window size/position defaults
    local default_width = config.default_width or 600
    local default_height = config.default_height or 400
    local default_x = config.default_x or 250
    local default_y = config.default_y or 360

    -- Persistence sliders (hidden, used to save window state)
    local prefix = self.id .. "_persist_"
    self._persist_size_x = core.menu.slider_int(300, 3000, default_width, prefix .. "w")
    self._persist_size_y = core.menu.slider_int(200, 2000, default_height, prefix .. "h")
    self._persist_pos_x = core.menu.slider_int(-1000, 10000, default_x, prefix .. "x")
    self._persist_pos_y = core.menu.slider_int(-1000, 10000, default_y, prefix .. "y")

    self._last_size = nil
    self._last_pos = nil
    self._state_saved = false

    -- Apply persisted state
    local initial_size = vec2.new(self._persist_size_x:get(), self._persist_size_y:get())
    local initial_pos = vec2.new(self._persist_pos_x:get(), self._persist_pos_y:get())

    self.window:set_initial_size(initial_size)
    self.window:set_initial_position(initial_pos)

    return self
end

---Adds a tab to the menu
---@param name string Tab display name
---@param render_func function Render callback: function(window, menu)
---@return TabMenu self (for chaining)
function TabMenu:add_tab(name, render_func)
    table.insert(self.tabs, {
        name = name,
        render = render_func
    })
    return self
end

---Removes a tab by name
---@param name string Tab name to remove
---@return boolean success
function TabMenu:remove_tab(name)
    for i, tab in ipairs(self.tabs) do
        if tab.name == name then
            table.remove(self.tabs, i)
            if self._active_tab_index > #self.tabs then
                self._active_tab_index = math.max(1, #self.tabs)
            end
            return true
        end
    end
    return false
end

---Sets the active tab by index
---@param index number Tab index (1-based)
function TabMenu:set_active_tab(index)
    if index >= 1 and index <= #self.tabs then
        self._entrance_anim.progress = 0.0
        self._entrance_anim.last_tab = index
        self._active_tab_index = index
    end
end

---Gets the currently active tab index
---@return number index
function TabMenu:get_active_tab()
    return self._active_tab_index
end

---Sets the visibility of the menu
---@param visible boolean
function TabMenu:set_visible(visible)
    self._is_visible = visible
    self.window:set_visibility(visible)
end

---Toggles the menu visibility
function TabMenu:toggle()
    self:set_visible(not self._is_visible)
end

---Gets the current visibility state
---@return boolean
function TabMenu:is_visible()
    return self._is_visible
end

---Gets the underlying window object
---@return table window
function TabMenu:get_window()
    return self.window
end

---Updates the window colors dynamically
---@param bg_color table|nil Background color
---@param border_color table|nil Border color
function TabMenu:update_colors(bg_color, border_color)
    if bg_color then
        -- Create a new color object to ensure it's properly set
        if type(bg_color) == "table" and bg_color.r then
            self.colors.background.default = color.new(bg_color.r, bg_color.g, bg_color.b, bg_color.a or 255)
        else
            self.colors.background.default = bg_color
        end
    end
    if border_color then
        -- Create a new color object to ensure it's properly set
        if type(border_color) == "table" and border_color.r then
            self.colors.borders.default = color.new(border_color.r, border_color.g, border_color.b, border_color.a or 255)
        else
            self.colors.borders.default = border_color
        end
    end
end

---Main render function (call from on_render_window callback)
---@param bg_color table|nil Optional background color override
---@param border_color table|nil Optional border color override
function TabMenu:render(bg_color, border_color)
    if not self._is_visible then return end
    if #self.tabs == 0 then return end

    -- Use provided colors or fall back to default colors
    local final_bg_color = bg_color or self.colors.background.default
    local final_border_color = border_color or self.colors.borders.default

    self.window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        false,
        final_bg_color,
        final_border_color,
        enums.window_enums.window_cross_visuals.DEFAULT,
        0, 0, 0,
        function()
            local window_width = self.window:get_size().x
            _render_header(self, window_width)
            local active_render_func, content_start_y = _render_tab_bar(self)
            if active_render_func then
                _render_content_panel(self, content_start_y, active_render_func)
            end
            _persist_window_state(self)
        end
    )
end

-- ============================================================================
-- Static Helper: Settings Panel
-- ============================================================================

---Creates a scrollable settings panel with automatic element padding
---@param window table Window reference
---@param callback function Callback: function(render) where render adds padding
function TabMenu.create_settings_panel(window, callback)
    local ws = window:get_size()
    local available_width = ws and ws.x or 600

    local current_offset = window:get_current_context_dynamic_drawing_offset()
    local window_height = ws and ws.y or 300
    local current_y = current_offset and current_offset.y or 0
    local available_height = math.max(100, window_height - current_y - 25)

    local padding = vec2.new(25, 0)

    -- WICHTIG: true = scrollbar aktivieren, damit der gesamte Inhalt (inkl. Headers) scrollt
    window:begin_window_sub_context(vec2.new(available_width, available_height), true, function()
        local function render_with_padding(render_func)
            window:add_menu_element_pos_offset(padding)
            render_func()
        end
        callback(render_with_padding)
    end)
end

---Returns the default color palette (for customization reference)
---@return table colors
function TabMenu.get_default_colors()
    return deep_copy_colors(DEFAULT_COLORS)
end

return TabMenu

