local game_client = {}

local function safe_lower(s)
    if s == nil then
        return ""
    end
    return tostring(s):lower()
end

---@return string
function game_client.get_game_version_string()
    if core then
        if core.get_game_version then
            local gv = core.get_game_version()
            if gv and gv ~= "" then
                return gv
            end
        end
        if core.get_exact_game_version then
            local egv = core.get_exact_game_version()
            if egv and egv ~= "" then
                return egv
            end
        end
    end
    return ""
end

---@return '"era"'|'"tbc"'|'"mop"'|'"retail"'|'"unknown"'
function game_client.get_flavor()
    local gv = safe_lower(game_client.get_game_version_string())

    -- New API strings: "Midnight", "Vanilla", "Tbc", "Mop", "Titan", "Forever"
    if gv == "midnight" then
        return "retail"
    end
    if gv == "vanilla" or gv == "forever" then
        return "era"
    end
    if gv == "tbc" then
        return "tbc"
    end
    if gv == "mop" then
        return "mop"
    end
    if gv == "titan" then
        return "retail"
    end

    -- Descriptive / fallback strings ("Classic Era", "Classic TBC", "Retail", "WoW Forever", etc.)
    if gv:find("retail", 1, true) then
        return "retail"
    end
    if gv:find("tbc", 1, true) then
        return "tbc"
    end
    if gv:find("pandaria", 1, true) then
        return "mop"
    end
    if gv:find("era", 1, true) or gv:find("forever", 1, true) or gv:find("classic", 1, true) then
        return "era"
    end

    return "unknown"
end

---@return boolean
function game_client.is_retail()
    return game_client.get_flavor() == "retail"
end

---@return boolean
function game_client.is_tbc()
    return game_client.get_flavor() == "tbc"
end

---@return boolean
function game_client.is_era()
    return game_client.get_flavor() == "era"
end

return game_client
