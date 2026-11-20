-- UI Components - Reusable rendering helpers for TabMenu
-- Provides common UI patterns: headers, separators, value displays, etc.
-- Version: 1.0.0

local color = require("common/color")
local vec2 = require("common/geometry/vector_2")
local enums = require("common/enums")

---@class UIComponents
local UIComponents = {}

-- ============================================================================
-- Separator Rendering
-- ============================================================================

---Renders a horizontal separator line
---@param window table Window reference
---@param width number|nil Separator width (default: 400)
---@param line_color table|nil Line color
function UIComponents.separator(window, width, line_color)
    -- Separator ist jetzt nur eine leere Zeile (kompakt)
    -- Die section_header hat bereits visuelle Trennung
end

---Renders a section header with separator lines
---@param window table Window reference
---@param title string Section title
---@param width number|nil Section width (default: 400)
---@param title_color table|nil Title color
function UIComponents.section_header(window, title, width, title_color)
    title_color = title_color or color.new(220, 200, 255, 255)
    -- Kompakter Header: nur Titel mit Prefix
    window:add_text_on_dynamic_pos(title_color, "-- " .. title .. " --")
end

-- ============================================================================
-- Value Display
-- ============================================================================

---Renders a labeled value display
---@param window table Window reference
---@param label string Label text
---@param value any Value to display
---@param label_color table|nil Label color (ignored - using single color for simplicity)
---@param value_color table|nil Value color (ignored - using single color for simplicity)
function UIComponents.labeled_value(window, label, value, label_color, value_color)
    local display_color = color.new(200, 190, 220, 255)
    -- Verwende add_text_on_dynamic_pos für korrekte Scroll-Integration
    window:add_text_on_dynamic_pos(display_color, label .. ": " .. tostring(value))
end

---Renders a key-value pair in a grid format
---@param window table Window reference
---@param key string Key text
---@param value any Value to display
---@param key_width number|nil Fixed width for key column (ignored)
function UIComponents.key_value(window, key, value, key_width)
    local display_color = color.new(200, 190, 220, 255)
    -- Verwende add_text_on_dynamic_pos für korrekte Scroll-Integration
    window:add_text_on_dynamic_pos(display_color, key .. ": " .. tostring(value))
end

-- ============================================================================
-- Progress/Status Indicators
-- ============================================================================

---Renders a horizontal progress bar as text (for scroll compatibility)
---@param window table Window reference
---@param current number Current value
---@param max number Maximum value
---@param width number|nil Bar width (ignored - using text representation)
---@param height number|nil Bar height (ignored - using text representation)
---@param fill_color table|nil Fill color
---@param bg_color table|nil Background color (ignored)
function UIComponents.progress_bar(window, current, max, width, height, fill_color, bg_color)
    fill_color = fill_color or color.new(100, 200, 150, 255)
    
    local percentage = max > 0 and math.max(0, math.min(1, current / max)) or 0
    local pct_text = string.format("%.0f%%", percentage * 100)
    
    -- Text-basierte Progress-Darstellung für Scroll-Kompatibilität (ASCII)
    local bar_width = 20
    local filled = math.floor(bar_width * percentage)
    local empty = bar_width - filled
    local bar = "[" .. string.rep("#", filled) .. string.rep("-", empty) .. "] " .. pct_text
    
    window:add_text_on_dynamic_pos(fill_color, bar)
end

---Returns a health-based color (green -> yellow -> red)
---@param health_pct number Health percentage (0-100)
---@return table color
function UIComponents.get_health_color(health_pct)
    if health_pct > 75 then
        return color.new(100, 255, 150, 255)  -- Green
    elseif health_pct > 50 then
        return color.new(255, 255, 100, 255)  -- Yellow
    elseif health_pct > 25 then
        return color.new(255, 180, 80, 255)   -- Orange
    else
        return color.new(255, 100, 120, 255)  -- Red
    end
end

---Renders a health bar with automatic color
---@param window table Window reference
---@param current number Current health
---@param max number Maximum health
---@param width number|nil Bar width
---@param height number|nil Bar height
function UIComponents.health_bar(window, current, max, width, height)
    local pct = max > 0 and (current / max * 100) or 0
    local fill_color = UIComponents.get_health_color(pct)
    UIComponents.progress_bar(window, current, max, width, height, fill_color)
end

-- ============================================================================
-- Status Indicators
-- ============================================================================

---Renders a colored status indicator dot
---@param window table Window reference
---@param is_active boolean Whether the indicator is active
---@param label string|nil Optional label text
---@param active_color table|nil Color when active
---@param inactive_color table|nil Color when inactive
function UIComponents.status_indicator(window, is_active, label, active_color, inactive_color)
    active_color = active_color or color.new(100, 255, 150, 255)
    inactive_color = inactive_color or color.new(100, 100, 100, 150)

    local indicator_color = is_active and active_color or inactive_color
    -- ASCII-kompatible Symbole
    local status_symbol = is_active and "[*] " or "[ ] "
    local label_text = label or ""
    
    -- Verwende add_text_on_dynamic_pos für korrekte Scroll-Integration
    window:add_text_on_dynamic_pos(indicator_color, status_symbol .. label_text)
end

-- ============================================================================
-- Buttons & Interactive Elements
-- ============================================================================

---Renders a styled button as text (for scroll compatibility)
---Note: Click detection is limited in text mode
---@param window table Window reference
---@param label string Button label
---@param width number|nil Button width (ignored)
---@param height number|nil Button height (ignored)
---@param bg_color table|nil Background color (ignored)
---@param text_color table|nil Text color
---@return boolean clicked (always false in text mode - use keybinds instead)
function UIComponents.button(window, label, width, height, bg_color, text_color)
    text_color = text_color or color.new(150, 130, 200, 255)
    
    -- Text-basierte Button-Darstellung für Scroll-Kompatibilität
    window:add_text_on_dynamic_pos(text_color, "[ " .. label .. " ]")
    
    -- Klick-Erkennung funktioniert nicht zuverlässig in scrollbaren Kontexten
    -- Verwende Keybinds als Alternative
    return false
end

-- ============================================================================
-- Text Helpers
-- ============================================================================

---Renders styled text
---@param window table Window reference
---@param text string Text to render
---@param text_color table|nil Text color
---@param font number|nil Font ID (ignored - add_text_on_dynamic_pos uses default font)
function UIComponents.text(window, text, text_color, font)
    text_color = text_color or color.white(255)
    -- Verwende add_text_on_dynamic_pos für korrekte Scroll-Integration
    window:add_text_on_dynamic_pos(text_color, text)
end

---Renders a title with larger font
---@param window table Window reference
---@param text string Title text
---@param text_color table|nil Text color
function UIComponents.title(window, text, text_color)
    text_color = text_color or color.new(220, 200, 255, 255)
    window:add_text_on_dynamic_pos(text_color, "> " .. string.upper(text))
end

-- ============================================================================
-- Spacing
-- ============================================================================

---Adds vertical spacing
---@param window table Window reference
---@param amount number Pixels of spacing (ignored - add_text_on_dynamic_pos handles spacing)
function UIComponents.spacing(window, amount)
    -- No-op: add_text_on_dynamic_pos fügt bereits Zeilenabstand hinzu
    -- Explizite Spacings werden ignoriert für kompaktes Layout
end

---Adds horizontal offset
---@param window table Window reference
---@param amount number Pixels of horizontal offset
function UIComponents.indent(window, amount)
    window:add_menu_element_pos_offset(vec2.new(amount, 0))
end

return UIComponents






