local common = {}

---@type enums
local enums = require("common/enums")

local TTD_FINISHER_WINDOW = 2.5

local forecast=require("rotations/rogue/era/rotation/ttd")
local safe_time_to_die=forecast.get

--- Determines whether Blade Flurry should be used during burst for the current target context.
--- Keeps logic level-agnostic and safe: uses Project Sylvanas unit methods only, guarded by pcall.
---
--- @param target game_object
--- @param is_aoe boolean
--- @param enemy_ttd_count number
--- @param is_elite_or_boss boolean
--- @param target_hp_percent number
--- @return boolean
function common.should_use_blade_flurry_burst(target, is_aoe, enemy_ttd_count, is_elite_or_boss, target_hp_percent)
    if is_aoe then
        return enemy_ttd_count >= 2
    end

    if not is_elite_or_boss and target_hp_percent <= 80 then
        return false
    end

    local ttd = safe_time_to_die(target)
    if ttd then
        return ttd >= 12.0
    end

    return target_hp_percent > 80
end

-- Check if we should pool energy (avoid capping, prepare for burst)
---@param energy number
---@param cp number
---@param has_adrenaline_rush boolean
---@return boolean
function common.should_pool_energy(energy, cp, has_adrenaline_rush)
    -- No pooling without a concrete goal. In particular, never deliberately
    -- hold a builder at 90+ energy; cooldown timing is handled independently.
    return false
end

-- Calculate dynamic energy threshold based on buffs
---@param base_cost number
---@param has_adrenaline_rush boolean
---@return number
function common.get_energy_threshold_for_builder(base_cost, has_adrenaline_rush)
    -- Regeneration speed does not reduce the cost of a spell.
    return base_cost
end

---@param target game_object
---@param energy number
---@param cp number
---@param helpers table
---@param local_player game_object
---@return boolean
function common.try_spend_cp_before_death(target, energy, cp, helpers, local_player)
    if cp < 1 or energy < 35 then
        return false
    end

    if forecast.finish_soon(target,cp) then
        return helpers:try_cast_finisher(local_player,target,"eviscerate")
    end

    return false
end

--- Handles interrupt attempts and CC pause checks.
--- This is the FIRST priority in all rotations - always executes before damage abilities.
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param helpers table Helper module reference
--- @param has_cheap_shot boolean Whether target has Cheap Shot active
--- @param cc_check_func function
--- @return boolean true if interrupt was cast OR rotation should pause for CC
function common.try_standard_interrupt_and_cc_check(local_player, target, helpers, has_cheap_shot, cc_check_func)
    -- PRIORITY 1: INTERRUPT current target (Kick -> Gouge fallback)
    -- Emergency action - ALWAYS allowed even during CC
    if helpers:try_interrupt_cast(local_player, target) then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std01", 0.4, "[ROT] STD01")
        end
        return true
    end

    -- PRIORITY 2: INTERRUPT nearby enemies (5 yards, frontal arc)
    -- Pools energy for Gouge if Kick on CD and enemy casting
    if helpers:try_interrupt_nearby(local_player, 5, math.pi / 2) then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std02", 0.4, "[ROT] STD02")
        end
        return true
    end

    -- PRIORITY 3: CRITICAL CC CHECK
    -- Stop DAMAGE rotation if target is CC'd (Gouge, Sap, Blind)
    -- Does NOT break on stuns (Cheap Shot, Kidney Shot) as they allow damage
    if cc_check_func and cc_check_func(target, has_cheap_shot) then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std03", 0.8, "[ROT] STD03")
        end
        return true  -- Don't break CC with damage!
    end

    return false
end

--- Handles defensive and emergency CC abilities.
--- Executes after interrupt/CC check but before offensive abilities.
--- Includes: Riposte (parry counter), Feint (threat), Kidney Shot (emergency stun)
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param helpers table Helper module reference
--- @param cp number Current combo points
--- @param target_hp_percent number Target HP percentage
--- @param cc_enabled boolean Whether CC toggle is active
--- @return boolean true if any defensive ability was cast
function common.try_standard_defensive_abilities(local_player, target, helpers, cp, target_hp_percent, cc_enabled)
    -- RIPOSTE (Defensive - after parry, disarms for 6s)
    -- Available at Level 20+ (Combat talent)
    if helpers:try_cast_riposte(local_player, target) then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std04", 0.6, "[ROT] STD04")
        end
        return true
    end

    -- FEINT (threat reduction in group)
    -- Available at Level 8+
    if helpers:try_use_feint(local_player, target) then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std05", 0.6, "[ROT] STD05")
        end
        return true
    end

    -- KIDNEY SHOT (EMERGENCY stun on Elite/Boss at high HP)
    -- Only use at 5 CP when target is Elite/Boss with >60% HP
    -- This acts as a defensive stun, not an offensive finisher
    if cc_enabled then
        local is_elite_or_boss = target:get_classification() >= enums.classification.ELITE
        if is_elite_or_boss and cp >= 5 and target_hp_percent > 60 then
            if helpers:try_cast_cc(local_player, target, "kidney_shot") then
                if helpers and helpers.log_checkpoint then
                    helpers:log_checkpoint("rot.std06", 0.8, "[ROT] STD06")
                end
                return true
            end
        end
    end

    return false
end

--- Applies Slice and Dice only after the current buff has expired.
--- This is CRITICAL for energy efficiency and follows Classic Era mechanics.
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param helpers table Helper module reference
--- @param energy number Current energy
--- @param cp number Current combo points
--- @param snd_remaining number SnD buff remaining time in milliseconds
--- @return boolean true if SnD was cast
function common.try_standard_snd_refresh(local_player, target, helpers, energy, cp, snd_remaining)
    -- Preserve all remaining uptime, including the last frame of the buff.
    if snd_remaining>0 or helpers:has_buff(local_player,"slice_and_dice") then return false end
    if cp<1 or forecast.finish_soon(target,cp) then return false end
    return helpers:try_cast_finisher(local_player,target,"slice_and_dice")
end

--- Handles Eviscerate (damage finisher) at 5 CP or low HP burst.
--- Standard damage finisher for all specs and levels.
---
--- PRIORITY LOGIC:
--- - 5 CP: Always Eviscerate (optimal damage)
--- - 3+ CP + <20% HP: Burst damage to finish target quickly
---
--- ENERGY COST: 35 energy (more expensive than SnD's 25)
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param helpers table Helper module reference
--- @param energy number Current energy
--- @param cp number Current combo points
--- @param target_hp_percent number Target HP percentage
--- @return boolean true if Eviscerate was cast
function common.try_standard_eviscerate(local_player, target, helpers, energy, cp, target_hp_percent)
    -- Energy check (Eviscerate costs 35 energy)
    if energy < 35 then
        return false
    end

    -- Standard Eviscerate at 5 CP
    if cp >= 5 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std09", 0.6, "[ROT] STD09")
            end
            return true
        end
    end

    -- Burst on low HP targets (finish quickly with 3+ CP)
    if cp >= 3 and target_hp_percent < 20 then
        if helpers:try_cast_finisher(local_player, target, "eviscerate") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std10", 0.6, "[ROT] STD10")
            end
            return true
        end
    end

    return false
end

--- Handles combo point builder abilities with energy pooling.
--- Priority: Backstab (Dagger+Behind) > Hemorrhage > Sinister Strike > Ghostly Strike
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param helpers table Helper module reference
--- @param energy number Current energy
--- @param cp number Current combo points
--- @param has_ar_buff boolean Whether Adrenaline Rush is active
--- @return boolean true if any builder was cast
function common.try_standard_builders(local_player, target, helpers, energy, cp, has_ar_buff)
    -- Do not overcap combo points while a finisher is temporarily unavailable.
    if cp>=5 or forecast.finish_soon(target,cp) then return false end
    if helpers.is_combat_swords_maces and helpers:is_combat_swords_maces() then
        return helpers:try_cast_builder(local_player,target,"sinister_strike")
    end
    -- Optional automatic builder selection for a different weapon/talent setup.
    -- The SDK checks each spell's real cost, learned state and restrictions.
    for _,name in ipairs({"backstab","hemorrhage","sinister_strike","ghostly_strike"}) do
        if helpers:try_cast_builder(local_player,target,name) then return true end
    end
    return false
end

return common
