-- Shared Rotation Settings Custom UI
-- A reusable custom window module for displaying rotation settings across all classes

---@type color
local color = require("common/color")

---@type vec2
local vec2 = require("common/geometry/vector_2")

---@type enums
local enums = require("common/enums")

-- ============================================================================
-- HELPER FUNCTIONS (Menu API Compatibility)
-- ============================================================================

local function menu_slider_int(min_value, max_value, default_value, id)
    if core.menu.slider_int then
        return core.menu.slider_int(min_value, max_value, default_value, id)
    end
    if core.menu.slider then
        local slider = core.menu.slider(min_value, max_value, default_value, id)
        if slider and slider.as_int then
            return slider:as_int()
        end
        return slider
    end
    if core.menu.new_slider then
        local slider = core.menu.new_slider(min_value, max_value, default_value, id)
        if slider and slider.as_int then
            return slider:as_int()
        end
        return slider
    end
    return nil
end

local function menu_checkbox(default_value, id)
    if core.menu.checkbox then
        return core.menu.checkbox(default_value, id)
    end
    return nil
end

local function menu_combobox(default_value, id)
    if core.menu.combobox then
        return core.menu.combobox(default_value, id)
    end
    return nil
end

-- ============================================================================
-- LAYOUT CONSTANTS
-- ============================================================================

local LAYOUT = {
    padding_top = 10,
    padding_side = 15,
    padding_bottom = 15,

    -- Tab system
    tab_bar_height = 35,
    tab_button_height = 30,
    tab_button_min_width = 80,
    tab_button_max_width = 150,
    tab_button_spacing = 2,
    tab_bar_padding_top = 5,
    tab_content_padding_top = 15,
    tab_bar_right_reserved = 48,

    -- Optional side menu (sub-categories inside a tab)
    side_menu_width = 190,
    side_menu_padding = 10,
    side_menu_item_height = 24,
    side_menu_item_spacing = 4,
    side_menu_gap = 10,

    -- Section settings
    section_spacing = 18,
    section_header_height = 0,
    section_padding_top = 8,
    section_padding_bottom = 10,
    element_height = 26,
    element_spacing = 6,
    column_spacing = 25,
    slider_bar_height = 16,
    checkbox_size = 16,
    keybind_badge_width = 60,
    keybind_status_width = 45,
    keybind_clear_width = 60,
    separator_height = 2
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Helper to lighten color for hover states
local function lighten_color(base_color, amount)
    -- Return a brightened version of the color for hover effects
    -- This is a simplified version that returns a lighter shade
    return color.new(60, 60, 70, 200)
end

-- ============================================================================
-- COLOR THEMES
-- ============================================================================

-- Theme names and indices mapping
local THEME_NAMES = { "astro", "warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid" }
local THEME_INDEX = {
    astro = 1,
    warrior = 2,
    paladin = 3,
    hunter = 4,
    rogue = 5,
    priest = 6,
    shaman = 7,
    mage = 8,
    warlock = 9,
    druid = 10
}

local THEMES = {
    -- Astro - Cosmic purple/violet theme
    astro = {
        background = color.new(15, 10, 30, 220),
        border = color.new(140, 100, 220, 255),
        section_bg = color.new(25, 18, 45, 180),
        section_border = color.new(120, 80, 200, 200),
        primary_accent = color.new(160, 100, 255, 255),
        secondary_accent = color.new(100, 200, 255, 255),
        text_primary = color.new(240, 240, 255, 255),
        text_secondary = color.new(200, 210, 240, 255),
        text_disabled = color.new(110, 100, 130, 255),
        slider_fill = color.new(160, 100, 255, 220),
        slider_bg = color.new(30, 25, 50, 200),
        checkbox_active = color.new(160, 100, 255, 255),
        checkbox_inactive = color.new(55, 45, 75, 200),
        checkbox_border = color.new(120, 80, 200, 200),
        keybind_bg = color.new(28, 20, 48, 220),
        keybind_border = color.new(120, 80, 200, 180),
        keybind_active = color.new(100, 200, 255, 255),
        keybind_inactive = color.new(45, 35, 65, 200),
        separator = color.new(120, 80, 200, 200)
    },
    -- Warrior - Tan/Brown (Class color: #C79C6E)
    warrior = {
        background = color.new(22, 18, 15, 220),
        border = color.new(199, 156, 110, 255),
        section_bg = color.new(30, 25, 20, 180),
        section_border = color.new(180, 140, 95, 200),
        primary_accent = color.new(220, 175, 125, 255),
        secondary_accent = color.new(200, 120, 60, 255),
        text_primary = color.new(245, 240, 230, 255),
        text_secondary = color.new(220, 210, 195, 255),
        text_disabled = color.new(130, 120, 110, 255),
        tab_text_active = color.new(30, 25, 20, 255),
        slider_fill = color.new(220, 175, 125, 220),
        slider_bg = color.new(40, 35, 30, 200),
        checkbox_active = color.new(220, 175, 125, 255),
        checkbox_inactive = color.new(75, 70, 65, 200),
        checkbox_border = color.new(180, 140, 95, 200),
        keybind_bg = color.new(35, 30, 25, 220),
        keybind_border = color.new(180, 140, 95, 180),
        keybind_active = color.new(200, 120, 60, 255),
        keybind_inactive = color.new(60, 55, 50, 200),
        separator = color.new(180, 140, 95, 200)
    },
    -- Paladin - Pink/Rose (Class color: #F58CBA)
    paladin = {
        background = color.new(25, 15, 20, 220),
        border = color.new(245, 140, 186, 255),
        section_bg = color.new(35, 22, 28, 180),
        section_border = color.new(220, 120, 165, 200),
        primary_accent = color.new(255, 150, 200, 255),
        secondary_accent = color.new(255, 215, 100, 255),
        text_primary = color.new(255, 245, 250, 255),
        text_secondary = color.new(240, 220, 230, 255),
        text_disabled = color.new(130, 110, 120, 255),
        tab_text_active = color.new(35, 22, 28, 255),
        slider_fill = color.new(255, 150, 200, 220),
        slider_bg = color.new(45, 35, 40, 200),
        checkbox_active = color.new(255, 150, 200, 255),
        checkbox_inactive = color.new(80, 70, 75, 200),
        checkbox_border = color.new(220, 120, 165, 200),
        keybind_bg = color.new(40, 30, 35, 220),
        keybind_border = color.new(220, 120, 165, 180),
        keybind_active = color.new(255, 215, 100, 255),
        keybind_inactive = color.new(65, 55, 60, 200),
        separator = color.new(220, 120, 165, 200)
    },
    -- Hunter - Green (Class color: #ABD473)
    hunter = {
        background = color.new(20, 24, 18, 220),
        border = color.new(171, 212, 115, 255),
        section_bg = color.new(28, 32, 25, 180),
        section_border = color.new(150, 190, 100, 200),
        primary_accent = color.new(180, 225, 125, 255),
        secondary_accent = color.new(220, 180, 80, 255),
        text_primary = color.new(245, 250, 240, 255),
        text_secondary = color.new(220, 230, 210, 255),
        text_disabled = color.new(120, 130, 115, 255),
        tab_text_active = color.new(28, 32, 25, 255),
        slider_fill = color.new(180, 225, 125, 220),
        slider_bg = color.new(38, 44, 35, 200),
        checkbox_active = color.new(180, 225, 125, 255),
        checkbox_inactive = color.new(75, 82, 70, 200),
        checkbox_border = color.new(150, 190, 100, 200),
        keybind_bg = color.new(33, 39, 30, 220),
        keybind_border = color.new(150, 190, 100, 180),
        keybind_active = color.new(220, 180, 80, 255),
        keybind_inactive = color.new(58, 64, 55, 200),
        separator = color.new(150, 190, 100, 200)
    },
    -- Rogue - Yellow (Class color: #FFF569)
    rogue = {
        background = color.new(22, 22, 15, 220),
        border = color.new(255, 245, 105, 255),
        section_bg = color.new(30, 30, 20, 180),
        section_border = color.new(230, 220, 90, 200),
        primary_accent = color.new(255, 250, 120, 255),
        secondary_accent = color.new(255, 180, 60, 255),
        text_primary = color.new(255, 255, 240, 255),
        text_secondary = color.new(240, 240, 210, 255),
        text_disabled = color.new(130, 130, 110, 255),
        tab_text_active = color.new(30, 30, 20, 255),
        slider_fill = color.new(255, 250, 120, 220),
        slider_bg = color.new(40, 40, 30, 200),
        checkbox_active = color.new(255, 250, 120, 255),
        checkbox_inactive = color.new(80, 80, 65, 200),
        checkbox_border = color.new(230, 220, 90, 200),
        keybind_bg = color.new(35, 35, 25, 220),
        keybind_border = color.new(230, 220, 90, 180),
        keybind_active = color.new(255, 180, 60, 255),
        keybind_inactive = color.new(60, 60, 50, 200),
        separator = color.new(230, 220, 90, 200)
    },
    -- Priest - White/Silver (Class color: #FFFFFF)
    priest = {
        background = color.new(18, 18, 20, 220),
        border = color.new(240, 240, 255, 255),
        section_bg = color.new(25, 25, 28, 180),
        section_border = color.new(210, 210, 230, 200),
        primary_accent = color.new(250, 250, 255, 255),
        secondary_accent = color.new(180, 200, 255, 255),
        text_primary = color.new(255, 255, 255, 255),
        text_secondary = color.new(230, 230, 245, 255),
        text_disabled = color.new(120, 120, 130, 255),
        tab_text_active = color.new(25, 25, 28, 255),
        slider_fill = color.new(250, 250, 255, 220),
        slider_bg = color.new(35, 35, 40, 200),
        checkbox_active = color.new(250, 250, 255, 255),
        checkbox_inactive = color.new(75, 75, 85, 200),
        checkbox_border = color.new(210, 210, 230, 200),
        keybind_bg = color.new(30, 30, 35, 220),
        keybind_border = color.new(210, 210, 230, 180),
        keybind_active = color.new(180, 200, 255, 255),
        keybind_inactive = color.new(55, 55, 65, 200),
        separator = color.new(210, 210, 230, 200)
    },
    -- Shaman - Blue (Class color: #0070DE)
    shaman = {
        background = color.new(12, 18, 25, 220),
        border = color.new(0, 112, 222, 255),
        section_bg = color.new(18, 25, 35, 180),
        section_border = color.new(0, 100, 200, 200),
        primary_accent = color.new(20, 130, 240, 255),
        secondary_accent = color.new(100, 180, 255, 255),
        text_primary = color.new(240, 250, 255, 255),
        text_secondary = color.new(210, 230, 245, 255),
        text_disabled = color.new(100, 120, 135, 255),
        slider_fill = color.new(20, 130, 240, 220),
        slider_bg = color.new(28, 38, 50, 200),
        checkbox_active = color.new(20, 130, 240, 255),
        checkbox_inactive = color.new(60, 75, 90, 200),
        checkbox_border = color.new(0, 100, 200, 200),
        keybind_bg = color.new(23, 33, 45, 220),
        keybind_border = color.new(0, 100, 200, 180),
        keybind_active = color.new(100, 180, 255, 255),
        keybind_inactive = color.new(45, 60, 75, 200),
        separator = color.new(0, 100, 200, 200)
    },
    -- Mage - Cyan/Aqua (Class color: #69CCF0)
    mage = {
        background = color.new(12, 20, 25, 220),
        border = color.new(105, 204, 240, 255),
        section_bg = color.new(18, 28, 35, 180),
        section_border = color.new(90, 185, 220, 200),
        primary_accent = color.new(120, 215, 250, 255),
        secondary_accent = color.new(180, 140, 255, 255),
        text_primary = color.new(240, 252, 255, 255),
        text_secondary = color.new(210, 240, 250, 255),
        text_disabled = color.new(100, 130, 140, 255),
        tab_text_active = color.new(18, 28, 35, 255),
        slider_fill = color.new(120, 215, 250, 220),
        slider_bg = color.new(28, 40, 48, 200),
        checkbox_active = color.new(120, 215, 250, 255),
        checkbox_inactive = color.new(60, 80, 90, 200),
        checkbox_border = color.new(90, 185, 220, 200),
        keybind_bg = color.new(23, 35, 43, 220),
        keybind_border = color.new(90, 185, 220, 180),
        keybind_active = color.new(180, 140, 255, 255),
        keybind_inactive = color.new(45, 65, 75, 200),
        separator = color.new(90, 185, 220, 200)
    },
    -- Warlock - Purple (Class color: #9482C9)
    warlock = {
        background = color.new(18, 15, 25, 220),
        border = color.new(148, 130, 201, 255),
        section_bg = color.new(25, 20, 35, 180),
        section_border = color.new(130, 115, 180, 200),
        primary_accent = color.new(160, 140, 220, 255),
        secondary_accent = color.new(200, 100, 180, 255),
        text_primary = color.new(245, 240, 255, 255),
        text_secondary = color.new(220, 210, 240, 255),
        text_disabled = color.new(120, 110, 135, 255),
        slider_fill = color.new(160, 140, 220, 220),
        slider_bg = color.new(35, 30, 48, 200),
        checkbox_active = color.new(160, 140, 220, 255),
        checkbox_inactive = color.new(70, 65, 85, 200),
        checkbox_border = color.new(130, 115, 180, 200),
        keybind_bg = color.new(30, 25, 43, 220),
        keybind_border = color.new(130, 115, 180, 180),
        keybind_active = color.new(200, 100, 180, 255),
        keybind_inactive = color.new(55, 50, 70, 200),
        separator = color.new(130, 115, 180, 200)
    },
    -- Druid - Orange (Class color: #FF7D0A)
    druid = {
        background = color.new(25, 18, 12, 220),
        border = color.new(255, 125, 10, 255),
        section_bg = color.new(35, 25, 18, 180),
        section_border = color.new(230, 110, 10, 200),
        primary_accent = color.new(255, 140, 30, 255),
        secondary_accent = color.new(180, 220, 80, 255),
        text_primary = color.new(255, 245, 235, 255),
        text_secondary = color.new(240, 220, 200, 255),
        text_disabled = color.new(130, 115, 100, 255),
        tab_text_active = color.new(35, 25, 18, 255),
        slider_fill = color.new(255, 140, 30, 220),
        slider_bg = color.new(45, 35, 28, 200),
        checkbox_active = color.new(255, 140, 30, 255),
        checkbox_inactive = color.new(80, 70, 60, 200),
        checkbox_border = color.new(230, 110, 10, 200),
        keybind_bg = color.new(40, 30, 23, 220),
        keybind_border = color.new(230, 110, 10, 180),
        keybind_active = color.new(180, 220, 80, 255),
        keybind_inactive = color.new(65, 55, 48, 200),
        separator = color.new(230, 110, 10, 200)
    }
}

-- ============================================================================
-- KEY NAME MAPPING
-- ============================================================================

local KEY_NAMES = {
    -- Windows virtual-key codes
    [1] = "LMB",
    [2] = "RMB",
    [4] = "MMB",
    [5] = "Mouse4",
    [6] = "Mouse5",
    [16] = "Shift",
    [17] = "Ctrl",
    [18] = "Alt",
    [160] = "L-Shift",
    [161] = "R-Shift",
    [162] = "L-Ctrl",
    [163] = "R-Ctrl",
    [164] = "L-Alt",
    [165] = "R-Alt",
    [112] = "F1",
    [113] = "F2",
    [114] = "F3",
    [115] = "F4",
    [116] = "F5",
    [117] = "F6",
    [118] = "F7",
    [119] = "F8",
    [120] = "F9",
    [121] = "F10",
    [122] = "F11",
    [123] = "F12",
    [999] = "None"
}

-- ============================================================================
-- WIDGET CLASS
-- ============================================================================

---@class rotation_settings_ui
---@field id string
---@field title string
---@field window any
---@field sections table[]
---@field theme_name string
---@field colors table
---@field menu table
---@field _pos_x any
---@field _pos_y any
---@field _size_x any
---@field _size_y any
---@field _window_epoch integer
---@field _window_id string
local RotationSettingsUI = {}
RotationSettingsUI.__index = RotationSettingsUI

RotationSettingsUI._extension_tabs = {}
RotationSettingsUI._extension_epoch = 0

-- Forward declaration: used by build_tab_section before TabBuilder is defined below.
local TabBuilder

local function build_tab_section(tab_info, build_fn, ui)
    if not tab_info or not tab_info.id or not tab_info.label then
        return nil
    end
    local section = {
        id = tab_info.id,
        label = tab_info.label,
        type = "tab",
        groups = {},
        visible_when = tab_info.visible_when
    }
    if build_fn and type(build_fn) == "function" then
        local builder = TabBuilder.new(ui, section)
        pcall(build_fn, builder)
    end
    section.__is_extension_tab = tab_info.__is_extension_tab == true
    return section
end

local function safe_window_mouse_check(window, method_name, button)
    if not window then
        return false
    end
    local method = window[method_name]
    if type(method) ~= "function" then
        return false
    end
    local ok, result = pcall(method, window, button)
    return ok and result
end

local function is_mouse_pressed_left(window)
    if safe_window_mouse_check(window, "is_mouse_button_pressed", 0) or safe_window_mouse_check(window, "is_mouse_button_pressed", 1) then
        return true
    end
    return core.input.is_key_pressed(1) or core.input.is_key_pressed(2)
end

local function is_mouse_clicked_left(window)
    return safe_window_mouse_check(window, "is_mouse_button_clicked", 0) or safe_window_mouse_check(window, "is_mouse_button_clicked", 1)
end

function RotationSettingsUI:_get_window_local_mouse_pos(space_hint)
    if not self.window then
        return nil
    end

    local ok_mouse, mouse_pos = pcall(function()
        return self.window:get_mouse_pos()
    end)
    if not ok_mouse or not mouse_pos then
        return nil
    end

    local ok_pos, window_pos = pcall(function()
        return self.window:get_position()
    end)

    local adjusted = nil
    if ok_pos and window_pos then
        adjusted = vec2.new(mouse_pos.x - window_pos.x, mouse_pos.y - window_pos.y)
    end

    if space_hint == "raw" then
        return mouse_pos, "raw"
    end
    if space_hint == "adjusted" and adjusted then
        return adjusted, "adjusted"
    end

    local ok_size, window_size = pcall(function()
        return self.window:get_size()
    end)

    local function is_inside_window(pos)
        if not ok_size or not window_size then
            return true
        end
        return pos.x >= 0 and pos.y >= 0 and pos.x <= window_size.x and pos.y <= window_size.y
    end

    local last = self._active_slider and self._active_slider.last_mouse_pos
    local best = nil
    local best_score = nil
    local best_space = nil

    local candidates = {
        { pos = mouse_pos, space = "raw" }
    }
    if adjusted then
        table.insert(candidates, { pos = adjusted, space = "adjusted" })
    end

    for _, candidate in ipairs(candidates) do
        local pos = candidate.pos
        local inside = is_inside_window(pos) and 0 or 1000000
        local delta = 0
        if last then
            local dx = pos.x - last.x
            local dy = pos.y - last.y
            delta = (dx * dx) + (dy * dy)
        end

        local score = inside + delta
        if best_score == nil or score < best_score then
            best_score = score
            best = pos
            best_space = candidate.space
        end
    end

    return best, best_space
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

---Creates a new rotation settings UI instance
---@param config table Configuration table {id, title, default_x, default_y, default_w, default_h, theme}
---@return rotation_settings_ui
function RotationSettingsUI.new(config)
    local self = setmetatable({}, RotationSettingsUI)

    self.id = config.id or "rotation_ui"
    self.title = config.title or "Rotation Settings"
    self.theme_name = config.theme or "astro"
    self.colors = THEMES[self.theme_name] or THEMES.astro
    self.sections = {}
    self._window_epoch = 0

    -- Tab state
    self.active_tab_index = 1

    -- Menu elements for persistence and control
    local default_theme_index = THEME_INDEX[self.theme_name] or 1
    self.menu = {
        enable = menu_checkbox(false, "rotation_ui_enable_" .. self.id),
        theme_selector = menu_combobox(default_theme_index, "rotation_ui_theme_" .. self.id),
        pos_x = menu_slider_int(0, 10000, config.default_x or 700, "rotation_ui_x_" .. self.id),
        pos_y = menu_slider_int(0, 10000, config.default_y or 200, "rotation_ui_y_" .. self.id),
        size_x = menu_slider_int(0, 10000, config.default_w or 450, "rotation_ui_w_" .. self.id),
        size_y = menu_slider_int(0, 10000, config.default_h or 600, "rotation_ui_h_" .. self.id),
        active_tab = menu_slider_int(0, 100, 1, "rotation_ui_tab_" .. self.id)
    }

    self._pos_x = self.menu.pos_x
    self._pos_y = self.menu.pos_y
    self._size_x = self.menu.size_x
    self._size_y = self.menu.size_y

    self._active_slider = nil
    self._active_key_capture = nil
    self._extension_epoch = RotationSettingsUI._extension_epoch - 1
    self._window_close_requested = false
    self._tab_scroll_offsets = {}
    self._scrollbar_drag = nil
    self._scroll_viewport = nil
    self._side_menu_active_pages = {}
    self._content_x_start = LAYOUT.padding_side
    self._side_menu_reserved_left = 0

    return self
end

-- ============================================================================
-- THEME UPDATE
-- ============================================================================

---Updates the theme based on the theme selector
function RotationSettingsUI:_update_theme()
    if not self.menu.theme_selector then
        return
    end

    local ok, theme_index = pcall(function()
        return self.menu.theme_selector:get()
    end)

    if ok and theme_index and THEME_NAMES[theme_index] then
        local new_theme_name = THEME_NAMES[theme_index]
        if new_theme_name ~= self.theme_name then
            self.theme_name = new_theme_name
            self.colors = THEMES[new_theme_name] or THEMES.astro
        end
    end
end

-- ============================================================================
-- SECTION REGISTRATION
-- ============================================================================

---Registers a section to be displayed in the UI
---@param section table Section configuration {id, label, type, elements, labels, columns, visible_when}
function RotationSettingsUI:register_section(section)
    if not section or not section.id or not section.type then
        return
    end

    table.insert(self.sections, section)
end

function RotationSettingsUI:_sync_extension_tabs()
    for i = #self.sections, 1, -1 do
        if self.sections[i] and self.sections[i].__is_extension_tab == true then
            table.remove(self.sections, i)
        end
    end

    for _, entry in ipairs(RotationSettingsUI._extension_tabs) do
        local tab_info = entry.tab
        local tab_copy = {
            id = tab_info.id,
            label = tab_info.label,
            visible_when = tab_info.visible_when,
            __is_extension_tab = true
        }
        local section = build_tab_section(tab_copy, entry.build_fn, self)
        if section then
            table.insert(self.sections, section)
        end
    end

    self._extension_epoch = RotationSettingsUI._extension_epoch
end

function RotationSettingsUI:_ensure_extension_tabs()
    if self._extension_epoch ~= RotationSettingsUI._extension_epoch then
        self:_sync_extension_tabs()
    end
end

-- ============================================================================
-- BUILDER API (Reusable UI Library Layer)
-- ============================================================================

---@class rotation_settings_ui_tab_builder
---@field _ui rotation_settings_ui
---@field _section table
TabBuilder = {}
TabBuilder.__index = TabBuilder

---@param ui rotation_settings_ui
---@param section table
---@return rotation_settings_ui_tab_builder
function TabBuilder.new(ui, section)
    return setmetatable({ _ui = ui, _section = section }, TabBuilder)
end

function TabBuilder:_add_group(group)
    if not group or not group.type then
        return self
    end
    self._section.groups = self._section.groups or {}
    table.insert(self._section.groups, group)
    return self
end

---@param opts table {label?, columns?, elements, visible_when?}
function TabBuilder:checkbox_grid(opts)
    return self:_add_group({
        type = "checkbox_grid",
        label = opts and opts.label or nil,
        columns = opts and opts.columns or nil,
        elements = opts and opts.elements or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label?, elements, visible_when?}
function TabBuilder:slider_list(opts)
    return self:_add_group({
        type = "slider_list",
        label = opts and opts.label or nil,
        elements = opts and opts.elements or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label?, elements, visible_when?}
function TabBuilder:combo_list(opts)
    return self:_add_group({
        type = "combo_list",
        label = opts and opts.label or nil,
        elements = opts and opts.elements or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {elements, labels?, visible_when?}
function TabBuilder:keybind_grid(opts)
    return self:_add_group({
        type = "keybind_grid",
        elements = opts and opts.elements or nil,
        labels = opts and opts.labels or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label?, text, visible_when?}
function TabBuilder:text(opts)
    return self:_add_group({
        type = "text",
        label = opts and opts.label or nil,
        text = opts and opts.text or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label, on_click, visible_when?}
function TabBuilder:button(opts)
    return self:_add_group({
        type = "button",
        label = opts and opts.label or nil,
        on_click = opts and opts.on_click or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label?, elements, visible_when?}
function TabBuilder:text_input_list(opts)
    return self:_add_group({
        type = "text_input_list",
        label = opts and opts.label or nil,
        elements = opts and opts.elements or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param opts table {label?, elements, visible_when?}
function TabBuilder:runtime_checkbox_list(opts)
    return self:_add_group({
        type = "runtime_checkbox_list",
        label = opts and opts.label or nil,
        elements = opts and opts.elements or nil,
        visible_when = opts and opts.visible_when or nil,
        page = opts and (opts.page or opts.subpage) or nil
    })
end

---@param page string?
function TabBuilder:separator(page)
    return self:_add_group({
        type = "separator",
        page = page
    })
end

---@param opts table { items: table[], width?: number, label?: string }
function TabBuilder:side_menu(opts)
    if not opts or type(opts) ~= "table" then
        return self
    end
    self._section.side_menu = {
        items = opts.items or {},
        width = opts.width,
        label = opts.label
    }
    return self
end

---@param tab table {id, label, visible_when?}
---@param build_fn fun(t:rotation_settings_ui_tab_builder)
function RotationSettingsUI:add_tab(tab, build_fn)
    if not tab or not tab.id or not tab.label then
        return
    end
    local section = {
        id = tab.id,
        label = tab.label,
        type = "tab",
        groups = {},
        visible_when = tab.visible_when
    }
    if build_fn and type(build_fn) == "function" then
        local builder = TabBuilder.new(self, section)
        pcall(build_fn, builder)
    end
    self:register_section(section)
end

function RotationSettingsUI._find_extension_index(id)
    for index, entry in ipairs(RotationSettingsUI._extension_tabs) do
        if entry.tab.id == id then
            return index
        end
    end
    return nil
end

function RotationSettingsUI.register_extension_tab(tab, build_fn)
    if not tab or not tab.id or not tab.label then
        return nil
    end
    local idx = RotationSettingsUI._find_extension_index(tab.id)
    if idx then
        RotationSettingsUI._extension_tabs[idx] = { tab = tab, build_fn = build_fn }
    else
        table.insert(RotationSettingsUI._extension_tabs, { tab = tab, build_fn = build_fn })
    end
    RotationSettingsUI._extension_epoch = RotationSettingsUI._extension_epoch + 1
    return function()
        RotationSettingsUI.unregister_extension_tab(tab.id)
    end
end

function RotationSettingsUI.unregister_extension_tab(tab_id)
    local idx = RotationSettingsUI._find_extension_index(tab_id)
    if not idx then
        return false
    end
    table.remove(RotationSettingsUI._extension_tabs, idx)
    RotationSettingsUI._extension_epoch = RotationSettingsUI._extension_epoch + 1
    return true
end

-- Example:
-- ui:add_tab({ id = "core", label = "Core" }, function(t)
--     t:keybind_grid({ elements = { menu.enable_toggle }, labels = { "Enable" } })
--     t:checkbox_grid({ label = "Toggles", columns = 2, elements = { { element = menu.auto_feint_enabled, label = "Auto Feint" } } })
--     t:slider_list({ label = "Thresholds", elements = { { element = menu.auto_pot_threshold, label = "Potion HP%", suffix = "%" } } })
-- end)

-- Convenience: bulk replace existing tabs (useful when rebuilding a UI dynamically)
---@param tabs table[]
function RotationSettingsUI:set_tabs(tabs)
    self.sections = {}
    if not tabs then
        return
    end
    for _, tab in ipairs(tabs) do
        if tab then
            self:register_section(tab)
        end
    end
end

-- Export builder for advanced external usage/debugging.
RotationSettingsUI.TabBuilder = TabBuilder

-- ============================================================================
-- WINDOW MANAGEMENT
-- ============================================================================

function RotationSettingsUI:_build_window()
    self._window_epoch = (self._window_epoch or 0) + 1
    self._window_id = string.format("%s##%d", self.title, self._window_epoch)
    self.window = core.menu.window(self._window_id)

    if self._pos_x and self._pos_y then
        self.window:set_initial_position(vec2.new(self._pos_x:get(), self._pos_y:get()))
    end
    if self._size_x and self._size_y then
        self.window:set_initial_size(vec2.new(self._size_x:get(), self._size_y:get()))
    end
end

function RotationSettingsUI:_sync_window_state()
    if not self.window then
        return
    end

    local ok_pos, pos = pcall(function()
        return self.window:get_position()
    end)
    if ok_pos and pos and self._pos_x and self._pos_y then
        local x = math.floor(pos.x + 0.5)
        local y = math.floor(pos.y + 0.5)
        if x ~= self._pos_x:get() then
            self._pos_x:set(x)
        end
        if y ~= self._pos_y:get() then
            self._pos_y:set(y)
        end
    end

    local ok_size, size = pcall(function()
        return self.window:get_size()
    end)
    if ok_size and size and self._size_x and self._size_y then
        local sx = math.floor(size.x + 0.5)
        local sy = math.floor(size.y + 0.5)
        if sx ~= self._size_x:get() then
            self._size_x:set(sx)
        end
        if sy ~= self._size_y:get() then
            self._size_y:set(sy)
        end
    end
end

function RotationSettingsUI:_is_enabled()
    if self.menu and self.menu.enable then
        return self.menu.enable:get_state()
    end
    return false
end

-- ============================================================================
-- KEY NAME HELPER
-- ============================================================================

function RotationSettingsUI:_get_key_name(key_code)
    if KEY_NAMES[key_code] then
        return KEY_NAMES[key_code]
    end

    if key_code >= 48 and key_code <= 57 then
        return string.char(key_code)
    end

    if key_code >= 65 and key_code <= 90 then
        return string.char(key_code)
    end

    return "Key" .. key_code
end

-- ============================================================================
-- SECTION VISIBILITY
-- ============================================================================

function RotationSettingsUI:_is_section_visible(section)
    if section.visible_when and type(section.visible_when) == "function" then
        local ok, result = pcall(section.visible_when)
        if ok then
            return result == true
        end
        return false
    end
    return true
end

-- ============================================================================
-- TAB STATE MANAGEMENT
-- ============================================================================

function RotationSettingsUI:_sync_tab_state()
    if self.menu.active_tab then
        local saved_tab = self.menu.active_tab:get()
        if saved_tab >= 1 and saved_tab <= #self.sections then
            self.active_tab_index = saved_tab
        end
    end
end

-- ============================================================================
-- TAB BAR RENDERING
-- ============================================================================

function RotationSettingsUI:_render_tab_bar()
    local window_size = self.window:get_size()
    local content_width = window_size.x - (2 * LAYOUT.padding_side) - LAYOUT.tab_bar_right_reserved
    local x_start = LAYOUT.padding_side
    local y_start = LAYOUT.padding_top

    local visible_indices = {}
    for i, section in ipairs(self.sections) do
        if self:_is_section_visible(section) then
            table.insert(visible_indices, i)
        end
    end

    local visible_count = #visible_indices
    if visible_count == 0 then
        return y_start
    end

    local spacing = LAYOUT.tab_button_spacing

    -- Wrap tabs across multiple rows when the window is too narrow.
    local tabs_per_row = math.max(1, math.floor((content_width + spacing) / (LAYOUT.tab_button_min_width + spacing)))
    tabs_per_row = math.min(tabs_per_row, visible_count)

    local tab_width = math.floor((content_width - (tabs_per_row - 1) * spacing) / tabs_per_row)
    tab_width = math.min(LAYOUT.tab_button_max_width, math.max(LAYOUT.tab_button_min_width, tab_width))

    local current_x = x_start
    local current_y = y_start
    local col = 0

    for _, i in ipairs(visible_indices) do
        local section = self.sections[i]
        if section then
            if col >= tabs_per_row then
                col = 0
                current_x = x_start
                current_y = current_y + LAYOUT.tab_button_height + spacing
            end

            local is_active = (i == self.active_tab_index)

            -- Tab button bounds
            local tab_start = vec2.new(current_x, current_y)
            local tab_end = vec2.new(current_x + tab_width, current_y + LAYOUT.tab_button_height)

            -- Check hover state
            local is_hovered = self.window:is_mouse_hovering_rect(tab_start, tab_end)
            self.window:is_mouse_hovering_rect_block_movement(tab_start, tab_end)

            -- Determine colors based on state
            local bg_color, text_color, border_color
            if is_active then
                bg_color = self.colors.primary_accent
                text_color = self.colors.tab_text_active or color.white(255)
                border_color = self.colors.primary_accent
            elseif is_hovered then
                bg_color = lighten_color(self.colors.section_bg, 20)
                text_color = self.colors.text_primary
                border_color = self.colors.section_border
            else
                bg_color = self.colors.section_bg
                text_color = self.colors.text_secondary
                border_color = self.colors.section_border
            end

            -- Render tab button background
            self.window:render_rect_filled(tab_start, tab_end, bg_color, 2.0)

            -- Render borders (all sides for now, active tab will be merged later)
            self.window:render_rect(tab_start, tab_end, border_color, 2.0, 1.0)

            -- Render tab label (centered, truncated if needed)
            local label = section.label or ("Tab " .. i)
            local text_size = self.window:get_text_size(label)

            -- Truncate label if too long
            local max_text_width = tab_width - 10
            if text_size.x > max_text_width then
                local truncated_label = label
                while #truncated_label > 0 do
                    local test_label = truncated_label .. "..."
                    local test_size = self.window:get_text_size(test_label)
                    if test_size.x <= max_text_width then
                        label = test_label
                        text_size = test_size
                        break
                    end
                    truncated_label = string.sub(truncated_label, 1, -2)
                end
            end

            local text_x = current_x + (tab_width - text_size.x) / 2
            local text_y = current_y + (LAYOUT.tab_button_height - text_size.y) / 2
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL,
                vec2.new(text_x, text_y), text_color, label)

            -- Handle click
            if self.window:is_rect_clicked(tab_start, tab_end) then
                self.active_tab_index = i
                if self.menu.active_tab then
                    self.menu.active_tab:set(i)
                end
            end

            current_x = current_x + tab_width + spacing
            col = col + 1
        end
    end

    return current_y + LAYOUT.tab_button_height + LAYOUT.tab_bar_padding_top
end

-- ============================================================================
-- ACTIVE TAB CONTENT RENDERING
-- ============================================================================

function RotationSettingsUI:_render_active_tab_content(y_offset)
    if self.active_tab_index < 1 or self.active_tab_index > #self.sections then
        return y_offset
    end

    local section = self.sections[self.active_tab_index]
    if not section or not self:_is_section_visible(section) then
        return y_offset
    end

    -- Render section content (NO header, just content)
    if section.type == "keybind_grid" then
        return self:_render_keybind_grid(section, y_offset)
    elseif section.type == "checkbox_grid" then
        return self:_render_checkbox_grid(section, y_offset)
    elseif section.type == "slider_list" then
        return self:_render_slider_list(section, y_offset)
    elseif section.type == "combo_list" then
        return self:_render_combo_list(section, y_offset)
    elseif section.type == "tab" then
        return self:_render_tab_groups(section, y_offset)
    end

    return y_offset
end

-- ============================================================================
-- SECTION HEADER RENDERING (DEPRECATED - replaced by tabs)
-- ============================================================================

function RotationSettingsUI:_render_section_header(section, y_offset)
    if not section.label then
        return
    end

    local window_size = self.window:get_size()
    local x_start = LAYOUT.padding_side
    local x_end = window_size.x - LAYOUT.padding_side

    -- Section background
    local section_bg_start = vec2.new(x_start, y_offset)
    local section_bg_end = vec2.new(x_end, y_offset + LAYOUT.section_header_height)
    self.window:render_rect_filled(section_bg_start, section_bg_end, self.colors.section_bg, 2.0)
    self.window:render_rect(section_bg_start, section_bg_end, self.colors.section_border, 2.0, 1.0)

    -- Section label (centered)
    local text_size = self.window:get_text_size(section.label)
    local text_x = x_start + ((x_end - x_start) - text_size.x) / 2
    local text_y = y_offset + (LAYOUT.section_header_height - text_size.y) / 2
    self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(text_x, text_y),
        self.colors.secondary_accent, section.label)
end

-- ============================================================================
-- KEYBIND GRID RENDERING (Custom + Interactive)
-- ============================================================================

function RotationSettingsUI:_render_keybind_grid(section, y_offset)
    if not section.elements or #section.elements == 0 then
        return y_offset
    end

    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    for i, element in ipairs(section.elements) do
        if element then
            local row_top = y_offset
            local row_bottom = y_offset + LAYOUT.element_height
            local label = (section.labels and section.labels[i]) or ("Keybind " .. i)

            local ok_key, key_code = pcall(function()
                return element:get_key_code()
            end)
            if not ok_key then
                key_code = 999
            end

            local ok_state, is_enabled = pcall(function()
                if element.get_toggle_state then
                    return element:get_toggle_state()
                end
                if element.get_state then
                    return element:get_state()
                end
                return false
            end)
            if not ok_state or is_enabled == nil then
                is_enabled = false
            end

            local key_name = self:_get_key_name(key_code)

            -- Define rectangles
            local key_box_start = vec2.new(x_start, y_offset)
            local key_box_end = vec2.new(x_start + LAYOUT.keybind_badge_width, y_offset + LAYOUT.element_height - 2)

            local clear_action_width = LAYOUT.keybind_clear_width
            local clear_box_end = vec2.new(x_start + content_width, y_offset + LAYOUT.element_height - 2)
            local clear_box_start = vec2.new(clear_box_end.x - clear_action_width, y_offset)
            local status_box_end = vec2.new(clear_box_start.x, y_offset + LAYOUT.element_height - 2)
            local status_box_start = vec2.new(status_box_end.x - LAYOUT.keybind_status_width, y_offset)

            -- Hover states for visual feedback
            local is_key_hovered = self.window:is_mouse_hovering_rect(key_box_start, key_box_end)
            local is_status_hovered = self.window:is_mouse_hovering_rect(status_box_start, status_box_end)
            local is_clear_hovered = self.window:is_mouse_hovering_rect(clear_box_start, clear_box_end)

            -- Prevent window dragging while interacting with this row
            if self:_is_y_visible(row_top, row_bottom) then
                self.window:is_mouse_hovering_rect_block_movement(key_box_start, key_box_end)
                self.window:is_mouse_hovering_rect_block_movement(status_box_start, status_box_end)
                self.window:is_mouse_hovering_rect_block_movement(clear_box_start, clear_box_end)
            end

            -- Custom Rendering - Key badge (left)
            local is_capturing_keybind = self._active_key_capture and self._active_key_capture.element == element

            if self:_is_y_visible(row_top, row_bottom) then
                local key_bg_color = is_key_hovered and lighten_color(self.colors.keybind_bg, 30) or self.colors.keybind_bg
                if is_capturing_keybind then
                    key_bg_color = self.colors.keybind_active
                end
                self.window:render_rect_filled(key_box_start, key_box_end, key_bg_color, 2.0)
                self.window:render_rect(key_box_start, key_box_end, self.colors.keybind_border, 2.0, 1.0)

                local key_text_size = self.window:get_text_size(key_name)
                local key_text_x = x_start + (LAYOUT.keybind_badge_width - key_text_size.x) / 2
                local key_text_y = y_offset + (LAYOUT.element_height - 2 - key_text_size.y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(key_text_x, key_text_y),
                    self.colors.text_primary, key_name)

                if self.window:is_rect_clicked(key_box_start, key_box_end) then
                    self:_start_key_capture(element, label)
                end

                -- Label (middle)
                local label_x = x_start + LAYOUT.keybind_badge_width + 12
                local label_y = y_offset + (LAYOUT.element_height - 2 - self.window:get_text_size(label).y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(label_x, label_y),
                    self.colors.text_primary, label)

                -- Status badge (right)
                local status_text = is_enabled and "ON" or "OFF"
                local status_color = is_enabled and self.colors.keybind_active or self.colors.keybind_inactive
                local status_hover_color = is_status_hovered and lighten_color(status_color, 30) or status_color
                self.window:render_rect_filled(status_box_start, status_box_end, status_hover_color, 2.0)

                local status_text_size = self.window:get_text_size(status_text)
                local status_text_x = status_box_start.x + (LAYOUT.keybind_status_width - status_text_size.x) / 2
                local status_text_y = y_offset + (LAYOUT.element_height - 2 - status_text_size.y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(status_text_x, status_text_y),
                    color.white(255), status_text)

                -- Clear badge
                local clear_bg = is_clear_hovered and lighten_color(self.colors.slider_bg, 20) or self.colors.slider_bg
                self.window:render_rect_filled(clear_box_start, clear_box_end, clear_bg, 1.5)
                self.window:render_rect(clear_box_start, clear_box_end, self.colors.section_border, 1.5, 1.0)
                local clear_text = "Clear"
                local clear_text_size = self.window:get_text_size(clear_text)
                local clear_text_x = clear_box_start.x + (LAYOUT.keybind_clear_width - clear_text_size.x) / 2
                local clear_text_y = y_offset + (LAYOUT.element_height - 2 - clear_text_size.y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(clear_text_x, clear_text_y),
                    self.colors.text_secondary, clear_text)
                if self.window:is_rect_clicked(clear_box_start, clear_box_end) then
                    pcall(function()
                        if element.set_key then
                            element:set_key(999)
                        end
                    end)
                end

                -- INPUT HANDLING
                -- Click on Status Badge → Toggle Enable State
                if self.window:is_rect_clicked(status_box_start, status_box_end) then
                    pcall(function()
                        if element.set_toggle_state then
                            element:set_toggle_state(not is_enabled)
                        elseif element.set_state then
                            element:set_state(not is_enabled)
                        end
                    end)
                end
            end

            y_offset = y_offset + LAYOUT.element_height + LAYOUT.element_spacing
        end
    end

    return y_offset + LAYOUT.section_padding_bottom
end

-- ============================================================================
-- CHECKBOX GRID RENDERING (Custom + Interactive)
-- ============================================================================

function RotationSettingsUI:_render_checkbox_grid(section, y_offset)
    if not section.elements or #section.elements == 0 then
        return y_offset
    end

    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    local columns = section.columns or 2
    local column_width = (content_width - ((columns - 1) * LAYOUT.column_spacing)) / columns

    y_offset = y_offset + LAYOUT.section_padding_top

    local row = 0
    local col = 0

    for i, item in ipairs(section.elements) do
        if item and item.element and self:_is_entry_visible(item) then
            local element = item.element
            local label = item.label or ("Option " .. i)

            local ok_state, is_checked = pcall(function()
                return element:get_state()
            end)
            if not ok_state then
                is_checked = false
            end

            local x_pos = x_start + (col * (column_width + LAYOUT.column_spacing))

            -- Checkbox rectangle
            local checkbox_start = vec2.new(x_pos, y_offset)
            local checkbox_end = vec2.new(x_pos + LAYOUT.checkbox_size, y_offset + LAYOUT.checkbox_size)
            local row_top = y_offset
            local row_bottom = y_offset + LAYOUT.element_height

            if self:_is_y_visible(row_top, row_bottom) then
                -- Hover state
                local is_hovered = self.window:is_mouse_hovering_rect(checkbox_start, checkbox_end)

                -- Custom Rendering
                local checkbox_color = is_checked and self.colors.checkbox_active or self.colors.checkbox_inactive
                if is_hovered then
                    checkbox_color = lighten_color(checkbox_color, 30)
                end

                self.window:render_rect_filled(checkbox_start, checkbox_end, checkbox_color, 1.0)
                self.window:render_rect(checkbox_start, checkbox_end, self.colors.checkbox_border, 1.0, 1.0)

                -- Checkmark if enabled
                if is_checked then
                    local check_padding = 3
                    local check_start = vec2.new(x_pos + check_padding, y_offset + check_padding)
                    local check_end = vec2.new(x_pos + LAYOUT.checkbox_size - check_padding, y_offset + LAYOUT.checkbox_size - check_padding)
                    self.window:render_rect_filled(check_start, check_end, color.white(255), 0.5)
                end

                -- Label
                local label_x = x_pos + LAYOUT.checkbox_size + 8
                local label_y = y_offset + (LAYOUT.checkbox_size - self.window:get_text_size(label).y) / 2
                local label_color = is_checked and self.colors.text_primary or self.colors.text_secondary
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(label_x, label_y),
                    label_color, label)

                -- INPUT HANDLING
                -- Click → Toggle
                local row_click_start = vec2.new(x_pos, y_offset)
                local row_click_end = vec2.new(x_pos + column_width, y_offset + LAYOUT.checkbox_size)
                self.window:is_mouse_hovering_rect_block_movement(row_click_start, row_click_end)
                if self.window:is_rect_clicked(row_click_start, row_click_end) then
                    pcall(function()
                        if element.set then
                            element:set(not is_checked)
                        elseif element.set_state then
                            element:set_state(not is_checked)
                        end
                    end)
                end
            end

            col = col + 1
            if col >= columns then
                col = 0
                row = row + 1
                y_offset = y_offset + LAYOUT.element_height + LAYOUT.element_spacing
            end
        end
    end

    if col > 0 then
        y_offset = y_offset + LAYOUT.element_height + LAYOUT.element_spacing
    end

    return y_offset + LAYOUT.section_padding_bottom
end

function RotationSettingsUI:_is_entry_visible(entry)
    if not entry or not entry.visible_when then
        return true
    end
    local ok, result = pcall(entry.visible_when)
    if not ok then
        return false
    end
    return result == true
end

function RotationSettingsUI:_get_active_tab_id()
    if self.active_tab_index < 1 or self.active_tab_index > #self.sections then
        return nil
    end
    local section = self.sections[self.active_tab_index]
    return section and section.id or nil
end

function RotationSettingsUI:_get_active_page_id(tab_id)
    if not tab_id then
        return nil
    end
    
    local current = self._side_menu_active_pages[tab_id]
    if current ~= nil then
        return current
    end
    
    -- Default to the first item in the side menu if it exists
    local section = nil
    for _, s in ipairs(self.sections) do
        if s.id == tab_id then
            section = s
            break
        end
    end
    
    if section and section.side_menu and section.side_menu.items and #section.side_menu.items > 0 then
        local first_id = section.side_menu.items[1].id
        if first_id then
            self._side_menu_active_pages[tab_id] = first_id
            return first_id
        end
    end
    
    return nil
end

function RotationSettingsUI:_set_active_page_id(tab_id, page_id)
    if not tab_id then
        return
    end
    self._side_menu_active_pages[tab_id] = page_id
end

function RotationSettingsUI:_get_active_scroll_key()
    local tab_id = self:_get_active_tab_id()
    if not tab_id then
        return nil
    end
    local section = self.sections[self.active_tab_index]
    local page_id = nil
    if section and section.side_menu then
        page_id = self:_get_active_page_id(tab_id)
        if page_id and #tostring(page_id) > 0 then
            return tab_id .. "::" .. tostring(page_id)
        end
    end
    return tab_id
end

function RotationSettingsUI:_get_tab_scroll_offset(tab_id)
    if not tab_id then
        return 0
    end
    return self._tab_scroll_offsets[tab_id] or 0
end

function RotationSettingsUI:_set_tab_scroll_offset(tab_id, value, max_value)
    if not tab_id then
        return
    end

    local clamped = math.max(0, value or 0)
    if max_value ~= nil then
        clamped = math.min(max_value, clamped)
    end

    self._tab_scroll_offsets[tab_id] = clamped
end

function RotationSettingsUI:_is_y_visible(y_top, y_bottom)
    local vp = self._scroll_viewport
    if not vp then
        return true
    end
    return y_bottom >= vp.top and y_top <= vp.bottom
end

function RotationSettingsUI:_render_scrollbar(tab_id, content_height, viewport_top, viewport_bottom)
    if not self.window or not tab_id then
        return
    end

    local viewport_height = viewport_bottom - viewport_top
    if viewport_height <= 0 then
        return
    end

    local max_scroll = math.max(0, (content_height or 0) - viewport_height)
    if max_scroll <= 0 then
        self._scrollbar_drag = nil
        self._scrollbar_reserved_right = 0
        self:_set_tab_scroll_offset(tab_id, 0)
        return
    end

    local window_size = self.window:get_size()
    local scrollbar_width = 10
    self._scrollbar_reserved_right = scrollbar_width + 6
    local x2 = window_size.x - LAYOUT.padding_side
    local x1 = x2 - scrollbar_width

    local track_start = vec2.new(x1, viewport_top)
    local track_end = vec2.new(x2, viewport_bottom)
    self.window:render_rect_filled(track_start, track_end, self.colors.slider_bg, 2.0)
    self.window:render_rect(track_start, track_end, self.colors.section_border, 2.0, 1.0)

    local handle_height = math.max(24, math.floor((viewport_height * viewport_height) / (content_height) + 0.5))
    handle_height = math.min(handle_height, viewport_height)

    local scroll = self:_get_tab_scroll_offset(tab_id)
    scroll = math.max(0, math.min(max_scroll, scroll))
    self:_set_tab_scroll_offset(tab_id, scroll, max_scroll)

    local handle_travel = viewport_height - handle_height
    local handle_y = viewport_top + (scroll / max_scroll) * handle_travel
    local handle_start = vec2.new(x1, handle_y)
    local handle_end = vec2.new(x2, handle_y + handle_height)

    local hovered = self.window:is_mouse_hovering_rect(handle_start, handle_end)
    self.window:is_mouse_hovering_rect_block_movement(track_start, track_end)

    local handle_col = hovered and lighten_color(self.colors.primary_accent, 10) or self.colors.primary_accent
    self.window:render_rect_filled(handle_start, handle_end, handle_col, 2.0)

    local mouse_pos = select(1, self:_get_window_local_mouse_pos())

    if not self._scrollbar_drag then
        if self.window:is_rect_clicked(handle_start, handle_end) and mouse_pos then
            self.window:block_input_capture()
            self._scrollbar_drag = {
                tab_id = tab_id,
                mouse_y = mouse_pos.y,
                scroll = scroll
            }
        elseif self.window:is_rect_clicked(track_start, track_end) and mouse_pos then
            self.window:block_input_capture()
            local click_y = mouse_pos.y
            local target = click_y - viewport_top - (handle_height / 2)
            local ratio = 0
            if handle_travel > 0 then
                ratio = math.max(0, math.min(1, target / handle_travel))
            end
            self:_set_tab_scroll_offset(tab_id, ratio * max_scroll, max_scroll)
        end
    end

    if self._scrollbar_drag and self._scrollbar_drag.tab_id == tab_id then
        if is_mouse_pressed_left(self.window) and mouse_pos then
            self.window:block_input_capture()
            local target = mouse_pos.y - viewport_top - (handle_height / 2)
            local ratio = 0
            if handle_travel > 0 then
                ratio = math.max(0, math.min(1, target / handle_travel))
            end
            self:_set_tab_scroll_offset(tab_id, ratio * max_scroll, max_scroll)
        else
            self._scrollbar_drag = nil
        end
    end
end

function RotationSettingsUI:_render_side_menu(section, viewport_top, viewport_bottom)
    if not self.window or not section or not section.side_menu then
        return 0
    end

    local items = section.side_menu.items
    if not items or #items == 0 then
        return 0
    end

    local width = section.side_menu.width or LAYOUT.side_menu_width
    if width <= 0 then
        return 0
    end

    local tab_id = section.id
    local visible_items = {}
    for _, item in ipairs(items) do
        if item then
            local show = true
            if item.visible_when and type(item.visible_when) == "function" then
                local ok, result = pcall(item.visible_when)
                show = ok and result == true
            end
            if show then
                table.insert(visible_items, item)
            end
        end
    end

    if #visible_items == 0 then
        return 0
    end

    local current_page = self:_get_active_page_id(tab_id)
    local current_valid = false
    for _, item in ipairs(visible_items) do
        if not item.header and item.id ~= nil and tostring(item.id) == tostring(current_page) then
            current_valid = true
            break
        end
    end

    if not current_valid then
        for _, item in ipairs(visible_items) do
            if not item.header and item.id ~= nil then
                self:_set_active_page_id(tab_id, item.id)
                current_page = item.id
                break
            end
        end
    end

    local x1 = LAYOUT.padding_side
    local x2 = x1 + width
    local panel_start = vec2.new(x1, viewport_top)
    local panel_end = vec2.new(x2, viewport_bottom)

    self.window:render_rect_filled(panel_start, panel_end, self.colors.section_bg, 2.0)
    self.window:render_rect(panel_start, panel_end, self.colors.section_border, 2.0, 1.0)
    self.window:is_mouse_hovering_rect_block_movement(panel_start, panel_end)

    local y = viewport_top + LAYOUT.side_menu_padding
    if section.side_menu.label and #tostring(section.side_menu.label) > 0 then
        local label = tostring(section.side_menu.label)
        local label_h = self.window:get_text_size(label).y
        self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x1 + LAYOUT.side_menu_padding, y),
            self.colors.secondary_accent, label)
        y = y + label_h + LAYOUT.side_menu_item_spacing + 4
        local sep_y = y
        self.window:render_rect_filled(vec2.new(x1 + LAYOUT.side_menu_padding, sep_y),
            vec2.new(x2 - LAYOUT.side_menu_padding, sep_y + 1), self.colors.separator, 0)
        y = y + 6
    end

    local item_x1 = x1 + LAYOUT.side_menu_padding
    local item_x2 = x2 - LAYOUT.side_menu_padding
    local item_w = item_x2 - item_x1

    for _, item in ipairs(visible_items) do
        local label = item.label and tostring(item.label) or ""
        if item.header then
            local header_h = self.window:get_text_size(label).y
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(item_x1, y),
                self.colors.primary_accent, label)
            y = y + header_h + LAYOUT.side_menu_item_spacing
        else
            local item_start = vec2.new(item_x1, y)
            local item_end = vec2.new(item_x1 + item_w, y + LAYOUT.side_menu_item_height)
            local hovered = self.window:is_mouse_hovering_rect(item_start, item_end)
            self.window:is_mouse_hovering_rect_block_movement(item_start, item_end)

            local is_active = current_page ~= nil and item.id ~= nil and tostring(item.id) == tostring(current_page)
            local bg = self.colors.section_bg
            local border = self.colors.section_border
            local text_col = self.colors.text_secondary

            if is_active then
                bg = self.colors.primary_accent
                border = self.colors.primary_accent
                text_col = self.colors.tab_text_active or color.white(255)
            elseif hovered then
                bg = lighten_color(self.colors.section_bg, 20)
                text_col = self.colors.text_primary
            end

            self.window:render_rect_filled(item_start, item_end, bg, 2.0)
            self.window:render_rect(item_start, item_end, border, 2.0, 1.0)

            local text_size = self.window:get_text_size(label)
            local text_y = y + (LAYOUT.side_menu_item_height - text_size.y) / 2
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(item_x1 + 8, text_y),
                text_col, label)

            if self.window:is_rect_clicked(item_start, item_end) and item.id ~= nil then
                self:_set_active_page_id(tab_id, item.id)
                current_page = item.id
            end

            y = y + LAYOUT.side_menu_item_height + LAYOUT.side_menu_item_spacing
        end
    end

    return width
end

function RotationSettingsUI:_get_content_width()
    if not self.window then
        return 0
    end
    local window_size = self.window:get_size()
    local reserved = self._scrollbar_reserved_right or 0
    local left_reserved = self._side_menu_reserved_left or 0
    local w = window_size.x - (2 * LAYOUT.padding_side) - reserved - left_reserved
    return math.max(0, w)
end

function RotationSettingsUI:_get_content_x_start()
    return self._content_x_start or LAYOUT.padding_side
end

function RotationSettingsUI:_set_content_layout(side_menu_width)
    local width = 0
    local x_start = LAYOUT.padding_side
    local left_reserved = 0

    if side_menu_width and side_menu_width > 0 then
        left_reserved = side_menu_width + LAYOUT.side_menu_gap
        x_start = LAYOUT.padding_side + left_reserved
    end

    self._side_menu_reserved_left = left_reserved
    self._content_x_start = x_start
    width = self:_get_content_width()
    return x_start, width
end

function RotationSettingsUI:_get_slider_bounds(entry)
    if not entry then
        return 0, 100
    end

    local function parse_value(value)
        if value == nil then
            return nil
        end
        if type(value) == "number" then
            return value
        end
        if type(value) == "string" then
            local parsed = tonumber(value)
            if parsed then
                return parsed
            end
        end
        if type(value) == "table" then
            if value.min ~= nil then
                return parse_value(value.min)
            end
            if value.max ~= nil then
                return parse_value(value.max)
            end
        end
        return nil
    end

    local explicit_min = nil
    local explicit_max = nil
    if entry.bounds then
        explicit_min = parse_value(entry.bounds.min)
        explicit_max = parse_value(entry.bounds.max)
    end
    if explicit_min == nil and entry.min ~= nil then
        explicit_min = parse_value(entry.min)
    end
    if explicit_max == nil and entry.max ~= nil then
        explicit_max = parse_value(entry.max)
    end

    if explicit_min ~= nil or explicit_max ~= nil then
        local min_value = explicit_min or 0
        local max_value = explicit_max or min_value
        if max_value < min_value then
            max_value = min_value
        end
        return min_value, max_value
    end

    local element = entry.element
    if not element then
        return 0, 100
    end

    local function normalize_number(value, fallback)
        if type(value) == "number" then
            return value
        end
        if type(value) == "string" then
            local parsed = tonumber(value)
            if parsed then
                return parsed
            end
        end
        if type(value) == "table" then
            if value.min then
                return normalize_number(value.min, fallback)
            end
            if value.max then
                return normalize_number(value.max, fallback)
            end
        end
        return fallback
    end

    local ok_min, min_from_api = pcall(function()
        if element.get_min then
            return element:get_min()
        end
        return nil
    end)
    local ok_max, max_from_api = pcall(function()
        if element.get_max then
            return element:get_max()
        end
        return nil
    end)

    local min_value = ok_min and normalize_number(min_from_api, 0) or 0
    local max_value = ok_max and normalize_number(max_from_api, 100) or 100

    if type(min_value) ~= "number" then
        min_value = 0
    end
    if type(max_value) ~= "number" then
        max_value = min_value
    end

    if max_value < min_value then
        max_value = min_value
    end

    if ok_min and ok_max then
        return min_value, max_value
    end

    local ok_bounds, bounds = pcall(function()
        if element.get_widget_bounds then
            return element:get_widget_bounds()
        end
        return nil
    end)

    if ok_bounds and bounds then
        local normalized_min = normalize_number(bounds.min or bounds.min_value, 0)
        local normalized_max = normalize_number(bounds.max or bounds.max_value, 100)
        if type(normalized_min) ~= "number" then
            normalized_min = 0
        end
        if type(normalized_max) ~= "number" then
            normalized_max = normalized_min
        end
        if normalized_max < normalized_min then
            normalized_max = normalized_min
        end
        return normalized_min, normalized_max
    end

    return 0, 100
end

function RotationSettingsUI:_apply_active_slider_from_mouse()
    if not self._active_slider or not self.window then
        return
    end

    local slider = self._active_slider
    if not slider.bar_width or slider.bar_width <= 0 or slider.min_value == slider.max_value then
        return
    end

    local mouse_space = slider.mouse_space or "adjusted"
    local mouse_pos = select(1, self:_get_window_local_mouse_pos(mouse_space))
    if not mouse_pos and mouse_space ~= "raw" then
        mouse_space = "raw"
        mouse_pos = select(1, self:_get_window_local_mouse_pos(mouse_space))
    end

    if not mouse_pos then
        return
    end

    slider.mouse_space = mouse_space
    slider.last_mouse_pos = vec2.new(mouse_pos.x, mouse_pos.y)

    local local_mouse_x = mouse_pos.x - slider.bar_x_start
    local clamped_x = math.max(0, math.min(slider.bar_width, local_mouse_x))
    local progress = clamped_x / slider.bar_width
    local new_value = slider.min_value + (slider.max_value - slider.min_value) * progress
    local rounded_value = math.floor(new_value + 0.5)
    local clamped_value = math.max(slider.min_value, math.min(slider.max_value, rounded_value))

    pcall(function()
        slider.element:set(clamped_value)
    end)
end

function RotationSettingsUI:_start_key_capture(element, label)
    if not element then
        return
    end

    if self.window then
        self.window:set_focus()
        self.window:block_input_capture()
    end

    self._active_key_capture = {
        element = element,
        label = label,
        wait_for_release = true
    }
end

function RotationSettingsUI:_process_key_capture_input()
    if not self._active_key_capture then
        return
    end

    if self._active_key_capture.wait_for_release then
        if not is_mouse_pressed_left(self.window) then
            self._active_key_capture.wait_for_release = false
        end
        return
    end

    if self.window then
        -- Allow binding mouse buttons except LMB/RMB.
        -- Map window button index -> Windows VK code.
        local mouse_vk_by_button_index = {
            [0] = 1, -- LMB
            [1] = 2, -- RMB
            [2] = 4, -- MMB
            [3] = 5, -- Mouse4 (XBUTTON1)
            [4] = 6  -- Mouse5 (XBUTTON2)
        }

        for button_index, vk_code in pairs(mouse_vk_by_button_index) do
            if button_index ~= 0 and button_index ~= 1 then
                if safe_window_mouse_check(self.window, "is_mouse_button_clicked", button_index) or core.input.is_key_pressed(vk_code) then
                    pcall(function()
                        if self._active_key_capture and self._active_key_capture.element and self._active_key_capture.element.set_key then
                            self._active_key_capture.element:set_key(vk_code)
                        end
                    end)
                    self._active_key_capture = nil
                    return
                end
            end
        end
    end

    for key_code = 1, 255 do
        if key_code == 1 or key_code == 2 then
            goto continue_key
        end
        if core.input.is_key_pressed(key_code) then
            if key_code == 27 then
                self._active_key_capture = nil
                return
            end

            pcall(function()
                if key_code == 8 or key_code == 46 then
                    if self._active_key_capture.element.set_key then
                        self._active_key_capture.element:set_key(999)
                    end
                elseif self._active_key_capture.element.set_key then
                    self._active_key_capture.element:set_key(key_code)
                end
            end)

            self._active_key_capture = nil
            return
        end

        ::continue_key::
    end
end

function RotationSettingsUI:_render_key_capture_prompt()
    if not self._active_key_capture or not self.window then
        return
    end

    local prompt_label = self._active_key_capture.label or "keybind"
    local prompt_text = string.format("Press a key for %s (Esc to cancel, Del to clear)", prompt_label)
    local window_size = self.window:get_size()
    local text_size = self.window:get_text_size(prompt_text)
    local prompt_pos = vec2.new(LAYOUT.padding_side, window_size.y - LAYOUT.padding_bottom - text_size.y - 4)
    self.window:render_text(enums.window_enums.font_id.FONT_SMALL, prompt_pos, self.colors.secondary_accent, prompt_text)
end

-- ============================================================================
-- SLIDER LIST RENDERING (Custom + Interactive)
-- ============================================================================

function RotationSettingsUI:_render_slider_list(section, y_offset)
    if not section.elements or #section.elements == 0 then
        return y_offset
    end

    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    local label_width = 180
    local bar_width = content_width - label_width - 60

    for i, item in ipairs(section.elements) do
        if item and item.element and self:_is_entry_visible(item) then
            local element = item.element
            local label = item.label or ("Slider " .. i)
            local suffix = item.suffix or ""

            local ok_val, value = pcall(function()
                return element:get()
            end)
            if not ok_val or value == nil then
                value = 0
            end

            local min_value, max_value = self:_get_slider_bounds(item)
            if max_value < min_value then
                max_value = min_value
            end

            -- Define rectangles
            local bar_x_start = x_start + label_width
            local bar_start = vec2.new(bar_x_start, y_offset)
            local bar_end = vec2.new(bar_x_start + bar_width, y_offset + LAYOUT.slider_bar_height)
            local row_top = y_offset
            local row_bottom = y_offset + LAYOUT.slider_bar_height + 6

            local is_hovered = false
            if self:_is_y_visible(row_top, row_bottom) then
                -- Hover/Press state
                is_hovered = self.window:is_mouse_hovering_rect(bar_start, bar_end)
                self.window:is_mouse_hovering_rect_block_movement(bar_start, bar_end)

                -- Custom Rendering - Label
                local label_y = y_offset + (LAYOUT.slider_bar_height - self.window:get_text_size(label).y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, label_y),
                    self.colors.text_primary, label)

                -- Progress bar background
                local bg_color = is_hovered and lighten_color(self.colors.slider_bg, 20) or self.colors.slider_bg
                self.window:render_rect_filled(bar_start, bar_end, bg_color, 1.5)

                -- Progress bar fill
                local fill_progress = max_value > min_value and ((value - min_value) / (max_value - min_value)) or 0
                local clamped_progress = math.max(0, math.min(1, fill_progress))
                local fill_width = bar_width * clamped_progress
                local fill_end = vec2.new(bar_x_start + fill_width, y_offset + LAYOUT.slider_bar_height)
                self.window:render_rect_filled(bar_start, fill_end, self.colors.slider_fill, 1.5)

                -- Progress bar border
                local is_active_slider = self._active_slider and self._active_slider.element == element
                local border_color = is_active_slider and self.colors.secondary_accent or self.colors.primary_accent
                self.window:render_rect(bar_start, bar_end, border_color, 1.5, 1.0)

                -- Value text
                local value_text = string.format("%d%s", value, suffix)
                local value_x = bar_x_start + bar_width + 10
                local value_y = y_offset + (LAYOUT.slider_bar_height - self.window:get_text_size(value_text).y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(value_x, value_y),
                    self.colors.text_secondary, value_text)

                -- INPUT HANDLING
                if is_hovered and is_mouse_clicked_left(self.window) then
                    self.window:block_input_capture()

                    local mouse_space = "adjusted"
                    local mouse_pos = select(1, self:_get_window_local_mouse_pos(mouse_space))
                    if not mouse_pos then
                        mouse_space = "raw"
                        mouse_pos = select(1, self:_get_window_local_mouse_pos(mouse_space))
                    end

                    if mouse_pos then
                        self._active_slider = {
                            element = element,
                            min_value = min_value,
                            max_value = max_value,
                            bar_x_start = bar_x_start,
                            bar_width = bar_width,
                            last_mouse_pos = vec2.new(mouse_pos.x, mouse_pos.y),
                            mouse_space = mouse_space
                        }
                        self:_apply_active_slider_from_mouse()
                    end
                end
            end

            y_offset = y_offset + LAYOUT.slider_bar_height + LAYOUT.element_spacing + 4
        end
    end

    if self._active_slider then
        if is_mouse_pressed_left(self.window) then
            self.window:block_input_capture()
            self:_apply_active_slider_from_mouse()
        else
            self._active_slider = nil
        end
    end

    return y_offset + LAYOUT.section_padding_bottom
end

function RotationSettingsUI:_render_combo_list(section, y_offset)
    if not section.elements or #section.elements == 0 then
        return y_offset
    end

    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    local label_width = 180
    local value_box_width = 160

    for i, item in ipairs(section.elements) do
        if item and item.element and self:_is_entry_visible(item) then
            local element = item.element
            local label = item.label or ("Option " .. i)
            local suffix = item.suffix or ""

            local ok_val, current_index = pcall(function()
                return element:get()
            end)
            if not ok_val or current_index == nil then
                current_index = 1
            end

            local options = item.options or {}
            local option_text = options[current_index] or tostring(current_index)
            if #suffix > 0 then
                option_text = option_text .. suffix
            end

            local box_start = vec2.new(x_start + label_width, y_offset)
            local box_end = vec2.new(x_start + label_width + value_box_width, y_offset + LAYOUT.slider_bar_height)
            local row_top = y_offset
            local row_bottom = y_offset + LAYOUT.slider_bar_height + 6

            if self:_is_y_visible(row_top, row_bottom) then
                local is_hovered = self.window:is_mouse_hovering_rect(box_start, box_end)
                self.window:is_mouse_hovering_rect_block_movement(box_start, box_end)

                local label_y = y_offset + (LAYOUT.slider_bar_height - self.window:get_text_size(label).y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, label_y),
                    self.colors.text_primary, label)

                local bg_color = is_hovered and lighten_color(self.colors.slider_bg, 20) or self.colors.slider_bg
                self.window:render_rect_filled(box_start, box_end, bg_color, 1.5)
                local border_color = is_hovered and self.colors.secondary_accent or self.colors.primary_accent
                self.window:render_rect(box_start, box_end, border_color, 1.5, 1.0)

                local value_text_size = self.window:get_text_size(option_text)
                local value_x = box_start.x + (value_box_width - value_text_size.x) / 2
                local value_y = y_offset + (LAYOUT.slider_bar_height - value_text_size.y) / 2
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(value_x, value_y),
                    self.colors.text_secondary, option_text)

                if self.window:is_rect_clicked(box_start, box_end) then
                    if #options > 0 then
                        local next_index = ((current_index - 1 + 1) % #options) + 1
                        pcall(function()
                            if element.set then
                                element:set(next_index)
                            end
                        end)
                    end
                end
            end

            y_offset = y_offset + LAYOUT.slider_bar_height + LAYOUT.element_spacing + 4
        end
    end

    return y_offset + LAYOUT.section_padding_bottom
end

function RotationSettingsUI:_render_text(group, y_offset)
    if not group.text then return y_offset end
    
    local x_start = self:_get_content_x_start()
    local text = type(group.text) == "function" and group.text() or tostring(group.text)
    
    local text_size = self.window:get_text_size(text)
    if self:_is_y_visible(y_offset, y_offset + text_size.y) then
        self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, y_offset), self.colors.text_secondary, text)
    end
    
    return y_offset + text_size.y + LAYOUT.element_spacing
end

function RotationSettingsUI:_render_button(group, y_offset)
    if not group.label or not group.on_click then return y_offset end
    
    local x_start = self:_get_content_x_start()
    local label = tostring(group.label)
    local text_size = self.window:get_text_size(label)
    local padding = 12
    local btn_w = text_size.x + (padding * 2)
    local btn_h = LAYOUT.element_height
    
    local btn_start = vec2.new(x_start, y_offset)
    local btn_end = vec2.new(x_start + btn_w, y_offset + btn_h)
    
    if self:_is_y_visible(y_offset, y_offset + btn_h) then
        local hovered = self.window:is_mouse_hovering_rect(btn_start, btn_end)
        local bg_color = hovered and lighten_color(self.colors.section_bg, 30) or self.colors.section_bg
        
        self.window:render_rect_filled(btn_start, btn_end, bg_color, 2.0)
        self.window:render_rect(btn_start, btn_end, self.colors.section_border, 2.0, 1.0)
        
        local text_x = x_start + padding
        local text_y = y_offset + (btn_h - text_size.y) / 2
        self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(text_x, text_y), self.colors.text_primary, label)
        
        if self.window:is_rect_clicked(btn_start, btn_end) then
            pcall(group.on_click)
        end
    end
    
    return y_offset + btn_h + LAYOUT.element_spacing
end

function RotationSettingsUI:_render_text_input_list(group, y_offset)
    if not group.elements then return y_offset end
    
    local x_start = self:_get_content_x_start()
    local content_width = self:_get_content_width()
    local label_width = 120
    local input_width = content_width - label_width - 10
    
    for i, item in ipairs(group.elements) do
        local element = item.element
        local label = item.label or ("Input " .. i)
        
        local row_h = LAYOUT.element_height
        if self:_is_y_visible(y_offset, y_offset + row_h) then
            -- Label
            local label_size = self.window:get_text_size(label)
            local label_y = y_offset + (row_h - label_size.y) / 2
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, label_y), self.colors.text_secondary, label)
            
            -- Input box (visual only)
            local box_start = vec2.new(x_start + label_width, y_offset)
            local box_end = vec2.new(x_start + label_width + input_width, y_offset + row_h - 2)
            
            self.window:render_rect_filled(box_start, box_end, self.colors.slider_bg, 1.0)
            self.window:render_rect(box_start, box_end, self.colors.section_border, 1.0, 1.0)
            
            local current_text = ""
            pcall(function() current_text = element:get_text() end)
            
            local text_size = self.window:get_text_size(current_text)
            local text_y = y_offset + (row_h - 2 - text_size.y) / 2
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(box_start.x + 5, text_y), self.colors.text_primary, current_text)
        end
        y_offset = y_offset + row_h + LAYOUT.element_spacing
    end
    
    return y_offset
end

function RotationSettingsUI:_render_runtime_checkbox_list(group, y_offset)
    if not group.elements then return y_offset end
    
    local elements = type(group.elements) == "function" and group.elements() or group.elements
    if not elements or #elements == 0 then return y_offset end
    
    for i, item in ipairs(elements) do
        local label = item.label or ("Item " .. i)
        local is_checked = false
        pcall(function() is_checked = item.get_state() end)
        
        local x_pos = self:_get_content_x_start()
        local row_h = LAYOUT.element_height
        
        if self:_is_y_visible(y_offset, y_offset + row_h) then
            local box_start = vec2.new(x_pos, y_offset + (row_h - LAYOUT.checkbox_size) / 2)
            local box_end = vec2.new(x_pos + LAYOUT.checkbox_size, box_start.y + LAYOUT.checkbox_size)
            
            local hovered = self.window:is_mouse_hovering_rect(box_start, box_end)
            local checkbox_color = is_checked and self.colors.checkbox_active or self.colors.checkbox_inactive
            if hovered then checkbox_color = lighten_color(checkbox_color, 30) end
            
            self.window:render_rect_filled(box_start, box_end, checkbox_color, 1.0)
            self.window:render_rect(box_start, box_end, self.colors.checkbox_border, 1.0, 1.0)
            
            if is_checked then
                local p = 3
                self.window:render_rect_filled(vec2.new(box_start.x + p, box_start.y + p), vec2.new(box_end.x - p, box_end.y - p), color.white(255), 0.5)
            end
            
            local label_x = x_pos + LAYOUT.checkbox_size + 8
            local label_y = y_offset + (row_h - self.window:get_text_size(label).y) / 2
            self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(label_x, label_y), self.colors.text_primary, label)
            
            local click_start = vec2.new(x_pos, y_offset)
            local click_end = vec2.new(x_pos + self:_get_content_width(), y_offset + row_h)
            if self.window:is_rect_clicked(click_start, click_end) then
                pcall(function() item.set_state(not is_checked) end)
            end
        end
        y_offset = y_offset + row_h + 2
    end
    
    return y_offset
end

function RotationSettingsUI:_render_separator(group, y_offset)
    local x_start = self:_get_content_x_start()
    local x_end = x_start + self:_get_content_width()
    
    local line_y = y_offset + (LAYOUT.element_spacing / 2)
    if self:_is_y_visible(line_y, line_y + 1) then
        self.window:render_rect_filled(vec2.new(x_start, line_y), vec2.new(x_end, line_y + 1), self.colors.separator, 0)
    end
    
    return y_offset + LAYOUT.element_spacing + 2
end

function RotationSettingsUI:_render_tab_groups(section, y_offset)
    if not section.groups or #section.groups == 0 then
        return y_offset
    end

    local active_page_id = nil
    if section.side_menu and section.id then
        active_page_id = self:_get_active_page_id(section.id)
    end

    for _, group in ipairs(section.groups) do
        if not self:_is_entry_visible(group) then
            goto continue_group
        end

        if active_page_id and group.page and tostring(group.page) ~= tostring(active_page_id) then
            goto continue_group
        end

        if group.label then
            local label_h = self.window:get_text_size(group.label).y + 6
            if self:_is_y_visible(y_offset, y_offset + label_h) then
                local label_pos = vec2.new(self:_get_content_x_start(), y_offset)
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, label_pos,
                    self.colors.primary_accent, group.label)
            end
            y_offset = y_offset + label_h
        end

        if group.type == "checkbox_grid" then
            y_offset = self:_render_checkbox_grid(group, y_offset)
        elseif group.type == "slider_list" then
            y_offset = self:_render_slider_list(group, y_offset)
        elseif group.type == "combo_list" then
            y_offset = self:_render_combo_list(group, y_offset)
        elseif group.type == "keybind_grid" then
            y_offset = self:_render_keybind_grid(group, y_offset)
        elseif group.type == "text" then
            y_offset = self:_render_text(group, y_offset)
        elseif group.type == "button" then
            y_offset = self:_render_button(group, y_offset)
        elseif group.type == "text_input_list" then
            y_offset = self:_render_text_input_list(group, y_offset)
        elseif group.type == "runtime_checkbox_list" then
            y_offset = self:_render_runtime_checkbox_list(group, y_offset)
        elseif group.type == "separator" then
            y_offset = self:_render_separator(group, y_offset)
        end

        ::continue_group::
    end

    return y_offset
end
-- ============================================================================
-- MAIN SECTION RENDERING
-- ============================================================================

function RotationSettingsUI:_render_sections()
    -- Render tab bar
    local y_offset = self:_render_tab_bar()

    -- Add separator line below tabs
    local window_size = self.window:get_size()
    local separator_start = vec2.new(LAYOUT.padding_side, y_offset)
    local separator_end = vec2.new(window_size.x - LAYOUT.padding_side, y_offset + 2)
    self.window:render_rect_filled(separator_start, separator_end, self.colors.separator, 0)

    y_offset = y_offset + 2 + LAYOUT.tab_content_padding_top

    local viewport_top = y_offset
    local viewport_bottom = window_size.y - LAYOUT.padding_bottom
    if self._active_key_capture then
        viewport_bottom = viewport_bottom - 18
    end
    if viewport_bottom < viewport_top then
        viewport_bottom = viewport_top
    end

    local section = nil
    if self.active_tab_index >= 1 and self.active_tab_index <= #self.sections then
        section = self.sections[self.active_tab_index]
    end

    -- Optional side-menu (sub categories) inside the active tab.
    local side_menu_width = 0
    if section and section.type == "tab" and section.side_menu then
        side_menu_width = self:_render_side_menu(section, viewport_top, viewport_bottom)
    end
    self:_set_content_layout(side_menu_width > 0 and side_menu_width or nil)

    local scroll_key = self:_get_active_scroll_key()
    local scroll = self:_get_tab_scroll_offset(scroll_key)
    self._scroll_viewport = { top = viewport_top, bottom = viewport_bottom }

    -- Render active tab content with vertical scroll offset
    local content_end_scrolled = self:_render_active_tab_content(y_offset - scroll)
    local content_end_unscrolled = content_end_scrolled + scroll
    local content_height = math.max(0, content_end_unscrolled - y_offset)

    -- Clamp scroll to valid bounds and render scrollbar if needed.
    local viewport_height = viewport_bottom - viewport_top
    local max_scroll = math.max(0, content_height - viewport_height)
    if scroll > max_scroll then
        scroll = max_scroll
        self:_set_tab_scroll_offset(scroll_key, scroll, max_scroll)
    end
    self:_render_scrollbar(scroll_key, content_height, viewport_top, viewport_bottom)
    self._scroll_viewport = nil

    if self._active_key_capture then
        self.window:block_input_capture()
    end
    self:_process_key_capture_input()
    self:_render_key_capture_prompt()
end

-- ============================================================================
-- PUBLIC API - LIFECYCLE HOOKS
-- ============================================================================

---Safely cycles the UI enable state (toggles it)
function RotationSettingsUI:toggle()
    if not self.menu or not self.menu.enable then
        return
    end

    local current_state = self.menu.enable:get_state()
    local is_on = (current_state == true or current_state == 1)
    local target_state = not is_on

    pcall(function()
        if self.menu.enable.set then
            self.menu.enable:set(target_state)
        elseif self.menu.enable.set_state then
            self.menu.enable:set_state(target_state)
        end
    end)
end

---Called in rotation's on_menu_render() to show toggle button
function RotationSettingsUI:on_menu_render(label)
    if not self.menu or not self.menu.enable then
        return
    end

    -- Attempt to render the enable checkbox. 
    -- We only check if the object exists and has a render method.
    if self.menu.enable and self.menu.enable.render then
        self.menu.enable:render(label or "Show " .. self.title)
    end
end

---Called in rotation's on_render() to render the custom window
function RotationSettingsUI:on_render()
    -- Check if window close was requested in previous frame
    if self._window_close_requested then
        -- Skip rendering this frame to allow checkbox state to sync
        self._window_close_requested = false
        return
    end

    if not self:_is_enabled() then
        return
    end

    self:_ensure_extension_tabs()

    -- Update theme based on selector
    self:_update_theme()

    if not self.window then
        self:_build_window()
    end

    -- Sync tab state from saved value
    self:_sync_tab_state()

    -- Register window render callback
    local function render_window_content()
        self:_render_sections()
    end

    local window_is_open = self.window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        true,
        self.colors.background,
        self.colors.border,
        enums.window_enums.window_cross_visuals.DEFAULT,
        render_window_content
    )

    self:_sync_window_state()

    -- CRITICAL: Check window state AFTER sync to handle X button close
    -- If user clicked X button to close, disable the checkbox (like F1 toggle)
    -- This allows F1 to re-open the window later
    if not window_is_open then
        -- Destroy window object so it gets rebuilt on next open
        self.window = nil

        -- Set flag to skip next frame (allows checkbox to sync)
        self._window_close_requested = true

        -- Disable the checkbox
        if self.menu and self.menu.enable then
            pcall(function()
                if self.menu.enable.set then
                    self.menu.enable:set(false)
                elseif self.menu.enable.set_state then
                    self.menu.enable:set_state(false)
                end
            end)
        end
    end
end

-- ============================================================================
-- MODULE EXPORT
-- ============================================================================

return {
    new = RotationSettingsUI.new,
    register_extension_tab = RotationSettingsUI.register_extension_tab,
    unregister_extension_tab = RotationSettingsUI.unregister_extension_tab,
    TabBuilder = TabBuilder
}
