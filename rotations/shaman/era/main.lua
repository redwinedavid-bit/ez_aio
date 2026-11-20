-- ============================================================================
local performance = require("shared/rotation_performance")
-- Shaman Restoration Rotation Module (AIO-compatible)
-- World of Warcraft Classic ERA
-- ============================================================================

local shaman = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/shaman/era/rotation_logic")

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
    totems_tree = md.tree_node(),
    buffs_tree = md.tree_node(),
    dispel_tree = md.tree_node(),
    cooldowns_tree = md.tree_node(),
    consumables_tree = md.tree_node(),
    leveling_tree = md.tree_node(),
    mana_ticks_tree = md.tree_node(),
    automation_tree = md.tree_node(),

    -- Main toggles
    enable_script_check = md.checkbox(true, "shaman_enable_script"),
    enable_toggle = md.keybind(999, true, "shaman_enable_toggle"),
    cooldowns_toggle = md.keybind(999, false, "shaman_cooldowns_toggle"),
    healing_only_toggle = md.keybind(999, false, "shaman_healing_only_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "shaman_ui_toggle_hotkey"),
    healing_only = md.checkbox(false, "shaman_healing_only"),

    -- PvP
    enable_pvp_mode = md.checkbox(false, "shaman_era_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "shaman_era_pvp_rotation_tick_rate"),

    -- Healing Settings
    healing_mode = md.combobox(1, "shaman_healing_mode"), -- 1=Auto, 2=Dungeon, 3=Raid
    tank_emergency_hp = md.slider_int(0, 100, 25, "shaman_tank_emergency_hp"),
    player_emergency_hp = md.slider_int(0, 100, 35, "shaman_player_emergency_hp"),
    lesser_healing_wave_hp = md.slider_int(0, 100, 45, "shaman_lesser_healing_wave_hp"),
    healing_wave_hp = md.slider_int(0, 100, 70, "shaman_healing_wave_hp"),
    earth_shield_hp = md.slider_int(0, 100, 100, "shaman_earth_shield_hp"),
    chain_heal_hp = md.slider_int(0, 100, 75, "shaman_chain_heal_hp"),
    group_aoe_threshold = md.slider_int(1, 10, 3, "shaman_group_aoe_threshold"),
    aoe_hp_threshold = md.slider_int(0, 100, 70, "shaman_aoe_hp_threshold"),
    mana_low_threshold = md.slider_int(0, 100, 20, "shaman_mana_low_threshold"),
    
    -- Healing Spell Toggles
    use_earth_shield = md.checkbox(true, "shaman_use_earth_shield"),
    enable_chain_heal = md.checkbox(true, "shaman_enable_chain_heal"),
    use_downranking = md.checkbox(true, "shaman_use_downranking"),
    enable_smart_downranking = md.checkbox(true, "shaman_enable_smart_downranking"),
    downrank_penalty_prevention = md.checkbox(true, "shaman_downrank_penalty_prevention"),

    -- Totems
    use_totems = md.checkbox(true, "shaman_use_totems"),
    use_healing_stream_totem = md.checkbox(true, "shaman_use_healing_stream_totem"),
    use_mana_spring_totem = md.checkbox(true, "shaman_use_mana_spring_totem"),
    use_tremor_totem = md.checkbox(true, "shaman_use_tremor_totem"),
    use_grounding_totem = md.checkbox(false, "shaman_use_grounding_totem"),
    use_searing_totem = md.checkbox(true, "shaman_use_searing_totem"),
    use_totem_of_wrath = md.checkbox(true, "shaman_use_totem_of_wrath"),
    use_windfury_totem = md.checkbox(false, "shaman_use_windfury_totem"),
    -- Removed Wrath of Air (Lvl 64)
    enable_totem_twisting = md.checkbox(false, "shaman_enable_totem_twisting"),

    -- Buffs
    use_water_shield = md.checkbox(true, "shaman_use_water_shield"),
    use_lightning_shield = md.checkbox(false, "shaman_use_lightning_shield"),
    use_weapon_buff = md.checkbox(true, "shaman_use_weapon_buff"),
    weapon_buff_type = md.combobox(1, "shaman_weapon_buff_type"),

    -- Dispel
    use_dispel = md.checkbox(true, "shaman_use_dispel"),
    use_purge = md.checkbox(true, "shaman_use_purge"),

    -- Cooldowns
    -- Removed Bloodlust (Lvl 70)
    use_natures_swiftness = md.checkbox(true, "shaman_use_natures_swiftness"),
    natures_swiftness_hp = md.slider_int(10, 40, 20, "shaman_natures_swiftness_hp"),
    use_mana_tide_totem = md.checkbox(true, "shaman_use_mana_tide_totem"),
    mana_tide_group_mana = md.slider_int(20, 80, 40, "shaman_mana_tide_group_mana"),
    mana_tide_min_players = md.slider_int(1, 5, 2, "shaman_mana_tide_min_players"),
    mana_tide_panic_key = md.keybind(999, false, "shaman_mana_tide_panic_key"),

    -- Consumables
    use_hp_potions = md.checkbox(true, "shaman_use_hp_potions"),
    hp_potion_at = md.slider_int(10, 50, 35, "shaman_hp_potion_at"),
    use_mana_potions = md.checkbox(true, "shaman_use_mana_potions"),
    mana_potion_at = md.slider_int(10, 40, 25, "shaman_mana_potion_at"),

    -- Leveling/Solo DPS
    enable_leveling_mode = md.checkbox(true, "shaman_enable_leveling_mode"),
    solo_dps_mana = md.slider_int(20, 80, 40, "shaman_solo_dps_mana"),
    solo_dps_group_hp = md.slider_int(60, 100, 80, "shaman_solo_dps_group_hp"),
    auto_attack_target = md.checkbox(true, "shaman_attack_on_target"),
    use_lightning_bolt = md.checkbox(true, "shaman_use_lightning_bolt"),
    use_chain_lightning = md.checkbox(true, "shaman_use_chain_lightning"),
    use_flame_shock = md.checkbox(true, "shaman_use_flame_shock"),
    use_earth_shock = md.checkbox(true, "shaman_use_earth_shock"),
    finish_with_melee = md.checkbox(true, "shaman_finish_with_melee"),
    finish_with_melee_hp = md.slider_int(5, 50, 15, "shaman_finish_with_melee_hp"),

    -- Automation
    auto_loot_enabled = md.checkbox(true, "shaman_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "shaman_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "shaman_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "shaman_auto_loot_retry_delay"),
    auto_mine_enabled = md.checkbox(true, "shaman_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "shaman_auto_mine_range"),
    auto_herb_enabled = md.checkbox(true, "shaman_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "shaman_auto_herb_range"),
    auto_quest_interact_enabled = md.checkbox(false, "shaman_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "shaman_auto_quest_interact_range"),
    auto_skin_enabled = md.checkbox(false, "shaman_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "shaman_auto_skin_range"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "shaman_rotation",
    title = "Shaman BxA (AIO)",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 650,
    theme = "shaman"
})
settings_ui:enable_presets(menu_elements, md)

-- Resource Tick Widget (Mana Tick & 5SR Timer)
local mana_tick_widget = resource_ticks_widget.new({
    id = "shaman_mana_ticks",
    label = "Mana Ticks & 5SR",
    menu_prefix = "shaman_mana_ticks",
    default_x = 600,
    default_y = 520,
    default_w = 240,
    default_h = 80,
    enable_window = true
})

-- Configure widget defaults for Shaman (show mana and 5SR, hide energy)
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

-- Helper functions for conditional visibility
local function chain_heal_enabled()
    return menu_elements.enable_chain_heal:get_state()
end

local function totems_enabled()
    return menu_elements.use_totems:get_state()
end

local function cooldowns_enabled()
    return menu_elements.use_natures_swiftness:get_state() or menu_elements.use_mana_tide_totem:get_state()
end

local function natures_swiftness_enabled()
    return menu_elements.use_natures_swiftness:get_state()
end

local function mana_tide_enabled()
    return menu_elements.use_mana_tide_totem:get_state()
end

-- Helper function to check if Healing Only mode is active (via keybind toggle OR checkbox)
local function healing_only_enabled()
    -- First check the checkbox
    if menu_elements.healing_only:get_state() then
        return true
    end
    return plugin_helper:is_toggle_enabled(menu_elements.healing_only_toggle) == true
end

local function hp_potions_enabled()
    return menu_elements.use_hp_potions:get_state()
end

local function mana_potions_enabled()
    return menu_elements.use_mana_potions:get_state()
end

local function leveling_mode_enabled()
    return menu_elements.enable_leveling_mode:get_state()
end

local function finish_with_melee_enabled()
    return menu_elements.finish_with_melee:get_state()
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

local function weapon_buff_enabled()
    return menu_elements.use_weapon_buff:get_state()
end

local function slider_entry(element, label, suffix, min_value, max_value, visible_when)
    local entry = {
        element = element,
        label = label,
        suffix = suffix or "",
        visible_when = visible_when
    }
    if min_value or max_value then
        entry.bounds = {}
        if min_value then
            entry.bounds.min = min_value
        end
        if max_value then
            entry.bounds.max = max_value
        end
    end
    return entry
end

-- ============================================================================
-- UI TABS
-- ============================================================================

settings_ui:add_tab({ id = "core_controls", label = "Core Controls" }, function(tab)
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
            menu_elements.cooldowns_toggle,
            menu_elements.healing_only_toggle
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
            "Healing Only Mode"
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = menu_elements.healing_only, label = "Healing Only (No DPS)" }
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
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
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Candidate Scan Interval", "ms", 30, 100)
        }
    })
end)

settings_ui:add_tab({ id = "healing", label = "Healing Logic" }, function(tab)
    tab:combo_list({
        label = "Healing Mode",
        elements = {
            {
                element = menu_elements.healing_mode,
                label = "Healing Logic",
                options = { "Auto (Based on Group Size)", "Dungeon (Tank Priority)", "Raid (Chain Heal Focus)" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Healing Spells",
        columns = 2,
        elements = {
            { element = menu_elements.use_earth_shield, label = "Maintain Earth Shield (Tank)" },
            { element = menu_elements.enable_chain_heal, label = "Use Chain Heal (AoE)" },
            { element = menu_elements.use_downranking, label = "Use Downranking" },
            { element = menu_elements.enable_smart_downranking, label = "Smart Downranking Selection" },
            { element = menu_elements.downrank_penalty_prevention, label = "Avoid TBC Healing Penalty" },
            { element = menu_elements.use_purge, label = "Use Purge (Enemy Magic)" }
        }
    })

    tab:slider_list({
        label = "Emergency Thresholds",
        elements = {
            slider_entry(menu_elements.tank_emergency_hp, "Tank Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.player_emergency_hp, "Player Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.lesser_healing_wave_hp, "Lesser Healing Wave HP", "%", 0, 100)
        }
    })

    tab:slider_list({
        label = "Standard Healing Thresholds",
        elements = {
            slider_entry(menu_elements.healing_wave_hp, "Healing Wave HP", "%", 0, 100),
            slider_entry(menu_elements.earth_shield_hp, "Earth Shield Refresh HP", "%", 0, 100),
            slider_entry(menu_elements.chain_heal_hp, "Chain Heal HP", "%", 0, 100, chain_heal_enabled)
        }
    })

    tab:slider_list({
        label = "AoE Healing (Chain Heal)",
        elements = {
            slider_entry(menu_elements.group_aoe_threshold, "Min Players Low HP", "", 1, 10, chain_heal_enabled),
            slider_entry(menu_elements.aoe_hp_threshold, "AoE HP Threshold", "%", 0, 100, chain_heal_enabled)
        }
    })

    tab:slider_list({
        label = "Mana Management",
        elements = {
            slider_entry(menu_elements.mana_low_threshold, "Mana Low Threshold", "%", 0, 100)
        }
    })
end)

settings_ui:add_tab({ id = "totems", label = "Totems" }, function(tab)
    tab:checkbox_grid({
        label = "Totem Options",
        columns = 2,
        elements = {
            { element = menu_elements.use_totems, label = "Auto-Place Totems" },
            { element = menu_elements.use_healing_stream_totem, label = "Healing Stream Totem" },
            { element = menu_elements.use_mana_spring_totem, label = "Mana Spring Totem" },
            { element = menu_elements.use_tremor_totem, label = "Tremor Totem (Auto)" },
            { element = menu_elements.use_grounding_totem, label = "Grounding Totem (Auto)" },
            { element = menu_elements.use_searing_totem, label = "Searing Totem (Leveling)" },
            { element = menu_elements.use_totem_of_wrath, label = "Totem of Wrath (Fire)" },
            { element = menu_elements.use_windfury_totem, label = "Windfury Totem (Group)" }
        }
    })

    tab:checkbox_grid({
        label = "Advanced Totem Features",
        columns = 1,
        elements = {
            { element = menu_elements.enable_totem_twisting, label = "Enable Totem Twisting (Windfury/Grace)" }
        }
    })
end)

settings_ui:add_tab({ id = "buffs_dispel", label = "Buffs & Dispel" }, function(tab)
    tab:checkbox_grid({
        label = "Buff Options",
        columns = 2,
        elements = {

            { element = menu_elements.use_lightning_shield, label = "Maintain Lightning Shield (Low Prio)" },
            { element = menu_elements.use_weapon_buff, label = "Auto-Buff Weapon" }
        }
    })

    tab:combo_list({
        label = "Weapon Buff Type",
        elements = {
            {
                element = menu_elements.weapon_buff_type,
                label = "Weapon Buff",
                options = { "Rockbiter", "Flametongue", "Frostbrand", "Windfury" },
                visible_when = weapon_buff_enabled
            }
        }
    })

    tab:checkbox_grid({
        label = "Dispel Options",
        columns = 2,
        elements = {
            { element = menu_elements.use_dispel, label = "Auto-Cleanse (Poison/Disease)" },
            { element = menu_elements.use_purge, label = "Auto-Purge Enemy Magic" }
        }
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns" }, function(tab)
    tab:checkbox_grid({
        label = "Cooldown Usage",
        columns = 2,
        elements = {

            { element = menu_elements.use_natures_swiftness, label = "Use Nature's Swiftness" },
            { element = menu_elements.use_mana_tide_totem, label = "Use Mana Tide Totem" }
        }
    })

    tab:slider_list({
        label = "Cooldown Thresholds",
        elements = {
            slider_entry(menu_elements.natures_swiftness_hp, "Nature's Swiftness HP", "%", 10, 40, natures_swiftness_enabled),
            slider_entry(menu_elements.mana_tide_group_mana, "Mana Tide Group Mana", "%", 20, 60, mana_tide_enabled)
        }
    })

    tab:checkbox_grid({
        label = "Consumables",
        columns = 2,
        elements = {
            { element = menu_elements.use_hp_potions, label = "Use HP Potions" },
            { element = menu_elements.use_mana_potions, label = "Use Mana Potions" }
        }
    })

    tab:slider_list({
        label = "Consumable Thresholds",
        elements = {
            slider_entry(menu_elements.hp_potion_at, "HP Potion at %", "%", 10, 50, hp_potions_enabled),
            slider_entry(menu_elements.mana_potion_at, "Mana Potion at %", "%", 10, 40, mana_potions_enabled)
        }
    })
end)

settings_ui:add_tab({ id = "leveling", label = "Leveling/Solo" }, function(tab)
    tab:checkbox_grid({
        label = "Leveling Mode",
        columns = 2,
        elements = {
            { element = menu_elements.enable_leveling_mode, label = "Enable Leveling Mode" },
            { element = menu_elements.auto_attack_target, label = "Attack on Target" },
            { element = menu_elements.use_lightning_bolt, label = "Use Lightning Bolt" },
            { element = menu_elements.use_chain_lightning, label = "Use Chain Lightning (AoE)" },
            { element = menu_elements.use_flame_shock, label = "Use Flame Shock" },
            { element = menu_elements.use_earth_shock, label = "Use Earth Shock" },
            { element = menu_elements.finish_with_melee, label = "Finish with Melee" }
        }
    })

    tab:slider_list({
        label = "DPS Conditions",
        elements = {
            slider_entry(menu_elements.solo_dps_mana, "Min Mana % for DPS", "%", 20, 80, leveling_mode_enabled),
            slider_entry(menu_elements.solo_dps_group_hp, "Group HP % for DPS", "%", 60, 100, leveling_mode_enabled),
            slider_entry(menu_elements.finish_with_melee_hp, "Finish with Melee HP %", "%", 5, 50, finish_with_melee_enabled)
        }
    })
end)

settings_ui:add_tab({ id = "mana_ticks", label = "Mana Ticks & 5SR" }, function(tab)
    if mana_tick_widget and mana_tick_widget.menu then
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
                label = "Loot Mode",
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
-- MENU RENDERING
-- ============================================================================

function shaman:on_menu_render()
    settings_ui:on_menu_render()

    menu_elements.main_tree:render("Shaman BxA (AIO)", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        local current_spec = rotation_logic.get_current_spec()
        local spec_color = color.white()
        if current_spec == "Restoration" then spec_color = color.new(0, 191, 255, 255) -- Deep Sky Blue
        elseif current_spec == "Enhancement" then spec_color = color.new(255, 140, 0, 255) -- Dark Orange
        elseif current_spec == "Elemental" then spec_color = color.new(255, 215, 0, 255) -- Gold
        end

        md.header():render("Detected Spec: " .. current_spec, spec_color)
        
        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.cooldowns_toggle:render("Cooldowns Toggle (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")")

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end

        md.header():render("PVP (ERA)", color.new(220, 170, 255, 220))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation (Overlay)")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_rotation_tick_rate:render("PvP Candidate Scan Interval (ms)")
        end

        menu_elements.healing_tree:render("Healing Settings", function()
            menu_elements.enable_chain_heal:render("Use Chain Heal (AoE)")
            menu_elements.use_downranking:render("Use Downranking")
            
            menu_elements.tank_emergency_hp:render("Tank Emergency HP %")
            menu_elements.player_emergency_hp:render("Player Emergency HP %")
            menu_elements.lesser_healing_wave_hp:render("Lesser Healing Wave HP %")
            menu_elements.healing_wave_hp:render("Healing Wave HP %")
            
            if menu_elements.enable_chain_heal:get_state() then
                menu_elements.chain_heal_hp:render("Chain Heal HP %")
                menu_elements.group_aoe_threshold:render("AoE: Min Players Low HP")
                menu_elements.aoe_hp_threshold:render("AoE: HP Threshold %")
            end
            
            menu_elements.mana_low_threshold:render("Mana Low Threshold %")
        end)

        menu_elements.totems_tree:render("Totems", function()
            menu_elements.use_totems:render("Auto-Place Totems")
            
            if menu_elements.use_totems:get_state() then
                menu_elements.use_healing_stream_totem:render("Healing Stream Totem")
                menu_elements.use_mana_spring_totem:render("Mana Spring Totem")
                menu_elements.use_tremor_totem:render("Tremor Totem (Auto)")
                menu_elements.use_grounding_totem:render("Grounding Totem (Auto)")
                menu_elements.use_searing_totem:render("Searing Totem (Leveling)")
                menu_elements.use_windfury_totem:render("Windfury Totem (Group)")
                menu_elements.enable_totem_twisting:render("Enable Totem Twisting")
            end
        end)

        menu_elements.buffs_tree:render("Buffs & Dispel", function()
            menu_elements.use_lightning_shield:render("Maintain Lightning Shield")
            menu_elements.use_weapon_buff:render("Auto-Buff Weapon")
            
            if menu_elements.use_weapon_buff:get_state() then
                menu_elements.weapon_buff_type:render("Weapon Buff Type", {
                    "Rockbiter",
                    "Flametongue",
                    "Frostbrand",
                    "Windfury"
                })
            end
            
            menu_elements.use_dispel:render("Auto-Cleanse (Poison/Disease)")
        end)

        menu_elements.cooldowns_tree:render("Cooldowns", function()
            menu_elements.use_natures_swiftness:render("Use Nature's Swiftness")
            
            if menu_elements.use_natures_swiftness:get_state() then
                menu_elements.natures_swiftness_hp:render("Nature's Swiftness HP %")
            end
            
            menu_elements.use_mana_tide_totem:render("Use Mana Tide Totem")
            
            if menu_elements.use_mana_tide_totem:get_state() then
                menu_elements.mana_tide_group_mana:render("Mana Tide Group Mana %")
            end
        end)

        menu_elements.consumables_tree:render("Consumables", function()
            menu_elements.use_hp_potions:render("Use HP Potions")
            if menu_elements.use_hp_potions:get_state() then
                menu_elements.hp_potion_at:render("HP Potion at %")
            end
            
            menu_elements.use_mana_potions:render("Use Mana Potions")
            if menu_elements.use_mana_potions:get_state() then
                menu_elements.mana_potion_at:render("Mana Potion at %")
            end
        end)

        menu_elements.leveling_tree:render("Leveling/Solo", function()
            menu_elements.enable_leveling_mode:render("Enable Leveling Mode")
            
            if menu_elements.enable_leveling_mode:get_state() then
                menu_elements.solo_dps_mana:render("Min Mana % for DPS")
                menu_elements.solo_dps_group_hp:render("Group HP % for DPS")
                menu_elements.auto_attack_target:render("Attack on Target")
                menu_elements.use_lightning_bolt:render("Use Lightning Bolt")
                menu_elements.use_flame_shock:render("Use Flame Shock")
                menu_elements.use_earth_shock:render("Use Earth Shock")
                menu_elements.finish_with_melee:render("Finish with Melee")
                
                if menu_elements.finish_with_melee:get_state() then
                    menu_elements.finish_with_melee_hp:render("Finish with Melee HP %")
                end
            end
        end)

        menu_elements.mana_ticks_tree:render("Mana Ticks & 5SR Widget", function()
            if mana_tick_widget and mana_tick_widget.on_menu_render then
                mana_tick_widget:on_menu_render()
            end
        end)

        menu_elements.automation_tree:render("Automation", function()
            menu_elements.auto_loot_enabled:render("Enable Auto Loot")
            
            if menu_elements.auto_loot_enabled:get_state() then
                menu_elements.auto_loot_mode:render("Loot Mode", {
                    "Out of Combat Only",
                    "In Combat Only",
                    "Always"
                })
                menu_elements.auto_loot_max_attempts:render("Max Attempts per Corpse")
                menu_elements.auto_loot_retry_delay:render("Corpse Lockout (seconds)")
            end
        end)
    end)
end

-- ============================================================================
-- F1 TOGGLE FOR CUSTOM UI
-- ============================================================================

local f1_key_was_pressed = false

-- ============================================================================
-- UPDATE LOOP
-- ============================================================================

function shaman:on_update(local_player)
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

    -- Don't run rotation while mounted
    if local_player:is_mounted() then
        return
    end

	    -- Update resource tick tracker (Mana ticks & 5SR tracking)
	    local tick_tracker = resource_ticks.get()


        local game_now = core.game_time()
        if performance:begin_update(local_player, menu_elements, game_now) then
            -- Execute rotation logic (pass tick tracker and healing_only mode like warrior's tank_mode)
            rotation_logic:execute(local_player, menu_elements, tick_tracker, healing_only_enabled())
        end

    -- Automation (lowest priority)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
end

-- ============================================================================
-- RENDER LOOP (UI Drawing)
-- ============================================================================

function shaman:on_render()
    if settings_ui then
        settings_ui:on_render()
    end
end

-- ============================================================================
-- CONTROL PANEL
-- ============================================================================

function shaman:on_control_panel_render()
    local control_panel_elements = {}

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Shaman Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Shaman Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Healing Only (" .. key_helper:get_key_name(menu_elements.healing_only_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.healing_only_toggle
    })

    return control_panel_elements
end

return shaman
