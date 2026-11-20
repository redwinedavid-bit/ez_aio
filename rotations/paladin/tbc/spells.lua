-- ============================================================================
-- Paladin Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft TBC Classic (lists may include extra IDs; unused IDs are ignored)
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
        27136, 10329, 10328, 10330, 10331,
        3474, 3473, 3472, 1914, 1913, 635
    },

    flash_of_light = {
        27137, 19943, 19942, 19941,
        19940, 19939, 19751, 19750
    },

    holy_shock = {
        25903, 20960, 20958, 20930, 20929, 20473
    },

    divine_favor = { 20216 },


    -- DAMAGE / THREAT
    judgement = {
        20271
    },

    exorcism = {
        27138, 10314, 10313, 10312, 5615, 5614, 879
    },

    consecration = {
        27173, 20924, 20923, 20922, 20116
    },

    hammer_of_wrath = {
        27180, 24275, 24274, 24239
    },


    -- TBC CORE / SPEC
    crusader_strike     = { 35395 },
    avenging_wrath      = { 31884 },
    avengers_shield     = { 31935 },
    arcane_torrent      = { 28730, 25046 },
    righteous_defense   = { 31789 },
    divine_illumination = { 31842 },
    holy_wrath          = { 27139, 10318 },

    perception          = { 20600 },
    stoneform           = { 20594 },
    gift_of_the_naaru   = { 28880 },


    -- SEALS
    seal_of_righteousness = {
        27155, 20293, 20292, 20291,
        20290, 20289, 20288, 20287, 20154, 21084
    },

    -- TBC Ret twist seal:
    -- - 31892: Seal of Blood (Blood Elf/TBC)
    -- - 53720: Seal of the Martyr (alt/server databases)
    -- - 348700: TBC Classic tracking ID used by some clients/tools
    seal_of_blood         = { 348700, 53720, 31892 },
    seal_of_vengeance     = { 31801 },

    seal_of_command       = {
        27170,
        20947, 20946, 20945, 20944,
        20920, 20919, 20918, 20915,
        20424, 20375
    },

    -- Rank 1 for Seal Twisting (lower mana)
    seal_of_command_r1    = { 20375 },

    seal_of_wisdom        = {
        27166,
        20461, 20460, 20459, 20357, 20356,
        20351, 20350, 20168, 20166
    },

    seal_of_light         = {
        27160,
        20458, 20457, 20456, 20455,
        20349, 20348, 20347, 20340,
        20334, 20333, 20167, 20165
    },

    seal_of_justice       = { 31895, 20462, 20164 },

    seal_of_the_crusader  = {
        27158,
        21083, 21082, 20448, 20447, 20446,
        20445, 20444, 20308, 20307,
        20306, 20305, 20162
    },


    -- BUFFS / DEFENSIVES
    righteous_fury         = { 25781, 25780, 20450 },

    holy_shield            = {
        27179, 20957, 20956, 20955,
        20928, 20927, 20925
    },

    divine_shield          = { 13874, 642 },
    divine_protection      = { 27779, 498 },

    blessing_of_protection = { 10279, 10278, 5600, 5599, 1911, 1022 },
    blessing_of_freedom    = { 1909, 1044 },
    blessing_of_sacrifice  = { 20730, 20729, 6941, 6940 },

    lay_on_hands           = {
        20236, 20233, 17233, 10311,
        10310, 9257, 2804, 2800,
        1878, 633
    },


    -- CLEANSE
    cleanse = { 28788, 28787, 4987 },
    purify = { 1152 },


    -- AURAS
    devotion_aura = {
        17232, 10297, 10296, 10295,
        10294, 10293, 10292, 10291,
        10290, 8258, 1877, 1876,
        1875, 1032, 643, 465
    },

    retribution_aura = {
        13008, 10305, 10304, 10303,
        10302, 10301, 10300, 10299,
        10298, 8990, 7296, 7294
    },

    concentration_aura = { 19747, 19746 },

    crusader_aura = { 32223 },


    -- BLESSINGS
    blessing_of_might = {
        27140, 25291,
        19838, 19837, 19836, 19835, 19834,
        19740, 19741
    },

    blessing_of_wisdom = {
        25961, 25398, 25290,
        19858, 19857, 19856,
        19855, 19854, 19853,
        19852, 19850
    },

    blessing_of_kings = { 20217 },

    blessing_of_sanctuary = {
        20951, 20950, 20949, 20948,
        20914, 20913, 20912, 20911
    },

    blessing_of_salvation = { 25939, 25895, 1912, 1038 },

    blessing_of_light = {
        26650, 19997, 19996,
        19995, 19979, 19978, 19977
    },


    -- CROWD CONTROL
    hammer_of_justice = {
        13005, 10309, 10308,
        5591, 5590, 5589,
        5588, 5584, 853
    },

    repentance = { 20066 }

}

-- Healing
spells.holy_light = init_spell(spell_ids.holy_light)
spells.flash_of_light = init_spell(spell_ids.flash_of_light)
spells.holy_shock = init_spell(spell_ids.holy_shock)
spells.divine_favor = init_spell(spell_ids.divine_favor)

-- Explicit downrank anchors (rank 1 / lowest)
spells.flash_of_light_r1 = izi.spell(19750)
spells.consecration_r1 = izi.spell(20116)
spells.holy_shield_r1 = izi.spell(20925)

-- Damage / threat
spells.judgement = init_spell(spell_ids.judgement)
spells.exorcism = init_spell(spell_ids.exorcism)
spells.consecration = init_spell(spell_ids.consecration)
spells.hammer_of_wrath = init_spell(spell_ids.hammer_of_wrath)
spells.crusader_strike = init_spell(spell_ids.crusader_strike)
spells.avenging_wrath = init_spell(spell_ids.avenging_wrath)
spells.avengers_shield = init_spell(spell_ids.avengers_shield)
spells.arcane_torrent = init_spell(spell_ids.arcane_torrent)
spells.righteous_defense = init_spell(spell_ids.righteous_defense)
spells.divine_illumination = init_spell(spell_ids.divine_illumination)
spells.holy_wrath = init_spell(spell_ids.holy_wrath)
spells.perception = init_spell(spell_ids.perception)
spells.stoneform = init_spell(spell_ids.stoneform)
spells.gift_of_the_naaru = init_spell(spell_ids.gift_of_the_naaru)

-- Seals
spells.seal_of_righteousness = init_spell(spell_ids.seal_of_righteousness)
spells.seal_of_blood = init_spell(spell_ids.seal_of_blood)
spells.seal_of_vengeance = init_spell(spell_ids.seal_of_vengeance)
spells.seal_of_command = init_spell(spell_ids.seal_of_command)
spells.seal_of_command_r1 = init_spell(spell_ids.seal_of_command_r1)
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
spells.crusader_aura = init_spell(spell_ids.crusader_aura)

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
spells.SEAL_OF_BLOOD_IDS = spell_ids.seal_of_blood
spells.SEAL_OF_VENGEANCE_IDS = spell_ids.seal_of_vengeance
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
spells.AURA_CRUSADER_IDS = spell_ids.crusader_aura

-- Blessing aura IDs also need to include "Greater" variants so we don't overwrite them.
spells.BLESSING_MIGHT_IDS = merge_ids(spell_ids.blessing_of_might, { 27141, 25782, 25916 })
spells.BLESSING_WISDOM_IDS = merge_ids(spell_ids.blessing_of_wisdom, { 25894, 25918 })
spells.BLESSING_KINGS_IDS = merge_ids(spell_ids.blessing_of_kings, { 25898 })
spells.BLESSING_SANCTUARY_IDS = merge_ids(spell_ids.blessing_of_sanctuary, { 25899 })
spells.BLESSING_SALVATION_IDS = merge_ids(spell_ids.blessing_of_salvation, { 25895 })
spells.BLESSING_LIGHT_IDS = merge_ids(spell_ids.blessing_of_light, { 25890 })

spells.FORBEARANCE_DEBUFF_IDS = { 25771 }

-- Judgement debuff IDs (for target checks; seal-specific judgement application)
-- NOTE: 456496 is non-standard (not a known TBC ID) — may be custom/private-server; kept for compat
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
