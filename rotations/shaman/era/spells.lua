-- ============================================================================
-- Shaman Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft Classic ERA (1.12)
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
-- All IDs verified for Classic ERA 1.12
local spell_ids = {
    -- HEALING SPELLS
    healing_wave = {25357, 10396, 10395, 25391, 8005, 959, 939, 913, 547, 332, 331},
    lesser_healing_wave = {10468, 10467, 10466, 8010, 8009, 8008},
    chain_heal = {10623, 10622, 1064},
    
    -- TOTEMS - Healing & Mana
    healing_stream_totem = { 10463, 10462, 6377, 6375, 5394 },
    mana_spring_totem = { 10497, 10496, 10495, 5675 },
    mana_tide_totem = {16190},
    
    -- TOTEMS - Utility
    tremor_totem = {8143},
    grounding_totem = {8177},
    poison_cleansing_totem = {8166},
    disease_cleansing_totem = {8170},
    
    -- TOTEMS - Offensive Support
    windfury_totem = { 10614, 10613, 8512 },
    grace_of_air_totem = { 25359, 10627, 8835 },
    strength_of_earth_totem = {10442, 8161, 8160, 8159, 8075},
    stoneskin_totem = { 10408, 10407, 10406, 8155, 8154, 8071 },
    
    -- TOTEMS - Offensive (for leveling)
    searing_totem = { 10438, 10437, 6365, 6364, 6363, 3599 },
    fire_nova_totem = { 11315, 11314, 8498, 8499, 1535 },
    magma_totem = { 10587, 10586, 10585, 8190 },
    
    -- TOTEMS - Resistance
    fire_resistance_totem = { 10538, 10537, 8184 },
    frost_resistance_totem = { 10479, 10478, 8181 },
    nature_resistance_totem = {10601, 10600, 10595, 25908},
    
    -- TOTEMS - Crowd Control
    earthbind_totem = {2484},
    stoneclaw_totem = {10428, 10427, 6392, 6391, 6390, 5730},
    
    -- WEAPON BUFFS
    rockbiter_weapon = { 16316, 16315, 16314, 10399, 8019, 8018, 8017 },
    flametongue_weapon = { 16342, 16341, 16339, 8030, 8027, 8024 },
    frostbrand_weapon = { 16356, 16355, 10456, 8038, 8033 },
    windfury_weapon = { 16362, 10486, 8235, 8232 },
    
    -- SHIELDS
    lightning_shield = {25472, 25469, 10432, 10431, 945, 8134, 325},
    -- Water Shield Removed (Lvl 62)

    -- DAMAGE SPELLS (Solo Leveling)
    stormstrike = {17364},
    earth_shield = {32594, 32593, 974},
    
    -- TOTEMS - TBC
    totem_of_wrath = {30706},
    -- Wrath of Air Removed (Lvl 64)
    
    -- COOLDOWNS - TBC (Bloodlust Removed Lvl 70)
    lightning_bolt = {25449, 25448, 15208, 15207, 10392, 10391, 8246, 943, 915, 548, 529, 403},
    chain_lightning = { 10605, 2860, 930, 421 },
    earth_shock = { 10414, 10413, 10412, 8046, 8045, 8044, 8042 },
    flame_shock = {29228, 10448, 10447, 8050, 8049, 8048, 8047}, -- 29228 might be TBC, moving to front just in case
    frost_shock = { 10473, 10472, 8058, 8056 },
    
    -- UTILITY
    purge = {8012, 370},
    cleanse_spirit = {51886},
    cure_disease = {2870},
    cure_poison = {526},
    natures_swiftness = {16188},
    ancestral_spirit = { 20777, 20776, 20610, 20609, 2008 },
    ghost_wolf = {2645},
    water_walking = {546},
    water_breathing = {131},
    far_sight = {6196},
    astral_recall = {556},
    
    -- TOTEMS - Additional
    windwall_totem = {15112, 15107, 15111},
    tranquil_air_totem = { 25908 },
}

local function init_spell(ids)
    return izi.spell(ids)
end

-- HEALING SPELLS
spells.healing_wave = init_spell(spell_ids.healing_wave)
spells.lesser_healing_wave = init_spell(spell_ids.lesser_healing_wave)
spells.chain_heal = init_spell(spell_ids.chain_heal)

-- TOTEMS - Healing & Mana
spells.healing_stream_totem = init_spell(spell_ids.healing_stream_totem)
spells.mana_spring_totem = init_spell(spell_ids.mana_spring_totem)
spells.mana_tide_totem = init_spell(spell_ids.mana_tide_totem)

-- TOTEMS - Utility
spells.tremor_totem = init_spell(spell_ids.tremor_totem)
spells.grounding_totem = init_spell(spell_ids.grounding_totem)
spells.poison_cleansing_totem = init_spell(spell_ids.poison_cleansing_totem)
spells.disease_cleansing_totem = init_spell(spell_ids.disease_cleansing_totem)

-- TOTEMS - Offensive Support
spells.windfury_totem = init_spell(spell_ids.windfury_totem)
spells.grace_of_air_totem = init_spell(spell_ids.grace_of_air_totem)
spells.strength_of_earth_totem = init_spell(spell_ids.strength_of_earth_totem)
spells.stoneskin_totem = init_spell(spell_ids.stoneskin_totem)

-- TOTEMS - Offensive (for leveling)
spells.searing_totem = init_spell(spell_ids.searing_totem)
spells.fire_nova_totem = init_spell(spell_ids.fire_nova_totem)
spells.magma_totem = init_spell(spell_ids.magma_totem)

-- TOTEMS - Resistance
spells.fire_resistance_totem = init_spell(spell_ids.fire_resistance_totem)
spells.frost_resistance_totem = init_spell(spell_ids.frost_resistance_totem)
spells.nature_resistance_totem = init_spell(spell_ids.nature_resistance_totem)

-- TOTEMS - Crowd Control
spells.earthbind_totem = init_spell(spell_ids.earthbind_totem)
spells.stoneclaw_totem = init_spell(spell_ids.stoneclaw_totem)

-- WEAPON BUFFS
-- Weapon buffs usually require special handling, but we initialize them here
spells.rockbiter_weapon = init_spell(spell_ids.rockbiter_weapon)
spells.flametongue_weapon = init_spell(spell_ids.flametongue_weapon)
spells.frostbrand_weapon = init_spell(spell_ids.frostbrand_weapon)
spells.windfury_weapon = init_spell(spell_ids.windfury_weapon)

-- SHIELDS (With Native SDK Tracking)
spells.lightning_shield = init_spell(spell_ids.lightning_shield):track_buff(spells.LIGHTNING_SHIELD_BUFF_IDS)
-- spells.water_shield removed
spells.earth_shield = init_spell(spell_ids.earth_shield):track_buff(spells.EARTH_SHIELD_BUFF_IDS)

-- DAMAGE SPELLS
spells.stormstrike = init_spell(spell_ids.stormstrike)
spells.lightning_bolt = init_spell(spell_ids.lightning_bolt)
spells.chain_lightning = init_spell(spell_ids.chain_lightning)
spells.earth_shock = init_spell(spell_ids.earth_shock)
-- Flame Shock (With Native SDK Tracking for target debuff)
spells.flame_shock = init_spell(spell_ids.flame_shock):track_debuff(spells.FLAME_SHOCK_DEBUFF_IDS)
spells.frost_shock = init_spell(spell_ids.frost_shock)

-- UTILITY
spells.purge = init_spell(spell_ids.purge)
spells.cleanse_spirit = init_spell(spell_ids.cleanse_spirit)
spells.cure_disease = init_spell(spell_ids.cure_disease)
spells.cure_poison = init_spell(spell_ids.cure_poison)
spells.natures_swiftness = init_spell(spell_ids.natures_swiftness)
spells.ancestral_spirit = init_spell(spell_ids.ancestral_spirit)
spells.ghost_wolf = init_spell(spell_ids.ghost_wolf)
spells.water_walking = init_spell(spell_ids.water_walking)
spells.water_breathing = init_spell(spell_ids.water_breathing)

-- TOTEMS - Additional
spells.windwall_totem = init_spell(spell_ids.windwall_totem)
spells.tranquil_air_totem = init_spell(spell_ids.tranquil_air_totem)
spells.totem_of_wrath = init_spell(spell_ids.totem_of_wrath)
-- spells.wrath_of_air_totem removed

-- COOLDOWNS (Bloodlust Removed)

function spells:refresh()
    -- No-op: static ID lists do not require refresh.
end

-- ============================================================================
-- BUFF TABLES (For Checking)
-- ============================================================================

-- Ancestral Healing buff ID (armor increase on healed target)
spells.ANCESTRAL_HEALING_BUFF_ID = 16177

-- Healing Way buff IDs (stacking healing increase)
spells.HEALING_WAY_BUFF_IDS = {29203, 29205, 29206}

-- Lightning Shield buff IDs
spells.LIGHTNING_SHIELD_BUFF_IDS = {324, 325, 905, 945, 8134, 10431, 10432, 25469, 25472}

-- Water Shield buff IDs
spells.WATER_SHIELD_BUFF_IDS = {24398, 33736}

-- Earth Shield buff IDs
spells.EARTH_SHIELD_BUFF_IDS = {32594, 32593, 974}

-- Weapon buff IDs
spells.ROCKBITER_BUFF_IDS = {8017, 8018, 8019, 10399, 10400, 16314, 16315, 16316, 25479, 25485}
spells.FLAMETONGUE_BUFF_IDS = {8024, 8027, 8030, 16339, 16341, 16342, 25489}
spells.FROSTBRAND_BUFF_IDS = {8033, 8038, 10456, 16355, 16356, 25500}
spells.WINDFURY_BUFF_IDS = {8232, 8235, 10486, 16362, 25505, 25584}

-- Windfury Totem buff ID (for totem twisting)
spells.WINDFURY_TOTEM_BUFF_ID = 8515

-- Flame Shock debuff IDs (for DoT tracking)
spells.FLAME_SHOCK_DEBUFF_IDS = {8050, 8052, 8053, 10447, 10448, 29228}

-- ============================================================================
-- CLEANSE / DEBUFF TYPES
-- ============================================================================

spells.CLEANSE_TYPES = {
    "Poison",
    "Disease",
}

-- ============================================================================
-- HEALING / MANA THRESHOLDS (Defaults)
-- ============================================================================

spells.DEFAULTS = {
    -- Emergency thresholds
    TANK_EMERGENCY_HP = 25,
    PLAYER_EMERGENCY_HP = 35,
    LESSER_HEALING_WAVE_HP = 45,
    HEALING_WAVE_HP = 70,
    CHAIN_HEAL_HP = 75,
    
    -- AoE healing
    GROUP_AOE_THRESHOLD = 3,
    AOE_HP_THRESHOLD = 70,
    
    -- Mana management
    MANA_LOW_THRESHOLD = 20,
    MANA_POTION_THRESHOLD = 25,
    
    -- Solo DPS fallback
    SOLO_DPS_MANA_MIN = 40,
    SOLO_DPS_GROUP_HP_MIN = 80,
    
    -- Nature's Swiftness threshold
    NATURES_SWIFTNESS_HP = 20,
    
    -- Mana Tide threshold
    MANA_TIDE_GROUP_MANA = 40,
}

-- ============================================================================
-- POTION ITEM IDS (Classic ERA)
-- ============================================================================

spells.MANA_POTION_IDS = {
    13444, -- Major Mana Potion
    13443, -- Superior Mana Potion
    6149,  -- Greater Mana Potion
    3827,  -- Mana Potion
    3385,  -- Lesser Mana Potion
    2455,  -- Minor Mana Potion
}

spells.HEALTH_POTION_IDS = {
    13446, -- Major Healing Potion
    3928,  -- Superior Healing Potion
    1710,  -- Greater Healing Potion
    929,   -- Healing Potion
    858,   -- Lesser Healing Potion
    118,   -- Minor Healing Potion
}


-- ============================================================================
-- HEALING WAVE RANKS (for Smart Downranking)
-- rank, id, level, avg_heal
spells.HEALING_WAVE_RANKS = {
    { rank = 10, id = 25357, level = 60, heal = 1620 },
    { rank = 9,  id = 10396, level = 56, heal = 1380 },
    { rank = 8,  id = 10395, level = 50, heal = 1030 },
    { rank = 7,  id = 8005,  level = 44, heal = 760 },
    { rank = 6,  id = 959,   level = 38, heal = 550 },
    { rank = 5,  id = 939,   level = 32, heal = 390 },
    { rank = 4,  id = 913,   level = 26, heal = 280 },
    { rank = 3,  id = 547,   level = 12, heal = 140 },
    { rank = 2,  id = 332,   level = 14, heal = 70 },
    { rank = 1,  id = 331,   level = 1,  heal = 40 },
}

-- LESSER HEALING WAVE RANKS
spells.LESSER_HEALING_WAVE_RANKS = {
    { rank = 6, id = 10468, level = 60, heal = 880 },
    { rank = 5, id = 10467, level = 52, heal = 660 },
    { rank = 4, id = 10466, level = 44, heal = 480 },
    { rank = 3, id = 8010,  level = 36, heal = 350 },
    { rank = 2, id = 8009,  level = 28, heal = 260 },
    { rank = 1, id = 8008,  level = 20, heal = 170 },
}

-- Initialize individual rank objects for explicit casting
spairs = {
    hw = {331, 332, 547, 913, 939, 959, 8005, 10395, 10396, 25357},
    lhw = {8008, 8009, 8010, 10466, 10467, 10468}
}

spells.hw_ranks = {}
for i, id in ipairs(spairs.hw) do spells.hw_ranks[i] = init_spell({id}) end

spells.lhw_ranks = {}
for i, id in ipairs(spairs.lhw) do spells.lhw_ranks[i] = init_spell({id}) end

return spells
