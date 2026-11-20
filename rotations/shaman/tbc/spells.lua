-- ============================================================================
-- Shaman Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft TBC Classic (2.4.3)
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function init_spell(ids)
    return izi.spell(ids)
end

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
local spell_ids = {
    -- HEALING SPELLS
    healing_wave = { 25357, 10396, 10395, 25391, 8005, 959, 939, 913, 547, 332, 331 },
    lesser_healing_wave = { 25420, 10468, 10467, 10466, 8010, 8009, 8008 },
    chain_heal = { 25423, 25422, 10623, 10622, 1064 },
    earth_shield = { 33735, 32593, 974 }, -- TBC Ranks: Rank 3(70), Rank 2(60), Rank 1(50)
    
    -- TOTEMS - Water (Healing & Mana)
    healing_stream_totem = { 25537, 25567, 10463, 10462, 10461, 6377, 6375, 5394 },
    mana_spring_totem = { 25536, 25570, 10497, 10496, 10495, 10494, 10493, 10491, 5675, 5570 },
    mana_tide_totem = { 16190 },
    poison_cleansing_totem = { 8166 },
    disease_cleansing_totem = { 8170 },
    fire_resistance_totem = { 25563, 10538, 10537, 8184 }, -- Rank 4(68)/3(58)/2(42)/1(28)
    
    -- TOTEMS - Fire (Offensive Support)
    totem_of_wrath = { 30706 }, -- Elemental Capstone
    searing_totem = { 25533, 10438, 10437, 6365, 6364, 6363, 3599 }, -- Rank 7(69)/6(60)/5(50)/4(40)/3(30)/2(20)/1(10)
    fire_nova_totem = { 25547, 25546, 11315, 11314, 8498, 8499, 1535 }, -- Rank 7(70)/6(61)/5(52)/4(42)/3(32)/2(22)/1(12)
    magma_totem = { 25532, 25552, 10587, 10586, 10585, 10584, 8190, 8189 },
    fire_elemental_totem = { 2894 },
    flametongue_totem = { 25529, 25557, 16387, 16342, 16341, 10526, 8227, 8222, 8249, 10399, 8194 },
    frost_resistance_totem = { 25560, 10479, 10478, 8181 }, -- Rank 4(67)/3(54)/2(38)/1(24)
    
    -- TOTEMS - Earth (Utility & Tank)
    strength_of_earth_totem = { 25528, 25361, 10442, 8161, 8160, 8159, 8075 },
    stoneskin_totem = { 25509, 25508, 10408, 10407, 10406, 8155, 8154, 8071 }, -- Rank 8(70)/7(63)/6(54)/5(44)/4(34)/3(24)/2(14)/1(4)
    tremor_totem = { 8143 },
    earthbind_totem = { 2484 },
    stoneclaw_totem = { 25525, 10428, 10427, 6392, 6391, 6390, 5730 },
    earth_elemental_totem = { 2062 },
    
    -- TOTEMS - Air (Caster & Melee Support)
    windfury_totem = { 25587, 25585, 10614, 10613, 8512 }, -- Rank 5(70)/4(61)/3(52)/2(42)/1(32)
    grace_of_air_totem = { 25535, 25359, 10627, 8836, 8835 },
    wrath_of_air_totem = { 30708, 3738 },
    grounding_totem = { 8177 },
    tranquil_air_totem = { 25908 },
    windwall_totem = { 25577, 15112, 15111, 15107 },
    nature_resistance_totem = { 25574, 10601, 10600, 10595 }, -- Rank 4(69)/3(60)/2(44)/1(30)
    sentry_totem = { 6495 },
    
    -- WEAPON BUFFS (TBC Classic - Highest Rank First)
    rockbiter_weapon = { 25500, 25485, 16316, 16315, 10399, 8019, 8018, 8017 }, -- TBC Rank 9/8/.../1
    flametongue_weapon = { 25489, 16342, 16341, 16311, 16310, 16309, 10456, 8030, 8027, 8024 }, -- TBC Rank 7/.../1
    frostbrand_weapon = { 25501, 25500, 16356, 16355, 16354, 16353, 10458, 8033 }, -- TBC Rank 6/.../1
    windfury_weapon = { 25505, 16362, 16361, 16360, 8235, 8232 }, -- TBC Rank 5 (25505, level 68) / 4 / 3 / 2 / 1
    
    -- SHIELDS
    lightning_shield = { 25472, 25469, 10432, 10431, 945, 8134, 325 },
    water_shield = { 33736, 24398 },
    
    -- DAMAGE SPELLS
    lightning_bolt = { 25449, 25448, 15208, 15207, 10392, 10391, 8246, 943, 915, 548, 529, 403 },
    chain_lightning = { 25442, 10605, 10604, 2860, 930, 421 },
    earth_shock = { 25454, 10414, 10413, 10412, 8046, 8045, 8044, 8042, 8041 },
    flame_shock = { 25457, 29228, 10448, 10447, 8050, 8049, 8048, 8047 },
    frost_shock = { 25464, 10473, 10472, 8058, 8056, 8050 },
    stormstrike = { 17364 },
    
    -- COOLDOWNS
    bloodlust = { 2825 },
    heroism = { 32182 },
    natures_swiftness = { 16188 },
    elemental_mastery = { 16166 },
    shamanistic_rage = { 30823 },
    
    -- UTILITY
    purge = { 8012, 370 },
    cleanse_spirit = { 51886 }, -- TBC Cleanse
    cure_disease = { 2870 },
    cure_poison = { 526 },
    ancestral_spirit = { 25590, 20776, 20777, 10880, 2008, 2011 },
    ghost_wolf = { 2645 },
    water_walking = { 546 },
    water_breathing = { 131 },
    totemic_call = { 36936 },

    -- RACIALS
    blood_fury = { 20572 },
    berserking = { 26297, 26296, 20554 },
    war_stomp = { 20549 },
    stoneform = { 20594 },
    gift_of_the_naaru = { 28880 },
}

-- Initialize primary spell objects
for name, ids in pairs(spell_ids) do
    spells[name] = init_spell(ids)
    -- Also export the raw ID table for matching
    spells[name .. "_ids"] = ids
end

-- HEALING WAVE RANKS (for Smart Downranking)
spells.HEALING_WAVE_RANKS = {
    { rank = 12, id = 25357, level = 70, heal = 2800 },
    { rank = 11, id = 25355, level = 63, heal = 2200 },
    { rank = 10, id = 10396, level = 60, heal = 1800 },
    { rank = 9,  id = 10395, level = 54, heal = 1450 },
    { rank = 8,  id = 8005,  level = 48, heal = 1100 },
    { rank = 7,  id = 959,   level = 42, heal = 850 },
    { rank = 6,  id = 939,   level = 36, heal = 600 },
    { rank = 5,  id = 913,   level = 30, heal = 450 },
    { rank = 4,  id = 8004,  level = 24, heal = 320 },
    { rank = 3,  id = 332,   level = 18, heal = 160 },
    { rank = 2,  id = 331,   level = 12, heal = 80 },
    { rank = 1,  id = 331,   level = 1,  heal = 40 },
}

-- LESSER HEALING WAVE RANKS
spells.LESSER_HEALING_WAVE_RANKS = {
    { rank = 7, id = 25420, level = 66, heal = 1200 },
    { rank = 6, id = 10468, level = 60, heal = 950 },
    { rank = 5, id = 10467, level = 52, heal = 750 },
    { rank = 4, id = 10466, level = 44, heal = 550 },
    { rank = 3, id = 8010,  level = 36, heal = 400 },
    { rank = 2, id = 8009,  level = 28, heal = 280 },
    { rank = 1, id = 8008,  level = 20, heal = 180 },
}

-- Initialize individual rank objects for smart selection
spells.hw_ranks = {}
for _, data in ipairs(spells.HEALING_WAVE_RANKS) do
    spells.hw_ranks[data.rank] = izi.spell(data.id)
end

spells.lhw_ranks = {}
for _, data in ipairs(spells.LESSER_HEALING_WAVE_RANKS) do
    spells.lhw_ranks[data.rank] = izi.spell(data.id)
end

-- ============================================================================
-- BUFF/DEBUFF TRACKING
-- ============================================================================

spells.LIGHTNING_SHIELD_IDS = spell_ids.lightning_shield
spells.WATER_SHIELD_IDS = spell_ids.water_shield
spells.EARTH_SHIELD_IDS = spell_ids.earth_shield
spells.FLAME_SHOCK_IDS = spell_ids.flame_shock

-- Totem Buff IDs for tracking presence
spells.SOE_BUFF_IDS = { 25528, 10442, 8161, 8160, 8159, 8075 }
spells.STONESKIN_BUFF_IDS = { 25509, 10408, 10407, 10406, 8155, 8154, 8072 }
spells.WF_BUFF_IDS = { 8515 } -- The temporary weapon imbue given by the totem
spells.GOA_BUFF_IDS = { 25359, 10627, 8836, 8835 }
spells.WOA_BUFF_IDS = { 3738 }
spells.TOW_BUFF_IDS = { 30706 }
spells.HST_BUFF_IDS = { 25567, 10463, 10462, 10461, 6377, 6375, 5394 }
spells.MST_BUFF_IDS = { 25570, 10497, 10496, 10495, 10494, 5675, 5570 }

-- ============================================================================
-- SMART RANK SELECTION
-- ============================================================================

--- Get the best rank of a spell based on HP deficit
function spells:get_best_rank(spell_name, deficit)
    if deficit == nil or deficit <= 0 then return nil end
    
    local target_heal = deficit * 1.05 -- Buffer
    local rank_table = nil
    local rank_objects = nil
    
    if spell_name == "healing_wave" then
        rank_table = self.HEALING_WAVE_RANKS
        rank_objects = self.hw_ranks
    elseif spell_name == "lesser_healing_wave" then
        rank_table = self.LESSER_HEALING_WAVE_RANKS
        rank_objects = self.lhw_ranks
    end
    
    if not rank_table then return nil end
    
    local best_rank = nil
    for i = #rank_table, 1, -1 do
        local data = rank_table[i]
        local obj = rank_objects[data.rank]
        if obj and obj:is_learned() then
            best_rank = { id = data.id, heal_avg = data.heal, rank_name = "Rank " .. data.rank, spell = obj }
            if data.heal >= target_heal then
                return best_rank
            end
        end
    end
    
    return best_rank
end

function spells:refresh()
    -- No-op for static IDs
end

-- Default Thresholds
spells.DEFAULTS = {
    TANK_EMERGENCY_HP = 30,
    PLAYER_EMERGENCY_HP = 35,
    LHW_HP = 50,
    HW_HP = 75,
    CHAIN_HEAL_HP = 80,
    EARTH_SHIELD_HP = 90,
    MANA_LOW = 25,
    NATURES_SWIFTNESS_HP = 20,
    SHAMANISTIC_RAGE_MANA = 30,
}

return spells
