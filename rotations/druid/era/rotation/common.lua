-- ============================================================================
-- Druid Rotation - Common Patterns (Classic ERA)
-- Emergency survival, buff management, Faerie Fire, OOC healing
-- Shared across all specs; runs BEFORE spec-specific rotation
-- ============================================================================

local common = {}

local spell_data = require("rotations/druid/era/spell_data")
local dot_apply_guard = require("shared/dot_apply_guard")

-- ============================================================================
-- EMERGENCY SURVIVAL (highest priority, all specs)
-- ============================================================================

--- Try emergency survival actions. Runs before any spec rotation.
--- @param player game_object
--- @param helpers table
--- @return boolean true if an emergency action was taken
function common.try_emergency_survival(player, helpers)
    if not player then return false end

    local hp = helpers:get_player_hp(player)
    local in_combat = helpers:is_in_combat(player)
    if not in_combat then return false end

    local is_hardcore = helpers:is_hardcore_mode()
    local level = helpers:get_player_level(player)

    -- 1. Barkskin (usable in any form, even while stunned) - instant 20% DR
    if helpers:get_menu_state("use_barkskin") and level >= 44 then
        local barkskin_hp = helpers:get_menu_value("barkskin_hp", 50)
        if hp < barkskin_hp then
            if not helpers:has_buff(player, "barkskin") then
                if helpers:is_cooldown_ready("buffs_utility", "barkskin") then
                    if helpers:try_cast("buffs_utility", "barkskin", player) then
                        helpers:log_checkpoint("barkskin", 3.0, "[Druid][Survival] Barkskin at HP=" .. math.floor(hp))
                        return true
                    end
                end
            end
        end
    end

    -- 2. Nature's Grasp (instant self-buff, roots melee attackers)
    if helpers:get_menu_state("use_natures_grasp") then
        if hp < 60 and helpers:is_in_caster_form(player) then
            if not helpers:has_buff(player, "natures_grasp") then
                if helpers:is_cooldown_ready("balance", "natures_grasp") then
                    if helpers:try_cast("balance", "natures_grasp", player) then
                        helpers:log_checkpoint("natures_grasp", 3.0, "[Druid][Survival] Nature's Grasp at HP=" .. math.floor(hp))
                        return true
                    end
                end
            end
        end
    end

    -- 3. Emergency Bear Form (Hardcore: any spec shifts to bear when critical)
    if is_hardcore then
        if helpers:try_emergency_bear(player) then
            return true
        end
    end

    -- 4. Frenzied Regeneration (in bear form, low HP)
    if helpers:is_in_bear_form(player) and level >= 36 then
        local frenzied_hp = helpers:get_menu_value("tank_frenzied_reg_hp", 25)
        if hp < frenzied_hp then
            if helpers:is_cooldown_ready("bear", "frenzied_regeneration") then
                if helpers:try_cast("bear", "frenzied_regeneration", player) then
                    helpers:log_checkpoint("frenzied_regen", 3.0, "[Druid][Survival] Frenzied Regeneration at HP=" .. math.floor(hp))
                    return true
                end
            end
        end
    end

    -- 5. Nature's Swiftness + Healing Touch emergency combo
    local ns_ht_hp = helpers:get_menu_value("ns_ht_hp", 25)
    if hp < ns_ht_hp and level >= 30 then
        if helpers:is_spell_learned("restoration", "natures_swiftness") then
            if helpers:is_cooldown_ready("restoration", "natures_swiftness") then
                -- Need to be in caster form for NS+HT
                if not helpers:is_in_caster_form(player) then
                    if helpers:ensure_form(player, "caster") then
                        helpers:log_checkpoint("ns_ht", 3.0, "[Druid][Survival] Shifting to caster for NS+HT")
                        return true
                    end
                end

                -- Cast Nature's Swiftness
                if helpers:has_buff(player, "natures_swiftness") then
                    -- NS is active, cast max rank HT on self
                    if helpers:try_cast("restoration", "healing_touch", player) then
                        helpers:log_checkpoint("ns_ht", 3.0, "[Druid][Survival] NS+HT at HP=" .. math.floor(hp))
                        return true
                    end
                else
                    if helpers:try_cast("restoration", "natures_swiftness", player) then
                        helpers:log_checkpoint("ns_ht", 3.0, "[Druid][Survival] Nature's Swiftness activated")
                        return true
                    end
                end
            end
        end
    end

    -- 6. Health Potion (emergency)
    if hp < 20 then
        if helpers:try_use_health_potion(player, 20) then
            return true
        end
        if helpers:try_use_healthstone(player, 20) then
            return true
        end
    end

    -- 7. Travel Form escape (Hardcore/PvP: flee when critical)
    if is_hardcore or helpers:is_pvp_mode() then
        if helpers:try_travel_form_escape(player) then
            return true
        end
    end

    return false
end

-- ============================================================================
-- BUFF MANAGEMENT (OOC priority, low-priority IC)
-- ============================================================================

--- Try to apply missing buffs (Mark of the Wild, Thorns, Omen of Clarity)
--- @param player game_object
--- @param helpers table
--- @return boolean true if a buff was cast
function common.try_buff_management(player, helpers)
    if not player then return false end

    -- Only buff OOC to avoid wasting combat GCDs
    if helpers:is_in_combat(player) then return false end

    -- Must be in caster form to buff
    if not helpers:is_in_caster_form(player) then return false end

    local level = helpers:get_player_level(player)

    -- Mark of the Wild on self
    if helpers:get_menu_state("auto_motw") and level >= 1 then
        if not helpers:has_buff(player, "mark_of_the_wild") then
            if helpers:try_cast("buffs_utility", "mark_of_the_wild", player) then
                helpers:log_checkpoint("motw_self", 5.0, "[Druid][Buffs] Mark of the Wild on self")
                return true
            end
        end

        -- MotW on party members
        local need_motw = helpers:get_members_without_motw()
        if need_motw and #need_motw > 0 then
            if helpers:try_cast("buffs_utility", "mark_of_the_wild", need_motw[1]) then
                helpers:log_checkpoint("motw_party", 3.0, "[Druid][Buffs] Mark of the Wild on party member")
                return true
            end
        end
    end

    -- Thorns on self
    if helpers:get_menu_state("auto_thorns") and level >= 6 then
        if not helpers:has_buff(player, "thorns") then
            if helpers:try_cast("buffs_utility", "thorns", player) then
                helpers:log_checkpoint("thorns_self", 5.0, "[Druid][Buffs] Thorns on self")
                return true
            end
        end

        -- Thorns on tank
        local tank_target = helpers:get_member_without_thorns()
        if tank_target then
            if helpers:try_cast("buffs_utility", "thorns", tank_target) then
                helpers:log_checkpoint("thorns_tank", 5.0, "[Druid][Buffs] Thorns on tank")
                return true
            end
        end
    end

    -- Omen of Clarity (talent) refresh
    if helpers:is_spell_learned("buffs_utility", "omen_of_clarity") then
        if not helpers:has_buff(player, "omen_of_clarity") then
            if helpers:try_cast("buffs_utility", "omen_of_clarity", player) then
                helpers:log_checkpoint("ooc_buff", 5.0, "[Druid][Buffs] Omen of Clarity refreshed")
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- OOC HEALING (heal to full between pulls)
-- ============================================================================

--- Heal self between pulls when not at full HP
--- @param player game_object
--- @param helpers table
--- @return boolean
function common.try_ooc_healing(player, helpers)
    if not player then return false end
    if helpers:is_in_combat(player) then return false end

    local hp = helpers:get_player_hp(player)
    if hp >= 90 then return false end

    local level = helpers:get_player_level(player)

    -- Need to be in caster form to heal
    if not helpers:is_in_caster_form(player) then
        if helpers:ensure_form(player, "caster") then
            return true
        end
        return false
    end

    -- Rejuvenation (if not already up)
    if level >= 4 and hp < 85 then
        if not helpers:has_buff(player, "rejuvenation") then
            if helpers:try_cast("restoration", "rejuvenation", player) then
                return true
            end
        end
    end

    -- Regrowth (if not already up and HP is lower)
    if level >= 12 and hp < 70 then
        if not helpers:has_buff(player, "regrowth") then
            if helpers:try_cast("restoration", "regrowth", player) then
                return true
            end
        end
    end

    -- Healing Touch for big heal
    if hp < 60 then
        if helpers:try_cast("restoration", "healing_touch", player) then
            return true
        end
    end

    return false
end

-- ============================================================================
-- FAERIE FIRE MAINTENANCE (shared across cat, bear, balance)
-- ============================================================================

--- Apply Faerie Fire (or Feral) on target if not already debuffed
--- @param player game_object
--- @param target game_object
--- @param helpers table
--- @param is_feral boolean True if in cat/bear form (use Feral version)
--- @return boolean
function common.try_faerie_fire(player, target, helpers, is_feral)
    if not player or not target then return false end

    -- Check if FF is already on target (either version)
    if helpers:has_debuff(target, "faerie_fire") then return false end
    if helpers:has_debuff(target, "faerie_fire_feral") then return false end

    if is_feral then
        -- Faerie Fire (Feral) - no cost, usable in cat/bear form
        local ff_enabled_key = helpers:is_in_cat_form(player) and "cat_use_faerie_fire" or "bear_use_faerie_fire"
        if not helpers:get_menu_state(ff_enabled_key) then return false end

        if helpers:is_spell_learned("cat", "faerie_fire_feral") then
            if helpers:is_cooldown_ready("cat", "faerie_fire_feral") then
                if helpers:try_cast("cat", "faerie_fire_feral", target) then
                    helpers:log_checkpoint("ff_feral", 2.0, "[Druid][FF] Faerie Fire (Feral) applied")
                    return true
                end
            end
        end
    else
        -- Faerie Fire (caster) - Balance spec
        if not helpers:get_menu_state("balance_use_faerie_fire") then return false end

        if helpers:is_spell_learned("balance", "faerie_fire") then
            if helpers:is_cooldown_ready("balance", "faerie_fire") then
                if helpers:try_cast("balance", "faerie_fire", target) then
                    helpers:log_checkpoint("ff_caster", 2.0, "[Druid][FF] Faerie Fire applied")
                    return true
                end
            end
        end
    end

    return false
end

-- ============================================================================
-- INNERVATE (shared utility)
-- ============================================================================

--- Try to cast Innervate on self when mana is low
--- @param player game_object
--- @param helpers table
--- @return boolean
function common.try_innervate(player, helpers)
    if not player then return false end

    local level = helpers:get_player_level(player)
    if level < 40 then return false end

    if not helpers:is_spell_learned("buffs_utility", "innervate") then return false end
    if not helpers:is_cooldown_ready("buffs_utility", "innervate") then return false end

    -- Check if Innervate is enabled for this spec
    local spec = helpers:get_spec()
    local mana_threshold = 30

    if spec == 1 then -- Resto
        if not helpers:get_menu_state("resto_use_innervate") then return false end
        mana_threshold = helpers:get_menu_value("resto_innervate_mana", 30)
    elseif spec == 4 then -- Balance
        mana_threshold = 30
    else
        -- Cat/Bear: only use innervate if in caster form and mana is low
        -- (rare, but useful for powershifting mana recovery)
        mana_threshold = 15
    end

    local mana_pct = helpers:get_mana_pct(player)
    if mana_pct >= mana_threshold then return false end

    -- Innervate is usable in any form
    if helpers:try_cast("buffs_utility", "innervate", player) then
        helpers:log_checkpoint("innervate", 10.0, "[Druid][Mana] Innervate at mana=" .. math.floor(mana_pct) .. "%")
        return true
    end

    return false
end

-- ============================================================================
-- DOT APPLICATION WITH GUARD
-- ============================================================================

--- Apply a DoT spell with double-cast prevention
--- @param target game_object
--- @param category string Spell data category
--- @param spell_key string Spell key
--- @param debuff_key string Key in spell_data.debuff_ids
--- @param helpers table
--- @param duration_ms number DoT duration in ms for guard
--- @return boolean
function common.try_apply_dot(target, category, spell_key, debuff_key, helpers, duration_ms)
    if not target then return false end

    -- Already on target
    if helpers:has_debuff(target, debuff_key) then return false end

    -- DoT apply guard (prevents double-cast within short window)
    local spell_entry = helpers:get_spell_entry(category, spell_key)
    if spell_entry and spell_entry.ids then
        local guard_id = spell_entry.ids[1]
        if guard_id then
            local ok, blocked = pcall(function()
                return dot_apply_guard.should_block(target, guard_id)
            end)
            if ok and blocked then return false end
        end
    end

    if helpers:try_cast(category, spell_key, target) then
        -- Register with guard
        if spell_entry and spell_entry.ids then
            local guard_id = spell_entry.ids[1]
            if guard_id then
                pcall(function()
                    dot_apply_guard.on_cast_requested(target, guard_id, duration_ms or 12000)
                end)
            end
        end
        return true
    end

    return false
end

return common
