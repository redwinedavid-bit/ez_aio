-- ============================================================================
-- Druid Spells - TBC (2.4.3)
-- ============================================================================

local spells = {}
local izi = require("common/izi_sdk")

local spell_ids = {
    -- Restoration (Healing)
    healing_touch = {26978, 26979, 25297, 1064, 1062, 1061, 1060, 5189, 5188, 5187, 5186, 5185},
    rejuvenation = {26981, 26982, 25299, 1080, 1079, 1078, 1077, 1076, 1075, 1074, 1073, 1072, 1071, 1070, 774},
    regrowth = {26980, 26977, 1094, 1093, 1092, 1091, 1090, 8941, 8940, 8939, 8938, 8936},
    lifebloom = {33763},
    tranquility = {26983, 17124, 17123, 9858, 9857, 740},
    swiftmend = {18562},
    tree_of_life = {33891},
    rebirth = {26994, 20748, 20747, 20742, 2050, 2048},
    remove_curse = {2782},
    abolish_poison = {2893},

    -- Feral (Bear/Tank)
    maul = {26996, 9881, 9880, 9879, 1178, 8998, 6807},
    swipe = {26997, 9908, 9901, 779, 769, 71},
    mangle_bear = {33878, 33986, 33987},
    lacerate = {33745},
    demoralizing_roar = {26998, 9898, 9892, 9460, 1160, 99},
    growl = {6795},
    bash = {8983, 5211, 4030},
    enrage = {5229},
    frenzied_regeneration = {22896, 22895, 22842},
    feral_charge = {16979},

    -- Feral (Cat/DPS)
    mangle_cat = {33876, 33982, 33983},
    claw = {27000, 9850, 9849, 9848, 9831, 9830, 9829, 6808, 1082},
    rake = {27001, 9904, 1824, 1823, 1822, 1152},
    rip = {27002, 9896, 9895, 9894, 9752, 1079},
    shred = {27004, 9943, 9942, 9941, 8992, 1083, 5221},
    cower = {27005, 9913, 9814, 8994},
    tigers_fury = {9847, 9846, 9845, 1081, 5217},
    ravage = {26999, 9891, 9890, 9889, 6787},
    pounce = {27003, 9827, 9823, 9005},
    ferocious_bite = {31018, 27557, 24248, 22568, 22827},
    prowl = {5215},
    dash = {33357, 1850},

    -- Balance (DPS)
    cyclone = {33786},
    starfire = {26986, 25298, 9876, 9875, 8951, 8949, 8948, 8947, 2912},
    wrath = {26984, 25296, 9835, 9834, 8908, 8907, 8906, 8905, 6748, 5177, 5176},
    moonfire = {26985, 25295, 10912, 10911, 10910, 10909, 9833, 8929, 8928, 8927, 8926, 8925, 8924, 8921},
    insect_swarm = {27013, 24977, 24976, 24975, 24974, 20911, 20909},
    entangling_roots = {26989, 9871, 9870, 9869, 9853, 9852, 1143, 811},
    faerie_fire = {26993, 9907, 776, 770},
    faerie_fire_feral = {27011, 17392, 17391, 17390, 16857},
    hurricane = {27012, 17402, 17401, 16914},
    force_of_nature = {33831},
    hibernate = {18658, 18657, 2637},
    natures_grasp = {27009, 16813, 16812, 16811, 16810, 16689},
    soothe_animal = {26995, 9901, 2908, 2904},

    -- Forms
    bear_form = {5487},
    dire_bear_form = {9634},
    cat_form = {768},
    travel_form = {783},
    aquatic_form = {1066},
    moonkin_form = {24858},
    flight_form = {33943},
    swift_flight_form = {40120},

    -- Utility / Buffs
    mark_of_the_wild = {26990, 26991, 26992, 9885, 9884, 8903, 6756, 5232, 1126},
    thorns = {26992, 9910, 8914, 5330, 467},
    innervate = {29166},
    nature_swiftness = {17116},
    barkskin = {22812},
    omen_of_clarity = {16864},

    -- Racials
    war_stomp = {20549},
    berserking = {26297},
}

-- Energy costs (reference for helpers)
spells.ENERGY_COSTS = {
    mangle_cat = 45,
    shred = 42,
    claw = 45,
    rake = 40,
    rip = 30,
    ferocious_bite = 35,
    cower = 20,
    ravage = 60,
    pounce = 50,
}

-- Rage costs (reference for helpers)
spells.RAGE_COSTS = {
    mangle_bear = 20,
    maul = 15,
    swipe = 20,
    lacerate = 15,
    demoralizing_roar = 10,
    bash = 10,
    feral_charge = 15,
    enrage = 0,
    frenzied_regeneration = 0,
}

local function init_spell(ids)
    return izi.spell(ids)
end

for name, ids in pairs(spell_ids) do
    spells[name] = init_spell(ids)
end

spells.REJUV_BUFF_IDS = {774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299, 26981, 26982}
spells.REGROWTH_BUFF_IDS = {8936, 8938, 8939, 8940, 8941, 1090, 1091, 1092, 1093, 1094, 26980, 26977}
spells.LIFEBLOOM_BUFF_ID = 33763
spells.MOTW_BUFF_IDS = {1126, 5232, 6756, 8903, 9884, 9885, 26992, 26990, 26991}
spells.MOONFIRE_DEBUFF_IDS = {26985, 25295, 10912, 10911, 10910, 10909, 9833, 8929, 8928, 8927, 8926, 8925, 8924, 8921}
spells.INSECT_SWARM_DEBUFF_IDS = {27013, 24977, 24976, 24975, 24974, 20911, 20909}

-- Feral Debuff IDs
spells.RIP_DEBUFF_IDS = {27002, 9896, 9895, 9894, 9752, 1079}
spells.RAKE_DEBUFF_IDS = {27001, 9904, 1824, 1823, 1822, 1152}
spells.MANGLE_DEBUFF_IDS = {33876, 33982, 33983, 33878, 33986, 33987} -- Cat + Bear Mangle share debuff
spells.LACERATE_DEBUFF_IDS = {33745}
spells.DEMO_ROAR_DEBUFF_IDS = {26998, 9898, 9892, 9460, 1160, 99}

-- Form Buff IDs
spells.CAT_FORM_BUFF_IDS = {768}
spells.BEAR_FORM_BUFF_IDS = {5487}
spells.DIRE_BEAR_FORM_BUFF_IDS = {9634}
spells.MOONKIN_FORM_BUFF_IDS = {24858}
spells.TRAVEL_FORM_BUFF_IDS = {783}
spells.TREE_OF_LIFE_BUFF_IDS = {33891}
spells.FLIGHT_FORM_BUFF_IDS = {33943, 40120}
spells.ANY_BEAR_FORM_BUFF_IDS = {5487, 9634}

-- Utility Buff IDs
spells.PROWL_BUFF_IDS = {5215}
spells.BARKSKIN_BUFF_IDS = {22812}
spells.OMEN_OF_CLARITY_BUFF_IDS = {16864}
spells.NATURES_GRASP_BUFF_IDS = {27009, 16813, 16812, 16811, 16810, 16689}
spells.NATURES_SWIFTNESS_BUFF_IDS = {17116}
spells.DASH_BUFF_IDS = {33357, 1850}
spells.INNERVATE_BUFF_IDS = {29166}
spells.TIGERS_FURY_BUFF_IDS = {9847, 9846, 9845, 1081, 5217}
spells.FRENZIED_REGEN_BUFF_IDS = {22896, 22895, 22842}
spells.ENRAGE_BUFF_IDS = {5229}

-- PvP / CC Debuff IDs
spells.CYCLONE_DEBUFF_IDS = {33786}
spells.HIBERNATE_DEBUFF_IDS = {18658, 18657, 2637}
spells.ENTANGLING_ROOTS_DEBUFF_IDS = {26989, 9871, 9870, 9869, 9853, 9852, 1143, 811}
spells.FAERIE_FIRE_DEBUFF_IDS = {26993, 9907, 776, 770}
spells.FERAL_FAERIE_FIRE_DEBUFF_IDS = {27011, 17392, 17391, 17390, 16857}
spells.POUNCE_DEBUFF_IDS = {27003, 9827, 9823, 9005}
spells.BASH_DEBUFF_IDS = {8983, 5211, 4030}

-- Consumable Spell IDs (for use items)
spells.CONSUMABLES = {
    health_potions = {
        {name = "Super Healing Potion", item_id = 22829, spell_id = 28495, min_level = 55},
        {name = "Major Healing Potion", item_id = 13446, spell_id = 11359, min_level = 45},
        {name = "Greater Healing Potion", item_id = 1710, spell_id = 6063, min_level = 35},
        {name = "Healing Potion", item_id = 929, spell_id = 441, min_level = 21},
        {name = "Lesser Healing Potion", item_id = 858, spell_id = 440, min_level = 1},
    },
    mana_potions = {
        {name = "Super Mana Potion", item_id = 22832, spell_id = 28499, min_level = 55},
        {name = "Major Mana Potion", item_id = 13444, spell_id = 11335, min_level = 49},
        {name = "Greater Mana Potion", item_id = 6149, spell_id = 6063, min_level = 31},
    },
    healthstones = {
        {name = "Master Healthstone", item_id = 36892, spell_id = 27235},
        {name = "Major Healthstone", item_id = 22105, spell_id = 27236},
        {name = "Greater Healthstone", item_id = 5509, spell_id = 11730},
        {name = "Healthstone", item_id = 5512, spell_id = 11729},
    },
}

return spells
