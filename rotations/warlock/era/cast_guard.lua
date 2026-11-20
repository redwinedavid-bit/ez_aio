-- Native SDK immunity feedback and bounded CC retries, scoped to Warlock.
local safety=require('shared/object_safety')
local M={}
local owner=nil
local registered,targets={},{}
local last_cleanup=-math.huge
local categories={fear='fear',howl_of_terror='fear',death_coil='horror'}
local flags={fear='FEAR',howl_of_terror='FEAR',death_coil='HORROR',banish='BANISH'}
local controls={fear=true,howl_of_terror=true,death_coil=true,banish=true,enslave_demon=true}
local function row(guid,now)
    if now<last_cleanup or now-last_cleanup>=5000 then
        for key,value in pairs(targets) do
            if now<value.at or now-value.at>120000 then targets[key]=nil end
        end
        last_cleanup=now
    end
    targets[guid]=targets[guid] or {at=now,blocked={},attempts={}}
    targets[guid].at=now
    return targets[guid]
end
function M.allow(player,target,spell,key)
    local guid=safety.guid(target);local pg=safety.guid(player)
    if not guid or not pg then return false end
    if owner~=pg then owner=pg;targets={};registered={} end
    local id=spell:id();registered[id]=key
    local now=core.game_time();local state=row(guid,now)
    local category=categories[key]
    if now<(state.blocked[id] or 0) or (category and now<(state.blocked['cc:'..category] or 0)) then
        return false,'Immune result cached'
    end
    if not controls[key] then return true end
    if category and target.get_dr then
        local dr=target:get_dr(category)
        if type(dr)=='number' and dr<=0 then return false,'CC diminishing immunity' end
    end
    local mask=flags[key] and target.CC and target.CC[flags[key]]
    if mask then
        if target.is_cc_immune and target:is_cc_immune(mask,100) then return false,'CC immunity' end
        if target.is_cc and target:is_cc(250,mask) then return false,'Control already active' end
    end
    local attempt=state.attempts[key]
    if attempt then
        if now<attempt.at or now-attempt.start>=30000 then state.attempts[key]=nil
        elseif now<attempt.until_ms or attempt.count>=2 then return false,'Control retry backoff' end
    end
    return true
end
function M.attempt(target,spell,key,accepted)
    if not controls[key] then return end
    local guid=safety.guid(target);if not guid then return end
    local now=core.game_time();local state=row(guid,now)
    local old=state.attempts[key]
    if not old or now<old.at or now-old.start>=30000 then old={start=now,count=0} end
    old.count=old.count+1;old.at=now
    old.until_ms=now+(accepted and math.max(0,spell:cast_time_ms())+1500 or 1000)
    state.attempts[key]=old
end
function M.on_event(event,args)
    if event=='PLAYER_REGEN_ENABLED' or event=='PLAYER_ENTERING_WORLD' then targets={};return end
    if event~='COMBAT_LOG_EVENT_UNFILTERED' or type(args)~='table' or args[4]~=owner then return end
    -- Installed core supplies flattened CombatLogGetCurrentEventInfo:
    -- source GUID [4], destination GUID [8], spell ID [12], miss type [15].
    local sub,guid,key=args[2],args[8],registered[args[12]]
    if not key or type(guid)~='string' or guid=='' then return end
    local now=core.game_time();local state=row(guid,now)
    if sub=='SPELL_MISSED' and args[15]=='IMMUNE' then
        state.blocked[args[12]]=now+30000
        local category=categories[key]
        if category then state.blocked['cc:'..category]=now+30000 end
    elseif sub=='SPELL_AURA_APPLIED' or sub=='SPELL_AURA_REFRESH' or sub=='SPELL_DAMAGE' then
        -- Success disproves immunity, but does not remove the CC retry budget.
        state.blocked[args[12]]=nil
        local category=categories[key]
        if category then state.blocked['cc:'..category]=nil end
    end
end
core.register_on_game_event_callback(safety.callback(M.on_event,'Warlock spell outcome guard'))
return M
