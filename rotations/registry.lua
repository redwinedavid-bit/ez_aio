-- <--astro_file-->
local registry = {}

---@type enums
local enums = require("common/enums")

local rotation_router = require("shared/rotation_router")
local game_client = require("shared/game_client")

registry.by_class =
{
    [enums.class_id.WARRIOR] = "warrior",
    [enums.class_id.PALADIN] = "paladin",
    [enums.class_id.ROGUE] = "rogue",
    [enums.class_id.HUNTER] = "hunter",
    [enums.class_id.WARLOCK] = "warlock",
    [enums.class_id.PRIEST] = "priest",
    [enums.class_id.SHAMAN] = "shaman",
    [enums.class_id.MAGE] = "mage",
    [enums.class_id.DRUID] = "druid",
}

local logged_missing = {}

---@param local_player game_object|nil
---@return table|nil
function registry:resolve(local_player)
    if not local_player then
        return nil
    end
    
    local class_id = local_player:get_class()
    local class_dir = self.by_class[class_id]
    if not class_dir then
        if not logged_missing[class_id] then
            logged_missing[class_id] = true
            core.log_error("[AIO] No rotation available for this class yet.")
        end
        return nil
    end

    local mod, loaded_module_name, err = rotation_router.require_class_main(class_dir)
    if not mod then
        if not logged_missing[class_id] then
            logged_missing[class_id] = true
            core.log_error(string.format(
                "[AIO] Failed to load rotation module '%s' (client=%s): %s",
                tostring(loaded_module_name),
                tostring(game_client.get_game_version_string()),
                tostring(err)
            ))
        end
        return nil
    end

    return mod
end

return registry
