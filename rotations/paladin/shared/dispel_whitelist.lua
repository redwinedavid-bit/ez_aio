-- Paladin Dispel Whitelist (persisted via core.menu text_input)
-- Used by both ERA and TBC paladin rotations.

local M = {}

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_entry(s)
    s = trim(s)
    if s == "" then
        return nil
    end
    s = s:gsub("\"", ""):gsub("'", "")
    s = trim(s)
    if s == "" then
        return nil
    end
    return s
end

local function normalize_key(s)
    if type(s) ~= "string" then
        return nil
    end
    s = normalize_entry(s)
    if not s then
        return nil
    end
    return string.lower(s)
end

local function parse_serialized(text)
    local entries = {}
    local set = {}
    if type(text) ~= "string" or text == "" then
        return entries, set
    end

    -- Split on newlines/commas/semicolons; keep stable order.
    for token in string.gmatch(text, "([^,\n;]+)") do
        local entry = normalize_entry(token)
        local key = normalize_key(entry)
        if entry and key and not set[key] then
            set[key] = true
            table.insert(entries, entry)
        end
    end

    return entries, set
end

local function serialize_entries(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return ""
    end
    return table.concat(entries, "\n")
end

local cache = {
    last_text = nil,
    entries = {},
    set = {}
}

local function get_storage_text(menu)
    if not menu or not menu.dispel_whitelist_storage or not menu.dispel_whitelist_storage.get_text then
        return ""
    end
    local ok, text = pcall(function()
        return menu.dispel_whitelist_storage:get_text()
    end)
    if not ok or type(text) ~= "string" then
        return ""
    end
    return text
end

local function set_storage_text(menu, text)
    if not menu or not menu.dispel_whitelist_storage or not menu.dispel_whitelist_storage.set then
        return false
    end
    local ok = pcall(function()
        menu.dispel_whitelist_storage:set(type(text) == "string" and text or "")
    end)
    return ok == true
end

---@param menu table
---@return table entries, table set
function M.get(menu)
    local text = get_storage_text(menu)
    if cache.last_text ~= text then
        cache.last_text = text
        cache.entries, cache.set = parse_serialized(text)
    end
    return cache.entries, cache.set
end

---@param menu table
---@param unit game_object
---@return boolean
function M.is_unit_whitelisted(menu, unit)
    if not unit or not unit.get_name then
        return false
    end
    local ok, name = pcall(function()
        return unit:get_name()
    end)
    if not ok or type(name) ~= "string" then
        return false
    end

    local _, set = M.get(menu)
    local key = normalize_key(name)
    return key and set[key] == true or false
end

---@param menu table
---@param entry string
---@return boolean changed
function M.add(menu, entry)
    local e = normalize_entry(entry)
    local k = normalize_key(e)
    if not e or not k then
        return false
    end

    local entries, set = M.get(menu)
    if set[k] then
        return false
    end

    table.insert(entries, e)
    set[k] = true
    local serialized = serialize_entries(entries)
    cache.last_text = serialized
    return set_storage_text(menu, serialized)
end

---@param menu table
---@param keys_to_remove table<string, boolean>
---@return boolean changed
function M.remove_keys(menu, keys_to_remove)
    if type(keys_to_remove) ~= "table" then
        return false
    end

    local entries, _ = M.get(menu)
    if #entries == 0 then
        return false
    end

    local new_entries = {}
    local new_set = {}
    local changed = false

    for _, entry in ipairs(entries) do
        local k = normalize_key(entry)
        if k and keys_to_remove[k] == true then
            changed = true
        elseif k and not new_set[k] then
            new_set[k] = true
            table.insert(new_entries, entry)
        end
    end

    if not changed then
        return false
    end

    local serialized = serialize_entries(new_entries)
    cache.entries = new_entries
    cache.set = new_set
    cache.last_text = serialized
    return set_storage_text(menu, serialized)
end

---@param menu table
---@param old_key string
---@param new_entry string
---@return boolean changed
function M.rename_key(menu, old_key, new_entry)
    local oldk = normalize_key(old_key)
    local e = normalize_entry(new_entry)
    local newk = normalize_key(e)
    if not oldk or not e or not newk then
        return false
    end

    local entries, set = M.get(menu)
    if not set[oldk] then
        return false
    end
    if set[newk] and newk ~= oldk then
        return false
    end

    local changed = false
    for i, entry in ipairs(entries) do
        local k = normalize_key(entry)
        if k == oldk then
            entries[i] = e
            changed = true
            break
        end
    end
    if not changed then
        return false
    end

    -- Rebuild set in case casing/duplicates changed.
    local serialized = serialize_entries(entries)
    cache.last_text = serialized
    cache.entries, cache.set = parse_serialized(serialized)
    return set_storage_text(menu, serialized)
end

return M

