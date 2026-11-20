-- ============================================================================
-- Druid Spell Data - Classic ERA (1.12)
-- Comprehensive spell IDs + metadata for all specs
-- ============================================================================

local spell_data = {}
local izi = require("common/izi_sdk")
local game_client = require("shared/game_client")
local is_forever = tostring(game_client.get_game_version_string()):lower():find("forever", 1, true) ~= nil

-- ============================================================================
-- HELPER: Initialize spell from ID array (highest rank first)
-- ============================================================================

local function init_spell(ids)
    return izi.spell(ids)
end

-- ============================================================================
-- FORMS
-- ============================================================================

spell_data.forms = {
    bear_form = {
        ids = {5487},
        spell = nil, -- initialized below
        name = "Bear Form",
        level = 10,
    },
    dire_bear_form = {
        ids = {9634},
        spell = nil,
        name = "Dire Bear Form",
        level = 40,
    },
    cat_form = {
        ids = {768},
        spell = nil,
        name = "Cat Form",
        level = 20,
    },
    travel_form = {
        ids = {783},
        spell = nil,
        name = "Travel Form",
        level = 30,
    },
    aquatic_form = {
        ids = {1066},
        spell = nil,
        name = "Aquatic Form",
        level = 16,
    },
    moonkin_form = {
        ids = {24858},
        spell = nil,
        name = "Moonkin Form",
        level = 40,
        is_talent = true,
    },
}

-- ============================================================================
-- CAT ABILITIES
-- ============================================================================

spell_data.cat = {
    claw = {
        ids = { 9850, 9849, 5201, 3029, 1082 },
        spell = nil,
        name = "Claw",
        energy_cost = 40,
        cp_generated = 1,
        level = 20,
    },
    rake = {
        ids = { 9904, 1824, 1823, 1822 },
        spell = nil,
        name = "Rake",
        energy_cost = 35,
        cp_generated = 1,
        is_dot = true,
        level = 24,
    },
    shred = {
        ids = { 9830, 9829, 8992, 6800, 5221 },
        spell = nil,
        name = "Shred",
        energy_cost = 60,
        cp_generated = 1,
        requires_behind = true,
        level = 22,
    },
    rip = {
        ids = {9896, 9895, 9894, 9752, 1079},
        spell = nil,
        name = "Rip",
        energy_cost = 30,
        is_finisher = true,
        is_dot = true,
        level = 20,
    },
    ferocious_bite = {
        ids = {31018, 22829, 22828, 22827, 22568},
        spell = nil,
        name = "Ferocious Bite",
        energy_cost = 35,
        is_finisher = true,
        level = 32,
    },
    tigers_fury = {
        ids = {9847, 9846, 9845, 1081, 5217},
        spell = nil,
        name = "Tiger's Fury",
        level = 24,
    },
    ravage = {
        ids = { 9867, 9866, 6787, 6785 },
        spell = nil,
        name = "Ravage",
        energy_cost = 60,
        cp_generated = 1,
        requires_stealth = true,
        requires_behind = true,
        level = 32,
    },
    pounce = {
        ids = {9827, 9823, 9005},
        spell = nil,
        name = "Pounce",
        energy_cost = 50,
        cp_generated = 1,
        requires_stealth = true,
        is_stun = true,
        level = 36,
    },
    cower = {
        ids = { 9892, 9000, 8998 },
        spell = nil,
        name = "Cower",
        energy_cost = 20,
        level = 28,
    },
    dash = {
        ids = {1850},
        spell = nil,
        name = "Dash",
        level = 26,
    },
    prowl = {
        ids = {5215},
        spell = nil,
        name = "Prowl",
        level = 20,
    },
    faerie_fire_feral = {
        ids = {17392, 17391, 17390, 16857},
        spell = nil,
        name = "Faerie Fire (Feral)",
        is_talent = true,
        level = 30,
    },
}

-- ============================================================================
-- BEAR ABILITIES
-- ============================================================================

spell_data.bear = {
    maul = {
        ids = { 9881, 9880, 9745, 8972, 6809, 6808, 6807 },
        spell = nil,
        name = "Maul",
        rage_cost = 15,
        is_next_melee = true,
        level = 10,
    },
    swipe = {
        ids = { 9908, 9754, 769, 780, 779 },
        spell = nil,
        name = "Swipe",
        rage_cost = 20,
        is_aoe = true,
        level = 16,
    },
    demoralizing_roar = {
        ids = { 9898, 9747, 9490, 1735, 99 },
        spell = nil,
        name = "Demoralizing Roar",
        rage_cost = 10,
        level = 10,
    },
    growl = {
        ids = {6795},
        spell = nil,
        name = "Growl",
        rage_cost = 0,
        is_taunt = true,
        level = 10,
    },
    bash = {
        ids = {8983, 5211, 4030},
        spell = nil,
        name = "Bash",
        rage_cost = 10,
        is_interrupt = true,
        is_stun = true,
        level = 14,
    },
    enrage = {
        ids = {5229},
        spell = nil,
        name = "Enrage",
        rage_cost = 0,
        level = 18,
    },
    frenzied_regeneration = {
        ids = {22896, 22895, 22842},
        spell = nil,
        name = "Frenzied Regeneration",
        rage_cost = 0,
        level = 36,
    },
    feral_charge = {
        ids = {16979},
        spell = nil,
        name = "Feral Charge",
        rage_cost = 15,
        is_talent = true,
        is_interrupt = true,
        level = 20,
    },
    challenging_roar = {
        ids = {5209},
        spell = nil,
        name = "Challenging Roar",
        rage_cost = 15,
        is_taunt = true,
        is_aoe = true,
        level = 28,
    },
}

-- ============================================================================
-- BALANCE ABILITIES
-- ============================================================================

spell_data.balance = {
    wrath = {
        ids = { 9912, 8905, 6780, 5180, 5179, 5178, 5177, 5176 },
        spell = nil,
        name = "Wrath",
        level = 1,
    },
    starfire = {
        ids = { 25298, 9876, 9875, 8951, 8950, 8949, 2912 },
        spell = nil,
        name = "Starfire",
        level = 20,
    },
    moonfire = {
        ids = { 9835, 9834, 9833, 8929, 8928, 8927, 8926, 8925, 8924, 8921 },
        spell = nil,
        name = "Moonfire",
        is_dot = true,
        level = 4,
    },
    insect_swarm = {
        ids = { 24977, 24976, 24975, 24974, 5570 },
        spell = nil,
        name = "Insect Swarm",
        is_talent = true,
        is_dot = true,
        level = 20,
    },
    entangling_roots = {
        ids = { 9853, 9852, 5196, 5195, 1062, 339 },
        spell = nil,
        name = "Entangling Roots",
        is_cc = true,
        level = 8,
    },
    faerie_fire = {
        ids = { 9907, 9749, 778, 770 },
        spell = nil,
        name = "Faerie Fire",
        level = 18,
    },
    hurricane = {
        ids = {16914},
        spell = nil,
        name = "Hurricane",
        is_aoe = true,
        is_channel = true,
        level = 40,
    },
    natures_grasp = {
        ids = {16689},
        spell = nil,
        name = "Nature's Grasp",
        is_talent = true,
        level = 10,
    },
    hibernate = {
        ids = {18658, 2637},
        spell = nil,
        name = "Hibernate",
        is_cc = true,
        level = 18,
    },
}

-- ============================================================================
-- RESTORATION ABILITIES
-- ============================================================================

spell_data.restoration = {
    healing_touch = {
        ids = { 25297, 9889, 9888, 9758, 8903, 6778, 5189, 5188, 5187, 5186, 5185 },
        spell = nil,
        name = "Healing Touch",
        level = 1,
    },
    rejuvenation = {
        ids = {25299, 9841, 9840, 9839, 8910, 3627, 2091, 2090, 1430, 1058, 774},
        spell = nil,
        name = "Rejuvenation",
        level = 4,
    },
    regrowth = {
        ids = {9858, 9857, 9856, 9750, 8941, 8940, 8939, 8938, 8936},
        spell = nil,
        name = "Regrowth",
        level = 12,
    },
    tranquility = {
        ids = { 9863, 9862, 8918, 740 },
        spell = nil,
        name = "Tranquility",
        is_channel = true,
        level = 30,
    },
    swiftmend = {
        ids = {18562},
        spell = nil,
        name = "Swiftmend",
        is_talent = true,
        level = 30,
    },
    natures_swiftness = {
        ids = {17116},
        spell = nil,
        name = "Nature's Swiftness",
        is_talent = true,
        level = 30,
    },
    remove_curse = {
        ids = {2782},
        spell = nil,
        name = "Remove Curse",
        level = 24,
    },
    abolish_poison = {
        ids = {2893},
        spell = nil,
        name = "Abolish Poison",
        level = 26,
    },
    rebirth = {
        ids = { 20748, 20747, 20742, 20739, 20484 },
        spell = nil,
        name = "Rebirth",
        level = 20,
    },
}

-- ============================================================================
-- BUFFS & UTILITY
-- ============================================================================

spell_data.buffs_utility = {
    mark_of_the_wild = {
        ids = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 },
        spell = nil,
        name = "Mark of the Wild",
        level = 1,
    },
    thorns = {
        ids = {26991, 9910, 8914, 21851, 5330, 467},
        spell = nil,
        name = "Thorns",
        level = 6,
    },
    innervate = {
        ids = {29166},
        spell = nil,
        name = "Innervate",
        level = 40,
    },
    barkskin = {
        ids = {22812},
        spell = nil,
        name = "Barkskin",
        level = 44,
    },
    omen_of_clarity = {
        ids = {16864},
        spell = nil,
        name = "Omen of Clarity",
        is_passive = is_forever,
        is_talent = true,
        level = 20,
    },
}

-- ============================================================================
-- INITIALIZE ALL SPELLS
-- ============================================================================

local categories = {"forms", "cat", "bear", "balance", "restoration", "buffs_utility"}
for _, category in ipairs(categories) do
    for name, data in pairs(spell_data[category]) do
        if not data.is_passive then
            data.spell = init_spell(data.ids)
        end
    end
end

-- ============================================================================
-- BUFF / DEBUFF ID ARRAYS (for has_buff / debuff_up checks)
-- ============================================================================

spell_data.buff_ids = {
    rejuvenation     = {774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299},
    regrowth         = {8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858},
    mark_of_the_wild = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 },
    thorns           = {467, 782, 1075, 8914, 9910, 26991},
    omen_of_clarity  = {16864},
    natures_grasp    = {16689, 16810, 16811, 16812, 16813, 27009},
    natures_swiftness = {17116},
    barkskin         = {22812},
    innervate        = {29166},

    -- Form Buff IDs
    cat_form         = {768},
    bear_form        = {5487},
    dire_bear_form   = {9634},
    moonkin_form     = {24858},
    travel_form      = {783},
    aquatic_form     = {1066},

    -- Prowl (stealth)
    prowl            = {5215, 6783, 9913},

    -- Tiger's Fury
    tigers_fury      = {5217, 6793, 9845, 9846, 9847},

    -- Dash
    dash             = {1850, 9821},

    -- Frenzied Regeneration
    frenzied_regeneration = {22842, 22895, 22896},

    -- Enrage
    enrage           = {5229},

    -- Clearcasting (from Omen of Clarity)
    clearcasting     = {16870},
}

spell_data.debuff_ids = {
    moonfire         = { 9835, 9834, 9833, 8929, 8928, 8927, 8926, 8925, 8924, 8921 },
    insect_swarm     = { 24977, 24976, 24975, 24974, 5570 },
    rip              = {9896, 9895, 9894, 9752, 1079},
    rake             = { 9904, 1824, 1823, 1822 },
    demoralizing_roar = { 9898, 9747, 9490, 1735, 99 },
    faerie_fire      = { 9907, 9749, 778, 770 },
    faerie_fire_feral = {17392, 17391, 17390, 16857},
    entangling_roots = { 9853, 9852, 5196, 5195, 1062, 339 },
    hibernate        = {18658, 2637},
    pounce_bleed     = { 9826, 9824, 9007 },
}

-- ============================================================================
-- RACIALS (detected at runtime)
-- ============================================================================

spell_data.racials = {
    war_stomp = {
        ids = {20549},
        spell = nil,
        name = "War Stomp",
        is_stun = true,
    },
    shadowmeld = {
        ids = {20580},
        spell = nil,
        name = "Shadowmeld",
    },
}

for _, data in pairs(spell_data.racials) do
    data.spell = init_spell(data.ids)
end

-- ============================================================================
-- CONSUMABLE ITEM IDS
-- ============================================================================

spell_data.consumables = {
    health_potions = {
        -- Minor, Lesser, Healing, Greater, Superior, Major
        item_ids = {118, 858, 929, 1710, 3928, 13446},
        name = "Health Potion",
    },
    mana_potions = {
        -- Minor, Lesser, Mana, Greater, Superior, Major
        item_ids = {2455, 3385, 3827, 6149, 13443, 13444},
        name = "Mana Potion",
    },
    healthstone = {
        item_ids = {5512, 19004, 19005, 5511, 19006, 19007, 5509, 19008, 19009, 5510, 19010, 19011, 9421, 19012, 19013},
        name = "Healthstone",
    },
    bandages = {
        -- Linen, Heavy Linen, Wool, Heavy Wool, Silk, Heavy Silk, Mageweave, Heavy Mageweave, Runecloth, Heavy Runecloth
        item_ids = {1251, 2581, 3530, 3531, 6450, 6451, 8544, 8545, 14529, 14530},
        name = "Bandage",
    },
}

return spell_data
