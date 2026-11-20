-- Spell Data for WoW Classic Era Rogue (Vanilla 1.12)
-- Contains all spell IDs, metadata, and requirements

local spell_data = {}

-- ============================================================================
-- BUILDERS (Combo Point Generators)
-- ============================================================================

spell_data.builders = {
    sinister_strike = {
        ids = {1752, 1757, 1758, 1759, 1760, 8621, 11293, 11294}, -- Ranks 1-8
        name = "Sinister Strike",
        energy_cost = 45,
        cp_generated = 1,
        requires_weapon = "any",
        requires_facing = "front"
    },
    backstab = {
        ids = {53, 2589, 2590, 2591, 8721, 11279, 11280, 11281}, -- Ranks 1-8
        name = "Backstab",
        energy_cost = 60,
        cp_generated = 1,
        requires_weapon = "dagger",
        requires_facing = "behind"
    },
    hemorrhage = {
        ids = {16511}, -- Subtlety Talent (Level 30)
        name = "Hemorrhage",
        energy_cost = 35,
        cp_generated = 1,
        requires_weapon = "any",
        requires_facing = "front",
        is_talent = true
    },
    ghostly_strike = {
        ids = {14278}, -- Combat Talent (Level 30)
        name = "Ghostly Strike",
        energy_cost = 40,
        cp_generated = 1,
        requires_weapon = "any",
        requires_facing = "front",
        is_talent = true
    }
}

-- ============================================================================
-- FINISHERS (Consume Combo Points)
-- ============================================================================

spell_data.finishers = {
    eviscerate = {
        ids = {2098, 6760, 6761, 6762, 8623, 8624, 11299, 11300}, -- Ranks 1-8
        name = "Eviscerate",
        energy_cost = 35,
        cp_required_min = 1,
        cp_required_optimal = 5,
        damage_type = "burst"
    },
    slice_and_dice = {
        ids = {5171, 6774}, -- Ranks 1-2
        name = "Slice and Dice",
        energy_cost = 25,
        cp_required_min = 1,
        cp_required_optimal = 1,
        buff_duration_base = {9, 12, 15, 18, 21}, -- per CP (1-5), in seconds
        buff_type = "attack_speed"
    },
    kidney_shot = {
        ids = {408, 8643}, -- Ranks 1-2
        name = "Kidney Shot",
        energy_cost = 25,
        cp_required_min = 1,
        cp_required_optimal = 5,
        cc_type = "stun",
        stun_duration = {2, 3, 4, 5, 6} -- per CP, in seconds
    },
    rupture = {
        ids = {1943, 8639, 8640, 11273, 11274, 11275}, -- Ranks 1-6
        name = "Rupture",
        energy_cost = 25,
        cp_required_min = 1,
        cp_required_optimal = 5,
        damage_type = "dot"
    },
    expose_armor = {
        ids = {8647, 8649, 8650, 11197, 11198}, -- Ranks 1-5
        name = "Expose Armor",
        energy_cost = 25,
        cp_required_min = 1,
        cp_required_optimal = 5,
        armor_reduction = true,
        duration_base = {30, 30, 30, 30, 30} -- 30 seconds per rank
    }
}

-- ============================================================================
-- CROWD CONTROL
-- ============================================================================

spell_data.cc = {
    gouge = {
        ids = {1776, 1777, 8629, 11285, 11286}, -- Ranks 1-5
        name = "Gouge",
        energy_cost = 45,
        requires_facing = "front",
        incapacitate_duration = 4, -- +1.5s with Improved Gouge talent
        cooldown = 10
    },
    kick = {
        ids = {1766, 1767, 1768, 1769}, -- Ranks 1-4
        name = "Kick",
        energy_cost = 25,
        requires_facing = "front",
        interrupt_duration = 5,
        cooldown = 10
    },
    blind = {
        ids = {2094}, -- Rank 1
        name = "Blind",
        energy_cost = 30,
        blind_duration = 10,
        cooldown = 300, -- 5 minutes
        requires_reagent = true -- Flash Powder
    },
    kidney_shot = {
        ids = {408, 8643}, -- Ranks 1-2
        name = "Kidney Shot",
        energy_cost = 25,
        cp_required_min = 1,
        cp_required_optimal = 5,
        cc_type = "stun",
        stun_duration = {2, 3, 4, 5, 6} -- per CP, in seconds
    }
}

-- ============================================================================
-- DEFENSIVE / REACTIVE ABILITIES
-- ============================================================================

spell_data.defensive = {
    riposte = {
        ids = {14251}, -- Combat Talent (Level 20, requires 5/5 Deflection)
        name = "Riposte",
        energy_cost = 10,
        damage_multiplier = 1.5, -- 150% weapon damage
        disarm_duration = 6,
        cooldown = 6,
        requires_parry = true,
        is_talent = true
    },
    feint = {
        ids = {1966, 6768, 8637, 11303}, -- Ranks 1-4
        name = "Feint",
        energy_cost = 20,
        duration = 10, -- Threat reduction lasts 10 seconds
        threat_reduction_percent = 75, -- Reduces threat by 75% for duration
        level_required = 8
    }
}

-- ============================================================================
-- COOLDOWNS
-- ============================================================================

spell_data.cooldowns = {
    adrenaline_rush = {
        ids = {13750}, -- Combat Talent (Level 40)
        name = "Adrenaline Rush",
        energy_cost = 0,
        duration = 15,
        cooldown = 300, -- 5 minutes
        effect = "100% energy regen",
        is_talent = true
    },
    blade_flurry = {
        ids = {13877}, -- Combat Talent (Level 30)
        name = "Blade Flurry",
        energy_cost = 25,
        duration = 15,
        cooldown = 120, -- 2 minutes
        effect = "cleave attacks",
        is_talent = true
    },
    cold_blood = {
        ids = {14177}, -- Assassination Talent (Level 20)
        name = "Cold Blood",
        energy_cost = 0,
        cooldown = 180, -- 3 minutes
        effect = "100% crit next finisher",
        is_talent = true
    },
    preparation = {
        ids = {14185}, -- Subtlety Talent (Level 31)
        name = "Preparation",
        energy_cost = 0,
        cooldown = 600, -- 10 minutes
        effect = "Resets Vanish, Sprint, Evasion, Cold Blood cooldowns",
        is_talent = true
    },
    vanish = {
        ids = {1856, 1857}, -- Ranks 1-2
        name = "Vanish",
        energy_cost = 0,
        cooldown = 300, -- 5 minutes
        effect = "stealth + threat drop"
    },
    evasion = {
        ids = {5277, 26669}, -- Ranks 1-2
        name = "Evasion",
        energy_cost = 0,
        duration = 15,
        cooldown = 300, -- 5 minutes
        effect = "dodge +50%"
    },
    sprint = {
        ids = {2983, 8696, 11305}, -- Ranks 1-3
        name = "Sprint",
        energy_cost = 0,
        duration = 15,
        cooldown = 300, -- 5 minutes (reduced with talents)
        effect = "movement speed +70%"
    }
}

-- ============================================================================
-- RACIAL ABILITIES (for DPS optimization)
-- ============================================================================

spell_data.racials = {
    blood_fury = {
        ids = {20572}, -- Orc Racial
        name = "Blood Fury",
        energy_cost = 0,
        duration = 15,
        cooldown = 120, -- 2 minutes
        effect = "+25% base melee AP, -5% healing received",
        race = "Orc"
    },
    berserking = {
        ids = {26297}, -- Troll Racial
        name = "Berserking",
        energy_cost = 0,
        duration = 10,
        cooldown = 180, -- 3 minutes
        effect = "+10-30% attack speed based on missing HP",
        race = "Troll"
    },
    will_of_the_forsaken = {
        ids = {7744}, -- Undead Racial
        name = "Will of the Forsaken",
        energy_cost = 0,
        duration = 5,
        cooldown = 120, -- 2 minutes
        effect = "Removes Fear, Charm, Sleep effects (PvP utility)",
        race = "Undead"
    },
    escape_artist = {
        ids = {20589}, -- Gnome Racial
        name = "Escape Artist",
        energy_cost = 0,
        duration = 0,
        cooldown = 60, -- 1 minute
        effect = "Removes movement impairing effects (PvP utility)",
        race = "Gnome"
    },
    stoneform = {
        ids = {20594}, -- Dwarf Racial
        name = "Stoneform",
        energy_cost = 0,
        duration = 8,
        cooldown = 180, -- 3 minutes
        effect = "Removes poison, bleed, disease + 10% armor",
        race = "Dwarf"
    }
}

-- ============================================================================
-- UTILITY ABILITIES
-- ============================================================================

spell_data.utility = {
    pick_pocket = {
        ids = {921}, -- Pick Pocket (no ranks in Classic)
        name = "Pick Pocket",
        energy_cost = 0,
        requires_stealth = true,
        requires_facing = "behind",
        range = 5 -- yards
    }
}

-- ============================================================================
-- CONSUMABLES (Health Potions & Healthstones)
-- ============================================================================

spell_data.consumables = {
    health_potions = {
        -- All ranks in order from weakest to strongest
        {118, "Minor Healing Potion"},       -- Restores 70-90 HP
        {858, "Lesser Healing Potion"},      -- Restores 140-180 HP
        {929, "Healing Potion"},             -- Restores 280-360 HP
        {1710, "Greater Healing Potion"},    -- Restores 455-585 HP
        {3928, "Superior Healing Potion"},   -- Restores 700-900 HP
        {13446, "Major Healing Potion"}      -- Restores 1050-1750 HP
    },
    healthstones = {
        -- All ranks in order from weakest to strongest
        {5512, "Minor Healthstone"},         -- Restores 100 HP
        {5511, "Lesser Healthstone"},        -- Restores 250 HP
        {5509, "Healthstone"},               -- Restores 500 HP
        {19004, "Minor Healthstone"},        -- Alternative ID (Warlock created)
        {19005, "Lesser Healthstone"},       -- Alternative ID
        {19006, "Healthstone"},              -- Alternative ID
        {19007, "Greater Healthstone"},      -- Restores 700 HP
        {19008, "Healthstone"},              -- Alternative ID
        {19009, "Greater Healthstone"},      -- Alternative ID
        {19010, "Major Healthstone"},        -- Restores 900 HP
        {19011, "Greater Healthstone"},      -- Alternative ID
        {19012, "Major Healthstone"},        -- Alternative ID
        {19013, "Major Healthstone"},        -- Alternative ID
        {9421, "Major Healthstone"}          -- Restores 1200 HP
    },
    thistle_tea = {
        item_id = 7676, -- Thistle Tea item ID
        name = "Thistle Tea",
        effect = "Restores 100 energy",
        cooldown = 300, -- 5 minutes
        rogue_only = true
    },
    target_dummies = {
        {4366, "Target Dummy"},
        {4392, "Advanced Target Dummy"},
        {16023, "Masterwork Target Dummy"}
    },
    bandages = {
        -- All ranks in order from weakest to strongest
        {1251, "Linen Bandage"},           -- Restores 66 HP
        {2581, "Heavy Linen Bandage"},     -- Restores 114 HP
        {3530, "Wool Bandage"},            -- Restores 161 HP
        {3531, "Heavy Wool Bandage"},      -- Restores 301 HP
        {6450, "Silk Bandage"},            -- Restores 400 HP
        {6451, "Heavy Silk Bandage"},      -- Restores 640 HP
        {8544, "Mageweave Bandage"},       -- Restores 800 HP
        {8545, "Heavy Mageweave Bandage"}, -- Restores 1104 HP
        {14529, "Runecloth Bandage"},      -- Restores 1360 HP
        {14530, "Heavy Runecloth Bandage"} -- Restores 2000 HP
    }
}

-- ============================================================================
-- BUFFS (for buff_manager checks)
-- ============================================================================

spell_data.buffs = {
    slice_and_dice = {5171, 6774},
    stealth = {1784, 1785, 1786, 1787}, -- Stealth Ranks 1-4
    vanish = {1856, 1857},
    cold_blood = {14177},
    adrenaline_rush = {13750},
    blade_flurry = {13877},
    evasion = {5277, 26669},
    sprint = {2983, 8696, 11305},
    riposte = {14251} -- Riposte available after parry
}

-- ============================================================================
-- DEBUFFS (for target checks)
-- ============================================================================

spell_data.debuffs = {
    rupture = {1943, 8639, 8640, 11273, 11274, 11275},
    garrote = {703, 8631, 8632, 8633, 11289, 11290},
    kidney_shot = {408, 8643}
}

-- ============================================================================
-- DAMAGE OVER TIME EFFECTS (For Bandage Safety)
-- ============================================================================
-- Comprehensive list of DoTs/Bleeds that prevent bandaging
-- Recently Bandaged debuff: 11196 (60 second duration)

spell_data.damage_over_time = {
    -- Rogue Bleeds
    rogue_bleeds = {
        1943, 8639, 8640, 11273, 11274, 11275,  -- Rupture (Ranks 1-6)
        703, 8631, 8632, 8633, 11289, 11290,     -- Garrote (Ranks 1-6)
        16511                                     -- Hemorrhage (Subtlety talent)
    },

    -- Warrior Bleeds
    warrior_bleeds = {
        772, 6546, 6547, 6548, 11572, 11573, 11574,  -- Rend (Ranks 1-7)
        12721                                         -- Deep Wounds (talent proc)
    },

    -- Druid Bleeds/DoTs
    druid_bleeds = {
        1822, 1823, 1824, 9904,                      -- Rake (Ranks 1-4)
        1079, 9492, 9493, 9752, 9894, 9896           -- Rip (Ranks 1-6)
    },
    druid_dots = {
        8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835,  -- Moonfire (Ranks 1-10)
        5570, 24974, 24975, 24976, 24977             -- Insect Swarm (Ranks 1-5, Balance talent)
    },

    -- Warlock DoTs
    warlock_dots = {
        172, 6222, 6223, 7648, 11671, 11672, 25311,  -- Corruption (Ranks 1-7)
        348, 707, 1094, 2941, 11665, 11667, 11668, 25309,  -- Immolate (Ranks 1-8)
        980, 1014, 6217, 11711, 11712, 11713, 27218,  -- Curse of Agony (Ranks 1-7)
        18265                                         -- Siphon Life (talent)
    },

    -- Hunter DoTs
    hunter_dots = {
        1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295  -- Serpent Sting (Ranks 1-9)
    },

    -- Priest DoTs
    priest_dots = {
        589, 594, 970, 992, 2767, 10892, 10893, 10894  -- Shadow Word: Pain (Ranks 1-8)
    },

    -- Dungeon Boss DoTs (expand with comprehensive list from WoWHead)
    dungeon_boss_dots = {
        9573,   -- Whirlwind (Herod - Scarlet Monastery)
        9438,   -- Fervor (Mograine - Scarlet Monastery)
        7068,   -- Veil of Shadow (Fenrus - Shadowfang Keep)
        8599,   -- Enrage (Death's Head Adept - Razorfen Kraul)
        6524,   -- Ground Tremor (Crowd Pummeler - Gnomeregan)
        8138,   -- Slow (Twilight Lord Kelris - Blackfathom Deeps)
        8142    -- Serpent Form (Druid of the Fang - Wailing Caverns)
    }
}

-- Helper function to get all DoT IDs as flat array
function spell_data.get_all_dot_ids()
    local all_dots = {}
    for _, ids in pairs(spell_data.damage_over_time) do
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                table.insert(all_dots, id)
            end
        end
    end
    return all_dots
end

return spell_data
