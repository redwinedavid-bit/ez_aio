-- ============================================================================
-- Mage Rotation Module (AIO-compatible)
-- TBC Classic - Arcane/Fire/Frost Support
-- ============================================================================

local mage = {}

local rotation_logic = require("rotations/mage/tbc/rotation_logic")

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

local menu_defaults = require("shared/menu_defaults")
local md = menu_defaults.new()

-- ============================================================================
-- MENU CONFIGURATION
-- ============================================================================

local menu_elements = {
    main_tree = md.tree_node(),
    core_tree = md.tree_node(),
    rotation_tree = md.tree_node(),
    buffs_tree = md.tree_node(),
    resources_tree = md.tree_node(),
    cooldowns_tree = md.tree_node(),
    utility_tree = md.tree_node(),
    defensive_tree = md.tree_node(),

    enable_script_check = md.checkbox(true, "mage_enable_script"),
    enable_toggle = md.keybind(999, true, "mage_enable_toggle"),
    ui_toggle_hotkey = md.keybind(112, false, "mage_ui_toggle_hotkey"),

    -- Rotation Mode
    rotation_mode = md.combobox(1, "mage_rotation_mode"), -- 1=Auto, 2=Arcane, 3=Fire, 4=Frost

    -- Specific Logic (Fire)
    maintain_scorch = md.checkbox(true, "mage_maintain_scorch"),

    -- Fire Blast
    use_fireblast = md.checkbox(true, "mage_use_fireblast"),
    fireblast_hp_threshold = md.slider_int(0, 100, 10, "mage_fireblast_hp_threshold"),
    use_fireblast_moving = md.checkbox(true, "mage_use_fireblast_moving"),
    use_fireblast_off_cd = md.checkbox(false, "mage_use_fireblast_off_cd"),
    
    -- Specific Logic (Frost)
    use_water_elemental = md.checkbox(true, "mage_use_water_elemental"),
    use_ice_lance = md.checkbox(true, "mage_use_ice_lance"),
    auto_pet_attack = md.checkbox(true, "mage_auto_pet_attack"),
    
    -- Specific Logic (Arcane)
    arcane_conserve_mana = md.slider_int(0, 100, 30, "mage_arcane_conserve_mana"),
    use_arcane_missiles = md.checkbox(true, "mage_use_arcane_missiles"),
    
    -- Wand / Filler
    use_wand = md.checkbox(true, "mage_use_wand"),
    wand_mana_threshold = md.slider_int(0, 100, 20, "mage_wand_mana_threshold"),
    wand_target_hp = md.slider_int(0, 100, 25, "mage_wand_target_hp"),
    attack_on_target = md.checkbox(true, "mage_attack_on_target"),

    -- Buffs
    maintain_armor = md.checkbox(true, "mage_maintain_armor"),
    armor_mode = md.combobox(1, "mage_armor_mode"), -- 1=Auto, 2=Molten, 3=Mage, 4=Ice
    maintain_intellect = md.checkbox(true, "mage_maintain_intellect"),

    -- Resources
    use_mana_gem = md.checkbox(true, "mage_use_mana_gem"),
    mana_gem_threshold = md.slider_int(0, 100, 80, "mage_mana_gem_threshold"),
    conjure_gems = md.checkbox(true, "mage_conjure_gems"),
    
    use_evocation = md.checkbox(true, "mage_use_evocation"),
    evocation_threshold = md.slider_int(0, 100, 15, "mage_evocation_threshold"),

    -- Cooldowns
    use_cooldowns = md.checkbox(true, "mage_use_cooldowns"),
    use_arcane_power = md.checkbox(true, "mage_use_arcane_power"),
    use_icy_veins = md.checkbox(true, "mage_use_icy_veins"),
    use_combustion = md.checkbox(true, "mage_use_combustion"),
    use_presence_of_mind = md.checkbox(true, "mage_use_presence_of_mind"),
    use_cold_snap = md.checkbox(true, "mage_use_cold_snap"),
    enable_pvp_burst = md.checkbox(false, "mage_enable_pvp_burst"),
    pvp_burst_hotkey = md.keybind(999, false, "mage_pvp_burst_hotkey"),
    
	    -- Utility
	    use_counterspell = md.checkbox(false, "mage_use_counterspell"),
	    use_arcane_torrent_interrupt = md.checkbox(false, "mage_use_arcane_torrent_interrupt"),
	    arcane_torrent_interrupt_pct = md.slider_int(0, 100, 25, "mage_arcane_torrent_interrupt_pct"),
	    use_polymorph = md.checkbox(false, "mage_use_polymorph"),
	    use_remove_curse = md.checkbox(false, "mage_use_remove_curse"),
    
    -- Defensive
    use_ice_block = md.checkbox(true, "mage_use_ice_block"),
    ice_block_hp_threshold = md.slider_int(0, 100, 15, "mage_ice_block_hp"),
    use_blink = md.checkbox(false, "mage_use_blink"),
    use_frost_nova = md.checkbox(false, "mage_use_frost_nova"),
    frost_nova_hp_threshold = md.slider_int(0, 100, 35, "mage_frost_nova_hp"),
    use_mana_shield = md.checkbox(false, "mage_use_mana_shield"),
    mana_shield_hp_threshold = md.slider_int(0, 100, 25, "mage_mana_shield_hp"),

    -- PvP Tuning
    pvp_focus_cc = md.checkbox(false, "mage_pvp_focus_cc"),
    pvp_interrupt_pct = md.slider_int(0, 100, 75, "mage_pvp_interrupt_pct"),
    pvp_spellsteal_enabled = md.checkbox(true, "mage_pvp_spellsteal_enabled"),
    
    -- Spellsteal Buff List
    ss_innervate = md.checkbox(true, "mage_ss_innervate"),
    ss_power_infusion = md.checkbox(true, "mage_ss_pi"),
    ss_lifebloom = md.checkbox(true, "mage_ss_lifebloom"),
    ss_earth_shield = md.checkbox(true, "mage_ss_earth_shield"),
    ss_wings = md.checkbox(true, "mage_ss_wings"),
    ss_bop = md.checkbox(true, "mage_ss_bop"),
    ss_freedom = md.checkbox(true, "mage_ss_freedom"),
    ss_heroism = md.checkbox(true, "mage_ss_heroism"),
    ss_icy_veins = md.checkbox(true, "mage_ss_icy_veins"),
    ss_combustion = md.checkbox(true, "mage_ss_combustion"),
    
    -- Elite Tuning
    pvp_pet_sync_shatter = md.checkbox(true, "mage_pvp_pet_sync_shatter"),
    pvp_anti_stealth = md.checkbox(true, "mage_pvp_anti_stealth"),
    pvp_armor_swap = md.checkbox(true, "mage_pvp_armor_swap"),
    use_remove_curse_smart = md.checkbox(true, "mage_use_remove_curse_smart"),
    pvp_coc_finisher = md.checkbox(true, "mage_pvp_coc_finisher"),
    pvp_kite_combo = md.checkbox(true, "mage_pvp_kite_combo"),
    pvp_trinket_enabled = md.checkbox(false, "mage_pvp_trinket_enabled"),
    pvp_dr_awareness = md.checkbox(true, "mage_pvp_dr_awareness"),

    -- AoE Mode
    enable_aoe_mode = md.checkbox(false, "mage_enable_aoe_mode"),
    aoe_toggle_key = md.keybind(999, false, "mage_aoe_toggle_key"),
    aoe_target_threshold = md.slider_int(2, 10, 3, "mage_aoe_target_threshold"),

    -- Automation
    auto_loot_enabled = md.checkbox(true, "mage_tbc_auto_loot_enabled"),
    auto_loot_mode = md.combobox(1, "mage_tbc_auto_loot_mode"),
    auto_loot_max_attempts = md.slider_int(1, 10, 1, "mage_tbc_auto_loot_max_attempts"),
    auto_loot_retry_delay = md.slider_int(30, 200, 60, "mage_tbc_auto_loot_retry_delay"),

    auto_mine_enabled = md.checkbox(true, "mage_tbc_auto_mine_enabled"),
    auto_mine_range = md.slider_int(2, 8, 5, "mage_tbc_auto_mine_range"),

    auto_herb_enabled = md.checkbox(true, "mage_tbc_auto_herb_enabled"),
    auto_herb_range = md.slider_int(2, 8, 5, "mage_tbc_auto_herb_range"),

    auto_quest_interact_enabled = md.checkbox(false, "mage_tbc_auto_quest_interact_enabled"),
    auto_quest_interact_range = md.slider_int(2, 8, 4, "mage_tbc_auto_quest_interact_range"),

    auto_skin_enabled = md.checkbox(false, "mage_tbc_auto_skin_enabled"),
    auto_skin_range = md.slider_int(2, 8, 5, "mage_tbc_auto_skin_range"),

    use_blizzard = md.checkbox(true, "mage_use_blizzard"),
    use_flamestrike = md.checkbox(false, "mage_use_flamestrike"),
    use_coc = md.checkbox(true, "mage_use_cone_of_cold_aoe"),
    use_ice_barrier_aoe = md.checkbox(true, "mage_use_ice_barrier_aoe"),
    use_mana_shield_aoe = md.checkbox(false, "mage_use_mana_shield_aoe"),

    -- Auto Recovery
    auto_consumables_enabled = md.checkbox(true, "mage_auto_consumables_enabled"),
    auto_food_pct = md.slider_int(0, 100, 50, "mage_auto_food_pct"),
    auto_drink_pct = md.slider_int(0, 100, 40, "mage_auto_drink_pct"),

    -- Tick Rate
    -- Tick Rate
    enable_pvp_mode = md.checkbox(false, "mage_enable_pvp_mode"),
    pvp_toggle_key = md.keybind(999, false, "mage_pvp_toggle_key"),
    pvp_rotation_tick_rate = md.slider_int(30, 100, 30, "mage_pvp_rotation_tick_rate"),
}

-- ============================================================================
-- CUSTOM UI SETUP
-- ============================================================================

local settings_ui = rotation_settings_ui.new({
    id = "mage_rotation",
    title = "Mage Rotation Settings",
    default_x = 700,
    default_y = 200,
    default_w = 480,
    default_h = 520,
    theme = "mage" -- Assumed existing theme or fallback
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
        elements = { menu_elements.enable_toggle },
        labels = { "Enable Rotation" }
    })
    
    tab:combo_list({
        label = "Strategy",
        elements = {
             {
                 element = menu_elements.rotation_mode,
                 label = "Rotation Spec",
                 options = { "Auto Detect", "Arcane", "Fire", "Frost" }
             }
        }
    })

    tab:checkbox_grid({
        label = "Core Toggles",
        columns = 1,
        elements = {
            { element = menu_elements.enable_script_check, label = "Enable Script" },
            { element = settings_ui.menu.enable, label = "Show Custom UI Window" }
        }
    })

    tab:keybind_grid({
        elements = { menu_elements.pvp_toggle_key },
        labels = { "Toggle PvP Mode" }
    })

    tab:checkbox_grid({
        label = "PvP Strategy",
        elements = {
            { element = menu_elements.enable_pvp_mode, label = "Enable PvP Mode" },
        }
    })

    tab:slider_list({
        label = "Performance Settings",
        elements = {
            slider_entry(menu_elements.pvp_rotation_tick_rate, "PvP Rotation Frequency", "ms", 30, 100)
        }
    })

    tab:separator()
    tab:button({
        label = "Reset All to Defaults",
        on_click = function() md.reset_all() end
    })
end)

settings_ui:add_tab({ id = "rotation", label = "Rotation" }, function(tab)
    tab:checkbox_grid({
        label = "Fire Spec",
        columns = 1,
        elements = {
            { element = menu_elements.maintain_scorch, label = "Maintain Improved Scorch" },
        }
    })
    
    tab:checkbox_grid({
        label = "Frost Spec",
        columns = 1,
        elements = {
            { element = menu_elements.use_water_elemental, label = "Summon Water Elemental" },
            { element = menu_elements.use_ice_lance, label = "Use Ice Lance (moving)" },
            { element = menu_elements.auto_pet_attack, label = "Auto Pet Attack" },
        }
    })
    
    tab:checkbox_grid({
        label = "Arcane Spec",
        columns = 1,
        elements = {
            { element = menu_elements.use_arcane_missiles, label = "Use Arcane Missiles" },
        }
    })
    
    tab:slider_list({
        label = "Arcane Settings",
        elements = {
            slider_entry(menu_elements.arcane_conserve_mana, "Conserve until Mana % >", "%", 0, 100)
        }
    })
    
    tab:checkbox_grid({
        label = "Wand / Filler",
        columns = 2,
        elements = {
            { element = menu_elements.use_wand, label = "Use Wand" },
            { element = menu_elements.attack_on_target, label = "Attack on Target" },
        }
    })
    
    tab:slider_list({
        label = "Wand Settings",
        elements = {
            slider_entry(menu_elements.wand_mana_threshold, "Wand when Mana % <", "%", 0, 100),
            slider_entry(menu_elements.wand_target_hp, "Wand when Target HP % <", "%", 0, 100),
        }
    })
end)

settings_ui:add_tab({ id = "cooldowns", label = "Cooldowns" }, function(tab)
    tab:checkbox_grid({
        label = "Master Toggle",
        columns = 1,
        elements = {
            { element = menu_elements.use_cooldowns, label = "Use Offensive Cooldowns" },
        }
    })
    
    tab:checkbox_grid({
        label = "Individual Cooldowns",
        columns = 2,
        elements = {
            { element = menu_elements.use_arcane_power, label = "Arcane Power" },
            { element = menu_elements.use_icy_veins, label = "Icy Veins" },
            { element = menu_elements.use_combustion, label = "Combustion" },
            { element = menu_elements.use_presence_of_mind, label = "Presence of Mind" },
            { element = menu_elements.use_cold_snap, label = "Cold Snap" },
            { element = menu_elements.use_fireblast, label = "Use Fire Blast" },
            { element = menu_elements.use_fireblast_moving, label = "Fire Blast Moving" },
        }
    })

    tab:checkbox_grid({
        label = "PvP Strategy",
        columns = 1,
        elements = {
            { element = menu_elements.enable_pvp_burst, label = "Enable PvP Burst Mode" },
        }
    })

    tab:keybind_grid({
        elements = { menu_elements.pvp_burst_hotkey },
        labels = { "PvP Burst Hotkey" }
    })

    tab:checkbox_grid({
        label = "Advanced Strategy",
        columns = 1,
        elements = {
            { element = menu_elements.use_fireblast_off_cd, label = "Fire Blast Off-Cooldown (High Mana)" },
        }
    })

    tab:slider_list({
        label = "Strategy Thresholds",
        elements = {
            slider_entry(menu_elements.fireblast_hp_threshold, "Fire Blast Finisher HP % <", "%", 0, 100),
        }
    })
end)

settings_ui:add_tab({ id = "buffs", label = "Buffs & Resources" }, function(tab)
    tab:checkbox_grid({
        label = "Buffs",
        columns = 2,
        elements = {
            { element = menu_elements.maintain_intellect, label = "Auto Intellect" },
            { element = menu_elements.maintain_armor, label = "Auto Armor" },
        }
    })
    
    tab:combo_list({
        label = "Armor Type",
        elements = {
             {
                 element = menu_elements.armor_mode,
                 label = "Preferred Armor",
                 options = { "Auto", "Molten Armor", "Mage Armor", "Ice Armor" }
             }
        }
    })
    
    tab:checkbox_grid({
        label = "Mana Management",
        columns = 2,
        elements = {
            { element = menu_elements.use_mana_gem, label = "Use Mana Gem" },
            { element = menu_elements.conjure_gems, label = "Auto Conjure Gems" },
            { element = menu_elements.use_evocation, label = "Auto Evocation" },
        }
    })
    
    tab:slider_list({
        label = "Thresholds",
        elements = {
            slider_entry(menu_elements.mana_gem_threshold, "Gem at Mana % <", "%", 0, 100),
            slider_entry(menu_elements.evocation_threshold, "Evocation at Mana % <", "%", 0, 100),
        }
    })

    tab:checkbox_grid({
        label = "Elite Advanced Tuning",
        columns = 1,
        elements = {
            { element = menu_elements.pvp_pet_sync_shatter, label = "Pet-Sync Shatter Mastery (Frost)" },
            { element = menu_elements.pvp_anti_stealth, label = "Anti-Stealth Reactive AE (Rank 1)" },
            { element = menu_elements.pvp_armor_swap, label = "Adaptive Armor Swapping (Melee/Caster)" },
            { element = menu_elements.use_remove_curse_smart, label = "Smart Decurse (Tongues/Exhaustion)" },
            { element = menu_elements.pvp_coc_finisher, label = "Cone of Cold Finisher (Kill Window)" },
            { element = menu_elements.pvp_kite_combo, label = "Auto Kite Combo (Nova > Blink > Bolt)" },
            { element = menu_elements.pvp_trinket_enabled, label = "Auto PvP Trinket (Break CC)" },
            { element = menu_elements.pvp_dr_awareness, label = "DR Awareness (Nova/Sheep/CS)" },
        }
    })
end)

settings_ui:add_tab({ id = "spellsteal", label = "Spellsteal Tuning" }, function(tab)
    tab:checkbox_grid({
        label = "Priority Buffs to Steal",
        columns = 2,
        elements = {
            { element = menu_elements.pvp_spellsteal_enabled, label = "Master Spellsteal Toggle" },
            { element = menu_elements.ss_innervate, label = "Innervate" },
            { element = menu_elements.ss_power_infusion, label = "Power Infusion" },
            { element = menu_elements.ss_lifebloom, label = "Lifebloom (Druid)" },
            { element = menu_elements.ss_earth_shield, label = "Earth Shield (Shaman)" },
            { element = menu_elements.ss_wings, label = "Avenging Wrath (Wings)" },
            { element = menu_elements.ss_bop, label = "Blessing of Protection" },
            { element = menu_elements.ss_freedom, label = "Blessing of Freedom" },
            { element = menu_elements.ss_heroism, label = "Heroism / Bloodlust" },
            { element = menu_elements.ss_icy_veins, label = "Icy Veins" },
            { element = menu_elements.ss_combustion, label = "Combustion" },
        }
    })
end)

settings_ui:add_tab({ id = "utility", label = "Utility" }, function(tab)
	    tab:checkbox_grid({
	        label = "Utility Spells",
	        columns = 2,
	        elements = {
	            { element = menu_elements.pvp_focus_cc, label = "Prioritize Focus Target CC" },
	            { element = menu_elements.use_counterspell, label = "Auto Counterspell" },
	            { element = menu_elements.use_arcane_torrent_interrupt, label = "Arcane Torrent (Belf)" },
	            { element = menu_elements.use_polymorph, label = "Auto Polymorph" },
	        }
	    })

	    tab:slider_list({
	        label = "Interrupt Timing",
	        elements = {
	            slider_entry(menu_elements.pvp_interrupt_pct, "Counterspell at Cast % >=", "%", 0, 100),
	            slider_entry(menu_elements.arcane_torrent_interrupt_pct, "Arcane Torrent at Cast % >=", "%", 0, 100),
	        }
	    })
end)

settings_ui:add_tab({ id = "defensive", label = "Defensive" }, function(tab)
    tab:checkbox_grid({
        label = "Defensive Abilities",
        columns = 2,
        elements = {
            { element = menu_elements.use_ice_block, label = "Auto Ice Block" },
            { element = menu_elements.use_blink, label = "Auto Blink" },
            { element = menu_elements.use_frost_nova, label = "Auto Frost Nova" },
            { element = menu_elements.use_mana_shield, label = "Auto Mana Shield" },
        }
    })
    
    tab:slider_list({
        label = "HP Thresholds",
        elements = {
            slider_entry(menu_elements.ice_block_hp_threshold, "Ice Block at HP % <", "%", 0, 100),
            slider_entry(menu_elements.frost_nova_hp_threshold, "Frost Nova at HP % <", "%", 0, 100),
            slider_entry(menu_elements.mana_shield_hp_threshold, "Mana Shield at HP % <", "%", 0, 100),
        }
    })
end)

settings_ui:add_tab({ id = "aoe", label = "AoE Mode" }, function(tab)
    tab:keybind_grid({
        elements = { menu_elements.aoe_toggle_key },
        labels = { "Toggle AoE Mode" }
    })

    tab:checkbox_grid({
        label = "Master Control",
        columns = 1,
        elements = {
            { element = menu_elements.enable_aoe_mode, label = "Enable AoE Mode" },
        }
    })

    tab:slider_list({
        label = "Target Detection",
        elements = {
            slider_entry(menu_elements.aoe_target_threshold, "Min Targets for AoE", "", 2, 10),
        }
    })

    tab:checkbox_grid({
        label = "AoE Spells",
        columns = 2,
        elements = {
            { element = menu_elements.use_blizzard, label = "Use Blizzard" },
            { element = menu_elements.use_flamestrike, label = "Use Flamestrike" },
            { element = menu_elements.use_coc, label = "Use Cone of Cold" },
        }
    })

    tab:checkbox_grid({
        label = "Survival (AoE)",
        columns = 2,
        elements = {
            { element = menu_elements.use_ice_barrier_aoe, label = "Maintain Ice Barrier" },
            { element = menu_elements.use_mana_shield_aoe, label = "Maintain Mana Shield" },
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
-- RENDER & UPDATE
-- ============================================================================

local f1_key_was_pressed = false
local aoe_key_was_pressed = false
local pvp_toggle_key_was_pressed = false
local pvp_burst_key_was_pressed = false
local last_rotation_tick_ms = 0
local last_automation_tick_ms = 0
local AUTOMATION_TICK_MS = 500 -- Run automation scanning once every 0.5s

function mage:on_update(local_player)
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

    -- Toggle PvP Burst Mode with keybind
    if menu_elements.pvp_burst_hotkey and menu_elements.pvp_burst_hotkey:get_key_code() ~= 999 then
        local pvp_burst_key_down = menu_elements.pvp_burst_hotkey:get_state() == true
        if pvp_burst_key_down and not pvp_burst_key_was_pressed then
            local current_state = menu_elements.enable_pvp_burst:get_state()
            local new_state = not current_state
            if menu_elements.enable_pvp_burst.set then
                menu_elements.enable_pvp_burst:set(new_state)
            elseif menu_elements.enable_pvp_burst.set_state then
                menu_elements.enable_pvp_burst:set_state(new_state)
            end
            core.log("[Mage] PvP Burst Mode: " .. (new_state and "Enabled" or "Disabled"))
        end
        pvp_burst_key_was_pressed = pvp_burst_key_down
    end

    -- Toggle PvP Mode with keybind
    if menu_elements.pvp_toggle_key and menu_elements.pvp_toggle_key:get_key_code() ~= 999 then
        local pvp_key_down = menu_elements.pvp_toggle_key:get_state() == true
        if pvp_key_down and not pvp_toggle_key_was_pressed then
            local current_state = menu_elements.enable_pvp_mode:get_state()
            local new_state = not current_state
            if menu_elements.enable_pvp_mode.set then
                menu_elements.enable_pvp_mode:set(new_state)
            elseif menu_elements.enable_pvp_mode.set_state then
                menu_elements.enable_pvp_mode:set_state(new_state)
            end
            core.log("[Mage] PvP Mode: " .. (new_state and "Enabled" or "Disabled"))
        end
        pvp_toggle_key_was_pressed = pvp_key_down
    end

    -- Toggle AoE Mode with keybind
    if menu_elements.aoe_toggle_key and menu_elements.aoe_toggle_key:get_key_code() ~= 999 then
        local aoe_key_down = menu_elements.aoe_toggle_key:get_state() == true
        if aoe_key_down and not aoe_key_was_pressed then
            local current_state = menu_elements.enable_aoe_mode:get_state()
            local new_state = not current_state
            if menu_elements.enable_aoe_mode.set then
                menu_elements.enable_aoe_mode:set(new_state)
            elseif menu_elements.enable_aoe_mode.set_state then
                menu_elements.enable_aoe_mode:set_state(new_state)
            end
            core.log("[Mage] AoE Mode: " .. (new_state and "Enabled" or "Disabled"))
        end
        aoe_key_was_pressed = aoe_key_down
    end

	    if not local_player then return end
	    if rotation_pause.is_eating_or_drinking(local_player) then return end
	    if not menu_elements.enable_script_check:get_state() then return end

	    local rotation_enabled = plugin_helper:is_toggle_enabled(menu_elements.enable_toggle) == true
	    if rotation_enabled and not local_player:is_mounted() then
	        local now = core.game_time()
            local is_pvp = menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode:get_state()
            local tick_rate = is_pvp and (menu_elements.pvp_rotation_tick_rate and menu_elements.pvp_rotation_tick_rate:get() or 30) or 100
	        if (now - last_rotation_tick_ms) >= tick_rate then
	            last_rotation_tick_ms = now
	            rotation_logic:execute(local_player, menu_elements)
	        end
	    end

    -- Automation (runs once every 0.5s to save CPU)
    local now = core.game_time()
    if (now - last_automation_tick_ms) >= AUTOMATION_TICK_MS then
        last_automation_tick_ms = now
        auto_skinning:on_update(local_player, menu_elements)
        auto_loot:on_update(local_player, menu_elements)
        auto_mining:on_update(local_player, menu_elements)
        auto_herbing:on_update(local_player, menu_elements)
        auto_quest_interact:on_update(local_player, menu_elements)
        auto_consumables:on_update(local_player, menu_elements)
    end
end

function mage:on_render()
    if settings_ui then settings_ui:on_render() end
end

function mage:on_menu_render()
    if settings_ui then settings_ui:on_menu_render() end

    menu_elements.main_tree:render("Mage Rotation", function()
        local ui_toggle_key_name = "F1"
        if menu_elements.ui_toggle_hotkey and menu_elements.ui_toggle_hotkey.get_key_code then
            local key_code = menu_elements.ui_toggle_hotkey:get_key_code()
            ui_toggle_key_name = key_helper:get_key_name(key_code) or "F1"
        end
        md.header():render("Press " .. ui_toggle_key_name .. " to toggle Custom UI", color.new(100, 200, 255, 255))

        menu_elements.enable_script_check:render("Enable Script")
        menu_elements.enable_toggle:render("Enable Toggle (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ")")

        if settings_ui and settings_ui.menu and settings_ui.menu.enable then
            settings_ui.menu.enable:render("Show Custom UI Window")
        end
    end)
end

function mage:on_control_panel_render()
    local elements = {}
    control_panel_helper:insert_toggle(elements, {
        name = "Mage Rotation (" .. key_helper:get_key_name(menu_elements.enable_toggle:get_key_code()) .. ") ",
        keybind = menu_elements.enable_toggle
    })
    return elements
end

return mage
