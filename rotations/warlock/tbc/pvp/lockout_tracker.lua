local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Warlock School Lockout Tracker (TBC PvP)
-- Tracks which spell school is locked after an interrupt and provides
-- fallback spell recommendations.
-- Uses izi.on_spell_cancel() to detect interrupts automatically.
-- ============================================================================

local lockout_tracker = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

-- State
local locked_school = nil      -- nil, "shadow", or "fire"
local lockout_expires_ms = 0   -- game_time when lockout ends

-- Shadow spells (locked when Shadow school interrupted)
local SHADOW_SPELL_IDS = {}  -- populated in init(), set of spell_id -> true
-- Fire spells (locked when Fire school interrupted)
local FIRE_SPELL_IDS = {}    -- populated in init(), set of spell_id -> true

-- Standard lockout durations (milliseconds)
local LOCKOUT_DURATION_MS = 3000  -- Conservative default (varies by interrupt source)

-- Track the last spell we were casting (to detect which school was interrupted)
local last_casting_spell_id = 0
local last_casting_start_ms = 0

-- Unsubscribe handle for cleanup
local unsubscribe_spell_cancel = nil
local unsubscribe_spell_begin = nil

-- Optional logging function (injected from pvp/init.lua)
local _log_fn = nil

local function lt_log(message)
    if _log_fn then _log_fn(message) end
end

function lockout_tracker.set_log_fn(fn)
    _log_fn = fn
end

local function to_number(v)
    local t = type(v)
    if t == "number" then return v end
    if t == "string" then return tonumber(v) end
    if t == "table" then
        -- Common shapes across runtimes / wrappers
        local candidates = {
            v.ms, v.time_ms, v.value_ms, v.value,
            v.t, v.time, v.game_time, v.now,
            v.expires_ms, v.expires, v.until_ms,
        }
        for _, c in ipairs(candidates) do
            local n = tonumber(c)
            if n then return n end
        end
        local n1 = tonumber(v[1])
        if n1 then return n1 end
        return nil
    end
    local ok, n = pcall(function() return tonumber(v) end)
    return ok and n or nil
end

-- ============================================================================
-- INTERNAL: Spell school lookup
-- ============================================================================

local function is_shadow_spell(spell_id)
    return SHADOW_SPELL_IDS[spell_id] == true
end

local function is_fire_spell(spell_id)
    return FIRE_SPELL_IDS[spell_id] == true
end

local function get_spell_school(spell_id)
    if is_shadow_spell(spell_id) then return "shadow" end
    if is_fire_spell(spell_id) then return "fire" end
    return nil
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Initialize with spell IDs from the spells module and register event listeners.
---@param spells table The spells module
function lockout_tracker.init(spells)
    -- Build Shadow spell ID lookup (set for O(1) lookup)
    local shadow_spells = {
        spells.shadow_bolt, spells.corruption, spells.fear,
        spells.drain_life, spells.drain_soul, spells.drain_mana,
        spells.death_coil, spells.howl_of_terror,
        spells.unstable_affliction, spells.seed_of_corruption,
        spells.curse_of_agony, spells.curse_of_doom,
        spells.siphon_life, spells.shadowburn,
        spells.curse_of_tongues, spells.curse_of_exhaustion,
    }
    SHADOW_SPELL_IDS = {}
    for _, spell in ipairs(shadow_spells) do
        if spell then
            local ok, id = pcall(function() return spell:id() end)
            if ok and id and id > 0 then
                SHADOW_SPELL_IDS[id] = true
            end
        end
    end

    -- Build Fire spell ID lookup
    local fire_spells = {
        spells.immolate, spells.incinerate, spells.conflagrate,
        spells.searing_pain, spells.rain_of_fire,
        spells.hellfire, spells.soul_fire,
    }
    FIRE_SPELL_IDS = {}
    for _, spell in ipairs(fire_spells) do
        if spell then
            local ok, id = pcall(function() return spell:id() end)
            if ok and id and id > 0 then
                FIRE_SPELL_IDS[id] = true
            end
        end
    end

    -- Register spell begin callback: track what we're casting
    if izi.on_spell_begin then
        unsubscribe_spell_begin = izi.on_spell_begin(function(data)
            if not data or not data.spell_id then return end
            local local_player = core.object_manager.get_local_player()
            if not local_player then return end
            -- Only track our own casts
            if data.caster and (__object_safety.same(data.caster,local_player)) then
                local school = get_spell_school(data.spell_id)
                if school then
                    last_casting_spell_id = data.spell_id
                    last_casting_start_ms = core.game_time()
                end
            end
        end)
    end

    -- Register spell cancel callback: detect interrupts
    if izi.on_spell_cancel then
        unsubscribe_spell_cancel = izi.on_spell_cancel(function(data)
            if not data or not data.spell_id then return end
            local local_player = core.object_manager.get_local_player()
            if not local_player then return end

            -- Only handle our own cancelled spells
            if data.caster and (__object_safety.same(data.caster,local_player)) then
                local spell_id = data.spell_id
                local school = get_spell_school(spell_id)
                if not school then return end

                -- Distinguish interrupt from manual cancel:
                -- If we were casting for at least 100ms and the spell was cancelled,
                -- check if we're now silenced (indicates interrupt, not manual stop)
                local now = core.game_time()
                local cast_duration = now - last_casting_start_ms

                -- Short cast threshold: if we cast for < 100ms, likely not an interrupt
                if cast_duration < 100 then return end

                -- Check if player is silenced (strong indicator of interrupt)
                local is_interrupted = false
                pcall(function()
                    local silenced = local_player:is_silenced(100)
                    if silenced then is_interrupted = true end
                end)

                -- Also check: if the spell simply failed to cast (not on GCD anymore
                -- but we didn't finish), it's likely an interrupt
                if not is_interrupted then
                    -- Fallback heuristic: if cast was well into progress and didn't succeed,
                    -- assume interrupt. Raised to 800ms to avoid false positives from
                    -- movement cancels, which are very common during PvP combat.
                    if cast_duration >= 800 then
                        is_interrupted = true
                    end
                end

                if is_interrupted then
                    lt_log(string.format("[Warlock][PvP][Lockout] Interrupt detected: %s school, spell_id=%d, cast_duration=%dms", school, spell_id, cast_duration))
                    lockout_tracker.on_interrupted(school, LOCKOUT_DURATION_MS)
                end
            end
        end)
    end
end

--- Call when a cast fails due to interrupt.
---@param school string "shadow" or "fire"
---@param duration_ms number|nil Optional lockout duration override
function lockout_tracker.on_interrupted(school, duration_ms)
    if school ~= "shadow" and school ~= "fire" then return end
    local now = to_number(core.game_time())
    local dur = to_number(duration_ms) or LOCKOUT_DURATION_MS
    if not now then
        lt_log("[Warlock][PvP][Lockout] on_interrupted: invalid core.game_time() (skipping)")
        return
    end
    locked_school = school
    lockout_expires_ms = now + dur
    lt_log(string.format("[Warlock][PvP][Lockout] %s school LOCKED for %dms", school, dur))
end

--- Check if a spell school is currently locked.
---@param now number|nil Current game time (optional, uses core.game_time())
---@return string|nil The locked school ("shadow" or "fire"), or nil if none
function lockout_tracker.get_locked_school(now)
    if not locked_school then return nil end
    now = to_number(now) or to_number(core.game_time()) or 0
    local expires = to_number(lockout_expires_ms)
    if not expires then
        lt_log("[Warlock][PvP][Lockout] Corrupted lockout_expires_ms; resetting lockout state")
        locked_school = nil
        lockout_expires_ms = 0
        return nil
    end
    if now >= expires then
        locked_school = nil
        return nil
    end
    return locked_school
end

--- Check remaining lockout time in milliseconds.
---@param now number|nil
---@return number Remaining lockout ms (0 if not locked)
function lockout_tracker.get_lockout_remaining_ms(now)
    if not locked_school then return 0 end
    now = to_number(now) or to_number(core.game_time()) or 0
    local expires = to_number(lockout_expires_ms)
    if not expires then
        lt_log("[Warlock][PvP][Lockout] Corrupted lockout_expires_ms; resetting lockout state")
        locked_school = nil
        lockout_expires_ms = 0
        return 0
    end
    local remaining = expires - now
    if remaining <= 0 then
        locked_school = nil
        return 0
    end
    return remaining
end

--- Check if Shadow school is currently locked.
---@return boolean
function lockout_tracker.is_shadow_locked(now)
    return lockout_tracker.get_locked_school(now) == "shadow"
end

--- Check if Fire school is currently locked.
---@return boolean
function lockout_tracker.is_fire_locked(now)
    return lockout_tracker.get_locked_school(now) == "fire"
end

--- Per-frame update: auto-expire lockout state.
--- Call this every frame from the PvP rotation.
---@param player game_object
function lockout_tracker.on_update(player)
    if not player then return end
    local now = to_number(core.game_time()) or 0
    local expires = to_number(lockout_expires_ms)
    if locked_school and expires and now >= expires then
        lt_log(string.format("[Warlock][PvP][Lockout] %s school UNLOCKED (expired)", locked_school))
        locked_school = nil
    end
end

--- Clear lockout state (e.g., when leaving combat).
function lockout_tracker.reset()
    locked_school = nil
    lockout_expires_ms = 0
    last_casting_spell_id = 0
    last_casting_start_ms = 0
end

return lockout_tracker
