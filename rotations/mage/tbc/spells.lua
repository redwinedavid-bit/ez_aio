-- ============================================================================
-- Mage Spells - Simple ID Lists (Highest Rank First)
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
    -- ARCANE
    arcane_blast = { 30451 },
    arcane_missiles = { 25345, 25344, 10272, 10271, 10269, 10268, 8417, 8416, 5145, 5144 },
    arcane_explosion = { 27082, 27080, 10202, 10201, 8442, 8441, 8439, 8438, 8437, 1449 },
    arcane_barrage = { 44425 }, -- WotLK spell, but keeping just in case/placeholder, likely remove for TBC
    
    -- FIRE
    fireball = { 27070, 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133 },
    scorch = { 27074, 25307, 10207, 10206, 10205, 8446, 8445, 8444, 2948 },
    fire_blast = { 27079, 27078, 10199, 10197, 8434, 8433, 8432, 2138, 2137, 2136 },
    pyroblast = { 27136, 18809, 12526, 12525, 12524, 12523, 12522, 12505, 11366 },
    flamestrike = { 27086, 2121, 2120, 8426, 8423, 8422, 9403, 10216, 10215, 27085 },
    blast_wave = { 27133, 33933, 11113 },
    dragon_breath = { 31661, 33041, 33042, 33043 },
    
    -- FROST
    frostbolt = { 27072, 25304, 10181, 10180, 10179, 8398, 7322, 837, 734, 205, 122, 116 },
    ice_lance = { 30455 },
    cone_of_cold = { 27087, 10161, 10160, 10159, 12611, 120 },
    frost_nova = { 27088, 10230, 865, 6131, 122, 120 },
    blizzard = { 27085, 10187, 10186, 10185, 8427, 8364, 10 },
    
    -- BUFFS / ARMORS
    molten_armor = { 30482 },
    mage_armor = { 27125, 22783, 22782, 6117 },
    ice_armor = { 27124, 10220, 10219, 7302, 7301, 7300, 168 },
    frost_armor = { 7302, 7301, 7300, 168 }, -- Low level fallback
    arcane_intellect = { 27126, 10157, 10156, 8395, 1461, 1460, 1459 },
    arcane_brilliance = { 27127, 23028, 10157, 10156 }, -- Group buff
    dampen_magic = { 25301, 10174, 10173, 8451, 8450, 604 },
    amplify_magic = { 25302, 10170, 10169, 8455, 1008 },
    
    -- COOLDOWNS / TALENTS
    arcane_power = { 12042 },
    presence_of_mind = { 12043 },
    icy_veins = { 12472 },
    combustion = { 11129 },
    cold_snap = { 11958 },
    evocation = { 12051 },
    invisibility = { 66 },
    
    -- PET
    summon_water_elemental = { 31687 },
    
	    -- UTILITY
	    polymorph = { 12826, 12825, 12824, 118 }, -- Rank 1-4
	    counterspell = { 2139 },
	    arcane_torrent = { 28730, 25046 }, -- Blood Elf racial (IDs vary across clients)
	    spellsteal = { 30449 },
	    remove_curse = { 475 },
	    blink = { 1953 },
    ice_block = { 27619, 11958, 45438 }, -- ID 45438 is mostly WotLK/Cata, using generic check usually
    
    -- CONJURE
    conjure_water = { 27090, 10140, 10139, 10138, 8388, 5505, 5504, 5503, 5502, 5501 },
    conjure_food = { 27089, 10145, 10144, 8408, 6418, 1515, 608, 587 },
    conjure_mana_emerald = { 27101, 10054, 10053, 5602, 5601 }, -- Emerald, Ruby, Citrine, Jade, Agate
    conjure_mana_gem = { 27101, 10054, 10053, 5602, 5601 }, -- Mapping all to 'conjure_mana_gem' for ease
}

-- Initialize spells
spells.arcane_blast = init_spell(spell_ids.arcane_blast)
spells.arcane_missiles = init_spell(spell_ids.arcane_missiles)
spells.arcane_explosion = init_spell(spell_ids.arcane_explosion)

spells.fireball = init_spell(spell_ids.fireball)
spells.scorch = init_spell(spell_ids.scorch)
spells.fire_blast = init_spell(spell_ids.fire_blast)
spells.pyroblast = init_spell(spell_ids.pyroblast)
spells.flamestrike = init_spell(spell_ids.flamestrike)
spells.blast_wave = init_spell(spell_ids.blast_wave)
spells.dragon_breath = init_spell(spell_ids.dragon_breath)

spells.frostbolt = init_spell(spell_ids.frostbolt)
spells.ice_lance = init_spell(spell_ids.ice_lance)
spells.cone_of_cold = init_spell(spell_ids.cone_of_cold)
spells.frost_nova = init_spell(spell_ids.frost_nova)
spells.blizzard = init_spell(spell_ids.blizzard)

spells.molten_armor = init_spell(spell_ids.molten_armor)
spells.mage_armor = init_spell(spell_ids.mage_armor)
spells.ice_armor = init_spell(spell_ids.ice_armor)
spells.fallback_armor = init_spell(spell_ids.frost_armor)

spells.arcane_intellect = init_spell(spell_ids.arcane_intellect)
spells.arcane_brilliance = init_spell(spell_ids.arcane_brilliance)

spells.arcane_power = init_spell(spell_ids.arcane_power)
spells.presence_of_mind = init_spell(spell_ids.presence_of_mind)
spells.icy_veins = init_spell(spell_ids.icy_veins)
spells.combustion = init_spell(spell_ids.combustion)
spells.cold_snap = init_spell(spell_ids.cold_snap)
spells.evocation = init_spell(spell_ids.evocation)

spells.summon_water_elemental = init_spell(spell_ids.summon_water_elemental)

spells.counterspell = init_spell(spell_ids.counterspell)
spells.arcane_torrent = init_spell(spell_ids.arcane_torrent)
spells.spellsteal = init_spell(spell_ids.spellsteal)
spells.remove_curse = init_spell(spell_ids.remove_curse)
spells.ice_block = init_spell(spell_ids.ice_block)
spells.polymorph = init_spell(spell_ids.polymorph)
spells.blink = init_spell(spell_ids.blink)

spells.conjure_mana_gem = init_spell(spell_ids.conjure_mana_gem)

-- ============================================================================
-- BUFF/DEBUFF TRACKING (Using arrays like Priest does)
-- ============================================================================

-- Arcane Blast Debuff (on self)
spells.ARCANE_BLAST_DEBUFF_ID = 36032 

-- Improved Scorch (on target) - stacks up to 5
spells.IMPROVED_SCORCH_DEBUFF_ID = 22959

-- Winter's Chill (on target) - stacks up to 5
spells.WINTERS_CHILL_DEBUFF_ID = 12579

-- Clearcasting (on self)
spells.CLEARCASTING_BUFF_ID = 12536

-- Buff ID Arrays for Armor check (all ranks)
spells.MOLTEN_ARMOR_BUFF_ID = 30482
spells.MOLTEN_ARMOR_BUFF_IDS = { 30482 }

spells.MAGE_ARMOR_BUFF_ID = 27125
spells.MAGE_ARMOR_BUFF_IDS = { 27125, 22783, 22782, 6117 }

spells.ICE_ARMOR_BUFF_ID = 27124
spells.ICE_ARMOR_BUFF_IDS = { 27124, 10220, 10219, 7302, 7301, 7300, 168 }

spells.FROST_ARMOR_BUFF_ID = 168
spells.FROST_ARMOR_BUFF_IDS = { 7302, 7301, 7300, 168 }

-- Combined all armor buffs for quick check
spells.ALL_ARMOR_BUFF_IDS = { 
    30482, -- Molten Armor
    27125, 22783, 22782, 6117, -- Mage Armor
    27124, 10220, 10219, 7302, 7301, 7300, 168 -- Ice/Frost Armor
}

-- Intellect buff IDs (all ranks)
spells.ARCANE_INTELLECT_BUFF_IDS = { 27126, 10157, 10156, 8395, 1461, 1460, 1459 }
spells.ARCANE_BRILLIANCE_BUFF_IDS = { 27127, 23028, 10157, 10156 }
spells.ALL_INTELLECT_BUFF_IDS = { 27126, 27127, 23028, 10157, 10156, 8395, 1461, 1460, 1459 }

-- Cooldown Buffs
spells.ARCANE_POWER_BUFF_ID = 12042
spells.ARCANE_POWER_BUFF_IDS = { 12042 }
spells.ICY_VEINS_BUFF_ID = 12472
spells.ICY_VEINS_BUFF_IDS = { 12472 }
spells.COMBUSTION_BUFF_ID = 11129
spells.COMBUSTION_BUFF_IDS = { 11129 }
spells.BLOODLUST_BUFF_ID = 2825
spells.HEROISM_BUFF_ID = 32182

-- Defensive/AoE Buffs
spells.ICE_BARRIER_BUFF_IDS = { 11426, 13031, 13032, 13033, 27134, 33405 }
spells.MANA_SHIELD_BUFF_IDS = { 1463, 10191, 10192, 10193, 27131 }

-- ============================================================================
-- ITEMS
-- ============================================================================
-- Mana Emeralds (Consumption)
spells.MANA_GEM_IDS = {
    22044, -- Mana Emerald
    8008,  -- Mana Ruby
    8007,  -- Mana Citrine
    5513,  -- Mana Jade
    5514,  -- Mana Agate
}

function spells:refresh()
    -- No-op
end

return spells
