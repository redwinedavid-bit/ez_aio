local __object_safety=require("shared/object_safety")
-- 60 FPS decision cadence; elapsed-time caches contain candidate lists only.
-- Health, cast state, cooldowns, engagement and castability remain live reads.
local performance = {}
performance.__load_revision = "AF-WAR-20261114-PACK-SHIELD-VERIFY1"
local FRAME_MS = 1000 / 60
local next_decision_ms, last_now_ms, owner, target
local scan_interval_ms = 100
local candidates = {}
local frame_auras = {}
local aura_time_ms = nil
local MAX_QUERIES = 64
local unpack_args = table.unpack or unpack

local function copy_list(value)
    return __object_safety.copy_live_list(value)
end

local function reset()
    candidates = {}
    frame_auras = {}
    aura_time_ms = nil
end

function performance:begin_update(player, menu, now_ms)
    local now = now_ms or core.game_time()
    -- Store primitive identity only. Native game-object equality can throw
    -- when the cached player or previous target has expired.
    local ok,player_guid,target_guid=pcall(function()
        if not player or not player:is_valid() then return nil end
        local guid=player:get_guid()
        if type(guid)~="string" or guid=="" then return nil end
        local current=player:get_target()
        if not current then return guid,nil end
        if not current:is_valid() then return nil end
        local current_guid=current:get_guid()
        if type(current_guid)~="string" or current_guid=="" then return nil end
        return guid,current_guid
    end)
    if not ok or not player_guid then
        owner=nil;target=nil;last_now_ms=nil;next_decision_ms=nil
        reset()
        return false
    end
    if player_guid ~= owner or (last_now_ms and (now < last_now_ms or now - last_now_ms > 1000)) then
        owner = player_guid
        next_decision_ms = nil
        reset()
    elseif target_guid ~= target then
        reset()
    end
    target = target_guid
    last_now_ms = now
    local interval = 100
    if menu and menu.enable_pvp_mode and menu.enable_pvp_mode:get_state() then
        interval = menu.pvp_rotation_tick_rate and menu.pvp_rotation_tick_rate:get() or 30
    end
    interval = math.max(30, math.min(100, tonumber(interval) or 100))
    if interval ~= scan_interval_ms then reset() end
    scan_interval_ms = interval
    -- game_time may be integer milliseconds. Allow its <1 ms quantization
    -- without turning a normal 16/17 ms frame cadence into 30 FPS decisions.
    if next_decision_ms and now + 0.999 < next_decision_ms then return false end
    if not next_decision_ms then
        next_decision_ms = now + FRAME_MS
    else
        local steps = math.max(1, math.floor((now - next_decision_ms) / FRAME_MS) + 1)
        next_decision_ms = next_decision_ms + steps * FRAME_MS
    end
    frame_auras = {}
    aura_time_ms = now
    return true
end

local function same_args(entry, args)
    if entry.args.n ~= args.n then return false end
    for i = 1, args.n do
        if not rawequal(entry.args[i],args[i]) then return false end
    end
    return true
end

local function query(source, method, position, interval, ...)
    -- Outside a configured rotation update, preserve the original SDK path.
    local now = core.game_time()
    if not owner or not last_now_ms or now < last_now_ms or now - last_now_ms > 1000 or not position then
        return copy_list(source[method](source, ...))
    end
    local x, y, z = position.x, position.y, position.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return copy_list(source[method](source, ...))
    end
    local args = { n = select("#", ...), ... }
    -- Position is an argument of the helper scan, but use its coordinates for
    -- matching: SDKs can allocate a new vector for every get_position call.
    local key_start = method == "get_enemy_list_around" and 2 or 1
    local match_args = { n = args.n - key_start + 1 }
    for i = key_start, args.n do match_args[i - key_start + 1] = args[i] end
    local oldest_index, oldest_time = 1, math.huge
    for i, entry in ipairs(candidates) do
        if entry.time < oldest_time then oldest_index, oldest_time = i, entry.time end
        if rawequal(entry.source,source) and entry.method == method and same_args(entry, match_args) then
            local dx, dy, dz = x - entry.x, y - entry.y, z - entry.z
            if now >= entry.time and now - entry.time < interval and dx*dx + dy*dy + dz*dz <= 1 then
                return copy_list(entry.value)
            end
            -- Refresh the matching query in place, including movement/teleports.
            local value = source[method](source, unpack_args(args, 1, args.n))
            if type(value) ~= "table" then return value end
            entry.x, entry.y, entry.z, entry.time = x, y, z, now
            entry.value = copy_list(value)
            return copy_list(value)
        end
    end
    local value = source[method](source, unpack_args(args, 1, args.n))
    if type(value) == "table" then
        local entry = {source=source, method=method, args=match_args, x=x, y=y, z=z, time=now, value=copy_list(value)}
        if #candidates < MAX_QUERIES then candidates[#candidates + 1] = entry
        else candidates[oldest_index] = entry end
    end
    return copy_list(value)
end

function performance:get_enemy_list_around(helper, position, ...)
    return query(helper, "get_enemy_list_around", position, scan_interval_ms, position, ...)
end

function performance:get_unit_list(unit, method, ...)
    if not __object_safety.valid(unit) then return {} end
    if not owner or not unit.get_position then return copy_list(unit[method](unit, ...)) end
    local ok,position=pcall(unit.get_position,unit)
    if not ok then
        if __object_safety.is_invalid_error(position) then return {} end
        error(position,0)
    end
    local interval = (method == "get_party_members" or method == "get_party_members_in_range") and 250 or scan_interval_ms
    return query(unit, method, position, interval, ...)
end

-- Warrior stance and defensive-aura checks reuse a snapshot only within the
-- current decision. No aura lifetime is cached across decision frames.
function performance:get_auras(unit)
    if not __object_safety.valid(unit) then return {} end
    local now = core.game_time()
    if not owner or aura_time_ms ~= now then return unit:get_auras() end
    local cached = frame_auras[unit]
    if cached then return cached end
    local value = unit:get_auras()
    if value then frame_auras[unit] = value end
    return copy_list(value)
end

return performance
