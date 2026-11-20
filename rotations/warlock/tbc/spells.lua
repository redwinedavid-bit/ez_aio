-- ============================================================================
-- Warlock (TBC Classic) - Spell IDs
-- Uses izi.spell so best learned rank is selected automatically.
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function s(ids)
    return izi.spell(ids)
end

-- Primary Damage
spells.shadow_bolt = s({ 27209, 25307, 11661, 11660, 11659, 7641, 1106, 1088, 705, 695, 686 })
spells.corruption = s({ 27216, 25311, 11674, 11673, 11672, 11671, 7648, 6223, 6222, 172 })
spells.curse_of_agony = s({ 27218, 11713, 11712, 11711, 6218, 6217, 1015, 1014, 980 })
spells.immolate = s({ 27215, 11670, 11669, 11668, 11667, 11666, 11665, 2941, 1094, 707, 348 })
spells.incinerate = s({ 29722, 32231 }) -- TBC Spell
spells.unstable_affliction = s({ 30451, 30449, 30108 }) -- TBC Affliction Talent
spells.seed_of_corruption = s({ 27243 }) -- TBC Spell
spells.drain_life = s({ 27219, 11702, 11701, 11700, 11699, 7653, 7652, 7651, 709, 699, 689 })
spells.drain_soul = s({ 27217, 11676, 11675, 8291, 8290, 8289, 8288, 1120 })
-- Siphon Life (Affliction Talent). Note: earlier versions of this repo mistakenly used Curse of Agony IDs here.
-- Verified IDs (Classic/TBC era): Rank 1=18265, Rank 2=18879, Rank 3=18880, Rank 4=18881, Rank 6=30911.
-- Rank 5 ID varies across DBs/clients; omitted intentionally to avoid mis-casts.
spells.siphon_life = s({ 30911, 18881, 18880, 18879, 18265 })
spells.shadowburn = s({ 18871, 18870, 18869, 18868, 18867, 17877 }) -- Talent
spells.conflagrate = s({ 18811, 18810, 18809, 17962 }) -- Talent (Note: TBC has ranks 1-4)
spells.soul_fire = s({ 27211, 17924, 17923, 6353 })
spells.searing_pain = s({ 27210, 11664, 11663, 11662, 7649, 1085 })

-- AoE
spells.rain_of_fire = s({ 27212, 11680, 11679, 11678, 11677, 5740 })
spells.hellfire = s({ 27213, 11684, 11683, 5857, 1949 })
spells.shadowfury = s({ 30283 }) -- TBC Destruction Talent

-- Armor / Buffs
spells.fel_armor = s({ 28176, 28189 }) -- TBC Spell
spells.demon_armor = s({ 27260, 11738, 11737, 11736, 11735, 11734, 11733, 1087, 1086, 706 })
spells.demon_skin = s({ 696, 687 })
spells.soul_link = s({ 19028 }) -- Talent

-- Pets
spells.summon_felguard = s({ 30146 }) -- TBC Demonology Talent
spells.summon_imp = s({ 688 })
spells.summon_voidwalker = s({ 697 })
spells.summon_felhunter = s({ 691 })
spells.summon_succubus = s({ 712 })

-- Utility
spells.life_tap = s({ 27222, 11692, 11691, 11690, 11689, 11688, 11687, 3097, 3096, 3095, 1456, 1455, 1454 })
spells.health_funnel = s({ 27259, 11658, 11657, 11656, 1083, 1082, 1081, 1080, 755 })
spells.death_coil = s({ 27223, 17926, 17925, 6789 })
spells.fear = s({ 6215, 6213, 5782 })
spells.drain_mana = s({ 27220, 6074 })
spells.shadow_ward = s({ 28610, 11740, 11739, 6229 })
spells.detect_invisibility = s({ 132 })
spells.unending_breath = s({ 5697, 1471, 1470 })
spells.create_spellstone = s({ 2362, 17727, 17728 }) -- Create Spellstone ranks (Classic/TBC)

-- Specific Curses
spells.curse_of_elements = s({ 27228, 11722, 11721, 1490 })
spells.curse_of_recklessness = s({ 27226, 11717, 704, 16231 })
spells.curse_of_weakness = s({ 27214, 11708, 11707, 7646, 6205, 702, 1108 })
spells.curse_of_tongues = s({ 11719, 1714 })
spells.curse_of_doom = s({ 30910, 603 })
spells.curse_of_exhaustion = s({ 18223 })
spells.amplify_curse = s({ 18288 })
spells.dark_pact = s({ 27269, 18220, 18905, 18906 })

-- Talents (additional)
spells.howl_of_terror = s({ 17928, 5484 })           -- Talent: AoE Fear (instant with talent)
spells.demonic_sacrifice = s({ 18788 })               -- Talent: Sacrifice pet for damage buff
spells.fel_domination = s({ 18708 })                  -- Talent: Next summon is instant
spells.soulshatter = s({ 29858 })                     -- TBC Spell: Threat drop

-- Racials (best-effort: only casts if learned for current race)
spells.blood_fury = s({ 20572 })                      -- Orc
spells.berserking = s({ 26297, 20554 })               -- Troll (rank differs by faction/era)
spells.arcane_torrent = s({ 28730, 25046 })           -- Blood Elf (mana), multiple ids across clients
spells.will_of_the_forsaken = s({ 7744 })             -- Undead
spells.stoneform = s({ 20594 })                       -- Dwarf
spells.escape_artist = s({ 20589 })                   -- Gnome
spells.war_stomp = s({ 20549 })                       -- Tauren
spells.shadowmeld = s({ 20580 })                      -- Night Elf
spells.perception = s({ 20600 })                      -- Human

-- Pet Abilities (cast via core.input.pet_cast_target_spell)
-- Voidwalker Sacrifice (shield): 7812, 19438, 19440, 19441, 19442, 19443, 27273
-- Spell Lock (Felhunter interrupt): 19244
-- Devour Magic (Felhunter purge): 19746
-- Seduction (Succubus CC): 6358
-- Felguard Cleave: 30213
-- Felguard Intercept: 30151

-- Creation
-- Healthstone creation (explicit ranks so we can always pick the highest one).
-- IDs verified against Classic/TBC spell DBs (2.4.3 era).
spells.create_healthstone_master = s({ 27230 }) -- Master Healthstone (TBC)
spells.create_healthstone_major = s({ 11730 })  -- Major Healthstone
spells.create_healthstone_greater = s({ 11729 }) -- Greater Healthstone
spells.create_healthstone_normal = s({ 5699 })  -- Healthstone
spells.create_healthstone_lesser = s({ 6202 })  -- Lesser Healthstone
spells.create_healthstone_minor = s({ 28023 })  -- Minor Healthstone

-- Consolidated handle for callers that want "best rank".
-- Note: warlock healthstone creation logic does not rely on this selection (see rotation_logic.lua).
spells.create_healthstone = s({ 27230, 11730, 11729, 5699, 6202, 28023 })
-- Soulstone ranks (some clients use 20757 for the level 60 rank)
spells.create_soulstone = s({ 27238, 20757, 20756, 20755, 20754, 20753, 20752 })
spells.ritual_of_souls = s({ 29893 }) -- TBC Spell

function spells:refresh()
    -- No-op (static ID lists).
end

return spells
