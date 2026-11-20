local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock PvP Overlay (Classic ERA)
-- Renders per-enemy: DR status, DoT timers, CC status
-- Renders fixed position: Pet status
-- Ported from TBC overlay, simplified for ERA spell set
-- ============================================================================

local overlay = {}

---@type izi_sdk
local izi = require("common/izi_sdk")
---@type color
local color = require("common/color")

local spells    = require("rotations/warlock/era/spells")
local dr_helper = require("shared/dr_helper")

-- ============================================================================
-- UTILITY
-- ============================================================================

local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then return fallback end
    local ok, v = pcall(function() return menu[key]:get_state() end)
    if ok then return v end
    return fallback
end

local function hp_pct(unit)
    if not unit or not unit.get_health_percentage then return 0 end
    return tonumber(unit:get_health_percentage()) or 0
end

local function mana_pct(unit)
    if not unit or not unit.mana_pct then return 0 end
    return tonumber(unit:mana_pct()) or 0
end

-- DoTs to display (ERA spell set)
local DOT_LIST = {
    { key = "corruption",           name = "Corr" },
    { key = "curse_of_agony",       name = "CoA"  },
    { key = "siphon_life",          name = "SL"   },
    { key = "immolate",             name = "Immo" },
    { key = "curse_of_tongues",     name = "CoT"  },
    { key = "curse_of_exhaustion",  name = "CoEx" },
    { key = "curse_of_doom",        name = "CoD"  },
}

-- ============================================================================
-- PER-ENEMY OVERLAY
-- ============================================================================

local function render_enemy_overlay(enemy, menu)
    if not enemy or not enemy:is_valid_enemy() or not enemy:is_alive() then return end

    -- World-to-screen conversion
    local ok_pos, pos = pcall(function() return enemy:get_position() end)
    if not ok_pos or not pos then return end

    local ok_screen, sx, sy = pcall(function()
        local s = core.graphics.w2s(pos)
        if s then return s.x, s.y end
        return nil, nil
    end)
    if not ok_screen or not sx or not sy then return end

    local y_offset = -40  -- Start above the nameplate area

    -- 1. DR Status
    if menu_enabled(menu, "pvp_overlay_dr", true) then
        local fear_dr   = dr_helper.get_dr(enemy, "fear")
        local horror_dr = dr_helper.get_dr(enemy, "horror")

        -- Always show Fear DR for visibility
        if true then
            local fc = dr_helper.get_dr_color(fear_dr)
            core.graphics.text_2d(
                "Fear: " .. dr_helper.format_dr(fear_dr),
                { x = sx, y = sy + y_offset },
                12, fc, true
            )
            y_offset = y_offset + 14
        end

        if horror_dr < 1.0 then
            local hc = dr_helper.get_dr_color(horror_dr)
            core.graphics.text_2d(
                "Horror: " .. dr_helper.format_dr(horror_dr),
                { x = sx, y = sy + y_offset },
                12, hc, true
            )
            y_offset = y_offset + 14
        end

        -- DR reset timer
        local fear_reset = dr_helper.get_dr_reset_time(enemy, "fear")
        if fear_reset > 0 and fear_dr < 1.0 then
            core.graphics.text_2d(
                string.format("Reset: %.1fs", fear_reset),
                { x = sx, y = sy + y_offset },
                11, color.new(180, 180, 180, 200), true
            )
            y_offset = y_offset + 13
        end
    end

    -- 2. DoT Timers
    if menu_enabled(menu, "pvp_overlay_dots", true) then
        for _, dot in ipairs(DOT_LIST) do
            local spell = spells[dot.key]
            if spell then
                local ok_up, is_up = pcall(function() return enemy:debuff_up(spell:id()) end)
                if ok_up and is_up then
                    local ok_rem, remains = pcall(function() return enemy:debuff_remains_ms(spell:id()) end)
                    if ok_rem and remains then
                        local secs = remains / 1000
                        local dot_color = secs > 5
                            and color.new(100, 255, 100, 200)
                            or  color.new(255, 100, 100, 200)
                        core.graphics.text_2d(
                            string.format("%s: %.1fs", dot.name, secs),
                            { x = sx, y = sy + y_offset },
                            11, dot_color, true
                        )
                        y_offset = y_offset + 13
                    end
                end
            end
        end
    end

    -- 3. CC Status
    if menu_enabled(menu, "pvp_overlay_cc", true) then
        -- Check Fear
        local ok_fear, is_feared = pcall(function()
            return enemy.CC and enemy:is_cc(500, enemy.CC.FEAR)
        end)
        if ok_fear and is_feared then
            core.graphics.text_2d("FEARED", { x = sx, y = sy + y_offset },
                13, color.new(255, 200, 0, 255), true)
            y_offset = y_offset + 15
        end

        -- Check Horror (Death Coil)
        local ok_horror, is_horrified = pcall(function()
            return enemy.CC and enemy:is_cc(500, enemy.CC.HORROR)
        end)
        if ok_horror and is_horrified then
            core.graphics.text_2d("HORRIFIED", { x = sx, y = sy + y_offset },
                13, color.new(255, 150, 0, 255), true)
            y_offset = y_offset + 15
        end
    end
end

-- ============================================================================
-- PET STATUS (fixed screen position)
-- ============================================================================

local function render_pet_status(player, menu)
    if not menu_enabled(menu, "pvp_overlay_pet", true) then return end

    local pet = player:get_pet()
    if not pet or not pet:is_valid() then
        core.graphics.text_2d("Pet: NONE",
            { x = 20, y = 180 }, 13, color.new(255, 80, 80, 255), true)
        return
    end

    local alive = pet:is_alive()
    local pet_hp = hp_pct(pet)
    local pet_mp = mana_pct(pet)

    local status_color = alive
        and (pet_hp > 50 and color.new(100, 255, 100, 255) or color.new(255, 255, 0, 255))
        or color.new(255, 50, 50, 255)

    core.graphics.text_2d(
        string.format("Pet: %s  HP:%.0f%%  Mana:%.0f%%",
            alive and "ALIVE" or "DEAD", pet_hp, pet_mp),
        { x = 20, y = 180 }, 13, status_color, true
    )
end

-- ============================================================================
-- MAIN RENDER ENTRY
-- ============================================================================

--- Called from warlock:on_render() when PvP mode is active.
---@param player game_object
---@param menu table
function overlay.render(player, menu)
    if not menu_enabled(menu, "pvp_overlay_enabled", true) then return end
    if not player then return end

    -- Render per-enemy overlays
    local ok_enemies, enemies = pcall(function() return izi.enemies(40) end)
    if ok_enemies and enemies then
        for _, enemy in __object_safety.live_ipairs(enemies) do
            render_enemy_overlay(enemy, menu)
        end
    end

    -- Render pet status
    render_pet_status(player, menu)
end

return overlay
