-- ============================================================================
-- Druid Helpers - Racials (Classic ERA)
-- Tauren: War Stomp | Night Elf: Shadowmeld
-- ============================================================================

local racials = {}

local spell_data = require("rotations/druid/era/spell_data")

-- ============================================================================
-- REGISTRATION
-- ============================================================================

function racials.register(helpers)

    --- Try to use War Stomp (Tauren racial) - AoE stun
    --- Useful in bear PvP, emergency survival, or interrupt
    --- @param player game_object
    --- @return boolean
    function helpers:try_war_stomp(player)
        if not player then return false end

        local ws = spell_data.racials.war_stomp
        if not ws or not ws.spell then return false end

        local ok, learned = pcall(function() return ws.spell:is_learned() end)
        if not (ok and learned) then return false end

        local ok2, cd_up = pcall(function() return ws.spell:cooldown_up() end)
        if not (ok2 and cd_up) then return false end

        -- War Stomp requires not in shapeshift form in Classic ERA
        -- Must be in caster form to use it
        if helpers:is_in_any_form(player) then return false end

        local ok3, result = pcall(function()
            return ws.spell:cast_safe(player)
        end)

        if ok3 and result then
            helpers:log_checkpoint("war_stomp", 3.0, "[Druid][Racial] Used War Stomp")
            return true
        end

        return false
    end

    --- Try to use Shadowmeld (Night Elf racial) - OOC pseudo-stealth
    --- Useful for avoiding patrols in hardcore mode
    --- @param player game_object
    --- @return boolean
    function helpers:try_shadowmeld(player)
        if not player then return false end
        if helpers:is_in_combat(player) then return false end

        local sm = spell_data.racials.shadowmeld
        if not sm or not sm.spell then return false end

        local ok, learned = pcall(function() return sm.spell:is_learned() end)
        if not (ok and learned) then return false end

        local ok2, cd_up = pcall(function() return sm.spell:cooldown_up() end)
        if not (ok2 and cd_up) then return false end

        local ok3, result = pcall(function()
            return sm.spell:cast_safe(player)
        end)

        if ok3 and result then
            helpers:log_checkpoint("shadowmeld", 5.0, "[Druid][Racial] Used Shadowmeld")
            return true
        end

        return false
    end

end -- racials.register

return racials
