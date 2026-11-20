local __object_safety=require("shared/object_safety")
-- Bungee x Astro AIO entrypoint

---@type color
local color = require("common/color")

local widgets = require("shared/widgets")
local fishing_bot = require("shared/fishing_bot")
local resource_ticks = require("shared/resource_ticks")
local rotation_registry = require("rotations/registry")
local rotation_pause = require("shared/rotation_pause")

-- Initialize new ESP module
require("shared/x_esp_new/main")

local active_rotation = nil
local active_class_id = nil
local missing_rotation_logged = {}

---@param local_player game_object|nil
---@return table|nil
local function resolve_rotation(local_player)
    if not __object_safety.valid(local_player) then
        return nil
    end

    local class_id = local_player:get_class()
    if class_id == active_class_id and active_rotation then
        return active_rotation
    end

    active_class_id = class_id
    active_rotation = rotation_registry:resolve(local_player)

    return active_rotation
end

local function on_update()
    local local_player = core.object_manager.get_local_player()
    if not __object_safety.valid(local_player) then
        return
    end

    resource_ticks.get():on_update(local_player)

    local rotation = resolve_rotation(local_player)
    widgets:on_update()
    if local_player:is_mounted() then
        if rotation and rotation.allow_while_mounted and rotation.on_update then
            rotation:on_update(local_player)
        end
        return
    end

    if rotation_pause.is_eating_or_drinking(local_player) then
        return
    end

    fishing_bot:on_update(local_player)

    if rotation and rotation.on_update then
        rotation:on_update(local_player)
    end
end

local function on_render()
    local local_player = core.object_manager.get_local_player()
    if not __object_safety.valid(local_player) then
        return
    end

    -- x_esp_new handles its own world rendering via self-registration
end

local function on_render_window()
    local local_player = core.object_manager.get_local_player()

    local rotation = resolve_rotation(local_player)
    if rotation and rotation.on_render then
        rotation:on_render(local_player)
    end

    -- widgets:on_render_window() -- Currently empty as they handle their own windows
end

local function on_menu_render()
    widgets:on_menu_render()
    fishing_bot:on_menu_render()

    local local_player = core.object_manager.get_local_player()
    local rotation = resolve_rotation(local_player)
    if rotation and rotation.on_menu_render then
        rotation:on_menu_render()
        return
    end

    local class_id = local_player and local_player:get_class() or nil
    if class_id and not missing_rotation_logged[class_id] then
        missing_rotation_logged[class_id] = true
        core.log_error("[AIO] No rotation available for this class yet.")
    end

    core.menu.header():render("No rotation available for this class yet", color.red(200))
end

local function on_control_panel_render()
    local local_player = core.object_manager.get_local_player()
    local rotation = resolve_rotation(local_player)
    if rotation and rotation.on_control_panel_render then
        return rotation:on_control_panel_render()
    end

    return {}
end

core.register_on_update_callback(__object_safety.callback(on_update,"main.lua:115"))
core.register_on_render_callback(__object_safety.callback(on_render,"main.lua:116"))
core.register_on_render_menu_callback(__object_safety.callback(on_menu_render,"main.lua:117"))
core.register_on_render_control_panel_callback(__object_safety.callback(on_control_panel_render,"main.lua:118",{}))

if core.register_on_render_window_callback then
    core.register_on_render_window_callback(__object_safety.callback(on_render_window,"main.lua:121"))
end
