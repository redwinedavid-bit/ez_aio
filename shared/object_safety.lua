-- Native objects can expire between frames, reads, and action dispatches.
local safety={}
local unpack_values=table.unpack or unpack
local function pack(...) return {n=select('#',...),...} end
local skipped=0
local last_failure=nil
function safety.is_invalid_error(err)
    return type(err)=='string' and err:find('Invalid game object',1,true)~=nil
end
function safety.valid(unit)
    if not unit then return false end
    local ok,value=pcall(function() return unit:is_valid() end)
    return ok and value==true
end
function safety.guid(unit)
    if not unit then return nil end
    local ok,value=pcall(function()
        if not unit:is_valid() then return nil end
        return unit:get_guid()
    end)
    if ok and type(value)=='string' and value~='' then return value end
end
function safety.same(a,b)
    if not a or not b then return rawequal(a,b) end
    local ga=safety.guid(a)
    if not ga then return false end
    local gb=safety.guid(b)
    return gb~=nil and ga==gb
end
function safety.resolve(guid)
    if type(guid)~='string' or guid=='' then return nil end
    local ok,unit=pcall(core.object_manager.get_object_from_guid,guid)
    if ok and safety.guid(unit)==guid then return unit end
end
-- This wrapper handles native lifetime races only. Programming errors still
-- propagate. Keep diagnostics in memory without flooding the 60 FPS log.
function safety.callback(fn,label,fallback)
    return function(...)
        local result=pack(pcall(fn,...))
        if result[1] then return unpack_values(result,2,result.n) end
        if not safety.is_invalid_error(result[2]) then error(result[2],0) end
        skipped=skipped+1;last_failure={label=label,error=result[2]}
        return fallback
    end
end
function safety.diagnostics() return skipped,last_failure end
local function live(value)
    local kind=type(value)
    if kind~='userdata' and kind~='table' then return true end
    local ok,is_object=pcall(function() return type(value.is_valid)=='function' end)
    return ok and (not is_object or safety.valid(value))
end
local function next_live(list,index)
    while true do
        index=index+1
        local value=list[index]
        if value==nil then return nil end
        if live(value) then return index,value end
    end
end
function safety.live_ipairs(list) return next_live,list,0 end
local function next_live_pair(list,key)
    while true do
        local value
        key,value=next(list,key)
        if key==nil then return nil end
        if live(key) and live(value) then return key,value end
    end
end
function safety.live_pairs(list) return next_live_pair,list,nil end
-- Filter only SDK objects; ordinary metadata in mixed lists is preserved.
function safety.copy_live_list(list)
    if type(list)~='table' then return list end
    local out={}
    local count=#list
    for i=1,count do if live(list[i]) then out[#out+1]=list[i] end end
    for key,value in pairs(list) do
        if not (type(key)=='number' and key>=1 and key<=count and key==math.floor(key))
            and live(value) then out[key]=value end
    end
    return out
end
return safety
