local cc = {}

local spell_data = require("rotations/rogue/era/spell_data")

-- Public function to check if target has breakable CC active
-- Used by main.lua to stop auto-attacks before they break CC
-- Returns true if target is under Gouge/Blind/Sap (damage breaks CC)
-- Returns false if target is stunned (Cheap Shot, Kidney Shot - damage allowed)
---@param target game_object
---@param has_cheap_shot boolean
---@return boolean true if target has breakable CC (Gouge/Blind/Sap)
function cc.is_breakable_cc_active(target, has_cheap_shot)
    if not target then
        return false
    end

    -- Unbreakable stuns: Continue attacking
    if has_cheap_shot then
        return false
    end

    local kidney_shot = spell_data.cc.kidney_shot
    if kidney_shot and kidney_shot.ids and target:debuff_up(kidney_shot.ids) == true then
        return false
    end

    if target:is_stunned(100) then
        return false
    end

    -- Breakable CCs: Stop attacking (damage breaks these)
    if target:is_sapped(100) then
        return true
    end

    local gouge = spell_data.cc.gouge
    if gouge and gouge.ids and target:debuff_up(gouge.ids) == true then
        return true
    end

    local blind = spell_data.cc.blind
    if blind and blind.ids and target:debuff_up(blind.ids) == true then
        return true
    end

    return false
end

-- Check if target is CC'd and we should NOT attack it
-- Returns true if we should pause DAMAGE rotation (but NOT emergency spells!)
---@param target game_object
---@param has_cheap_shot boolean
---@return boolean
function cc.should_pause_for_cc(target, has_cheap_shot)
    return cc.is_breakable_cc_active(target, has_cheap_shot)
end

return cc

