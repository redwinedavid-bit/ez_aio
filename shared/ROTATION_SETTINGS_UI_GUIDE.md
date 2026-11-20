# Rotation Settings UI Library Guide

This library lets you turn your rotation settings into a shared, tabbed custom window that feels tight and stable. It handles the window itself, tab state, keyboard/mouse input for sliders and keybinds, and saves position + size between injections.

## What it gives you

- A movable, resizable window with themeable colors.
- A tab bar where each tab can host keybind rows, checkbox grids, slider lists, and combo dropdowns.
- Visual guards that block window dragging when you interact with widgets.
- Persisted window position, size, tab index, and visibility via hidden ghost menu elements.
- A consistent keybind capture flow with a clear/escape prompt and restricted mouse support (everything except LMB/RMB is allowed).

## Step-by-step (the shortest path)

1. **Create your menu elements** in your rotation module (`core.menu.checkbox`, `core.menu.slider_int`, `core.menu.combobox`, `core.menu.keybind`).
2. **Instantiate the UI window** once:

```lua
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")
local ui = rotation_settings_ui.new({
  id = "my_rotation",
  title = "My Rotation Settings",
  default_x = 700,
  default_y = 200,
  default_w = 520,
  default_h = 640,
  theme = "neutral"
})
```

3. **Add helper closures** for `visible_when` checks so the UI stays in sync with the menu state (e.g. `local function auto_pot_enabled() return menu_elements.auto_pot_enabled:get_state() end`).
4. **Build tabs using the builder API** (`ui:add_tab`). Each tab callback receives a builder that can emit rows, grids, and lists.
5. **Hook the UI** into your rotation:

```lua
function my_rotation:on_menu_render()
  ui:on_menu_render()
  -- render your normal menu tree here
end

function my_rotation:on_render()
  ui:on_render()
end
```

## Example layout snippet

```lua
local function slider_entry(element, label, suffix, min_value, max_value, visible_when)
  local entry = {
    element = element,
    label = label,
    suffix = suffix or "",
    visible_when = visible_when
  }
  if min_value or max_value then
    entry.bounds = {}
    if min_value then entry.bounds.min = min_value end
    if max_value then entry.bounds.max = max_value end
  end
  return entry
end

ui:add_tab({ id = "survival", label = "Survival" }, function(tab)
  tab:checkbox_grid({
    label = "Consumables",
    columns = 2,
    elements = {
      { element = menu_elements.auto_pot_enabled, label = "Auto Potion" },
      { element = menu_elements.auto_healthstone_enabled, label = "Auto Healthstone" }
    }
  })

  tab:slider_list({
    label = "Thresholds",
    elements = {
      slider_entry(menu_elements.auto_pot_threshold, "Potion HP%", "%", 0, 100, auto_pot_enabled),
      slider_entry(menu_elements.auto_healthstone_threshold, "Healthstone HP%", "%", 0, 100, auto_healthstone_enabled)
    }
  })
end)
```

## Builder API reference

- `ui:add_tab(tab_info, build_fn)` creates or replaces a tab. `tab_info` must include `id` and `label`; `visible_when` can hide the tab.
- `t:keybind_grid(opts)` renders rows with key badges, labels, toggles, and a “Clear” button. Pass `elements` (keybind objects) and optional `labels`.
- `t:checkbox_grid(opts)` lays out checkbox + toggle entries. `columns` defaults to 2; each `elements` entry can include `element`, `label`, and `visible_when`.
- `t:slider_list(opts)` renders sliders; each entry can specify `element`, `label`, `suffix` (“%”, “ms”, “yd”, etc.), `visible_when`, and optional bounds via `bounds`, `min`, or `max`.
- `t:combo_list(opts)` drops down combo boxes. Entries require `element`, `label`, `options` (string array), plus optional `visible_when`.

## Slider bounds and suffixes

Sliders default to `0–100`, so you must tell the UI what range the menu widget actually exposes when it differs (loot delay, mining range, engineering buffers, …).

- Use `bounds = { min = X, max = Y }` (or `min`, `max` fields) on the slider entry to force the correct range.
- Attach a `suffix` string (e.g. `"ms"` or `"yd"`) so the value display stays readable.
- The helper above (`slider_entry`) is optional, but it shows a repeatable pattern for passing bounds while keeping code concise.

## Visibility helpers

- Any tab, group, or entry can include `visible_when = function() return <boolean> end`.
- Keep `visible_when` lightweight; it gets called every frame. Cache menu state in helper functions rather than re-querying expensive APIs.
- Use the same helper for both the classic menu render and the custom UI so both stay in sync.

## Keybind capture hints

- Click the key badge to start capturing. A prompt appears (`Esc` to cancel, `Del` to clear).
- Mouse buttons other than left/right are accepted. Left/right are intentionally skipped to keep default behavior intact.
- While capturing, the window blocks other input so drag or slider gestures don’t interfere.

## Window persistence

The constructor wires hidden `core.menu` elements for position, size, and tab index. You can expose them in your own menu tree if you want to give players explicit controls:

- `ui.menu.enable`: checkbox (“Show Custom UI Window”).
- `ui.menu.pos_*` and `ui.menu.size_*`: sliders (ghost elements) that restore the last window layout.
- `ui.menu.active_tab`: slider storing the last selected tab index.

Call `ui:on_menu_render()` from your menu so those helpers can render and keep their state synchronized.

## Extension tabs

Use `rotation_settings_ui.register_extension_tab(tab_info, build_fn)` when an optional module needs to decorate the shared window with its own tab (ESP, fishing, utilities, etc.). The same builder API is available inside the callback, so the extension can reuse `checkbox_grid`, `slider_list`, `combo_list`, or `keybind_grid`.

```lua
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")

rotation_settings_ui.register_extension_tab({
  id = "visuals",
  label = "Visuals / ESP",
  visible_when = function() return menu.enable:get_state() end
}, function(tab)
  tab:checkbox_grid({
    label = "Visual Toggles",
    elements = {
      { element = menu.show_labels, label = "Show Labels" },
      { element = menu.show_fishing_bobber, label = "Show Fishing Bobber" }
    }
  })
end)
```

Extensions appear automatically at the end of the tab bar. `register_extension_tab` returns an unregister helper if you ever need to remove the tab, and `rotation_settings_ui.unregister_extension_tab(tab_id)` is also exposed on the module. The builder object `rotation_settings_ui.TabBuilder` stays available for shared helper code.

## Optional Side-Menu (Sub-Categories inside a Tab)

If a single tab becomes too large, you can optionally add a left “side menu” to sub-categorize the same tab content.
This is completely optional: if you never call `t:side_menu(...)`, the layout stays exactly as it is today.

**Builder method**
- `t:side_menu({ items, width?, label? })` enables a static side menu for the current tab.

**How it works**
- Define the side menu items with `t:side_menu({ items = {...} })`
- Assign groups to a side-menu page by adding `page = "some_id"` (or `subpage = "some_id"`) to the group call (`checkbox_grid`, `slider_list`, `combo_list`, `keybind_grid`).
- Groups with no `page` are always visible (useful for global selectors).
- Each side-menu page gets its own scroll position (switching pages preserves scroll per page).

### Example

```lua
ui:add_tab({ id = "defensives", label = "Defensives" }, function(t)
  t:side_menu({
    label = "Defensives",
    width = 190, -- optional
    items = {
      { header = true, label = "Defensives" },
      { id = "personal", label = "Personal Defensives" },
      { id = "externals", label = "External Defensives" },
      { header = true, label = "Spells" },
      { id = "diffuse", label = "Diffuse Magic" },
      { id = "fort_brew", label = "Fortifying Brew" }
    }
  })

  t:checkbox_grid({
    label = "Personal",
    page = "personal",
    columns = 2,
    elements = {
      { element = menu.use_personal_1, label = "Use Personal 1" },
      { element = menu.use_personal_2, label = "Use Personal 2" }
    }
  })

  t:slider_list({
    label = "Diffuse Magic",
    page = "diffuse",
    elements = {
      { element = menu.diffuse_hp, label = "Use at HP %", suffix = "%" }
    }
  })

  -- Always visible (no page)
  t:combo_list({
    label = "Shared",
    elements = {
      { element = ui.menu.theme_selector, label = "Color Theme", options = { "BxA", "Hunter", "Rogue" } }
    }
  })
end)
```
