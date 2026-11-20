-- ============================================================================
local performance = require("shared/rotation_performance")
-- Druid Rotation Module (AIO-compatible)
-- World of Warcraft Classic ERA
-- Full PvE (4 specs) + PvP + Hardcore Survival
-- ============================================================================

local druid = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/druid/era/rotation")
local helpers = require("rotations/druid/era/helpers")

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
    healing_tree = md.tree_node(),
    feral_dps_tree = md.tree_node(),
    tank_tree = md.tree_node(),
    balance_tree = md.tree_node(),
    buffs_tree = md.tree_node(),
    automation_tree = md.tree_node(),
    mana_ticks_tree = md.tree_node(),

    -- ========================================================================
    -- MAIN TOGGLES
    -- ========================================================================
    enable_script_check = core.menu.checkbox(true, "druid_enable_script"),
    enable_toggle = core.menu.keybind(999, true, "druid_enable_toggle"),
    cooldowns_toggle = core.menu.keybind(999, false, "druid_cooldowns_toggle"),
    ui_toggle_hotkey = core.menu.keybind(112, false, "druid_ui_toggle_hotkey"),
    spec_selector = core.menu.combobox(1, "druid_spec_selector"),
    reset_ui_position = core.menu.checkbox(false, "druid_reset_ui_position"),

    -- ========================================================================
    -- PVP
    -- ========================================================================
    pvp_toggle = core.menu.keybind(999, false, "druid_pvp_toggle"),
    pvp_break_roots = core.menu.checkbox(true, "druid_pvp_break_roots"),
    pvp_use_feral_charge = core.menu.checkbox(true, "druid_pvp_use_feral_charge"),
    pvp_use_entangling_roots = core.menu.checkbox(true, "druid_pvp_use_roots"),
    pvp_travel_escape_hp = core.menu.slider_int(0, 100, 25, "druid_pvp_travel_escape_hp"),

    -- ========================================================================
    -- HARDCORE / SURVIVAL
    -- ========================================================================
    hardcore_mode = core.menu.checkbox(false, "druid_hardcore_mode"),
    emergency_bear_hp = core.menu.slider_int(0, 100, 30, "druid_emergency_bear_hp"),
    emergency_heal_hp = core.menu.slider_int(0, 100, 40, "druid_emergency_heal_hp"),
    use_barkskin = core.menu.checkbox(true, "druid_use_barkskin"),
    barkskin_hp = core.menu.slider_int(0, 100, 50, "druid_barkskin_hp"),
    use_natures_grasp = core.menu.checkbox(true, "druid_use_natures_grasp"),
    ns_ht_hp = core.menu.slider_int(0, 100, 25, "druid_ns_ht_hp"),

    -- ========================================================================
    -- HEALING SETTINGS (Restoration)
    -- ========================================================================
    enable_healing = core.menu.checkbox(true, "druid_enable_healing"),
    tank_emergency_hp = core.menu.slider_int(0, 100, 30, "druid_tank_emergency_hp"),
    player_emergency_hp = core.menu.slider_int(0, 100, 40, "druid_player_emergency_hp"),
    rejuvenation_hp = core.menu.slider_int(0, 100, 85, "druid_rejuvenation_hp"),
    regrowth_hp = core.menu.slider_int(0, 100, 60, "druid_regrowth_hp"),
    healing_touch_hp = core.menu.slider_int(0, 100, 50, "druid_healing_touch_hp"),
    swiftmend_hp = core.menu.slider_int(0, 100, 35, "druid_swiftmend_hp"),
    resto_use_ns = core.menu.checkbox(true, "druid_resto_use_ns"),
    resto_use_innervate = core.menu.checkbox(true, "druid_resto_use_innervate"),
    resto_innervate_mana = core.menu.slider_int(0, 100, 30, "druid_resto_innervate_mana"),
    resto_use_tranquility = core.menu.checkbox(true, "druid_resto_use_tranq"),
    resto_use_barkskin = core.menu.checkbox(true, "druid_resto_use_barkskin"),
    resto_tranq_count = core.menu.slider_int(2, 5, 3, "druid_resto_tranq_count"),
    resto_raid_mode = core.menu.checkbox(false, "druid_resto_raid_mode"),

    -- ========================================================================
    -- FERAL DPS (Cat)
    -- ========================================================================
    cat_rip_cp = core.menu.slider_int(1, 5, 5, "druid_cat_rip_cp"),
    cat_use_rake = core.menu.checkbox(true, "druid_cat_use_rake"),
    cat_use_shred = core.menu.checkbox(true, "druid_cat_use_shred"),
    cat_use_tigers_fury = core.menu.checkbox(true, "druid_cat_use_tigers_fury"),
    cat_use_ferocious_bite = core.menu.checkbox(true, "druid_cat_use_fb"),
    cat_use_prowl = core.menu.checkbox(true, "druid_cat_use_prowl"),
    cat_use_cower = core.menu.checkbox(false, "druid_cat_use_cower"),
    cat_use_faerie_fire = core.menu.checkbox(true, "druid_cat_use_ff"),
    cat_use_powershift = core.menu.checkbox(true, "druid_cat_use_powershift"),
    cat_fb_cp = core.menu.slider_int(1, 5, 5, "druid_cat_fb_cp"),

    -- ========================================================================
    -- TANK (Bear)
    -- ========================================================================
    tank_maul_rage = core.menu.slider_int(10, 100, 15, "druid_tank_maul_rage"),
    tank_frenzied_reg_hp = core.menu.slider_int(5, 50, 25, "druid_tank_frenzied_reg_hp"),
    tank_use_demo_roar = core.menu.checkbox(true, "druid_tank_use_demo_roar"),
    tank_use_bash = core.menu.checkbox(true, "druid_tank_use_bash"),
    bear_use_growl = core.menu.checkbox(true, "druid_bear_use_growl"),
    bear_use_enrage = core.menu.checkbox(true, "druid_bear_use_enrage"),
    bear_use_faerie_fire = core.menu.checkbox(true, "druid_bear_use_ff"),
    bear_use_swipe = core.menu.checkbox(true, "druid_bear_use_swipe"),

    -- ========================================================================
    -- BALANCE
    -- ========================================================================
    balance_use_roots = core.menu.checkbox(true, "druid_balance_use_roots"),
    balance_use_insect_swarm = core.menu.checkbox(true, "druid_balance_use_insect_swarm"),
    balance_min_mana = core.menu.slider_int(5, 50, 15, "druid_balance_min_mana"),
    balance_auto_attack_hp = core.menu.slider_int(0, 100, 10, "druid_balance_auto_attack_hp"),
    balance_use_faerie_fire = core.menu.checkbox(true, "druid_balance_use_ff"),
    balance_use_starfire = core.menu.checkbox(true, "druid_balance_use_sf"),

    -- ========================================================================
    -- BUFFS
    -- ========================================================================
    use_buffs = core.menu.checkbox(true, "druid_use_buffs"),
    auto_form = core.menu.checkbox(true, "druid_auto_form"),
    auto_motw = core.menu.checkbox(true, "druid_auto_motw"),
    auto_thorns = core.menu.checkbox(true, "druid_auto_thorns"),

    -- ========================================================================
    -- AUTOMATION
    -- ========================================================================
    auto_loot_enabled = core.menu.checkbox(true, "druid_auto_loot_enabled"),
    auto_loot_mode = core.menu.combobox(1, "druid_auto_loot_mode"),
    auto_loot_max_attempts = core.menu.slider_int(1, 10, 1, "druid_auto_loot_max_attempts"),
    auto_loot_retry_delay = core.menu.slider_int(30, 200, 60, "druid_auto_loot_retry_delay"),

    -- ========================================================================
    -- PVP
    -- ========================================================================
    pvp_toggle = md.keybind(999, false, "druid_pvp_toggle"),
    pvp_break_roots = md.checkbox(true, "druid_pvp_break_roots"),
    pvp_use_feral_charge = md.checkbox(true, "druid_pvp_use_feral_charge"),
    pvp_use_entangling_roots = md.checkbox(true, "druid_pvp_use_roots"),
    pvp_travel_escape_hp = md.slider_int(0, 100, 25, "druid_pvp_travel_escape_hp"),
    
    -- PvP Performance Settings
    enable_pvp_mode = md.checkbox(false, "druid_era_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "druid_era_pvp_rotation_tick_rate"),

    -- ========================================================================
    -- HARDCORE / SURVIVAL
    -- ========================================================================
    hardcore_mode = md.checkbox(false, "druid_hardcore_mode"),
    emergency_bear_hp = md.slider_int(0, 100, 30, "druid_emergency_bear_hp"),
    emergency_heal_hp = md.slider_int(0, 100, 40, "druid_emergency_heal_hp"),
    use_barkskin = md.checkbox(true, "druid_use_barkskin"),
    barkskin_hp = md.slider_int(0, 100, 50, "druid_barkskin_hp"),
    use_natures_grasp = md.checkbox(true, "druid_use_natures_grasp"),
    ns_ht_hp = md.slider_int(0, 100, 25, "druid_ns_ht_hp"),

    -- ========================================================================
    -- HEALING SETTINGS (Restoration)
    -- ========================================================================
    enable_healing = md.checkbox(true, "druid_enable_healing"),
    tank_emergency_hp = md.slider_int(0, 100, 30, "druid_tank_emergency_hp"),
    player_emergency_hp = md.slider_int(0, 100, 40, "druid_player_emergency_hp"),
    rejuvenation_hp = md.slider_int(0, 100, 85, "druid_rejuvenation_hp"),
    regrowth_hp = md.slider_int(0, 100, 60, "druid_regrowth_hp"),
    healing_touch_hp = md.slider_int(0, 100, 50, "druid_healing_touch_hp"),
    swiftmend_hp = md.slider_int(0, 100, 35, "druid_swiftmend_hp"),
    resto_use_ns = md.checkbox(true, "druid_resto_use_ns"),
    resto_use_innervate = md.checkbox(true, "druid_resto_use_innervate"),
    resto_innervate_mana = md.slider_int(0, 100, 30, "druid_resto_innervate_mana"),
    resto_use_tranquility = md.checkbox(true, "druid_resto_use_tranq"),
    resto_use_barkskin = md.checkbox(true, "druid_resto_use_barkskin"),
    resto_tranq_count = md.slider_int(2, 5, 3, "druid_resto_tranq_count"),
    resto_raid_mode = md.checkbox(false, "druid_resto_raid_mode"),

    -- ========================================================================
    -- FERAL DPS (Cat)
    -- ========================================================================
    cat_rip_cp = md.slider_int(1, 5, 5, "druid_cat_rip_cp"),
    cat_use_rake = md.checkbox(true, "druid_cat_use_rake"),
    cat_use_shred = md.checkbox(true, "druid_cat_use_shred"),
    cat_use_tigers_fury = md.checkbox(true, "druid_cat_use_tigers_fury"),
    cat_use_ferocious_bite = md.checkbox(true, "druid_cat_use_fb"),
    cat_use_prowl = md.checkbox(true, "druid_cat_use_prowl"),
    cat_use_cower = md.checkbox(false, "druid_cat_use_cower"),
    cat_use_faerie_fire = md.checkbox(true, "druid_cat_use_ff"),
    cat_use_powershift = md.checkbox(true, "druid_cat_use_powershift"),
    cat_fb_cp = md.slider_int(1, 5, 5, "druid_cat_fb_cp"),

    -- ========================================================================
    -- TANK (Bear)
    -- ========================================================================
    tank_maul_rage = md.slider_int(10, 100, 15, "druid_tank_maul_rage"),
    tank_frenzied_reg_hp = md.slider_int(5, 50, 25, "druid_tank_frenzied_reg_hp"),
    tank_use_demo_roar = md.checkbox(true, "druid_tank_use_demo_roar"),
    tank_use_bash = md.checkbox(true, "druid_tank_use_bash"),
    bear_use_growl = md.checkbox(true, "druid_bear_use_growl"),
    bear_use_enrage = md.checkbox(true, "druid_bear_use_enrage"),
    bear_use_faerie_fire = md.checkbox(true, "druid_bear_use_ff"),
    bear_use_swipe = md.checkbox(true, "druid_bear_use_swipe"),

    -- ========================================================================
    -- BALANCE
    -- ========================================================================
    balance_use_roots = md.checkbox(true, "druid_balance_use_roots"),
    balance_use_insect_swarm = md.checkbox(true, "druid_balance_use_insect_swarm"),
    balance_min_mana = md.slider_int(5, 50, 15, "druid_balance_min_mana"),
    balance_auto_attack_hp = md.slider_int(0, 100, 10, "druid_balance_auto_attack_hp"),
    balance_use_faerie_fire = md.checkbox(true, "druid_balance_use_ff"),
    balance_use_starfire = md.checkbox(true, "druid_balance_use_sf"),

    -- ========================================================================
    -- BUFFS
    -- ========================================================================
    use_buffs = md.checkbox(true, "druid_use_buffs"),
    auto_form = md.checkbox(true, "druid_auto_form"),
    auto_motw = md.checkbox(true, "druid_auto_motw"),
    auto_thorns = md.checkbox(true, "druid_auto_thorns"),

    -- ========================================================================
    -- AUTOMATION
    -- ========================================================================
    auto_loot_enabled = md.checkbox(true, "druid_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "druid_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "druid_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "druid_auto_loot_retry_delay"),

    auto_mine_enabled = md.checkbox(true, "druid_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "druid_auto_mine_range"),

    auto_herb_enabled = md.checkbox(true, "druid_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "druid_auto_herb_range"),

    auto_quest_interact_enabled = md.checkbox(false, "druid_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "druid_auto_quest_interact_range"),

    auto_skin_enabled = md.checkbox(false, "druid_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "druid_auto_skin_range"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = md.checkbox(false, "druid_era_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "druid_era_pvp_rotation_tick_rate"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "druid_rotation",
    title = "Druid Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 520,
    default_h = 700,
    theme = "druid"
})
settings_ui:enable_presets(menu_elements, md)

-- Resource Tick Widget
local mana_tick_widget = resource_ticks_widget.new({
    id = "druid_mana_ticks",
    label = "Resource Ticks",
    menu_prefix = "druid_mana_ticks",
    default_x = 600,
    default_y = 520,
    default_w = 240,
    default_h = 80,
    enable_window = true
})

if mana_tick_widget and mana_tick_widget.menu then
    pcall(function()
        mana_tick_widget.menu.show_energy:set(true)
        mana_tick_widget.menu.show_mana:set(true)
        mana_tick_widget.menu.show_fsr:set(true)
    end)
end

-- ============================================================================
-- VISIBILITY HELPERS
-- ============================================================================

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

local function pvp_enabled()
    return menu_elements.pvp_toggle:get_state()
end

local function hardcore_enabled()
    return menu_elements.hardcore_mode:get_state()
end

local function barkskin_enabled()
    return menu_elements.use_barkskin:get_state()
end

local function slider_entry(element, label, suffix, min_value, max_value, visible_when)
    local entry = {
        element = element,
        label = label,
        suffix = suffix or "",
        visible_when = visible_when
    }
    if min_value or max_value then
        entry.bounds = { min = min_value, max = max_value }
    end
    return entry
end

-- ============================================================================
-- UI TABS
-- ============================================================================

settings_ui:add_tab({ id = "core_controls", label = "Core Controls" }, function(tab)
    tab:combo_list({
        label = "Specialization",
        elements = {
            {
                element = menu_elements.spec_selector,
                label = "Active Spec",
                options = { "Restoration (Heal)", "Feral (Cat/DPS)", "Feral (Bear/Tank)", "Balance (Caster)" }
            }
        }
    })

    tab:keybind_grid({
        elements = {
            menu_elements.enable_toggle,
            menu_elements.cooldowns_toggle,
            menu_elements.pvp_toggle,
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
            "PvP Mode",
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" },
            { element = menu_elements.auto_form, label = "Auto-Transform" },
            { element = menu_elements.hardcore_mode, label = "Hardcore Mode" },
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" },
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Candidate Scan Interval", "ms", 30, 100)
        }
    })
end)

settings_ui:add_tab({ id = "survival", label = "Survival" }, function(tab)
    tab:checkbox_grid({
        label = "Emergency Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.use_barkskin, label = "Use Barkskin" },
            { element = menu_elements.use_natures_grasp, label = "Use Nature's Grasp" },
        }
    })

    tab:slider_list({
        label = "Survival Thresholds",
        elements = {
            slider_entry(menu_elements.barkskin_hp, "Barkskin at HP", "%", 0, 100, barkskin_enabled),
            slider_entry(menu_elements.ns_ht_hp, "NS+HT at HP", "%", 0, 100),
            slider_entry(menu_elements.emergency_bear_hp, "Emergency Bear at HP", "%", 0, 100, hardcore_enabled),
            slider_entry(menu_elements.emergency_heal_hp, "Emergency Heal at HP", "%", 0, 100, hardcore_enabled),
        }
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
    tab:keybind_grid({
        elements = { menu_elements.pvp_toggle },
        labels = { "PvP Mode Toggle" }
    })

    tab:checkbox_grid({
        label = "PvP Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_break_roots, label = "Break Roots (Shift)" },
            { element = menu_elements.pvp_use_feral_charge, label = "Use Feral Charge" },
            { element = menu_elements.pvp_use_entangling_roots, label = "Use Entangling Roots" },
        }
    })

    tab:slider_list({
        label = "PvP Thresholds",
        elements = {
            slider_entry(menu_elements.pvp_travel_escape_hp, "Travel Form Escape HP", "%", 0, 100, pvp_enabled),
        }
    })
end)

settings_ui:add_tab({ id = "restoration", label = "Restoration" }, function(tab)
    tab:checkbox_grid({
        label = "Healing Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_healing, label = "Enable Healing Logic" },
            { element = menu_elements.resto_use_ns, label = "Use Nature's Swiftness" },
            { element = menu_elements.resto_use_innervate, label = "Use Innervate" },
            { element = menu_elements.resto_use_tranquility, label = "Use Tranquility" },
            { element = menu_elements.resto_use_barkskin, label = "Use Barkskin" },
        }
    })

    tab:slider_list({
        label = "Healing Thresholds",
        elements = {
            slider_entry(menu_elements.rejuvenation_hp, "Rejuvenation HP", "%", 0, 100),
            slider_entry(menu_elements.regrowth_hp, "Regrowth HP", "%", 0, 100),
            slider_entry(menu_elements.healing_touch_hp, "Healing Touch HP", "%", 0, 100),
            slider_entry(menu_elements.swiftmend_hp, "Swiftmend HP", "%", 0, 100),
            slider_entry(menu_elements.resto_innervate_mana, "Innervate at Mana", "%", 0, 100),
            slider_entry(menu_elements.resto_tranq_count, "Tranquility at # Low", "", 2, 5),
        }
    })
end)

settings_ui:add_tab({ id = "feral_cat", label = "Feral (Cat)" }, function(tab)
    tab:checkbox_grid({
        label = "Cat DPS Options",
        columns = 2,
        elements = {
            { element = menu_elements.cat_use_rake, label = "Use Rake" },
            { element = menu_elements.cat_use_shred, label = "Use Shred" },
            { element = menu_elements.cat_use_tigers_fury, label = "Use Tiger's Fury" },
            { element = menu_elements.cat_use_ferocious_bite, label = "Use Ferocious Bite" },
            { element = menu_elements.cat_use_prowl, label = "Use Prowl/Opener" },
            { element = menu_elements.cat_use_cower, label = "Use Cower" },
            { element = menu_elements.cat_use_faerie_fire, label = "Use Faerie Fire" },
            { element = menu_elements.cat_use_powershift, label = "Powershifting" },
        }
    })

    tab:slider_list({
        label = "Finisher Settings",
        elements = {
            slider_entry(menu_elements.cat_rip_cp, "Rip at CP", " CP", 1, 5),
            slider_entry(menu_elements.cat_fb_cp, "FB at CP", " CP", 1, 5),
        }
    })
end)

settings_ui:add_tab({ id = "feral_bear", label = "Feral (Bear)" }, function(tab)
    tab:checkbox_grid({
        label = "Tanking Options",
        columns = 2,
        elements = {
            { element = menu_elements.tank_use_demo_roar, label = "Use Demo Roar" },
            { element = menu_elements.tank_use_bash, label = "Use Bash (CC)" },
            { element = menu_elements.bear_use_growl, label = "Use Growl (Taunt)" },
            { element = menu_elements.bear_use_enrage, label = "Use Enrage" },
            { element = menu_elements.bear_use_faerie_fire, label = "Use Faerie Fire" },
            { element = menu_elements.bear_use_swipe, label = "Use Swipe (AoE)" },
        }
    })

    tab:slider_list({
        label = "Rage & HP Management",
        elements = {
            slider_entry(menu_elements.tank_maul_rage, "Maul above Rage", " Rage", 10, 100),
            slider_entry(menu_elements.tank_frenzied_reg_hp, "Frenzied Reg at HP", "%", 5, 50),
        }
    })
end)

settings_ui:add_tab({ id = "balance", label = "Balance" }, function(tab)
    tab:checkbox_grid({
        label = "Balance Options",
        columns = 2,
        elements = {
            { element = menu_elements.balance_use_insect_swarm, label = "Use Insect Swarm" },
            { element = menu_elements.balance_use_faerie_fire, label = "Use Faerie Fire" },
            { element = menu_elements.balance_use_starfire, label = "Use Starfire" },
            { element = menu_elements.balance_use_roots, label = "Use Roots (HC)" },
        }
    })

    tab:slider_list({
        label = "Mana Settings",
        elements = {
            slider_entry(menu_elements.balance_min_mana, "Min Mana % per spell", "%", 5, 50),
            slider_entry(menu_elements.balance_auto_attack_hp, "Auto Attack at Target HP", "%", 0, 100),
        }
    })
end)

settings_ui:add_tab({ id = "buffs", label = "Buffs" }, function(tab)
    tab:checkbox_grid({
        label = "Auto-Buff Options",
        columns = 2,
        elements = {
            { element = menu_elements.auto_motw, label = "Auto Mark of the Wild" },
            { element = menu_elements.auto_thorns, label = "Auto Thorns" },
            { element = menu_elements.auto_form, label = "Auto-Transform to Spec Form" },
        }
    })
end)

settings_ui:add_tab({ id = "mana_ticks", label = "Resource Ticks" }, function(tab)
    if mana_tick_widget and mana_tick_widget.menu then
        tab:checkbox_grid({
            label = "Widget Display",
            columns = 2,
            elements = {
                { element = mana_tick_widget.menu.enable, label = "Enable Widget" },
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
    end
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
                label = "Mode",
                options = { "Out of Combat Only", "In Combat Only", "Always" },
                visible_when = auto_loot_enabled
            }
        }
    })

    tab:slider_list({
        label = "Auto Loot",
        elements = {
            slider_entry(menu_elements.auto_loot_max_attempts, "Max Attempts per Corpse", "", 1, 10, auto_loot_enabled),
            slider_entry(menu_elements.auto_loot_retry_delay, "Corpse Lockout (sec)", "s", 30, 200, auto_loot_enabled)
        }
    })

    tab:slider_list({
        label = "Auto Mining",
        elements = {
            slider_entry(menu_elements.auto_mine_range, "Mining Range", "yd", 2, 8, auto_mine_enabled)
        }
    })

    tab:slider_list({
        label = "Auto Herbs",
        elements = {
            slider_entry(menu_elements.auto_herb_range, "Herbing Range", "yd", 2, 8, auto_herb_enabled)
        }
    })

    tab:slider_list({
        label = "Auto Quest Interact",
        elements = {
            slider_entry(menu_elements.auto_quest_interact_range, "Interact Range", "yd", 2, 8, quest_interact_enabled)
        }
    })

    tab:slider_list({
        label = "Auto Skinning",
        elements = {
            slider_entry(menu_elements.auto_skin_range, "Skinning Range", "yd", 2, 8, skinning_enabled)
        }
    })
end)

-- ============================================================================
-- MENU RENDERING (Classic tree)
-- ============================================================================

function druid:on_menu_render()
    settings_ui:on_menu_render()

    menu_elements.main_tree:render("Druid Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        core.menu.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.pvp_toggle:render("PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_toggle:get_key_code()) .. ")")
        
        core.menu.header():render("PVP (ERA)", color.new(220, 170, 255, 220))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation (Overlay)")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_rotation_tick_rate:render("PvP Candidate Scan Interval (ms)")
        end
        
        menu_elements.spec_selector:render("Spec Selector", { "Resto", "Cat", "Bear", "Balance" })

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end
        menu_elements.reset_ui_position:render("Reset UI to Default Position")

        menu_elements.healing_tree:render("Restoration Settings", function()
            menu_elements.enable_healing:render("Enable Healing Logic")
            menu_elements.rejuvenation_hp:render("Rejuvenation HP %")
            menu_elements.regrowth_hp:render("Regrowth HP %")
            menu_elements.healing_touch_hp:render("Healing Touch HP %")
            menu_elements.swiftmend_hp:render("Swiftmend HP %")
            menu_elements.resto_use_ns:render("Use Nature's Swiftness")
            menu_elements.resto_use_innervate:render("Use Innervate")
            menu_elements.resto_use_tranquility:render("Use Tranquility")
        end)

        menu_elements.feral_dps_tree:render("Cat DPS Settings", function()
            menu_elements.cat_use_rake:render("Use Rake")
            menu_elements.cat_use_shred:render("Use Shred")
            menu_elements.cat_use_ferocious_bite:render("Use Ferocious Bite")
            menu_elements.cat_use_prowl:render("Use Prowl/Opener")
            menu_elements.cat_use_powershift:render("Powershifting")
            menu_elements.cat_rip_cp:render("Rip at CP")
            menu_elements.cat_fb_cp:render("FB at CP")
        end)

        menu_elements.tank_tree:render("Bear Tank Settings", function()
            menu_elements.tank_use_demo_roar:render("Use Demo Roar")
            menu_elements.tank_use_bash:render("Use Bash")
            menu_elements.bear_use_growl:render("Use Growl")
            menu_elements.bear_use_enrage:render("Use Enrage")
            menu_elements.bear_use_swipe:render("Use Swipe")
            menu_elements.tank_maul_rage:render("Maul Rage Threshold")
            menu_elements.tank_frenzied_reg_hp:render("Frenzied Regen HP %")
        end)

        menu_elements.balance_tree:render("Balance Settings", function()
            menu_elements.balance_use_insect_swarm:render("Use Insect Swarm")
            menu_elements.balance_use_faerie_fire:render("Use Faerie Fire")
            menu_elements.balance_use_starfire:render("Use Starfire")
            menu_elements.balance_min_mana:render("Min Mana %")
        end)

        menu_elements.mana_ticks_tree:render("Resource Widget", function()
            if mana_tick_widget and mana_tick_widget.on_menu_render then
                mana_tick_widget:on_menu_render()
            end
        end)
    end)
end

-- ============================================================================
-- UPDATE (per-frame logic)
-- ============================================================================

local f1_key_was_pressed = false

function druid:on_update(local_player)
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

    -- Position Reset
    if menu_elements.reset_ui_position:get_state() then
        if settings_ui.menu.pos_x then settings_ui.menu.pos_x:set(700) end
        if settings_ui.menu.pos_y then settings_ui.menu.pos_y:set(200) end
        menu_elements.reset_ui_position:set(false)
    end

    if not local_player or not menu_elements.enable_script_check:get_state() then return end
    if not plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) then return end

    if local_player:is_mounted() then return end

    local is_eating_or_drinking = false
    pcall(function()
        local eating_buff_data = buff_manager:get_buff_data(local_player, { 431, 434 })
        is_eating_or_drinking = eating_buff_data and eating_buff_data.is_active == true
    end)
    if is_eating_or_drinking then return end

    -- Resource tick tracking
    local tick_tracker = resource_ticks.get()


    -- Initialize helpers with menu and tick tracker
    helpers:set_menu(menu_elements)
    helpers:set_tick_tracker(tick_tracker)

    -- Execute rotation
    local now = core.game_time()
    if performance:begin_update(local_player, menu_elements, now) then
        rotation_logic:execute(local_player, helpers)
    end

    -- Automation (runs regardless of rotation state)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
end

-- ============================================================================
-- RENDERING
-- ============================================================================

function druid:on_render()
    settings_ui:on_render()
end

function druid:on_control_panel_render()
    local elements = {}
    control_panel_helper:insert_toggle(elements, {
        name = "Druid Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")",
        keybind = menu_elements.enable_toggle
    })
    control_panel_helper:insert_toggle(elements, {
        name = "Burst Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")",
        keybind = menu_elements.cooldowns_toggle
    })
    control_panel_helper:insert_toggle(elements, {
        name = "PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_toggle:get_key_code()) .. ")",
        keybind = menu_elements.pvp_toggle
    })
    return elements
end

return druid
