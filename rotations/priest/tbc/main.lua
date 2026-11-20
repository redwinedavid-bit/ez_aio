-- ============================================================================
-- Priest Healer Rotation Module (AIO-compatible)
-- World of Warcraft TBC Classic (2.4.3)
-- ============================================================================
print("[AIO] Initializing Priest Rotation v1.1...")


local priest = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/priest/tbc/rotation_logic")
local shadow_rotation_logic = require("rotations/priest/tbc/shadow_rotation_logic")


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

---@type auto_consumables
local auto_consumables = require("shared/auto_consumables")

local log_capture = require("shared/log_capture")

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
    shadow_tree = md.tree_node(), -- Old shadow leveling tree
    pvp_tree = md.tree_node(),
    mana_ticks_tree = md.tree_node(),
    automation_tree = md.tree_node(),
    profiles_tree = md.tree_node(),
    sp_tree = md.tree_node(), -- New Shadow Priest standalone tree

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
    stop_healing_hp = md.slider_int(70, 100, 95, "priest_stop_healing_hp"),
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
    gh_min_rank = md.slider_int(1, 7, 1, "priest_gh_min_rank"),
    gh_max_rank = md.slider_int(1, 7, 7, "priest_gh_max_rank"),
    h_min_rank = md.slider_int(1, 4, 1, "priest_h_min_rank"),
    h_max_rank = md.slider_int(1, 4, 4, "priest_h_max_rank"),
    fh_min_rank = md.slider_int(1, 9, 1, "priest_fh_min_rank"),
    fh_max_rank = md.slider_int(1, 9, 9, "priest_fh_max_rank"),

    -- Cancel Casting (Anti Fake Cast)
    enable_cancel_casting = md.checkbox(true, "priest_enable_cancel_casting"),
    cancel_cast_target_hp = md.slider_int(80, 100, 95, "priest_cancel_cast_target_hp"),

    -- TBC Talent Spells
    use_circle_of_healing = md.checkbox(true, "priest_use_coh"),
    coh_hp_threshold = md.slider_int(50, 95, 85, "priest_coh_hp_threshold"),
    coh_min_targets = md.slider_int(2, 5, 3, "priest_coh_min_targets"),
    
    -- Healing Spell Toggles
    use_renew = md.checkbox(true, "priest_use_renew"),
    use_prayer_of_mending = md.checkbox(true, "priest_use_prayer_of_mending"),
    use_binding_heal = md.checkbox(true, "priest_use_binding_heal"),
    use_shield = md.checkbox(true, "priest_use_shield"),
    avoid_shield_on_rage_tanks = md.checkbox(true, "priest_avoid_shield_on_rage"),
    use_fade = md.checkbox(true, "priest_use_fade"),
    use_downranking = md.checkbox(true, "priest_use_downranking"),
    use_circle_of_healing_option = md.checkbox(true, "priest_use_coh_option"),
    use_heal = md.checkbox(true, "priest_use_heal"),
    use_greater_heal = md.checkbox(true, "priest_use_greater_heal"),
    use_flash_heal = md.checkbox(true, "priest_use_flash_heal"),
    use_dispel_magic = md.checkbox(true, "priest_use_dispel_magic"),

    -- Buffs
    use_buffs = md.checkbox(true, "priest_use_buffs"),
    use_shadow_protection = md.checkbox(false, "priest_use_shadow_protection"),

    -- Dispel
    use_dispel = md.checkbox(true, "priest_use_dispel"),
    cancel_shadowform_dispel = md.checkbox(true, "priest_cancel_sf_dispel"),
    avoid_dispel_fear = md.checkbox(true, "priest_avoid_dispel_fear"),
    use_mass_dispel = md.checkbox(false, "priest_use_mass_dispel"),
    mass_dispel_min_targets = md.slider_int(2, 5, 2, "priest_mass_dispel_min_targets"),

    -- Cooldowns
    use_power_infusion = md.checkbox(true, "priest_use_power_infusion"),
    use_inner_focus = md.checkbox(true, "priest_use_inner_focus"),
    use_pain_suppression = md.checkbox(true, "priest_use_pain_suppression"),
    use_shadowfiend = md.checkbox(true, "priest_use_shadowfiend"),
    shadowfiend_mana_threshold = md.slider_int(5, 60, 25, "priest_shadowfiend_mana_threshold"),
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
    no_healing_in_shadowform = md.checkbox(false, "priest_no_healing_in_shadowform"),
    attack_on_target = md.checkbox(true, "priest_attack_on_target"),
    use_vampiric_embrace = md.checkbox(true, "priest_use_vampiric_embrace"),
    use_vampiric_touch = md.checkbox(true, "priest_use_vampiric_touch"),
    use_shadow_word_death = md.checkbox(true, "priest_use_shadow_word_death"),
    swd_min_hp = md.slider_int(10, 80, 35, "priest_swd_min_hp"),
    use_mind_blast = md.checkbox(true, "priest_use_mind_blast"),
    use_lesser_heal_fallback = md.checkbox(true, "priest_use_lesser_heal_fallback"),
    pvp_unlock_pin = md.text_input("priest_pvp_unlock_pin", true),

    -- PvP & Utility
    enable_pvp_mode = md.checkbox(false, "priest_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "priest_pvp_rotation_tick_rate"),
    mass_dispel_sniping = md.checkbox(true, "priest_mass_dispel_sniping"),
    use_fear_ward_auto = md.checkbox(true, "priest_use_fear_ward_auto"),
    use_pain_suppression_stun = md.checkbox(true, "priest_use_pain_suppression_stun"),
    auto_totem_stomping = md.checkbox(true, "priest_auto_totem_stomping"),
    use_swd_breaker = md.checkbox(true, "priest_use_swd_breaker"),
    use_offensive_dispel = md.checkbox(true, "priest_use_offensive_dispel"),
    purge_high_priority_only = md.checkbox(true, "priest_purge_high_priority"),
    use_shackle_undead = md.checkbox(true, "priest_use_shackle_undead"),
    use_mana_burn = md.checkbox(false, "priest_use_mana_burn"),
    mana_burn_focus_only = md.checkbox(true, "priest_mana_burn_focus"),
    mana_burn_target_mana = md.slider_int(10, 80, 20, "priest_mana_burn_target_mana"),
    use_silence_focus = md.checkbox(true, "priest_use_silence_focus"), -- Shadow
    use_swp_multidot = md.checkbox(false, "priest_use_swp_multidot"),
    swp_max_targets = md.slider_int(1, 5, 3, "priest_swp_max_targets"),
    swp_min_mana = md.slider_int(0, 100, 40, "priest_swp_min_mana"),

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

    -- Auto Consumables
    auto_consumables_enabled = md.checkbox(true, "priest_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "priest_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 40, "priest_auto_drink_pct"),

    -- CC & Utility
    use_psychic_scream = md.checkbox(true, "priest_use_psychic_scream"),
    scream_mob_count = md.slider_int(2, 5, 2, "priest_scream_mob_count"),
    scream_hp_threshold = md.slider_int(10, 60, 35, "priest_scream_hp_threshold"),
    
    -- Debug Logging
    rotation_log_enabled = md.checkbox(false, "priest_rotation_log_enabled"),
    rotation_file_logging_enabled = md.checkbox(false, "priest_rotation_file_logging_enabled"),

    -- Profiles & Sharing
    profile_string = md.text_input("priest_profile_string", true),
    export_button = core.menu.button("priest_export_button"),
    import_clipboard_button = core.menu.button("priest_import_clipboard_button"),

    -- UI Reset
    reset_ui_position = md.checkbox(false, "priest_reset_ui_position"),

    -- ========================================================================
    -- SHADOW PRIEST MODE (Self-Healing Only)
    -- ========================================================================
    sp_mode_enabled = md.checkbox(false, "spriest_mode_enabled"),

    -- Shadow DPS Abilities
    sp_use_vampiric_touch = md.checkbox(true, "spriest_use_vampiric_touch"),
    sp_use_shadow_word_pain = md.checkbox(true, "spriest_use_shadow_word_pain"),
    sp_use_devouring_plague = md.checkbox(true, "spriest_use_devouring_plague"),
    sp_use_vampiric_embrace = md.checkbox(true, "spriest_use_vampiric_embrace"),
    sp_use_mind_blast = md.checkbox(true, "spriest_use_mind_blast"),
    sp_use_mind_flay = md.checkbox(true, "spriest_use_mind_flay"),
    sp_use_shadow_word_death = md.checkbox(true, "spriest_use_shadow_word_death"),
    sp_swd_target_hp = md.slider_int(0, 100, 25, "spriest_swd_target_hp"),
    sp_swd_min_player_hp = md.slider_int(10, 80, 35, "spriest_swd_min_player_hp"),
    sp_dot_refresh_threshold = md.slider_int(0, 100, 20, "spriest_dot_refresh_threshold"),
    sp_maintain_shadowform = md.checkbox(true, "spriest_maintain_shadowform"),
    sp_attack_on_target = md.checkbox(true, "spriest_attack_on_target"),

    -- Shadow Priest Multi-DoT
    sp_enable_multidot = md.checkbox(false, "spriest_enable_multidot"),
    sp_multidot_limit = md.slider_int(1, 5, 3, "spriest_multidot_limit"),

    -- Shadow Priest Wand
    sp_use_wand = md.checkbox(true, "spriest_use_wand"),
    sp_wand_mana_threshold = md.slider_int(0, 50, 15, "spriest_wand_mana_threshold"),
    sp_wand_target_hp = md.slider_int(0, 100, 10, "spriest_wand_target_hp"),

    -- Shadow Priest Self-Healing
    sp_self_heal_enabled = md.checkbox(true, "spriest_self_heal_enabled"),
    sp_self_heal_hp = md.slider_int(20, 80, 50, "spriest_self_heal_hp"),
    sp_use_flash_heal = md.checkbox(true, "spriest_use_flash_heal"),
    sp_self_flash_heal_hp = md.slider_int(10, 60, 35, "spriest_self_flash_heal_hp"),
    sp_use_self_renew = md.checkbox(true, "spriest_use_self_renew"),
    sp_self_renew_hp = md.slider_int(30, 90, 70, "spriest_self_renew_hp"),
    sp_use_self_shield = md.checkbox(true, "spriest_use_self_shield"),
    sp_self_shield_hp = md.slider_int(20, 80, 60, "spriest_self_shield_hp"),
    sp_use_desperate_prayer = md.checkbox(true, "spriest_use_desperate_prayer"),
    sp_desperate_prayer_hp = md.slider_int(10, 40, 25, "spriest_desperate_prayer_hp"),
    sp_cancel_shadowform_heal = md.checkbox(true, "spriest_cancel_shadowform_heal"),

    -- Shadow Priest Cooldowns
    sp_use_shadowfiend = md.checkbox(true, "spriest_use_shadowfiend"),
    sp_shadowfiend_mana = md.slider_int(5, 60, 30, "spriest_shadowfiend_mana"),
    sp_use_inner_focus = md.checkbox(true, "spriest_use_inner_focus"),
    sp_inner_focus_mana = md.slider_int(5, 50, 30, "spriest_inner_focus_mana"),

    -- Shadow Priest Consumables
    sp_use_hp_potions = md.checkbox(true, "spriest_use_hp_potions"),
    sp_hp_potion_at = md.slider_int(10, 50, 30, "spriest_hp_potion_at"),
    sp_use_mana_potions = md.checkbox(true, "spriest_use_mana_potions"),
    sp_mana_potion_at = md.slider_int(10, 40, 25, "spriest_mana_potion_at"),

    -- Shadow Priest Utility
    sp_use_fade = md.checkbox(true, "spriest_use_fade"),
    sp_use_psychic_scream = md.checkbox(true, "spriest_use_psychic_scream"),
    sp_scream_mob_count = md.slider_int(1, 5, 3, "spriest_scream_mob_count"),
    sp_scream_hp_threshold = md.slider_int(10, 60, 30, "spriest_scream_hp_threshold"),
    sp_use_self_dispel = md.checkbox(true, "spriest_use_self_dispel"),
    sp_use_shadow_protection = md.checkbox(false, "spriest_use_shadow_protection"),

    -- Shadow Priest PvP
    sp_use_silence = md.checkbox(true, "spriest_use_silence"),
    sp_silence_delay_ms = md.slider_int(0, 1500, 200, "spriest_silence_delay_ms"),
    sp_use_mana_burn = md.checkbox(true, "spriest_use_mana_burn"),
    sp_mana_burn_target_mana = md.slider_int(0, 100, 20, "spriest_mana_burn_target_mana"),
    sp_use_swd_breaker = md.checkbox(true, "spriest_use_swd_breaker"),
    sp_use_offensive_dispel = md.checkbox(true, "spriest_use_offensive_dispel"),
    sp_blackout_mode = md.checkbox(false, "spriest_blackout_mode"),
}

-- ============================================================================
-- CUSTOM UI (ESP STYLE)
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "priest_tbc",
    title = "Priest Rotation",
    theme = "priest",
    default_x = 550,
    default_y = 200,
    default_w = 480,
    default_h = 650
})

-- Core Controls Tab
settings_ui:add_tab({ id = "core", label = "Core Controls" }, function(t)
    t:keybind_grid({
        elements = { menu_elements.enable_toggle, menu_elements.ui_toggle_hotkey },
        labels = { "Enable Script", "UI Toggle (F1)" }
    })
    t:keybind_grid({
        elements = { menu_elements.cooldowns_toggle, menu_elements.aoe_toggle, menu_elements.healing_only_toggle },
        labels = { "Burst Toggle", "AoE Toggle", "Healing Only" }
    })
    t:checkbox_grid({
        label = "Global Settings",
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script (Master)" },
            { element = menu_elements.rotation_log_enabled, label = "Debug Logging" },
            { element = menu_elements.rotation_file_logging_enabled, label = "Log to TXT File" }
        }
    })
    t:checkbox_grid({
        label = "Profile Management",
        elements = {
            { element = menu_elements.export_button, label = "Export to Clipboard" },
            { element = menu_elements.import_clipboard_button, label = "Import from Clipboard" }
        }
    })
end)

-- Healing Tab
settings_ui:add_tab({ id = "healing", label = "Healing" }, function(t)
    t:checkbox_grid({
        label = "Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_healing, label = "Enable Healing" },
            { element = menu_elements.enable_aoe, label = "Enable AoE" },
            { element = menu_elements.healing_only, label = "Healing Only Mode" },
            { element = menu_elements.use_circle_of_healing, label = "Circle of Healing" },
            { element = menu_elements.use_prayer_of_mending, label = "Prayer of Mending" },
            { element = menu_elements.use_renew, label = "Renew" },
            { element = menu_elements.use_shield, label = "Shield" },
            { element = menu_elements.avoid_shield_on_rage_tanks, label = "Avoid Shield on Rage" },
            { element = menu_elements.use_power_infusion, label = "Power Infusion (Support)" },
            { element = menu_elements.enable_cancel_casting, label = "Cancel Casting (Anti-Overheal)" }
        }
    })
    t:slider_list({
        label = "Thresholds (HP%)",
        elements = {
            { element = menu_elements.heal_hp, label = "Heal", suffix = "%" },
            { element = menu_elements.flash_heal_hp, label = "Flash Heal", suffix = "%" },
            { element = menu_elements.shield_hp, label = "Shield", suffix = "%" },
            { element = menu_elements.tank_emergency_hp, label = "Tank Emergency", suffix = "%" },
            { element = menu_elements.player_emergency_hp, label = "Player Emergency", suffix = "%" },
            { element = menu_elements.aoe_hp_threshold, label = "AoE Trigger", suffix = "%" },
            { element = menu_elements.cancel_cast_target_hp, label = "Cancel Cast At", suffix = "%" }
        }
    })
    t:slider_list({
        label = "Group Logic",
        elements = {
            { element = menu_elements.group_aoe_threshold, label = "Min Targets for AoE", suffix = " ppl" },
            { element = menu_elements.coh_min_targets, label = "Min Targets for CoH", suffix = " ppl" }
        }
    })
end)

-- Shadow Priest Tab
settings_ui:add_tab({ id = "shadow", label = "Shadow Priest" }, function(t)
    t:checkbox_grid({
        label = "Shadow Mode Toggle",
        elements = {
            { element = menu_elements.sp_mode_enabled, label = "Enable Shadow Priest Mode" }
        }
    })
    
    t:checkbox_grid({
        label = "DPS Settings",
        columns = 2,
        elements = {
            { element = menu_elements.sp_maintain_shadowform, label = "Maintain Shadowform" },
            { element = menu_elements.sp_use_vampiric_touch, label = "Vampiric Touch" },
            { element = menu_elements.sp_use_vampiric_embrace, label = "Vampiric Embrace" },
            { element = menu_elements.sp_use_shadow_word_pain, label = "Shadow Word Pain" },
            { element = menu_elements.sp_use_devouring_plague, label = "Devouring Plague" },
            { element = menu_elements.sp_use_mind_blast, label = "Mind Blast" },
            { element = menu_elements.sp_use_mind_flay, label = "Mind Flay" },
            { element = menu_elements.sp_enable_multidot, label = "Multi-DoT" },
            { element = menu_elements.sp_use_wand, label = "Auto Wand Filler" }
        }
    })

    t:slider_list({
        label = "Shadow Thresholds",
        elements = {
            { element = menu_elements.sp_multidot_limit, label = "Multi-DoT Max Targets" },
            { element = menu_elements.sp_dot_refresh_threshold, label = "DoT Refresh Target HP", suffix = "%" },
            { element = menu_elements.sp_wand_mana_threshold, label = "Wand Below Mana", suffix = "%" },
            { element = menu_elements.sp_wand_target_hp, label = "Wand Below Target HP", suffix = "%" }
        }
    })

    t:checkbox_grid({
        label = "Self-Healing (Shadow)",
        columns = 2,
        elements = {
            { element = menu_elements.sp_self_heal_enabled, label = "Enable Self-Healing" },
            { element = menu_elements.sp_cancel_shadowform_heal, label = "Leave SF to Heal" },
            { element = menu_elements.sp_use_desperate_prayer, label = "Desperate Prayer" },
            { element = menu_elements.sp_use_self_shield, label = "PW: Shield" },
            { element = menu_elements.sp_use_self_renew, label = "Renew" },
            { element = menu_elements.sp_use_flash_heal, label = "Flash Heal" }
        }
    })

    t:slider_list({
        label = "Self-Healing Thresholds",
        elements = {
            { element = menu_elements.sp_self_heal_hp, label = "General Healing", suffix = "%" },
            { element = menu_elements.sp_desperate_prayer_hp, label = "Desperate Prayer", suffix = "%" },
            { element = menu_elements.sp_self_shield_hp, label = "Shield", suffix = "%" },
            { element = menu_elements.sp_self_renew_hp, label = "Renew", suffix = "%" },
            { element = menu_elements.sp_self_flash_heal_hp, label = "Flash Heal", suffix = "%" }
        }
    })
end)

-- PvP & Utility Tab
settings_ui:add_tab({ id = "utility", label = "PvP & Utility" }, function(t)
    t:checkbox_grid({
        label = "PvP Settings",
        columns = 2,
        elements = {
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" },
            { element = menu_elements.mass_dispel_sniping, label = "Mass Dispel Sniping" },
            { element = menu_elements.use_fear_ward_auto, label = "Auto Fear Ward" },
            { element = menu_elements.use_pain_suppression_stun, label = "Pain Sup. on Stun" },
            { element = menu_elements.auto_totem_stomping, label = "Auto Totem Stomping" },
            { element = menu_elements.sp_use_silence, label = "Auto Silence (Shadow)" },
            { element = menu_elements.sp_use_swd_breaker, label = "SW:D CC Breaker" },
            { element = menu_elements.sp_use_offensive_dispel, label = "Offensive Purge" },
            { element = menu_elements.use_dispel, label = "Defensive Dispel" },
            { element = menu_elements.avoid_dispel_fear, label = "Avoid Dispel Fear" },
            { element = menu_elements.cancel_shadowform_dispel, label = "Leave SF to Dispel" }
        }
    })
    t:slider_list({
        label = "Utility Settings",
        elements = {
            { element = menu_elements.pvp_rotation_tick_rate, label = "PvP Rotation Frequency", suffix = " ms", bounds = { min = 30, max = 100 } },
            { element = menu_elements.sp_silence_delay_ms, label = "Silence Delay", suffix = " ms" },
            { element = menu_elements.sp_mana_burn_target_mana, label = "Mana Burn Below", suffix = "%" }
        }
    })
    t:checkbox_grid({
        label = "Crowd Control",
        elements = {
            { element = menu_elements.sp_use_psychic_scream, label = "Psychic Scream (Emergency)" },
            { element = menu_elements.use_shackle_undead, label = "Auto Shackle Undead" }
        }
    })
end)

-- Automation Tab
settings_ui:add_tab({ id = "automation", label = "Automation" }, function(t)
    t:checkbox_grid({
        label = "Looting & Gathering",
        columns = 2,
        elements = {
            { element = menu_elements.auto_loot_enabled, label = "Auto Loot" },
            { element = menu_elements.auto_skin_enabled, label = "Auto Skin" },
            { element = menu_elements.auto_mine_enabled, label = "Auto Mine" },
            { element = menu_elements.auto_herb_enabled, label = "Auto Herb" },
            { element = menu_elements.auto_quest_interact_enabled, label = "Quest Auto-Interact" }
        }
    })
    t:slider_list({
        label = "Range Settings",
        elements = {
            { element = menu_elements.auto_skin_range, label = "Skin Range" },
            { element = menu_elements.auto_mine_range, label = "Mine Range" },
            { element = menu_elements.auto_herb_range, label = "Herb Range" },
            { element = menu_elements.auto_quest_interact_range, label = "Quest Interact Range" }
        }
    })
    t:checkbox_grid({
        label = "Consumables",
        elements = {
            { element = menu_elements.auto_consumables_enabled, label = "Auto Food/Drink" }
        }
    })
    t:slider_list({
        label = "HP/Mana Recovery",
        elements = {
            { element = menu_elements.auto_food_pct, label = "Food Threshold", suffix = "%" },
            { element = menu_elements.auto_drink_pct, label = "Drink Threshold", suffix = "%" }
        }
    })
end)

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

-- ============================================================================
-- MENU RENDERING
-- ============================================================================

-- ============================================================================
-- MENU RENDERING
-- ============================================================================

function priest:on_menu_render()
    -- Custom UI Window Toggle
    if settings_ui then
        settings_ui:on_menu_render("Show Custom UI Window")
    end

    menu_elements.main_tree:render("Priest Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")

        menu_elements.healing_tree:render("Healing Settings", function()
            menu_elements.use_heal:render("Use Heal (Obsolete at 70)")
            menu_elements.use_greater_heal:render("Use Greater Heal")
            menu_elements.use_flash_heal:render("Use Flash Heal")
            menu_elements.use_renew:render("Use Renew (HoT)")
            menu_elements.use_prayer_of_mending:render("Use Prayer of Mending")
            menu_elements.use_binding_heal:render("Use Binding Heal")
            menu_elements.use_shield:render("Use Power Word: Shield")
            menu_elements.use_fade:render("Use Fade (Threat)")
            menu_elements.use_dispel_magic:render("Use Dispel Magic")
            menu_elements.use_lesser_heal_fallback:render("Use Lesser Heal Fallback (Low Mana)")

            menu_elements.stop_healing_hp:render("Stop Healing Above %")
            menu_elements.tank_emergency_hp:render("Tank Emergency HP %")
            menu_elements.player_emergency_hp:render("Player Emergency HP %")
            menu_elements.flash_heal_hp:render("Flash Heal HP %")
            menu_elements.heal_hp:render("Greater Heal HP %")
            
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
            
            if menu_elements.enable_smart_downranking:get_state() then
                menu_elements.gh_min_rank:render("GH Min Rank")
                menu_elements.gh_max_rank:render("GH Max Rank")
                if menu_elements.use_heal:get_state() then
                    menu_elements.h_min_rank:render("Heal Min Rank")
                    menu_elements.h_max_rank:render("Heal Max Rank")
                end
                menu_elements.fh_min_rank:render("Flash Heal Min Rank")
                menu_elements.fh_max_rank:render("Flash Heal Max Rank")
            end

            menu_elements.mana_low_threshold:render("Mana Low Threshold %")
        end)

        menu_elements.buffs_tree:render("Buffs & Dispel", function()
            menu_elements.use_buffs:render("Auto-Buff Group")
            menu_elements.use_shadow_protection:render("Use Shadow Protection")
            menu_elements.use_dispel:render("Auto-Dispel (Magic/Disease)")
            menu_elements.cancel_shadowform_dispel:render("Cancel Shadowform for Dispel")
            menu_elements.use_mass_dispel:render("Use Mass Dispel (TBC)")
            if menu_elements.use_mass_dispel:get_state() then
                menu_elements.mass_dispel_min_targets:render("Mass Dispel: Min Targets")
            end
        end)

        menu_elements.cooldowns_tree:render("Cooldowns", function()
            menu_elements.use_power_infusion:render("Use Power Infusion")
            menu_elements.use_inner_focus:render("Use Inner Focus")
            menu_elements.use_pain_suppression:render("Use Pain Suppression (Tank CD)")
            menu_elements.use_shadowfiend:render("Use Shadowfiend")
            if menu_elements.use_shadowfiend:get_state() then
                menu_elements.shadowfiend_mana_threshold:render("Shadowfiend at Mana %")
            end
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

        menu_elements.sp_tree:render("Shadow Priest (PvE/PvP)", function()
            menu_elements.sp_mode_enabled:render("Enable Shadow Priest Mode")
            if menu_elements.sp_mode_enabled:get_state() then
                menu_elements.sp_use_vampiric_touch:render("Use Vampiric Touch")
                menu_elements.sp_use_shadow_word_pain:render("Use Shadow Word: Pain")
                menu_elements.sp_use_devouring_plague:render("Use Devouring Plague")
                menu_elements.sp_use_vampiric_embrace:render("Use Vampiric Embrace")
                menu_elements.sp_use_mind_blast:render("Use Mind Blast")
                menu_elements.sp_use_mind_flay:render("Use Mind Flay")
                menu_elements.sp_use_shadow_word_death:render("Use Shadow Word: Death")
                if menu_elements.sp_use_shadow_word_death:get_state() then
                    menu_elements.sp_swd_target_hp:render("SW:D at Target HP %")
                    menu_elements.sp_swd_min_player_hp:render("SW:D Min Player HP %")
                end
                menu_elements.sp_dot_refresh_threshold:render("DoT Refresh Threshold %")
                menu_elements.sp_maintain_shadowform:render("Maintain Shadowform")
                menu_elements.sp_attack_on_target:render("Auto Attack")

                md.header():render("Shadow Priest Multi-DoT", color.purple())
                menu_elements.sp_enable_multidot:render("Enable Multi-DoTing")
                if menu_elements.sp_enable_multidot:get_state() then
                    menu_elements.sp_multidot_limit:render("Max targets to DoT (1-5)")
                end
                
                md.header():render("Shadow Priest Wand", color.yellow())
                menu_elements.sp_use_wand:render("Use Wand")
                if menu_elements.sp_use_wand:get_state() then
                    menu_elements.sp_wand_mana_threshold:render("Wand below Mana %")
                    menu_elements.sp_wand_target_hp:render("Wand below Target HP %")
                end
                
                md.header():render("Shadow Priest Self-Healing", color.green())
                menu_elements.sp_self_heal_enabled:render("Self Healing Enabled")
                if menu_elements.sp_self_heal_enabled:get_state() then
                    menu_elements.sp_self_heal_hp:render("Heal HP %")
                    menu_elements.sp_use_flash_heal:render("Use Flash Heal")
                    if menu_elements.sp_use_flash_heal:get_state() then
                        menu_elements.sp_self_flash_heal_hp:render("Flash Heal HP %")
                    end
                    menu_elements.sp_use_self_renew:render("Use Renew")
                    if menu_elements.sp_use_self_renew:get_state() then
                        menu_elements.sp_self_renew_hp:render("Renew HP %")
                    end
                    menu_elements.sp_use_self_shield:render("Use Power Word: Shield")
                    if menu_elements.sp_use_self_shield:get_state() then
                        menu_elements.sp_self_shield_hp:render("Shield HP %")
                    end
                    menu_elements.sp_use_desperate_prayer:render("Use Desperate Prayer")
                    if menu_elements.sp_use_desperate_prayer:get_state() then
                        menu_elements.sp_desperate_prayer_hp:render("Desperate Prayer HP %")
                    end
                    menu_elements.sp_cancel_shadowform_heal:render("Cancel Shadowform to Heal")
                end

                md.header():render("Shadow Priest Cooldowns", color.purple())
                menu_elements.sp_use_shadowfiend:render("Use Shadowfiend")
                if menu_elements.sp_use_shadowfiend:get_state() then
                    menu_elements.sp_shadowfiend_mana:render("Shadowfiend Mana %")
                end
                menu_elements.sp_use_inner_focus:render("Use Inner Focus")
                if menu_elements.sp_use_inner_focus:get_state() then
                    menu_elements.sp_inner_focus_mana:render("Inner Focus Mana %")
                end

                md.header():render("Shadow Priest Consumables", color.orange())
                menu_elements.sp_use_hp_potions:render("Use HP Potions")
                if menu_elements.sp_use_hp_potions:get_state() then
                    menu_elements.sp_hp_potion_at:render("HP Potion at %")
                end
                menu_elements.sp_use_mana_potions:render("Use Mana Potions")
                if menu_elements.sp_use_mana_potions:get_state() then
                    menu_elements.sp_mana_potion_at:render("Mana Potion at %")
                end

                md.header():render("Shadow Priest Utility", color.cyan())
                menu_elements.sp_use_fade:render("Use Fade")
                menu_elements.sp_use_psychic_scream:render("Use Psychic Scream")
                if menu_elements.sp_use_psychic_scream:get_state() then
                    menu_elements.sp_scream_mob_count:render("Scream Mob Count")
                    menu_elements.sp_scream_hp_threshold:render("Scream Player HP %")
                end
                menu_elements.sp_use_self_dispel:render("Self Dispel (Magic/Disease)")
                menu_elements.sp_use_shadow_protection:render("Use Shadow Protection buff")

                md.header():render("Shadow Priest PvP", color.red())
                menu_elements.sp_use_silence:render("Silence Casters")
                if menu_elements.sp_use_silence:get_state() then
                    menu_elements.sp_silence_delay_ms:render("Silence Delay Humanizer (ms)")
                end
                menu_elements.sp_use_swd_breaker:render("SW:D CC Breaker (vs Poly/Fear focus)")
                menu_elements.sp_use_offensive_dispel:render("Offensive Purge (Enemy Buffs)")
                menu_elements.sp_use_mana_burn:render("Mana Burn Enemy Healers")
                if menu_elements.sp_use_mana_burn:get_state() then
                    menu_elements.sp_mana_burn_target_mana:render("Stop Burn at Target Mana %")
                end
                menu_elements.sp_blackout_mode:render("Blackout Fishing (Rank 1 SW:P)")
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
                menu_elements.use_mind_blast:render("Use Mind Blast")
                menu_elements.use_shadow_word_death:render("Use Shadow Word: Death")
                if menu_elements.use_shadow_word_death:get_state() then
                    menu_elements.swd_min_hp:render("SW:D Min Player HP %")
                end
            end
        end)

        menu_elements.pvp_tree:render("PvP & Utility", function()
            menu_elements.enable_pvp_mode:render("Enable PvP Mode")
            if menu_elements.enable_pvp_mode:get_state() then
                menu_elements.pvp_rotation_tick_rate:render("PvP Rotation Frequency (ms)")
                menu_elements.mass_dispel_sniping:render("Mass Dispel Sniping (Immunity)")
                menu_elements.use_fear_ward_auto:render("Auto Fear Ward")
                menu_elements.use_pain_suppression_stun:render("Pain Suppression on Stun")
                menu_elements.auto_totem_stomping:render("Auto Totem Stomping")
                menu_elements.use_swd_breaker:render("SW:D CC Breaker")
                menu_elements.use_offensive_dispel:render("Offensive Purge")
                menu_elements.purge_high_priority_only:render("Purge High Priority Only")
                menu_elements.use_mana_burn:render("Use Mana Burn")
                if menu_elements.use_mana_burn:get_state() then
                    menu_elements.mana_burn_focus_only:render("Mana Burn Focus Only")
                    menu_elements.mana_burn_target_mana:render("Stop Burn at Mana %")
                end
                menu_elements.use_silence_focus:render("Silence Focus (Shadow)")
                menu_elements.use_shackle_undead:render("Auto Shackle Undead")
                
                md.header():render("PvP Blackout Optimization", color.purple())
                menu_elements.use_swp_multidot:render("SW:P Multi-Dotting (Blackout)")
                if menu_elements.use_swp_multidot:get_state() then
                    menu_elements.swp_max_targets:render("Max SW:P Targets")
                    menu_elements.swp_min_mana:render("Min Mana % for Dotting")
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

        menu_elements.profiles_tree:render("Profiles & Sharing", function()
            md.header():render("Export or import your rotation settings below.", color.new(200, 200, 200, 255))
            
            menu_elements.export_button:render("Export to Clipboard")
            if menu_elements.export_button:is_clicked() then
                settings_ui:export_profile()
            end
            
            md.header():render("----------------------------------------", color.new(100, 100, 100, 255))
            
            menu_elements.profile_string:render("Profile String")
            
            menu_elements.import_clipboard_button:render("Import from Clipboard")
            if menu_elements.import_clipboard_button:is_clicked() then
                settings_ui:import_from_clipboard()
            end
        end)
    end)
end

local last_file_log_state = false

-- F1 Hotkey State for Custom UI Toggle
local ui_toggle_key_was_pressed = false
local last_rotation_tick_ms = 0

function priest:on_update(local_player)
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
	    if tick_tracker then
	        tick_tracker:on_update(local_player)
	    end

    -- File logging toggle (syncs checkbox state â†’ log_capture)
    do
        local want_file = menu_elements.rotation_file_logging_enabled
            and menu_elements.rotation_file_logging_enabled:get_state() == true
        if want_file ~= last_file_log_state then
            last_file_log_state = want_file
            log_capture:set_enabled(want_file, { prefix = "priest_tbc" })
        end
    end

    -- Execute rotation logic (pass tick tracker for mana optimization)
    -- Route to Shadow Priest or Healer rotation based on toggle
    local game_now = core.game_time()
    local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
    local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
    if (game_now - last_rotation_tick_ms) >= tick_rate then
        last_rotation_tick_ms = game_now
        if menu_elements.sp_mode_enabled:get_state() then
            shadow_rotation_logic:execute(local_player, menu_elements, tick_tracker)
        else
            rotation_logic:execute(local_player, menu_elements, tick_tracker)
        end
    end

    -- Automation (lowest priority)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)

    auto_consumables:on_update(local_player, menu_elements)
end

-- ============================================================================
-- RENDER LOOP (UI Drawing)
-- ============================================================================

function priest:on_render()
    -- Render Custom ESP UI Window
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
