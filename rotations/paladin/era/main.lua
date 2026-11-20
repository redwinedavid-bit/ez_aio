-- ============================================================================
local performance = require("shared/rotation_performance")
-- Paladin Unified Leveling Rotation Module (AIO-compatible)
-- World of Warcraft Classic ERA
-- ============================================================================

local paladin = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/paladin/era/rotation_logic")
local dispel_whitelist = require("rotations/paladin/shared/dispel_whitelist")

---@type color
local color = require("common/color")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type key_helper
local key_helper = require("common/utility/key_helper")

---@type control_panel_helper
local control_panel_helper = require("common/utility/control_panel_helper")

---@type enums
local enums = require("common/enums")

local function render_menu_separator()
    local menu = core and core.menu
    if not menu then
        return
    end

    if type(menu.separator) == "function" then
        pcall(menu.separator)
        return
    end

    if type(menu.header) == "function" then
        pcall(function()
            menu.header():render("--------------------------------", color.white(80))
        end)
    end
end

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type rotation_pause
local rotation_pause = require("shared/rotation_pause")

---@type auto_loot
local auto_loot = require("shared/auto_loot")

---@type auto_mining
local auto_mining = require("shared/auto_mining")

---@type auto_herbing
local auto_herbing = require("shared/auto_herbing")

---@type auto_quest_interact
local auto_quest_interact = require("shared/auto_quest_interact")

---@type auto_skinning
local auto_skinning = require("shared/auto_skinning")

---@type rotation_settings_ui
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")

---@type resource_ticks
local resource_ticks = require("shared/resource_ticks")

---@type resource_ticks_widget
local resource_ticks_widget = require("shared/resource_ticks_widget")

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = md.tree_node(),

    enable_script_check = md.checkbox(true, "paladin_enable_script"),
    enable_toggle = md.keybind(999, true, "paladin_enable_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "paladin_ui_toggle_hotkey"),

    -- Optional mode keybind toggles (show in Control Panel)
    tank_mode_toggle = md.keybind(999, false, "paladin_tank_mode_toggle"),
    heal_mode_toggle = md.keybind(999, false, "paladin_heal_mode_toggle"),
    safe_mode_toggle = md.keybind(999, true, "paladin_safe_mode_toggle"),
    mana_save_toggle = md.keybind(999, false, "paladin_mana_save_toggle"),
    pvp_mode_toggle = md.keybind(999, false, "paladin_pvp_mode_toggle"),
    aoe_toggle = md.keybind(999, true, "paladin_aoe_toggle"),

    activate_seal_selection_control_panel = md.checkbox(false, "paladin_activate_seal_selection_control_panel"),
    prefer_seal_righteousness = md.keybind(999, false, "paladin_prefer_seal_righteousness"),
    prefer_seal_command = md.keybind(999, false, "paladin_prefer_seal_command"),
    prefer_seal_wisdom = md.keybind(999, false, "paladin_prefer_seal_wisdom"),
    prefer_seal_light = md.keybind(999, false, "paladin_prefer_seal_light"),
    prefer_seal_justice = md.keybind(999, false, "paladin_prefer_seal_justice"),
    prefer_seal_crusader = md.keybind(999, false, "paladin_prefer_seal_crusader"),

    allow_melee_for_healer = md.checkbox(false, "paladin_allow_melee_for_healer"),

    -- Advanced thresholds (kept compact but powerful)
    allow_safety_while_casting = md.checkbox(true, "paladin_allow_safety_while_casting"),

    use_lay_on_hands = md.checkbox(true, "paladin_use_lay_on_hands"),
    lay_on_hands_at_hp = md.slider_int(1, 40, 15, "paladin_lay_on_hands_at_hp"),
    use_divine_shield = md.checkbox(true, "paladin_use_divine_shield"),
    divine_shield_at_hp = md.slider_int(1, 60, 28, "paladin_divine_shield_at_hp"),
    use_divine_protection = md.checkbox(true, "paladin_use_divine_protection"),
    divine_protection_at_hp = md.slider_int(1, 60, 26, "paladin_divine_protection_at_hp"),
    use_blessing_of_protection = md.checkbox(true, "paladin_use_blessing_of_protection"),
    blessing_of_protection_at_hp = md.slider_int(1, 60, 25, "paladin_blessing_of_protection_at_hp"),
    bop_min_melee_targeters = md.slider_int(0, 10, 1, "paladin_bop_min_melee_targeters"),
    ally_bop_min_melee_targeters = md.slider_int(0, 10, 1, "paladin_ally_bop_min_melee_targeters"),

    use_self_flash_of_light = md.checkbox(true, "paladin_use_self_flash_of_light"),
    self_flash_of_light_at_hp = md.slider_int(1, 90, 50, "paladin_self_flash_of_light_at_hp"),
    use_self_holy_light = md.checkbox(true, "paladin_use_self_holy_light"),
    self_holy_light_at_hp = md.slider_int(1, 90, 32, "paladin_self_holy_light_at_hp"),
    freedom_slow_pct = md.slider_int(10, 90, 30, "paladin_freedom_slow_pct"),

    -- Healing tuning
    tank_holy_light_at_hp = md.slider_int(1, 95, 45, "paladin_tank_holy_light_at_hp"),
    tank_flash_of_light_at_hp = md.slider_int(1, 99, 80, "paladin_tank_flash_of_light_at_hp"),
    ally_flash_of_light_at_hp = md.slider_int(1, 99, 65, "paladin_ally_flash_of_light_at_hp"),
    holy_shock_at_hp = md.slider_int(1, 80, 30, "paladin_holy_shock_at_hp"),
    enable_fol_rank1 = md.checkbox(true, "paladin_enable_fol_rank1"),
    fol_rank1_window_low = md.slider_int(1, 99, 70, "paladin_fol_rank1_window_low"),
    fol_rank1_window_high = md.slider_int(1, 99, 90, "paladin_fol_rank1_window_high"),
    min_mana_for_dispel = md.slider_int(0, 100, 6, "paladin_min_mana_for_dispel"),
    dispel_toggle = md.keybind(999, true, "paladin_dispel_toggle"),
    dispel_use_whitelist = md.checkbox(false, "paladin_dispel_use_whitelist"),
    dispel_whitelist_storage = md.text_input("paladin_dispel_whitelist_storage", false),
    dispel_whitelist_new = md.text_input("paladin_dispel_whitelist_new", false),
    dispel_whitelist_edit = md.text_input("paladin_dispel_whitelist_edit", false),

    -- Self-heal safety: skip casts when you're being focused by too many enemies.
    self_flash_of_light_max_targeters = md.slider_int(0, 10, 2, "paladin_self_flash_of_light_max_targeters"),
    self_holy_light_max_targeters = md.slider_int(0, 10, 1, "paladin_self_holy_light_max_targeters"),

    -- Blessings
    preferred_self_blessing = md.combobox(1, "paladin_preferred_self_blessing"), -- 1=Auto, 2=Might, 3=Wisdom, 4=Kings, 5=Salvation, 6=Sanctuary, 7=Light
    auto_blessings = md.checkbox(true, "paladin_auto_blessings"),
    auto_auras = md.checkbox(true, "paladin_auto_auras"),
    self_overwrite_blessings = md.checkbox(true, "paladin_self_overwrite_blessings"),
    enable_party_blessings = md.checkbox(false, "paladin_enable_party_blessings"),
    party_overwrite_blessings = md.checkbox(false, "paladin_party_overwrite_blessings"),
    party_use_salvation = md.checkbox(true, "paladin_party_use_salvation"),
    party_use_light_on_tank = md.checkbox(true, "paladin_party_use_light_on_tank"),

    -- Tank/DPS tuning
    use_consecration = md.checkbox(true, "paladin_use_consecration"),
    consecration_min_enemies = md.slider_int(1, 10, 2, "paladin_consecration_min_enemies"),
    consecration_min_mana = md.slider_int(0, 100, 35, "paladin_consecration_min_mana"),
    consecration_min_mana_save = md.slider_int(0, 100, 18, "paladin_consecration_min_mana_save"),
    enable_consecration_downrank = md.checkbox(true, "paladin_enable_consecration_downrank"),
    use_holy_shield = md.checkbox(true, "paladin_use_holy_shield"),
    holy_shield_min_mana = md.slider_int(0, 100, 10, "paladin_holy_shield_min_mana"),
    enable_holy_shield_downrank = md.checkbox(true, "paladin_enable_holy_shield_downrank"),
    holy_shield_downrank_threshold = md.slider_int(0, 100, 50, "paladin_holy_shield_downrank_threshold"),
    judgement_min_mana = md.slider_int(0, 100, 12, "paladin_judgement_min_mana"),
    judgement_min_mana_save = md.slider_int(0, 100, 6, "paladin_judgement_min_mana_save"),
    judgement_only_if_missing = md.checkbox(true, "paladin_judgement_only_if_missing"),
    judgement_skip_if_other_active = md.checkbox(false, "paladin_judgement_skip_if_other_active"),
    judgement_refresh_under_sec = md.slider_int(0, 30, 4, "paladin_judgement_refresh_under_sec"),
    enable_jotc_opener = md.checkbox(true, "paladin_enable_jotc_opener"),
    jotc_min_ttd = md.slider_int(0, 60, 18, "paladin_jotc_min_ttd"),

    use_hp_potions = md.checkbox(true, "paladin_use_hp_potions"),
    hp_potion_at = md.slider_int(10, 60, 35, "paladin_hp_potion_at"),

    -- Auto Loot
    auto_loot_enabled = md.checkbox(true, "paladin_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "paladin_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "paladin_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "paladin_auto_loot_retry_delay"),
    auto_mine_enabled = md.checkbox(true, "paladin_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "paladin_auto_mine_range"),
    auto_herb_enabled = md.checkbox(true, "paladin_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "paladin_auto_herb_range"),
    auto_quest_interact_enabled = md.checkbox(false, "paladin_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "paladin_auto_quest_interact_range"),
    auto_skin_enabled = md.checkbox(false, "paladin_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "paladin_auto_skin_range"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = md.checkbox(false, "paladin_era_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "paladin_era_pvp_rotation_tick_rate"),
}

local function auto_loot_enabled()
    return menu_elements.auto_loot_enabled:get_state()
end

local function auto_mine_enabled()
    return menu_elements.auto_mine_enabled:get_state()
end

local function auto_herb_enabled()
    return menu_elements.auto_herb_enabled:get_state()
end

local function quest_interact_available()
    return auto_quest_interact and auto_quest_interact.is_available and auto_quest_interact:is_available()
end

local function quest_interact_enabled()
    return quest_interact_available() and menu_elements.auto_quest_interact_enabled:get_state()
end

local function skinning_available()
    return auto_skinning and auto_skinning.is_available and auto_skinning:is_available()
end

local function skinning_enabled()
    return skinning_available() and menu_elements.auto_skin_enabled:get_state()
end

local function keybind_toggle_active(keybind)
    return plugin_helper:is_toggle_enabled(keybind) == true
end

local function aoe_mode_label_from_menu()
    if not (menu_elements and menu_elements.aoe_mode and menu_elements.aoe_mode.get) then
        return "Auto"
    end
    local idx = menu_elements.aoe_mode:get() or 1
    if idx == 2 then
        return "Single"
    end
    if idx == 3 then
        return "AoE"
    end
    return "Auto"
end

local function resolve_mode_state()
    -- Mode toggles must work from Control Panel even when the keybind is unassigned (key_code=999).
    local tank_mode = plugin_helper:is_toggle_enabled(menu_elements.tank_mode_toggle) == true
    local heal_mode = plugin_helper:is_toggle_enabled(menu_elements.heal_mode_toggle) == true

    if tank_mode and heal_mode then
        heal_mode = false
    end

    -- No fallbacks: these values are driven by keybind toggles only.
    -- Defaults remain stable even if no keys are bound.
    local safe_mode = keybind_toggle_active(menu_elements.safe_mode_toggle)
    if safe_mode == nil then safe_mode = true end

    local mana_save = keybind_toggle_active(menu_elements.mana_save_toggle)
    if mana_save == nil then mana_save = false end

    local pvp_mode = keybind_toggle_active(menu_elements.pvp_mode_toggle)
    if pvp_mode == nil then pvp_mode = false end

    local dispel = keybind_toggle_active(menu_elements.dispel_toggle)
    if dispel == nil then dispel = true end

    -- AoE toggle enables/disables automatic AoE detection.
    -- - Enabled: "auto" (AoE based on enemies nearby)
    -- - Disabled: "single" (force single-target)
    local aoe_toggle = keybind_toggle_active(menu_elements.aoe_toggle) == true
    local aoe_mode_override = aoe_toggle and "auto" or "single"

    local seal_selection_enabled = menu_elements.activate_seal_selection_control_panel:get_state() == true
    local seal_selection = {
        enabled = seal_selection_enabled,
        righteousness = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_righteousness) == true) or false,
        command = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_command) == true) or false,
        wisdom = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_wisdom) == true) or false,
        light = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_light) == true) or false,
        justice = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_justice) == true) or false,
        crusader = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_crusader) == true) or false
    }

    return {
        tank_mode = tank_mode,
        heal_mode = heal_mode,
        safe_mode = safe_mode,
        mana_save = mana_save,
        pvp_mode = pvp_mode,
        dispel = dispel,
        aoe_mode = aoe_mode_override,
        seal_selection = seal_selection
    }
end

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "paladin_rotation",
    title = "Paladin BxA (AIO)",
    default_x = 700,
    default_y = 200,
    default_w = 460,
    default_h = 520,
    theme = "paladin"
})
settings_ui:enable_presets(menu_elements, md)

local mana_tick_widget = resource_ticks_widget.new({
    id = "paladin_mana_ticks",
    label = "Mana Ticks & 5SR",
    menu_prefix = "paladin_mana_ticks",
    default_x = 600,
    default_y = 520,
    default_w = 240,
    default_h = 80,
    enable_window = true
})

if mana_tick_widget and mana_tick_widget.menu then
    pcall(function()
        if mana_tick_widget.menu.show_energy.set then
            mana_tick_widget.menu.show_energy:set(false)
        end
        if mana_tick_widget.menu.show_mana.set then
            mana_tick_widget.menu.show_mana:set(true)
        end
        if mana_tick_widget.menu.show_fsr.set then
            mana_tick_widget.menu.show_fsr:set(true)
        end
    end)
end

-- ============================================================================
-- UI TABS
-- ============================================================================

settings_ui:add_tab({ id = "core_controls", label = "Core Controls" }, function(tab)
    tab:combo_list({
        label = "Blessing Configuration",
        elements = {
            {
                element = menu_elements.preferred_self_blessing,
                label = "Preferred Self Blessing",
                options = { "Auto", "Might", "Wisdom", "Kings", "Salvation", "Sanctuary", "Light" }
            }
        }
    })

    tab:combo_list({
        label = "UI Theme",
        elements = {
            {
                element = settings_ui.menu.theme_selector,
                label = "Color Theme",
                options = { "BxA", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid" }
            }
        }
    })

    tab:keybind_grid({
        elements = {
            menu_elements.enable_toggle,
            menu_elements.tank_mode_toggle,
            menu_elements.heal_mode_toggle,
            menu_elements.safe_mode_toggle,
            menu_elements.mana_save_toggle,
            menu_elements.pvp_mode_toggle,
            menu_elements.aoe_toggle
        },
        labels = {
            "Enable Rotation",
            "Tank Mode",
            "Heal Mode",
            "Safe Mode",
            "Mana Save",
            "PvP Mode",
            "Auto AoE Detection"
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = menu_elements.activate_seal_selection_control_panel, label = "Activate Seal Selection control panel" },
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" }
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            { element = menu_elements.pvp_rotation_tick_rate, label = "PvP Candidate Scan Interval", suffix = "ms", bounds = { min = 30, max = 100 } }
        }
    })

    if menu_elements.activate_seal_selection_control_panel:get_state() == true then
        tab:keybind_grid({
            elements = {
                menu_elements.prefer_seal_righteousness,
                menu_elements.prefer_seal_command,
                menu_elements.prefer_seal_wisdom,
                menu_elements.prefer_seal_light,
                menu_elements.prefer_seal_justice,
                menu_elements.prefer_seal_crusader
            },
            labels = {
                "Prefer Seal: Righteousness",
                "Prefer Seal: Command",
                "Prefer Seal: Wisdom",
                "Prefer Seal: Light",
                "Prefer Seal: Justice",
                "Prefer Seal: Crusader"
            }
        })
    end

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "paladin_modes", label = "Paladin" }, function(tab)
    tab:side_menu({
        label = "Category",
        items = {
            { id = "survival", label = "Survival" },
            { id = "healing", label = "Healing" },
            { id = "party", label = "Party" },
            { id = "tank", label = "Tank" },
            { id = "dps", label = "DPS" }
        }
    })

    tab:checkbox_grid({
        label = "Emergency Buttons",
        columns = 2,
        elements = {
            { element = menu_elements.allow_safety_while_casting, label = "Evaluate Safety While Casting" },
            { element = menu_elements.use_lay_on_hands, label = "Use Lay on Hands" },
            { element = menu_elements.use_divine_shield, label = "Use Divine Shield" },
            { element = menu_elements.use_divine_protection, label = "Use Divine Protection" },
            { element = menu_elements.use_blessing_of_protection, label = "Use Blessing of Protection" },
            { element = menu_elements.use_self_flash_of_light, label = "Self: Flash of Light" },
            { element = menu_elements.use_self_holy_light, label = "Self: Holy Light" }
        },
        page = "survival"
    })

    tab:slider_list({
        label = "Emergency Thresholds",
        elements = {
            { element = menu_elements.lay_on_hands_at_hp, label = "Lay on Hands at HP%", suffix = "%", bounds = { min = 1, max = 40 } },
            { element = menu_elements.divine_shield_at_hp, label = "Divine Shield at HP%", suffix = "%", bounds = { min = 1, max = 60 } },
            { element = menu_elements.divine_protection_at_hp, label = "Divine Protection at HP%", suffix = "%", bounds = { min = 1, max = 60 } },
            { element = menu_elements.blessing_of_protection_at_hp, label = "BoP at HP%", suffix = "%", bounds = { min = 1, max = 60 } },
            { element = menu_elements.bop_min_melee_targeters, label = "BoP min melee targeters", suffix = "", bounds = { min = 0, max = 10 } },
            { element = menu_elements.ally_bop_min_melee_targeters, label = "Ally BoP min melee targeters", suffix = "", bounds = { min = 0, max = 10 } },
            { element = menu_elements.self_flash_of_light_at_hp, label = "Self FoL at HP%", suffix = "%", bounds = { min = 1, max = 90 } },
            { element = menu_elements.self_holy_light_at_hp, label = "Self HL at HP%", suffix = "%", bounds = { min = 1, max = 90 } },
            { element = menu_elements.self_flash_of_light_max_targeters, label = "Skip Self FoL if targeters >= (0=ignore)", suffix = "", bounds = { min = 0, max = 10 } },
            { element = menu_elements.self_holy_light_max_targeters, label = "Skip Self HL if targeters >= (0=ignore)", suffix = "", bounds = { min = 0, max = 10 } },
            { element = menu_elements.freedom_slow_pct, label = "Freedom if slowed by %", suffix = "%", bounds = { min = 10, max = 90 } }
        },
        page = "survival"
    })

    tab:slider_list({
        label = "Healing Thresholds",
        elements = {
            { element = menu_elements.tank_holy_light_at_hp, label = "Tank Holy Light at HP%", suffix = "%", bounds = { min = 1, max = 95 } },
            { element = menu_elements.tank_flash_of_light_at_hp, label = "Tank Flash of Light at HP%", suffix = "%", bounds = { min = 1, max = 99 } },
            { element = menu_elements.ally_flash_of_light_at_hp, label = "Ally FoL at HP%", suffix = "%", bounds = { min = 1, max = 99 } },
            { element = menu_elements.holy_shock_at_hp, label = "Holy Shock at HP%", suffix = "%", bounds = { min = 1, max = 80 } },
            { element = menu_elements.min_mana_for_dispel, label = "Min Mana% for Dispel", suffix = "%", bounds = { min = 0, max = 100 } }
        },
        page = "healing"
    })

    tab:keybind_grid({
        elements = { menu_elements.dispel_toggle },
        labels = { "Dispel Toggle" },
        page = "healing"
    })

    tab:checkbox_grid({
        label = "Dispel Settings",
        columns = 1,
        elements = {
            { element = menu_elements.dispel_use_whitelist, label = "Only Dispel Allies on Whitelist" }
        },
        page = "healing"
    })

    local dispel_whitelist_selected = {}

    tab:text_input_list({
        label = "Dispel Whitelist (Names)",
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        elements = {
            {
                element = menu_elements.dispel_whitelist_new,
                label = "Add Name",
                tooltip = "Example: Tankname\nTip: You can also paste multiple names separated by commas or newlines."
            },
            {
                element = menu_elements.dispel_whitelist_edit,
                label = "Rename Selected To",
                tooltip = "Select exactly one name below, then enter the new name here."
            }
        },
        page = "healing"
    })

    tab:button({
        label = "Add to Whitelist",
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        on_click = function()
            local text = menu_elements.dispel_whitelist_new and menu_elements.dispel_whitelist_new.get_text and menu_elements.dispel_whitelist_new:get_text() or ""
            if type(text) ~= "string" or text == "" then
                return
            end
            for token in string.gmatch(text, "([^,\n;]+)") do
                dispel_whitelist.add(menu_elements, token)
            end
            if menu_elements.dispel_whitelist_new and menu_elements.dispel_whitelist_new.set then
                menu_elements.dispel_whitelist_new:set("")
            end
        end,
        page = "healing"
    })

    tab:button({
        label = "Rename Selected",
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        on_click = function()
            local new_name = menu_elements.dispel_whitelist_edit and menu_elements.dispel_whitelist_edit.get_text and menu_elements.dispel_whitelist_edit:get_text() or ""
            if type(new_name) ~= "string" or new_name == "" then
                return
            end
            local old_key = nil
            for k, v in pairs(dispel_whitelist_selected) do
                if v == true then
                    old_key = k
                    break
                end
            end
            if not old_key then
                return
            end
            if dispel_whitelist.rename_key(menu_elements, old_key, new_name) then
                dispel_whitelist_selected = {}
            end
            if menu_elements.dispel_whitelist_edit and menu_elements.dispel_whitelist_edit.set then
                menu_elements.dispel_whitelist_edit:set("")
            end
        end,
        page = "healing"
    })

    tab:button({
        label = "Remove Selected",
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        on_click = function()
            if dispel_whitelist.remove_keys(menu_elements, dispel_whitelist_selected) then
                dispel_whitelist_selected = {}
            end
        end,
        page = "healing"
    })

    tab:runtime_checkbox_list({
        label = "Current Whitelist",
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        elements = function()
            local entries, _ = dispel_whitelist.get(menu_elements)
            local items = {}
            for _, entry in ipairs(entries) do
                local key = string.lower(tostring(entry))
                table.insert(items, {
                    label = tostring(entry),
                    get_state = function()
                        return dispel_whitelist_selected[key] == true
                    end,
                    set_state = function(state)
                        dispel_whitelist_selected[key] = (state == true)
                    end
                })
            end
            return items
        end,
        page = "healing"
    })

    tab:text({
        visible_when = function()
            return menu_elements.dispel_use_whitelist:get_state() == true
        end,
        text = function()
            local entries, _ = dispel_whitelist.get(menu_elements)
            return string.format("Whitelist entries: %d\nNote: Self-dispel ignores the whitelist.", #entries)
        end,
        page = "healing"
    })

    tab:checkbox_grid({
        label = "Healing Efficiency",
        columns = 2,
        elements = {
            { element = menu_elements.enable_fol_rank1, label = "Allow FoL Rank 1 Topups" },
            { element = menu_elements.allow_melee_for_healer, label = "Allow Melee (SoW/JoW)" }
        },
        page = "healing"
    })

    tab:slider_list({
        label = "FoL Rank 1 Window",
        elements = {
            { element = menu_elements.fol_rank1_window_low, label = "Use FoL R1 if Tank HP >= ", suffix = "%", bounds = { min = 1, max = 99 } },
            { element = menu_elements.fol_rank1_window_high, label = "and Tank HP <= ", suffix = "%", bounds = { min = 1, max = 99 } }
        },
        page = "healing"
    })

    tab:checkbox_grid({
        label = "Tank Tools",
        columns = 2,
        elements = {
            { element = menu_elements.use_holy_shield, label = "Use Holy Shield" },
            { element = menu_elements.use_consecration, label = "Use Consecration" }
        },
        page = "tank"
    })

    tab:slider_list({
        label = "Tank Mana Controls",
        elements = {
            { element = menu_elements.holy_shield_min_mana, label = "Holy Shield min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.enable_holy_shield_downrank, label = "Enable Holy Shield Downranking (R1)" },
            { element = menu_elements.holy_shield_downrank_threshold, label = "Downrank Holy Shield when mana <=", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.consecration_min_mana, label = "Consecration min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.consecration_min_mana_save, label = "Consecration (Mana Save) min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.consecration_min_enemies, label = "Consecration min enemies", suffix = "", bounds = { min = 1, max = 10 } }
        },
        page = "tank"
    })

    tab:checkbox_grid({
        label = "DPS Options",
        columns = 2,
        elements = {
            { element = menu_elements.enable_jotc_opener, label = "Use JoTC opener (long fights)" },
            { element = menu_elements.use_consecration, label = "Use Consecration" },
            { element = menu_elements.judgement_only_if_missing, label = "Judgement: Only If Missing" },
            { element = menu_elements.judgement_skip_if_other_active, label = "Judgement: Skip if Other Active" }
        },
        page = "dps"
    })

    tab:slider_list({
        label = "DPS Mana Controls",
        elements = {
            { element = menu_elements.judgement_min_mana, label = "Judgement min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.judgement_min_mana_save, label = "Judgement (Mana Save) min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.jotc_min_ttd, label = "JoTC min TTD (sec)", suffix = "s", bounds = { min = 0, max = 60 } },
            { element = menu_elements.judgement_refresh_under_sec, label = "Judgement refresh under (sec)", suffix = "s", bounds = { min = 0, max = 30 } }
        },
        page = "dps"
    })

    tab:checkbox_grid({
        label = "Blessings",
        columns = 2,
        elements = {
            { element = menu_elements.auto_blessings, label = "Auto Blessings" },
            { element = menu_elements.auto_auras, label = "Auto Auras" },
            { element = menu_elements.self_overwrite_blessings, label = "Self: Overwrite Existing Blessing" },
            { element = menu_elements.enable_party_blessings, label = "Enable Party Blessings" },
            { element = menu_elements.party_overwrite_blessings, label = "Party: Overwrite Existing Blessing" },
            { element = menu_elements.party_use_salvation, label = "Party: Use Salvation on DPS" },
            { element = menu_elements.party_use_light_on_tank, label = "Party: Use Light on Tank (heals)" }
        },
        page = "party"
    })
end)

settings_ui:add_tab({ id = "consumables", label = "Consumables" }, function(tab)
    tab:checkbox_grid({
        label = "Consumable Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.use_hp_potions, label = "Use Health Potions" }
        }
    })

    tab:slider_list({
        label = "Health Potions",
        elements = {
            { element = menu_elements.hp_potion_at, label = "Use at HP%", suffix = "%", bounds = { min = 10, max = 60 } }
        }
    })
end)

settings_ui:add_tab({ id = "mana_ticks", label = "Mana Ticks & 5SR" }, function(tab)
    if not mana_tick_widget or not mana_tick_widget.menu then
        return
    end

    tab:checkbox_grid({
        label = "Widget Display",
        columns = 2,
        elements = {
            { element = mana_tick_widget.menu.enable, label = "Enable Mana Tick Widget" },
            { element = mana_tick_widget.menu.only_in_combat, label = "Only In Combat" },
            { element = mana_tick_widget.menu.show_label, label = "Show Label" },
            { element = mana_tick_widget.menu.show_time, label = "Show Timers" }
        }
    })

    tab:checkbox_grid({
        label = "Bars to Display",
        columns = 3,
        elements = {
            { element = mana_tick_widget.menu.show_energy, label = "Energy Tick" },
            { element = mana_tick_widget.menu.show_mana, label = "Mana Tick" },
            { element = mana_tick_widget.menu.show_fsr, label = "5-Second Rule" }
        }
    })
end)

settings_ui:add_tab({ id = "automation", label = "Automation" }, function(tab)
        tab:checkbox_grid({
            label = "Automation",
            columns = 2,
            elements = {
                { element = menu_elements.auto_loot_enabled, label = "Auto Loot" },
                { element = menu_elements.auto_mine_enabled, label = "Auto Mining" },
                { element = menu_elements.auto_herb_enabled, label = "Auto Herbs" },
                { element = menu_elements.auto_quest_interact_enabled, label = "Auto Quest Interact", visible_when = quest_interact_available },
                { element = menu_elements.auto_skin_enabled, label = "Auto Skinning", visible_when = skinning_available }
            }
        })

    tab:combo_list({
        label = "Loot Mode",
        elements = {
            {
                element = menu_elements.auto_loot_mode,
                label = "Loot Mode",
                options = { "Out of Combat Only", "In Combat Only", "Always" },
                visible_when = auto_loot_enabled
            }
        }
    })

    tab:slider_list({
        label = "Auto Loot",
        elements = {
            { element = menu_elements.auto_loot_max_attempts, label = "Max Attempts per Corpse", suffix = "", bounds = { min = 1, max = 10 }, visible_when = auto_loot_enabled },
            { element = menu_elements.auto_loot_retry_delay, label = "Corpse Lockout (sec)", suffix = "s", bounds = { min = 30, max = 200 }, visible_when = auto_loot_enabled }
        }
    })

        tab:slider_list({
            label = "Auto Mining",
            elements = {
                { element = menu_elements.auto_mine_range, label = "Mining Range", suffix = "yd", bounds = { min = 2, max = 8 }, visible_when = auto_mine_enabled }
            }
        })

        tab:slider_list({
            label = "Auto Herbs",
            elements = {
                { element = menu_elements.auto_herb_range, label = "Herbing Range", suffix = "yd", bounds = { min = 2, max = 8 }, visible_when = auto_herb_enabled }
            }
        })

        tab:slider_list({
            label = "Auto Quest Interact",
            elements = {
                { element = menu_elements.auto_quest_interact_range, label = "Interact Range", suffix = "yd", bounds = { min = 2, max = 8 }, visible_when = quest_interact_enabled }
            }
        })

    tab:slider_list({
        label = "Auto Skinning",
        elements = {
            { element = menu_elements.auto_skin_range, label = "Skinning Range", suffix = "yd", bounds = { min = 2, max = 8 }, visible_when = skinning_enabled }
        }
    })
end)

-- ============================================================================
-- F1 TOGGLE FOR CUSTOM UI
-- ============================================================================

local f1_key_was_pressed = false

-- ============================================================================
-- UPDATE LOOP
-- ============================================================================

function paladin:on_update(local_player)
    -- F1 Hotkey for Custom UI Toggle
    if settings_ui and settings_ui.menu and settings_ui.menu.enable then
        local hotkey_state = menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey:get_state()
        local f1_key_down = (hotkey_state == true or hotkey_state == 1)

        if f1_key_down and not f1_key_was_pressed then
            if settings_ui.toggle then
                settings_ui:toggle()
            else
                settings_ui.menu.enable:set_state(not settings_ui.menu.enable:get_state())
            end
        end

        f1_key_was_pressed = f1_key_down
    end

	    if not local_player then
	        return
	    end

	    if rotation_pause.is_eating_or_drinking(local_player) then
	        return
	    end

	    if not menu_elements.enable_script_check:get_state() then
	        return
	    end

    if not plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) then
        return
    end

    if local_player:is_mounted() then
        return
    end

	    local tick_tracker = resource_ticks.get()


    local game_now = core.game_time()
    if performance:begin_update(local_player, menu_elements, game_now) then
        rotation_logic:execute(local_player, menu_elements, tick_tracker, resolve_mode_state())
    end

    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
end

-- ============================================================================
-- RENDER LOOP
-- ============================================================================

function paladin:on_render()
    if settings_ui then
        settings_ui:on_render()
    end
end

-- ============================================================================
-- CORE MENU RENDER (legacy entrypoint)
-- ============================================================================

function paladin:on_menu_render()
    settings_ui:on_menu_render()

    local mode = resolve_mode_state()
    local role_label = mode.tank_mode and "Tank" or (mode.heal_mode and "Heal" or "DPS")
    local aoe_label = (mode.aoe_mode == "auto" and "Auto")
        or (mode.aoe_mode == "single" and "Single")
        or (mode.aoe_mode == "aoe" and "AoE")
        or aoe_mode_label_from_menu()

    menu_elements.main_tree:render("Paladin BxA (AIO)", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(255, 150, 200, 255))

        md.header():render("Role: " .. role_label .. " | AoE: " .. aoe_label, color.new(255, 215, 100, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")

        render_menu_separator()
        md.header():render("Control Panel Toggles (optional keybinds)", color.white(200))
        menu_elements.tank_mode_toggle:render("Tank Mode Toggle (" .. key_helper:get_key_name(menu_elements.tank_mode_toggle:get_key_code()) .. ")")
        menu_elements.heal_mode_toggle:render("Heal Mode Toggle (" .. key_helper:get_key_name(menu_elements.heal_mode_toggle:get_key_code()) .. ")")
        menu_elements.safe_mode_toggle:render("Safe Mode Toggle (" .. key_helper:get_key_name(menu_elements.safe_mode_toggle:get_key_code()) .. ")")
        menu_elements.mana_save_toggle:render("Mana Save Toggle (" .. key_helper:get_key_name(menu_elements.mana_save_toggle:get_key_code()) .. ")")
        menu_elements.pvp_mode_toggle:render("PvP Mode Toggle (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ")")
        menu_elements.aoe_toggle:render("Auto AoE Toggle (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ")")
        menu_elements.dispel_toggle:render("Dispel Toggle (" .. key_helper:get_key_name(menu_elements.dispel_toggle:get_key_code()) .. ")")

        render_menu_separator()
        md.header():render("Non-toggle Options", color.white(200))
        menu_elements.allow_melee_for_healer:render("Allow Melee (healer downtime)")
    end)
end

-- ============================================================================
-- CONTROL PANEL
-- ============================================================================

function paladin:on_control_panel_render()
    local control_panel_elements = {}

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Paladin Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Tank Mode (" .. key_helper:get_key_name(menu_elements.tank_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.tank_mode_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Heal Mode (" .. key_helper:get_key_name(menu_elements.heal_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.heal_mode_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Safe Mode (" .. key_helper:get_key_name(menu_elements.safe_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.safe_mode_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Mana Save (" .. key_helper:get_key_name(menu_elements.mana_save_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.mana_save_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.pvp_mode_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Dispel (" .. key_helper:get_key_name(menu_elements.dispel_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.dispel_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Auto AoE (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_toggle
    })

    if menu_elements.activate_seal_selection_control_panel:get_state() == true then
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Righteousness (" .. key_helper:get_key_name(menu_elements.prefer_seal_righteousness:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_righteousness
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Command (" .. key_helper:get_key_name(menu_elements.prefer_seal_command:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_command
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Wisdom (" .. key_helper:get_key_name(menu_elements.prefer_seal_wisdom:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_wisdom
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Light (" .. key_helper:get_key_name(menu_elements.prefer_seal_light:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_light
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Justice (" .. key_helper:get_key_name(menu_elements.prefer_seal_justice:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_justice
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Crusader (" .. key_helper:get_key_name(menu_elements.prefer_seal_crusader:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_crusader
        })
    end

    return control_panel_elements
end

return paladin
