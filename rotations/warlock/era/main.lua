local affliction=require("rotations/warlock/era/forever_affliction")
local aff_profiles=require("rotations/warlock/era/affliction_status")
local aff_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Warlock Rotation Module (AIO-compatible)
-- Classic ERA - expanded rotation (izi / Project Sylvanas only)
-- ============================================================================

local warlock = {}

local rotation_logic = require("rotations/warlock/era/rotation_logic")
local pvp_overlay = require("rotations/warlock/era/pvp/overlay")

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

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    aff_profile = core.menu.combobox(1,"warlock_aff_profile"),
    affliction_enabled = core.menu.checkbox(true,"warlock_affliction_enabled"),
    aff_finish_drain_soul = core.menu.checkbox(false,"warlock_aff_finish_drain_soul"),
    aff_use_wrack = core.menu.checkbox(true,"warlock_aff_use_wrack"),
    aff_use_elements = core.menu.checkbox(true,"warlock_aff_use_elements"),
    aff_use_amplify = core.menu.checkbox(true,"warlock_aff_use_amplify"),
    aff_use_shadowburn = core.menu.checkbox(true,"warlock_aff_use_shadowburn"),
    aff_use_nightfall = core.menu.checkbox(true,"warlock_aff_use_nightfall"),
    aff_unknown_ttd_dots = core.menu.checkbox(true,"warlock_aff_unknown_ttd_dots"),
    aff_pet_lead = core.menu.checkbox(true,"warlock_aff_pet_lead"),
    aff_clip_channels = core.menu.checkbox(true,"warlock_aff_clip_channels"),
    aff_clip_dots = core.menu.checkbox(true,"warlock_aff_clip_dots"),
    aff_next_target = core.menu.checkbox(true,"warlock_aff_next_target"),
    aff_use_hellfire = core.menu.checkbox(false,"warlock_aff_use_hellfire"),
    aff_chain_pull = core.menu.checkbox(false,"warlock_aff_chain_pull"),
    aff_status_enabled = core.menu.checkbox(false,"warlock_aff_status_enabled"),
    aff_status_pinned = core.menu.checkbox(true,"warlock_aff_status_pinned"),
    aff_status_clickthrough = core.menu.checkbox(true,"warlock_aff_status_clickthrough"),
    aff_status_opacity = core.menu.slider_int(0,100,30,"warlock_aff_status_opacity"),
    aff_status_x = core.menu.slider_int(0,7680,30,"warlock_aff_status_x"),
    aff_status_y = core.menu.slider_int(0,4320,350,"warlock_aff_status_y"),
    aff_cast_check_cache_ms = core.menu.slider_int(0,150,50,"warlock_aff_cast_check_cache_ms"),
    aff_refresh_min_ttd = core.menu.slider_int(0,30,6,"warlock_aff_refresh_min_ttd"),
    aff_refresh_window_ms = core.menu.slider_int(0,3000,0,"warlock_aff_refresh_window_ms"),
    aff_urgent_mana_pct = core.menu.slider_int(0,40,10,"warlock_aff_urgent_mana_pct"),
    aff_pet_lead_ms = core.menu.slider_int(0,3000,750,"warlock_aff_pet_lead_ms"),
    aff_drain_filler_level = core.menu.slider_int(1,60,38,"warlock_aff_drain_filler_level"),
    aff_hellfire_min_hp = core.menu.slider_int(20,100,75,"warlock_aff_hellfire_min_hp"),
    aff_hellfire_min_mana = core.menu.slider_int(0,100,30,"warlock_aff_hellfire_min_mana"),
    aff_hellfire_min_enemies = core.menu.slider_int(2,8,3,"warlock_aff_hellfire_min_enemies"),
    aff_chain_start_hp = core.menu.slider_int(5,60,40,"warlock_aff_chain_start_hp"),
    aff_chain_min_hp = core.menu.slider_int(30,100,75,"warlock_aff_chain_min_hp"),
    aff_chain_min_mana = core.menu.slider_int(0,100,60,"warlock_aff_chain_min_mana"),
    aff_chain_max_enemies = core.menu.slider_int(1,4,2,"warlock_aff_chain_max_enemies"),
    aff_chain_interval_ms = core.menu.slider_int(1000,15000,4000,"warlock_aff_chain_interval_ms"),
    aff_chain_range = core.menu.slider_int(5,40,25,"warlock_aff_chain_range"),
    main_tree = core.menu.tree_node(),
    core_tree = core.menu.tree_node(),
    rotation_tree = core.menu.tree_node(),
    resources_tree = core.menu.tree_node(),
    pet_tree = core.menu.tree_node(),
    defensive_tree = core.menu.tree_node(),
    pvp_tree = core.menu.tree_node(),
    automation_tree = core.menu.tree_node(),

    enable_script_check = core.menu.checkbox(true, "warlock_enable_script"),
    enable_toggle = core.menu.keybind(999, true, "warlock_enable_toggle"),
    ui_toggle_hotkey = core.menu.keybind(112, false, "warlock_ui_toggle_hotkey"),
    pvp_mode_toggle = core.menu.keybind(0x73, false, "warlock_pvp_toggle"), -- F4

    -- Rotation mode
    rotation_mode = core.menu.combobox(1, "warlock_rotation_mode"), -- 1=Solo/Leveling, 2=Dungeon/Raid, 3=DS/Ruin, 4=SM/Ruin
    pvp_build = core.menu.combobox(1, "warlock_pvp_build"), -- 1=Soul Link, 2=SM/Ruin

    -- Rotation toggles
    use_curse_of_agony = core.menu.checkbox(true, "warlock_use_curse_of_agony"),
    use_corruption = core.menu.checkbox(true, "warlock_use_corruption"),
    use_siphon_life = core.menu.checkbox(true, "warlock_use_siphon_life"),
    use_immolate = core.menu.checkbox(false, "warlock_use_immolate"),
    use_shadow_bolt = core.menu.checkbox(true, "warlock_use_shadow_bolt"),
    shadow_bolt_min_mana_pct = core.menu.slider_int(0, 100, 35, "warlock_shadow_bolt_min_mana_pct"),
    use_wand = core.menu.checkbox(true, "warlock_use_wand"),
    dot_min_ttd_sec = core.menu.slider_int(0, 30, 8, "warlock_dot_min_ttd_sec"),
    multi_dot_enabled = core.menu.checkbox(false, "warlock_multi_dot_enabled"),
    multi_dot_limit = core.menu.slider_int(1, 5, 3, "warlock_multi_dot_limit"),
    aoe_dot_toggle = core.menu.keybind(999, false, "warlock_aoe_dot_toggle"),

    -- Curses
    preferred_curse = core.menu.combobox(1, "warlock_preferred_curse"), -- 1=Agony, 2=Elements, 3=Shadow, 4=Recklessness, 5=Tongues, 6=Weakness

    -- Resources
    use_life_tap = core.menu.checkbox(true, "warlock_use_life_tap"),
    life_tap_mana_pct = core.menu.slider_int(0, 100, 40, "warlock_life_tap_mana_pct"),
    life_tap_min_hp_pct = core.menu.slider_int(0, 100, 60, "warlock_life_tap_min_hp_pct"),

    use_drain_life = core.menu.checkbox(true, "warlock_use_drain_life"),
    drain_life_hp_pct = core.menu.slider_int(0, 100, 45, "warlock_drain_life_hp_pct"),

    use_drain_soul = core.menu.checkbox(true, "warlock_use_drain_soul"),
    min_soul_shards = core.menu.slider_int(0, 30, 3, "warlock_min_soul_shards"),
    max_soul_shards = core.menu.slider_int(0,40,10,"warlock_max_soul_shards"),
    auto_delete_excess_shards = core.menu.checkbox(false,"warlock_auto_delete_excess_shards"),
    auto_create_healthstone = core.menu.checkbox(true,"warlock_auto_create_healthstone"),
    auto_self_soulstone = core.menu.checkbox(true,"warlock_auto_self_soulstone"),
    drain_soul_execute_hp_pct = core.menu.slider_int(0, 60, 20, "warlock_drain_soul_execute_hp_pct"),

    -- Hardcore / Survival
    use_armor = core.menu.checkbox(true, "warlock_use_armor"),
    use_healthstone = core.menu.checkbox(true, "warlock_use_healthstone"),
    healthstone_hp_pct = core.menu.slider_int(0, 100, 35, "warlock_healthstone_hp_pct"),
    use_emergency_cc = core.menu.checkbox(true, "warlock_use_emergency_cc"),
    use_shadow_ward = core.menu.checkbox(false, "warlock_use_shadow_ward"),
    shadow_ward_hp_pct = core.menu.slider_int(0, 100, 50, "warlock_shadow_ward_hp_pct"),

    -- Drain Tank (Solo/Leveling)
    use_drain_tank = core.menu.checkbox(false, "warlock_use_drain_tank"),

    -- Curse of Doom (Boss fights)
    use_curse_of_doom = core.menu.checkbox(false, "warlock_use_curse_of_doom"),

    -- PvP
    pvp_mode = core.menu.checkbox(false, "warlock_pvp_mode"),
    use_fear_pvp = core.menu.checkbox(true, "warlock_pvp_fear"),
    use_seduce_pvp = core.menu.checkbox(true, "warlock_pvp_seduce"),
    use_drain_mana_pvp = core.menu.checkbox(true, "warlock_pvp_drain_mana"),
    bait_kicks_pvp = core.menu.checkbox(true, "warlock_pvp_bait"),
    auto_death_coil_pvp = core.menu.checkbox(true, "warlock_pvp_death_coil"),
    auto_curse_tongues_pvp = core.menu.checkbox(true, "warlock_pvp_cot"),
    use_howl_offensive = core.menu.checkbox(true, "warlock_pvp_howl_offensive"),
    pvp_dot_spread = core.menu.checkbox(true, "warlock_pvp_dot_spread"),
    pvp_dot_spread_limit = core.menu.slider_int(1, 5, 3, "warlock_pvp_dot_spread_limit"),

    -- PvP Overlay
    pvp_overlay_enabled = core.menu.checkbox(true, "warlock_pvp_overlay_enabled"),
    pvp_overlay_dr = core.menu.checkbox(true, "warlock_pvp_overlay_dr"),
    pvp_overlay_dots = core.menu.checkbox(true, "warlock_pvp_overlay_dots"),
    pvp_overlay_cc = core.menu.checkbox(true, "warlock_pvp_overlay_cc"),
    pvp_overlay_pet = core.menu.checkbox(true, "warlock_pvp_overlay_pet"),

    -- Emergency CC
    death_coil_hp_pct = core.menu.slider_int(0, 100, 20, "warlock_death_coil_hp_pct"),
    howl_hp_pct = core.menu.slider_int(0, 100, 15, "warlock_howl_hp_pct"),
    fear_hp_pct = core.menu.slider_int(0, 100, 30, "warlock_fear_hp_pct"),

    -- Pet
    auto_summon_pet = core.menu.checkbox(true, "warlock_auto_summon_pet"),
    preferred_pet = core.menu.combobox(1, "warlock_preferred_pet"), -- 1=VW, 2=Imp, 3=Felhunter, 4=Succubus
    auto_spell_lock = core.menu.checkbox(true, "warlock_auto_spell_lock"),
    use_health_funnel = core.menu.checkbox(true, "warlock_use_health_funnel"),
    health_funnel_pet_hp_pct = core.menu.slider_int(0, 100, 40, "warlock_health_funnel_pet_hp_pct"),
    health_funnel_max_ms = core.menu.slider_int(1000,8000,3000,"warlock_health_funnel_max_ms"),
    health_funnel_damage_window_ms = core.menu.slider_int(1000,15000,6000,"warlock_health_funnel_damage_window_ms"),
    use_pet_sacrifice = core.menu.checkbox(true, "warlock_use_pet_sacrifice"),
    pet_sacrifice_hp_pct = core.menu.slider_int(0, 100, 25, "warlock_pet_sacrifice_hp_pct"),

    -- Automation
    auto_loot_enabled = core.menu.checkbox(true, "warlock_auto_loot_enabled"),
    auto_loot_mode = core.menu.combobox(1, "warlock_auto_loot_mode"),
    auto_loot_max_attempts = core.menu.slider_int(1, 10, 1, "warlock_auto_loot_max_attempts"),
    auto_loot_retry_delay = core.menu.slider_int(30, 200, 60, "warlock_auto_loot_retry_delay"),

    auto_mine_enabled = core.menu.checkbox(true, "warlock_auto_mine_enabled"),
    auto_mine_range = core.menu.slider_int(2, 8, 5, "warlock_auto_mine_range"),
    auto_herb_enabled = core.menu.checkbox(true, "warlock_auto_herb_enabled"),
    auto_herb_range = core.menu.slider_int(2, 8, 5, "warlock_auto_herb_range"),

    auto_quest_interact_enabled = core.menu.checkbox(false, "warlock_auto_quest_interact_enabled"),
    auto_quest_interact_range = core.menu.slider_int(2, 8, 4, "warlock_auto_quest_interact_range"),

    auto_skin_enabled = core.menu.checkbox(false, "warlock_auto_skin_enabled"),
    auto_skin_range = core.menu.slider_int(2, 8, 5, "warlock_auto_skin_range"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = core.menu.checkbox(false, "warlock_enable_pvp_mode"),
    pvp_rotation_tick_rate = core.menu.slider_int(30, 100, 30, "warlock_pvp_rotation_tick_rate"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "warlock_rotation",
    title = "Warlock Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 520,
    theme = "warlock"
})

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

local function life_tap_enabled()
    return menu_elements.use_life_tap:get_state()
end

local function drain_life_enabled()
    return menu_elements.use_drain_life:get_state()
end

local function drain_soul_enabled()
    return menu_elements.use_drain_soul:get_state()
end

local function healthstone_enabled()
    return menu_elements.use_healthstone:get_state()
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
        elements = { menu_elements.enable_toggle, menu_elements.pvp_mode_toggle, menu_elements.aoe_dot_toggle },
        labels = { "Enable Rotation", "PvP Mode Toggle", "AoE Multi-DoT" }
    })

    tab:checkbox_grid({
        elements = { menu_elements.pvp_mode, menu_elements.enable_pvp_mode },
        labels = { "PvP Mode Enabled", "Enable PvP Rotation (Tick Rate)" }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Candidate Scan Interval", "ms", 30, 100)
        }
    })

    tab:combo_list({
        element = menu_elements.pvp_build,
        label = "PvP Build Focus",
        items = { "Soul Link (Tanky)", "SM/Ruin (Burst/Nightfall)" }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" }
        }
    })
end)

settings_ui:add_tab({ id = "rotation", label = "Rotation" }, function(tab)
    tab:combo_list({
        label = "Scenario",
        elements = {
            {
                element = menu_elements.rotation_mode,
                label = "Rotation Mode",
                options = { "Solo / Leveling", "Dungeon / Raid", "DS/Ruin (Succubus Sacrifice)", "SM/Ruin (Pet + DoTs)" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Damage",
        columns = 2,
        elements = {
            { element = menu_elements.use_curse_of_agony, label = "Curse of Agony" },
            { element = menu_elements.use_corruption, label = "Corruption" },
            { element = menu_elements.use_siphon_life, label = "Siphon Life" },
            { element = menu_elements.use_immolate, label = "Immolate" },
            { element = menu_elements.use_shadow_bolt, label = "Shadow Bolt" },
            { element = menu_elements.use_wand, label = "Wand Filler" },
            { element = menu_elements.multi_dot_enabled, label = "Multi-DoT" },
            { element = menu_elements.use_curse_of_doom, label = "Curse of Doom (Boss)" },
            { element = menu_elements.use_drain_tank, label = "Drain Tank (Lv38+)" }
        }
    })

    tab:combo_list({
        label = "Curses",
        elements = {
            {
                element = menu_elements.preferred_curse,
                label = "Preferred Curse",
                options = { "Agony", "Elements", "Shadow", "Recklessness", "Tongues", "Weakness" }
            }
        }
    })

    tab:slider_list({
        label = "DoT Rules",
        elements = {
            slider_entry(menu_elements.dot_min_ttd_sec, "Min Time-to-Die for DoTs", "s", 0, 30),
            slider_entry(menu_elements.multi_dot_limit, "Max Multi-DoT Targets", "", 1, 5, function() return menu_elements.multi_dot_enabled:get_state() end)
        }
    })

    tab:slider_list({
        label = "Shadow Bolt",
        elements = {
            slider_entry(menu_elements.shadow_bolt_min_mana_pct, "Min Mana to Cast", "%", 0, 100)
        }
    })
end)

settings_ui:add_tab({ id = "resources", label = "Resources" }, function(tab)
    tab:checkbox_grid({
        label = "Mana / Sustain",
        columns = 2,
        elements = {
            { element = menu_elements.use_life_tap, label = "Use Life Tap" },
            { element = menu_elements.use_drain_life, label = "Use Drain Life" },
            { element = menu_elements.use_drain_soul, label = "Use Drain Soul (Shard Farm)" }
        }
    })

    tab:slider_list({
        label = "Life Tap",
        elements = {
            slider_entry(menu_elements.life_tap_mana_pct, "Tap when Mana <=", "%", 0, 100, life_tap_enabled),
            slider_entry(menu_elements.life_tap_min_hp_pct, "Only if HP >=", "%", 0, 100, life_tap_enabled)
        }
    })

    tab:slider_list({
        label = "Drain Life",
        elements = {
            slider_entry(menu_elements.drain_life_hp_pct, "Drain Life when HP <=", "%", 0, 100, drain_life_enabled)
        }
    })

    tab:slider_list({
        label = "Soul Shards",
        elements = {
            slider_entry(menu_elements.min_soul_shards, "Min Soul Shards", "", 0, 30, drain_soul_enabled),
            slider_entry(menu_elements.drain_soul_execute_hp_pct, "Execute HP <=", "%", 0, 60, drain_soul_enabled)
        }
    })
end)

local function shadow_ward_enabled()
    return menu_elements.use_shadow_ward:get_state()
end

local function emergency_cc_enabled()
    return menu_elements.use_emergency_cc:get_state()
end

settings_ui:add_tab({ id = "pet_def", label = "Survival" }, function(tab)
    tab:checkbox_grid({label="Armor",elements={
        {element=menu_elements.use_armor,label="Maintain Demon Armor/Skin"}
    }})

    tab:checkbox_grid({
        label = "Consumables & Defensive",
        columns = 2,
        elements = {
            { element = menu_elements.use_healthstone, label = "Use Healthstone" },
            { element = menu_elements.use_shadow_ward, label = "Use Shadow Ward" },
            { element = menu_elements.use_emergency_cc, label = "Emergency CC" }
        }
    })

    tab:slider_list({
        label = "Healthstone",
        elements = {
            slider_entry(menu_elements.healthstone_hp_pct, "Use at HP <=", "%", 0, 100, healthstone_enabled)
        }
    })

    tab:slider_list({
        label = "Shadow Ward",
        elements = {
            slider_entry(menu_elements.shadow_ward_hp_pct, "Use at HP <=", "%", 0, 100, shadow_ward_enabled)
        }
    })

    tab:slider_list({
        label = "Emergency CC",
        elements = {
            slider_entry(menu_elements.fear_hp_pct, "Fear at HP <=", "%", 0, 100, emergency_cc_enabled),
            slider_entry(menu_elements.death_coil_hp_pct, "Death Coil at HP <=", "%", 0, 100, emergency_cc_enabled),
            slider_entry(menu_elements.howl_hp_pct, "Howl of Terror at HP <=", "%", 0, 100, emergency_cc_enabled)
        }
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
    tab:checkbox_grid({
        label = "PvP Rotation",
        columns = 2,
        elements = {
            { element = menu_elements.use_fear_pvp, label = "Use Fear" },
            { element = menu_elements.use_seduce_pvp, label = "Use Seduce" },
            { element = menu_elements.use_drain_mana_pvp, label = "Drain Mana" },
            { element = menu_elements.auto_death_coil_pvp, label = "Auto Death Coil" },
            { element = menu_elements.auto_curse_tongues_pvp, label = "Auto Curse of Tongues" },
            { element = menu_elements.use_howl_offensive, label = "Offensive Howl (2+ melee)" },
            { element = menu_elements.pvp_dot_spread, label = "Spread Corruption" },
            { element = menu_elements.bait_kicks_pvp, label = "Bait Interrupts" }
        }
    })

    tab:slider_list({
        label = "DoT Spread",
        elements = {
            slider_entry(menu_elements.pvp_dot_spread_limit, "Max Spread Targets", "", 1, 5, function() return menu_elements.pvp_dot_spread:get_state() end)
        }
    })

    tab:checkbox_grid({
        label = "PvP Overlay",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_overlay_enabled, label = "Enable Overlay" },
            { element = menu_elements.pvp_overlay_dr, label = "Show DR Status" },
            { element = menu_elements.pvp_overlay_dots, label = "Show DoT Timers" },
            { element = menu_elements.pvp_overlay_cc, label = "Show CC Status" },
            { element = menu_elements.pvp_overlay_pet, label = "Show Pet Status" }
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
end)

settings_ui:add_tab({id="forever_affliction",label="Forever Affliction"},function(tab)
    tab:combo_list({label="Saved configurations (auto-save)",elements={{element=menu_elements.aff_profile,label="Profile",options={"Leveling","Dungeon","PvP"}}}})
    tab:checkbox_grid({label="Affliction and status",columns=2,elements={
        {element=menu_elements.affliction_enabled,label="Use Forever Affliction leveling"},
        {element=menu_elements.aff_finish_drain_soul,label="Finish with Drain Soul (Soul Harvest)"},
        {element=menu_elements.aff_use_wrack,label="Wrack filler when learned"},
        {element=menu_elements.aff_use_elements,label="Maintain Curse of the Elements"},
        {element=menu_elements.aff_use_amplify,label="Amplify Curse before Bane of Agony"},
        {element=menu_elements.aff_use_shadowburn,label="Shadowburn on cooldown above shard reserve"},
        {element=menu_elements.aff_use_nightfall,label="Use Nightfall instant Shadow Bolt"},
        {element=menu_elements.aff_unknown_ttd_dots,label="Apply DoTs when TTD is unknown"},
        {element=menu_elements.aff_clip_channels,label="Interrupt filler channels for priority actions"},
        {element=menu_elements.aff_clip_dots,label="Interrupt filler channels for DoT upkeep"},
        {element=menu_elements.aff_next_target,label="Select next engaged mob after a kill"},
        {element=menu_elements.aff_use_hellfire,label="Use Hellfire on engaged packs"},
        {element=menu_elements.aff_chain_pull,label="Auto chain-pull additional normal mobs"},
        {element=menu_elements.aff_status_enabled,label="Show Affliction status window"},
        {element=menu_elements.aff_status_pinned,label="Keep status visible with F1 closed"},
        {element=menu_elements.aff_status_clickthrough,label="Click-through status (disable to move/use controls)"},
    }})
    tab:checkbox_grid({label="Core spells",columns=2,elements={
        {element=menu_elements.use_curse_of_agony,label="Bane of Agony"},
        {element=menu_elements.use_corruption,label="Corruption"},
        {element=menu_elements.use_siphon_life,label="Siphon Life"},
        {element=menu_elements.use_immolate,label="Immolate"},
        {element=menu_elements.use_shadow_bolt,label="Shadow Bolt / Nightfall"},
        {element=menu_elements.use_drain_life,label="Drain Life"},
        {element=menu_elements.use_life_tap,label="Life Tap"},
        {element=menu_elements.use_drain_soul,label="Drain Soul"},
        {element=menu_elements.use_wand,label="Wand fallback"},
        {element=menu_elements.multi_dot_enabled,label="Spread DoTs on engaged enemies"},
    }})
    tab:checkbox_grid({label="Pet management",columns=2,elements={
        {element=menu_elements.auto_summon_pet,label="Automatically summon chosen pet"},
        {element=menu_elements.auto_spell_lock,label="Felhunter Spell Lock"},
        {element=menu_elements.use_health_funnel,label="Health Funnel"},
        {element=menu_elements.use_pet_sacrifice,label="Voidwalker Sacrifice"},
        {element=menu_elements.aff_pet_lead,label="Give demon an initial threat lead"},
    }})
    tab:combo_list({label="Pet selection",elements={
        {element=menu_elements.preferred_pet,label="Preferred pet",options={"Voidwalker","Imp","Felhunter","Succubus","Incubus (Forever)"}}
    }})
    tab:slider_list({label="Pet thresholds",elements={
        slider_entry(menu_elements.health_funnel_max_ms,"Maximum Health Funnel channel","ms",1000,8000),
        slider_entry(menu_elements.health_funnel_damage_window_ms,"Damage time between Health Funnels","ms",1000,15000),
        slider_entry(menu_elements.health_funnel_pet_hp_pct,"Health Funnel at pet health","%",0,100,function() return menu_elements.use_health_funnel:get_state() end),
        slider_entry(menu_elements.pet_sacrifice_hp_pct,"Sacrifice at player health","%",0,100,function() return menu_elements.use_pet_sacrifice:get_state() end),
        slider_entry(menu_elements.aff_pet_lead_ms,"Demon threat lead-in","ms",0,3000,function() return menu_elements.aff_pet_lead:get_state() end),
    }})
    tab:slider_list({label="Affliction thresholds",elements={
        slider_entry(menu_elements.aff_cast_check_cache_ms,"Castability cache (lower = more responsive)","ms",0,150),
        slider_entry(menu_elements.aff_refresh_min_ttd,"Minimum TTD for DoT refresh","s",0,30),
        slider_entry(menu_elements.aff_refresh_window_ms,"Refresh non-Agony DoTs below","ms",0,3000),
        slider_entry(menu_elements.aff_urgent_mana_pct,"Urgent Life Tap mana","%",0,40),
        slider_entry(menu_elements.aff_drain_filler_level,"Use Drain Life filler before Wrack from level","",1,60),
        slider_entry(menu_elements.aff_hellfire_min_hp,"Hellfire health floor","%",20,100),
        slider_entry(menu_elements.aff_hellfire_min_mana,"Hellfire mana floor","%",0,100),
        slider_entry(menu_elements.aff_hellfire_min_enemies,"Hellfire minimum engaged enemies","",2,8),
        slider_entry(menu_elements.aff_chain_start_hp,"Chain-pull when current target reaches","%",5,60),
        slider_entry(menu_elements.aff_chain_min_hp,"Chain-pull minimum player health","%",30,100),
        slider_entry(menu_elements.aff_chain_min_mana,"Chain-pull minimum player mana","%",0,100),
        slider_entry(menu_elements.aff_chain_max_enemies,"Chain-pull maximum engaged targets","",1,4),
        slider_entry(menu_elements.aff_chain_interval_ms,"Minimum time between chain pulls","ms",1000,15000),
        slider_entry(menu_elements.aff_chain_range,"Maximum chain-pull range","yd",5,40),
    }})
    tab:slider_list({label="Health, mana, shards and DoT targets",elements={
        slider_entry(menu_elements.life_tap_mana_pct,"Life Tap below mana","%",0,100),
        slider_entry(menu_elements.life_tap_min_hp_pct,"Life Tap only above health","%",0,100),
        slider_entry(menu_elements.drain_life_hp_pct,"Drain Life at health","%",0,100),
        slider_entry(menu_elements.min_soul_shards,"Minimum shard reserve","",0,30),
        slider_entry(menu_elements.max_soul_shards,"Maximum Soul Shards to keep","",0,40),
        slider_entry(menu_elements.drain_soul_execute_hp_pct,"Drain Soul finisher health","%",0,60),
        slider_entry(menu_elements.dot_min_ttd_sec,"Minimum TTD for new DoTs","s",0,30),
        slider_entry(menu_elements.multi_dot_limit,"Maximum engaged DoT targets","",1,5),
    }})
    tab:checkbox_grid({label="Shards and stones (out of combat)",columns=2,elements={
        {element=menu_elements.auto_delete_excess_shards,label="Delete excess Soul Shards"},
        {element=menu_elements.auto_create_healthstone,label="Keep a Healthstone available"},
        {element=menu_elements.auto_self_soulstone,label="Create and Soulstone yourself"},
    }})
    tab:slider_list({label="Status window appearance",elements={
        slider_entry(menu_elements.aff_status_opacity,"Background opacity","%",0,100),
        slider_entry(menu_elements.aff_status_x,"Status position X","px",0,7680),
        slider_entry(menu_elements.aff_status_y,"Status position Y","px",0,4320),
    }})
    tab:button({label="Show / reset status window",on_click=function() aff_profiles.show_reset(menu_elements) end})
end)
core.register_on_render_callback(aff_safety.callback(function()
    local open=settings_ui.menu and settings_ui.menu.enable and settings_ui.menu.enable:get_state()
    aff_profiles.render_overlay(menu_elements,open==true)
end,"Warlock Affliction HUD"))

-- ============================================================================
-- MENU RENDER (classic menu)
-- ============================================================================

function warlock:on_menu_render()
    if settings_ui and settings_ui.menu and settings_ui.menu.enable then
        settings_ui.menu.enable:render("Show Custom UI Window")
    end
    if settings_ui then
        settings_ui:on_menu_render()
    end

    menu_elements.main_tree:render("Warlock", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        core.menu.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.core_tree:render("Core", function()
            menu_elements.enable_script_check:render("Enable Script")
            menu_elements.enable_toggle:render("Enable Toggle")
            
            core.menu.header():render("Performance Settings", color.white(200))
            menu_elements.enable_pvp_mode:render("Enable PvP Rotation")
            if menu_elements.enable_pvp_mode:get_state() then
                menu_elements.pvp_rotation_tick_rate:render("PvP Candidate Scan Interval (ms)")
            end
        end)

        menu_elements.rotation_tree:render("Rotation", function()
            menu_elements.rotation_mode:render("Rotation Mode", { "Solo / Leveling", "Dungeon / Raid", "DS/Ruin (Succubus Sacrifice)", "SM/Ruin (Pet + DoTs)" })
            menu_elements.use_curse_of_agony:render("Use Curse of Agony")
            menu_elements.use_corruption:render("Use Corruption")
            menu_elements.use_siphon_life:render("Use Siphon Life")
            menu_elements.use_immolate:render("Use Immolate")
            menu_elements.preferred_curse:render("Preferred Curse", { "Agony", "Elements", "Shadow", "Recklessness", "Tongues", "Weakness" })
            menu_elements.use_shadow_bolt:render("Use Shadow Bolt")
            menu_elements.shadow_bolt_min_mana_pct:render("Shadow Bolt Min Mana%")
            menu_elements.use_wand:render("Use Wand Filler")
            menu_elements.use_drain_tank:render("Drain Tank Mode (Lv38+ Drain Life filler)")
            menu_elements.use_curse_of_doom:render("Use Curse of Doom (Boss >65s)")
            menu_elements.dot_min_ttd_sec:render("Min Time-to-Die for DoTs (sec)")
            menu_elements.multi_dot_enabled:render("Enable Multi-DoT")
            if menu_elements.multi_dot_enabled:get_state() then
                menu_elements.multi_dot_limit:render("Max Multi-DoT Targets")
            end
        end)

        menu_elements.resources_tree:render("Resources", function()
            menu_elements.use_life_tap:render("Use Life Tap")
            if menu_elements.use_life_tap:get_state() then
                menu_elements.life_tap_mana_pct:render("Tap when Mana% <= ")
                menu_elements.life_tap_min_hp_pct:render("Only if HP% >= ")
            end

            menu_elements.use_drain_life:render("Use Drain Life")
            if menu_elements.use_drain_life:get_state() then
                menu_elements.drain_life_hp_pct:render("Drain Life at HP% <= ")
            end

            menu_elements.use_drain_soul:render("Use Drain Soul (Shard Farm)")
            if menu_elements.use_drain_soul:get_state() then
                menu_elements.min_soul_shards:render("Min Soul Shards")
                menu_elements.drain_soul_execute_hp_pct:render("Execute HP% <= ")
            end
        end)

        menu_elements.pet_tree:render("Pet", function()
            menu_elements.auto_summon_pet:render("Auto Summon Pet")
            menu_elements.preferred_pet:render("Preferred Pet", { "Voidwalker", "Imp", "Felhunter", "Succubus", "Incubus (Forever)" })
            menu_elements.auto_spell_lock:render("Auto Spell Lock (Felhunter)")
            menu_elements.use_health_funnel:render("Use Health Funnel")
            if menu_elements.use_health_funnel:get_state() then
                menu_elements.health_funnel_pet_hp_pct:render("Health Funnel at Pet HP% <= ")
            end
        end)

        menu_elements.defensive_tree:render("Survival", function()
            menu_elements.use_armor:render("Maintain Demon Armor/Skin")
            menu_elements.use_healthstone:render("Use Healthstone")
            if menu_elements.use_healthstone:get_state() then
                menu_elements.healthstone_hp_pct:render("Use at HP% <= ")
            end
            menu_elements.use_shadow_ward:render("Use Shadow Ward")
            if menu_elements.use_shadow_ward:get_state() then
                menu_elements.shadow_ward_hp_pct:render("Use at HP% <= ")
            end
            menu_elements.use_pet_sacrifice:render("Use Sacrifice (Voidwalker)")
            if menu_elements.use_pet_sacrifice:get_state() then
                menu_elements.pet_sacrifice_hp_pct:render("Sacrifice at Player HP% <= ")
            end
            menu_elements.use_emergency_cc:render("Emergency CC (Fear/Coil/Howl)")
            if menu_elements.use_emergency_cc:get_state() then
                menu_elements.fear_hp_pct:render("Fear at HP% <= ")
                menu_elements.death_coil_hp_pct:render("Death Coil at HP% <= ")
                menu_elements.howl_hp_pct:render("Howl of Terror at HP% <= ")
            end
        end)

        menu_elements.pvp_tree:render("PvP", function()
            menu_elements.use_fear_pvp:render("Use Fear (PvP)")
            menu_elements.use_seduce_pvp:render("Use Seduce (PvP)")
            menu_elements.use_drain_mana_pvp:render("Drain Mana (PvP)")
            menu_elements.auto_death_coil_pvp:render("Auto Death Coil")
            menu_elements.auto_curse_tongues_pvp:render("Auto Curse of Tongues")
            menu_elements.use_howl_offensive:render("Offensive Howl (2+ melee)")
            menu_elements.pvp_dot_spread:render("Spread Corruption (PvP)")
            if menu_elements.pvp_dot_spread:get_state() then
                menu_elements.pvp_dot_spread_limit:render("Max Spread Targets")
            end
            menu_elements.pvp_overlay_enabled:render("PvP Overlay Enabled")
            if menu_elements.pvp_overlay_enabled:get_state() then
                menu_elements.pvp_overlay_dr:render("Show DR Status")
                menu_elements.pvp_overlay_dots:render("Show DoT Timers")
                menu_elements.pvp_overlay_cc:render("Show CC Status")
                menu_elements.pvp_overlay_pet:render("Show Pet Status")
            end
        end)

        menu_elements.automation_tree:render("Automation", function()
            auto_loot:on_menu_render(menu_elements)
            auto_mining:on_menu_render(menu_elements)
            auto_herbing:on_menu_render(menu_elements)
            auto_quest_interact:on_menu_render(menu_elements)
            auto_skinning:on_menu_render(menu_elements)
        end)
    end)
end

-- ============================================================================
-- UPDATE / RENDER
-- ============================================================================

local f1_key_was_pressed = false

function warlock:on_update(local_player)
    aff_profiles.update(menu_elements)
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

    affliction.observe(local_player,menu_elements,menu_elements.enable_script_check:get_state() and plugin_helper:is_toggle_enabled(menu_elements.enable_toggle))
    if affliction.hold_drain_soul(local_player) then return end

    local eat_or_drink = buff_manager:get_aura_data(local_player, enums.buff_db.EATING_OR_DRINKING, 200)
    if eat_or_drink and eat_or_drink.is_active then
        return
    end

    if not menu_elements.enable_script_check:get_state() then
        return
    end

    local rotation_enabled = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true
    if rotation_enabled then
        local now = core.game_time()
        if performance:begin_update(local_player, menu_elements, now) then
            rotation_logic:execute(local_player, menu_elements)
        end
    end

    -- Automation runs even if rotation is toggled off
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
end

function warlock:on_render(local_player)
    local open=settings_ui and settings_ui.menu and settings_ui.menu.enable and settings_ui.menu.enable:get_state()
    aff_profiles.render(menu_elements,open==true)
    if settings_ui then
        settings_ui:on_render()
    end

    -- PvP Overlay rendering
    if local_player then
        local pvp_active = plugin_helper:is_toggle_enabled(menu_elements.pvp_mode_toggle)
            or menu_elements.pvp_mode:get_state()
        if pvp_active then
            pvp_overlay.render(local_player, menu_elements)
        end
    end
end

function warlock:on_control_panel_render()
    local elements = {}

    control_panel_helper:insert_toggle(elements, {
        name = "Warlock Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.pvp_mode_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "AoE Multi-DoT (" .. key_helper:get_key_name(menu_elements.aoe_dot_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_dot_toggle
    })

    return elements
end

return warlock
