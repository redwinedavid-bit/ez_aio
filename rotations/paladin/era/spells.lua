-- ============================================================================
-- Paladin Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft Classic ERA (incl. 1.15.x variants; unused IDs are ignored)
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function init_spell(ids)
    return izi.spell(ids)
end

---@param base_ids integer[]|nil
---@param extra_ids integer[]|nil
---@return integer[]
local function merge_ids(base_ids, extra_ids)
    local out = {}
    for _, id in ipairs(base_ids or {}) do
        table.insert(out, id)
    end
    for _, id in ipairs(extra_ids or {}) do
        table.insert(out, id)
    end
    return out
end

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
local spell_ids = {
    -- HEALING
    holy_light = {
        1236181, 1232709, 1213298, 469566, 25963, 25400, 25292, 25263, 19982, 19981,
        19980, 19968, 15493, 13952, 10331, 10330, 10329, 10328, 3474, 3473, 3472,
        1914, 1913, 1874, 1873, 1872, 1043, 1042, 1027, 1026, 664, 656, 647, 639, 635
    },
    flash_of_light = {
        412020, 25514, 19993, 19948, 19947, 19946, 19945, 19944, 19943, 19942,
        19941, 19940, 19939, 19751, 19750
    },
    holy_shock = { 444894, 25914, 25913, 25912, 25911, 25903, 25902, 20960, 20958, 20930, 20929, 20473 },
    divine_favor = { 20216 },

    -- DAMAGE / THREAT
    judgement = { 23590, 20271, 10321, 3684 },
    exorcism = {
        415073, 415072, 415071, 415070, 415069, 415068, 17149, 17147, 10317, 10316,
        10315, 10314, 10313, 10312, 5617, 5616, 5615, 5614, 5613, 3690, 931, 879, 559
    },
    consecration = {
        1232755, 458286, 458285, 437887, 437884, 368235, 368218, 26574, 26573, 20954,
        20953, 20952, 20924, 20923, 20922, 20116
    },
    hammer_of_wrath = { 429151, 24278, 24277, 24276, 24275, 24274, 24239 },

    -- SEALS
    seal_of_righteousness = {
        25742, 25741, 25740, 25739, 25738, 25737, 25736, 25735, 25713, 21085,
        21084, 20443, 20442, 20441, 20440, 20439, 20438, 20437, 20293, 20292,
        20291, 20290, 20289, 20288, 20287, 20154, 3094, 3093, 864
    },
    seal_of_command = { 20947, 20946, 20945, 20944, 20920, 20919, 20918, 20915, 20424, 20375 },
    seal_of_wisdom = { 20461, 20460, 20459, 20357, 20356, 20351, 20350, 20168, 20166, 7327, 3713, 1105 },
    seal_of_light = { 20458, 20457, 20456, 20455, 20349, 20348, 20347, 20340, 20334, 20333, 20167, 20165 },
    seal_of_justice = { 20462, 20164 },
    seal_of_the_crusader = { 21083, 21082, 20448, 20447, 20446, 20445, 20444, 20308, 20307, 20306, 20305, 20162 },

    -- BUFFS / DEFENSIVES
    righteous_fury = { 407628, 407627, 25781, 25780, 20450 },
    holy_shield = { 456544, 20957, 20956, 20955, 20928, 20927, 20925, 9800 },
    divine_shield = { 13874, 1898, 1897, 1021, 1020, 659, 642 },
    divine_protection = { 1213300, 458371, 458312, 27779, 13007, 5574, 5573, 5572, 3697, 735, 498 },
    blessing_of_protection = { 442948, 10279, 10278, 5600, 5599, 1911, 1022 },
    blessing_of_freedom = { 1909, 1044 },
    blessing_of_sacrifice = { 20730, 20729, 6941, 6940 },
    lay_on_hands = { 20236, 20233, 17233, 10311, 10310, 9257, 2804, 2800, 1878, 633 },

    -- CLEANSE
    cleanse = { 28788, 4993, 4990, 4987 },
    purify = { 3725, 1937, 1152 },

    -- AURAS
    devotion_aura = {
        1233344, 17232, 10297, 10296, 10295, 10294, 10293, 10292, 10291, 10290,
        8258, 1877, 1876, 1875, 1032, 643, 465
    },
    retribution_aura = { 1232703, 463621, 449669, 420998, 13008, 10305, 10304, 10303, 10302, 10301, 10300, 10299, 10298, 8990, 7296, 7294 },
    concentration_aura = { 19747, 19746 },

    -- BLESSINGS
    blessing_of_might = {
        25962, 25399, 25291, 19843, 19842, 19841, 19840, 19839, 19838, 19837,
        19836, 19835, 19834, 19741, 19740
    },
    blessing_of_wisdom = {
        25961, 25398, 25290, 19858, 19857, 19856, 19855, 19854, 19853, 19852,
        19850, 19743, 19742
    },
    blessing_of_kings = { 1213408, 20217 },
    blessing_of_sanctuary = { 20951, 20950, 20949, 20948, 20914, 20913, 20912, 20911 },
    blessing_of_salvation = { 25939, 25895, 1912, 1038 },
    blessing_of_light = { 26650, 19997, 19996, 19995, 19979, 19978, 19977 },

    -- CROWD CONTROL
    hammer_of_justice = { 1213301, 13005, 10309, 10308, 5591, 5590, 5589, 5588, 5584, 853 },
    repentance = { 20066 }
}

-- Healing
spells.holy_light = init_spell(spell_ids.holy_light)
spells.flash_of_light = init_spell(spell_ids.flash_of_light)
spells.holy_shock = init_spell(spell_ids.holy_shock)
spells.divine_favor = init_spell(spell_ids.divine_favor)

-- Explicit downrank anchors (rank 1 / lowest)
spells.flash_of_light_r1 = izi.spell(19750)
spells.consecration_r1 = izi.spell(26573)
spells.holy_shield_r1 = izi.spell(20925)

-- Damage / threat
spells.judgement = init_spell(spell_ids.judgement)
spells.exorcism = init_spell(spell_ids.exorcism)
spells.consecration = init_spell(spell_ids.consecration)
spells.hammer_of_wrath = init_spell(spell_ids.hammer_of_wrath)

-- Seals
spells.seal_of_righteousness = init_spell(spell_ids.seal_of_righteousness)
spells.seal_of_command = init_spell(spell_ids.seal_of_command)
spells.seal_of_wisdom = init_spell(spell_ids.seal_of_wisdom)
spells.seal_of_light = init_spell(spell_ids.seal_of_light)
spells.seal_of_justice = init_spell(spell_ids.seal_of_justice)
spells.seal_of_the_crusader = init_spell(spell_ids.seal_of_the_crusader)

-- Buffs / defensives
spells.righteous_fury = init_spell(spell_ids.righteous_fury)
spells.holy_shield = init_spell(spell_ids.holy_shield)
spells.divine_shield = init_spell(spell_ids.divine_shield)
spells.divine_protection = init_spell(spell_ids.divine_protection)
spells.blessing_of_protection = init_spell(spell_ids.blessing_of_protection)
spells.blessing_of_freedom = init_spell(spell_ids.blessing_of_freedom)
spells.blessing_of_sacrifice = init_spell(spell_ids.blessing_of_sacrifice)
spells.lay_on_hands = init_spell(spell_ids.lay_on_hands)

-- Cleanse
spells.cleanse = init_spell(spell_ids.cleanse)
spells.purify = init_spell(spell_ids.purify)

-- Auras
spells.devotion_aura = init_spell(spell_ids.devotion_aura)
spells.retribution_aura = init_spell(spell_ids.retribution_aura)
spells.concentration_aura = init_spell(spell_ids.concentration_aura)

-- Blessings
spells.blessing_of_might = init_spell(spell_ids.blessing_of_might)
spells.blessing_of_wisdom = init_spell(spell_ids.blessing_of_wisdom)
spells.blessing_of_kings = init_spell(spell_ids.blessing_of_kings)
spells.blessing_of_sanctuary = init_spell(spell_ids.blessing_of_sanctuary)
spells.blessing_of_salvation = init_spell(spell_ids.blessing_of_salvation)
spells.blessing_of_light = init_spell(spell_ids.blessing_of_light)

-- Control
spells.hammer_of_justice = init_spell(spell_ids.hammer_of_justice)
spells.repentance = init_spell(spell_ids.repentance)

function spells:refresh()
    -- No-op: static ID lists do not require refresh.
end

-- ============================================================================
-- BUFF/DEBUFF TABLES
-- ============================================================================

spells.SEAL_OF_RIGHTEOUSNESS_IDS = spell_ids.seal_of_righteousness
spells.SEAL_OF_COMMAND_IDS = spell_ids.seal_of_command
spells.SEAL_OF_WISDOM_IDS = spell_ids.seal_of_wisdom
spells.SEAL_OF_LIGHT_IDS = spell_ids.seal_of_light
spells.SEAL_OF_JUSTICE_IDS = spell_ids.seal_of_justice
spells.SEAL_OF_THE_CRUSADER_IDS = spell_ids.seal_of_the_crusader

spells.RIGHTEOUS_FURY_IDS = spell_ids.righteous_fury
spells.HOLY_SHIELD_IDS = spell_ids.holy_shield

spells.AURA_DEVOTION_IDS = spell_ids.devotion_aura
spells.AURA_RETRIBUTION_IDS = spell_ids.retribution_aura
spells.AURA_CONCENTRATION_IDS = spell_ids.concentration_aura

-- Blessing aura IDs also need to include "Greater" variants so we don't overwrite them.
spells.BLESSING_MIGHT_IDS = merge_ids(spell_ids.blessing_of_might, { 25782, 25916 })
spells.BLESSING_WISDOM_IDS = merge_ids(spell_ids.blessing_of_wisdom, { 25894, 25918 })
spells.BLESSING_KINGS_IDS = merge_ids(spell_ids.blessing_of_kings, { 25898 })
spells.BLESSING_SANCTUARY_IDS = merge_ids(spell_ids.blessing_of_sanctuary, { 25899 })
spells.BLESSING_SALVATION_IDS = merge_ids(spell_ids.blessing_of_salvation, { 25895 })
spells.BLESSING_LIGHT_IDS = merge_ids(spell_ids.blessing_of_light, { 25890 })

spells.FORBEARANCE_DEBUFF_IDS = { 25771 }

-- Judgement debuff IDs (for target checks; seal-specific judgement application)
spells.JOTC_DEBUFF_IDS = { 456496, 25943, 25942, 21183, 20303, 20302, 20301, 20300, 20188 }
spells.JOW_DEBUFF_IDS = { 25758, 25757, 20355, 20354, 20353, 20352, 20268, 20186 }
spells.JOL_DEBUFF_IDS = { 28775, 25753, 25752, 20346, 20345, 20344, 20343, 20342, 20341, 20267, 20185 }

spells.DEFAULTS = {
    HP_PANIC_SAFE = 18,
    HP_PANIC = 12,
    HP_EMERGENCY_SAFE = 30,
    HP_EMERGENCY = 20,
    HP_WARNING_SAFE = 45,
    HP_WARNING = 35,
    MANA_LOW_SAVE = 45,
    MANA_LOW = 25,
    MANA_VERY_LOW_SAVE = 25,
    MANA_VERY_LOW = 12,
    AOE_MIN_SAVE = 3,
    AOE_MIN = 2,
    AOE_BIG = 5
}

return spells
