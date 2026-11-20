-- ============================================================================
-- Druid Racials Module - TBC (2.4.3)
-- War Stomp (Tauren), Berserking (Troll)
-- ============================================================================

local racials = {}

local spells = require("rotations/druid/tbc/spells")

-- ============================================================================
-- RACIAL DETECTION
-- ============================================================================

local _detected_race = nil

local function detect_race(helpers)
    if _detected_race then return _detected_race end

    -- Try to detect by checking if racial spells are learned
    if helpers:is_spell_learned(spells.war_stomp) then
        _detected_race = "tauren"
    elseif helpers:is_spell_learned(spells.berserking) then
        _detected_race = "troll"
    else
        _detected_race = "night_elf" -- Default for Alliance druids
    end

    return _detected_race
end

-- ============================================================================
-- WAR STOMP (Tauren) - 2s AoE stun, 0.5s cast, 2min CD
-- ============================================================================

function racials:try_war_stomp(player, helpers)
    if not player then return false end
    if detect_race(helpers) ~= "tauren" then return false end
    if not helpers:is_spell_learned(spells.war_stomp) then return false end
    if not helpers:is_spell_ready(spells.war_stomp) then return false end

    -- Must be in caster form (War Stomp requires humanoid form)
    local form = helpers:get_current_form(player)
    if form ~= "caster" then return false end

    return helpers:try_cast(spells.war_stomp, player, "[Racial] War Stomp")
end

-- ============================================================================
-- BERSERKING (Troll) - 10% haste for 10s, 3min CD
-- ============================================================================

function racials:try_berserking(player, helpers)
    if not player then return false end
    if detect_race(helpers) ~= "troll" then return false end
    if not helpers:is_spell_learned(spells.berserking) then return false end
    if not helpers:is_spell_ready(spells.berserking) then return false end

    -- Usable in any form
    return helpers:try_cast(spells.berserking, player, "[Racial] Berserking")
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

function racials:try_use_racial(player, helpers, is_burst)
    if not player then return false end
    if not is_burst then return false end

    local race = detect_race(helpers)

    if race == "troll" then
        return self:try_berserking(player, helpers)
    end

    -- War Stomp is situational (interrupt/emergency), not a DPS cooldown
    -- It's handled separately in PvP and interrupt logic

    return false
end

function racials:try_use_racial_interrupt(player, helpers)
    if not player then return false end
    return self:try_war_stomp(player, helpers)
end

return racials
