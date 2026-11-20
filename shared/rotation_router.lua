local rotation_router = {}

local game_client = require("shared/game_client")

local function is_module_not_found_error(err, module_name)
    local msg = tostring(err or "")
    -- Lua's default require error includes: "module 'X' not found:"
    return msg:find("module '" .. module_name .. "' not found", 1, true) ~= nil
end

---@param class_dir string e.g. "warrior"
---@return table|nil rotation_module
---@return string loaded_module_name
---@return string|nil error_message
function rotation_router.require_class_main(class_dir)
    local flavor = game_client.get_flavor()

    local candidates = {}
    if flavor == "tbc" then
        candidates = {
            "rotations/" .. class_dir .. "/tbc/main",
            "rotations/" .. class_dir .. "/era/main"
        }
    elseif flavor == "era" then
        candidates = {
            "rotations/" .. class_dir .. "/era/main",
        }
    else
        candidates = {
            "rotations/" .. class_dir .. "/" .. flavor .. "/main",
            "rotations/" .. class_dir .. "/era/main"
        }
    end

    for i, module_name in ipairs(candidates) do
        local ok, mod_or_err = pcall(require, module_name)
        if ok then
            return mod_or_err, module_name, nil
        end

        local can_fallback = (i < #candidates) and is_module_not_found_error(mod_or_err, module_name)
        if not can_fallback then
            return nil, module_name, tostring(mod_or_err)
        end
    end

    return nil, candidates[#candidates] or "", "unknown error"
end

return rotation_router
