local cast_guard=require("rotations/warlock/era/cast_guard")
-- Forever Affliction leveling. All native calls are from the installed SDK.
local safety=require('shared/object_safety')
local performance=require('shared/rotation_performance')
local izi=require('common/izi_sdk')
local plugin=require('common/utility/plugin_helper')
local shard_item=izi.item(6265)
local ids=require('rotations/warlock/era/forever_affliction_ids')
local spells={}
for key,list in pairs(ids) do spells[key]=izi.spell(list) end
local M={status={action='Waiting',reason='No decision yet'}}
M.REVISION='WL-P4'
core.log('[AstroForever][Warlock] '..M.REVISION..' loaded: independent DoT planning')
local samples,requests={},{}
local debuff_snapshots={}
local applications={}
local drain_request=nil
local last_dot_guid=nil
local spell_start_request=nil
local funnel={}
local last_dot_cleanup=-math.huge
local last_cleanup,last_pet_command,last_cancel=0,-math.huge,-math.huge
local lead_guid,lead_at=nil,0
local wanding=false
local cast_check_opts={cache_time_override=0.05}
local clip_check_opts={cache_time_override=0.05,skip_casting=true,skip_channeling=true}
local self_clip_check_opts={skip_casting=true,skip_channeling=true}
-- Resource metadata is cached; logical DoT need is independent of GCD readiness.
local channels={wrack=true,drain_life=true,drain_soul=true,hellfire=true,health_funnel=true}
local cost_cache={}
function M.clear_queued_wand()
    require('common/modules/spell_queue'):purge_by_spell(5019)
end
function M.await_spell_start(player)
    local request=spell_start_request
    if not request then return false end
    local now=core.game_time()
    if request.owner~=safety.guid(player) or now<request.at or now-request.at>=1500
        or player:get_active_spell_id()==request.id or player:get_active_channel_spell_id()==request.id then
        spell_start_request=nil;return false
    end
    return true
end
function M.note_cast_request(player,target,spell,key)
    if spell_start_request and spell_start_request.id~=spell:id() then
        -- A higher-priority accepted action replaces any older queued cast.
        require('common/modules/spell_queue'):purge_by_spell(spell_start_request.id)
    end
    if channels[key] or spell:cast_time_ms()>0 then
        spell_start_request={id=spell:id(),owner=safety.guid(player),at=core.game_time(),is_channel=channels[key]==true}
    else spell_start_request=nil end
end
local visible,visible_at={},-math.huge
local last_chain=-math.huge
local function enabled(menu,key,default)
    local e=menu[key];if not e then return default end
    return e:get_state()==true
end
local function number(menu,key,default)
    local e=menu[key];local v=e and e:get() or default
    if type(v)~='number' or v~=v then return default end
    return v
end
local function finite(v) return type(v)=='number' and v==v and v>0 and v<math.huge end
local function hp(u) return u:get_health_percentage() end
local function mana(u) return u:mana_pct() end
local function known(key) return spells[key] and spells[key]:is_learned() end
local function reason(text) M.status.reason=text end
local function shard_count() return shard_item:count() or 0 end
local function protected(u)
    return not safety.valid(u) or not u:is_alive() or not u:is_valid_enemy()
        or (u.is_cc_weak and u:is_cc_weak())
end
function M.hold_drain_soul(player)
    if not safety.valid(player) then return false end
    local now=core.game_time()
    local channel=player:get_active_channel_spell_id() or 0
    for _,id in ipairs(ids.drain_soul) do
        if channel==id then
            drain_request=nil
            M.status.action='Drain Soul';M.status.drain_soul='Channeling until target dies'
            reason('Holding Drain Soul: no scripted interruptions');return true
        end
    end
    if drain_request then
        local target=player:get_target()
        local dead=safety.guid(target)==drain_request.guid and not target:is_alive()
        if not dead and now>=drain_request.at and now<drain_request.until_ms then
            M.status.action='Drain Soul';M.status.drain_soul='Waiting for channel to start'
            reason('Holding accepted Drain Soul request');return true
        end
        drain_request=nil
    end
    return false
end
local function funnel_channel(player)
    local channel=player:get_active_channel_spell_id() or 0
    for _,id in ipairs(ids.health_funnel) do if channel==id then return true end end
    return false
end
local function funnel_owner(player)
    local guid=safety.guid(player);local now=core.game_time()
    if funnel.owner~=guid or (funnel.at and now<funnel.at) then funnel={owner=guid} end
    return now
end
function M.pet_heal_allowed(player,pet,menu)
    local now=funnel_owner(player)
    if not enabled(menu,'use_health_funnel',true) or not safety.valid(pet) or not pet:is_alive()
        or player:is_moving() or hp(player)<=30 then return false end
    if funnel_channel(player) or now<(funnel.damage_until or 0) then return false end
    return not funnel.pending
end
function M.record_pet_heal(player,pet)
    local now=funnel_owner(player)
    funnel.at=now;funnel.pending=true;funnel.pet=safety.guid(pet);funnel.started_at=nil
end
function M.handle_pet_heal(player,menu)
    local now=funnel_owner(player)
    if not funnel.pet then return false end -- Leave manually started Funnel alone.
    local pet=player:get_pet()
    local valid_pet=safety.guid(pet)==funnel.pet and pet:is_alive()
    if funnel_channel(player) then
        funnel.pending=false;funnel.started_at=funnel.started_at or now
        local duration=math.max(1000,number(menu,'health_funnel_max_ms',3000))
        if not valid_pet or not enabled(menu,'use_health_funnel',true) or hp(player)<=30
            or hp(pet)>=number(menu,'health_funnel_pet_hp_pct',40) or now-funnel.started_at>=duration then
            core.input.cancel_spells()
            funnel.damage_until=now+math.max(1000,number(menu,'health_funnel_damage_window_ms',6000))
            funnel.pet=nil;funnel.pending=false;funnel.started_at=nil
            reason('Ending Health Funnel for damage window');return true
        end
        M.status.action='Health Funnel';reason('Brief pet recovery; damage window follows');return true
    end
    if funnel.started_at then
        funnel.damage_until=now+math.max(1000,number(menu,'health_funnel_damage_window_ms',6000))
        funnel.started_at=nil;funnel.pet=nil;funnel.pending=false
    elseif funnel.pending and valid_pet and now-funnel.at<1500 then
        M.status.action='Health Funnel';reason('Waiting for pet-heal channel');return true
    else
        funnel.damage_until=now+1000;funnel.pending=false;funnel.pet=nil
    end
    return false
end
function M.ttd(unit)
    local guid=safety.guid(unit);if not guid then return nil end
    local now=core.time();local health=unit:get_health()
    if not finite(health) then samples[guid]=nil;requests[guid]=nil;return nil end
    local s=samples[guid]
    if not s or now<s.at or now-s.at>2 or health>s.hp then
        s={at=now,start=now,hp=health,initial=health};samples[guid]=s
    elseif now-s.at>=0.1 then
        s.at=now;s.hp=health
        local elapsed=now-s.start;local damage=s.initial-health
        s.value=elapsed>=0.75 and damage>0 and health*elapsed/damage or nil
        if elapsed>=4 then s.start=now;s.initial=health end
    end
    if now<last_cleanup or now-last_cleanup>=5 then
        for key,value in pairs(samples) do if now-value.at>10 or now<value.at then samples[key]=nil;requests[key]=nil;debuff_snapshots[key]=nil;applications[key]=nil end end
        last_cleanup=now
    end
    local ok,value=pcall(function()
        if unit.has_time_to_die_data and not unit:has_time_to_die_data() then return nil end
        return unit:time_to_die()
    end)
    if ok and finite(value) and value~=1.1 and math.abs(value-61.22)>0.001 then return value end
    return s.value
end
local function own_remains(player,target,key,spell_ids)
    local list=spell_ids or ids[key];if not list then return 0 end
    local guid=safety.guid(target);local owner=safety.guid(player)
    if not guid or not owner then return 0 end
    local now=core.game_time();local snapshot=debuff_snapshots[guid]
    if not snapshot or snapshot.owner~=owner or now<snapshot.at or now-snapshot.at>=100 then
        snapshot={at=now,owner=owner,expires={}};debuff_snapshots[guid]=snapshot
        -- Native aura tables expose expire_time, not the manager's derived remaining.
        -- Use pairs: aura slots need not form a dense, one-based array.
        for _,aura in pairs(target:get_debuffs() or {}) do
            if safety.same(aura.caster,player) then
                local expires=tonumber(aura.expire_time)
                if expires and expires>now then
                    snapshot.expires[aura.buff_id]=math.max(snapshot.expires[aura.buff_id] or 0,expires)
                end
            end
        end
    end
    local remains=0
    for _,id in ipairs(list) do
        remains=math.max(remains,(snapshot.expires[id] or 0)-now)
    end
    return remains
end
-- Accepted queue requests precede the real cast and the server aura update.
-- Keep this separate from DoT duration: a miss/resist must become retryable.
function M.record_dot(target,key,spell)
    local guid=safety.guid(target);if not guid then return end
    local now=core.game_time()
    applications[guid]=applications[guid] or {}
    applications[guid][key]={id=spell:id(),at=now,
        until_ms=now+math.max(0,spell:cast_time_ms())+2000}
end
function M.observe_cast(player)
    local now=core.game_time()
    if now<last_dot_cleanup or now-last_dot_cleanup>=5000 then
        for guid,snapshot in pairs(debuff_snapshots) do
            if now<snapshot.at or now-snapshot.at>10000 then debuff_snapshots[guid]=nil end
        end
        for guid,pending in pairs(applications) do
            for key,entry in pairs(pending) do
                if now<entry.at or now>=entry.until_ms then pending[key]=nil end
            end
            if next(pending)==nil then applications[guid]=nil end
        end
        last_dot_cleanup=now
    end
    local id=player:get_active_spell_id()
    if not id or id==0 then return end
    local guid=safety.guid(player:get_active_spell_target())
    local pending=guid and applications[guid]
    if not pending then return end
    for _,entry in pairs(pending) do
        if entry.id==id and now>=entry.at then
            entry.until_ms=math.max(entry.until_ms,now+1500)
        end
    end
end
function M.dot_ready(player,target,key,spell,window)
    local guid=safety.guid(target);if not guid then return false end
    local pending=applications[guid] and applications[guid][key]
    local now=core.game_time()
    if pending and now>=pending.at and now<pending.until_ms then return false end
    return own_remains(player,target,key,spell.ids or ids[key] or {spell:id()})<=(window or 0)
end
function M.own_dot_remains(player,target,spell_ids)
    return own_remains(player,target,'',spell_ids)
end
local function castable(player,target,key,clip)
    local spell=spells[key]
    if not spell or not spell:is_learned() or not safety.valid(target) then return false end
    if player:is_moving() and (channels[key] or spell:cast_time()>0) then return false end
    local opts=(clip or wanding) and clip_check_opts or cast_check_opts
    if safety.same(player,target) then return spell:is_castable((clip or wanding) and self_clip_check_opts or nil) end
    return spell:is_castable_to_unit(target,opts)
end
local function mana_for_spell(player,spell)
    local id=spell:id();local now=core.game_time();local cached=cost_cache[id]
    if not cached or now<cached.at or now-cached.at>=200 then
        cached={at=now,rows=core.spell_book.get_spell_costs(id) or {}};cost_cache[id]=cached
    end
    local lowest=nil
    for _,row in pairs(cached.rows) do
        if row.cost_type==0 and (not row.required_buff_id or row.required_buff_id==0 or player:buff_up({row.required_buff_id}))
            and (tonumber(row.cost_percent) or 0)==0 and type(row.cost)=='number' then
            lowest=lowest and math.min(lowest,row.cost) or row.cost
        end
    end
    if lowest then return player:mana_current()>=lowest end
    return player:mana_current()>0 -- No cost record is not proof that setup is complete.
end
local function explicit_unavailable(why)
    if type(why)~='string' then return false end
    why=why:lower()
    for _,part in ipairs({'immune','range','line_of_sight','line of sight','facing','moving','mana','resource'}) do
        if why:find(part,1,true) then return true end
    end
    return false
end
-- Logical need is independent of is_castable, GCD state, queue acceptance and
-- cached SDK booleans. Both the Forever and legacy PvE filler gates use this.
local function dot_verdict(guid,key,needed,why)
    local checks=M.status.dot_checks
    if checks then checks[key.."@"..tostring(guid)]=why end
    M.status.dot_plan=key..": "..why
    return needed,why
end
function M.dot_requirement(player,target,menu,key,spell,window,minimum)
    local guid=safety.guid(target)
    if protected(target) or not spell:is_learned() then return dot_verdict(guid,key,false,"Unavailable target/spell") end
    local pending=applications[guid] and applications[guid][key]
    local remaining=own_remains(player,target,key,spell.ids or ids[key] or {spell:id()})
    if remaining>(window or 0) then return dot_verdict(guid,key,false,"DoT active") end
    if not cast_guard.allow(player,target,spell,key) then return dot_verdict(guid,key,false,"Immunity/retry guard") end
    local now=core.game_time()
    if pending and now>=pending.at and now<pending.until_ms then return dot_verdict(guid,key,true,"Awaiting DoT confirmation") end
    local ttd=M.ttd(target)
    if ttd and ttd<(minimum or 8) then return dot_verdict(guid,key,false,string.format("TTD %.1f < minimum %.1f",ttd,minimum or 8)) end
    if not ttd and not (enabled(menu,'aff_unknown_ttd_dots',true) and hp(target)>20) then return dot_verdict(guid,key,false,"Unknown TTD policy") end
    if player:is_moving() and spell:cast_time_ms()>0 then return dot_verdict(guid,key,false,"Moving: cast-time DoT") end
    if type(spell.maximum_range)=='number' and spell.maximum_range>0 and target:distance()>spell.maximum_range then return dot_verdict(guid,key,false,"Out of DoT range") end
    if not mana_for_spell(player,spell) then return dot_verdict(guid,key,false,"Insufficient DoT mana") end
    local ok,why=spell:is_castable_to_unit(target,clip_check_opts)
    if not ok and explicit_unavailable(why) then return dot_verdict(guid,key,false,tostring(why)) end
    return dot_verdict(guid,key,true,ok and "DoT ready" or tostring(why or "Waiting for SDK readiness"))
end

local function cast(player,target,key)
    if not castable(player,target,key,false) then return false end
    if not cast_guard.allow(player,target,spells[key],key) then return false end
    M.clear_queued_wand()
    if wanding then
        local auto=require('common/utility/auto_attack_helper')
        auto:stop_attack(target,auto.ATTACK_TYPE.WAND)
        core.input.cancel_spells();reason('Ending wand for '..key);return true
    end
    local guid=safety.guid(target);local now=core.game_time()
    if not guid then return false end
    local last=requests[guid] and requests[guid][key]
    if last and now>=last and now-last<750 then return false end
    if spells[key]:cast(target)==true then
        M.note_cast_request(player,target,spells[key],key)
        requests[guid]=requests[guid] or {};requests[guid][key]=now
        if key=='drain_soul' then drain_request={guid=guid,at=now,until_ms=now+1500} end
        if key=='bane_of_agony' or key=='corruption' or key=='siphon_life' or key=='curse_of_elements' or key=='immolate' then
            M.record_dot(target,key,spells[key])
            last_dot_guid=guid
        end
        M.status.action=key:gsub('_',' '):gsub('^%l',string.upper);reason('Cast accepted by SDK')
        return true
    end
    return false
end
local function next_dot(player,target,menu,clip,plan_only)
    local sequence={{'use_curse_of_agony','bane_of_agony'},{'use_corruption','corruption'},
        {'use_siphon_life','siphon_life'},{'aff_use_elements','curse_of_elements'},{'use_immolate','immolate'}}
    for _,entry in ipairs(sequence) do
        local key=entry[2]
        if enabled(menu,entry[1],key~='immolate') and known(key) then
            local remaining=own_remains(player,target,key)
            local window=key=='bane_of_agony' and 0 or number(menu,'aff_refresh_window_ms',0)
            local previous=requests[safety.guid(target)]
            local sent=previous and previous[key]
            local minimum=number(menu,(remaining>0 or sent~=nil) and 'aff_refresh_min_ttd' or 'dot_min_ttd_sec',(remaining>0 or sent~=nil) and 6 or 8)
            local needed,why=M.dot_requirement(player,target,menu,key,spells[key],window,minimum)
            if needed then
                M.status.dot_plan=key..': '..why
                if plan_only then return key,target end
                if M.dot_ready(player,target,key,spells[key],window) then
                if key=='bane_of_agony' and enabled(menu,'aff_use_amplify',true) and known('amplify_curse')
                    and not player:buff_up(ids.amplify_curse) and castable(player,player,'amplify_curse',clip) then
                    return 'amplify_curse',player
                end
                if castable(player,target,key,clip) then return key,target end
                end
            else
                M.status.dot_plan=key..': '..why
            end
        else
            dot_verdict(safety.guid(target),key,false,
                not enabled(menu,entry[1],key~='immolate') and 'Disabled by setting' or ('Not learned (SDK id='..tostring(spells[key]:id())..')'))
        end
    end
end
local function engaged(player,pet,u,current,allies)
    if protected(u) then return false end
    if safety.same(u,current) then return true end
    local victim=u:get_target();local vg=safety.guid(victim)
    if safety.same(victim,player) or (pet and victim and safety.same(victim,pet)) or (vg and allies[vg]) then return true end
    local info=player:get_threat_situation(u)
    return info and ((tonumber(info.threat_percent) or 0)>0 or info.is_tanking==true)
end
local function enemies(player,pet,current)
    local allies={}
    for _,member in safety.live_ipairs(performance:get_unit_list(player,'get_party_members_in_range',40,true) or {}) do
        local guid=safety.guid(member);if guid then allies[guid]=true end
    end
    local list={};local seen={}
    if current and not protected(current) then list[1]=current;seen[safety.guid(current)]=true end
    local others={}
    for _,u in safety.live_ipairs(performance:get_unit_list(player,'get_enemies_in_range',30,false) or {}) do
        local guid=safety.guid(u)
        if guid and not seen[guid] and engaged(player,pet,u,current,allies) then
            others[#others+1]={unit=u,guid=guid}
            seen[guid]=true
        end
    end
    -- Stable primitive ordering prevents object-list order from rotating the
    -- target cap across different mobs every frame. Victim does not set priority.
    table.sort(others,function(a,b)
        return a.guid<b.guid
    end)
    for _,entry in ipairs(others) do list[#list+1]=entry.unit end
    return list
end
function M.engaged_targets(player,pet,target)
    return enemies(player,pet,target)
end
local function multi_dot_enabled(menu)
    return enabled(menu,'multi_dot_enabled',false)
        or (menu.aoe_dot_toggle and plugin:is_toggle_enabled(menu.aoe_dot_toggle)==true)
end
local function next_pack_dot(player,pet,target,menu,clip,plan_only)
    if not multi_dot_enabled(menu) then return next_dot(player,target,menu,clip,plan_only) end
    local pack=enemies(player,pet,target)
    local limit=math.max(1,math.min(5,number(menu,'multi_dot_limit',3)))
    local count=math.min(limit,#pack)
    local start=1
    for i=1,count do if safety.guid(pack[i])==last_dot_guid then start=i%count+1;break end end
    for offset=0,count-1 do
        local index=(start+offset-1)%count+1
        local key,unit=next_dot(player,pack[index],menu,clip,plan_only)
        if key then return key,unit,pack end
    end
    return nil,nil,pack
end
local function awaiting_dot(player,target,menu,candidates)
    local pack=candidates or {target}
    local limit=candidates and math.max(1,math.min(5,number(menu,'multi_dot_limit',3))) or 1
    local now=core.game_time()
    for i=1,math.min(limit,#pack) do
        local u=pack[i];local pending=applications[safety.guid(u)]
        if pending and not protected(u) then
            for key,entry in pairs(pending) do
                if ids[key] and now>=entry.at and now<entry.until_ms and own_remains(player,u,key)<=0
                    and cast_guard.allow(player,u,spells[key],key) then
                    return true
                end
            end
        end
    end
    return false
end
local function lead_pet(player,target,pet,menu)
    if not safety.valid(pet) or not pet:is_alive() then return false end
    local now=core.game_time();local guid=safety.guid(target)
    if guid~=lead_guid or now<lead_at then lead_guid=guid;lead_at=now end
    local victim=pet:get_target()
    if (not safety.same(victim,target) or not pet:is_auto_attacking()) and (now<last_pet_command or now-last_pet_command>=500) then
        core.input.pet_attack(target);last_pet_command=now
    end
    if not enabled(menu,'aff_pet_lead',true) then return false end
    local info=pet:get_threat_situation(target)
    if info and info.is_tanking==true then return false end
    if now-lead_at<number(menu,'aff_pet_lead_ms',750) then reason('Letting demon establish threat');return true end
    return false
end
local function chain_pull(player,target,pet,menu,current_pack)
    if not enabled(menu,'aff_chain_pull',false) or not safety.valid(pet) or not pet:is_alive() then return false end
    if hp(target)>number(menu,'aff_chain_start_hp',40) or hp(player)<number(menu,'aff_chain_min_hp',75)
        or mana(player)<number(menu,'aff_chain_min_mana',60)
        or #current_pack>=number(menu,'aff_chain_max_enemies',2) then return false end
    local now=core.game_time()
    if now>=last_chain and now-last_chain<number(menu,'aff_chain_interval_ms',4000) then return false end
    if now<visible_at or now-visible_at>=250 then visible=core.object_manager.get_visible_objects() or {};visible_at=now end
    local best,distance=nil,math.huge
    for _,u in safety.live_ipairs(visible) do
        if u:is_unit() and not u:is_player() and not u:is_in_combat() and not protected(u)
            and u:get_classification()==0 and u:get_level()>0 and u:get_level()<=player:get_level()+2
            and not safety.same(u,target) and u:distance()<=number(menu,'aff_chain_range',25) then
            local starter=known('bane_of_agony') and 'bane_of_agony' or 'curse_of_elements'
            if u:distance()<distance and castable(player,u,starter) then best,distance=u,u:distance() end
        end
    end
    if best and core.input.set_target(best)==true then
        last_chain=now;core.input.pet_attack(best);last_pet_command=now
        M.status.action='Chain pull';reason('Demon sent to next target');return true
    end
    return false
end
function M.observe(player,menu,active)
    local now=core.game_time()
    if M.status.observed and now>=M.status.observed and now-M.status.observed<200 then return end
    M.status.observed=now;M.status.hp=hp(player);M.status.mana=mana(player);M.status.shards=shard_count()
    M.status.shard_min=number(menu,'min_soul_shards',3)
    M.status.shard_max=math.max(M.status.shard_min,number(menu,'max_soul_shards',10))
    local target=player:get_target();M.status.target=safety.valid(target) and target:get_name() or 'None'
    M.status.ttd=safety.valid(target) and target:is_valid_enemy() and M.ttd(target) or nil
    local pet=player:get_pet();M.status.pet=safety.valid(pet) and pet:is_alive() and string.format('%s %.0f%%',pet:get_name(),hp(pet)) or 'No living demon'
    M.status.wrack=known('wrack');M.status.shadowburn_cd=known('shadowburn') and spells.shadowburn:cooldown_remains() or nil
    if not active then M.status.action='Disabled';reason('Enable rotation to resume')
    elseif enabled(menu,'pvp_mode',false) or (menu.pvp_mode_toggle and plugin:is_toggle_enabled(menu.pvp_mode_toggle)) then
        M.status.action='PvP';reason('Using PvP priority')
    elseif not enabled(menu,'affliction_enabled',true) or number(menu,'rotation_mode',1)>2 then
        M.status.action='Standard rotation';reason('Forever Affliction priority is not selected')
    elseif not player:is_in_combat() then M.status.action='Out of combat';reason('Preparing pet and buffs') end
end
local filler_notices={}
local function trace_filler(player,target,kind)
    local guid=safety.guid(target);local now=core.game_time();local previous=filler_notices[kind]
    if previous and previous.guid==guid and now>=previous.at and now-previous.at<20000 then return end
    filler_notices[kind]={guid=guid,at=now}
    core.log('['..M.REVISION..'] filler='..kind..' route='..tostring(M.status.route or 'Unknown')
        ..' target='..target:get_name()..' mana='..string.format('%.0f%%',mana(player))
        ..' decision='..tostring(M.status.dot_plan or 'No required DoT')
        ..' checks='..(function() local entries={};for key,why in pairs(M.status.dot_checks or {}) do entries[#entries+1]=key..'='..why end;table.sort(entries);return table.concat(entries,'; ') end)())
end
M.trace_filler=trace_filler
function M.execute(player,target,menu,ctx)
    M.status.dot_checks={}
    if not safety.valid(player) or not player:is_alive() then return false end
    M.status.route='Forever Affliction'
    if M.hold_drain_soul(player) then return true end
    if M.handle_pet_heal(player,menu) then return true end
    if player:is_mounted() or not player:is_in_combat() then return false end
    local cache_ms=math.max(0,math.min(150,number(menu,'aff_cast_check_cache_ms',50)))
    cast_check_opts.cache_time_override=cache_ms/1000
    clip_check_opts.cache_time_override=cache_ms/1000
    M.observe_cast(player)
    local pet=player:get_pet()
    wanding=ctx.is_wanding(player)
    local active_cast=player:get_active_spell_id() or 0
    if active_cast>0 then
        local auto=require('common/utility/auto_attack_helper')
        if not auto:is_spell_auto_attack(active_cast) then wanding=false end
    end
    if protected(target) then
        local selection=player:get_target()
        if safety.valid(selection) and selection:is_alive() and not selection:is_valid_enemy() then
            reason('Keeping friendly selection');return false
        end
        if not enabled(menu,'aff_next_target',true) then reason('No valid hostile selection');return false end
        target=nil
        for _,u in ipairs(enemies(player,pet,nil)) do
            if core.input.set_target(u)==true then target=u;break end
        end
        if not target then reason('No engaged target');return false end
    end
    M.ttd(target)
    if ctx.emergency(player,target,menu) then
        M.status.action='Emergency';M.status.drain_soul='Waiting for emergency action'
        reason('Survival priority');return true
    end
    local health,mp,shards=hp(player),mana(player),shard_count()
    local shard_min=number(menu,'min_soul_shards',3)
    M.status.shards=shards;M.status.shard_min=shard_min
    local urgent_heal=enabled(menu,'use_drain_life',true) and known('drain_life') and health<=number(menu,'drain_life_hp_pct',45)
    local urgent_tap=enabled(menu,'use_life_tap',true) and known('life_tap') and mp<=number(menu,'aff_urgent_mana_pct',10)
        and health>number(menu,'life_tap_min_hp_pct',60)
    local needs_shards=shards<shard_min
    local harvest_finish=enabled(menu,'aff_finish_drain_soul',false) and known('soul_harvest')
    local finish_reason=needs_shards or harvest_finish
    local execute_hp=number(menu,'drain_soul_execute_hp_pct',20)
    local ttd=M.ttd(target)
    local finish_range=hp(target)<=execute_hp or (finish_reason and ttd and ttd<=5)
    local finishing=enabled(menu,'use_drain_soul',true) and known('drain_soul') and finish_range and finish_reason
    local drain_usable=false
    if not enabled(menu,'use_drain_soul',true) then M.status.drain_soul='Disabled in settings'
    elseif not known('drain_soul') then M.status.drain_soul='Not learned'
    elseif not finish_reason then M.status.drain_soul='Shard minimum satisfied'
    elseif not finish_range then M.status.drain_soul=string.format('Waiting: target %.0f%%, finish %.0f%%',hp(target),execute_hp)
    else
        local usable,why=castable(player,target,'drain_soul',true)
        drain_usable=usable
        M.status.drain_soul=usable and 'Ready to finish' or ('Blocked: '..(player:is_moving() and 'moving' or tostring(why or 'SDK castability check')))
    end
    local pack_key,pack_unit,candidates=next_pack_dot(player,pet,target,menu,true)
    local spreading=candidates and #candidates>1
    local dot_pending=awaiting_dot(player,target,menu,candidates)
    local waiting_key,waiting_unit=next_pack_dot(player,pet,target,menu,true,true)
    local setup_outstanding=dot_pending or waiting_key~=nil
    if setup_outstanding then M.clear_queued_wand() end
    local channel=player:get_active_channel_spell_id() or 0
    if known('hellfire') and channel==spells.hellfire:id()
        and (health<number(menu,'aff_hellfire_min_hp',75) or mp<number(menu,'aff_hellfire_min_mana',30)) then
        local now=core.game_time()
        if now<last_cancel or now-last_cancel>=350 then core.input.cancel_spells();last_cancel=now;reason('Hellfire health/mana floor');return true end
    end
    local healing_channel=known('drain_life') and channel==spells.drain_life:id()
    local clip_key,clip_target
    if finishing and channel~=spells.drain_soul:id() then clip_key,clip_target='drain_soul',target
    elseif spreading and pack_key and enabled(menu,'aff_clip_dots',true) then clip_key,clip_target=pack_key,pack_unit
    elseif urgent_heal and not healing_channel then clip_key,clip_target='drain_life',target
    elseif urgent_tap then clip_key,clip_target='life_tap',player
    elseif pack_key and enabled(menu,'aff_clip_dots',true) then clip_key,clip_target=pack_key,pack_unit
    elseif not setup_outstanding and enabled(menu,'aff_use_nightfall',true) and enabled(menu,'use_shadow_bolt',true)
        and known('shadow_bolt') and player:buff_up({17941})
        and not (finishing and channel==spells.drain_soul:id()) then clip_key,clip_target='shadow_bolt',target end
    if (player:is_channeling_or_casting() or active_cast>0 or channel>0) and not wanding then
        local ours=false;for key in pairs(channels) do if known(key) and channel==spells[key]:id() then ours=true end end
        local finish_bolt=finishing and clip_key=='drain_soul' and known('shadow_bolt')
            and player:get_active_spell_id()==spells.shadow_bolt:id()
        local spread_bolt=spreading and pack_key and enabled(menu,'aff_clip_dots',true) and known('shadow_bolt')
            and player:get_active_spell_id()==spells.shadow_bolt:id()
        if (ours or finish_bolt or spread_bolt) and enabled(menu,'aff_clip_channels',true) and clip_key and castable(player,clip_target,clip_key,true) then
            local now=core.game_time()
            if now<last_cancel or now-last_cancel>=350 then core.input.cancel_spells();last_cancel=now;reason('Ending channel for '..clip_key);return true end
        end
        reason('Protecting current cast/channel');return true
    end
    if finishing and cast(player,target,'drain_soul') then
        reason(string.format('Finishing: shards %d / minimum %d',shards,shard_min));return true
    end
    if finishing and drain_usable then M.status.drain_soul='SDK did not accept cast request' end
    if spreading and pack_key and cast(player,pack_unit,pack_key) then
        reason('Pack DoT priority');return true
    end
    if urgent_heal and cast(player,target,'drain_life') then return true end
    if urgent_tap and cast(player,player,'life_tap') then return true end
    if lead_pet(player,target,pet,menu) then return true end
    if ctx.pet_utility(player,target,menu) then M.status.action='Pet utility';reason('Pet management accepted an action');return true end
    local key,unit=pack_key,pack_unit
    if key and cast(player,unit,key) then return true end
    if dot_pending then reason('Waiting for DoT confirmation');return true end
    if waiting_key then
        if wanding then
            local auto=require('common/utility/auto_attack_helper')
            auto:stop_attack(waiting_unit,auto.ATTACK_TYPE.WAND)
            core.input.cancel_spells()
        end
        reason('DoT setup: '..tostring(M.status.dot_plan or waiting_key));return true
    end
    if M.await_spell_start(player) then reason('Waiting for accepted cast/channel to start');return true end
    if enabled(menu,'aff_use_nightfall',true) and enabled(menu,'use_shadow_bolt',true) and player:buff_up({17941})
        and cast(player,target,'shadow_bolt') then return true end
    if enabled(menu,'aff_use_shadowburn',true) and shards>shard_min
        and cast(player,target,'shadowburn') then return true end
    if not candidates and (enabled(menu,'aff_use_hellfire',false) or enabled(menu,'aff_chain_pull',false)) then
        candidates=enemies(player,pet,target)
    end
    if candidates and chain_pull(player,target,pet,menu,candidates) then return true end
    if candidates and enabled(menu,'aff_use_hellfire',false) and health>=number(menu,'aff_hellfire_min_hp',75)
        and mp>=number(menu,'aff_hellfire_min_mana',30) then
        local near=0;for _,u in ipairs(candidates) do if u:distance()<=8 then near=near+1 end end
        if near>=number(menu,'aff_hellfire_min_enemies',3) and cast(player,player,'hellfire') then return true end
    end
    if enabled(menu,'use_life_tap',true) and mp<number(menu,'life_tap_mana_pct',40)
        and health>number(menu,'life_tap_min_hp_pct',60) and cast(player,player,'life_tap') then return true end
    if enabled(menu,'aff_use_wrack',true) and cast(player,target,'wrack') then trace_filler(player,target,'Wrack');return true end
    if not known('wrack') and enabled(menu,'use_drain_life',true) and player:get_level()>=number(menu,'aff_drain_filler_level',38)
        and cast(player,target,'drain_life') then return true end
    if enabled(menu,'use_wand',true) and ctx.wand(player,target,menu) then
        M.status.action='Wand';reason('Filler: '..tostring(M.status.dot_plan or 'No required DoT'))
        trace_filler(player,target,'Wand');return true
    end
    if enabled(menu,'use_shadow_bolt',true) and mp>number(menu,'shadow_bolt_min_mana_pct',35)
        and cast(player,target,'shadow_bolt') then return true end
    reason('No usable attack: check learned skills, mana, movement, range/facing')
    return false
end
core.register_on_game_event_callback(safety.callback(function(event,args)
    local request=spell_start_request
    if not request or type(args)~='table' or args[1]~='player' or args[3]~=request.id then return end
    if event=='UNIT_SPELLCAST_START' or event=='UNIT_SPELLCAST_CHANNEL_START'
        or (event=='UNIT_SPELLCAST_SUCCEEDED' and not request.is_channel)
        or event=='UNIT_SPELLCAST_FAILED' or event=='UNIT_SPELLCAST_FAILED_QUIET'
        or event=='UNIT_SPELLCAST_INTERRUPTED' or event=='UNIT_SPELLCAST_CHANNEL_STOP' then
        spell_start_request=nil
    end
end,'Warlock cast-start acknowledgement'))
return M
