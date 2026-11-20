-- ============================================================================
-- Priest Spells - Simple ID Lists (Highest Rank First)
-- World of Warcraft TBC Classic (2.4.3) (lists may include extra IDs; unused IDs are ignored)
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
    lesser_heal = { 2053, 2052, 2050 },
    heal = { 6064, 6063, 2055, 2054 },
    greater_heal = { 25213, 25210, 25314, 10965, 10964, 10963, 2060 },
    flash_heal = { 25235, 25233, 10917, 10916, 10915, 9474, 9473, 9472, 2061 },
    renew = { 25222, 25221, 25315, 10929, 10928, 10927, 6078, 6077, 6076, 6075, 6074, 139 },
    prayer_of_healing = { 25308, 25316, 10961, 10960, 996, 596 },
    prayer_of_mending = { 33076, 41635, 351575 },
    binding_heal = { 32546 },
    desperate_prayer = { 25437, 19243, 19240, 19238, 19236, 13908, 5634, 5637, 5639, 5638, 5635, 5636 },
    holy_nova = { 25331, 25329, 27801, 23455, 23458, 23457, 15431, 15430, 15237 },

    -- TALENTS / HEALING (TBC)
    circle_of_healing = { 34866, 34865, 34864, 34863, 34861, 41455 },
    pain_suppression = { 33206, 44416 },

    -- DEFENSIVE / SHIELDS
    power_word_shield = { 25218, 25217, 10901, 10900, 10899, 10898, 6066, 6065, 3747, 600, 592, 17 },
    inner_fire = { 25431, 10952, 10951, 7128, 602, 1006, 588 },
    fade = { 25429, 10942, 10941, 9592, 9579, 9578, 586 },

    -- BUFFS (Self & Group)
    power_word_fortitude = { 25389, 10938, 10937, 2791, 1245, 1244, 1243, 23948, 23947 },
    prayer_of_fortitude = { 25392, 21564, 21562, 39231 },
    divine_spirit = { 25312, 27841, 14819, 14818, 14752, 39234 },
    prayer_of_spirit = { 27681, 32999 },
    shadow_protection = { 25433, 10958, 10957, 976, 7244, 7243, 7241, 7235 },
    prayer_of_shadow_protection = { 27683, 39374, 39236 },

    -- COOLDOWNS
    power_infusion = { 10060, 37274 },
    inner_focus = { 14751 },
    shadowfiend = { 34433 },

    -- DISPEL / CLEANSE
    dispel_magic = { 27609, 988, 527 },
    cure_disease = { 528, 28133 },
    abolish_disease = { 552 },
    mass_dispel = { 32375, 4526, 32592, 39897, 38082, 353184 },

    -- UTILITY
    fear_ward = { 6346 },
    psychic_scream = { 27610, 10890, 10888, 8124, 8122 },
    shackle_undead = { 10955, 9485, 9484 },
    resurrection = { 25435, 20770, 10881, 10880, 2010, 2006 },
    mana_burn = { 25380, 25379, 10876, 10875, 8129, 8131 },
    silence = { 15487 },

    -- SHADOW / DAMAGE
    shadow_word_pain = { 25368, 25367, 10894, 10893, 10892, 2767, 992, 970, 594, 589 },
    mind_blast = { 25375, 25372, 10947, 10946, 10945, 8106, 8105, 8104, 8103, 8102, 8092 },
    mind_flay = { 25387, 18807, 17314, 17313, 17312, 17311, 15407 },
    vampiric_embrace = { 15286, 15290 },
    vampiric_touch = { 34917, 34916, 34914 },
    shadow_word_death = { 32996, 32379, 32409 },
    shadow_form = { 15473, 16592 },
    devouring_plague = { 25467, 19280, 19279, 19278, 19277, 19276, 2944, 5644, 5646, 5679 },
    touch_of_weakness = { 25461, 19266, 19264, 19261, 2652, 10379, 5662, 5660, 5661, 5658 },

    -- HOLY / DAMAGE (Leveling fallback, never in Shadowform)
    smite = { 25364, 25363, 10934, 10933, 6060, 1004, 984, 598, 591, 585 },
    holy_fire = { 25384, 15261, 15266, 15265, 15262, 15260, 14914 },

    -- RACIAL (Night Elf / Troll)
    starshards = { 25446, 19305, 19304, 19303, 19302, 19299, 19296, 16568, 10797, 10796, 10002, 22822, 22823 },
    shadow_guard = { 25471, 19312, 19311, 19310, 19309, 19308, 18137 },

    -- WAND
    shoot = { 5019 },
}

-- Healing
spells.lesser_heal = init_spell(spell_ids.lesser_heal)
spells.heal = init_spell(spell_ids.heal)
spells.greater_heal = init_spell(spell_ids.greater_heal)
spells.flash_heal = init_spell(spell_ids.flash_heal)
spells.renew = init_spell(spell_ids.renew)
spells.prayer_of_healing = init_spell(spell_ids.prayer_of_healing)
spells.prayer_of_mending = init_spell(spell_ids.prayer_of_mending)
spells.binding_heal = init_spell(spell_ids.binding_heal)
spells.desperate_prayer = init_spell(spell_ids.desperate_prayer)
spells.holy_nova = init_spell(spell_ids.holy_nova)
spells.circle_of_healing = init_spell(spell_ids.circle_of_healing)

-- GREATER HEAL RANKS (for Smart Downranking)
-- rank, id, level, avg_heal (rough heuristic; used only for rank selection)
spells.GH_RANKS = {
    { rank = 7, id = 25213, level = 70, heal = 3400 },
    { rank = 6, id = 25210, level = 68, heal = 3000 },
    { rank = 5, id = 25314, level = 63, heal = 2500 },
    { rank = 4, id = 10965, level = 58, heal = 2100 },
    { rank = 3, id = 10964, level = 52, heal = 1600 },
    { rank = 2, id = 10963, level = 46, heal = 1200 },
    { rank = 1, id = 2060, level = 40, heal = 950 },
}

-- Initialize individual rank objects for explicit casting
spells.gh_r1 = izi.spell(2060)
spells.gh_r2 = izi.spell(10963)
spells.gh_r3 = izi.spell(10964)
spells.gh_r4 = izi.spell(10965)
spells.gh_r5 = izi.spell(25314)
spells.gh_r6 = izi.spell(25210)
spells.gh_r7 = izi.spell(25213)

-- HEAL RANKS (for Smart Downranking)
-- rank, id, level, avg_heal (rough heuristic)
spells.HEAL_RANKS = {
    { rank = 4, id = 6064, level = 34, heal = 500 },
    { rank = 3, id = 6063, level = 28, heal = 350 },
    { rank = 2, id = 2055, level = 22, heal = 250 },
    { rank = 1, id = 2054, level = 16, heal = 150 },
}

-- Initialize individual rank objects for explicit casting
spells.h_r1 = izi.spell(2054)
spells.h_r2 = izi.spell(2055)
spells.h_r3 = izi.spell(6063)
spells.h_r4 = izi.spell(6064)

-- Defensive / utility
spells.power_word_shield = init_spell(spell_ids.power_word_shield)
spells.inner_fire = init_spell(spell_ids.inner_fire)
spells.fade = init_spell(spell_ids.fade)
spells.pain_suppression = init_spell(spell_ids.pain_suppression)

-- Buffs
spells.power_word_fortitude = init_spell(spell_ids.power_word_fortitude)
spells.prayer_of_fortitude = init_spell(spell_ids.prayer_of_fortitude)
spells.divine_spirit = init_spell(spell_ids.divine_spirit)
spells.prayer_of_spirit = init_spell(spell_ids.prayer_of_spirit)
spells.shadow_protection = init_spell(spell_ids.shadow_protection)
spells.prayer_of_shadow_protection = init_spell(spell_ids.prayer_of_shadow_protection)

-- Cooldowns
spells.power_infusion = init_spell(spell_ids.power_infusion)
spells.inner_focus = init_spell(spell_ids.inner_focus)
spells.shadowfiend = init_spell(spell_ids.shadowfiend)

-- Dispel
spells.dispel_magic = init_spell(spell_ids.dispel_magic)
spells.cure_disease = init_spell(spell_ids.cure_disease)
spells.abolish_disease = init_spell(spell_ids.abolish_disease)
spells.mass_dispel = init_spell(spell_ids.mass_dispel)

-- Utility
spells.fear_ward = init_spell(spell_ids.fear_ward)
spells.psychic_scream = init_spell(spell_ids.psychic_scream)
spells.shackle_undead = init_spell(spell_ids.shackle_undead)
spells.resurrection = init_spell(spell_ids.resurrection)
spells.mana_burn = init_spell(spell_ids.mana_burn)
spells.silence = init_spell(spell_ids.silence)

-- Shadow / damage
spells.shadow_word_pain = init_spell(spell_ids.shadow_word_pain)
spells.swp_r1 = izi.spell(589)
spells.mind_blast = init_spell(spell_ids.mind_blast)
spells.mind_flay = init_spell(spell_ids.mind_flay)
spells.vampiric_embrace = init_spell(spell_ids.vampiric_embrace)
spells.vampiric_touch = init_spell(spell_ids.vampiric_touch)
spells.shadow_word_death = init_spell(spell_ids.shadow_word_death)
spells.shadow_form = init_spell(spell_ids.shadow_form)
spells.devouring_plague = init_spell(spell_ids.devouring_plague)
spells.touch_of_weakness = init_spell(spell_ids.touch_of_weakness)

-- Holy / damage (leveling)
spells.smite = init_spell(spell_ids.smite)
spells.holy_fire = init_spell(spell_ids.holy_fire)

-- Racials
spells.starshards = init_spell(spell_ids.starshards)
spells.shadow_guard = init_spell(spell_ids.shadow_guard)

-- Wand
spells.shoot = init_spell(spell_ids.shoot)

function spells:refresh()
    -- No-op: static ID lists do not require refresh.
end

-- ============================================================================
-- BUFF/DEBUFF TABLES (For Checking)
-- ============================================================================

spells.RENEW_BUFF_IDS = spell_ids.renew
spells.PWS_BUFF_IDS = spell_ids.power_word_shield
spells.POM_BUFF_IDS = spell_ids.prayer_of_mending

-- Weakened Soul debuff (prevents re-shielding)
spells.WEAKENED_SOUL_ID = 6788

-- Shadowform buff ID (for checking if active)
spells.SHADOWFORM_BUFF_IDS = spell_ids.shadow_form

-- Pain Suppression buff ID (for checking if active)
spells.PAIN_SUPPRESSION_BUFF_IDS = spell_ids.pain_suppression

-- Dot / debuff IDs
spells.SWP_DEBUFF_IDS = spell_ids.shadow_word_pain
spells.VT_DEBUFF_IDS = spell_ids.vampiric_touch
spells.VE_DEBUFF_IDS = spell_ids.vampiric_embrace
spells.DP_DEBUFF_IDS = spell_ids.devouring_plague

-- Shoot (Wand) spell ID for channel detection
spells.SHOOT_SPELL_ID = 5019

-- Fortitude buff IDs (all ranks)
spells.FORTITUDE_BUFF_IDS = { 25389, 10938, 10937, 2791, 1245, 1244, 1243, 21562, 21564, 25392, 23948, 23947, 39231 }

-- Divine Spirit buff IDs (all ranks)
spells.DIVINE_SPIRIT_BUFF_IDS = { 25312, 27841, 14819, 14818, 14752, 27681, 39234, 32999 }

-- Inner Fire buff IDs
spells.INNER_FIRE_BUFF_IDS = spell_ids.inner_fire

-- Shadow Protection buff IDs
spells.SHADOW_PROTECTION_BUFF_IDS = { 25433, 10958, 10957, 976, 27683, 39374, 39236 }
spells.SHADOW_GUARD_BUFF_IDS = spell_ids.shadow_guard
spells.TOUCH_OF_WEAKNESS_BUFF_IDS = spell_ids.touch_of_weakness

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

    -- Shadowfiend
    SHADOWFIEND_MANA_THRESHOLD = 25,

    -- Shadow Word: Death safety
    SWD_MIN_HP = 35,

    -- Solo DPS fallback
    SOLO_DPS_MANA_MIN = 50,
    SOLO_DPS_GROUP_HP_MIN = 80,

    -- Desperate Prayer threshold
    DESPERATE_PRAYER_HP = 25,
}

-- ============================================================================
-- POTION ITEM IDS (TBC Classic)
-- ============================================================================

spells.MANA_POTION_IDS = {
    22832, -- Super Mana Potion
    13444, -- Major Mana Potion
    13443, -- Superior Mana Potion
    6149, -- Greater Mana Potion
    3827, -- Mana Potion
    3385, -- Lesser Mana Potion
    2455, -- Minor Mana Potion
}

spells.HEALTH_POTION_IDS = {
    22829, -- Super Healing Potion
    13446, -- Major Healing Potion
    3928, -- Superior Healing Potion
    1710, -- Greater Healing Potion
    929, -- Healing Potion
    858, -- Lesser Healing Potion
    118, -- Minor Healing Potion
}

-- ============================================================================
-- DOWNRANKING SUPPORT (Spell Rank Tables)
-- ============================================================================

-- Sorted from lowest to highest rank.
-- Values are rough heuristics used only for rank selection (they don't need to be exact).

spells.FLASH_HEAL_RANKS = {
    { id = 2061, heal_avg = 220, rank_name = "Rank 1" },
    { id = 9472, heal_avg = 300, rank_name = "Rank 2" },
    { id = 9473, heal_avg = 380, rank_name = "Rank 3" },
    { id = 9474, heal_avg = 480, rank_name = "Rank 4" },
    { id = 10915, heal_avg = 600, rank_name = "Rank 5" },
    { id = 10916, heal_avg = 750, rank_name = "Rank 6" },
    { id = 10917, heal_avg = 920, rank_name = "Rank 7" },
    { id = 25233, heal_avg = 1100, rank_name = "Rank 8" },
    { id = 25235, heal_avg = 1300, rank_name = "Rank 9" },
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
    { id = 25222, heal_avg = 1050, rank_name = "Rank 11" },
}

spells.COH_RANKS = {
    { id = 34861, heal_avg = 360, rank_name = "Rank 1" },
    { id = 34863, heal_avg = 450, rank_name = "Rank 2" },
    { id = 34864, heal_avg = 550, rank_name = "Rank 3" },
    { id = 34865, heal_avg = 650, rank_name = "Rank 4" },
    { id = 34866, heal_avg = 800, rank_name = "Rank 5" },
}

--- Get the best rank of a spell based on HP deficit (for downranking)
--- @param spell_name string The name of the spell ("heal", "greater_heal", "flash_heal", "renew", "circle_of_healing")
--- @param deficit number The HP deficit to heal (max_hp - current_hp)
--- @return table|nil Returns { id = spell_id, heal_avg = amount, rank_name = string } or nil if not found
function spells:get_best_rank(spell_name, deficit)
    if deficit == nil or deficit <= 0 then
        return nil
    end

    local target_heal = deficit * 1.1

    -- Heal/Greater Heal use the existing TBC smart-downrank tables:
    -- spells.HEAL_RANKS and spells.GH_RANKS (shape: { rank, id, level, heal })
    if spell_name == "heal" then
        local best_rank = nil
        for i = #self.HEAL_RANKS, 1, -1 do
            local rank = self.HEAL_RANKS[i]
            local spell = izi.spell(rank.id)
            if spell and spell:is_learned() then
                best_rank = { id = rank.id, heal_avg = rank.heal, rank_name = "Heal Rank " .. tostring(rank.rank) }
                if rank.heal >= target_heal then
                    return best_rank
                end
            end
        end
        return best_rank
    end

    if spell_name == "greater_heal" then
        local best_rank = nil
        for i = #self.GH_RANKS, 1, -1 do
            local rank = self.GH_RANKS[i]
            local spell = izi.spell(rank.id)
            if spell and spell:is_learned() then
                best_rank = { id = rank.id, heal_avg = rank.heal, rank_name = "Greater Heal Rank " .. tostring(rank.rank) }
                if rank.heal >= target_heal then
                    return best_rank
                end
            end
        end
        return best_rank
    end

    local rank_table = nil
    if spell_name == "flash_heal" then
        rank_table = self.FLASH_HEAL_RANKS
    elseif spell_name == "renew" then
        rank_table = self.RENEW_RANKS
    elseif spell_name == "circle_of_healing" then
        rank_table = self.COH_RANKS
    end

    if not rank_table then
        return nil
    end

    local best_rank = nil
    for _, rank in ipairs(rank_table) do
        local spell = izi.spell(rank.id)
        if spell and spell:is_learned() then
            best_rank = rank
            if rank.heal_avg >= target_heal then
                return rank
            end
        end
    end

    return best_rank
end

return spells
