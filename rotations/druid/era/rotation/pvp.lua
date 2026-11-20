-- ============================================================================
-- Druid PvP - Main Dispatcher (Classic ERA)
-- High-priority PvP actions shared across all specs
-- ============================================================================

local pvp = {}

-- ============================================================================
-- PVP PRIORITY ACTIONS (run before spec rotation)
-- ============================================================================

--- Try high-priority PvP actions that apply to all specs
--- @param player game_object
--- @param target game_object|nil
--- @param helpers table
--- @return boolean
function pvp.try_pvp_priority(player, target, helpers)
    if not player then return false end
    if not helpers:is_pvp_mode() then return false end

    -- Root/snare breaking via shapeshift (highest PvP priority)
    if helpers:try_break_roots(player) then
        return true
    end

    -- Feral Charge interrupt on enemy caster (if in bear form)
    if target and helpers:is_valid_enemy(target) then
        if helpers:is_in_bear_form(player) then
            if helpers:is_target_casting(target) then
                if helpers:get_menu_state("pvp_use_feral_charge") then
                    if helpers:is_spell_learned("bear", "feral_charge") then
                        if helpers:is_cooldown_ready("bear", "feral_charge") then
                            local rage = helpers:get_rage(player)
                            if rage >= 15 then
                                if helpers:try_cast("bear", "feral_charge", target) then
                                    helpers:log_checkpoint("pvp_charge", 3.0, "[Druid][PvP] Feral Charge interrupt")
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

return pvp
