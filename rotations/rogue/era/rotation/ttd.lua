-- SDK forecasts use 1.1 for unavailable data. Never treat it as imminent death.
local ttd = {}
local tracked_guid, sample = nil, nil
local function finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
local function clear_sample()
    tracked_guid=nil;sample=nil
end
function ttd.get(target)
    -- Selector objects can expire after a kill/despawn or a native action.
    -- Protect the entire snapshot: a successful validity check alone is not
    -- sufficient if the object disappears before its health is read.
    local ok,hp,hp_percent,guid=pcall(function()
        if not target or not target:is_valid() or target:is_dead() then return nil end
        return target:get_health(),target:get_health_percentage(),target:get_guid()
    end)
    if not ok or not finite(hp) or hp<=0 or not finite(hp_percent) or type(guid)~="string" or guid=="" then
        clear_sample()
        return nil,false
    end
    local now=core.time()
    -- Never retain/compare game objects: native __eq can dereference an expired
    -- PREVIOUS target even when the current target is valid. Keep only its GUID.
    if tracked_guid~=guid or not sample or now<sample.at or now-sample.at>2 or hp>sample.hp then
        tracked_guid=guid;sample={at=now,hp=hp,start=now,initial=hp,estimate=nil}
    elseif now-sample.at>=0.1 then
        sample.at=now;sample.hp=hp
        local elapsed=now-sample.start
        local loss=sample.initial-hp
        sample.estimate=elapsed>=0.75 and loss>0 and hp/(loss/elapsed) or nil
        if elapsed>=4 then sample.start=now;sample.initial=hp end
    end
    local forecast_ok,value=pcall(function()
        if target.has_time_to_die_data and not target:has_time_to_die_data() then return nil end
        return target:time_to_die()
    end)
    if forecast_ok and finite(value) and value>0
        and value~=1.1 and math.abs(value-61.22)>0.001 then return value,true,hp_percent end
    return sample.estimate,true,hp_percent
end
function ttd.finish_soon(target,cp)
    if cp<1 then return false end
    local value,valid,hp_percent=ttd.get(target)
    if not valid then return false end
    return (value~=nil and value<=2.5) or (cp>=3 and hp_percent<20)
end
return ttd
