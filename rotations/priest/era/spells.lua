-- ============================================================================
-- Priest Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft Classic ERA (1.12) + TBC Pre-Patch (Level 60 Cap)
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
-- All IDs verified for Classic ERA 1.12 + TBC Pre-Patch spells
local spell_ids = {
    -- HEALING SPELLS
    lesser_heal = {2053, 2052, 2050},
    heal = {6064, 6063, 2055, 2054, 2053, 2052, 2050},
    greater_heal = {10965, 10964, 10963, 2060},
    flash_heal = {10917, 10916, 10915, 9474, 9473, 9472, 2061},
    renew = {25315, 25221, 10929, 10928, 10927, 6078, 6077, 6076, 6075, 6074, 139},
    prayer_of_healing = {25316, 10961, 10960, 996, 596},
    desperate_prayer = {19243, 19242, 19241, 19240, 19238, 19236, 13908},
    holy_nova = { 27801, 27800, 27799, 15431, 15430, 15237 },
    
    -- TBC HEALING SPELLS (Available at Level 60 Pre-Patch)
    circle_of_healing = {34866, 34865, 34864, 34863, 34861}, -- Holy Talent (Rank 5 -> 1)

    -- DEFENSIVE / SHIELDS
    power_word_shield = {25217, 25218, 10901, 10900, 10899, 10898, 6066, 6065, 3747, 600, 592, 17},
    inner_fire = {25431, 10952, 10951, 7128, 602, 1006, 588},
    fade = { 10942, 10941, 9592, 9579, 9578, 586 },

    -- BUFFS (Self & Group)
    power_word_fortitude = {25389, 10938, 10937, 2791, 1245, 1244, 1243},
    prayer_of_fortitude = {25392, 21564, 21562},
    divine_spirit = {25312, 27841, 14819, 14818, 14752},
    prayer_of_spirit = {27681, 27681},
    shadow_protection = {25433, 10958, 10957, 976},
    prayer_of_shadow_protection = {27683, 39374},

    -- COOLDOWNS
    power_infusion = {10060},
    inner_focus = {14751},

    -- DISPEL / CLEANSE
    dispel_magic = {988, 527},
    cure_disease = {528},
    abolish_disease = {552},

    -- UTILITY
    fear_ward = {6346},
    psychic_scream = {10890, 10888, 8124, 8122},
    shackle_undead = {10955, 9485, 9484},
    resurrection = {25435, 20770, 10881, 10880, 2010, 2006},

    -- SHADOW / DAMAGE (Solo Leveling & DPS Fallback)
    shadow_word_pain = {25367, 25368, 10894, 10893, 10892, 2767, 992, 970, 594, 589},
    mind_blast = {25375, 25372, 10947, 10946, 10945, 8106, 8105, 8104, 8103, 8102, 8092},
    smite = {25363, 25364, 10934, 10933, 1004, 984, 598, 591, 585},
    holy_fire = { 15261, 15267, 15266, 15265, 15264, 15263, 15262, 14914 },
    mind_flay = {18807, 17314, 17313, 17312, 17311, 15407},
    vampiric_embrace = {15286},
    shadow_form = {15473},
    mana_burn = {10876, 10875, 8129, 8131},
    vampiric_touch = {34917, 34916, 34914}, -- TBC Spell

    -- RACIAL (Night Elf)
    starshards = { 19305, 19304, 19303, 19302, 19299, 19296, 10797 },

    -- WAND
    shoot = {5019},
}

local function init_spell(ids)
    return izi.spell(ids)
end

-- HEALING SPELLS
spells.lesser_heal = init_spell(spell_ids.lesser_heal)
spells.heal = init_spell(spell_ids.heal)
spells.greater_heal = init_spell(spell_ids.greater_heal)
spells.flash_heal = init_spell(spell_ids.flash_heal)
spells.renew = init_spell(spell_ids.renew)
spells.prayer_of_healing = init_spell(spell_ids.prayer_of_healing)
spells.desperate_prayer = init_spell(spell_ids.desperate_prayer)
spells.holy_nova = init_spell(spell_ids.holy_nova)
spells.circle_of_healing = init_spell(spell_ids.circle_of_healing) -- TBC Pre-Patch

-- GREATER HEAL RANKS (for Smart Downranking)
-- rank, id, level, avg_heal
spells.GH_RANKS = {
    { rank = 7, id = 25213, level = 70, heal = 3400 },
    { rank = 5, id = 25314, level = 63, heal = 2500 },
    { rank = 4, id = 10965, level = 58, heal = 2100 },
    { rank = 3, id = 10964, level = 52, heal = 1600 },
    { rank = 2, id = 10963, level = 46, heal = 1200 },
    { rank = 1, id = 2060,  level = 40, heal = 950 },
}

-- Initialize individual rank objects for explicit casting
spells.gh_r1 = init_spell({2060})
spells.gh_r2 = init_spell({10963})
spells.gh_r3 = init_spell({10964})
spells.gh_r4 = init_spell({10965})
spells.gh_r5 = init_spell({25314})
spells.gh_r7 = init_spell({25213})

-- HEAL RANKS (for Smart Downranking)
-- rank, id, level, avg_heal
spells.HEAL_RANKS = {
    { rank = 4, id = 6064, level = 34, heal = 500 },
    { rank = 3, id = 6063, level = 28, heal = 350 },
    { rank = 2, id = 2055, level = 22, heal = 250 },
    { rank = 1, id = 2054, level = 16, heal = 150 },
}

-- Initialize individual rank objects for explicit casting
spells.h_r1 = init_spell({2054})
spells.h_r2 = init_spell({2055})
spells.h_r3 = init_spell({6063})
spells.h_r4 = init_spell({6064})

-- DEFENSIVE / SHIELDS
spells.power_word_shield = init_spell(spell_ids.power_word_shield)
spells.inner_fire = init_spell(spell_ids.inner_fire)
spells.fade = init_spell(spell_ids.fade)

-- BUFFS
spells.power_word_fortitude = init_spell(spell_ids.power_word_fortitude)
spells.prayer_of_fortitude = init_spell(spell_ids.prayer_of_fortitude)
spells.divine_spirit = init_spell(spell_ids.divine_spirit)
spells.prayer_of_spirit = init_spell(spell_ids.prayer_of_spirit)
spells.shadow_protection = init_spell(spell_ids.shadow_protection)
spells.prayer_of_shadow_protection = init_spell(spell_ids.prayer_of_shadow_protection)

-- COOLDOWNS
spells.power_infusion = init_spell(spell_ids.power_infusion)
spells.inner_focus = init_spell(spell_ids.inner_focus)

-- DISPEL / CLEANSE
spells.dispel_magic = init_spell(spell_ids.dispel_magic)
spells.cure_disease = init_spell(spell_ids.cure_disease)
spells.abolish_disease = init_spell(spell_ids.abolish_disease)

-- UTILITY
spells.fear_ward = init_spell(spell_ids.fear_ward)
spells.psychic_scream = init_spell(spell_ids.psychic_scream)
spells.shackle_undead = init_spell(spell_ids.shackle_undead)
spells.resurrection = init_spell(spell_ids.resurrection)

-- SHADOW / DAMAGE
spells.shadow_word_pain = init_spell(spell_ids.shadow_word_pain)
spells.mind_blast = init_spell(spell_ids.mind_blast)
spells.smite = init_spell(spell_ids.smite)
spells.holy_fire = init_spell(spell_ids.holy_fire)
spells.mind_flay = init_spell(spell_ids.mind_flay)
spells.vampiric_embrace = init_spell(spell_ids.vampiric_embrace)
spells.shadow_form = init_spell(spell_ids.shadow_form)
spells.mana_burn = init_spell(spell_ids.mana_burn)
spells.vampiric_touch = init_spell(spell_ids.vampiric_touch)

-- RACIAL (Night Elf)
spells.starshards = init_spell(spell_ids.starshards)

-- WAND
spells.shoot = init_spell(spell_ids.shoot)

function spells:refresh()
    -- No-op: static ID lists do not require refresh.
end

-- ============================================================================
-- BUFF TABLES (For Checking)
-- ============================================================================

-- Renew buff IDs for checking if already applied
spells.RENEW_BUFF_IDS = {25315, 25221, 10929, 10928, 10927, 6078, 6077, 6076, 6075, 6074, 139}

-- Power Word: Shield buff IDs (includes Weakened Soul debuff check)
spells.PWS_BUFF_IDS = {25217, 25218, 10901, 10900, 10899, 10898, 6066, 6065, 3747, 600, 592, 17}

-- Weakened Soul debuff (prevents re-shielding)
spells.WEAKENED_SOUL_ID = 6788

-- Shadowform buff ID (for checking if active)
spells.SHADOWFORM_BUFF_ID = 15473

-- Shoot (Wand) spell ID for channel detection
spells.SHOOT_SPELL_ID = 5019

-- Fortitude buff IDs (all ranks)
spells.FORTITUDE_BUFF_IDS = {25389, 10938, 10937, 2791, 1245, 1244, 1243, 21562, 21564, 25392}

-- Divine Spirit buff IDs (all ranks)
spells.DIVINE_SPIRIT_BUFF_IDS = {25312, 27841, 14819, 14818, 14752, 27681}

-- Inner Fire buff IDs
spells.INNER_FIRE_BUFF_IDS = {25431, 10952, 10951, 7128, 602, 1006, 588}

-- Shadow Protection buff IDs
spells.SHADOW_PROTECTION_BUFF_IDS = {25433, 10958, 10957, 976, 27683, 39374}

-- ============================================================================
-- CLEANSE / DEBUFF TYPES
-- ============================================================================

spells.CLEANSE_TYPES = {
    "Magic",
    "Disease",
}

-- ============================================================================
-- HEALING / MANA THRESHOLDS (Defaults)
-- ============================================================================

spells.DEFAULTS = {
    -- Emergency thresholds
    TANK_EMERGENCY_HP = 30,
    PLAYER_EMERGENCY_HP = 40,
    FLASH_HEAL_HP = 50,
    GREATER_HEAL_HP = 60,
    HEAL_HP = 75,
    
    -- Preventive healing
    RENEW_REFRESH_HP = 85,
    SHIELD_HP = 50,
    
    -- AoE healing
    GROUP_AOE_THRESHOLD = 3,
    AOE_HP_THRESHOLD = 70,
    
    -- Mana management
    MANA_LOW_THRESHOLD = 20,
    MANA_POTION_THRESHOLD = 25,
    
    -- Solo DPS fallback
    SOLO_DPS_MANA_MIN = 50,
    SOLO_DPS_GROUP_HP_MIN = 80,
    
    -- Desperate Prayer threshold
    DESPERATE_PRAYER_HP = 25,
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
-- DOWNRANKING SUPPORT (Spell Rank Tables)
-- ============================================================================

-- Each entry: { id = spell_id, heal_avg = average_healing_amount }
-- Heal amounts are approximate averages for Classic ERA (with ~300-500 +healing)
-- Sorted from lowest to highest rank

spells.HEAL_RANKS = {
    { id = 2050, heal_avg = 60, rank_name = "Lesser Heal Rank 1" },
    { id = 2052, heal_avg = 90, rank_name = "Lesser Heal Rank 2" },
    { id = 2053, heal_avg = 180, rank_name = "Lesser Heal Rank 3" },
    { id = 2054, heal_avg = 330, rank_name = "Heal Rank 2" },
    { id = 2055, heal_avg = 500, rank_name = "Heal Rank 3" },
    { id = 6063, heal_avg = 730, rank_name = "Heal Rank 4" },
    { id = 6064, heal_avg = 1000, rank_name = "Greater Heal Rank 1 (Low)" },
    { id = 2060, heal_avg = 1250, rank_name = "Greater Heal Rank 1" },
    { id = 10963, heal_avg = 1650, rank_name = "Greater Heal Rank 2" },
    { id = 10964, heal_avg = 2100, rank_name = "Greater Heal Rank 3" },
    { id = 10965, heal_avg = 2600, rank_name = "Greater Heal Rank 4" },
}

spells.FLASH_HEAL_RANKS = {
    { id = 2061, heal_avg = 220, rank_name = "Rank 1" },
    { id = 9472, heal_avg = 300, rank_name = "Rank 2" },
    { id = 9473, heal_avg = 380, rank_name = "Rank 3" },
    { id = 9474, heal_avg = 480, rank_name = "Rank 4" },
    { id = 10915, heal_avg = 600, rank_name = "Rank 5" },
    { id = 10916, heal_avg = 750, rank_name = "Rank 6" },
    { id = 10917, heal_avg = 920, rank_name = "Rank 7" },
}

spells.RENEW_RANKS = {
    { id = 139, heal_avg = 60, rank_name = "Rank 1" },
    { id = 6074, heal_avg = 120, rank_name = "Rank 2" },
    { id = 6075, heal_avg = 180, rank_name = "Rank 3" },
    { id = 6076, heal_avg = 270, rank_name = "Rank 4" },
    { id = 6077, heal_avg = 360, rank_name = "Rank 5" },
    { id = 6078, heal_avg = 450, rank_name = "Rank 6" },
    { id = 10927, heal_avg = 560, rank_name = "Rank 7" },
    { id = 10928, heal_avg = 700, rank_name = "Rank 8" },
    { id = 10929, heal_avg = 840, rank_name = "Rank 9" },
    { id = 25221, heal_avg = 970, rank_name = "Rank 10" },
    { id = 25315, heal_avg = 1010, rank_name = "Rank 11" },
}

spells.COH_RANKS = {
    { id = 34861, heal_avg = 360, rank_name = "Rank 1" },
    { id = 34863, heal_avg = 450, rank_name = "Rank 2" },
    { id = 34864, heal_avg = 550, rank_name = "Rank 3" },
    { id = 34865, heal_avg = 650, rank_name = "Rank 4" },
    { id = 34866, heal_avg = 800, rank_name = "Rank 5" },
}

--- Get the best rank of a spell based on HP deficit (for downranking)
--- @param spell_name string The name of the spell ("heal", "flash_heal", "renew", "circle_of_healing")
--- @param deficit number The HP deficit to heal (max_hp - current_hp)
--- @return table|nil Returns { id = spell_id, heal_avg = amount } or nil if not found
function spells:get_best_rank(spell_name, deficit)
    local rank_table = nil
    
    if spell_name == "heal" or spell_name == "greater_heal" then
        rank_table = self.HEAL_RANKS
    elseif spell_name == "flash_heal" then
        rank_table = self.FLASH_HEAL_RANKS
    elseif spell_name == "renew" then
        rank_table = self.RENEW_RANKS
    elseif spell_name == "circle_of_healing" then
        rank_table = self.COH_RANKS
    end
    
    if not rank_table or deficit <= 0 then
        return nil
    end
    
    -- Find the smallest rank that can heal at least the deficit (with 10% buffer)
    local target_heal = deficit * 1.1  -- Add 10% buffer for efficiency
    local best_rank = nil
    
    for _, rank in ipairs(rank_table) do
        -- Check if this rank is learned
        local spell = izi.spell(rank.id)
        if spell and spell:is_learned() then
            best_rank = rank  -- Always update to have at least one valid rank
            if rank.heal_avg >= target_heal then
                return rank  -- This rank can cover the deficit
            end
        end
    end
    
    -- Return the highest learned rank if no rank covers the deficit
    return best_rank
end

return spells

