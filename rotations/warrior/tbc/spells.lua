-- ============================================================================
-- Warrior Spells - ID Lists (Highest Rank First where applicable)
-- WoW Classic TBC; uses izi.spell() to select best learned.
-- ============================================================================

local spells = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

local function s(ids)
    return izi.spell(ids)
end

-- Stances
spells.battle_stance = s({ 2457 })
spells.defensive_stance = s({ 71 })
spells.berserker_stance = s({ 2458 })

-- Core buffs / rage tools
-- TBC highest rank is Rank 8 (Spell ID 2048). Rank 9 (47436) is WotLK and should not be included here.
spells.battle_shout = s({ 2048, 25289, 11551, 11550, 11549, 6192, 5242, 6673 })
spells.commanding_shout = s({ 469 })
spells.bloodrage = s({ 29131, 2688, 2687 })
spells.berserker_rage = s({ 18556, 18499 })

-- Mobility
spells.charge = s({ 11579, 11578, 7371, 7370, 6180, 6178, 1738, 100 })
spells.intercept = s({ 27826, 27577, 20622, 20621, 20617, 20616, 20611, 20252 })
spells.intervene = s({ 3411 })

-- Rotation (damage)
spells.rend = s({ 11577, 11576, 11575, 11574, 11573, 11572, 6551, 6550, 6549, 6548, 6547, 6546, 1423, 772 })
spells.hamstring = s({ 27584, 26211, 26141, 9080, 7375, 7374, 7373, 7372, 1716, 1715 })
spells.overpower = s({ 11587, 11586, 11585, 11584, 7889, 7887, 7385, 7384 })
spells.slam = s({ 25242, 25241, 11605, 11604, 11430, 8821, 8820, 1482, 1464 })
-- NOTE: Keep ONLY castable Heroic Strike ranks here.
-- Some commonly-copied IDs (e.g. 25958 / 11570 / 11571 / 1610 / 1611) are "learn spell" entries and will break izi.spell().
spells.heroic_strike = s({ 30324, 29707, 25286, 11567, 11566, 11565, 11564, 1608, 285, 284, 78 })
-- NOTE: Keep ONLY castable Cleave ranks here (avoid "learn spell" IDs).
spells.cleave = s({ 25231, 20569, 11609, 11608, 7369, 845 })
spells.execute = s({ 25236, 25234, 20662, 20661, 20660, 20658, 5308 })
spells.whirlwind = s({ 9633, 8989, 1685, 1680 })
-- NOTE: Some TBC server builds use different spell IDs for Devastate ranks.
-- Keep a superset so izi.spell() can pick the best learned rank.
spells.devastate = s({ 30022, 30016, 20243 }) -- Prot filler that benefits from Sunder stacks.

-- Shouts / debuffs
spells.demoralizing_shout = s({ 27579, 25203, 25202, 11559, 11558, 11557, 11556, 11555, 11554, 6191, 6190, 1160 })
spells.thunder_clap = s({ 25264, 11581, 11580, 8205, 8204, 8198, 6343 })
spells.intimidating_shout = s({ 29544, 20511, 19134, 5247, 5246 })

-- Tank toolkit / threat
spells.sunder_armor = s({ 25051, 24317, 11971, 11599, 11598, 11597, 11596, 8381, 8380, 7406, 7405, 7404, 7386 })
spells.revenge = s({ 30357, 25288, 25269, 11601, 11600, 7379, 6574, 6572 })
spells.shield_block = s({ 12169, 2570, 2565 })
spells.taunt = s({ 355 })
spells.mocking_blow = s({ 20562, 20561, 20560, 20559, 7403, 7402, 7401, 7400, 7382, 694 })
spells.challenging_shout = s({ 1161 })
spells.concussion_blow = s({ 12809 })

-- Interrupts
spells.pummel = s({ 12555, 6556, 6554, 6553, 6552 })
spells.shield_bash = s({ 29704, 11972, 1672, 1671, 72 })

-- Talent actives (TBC)
-- Sweeping Strikes is an Arms talent in TBC. Some server builds have differing IDs, so keep a small superset.
spells.sweeping_strikes = s({ 12328, 12723 })
spells.piercing_howl = s({ 12323 })
spells.death_wish = s({ 12292 })
spells.mortal_strike = s({ 30330, 27580, 24573, 21558, 21557, 21555, 21553, 21552, 21551, 19643, 17547, 16856, 15708, 13737, 12294 })
spells.bloodthirst = s({ 30335, 23900, 23899, 23898, 23894, 23893, 23892, 23891, 23890, 23889, 23888, 23887, 23886, 23885, 23881, 23880 })
-- Rampage: some servers expose the buff aura as 30033; the castable spell is 29801.
-- Prefer the castable spell id first to avoid selecting a non-castable aura entry.
spells.rampage = s({ 29801, 30033 })
spells.RAMPAGE_BUFF_ID = 30033
spells.shield_slam = s({ 30356, 25258, 23925, 23924, 23923, 23922 })
spells.last_stand = s({ 12976, 12975 })
spells.shield_wall = s({ 29061, 15062, 1055, 871 })
spells.retaliation = s({ 22858, 22857, 20724, 20240, 20230 })
spells.recklessness = s({ 13847, 1722, 1719 })
spells.disarm = s({ 27581, 22691, 15752, 13534, 11879, 8379, 6713, 1646, 676 })
spells.spell_reflection = s({ 23920 })

-- Racials (offensive / utility)
spells.blood_fury = s({ 20572 })
spells.berserking = s({ 26297, 20554 })
spells.arcane_torrent = s({ 28730, 25046 })

function spells:refresh()
    -- No-op (static ID lists).
end

return spells
