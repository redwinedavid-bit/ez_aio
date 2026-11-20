-- ============================================================================
local performance = require("shared/rotation_performance")
-- Priest Healer Rotation Module (AIO-compatible)
-- World of Warcraft Classic ERA
-- ============================================================================

local priest = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/priest/era/rotation_logic")

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
    buffs_tree = md.tree_node(),
    dispel_tree = md.tree_node(),
    cooldowns_tree = md.tree_node(),
    consumables_tree = md.tree_node(),
    shadow_tree = md.tree_node(),
    pvp_tree = md.tree_node(),
    mana_ticks_tree = md.tree_node(),
    automation_tree = md.tree_node(),

    -- Main toggles
    enable_script_check = md.checkbox(true, "priest_enable_script"),
    enable_toggle = md.keybind(999, true, "priest_enable_toggle"),
    cooldowns_toggle = md.keybind(999, false, "priest_cooldowns_toggle"),
    healing_only_toggle = md.keybind(999, false, "priest_healing_only_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "priest_ui_toggle_hotkey"),
    healing_only = md.checkbox(false, "priest_healing_only"),
    enable_aoe = md.checkbox(true, "priest_enable_aoe"),
    aoe_toggle = md.keybind(999, false, "priest_aoe_toggle"),

    -- Healing Settings (All 0-100 for maximum flexibility)
    enable_healing = md.checkbox(true, "priest_enable_healing"),
    tank_emergency_hp = md.slider_int(0, 100, 30, "priest_tank_emergency_hp"),
    player_emergency_hp = md.slider_int(0, 100, 40, "priest_player_emergency_hp"),
    flash_heal_hp = md.slider_int(0, 100, 50, "priest_flash_heal_hp"),
    heal_hp = md.slider_int(0, 100, 75, "priest_heal_hp"),
    renew_refresh_hp = md.slider_int(0, 100, 85, "priest_renew_refresh_hp"),
    shield_hp = md.slider_int(0, 100, 50, "priest_shield_hp"),
    group_aoe_threshold = md.slider_int(1, 10, 3, "priest_group_aoe_threshold"),
    aoe_hp_threshold = md.slider_int(0, 100, 70, "priest_aoe_hp_threshold"),
    mana_low_threshold = md.slider_int(0, 100, 20, "priest_mana_low_threshold"),
    enable_smart_downranking = md.checkbox(false, "priest_enable_smart_downranking"),
    downrank_penalty_prevention = md.checkbox(true, "priest_downrank_penalty_prevention"), -- TBC only
    
    -- TBC Spells (Pre-Patch)
    use_circle_of_healing = md.checkbox(true, "priest_use_coh"),
    coh_hp_threshold = md.slider_int(50, 95, 85, "priest_coh_hp_threshold"),
    coh_min_targets = md.slider_int(2, 5, 3, "priest_coh_min_targets"),
    
    -- Healing Spell Toggles
    use_renew = md.checkbox(true, "priest_use_renew"),
    use_shield = md.checkbox(true, "priest_use_shield"),
    avoid_shield_on_rage_tanks = md.checkbox(true, "priest_avoid_shield_on_rage"),
    use_fade = md.checkbox(true, "priest_use_fade"),
    use_downranking = md.checkbox(true, "priest_use_downranking"),
    use_circle_of_healing_option = md.checkbox(true, "priest_use_coh_option"),
    use_dispel_magic = md.checkbox(true, "priest_use_dispel_magic"),
    use_lesser_heal_fallback = md.checkbox(false, "priest_use_lesser_heal_fallback"),
    pvp_unlock_pin = md.text_input("priest_pvp_unlock_pin", true),

    -- Buffs
    use_buffs = md.checkbox(true, "priest_use_buffs"),
    use_shadow_protection = md.checkbox(false, "priest_use_shadow_protection"),

    -- Dispel
    use_dispel = md.checkbox(true, "priest_use_dispel"),
    cancel_shadowform_dispel = md.checkbox(true, "priest_cancel_sf_dispel"),

    -- Cooldowns
    use_power_infusion = md.checkbox(true, "priest_use_power_infusion"),
    use_inner_focus = md.checkbox(true, "priest_use_inner_focus"),
    use_desperate_prayer = md.checkbox(true, "priest_use_desperate_prayer"),
    desperate_prayer_hp = md.slider_int(10, 40, 25, "priest_desperate_prayer_hp"),

    -- Consumables
    use_hp_potions = md.checkbox(true, "priest_use_hp_potions"),
    hp_potion_at = md.slider_int(10, 50, 35, "priest_hp_potion_at"),
    use_mana_potions = md.checkbox(true, "priest_use_mana_potions"),
    mana_potion_at = md.slider_int(10, 40, 25, "priest_mana_potion_at"),

    -- Shadow DPS (Solo Leveling) - enabled by default for solo play
    enable_shadow_dps = md.checkbox(true, "priest_enable_shadow_dps"),
    solo_dps_mana = md.slider_int(20, 80, 30, "priest_solo_dps_mana"),
    solo_dps_group_hp = md.slider_int(60, 100, 80, "priest_solo_dps_group_hp"),
    use_wand = md.checkbox(true, "priest_use_wand"),
    wand_target_hp = md.slider_int(0, 100, 25, "priest_wand_target_hp"),
    maintain_shadowform = md.checkbox(true, "priest_maintain_shadowform"),
    attack_on_target = md.checkbox(true, "priest_attack_on_target"),
    use_vampiric_embrace = md.checkbox(true, "priest_use_vampiric_embrace"),
    use_vampiric_touch = md.checkbox(true, "priest_use_vampiric_touch"),
    use_mind_blast = md.checkbox(true, "priest_use_mind_blast"),
    use_lesser_heal_fallback = md.checkbox(true, "priest_use_lesser_heal_fallback"),

    -- PvP & Utility
    enable_pvp_mode = md.checkbox(false, "priest_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "priest_pvp_rotation_tick_rate"),
    use_swd_breaker = md.checkbox(true, "priest_use_swd_breaker"),
    use_offensive_dispel = md.checkbox(true, "priest_use_offensive_dispel"),
    purge_high_priority_only = md.checkbox(true, "priest_purge_high_priority"),
    use_shackle_undead = md.checkbox(true, "priest_use_shackle_undead"),
    use_mana_burn = md.checkbox(false, "priest_use_mana_burn"),
    mana_burn_target_mana = md.slider_int(10, 80, 20, "priest_mana_burn_target_mana"),

    -- Automation
    auto_loot_enabled = md.checkbox(true, "priest_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "priest_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "priest_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "priest_auto_loot_retry_delay"),
    auto_mine_enabled = md.checkbox(true, "priest_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "priest_auto_mine_range"),
    auto_herb_enabled = md.checkbox(true, "priest_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "priest_auto_herb_range"),
    auto_quest_interact_enabled = md.checkbox(false, "priest_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "priest_auto_quest_interact_range"),
    auto_skin_enabled = md.checkbox(false, "priest_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "priest_auto_skin_range"),

    -- CC & Utility
    use_psychic_scream = md.checkbox(true, "priest_use_psychic_scream"),
    scream_mob_count = md.slider_int(2, 5, 2, "priest_scream_mob_count"),
    scream_hp_threshold = md.slider_int(10, 60, 35, "priest_scream_hp_threshold"),
    
    -- UI Reset
    reset_ui_position = md.checkbox(false, "priest_reset_ui_position"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "priest_rotation",
    title = "Priest Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 650,
    theme = "priest"
})
settings_ui:enable_presets(menu_elements, md)

-- FORCE RESET UI POSITION TO DEFAULTS (Remove this block after the UI is back on screen)
if settings_ui.menu.pos_x and settings_ui.menu.pos_x.set then
    settings_ui.menu.pos_x:set(700)
end
if settings_ui.menu.pos_y and settings_ui.menu.pos_y.set then
    settings_ui.menu.pos_y:set(200)
end
if settings_ui.menu.size_x and settings_ui.menu.size_x.set then
    settings_ui.menu.size_x:set(480)
end
if settings_ui.menu.size_y and settings_ui.menu.size_y.set then
    settings_ui.menu.size_y:set(650)
end
if settings_ui.menu.enable and settings_ui.menu.enable.set then
    settings_ui.menu.enable:set(true)
end
-- Force window rebuild with new position
settings_ui.window = nil
settings_ui._window_epoch = 0

-- Resource Tick Widget (Mana Tick & 5SR Timer)
local mana_tick_widget = resource_ticks_widget.new({
    id = "priest_mana_ticks",
    label = "Mana Ticks & 5SR",
    menu_prefix = "priest_mana_ticks",
    default_x = 600,
    default_y = 520,
    default_w = 240,
    default_h = 80,
    enable_window = true
})

-- Configure widget defaults for Priest (show mana and 5SR, hide energy)
-- Note: These are just default values stored via menu IDs, actual values persist from user settings
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
local function use_renew_enabled()
    return menu_elements.use_renew:get_state()
end

local function use_shield_enabled()
    return menu_elements.use_shield:get_state()
end

local function aoe_enabled()
    return menu_elements.enable_aoe:get_state()
end

local function cooldowns_enabled()
    return menu_elements.use_power_infusion:get_state() or menu_elements.use_inner_focus:get_state()
end

local function desperate_prayer_enabled()
    return menu_elements.use_desperate_prayer:get_state()
end

local function hp_potions_enabled()
    return menu_elements.use_hp_potions:get_state()
end

local function mana_potions_enabled()
    return menu_elements.use_mana_potions:get_state()
end

local function shadow_dps_enabled()
    return menu_elements.enable_shadow_dps:get_state()
end

local function use_scream_enabled()
    return menu_elements.use_psychic_scream:get_state()
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
            menu_elements.aoe_toggle,
            menu_elements.healing_only_toggle
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
            "AoE Healing Mode",
            "Healing Only Mode"
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" },
            { element = menu_elements.healing_only, label = "Healing Only (No DPS)" },
            { element = menu_elements.enable_aoe, label = "Enable AoE Healing" }
        }
    })

    tab:text_input_list({
        label = "Security",
        elements = {
            { element = menu_elements.pvp_unlock_pin, label = "PvP Unlock PIN", tooltip = "Enter the 4-digit PIN to unlock PvP features." }
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "healing", label = "Healing Logic" }, function(tab)
    tab:checkbox_grid({
        label = "Healing Spells",
        columns = 2,
        elements = {
            { element = menu_elements.use_renew, label = "Use Renew (HoT)" },
            { element = menu_elements.use_shield, label = "Use Power Word: Shield" },
            { element = menu_elements.avoid_shield_on_rage_tanks, label = "Smart Shield (Skip Rage Tanks)" },
            { element = menu_elements.use_fade, label = "Use Fade (Threat)" },
            { element = menu_elements.use_downranking, label = "Use Downranking (Mana Efficient)" },
            { element = menu_elements.use_circle_of_healing, label = "Use Circle of Healing (AoE)" },
            { element = menu_elements.use_dispel_magic, label = "Use Dispel Magic" },
            { element = menu_elements.use_lesser_heal_fallback, label = "Use Lesser Heal Fallback (Low Mana)" }
        }
    })

    tab:slider_list({
        label = "Emergency Thresholds",
        elements = {
            slider_entry(menu_elements.tank_emergency_hp, "Tank Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.player_emergency_hp, "Player Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.flash_heal_hp, "Flash Heal HP", "%", 0, 100)
        }
    })

    tab:slider_list({
        label = "Standard Healing Thresholds",
        elements = {
            slider_entry(menu_elements.heal_hp, "Heal/Greater Heal HP", "%", 0, 100),
            slider_entry(menu_elements.renew_refresh_hp, "Renew Refresh HP", "%", 0, 100, use_renew_enabled),
            slider_entry(menu_elements.shield_hp, "Shield HP Threshold", "%", 0, 100, use_shield_enabled)
        }
    })

    tab:slider_list({
        label = "AoE Healing (Prayer of Healing)",
        elements = {
            slider_entry(menu_elements.group_aoe_threshold, "Min Players Low HP", "", 1, 10, aoe_enabled),
            slider_entry(menu_elements.aoe_hp_threshold, "AoE HP Threshold", "%", 0, 100, aoe_enabled)
        }
    })

    tab:slider_list({
        label = "Mana Management",
        elements = {
            slider_entry(menu_elements.mana_low_threshold, "Mana Low Threshold", "%", 0, 100)
        }
    })

    tab:checkbox_grid({
        label = "Smart Downranking (TBC 2.0+)",
        columns = 1,
        elements = {
            { element = menu_elements.enable_smart_downranking, label = "Enable Smart Downranking (Mana Efficiency)" },
            { element = menu_elements.downrank_penalty_prevention, label = "Avoid TBC Healing Penalty (10+ levels below)" }
        }
    })
end)

settings_ui:add_tab({ id = "buffs_dispel", label = "Buffs & Dispel" }, function(tab)
    tab:checkbox_grid({
        label = "Buff Options",
        columns = 2,
        elements = {
            { element = menu_elements.use_buffs, label = "Auto-Buff Group" },
            { element = menu_elements.use_shadow_protection, label = "Use Shadow Protection" }
        }
    })

    tab:checkbox_grid({
        label = "Dispel Options",
        columns = 2,
        elements = {
            { element = menu_elements.use_dispel, label = "Auto-Dispel (Magic/Disease)" },
            { element = menu_elements.cancel_shadowform_dispel, label = "Cancel Shadowform" }
        }
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns & Mana" }, function(tab)
    tab:checkbox_grid({
        label = "Cooldown Usage",
        columns = 2,
        elements = {
            { element = menu_elements.use_power_infusion, label = "Use Power Infusion" },
            { element = menu_elements.use_inner_focus, label = "Use Inner Focus" },
            { element = menu_elements.use_desperate_prayer, label = "Use Desperate Prayer" }
        }
    })

    tab:slider_list({
        label = "Cooldown Thresholds",
        elements = {
            slider_entry(menu_elements.desperate_prayer_hp, "Desperate Prayer HP", "%", 10, 40, desperate_prayer_enabled)
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

local function use_wand_enabled()
    return menu_elements.use_wand:get_state() and menu_elements.enable_shadow_dps:get_state()
end

settings_ui:add_tab({ id = "shadow_dps", label = "Shadow DPS (Solo)" }, function(tab)
    tab:checkbox_grid({
        label = "Shadow DPS Fallback",
        columns = 2,
        elements = {
            { element = menu_elements.enable_shadow_dps, label = "Enable Shadow DPS" },
            { element = menu_elements.use_wand, label = "Use Wand" },
            { element = menu_elements.maintain_shadowform, label = "Maintain Shadowform" },
            { element = menu_elements.attack_on_target, label = "Attack on Target" },
            { element = menu_elements.use_vampiric_embrace, label = "Use Vampiric Embrace" },
            { element = menu_elements.use_vampiric_touch, label = "Use Vampiric Touch" }
        }
    })

    tab:slider_list({
        label = "DPS Conditions",
        elements = {
            slider_entry(menu_elements.solo_dps_mana, "Min Mana % for DPS", "%", 20, 80, shadow_dps_enabled),
            slider_entry(menu_elements.solo_dps_group_hp, "Group HP % for DPS", "%", 60, 100, shadow_dps_enabled),
            slider_entry(menu_elements.wand_target_hp, "Wand at Target HP %", "%", 0, 100, use_wand_enabled)
        }
    })

    tab:checkbox_grid({
        label = "Crowd Control",
        columns = 1,
        elements = {
            { element = menu_elements.use_psychic_scream, label = "Use Psychic Scream (Fear)" }
        }
    })

    tab:slider_list({
        label = "Fear Thresholds",
        elements = {
            slider_entry(menu_elements.scream_mob_count, "Scream at X+ enemies", " enemies", 1, 5, use_scream_enabled),
            slider_entry(menu_elements.scream_hp_threshold, "Scream at HP % (Panic)", "%", 10, 60, use_scream_enabled)
        }
    })
end)

local function pvp_unlocked()
    if not menu_elements.pvp_unlock_pin or not menu_elements.pvp_unlock_pin.get_text then return false end
    return menu_elements.pvp_unlock_pin:get_text() == "7192"
end

settings_ui:add_tab({ id = "pvp_utility", label = "PvP & Utility", visible_when = pvp_unlocked }, function(tab)
    tab:checkbox_grid({
        label = "PvP Core",
        columns = 2,
        elements = {
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" },
            { element = menu_elements.enable_healing, label = "Enable Support Healing" },
            { element = menu_elements.use_swd_breaker, label = "SW:D CC Breaker (vs Poly/Fear)" },
            { element = menu_elements.use_offensive_dispel, label = "Offensive Purge" },
            { element = menu_elements.purge_high_priority_only, label = "Purge High Priority Only" },
            { element = menu_elements.use_mana_burn, label = "Use Mana Burn" },
            { element = menu_elements.use_shackle_undead, label = "Auto Shackle Undead" }
        }
    })

    tab:slider_list({
        label = "Mana Burn Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Candidate Scan Interval", "ms", 30, 100),
            slider_entry(menu_elements.mana_burn_target_mana, "Stop Burn at Target Mana %", "%", 5, 80)
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

function priest:on_menu_render()
    settings_ui:on_menu_render()

    menu_elements.main_tree:render("Priest Rotation", function()
        md.header():render("Press - to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.cooldowns_toggle:render("Cooldowns Toggle (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")")
        menu_elements.enable_aoe:render("Enable AoE Healing")
        menu_elements.aoe_toggle:render("AoE Toggle (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ")")

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end
        
        menu_elements.reset_ui_position:render("Reset UI to Default Position")

        menu_elements.healing_tree:render("Healing Settings", function()
            menu_elements.use_renew:render("Use Renew (HoT)")
            menu_elements.use_shield:render("Use Power Word: Shield")
            menu_elements.use_fade:render("Use Fade (Threat)")
            menu_elements.use_dispel_magic:render("Use Dispel Magic")
            menu_elements.use_lesser_heal_fallback:render("Use Lesser Heal Fallback (Low Mana)")
            
            menu_elements.tank_emergency_hp:render("Tank Emergency HP %")
            menu_elements.player_emergency_hp:render("Player Emergency HP %")
            menu_elements.flash_heal_hp:render("Flash Heal HP %")
            menu_elements.heal_hp:render("Heal/Greater Heal HP %")
            
            if menu_elements.use_renew:get_state() then
                menu_elements.renew_refresh_hp:render("Renew Refresh HP %")
            end
            
            if menu_elements.use_shield:get_state() then
                menu_elements.shield_hp:render("Shield HP Threshold %")
            end
            
            if menu_elements.enable_aoe:get_state() then
                menu_elements.group_aoe_threshold:render("AoE: Min Players Low HP")
                menu_elements.aoe_hp_threshold:render("AoE: HP Threshold %")
            end
            
            menu_elements.mana_low_threshold:render("Mana Low Threshold %")
        end)

        menu_elements.buffs_tree:render("Buffs & Dispel", function()
            menu_elements.use_buffs:render("Auto-Buff Group")
            menu_elements.use_shadow_protection:render("Use Shadow Protection")
            menu_elements.use_dispel:render("Auto-Dispel (Magic/Disease)")
            menu_elements.cancel_shadowform_dispel:render("Cancel Shadowform for Dispel")
        end)

        menu_elements.cooldowns_tree:render("Cooldowns", function()
            menu_elements.use_power_infusion:render("Use Power Infusion")
            menu_elements.use_inner_focus:render("Use Inner Focus")
            menu_elements.use_desperate_prayer:render("Use Desperate Prayer")
            
            if menu_elements.use_desperate_prayer:get_state() then
                menu_elements.desperate_prayer_hp:render("Desperate Prayer HP %")
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

        menu_elements.shadow_tree:render("Shadow DPS (Solo)", function()
            menu_elements.enable_shadow_dps:render("Enable Shadow DPS (Solo/Leveling)")
            
            if menu_elements.enable_shadow_dps:get_state() then
                menu_elements.solo_dps_mana:render("Min Mana % for DPS")
                menu_elements.solo_dps_group_hp:render("Group HP % for DPS")
                menu_elements.use_wand:render("Use Wand")
                if menu_elements.use_wand:get_state() then
                    menu_elements.wand_target_hp:render("Wand at Target HP %")
                end
                menu_elements.maintain_shadowform:render("Maintain Shadowform")
                menu_elements.attack_on_target:render("Attack on Target")
                menu_elements.use_vampiric_embrace:render("Use Vampiric Embrace")
                menu_elements.use_vampiric_touch:render("Use Vampiric Touch")
                menu_elements.use_mind_blast:render("Use Mind Blast (Gedankenschlag)")
            end
        end)

        menu_elements.pvp_tree:render("PvP & Utility", function()
            menu_elements.enable_pvp_mode:render("Enable PvP Mode")
            if menu_elements.enable_pvp_mode:get_state() then
                menu_elements.pvp_rotation_tick_rate:render("PvP Candidate Scan Interval (ms)")
                menu_elements.use_swd_breaker:render("SW:D CC Breaker")
                menu_elements.use_offensive_dispel:render("Offensive Purge")
                menu_elements.purge_high_priority_only:render("Purge High Priority Only")
                menu_elements.use_mana_burn:render("Use Mana Burn")
                if menu_elements.use_mana_burn:get_state() then
                    menu_elements.mana_burn_target_mana:render("Stop Burn at Mana %")
                end
                menu_elements.use_shackle_undead:render("Auto Shackle Undead")
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

function priest:on_update(local_player)
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
    
    -- Handle UI position reset
    if menu_elements.reset_ui_position:get_state() then
        -- Reset position
        if settings_ui.menu.pos_x and settings_ui.menu.pos_x.set then
            settings_ui.menu.pos_x:set(700)
        end
        if settings_ui.menu.pos_y and settings_ui.menu.pos_y.set then
            settings_ui.menu.pos_y:set(200)
        end
        -- Reset the checkbox
        if menu_elements.reset_ui_position.set then
            menu_elements.reset_ui_position:set(false)
        end
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


    -- Execute rotation logic (pass tick tracker for mana optimization)
    local game_now = core.game_time()
    if performance:begin_update(local_player, menu_elements, game_now) then
        rotation_logic:execute(local_player, menu_elements, tick_tracker)
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

function priest:on_render()
    if settings_ui then
        settings_ui:on_render()
    end
end

-- ============================================================================
-- CONTROL PANEL
-- ============================================================================

function priest:on_control_panel_render()
    local control_panel_elements = {}

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Priest Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Priest Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Priest AoE Healing (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Healing Only (" .. key_helper:get_key_name(menu_elements.healing_only_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.healing_only_toggle
    })

    return control_panel_elements
end

return priest
