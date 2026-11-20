local __object_safety=require("shared/object_safety")
-- Resource Tick + 5SR Widget (Custom UI window)

---@type color
local color = require("common/color")

---@type enums
local enums = require("common/enums")

---@type vec2
local vec2 = require("common/geometry/vector_2")

local ticks_api = require("shared/resource_ticks")

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

local function menu_color_picker(default_color, id)
    if core.menu.color_picker then
        return core.menu.color_picker(default_color, id)
    end
    if core.menu.colorpicker then
        return core.menu.colorpicker(default_color, id)
    end
    if core.menu.new_colorpicker then
        return core.menu.new_colorpicker(default_color, id)
    end
    return nil
end

local function format_ms(ms)
    if not ms or ms <= 0 then
        return "0.00s"
    end
    return string.format("%.2fs", ms / 1000)
end

---@class resource_ticks_widget
---@field id string
---@field label string
---@field window any
---@field enable_window boolean
---@field window_bg_color color
---@field window_border_color color
---@field menu table
---@field _pos_x any
---@field _pos_y any
---@field _size_x any
---@field _size_y any
---@field _parent_enabled_provider fun(): boolean|nil
---@field _size_provider fun(): vec2|{x:number,y:number}|nil
---@field _force_size vec2|{x:number,y:number}|nil
---@field _window_epoch integer
---@field _window_title string
---@field _window_id_base string
---@field _window_id string
local Widget = {}
Widget.__index = Widget

function Widget:_is_enabled()
    if self.menu and self.menu.enable and not self.menu.enable:get_state() then
        return false
    end
    if self._parent_enabled_provider and not self._parent_enabled_provider() then
        return false
    end
    return true
end

function Widget:_build_window()
    self._window_epoch = (self._window_epoch or 0) + 1
    self._window_id = string.format("%s##%s##%d", tostring(self._window_title), tostring(self.id), self._window_epoch)
    self.window = core.menu.window(self._window_id)

    if self._pos_x and self._pos_y then
        self.window:set_initial_position(vec2.new(self._pos_x:get(), self._pos_y:get()))
    end
    if self._size_x and self._size_y then
        if self._force_size and self._force_size.x and self._force_size.y then
            self._size_x:set(self._force_size.x)
            self._size_y:set(self._force_size.y)
        end
        self.window:set_initial_size(vec2.new(self._size_x:get(), self._size_y:get()))
    end
end

function Widget:_sync_window_state()
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

function Widget:_render_window()
    if not self:_is_enabled() then
        return
    end

    if not self.window then
        self:_build_window()
    end

    local ticks = ticks_api.get()
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end

    if self.menu.only_in_combat and self.menu.only_in_combat:get_state() then
        local ok, in_combat = pcall(function()
            return local_player:is_in_combat()
        end)
        if ok and in_combat ~= true then
            return
        end
    end

    local show_energy = self.menu.show_energy and self.menu.show_energy:get_state()
    local show_mana = self.menu.show_mana and self.menu.show_mana:get_state()
    local show_fsr = self.menu.show_fsr and self.menu.show_fsr:get_state()

    local bar_count = 0
    if show_energy then bar_count = bar_count + 1 end
    if show_mana then bar_count = bar_count + 1 end
    if show_fsr then bar_count = bar_count + 1 end
    if bar_count == 0 then
        show_energy = true
        bar_count = 1
    end

    local bg_color = self.window_bg_color
    local border_color = self.window_border_color
    local text_color = self.menu.text_color and self.menu.text_color:get() or color.white(230)

    local energy_bar_color = self.menu.energy_bar_color and self.menu.energy_bar_color:get() or color.green(220)
    local mana_bar_color = self.menu.mana_bar_color and self.menu.mana_bar_color:get() or color.cyan(220)
    local fsr_bar_color = self.menu.fsr_bar_color and self.menu.fsr_bar_color:get() or color.red(220)
    local bar_bg = self.menu.bar_bg_color and self.menu.bar_bg_color:get() or color.gray(60)

    self.window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_WIDTH,
        false,
        bg_color,
        border_color,
        enums.window_enums.window_cross_visuals.NO_BACKGROUND_AND_NO_BORDER,
        function()
            self:_sync_window_state()

            local size = self.window:get_size()
            local padding = 8
            local header_height = 0

            if self.menu.show_label and self.menu.show_label:get_state() then
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(padding, 4), text_color, self.label)
                header_height = 12
            end

            local content_top = padding + header_height
            local available_h = math.max(10, size.y - content_top - padding)
            local gap = 6
            local total_gap = gap * math.max(0, bar_count - 1)
            local bar_h = math.max(8, (available_h - total_gap) / bar_count)
            local bar_w = math.max(40, size.x - (padding * 2))

            local y = content_top

            local function draw_bar(label, progress, right_text, fg)
                local bar_start = vec2.new(padding, y)
                local bar_end = vec2.new(padding + bar_w, y + bar_h)
                self.window:render_rect_filled(bar_start, bar_end, bar_bg, 1.0)

                local fill_w = bar_w * (progress or 0)
                if fill_w > 0 then
                    local fill_end = vec2.new(bar_start.x + fill_w, bar_end.y)
                    self.window:render_rect_filled(bar_start, fill_end, fg, 1.0)
                end

                self.window:render_rect(bar_start, bar_end, text_color, 1.0, 1.0)

                if self.menu.show_time and self.menu.show_time:get_state() then
                    self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(padding + 2, y - 2), text_color, label)
                    local text_size = self.window:get_text_size(right_text or "")
                    local tx = math.max(padding + 2, size.x - padding - text_size.x)
                    self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(tx, y - 2), text_color, right_text or "")
                end

                y = y + bar_h + gap
            end

            if show_energy then
                draw_bar("Energy Tick", ticks:energy_progress_01(), format_ms(ticks:energy_ms_to_next_tick()), energy_bar_color)
            end
            if show_mana then
                draw_bar("Mana Tick", ticks:mana_progress_01(), format_ms(ticks:mana_ms_to_next_tick()), mana_bar_color)
            end
            if show_fsr then
                draw_bar("5SR", ticks:fsr_progress_01(), format_ms(ticks:fsr_remaining_ms()), fsr_bar_color)
            end
        end
    )
end

function Widget:on_update()
    -- Library is updated centrally (main.lua). Widget stays read-only.
end

function Widget:on_menu_render()
    if not self.menu then
        return
    end

    self.menu.enable:render("Enable Resource Tick Window")
    self.menu.only_in_combat:render("Only In Combat")
    self.menu.show_label:render("Show Label")
    self.menu.show_time:render("Show Timers")

    self.menu.show_energy:render("Show Energy Tick")
    self.menu.show_mana:render("Show Mana Tick")
    self.menu.show_fsr:render("Show 5SR")

    self.menu.bar_bg_color:render("Bar Background")
    self.menu.text_color:render("Text/Border Color")
    self.menu.energy_bar_color:render("Energy Bar Color")
    self.menu.mana_bar_color:render("Mana Bar Color")
    self.menu.fsr_bar_color:render("5SR Bar Color")
end

---@param w number
---@param h number
function Widget:apply_size(w, h)
    if type(w) ~= "number" or type(h) ~= "number" then
        return
    end
    if self._size_x then
        self._size_x:set(math.floor(w + 0.5))
    end
    if self._size_y then
        self._size_y:set(math.floor(h + 0.5))
    end
    self._force_size = { x = math.floor(w + 0.5), y = math.floor(h + 0.5) }
    self:_build_window()
end

local api = {}

---@param opts table|nil
---@return resource_ticks_widget
function api.new(opts)
    opts = opts or {}

    local self = setmetatable({}, Widget)
    self.id = opts.id or "resource_ticks"
    self.label = opts.label or "Resource Ticks"
    self.enable_window = opts.enable_window ~= false
    self.window_bg_color = opts.window_bg_color or color.new(0, 0, 0, 120)
    self.window_border_color = opts.window_border_color or color.new(0, 0, 0, 160)
    self._parent_enabled_provider = opts.parent_enabled_provider
    self._size_provider = opts.size_provider
    self._force_size = opts.force_size
    self._window_epoch = 0
    self._window_title = opts.window_id or self.label

    local menu_prefix = opts.menu_prefix or ("resource_ticks_" .. self.id)
    self.menu = {
        enable = core.menu.checkbox(true, menu_prefix .. "_enable"),
        only_in_combat = core.menu.checkbox(false, menu_prefix .. "_only_in_combat"),
        show_label = core.menu.checkbox(true, menu_prefix .. "_show_label"),
        show_time = core.menu.checkbox(true, menu_prefix .. "_show_time"),
        show_energy = core.menu.checkbox(true, menu_prefix .. "_show_energy"),
        show_mana = core.menu.checkbox(false, menu_prefix .. "_show_mana"),
        show_fsr = core.menu.checkbox(false, menu_prefix .. "_show_fsr"),
        bar_bg_color = menu_color_picker(color.gray(60), menu_prefix .. "_bar_bg"),
        text_color = menu_color_picker(color.white(230), menu_prefix .. "_text_color"),
        energy_bar_color = menu_color_picker(color.green(220), menu_prefix .. "_energy_color"),
        mana_bar_color = menu_color_picker(color.cyan(220), menu_prefix .. "_mana_color"),
        fsr_bar_color = menu_color_picker(color.red(220), menu_prefix .. "_fsr_color")
    }

    -- Match Swing Timer defaults for consistent visuals.
    self._pos_x = menu_slider_int(0, 5000, opts.default_x or 600, menu_prefix .. "_pos_x")
    self._pos_y = menu_slider_int(0, 5000, opts.default_y or 520, menu_prefix .. "_pos_y")
    self._size_x = menu_slider_int(120, 600, opts.default_w or 240, menu_prefix .. "_size_x")
    self._size_y = menu_slider_int(30, 200, opts.default_h or 50, menu_prefix .. "_size_y")

    self:_build_window()

    if self.enable_window then
        core.register_on_render_window_callback(__object_safety.callback(function()
            self:_render_window()
        end,"shared/resource_ticks_widget.lua:332"))
    end

    return self
end

return api
