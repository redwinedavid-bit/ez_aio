local color = require("common/color")
local enums = require("common/enums")
local swing_timer = require("shared/swing_timer")
local resource_ticks_widget = require("shared/resource_ticks_widget")
local has_ui, rotation_settings_ui = pcall(require, "root/ext_lib_astro_ui/main")

local widgets = {}

local menu = {
    main_tree = core.menu.tree_node(),
    swing_timer_tree = core.menu.tree_node(),
    resource_ticks_tree = core.menu.tree_node(),
    
    -- We'll try to reuse some settings if possible, but these widgets handle their own internally mostly
    resource_ticks_custom_w = core.menu.slider_int(120, 600, 120, "visuals_resource_ticks_custom_w"),
    resource_ticks_custom_h = core.menu.slider_int(30, 200, 200, "visuals_resource_ticks_custom_h"),
}

local swing_timer_widget = swing_timer.new({
    id = "visuals_esp",
    label = "Swing Timer",
    menu_prefix = "visuals_swing_timer",
    parent_enabled_provider = function()
        local lp = core.object_manager.get_local_player()
        return lp and lp:get_class() == enums.class_id.HUNTER
    end,
    attack_mode = "ranged"
})

local resource_widget = resource_ticks_widget.new({
    id = "visuals_esp_swing_v2",
    label = "Resource Ticks",
    menu_prefix = "visuals_resource_ticks",
    parent_enabled_provider = function()
        local lp = core.object_manager.get_local_player()
        return lp and lp:get_class() == enums.class_id.ROGUE
    end,
    default_w = 120,
    default_h = 200
})

local function sync_resource_ticks_window_size()
    if not resource_widget or not resource_widget._size_x or not resource_widget._size_y then
        return
    end

    local ok_w, target_w = pcall(function() return menu.resource_ticks_custom_w:get() end)
    local ok_h, target_h = pcall(function() return menu.resource_ticks_custom_h:get() end)
    if not ok_w or not ok_h or target_w == nil or target_h == nil then return end

    local ok_cw, current_w = pcall(function() return resource_widget._size_x:get() end)
    local ok_ch, current_h = pcall(function() return resource_widget._size_y:get() end)
    if not ok_cw or not ok_ch or current_w == nil or current_h == nil then return end

    if current_w == target_w and current_h == target_h then return end

    if resource_widget.apply_size then
        resource_widget:apply_size(target_w, target_h)
    else
        resource_widget._size_x:set(target_w)
        resource_widget._size_y:set(target_h)
        if resource_widget._build_window then
            resource_widget:_build_window()
        end
    end
end

function widgets:on_update()
    swing_timer_widget:on_update()
    resource_widget:on_update()
    sync_resource_ticks_window_size()
end

function widgets:on_menu_render()
    menu.main_tree:render("AIO Widgets", function()
        menu.swing_timer_tree:render("Swing Timer", function()
            swing_timer_widget:on_menu_render()
        end)

        menu.resource_ticks_tree:render("Resource Ticks", function()
            resource_widget:on_menu_render()
            core.menu.header():render("Window Size", color.gray(200))
            menu.resource_ticks_custom_w:render("Width")
            menu.resource_ticks_custom_h:render("Height")
            sync_resource_ticks_window_size()
        end)
    end)
end

function widgets:on_render_window()
    -- These widgets handle their own window rendering if enabled
end

-- Restore the "Visuals / ESP" tab in the rotation settings menu
if has_ui and rotation_settings_ui and rotation_settings_ui.register_extension_tab then
    rotation_settings_ui.register_extension_tab({
        id = "visuals_esp",
        label = "Visuals / ESP"
    }, function(tab)
        tab:button({
            label = "Open Ultimate ESP Settings",
            on_click = function()
                local ok, x_esp_new = pcall(require, "shared/x_esp_new/main")
                if ok and x_esp_new and x_esp_new.toggle_settings_window then
                    x_esp_new.toggle_settings_window()
                elseif ok and x_esp_new and x_esp_new.show_settings_window then
                    x_esp_new.show_settings_window()
                end
            end
        })
    end)
end

return widgets
