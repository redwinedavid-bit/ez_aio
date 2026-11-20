-- <--astro_file-->
-- Warrior rotation module (AIO-compatible)
-- WoW Classic TBC focused, with Tank Mode override.

local warrior = {}

local rotation_logic = require("rotations/warrior/tbc/rotation_logic")

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

---@type auto_consumables
local auto_consumables = require("shared/auto_consumables")

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type shield_swap_helper
local shield_swap_helper = require("rotations/warrior/tbc/shield_swap_helper")

---@type color
local color = require("common/color")

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

local function menu_slider_float(min_value, max_value, default_value, id)
    if core.menu.slider_float then
        return core.menu.slider_float(min_value, max_value, default_value, id)
    end
    return core.menu.slider_int(math.floor(min_value), math.ceil(max_value), math.floor(default_value + 0.5), id)
end

local function checkbox_enabled(element)
    if not element then
        return false
    end
    local getter = element.get_state or element.get
    if not getter then
        return false
    end
    local ok, state = pcall(function()
        return getter(element)
    end)
    if not ok then
        return false
    end
    return state == true or state == 1
end

local function normalize_checkbox_state_value(value)
    if value == 1 then
        return true
    end
    if value == 0 then
        return false
    end
    return value
end

local patched_checkbox_elements = setmetatable({}, { __mode = "k" })

local function patch_checkbox_element(element)
    local element_type = type(element)
    if element_type ~= "table" and element_type ~= "userdata" then
        return
    end

    if patched_checkbox_elements[element] == true then
        return
    end

    local has_checkbox_state = type(element.get_state) == "function"
    if not has_checkbox_state then
        return
    end

    local original_get_state = element.get_state
    local ok_patch_get_state = pcall(function()
        element.get_state = function(self, ...)
            local ok, value = pcall(original_get_state, self, ...)
            if not ok then
                return original_get_state(self, ...)
            end
            return normalize_checkbox_state_value(value)
        end
    end)
    if not ok_patch_get_state then
        return
    end

    if type(element.get) == "function" then
        local original_get = element.get
        pcall(function()
            element.get = function(self, ...)
                local ok, value = pcall(original_get, self, ...)
                if not ok then
                    return original_get(self, ...)
                end
                return normalize_checkbox_state_value(value)
            end
        end)
    end

    patched_checkbox_elements[element] = true
end

local function patch_checkbox_state_accessors(tbl)
    if type(tbl) ~= "table" then
        return
    end

    for _, element in pairs(tbl) do
        patch_checkbox_element(element)
    end
end

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = core.menu.tree_node(),
    rotation_tree = core.menu.tree_node(),
    cooldowns_tree = core.menu.tree_node(),
    advanced_tree = core.menu.tree_node(),
    tank_tree = core.menu.tree_node(),
    interrupts_tree = core.menu.tree_node(),
    stance_tree = core.menu.tree_node(),
    shield_swap_tree = core.menu.tree_node(),
    defensives_tree = core.menu.tree_node(),
    automation_tree = core.menu.tree_node(),

    enable_toggle = core.menu.keybind(999, true, "warrior_enable_toggle"),
    ui_toggle_hotkey = core.menu.keybind(112, false, "warrior_ui_toggle_hotkey"),
    cooldowns_toggle = core.menu.keybind(999, true, "warrior_cooldowns_toggle"),
    tank_mode_toggle = core.menu.keybind(999, false, "warrior_tank_mode_toggle"),
    ooc_charge_toggle = core.menu.keybind(999, false, "warrior_ooc_charge_toggle"),
    intimidating_shout_toggle = core.menu.keybind(999, true, "warrior_intimidating_shout_toggle"),

    -- PvP
    enable_pvp_mode = core.menu.checkbox(false, "warrior_tbc_enable_pvp_mode"),
    pvp_rotation_tick_rate = core.menu.slider_int(30, 100, 30, "warrior_tbc_pvp_rotation_tick_rate"),
    pvp_auto_overpower_dance = core.menu.checkbox(true, "warrior_tbc_pvp_auto_overpower_dance"),
    pvp_disarm_shield_swap = core.menu.checkbox(true, "warrior_tbc_pvp_disarm_shield_swap"),
    pvp_priority_ms = core.menu.checkbox(true, "warrior_tbc_pvp_priority_ms"),
    pvp_smart_intercept = core.menu.checkbox(true, "warrior_tbc_pvp_smart_intercept"),
    pvp_auto_piercing_howl = core.menu.checkbox(true, "warrior_tbc_pvp_auto_piercing_howl"),

    -- Rotation (default: leveling/dungeon)
    content_profile = core.menu.combobox(1, "warrior_content_profile"), -- 1=Open World, 2=Dungeon, 3=Raid
    auto_battle_stance = core.menu.checkbox(true, "warrior_auto_battle_stance"),
    auto_berserker_stance_fury = core.menu.checkbox(true, "warrior_auto_berserker_stance_fury"),
    auto_defensive_stance_prot_dps = core.menu.checkbox(true, "warrior_auto_defensive_stance_prot_dps"),
    allow_stance_dance_for_whirlwind_arms = core.menu.checkbox(true, "warrior_allow_stance_dance_for_whirlwind_arms"),
    allow_stance_dance_for_sweeping_strikes = core.menu.checkbox(false, "warrior_allow_stance_dance_for_sweeping_strikes"),
    keep_battle_shout = core.menu.checkbox(true, "warrior_keep_battle_shout"),
    shout_mode = core.menu.combobox(1, "warrior_shout_mode"), -- 1=Battle, 2=Commanding, 3=Auto
    use_bloodrage = core.menu.checkbox(true, "warrior_use_bloodrage"),
    bloodrage_rage_below = core.menu.slider_int(0, 60, 10, "warrior_bloodrage_rage_below"),
    bloodrage_min_hp_pct = core.menu.slider_int(0, 100, 65, "warrior_bloodrage_min_hp_pct"),

    use_rend = core.menu.checkbox(true, "warrior_use_rend"),
    rend_min_ttd = menu_slider_float(0, 25, 6, "warrior_rend_min_ttd"),
    use_overpower = core.menu.checkbox(true, "warrior_use_overpower"),
    use_mortal_strike = core.menu.checkbox(true, "warrior_use_mortal_strike"),
    use_slam_arms = core.menu.checkbox(true, "warrior_use_slam_arms"),
    slam_min_rage = core.menu.slider_int(0, 100, 25, "warrior_slam_min_rage"),
    slam_assumed_cast_ms = core.menu.slider_int(200, 1500, 550, "warrior_slam_assumed_cast_ms"),
    slam_swing_buffer_ms = core.menu.slider_int(0, 300, 120, "warrior_slam_swing_buffer_ms"),
    slam_post_swing_window_ms = core.menu.slider_int(0, 1200, 400, "warrior_slam_post_swing_window_ms"),
    use_bloodthirst = core.menu.checkbox(true, "warrior_use_bloodthirst"),
    use_rampage = core.menu.checkbox(true, "warrior_use_rampage"),

    enable_aoe = core.menu.checkbox(true, "warrior_enable_aoe"),
    aoe_min_enemies = core.menu.slider_int(2, 6, 2, "warrior_aoe_min_enemies"),
    use_sweeping_strikes = core.menu.checkbox(true, "warrior_use_sweeping_strikes"),
    use_whirlwind = core.menu.checkbox(true, "warrior_use_whirlwind"),

    use_execute = core.menu.checkbox(true, "warrior_use_execute"),
    execute_hp_pct = core.menu.slider_int(0, 35, 20, "warrior_execute_hp_pct"),

    use_demoralizing_shout = core.menu.checkbox(true, "warrior_use_demoralizing_shout"),
    use_devastate = core.menu.checkbox(true, "warrior_use_devastate"),

    auto_hamstring_on_target_loss = core.menu.checkbox(false, "warrior_auto_hamstring_on_target_loss"),
    auto_hamstring_mode = core.menu.combobox(1, "warrior_auto_hamstring_mode"),
    auto_hamstring_on_target_loss_range = menu_slider_float(4, 12, 8, "warrior_auto_hamstring_on_target_loss_range"),
    auto_hamstring_on_target_loss_throttle = core.menu.slider_int(200, 2000, 1200, "warrior_auto_hamstring_on_target_loss_throttle"),
    auto_hamstring_on_humanoid_lowhp = core.menu.checkbox(false, "warrior_auto_hamstring_on_humanoid_lowhp"),
    auto_hamstring_on_humanoid_hp_pct = core.menu.slider_int(0, 40, 20, "warrior_auto_hamstring_on_humanoid_hp_pct"),
    auto_hamstring_on_humanoid_range = menu_slider_float(3, 10, 5, "warrior_auto_hamstring_on_humanoid_range"),

    -- Optional: Sunder Armor in leveling rotation (off by default; useful for elites/dungeons).
    use_sunder_leveling = core.menu.checkbox(false, "warrior_use_sunder_leveling"),
    sunder_leveling_only_elite_or_boss = core.menu.checkbox(true, "warrior_sunder_leveling_only_elite_or_boss"),
    sunder_leveling_only_in_party = core.menu.checkbox(false, "warrior_sunder_leveling_only_in_party"),
    sunder_leveling_engaged_only = core.menu.checkbox(true, "warrior_sunder_leveling_engaged_only"),
    sunder_leveling_min_ttd = menu_slider_float(0, 60, 10, "warrior_sunder_leveling_min_ttd"),
    sunder_leveling_stacks = core.menu.slider_int(0, 5, 2, "warrior_sunder_leveling_stacks"),
    sunder_leveling_min_rage = core.menu.slider_int(0, 100, 15, "warrior_sunder_leveling_min_rage"),

    -- Rage dump
    use_heroic_strike = core.menu.checkbox(true, "warrior_use_heroic_strike"),
    use_cleave = core.menu.checkbox(true, "warrior_use_cleave"),
    rage_dump_threshold = core.menu.slider_int(0, 100, 55, "warrior_rage_dump_threshold"),
    rage_dump_prevent_cap = core.menu.checkbox(true, "warrior_rage_dump_prevent_cap"),
    rage_dump_estimated_rage_per_hit = core.menu.slider_int(5, 50, 20, "warrior_rage_dump_estimated_rage_per_hit"),

    execute_pool_enabled = core.menu.checkbox(false, "warrior_execute_pool_enabled"),
    execute_pool_start_hp_pct = core.menu.slider_int(0, 60, 30, "warrior_execute_pool_start_hp_pct"),
    execute_pool_min_rage = core.menu.slider_int(0, 100, 60, "warrior_execute_pool_min_rage"),
    execute_pool_skip_mortal_strike = core.menu.checkbox(true, "warrior_execute_pool_skip_mortal_strike"),
    execute_pool_skip_aoe = core.menu.checkbox(true, "warrior_execute_pool_skip_aoe"),

    -- Interrupts
    auto_interrupt = core.menu.checkbox(true, "warrior_auto_interrupt"),
    interrupt_target_mode = core.menu.combobox(2, "warrior_interrupt_target_mode"), -- 1=Current, 2=Auto (smart)
    interrupt_delay_min_pct = core.menu.slider_int(0, 100, 10, "warrior_interrupt_delay_min_pct"),
    interrupt_delay_max_pct = core.menu.slider_int(0, 100, 35, "warrior_interrupt_delay_max_pct"),
    interrupt_range = core.menu.slider_int(5, 20, 10, "warrior_interrupt_range"),
    interrupt_fast_cast_ms = core.menu.slider_int(0, 1200, 450, "warrior_interrupt_fast_cast_ms"),
    interrupt_engaged_only = core.menu.checkbox(true, "warrior_interrupt_engaged_only"),
    use_pummel = core.menu.checkbox(true, "warrior_use_pummel"),
    use_shield_bash = core.menu.checkbox(true, "warrior_use_shield_bash"),
    use_concussion_blow_interrupt = core.menu.checkbox(false, "warrior_use_concussion_blow_interrupt"),
    allow_stance_dance_for_pummel = core.menu.checkbox(true, "warrior_allow_stance_dance_for_pummel"),
    allow_stance_dance_for_pummel_in_tank_mode = core.menu.checkbox(false, "warrior_allow_stance_dance_for_pummel_in_tank_mode"),

    -- Stance Dance / Tactical Mastery (rage keep)
    stance_dance_auto_detect_rage_kept = core.menu.checkbox(true, "warrior_stance_dance_auto_detect_rage_kept"),
    stance_dance_rage_kept_fallback = core.menu.slider_int(0, 25, 5, "warrior_stance_dance_rage_kept_fallback"),
    stance_dance_return_delay_ms = core.menu.slider_int(200, 2000, 900, "warrior_stance_dance_return_delay_ms"),
    stance_dance_return_timeout_ms = core.menu.slider_int(800, 6000, 2500, "warrior_stance_dance_return_timeout_ms"),
    interrupt_stance_dance_max_rage_waste = core.menu.slider_int(0, 100, 5, "warrior_interrupt_stance_dance_max_rage_waste"),
    tank_stance_dance_max_rage_waste = core.menu.slider_int(0, 100, 5, "warrior_tank_stance_dance_max_rage_waste"),

    -- Shield Weapon Swapping (Dynamic 2H â†” 1H+Shield for Shield Abilities)
    enable_shield_weapon_swap = core.menu.checkbox(true, "warrior_enable_shield_weapon_swap"),
    shield_swap_mode = core.menu.combobox(1, "warrior_shield_swap_mode_id"),  -- 1=Auto, 2=Manual
    shield_swap_manual_shield_id = core.menu.text_input("warrior_shield_swap_manual_shield_id", true),
    shield_swap_manual_weapon_id = core.menu.text_input("warrior_shield_swap_manual_weapon_id", true),
    shield_swap_delay_ms = core.menu.slider_int(1000, 3000, 1500, "warrior_shield_swap_delay_ms"),
    shield_swap_back_delay_ms = core.menu.slider_int(100, 1000, 300, "warrior_shield_swap_back_delay_ms"),
    shield_swap_fallback_timeout_ms = core.menu.slider_int(3000, 10000, 5000, "warrior_shield_swap_fallback_timeout_ms"),
    shield_swap_require_onehand = core.menu.checkbox(false, "warrior_shield_swap_require_onehand"),
    shield_swap_verbose_logging = core.menu.checkbox(false, "warrior_shield_swap_verbose_logging"),
    debug_focus_shield_slam = core.menu.checkbox(false, "warrior_debug_focus_shield_slam"),

    -- Tank Mode (active when keybind toggle ON)
    tank_auto_defensive_stance = core.menu.checkbox(true, "warrior_tank_auto_defensive_stance"),
    tank_auto_taunt = core.menu.checkbox(true, "warrior_tank_auto_taunt"),
    tank_use_thunder_clap = core.menu.checkbox(true, "warrior_tank_use_thunder_clap"),
    tank_thunder_clap_min_enemies = core.menu.slider_int(1, 6, 2, "warrior_tank_thunder_clap_min_enemies"),
    tank_allow_stance_dance_for_thunder_clap = core.menu.checkbox(false, "warrior_tank_allow_stance_dance_for_thunder_clap"),
    tank_use_shield_block = core.menu.checkbox(true, "warrior_tank_use_shield_block"),
    tank_shield_block_min_rage = core.menu.slider_int(0, 100, 20, "warrior_tank_shield_block_min_rage"),
    tank_use_revenge = core.menu.checkbox(true, "warrior_tank_use_revenge"),
    tank_use_shield_slam = core.menu.checkbox(true, "warrior_tank_use_shield_slam"),
    tank_use_sunder = core.menu.checkbox(false, "warrior_tank_use_sunder"),
    tank_sunder_stacks = core.menu.slider_int(0, 5, 5, "warrior_tank_sunder_stacks"),
    tank_tab_sunder_enabled = core.menu.checkbox(false, "warrior_tank_tab_sunder_enabled"),
    tank_tab_sunder_engaged_only = core.menu.checkbox(true, "warrior_tank_tab_sunder_engaged_only"),
    tank_tab_sunder_min_enemies = core.menu.slider_int(2, 6, 2, "warrior_tank_tab_sunder_min_enemies"),
    tank_tab_sunder_max_targets = core.menu.slider_int(1, 10, 4, "warrior_tank_tab_sunder_max_targets"),
    tank_tab_sunder_stacks = core.menu.slider_int(0, 5, 2, "warrior_tank_tab_sunder_stacks"),
    tank_tab_sunder_range = core.menu.slider_int(5, 20, 10, "warrior_tank_tab_sunder_range"),
    tank_use_demoralizing_shout = core.menu.checkbox(true, "warrior_tank_use_demoralizing_shout"),
    tank_use_devastate = core.menu.checkbox(true, "warrior_tank_use_devastate"),
    tank_use_mocking_blow = core.menu.checkbox(true, "warrior_tank_use_mocking_blow"),
    tank_allow_stance_dance_for_mocking_blow = core.menu.checkbox(false, "warrior_tank_allow_stance_dance_for_mocking_blow"),
    tank_mocking_blow_min_rage = core.menu.slider_int(0, 100, 20, "warrior_tank_mocking_blow_min_rage"),
    tank_use_intervene = core.menu.checkbox(false, "warrior_tank_use_intervene"),
    tank_intervene_hp_pct = core.menu.slider_int(0, 100, 35, "warrior_tank_intervene_hp_pct"),
    tank_intervene_throttle_ms = core.menu.slider_int(300, 5000, 1200, "warrior_tank_intervene_throttle_ms"),

    tank_use_challenging_shout = core.menu.checkbox(false, "warrior_tank_use_challenging_shout"),
    tank_use_concussion_blow = core.menu.checkbox(false, "warrior_tank_use_concussion_blow"),
    tank_use_spell_reflection = core.menu.checkbox(false, "warrior_tank_use_spell_reflection"),
    tank_use_berserker_rage_fear_break = core.menu.checkbox(true, "warrior_tank_use_berserker_rage_fear_break"),
    tank_use_disarm = core.menu.checkbox(false, "warrior_tank_use_disarm"),
    tank_disarm_players_only = core.menu.checkbox(false, "warrior_tank_disarm_players_only"),
    tank_disarm_melee_classes_only = core.menu.checkbox(false, "warrior_tank_disarm_melee_classes_only"),
    tank_cleave_rage_threshold = core.menu.slider_int(0, 100, 30, "warrior_tank_cleave_rage_threshold"),

    -- Defensives (Hardcore)
    use_hp_potions = core.menu.checkbox(true, "warrior_use_hp_potions"),
    hp_potion_hp_pct = core.menu.slider_int(0, 100, 35, "warrior_hp_potion_hp_pct"),
    use_healthstones = core.menu.checkbox(true, "warrior_use_healthstones"),
    healthstone_hp_pct = core.menu.slider_int(0, 100, 35, "warrior_healthstone_hp_pct"),
    emergency_defensive_stance = core.menu.checkbox(true, "warrior_emergency_defensive_stance"),
    defensive_stance_hp_pct = core.menu.slider_int(0, 100, 35, "warrior_defensive_stance_hp_pct"),
    use_last_stand = core.menu.checkbox(true, "warrior_use_last_stand"),
    last_stand_hp_pct = core.menu.slider_int(0, 100, 25, "warrior_last_stand_hp_pct"),
	use_shield_wall = core.menu.checkbox(true, "warrior_use_shield_wall"),
	shield_wall_hp_pct = core.menu.slider_int(0, 100, 18, "warrior_shield_wall_hp_pct"),
	retaliation_hp_pct = core.menu.slider_int(0, 100, 55, "warrior_retaliation_hp_pct"),
	use_intimidating_shout = core.menu.checkbox(true, "warrior_use_intimidating_shout"),
	intimidating_shout_hp_pct = core.menu.slider_int(0, 100, 20, "warrior_intimidating_shout_hp_pct"),

    -- Cooldowns (TBC)
    use_cooldowns = md.checkbox(true, "warrior_use_cooldowns"),
    use_cds_on = md.combobox(1, "warrior_use_cds_on"), -- 1=Boss, 2=Elite+, 3=Always
    cooldowns_min_ttd = md.slider_float(0, 60, 12.0, "warrior_cooldowns_min_ttd"),
    use_death_wish = md.checkbox(true, "warrior_use_death_wish"),
    use_recklessness = md.checkbox(false, "warrior_use_recklessness"),
    use_racials = md.checkbox(true, "warrior_use_racials"),
    racials_sync_with_cds = md.checkbox(true, "warrior_racials_sync_with_cds"),
    racials_min_ttd = md.slider_float(0, 60, 12.0, "warrior_racials_min_ttd"),
    arcane_torrent_rage_below = md.slider_int(0, 100, 25, "warrior_arcane_torrent_rage_below"),

    -- Automation (optional utilities)
    auto_loot_enabled = core.menu.checkbox(true, "warrior_auto_loot_enabled"),
    auto_loot_mode = core.menu.combobox(1, "warrior_auto_loot_mode"),
    auto_loot_max_attempts = core.menu.slider_int(1, 10, 1, "warrior_auto_loot_max_attempts"),
    auto_loot_retry_delay = core.menu.slider_int(30, 200, 60, "warrior_auto_loot_retry_delay"),
    auto_mine_enabled = core.menu.checkbox(true, "warrior_auto_mine_enabled"),
    auto_mine_range = core.menu.slider_int(2, 8, 5, "warrior_auto_mine_range"),
    auto_herb_enabled = core.menu.checkbox(true, "warrior_auto_herb_enabled"),
    auto_herb_range = core.menu.slider_int(2, 8, 5, "warrior_auto_herb_range"),
    auto_quest_interact_enabled = core.menu.checkbox(false, "warrior_auto_quest_interact_enabled"),
    auto_quest_interact_range = core.menu.slider_int(2, 8, 4, "warrior_auto_quest_interact_range"),
    auto_skin_enabled = core.menu.checkbox(false, "warrior_auto_skin_enabled"),
    auto_skin_range = core.menu.slider_int(2, 8, 5, "warrior_auto_skin_range"),

    -- Auto Food
    auto_consumables_enabled = core.menu.checkbox(true, "warrior_auto_consumables_enabled"),
    auto_food_pct = core.menu.slider_int(0, 100, 50, "warrior_auto_food_pct"),
}

patch_checkbox_state_accessors(menu_elements)

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "warrior_rotation",
    title = "Warrior Rotation Settings (TBC)",
    default_x = 700,
    default_y = 200,
    default_w = 520,
    default_h = 650,
    theme = "warrior"
})

if settings_ui and settings_ui.menu then
    patch_checkbox_state_accessors(settings_ui.menu)
end

local function slider_entry(element, label, suffix, min_value, max_value, visible_when)
    if type(min_value) == "function" and max_value == nil and visible_when == nil then
        visible_when = min_value
        min_value = nil
    end

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

local function tank_mode_enabled()
    return plugin_helper:is_toggle_enabled(menu_elements.tank_mode_toggle)
end

settings_ui:add_tab({ id = "core_controls", label = "Core" }, function(tab)
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
            menu_elements.ooc_charge_toggle,
            menu_elements.intimidating_shout_toggle
        },
        labels = {
            "Enable Rotation",
            "Cooldowns",
            "Tank Mode",
            "OOC Charge",
            "Intimidating Shout"
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
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })

    tab:checkbox_grid({
        label = "Arms PvP Optimizations",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_auto_overpower_dance, label = "Auto Overpower Dance" },
            { element = menu_elements.pvp_disarm_shield_swap, label = "Shield Swap on Disarm" },
            { element = menu_elements.pvp_priority_ms, label = "Mortal Strike Priority" },
            { element = menu_elements.pvp_smart_intercept, label = "Smart Intercept" },
            { element = menu_elements.pvp_auto_piercing_howl, label = "Auto Piercing Howl" },
        }
    })
end)

settings_ui:add_tab({ id = "rotation", label = "Rotation" }, function(tab)
    tab:combo_list({
        label = "Profiles",
        elements = {
            { element = menu_elements.content_profile, label = "Content", options = { "Open World", "Dungeon", "Raid" } },
        }
    })

    tab:checkbox_grid({
        label = "Basics",
        columns = 2,
        elements = {
            { element = menu_elements.auto_battle_stance, label = "Auto Battle Stance" },
            { element = menu_elements.auto_berserker_stance_fury, label = "Auto Berserker (Fury)" },
            { element = menu_elements.auto_defensive_stance_prot_dps, label = "Auto Defensive (Prot DPS)" },
            { element = menu_elements.allow_stance_dance_for_whirlwind_arms, label = "Stance Dance Whirlwind (Arms)" },
            { element = menu_elements.allow_stance_dance_for_sweeping_strikes, label = "Stance Dance Sweeping Strikes" },
            { element = menu_elements.keep_battle_shout, label = "Keep Battle Shout" },
            { element = menu_elements.use_bloodrage, label = "Use Bloodrage" },
        }
    })

    tab:combo_list({
        label = "Shout",
        elements = {
            {
                element = menu_elements.shout_mode,
                label = "Mode",
                options = { "Battle Shout", "Commanding Shout", "Auto" },
                visible_when = function() return menu_elements.keep_battle_shout:get_state() end
            }
        }
    })

    tab:slider_list({
        label = "Bloodrage",
        elements = {
            slider_entry(menu_elements.bloodrage_rage_below, "Bloodrage when Rage <=", "", function() return menu_elements.use_bloodrage:get_state() end),
            slider_entry(menu_elements.bloodrage_min_hp_pct, "Bloodrage Min HP%", "%", function() return menu_elements.use_bloodrage:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Single Target",
        columns = 2,
        elements = {
            { element = menu_elements.use_rend, label = "Use Rend" },
            { element = menu_elements.use_overpower, label = "Use Overpower" },
            { element = menu_elements.use_mortal_strike, label = "Use Mortal Strike (if learned)" },
            { element = menu_elements.use_slam_arms, label = "Use Slam (Arms, swing-safe)" },
            { element = menu_elements.use_bloodthirst, label = "Use Bloodthirst (Fury)" },
            { element = menu_elements.use_rampage, label = "Use Rampage (Fury)" },
            { element = menu_elements.use_execute, label = "Use Execute" },
            { element = menu_elements.use_demoralizing_shout, label = "Use Demoralizing Shout" },
            { element = menu_elements.use_sunder_leveling, label = "Use Sunder Armor (optional)" }
        }
    })

    tab:slider_list({
        label = "Single Target Thresholds",
        elements = {
            slider_entry(menu_elements.rend_min_ttd, "Rend Min TTD", "s", function() return menu_elements.use_rend:get_state() end),
            slider_entry(menu_elements.execute_hp_pct, "Execute HP%", "%", function() return menu_elements.use_execute:get_state() end),
            slider_entry(menu_elements.slam_min_rage, "Slam Min Rage", "", function() return menu_elements.use_slam_arms:get_state() end),
            slider_entry(menu_elements.slam_assumed_cast_ms, "Slam Assumed Cast", "ms", function() return menu_elements.use_slam_arms:get_state() end),
            slider_entry(menu_elements.slam_swing_buffer_ms, "Slam Swing Buffer", "ms", function() return menu_elements.use_slam_arms:get_state() end),
            slider_entry(menu_elements.slam_post_swing_window_ms, "Slam Post-Swing Window", "ms", function() return menu_elements.use_slam_arms:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Sunder Armor (Leveling)",
        columns = 2,
        elements = {
            { element = menu_elements.sunder_leveling_only_elite_or_boss, label = "Only Elite/Boss", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
            { element = menu_elements.sunder_leveling_only_in_party, label = "Only In Party", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
            { element = menu_elements.sunder_leveling_engaged_only, label = "Engaged Only", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
        }
    })

    tab:slider_list({
        label = "Sunder Armor (Leveling) Thresholds",
        elements = {
            slider_entry(menu_elements.sunder_leveling_min_ttd, "Min TTD", "s", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
            slider_entry(menu_elements.sunder_leveling_stacks, "Stacks", "", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
            slider_entry(menu_elements.sunder_leveling_min_rage, "Min Rage", "", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
        }
    })

    tab:checkbox_grid({
        label = "Advanced: Execute Pooling",
        columns = 2,
        elements = {
            { element = menu_elements.execute_pool_enabled, label = "Enable Execute Pooling" },
            { element = menu_elements.execute_pool_skip_mortal_strike, label = "Skip Mortal Strike while pooling", visible_when = function()
                return menu_elements.execute_pool_enabled:get_state()
            end },
            { element = menu_elements.execute_pool_skip_aoe, label = "Skip AoE while pooling", visible_when = function()
                return menu_elements.execute_pool_enabled:get_state()
            end },
        }
    })

    tab:slider_list({
        label = "Execute Pooling",
        elements = {
            slider_entry(menu_elements.execute_pool_start_hp_pct, "Start Pooling at HP%", "%", function()
                return menu_elements.execute_pool_enabled:get_state()
            end),
            slider_entry(menu_elements.execute_pool_min_rage, "Execute Min Rage", "", function()
                return menu_elements.execute_pool_enabled:get_state()
            end),
        }
    })

    tab:checkbox_grid({
        label = "AoE",
        columns = 2,
        elements = {
            { element = menu_elements.enable_aoe, label = "Enable AoE" },
            { element = menu_elements.use_sweeping_strikes, label = "Use Sweeping Strikes (Battle/Berserker, if learned)" },
            { element = menu_elements.use_whirlwind, label = "Use Whirlwind (if learned)" }
        }
    })

    tab:slider_list({
        label = "AoE Thresholds",
        elements = {
            slider_entry(menu_elements.aoe_min_enemies, "AoE Min Enemies", "", function() return menu_elements.enable_aoe:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Target Loss",
        columns = 2,
        elements = {
            { element = menu_elements.auto_hamstring_on_target_loss, label = "Hamstring on Target Loss" },
        }
    })

    tab:combo_list({
        label = "Hamstring Mode",
        elements = {
            {
                element = menu_elements.auto_hamstring_mode,
                label = "Mode",
                options = { "Target Loss Only", "Any Enemy in Range" },
                visible_when = function() return menu_elements.auto_hamstring_on_target_loss:get_state() end
            }
        }
    })

    tab:slider_list({
        label = "Target Loss Settings",
        elements = {
            slider_entry(menu_elements.auto_hamstring_on_target_loss_range, "Trigger Range", "y", function() return menu_elements.auto_hamstring_on_target_loss:get_state() end),
            slider_entry(menu_elements.auto_hamstring_on_target_loss_throttle, "Throttle", "ms", function() return menu_elements.auto_hamstring_on_target_loss:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Humanoids",
        columns = 2,
        elements = {
            { element = menu_elements.auto_hamstring_on_humanoid_lowhp, label = "Hamstring Humanoids < HP" },
        }
    })

    tab:slider_list({
        label = "Humanoid Settings",
        elements = {
            slider_entry(menu_elements.auto_hamstring_on_humanoid_hp_pct, "HP Threshold", "%", function() return menu_elements.auto_hamstring_on_humanoid_lowhp:get_state() end),
            slider_entry(menu_elements.auto_hamstring_on_humanoid_range, "Trigger Range", "y", function() return menu_elements.auto_hamstring_on_humanoid_lowhp:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Rage Dump",
        columns = 2,
        elements = {
            { element = menu_elements.use_heroic_strike, label = "Use Heroic Strike" },
            { element = menu_elements.use_cleave, label = "Use Cleave (AoE)" },
            { element = menu_elements.rage_dump_prevent_cap, label = "Prevent Rage Cap" },
        }
    })

    tab:slider_list({
        label = "Rage Dump Thresholds",
        elements = {
            slider_entry(menu_elements.rage_dump_threshold, "Rage Dump Threshold", "", nil),
            slider_entry(menu_elements.rage_dump_estimated_rage_per_hit, "Est. Rage/Hit", "", function() return menu_elements.rage_dump_prevent_cap:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Sunder Armor (Leveling)",
        columns = 2,
        elements = {
            { element = menu_elements.sunder_leveling_only_elite_or_boss, label = "Only Elite/Boss", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
            { element = menu_elements.sunder_leveling_only_in_party, label = "Only In Party", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
            { element = menu_elements.sunder_leveling_engaged_only, label = "Engaged Only", visible_when = function()
                return menu_elements.use_sunder_leveling:get_state()
            end },
        }
    })

    tab:slider_list({
        label = "Sunder Armor (Leveling) Thresholds",
        elements = {
            slider_entry(menu_elements.sunder_leveling_min_ttd, "Min TTD", "s", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
            slider_entry(menu_elements.sunder_leveling_stacks, "Stacks", "", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
            slider_entry(menu_elements.sunder_leveling_min_rage, "Min Rage", "", function()
                return menu_elements.use_sunder_leveling:get_state()
            end),
        }
    })

    tab:checkbox_grid({
        label = "Advanced: Execute Pooling",
        columns = 2,
        elements = {
            { element = menu_elements.execute_pool_enabled, label = "Enable Execute Pooling" },
            { element = menu_elements.execute_pool_skip_mortal_strike, label = "Skip Mortal Strike while pooling", visible_when = function()
                return menu_elements.execute_pool_enabled:get_state()
            end },
            { element = menu_elements.execute_pool_skip_aoe, label = "Skip AoE while pooling", visible_when = function()
                return menu_elements.execute_pool_enabled:get_state()
            end },
        }
    })

    tab:slider_list({
        label = "Execute Pooling",
        elements = {
            slider_entry(menu_elements.execute_pool_start_hp_pct, "Start Pooling at HP%", "%", function()
                return menu_elements.execute_pool_enabled:get_state()
            end),
            slider_entry(menu_elements.execute_pool_min_rage, "Execute Min Rage", "", function()
                return menu_elements.execute_pool_enabled:get_state()
            end),
        }
    })

    tab:checkbox_grid({
        label = "AoE",
        columns = 2,
        elements = {
            { element = menu_elements.enable_aoe, label = "Enable AoE" },
            { element = menu_elements.use_sweeping_strikes, label = "Use Sweeping Strikes (Battle/Berserker, if learned)" },
            { element = menu_elements.use_whirlwind, label = "Use Whirlwind (if learned)" }
        }
    })

    tab:slider_list({
        label = "AoE Thresholds",
        elements = {
            slider_entry(menu_elements.aoe_min_enemies, "AoE Min Enemies", "", function() return menu_elements.enable_aoe:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Target Loss",
        columns = 2,
        elements = {
            { element = menu_elements.auto_hamstring_on_target_loss, label = "Hamstring on Target Loss" },
        }
    })

    tab:combo_list({
        label = "Hamstring Mode",
        elements = {
            {
                element = menu_elements.auto_hamstring_mode,
                label = "Mode",
                options = { "Target Loss Only", "Any Enemy in Range" },
                visible_when = function() return menu_elements.auto_hamstring_on_target_loss:get_state() end
            }
        }
    })

    tab:slider_list({
        label = "Target Loss Settings",
        elements = {
            slider_entry(menu_elements.auto_hamstring_on_target_loss_range, "Trigger Range", "y", function() return menu_elements.auto_hamstring_on_target_loss:get_state() end),
            slider_entry(menu_elements.auto_hamstring_on_target_loss_throttle, "Throttle", "ms", function() return menu_elements.auto_hamstring_on_target_loss:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Humanoids",
        columns = 2,
        elements = {
            { element = menu_elements.auto_hamstring_on_humanoid_lowhp, label = "Hamstring Humanoids < HP" },
        }
    })

    tab:slider_list({
        label = "Humanoid Settings",
        elements = {
            slider_entry(menu_elements.auto_hamstring_on_humanoid_hp_pct, "HP Threshold", "%", function() return menu_elements.auto_hamstring_on_humanoid_lowhp:get_state() end),
            slider_entry(menu_elements.auto_hamstring_on_humanoid_range, "Trigger Range", "y", function() return menu_elements.auto_hamstring_on_humanoid_lowhp:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Rage Dump",
        columns = 2,
        elements = {
            { element = menu_elements.use_heroic_strike, label = "Use Heroic Strike" },
            { element = menu_elements.use_cleave, label = "Use Cleave (AoE)" },
        }
    })

    tab:slider_list({
        label = "Rage Dump Thresholds",
        elements = {
            slider_entry(menu_elements.rage_dump_threshold, "Rage Dump Threshold", "", nil),
        }
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns" }, function(tab)
    tab:checkbox_grid({
        label = "Cooldown Usage",
        columns = 2,
        elements = {
            { element = menu_elements.use_cooldowns, label = "Use Cooldowns" },
            { element = menu_elements.use_death_wish, label = "Death Wish" },
            { element = menu_elements.use_recklessness, label = "Recklessness" },
            { element = menu_elements.use_racials, label = "Use Racials" },
            { element = menu_elements.racials_sync_with_cds, label = "Sync Racials with CDs" },
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
            },
        }
    })

    tab:slider_list({
        label = "TTD Thresholds",
        elements = {
            slider_entry(menu_elements.cooldowns_min_ttd, "Cooldowns Min TTD", "s", function() return menu_elements.use_cooldowns:get_state() end),
            slider_entry(menu_elements.racials_min_ttd, "Racials Min TTD", "s", function() return menu_elements.use_racials:get_state() end),
        }
    })

    tab:slider_list({
        label = "Racial Utility",
        elements = {
            slider_entry(menu_elements.arcane_torrent_rage_below, "Arcane Torrent when Rage <=", "", function() return menu_elements.use_racials:get_state() end),
        }
    })
end)

settings_ui:add_tab({ id = "interrupts", label = "Interrupts" }, function(tab)
    tab:checkbox_grid({
        label = "Auto Interrupt",
        columns = 2,
        elements = {
            { element = menu_elements.auto_interrupt, label = "Enable Auto Interrupt" },
            { element = menu_elements.interrupt_engaged_only, label = "Engaged Only" },
        }
    })

    tab:combo_list({
        label = "Targeting",
        elements = {
            {
                element = menu_elements.interrupt_target_mode,
                label = "Target Mode",
                options = { "Current Target", "Automatic (smart)" }
            }
        }
    })

    tab:slider_list({
        label = "Timing / Range",
        elements = {
            slider_entry(menu_elements.interrupt_range, "Range", "y", nil),
            slider_entry(menu_elements.interrupt_delay_min_pct, "Delay Min", "%", nil),
            slider_entry(menu_elements.interrupt_delay_max_pct, "Delay Max", "%", nil),
            slider_entry(menu_elements.interrupt_fast_cast_ms, "Fast Cast", "ms", nil)
        }
    })

    tab:checkbox_grid({
        label = "Methods",
        columns = 2,
        elements = {
            { element = menu_elements.use_shield_bash, label = "Use Shield Bash" },
            { element = menu_elements.use_pummel, label = "Use Pummel" },
            { element = menu_elements.use_concussion_blow_interrupt, label = "Use Concussion Blow (stun interrupt)" },
            { element = menu_elements.allow_stance_dance_for_pummel, label = "Allow Stance Dance for Pummel" },
            { element = menu_elements.allow_stance_dance_for_pummel_in_tank_mode, label = "Allow Stance Dance in Tank Mode" },
        }
    })
end)

settings_ui:add_tab({ id = "stance_dance", label = "Stance" }, function(tab)
    tab:checkbox_grid({
        label = "Tactical Mastery (Rage Kept)",
        columns = 2,
        elements = {
            { element = menu_elements.stance_dance_auto_detect_rage_kept, label = "Auto-detect Rage Kept" },
        }
    })

    tab:slider_list({
        label = "Rage Keep / Returns",
        elements = {
            slider_entry(menu_elements.stance_dance_rage_kept_fallback, "Rage Kept Fallback (0-25)", "", function()
                return menu_elements.stance_dance_auto_detect_rage_kept:get_state() ~= true
            end),
            slider_entry(menu_elements.stance_dance_return_delay_ms, "Return Delay (Fallback)", "ms", nil),
            slider_entry(menu_elements.stance_dance_return_timeout_ms, "Return Timeout (Safety)", "ms", nil),
        }
    })

    tab:slider_list({
        label = "Rage Waste Limits",
        elements = {
            slider_entry(menu_elements.interrupt_stance_dance_max_rage_waste, "Interrupt Max Rage Waste", "", nil),
            slider_entry(menu_elements.tank_stance_dance_max_rage_waste, "Tank Max Rage Waste", "", nil),
        }
    })
end)

settings_ui:add_tab({ id = "tank", label = "Tank" }, function(tab)
    tab:checkbox_grid({
        label = "Tank Rotation (active when Tank Mode ON)",
        columns = 2,
        elements = {
            { element = menu_elements.tank_auto_defensive_stance, label = "Auto Defensive Stance" },
            { element = menu_elements.tank_auto_taunt, label = "Auto Taunt" },
            { element = menu_elements.tank_use_thunder_clap, label = "Use Thunder Clap (AoE)" },
            { element = menu_elements.tank_allow_stance_dance_for_thunder_clap, label = "Allow Stance Dance for Thunder Clap" },
            { element = menu_elements.tank_use_shield_block, label = "Use Shield Block" },
            { element = menu_elements.tank_use_revenge, label = "Use Revenge" },
            { element = menu_elements.tank_use_shield_slam, label = "Use Shield Slam (if learned)" },
            { element = menu_elements.tank_use_sunder, label = "Apply Sunder (fallback if no Devastate)" },
            { element = menu_elements.tank_tab_sunder_enabled, label = "Tab-Sunder (fallback, multi-target, no Devastate)" },
            { element = menu_elements.tank_use_demoralizing_shout, label = "Apply Demo Shout (missing)" },
            { element = menu_elements.tank_use_mocking_blow, label = "Use Mocking Blow (Taunt backup)" },
            { element = menu_elements.tank_allow_stance_dance_for_mocking_blow, label = "Allow Stance Dance for Mocking Blow" },
            { element = menu_elements.tank_use_intervene, label = "Use Intervene (peel/utility)" },
        }
    })

    tab:checkbox_grid({
        label = "Tank Utility / CC",
        columns = 2,
        elements = {
            { element = menu_elements.tank_use_challenging_shout, label = "Use Challenging Shout (AoE taunt emergency)" },
            { element = menu_elements.tank_use_concussion_blow, label = "Use Concussion Blow (stun/interrupt)" },
            { element = menu_elements.tank_use_spell_reflection, label = "Use Spell Reflection (when cast targets you)" },
            { element = menu_elements.tank_use_berserker_rage_fear_break, label = "Use Berserker Rage (fear break)" },
            { element = menu_elements.tank_use_disarm, label = "Use Disarm (utility)" },
            { element = menu_elements.debug_focus_shield_slam, label = "Debug Focus: Shield Slam" },
        }
    })

    tab:checkbox_grid({
        label = "Disarm Filters",
        columns = 2,
        visible_when = function()
            return menu_elements.tank_use_disarm:get_state() == true
        end,
        elements = {
            { element = menu_elements.tank_disarm_players_only, label = "Players Only" },
            { element = menu_elements.tank_disarm_melee_classes_only, label = "Melee Classes Only (players)" },
        }
    })

    tab:slider_list({
        label = "Tank Tuning",
        elements = {
            slider_entry(menu_elements.tank_thunder_clap_min_enemies, "Thunder Clap Min Enemies", "", function() return menu_elements.tank_use_thunder_clap:get_state() end),
            slider_entry(menu_elements.tank_shield_block_min_rage, "Shield Block Min Rage", "", function() return menu_elements.tank_use_shield_block:get_state() end),
            slider_entry(menu_elements.tank_sunder_stacks, "Sunder Stacks", "", function() return menu_elements.tank_use_sunder:get_state() end),
            slider_entry(menu_elements.tank_tab_sunder_min_enemies, "Tab-Sunder Min Enemies", "", function() return menu_elements.tank_tab_sunder_enabled:get_state() end),
            slider_entry(menu_elements.tank_tab_sunder_max_targets, "Tab-Sunder Max Targets", "", function() return menu_elements.tank_tab_sunder_enabled:get_state() end),
            slider_entry(menu_elements.tank_tab_sunder_stacks, "Tab-Sunder Stacks", "", function() return menu_elements.tank_tab_sunder_enabled:get_state() end),
            slider_entry(menu_elements.tank_tab_sunder_range, "Tab-Sunder Range", "y", function() return menu_elements.tank_tab_sunder_enabled:get_state() end),
            slider_entry(menu_elements.tank_mocking_blow_min_rage, "Mocking Blow Min Rage", "", function() return menu_elements.tank_use_mocking_blow:get_state() end),
            slider_entry(menu_elements.tank_intervene_hp_pct, "Intervene Target HP%", "%", function() return menu_elements.tank_use_intervene:get_state() end),
            slider_entry(menu_elements.tank_intervene_throttle_ms, "Intervene Throttle", "ms", function() return menu_elements.tank_use_intervene:get_state() end),
            slider_entry(menu_elements.tank_cleave_rage_threshold, "Cleave/HS Rage Threshold", "", nil),
        }
    })

    tab:checkbox_grid({
        label = "Tab-Sunder Safety",
        columns = 2,
        visible_when = function()
            return menu_elements.tank_tab_sunder_enabled:get_state()
        end,
        elements = {
            { element = menu_elements.tank_tab_sunder_engaged_only, label = "Engaged Only" }
        }
    })
end)

settings_ui:add_tab({ id = "defensives", label = "Defensives" }, function(tab)
	    tab:checkbox_grid({
	        label = "Hardcore",
	        columns = 2,
	        elements = {
	            { element = menu_elements.use_hp_potions, label = "Use Health Potions" },
	            { element = menu_elements.use_healthstones, label = "Use Healthstones" },
	            { element = menu_elements.emergency_defensive_stance, label = "Emergency Defensive Stance" },
	            { element = menu_elements.use_last_stand, label = "Use Last Stand (if learned)" },
	            { element = menu_elements.use_shield_wall, label = "Use Shield Wall (if learned)" },
	            { element = menu_elements.use_intimidating_shout, label = "Use Intimidating Shout (if learned)" },
	        }
	    })

	    tab:slider_list({
	        label = "Thresholds",
	        elements = {
	            slider_entry(menu_elements.hp_potion_hp_pct, "Potion HP%", "%", function() return menu_elements.use_hp_potions:get_state() end),
	            slider_entry(menu_elements.healthstone_hp_pct, "Healthstone HP%", "%", function() return menu_elements.use_healthstones:get_state() end),
	            slider_entry(menu_elements.defensive_stance_hp_pct, "Defensive Stance at HP%", "%", function() return menu_elements.emergency_defensive_stance:get_state() end),
	            slider_entry(menu_elements.last_stand_hp_pct, "Last Stand at HP%", "%", function() return menu_elements.use_last_stand:get_state() end),
	            slider_entry(menu_elements.shield_wall_hp_pct, "Shield Wall at HP%", "%", function() return menu_elements.use_shield_wall:get_state() end),
	            slider_entry(menu_elements.intimidating_shout_hp_pct, "Intimidating Shout at HP%", "%", function() return menu_elements.use_intimidating_shout:get_state() end),
	            slider_entry(menu_elements.retaliation_hp_pct, "Retaliation at HP%", "%", nil),
	        }
	    })
end)

settings_ui:add_tab({ id = "shield_swap", label = "Shield Swap" }, function(tab)
    -- Enable Toggle
    tab:checkbox_grid({
        label = "Weapon Swapping",
        columns = 2,
        elements = {
            { element = menu_elements.enable_shield_weapon_swap, label = "Enable Shield Swap" },
            { element = menu_elements.shield_swap_verbose_logging, label = "Verbose Logging (Debug)" },
        }
    })

    tab:separator()

    -- Mode Selector
    if tab.combo_list then
        tab:combo_list({
            label = "Shield Swap Mode",
            elements = {
                {
                    element = menu_elements.shield_swap_mode,
                    label = "Mode",
                    options = { "Auto Detection", "Manual ID Input" }
                }
            }
        })
    end

    tab:separator()

    local function is_auto_mode()
        return menu_elements.shield_swap_mode and menu_elements.shield_swap_mode:get() == 1
    end

    local function is_manual_mode()
        return menu_elements.shield_swap_mode and menu_elements.shield_swap_mode:get() == 2
    end

    tab:button({
        label = "Refresh Shield List",
        visible_when = function()
            return is_auto_mode()
        end,
        on_click = function()
            local player = core.object_manager.get_local_player()
            if not player then
                return
            end
            if menu_elements.shield_swap_verbose_logging and menu_elements.shield_swap_verbose_logging.get_state then
                shield_swap_helper:set_verbose_logging(menu_elements.shield_swap_verbose_logging:get_state() == true)
            end
            shield_swap_helper:force_rescan()
            shield_swap_helper:scan_inventory(player, true)
            core.log("[Shield Swap] Refresh clicked. Found=" .. tostring(#(shield_swap_helper:get_found_shields() or {})))
        end
    })

    tab:text({
        visible_when = function()
            return is_auto_mode()
        end,
        text = function()
            local player = core.object_manager.get_local_player()
            if not player then
                return "Player not available."
            end

            if menu_elements.shield_swap_verbose_logging and menu_elements.shield_swap_verbose_logging.get_state then
                shield_swap_helper:set_verbose_logging(menu_elements.shield_swap_verbose_logging:get_state() == true)
            end

            pcall(function()
                shield_swap_helper:scan_inventory(player, false)
            end)

            local cache_info = shield_swap_helper:get_cache_info()
            local found_shields = shield_swap_helper:get_found_shields()
            local found_onehands = nil
            pcall(function()
                if shield_swap_helper.get_found_onehand_weapons then
                    found_onehands = shield_swap_helper:get_found_onehand_weapons()
                end
            end)

            local current_setup = nil
            pcall(function()
                current_setup = shield_swap_helper:detect_current_equipment(player)
            end)

            local lines = {}
            local count = (found_shields and #found_shields) or 0
            local onehand_count = (found_onehands and #found_onehands) or 0
            if count == 0 then
                return string.format("No shields found in bags. (Found %d 1H weapon(s).)", onehand_count)
            end

            if current_setup and current_setup.has_shield_equipped then
                table.insert(lines, string.format("Equipped shield: %d", current_setup.shield_id or 0))
            end

            if current_setup then
                table.insert(lines, string.format("Equipped: MH=%d (2H=%s), OH=%d", current_setup.mainhand_id or 0, tostring(current_setup.is_2h == true), current_setup.offhand_id or 0))
            end

            local selected_onehand = 0
            pcall(function()
                if shield_swap_helper.get_selected_onehand_id then
                    selected_onehand = shield_swap_helper:get_selected_onehand_id() or 0
                end
            end)
            if selected_onehand and selected_onehand > 0 then
                table.insert(lines, string.format("Selected 1H: %d", selected_onehand))
            end

            table.insert(lines, string.format("Found %d shield(s), %d 1H weapon(s).", count, onehand_count))
            table.insert(lines, "Check shields below to prefer; select a 1H below for 2H->shield fallback.")
            return table.concat(lines, "\n")
        end
    })

    tab:separator()

    tab:runtime_checkbox_list({
        label = "Shields (check to prefer)",
        visible_when = function()
            return is_auto_mode()
        end,
        elements = function()
            local player = core.object_manager.get_local_player()
            if not player then
                return {}
            end

            if menu_elements.shield_swap_verbose_logging and menu_elements.shield_swap_verbose_logging.get_state then
                shield_swap_helper:set_verbose_logging(menu_elements.shield_swap_verbose_logging:get_state() == true)
            end

            pcall(function()
                shield_swap_helper:scan_inventory(player, false)
            end)

            local found = shield_swap_helper:get_found_shields() or {}
            local items = {}
            for _, shield in ipairs(found) do
                if shield and shield.id then
                    local label = string.format("%s (ID: %d)", tostring(shield.name), shield.id)
                    table.insert(items, {
                        label = label,
                        get_state = function()
                            return shield_swap_helper:is_preferred_shield(shield.id)
                        end,
                        set_state = function(state)
                            shield_swap_helper:set_preferred_shield(shield.id, state == true)
                        end
                    })
                end
            end
            return items
        end
    })

    tab:separator()

    tab:runtime_checkbox_list({
        label = "1H Weapons (check to select)",
        visible_when = function()
            return is_auto_mode()
        end,
        elements = function()
            local player = core.object_manager.get_local_player()
            if not player then
                return {}
            end

            if menu_elements.shield_swap_verbose_logging and menu_elements.shield_swap_verbose_logging.get_state then
                shield_swap_helper:set_verbose_logging(menu_elements.shield_swap_verbose_logging:get_state() == true)
            end

            pcall(function()
                shield_swap_helper:scan_inventory(player, false)
            end)

            if not shield_swap_helper.get_found_onehand_weapons or not shield_swap_helper.get_selected_onehand_id or not shield_swap_helper.set_selected_onehand then
                return {}
            end

            local found = shield_swap_helper:get_found_onehand_weapons() or {}
            local selected_id = shield_swap_helper:get_selected_onehand_id() or 0
            local items = {}
            for _, w in ipairs(found) do
                if w and w.id then
                    local label = string.format("%s (ID: %d)", tostring(w.name), w.id)
                    table.insert(items, {
                        label = label,
                        get_state = function()
                            return selected_id == w.id
                        end,
                        set_state = function(state)
                            if state == true then
                                shield_swap_helper:set_selected_onehand(w.id)
                            else
                                if (shield_swap_helper:get_selected_onehand_id() or 0) == w.id then
                                    shield_swap_helper:set_selected_onehand(0)
                                end
                            end
                        end
                    })
                end
            end
            return items
        end
    })

    tab:text_input_list({
        label = "Manual IDs",
        visible_when = function()
            return is_manual_mode()
        end,
        elements = {
            { element = menu_elements.shield_swap_manual_shield_id, label = "Shield Item ID", tooltip = "Required. Must be in your bags." },
            { element = menu_elements.shield_swap_manual_weapon_id, label = "1H Weapon Item ID", tooltip = "Optional. If set, equips this 1H with your shield." }
        }
    })

    tab:text({
        visible_when = function()
            return is_manual_mode()
        end,
        text = function()
            local shield_id = 0
            if menu_elements.shield_swap_manual_shield_id and menu_elements.shield_swap_manual_shield_id.get_text_as_number then
                shield_id = menu_elements.shield_swap_manual_shield_id:get_text_as_number() or 0
            end

            local weapon_id = 0
            if menu_elements.shield_swap_manual_weapon_id and menu_elements.shield_swap_manual_weapon_id.get_text_as_number then
                weapon_id = menu_elements.shield_swap_manual_weapon_id:get_text_as_number() or 0
            end

            shield_swap_helper:set_manual_equipment(shield_id, weapon_id)

            local lines = {}
            if shield_id <= 0 then
                table.insert(lines, "Shield ID: [NOT SET]")
                table.insert(lines, "Status: Missing required shield item ID")
            else
                local is_valid, message = shield_swap_helper:validate_manual_shield_id(shield_id)
                table.insert(lines, string.format("Shield ID: %d", shield_id))
                table.insert(lines, string.format("Status: %s", is_valid and "Valid" or ("Invalid - " .. tostring(message))))
            end

            if weapon_id > 0 then
                table.insert(lines, string.format("1H Weapon ID: %d", weapon_id))
            else
                table.insert(lines, "1H Weapon ID: [NOT SET]")
            end

            return table.concat(lines, "\n")
        end
    })

    tab:separator()

    -- Timing Settings (same for both modes)
    tab:slider_list({
        label = "Timing (ms)",
        elements = {
            slider_entry(menu_elements.shield_swap_delay_ms, "Ability Cast Delay (GCD)", "ms"),
            slider_entry(menu_elements.shield_swap_back_delay_ms, "Swap Back Buffer", "ms"),
            slider_entry(menu_elements.shield_swap_fallback_timeout_ms, "Safety Timeout", "ms"),
        }
    })

    tab:separator()

    -- System Info (updated for both modes)
    tab:text({
        text = "System Info:\n" ..
               "- Auto Mode: Scans inventory for shields (30s cache OOC)\n" ..
               "- Manual Mode: Uses your entered item IDs directly\n" ..
               "- Both modes: Swaps to shield before abilities, restores after GCD\n" ..
               "\nRequirements:\n" ..
               "- Shield in inventory (auto-detected or manual ID)\n" ..
               "- If you are using a 2H weapon: usually requires a 1H weapon in bags (helper tries shield-only first, then falls back to 1H+shield)"
    })
end)

settings_ui:add_tab({ id = "automation", label = "Automation" }, function(tab)
    tab:checkbox_grid({
        label = "Auto Loot",
        columns = 2,
        elements = {
            { element = menu_elements.auto_loot_enabled, label = "Enable Auto Loot" },
        }
    })

    tab:combo_list({
        label = "Loot",
        elements = {
            {
                element = menu_elements.auto_loot_mode,
                label = "Loot Mode",
                options = { "Out of Combat Only", "In Combat Only", "Always" },
                visible_when = function()
                    return menu_elements.auto_loot_enabled:get_state()
                end
            }
        }
    })

    tab:slider_list({
        label = "Loot Limits",
        elements = {
            slider_entry(menu_elements.auto_loot_max_attempts, "Max Attempts per Corpse", "", function() return menu_elements.auto_loot_enabled:get_state() end),
            slider_entry(menu_elements.auto_loot_retry_delay, "Corpse Lockout", "s", function() return menu_elements.auto_loot_enabled:get_state() end),
        }
    })

    tab:checkbox_grid({
        label = "Gathering / Interact",
        columns = 2,
        elements = {
            { element = menu_elements.auto_mine_enabled, label = "Enable Auto Mining" },
            { element = menu_elements.auto_herb_enabled, label = "Enable Auto Herbs" },
            { element = menu_elements.auto_quest_interact_enabled, label = "Enable Auto Quest Interact", visible_when = function() return auto_quest_interact and auto_quest_interact:is_available() == true end },
            { element = menu_elements.auto_skin_enabled, label = "Enable Auto Skinning", visible_when = function() return auto_skinning and auto_skinning:is_available() == true end },
        }
    })

    tab:slider_list({
        label = "Ranges",
        elements = {
            slider_entry(menu_elements.auto_mine_range, "Mining Range", "y", function() return menu_elements.auto_mine_enabled:get_state() end),
            slider_entry(menu_elements.auto_herb_range, "Herbing Range", "y", function() return menu_elements.auto_herb_enabled:get_state() end),
            slider_entry(menu_elements.auto_quest_interact_range, "Quest Interact Range", "y", function() return menu_elements.auto_quest_interact_enabled:get_state() end),
            slider_entry(menu_elements.auto_skin_range, "Skinning Range", "y", function() return menu_elements.auto_skin_enabled:get_state() end),
        }
    })
end)

-- ============================================================================
-- MENU / UPDATE / RENDER
-- ============================================================================

function warrior:on_menu_render()
    -- Custom UI Window Toggle
    if settings_ui then
        settings_ui:on_menu_render("Show Custom UI Window")
    end

    menu_elements.main_tree:render("Warrior Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        core.menu.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))
        core.menu.header():render("PVP (TBC)", color.new(220, 170, 255, 220))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation (Overlay)")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_rotation_tick_rate:render("PvP Rotation Frequency (ms)")
        end
        menu_elements.rotation_tree:render("Rotation", function()
            menu_elements.content_profile:render("Content Profile", { "Open World", "Dungeon", "Raid" })

            menu_elements.auto_battle_stance:render("Auto Battle Stance")
            menu_elements.auto_berserker_stance_fury:render("Auto Berserker (Fury)")
            menu_elements.auto_defensive_stance_prot_dps:render("Auto Defensive (Prot DPS)")
            menu_elements.allow_stance_dance_for_whirlwind_arms:render("Stance Dance Whirlwind (Arms)")
            menu_elements.allow_stance_dance_for_sweeping_strikes:render("Stance Dance Sweeping Strikes")
            menu_elements.keep_battle_shout:render("Keep Battle Shout")
            if menu_elements.keep_battle_shout:get_state() then
                menu_elements.shout_mode:render("Shout Mode", { "Battle Shout", "Commanding Shout", "Auto" })
            end
            menu_elements.use_bloodrage:render("Use Bloodrage")
            if menu_elements.use_bloodrage:get_state() then
                menu_elements.bloodrage_rage_below:render("Bloodrage when Rage <=")
                menu_elements.bloodrage_min_hp_pct:render("Bloodrage Min HP%")
            end

            menu_elements.use_rend:render("Use Rend")
            if menu_elements.use_rend:get_state() then
                menu_elements.rend_min_ttd:render("Rend Min TTD (seconds)")
            end
            menu_elements.use_overpower:render("Use Overpower")
            menu_elements.use_mortal_strike:render("Use Mortal Strike (if learned)")
            menu_elements.use_slam_arms:render("Use Slam (Arms, swing-safe)")
            if menu_elements.use_slam_arms:get_state() then
                menu_elements.slam_min_rage:render("Slam Min Rage")
                menu_elements.slam_assumed_cast_ms:render("Slam Assumed Cast (ms)")
                menu_elements.slam_swing_buffer_ms:render("Slam Swing Buffer (ms)")
                menu_elements.slam_post_swing_window_ms:render("Slam Post-Swing Window (ms)")
            end
            menu_elements.use_bloodthirst:render("Use Bloodthirst (Fury)")
            menu_elements.use_rampage:render("Use Rampage (Fury)")
            menu_elements.use_execute:render("Use Execute")
            if menu_elements.use_execute:get_state() then
                menu_elements.execute_hp_pct:render("Execute HP%")
            end

            menu_elements.use_demoralizing_shout:render("Use Demoralizing Shout")
            menu_elements.use_devastate:render("Use Devastate (Defensive stance filler)")

            menu_elements.use_sunder_leveling:render("Use Sunder Armor (optional)")
            if menu_elements.use_sunder_leveling:get_state() then
                menu_elements.sunder_leveling_only_elite_or_boss:render("Only Elite/Boss")
                menu_elements.sunder_leveling_only_in_party:render("Only In Party")
                menu_elements.sunder_leveling_engaged_only:render("Engaged Only")
                menu_elements.sunder_leveling_min_ttd:render("Sunder Min TTD (seconds)")
                menu_elements.sunder_leveling_stacks:render("Sunder Stacks")
                menu_elements.sunder_leveling_min_rage:render("Sunder Min Rage")
            end

            menu_elements.enable_aoe:render("Enable AoE")
            if menu_elements.enable_aoe:get_state() then
                menu_elements.aoe_min_enemies:render("AoE Min Enemies")
            end
            menu_elements.use_sweeping_strikes:render("Use Sweeping Strikes")
            menu_elements.use_whirlwind:render("Use Whirlwind")

            menu_elements.use_heroic_strike:render("Use Heroic Strike")
            menu_elements.use_cleave:render("Use Cleave")
            menu_elements.rage_dump_threshold:render("Rage Dump Threshold")
            menu_elements.rage_dump_prevent_cap:render("Prevent Rage Cap (HS/Cleave)")
            if menu_elements.rage_dump_prevent_cap:get_state() then
                menu_elements.rage_dump_estimated_rage_per_hit:render("Est. Rage Per Hit")
            end
        end)

        menu_elements.cooldowns_tree:render("Cooldowns", function()
            menu_elements.use_cooldowns:render("Use Cooldowns")
            if menu_elements.use_cooldowns:get_state() then
                menu_elements.use_cds_on:render("Use CDs On", { "Boss Only", "Elite+", "Always" })
                menu_elements.cooldowns_min_ttd:render("Cooldowns Min TTD (seconds)")
                menu_elements.use_death_wish:render("Use Death Wish")
                menu_elements.use_recklessness:render("Use Recklessness")
            end

            menu_elements.use_racials:render("Use Racials")
            if menu_elements.use_racials:get_state() then
                menu_elements.racials_sync_with_cds:render("Sync Racials with CDs")
                menu_elements.racials_min_ttd:render("Racials Min TTD (seconds)")
                menu_elements.arcane_torrent_rage_below:render("Arcane Torrent when Rage <=")
            end
        end)

        menu_elements.advanced_tree:render("Advanced (Execute Pooling)", function()
            menu_elements.execute_pool_enabled:render("Enable Execute Pooling")
            if menu_elements.execute_pool_enabled:get_state() then
                menu_elements.execute_pool_start_hp_pct:render("Start Pooling at HP%")
                menu_elements.execute_pool_min_rage:render("Execute Min Rage")
                menu_elements.execute_pool_skip_mortal_strike:render("Skip Mortal Strike while pooling")
                menu_elements.execute_pool_skip_aoe:render("Skip AoE while pooling")
            end
        end)

        menu_elements.interrupts_tree:render("Interrupts", function()
            menu_elements.auto_interrupt:render("Enable Auto Interrupt")
            menu_elements.interrupt_target_mode:render("Target Mode", { "Current Target", "Automatic (smart)" })
            menu_elements.interrupt_range:render("Range (yards)")
            menu_elements.interrupt_engaged_only:render("Engaged Only")
            menu_elements.interrupt_delay_min_pct:render("Delay Min %")
            menu_elements.interrupt_delay_max_pct:render("Delay Max %")
            menu_elements.interrupt_fast_cast_ms:render("Fast Cast (ms)")
            menu_elements.use_shield_bash:render("Use Shield Bash")
            menu_elements.use_pummel:render("Use Pummel")
            menu_elements.use_concussion_blow_interrupt:render("Use Concussion Blow (stun interrupt)")
            menu_elements.allow_stance_dance_for_pummel:render("Allow Stance Dance for Pummel")
            menu_elements.allow_stance_dance_for_pummel_in_tank_mode:render("Allow Stance Dance in Tank Mode")
        end)

        menu_elements.stance_tree:render("Stance Dance", function()
            menu_elements.stance_dance_auto_detect_rage_kept:render("Auto-detect Rage Kept")
            if menu_elements.stance_dance_auto_detect_rage_kept:get_state() ~= true then
                menu_elements.stance_dance_rage_kept_fallback:render("Rage Kept Fallback (0-25)")
            end
            menu_elements.stance_dance_return_delay_ms:render("Return Delay (Fallback, ms)")
            menu_elements.stance_dance_return_timeout_ms:render("Return Timeout (Safety, ms)")
            menu_elements.interrupt_stance_dance_max_rage_waste:render("Interrupt Max Rage Waste")
            menu_elements.tank_stance_dance_max_rage_waste:render("Tank Max Rage Waste")
        end)

        menu_elements.tank_tree:render("Tank Mode", function()
            menu_elements.tank_auto_defensive_stance:render("Auto Defensive Stance")
            menu_elements.tank_auto_taunt:render("Auto Taunt")
            menu_elements.tank_use_thunder_clap:render("Use Thunder Clap (AoE)")
            if menu_elements.tank_use_thunder_clap:get_state() then
                menu_elements.tank_thunder_clap_min_enemies:render("Thunder Clap Min Enemies")
                menu_elements.tank_allow_stance_dance_for_thunder_clap:render("Allow Stance Dance for Thunder Clap")
            end
            menu_elements.tank_use_shield_block:render("Use Shield Block")
            if menu_elements.tank_use_shield_block:get_state() then
                menu_elements.tank_shield_block_min_rage:render("Shield Block Min Rage")
            end
            menu_elements.tank_use_revenge:render("Use Revenge")
            menu_elements.tank_use_shield_slam:render("Use Shield Slam (if learned)")
            menu_elements.tank_use_sunder:render("Apply Sunder (fallback if no Devastate)")
            if menu_elements.tank_use_sunder:get_state() then
                menu_elements.tank_sunder_stacks:render("Sunder Stacks")
            end
            menu_elements.tank_tab_sunder_enabled:render("Enable Tab-Sunder (fallback, multi-target, no Devastate)")
            if menu_elements.tank_tab_sunder_enabled:get_state() then
                menu_elements.tank_tab_sunder_engaged_only:render("Tab-Sunder Engaged Only")
                menu_elements.tank_tab_sunder_min_enemies:render("Tab-Sunder Min Enemies")
                menu_elements.tank_tab_sunder_max_targets:render("Tab-Sunder Max Targets")
                menu_elements.tank_tab_sunder_stacks:render("Tab-Sunder Stacks")
                menu_elements.tank_tab_sunder_range:render("Tab-Sunder Range (yards)")
            end
            menu_elements.tank_use_demoralizing_shout:render("Apply Demo Shout (if debuff missing)")
            menu_elements.tank_use_devastate:render("Use Devastate (Defensive stance filler)")
            menu_elements.tank_use_mocking_blow:render("Use Mocking Blow (Taunt backup)")
            if menu_elements.tank_use_mocking_blow:get_state() then
                menu_elements.tank_allow_stance_dance_for_mocking_blow:render("Allow Stance Dance for Mocking Blow")
                menu_elements.tank_mocking_blow_min_rage:render("Mocking Blow Min Rage")
            end

            menu_elements.tank_use_intervene:render("Use Intervene (peel/utility)")
            if menu_elements.tank_use_intervene:get_state() then
                menu_elements.tank_intervene_hp_pct:render("Intervene Target HP%")
                menu_elements.tank_intervene_throttle_ms:render("Intervene Throttle (ms)")
            end

            menu_elements.tank_use_challenging_shout:render("Use Challenging Shout (AoE taunt emergency)")
            menu_elements.tank_use_concussion_blow:render("Use Concussion Blow (stun/interrupt)")
            menu_elements.tank_use_spell_reflection:render("Use Spell Reflection")
            menu_elements.tank_use_berserker_rage_fear_break:render("Use Berserker Rage (fear break)")
            menu_elements.debug_focus_shield_slam:render("Debug Focus: Shield Slam Castability")

            menu_elements.tank_use_disarm:render("Use Disarm (utility)")
            if menu_elements.tank_use_disarm:get_state() then
                menu_elements.tank_disarm_players_only:render("Disarm Players Only")
                menu_elements.tank_disarm_melee_classes_only:render("Disarm Melee Classes Only (players)")
            end

            menu_elements.tank_cleave_rage_threshold:render("Tank Cleave/HS Rage Threshold")
        end)

        menu_elements.shield_swap_tree:render("Shield Weapon Swapping", function()
            menu_elements.enable_shield_weapon_swap:render("Enable Shield Swap")
            menu_elements.shield_swap_mode:render("Mode", { "Auto Detection", "Manual ID Input" })

            -- Show different options based on mode
            local selected_mode = menu_elements.shield_swap_mode:get() or 1

            if selected_mode == 2 then
                -- Manual Mode: Show text inputs
                if menu_elements.shield_swap_manual_shield_id and menu_elements.shield_swap_manual_shield_id.render then
                    menu_elements.shield_swap_manual_shield_id:render("Shield Item ID (required)")
                end
                if menu_elements.shield_swap_manual_weapon_id and menu_elements.shield_swap_manual_weapon_id.render then
                    menu_elements.shield_swap_manual_weapon_id:render("1H Weapon ID (optional)")
                end
            end

            menu_elements.shield_swap_delay_ms:render("Ability Cast Delay (GCD, ms)")
            menu_elements.shield_swap_back_delay_ms:render("Swap Back Buffer (ms)")
            menu_elements.shield_swap_fallback_timeout_ms:render("Safety Timeout (ms)")
            menu_elements.shield_swap_verbose_logging:render("Verbose Logging (Debug)")
        end)

	        menu_elements.defensives_tree:render("Defensives (Hardcore)", function()
	            menu_elements.use_hp_potions:render("Use Health Potions")
	            if menu_elements.use_hp_potions:get_state() then
	                menu_elements.hp_potion_hp_pct:render("Potion HP%")
	            end

            menu_elements.use_healthstones:render("Use Healthstones")
            if menu_elements.use_healthstones:get_state() then
                menu_elements.healthstone_hp_pct:render("Healthstone HP%")
            end

            menu_elements.emergency_defensive_stance:render("Emergency Defensive Stance")
            if menu_elements.emergency_defensive_stance:get_state() then
                menu_elements.defensive_stance_hp_pct:render("Defensive Stance at HP%")
            end

            menu_elements.use_last_stand:render("Use Last Stand")
            if menu_elements.use_last_stand:get_state() then
                menu_elements.last_stand_hp_pct:render("Last Stand at HP%")
            end

	            menu_elements.use_shield_wall:render("Use Shield Wall")
	            if menu_elements.use_shield_wall:get_state() then
	                menu_elements.shield_wall_hp_pct:render("Shield Wall at HP%")
	            end

	            menu_elements.use_intimidating_shout:render("Use Intimidating Shout")
	            if menu_elements.use_intimidating_shout:get_state() then
	                menu_elements.intimidating_shout_hp_pct:render("Intimidating Shout at HP%")
	            end
	            menu_elements.retaliation_hp_pct:render("Retaliation at HP%")
	        end)

        menu_elements.automation_tree:render("Automation", function()
            menu_elements.auto_loot_enabled:render("Auto Loot")
            if menu_elements.auto_loot_enabled:get_state() then
                menu_elements.auto_loot_mode:render("Loot Mode", { "Out of Combat Only", "In Combat Only", "Always" })
                menu_elements.auto_loot_max_attempts:render("Max Attempts per Corpse")
                menu_elements.auto_loot_retry_delay:render("Corpse Lockout (seconds)")
            end

            menu_elements.auto_mine_enabled:render("Enable Auto Mining")
            if menu_elements.auto_mine_enabled:get_state() then
                menu_elements.auto_mine_range:render("Mining Range (yards)")
            end

            menu_elements.auto_herb_enabled:render("Enable Auto Herbs")
            if menu_elements.auto_herb_enabled:get_state() then
                menu_elements.auto_herb_range:render("Herbing Range (yards)")
            end

            if auto_quest_interact:is_available() then
                menu_elements.auto_quest_interact_enabled:render("Enable Auto Quest Interact")
                if menu_elements.auto_quest_interact_enabled:get_state() then
                    menu_elements.auto_quest_interact_range:render("Interact Range (yards)")
                end
            end

            if auto_skinning:is_available() then
                menu_elements.auto_skin_enabled:render("Enable Auto Skinning")
                if menu_elements.auto_skin_enabled:get_state() then
                    menu_elements.auto_skin_range:render("Skinning Range (yards)")
                end
            end

            core.menu.header():render("Auto Food", color.gray(200))
            menu_elements.auto_consumables_enabled:render("Enable Auto Recovery")
            if menu_elements.auto_consumables_enabled:get_state() then
                menu_elements.auto_food_pct:render("Food Threshold %")
            end
        end)
    end)
end

local f1_key_was_pressed = false
local last_rotation_error_log_time = 0.0
local last_rotation_tick_ms = 0

function warrior:on_update(local_player)
    if settings_ui and settings_ui.menu and settings_ui.menu.enable then
        local hotkey_state = menu_elements.ui_toggle_hotkey:get_state()
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

    local eat_or_drink = buff_manager:get_aura_data(local_player, enums.buff_db.EATING_OR_DRINKING, 200)
    if eat_or_drink and eat_or_drink.is_active then
        return
    end

    control_panel_helper:on_update(menu_elements)

    do
        local want_file = menu_elements.debug_file_logging
            and menu_elements.debug_file_logging:get_state() == true
        if want_file ~= last_file_log_state then
            last_file_log_state = want_file
            log_capture:set_enabled(want_file, { prefix = "warrior_tbc" })
        end
    end

    local rotation_enabled = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true

    local shout_enabled = plugin_helper:is_toggle_enabled(menu_elements.intimidating_shout_toggle) == true
    menu_elements.intimidating_shout_enabled = checkbox_enabled(menu_elements.use_intimidating_shout)
        and shout_enabled

    if rotation_enabled then
        local ooc_charge_enabled = plugin_helper:is_toggle_enabled(menu_elements.ooc_charge_toggle) == true
        local game_now = core.game_time()
        local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
        local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
        if (game_now - last_rotation_tick_ms) >= tick_rate then
            last_rotation_tick_ms = game_now
            local ok, err = pcall(function()
                rotation_logic:execute(local_player, menu_elements, tank_mode_enabled(), ooc_charge_enabled)
            end)
            if not ok then
                local now = core.time()
                if (now - (last_rotation_error_log_time or 0.0)) > 3.0 then
                    last_rotation_error_log_time = now
                    core.log_error(string.format("[Warrior] Rotation error: %s", tostring(err)))
                end
            end
        end
    end

    auto_consumables:on_update(local_player, menu_elements)
    auto_skinning:on_update(local_player, menu_elements)
    auto_loot:on_update(local_player, menu_elements)
    auto_mining:on_update(local_player, menu_elements)
    auto_herbing:on_update(local_player, menu_elements)
    auto_quest_interact:on_update(local_player, menu_elements)
end

function warrior:on_render()
    if settings_ui then
        settings_ui:on_render()
    end
end

function warrior:on_control_panel_render()
    local elements = {}

    control_panel_helper:insert_toggle(elements, {
        name = "Warrior Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "Warrior Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "Warrior Tank Mode (" .. key_helper:get_key_name(menu_elements.tank_mode_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.tank_mode_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "Warrior OOC Charge (" .. key_helper:get_key_name(menu_elements.ooc_charge_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.ooc_charge_toggle
    })

    control_panel_helper:insert_toggle(elements, {
        name = "Warrior Intimidating Shout (" .. key_helper:get_key_name(menu_elements.intimidating_shout_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.intimidating_shout_toggle
    })

    return elements
end

return warrior
