local __object_safety=require("shared/object_safety")
-- Pack discovery is timed; victim/role/health checks are evaluated per decision.
local performance = require("shared/rotation_performance")
local unit_helper = require("common/utility/unit_helper")
local threat = {}
threat.__load_revision = "AF-WAR-20261114-PACK-SHIELD-VERIFY1"
local owner, last_now, last_focus, last_focus_ms
local states = setmetatable({}, { __mode = "k" })
local touched = setmetatable({}, { __mode = "k" })
local protected_text, protected_names = nil, {}
local last_taunt_ms = -math.huge

local function read(unit, method, ...)
    if not unit or type(unit[method]) ~= "function" then return nil end
    local ok, value = pcall(unit[method], unit, ...)
    if ok then return value end
end

local function setting(menu, key, default)
    local option = menu and menu[key]
    if not option or not option.get then return default end
    local value = tonumber(option:get())
    if not value or value ~= value then return default end
    return value
end

local function short_name(value)
    return tostring(value or ""):lower():match("^%s*([^%s,;%-]+)") or ""
end

local function refresh_protected(menu)
    local option = menu and menu.tank_protected_tank_names
    local value = option and option.get_text and option:get_text() or ""
    if value == protected_text then return end
    protected_text, protected_names = value, {}
    for name in value:gmatch("[^,;]+") do
        local key=short_name(name)
        if key~="" then protected_names[key] = true end
    end
    states = setmetatable({}, { __mode = "k" })
end

local function role(unit)
    if protected_names[short_name(read(unit, "get_name"))] then return "tank" end
    -- Positive tank detection overrides conflicting healer/DPS role data.
    if read(unit, "is_tank") == true then return "tank" end
    local value = read(unit, "get_role")
    if type(value) == "string" then
        value = value:lower()
        if value == "tank" or value == "maintank" or value == "main_tank" then return "tank" end
        if value == "healer" or value == "heal" then return "healer" end
        if value == "damager" or value == "damage" or value == "dps" then return "dps" end
    end
    if read(unit, "is_healer") == true then return "healer" end
    -- Numeric role encodings and false booleans are not enough to prove DPS.
    return "unknown"
end

local function percent(info)
    local value = info and tonumber(info.threat_percent)
    if value and value == value and value >= 0 and value < math.huge then return value end
end

local function distance_sq(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = (a.x or 0)-(b.x or 0), (a.y or 0)-(b.y or 0), (a.z or 0)-(b.z or 0)
    return dx*dx + dy*dy + dz*dz
end

function threat.assess(player, current_target, menu)
    local now = core.game_time()
    if (not __object_safety.same(player,owner)) or (last_now and (now < last_now or now-last_now > 1000)) then
        owner, states, touched = player, setmetatable({}, {__mode="k"}), setmetatable({}, {__mode="k"})
        last_focus, last_focus_ms, last_taunt_ms = nil, nil, -math.huge
    end
    last_now = now
    refresh_protected(menu)
    local pack = { entries={}, attacks={}, now=now, by_unit={}, aoe_safe=true }
    local position = read(player, "get_position")
    if not position then return pack end
    local ok, members = pcall(performance.get_unit_list, performance, player, "get_party_members_in_range", 40, true)
    members = ok and members or {}
    local allies, roles = {[player]=true}, {}
    for _, member in ipairs(members or {}) do
        if member and (not __object_safety.same(member,player)) then allies[member], roles[member] = true, role(member) end
    end
    local range = math.max(10, math.min(40, setting(menu, "tank_threat_scan_range", 30)))
    local enemies = performance:get_enemy_list_around(unit_helper, position, range, true, false, false, false) or {}
    -- Include a newly selected mob immediately, even before the next discovery scan.
    local list, seen = {}, {}
    if current_target then list[1] = current_target end
    for _, enemy in ipairs(enemies) do list[#list+1] = enemy end
    for _, enemy in ipairs(list) do
        if not seen[enemy] then
            seen[enemy] = true
            local d2 = distance_sq(position, read(enemy, "get_position"))
            if read(enemy,"is_valid_enemy") == true and read(enemy,"is_alive") == true
                and read(enemy,"is_player") ~= true and d2 <= range*range then
                local state = states[enemy]
                if not state then state={};states[enemy]=state end
                if not state.numbers_at or now-state.numbers_at >= 100 then
                    state.own = read(player,"get_threat_situation",enemy)
                    state.party_peak = nil
                    state.other_tank_holds = false
                    for member, member_role in pairs(roles) do
                        local info=read(member,"get_threat_situation",enemy)
                        if member_role == "tank" then
                            if info and info.is_tanking==true then state.other_tank_holds=true end
                        else
                            local p = percent(info)
                            if p then state.party_peak = math.max(state.party_peak or 0,p) end
                        end
                    end
                    state.numbers_at = now
                end
                local victim = read(enemy,"get_target")
                local own_pct = percent(state.own)
                local tanking = state.own and state.own.is_tanking == true
                local combat = read(enemy,"affecting_combat")
                if combat == nil then combat=read(enemy,"is_in_combat") end
                local engaged = combat ~= false and (allies[victim] == true or tanking or (own_pct and own_pct>0))
                -- With neither combat nor threat evidence, do not pull an idle mob
                -- just because its selection happens to point at a party member.
                if combat == nil and not tanking and not (own_pct and own_pct>0) then engaged=false end
                if engaged then
                    local victim_role = roles[victim]
                    local protected = ((not __object_safety.same(victim,player)) and victim_role == "tank") or state.other_tank_holds
                    if protected and d2<=64 then pack.aoe_safe=false end
                    local recover = not protected and (not __object_safety.same(victim,player)) and allies[victim] == true and not tanking
                    if recover then
                        if not state.loss_since or not state.seen_at or now-state.seen_at>500 then state.loss_since=now end
                    else state.loss_since=nil end
                    state.seen_at=now
                    local priority = 100
                    if recover then priority = victim_role=="healer" and 400 or victim_role=="dps" and 300 or 250
                    elseif tanking and state.party_peak and state.party_peak >= setting(menu,"tank_threat_warning_pct",85) then priority=200 end
                    local entry={unit=enemy,victim=victim,role=victim_role,protected=protected,recover=recover,
                        priority=priority,own_pct=own_pct,party_peak=state.party_peak,d2=d2,
                        loss_ms=state.loss_since and now-state.loss_since or 0,last_touch=touched[enemy] or -math.huge}
                    pack.entries[#pack.entries+1]=entry;pack.by_unit[enemy]=entry
                    if not protected and d2 <= 64 then pack.attacks[#pack.attacks+1]=entry end
                elseif d2<=64 then pack.aoe_safe=false end
            end
        end
    end
    local function before(a,b)
        if a.priority~=b.priority then return a.priority>b.priority end
        if a.last_touch~=b.last_touch then return a.last_touch<b.last_touch end
        if a.own_pct and b.own_pct and a.own_pct~=b.own_pct then return a.own_pct<b.own_pct end
        return a.d2<b.d2
    end
    table.sort(pack.entries,before);table.sort(pack.attacks,before)
    return pack
end

function threat.can_taunt(entry, menu)
    if not entry or not entry.recover or entry.protected then return false end
    -- Unknown roles fail closed rather than treating a second tank as DPS.
    if entry.role~="healer" and entry.role~="dps" then return false end
    local hp = tonumber(read(entry.victim,"get_health_percentage"))
    if hp and hp <= setting(menu,"tank_taunt_ally_emergency_hp_pct",40) then return true end
    if entry.d2>64 then return true end -- An immediate melee recovery is unavailable.
    local slight = setting(menu,"tank_taunt_slight_loss_pct",85)
    if entry.own_pct and entry.own_pct < slight then return true end
    return entry.loss_ms >= math.max(0,setting(menu,"tank_taunt_recovery_grace_ms",750))
end

function threat.taunt_attempt_ready()
    return core.game_time()-last_taunt_ms >= 350
end
function threat.note_taunt_attempt() last_taunt_ms=core.game_time() end
function threat.record_attack(unit) if unit then touched[unit]=core.game_time() end end

function threat.focus(pack, current_target)
    local best=pack.attacks[1]
    if not best then return nil end
    local current=pack.by_unit[current_target]
    if current and not current.protected and current.d2<=64 and current.priority>=best.priority
        and last_focus_ms and pack.now-last_focus_ms<500 then return current_target end
    if (not __object_safety.same(best.unit,last_focus)) then
        last_focus,last_focus_ms=best.unit,pack.now
        touched[best.unit]=pack.now
    end
    return best.unit
end

return threat
