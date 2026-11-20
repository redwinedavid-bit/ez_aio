-- ============================================================================
-- Hunter Spells - Simple ID Lists (Highest Rank First)
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

-- Highest rank -> lowest rank so izi.spell() can pick the best learned spell.
local spell_ids = {
    -- SHOTS
    aimed_shot = {20904, 20903, 20902, 20901, 20900, 19434},
    multi_shot = {25294, 14290, 14289, 14288, 2643},
    volley = {14295, 14294, 1510},
    flare = {1543},
    distracting_shot = {20736},
    disengage = {781},
    arcane_shot = {14287, 14286, 14285, 14284, 14283, 14282, 14281, 3044},
    serpent_sting = {25295, 13555, 13554, 13553, 13552, 13551, 13550, 13549, 1978},
    viper_sting = {14280, 14279, 3034},
    concussive_shot = {5116},
    tranq_shot = {19801},

    -- ASPECTS
    aspect_hawk = {25296, 14322, 14321, 14320, 14319, 14318, 13165},
    aspect_monkey = {13163},
    aspect_cheetah = {5118},
    aspect_pack = {13159},

    -- PET ABILITIES
    call_pet = {883},
    revive_pet = { 982 },
    mend_pet = {13545, 13544, 13543, 13542, 3662, 3661, 3111, 136},
    feed_pet = {6991},
    pet_bite = {17261, 17260, 17259, 17258, 17257, 17256, 17255, 17253},
    pet_charge = {27685, 26201, 26179, 26178, 26177, 7371},
    pet_claw = {3009, 3010, 16832, 16831, 16830, 16829, 16828, 16827},
    pet_cower = {16697, 1756, 1755, 1754, 1753, 1742},
    pet_dash = {23110, 23109, 23099},
    pet_dive = {23148, 23147, 23145},
    pet_furious_howl = {24597, 24603, 24605, 24604},
    pet_growl = {14921, 14920, 14919, 14918, 14917, 14916, 2649},
    pet_lightning_breath = {25012, 25011, 25010, 25009, 25008, 24844},
    pet_prowl = {24453, 24452, 24450},
    pet_scorpid_poison = {24587, 24586, 24583, 24640},
    pet_screech = {24579, 24578, 24577, 24423},
    pet_shell_shield = {26064},
    pet_thunderstomp = {26188, 26187, 26090},

    -- BUFFS
    hunters_mark = {14325, 14324, 14323, 1130},
    trueshot_aura = {20906, 20905, 19506},

    -- MELEE ABILITIES
    raptor_strike = {14266, 14265, 14264, 14263, 14262, 14261, 14260, 2973},
    mongoose_bite = { 14271, 14270, 14269, 1495 },
    wing_clip = {14268, 14267, 2974},

    -- CROWD CONTROL
    intimidation = {19577},
    scare_beast = {14327, 14326, 1513},

    -- COOLDOWNS
    bestial_wrath = {19574},
    rapid_fire = {3045},

    -- SURVIVAL / THREAT
    feign_death = {5386, 5385, 5384},
    deterrence = {19263},
}

local function init_spell(ids)
    return izi.spell(ids)
end

-- SHOTS
spells.aimed_shot = init_spell(spell_ids.aimed_shot)
spells.multi_shot = init_spell(spell_ids.multi_shot)
spells.volley = init_spell(spell_ids.volley)
spells.flare = init_spell(spell_ids.flare)
spells.distracting_shot = init_spell(spell_ids.distracting_shot)
spells.disengage = init_spell(spell_ids.disengage)
spells.arcane_shot = init_spell(spell_ids.arcane_shot)
spells.serpent_sting = init_spell(spell_ids.serpent_sting)
spells.viper_sting = init_spell(spell_ids.viper_sting)
spells.concussive_shot = init_spell(spell_ids.concussive_shot)
spells.tranq_shot = init_spell(spell_ids.tranq_shot)
spells.auto_shot = izi.spell(75) -- Auto Shot (no rank)

-- ASPECTS
spells.aspect_hawk = init_spell(spell_ids.aspect_hawk)
spells.aspect_monkey = init_spell(spell_ids.aspect_monkey)
spells.aspect_cheetah = init_spell(spell_ids.aspect_cheetah)
spells.aspect_pack = init_spell(spell_ids.aspect_pack)

-- PET ABILITIES
spells.call_pet = init_spell(spell_ids.call_pet)
spells.revive_pet = init_spell(spell_ids.revive_pet)
spells.mend_pet = init_spell(spell_ids.mend_pet)
spells.feed_pet = init_spell(spell_ids.feed_pet)
spells.pet_bite = init_spell(spell_ids.pet_bite)
spells.pet_charge = init_spell(spell_ids.pet_charge)
spells.pet_claw = init_spell(spell_ids.pet_claw)
spells.pet_cower = init_spell(spell_ids.pet_cower)
spells.pet_dash = init_spell(spell_ids.pet_dash)
spells.pet_dive = init_spell(spell_ids.pet_dive)
spells.pet_furious_howl = init_spell(spell_ids.pet_furious_howl)
spells.pet_growl = init_spell(spell_ids.pet_growl)
spells.pet_lightning_breath = init_spell(spell_ids.pet_lightning_breath)
spells.pet_prowl = init_spell(spell_ids.pet_prowl)
spells.pet_scorpid_poison = init_spell(spell_ids.pet_scorpid_poison)
spells.pet_screech = init_spell(spell_ids.pet_screech)
spells.pet_shell_shield = init_spell(spell_ids.pet_shell_shield)
spells.pet_thunderstomp = init_spell(spell_ids.pet_thunderstomp)

-- BUFFS
spells.hunters_mark = init_spell(spell_ids.hunters_mark)
spells.trueshot_aura = init_spell(spell_ids.trueshot_aura)

-- MELEE ABILITIES
spells.raptor_strike = init_spell(spell_ids.raptor_strike)
spells.mongoose_bite = init_spell(spell_ids.mongoose_bite)
spells.wing_clip = init_spell(spell_ids.wing_clip)

-- CROWD CONTROL
spells.intimidation = init_spell(spell_ids.intimidation)
spells.scare_beast = init_spell(spell_ids.scare_beast)

-- COOLDOWNS
spells.bestial_wrath = init_spell(spell_ids.bestial_wrath)
spells.rapid_fire = init_spell(spell_ids.rapid_fire)

-- SURVIVAL / THREAT
spells.feign_death = init_spell(spell_ids.feign_death)
spells.deterrence = init_spell(spell_ids.deterrence)

function spells:refresh()
    -- No-op: static ID lists do not require refresh.
end

-- ============================================================================
-- BOSS ENRAGE BUFFS (For Tranquilizing Shot)
-- ============================================================================

spells.ENRAGE_BUFFS = {
    19451, -- Magmadar Frenzy (Molten Core)
    23128, -- Flamegor Frenzy (Blackwing Lair)
    23342, -- Chromaggus Frenzy (Blackwing Lair)
    26051, -- Princess Huhuran Berserk (Temple of Ahn'Qiraj)
}

return spells
