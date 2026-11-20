-- ============================================================================
-- Warlock (Classic ERA) - Minimal spell list
-- Uses izi.spell so best learned rank is selected automatically.
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function s(ids)
    return izi.spell(ids)
end

-- Damage
spells.shadow_bolt = s({ 25307, 11661, 11660, 11659, 7641, 1106, 1088, 705, 695, 686 })
spells.corruption = s({ 25311, 11674, 11673, 11672, 11671, 7648, 6223, 6222, 172 })
spells.curse_of_agony = s({ 11713, 11712, 11711, 6218, 6217, 1015, 1014, 980 })
spells.immolate = s({ 11670, 11669, 11668, 11667, 11666, 11665, 2941, 1094, 707, 348 })
spells.drain_life = s({ 11702, 11701, 11700, 11699, 7653, 7652, 7651, 709, 699, 689 })
spells.drain_mana = s({ 11704, 11703, 6226, 5138 }) -- Added for PvP
spells.drain_soul = s({ 11676, 11675, 8291, 8290, 8289, 8288, 1120 })
-- Siphon Life (Affliction Talent). Note: earlier versions of this repo mistakenly used Curse of Agony IDs here.
-- Verified ERA IDs: Rank 1=18265, Rank 2=18879, Rank 3=18880, Rank 4=18881.
spells.siphon_life = s({ 18881, 18880, 18879, 18265 })
spells.shadowburn = s({ 18871, 18870, 18869, 18868, 18867, 17877 }) -- Destruction Talent
spells.conflagrate = s({ 18932, 18931, 18930, 17962 }) -- Destruction Talent
spells.soul_fire = s({ 17924, 6353 })
spells.searing_pain = s({ 17923, 17922, 17921, 17920, 17919, 5676 })
spells.rain_of_fire = s({ 11680, 11679, 11678, 11677, 5740 })
spells.hellfire = s({ 11684, 11683, 1949 })

-- Utility / survival
spells.life_tap = s({ 11692, 11691, 11690, 11689, 11688, 11687, 3097, 3096, 3095, 1456, 1455, 1454 })
spells.demon_armor = s({ 11735, 11734, 11733, 1086, 706 })
spells.demon_skin = s({ 696, 687 })
spells.health_funnel = s({ 11695, 11694, 11693, 3700, 3699, 3698, 755 })
spells.banish = s({ 18647, 710 })
spells.enslave_demon = s({ 11726, 11725, 1098 })

-- Pets
local forever=tostring(require("shared/game_client").get_game_version_string()):lower():find("forever",1,true)
spells.summon_incubus=forever and s({713}) or nil
spells.summon_imp = s({ 688 })
spells.summon_voidwalker = s({ 697 })
spells.summon_felhunter = s({ 691 })
spells.summon_succubus = s({ 712 })
spells.summon_felguard = s({ 30146 }) -- BC Talent, but keep for unified logic

-- CC Spells
spells.fear = s({ 6215, 6213, 5782 })
spells.death_coil = s({ 27223, 17926, 17925, 6789 })
spells.howl_of_terror = s({ 17928, 5484 })

-- Defensive
spells.shadow_ward = s({ 28610, 11740, 11739, 6229 })
spells.sacrifice = s({ 19443, 19442, 19441, 19440, 19438, 7812 }) -- Voidwalker Sacrifice (highest rank first)

-- Specific Curses
spells.curse_of_weakness = s({ 11708, 11707, 7646, 6205, 702, 1108 })
spells.curse_of_tongues = s({ 11719, 1714 })
spells.curse_of_recklessness = s({ 11717, 704, 16231 })
spells.curse_of_elements = s({ 11722, 11721, 1490 })
spells.curse_of_shadow = s({ 17937, 17862 })
spells.curse_of_doom = s({ 603 })
spells.curse_of_exhaustion = s({ 18223 }) -- Affliction Talent
spells.amplify_curse = s({ 18288 }) -- Affliction Talent
spells.dark_pact = s({ 18906, 18905, 18220 }) -- Affliction Talent (highest rank first)
spells.soul_link = s({ 19028 }) -- Demonology Talent
spells.demonic_sacrifice = s({ 18788 }) -- Demonology Talent
spells.fel_domination = s({ 18708 }) -- Demonology Talent
spells.life_tap_rank1 = s({ 1454 }) -- Rank 1 for trinket procs
spells.detect_invisibility = s({ 132 })

-- Creation Spells (for out of combat)
spells.create_healthstone_minor = s({ 6201 })
spells.create_healthstone_lesser = s({ 6202 })
spells.create_healthstone = s({ 5699 })
spells.create_healthstone_greater = s({ 11729 })
spells.create_healthstone_major = s({ 11730 })
spells.create_soulstone_minor = s({ 693 })
spells.create_soulstone_lesser = s({ 20752 })
spells.create_soulstone = s({ 20755 })
spells.create_soulstone_greater = s({ 20756 })
spells.create_soulstone_major = s({ 20757 })
spells.create_firestone = s({ 17953, 17952, 17951, 6366 }) -- Firestones (highest rank first)
spells.create_spellstone = s({ 2362, 17727, 17728 })

function spells:refresh()
    -- No-op (static ID lists).
end

return spells
