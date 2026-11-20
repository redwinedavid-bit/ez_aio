-- ============================================================================
-- Druid Helpers - Shapeshifting Logic (Classic ERA)
-- Form detection, powershift, root-breaking, travel form escape
-- ============================================================================

local forms = {}

local spell_data = require("rotations/druid/era/spell_data")
local resource_ticks = require("shared/resource_ticks")

-- ============================================================================
-- POWERSHIFT STATE MACHINE
-- ============================================================================

local powershift_state = {
    phase = "idle",     -- "idle", "shifting_out", "shifting_in"
    timestamp = 0,
    target_form = nil,
}

local POWERSHIFT_SHIFT_DELAY_MS = 100 -- Delay between shift out and shift back in

-- Root-breaking state machine
local root_break_state = {
    phase = "idle",     -- "idle", "shifting_out", "shifting_back"
    timestamp = 0,
    original_form = nil,
}

local ROOT_BREAK_DELAY_MS = 100

-- ============================================================================
-- REGISTRATION
-- ============================================================================

function forms.register(helpers)

    -- ========================================================================
    -- FORM DETECTION
    -- ========================================================================

    --- Get the current shapeshift form name
    --- @param player game_object
    --- @return string "cat", "bear", "dire_bear", "travel", "moonkin", "aquatic", "caster"
    function helpers:get_current_form(player)
        if not player then return "caster" end

        if self:has_buff(player, "cat_form") then return "cat" end
        if self:has_buff(player, "dire_bear_form") then return "dire_bear" end
        if self:has_buff(player, "bear_form") then return "bear" end
        if self:has_buff(player, "travel_form") then return "travel" end
        if self:has_buff(player, "moonkin_form") then return "moonkin" end
        if self:has_buff(player, "aquatic_form") then return "aquatic" end

        return "caster"
    end

    function helpers:is_in_cat_form(player)
        return self:has_buff(player, "cat_form")
    end

    function helpers:is_in_bear_form(player)
        return self:has_buff(player, "bear_form") or self:has_buff(player, "dire_bear_form")
    end

    function helpers:is_in_caster_form(player)
        return self:get_current_form(player) == "caster"
    end

    function helpers:is_in_travel_form(player)
        return self:has_buff(player, "travel_form")
    end

    function helpers:is_in_moonkin_form(player)
        return self:has_buff(player, "moonkin_form")
    end

    function helpers:is_stealthed(player)
        return self:has_buff(player, "prowl")
    end

    --- Check if player is in any shapeshift form
    function helpers:is_in_any_form(player)
        return self:get_current_form(player) ~= "caster"
    end

    -- ========================================================================
    -- FORM SHIFTING
    -- ========================================================================

    --- Ensure player is in the desired form. Returns true if a shift was initiated.
    --- @param player game_object
    --- @param desired_form string "cat", "bear", "travel", "moonkin", "caster"
    --- @return boolean true if a form shift was cast (caller should yield frame)
    function helpers:ensure_form(player, desired_form)
        if not player then return false end

        local current = self:get_current_form(player)

        -- Already in desired form
        if desired_form == "cat" and current == "cat" then return false end
        if desired_form == "bear" and (current == "bear" or current == "dire_bear") then return false end
        if desired_form == "travel" and current == "travel" then return false end
        if desired_form == "moonkin" and current == "moonkin" then return false end
        if desired_form == "caster" and current == "caster" then return false end

        -- Need to shift out first if in a different form (to go to caster first)
        if current ~= "caster" and desired_form ~= "caster" then
            -- Cancel current form by re-casting it
            return self:_cancel_current_form(player, current)
        end

        -- Now in caster form, shift to desired
        if desired_form == "cat" then
            return self:try_cast("forms", "cat_form", player)
        elseif desired_form == "bear" then
            -- Prefer Dire Bear if available
            if self:is_spell_learned("forms", "dire_bear_form") then
                return self:try_cast("forms", "dire_bear_form", player)
            else
                return self:try_cast("forms", "bear_form", player)
            end
        elseif desired_form == "travel" then
            return self:try_cast("forms", "travel_form", player)
        elseif desired_form == "moonkin" then
            return self:try_cast("forms", "moonkin_form", player)
        elseif desired_form == "caster" then
            return self:_cancel_current_form(player, current)
        end

        return false
    end

    --- Cancel current form by recasting it (toggles off)
    function helpers:_cancel_current_form(player, current)
        if current == "cat" then
            return self:try_cast("forms", "cat_form", player)
        elseif current == "bear" then
            return self:try_cast("forms", "bear_form", player)
        elseif current == "dire_bear" then
            return self:try_cast("forms", "dire_bear_form", player)
        elseif current == "travel" then
            return self:try_cast("forms", "travel_form", player)
        elseif current == "moonkin" then
            return self:try_cast("forms", "moonkin_form", player)
        elseif current == "aquatic" then
            return self:try_cast("forms", "aquatic_form", player)
        end
        return false
    end

    -- ========================================================================
    -- POWERSHIFTING (Cat DPS optimization)
    -- ========================================================================

    --- Attempt a powershift: leave Cat Form and re-enter for energy reset
    --- Uses Furor talent (40 energy) + Wolfshead Helm (20 energy) = 60 energy on shift-in
    --- Should only be called when energy is very low (<= 10)
    --- @param player game_object
    --- @return boolean true if powershift action was taken
    function helpers:try_powershift(player)
        if not player then return false end
        if not self:get_menu_state("cat_use_powershift") then return false end

        local now = core.time()

        if powershift_state.phase == "idle" then
            -- Only powershift if in cat form and energy is very low
            if not self:is_in_cat_form(player) then return false end

            local energy = self:get_energy(player)
            if energy > 10 then return false end

            -- Check mana: powershifting costs mana to shift forms
            local mana_pct = self:get_mana_pct(player)
            if mana_pct < 10 then return false end -- Not enough mana to shift

            -- Start powershift: shift OUT of cat form
            powershift_state.phase = "shifting_out"
            powershift_state.timestamp = now

            -- Cancel cat form
            if self:try_cast("forms", "cat_form", player) then
                self:log_checkpoint("powershift", 2.0, "[Druid][Cat] Powershifting - shifting out, energy=" .. energy)
                return true
            end

            powershift_state.phase = "idle"
            return false

        elseif powershift_state.phase == "shifting_out" then
            -- Waiting to shift back in
            if (now - powershift_state.timestamp) < POWERSHIFT_SHIFT_DELAY_MS then
                return true -- Still waiting
            end

            -- Should be in caster form now, shift back to cat
            if self:is_in_caster_form(player) then
                powershift_state.phase = "idle"
                if self:try_cast("forms", "cat_form", player) then
                    self:log_checkpoint("powershift", 2.0, "[Druid][Cat] Powershifting - shifting back in")
                    return true
                end
            end

            -- Timeout or error - reset
            if (now - powershift_state.timestamp) > 1000 then
                powershift_state.phase = "idle"
            end

            return true -- Still in process
        end

        return false
    end

    --- Check if a powershift is currently in progress
    function helpers:is_powershifting()
        return powershift_state.phase ~= "idle"
    end

    --- Reset powershift state (call when entering combat fresh, etc.)
    function helpers:reset_powershift()
        powershift_state.phase = "idle"
        powershift_state.timestamp = 0
    end

    -- ========================================================================
    -- ROOT-BREAKING VIA SHAPESHIFT (PvP)
    -- ========================================================================

    --- Attempt to break roots/snares by shapeshifting
    --- Shifts out of current form and back to break root effects
    --- @param player game_object
    --- @return boolean true if root-breaking action was taken
    function helpers:try_break_roots(player)
        if not player then return false end
        if not self:is_pvp_mode() then return false end
        if not self:get_menu_state("pvp_break_roots") then return false end
        if not self:is_rooted_or_snared(player) then return false end

        local now = core.time()

        if root_break_state.phase == "idle" then
            local current = self:get_current_form(player)

            -- Check mana for shifting
            local mana_pct = self:get_mana_pct(player)
            if mana_pct < 8 then return false end

            root_break_state.phase = "shifting_out"
            root_break_state.timestamp = now
            root_break_state.original_form = current

            if current == "caster" then
                -- Already in caster, shift to any form (Travel preferably for escape)
                local level = self:get_player_level(player)
                if level >= 30 and self:is_spell_learned("forms", "travel_form") then
                    if self:try_cast("forms", "travel_form", player) then
                        root_break_state.phase = "idle" -- Single shift is enough
                        self:log_checkpoint("rootbreak", 1.0, "[Druid][PvP] Breaking root -> Travel Form")
                        return true
                    end
                elseif self:is_spell_learned("forms", "cat_form") then
                    if self:try_cast("forms", "cat_form", player) then
                        root_break_state.phase = "idle"
                        return true
                    end
                elseif self:is_spell_learned("forms", "bear_form") then
                    if self:try_cast("forms", "bear_form", player) then
                        root_break_state.phase = "idle"
                        return true
                    end
                end
                root_break_state.phase = "idle"
                return false
            else
                -- In a form: cancel form (breaks root), then re-enter
                if self:_cancel_current_form(player, current) then
                    self:log_checkpoint("rootbreak", 1.0, "[Druid][PvP] Breaking root - shifting out of " .. current)
                    return true
                end
                root_break_state.phase = "idle"
                return false
            end

        elseif root_break_state.phase == "shifting_out" then
            if (now - root_break_state.timestamp) < ROOT_BREAK_DELAY_MS then
                return true
            end

            -- Shift back to original form
            local orig = root_break_state.original_form
            root_break_state.phase = "idle"

            if orig and orig ~= "caster" then
                return self:ensure_form(player, orig)
            end

            return false
        end

        return false
    end

    -- ========================================================================
    -- TRAVEL FORM ESCAPE (Hardcore / PvP)
    -- ========================================================================

    --- Attempt to escape via Travel Form when HP is critical
    --- @param player game_object
    --- @return boolean true if escape action taken
    function helpers:try_travel_form_escape(player)
        if not player then return false end

        local level = self:get_player_level(player)
        if level < 30 then return false end
        if not self:is_spell_learned("forms", "travel_form") then return false end

        local hp_threshold = self:get_menu_value("pvp_travel_escape_hp", 25)
        local hp = self:get_player_hp(player)
        if hp >= hp_threshold then return false end

        -- Don't escape if already in travel form
        if self:is_in_travel_form(player) then return false end

        -- Shift to travel form for escape
        if self:ensure_form(player, "travel") then
            self:log_checkpoint("escape", 2.0, "[Druid][Survival] Emergency Travel Form escape at HP=" .. math.floor(hp))
            return true
        end

        return false
    end

    -- ========================================================================
    -- EMERGENCY BEAR SHIFT (Hardcore)
    -- ========================================================================

    --- Emergency shift to Bear Form when HP is critically low (any spec)
    --- @param player game_object
    --- @return boolean true if emergency bear shift was initiated
    function helpers:try_emergency_bear(player)
        if not player then return false end

        -- Only in hardcore mode
        if not self:is_hardcore_mode() then return false end

        local hp_threshold = self:get_menu_value("emergency_bear_hp", 30)
        local hp = self:get_player_hp(player)
        if hp >= hp_threshold then return false end

        -- Already in bear form
        if self:is_in_bear_form(player) then return false end

        -- Don't override if already escaping in travel form
        if self:is_in_travel_form(player) then return false end

        local level = self:get_player_level(player)
        if level < 10 then return false end

        -- Shift to bear for armor bonus
        if self:ensure_form(player, "bear") then
            self:log_checkpoint("emergency_bear", 2.0, "[Druid][HC] Emergency Bear Form at HP=" .. math.floor(hp))
            return true
        end

        return false
    end

end -- forms.register

return forms
