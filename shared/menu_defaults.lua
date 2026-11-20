-- shared/menu_defaults.lua
-- Factory module that wraps core.menu.* constructors and tracks defaults
-- for implementing "Reset All to Defaults" functionality.

local menu_defaults = {}

--- Create a new menu defaults tracker instance.
--- Each rotation should create its own instance.
---@return table
function menu_defaults.new()
    local instance = {}
    local registry = {}

    --- Internal: register an element with its default(s)
    local function track(element, type_tag, ...)
        registry[#registry + 1] = { element = element, type_tag = type_tag, defaults = { ... } }
        return element
    end

    --- checkbox(default_state, id) -> checkbox element
    function instance.checkbox(default_state, id)
        return track(core.menu.checkbox(default_state, id), "checkbox", default_state)
    end

    --- slider_int(min, max, default, id) -> slider_int element
    function instance.slider_int(min_val, max_val, default_val, id)
        return track(core.menu.slider_int(min_val, max_val, default_val, id), "slider", default_val)
    end

    --- slider_float(min, max, default, id) -> slider_float element
    --- Includes fallback-to-slider_int logic used across the codebase.
    function instance.slider_float(min_val, max_val, default_val, id)
        local el
        if core.menu.slider_float then
            el = core.menu.slider_float(min_val, max_val, default_val, id)
        else
            el = core.menu.slider_int(
                math.floor(min_val),
                math.ceil(max_val),
                math.floor(default_val + 0.5),
                id
            )
        end
        return track(el, "slider", default_val)
    end

    --- combobox(default_index, id) -> combobox element
    function instance.combobox(default_index, id)
        return track(core.menu.combobox(default_index, id), "combobox", default_index)
    end

    --- keybind(key_code, toggle_state, id) -> keybind element
    function instance.keybind(key_code, toggle_state, id)
        return track(core.menu.keybind(key_code, toggle_state, id), "keybind", key_code, toggle_state)
    end

    --- text_input(id, save) -> text_input element (tracked with "" default)
    function instance.text_input(id, save)
        return track(core.menu.text_input(id, save), "text_input", "")
    end

    -- Pass-through (no tracking needed for non-value types):
    function instance.tree_node() return core.menu.tree_node() end
    function instance.header()    return core.menu.header() end

    --- Return the internal registry (used by the preset system).
    ---@return table[] Array of {element, type_tag, defaults}
    function instance.get_registry()
        return registry
    end

    --- Reset all tracked elements to their constructor defaults.
    function instance.reset_all()
        for i = 1, #registry do
            local e = registry[i]
            if e.type_tag == "keybind" then
                pcall(e.element.set_key, e.element, e.defaults[1])
                pcall(e.element.set_toggle_state, e.element, e.defaults[2])
            else
                pcall(e.element.set, e.element, e.defaults[1])
            end
        end
        if core and core.log then
            core.log("[Settings] All values reset to defaults.")
        end
    end

    return instance
end

return menu_defaults
