local __object_safety=require("shared/object_safety")
-- Instant Poison catalog verified against local Forever DB2 item effects/enchantments.
local inventory=require("common/utility/inventory_helper")
local poisons={}
local ranks={
    {item=8928,enchant=625,level=60},{item=8927,enchant=624,level=52},
    {item=8926,enchant=623,level=44},{item=6950,enchant=325,level=36},
    {item=6949,enchant=324,level=28},{item=6947,enchant=323,level=20}
}
local instant={ [323]=true,[324]=true,[325]=true,[623]=true,[624]=true,[625]=true }
local next_check=0
local pending=nil
local blocked={}
local windows={MERCHANT_SHOW="merchant",MERCHANT_CLOSED="merchant",
    BANKFRAME_OPENED="bank",BANKFRAME_CLOSED="bank",MAIL_SHOW="mail",MAIL_CLOSED="mail",
    TRADE_SHOW="trade",TRADE_CLOSED="trade",LOOT_OPENED="loot",LOOT_CLOSED="loot"}
local function weapon(player,slot)
    local row=player:get_item_at_inventory_slot(slot)
    return row and row.object
end
local function cancel()
    if pending then core.input.stop_spell_target() end
    pending=nil;next_check=core.time()+5
end
core.register_on_game_event_callback(__object_safety.callback(function(event,args)
    local window=windows[event]
    if window then blocked[window]=not (event:find("CLOSED")~=nil) end
    if not pending then return end
    local age=core.time()-pending.at
    if age<0 or age>6 then return end
    local pending_player=__object_safety.resolve(pending.player_guid)
    if not pending_player then pending=nil;return end
    local item=weapon(pending_player,pending.slot)
    if not item or item:get_item_id()~=pending.weapon then cancel();return end
    if event=="REPLACE_ENCHANT" then core.input.replace_enchant()
    elseif event=="BIND_ENCHANT" then core.input.bind_enchant()
    elseif event=="UI_ERROR_MESSAGE" then cancel() end
end,"rotations/rogue/era/helpers/poisons.lua:24"))
function poisons.update(player,helpers)
    local now=core.time()
    if pending then
        if pending.player_guid~=__object_safety.guid(player) then pending=nil;next_check=now;return false end
        local item=weapon(player,pending.slot)
        if not item or item:get_item_id()~=pending.weapon then cancel();return false end
        if item:item_enchant_id()==pending.enchant and item:item_enchant_expiration()>30000
            and item:item_enchant_charges()>5 then
            pending=nil;next_check=now+0.5
        elseif now<pending.at or now-pending.at>6 then cancel()
        -- The main update already pauses while an actual cast is in progress.
        -- Waiting on a delayed/failed confirmation must not stall combat.
        else return now-pending.at<0.3 and player:get_health_percentage()>=40 end
    end
    if now<next_check then return false end
    next_check=now+0.5
    if player:level()<20 or player:is_dead() or player:is_moving() or player:is_mounted()
        or player:get_health_percentage()<40 or helpers:is_in_stealth(player)
        or helpers:is_vanish_attack_suppressed(player) or core.game_ui.has_cursor_item() then return false end
    for _,open in pairs(blocked) do if open then return false end end
    for _,slot in ipairs({16,17}) do
        local item=weapon(player,slot)
        if item then
            local info=core.quests.get_item_info(item:get_item_id())
            -- Weapon class only: skip shields, held objects and uncached item information.
            if info and info.class_id==2 and not (instant[item:item_enchant_id()]
                and item:item_enchant_expiration()>30000 and item:item_enchant_charges()>5) then
                local bags=inventory:get_character_bag_slots() or {}
                for _,rank in ipairs(ranks) do
                    if player:level()>=rank.level then
                        for _,bag in ipairs(bags) do
                            if bag.item and bag.item:get_item_id()==rank.item and bag.stack_count>0 then
                                pending={player_guid=__object_safety.guid(player),slot=slot,weapon=item:get_item_id(),enchant=rank.enchant,at=now}
                                if core.input.apply_container_item_to_inventory_slot(bag.bag_id,bag.bag_slot,slot) then return true end
                                pending=nil;next_check=now+5;return false
                            end
                        end
                    end
                end
                next_check=now+2 -- Missing supplies: don't scan bags every frame.
            end
        end
    end
    return false
end
return poisons
