-- ============================================================================
-- Mage Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft Classic ERA
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function init_spell(ids)
    return izi.spell(ids)
end

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
local spell_ids = {
    -- FROST
    frostbolt = { 25304, 10181, 10180, 10179, 8408, 8407, 8406, 7322, 837, 205, 116 },
    cone_of_cold = { 10161, 10160, 10159, 12611, 120 },
    frost_nova = { 10230, 6131, 865, 122 },
    blizzard = { 10187, 10186, 10185, 8427, 8364, 10 },
    
    -- FIRE
    fireball = { 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133 },
    scorch = { 10207, 10206, 10205, 8446, 8445, 8444, 2948 },
    fire_blast = { 10199, 10197, 8413, 8412, 2138, 2137, 2136 },
    pyroblast = { 18809, 12526, 12525, 12524, 12523, 12522, 12505, 11366 },
    flamestrike = { 10216, 10215, 8423, 8422, 2121, 2120 },
    blast_wave = { 11113 },
    
    -- ARCANE
    arcane_missiles = { 25345, 10212, 10211, 8417, 8416, 5145, 5144, 5143 },
    arcane_explosion = { 10202, 10201, 8442, 8441, 8439, 8438, 8437, 1449 },
    
    -- BUFFS / ARMORS
    mage_armor = { 22783, 22782, 6117 },
    ice_armor = { 10220, 10219, 7320, 7302, 7301, 7300, 168 },
    frost_armor = { 7302, 7301, 7300, 168 }, -- Low level fallback
    arcane_intellect = { 10157, 10156, 1461, 1460, 1459 },
    arcane_brilliance = { 23028 }, -- Group buff
    dampen_magic = { 10174, 10173, 8451, 8450, 604 },
    amplify_magic = { 10170, 10169, 8455, 1008 },
    
    -- COOLDOWNS / TALENTS
    arcane_power = { 12042 },
    presence_of_mind = { 12043 },
    combustion = { 11129 },
    cold_snap = { 12472 },
    evocation = { 12051 },
    
    -- UTILITY
    polymorph = { 12826, 12825, 12824, 118 }, -- Rank 1-4
    counterspell = { 2139 },
    remove_curse = { 475 },
    blink = { 1953 },
    ice_block = { 11958 }, -- Ice Block cast button
    cold_snap = { 12472 },
    
    -- CONJURE
    conjure_water = { 10140, 10139, 10138, 6127, 5506, 5505, 5504 },
    conjure_food = { 28612, 10145, 10144, 6129, 990, 597, 587 },
    conjure_mana_ruby = { 10054 },
    conjure_mana_citrine = { 10053 },
    conjure_mana_jade = { 5602 },
    conjure_mana_agate = { 5601 },
    
    -- DEFENSIVE
    mana_shield = { 10193, 10192, 10191, 1463 },
    ice_barrier = { 11426 }, -- Talent
}

-- Initialize spells
spells.frostbolt = init_spell(spell_ids.frostbolt)
spells.cone_of_cold = init_spell(spell_ids.cone_of_cold)
spells.frost_nova = init_spell(spell_ids.frost_nova)
spells.blizzard = init_spell(spell_ids.blizzard)

spells.fireball = init_spell(spell_ids.fireball)
spells.scorch = init_spell(spell_ids.scorch)
spells.fire_blast = init_spell(spell_ids.fire_blast)
spells.pyroblast = init_spell(spell_ids.pyroblast)
spells.flamestrike = init_spell(spell_ids.flamestrike)
spells.blast_wave = init_spell(spell_ids.blast_wave)

spells.arcane_missiles = init_spell(spell_ids.arcane_missiles)
spells.arcane_explosion = init_spell(spell_ids.arcane_explosion)

spells.mage_armor = init_spell(spell_ids.mage_armor)
spells.ice_armor = init_spell(spell_ids.ice_armor)
spells.fallback_armor = init_spell(spell_ids.frost_armor)

spells.arcane_intellect = init_spell(spell_ids.arcane_intellect)
spells.arcane_brilliance = init_spell(spell_ids.arcane_brilliance)

spells.arcane_power = init_spell(spell_ids.arcane_power)
spells.presence_of_mind = init_spell(spell_ids.presence_of_mind)
spells.combustion = init_spell(spell_ids.combustion)
spells.cold_snap = init_spell(spell_ids.cold_snap)
spells.evocation = init_spell(spell_ids.evocation)

spells.counterspell = init_spell(spell_ids.counterspell)
spells.remove_curse = init_spell(spell_ids.remove_curse)
spells.ice_block = init_spell(spell_ids.ice_block)
spells.polymorph = init_spell(spell_ids.polymorph)
spells.blink = init_spell(spell_ids.blink)
spells.mana_shield = init_spell(spell_ids.mana_shield)
spells.ice_barrier = init_spell(spell_ids.ice_barrier)

-- CONJURE
spells.conjure_water = init_spell(spell_ids.conjure_water)
spells.conjure_food = init_spell(spell_ids.conjure_food)
spells.conjure_mana_ruby = init_spell(spell_ids.conjure_mana_ruby)
spells.conjure_mana_citrine = init_spell(spell_ids.conjure_mana_citrine)
spells.conjure_mana_jade = init_spell(spell_ids.conjure_mana_jade)
spells.conjure_mana_agate = init_spell(spell_ids.conjure_mana_agate)
spells.conjure_mana_gem = init_spell({ 10054, 10053, 5602, 5601 }) -- All ranks for easy selection

-- DOWNRANKING (Rank 1 Spells)
spells.frostbolt_r1 = init_spell({ 116 })
spells.cone_of_cold_r1 = init_spell({ 120 })
spells.frost_nova_r1 = init_spell({ 122 })
spells.blizzard_r1 = init_spell({ 10 })
spells.arcane_explosion_r1 = init_spell({ 1449 })
spells.fire_blast_r1 = init_spell({ 2136 })
spells.fireball_r1 = init_spell({ 133 })

-- ============================================================================
-- BUFF/DEBUFF TRACKING (Using arrays like Priest does)
-- ============================================================================

-- Improved Scorch (on target) - stacks up to 5
spells.IMPROVED_SCORCH_DEBUFF_ID = 22959 

-- Winter's Chill (on target) - stacks up to 5
spells.WINTERS_CHILL_DEBUFF_ID = 12579

-- Clearcasting (on self)
spells.CLEARCASTING_BUFF_ID = 12536
spells.CLEARCASTING_BUFF_IDS = { 12536 }

-- Buff ID Arrays for Armor check (all ranks)
spells.MAGE_ARMOR_BUFF_ID = 22782
spells.MAGE_ARMOR_BUFF_IDS = { 22783, 22782, 6117 }

spells.ICE_ARMOR_BUFF_ID = 10220
spells.ICE_ARMOR_BUFF_IDS = { 10220, 10219, 7320, 7302, 7301, 7300, 168 }

spells.FROST_ARMOR_BUFF_ID = 168
spells.FROST_ARMOR_BUFF_IDS = { 7302, 7301, 7300, 168 }

-- Combined all armor buffs for quick check (No Molten in Classic Era)
spells.ALL_ARMOR_BUFF_IDS = { 
    22783, 22782, 6117, -- Mage Armor
    10220, 10219, 7320, 7302, 7301, 7300, 168 -- Ice/Frost Armor
}

-- Intellect buff IDs (all ranks)
spells.ARCANE_INTELLECT_BUFF_IDS = { 10157, 10156, 1461, 1460, 1459 }
spells.ARCANE_BRILLIANCE_BUFF_IDS = { 23028, 10157, 10156 }
spells.ALL_INTELLECT_BUFF_IDS = { 23028, 10157, 10156, 1461, 1460, 1459 }

-- Cooldown Buffs
spells.ARCANE_POWER_BUFF_ID = 12042
spells.ARCANE_POWER_BUFF_IDS = { 12042 }
spells.COMBUSTION_BUFF_ID = 11129
spells.COMBUSTION_BUFF_IDS = { 11129 }

-- Defensive/AoE Buffs
spells.ICE_BARRIER_BUFF_IDS = { 11426, 13031, 13032, 13033 }
spells.MANA_SHIELD_BUFF_IDS = { 1463, 10191, 10192, 10193 }

-- ============================================================================
-- ITEMS
-- ============================================================================
-- Mana Emeralds (Consumption) - Era doesn't have Emerald (Rank 5)?, highest is Ruby?
-- Rank 4: Mana Ruby.
spells.MANA_GEM_IDS = {
    8008,  -- Mana Ruby
    8007,  -- Mana Citrine
    5513,  -- Mana Jade
    5514,  -- Mana Agate
}

function spells:refresh()
    -- No-op
end

return spells
