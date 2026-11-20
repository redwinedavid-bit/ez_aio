-- ============================================================================
-- Warrior Spells - ID Lists (Highest Rank First where applicable)
-- Classic Era defaults with a verified, separate Forever spell map.
-- ============================================================================

local spells = {}
spells.__load_revision = "AF-WAR-20261114-PACK-SHIELD-VERIFY1"

---@type izi_sdk
local izi = require("common/izi_sdk")

local game_client = require("shared/game_client")
local version = tostring(game_client.get_game_version_string() or ""):lower()
local forever_ids = nil
if version:find("forever", 1, true) then
    forever_ids = require("rotations/warrior/era/forever_spell_ids")
end

local function s(ids, key)
    if forever_ids then
        local verified_ids = forever_ids[key]
        if verified_ids == false then return nil end
        assert(verified_ids, "Missing Forever Warrior spell mapping: " .. tostring(key))
        ids = verified_ids
    end
    return izi.spell(ids)
end

-- Stances
spells.battle_stance = s({ 2457 }, "battle_stance")
spells.defensive_stance = s({ 71 }, "defensive_stance")
spells.berserker_stance = s({ 2458 }, "berserker_stance")

-- Core buffs / rage tools
spells.battle_shout = s({ 27578, 26099, 26043, 25959, 25356, 25289, 25101, 24438, 11553, 11552, 11551, 11550, 11549, 9128, 6674, 6673, 6543, 6193, 6192, 5243, 5242 }, "battle_shout")
spells.bloodrage = s({ 29131, 2688, 2687 }, "bloodrage")
spells.berserker_rage = s({ 18556, 18499 }, "berserker_rage")

-- Mobility
spells.charge = s({ 11579, 11578, 7371, 7370, 6180, 6178, 1738, 100 }, "charge")
spells.intercept = s({ 27826, 27577, 20622, 20621, 20617, 20616, 20611, 20252 }, "intercept")

-- Rotation (damage)
-- Forever-specific active; do not introduce expansion-only spells on Era.
spells.victory_rush = forever_ids and s({ 402927 }, "victory_rush") or nil
spells.rend = s({ 11577, 11576, 11575, 11574, 11573, 11572, 6551, 6550, 6549, 6548, 6547, 6546, 1423, 772 }, "rend")
spells.hamstring = s({ 27584, 26211, 26141, 9080, 7375, 7374, 7373, 7372, 1716, 1715 }, "hamstring")
spells.overpower = s({ 11587, 11586, 11585, 11584, 7889, 7887, 7385, 7384 }, "overpower")
spells.heroic_strike = s({
    25286, -- Rank 9 (level 60)
    11567, -- Rank 9
    11566, -- Rank 8
    11565, -- Rank 7
    11564, -- Rank 6
    1608,  -- Rank 5
    1607,  -- Rank 4
    1606,  -- Rank 3
    285,   -- Rank 2
    284,   -- Rank 1
    78     -- Rank 0 / base
}, "heroic_strike")spells.cleave = s({ 11609, 11608, 11427, 7369, 5532, 3435, 3434, 3433, 845 }, "cleave")
spells.execute = s({ 20662, 20661, 20660, 20658, 5308 }, "execute")
spells.whirlwind = s({ 9633, 8989, 1685, 1680 }, "whirlwind")
spells.devastate = s({ 403355, 403195, 20243 }, "devastate") -- Defensive-stance filler that benefits from Sunder stacks.

-- Shouts / debuffs
spells.demoralizing_shout = s({ 27579, 11559, 11558, 11557, 11556, 11555, 11554, 6191, 6190, 1160 }, "demoralizing_shout")
spells.thunder_clap = s({ 11581, 11580, 8205, 8204, 8198, 6343 }, "thunder_clap")
spells.intimidating_shout = s({ 29544, 20511, 19134, 5247, 5246 }, "intimidating_shout")

-- Tank toolkit / threat
spells.sunder_armor = s({ 25051, 24317, 11971, 11599, 11598, 11597, 11596, 8381, 8380, 7406, 7405, 7404, 7386 }, "sunder_armor")
spells.revenge = s({ 25288, 11603, 11602, 11601, 11600, 7380, 7379, 6575, 6574, 6573, 6572 }, "revenge")
spells.shield_block = s({ 12169, 2570, 2565 }, "shield_block")
spells.taunt = s({ 355 }, "taunt")
spells.mocking_blow = s({ 20562, 20561, 20560, 20559, 7403, 7402, 7401, 7400, 7382, 694 }, "mocking_blow")

-- Interrupts
spells.pummel = s({ 12555, 6556, 6554, 6553, 6552 }, "pummel")
spells.shield_bash = s({ 11972, 1672, 1671, 72 }, "shield_bash")

-- Talent actives (Classic)
-- Legacy Era candidates below are overridden by the verified map on Forever.
spells.sweeping_strikes = s({ 12328, 12723 }, "sweeping_strikes")
spells.mortal_strike = s({ 27580, 24573, 21558, 21557, 21555, 21553, 21552, 21551, 19643, 17547, 16856, 15708, 13737, 12294 }, "mortal_strike")
spells.bloodthirst = s({ 23900, 23899, 23898, 23894, 23893, 23892, 23891, 23890, 23889, 23888, 23887, 23886, 23885, 23881, 23880 }, "bloodthirst")
spells.shield_slam = s({ 23925, 23924, 23923, 23922 }, "shield_slam")
spells.last_stand = s({ 12976, 12975 }, "last_stand")
spells.shield_wall = s({ 29061, 15062, 1055, 871 }, "shield_wall")
spells.retaliation = s({ 22858, 22857, 20724, 20240, 20230 }, "retaliation")
spells.recklessness = s({ 13847, 1722, 1719 }, "recklessness")
spells.disarm = s({ 27581, 22691, 15752, 13534, 11879, 8379, 6713, 1646, 676 }, "disarm")

function spells:refresh()
    -- No-op (static ID lists).
end

return spells
