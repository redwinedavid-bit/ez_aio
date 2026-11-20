local log_capture = {}

local original_core_log = nil
local wrapper_installed = false
local file_enabled = false
local log_file_name = nil

local function safe_core_time()
    local ok, v = pcall(function()
        return core.time()
    end)
    if ok and type(v) == "number" then
        return v
    end
    return 0
end

local function ensure_wrapper()
    if wrapper_installed then
        return true
    end

    if not core or type(core.log) ~= "function" then
        return false
    end

    original_core_log = core.log

    local ok_set = pcall(function()
        core.log = function(message)
            local now = safe_core_time()
            if file_enabled and log_file_name then
                pcall(function()
                    core.write_log_file(log_file_name, string.format("[%d] %s\n", math.floor(now or 0), tostring(message)))
                end)
            end
            pcall(original_core_log, message)
        end
    end)

    wrapper_installed = ok_set == true
    return wrapper_installed
end

local function create_new_log_file(prefix)
    local now = safe_core_time()
    local stem = tostring(prefix or "rotation")
    log_file_name = string.format("%s_%d.txt", stem, math.floor(now or 0))

    local ok_create = pcall(function()
        core.create_log_file(log_file_name)
    end)
    if ok_create then
        pcall(function()
            core.write_log_file(log_file_name, string.format("[LOG] start t=%d\n", math.floor(now or 0)))
        end)
        return true
    end

    log_file_name = nil
    return false
end

---@param enabled boolean
---@param opts table|nil { prefix: string|nil }
---@return boolean ok
function log_capture:set_enabled(enabled, opts)
    local want = enabled == true
    if want == file_enabled and wrapper_installed then
        return true
    end

    if not ensure_wrapper() then
        file_enabled = false
        log_file_name = nil
        return false
    end

    file_enabled = want
    if not file_enabled then
        log_file_name = nil
        return true
    end

    local prefix = opts and opts.prefix or "rotation"
    return create_new_log_file(prefix)
end

---@return boolean
function log_capture:is_enabled()
    return file_enabled == true and log_file_name ~= nil
end

---@return string|nil
function log_capture:get_file_name()
    return log_file_name
end

return log_capture

