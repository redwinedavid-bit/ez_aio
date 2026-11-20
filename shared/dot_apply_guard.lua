-- Shared DoT apply guard (Project Sylvanas / izi friendly)
-- Prevents double-casts when aura/debuff cache updates slightly late by locking a spell+target
-- for a short grace window after a cast request (and optionally across cast time).

local dot_apply_guard = {}

---@param obj any
---@return string|nil
local function target_key(obj)
    if not obj then
        return nil
    end

    if obj.is_valid then
        local ok_valid, valid = pcall(function()
            return obj:is_valid()
        end)
        if ok_valid and valid == false then
            return nil
        end
    end

    if obj.get_guid then
        local ok, g = pcall(function()
            return obj:get_guid()
        end)
        if ok and g then
            return tostring(g)
        end
    end

    return tostring(obj)
end

---@param spell any
---@return number|nil
local function safe_spell_id(spell)
    if not spell or not spell.id then
        return nil
    end
    local ok, id = pcall(function()
        return spell:id()
    end)
    if ok and id and id > 0 then
        return id
    end
    return nil
end

---@class dot_apply_guard_instance
---@field default_grace_ms integer
---@field spell_grace_ms table<number, integer>
---@field states table<number, table<string, integer>>

---@param opts table|nil
---@return dot_apply_guard_instance
function dot_apply_guard.new(opts)
    opts = opts or {}

    local self = setmetatable({
        default_grace_ms = tonumber(opts.default_grace_ms) or 250,
        spell_grace_ms = {},
        states = {}
    }, { __index = dot_apply_guard })

    if self.default_grace_ms < 0 then
        self.default_grace_ms = 0
    end

    return self
end

---@param self dot_apply_guard_instance
---@param ms integer
function dot_apply_guard.set_default_grace_ms(self, ms)
    ms = tonumber(ms) or 0
    if ms < 0 then
        ms = 0
    end
    self.default_grace_ms = ms
end

---@param self dot_apply_guard_instance
---@param spell_id number
---@param ms integer|nil
function dot_apply_guard.set_spell_grace_ms(self, spell_id, ms)
    if not spell_id or spell_id <= 0 then
        return
    end
    if ms == nil then
        self.spell_grace_ms[spell_id] = nil
        return
    end
    ms = tonumber(ms) or 0
    if ms < 0 then
        ms = 0
    end
    self.spell_grace_ms[spell_id] = ms
end

---@param self dot_apply_guard_instance
---@param spell_id number
---@return integer
function dot_apply_guard.get_grace_ms(self, spell_id)
    if spell_id and self.spell_grace_ms[spell_id] ~= nil then
        return self.spell_grace_ms[spell_id]
    end
    return self.default_grace_ms or 0
end

---@param self dot_apply_guard_instance
---@param spell_id number
---@param target any
---@return boolean
function dot_apply_guard.should_block(self, spell_id, target)
    if not self or not spell_id or spell_id <= 0 or not target then
        return false
    end

    if target.is_valid then
        local ok_valid, valid = pcall(function()
            return target:is_valid()
        end)
        if not ok_valid or valid ~= true then
            return false
        end
    end

    local now_ms = core.game_time()
    local key = target_key(target)
    if not key then
        return false
    end

    local per_spell = self.states[spell_id]
    if not per_spell then
        return false
    end

    local until_ms = per_spell[key]
    return until_ms ~= nil and now_ms < until_ms
end

---@param self dot_apply_guard_instance
---@param spell_id number
---@param target any
---@param until_ms integer
function dot_apply_guard.set_until(self, spell_id, target, until_ms)
    if not self or not spell_id or spell_id <= 0 or not target or not until_ms then
        return
    end

    local key = target_key(target)
    if not key then
        return
    end

    local per_spell = self.states[spell_id]
    if not per_spell then
        per_spell = {}
        self.states[spell_id] = per_spell
    end

    per_spell[key] = until_ms
end

---@param self dot_apply_guard_instance
---@param spell any
---@param target any
---@param grace_ms integer|nil
function dot_apply_guard.on_cast_requested(self, spell, target, grace_ms)
    local spell_id = type(spell) == "number" and spell or safe_spell_id(spell)
    if not spell_id then
        return
    end
    local ms = grace_ms
    if ms == nil then
        ms = self:get_grace_ms(spell_id)
    end
    self:set_until(spell_id, target, core.game_time() + ms)
end

---@param self dot_apply_guard_instance
---@param spell any
---@param target any
---@param cast_end_ms integer|nil
---@param grace_ms integer|nil
function dot_apply_guard.on_casting(self, spell, target, cast_end_ms, grace_ms)
    local spell_id = type(spell) == "number" and spell or safe_spell_id(spell)
    if not spell_id then
        return
    end
    if not cast_end_ms or cast_end_ms <= 0 then
        return
    end
    local ms = grace_ms
    if ms == nil then
        ms = self:get_grace_ms(spell_id)
    end
    self:set_until(spell_id, target, math.floor(cast_end_ms + ms))
end

return dot_apply_guard
