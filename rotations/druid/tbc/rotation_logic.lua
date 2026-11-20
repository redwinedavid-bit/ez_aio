-- ============================================================================
-- Druid Rotation Logic - TBC (2.4.3)
-- Thin wrapper: delegates to rotation/init.lua
-- ============================================================================

local rotation_logic = {}

local rotation = require("rotations/druid/tbc/rotation/init")

function rotation_logic:execute(player, menu, tick_tracker)
    return rotation:execute(player, menu, tick_tracker)
end

return rotation_logic
