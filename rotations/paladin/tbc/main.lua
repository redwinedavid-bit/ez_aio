-- ============================================================================
-- Paladin Unified Rotation Module (AIO-compatible)
-- World of Warcraft TBC Classic
-- ============================================================================

local paladin = {
    allow_while_mounted = true
}

local rotation_logic = require("rotations/paladin/tbc/rotation_logic")
local spells = require("rotations/paladin/tbc/spells")
local dispel_whitelist = require("rotations/paladin/shared/dispel_whitelist")
pcall(function()
    core.log("[Paladin TBC] Rotation module loaded.")
end)

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

local log_capture = require("shared/log_capture")

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

    enable_script_check = md.checkbox(true, "paladin_enable_script"),
    enable_toggle = md.keybind(999, true, "paladin_enable_toggle"),
    cooldowns_toggle = md.keybind(999, true, "paladin_cooldowns_toggle"),
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
    prefer_seal_blood = md.keybind(999, false, "paladin_prefer_seal_blood"),
    prefer_seal_vengeance = md.keybind(999, false, "paladin_prefer_seal_vengeance"),

    -- Ret DPS: Seal Twisting (SoC -> SoB/SoM)
    seal_twist_toggle = md.keybind(999, false, "paladin_seal_twist_toggle"),
    seal_twist_window_ms = md.slider_int(150, 700, 400, "paladin_seal_twist_window_ms"),
    seal_twist_min_mana_pct = md.slider_int(0, 100, 20, "paladin_seal_twist_min_mana_pct"),
    seal_twist_debug = md.checkbox(false, "paladin_seal_twist_debug"),

    allow_melee_for_healer = md.checkbox(false, "paladin_allow_melee_for_healer"),

    -- Holy: Tank target selection (for "Tank" settings)
    tank_target_mode = md.combobox(1, "paladin_tank_target_mode"), -- 1=Auto(Role), 2=Focus, 3=Name List
    tank_name_list = md.text_input("paladin_tank_name_list", false),

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
    ally_holy_light_enable = md.checkbox(false, "paladin_ally_holy_light_enable"),
    ally_holy_light_at_hp = md.slider_int(1, 99, 35, "paladin_ally_holy_light_at_hp"),
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

    -- Cooldowns (TBC)
    use_cooldowns = md.checkbox(true, "paladin_use_cooldowns"),
    use_cds_on = md.combobox(2, "paladin_use_cds_on"), -- 1=Boss, 2=Elite+, 3=Always
    cooldowns_min_ttd = md.slider_int(0, 60, 12, "paladin_cooldowns_min_ttd"),
    use_avenging_wrath = md.checkbox(true, "paladin_use_avenging_wrath"),
    use_crusader_strike = md.checkbox(true, "paladin_use_crusader_strike"),
    use_tbc_ret_seals = md.checkbox(true, "paladin_use_tbc_ret_seals"),
    use_avengers_shield = md.checkbox(true, "paladin_use_avengers_shield"),
	    use_arcane_torrent = md.checkbox(true, "paladin_use_arcane_torrent"),
	    arcane_torrent_mana_pct = md.slider_int(0, 100, 25, "paladin_arcane_torrent_mana_pct"),
	    use_arcane_torrent_interrupt = md.checkbox(false, "paladin_use_arcane_torrent_interrupt"),
	    arcane_torrent_interrupt_pct = md.slider_int(0, 100, 25, "paladin_arcane_torrent_interrupt_pct"),
	    use_racials = md.checkbox(true, "paladin_use_racials"),
	    racials_sync_with_cds = md.checkbox(true, "paladin_racials_sync_with_cds"),
	    use_stoneform = md.checkbox(true, "paladin_use_stoneform"),
    stoneform_hp_pct = md.slider_int(0, 100, 35, "paladin_stoneform_hp_pct"),
    use_gift_of_the_naaru = md.checkbox(true, "paladin_use_gift_of_the_naaru"),
    gift_of_the_naaru_hp_pct = md.slider_int(0, 100, 40, "paladin_gift_of_the_naaru_hp_pct"),
    use_perception = md.checkbox(true, "paladin_use_perception"),
    use_divine_illumination = md.checkbox(true, "paladin_use_divine_illumination"),
    divine_illumination_mana_pct = md.slider_int(0, 100, 35, "paladin_divine_illumination_mana_pct"),
    use_holy_wrath = md.checkbox(true, "paladin_use_holy_wrath"),
    use_exorcism = md.checkbox(true, "paladin_use_exorcism"),
    use_righteous_defense = md.checkbox(true, "paladin_use_righteous_defense"),

    -- Raid / Judgement policy (TBC)
    raid_mode = md.checkbox(false, "paladin_raid_mode"),
    judgement_assignment = md.combobox(1, "paladin_judgement_assignment"), -- 1=Auto,2=None,3=Wisdom,4=Crusader,5=Light
    judgement_only_if_missing = md.checkbox(true, "paladin_judgement_only_if_missing"),
    judgement_refresh_under_sec = md.slider_int(0, 30, 4, "paladin_judgement_refresh_under_sec"),
    judgement_allow_seal_swap = md.checkbox(false, "paladin_judgement_allow_seal_swap"),
    judgement_skip_if_other_active = md.checkbox(false, "paladin_judgement_skip_if_other_active"),

    -- On-use items (TBC)
    use_trinkets = md.checkbox(true, "paladin_use_trinkets"),
    trinkets_sync_with_cds = md.checkbox(true, "paladin_trinkets_sync_with_cds"),
    trinkets_min_ttd = md.slider_int(0, 60, 12, "paladin_trinkets_min_ttd"),
    use_trinkets_in_heal = md.checkbox(false, "paladin_use_trinkets_in_heal"),
    trinkets_heal_mana_pct = md.slider_int(0, 100, 20, "paladin_trinkets_heal_mana_pct"),

    use_drums = md.checkbox(true, "paladin_use_drums"),
    drums_type = md.combobox(1, "paladin_drums_type"), -- 1=Battle,2=War,3=Restoration,4=Panic
    drums_sync_with_cds = md.checkbox(true, "paladin_drums_sync_with_cds"),
    drums_min_ttd = md.slider_int(0, 60, 12, "paladin_drums_min_ttd"),
    drums_mana_pct = md.slider_int(0, 100, 30, "paladin_drums_mana_pct"),

    use_engineering_explosives = md.checkbox(false, "paladin_use_engineering_explosives"),
    engineering_explosives_min_enemies = md.slider_int(1, 10, 3, "paladin_engineering_explosives_min_enemies"),
    engineering_explosives_min_ttd = md.slider_int(0, 60, 10, "paladin_engineering_explosives_min_ttd"),

    -- Self-heal safety: skip casts when you're being focused by too many enemies.
    self_flash_of_light_max_targeters = md.slider_int(0, 10, 2, "paladin_self_flash_of_light_max_targeters"),
    self_holy_light_max_targeters = md.slider_int(0, 10, 1, "paladin_self_holy_light_max_targeters"),

    -- Blessings
    preferred_self_blessing = md.combobox(1, "paladin_preferred_self_blessing"), -- 1=Auto, 2=Might, 3=Wisdom, 4=Kings, 5=Salvation, 6=Sanctuary, 7=Light, 8=User Selected
    auto_blessings = md.checkbox(true, "paladin_auto_blessings"),
    auto_auras = md.checkbox(true, "paladin_auto_auras"),
    auto_crusader_aura = md.checkbox(true, "paladin_auto_crusader_aura"),
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
    consecration_downrank_threshold = md.slider_int(0, 100, 50, "paladin_consecration_downrank_threshold"),
    use_holy_shield = md.checkbox(true, "paladin_use_holy_shield"),
    holy_shield_min_mana = md.slider_int(0, 100, 10, "paladin_holy_shield_min_mana"),
    enable_holy_shield_downrank = md.checkbox(true, "paladin_enable_holy_shield_downrank"),
    holy_shield_downrank_threshold = md.slider_int(0, 100, 50, "paladin_holy_shield_downrank_threshold"),
    judgement_min_mana = md.slider_int(0, 100, 12, "paladin_judgement_min_mana"),
    judgement_min_mana_save = md.slider_int(0, 100, 6, "paladin_judgement_min_mana_save"),
    enable_jotc_opener = md.checkbox(true, "paladin_enable_jotc_opener"),
    jotc_min_ttd = md.slider_int(0, 60, 18, "paladin_jotc_min_ttd"),

    use_hp_potions = md.checkbox(true, "paladin_use_hp_potions"),
    hp_potion_at = md.slider_int(10, 60, 35, "paladin_hp_potion_at"),
    use_healthstones = md.checkbox(true, "paladin_use_healthstones"),
    healthstone_hp_pct = md.slider_int(0, 100, 35, "paladin_healthstone_hp_pct"),

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

    -- Auto Consumables
    auto_consumables_enabled = md.checkbox(true, "paladin_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "paladin_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 40, "paladin_auto_drink_pct"),

    paladin_detailed_log_enabled = md.checkbox(false, "paladin_detailed_log_enabled"),
    paladin_log_to_file = md.checkbox(false, "paladin_log_to_file"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = md.checkbox(false, "paladin_tbc_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "paladin_tbc_pvp_rotation_tick_rate"),
}

local last_file_log_state = false

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

    local cooldowns = keybind_toggle_active(menu_elements.cooldowns_toggle)
    if cooldowns == nil then cooldowns = true end

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
        crusader = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_crusader) == true) or false,
        blood = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_blood) == true) or false,
        vengeance = seal_selection_enabled and (plugin_helper:is_toggle_enabled(menu_elements.prefer_seal_vengeance) == true) or false
    }

    local seal_twist = keybind_toggle_active(menu_elements.seal_twist_toggle) == true
    local seal_twist_window_ms = (menu_elements.seal_twist_window_ms and menu_elements.seal_twist_window_ms.get and menu_elements.seal_twist_window_ms:get()) or 400
    local seal_twist_min_mana_pct = (menu_elements.seal_twist_min_mana_pct and menu_elements.seal_twist_min_mana_pct.get and menu_elements.seal_twist_min_mana_pct:get()) or 20
    local seal_twist_debug = (menu_elements.seal_twist_debug and menu_elements.seal_twist_debug.get_state and menu_elements.seal_twist_debug:get_state() == true) or false

    return {
        tank_mode = tank_mode,
        heal_mode = heal_mode,
        safe_mode = safe_mode,
        mana_save = mana_save,
        pvp_mode = pvp_mode,
        dispel = dispel,
        cooldowns = cooldowns,
        aoe_mode = aoe_mode_override,
        seal_selection = seal_selection,
        seal_twist = seal_twist,
        seal_twist_window_ms = seal_twist_window_ms,
        seal_twist_min_mana_pct = seal_twist_min_mana_pct,
        seal_twist_debug = seal_twist_debug
    }
end

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "paladin_rotation",
    title = "Paladin BxA (AIO) - TBC",
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
                options = { "Auto", "Might", "Wisdom", "Kings", "Salvation", "Sanctuary", "Light", "User Selected" }
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
            menu_elements.cooldowns_toggle,
            menu_elements.tank_mode_toggle,
            menu_elements.heal_mode_toggle,
            menu_elements.safe_mode_toggle,
            menu_elements.mana_save_toggle,
            menu_elements.pvp_mode_toggle,
            menu_elements.aoe_toggle
        },
        labels = {
            "Enable Rotation",
            "Cooldowns",
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
            { element = menu_elements.paladin_detailed_log_enabled, label = "Enable Detailed Logs" },
            { element = menu_elements.paladin_log_to_file, label = "Save Logs to File" },
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" }
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            { element = menu_elements.pvp_rotation_tick_rate, label = "PvP Rotation Frequency", suffix = "ms", bounds = { min = 30, max = 100 } }
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
                menu_elements.prefer_seal_crusader,
                menu_elements.prefer_seal_blood,
                menu_elements.prefer_seal_vengeance
            },
            labels = {
                "Prefer Seal: Righteousness",
                "Prefer Seal: Command",
                "Prefer Seal: Wisdom",
                "Prefer Seal: Light",
                "Prefer Seal: Justice",
                "Prefer Seal: Crusader (JoTC Swap)",
                "Prefer Seal: Blood/Martyr",
                "Prefer Seal: Vengeance"
            }
        })
    end

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns" }, function(tab)
	    tab:checkbox_grid({
	        label = "TBC Cooldowns",
	        columns = 2,
	        elements = {
	            { element = menu_elements.use_cooldowns, label = "Use Cooldowns" },
	            { element = menu_elements.use_avenging_wrath, label = "Avenging Wrath" },
	            { element = menu_elements.use_arcane_torrent, label = "Arcane Torrent (Blood Elf)" },
	            { element = menu_elements.use_arcane_torrent_interrupt, label = "Arcane Torrent Interrupt (Blood Elf)" },
	            { element = menu_elements.use_divine_illumination, label = "Divine Illumination (Holy)" },
	        }
	    })

    tab:checkbox_grid({
        label = "On-use Items",
        columns = 2,
        elements = {
            { element = menu_elements.use_trinkets, label = "Use Trinkets (On-use)" },
            { element = menu_elements.trinkets_sync_with_cds, label = "Trinkets: Sync with Cooldowns" },
            { element = menu_elements.use_drums, label = "Use Drums" },
            { element = menu_elements.drums_sync_with_cds, label = "Drums: Sync with Cooldowns" },
            { element = menu_elements.use_trinkets_in_heal, label = "Trinkets in Heal Mode" },
            { element = menu_elements.use_engineering_explosives, label = "Engineering Explosives" },
        }
    })

    tab:checkbox_grid({
        label = "Racials",
        columns = 2,
        elements = {
            { element = menu_elements.use_racials, label = "Use Racials" },
            { element = menu_elements.racials_sync_with_cds, label = "Sync with Cooldowns" },
            { element = menu_elements.use_stoneform, label = "Stoneform (Dwarf)" },
            { element = menu_elements.use_gift_of_the_naaru, label = "Gift of the Naaru (Draenei)" },
            { element = menu_elements.use_perception, label = "Perception (Human, PvP)" },
        }
    })

    tab:combo_list({
        label = "When to Use",
        elements = {
            {
                element = menu_elements.use_cds_on,
                label = "Use CDs On",
                options = { "Boss Only", "Elite+", "Always" },
                visible_when = function() return menu_elements.use_cooldowns:get_state() end
            }
        }
    })

	    tab:slider_list({
	        label = "TTD / Mana",
	        elements = {
	            { element = menu_elements.cooldowns_min_ttd, label = "Cooldowns Min TTD", suffix = "s", bounds = { min = 0, max = 60 } },
	            { element = menu_elements.trinkets_min_ttd, label = "Trinkets Min TTD", suffix = "s", bounds = { min = 0, max = 60 } },
	            { element = menu_elements.drums_min_ttd, label = "Drums Min TTD", suffix = "s", bounds = { min = 0, max = 60 } },
	            { element = menu_elements.arcane_torrent_mana_pct, label = "Arcane Torrent at Mana%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.arcane_torrent_interrupt_pct, label = "Arcane Torrent Interrupt at Cast%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.divine_illumination_mana_pct, label = "Divine Illumination at Mana%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.trinkets_heal_mana_pct, label = "Heal Trinkets at Mana%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.drums_mana_pct, label = "Drums (Restoration) at Mana%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.stoneform_hp_pct, label = "Stoneform at HP%", suffix = "%", bounds = { min = 0, max = 100 } },
	            { element = menu_elements.gift_of_the_naaru_hp_pct, label = "Gift of the Naaru at HP%", suffix = "%", bounds = { min = 0, max = 100 } },
	        }
	    })

    tab:combo_list({
        label = "Drums",
        elements = {
            {
                element = menu_elements.drums_type,
                label = "Drums Type",
                options = { "Battle (Haste)", "War (AP)", "Restoration (Mana)", "Panic (Fear)" },
                visible_when = function() return menu_elements.use_drums:get_state() end
            }
        }
    })

    tab:slider_list({
        label = "Engineering",
        elements = {
            { element = menu_elements.engineering_explosives_min_enemies, label = "Explosives min enemies", suffix = "", bounds = { min = 1, max = 10 } },
            { element = menu_elements.engineering_explosives_min_ttd, label = "Explosives Min TTD", suffix = "s", bounds = { min = 0, max = 60 } },
        }
    })
end)

settings_ui:add_tab({ id = "raid", label = "Raid" }, function(tab)
    tab:checkbox_grid({
        label = "Raid Safety",
        columns = 2,
        elements = {
            { element = menu_elements.raid_mode, label = "Raid Mode" },
            { element = menu_elements.judgement_only_if_missing, label = "Judgement: Only If Missing" },
            { element = menu_elements.judgement_allow_seal_swap, label = "Judgement: Allow Seal Swap" },
            { element = menu_elements.judgement_skip_if_other_active, label = "Judgement: Skip if Other Active" },
        }
    })

    tab:slider_list({
        label = "Judgement Refresh",
        elements = {
            { element = menu_elements.judgement_refresh_under_sec, label = "Refresh under", suffix = "s", bounds = { min = 0, max = 30 } },
        }
    })

    tab:combo_list({
        label = "Judgement Assignment",
        elements = {
            {
                element = menu_elements.judgement_assignment,
                label = "Judgement",
                options = { "Auto", "None", "Wisdom (JoW)", "Crusader (JoC)", "Light (JoL)" },
            }
        }
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
            { element = menu_elements.ally_holy_light_at_hp, label = "Ally Holy Light at HP% (non-tank)", suffix = "%", bounds = { min = 1, max = 99 } },
            { element = menu_elements.holy_shock_at_hp, label = "Holy Shock at HP%", suffix = "%", bounds = { min = 1, max = 80 } },
            { element = menu_elements.min_mana_for_dispel, label = "Min Mana% for Dispel", suffix = "%", bounds = { min = 0, max = 100 } }
        },
        page = "healing"
    })

    tab:checkbox_grid({
        label = "Holy Light (Allies)",
        columns = 1,
        elements = {
            { element = menu_elements.ally_holy_light_enable, label = "Enable Holy Light on non-tank allies" },
        },
        page = "healing"
    })

    tab:combo_list({
        label = "Tank Target Source",
        elements = {
            {
                element = menu_elements.tank_target_mode,
                label = "Tank Target",
                options = { "Auto (Role)", "Focus", "Name List" },
                tooltip = "Controls which unit Holy 'Tank' settings will target.\nAuto uses party role first."
            }
        },
        page = "healing"
    })

    tab:text_input_list({
        label = "Tank Name List",
        visible_when = function()
            return menu_elements.tank_target_mode and menu_elements.tank_target_mode.get and menu_elements.tank_target_mode:get() == 3
        end,
        elements = {
            {
                element = menu_elements.tank_name_list,
                label = "Names",
                tooltip = "Example: Schmeltz\nTip: You can paste multiple names separated by commas, semicolons, or newlines."
            }
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
            { element = menu_elements.enable_jotc_opener, label = "Use JoTC swap (Crusader selected)" },
            { element = menu_elements.use_holy_shield, label = "Use Holy Shield" },
            { element = menu_elements.use_consecration, label = "Use Consecration" },
            { element = menu_elements.use_avengers_shield, label = "Use Avenger's Shield (TBC)" },
            { element = menu_elements.use_holy_wrath, label = "Use Holy Wrath (Undead/Demon)" },
            { element = menu_elements.use_exorcism, label = "Use Exorcism (Undead/Demon)" },
            { element = menu_elements.use_righteous_defense, label = "Use Righteous Defense (TBC)" },
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
            { element = menu_elements.enable_consecration_downrank, label = "Enable Consecration Downranking (R1)" },
            { element = menu_elements.consecration_downrank_threshold, label = "Downrank Consec when mana <=", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.consecration_min_enemies, label = "Consecration min enemies", suffix = "", bounds = { min = 1, max = 10 } }
        },
        page = "tank"
    })

    tab:checkbox_grid({
        label = "DPS Options",
        columns = 2,
        elements = {
            { element = menu_elements.enable_jotc_opener, label = "Use JoTC swap (Crusader selected)" },
            { element = menu_elements.use_consecration, label = "Use Consecration" },
            { element = menu_elements.use_crusader_strike, label = "Use Crusader Strike (TBC)" },
            { element = menu_elements.use_tbc_ret_seals, label = "Prefer Seal of Blood/Martyr/Vengeance (TBC)" },
            { element = menu_elements.seal_twist_debug, label = "Seal Twisting: Debug logs" },
            { element = menu_elements.use_holy_wrath, label = "Use Holy Wrath (Undead/Demon)" },
            { element = menu_elements.use_exorcism, label = "Use Exorcism (Undead/Demon)" },
        },
        page = "dps"
    })

    tab:slider_list({
        label = "Seal Twisting (Ret)",
        elements = {
            { element = menu_elements.seal_twist_window_ms, label = "Twist window (ms)", suffix = "ms", bounds = { min = 150, max = 700 } },
            { element = menu_elements.seal_twist_min_mana_pct, label = "Disable twisting below mana%", suffix = "%", bounds = { min = 0, max = 100 } },
        },
        page = "dps"
    })

    tab:slider_list({
        label = "DPS Mana Controls",
        elements = {
            { element = menu_elements.judgement_min_mana, label = "Judgement min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.judgement_min_mana_save, label = "Judgement (Mana Save) min mana%", suffix = "%", bounds = { min = 0, max = 100 } },
            { element = menu_elements.jotc_min_ttd, label = "JoTC min TTD (sec)", suffix = "s", bounds = { min = 0, max = 60 } }
        },
        page = "dps"
    })

    tab:checkbox_grid({
        label = "Blessings",
        columns = 2,
        elements = {
            { element = menu_elements.auto_blessings, label = "Auto Blessings" },
            { element = menu_elements.auto_auras, label = "Auto Auras" },
            { element = menu_elements.auto_crusader_aura, label = "Crusader Aura (Mounted)" },
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
            { element = menu_elements.use_hp_potions, label = "Use Health Potions" },
            { element = menu_elements.use_healthstones, label = "Use Healthstones" }
        }
    })

    tab:slider_list({
        label = "Health Potions",
        elements = {
            { element = menu_elements.hp_potion_at, label = "Use at HP%", suffix = "%", bounds = { min = 10, max = 60 } }
        }
    })

    tab:slider_list({
        label = "Healthstones",
        elements = {
            { element = menu_elements.healthstone_hp_pct, label = "Use at HP%", suffix = "%", bounds = { min = 0, max = 100 } }
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
            { element = menu_elements.auto_food_pct, label = "Food Threshold %", suffix = "%", bounds = { min = 0, max = 100 }, visible_when = function() return menu_elements.auto_consumables_enabled:get_state() end },
            { element = menu_elements.auto_drink_pct, label = "Drink Threshold %", suffix = "%", bounds = { min = 0, max = 100 }, visible_when = function() return menu_elements.auto_consumables_enabled:get_state() end },
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
local last_rotation_tick_ms = 0

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

    do
        local want_file = menu_elements.paladin_detailed_log_enabled:get_state() == true
            and menu_elements.paladin_log_to_file:get_state() == true
        if want_file ~= last_file_log_state then
            last_file_log_state = want_file
            log_capture:set_enabled(want_file, { prefix = "paladin_tbc" })
        end
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
        if menu_elements.auto_crusader_aura:get_state()
            and spells.crusader_aura:is_learned()
            and not local_player:buff_up(32223)
            and spells.crusader_aura:is_castable({ skip_facing = true })
        then
            spells.crusader_aura:cast(local_player)
        end
        return
    end

	    local tick_tracker = resource_ticks.get()
	    if tick_tracker then
	        tick_tracker:on_update(local_player)
	    end

    local game_now = core.game_time()
    local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
    local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
    if (game_now - last_rotation_tick_ms) >= tick_rate then
        last_rotation_tick_ms = game_now
        rotation_logic:execute(local_player, menu_elements, tick_tracker, resolve_mode_state())
    end

    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
    auto_skinning:on_update(local_player, menu_elements)

    auto_consumables:on_update(local_player, menu_elements)
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
        menu_elements.cooldowns_toggle:render("Cooldowns Toggle (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")")
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
        name = "Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Dispel (" .. key_helper:get_key_name(menu_elements.dispel_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.dispel_toggle
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
        name = "Auto AoE (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Seal Twisting (" .. key_helper:get_key_name(menu_elements.seal_twist_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.seal_twist_toggle
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
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Blood/Martyr (" .. key_helper:get_key_name(menu_elements.prefer_seal_blood:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_blood
        })
        control_panel_helper:insert_toggle(control_panel_elements, {
            name = "Prefer Seal: Vengeance (" .. key_helper:get_key_name(menu_elements.prefer_seal_vengeance:get_key_code()) .. ") ",
            keybind = menu_elements.prefer_seal_vengeance
        })
    end

    return control_panel_elements
end

return paladin
