-- TabMenu - ESP Settings Window
-- Uses rotation_settings_ui as base library and extends it with:
-- - ESP-specific theme
-- - Scrollable content (now built into base)
-- - Additional widget types (colorpicker, custom_render, section_header, separator)

local color = require("common/color")
local vec2 = require("common/geometry/vector_2")
local enums = require("common/enums")

-- Import the base library
local RotationSettingsUI = require("shared/x_esp_new/windowlib/rotation_settings_ui")

-- ============================================================================
-- ESP THEME
-- ============================================================================

local ESP_THEME = {
    background = color.new(28, 30, 35, 245),
    border = color.new(0, 180, 200, 255),
    section_bg = color.new(35, 38, 45, 200),
    section_border = color.new(0, 150, 170, 180),
    primary_accent = color.new(0, 200, 220, 255),
    secondary_accent = color.new(100, 220, 255, 255),
    text_primary = color.white(245),
    text_secondary = color.new(180, 190, 200, 255),
    text_disabled = color.new(100, 110, 120, 255),
    tab_text_active = color.new(28, 30, 35, 255),  -- Dark text on active tab
    slider_fill = color.new(0, 200, 220, 255),
    slider_bg = color.new(45, 48, 55, 220),
    checkbox_active = color.new(0, 200, 220, 255),
    checkbox_inactive = color.new(55, 58, 65, 200),
    checkbox_border = color.new(0, 150, 170, 180),
    keybind_bg = color.new(35, 38, 45, 220),
    keybind_border = color.new(0, 150, 170, 160),
    keybind_active = color.new(0, 200, 220, 255),
    keybind_inactive = color.new(50, 55, 60, 200),
    separator = color.new(0, 150, 170, 180)
}

-- ============================================================================
-- LAYOUT CONSTANTS (matching base library)
-- ============================================================================

local LAYOUT = {
    padding_top = 10,
    padding_side = 15,
    padding_bottom = 15,
    tab_bar_height = 35,
    tab_button_height = 30,
    tab_button_min_width = 80,
    tab_button_max_width = 150,
    tab_button_spacing = 2,
    tab_bar_padding_top = 5,
    tab_content_padding_top = 15,
    tab_bar_right_reserved = 48,
    section_spacing = 18,
    section_header_height = 0,
    section_padding_top = 8,
    section_padding_bottom = 10,
    element_height = 26,
    element_spacing = 6,
    column_spacing = 25,
    slider_bar_height = 16,
    checkbox_size = 16,
    separator_height = 2
}

-- ============================================================================
-- TABMENU CLASS (Extends RotationSettingsUI)
-- ============================================================================

local TabMenu = {}
TabMenu.__index = TabMenu

-- Inherit from RotationSettingsUI
setmetatable(TabMenu, { __index = function(t, k)
    -- Forward unknown calls to the base instance
    return rawget(t, "_base") and t._base[k]
end })

---Creates a new TabMenu instance
---@param config table Configuration {id, title, default_x, default_y, default_w, default_h, theme}
---@return table
function TabMenu.new(config)
    local self = setmetatable({}, TabMenu)
    
    -- Apply ESP theme if requested
    if config.theme == "esp" then
        config.theme = "astro" -- Use astro as base, we'll override colors
    end
    
    -- Create base instance
    self._base = RotationSettingsUI.new(config)
    
    -- Override colors with ESP theme if requested
    if config.theme == "esp" or config.theme == "astro" then
        self._base.colors = ESP_THEME
    end
    
    -- Additional state for extended features
    self._active_colorpicker = nil
    self._legacy_tabs = {}
    
    -- Tab transition animation state
    self._tab_transition_alpha = 1.0
    self._last_tab_index = 1
    self._last_render_time = 0
    
    -- Tooltip state
    self._hovered_tooltip = nil
    self._tooltip_hover_time = 0
    
    return self
end

-- ============================================================================
-- EXTENDED TAB BUILDER
-- ============================================================================

local ExtendedTabBuilder = {}
ExtendedTabBuilder.__index = ExtendedTabBuilder

function ExtendedTabBuilder.new(tab_menu, section)
    local self = setmetatable({}, ExtendedTabBuilder)
    self._tab_menu = tab_menu
    self._section = section
    return self
end

function ExtendedTabBuilder:_add_group(group)
    if not group or not group.type then
        return self
    end
    self._section.groups = self._section.groups or {}
    table.insert(self._section.groups, group)
    return self
end

-- Standard widgets (forwarded to base, with page/subpage support)
function ExtendedTabBuilder:checkbox_grid(opts)
    -- Check if any element has a description - use extended renderer
    local has_descriptions = false
    if opts and opts.elements then
        for _, item in ipairs(opts.elements) do
            if item and item.description then
                has_descriptions = true
                break
            end
        end
    end
    
    return self:_add_group({
        type = has_descriptions and "checkbox_grid_with_tooltips" or "checkbox_grid",
        label = opts and opts.label,
        columns = opts and opts.columns,
        elements = opts and opts.elements,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

function ExtendedTabBuilder:slider_list(opts)
    return self:_add_group({
        type = "slider_list",
        label = opts and opts.label,
        elements = opts and opts.elements,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

function ExtendedTabBuilder:combo_list(opts)
    return self:_add_group({
        type = "combo_list",
        label = opts and opts.label,
        elements = opts and opts.elements,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

function ExtendedTabBuilder:keybind_grid(opts)
    return self:_add_group({
        type = "keybind_grid",
        elements = opts and opts.elements,
        labels = opts and opts.labels,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

-- Side menu support (new from base)
function ExtendedTabBuilder:side_menu(opts)
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

-- Extended widgets
function ExtendedTabBuilder:colorpicker_list(opts)
    return self:_add_group({
        type = "colorpicker_list",
        label = opts and opts.label,
        elements = opts and opts.elements,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

function ExtendedTabBuilder:custom_render(opts)
    return self:_add_group({
        type = "custom_render",
        label = opts and opts.label,
        render_func = opts and opts.render_func,
        visible_when = opts and opts.visible_when,
        page = opts and (opts.page or opts.subpage)
    })
end

function ExtendedTabBuilder:section_header(title)
    return self:_add_group({
        type = "section_header",
        title = title
    })
end

function ExtendedTabBuilder:spacing(height)
    return self:_add_group({
        type = "spacing",
        height = height or 10
    })
end

function ExtendedTabBuilder:separator()
    return self:_add_group({
        type = "separator"
    })
end

-- ============================================================================
-- ADD TAB (Extended to support legacy and new API)
-- ============================================================================

---Add a tab to the menu
---@param tab table|string Either {id, label} or just a string name (legacy)
---@param build_fn function Builder callback
function TabMenu:add_tab(tab, build_fn)
    -- Legacy API support: add_tab("Name", function(window, menu) ... end)
    if type(tab) == "string" then
        local section = {
            id = tab:lower():gsub("%s+", "_"),
            label = tab,
            type = "legacy_tab",
            legacy_render_func = build_fn,
            groups = {}
        }
        self._base:register_section(section)
        return self
    end
    
    -- New API: add_tab({ id = "...", label = "..." }, function(t) ... end)
    if not tab or not tab.id or not tab.label then
        return self
    end
    
    local section = {
        id = tab.id,
        label = tab.label,
        type = "tab",
        groups = {},
        visible_when = tab.visible_when
    }
    
    if build_fn and type(build_fn) == "function" then
        local builder = ExtendedTabBuilder.new(self, section)
        pcall(build_fn, builder)
    end
    
    self._base:register_section(section)
    return self
end

-- ============================================================================
-- EXTENDED RENDERING FUNCTIONS
-- ============================================================================

local function lighten_color(base_color, amount)
    return color.new(60, 60, 70, 200)
end

-- ============================================================================
-- ANIMATION & TOOLTIP HELPERS
-- ============================================================================

-- Get current time in seconds (fallback to os.clock if core.game_time not available)
local function get_time()
    if core and core.game_time then
        return core.game_time()
    end
    return os.clock()
end

-- Lerp helper for smooth transitions
local function lerp(a, b, t)
    return a + (b - a) * math.max(0, math.min(1, t))
end

-- Render tooltip at mouse position
local function render_tooltip(window, colors, text, mouse_pos)
    if not text or #text == 0 or not mouse_pos then
        return
    end
    
    local padding = 8
    local text_size = window:get_text_size(text)
    local tooltip_width = text_size.x + padding * 2
    local tooltip_height = text_size.y + padding * 2
    
    -- Position tooltip above and to the right of cursor
    local tooltip_x = mouse_pos.x + 15
    local tooltip_y = mouse_pos.y - tooltip_height - 5
    
    -- Keep tooltip on screen
    local window_size = window:get_size()
    if tooltip_x + tooltip_width > window_size.x - 10 then
        tooltip_x = mouse_pos.x - tooltip_width - 5
    end
    if tooltip_y < 10 then
        tooltip_y = mouse_pos.y + 20
    end
    
    local bg_start = vec2.new(tooltip_x, tooltip_y)
    local bg_end = vec2.new(tooltip_x + tooltip_width, tooltip_y + tooltip_height)
    
    -- Background with slight transparency
    window:render_rect_filled(bg_start, bg_end, color.new(20, 22, 28, 245), 4.0)
    window:render_rect(bg_start, bg_end, colors.primary_accent, 4.0, 1.5)
    
    -- Text
    local text_pos = vec2.new(tooltip_x + padding, tooltip_y + padding)
    window:render_text(enums.window_enums.font_id.FONT_SMALL, text_pos, colors.text_primary, text)
end

-- Check if Y position is visible in scroll viewport
function TabMenu:_is_y_visible(y_top, y_bottom)
    -- Use base's viewport if available
    local vp = self._base._scroll_viewport
    if not vp then
        return true
    end
    return y_bottom >= vp.top and y_top <= vp.bottom
end

-- Get content width (accounting for scrollbar and side menu)
function TabMenu:_get_content_width()
    return self._base:_get_content_width()
end

-- Get content X start position (accounting for side menu)
function TabMenu:_get_content_x_start()
    return self._base:_get_content_x_start()
end

-- Section header rendering
function TabMenu:_render_section_header_inline(group, y_offset)
    local window = self._base.window
    local colors = self._base.colors
    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    local row_top = y_offset
    local row_bottom = y_offset + 32

    if not self:_is_y_visible(row_top, row_bottom) then
        return y_offset + 40
    end

    y_offset = y_offset + 8

    local header_start = vec2.new(x_start, y_offset)
    local header_end = vec2.new(x_start + content_width, y_offset + 24)
    window:render_rect_filled(header_start, header_end, colors.section_bg, 3.0)
    window:render_rect(header_start, header_end, colors.section_border, 3.0, 1.0)

    local text = group.title or "Section"
    local text_size = window:get_text_size(text)
    local text_x = x_start + 10
    local text_y = y_offset + (24 - text_size.y) / 2
    window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(text_x, text_y),
        colors.secondary_accent, text)

    return y_offset + 24 + 8
end

-- Separator line rendering
function TabMenu:_render_separator_line(y_offset)
    local window = self._base.window
    local colors = self._base.colors
    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    local row_top = y_offset
    local row_bottom = y_offset + 14

    if not self:_is_y_visible(row_top, row_bottom) then
        return y_offset + 14
    end

    y_offset = y_offset + 6
    local separator_start = vec2.new(x_start, y_offset)
    local separator_end = vec2.new(x_start + content_width, y_offset + 1)
    window:render_rect_filled(separator_start, separator_end, colors.separator, 0)
    
    return y_offset + 8
end

-- Extended slider list rendering (handles float values correctly)
function TabMenu:_render_slider_list_extended(group, y_offset)
    if not group.elements or #group.elements == 0 then
        return y_offset
    end

    local window = self._base.window
    local colors = self._base.colors
    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    local label_width = 180
    local bar_width = content_width - label_width - 60

    for i, item in ipairs(group.elements) do
        if item and item.element and self._base:_is_entry_visible(item) then
            local element = item.element
            local label = item.label or ("Slider " .. i)
            local suffix = item.suffix or ""

            local ok_val, value = pcall(function()
                return element:get()
            end)
            if not ok_val or value == nil then
                value = 0
            end

            -- Prüfe ob es ein Float-Slider ist
            -- Standardmäßig als Float behandeln (da alle Slider in main.lua mit slider_float erstellt werden)
            local min_value, max_value = self._base:_get_slider_bounds(item)
            local is_float = true  -- Standard: Float
            
            -- Nur als Integer behandeln, wenn ALLE folgenden Bedingungen erfüllt sind:
            -- 1. min, max und value sind alle ganze Zahlen
            -- 2. Der Bereich ist >= 1 (um 0.0-1.0 Slider auszuschließen)
            if type(min_value) == "number" and type(max_value) == "number" and type(value) == "number" then
                local min_is_int = math.floor(min_value) == min_value
                local max_is_int = math.floor(max_value) == max_value
                local value_is_int = math.floor(value) == value
                local range = max_value - min_value
                
                -- Nur wenn ALLE Werte ganze Zahlen sind UND der Bereich >= 1 ist, dann Integer
                if min_is_int and max_is_int and value_is_int and range >= 1.0 then
                    is_float = false
                end
            end

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
                is_hovered = window:is_mouse_hovering_rect(bar_start, bar_end)
                window:is_mouse_hovering_rect_block_movement(bar_start, bar_end)

                -- Custom Rendering - Label
                local label_y = y_offset + (LAYOUT.slider_bar_height - window:get_text_size(label).y) / 2
                window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, label_y),
                    colors.text_primary, label)

                -- Progress bar background
                local bg_color = is_hovered and lighten_color(colors.slider_bg, 20) or colors.slider_bg
                window:render_rect_filled(bar_start, bar_end, bg_color, 1.5)

                -- Progress bar fill
                local fill_progress = max_value > min_value and ((value - min_value) / (max_value - min_value)) or 0
                local clamped_progress = math.max(0, math.min(1, fill_progress))
                local fill_width = bar_width * clamped_progress
                local fill_end = vec2.new(bar_x_start + fill_width, y_offset + LAYOUT.slider_bar_height)
                window:render_rect_filled(bar_start, fill_end, colors.slider_fill, 1.5)

                -- Progress bar border
                local is_active_slider = self._base._active_slider and self._base._active_slider.element == element
                local border_color = is_active_slider and colors.secondary_accent or colors.primary_accent
                window:render_rect(bar_start, bar_end, border_color, 1.5, 1.0)

                -- Value text (Float oder Int formatieren)
                local value_text
                if is_float then
                    value_text = string.format("%.2f%s", value, suffix)
                else
                    value_text = string.format("%d%s", value, suffix)
                end
                local value_x = bar_x_start + bar_width + 10
                local value_y = y_offset + (LAYOUT.slider_bar_height - window:get_text_size(value_text).y) / 2
                window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(value_x, value_y),
                    colors.text_secondary, value_text)

                -- INPUT HANDLING
                if is_hovered and window:is_rect_clicked(bar_start, bar_end) then
                    window:block_input_capture()

                    local mouse_space = "adjusted"
                    local mouse_pos = select(1, self._base:_get_window_local_mouse_pos(mouse_space))
                    if not mouse_pos then
                        mouse_space = "raw"
                        mouse_pos = select(1, self._base:_get_window_local_mouse_pos(mouse_space))
                    end

                    if mouse_pos then
                        self._base._active_slider = {
                            element = element,
                            min_value = min_value,
                            max_value = max_value,
                            bar_x_start = bar_x_start,
                            bar_width = bar_width,
                            last_mouse_pos = vec2.new(mouse_pos.x, mouse_pos.y),
                            mouse_space = mouse_space,
                            is_float = is_float  -- Flag für Float-Behandlung
                        }
                        self:_apply_slider_from_mouse_extended()
                    end
                end
            end

            y_offset = y_offset + LAYOUT.slider_bar_height + LAYOUT.element_spacing + 4
        end
    end

    if self._base._active_slider then
        -- Check if mouse is still pressed
        local mouse_pressed = false
        if window.is_mouse_button_pressed then
            local ok1, pressed1 = pcall(window.is_mouse_button_pressed, window, 0)
            local ok2, pressed2 = pcall(window.is_mouse_button_pressed, window, 1)
            mouse_pressed = (ok1 and pressed1) or (ok2 and pressed2)
        end
        if not mouse_pressed and core and core.input then
            mouse_pressed = core.input.is_key_pressed(1) or core.input.is_key_pressed(2)
        end
        
        if mouse_pressed then
            window:block_input_capture()
            self:_apply_slider_from_mouse_extended()
        else
            self._base._active_slider = nil
    end
end

    return y_offset + LAYOUT.section_padding_bottom
end

-- Extended slider mouse handling (preserves float precision)
function TabMenu:_apply_slider_from_mouse_extended()
    if not self._base._active_slider or not self._base.window then
        return
    end

    local slider = self._base._active_slider
    if not slider.bar_width or slider.bar_width <= 0 or slider.min_value == slider.max_value then
        return
    end

    local mouse_space = slider.mouse_space or "adjusted"
    local mouse_pos = select(1, self._base:_get_window_local_mouse_pos(mouse_space))
    if not mouse_pos and mouse_space ~= "raw" then
        mouse_space = "raw"
        mouse_pos = select(1, self._base:_get_window_local_mouse_pos(mouse_space))
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
    
    -- Für Float-Slider: NICHT runden, für Int-Slider: runden
    local clamped_value
    if slider.is_float then
        clamped_value = math.max(slider.min_value, math.min(slider.max_value, new_value))
    else
        local rounded_value = math.floor(new_value + 0.5)
        clamped_value = math.max(slider.min_value, math.min(slider.max_value, rounded_value))
    end

    pcall(function()
        slider.element:set(clamped_value)
    end)
end

-- Helper functions (from base UI)
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

local function is_mouse_clicked_left(window)
    return safe_window_mouse_check(window, "is_mouse_button_clicked", 0) or safe_window_mouse_check(window, "is_mouse_button_clicked", 1)
end

local function is_mouse_pressed_left(window)
    if safe_window_mouse_check(window, "is_mouse_button_pressed", 0) or safe_window_mouse_check(window, "is_mouse_button_pressed", 1) then
        return true
    end
    return core.input.is_key_pressed(1) or core.input.is_key_pressed(2)
end

-- Colorpicker list rendering
function TabMenu:_render_colorpicker_list(group, y_offset)
    if not group.elements or #group.elements == 0 then
        return y_offset
    end

    local window = self._base.window
    local colors = self._base.colors
    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    local label_width = 180
    local color_box_width = 100
    local color_box_height = 20
    local row_height = 28

    for i, item in ipairs(group.elements) do
        if item and item.element then
            local element = item.element
            local label = item.label or ("Color " .. i)

            local current_color = color.white(255)
            local ok_color, col = pcall(function()
                return element:get()
            end)
            if ok_color and col then
                current_color = col
            end

            local row_top = y_offset
            local row_bottom = y_offset + row_height

            if self:_is_y_visible(row_top, row_bottom) then
                local label_y = y_offset + (row_height - window:get_text_size(label).y) / 2
                window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(x_start, label_y),
                    colors.text_primary, label)

                local box_x = x_start + label_width
                local box_start = vec2.new(box_x, y_offset + 3)
                local box_end = vec2.new(box_x + color_box_width, y_offset + 3 + color_box_height)
                
                -- Checkerboard background
                local checker_size = 5
                for cy = 0, color_box_height - 1, checker_size do
                    for cx = 0, color_box_width - 1, checker_size do
                        local is_light = ((cx / checker_size) + (cy / checker_size)) % 2 == 0
                        local checker_color = is_light and color.new(80, 80, 80, 255) or color.new(50, 50, 50, 255)
                        local c_start = vec2.new(box_x + cx, y_offset + 3 + cy)
                        local c_end = vec2.new(
                            math.min(box_x + cx + checker_size, box_end.x),
                            math.min(y_offset + 3 + cy + checker_size, box_end.y)
                        )
                        window:render_rect_filled(c_start, c_end, checker_color, 0)
                    end
                end
                
                window:render_rect_filled(box_start, box_end, current_color, 2.0)
                
                local is_hovered = window:is_mouse_hovering_rect(box_start, box_end)
                local border_color = is_hovered and colors.primary_accent or colors.section_border
                window:render_rect(box_start, box_end, border_color, 2.0, is_hovered and 2.0 or 1.0)
                window:is_mouse_hovering_rect_block_movement(box_start, box_end)

                if is_hovered then
                    local hint_text = "Click to edit"
                    local hint_x = box_x + color_box_width + 10
                    local hint_y = y_offset + (row_height - window:get_text_size(hint_text).y) / 2
                    window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(hint_x, hint_y),
                        colors.text_secondary, hint_text)
                end

                if window:is_rect_clicked(box_start, box_end) then
                    self._active_colorpicker = element
                end
            end

            if self._active_colorpicker == element then
                y_offset = y_offset + row_height + 2
                
                window:add_menu_element_pos_offset(vec2.new(x_start + 20, y_offset))
                pcall(function()
                    element:render("", "")
                end)
                
                local close_x = x_start + content_width - 60
                local close_start = vec2.new(close_x, y_offset)
                local close_end = vec2.new(close_x + 50, y_offset + 22)
                local close_hovered = window:is_mouse_hovering_rect(close_start, close_end)
                window:render_rect_filled(close_start, close_end, 
                    close_hovered and colors.primary_accent or colors.section_bg, 3.0)
                window:render_rect(close_start, close_end, colors.section_border, 3.0, 1.0)
                local close_text = "Done"
                local close_text_size = window:get_text_size(close_text)
                window:render_text(enums.window_enums.font_id.FONT_SMALL, 
                    vec2.new(close_x + (50 - close_text_size.x) / 2, y_offset + 4),
                    colors.text_primary, close_text)
                
                if window:is_rect_clicked(close_start, close_end) then
                    self._active_colorpicker = nil
                end
                
                y_offset = y_offset + 30 + LAYOUT.element_spacing
            else
                y_offset = y_offset + row_height + LAYOUT.element_spacing
            end
        end
    end

    return y_offset + LAYOUT.section_padding_bottom
end

-- Checkbox grid with tooltip support
function TabMenu:_render_checkbox_grid_with_tooltips(group, y_offset)
    if not group.elements or #group.elements == 0 then
        return y_offset
    end

    local window = self._base.window
    local colors = self._base.colors
    local content_width = self:_get_content_width()
    local x_start = self:_get_content_x_start()

    local columns = group.columns or 2
    local column_width = (content_width - ((columns - 1) * LAYOUT.column_spacing)) / columns

    y_offset = y_offset + LAYOUT.section_padding_top

    local col = 0
    local current_time = get_time()

    for i, item in ipairs(group.elements) do
        if item and item.element then
            -- Check visibility
            if item.visible_when then
                local ok, visible = pcall(item.visible_when)
                if not ok or not visible then
                    goto continue_checkbox
                end
            end

            local element = item.element
            local label = item.label or ("Option " .. i)
            local description = item.description

            local ok_state, is_checked = pcall(function()
                return element:get_state()
            end)
            if not ok_state then
                is_checked = false
            end

            local x_pos = x_start + (col * (column_width + LAYOUT.column_spacing))
            local row_top = y_offset
            local row_bottom = y_offset + LAYOUT.element_height

            if self:_is_y_visible(row_top, row_bottom) then
                -- Checkbox rectangle
                local checkbox_start = vec2.new(x_pos, y_offset)
                local checkbox_end = vec2.new(x_pos + LAYOUT.checkbox_size, y_offset + LAYOUT.checkbox_size)

                -- Hover state
                local row_click_start = vec2.new(x_pos, y_offset)
                local row_click_end = vec2.new(x_pos + column_width, y_offset + LAYOUT.checkbox_size)
                local is_hovered = window:is_mouse_hovering_rect(row_click_start, row_click_end)

                -- Handle tooltip state
                if is_hovered and description then
                    if self._hovered_tooltip ~= description then
                        self._hovered_tooltip = description
                        self._tooltip_hover_time = current_time
                    end
                elseif self._hovered_tooltip == description then
                    self._hovered_tooltip = nil
                    self._tooltip_hover_time = 0
                end

                -- Custom Rendering
                local checkbox_color = is_checked and colors.checkbox_active or colors.checkbox_inactive
                if is_hovered then
                    checkbox_color = lighten_color(checkbox_color, 30)
                end

                window:render_rect_filled(checkbox_start, checkbox_end, checkbox_color, 1.0)
                window:render_rect(checkbox_start, checkbox_end, colors.checkbox_border, 1.0, 1.0)

                -- Checkmark if enabled
                if is_checked then
                    local check_padding = 3
                    local check_start = vec2.new(x_pos + check_padding, y_offset + check_padding)
                    local check_end = vec2.new(x_pos + LAYOUT.checkbox_size - check_padding, y_offset + LAYOUT.checkbox_size - check_padding)
                    window:render_rect_filled(check_start, check_end, color.white(255), 0.5)
                end

                -- Label with info icon if has description
                local label_x = x_pos + LAYOUT.checkbox_size + 8
                local label_y = y_offset + (LAYOUT.checkbox_size - window:get_text_size(label).y) / 2
                local label_color = is_checked and colors.text_primary or colors.text_secondary
                window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(label_x, label_y),
                    label_color, label)

                -- Small info indicator if has description
                if description then
                    local info_text = "(?)"
                    local label_size = window:get_text_size(label)
                    local info_x = label_x + label_size.x + 4
                    local info_color = is_hovered and colors.primary_accent or colors.text_disabled
                    window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(info_x, label_y),
                        info_color, info_text)
                end

                -- Click handling
                window:is_mouse_hovering_rect_block_movement(row_click_start, row_click_end)
                if window:is_rect_clicked(row_click_start, row_click_end) then
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
                y_offset = y_offset + LAYOUT.element_height + LAYOUT.element_spacing
            end

            ::continue_checkbox::
        end
    end

    if col > 0 then
        y_offset = y_offset + LAYOUT.element_height + LAYOUT.element_spacing
    end

    return y_offset + LAYOUT.section_padding_bottom
end

-- Custom render callback
function TabMenu:_render_custom(group, y_offset)
    if not group.render_func then
        return y_offset
    end

    local window = self._base.window
    local x_start = self:_get_content_x_start()

    y_offset = y_offset + LAYOUT.section_padding_top

    local sub_context_pos = vec2.new(x_start, y_offset)
    local elements_rendered = 0
    
    window:add_menu_element_pos_offset(sub_context_pos)
    local ok, result = pcall(group.render_func, window, self)
    if ok and type(result) == "number" then
        elements_rendered = result
    end

    local element_height = 30
    if elements_rendered > 0 then
        return y_offset + (elements_rendered * element_height) + LAYOUT.section_padding_bottom
    else
        return y_offset + (3 * element_height) + LAYOUT.section_padding_bottom
    end
end

-- Legacy tab rendering
function TabMenu:_render_legacy_tab(section, y_offset)
    if not section.legacy_render_func then
        return y_offset
    end

    local window = self._base.window
    local x_start = self:_get_content_x_start()
    window:add_menu_element_pos_offset(vec2.new(x_start, y_offset))

    local ok, err = pcall(section.legacy_render_func, window, self)
    if not ok and core and core.log then
        core.log("[TabMenu] Legacy tab render error: " .. tostring(err))
    end

    return y_offset
end

-- ============================================================================
-- EXTENDED _render_tab_groups IMPLEMENTATION
-- ============================================================================

function TabMenu:_render_extended_tab_groups(section, y_offset)
    if not section.groups or #section.groups == 0 then
        return y_offset
    end

    local window = self._base.window
    local colors = self._base.colors

    -- Get active page for side menu filtering
    local active_page_id = nil
    if section.side_menu and section.id then
        active_page_id = self._base:_get_active_page_id(section.id)
    end

    for _, group in ipairs(section.groups) do
        -- Check visibility condition
        if group.visible_when then
            local ok, visible = pcall(group.visible_when)
            if not ok or not visible then
                goto continue_group
            end
        end

        -- Check page filter (for side menu)
        if active_page_id and group.page and tostring(group.page) ~= tostring(active_page_id) then
            goto continue_group
        end

        -- Render group label if present
        if group.label then
            local label_h = window:get_text_size(group.label).y + 6
            if self:_is_y_visible(y_offset, y_offset + label_h) then
                local label_pos = vec2.new(self:_get_content_x_start(), y_offset)
                window:render_text(enums.window_enums.font_id.FONT_SMALL, label_pos,
                    colors.primary_accent, group.label)
            end
            y_offset = y_offset + label_h
        end

        -- Render based on group type
        if group.type == "checkbox_grid" then
            y_offset = self._base:_render_checkbox_grid(group, y_offset)
        elseif group.type == "checkbox_grid_with_tooltips" then
            y_offset = self:_render_checkbox_grid_with_tooltips(group, y_offset)
        elseif group.type == "slider_list" then
            y_offset = self:_render_slider_list_extended(group, y_offset)
        elseif group.type == "combo_list" then
            y_offset = self._base:_render_combo_list(group, y_offset)
        elseif group.type == "keybind_grid" then
            y_offset = self._base:_render_keybind_grid(group, y_offset)
        elseif group.type == "colorpicker_list" then
            y_offset = self:_render_colorpicker_list(group, y_offset)
        elseif group.type == "custom_render" then
            y_offset = self:_render_custom(group, y_offset)
        elseif group.type == "section_header" then
            y_offset = self:_render_section_header_inline(group, y_offset)
        elseif group.type == "spacing" then
            y_offset = y_offset + (group.height or 10)
        elseif group.type == "separator" then
            y_offset = self:_render_separator_line(y_offset)
        end

        ::continue_group::
    end

    return y_offset
end

-- ============================================================================
-- CUSTOM _render_active_tab_content TO HANDLE EXTENDED TYPES
-- ============================================================================

function TabMenu:_render_active_tab_content_extended(y_offset)
    local base = self._base
    if base.active_tab_index < 1 or base.active_tab_index > #base.sections then
        return y_offset
    end

    local section = base.sections[base.active_tab_index]
    if not section then
        return y_offset
    end

    -- Check visibility
    if not base:_is_section_visible(section) then
        return y_offset
    end

    -- Render based on section type
    if section.type == "keybind_grid" then
        return base:_render_keybind_grid(section, y_offset)
    elseif section.type == "checkbox_grid" then
        return base:_render_checkbox_grid(section, y_offset)
    elseif section.type == "slider_list" then
        return base:_render_slider_list(section, y_offset)
    elseif section.type == "combo_list" then
        return base:_render_combo_list(section, y_offset)
    elseif section.type == "tab" then
        return self:_render_extended_tab_groups(section, y_offset)
    elseif section.type == "legacy_tab" then
        return self:_render_legacy_tab(section, y_offset)
    end

    return y_offset
end

-- ============================================================================
-- CUSTOM _render_sections WITH SCROLLBAR AND EXTENDED WIDGETS
-- ============================================================================

function TabMenu:_render_sections_with_scroll()
    local base = self._base
    local window = base.window
    local colors = base.colors
    
    -- Update tab transition animation
    local current_time = get_time()
    local delta_time = current_time - (self._last_render_time or current_time)
    self._last_render_time = current_time
    
    -- Detect tab change and trigger fade
    if self._last_tab_index ~= base.active_tab_index then
        self._tab_transition_alpha = 0.0
        self._last_tab_index = base.active_tab_index
    end
    
    -- Smoothly animate alpha back to 1.0
    if self._tab_transition_alpha < 1.0 then
        self._tab_transition_alpha = lerp(self._tab_transition_alpha, 1.0, delta_time * 8)
        if self._tab_transition_alpha > 0.98 then
            self._tab_transition_alpha = 1.0
    end
end

    -- Use base's tab bar rendering (now with wrapping support)
    local y_offset = base:_render_tab_bar()

    -- Add separator line below tabs
    local window_size = window:get_size()
    local separator_start = vec2.new(LAYOUT.padding_side, y_offset)
    local separator_end = vec2.new(window_size.x - LAYOUT.padding_side, y_offset + 2)
    window:render_rect_filled(separator_start, separator_end, colors.separator, 0)

    y_offset = y_offset + 2 + LAYOUT.tab_content_padding_top

    -- Calculate viewport bounds
    local viewport_top = y_offset
    local viewport_bottom = window_size.y - LAYOUT.padding_bottom
    if base._active_key_capture then
        viewport_bottom = viewport_bottom - 18
    end
    if viewport_bottom < viewport_top then
        viewport_bottom = viewport_top
    end

    -- Get active section for side menu
    local section = nil
    if base.active_tab_index >= 1 and base.active_tab_index <= #base.sections then
        section = base.sections[base.active_tab_index]
    end

    -- Render optional side menu
    local side_menu_width = 0
    if section and section.type == "tab" and section.side_menu then
        side_menu_width = base:_render_side_menu(section, viewport_top, viewport_bottom)
    end
    base:_set_content_layout(side_menu_width > 0 and side_menu_width or nil)

    -- Get scroll state
    local scroll_key = base:_get_active_scroll_key()
    local scroll = base:_get_tab_scroll_offset(scroll_key)
    base._scroll_viewport = { top = viewport_top, bottom = viewport_bottom }

    -- Render active tab content with scroll offset
    local content_end_scrolled = self:_render_active_tab_content_extended(y_offset - scroll)
    local content_end_unscrolled = content_end_scrolled + scroll
    local content_height = math.max(0, content_end_unscrolled - y_offset)

    -- Clamp scroll and render scrollbar
    local viewport_height = viewport_bottom - viewport_top
    local max_scroll = math.max(0, content_height - viewport_height)
    if scroll > max_scroll then
        scroll = max_scroll
        base:_set_tab_scroll_offset(scroll_key, scroll, max_scroll)
    end
    base:_render_scrollbar(scroll_key, content_height, viewport_top, viewport_bottom)
    base._scroll_viewport = nil

    -- Handle key capture
    if base._active_key_capture then
        window:block_input_capture()
    end
    base:_process_key_capture_input()
    base:_render_key_capture_prompt()
    
    -- Render fade overlay for tab transition
    if self._tab_transition_alpha < 1.0 then
        local fade_alpha = math.floor((1.0 - self._tab_transition_alpha) * 200)
        local fade_color = color.new(
            colors.background:get_r(),
            colors.background:get_g(),
            colors.background:get_b(),
            fade_alpha
        )
        local fade_start = vec2.new(LAYOUT.padding_side, viewport_top)
        local fade_end = vec2.new(window_size.x - LAYOUT.padding_side, viewport_bottom)
        window:render_rect_filled(fade_start, fade_end, fade_color, 0)
    end
    
    -- Render tooltip if hovering (with delay)
    if self._hovered_tooltip and self._tooltip_hover_time > 0 then
        local hover_duration = current_time - self._tooltip_hover_time
        if hover_duration > 0.5 then  -- Show after 0.5 seconds hover
            local mouse_pos = nil
            pcall(function()
                mouse_pos = window:get_mouse_pos()
            end)
            if mouse_pos then
                render_tooltip(window, colors, self._hovered_tooltip, mouse_pos)
            end
        end
    end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function TabMenu:on_render()
    -- Check if window close was requested
    if self._base._window_close_requested then
        self._base._window_close_requested = false
        return
    end

    if not self._base:_is_enabled() then
        return
    end

    -- Ensure extension tabs are synced
    self._base:_ensure_extension_tabs()

    -- Update theme based on selector
    self._base:_update_theme()
    
    -- Re-apply ESP theme after selector update (to keep our custom theme)
    self._base.colors = ESP_THEME

    if not self._base.window then
        self._base:_build_window()
    end

    self._base:_sync_tab_state()

    local tab_menu_self = self
    local function render_window_content()
        tab_menu_self:_render_sections_with_scroll()
    end

    local window_is_open = self._base.window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        true,
        self._base.colors.background,
        self._base.colors.border,
        enums.window_enums.window_cross_visuals.DEFAULT,
        render_window_content
    )

    self._base:_sync_window_state()

    -- Handle window close via X button
    if not window_is_open then
        self._base.window = nil
        self._base._window_close_requested = true
        if self._base.menu and self._base.menu.enable then
            pcall(function()
                if self._base.menu.enable.set then
                    self._base.menu.enable:set(false)
                elseif self._base.menu.enable.set_state then
                    self._base.menu.enable:set_state(false)
                end
            end)
        end
    end
end

function TabMenu:render(bg_color, border_color)
    self:on_render()
end

function TabMenu:set_visible(visible)
    if self._base.menu and self._base.menu.enable then
        self._base.menu.enable:set(visible)
    end
end

function TabMenu:toggle()
    if self._base.menu and self._base.menu.enable then
        self._base.menu.enable:set(not self._base.menu.enable:get_state())
    end
end

function TabMenu:is_visible()
    return self._base:_is_enabled()
end

function TabMenu:get_window()
    return self._base.window
end

-- ============================================================================
-- STATIC HELPER: SETTINGS PANEL (Legacy compatibility)
-- ============================================================================

function TabMenu.create_settings_panel(window, callback)
    local ws = window:get_size()
    local available_width = ws and ws.x or 600

    local current_offset = window:get_current_context_dynamic_drawing_offset()
    local window_height = ws and ws.y or 300
    local current_y = current_offset and current_offset.y or 0
    local available_height = math.max(100, window_height - current_y - 25)

    local padding = vec2.new(25, 0)

    window:begin_window_sub_context(vec2.new(available_width, available_height), true, function()
        local function render_with_padding(render_func)
            window:add_menu_element_pos_offset(padding)
            render_func()
        end
        callback(render_with_padding)
    end)
end

-- ============================================================================
-- MODULE EXPORT
-- ============================================================================

return {
    new = TabMenu.new,
    create_settings_panel = TabMenu.create_settings_panel
}
