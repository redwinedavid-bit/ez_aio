-- Independent SDK window: real native drawing/input and scripts_data profiles.
local safety=require('shared/object_safety')
local color=require('common/color')
local vec2=require('common/geometry/vector_2')
local enums=require('common/enums')
local plugin=require('common/utility/plugin_helper')
local affliction=require('rotations/warlock/era/forever_affliction')
local fields=require('rotations/warlock/era/affliction_profile_fields')
local M={};local names={'Leveling','Dungeon','PvP'}
local active=nil;local last_poll=-math.huge;local signature=nil;local drop=false
local window=nil
local function filename(index) return 'AstroForever_Warlock_'..names[index]..'.cfg' end
local function snapshot(menu)
    local parts={}
    for _,field in ipairs(fields) do
        local element=menu[field.key]
        if element then
            local value
            if field.kind=='bool' then value=element:get_state() else value=element:get() end
            parts[#parts+1]=field.key..'='..tostring(value)
        end
    end
    return table.concat(parts,'\n')
end
local function apply(menu,text)
    local allowed={};for _,field in ipairs(fields) do allowed[field.key]=field end
    for key,raw in text:gmatch('([%w_]+)=([^\r\n]+)') do
        local field=allowed[key];local element=menu[key]
        if field and element then
            if field.kind=='bool' and (raw=='true' or raw=='false') then element:set(raw=='true')
            elseif field.kind=='number' then
                local value=tonumber(raw)
                if value and value==value and value>-math.huge and value<math.huge then
                    value=math.max(field.min,math.min(field.max,value));element:set(math.floor(value))
                end
            end
        end
    end
    -- PvP hotkey and checkbox must agree when a profile is selected.
    menu.pvp_mode_toggle:set_toggle_state(menu.pvp_mode:get_state())
end
function M.save(menu)
    if not active then return end
    local text=snapshot(menu)
    if core.create_data_file(filename(active)) then core.write_data_file(filename(active),text);signature=text end
end
function M.select(menu,index)
    index=math.max(1,math.min(3,math.floor(index)))
    if active then M.save(menu) end
    active=index;menu.aff_profile:set(index)
    local text=core.read_data_file(filename(index))
    if text and text~='' then apply(menu,text)
    else
        menu.rotation_mode:set(index==2 and 2 or 1)
        menu.pvp_mode:set(index==3);menu.pvp_mode_toggle:set_toggle_state(index==3)
        menu.aff_pet_lead:set(index==1);menu.aff_use_hellfire:set(false);menu.aff_chain_pull:set(false)
        if index==1 then menu.preferred_pet:set(4) end
        M.save(menu)
    end
    signature=snapshot(menu)
end
function M.update(menu)
    local now=core.game_time()
    local selected=menu.aff_profile:get()
    if not active or selected~=active then M.select(menu,selected) end
    if now<last_poll or now-last_poll>=2000 then
        last_poll=now
        if snapshot(menu)~=signature then M.save(menu) end
    end
end
local WIDTH,HEIGHT=360,232
local reset_position=true
local last_position_x,last_position_y=nil,nil
local function value(menu,key,default)
    return menu[key] and menu[key]:get() or default
end
local function clickthrough(menu)
    return not menu.aff_status_clickthrough or menu.aff_status_clickthrough:get_state()
end
local function visible(menu,gui_open)
    return menu.aff_status_enabled:get_state() and (menu.aff_status_pinned:get_state() or gui_open)
end
local function position(menu)
    local screen=core.graphics.get_screen_size()
    local x=math.max(0,math.min(value(menu,'aff_status_x',30),math.max(0,(screen and screen.x or 1920)-WIDTH)))
    local y=math.max(0,math.min(value(menu,'aff_status_y',350),math.max(0,(screen and screen.y or 1080)-HEIGHT)))
    return x,y
end
local observe_status=safety.callback(function(menu)
    local player=core.object_manager.get_local_player()
    if safety.valid(player) then
        affliction.observe(player,menu,menu.enable_script_check:get_state() and plugin:is_toggle_enabled(menu.enable_toggle))
    end
end,'Warlock status observation')
function M.show_reset(menu)
    menu.aff_status_enabled:set(true);menu.aff_status_pinned:set(true)
    local screen=core.graphics.get_screen_size()
    -- Keep the recovered display away from the F1 settings window on the left.
    local x=math.max(0,(screen and screen.x or 1920)-WIDTH-24)
    if menu.aff_status_x then menu.aff_status_x:set(math.min(7680,x)) end
    if menu.aff_status_y then menu.aff_status_y:set(80) end
    reset_position=true;drop=false
end
local function paint(menu,rect,text,interactive)
    local opacity=math.max(0,math.min(100,value(menu,'aff_status_opacity',30)))
    local alpha=math.floor(opacity*255/100)
    local running=menu.enable_script_check:get_state() and plugin:is_toggle_enabled(menu.enable_toggle)
    local s=affliction.status
    rect(0,0,WIDTH,HEIGHT,color.new(16,19,29,alpha),9)
    rect(0,0,3,HEIGHT,color.new(167,123,242,200),2)
    local function chip(label,x,w,fill)
        rect(x,8,w,24,fill,5);text(label,x+7,13,12,color.white(240))
        if not interactive then return false end
        local a,b=vec2.new(x,8),vec2.new(x+w,32)
        window:is_mouse_hovering_rect_block_movement(a,b)
        return window:is_rect_clicked(a,b)
    end
    if chip(running and 'Enabled' or 'Paused',10,84,running and color.new(25,110,78,160) or color.new(115,51,61,160)) then
        menu.enable_script_check:set(not running);menu.enable_toggle:set_toggle_state(not running)
    end
    if chip((names[active or 1] or 'Leveling')..(interactive and '  v' or ''),102,140,color.new(91,64,135,140)) then drop=not drop end
    if interactive then
        if chip('Save',250,62,color.new(54,63,85,160)) then M.save(menu) end
        if chip('x',320,28,color.new(105,52,65,160)) then menu.aff_status_enabled:set(false) end
    else text(({['Forever Affliction']='FOREVER',['Legacy leveling']='LEGACY',['Legacy dungeon']='DUNGEON'})[s.route] or s.route or 'WAITING',255,16,11,color.new(201,180,240,235)) end
    local function bar(label,pct,x,r,g,b)
        pct=math.max(0,math.min(100,pct or 0))
        text(string.format('%s  %.0f%%',label,pct),x,43,11,color.white(225))
        rect(x,60,160,5,color.new(70,77,95,100),2)
        rect(x,60,160*pct/100,5,color.new(r,g,b,210),2)
    end
    bar('HEALTH',s.hp,12,70,196,135);bar('MANA',s.mana,188,87,152,235)
    text(tostring(s.action or 'Waiting'),12,79,15,color.new(201,175,250,255))
    text(tostring(s.reason or ''):sub(1,53),12,101,11,color.white(205))
    local ttd=s.ttd and string.format('%.1fs',s.ttd) or '?'
    text('Target: '..tostring(s.target or 'None'):sub(1,30)..'  |  '..ttd,12,123,12,color.white(230))
    text('Pet: '..tostring(s.pet or 'None'):sub(1,48),12,144,11,color.white(210))
    text('Drain Soul: '..tostring(s.drain_soul or 'Waiting'):sub(1,42),12,165,11,color.white(210))
    local cap=menu.auto_delete_excess_shards and menu.auto_delete_excess_shards:get_state() and tostring(s.shard_max or 10) or 'off'
    text(string.format('SHARDS  %d / %d min | cap %s',s.shards or 0,s.shard_min or 0,cap),12,188,12,color.new(218,194,250,245))
    text(tostring(affliction.REVISION)..' | Wrack '..(s.wrack and 'yes' or 'no')..' | Shadowburn '..(s.shadowburn_cd and string.format('%.1fs',s.shadowburn_cd) or 'not learned'),12,211,10,color.white(180))
    if interactive and drop then
        for i,name in ipairs(names) do
            local y=35+(i-1)*25
            rect(102,y,140,24,color.new(42,34,62,245),3);text(name,109,y+5,12,color.white(245))
            local a,b=vec2.new(102,y),vec2.new(242,y+24)
            window:is_mouse_hovering_rect_block_movement(a,b)
            if window:is_rect_clicked(a,b) then M.select(menu,i);drop=false end
        end
    end
end
-- Pure drawing has no window, mouse polling, hit boxes or capture calls.
function M.render_overlay(menu,gui_open)
    if not visible(menu,gui_open) or not clickthrough(menu) then return end
    observe_status(menu)
    local x,y=position(menu)
    paint(menu,function(dx,dy,w,h,col,rounding)
        core.graphics.rect_2d_filled(vec2.new(x+dx,y+dy),w,h,col,rounding)
    end,function(label,dx,dy,size,col)
        core.graphics.text_2d(label,vec2.new(x+dx,y+dy),size,col,false)
    end,false)
end
function M.render(menu,gui_open)
    if not visible(menu,gui_open) or clickthrough(menu) then
        if window then window:set_visibility(false) end
        return
    end
    observe_status(menu)
    local x,y=position(menu)
    if not window then
        window=core.menu.window('Warlock Status##AstroForever_Affliction_v2')
        window:set_initial_position(vec2.new(x,y));window:set_initial_size(vec2.new(WIDTH,HEIGHT))
        reset_position=true
    end
    window:set_visibility(true)
    if reset_position or x~=last_position_x or y~=last_position_y then
        window:force_next_begin_window_pos(vec2.new(x,y));window:force_window_size(vec2.new(WIDTH,HEIGHT))
        reset_position=false
    end
    window:begin(enums.window_enums.window_resizing_flags.NO_RESIZE,false,color.new(0,0,0,0),color.new(0,0,0,0),
        enums.window_enums.window_cross_visuals.NO_BACKGROUND_AND_NO_BORDER,function()
        paint(menu,function(dx,dy,w,h,col,rounding)
            window:render_rect_filled(vec2.new(dx,dy),vec2.new(dx+w,dy+h),col,rounding)
        end,function(label,dx,dy,size,col)
            window:render_text_custom_size(enums.window_enums.font_id.FONT_SMALL,vec2.new(dx,dy),col,size,label)
        end,true)
    end)
    local pos=window:get_position()
    if pos then
        last_position_x,last_position_y=math.floor(pos.x),math.floor(pos.y)
        if menu.aff_status_x then menu.aff_status_x:set(last_position_x) end
        if menu.aff_status_y then menu.aff_status_y:set(last_position_y) end
    end
end
return M
