-- ============================================================================
-- Druid Rotation Module (AIO-compatible)
-- Burning Crusade Classic (TBC)
-- ============================================================================

local druid = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/druid/tbc/rotation/init")

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

---@type auto_consumables
local auto_consumables = require("shared/auto_consumables")

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

    -- Main toggles
    enable_script_check = md.checkbox(true, "druid_tbc_enable_script"),
    enable_toggle = md.keybind(999, true, "druid_tbc_enable_toggle"),
    cooldowns_toggle = md.keybind(999, false, "druid_tbc_cooldowns_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "druid_tbc_ui_toggle_hotkey"),
    spec_selector = md.combobox(1, "druid_tbc_spec_selector"), -- 1: Heal, 2: Cat, 3: Tank, 4: Balance
    reset_ui_position = md.checkbox(false, "druid_tbc_reset_ui_position"),
    
    -- Healing Settings
    enable_healing = md.checkbox(true, "druid_tbc_enable_healing"),
    tank_emergency_hp = md.slider_int(0, 100, 30, "druid_tbc_tank_emergency_hp"),
    player_emergency_hp = md.slider_int(0, 100, 40, "druid_tbc_player_emergency_hp"),
    lifebloom_hp = md.slider_int(0, 100, 95, "druid_tbc_lifebloom_hp"),
    rejuvenation_hp = md.slider_int(0, 100, 85, "druid_tbc_rejuvenation_hp"),
    regrowth_hp = md.slider_int(0, 100, 60, "druid_tbc_regrowth_hp"),
    healing_touch_hp = md.slider_int(0, 100, 50, "druid_tbc_healing_touch_hp"),
    swiftmend_hp = md.slider_int(0, 100, 35, "druid_tbc_swiftmend_hp"),
    
    -- Feral DPS (Cat)
    cat_mangle_priority = core.menu.checkbox(true, "druid_tbc_cat_mangle_pri"),
    cat_rip_cp = core.menu.slider_int(1, 5, 5, "druid_tbc_cat_rip_cp"),
    cat_use_rake = core.menu.checkbox(true, "druid_tbc_cat_use_rake"),
    cat_use_shred = core.menu.checkbox(true, "druid_tbc_cat_use_shred"),
    cat_use_tigers_fury = core.menu.checkbox(true, "druid_tbc_cat_use_tigers_fury"),
    cat_powershift_enabled = core.menu.checkbox(true, "druid_tbc_cat_powershift"),
    cat_powershift_energy = core.menu.slider_int(10, 60, 30, "druid_tbc_cat_ps_energy"),
    cat_bite_weave = core.menu.checkbox(true, "druid_tbc_cat_bite_weave"),
    cat_use_faerie_fire = core.menu.checkbox(true, "druid_tbc_cat_ff"),
    cat_rip_min_ttd = core.menu.slider_int(5, 30, 12, "druid_tbc_cat_rip_ttd"),

    -- Tank (Bear)
    tank_use_mangle = core.menu.checkbox(true, "druid_tbc_tank_use_mangle"),
    tank_use_lacerate = core.menu.checkbox(true, "druid_tbc_tank_use_lacerate"),
    tank_maul_rage = core.menu.slider_int(10, 100, 15, "druid_tbc_tank_maul_rage"),
    tank_frenzied_reg_hp = core.menu.slider_int(5, 50, 25, "druid_tbc_tank_frenzied_reg_hp"),
    tank_use_demo_roar = core.menu.checkbox(true, "druid_tbc_tank_use_demo_roar"),
    tank_use_bash = core.menu.checkbox(true, "druid_tbc_tank_use_bash"),
    tank_use_swipe = core.menu.checkbox(true, "druid_tbc_tank_swipe"),
    tank_swipe_count = core.menu.slider_int(2, 5, 2, "druid_tbc_tank_swipe_count"),
    tank_use_feral_charge = core.menu.checkbox(true, "druid_tbc_tank_charge"),
    tank_enrage_prepull = core.menu.checkbox(true, "druid_tbc_tank_enrage"),

    -- Balance
    balance_use_starfire = core.menu.checkbox(true, "druid_tbc_balance_starfire"),
    balance_use_insect_swarm = core.menu.checkbox(true, "druid_tbc_balance_insect"),
    balance_min_mana = core.menu.slider_int(5, 50, 15, "druid_tbc_balance_min_mana"),
    balance_auto_attack_hp = core.menu.slider_int(0, 100, 10, "druid_tbc_balance_auto_attack_hp"),
    balance_use_hurricane = core.menu.checkbox(true, "druid_tbc_balance_hurricane"),
    balance_hurricane_count = core.menu.slider_int(2, 6, 3, "druid_tbc_balance_hurricane_count"),
    balance_use_force_of_nature = core.menu.checkbox(true, "druid_tbc_balance_fon"),
    balance_innervate_mana = core.menu.slider_int(10, 50, 30, "druid_tbc_balance_innervate"),

    -- Restoration Advanced
    resto_lifebloom_stacks = core.menu.slider_int(1, 3, 3, "druid_tbc_resto_lb_stacks"),
    resto_innervate_mana = core.menu.slider_int(10, 50, 20, "druid_tbc_resto_innervate"),
    resto_use_natures_swiftness = core.menu.checkbox(true, "druid_tbc_resto_ns"),
    resto_tranquility_count = core.menu.slider_int(2, 5, 3, "druid_tbc_resto_tranq_count"),
    resto_ns_hp = core.menu.slider_int(10, 40, 25, "druid_tbc_resto_ns_hp"),

    -- PvP
    pvp_mode_toggle = core.menu.keybind(999, false, "druid_tbc_pvp_toggle"),
    pvp_use_cyclone = core.menu.checkbox(true, "druid_tbc_pvp_cyclone"),
    pvp_barkskin_hp = core.menu.slider_int(0, 100, 40, "druid_tbc_pvp_barkskin_hp"),
    pvp_bear_hp = core.menu.slider_int(0, 100, 30, "druid_tbc_pvp_bear_hp"),
    pvp_faerie_fire_stealth = core.menu.checkbox(true, "druid_tbc_pvp_ff_stealth"),
    pvp_use_roots = core.menu.checkbox(true, "druid_tbc_pvp_roots"),
    pvp_use_natures_grasp = core.menu.checkbox(true, "druid_tbc_pvp_natures_grasp"),

    -- Consumables
    use_health_potions = core.menu.checkbox(true, "druid_tbc_use_hp_pot"),
    health_potion_hp = core.menu.slider_int(10, 60, 30, "druid_tbc_hp_pot_hp"),
    use_mana_potions = core.menu.checkbox(true, "druid_tbc_use_mp_pot"),
    mana_potion_pct = core.menu.slider_int(10, 50, 20, "druid_tbc_mp_pot_pct"),
    use_healthstone = core.menu.checkbox(true, "druid_tbc_use_hs"),
    healthstone_hp = core.menu.slider_int(10, 60, 25, "druid_tbc_hs_hp"),

    -- Interrupts
    interrupt_enabled = core.menu.checkbox(true, "druid_tbc_interrupt"),
    interrupt_bash = core.menu.checkbox(true, "druid_tbc_interrupt_bash"),
    interrupt_feral_charge = core.menu.checkbox(true, "druid_tbc_interrupt_charge"),

    -- Debug
    debug_logging = core.menu.checkbox(false, "druid_tbc_debug_logging"),

    -- Buffs
    use_buffs = md.checkbox(true, "druid_tbc_use_buffs"),
    auto_form = md.checkbox(true, "druid_tbc_auto_form"),
    
    -- Automation
    auto_loot_enabled = md.checkbox(true, "druid_tbc_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "druid_tbc_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "druid_tbc_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "druid_tbc_auto_loot_retry_delay"),

    auto_mine_enabled = md.checkbox(true, "druid_tbc_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "druid_tbc_auto_mine_range"),

    auto_herb_enabled = md.checkbox(true, "druid_tbc_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "druid_tbc_auto_herb_range"),

    auto_quest_interact_enabled = md.checkbox(false, "druid_tbc_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "druid_tbc_auto_quest_interact_range"),

    auto_skin_enabled = md.checkbox(false, "druid_tbc_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "druid_tbc_auto_skin_range"),

    -- Auto Consumables
    auto_consumables_enabled = md.checkbox(true, "druid_tbc_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "druid_tbc_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 40, "druid_tbc_auto_drink_pct"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = md.checkbox(false, "druid_tbc_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "druid_tbc_pvp_rotation_tick_rate"),
}

-- Custom UI Setup
local settings_ui = rotation_settings_ui.new({
    id = "druid_tbc_rotation",
    title = "Druid (TBC) Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 650,
    theme = "druid"
})
settings_ui:enable_presets(menu_elements, md)

-- Resource Tick Widget (Energy/Mana Tick)
local mana_tick_widget = resource_ticks_widget.new({
    id = "druid_tbc_mana_ticks",
    label = "Resource Ticks",
    menu_prefix = "druid_tbc_mana_ticks",
    default_x = 600,
    default_y = 520,
    default_w = 240,
    default_h = 80,
    enable_window = true
})

-- Configure widget defaults for Druid
if mana_tick_widget and mana_tick_widget.menu then
    pcall(function()
        mana_tick_widget.menu.show_energy:set(true)
        mana_tick_widget.menu.show_mana:set(true)
        mana_tick_widget.menu.show_fsr:set(true)
    end)
end

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

-- UI TABS
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
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" },
            { element = menu_elements.auto_form, label = "Auto-Transform" },
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" },
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "restoration", label = "Restoration" }, function(tab)
    tab:checkbox_grid({
        label = "Healing Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_healing, label = "Enable Healing Logic" },
            { element = menu_elements.resto_use_natures_swiftness, label = "Use Nature's Swiftness" },
        }
    })

    tab:slider_list({
        label = "Restoration Thresholds",
        elements = {
            slider_entry(menu_elements.tank_emergency_hp, "Tank Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.player_emergency_hp, "Player Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.lifebloom_hp, "Lifebloom HP", "%", 0, 100),
            slider_entry(menu_elements.rejuvenation_hp, "Rejuvenation HP", "%", 0, 100),
            slider_entry(menu_elements.regrowth_hp, "Regrowth HP", "%", 0, 100),
            slider_entry(menu_elements.healing_touch_hp, "Healing Touch HP", "%", 0, 100),
            slider_entry(menu_elements.swiftmend_hp, "Swiftmend HP", "%", 0, 100),
            slider_entry(menu_elements.resto_ns_hp, "NS + HT Emergency HP", "%", 10, 40),
        }
    })

    tab:slider_list({
        label = "Advanced",
        elements = {
            slider_entry(menu_elements.resto_lifebloom_stacks, "Lifebloom Target Stacks", "", 1, 3),
            slider_entry(menu_elements.resto_innervate_mana, "Innervate at Mana %", "%", 10, 50),
            slider_entry(menu_elements.resto_tranquility_count, "Tranquility at X Allies Low", "", 2, 5),
        }
    })
end)

settings_ui:add_tab({ id = "feral_cat", label = "Feral (Cat)" }, function(tab)
    tab:checkbox_grid({
        label = "Cat DPS Options",
        columns = 2,
        elements = {
            { element = menu_elements.cat_mangle_priority, label = "Prioritize Mangle" },
            { element = menu_elements.cat_use_rake, label = "Use Rake" },
            { element = menu_elements.cat_use_shred, label = "Use Shred" },
            { element = menu_elements.cat_use_tigers_fury, label = "Use Tiger's Fury" },
            { element = menu_elements.cat_use_faerie_fire, label = "Use Faerie Fire" },
            { element = menu_elements.cat_bite_weave, label = "Bite Weave (FB w/ Rip)" },
        }
    })

    tab:checkbox_grid({
        label = "Powershifting",
        columns = 2,
        elements = {
            { element = menu_elements.cat_powershift_enabled, label = "Enable Powershifting" },
        }
    })

    tab:slider_list({
        label = "Cat Thresholds",
        elements = {
            slider_entry(menu_elements.cat_rip_cp, "Rip at CP count", " CP", 1, 5),
            slider_entry(menu_elements.cat_powershift_energy, "Powershift below Energy", " E", 10, 60),
            slider_entry(menu_elements.cat_rip_min_ttd, "Rip min TTD", "s", 5, 30),
        }
    })
end)

settings_ui:add_tab({ id = "feral_bear", label = "Feral (Bear)" }, function(tab)
    tab:checkbox_grid({
        label = "Tanking Options",
        columns = 2,
        elements = {
            { element = menu_elements.tank_use_mangle, label = "Use Mangle" },
            { element = menu_elements.tank_use_lacerate, label = "Use Lacerate" },
            { element = menu_elements.tank_use_demo_roar, label = "Use Demoralizing Roar" },
            { element = menu_elements.tank_use_bash, label = "Use Bash (CC)" },
            { element = menu_elements.tank_use_swipe, label = "Use Swipe (AoE)" },
            { element = menu_elements.tank_use_feral_charge, label = "Use Feral Charge" },
            { element = menu_elements.tank_enrage_prepull, label = "Enrage (Pre-pull/Low Rage)" },
        }
    })

    tab:slider_list({
        label = "Rage & HP Management",
        elements = {
            slider_entry(menu_elements.tank_maul_rage, "Maul above Rage", " Rage", 10, 100),
            slider_entry(menu_elements.tank_frenzied_reg_hp, "Frenzied Reg at HP", "%", 5, 50),
            slider_entry(menu_elements.tank_swipe_count, "Swipe at X enemies", "", 2, 5),
        }
    })
end)

settings_ui:add_tab({ id = "balance", label = "Balance" }, function(tab)
    tab:checkbox_grid({
        label = "Balance Options",
        columns = 2,
        elements = {
            { element = menu_elements.balance_use_starfire, label = "Use Starfire" },
            { element = menu_elements.balance_use_insect_swarm, label = "Use Insect Swarm" },
            { element = menu_elements.balance_use_hurricane, label = "Use Hurricane (AoE)" },
            { element = menu_elements.balance_use_force_of_nature, label = "Use Force of Nature" },
        }
    })

    tab:slider_list({
        label = "Balance Thresholds",
        elements = {
            slider_entry(menu_elements.balance_min_mana, "Min Mana % to cast", "%", 5, 50),
            slider_entry(menu_elements.balance_auto_attack_hp, "Auto Attack at Target HP", "%", 0, 100),
            slider_entry(menu_elements.balance_hurricane_count, "Hurricane at X enemies", "", 2, 6),
            slider_entry(menu_elements.balance_innervate_mana, "Innervate at Mana %", "%", 10, 50),
        }
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
    tab:keybind_grid({
        elements = {
            menu_elements.pvp_mode_toggle,
        },
        labels = {
            "PvP Mode Toggle",
        }
    })

    tab:checkbox_grid({
        label = "PvP Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_use_cyclone, label = "Use Cyclone" },
            { element = menu_elements.pvp_use_roots, label = "Use Entangling Roots" },
            { element = menu_elements.pvp_use_natures_grasp, label = "Use Nature's Grasp" },
            { element = menu_elements.pvp_faerie_fire_stealth, label = "FF Anti-Stealth" },
        }
    })

    tab:checkbox_grid({
        label = "PvP Mode",
        columns = 2,
        elements = {
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Rotation" }
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })

    tab:slider_list({
        label = "PvP Thresholds",
        elements = {
            slider_entry(menu_elements.pvp_barkskin_hp, "Barkskin at HP", "%", 0, 100),
            slider_entry(menu_elements.pvp_bear_hp, "Bear Form at HP", "%", 0, 100),
        }
    })
end)

settings_ui:add_tab({ id = "consumables", label = "Consumables" }, function(tab)
    tab:checkbox_grid({
        label = "Consumable Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.use_health_potions, label = "Use Health Potions" },
            { element = menu_elements.use_mana_potions, label = "Use Mana Potions" },
            { element = menu_elements.use_healthstone, label = "Use Healthstone" },
        }
    })

    tab:slider_list({
        label = "Consumable Thresholds",
        elements = {
            slider_entry(menu_elements.health_potion_hp, "Health Potion at HP", "%", 10, 60),
            slider_entry(menu_elements.mana_potion_pct, "Mana Potion at Mana", "%", 10, 50),
            slider_entry(menu_elements.healthstone_hp, "Healthstone at HP", "%", 10, 60),
        }
    })

    tab:separator()
    tab:checkbox_grid({
        label = "Auto Recovery",
        columns = 1,
        elements = {
            { element = menu_elements.auto_consumables_enabled, label = "Enable Auto Food/Drink" },
        }
    })

    tab:slider_list({
        label = "Auto Recovery Thresholds",
        elements = {
            slider_entry(menu_elements.auto_food_pct, "Food Threshold %", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
            slider_entry(menu_elements.auto_drink_pct, "Drink Threshold %", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
        }
    })
end)

settings_ui:add_tab({ id = "interrupts", label = "Interrupts" }, function(tab)
    tab:checkbox_grid({
        label = "Interrupt Settings",
        columns = 2,
        elements = {
            { element = menu_elements.interrupt_enabled, label = "Enable Interrupts" },
            { element = menu_elements.interrupt_bash, label = "Use Bash" },
            { element = menu_elements.interrupt_feral_charge, label = "Use Feral Charge" },
        }
    })

    tab:checkbox_grid({
        label = "Debug",
        columns = 2,
        elements = {
            { element = menu_elements.debug_logging, label = "Enable Debug Logging" },
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

-- RENDERING
function druid:on_menu_render()
    settings_ui:on_menu_render()
    
    menu_elements.main_tree:render("Druid Rotation (TBC)", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))
        
        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.spec_selector:render("Spec Selector", { "Resto", "Cat", "Bear", "Balance" })
        
        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end
        menu_elements.reset_ui_position:render("Reset UI to Default Position")

        menu_elements.healing_tree:render("Restoration Settings", function()
            menu_elements.enable_healing:render("Enable Healing Logic")
            menu_elements.lifebloom_hp:render("Lifebloom HP %")
            menu_elements.rejuvenation_hp:render("Rejuvenation HP %")
        end)

        menu_elements.mana_ticks_tree:render("Resource Widget", function()
            if mana_tick_widget and mana_tick_widget.on_menu_render then
                mana_tick_widget:on_menu_render()
            end
        end)
    end)
end

-- UPDATE
local f1_key_was_pressed = false
local last_rotation_tick_ms = 0

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

	    if not local_player then return end
	    if rotation_pause.is_eating_or_drinking(local_player) then return end
	    if not menu_elements.enable_script_check:get_state() then return end
	    if not plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) then return end
    
    if local_player:is_mounted() then return end
    
	    local tick_tracker = resource_ticks.get()
	    if tick_tracker then tick_tracker:on_update(local_player) end

    local now = core.game_time()
    local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
    local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
    if (now - last_rotation_tick_ms) >= tick_rate then
        last_rotation_tick_ms = now
        rotation_logic:execute(local_player, menu_elements, tick_tracker)
    end

    -- Automation (runs even if rotation is toggled off)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)

    auto_consumables:on_update(local_player, menu_elements)
end

function druid:on_render()
    settings_ui:on_render()
end

function druid:on_control_panel_render()
    local elements = {}
    control_panel_helper:insert_toggle(elements, {
        name = "Druid (TBC) Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")",
        keybind = menu_elements.enable_toggle
    })
    control_panel_helper:insert_toggle(elements, {
        name = "Burst Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")",
        keybind = menu_elements.cooldowns_toggle
    })
    return elements
end

return druid
