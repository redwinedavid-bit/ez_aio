-- ============================================================================
-- Druid CC Detection (Classic ERA)
-- Detect breakable CC on targets to pause rotation
-- ============================================================================

local cc = {}

local spell_data = require("rotations/druid/era/spell_data")

-- ============================================================================
-- BREAKABLE CC IDS
-- Damage breaks these effects
-- ============================================================================

local ENTANGLING_ROOTS_IDS = {339, 1062, 5195, 5196, 9852, 9853, 9871, 9870, 9869}
local HIBERNATE_IDS = {2637, 18657, 18658}

-- Non-breakable stuns (damage allowed)
local BASH_IDS = {5211, 4030, 8983}
local POUNCE_STUN_IDS = {9005, 9823, 9827}
local WAR_STOMP_IDS = {20549}

-- ============================================================================
-- PUBLIC FUNCTIONS
-- ============================================================================

--- Check if target has breakable CC active (damage would break it)
--- @param target game_object
--- @return boolean true if target has breakable CC
function cc.is_breakable_cc_active(target)
    if not target then return false end

    -- Unbreakable stuns: continue attacking
    local ok_bash, has_bash = pcall(function() return target:debuff_up(BASH_IDS) end)
    if ok_bash and has_bash then return false end

    local ok_pounce, has_pounce = pcall(function() return target:debuff_up(POUNCE_STUN_IDS) end)
    if ok_pounce and has_pounce then return false end

    -- Generic stun check: continue attacking
    local ok_stun, is_stunned = pcall(function() return target:is_stunned(100) end)
    if ok_stun and is_stunned then return false end

    -- Breakable CCs: STOP attacking
    local ok_roots, has_roots = pcall(function() return target:debuff_up(ENTANGLING_ROOTS_IDS) end)
    if ok_roots and has_roots then return true end

    local ok_hib, has_hib = pcall(function() return target:debuff_up(HIBERNATE_IDS) end)
    if ok_hib and has_hib then return true end

    return false
end

--- Should we pause the damage rotation for this target?
--- @param target game_object
--- @return boolean
function cc.should_pause_for_cc(target)
    return cc.is_breakable_cc_active(target)
end

return cc
