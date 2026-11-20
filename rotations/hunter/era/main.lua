-- Hunter rotation module (AIO-compatible)
local performance = require("shared/rotation_performance")

local hunter = {
    allow_while_mounted = true
}
local cooldowns_auto_off_deadline = nil
local cooldowns_auto_off_prev_enabled = false

local rotation_logic = require("rotations/hunter/era/rotation_logic")

---@type color
local color = require("common/color")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type key_helper
local key_helper = require("common/utility/key_helper")

---@type control_panel_helper
local control_panel_helper = require("common/utility/control_panel_helper")

---@type pet_handler
local pet_handler = require("common/utility/pet_handler")

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

---@type rotation_settings_ui
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = md.tree_node(),
    general_tree = md.tree_node(),
    pet_tree = md.tree_node(),
    aspects_tree = md.tree_node(),
    cooldowns_tree = md.tree_node(),
    tranq_tree = md.tree_node(),
    consumables_tree = md.tree_node(),
    defensive_tree = md.tree_node(),

    -- Main toggles
    enable_script_check = md.checkbox(true, "hunter_enable_script"),
    enable_toggle = md.keybind(999, true, "hunter_enable_toggle"),
    cooldowns_toggle = md.keybind(999, false, "hunter_cooldowns_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "hunter_ui_toggle_hotkey"),
    enable_aoe = md.checkbox(false, "hunter_enable_aoe"),
    aoe_toggle = md.keybind(999, false, "hunter_aoe_toggle"),

    -- General
    auto_dismount = md.checkbox(true, "hunter_auto_dismount"),
    use_aimed_shot = md.checkbox(true, "hunter_use_aimed_shot"),
    use_clipped_rotation = md.checkbox(true, "hunter_use_clipped_rotation"),
    post_swing_instants_only = md.checkbox(false, "hunter_post_swing_instants_only"),
    post_swing_window_ms = md.slider_int(50, 600, 350, "hunter_post_swing_window_ms"),
    use_volley = md.checkbox(true, "hunter_use_volley"),
    use_multi_shot = md.checkbox(true, "hunter_use_multi_shot"),
    multi_on_boss = md.checkbox(true, "hunter_multi_on_boss"),
    use_arcane_shot = md.checkbox(true, "hunter_use_arcane_shot"),
    use_flare_anti_stealth = md.checkbox(false, "hunter_use_flare_anti_stealth"),
    arcane_shot_min_mana = md.slider_int(0, 100, 70, "hunter_arcane_shot_min_mana"),
    arcane_min_ttd_normal = md.slider_float(0, 10, 1.5, "hunter_arcane_min_ttd_normal"),
    arcane_min_ttd_elite = md.slider_float(0, 10, 1.5, "hunter_arcane_min_ttd_elite"),
    arcane_min_ttd_rare = md.slider_float(0, 10, 1.5, "hunter_arcane_min_ttd_rare"),
    use_serpent_sting = md.checkbox(true, "hunter_use_serpent_sting"),
    serpent_min_ttd_normal = md.slider_int(0, 30, 10, "hunter_serpent_min_ttd_normal"),
    serpent_min_hp_normal = md.slider_int(0, 100, 50, "hunter_serpent_min_hp_normal"),
    serpent_min_ttd_elite = md.slider_int(0, 30, 6, "hunter_serpent_min_ttd_elite"),
    serpent_min_hp_elite = md.slider_int(0, 100, 25, "hunter_serpent_min_hp_elite"),
    serpent_min_ttd_rare = md.slider_int(0, 30, 6, "hunter_serpent_min_ttd_rare"),
    serpent_min_hp_rare = md.slider_int(0, 100, 20, "hunter_serpent_min_hp_rare"),
    use_viper_sting = md.checkbox(false, "hunter_use_viper_sting"),
    use_concussive_shot = md.checkbox(true, "hunter_use_concussive_shot"),
    concussive_distance = md.slider_int(10, 41, 15, "hunter_concussive_distance"),
    use_scare_beast = md.checkbox(false, "hunter_use_scare_beast"),
    scare_beast_hp = md.slider_int(20, 60, 30, "hunter_scare_beast_hp"),
    use_raptor_strike = md.checkbox(true, "hunter_use_raptor_strike"),
    use_mongoose_bite = md.checkbox(true, "hunter_use_mongoose_bite"),
    use_wing_clip = md.checkbox(false, "hunter_use_wing_clip"),

    -- Pet Management
    auto_call_pet = md.checkbox(true, "hunter_auto_call_pet"),
    auto_revive_pet = md.checkbox(true, "hunter_auto_revive_pet"),
    auto_pet_attack = md.checkbox(true, "hunter_auto_pet_attack"),
    auto_mend_pet = md.checkbox(true, "hunter_auto_mend_pet"),
    mend_pet_hp = md.slider_int(0, 100, 30, "hunter_mend_pet_hp"),
    enable_pet_pullback = md.checkbox(true, "hunter_enable_pet_pullback"),
    pet_pullback_hp = md.slider_int(0, 100, 35, "hunter_pet_pullback_hp"),
    pet_send_back_hp = md.slider_int(50, 100, 70, "hunter_pet_send_back_hp"),
    wait_for_pet_aggro = md.checkbox(false, "hunter_wait_for_pet_aggro"),
    use_intimidation = md.checkbox(true, "hunter_use_intimidation"),
    save_intimidation_for_interrupt = md.checkbox(false, "hunter_save_intimidation_for_interrupt"),
    pet_aggro_wait_time = md.slider_int(0, 5, 2, "hunter_pet_aggro_wait_time"),
    pet_aggro_hp_threshold = md.slider_int(80, 100, 95, "hunter_pet_aggro_hp_threshold"),

    -- Pet Engage (pet_attack targeting)
    pet_target_mode = md.combobox(2, "hunter_pet_target_mode"),
    pet_engage_throttle_ms = md.slider_int(0, 2500, 300, "hunter_pet_engage_throttle_ms"),
    pet_target_scan_range = md.slider_int(10, 60, 35, "hunter_pet_target_scan_range"),
    pet_debug_logs = md.checkbox(false, "hunter_pet_debug_logs"),
    pet_debug_verbose = md.checkbox(false, "hunter_pet_debug_verbose"),

    -- Aspects
    use_aspect_hawk = md.checkbox(true, "hunter_use_aspect_hawk"),
    use_aspect_monkey = md.checkbox(true, "hunter_use_aspect_monkey"),
    aspect_monkey_hp = md.slider_int(0, 100, 75, "hunter_aspect_monkey_hp"),
    use_aspect_cheetah = md.checkbox(true, "hunter_use_aspect_cheetah"),
    prevent_pack_combat = md.checkbox(true, "hunter_prevent_pack_combat"),
    use_hunters_mark = md.checkbox(true, "hunter_use_hunters_mark"),
    use_trueshot_aura = md.checkbox(true, "hunter_use_trueshot_aura"),

    -- Cooldowns
    use_cooldowns = md.checkbox(true, "hunter_use_cooldowns"),
    use_cds_on = md.combobox(1, "hunter_use_cds_on"), -- 1=Boss, 2=Elite+, 3=Always
    cooldowns_auto_off_seconds = md.slider_int(5, 120, 30, "hunter_cooldowns_auto_off_seconds"),

    -- Tranq Shot
    use_tranq_shot = md.checkbox(true, "hunter_use_tranq_shot"),
    save_mana_for_tranq = md.checkbox(true, "hunter_save_mana_for_tranq"),
    hunters_that_tranq = md.combobox(1, "hunter_hunters_that_tranq"),
    tranq_order = md.combobox(1, "hunter_tranq_order"),

    -- Consumables
    use_hp_potions = md.checkbox(true, "hunter_use_hp_potions"),
    hp_potion_at = md.slider_int(10, 80, 40, "hunter_hp_potion_at"),
    use_mana_potions = md.checkbox(true, "hunter_use_mana_potions"),
    mana_potion_at = md.slider_int(10, 60, 30, "hunter_mana_potion_at"),
    use_healthstones = md.checkbox(true, "hunter_use_healthstones"),
    healthstone_hp_pct = md.slider_int(0, 100, 35, "hunter_healthstone_hp_pct"),

    -- Defensive
    use_deterrence = md.checkbox(true, "hunter_use_deterrence"),
    deterrence_hp = md.slider_int(10, 50, 25, "hunter_deterrence_hp"),
    use_feign_death_emergency = md.checkbox(true, "hunter_use_feign_death_emergency"),
    feign_death_emergency_hp = md.slider_int(1, 100, 20, "hunter_feign_death_emergency_hp"),
    feign_death_emergency_min_aggro = md.slider_int(1, 10, 1, "hunter_feign_death_emergency_min_aggro"),
    feign_death_emergency_range = md.slider_int(5, 40, 20, "hunter_feign_death_emergency_range"),

    use_feign_death_multi = md.checkbox(false, "hunter_use_feign_death_multi"),
    feign_death_multi_hp = md.slider_int(1, 100, 50, "hunter_feign_death_multi_hp"),
    feign_death_multi_min_aggro = md.slider_int(1, 10, 3, "hunter_feign_death_multi_min_aggro"),
    feign_death_multi_range = md.slider_int(5, 40, 20, "hunter_feign_death_multi_range"),

    -- Threat / Utility
    use_disengage = md.checkbox(true, "hunter_use_disengage"),
    disengage_range = md.slider_int(3, 8, 5, "hunter_disengage_range"),

    use_distracting_shot = md.checkbox(false, "hunter_use_distracting_shot"),
    distracting_shot_range = md.slider_int(10, 41, 35, "hunter_distracting_shot_range"),
    distracting_party_range = md.slider_int(10, 41, 40, "hunter_distracting_party_range"),
    distracting_only_healers = md.checkbox(true, "hunter_distracting_only_healers"),
    distracting_require_not_tanking = md.checkbox(true, "hunter_distracting_require_not_tanking"),

    -- Auto Loot
    automation_tree = md.tree_node(),
    auto_loot_enabled = md.checkbox(true, "hunter_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "hunter_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "hunter_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "hunter_auto_loot_retry_delay"),

    -- Auto Mining
    auto_mine_enabled = md.checkbox(true, "hunter_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "hunter_auto_mine_range"),

    -- Auto Herbs
    auto_herb_enabled = md.checkbox(true, "hunter_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "hunter_auto_herb_range"),

    -- Auto Quest Interact
    auto_quest_interact_enabled = md.checkbox(false, "hunter_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "hunter_auto_quest_interact_range"),

    -- Auto Skinning
    auto_skin_enabled = md.checkbox(false, "hunter_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "hunter_auto_skin_range"),

    -- PvP Mode & Tick Rate
    enable_pvp_mode = md.checkbox(false, "hunter_era_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "hunter_era_pvp_rotation_tick_rate"),

    -- Auto Food/Drink
    auto_consumables_enabled = md.checkbox(true, "hunter_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "hunter_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 50, "hunter_auto_drink_pct"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "hunter_rotation",
    title = "Hunter Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 650,
    theme = "hunter"
})
settings_ui:enable_presets(menu_elements, md)

local function arcane_shot_enabled()
    return menu_elements.use_arcane_shot:get_state()
end

local function serpent_sting_enabled()
    return menu_elements.use_serpent_sting:get_state()
end

local function concussive_enabled()
    return menu_elements.use_concussive_shot:get_state()
end

local function scare_beast_enabled()
    return menu_elements.use_scare_beast:get_state()
end

local function auto_mend_enabled()
    return menu_elements.auto_mend_pet:get_state()
end

local function pet_engage_enabled()
    return menu_elements.auto_pet_attack:get_state()
end

local function pet_pullback_enabled()
    return menu_elements.enable_pet_pullback:get_state()
end

local function pet_aggro_wait_enabled()
    return menu_elements.wait_for_pet_aggro:get_state()
end

local function aspect_monkey_enabled()
    return menu_elements.use_aspect_monkey:get_state()
end

local function cooldowns_enabled()
    return menu_elements.use_cooldowns:get_state()
end

local function get_cooldowns_auto_off_seconds()
    local ok, seconds = pcall(function()
        return menu_elements.cooldowns_auto_off_seconds:get()
    end)
    if ok and type(seconds) == "number" then
        return seconds
    end
    return 30
end

local function force_cooldowns_toggle_off()
    local toggle = menu_elements and menu_elements.cooldowns_toggle
    if not toggle then
        return
    end
    pcall(function()
        if toggle.set_toggle_state then
            toggle:set_toggle_state(false)
        elseif toggle.set_state then
            toggle:set_state(false)
        end
    end)
end

local function deterrence_enabled()
    return menu_elements.use_deterrence:get_state()
end

local function hp_potions_enabled()
    return menu_elements.use_hp_potions:get_state()
end

local function mana_potions_enabled()
    return menu_elements.use_mana_potions:get_state()
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

local function auto_quest_available()
    return auto_quest_interact and auto_quest_interact:is_available() == true
end

local function auto_quest_enabled()
    return menu_elements.auto_quest_interact_enabled:get_state()
end

local function skinning_available()
    return auto_skinning and auto_skinning:is_available() == true
end

local function auto_skin_enabled()
    return menu_elements.auto_skin_enabled:get_state()
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
            menu_elements.aoe_toggle
        },
        labels = {
            "Enable Rotation",
            "Burst Cooldowns",
            "AoE Mode"
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = menu_elements.enable_aoe, label = "Enable AoE" },
            { element = menu_elements.auto_dismount, label = "Auto Dismount" },
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" }
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Candidate Scan Interval", "ms", 30, 100)
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "combat", label = "Combat Features" }, function(tab)
    tab:checkbox_grid({
        label = "Ranged Rotation",
        columns = 2,
        elements = {
            { element = menu_elements.use_aimed_shot, label = "Use Aimed Shot" },
            { element = menu_elements.use_clipped_rotation, label = "Use Clipped Rotation" },
            { element = menu_elements.post_swing_instants_only, label = "Instants Only After Auto (Unclipped)" },
            { element = menu_elements.use_volley, label = "Use Volley" },
            { element = menu_elements.use_multi_shot, label = "Use Multi-Shot" },
            { element = menu_elements.multi_on_boss, label = "Multi-Shot on Boss", visible_when = function()
                return menu_elements.use_multi_shot:get_state()
            end },
            { element = menu_elements.use_arcane_shot, label = "Use Arcane Shot" },
            { element = menu_elements.use_serpent_sting, label = "Use Serpent Sting" },
            { element = menu_elements.use_viper_sting, label = "Use Viper Sting" },
            { element = menu_elements.use_flare_anti_stealth, label = "Anti-Stealth Flare" }
        }
    })

    tab:slider_list({
        label = "Arcane Shot",
        elements = {
            slider_entry(menu_elements.arcane_shot_min_mana, "Arcane Min Mana %", "%", 0, 100, arcane_shot_enabled),
            slider_entry(menu_elements.arcane_min_ttd_normal, "Arcane Min TTD (Normal)", "s", 0, 10, arcane_shot_enabled),
            slider_entry(menu_elements.arcane_min_ttd_elite, "Arcane Min TTD (Elite)", "s", 0, 10, arcane_shot_enabled),
            slider_entry(menu_elements.arcane_min_ttd_rare, "Arcane Min TTD (Rare)", "s", 0, 10, arcane_shot_enabled)
        }
    })

    tab:slider_list({
        label = "Auto Shot Timing",
        elements = {
            slider_entry(menu_elements.post_swing_window_ms, "Post-Swing Window", "ms", 50, 600, function()
                return (not menu_elements.use_clipped_rotation:get_state()) and menu_elements.post_swing_instants_only:get_state()
            end)
        }
    })

    tab:slider_list({
        label = "Serpent Sting",
        elements = {
            slider_entry(menu_elements.serpent_min_ttd_normal, "Serpent Min TTD (Normal)", "s", 0, 30, serpent_sting_enabled),
            slider_entry(menu_elements.serpent_min_hp_normal, "Serpent Min HP (Normal)", "%", 0, 100, serpent_sting_enabled),
            slider_entry(menu_elements.serpent_min_ttd_elite, "Serpent Min TTD (Elite)", "s", 0, 30, serpent_sting_enabled),
            slider_entry(menu_elements.serpent_min_hp_elite, "Serpent Min HP (Elite)", "%", 0, 100, serpent_sting_enabled),
            slider_entry(menu_elements.serpent_min_ttd_rare, "Serpent Min TTD (Rare)", "s", 0, 30, serpent_sting_enabled),
            slider_entry(menu_elements.serpent_min_hp_rare, "Serpent Min HP (Rare)", "%", 0, 100, serpent_sting_enabled)
        }
    })

    tab:checkbox_grid({
        label = "Utility & CC",
        columns = 2,
        elements = {
            { element = menu_elements.use_concussive_shot, label = "Use Concussive Shot" },
            { element = menu_elements.use_scare_beast, label = "Use Scare Beast (CC)" }
        }
    })

    tab:slider_list({
        label = "Utility Thresholds",
        elements = {
            slider_entry(menu_elements.concussive_distance, "Concussive Distance", "yd", 10, 41, concussive_enabled),
            slider_entry(menu_elements.scare_beast_hp, "Scare Beast HP%", "%", 20, 60, scare_beast_enabled)
        }
    })

    tab:checkbox_grid({
        label = "Melee Fallback",
        columns = 2,
        elements = {
            { element = menu_elements.use_raptor_strike, label = "Use Raptor Strike" },
            { element = menu_elements.use_mongoose_bite, label = "Use Mongoose Bite" },
            { element = menu_elements.use_wing_clip, label = "Use Wing Clip" }
        }
    })
end)

settings_ui:add_tab({ id = "pet", label = "Pet Management" }, function(tab)
    tab:checkbox_grid({
        label = "Pet Controls",
        columns = 2,
        elements = {
            { element = menu_elements.auto_call_pet, label = "Auto Call Pet" },
            { element = menu_elements.auto_revive_pet, label = "Auto Revive Pet" },
            { element = menu_elements.auto_pet_attack, label = "Auto Pet Attack" },
            { element = menu_elements.auto_mend_pet, label = "Auto Mend Pet" },
            { element = menu_elements.enable_pet_pullback, label = "Enable Pet Pullback" },
            { element = menu_elements.wait_for_pet_aggro, label = "Wait for Pet Aggro" },
            { element = menu_elements.use_intimidation, label = "Use Intimidation" },
            { element = menu_elements.save_intimidation_for_interrupt, label = "Save Intimidation for Interrupt" },
            { element = menu_elements.pet_debug_logs, label = "Pet Debug Logs (Console)", visible_when = pet_engage_enabled },
            { element = menu_elements.pet_debug_verbose, label = "Pet Debug Verbose (Spammy)", visible_when = pet_engage_enabled and menu_elements.pet_debug_logs:get_state() }
        }
    })

    tab:combo_list({
        label = "Pet Targeting",
        elements = {
            {
                element = menu_elements.pet_target_mode,
                label = "Target Mode",
                options = {
                    "Disabled",
                    "Attack My Target (Tank It)",
                    "Take Aggro (then My Target)",
                    "Smart (Healer > Me > Tank > My Target)"
                },
                visible_when = pet_engage_enabled
            }
        }
    })

    tab:slider_list({
        label = "Pet Thresholds",
        elements = {
            slider_entry(menu_elements.mend_pet_hp, "Mend Pet HP%", "%", 0, 100, auto_mend_enabled),
            slider_entry(menu_elements.pet_pullback_hp, "Pet Pullback HP%", "%", 0, 100, pet_pullback_enabled),
            slider_entry(menu_elements.pet_send_back_hp, "Pet Send Back HP%", "%", 50, 100, pet_pullback_enabled),
            slider_entry(menu_elements.pet_aggro_wait_time, "Wait Time (sec)", "s", 0, 5, pet_aggro_wait_enabled),
            slider_entry(menu_elements.pet_aggro_hp_threshold, "Wait Until Target HP%", "%", 80, 100, pet_aggro_wait_enabled)
        }
    })

    tab:slider_list({
        label = "Pet Engage Tuning",
        elements = {
            slider_entry(menu_elements.pet_target_scan_range, "Scan Range", "yd", 10, 60, pet_engage_enabled),
            slider_entry(menu_elements.pet_engage_throttle_ms, "Retarget Throttle (0=off)", "ms", 0, 2500, pet_engage_enabled)
        }
    })

    tab:separator({})
    tab:text({
        text = [[Pet Engage / Auto Pet Attack

- If "Auto Pet Attack" is enabled, the pet is sent to attack the selected target via pet_attack.
- Target Mode:
  - Attack My Target: Pet attacks your current target.
  - Take Aggro: Pet locks onto the first enemy targeting you; stays locked until it stops targeting you; then rescans. Falls back to your target.
  - Smart: Same as above but priority lock is Healer > Me > Tank > My Target (locks until that condition no longer holds, then rescans).
- Scan Range: How far to scan for valid enemies.
- Retarget Throttle: Minimum time between pet_attack commands (higher = less spam, 0 = off).]]
    })
end)

settings_ui:add_tab({ id = "aspects", label = "Aspects & Buffs" }, function(tab)
    tab:checkbox_grid({
        label = "Aspects",
        columns = 2,
        elements = {
            { element = menu_elements.use_aspect_hawk, label = "Use Aspect of the Hawk" },
            { element = menu_elements.use_aspect_monkey, label = "Use Aspect of the Monkey" },
            { element = menu_elements.use_aspect_cheetah, label = "Use Aspect of the Cheetah" },
            { element = menu_elements.prevent_pack_combat, label = "Prevent Pack in Combat" }
        }
    })

    tab:slider_list({
        label = "Aspect Thresholds",
        elements = {
            slider_entry(menu_elements.aspect_monkey_hp, "Switch to Monkey HP%", "%", 0, 100, aspect_monkey_enabled)
        }
    })

    tab:checkbox_grid({
        label = "Buffs",
        columns = 2,
        elements = {
            { element = menu_elements.use_hunters_mark, label = "Use Hunter's Mark" },
            { element = menu_elements.use_trueshot_aura, label = "Use Trueshot Aura" }
        }
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns & Tranq" }, function(tab)
    tab:checkbox_grid({
        label = "Cooldowns",
        columns = 2,
        elements = {
            { element = menu_elements.use_cooldowns, label = "Use Cooldowns" }
        }
    })

    tab:combo_list({
        label = "Cooldown Mode",
        elements = {
            {
                element = menu_elements.use_cds_on,
                label = "Use CDs On",
                options = { "Boss Only", "Elite+", "Always" },
                visible_when = cooldowns_enabled
            }
        }
    })

    tab:slider_list({
        label = "Cooldown Timer",
        elements = {
            slider_entry(menu_elements.cooldowns_auto_off_seconds, "Cooldown Auto-Off (sec)", " s", 5, 120)
        }
    })

    tab:checkbox_grid({
        label = "Tranquilizing Shot",
        columns = 2,
        elements = {
            { element = menu_elements.use_tranq_shot, label = "Use Tranq Shot" },
            { element = menu_elements.save_mana_for_tranq, label = "Save Mana for Tranq" }
        }
    })

    tab:combo_list({
        label = "Tranq Rotation",
        elements = {
            {
                element = menu_elements.hunters_that_tranq,
                label = "Hunters in Rotation",
                options = { "1", "2", "3" }
            },
            {
                element = menu_elements.tranq_order,
                label = "My Tranq Order",
                options = { "1st", "2nd", "3rd" }
            }
        }
    })
end)

settings_ui:add_tab({ id = "survival", label = "Survival & Consumables" }, function(tab)
    tab:checkbox_grid({
        label = "Defensive",
        columns = 2,
        elements = {
            { element = menu_elements.use_deterrence, label = "Use Deterrence" },
            { element = menu_elements.use_disengage, label = "Use Disengage" }
        }
    })

    tab:slider_list({
        label = "Defensive Thresholds",
        elements = {
            slider_entry(menu_elements.deterrence_hp, "Deterrence HP%", "%", 10, 50, deterrence_enabled),
            slider_entry(menu_elements.disengage_range, "Disengage Range", "yd", 3, 8, function()
                return menu_elements.use_disengage:get_state()
            end)
        }
    })

    tab:checkbox_grid({
        label = "Threat / Utility",
        columns = 2,
        elements = {
            { element = menu_elements.use_distracting_shot, label = "Use Distracting Shot" },
            { element = menu_elements.distracting_only_healers, label = "Only Protect Healers", visible_when = function()
                return menu_elements.use_distracting_shot:get_state()
            end },
            { element = menu_elements.distracting_require_not_tanking, label = "Only If Not Tanking", visible_when = function()
                return menu_elements.use_distracting_shot:get_state()
            end }
        }
    })

    tab:slider_list({
        label = "Distracting Shot",
        elements = {
            slider_entry(menu_elements.distracting_shot_range, "Distracting Shot Range", "yd", 10, 41, function()
                return menu_elements.use_distracting_shot:get_state()
            end),
            slider_entry(menu_elements.distracting_party_range, "Protect Party Range", "yd", 10, 41, function()
                return menu_elements.use_distracting_shot:get_state()
            end)
        }
    })

    tab:checkbox_grid({
        label = "Consumables",
        columns = 2,
        elements = {
            { element = menu_elements.use_hp_potions, label = "Use HP Potions" },
            { element = menu_elements.use_mana_potions, label = "Use Mana Potions" },
            { element = menu_elements.use_healthstones, label = "Use Healthstones" }
        }
    })

    tab:slider_list({
        label = "Consumable Thresholds",
        elements = {
            slider_entry(menu_elements.hp_potion_at, "HP Potion at %", "%", 10, 80, hp_potions_enabled),
            slider_entry(menu_elements.mana_potion_at, "Mana Potion at %", "%", 10, 60, mana_potions_enabled),
            slider_entry(menu_elements.healthstone_hp_pct, "Healthstone HP%", "%", 0, 100, function()
                return menu_elements.use_healthstones:get_state()
            end),
            slider_entry(menu_elements.auto_food_pct, "Auto Food at HP%", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
            slider_entry(menu_elements.auto_drink_pct, "Auto Drink at Mana%", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
        }
    })
end)

settings_ui:add_tab({ id = "automation", label = "Automation & Utilities" }, function(tab)
        tab:checkbox_grid({
            label = "Automation Toggles",
            columns = 2,
            elements = {
                { element = menu_elements.auto_loot_enabled, label = "Auto Loot" },
                { element = menu_elements.auto_mine_enabled, label = "Auto Mining" },
                { element = menu_elements.auto_herb_enabled, label = "Auto Herbs" },
                { element = menu_elements.auto_quest_interact_enabled, label = "Auto Quest Interact", visible_when = auto_quest_available },
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
            label = "Automation Ranges",
            elements = {
                slider_entry(menu_elements.auto_loot_max_attempts, "Max Attempts per Corpse", "", 1, 10, auto_loot_enabled),
                slider_entry(menu_elements.auto_loot_retry_delay, "Corpse Lockout (sec)", "s", 30, 200, auto_loot_enabled),
                slider_entry(menu_elements.auto_mine_range, "Mining Range (yd)", "yd", 2, 8, auto_mine_enabled),
                slider_entry(menu_elements.auto_herb_range, "Herbing Range (yd)", "yd", 2, 8, auto_herb_enabled),
                slider_entry(menu_elements.auto_quest_interact_range, "Quest Interact Range (yd)", "yd", 2, 8, auto_quest_enabled),
                slider_entry(menu_elements.auto_skin_range, "Skinning Range (yd)", "yd", 2, 8, function()
                    return skinning_available() and auto_skin_enabled()
                end),
                slider_entry(menu_elements.auto_food_pct, "Auto Food at HP%", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
                slider_entry(menu_elements.auto_drink_pct, "Auto Drink at Mana%", "%", 0, 100, function() return menu_elements.auto_consumables_enabled:get_state() end),
            }
        })
end)

function hunter:on_menu_render()
    settings_ui:on_menu_render()

    menu_elements.main_tree:render("Hunter Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Toggle Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")
        menu_elements.cooldowns_toggle:render("Cooldowns Toggle (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ")")
        menu_elements.enable_aoe:render("Enable AoE")
        menu_elements.aoe_toggle:render("AoE Toggle (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ")")

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end

        menu_elements.general_tree:render("General", function()
            menu_elements.auto_dismount:render("Auto Dismount")
            menu_elements.use_aimed_shot:render("Use Aimed Shot")
            menu_elements.use_clipped_rotation:render("Use Clipped Rotation")
            menu_elements.post_swing_instants_only:render("Instants Only After Auto (Unclipped)")
            if (not menu_elements.use_clipped_rotation:get_state()) and menu_elements.post_swing_instants_only:get_state() then
                menu_elements.post_swing_window_ms:render("Post-Swing Window (ms)")
            end
            menu_elements.use_volley:render("Use Volley")
            menu_elements.use_multi_shot:render("Use Multi-Shot")
            if menu_elements.use_multi_shot:get_state() then
                menu_elements.multi_on_boss:render("Use Multi-Shot on Boss")
            end
            menu_elements.use_arcane_shot:render("Use Arcane Shot")
            menu_elements.use_flare_anti_stealth:render("Anti-Stealth Flare")
            if menu_elements.use_arcane_shot:get_state() then
                menu_elements.arcane_shot_min_mana:render("Arcane Shot Min Mana % (Ranged)")
                menu_elements.arcane_min_ttd_normal:render("Arcane Min TTD (Normal, sec)")
                menu_elements.arcane_min_ttd_elite:render("Arcane Min TTD (Elite, sec)")
                menu_elements.arcane_min_ttd_rare:render("Arcane Min TTD (Rare, sec)")
            end
            menu_elements.use_serpent_sting:render("Use Serpent Sting")
            if menu_elements.use_serpent_sting:get_state() then
                menu_elements.serpent_min_ttd_normal:render("Serpent Min TTD (Normal, sec)")
                menu_elements.serpent_min_hp_normal:render("Serpent Min HP (Normal, %)")
                menu_elements.serpent_min_ttd_elite:render("Serpent Min TTD (Elite, sec)")
                menu_elements.serpent_min_hp_elite:render("Serpent Min HP (Elite, %)")
                menu_elements.serpent_min_ttd_rare:render("Serpent Min TTD (Rare, sec)")
                menu_elements.serpent_min_hp_rare:render("Serpent Min HP (Rare, %)")
            end
            menu_elements.use_viper_sting:render("Use Viper Sting")
            menu_elements.use_concussive_shot:render("Use Concussive Shot")
            if menu_elements.use_concussive_shot:get_state() then
                menu_elements.concussive_distance:render("Concussive Distance")
            end
            menu_elements.use_scare_beast:render("Use Scare Beast (CC)")
            if menu_elements.use_scare_beast:get_state() then
                menu_elements.scare_beast_hp:render("Scare Beast at HP %")
            end
            menu_elements.use_raptor_strike:render("Use Raptor Strike (Melee)")
            menu_elements.use_mongoose_bite:render("Use Mongoose Bite (Melee)")
            menu_elements.use_wing_clip:render("Use Wing Clip (Melee)")
        end)

        menu_elements.pet_tree:render("Pet Management", function()
            menu_elements.auto_call_pet:render("Auto Call Pet")
            menu_elements.auto_revive_pet:render("Auto Revive Pet")
            menu_elements.auto_pet_attack:render("Auto Pet Attack")
            if menu_elements.auto_pet_attack:get_state() then
                menu_elements.pet_target_mode:render("Pet Target Mode", {
                    "Disabled",
                    "Attack My Target (Tank It)",
                    "Take Aggro (then My Target)",
                    "Smart (Healer > Me > Tank > My Target)"
                })
                menu_elements.pet_target_scan_range:render("Pet Scan Range (yd)")
                menu_elements.pet_engage_throttle_ms:render("Pet Retarget Throttle (ms, 0=off)")
                menu_elements.pet_debug_logs:render("Pet Debug Logs (Console)")
                if menu_elements.pet_debug_logs:get_state() then
                    menu_elements.pet_debug_verbose:render("Pet Debug Verbose (Spammy)")
                end
            end
            menu_elements.auto_mend_pet:render("Auto Mend Pet")
            if menu_elements.auto_mend_pet:get_state() then
                menu_elements.mend_pet_hp:render("Mend Pet HP %")
            end
            menu_elements.enable_pet_pullback:render("Enable Pet Pullback (Safety)")
            if menu_elements.enable_pet_pullback:get_state() then
                menu_elements.pet_pullback_hp:render("Pet Pullback HP %")
                menu_elements.pet_send_back_hp:render("Pet Send Back HP %")
            end
            menu_elements.wait_for_pet_aggro:render("Wait for Pet Aggro (Safety)")
            if menu_elements.wait_for_pet_aggro:get_state() then
                menu_elements.pet_aggro_wait_time:render("Wait Time (seconds)")
                menu_elements.pet_aggro_hp_threshold:render("Wait Until Target HP % <")
            end
            menu_elements.use_intimidation:render("Use Intimidation")
            menu_elements.save_intimidation_for_interrupt:render("Save Intimidation for Interrupt")
        end)

        menu_elements.aspects_tree:render("Aspects & Buffs", function()
            menu_elements.use_aspect_hawk:render("Use Aspect of the Hawk")
            menu_elements.use_aspect_monkey:render("Use Aspect of the Monkey")
            if menu_elements.use_aspect_monkey:get_state() then
                menu_elements.aspect_monkey_hp:render("Switch to Monkey HP %")
            end
            menu_elements.use_aspect_cheetah:render("Use Aspect of the Cheetah (Travel)")
            menu_elements.prevent_pack_combat:render("Prevent Aspect of Pack in Combat")
            menu_elements.use_hunters_mark:render("Use Hunter's Mark")
            menu_elements.use_trueshot_aura:render("Use Trueshot Aura")
        end)

        menu_elements.defensive_tree:render("Survival", function()
            menu_elements.use_deterrence:render("Use Deterrence")
            if menu_elements.use_deterrence:get_state() then
                menu_elements.deterrence_hp:render("Deterrence HP %")
            end
            menu_elements.use_disengage:render("Use Disengage")
            if menu_elements.use_disengage:get_state() then
                menu_elements.disengage_range:render("Disengage Range")
            end
            menu_elements.use_feign_death_emergency:render("Use Feign Death (Emergency)")
            if menu_elements.use_feign_death_emergency:get_state() then
                menu_elements.feign_death_emergency_hp:render("Feign Death at HP %")
                menu_elements.feign_death_emergency_min_aggro:render("Feign Death Min Aggro Size")
            end
            menu_elements.use_distracting_shot:render("Use Distracting Shot")
            menu_elements.use_hp_potions:render("Use HP Potions")
            if menu_elements.use_hp_potions:get_state() then
                menu_elements.hp_potion_at:render("HP Potion at %")
            end
            menu_elements.use_mana_potions:render("Use Mana Potions")
            if menu_elements.use_mana_potions:get_state() then
                menu_elements.mana_potion_at:render("Mana Potion at %")
            end
            menu_elements.use_healthstones:render("Use Healthstones")
            if menu_elements.use_healthstones:get_state() then
                menu_elements.healthstone_hp_pct:render("Healthstone HP %")
            end

            menu_elements.auto_consumables_enabled:render("Auto Food/Drink (OOC)")
            if menu_elements.auto_consumables_enabled:get_state() then
                menu_elements.auto_food_pct:render("Auto Food HP%")
                menu_elements.auto_drink_pct:render("Auto Drink Mana%")
            end
        end)

        menu_elements.cooldowns_tree:render("Cooldowns", function()
            menu_elements.use_cooldowns:render("Use Cooldowns")
            if menu_elements.use_cooldowns:get_state() then
                menu_elements.use_cds_on:render("Use CDs On", { "Boss Only", "Elite+", "Always" })
                menu_elements.cooldowns_auto_off_seconds:render("Cooldown Auto-Off (sec)")
            end
        end)

        menu_elements.tranq_tree:render("Tranquilizing Shot", function()
            menu_elements.use_tranq_shot:render("Use Tranq Shot on Boss Enrage")
            menu_elements.save_mana_for_tranq:render("Save Mana for Tranq Shot")
            menu_elements.hunters_that_tranq:render("Hunters in Tranq Rotation", { "1", "2", "3" })
            menu_elements.tranq_order:render("My Tranq Order", { "1st", "2nd", "3rd" })
        end)

        menu_elements.defensive_tree:render("Defensive Abilities", function()
            menu_elements.use_deterrence:render("Use Deterrence")
            if menu_elements.use_deterrence:get_state() then
                menu_elements.deterrence_hp:render("Deterrence HP %")
            end

            menu_elements.use_disengage:render("Use Disengage")
            if menu_elements.use_disengage:get_state() then
                menu_elements.disengage_range:render("Disengage Range (yards)")
            end

            menu_elements.use_distracting_shot:render("Use Distracting Shot (Protect Party)")
            if menu_elements.use_distracting_shot:get_state() then
                menu_elements.distracting_shot_range:render("Distracting Shot Range (yards)")
                menu_elements.distracting_party_range:render("Protect Party Range (yards)")
                menu_elements.distracting_only_healers:render("Only Protect Healers")
                menu_elements.distracting_require_not_tanking:render("Only If Not Tanking")
            end

            menu_elements.use_feign_death_emergency:render("Use Feign Death (Emergency)")
            if menu_elements.use_feign_death_emergency:get_state() then
                menu_elements.feign_death_emergency_hp:render("Emergency HP %")
                menu_elements.feign_death_emergency_min_aggro:render("Emergency: Min Aggro Count")
                menu_elements.feign_death_emergency_range:render("Emergency: Aggro Check Range (yards)")
            end

            menu_elements.use_feign_death_multi:render("Use Feign Death (Multi-Aggro)")
            if menu_elements.use_feign_death_multi:get_state() then
                menu_elements.feign_death_multi_hp:render("Multi-Aggro HP %")
                menu_elements.feign_death_multi_min_aggro:render("Multi-Aggro: Min Aggro Count")
                menu_elements.feign_death_multi_range:render("Multi-Aggro: Aggro Check Range (yards)")
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

            -- Auto Skinning (conditional - nur wenn Profession gelernt)
            if auto_skinning:is_available() then
                menu_elements.auto_skin_enabled:render("Enable Auto Skinning")
                if menu_elements.auto_skin_enabled:get_state() then
                    menu_elements.auto_skin_range:render("Skinning Range (yards)")
                end
            end
        end)
    end)
end

local f1_key_was_pressed = false

function hunter:on_update(local_player)
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

    local now = core.time()
    local cooldowns_toggle_enabled = plugin_helper:is_toggle_enabled(menu_elements.cooldowns_toggle) == true
    if cooldowns_toggle_enabled and not cooldowns_auto_off_prev_enabled then
        cooldowns_auto_off_deadline = now + get_cooldowns_auto_off_seconds()
    elseif (not cooldowns_toggle_enabled) and cooldowns_auto_off_prev_enabled then
        cooldowns_auto_off_deadline = nil
    elseif cooldowns_toggle_enabled and cooldowns_auto_off_deadline and now >= cooldowns_auto_off_deadline then
        force_cooldowns_toggle_off()
        cooldowns_auto_off_deadline = nil
        cooldowns_toggle_enabled = false
    end
    cooldowns_auto_off_prev_enabled = cooldowns_toggle_enabled

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

    -- Don't run rotation/automation while mounted or while eating/drinking.
    -- This prevents breaking the regen buffs and matches the mounted behavior request.
    if local_player:is_mounted() then
        return
    end

	    -- Pet handler tick (required for pet commands to execute)
    pet_handler:on_render()

    local game_now = core.game_time()
    if performance:begin_update(local_player, menu_elements, game_now) then
        rotation_logic:execute(local_player, menu_elements)
    end

    -- Auto-skinning (before loot, after rotation logic)
    auto_skinning:on_update(local_player, menu_elements)

    -- Auto-loot (lowest priority)
    auto_loot:on_update(local_player, menu_elements)

    -- Auto-mining (lowest priority)
    auto_mining:on_update(local_player, menu_elements)

    -- Auto-herbing (lowest priority)
    auto_herbing:on_update(local_player, menu_elements)

    -- Auto-quest interact (if Questie available)
    auto_quest_interact:on_update(local_player, menu_elements)

    -- Auto-consumables
    auto_consumables:on_update(local_player, menu_elements)
end

function hunter:on_render()
    if settings_ui then
        settings_ui:on_render()
    end
end

function hunter:on_control_panel_render()
    local control_panel_elements = {}

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Hunter Rotation Enable (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Hunter Cooldowns (" .. key_helper:get_key_name(menu_elements.cooldowns_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.cooldowns_toggle
    })

    control_panel_helper:insert_toggle(control_panel_elements, {
        name = "Hunter AoE (" .. key_helper:get_key_name(menu_elements.aoe_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.aoe_toggle
    })

    return control_panel_elements
end

return hunter
