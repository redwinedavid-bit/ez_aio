-- ============================================================================
-- Shaman Rotation Module (TBC Classic 2.4.3)
-- All-In-One Restoration/Elemental/Enhancement
-- Mage-Style Professional Structure
-- ============================================================================

local shaman = {
    allow_while_mounted = false
}

local rotation_logic = require("rotations/shaman/tbc/rotation_logic")
local spells = require("rotations/shaman/tbc/spells")

---@type color
local color = require("common/color")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

---@type key_helper
local key_helper = require("common/utility/key_helper")

---@type enums
local enums = require("common/enums")

---@type control_panel_helper
local control_panel_helper = require("common/utility/control_panel_helper")

---@type rotation_settings_ui
local rotation_settings_ui = require("root/ext_lib_astro_ui/main")

---@type resource_ticks
local resource_ticks = require("shared/resource_ticks")

---@type resource_ticks_widget
local resource_ticks_widget = require("shared/resource_ticks_widget")

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

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = md.tree_node(),
    
    -- Main toggles
    enable_script_check = md.checkbox(true, "shaman_tbc_enable_script"),
    enable_toggle = md.keybind(999, true, "shaman_tbc_enable_toggle"),
    cooldowns_toggle = md.keybind(999, false, "shaman_tbc_cooldowns_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "shaman_tbc_ui_toggle_hotkey"),
    use_cooldowns = md.checkbox(true, "shaman_tbc_use_cd"),
    healing_only = md.checkbox(false, "shaman_tbc_healing_only"),

    -- PvP
    enable_pvp_mode = md.checkbox(false, "shaman_tbc_enable_pvp_mode"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "shaman_tbc_pvp_rotation_tick_rate"),

    -- Restoration Settings
    tank_emergency_hp = md.slider_int(0, 100, spells.DEFAULTS.TANK_EMERGENCY_HP, "shaman_tbc_tank_emergency_hp"),
    player_emergency_hp = md.slider_int(0, 100, spells.DEFAULTS.PLAYER_EMERGENCY_HP, "shaman_tbc_player_emergency_hp"),
    lesser_healing_wave_hp = md.slider_int(0, 100, spells.DEFAULTS.LHW_HP, "shaman_tbc_lhw_hp"),
    healing_wave_hp = md.slider_int(0, 100, spells.DEFAULTS.HW_HP, "shaman_tbc_hw_hp"),
    
    -- AoE Healing
    enable_aoe = md.checkbox(true, "shaman_tbc_enable_aoe"),
    group_aoe_threshold = md.slider_int(1, 10, 3, "shaman_tbc_aoe_count"),
    aoe_hp_threshold = md.slider_int(0, 100, spells.DEFAULTS.CHAIN_HEAL_HP, "shaman_tbc_aoe_hp"),

    -- Elemental Settings
    use_elemental_mastery = md.checkbox(true, "shaman_tbc_use_em"),
    use_chain_lightning = md.checkbox(true, "shaman_tbc_use_cl"),
    cl_mana_threshold = md.slider_int(0, 100, 20, "shaman_tbc_cl_mana"),
    use_totem_of_wrath = md.checkbox(true, "shaman_tbc_use_tow"),

    -- Enhancement Settings
    use_stormstrike = md.checkbox(true, "shaman_tbc_use_ss"),
    use_shamanistic_rage = md.checkbox(true, "shaman_tbc_use_sr"),
    shamanistic_rage_mana = md.slider_int(0, 100, spells.DEFAULTS.SHAMANISTIC_RAGE_MANA, "shaman_tbc_sr_mana"),
    shamanistic_rage_max_hp = md.slider_int(0, 100, 20, "shaman_tbc_sr_target_hp"),

    -- Maintenance
    use_earth_shield = md.checkbox(true, "shaman_tbc_use_es"),
    earth_shield_mode = md.combobox(1, "shaman_tbc_es_mode"), -- 1=Auto, 2=Focus, 3=Main Tank
    use_lightning_shield = md.checkbox(false, "shaman_tbc_use_ls"),
    use_water_shield = md.checkbox(true, "shaman_tbc_use_ws"),
    use_totems = md.checkbox(true, "shaman_tbc_use_totems"),
    totems_combat_only = md.checkbox(true, "shaman_tbc_totems_combat_only"),
    auto_recast_range = md.checkbox(true, "shaman_tbc_totem_range_recast"),
    totem_range = md.slider_int(10, 40, 20, "shaman_tbc_totem_range"),
    
    earth_totem_selection = md.combobox(1, "shaman_tbc_earth_totem"), -- None, SoE, Stoneskin, Tremor, Earthbind, Stoneclaw
    fire_totem_selection = md.combobox(1, "shaman_tbc_fire_totem"),  -- None, ToW, Searing, Fire Nova, Magma, Flametongue
    water_totem_selection = md.combobox(1, "shaman_tbc_water_totem"), -- None, HST, MST, Poison, Disease, Mana Tide
    air_totem_selection = md.combobox(1, "shaman_tbc_air_totem"),   -- None, WF, GoA, WoA, Grounding, Tranquil Air
    
    -- Totem Twisting (WF + GoA)
    enable_totem_twisting = md.checkbox(false, "shaman_tbc_totem_twist"),
    twist_interval = md.slider_int(8, 12, 9, "shaman_tbc_twist_interval"), -- seconds between twists

    use_weapon_buff = md.checkbox(true, "shaman_tbc_use_wb"),
    weapon_buff_mh = md.combobox(4, "shaman_tbc_wb_mh"), -- 1=Rockbiter, 2=Flametongue, 3=Frostbrand, 4=Windfury
    weapon_buff_oh = md.combobox(2, "shaman_tbc_wb_oh"), -- Default: Flametongue for OH

    -- Downranking
    use_downranking = md.checkbox(true, "shaman_tbc_use_dr"),
    
    -- Cooldowns
    use_natures_swiftness = md.checkbox(true, "shaman_tbc_use_ns"),
    natures_swiftness_hp = md.slider_int(0, 100, spells.DEFAULTS.NATURES_SWIFTNESS_HP, "shaman_tbc_ns_hp"),

    -- Leveling / DPS Fallback
    attack_on_target = md.checkbox(true, "shaman_tbc_attack_on_target"),
    auto_melee_engage = md.checkbox(true, "shaman_tbc_auto_melee"),
    melee_distance = md.slider_int(1, 10, 5, "shaman_tbc_melee_dist"),
    
    solo_dps_mana = md.slider_int(0, 100, 40, "shaman_tbc_solo_mana"),
    solo_dps_group_hp = md.slider_int(0, 100, 80, "shaman_tbc_solo_group_hp"),
    
    use_melee_filler = md.checkbox(true, "shaman_tbc_melee_filler"),
    melee_filler_mana = md.slider_int(0, 100, 15, "shaman_tbc_melee_fill_mana"),
    melee_filler_hp = md.slider_int(0, 100, 10, "shaman_tbc_melee_fill_hp"),

    use_lightning_bolt = md.checkbox(true, "shaman_tbc_use_lb"),
    use_flame_shock = md.checkbox(true, "shaman_tbc_use_fs"),
    use_earth_shock = md.checkbox(true, "shaman_tbc_use_esh"),
    earth_shock_mode = md.combobox(1, "shaman_tbc_esh_mode"), -- 1=All, 2=Interrupt Only, 3=Off
    use_flame_shock_grinding = md.checkbox(true, "shaman_tbc_fs_grind"),
    shock_mode = md.combobox(3, "shaman_tbc_shock_mode"), -- 1=Earth Only, 2=Flame Only, 3=Flame DoT + Earth Filler, 4=Frost Shock
    
    attack_on_target_toggle = md.keybind(999, true, "shaman_tbc_attack_ont_toggle"), -- NEW

    -- Survival
    use_healthstones = md.checkbox(true, "shaman_tbc_use_healthstone"),
    healthstone_hp_pct = md.slider_int(0, 100, 35, "shaman_tbc_healthstone_hp"),
    use_hp_potions = md.checkbox(true, "shaman_tbc_use_hp_pot"),
    hp_potion_at = md.slider_int(0, 100, 30, "shaman_tbc_hp_pot_hp"),
    use_mana_potions = md.checkbox(true, "shaman_tbc_use_mana_pot"),
    mana_potion_at = md.slider_int(0, 100, 20, "shaman_tbc_mana_pot_mana"),
    use_racials = md.checkbox(true, "shaman_tbc_use_racials"),
    use_stoneform = md.checkbox(true, "shaman_tbc_use_stoneform"),
    stoneform_hp_pct = md.slider_int(0, 100, 35, "shaman_tbc_stoneform_hp"),
    use_gift_of_the_naaru = md.checkbox(true, "shaman_tbc_use_gon"),
    gift_of_the_naaru_hp_pct = md.slider_int(0, 100, 40, "shaman_tbc_gon_hp"),

    -- Post-Combat Healing
    post_combat_heal_hp = md.slider_int(0, 100, 60, "shaman_tbc_pc_heal_hp"),
    post_combat_heal_to_hp = md.slider_int(0, 100, 90, "shaman_tbc_pc_heal_to_hp"),

    -- Automation
    auto_loot_enabled = md.checkbox(true, "shaman_tbc_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "shaman_tbc_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "shaman_tbc_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "shaman_tbc_auto_loot_retry_delay"),
    auto_mine_enabled = md.checkbox(true, "shaman_tbc_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "shaman_tbc_auto_mine_range"),
    auto_herb_enabled = md.checkbox(true, "shaman_tbc_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "shaman_tbc_auto_herb_range"),
    auto_quest_interact_enabled = md.checkbox(false, "shaman_tbc_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "shaman_tbc_auto_quest_interact_range"),
    auto_skin_enabled = md.checkbox(false, "shaman_tbc_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "shaman_tbc_auto_skin_range"),

    -- Auto Consumables
    auto_consumables_enabled = md.checkbox(true, "shaman_tbc_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "shaman_tbc_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 40, "shaman_tbc_auto_drink_pct"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "shaman_tbc_rotation",
    title = "Shaman TBC Professional",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 550,
    theme = "shaman"
})
settings_ui:enable_presets(menu_elements, md)

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
    return {
        element = element,
        label = label,
        suffix = suffix or "",
        visible_when = visible_when,
        bounds = { min = min_value, max = max_value }
    }
end

settings_ui:add_tab({ id = "core", label = "Core" }, function(tab)
    tab:keybind_grid({
        elements = { menu_elements.enable_toggle, menu_elements.cooldowns_toggle, menu_elements.attack_on_target_toggle },
        labels = { "Enable Rotation", "Burst Cooldowns", "Attack on selected target" }
    })
    
    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 2,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = menu_elements.healing_only, label = "Healing-Only Mode" },
            { element = settings_ui.menu.enable, label = "Show UI Window" }
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
end)

settings_ui:add_tab({ id = "healing", label = "Restoration" }, function(tab)
    tab:checkbox_grid({
        label = "Healing Features",
        columns = 2,
        elements = {
            { element = menu_elements.use_downranking, label = "Smart Downranking" },
            { element = menu_elements.enable_aoe, label = "Use Chain Heal" },
            { element = menu_elements.use_natures_swiftness, label = "Use Nature's Swiftness" }
        }
    })

    tab:slider_list({
        label = "HP Thresholds",
        elements = {
            slider_entry(menu_elements.tank_emergency_hp, "Tank Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.player_emergency_hp, "Player Emergency HP", "%", 0, 100),
            slider_entry(menu_elements.lesser_healing_wave_hp, "LHW Threshhold", "%", 0, 100),
            slider_entry(menu_elements.healing_wave_hp, "HW Threshhold", "%", 0, 100),
            slider_entry(menu_elements.natures_swiftness_hp, "NS Emergency HP", "%", 0, 100)
        }
    })

    tab:slider_list({
        label = "AoE Settings",
        elements = {
            slider_entry(menu_elements.aoe_hp_threshold, "Chain Heal HP", "%", 0, 100),
            slider_entry(menu_elements.group_aoe_threshold, "Min Players for AoE", "", 1, 10)
        }
    })
end)

settings_ui:add_tab({ id = "maintenance", label = "Maintenance" }, function(tab)
    tab:checkbox_grid({
        label = "Shield Upkeep",
        columns = 2,
        elements = {
            { element = menu_elements.use_earth_shield, label = "Earth Shield" },
            { element = menu_elements.use_water_shield, label = "Water Shield (Self)" },
            { element = menu_elements.use_lightning_shield, label = "Lightning Shield" }
        }
    })

    tab:combo_list({
        label = "Earth Shield Settings",
        elements = {
            {
                element = menu_elements.earth_shield_mode,
                label = "Target Mode",
                options = { "Auto (Tank)", "Focus", "Main Tank (Raid)" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Weapon Buffs",
        columns = 1,
        elements = {
            { element = menu_elements.use_weapon_buff, label = "Auto Weapon Imbuement" }
        }
    })

    tab:combo_list({
        label = "Weapon Type",
        elements = {
            {
                element = menu_elements.weapon_buff_type,
                label = "Preferred Buff",
                options = { "Rockbiter", "Flametongue", "Frostbrand", "Windfury" }
            }
        }
    })

    tab:checkbox_grid({
        label = "Totem Management",
        columns = 2,
        elements = {
            { element = menu_elements.use_totems, label = "Automate Totem Placement" },
            { element = menu_elements.totems_combat_only, label = "Combat Only" },
            { element = menu_elements.auto_recast_range, label = "Auto-Recast on Range" }
        }
    })

    tab:slider_list({
        label = "Range Settings",
        elements = {
            slider_entry(menu_elements.totem_range, "Max Totem Distance", "y", 10, 40)
        }
    })
    
    -- Totem Twisting Section
    tab:checkbox_grid({
        label = "Totem Twisting (Enhancement)",
        columns = 1,
        elements = {
            { element = menu_elements.enable_totem_twisting, label = "Enable WF + GoA Twisting" }
        }
    })
    
    tab:slider_list({
        label = "Twist Settings",
        elements = {
            slider_entry(menu_elements.twist_interval, "Twist Interval (sec)", "s", 8, 12)
        }
    })

    tab:combo_list({
        label = "Element Selection",
        elements = {
            {
                element = menu_elements.earth_totem_selection,
                label = "Earth Totem",
                options = { "None", "Strength of Earth", "Stoneskin", "Tremor", "Earthbind", "Stoneclaw" }
            },
            {
                element = menu_elements.fire_totem_selection,
                label = "Fire Totem",
                options = { "None", "Totem of Wrath (Ele)", "Searing Totem", "Fire Nova Totem", "Magma Totem", "Flametongue Totem" }
            },
            {
                element = menu_elements.water_totem_selection,
                label = "Water Totem",
                options = { "None", "Healing Stream", "Mana Spring", "Poison Cleansing", "Disease Cleansing", "Mana Tide (Resto)" }
            },
            {
                element = menu_elements.air_totem_selection,
                label = "Air Totem",
                options = { "None", "Windfury Totem", "Grace of Air", "Wrath of Air", "Grounding Totem", "Tranquil Air" }
            }
        }
    })
end)

settings_ui:add_tab({ id = "elemental", label = "Elemental" }, function(tab)
    tab:checkbox_grid({
        label = "Offensive Spells",
        columns = 2,
        elements = {
            { element = menu_elements.use_lightning_bolt, label = "Lightning Bolt" },
            { element = menu_elements.use_chain_lightning, label = "Chain Lightning" },
            { element = menu_elements.use_elemental_mastery, label = "Elemental Mastery" },
            { element = menu_elements.use_totem_of_wrath, label = "Totem of Wrath" },
            { element = menu_elements.use_flame_shock_grinding, label = "Use Flame Shock (Grinding)" }
        }
    })

    tab:combo_list({
        label = "Earth Shock Settings",
        elements = {
            {
                element = menu_elements.earth_shock_mode,
                label = "Usage Mode",
                options = { "Full DPS", "Interrupt Only", "Off" }
            }
        }
    })

    tab:slider_list({
        label = "Mana Control",
        elements = {
            slider_entry(menu_elements.cl_mana_threshold, "CL Min Mana", "%", 0, 100)
        }
    })
    
    tab:combo_list({
        label = "Shock Settings",
        elements = {
            {
                element = menu_elements.shock_mode,
                label = "Shock Priority",
                options = { "Earth Shock Only", "Flame Shock Only", "Flame DoT + Earth Filler", "Frost Shock (Kiting)" }
            }
        }
    })
end)

settings_ui:add_tab({ id = "enhancement", label = "Enhancement" }, function(tab)
    tab:checkbox_grid({
        label = "Melee Features",
        columns = 1,
        elements = {
            { element = menu_elements.use_stormstrike, label = "Use Stormstrike" },
            { element = menu_elements.use_shamanistic_rage, label = "Use Shamanistic Rage" },
            { element = menu_elements.use_weapon_buff, label = "Auto Weapon Imbues" }
        }
    })
    
    tab:combo_list({
        label = "Weapon Imbues",
        elements = {
            {
                element = menu_elements.weapon_buff_mh,
                label = "Mainhand Imbue",
                options = { "Rockbiter", "Flametongue", "Frostbrand", "Windfury" }
            },
            {
                element = menu_elements.weapon_buff_oh,
                label = "Offhand Imbue",
                options = { "Rockbiter", "Flametongue", "Frostbrand", "Windfury" }
            }
        }
    })

    tab:slider_list({
        label = "Mana Management",
        elements = {
            slider_entry(menu_elements.shamanistic_rage_mana, "Rage at Mana % <", "%", 0, 100),
            slider_entry(menu_elements.shamanistic_rage_max_hp, "Stop if Target HP <", "%", 0, 100)
        }
    })
end)

settings_ui:add_tab({ id = "fallback", label = "DPS Fallback" }, function(tab)
    tab:keybind_grid({
        elements = { menu_elements.attack_on_target_toggle },
        labels = { "Attack on selected target Toggle" }
    })

    tab:checkbox_grid({
        label = "Engage Settings",
        columns = 2,
        elements = {
            { element = menu_elements.attack_on_target, label = "Attack on selected target" },
            { element = menu_elements.auto_melee_engage, label = "Auto Melee Engagement" },
            { element = menu_elements.use_melee_filler, label = "Use Melee Filler" },
            { element = menu_elements.use_lightning_bolt, label = "LB Filler" }
        }
    })

    tab:slider_list({
        label = "Conditionals",
        elements = {
            slider_entry(menu_elements.melee_distance, "Melee Max Range", "y", 1, 10),
            slider_entry(menu_elements.solo_dps_mana, "Min Mana for Spell DPS", "%", 0, 100),
            slider_entry(menu_elements.solo_dps_group_hp, "Min Group HP for DPS", "%", 0, 100)
        }
    })

    tab:slider_list({
        label = "Filler Thresholds (Wand-Style)",
        elements = {
            slider_entry(menu_elements.melee_filler_mana, "Melee when Mana % <", "%", 0, 100),
            slider_entry(menu_elements.melee_filler_hp, "Melee when Enemy HP % <", "%", 0, 100)
        }
    })
end)

settings_ui:add_tab({ id = "survival", label = "Survival" }, function(tab)
    tab:checkbox_grid({
        label = "Emergency Buttons",
        columns = 2,
        elements = {
            { element = menu_elements.use_healthstones, label = "Use Healthstones" },
            { element = menu_elements.use_hp_potions, label = "Use HP Potions" },
            { element = menu_elements.use_mana_potions, label = "Use Mana Potions" },
            { element = menu_elements.use_racials, label = "Use Racial Abilities" },
            { element = menu_elements.use_stoneform, label = "Use Stoneform (Dwarf)" },
            { element = menu_elements.use_gift_of_the_naaru, label = "Use Gift of the Naaru (Draenei)" },
        }
    })

    tab:slider_list({
        label = "Thresholds",
        elements = {
            slider_entry(menu_elements.healthstone_hp_pct, "Healthstone at HP%", "%", 0, 100),
            slider_entry(menu_elements.hp_potion_at, "HP Potion at HP%", "%", 0, 100),
            slider_entry(menu_elements.mana_potion_at, "Mana Potion at Mana%", "%", 0, 100),
            slider_entry(menu_elements.stoneform_hp_pct, "Stoneform at HP%", "%", 0, 100),
            slider_entry(menu_elements.gift_of_the_naaru_hp_pct, "Gift of the Naaru at HP%", "%", 0, 100),
        }
    })

    tab:slider_list({
        label = "Post-Combat Healing",
        elements = {
            slider_entry(menu_elements.post_combat_heal_hp, "Heal if HP % <", "%", 0, 100),
            slider_entry(menu_elements.post_combat_heal_to_hp, "Heal UP to HP %", "%", 0, 100)
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
-- UPDATE LOOP
-- ============================================================================

local f1_key_was_pressed = false
local attack_key_was_pressed = false
local last_rotation_tick_ms = 0
local ROTATION_TICK_MS = 100

function shaman:on_update(local_player)
    -- Toggle UI with F1
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

    -- Toggle Attack on Target with keybind (Mage Style)
    if menu_elements.attack_on_target_toggle and menu_elements.attack_on_target_toggle:get_key_code() ~= 999 then
        local attack_key_down = menu_elements.attack_on_target_toggle:get_state() == true
        if attack_key_down and not attack_key_was_pressed then
            local current_state = menu_elements.attack_on_target:get_state()
            local new_state = not current_state
            if menu_elements.attack_on_target.set then
                menu_elements.attack_on_target:set(new_state)
            elseif menu_elements.attack_on_target.set_state then
                menu_elements.attack_on_target:set_state(new_state)
            end
            core.log("[Shaman TBC] Attack on selected target: " .. (new_state and "Enabled" or "Disabled"))
        end
        attack_key_was_pressed = attack_key_down
    end

	    if not local_player then return end
	    if rotation_pause.is_eating_or_drinking(local_player) then return end
	    if not menu_elements.enable_script_check:get_state() then return end

	    local rotation_enabled = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true
	    if rotation_enabled and not local_player:is_dead() and not local_player:is_ghost() and not local_player:is_mounted() then
	        local now = core.game_time()
            local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
            local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
	        if (now - last_rotation_tick_ms) >= tick_rate then
	            last_rotation_tick_ms = now

	            -- Resource Tick Tracker
	            local tick_tracker = resource_ticks.get()
	            if tick_tracker then tick_tracker:on_update(local_player) end

	            -- Execute Logic
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

function shaman:on_render()
    if settings_ui then settings_ui:on_render() end
end

function shaman:on_menu_render()
    if settings_ui then settings_ui:on_menu_render() end
    
    local spec = rotation_logic:get_current_spec()
    local spec_color = color.white()
    if spec == "Restoration" then spec_color = color.new(0, 191, 255, 255)
    elseif spec == "Elemental" then spec_color = color.new(255, 0, 0, 255)
    elseif spec == "Enhancement" then spec_color = color.new(255, 140, 0, 255)
    end

    menu_elements.main_tree:render("Shaman TBC Professional", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))
        md.header():render(string.format("Detected Spec: %s", spec), spec_color)
        
        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Enable Rotation Toggle")

        md.header():render("PVP (TBC)", color.new(220, 170, 255, 220))
        menu_elements.enable_pvp_mode:render("Enable PvP Rotation (Overlay)")
        if menu_elements.enable_pvp_mode:get_state() then
            menu_elements.pvp_rotation_tick_rate:render("PvP Rotation Frequency (ms)")
        end
        
        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end
    end)
end

function shaman:on_control_panel_render()
    local elements = {}
    control_panel_helper:insert_toggle(elements, {
        name = "Shaman TBC " .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()),
        keybind = menu_elements.enable_toggle
    })
    return elements
end

return shaman
