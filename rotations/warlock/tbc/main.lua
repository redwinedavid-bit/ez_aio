-- ============================================================================
-- Warlock Rotation Module (AIO-compatible)
-- TBC Classic - Comprehensive rotation with full feature parity to ERA
-- ============================================================================

local warlock = {
    allow_while_mounted = false
}

local rotation_logic = require("rotations/warlock/tbc/rotation_logic")
local spells = require("rotations/warlock/tbc/spells")

---@type color
local color = require("common/color")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type key_helper
local key_helper = require("common/utility/key_helper")

---@type control_panel_helper
local control_panel_helper = require("common/utility/control_panel_helper")

---@type rotation_settings_ui
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")

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

local auto_consumables = require("shared/auto_consumables")
local rotation_pause = require("shared/rotation_pause")

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = core.menu.tree_node(),
    core_tree = core.menu.tree_node(),
    rotation_tree = core.menu.tree_node(),
    resources_tree = core.menu.tree_node(),
    pet_tree = core.menu.tree_node(),
    defensive_tree = core.menu.tree_node(),

    -- Main toggles
    enable_script_check = core.menu.checkbox(true, "warlock_tbc_enable_script"),
    enable_toggle = core.menu.keybind(999, true, "warlock_tbc_enable_toggle"),
    ui_toggle_hotkey = core.menu.keybind(112, false, "warlock_tbc_ui_toggle_hotkey"),
    pvp_mode_toggle = core.menu.keybind(0x73, false, "warlock_tbc_pvp_toggle"), -- F4
    rotation_mode = core.menu.combobox(1, "warlock_tbc_rotation_mode"), -- 1=Affliction, 2=Shadow Destro, 3=Fire Destro, 4=Demonology

    -- Action Priority
    use_curse_of_elements = core.menu.checkbox(true, "warlock_tbc_use_elements"),
    use_ua = core.menu.checkbox(true, "warlock_tbc_use_ua"),
    use_corruption = core.menu.checkbox(true, "warlock_tbc_use_corruption"),
    use_siphon_life = core.menu.checkbox(true, "warlock_tbc_use_siphon"),
    use_immolate = core.menu.checkbox(false, "warlock_tbc_use_immolate"),
    use_shadow_bolt = core.menu.checkbox(true, "warlock_tbc_use_shadow_bolt"),
    use_conflagrate = core.menu.checkbox(true, "warlock_tbc_use_conflagrate"),
    use_wand = core.menu.checkbox(true, "warlock_tbc_use_wand"),

    -- Rotation Options
    dot_min_ttd_sec = core.menu.slider_int(0, 30, 8, "warlock_tbc_dot_min_ttd_sec"),
    multi_dot_enabled = core.menu.checkbox(false, "warlock_tbc_multi_dot_enabled"),
    multi_dot_limit = core.menu.slider_int(1, 5, 3, "warlock_tbc_multi_dot_limit"),
    shadow_bolt_min_mana_pct = core.menu.slider_int(0, 100, 35, "warlock_tbc_sb_min_mana"),
    preferred_curse = core.menu.combobox(1, "warlock_tbc_preferred_curse"), -- 1=Elements, 2=Agony, etc.

    -- AoE
    use_seed_aoe = core.menu.checkbox(true, "warlock_tbc_use_seed"),
    use_shadowfury = core.menu.checkbox(true, "warlock_tbc_use_shadowfury"),
    use_hellfire_aoe = core.menu.checkbox(false, "warlock_tbc_use_hellfire"),
    aoe_target_count = core.menu.slider_int(1, 10, 3, "warlock_tbc_aoe_count"),
    aoe_dot_toggle = core.menu.keybind(999, false, "warlock_tbc_aoe_toggle"),

    -- PvP logic
    pvp_mode = core.menu.checkbox(false, "warlock_tbc_pvp_mode"),
    pvp_spec_mode = core.menu.combobox(1, "warlock_tbc_pvp_spec_mode"), -- 1=SL/SL, 2=UA Affliction
    use_fear_pvp = core.menu.checkbox(true, "warlock_tbc_pvp_fear"),
    use_drain_mana_pvp = core.menu.checkbox(true, "warlock_tbc_pvp_drain_mana"),
    bait_kicks = core.menu.checkbox(true, "warlock_tbc_pvp_bait"),
    use_seduce_pvp = core.menu.checkbox(true, "warlock_tbc_pvp_seduce"),
    auto_death_coil_pvp = core.menu.checkbox(true, "warlock_tbc_pvp_death_coil"),
    auto_curse_tongues_pvp = core.menu.checkbox(true, "warlock_tbc_pvp_curse_tongues"),
    pvp_auto_dot_spread = core.menu.checkbox(true, "warlock_tbc_pvp_auto_dot_spread"),
    pvp_dot_spread_limit = core.menu.slider_int(1, 5, 3, "warlock_tbc_pvp_dot_spread_limit"),
    pvp_fear_dr_threshold = core.menu.slider_int(0, 100, 50, "warlock_tbc_pvp_fear_dr_thresh"),
    pvp_use_amplify_curse = core.menu.checkbox(true, "warlock_tbc_pvp_amplify_curse"),
    use_fel_domination = core.menu.checkbox(true, "warlock_tbc_use_fel_dom"),
    use_vw_sacrifice = core.menu.checkbox(true, "warlock_tbc_use_vw_sac"),
    vw_sacrifice_hp_pct = core.menu.slider_int(0, 100, 20, "warlock_tbc_vw_sac_hp"),
    pvp_overlay_enabled = core.menu.checkbox(true, "warlock_tbc_pvp_overlay"),
    pvp_overlay_dr = core.menu.checkbox(true, "warlock_tbc_pvp_overlay_dr"),
    pvp_overlay_dots = core.menu.checkbox(true, "warlock_tbc_pvp_overlay_dots"),
    pvp_overlay_cc = core.menu.checkbox(true, "warlock_tbc_pvp_overlay_cc"),
    pvp_overlay_pet = core.menu.checkbox(true, "warlock_tbc_pvp_overlay_pet"),
    pvp_overlay_lockout = core.menu.checkbox(true, "warlock_tbc_pvp_overlay_lockout"),

    -- Resource Management
    use_life_tap = core.menu.checkbox(true, "warlock_tbc_use_life_tap"),
    life_tap_mana_pct = core.menu.slider_int(0, 100, 40, "warlock_tbc_life_tap_mana"),
    life_tap_min_hp_pct = core.menu.slider_int(0, 100, 60, "warlock_tbc_life_tap_min_hp"),
    use_drain_life = core.menu.checkbox(true, "warlock_tbc_use_drain_life"),
    drain_life_hp_pct = core.menu.slider_int(0, 100, 45, "warlock_tbc_drain_life_hp"),
    use_drain_soul = core.menu.checkbox(true, "warlock_tbc_use_drain_soul"),
    min_soul_shards = core.menu.slider_int(0, 30, 3, "warlock_tbc_min_soul_shards"),
    drain_soul_execute_hp_pct = core.menu.slider_int(0, 60, 20, "warlock_tbc_drain_soul_execute"),

    -- Soul Link
    use_soul_link = core.menu.checkbox(true, "warlock_tbc_use_soul_link"),

    -- Defense / Utility
    use_fel_armor = core.menu.checkbox(true, "warlock_tbc_use_fel_armor"),
    use_healthstone = core.menu.checkbox(true, "warlock_tbc_use_hs"),
    healthstone_hp_pct = core.menu.slider_int(0, 100, 35, "warlock_tbc_hs_pct"),
    soulstone_target = core.menu.combobox(1, "warlock_tbc_ss_target"), -- 1=Self, 2=Tank, 3=Healer
    use_shadow_ward = core.menu.checkbox(false, "warlock_tbc_use_shadow_ward"),
    shadow_ward_hp_pct = core.menu.slider_int(0, 100, 50, "warlock_tbc_shadow_ward_hp"),
    use_emergency_cc = core.menu.checkbox(true, "warlock_tbc_use_emergency_cc"),
    death_coil_hp_pct = core.menu.slider_int(0, 100, 20, "warlock_tbc_death_coil_hp"),
    howl_hp_pct = core.menu.slider_int(0, 100, 25, "warlock_tbc_howl_hp"),

    -- Pet
    auto_summon_pet = core.menu.checkbox(true, "warlock_tbc_auto_summon_pet"),
    preferred_pet = core.menu.combobox(1, "warlock_tbc_pet"), -- 1=Felguard, 2=Imp, 3=Succubus, 4=Felhunter, 5=VW
    use_pet_sacrifice = core.menu.checkbox(true, "warlock_tbc_sacrifice"),
    auto_spell_lock = core.menu.checkbox(true, "warlock_tbc_auto_spell_lock"),
    use_health_funnel = core.menu.checkbox(true, "warlock_tbc_use_health_funnel"),
    health_funnel_pet_hp_pct = core.menu.slider_int(0, 100, 40, "warlock_tbc_health_funnel_hp"),

    -- Automation
    auto_loot_enabled = core.menu.checkbox(true, "warlock_tbc_auto_loot_enabled"),
    auto_loot_mode = core.menu.combobox(1, "warlock_tbc_auto_loot_mode"),
    auto_loot_max_attempts = core.menu.slider_int(1, 10, 1, "warlock_tbc_auto_loot_max_attempts"),
    auto_loot_retry_delay = core.menu.slider_int(30, 200, 60, "warlock_tbc_auto_loot_retry_delay"),

    auto_mine_enabled = core.menu.checkbox(true, "warlock_tbc_auto_mine_enabled"),
    auto_mine_range = core.menu.slider_int(2, 8, 5, "warlock_tbc_auto_mine_range"),
    auto_herb_enabled = core.menu.checkbox(true, "warlock_tbc_auto_herb_enabled"),
    auto_herb_range = core.menu.slider_int(2, 8, 5, "warlock_tbc_auto_herb_range"),

    auto_quest_interact_enabled = core.menu.checkbox(false, "warlock_tbc_auto_quest_interact_enabled"),
    auto_quest_interact_range = core.menu.slider_int(2, 8, 4, "warlock_tbc_auto_quest_interact_range"),

    auto_skin_enabled = core.menu.checkbox(false, "warlock_tbc_auto_skin_enabled"),
    auto_skin_range = core.menu.slider_int(2, 8, 5, "warlock_tbc_auto_skin_range"),

    -- Auto Consumables
    auto_consumables_enabled = core.menu.checkbox(true, "warlock_tbc_auto_consumables_enabled"),
    auto_food_pct = core.menu.slider_int(0, 100, 50, "warlock_tbc_auto_food_pct"),
    auto_drink_pct = core.menu.slider_int(0, 100, 40, "warlock_tbc_auto_drink_pct"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = core.menu.checkbox(false, "warlock_tbc_enable_pvp_mode"),
    pvp_rotation_tick_rate = core.menu.slider_int(30, 100, 30, "warlock_tbc_pvp_rotation_tick_rate"),
}

-- ============================================================================
-- SETTINGS UI (Custom Window)
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "warlock_tbc_rotation",
    title = "Warlock BxA (AIO) - TBC",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 700,
    theme = "warlock"
})

-- Helper function for slider entries
local function slider_entry(element, label, suffix, min_val, max_val, visible_when)
    return {
        element = element,
        label = label,
        suffix = suffix or "",
        bounds = { min = min_val, max = max_val },
        visible_when = visible_when
    }
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

settings_ui:add_tab({ id = "core", label = "Core" }, function(tab)
    tab:combo_list({
        label = "Specialization",
        elements = {
            {
                element = menu_elements.rotation_mode,
                label = "Specialization",
                options = { "Affliction (UA/DoT Focus)", "Shadow Destruction", "Fire Destruction (Incinerate)", "Demonology (Felguard)", "DS/Ruin (Succubus Sacrifice)" }
            }
        }
    })

    tab:combo_list({
        label = "Preferred Curse",
        elements = {
            {
                element = menu_elements.preferred_curse,
                label = "Preferred Curse",
                options = { "Curse of Elements", "Curse of Agony", "Curse of Doom", "Curse of Tongues", "Curse of Recklessness" }
            }
        }
    })

    tab:keybind_grid({
        elements = {
            menu_elements.enable_toggle,
            menu_elements.pvp_mode_toggle,
            menu_elements.aoe_dot_toggle,
        },
        labels = {
            "Enable Rotation",
            "PvP Mode Toggle",
            "AoE Multi-DoT",
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" },
            { element = menu_elements.enable_pvp_mode, label = "PvP Mode" },
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })
end)

settings_ui:add_tab({ id = "rotation", label = "Rotation" }, function(tab)
    tab:checkbox_grid({
        label = "Affliction Spells",
        columns = 2,
        elements = {
            { element = menu_elements.use_corruption, label = "Use Corruption" },
            { element = menu_elements.use_ua, label = "Use Unstable Affliction" },
            { element = menu_elements.use_siphon_life, label = "Use Siphon Life" },
            { element = menu_elements.use_curse_of_elements, label = "Curse of Elements" },
        }
    })
    
    tab:checkbox_grid({
        label = "Spell Priority",
        columns = 2,
        elements = {
            { element = menu_elements.use_corruption, label = "Use Corruption" },
            { element = menu_elements.use_ua, label = "Use UA" },
            { element = menu_elements.use_siphon_life, label = "Use Siphon Life" },
            { element = menu_elements.use_immolate, label = "Use Immolate" },
            { element = menu_elements.use_conflagrate, label = "Use Conflagrate" },
            { element = menu_elements.use_wand, label = "Use Wand Filler" },
            { element = menu_elements.use_soul_link, label = "Use Soul Link" }
        }
    })

    tab:slider_list({
        label = "Rotation Thresholds",
        elements = {
            slider_entry(menu_elements.dot_min_ttd_sec, "Min TTD for DoTs", "s", 0, 30),
            slider_entry(menu_elements.shadow_bolt_min_mana_pct, "Shadow Bolt Min Mana", "%", 0, 100),
            slider_entry(menu_elements.multi_dot_limit, "Max Multi-DoT Targets", "", 1, 5)
        }
    })

    tab:checkbox_grid({
        elements = {
            { element = menu_elements.multi_dot_enabled, label = "Enable Multi-DoT" }
        }
    })
end)

settings_ui:add_tab({ id = "pet", label = "Pet Management" }, function(tab)
    tab:combo_list({
        label = "Preferred Pet",
        elements = {
            {
                element = menu_elements.preferred_pet,
                label = "Preferred Pet",
                options = { "Felguard", "Imp", "Succubus", "Felhunter", "Voidwalker" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Pet Automation",
        columns = 2,
        elements = {
            { element = menu_elements.auto_summon_pet, label = "Auto Summon Pet" },
            { element = menu_elements.auto_spell_lock, label = "Auto Spell Lock (Felhunter)" },
            { element = menu_elements.use_health_funnel, label = "Auto Health Funnel" },
            { element = menu_elements.use_pet_sacrifice, label = "Auto Pet Sacrifice" }
        }
    })

    tab:slider_list({
        label = "Pet Thresholds",
        elements = {
            slider_entry(menu_elements.health_funnel_pet_hp_pct, "Health Funnel at Pet HP", "%", 0, 100)
        }
    })
end)

settings_ui:add_tab({ id = "resources", label = "Resources" }, function(tab)
    tab:checkbox_grid({
        label = "Life Tap",
        elements = {
            { element = menu_elements.use_life_tap, label = "Use Life Tap" }
        }
    })

    tab:slider_list({
        label = "Life Tap Settings",
        elements = {
            slider_entry(menu_elements.life_tap_mana_pct, "Life Tap at Mana", "%", 0, 100),
            slider_entry(menu_elements.life_tap_min_hp_pct, "Life Tap Min HP", "%", 0, 100)
        }
    })

    tab:checkbox_grid({
        label = "Drain Life",
        elements = {
            { element = menu_elements.use_drain_life, label = "Use Drain Life (Healing)" }
        }
    })

    tab:slider_list({
        label = "Drain Life Settings",
        elements = {
            slider_entry(menu_elements.drain_life_hp_pct, "Drain Life at HP", "%", 0, 100)
        }
    })

    tab:checkbox_grid({
        label = "Drain Soul (Shard Farming)",
        elements = {
            { element = menu_elements.use_drain_soul, label = "Use Drain Soul" }
        }
    })

    tab:slider_list({
        label = "Drain Soul Settings",
        elements = {
            slider_entry(menu_elements.min_soul_shards, "Minimum Soul Shards", "", 0, 30),
            slider_entry(menu_elements.drain_soul_execute_hp_pct, "Drain Soul at Target HP", "%", 0, 60)
        }
    })
end)

settings_ui:add_tab({ id = "aoe", label = "AoE" }, function(tab)
    tab:checkbox_grid({
        columns = 2,
        elements = {
            { element = menu_elements.use_seed_aoe, label = "Use Seed of Corruption" },
            { element = menu_elements.use_shadowfury, label = "Use Shadowfury" },
            { element = menu_elements.use_hellfire_aoe, label = "Use Hellfire" },
            { element = menu_elements.use_curse_of_elements, label = "Use Curse of Elements" }
        }
    })
    tab:slider_list({
        elements = {
            slider_entry(menu_elements.aoe_target_count, "Min Seed Targets", "", 1, 10)
        }
    })
end)

settings_ui:add_tab({ id = "survival", label = "Survival" }, function(tab)
    tab:checkbox_grid({
        label = "Defensive Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.use_fel_armor, label = "Maintain Fel Armor" },
            { element = menu_elements.use_healthstone, label = "Use Healthstone" },
            { element = menu_elements.use_shadow_ward, label = "Use Shadow Ward" },
            { element = menu_elements.use_emergency_cc, label = "Emergency CC (Fear/Death Coil/Howl)" }
        }
    })

    tab:slider_list({
        label = "Defensive Thresholds",
        elements = {
            slider_entry(menu_elements.healthstone_hp_pct, "Healthstone at HP", "%", 0, 100),
            slider_entry(menu_elements.shadow_ward_hp_pct, "Shadow Ward at HP", "%", 0, 100),
            slider_entry(menu_elements.death_coil_hp_pct, "Death Coil at HP", "%", 0, 100),
            slider_entry(menu_elements.howl_hp_pct, "Howl of Terror at HP", "%", 0, 100)
        }
    })

    tab:combo_list({
        label = "Soulstone",
        elements = {
            {
                element = menu_elements.soulstone_target,
                label = "Soulstone Target",
                options = { "Self", "Tank", "Healer" }
            }
        }
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
    tab:combo_list({
        label = "PvP Specialization",
        elements = {
            {
                element = menu_elements.pvp_spec_mode,
                label = "PvP Spec",
                options = { "SL/SL (Soul Link / Tanky Pressure)", "UA Affliction (Dispel Pressure)" }
            }
        }
    })

    tab:checkbox_grid({
        label = "PvP Automation",
        columns = 2,
        elements = {
            { element = menu_elements.use_fear_pvp, label = "Auto Fear CC" },
            { element = menu_elements.use_drain_mana_pvp, label = "Auto Drain Mana" },
            { element = menu_elements.bait_kicks, label = "Bait Kicks (Fire)" },
            { element = menu_elements.use_seduce_pvp, label = "Auto Seduce (Succubus)" },
            { element = menu_elements.auto_death_coil_pvp, label = "Auto Death Coil" },
            { element = menu_elements.auto_curse_tongues_pvp, label = "Auto Curse of Tongues" },
            { element = menu_elements.pvp_auto_dot_spread, label = "Auto DoT Spread" },
            { element = menu_elements.pvp_use_amplify_curse, label = "Amplify Curse" },
            { element = menu_elements.use_fel_domination, label = "Fel Dom. Resummon" },
            { element = menu_elements.use_vw_sacrifice, label = "VW Sacrifice (Emergency)" },
        }
    })

    tab:slider_list({
        label = "PvP Thresholds",
        elements = {
            slider_entry(menu_elements.pvp_dot_spread_limit, "Max DoT Spread Targets", "", 1, 5),
            slider_entry(menu_elements.pvp_fear_dr_threshold, "Min Fear DR% to Cast", "%", 0, 100),
            slider_entry(menu_elements.vw_sacrifice_hp_pct, "VW Sacrifice at HP", "%", 0, 100),
        }
    })

    tab:checkbox_grid({
        label = "PvP Overlay",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_overlay_enabled, label = "Enable PvP Overlay" },
            { element = menu_elements.pvp_overlay_dr, label = "Show DR Status" },
            { element = menu_elements.pvp_overlay_dots, label = "Show DoT Timers" },
            { element = menu_elements.pvp_overlay_cc, label = "Show CC Status" },
            { element = menu_elements.pvp_overlay_pet, label = "Show Pet Status" },
            { element = menu_elements.pvp_overlay_lockout, label = "Show School Lockout" },
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
            slider_entry(menu_elements.auto_loot_retry_delay, "Corpse Lockout", "s", 30, 200, auto_loot_enabled)
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

-- ============================================================================
-- MENU RENDER (classic menu fallback)
-- ============================================================================

function warlock:on_menu_render()
    if settings_ui then
        settings_ui:on_menu_render()
    end

    menu_elements.main_tree:render("Warlock TBC Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        core.menu.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.pvp_mode_toggle:render("PvP Mode Toggle (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ")")

        render_menu_separator()
        core.menu.header():render("Performance Settings", color.white(200))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_rotation_tick_rate:render("PvP Rotation Frequency (ms)")
        end
        render_menu_separator()

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end

        -- Core Settings
        menu_elements.core_tree:render("Core Settings", function()
            menu_elements.rotation_mode:render("Specialization", {
                "Affliction (UA/DoT Focus)",
                "Shadow Destruction",
                "Fire Destruction (Incinerate)",
                "Demonology (Felguard)",
                "DS/Ruin (Succubus Sacrifice)"
            })
            menu_elements.preferred_curse:render("Preferred Curse", {
                "Curse of Elements",
                "Curse of Agony",
                "Curse of Doom",
                "Curse of Tongues",
                "Curse of Recklessness"
            })
            menu_elements.use_curse_of_elements:render("Use Curse of Elements")
            menu_elements.use_ua:render("Use Unstable Affliction")
            menu_elements.use_corruption:render("Use Corruption")
            menu_elements.use_siphon_life:render("Use Siphon Life")
            menu_elements.use_immolate:render("Use Immolate")
            menu_elements.use_shadow_bolt:render("Use Shadow Bolt")
            menu_elements.use_conflagrate:render("Use Conflagrate")
            menu_elements.use_wand:render("Use Wand Filler")
            menu_elements.use_soul_link:render("Use Soul Link (OOC)")
        end)

        -- Pet Management
        menu_elements.pet_tree:render("Pet Management", function()
            menu_elements.auto_summon_pet:render("Auto Summon Pet")
            menu_elements.preferred_pet:render("Preferred Pet", { "Felguard", "Imp", "Succubus", "Felhunter", "Voidwalker" })
            menu_elements.auto_spell_lock:render("Auto Spell Lock (Felhunter)")
            menu_elements.use_health_funnel:render("Auto Health Funnel")
            if menu_elements.use_health_funnel:get_state() then
                menu_elements.health_funnel_pet_hp_pct:render("Health Funnel at Pet HP%")
            end
        end)

        -- Resources
        menu_elements.resources_tree:render("Resources", function()
            menu_elements.use_life_tap:render("Use Life Tap")
            if menu_elements.use_life_tap:get_state() then
                menu_elements.life_tap_mana_pct:render("Life Tap at Mana%")
                menu_elements.life_tap_min_hp_pct:render("Life Tap Min HP%")
            end

            menu_elements.use_drain_life:render("Use Drain Life")
            if menu_elements.use_drain_life:get_state() then
                menu_elements.drain_life_hp_pct:render("Drain Life at HP%")
            end
        end)

        -- Defensive
        menu_elements.defensive_tree:render("Defensive & Survival", function()
            menu_elements.use_fel_armor:render("Maintain Fel Armor")
            menu_elements.use_healthstone:render("Use Healthstone")
            menu_elements.healthstone_hp_pct:render("Healthstone at HP%")
            menu_elements.use_shadow_ward:render("Use Shadow Ward")
            menu_elements.use_emergency_cc:render("Emergency CC")
        end)
    end)
end

-- ============================================================================
-- UPDATE / RENDER
-- ============================================================================

local f1_key_was_pressed = false
local last_rotation_tick_ms = 0

function warlock:on_update(local_player)
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

    local rotation_enabled = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true
    if rotation_enabled then
        local game_now = core.game_time()
        local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
        local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
        if (game_now - last_rotation_tick_ms) >= tick_rate then
            last_rotation_tick_ms = game_now
            rotation_logic:execute(local_player, menu_elements)
        end
    end

    -- Automation runs even if rotation is toggled off
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)

    auto_consumables:on_update(local_player, menu_elements)
end

local pvp_overlay = require("rotations/warlock/tbc/pvp/overlay")

function warlock:on_render(local_player)
    if settings_ui then
        settings_ui:on_render()
    end

    -- PvP overlay renders when PvP mode is active
    if local_player and (plugin_helper:is_toggle_enabled(menu_elements.pvp_mode_toggle)
        or menu_elements.pvp_mode:get_state()) then
        pvp_overlay.render(local_player, menu_elements)
    end
end

function warlock:on_control_panel_render()
    local elements = {}

    control_panel_helper:insert_toggle(elements, {
        name = "Warlock (TBC) Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ")",
        keybind = menu_elements.pvp_mode_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "AoE Seed/DoT (" .. key_helper:get_key_name(menu_elements.aoe_dot_toggle:get_key_code()) .. ")",
        keybind = menu_elements.aoe_dot_toggle
    })

    return elements
end

return warlock
