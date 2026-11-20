-- Shared helper for selecting interrupt targets (Project Sylvanas / izi-friendly)
local performance = require("shared/rotation_performance")
-- Keeps logic generic so rotations can reuse it (player interrupts, pet interrupts, etc.)

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

local targeting = {}

---@param unit game_object
---@return number
local function get_spell_cast_time_left_seconds(unit)
    if not unit then
        return 0.0
    end

    local cast_end = 0.0
    pcall(function() cast_end = unit:get_active_spell_cast_end_time() or 0.0 end)
    if cast_end <= 0.0 then
        return 0.0
    end

    local now_ms = core.game_time()
    local now_s = core.time()

    local left_ms = cast_end - now_ms
    if left_ms > -1000 and left_ms < 120000 then
        return left_ms > 0 and (left_ms / 1000.0) or 0.0
    end

    local left_s = cast_end - now_s
    if left_s > -1 and left_s < 120 then
        return left_s > 0 and left_s or 0.0
    end

    if cast_end > 100000 then
        return left_ms > 0 and (left_ms / 1000.0) or 0.0
    end

    return left_s > 0 and left_s or 0.0
end

---@param unit game_object
---@return boolean
local function safe_is_casting_interruptable(unit)
    if not unit or not unit.is_valid or not unit:is_valid() or unit:is_dead() then
        return false
    end

    if not unit:is_casting_spell() then
        return false
    end

    return unit:is_active_spell_interruptable() == true
end

---@param local_player game_object
---@param range_yards number
---@param predicate fun(enemy: game_object): boolean|nil
---@return game_object|nil best_target, number|nil best_time_left
function targeting.find_best_interrupt_target(local_player, range_yards, predicate)
    if not local_player then
        return nil, nil
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return nil, nil
    end

    local range = range_yards or 30
    local enemies = performance:get_enemy_list_around(unit_helper, player_pos, range, true, false, false, false)
    if not enemies or #enemies == 0 then
        return nil, nil
    end

    local best_target = nil
    local best_time_left = nil

    for _, enemy in ipairs(enemies) do
        if not safe_is_casting_interruptable(enemy) then
            goto continue
        end

        if predicate and predicate(enemy) ~= true then
            goto continue
        end

        local time_left = get_spell_cast_time_left_seconds(enemy)

        if not best_time_left or time_left < best_time_left then
            best_target = enemy
            best_time_left = time_left
        end

        ::continue::
    end

    return best_target, best_time_left
end

return targeting
