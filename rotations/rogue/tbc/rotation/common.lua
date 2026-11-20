local common = {}

---@type enums
local enums = require("common/enums")

local spell_data = require("rotations/rogue/tbc/spell_data")

local TTD_FINISHER_WINDOW = 2.5

local function has_any_debuff_ids(target, ids)
    if not target or not ids then
        return false
    end
    for _, id in ipairs(ids) do
        local ok, up = pcall(function()
            return target:debuff_up(id) == true
        end)
        if ok and up then
            return true
        end
    end
    return false
end

local function is_spell_learned_any(ids)
    for _, id in ipairs(ids or {}) do
        local ok, learned = pcall(function()
            return core.spell_book.is_spell_learned(id)
        end)
        if ok and learned == true then
            return true
        end
    end
    return false
end

local function menu_allows_shiv(helpers)
    local m = helpers and helpers._menu_elements or nil
    if not m or not m.use_shiv or not m.use_shiv.get_state then
        return true
    end
    return m.use_shiv:get_state() == true
end

local function menu_allows_envenom(helpers)
    local m = helpers and helpers._menu_elements or nil
    if not m or not m.pve_use_envenom or not m.pve_use_envenom.get_state then
        return true
    end
    return m.pve_use_envenom:get_state() == true
end

local function menu_allows_rupture(helpers)
    local m = helpers and helpers._menu_elements or nil
    if not m or not m.pve_use_rupture or not m.pve_use_rupture.get_state then
        return true
    end
    return m.pve_use_rupture:get_state() == true
end

local function menu_get_rupture_min_ttd(helpers)
    local m = helpers and helpers._menu_elements or nil
    if not m or not m.pve_rupture_min_ttd or not m.pve_rupture_min_ttd.get then
        return 12
    end
    local ok, v = pcall(function()
        return m.pve_rupture_min_ttd:get()
    end)
    if not ok or type(v) ~= "number" then
        return 12
    end
    return v
end

local function menu_get_rupture_min_cp(helpers)
    local m = helpers and helpers._menu_elements or nil
    if not m or not m.pve_rupture_min_cp or not m.pve_rupture_min_cp.get then
        return 5
    end
    local ok, v = pcall(function()
        return m.pve_rupture_min_cp:get()
    end)
    if not ok or type(v) ~= "number" then
        return 5
    end
    if v < 1 then
        return 1
    end
    if v > 5 then
        return 5
    end
    return v
end

local function safe_time_to_die(target)
    if not target then
        return nil
    end

    local ok, ttd = pcall(function()
        return target:time_to_die()
    end)

    if not ok or not ttd or ttd <= 0 then
        return nil
    end

    return ttd
end

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
    -- Don't pool during Adrenaline Rush (energy regen is doubled)
    if has_adrenaline_rush then
        return false
    end

    -- NEVER pool if we have 5 CP - always use finisher immediately
    if cp >= 5 then
        return false
    end

    -- Pool if we're close to capping (90-94 energy) AND have high CP (4)
    -- This prevents energy waste while building to 5 CP
    -- Fixed: Changed from >= 95 to avoid deadlock where finisher can't be cast
    if energy >= 90 and energy < 95 and cp >= 4 then
        return true
    end

    return false
end

-- Calculate dynamic energy threshold based on buffs
---@param base_cost number
---@param has_adrenaline_rush boolean
---@return number
function common.get_energy_threshold_for_builder(base_cost, has_adrenaline_rush)
    if has_adrenaline_rush then
        -- Lower threshold during AR (faster regen)
        return math.max(base_cost - 20, 25)
    end
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

    local ttd = target:time_to_die()
    if not ttd or ttd <= 0 then
        return false
    end

    if ttd <= TTD_FINISHER_WINDOW then
        return helpers:try_cast_finisher(local_player, target, "eviscerate")
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

--- Handles Slice and Dice refresh with Pandemic logic.
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
    -- Energy check (SnD costs 25 energy)
    if energy < 25 then
        return false
    end

    -- EMERGENCY REFRESH: <1s remaining, 1+ CP
    -- Only applies when SnD is ACTIVE (snd_remaining > 0) but about to expire
    -- Prevents downtime at the cost of lower CP usage
    if snd_remaining > 0 and snd_remaining <= 1000 and cp >= 1 then
        if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std07", 0.8, "[ROT] STD07")
            end
            return true
        end
    end

    -- OPTIMAL REFRESH: <=3s remaining, 2+ CP
    -- Handles both:
    -- 1. Initial cast (snd_remaining == 0, check <=3000ms always true)
    -- 2. Refresh cast (snd_remaining <=3000ms with 2+ CP for 12s+ duration)
    if snd_remaining <= 3000 and cp >= 2 then
        if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std08", 0.8, "[ROT] STD08")
            end
            return true
        end
    end

    return false
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

    -- Envenom (TBC Assassination): only if Deadly Poison is active on target.
    if menu_allows_envenom(helpers) and cp >= 5 and spell_data and spell_data.finishers and spell_data.finishers.envenom then
        local envenom = spell_data.finishers.envenom
        if is_spell_learned_any(envenom.ids) and spell_data.debuffs and spell_data.debuffs.deadly_poison then
            if has_any_debuff_ids(target, spell_data.debuffs.deadly_poison) then
                if helpers:try_cast_finisher(local_player, target, "envenom") then
                    if helpers and helpers.log_checkpoint then
                        helpers:log_checkpoint("rot.std09e", 0.6, "[ROT] STD09E")
                    end
                    return true
                end
            end
        end
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
    -- Check energy pooling (prevent waste at 90-94 energy with 4 CP)
    local should_pool = common.should_pool_energy(energy, cp, has_ar_buff)
    if should_pool then
        if helpers and helpers.log_checkpoint then
            helpers:log_checkpoint("rot.std15", 0.8, "[ROT] STD15")
        end
        return false
    end

    -- Calculate dynamic energy thresholds (lower during AR)
    local mut_threshold = common.get_energy_threshold_for_builder(60, has_ar_buff)
    local bs_threshold = common.get_energy_threshold_for_builder(60, has_ar_buff)
    local hemo_threshold = common.get_energy_threshold_for_builder(35, has_ar_buff)
    local ss_threshold = common.get_energy_threshold_for_builder(45, has_ar_buff)
    local gs_threshold = common.get_energy_threshold_for_builder(40, has_ar_buff)

    -- Unified builder priority (learned/castable-driven; no spec branching):
    -- Mutilate > Backstab (behind/dagger) > Hemorrhage > Sinister Strike > Ghostly Strike
    if energy >= mut_threshold then
        if helpers:try_cast_builder(local_player, target, "mutilate") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std10m", 0.6, "[ROT] STD10M")
            end
            return true
        end
    end

    -- Shiv: poison/CP utility when Deadly Poison is not present (works for any spec if enabled/learned).
    if menu_allows_shiv(helpers) and energy >= 20 and cp <= 4 and spell_data and spell_data.debuffs and spell_data.debuffs.deadly_poison then
        if not has_any_debuff_ids(target, spell_data.debuffs.deadly_poison) then
            if helpers:try_cast_builder(local_player, target, "shiv") then
                if helpers and helpers.log_checkpoint then
                    helpers:log_checkpoint("rot.std10v", 0.6, "[ROT] STD10V")
                end
                return true
            end
        end
    end

    if energy >= bs_threshold then
        if helpers:try_cast_builder(local_player, target, "backstab") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std11", 0.6, "[ROT] STD11")
            end
            return true
        end
    end

    if energy >= hemo_threshold then
        if helpers:try_cast_builder(local_player, target, "hemorrhage") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std12", 0.6, "[ROT] STD12")
            end
            return true
        end
    end

    if energy >= ss_threshold then
        if helpers:try_cast_builder(local_player, target, "sinister_strike") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std13", 0.6, "[ROT] STD13")
            end
            return true
        end
    end

    if energy >= gs_threshold then
        if helpers:try_cast_builder(local_player, target, "ghostly_strike") then
            if helpers and helpers.log_checkpoint then
                helpers:log_checkpoint("rot.std14", 0.6, "[ROT] STD14")
            end
            return true
        end
    end

    return false
end

--- Centralized TBC PvE Finisher Logic
--- Priority: SnD (Uptime) > Expose Armor (if enabled) > Rupture (Elite/Boss) > Eviscerate/Envenom (Filler)
---
--- @param local_player game_object
--- @param target game_object
--- @param helpers table
--- @param energy number
--- @param cp number
--- @param target_hp_percent number
--- @param snd_remaining number
--- @return boolean
function common.try_tbc_pve_finishers(local_player, target, helpers, energy, cp, target_hp_percent, snd_remaining)
    -- PRIORITY 1: Slice and Dice (100% uptime is #1)
    -- Conservative refresh rules so we can still reach 4-5 CP for finishers:
    -- - Missing: cast with 1+ CP (pool energy if needed)
    -- - Emergency refresh: <=1s with 1+ CP
    -- - Optimal refresh: <=3s with 2+ CP
    if snd_remaining == 0 and cp >= 1 then
        if energy >= 25 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end
        return true -- pool for SnD
    end

    if snd_remaining > 0 and snd_remaining <= 1000 and cp >= 1 then
        if energy >= 25 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end
        return true -- pool for SnD
    end

    if snd_remaining > 0 and snd_remaining <= 3000 and cp >= 2 then
        if energy >= 25 then
            if helpers:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end
        if snd_remaining <= 1500 then
            return true -- pool for SnD if close to falling
        end
    end

    -- PRIORITY 2: Expose Armor (Boss/Elite armor reduction)
    -- helpers:try_cast_expose_armor handles menu checks, stance, and existing sunder/EA
    if cp >= 5 then
        if helpers:try_cast_expose_armor(local_player, target, cp) then
            return true
        end
    end

    -- PRIORITY 3: Rupture (High damage DoT, Elite/Boss only)
    -- Only if SnD has comfortable uptime and the target will live long enough.
    local rupture_min_cp = menu_get_rupture_min_cp(helpers)
    if menu_allows_rupture(helpers) and cp >= rupture_min_cp and snd_remaining > 4500 then
        local ttd = safe_time_to_die(target)
        local min_ttd = menu_get_rupture_min_ttd(helpers)
        if not ttd or ttd >= min_ttd then
            if helpers:try_cast_rupture(local_player, target, cp) then
                return true
            end
        end
    end

    -- PRIORITY 4: Eviscerate / Envenom (Filler)
    -- Cold Blood Activation: If we are about to Eviscerate/Envenom at 5 CP, use Cold Blood if available
    if cp >= 5 and energy >= 35 then
        local cb = spell_data.cooldowns and spell_data.cooldowns.cold_blood
        if cb and is_spell_learned_any(cb.ids) and not spell_helper:is_spell_on_cooldown(cb.ids[1]) then
            if not local_player:has_buff(cb.ids[1]) then
                if helpers:try_cast_cooldown(local_player, "cold_blood") then
                    return true
                end
            end
        end
    end

    if cp >= 5 then
        return common.try_standard_eviscerate(local_player, target, helpers, energy, cp, target_hp_percent)
    end

    return false
end

return common
