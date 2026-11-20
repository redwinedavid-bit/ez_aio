local __object_safety=require("shared/object_safety")
-- Swing Timer (Shared)

---@type color
local color = require("common/color")

---@type enums
local enums = require("common/enums")

---@type vec2
local vec2 = require("common/geometry/vector_2")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type izi_sdk|nil
local izi = nil
do
    local ok, mod = pcall(require, "common/izi_sdk")
    if ok then
        izi = mod
    end
end

local function menu_slider_int(min_value, max_value, default_value, id)
    if core.menu.slider_int then
        return core.menu.slider_int(min_value, max_value, default_value, id)
    end
    if core.menu.slider then
        local slider = core.menu.slider(min_value, max_value, default_value, id)
        if slider and slider.as_int then
            return slider:as_int()
        end
        return slider
    end
    if core.menu.new_slider then
        local slider = core.menu.new_slider(min_value, max_value, default_value, id)
        if slider and slider.as_int then
            return slider:as_int()
        end
        return slider
    end
    return nil
end

local function menu_color_picker(default_color, id)
    if core.menu.color_picker then
        return core.menu.color_picker(default_color, id)
    end
    if core.menu.colorpicker then
        return core.menu.colorpicker(default_color, id)
    end
    if core.menu.new_colorpicker then
        return core.menu.new_colorpicker(default_color, id)
    end
    return nil
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function format_ms(ms)
    if not ms or ms <= 0 then
        return "0.00s"
    end
    return string.format("%.2fs", ms / 1000)
end

local function format_num(x)
    if x == nil then
        return "nil"
    end
    if type(x) ~= "number" then
        return tostring(x)
    end
    return string.format("%.0f", x)
end

local function list_to_set(list)
    if not list then
        return nil
    end
    local set = {}
    for _, id in ipairs(list) do
        if type(id) == "number" then
            set[id] = true
        end
    end
    return set
end

local function calculate_median(samples)
    if not samples or #samples == 0 then
        return nil
    end

    -- Create a copy and sort
    local sorted = {}
    for i, v in ipairs(samples) do
        sorted[i] = v
    end
    table.sort(sorted)

    local count = #sorted
    if count % 2 == 0 then
        -- Even number: average of middle two
        local mid1 = sorted[count / 2]
        local mid2 = sorted[(count / 2) + 1]
        return (mid1 + mid2) / 2
    else
        -- Odd number: middle value
        return sorted[math.ceil(count / 2)]
    end
end

local function get_attack_ids_for_mode(mode)
    local atk = auto_attack_helper and auto_attack_helper.ATTACK_TYPE or nil
    local melee = atk and atk.MELEE or 6603
    local ranged = atk and atk.RANGED or 75
    local wand = atk and atk.WAND or 5019

    if mode == "melee" then
        return { melee }
    elseif mode == "ranged" then
        return { ranged }
    elseif mode == "wand" then
        return { wand }
    end
    return { melee, ranged, wand }
end

local RESET_SPELL_IDS = {
    -- These IDs are taken from WeaponSwingTimer's active (uncommented) reset tables
    -- plus Hunter-specific ranged reset behavior (Aimed Shot / Feign Death).
    hunter = {
        ranged = {
            5384, -- Feign Death
            2643, 14288, 14289, 14290, 25294, 27021, -- Multi-Shot ranks
            19434, 20900, 20901, 20902, 20903, 20904, 27065 -- Aimed Shot ranks
        },
        melee = {
            2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266, 27014, 48995, 48996 -- Raptor Strike ranks
        }
    },
    warrior = {
        melee = {
            845, 7369, 11608, 11609, 20569, 25231, 47519, 47520, -- Cleave ranks
            78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286, 29707, 30324, 47450, 47449, -- Heroic Strike ranks
            57755 -- Heroic Throw
        }
    },
    druid = {
        melee = { 6807, 6808, 6809, 8972, 9745, 9880, 9881, 26996, 48479, 48480 } -- Maul ranks
    },
    paladin = {
        melee = {
            879, 5614, 5615, 10312, 10313, 10314, 27138, 48800, -- Exorcism ranks
            635, 639, 647, 1026, 1042, 3472, 10328, 10329, 25292, 27135, 27136, 48781 -- Holy Light ranks
        }
    },
    deathknight = {
        melee = { 56815 } -- Rune Strike
    }
}

local CLASS_ID_TO_KEY = {
    [1] = "warrior",
    [2] = "paladin",
    [3] = "hunter",
    [4] = "rogue",
    [5] = "priest",
    [6] = "deathknight",
    [7] = "shaman",
    [8] = "mage",
    [9] = "warlock",
    [11] = "druid"
}

-- WoW Classic Era attack speed modifiers (haste buffs + slow debuffs).
-- Goal: compute an EFFECTIVE swing duration for the current swing, while persisting only BASE (unmodified) speed.
-- Note: Quiver/Ammo Pouch is intentionally NOT treated as a temporary modifier (it's long-term "gear baseline").
-- COMPLETE VERSION: Extracted from spell database 1.15.8.64907 (601 unique attack speed auras identified)
-- Includes ALL diseases, curses, buffs, and debuffs affecting attack speed for Era; plus a small TBC addendum.
local ATTACK_SPEED_AURAS = {
    buffs = {
        -- Hunter (ranged)
        rapid_fire = {
            ids = { 3045 },
            pct = 0.40,
            affects = { melee = false, ranged = true, wand = false }
        },
        quick_shots = {
            ids = { 6150 },
            pct = 0.30,
            affects = { melee = false, ranged = true, wand = false }
        },
        improved_aspect_of_the_hawk = {
            ids = { 19552, 19553, 19554, 19555, 19556 },
            pct = 0.15,
            affects = { melee = false, ranged = true, wand = false }
        },

        -- Troll racial (all ranks)
        berserking = {
            ids = { 20554, 26296, 26297, 27554 },
            pct = "dynamic",  -- 10-30% based on missing HP
            affects = { melee = true, ranged = true, wand = true }
        },

        -- Consumables / trinkets
        kiss_of_the_spider = {
            ids = { 28866 },
            pct = 0.20,
            affects = { melee = true, ranged = true, wand = false }
        },
        juju_flurry = {
            ids = { 16322 },
            pct = 0.03,
            affects = { melee = true, ranged = true, wand = false }
        },
        haste_50 = {
            ids = { 13494 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        battle_squawk = {
            ids = { 23060 },
            pct = 0.05,
            affects = { melee = true, ranged = false, wand = false }
        },
        manual_crowd_pummeler = {
            ids = { 13494 },
            pct = 0.50,
            affects = { melee = true, ranged = false, wand = false }
        },
        eskhandars_rage = {
            ids = { 22640 },
            pct = 0.30,
            affects = { melee = true, ranged = false, wand = false }
        },
        mongoose_fury = {
            ids = { 28093 },
            pct = 0.02,
            affects = { melee = true, ranged = false, wand = false }
        },
        zandalarian_hero_charm = {
            ids = { 24658 },
            pct = 0.05,
            affects = { melee = true, ranged = false, wand = false }
        },
        slayers_crest = {
            ids = { 28777 },
            pct = 0.02,
            affects = { melee = true, ranged = false, wand = false }
        },
        bloodlust = {
            ids = { 2825 },
            pct = 0.30,
            affects = { melee = true, ranged = true, wand = true }
        },
        heroism = {
            ids = { 32182 },
            pct = 0.30,
            affects = { melee = true, ranged = true, wand = true }
        },

        -- Rogue abilities
        blade_flurry = {
            ids = { 13877 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },
        slice_and_dice = {
            ids = { 5171, 6774 },
            pct = "dynamic",  -- 20-30% based on combo points
            affects = { melee = true, ranged = false, wand = false }
        },
        adrenaline_rush = {
            ids = { 13750 },
            pct = 1.00,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Shaman abilities
        flurry = {
            ids = { 12319, 12971, 12972, 12973, 12974, 16256, 16277, 12970, 16280 },
            pct = "dynamic",  -- 10-30% based on talent rank
            affects = { melee = true, ranged = false, wand = false }
        },
        windfury_totem = {
            ids = { 8515, 10607, 10608, 25580, 25582 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },
        grace_of_air_totem = {
            ids = { 8836, 10626, 25359 },
            pct = 0.15,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Paladin abilities
        seal_of_the_crusader = {
            ids = { 21082, 20162, 20305, 20306, 20307, 20308 },
            pct = 0.40,
            affects = { melee = true, ranged = false, wand = false }
        },
        judgment_of_the_crusader = {
            ids = { 20271 },
            pct = 0.15,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Warrior abilities
        blood_fury = {
            ids = { 20572, 33697, 33702 },
            pct = 0.25,
            affects = { melee = true, ranged = false, wand = false }
        },
        recklessness = {
            ids = { 1719 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Druid abilities
        predatory_strikes = {
            ids = { 16972, 16974, 16975 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- World buffs
        warchiefs_blessing = {
            ids = { 16609, 473441 },
            pct = 0.15,
            affects = { melee = true, ranged = false, wand = false }
        },
        bloodlust_npc = {
            ids = { 6742, 16170 },
            pct = "dynamic",
            affects = { melee = true, ranged = false, wand = false }
        },
        rallying_cry_of_the_dragonslayer = {
            ids = { 22888 },
            pct = 0.10,
            affects = { melee = true, ranged = false, wand = false }
        },
        spirit_of_zandalar = {
            ids = { 24425 },
            pct = 0.15,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Boss/encounter specific
        chromatic_mutation = {
            ids = { 23174, 23175 },
            pct = 0.50,
            affects = { melee = true, ranged = false, wand = false }
        },
        frenzy_bwl = {
            ids = { 23128, 23537, 23538, 23539 },
            pct = 0.50,
            affects = { melee = true, ranged = false, wand = false }
        },
        cursed_blade_sod = {
            ids = { 462228 },
            pct = 0.05,
            affects = { melee = true, ranged = false, wand = false }
        }
    },
    debuffs = {
        -- Warrior abilities
        thunder_clap = {
            ids = { 6343, 8198, 8204, 8205, 11580, 11581, 461810, 461826, 461827, 461828, 461829, 461830 },
            pct = "dynamic",  -- 10-20% based on rank
            affects = { melee = true, ranged = true, wand = false }
        },
        hamstring = {
            ids = { 1715, 7372, 7373, 25212 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Weapon procs
        thunderfury = {
            ids = { 21992 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Mage spells
        chilled = {
            ids = { 16927 },
            pct = 0.25,
            affects = { melee = true, ranged = false, wand = false }
        },
        slow = {
            ids = { 246, 6146 },
            pct = 0.60,
            affects = { melee = true, ranged = true, wand = false }
        },
        frostbolt_slow = {
            ids = { 116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181, 25304, 27071, 27072, 38697 },
            pct = 0.40,
            affects = { melee = true, ranged = true, wand = false }
        },
        cone_of_cold = {
            ids = { 120, 8492, 10159, 10160, 10161, 27087 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        frost_armor_slow = {
            ids = { 168, 7300, 7301, 7302, 7320, 10219, 10220, 27088 },
            pct = 0.25,
            affects = { melee = true, ranged = false, wand = false }
        },
        ice_armor_slow = {
            ids = { 7302, 7320, 10219, 10220 },
            pct = 0.25,
            affects = { melee = true, ranged = false, wand = false }
        },
        frost_nova = {
            ids = { 122, 865, 6131, 10230, 27088 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Hunter abilities
        concussive_shot = {
            ids = { 5116, 14260, 14261, 14262, 14263, 14264, 14265, 14266, 27065 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        wing_clip = {
            ids = { 2974, 14267, 14268 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        scorpid_sting = {
            ids = { 3043, 14275, 14276, 14277 },
            pct = 0.20,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Druid abilities
        infected_wounds = {
            ids = { 48483, 48484 },
            pct = 0.20,
            affects = { melee = true, ranged = false, wand = false }
        },
        demoralizing_roar = {
            ids = { 99, 1735, 9490, 9747, 9898, 26998 },
            pct = 0.25,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- NPC/Boss curses
        cursed_blade = {
            ids = { 5271 },
            pct = 0.44,
            affects = { melee = true, ranged = false, wand = false }
        },
        curse_of_tutenkash = {
            ids = { 12255 },
            pct = 0.19,
            affects = { melee = true, ranged = false, wand = false }
        },
        curse_of_shahram = {
            ids = { 16597 },
            pct = 0.26,
            affects = { melee = true, ranged = false, wand = false }
        },
        curse_of_vengeance = {
            ids = { 17213 },
            pct = 0.26,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Disease effects
        diseased_slime = {
            ids = { 6907 },
            pct = 0.55,
            affects = { melee = true, ranged = false, wand = false }
        },

        -- Priest abilities
        mind_flay = {
            ids = { 15407, 17311, 17312, 17313, 17314, 18807, 25387 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Shaman abilities
        frost_shock = {
            ids = { 8056, 8058, 10472, 10473, 25464 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        earthbind_totem = {
            ids = { 2484, 3600 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Generic slowing effects
        cripple = {
            ids = { 89 },
            pct = 0.75,
            affects = { melee = true, ranged = true, wand = false }
        },
        dazed = {
            ids = { 1604 },
            pct = 0.40,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Poison effects
        mind_numbing_poison = {
            ids = { 5760, 8692, 11398, 25810 },
            pct = 0.20,
            affects = { melee = false, ranged = false, wand = false }
        },
        crippling_poison = {
            ids = { 3408, 3409, 11201 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },

        -- Boss abilities
        ancient_despair = {
            ids = { 24664 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        },
        curse_of_the_deadwood = {
            ids = { 21516 },
            pct = 0.50,
            affects = { melee = true, ranged = true, wand = false }
        }
    }
}

local function aura_affects_mode(entry, attack_mode)
    if not entry or not entry.affects then
        return true
    end
    if attack_mode == "any" then
        return true
    end
    return entry.affects[attack_mode] == true
end

local function normalize_pct_value(v)
    if not v or type(v) ~= "number" then
        return nil
    end
    if v > 1.0 then
        return v / 100.0
    end
    return v
end

local function same_unit(a, b)
    if not a or not b then
        return false
    end
    if (__object_safety.same(a,b)) then
        return true
    end
    local ok_a, guid_a = pcall(function()
        return a:get_guid()
    end)
    local ok_b, guid_b = pcall(function()
        return b:get_guid()
    end)
    return ok_a and ok_b and guid_a and guid_b and guid_a == guid_b
end

local function normalize_attack_times(last_swing, next_swing, now_ms)
    local now_game = now_ms
    local now_sec = core.time()
    local uses_seconds = false

    if next_swing and now_game and next_swing > 0 then
        if next_swing < 10000 and now_game > 10000 then
            uses_seconds = true
        end
    elseif last_swing and now_game and last_swing > 0 then
        if last_swing < 10000 and now_game > 10000 then
            uses_seconds = true
        end
    end

    if uses_seconds then
        if last_swing then
            last_swing = last_swing * 1000
        end
        if next_swing then
            next_swing = next_swing * 1000
        end
        now_game = now_sec * 1000
    end

    return last_swing, next_swing, now_game, uses_seconds
end

local function safe_get_attack_speed_ms(unit)
    if not unit or not unit.get_attack_speed then
        return nil
    end

    local ok, speed = pcall(function()
        return unit:get_attack_speed()
    end)
    if not ok or not speed or speed <= 0 then
        return nil
    end

    local ms = speed * 1000
    -- In Project Sylvanas, `get_attack_speed()` can return non-ranged values (or bogus values like ~30s)
    -- depending on context. Filter obviously invalid speeds to avoid a long "warmup" bar.
    if ms > 8000 then
        return nil
    end

    return ms
end

local function safe_get_item_id_at_slot(unit, slot_id)
    if not unit or not unit.get_item_at_inventory_slot then
        return nil
    end

    local ok_slot, slot_info = pcall(function()
        return unit:get_item_at_inventory_slot(slot_id)
    end)
    if not ok_slot or not slot_info or not slot_info.object then
        return nil
    end

    local ok_id, item_id = pcall(function()
        return slot_info.object:get_item_id()
    end)
    if ok_id and item_id and item_id > 0 then
        return item_id
    end
    return nil
end

-- Phase 3: Extract base weapon speed from tooltip (test for Project Sylvanas compatibility)
-- Pattern from WeaponSwingTimer_ranged_base_speed.lua
-- Returns base speed in milliseconds, or nil if extraction fails
local function extract_base_weapon_speed(unit, slot_id)
    -- Test if Project Sylvanas supports tooltip/frame API
    local ok_frame, frame_func = pcall(function()
        return CreateFrame
    end)

    if not ok_frame or not frame_func then
        return nil  -- Tooltip API not available in Project Sylvanas
    end

    -- Try to get weapon item ID
    local weapon_id = safe_get_item_id_at_slot(unit, slot_id)
    if not weapon_id or weapon_id == 0 then
        return nil
    end

    -- Attempt tooltip parsing (may fail if WoW API not fully available)
    local ok_parse, base_speed = pcall(function()
        -- Create temporary tooltip frame
        local tooltip = CreateFrame("GameTooltip", "SwingTimerTooltip" .. weapon_id, nil, "GameTooltipTemplate")
        if not tooltip or not tooltip.SetItemByID then
            return nil
        end

        tooltip:SetOwner(UIParent or WorldFrame, "ANCHOR_NONE")
        tooltip:SetItemByID(weapon_id)

        -- Search for "Speed X.XX" pattern in tooltip lines
        local num_lines = tooltip.NumLines and tooltip:NumLines() or 0
        for i = 1, num_lines do
            local line_right = _G["SwingTimerTooltip" .. weapon_id .. "TextRight" .. i]
            if line_right then
                local text = line_right:GetText()
                if text then
                    -- Match speed pattern: "Speed" or "SPEED" followed by number
                    local speed_match = text:match("(%d+%.%d+)")
                    if speed_match then
                        return tonumber(speed_match) * 1000  -- Convert seconds to ms
                    end
                end
            end
        end

        return nil
    end)

    if ok_parse and base_speed and base_speed > 0 then
        return base_speed
    end

    -- Tooltip parsing not supported or failed
    return nil
end

local SwingTimer = {}
SwingTimer.__index = SwingTimer

local registered_instances = {}
local spell_event_registered = false

local function extract_spell_id_and_caster(ev)
    if not ev then
        return nil, nil, nil
    end
    if type(ev) == "number" then
        return ev, nil, nil
    end
    if type(ev) ~= "table" then
        return nil, nil, nil
    end
    local spell_id = ev.spell_id or ev.id or ev.spell or ev.spellId
    local caster = ev.caster or ev.unit or ev.source or ev.src
    local target = ev.target or ev.dst or ev.dest
    return spell_id, caster, target
end

local function instance_interested_in_spell(inst, spell_id)
    if not inst or not spell_id then
        return false
    end
    return (inst._track_spell_ids and inst._track_spell_ids[spell_id])
        or (inst._reset_spell_ids and inst._reset_spell_ids[spell_id])
end

local function handle_spell_event(ev)
    if not ev then
        return
    end

    local spell_id, caster = extract_spell_id_and_caster(ev)
    if not spell_id then
        return
    end

    for _, inst in pairs(registered_instances) do
        if instance_interested_in_spell(inst, spell_id) then
            inst._last_event_spell_id = spell_id
            inst._last_event_time_ms = core.game_time()
            local unit = inst:_unit()
            if caster and unit and not same_unit(caster, unit) then
                goto continue_instance
            end

            if inst._reset_spell_ids and inst._reset_spell_ids[spell_id] then
                inst._last_reset_spell_id = spell_id
                inst._last_reset_time_ms = inst._last_event_time_ms
                local ignore = inst.reset_ignore_samples_ms
                inst:reset(ignore)
                goto continue_instance
            end

            inst:_record_swing(core.game_time())
        end
        ::continue_instance::
    end
end

local function register_spell_events()
    if spell_event_registered then
        return
    end
    spell_event_registered = true

    if izi and izi.on_spell_success then
        izi.on_spell_success(function(ev)
            handle_spell_event(ev)
        end)
    end

    if core.register_on_spell_cast_callback then
        core.register_on_spell_cast_callback(__object_safety.callback(function(ev)
            handle_spell_event(ev)
        end,"shared/swing_timer.lua:789"))
    end

    if core.register_on_legit_spell_cast_callback then
        core.register_on_legit_spell_cast_callback(__object_safety.callback(function(ev)
            handle_spell_event(ev)
        end,"shared/swing_timer.lua:795"))
    end
end

function SwingTimer:_is_enabled()
    if self.always_enabled then
        if self._parent_enabled_provider and not self._parent_enabled_provider() then
            return false
        end
        return true
    end

    if self.menu and self.menu.enable and not self.menu.enable:get_state() then
        return false
    end
    if self._parent_enabled_provider and not self._parent_enabled_provider() then
        return false
    end
    return true
end

function SwingTimer:_unit()
    if self._unit_provider then
        return self._unit_provider()
    end
    return core.object_manager.get_local_player()
end

function SwingTimer:_record_swing(now_ms)
    if not now_ms or now_ms <= 0 then
        return
    end
    if self._last_swing_ms and now_ms <= self._last_swing_ms then
        return
    end

    self._prev_swing_ms = self._last_swing_ms
    self._last_swing_ms = now_ms
    if self._prev_swing_ms then
        local delta = now_ms - self._prev_swing_ms
        if self._ignore_samples_until_ms and now_ms < self._ignore_samples_until_ms then
            return
        end
        if delta > 50 and delta < 8000 then
            -- Always track observed effective duration (for diagnostics/fallback)
            if not self._observed_duration_ms then
                self._observed_duration_ms = delta
            else
                local alpha = 0.7
                self._observed_duration_ms = (alpha * delta) + ((1 - alpha) * self._observed_duration_ms)
            end

            -- Collect CLEAN samples only (no modifiers active)
            local unit = self:_unit()
            local mods = self:_compute_attack_speed_factors(unit)
            local has_modifiers = mods and mods.active and (#mods.active > 0) or false
            local has_dynamic = mods and mods.has_dynamic or false

            -- Only add to clean samples if no modifiers and not in ignore window
            if not has_modifiers and not has_dynamic then
                -- Initialize clean samples array if needed
                self._clean_samples = self._clean_samples or {}

                -- Add new clean sample
                table.insert(self._clean_samples, delta)
                if #self._clean_samples > (self._clean_samples_max or 5) then
                    table.remove(self._clean_samples, 1)  -- Keep rolling window
                end

                -- CONTINUOUSLY update baseline after EVERY clean swing
                local min_samples = self._min_samples_for_baseline or 2
                if #self._clean_samples >= min_samples then
                    local median = calculate_median(self._clean_samples)

                    if median then
                        local baseline = self:_get_baseline_ms()
                        if not baseline then
                            -- Initial baseline from clean samples
                            self:_set_baseline_ms(median)
                        else
                            -- ALWAYS update baseline if median differs (continuous refinement)
                            local diff = math.abs(median - baseline)
                            if diff >= 30 then  -- 30ms threshold to avoid jitter
                                self:_set_baseline_ms(median)
                            end
                        end
                    end
                end
            end
        end
    end
end

function SwingTimer:reset(ignore_samples_ms)
    local now = core.game_time()
    self._ignore_samples_until_ms = now + (ignore_samples_ms or 1200)
    self._last_swing_ms = now
    self._prev_swing_ms = nil
end

function SwingTimer:_get_baseline_ms()
    if not self._baseline_ms then
        return nil
    end
    local v = self._baseline_ms:get()
    if not v or v <= 0 then
        return nil
    end
    return v
end

function SwingTimer:_set_baseline_ms(value)
    if not self._baseline_ms or not value or value <= 0 then
        return
    end
    value = math.floor(value + 0.5)
    if value < 50 then
        return
    end
    if value > 8000 then
        return
    end
    self._baseline_ms:set(value)
end

function SwingTimer:_get_weapon_signature(unit)
    if self.attack_mode == "ranged" or self.attack_mode == "wand" then
        return { safe_get_item_id_at_slot(unit, 18) or 0 }
    end
    if self.attack_mode == "melee" then
        return { safe_get_item_id_at_slot(unit, 16) or 0, safe_get_item_id_at_slot(unit, 17) or 0 }
    end
    return {
        safe_get_item_id_at_slot(unit, 16) or 0,
        safe_get_item_id_at_slot(unit, 17) or 0,
        safe_get_item_id_at_slot(unit, 18) or 0
    }
end

function SwingTimer:_sync_weapon_signature(unit)
    if not self._sig_a then
        return false
    end
    local sig = self:_get_weapon_signature(unit)
    local a = sig[1] or 0
    local b = sig[2] or 0
    local c = sig[3] or 0

    local old_a = self._sig_a:get() or 0
    local old_b = self._sig_b and (self._sig_b:get() or 0) or 0
    local old_c = self._sig_c and (self._sig_c:get() or 0) or 0

    local changed = (a ~= old_a) or (b ~= old_b) or (c ~= old_c)
    if changed then
        self._sig_a:set(a)
        if self._sig_b then
            self._sig_b:set(b)
        end
        if self._sig_c then
            self._sig_c:set(c)
        end

        self._observed_samples = {}
        self._observed_duration_ms = nil
        self._last_swing_ms = nil
        self._prev_swing_ms = nil
        if self._baseline_ms then
            self._baseline_ms:set(0)
        end
        self._observed_base_ms = nil
        self._effective_duration_ms = nil
        self._last_speed_factor = nil
        self._last_effective_duration_ms = nil
        self._clean_samples = {}  -- Reset clean samples on weapon change

        if self.menu and self.menu.debug and self.menu.debug:get_state() then
            core.log(string.format("[SwingTimer:%s] Weapon change detected -> relearning base speed", self.id))
        end
    end

    return changed
end

-- Collect active attack speed modifiers and compute a combined speed factor.
-- `speed_factor` > 1 means faster attacks (shorter interval).
-- `interval_multiplier` is the inverse (multiply BASE interval by this to get effective interval).
function SwingTimer:_compute_attack_speed_factors(unit)
    if not unit or not unit.buff_up or not unit.debuff_up then
        return { speed_factor = 1.0, interval_multiplier = 1.0, active = {} }
    end

    local active = {}
    local haste_factor = 1.0
    local slow_factor = 1.0
    local has_dynamic = false
    local aura_db = self._attack_speed_auras or ATTACK_SPEED_AURAS

    for aura_name, entry in pairs(aura_db.buffs or {}) do
        if aura_affects_mode(entry, self.attack_mode) then
            for _, aura_id in ipairs(entry.ids or {}) do
                local ok_up, is_up = pcall(function()
                    return unit:buff_up(aura_id)
                end)
                if ok_up and is_up then
                    local ok_rem, rem_ms = pcall(function()
                        return unit:buff_remains_ms(aura_id)
                    end)
                    local pct = entry.pct

                    -- Handle dynamic modifiers (percentage varies based on game state)
                    if pct == "dynamic" then
                        has_dynamic = true
                        local extracted = nil

                        -- Try to extract actual percentage from aura tooltip
                        if unit.get_aura_description_value then
                            local ok_val, v = pcall(function()
                                return unit:get_aura_description_value(aura_id, "buff", true)
                            end)
                            if ok_val then
                                extracted = normalize_pct_value(v)
                            end
                        end

                        -- Fallback for specific known dynamic modifiers
                        if not extracted then
                            if aura_name == "berserking" then
                                -- Troll racial: 10-30% based on missing HP
                                if unit.get_health_percentage then
                                    local ok_hp, hp = pcall(function()
                                        return unit:get_health_percentage()
                                    end)
                                    if ok_hp and hp and hp > 0 then
                                        local missing = 1.0 - (hp / 100.0)
                                        extracted = 0.10 + (missing * 0.20)
                                    end
                                end
                            elseif aura_name == "slice_and_dice" then
                                -- Rogue: 20-30% based on combo points (assume max for safety)
                                extracted = 0.30
                            elseif aura_name == "flurry" then
                                -- Shaman: 10-30% based on talent rank (assume max for safety)
                                extracted = 0.30
                            elseif aura_name == "bloodlust_npc" then
                                -- NPC bloodlust: varies (assume 25% average)
                                extracted = 0.25
                            end
                        end

                        pct = extracted or 0.20  -- Default fallback
                    end

                    pct = (type(pct) == "number") and pct or 0
                    if pct > 0 then
                        haste_factor = haste_factor * (1.0 + pct)
                    end
                    table.insert(active, { name = aura_name, id = aura_id, type = "buff", pct = pct, remaining_ms = (ok_rem and rem_ms) or 0 })
                    break
                end
            end
        end
    end

    for aura_name, entry in pairs(aura_db.debuffs or {}) do
        if aura_affects_mode(entry, self.attack_mode) then
            for _, aura_id in ipairs(entry.ids or {}) do
                local ok_up, is_up = pcall(function()
                    return unit:debuff_up(aura_id)
                end)
                if ok_up and is_up then
                    local ok_rem, rem_ms = pcall(function()
                        return unit:debuff_remains_ms(aura_id)
                    end)
                    local pct = entry.pct

                    -- Handle dynamic debuff modifiers
                    if pct == "dynamic" then
                        has_dynamic = true
                        local extracted = nil

                        -- Try to extract actual percentage from aura tooltip
                        if unit.get_aura_description_value then
                            local ok_val, v = pcall(function()
                                return unit:get_aura_description_value(aura_id, "debuff", false)
                            end)
                            if ok_val then
                                extracted = normalize_pct_value(v)
                            end
                        end

                        -- Fallback for specific known dynamic debuffs
                        if not extracted then
                            if aura_name == "thunder_clap" then
                                -- Warrior: 10-20% based on rank (assume max for safety)
                                extracted = 0.20
                            end
                        end

                        pct = extracted or 0.15  -- Default fallback for debuffs
                    end

                    pct = (type(pct) == "number") and pct or 0
                    if pct > 0 then
                        slow_factor = slow_factor * (1.0 + pct)
                    end
                    table.insert(active, { name = aura_name, id = aura_id, type = "debuff", pct = pct, remaining_ms = (ok_rem and rem_ms) or 0 })
                    break
                end
            end
        end
    end

    local speed_factor = haste_factor / slow_factor
    if speed_factor <= 0 then
        speed_factor = 0.01
    end
    return {
        speed_factor = speed_factor,
        interval_multiplier = 1.0 / speed_factor,
        active = active,
        has_dynamic = has_dynamic
    }
end

function SwingTimer:_detect_modifier_change(mods)
    local active = mods and mods.active or nil
    if not active then
        return false
    end

    local parts = {}
    for _, aura in ipairs(active) do
        table.insert(parts, string.format("%s:%d:%.3f", tostring(aura.type), tonumber(aura.id or 0) or 0, tonumber(aura.pct or 0) or 0))
    end
    table.sort(parts)
    local new_hash = table.concat(parts, "|")

    if new_hash ~= self._last_mod_hash then
        self._last_mod_hash = new_hash
        return true
    end
    return false
end

function SwingTimer:_compute_state(unit)
    if not unit then
        return nil
    end

    local ok_auto, is_auto = pcall(function()
        return auto_attack_helper:is_auto_attacking(unit)
    end)

    local last_swing = nil
    local next_swing = nil
    local ok_last, last_val = pcall(function()
        return auto_attack_helper:get_last_attack_game_time(unit, self.weapon_count)
    end)
    if ok_last then
        last_swing = last_val
    end

    local ok_next, next_val = pcall(function()
        return auto_attack_helper:get_next_attack_game_time(unit, self.weapon_count)
    end)
    if ok_next then
        next_swing = next_val
    end

    local now = core.game_time()
    local uses_seconds = false
    last_swing, next_swing, now, uses_seconds = normalize_attack_times(last_swing, next_swing, now)
    if uses_seconds then
        if self._last_swing_ms and self._last_swing_ms < 10000 then
            self._last_swing_ms = self._last_swing_ms * 1000
        end
        if self._prev_swing_ms and self._prev_swing_ms < 10000 then
            self._prev_swing_ms = self._prev_swing_ms * 1000
        end
    end

    local function is_significant_duration_diff(a, b)
        if not a or not b or a <= 0 or b <= 0 then
            return false
        end
        local ref = math.max(a, b)
        local threshold = math.max(80, ref * 0.08)
        return math.abs(a - b) > threshold
    end

    local duration = nil
    local duration_source = nil
    local helper_last = last_swing
    local helper_next = next_swing

    local helper_duration = nil
    if helper_last and helper_next and helper_next > helper_last then
        helper_duration = helper_next - helper_last
    end

    local effective_duration = self._effective_duration_ms
    local observed_duration = self._observed_duration_ms
    local active_mod_count = self._active_speed_mods and #self._active_speed_mods or 0
    local clean_sample_count = self._clean_samples and #self._clean_samples or 0
    local min_samples = self._min_samples_for_baseline or 2

    local baseline_ms = self:_get_baseline_ms()
    local baseline_trusted = baseline_ms and baseline_ms > 0 and clean_sample_count >= min_samples

    -- Prefer stable/clean baseline + computed effective duration over "observed" samples, because
    -- observed deltas can be polluted by pauses/latency/clipping.
    if baseline_trusted then
        if active_mod_count > 0 and effective_duration and effective_duration > 0 then
            duration = effective_duration
            duration_source = "effective"
        else
            duration = baseline_ms
            duration_source = "baseline"
        end
    end

    if (not duration or duration <= 0) and helper_duration and helper_duration > 0 then
        duration = helper_duration
        duration_source = "helper"
    end

    if (not duration or duration <= 0) and effective_duration and effective_duration > 0 then
        duration = effective_duration
        duration_source = "effective"
    end

    if (not duration or duration <= 0) and observed_duration and observed_duration > 0 then
        duration = observed_duration
        duration_source = "observed"
    end

    if (not duration or duration <= 0) and baseline_ms and baseline_ms > 0 then
        duration = baseline_ms
        duration_source = "baseline"
    end

    if (not duration or duration <= 0) then
        duration = safe_get_attack_speed_ms(unit)
        duration_source = "unit_speed"
    end

    -- Some clients/helpers report base swing interval and ignore haste modifiers.
    -- If we detect a large mismatch, prefer the computed effective interval (when modifiers are active),
    -- otherwise keep baseline (when available).
    if duration and duration > 0 then
        if active_mod_count > 0 and effective_duration and is_significant_duration_diff(duration, effective_duration) then
            duration = effective_duration
            duration_source = "effective"
        elseif baseline_ms and baseline_ms > 0 and is_significant_duration_diff(duration, baseline_ms) and baseline_trusted then
            duration = baseline_ms
            duration_source = "baseline"
        end
    end

    local event_last = self._last_swing_ms
    if event_last and event_last > 0 and (not helper_last or event_last > helper_last) then
        last_swing = event_last
    end

    local helper_next_is_valid = false
    if helper_next and helper_last and helper_next > helper_last then
        helper_next_is_valid = helper_next > (now + 5)
    end

    local can_use_helper_next = helper_next_is_valid and duration_source == "helper"
    if can_use_helper_next then
        next_swing = helper_next
    else
        next_swing = nil
        if last_swing and duration and duration > 0 then
            next_swing = last_swing + duration
        end
    end

    if ok_auto and is_auto == true and (not last_swing or not next_swing) and duration and duration > 0 then
        if not last_swing then
            last_swing = now
            self._last_swing_ms = now
        end
        if not next_swing then
            next_swing = last_swing + duration
        end
    end

    local remaining = nil
    if next_swing then
        remaining = next_swing - now
    end

    if remaining and remaining < 0 then
        remaining = 0
    end

    local progress = 0
    if duration and duration > 0 then
        local elapsed = 0
        if remaining ~= nil then
            elapsed = duration - remaining
        elseif last_swing then
            elapsed = now - last_swing
        elseif self._last_swing_ms then
            elapsed = now - self._last_swing_ms
        end
        progress = clamp(elapsed / duration, 0, 1)
    end

    local event_active = false
    if self._last_swing_ms then
        local idle_window = (duration and duration > 0) and (duration * 2) or 2500
        event_active = (now - self._last_swing_ms) <= idle_window
    end

    local is_auto_attacking = (ok_auto and is_auto == true) or event_active
    if not is_auto_attacking then
        -- Avoid showing a "stuck full" bar when auto-attack is inactive.
        next_swing = nil
        remaining = 0
        progress = 0
    end

    return {
        is_auto_attacking = is_auto_attacking,
        now = now,
        last_swing = last_swing,
        next_swing = next_swing,
        duration = duration,
        duration_source = duration_source,
        remaining_ms = remaining,
        progress = progress,
        phase = "swing"
    }
end

function SwingTimer:_sync_window_state()
    if not self._pos_x or not self._pos_y or not self._size_x or not self._size_y then
        return
    end

    local ok_pos, pos = pcall(function()
        return self.window:get_position()
    end)
    if ok_pos and pos then
        local px = math.floor(pos.x + 0.5)
        local py = math.floor(pos.y + 0.5)
        if px ~= self._last_pos_x then
            self._last_pos_x = px
            self._pos_x:set(px)
        end
        if py ~= self._last_pos_y then
            self._last_pos_y = py
            self._pos_y:set(py)
        end
    end

    local ok_size, size = pcall(function()
        return self.window:get_size()
    end)
    if ok_size and size then
        local sx = math.floor(size.x + 0.5)
        local sy = math.floor(size.y + 0.5)
        if sx ~= self._last_size_x then
            self._last_size_x = sx
            self._size_x:set(sx)
        end
        if sy ~= self._last_size_y then
            self._last_size_y = sy
            self._size_y:set(sy)
        end
    end
end

function SwingTimer:_render_window()
    if not self:_is_enabled() then
        return
    end

    local unit = self:_unit()
    if not unit then
        return
    end

    local state = self:_compute_state(unit)
    if not state then
        return
    end

    if self.menu.only_in_combat and self.menu.only_in_combat:get_state() then
        if not unit:is_in_combat() then
            return
        end
    end

    if self.menu.only_when_auto and self.menu.only_when_auto:get_state() then
        if not state.is_auto_attacking then
            return
        end
    end

    local bg_color = self.window_bg_color
    local border_color = self.window_border_color
    local bar_color = self.menu.bar_color and self.menu.bar_color:get() or color.green(200)
    local bar_bg = self.menu.bar_bg_color and self.menu.bar_bg_color:get() or color.gray(60)
    local text_color = self.menu.text_color and self.menu.text_color:get() or color.white(230)

    self.window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_WIDTH,
        false,
        bg_color,
        border_color,
        enums.window_enums.window_cross_visuals.NO_BACKGROUND_AND_NO_BORDER,
        function()
            self:_sync_window_state()

            local size = self.window:get_size()
            local padding = 8
            local header_height = 0
            local label = self.label

            if self.menu.show_label and self.menu.show_label:get_state() then
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(padding, 4), text_color, label)
                header_height = 12
            end

            local time_text = ""
            if self.menu.show_time and self.menu.show_time:get_state() then
                if not state.is_auto_attacking then
                    time_text = "Idle"
                elseif state.remaining_ms and state.remaining_ms > 0 then
                    time_text = format_ms(state.remaining_ms)
                else
                    time_text = "0.00s"
                end

                local text_size = self.window:get_text_size(time_text)
                local text_x = math.max(padding, size.x - padding - text_size.x)
                self.window:render_text(enums.window_enums.font_id.FONT_SMALL, vec2.new(text_x, 4), text_color, time_text)
            end

            if state.phase == "cast" and state.phase_spell_id then
                self.window:render_text(
                    enums.window_enums.font_id.FONT_SMALL,
                    vec2.new(padding, 4),
                    text_color,
                    string.format("%s (cast %d)", label, state.phase_spell_id)
                )
            end

            local bar_top = padding + header_height
            local bar_height = math.max(8, size.y - bar_top - padding)
            local bar_width = math.max(40, size.x - (padding * 2))

            local bar_start = vec2.new(padding, bar_top)
            local bar_end = vec2.new(padding + bar_width, bar_top + bar_height)
            self.window:render_rect_filled(bar_start, bar_end, bar_bg, 1.0)

            local fill_width = bar_width * (state.progress or 0)
            if fill_width > 0 then
                local fill_end = vec2.new(bar_start.x + fill_width, bar_end.y)
                self.window:render_rect_filled(bar_start, fill_end, bar_color, 1.0)
            end

            self.window:render_rect(bar_start, bar_end, text_color, 1.0, 1.0)
        end
    )
end

function SwingTimer:on_update()
    if not self:_is_enabled() then
        self._state = nil
        return
    end

    local unit = self:_unit()

    local mods = self:_compute_attack_speed_factors(unit)
    self._active_speed_mods = mods and mods.active or {}

    local mods_changed = self:_detect_modifier_change(mods)

    local base_ms = self:_get_baseline_ms()
    local effective_ms = nil
    if base_ms and base_ms > 0 then
        effective_ms = base_ms * (mods and mods.interval_multiplier or 1.0)
    else
        effective_ms = self._observed_duration_ms or safe_get_attack_speed_ms(unit)
    end

    if effective_ms and effective_ms > 0 then
        self._effective_duration_ms = effective_ms
    end

    -- Preserve swing progress when modifiers change (castbar-like behavior).
    if mods_changed and self._last_effective_duration_ms and effective_ms and self._last_effective_duration_ms > 0 then
        local multiplier = effective_ms / self._last_effective_duration_ms
        if self._last_swing_ms and self._last_swing_ms > 0 and multiplier > 0 then
            local now = core.game_time()
            local elapsed = now - self._last_swing_ms
            local adjusted_elapsed = elapsed / multiplier
            self._last_swing_ms = now - adjusted_elapsed
        end
    end
    self._last_effective_duration_ms = effective_ms

    if self._reset_spell_ids_auto and not self._reset_spell_ids then
        local class_id = unit and unit.get_class and unit:get_class() or nil
        local class_key = class_id and CLASS_ID_TO_KEY[class_id] or nil
        if class_key then
            local set = {}

            local function add_ids(list)
                if not list then
                    return
                end
                for _, id in ipairs(list) do
                    if type(id) == "number" then
                        set[id] = true
                    end
                end
            end

            local mode = self.attack_mode
            if RESET_SPELL_IDS[class_key] then
                if mode == "any" then
                    add_ids(RESET_SPELL_IDS[class_key].melee)
                    add_ids(RESET_SPELL_IDS[class_key].ranged)
                    add_ids(RESET_SPELL_IDS[class_key].wand)
                else
                    add_ids(RESET_SPELL_IDS[class_key][mode])
                end
            end

            if self.attack_mode == "melee" or self.attack_mode == "any" then
                add_ids(RESET_SPELL_IDS.warrior.melee)
                add_ids(RESET_SPELL_IDS.druid.melee)
                add_ids(RESET_SPELL_IDS.paladin.melee)
                add_ids(RESET_SPELL_IDS.deathknight.melee)
                add_ids(RESET_SPELL_IDS.hunter.melee)
            end

            if self.attack_mode == "ranged" or self.attack_mode == "any" then
                add_ids(RESET_SPELL_IDS.hunter.ranged)
            end

            self._reset_spell_ids = set
        end
    end

    local now_s = core.time()
    if not self._sig_last_check_s or (now_s - self._sig_last_check_s) >= 0.5 then
        self._sig_last_check_s = now_s
        self:_sync_weapon_signature(unit)
    end

    self._state = self:_compute_state(unit)

    if self.menu and self.menu.debug and self.menu.debug:get_state() then
        if not self._last_debug_log_s or (now_s - self._last_debug_log_s) >= 1.0 then
            self._last_debug_log_s = now_s
            local s = self._state or {}

            local mods_str = "none"
            if self._active_speed_mods and #self._active_speed_mods > 0 then
                local parts = {}
                for _, aura in ipairs(self._active_speed_mods) do
                    local type_prefix = aura.type == "debuff" and "-" or "+"
                    local pct = tonumber(aura.pct or 0) or 0
                    table.insert(parts, string.format("%s%s(%.0f%%,%dms)", type_prefix, tostring(aura.name), pct * 100.0, tonumber(aura.remaining_ms or 0) or 0))
                end
                mods_str = table.concat(parts, ",")
            end

            core.log(string.format(
                "[SwingTimer:%s mode=%s] auto=%s last=%s next=%s dur=%s src=%s base=%s eff=%s obs=%s rem=%s prog=%.2f mods=%s clean_samples=%d event=%s@%s reset=%s@%s",
                tostring(self.id),
                tostring(self.attack_mode),
                tostring(s.is_auto_attacking),
                format_num(s.last_swing),
                format_num(s.next_swing),
                format_num(s.duration),
                tostring(s.duration_source),
                format_num(self:_get_baseline_ms()),
                format_num(self._effective_duration_ms),
                format_num(self._observed_duration_ms),
                format_num(s.remaining_ms),
                tonumber(s.progress or 0) or 0,
                mods_str,
                #(self._clean_samples or {}),  -- NEW: Show clean sample count
                tostring(self._last_event_spell_id),
                format_num(self._last_event_time_ms),
                tostring(self._last_reset_spell_id),
                format_num(self._last_reset_time_ms)
            ))
        end
    end
end

function SwingTimer:get_state()
    return self._state
end

function SwingTimer:on_menu_render()
    if not self.menu then
        return
    end

    self.menu.enable:render("Enable Swing Timer")

    if not self.menu.enable:get_state() then
        return
    end

    if self.menu.only_in_combat then
        self.menu.only_in_combat:render("Only Show In Combat")
    end
    if self.menu.only_when_auto then
        self.menu.only_when_auto:render("Only Show While Auto-Attacking")
    end
    if self.menu.show_label then
        self.menu.show_label:render("Show Label")
    end
    if self.menu.show_time then
        self.menu.show_time:render("Show Time Remaining")
    end
    if self.menu.debug then
        self.menu.debug:render("Debug (logs once/sec)")
    end
    if self.menu.bar_color then
        self.menu.bar_color:render("Bar Color")
    end
    if self.menu.bar_bg_color then
        self.menu.bar_bg_color:render("Bar Background")
    end
    if self.menu.text_color then
        self.menu.text_color:render("Text/Border Color")
    end
end

local swing_timer = {}

---@param opts table|nil
---@return table
function swing_timer.new(opts)
    opts = opts or {}

    local self = setmetatable({}, SwingTimer)
    self.id = opts.id or "swing_timer"
    self.label = opts.label or "Swing Timer"
    self.attack_mode = opts.attack_mode or "any"
    self.enable_window = opts.enable_window ~= false
    self.always_enabled = opts.always_enabled == true
    self.reset_ignore_samples_ms = opts.reset_ignore_samples_ms or 1200
    self.weapon_count = opts.weapon_count
    self.window_bg_color = opts.window_bg_color or color.new(0, 0, 0, 120)
    self.window_border_color = opts.window_border_color or color.new(0, 0, 0, 160)
    self._unit_provider = opts.unit_provider
    self._parent_enabled_provider = opts.parent_enabled_provider
    self._attack_speed_auras = opts.attack_speed_auras or ATTACK_SPEED_AURAS
    local track_list = opts.track_spell_ids or get_attack_ids_for_mode(self.attack_mode)
    self._track_spell_ids = list_to_set(track_list)

    self._reset_spell_ids = list_to_set(opts.reset_spell_ids)
    self._reset_spell_ids_auto = opts.reset_spell_ids == nil

    local menu_prefix = opts.menu_prefix or ("swing_timer_" .. self.id)
    self.menu = {
        enable = core.menu.checkbox(false, menu_prefix .. "_enable"),
        only_in_combat = core.menu.checkbox(false, menu_prefix .. "_only_in_combat"),
        only_when_auto = core.menu.checkbox(true, menu_prefix .. "_only_when_auto"),
        show_label = core.menu.checkbox(true, menu_prefix .. "_show_label"),
        show_time = core.menu.checkbox(true, menu_prefix .. "_show_time"),
        debug = core.menu.checkbox(false, menu_prefix .. "_debug"),
        bar_color = menu_color_picker(color.green(200), menu_prefix .. "_bar_color"),
        bar_bg_color = menu_color_picker(color.gray(60), menu_prefix .. "_bar_bg"),
        text_color = menu_color_picker(color.white(230), menu_prefix .. "_text_color")
    }

    self._pos_x = menu_slider_int(0, 5000, opts.default_x or 600, menu_prefix .. "_pos_x")
    self._pos_y = menu_slider_int(0, 5000, opts.default_y or 520, menu_prefix .. "_pos_y")
    self._size_x = menu_slider_int(120, 600, opts.default_w or 240, menu_prefix .. "_size_x")
    self._size_y = menu_slider_int(30, 200, opts.default_h or 50, menu_prefix .. "_size_y")
    self._baseline_ms = menu_slider_int(0, 8000, 0, menu_prefix .. "_baseline_ms")

    self._sig_a = menu_slider_int(0, 500000, 0, menu_prefix .. "_sig_a")
    if self.attack_mode == "melee" or self.attack_mode == "any" then
        self._sig_b = menu_slider_int(0, 500000, 0, menu_prefix .. "_sig_b")
    end
    if self.attack_mode == "any" then
        self._sig_c = menu_slider_int(0, 500000, 0, menu_prefix .. "_sig_c")
    end

    self._active_speed_mods = {}
    self._last_mod_hash = ""
    self._effective_duration_ms = nil
    self._last_effective_duration_ms = nil
    self._last_swing_ms = nil
    self._prev_swing_ms = nil
    self._observed_duration_ms = nil
    self._observed_base_ms = nil

    -- Clean samples for median-based baseline calculation
    self._clean_samples = {}
    self._clean_samples_max = 5
    self._min_samples_for_baseline = 2

    local window_id = (opts.window_id or self.label) .. "##" .. self.id
    self.window = core.menu.window(window_id)

    if self._pos_x and self._pos_y then
        self.window:set_initial_position(vec2.new(self._pos_x:get(), self._pos_y:get()))
    end
    if self._size_x and self._size_y then
        self.window:set_initial_size(vec2.new(self._size_x:get(), self._size_y:get()))
    end

    if self.enable_window then
        core.register_on_render_window_callback(__object_safety.callback(function()
            self:_render_window()
        end,"shared/swing_timer.lua:1717"))
    end

    registered_instances[self.id] = self
    if self._track_spell_ids or self._reset_spell_ids then
        register_spell_events()
    end

    return self
end

return swing_timer
