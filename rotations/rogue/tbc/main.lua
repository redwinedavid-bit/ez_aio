local __object_safety=require("shared/object_safety")
-- BxA rogue rotation module (AIO-compatible)
-- Keep logic minimal and expand as needed.

local rogue = {}

-- Init / Config
-- Module imports
---@type color
local color = require("common/color")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type control_panel_helper
local control_panel_helper = require("common/utility/control_panel_helper")

---@type target_selector
local target_selector = require("common/modules/target_selector")

---@type key_helper
local key_helper = require("common/utility/key_helper")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

local resource_ticks = require("shared/resource_ticks")
local ar_timing = require("shared/rogue_adrenaline_rush_timing")

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

-- Custom UI Module
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")
local log_capture = require("shared/log_capture")

-- Rogue Rotation Modules
local rotation_logic = require("rotations/rogue/tbc/rotation")
local pvp_rotation = require("rotations/rogue/tbc/rotation/pvp")
local helpers = require("rotations/rogue/tbc/helpers")
local spell_data = require("rotations/rogue/tbc/spell_data")

---@type auto_skinning
local auto_skinning = require("shared/auto_skinning")

---@type auto_loot
local auto_loot = require("shared/auto_loot")
local rotation_pause = require("shared/rotation_pause")

---@type auto_mining
local auto_mining = require("shared/auto_mining")

---@type auto_quest_interact
local auto_quest_interact = require("shared/auto_quest_interact")

---@type auto_herbing
local auto_herbing = require("shared/auto_herbing")

---@type auto_consumables
local auto_consumables = require("shared/auto_consumables")

local recent_targets = {}
local RECENT_TARGET_TTL = 12.0

---@param target game_object
---@return string|nil
local function target_id(target)
    if not target then
        return nil
    end
    return tostring(target)
end

---@param target game_object
local function mark_recent_target(target)
    local id = target_id(target)
    if not id then
        return
    end
    recent_targets[id] = core.time()
end

---@param target game_object
---@param now number
---@return boolean
local function is_recent_target(target, now)
    local id = target_id(target)
    if not id then
        return false
    end
    local ts = recent_targets[id]
    if not ts then
        return false
    end
    if (now - ts) > RECENT_TARGET_TTL then
        recent_targets[id] = nil
        return false
    end
    return true
end

---@param now number
local function prune_recent_targets(now)
    for id, ts in pairs(recent_targets) do
        if (now - ts) > RECENT_TARGET_TTL then
            recent_targets[id] = nil
        end
    end
end

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

-- ============================================================================
-- LOGGING (checkbox-gated via helpers)
-- ============================================================================
local rotation_log_enabled = md.checkbox(false, "rotation_log_enabled")
local rotation_file_logging_enabled = md.checkbox(false, "rogue_rotation_file_logging_enabled")

-- ============================================================================
-- SMART TARGET SWITCH STABILIZATION
-- ============================================================================
local last_smart_target_switch_time = 0.0
local SMART_TARGET_SWITCH_COOLDOWN = 0.35

local diag_target_summary =
{
    last_flush_time = 0.0,
    scanned = 0,
    acted = 0,
    skip_dead = 0,
    skip_ooc = 0,
    skip_unengaged = 0,
    skip_phys_immune = 0,
    skip_breakable_cc = 0
}

local last_rotation_log_state = false
local last_main_state_signature = nil
local last_file_log_state = false

local function reset_diag_target_summary()
    diag_target_summary.scanned = 0
    diag_target_summary.acted = 0
    diag_target_summary.skip_dead = 0
    diag_target_summary.skip_ooc = 0
    diag_target_summary.skip_unengaged = 0
    diag_target_summary.skip_phys_immune = 0
    diag_target_summary.skip_breakable_cc = 0
end

---@param local_player game_object
---@return boolean
local function get_player_in_combat(local_player)
    if not local_player then
        return false
    end

    local ok_combat, combat_state = pcall(function()
        return local_player:is_in_combat()
    end)
    if ok_combat then
        return combat_state == true
    end

    local ok_affecting, affecting_state = pcall(function()
        return local_player:affecting_combat()
    end)
    if ok_affecting then
        return affecting_state == true
    end

    return false
end

-- Menu
local menu_elements =
{
    -- ============================================================================
    -- ROOT & CORE CONTROLS
    -- ============================================================================
    main_tree = md.tree_node(),
    enable_script_check = md.checkbox(true, "enable_script_check"),
    rotation_log_enabled = rotation_log_enabled,
    rotation_file_logging_enabled = rotation_file_logging_enabled,
    keybinds_tree_node = md.tree_node(),
    ui_toggle_hotkey = md.keybind(112, false, "rogue_tbc_ui_toggle_hotkey"),
    enable_toggle = md.keybind(999, true, "toggle_script_check"),
    cooldowns_toggle = md.keybind(999, true, "cooldowns_toggle"),
    aoe_toggle = md.keybind(999, false, "aoe_toggle"),
    cc_toggle = md.keybind(999, false, "cc_toggle"),
    pickpocket_toggle = md.keybind(999, false, "pickpocket_toggle"),
    engineering_toggle = md.keybind(999, true, "engineering_toggle"),
    gouge_energy_regen_toggle = md.keybind(999, false, "gouge_energy_regen_toggle"),

    -- PvP
    pvp_mode_toggle = md.keybind(999, false, "rogue_pvp_mode_toggle"),
    enable_pvp_mode = md.checkbox(false, "rogue_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "rogue_tbc_pvp_rotation_tick_rate"),
    pvp_require_pvp_scenario = md.checkbox(true, "rogue_pvp_require_pvp_scenario"),
    pvp_targeting_mode = md.combobox(1, "rogue_pvp_targeting_mode"), -- 1=Current Target, 2=Target Selector
    pvp_auto_focus = md.checkbox(true, "rogue_pvp_auto_focus"),
    pvp_focus_override = md.checkbox(false, "rogue_pvp_focus_override"),
    pvp_auto_opener = md.checkbox(true, "rogue_pvp_auto_opener"),
    pvp_auto_sap_focus = md.checkbox(true, "rogue_pvp_auto_sap_focus"),
    pvp_use_premeditation = md.checkbox(true, "rogue_pvp_use_premeditation"),
    pvp_opener_mode = md.combobox(3, "rogue_pvp_opener_mode"), -- 1=Cheap Shot, 2=Garrote, 3=Auto, 4=Ambush, 5=Expose Armor
    pvp_cc_min_dr = md.combobox(2, "rogue_pvp_cc_min_dr"), -- 1=Full, 2=Half+, 3=Any
    pvp_auto_kick_focus = md.checkbox(true, "rogue_pvp_auto_kick_focus"),
    pvp_use_shadowstep_interrupt = md.checkbox(true, "rogue_pvp_use_shadowstep_interrupt"),
    pvp_step_interrupt_in_stealth = md.checkbox(false, "rogue_pvp_step_interrupt_in_stealth"),
    pvp_use_kidney = md.checkbox(true, "rogue_pvp_use_kidney"),
    pvp_kidney_min_cp = md.slider_int(1, 5, 5, "rogue_pvp_kidney_min_cp"),
    pvp_kidney_burst_only = md.checkbox(true, "rogue_pvp_kidney_burst_only"),
    pvp_use_blind = md.checkbox(true, "rogue_pvp_use_blind"),
    pvp_blind_hp_threshold = md.slider_int(0, 100, 25, "rogue_pvp_blind_hp_threshold"),
    pvp_use_deadly_throw_interrupt = md.checkbox(true, "rogue_pvp_use_deadly_throw_interrupt"),
    pvp_dt_requires_gloves = md.checkbox(true, "rogue_pvp_dt_requires_gloves"),

    -- PvP Phase 2: Abilities
    pvp_use_shiv = md.checkbox(true, "rogue_pvp_use_shiv"),
    pvp_use_gouge = md.checkbox(true, "rogue_pvp_use_gouge"),
    pvp_gouge_mode = md.combobox(1, "rogue_pvp_gouge_mode"), -- 1=Interrupt Only, 2=CC Chain, 3=Full Utility
    pvp_use_rupture = md.checkbox(true, "rogue_pvp_use_rupture"),

    -- PvP Phase 3: Offensive Cooldowns
    pvp_offensive_vanish = md.checkbox(false, "rogue_pvp_offensive_vanish"),
    pvp_vanish_hp_threshold = md.slider_int(0, 100, 40, "rogue_pvp_vanish_hp_threshold"),
    pvp_use_preparation = md.checkbox(true, "rogue_pvp_use_preparation"),
    pvp_proactive_evasion = md.checkbox(false, "rogue_pvp_proactive_evasion"),
    pvp_evasion_melee_count = md.slider_int(1, 3, 2, "rogue_pvp_evasion_melee_count"),
    pvp_use_sprint_gap_close = md.checkbox(true, "rogue_pvp_use_sprint_gap_close"),

    -- PvP Hybrid-Mode Keybinds
    pvp_vanish_keybind = md.keybind(999, false, "rogue_pvp_vanish_keybind"),
    pvp_blind_keybind = md.keybind(999, false, "rogue_pvp_blind_keybind"),
    pvp_prep_keybind = md.keybind(999, false, "rogue_pvp_prep_keybind"),

    -- PvP Phase 4: Intelligence
    pvp_pool_for_kick = md.checkbox(true, "rogue_pvp_pool_for_kick"),
    pvp_react_to_burst = md.checkbox(true, "rogue_pvp_react_to_burst"),

    -- PvP Phase 5: Advanced
    pvp_offensive_blind = md.checkbox(false, "rogue_pvp_offensive_blind"),
    pvp_class_awareness = md.checkbox(true, "rogue_pvp_class_awareness"),
    pvp_cc_chain_enabled = md.checkbox(false, "rogue_pvp_cc_chain_enabled"),

    -- PvP Phase 6: Arena Mechanics
    pvp_reset_cycle = md.checkbox(false, "rogue_pvp_reset_cycle"),
    pvp_reset_hp_threshold = md.slider_int(0, 100, 50, "rogue_pvp_reset_hp_threshold"),
    pvp_reset_require_burst = md.checkbox(false, "rogue_pvp_reset_require_burst"),
    pvp_trinket_tracking = md.checkbox(true, "rogue_pvp_trinket_tracking"),
    pvp_gouge_restealth = md.checkbox(false, "rogue_pvp_gouge_restealth"),
    pvp_shadowstep_defensive = md.checkbox(false, "rogue_pvp_shadowstep_defensive"),
    pvp_shadowstep_defensive_hp = md.slider_int(0, 100, 30, "rogue_pvp_shadowstep_defensive_hp"),

    -- PvP Debug
    pvp_debug_logging = md.checkbox(false, "rogue_pvp_debug_logging"),

    burst_mode = md.combobox(2, "burst_mode"),

    -- ============================================================================
    -- COMBAT FEATURES
    -- ============================================================================
    rotation_tree_node = md.tree_node(),
    combat_abilities_tree_node = md.tree_node(),
    racial_tree_node = md.tree_node(),
    interrupts_tree_node = md.tree_node(),

	    -- Interrupt Settings
	    kick_delay_min_pct = md.slider_int(0, 95, 10, "kick_delay_min_pct"),
	    kick_delay_max_pct = md.slider_int(5, 100, 35, "kick_delay_max_pct"),
	    use_arcane_torrent_interrupt = md.checkbox(false, "rogue_use_arcane_torrent_interrupt"),
	    arcane_torrent_interrupt_pct = md.slider_int(0, 100, 25, "rogue_arcane_torrent_interrupt_pct"),

    -- Combat Abilities
    auto_preparation_enabled = md.checkbox(false, "auto_preparation_enabled"),
    auto_expose_armor_enabled = md.checkbox(false, "auto_expose_armor_enabled"),
    use_shiv = md.checkbox(true, "rogue_use_shiv"),
    auto_feint_enabled = md.checkbox(true, "auto_feint_enabled"),
    auto_feint_threat_threshold = md.slider_int(0, 100, 80, "auto_feint_threat_threshold"),
    auto_feint_reactive_mode = md.checkbox(true, "auto_feint_reactive_mode"),
    auto_feint_instance_only = md.checkbox(true, "auto_feint_instance_only"),

    -- PvE Finisher Policy (TBC)
    pve_use_rupture = md.checkbox(true, "rogue_pve_use_rupture"),
    pve_rupture_min_ttd = md.slider_int(0, 60, 12, "rogue_pve_rupture_min_ttd"),
    pve_rupture_min_cp = md.slider_int(1, 5, 5, "rogue_pve_rupture_min_cp"),
    pve_rupture_target_policy = md.combobox(1, "rogue_pve_rupture_target_policy"), -- 1=Elite/Boss only, 2=TTD-based (any)
    pve_use_envenom = md.checkbox(false, "rogue_pve_use_envenom"),
    adrenaline_rush_timing_mode = md.combobox(2, "adrenaline_rush_timing_mode"),
    adrenaline_rush_tick_safety_ms = md.slider_int(0, 500, 150, "adrenaline_rush_tick_safety_ms"),

    -- On-use Items (TBC)
    use_trinkets = md.checkbox(true, "rogue_use_trinkets"),
    trinkets_sync_with_burst = md.checkbox(true, "rogue_trinkets_sync_with_burst"),
    trinkets_min_ttd = md.slider_int(0, 60, 12, "rogue_trinkets_min_ttd"),
    use_drums = md.checkbox(true, "rogue_use_drums"),
    drums_type = md.combobox(1, "rogue_drums_type"), -- 1=Battle,2=War,3=Restoration,4=Panic
    drums_sync_with_burst = md.checkbox(true, "rogue_drums_sync_with_burst"),
    drums_min_ttd = md.slider_int(0, 60, 12, "rogue_drums_min_ttd"),

    -- Raid Policy (TBC)
    raid_mode = md.checkbox(false, "rogue_raid_mode"),
    raid_expose_armor_policy = md.combobox(1, "rogue_raid_expose_armor_policy"), -- 1=Auto,2=Never,3=Assigned

    -- Racial Abilities
    auto_racial_enabled = md.checkbox(true, "auto_racial_enabled"),
    auto_racial_smart_mode = md.checkbox(true, "auto_racial_smart_mode"),
    auto_racial_on_boss = md.checkbox(true, "auto_racial_on_boss"),
    auto_racial_on_elite = md.checkbox(true, "auto_racial_on_elite"),
    auto_racial_on_normal = md.checkbox(true, "auto_racial_on_normal"),
    auto_defensive_racial_enabled = md.checkbox(true, "auto_defensive_racial_enabled"),
    auto_escape_artist_enabled = md.checkbox(true, "auto_escape_artist_enabled"),
    stoneform_hp_threshold = md.slider_int(0, 100, 60, "stoneform_hp_threshold"),
    arcane_torrent_energy_threshold = md.slider_int(0, 100, 35, "arcane_torrent_energy_threshold"),

    -- Engineering
    engineering_tree_node = md.tree_node(),
    engineering_prefer_stun = md.checkbox(true, "engineering_prefer_stun"),
    engineering_min_targets = md.slider_int(1, 6, 2, "engineering_min_targets"),
    engineering_sapper_min_targets = md.slider_int(2, 10, 4, "engineering_sapper_min_targets"),
    engineering_sapper_min_hp_pct = md.slider_int(0, 100, 95, "engineering_sapper_min_hp_pct"),
    engineering_sapper_self_damage_buffer = md.slider_int(0, 1000, 200, "engineering_sapper_self_damage_buffer"),

    -- ============================================================================
    -- SURVIVAL & RECOVERY
    -- ============================================================================
    consumables_tree_node = md.tree_node(),
    auto_pot_enabled = md.checkbox(true, "auto_pot_enabled"),
    auto_pot_threshold = md.slider_int(0, 100, 25, "auto_pot_threshold"),
    auto_healthstone_enabled = md.checkbox(true, "auto_healthstone_enabled"),
    auto_healthstone_threshold = md.slider_int(0, 100, 35, "auto_healthstone_threshold"),
    auto_thistle_tea_enabled = md.checkbox(true, "auto_thistle_tea_enabled"),
    auto_thistle_tea_energy_threshold = md.slider_int(0, 100, 20, "auto_thistle_tea_energy_threshold"),

    -- Defensive Cooldowns
    defensive_tree_node = md.tree_node(),
    emergency_enabled = md.checkbox(true, "emergency_enabled"),
    emergency_vanish_threshold = md.slider_int(0, 100, 20, "emergency_vanish_threshold"),
    emergency_sprint_threshold = md.slider_int(0, 100, 20, "emergency_sprint_threshold"),
    -- Legacy single-threshold (kept for config migration; not rendered)
    emergency_threshold_legacy = md.slider_int(0, 100, 20, "emergency_threshold"),
    auto_target_dummy_enabled = md.checkbox(true, "auto_target_dummy_enabled"),
    auto_target_dummy_threshold = md.slider_int(1, 100, 15, "auto_target_dummy_threshold"),
    auto_cloak_enabled = md.checkbox(true, "rogue_auto_cloak_enabled"),
    auto_cloak_hp_threshold = md.slider_int(0, 100, 45, "rogue_auto_cloak_hp_threshold"),
    auto_evasion_enabled = md.checkbox(true, "auto_evasion_enabled"),
    auto_evasion_threshold = md.slider_int(10, 100, 40, "auto_evasion_threshold"),
    emergency_blind_enabled = md.checkbox(true, "emergency_blind_enabled"),
    emergency_blind_threshold = md.slider_int(0, 80, 25, "emergency_blind_threshold"),
    auto_bandage_enabled = md.checkbox(true, "auto_bandage_enabled"),
    auto_bandage_threshold = md.slider_int(10, 80, 40, "auto_bandage_threshold"),
    auto_bandage_movement_stop = md.checkbox(true, "auto_bandage_movement_stop"),
    hardcore_safe_aoe = md.checkbox(true, "hardcore_safe_aoe"),

    -- ============================================================================
    -- AUTOMATION & UTILITIES
    -- ============================================================================
    automation_tree_node = md.tree_node(),
    auto_loot_enabled = md.checkbox(true, "auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "auto_loot_retry_delay"),
    auto_quest_interact_enabled = md.checkbox(true, "auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "auto_quest_interact_range"),
    auto_mine_enabled = md.checkbox(true, "auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "auto_mine_range"),
    auto_herb_enabled = md.checkbox(true, "auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "auto_herb_range"),
    auto_skin_enabled = md.checkbox(true, "rogue_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "rogue_auto_skin_range"),

    -- Auto Food
    auto_consumables_enabled = md.checkbox(true, "rogue_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "rogue_auto_food_pct"),

    -- Gouge Target Swap
    gouge_target_swap_max_cp = md.slider_int(0, 5, 1, "gouge_target_swap_max_cp"),

    -- Pickpocket Settings
    pickpocket_fail_behavior = md.combobox(1, "pickpocket_fail_behavior"),
    pickpocket_temp_lockout = md.slider_int(10, 120, 30, "pickpocket_temp_lockout"),
    pickpocket_cleanup_interval = md.slider_int(60, 600, 180, "pickpocket_cleanup_interval"),
    pickpocket_max_retries = md.slider_int(1, 5, 1, "pickpocket_max_retries"),

    -- ============================================================================
    -- ADVANCED SETTINGS
    -- ============================================================================
    advanced_settings_tree_node = md.tree_node(),
    ts_custom_logic_override = md.checkbox(true, "override_ts_logic"),
    draw_plugin_state = md.checkbox(true, "draw_plugin_state"),

    -- Developer Tools
    developer_tools_tree_node = md.tree_node(),
    debug_mode_enabled = md.checkbox(false, "debug_mode_enabled"),
    debug_hardcore_safety = md.checkbox(false, "debug_hardcore_safety")
}

-- Initialize helpers with menu
helpers:set_menu_elements(menu_elements)

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "rogue_rotation",
    title = "Rogue BxA (AIO) - TBC",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 650,
    theme = "rogue"
})
settings_ui:enable_presets(menu_elements, md)

local function auto_feint_enabled()
    return menu_elements.auto_feint_enabled:get_state()
end

local function auto_racial_enabled()
    return menu_elements.auto_racial_enabled:get_state()
end

local function auto_defensive_racial_enabled()
    return menu_elements.auto_defensive_racial_enabled:get_state()
end

local function auto_bandage_enabled()
    return menu_elements.auto_bandage_enabled:get_state()
end

local function emergency_enabled()
    return menu_elements.emergency_enabled:get_state()
end

local function auto_evasion_enabled()
    return menu_elements.auto_evasion_enabled:get_state()
end

local function auto_target_dummy_enabled()
    return menu_elements.auto_target_dummy_enabled:get_state()
end

local function auto_pot_enabled()
    return menu_elements.auto_pot_enabled:get_state()
end

local function auto_healthstone_enabled()
    return menu_elements.auto_healthstone_enabled:get_state()
end

local function auto_thistle_enabled()
    return menu_elements.auto_thistle_tea_enabled:get_state()
end

local function auto_loot_enabled()
    return menu_elements.auto_loot_enabled:get_state()
end

local function auto_quest_enabled()
    return menu_elements.auto_quest_interact_enabled:get_state()
end

local function auto_mine_enabled()
    return menu_elements.auto_mine_enabled:get_state()
end

local function auto_herb_enabled()
    return menu_elements.auto_herb_enabled:get_state()
end

local function auto_skin_enabled()
    return menu_elements.auto_skin_enabled:get_state()
end

local function adrenalin_timing_before_tick()
    return menu_elements.adrenaline_rush_timing_mode:get() == 2
end

local function pickpocket_requires_lockout()
    return menu_elements.pickpocket_fail_behavior:get() == 3
end

local function skinning_available()
    return auto_skinning and auto_skinning:is_available() == true
end

local function auto_skin_enabled_and_available()
    return skinning_available() and auto_skin_enabled()
end


-- Core Controls Tab
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
            menu_elements.cc_toggle,
            menu_elements.pickpocket_toggle,
            menu_elements.engineering_toggle,
            menu_elements.gouge_energy_regen_toggle,
            menu_elements.pvp_mode_toggle
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
            "AoE Mode",
            "CC & Interrupts",
            "Pickpocket",
            "Engineering",
            "Gouge Energy Regen",
            "PvP Mode"
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "combat", label = "Combat Features" }, function(tab)
    tab:combo_list({
        label = "Combat Modes",
        elements = {
            {
                element = menu_elements.burst_mode,
                label = "Burst Mode",
                options = { "Smart", "Always" }
            },
            {
                element = menu_elements.adrenaline_rush_timing_mode,
                label = "Adrenaline Rush Timing",
                options = { "Immediate", "Before Next Energy Tick" },
                visible_when = auto_feint_enabled
            }
        }
    })

    tab:checkbox_grid({
        label = "Raid Policy (TBC)",
        columns = 2,
        elements = {
            { element = menu_elements.raid_mode, label = "Raid Mode" },
            { element = menu_elements.auto_expose_armor_enabled, label = "Auto Expose Armor" },
            { element = menu_elements.trinkets_sync_with_burst, label = "Trinkets Sync with Burst" },
            { element = menu_elements.drums_sync_with_burst, label = "Drums Sync with Burst" }
        }
    })

    tab:combo_list({
        label = "Assignments",
        elements = {
            {
                element = menu_elements.raid_expose_armor_policy,
                label = "Expose Armor",
                options = { "Auto", "Never", "Assigned" }
            },
            {
                element = menu_elements.drums_type,
                label = "Drums Type",
                options = { "Battle (Haste)", "War (AP)", "Restoration", "Panic" },
                visible_when = function() return menu_elements.use_drums:get_state() end
            }
        }
    })

    tab:checkbox_grid({
        label = "On-use Items (TBC)",
        columns = 2,
        elements = {
            { element = menu_elements.use_trinkets, label = "Use Trinkets (On-use)" },
            { element = menu_elements.use_drums, label = "Use Drums" }
        }
    })

    tab:slider_list({
        label = "On-use Gating",
        elements = {
            slider_entry(menu_elements.trinkets_min_ttd, "Trinkets Min TTD", " s", 0, 60),
            slider_entry(menu_elements.drums_min_ttd, "Drums Min TTD", " s", 0, 60)
        }
    })

    tab:checkbox_grid({
        label = "Rotation Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.auto_preparation_enabled, label = "Auto Preparation" },
            { element = menu_elements.use_shiv, label = "Use Shiv (TBC)" },
            { element = menu_elements.auto_feint_enabled, label = "Auto Feint" },
            { element = menu_elements.auto_feint_reactive_mode, label = "Reactive Feint Mode", visible_when = auto_feint_enabled },
            { element = menu_elements.auto_feint_instance_only, label = "Instance Only Feint", visible_when = auto_feint_enabled },
            { element = menu_elements.pve_use_rupture, label = "Use Rupture (PvE)" },
            { element = menu_elements.pve_use_envenom, label = "Use Envenom (PvE)" }
        }
    })

    tab:slider_list({
        label = "PvE Finisher Gating",
        elements = {
            slider_entry(menu_elements.pve_rupture_min_ttd, "Rupture Min TTD", " s", 0, 60),
            slider_entry(menu_elements.pve_rupture_min_cp, "Rupture Min CP", "", 1, 5)
        }
    })

    tab:combo_list({
        label = "PvE Rupture Targeting",
        elements = {
            {
                element = menu_elements.pve_rupture_target_policy,
                label = "Rupture Targets",
                options = { "Elite/Boss Only", "TTD-Based (Any Target)" }
            }
        }
    })

    tab:slider_list({
        label = "Feint & Gouge",
        elements = {
            slider_entry(menu_elements.auto_feint_threat_threshold, "Feint Threat Threshold", "%", 0, 100, auto_feint_enabled),
            slider_entry(menu_elements.adrenaline_rush_tick_safety_ms, "Adrenaline Tick Safety", " ms", 0, 500, adrenalin_timing_before_tick),
            slider_entry(menu_elements.gouge_target_swap_max_cp, "Gouge Target Swap Max CP", "", 0, 5)
        }
    })

    tab:slider_list({
        label = "Interrupt Timing",
        elements = {
            slider_entry(menu_elements.kick_delay_min_pct, "Kick Delay Min %", "%", 0, 95),
            slider_entry(menu_elements.kick_delay_max_pct, "Kick Delay Max %", "%", 5, 100)
        }
    })

    tab:checkbox_grid({
        label = "Racial Controls",
        columns = 2,
        elements = {
            { element = menu_elements.auto_racial_enabled, label = "DPS Racials" },
            { element = menu_elements.auto_racial_smart_mode, label = "Smart Mode (Uses Adrenaline Rush)", visible_when = auto_racial_enabled },
            { element = menu_elements.auto_racial_on_boss, label = "Use on Boss/Rare", visible_when = auto_racial_enabled },
            { element = menu_elements.auto_racial_on_elite, label = "Use on Elite/Rare", visible_when = auto_racial_enabled },
            { element = menu_elements.auto_racial_on_normal, label = "Use on Normal Mobs", visible_when = auto_racial_enabled }
        }
    })

    tab:slider_list({
        label = "Racial Thresholds",
        elements = {
            slider_entry(menu_elements.arcane_torrent_energy_threshold, "Arcane Torrent Energy%", "%", 0, 100, auto_racial_enabled)
        }
    })
end)

settings_ui:add_tab({ id = "pvp", label = "PvP" }, function(tab)
    tab:checkbox_grid({
        label = "PvP Mode",
        columns = 2,
        elements = {
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Rotation" },
            { element = menu_elements.pvp_require_pvp_scenario, label = "Require PvP Scenario (Arena/BG)" }
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })

    tab:combo_list({
        label = "Targeting",
        elements = {
            {
                element = menu_elements.pvp_targeting_mode,
                label = "PvP Target Source",
                options = { "Current Target", "Target Selector" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Focus Automation",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_auto_focus, label = "Auto Focus Enemy (Healer-leaning)" },
            { element = menu_elements.pvp_focus_override, label = "Override Manual Focus" },
            { element = menu_elements.pvp_auto_kick_focus, label = "Interrupt Focus When Casting" },
            { element = menu_elements.pvp_use_shadowstep_interrupt, label = "Shadowstep for Interrupts" },
            { element = menu_elements.pvp_step_interrupt_in_stealth, label = "Allow Step Interrupt In Stealth" }
        }
    })

    tab:checkbox_grid({
        label = "Stealth & Openers",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_auto_opener, label = "Auto Opener From Stealth" },
            { element = menu_elements.pvp_auto_sap_focus, label = "Auto Sap Focus (if possible)" },
            { element = menu_elements.pvp_use_premeditation, label = "Use Premeditation (if learned)" }
        }
    })

    tab:combo_list({
        label = "Opener Style",
        elements = {
            {
                element = menu_elements.pvp_opener_mode,
                label = "Opener",
                options = { "Cheap Shot", "Garrote", "Auto", "Ambush", "Expose Armor" }
            }
        }
    })

    tab:combo_list({
        label = "DR / Safety",
        elements = {
            {
                element = menu_elements.pvp_cc_min_dr,
                label = "Minimum DR (CC/Stuns)",
                options = { "Full Only", "Half+", "Any" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Setup Tools",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_use_kidney, label = "Auto Kidney Shot" },
            { element = menu_elements.pvp_kidney_burst_only, label = "Kidney Only With Burst Toggle" },
            { element = menu_elements.pvp_use_blind, label = "Auto Blind (very conservative)" },
            { element = menu_elements.pvp_use_deadly_throw_interrupt, label = "Deadly Throw as Kick Backup" },
            { element = menu_elements.pvp_dt_requires_gloves, label = "Require DT Interrupt Gloves" }
        }
    })

    tab:slider_list({
        label = "Setup Thresholds",
        elements = {
            slider_entry(menu_elements.pvp_kidney_min_cp, "Kidney Min CP", "", 1, 5),
            slider_entry(menu_elements.pvp_blind_hp_threshold, "Blind HP% Threshold", "%", 0, 100, function()
                return menu_elements.pvp_use_blind:get_state()
            end)
        }
    })

    tab:checkbox_grid({
        label = "PvP Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_use_shiv, label = "Use Shiv (Poison Application)" },
            { element = menu_elements.pvp_use_gouge, label = "Use Gouge" },
            { element = menu_elements.pvp_use_rupture, label = "Use Rupture (vs Warrior/Rogue/Druid)" }
        }
    })

    tab:combo_list({
        label = "Gouge Mode",
        elements = {
            {
                element = menu_elements.pvp_gouge_mode,
                label = "Gouge Usage",
                options = { "Interrupt Fallback Only", "CC Chain Extension", "Full Utility" }
            }
        }
    })

    tab:checkbox_grid({
        label = "PvP Cooldowns",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_offensive_vanish, label = "Offensive Vanish (Re-Opener)" },
            { element = menu_elements.pvp_use_preparation, label = "Auto Preparation" },
            { element = menu_elements.pvp_proactive_evasion, label = "Proactive Evasion (vs Melee)" },
            { element = menu_elements.pvp_use_sprint_gap_close, label = "Sprint Gap-Close" }
        }
    })

    tab:slider_list({
        label = "Cooldown Thresholds",
        elements = {
            slider_entry(menu_elements.pvp_vanish_hp_threshold, "Vanish Target HP% (offensive)", "%", 0, 100, function()
                return menu_elements.pvp_offensive_vanish:get_state()
            end),
            slider_entry(menu_elements.pvp_evasion_melee_count, "Melee Count for Evasion", "", 1, 3, function()
                return menu_elements.pvp_proactive_evasion:get_state()
            end)
        }
    })

    tab:checkbox_grid({
        label = "PvP Intelligence",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_pool_for_kick, label = "Pool Energy for Kick" },
            { element = menu_elements.pvp_react_to_burst, label = "React to Enemy Burst" }
        }
    })

    tab:checkbox_grid({
        label = "PvP Advanced",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_offensive_blind, label = "Offensive Blind (Focus Healer)" },
            { element = menu_elements.pvp_class_awareness, label = "Class-Aware Decisions" },
            { element = menu_elements.pvp_cc_chain_enabled, label = "CC Chain Sequencing" }
        }
    })

    tab:checkbox_grid({
        label = "Arena Mechanics",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_reset_cycle, label = "Blind Reset Cycle" },
            { element = menu_elements.pvp_reset_require_burst, label = "Reset: Require Burst Toggle" },
            { element = menu_elements.pvp_trinket_tracking, label = "Trinket Detection" },
            { element = menu_elements.pvp_gouge_restealth, label = "Gouge Restealth" },
            { element = menu_elements.pvp_shadowstep_defensive, label = "Shadowstep Defensive" }
        }
    })

    tab:slider_list({
        label = "Arena Thresholds",
        elements = {
            { element = menu_elements.pvp_reset_hp_threshold, label = "Reset Cycle HP%", suffix = "%", min = 0, max = 100 },
            { element = menu_elements.pvp_shadowstep_defensive_hp, label = "Defensive Step HP%", suffix = "%", min = 0, max = 100 }
        }
    })

    tab:keybind_grid({
        label = "Hybrid Keybinds (Manual Override)",
        elements = {
            { element = menu_elements.pvp_vanish_keybind, label = "Force Vanish" },
            { element = menu_elements.pvp_blind_keybind, label = "Force Blind" },
            { element = menu_elements.pvp_prep_keybind, label = "Force Preparation" }
        }
    })

    tab:checkbox_grid({
        label = "Debug",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_debug_logging, label = "PvP Debug Logging" }
        }
    })
end)

settings_ui:add_tab({ id = "survival", label = "Survival & Recovery" }, function(tab)
    tab:checkbox_grid({
        label = "Defensive Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.emergency_enabled, label = "Emergency Vanish" },
            { element = menu_elements.auto_evasion_enabled, label = "Auto Evasion" },
            { element = menu_elements.emergency_blind_enabled, label = "Emergency Blind" },
            { element = menu_elements.auto_target_dummy_enabled, label = "Auto Target Dummy" },
            { element = menu_elements.auto_cloak_enabled, label = "Auto Cloak of Shadows (TBC)" },
            { element = menu_elements.auto_bandage_enabled, label = "Auto Bandage" },
            { element = menu_elements.auto_bandage_movement_stop, label = "Stop Movement During Bandage", visible_when = auto_bandage_enabled },
            { element = menu_elements.auto_defensive_racial_enabled, label = "Defensive Racials" },
            { element = menu_elements.auto_escape_artist_enabled, label = "Escape Artist (PvE only)", visible_when = auto_defensive_racial_enabled },
            { element = menu_elements.hardcore_safe_aoe, label = "CC-Safe AoE Blocker" }
        }
    })
    tab:slider_list({
        label = "Defensive Thresholds",
        elements = {
            slider_entry(menu_elements.emergency_vanish_threshold, "Vanish HP%", "%", 0, 100, emergency_enabled),
            slider_entry(menu_elements.emergency_sprint_threshold, "Sprint HP%", "%", 0, 100, emergency_enabled),
            slider_entry(menu_elements.auto_evasion_threshold, "Evasion HP%", "%", 10, 100, auto_evasion_enabled),
            slider_entry(menu_elements.emergency_blind_threshold, "Blind HP%", "%", 0, 80, function()
                return menu_elements.emergency_blind_enabled:get_state()
            end),
            slider_entry(menu_elements.auto_target_dummy_threshold, "Target Dummy HP%", "%", 1, 100, auto_target_dummy_enabled),
            slider_entry(menu_elements.auto_cloak_hp_threshold, "Cloak HP%", "%", 0, 100, function()
                return menu_elements.auto_cloak_enabled:get_state()
            end),
            slider_entry(menu_elements.auto_bandage_threshold, "Bandage HP%", "%", 10, 80, auto_bandage_enabled),
            slider_entry(menu_elements.stoneform_hp_threshold, "Stoneform HP%", "%", 0, 100, auto_defensive_racial_enabled)
        }
    })
    tab:checkbox_grid({
        label = "Consumable Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.auto_pot_enabled, label = "Auto Health Potion" },
            { element = menu_elements.auto_healthstone_enabled, label = "Auto Healthstone" },
            { element = menu_elements.auto_thistle_tea_enabled, label = "Auto Thistle Tea" }
        }
    })
    tab:slider_list({
        label = "Consumable Thresholds",
        elements = {
            slider_entry(menu_elements.auto_pot_threshold, "Health Potion HP%", "%", 0, 100, auto_pot_enabled),
            slider_entry(menu_elements.auto_healthstone_threshold, "Healthstone HP%", "%", 0, 100, auto_healthstone_enabled),
            slider_entry(menu_elements.auto_thistle_tea_energy_threshold, "Thistle Tea Energy%", "%", 0, 100, auto_thistle_enabled)
        }
    })
end)

settings_ui:add_tab({ id = "automation", label = "Automation & Utilities" }, function(tab)
        tab:checkbox_grid({
            label = "Automation Toggles",
            columns = 2,
            elements = {
                { element = menu_elements.auto_loot_enabled, label = "Auto Loot" },
                { element = menu_elements.auto_quest_interact_enabled, label = "Auto Quest Interact" },
                { element = menu_elements.auto_mine_enabled, label = "Auto Mining" },
                { element = menu_elements.auto_herb_enabled, label = "Auto Herbs" },
                { element = menu_elements.auto_skin_enabled, label = "Auto Skinning", visible_when = skinning_available }
            }
        })
    tab:combo_list({
        label = "Automation Modes",
        elements = {
            {
                element = menu_elements.auto_loot_mode,
                label = "Loot Mode",
                options = { "Out of Combat Only", "In Combat Only", "Always" },
                visible_when = auto_loot_enabled
            },
            {
                element = menu_elements.pickpocket_fail_behavior,
                label = "Pickpocket Behavior",
                options = { "Retry Immediately", "Never Retry (Permanent)", "Temporary Lockout" }
            }
        }
    })
        tab:slider_list({
            label = "Automation Settings",
            elements = {
                slider_entry(menu_elements.auto_loot_max_attempts, "Max Loot Attempts", "", 1, 10, auto_loot_enabled),
                slider_entry(menu_elements.auto_loot_retry_delay, "Loot Retry Delay (sec)", "s", 30, 200, auto_loot_enabled),
                slider_entry(menu_elements.auto_quest_interact_range, "Quest Interact Range (yd)", "yd", 2, 8, auto_quest_enabled),
                slider_entry(menu_elements.auto_mine_range, "Mining Range (yd)", "yd", 2, 8, auto_mine_enabled),
                slider_entry(menu_elements.auto_herb_range, "Herbing Range (yd)", "yd", 2, 8, auto_herb_enabled),
                slider_entry(menu_elements.auto_skin_range, "Skinning Range (yd)", "yd", 2, 8, auto_skin_enabled_and_available)
            }
        })
    tab:slider_list({
        label = "Pickpocket Settings",
        elements = {
            slider_entry(menu_elements.pickpocket_temp_lockout, "Temporary Lockout (sec)", "s", 10, 120, pickpocket_requires_lockout),
            slider_entry(menu_elements.pickpocket_cleanup_interval, "Cache Cleanup (sec)", "s", 60, 600),
            slider_entry(menu_elements.pickpocket_max_retries, "Max Retry Attempts", "", 1, 5)
        }
    })
    tab:checkbox_grid({
        label = "Engineering Tools",
        columns = 1,
        elements = {
            { element = menu_elements.engineering_prefer_stun, label = "Prefer Stun Bombs" }
        }
    })
    tab:slider_list({
        label = "Engineering Thresholds",
        elements = {
            slider_entry(menu_elements.engineering_min_targets, "Min Targets", "", 1, 6),
            slider_entry(menu_elements.engineering_sapper_min_targets, "Sapper Min Targets", "", 2, 10),
            slider_entry(menu_elements.engineering_sapper_min_hp_pct, "Sapper Min HP%", "%", 0, 100),
            slider_entry(menu_elements.engineering_sapper_self_damage_buffer, "Sapper Self-Dmg Buffer", "HP", 0, 1000)
        }
    })
end)

settings_ui:add_tab({ id = "advanced", label = "Advanced" }, function(tab)
    tab:checkbox_grid({
        label = "Advanced Settings",
        columns = 2,
        elements = {
            { element = menu_elements.rotation_log_enabled, label = "Enable Rotation Logging" },
            { element = menu_elements.rotation_file_logging_enabled, label = "Save Logs to TXT (File)" },
            { element = menu_elements.ts_custom_logic_override, label = "Enable TS Custom Override" },
            { element = menu_elements.draw_plugin_state, label = "Draw Plugin State" },
            { element = menu_elements.debug_mode_enabled, label = "Enable Debug Logging" },
            { element = menu_elements.debug_hardcore_safety, label = "Debug Hardcore Safety" }
        }
    })
end)
-- Register Keybind Modes Section
-- Combat Tab
-- Defense Tab
-- Consumables Tab
-- Automation Tab
-- Utilities Tab
local did_migrate_emergency_threshold = false
local function migrate_emergency_threshold_once()
    if did_migrate_emergency_threshold then
        return
    end
    did_migrate_emergency_threshold = true

    if not menu_elements or not menu_elements.emergency_threshold_legacy then
        return
    end

    local ok_old, old_value = pcall(function()
        return menu_elements.emergency_threshold_legacy:get()
    end)
    if not ok_old or old_value == nil then
        return
    end

    local function migrate_if_default(slider)
        if not slider then
            return
        end
        local ok_get, current = pcall(function()
            return slider:get()
        end)
        if ok_get and current == 20 then
            pcall(function()
                slider:set(old_value)
            end)
        end
    end

    migrate_if_default(menu_elements.emergency_vanish_threshold)
    migrate_if_default(menu_elements.emergency_sprint_threshold)
end

function rogue:on_menu_render()
    -- Custom UI Window Toggle
    if settings_ui then
        settings_ui:on_menu_render("Show Custom UI Window")
    end

    menu_elements.main_tree:render("Rogue Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.rotation_log_enabled:render("Enable Logging")
        menu_elements.rotation_file_logging_enabled:render("Save Logs to TXT (File)")

        if not menu_elements.enable_script_check:get_state() then
            return false
        end

        -- ====================================================================
        -- CORE CONTROLS
        -- ====================================================================
        md.header():render("CORE CONTROLS", color.cyan(220))

        menu_elements.keybinds_tree_node:render("Keybinds & Toggles", function()
            menu_elements.ui_toggle_hotkey:render("UI Toggle Hotkey")
            menu_elements.enable_toggle:render("Enable Script Toggle")
            menu_elements.cooldowns_toggle:render("Burst Toggle")
            menu_elements.aoe_toggle:render("AoE Toggle")
            menu_elements.cc_toggle:render("CC/Interrupts Toggle")
            menu_elements.pickpocket_toggle:render("Auto Pickpocket Toggle")
            menu_elements.engineering_toggle:render("Engineering Explosives Toggle")
            menu_elements.gouge_energy_regen_toggle:render("Gouge Energy Regen Toggle")
            menu_elements.pvp_mode_toggle:render("PvP Mode Toggle")
        end)

        md.header():render("PVP (TBC)", color.new(220, 170, 255, 220))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation (Overlay)")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_require_pvp_scenario:render("Require PvP Scenario (Arena/BG)")
            menu_elements.pvp_rotation_tick_rate:render("PvP Rotation Frequency (ms)")
        end

        -- ====================================================================
        -- COMBAT FEATURES
        -- ====================================================================
        md.header():render("COMBAT FEATURES", color.orange(220))

        menu_elements.rotation_tree_node:render("Rotation & Abilities", function()
            menu_elements.combat_abilities_tree_node:render("Combat Abilities", function()
                menu_elements.auto_preparation_enabled:render("Auto Preparation")
                md.header():render("Requires Burst Toggle", color.gray(180))

                menu_elements.auto_expose_armor_enabled:render("Auto Expose Armor")
                md.header():render("Sunder Armor alternative for solo", color.gray(180))

                md.header():render("PvE Finishers", color.cyan(200))
                menu_elements.pve_use_rupture:render("Use Rupture (PvE)")
                menu_elements.pve_rupture_min_ttd:render("Rupture Min TTD (sec)")
                menu_elements.pve_rupture_min_cp:render("Rupture Min CP")
                menu_elements.pve_rupture_target_policy:render("Rupture Targets", { "Elite/Boss Only", "TTD-Based (Any Target)" })
                menu_elements.pve_use_envenom:render("Use Envenom (PvE)")
                md.header():render("Envenom is usually for Assassination; Combat defaults to off", color.gray(180))

                menu_elements.auto_feint_enabled:render("Auto Feint")
                if menu_elements.auto_feint_enabled:get_state() then
                    md.header():render("Threat reduction in groups", color.gray(180))
                    menu_elements.auto_feint_threat_threshold:render("Feint Threat Threshold (%)")

                    menu_elements.auto_feint_reactive_mode:render("Reactive Mode (is_tanking)")
                    md.header():render("Cast when tanking OR above threshold", color.gray(180))

                    menu_elements.auto_feint_instance_only:render("Instance Only")
                    md.header():render("Only in dungeons/raids (not world groups)", color.gray(180))
                end

                md.header():render("Adrenaline Rush Timing", color.cyan(200))
                menu_elements.adrenaline_rush_timing_mode:render("Activation Mode", { "Immediate", "Before Next Energy Tick" })
                if menu_elements.adrenaline_rush_timing_mode:get() == 2 then
                    menu_elements.adrenaline_rush_tick_safety_ms:render("Safety Window (ms)")
                    md.header():render("Casts when tick is within this window", color.gray(180))
                end

                menu_elements.burst_mode:render("Burst Mode", { "Smart", "Always" }, "Smart: uses gating checks.\nAlways: ignores AR/BF gating checks." )

            end)

            md.header():render("Gouge Target Swap", color.cyan(200))
            menu_elements.gouge_target_swap_max_cp:render("Max CP To Drop (0=Never, 5=Always)")
            md.header():render("Swaps off Gouged target and keeps fighting the new target", color.gray(180))

            menu_elements.racial_tree_node:render("Racial Abilities", function()
                menu_elements.auto_racial_enabled:render("DPS Racials")
                md.header():render("Blood Fury (Orc) / Berserking (Troll)", color.gray(180))

                if menu_elements.auto_racial_enabled:get_state() then
                    menu_elements.auto_racial_smart_mode:render("Smart Mode (with Adrenaline Rush)")
                    md.header():render("Only use when AR active (fallback: always if AR not learned)", color.gray(180))

                    md.header():render("Target Types", color.cyan(200))
                    menu_elements.auto_racial_on_boss:render("Use on Boss/Rare Elite")
                    menu_elements.auto_racial_on_elite:render("Use on Elite/Rare")
                    menu_elements.auto_racial_on_normal:render("Use on Normal Mobs")
                end

            end)

	            menu_elements.interrupts_tree_node:render("Interrupts & CC", function()
	                menu_elements.kick_delay_min_pct:render("Kick Delay Min %")
	                md.header():render("Human-like interrupt timing", color.gray(180))

	                menu_elements.kick_delay_max_pct:render("Kick Delay Max %")
	                md.header():render("Instant if cast exceeds this", color.gray(180))

	                menu_elements.use_arcane_torrent_interrupt:render("Arcane Torrent Interrupt (Blood Elf)")
	                if menu_elements.use_arcane_torrent_interrupt:get_state() then
	                    menu_elements.arcane_torrent_interrupt_pct:render("Arcane Torrent at Cast % >=")
	                end

	                menu_elements.hardcore_safe_aoe:render("CC-Safe AoE Blocker")
	                md.header():render("Prevents explosives/Blade Flurry during CC", color.gray(180))
	            end)
        end)

        menu_elements.engineering_tree_node:render("Engineering", function()
            menu_elements.engineering_prefer_stun:render("Prefer Stun Bombs")
            md.header():render("Requires CC Toggle", color.gray(180))

            menu_elements.engineering_min_targets:render("Min Targets For Explosives")
            menu_elements.engineering_sapper_min_targets:render("Min Targets For Sapper")
            menu_elements.engineering_sapper_min_hp_pct:render("Sapper Min HP% (Fallback)")
            menu_elements.engineering_sapper_self_damage_buffer:render("Sapper Self-Dmg Buffer (HP)")
            md.header():render("Sapper only if HP > max self-damage + buffer", color.gray(180))
        end)

        -- ====================================================================
        -- SURVIVAL & RECOVERY
        -- ====================================================================
        md.header():render("SURVIVAL & RECOVERY", color.green(220))

        menu_elements.consumables_tree_node:render("Consumables", function()
            menu_elements.auto_pot_enabled:render("Auto Health Potion")
            if menu_elements.auto_pot_enabled:get_state() then
                menu_elements.auto_pot_threshold:render("Health Potion HP% Threshold")
            end

            menu_elements.auto_healthstone_enabled:render("Auto Healthstone")
            if menu_elements.auto_healthstone_enabled:get_state() then
                menu_elements.auto_healthstone_threshold:render("Healthstone HP% Threshold")
            end

            menu_elements.auto_thistle_tea_enabled:render("Auto Thistle Tea")
            if menu_elements.auto_thistle_tea_enabled:get_state() then
                md.header():render("Requires Burst Toggle", color.gray(180))
                menu_elements.auto_thistle_tea_energy_threshold:render("Thistle Tea Energy% Threshold")
            end
        end)

        menu_elements.defensive_tree_node:render("Defensive Cooldowns", function()
            menu_elements.emergency_enabled:render("Emergency Vanish")
            if menu_elements.emergency_enabled:get_state() then
                md.header():render("Triggers Vanish+Sprint at low HP", color.gray(180))
                menu_elements.emergency_vanish_threshold:render("Vanish HP% Threshold")
                menu_elements.emergency_sprint_threshold:render("Sprint HP% Threshold")
            end

            menu_elements.auto_evasion_enabled:render("Auto Evasion")
            if menu_elements.auto_evasion_enabled:get_state() then
                menu_elements.auto_evasion_threshold:render("Evasion HP% Threshold")
            end

            md.header():render("Defensive Racials", color.gray(180))
            menu_elements.auto_defensive_racial_enabled:render("Defensive Racials")
            if menu_elements.auto_defensive_racial_enabled:get_state() then
                menu_elements.auto_escape_artist_enabled:render("Escape Artist")
                md.header():render("PvE only (Gnome)", color.gray(180))
                menu_elements.stoneform_hp_threshold:render("Stoneform HP% Threshold")
                md.header():render("Dwarf only", color.gray(180))
            end

            menu_elements.emergency_blind_enabled:render("Emergency Blind")
            if menu_elements.emergency_blind_enabled:get_state() then
                md.header():render("Anti-melee CC", color.gray(180))
                menu_elements.emergency_blind_threshold:render("Blind HP% Threshold")
            end

            menu_elements.auto_target_dummy_enabled:render("Auto Target Dummy")
            if menu_elements.auto_target_dummy_enabled:get_state() then
                menu_elements.auto_target_dummy_threshold:render("Target Dummy HP% Threshold")
            end

            menu_elements.auto_bandage_enabled:render("Auto Bandage")
            if menu_elements.auto_bandage_enabled:get_state() then
                menu_elements.auto_bandage_threshold:render("Bandage HP% Threshold")
                menu_elements.auto_bandage_movement_stop:render("Stop Movement")
                md.header():render("Prevents bandage break", color.gray(180))
            end
        end)

        -- ====================================================================
        -- AUTOMATION & UTILITIES
        -- ====================================================================
        md.header():render("AUTOMATION & UTILITIES", color.new(220, 170, 255, 220))

        menu_elements.automation_tree_node:render("Automation", function()
            menu_elements.auto_loot_enabled:render("Auto Loot")
            if menu_elements.auto_loot_enabled:get_state() then
                menu_elements.auto_loot_mode:render("Loot Mode", {"Out of Combat Only", "In Combat Only", "Always"})
                menu_elements.auto_loot_max_attempts:render("Max Loot Attempts Per Corpse")
                menu_elements.auto_loot_retry_delay:render("Corpse Lockout (30-200 sec)")
            end

            menu_elements.auto_quest_interact_enabled:render("Auto Quest Interact")
            if menu_elements.auto_quest_interact_enabled:get_state() then
                menu_elements.auto_quest_interact_range:render("Interact Range (yards)")
                md.header():render("Open world quest objects (Questie)", color.gray(180))
            end

            menu_elements.auto_mine_enabled:render("Auto Mining")
            if menu_elements.auto_mine_enabled:get_state() then
                menu_elements.auto_mine_range:render("Mining Range (yards)")
            end

            menu_elements.auto_herb_enabled:render("Auto Herbs")
            if menu_elements.auto_herb_enabled:get_state() then
                menu_elements.auto_herb_range:render("Herbing Range (yards)")
            end

            -- Auto Skinning (conditional - nur wenn Profession gelernt)
            if auto_skinning:is_available() then
                menu_elements.auto_skin_enabled:render("Auto Skinning")
                if menu_elements.auto_skin_enabled:get_state() then
                    menu_elements.auto_skin_range:render("Skinning Range (yards)")
                end
            end

            md.header():render("Auto Food", color.gray(200))
            menu_elements.auto_consumables_enabled:render("Enable Auto Recovery")
            if menu_elements.auto_consumables_enabled:get_state() then
                menu_elements.auto_food_pct:render("Food Threshold %")
            end

            md.header():render("Pickpocket Settings", color.cyan(200))

            menu_elements.pickpocket_fail_behavior:render("Failed Pickpocket Behavior",
                {"Retry Immediately", "Never Retry (Permanent)", "Temporary Lockout"})
            md.header():render("What to do when pickpocket fails or resists", color.gray(180))

            if menu_elements.pickpocket_fail_behavior:get() == 3 then
                menu_elements.pickpocket_temp_lockout:render("Lockout Duration (sec)")
                md.header():render("Wait time before retry after fail", color.gray(180))
            end

            menu_elements.pickpocket_cleanup_interval:render("Cache Cleanup Interval (sec)")
            md.header():render("How long to remember targets (default: 180s)", color.gray(180))

            menu_elements.pickpocket_max_retries:render("Max Retry Attempts")
            md.header():render("Attempts before marking empty pickpocket as success", color.gray(180))
        end)

        -- ====================================================================
        -- ADVANCED SETTINGS
        -- ====================================================================
        md.header():render("ADVANCED SETTINGS", color.yellow(220))

        menu_elements.advanced_settings_tree_node:render("Advanced Settings", function()
            menu_elements.ts_custom_logic_override:render("Enable TS Custom Settings Override")
            md.header():render("Override TotalSilence settings", color.gray(180))

            menu_elements.draw_plugin_state:render("Draw Plugin State")
            md.header():render("Shows enabled/disabled state on screen", color.gray(180))
        end)

        menu_elements.developer_tools_tree_node:render("Developer Tools", function()
            menu_elements.debug_mode_enabled:render("Enable Debug Logging")
            md.header():render("WARNING: Performance impact", color.red(200))

            menu_elements.debug_hardcore_safety:render("Debug Hardcore Safety")
            md.header():render("Logs AoE blocker actions", color.gray(180))
        end)
    end)

end

-- Target selector overrides
local is_ts_overriden = false
local function override_ts_settings()
    if is_ts_overriden then
        return
    end

    if not menu_elements.ts_custom_logic_override:get_state() then
        return
    end

    -- TODO: adjust target selector settings to match your rogue logic
    target_selector.menu_elements.settings.max_range_damage:set(5)

    is_ts_overriden = true
end

-- Core Loop (Update)
local run_rotation
local handle_out_of_combat

-- F1-Taste Hotkey State für Custom UI Toggle
local ui_toggle_key_was_pressed = false
local last_rotation_tick_ms = 0

function rogue:on_update(local_player)
    control_panel_helper:on_update(menu_elements)
    migrate_emergency_threshold_once()

    -- F1 Hotkey for Custom UI Toggle
    if settings_ui and settings_ui.menu and settings_ui.menu.enable then
        local hotkey_state = menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey:get_state()
        local ui_toggle_key_down = (hotkey_state == true or hotkey_state == 1)

        if ui_toggle_key_down and not ui_toggle_key_was_pressed then
            if settings_ui.toggle then
                settings_ui:toggle()
            else
                settings_ui.menu.enable:set_state(not settings_ui.menu.enable:get_state())
            end
        end

        ui_toggle_key_was_pressed = ui_toggle_key_down
    end

    local local_player = helpers:get_player()
    if not local_player then
        return
    end

    -- SAFETY: Stop all rotation activity if player is eating or drinking
    if rotation_pause.is_eating_or_drinking(local_player) then
        return
    end

    if not menu_elements.enable_script_check:get_state() then
        return
    end

    local logging_enabled = menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
    if logging_enabled ~= last_rotation_log_state then
        last_rotation_log_state = logging_enabled
        if logging_enabled then
            helpers:log_checkpoint("log.enabled", 0.1, "[LOG] ENABLED")
        end
    end

    do
        local want_file = menu_elements.rotation_file_logging_enabled and menu_elements.rotation_file_logging_enabled:get_state() == true
        if want_file ~= last_file_log_state then
            last_file_log_state = want_file
            local ok = log_capture:set_enabled(want_file, { prefix = "rogue_tbc" })
            if logging_enabled then
                helpers:log_checkpoint("log.file", 0.25, string.format("[LOG] FILE=%s ok=%s file=%s",
                    tostring(want_file), tostring(ok), tostring(log_capture:get_file_name() or "nil")))
            end
        end
    end

    if not menu_elements.enable_script_check:get_state() then
        if logging_enabled then
            helpers:log_checkpoint("main.disabled", 1.0, "[MAIN] DISABLED")
        end
        return
    end

    if not plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) then
        if logging_enabled then
            helpers:log_checkpoint("main.toggle_off", 1.0, "[MAIN] TOGGLE_OFF")
        end
        return
    end

    local cast_end_time = local_player:get_active_spell_cast_end_time()
    if cast_end_time > 0.0 then
        if logging_enabled then
            helpers:log_checkpoint("main.casting", 1.0, "[MAIN] CASTING")
        end
        return
    end

    local channel_end_time = local_player:get_active_channel_cast_end_time()
    if channel_end_time > 0.0 then
        if logging_enabled then
            helpers:log_checkpoint("main.channeling", 1.0, "[MAIN] CHANNELING")
        end
        return
    end

    if local_player:is_mounted() then
        if logging_enabled then
            helpers:log_checkpoint("main.mounted", 1.0, "[MAIN] MOUNTED")
        end
        return
    end

    if handle_out_of_combat and handle_out_of_combat(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("main.ooc_handler", 1.0, "[MAIN] OOC_HANDLER")
        end
        return
    end

    override_ts_settings()

    local targets_list = target_selector:get_targets()

    if run_rotation then
        if logging_enabled then
            local in_combat = get_player_in_combat(local_player)
            local has_target = local_player:get_target() ~= nil
            local is_casting = (local_player:get_active_spell_cast_end_time() or 0.0) > 0.0
            local is_channeling = (local_player:get_active_channel_cast_end_time() or 0.0) > 0.0
            local is_mounted = local_player:is_mounted() == true
            local enabled_script = menu_elements.enable_script_check:get_state() == true
            local toggle_on = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true

            local signature = string.format("c=%s t=%s cast=%s chan=%s m=%s en=%s tg=%s",
                tostring(in_combat),
                tostring(has_target),
                tostring(is_casting),
                tostring(is_channeling),
                tostring(is_mounted),
                tostring(enabled_script),
                tostring(toggle_on))

            if signature ~= last_main_state_signature then
                last_main_state_signature = signature
                helpers:log_checkpoint("main.state", 0.2, "[MAIN] STATE " .. signature)
            end
        end
        local game_now = core.game_time()
        local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
        local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
        if (game_now - last_rotation_tick_ms) >= tick_rate then
            last_rotation_tick_ms = game_now
            run_rotation(local_player, targets_list)
        end
    end

    -- Automation (lowest priority)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)

    -- Auto Food
    auto_consumables:on_update(local_player, menu_elements)
end

-- CP-aware target switching for optimal multi-target DPS during Gouge
-- CRITICAL CONDITIONS (ALL must be true):
-- 1. Current target is Gouged (safe window, won't break CC)
-- 2. CP threshold allows dropping limited CP (0=never, 5=always)
-- 3. 1+ other enemy within 5 yards
-- Switches to highest HP non-gouged enemy within 5 yards (rogue melee range)
---@param local_player game_object
---@param current_target game_object
---@param targets_list game_object[]
---@return boolean switched True if target was switched
local function try_smart_target_switch(local_player, current_target, targets_list)
    if not local_player or not current_target then
        return false
    end

    local now = core.time()
    if (now - last_smart_target_switch_time) < SMART_TARGET_SWITCH_COOLDOWN then
        return false
    end

    local max_cp_to_drop = menu_elements.gouge_target_swap_max_cp and menu_elements.gouge_target_swap_max_cp:get() or 0
    if max_cp_to_drop <= 0 then
        return false -- Never switch (user setting)
    end

    local cp = helpers:get_combo_points(local_player)
    if max_cp_to_drop < 5 and cp > max_cp_to_drop then
        return false -- Wait to preserve CP
    end

    -- CRITICAL: Only switch if current target is Gouged
    -- Gouge allows safe target switching without breaking CC
    local gouge_spell = spell_data.cc.gouge
    local is_gouged = false
    if gouge_spell and gouge_spell.ids then
        is_gouged = current_target:debuff_up(gouge_spell.ids) == true
    end
    if not is_gouged then
        return false  -- Only switch when current target is gouged
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    -- Find valid enemies within 5 yards (rogue melee range)
    local nearby_enemies = {}
    for _, target in __object_safety.live_ipairs(targets_list) do
        if target and target:is_valid() and target:is_alive() then
            local is_phys_immune = select(1, target:is_damage_immune(target.DMG.PHYSICAL))
            if not is_phys_immune then
                local target_pos = target:get_position()
                if target_pos then
                    local dist = player_pos:dist_to_ignore_z(target_pos)
                    if dist <= 5.0 then
                        -- Don't swap to a Gouged target (would immediately pause again)
                        local is_target_gouged = false
                        if gouge_spell and gouge_spell.ids then
                            is_target_gouged = target:debuff_up(gouge_spell.ids) == true
                        end
                        if is_target_gouged then
                            goto continue
                        end

                        -- Only engaged enemies (no accidental pulls)
                        if helpers:is_enemy_engaged_with_player(local_player, target) then
                            table.insert(nearby_enemies, target)
                        end
                    end
                end
            end
        end
        ::continue::
    end

    -- Need at least 1 other enemy to consider switching
    if #nearby_enemies < 1 then
        return false
    end

    -- Find highest HP enemy
    local best_target = nil
    local best_hp = 0

    for _, enemy in __object_safety.live_ipairs(nearby_enemies) do
        local enemy_hp = enemy:get_health()
        if enemy_hp > best_hp then
            best_hp = enemy_hp
            best_target = enemy
        end
    end

    -- Switch to highest HP target
    if best_target and (not __object_safety.same(best_target,current_target)) then
        core.input.set_target(best_target)
        last_smart_target_switch_time = now
        helpers:log_checkpoint("target.switch", 2.0, "[TARGET] SWITCH")
        return true
    end

    return false
end

-- Combat Logic
---@param local_player game_object
---@param targets_list game_object[]
---@return boolean
run_rotation = function(local_player, targets_list)
    local now = core.time()
    prune_recent_targets(now)

    local logging_enabled = menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
    if not logging_enabled then
        diag_target_summary.last_flush_time = 0.0
    elseif diag_target_summary.last_flush_time == 0.0 then
        diag_target_summary.last_flush_time = now
        reset_diag_target_summary()
    end

    local pvp_active = helpers.is_pvp_mode_active and helpers:is_pvp_mode_active() == true
    if pvp_active and menu_elements.pvp_require_pvp_scenario and menu_elements.pvp_require_pvp_scenario.get_state then
        if menu_elements.pvp_require_pvp_scenario:get_state() == true then
            pvp_active = helpers.is_pvp_scenario and helpers:is_pvp_scenario() == true
        end
    end

    -- EMERGENCY HARDCORE SURVIVAL (absolute highest priority - 20% default)
    if helpers:try_emergency_vanish_sprint(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp01", 0.5, "[ROT] CP01")
        end
        return true
    end

    -- VANISH SAFETY: Suppress attacks briefly after Vanish (even if party is in combat)
    if helpers:is_vanish_attack_suppressed(local_player) then
        pcall(function()
            core.input.stop_attack()
        end)
        if logging_enabled then
            helpers:log_checkpoint("rot.cp02", 0.5, "[ROT] CP02")
        end
        return true
    end

    -- PICKPOCKET DETECTION & CONFIG SYNC (PvE only)
    if not pvp_active then
        helpers:sync_pickpocket_config()
        helpers:check_pickpocket_detection(local_player)

        -- ? CRITICAL FIX: Process loot BEFORE pickpocket returns
        -- Check if there's an open loot window (pickpocket or corpse)
        local loot_window_is_open = false
        local ok_loot_check, loot_check_count = pcall(function()
            return core.game_ui.get_loot_item_count()
        end)
        if ok_loot_check and loot_check_count and loot_check_count >= 0 then
            loot_window_is_open = true
            helpers:try_auto_loot(local_player)  -- Process window NOW
        end

        -- PICKPOCKET (stealth, independent of target selector)
        if helpers:try_pickpocket(local_player) then
            if logging_enabled then
                helpers:log_checkpoint("rot.cp12", 0.5, "[ROT] CP12")
            end
            -- Only return true if NO loot window is open (let rotation continue to process loot)
            if not loot_window_is_open then
                return true
            end
            -- else: loot window open, continue rotation
        end
    end

    -- STEALTH SAFETY: Never auto-attack while stealthed. In PvP, execute overlay logic here.
    if helpers:is_in_stealth(local_player) then
        pcall(function()
            core.input.stop_attack()
        end)
        if pvp_active and pvp_rotation and pvp_rotation.execute then
            pvp_rotation:execute(local_player, helpers, targets_list)
        end
        if logging_enabled then
            helpers:log_checkpoint("rot.cp03", 0.5, "[ROT] CP03")
        end
        return true
    end

    -- EMERGENCY BLIND (creates safe window - 25% default, after Vanish, respects DoT priority)
    local current_target = local_player:get_target()
    if current_target and helpers:try_emergency_blind(local_player, current_target) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp04", 0.5, "[ROT] CP04")
        end
        return true
    end

    -- GOUGE + BANDAGE EMERGENCY HEALING (during active Gouge, if bandage flag is set)
    if helpers:is_gouge_energy_regen_active() and helpers:should_bandage_during_gouge() then
        -- Try to apply bandage during Gouge
        helpers:try_use_bandage(local_player)
        -- Continue pausing rotation while Gouge is active (regardless of bandage success)
        if logging_enabled then
            helpers:log_checkpoint("rot.cp05", 0.5, "[ROT] CP05")
        end
        return true
    end

    -- AUTO BANDAGE (highest healing priority - 40% default, conserves pots during safe windows)
    if helpers:try_use_bandage(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp06", 0.5, "[ROT] CP06")
        end
        return true
    end

    -- AUTO HEALTHSTONE (fallback healing - 35% default)
    if helpers:try_use_healthstone(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp07", 0.5, "[ROT] CP07")
        end
        return true
    end

    -- AUTO HEALTH POTION (last resort consumable - 25% default)
    if helpers:try_use_health_potion(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp08", 0.5, "[ROT] CP08")
        end
        return true
    end

    -- AUTO TARGET DUMMY (emergency decoy - 15% default)
    if helpers:try_use_target_dummy(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp09", 0.5, "[ROT] CP09")
        end
        return true
    end

    -- AUTO CLOAK OF SHADOWS (TBC - magic/curse purge + resist)
    if helpers:try_use_cloak_of_shadows(local_player, current_target) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp09a", 0.5, "[ROT] CP09A")
        end
        return true
    end

    -- AUTO EVASION (defensive cooldown - 40% default)
    if helpers:try_use_evasion(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp10", 0.5, "[ROT] CP10")
        end
        return true
    end

    -- FRONT ARC INTERRUPTS (scan 180 degrees in front, 5 yards)
    if helpers:try_interrupt_nearby(local_player, 5, math.pi / 2) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp11", 0.5, "[ROT] CP11")
        end
        return true
    end

    -- ENGINEERING EXPLOSIVES (AoE only, engaged targets only)
    if helpers:try_use_engineering_explosive(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp13", 0.5, "[ROT] CP13")
        end
        return true
    end

    -- ON-USE ITEMS (Trinkets / Drums) - gated via Burst toggle and TTD settings
    local current_target_for_items = local_player:get_target()
    if current_target_for_items and helpers:try_use_trinkets(local_player, current_target_for_items) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp13a", 0.5, "[ROT] CP13A")
        end
        return true
    end
    if current_target_for_items and helpers:try_use_drums(local_player, current_target_for_items) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp13b", 0.5, "[ROT] CP13B")
        end
        return true
    end

    -- AUTO QUEST INTERACT (out of combat, open world quest objects)
    if helpers:try_auto_interact_quest_objects(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp14", 0.5, "[ROT] CP14")
        end
        return true
    end

    -- AUTO MINING (out of combat, nearby nodes)
    if helpers:try_auto_mine(local_player) then
        if logging_enabled then
            helpers:log_checkpoint("rot.cp15", 0.5, "[ROT] CP15")
        end
        return true
    end

    -- CP-aware target switching (only when current target is Gouged, with CP threshold)
    -- Gouge creates safe window to switch targets without breaking CC
    -- Must execute before target loop to ensure fresh targets_list after switch
    local player_target = local_player:get_target()
    if player_target then
        local gouge_spell = spell_data.cc.gouge
        local is_gouged = false
        if gouge_spell and gouge_spell.ids then
            is_gouged = player_target:debuff_up(gouge_spell.ids) == true
        end

        if is_gouged then
            local max_cp_to_drop = menu_elements.gouge_target_swap_max_cp and menu_elements.gouge_target_swap_max_cp:get() or 0
            local cp = helpers:get_combo_points(local_player)
            if max_cp_to_drop <= 0 or (max_cp_to_drop < 5 and cp > max_cp_to_drop) then
                -- Don't switch and don't attack other targets; wait on Gouge window to end
                pcall(function()
                    core.input.stop_attack()
                end)
                if logging_enabled then
                    helpers:log_checkpoint("rot.cp16", 0.5, "[ROT] CP16_WAIT")
                end
                return true
            end

            if try_smart_target_switch(local_player, player_target, targets_list) then
                -- Target switched, refresh list for current frame
                targets_list = target_selector:get_targets()
                if logging_enabled then
                    helpers:log_checkpoint("rot.cp16", 0.5, "[ROT] CP16_SWAP")
                end
            end
        end
    end

    for _, target in __object_safety.live_ipairs(targets_list) do
        if logging_enabled then
            diag_target_summary.scanned = diag_target_summary.scanned + 1
        end

        local has_cheap_shot = target:debuff_up({1833}) == true
        if not has_cheap_shot then
            local ok, is_buff = pcall(function()
                return target:buff_up({1833})
            end)
            has_cheap_shot = ok and is_buff == true
        end

        -- BUGFIX: Mark unbreakable stun targets as recent to bypass engagement check
        -- Cheap Shot and Kidney Shot are classified as INCAPACITATE in WoW API,
        -- causing is_enemy_engaged_with_player() to return false and skip rotation
        if has_cheap_shot then
            mark_recent_target(target)
        end

        local kidney_shot_check = spell_data.cc.kidney_shot
        if kidney_shot_check and target:debuff_up(kidney_shot_check.ids) == true then
            mark_recent_target(target)
        end

        if not target:is_alive() then
            if logging_enabled then
                diag_target_summary.skip_dead = diag_target_summary.skip_dead + 1
            end
            goto continue
        end

        if not target:affecting_combat() and not has_cheap_shot and not is_recent_target(target, now) then
            if logging_enabled then
                diag_target_summary.skip_ooc = diag_target_summary.skip_ooc + 1
            end
            goto continue
        end

        -- Only attack targets engaged with us or our party, or targets we recently hit
        if not helpers:is_enemy_engaged_with_player(local_player, target) and not is_recent_target(target, now) then
            if logging_enabled then
                diag_target_summary.skip_unengaged = diag_target_summary.skip_unengaged + 1
            end
            goto continue
        end

        local is_phys_immune = select(1, target:is_damage_immune(target.DMG.PHYSICAL))
        if is_phys_immune then
            if logging_enabled then
                diag_target_summary.skip_phys_immune = diag_target_summary.skip_phys_immune + 1
            end
            goto continue
        end

        -- CRITICAL: Stop auto-attacks if target has breakable CC (Gouge, Blind, Sap)
        -- Breakable CCs break on damage, unbreakable stuns (Cheap Shot, Kidney) do not
        if rotation_logic:is_breakable_cc_active(target, has_cheap_shot) then
            -- Stop auto-attacks if currently attacking
            if (__object_safety.same(target,local_player:get_target())) and auto_attack_helper:is_auto_attacking(local_player) then
                auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
                if logging_enabled then
                    helpers:log_checkpoint("aa.stop", 1.0, "[AA] STOP")
                end
            end
            if logging_enabled then
                diag_target_summary.skip_breakable_cc = diag_target_summary.skip_breakable_cc + 1
            end
            goto continue  -- Skip rotation for this CC'd target
        end

        -- Ensure auto attack is active
        if not auto_attack_helper:is_auto_attacking(local_player) then
            auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
            mark_recent_target(target)
            if logging_enabled then
                helpers:log_checkpoint("aa.start", 1.0, "[AA] START")
            end
        end

        -- MAIN ROTATION EXECUTION
        if rotation_logic:execute(local_player, target, helpers, has_cheap_shot, targets_list) then
            mark_recent_target(target)
            if logging_enabled then
                diag_target_summary.acted = diag_target_summary.acted + 1
            end
            return true
        end

        ::continue::
    end

    if logging_enabled and (now - diag_target_summary.last_flush_time) >= 1.5 then
        local has_activity =
            diag_target_summary.acted > 0 or
            diag_target_summary.skip_dead > 0 or
            diag_target_summary.skip_ooc > 0 or
            diag_target_summary.skip_unengaged > 0 or
            diag_target_summary.skip_phys_immune > 0 or
            diag_target_summary.skip_breakable_cc > 0

        if has_activity then
            helpers:log_checkpoint("targets.summary", 1.5, string.format("[TARGETS] s=%d a=%d sd=%d so=%d su=%d si=%d sc=%d",
                diag_target_summary.scanned,
                diag_target_summary.acted,
                diag_target_summary.skip_dead,
                diag_target_summary.skip_ooc,
                diag_target_summary.skip_unengaged,
                diag_target_summary.skip_phys_immune,
                diag_target_summary.skip_breakable_cc))
        end

        diag_target_summary.last_flush_time = now
        reset_diag_target_summary()
    end

    -- AUTO SKINNING (after pickpocket, before loot)
    if helpers:try_auto_skin(local_player) then
        return true
    end

    -- AUTO LOOT (lowest priority - after combat actions)
    if helpers:try_auto_loot(local_player) then
        return true
    end

    return false
end

-- Out-of-Combat
---@param local_player game_object
---@return boolean
handle_out_of_combat = function(local_player)
    return false
end

-- Render
function rogue:on_render(local_player)
    -- Render Custom UI Window
    settings_ui:on_render()

    if not local_player then
        return
    end

    if not menu_elements.enable_script_check:get_state() then
        return
    end

    if not plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) then
        if menu_elements.draw_plugin_state:get_state() then
            plugin_helper:draw_text_character_center("DISABLED")
        end
    end
end

-- Control panel rendering
function rogue:on_control_panel_render()
    local control_panel_elements = {}

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "Rogue Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "Burst (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "AoE (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "CC/Interrupts (" .. key_helper:get_key_name(menu_elements.cc_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cc_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "Auto Pickpocket (" .. key_helper:get_key_name(menu_elements.pickpocket_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.pickpocket_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "Engineering Explosives (" .. key_helper:get_key_name(menu_elements.engineering_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.engineering_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "Gouge Energy Regen (" .. key_helper:get_key_name(menu_elements.gouge_energy_regen_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.gouge_energy_regen_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements,
    {
        name = "PvP Mode (" .. key_helper:get_key_name(menu_elements.pvp_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.pvp_mode_toggle
    })

    return control_panel_elements
end

return rogue
