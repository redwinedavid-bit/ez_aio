-- ============================================================================
-- Druid CC Detection Module - TBC (2.4.3)
-- Detects crowd control effects on targets to prevent breaking them
-- ============================================================================

local cc = {}

local spells = require("rotations/druid/tbc/spells")

-- ============================================================================
-- BREAKABLE CC (damage breaks these - pause damage/auto-attack)
-- ============================================================================

--- Check if target has a CC effect that would break on damage
---@param target any Game object
---@return boolean
function cc.is_breakable_cc_active(target)
    if not target then return false end

    -- Entangling Roots - breaks on damage
    local ok_roots, has_roots = pcall(function()
        return target:has_debuff(spells.ENTANGLING_ROOTS_DEBUFF_IDS)
    end)
    if ok_roots and has_roots == true then return true end

    -- Hibernate - breaks on damage (beasts/dragonkin only)
    local ok_hib, has_hib = pcall(function()
        return target:has_debuff(spells.HIBERNATE_DEBUFF_IDS)
    end)
    if ok_hib and has_hib == true then return true end

    return false
end

-- ============================================================================
-- UNBREAKABLE CC (stuns - damage does NOT break)
-- ============================================================================

--- Check if target has a stun (unbreakable by damage, safe to keep attacking)
---@param target any Game object
---@return boolean
function cc.is_stunned(target)
    if not target then return false end

    -- Bash stun
    local ok_bash, has_bash = pcall(function()
        return target:has_debuff(spells.BASH_DEBUFF_IDS)
    end)
    if ok_bash and has_bash == true then return true end

    -- Pounce stun
    local ok_pounce, has_pounce = pcall(function()
        return target:has_debuff(spells.POUNCE_DEBUFF_IDS)
    end)
    if ok_pounce and has_pounce == true then return true end

    -- Generic stun check
    local ok_stun, is_stun = pcall(function()
        return target:is_stunned()
    end)
    if ok_stun and is_stun == true then return true end

    return false
end

-- ============================================================================
-- CYCLONE (immune to everything - pause ALL actions on target)
-- ============================================================================

--- Check if target is cycloned (immune to damage AND healing)
---@param target any Game object
---@return boolean
function cc.is_cycloned(target)
    if not target then return false end

    local ok, val = pcall(function()
        return target:has_debuff(spells.CYCLONE_DEBUFF_IDS)
    end)
    return ok and val == true
end

-- ============================================================================
-- COMBINED CHECKS
-- ============================================================================

--- Should pause all rotation actions (damage, healing, CC) on this target?
--- Returns true for: Cyclone, Entangling Roots, Hibernate
---@param target any Game object
---@return boolean
function cc.should_pause_for_cc(target)
    if not target then return false end
    if cc.is_cycloned(target) then return true end
    if cc.is_breakable_cc_active(target) then return true end
    return false
end

--- Should pause auto-attack specifically?
--- Only for breakable CCs (not cyclone since target is immune anyway)
---@param target any Game object
---@return boolean
function cc.should_pause_auto_attack(target)
    return cc.is_breakable_cc_active(target)
end

--- Is it safe to deal damage to this target?
--- True if target has no CC or only has stuns (unbreakable)
---@param target any Game object
---@return boolean
function cc.is_safe_to_damage(target)
    if not target then return false end
    if cc.is_cycloned(target) then return false end
    if cc.is_breakable_cc_active(target) then return false end
    return true
end

return cc
