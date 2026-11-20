-- Out-of-combat maintenance using the installed native inventory/SDK calls.
local safety=require('shared/object_safety')
local inventory=require('common/utility/inventory_helper')
local izi=require('common/izi_sdk')
local data=require('rotations/warlock/era/consumable_ids')
local M={status='Idle'}
local healthstone=izi.spell(data.create_healthstone)
local soulstone=izi.spell(data.create_soulstone)
local soulstone_item=izi.item(data.soulstone_items)
local hs_ids,ss_ids,ss_buffs={},{},{}
for _,id in ipairs(data.healthstone_items) do hs_ids[id]=true end
for _,id in ipairs(data.soulstone_items) do ss_ids[id]=true end
for _,id in ipairs(data.soulstone_buffs) do ss_buffs[id]=true end
local owner=nil
local last_poll=-math.huge
local pending=nil
local retry_at={}
local awaiting_delete=nil
local function enabled(menu,key,default)
    return menu[key] and menu[key]:get_state()==true or (not menu[key] and default)
end
local function number(menu,key,default)
    local value=menu[key] and menu[key]:get() or default
    if type(value)~='number' or value~=value or value==math.huge or value==-math.huge then return default end
    return math.max(0,math.floor(value))
end
local function scan()
    local result={shards=0,healthstones=0,soulstones=0,shard_slots={}}
    local seen={}
    for _,slot in pairs(inventory:get_character_bag_slots() or {}) do
        local item=slot.item
        if safety.valid(item) and type(slot.bag_id)=='number' and slot.bag_id>=0 and slot.bag_id<=4
            and slot.bag_id==math.floor(slot.bag_id) and type(slot.bag_slot)=='number' and slot.bag_slot>=1
            and slot.bag_slot==math.floor(slot.bag_slot) then
            local location=tostring(slot.bag_id)..':'..tostring(slot.bag_slot)
            if not seen[location] then
                seen[location]=true
                local id=item:get_item_id()
                local count=item:get_item_stack_count()
                if type(count)=='number' and count>0 and count<math.huge and count==math.floor(count) then
                    if id==6265 then
                        result.shards=result.shards+count
                        result.shard_slots[#result.shard_slots+1]={bag=slot.bag_id,slot=slot.bag_slot,count=count,guid=safety.guid(item)}
                    elseif hs_ids[id] then result.healthstones=result.healthstones+count
                    elseif ss_ids[id] then result.soulstones=result.soulstones+count end
                end
            end
        end
    end
    return result
end
local function soulstone_up(player)
    for _,aura in pairs(player:get_buffs() or {}) do if ss_buffs[aura.buff_id] then return true end end
    return false
end
local function create(player,spell,key,now)
    if now<(retry_at[key] or 0) or not spell:is_learned() or not spell:is_castable() then return false end
    local accepted,meta=spell:cast(player)
    if meta and meta.reason=='fast_queue_busy' then return false end
    retry_at[key]=now+5000
    if accepted==true then
        pending={kind=key,spell_id=spell:id(),until_ms=now+math.max(0,spell:cast_time_ms())+2500}
        M.status='Creating '..key;return true
    end
    return false
end
local function cleanup(player,menu,bags,now)
    if not enabled(menu,'auto_delete_excess_shards',false) then return false end
    local cap=math.max(number(menu,'min_soul_shards',3),number(menu,'max_soul_shards',10))
    if menu.max_soul_shards and menu.max_soul_shards:get()<cap then menu.max_soul_shards:set(cap) end
    if bags.shards<=cap then awaiting_delete=nil;return false end
    if awaiting_delete then
        if bags.shards<awaiting_delete.before then awaiting_delete=nil
        elseif now<awaiting_delete.until_ms then M.status='Waiting for shard bag update';return false
        else awaiting_delete=nil end
    end
    if core.game_ui.has_cursor_item() then M.status='Shard cleanup waits for empty cursor';return false end
    local excess=bags.shards-cap
    table.sort(bags.shard_slots,function(a,b) return a.count<b.count end)
    for _,candidate in ipairs(bags.shard_slots) do
        if candidate.guid and candidate.count<=excess then
            -- Re-read through the supported coordinate mapper immediately before
            -- destroying. Never use raw get_items_in_bag slot indices here.
            local live=scan()
            if live.shards-candidate.count<cap then return false end
            local found=false
            for _,slot in ipairs(live.shard_slots) do
                if slot.bag==candidate.bag and slot.slot==candidate.slot and slot.guid==candidate.guid and slot.count==candidate.count then found=true;break end
            end
            if found and not core.game_ui.has_cursor_item() and not player:is_in_combat() and not player:is_channeling_or_casting() then
                local deleted=core.input.destroy_container_item(candidate.bag,candidate.slot)
                if deleted==true then
                    awaiting_delete={before=live.shards,until_ms=now+3000}
                    M.status='Removed '..candidate.count..' excess Soul Shard(s)';return true
                end
                M.status='Shard deletion was not accepted';return false
            end
        end
    end
    M.status='Excess shards are in stacks larger than the removable excess'
    return false
end
function M.cancel_for_combat(player)
    if not pending or not pending.spell_id or not safety.valid(player) or owner~=safety.guid(player) or not player:is_in_combat() then return false end
    local id=pending.spell_id
    local removed=require('common/modules/spell_queue'):purge_by_spell(id)
    local active=player:get_active_spell_id()==id
    if active then core.input.cancel_spells() end
    pending=nil;M.status='Stone creation deferred until out of combat'
    return active or removed>0
end
function M.update(player,menu)
    if not safety.valid(player) or not player:is_alive() or player:is_in_combat() or player:is_moving() or player:is_mounted()
        or player:is_channeling_or_casting() or (player:get_active_spell_id() or 0)>0 or (player:get_active_channel_spell_id() or 0)>0 then return false end
    local now=core.game_time();local guid=safety.guid(player)
    if not guid then return false end
    if owner~=guid or now<last_poll then owner=guid;last_poll=-math.huge;pending=nil;retry_at={};awaiting_delete=nil end
    if now-last_poll<1000 then return pending~=nil end
    last_poll=now
    local bags=scan();local buffed=soulstone_up(player)
    if pending then
        local ready=(pending.kind=='Healthstone' and bags.healthstones>0)
            or (pending.kind=='Soulstone' and bags.soulstones>0) or (pending.kind=='Soulstone buff' and buffed)
        if ready or now>=pending.until_ms then pending=nil else M.status='Waiting for '..pending.kind;return true end
    end
    if enabled(menu,'auto_self_soulstone',true) and not buffed and bags.soulstones>0 and now>=(retry_at.apply or 0) then
        local used=soulstone_item:use_self_safe('Self Soulstone')
        retry_at.apply=now+3000
        if used==true then pending={kind='Soulstone buff',until_ms=now+2500};M.status='Applying Soulstone to self';return true end
    end
    if enabled(menu,'auto_create_healthstone',true) and bags.healthstones==0 and bags.shards>0
        and create(player,healthstone,'Healthstone',now) then return true end
    if enabled(menu,'auto_self_soulstone',true) and not buffed and bags.soulstones==0 and bags.shards>0
        and create(player,soulstone,'Soulstone',now) then return true end
    if cleanup(player,menu,bags,now) then return true end
    if bags.shards==0 and ((enabled(menu,'auto_create_healthstone',true) and bags.healthstones==0)
        or (enabled(menu,'auto_self_soulstone',true) and not buffed and bags.soulstones==0)) then
        M.status='Need a Soul Shard to create stones'
    end
    return false
end
return M
