-- Edit Mode Module für Bungees Ultimate ESP 2.1
-- Verwaltet Drag & Drop und Größenänderung für UI-Elemente

local color = require("common/color")
local vec2 = require("common/geometry/vector_2")

local edit_mode_module = {}

-- Helper für vec2_new
local function vec2_new(x, y)
    return vec2.new(x, y)
end

-- Edit Mode State
local edit_mode_active = false
local edit_mode_selected_element = nil
local edit_mode_key_was_pressed = false
local edit_mode_button_was_pressed = false
local select_key_was_pressed = false
local scale_up_key_was_pressed = false
local scale_down_key_was_pressed = false

-- UI Element Definitions für Edit Mode
local edit_mode_elements = {}

-- Menu-Elemente
local menu_elements_edit_mode = {
    edit_mode = nil,
    edit_mode_key = nil,
    drag_key = nil,
    scale_up_key = nil,
    scale_down_key = nil,
    reset_all_positions = nil
}

-- Exportiere Menu-Elemente für externen Zugriff
function edit_mode_module.get_menu_elements()
    return menu_elements_edit_mode
end

-- Toggle Edit Mode (wird von Button aufgerufen)
function edit_mode_module.toggle()
    edit_mode_active = not edit_mode_active
end

-- Get Edit Mode State
function edit_mode_module.get_state()
    return edit_mode_active
end

-- Reset All Positions
function edit_mode_module.reset_all_positions()
    -- Verwende die Modul-Variable für Callbacks
    local helper_callbacks = edit_mode_module._helper_callbacks
    
    -- Debug: Prüfe ob helper_callbacks verfügbar ist
    if core and core.log then
        core.log("Edit Mode: Reset called")
        core.log("Edit Mode: helper_callbacks exists: " .. tostring(helper_callbacks ~= nil))
        if helper_callbacks then
            core.log("Edit Mode: menu_elements exists: " .. tostring(helper_callbacks.menu_elements ~= nil))
        end
    end
    
    if not helper_callbacks then
        if core and core.log then
            core.log("Edit Mode: Reset failed - helper_callbacks is nil")
        end
        return
    end
    
    if not helper_callbacks.menu_elements then
        if core and core.log then
            core.log("Edit Mode: Reset failed - menu_elements is nil")
        end
        return
    end
    
    local menu_elements = helper_callbacks.menu_elements
    
    if core and core.log then
        core.log("Edit Mode: Resetting all positions and scales...")
    end
    
    -- Health Bar Position
    if menu_elements.health_bar_pos_x and menu_elements.health_bar_pos_x.set then
        pcall(menu_elements.health_bar_pos_x.set, menu_elements.health_bar_pos_x, 50.0)
    end
    if menu_elements.health_bar_pos_y and menu_elements.health_bar_pos_y.set then
        pcall(menu_elements.health_bar_pos_y.set, menu_elements.health_bar_pos_y, 75.0)
    end
    
    -- XP Bar Position
    if menu_elements.xp_bar_pos_x and menu_elements.xp_bar_pos_x.set then
        pcall(menu_elements.xp_bar_pos_x.set, menu_elements.xp_bar_pos_x, 50.0)
    end
    if menu_elements.xp_bar_pos_y and menu_elements.xp_bar_pos_y.set then
        pcall(menu_elements.xp_bar_pos_y.set, menu_elements.xp_bar_pos_y, 2.3)
    end
    
    -- Cast Bar Position
    if menu_elements.cast_bar_pos_x and menu_elements.cast_bar_pos_x.set then
        pcall(menu_elements.cast_bar_pos_x.set, menu_elements.cast_bar_pos_x, 50.0)
    end
    if menu_elements.cast_bar_pos_y and menu_elements.cast_bar_pos_y.set then
        pcall(menu_elements.cast_bar_pos_y.set, menu_elements.cast_bar_pos_y, 80.0)
    end
    
    -- Target Bar Position
    if menu_elements.target_bar_pos_x and menu_elements.target_bar_pos_x.set then
        pcall(menu_elements.target_bar_pos_x.set, menu_elements.target_bar_pos_x, 50.0)
    end
    if menu_elements.target_bar_pos_y and menu_elements.target_bar_pos_y.set then
        pcall(menu_elements.target_bar_pos_y.set, menu_elements.target_bar_pos_y, 25.0)
    end
    
    -- Radar Position
    if menu_elements.radar_pos_x and menu_elements.radar_pos_x.set then
        pcall(menu_elements.radar_pos_x.set, menu_elements.radar_pos_x, 100.0)
    end
    if menu_elements.radar_pos_y and menu_elements.radar_pos_y.set then
        pcall(menu_elements.radar_pos_y.set, menu_elements.radar_pos_y, 100.0)
    end
    
    -- Level Warning Position
    if menu_elements.level_warning_pos_x and menu_elements.level_warning_pos_x.set then
        pcall(menu_elements.level_warning_pos_x.set, menu_elements.level_warning_pos_x, 100.0)
    end
    if menu_elements.level_warning_pos_y and menu_elements.level_warning_pos_y.set then
        pcall(menu_elements.level_warning_pos_y.set, menu_elements.level_warning_pos_y, 150.0)
    end
    
    -- Behind Warning Position
    if menu_elements.behind_warning_pos_x and menu_elements.behind_warning_pos_x.set then
        pcall(menu_elements.behind_warning_pos_x.set, menu_elements.behind_warning_pos_x, 100.0)
    end
    if menu_elements.behind_warning_pos_y and menu_elements.behind_warning_pos_y.set then
        pcall(menu_elements.behind_warning_pos_y.set, menu_elements.behind_warning_pos_y, 270.0)
    end
    
    -- Patrol Warning Position
    if menu_elements.patrol_warning_pos_x and menu_elements.patrol_warning_pos_x.set then
        pcall(menu_elements.patrol_warning_pos_x.set, menu_elements.patrol_warning_pos_x, 100.0)
    end
    if menu_elements.patrol_warning_pos_y and menu_elements.patrol_warning_pos_y.set then
        pcall(menu_elements.patrol_warning_pos_y.set, menu_elements.patrol_warning_pos_y, 380.0)
    end
    
    -- Pet Bar Position
    if menu_elements.pet_bar_pos_x and menu_elements.pet_bar_pos_x.set then
        pcall(menu_elements.pet_bar_pos_x.set, menu_elements.pet_bar_pos_x, 50.0)
    end
    if menu_elements.pet_bar_pos_y and menu_elements.pet_bar_pos_y.set then
        pcall(menu_elements.pet_bar_pos_y.set, menu_elements.pet_bar_pos_y, 85.0)
    end
    
    -- Reset Scales
    if menu_elements.health_resource_overlay_scale and menu_elements.health_resource_overlay_scale.set then
        pcall(menu_elements.health_resource_overlay_scale.set, menu_elements.health_resource_overlay_scale, 100.0)
    end
    if menu_elements.target_overlay_scale and menu_elements.target_overlay_scale.set then
        pcall(menu_elements.target_overlay_scale.set, menu_elements.target_overlay_scale, 100.0)
    end
    if menu_elements.xp_bar_overlay_scale and menu_elements.xp_bar_overlay_scale.set then
        pcall(menu_elements.xp_bar_overlay_scale.set, menu_elements.xp_bar_overlay_scale, 100.0)
    end
    if menu_elements.enemy_cast_bar_scale and menu_elements.enemy_cast_bar_scale.set then
        pcall(menu_elements.enemy_cast_bar_scale.set, menu_elements.enemy_cast_bar_scale, 100.0)
    end
    if menu_elements.player_cast_bar_scale and menu_elements.player_cast_bar_scale.set then
        pcall(menu_elements.player_cast_bar_scale.set, menu_elements.player_cast_bar_scale, 100.0)
    end
    if menu_elements.enemy_hp_bar_scale and menu_elements.enemy_hp_bar_scale.set then
        pcall(menu_elements.enemy_hp_bar_scale.set, menu_elements.enemy_hp_bar_scale, 100.0)
    end
    if menu_elements.pet_overlay_scale and menu_elements.pet_overlay_scale.set then
        pcall(menu_elements.pet_overlay_scale.set, menu_elements.pet_overlay_scale, 100.0)
    end
    if menu_elements.radar_size and menu_elements.radar_size.set then
        pcall(menu_elements.radar_size.set, menu_elements.radar_size, 250.0)
    end
end

-- Callbacks für Helper-Funktionen (werden von main.lua übergeben)
-- WICHTIG: Als Modul-Variable speichern, damit sie immer verfügbar ist
edit_mode_module._helper_callbacks = {
    load_health_bar_position = nil,
    load_target_bar_position = nil,
    load_xp_bar_position = nil,
    load_cast_bar_position = nil,
    load_pet_bar_position = nil,
    get_element_scale = nil,
    menu_elements = nil
}

-- Initialisierung
function edit_mode_module.init(menu_ref, tag_prefix, callbacks)
    if not menu_ref then
        return
    end
    
    local tag = tag_prefix or "edit_mode_"
    menu_elements_edit_mode.edit_mode = menu_ref.button(tag .. "edit_mode")
    menu_elements_edit_mode.edit_mode_key = menu_ref.keybind(999, false, tag .. "edit_mode_key")
    menu_elements_edit_mode.drag_key = menu_ref.keybind(0xA2, false, tag .. "drag_key")  -- Left Ctrl (0xA2 = VK_LCONTROL) für Drag
    menu_elements_edit_mode.scale_up_key = menu_ref.keybind(0xBB, false, tag .. "scale_up_key")  -- Plus-Taste
    menu_elements_edit_mode.scale_down_key = menu_ref.keybind(0xBD, false, tag .. "scale_down_key")  -- Minus-Taste
    menu_elements_edit_mode.reset_all_positions = menu_ref.button(tag .. "reset_all_positions")
    
    -- Speichere Callbacks direkt im Modul (damit sie immer verfügbar sind)
    if callbacks then
        -- Überschreibe die Modul-Variable
        edit_mode_module._helper_callbacks = callbacks
        if core and core.log then
            core.log("Edit Mode: Callbacks stored, menu_elements available: " .. tostring(edit_mode_module._helper_callbacks.menu_elements ~= nil))
        end
    else
        if core and core.log then
            core.log("Edit Mode: WARNING - No callbacks provided!")
        end
    end
    
    return menu_elements_edit_mode
end

-- Initialisiere Edit Mode Elemente
local function init_edit_mode_elements()
    local helper_callbacks = edit_mode_module._helper_callbacks
    
    if not helper_callbacks or not helper_callbacks.menu_elements then
        return
    end
    
    if not helper_callbacks.load_health_bar_position or 
       not helper_callbacks.load_target_bar_position or not helper_callbacks.load_xp_bar_position or
       not helper_callbacks.load_cast_bar_position or not helper_callbacks.load_pet_bar_position or
       not helper_callbacks.get_element_scale then
        return
    end
    
    local menu_elements = helper_callbacks.menu_elements
    local load_health_bar_position = helper_callbacks.load_health_bar_position
    local load_target_bar_position = helper_callbacks.load_target_bar_position
    local load_xp_bar_position = helper_callbacks.load_xp_bar_position
    local load_cast_bar_position = helper_callbacks.load_cast_bar_position
    local load_pet_bar_position = helper_callbacks.load_pet_bar_position
    local get_element_scale = helper_callbacks.get_element_scale
    
    edit_mode_elements = {
        {
            id = "health_resource_overlay",
            name = "Health & Resource Overlay",
            get_bounds = function(screen_size)
                if not menu_elements.health_resource_overlay or not menu_elements.health_resource_overlay.get_state then
                    return nil
                end
                local ok, enabled = pcall(menu_elements.health_resource_overlay.get_state, menu_elements.health_resource_overlay)
                if not ok or not enabled then
                    return nil
                end
                
                local hp_bar_x, hp_bar_y = load_health_bar_position(screen_size)
                local ui_scale = get_element_scale(menu_elements.health_resource_overlay_scale)
                local hp_bar_width = 400 * ui_scale
                local hp_bar_height = 30 * ui_scale
                local power_bar_y = hp_bar_y + hp_bar_height + 10
                
                return {
                    x = hp_bar_x - hp_bar_width * 0.5,
                    y = hp_bar_y - hp_bar_height * 0.5,
                    width = hp_bar_width,
                    height = (power_bar_y + hp_bar_height * 0.5) - (hp_bar_y - hp_bar_height * 0.5),
                    center_x = hp_bar_x,
                    center_y = hp_bar_y
                }
            end,
            set_position = function(x, y, screen_size)
                local percent_x = (x / screen_size.x) * 100.0
                local percent_y = (y / screen_size.y) * 100.0
                if menu_elements.health_bar_pos_x and menu_elements.health_bar_pos_x.set then
                    pcall(menu_elements.health_bar_pos_x.set, menu_elements.health_bar_pos_x, percent_x)
                end
                if menu_elements.health_bar_pos_y and menu_elements.health_bar_pos_y.set then
                    pcall(menu_elements.health_bar_pos_y.set, menu_elements.health_bar_pos_y, percent_y)
                end
            end,
            set_scale = function(scale)
                if menu_elements.health_resource_overlay_scale and menu_elements.health_resource_overlay_scale.set then
                    pcall(menu_elements.health_resource_overlay_scale.set, menu_elements.health_resource_overlay_scale, scale)
                end
            end,
            get_scale = function()
                return get_element_scale(menu_elements.health_resource_overlay_scale) * 100.0
            end
        },
        {
            id = "target_overlay",
            name = "Target Overlay",
            get_bounds = function(screen_size)
                if not menu_elements.target_overlay then
                    return nil
                end
                
                local ok, enabled = pcall(function()
                    return menu_elements.target_overlay:get_state()
                end)
                
                if not ok or not enabled then
                    return nil
                end
                
                local target_bar_x, target_bar_y = load_target_bar_position(screen_size)
                local ui_scale = get_element_scale(menu_elements.target_overlay_scale)
                local target_bar_width = 400 * ui_scale
                local target_bar_height = 30 * ui_scale
                local power_bar_y = target_bar_y + target_bar_height + 10
                
                return {
                    x = target_bar_x - target_bar_width * 0.5,
                    y = target_bar_y - target_bar_height * 0.5 - 30, -- Name oben
                    width = target_bar_width,
                    height = (power_bar_y + target_bar_height * 0.5) - (target_bar_y - target_bar_height * 0.5 - 30),
                    center_x = target_bar_x,
                    center_y = target_bar_y
                }
            end,
            set_position = function(x, y, screen_size)
                local percent_x = (x / screen_size.x) * 100.0
                local percent_y = (y / screen_size.y) * 100.0
                if menu_elements.target_bar_pos_x and menu_elements.target_bar_pos_x.set then
                    pcall(menu_elements.target_bar_pos_x.set, menu_elements.target_bar_pos_x, percent_x)
                end
                if menu_elements.target_bar_pos_y and menu_elements.target_bar_pos_y.set then
                    pcall(menu_elements.target_bar_pos_y.set, menu_elements.target_bar_pos_y, percent_y)
                end
            end,
            set_scale = function(scale)
                if menu_elements.target_overlay_scale and menu_elements.target_overlay_scale.set then
                    pcall(menu_elements.target_overlay_scale.set, menu_elements.target_overlay_scale, scale)
                end
            end,
            get_scale = function()
                return get_element_scale(menu_elements.target_overlay_scale) * 100.0
            end
        },
        {
            id = "pet_overlay",
            name = "Pet Health & Resource Overlay",
            get_bounds = function(screen_size)
                if not menu_elements.pet_overlay then
                    return nil
                end
                
                local ok, enabled = pcall(function()
                    return menu_elements.pet_overlay:get_state()
                end)
                
                if not ok or not enabled then
                    return nil
                end
                
                local pet_bar_x, pet_bar_y = load_pet_bar_position(screen_size)
                local ui_scale = get_element_scale(menu_elements.pet_overlay_scale)
                local pet_bar_width = 400 * ui_scale
                local pet_bar_height = 30 * ui_scale
                local power_bar_y = pet_bar_y + pet_bar_height + 10
                
                return {
                    x = pet_bar_x - pet_bar_width * 0.5,
                    y = pet_bar_y - pet_bar_height * 0.5 - 30, -- Name oben
                    width = pet_bar_width,
                    height = (power_bar_y + pet_bar_height * 0.5) - (pet_bar_y - pet_bar_height * 0.5 - 30),
                    center_x = pet_bar_x,
                    center_y = pet_bar_y
                }
            end,
            set_position = function(x, y, screen_size)
                local percent_x = (x / screen_size.x) * 100.0
                local percent_y = (y / screen_size.y) * 100.0
                if menu_elements.pet_bar_pos_x and menu_elements.pet_bar_pos_x.set then
                    pcall(menu_elements.pet_bar_pos_x.set, menu_elements.pet_bar_pos_x, percent_x)
                end
                if menu_elements.pet_bar_pos_y and menu_elements.pet_bar_pos_y.set then
                    pcall(menu_elements.pet_bar_pos_y.set, menu_elements.pet_bar_pos_y, percent_y)
                end
            end,
            set_scale = function(scale)
                if menu_elements.pet_overlay_scale and menu_elements.pet_overlay_scale.set then
                    pcall(menu_elements.pet_overlay_scale.set, menu_elements.pet_overlay_scale, scale)
                end
            end,
            get_scale = function()
                return get_element_scale(menu_elements.pet_overlay_scale) * 100.0
            end
        },
        {
            id = "xp_bar_overlay",
            name = "XP Bar Overlay",
            get_bounds = function(screen_size)
                if not menu_elements.xp_bar_overlay or not menu_elements.xp_bar_overlay.get_state then
                    return nil
                end
                local ok, enabled = pcall(menu_elements.xp_bar_overlay.get_state, menu_elements.xp_bar_overlay)
                if not ok or not enabled then
                    return nil
                end
                
                local xp_bar_x, xp_bar_y = load_xp_bar_position(screen_size)
                local ui_scale = get_element_scale(menu_elements.xp_bar_overlay_scale)
                local xp_bar_width = screen_size.x * 0.42 * ui_scale
                local xp_bar_height = 28 * ui_scale
                
                return {
                    x = xp_bar_x - xp_bar_width * 0.5,
                    y = xp_bar_y - xp_bar_height * 0.5,
                    width = xp_bar_width,
                    height = xp_bar_height,
                    center_x = xp_bar_x,
                    center_y = xp_bar_y
                }
            end,
            set_position = function(x, y, screen_size)
                local percent_x = (x / screen_size.x) * 100.0
                local percent_y = (y / screen_size.y) * 100.0
                if menu_elements.xp_bar_pos_x and menu_elements.xp_bar_pos_x.set then
                    pcall(menu_elements.xp_bar_pos_x.set, menu_elements.xp_bar_pos_x, percent_x)
                end
                if menu_elements.xp_bar_pos_y and menu_elements.xp_bar_pos_y.set then
                    pcall(menu_elements.xp_bar_pos_y.set, menu_elements.xp_bar_pos_y, percent_y)
                end
            end,
            set_scale = function(scale)
                if menu_elements.xp_bar_overlay_scale and menu_elements.xp_bar_overlay_scale.set then
                    pcall(menu_elements.xp_bar_overlay_scale.set, menu_elements.xp_bar_overlay_scale, scale)
                end
            end,
            get_scale = function()
                return get_element_scale(menu_elements.xp_bar_overlay_scale) * 100.0
            end
        },
        {
            id = "player_cast_bar",
            name = "Player Cast Bar",
            get_bounds = function(screen_size)
                if not menu_elements.show_player_cast_bar then
                    return nil
                end
                
                local ok, enabled = pcall(function()
                    return menu_elements.show_player_cast_bar:get_state()
                end)
                
                if not ok or not enabled then
                    return nil
                end
                
                -- Im Edit Mode immer Bounds zurückgeben, auch wenn nicht gezaubert wird
                local hp_bar_x, hp_bar_y = load_health_bar_position(screen_size)
                local ui_scale = get_element_scale(menu_elements.health_resource_overlay_scale)
                local hp_bar_height = 30 * ui_scale
                local cast_bar_x, cast_bar_y = load_cast_bar_position(screen_size, hp_bar_y, hp_bar_height)
                local player_cast_scale = get_element_scale(menu_elements.player_cast_bar_scale)
                local hp_bar_width = 400 * ui_scale
                local cast_bar_width = hp_bar_width * (player_cast_scale / ui_scale)
                local cast_bar_height_scaled = hp_bar_height * (player_cast_scale / ui_scale)
                
                return {
                    x = cast_bar_x - cast_bar_width * 0.5,
                    y = cast_bar_y - cast_bar_height_scaled * 0.5,
                    width = cast_bar_width,
                    height = cast_bar_height_scaled,
                    center_x = cast_bar_x,
                    center_y = cast_bar_y
                }
            end,
            set_position = function(x, y, screen_size)
                local percent_x = (x / screen_size.x) * 100.0
                local percent_y = (y / screen_size.y) * 100.0
                if menu_elements.cast_bar_pos_x and menu_elements.cast_bar_pos_x.set then
                    pcall(menu_elements.cast_bar_pos_x.set, menu_elements.cast_bar_pos_x, percent_x)
                end
                if menu_elements.cast_bar_pos_y and menu_elements.cast_bar_pos_y.set then
                    pcall(menu_elements.cast_bar_pos_y.set, menu_elements.cast_bar_pos_y, percent_y)
                end
            end,
            set_scale = function(scale)
                if menu_elements.player_cast_bar_scale and menu_elements.player_cast_bar_scale.set then
                    pcall(menu_elements.player_cast_bar_scale.set, menu_elements.player_cast_bar_scale, scale)
                end
            end,
            get_scale = function()
                return get_element_scale(menu_elements.player_cast_bar_scale) * 100.0
            end
        },
        {
            id = "2d_radar",
            name = "2D Radar",
            get_bounds = function(screen_size)
                if not menu_elements.show_radar or not menu_elements.show_radar.get_state then
                    return nil
                end
                local ok, enabled = pcall(menu_elements.show_radar.get_state, menu_elements.show_radar)
                if not ok or not enabled then
                    return nil
                end
                
                local radar_pos_x = 100.0
                local radar_pos_y = 100.0
                if menu_elements.radar_pos_x and menu_elements.radar_pos_x.get then
                    local ok_x, val_x = pcall(menu_elements.radar_pos_x.get, menu_elements.radar_pos_x)
                    if ok_x and val_x and type(val_x) == "number" then
                        radar_pos_x = val_x
                    end
                end
                if menu_elements.radar_pos_y and menu_elements.radar_pos_y.get then
                    local ok_y, val_y = pcall(menu_elements.radar_pos_y.get, menu_elements.radar_pos_y)
                    if ok_y and val_y and type(val_y) == "number" then
                        radar_pos_y = val_y
                    end
                end
                
                local radar_size = 250.0
                if menu_elements.radar_size and menu_elements.radar_size.get then
                    local ok_s, val_s = pcall(menu_elements.radar_size.get, menu_elements.radar_size)
                    if ok_s and val_s and type(val_s) == "number" then
                        radar_size = val_s
                    end
                end
                
                return {
                    x = radar_pos_x,
                    y = radar_pos_y,
                    width = radar_size,
                    height = radar_size,
                    center_x = radar_pos_x + radar_size / 2.0,
                    center_y = radar_pos_y + radar_size / 2.0
                }
            end,
            set_position = function(x, y, screen_size)
                if menu_elements.radar_pos_x and menu_elements.radar_pos_x.set then
                    pcall(menu_elements.radar_pos_x.set, menu_elements.radar_pos_x, x)
                end
                if menu_elements.radar_pos_y and menu_elements.radar_pos_y.set then
                    pcall(menu_elements.radar_pos_y.set, menu_elements.radar_pos_y, y)
                end
            end,
            set_scale = function(scale)
                -- Radar-Size als "Scale" verwenden (50-500)
                local new_size = math.max(150.0, math.min(500.0, scale))
                if menu_elements.radar_size and menu_elements.radar_size.set then
                    pcall(menu_elements.radar_size.set, menu_elements.radar_size, new_size)
                end
            end,
            get_scale = function()
                local radar_size = 250.0
                if menu_elements.radar_size and menu_elements.radar_size.get then
                    local ok, val = pcall(menu_elements.radar_size.get, menu_elements.radar_size)
                    if ok and val and type(val) == "number" then
                        radar_size = val
                    end
                end
                return radar_size
            end
        },
        -- Level Warning (In Range Warning) - Immer sichtbar im Edit Mode
        {
            id = "level_warning",
            name = "Level Warning (In Range)",
            get_bounds = function(screen_size)
                -- Im Edit Mode immer Bounds zurückgeben, auch wenn nicht aktiv
                local window_pos_x = 100.0
                local window_pos_y = 150.0
                if menu_elements.level_warning_pos_x and menu_elements.level_warning_pos_x.get then
                    local ok, val = pcall(menu_elements.level_warning_pos_x.get, menu_elements.level_warning_pos_x)
                    if ok and val and type(val) == "number" then
                        window_pos_x = val
                    end
                end
                if menu_elements.level_warning_pos_y and menu_elements.level_warning_pos_y.get then
                    local ok, val = pcall(menu_elements.level_warning_pos_y.get, menu_elements.level_warning_pos_y)
                    if ok and val and type(val) == "number" then
                        window_pos_y = val
                    end
                end
                
                -- Feste Größe für das Warning Window
                local warning_width = 230
                local warning_height = 120
                
                return {
                    x = window_pos_x,
                    y = window_pos_y,
                    width = warning_width,
                    height = warning_height,
                    center_x = window_pos_x + warning_width / 2,
                    center_y = window_pos_y + warning_height / 2
                }
            end,
            set_position = function(x, y, screen_size)
                if menu_elements.level_warning_pos_x and menu_elements.level_warning_pos_x.set then
                    pcall(menu_elements.level_warning_pos_x.set, menu_elements.level_warning_pos_x, x)
                end
                if menu_elements.level_warning_pos_y and menu_elements.level_warning_pos_y.set then
                    pcall(menu_elements.level_warning_pos_y.set, menu_elements.level_warning_pos_y, y)
                end
            end,
            set_scale = function(scale)
                -- Level Warning hat keine Scale-Funktion
            end,
            get_scale = function()
                return 100.0  -- Default, keine Scale
            end
        },
        -- Behind Warning (Behind You) - Immer sichtbar im Edit Mode
        {
            id = "behind_warning",
            name = "Behind Warning (Behind You)",
            get_bounds = function(screen_size)
                -- Im Edit Mode immer Bounds zurückgeben, auch wenn nicht aktiv
                local window_pos_x = 100.0
                local window_pos_y = 270.0
                if menu_elements.behind_warning_pos_x and menu_elements.behind_warning_pos_x.get then
                    local ok, val = pcall(menu_elements.behind_warning_pos_x.get, menu_elements.behind_warning_pos_x)
                    if ok and val and type(val) == "number" then
                        window_pos_x = val
                    end
                end
                if menu_elements.behind_warning_pos_y and menu_elements.behind_warning_pos_y.get then
                    local ok, val = pcall(menu_elements.behind_warning_pos_y.get, menu_elements.behind_warning_pos_y)
                    if ok and val and type(val) == "number" then
                        window_pos_y = val
                    end
                end
                
                -- Feste Größe für das Warning Window
                local warning_width = 230
                local warning_height = 100
                
                return {
                    x = window_pos_x,
                    y = window_pos_y,
                    width = warning_width,
                    height = warning_height,
                    center_x = window_pos_x + warning_width / 2,
                    center_y = window_pos_y + warning_height / 2
                }
            end,
            set_position = function(x, y, screen_size)
                if menu_elements.behind_warning_pos_x and menu_elements.behind_warning_pos_x.set then
                    pcall(menu_elements.behind_warning_pos_x.set, menu_elements.behind_warning_pos_x, x)
                end
                if menu_elements.behind_warning_pos_y and menu_elements.behind_warning_pos_y.set then
                    pcall(menu_elements.behind_warning_pos_y.set, menu_elements.behind_warning_pos_y, y)
                end
            end,
            set_scale = function(scale)
                -- Behind Warning hat keine Scale-Funktion
            end,
            get_scale = function()
                return 100.0  -- Default, keine Scale
            end
        },
        -- Patrol Warning - Immer sichtbar im Edit Mode
        {
            id = "patrol_warning",
            name = "Patrol Warning",
            get_bounds = function(screen_size)
                -- Im Edit Mode immer Bounds zurückgeben, auch wenn nicht aktiv
                local window_pos_x = 100.0
                local window_pos_y = 380.0
                if menu_elements.patrol_warning_pos_x and menu_elements.patrol_warning_pos_x.get then
                    local ok, val = pcall(menu_elements.patrol_warning_pos_x.get, menu_elements.patrol_warning_pos_x)
                    if ok and val and type(val) == "number" then
                        window_pos_x = val
                    end
                end
                if menu_elements.patrol_warning_pos_y and menu_elements.patrol_warning_pos_y.get then
                    local ok, val = pcall(menu_elements.patrol_warning_pos_y.get, menu_elements.patrol_warning_pos_y)
                    if ok and val and type(val) == "number" then
                        window_pos_y = val
                    end
                end
                
                -- Feste Größe für das Warning Window
                local warning_width = 230
                local warning_height = 100
                
                return {
                    x = window_pos_x,
                    y = window_pos_y,
                    width = warning_width,
                    height = warning_height,
                    center_x = window_pos_x + warning_width / 2,
                    center_y = window_pos_y + warning_height / 2
                }
            end,
            set_position = function(x, y, screen_size)
                if menu_elements.patrol_warning_pos_x and menu_elements.patrol_warning_pos_x.set then
                    pcall(menu_elements.patrol_warning_pos_x.set, menu_elements.patrol_warning_pos_x, x)
                end
                if menu_elements.patrol_warning_pos_y and menu_elements.patrol_warning_pos_y.set then
                    pcall(menu_elements.patrol_warning_pos_y.set, menu_elements.patrol_warning_pos_y, y)
                end
            end,
            set_scale = function(scale)
                -- Patrol Warning hat keine Scale-Funktion
            end,
            get_scale = function()
                return 100.0  -- Default, keine Scale
            end
        }
    }
end

-- Hole Cursor Position (korrekte API)
local function get_cursor_position()
    if not core or not core.get_cursor_position then
        return nil
    end
    
    local ok, cursor_pos = pcall(core.get_cursor_position)
    if ok and cursor_pos and cursor_pos.x and cursor_pos.y then
        return cursor_pos
    end
    
    return nil
end

-- Prüfe ob Punkt in Bounds ist
local function is_point_in_bounds(x, y, bounds)
    if not bounds then return false end
    return x >= bounds.x and x <= bounds.x + bounds.width and
           y >= bounds.y and y <= bounds.y + bounds.height
end

-- Render Edit Mode Overlay
function edit_mode_module.render()
    if not core or not core.graphics then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- Debug: Zeige "Edit Mode" Text wenn aktiv (ESP Theme)
    if edit_mode_active then
        if core.graphics and core.graphics.text_2d then
            pcall(core.graphics.text_2d, "EDIT MODE ACTIVE", vec2_new(50, 50), 20, color.new(0, 200, 220, 255), false)
        end
    else
        return
    end
    
    -- Initialisiere Elemente wenn nötig
    if #edit_mode_elements == 0 then
        init_edit_mode_elements()
    end
    
    -- Render Grid für bessere Positionierung (ESP Theme)
    if core.graphics and core.graphics.line_2d then
        local grid_size = 50  -- Grid-Abstand in Pixeln
        local grid_color = color.new(0, 150, 170, 80)  -- ESP Theme Cyan Grid
        local grid_thickness = 1.5  -- Etwas dicker
        
        -- Vertikale Linien
        for x = 0, screen_size.x, grid_size do
            pcall(core.graphics.line_2d,
                vec2_new(x, 0),
                vec2_new(x, screen_size.y),
                grid_color,
                grid_thickness
            )
        end
        
        -- Horizontale Linien
        for y = 0, screen_size.y, grid_size do
            pcall(core.graphics.line_2d,
                vec2_new(0, y),
                vec2_new(screen_size.x, y),
                grid_color,
                grid_thickness
            )
        end
    end
    
    -- Debug: Zeige Anzahl der Elemente (ESP Theme)
    if core.graphics and core.graphics.text_2d then
        local debug_text = string.format("Elements: %d", #edit_mode_elements)
        pcall(core.graphics.text_2d, debug_text, vec2_new(50, 80), 16, color.new(180, 190, 200, 255), false)
    end
    
    -- Wenn keine Elemente initialisiert wurden, abbrechen
    if #edit_mode_elements == 0 then
        if core.graphics and core.graphics.text_2d then
            pcall(core.graphics.text_2d, "NO ELEMENTS INITIALIZED", vec2_new(50, 100), 16, color.new(255, 100, 100, 255), false)
        end
        return
    end
    
    local cursor_pos = get_cursor_position()
    if not cursor_pos then
        return
    end
    
    local hovered_element = nil
    local selected_bounds = nil
    local found_bounds_count = 0
    
    -- Finde hovered und selected Elemente
    for _, element in ipairs(edit_mode_elements) do
        local bounds = element.get_bounds(screen_size)
        if bounds then
            found_bounds_count = found_bounds_count + 1
            if is_point_in_bounds(cursor_pos.x, cursor_pos.y, bounds) then
                hovered_element = element
            end
            if edit_mode_selected_element and edit_mode_selected_element.id == element.id then
                selected_bounds = bounds
            end
        end
    end
    
    -- Render Anleitungs-Popup wenn Edit Mode aktiv ist
    if core.graphics and core.graphics.text_2d and core.graphics.rect_2d_filled then
        local popup_x = screen_size.x - 400
        local popup_y = screen_size.y - 350  -- Weiter runter
        local popup_width = 380  -- Größer
        local popup_height = 280  -- Größer
        
        -- Hintergrund (ESP Theme)
        pcall(core.graphics.rect_2d_filled,
            vec2_new(popup_x, popup_y),
            popup_width,
            popup_height,
            color.new(28, 30, 35, 245),
            8.0
        )
        
        -- Border (ESP Theme Cyan)
        if core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(popup_x, popup_y),
                popup_width,
                popup_height,
                color.new(0, 180, 200, 255),
                2.0,
                8.0
            )
        end
        
        -- Titel (ESP Theme Cyan)
        pcall(core.graphics.text_2d, "EDIT MODE ACTIVE", vec2_new(popup_x + 15, popup_y + 15), 20, color.new(0, 200, 220, 255), false)
        
        -- Anleitung
        local line_y = popup_y + 45
        local line_height = 20
        local instructions = {
            "1. Hover over UI element",
            "2. Hold CTRL to drag",
            "3. Move mouse to reposition",
            "4. Release CTRL to drop",
            "5. Use +/- to scale",
            "",
            "Elements: Health Bar, Target,",
            "XP Bar, Cast Bar, Pet Bar,",
            "2D Radar, Level Warning,",
            "Behind Warning, Patrol Warning"
        }
        
        for i, instruction in ipairs(instructions) do
            pcall(core.graphics.text_2d, instruction, vec2_new(popup_x + 15, line_y), 14, color.new(180, 190, 200, 255), false)
            line_y = line_y + line_height
        end
    end
    
    -- Debug: Zeige gefundene Bounds und Selected-Status (ESP Theme)
    if core.graphics and core.graphics.text_2d then
        local bounds_text = string.format("Found Bounds: %d", found_bounds_count)
        pcall(core.graphics.text_2d, bounds_text, vec2_new(50, 110), 16, color.new(180, 190, 200, 255), false)
        
        if edit_mode_selected_element then
            pcall(core.graphics.text_2d, "Selected: " .. edit_mode_selected_element.name, vec2_new(50, 130), 14, color.new(0, 200, 220, 255), false)
            pcall(core.graphics.text_2d, "Release CTRL to drop", vec2_new(50, 150), 12, color.new(100, 110, 120, 255), false)
        end
    end
    
    -- Render Highlight für alle Elemente (ESP Theme)
    for _, element in ipairs(edit_mode_elements) do
        local bounds = element.get_bounds(screen_size)
        if bounds then
            local is_selected = edit_mode_selected_element and edit_mode_selected_element.id == element.id
            local is_hovered = hovered_element and hovered_element.id == element.id
            
            local highlight_color = nil
            if is_selected then
                highlight_color = color.new(0, 200, 220, 220)  -- Cyan für selected
            elseif is_hovered then
                highlight_color = color.new(100, 220, 255, 180)  -- Helles Cyan für hovered
            else
                highlight_color = color.new(0, 150, 170, 120)  -- Dunkleres Cyan für normal
            end
            
            -- Render Highlight Border (4 Linien für bessere Sichtbarkeit)
            if core.graphics and core.graphics.line_2d then
                local thickness = 3.0
                -- Obere Linie
                pcall(core.graphics.line_2d, 
                    vec2_new(bounds.x, bounds.y), 
                    vec2_new(bounds.x + bounds.width, bounds.y), 
                    highlight_color, 
                    thickness
                )
                -- Untere Linie
                pcall(core.graphics.line_2d, 
                    vec2_new(bounds.x, bounds.y + bounds.height), 
                    vec2_new(bounds.x + bounds.width, bounds.y + bounds.height), 
                    highlight_color, 
                    thickness
                )
                -- Linke Linie
                pcall(core.graphics.line_2d, 
                    vec2_new(bounds.x, bounds.y), 
                    vec2_new(bounds.x, bounds.y + bounds.height), 
                    highlight_color, 
                    thickness
                )
                -- Rechte Linie
                pcall(core.graphics.line_2d, 
                    vec2_new(bounds.x + bounds.width, bounds.y), 
                    vec2_new(bounds.x + bounds.width, bounds.y + bounds.height), 
                    highlight_color, 
                    thickness
                )
            end
            
            -- Render Element Name (ESP Theme)
            if core.graphics and core.graphics.text_2d then
                local name_color = is_selected and color.new(0, 200, 220, 255) or color.new(180, 190, 200, 220)
                local name_x = bounds.x + bounds.width * 0.5
                local name_y = bounds.y - 20
                pcall(core.graphics.text_2d, element.name, vec2_new(name_x, name_y), 14, name_color, true)
            end
        end
    end
    
    -- Render Scale Info für selected Element (ESP Theme)
    if edit_mode_selected_element and selected_bounds then
        local scale = edit_mode_selected_element.get_scale()
        local scale_text = string.format("Scale: %.0f%% (Use +/- to adjust)", scale)
        if core.graphics and core.graphics.text_2d then
            local info_x = selected_bounds.x + selected_bounds.width * 0.5
            local info_y = selected_bounds.y + selected_bounds.height + 5
            pcall(core.graphics.text_2d, scale_text, vec2_new(info_x, info_y), 12, color.new(100, 220, 255, 255), true)
        end
    end
end

-- Update Edit Mode Logic
function edit_mode_module.update()
    local helper_callbacks = edit_mode_module._helper_callbacks
    
    -- Prüfe ob Haupt-Script aktiv ist
    local main_script_enabled = true
    if helper_callbacks and helper_callbacks.menu_elements then
        local menu_elements = helper_callbacks.menu_elements
        
        -- Prüfe Checkbox
        local checkbox_enabled = true
        if menu_elements.enabled and menu_elements.enabled.get_state then
            local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
            if ok and val ~= nil then
                checkbox_enabled = val
            end
        end
        
        -- Prüfe Toggle-Key
        local toggle_enabled = true
        if menu_elements.toggle_key and menu_elements.toggle_key.get_toggle_state then
            local ok, val = pcall(menu_elements.toggle_key.get_toggle_state, menu_elements.toggle_key)
            if ok and val ~= nil then
                toggle_enabled = val
            end
        end
        
        -- Beide müssen aktiv sein!
        main_script_enabled = checkbox_enabled and toggle_enabled
    end
    
    -- Deaktiviere Edit Mode wenn Haupt-Script deaktiviert ist
    if not main_script_enabled then
        edit_mode_active = false
        edit_mode_selected_element = nil
        return
    end
    
    -- Prüfe Keybind (Toggle-Modus - nur bei Key-Press)
    if menu_elements_edit_mode.edit_mode_key and menu_elements_edit_mode.edit_mode_key.get_toggle_state then
        local ok, key_pressed = pcall(menu_elements_edit_mode.edit_mode_key.get_toggle_state, menu_elements_edit_mode.edit_mode_key)
        if ok and key_pressed then
            -- Toggle nur wenn Key gerade gedrückt wurde (nicht dauerhaft)
            -- Wir müssen einen State-Tracker verwenden, um zu verhindern, dass es jeden Frame togglet
            if not edit_mode_key_was_pressed then
                edit_mode_active = not edit_mode_active
            end
            edit_mode_key_was_pressed = true
        else
            edit_mode_key_was_pressed = false
        end
    end
    
    if not edit_mode_active then
        edit_mode_selected_element = nil
        return
    end
    
    
    if not core or not core.graphics then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- Initialisiere Elemente wenn nötig
    if #edit_mode_elements == 0 then
        init_edit_mode_elements()
    end
    
    local cursor_pos = get_cursor_position()
    if not cursor_pos then
        return
    end
    
    -- Finde Element unter Cursor
    local element_under_cursor = nil
    for _, element in ipairs(edit_mode_elements) do
        local bounds = element.get_bounds(screen_size)
        if bounds and is_point_in_bounds(cursor_pos.x, cursor_pos.y, bounds) then
            element_under_cursor = element
            break
        end
    end
    
    -- Auswahl-Taste (CTRL) - Direkte Input-Abfrage für zuverlässiges Hold-to-Drag
    local select_pressed = false
    
    -- Hole den konfigurierten Key-Code (Standard: 0xA2 = Left Ctrl)
    local drag_key_code = 0xA2  -- VK_LCONTROL
    if menu_elements_edit_mode.drag_key then
        local ok_get, key_code = pcall(function()
            return menu_elements_edit_mode.drag_key:get()
        end)
        if ok_get and key_code and key_code ~= 0 then
            drag_key_code = key_code
        end
    end
    
    -- Prüfe direkt über core.input ob die Taste gedrückt ist
    local input_api_available = core and core.input and core.input.is_key_pressed
    
    if input_api_available then
        local ok, is_pressed = pcall(core.input.is_key_pressed, drag_key_code)
        if ok and is_pressed then
            select_pressed = true
        end
        
        -- Auch CTRL rechts (0xA3) und beide CTRL (0x11) prüfen
        if not select_pressed then
            local ok2, is_pressed2 = pcall(core.input.is_key_pressed, 0xA3)  -- VK_RCONTROL
            if ok2 and is_pressed2 then select_pressed = true end
        end
        if not select_pressed then
            local ok3, is_pressed3 = pcall(core.input.is_key_pressed, 0x11)  -- VK_CONTROL (both)
            if ok3 and is_pressed3 then select_pressed = true end
        end
    end
    
    -- Hold-basiert: Element wird gehalten solange CTRL gedrückt ist
    if select_pressed then
        -- Wenn nichts selected und Element unter Cursor -> aufnehmen
        if not edit_mode_selected_element and element_under_cursor then
            edit_mode_selected_element = element_under_cursor
        end
        -- Bleibt selected solange gedrückt
    else
        -- CTRL losgelassen -> fallen lassen
        edit_mode_selected_element = nil
    end
    
    -- Bewegung: Element folgt immer dem Cursor (kein Drag-State nötig!)
    if edit_mode_selected_element then
        -- Clamp to screen bounds
        local new_x = math.max(0, math.min(screen_size.x, cursor_pos.x))
        local new_y = math.max(0, math.min(screen_size.y, cursor_pos.y))
        
        -- Update Position direkt zum Cursor
        edit_mode_selected_element.set_position(new_x, new_y, screen_size)
    end
    
    -- Handle Scale (Plus/Minus) - über Keybinds mit Edge-Detection
    -- PLUS
    local plus_pressed = false
    if menu_elements_edit_mode.scale_up_key and menu_elements_edit_mode.scale_up_key.get_state then
        local ok, state = pcall(function()
            return menu_elements_edit_mode.scale_up_key:get_state()
        end)
        if ok and state then
            plus_pressed = true
        end
    end
    
    if plus_pressed and not scale_up_key_was_pressed and edit_mode_selected_element then
        local current_scale = edit_mode_selected_element.get_scale()
        local new_scale = math.min(200.0, current_scale + 5.0)
        edit_mode_selected_element.set_scale(new_scale)
    end
    scale_up_key_was_pressed = plus_pressed
    
    -- MINUS
    local minus_pressed = false
    if menu_elements_edit_mode.scale_down_key and menu_elements_edit_mode.scale_down_key.get_state then
        local ok, state = pcall(function()
            return menu_elements_edit_mode.scale_down_key:get_state()
        end)
        if ok and state then
            minus_pressed = true
        end
    end
    
    if minus_pressed and not scale_down_key_was_pressed and edit_mode_selected_element then
        local current_scale = edit_mode_selected_element.get_scale()
        local new_scale = math.max(50.0, current_scale - 5.0)
        edit_mode_selected_element.set_scale(new_scale)
    end
    scale_down_key_was_pressed = minus_pressed
end

-- Prüft ob Edit Mode aktiv ist
function edit_mode_module.is_active()
    return edit_mode_active
end

-- Render Edit Mode Window (für Maus-Interaktionen über Custom UI)
function edit_mode_module.render_window()
    if not edit_mode_active or not edit_mode_window then
        return
    end
    
    if not core or not core.graphics then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- Rendere unsichtbares Window über dem gesamten Bildschirm
    -- Dies ermöglicht Maus-Interaktionen über window:is_rect_clicked()
    if edit_mode_window.begin then
        local ok = pcall(function()
            -- Window begin (unsichtbar, transparent)
            edit_mode_window:begin("Edit Mode Overlay")
            
            -- Setze End-Called State (wichtig für Custom UI)
            if edit_mode_window.set_end_called_state then
                edit_mode_window:set_end_called_state()
            end
        end)
    end
end

return edit_mode_module

