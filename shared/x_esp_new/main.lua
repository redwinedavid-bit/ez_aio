local __object_safety=require("shared/object_safety")
local color = require("common/color")
local control_panel_helper = require("common/utility/control_panel_helper")
local vec2 = require("common/geometry/vector_2")
local enums = require("common/enums")
local buff_manager = require("common/modules/buff_manager")
local TabMenu = require("shared/x_esp_new/core/tab_menu")
local Components = require("shared/x_esp_new/core/components")  -- Kept for backwards compatibility
local pvp_module = require("shared/x_esp_new/pvp")
local edit_mode_module = require("shared/x_esp_new/edit_mode")

-- Attempt to load new helper libs if present
local icon_helper = rawget(_G, "icon_helper")
if not icon_helper then
    -- Path 1: Local directory (workspace)
    local ok, mod = pcall(require, "icon_helper")
    if ok then icon_helper = mod end
end
if not icon_helper then
    -- Path 2: Full path with shared prefix (AIO integration)
    local ok, mod = pcall(require, "shared/x_esp_new/icon_helper")
    if ok then icon_helper = mod end
end
if not icon_helper then
    -- Path 3: Explicit workspace prefix
    local ok, mod = pcall(require, "x_esp_new/icon_helper")
    if ok then icon_helper = mod end
end
if not icon_helper then
    -- Path 4: The standard common/utility location
    local ok, mod = pcall(require, "common/utility/icon_helper")
    if ok then 
        icon_helper = mod 
    else
        if core.log then core.log("[ICON] Failed to load icon_helper from 'common/utility/icon_helper': " .. tostring(mod)) end
    end
end

if not icon_helper then
    if core.log then core.log("[ICON] icon_helper loaded: false - Using fallback text (Check paths)") end
else
    if core.log then core.log("[ICON] icon_helper loaded: true") end
end
local assets_helper = rawget(_G, "assets_helper")
if not assets_helper then
    local ok, mod = pcall(require, "assets_helper")
    if ok then assets_helper = mod end
end
if not assets_helper then
    -- Path 2: Full path with shared prefix (AIO integration)
    local ok, mod = pcall(require, "shared/x_esp_new/assets_helper")
    if ok then assets_helper = mod end
end
if not assets_helper then
    local ok, mod = pcall(require, "x_esp_new/assets_helper")
    if ok then assets_helper = mod end
end
if not assets_helper then
    local ok, mod = pcall(require, "common/utility/assets_helper")
    if ok then 
        assets_helper = mod 
    end
end

-- Status Debugs (Only show successful load as requested)
if core and core.log then
    if icon_helper then core.log("[ICON] icon_helper successfully loaded!") end
    if assets_helper then core.log("[ASSETS] assets_helper successfully loaded!") end
end

-- ============================================================================
-- Frame-konsistente Spielerposition (einmal pro Frame gecached)
-- Verhindert leichte Verschiebungen zwischen Pfeilen und Tracelines
-- MUSS am Anfang der Datei stehen, damit alle Funktionen darauf zugreifen können!
-- ============================================================================
local cached_player_pos = nil
local cached_local_player = nil

-- ============================================================================
-- WoW Datei-Test: Versuche Texturen aus WoW zu laden
-- ============================================================================
local wow_texture_test_done = false
local wow_loaded_textures = {}

local function test_wow_file_access()
    if wow_texture_test_done then return end
    wow_texture_test_done = true
    
    -- Test 1: Versuche eine bekannte Datei zu lesen
    local test_paths = {
        -- Interface-Dateien (falls extrahiert)
        "Interface/Icons/INV_Misc_QuestionMark.blp",
        "Interface/Icons/Ability_Creature_Cursed_02.blp",
        "Interface/TargetingFrame/UI-TargetingFrame-Elite.blp",
        -- Addon-Dateien (immer lesbar)
        "_classic_era_/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestMapFrame.xml",
        -- Config-Dateien
        "_classic_era_/WTF/Config.wtf",
        "WTF/Config.wtf",
    }
    
    for _, path in ipairs(test_paths) do
        local size = core.get_file_size(path)
        if size and size > 0 then
            -- Datei gefunden, aber kein Log
        end
    end
    
    -- Test 2: Versuche load_image
    local test_image_paths = {
        "Interface/Icons/INV_Misc_QuestionMark.blp",
        "Interface/Icons/Ability_Creature_Cursed_02.blp",
    }
    
    for _, path in ipairs(test_image_paths) do
        local ok, result = pcall(function()
            return core.graphics.load_image(path)
        end)
        if ok and result then
            wow_loaded_textures[path] = result
        end
    end
    
    -- Test 3: Versuche aus assets-Ordner zu laden
    local ok, result = pcall(function()
        return core.graphics.load_image("assets/test.png")
    end)
    -- Assets-Test ohne Log
end

-- Test beim ersten Render ausführen
local function run_wow_test_once()
    test_wow_file_access()
end
pcall(run_wow_test_once)


-- IZI SDK für automatische Spell-Range-Erkennung (alle Klassen/Specs)
-- Dokumentation: https://docs.project-sylvanas.net/dev/libraries/izi/
---@type izi_api
local izi = nil
pcall(function()
    izi = require("common/izi_sdk")
end)

-- Spell-Helper Modul für Range-Erkennung
-- Dokumentation: https://docs.project-sylvanas.net/dev/libraries/izi/spell
local spell_helper = nil
pcall(function()
    spell_helper = require("common/utility/spell_helper")
end)

-- Klassen-basierte primäre Spells für Range-Check
-- Für Melee-Klassen verwenden wir Taunt oder einen anderen Spell mit bekannter Range
local CLASS_PRIMARY_SPELLS = {
    [1] = 355,      -- Warrior: Taunt (30 yards)
    [2] = 62124,    -- Paladin: Hand of Reckoning (30 yards)
    [3] = 75,       -- Hunter: Auto Shot (40 yards)
    [4] = 1725,     -- Rogue: Distract (30 yards)
    [5] = 589,      -- Priest: Shadow Word Pain (40 yards)
    [6] = 49576,    -- Death Knight: Death Grip (30 yards)
    [7] = 403,      -- Shaman: Lightning Bolt (40 yards)
    [8] = 133,      -- Mage: Fireball (40 yards)
    [9] = 686,      -- Warlock: Shadow Bolt (40 yards)
    [10] = 115546,  -- Monk: Provoke (30 yards)
    [11] = 5176,    -- Druid: Wrath (40 yards)
    [12] = 185123,  -- Demon Hunter: Throw Glaive (30 yards)
    [13] = 190984,  -- Evoker: Disintegrate (25 yards)
}

-- Cache für primären Spell
local cached_spell_id = nil
local cached_class_id = nil

-- Ermittelt den primären Spell für die aktuelle Klasse
local function get_primary_spell_id()
    local local_player = core.object_manager and core.object_manager.get_local_player and core.object_manager.get_local_player()
    if not local_player then return nil end
    
    -- Nutze IZI me() falls verfügbar
    if izi and izi.me then
        local ok, me = pcall(izi.me)
        if ok and me then
            local_player = me
        end
    end
    
    local class_id = nil
    if local_player.get_class then
        local ok, cid = pcall(local_player.get_class, local_player)
        if ok then class_id = cid end
    end
    
    -- Cache nutzen
    if class_id and class_id == cached_class_id and cached_spell_id then
        return cached_spell_id
    end
    
    if class_id then
        cached_class_id = class_id
        cached_spell_id = CLASS_PRIMARY_SPELLS[class_id]
    end
    
    return cached_spell_id
end

-- Prüft ob das Ziel in Spell-Range ist
-- Nutzt IZI Game Object Extensions: target:is_spell_in_range(spell_id)
-- Dokumentation: https://docs.project-sylvanas.net/dev/libraries/izi/object-extensions
local function is_target_in_spell_range(target, fallback_distance, max_range)
    -- VEREINFACHT: Diese Funktion versucht NUR die SDK Spell-Range-Prüfung
    -- Bei nil/Fehler wird nil zurückgegeben und der Aufrufer verwendet den Distanz-Fallback
    if not target then return nil end
    
    local spell_id = get_primary_spell_id()
    
    -- Methode 1: IZI Game Object Extension - target:is_spell_in_range(spell_id)
    if spell_id and target.is_spell_in_range then
        local ok, result = pcall(target.is_spell_in_range, target, spell_id)
        if ok and result ~= nil then
            return result  -- true / false
        end
    end
    
    -- Methode 2: spell_helper:is_spell_in_range(spell_id, caster, target)
    if spell_id and spell_helper and spell_helper.is_spell_in_range then
        local caster = cached_local_player or (core.object_manager and core.object_manager.get_local_player and core.object_manager.get_local_player())
        if caster then
            local ok, result = pcall(spell_helper.is_spell_in_range, spell_helper, spell_id, caster, target)
            if ok and result ~= nil then
                return result  -- true / false
            end
        end
    end
    
    -- WICHTIG: NICHT target.distance() hier verwenden!
    -- Der Aufrufer berechnet die Distanz selbst mit cached_player_pos
    -- Das ist stabiler während der Bewegung
    return nil
end

-- Hilfsfunktion: Berechnet Distanz zwischen zwei Positionen
local function calc_distance(pos1, pos2)
    if not pos1 or not pos2 then return nil end
    local dx = (pos1.x or 0) - (pos2.x or 0)
    local dy = (pos1.y or 0) - (pos2.y or 0)
    local dz = (pos1.z or 0) - (pos2.z or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Hilfsfunktion: Prüft ob Ziel in Range ist (NUR DISTANZ - stabil)
local function is_in_range_check(target, target_pos, max_range)
    if not cached_player_pos or not target_pos then return true end
    
    -- Distanz berechnen
    local target_distance = calc_distance(cached_player_pos, target_pos)
    if not target_distance then return true end
    
    -- Feste 35 Yards Range-Prüfung
    return target_distance <= (max_range or 35.0)
end
local function vec2_new(x, y)
    if vec2 and vec2.new then
        return vec2.new(x, y)
    elseif core and core.vec2 and core.vec2.new then
        return core.vec2.new(x, y)
    else
        return { x = x, y = y }
    end
end

-- Helper: Text mit sauberer Outline (2D-basiert, kein Ghosting)
-- Konvertiert 3D-Position zu 2D und rendert dann 2D-Text mit Outline
local outline_color = color.new(0, 0, 0, 255)

local function draw_text_3d_outlined(text, pos, size, text_color, centered)
    if not core or not core.graphics then return end
    
    -- 3D-Position zu 2D-Bildschirmkoordinaten umwandeln
    local screen_pos = nil
    if core.graphics.w2s then
        local ok, sp = pcall(core.graphics.w2s, pos)
        if ok and sp and sp.x and sp.y then
            screen_pos = sp
        end
    elseif core.graphics.world_to_screen then
        local ok, sp = pcall(core.graphics.world_to_screen, pos)
        if ok and sp and sp.x and sp.y then
            screen_pos = sp
        end
    end
    
    if not screen_pos then
        -- Fallback: Normaler 3D-Text ohne Outline
        if core.graphics.text_3d then
            pcall(core.graphics.text_3d, text, pos, size, text_color, centered)
        end
        return
    end
    
    -- 2D-Text mit Outline rendern (kein Ghosting!)
    if core.graphics.text_2d then
        -- Outline in 4 Richtungen
        pcall(core.graphics.text_2d, text, vec2_new(screen_pos.x - 1, screen_pos.y - 1), size, outline_color, centered)
        pcall(core.graphics.text_2d, text, vec2_new(screen_pos.x + 1, screen_pos.y - 1), size, outline_color, centered)
        pcall(core.graphics.text_2d, text, vec2_new(screen_pos.x - 1, screen_pos.y + 1), size, outline_color, centered)
        pcall(core.graphics.text_2d, text, vec2_new(screen_pos.x + 1, screen_pos.y + 1), size, outline_color, centered)
        -- Haupttext
        pcall(core.graphics.text_2d, text, vec2_new(screen_pos.x, screen_pos.y), size, text_color, centered)
    end
end

local function draw_text_2d_outlined(text, pos, size, text_color, centered)
    if not core or not core.graphics or not core.graphics.text_2d then return end
    -- Outline in 4 Richtungen
    pcall(core.graphics.text_2d, text, vec2_new(pos.x - 1, pos.y - 1), size, outline_color, centered)
    pcall(core.graphics.text_2d, text, vec2_new(pos.x + 1, pos.y - 1), size, outline_color, centered)
    pcall(core.graphics.text_2d, text, vec2_new(pos.x - 1, pos.y + 1), size, outline_color, centered)
    pcall(core.graphics.text_2d, text, vec2_new(pos.x + 1, pos.y + 1), size, outline_color, centered)
    -- Haupttext
    pcall(core.graphics.text_2d, text, pos, size, text_color, centered)
end

-- Prüft ob ein Objekt ein Pet ist (nicht ein echter Spieler!)
-- WICHTIG: is_player_controlled NICHT verwenden, da das auch für echte Spieler true sein kann!
local function is_player_pet(obj)
    if not obj then return false end
    
    -- ZUERST prüfen: Wenn es ein echter Spieler ist (unit_type == 1), ist es KEIN Pet
    if obj.get_unit_type then
        local ok, unit_type = pcall(obj.get_unit_type, obj)
        if ok and unit_type == 1 then
            return false  -- Unit Type 1 = Player = KEIN Pet!
        end
        -- Unit Type 8 = Pet
        if ok and unit_type == 8 then
            return true
        end
    end
    
    -- Methode 1: is_pet() - direkte Pet-Prüfung
    if obj.is_pet then
        local ok, is_pet = pcall(obj.is_pet, obj)
        if ok and is_pet then
            return true
        end
    end
    
    -- Methode 2: get_pet_owner() - Hat einen Besitzer = ist ein Pet
    if obj.get_pet_owner then
        local ok, owner = pcall(obj.get_pet_owner, obj)
        if ok and owner then
            return true
        end
    end
    
    -- Methode 3: get_summoner() - Hat einen Beschwörer = ist ein Pet/Minion
    if obj.get_summoner then
        local ok, summoner = pcall(obj.get_summoner, obj)
        if ok and summoner then
            return true
        end
    end
    
    -- Methode 4: is_summoned()
    if obj.is_summoned then
        local ok, summoned = pcall(obj.is_summoned, obj)
        if ok and summoned then
            return true
        end
    end
    
    return false
end

-- Prüft ob ein Objekt ein Spieler ist (nicht Pet, sondern echter Spieler)
local function is_player_unit(obj)
    if not obj then return false end
    
    -- Prüfe Unit Type: 1 = Player (laut Kommentar in is_player_pet)
    if obj.get_unit_type then
        local ok, unit_type = pcall(obj.get_unit_type, obj)
        if ok and unit_type == 1 then
            -- Zusätzlich prüfen, dass es kein Pet ist (Pets können auch unit_type haben)
            if not is_player_pet(obj) then
                return true
            end
        end
    end
    
    return false
end

local questie = nil
local questie_dump_done = false
local function questie_available()
    if not questie then
        local ok, mod = pcall(require, "common/utility/questie_tracker")
        if ok then
            questie = mod
        end
    end
    if questie and questie.is_hooked then
        local ok, hooked = pcall(questie.is_hooked, questie)
        if ok and hooked then
            return true
        end
    end
    return false
end
local function dump_questie_api()
    if questie_dump_done or not questie_available() then
        return
    end
    -- Questie API wurde untersucht - keine Quest-Geber Funktionen verfügbar
    -- Nur Quest-Ziele (Mobs/Items) werden getrackt
    questie_dump_done = true
end
local function is_quest_object(obj)
    if not obj or not questie_available() then
        return false
    end
    if questie and questie.is_quest_object then
        local ok, res = pcall(questie.is_quest_object, questie, obj)
        if ok and res then
            return true
        end
    end
    return false
end
local function get_quest_ids_for_object(obj)
    if not obj or not questie_available() or not questie or not questie.obj_list then
        return nil
    end
    if not obj.get_guid then
        return nil
    end
    local ok_guid, guid = pcall(obj.get_guid, obj)
    if not ok_guid or not guid then
        return nil
    end
    local entry = questie.obj_list[guid]
    if not entry then
        return nil
    end
    if type(entry) == "number" then
        return { entry }
    elseif type(entry) == "table" then
        return entry
    end
    return nil
end

local herb_keywords = {
    -- Generische Keywords
    "herb", "flower", "lotus", "grass", "kelp", "mushroom", "pilz", "fungus", "kraut", "blume", "pflanze",
    -- Classic / Vanilla
    "peacebloom", "friedensblume", "silverleaf", "silberblatt", "earthroot", "erdwurzel",
    "mageroyal", "maguskönigskraut", "briarthorn", "wilddornrose", "dornrose",
    "stranglekelp", "würgetang", "wuergetang", "bruiseweed", "beulengras",
    "wild steelbloom", "wildstahlblüte", "grave moss", "grabmoos",
    "kingsblood", "königsblut", "liferoot", "lebenswurz",
    "fadeleaf", "blassblatt", "goldthorn", "golddorn",
    "khadgar's whisker", "khadgars schnurrbart", "khadgar",
    "wintersbite", "winterbiss", "firebloom", "feuerblüte",
    "purple lotus", "lila lotus", "arthas' tears", "arthas tränen", "arthas",
    "sungrass", "sonnengras", "blindweed", "blindkraut",
    "ghost mushroom", "geisterpilz", "gromsblood", "gromsblut",
    "golden sansam", "goldener sansam", "dreamfoil", "traumblatt",
    "mountain silversage", "bergsilbersalbei", "plaguebloom", "pestblüte",
    "icecap", "eiskappe", "black lotus", "schwarzer lotus",
    -- TBC / Burning Crusade
    "felweed", "teufelsgras", "dreaming glory", "traumwinde",
    "terocone", "terozapfen", "ragveil", "zornhülle",
    "flame cap", "flammenkappe", "mana thistle", "manadistel",
    "netherbloom", "netherblüte", "nightmare vine", "alptraumranke",
    "ancient lichen", "uralte flechte", "fel lotus", "teufelslotus",
    -- WotLK / Wrath of the Lich King
    "goldclover", "goldklee", "firethorn", "feuerdorn",
    "tiger lily", "tigerlilie", "talandra's rose", "talandras rose",
    "adder's tongue", "natterzunge", "lichbloom", "lichblüte",
    "icethorn", "eisdorn", "frost lotus", "frostlotus",
    "frozen herb", "gefrorenes kraut",
    -- Cataclysm
    "cinderbloom", "aschenblüte", "stormvine", "sturmwinde",
    "azshara's veil", "azsharas schleier", "heartblossom", "herzblüte",
    "twilight jasmine", "schattenjasmin", "whiptail", "peitschenschwanz",
    -- MoP / Mists of Pandaria
    "green tea leaf", "grünes teeblatt", "rain poppy", "regenmohn",
    "silkweed", "seidenkraut", "snow lily", "schneelilie",
    "fool's cap", "narrenkappe", "golden lotus", "goldener lotus",
    "sha-touched herb", "sha-berührtes kraut",
    -- WoD / Warlords of Draenor
    "frostweed", "frostkraut", "fireweed", "feuerkraut",
    "gorgrond flytrap", "gorgrond-fliegenfalle", "starflower", "sternblume",
    "nagrand arrowbloom", "nagrand-pfeilblüte", "talador orchid", "talador-orchidee",
    -- Legion
    "aethril", "äthril", "dreamleaf", "traumblatt",
    "foxflower", "fuchsblume", "fjarnskaggl", "fjarnskaggl",
    "starlight rose", "sternenlichtrose", "felwort", "teufelswurz",
    -- BfA / Battle for Azeroth
    "riverbud", "flussknospe", "star moss", "sternmoos",
    "akunda's bite", "akundas biss", "winter's kiss", "winterkuss",
    "sea stalk", "meeresstiel", "siren's pollen", "sirenenpollen",
    "anchor weed", "ankerkraut",
    -- Shadowlands
    "death blossom", "todesblüte", "rising glory", "steigende pracht",
    "marrowroot", "markwurzel", "vigil's torch", "wachtfackel",
    "widowbloom", "witwenblüte", "nightshade", "nachtschatten",
    -- Dragonflight
    "hochenblume", "hochenblume", "saxifrage", "steinbrech",
    "writhebark", "winderinde", "bubble poppy", "blasenmohn",
    -- TWW / The War Within
    "mycobloom", "mykoblüte", "luredrop", "lockentropfen",
    "blessing blossom", "segensblüte", "orbinid", "orbinid",
    "arathi thistle", "arathi-distel",
    -- Dragonflight Herb-Varianten
    "lustrous", "schimmernd", "schimmernde",
    "decayed", "verfallen", "verfallene", "verwest", "verweste",
    "infurious", "wütend", "wütende",
    -- TWW Herb-Varianten
    "lush", "üppig", "üppige", "üppiges",
    "crystallized", "kristallisiert", "kristallisierte", "kristallisiertes",
    "overgrown", "überwuchert", "überwucherte", "überwuchertes",
    "camouflaged", "getarnt", "getarnte", "getarntes",
    "altered", "verändert", "veränderte", "verändertes",
    "sporefused", "sporenverschmolzen", "sporenverschmolzene"
}
local mining_keywords = {
    -- Generische Keywords
    "ore", "erz", "vein", "vorkommen", "ader", "deposit", "lode", "aufschluss", "depósito", "filón", "seam",
    -- Classic / Vanilla
    "copper", "kupfer", "tin", "zinn", "silver", "silber",
    "iron", "eisen", "gold", "mithril", "truesilver", "echtsilber",
    "thorium", "dark iron", "dunkeleisen",
    "incendicite", "indurium", "lesser bloodstone",
    -- TBC / Burning Crusade
    "fel iron", "teufelseisen", "adamantite", "adamantit",
    "khorium", "nethercite", "eternium",
    -- WotLK / Wrath of the Lich King
    "cobalt", "kobalt", "saronite", "saronit",
    "titanium", "titan",
    -- Cataclysm
    "obsidium", "elementium", "pyrite", "pyrit",
    -- MoP / Mists of Pandaria
    "ghost iron", "geistereisen", "kyparite", "kyparit",
    "trillium", "black trillium", "white trillium",
    -- WoD / Warlords of Draenor
    "true iron", "wahres eisen", "blackrock",
    -- Legion
    "leystone", "leystein", "felslate", "teufelsschiefer",
    "living felslate", "infernal brimstone",
    -- BfA / Battle for Azeroth
    "monelite", "storm silver", "sturmssilber",
    "platinum", "platin", "osmenite",
    -- Shadowlands
    "laestrite", "solenium", "oxxein",
    "phaedrum", "sinvyr", "elethium",
    -- Dragonflight
    "serevite", "serevit", "drakonium",
    "khaz'gorite", "khazgorit",
    -- TWW / The War Within
    "bismuth", "bismut", "wismut", "aqirite", "aqirit",
    "ironclaw", "eisenklaue", "null stone", "nullstein",
    -- TWW Varianten (crystallized, rich, overloaded, etc.)
    "crystallized", "kristallisiert", "kristallisiertes",
    "rich ", "reiches", "reiche ", "reichhaltiges",
    "overloaded", "überladen", "überladenes",
    "camouflaged", "getarnt", "getarntes",
    "webbed", "eingewoben", "eingewobenes"
}
local fishing_keywords = {
    "fishing", "fish", "pool", "pond", "shoal", "school", "bank", "wreck", "debris",
    "schwarm", "fischschwarm", "schwarm fisch", "schwarm von", "schwarm der",
    "strom", "stromung", "strömung", "fanggrube", "angel", "angler", "angelstelle", "angelplatz",
    "fangstelle", "loch", "loch fisch", "lure", "bait"
}
local chest_keywords = {
    "chest", "kiste", "truhe", "crate", "box", "kasten", "coffer", "strongbox", "lockbox", "schatulle",
    "treasure", "schatz", "barrel", "fass", "cask", "trunk", "koffer"
}
local city_prop_keywords = {
    "bank", "banke", "bänke",
    "lagerfeuer", "campfire",
    "heinkleiden", "healing", "heal",
    "kerze", "kerzen", "candle", "candles",
    "lampe", "lamp", "lantern", "laterne",
    "briefkasten", "mailbox",
    "eimer", "bucket",
    "schatzkammer", "treasury", "vault",
    "truhe des sammlers", "collector",
    "angelrute", "fishing rod", "rod",
    "fass",
    "pult", "desk", "pulpit",
    "auditoren", "auditor", "auditorium",
    "tisch", "table", "dinner table",
    "stuhl", "chair", "seat", "bench",
    "crate", "crates", "kiste",
    -- Städte und Orte ausschließen
    "goldhain", "goldshire", "goldenhain",
    "löwenherz", "lionheart", "lion's pride",
    "rüstkammer", "armory", "waffenkammer",
    "stormwind", "sturmwind", "orgrimmar", "ironforge", "eisenschmiede",
    "darnassus", "undercity", "unterstadt", "thunder bluff", "donnerfels",
    -- Gebäude und Strukturen
    "inn", "gasthaus", "tavern", "taverne", "hotel",
    "shop", "laden", "store", "geschäft",
    "house", "haus", "building", "gebäude",
    "tower", "turm", "castle", "burg", "schloss",
    "gate", "tor", "portal", "entrance", "eingang",
    "bridge", "brücke", "fountain", "brunnen",
    -- NPCs und Marker
    "guard", "wache", "vendor", "händler", "trainer",
    "flightmaster", "fluglehrer", "stable", "stall",
    "auction", "auktion", "guild", "gilde"
}
local function classify_gather_node(obj)
    if not obj or not obj.get_name then
        return nil
    end
    local ok_name, name = pcall(obj.get_name, obj)
    if not ok_name or not name then
        return nil
    end
    
    -- Prüfe ob Objekt überhaupt interagierbar ist (filtert die meisten Worldmarker)
    -- Ausnahme: Fishing Pools haben manchmal can_be_used = false
    local can_interact = true
    if obj.can_be_used then
        local ok_use, can_use = pcall(obj.can_be_used, obj)
        if ok_use then
            can_interact = can_use
        end
    end
    
    local lower = string.lower(name)
    
    -- Zuerst City Props ausschließen
    for _, kw in ipairs(city_prop_keywords) do
        if string.find(lower, kw, 1, true) then
            return nil
        end
    end
    
    -- WICHTIG: Fishing Pools ZUERST prüfen (vor Mining/Herbs)
    -- Sonst werden Fischschwärme fälschlicherweise als Ores klassifiziert
    for _, kw in ipairs(fishing_keywords) do
        if string.find(lower, kw, 1, true) then
            return "fishing", name
        end
    end
    
    -- Herbs
    for _, kw in ipairs(herb_keywords) do
        if string.find(lower, kw, 1, true) then
            if can_interact then
                return "herb", name
            end
            return nil
        end
    end
    
    -- Mining - nur wenn interagierbar
    for _, kw in ipairs(mining_keywords) do
        if string.find(lower, kw, 1, true) then
            if can_interact then
                return "mining", name
            end
            return nil
        end
    end
    
    -- Chests - nur wenn interagierbar
    for _, kw in ipairs(chest_keywords) do
        if string.find(lower, kw, 1, true) then
            if can_interact then
                return "chest", name
            end
            return nil
        end
    end
    
    return nil
end
local menu = core and core.menu
if not menu then
    return
end
local ADDON_NAME = "Bungees Ultimate ESP 2.X - Pro Edition"
local TAG = "enemyesp_"

-- Texture-System
local textures = {
    herbs = "herbs.png",
    mining = "mining.png",
    fish = "fish.png",
    chest = "chest.png",
    quest = "quest.png",
    target = "target.png",
}

local raw_textures = {}
local texture_ids = {}

local function init_textures()
    for k, img_file_name in pairs(textures) do
        local path = "bungee/assets/" .. img_file_name
        
        -- Versuche die Textur zu laden, mit Fehlerbehandlung
        local ok, data = pcall(function()
            return core.read_data_file(path)
        end)
        
        if not ok or not data then
            -- Setze explizit nil, um sicherzustellen, dass keine alte Daten verwendet werden
            raw_textures[k] = nil
            texture_ids[k] = nil
        else
            raw_textures[k] = data
        end
    end
end

local function load_textures()
    if not core or not core.graphics then
        return
    end
    if not core.graphics.load_texture then
        return
    end
    
    for k, raw_texture in pairs(raw_textures) do
        if not raw_texture then
            -- Skip wenn raw_texture nil ist
            texture_ids[k] = nil
        else
            local ok, texture_id = pcall(function()
                return core.graphics.load_texture(raw_texture)
            end)
            
            if not ok or not texture_id then
                texture_ids[k] = nil
            else
                texture_ids[k] = texture_id
            end
        end
    end
end

-- Mapping von texture_key zu Wowhead icon Namen
-- Format: lowercase mit underscores, wie auf wowhead.com/icons
-- Original Mappings vom User:
-- herb= inv_misc_herb_11
-- ore=trade_mining
-- chest=inv_misc_chamferchest02
-- target=ability_hunter_markedfordeath
-- questmob=achievement_quests_completed_06
-- fishing=Inv_fishingpole_02
local wowhead_icon_map = {
    -- Gathering / Nodes
    herb = "inv_misc_herb_11",
    herbs = "inv_misc_herb_11",
    mine = "trade_mining",
    ores = "trade_mining",
    ore = "trade_mining",
    mining = "trade_mining",
    chest = "inv_misc_chamferchest02",
    fish = "inv_fishingpole_02",
    fishing = "inv_fishingpole_02",
    
    -- Targets / Objectives
    target = "ability_hunter_markedfordeath",
    quest = "achievement_quests_completed_06",
    questmob = "achievement_quests_completed_06",
}

-- Debug: Einmaliger Log beim ersten Aufruf
local _draw_texture_init_logged = false

local function draw_texture(texture_key, pos, x_size, y_size, tint)
    -- Debug: Einmaliger Log für icon_helper Status
    if not _draw_texture_init_logged then
        _draw_texture_init_logged = true
        if core.log then
            core.log("[ICON] icon_helper loaded: " .. tostring(icon_helper ~= nil))
            if icon_helper then
                core.log("[ICON] icon_helper.draw_icon exists: " .. tostring(icon_helper.draw_icon ~= nil))
            end
        end
    end
    
    -- Prüfe ob texture_key gültig ist
    if not texture_key then
        return false
    end
    
    -- Default tint falls nicht angegeben
    local icon_tint = tint or color.white(255)
    
    -- Versuche zuerst icon_helper (Wowhead Icons)
    if icon_helper and icon_helper.draw_icon then
        -- Verwende Map ODER nimm den Key direkt als Icon-Namen (ermöglicht On-Demand Zeichnen)
        local wowhead_icon = wowhead_icon_map[texture_key] or texture_key
        if wowhead_icon then
            if not _icon_drawn_logged then
                _icon_drawn_logged = {}
            end
            if not _icon_drawn_logged[texture_key] then
                _icon_drawn_logged[texture_key] = true
            end
            
            -- Versuche icon_helper:draw_icon mit 5 Parametern (icon_name, pos, width, height, tint)
            -- Falls das fehlschlägt, versuche ohne tint
            local ok, err = pcall(function()
                icon_helper:draw_icon(wowhead_icon, pos, x_size, y_size, icon_tint)
            end)
            if ok then
                return true
            else
                -- Fallback: Versuche ohne tint Parameter
                local ok2, err2 = pcall(function()
                    icon_helper:draw_icon(wowhead_icon, pos, x_size, y_size)
                end)
                if ok2 then
                    return true
                end
                
                -- Debug: Fehler loggen (einmalig pro Icon-Typ)
                if not _icon_draw_error_logged then
                    _icon_draw_error_logged = {}
                end
                if not _icon_draw_error_logged[texture_key] then
                    _icon_draw_error_logged[texture_key] = true
                    if core.log then
                        core.log("[ICON] draw_icon error for " .. tostring(texture_key) .. ": " .. tostring(err))
                    end
                end
            end
        else
            -- Debug: Einmalig loggen wenn texture_key nicht gemappt ist
            if not _icon_unmapped_logged then
                _icon_unmapped_logged = {}
            end
            if not _icon_unmapped_logged[texture_key] then
                _icon_unmapped_logged[texture_key] = true
                if core.log then
                    core.log("[ICON] Unmapped texture_key: " .. tostring(texture_key))
                end
            end
        end
    end
    
    -- Fallback: alte Methode mit lokalen Texturen
    local texture_id = texture_ids[texture_key]
    if not texture_id then
        return false
    end
    
    if not core or not core.graphics or not core.graphics.draw_texture then
        return false
    end
    
    local ok, result = pcall(function()
        return core.graphics.draw_texture(texture_id, pos, x_size, y_size, tint)
    end)
    
    if not ok then
        texture_ids[texture_key] = nil
        return false
    end
    
    return true
end

-- Texturen initialisieren und laden (mit Fehlerbehandlung)
local function initialize_textures_safely()
    local ok1, err1 = pcall(init_textures)
    if not ok1 then
        core.log("ERROR in init_textures: " .. tostring(err1))
    end
    
    local ok2, err2 = pcall(load_textures)
    if not ok2 then
        core.log("ERROR in load_textures: " .. tostring(err2))
    end
    
    -- Log welche Texturen erfolgreich geladen wurden
    local loaded_count = 0
    local total_count = 0
    for k, v in pairs(texture_ids) do
        total_count = total_count + 1
        if v then
            loaded_count = loaded_count + 1
        end
    end
    -- Zähle auch die erwarteten Texturen
    local expected_count = 0
    for _ in pairs(textures) do
        expected_count = expected_count + 1
    end
    -- Summary removed as requested
end

initialize_textures_safely()

-- Gathering Icons für Tracelines laden
local gathering_icons = {
    mining = nil,
    herb = nil
}

-- Prüfe ob Image-API verfügbar ist
local HAS_IMAGE_API = core.graphics
    and type(core.graphics.load_image) == "function"
    and type(core.graphics.draw_image) == "function"

-- Lade Icons wenn API verfügbar
local function load_gathering_icons()
    if gathering_icons._loaded then
        return  -- Bereits geladen
    end
    gathering_icons._loaded = true
    
    if not HAS_IMAGE_API then
        return
    end
    
    -- Versuche verschiedene Pfade für Mining
    local paths_to_try = {
        "assets/mining.png",
        "x_esp_new/assets/mining.png"
    }
    
    for _, path in ipairs(paths_to_try) do
        local ok, result = pcall(core.graphics.load_image, path)
        if ok and result then
            gathering_icons.mining = result
            break
        end
    end
    
    -- Versuche verschiedene Pfade für Herb
    local herb_paths = {
        "assets/herb.png",
        "x_esp_new/assets/herb.png"
    }
    
    for _, path in ipairs(herb_paths) do
        local ok, result = pcall(core.graphics.load_image, path)
        if ok and result then
            gathering_icons.herb = result
            break
        end
    end
end

-- Radar Settings Popup State
local radar_settings_popup_open = false
local radar_settings_button_hovered = false
local radar_settings_button_was_pressed = false

-- Settings Menu initialisieren (früh, damit Radar-Button darauf zugreifen kann)
local settings_menu = nil
if core and core.menu and TabMenu then
    settings_menu = TabMenu.new({
        id = "enemyesp_settings",
        title = "Bungees ESP PRO",
        default_x = 250,
        default_y = 100,
        default_w = 760,
        default_h = 1000,
        theme = "esp"
    })
end

-- Level Warning Popup Window
local level_warning_window = nil
local level_warning_data = {
    visible = false,
    enemy_name = "",
    enemy_level = 0,
    level_diff = 0,
    distance = 0,
    direction_angle = 0,  -- Winkel in Radiant zum Gegner
    is_critical = false   -- true wenn > +3 Level
}
if core and core.menu then
    level_warning_window = core.menu.window("Level Warning")
    if level_warning_window then
        level_warning_window:set_initial_size(vec2.new(260, 105))
        level_warning_window:set_initial_position(vec2.new(100, 150))
    end
end

-- Behind You Warning Popup Window
local behind_warning_window = nil
local behind_warning_data = {
    visible = false,
    enemy_count = 0,
    closest_enemy_name = "",
    closest_distance = 0,
    direction_angle = 0,  -- Winkel zum nächsten Feind hinter dir
    is_critical = false   -- true wenn mehrere Feinde oder sehr nah
}
if core and core.menu then
    behind_warning_window = core.menu.window("Behind Warning")
    if behind_warning_window then
        behind_warning_window:set_initial_size(vec2.new(240, 95))
        behind_warning_window:set_initial_position(vec2.new(100, 270))
    end
end

-- Patrol Warning System - Erkennt sich bewegende Mobs (Patrouillen)
local patrol_warning_window = nil
local patrol_warning_data = {
    visible = false,
    patrol_count = 0,
    closest_patrol_name = "",
    closest_distance = 0,
    direction_angle = 0,
    is_approaching = false,  -- true wenn Patrouille auf Spieler zukommt
    is_critical = false
}
-- Speichert letzte Positionen von Mobs um Bewegung zu erkennen
local mob_last_positions = {}
local mob_position_update_time = {}
local PATROL_POSITION_HISTORY_FRAMES = 120  -- Frames zwischen Position-Updates (~2 Sekunden bei 60 FPS)
local PATROL_MIN_MOVE_DISTANCE = 2.0  -- Minimum Bewegung um als Patrouille zu gelten

if core and core.menu then
    patrol_warning_window = core.menu.window("Patrol Warning")
    if patrol_warning_window then
        patrol_warning_window:set_initial_size(vec2.new(250, 105))
        patrol_warning_window:set_initial_position(vec2.new(100, 380))
    end
end

local menu_elements = {
    main_tree = nil,
    enabled = nil,
    toggle_key = nil,
    enemy_color = nil,
    stealth_color = nil,
    show_names = nil,
    max_distance = nil,
    show_danger_zones = nil,
    danger_zone_radius = nil,
    danger_zone_scale = nil,
    danger_zone_color = nil,
    danger_zone_alpha = nil,
    show_enemy_circles = nil,
    quest_tree = nil,
    show_quest_mobs = nil,
    show_quest_symbol = nil,
    quest_color = nil,
    quest_item_color = nil,
    targeting_color = nil,
    show_targeting_indicator = nil,
    line_thickness = nil,
    gathering_tree = nil,
    show_herbs = nil,
    show_mining = nil,
    show_chests = nil,
    show_fishing = nil,
    herb_color = nil,
    mining_color = nil,
    chest_color = nil,
    fishing_color = nil,
    gathering_radius = nil,
    gathering_thickness = nil,
    show_tracelines_gathering = nil,
    gathering_traceline_solid = nil,  -- true = solid line, false = dotted
    show_tracelines_questmobs = nil,
    show_tracelines_questitems = nil,
    show_traceline_labels = nil,
    attack_range_tree = nil,
    show_attack_range = nil,
    use_spell_range = nil,
    min_range = nil,
    max_range = nil,
    attack_range_color = nil,
    dead_zone_color = nil,
    attack_range_thickness = nil,
    radar_tree = nil,
    show_radar = nil,
    radar_size = nil,
    radar_range = nil,
    radar_background_color = nil,
    radar_border_color = nil,
    radar_player_color = nil,
    radar_enemy_color = nil,
    radar_quest_color = nil,
    radar_quest_item_color = nil,
    radar_gathering_color = nil,
    radar_fishing_color = nil,
    radar_show_names = nil,
    radar_blip_size = nil,
    radar_show_height = nil,
    radar_show_enemy_arrows = nil,
    radar_show_quest_arrows = nil,
    enemy_circle_tree = nil,
    danger_zone_tree = nil,
    targeting_tree = nil,
    window_enemy_circles = nil,
    window_danger_zones = nil,
    window_targeting = nil,
    window_quest = nil,
    window_gathering = nil,
    window_attack_range = nil,
    window_radar = nil,
    window_enhanced_esp = nil,
    window_enemy_circles_tree = nil,
    window_danger_zones_tree = nil,
    window_targeting_tree = nil,
    window_quest_tree = nil,
    window_gathering_tree = nil,
    window_attack_range_tree = nil,
    window_radar_tree = nil,
    window_enhanced_esp_tree = nil,
    behind_warning = nil,
    behind_warning_distance = nil,
    patrol_warning = nil,
    patrol_warning_distance = nil,
    -- Cave Mode
    cave_mode_key = nil,
    cave_mode_height = nil,
    cave_mode_cone_angle = nil,
    cave_mode_cone_enabled = nil,
    cave_mode_height_enabled = nil,
}

-- ============================================================================
-- CAVE MODE: Filtert Entities basierend auf Höhe und Blickfeld-Kegel
-- ============================================================================

-- Normalisiert einen Winkel auf -PI bis PI
local function normalize_angle(angle)
    while angle > math.pi do
        angle = angle - 2 * math.pi
    end
    while angle < -math.pi do
        angle = angle + 2 * math.pi
    end
    return angle
end

-- Prüft ob eine Entity durch Cave Mode gefiltert werden soll
-- Gibt true zurück wenn Entity ANGEZEIGT werden soll, false wenn ausgeblendet
local function cave_mode_filter(entity_pos, player_pos, player_facing_param)
    -- Cave Mode nicht aktiv? -> Zeige alles
    if not menu_elements.cave_mode_key then
        return true
    end
    local ok, enabled = pcall(function()
        return menu_elements.cave_mode_key:get_toggle_state()
    end)
    if not ok or not enabled then
        return true
    end
    
    -- Höhenfilter
    local height_check_passed = true
    if menu_elements.cave_mode_height_enabled then
        local ok2, height_enabled = pcall(function()
            return menu_elements.cave_mode_height_enabled:get_state()
        end)
        if ok2 and height_enabled then
            local max_height = 8.0  -- Default
            if menu_elements.cave_mode_height then
                local ok3, h = pcall(function()
                    return menu_elements.cave_mode_height:get()
                end)
                if ok3 and h then
                    max_height = h
                end
            end
            
            local height_diff = math.abs((player_pos.z or 0) - (entity_pos.z or 0))
            height_check_passed = height_diff <= max_height
        end
    end
    
    -- Cone-Filter (Blickfeld)
    local cone_check_passed = true
    if menu_elements.cave_mode_cone_enabled then
        local ok4, cone_enabled = pcall(function()
            return menu_elements.cave_mode_cone_enabled:get_state()
        end)
        if ok4 and cone_enabled then
            -- Hole player_facing direkt hier (falls Parameter nil ist)
            local player_facing = player_facing_param
            if not player_facing then
                local local_player = core.object_manager.get_local_player()
                if local_player then
                    -- Versuche verschiedene Methoden
                    if local_player.get_facing then
                        local ok_f, f = pcall(local_player.get_facing, local_player)
                        if ok_f and f then
                            player_facing = f
                        end
                    end
                    -- Fallback: get_rotation
                    if not player_facing and local_player.get_rotation then
                        local ok_r, r = pcall(local_player.get_rotation, local_player)
                        if ok_r and r then
                            player_facing = r
                        end
                    end
                    -- Fallback: rotation Property
                    if not player_facing and local_player.rotation then
                        player_facing = local_player.rotation
                    end
                    -- Fallback: facing Property
                    if not player_facing and local_player.facing then
                        player_facing = local_player.facing
                    end
                end
            end
            
            -- Debug: Einmalig loggen
            if not _cone_debug_done then
                _cone_debug_done = true
                if core.log then
                    core.log("[CONE] Cone filter active, player_facing: " .. tostring(player_facing))
                end
            end
            
            if player_facing then
                local cone_angle = 120.0  -- Default (Grad)
                if menu_elements.cave_mode_cone_angle then
                    local ok5, a = pcall(function()
                        return menu_elements.cave_mode_cone_angle:get()
                    end)
                    if ok5 and a then
                        cone_angle = a
                    end
                end
                
                -- Winkel zur Entity berechnen
                local dx = (entity_pos.x or 0) - (player_pos.x or 0)
                local dy = (entity_pos.y or 0) - (player_pos.y or 0)
                
                -- Berechne Winkel zur Entity (relativ zu positiver X-Achse)
                local angle_to_entity = math.atan2(dy, dx)
                
                -- Player facing ist bereits in Radiant (0 bis 2*PI in WoW)
                -- Konvertiere zu -PI bis PI für einfachere Berechnung
                local facing_normalized = player_facing
                if facing_normalized > math.pi then
                    facing_normalized = facing_normalized - 2 * math.pi
                end
                
                -- Differenz berechnen
                local angle_diff = angle_to_entity - facing_normalized
                
                -- Auf -PI bis PI normalisieren
                while angle_diff > math.pi do
                    angle_diff = angle_diff - 2 * math.pi
                end
                while angle_diff < -math.pi do
                    angle_diff = angle_diff + 2 * math.pi
                end
                
                -- Cone-Winkel in Radiant (halber Winkel für jede Seite)
                local half_cone_rad = math.rad(cone_angle / 2)
                cone_check_passed = math.abs(angle_diff) <= half_cone_rad
            else
                -- Kein player_facing verfügbar - zeige alles
                if not _cone_no_facing_logged then
                    _cone_no_facing_logged = true
                    if core.log then
                        core.log("[CONE] Warning: Could not get player facing! Cone filter disabled.")
                    end
                end
                cone_check_passed = true
            end
        end
    end
    
    -- Beide Filter müssen bestanden werden
    return height_check_passed and cone_check_passed
end

-- Prüft ob Gathering Mode aktiv ist
local function is_gathering_mode_active()
    if not menu_elements.gathering_mode_key then
        return false
    end
    local ok, enabled = pcall(function()
        return menu_elements.gathering_mode_key:get_toggle_state()
    end)
    return ok and enabled
end

-- Prüft ob ein bestimmter Gathering-Typ im Gathering Mode angezeigt werden soll
-- gathering_type: "ore", "herb", "chest", "fish"
local function gathering_mode_allows_type(gathering_type)
    if not is_gathering_mode_active() then
        return true  -- Wenn Gathering Mode nicht aktiv, zeige alles
    end
    
    -- Prüfe den spezifischen Typ
    if gathering_type == "ore" or gathering_type == "ores" then
        if menu_elements.gathering_mode_ores then
            local ok, val = pcall(function()
                return menu_elements.gathering_mode_ores:get_state()
            end)
            return ok and val
        end
    elseif gathering_type == "herb" or gathering_type == "herbs" then
        if menu_elements.gathering_mode_herbs then
            local ok, val = pcall(function()
                return menu_elements.gathering_mode_herbs:get_state()
            end)
            return ok and val
        end
    elseif gathering_type == "chest" or gathering_type == "chests" then
        if menu_elements.gathering_mode_chests then
            local ok, val = pcall(function()
                return menu_elements.gathering_mode_chests:get_state()
            end)
            return ok and val
        end
    elseif gathering_type == "fish" or gathering_type == "fishing" then
        if menu_elements.gathering_mode_fish then
            local ok, val = pcall(function()
                return menu_elements.gathering_mode_fish:get_state()
            end)
            return ok and val
        end
    end
    
    return true  -- Unbekannter Typ -> zeige an
end

local function estimate_aggro_radius(obj, default_radius, player_level)
    if not obj then
        return default_radius
    end
    if not player_level then
        local local_player = core.object_manager.get_local_player()
        if local_player and local_player.level then
            local ok, lvl = pcall(local_player.level, local_player)
            if ok and lvl then
                player_level = lvl
            end
        end
    end
    if not player_level then
        return default_radius
    end
    local mob_level = nil
    if obj.level then
        local ok, lvl = pcall(obj.level, obj)
        if ok and lvl then
            mob_level = lvl
        end
    end
    if not mob_level then
        return default_radius
    end
    local aggro_radius = 20 + (mob_level - player_level)
    if aggro_radius < 5 then
        aggro_radius = 5
    elseif aggro_radius > 45 then
        aggro_radius = 45
    end
    return aggro_radius
end
-- Live Color Read: Liest Farben JEDES FRAME direkt aus dem Color-Picker
-- Laut Sylvanas API: colorpicker:get() gibt ein color Objekt zurück
-- Das color Objekt kann direkt an Grafik-Funktionen übergeben werden
local function get_live_color(elem, fallback)
    if not elem or not elem.get then 
        return fallback 
    end
    local ok, col = pcall(elem.get, elem)
    if ok and col then
        return col
    end
    return fallback
end

-- Alias für Rückwärtskompatibilität
local function get_safe_color(elem, fallback)
    return get_live_color(elem, fallback)
end

-- Helper-Funktion: Hole UI-Skalierungsfaktor für ein bestimmtes Element
local function get_element_scale(element)
    if not element or not element.get then
        return 1.0  -- Default: 100%
    end
    local ok, scale = pcall(element.get, element)
    if ok and scale and type(scale) == "number" then
        return scale / 100.0  -- Konvertiere Prozent zu Faktor (100% = 1.0)
    end
    return 1.0
end

local render_frame_count = 0

-- Extrahiert RGBA aus einem Sylvanas color Objekt via color:get()
-- Laut API: color:get() gibt r, g, b, a zurück
local function get_color_rgba(col)
    if not col then return nil, nil, nil, nil end
    
    -- Versuche color:get() - die offizielle Sylvanas API
    if col.get then
        local ok, r, g, b, a = pcall(col.get, col)
        if ok and r then
            return r, g or 0, b or 0, a or 255
        end
    end
    
    -- Fallback: direkter Zugriff auf .r/.g/.b/.a
    local ok_r, r = pcall(function() return col.r end)
    local ok_g, g = pcall(function() return col.g end)
    local ok_b, b = pcall(function() return col.b end)
    local ok_a, a = pcall(function() return col.a end)
    
    if ok_r and ok_g and ok_b and r and g and b then
        return r, g, b, a or 255
    end
    
    return nil, nil, nil, nil
end

-- Wrapper für Rückwärtskompatibilität
local function safe_get_rgb(col, default_r, default_g, default_b)
    local r, g, b, _ = get_color_rgba(col)
    return r or default_r or 255, g or default_g or 255, b or default_b or 255
end

local function safe_get_alpha(col, default_a)
    local _, _, _, a = get_color_rgba(col)
    return a or default_a or 255
end

-- Wendet Alpha-Slider auf Farbe an (genau wie apply_distance_fading, aber mit Alpha-Multiplier)
local function apply_alpha_multiplier(base_color, alpha_multiplier)
    if not base_color then 
        return color.new(255, 165, 0, math.floor(255 * alpha_multiplier))
    end
    
    -- Verwende safe_get_alpha für robuste Alpha-Extraktion
    local base_alpha = safe_get_alpha(base_color, 255)
    
    local alpha = math.floor(base_alpha * alpha_multiplier)
    if alpha < 0 then alpha = 0 end
    if alpha > 255 then alpha = 255 end
    
    local r, g, b = safe_get_rgb(base_color, 255, 0, 0)  -- Rot als Fallback
    return color.new(r, g, b, alpha)
end

local function render_enemy_esp()
    local enabled = true
    if menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok and val ~= nil then
            enabled = val
        end
    end
    if not enabled then
        return
    end
    if menu_elements.toggle_key then
        if menu_elements.toggle_key.get_toggle_state then
            local ok, toggle_state = pcall(menu_elements.toggle_key.get_toggle_state, menu_elements.toggle_key)
            if ok and toggle_state ~= nil and not toggle_state then
                return
            end
        end
    end
    render_frame_count = render_frame_count + 1
    if not core or not core.object_manager or not core.object_manager.get_all_objects then
        return
    end
    
    -- FRAME UPDATE: Spieler cachen (JEDES FRAME!)
    cached_local_player = core.object_manager.get_local_player()
    if cached_local_player and cached_local_player.get_position then
        local ok, pos = pcall(cached_local_player.get_position, cached_local_player)
        if ok and pos and pos.x and pos.y then
            cached_player_pos = pos
        end
    end
    
    -- Ohne gültige Position NICHT rendern
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    local player_level = nil
    if local_player.level then
        local ok_lvl, lvl = pcall(local_player.level, local_player)
        if ok_lvl and lvl then
            player_level = lvl
        end
    end
    -- Aktuelles Target des Spielers abrufen
    local player_target = nil
    local player_target_guid = nil
    if local_player.get_target then
        local ok_target, target = pcall(local_player.get_target, local_player)
        if ok_target and target then
            player_target = target
            if target.get_guid then
                local ok_guid, guid = pcall(target.get_guid, target)
                if ok_guid and guid then
                    player_target_guid = guid
                end
        end
    end
    end
    local objects = core.object_manager.get_all_objects()
    if not objects then
        return
    end
    -- Feste Werte für Radius und Dicke
    local enemy_radius = 2.0
    local render_thickness = 8.0
    local show_names = true
    if menu_elements.show_names and menu_elements.show_names.get_state then
        local ok, val = pcall(menu_elements.show_names.get_state, menu_elements.show_names)
        if ok and val ~= nil then
            show_names = val
        end
    end
    local max_distance = 100.0
    if menu_elements.max_distance and menu_elements.max_distance.get then
        local ok, val = pcall(menu_elements.max_distance.get, menu_elements.max_distance)
        if ok and val and type(val) == "number" then
            max_distance = val
        end
    end
    local show_danger_zones = true
    if menu_elements.show_danger_zones and menu_elements.show_danger_zones.get_state then
        local ok, val = pcall(menu_elements.show_danger_zones.get_state, menu_elements.show_danger_zones)
        if ok and val ~= nil then
            show_danger_zones = val
        end
    end
    local base_danger_zone_radius = 10.0
    if menu_elements.danger_zone_radius and menu_elements.danger_zone_radius.get then
        local ok, val = pcall(menu_elements.danger_zone_radius.get, menu_elements.danger_zone_radius)
        if ok and val and type(val) == "number" then
            base_danger_zone_radius = val
        end
    end
    local danger_zone_scale = 1.0
    if menu_elements.danger_zone_scale and menu_elements.danger_zone_scale.get then
        local ok, val = pcall(menu_elements.danger_zone_scale.get, menu_elements.danger_zone_scale)
        if ok and val and type(val) == "number" then
            danger_zone_scale = val
        end
    end
    local show_quest_mobs = true
    if menu_elements.show_quest_mobs and menu_elements.show_quest_mobs.get_state then
        local ok, val = pcall(menu_elements.show_quest_mobs.get_state, menu_elements.show_quest_mobs)
        if ok and val ~= nil then
            show_quest_mobs = val
        end
    end
    local show_quest_symbol = true
    if menu_elements.show_quest_symbol and menu_elements.show_quest_symbol.get_state then
        local ok, val = pcall(menu_elements.show_quest_symbol.get_state, menu_elements.show_quest_symbol)
        if ok and val ~= nil then
            show_quest_symbol = val
        end
    end
    local show_level_hp = true
    if menu_elements.show_level_hp and menu_elements.show_level_hp.get_state then
        local ok, val = pcall(menu_elements.show_level_hp.get_state, menu_elements.show_level_hp)
        if ok and val ~= nil then
            show_level_hp = val
        end
    end
    -- Farben werden jetzt direkt vor der Verwendung gelesen (nicht mehr gecacht)
    dump_questie_api()
    local show_herbs = false
    if menu_elements.show_herbs and menu_elements.show_herbs.get_state then
        local ok, val = pcall(menu_elements.show_herbs.get_state, menu_elements.show_herbs)
        if ok and val ~= nil then
            show_herbs = val
        end
    end
    local show_mining = false
    if menu_elements.show_mining and menu_elements.show_mining.get_state then
        local ok, val = pcall(menu_elements.show_mining.get_state, menu_elements.show_mining)
        if ok and val ~= nil then
            show_mining = val
        end
    end
    local show_chests = false
    if menu_elements.show_chests and menu_elements.show_chests.get_state then
        local ok, val = pcall(menu_elements.show_chests.get_state, menu_elements.show_chests)
        if ok and val ~= nil then
            show_chests = val
        end
    end
    local show_fishing = true
    if menu_elements.show_fishing and menu_elements.show_fishing.get_state then
        local ok, val = pcall(menu_elements.show_fishing.get_state, menu_elements.show_fishing)
        if ok and val ~= nil then
            show_fishing = val
        end
    end
    local show_fishing = true
    if menu_elements.show_fishing and menu_elements.show_fishing.get_state then
        local ok, val = pcall(menu_elements.show_fishing.get_state, menu_elements.show_fishing)
        if ok and val ~= nil then
            show_fishing = val
        end
    end
    -- Farben werden jetzt direkt vor der Verwendung gelesen (nicht mehr gecacht)
    local gathering_radius = 2.0
    if menu_elements.gathering_radius and menu_elements.gathering_radius.get then
        local ok, val = pcall(menu_elements.gathering_radius.get, menu_elements.gathering_radius)
        if ok and val and type(val) == "number" then
            gathering_radius = val
        end
    end
    local gathering_thickness = 1.5
    if menu_elements.gathering_thickness and menu_elements.gathering_thickness.get then
        local ok, val = pcall(menu_elements.gathering_thickness.get, menu_elements.gathering_thickness)
        if ok and val and type(val) == "number" then
            gathering_thickness = val
        end
    end
    -- Farben werden jetzt direkt vor der Verwendung gelesen (nicht mehr gecacht)
    local show_enemy_circles = true
    if menu_elements.show_enemy_circles and menu_elements.show_enemy_circles.get_state then
        local ok, val = pcall(menu_elements.show_enemy_circles.get_state, menu_elements.show_enemy_circles)
        if ok and val ~= nil then
            show_enemy_circles = val
        end
    end
    
    -- Custom Nameplates Check - wenn aktiv, alte HP-Bars nicht rendern
    local custom_nameplates_active = false
    if menu_elements.custom_nameplates and menu_elements.custom_nameplates.get_state then
        local ok, val = pcall(menu_elements.custom_nameplates.get_state, menu_elements.custom_nameplates)
        if ok and val == true then
            custom_nameplates_active = true
        end
    end
    -- Farben werden jetzt direkt vor der Verwendung gelesen (nicht mehr gecacht)
    local show_targeting_indicator = true
    if menu_elements.show_targeting_indicator and menu_elements.show_targeting_indicator.get_state then
        local ok, val = pcall(menu_elements.show_targeting_indicator.get_state, menu_elements.show_targeting_indicator)
        if ok and val ~= nil then
            show_targeting_indicator = val
        end
    end
    local line_thickness = 8.0
    if menu_elements.line_thickness and menu_elements.line_thickness.get then
        local ok, val = pcall(menu_elements.line_thickness.get, menu_elements.line_thickness)
        if ok and val and type(val) == "number" then
            line_thickness = val
        end
    end
    local show_attack_range = false
    if menu_elements.show_attack_range and menu_elements.show_attack_range.get_state then
        local ok, val = pcall(menu_elements.show_attack_range.get_state, menu_elements.show_attack_range)
        if ok and val ~= nil then
            show_attack_range = val
        end
    end
    local use_spell_range = true
    if menu_elements.use_spell_range and menu_elements.use_spell_range.get_state then
        local ok, val = pcall(menu_elements.use_spell_range.get_state, menu_elements.use_spell_range)
        if ok and val ~= nil then
            use_spell_range = val
        end
    end
    local min_range = 0.0
    if menu_elements.min_range and menu_elements.min_range.get then
        local ok, val = pcall(menu_elements.min_range.get, menu_elements.min_range)
        if ok and val and type(val) == "number" then
            min_range = val
        end
    end
    local max_range = 35.0
    if menu_elements.max_range and menu_elements.max_range.get then
        local ok, val = pcall(menu_elements.max_range.get, menu_elements.max_range)
        if ok and val and type(val) == "number" then
            max_range = val
        end
    end
    -- Farben werden jetzt direkt vor der Verwendung gelesen (nicht mehr gecacht)
    local attack_range_thickness = 2.0
    if menu_elements.attack_range_thickness and menu_elements.attack_range_thickness.get then
        local ok, val = pcall(menu_elements.attack_range_thickness.get, menu_elements.attack_range_thickness)
        if ok and val and type(val) == "number" then
            attack_range_thickness = val
        end
    end
    -- Verwende gecachte Spielerposition für Frame-Konsistenz
    local player_pos = cached_player_pos
    if show_attack_range then
        local render_range_thickness = math.min(attack_range_thickness, 10.0)
        local current_target = nil
        if local_player.get_target then
            local ok_target, target = pcall(local_player.get_target, local_player)
            if ok_target and target then
                current_target = target
            end
        end
        local target_distance = nil
        local is_in_dead_zone = false
        local is_in_range = false
        if current_target then
            if local_player.distance_to then
                local ok_dist, dist = pcall(local_player.distance_to, local_player, current_target)
                if ok_dist and dist then
                    target_distance = dist
                end
            elseif local_player.distance then
                local ok_dist, dist = pcall(local_player.distance, local_player, current_target)
                if ok_dist and dist then
                    target_distance = dist
                end
            end
            if not target_distance and current_target.get_position then
                local ok_pos, target_pos = pcall(current_target.get_position, current_target)
                if ok_pos and target_pos and target_pos.x and target_pos.y then
                    local dx = target_pos.x - player_pos.x
                    local dy = target_pos.y - player_pos.y
                    local dz = (target_pos.z or 0) - (player_pos.z or 0)
                    target_distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                end
            end
            if target_distance then
                if target_distance < min_range then
                    is_in_dead_zone = true
                end

                -- Manuelle Distanz-Prüfung (35 Yards)
                is_in_range = (target_distance <= max_range and target_distance >= min_range)
            end
        end
        -- Farben werden jetzt direkt vor der Verwendung gelesen (live aus dem Color-Picker)
        local attack_range_color = get_safe_color(menu_elements.attack_range_color, color.new(0, 255, 0, 200))
        local dead_zone_color = get_safe_color(menu_elements.dead_zone_color, color.new(255, 0, 0, 200))
        local range_color = attack_range_color
        if is_in_dead_zone then
            range_color = dead_zone_color
        elseif is_in_range then
            range_color = attack_range_color
        else
            -- Out of range: Orange mit Alpha vom attack_range_color (nicht hardcoded!)
            local out_of_range_alpha = math.min(safe_get_alpha(attack_range_color, 150), 150)
            range_color = color.new(255, 165, 0, out_of_range_alpha)
        end
        if min_range > 0 then
            -- Verwende dead_zone_color wenn in Dead Zone, sonst Orange mit Alpha vom Color-Picker
            local min_color = dead_zone_color
            if not is_in_dead_zone then
                local min_range_alpha = math.min(safe_get_alpha(dead_zone_color, 150), 150)
                min_color = color.new(255, 165, 0, min_range_alpha)
            end
            local min_thickness = is_in_dead_zone and render_range_thickness * 1.5 or render_range_thickness
            pcall(core.graphics.circle_3d, player_pos, min_range, min_color, min_thickness, 40)
            pcall(core.graphics.circle_3d, player_pos, min_range, min_color, min_thickness * 0.95, 40)
            pcall(core.graphics.circle_3d, player_pos, min_range, min_color, min_thickness * 0.9, 40)
            pcall(core.graphics.circle_3d, player_pos, min_range, min_color, min_thickness * 0.85, 40)
            pcall(core.graphics.circle_3d, player_pos, min_range, min_color, min_thickness * 0.8, 40)
        end
        if max_range > min_range then
            pcall(core.graphics.circle_3d, player_pos, max_range, range_color, render_range_thickness, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, range_color, render_range_thickness * 0.95, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, range_color, render_range_thickness * 0.9, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, range_color, render_range_thickness * 0.85, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, range_color, render_range_thickness * 0.8, 40)
            local outline_color = color.new(255, 255, 255, 100)
            pcall(core.graphics.circle_3d, player_pos, max_range, outline_color, render_range_thickness * 1.2, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, outline_color, render_range_thickness * 1.0, 40)
            pcall(core.graphics.circle_3d, player_pos, max_range, outline_color, render_range_thickness * 0.8, 40)
        end
        if is_in_dead_zone and current_target and current_target.get_position then
            local ok_pos, target_pos = pcall(current_target.get_position, current_target)
            if ok_pos and target_pos and target_pos.x and target_pos.y then
                local render_z = target_pos.z or player_pos.z or 0
                local target_render_pos = { x = target_pos.x, y = target_pos.y, z = render_z }
                local warning_thickness = render_range_thickness * 2.0
                pcall(core.graphics.circle_3d, target_render_pos, enemy_radius * 1.2, dead_zone_color, warning_thickness, 40)
                pcall(core.graphics.circle_3d, target_render_pos, enemy_radius * 1.2, dead_zone_color, warning_thickness * 0.9, 40)
                pcall(core.graphics.circle_3d, target_render_pos, enemy_radius * 1.2, dead_zone_color, warning_thickness * 0.8, 40)
            end
        end
    end
    local rendered_count = 0
local function format_unit_info(unit)
    local name = "Enemy"
    if unit.get_name then
        local ok, n = pcall(unit.get_name, unit)
        if ok and n then name = n end
    end
    local lvl = nil
    if unit.get_level then
        local ok, l = pcall(unit.get_level, unit)
        if ok and l then lvl = l end
    elseif unit.level then
        local ok, l = pcall(unit.level, unit)
        if ok and l then lvl = l end
    end
    local hp_pct = nil
    if unit.get_health and unit.get_max_health then
        local ok1, hp = pcall(unit.get_health, unit)
        local ok2, mhp = pcall(unit.get_max_health, unit)
        if ok1 and ok2 and hp and mhp and mhp > 0 then
            hp_pct = (hp / mhp) * 100.0
        end
    end
    return name, lvl, hp_pct
end

-- ESP 2.0: Gibt Cast-Informationen zurück (spell_name, cast_progress, is_channeling)
-- Verwendet die offizielle Project Sylvanas API
local function get_unit_cast_info(unit)
    if not unit then return nil, 0, false end
    
    -- Prüfe ob Unit castet oder channelt (game_object API)
    local is_casting = unit:is_casting_spell()
    local is_channeling = unit:is_channelling_spell()
    
    if not is_casting and not is_channeling then
        return nil, 0, false
    end
    
    -- Hole Spell-ID (game_object API)
    local spell_id = 0
    if is_casting then
        spell_id = unit:get_active_spell_id()
    elseif is_channeling then
        spell_id = unit:get_active_channel_spell_id()
    end
    
    -- Hole Cast-Progress über Zeit-Berechnung (game_object API)
    local cast_progress = 0.0
    local start_time, end_time
    
    if is_casting then
        start_time = unit:get_active_spell_cast_start_time()
        end_time = unit:get_active_spell_cast_end_time()
    else
        start_time = unit:get_active_channel_cast_start_time()
        end_time = unit:get_active_channel_cast_end_time()
    end
    
    if start_time and end_time and start_time > 0 and end_time > start_time then
        local current_time = core.game_time()
        local total_time = end_time - start_time
        local elapsed = current_time - start_time
        if elapsed >= 0 and total_time > 0 then
            cast_progress = math.max(0.0, math.min(1.0, elapsed / total_time))
        end
    end
    
    -- Hole Spell-Name über core.spell_book
    local spell_name = nil
    if spell_id and spell_id > 0 then
        if core.spell_book and core.spell_book.get_spell_name then
            spell_name = core.spell_book.get_spell_name(spell_id)
        end
        if not spell_name or spell_name == "" then
            spell_name = "Spell " .. tostring(spell_id)
        end
    else
        spell_name = is_channeling and "Channeling" or "Casting"
    end
    
    return spell_name, cast_progress, is_channeling
end

-- ESP 2.0: Gibt Klassifikation zurück (Normal, Elite, Rare, RareElite, Boss)
local function get_unit_classification(unit)
    if not unit then return "normal" end
    
    if unit.get_classification then
        local ok, class = pcall(unit.get_classification, unit)
        if ok and class then
            return class
        end
    end
    
    -- Fallback: Prüfe ob Elite über andere Methoden
    if unit.is_elite then
        local ok, elite = pcall(unit.is_elite, unit)
        if ok and elite then
            return "elite"
        end
    end
    
    return "normal"
end

-- ESP 2.0: Gibt Bewegungsstatus zurück
local function get_unit_movement_status(unit)
    if not unit then return false, false, 0 end
    
    local is_moving = false
    local is_dashing = false
    local speed = 0
    
    -- Methode 1: is_moving()
    if unit.is_moving then
        local ok, moving = pcall(unit.is_moving, unit)
        if ok and moving then
            is_moving = moving
        end
    end
    
    -- Methode 2: Geschwindigkeit prüfen (Fallback)
    if unit.get_movement_speed then
        local ok, spd = pcall(unit.get_movement_speed, unit)
        if ok and spd and type(spd) == "number" then
            speed = spd
            -- Wenn Geschwindigkeit > 0, dann bewegt sich die Einheit
            if speed > 0.1 then
                is_moving = true
            end
            -- Sprint-Erkennung: > 100% Bewegungsgeschwindigkeit (7.0 ist normal)
            if speed > 8.0 then
                is_dashing = true
            end
        end
    end
    
    -- Methode 3: is_dashing()
    if unit.is_dashing then
        local ok, dashing = pcall(unit.is_dashing, unit)
        if ok and dashing then
            is_dashing = dashing
        end
    end
    
    return is_moving, is_dashing, speed
end

-- ESP 2.0: Prüft ob Unit im Kampf ist
local function is_unit_in_combat(unit)
    if not unit then return false end
    
    -- Methode 1: is_in_combat()
    if unit.is_in_combat then
        local ok, in_combat = pcall(unit.is_in_combat, unit)
        if ok and in_combat then
            return true
        end
    end
    
    -- Methode 2: has_combat_flag()
    if unit.has_combat_flag then
        local ok, has_flag = pcall(unit.has_combat_flag, unit)
        if ok and has_flag then
            return true
        end
    end
    
    -- Methode 3: get_combat_state()
    if unit.get_combat_state then
        local ok, state = pcall(unit.get_combat_state, unit)
        if ok and state then
            return true
        end
    end
    
    return false
end

-- ESP 2.0: Gibt Blickrichtung zurück
local function get_unit_facing_direction(unit)
    if not unit then return nil end
    
    if unit.get_direction then
        local ok, dir = pcall(unit.get_direction, unit)
        if ok and dir then
            return dir
        end
    end
    
    -- Fallback: Rotation
    if unit.get_rotation then
        local ok, rot = pcall(unit.get_rotation, unit)
        if ok and rot then
            return { x = math.cos(rot), y = math.sin(rot), z = 0 }
        end
    end
    
    return nil
end

local function calculate_distance(pos1, pos2)
    if not pos1 or not pos2 or not pos1.x or not pos2.x then
        return 0
    end
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = (pos1.z or 0) - (pos2.z or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function apply_distance_fading(base_color, distance, max_distance, min_alpha)
    if not base_color then return base_color end
    min_alpha = min_alpha or 120
    
    -- Hole das ursprüngliche Alpha vom Color-Picker (berücksichtigt User-Transparenz!)
    local original_alpha = safe_get_alpha(base_color, 255)
    
    -- Berechne Fading-Faktor basierend auf Distanz (1.0 = nah, min_alpha/255 = weit)
    local fading_factor = math.max(min_alpha / 255, 1.0 - (distance / max_distance) * (1.0 - min_alpha / 255))
    
    -- Wende Fading-Faktor auf das ursprüngliche Alpha an (nicht ersetzen!)
    local alpha = math.floor(original_alpha * fading_factor)
    if alpha < 0 then alpha = 0 end
    if alpha > 255 then alpha = 255 end
    
    local r, g, b = safe_get_rgb(base_color, 255, 0, 0)  -- Rot als Fallback
    return color.new(r, g, b, alpha)
end

-- Holt Danger Zone Farbe mit Alpha-Slider (global für Zugriff aus allen Funktionen)
function get_danger_zone_color_from_picker(elem, fallback_r, fallback_g, fallback_b)
    local r, g, b = fallback_r or 255, fallback_g or 165, fallback_b or 0
    
    -- Hole Farbwerte direkt vom ColorPicker
    if elem and elem.get then
        local ok, v = pcall(elem.get, elem)
        if ok and v then
            -- Float-Format (x,y,z,w) 0..1
            if type(v) == "table" and (v.x ~= nil or v.y ~= nil or v.z ~= nil) then
                r = math.floor((v.x or 1) * 255)
                g = math.floor((v.y or 1) * 255)
                b = math.floor((v.z or 1) * 255)
            -- Int-Format (r,g,b,a)
            elseif type(v) == "table" then
                r = v.r or v[1] or fallback_r or 255
                g = v.g or v[2] or fallback_g or 165
                b = v.b or v[3] or fallback_b or 0
            -- Nummer (gepackt)
            elseif type(v) == "number" then
                local color_num = v
                if color_num < 0 then
                    color_num = color_num + 0x100000000
                end
                local packed_b = math.floor(color_num / 0x10000) % 0x100
                local packed_g = math.floor(color_num / 0x100) % 0x100
                local packed_r = color_num % 0x100
                r, g, b = packed_r, packed_g, packed_b
            end
        end
    end
    
    -- Alpha-Slider-Wert abrufen (0-100, 0 = unsichtbar, 100 = voll sichtbar)
    local alpha_multiplier = 0.7
    if menu_elements.danger_zone_alpha and menu_elements.danger_zone_alpha.get then
        local ok, val = pcall(menu_elements.danger_zone_alpha.get, menu_elements.danger_zone_alpha)
        if ok and val ~= nil and type(val) == "number" then
            alpha_multiplier = val / 100.0  -- Slider gibt 0-100 zurück, normalisiere auf 0-1
        end
    end
    
    local final_alpha = math.floor(255 * alpha_multiplier)
    if final_alpha < 0 then final_alpha = 0 end
    if final_alpha > 255 then final_alpha = 255 end
    
    return color.new(r, g, b, final_alpha)
end

-- Prüft ob Darkmode aktiv ist
local function is_darkmode_active()
    if menu_elements.hardcore_dark_mode and menu_elements.hardcore_dark_mode.get_state then
        local ok, val = pcall(menu_elements.hardcore_dark_mode.get_state, menu_elements.hardcore_dark_mode)
        if ok and val == true then
            return true
        end
    end
    return false
end

-- Konvertiert 3D-Position zu 2D-Screen-Koordinaten
local function world_to_screen_2d(world_pos)
    if not world_pos or not core or not core.graphics then
        return nil
    end
    if core.graphics.w2s then
        local ok, screen_pos = pcall(core.graphics.w2s, world_pos)
        if ok and screen_pos and screen_pos.x and screen_pos.y then
            return screen_pos
        end
    elseif core.graphics.world_to_screen then
        local ok, screen_pos = pcall(core.graphics.world_to_screen, world_pos)
        if ok and screen_pos and screen_pos.x and screen_pos.y then
            return screen_pos
        end
    end
    return nil
end

-- Zeichnet Traceline (2D wenn Darkmode, sonst 3D)
local function draw_traceline(world_pos1, world_pos2, line_color, line_thickness)
    if not world_pos1 or not world_pos2 or not line_color or not core or not core.graphics then
        return
    end
    
    -- Berechne Richtungsvektor
    local dx = world_pos2.x - world_pos1.x
    local dy = world_pos2.y - world_pos1.y
    local dz = (world_pos2.z or 0) - (world_pos1.z or 0)
    local total_distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    
    if total_distance < 0.1 then
        return
    end
    
    -- Normalisiere Richtungsvektor
    dx = dx / total_distance
    dy = dy / total_distance
    dz = dz / total_distance
    
    -- Punkt-Abstand (kleine Punkte entlang der Linie)
    local point_spacing = 2.0  -- Abstand zwischen Punkten
    local point_size = 1.2     -- Größe der Punkte (größer für bessere Sichtbarkeit)
    local num_points = math.floor(total_distance / point_spacing)
    
    if num_points < 1 then
        num_points = 1
    end
    
    -- Übernehme die Farblogik der alten Tracelines - get_safe_color und apply_distance_fading geben color-Objekte zurück
    -- Extrahiere RGB-Werte aus dem color-Objekt
    local final_color = nil
    
    if line_color and type(line_color) == "table" then
        -- Prüfe ob es ein color-Objekt mit .r, .g, .b ist (von get_safe_color oder apply_distance_fading)
        -- WICHTIG: Prüfe mit ~= nil, nicht mit truthy, da 0 ein gültiger Wert ist
        if line_color.r ~= nil and line_color.g ~= nil and line_color.b ~= nil then
            -- Es ist bereits ein color-Objekt, extrahiere die Werte
            local r = line_color.r
            local g = line_color.g
            local b = line_color.b
            local a = line_color.a
            if a == nil then
                a = 255
            end
            -- Erstelle neues color-Objekt mit den extrahierten Werten
            final_color = color.new(r, g, b, a)
        elseif line_color.value then
            -- Fallback: Konvertiere .value zu color-Objekt (RGBA Format)
            local color_num = line_color.value
            if type(color_num) == "number" then
                if color_num < 0 then
                    color_num = color_num + 0x100000000
                end
                local r = math.floor(color_num / 0x1000000) % 0x100
                local g = math.floor(color_num / 0x10000) % 0x100
                local b = math.floor(color_num / 0x100) % 0x100
                local a = color_num % 0x100
                final_color = color.new(r, g, b, a)
            end
        elseif type(line_color) == "table" and #line_color >= 3 then
            -- Array-Format [r, g, b, a]
            final_color = color.new(line_color[1] or 255, line_color[2] or 255, line_color[3] or 255, line_color[4] or 255)
        end
    end
    
    -- Sicherstellen, dass final_color ein gültiges color-Objekt ist
    if not final_color then
        -- Fallback: versuche line_color direkt zu verwenden
        if line_color then
            local lr, lg, lb = safe_get_rgb(line_color, 255, 255, 255)
            local la = safe_get_alpha(line_color, 255)
            final_color = color.new(lr, lg, lb, la)
        else
            final_color = color.new(255, 255, 255, 255)  -- Fallback: weiß
        end
    end
    
    -- Finale Validierung: Stelle sicher, dass final_color ein gültiges color-Objekt mit .r, .g, .b ist
    -- WICHTIG: Prüfe mit == nil, nicht mit not, da 0 == false in Lua!
    if final_color.r == nil or final_color.g == nil or final_color.b == nil then
        final_color = color.new(255, 255, 255, 255)  -- Fallback: weiß
    end
    
    -- Zeichne kleine Punkte entlang der Linie
    -- WICHTIG: Setze die Farbe bei jedem Punkt explizit, da Render-Farbe ein globaler State ist
    for i = 0, num_points do
        local t = i / num_points
        local point_pos = {
            x = world_pos1.x + dx * total_distance * t,
            y = world_pos1.y + dy * total_distance * t,
            z = (world_pos1.z or 0) + dz * total_distance * t
        }
        
        -- Stelle sicher, dass final_color ein gültiges color-Objekt ist (mit .r, .g, .b, .a)
        -- WICHTIG: Prüfe mit == nil, nicht mit not, da 0 == false in Lua!
        local point_color = final_color
        if not point_color or point_color.r == nil or point_color.g == nil or point_color.b == nil then
            point_color = color.new(255, 255, 255, 255)
        end
        
        -- Wenn Darkmode aktiv ist, verwende 2D-Rendering
        if is_darkmode_active() then
            if core.graphics.circle_2d then
                local screen_pos = world_to_screen_2d(point_pos)
                if screen_pos then
                    -- Gefüllter Kreis für bessere Sichtbarkeit
                    if core.graphics.circle_2d_filled then
                        -- Setze Farbe explizit vor jedem Draw-Call
                        pcall(core.graphics.circle_2d_filled, vec2_new(screen_pos.x, screen_pos.y), point_size, point_color)
                    else
                        -- Setze Farbe explizit vor jedem Draw-Call
                        pcall(core.graphics.circle_2d, vec2_new(screen_pos.x, screen_pos.y), point_size, point_color, 2.0)
                    end
                end
            end
        else
            -- Normales 3D-Rendering
            -- Verwende gefüllte Kreise für bessere Sichtbarkeit
            if core.graphics.circle_3d_filled then
                -- Setze Farbe explizit vor jedem Draw-Call
                pcall(core.graphics.circle_3d_filled, point_pos, point_size, point_color)
            elseif core.graphics.circle_3d then
                -- Setze Farbe explizit vor jedem Draw-Call
                pcall(core.graphics.circle_3d, point_pos, point_size, point_color, 2.0, 12)
            end
        end
    end
end

-- Zeichnet Traceline als Punkte (3D Kreise - gefüllt, mit Alpha-Slider)
-- start_offset: Abstand vom Spieler (world_pos2), ab dem Dots gezeichnet werden (Standard: 5 Yards für 3D Radar)
local function draw_traceline_dots(world_pos1, world_pos2, dot_color, dot_spacing, dot_radius, start_offset)
    if not world_pos1 or not world_pos2 or not dot_color or not core or not core.graphics then
        return
    end
    
    dot_spacing = dot_spacing or 1.5
    dot_radius  = dot_radius  or 0.15
    start_offset = start_offset or 5.0  -- Standard: 5 Yards Abstand vom Spieler (außerhalb 3D Radar)
    
    local dx = world_pos1.x - world_pos2.x  -- Richtung: vom Spieler zum Ziel
    local dy = world_pos1.y - world_pos2.y
    local dz = (world_pos1.z or 0) - (world_pos2.z or 0)
    
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    if distance <= start_offset then return end  -- Zu nah, keine Dots zeichnen
    
    -- Normalisierte Richtung
    local dir_x = dx / distance
    local dir_y = dy / distance
    local dir_z = dz / distance
    
    -- Startposition: start_offset Yards vom Spieler entfernt
    local start_x = world_pos2.x + dir_x * start_offset
    local start_y = world_pos2.y + dir_y * start_offset
    local start_z = (world_pos2.z or 0) + dir_z * start_offset
    
    -- Verbleibende Distanz nach Offset
    local remaining_distance = distance - start_offset
    if remaining_distance <= 0 then return end
    
    local steps = math.floor(remaining_distance / dot_spacing)
    if steps <= 0 then return end
    
    local step_x = dir_x * dot_spacing
    local step_y = dir_y * dot_spacing
    local step_z = dir_z * dot_spacing
    
    -- WICHTIG: color.new() gibt userdata zurück, NICHT table!
    -- Daher verwenden wir dot_color direkt - es ist bereits ein gültiges Farbobjekt von get_safe_color
    
    for i = 1, steps do
        local pos = {
            x = start_x + step_x * i,
            y = start_y + step_y * i,
            z = start_z + step_z * i
        }
        
        -- Punkt zeichnen (2D gefüllter Kreis - besser sichtbar)
        if core.graphics.circle_2d_filled then
            local screen_pos = world_to_screen_2d(pos)
            if screen_pos then
                local screen_radius = dot_radius * 10.0
                if screen_radius > 20.0 then
                    screen_radius = 20.0
                elseif screen_radius < 1.0 then
                    screen_radius = 1.0
                end
                pcall(core.graphics.circle_2d_filled, vec2_new(screen_pos.x, screen_pos.y), screen_radius, dot_color)
            end
        elseif core.graphics.circle_3d_filled then
            pcall(core.graphics.circle_3d_filled, pos, dot_radius, dot_color)
        elseif core.graphics.circle_3d then
            pcall(core.graphics.circle_3d, pos, dot_radius, dot_color, 1.0, 8)
        end
    end
end

-- Zeichnet Box in 2D (für Darkmode)
local function draw_box_2d(center_pos, width, height, depth, box_color, line_thickness)
    if not center_pos or not box_color or not core or not core.graphics then return end
    if not core.graphics.line_2d then return end
    
    local w2 = width * 0.5
    local h2 = height * 0.5
    local d2 = depth * 0.5
    
    -- Ecken der Box in 3D
    local corners_3d = {
        { x = center_pos.x - w2, y = center_pos.y - d2, z = center_pos.z },
        { x = center_pos.x + w2, y = center_pos.y - d2, z = center_pos.z },
        { x = center_pos.x + w2, y = center_pos.y + d2, z = center_pos.z },
        { x = center_pos.x - w2, y = center_pos.y + d2, z = center_pos.z },
        { x = center_pos.x - w2, y = center_pos.y - d2, z = center_pos.z + height },
        { x = center_pos.x + w2, y = center_pos.y - d2, z = center_pos.z + height },
        { x = center_pos.x + w2, y = center_pos.y + d2, z = center_pos.z + height },
        { x = center_pos.x - w2, y = center_pos.y + d2, z = center_pos.z + height }
    }
    
    -- Konvertiere alle Ecken zu 2D
    local corners_2d = {}
    for i, corner_3d in ipairs(corners_3d) do
        local screen_pos = world_to_screen_2d(corner_3d)
        if screen_pos then
            corners_2d[i] = screen_pos
        else
            return -- Wenn eine Ecke nicht sichtbar ist, zeichne die Box nicht
        end
    end
    
    -- Zeichne Box-Linien in 2D
    local edges = {
        {1, 2}, {2, 3}, {3, 4}, {4, 1}, -- Unterseite
        {5, 6}, {6, 7}, {7, 8}, {8, 5}, -- Oberseite
        {1, 5}, {2, 6}, {3, 7}, {4, 8}  -- Vertikale Kanten
    }
    
    for _, edge in ipairs(edges) do
        local p1 = corners_2d[edge[1]]
        local p2 = corners_2d[edge[2]]
        if p1 and p2 then
            pcall(core.graphics.line_2d, vec2_new(p1.x, p1.y), vec2_new(p2.x, p2.y), box_color, line_thickness)
        end
    end
end

local function draw_box_3d(center_pos, width, height, depth, box_color, line_thickness)
    if not center_pos or not box_color then return end
    
    -- Wenn Darkmode aktiv ist, verwende 2D-Rendering
    if is_darkmode_active() then
        draw_box_2d(center_pos, width, height, depth, box_color, line_thickness)
        return
    end
    
    -- Normales 3D-Rendering
    local w2 = width * 0.5
    local h2 = height * 0.5
    local d2 = depth * 0.5
    local corners = {
        { x = center_pos.x - w2, y = center_pos.y - d2, z = center_pos.z },
        { x = center_pos.x + w2, y = center_pos.y - d2, z = center_pos.z },
        { x = center_pos.x + w2, y = center_pos.y + d2, z = center_pos.z },
        { x = center_pos.x - w2, y = center_pos.y + d2, z = center_pos.z },
        { x = center_pos.x - w2, y = center_pos.y - d2, z = center_pos.z + height },
        { x = center_pos.x + w2, y = center_pos.y - d2, z = center_pos.z + height },
        { x = center_pos.x + w2, y = center_pos.y + d2, z = center_pos.z + height },
        { x = center_pos.x - w2, y = center_pos.y + d2, z = center_pos.z + height }
    }
    if not core.graphics.line_3d then return end
    pcall(core.graphics.line_3d, corners[1], corners[5], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[2], corners[6], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[3], corners[7], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[4], corners[8], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[1], corners[2], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[2], corners[3], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[3], corners[4], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[4], corners[1], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[5], corners[6], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[6], corners[7], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[7], corners[8], box_color, line_thickness)
    pcall(core.graphics.line_3d, corners[8], corners[5], box_color, line_thickness)
end
-- Automatische Größenberechnung basierend auf Sylvanas API
local function get_object_size(obj, default_height)
    if not obj then
        return default_height or 2.0, 0.6, 0.6
    end
    
    local height = nil
    local radius = nil
    local scale = 1.0
    
    -- 1. Versuche scale/model_scale zu bekommen (Skalierungsfaktor des Modells)
    if obj.get_scale then
        local ok, s = pcall(obj.get_scale, obj)
        if ok and s and type(s) == "number" and s > 0 then
            scale = s
        end
    elseif obj.get_model_scale then
        local ok, s = pcall(obj.get_model_scale, obj)
        if ok and s and type(s) == "number" and s > 0 then
            scale = s
        end
    end
    
    -- 2. Versuche bounding_radius zu bekommen (gibt den Umkreis des Objekts)
    if obj.get_bounding_radius then
        local ok, r = pcall(obj.get_bounding_radius, obj)
        if ok and r and type(r) == "number" and r > 0 then
            radius = r
        end
    end
    
    -- 3. Versuche combat_reach zu bekommen (Kampfreichweite, oft ~= Größe)
    if not radius and obj.get_combat_reach then
        local ok, r = pcall(obj.get_combat_reach, obj)
        if ok and r and type(r) == "number" and r > 0 then
            radius = r
        end
    end
    
    -- 4. Versuche direkt die Höhe zu bekommen
    if obj.get_height then
        local ok, h = pcall(obj.get_height, obj)
        if ok and h and type(h) == "number" and h > 0 then
            height = h
        end
    end
    
    -- 5. Berechne die Werte
    if radius then
        -- Radius vorhanden: Box-Breite/Tiefe = Radius * 2 (Durchmesser)
        local box_width = radius * 2 * scale
        local box_depth = radius * 2 * scale
        -- Höhe: Entweder direkt oder basierend auf Radius (typisch: Höhe = 3-4x Radius)
        local box_height = height and (height * scale) or (radius * 3.5 * scale)
        
        -- Clamp auf vernünftige Werte
        box_height = math.max(0.5, math.min(box_height, 8.0))
        box_width = math.max(0.3, math.min(box_width, 4.0))
        box_depth = math.max(0.3, math.min(box_depth, 4.0))
        
        return box_height, box_width, box_depth
    elseif height then
        -- Nur Höhe vorhanden: Breite/Tiefe proportional berechnen
        local box_height = height * scale
        local box_width = (height * 0.35) * scale  -- Breite ~35% der Höhe
        local box_depth = (height * 0.35) * scale
        
        -- Clamp
        box_height = math.max(0.5, math.min(box_height, 8.0))
        box_width = math.max(0.3, math.min(box_width, 4.0))
        box_depth = math.max(0.3, math.min(box_depth, 4.0))
        
        return box_height, box_width, box_depth
    else
        -- Fallback: Standard-Werte mit Skalierung
        local base_height = default_height or 2.0
        return base_height * scale, 0.6 * scale, 0.6 * scale
    end
end
local function is_stealthed(unit)
    if not unit then
        return false
    end
    local stealth_buff_ids = {1784, 5215}
    if buff_manager and buff_manager.get_buff_data then
        for _, buff_id in ipairs(stealth_buff_ids) do
            local ok, buff_data = pcall(buff_manager.get_buff_data, buff_manager, unit, {buff_id})
            if ok and buff_data and buff_data.is_active then
                return true
            end
        end
    end
    if unit.get_buffs then
        local ok, buffs = pcall(unit.get_buffs, unit)
        if ok and buffs then
            for _, buff in ipairs(buffs) do
                if buff.buff_id then
                    for _, stealth_id in ipairs(stealth_buff_ids) do
                        if buff.buff_id == stealth_id then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Helper: Check if unit is elite
local function is_elite(unit)
    if not unit then
        return false
    end
    
    -- Versuche classification Methode (wenn verfügbar)
    if unit.get_classification then
        local ok, classification = pcall(unit.get_classification, unit)
        if ok and classification then
            -- Elite classification values (können je nach WoW-Version variieren)
            -- 2 = Elite, 3 = Rare Elite, 4 = World Boss, 5 = Rare
            if classification == 2 or classification == 3 or classification == 4 then
                return true
            end
        end
    end
    
    -- Versuche is_elite Methode (direkter Ansatz)
    if unit.is_elite then
        local ok, result = pcall(unit.is_elite, unit)
        if ok and result then
            return true
        end
    end
    
    -- Versuche classification Property (falls als Property verfügbar)
    if unit.classification then
        local ok, classification = pcall(function() return unit.classification end)
        if ok and classification then
            if classification == 2 or classification == 3 or classification == 4 then
                return true
            end
        end
    end
    
    return false
end

-- Helper: Check if unit is rare
local function is_rare(unit)
    if not unit then
        return false
    end
    
    -- Versuche classification Methode (wenn verfügbar)
    if unit.get_classification then
        local ok, classification = pcall(unit.get_classification, unit)
        if ok and classification then
            -- Rare classification values: 3 = Rare Elite, 5 = Rare
            if classification == 3 or classification == 5 then
                return true
            end
        end
    end
    
    -- Versuche is_rare Methode (direkter Ansatz)
    if unit.is_rare then
        local ok, result = pcall(unit.is_rare, unit)
        if ok and result then
            return true
        end
    end
    
    -- Versuche classification Property (falls als Property verfügbar)
    if unit.classification then
        local ok, classification = pcall(function() return unit.classification end)
        if ok and classification then
            if classification == 3 or classification == 5 then
                return true
            end
        end
    end
    
    return false
end

-- Helper: Check if unit is boss
local function is_boss(unit)
    if not unit then
        return false
    end
    
    -- Versuche classification Methode (wenn verfügbar)
    if unit.get_classification then
        local ok, classification = pcall(unit.get_classification, unit)
        if ok and classification then
            -- Boss classification values: 4 = World Boss
            if classification == 4 then
                return true
            end
        end
    end
    
    -- Versuche is_boss Methode (direkter Ansatz)
    if unit.is_boss then
        local ok, result = pcall(unit.is_boss, unit)
        if ok and result then
            return true
        end
    end
    
    -- Versuche classification Property (falls als Property verfügbar)
    if unit.classification then
        local ok, classification = pcall(function() return unit.classification end)
        if ok and classification then
            if classification == 4 then
                return true
            end
        end
    end
    
    return false
end

local function is_behind_wall(player_pos, obj_pos, obj)
    if not player_pos or not obj_pos then
        return false
    end
    if core and core.raycast then
        local ok, result = pcall(core.raycast, player_pos, obj_pos)
        if ok and result == false then
            return true
        end
    end
    if core and core.line_of_sight then
        local ok, result = pcall(core.line_of_sight, player_pos, obj_pos)
        if ok and result == false then
            return true
        end
    end
    if obj then
        if obj.is_visible then
            local ok, result = pcall(obj.is_visible, obj)
            if ok and result == false then
                return true
            end
        end
        if obj.is_in_los then
            local ok, result = pcall(obj.is_in_los, obj)
            if ok and result == false then
                return true
            end
        end
    end
    if core and core.graphics and core.graphics.raycast then
        local ok, result = pcall(core.graphics.raycast, player_pos, obj_pos)
        if ok and result == false then
            return true
        end
    end
    return false
end
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj:is_valid() then
            local is_unit_obj = false
            if obj.is_unit then
                local ok, res = pcall(obj.is_unit, obj)
                if ok then is_unit_obj = res end
            end
            local gather_type, gather_name = nil, nil
            if not is_unit_obj then
                gather_type, gather_name = classify_gather_node(obj)
            end
            -- Für Chests: Nur anzeigen wenn sie interagierbar sind (can_be_used)
            local chest_interactable = true
            if gather_type == "chest" then
                if obj.can_be_used then
                    local ok_use, can_use = pcall(obj.can_be_used, obj)
                    if ok_use then
                        chest_interactable = can_use
                    end
                end
            end
            
            -- Gathering Mode Filter: Wenn aktiv, nur aktivierte Typen anzeigen
            local gathering_mode_pass = true
            if is_gathering_mode_active() then
                if gather_type == "herb" then
                    gathering_mode_pass = gathering_mode_allows_type("herb")
                elseif gather_type == "mining" then
                    gathering_mode_pass = gathering_mode_allows_type("ore")
                elseif gather_type == "chest" then
                    gathering_mode_pass = gathering_mode_allows_type("chest")
                elseif gather_type == "fishing" then
                    gathering_mode_pass = gathering_mode_allows_type("fish")
                end
            end
            
            local should_render_gathering = gathering_mode_pass and (
                                          (gather_type == "herb" and show_herbs) or
                                          (gather_type == "mining" and show_mining) or
                                          (gather_type == "chest" and show_chests and chest_interactable) or
                                          (gather_type == "fishing" and show_fishing))
            if should_render_gathering then
                local obj_pos = nil
                if obj.get_position then
                    local okp, result = pcall(obj.get_position, obj)
                    if okp and result and result.x and result.y then
                        obj_pos = result
                    end
                end
                if obj_pos then
                    local dx = obj_pos.x - player_pos.x
                    local dy = obj_pos.y - player_pos.y
                    local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                    
                    -- Cave Mode Filter für Gathering
                    local cave_mode_pass_gather = true
                    local player_facing_gather = nil
                    if local_player and local_player.get_facing then
                        local ok_f, f = pcall(local_player.get_facing, local_player)
                        if ok_f then player_facing_gather = f end
                    end
                    cave_mode_pass_gather = cave_mode_filter(obj_pos, player_pos, player_facing_gather)
                    
                    if distance <= max_distance and cave_mode_pass_gather then
                        local render_z = obj_pos.z or 0
                        if gather_type == "fishing" then
                            if core.get_height_for_position then
                                local test_z = obj_pos.z or player_pos.z or 0
                                local ok_height, height = pcall(core.get_height_for_position, { x = obj_pos.x, y = obj_pos.y, z = test_z })
                                if ok_height and height and height > 0 then
                                    render_z = height - 0.3
                                elseif obj_pos.z and obj_pos.z > 0 then
                                    render_z = obj_pos.z - 0.3
                                else
                                    local ok_height2, height2 = pcall(core.get_height_for_position, { x = obj_pos.x, y = obj_pos.y, z = player_pos.z or 0 })
                                    if ok_height2 and height2 and height2 > 0 then
                                        render_z = height2 - 0.3
                                    else
                                        render_z = obj_pos.z or 0
                                    end
                                end
                            elseif obj_pos.z and obj_pos.z > 0 then
                                render_z = obj_pos.z - 0.3
                            else
                                render_z = obj_pos.z or 0
                            end
                        else
                            if render_z == 0 then
                                render_z = player_pos.z or 0
                            end
                        end
                        local render_pos = { x = obj_pos.x, y = obj_pos.y, z = render_z }
                        -- Farben werden jetzt direkt vor der Verwendung gelesen (live aus dem Color-Picker)
                        local g_color = nil
                        if gather_type == "herb" then
                            g_color = get_safe_color(menu_elements.herb_color, color.new(0, 190, 255, 255))
                        elseif gather_type == "mining" then
                            g_color = get_safe_color(menu_elements.mining_color, color.new(200, 180, 80, 255))
                        elseif gather_type == "chest" then
                            g_color = get_safe_color(menu_elements.chest_color, color.new(255, 215, 0, 255))
                        elseif gather_type == "fishing" then
                            g_color = get_safe_color(menu_elements.fishing_color, color.new(80, 170, 255, 255))
                        end
                        if g_color then
                            -- Range-Check (out of range = 30% Alpha)
                            local gather_max_range = 35.0
                            local is_gather_in_range = true
                            if distance and type(distance) == "number" then
                                is_gather_in_range = (distance <= gather_max_range)
                            end
                            
                            -- Wenn in-range: verwende Originalfarbe direkt (Live-Updates!)
                            -- Wenn out-of-range: erstelle neue Farbe mit 30% Alpha
                            local render_g_color = g_color
                            if not is_gather_in_range then
                                local gr, gg, gb, ga = get_color_rgba(g_color)
                                if gr and gg and gb then
                                    local final_alpha = math.floor((ga or 255) * 0.30)
                                    render_g_color = color.new(gr, gg, gb, final_alpha)
                                end
                            end
                            
                            -- Wabernde Fläche unter dem Gathering-Objekt (basierend auf aurora/aurora_system.lua)
                            local time = (core.game_time and core.game_time() or 0) / 1000
                            
                            -- Flächen-Parameter
                            local surface_radius = gathering_radius or 1.5
                            local grid_resolution = 16  -- Anzahl der Punkte pro Achse (mehr = feinere Fläche)
                            local wave_frequency = 2.5  -- Frequenz der Wellen
                            local wave_amplitude = 0.15  -- Amplitude der Wellen (Höhe der Waberung)
                            local wave_speed = 1.2  -- Geschwindigkeit der Wellen
                            local base_z_offset = -0.1  -- Z-Offset unter dem Objekt
                            
                            -- Extrahiere RGB aus render_g_color
                            local r, g, b, a = get_color_rgba(render_g_color)
                            if r and g and b and core and core.graphics then
                                -- Erstelle Gitter von Punkten für die wabernde Fläche
                                local points = {}
                                for i = 0, grid_resolution do
                                    points[i] = {}
                                    local u = (i / grid_resolution) * 2 - 1  -- -1 bis 1
                                    
                                    for j = 0, grid_resolution do
                                        local v = (j / grid_resolution) * 2 - 1  -- -1 bis 1
                                        
                                        -- Distanz vom Zentrum
                                        local dist = math.sqrt(u * u + v * v)
                                        
                                        -- Nur Punkte innerhalb des Radius
                                        if dist <= 1.0 then
                                            -- Wabernde Wellen-Effekte
                                            local wave1 = math.sin(dist * wave_frequency * math.pi - time * wave_speed)
                                            local wave2 = math.sin((u * wave_frequency * 2 + time * wave_speed * 0.7))
                                            local wave3 = math.sin((v * wave_frequency * 2 + time * wave_speed * 0.9))
                                            local height_offset = (wave1 + wave2 * 0.5 + wave3 * 0.5) * wave_amplitude
                                            
                                            -- Punkt-Position auf der wabernden Fläche
                                            local point_pos = {
                                                x = render_pos.x + u * surface_radius,
                                                y = render_pos.y + v * surface_radius,
                                                z = render_pos.z + base_z_offset + height_offset
                                            }
                                            
                                            -- Farbe basierend auf Distanz (zentrum heller, aber weniger grell)
                                            local dist_factor = 1.0 - (dist * 0.3)
                                            local color_factor = 0.4 + (dist_factor * 0.2)  -- Reduzierte Helligkeit
                                            local point_color = color.new(
                                                math.floor(r * color_factor),
                                                math.floor(g * color_factor),
                                                math.floor(b * color_factor),
                                                math.floor((a or 180) * 0.5)  -- Reduzierte Transparenz (weniger sichtbar)
                                            )
                                            
                                            points[i][j] = { pos = point_pos, color = point_color }
                                        end
                                    end
                                end
                                
                                -- Zeichne die Fläche mit Linien zwischen benachbarten Punkten
                                if core.graphics.line_3d then
                                    for i = 0, grid_resolution - 1 do
                                        for j = 0, grid_resolution - 1 do
                                            if points[i] and points[i][j] and points[i + 1] and points[i + 1][j] then
                                                -- Horizontale Linie
                                                pcall(core.graphics.line_3d, 
                                                    points[i][j].pos, 
                                                    points[i + 1][j].pos, 
                                                    points[i][j].color, 
                                                    1.5  -- Dünnere Linien
                                                )
                                            end
                                            if points[i] and points[i][j] and points[i] and points[i][j + 1] then
                                                -- Vertikale Linie
                                                pcall(core.graphics.line_3d, 
                                                    points[i][j].pos, 
                                                    points[i][j + 1].pos, 
                                                    points[i][j].color, 
                                                    1.5  -- Dünnere Linien
                                                )
                                            end
                                        end
                                    end
                                end
                            end
                            
                            -- Label rendern
                            local label = gather_name or "Node"
                            if core.graphics.text_3d then
                                draw_text_3d_outlined(label, { x = render_pos.x, y = render_pos.y, z = render_pos.z + 1.2 }, 12, render_g_color, true)
                            end
                            
                            -- Traceline rendern (gleiche Farbe!)
                            local show_tracelines_gathering = false
                            if menu_elements.show_tracelines_gathering and menu_elements.show_tracelines_gathering.get_state then
                                local ok, val = pcall(menu_elements.show_tracelines_gathering.get_state, menu_elements.show_tracelines_gathering)
                                if ok and val ~= nil then
                                    show_tracelines_gathering = val
                                end
                            end
                            if show_tracelines_gathering and core.graphics.line_3d then
                                -- Traceline verwendet dieselbe Farbe wie Kreis und Label!
                                -- Prüfe ob solid oder dotted
                                local use_solid_line = false
                                if menu_elements.gathering_traceline_solid and menu_elements.gathering_traceline_solid.get_state then
                                    local ok, val = pcall(menu_elements.gathering_traceline_solid.get_state, menu_elements.gathering_traceline_solid)
                                    if ok and val ~= nil then
                                        use_solid_line = val
                                    end
                                end
                                
                                if use_solid_line then
                                    -- Ganze durchgehende Linie
                                    local line_thickness = gathering_thickness or 1.5
                                    pcall(core.graphics.line_3d, render_pos, player_pos, render_g_color, line_thickness)
                                else
                                    -- Gepunktete Linie
                                    draw_traceline_dots(render_pos, player_pos, render_g_color, 1.6, 0.15)
                                end
                                
                                -- Traceline-Label (optional)
                                local show_traceline_labels = true
                                if menu_elements.show_traceline_labels and menu_elements.show_traceline_labels.get_state then
                                    local ok, val = pcall(menu_elements.show_traceline_labels.get_state, menu_elements.show_traceline_labels)
                                    if ok and val ~= nil then
                                        show_traceline_labels = val
                                    end
                                end
                                if show_traceline_labels then
                                    local mid_x = (render_pos.x + player_pos.x) / 2
                                    local mid_y = (render_pos.y + player_pos.y) / 2
                                    local mid_z = ((render_pos.z or 0) + (player_pos.z or 0)) / 2
                                    local icon_world_pos = { x = mid_x, y = mid_y, z = mid_z + 0.5 }
                                    local icon_screen = world_to_screen_2d(icon_world_pos)
                                    
                                    if icon_screen then
                                        -- Prüfe ob "Show Icon Instead of Text" für alle Gathering-Typen aktiviert ist
                                        local show_texture_icon = false
                                        local texture_key = nil
                                        
                                        if gather_type == "herb" and menu_elements.show_herb_icon_instead_of_text and menu_elements.show_herb_icon_instead_of_text.get_state then
                                            local ok, val = pcall(menu_elements.show_herb_icon_instead_of_text.get_state, menu_elements.show_herb_icon_instead_of_text)
                                            if ok and val ~= nil and val then
                                                show_texture_icon = true
                                                texture_key = "herbs"
                                            end
                                        elseif gather_type == "mining" and menu_elements.show_mining_icon_instead_of_text and menu_elements.show_mining_icon_instead_of_text.get_state then
                                            local ok, val = pcall(menu_elements.show_mining_icon_instead_of_text.get_state, menu_elements.show_mining_icon_instead_of_text)
                                            if ok and val ~= nil and val then
                                                show_texture_icon = true
                                                texture_key = "mining"
                                            end
                                        elseif gather_type == "chest" and menu_elements.show_chest_icon_instead_of_text and menu_elements.show_chest_icon_instead_of_text.get_state then
                                            local ok, val = pcall(menu_elements.show_chest_icon_instead_of_text.get_state, menu_elements.show_chest_icon_instead_of_text)
                                            if ok and val ~= nil and val then
                                                show_texture_icon = true
                                                texture_key = "chest"
                                            end
                                        elseif gather_type == "fishing" and menu_elements.show_fish_icon_instead_of_text and menu_elements.show_fish_icon_instead_of_text.get_state then
                                            local ok, val = pcall(menu_elements.show_fish_icon_instead_of_text.get_state, menu_elements.show_fish_icon_instead_of_text)
                                            if ok and val ~= nil and val then
                                                show_texture_icon = true
                                                texture_key = "fish"
                                            end
                                        end
                                        
                                        -- Wenn Texture-Icon aktiviert und verfügbar: Verwende Texture (ohne Tint, Original-Farbe, aber mit Distanz-Alpha)
                                        local texture_drawn = false
                                        if show_texture_icon and texture_key then
                                            local icon_size = 36
                                            local icon_pos = vec2_new(icon_screen.x, icon_screen.y)
                                            -- Alpha aus render_g_color übernehmen (für Distanz-Transparenz)
                                            local _, _, _, icon_alpha = get_color_rgba(render_g_color)
                                            -- Weiß ohne Tint (Original-Farbe), aber mit Distanz-basiertem Alpha
                                            local tint_color = color.new(255, 255, 255, icon_alpha or 255)
                                            texture_drawn = draw_texture(texture_key, icon_pos, icon_size, icon_size, tint_color)
                                        end
                                        
                                        -- Fallback zu Text/Icons wenn Texture nicht verfügbar oder nicht gezeichnet wurde
                                        if not texture_drawn then
                                            -- Normale Icon/Text-Logik
                                            local icon_image = nil
                                            local has_icon = false
                                            
                                            if gather_type == "herb" then
                                                icon_image = gathering_icons.herb
                                                has_icon = true
                                            elseif gather_type == "mining" then
                                                icon_image = gathering_icons.mining
                                                has_icon = true
                                            end
                                            
                                            -- Wenn Icon verfügbar: Bild rendern, sonst Text
                                            if has_icon and icon_image and core.graphics and core.graphics.draw_image then
                                                local icon_size = 32
                                                local icon_pos = vec2_new(icon_screen.x - icon_size * 0.5, icon_screen.y - icon_size * 0.5)
                                                pcall(core.graphics.draw_image, icon_image, icon_pos)
                                            elseif core.graphics.text_3d then
                                                -- Fallback: Text rendern
                                                local text_pos = { x = mid_x, y = mid_y, z = mid_z }
                                                local label_text = "Node"
                                                if gather_type == "herb" then
                                                    label_text = "Herb"
                                                elseif gather_type == "mining" then
                                                    label_text = "Ore"
                                                elseif gather_type == "chest" then
                                                    label_text = "Chest"
                                                elseif gather_type == "fishing" then
                                                    label_text = "Fishing"
                                                end
                                                draw_text_3d_outlined(label_text, text_pos, 16, render_g_color, true)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if not is_unit_obj then
                local gather_type, gather_name = classify_gather_node(obj)
                local is_gathering = gather_type ~= nil
                if not is_gathering then
                    local is_quest_item = false
                    local quest_item_ids = nil
                    if show_quest_mobs then
                        is_quest_item = is_quest_object(obj)
                        if is_quest_item then
                            quest_item_ids = get_quest_ids_for_object(obj)
                        end
                        -- Spieler-Pets nicht als Quest-Objekte anzeigen
                        if is_quest_item and is_player_pet(obj) then
                            is_quest_item = false
                            quest_item_ids = nil
                        end
                    end
                    if is_quest_item then
                        local obj_pos = nil
                        if obj.get_position then
                            local okp, result = pcall(obj.get_position, obj)
                            if okp and result and result.x and result.y then
                                obj_pos = result
                            end
                        end
                        if obj_pos then
                            local dx = obj_pos.x - player_pos.x
                            local dy = obj_pos.y - player_pos.y
                            local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                            local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                            if distance <= max_distance then
                                local render_z = obj_pos.z or 0
                                if render_z == 0 then
                                    render_z = player_pos.z or 0
                                end
                                local render_pos = { x = obj_pos.x, y = obj_pos.y, z = render_z }
                                -- Farbe wird jetzt direkt vor der Verwendung gelesen (live aus dem Color-Picker)
                                local quest_item_color = get_safe_color(menu_elements.quest_item_color, color.new(255, 215, 0, 255))
                                pcall(core.graphics.circle_3d, render_pos, gathering_radius, quest_item_color, gathering_thickness, 24)
                                
                                -- 3D Cone (gefüllter Kreis am Boden, wie bei Gathering)
                                if core.graphics and core.graphics.cone_3d then
                                    -- Alpha für den gefüllten Kreis (etwas transparenter als die Linie)
                                    local cone_r, cone_g, cone_b, cone_a = get_color_rgba(quest_item_color)
                                    local cone_alpha = math.floor((cone_a or 255) * 0.35)  -- 35% Alpha für gefüllten Kreis
                                    local cone_fill_color = color.new(cone_r or 255, cone_g or 255, cone_b or 255, cone_alpha)
                                    
                                    -- Zielposition für cone_3d (Richtung)
                                    local target_pos = {
                                        x = render_pos.x + 1,
                                        y = render_pos.y,
                                        z = render_pos.z
                                    }
                                    
                                    -- cone_3d mit 360° = voller Kreis
                                    local cone_radius = gathering_radius * 0.9  -- Etwas kleiner als der Kreis-Rand
                                    pcall(core.graphics.cone_3d, render_pos, target_pos, cone_radius, 360, cone_fill_color, 1.5)
                                end
                                
                                local item_name = "Quest Item"
                                if obj.get_name then
                                    local ok_name, name_result = pcall(obj.get_name, obj)
                                    if ok_name and name_result then
                                        item_name = name_result
                                    end
                                end
                                if core.graphics.text_3d then
                                    -- Prüfe ob "Show Icon Instead of Text" für Quest-Items aktiviert ist
                                    local show_questitem_icon = false
                                    if menu_elements.show_questitem_icon_instead_of_text and menu_elements.show_questitem_icon_instead_of_text.get_state then
                                        local ok, val = pcall(menu_elements.show_questitem_icon_instead_of_text.get_state, menu_elements.show_questitem_icon_instead_of_text)
                                        if ok and val ~= nil then
                                            show_questitem_icon = val
                                        end
                                    end
                                    
                                    -- Wenn Icon aktiviert ist, zeige nur den Item-Namen (ohne "(QUEST)")
                                    -- Wenn Icon nicht aktiviert ist, zeige Namen mit "(QUEST)"
                                    local quest_item_text = item_name
                                    if not show_questitem_icon then
                                        if quest_item_ids and #quest_item_ids > 0 then
                                            quest_item_text = string.format("%s (QUEST %s)", item_name, table.concat(quest_item_ids, ","))
                                        else
                                            quest_item_text = string.format("%s (QUEST)", item_name)
                                        end
                                    end
                                    
                                    local symbol_color = color.new(255, 215, 0, 255)
                                    local symbol_pos = { x = render_pos.x, y = render_pos.y, z = render_pos.z + 1.5 }
                                    draw_text_3d_outlined("☠", symbol_pos, 20, symbol_color, true)
                                    local text_pos = { x = render_pos.x, y = render_pos.y, z = render_pos.z + 1.2 }
                                    draw_text_3d_outlined(quest_item_text, text_pos, 12, quest_item_color, true)
                                end
                                    local show_tracelines_questitems = false
                                    if menu_elements.show_tracelines_questitems and menu_elements.show_tracelines_questitems.get_state then
                                        local ok, val = pcall(menu_elements.show_tracelines_questitems.get_state, menu_elements.show_tracelines_questitems)
                                        if ok and val ~= nil then
                                            show_tracelines_questitems = val
                                        end
                                    end
                                    if show_tracelines_questitems and core.graphics.line_3d then
                                    local enable_distance_fading = true
                                    if menu_elements.enable_distance_fading and menu_elements.enable_distance_fading.get_state then
                                        local ok, val = pcall(menu_elements.enable_distance_fading.get_state, menu_elements.enable_distance_fading)
                                        if ok and val ~= nil then
                                            enable_distance_fading = val
                                        end
                                    end
                                    local traceline_color = get_safe_color(menu_elements.quest_item_color, color.new(255, 215, 0, 255))
                                    if enable_distance_fading then
                                        traceline_color = apply_distance_fading(traceline_color, distance, max_distance, 100)
                                    end
                                    -- Alpha basierend auf Range (30% wenn out of range, 30.0 Yard) - direkt in color.new() setzen
                                    local max_range = 35.0
                                    local is_in_range = true
                                    if distance and type(distance) == "number" then
                                        is_in_range = (distance <= max_range)
                                    end
                                    local alpha_multiplier = is_in_range and 1.0 or 0.30
                                    local base_alpha = safe_get_alpha(traceline_color, 255)
                                    local new_alpha = math.floor(base_alpha * alpha_multiplier)
                                    local qir, qig, qib = safe_get_rgb(traceline_color, 255, 215, 0)
                                    traceline_color = color.new(qir, qig, qib, new_alpha)
                                    draw_traceline_dots(render_pos, player_pos, traceline_color, 1.4, 0.15)
                                    local show_traceline_labels = true
                                    if menu_elements.show_traceline_labels and menu_elements.show_traceline_labels.get_state then
                                        local ok, val = pcall(menu_elements.show_traceline_labels.get_state, menu_elements.show_traceline_labels)
                                        if ok and val ~= nil then
                                            show_traceline_labels = val
                                        end
                                    end
                                    if show_traceline_labels then
                                        local mid_x = (render_pos.x + player_pos.x) / 2
                                        local mid_y = (render_pos.y + player_pos.y) / 2
                                        local mid_z = ((render_pos.z or 0) + (player_pos.z or 0)) / 2
                                        
                                        -- Prüfe ob "Show Icon Instead of Text" für Quest-Items aktiviert ist
                                        local show_questitem_icon = false
                                        if menu_elements.show_questitem_icon_instead_of_text and menu_elements.show_questitem_icon_instead_of_text.get_state then
                                            local ok, val = pcall(menu_elements.show_questitem_icon_instead_of_text.get_state, menu_elements.show_questitem_icon_instead_of_text)
                                            if ok and val ~= nil then
                                                show_questitem_icon = val
                                            end
                                        end
                                        
                                        -- Wenn Icon-Toggle aktiv: Versuche Texture zu verwenden
                                        local texture_drawn = false
                                        local icon_available = false
                                        if show_questitem_icon then
                                            icon_available = true
                                            local icon_world_pos = { x = mid_x, y = mid_y, z = mid_z + 0.5 }
                                            local icon_screen = world_to_screen_2d(icon_world_pos)
                                            if icon_screen then
                                                local icon_size = 36
                                                local icon_pos = vec2_new(icon_screen.x, icon_screen.y)
                                                -- Alpha aus traceline_color übernehmen (für Distanz-Transparenz)
                                                local _, _, _, icon_alpha = get_color_rgba(traceline_color)
                                                -- Weiß ohne Tint (Original-Farbe), aber mit Distanz-basiertem Alpha
                                                local tint_color = color.new(255, 255, 255, icon_alpha or 255)
                                                texture_drawn = draw_texture("quest", icon_pos, icon_size, icon_size, tint_color)
                                            end
                                        end
                                        
                                        -- Fallback: Text rendern nur wenn Icon nicht aktiv ODER Icon nicht verfügbar
                                        -- Wenn Icon aktiv ist UND verfügbar, wird kein Text angezeigt (auch wenn Zeichnen fehlschlug)
                                        if not show_questitem_icon or not icon_available then
                                            if core.graphics and core.graphics.text_3d then
                                                local text_pos = { x = mid_x, y = mid_y, z = mid_z }
                                                draw_text_3d_outlined("Quest Item", text_pos, 16, traceline_color, true)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if obj.is_unit and obj:is_unit() then
            local is_dead = false
            if obj.is_dead then
                local ok, result = pcall(obj.is_dead, obj)
                if ok then
                    is_dead = result
                end
            end
            local is_enemy = false
            if obj.is_enemy_with then
                local ok, result = pcall(obj.is_enemy_with, obj, local_player)
                if ok then
                    is_enemy = result
                end
            end
            -- Spieler-Pets nicht als Feinde anzeigen
            if is_enemy and is_player_pet(obj) then
                is_enemy = false
            end
            local is_quest_obj = false
            local quest_ids = nil
            if show_quest_mobs then
                is_quest_obj = is_quest_object(obj)
                if is_quest_obj then
                    quest_ids = get_quest_ids_for_object(obj)
                end
            end
            -- Spieler-Pets nicht als Quest-Objekte anzeigen
            if is_quest_obj and is_player_pet(obj) then
                is_quest_obj = false
                quest_ids = nil
            end
            -- Gathering Mode: Überspringe Enemy/Quest-Mob Rendering
            if is_gathering_mode_active() and (is_enemy or is_quest_obj) then
                goto continue_entity_loop
            end
            
            if (is_enemy or is_quest_obj) and not is_dead then
                -- Prüfe ob Unit im Kampf ist (einmal für alle Verwendungen)
                local is_in_combat = is_unit_in_combat(obj)
                
                local is_stealthed_enemy = false
                if is_enemy then
                    is_stealthed_enemy = is_stealthed(obj)
                end
                local obj_pos = nil
                if obj.get_position then
                    local ok, result = pcall(obj.get_position, obj)
                    if ok and result and result.x and result.y then
                        obj_pos = result
                    end
                end
                if obj_pos then
                    local dx = obj_pos.x - player_pos.x
                    local dy = obj_pos.y - player_pos.y
                    local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                    
                    -- Cave Mode Filter
                    local cave_mode_pass = true
                    local player_facing = nil
                    if local_player and local_player.get_facing then
                        local ok_f, f = pcall(local_player.get_facing, local_player)
                        if ok_f then player_facing = f end
                    end
                    cave_mode_pass = cave_mode_filter(obj_pos, player_pos, player_facing)
                    
                    if distance <= max_distance and cave_mode_pass then
                        local render_z = obj_pos.z or 0
                        if render_z == 0 then
                            render_z = player_pos.z or 0
                        end
                        local render_pos = { x = obj_pos.x, y = obj_pos.y, z = render_z }
                        local is_targeting_player = false
                        if obj.get_target then
                            local ok_target, target = pcall(obj.get_target, obj)
                            if ok_target and target then
                                if (__object_safety.same(target,local_player)) then
                                    is_targeting_player = true
                                elseif target.get_guid and local_player.get_guid then
                                    local ok_guid1, guid1 = pcall(target.get_guid, target)
                                    local ok_guid2, guid2 = pcall(local_player.get_guid, local_player)
                                    if ok_guid1 and ok_guid2 and guid1 == guid2 then
                                        is_targeting_player = true
                                    end
                                end
                            end
                        end
                        -- Prüfen ob dieses Objekt das aktuelle Target des Spielers ist
                        local is_player_target = false
                        if player_target then
                            if (__object_safety.same(obj,player_target)) then
                                is_player_target = true
                            elseif player_target_guid and obj.get_guid then
                                local ok_guid, obj_guid = pcall(obj.get_guid, obj)
                                if ok_guid and obj_guid and obj_guid == player_target_guid then
                                    is_player_target = true
                                end
                            end
                        end
                        local stealth_color_value = get_safe_color(menu_elements.stealth_color, color.new(255, 0, 255, 255))
                        
                        -- Prüfe ob Einheit Boss, Elite oder Rare ist
                        local is_boss_unit = is_boss(obj)
                        local is_elite_unit = is_elite(obj)
                        local is_rare_unit = is_rare(obj)
                        
                        -- Farben werden jetzt direkt vor der Verwendung gelesen (live aus dem Color-Picker)
                        -- Hole Originalfarbe direkt vom Color Picker (LIVE!)
                        local current_enemy_color = get_safe_color(menu_elements.enemy_color, color.new(255, 0, 0, 255))
                        
                        if is_boss_unit then
                            current_enemy_color = get_safe_color(menu_elements.boss_color, color.new(255, 0, 0, 255))
                        elseif is_rare_unit then
                            current_enemy_color = get_safe_color(menu_elements.rare_color, color.new(255, 215, 0, 255))
                        elseif is_elite_unit then
                            current_enemy_color = get_safe_color(menu_elements.elite_color, color.new(255, 165, 0, 255))
                        elseif is_stealthed_enemy then
                            current_enemy_color = stealth_color_value
                        elseif is_targeting_player then
                            current_enemy_color = get_safe_color(menu_elements.targeting_color, color.new(255, 0, 0, 255))
                        elseif is_quest_obj then
                            current_enemy_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
                        end
                        
                        local show_tracelines_all = false
                        if menu_elements.show_tracelines_all and menu_elements.show_tracelines_all.get_state then
                            local ok, val = pcall(menu_elements.show_tracelines_all.get_state, menu_elements.show_tracelines_all)
                            if ok and val ~= nil then
                                show_tracelines_all = val
                            end
                        end
                        local enable_distance_fading = true
                        if menu_elements.enable_distance_fading and menu_elements.enable_distance_fading.get_state then
                            local ok, val = pcall(menu_elements.enable_distance_fading.get_state, menu_elements.enable_distance_fading)
                            if ok and val ~= nil then
                                enable_distance_fading = val
                            end
                        end
                        
                        -- Range-Berechnung
                        local max_range = 35.0
                        local is_enemy_in_range = is_in_range_check(obj, obj_pos, max_range)
                        
                        -- Nur wenn Fading oder out-of-range: Alpha modifizieren
                        -- Sonst: Originalfarbe direkt verwenden (Live-Updates!)
                        if enable_distance_fading or not is_enemy_in_range then
                            local er, eg, eb, ea = get_color_rgba(current_enemy_color)
                            if er and eg and eb then
                                -- Distance Fading berechnen
                                local fading_factor = 1.0
                                if enable_distance_fading then
                                    local min_alpha = 120
                                    fading_factor = math.max(min_alpha / 255, 1.0 - (distance / max_distance) * (1.0 - min_alpha / 255))
                                end
                                
                                -- Out-of-range Multiplier
                                local range_multiplier = is_enemy_in_range and 1.0 or 0.30
                                
                                -- Finales Alpha
                                local final_alpha = math.floor((ea or 255) * fading_factor * range_multiplier)
                                if final_alpha < 0 then final_alpha = 0 end
                                if final_alpha > 255 then final_alpha = 255 end
                                
                                current_enemy_color = color.new(er, eg, eb, final_alpha)
                            end
                        end
                        if is_enemy and show_danger_zones then
                            local actual_aggro_radius = base_danger_zone_radius
                            local mob_level = nil
                            if obj.get_level then
                                local ok_ml, ml = pcall(obj.get_level, obj)
                                if ok_ml and ml then
                                    mob_level = ml
                                end
                            elseif obj.level then
                                local ok_ml, ml = pcall(obj.level, obj)
                                if ok_ml and ml then
                                    mob_level = ml
                                end
                            end
                            local level_diff = 0
                            if player_level and mob_level then
                                level_diff = mob_level - player_level
                            end
                            local level_scale = 1.0 + math.max(level_diff, 0) * 0.15
                            actual_aggro_radius = actual_aggro_radius * danger_zone_scale * level_scale
                            if actual_aggro_radius < 1.0 then
                                actual_aggro_radius = 1.0
                            elseif actual_aggro_radius > 60.0 then
                                actual_aggro_radius = 60.0
                            end
                            -- Rendere Danger Zone
                            if core.graphics and core.graphics.cone_3d then
                                -- Hole Danger Zone Farbe live aus dem Color-Picker (wie andere Farben auch)
                                local fill_color = get_live_color(menu_elements.danger_zone_color, color.new(255, 165, 0, 255))
                                
                                -- Zielposition für cone_3d (Richtung)
                                local target_pos = {
                                    x = render_pos.x + 1,
                                    y = render_pos.y,
                                    z = render_pos.z
                                }
                                
                                -- Glatter gefüllter Kreis mit cone_3d (360° = voller Kreis)
                                pcall(core.graphics.cone_3d, render_pos, target_pos, actual_aggro_radius, 360, fill_color, 1.5)
                            end
                            
                            -- Warnung wenn Spieler in Zone
                            if distance <= actual_aggro_radius and core.graphics and core.graphics.cone_3d then
                                local warning_color = color.new(255, 50, 50, 120)
                                
                                local target_pos = {
                                    x = render_pos.x + 1,
                                    y = render_pos.y,
                                    z = render_pos.z
                                }
                                
                                pcall(core.graphics.cone_3d, render_pos, target_pos, actual_aggro_radius, 360, warning_color, 1.5)
                            end
                        end
                        -- Enemy Circles entfernt (nur Box ESP und Danger Zone bleiben)
                        local box_esp_all = false
                        if menu_elements.box_esp_all_enemies and menu_elements.box_esp_all_enemies.get_state then
                            local ok, val = pcall(menu_elements.box_esp_all_enemies.get_state, menu_elements.box_esp_all_enemies)
                            if ok and val ~= nil then
                                box_esp_all = val
                            end
                        end
                        
                        -- PvP-Filterung: Wenn "Use only Enemy ESP" aktiviert ist, NUR feindliche Spieler anzeigen (keine NPCs/Mobs)
                        local should_draw_box = false
                        local use_only_enemy_esp = false
                        if pvp_module and pvp_module.should_show_only_enemy_players then
                            use_only_enemy_esp = pvp_module.should_show_only_enemy_players()
                        end
                        
                        if use_only_enemy_esp then
                            -- PvP MODUS: NUR feindliche SPIELER anzeigen (KEINE Mobs/NPCs!)
                            if is_enemy then
                                -- Alle Methoden zur Spieler-Erkennung versuchen
                                local detected_as_player = false
                                local detection_method = "none"
                                
                                -- Methode 1: is_player() direkt
                                if obj.is_player then
                                    local ok, result = pcall(obj.is_player, obj)
                                    if ok and result == true then
                                        detected_as_player = true
                                        detection_method = "is_player()"
                                    end
                                end
                                
                                -- Methode 2: get_unit_type == 1
                                if not detected_as_player and obj.get_unit_type then
                                    local ok, unit_type = pcall(obj.get_unit_type, obj)
                                    if ok and unit_type == 1 then
                                        detected_as_player = true
                                        detection_method = "unit_type==1"
                                    end
                                end
                                
                                -- Methode 3: Prüfe ob es KEIN NPC ist (unit_type != 3)
                                -- In WoW: 0=Object, 1=Player, 2=??, 3=NPC, 4=??, 5=??, 8=Pet
                                if not detected_as_player and obj.get_unit_type then
                                    local ok, unit_type = pcall(obj.get_unit_type, obj)
                                    if ok and unit_type ~= nil then
                                        -- unit_type check ohne Debug-Log
                                    end
                                end
                                
                                if detected_as_player then
                                    should_draw_box = true
                                end
                            end
                        else
                            -- NORMALES Verhalten (PvP deaktiviert): Alle Feinde anzeigen ODER wenn es ein Quest-Objekt ist
                            should_draw_box = box_esp_all or is_quest_obj
                        end
                        
                        -- Quest-Mob Symbol (☠) und Info - IMMER anzeigen wenn enabled, unabhängig von Box ESP
                        if is_quest_obj and not is_dead and core.graphics then
                            local show_q_symbol = true
                            if menu_elements.show_quest_symbol and menu_elements.show_quest_symbol.get_state then
                                local ok, val = pcall(menu_elements.show_quest_symbol.get_state, menu_elements.show_quest_symbol)
                                if ok and val ~= nil then show_q_symbol = val end
                            end
                            
                            if show_q_symbol then
                                local q_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
                                local q_symbol_pos = { x = render_pos.x, y = render_pos.y, z = render_pos.z + 2.4 }
                                draw_text_3d_outlined("☠", q_symbol_pos, 22, q_color, true)
                                
                                -- Quest-Text (Namen + Quest ID falls verfügbar)
                                local q_text_pos = { x = render_pos.x, y = render_pos.y, z = render_pos.z + 2.0 }
                                local q_display_text = "(QUEST)"
                                if quest_ids and #quest_ids > 0 then
                                    q_display_text = string.format("(QUEST %s)", table.concat(quest_ids, ","))
                                end
                                draw_text_3d_outlined(q_display_text, q_text_pos, 14, q_color, true)
                            end
                        end
                        
                        -- Berechnungen für Box/Arrow (auch für Target Arrow benötigt wenn Box aus ist)
                        local box_height, box_width, box_depth = get_object_size(obj, 2.0)
                        local box_center = {
                            x = render_pos.x,
                            y = render_pos.y,
                            z = render_pos.z + box_height * 0.2 - 0.3
                        }
                        local box_top_z = box_center.z + box_height
                        
                        -- TARGET ARROW: 2D Pfeil über dem aktuellen Target (Immer anzeigen wenn Target)
                        local show_target_arrow_val = true
                        if menu_elements.show_target_arrow and menu_elements.show_target_arrow.get_state then
                            local ok_ta, val_ta = pcall(menu_elements.show_target_arrow.get_state, menu_elements.show_target_arrow)
                            if ok_ta and val_ta ~= nil then
                                show_target_arrow_val = val_ta
                            end
                        end
                        
                        if show_target_arrow_val and is_player_target then
                            -- World-Position für den Pfeil/Icon (über dem Kopf)
                            local arrow_world_pos = { x = box_center.x, y = box_center.y, z = box_top_z + 2.4 }
                            local arrow_screen = world_to_screen_2d(arrow_world_pos)
                            
                            if arrow_screen then
                                -- Prüfe ob "Show Icon Instead of Arrow" aktiviert ist
                                local show_target_icon = false
                                if menu_elements.show_target_icon_instead_of_arrow and menu_elements.show_target_icon_instead_of_arrow.get_state then
                                    local ok, val = pcall(menu_elements.show_target_icon_instead_of_arrow.get_state, menu_elements.show_target_icon_instead_of_arrow)
                                    if ok and val ~= nil then
                                        show_target_icon = val
                                    end
                                end
                                
                                -- Farbe aus Color Picker
                                local arrow_base_color = get_safe_color(menu_elements.target_arrow_color, color.new(255, 220, 0, 255))
                                local ar, ag, ab, aa = get_color_rgba(arrow_base_color)
                                local arrow_alpha = is_enemy_in_range and (aa or 255) or math.floor((aa or 255) * 0.5)
                                local arrow_color = color.new(ar or 255, ag or 220, ab or 0, arrow_alpha)
                                
                                -- Wenn Icon-Toggle aktiv: Versuche Texture zu verwenden, sonst Fallback zu Pfeil
                                local texture_drawn = false
                                if show_target_icon then
                                    local icon_size = 30
                                    local icon_pos = vec2_new(arrow_screen.x - icon_size * 0.5, arrow_screen.y - icon_size * 0.5)
                                    local _, _, _, icon_alpha = get_color_rgba(arrow_color)
                                    local tint_color = color.new(255, 255, 255, icon_alpha or 255)
                                    texture_drawn = draw_texture("target", icon_pos, icon_size, icon_size, tint_color)
                                end
                                
                                -- Fallback: Pfeil rendern wenn Texture nicht verfügbar
                                if not texture_drawn and core.graphics and core.graphics.triangle_2d_filled then
                                    local arrow_tip_y = arrow_screen.y + 12
                                    local arrow_base_y = arrow_screen.y - 3
                                    local arrow_width = 7
                                    local arrow_tip = vec2_new(arrow_screen.x, arrow_tip_y)
                                    local arrow_left = vec2_new(arrow_screen.x - arrow_width, arrow_base_y)
                                    local arrow_right = vec2_new(arrow_screen.x + arrow_width, arrow_base_y)
                                    pcall(core.graphics.triangle_2d_filled, arrow_tip, arrow_left, arrow_right, arrow_color)
                                    
                                    local text_y = arrow_base_y - 18
                                    if core.graphics.text_2d then
                                        local outline_color = color.new(0, 0, 0, arrow_alpha)
                                        local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
                                        for _, off in ipairs(offsets) do
                                            pcall(core.graphics.text_2d, "TARGET", vec2_new(arrow_screen.x + off[1], text_y + off[2]), 16, outline_color, true)
                                        end
                                        pcall(core.graphics.text_2d, "TARGET", vec2_new(arrow_screen.x, text_y), 16, arrow_color, true)
                                    end
                                end
                            end
                        end

                        if should_draw_box then
                                -- Range-Prüfung für ESP Box (Slider-gesteuert)
                                local box_max_range = 35.0  -- Default fallback
                                if menu_elements.box_esp_visibility and menu_elements.box_esp_visibility.get then
                                    local ok, val = pcall(menu_elements.box_esp_visibility.get, menu_elements.box_esp_visibility)
                                    if ok and val and type(val) == "number" then
                                        box_max_range = val
                                    end
                                end
                                local box_in_range = distance <= box_max_range
                                
                                -- Nur rendern wenn in Sichtweite!
                                if box_in_range then
                                
                                -- Farbe wird jetzt direkt vor der Verwendung gelesen (live aus dem Color-Picker)
                                local quest_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
                                local base_box_color = is_quest_obj and quest_color or current_enemy_color
                                local box_color = base_box_color

                                -- Wenn im Kampf: Roter Glow-Effekt für Box
                                if is_in_combat then
                                    box_color = color.new(255, 50, 50, 255)  -- Leuchtendes Rot
                                    box_thickness = 3.5  -- Dickere Linie für bessere Sichtbarkeit
                                else
                                    box_thickness = 2.0
                                end
                                
                                if menu_elements.box_esp_thickness and menu_elements.box_esp_thickness.get then
                                    local ok, val = pcall(menu_elements.box_esp_thickness.get, menu_elements.box_esp_thickness)
                                    if ok and val and type(val) == "number" then
                                        if not is_in_combat then  -- Nur überschreiben wenn nicht im Kampf
                                            box_thickness = val
                                        end
                                    end
                                end
                                if menu_elements.box_esp_thickness and menu_elements.box_esp_thickness.get then
                                    local ok, val = pcall(menu_elements.box_esp_thickness.get, menu_elements.box_esp_thickness)
                                    if ok and val and type(val) == "number" then
                                        box_thickness = val
                                    end
                                end
                                
                                draw_box_3d(box_center, box_width, box_height, box_depth, box_color, box_thickness)
                                local unit_name, unit_level, unit_hp_pct = format_unit_info(obj)
                                
                                -- Alte Nameplates entfernt - nur Custom Nameplates werden verwendet
                                local hp_bar_screen = nil
                                -- Alte Nameplate-Rendering-Logik entfernt (wird jetzt in Custom Nameplates gehandhabt)
                                if false then  -- Alte Nameplates deaktiviert
                                    local ui_scale = 1.0
                                    local hp_bar_width = 140 * ui_scale
                                    local hp_bar_height = 16 * ui_scale
                                    local hp_bar_x = hp_bar_screen.x
                                    local hp_bar_y = hp_bar_screen.y
                                    
                                    -- Alpha-Wert basierend auf Range (30% wenn out of range, 100% wenn in range)
                                    local alpha_multiplier_box = is_enemy_in_range and 1.0 or 0.30
                                    
                                    -- Farben (Mana-Bar-Stil) - Alpha basierend auf Range
                                    local bg_alpha_box = math.floor(220 * alpha_multiplier_box)
                                    local border_alpha_box = math.floor(255 * alpha_multiplier_box)
                                    local outline_alpha_box = math.floor(255 * alpha_multiplier_box)
                                    local text_alpha_box = math.floor(255 * alpha_multiplier_box)
                                    
                                    local bg_color = color.new(30, 30, 35, bg_alpha_box)
                                    local border_color = color.new(80, 80, 90, border_alpha_box)
                                    local outline_color = color.new(0, 0, 0, outline_alpha_box)
                                    local text_color = color.new(255, 255, 255, text_alpha_box)
                                    
                                    -- HP-Farbe basierend auf Prozent - Alpha basierend auf Range
                                    local hp_alpha_box = math.floor(255 * alpha_multiplier_box)
                                    
                                    local hp_fill_color
                                    if hp_ratio > 0.6 then
                                        hp_fill_color = color.new(80, 200, 80, hp_alpha_box)  -- Grün
                                    elseif hp_ratio > 0.3 then
                                        hp_fill_color = color.new(255, 200, 80, hp_alpha_box)  -- Gelb/Orange
                                    else
                                        hp_fill_color = color.new(255, 80, 80, hp_alpha_box)  -- Rot
                                    end
                                    
                                    -- Hintergrund mit Rundungen (Mana-Bar-Stil)
                                    if core.graphics.rect_2d_filled then
                                        pcall(core.graphics.rect_2d_filled,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
                                            hp_bar_width,
                                            hp_bar_height,
                                            bg_color,
                                            4.0
                                        )
                                    end
                                    
                                    -- Border (Mana-Bar-Stil)
                                    if core.graphics.rect_2d then
                                        pcall(core.graphics.rect_2d,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
                                            hp_bar_width,
                                            hp_bar_height,
                                            border_color,
                                            1.0,
                                            4.0
                                        )
                                    end
                                    
                                    -- HP Füllung (Mana-Bar-Stil)
                                    local hp_fill_width = (hp_bar_width - 4) * hp_ratio
                                    if hp_fill_width > 0 and core.graphics.rect_2d_filled then
                                        pcall(core.graphics.rect_2d_filled,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5 + 2, hp_bar_y - hp_bar_height * 0.5 + 2),
                                            hp_fill_width,
                                            hp_bar_height - 4,
                                            hp_fill_color,
                                            3.0
                                        )
                                    end
                                    
                                    -- HP-Text mit Prozent (Mana-Bar-Stil) - mittig
                                    local hp_text = string.format("%.0f%%", hp_ratio * 100)
                                    local font_size = 13 * ui_scale
                                    if core.graphics.text_2d then
                                        local text_x = hp_bar_x
                                        local text_y = hp_bar_y - font_size * 0.4  -- Vertikal zentriert
                                        local hp_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                        for _, offset in ipairs(hp_offsets) do
                                            pcall(core.graphics.text_2d, hp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
                                        end
                                        pcall(core.graphics.text_2d, hp_text, vec2_new(text_x, text_y), font_size, text_color, true)
                                    end
                                    
                                    -- Resource Bar (Mana/Rage/Energy) unter der HP-Bar
                                    local has_power = false
                                    local power_ratio = 0
                                    local power_fill_color = color.new(100, 150, 255, 255)  -- Default: Mana (blau)
                                    local power_type = 0  -- Default: Mana
                                    
                                    -- Bestimme Power-Type basierend auf Klasse (wie beim Spieler)
                                    local enemy_class = 0
                                    if obj.get_class then
                                        local ok_class, cls = pcall(obj.get_class, obj)
                                        if ok_class and cls and type(cls) == "number" then
                                            enemy_class = cls
                                        end
                                    end
                                    
                                    -- Setze erwarteten Power-Type basierend auf Klasse
                                    local expected_power_type = 0  -- Default: Mana
                                    if enemy_class == 1 then
                                        expected_power_type = 1  -- Warrior: Rage
                                    elseif enemy_class == 4 then
                                        expected_power_type = 3  -- Rogue: Energy
                                    elseif enemy_class == 6 then
                                        expected_power_type = 6  -- Death Knight: Runic Power
                                    elseif enemy_class == 3 then
                                        expected_power_type = 2  -- Hunter: Focus
                                    elseif enemy_class == 10 then
                                        expected_power_type = 3  -- Monk: Energy
                                    elseif enemy_class == 12 then
                                        expected_power_type = 17  -- Demon Hunter: Fury
                                    end
                                    
                                    -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
                                    local best_power_type = expected_power_type
                                    local best_max_power = 0
                                    
                                    if obj.get_max_power then
                                        -- Prüfe alle relevanten Power-Types
                                        local power_types_to_check = {0, 1, 2, 3, 6, 17}  -- Mana, Rage, Focus, Energy, Runic Power, Fury
                                        
                                        for _, pt in ipairs(power_types_to_check) do
                                            local ok_mp, mp = pcall(obj.get_max_power, obj, pt)
                                            if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                                                best_max_power = mp
                                                best_power_type = pt
                                            end
                                        end
                                        
                                        -- Spezielle Logik für Druiden: Wenn mehrere Power-Types vorhanden sind, verwende den höchsten
                                        if enemy_class == 11 then
                                            local mana_max = 0
                                            local rage_max = 0
                                            local energy_max = 0
                                            local ok_mm, mm = pcall(obj.get_max_power, obj, 0)
                                            if ok_mm and mm and type(mm) == "number" then mana_max = mm end
                                            local ok_rm, rm = pcall(obj.get_max_power, obj, 1)
                                            if ok_rm and rm and type(rm) == "number" then rage_max = rm end
                                            local ok_em, em = pcall(obj.get_max_power, obj, 3)
                                            if ok_em and em and type(em) == "number" then energy_max = em end
                                            
                                            if energy_max > mana_max and energy_max > rage_max then
                                                best_power_type = 3  -- Energy (Cat Form)
                                                best_max_power = energy_max
                                            elseif rage_max > mana_max and rage_max > energy_max then
                                                best_power_type = 1  -- Rage (Bear Form)
                                                best_max_power = rage_max
                                            elseif mana_max > 0 then
                                                best_power_type = 0  -- Mana (Caster/Heal Form)
                                                best_max_power = mana_max
                                            end
                                        end
                                    end
                                    
                                    power_type = best_power_type
                                    
                                    -- Hole Power-Werte basierend auf erkanntem Power-Type
                                    if obj.get_power and obj.get_max_power then
                                        local ok_p, current_power = pcall(obj.get_power, obj, power_type)
                                        local ok_mp, max_power = pcall(obj.get_max_power, obj, power_type)
                                        if ok_p and ok_mp and current_power and max_power and max_power > 0 then
                                            power_ratio = current_power / max_power
                                            has_power = true
                                            -- Farbe basierend auf Power-Type
                                            if power_type == 0 then
                                                power_fill_color = color.new(100, 150, 255, 255)  -- Mana: Blau
                                            elseif power_type == 1 then
                                                power_fill_color = color.new(255, 50, 50, 255)  -- Rage: Rot
                                            elseif power_type == 2 then
                                                power_fill_color = color.new(255, 180, 80, 255)  -- Focus: Orange
                                            elseif power_type == 3 then
                                                power_fill_color = color.new(255, 255, 100, 255)  -- Energy: Gelb
                                            elseif power_type == 6 then
                                                power_fill_color = color.new(0, 200, 255, 255)  -- Runic Power: Cyan
                                            elseif power_type == 17 then
                                                power_fill_color = color.new(200, 100, 255, 255)  -- Fury: Lila
                                            end
                                        end
                                    end
                                    
                                    -- Power-Farbe Alpha basierend auf Range (konsistent mit HP-Bar)
                                    local power_alpha_box = math.floor(255 * alpha_multiplier_box)
                                    power_fill_color = color.new(
                                        power_fill_color.r or 100,
                                        power_fill_color.g or 150,
                                        power_fill_color.b or 255,
                                        power_alpha_box
                                    )

                                    -- Resource Bar zeichnen (wenn vorhanden)
                                    if has_power and power_ratio > 0 then
                                        local power_bar_height = 10 * ui_scale
                                        local power_bar_y = hp_bar_y + hp_bar_height * 0.5 + power_bar_height * 0.5 + 2

                                        -- Power Bar Hintergrund (mit Range-Alpha)
                                        local power_bg_alpha_box = math.floor(200 * alpha_multiplier_box)
                                        local power_bg_color = color.new(20, 20, 25, power_bg_alpha_box)
                                        local power_border_alpha_box = math.floor(180 * alpha_multiplier_box)
                                        local power_border_color = color.new(60, 60, 70, power_border_alpha_box)

                                        if core.graphics.rect_2d_filled then
                                            pcall(core.graphics.rect_2d_filled,
                                                vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - power_bar_height * 0.5),
                                                hp_bar_width,
                                                power_bar_height,
                                                power_bg_color,
                                                3.0
                                            )
                                        end

                                        -- Border
                                        if core.graphics.rect_2d then
                                            pcall(core.graphics.rect_2d,
                                                vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - power_bar_height * 0.5),
                                                hp_bar_width,
                                                power_bar_height,
                                                power_border_color,
                                                1.0,
                                                3.0
                                            )
                                        end

                                        -- Füllung
                                        local power_fill_width = (hp_bar_width - 4) * power_ratio
                                        if power_fill_width > 0 and core.graphics.rect_2d_filled then
                                            pcall(core.graphics.rect_2d_filled,
                                                vec2_new(hp_bar_x - hp_bar_width * 0.5 + 2, power_bar_y - power_bar_height * 0.5 + 2),
                                                power_fill_width,
                                                power_bar_height - 4,
                                                power_fill_color,
                                                2.0
                                            )
                                        end
                                    end
                                    
                                    -- Enemy Name über der HP-Bar (fest, 2D) - nur wenn show_names oder show_level_hp aktiv
                                    if show_names or show_level_hp then
                                        local enemy_name = ""
                                        if show_names then
                                            enemy_name = unit_name or "Enemy"
                                        end
                                        if show_level_hp and unit_level then
                                            if enemy_name ~= "" then
                                                enemy_name = string.format("[%d] %s", unit_level, enemy_name)
                                            else
                                                enemy_name = string.format("[%d]", unit_level)
                                            end
                                        end
                                        if enemy_name ~= "" then
                                            local name_font_size = 14 * ui_scale
                                            local name_y = hp_bar_y - hp_bar_height * 0.5 - name_font_size - 4
                                            if core.graphics.text_2d then
                                                local name_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                                for _, offset in ipairs(name_offsets) do
                                                    pcall(core.graphics.text_2d, enemy_name, vec2_new(hp_bar_x + offset[1], name_y + offset[2]), name_font_size, outline_color, true)
                                                end
                                                pcall(core.graphics.text_2d, enemy_name, vec2_new(hp_bar_x, name_y), name_font_size, text_color, true)
                                            end
                                        end
                                    end
                                end
                                -- Quest-Text entfernt (wird jetzt in Custom Nameplates gehandhabt)
                                if false and is_quest_obj and hp_bar_screen then
                                    local ui_scale = get_element_scale(menu_elements.enemy_hp_bar_scale)
                                    local quest_text = ""
                                    if quest_ids and #quest_ids > 0 then
                                        quest_text = string.format("(QUEST %s)", table.concat(quest_ids, ","))
                                    else
                                        quest_text = "(QUEST)"
                                    end
                                    local quest_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
                                    local quest_font_size = 14 * ui_scale
                                    local quest_outline_color = color.new(0, 0, 0, 255)
                                    -- Position über dem Namen (Name ist bei hp_bar_y - 16*0.5 - 14 - 4)
                                    local quest_hp_bar_height = 16 * ui_scale
                                    local quest_hp_bar_x = hp_bar_screen.x
                                    local quest_hp_bar_y = hp_bar_screen.y
                                    local name_y = quest_hp_bar_y - quest_hp_bar_height * 0.5 - 14 - 4
                                    local quest_y = name_y - quest_font_size - 4
                                    
                                    if core.graphics.text_2d then
                                        local quest_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                        for _, offset in ipairs(quest_offsets) do
                                            pcall(core.graphics.text_2d, quest_text, vec2_new(quest_hp_bar_x + offset[1], quest_y + offset[2]), quest_font_size, quest_outline_color, true)
                                        end
                                        pcall(core.graphics.text_2d, quest_text, vec2_new(quest_hp_bar_x, quest_y), quest_font_size, quest_color, true)
                                    end
                                end
                                
                                -- PvP: Klassen- und Spec/Rollen-Anzeige NUR für feindliche SPIELER (nicht Mobs!)
                                local is_actual_player = false
                                
                                -- Methode 1: is_player()
                                if obj.is_player then
                                    local ok_ip, ip = pcall(obj.is_player, obj)
                                    if ok_ip and ip then
                                        is_actual_player = true
                                    end
                                end
                                
                                -- Methode 2: get_unit_type() == 1
                                if not is_actual_player and obj.get_unit_type then
                                    local ok_ut, ut = pcall(obj.get_unit_type, obj)
                                    if ok_ut and ut == 1 then
                                        is_actual_player = true
                                    end
                                end
                                
                                -- Methode 3: Nicht is_unit (NPCs sind is_unit, Spieler nicht)
                                if not is_actual_player and obj.is_unit then
                                    local ok_iu, iu = pcall(obj.is_unit, obj)
                                    if ok_iu and not iu then
                                        -- Wenn nicht is_unit, aber Klasse hat, dann Spieler
                                        if obj.get_class then
                                            local ok_c, c = pcall(obj.get_class, obj)
                                            if ok_c and c and type(c) == "number" and c >= 1 and c <= 13 then
                                                is_actual_player = true
                                            end
                                        end
                                    end
                                end
                                
                                -- Spec/Klasse entfernt (wird jetzt in Custom Nameplates gehandhabt)
                                if false and is_actual_player and pvp_module and pvp_module.should_show_class_spec and pvp_module.should_show_class_spec() and hp_bar_screen then
                                    local ui_scale = get_element_scale(menu_elements.enemy_hp_bar_scale)
                                    -- Versuche Klasse, Spec und Rolle zu holen
                                    local class_id = nil
                                    local spec_id = nil
                                    local role_name = nil
                                    
                                    -- Klasse holen
                                    if obj.get_class then
                                        local ok_class, cid = pcall(obj.get_class, obj)
                                        if ok_class and cid and type(cid) == "number" and cid > 0 and cid < 14 then
                                            class_id = cid
                                        end
                                    end
                                    
                                    -- Spec holen (verschiedene Methoden)
                                    if obj.get_specialization then
                                        local ok_spec, sid = pcall(obj.get_specialization, obj)
                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                            spec_id = sid
                                        end
                                    end
                                    if not spec_id and obj.get_spec_id then
                                        local ok_spec, sid = pcall(obj.get_spec_id, obj)
                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                            spec_id = sid
                                        end
                                    end
                                    if not spec_id and obj.get_spec then
                                        local ok_spec, sid = pcall(obj.get_spec, obj)
                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                            spec_id = sid
                                        end
                                    end
                                    
                                    -- Rolle holen (Tank/Healer/DPS) als Fallback
                                    if not spec_id then
                                        if obj.get_role then
                                            local ok_role, role = pcall(obj.get_role, obj)
                                            if ok_role and role then
                                                if type(role) == "string" then
                                                    role_name = role
                                                elseif type(role) == "number" then
                                                    -- 0=None, 1=Tank, 2=Healer, 3=DPS (typisch)
                                                    if role == 1 then role_name = "Tank"
                                                    elseif role == 2 then role_name = "Healer"
                                                    elseif role == 3 then role_name = "DPS"
                                                    end
                                                end
                                            end
                                        end
                                        -- Alternativ: is_tank, is_healer prüfen
                                        if not role_name then
                                            if obj.is_tank then
                                                local ok, is_t = pcall(obj.is_tank, obj)
                                                if ok and is_t then role_name = "Tank" end
                                            end
                                        end
                                        if not role_name then
                                            if obj.is_healer then
                                                local ok, is_h = pcall(obj.is_healer, obj)
                                                if ok and is_h then role_name = "Healer" end
                                            end
                                        end
                                    end
                                    
                                    if class_id then
                                        local class_text = nil
                                        
                                        -- Priorität: Spec > Rolle > nur Klasse
                                        if spec_id and pvp_module.format_class_spec_string then
                                            class_text = pvp_module.format_class_spec_string(class_id, spec_id)
                                        elseif role_name and pvp_module.get_class_name then
                                            local class_name = pvp_module.get_class_name(class_id)
                                            if class_name then
                                                class_text = role_name .. " " .. class_name
                                            end
                                        elseif pvp_module.get_class_name then
                                            class_text = pvp_module.get_class_name(class_id)
                                        end
                                        
                                        if class_text and core.graphics.text_2d then
                                            local r, g, b = pvp_module.get_class_color(class_id)
                                            local class_color = color.new(r, g, b, 255)
                                            local class_outline_color = color.new(0, 0, 0, 255)
                                            local class_font_size = 16 * ui_scale
                                            local class_hp_bar_height = 16 * ui_scale
                                            local class_hp_bar_y = hp_bar_screen.y
                                            local class_name_y = class_hp_bar_y - class_hp_bar_height * 0.5 - 14 - 4
                                            
                                            -- Prüfe ob Elite-Label vorhanden ist
                                            local elite_offset = 0
                                            local show_elite_check = true
                                            if menu_elements.show_elite_highlight and menu_elements.show_elite_highlight.get_state then
                                                local ok_el, val_el = pcall(menu_elements.show_elite_highlight.get_state, menu_elements.show_elite_highlight)
                                                if ok_el and val_el ~= nil then show_elite_check = val_el end
                                            end
                                            if show_elite_check then
                                                local classification = get_unit_classification(obj)
                                                if classification and classification ~= "normal" then
                                                    elite_offset = 16 + 4  -- Elite-Label Höhe + Abstand
                                                end
                                            end
                                            
                                            -- Prüfe ob Castbar vorhanden ist
                                            local castbar_offset = 0
                                            local show_cast_bar_check = true
                                            if menu_elements.show_cast_bar and menu_elements.show_cast_bar.get_state then
                                                local ok_cb, val_cb = pcall(menu_elements.show_cast_bar.get_state, menu_elements.show_cast_bar)
                                                if ok_cb and val_cb ~= nil then show_cast_bar_check = val_cb end
                                            end
                                            if show_cast_bar_check then
                                                local cast_spell_check, _, _ = get_unit_cast_info(obj)
                                                if cast_spell_check then
                                                    castbar_offset = 16 + 4  -- Castbar Höhe + Abstand
                                                end
                                            end
                                            
                                            local class_y = class_name_y - elite_offset - castbar_offset - class_font_size - 4
                                            local class_x = hp_bar_screen.x
                                            
                                            local class_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                            for _, offset in ipairs(class_offsets) do
                                                pcall(core.graphics.text_2d, class_text, vec2_new(class_x + offset[1], class_y + offset[2]), class_font_size, class_outline_color, true)
                                            end
                                            pcall(core.graphics.text_2d, class_text, vec2_new(class_x, class_y), class_font_size, class_color, true)
                                        end
                                    end
                                end
                                
                                -- ESP 2.0: Cast-Bar entfernt (wird jetzt in Custom Nameplates gehandhabt)
                                if false then
                                    local show_cast_bar = true
                                    local cast_spell, cast_progress, is_channel = get_unit_cast_info(obj)
                                    if cast_spell and hp_bar_screen then
                                        -- 2D Cast-Bar über dem Namen (basierend auf HP-Bar Position)
                                        -- Bar-Dimensionen
                                        local ui_scale = get_element_scale(menu_elements.enemy_cast_bar_scale)
                                        local cast_bar_width = 140 * ui_scale
                                        local cast_bar_height = 16 * ui_scale
                                        local cast_hp_bar_height = 16 * ui_scale  -- HP-Bar Höhe (gleich wie cast_bar_height)
                                        local cast_bar_x = hp_bar_screen.x
                                        local cast_hp_bar_y = hp_bar_screen.y
                                        -- Position über dem Namen: Name ist bei hp_bar_y - hp_bar_height*0.5 - 14 - 4
                                        local name_y = cast_hp_bar_y - cast_hp_bar_height * 0.5 - 14 - 4
                                        
                                        -- Prüfe ob Spec-Anzeige vorhanden ist (aus PvP Settings)
                                        local spec_offset = 0
                                        if is_actual_player and pvp_module and pvp_module.should_show_class_spec and pvp_module.should_show_class_spec() then
                                            local player_class_id = nil
                                            if obj.get_class then
                                                local ok_class, cid = pcall(obj.get_class, obj)
                                                if ok_class and cid and type(cid) == "number" and cid > 0 and cid < 14 then
                                                    player_class_id = cid
                                                end
                                            end
                                            if player_class_id then
                                                local spec_text = nil
                                                local player_spec_id = nil
                                                if obj.get_specialization then
                                                    local ok_spec, sid = pcall(obj.get_specialization, obj)
                                                    if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                        player_spec_id = sid
                                                    end
                                                end
                                                if not player_spec_id and obj.get_spec_id then
                                                    local ok_spec, sid = pcall(obj.get_spec_id, obj)
                                                    if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                        player_spec_id = sid
                                                    end
                                                end
                                                if not player_spec_id and obj.get_spec then
                                                    local ok_spec, sid = pcall(obj.get_spec, obj)
                                                    if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                        player_spec_id = sid
                                                    end
                                                end
                                                if player_spec_id and pvp_module.format_class_spec_string then
                                                    spec_text = pvp_module.format_class_spec_string(player_class_id, player_spec_id)
                                                elseif pvp_module.get_class_name then
                                                    spec_text = pvp_module.get_class_name(player_class_id)
                                                end
                                                if spec_text then
                                                    spec_offset = 16 + 4  -- Spec-Label Höhe + Abstand
                                                end
                                            end
                                        end
                                        
                                        -- Prüfe ob Elite-Label vorhanden ist (für Positionierung)
                                        local elite_offset = 0
                                        local show_elite_check = true
                                        if menu_elements.show_elite_highlight and menu_elements.show_elite_highlight.get_state then
                                            local ok_el, val_el = pcall(menu_elements.show_elite_highlight.get_state, menu_elements.show_elite_highlight)
                                            if ok_el and val_el ~= nil then show_elite_check = val_el end
                                        end
                                        if show_elite_check then
                                            local classification = get_unit_classification(obj)
                                            if classification and classification ~= "normal" then
                                                elite_offset = 16 + 4  -- Elite-Label Höhe + Abstand
                                            end
                                        end
                                        local cast_bar_y = name_y - cast_bar_height * 0.5 - 4 - spec_offset - elite_offset
                                        
                                        -- Farben (Mana-Bar-Stil)
                                        local bg_color = color.new(30, 30, 35, 220)
                                        local border_color = color.new(80, 80, 90, 255)
                                        local outline_color = color.new(0, 0, 0, 255)
                                        local text_color = color.new(255, 255, 255, 255)
                                        local cast_fill_color = is_channel and color.new(180, 100, 255, 255) or color.new(255, 200, 50, 255)
                                        
                                        -- Hintergrund mit Rundungen (Mana-Bar-Stil - wie HP-Bar)
                                        if core.graphics.rect_2d_filled then
                                            pcall(core.graphics.rect_2d_filled,
                                                vec2_new(cast_bar_x - cast_bar_width * 0.5, cast_bar_y - cast_bar_height * 0.5),
                                                cast_bar_width,
                                                cast_bar_height,
                                                bg_color,
                                                4.0
                                            )
                                        end
                                        
                                        -- Border (Mana-Bar-Stil - wie HP-Bar)
                                        if core.graphics.rect_2d then
                                            pcall(core.graphics.rect_2d,
                                                vec2_new(cast_bar_x - cast_bar_width * 0.5, cast_bar_y - cast_bar_height * 0.5),
                                                cast_bar_width,
                                                cast_bar_height,
                                                border_color,
                                                1.0,
                                                4.0
                                            )
                                        end
                                        
                                        -- Füllung (Mana-Bar-Stil - wie HP-Bar)
                                        local cast_fill_width = (cast_bar_width - 4) * math.max(0.01, cast_progress)
                                        if cast_fill_width > 0 and core.graphics.rect_2d_filled then
                                            pcall(core.graphics.rect_2d_filled,
                                                vec2_new(cast_bar_x - cast_bar_width * 0.5 + 2, cast_bar_y - cast_bar_height * 0.5 + 2),
                                                cast_fill_width,
                                                cast_bar_height - 4,
                                                cast_fill_color,
                                                3.0
                                            )
                                        end
                                        
                                        -- Cast-Text mit Prozent (Mana-Bar-Stil - mittig)
                                        local cast_percent = math.floor(cast_progress * 100)
                                        local cast_text = string.format("%s (%.0f%%)", cast_spell, cast_percent)
                                        local font_size = 12 * ui_scale
                                        if core.graphics.text_2d then
                                            local text_x = cast_bar_x
                                            local text_y = cast_bar_y
                                            local cast_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                            for _, offset in ipairs(cast_offsets) do
                                                pcall(core.graphics.text_2d, cast_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
                                            end
                                            pcall(core.graphics.text_2d, cast_text, vec2_new(text_x, text_y), font_size, text_color, true)
                                        end
                                    end
                                end
                                
                                -- ESP 2.0: Elite/Rare Highlight entfernt (wird jetzt in Custom Nameplates gehandhabt)
                                if false then
                                    local show_elite = true
                                    if hp_bar_screen then
                                    local classification = get_unit_classification(obj)
                                    if classification and classification ~= "normal" then
                                        local elite_label = ""
                                        local elite_color = nil
                                        if classification == "elite" or classification == 1 then
                                            elite_label = "ELITE"
                                            elite_color = get_safe_color(menu_elements.elite_color, color.new(255, 215, 0, 255))
                                        elseif classification == "rare" or classification == 2 then
                                            elite_label = "RARE"
                                            elite_color = get_safe_color(menu_elements.rare_color, color.new(150, 200, 255, 255))
                                        elseif classification == "rareelite" or classification == 3 then
                                            elite_label = "RARE ELITE"
                                            -- Verwende Rare Color für Rare Elite
                                            elite_color = get_safe_color(menu_elements.rare_color, color.new(255, 150, 255, 255))
                                        elseif classification == "worldboss" or classification == 4 then
                                            elite_label = "BOSS"
                                            elite_color = get_safe_color(menu_elements.boss_color, color.new(255, 100, 100, 255))
                                        end
                                        if elite_label ~= "" and elite_color then
                                            -- Position unter der Spec-Anzeige (falls vorhanden)
                                            local elite_font_size = 16
                                            local elite_hp_bar_height = 16
                                            local elite_hp_bar_y = hp_bar_screen.y
                                            local elite_name_y = elite_hp_bar_y - elite_hp_bar_height * 0.5 - 14 - 4
                                            
                                            -- Prüfe ob Spec-Anzeige vorhanden ist (aus PvP Settings)
                                            local spec_offset = 0
                                            if is_actual_player and pvp_module and pvp_module.should_show_class_spec and pvp_module.should_show_class_spec() then
                                                local player_class_id = nil
                                                if obj.get_class then
                                                    local ok_class, cid = pcall(obj.get_class, obj)
                                                    if ok_class and cid and type(cid) == "number" and cid > 0 and cid < 14 then
                                                        player_class_id = cid
                                                    end
                                                end
                                                if player_class_id then
                                                    local spec_text = nil
                                                    local player_spec_id = nil
                                                    if obj.get_specialization then
                                                        local ok_spec, sid = pcall(obj.get_specialization, obj)
                                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                            player_spec_id = sid
                                                        end
                                                    end
                                                    if not player_spec_id and obj.get_spec_id then
                                                        local ok_spec, sid = pcall(obj.get_spec_id, obj)
                                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                            player_spec_id = sid
                                                        end
                                                    end
                                                    if not player_spec_id and obj.get_spec then
                                                        local ok_spec, sid = pcall(obj.get_spec, obj)
                                                        if ok_spec and sid and type(sid) == "number" and sid > 0 then
                                                            player_spec_id = sid
                                                        end
                                                    end
                                                    if player_spec_id and pvp_module.format_class_spec_string then
                                                        spec_text = pvp_module.format_class_spec_string(player_class_id, player_spec_id)
                                                    elseif pvp_module.get_class_name then
                                                        spec_text = pvp_module.get_class_name(player_class_id)
                                                    end
                                                    if spec_text then
                                                        spec_offset = 16 + 4  -- Spec-Label Höhe + Abstand
                                                    end
                                                end
                                            end
                                            
                                            -- Prüfe ob Castbar vorhanden ist
                                            local castbar_offset = 0
                                            local show_cast_bar_check = true
                                            if menu_elements.show_cast_bar and menu_elements.show_cast_bar.get_state then
                                                local ok_cb, val_cb = pcall(menu_elements.show_cast_bar.get_state, menu_elements.show_cast_bar)
                                                if ok_cb and val_cb ~= nil then show_cast_bar_check = val_cb end
                                            end
                                            if show_cast_bar_check then
                                                local cast_spell_check, _, _ = get_unit_cast_info(obj)
                                                if cast_spell_check then
                                                    castbar_offset = 16 + 4  -- Castbar Höhe + Abstand
                                                end
                                            end
                                            local elite_y = elite_name_y - spec_offset - castbar_offset - elite_font_size - 4
                                            
                                            if core.graphics.text_2d then
                                                local elite_outline_color = color.new(0, 0, 0, 255)
                                                local elite_x = hp_bar_screen.x
                                                local elite_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                                for _, offset in ipairs(elite_offsets) do
                                                    pcall(core.graphics.text_2d, elite_label, vec2_new(elite_x + offset[1], elite_y + offset[2]), elite_font_size, elite_outline_color, true)
                                                end
                                                pcall(core.graphics.text_2d, elite_label, vec2_new(elite_x, elite_y), elite_font_size, elite_color, true)
                                            end
                                        end
                                    end
                                end -- if hp_bar_screen
                                
                                -- ESP 2.0: Facing Indicator (Blickrichtung als Pfeil)
                                local show_facing = false
                                if menu_elements.show_facing_indicator and menu_elements.show_facing_indicator.get_state then
                                    local ok_fc, val_fc = pcall(menu_elements.show_facing_indicator.get_state, menu_elements.show_facing_indicator)
                                    if ok_fc and val_fc ~= nil then show_facing = val_fc end
                                end
                                if show_facing then
                                    local facing_dir = get_unit_facing_direction(obj)
                                    if facing_dir and facing_dir.x and facing_dir.y then
                                        -- Kleiner gefüllter Pfeilkopf
                                        local arrow_dist = 1.5
                                        local facing_tip = {
                                            x = render_pos.x + facing_dir.x * arrow_dist,
                                            y = render_pos.y + facing_dir.y * arrow_dist,
                                            z = render_pos.z + 0.3
                                        }
                                        
                                        local facing_color = color.new(255, 200, 80, 255)
                                        local tip_size = 0.4
                                        local wing_width = 0.25
                                        
                                        if core.graphics.line_3d then
                                            -- Gefülltes Dreieck durch Schichten
                                            for i = 0, 3 do
                                                local t = i / 3
                                                local px = facing_tip.x - facing_dir.x * tip_size * t
                                                local py = facing_tip.y - facing_dir.y * tip_size * t
                                                local w = wing_width * t
                                                local left = { x = px - facing_dir.y * w, y = py + facing_dir.x * w, z = facing_tip.z }
                                                local right = { x = px + facing_dir.y * w, y = py - facing_dir.x * w, z = facing_tip.z }
                                                pcall(core.graphics.line_3d, left, right, facing_color, 3.0)
                                            end
                                        end
                                    end
                                end
                                
                                local fill_box = true
                                if menu_elements.fill_box_esp and menu_elements.fill_box_esp.get_state then
                                    local ok, val = pcall(menu_elements.fill_box_esp.get_state, menu_elements.fill_box_esp)
                                    if ok and val ~= nil then
                                        fill_box = val
                                    end
                                end
                                if fill_box then
                                    local num_fill_boxes = 8
                                    local bcr, bcg, bcb = safe_get_rgb(box_color, 100, 150, 255)
                                    for i = 1, num_fill_boxes do
                                        local scale = 1.0 - (i - 1) / num_fill_boxes * 0.3
                                        local fill_alpha = safe_get_alpha(box_color, 255) * (1.0 - (i - 1) / num_fill_boxes * 0.4)
                                        local fill_box_color = color.new(bcr, bcg, bcb, math.max(30, fill_alpha))
                                        local fill_center = {
                                            x = box_center.x,
                                            y = box_center.y,
                                            z = box_center.z
                                        }
                                        draw_box_3d(
                                            fill_center,
                                            box_width * scale,
                                            box_height * scale,
                                            box_depth * scale,
                                            fill_box_color,
                                            box_thickness * 0.5
                                        )
                                    end
                            end
                        end -- box_in_range
                        end -- should_draw_box
                        -- Traceline wenn Gegner den Spieler anvisiert (targeting player)
                        if is_targeting_player and core.graphics.line_3d then
                            local targeting_traceline_color = get_safe_color(menu_elements.targeting_color, color.new(255, 0, 0, 255))
                            if enable_distance_fading then
                                targeting_traceline_color = apply_distance_fading(targeting_traceline_color, distance, max_distance, 100)
                            end
                            -- Range-Prüfung für Traceline (Slider-gesteuert)
                            local max_range = 35.0  -- Default fallback
                            if menu_elements.box_esp_visibility and menu_elements.box_esp_visibility.get then
                                local ok, val = pcall(menu_elements.box_esp_visibility.get, menu_elements.box_esp_visibility)
                                if ok and val and type(val) == "number" then
                                    max_range = val
                                end
                            end
                            local is_in_range = is_in_range_check(obj, obj_pos, max_range)
                            -- Nur rendern wenn in Sichtweite!
                            if is_in_range then
                                draw_traceline_dots(render_pos, player_pos, targeting_traceline_color, 1.0, 0.25)
                            end
                        end
                        if show_tracelines_all and core.graphics.line_3d and is_enemy then
                            local traceline_color = current_enemy_color
                            if enable_distance_fading then
                                traceline_color = apply_distance_fading(traceline_color, distance, max_distance, 100)
                            end
                            -- Range-Prüfung (Slider-gesteuert)
                            local max_range = 35.0  -- Default fallback
                            if menu_elements.box_esp_visibility and menu_elements.box_esp_visibility.get then
                                local ok, val = pcall(menu_elements.box_esp_visibility.get, menu_elements.box_esp_visibility)
                                if ok and val and type(val) == "number" then
                                    max_range = val
                                end
                            end
                            local is_in_range = is_in_range_check(obj, obj_pos, max_range)
                            -- Nur rendern wenn in Sichtweite!
                            if is_in_range then
                                draw_traceline_dots(render_pos, player_pos, traceline_color, 1.2, 0.15)
                            end
                        end
                        local show_tracelines_questmobs = false
                        if menu_elements.show_tracelines_questmobs and menu_elements.show_tracelines_questmobs.get_state then
                            local ok, val = pcall(menu_elements.show_tracelines_questmobs.get_state, menu_elements.show_tracelines_questmobs)
                            if ok and val ~= nil then
                                show_tracelines_questmobs = val
                            end
                        end
                        if show_tracelines_questmobs and is_quest_obj then
                            local traceline_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
                            if enable_distance_fading then
                                traceline_color = apply_distance_fading(traceline_color, distance, max_distance, 100)
                            end
                            -- Range-Prüfung für Quest-Traceline (Slider-gesteuert)
                            local max_range = 35.0  -- Default fallback
                            if menu_elements.box_esp_visibility and menu_elements.box_esp_visibility.get then
                                local ok, val = pcall(menu_elements.box_esp_visibility.get, menu_elements.box_esp_visibility)
                                if ok and val and type(val) == "number" then
                                    max_range = val
                                end
                            end
                            local is_in_range = is_in_range_check(obj, obj_pos, max_range)
                            -- Nur rendern wenn in Sichtweite!
                            if is_in_range then
                            draw_traceline_dots(render_pos, player_pos, traceline_color, 1.4, 0.30)
                            local show_traceline_labels = true
                            if menu_elements.show_traceline_labels and menu_elements.show_traceline_labels.get_state then
                                local ok, val = pcall(menu_elements.show_traceline_labels.get_state, menu_elements.show_traceline_labels)
                                if ok and val ~= nil then
                                    show_traceline_labels = val
                                end
                            end
                            if show_traceline_labels then
                                local mid_x = (render_pos.x + player_pos.x) / 2
                                local mid_y = (render_pos.y + player_pos.y) / 2
                                local mid_z = ((render_pos.z or 0) + (player_pos.z or 0)) / 2
                                
                                -- Prüfe ob "Show Icon Instead of Text" für Questmobs aktiviert ist
                                local show_quest_icon = false
                                if menu_elements.show_questmob_icon_instead_of_text and menu_elements.show_questmob_icon_instead_of_text.get_state then
                                    local ok, val = pcall(menu_elements.show_questmob_icon_instead_of_text.get_state, menu_elements.show_questmob_icon_instead_of_text)
                                    if ok and val ~= nil then
                                        show_quest_icon = val
                                    end
                                end
                                
                                -- Wenn Icon-Toggle aktiv: Versuche Texture zu verwenden
                                local texture_drawn = false
                                local icon_available = false
                                if show_quest_icon then
                                    icon_available = true
                                    local icon_world_pos = { x = mid_x, y = mid_y, z = mid_z + 0.5 }
                                    local icon_screen = world_to_screen_2d(icon_world_pos)
                                    if icon_screen then
                                        local icon_size = 36
                                        local icon_pos = vec2_new(icon_screen.x, icon_screen.y)
                                        local tint_color = color.new(255, 255, 255, 255)
                                        texture_drawn = draw_texture("quest", icon_pos, icon_size, icon_size, tint_color)
                                    end
                                end
                                
                                -- Fallback: Text rendern nur wenn Icon nicht aktiv ODER Icon nicht verfügbar
                                if not show_quest_icon or not icon_available then
                                    if core.graphics and core.graphics.text_3d then
                                        local text_pos = { x = mid_x, y = mid_y, z = mid_z }
                                        draw_text_3d_outlined("Questmob", text_pos, 16, traceline_color, true)
                                    end
                                end
                            end
                            end -- is_in_range
                        end
                        -- Target-Traceline entfernt - wird jetzt durch Target Arrow + Text ersetzt
                        -- ESP 2.0: Combat Status (gut sichtbar für ALLE Feinde im Sichtfeld)
                        -- Wird außerhalb des Box-ESP-Blocks angezeigt, damit es für alle Feinde funktioniert
                        local show_in_combat_with = true
                        if menu_elements.show_in_combat_with and menu_elements.show_in_combat_with.get_state then
                            local ok_ic, val_ic = pcall(menu_elements.show_in_combat_with.get_state, menu_elements.show_in_combat_with)
                            if ok_ic and val_ic ~= nil then show_in_combat_with = val_ic end
                        end
                        if is_in_combat and show_in_combat_with then
                            local combat_label = "IN COMBAT"
                            local combat_color = color.new(255, 80, 80, 255)  -- Standard: Leuchtendes Rot
                            
                            -- Prüfe, mit wem der Feind im Kampf ist (Target)
                            local combat_target_name = nil
                            local is_targeting_player = false
                            if obj.get_target then
                                local ok_target, target = pcall(obj.get_target, obj)
                                if ok_target and target then
                                    -- Prüfe ob Target der Spieler ist
                                    if (__object_safety.same(target,local_player)) then
                                        is_targeting_player = true
                                    elseif target.get_guid and local_player.get_guid then
                                        local ok_guid1, guid1 = pcall(target.get_guid, target)
                                        local ok_guid2, guid2 = pcall(local_player.get_guid, local_player)
                                        if ok_guid1 and ok_guid2 and guid1 == guid2 then
                                            is_targeting_player = true
                                        end
                                    end
                                    
                                    -- Wenn Target der Spieler ist, zeige "YOU", sonst den Namen
                                    if is_targeting_player then
                                        combat_target_name = "YOU"
                                    elseif target.get_name then
                                        local ok_name, name = pcall(target.get_name, target)
                                        if ok_name and name and name ~= "" then
                                            combat_target_name = name
                                        end
                                    end
                                end
                            end
                            
                            -- Wenn der Feind mit dem Spieler im Kampf ist: Grün
                            if is_targeting_player then
                                combat_color = color.new(80, 255, 80, 255)  -- Leuchtendes Grün
                            end
                            
                            -- Label mit Target-Namen erweitern, falls vorhanden
                            if combat_target_name then
                                combat_label = "IN COMBAT: " .. combat_target_name
                            end
                            
                            local combat_pos = { x = render_pos.x, y = render_pos.y, z = render_pos.z + 2.5 }
                            
                            -- Text (groß und gut sichtbar) - nur einmal zeichnen
                            draw_text_3d_outlined(combat_label, combat_pos, 22, combat_color, true)
                        end
                        
                        
                        local name, lvl_val, hp_pct_val = format_unit_info(obj)
                        local box_esp_active = false
                        if should_draw_box then
                            box_esp_active = true
                        end
                        
                        -- PvP-Filterung auch für Healthbars ohne Boxen anwenden - NUR feindliche Spieler
                        local should_show_healthbar = true
                        
                        if use_only_enemy_esp then
                            -- PvP MODUS: Gleiche Logik wie bei Boxen - NUR feindliche SPIELER
                            should_show_healthbar = false
                            if is_enemy then
                                -- Methode 1: is_player()
                                if obj.is_player then
                                    local ok, result = pcall(obj.is_player, obj)
                                    if ok and result == true then
                                        should_show_healthbar = true
                                    end
                                end
                                -- Methode 2: get_unit_type == 1
                                if not should_show_healthbar and obj.get_unit_type then
                                    local ok, unit_type = pcall(obj.get_unit_type, obj)
                                    if ok and unit_type == 1 then
                                        should_show_healthbar = true
                                    end
                                end
                            end
                        end
                        
                        -- Alte Nameplates entfernt - nur Custom Nameplates werden verwendet
                        if false then  -- Alte Nameplates deaktiviert
                                local hp_bar_screen = nil
                                local ui_scale = 1.0
                                local hp_bar_width = 140 * ui_scale
                                local hp_bar_height = 16 * ui_scale
                                local hp_bar_x = hp_bar_screen.x
                                local hp_bar_y = hp_bar_screen.y
                                
                                -- Farben (Mana-Bar-Stil) - Alpha direkt setzen
                                local bg_alpha = math.floor(220 * alpha_multiplier)
                                local border_alpha = math.floor(255 * alpha_multiplier)
                                local outline_alpha = math.floor(255 * alpha_multiplier)
                                local text_alpha = math.floor(255 * alpha_multiplier)
                                
                                local bg_color = color.new(30, 30, 35, bg_alpha)
                                local border_color = color.new(80, 80, 90, border_alpha)
                                local outline_color = color.new(0, 0, 0, outline_alpha)
                                local text_color = color.new(255, 255, 255, text_alpha)
                                
                                -- HP-Farbe basierend auf Prozent - Alpha basierend auf Range
                                local hp_alpha = math.floor(255 * alpha_multiplier)
                                
                                local hp_fill_color
                                if hp_ratio > 0.6 then
                                    hp_fill_color = color.new(80, 200, 80, hp_alpha)  -- Grün
                                elseif hp_ratio > 0.3 then
                                    hp_fill_color = color.new(255, 200, 80, hp_alpha)  -- Gelb/Orange
                                else
                                    hp_fill_color = color.new(255, 80, 80, hp_alpha)  -- Rot
                                end
                                
                                -- Hintergrund mit Rundungen (Mana-Bar-Stil)
                                if core.graphics.rect_2d_filled then
                                    pcall(core.graphics.rect_2d_filled,
                                        vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
                                        hp_bar_width,
                                        hp_bar_height,
                                        bg_color,
                                        4.0
                                    )
                                end
                                
                                -- Border (Mana-Bar-Stil)
                                if core.graphics.rect_2d then
                                    pcall(core.graphics.rect_2d,
                                        vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
                                        hp_bar_width,
                                        hp_bar_height,
                                        border_color,
                                        1.0,
                                        4.0
                                    )
                                end
                                
                                -- HP Füllung (Mana-Bar-Stil)
                                local hp_fill_width = (hp_bar_width - 4) * hp_ratio
                                if hp_fill_width > 0 and core.graphics.rect_2d_filled then
                                    pcall(core.graphics.rect_2d_filled,
                                        vec2_new(hp_bar_x - hp_bar_width * 0.5 + 2, hp_bar_y - hp_bar_height * 0.5 + 2),
                                        hp_fill_width,
                                        hp_bar_height - 4,
                                        hp_fill_color,
                                        3.0
                                    )
                                end
                                
                                -- HP-Text mit Prozent (Mana-Bar-Stil) - mittig
                                local hp_text = string.format("%.0f%%", hp_ratio * 100)
                                local font_size = 13 * ui_scale
                                if core.graphics.text_2d then
                                    local text_x = hp_bar_x
                                    local text_y = hp_bar_y - font_size * 0.4  -- Vertikal zentriert
                                    local hp_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                    for _, offset in ipairs(hp_offsets) do
                                        pcall(core.graphics.text_2d, hp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
                                    end
                                    pcall(core.graphics.text_2d, hp_text, vec2_new(text_x, text_y), font_size, text_color, true)
                                end
                                
                                -- Resource Bar (Mana/Rage/Energy) unter der HP-Bar
                                local has_power = false
                                local power_ratio = 0
                                local power_fill_color = color.new(100, 150, 255, 255)  -- Default: Mana (blau)
                                local power_type = 0  -- Default: Mana
                                
                                -- Bestimme Power-Type basierend auf Klasse (wie beim Spieler)
                                local enemy_class = 0
                                if obj.get_class then
                                    local ok_class, cls = pcall(obj.get_class, obj)
                                    if ok_class and cls and type(cls) == "number" then
                                        enemy_class = cls
                                            end
                                        end
                            
                                -- Setze erwarteten Power-Type basierend auf Klasse
                                local expected_power_type = 0  -- Default: Mana
                                if enemy_class == 1 then
                                    expected_power_type = 1  -- Warrior: Rage
                                elseif enemy_class == 4 then
                                    expected_power_type = 3  -- Rogue: Energy
                                elseif enemy_class == 6 then
                                    expected_power_type = 6  -- Death Knight: Runic Power
                                elseif enemy_class == 3 then
                                    expected_power_type = 2  -- Hunter: Focus
                                elseif enemy_class == 10 then
                                    expected_power_type = 3  -- Monk: Energy
                                elseif enemy_class == 12 then
                                    expected_power_type = 17  -- Demon Hunter: Fury
                                end
                                
                                -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
                                local best_power_type = expected_power_type
                                local best_max_power = 0
                                
                                if obj.get_max_power then
                                    -- Prüfe alle relevanten Power-Types
                                    local power_types_to_check = {0, 1, 2, 3, 6, 17}  -- Mana, Rage, Focus, Energy, Runic Power, Fury
                                    
                                    for _, pt in ipairs(power_types_to_check) do
                                        local ok_mp, mp = pcall(obj.get_max_power, obj, pt)
                                        if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                                            best_max_power = mp
                                            best_power_type = pt
                                        end
                                    end
                                    
                                    -- Spezielle Logik für Druiden: Wenn mehrere Power-Types vorhanden sind, verwende den höchsten
                                    if enemy_class == 11 then
                                        local mana_max = 0
                                        local rage_max = 0
                                        local energy_max = 0
                                        local ok_mm, mm = pcall(obj.get_max_power, obj, 0)
                                        if ok_mm and mm and type(mm) == "number" then mana_max = mm end
                                        local ok_rm, rm = pcall(obj.get_max_power, obj, 1)
                                        if ok_rm and rm and type(rm) == "number" then rage_max = rm end
                                        local ok_em, em = pcall(obj.get_max_power, obj, 3)
                                        if ok_em and em and type(em) == "number" then energy_max = em end
                                        
                                        if energy_max > mana_max and energy_max > rage_max then
                                            best_power_type = 3  -- Energy (Cat Form)
                                            best_max_power = energy_max
                                        elseif rage_max > mana_max and rage_max > energy_max then
                                            best_power_type = 1  -- Rage (Bear Form)
                                            best_max_power = rage_max
                                        elseif mana_max > 0 then
                                            best_power_type = 0  -- Mana (Caster/Heal Form)
                                            best_max_power = mana_max
                                        end
                                    end
                                end
                                
                                power_type = best_power_type
                                
                                -- Hole Power-Werte basierend auf erkanntem Power-Type
                                if obj.get_power and obj.get_max_power then
                                    local ok_p, current_power = pcall(obj.get_power, obj, power_type)
                                    local ok_mp, max_power = pcall(obj.get_max_power, obj, power_type)
                                    if ok_p and ok_mp and current_power and max_power and max_power > 0 then
                                        power_ratio = current_power / max_power
                                        has_power = true
                                        -- Farbe basierend auf Power-Type
                                        if power_type == 0 then
                                            power_fill_color = color.new(100, 150, 255, 255)  -- Mana: Blau
                                        elseif power_type == 1 then
                                            power_fill_color = color.new(255, 50, 50, 255)  -- Rage: Rot
                                        elseif power_type == 2 then
                                            power_fill_color = color.new(255, 180, 80, 255)  -- Focus: Orange
                                        elseif power_type == 3 then
                                            power_fill_color = color.new(255, 255, 100, 255)  -- Energy: Gelb
                                        elseif power_type == 6 then
                                            power_fill_color = color.new(0, 200, 255, 255)  -- Runic Power: Cyan
                                        elseif power_type == 17 then
                                            power_fill_color = color.new(200, 100, 255, 255)  -- Fury: Lila
                                        end
                                    end
                                    
                                    -- Power-Farbe Alpha basierend auf Range (konsistent mit HP-Bar)
                                    local power_alpha = math.floor(255 * alpha_multiplier)
                                    power_fill_color = color.new(
                                        power_fill_color.r or 100,
                                        power_fill_color.g or 150,
                                        power_fill_color.b or 255,
                                        power_alpha
                                    )
                                end

                                -- Resource Bar zeichnen (wenn vorhanden)
                                if has_power and power_ratio > 0 then
                                    local power_bar_height = 10 * ui_scale
                                    local power_bar_y = hp_bar_y + hp_bar_height * 0.5 + power_bar_height * 0.5 + 2

                                    -- Power Bar Hintergrund (mit Range-Alpha)
                                    local power_bg_alpha = math.floor(200 * alpha_multiplier)
                                    local power_bg_color = color.new(20, 20, 25, power_bg_alpha)
                                    local power_border_alpha = math.floor(180 * alpha_multiplier)
                                    local power_border_color = color.new(60, 60, 70, power_border_alpha)

                                    if core.graphics.rect_2d_filled then
                                        pcall(core.graphics.rect_2d_filled,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - power_bar_height * 0.5),
                                            hp_bar_width,
                                            power_bar_height,
                                            power_bg_color,
                                            3.0
                                        )
                                    end

                                    -- Border
                                    if core.graphics.rect_2d then
                                        pcall(core.graphics.rect_2d,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - power_bar_height * 0.5),
                                            hp_bar_width,
                                            power_bar_height,
                                            power_border_color,
                                            1.0,
                                            3.0
                                        )
                                    end

                                    -- Füllung
                                    local power_fill_width = (hp_bar_width - 4) * power_ratio
                                    if power_fill_width > 0 and core.graphics.rect_2d_filled then
                                        pcall(core.graphics.rect_2d_filled,
                                            vec2_new(hp_bar_x - hp_bar_width * 0.5 + 2, power_bar_y - power_bar_height * 0.5 + 2),
                                            power_fill_width,
                                            power_bar_height - 4,
                                            power_fill_color,
                                            2.0
                                        )
                                    end
                                end
                                
                                -- Enemy Name über der HP-Bar (fest, 2D) - nur wenn show_names oder show_level_hp aktiv
                                if show_names or show_level_hp then
                                    local enemy_name = ""
                                    if show_names then
                                        enemy_name = name or "Enemy"
                                    end
                                    if show_level_hp and lvl_val then
                                        if enemy_name ~= "" then
                                            enemy_name = string.format("[%d] %s", lvl_val, enemy_name)
                                        else
                                            enemy_name = string.format("[%d]", lvl_val)
                                        end
                                    end
                                    if enemy_name ~= "" then
                                        local name_font_size = 14 * ui_scale
                                        local name_y = hp_bar_y - hp_bar_height * 0.5 - name_font_size - 4
                                        if core.graphics.text_2d then
                                            local name_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
                                            for _, offset in ipairs(name_offsets) do
                                                pcall(core.graphics.text_2d, enemy_name, vec2_new(hp_bar_x + offset[1], name_y + offset[2]), name_font_size, outline_color, true)
                                            end
                                            pcall(core.graphics.text_2d, enemy_name, vec2_new(hp_bar_x, name_y), name_font_size, text_color, true)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            end
            
            ::continue_entity_loop::
        end
    end
end

local function render_radar()
    if not core or not core.graphics then
        return
    end
    if not menu then
        return
    end
    local enabled = true
    if menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok and val ~= nil then
            enabled = val
        end
    end
    if not enabled then
        return
    end
    local show_radar = false
    if menu_elements.show_radar and menu_elements.show_radar.get_state then
        local ok, val = pcall(menu_elements.show_radar.get_state, menu_elements.show_radar)
        if ok and val ~= nil then
            show_radar = val
        end
    end
    if not show_radar then
        return
    end
    
    -- Menü-Werte laden
    local max_distance = 100.0
    if menu_elements.max_distance and menu_elements.max_distance.get then
        local ok, val = pcall(menu_elements.max_distance.get, menu_elements.max_distance)
        if ok and val and type(val) == "number" then
            max_distance = val
        end
    end
    local radar_size = 250.0
    if menu_elements.radar_size and menu_elements.radar_size.get then
        local ok, val = pcall(menu_elements.radar_size.get, menu_elements.radar_size)
        if ok and val and type(val) == "number" then
            radar_size = val
        end
    end
    local radar_range = 50.0
    if menu_elements.radar_range and menu_elements.radar_range.get then
        local ok, val = pcall(menu_elements.radar_range.get, menu_elements.radar_range)
        if ok and val and type(val) == "number" then
            radar_range = val
        end
    end
    if radar_range > max_distance then
        radar_range = max_distance
    end
    local radar_bg_color = get_safe_color(menu_elements.radar_background_color, color.new(20, 20, 30, 220))
    local radar_border_color = get_safe_color(menu_elements.radar_border_color, color.new(100, 100, 120, 255))
    local radar_player_color = get_safe_color(menu_elements.radar_player_color, color.new(0, 150, 255, 255))
    local radar_enemy_color = get_safe_color(menu_elements.radar_enemy_color, color.new(255, 0, 0, 255))
    local radar_quest_color = get_safe_color(menu_elements.radar_quest_color, color.new(255, 215, 0, 255))
    local radar_quest_item_color = get_safe_color(menu_elements.radar_quest_item_color, color.new(255, 215, 0, 255))
    local radar_gathering_color = get_safe_color(menu_elements.radar_gathering_color, color.new(0, 255, 120, 255))
    local radar_fishing_color = get_safe_color(menu_elements.radar_fishing_color, color.new(80, 170, 255, 255))
    local radar_show_names = false
    if menu_elements.radar_show_names and menu_elements.radar_show_names.get_state then
        local ok, val = pcall(menu_elements.radar_show_names.get_state, menu_elements.radar_show_names)
        if ok and val ~= nil then
            radar_show_names = val
        end
    end
    local radar_blip_size = 4.0
    if menu_elements.radar_blip_size and menu_elements.radar_blip_size.get then
        local ok, val = pcall(menu_elements.radar_blip_size.get, menu_elements.radar_blip_size)
        if ok and val and type(val) == "number" then
            radar_blip_size = val
        end
    end
    local show_quest_mobs = true
    if menu_elements.show_quest_mobs and menu_elements.show_quest_mobs.get_state then
        local ok, val = pcall(menu_elements.show_quest_mobs.get_state, menu_elements.show_quest_mobs)
        if ok and val ~= nil then
            show_quest_mobs = val
        end
    end
    local show_herbs = false
    if menu_elements.show_herbs and menu_elements.show_herbs.get_state then
        local ok, val = pcall(menu_elements.show_herbs.get_state, menu_elements.show_herbs)
        if ok and val ~= nil then
            show_herbs = val
        end
    end
    local show_mining = false
    if menu_elements.show_mining and menu_elements.show_mining.get_state then
        local ok, val = pcall(menu_elements.show_mining.get_state, menu_elements.show_mining)
        if ok and val ~= nil then
            show_mining = val
        end
    end
    local show_chests = false
    if menu_elements.show_chests and menu_elements.show_chests.get_state then
        local ok, val = pcall(menu_elements.show_chests.get_state, menu_elements.show_chests)
        if ok and val ~= nil then
            show_chests = val
        end
    end
    local show_fishing = false
    if menu_elements.show_fishing and menu_elements.show_fishing.get_state then
        local ok, val = pcall(menu_elements.show_fishing.get_state, menu_elements.show_fishing)
        if ok and val ~= nil then
            show_fishing = val
        end
    end
    -- Verwende gecachte Spielerposition für Frame-Konsistenz
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    local player_rotation = 0.0
    if local_player.get_rotation then
        local ok_rot, rot = pcall(local_player.get_rotation, local_player)
        if ok_rot and rot then
            player_rotation = rot
        end
    end
    
    -- Position aus Slidern laden (persistent, einstellbar im Menü)
    local radar_pos_x = 100.0
    local radar_pos_y = 100.0
    if menu_elements.radar_pos_x and menu_elements.radar_pos_x.get then
        local ok, val = pcall(menu_elements.radar_pos_x.get, menu_elements.radar_pos_x)
        if ok and val and type(val) == "number" then
            radar_pos_x = val
        end
    end
    if menu_elements.radar_pos_y and menu_elements.radar_pos_y.get then
        local ok, val = pcall(menu_elements.radar_pos_y.get, menu_elements.radar_pos_y)
        if ok and val and type(val) == "number" then
            radar_pos_y = val
        end
    end
    
    -- Berechne Radar-Zentrum
    local center_x = radar_pos_x + radar_size / 2.0
    local center_y = radar_pos_y + radar_size / 2.0
    local radar_radius = radar_size / 2.0 - 10.0
    local bg_rect_size = radar_size
    
    -- Hintergrund zeichnen
    core.graphics.rect_2d_filled(
        vec2_new(radar_pos_x, radar_pos_y),
        bg_rect_size,
        bg_rect_size,
        radar_bg_color,
        radar_radius + 5.0
    )
    core.graphics.circle_2d(
        vec2_new(center_x, center_y),
        radar_radius,
        radar_border_color,
        2.0
    )
    local line_length = radar_radius * 0.8
    local rotation_offset = -player_rotation - math.pi / 2.0
    local cos_rot = math.cos(rotation_offset)
    local sin_rot = math.sin(rotation_offset)
    local h_start_x = center_x + (-line_length * cos_rot)
    local h_start_y = center_y + (-line_length * sin_rot)
    local h_end_x = center_x + (line_length * cos_rot)
    local h_end_y = center_y + (line_length * sin_rot)
    core.graphics.line_2d(
        vec2_new(h_start_x, h_start_y),
        vec2_new(h_end_x, h_end_y),
        color.new(255, 255, 255, 50),
        1.0
    )
    local v_start_x = center_x + (line_length * sin_rot)
    local v_start_y = center_y + (-line_length * cos_rot)
    local v_end_x = center_x + (-line_length * sin_rot)
    local v_end_y = center_y + (line_length * cos_rot)
    core.graphics.line_2d(
        vec2_new(v_start_x, v_start_y),
        vec2_new(v_end_x, v_end_y),
        color.new(255, 255, 255, 50),
        1.0
    )
    local player_blip_pos = vec2_new(center_x, center_y)
    
    -- Kleiner Spieler-Punkt
    core.graphics.circle_2d_filled(player_blip_pos, radar_blip_size * 1.2, radar_player_color)
    
    -- Kleiner gefüllter Pfeilkopf
    local arrow_rotation = -math.pi / 2.0
    local arrow_dist = radar_blip_size * 2.5
    local tip_x = center_x + math.cos(arrow_rotation) * arrow_dist
    local tip_y = center_y + math.sin(arrow_rotation) * arrow_dist
    
    local arrow_size = 4.0
    local wing_width = 2.5
    local back_offset = arrow_size * 0.8
    local perp_x = -math.sin(arrow_rotation) * wing_width
    local perp_y = math.cos(arrow_rotation) * wing_width
    
    -- Gefüllter Pfeilkopf
    core.graphics.triangle_2d_filled(
        vec2_new(tip_x, tip_y),
        vec2_new(tip_x - math.cos(arrow_rotation) * back_offset - perp_x, tip_y - math.sin(arrow_rotation) * back_offset - perp_y),
        vec2_new(tip_x - math.cos(arrow_rotation) * back_offset + perp_x, tip_y - math.sin(arrow_rotation) * back_offset + perp_y),
        radar_player_color
    )
    local objects = core.object_manager.get_all_objects()
    if objects then
        for _, obj in __object_safety.live_ipairs(objects) do
            if obj and obj:is_valid() then
                local obj_pos = nil
                if obj.get_position then
                    local ok_pos, pos = pcall(obj.get_position, obj)
                    if ok_pos and pos and pos.x and pos.y then
                        obj_pos = pos
                    end
                end
                if obj_pos then
                    local dx = obj_pos.x - player_pos.x
                    local dy = obj_pos.y - player_pos.y
                    local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if distance <= radar_range and distance <= max_distance and distance > 0.1 then
                        local angle = math.atan2(dy, dx)
                        local rotated_angle = angle - player_rotation - math.pi / 2.0
                        local normalized_dist = distance / radar_range
                        local radar_x = center_x + math.cos(rotated_angle) * normalized_dist * radar_radius
                        local radar_y = center_y + math.sin(rotated_angle) * normalized_dist * radar_radius
                        local blip_color = nil
                        local is_unit = false
                        if obj.is_unit then
                            local ok_unit, is_unit_res = pcall(obj.is_unit, obj)
                            if ok_unit then
                                is_unit = is_unit_res
                            end
                        end
                        if is_unit then
                            local is_dead = false
                            if obj.is_dead then
                                local ok, res = pcall(obj.is_dead, obj)
                                if ok then
                                    is_dead = res
                                end
                            end
                            if not is_dead then
                                local is_enemy = false
                                if obj.is_enemy_with then
                                    local ok, res = pcall(obj.is_enemy_with, obj, local_player)
                                    if ok then
                                        is_enemy = res
                                    end
                                end
                                -- Spieler-Pets nicht als Feinde anzeigen
                                if is_enemy and is_player_pet(obj) then
                                    is_enemy = false
                                end
                                local is_quest = false
                                if show_quest_mobs then
                                    is_quest = is_quest_object(obj)
                                    -- Spieler-Pets nicht als Quest-Objekte anzeigen
                                    if is_quest and is_player_pet(obj) then
                                        is_quest = false
                                    end
                                end
                                if is_enemy then
                                    blip_color = is_quest and radar_quest_color or radar_enemy_color
                                elseif is_quest then
                                    blip_color = radar_quest_color
                                end
                            end
                        else
                            local gather_type, gather_name = classify_gather_node(obj)
                            if gather_type then
                                -- Für Chests: Nur anzeigen wenn sie interagierbar sind
                                local chest_ok = true
                                if gather_type == "chest" then
                                    if obj.can_be_used then
                                        local ok_use, can_use = pcall(obj.can_be_used, obj)
                                        if ok_use then
                                            chest_ok = can_use
                                        end
                                    end
                                end
                                local should_show = (gather_type == "herb" and show_herbs) or
                                                  (gather_type == "mining" and show_mining) or
                                                  (gather_type == "chest" and show_chests and chest_ok) or
                                                  (gather_type == "fishing" and show_fishing)
                                if should_show then
                                    if gather_type == "fishing" then
                                        blip_color = radar_fishing_color
                                    else
                                        blip_color = radar_gathering_color
                                    end
                                end
                            else
                                local is_quest_item = false
                                if show_quest_mobs then
                                    is_quest_item = is_quest_object(obj)
                                    -- Spieler-Pets nicht als Quest-Objekte anzeigen
                                    if is_quest_item and is_player_pet(obj) then
                                        is_quest_item = false
                                    end
                                end
                                if is_quest_item then
                                    blip_color = radar_quest_item_color
                                end
                            end
                        end
                        if blip_color then
                            local blip_pos = vec2_new(radar_x, radar_y)
                            core.graphics.circle_2d_filled(
                                blip_pos,
                                radar_blip_size,
                                blip_color
                            )
                            local show_height = true
                            if menu_elements.radar_show_height and menu_elements.radar_show_height.get_state then
                                local ok, val = pcall(menu_elements.radar_show_height.get_state, menu_elements.radar_show_height)
                                if ok and val ~= nil then
                                    show_height = val
                                end
                            end
                            if show_height then
                                local height_diff = (obj_pos.z or 0) - (player_pos.z or 0)
                                local height_threshold = 1.0
                                if math.abs(height_diff) > height_threshold then
                                    -- Kompakte Farben
                                    local indicator_color = height_diff > 0 
                                        and color.new(50, 255, 100, 255)
                                        or color.new(255, 80, 80, 255)
                                    
                                    local indicator_size = 2.5
                                    local indicator_offset = radar_blip_size + 3.0
                                    
                                    if height_diff > 0 then
                                        -- Kleiner Pfeil nach oben
                                        core.graphics.triangle_2d_filled(
                                            vec2_new(radar_x, radar_y - indicator_offset),
                                            vec2_new(radar_x - indicator_size, radar_y - indicator_offset + indicator_size),
                                            vec2_new(radar_x + indicator_size, radar_y - indicator_offset + indicator_size),
                                            indicator_color
                                        )
                                    else
                                        -- Kleiner Pfeil nach unten
                                        core.graphics.triangle_2d_filled(
                                            vec2_new(radar_x, radar_y + indicator_offset),
                                            vec2_new(radar_x - indicator_size, radar_y + indicator_offset - indicator_size),
                                            vec2_new(radar_x + indicator_size, radar_y + indicator_offset - indicator_size),
                                            indicator_color
                                        )
                                    end
                                end
                            end
                            if radar_show_names and obj.get_name then
                                local ok_name, name = pcall(obj.get_name, obj)
                                if ok_name and name then
                                    core.graphics.text_2d(
                                        string.sub(name, 1, 10),
                                        vec2_new(radar_x, radar_y - 12),
                                        12,
                                        color.new(255, 255, 255, 200),
                                        true
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end  -- Ende: if objects then
    
    -- Settings Button unter dem Radar
    local button_width = 60
    local button_height = 20
    local button_x = center_x - button_width / 2
    local button_y = radar_pos_y + radar_size + 8
    
    -- Button Hintergrund
    local button_bg_color = radar_settings_button_hovered and color.new(80, 80, 100, 255) or color.new(40, 40, 60, 220)
    if radar_settings_popup_open then
        button_bg_color = color.new(100, 100, 140, 255)
    end
    
    pcall(core.graphics.rect_2d_filled, vec2_new(button_x, button_y), button_width, button_height, button_bg_color, 4)
    pcall(core.graphics.rect_2d, vec2_new(button_x, button_y), button_width, button_height, radar_border_color, 1.0, 4)
    
    -- F7 Hint Text
    pcall(core.graphics.text_2d, "Menu", vec2_new(button_x + button_width / 2, button_y + button_height / 2 - 5), 11, color.new(200, 200, 220, 255), true)
    
    -- Klick-Erkennung für Button (gleiche Methode wie Keybind)
    if settings_menu and core.input then
        -- Cursor Position holen
        local cursor_pos = nil
        if core.graphics and core.graphics.get_cursor_position then
            local ok, cpos = pcall(core.graphics.get_cursor_position)
            if ok and cpos and cpos.x and cpos.y then
                cursor_pos = cpos
            end
        end
        if not cursor_pos and core.input.get_cursor_position then
            local ok, cpos = pcall(core.input.get_cursor_position)
            if ok and cpos and cpos.x and cpos.y then
                cursor_pos = cpos
            end
        end
        
        if cursor_pos then
            -- Prüfe ob Cursor über Button ist
            local is_over = cursor_pos.x >= button_x and cursor_pos.x <= button_x + button_width and
                           cursor_pos.y >= button_y and cursor_pos.y <= button_y + button_height
            radar_settings_button_hovered = is_over
            
            -- Linke Maustaste prüfen (gleiche Methode wie F7 Key)
            if is_over and core.input.is_key_pressed then
                local ok, is_pressed = pcall(core.input.is_key_pressed, 1)  -- 1 = Left Mouse Button
                if ok and is_pressed and not radar_settings_button_was_pressed then
                    settings_menu:toggle()
                end
                radar_settings_button_was_pressed = is_pressed
            end
        end
    end
end
local function render_hardcore_dark_overlay()
    if not menu_elements.hardcore_dark_mode or not menu_elements.hardcore_dark_mode.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.hardcore_dark_mode.get_state, menu_elements.hardcore_dark_mode)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.graphics or not core.graphics.get_screen_size then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size or not screen_size.x or not screen_size.y then
        return
    end
    
    local intensity = 0.7
    if menu_elements.dark_mode_intensity and menu_elements.dark_mode_intensity.get then
        local ok, val = pcall(menu_elements.dark_mode_intensity.get, menu_elements.dark_mode_intensity)
        if ok and val and type(val) == "number" then
            intensity = val
        end
    end
    
    local dark_alpha = math.floor(intensity * 255)
    local dark_color = color.new(0, 0, 0, dark_alpha)
    
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(0, 0),
            screen_size.x,
            screen_size.y,
            dark_color,
            0
        )
    end
end

local function render_enemy_spotlights()
    if not menu_elements.enemy_spotlight or not menu_elements.enemy_spotlight.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.enemy_spotlight.get_state, menu_elements.enemy_spotlight)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager or not core.object_manager.get_all_objects then
        return
    end
    
    -- Verwende gecachte Spielerposition für Frame-Konsistenz
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    
    local max_distance = 100.0
    if menu_elements.max_distance and menu_elements.max_distance.get then
        local ok, val = pcall(menu_elements.max_distance.get, menu_elements.max_distance)
        if ok and val and type(val) == "number" then
            max_distance = val
        end
    end
    
    local spotlight_radius = 200.0
    if menu_elements.spotlight_radius and menu_elements.spotlight_radius.get then
        local ok, val = pcall(menu_elements.spotlight_radius.get, menu_elements.spotlight_radius)
        if ok and val and type(val) == "number" then
            spotlight_radius = val
        end
    end
    
    local spotlight_intensity = 0.5
    if menu_elements.spotlight_intensity and menu_elements.spotlight_intensity.get then
        local ok, val = pcall(menu_elements.spotlight_intensity.get, menu_elements.spotlight_intensity)
        if ok and val and type(val) == "number" then
            spotlight_intensity = val
        end
    end
    
    local objects = core.object_manager.get_all_objects()
    if not objects then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue
            end
            
            local obj_pos = nil
            if obj.get_position then
                local ok_pos, pos = pcall(obj.get_position, obj)
                if ok_pos and pos and pos.x and pos.y then
                    obj_pos = pos
                end
            end
            if not obj_pos then
                goto continue
            end
            
            local distance = math.sqrt(
                (obj_pos.x - player_pos.x) * (obj_pos.x - player_pos.x) +
                (obj_pos.y - player_pos.y) * (obj_pos.y - player_pos.y) +
                ((obj_pos.z or 0) - (player_pos.z or 0)) * ((obj_pos.z or 0) - (player_pos.z or 0))
            )
            
            if distance > max_distance then
                goto continue
            end
            
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                if ok_enemy and enemy then
                    is_enemy = enemy
                end
            end
            -- Spieler-Pets nicht als Feinde anzeigen
            if is_enemy and is_player_pet(obj) then
                is_enemy = false
            end
            
            if is_enemy then
                local is_dead = false
                if obj.is_dead then
                    local ok_dead, dead = pcall(obj.is_dead, obj)
                    if ok_dead and dead then
                        is_dead = dead
                    end
                end
                
                if not is_dead then
                    local screen_pos = nil
                    if core.graphics and core.graphics.w2s then
                        local ok_screen, screen = pcall(core.graphics.w2s, obj_pos)
                        if ok_screen and screen and screen.x and screen.y then
                            screen_pos = screen
                        end
                    end
                    
                    if screen_pos then
                        local num_rings = 15
                        for i = 1, num_rings do
                            local progress = i / num_rings
                            local ring_radius = spotlight_radius * progress
                            local alpha_multiplier = (1.0 - progress) * (1.0 - progress) * spotlight_intensity
                            local ring_alpha = math.floor(alpha_multiplier * 255)
                            
                            if ring_alpha > 5 and core.graphics and core.graphics.circle_2d_filled then
                                local ring_color = color.new(255, 255, 200, ring_alpha)
                                pcall(core.graphics.circle_2d_filled,
                                    vec2_new(screen_pos.x, screen_pos.y),
                                    ring_radius,
                                    ring_color
                                )
                            end
                        end
                    end
                end
            end
            
            ::continue::
        end
    end
end

-- Präzise Aggro-Radius-Berechnung basierend auf Level-Differenz
local function calculate_accurate_aggro_radius(player_level, mob_level)
    if not player_level or not mob_level then
        return 20.0
    end
    
    local level_diff = mob_level - player_level
    
    -- Spieler höher als Mob
    if level_diff <= 0 then
        local diff = math.abs(level_diff)
        if diff >= 15 then
            return 5.0
        elseif diff >= 10 then
            return 10.0
        elseif diff >= 5 then
            return 15.0
        elseif diff >= 3 then
            return 17.0
        elseif diff >= 1 then
            return 19.0
        else
            return 20.0
        end
    else
        -- Mob höher als Spieler
        if level_diff >= 25 then
            return 45.0
        elseif level_diff >= 20 then
            return 40.0
        elseif level_diff >= 10 then
            return 30.0
        elseif level_diff >= 5 then
            return 25.0
        elseif level_diff >= 3 then
            return 23.0
        elseif level_diff >= 1 then
            return 21.0
        else
            return 20.0
        end
    end
end

local function render_hardcore_danger_zones()
    local hardcore_enabled = false
    if menu_elements.hardcore_dark_mode and menu_elements.hardcore_dark_mode.get_state then
        local ok, val = pcall(menu_elements.hardcore_dark_mode.get_state, menu_elements.hardcore_dark_mode)
        if ok and val ~= nil then
            hardcore_enabled = val
        end
    end
    
    if not hardcore_enabled then
        return
    end
    
    local show_danger_zones = true
    if menu_elements.show_danger_zones and menu_elements.show_danger_zones.get_state then
        local ok, val = pcall(menu_elements.show_danger_zones.get_state, menu_elements.show_danger_zones)
        if ok and val ~= nil then
            show_danger_zones = val
        end
    end
    
    if not show_danger_zones then
        return
    end
    
    if not core or not core.object_manager or not core.object_manager.get_all_objects then
        return
    end
    
    -- Verwende gecachte Spielerposition für Frame-Konsistenz
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    
    local player_level = nil
    if local_player.level then
        local ok_lvl, lvl = pcall(local_player.level, local_player)
        if ok_lvl and lvl then
            player_level = lvl
        end
    end
    
    local max_distance = 100.0
    if menu_elements.max_distance and menu_elements.max_distance.get then
        local ok, val = pcall(menu_elements.max_distance.get, menu_elements.max_distance)
        if ok and val and type(val) == "number" then
            max_distance = val
        end
    end
    
    local danger_zone_scale = 1.0
    if menu_elements.danger_zone_scale and menu_elements.danger_zone_scale.get then
        local ok, val = pcall(menu_elements.danger_zone_scale.get, menu_elements.danger_zone_scale)
        if ok and val and type(val) == "number" then
            danger_zone_scale = val
        end
    end
    
    
    local objects = core.object_manager.get_all_objects()
    if not objects then
        return
    end
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue
            end
            
            local obj_pos = nil
            if obj.get_position then
                local ok_pos, pos = pcall(obj.get_position, obj)
                if ok_pos and pos and pos.x and pos.y then
                    obj_pos = pos
                end
            end
            if not obj_pos then
                goto continue
            end
            
            local horizontal_distance = math.sqrt(
                (obj_pos.x - player_pos.x) * (obj_pos.x - player_pos.x) +
                (obj_pos.y - player_pos.y) * (obj_pos.y - player_pos.y)
            )
            
            local vertical_distance = math.abs((obj_pos.z or 0) - (player_pos.z or 0))
            -- Vertikale Distanz zählt 1.5-2x stärker
            local effective_vertical_distance = vertical_distance * 1.75
            local effective_distance = math.sqrt(horizontal_distance * horizontal_distance + effective_vertical_distance * effective_vertical_distance)
            
            if effective_distance > max_distance then
                goto continue
            end
            
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                if ok_enemy and enemy then
                    is_enemy = enemy
                end
            end
            -- Spieler-Pets nicht als Feinde anzeigen
            if is_enemy and is_player_pet(obj) then
                is_enemy = false
            end
            
            if is_enemy then
                local is_dead = false
                if obj.is_dead then
                    local ok_dead, dead = pcall(obj.is_dead, obj)
                    if ok_dead and dead then
                        is_dead = dead
                    end
                end
                
                -- Cave Mode Filter für Danger Zones
                local player_facing = nil
                if local_player and local_player.get_facing then
                    local ok_f, f = pcall(local_player.get_facing, local_player)
                    if ok_f then player_facing = f end
                end
                local cave_mode_pass = cave_mode_filter(obj_pos, player_pos, player_facing)
                
                if not is_dead and cave_mode_pass then
                    local render_pos = obj_pos
                    
                    -- Präzise Aggro-Radius-Berechnung basierend auf Level-Differenz
                    local mob_level = nil
                    if obj.level then
                        local ok_lvl, lvl = pcall(obj.level, obj)
                        if ok_lvl and lvl then
                            mob_level = lvl
                        end
                    end
                    
                    local actual_aggro_radius = 20.0
                    if player_level and mob_level then
                        actual_aggro_radius = calculate_accurate_aggro_radius(player_level, mob_level)
                    end
                    
                    -- Scale anwenden
                    actual_aggro_radius = actual_aggro_radius * danger_zone_scale
                    
                    -- Assist-Aggro-Radius (10-15 Yards) - durchschnittlich 12.5
                    local assist_aggro_radius = 12.5 * danger_zone_scale
                    
                    -- Vertikale Distanz berücksichtigen: Wenn Mob deutlich höher/tiefer, reduziere effektiven Radius
                    local vertical_modifier = 1.0
                    if vertical_distance > 8.0 then
                        -- Mob ist sehr weit über/unter dem Spieler - Aggro wird unwahrscheinlicher
                        vertical_modifier = 0.5
                    elseif vertical_distance > 5.0 then
                        vertical_modifier = 0.7
                    elseif vertical_distance > 3.0 then
                        vertical_modifier = 0.85
                    end
                    
                    local effective_aggro_radius = actual_aggro_radius * vertical_modifier
                    
                    if effective_aggro_radius < 1.0 then
                        effective_aggro_radius = 1.0
                    elseif effective_aggro_radius > 60.0 then
                        effective_aggro_radius = 60.0
                    end
                    
                    local danger_thickness = 3.0
                    
                    -- Position leicht über dem Boden für bessere Sichtbarkeit
                    local ground_pos = {
                        x = render_pos.x,
                        y = render_pos.y,
                        z = (render_pos.z or 0) + 0.1
                    }
                    
                    -- Nur gefüllter Kreis am Boden (Danger Zone) mit cone_3d für glattes Rendering
                    if core.graphics and core.graphics.cone_3d then
                        -- Hole Danger Zone Farbe live aus dem Color-Picker (wie andere Farben auch)
                        local filled_color = get_live_color(menu_elements.danger_zone_color, color.new(255, 165, 0, 255))
                        
                        -- Zielposition für cone_3d (Richtung)
                        local target_pos = {
                            x = ground_pos.x + 1,
                            y = ground_pos.y,
                            z = ground_pos.z
                        }
                        -- cone_3d mit 360° = voller Kreis, fade_power für weichen Rand
                        pcall(core.graphics.cone_3d, ground_pos, target_pos, effective_aggro_radius, 360, filled_color, 1.5)
                        
                        -- Warnung wenn Spieler in Zone - rot gefüllt
                        if effective_distance <= effective_aggro_radius then
                            local warning_filled_color = color.new(255, 50, 50, 50)
                            pcall(core.graphics.cone_3d, ground_pos, target_pos, effective_aggro_radius, 360, warning_filled_color, 1.5)
                        end
                    end
                end
            end
            
            ::continue::
        end
    end
end

-- ============================================================================

-- Helper: Speichere Position für Health Bar (als % der Bildschirmgröße)
local function save_health_bar_position(pos_x, pos_y, screen_size)
    if menu_elements.health_bar_pos_x and menu_elements.health_bar_pos_x.set then
        local percent_x = (pos_x / screen_size.x) * 100.0
        pcall(menu_elements.health_bar_pos_x.set, menu_elements.health_bar_pos_x, percent_x)
    end
    if menu_elements.health_bar_pos_y and menu_elements.health_bar_pos_y.set then
        local percent_y = (pos_y / screen_size.y) * 100.0
        pcall(menu_elements.health_bar_pos_y.set, menu_elements.health_bar_pos_y, percent_y)
    end
end

-- Helper: Lade Position für Health Bar (aus % zu Pixel)
local function load_health_bar_position(screen_size)
    local pos_x = screen_size.x * 0.5  -- Default: zentriert
    local pos_y = screen_size.y * 0.75  -- Default: 75% von oben
    
    if menu_elements.health_bar_pos_x and menu_elements.health_bar_pos_x.get then
        local ok, val = pcall(menu_elements.health_bar_pos_x.get, menu_elements.health_bar_pos_x)
        if ok and val and type(val) == "number" then
            pos_x = (val / 100.0) * screen_size.x
        end
    end
    if menu_elements.health_bar_pos_y and menu_elements.health_bar_pos_y.get then
        local ok, val = pcall(menu_elements.health_bar_pos_y.get, menu_elements.health_bar_pos_y)
        if ok and val and type(val) == "number" then
            pos_y = (val / 100.0) * screen_size.y
        end
    end
    
    return pos_x, pos_y
end

-- Helper: Speichere Position für XP Bar (als % der Bildschirmgröße)
local function save_xp_bar_position(pos_x, pos_y, screen_size)
    if menu_elements.xp_bar_pos_x and menu_elements.xp_bar_pos_x.set then
        local percent_x = (pos_x / screen_size.x) * 100.0
        pcall(menu_elements.xp_bar_pos_x.set, menu_elements.xp_bar_pos_x, percent_x)
    end
    if menu_elements.xp_bar_pos_y and menu_elements.xp_bar_pos_y.set then
        local percent_y = (pos_y / screen_size.y) * 100.0
        pcall(menu_elements.xp_bar_pos_y.set, menu_elements.xp_bar_pos_y, percent_y)
    end
end

-- Helper: Lade Position für XP Bar (aus % zu Pixel)
local function load_xp_bar_position(screen_size)
    local pos_x = screen_size.x * 0.5  -- Default: zentriert
    local pos_y = 25  -- Default: 25 Pixel (wird zu % konvertiert)
    
    if menu_elements.xp_bar_pos_x and menu_elements.xp_bar_pos_x.get then
        local ok, val = pcall(menu_elements.xp_bar_pos_x.get, menu_elements.xp_bar_pos_x)
        if ok and val and type(val) == "number" then
            pos_x = (val / 100.0) * screen_size.x
        end
    end
    if menu_elements.xp_bar_pos_y and menu_elements.xp_bar_pos_y.get then
        local ok, val = pcall(menu_elements.xp_bar_pos_y.get, menu_elements.xp_bar_pos_y)
        if ok and val and type(val) == "number" then
            pos_y = (val / 100.0) * screen_size.y
        end
    end
    
    return pos_x, pos_y
end

-- Helper: Speichere Position für Cast Bar (als % der Bildschirmgröße)
local function save_cast_bar_position(pos_x, pos_y, screen_size)
    if menu_elements.cast_bar_pos_x and menu_elements.cast_bar_pos_x.set then
        local percent_x = (pos_x / screen_size.x) * 100.0
        pcall(menu_elements.cast_bar_pos_x.set, menu_elements.cast_bar_pos_x, percent_x)
    end
    if menu_elements.cast_bar_pos_y and menu_elements.cast_bar_pos_y.set then
        local percent_y = (pos_y / screen_size.y) * 100.0
        pcall(menu_elements.cast_bar_pos_y.set, menu_elements.cast_bar_pos_y, percent_y)
    end
end

-- Helper: Lade Position für Cast Bar (aus % zu Pixel)
local function load_cast_bar_position(screen_size, hp_bar_y, hp_bar_height)
    local pos_x = screen_size.x * 0.5  -- Default: zentriert
    local pos_y = hp_bar_y + hp_bar_height + 10  -- Default: unter Health Bar
    
    if menu_elements.cast_bar_pos_x and menu_elements.cast_bar_pos_x.get then
        local ok, val = pcall(menu_elements.cast_bar_pos_x.get, menu_elements.cast_bar_pos_x)
        if ok and val and type(val) == "number" then
            pos_x = (val / 100.0) * screen_size.x
        end
    end
    if menu_elements.cast_bar_pos_y and menu_elements.cast_bar_pos_y.get then
        local ok, val = pcall(menu_elements.cast_bar_pos_y.get, menu_elements.cast_bar_pos_y)
        if ok and val and type(val) == "number" then
            pos_y = (val / 100.0) * screen_size.y
        end
    end
    
    return pos_x, pos_y
end

-- Helper: Lade Position für Target Bar (aus % zu Pixel)
local function load_target_bar_position(screen_size)
    local pos_x = screen_size.x * 0.5  -- Default: zentriert
    local pos_y = screen_size.y * 0.25  -- Default: 25% von oben
    
    if menu_elements.target_bar_pos_x and menu_elements.target_bar_pos_x.get then
        local ok, val = pcall(menu_elements.target_bar_pos_x.get, menu_elements.target_bar_pos_x)
        if ok and val and type(val) == "number" then
            pos_x = (val / 100.0) * screen_size.x
        end
    end
    if menu_elements.target_bar_pos_y and menu_elements.target_bar_pos_y.get then
        local ok, val = pcall(menu_elements.target_bar_pos_y.get, menu_elements.target_bar_pos_y)
        if ok and val and type(val) == "number" then
            pos_y = (val / 100.0) * screen_size.y
        end
    end
    
    return pos_x, pos_y
end

-- Helper: Lade Position für Pet Bar (aus % zu Pixel)
local function load_pet_bar_position(screen_size)
    local pos_x = screen_size.x * 0.5  -- Default: zentriert
    local pos_y = screen_size.y * 0.85  -- Default: 85% von oben (unter Player Bar)
    
    if menu_elements.pet_bar_pos_x and menu_elements.pet_bar_pos_x.get then
        local ok, val = pcall(menu_elements.pet_bar_pos_x.get, menu_elements.pet_bar_pos_x)
        if ok and val and type(val) == "number" then
            pos_x = (val / 100.0) * screen_size.x
        end
    end
    if menu_elements.pet_bar_pos_y and menu_elements.pet_bar_pos_y.get then
        local ok, val = pcall(menu_elements.pet_bar_pos_y.get, menu_elements.pet_bar_pos_y)
        if ok and val and type(val) == "number" then
            pos_y = (val / 100.0) * screen_size.y
        end
    end
    
    return pos_x, pos_y
end

-- Helper: Finde das Pet des Spielers
local function get_player_pet(local_player)
    if not local_player or not core or not core.object_manager then
        return nil
    end
    
    -- Methode 1: Versuche direkte API (falls verfügbar)
    if local_player.get_pet then
        local ok, pet = pcall(local_player.get_pet, local_player)
        if ok and pet then
            return pet
        end
    end
    
    local player_guid = nil
    if local_player.get_guid then
        local ok, guid = pcall(local_player.get_guid, local_player)
        if ok and guid then
            player_guid = guid
        end
    end
    
    if not player_guid then
        return nil
    end
    
    -- Methode 2: Iteriere über alle Objekte und finde das Pet des Spielers
    -- Verwende die gleiche Methode wie im ESP-Code
    local objects = core.object_manager.get_all_objects()
    if not objects then
        return nil
    end
    
    local player_pos = cached_player_pos
    local closest_pet = nil
    local closest_distance = 999999
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue_pet_search
            end
            
            -- Prüfe ob es ein Pet ist
            if is_player_pet(obj) then
                local is_player_pet_obj = false
                
                -- Prüfe ob dieses Pet dem Spieler gehört
                if obj.get_pet_owner then
                    local ok, owner = pcall(obj.get_pet_owner, obj)
                    if ok and owner then
                        -- Direkter Vergleich (schneller)
                        if (__object_safety.same(owner,local_player)) then
                            is_player_pet_obj = true
                        else
                            -- GUID-Vergleich
                            local owner_guid = nil
                            if owner.get_guid then
                                local ok_guid, guid = pcall(owner.get_guid, owner)
                                if ok_guid and guid and guid == player_guid then
                                    is_player_pet_obj = true
                                end
                            end
                        end
                    end
                end
                
                -- Alternative: Prüfe über get_summoner
                if not is_player_pet_obj and obj.get_summoner then
                    local ok, summoner = pcall(obj.get_summoner, obj)
                    if ok and summoner then
                        if (__object_safety.same(summoner,local_player)) then
                            is_player_pet_obj = true
                        else
                            local summoner_guid = nil
                            if summoner.get_guid then
                                local ok_guid, guid = pcall(summoner.get_guid, summoner)
                                if ok_guid and guid and guid == player_guid then
                                    is_player_pet_obj = true
                                end
                            end
                        end
                    end
                end
                
                -- Wenn Owner gefunden wurde, direkt zurückgeben
                if is_player_pet_obj then
                    return obj
                end
                
                -- Fallback: Wenn es ein Pet ist und nah beim Spieler ist, könnte es unseres sein
                if player_pos then
                    local obj_pos = nil
                    if obj.get_position then
                        local ok_pos, pos = pcall(obj.get_position, obj)
                        if ok_pos and pos and pos.x and pos.y then
                            obj_pos = pos
                        end
                    end
                    if obj_pos then
                        local dx = obj_pos.x - player_pos.x
                        local dy = obj_pos.y - player_pos.y
                        local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                        local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                        -- Wenn Pet sehr nah ist (innerhalb 50 Yards), könnte es unseres sein
                        if distance < 50 and distance < closest_distance then
                            closest_pet = obj
                            closest_distance = distance
                        end
                    end
                end
            end
        end
        ::continue_pet_search::
    end
    
    -- Wenn kein Pet mit Owner gefunden wurde, aber ein nahes Pet existiert, verwende das
    if closest_pet then
        return closest_pet
    end
    
    return nil
end

-- ============================================================================
-- Health & Resource Monitor Overlay
-- ============================================================================
local function render_health_resource_overlay()
    if not menu_elements.health_resource_overlay or not menu_elements.health_resource_overlay.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.health_resource_overlay.get_state, menu_elements.health_resource_overlay)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- HP-Bar Position laden (aus Slidern oder Default)
    local hp_bar_x, hp_bar_y = load_health_bar_position(screen_size)
    local ui_scale = get_element_scale(menu_elements.health_resource_overlay_scale)
    local hp_bar_width = 400 * ui_scale
    local hp_bar_height = 30 * ui_scale
    
    local current_hp = 0
    local max_hp = 1
    if local_player.get_health then
        local ok, hp = pcall(local_player.get_health, local_player)
        if ok and hp and type(hp) == "number" then
            current_hp = hp
        end
    end
    if local_player.get_max_health then
        local ok, max = pcall(local_player.get_max_health, local_player)
        if ok and max and type(max) == "number" then
            max_hp = max
        end
    end
    
    local hp_ratio = max_hp > 0 and (current_hp / max_hp) or 0
    
    -- HP-Bar Hintergrund (TabMenu-Stil)
    local bg_color = color.new(18, 15, 25, 230)
    local border_color = color.new(100, 67, 150, 220)
    
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
            hp_bar_width,
            hp_bar_height,
            bg_color,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(hp_bar_x - hp_bar_width * 0.5, hp_bar_y - hp_bar_height * 0.5),
                hp_bar_width,
                hp_bar_height,
                border_color,
                1.0,
                6.0
            )
        end
    end
    
    -- HP-Bar Füllung
    local fill_width = hp_bar_width * hp_ratio
    local fill_color = color.new(100, 255, 150, 255)
    if hp_ratio < 0.3 then
        fill_color = color.new(255, 100, 120, 255)
        local blink = math.floor((core.time() * 2) % 2)
        if blink == 0 then
            fill_color = color.new(255, 150, 150, 255)
        end
    elseif hp_ratio < 0.6 then
        fill_color = color.new(255, 180, 80, 255)
    end
    
    if fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(hp_bar_x - hp_bar_width * 0.5 + 3, hp_bar_y - hp_bar_height * 0.5 + 3),
            fill_width - 6,
            hp_bar_height - 6,
            fill_color,
            4.0
        )
    end
    
    -- HP-Text (TabMenu-Stil: heller Text, zentriert)
    local hp_text = string.format("HP: %d / %d (%.0f%%)", math.floor(current_hp), math.floor(max_hp), hp_ratio * 100)
    local text_color = color.new(220, 200, 255, 255)  -- TabMenu-Text-Farbe
    local outline_color = color.new(0, 0, 0, 200)  -- Leichte Umrandung für Lesbarkeit
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        -- Text-Größe berechnen für Zentrierung (approximativ - Font-Größe / 2 für vertikale Zentrierung)
        local text_x = hp_bar_x  -- Horizontal bereits zentriert (bar_x ist Bar-Mitte)
        local text_y = hp_bar_y - font_size * 0.25  -- Vertikal zentriert (etwa halbe Font-Größe nach oben verschieben)
        -- Umrandung (mehrfach zeichnen mit kleinen Offsets)
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, hp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        -- Haupttext
        pcall(core.graphics.text_2d, hp_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
    
    -- Power/Mana Bar (unter der HP Bar)
    local power_bar_y = hp_bar_y + hp_bar_height + 10
    local current_power = 0
    local max_power = 1
    local power_type = 0  -- Default: Mana
    
    -- Bestimme Power-Type basierend auf Klasse
    -- WoW Klassen-IDs: 1=Warrior, 2=Paladin, 3=Hunter, 4=Rogue, 5=Priest, 6=DK, 7=Shaman, 8=Mage, 9=Warlock, 10=Monk, 11=Druid, 12=DH
    -- Power Types: 0=Mana, 1=Rage, 2=Focus, 3=Energy, 6=Runic Power
    local player_class = 0
    if local_player.get_class then
        local ok_class, cls = pcall(local_player.get_class, local_player)
        if ok_class and cls and type(cls) == "number" then
            player_class = cls
        end
    end
    
    -- Setze erwarteten Power-Type basierend auf Klasse
    local expected_power_type = 0  -- Default: Mana
    if player_class == 1 then
        expected_power_type = 1  -- Warrior: Rage
    elseif player_class == 4 then
        expected_power_type = 3  -- Rogue: Energy
    elseif player_class == 6 then
        expected_power_type = 6  -- Death Knight: Runic Power
    elseif player_class == 3 then
        expected_power_type = 2  -- Hunter: Focus
    elseif player_class == 10 then
        expected_power_type = 3  -- Monk: Energy
    elseif player_class == 12 then
        expected_power_type = 17  -- Demon Hunter: Fury
    end
    
    -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
    local best_power_type = expected_power_type
    local best_max_power = 0
    
    if local_player.get_max_power then
        -- Prüfe alle relevanten Power-Types
        local power_types_to_check = {0, 1, 2, 3, 6, 17}  -- Mana, Rage, Focus, Energy, Runic Power, Fury
        
        for _, pt in ipairs(power_types_to_check) do
            local ok_mp, mp = pcall(local_player.get_max_power, local_player, pt)
            if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                best_max_power = mp
                best_power_type = pt
                    end
                end
                
        -- Spezielle Logik für Druiden: Wenn mehrere Power-Types vorhanden sind, verwende den höchsten
        if player_class == 11 then
            local mana_max = 0
            local rage_max = 0
            local energy_max = 0
            local ok_mm, mm = pcall(local_player.get_max_power, local_player, 0)
            if ok_mm and mm and type(mm) == "number" then mana_max = mm end
            local ok_rm, rm = pcall(local_player.get_max_power, local_player, 1)
            if ok_rm and rm and type(rm) == "number" then rage_max = rm end
            local ok_em, em = pcall(local_player.get_max_power, local_player, 3)
            if ok_em and em and type(em) == "number" then energy_max = em end
            
            if energy_max > mana_max and energy_max > rage_max then
                best_power_type = 3  -- Energy (Cat Form)
                best_max_power = energy_max
            elseif rage_max > mana_max and rage_max > energy_max then
                best_power_type = 1  -- Rage (Bear Form)
                best_max_power = rage_max
            elseif mana_max > 0 then
                best_power_type = 0  -- Mana (Caster/Heal Form)
                best_max_power = mana_max
            end
        end
    end
    
    power_type = best_power_type
    
    -- Hole Power-Werte basierend auf erkanntem Power-Type
    if local_player.get_power and local_player.get_max_power then
        local ok_p, power = pcall(local_player.get_power, local_player, power_type)
        local ok_mp, max = pcall(local_player.get_max_power, local_player, power_type)
        if ok_p and ok_mp and power and max and type(power) == "number" and type(max) == "number" and max > 0 then
            current_power = power
            max_power = max
        end
    end
    
    local power_ratio = max_power > 0 and (current_power / max_power) or 0
    
    -- Power-Bar Hintergrund (TabMenu-Stil)
    local power_bg_color = color.new(18, 15, 25, 230)
    local power_border_color = color.new(100, 67, 150, 220)
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - hp_bar_height * 0.5),
            hp_bar_width,
            hp_bar_height,
            power_bg_color,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(hp_bar_x - hp_bar_width * 0.5, power_bar_y - hp_bar_height * 0.5),
                hp_bar_width,
                hp_bar_height,
                power_border_color,
                1.0,
                6.0
            )
        end
    end

    -- Power-Bar Füllung (Farbe basierend auf Power-Typ)
    local power_fill_color = color.new(100, 150, 255, 255)  -- Standard: Blau (Mana)
    if power_type == 1 then
        power_fill_color = color.new(255, 50, 50, 255)  -- Rage: Rot
    elseif power_type == 2 then
        power_fill_color = color.new(255, 180, 80, 255)  -- Focus: Orange
    elseif power_type == 3 then
        power_fill_color = color.new(255, 255, 100, 255)  -- Energy: Gelb
    elseif power_type == 6 then
        power_fill_color = color.new(0, 200, 255, 255)  -- Runic Power: Cyan
    elseif power_type == 17 then
        power_fill_color = color.new(200, 100, 255, 255)  -- Fury (DH): Lila
    end
    
    local power_fill_width = hp_bar_width * power_ratio
    if power_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(hp_bar_x - hp_bar_width * 0.5 + 3, power_bar_y - hp_bar_height * 0.5 + 3),
            power_fill_width - 6,
            hp_bar_height - 6,
            power_fill_color,
            4.0
        )
    end
    
    -- Power-Text mit schwarzer Umrandung
    local power_type_name = "Mana"
    if power_type == 1 then
        power_type_name = "Rage"
    elseif power_type == 2 then
        power_type_name = "Focus"
    elseif power_type == 3 then
        power_type_name = "Energy"
    elseif power_type == 6 then
        power_type_name = "Runic Power"
    elseif power_type == 17 then
        power_type_name = "Fury"
    end
    
    local power_text = string.format("%s: %d / %d (%.0f%%)", power_type_name, math.floor(current_power), math.floor(max_power), power_ratio * 100)
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        -- Text zentriert (horizontal und vertikal)
        local text_x = hp_bar_x  -- Horizontal bereits zentriert (bar_x ist Bar-Mitte)
        local text_y = power_bar_y - font_size * 0.25  -- Vertikal zentriert (etwa halbe Font-Größe nach oben verschieben)
        -- Umrandung (mehrfach zeichnen mit kleinen Offsets)
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, power_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        -- Haupttext (TabMenu-Stil)
        pcall(core.graphics.text_2d, power_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
    
    -- Cast-Bar (unter der Power-Bar, nur wenn Spieler castet)
    -- Direkte API-Aufrufe da get_unit_cast_info hier nicht verfügbar ist
    local show_player_cast_bar = true
    if menu_elements.show_player_cast_bar and menu_elements.show_player_cast_bar.get_state then
        local ok_pcb, val_pcb = pcall(menu_elements.show_player_cast_bar.get_state, menu_elements.show_player_cast_bar)
        if ok_pcb and val_pcb ~= nil then show_player_cast_bar = val_pcb end
    end
    
    if show_player_cast_bar then
        local is_casting = local_player:is_casting_spell()
        local is_channeling = local_player:is_channelling_spell()
        
        if is_casting or is_channeling then
        local cast_spell = nil
        local cast_progress = 0.0
        local is_channel = is_channeling
        
        -- Hole Spell-ID
        local spell_id = 0
        if is_casting then
            spell_id = local_player:get_active_spell_id()
        else
            spell_id = local_player:get_active_channel_spell_id()
        end
        
        -- Hole Cast-Progress über Zeit-Berechnung
        local start_time, end_time
        if is_casting then
            start_time = local_player:get_active_spell_cast_start_time()
            end_time = local_player:get_active_spell_cast_end_time()
        else
            start_time = local_player:get_active_channel_cast_start_time()
            end_time = local_player:get_active_channel_cast_end_time()
        end
        
        if start_time and end_time and start_time > 0 and end_time > start_time then
            local current_time = core.game_time()
            local total_time = end_time - start_time
            local elapsed = current_time - start_time
            if elapsed >= 0 and total_time > 0 then
                cast_progress = math.max(0.0, math.min(1.0, elapsed / total_time))
            end
        end
        
        -- Hole Spell-Name
        if spell_id and spell_id > 0 then
            if core.spell_book and core.spell_book.get_spell_name then
                cast_spell = core.spell_book.get_spell_name(spell_id)
            end
            if not cast_spell or cast_spell == "" then
                cast_spell = is_channel and "Channeling" or "Casting"
            end
        else
            cast_spell = is_channel and "Channeling" or "Casting"
        end
        
        -- Cast Bar Position laden (aus Slidern oder Default)
        local cast_bar_x, cast_bar_y = load_cast_bar_position(screen_size, hp_bar_y, hp_bar_height)
        
        -- Player Cast Bar verwendet eigenen Scale
        local player_cast_scale = get_element_scale(menu_elements.player_cast_bar_scale)
        local cast_bar_width = hp_bar_width * (player_cast_scale / ui_scale)  -- Relativ zum Health Bar Scale
        local cast_bar_height_scaled = hp_bar_height * (player_cast_scale / ui_scale)
        
        -- Cast-Bar Hintergrund (TabMenu-Stil)
        local cast_bg_color = color.new(18, 15, 25, 230)
        local cast_border_color = color.new(100, 67, 150, 220)
        if core.graphics and core.graphics.rect_2d_filled then
            pcall(core.graphics.rect_2d_filled,
                vec2_new(cast_bar_x - cast_bar_width * 0.5, cast_bar_y - cast_bar_height_scaled * 0.5),
                cast_bar_width,
                cast_bar_height_scaled,
                cast_bg_color,
                6.0
            )
            if core.graphics.rect_2d then
                pcall(core.graphics.rect_2d,
                    vec2_new(cast_bar_x - cast_bar_width * 0.5, cast_bar_y - cast_bar_height_scaled * 0.5),
                    cast_bar_width,
                    cast_bar_height_scaled,
                    cast_border_color,
                    1.0,
                    6.0
                )
            end
        end
        
        -- Cast-Bar Füllung (Farbe basierend auf Cast/Channel)
        local cast_fill_color = is_channel and color.new(180, 100, 255, 255) or color.new(255, 200, 50, 255)
        local cast_fill_width = cast_bar_width * math.max(0.01, cast_progress)
        if cast_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
            pcall(core.graphics.rect_2d_filled,
                vec2_new(cast_bar_x - cast_bar_width * 0.5 + 3, cast_bar_y - cast_bar_height_scaled * 0.5 + 3),
                cast_fill_width - 6,
                cast_bar_height_scaled - 6,
                cast_fill_color,
                4.0
            )
        end
        
        -- Cast-Text mit schwarzer Umrandung (wie Mana-Bar Stil mit Prozent)
        local cast_font_size = font_size * (player_cast_scale / ui_scale)
        local cast_percent = math.floor(cast_progress * 100)
        local cast_text = string.format("%s (%.0f%%)", cast_spell, cast_percent)
        if core.graphics and core.graphics.text_2d then
            local text_x = cast_bar_x
            local text_y = cast_bar_y - cast_font_size * 0.25
            local cast_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
            for _, offset in ipairs(cast_offsets) do
                pcall(core.graphics.text_2d, cast_text, vec2_new(text_x + offset[1], text_y + offset[2]), cast_font_size, outline_color, true)
            end
            pcall(core.graphics.text_2d, cast_text, vec2_new(text_x, text_y), cast_font_size, text_color, true)
        end
        end
    end
end

-- Target Health & Resource Overlay - Zeigt Health/Resource Bar für aktuelles Target
local function render_target_overlay()
    if not menu_elements.target_overlay or not menu_elements.target_overlay.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.target_overlay.get_state, menu_elements.target_overlay)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    -- Hole aktuelles Target
    local current_target = nil
    if local_player.get_target then
        local ok_target, target = pcall(local_player.get_target, local_player)
        if ok_target and target then
            current_target = target
        end
    end
    
    if not current_target then
        return
    end
    
    -- Prüfe ob Target tot ist
    local is_dead = false
    if current_target.is_dead then
        local ok_dead, dead = pcall(current_target.is_dead, current_target)
        if ok_dead and dead then
            is_dead = dead
        end
    end
    
    if is_dead then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- Target Bar Position laden (aus Slidern oder Default)
    local target_bar_x, target_bar_y = load_target_bar_position(screen_size)
    local ui_scale = get_element_scale(menu_elements.target_overlay_scale)
    local target_bar_width = 400 * ui_scale
    local target_bar_height = 30 * ui_scale
    
    -- Hole Target Name
    local target_name = "Target"
    if current_target.get_name then
        local ok_name, name = pcall(current_target.get_name, current_target)
        if ok_name and name and name ~= "" then
            target_name = name
        end
    end
    
    -- Hole Target Level
    local target_level = 0
    if current_target.get_level then
        local ok_lvl, lvl = pcall(current_target.get_level, current_target)
        if ok_lvl and lvl and type(lvl) == "number" then
            target_level = lvl
        end
    elseif current_target.level then
        local ok_lvl, lvl = pcall(current_target.level, current_target)
        if ok_lvl and lvl and type(lvl) == "number" then
            target_level = lvl
        end
    end
    
    -- Hole Target Klasse
    local target_class = 0
    if current_target.get_class then
        local ok_class, cls = pcall(current_target.get_class, current_target)
        if ok_class and cls and type(cls) == "number" then
            target_class = cls
        end
    end
    
    local current_hp = 0
    local max_hp = 1
    if current_target.get_health then
        local ok, hp = pcall(current_target.get_health, current_target)
        if ok and hp and type(hp) == "number" then
            current_hp = hp
        end
    end
    if current_target.get_max_health then
        local ok, max = pcall(current_target.get_max_health, current_target)
        if ok and max and type(max) == "number" then
            max_hp = max
        end
    end
    
    local hp_ratio = max_hp > 0 and (current_hp / max_hp) or 0
    
    -- Berechne Distanz zum Target
    local target_distance = nil
    if current_target.distance then
        local ok_dist, dist = pcall(current_target.distance, current_target)
        if ok_dist and dist and type(dist) == "number" then
            target_distance = dist
        end
    end
    if not target_distance and local_player.distance_to then
        local ok_dist, dist = pcall(local_player.distance_to, local_player, current_target)
        if ok_dist and dist and type(dist) == "number" then
            target_distance = dist
        end
    end
    if not target_distance and current_target.get_position and cached_player_pos then
        local ok_pos, target_pos = pcall(current_target.get_position, current_target)
        if ok_pos and target_pos and target_pos.x and target_pos.y then
            local dx = target_pos.x - cached_player_pos.x
            local dy = target_pos.y - cached_player_pos.y
            local dz = (target_pos.z or 0) - (cached_player_pos.z or 0)
            target_distance = math.sqrt(dx*dx + dy*dy + dz*dz)
        end
    end
    
    -- Manuelle Range-Prüfung (35 Yards)
    local max_range = 35.0
    local is_in_range = true
    if target_distance and type(target_distance) == "number" then
        is_in_range = (target_distance <= max_range)
    end
    
    -- Alpha-Wert basierend auf Range (30% wenn out of range, 100% wenn in range)
    local alpha_multiplier = is_in_range and 1.0 or 0.30
    
    -- HP-Bar Hintergrund (TabMenu-Stil) - Alpha basierend auf Range - Live Color
    local base_bg_color = color.new(18, 15, 25, 230)
    local base_border_color = color.new(100, 67, 150, 220)
    local bg_r, bg_g, bg_b, bg_a = get_color_rgba(base_bg_color)
    local border_r, border_g, border_b, border_a = get_color_rgba(base_border_color)
    local bg_alpha = math.floor((bg_a or 230) * alpha_multiplier)
    local border_alpha = math.floor((border_a or 220) * alpha_multiplier)
    local bg_color = color.new(bg_r or 18, bg_g or 15, bg_b or 25, bg_alpha)
    local border_color = color.new(border_r or 100, border_g or 67, border_b or 150, border_alpha)
    
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(target_bar_x - target_bar_width * 0.5, target_bar_y - target_bar_height * 0.5),
            target_bar_width,
            target_bar_height,
            bg_color,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(target_bar_x - target_bar_width * 0.5, target_bar_y - target_bar_height * 0.5),
                target_bar_width,
                target_bar_height,
                border_color,
                1.0,
                6.0
            )
        end
    end
    
    -- HP-Bar Füllung - Alpha basierend auf Range
    local fill_width = target_bar_width * hp_ratio
    local base_fill_color = color.new(100, 255, 150, 255)
    if hp_ratio < 0.3 then
        base_fill_color = color.new(255, 100, 120, 255)
    elseif hp_ratio < 0.6 then
        base_fill_color = color.new(255, 180, 80, 255)
    end
    local fill_r, fill_g, fill_b, fill_a = get_color_rgba(base_fill_color)
    local fill_alpha = math.floor((fill_a or 255) * alpha_multiplier)
    local fill_color = color.new(fill_r or 100, fill_g or 255, fill_b or 150, fill_alpha)
    
    if fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(target_bar_x - target_bar_width * 0.5 + 3, target_bar_y - target_bar_height * 0.5 + 3),
            fill_width - 6,
            target_bar_height - 6,
            fill_color,
            4.0
        )
    end
    
    -- Name über der Bar (mit Klasse in Klassenfarbe - nur bei Spielern)
    local class_name = nil
    local class_color = nil
    
    -- Prüfe ob Target ein Spieler ist (mehrere Methoden)
    local is_target_player = false
    if current_target.is_player then
        local ok, is_player = pcall(current_target.is_player, current_target)
        if ok and is_player then
            is_target_player = true
        end
    end
    if not is_target_player and current_target.get_unit_type then
        local ok, unit_type = pcall(current_target.get_unit_type, current_target)
        if ok and unit_type == 1 then
            is_target_player = true
        end
    end
    
    if is_target_player and target_class > 0 and pvp_module then
        if pvp_module.get_class_name then
            class_name = pvp_module.get_class_name(target_class)
        end
        if pvp_module.get_class_color then
            local r, g, b = pvp_module.get_class_color(target_class)
            if r and g and b then
                class_color = color.new(r, g, b, 255)
            end
        end
    end
    
    local name_text_alpha = math.floor(255 * alpha_multiplier)
    local name_outline_alpha = math.floor(200 * alpha_multiplier)
    local name_text_color = color.new(255, 255, 255, name_text_alpha)
    local name_outline_color = color.new(0, 0, 0, name_outline_alpha)
    local name_font_size = 18 * ui_scale
    local name_y = target_bar_y - target_bar_height * 0.5 - name_font_size - 5
    
    if core.graphics and core.graphics.text_2d then
        local name_offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        
        -- Hole Player Level für Level-Differenz Warnung (wird später verwendet)
        local player_level = 1
        if local_player.get_level then
            local ok_lvl, lvl = pcall(local_player.get_level, local_player)
            if ok_lvl and lvl and type(lvl) == "number" then
                player_level = lvl
            end
        elseif local_player.level then
            local ok_lvl, lvl = pcall(local_player.level, local_player)
            if ok_lvl and lvl and type(lvl) == "number" then
                player_level = lvl
            end
        end
        local level_diff = target_level - player_level
        local level_warning_color = name_text_color
        if level_diff >= 3 then
            level_warning_color = color.new(255, 0, 0, 255)  -- Rot (viel höher)
        elseif level_diff >= 1 then
            level_warning_color = color.new(255, 150, 0, 255)  -- Orange (höher)
        elseif level_diff <= -3 then
            level_warning_color = color.new(150, 150, 150, 255)  -- Grau (viel niedriger)
        end
        
        -- Baue den Basis-Text zusammen (Name + Level)
        local base_text = target_name
        if target_level > 0 then
            base_text = string.format("Level %d - %s", target_level, target_name)
        end
        
        -- Position links an der Healthbar (linksbündig)
        local base_text_x = target_bar_x - target_bar_width * 0.5
        
        -- Rendere Basis-Text (Name + Level) linksbündig
        -- Level in Warnfarbe wenn nötig
        if target_level > 0 and (level_diff >= 1 or level_diff <= -3) then
            -- Rendere Level separat in Warnfarbe
            local level_part = string.format("Level %d", target_level)
            local name_part = " - " .. target_name
            local level_text_x = base_text_x
            
            -- Rendere Level in Warnfarbe
            for _, offset in ipairs(name_offsets) do
                pcall(core.graphics.text_2d, level_part, vec2_new(level_text_x + offset[1], name_y + offset[2]), name_font_size, name_outline_color, false)
            end
            pcall(core.graphics.text_2d, level_part, vec2_new(level_text_x, name_y), name_font_size, level_warning_color, false)
            
            -- Rendere Name normal
            local name_text_x = level_text_x + #level_part * (name_font_size * 0.5)
            for _, offset in ipairs(name_offsets) do
                pcall(core.graphics.text_2d, name_part, vec2_new(name_text_x + offset[1], name_y + offset[2]), name_font_size, name_outline_color, false)
            end
            pcall(core.graphics.text_2d, name_part, vec2_new(name_text_x, name_y), name_font_size, name_text_color, false)
        else
            -- Normale Darstellung
            for _, offset in ipairs(name_offsets) do
                pcall(core.graphics.text_2d, base_text, vec2_new(base_text_x + offset[1], name_y + offset[2]), name_font_size, name_outline_color, false)
            end
            pcall(core.graphics.text_2d, base_text, vec2_new(base_text_x, name_y), name_font_size, name_text_color, false)
        end
        
        -- Berechne Position für Klassentext (rechts neben dem Namen)
        local base_text_width = #base_text * (name_font_size * 0.5)
        
        -- Rendere Klasse in Klassenfarbe (falls vorhanden) rechts neben dem Namen
        if class_name then
            local class_text = "(" .. class_name .. ")"
            local final_class_color = class_color
            if final_class_color then
                -- Alpha für Klassenfarbe anpassen
                local class_alpha = math.floor(safe_get_alpha(final_class_color, 255) * alpha_multiplier)
                local fcr, fcg, fcb = safe_get_rgb(final_class_color, 255, 255, 255)
                final_class_color = color.new(fcr, fcg, fcb, class_alpha)
            else
                final_class_color = name_text_color
            end
            local class_text_x = base_text_x + base_text_width + 5
            
            for _, offset in ipairs(name_offsets) do
                pcall(core.graphics.text_2d, class_text, vec2_new(class_text_x + offset[1], name_y + offset[2]), name_font_size, name_outline_color, false)
            end
            pcall(core.graphics.text_2d, class_text, vec2_new(class_text_x, name_y), name_font_size, final_class_color, false)
        end
    end
    
    -- HP-Text (TabMenu-Stil: heller Text, zentriert) - Alpha basierend auf Range - Live Color
    local hp_text = string.format("HP: %d / %d (%.0f%%)", math.floor(current_hp), math.floor(max_hp), hp_ratio * 100)
    local base_text_color = color.new(220, 200, 255, 255)
    local text_r, text_g, text_b, text_a = get_color_rgba(base_text_color)
    local hp_text_alpha = math.floor((text_a or 255) * alpha_multiplier)
    local hp_outline_alpha = math.floor(200 * alpha_multiplier)
    local text_color = color.new(text_r or 220, text_g or 200, text_b or 255, hp_text_alpha)
    local outline_color = color.new(0, 0, 0, hp_outline_alpha)  -- Leichte Umrandung für Lesbarkeit
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        local text_x = target_bar_x  -- Horizontal bereits zentriert
        local text_y = target_bar_y - font_size * 0.25  -- Vertikal zentriert
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, hp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        pcall(core.graphics.text_2d, hp_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
    
    -- Bestimme Power-Type basierend auf Klasse
    local target_class = 0
    if current_target.get_class then
        local ok_class, cls = pcall(current_target.get_class, current_target)
        if ok_class and cls and type(cls) == "number" then
            target_class = cls
        end
    end
    
    -- Power/Mana Bar (unter der HP Bar)
    local power_bar_y = target_bar_y + target_bar_height + 10
    local current_power = 0
    local max_power = 1
    local power_type = 0  -- Default: Mana
    
    -- Setze erwarteten Power-Type basierend auf Klasse
    local expected_power_type = 0  -- Default: Mana
    if target_class == 1 then
        expected_power_type = 1  -- Warrior: Rage
    elseif target_class == 4 then
        expected_power_type = 3  -- Rogue: Energy
    elseif target_class == 6 then
        expected_power_type = 6  -- Death Knight: Runic Power
    elseif target_class == 3 then
        expected_power_type = 2  -- Hunter: Focus
    elseif target_class == 10 then
        expected_power_type = 3  -- Monk: Energy
    elseif target_class == 12 then
        expected_power_type = 17  -- Demon Hunter: Fury
    end
    
    -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
    local best_power_type = expected_power_type
    local best_max_power = 0
    
    if current_target.get_max_power then
        local power_types_to_check = {0, 1, 2, 3, 6, 17}  -- Mana, Rage, Focus, Energy, Runic Power, Fury
        
        for _, pt in ipairs(power_types_to_check) do
            local ok_mp, mp = pcall(current_target.get_max_power, current_target, pt)
            if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                best_max_power = mp
                best_power_type = pt
            end
        end
        
        -- Spezielle Logik für Druiden
        if target_class == 11 then
            local mana_max = 0
            local rage_max = 0
            local energy_max = 0
            local ok_mm, mm = pcall(current_target.get_max_power, current_target, 0)
            if ok_mm and mm and type(mm) == "number" then mana_max = mm end
            local ok_rm, rm = pcall(current_target.get_max_power, current_target, 1)
            if ok_rm and rm and type(rm) == "number" then rage_max = rm end
            local ok_em, em = pcall(current_target.get_max_power, current_target, 3)
            if ok_em and em and type(em) == "number" then energy_max = em end
            
            if energy_max > mana_max and energy_max > rage_max then
                best_power_type = 3  -- Energy (Cat Form)
                best_max_power = energy_max
            elseif rage_max > mana_max and rage_max > energy_max then
                best_power_type = 1  -- Rage (Bear Form)
                best_max_power = rage_max
            elseif mana_max > 0 then
                best_power_type = 0  -- Mana (Caster/Heal Form)
                best_max_power = mana_max
            end
        end
    end
    
    power_type = best_power_type
    
    -- Hole Power-Werte basierend auf erkanntem Power-Type
    if current_target.get_power and current_target.get_max_power then
        local ok_p, power = pcall(current_target.get_power, current_target, power_type)
        local ok_mp, max = pcall(current_target.get_max_power, current_target, power_type)
        if ok_p and ok_mp and power and max and type(power) == "number" and type(max) == "number" and max > 0 then
            current_power = power
            max_power = max
        end
    end
    
    local power_ratio = max_power > 0 and (current_power / max_power) or 0
    
    -- Power-Bar Hintergrund (TabMenu-Stil) - schattiger wenn außerhalb - Live Color
    local target_power_bg_color = color.new(18, 15, 25, 230)
    local target_power_border_color = color.new(100, 67, 150, 220)
    local power_bg_r, power_bg_g, power_bg_b, power_bg_a = get_color_rgba(target_power_bg_color)
    local power_border_r, power_border_g, power_border_b, power_border_a = get_color_rgba(target_power_border_color)
    local power_bg_alpha = math.floor((power_bg_a or 230) * alpha_multiplier)
    local power_border_alpha = math.floor((power_border_a or 220) * alpha_multiplier)
    local power_bg_color_final = color.new(power_bg_r or 18, power_bg_g or 15, power_bg_b or 25, power_bg_alpha)
    local power_border_color_final = color.new(power_border_r or 100, power_border_g or 67, power_border_b or 150, power_border_alpha)
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(target_bar_x - target_bar_width * 0.5, power_bar_y - target_bar_height * 0.5),
            target_bar_width,
            target_bar_height,
            power_bg_color_final,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(target_bar_x - target_bar_width * 0.5, power_bar_y - target_bar_height * 0.5),
                target_bar_width,
                target_bar_height,
                power_border_color_final,
                1.0,
                6.0
            )
        end
    end
    
    -- Power-Bar Füllung (Farbe basierend auf Power-Typ) - Alpha basierend auf Range
    local base_power_fill_color = color.new(100, 150, 255, 255)  -- Standard: Blau (Mana)
    if power_type == 1 then
        base_power_fill_color = color.new(255, 50, 50, 255)  -- Rage: Rot
    elseif power_type == 2 then
        base_power_fill_color = color.new(255, 180, 80, 255)  -- Focus: Orange
    elseif power_type == 3 then
        base_power_fill_color = color.new(255, 255, 100, 255)  -- Energy: Gelb
    elseif power_type == 6 then
        base_power_fill_color = color.new(0, 200, 255, 255)  -- Runic Power: Cyan
    elseif power_type == 17 then
        base_power_fill_color = color.new(200, 100, 255, 255)  -- Fury (DH): Lila
    end
    local power_fill_r, power_fill_g, power_fill_b, power_fill_a = get_color_rgba(base_power_fill_color)
    local power_fill_alpha = math.floor((power_fill_a or 255) * alpha_multiplier)
    local power_fill_color = color.new(power_fill_r or 100, power_fill_g or 150, power_fill_b or 255, power_fill_alpha)
    
    local power_fill_width = target_bar_width * power_ratio
    if power_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        local fill_radius = 4.0
        pcall(core.graphics.rect_2d_filled,
            vec2_new(target_bar_x - target_bar_width * 0.5 + 3, power_bar_y - target_bar_height * 0.5 + 3),
            power_fill_width - 6,
            target_bar_height - 6,
            power_fill_color,
            fill_radius
        )
    end
    
    -- Power-Text mit schwarzer Umrandung
    local power_type_name = "Mana"
    if power_type == 1 then
        power_type_name = "Rage"
    elseif power_type == 2 then
        power_type_name = "Focus"
    elseif power_type == 3 then
        power_type_name = "Energy"
    elseif power_type == 6 then
        power_type_name = "Runic Power"
    elseif power_type == 17 then
        power_type_name = "Fury"
    end
    
    local power_text = string.format("%s: %d / %d (%.0f%%)", power_type_name, math.floor(current_power), math.floor(max_power), power_ratio * 100)
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        local text_x = target_bar_x
        local text_y = power_bar_y - font_size * 0.25
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, power_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        pcall(core.graphics.text_2d, power_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
    
    -- ============================================================================
    -- ZUSÄTZLICHE FEATURES FÜR TARGET OVERLAY
    -- ============================================================================
    
    -- 1. Target Cast Bar (unter der Power Bar) - verwendet gleiche Logik wie Enemy Cast Bar
    local cast_spell = nil
    local cast_progress = 0.0
    local is_channel = false
    
    -- Prüfe ob Target castet oder channelt (direkt wie in get_unit_cast_info)
    if current_target then
        local is_casting = current_target:is_casting_spell()
        local is_channeling = current_target:is_channelling_spell()
        
        if is_casting or is_channeling then
            is_channel = is_channeling
            
            -- Hole Spell-ID
            local spell_id = 0
            if is_casting then
                spell_id = current_target:get_active_spell_id()
            elseif is_channeling then
                spell_id = current_target:get_active_channel_spell_id()
            end
            
            -- Hole Cast-Progress über Zeit-Berechnung
            local start_time, end_time
            if is_casting then
                start_time = current_target:get_active_spell_cast_start_time()
                end_time = current_target:get_active_spell_cast_end_time()
            else
                start_time = current_target:get_active_channel_cast_start_time()
                end_time = current_target:get_active_channel_cast_end_time()
            end
            
            if start_time and end_time and start_time > 0 and end_time > start_time then
                local current_time = core.game_time()
                local total_time = end_time - start_time
                local elapsed = current_time - start_time
                if elapsed >= 0 and total_time > 0 then
                    cast_progress = math.max(0.0, math.min(1.0, elapsed / total_time))
                end
            end
            
            -- Hole Spell-Name
            if spell_id and spell_id > 0 then
                if core.spell_book and core.spell_book.get_spell_name then
                    cast_spell = core.spell_book.get_spell_name(spell_id)
                end
                if not cast_spell or cast_spell == "" then
                    cast_spell = is_channel and "Channeling" or "Casting"
                end
            else
                cast_spell = is_channel and "Channeling" or "Casting"
            end
        end
    end
    
    if cast_spell then
        local cast_bar_y = power_bar_y + target_bar_height + 10
        local base_cast_fill_color = is_channel and color.new(180, 100, 255, 255) or color.new(255, 200, 50, 255)
        local cast_fill_r, cast_fill_g, cast_fill_b, cast_fill_a = get_color_rgba(base_cast_fill_color)
        local cast_fill_alpha = math.floor((cast_fill_a or 255) * alpha_multiplier)
        local cast_fill_color = color.new(cast_fill_r or 255, cast_fill_g or 200, cast_fill_b or 50, cast_fill_alpha)
        local cast_fill_width = target_bar_width * math.max(0.01, cast_progress)
        
        -- Cast-Bar Hintergrund - Live Color
        local target_cast_bg_color = color.new(18, 15, 25, 230)
        local target_cast_border_color = color.new(100, 67, 150, 220)
        local cast_bg_r, cast_bg_g, cast_bg_b, cast_bg_a = get_color_rgba(target_cast_bg_color)
        local cast_border_r, cast_border_g, cast_border_b, cast_border_a = get_color_rgba(target_cast_border_color)
        local cast_bg_alpha = math.floor((cast_bg_a or 230) * alpha_multiplier)
        local cast_border_alpha = math.floor((cast_border_a or 220) * alpha_multiplier)
        local cast_bg_color_final = color.new(cast_bg_r or 18, cast_bg_g or 15, cast_bg_b or 25, cast_bg_alpha)
        local cast_border_color_final = color.new(cast_border_r or 100, cast_border_g or 67, cast_border_b or 150, cast_border_alpha)
        if core.graphics and core.graphics.rect_2d_filled then
            pcall(core.graphics.rect_2d_filled,
                vec2_new(target_bar_x - target_bar_width * 0.5, cast_bar_y - target_bar_height * 0.5),
                target_bar_width,
                target_bar_height,
                cast_bg_color_final,
                6.0
            )
            if core.graphics and core.graphics.rect_2d then
                pcall(core.graphics.rect_2d,
                    vec2_new(target_bar_x - target_bar_width * 0.5, cast_bar_y - target_bar_height * 0.5),
                    target_bar_width,
                    target_bar_height,
                    cast_border_color_final,
                    1.0,
                    6.0
                )
            end
        end
        
        -- Cast-Bar Füllung
        if cast_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
            pcall(core.graphics.rect_2d_filled,
                vec2_new(target_bar_x - target_bar_width * 0.5 + 3, cast_bar_y - target_bar_height * 0.5 + 3),
                cast_fill_width - 6,
                target_bar_height - 6,
                cast_fill_color,
                4.0
            )
        end
        
        -- Cast-Text
        local cast_percent = math.floor(cast_progress * 100)
        local cast_text = string.format("%s (%.0f%%)", cast_spell, cast_percent)
        if core.graphics and core.graphics.text_2d then
            local cast_text_x = target_bar_x
            local cast_text_y = cast_bar_y - font_size * 0.25
            local cast_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
            for _, offset in ipairs(cast_offsets) do
                pcall(core.graphics.text_2d, cast_text, vec2_new(cast_text_x + offset[1], cast_text_y + offset[2]), font_size, outline_color, true)
            end
            pcall(core.graphics.text_2d, cast_text, vec2_new(cast_text_x, cast_text_y), font_size, text_color, true)
        end
    end
    
    -- 2. Distanz zum Target
    local target_distance = nil
    if local_player.distance_to then
        local ok_dist, dist = pcall(local_player.distance_to, local_player, current_target)
        if ok_dist and dist and type(dist) == "number" then
            target_distance = dist
        end
    end
    if not target_distance and current_target.distance then
        local ok_dist, dist = pcall(current_target.distance, current_target)
        if ok_dist and dist and type(dist) == "number" then
            target_distance = dist
        end
    end
    if not target_distance and current_target.get_position and local_player.get_position then
        local ok_pos1, target_pos = pcall(current_target.get_position, current_target)
        local ok_pos2, player_pos = pcall(local_player.get_position, local_player)
        if ok_pos1 and ok_pos2 and target_pos and player_pos then
            local dx = target_pos.x - player_pos.x
            local dy = target_pos.y - player_pos.y
            local dz = (target_pos.z or 0) - (player_pos.z or 0)
            target_distance = math.sqrt(dx*dx + dy*dy + dz*dz)
        end
    end
    
    -- 3. Classification Badge (direkt implementiert wie get_unit_classification)
    local classification = "normal"
    if current_target then
        if current_target.get_classification then
            local ok, class = pcall(current_target.get_classification, current_target)
            if ok and class then
                classification = class
            end
        end
        -- Fallback: Prüfe ob Elite über andere Methoden
        if classification == "normal" and current_target.is_elite then
            local ok, elite = pcall(current_target.is_elite, current_target)
            if ok and elite then
                classification = "elite"
            end
        end
    end
    
    local classification_text = nil
    local classification_alpha = math.floor(255 * alpha_multiplier)
    local classification_color = name_text_color
    if classification == "elite" or classification == "rareelite" then
        classification_text = "ELITE"
        classification_color = color.new(255, 215, 0, classification_alpha)  -- Gold
    elseif classification == "rare" then
        classification_text = "RARE"
        classification_color = color.new(255, 128, 0, classification_alpha)  -- Orange
    elseif classification == "boss" then
        classification_text = "BOSS"
        classification_color = color.new(255, 0, 0, classification_alpha)  -- Rot
    end
    
    -- 4. Combat Status
    local is_in_combat = false
    local combat_target_name = nil
    if current_target.is_in_combat then
        local ok_combat, in_combat = pcall(current_target.is_in_combat, current_target)
        if ok_combat and in_combat then
            is_in_combat = true
        end
    end
    if is_in_combat and current_target.get_target then
        local ok_target, target_of_target = pcall(current_target.get_target, current_target)
        if ok_target and target_of_target then
            if (__object_safety.same(target_of_target,local_player)) then
                combat_target_name = "YOU"
            elseif target_of_target.get_name then
                local ok_name, name = pcall(target_of_target.get_name, target_of_target)
                if ok_name and name and name ~= "" then
                    combat_target_name = name
                end
            end
        end
    end
    
    -- 5. Targeting Indicator (wenn Target dich anvisiert)
    local is_targeting_player = false
    if current_target.get_target then
        local ok_target, target_of_target = pcall(current_target.get_target, current_target)
        if ok_target and target_of_target then
            if (__object_safety.same(target_of_target,local_player)) then
                is_targeting_player = true
            elseif target_of_target.get_guid and local_player.get_guid then
                local ok_guid1, guid1 = pcall(target_of_target.get_guid, target_of_target)
                local ok_guid2, guid2 = pcall(local_player.get_guid, local_player)
                if ok_guid1 and ok_guid2 and guid1 == guid2 then
                    is_targeting_player = true
                end
            end
        end
    end
    
    
    -- 7. Range Indicator
    local is_in_range = false
    local range_text = nil
    if target_distance then
        -- Prüfe Spell-Range (Standard: 40 Yards für die meisten Zauber)
        local spell_id = nil
        if local_player.get_active_spell_id then
            local ok_spell, sid = pcall(local_player.get_active_spell_id, local_player)
            if ok_spell and sid and sid > 0 then
                spell_id = sid
            end
        end
        local max_range = 35.0  -- Default Range
        if spell_id and current_target.is_spell_in_range then
            local ok_range, in_range = pcall(current_target.is_spell_in_range, current_target, spell_id)
            if ok_range and in_range ~= nil then
                is_in_range = in_range
            end
        end
        -- Fallback: Distanz-basierte Prüfung
        if is_in_range == false and target_distance <= max_range then
            is_in_range = true
        end
        range_text = is_in_range and "IN RANGE" or "OUT OF RANGE"
    end
    
    -- Rendere zusätzliche Informationen über dem Namen
    local info_y = name_y - name_font_size - 5
    local info_font_size = 14 * ui_scale
    local info_x = target_bar_x - target_bar_width * 0.5  -- Linksbündig
    
    if core.graphics and core.graphics.text_2d then
        local info_offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        local info_parts = {}
        
        -- Distanz
        if target_distance then
            local dist_color = is_in_range and color.new(0, 255, 0, 255) or color.new(255, 100, 100, 255)
            table.insert(info_parts, {text = string.format("%.1f yd", target_distance), color = dist_color})
        end
        
        -- Classification
        if classification_text then
            table.insert(info_parts, {text = classification_text, color = classification_color})
        end
        
        -- Combat Status
        if is_in_combat then
            local combat_text = "IN COMBAT"
            if combat_target_name then
                combat_text = combat_text .. ": " .. combat_target_name
            end
            table.insert(info_parts, {text = combat_text, color = color.new(255, 100, 100, 255)})
        end
        
        -- Targeting Indicator
        if is_targeting_player then
            table.insert(info_parts, {text = "TARGETING YOU!", color = color.new(255, 0, 0, 255)})
        end
        
        -- Range Indicator
        if range_text then
            local range_color = is_in_range and color.new(0, 255, 0, 255) or color.new(255, 150, 0, 255)
            table.insert(info_parts, {text = range_text, color = range_color})
        end
        
        -- Rendere alle Info-Teile
        local current_x = info_x
        for i, part in ipairs(info_parts) do
            if i > 1 then
                current_x = current_x + 10  -- Abstand zwischen Teilen
            end
            for _, offset in ipairs(info_offsets) do
                pcall(core.graphics.text_2d, part.text, vec2_new(current_x + offset[1], info_y + offset[2]), info_font_size, name_outline_color, false)
            end
            pcall(core.graphics.text_2d, part.text, vec2_new(current_x, info_y), info_font_size, part.color, false)
            -- Berechne nächste Position
            current_x = current_x + #part.text * (info_font_size * 0.5)
        end
    end
    
end

-- Pet Health & Resource Overlay - Zeigt Health/Resource Bar für Spieler-Pet
local function render_pet_health_resource_overlay()
    if not menu_elements.pet_overlay or not menu_elements.pet_overlay.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.pet_overlay.get_state, menu_elements.pet_overlay)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    -- Finde das Pet des Spielers - verwende mehrere Methoden
    local player_pet = nil
    
    -- Methode 1: Direkte API (falls verfügbar)
    if local_player.get_pet then
        local ok_pet, pet = pcall(local_player.get_pet, local_player)
        if ok_pet and pet then
            player_pet = pet
        end
    end
    
    -- Methode 2: Iteriere über alle Objekte (genau wie im ESP-Code)
    if not player_pet then
        local objects = core.object_manager.get_all_objects()
        if objects then
            local player_guid = nil
            if local_player.get_guid then
                local ok, guid = pcall(local_player.get_guid, local_player)
                if ok and guid then
                    player_guid = guid
                end
            end
            
            local player_pos = cached_player_pos
            local closest_pet = nil
            local closest_distance = 999999
            
            for _, obj in __object_safety.live_ipairs(objects) do
                if obj and obj.is_valid then
                    local ok_valid, is_valid = pcall(obj.is_valid, obj)
                    if ok_valid and is_valid then
                        if is_player_pet(obj) then
                            -- Prüfe Owner
                            local is_my_pet = false
                            if obj.get_pet_owner then
                                local ok, owner = pcall(obj.get_pet_owner, obj)
                                if ok and owner then
                                    if (__object_safety.same(owner,local_player)) then
                                        is_my_pet = true
                                    elseif player_guid and owner.get_guid then
                                        local ok_guid, guid = pcall(owner.get_guid, owner)
                                        if ok_guid and guid == player_guid then
                                            is_my_pet = true
                                        end
                                    end
                                end
                            end
                            
                            -- Prüfe Summoner
                            if not is_my_pet and obj.get_summoner then
                                local ok, summoner = pcall(obj.get_summoner, obj)
                                if ok and summoner then
                                    if (__object_safety.same(summoner,local_player)) then
                                        is_my_pet = true
                                    elseif player_guid and summoner.get_guid then
                                        local ok_guid, guid = pcall(summoner.get_guid, summoner)
                                        if ok_guid and guid == player_guid then
                                            is_my_pet = true
                                        end
                                    end
                                end
                            end
                            
                            if is_my_pet then
                                player_pet = obj
                                break  -- Pet gefunden, Schleife beenden
                            elseif player_pos then
                                -- Fallback: Nächstes Pet
                                local obj_pos = nil
                                if obj.get_position then
                                    local ok_pos, pos = pcall(obj.get_position, obj)
                                    if ok_pos and pos and pos.x and pos.y then
                                        obj_pos = pos
                                    end
                                end
                                if obj_pos then
                                    local dx = obj_pos.x - player_pos.x
                                    local dy = obj_pos.y - player_pos.y
                                    local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                                    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
                                    if distance < 50 and distance < closest_distance then
                                        closest_pet = obj
                                        closest_distance = distance
                                    end
                                end
                            end
                        end
                    end
                end
            end
            
            -- Wenn kein Pet mit Owner gefunden wurde, aber ein nahes Pet existiert
            if not player_pet and closest_pet then
                player_pet = closest_pet
            end
        end
    end
    
    if not player_pet then
        return
    end
    
    -- Prüfe ob Pet tot ist
    local is_dead = false
    if player_pet.is_dead then
        local ok_dead, dead = pcall(player_pet.is_dead, player_pet)
        if ok_dead and dead then
            is_dead = dead
        end
    end
    
    if is_dead then
        return
    end
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    -- Pet Bar Position laden (aus Slidern oder Default)
    local pet_bar_x, pet_bar_y = load_pet_bar_position(screen_size)
    local ui_scale = get_element_scale(menu_elements.pet_overlay_scale)
    local pet_bar_width = 400 * ui_scale
    local pet_bar_height = 30 * ui_scale
    
    -- Hole Pet Name
    local pet_name = "Pet"
    if player_pet.get_name then
        local ok_name, name = pcall(player_pet.get_name, player_pet)
        if ok_name and name and name ~= "" then
            pet_name = name
        end
    end
    
    -- Hole Pet Level
    local pet_level = 0
    if player_pet.get_level then
        local ok_lvl, lvl = pcall(player_pet.get_level, player_pet)
        if ok_lvl and lvl and type(lvl) == "number" then
            pet_level = lvl
        end
    elseif player_pet.level then
        local ok_lvl, lvl = pcall(player_pet.level, player_pet)
        if ok_lvl and lvl and type(lvl) == "number" then
            pet_level = lvl
        end
    end
    
    local current_hp = 0
    local max_hp = 1
    if player_pet.get_health then
        local ok, hp = pcall(player_pet.get_health, player_pet)
        if ok and hp and type(hp) == "number" then
            current_hp = hp
        end
    end
    if player_pet.get_max_health then
        local ok, max = pcall(player_pet.get_max_health, player_pet)
        if ok and max and type(max) == "number" then
            max_hp = max
        end
    end
    
    local hp_ratio = max_hp > 0 and (current_hp / max_hp) or 0
    
    -- HP-Bar Hintergrund (TabMenu-Stil) - Live Color
    local bg_color = color.new(18, 15, 25, 230)
    local border_color = color.new(100, 67, 150, 220)
    
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(pet_bar_x - pet_bar_width * 0.5, pet_bar_y - pet_bar_height * 0.5),
            pet_bar_width,
            pet_bar_height,
            bg_color,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(pet_bar_x - pet_bar_width * 0.5, pet_bar_y - pet_bar_height * 0.5),
                pet_bar_width,
                pet_bar_height,
                border_color,
                1.0,
                6.0
            )
        end
    end
    
    -- HP-Bar Füllung
    local fill_width = pet_bar_width * hp_ratio
    local fill_color = color.new(100, 255, 150, 255)
    if hp_ratio < 0.3 then
        fill_color = color.new(255, 100, 120, 255)
        local blink = math.floor((core.time() * 2) % 2)
        if blink == 0 then
            fill_color = color.new(255, 150, 150, 255)
        end
    elseif hp_ratio < 0.6 then
        fill_color = color.new(255, 180, 80, 255)
    end
    
    if fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(pet_bar_x - pet_bar_width * 0.5 + 3, pet_bar_y - pet_bar_height * 0.5 + 3),
            fill_width - 6,
            pet_bar_height - 6,
            fill_color,
            4.0
        )
    end
    
    -- Name über der Bar
    local name_text_color = color.new(255, 255, 255, 255)
    local name_outline_color = color.new(0, 0, 0, 200)
    local name_font_size = 18 * ui_scale
    local name_y = pet_bar_y - pet_bar_height * 0.5 - name_font_size - 5
    
    if core.graphics and core.graphics.text_2d then
        local name_offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        
        local base_text = pet_name
        if pet_level > 0 then
            base_text = string.format("Level %d - %s", pet_level, pet_name)
        end
        
        local base_text_x = pet_bar_x - pet_bar_width * 0.5
        
        for _, offset in ipairs(name_offsets) do
            pcall(core.graphics.text_2d, base_text, vec2_new(base_text_x + offset[1], name_y + offset[2]), name_font_size, name_outline_color, false)
        end
        pcall(core.graphics.text_2d, base_text, vec2_new(base_text_x, name_y), name_font_size, name_text_color, false)
    end
    
    -- HP-Text (TabMenu-Stil: heller Text, zentriert)
    local hp_text = string.format("HP: %d / %d (%.0f%%)", math.floor(current_hp), math.floor(max_hp), hp_ratio * 100)
    local text_color = color.new(220, 200, 255, 255)  -- TabMenu-Text-Farbe
    local outline_color = color.new(0, 0, 0, 200)  -- Leichte Umrandung für Lesbarkeit
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        local text_x = pet_bar_x  -- Horizontal bereits zentriert
        local text_y = pet_bar_y - font_size * 0.25  -- Vertikal zentriert
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, hp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        pcall(core.graphics.text_2d, hp_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
    
    -- Power/Mana Bar (unter der HP Bar)
    local power_bar_y = pet_bar_y + pet_bar_height + 10
    local current_power = 0
    local max_power = 1
    local power_type = 0  -- Default: Mana
    
    -- Pets verwenden normalerweise Mana oder Focus
    -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
    local best_power_type = 0
    local best_max_power = 0
    
    if player_pet.get_max_power then
        local power_types_to_check = {0, 2}  -- Mana, Focus (typisch für Pets)
        
        for _, pt in ipairs(power_types_to_check) do
            local ok_mp, mp = pcall(player_pet.get_max_power, player_pet, pt)
            if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                best_max_power = mp
                best_power_type = pt
            end
        end
    end
    
    power_type = best_power_type
    
    -- Hole Power-Werte basierend auf erkanntem Power-Type
    if player_pet.get_power and player_pet.get_max_power then
        local ok_p, power = pcall(player_pet.get_power, player_pet, power_type)
        local ok_mp, max = pcall(player_pet.get_max_power, player_pet, power_type)
        if ok_p and ok_mp and power and max and type(power) == "number" and type(max) == "number" and max > 0 then
            current_power = power
            max_power = max
        end
    end
    
    local power_ratio = max_power > 0 and (current_power / max_power) or 0
    
    -- Power-Bar Hintergrund (TabMenu-Stil) - Live Color
    local pet_power_bg_color = color.new(18, 15, 25, 230)
    local pet_power_border_color = color.new(100, 67, 150, 220)
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(pet_bar_x - pet_bar_width * 0.5, power_bar_y - pet_bar_height * 0.5),
            pet_bar_width,
            pet_bar_height,
            pet_power_bg_color,
            6.0
        )
        if core.graphics and core.graphics.rect_2d then
            pcall(core.graphics.rect_2d,
                vec2_new(pet_bar_x - pet_bar_width * 0.5, power_bar_y - pet_bar_height * 0.5),
                pet_bar_width,
                pet_bar_height,
                pet_power_border_color,
                1.0,
                6.0
            )
        end
    end
    
    -- Power-Bar Füllung (Farbe basierend auf Power-Typ)
    local power_fill_color = color.new(100, 150, 255, 255)  -- Standard: Blau (Mana)
    if power_type == 2 then
        power_fill_color = color.new(255, 180, 80, 255)  -- Focus: Orange
    end
    
    local power_fill_width = pet_bar_width * power_ratio
    if power_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(pet_bar_x - pet_bar_width * 0.5 + 3, power_bar_y - pet_bar_height * 0.5 + 3),
            power_fill_width - 6,
            pet_bar_height - 6,
            power_fill_color,
            4.0
        )
    end
    
    -- Power-Text mit schwarzer Umrandung
    local power_type_name = "Mana"
    if power_type == 2 then
        power_type_name = "Focus"
    end
    
    local power_text = string.format("%s: %d / %d (%.0f%%)", power_type_name, math.floor(current_power), math.floor(max_power), power_ratio * 100)
    local font_size = 16 * ui_scale
    if core.graphics and core.graphics.text_2d then
        local text_x = pet_bar_x
        local text_y = power_bar_y - font_size * 0.25
        local offsets = {
            {-1, -1}, {0, -1}, {1, -1},
            {-1, 0},           {1, 0},
            {-1, 1},  {0, 1},  {1, 1}
        }
        for _, offset in ipairs(offsets) do
            pcall(core.graphics.text_2d, power_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        pcall(core.graphics.text_2d, power_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
end

-- XP Bar Overlay - Zeigt Experience-Bar oben am Bildschirm (Mana-Bar-Stil)
local function render_xp_bar_overlay()
    if not menu_elements.xp_bar_overlay or not menu_elements.xp_bar_overlay.get_state then
        return
    end
    
    local enabled = false
    local ok, val = pcall(menu_elements.xp_bar_overlay.get_state, menu_elements.xp_bar_overlay)
    if ok and val ~= nil then
        enabled = val
    end
    
    if not enabled then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    -- Hole XP-Daten
    local current_xp = 0
    local max_xp = 1
    local player_level = 1
    local rested_xp = 0
    
    -- UnitXP und UnitXPMax über game API
    if local_player.get_xp then
        local ok_xp, xp = pcall(local_player.get_xp, local_player)
        if ok_xp and xp and type(xp) == "number" then
            current_xp = xp
        end
    end
    
    if local_player.get_max_xp then
        local ok_max, max = pcall(local_player.get_max_xp, local_player)
        if ok_max and max and type(max) == "number" and max > 0 then
            max_xp = max
        end
    end
    
    if local_player.get_level then
        local ok_lvl, lvl = pcall(local_player.get_level, local_player)
        if ok_lvl and lvl and type(lvl) == "number" then
            player_level = lvl
        end
    end
    
    -- Rested XP (verschiedene Methoden versuchen)
    -- Methode 1: get_rested_xp (direkt)
    if local_player.get_rested_xp then
        local ok_rest, rest = pcall(local_player.get_rested_xp, local_player)
        if ok_rest and rest and type(rest) == "number" and rest > 0 then
            rested_xp = rest
        end
    end
    
    -- Methode 2: get_rested_experience (alternative API)
    if rested_xp == 0 and local_player.get_rested_experience then
        local ok_rest_exp, rest_exp = pcall(local_player.get_rested_experience, local_player)
        if ok_rest_exp and rest_exp and type(rest_exp) == "number" and rest_exp > 0 then
            rested_xp = rest_exp
        end
    end
    
    -- Methode 3: get_rest_state + Berechnung (falls nur State verfügbar)
    if rested_xp == 0 and local_player.get_rest_state then
        local ok_rest_state, rest_state = pcall(local_player.get_rest_state, local_player)
        if ok_rest_state and rest_state and type(rest_state) == "number" and rest_state > 0 then
            -- rest_state: 0 = normal, 1 = rested, 2 = well rested
            -- Berechne rested XP basierend auf max_xp und rest_state
            if rest_state >= 1 then
                -- In WoW Classic: rested XP kann bis zu 1.5x max_xp sein (well rested)
                -- Geschätzte rested XP basierend auf rest_state
                local rested_multiplier = rest_state == 2 and 1.5 or 1.0
                rested_xp = max_xp * rested_multiplier
            end
        end
    end
    
    -- Debug: Log wenn keine rested XP gefunden wird
    -- (kann später entfernt werden)
    if rested_xp == 0 and local_player.get_rested_xp == nil and local_player.get_rested_experience == nil and local_player.get_rest_state == nil then
        -- Keine Methode verfügbar - könnte bedeuten, dass die API anders heißt
    end
    
    -- Max Level Check (Classic = 60, TBC = 70, WotLK = 80)
    if player_level >= 60 and max_xp <= 1 then
        -- Max Level erreicht - zeige nichts oder "Max Level"
        return
    end
    
    local xp_ratio = max_xp > 0 and (current_xp / max_xp) or 0
    local rested_ratio = max_xp > 0 and (rested_xp / max_xp) or 0
    
    -- Bildschirmgröße
    local screen_width = 1920
    local screen_height = 1080
    local screen_size = nil
    if core.graphics.get_screen_size then
        local ok_size, size = pcall(core.graphics.get_screen_size)
        if ok_size and size and size.x and size.y then
            screen_width = size.x
            screen_height = size.y
            screen_size = { x = size.x, y = size.y }
        end
    end
    
    if not screen_size then
        screen_size = { x = screen_width, y = screen_height }
    end
    
    -- XP-Bar Position laden (aus Slidern oder Default)
    local xp_bar_x, xp_bar_y = load_xp_bar_position(screen_size)
    
    local ui_scale = get_element_scale(menu_elements.xp_bar_overlay_scale)
    local xp_bar_width = screen_width * 0.42 * ui_scale  -- 42% der Bildschirmbreite (30% schmaler als 60%)
    local xp_bar_height = 28 * ui_scale
    
    -- Farben (Mana-Bar-Stil)
    local bg_color = color.new(30, 30, 35, 220)
    local border_color = color.new(80, 80, 90, 255)
    local xp_fill_color = color.new(150, 80, 255, 255)  -- Lila für XP
    local rested_fill_color = color.new(80, 150, 255, 150)  -- Blau für Rested XP
    local text_color = color.new(255, 255, 255, 255)
    local outline_color = color.new(0, 0, 0, 255)
    
    -- Hintergrund mit Rundungen (Mana-Bar-Stil)
    if core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(xp_bar_x - xp_bar_width * 0.5, xp_bar_y - xp_bar_height * 0.5),
            xp_bar_width,
            xp_bar_height,
            bg_color,
            6.0
        )
    end
    
    -- Border (Mana-Bar-Stil)
    if core.graphics and core.graphics.rect_2d then
        pcall(core.graphics.rect_2d,
            vec2_new(xp_bar_x - xp_bar_width * 0.5, xp_bar_y - xp_bar_height * 0.5),
            xp_bar_width,
            xp_bar_height,
            border_color,
            1.0,
            6.0
        )
    end
    
    -- Rested XP Füllung (zuerst, da hinter der normalen XP)
    if rested_xp > 0 and rested_ratio > 0 then
        local rested_start = xp_ratio
        local rested_end = math.min(1.0, xp_ratio + rested_ratio)
        local rested_width = (rested_end - rested_start) * xp_bar_width
        local rested_start_x = xp_bar_x - xp_bar_width * 0.5 + 3 + (xp_ratio * (xp_bar_width - 6))
        
        if rested_width > 0 and core.graphics and core.graphics.rect_2d_filled then
            pcall(core.graphics.rect_2d_filled,
                vec2_new(rested_start_x, xp_bar_y - xp_bar_height * 0.5 + 3),
                rested_width,
                xp_bar_height - 6,
                rested_fill_color,
                4.0
            )
        end
    end
    
    -- XP Füllung (Mana-Bar-Stil)
    local xp_fill_width = (xp_bar_width - 6) * xp_ratio
    if xp_fill_width > 0 and core.graphics and core.graphics.rect_2d_filled then
        pcall(core.graphics.rect_2d_filled,
            vec2_new(xp_bar_x - xp_bar_width * 0.5 + 3, xp_bar_y - xp_bar_height * 0.5 + 3),
            xp_fill_width,
            xp_bar_height - 6,
            xp_fill_color,
            4.0
        )
    end
    
    -- XP-Text mit Level und Prozent (Mana-Bar-Stil)
    local xp_text = string.format("Level %d - XP: %d / %d (%.1f%%)", player_level, math.floor(current_xp), math.floor(max_xp), xp_ratio * 100)
    if rested_xp > 0 then
        xp_text = xp_text .. string.format(" [Rested: %d]", math.floor(rested_xp))
    end
    
    local font_size = 14 * ui_scale
    if core.graphics and core.graphics.text_2d then
        local text_x = xp_bar_x
        local text_y = xp_bar_y - font_size * 0.25
        local xp_offsets = { {-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1} }
        for _, offset in ipairs(xp_offsets) do
            pcall(core.graphics.text_2d, xp_text, vec2_new(text_x + offset[1], text_y + offset[2]), font_size, outline_color, true)
        end
        pcall(core.graphics.text_2d, xp_text, vec2_new(text_x, text_y), font_size, text_color, true)
    end
end

-- Level Difference Warning - Aktualisiert die Warndaten für das Popup
local function render_level_difference_warning()
    if not menu_elements.level_difference_warning or not menu_elements.level_difference_warning.get_state then
        level_warning_data.visible = false
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.level_difference_warning.get_state, menu_elements.level_difference_warning)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        level_warning_data.visible = false
        return
    end
    
    if not core or not core.object_manager then
        level_warning_data.visible = false
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        level_warning_data.visible = false
        return
    end
    
    local player_level = nil
    if local_player.level then
        local ok_lvl, lvl = pcall(local_player.level, local_player)
        if ok_lvl and lvl then
            player_level = lvl
        end
    end
    
    if not player_level then
        level_warning_data.visible = false
        return
    end
    
    local player_pos = nil
    local ok_pos, pos = pcall(local_player.get_position, local_player)
    if ok_pos and pos and pos.x and pos.y then
        player_pos = pos
    end
    if not player_pos then
        level_warning_data.visible = false
        return
    end
    
    -- Spieler-Rotation für Pfeilrichtung
    local player_rotation = 0
    if local_player.get_rotation then
        local ok_rot, rot = pcall(local_player.get_rotation, local_player)
        if ok_rot and rot then
            player_rotation = rot
        end
    end
    
    local objects = core.object_manager.get_all_objects()
    if not objects then
        level_warning_data.visible = false
        return
    end
    
    -- Finde den gefährlichsten Gegner (höchste Level-Differenz > 2)
    local dangerous_enemy = nil
    local dangerous_enemy_pos = nil
    local dangerous_enemy_name = ""
    local dangerous_enemy_level = 0
    local max_level_diff = 0
    local dangerous_distance = 0
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue
            end
            
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                if ok_enemy and enemy then
                    is_enemy = enemy
                end
            end
            -- Spieler-Pets nicht als Feinde anzeigen
            if is_enemy and is_player_pet(obj) then
                is_enemy = false
            end
            
            if is_enemy then
                -- Nur lebende Gegner berücksichtigen
                local is_dead = false
                if obj.is_dead then
                    local ok_dead, dead = pcall(obj.is_dead, obj)
                    if ok_dead and dead then
                        is_dead = dead
                    end
                end
                
                if not is_dead then
                    local mob_level = nil
                    if obj.level then
                        local ok_lvl, lvl = pcall(obj.level, obj)
                        if ok_lvl and lvl then
                            mob_level = lvl
                        end
                    end
                    
                    if mob_level then
                        local level_diff = mob_level - player_level
                        
                        -- Nur Gegner mit > +2 Level berücksichtigen
                        if level_diff > 2 and level_diff > max_level_diff then
                        local obj_pos = nil
                        if obj.get_position then
                            local ok_p, p = pcall(obj.get_position, obj)
                            if ok_p and p and p.x and p.y then
                                obj_pos = p
                            end
                        end
                        
                        if obj_pos then
                            -- Distanz berechnen
                            local dx = obj_pos.x - player_pos.x
                            local dy = obj_pos.y - player_pos.y
                            local dz = (obj_pos.z or 0) - (player_pos.z or 0)
                            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                            
                            -- Name holen
                            local name = "Unbekannt"
                            if obj.get_name then
                                local ok_n, n = pcall(obj.get_name, obj)
                                if ok_n and n then
                                    name = n
                                end
                            end
                            
                            max_level_diff = level_diff
                            dangerous_enemy = obj
                            dangerous_enemy_pos = obj_pos
                            dangerous_enemy_name = name
                            dangerous_enemy_level = mob_level
                            dangerous_distance = dist
                        end
                    end
                end
                end  -- end if not is_dead
            end
            
            ::continue::
        end
    end
    
    -- Warndaten aktualisieren
    if dangerous_enemy and max_level_diff > 2 then
        level_warning_data.visible = true
        level_warning_data.enemy_name = dangerous_enemy_name
        level_warning_data.enemy_level = dangerous_enemy_level
        level_warning_data.level_diff = max_level_diff
        level_warning_data.distance = dangerous_distance
        level_warning_data.is_critical = (max_level_diff > 3)
        
        -- Winkel vom Spieler zum Gegner berechnen (relativ zur Spieler-Blickrichtung)
        local dx = dangerous_enemy_pos.x - player_pos.x
        local dy = dangerous_enemy_pos.y - player_pos.y
        local angle_to_enemy = math.atan2(dy, dx)
        level_warning_data.direction_angle = angle_to_enemy - player_rotation
    else
        level_warning_data.visible = false
    end
end

-- Behind You Warning - Prüft ob Feinde hinter dem Spieler sind
local function check_enemies_behind()
    if not menu_elements.behind_warning or not menu_elements.behind_warning.get_state then
        behind_warning_data.visible = false
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.behind_warning.get_state, menu_elements.behind_warning)
    if ok and val then
        enabled = val
    end
    if not enabled then
        behind_warning_data.visible = false
        return
    end
    
    if not core or not core.object_manager then
        behind_warning_data.visible = false
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        behind_warning_data.visible = false
        return
    end
    
    local player_pos = nil
    if local_player.get_position then
        local ok_pos, pos = pcall(local_player.get_position, local_player)
        if ok_pos and pos then
            player_pos = pos
        end
    end
    if not player_pos then
        behind_warning_data.visible = false
        return
    end
    
    -- Spieler-Blickrichtung (Rotation)
    local player_rotation = 0
    if local_player.get_rotation then
        local ok_rot, rot = pcall(local_player.get_rotation, local_player)
        if ok_rot and rot then
            player_rotation = rot
        end
    end
    
    -- Max Distance aus Slider
    local max_distance = 20.0
    if menu_elements.behind_warning_distance and menu_elements.behind_warning_distance.get then
        local ok_dist, dist = pcall(menu_elements.behind_warning_distance.get, menu_elements.behind_warning_distance)
        if ok_dist and dist then
            max_distance = dist
        end
    end
    
    local objects = core.object_manager.get_all_objects()
    if not objects then
        behind_warning_data.visible = false
        return
    end
    
    local enemies_behind = {}
    local closest_behind_enemy = nil
    local closest_behind_distance = 999999
    local closest_behind_name = ""
    local closest_behind_angle = 0
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue_behind
            end
            
            -- Nur Units prüfen
            local is_unit = false
            if obj.is_unit then
                local ok_unit, unit = pcall(obj.is_unit, obj)
                if ok_unit and unit then
                    is_unit = unit
                end
            end
            if not is_unit then
                goto continue_behind
            end
            
            -- Ist es ein Feind?
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                if ok_enemy and enemy then
                    is_enemy = enemy
                end
            end
            if not is_enemy or is_player_pet(obj) then
                goto continue_behind
            end
            
            -- Ist es tot?
            local is_dead = false
            if obj.is_dead then
                local ok_dead, dead = pcall(obj.is_dead, obj)
                if ok_dead and dead then
                    is_dead = dead
                end
            end
            if is_dead then
                goto continue_behind
            end
            
            -- Position des Feindes
            local obj_pos = nil
            if obj.get_position then
                local ok_pos, pos = pcall(obj.get_position, obj)
                if ok_pos and pos and pos.x and pos.y then
                    obj_pos = pos
                end
            end
            if not obj_pos then
                goto continue_behind
            end
            
            -- Distanz berechnen
            local dx = obj_pos.x - player_pos.x
            local dy = obj_pos.y - player_pos.y
            local distance = math.sqrt(dx*dx + dy*dy)
            
            if distance > max_distance then
                goto continue_behind
            end
            
            -- Winkel zum Feind berechnen
            local angle_to_enemy = math.atan2(dy, dx)
            local relative_angle = angle_to_enemy - player_rotation
            
            -- Normalisiere auf -PI bis PI
            while relative_angle > math.pi do
                relative_angle = relative_angle - 2 * math.pi
            end
            while relative_angle < -math.pi do
                relative_angle = relative_angle + 2 * math.pi
            end
            
            -- "Hinter" = Winkel > 90° oder < -90° (also abs > 90°)
            -- Wir nutzen einen breiteren Bereich: > 100° für "behind"
            local behind_threshold = math.rad(100) -- 100 Grad
            if math.abs(relative_angle) > behind_threshold then
                -- Feind ist hinter dem Spieler!
                local enemy_name = "Enemy"
                if obj.get_name then
                    local ok_name, name = pcall(obj.get_name, obj)
                    if ok_name and name then
                        enemy_name = name
                    end
                end
                
                table.insert(enemies_behind, {
                    name = enemy_name,
                    distance = distance,
                    angle = relative_angle
                })
                
                if distance < closest_behind_distance then
                    closest_behind_distance = distance
                    closest_behind_enemy = obj
                    closest_behind_name = enemy_name
                    closest_behind_angle = relative_angle
                end
            end
            
            ::continue_behind::
        end
    end
    
    -- Warndaten aktualisieren
    if #enemies_behind > 0 then
        behind_warning_data.visible = true
        behind_warning_data.enemy_count = #enemies_behind
        behind_warning_data.closest_enemy_name = closest_behind_name
        behind_warning_data.closest_distance = closest_behind_distance
        behind_warning_data.direction_angle = closest_behind_angle
        behind_warning_data.is_critical = (#enemies_behind > 1) or (closest_behind_distance < 10)
        
    else
        behind_warning_data.visible = false
    end
end

-- Patrol Warning - Erkennt sich bewegende Mobs (Patrouillen)
local function check_patrol_warning()
    if not menu_elements.patrol_warning or not menu_elements.patrol_warning.get_state then
        patrol_warning_data.visible = false
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.patrol_warning.get_state, menu_elements.patrol_warning)
    if ok and val then
        enabled = val
    end
    if not enabled then
        patrol_warning_data.visible = false
        return
    end
    
    if not core or not core.object_manager then
        patrol_warning_data.visible = false
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        patrol_warning_data.visible = false
        return
    end
    
    local player_pos = nil
    if local_player.get_position then
        local ok_pos, pos = pcall(local_player.get_position, local_player)
        if ok_pos and pos then
            player_pos = pos
        end
    end
    if not player_pos then
        patrol_warning_data.visible = false
        return
    end
    
    -- Max Distance aus Slider
    local max_distance = 30.0
    if menu_elements.patrol_warning_distance and menu_elements.patrol_warning_distance.get then
        local ok_dist, dist = pcall(menu_elements.patrol_warning_distance.get, menu_elements.patrol_warning_distance)
        if ok_dist and dist then
            max_distance = dist
        end
    end
    
    local current_frame = render_frame_count or 0
    local objects = core.object_manager.get_all_objects()
    if not objects then
        patrol_warning_data.visible = false
        return
    end
    
    local patrols_approaching = {}
    local closest_patrol = nil
    local closest_patrol_distance = 999999
    local closest_patrol_name = ""
    local closest_patrol_angle = 0
    local closest_is_approaching = false
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue_patrol
            end
            
            -- Nur Units prüfen
            local is_unit = false
            if obj.is_unit then
                local ok_unit, unit = pcall(obj.is_unit, obj)
                if ok_unit and unit then
                    is_unit = unit
                end
            end
            if not is_unit then
                goto continue_patrol
            end
            
            -- Ist es ein Feind?
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                if ok_enemy and enemy then
                    is_enemy = enemy
                end
            end
            if not is_enemy or is_player_pet(obj) then
                goto continue_patrol
            end
            
            -- Ist es tot?
            local is_dead = false
            if obj.is_dead then
                local ok_dead, dead = pcall(obj.is_dead, obj)
                if ok_dead and dead then
                    is_dead = dead
                end
            end
            if is_dead then
                goto continue_patrol
            end
            
            -- GUID für Tracking
            local guid = nil
            if obj.get_guid then
                local ok_guid, g = pcall(obj.get_guid, obj)
                if ok_guid and g then
                    guid = tostring(g)
                end
            end
            if not guid then
                goto continue_patrol
            end
            
            -- Position des Feindes
            local obj_pos = nil
            if obj.get_position then
                local ok_pos, pos = pcall(obj.get_position, obj)
                if ok_pos and pos and pos.x and pos.y then
                    obj_pos = pos
                end
            end
            if not obj_pos then
                goto continue_patrol
            end
            
            -- Distanz berechnen
            local dx = obj_pos.x - player_pos.x
            local dy = obj_pos.y - player_pos.y
            local distance = math.sqrt(dx*dx + dy*dy)
            
            if distance > max_distance then
                -- Position trotzdem speichern für später
                mob_last_positions[guid] = {x = obj_pos.x, y = obj_pos.y, z = obj_pos.z or 0}
                mob_position_update_time[guid] = current_frame
                goto continue_patrol
            end
            
            -- Prüfe ob wir eine vorherige Position haben
            local last_pos = mob_last_positions[guid]
            local last_frame = mob_position_update_time[guid]
            
            if last_pos and last_frame then
                local frame_diff = current_frame - last_frame
                
                if frame_diff >= PATROL_POSITION_HISTORY_FRAMES then
                    -- Berechne Bewegung
                    local move_dx = obj_pos.x - last_pos.x
                    local move_dy = obj_pos.y - last_pos.y
                    local move_distance = math.sqrt(move_dx*move_dx + move_dy*move_dy)
                    
                    if move_distance >= PATROL_MIN_MOVE_DISTANCE then
                        -- Das ist eine Patrouille!
                        
                        -- Normalisiere Bewegungsrichtung
                        local move_dir_x = move_dx / move_distance
                        local move_dir_y = move_dy / move_distance
                        
                        -- Richtung vom Mob zum Spieler
                        local to_player_x = player_pos.x - obj_pos.x
                        local to_player_y = player_pos.y - obj_pos.y
                        local to_player_dist = math.sqrt(to_player_x*to_player_x + to_player_y*to_player_y)
                        if to_player_dist > 0.1 then
                            to_player_x = to_player_x / to_player_dist
                            to_player_y = to_player_y / to_player_dist
                        end
                        
                        -- Dot-Product: Positiv wenn Mob auf Spieler zukommt
                        local dot = move_dir_x * to_player_x + move_dir_y * to_player_y
                        local is_approaching = dot > 0.3  -- > 0.3 = kommt grob auf Spieler zu
                        
                        local enemy_name = "Patrol"
                        if obj.get_name then
                            local ok_name, name = pcall(obj.get_name, obj)
                            if ok_name and name then
                                enemy_name = name
                            end
                        end
                        
                        if is_approaching then
                            table.insert(patrols_approaching, {
                                name = enemy_name,
                                distance = distance,
                                is_approaching = true
                            })
                        end
                        
                        -- Track closest patrol (egal ob approaching oder nicht)
                        if distance < closest_patrol_distance then
                            closest_patrol_distance = distance
                            closest_patrol = obj
                            closest_patrol_name = enemy_name
                            closest_patrol_angle = math.atan2(dy, dx)
                            closest_is_approaching = is_approaching
                        end
                    end
                    
                    -- Update Position
                    mob_last_positions[guid] = {x = obj_pos.x, y = obj_pos.y, z = obj_pos.z or 0}
                    mob_position_update_time[guid] = current_frame
                end
            else
                -- Erste Position speichern
                mob_last_positions[guid] = {x = obj_pos.x, y = obj_pos.y, z = obj_pos.z or 0}
                mob_position_update_time[guid] = current_frame
            end
            
            ::continue_patrol::
        end
    end
    
    -- Cleanup alte Einträge (Mobs die nicht mehr existieren)
    local cleanup_threshold = current_frame - 1800  -- ~30 Sekunden alte Einträge löschen (bei 60 FPS)
    for guid, frame in pairs(mob_position_update_time) do
        if frame < cleanup_threshold then
            mob_last_positions[guid] = nil
            mob_position_update_time[guid] = nil
        end
    end
    
    -- Warndaten aktualisieren - nur wenn Patrouillen auf uns zukommen
    if #patrols_approaching > 0 and closest_patrol then
        patrol_warning_data.visible = true
        patrol_warning_data.patrol_count = #patrols_approaching
        patrol_warning_data.closest_patrol_name = closest_patrol_name
        patrol_warning_data.closest_distance = closest_patrol_distance
        patrol_warning_data.direction_angle = closest_patrol_angle
        patrol_warning_data.is_approaching = closest_is_approaching
        patrol_warning_data.is_critical = (#patrols_approaching > 1) or (closest_patrol_distance < 15)
        
    else
        patrol_warning_data.visible = false
    end
end

-- Level Warning Popup rendern (wird in on_render_window_callback aufgerufen)
-- Speichere Pfeil-Daten für Rendering nach dem Window
local level_warning_arrow_data = {
    should_render = false,
    center_x = 0,
    center_y = 0,
    angle = 0,
    is_critical = false
}

local function render_level_warning_popup()
    if not level_warning_window or not level_warning_data.visible then
        level_warning_arrow_data.should_render = false
        return
    end
    
    -- Position aus Slidern laden (persistent, einstellbar im Menü)
    local window_pos_x = 100.0
    local window_pos_y = 150.0
    if menu_elements.level_warning_pos_x and menu_elements.level_warning_pos_x.get then
        local ok, val = pcall(menu_elements.level_warning_pos_x.get, menu_elements.level_warning_pos_x)
        if ok and val and type(val) == "number" then
            window_pos_x = val
        end
    end
    if menu_elements.level_warning_pos_y and menu_elements.level_warning_pos_y.get then
        local ok, val = pcall(menu_elements.level_warning_pos_y.get, menu_elements.level_warning_pos_y)
        if ok and val and type(val) == "number" then
            window_pos_y = val
        end
    end
    
    -- ESP Theme Farben
    local bg_color = color.new(28, 30, 35, 245)
    local main_border_color = color.new(0, 180, 200, 255)
    
    -- Akzentfarben basierend auf Gefährlichkeit (ESP Theme)
    local accent_color = level_warning_data.is_critical 
        and color.new(255, 50, 50, 255) 
        or color.new(0, 200, 220, 255)
    local title_color = level_warning_data.is_critical 
        and color.new(255, 80, 80, 255) 
        or color.new(100, 220, 255, 255)
    
    -- Position mit force_next_begin_window_pos setzen
    level_warning_window:force_next_begin_window_pos(vec2.new(window_pos_x, window_pos_y))
    
    level_warning_window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        false,
        bg_color,
        main_border_color,
        enums.window_enums.window_cross_visuals.DEFAULT,
        0, 0, 0,
        function()
            local ws = level_warning_window:get_size()
            local wp = level_warning_window:get_position()
            
            -- Base offset für Window-relative Koordinaten
            local base = level_warning_window:get_current_context_dynamic_drawing_offset()
            local at = function(x, y) return vec2.new(base.x + x, base.y + y) end
            
            -- Header-Bereich mit Gradient (ESP Theme)
            local header_gradient_top = color.new(0, 200, 220, 200)
            local header_gradient_bottom = color.new(0, 150, 170, 180)
            level_warning_window:render_rect_filled_multicolor(
                at(6, 4), at(ws.x - 6, 32),
                header_gradient_top, header_gradient_top,
                header_gradient_bottom, header_gradient_bottom,
                5.0
            )
            -- Akzent-Border oben im Header
            level_warning_window:render_rect(at(6, 4), at(ws.x - 6, 32), accent_color, 5.0, 2)
            
            -- Pfeil-Bereich rechts im Fenster
            local arrow_box_size = 50
            local arrow_box_x = ws.x - arrow_box_size - 12
            local arrow_box_y = 40
            
            -- Feste Y-Positionen für Layout (Text links, Pfeil rechts)
            local y_title = 8
            local y_separator = 36
            local y_name = 46
            local y_level = 64
            local y_distance = 82
            
            -- Titel - zentriert im Header
            local title_text = level_warning_data.is_critical and "!! RUN !!" or "WARNING"
            level_warning_window:push_font(enums.window_enums.font_id.FONT_BIG)
            local title_size = level_warning_window:get_text_size(title_text)
            local title_x = (ws.x - title_size.x) / 2
            level_warning_window:render_text(enums.window_enums.font_id.FONT_BIG, at(title_x, y_title), title_color, title_text)
            level_warning_window:pop_font()
            
            -- Content-Panel Hintergrund (ESP Theme)
            local content_bg = color.new(35, 38, 45, 200)
            level_warning_window:render_rect_filled(at(6, y_separator), at(ws.x - 6, ws.y - 6), content_bg, 5.0)
            level_warning_window:render_rect(at(6, y_separator), at(ws.x - 6, ws.y - 6), color.new(0, 150, 170, 180), 5.0, 1)
            
            -- Gegner-Name
            local name_text = level_warning_data.enemy_name
            if #name_text > 12 then
                name_text = name_text:sub(1, 11) .. ".."
            end
            level_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_name), color.white(245), name_text)
            
            -- Level-Differenz
            local level_text = "Lv " .. level_warning_data.enemy_level .. " (+" .. level_warning_data.level_diff .. ")"
            level_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_level), title_color, level_text)
            
            -- Distanz
            local dist_text = string.format("%.1f yd", level_warning_data.distance)
            level_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_distance), color.new(180, 190, 200, 255), dist_text)
            
            -- Vertikale Trennlinie zwischen Text und Pfeil (ESP Theme)
            level_warning_window:render_rect_filled(at(arrow_box_x - 6, y_separator + 6), at(arrow_box_x - 4, ws.y - 12), color.new(0, 150, 170, 180), 2)
            
            -- Pfeil-Hintergrund (ESP Theme)
            local arrow_bg_color = color.new(35, 38, 45, 230)
            local arrow_center_x = arrow_box_x + arrow_box_size / 2
            local arrow_center_y = arrow_box_y + arrow_box_size / 2
            level_warning_window:render_circle_filled(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, arrow_bg_color, 0)
            level_warning_window:render_circle(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, accent_color, 2.0, 0)
            
            -- Pfeil direkt im Fenster zeichnen
            local arrow_radius = 16
            local angle = level_warning_data.direction_angle - math.pi / 2
            
            local tip_x = arrow_center_x + math.cos(angle) * arrow_radius
            local tip_y = arrow_center_y + math.sin(angle) * arrow_radius
            local wing_angle = 2.4
            local wing_length = arrow_radius * 0.65
            local left_x = arrow_center_x + math.cos(angle + wing_angle) * wing_length
            local left_y = arrow_center_y + math.sin(angle + wing_angle) * wing_length
            local right_x = arrow_center_x + math.cos(angle - wing_angle) * wing_length
            local right_y = arrow_center_y + math.sin(angle - wing_angle) * wing_length
            
            local arrow_color = title_color
            
            -- Pfeil-Dreieck
            level_warning_window:render_triangle_filled(at(tip_x, tip_y), at(left_x, left_y), at(right_x, right_y), arrow_color)
            
            -- Pfeil-Umrandung
            level_warning_window:render_line(at(tip_x, tip_y), at(left_x, left_y), color.white(200), 1.5)
            level_warning_window:render_line(at(left_x, left_y), at(right_x, right_y), color.white(200), 1.5)
            level_warning_window:render_line(at(right_x, right_y), at(tip_x, tip_y), color.white(200), 1.5)
            
            -- "^" für Vorwärts-Referenz
            level_warning_window:render_text(enums.window_enums.font_id.FONT_SMALL, at(arrow_center_x - 3, arrow_center_y - arrow_radius - 6), color.white(150), "^")
            
            -- Speichere Daten für Pfeil-Overlay (falls benötigt)
            level_warning_arrow_data.should_render = false
            level_warning_arrow_data.center_x = wp.x + arrow_center_x
            level_warning_arrow_data.center_y = wp.y + arrow_center_y
            level_warning_arrow_data.angle = angle
            level_warning_arrow_data.is_critical = level_warning_data.is_critical
            level_warning_arrow_data.border_color = accent_color
        end
    )
end

-- Pfeil über dem Fenster zeichnen (wird im on_render_menu_callback aufgerufen, der NACH windows kommt)
local function render_level_warning_arrow()
    if not level_warning_arrow_data.should_render then
        return
    end
    
    local arrow_center_x = level_warning_arrow_data.center_x
    local arrow_center_y = level_warning_arrow_data.center_y
    local angle = level_warning_arrow_data.angle
    local arrow_radius = 20
    
    -- Pfeil-Dreieck berechnen
    local tip_x = arrow_center_x + math.cos(angle) * arrow_radius
    local tip_y = arrow_center_y + math.sin(angle) * arrow_radius
    local wing_angle = 2.4
    local wing_length = arrow_radius * 0.65
    local left_x = arrow_center_x + math.cos(angle + wing_angle) * wing_length
    local left_y = arrow_center_y + math.sin(angle + wing_angle) * wing_length
    local right_x = arrow_center_x + math.cos(angle - wing_angle) * wing_length
    local right_y = arrow_center_y + math.sin(angle - wing_angle) * wing_length
    
    -- Pfeil-Farbe
    local arrow_color = level_warning_arrow_data.is_critical 
        and color.new(255, 80, 80, 255) 
        or color.new(255, 180, 80, 255)
    local border_color = level_warning_arrow_data.border_color or color.new(255, 150, 50, 255)
    
    -- Hintergrund-Kreis
    if core.graphics and core.graphics.circle_2d_filled then
        pcall(core.graphics.circle_2d_filled, vec2_new(arrow_center_x, arrow_center_y), arrow_radius + 6, color.new(30, 30, 40, 240))
        pcall(core.graphics.circle_2d, vec2_new(arrow_center_x, arrow_center_y), arrow_radius + 6, border_color, 2.0)
    end
    
    -- Pfeil zeichnen
    if core.graphics and core.graphics.triangle_2d_filled then
        pcall(core.graphics.triangle_2d_filled,
            vec2_new(tip_x, tip_y),
            vec2_new(left_x, left_y),
            vec2_new(right_x, right_y),
            arrow_color
        )
    end
    
    -- Pfeil-Umrandung
    if core.graphics and core.graphics.line_2d then
        local outline_color = color.white(255)
        pcall(core.graphics.line_2d, vec2_new(tip_x, tip_y), vec2_new(left_x, left_y), outline_color, 1.5)
        pcall(core.graphics.line_2d, vec2_new(left_x, left_y), vec2_new(right_x, right_y), outline_color, 1.5)
        pcall(core.graphics.line_2d, vec2_new(right_x, right_y), vec2_new(tip_x, tip_y), outline_color, 1.5)
    end
    
    -- "^" für Vorwärts-Referenz oben
    if core.graphics and core.graphics.text_2d then
        local n_y = arrow_center_y - arrow_radius - 10
        pcall(core.graphics.text_2d, "^", vec2_new(arrow_center_x, n_y), 12, color.white(150), true)
    end
end

-- Behind You Warning Popup rendern
local behind_warning_arrow_data = {
    should_render = false,
    center_x = 0,
    center_y = 0,
    angle = 0,
    is_critical = false
}

local function render_behind_warning_popup()
    if not behind_warning_window or not behind_warning_data.visible then
        behind_warning_arrow_data.should_render = false
        return
    end
    
    -- Position aus Slidern laden (persistent, einstellbar im Menü)
    local window_pos_x = 100.0
    local window_pos_y = 270.0
    if menu_elements.behind_warning_pos_x and menu_elements.behind_warning_pos_x.get then
        local ok, val = pcall(menu_elements.behind_warning_pos_x.get, menu_elements.behind_warning_pos_x)
        if ok and val and type(val) == "number" then
            window_pos_x = val
        end
    end
    if menu_elements.behind_warning_pos_y and menu_elements.behind_warning_pos_y.get then
        local ok, val = pcall(menu_elements.behind_warning_pos_y.get, menu_elements.behind_warning_pos_y)
        if ok and val and type(val) == "number" then
            window_pos_y = val
        end
    end
    
    -- ESP Theme Farben
    local bg_color = color.new(28, 30, 35, 245)
    local main_border_color = color.new(0, 180, 200, 255)
    
    -- Akzentfarben basierend auf Gefährlichkeit (ESP Theme)
    local accent_color = behind_warning_data.is_critical 
        and color.new(255, 50, 50, 255) 
        or color.new(0, 200, 220, 255)
    local title_color = behind_warning_data.is_critical 
        and color.new(255, 60, 60, 255) 
        or color.new(100, 220, 255, 255)
    
    -- Position mit force_next_begin_window_pos setzen
    behind_warning_window:force_next_begin_window_pos(vec2.new(window_pos_x, window_pos_y))
    
    behind_warning_window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        false,
        bg_color,
        main_border_color,
        enums.window_enums.window_cross_visuals.DEFAULT,
        0, 0, 0,
        function()
            local ws = behind_warning_window:get_size()
            local wp = behind_warning_window:get_position()
            local base = behind_warning_window:get_current_context_dynamic_drawing_offset()
            local at = function(x, y) return vec2.new(base.x + x, base.y + y) end
            
            -- Header-Bereich mit Gradient (ESP Theme)
            local header_gradient_top = color.new(0, 200, 220, 200)
            local header_gradient_bottom = color.new(0, 150, 170, 180)
            behind_warning_window:render_rect_filled_multicolor(
                at(6, 4), at(ws.x - 6, 32),
                header_gradient_top, header_gradient_top,
                header_gradient_bottom, header_gradient_bottom,
                5.0
            )
            -- Akzent-Border oben im Header
            behind_warning_window:render_rect(at(6, 4), at(ws.x - 6, 32), accent_color, 5.0, 2)
            
            -- Layout
            local arrow_box_size = 50
            local arrow_box_x = ws.x - arrow_box_size - 12
            local arrow_box_y = 38
            
            local y_title = 8
            local y_separator = 36
            local y_enemy = 45
            local y_distance = 63
            
            -- Titel - zentriert im Header
            local title_text = behind_warning_data.is_critical and "!! BEHIND !!" or "BEHIND"
            behind_warning_window:push_font(enums.window_enums.font_id.FONT_BIG)
            local title_size = behind_warning_window:get_text_size(title_text)
            local title_x = (ws.x - title_size.x) / 2
            behind_warning_window:render_text(enums.window_enums.font_id.FONT_BIG, at(title_x, y_title), title_color, title_text)
            behind_warning_window:pop_font()
            
            -- Content-Panel Hintergrund (ESP Theme)
            local content_bg = color.new(35, 38, 45, 200)
            behind_warning_window:render_rect_filled(at(6, y_separator), at(ws.x - 6, ws.y - 6), content_bg, 5.0)
            behind_warning_window:render_rect(at(6, y_separator), at(ws.x - 6, ws.y - 6), color.new(0, 150, 170, 180), 5.0, 1)
            
            -- Feind-Info
            local enemy_text = behind_warning_data.enemy_count > 1 
                and (behind_warning_data.enemy_count .. " enemies!") 
                or behind_warning_data.closest_enemy_name
            if #enemy_text > 14 then
                enemy_text = enemy_text:sub(1, 13) .. ".."
            end
            behind_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_enemy), color.white(245), enemy_text)
            
            -- Distanz
            local dist_text = string.format("%.1f yd", behind_warning_data.closest_distance)
            behind_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_distance), color.new(180, 190, 200, 255), dist_text)
            
            -- Vertikale Trennlinie (ESP Theme)
            behind_warning_window:render_rect_filled(at(arrow_box_x - 6, y_separator + 6), at(arrow_box_x - 4, ws.y - 12), color.new(0, 150, 170, 180), 2)
            
            -- Pfeil-Hintergrund (ESP Theme)
            local arrow_bg_color = color.new(35, 38, 45, 230)
            local arrow_center_x = arrow_box_x + arrow_box_size / 2
            local arrow_center_y = arrow_box_y + arrow_box_size / 2
            behind_warning_window:render_circle_filled(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, arrow_bg_color, 0)
            behind_warning_window:render_circle(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, accent_color, 2.0, 0)
            
            -- Pfeil direkt im Fenster zeichnen
            local arrow_radius = 16
            local angle = behind_warning_data.direction_angle - math.pi / 2
            
            local tip_x = arrow_center_x + math.cos(angle) * arrow_radius
            local tip_y = arrow_center_y + math.sin(angle) * arrow_radius
            local wing_angle = 2.5
            local wing_length = arrow_radius * 0.7
            local left_x = arrow_center_x + math.cos(angle + wing_angle) * wing_length
            local left_y = arrow_center_y + math.sin(angle + wing_angle) * wing_length
            local right_x = arrow_center_x + math.cos(angle - wing_angle) * wing_length
            local right_y = arrow_center_y + math.sin(angle - wing_angle) * wing_length
            
            local arrow_color = title_color
            
            -- Pfeil-Dreieck
            behind_warning_window:render_triangle_filled(at(tip_x, tip_y), at(left_x, left_y), at(right_x, right_y), arrow_color)
            
            -- Pfeil-Umrandung
            behind_warning_window:render_line(at(tip_x, tip_y), at(left_x, left_y), color.white(200), 1.5)
            behind_warning_window:render_line(at(left_x, left_y), at(right_x, right_y), color.white(200), 1.5)
            behind_warning_window:render_line(at(right_x, right_y), at(tip_x, tip_y), color.white(200), 1.5)
            
            -- "^" für Vorwärts-Referenz
            behind_warning_window:render_text(enums.window_enums.font_id.FONT_SMALL, at(arrow_center_x - 3, arrow_center_y - arrow_radius - 6), color.white(150), "^")
            
            -- Deaktiviere separates Overlay-Rendering
            behind_warning_arrow_data.should_render = false
        end
    )
end

-- Pfeil für Behind Warning über dem Fenster
local function render_behind_warning_arrow()
    if not behind_warning_arrow_data.should_render then
        return
    end
    
    local arrow_center_x = behind_warning_arrow_data.center_x
    local arrow_center_y = behind_warning_arrow_data.center_y
    local arrow_radius = 22
    local angle = behind_warning_arrow_data.angle
    
    local vec2_new = vec2.new
    
    -- Pfeil-Spitze und Flügel berechnen
    local tip_x = arrow_center_x + math.cos(angle) * arrow_radius
    local tip_y = arrow_center_y + math.sin(angle) * arrow_radius
    local wing_angle = 2.5
    local wing_length = arrow_radius * 0.7
    local left_x = arrow_center_x + math.cos(angle + wing_angle) * wing_length
    local left_y = arrow_center_y + math.sin(angle + wing_angle) * wing_length
    local right_x = arrow_center_x + math.cos(angle - wing_angle) * wing_length
    local right_y = arrow_center_y + math.sin(angle - wing_angle) * wing_length
    
    local arrow_color = behind_warning_arrow_data.is_critical 
        and color.new(255, 60, 60, 255) 
        or color.new(255, 200, 80, 255)
    local border_color = behind_warning_arrow_data.border_color or color.white(255)
    
    -- Hintergrund-Kreis
    if core.graphics and core.graphics.circle_2d_filled then
        pcall(core.graphics.circle_2d_filled, vec2_new(arrow_center_x, arrow_center_y), arrow_radius + 6, color.new(40, 20, 20, 240))
        pcall(core.graphics.circle_2d, vec2_new(arrow_center_x, arrow_center_y), arrow_radius + 6, border_color, 2.0)
    end
    
    -- Pfeil zeichnen
    if core.graphics and core.graphics.triangle_2d_filled then
        pcall(core.graphics.triangle_2d_filled,
            vec2_new(tip_x, tip_y),
            vec2_new(left_x, left_y),
            vec2_new(right_x, right_y),
            arrow_color
        )
    end
    
    -- Pfeil-Umrandung
    if core.graphics and core.graphics.line_2d then
        local outline_color = color.white(255)
        pcall(core.graphics.line_2d, vec2_new(tip_x, tip_y), vec2_new(left_x, left_y), outline_color, 1.5)
        pcall(core.graphics.line_2d, vec2_new(left_x, left_y), vec2_new(right_x, right_y), outline_color, 1.5)
        pcall(core.graphics.line_2d, vec2_new(right_x, right_y), vec2_new(tip_x, tip_y), outline_color, 1.5)
    end
    
    -- "^" für Vorwärts-Referenz
    if core.graphics and core.graphics.text_2d then
        local n_y = arrow_center_y - arrow_radius - 10
        pcall(core.graphics.text_2d, "^", vec2_new(arrow_center_x, n_y), 12, color.white(150), true)
    end
end

-- Patrol Warning Popup rendern
local function render_patrol_warning_popup()
    if not patrol_warning_window or not patrol_warning_data.visible then
        return
    end
    
    -- Position aus Slidern laden (persistent, einstellbar im Menü)
    local window_pos_x = 100.0
    local window_pos_y = 380.0
    if menu_elements.patrol_warning_pos_x and menu_elements.patrol_warning_pos_x.get then
        local ok, val = pcall(menu_elements.patrol_warning_pos_x.get, menu_elements.patrol_warning_pos_x)
        if ok and val and type(val) == "number" then
            window_pos_x = val
        end
    end
    if menu_elements.patrol_warning_pos_y and menu_elements.patrol_warning_pos_y.get then
        local ok, val = pcall(menu_elements.patrol_warning_pos_y.get, menu_elements.patrol_warning_pos_y)
        if ok and val and type(val) == "number" then
            window_pos_y = val
        end
    end
    
    -- ESP Theme Farben
    local bg_color = color.new(28, 30, 35, 245)
    local main_border_color = color.new(0, 180, 200, 255)
    
    -- Akzentfarben - Cyan für Patrouillen, Rot wenn kritisch (ESP Theme)
    local accent_color = patrol_warning_data.is_critical 
        and color.new(255, 100, 50, 255) 
        or color.new(0, 200, 220, 255)
    local title_color = patrol_warning_data.is_critical 
        and color.new(255, 120, 50, 255) 
        or color.new(100, 220, 255, 255)
    
    -- Position mit force_next_begin_window_pos setzen
    patrol_warning_window:force_next_begin_window_pos(vec2.new(window_pos_x, window_pos_y))
    
    patrol_warning_window:begin(
        enums.window_enums.window_resizing_flags.RESIZE_BOTH_AXIS,
        false,
        bg_color,
        main_border_color,
        enums.window_enums.window_cross_visuals.DEFAULT,
        0, 0, 0,
        function()
            local ws = patrol_warning_window:get_size()
            local wp = patrol_warning_window:get_position()
            local base = patrol_warning_window:get_current_context_dynamic_drawing_offset()
            local at = function(x, y) return vec2.new(base.x + x, base.y + y) end
            
            -- Header-Bereich mit Gradient (ESP Theme)
            local header_gradient_top = color.new(0, 200, 220, 200)
            local header_gradient_bottom = color.new(0, 150, 170, 180)
            patrol_warning_window:render_rect_filled_multicolor(
                at(6, 4), at(ws.x - 6, 32),
                header_gradient_top, header_gradient_top,
                header_gradient_bottom, header_gradient_bottom,
                5.0
            )
            -- Akzent-Border oben im Header
            patrol_warning_window:render_rect(at(6, 4), at(ws.x - 6, 32), accent_color, 5.0, 2)
            
            -- Layout
            local arrow_box_size = 50
            local arrow_box_x = ws.x - arrow_box_size - 12
            local arrow_box_y = 40
            
            local y_title = 8
            local y_separator = 36
            local y_enemy = 45
            local y_distance = 62
            local y_status = 79
            
            -- Titel - zentriert im Header
            local title_text = patrol_warning_data.is_critical and "!! PATROL !!" or "PATROL"
            patrol_warning_window:push_font(enums.window_enums.font_id.FONT_BIG)
            local title_size = patrol_warning_window:get_text_size(title_text)
            local title_x = (ws.x - title_size.x) / 2
            patrol_warning_window:render_text(enums.window_enums.font_id.FONT_BIG, at(title_x, y_title), title_color, title_text)
            patrol_warning_window:pop_font()
            
            -- Content-Panel Hintergrund (ESP Theme)
            local content_bg = color.new(35, 38, 45, 200)
            patrol_warning_window:render_rect_filled(at(6, y_separator), at(ws.x - 6, ws.y - 6), content_bg, 5.0)
            patrol_warning_window:render_rect(at(6, y_separator), at(ws.x - 6, ws.y - 6), color.new(0, 150, 170, 180), 5.0, 1)
            
            -- Feind-Info
            local enemy_text = patrol_warning_data.patrol_count > 1 
                and (patrol_warning_data.patrol_count .. " patrols!") 
                or patrol_warning_data.closest_patrol_name
            if #enemy_text > 14 then
                enemy_text = enemy_text:sub(1, 13) .. ".."
            end
            patrol_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_enemy), color.white(245), enemy_text)
            
            -- Distanz
            local dist_text = string.format("%.1f yd", patrol_warning_data.closest_distance)
            patrol_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_distance), color.new(180, 190, 200, 255), dist_text)
            
            -- Status
            local status_text = patrol_warning_data.is_approaching and "INCOMING!" or "Moving"
            local status_color = patrol_warning_data.is_approaching and color.new(255, 80, 80, 255) or color.new(100, 220, 255, 255)
            patrol_warning_window:render_text(enums.window_enums.font_id.FONT_NORMAL, at(14, y_status), status_color, status_text)
            
            -- Vertikale Trennlinie (ESP Theme)
            patrol_warning_window:render_rect_filled(at(arrow_box_x - 6, y_separator + 6), at(arrow_box_x - 4, ws.y - 12), color.new(0, 150, 170, 180), 2)
            
            -- Pfeil-Hintergrund (ESP Theme)
            local arrow_bg_color = color.new(35, 38, 45, 230)
            local arrow_center_x = arrow_box_x + arrow_box_size / 2
            local arrow_center_y = arrow_box_y + arrow_box_size / 2
            patrol_warning_window:render_circle_filled(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, arrow_bg_color, 0)
            patrol_warning_window:render_circle(at(arrow_center_x, arrow_center_y), arrow_box_size / 2, accent_color, 2.0, 0)
            
            -- Pfeil direkt im Fenster zeichnen (zeigt Richtung zur Patrouille)
            local arrow_radius = 16
            local angle = patrol_warning_data.direction_angle - math.pi / 2
            
            local tip_x = arrow_center_x + math.cos(angle) * arrow_radius
            local tip_y = arrow_center_y + math.sin(angle) * arrow_radius
            local wing_angle = 2.5
            local wing_length = arrow_radius * 0.7
            local left_x = arrow_center_x + math.cos(angle + wing_angle) * wing_length
            local left_y = arrow_center_y + math.sin(angle + wing_angle) * wing_length
            local right_x = arrow_center_x + math.cos(angle - wing_angle) * wing_length
            local right_y = arrow_center_y + math.sin(angle - wing_angle) * wing_length
            
            local arrow_color = title_color
            
            -- Pfeil-Dreieck
            patrol_warning_window:render_triangle_filled(at(tip_x, tip_y), at(left_x, left_y), at(right_x, right_y), arrow_color)
            
            -- Pfeil-Umrandung
            patrol_warning_window:render_line(at(tip_x, tip_y), at(left_x, left_y), color.white(200), 1.5)
            patrol_warning_window:render_line(at(left_x, left_y), at(right_x, right_y), color.white(200), 1.5)
            patrol_warning_window:render_line(at(right_x, right_y), at(tip_x, tip_y), color.white(200), 1.5)
            
            -- "^" für Vorwärts-Referenz
            patrol_warning_window:render_text(enums.window_enums.font_id.FONT_SMALL, at(arrow_center_x - 3, arrow_center_y - arrow_radius - 6), color.white(150), "^")
        end
    )
end

-- Safe Zone Indicator
-- Hilfsfunktion zum Zeichnen eines gefüllten 3D-Pfeilkopfes
-- Pfeil zeigt von start_pos nach end_pos, Spitze bei end_pos
local function draw_arrow_3d(start_pos, end_pos, arrow_color, arrow_thickness)
    if not start_pos or not end_pos or not arrow_color or not core or not core.graphics then
        return
    end
    
    -- Berechne Richtungsvektor (von start nach end)
    local dx = end_pos.x - start_pos.x
    local dy = end_pos.y - start_pos.y
    local dz = (end_pos.z or 0) - (start_pos.z or 0)
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    
    if distance < 0.1 then
        return
    end
    
    -- Normalisiere Richtungsvektor
    dx = dx / distance
    dy = dy / distance
    dz = dz / distance
    
    -- Pfeilkopf-Größe
    local tip_length = 0.5
    local wing_width = 0.3
    
    -- Pfeilspitze (zeigt nach außen Richtung end)
    local arrow_tip = {
        x = start_pos.x + dx * tip_length,
        y = start_pos.y + dy * tip_length,
        z = (start_pos.z or 0)
    }
    
    -- Perpendikulare Vektoren für die Flügel
    local perp_x = -dy
    local perp_y = dx
    
    -- Basis-Ecken des Dreiecks
    local base_left = {
        x = start_pos.x + perp_x * wing_width,
        y = start_pos.y + perp_y * wing_width,
        z = start_pos.z or 0
    }
    local base_right = {
        x = start_pos.x - perp_x * wing_width,
        y = start_pos.y - perp_y * wing_width,
        z = start_pos.z or 0
    }
    
    -- Echtes gefülltes Dreieck mit triangle_3d_filled
    if core.graphics.triangle_3d_filled then
        pcall(core.graphics.triangle_3d_filled, arrow_tip, base_left, base_right, arrow_color)
    elseif core.graphics.line_3d then
        -- Fallback: Outline mit glatten Linien
        pcall(core.graphics.line_3d, arrow_tip, base_left, arrow_color, arrow_thickness, 1.5, true)
        pcall(core.graphics.line_3d, arrow_tip, base_right, arrow_color, arrow_thickness, 1.5, true)
        pcall(core.graphics.line_3d, base_left, base_right, arrow_color, arrow_thickness, 1.5, true)
    end
end

local function render_safe_zone_indicator()
    if not menu_elements.safe_zone_indicator or not menu_elements.safe_zone_indicator.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.safe_zone_indicator.get_state, menu_elements.safe_zone_indicator)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    -- Verwende gecachte Spielerposition für Frame-Konsistenz
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    
    local max_distance = 100.0
    if menu_elements.max_distance and menu_elements.max_distance.get then
        local ok, val = pcall(menu_elements.max_distance.get, menu_elements.max_distance)
        if ok and val and type(val) == "number" then
            max_distance = val
        end
    end
    
    local objects = core.object_manager.get_all_objects()
    if not objects then
        return
    end
    
    -- Radar-Radius (größer um den Spieler)
    local radar_radius = 5.0
    local radar_pos = {
        x = player_pos.x,
        y = player_pos.y,
        z = (player_pos.z or 0) + 0.1
    }
    
    -- Transparenz aus Menu holen (0-100 Prozent -> 0.0-1.0)
    local transparency_percent = 60
    if menu_elements.safe_zone_transparency and menu_elements.safe_zone_transparency.get then
        local ok, val = pcall(menu_elements.safe_zone_transparency.get, menu_elements.safe_zone_transparency)
        if ok and val and type(val) == "number" then
            transparency_percent = val
        end
    end
    local transparency = transparency_percent / 100  -- Konvertiere zu 0.0-1.0
    local base_alpha = math.floor(transparency * 255)
    
    -- Prüfe ob Quest-Mobs angezeigt werden sollen
    local show_quest_mobs = true
    if menu_elements.show_quest_mobs and menu_elements.show_quest_mobs.get_state then
        local ok, val = pcall(menu_elements.show_quest_mobs.get_state, menu_elements.show_quest_mobs)
        if ok and val ~= nil then
            show_quest_mobs = val
        end
    end
    
    -- Sammle Feinde und Quest-Mobs
    local enemies = {}
    local quest_mobs = {}
    local min_enemy_distance = 999999
    local enemy_found = false
    
    for _, obj in __object_safety.live_ipairs(objects) do
        if obj and obj.is_valid then
            local ok_valid, is_valid = pcall(obj.is_valid, obj)
            if not ok_valid or not is_valid then
                goto continue
            end
            
            local is_dead = false
            if obj.is_dead then
                local ok_dead, dead = pcall(obj.is_dead, obj)
                if ok_dead and dead then
                    is_dead = dead
                end
            end
            
            if not is_dead then
                local is_enemy = false
                if obj.is_enemy_with then
                    local ok_enemy, enemy = pcall(obj.is_enemy_with, obj, local_player)
                    if ok_enemy and enemy then
                        is_enemy = enemy
                    end
                end
                -- Spieler-Pets nicht als Feinde anzeigen
                if is_enemy and is_player_pet(obj) then
                    is_enemy = false
                end
                
                local is_quest_obj = false
                if show_quest_mobs then
                    is_quest_obj = is_quest_object(obj)
                    -- Spieler-Pets nicht als Quest-Objekte anzeigen
                    if is_quest_obj and is_player_pet(obj) then
                        is_quest_obj = false
                    end
                end
                
                local obj_pos = nil
                if obj.get_position then
                    local ok_pos, pos = pcall(obj.get_position, obj)
                    if ok_pos and pos and pos.x and pos.y then
                        obj_pos = pos
                    end
                end
                
                if obj_pos then
                    local distance = math.sqrt(
                        (obj_pos.x - player_pos.x) * (obj_pos.x - player_pos.x) +
                        (obj_pos.y - player_pos.y) * (obj_pos.y - player_pos.y) +
                        ((obj_pos.z or 0) - (player_pos.z or 0)) * ((obj_pos.z or 0) - (player_pos.z or 0))
                    )
                    
                    if distance <= max_distance then
                        if is_enemy then
                            table.insert(enemies, {
                                pos = obj_pos,
                                distance = distance,
                                is_quest = false
                            })
                            
                            if distance < min_enemy_distance then
                                min_enemy_distance = distance
                                enemy_found = true
                            end
                        elseif is_quest_obj then
                            table.insert(quest_mobs, {
                                pos = obj_pos,
                                distance = distance,
                                is_quest = true
                            })
                        end
                    end
                end
            end
            
            ::continue::
        end
    end
    
    -- Farbe basierend auf Entfernung zum nächsten Feind
    -- Speichere RGB-Werte direkt für späteren Zugriff
    local color_r, color_g, color_b = 0, 255, 0  -- Standard: Grün = sicher
    
    if enemy_found then
        if min_enemy_distance < 20.0 then
            -- Sehr gefährlich - rot
            color_r, color_g, color_b = 255, 0, 0
        elseif min_enemy_distance < 35.0 then
            -- Vorsichtig - orange
            color_r, color_g, color_b = 255, 150, 0
        elseif min_enemy_distance < 50.0 then
            -- Leicht gefährlich - gelb
            color_r, color_g, color_b = 255, 255, 0
        else
            -- Sicher - grün
            color_r, color_g, color_b = 0, 255, 0
        end
    end
    
    -- Zeichne Safe Zone mit cone_3d (360° = voller Kreis mit fade_power)
    if core.graphics and core.graphics.cone_3d then
        -- Zielposition: irgendwo vor dem Spieler (für Richtung)
        local target_pos = {
            x = radar_pos.x + 1,
            y = radar_pos.y,
            z = radar_pos.z
        }
        local fill_color = color.new(color_r, color_g, color_b, base_alpha)
        -- cone_3d(center, target_pos, radius, angle_degrees, color, fade_power)
        -- 360° = voller Kreis, fade_power für weichen Rand
        core.graphics.cone_3d(radar_pos, target_pos, radar_radius, 360, fill_color, 1.5)
    end
    
    -- Prüfe ob Enemy-Pfeile angezeigt werden sollen
    local show_enemy_arrows = true
    if menu_elements.radar_show_enemy_arrows and menu_elements.radar_show_enemy_arrows.get_state then
        local ok, val = pcall(menu_elements.radar_show_enemy_arrows.get_state, menu_elements.radar_show_enemy_arrows)
        if ok and val ~= nil then
            show_enemy_arrows = val
        end
    end
    
    -- Zeichne Pfeile für Feinde
    if show_enemy_arrows and #enemies > 0 and core.graphics then
        for _, enemy_data in ipairs(enemies) do
            local enemy_pos = enemy_data.pos
            local distance = enemy_data.distance
            
            -- Berechne Richtung vom Spieler zum Feind
            local dx = enemy_pos.x - player_pos.x
            local dy = enemy_pos.y - player_pos.y
            local dist_2d = math.sqrt(dx * dx + dy * dy)
            
            if dist_2d > 0.1 then
                -- Normalisiere Richtungsvektor
                dx = dx / dist_2d
                dy = dy / dist_2d
                
                -- Pfeil-Position auf Radar-Rand
                local arrow_start = {
                    x = radar_pos.x + dx * radar_radius,
                    y = radar_pos.y + dy * radar_radius,
                    z = radar_pos.z
                }
                
                -- Pfeil zeigt in Richtung des Feindes (aber begrenzt auf Radar-Radius)
                local arrow_end = {
                    x = radar_pos.x + dx * radar_radius * 1.3,
                    y = radar_pos.y + dy * radar_radius * 1.3,
                    z = radar_pos.z
                }
                
                -- Pfeil-Farbe passt sich an Safe Zone Farbe an (basierend auf nächstem Feind)
                -- Nutze die gleiche RGB-Farbe und Transparenz wie die Safe Zone
                local arrow_color = color.new(color_r, color_g, color_b, base_alpha)
                
                -- Zeichne Pfeil
                draw_arrow_3d(arrow_start, arrow_end, arrow_color, 2.0)
                
                -- Zeichne Entfernungstext am Pfeil
                if core.graphics and core.graphics.text_3d then
                    local distance_text = string.format("%.0fm", distance)
                    local text_pos = {
                        x = arrow_start.x + dx * 0.55,
                        y = arrow_start.y + dy * 0.55,
                        z = arrow_start.z + 0.2
                    }
                    
                    local text_color = color.new(
                        arrow_color.r or 255,
                        arrow_color.g or 255,
                        arrow_color.b or 255,
                        255
                    )
                    
                    pcall(core.graphics.text_3d, distance_text, text_pos, 11, text_color, true)
                end
            end
        end
    end
    
    -- Prüfe ob Quest-Mob-Pfeile angezeigt werden sollen
    local show_quest_arrows = true
    if menu_elements.radar_show_quest_arrows and menu_elements.radar_show_quest_arrows.get_state then
        local ok, val = pcall(menu_elements.radar_show_quest_arrows.get_state, menu_elements.radar_show_quest_arrows)
        if ok and val ~= nil then
            show_quest_arrows = val
        end
    end
    
    -- Zeichne Pfeile für Quest-Mobs
    if show_quest_arrows and #quest_mobs > 0 and core.graphics then
        -- Hole Quest-Farbe aus Menu
        local quest_color = color.new(255, 215, 0, 255)  -- Gold als Standard
        if menu_elements.quest_color then
            quest_color = get_safe_color(menu_elements.quest_color, quest_color)
        end
        
        for _, quest_data in ipairs(quest_mobs) do
            local quest_pos = quest_data.pos
            local distance = quest_data.distance
            
            -- Berechne Richtung vom Spieler zum Quest-Mob
            local dx = quest_pos.x - player_pos.x
            local dy = quest_pos.y - player_pos.y
            local dist_2d = math.sqrt(dx * dx + dy * dy)
            
            if dist_2d > 0.1 then
                -- Normalisiere Richtungsvektor
                dx = dx / dist_2d
                dy = dy / dist_2d
                
                -- Pfeil-Position auf Radar-Rand
                local arrow_start = {
                    x = radar_pos.x + dx * radar_radius,
                    y = radar_pos.y + dy * radar_radius,
                    z = radar_pos.z
                }
                
                -- Pfeil zeigt in Richtung des Quest-Mobs (aber begrenzt auf Radar-Radius)
                local arrow_end = {
                    x = radar_pos.x + dx * radar_radius * 1.3,
                    y = radar_pos.y + dy * radar_radius * 1.3,
                    z = radar_pos.z
                }
                
                -- Quest-Mob-Pfeil-Farbe (immer gold/gelb)
                local arrow_color = color.new(
                    quest_color.r or 255,
                    quest_color.g or 215,
                    quest_color.b or 0,
                    255
                )
                
                -- Zeichne Pfeil
                draw_arrow_3d(arrow_start, arrow_end, arrow_color, 2.0)
                
                -- Zeichne Entfernungstext am Pfeil
                if core.graphics and core.graphics.text_3d then
                    local distance_text = string.format("%.0fm", distance)
                    local text_pos = {
                        x = arrow_start.x + dx * 0.55,
                        y = arrow_start.y + dy * 0.55,
                        z = arrow_start.z + 0.2
                    }
                    
                    local text_color = color.new(
                        arrow_color.r or 255,
                        arrow_color.g or 215,
                        arrow_color.b or 0,
                        255
                    )
                    
                    pcall(core.graphics.text_3d, distance_text, text_pos, 11, text_color, true)
                end
            end
        end
    end
end

-- Death Risk Calculator (nur für aktuelles Target)
local function render_death_risk_calculator()
    if not menu_elements.death_risk_calculator or not menu_elements.death_risk_calculator.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.death_risk_calculator.get_state, menu_elements.death_risk_calculator)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    -- Hole aktuelles Target
    local current_target = nil
    if local_player.get_target then
        local ok_target, target = pcall(local_player.get_target, local_player)
        if ok_target and target then
            current_target = target
        end
    end
    
    -- Kein Target = nichts anzeigen
    if not current_target then
        return
    end
    
    -- Prüfe ob Target gültig ist
    if current_target.is_valid then
        local ok_valid, is_valid = pcall(current_target.is_valid, current_target)
        if not ok_valid or not is_valid then
            return
        end
    end
    
    -- Prüfe ob Target ein Feind ist
    local is_enemy = false
    if current_target.is_enemy_with then
        local ok_enemy, enemy = pcall(current_target.is_enemy_with, current_target, local_player)
        if ok_enemy and enemy then
            is_enemy = enemy
        end
    end
    
    if not is_enemy then
        return
    end
    
    -- Prüfe ob Target tot ist
    local is_dead = false
    if current_target.is_dead then
        local ok_dead, dead = pcall(current_target.is_dead, current_target)
        if ok_dead and dead then
            is_dead = dead
        end
    end
    
    if is_dead then
        return
    end
    
    -- Spieler HP
    local player_hp = 0
    local player_max_hp = 1
    if local_player.get_health then
        local ok_hp, hp = pcall(local_player.get_health, local_player)
        if ok_hp and hp and type(hp) == "number" then
            player_hp = hp
        end
    end
    if local_player.get_max_health then
        local ok_max, max = pcall(local_player.get_max_health, local_player)
        if ok_max and max and type(max) == "number" then
            player_max_hp = max
        end
    end
    local player_hp_ratio = player_max_hp > 0 and (player_hp / player_max_hp) or 0
    
    -- Target HP
    local target_hp = 0
    local target_max_hp = 1
    if current_target.get_health then
        local ok_hp, hp = pcall(current_target.get_health, current_target)
        if ok_hp and hp and type(hp) == "number" then
            target_hp = hp
        end
    end
    if current_target.get_max_health then
        local ok_max, max = pcall(current_target.get_max_health, current_target)
        if ok_max and max and type(max) == "number" then
            target_max_hp = max
        end
    end
    local target_hp_ratio = target_max_hp > 0 and (target_hp / target_max_hp) or 0
    
    -- Spieler Level
    local player_level = 1
    if local_player.level then
        local ok_lvl, lvl = pcall(local_player.level, local_player)
        if ok_lvl and lvl then
            player_level = lvl
        end
    end
    
    -- Target Level
    local target_level = 1
    if current_target.level then
        local ok_lvl, lvl = pcall(current_target.level, current_target)
        if ok_lvl and lvl then
            target_level = lvl
        end
    elseif current_target.get_level then
        local ok_lvl, lvl = pcall(current_target.get_level, current_target)
        if ok_lvl and lvl then
            target_level = lvl
        end
    end
    
    -- Target Name
    local target_name = "Target"
    if current_target.get_name then
        local ok_name, name = pcall(current_target.get_name, current_target)
        if ok_name and name then
            target_name = name
        end
    end
    
    -- Level-Differenz
    local level_diff = target_level - player_level
    
    -- Risiko-Berechnung basierend auf Target
    local risk = 0.0
    
    -- Spieler HP ist niedrig = höheres Risiko
    risk = risk + (1.0 - player_hp_ratio) * 40.0
    
    -- Target HP ist hoch = höheres Risiko
    risk = risk + target_hp_ratio * 20.0
    
    -- Level-Differenz
    if level_diff > 0 then
        risk = risk + level_diff * 10.0  -- Target höher = gefährlicher
    elseif level_diff < -5 then
        risk = risk - 10.0  -- Spieler viel höher = sicherer
    end
    
    -- Skull-Level (Level ??) = sehr hohes Risiko
    if target_level > player_level + 10 then
        risk = risk + 30.0
    end
    
    risk = math.max(0.0, math.min(100.0, risk))
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    local risk_text = string.format("[%s Lv%d] Death Risk: %.0f%%", target_name, target_level, risk)
    local risk_color = color.new(0, 255, 0, 255)
    if risk > 70 then
        risk_color = color.new(255, 0, 0, 255)
    elseif risk > 40 then
        risk_color = color.new(255, 150, 0, 255)
    end
    
    local text_x = screen_size.x * 0.5
    local text_y = 200
    if core.graphics and core.graphics.text_2d then
        draw_text_2d_outlined(risk_text, vec2_new(text_x, text_y), 20, risk_color, true)
    end
end

-- Combat Prediction Overlay (nur für aktuelles Target)
local function render_combat_prediction()
    if not menu_elements.combat_prediction or not menu_elements.combat_prediction.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.combat_prediction.get_state, menu_elements.combat_prediction)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    if not core or not core.object_manager then
        return
    end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then
        return
    end
    
    -- Hole aktuelles Target
    local current_target = nil
    if local_player.get_target then
        local ok_target, target = pcall(local_player.get_target, local_player)
        if ok_target and target then
            current_target = target
        end
    end
    
    -- Kein Target = nichts anzeigen
    if not current_target then
        return
    end
    
    -- Prüfe ob Target gültig ist
    if current_target.is_valid then
        local ok_valid, is_valid = pcall(current_target.is_valid, current_target)
        if not ok_valid or not is_valid then
            return
        end
    end
    
    -- Prüfe ob Target ein Feind ist
    local is_enemy = false
    if current_target.is_enemy_with then
        local ok_enemy, enemy = pcall(current_target.is_enemy_with, current_target, local_player)
        if ok_enemy and enemy then
            is_enemy = enemy
        end
    end
    
    if not is_enemy then
        return
    end
    
    -- Prüfe ob Target tot ist
    local is_dead = false
    if current_target.is_dead then
        local ok_dead, dead = pcall(current_target.is_dead, current_target)
        if ok_dead and dead then
            is_dead = dead
        end
    end
    
    if is_dead then
        return
    end
    
    -- Spieler HP
    local player_hp = 0
    local player_max_hp = 1
    if local_player.get_health then
        local ok_hp, hp = pcall(local_player.get_health, local_player)
        if ok_hp and hp and type(hp) == "number" then
            player_hp = hp
        end
    end
    if local_player.get_max_health then
        local ok_max, max = pcall(local_player.get_max_health, local_player)
        if ok_max and max and type(max) == "number" then
            player_max_hp = max
        end
    end
    local player_hp_ratio = player_max_hp > 0 and (player_hp / player_max_hp) or 0
    
    -- Target HP
    local target_hp = 0
    local target_max_hp = 1
    if current_target.get_health then
        local ok_hp, hp = pcall(current_target.get_health, current_target)
        if ok_hp and hp and type(hp) == "number" then
            target_hp = hp
        end
    end
    if current_target.get_max_health then
        local ok_max, max = pcall(current_target.get_max_health, current_target)
        if ok_max and max and type(max) == "number" then
            target_max_hp = max
        end
    end
    local target_hp_ratio = target_max_hp > 0 and (target_hp / target_max_hp) or 0
    
    -- Spieler Level
    local player_level = 1
    if local_player.level then
        local ok_lvl, lvl = pcall(local_player.level, local_player)
        if ok_lvl and lvl then
            player_level = lvl
        end
    end
    
    -- Target Level
    local target_level = 1
    if current_target.level then
        local ok_lvl, lvl = pcall(current_target.level, current_target)
        if ok_lvl and lvl then
            target_level = lvl
        end
    elseif current_target.get_level then
        local ok_lvl, lvl = pcall(current_target.get_level, current_target)
        if ok_lvl and lvl then
            target_level = lvl
        end
    end
    
    -- Target Name
    local target_name = "Target"
    if current_target.get_name then
        local ok_name, name = pcall(current_target.get_name, current_target)
        if ok_name and name then
            target_name = name
        end
    end
    
    -- Level-Differenz
    local level_diff = target_level - player_level
    
    -- Gewinnchance-Berechnung basierend auf Target
    local win_chance = 100.0
    
    -- Spieler HP ist niedrig = niedrigere Gewinnchance
    win_chance = win_chance - (1.0 - player_hp_ratio) * 35.0
    
    -- Target HP ist hoch = niedrigere Gewinnchance
    win_chance = win_chance - target_hp_ratio * 15.0
    
    -- Level-Differenz
    if level_diff > 0 then
        win_chance = win_chance - level_diff * 12.0  -- Target höher = schwieriger
    elseif level_diff < 0 then
        win_chance = win_chance + math.abs(level_diff) * 5.0  -- Spieler höher = leichter
    end
    
    -- Skull-Level (Level ??) = sehr niedrige Gewinnchance
    if target_level > player_level + 10 then
        win_chance = win_chance - 40.0
    end
    
    -- Bonus wenn Target schon angeschlagen
    if target_hp_ratio < 0.5 then
        win_chance = win_chance + 15.0
    end
    
    win_chance = math.max(0.0, math.min(100.0, win_chance))
    
    local screen_size = core.graphics.get_screen_size()
    if not screen_size then
        return
    end
    
    local chance_text = string.format("[%s Lv%d] Win Chance: %.0f%%", target_name, target_level, win_chance)
    local chance_color = color.new(0, 255, 0, 255)
    local recommendation = "FIGHT!"
    
    if win_chance < 30 then
        chance_color = color.new(255, 0, 0, 255)
        recommendation = "RUN!!"
    elseif win_chance < 60 then
        chance_color = color.new(255, 150, 0, 255)
        recommendation = "Careful!"
    end
    
    local text_x = screen_size.x * 0.5
    local text_y = 230
    if core.graphics and core.graphics.text_2d then
        draw_text_2d_outlined(chance_text, vec2_new(text_x, text_y), 20, chance_color, true)
        draw_text_2d_outlined(recommendation, vec2_new(text_x, text_y + 25), 18, chance_color, true)
    end
end

-- ============================================================================
-- CUSTOM NAMEPLATES - Ersetzt/Ergänzt WoW Nameplates
-- Zeigt HP-Bar, Cast-Bar, Name und Level über allen Gegnern in Range
-- ============================================================================
local function render_custom_nameplates()
    -- Check ob Feature aktiviert
    if not menu_elements.custom_nameplates or not menu_elements.custom_nameplates.get_state then
        return
    end
    local enabled = false
    local ok, val = pcall(menu_elements.custom_nameplates.get_state, menu_elements.custom_nameplates)
    if ok and val ~= nil then
        enabled = val
    end
    if not enabled then
        return
    end
    
    -- Basis-Checks
    if not core or not core.object_manager or not core.graphics then
        return
    end
    
    local local_player = cached_local_player or core.object_manager.get_local_player()
    if not local_player then return end
    
    local player_pos = cached_player_pos
    if not player_pos then
        if local_player.get_position then
            local ok_pos, pos = pcall(local_player.get_position, local_player)
            if ok_pos and pos then player_pos = pos end
        end
    end
    if not player_pos then return end
    
    -- Spieler-Target für Highlight
    local player_target = nil
    local player_target_guid = nil
    if local_player.get_target then
        local ok_t, t = pcall(local_player.get_target, local_player)
        if ok_t and t then
            player_target = t
            if t.get_guid then
                local ok_g, g = pcall(t.get_guid, t)
                if ok_g then player_target_guid = g end
            end
        end
    end
    
    -- Hole Einstellungen
    local np_max_distance = 40.0
    if menu_elements.nameplate_max_distance and menu_elements.nameplate_max_distance.get then
        local ok_d, d = pcall(menu_elements.nameplate_max_distance.get, menu_elements.nameplate_max_distance)
        if ok_d and d then np_max_distance = d end
    end
    
    local np_scale = 1.0
    if menu_elements.nameplate_scale and menu_elements.nameplate_scale.get then
        local ok_s, s = pcall(menu_elements.nameplate_scale.get, menu_elements.nameplate_scale)
        if ok_s and s then np_scale = s / 100.0 end
    end
    
    local np_width = 120.0
    if menu_elements.nameplate_width and menu_elements.nameplate_width.get then
        local ok_w, w = pcall(menu_elements.nameplate_width.get, menu_elements.nameplate_width)
        if ok_w and w then np_width = w end
    end
    np_width = np_width * np_scale
    
    local np_y_offset = 2.2
    if menu_elements.nameplate_y_offset and menu_elements.nameplate_y_offset.get then
        local ok_o, o = pcall(menu_elements.nameplate_y_offset.get, menu_elements.nameplate_y_offset)
        if ok_o and o then np_y_offset = o end
    end
    
    local show_cast = true
    if menu_elements.nameplate_show_cast and menu_elements.nameplate_show_cast.get_state then
        local ok_c, c = pcall(menu_elements.nameplate_show_cast.get_state, menu_elements.nameplate_show_cast)
        if ok_c and c ~= nil then show_cast = c end
    end
    
    local show_name = true
    if menu_elements.nameplate_show_name and menu_elements.nameplate_show_name.get_state then
        local ok_n, n = pcall(menu_elements.nameplate_show_name.get_state, menu_elements.nameplate_show_name)
        if ok_n and n ~= nil then show_name = n end
    end
    
    local show_level = true
    if menu_elements.nameplate_show_level and menu_elements.nameplate_show_level.get_state then
        local ok_l, l = pcall(menu_elements.nameplate_show_level.get_state, menu_elements.nameplate_show_level)
        if ok_l and l ~= nil then show_level = l end
    end
    
    local show_health_text = true
    if menu_elements.nameplate_show_health_text and menu_elements.nameplate_show_health_text.get_state then
        local ok_h, h = pcall(menu_elements.nameplate_show_health_text.get_state, menu_elements.nameplate_show_health_text)
        if ok_h and h ~= nil then show_health_text = h end
    end
    
    local show_targeting_glow = true
    if menu_elements.nameplate_targeting_glow and menu_elements.nameplate_targeting_glow.get_state then
        local ok_tg, tg = pcall(menu_elements.nameplate_targeting_glow.get_state, menu_elements.nameplate_targeting_glow)
        if ok_tg and tg ~= nil then show_targeting_glow = tg end
    end
    
    local show_q_mobs = true
    if menu_elements.show_quest_mobs and menu_elements.show_quest_mobs.get_state then
        local ok_qm, qm = pcall(menu_elements.show_quest_mobs.get_state, menu_elements.show_quest_mobs)
        if ok_qm and qm ~= nil then show_q_mobs = qm end
    end
    
    local show_q_symbol = true
    if menu_elements.show_quest_symbol and menu_elements.show_quest_symbol.get_state then
        local ok_qs, qs = pcall(menu_elements.show_quest_symbol.get_state, menu_elements.show_quest_symbol)
        if ok_qs and qs ~= nil then show_q_symbol = qs end
    end
    
    -- Farben holen
    local hp_color = get_live_color(menu_elements.nameplate_hp_color, color.new(50, 205, 50, 255))
    local cast_color = get_live_color(menu_elements.nameplate_cast_color, color.new(255, 200, 50, 255))
    local bg_color = get_live_color(menu_elements.nameplate_bg_color, color.new(20, 20, 25, 220))
    local border_color = get_live_color(menu_elements.nameplate_border_color, color.new(60, 60, 70, 255))
    
    -- Dimensionen
    local bar_height = 12 * np_scale
    local cast_height = 8 * np_scale
    local padding = 3 * np_scale
    local rounding = 4 * np_scale
    local font_size_name = 11 * np_scale
    local font_size_small = 9 * np_scale
    
    -- Nameplate Stacking aktiviert?
    local enable_stacking = true
    if menu_elements.nameplate_stacking and menu_elements.nameplate_stacking.get_state then
        local ok_st, st = pcall(menu_elements.nameplate_stacking.get_state, menu_elements.nameplate_stacking)
        if ok_st and st ~= nil then enable_stacking = st end
    end
    
    -- Alle Nameplates sammeln (Phase 1: Daten sammeln)
    local nameplates = {}
    
    -- Alle Objekte durchgehen
    local objects = core.object_manager.get_all_objects()
    if not objects then return end
    
    for _, obj in __object_safety.live_ipairs(objects) do
        repeat
            -- Validierung
            if not obj then break end
            
            local is_valid = true
            if obj.is_valid then
                local ok_v, v = pcall(obj.is_valid, obj)
                if ok_v then is_valid = v end
            end
            if not is_valid then break end
            
            -- Muss eine Unit sein (keine Items, GameObjects etc)
            local is_unit = false
            if obj.is_unit then
                local ok_u, u = pcall(obj.is_unit, obj)
                if ok_u and u then is_unit = true end
            end
            if not is_unit then break end
            
            -- Ist es ein Gegner oder ein Quest-Objekt?
            local is_enemy = false
            if obj.is_enemy_with then
                local ok_e, e = pcall(obj.is_enemy_with, obj, local_player)
                if ok_e and e then is_enemy = true end
            end
            
            -- Quest Info sammeln (jetzt früher, um Neutralen Quest-Mobs Nameplates zu ermöglichen)
            local is_quest_obj = false
            local quest_ids = nil
            if show_q_mobs then
                is_quest_obj = is_quest_object(obj)
                if is_quest_obj then
                    quest_ids = get_quest_ids_for_object(obj)
                end
            end
            
            -- Wenn kein Feind UND kein Quest-Objekt: Überspringen
            if not is_enemy and not is_quest_obj then break end
            
            -- Spieler-Pets nicht anzeigen
            if is_player_pet and is_player_pet(obj) then break end
            
            -- Ist es tot?
            local is_dead = false
            if obj.is_dead then
                local ok_d, d = pcall(obj.is_dead, obj)
                if ok_d and d then is_dead = true end
            end
            if is_dead then break end
            
            -- Position holen
            local obj_pos = nil
            if obj.get_position then
                local ok_p, p = pcall(obj.get_position, obj)
                if ok_p and p and p.x and p.y then obj_pos = p end
            end
            if not obj_pos then break end
            
            -- Distanz prüfen
            local dx = obj_pos.x - player_pos.x
            local dy = obj_pos.y - player_pos.y
            local dz = (obj_pos.z or 0) - (player_pos.z or 0)
            local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
            
            if distance > np_max_distance then break end
            
            -- Höhe des Objekts ermitteln
            local obj_height = 2.0
            if obj.get_height then
                local ok_h, h = pcall(obj.get_height, obj)
                if ok_h and h and h > 0 then obj_height = h end
            end
            
            -- World-Position über dem Kopf
            local world_pos = {
                x = obj_pos.x,
                y = obj_pos.y,
                z = (obj_pos.z or 0) + obj_height + np_y_offset
            }
            
            -- World to Screen
            local screen_pos = nil
            if core.graphics.w2s then
                local ok_w, w = pcall(core.graphics.w2s, world_pos)
                if ok_w and w then screen_pos = w end
            end
            if not screen_pos then break end
            
            -- Zusätzlicher Y-Offset um Nameplates höher zu positionieren (kleinere Y-Werte = höher auf dem Bildschirm)
            -- Dies betrifft auch alle darüber liegenden Elemente (Icons, Text, etc.)
            -- Standard: -25 Pixel (etwas höher), kann über np_y_offset angepasst werden
            local additional_y_offset = -25 * np_scale  -- Skaliert mit Nameplate-Scale
            screen_pos.y = screen_pos.y + additional_y_offset
            
            -- Daten sammeln
            local unit_name = "Enemy"
            if obj.get_name then
                local ok_n, n = pcall(obj.get_name, obj)
                if ok_n and n then unit_name = n end
            end
            
            local unit_level = 0
            if obj.get_level then
                local ok_l, l = pcall(obj.get_level, obj)
                if ok_l and l then unit_level = l end
            elseif obj.level then
                local ok_l, l = pcall(obj.level, obj)
                if ok_l and l then unit_level = l end
            end
            
            local current_hp, max_hp = 1, 1
            if obj.get_health then
                local ok_h, h = pcall(obj.get_health, obj)
                if ok_h and h then current_hp = h end
            end
            if obj.get_max_health then
                local ok_m, m = pcall(obj.get_max_health, obj)
                if ok_m and m and m > 0 then max_hp = m end
            end
            local hp_ratio = math.max(0, math.min(1, current_hp / max_hp))
            
            -- Classification (Elite/Rare/Boss)
            local classification = 0
            if obj.get_classification then
                local ok_c, c = pcall(obj.get_classification, obj)
                if ok_c and c then classification = c end
            end
            
            -- Quest Info wurde bereits oben gesammelt
            
            -- Targeting: Zielt dieser Mob auf den Spieler?
            local is_targeting_player = false
            if obj.get_target then
                local ok_t, t = pcall(obj.get_target, obj)
                if ok_t and t then
                    if (__object_safety.same(t,local_player)) then
                        is_targeting_player = true
                    elseif t.get_guid and local_player.get_guid then
                        local ok_g1, g1 = pcall(t.get_guid, t)
                        local ok_g2, g2 = pcall(local_player.get_guid, local_player)
                        if ok_g1 and ok_g2 and g1 == g2 then
                            is_targeting_player = true
                        end
                    end
                end
            end
            
            -- Ist dieses Objekt das Target des Spielers?
            local is_player_target = false
            if player_target then
                if (__object_safety.same(obj,player_target)) then
                    is_player_target = true
                elseif player_target_guid and obj.get_guid then
                    local ok_g, g = pcall(obj.get_guid, obj)
                    if ok_g and g == player_target_guid then
                        is_player_target = true
                    end
                end
            end
            
            -- Casting Info
            local is_casting = false
            local cast_spell_name = nil
            local cast_ratio = 0
            if obj.is_casting_spell then
                local ok_c, c = pcall(obj.is_casting_spell, obj)
                if ok_c and c then is_casting = true end
            end
            if is_casting then
                if obj.get_active_spell_id then
                    local ok_id, spell_id = pcall(obj.get_active_spell_id, obj)
                    if ok_id and spell_id and spell_id > 0 then
                        if core.spell_book and core.spell_book.get_spell_name then
                            local ok_n, n = pcall(core.spell_book.get_spell_name, spell_id)
                            if ok_n and n then cast_spell_name = n end
                        end
                    end
                end
                -- Cast Progress berechnen
                local cast_start, cast_end = 0, 0
                if obj.get_active_spell_cast_start_time then
                    local ok_s, s = pcall(obj.get_active_spell_cast_start_time, obj)
                    if ok_s and s then cast_start = s end
                end
                if obj.get_active_spell_cast_end_time then
                    local ok_e, e = pcall(obj.get_active_spell_cast_end_time, obj)
                    if ok_e and e then cast_end = e end
                end
                if cast_end > cast_start then
                    local now = core.game_time and core.game_time() or 0
                    cast_ratio = math.max(0, math.min(1, (now - cast_start) / (cast_end - cast_start)))
                end
            end
            
            -- Channeling Check
            if not is_casting and obj.is_channelling_spell then
                local ok_ch, ch = pcall(obj.is_channelling_spell, obj)
                if ok_ch and ch then
                    is_casting = true
                    if obj.get_active_channel_spell_id then
                        local ok_id, spell_id = pcall(obj.get_active_channel_spell_id, obj)
                        if ok_id and spell_id and spell_id > 0 then
                            if core.spell_book and core.spell_book.get_spell_name then
                                local ok_n, n = pcall(core.spell_book.get_spell_name, spell_id)
                                if ok_n and n then cast_spell_name = n end
                            end
                        end
                    end
                    local ch_start, ch_end = 0, 0
                    if obj.get_active_channel_cast_start_time then
                        local ok_s, s = pcall(obj.get_active_channel_cast_start_time, obj)
                        if ok_s and s then ch_start = s end
                    end
                    if obj.get_active_channel_cast_end_time then
                        local ok_e, e = pcall(obj.get_active_channel_cast_end_time, obj)
                        if ok_e and e then ch_end = e end
                    end
                    if ch_end > ch_start then
                        local now = core.game_time and core.game_time() or 0
                        cast_ratio = math.max(0, math.min(1, (now - ch_start) / (ch_end - ch_start)))
                    end
                end
            end
            
            -- Power/Mana-Daten sammeln (wie bei normalen Nameplates)
            local has_power = false
            local power_ratio = 0
            local power_type = 0  -- Default: Mana
            
            -- Bestimme Power-Type basierend auf Klasse
            local enemy_class = 0
            if obj.get_class then
                local ok_class, cls = pcall(obj.get_class, obj)
                if ok_class and cls and type(cls) == "number" then
                    enemy_class = cls
                end
            end
            
            -- Setze erwarteten Power-Type basierend auf Klasse
            local expected_power_type = 0  -- Default: Mana
            if enemy_class == 1 then
                expected_power_type = 1  -- Warrior: Rage
            elseif enemy_class == 4 then
                expected_power_type = 3  -- Rogue: Energy
            elseif enemy_class == 6 then
                expected_power_type = 6  -- Death Knight: Runic Power
            elseif enemy_class == 3 then
                expected_power_type = 2  -- Hunter: Focus
            elseif enemy_class == 10 then
                expected_power_type = 3  -- Monk: Energy
            elseif enemy_class == 12 then
                expected_power_type = 17  -- Demon Hunter: Fury
            end
            
            -- Prüfe alle Power-Types und finde den mit dem höchsten Max-Wert
            local best_power_type = expected_power_type
            local best_max_power = 0
            
            if obj.get_max_power then
                local power_types_to_check = {0, 1, 2, 3, 6, 17}  -- Mana, Rage, Focus, Energy, Runic Power, Fury
                
                for _, pt in ipairs(power_types_to_check) do
                    local ok_mp, mp = pcall(obj.get_max_power, obj, pt)
                    if ok_mp and mp and type(mp) == "number" and mp > best_max_power then
                        best_max_power = mp
                        best_power_type = pt
                    end
                end
                
                -- Spezielle Logik für Druiden
                if enemy_class == 11 then
                    local mana_max = 0
                    local rage_max = 0
                    local energy_max = 0
                    local ok_mm, mm = pcall(obj.get_max_power, obj, 0)
                    if ok_mm and mm and type(mm) == "number" then mana_max = mm end
                    local ok_rm, rm = pcall(obj.get_max_power, obj, 1)
                    if ok_rm and rm and type(rm) == "number" then rage_max = rm end
                    local ok_em, em = pcall(obj.get_max_power, obj, 3)
                    if ok_em and em and type(em) == "number" then energy_max = em end
                    
                    if energy_max > mana_max and energy_max > rage_max then
                        best_power_type = 3  -- Energy (Cat Form)
                        best_max_power = energy_max
                    elseif rage_max > mana_max and rage_max > energy_max then
                        best_power_type = 1  -- Rage (Bear Form)
                        best_max_power = rage_max
                    elseif mana_max > 0 then
                        best_power_type = 0  -- Mana (Caster/Heal Form)
                        best_max_power = mana_max
                    end
                end
            end
            
            power_type = best_power_type
            
            -- Hole Power-Werte basierend auf erkanntem Power-Type
            if obj.get_power and obj.get_max_power then
                local ok_p, current_power = pcall(obj.get_power, obj, power_type)
                local ok_mp, max_power = pcall(obj.get_max_power, obj, power_type)
                if ok_p and ok_mp and current_power and max_power and max_power > 0 then
                    power_ratio = current_power / max_power
                    has_power = true
                end
            end
            
            -- Gesamt-Höhe berechnen (Container-Höhe ohne Name-Text)
            local total_height = bar_height + padding * 2
            if has_power and power_ratio > 0 then
                total_height = total_height + bar_height + padding  -- Power-Leiste hinzufügen
            end
            if show_cast and is_casting then
                total_height = total_height + cast_height + padding
            end
            -- Name wird über dem Container gerendert, aber benötigt Platz beim Stacking
            local name_space = 0
            if (show_name or show_level) then
                name_space = font_size_name + 4
            end
            
            -- Alpha basierend auf Distanz
            local alpha_mult = math.max(0.4, 1.0 - (distance / np_max_distance) * 0.6)
            
            -- Nameplate-Daten speichern
            table.insert(nameplates, {
                obj = obj,
                screen_pos = screen_pos,
                distance = distance,
                unit_name = unit_name,
                unit_level = unit_level,
                hp_ratio = hp_ratio,
                classification = classification,
                is_targeting_player = is_targeting_player,
                is_player_target = is_player_target,
                is_casting = is_casting,
                cast_spell_name = cast_spell_name,
                cast_ratio = cast_ratio,
                has_power = has_power,
                power_ratio = power_ratio,
                power_type = power_type,
                total_height = total_height,
                name_space = name_space,
                alpha_mult = alpha_mult,
                is_quest_obj = is_quest_obj,
                quest_ids = quest_ids
            })
            
        until true
    end
    
    -- Phase 2: Nameplates nach Y-Position sortieren (von unten nach oben, höhere Y-Werte = weiter unten)
    table.sort(nameplates, function(a, b)
        return a.screen_pos.y > b.screen_pos.y
    end)
    
    -- Phase 3: Stacking-Logik - Überlappungen verhindern (nur nach oben stacken)
    if enable_stacking and #nameplates > 1 then
        local min_spacing = 2  -- Minimale Pixel-Distanz zwischen Nameplates
        local stack_spacing = 28 * np_scale  -- Standard-Abstand zwischen gestapelten Nameplates
        
        for i = 2, #nameplates do
            local current = nameplates[i]
            local position_changed = true
            
            -- Iteriere solange bis keine weiteren Anpassungen nötig sind
            -- (wichtig, da sich Positionen beim Stacking ändern können)
            while position_changed do
                position_changed = false
                
                -- Prüfe gegen alle vorherigen Nameplates
                for j = 1, i - 1 do
                    local previous = nameplates[j]
                    
                    -- X-Achse Überlappung prüfen (Horizontal)
                    local current_left = current.screen_pos.x - np_width / 2
                    local current_right = current.screen_pos.x + np_width / 2
                    local prev_left = previous.screen_pos.x - np_width / 2
                    local prev_right = previous.screen_pos.x + np_width / 2
                    
                    local x_overlap = not (current_right < prev_left or current_left > prev_right)
                    
                    if x_overlap then
                        -- Y-Achse Abstand prüfen (Vertikal)
                        -- Berücksichtige auch den Name-Space (Text über dem Nameplate)
                        local current_top = current.screen_pos.y - current.name_space
                        local current_bottom = current.screen_pos.y + current.total_height
                        local prev_top = previous.screen_pos.y - previous.name_space
                        local prev_bottom = previous.screen_pos.y + previous.total_height
                        
                        -- Prüfe ob aktuelles Nameplate zu nah am vorherigen ist (nach unten)
                        local spacing_down = current_top - prev_bottom
                        
                        -- Nur nach oben stacken (nie nach unten)
                        if spacing_down < stack_spacing then
                            -- Verschiebe aktuelles Nameplate nach oben (kleinere Y-Werte = höher auf dem Bildschirm)
                            -- Die neue Container-Position: prev_top - stack_spacing - current.total_height
                            -- Damit ist current_bottom = prev_top - stack_spacing
                            local new_container_y = prev_top - stack_spacing - current.total_height
                            -- Nur nach oben verschieben, nie nach unten
                            if new_container_y < current.screen_pos.y then
                                current.screen_pos.y = new_container_y
                                position_changed = true
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Phase 4: Rendering aller Nameplates mit finalen Positionen
    for _, np in ipairs(nameplates) do
        -- ========== RENDERING ==========
        local center_x = np.screen_pos.x
        local top_y = np.screen_pos.y
            
        -- Positionen
        local bg_x = center_x - np_width / 2
        local bg_y = top_y
        local hp_x = bg_x + padding
        local hp_y = bg_y + padding
        local hp_bar_width = np_width - padding * 2
        
        -- Background
        local r_bg, g_bg, b_bg, a_bg = get_color_rgba(bg_color)
        local final_bg = color.new(r_bg, g_bg, b_bg, math.floor((a_bg or 220) * np.alpha_mult))
        pcall(core.graphics.rect_2d_filled, vec2_new(bg_x, bg_y), np_width, np.total_height, final_bg, rounding)
        
        -- Border
        local r_bd, g_bd, b_bd, a_bd = get_color_rgba(border_color)
        local final_border = color.new(r_bd, g_bd, b_bd, math.floor((a_bd or 255) * np.alpha_mult))
        
        -- Targeting Glow (roter Rand wenn Mob auf Spieler zielt)
        if show_targeting_glow and np.is_targeting_player then
            local glow_color = color.new(255, 50, 50, math.floor(200 * np.alpha_mult))
            pcall(core.graphics.rect_2d, vec2_new(bg_x - 2, bg_y - 2), np_width + 4, np.total_height + 4, glow_color, 2.5, rounding + 2)
        end
        
        -- Player Target Highlight (weißer Rand wenn Spieler diesen Mob targeted)
        if np.is_player_target then
            local target_border = color.new(255, 255, 255, math.floor(255 * np.alpha_mult))
            pcall(core.graphics.rect_2d, vec2_new(bg_x, bg_y), np_width, np.total_height, target_border, 2.0, rounding)
        else
            pcall(core.graphics.rect_2d, vec2_new(bg_x, bg_y), np_width, np.total_height, final_border, 1.0, rounding)
        end
        
        -- HP Bar Background (dunkel)
        local hp_bg = color.new(30, 30, 30, math.floor(200 * np.alpha_mult))
        pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, hp_y), hp_bar_width, bar_height, hp_bg, rounding - 2)
        
        -- HP Bar Fill
        local hp_fill_width = hp_bar_width * np.hp_ratio
        if hp_fill_width > 0 then
            -- Farbe basierend auf HP
            local r_hp, g_hp, b_hp, a_hp = get_color_rgba(hp_color)
            local final_hp_color
            if np.hp_ratio > 0.6 then
                final_hp_color = color.new(r_hp, g_hp, b_hp, math.floor((a_hp or 255) * np.alpha_mult))
            elseif np.hp_ratio > 0.3 then
                final_hp_color = color.new(255, 200, 50, math.floor(255 * np.alpha_mult))
            else
                final_hp_color = color.new(255, 60, 60, math.floor(255 * np.alpha_mult))
            end
            
            -- Elite/Rare/Boss Farbe
            if np.classification == 3 then  -- Boss
                final_hp_color = color.new(255, 0, 0, math.floor(255 * np.alpha_mult))
            elseif np.classification == 2 or np.classification == 4 then  -- Rare/RareElite
                final_hp_color = color.new(255, 215, 0, math.floor(255 * np.alpha_mult))
            elseif np.classification == 1 then  -- Elite
                final_hp_color = color.new(255, 165, 0, math.floor(255 * np.alpha_mult))
            end
            
            pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, hp_y), hp_fill_width, bar_height, final_hp_color, rounding - 2)
        end
        
        -- Power/Mana Bar (unter HP Bar)
        if np.has_power and np.power_ratio > 0 then
            local power_y = hp_y + bar_height + padding
            
            -- Power Bar Background
            local power_bg = color.new(20, 20, 25, math.floor(200 * np.alpha_mult))
            pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, power_y), hp_bar_width, bar_height, power_bg, rounding - 2)
            
            -- Power Bar Fill
            local power_fill_width = hp_bar_width * np.power_ratio
            if power_fill_width > 0 then
                -- Farbe basierend auf Power-Type
                local power_color
                if np.power_type == 0 then
                    power_color = color.new(100, 150, 255, math.floor(255 * np.alpha_mult))  -- Mana: Blau
                elseif np.power_type == 1 then
                    power_color = color.new(255, 50, 50, math.floor(255 * np.alpha_mult))  -- Rage: Rot
                elseif np.power_type == 2 then
                    power_color = color.new(255, 180, 80, math.floor(255 * np.alpha_mult))  -- Focus: Orange
                elseif np.power_type == 3 then
                    power_color = color.new(255, 255, 100, math.floor(255 * np.alpha_mult))  -- Energy: Gelb
                elseif np.power_type == 6 then
                    power_color = color.new(0, 200, 255, math.floor(255 * np.alpha_mult))  -- Runic Power: Cyan
                elseif np.power_type == 17 then
                    power_color = color.new(200, 100, 255, math.floor(255 * np.alpha_mult))  -- Fury: Lila
                else
                    power_color = color.new(100, 150, 255, math.floor(255 * np.alpha_mult))  -- Default: Blau
                end
                
                pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, power_y), power_fill_width, bar_height, power_color, rounding - 2)
            end
            
            -- Power Bar Border
            local power_border = color.new(60, 60, 70, math.floor(180 * np.alpha_mult))
            pcall(core.graphics.rect_2d, vec2_new(hp_x, power_y), hp_bar_width, bar_height, power_border, 1.0, rounding - 2)
        end
        
        -- HP Text (Prozent)
        if show_health_text then
            local hp_text = string.format("%.0f%%", np.hp_ratio * 100)
            local text_col = color.new(255, 255, 255, math.floor(255 * np.alpha_mult))
            local text_outline = color.new(0, 0, 0, math.floor(255 * np.alpha_mult))
            local text_y = hp_y + bar_height/2 - font_size_small/2
            
            -- Outline
            local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
            for _, off in ipairs(offsets) do
                pcall(core.graphics.text_2d, hp_text, vec2_new(center_x + off[1], text_y + off[2]), font_size_small, text_outline, true)
            end
            pcall(core.graphics.text_2d, hp_text, vec2_new(center_x, text_y), font_size_small, text_col, true)
        end
        
        -- Cast Bar (unter HP Bar oder Power Bar)
        if show_cast and np.is_casting then
            local cast_y = hp_y + bar_height + padding
            if np.has_power and np.power_ratio > 0 then
                cast_y = cast_y + bar_height + padding  -- Unter Power-Leiste
            end
            
            -- Cast Bar Background
            local cast_bg = color.new(40, 40, 40, math.floor(200 * np.alpha_mult))
            pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, cast_y), hp_bar_width, cast_height, cast_bg, rounding - 2)
            
            -- Cast Bar Fill
            local cast_fill_width = hp_bar_width * np.cast_ratio
            if cast_fill_width > 0 then
                local r_c, g_c, b_c, a_c = get_color_rgba(cast_color)
                local final_cast = color.new(r_c, g_c, b_c, math.floor((a_c or 255) * np.alpha_mult))
                pcall(core.graphics.rect_2d_filled, vec2_new(hp_x, cast_y), cast_fill_width, cast_height, final_cast, rounding - 2)
            end
            
            -- Cast Spell Name (IN der Cast Bar, zentriert)
            if np.cast_spell_name then
                local cast_percent = math.floor(np.cast_ratio * 100)
                local cast_text = string.format("%s (%.0f%%)", np.cast_spell_name, cast_percent)
                local text_col = color.new(255, 255, 255, math.floor(255 * np.alpha_mult))
                local text_outline = color.new(0, 0, 0, math.floor(255 * np.alpha_mult))
                local text_y = cast_y + cast_height/2 - font_size_small/2
                
                -- Outline (wie bei HP Text)
                local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
                for _, off in ipairs(offsets) do
                    pcall(core.graphics.text_2d, cast_text, vec2_new(center_x + off[1], text_y + off[2]), font_size_small, text_outline, true)
                end
                pcall(core.graphics.text_2d, cast_text, vec2_new(center_x, text_y), font_size_small, text_col, true)
            end
        end
        
        -- Name und Level (über dem Nameplate)
        local name_y = bg_y - font_size_name - 2
        
        if show_name or show_level then
            local display_text = ""
            if show_level and np.unit_level > 0 then
                display_text = "[" .. np.unit_level .. "] "
            end
            if show_name then
                display_text = display_text .. np.unit_name
            end
            
            -- Farbe basierend auf Classification
            local name_color = color.new(255, 255, 255, math.floor(255 * np.alpha_mult))
            if np.classification == 3 then  -- Boss
                name_color = color.new(255, 80, 80, math.floor(255 * np.alpha_mult))
            elseif np.classification == 2 or np.classification == 4 then  -- Rare
                name_color = color.new(255, 215, 0, math.floor(255 * np.alpha_mult))
            elseif np.classification == 1 then  -- Elite
                name_color = color.new(255, 165, 0, math.floor(255 * np.alpha_mult))
            end
            
            -- Outline
            local outline = color.new(0, 0, 0, math.floor(255 * np.alpha_mult))
            local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
            for _, off in ipairs(offsets) do
                pcall(core.graphics.text_2d, display_text, vec2_new(center_x + off[1], name_y + off[2]), font_size_name, outline, true)
            end
            pcall(core.graphics.text_2d, display_text, vec2_new(center_x, name_y), font_size_name, name_color, true)
        end
        
        -- Quest-Symbol und Text über dem Namen (Custom Nameplate)
        if show_q_symbol and np.is_quest_obj then
            local q_color = get_safe_color(menu_elements.quest_color, color.new(255, 215, 0, 255))
            local q_alpha = math.floor(255 * np.alpha_mult)
            local qr, qg, qb = safe_get_rgb(q_color, 255, 215, 0)
            local final_q_color = color.new(qr, qg, qb, q_alpha)
            local q_outline = color.new(0, 0, 0, q_alpha)
            
            -- Font Größe etwas kleiner als Name
            local q_font_size = font_size_name * 0.9
            local q_y = (show_name or show_level) and (name_y - q_font_size - 4) or (bg_y - q_font_size - 4)
            
            local q_symbol_text = "☠"
            local q_info_text = "(QUEST)"
            if np.quest_ids and #np.quest_ids > 0 then
                q_info_text = string.format("(QUEST %s)", table.concat(np.quest_ids, ","))
            end
            
            local q_full_text = q_symbol_text .. " " .. q_info_text
            
            -- Outline
            local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
            for _, off in ipairs(offsets) do
                pcall(core.graphics.text_2d, q_full_text, vec2_new(center_x + off[1], q_y + off[2]), q_font_size, q_outline, true)
            end
            pcall(core.graphics.text_2d, q_full_text, vec2_new(center_x, q_y), q_font_size, final_q_color, true)
            
            -- name_space anpassen falls Stacking aktiv? (Bereits in Phase 1 berechnet, aber hier ignorieren wir es für jetzt)
        end
    end
end

-- State für Settings Key (um doppelte Aktivierung zu verhindern)
local settings_key_was_pressed = false

local function cache_player_position()
    cached_local_player = nil
    cached_player_pos = nil
    
    if not core or not core.object_manager then return end
    
    local local_player = core.object_manager.get_local_player()
    if not local_player then return end
    
    local ok, pos = pcall(local_player.get_position, local_player)
    if ok and pos and pos.x and pos.y then
        cached_player_pos = pos
        cached_local_player = local_player
    end
end

-- Render only Target Icon (for Dungeon Mode)
local function render_target_icon_only()
    -- Verwende cached local_player und player_pos
    if not cached_local_player or not cached_player_pos then
        return
    end
    local local_player = cached_local_player
    local player_pos = cached_player_pos
    
    -- Hole aktuelles Target
    local current_target = nil
    local player_target_guid = nil
    if local_player.get_target then
        local ok_target, target = pcall(local_player.get_target, local_player)
        if ok_target and target then
            current_target = target
            -- Hole GUID für Vergleich
            if target.get_guid then
                local ok_guid, guid = pcall(target.get_guid, target)
                if ok_guid and guid then
                    player_target_guid = guid
                end
            end
        end
    end
    
    if not current_target then
        return
    end
    
    -- Prüfe ob Target gültig ist
    if current_target.is_valid then
        local ok_valid, is_valid = pcall(current_target.is_valid, current_target)
        if not ok_valid or not is_valid then
            return
        end
    end
    
    -- Hole Position des Targets
    local target_pos = nil
    if current_target.get_position then
        local ok_pos, pos = pcall(current_target.get_position, current_target)
        if ok_pos and pos then
            target_pos = pos
        end
    end
    
    if not target_pos then
        return
    end
    
    -- Im Dungeon Mode IMMER Target Icon/Arrow anzeigen (unabhängig von Checkbox-Einstellungen)
    -- World-Position für den Pfeil/Icon (über dem Kopf) - höher positioniert
    local arrow_world_pos = { x = target_pos.x, y = target_pos.y, z = target_pos.z + 4.5 }
    
    -- Konvertiere 3D-Position zu 2D-Bildschirmkoordinaten (inline, wie in render_enemy_esp)
    local arrow_screen = nil
    if core and core.graphics then
        if core.graphics.w2s then
            local ok, sp = pcall(core.graphics.w2s, arrow_world_pos)
            if ok and sp and sp.x and sp.y then
                arrow_screen = sp
            end
        elseif core.graphics.world_to_screen then
            local ok, sp = pcall(core.graphics.world_to_screen, arrow_world_pos)
            if ok and sp and sp.x and sp.y then
                arrow_screen = sp
            end
        end
    end
    
    if arrow_screen then
        -- Farbe aus Color Picker
        local arrow_base_color = get_safe_color(menu_elements.target_arrow_color, color.new(255, 220, 0, 255))
        local ar, ag, ab, aa = get_color_rgba(arrow_base_color)
        local arrow_color = color.new(ar or 255, ag or 220, ab or 0, aa or 255)
        
        -- Im Dungeon Mode: Versuche IMMER zuerst das Icon zu rendern (ignoriere Checkbox)
        local texture_drawn = false
        local icon_size = 30
        local icon_pos = vec2_new(arrow_screen.x - icon_size * 0.5, arrow_screen.y - icon_size * 0.5)
        local _, _, _, icon_alpha = get_color_rgba(arrow_color)
        local tint_color = color.new(255, 255, 255, icon_alpha or 255)
        texture_drawn = draw_texture("target", icon_pos, icon_size, icon_size, tint_color)
        
        -- Fallback: Pfeil rendern wenn Texture nicht verfügbar oder Icon-Toggle aus
        if not texture_drawn and core.graphics and core.graphics.triangle_2d_filled then
            local arrow_tip_y = arrow_screen.y + 12
            local arrow_base_y = arrow_screen.y - 3
            local arrow_width = 7
            local arrow_tip = vec2_new(arrow_screen.x, arrow_tip_y)
            local arrow_left = vec2_new(arrow_screen.x - arrow_width, arrow_base_y)
            local arrow_right = vec2_new(arrow_screen.x + arrow_width, arrow_base_y)
            pcall(core.graphics.triangle_2d_filled, arrow_tip, arrow_left, arrow_right, arrow_color)
            
            -- "TARGET" Text über dem Pfeil (zentriert)
            local text_y = arrow_base_y - 18
            if core.graphics.text_2d then
                local outline_color = color.new(0, 0, 0, aa or 255)
                local offsets = {{-1,0}, {1,0}, {0,-1}, {0,1}}
                for _, off in ipairs(offsets) do
                    pcall(core.graphics.text_2d, "TARGET", vec2_new(arrow_screen.x + off[1], text_y + off[2]), 16, outline_color, true)
                end
                pcall(core.graphics.text_2d, "TARGET", vec2_new(arrow_screen.x, text_y), 16, arrow_color, true)
            end
        end
    end
end

local function on_render()
    
    -- Icons beim ersten Render laden (falls API verfügbar)
    load_gathering_icons()
    
    -- Cache Spielerposition für diesen Frame (verhindert Sync-Probleme)
    cache_player_position()
    
    -- Update Edit Mode (muss IMMER laufen, auch wenn Script deaktiviert ist)
    if edit_mode_module and edit_mode_module.update then
        edit_mode_module.update()
    end
    
    -- Settings Menu Keybind Check (F7) - DEAKTIVIERT auf User-Wunsch, jetzt über Visuals-Menu Button
    -- if settings_menu and core.input and core.input.is_key_pressed then
    --     local key_code = 0x76  -- F7
    --     -- Hole den konfigurierten Key aus dem Keybind-Element
    --     if menu_elements.settings_key and menu_elements.settings_key.get then
    --         local ok, key = pcall(menu_elements.settings_key.get, menu_elements.settings_key)
    --         if ok and key and type(key) == "number" then
    --             key_code = key
    --         end
    --     end
        
    --     local ok, is_pressed = pcall(core.input.is_key_pressed, key_code)
    --     if ok and is_pressed and not settings_key_was_pressed then
    --         settings_menu:toggle()
    --     end
    --     settings_key_was_pressed = is_pressed
    -- end
    
    -- Prüfe Dungeon Mode (nur Toggle State, wie beim Haupt-Toggle)
    -- DEFAULT: false (Dungeon Mode ist AUS im normalen Modus)
    local dungeon_mode_active = false
    if menu_elements.dungeon_mode_key and menu_elements.dungeon_mode_key.get_toggle_state then
        local ok, val = pcall(menu_elements.dungeon_mode_key.get_toggle_state, menu_elements.dungeon_mode_key)
        if ok and val == true then
            dungeon_mode_active = true
        end
    end
    
    -- Wenn Dungeon Mode aktiv ist, nur Nameplates und Target Icon rendern
    if dungeon_mode_active then
        -- Render Edit Mode Overlay auch wenn Script deaktiviert ist
        if edit_mode_module and edit_mode_module.render then
            edit_mode_module.render()
        end
        
        -- Nur Custom Nameplates und Target Icon im Dungeon Mode
        render_custom_nameplates()
        render_target_icon_only()
        
        return
    end
    
    -- Gathering Mode: Nur Gathering ESP rendern (Herbs, Ores, Chests, Fish)
    local gathering_mode_active = is_gathering_mode_active()
    if gathering_mode_active then
        -- Render Edit Mode Overlay
        if edit_mode_module and edit_mode_module.render then
            edit_mode_module.render()
        end
        
        -- Nur Gathering ESP rendern (filter wird in render_enemy_esp angewendet)
        render_enemy_esp()  -- Gathering ist Teil von render_enemy_esp
        
        return
    end
    
    -- GLOBAL CHECK: Wenn Script deaktiviert, nichts rendern!
    -- Prüfe Checkbox UND Toggle-Key
    local checkbox_enabled = true
    if menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok and val ~= nil then
            checkbox_enabled = val
        end
    end
    
    local toggle_enabled = true
    if menu_elements.toggle_key and menu_elements.toggle_key.get_toggle_state then
        local ok, val = pcall(menu_elements.toggle_key.get_toggle_state, menu_elements.toggle_key)
        if ok and val ~= nil then
            toggle_enabled = val
        end
    end
    
    -- Beide müssen aktiv sein!
    if not checkbox_enabled or not toggle_enabled then
        -- Render Edit Mode Overlay auch wenn Script deaktiviert ist
        if edit_mode_module and edit_mode_module.render then
            edit_mode_module.render()
        end
        
        return  -- Alles aus wenn Toggle aus!
    end
    
    local hardcore_active = false
    if menu_elements.hardcore_dark_mode and menu_elements.hardcore_dark_mode.get_state then
        local ok, val = pcall(menu_elements.hardcore_dark_mode.get_state, menu_elements.hardcore_dark_mode)
        if ok and val == true then
            hardcore_active = true
        end
    end
    
    -- ZUERST: Darkmode-Overlay (wenn aktiv) - abdunkelt nur das Spiel
    if hardcore_active then
        render_hardcore_dark_overlay()
    end
    
    -- UNTERSTE EBENE: Safe Zone und Radar zuerst (damit alles andere darüber ist)
    render_safe_zone_indicator()  -- Ganz unten!
    render_radar()
    
    -- ESP-Elemente werden hier gerendert
    -- Boxen und Tracelines werden automatisch in 2D gerendert, wenn Darkmode aktiv ist
    -- (über die draw_box_3d und draw_traceline Funktionen)
    render_enemy_esp()
    
    -- Hardcore-Features (werden über allem gerendert, bleiben hell)
    render_hardcore_danger_zones()
    render_enemy_spotlights()
    
    -- Health & Resource Overlay ÜBER allem rendern
    render_health_resource_overlay()
    render_target_overlay()
    render_pet_health_resource_overlay()
    render_xp_bar_overlay()
    render_level_difference_warning()
    check_enemies_behind()
    check_patrol_warning()
    render_death_risk_calculator()
    render_combat_prediction()
    render_custom_nameplates()
    
    -- Render Edit Mode Overlay (muss zuletzt gerendert werden, auch wenn Script aktiv ist)
    if edit_mode_module and edit_mode_module.render then
        edit_mode_module.render()
    end
end

-- Post-Render: ESP-Elemente, die ÜBER dem Darkmode-Overlay gerendert werden müssen
-- Diese Funktion wird nach dem UI-Overlay gerendert (wie Quest-Texte)
local function on_post_render()
    -- GLOBAL CHECK: Wenn Script deaktiviert, nichts rendern!
    local checkbox_enabled = true
    if menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok and val ~= nil then
            checkbox_enabled = val
        end
    end
    
    local toggle_enabled = true
    if menu_elements.toggle_key and menu_elements.toggle_key.get_toggle_state then
        local ok, val = pcall(menu_elements.toggle_key.get_toggle_state, menu_elements.toggle_key)
        if ok and val ~= nil then
            toggle_enabled = val
        end
    end
    
    if not checkbox_enabled or not toggle_enabled then
        -- Render Edit Mode Overlay auch wenn Script deaktiviert ist
        if edit_mode_module and edit_mode_module.render then
            edit_mode_module.render()
        end
        return  -- Alles aus wenn Toggle aus!
    end
    
    -- RADAR wird NUR in on_render() gerendert (nicht doppelt, sonst springt Dragging!)
    -- ESP-Elemente, die über dem Darkmode sichtbar sein sollen
    render_enemy_esp()
    
    -- Render Edit Mode Overlay (muss zuletzt gerendert werden)
    if edit_mode_module and edit_mode_module.render then
        edit_mode_module.render()
    end
end
local function on_render_menu()
    if not menu or not menu.tree_node then
        return
    end
    if not menu_elements.main_tree then
        menu_elements.main_tree = menu.tree_node(ADDON_NAME)
    end
    if not menu_elements.main_tree then
        return
    end
    menu_elements.main_tree:render(ADDON_NAME, function()
        if menu_elements.enabled then
            menu_elements.enabled:render("Enable Enemy ESP")
        end
        if menu_elements.toggle_key then
            menu_elements.toggle_key:render("Toggle", "Taste zum Ein-/Ausschalten")
        end
        if menu_elements.settings_key then
            menu_elements.settings_key:render("Settings Hotkey", "Taste zum Öffnen der Settings (Standard: F7)")
        end
        if menu_elements.max_distance then
            menu_elements.max_distance:render("Max Distance")
        end
        if menu_elements.open_settings_window and settings_menu then
            if menu_elements.open_settings_window:render("Open Settings") then
                settings_menu:toggle()
            end
        end
    end)
end
local function init_menu_elements()
    if not menu then
        return
    end
    menu_elements.main_tree = menu.tree_node(ADDON_NAME)
    menu_elements.enemy_circle_tree = menu.tree_node()
    menu_elements.danger_zone_tree = menu.tree_node()
    menu_elements.targeting_tree = menu.tree_node()
    menu_elements.quest_tree = menu.tree_node()
    menu_elements.gathering_tree = menu.tree_node()
    menu_elements.attack_range_tree = menu.tree_node()
    menu_elements.radar_tree = menu.tree_node()
    menu_elements.enhanced_esp_tree = menu.tree_node()
    menu_elements.window_enemy_circles_tree = menu.tree_node()
    menu_elements.window_danger_zones_tree = menu.tree_node()
    menu_elements.window_targeting_tree = menu.tree_node()
    menu_elements.window_quest_tree = menu.tree_node()
    menu_elements.window_gathering_tree = menu.tree_node()
    menu_elements.window_attack_range_tree = menu.tree_node()
    menu_elements.window_radar_tree = menu.tree_node()
    menu_elements.window_enhanced_esp_tree = menu.tree_node()
    menu_elements.open_settings_window = menu.button(TAG .. "open_settings_window")
    
    -- Reset Buttons für UI Positionen
    menu_elements.reset_health_bar_pos = menu.button(TAG .. "reset_health_bar_pos")
    menu_elements.reset_xp_bar_pos = menu.button(TAG .. "reset_xp_bar_pos")
    menu_elements.reset_cast_bar_pos = menu.button(TAG .. "reset_cast_bar_pos")
    menu_elements.reset_target_bar_pos = menu.button(TAG .. "reset_target_bar_pos")
    menu_elements.reset_level_warning_pos = menu.button(TAG .. "reset_level_warning_pos")
    menu_elements.reset_behind_warning_pos = menu.button(TAG .. "reset_behind_warning_pos")
    menu_elements.reset_patrol_warning_pos = menu.button(TAG .. "reset_patrol_warning_pos")
    
    -- Reset Buttons für UI Scale Slider
    menu_elements.reset_health_resource_overlay_scale = menu.button(TAG .. "reset_health_resource_overlay_scale")
    menu_elements.reset_target_overlay_scale = menu.button(TAG .. "reset_target_overlay_scale")
    menu_elements.reset_xp_bar_overlay_scale = menu.button(TAG .. "reset_xp_bar_overlay_scale")
    menu_elements.reset_enemy_cast_bar_scale = menu.button(TAG .. "reset_enemy_cast_bar_scale")
    menu_elements.reset_player_cast_bar_scale = menu.button(TAG .. "reset_player_cast_bar_scale")
    menu_elements.reset_enemy_hp_bar_scale = menu.button(TAG .. "reset_enemy_hp_bar_scale")
    
    -- Edit Mode Initialisierung
    if edit_mode_module and edit_mode_module.init then
        local edit_mode_callbacks = {
            load_health_bar_position = load_health_bar_position,
            load_target_bar_position = load_target_bar_position,
            load_xp_bar_position = load_xp_bar_position,
            load_cast_bar_position = load_cast_bar_position,
            load_pet_bar_position = load_pet_bar_position,
            get_element_scale = get_element_scale,
            menu_elements = menu_elements
        }
        edit_mode_module.init(menu, TAG, edit_mode_callbacks)
    end
    
    menu_elements.enabled = menu.checkbox(true, TAG .. "enabled")
    menu_elements.toggle_key = menu.keybind(0x12, true, TAG .. "toggle")
    menu_elements.settings_key = menu.keybind(0x76, false, TAG .. "settings_key")  -- F7 Key
    menu_elements.dungeon_mode_key = menu.keybind(0x00, false, TAG .. "dungeon_mode_key")  -- Standard: kein Key, kann im Menu gesetzt werden
    menu_elements.enemy_color = menu.colorpicker(color.new(255, 0, 0, 255), "enemyesp_color")
    menu_elements.show_enemy_circles = menu.checkbox(true, "enemyesp_show_enemy_circles")
    menu_elements.show_names = menu.checkbox(true, "enemyesp_show_names")
    menu_elements.max_distance = menu.slider_float(10.0, 200.0, 100.0, "enemyesp_max_distance")
    menu_elements.show_danger_zones = menu.checkbox(true, "enemyesp_show_danger_zones")
    menu_elements.danger_zone_radius = menu.slider_float(5.0, 20.0, 12.0, "enemyesp_danger_zone_radius")
    menu_elements.danger_zone_scale = menu.slider_float(0.1, 2.0, 1.4, "enemyesp_danger_zone_scale")
    menu_elements.danger_zone_color = menu.colorpicker(color.new(255, 165, 0, 255), "enemyesp_danger_zone_color")
    menu_elements.show_targeting_indicator = menu.checkbox(true, "enemyesp_show_targeting")
    menu_elements.targeting_color = menu.colorpicker(color.new(255, 0, 0, 255), "enemyesp_targeting_color")
    menu_elements.stealth_color = menu.colorpicker(color.new(255, 0, 255, 255), "enemyesp_stealth_color")
    menu_elements.show_in_combat_with = menu.checkbox(true, TAG .. "show_in_combat_with")
    menu_elements.show_target_arrow = menu.checkbox(true, TAG .. "show_target_arrow")
    menu_elements.target_arrow_color = menu.colorpicker(color.new(255, 220, 0, 255), TAG .. "target_arrow_color")
    menu_elements.elite_color = menu.colorpicker(color.new(255, 165, 0, 255), "enemyesp_elite_color")
    menu_elements.rare_color = menu.colorpicker(color.new(255, 215, 0, 255), "enemyesp_rare_color")
    menu_elements.boss_color = menu.colorpicker(color.new(255, 0, 0, 255), "enemyesp_boss_color")
    menu_elements.line_thickness = menu.slider_float(1.0, 15.0, 3.0, "enemyesp_line_thickness")
    menu_elements.show_quest_mobs = menu.checkbox(true, "enemyesp_show_quest_mobs")
    menu_elements.show_quest_symbol = menu.checkbox(true, "enemyesp_show_quest_symbol")
    menu_elements.show_level_hp = menu.checkbox(true, "enemyesp_show_level_hp")
    -- ESP 2.0 Features
    menu_elements.show_cast_bar = menu.checkbox(true, TAG .. "show_cast_bar")
    menu_elements.show_elite_highlight = menu.checkbox(true, TAG .. "show_elite_highlight")
    menu_elements.show_movement_status = menu.checkbox(true, TAG .. "show_movement_status")
    menu_elements.show_facing_indicator = menu.checkbox(false, TAG .. "show_facing_indicator")
    menu_elements.quest_color = menu.colorpicker(color.new(255, 215, 0, 255), "enemyesp_quest_color")
    menu_elements.quest_item_color = menu.colorpicker(color.new(255, 215, 0, 255), "enemyesp_quest_item_color")
    menu_elements.show_herbs = menu.checkbox(true, "enemyesp_show_herbs")
    menu_elements.show_mining = menu.checkbox(true, "enemyesp_show_mining")
    menu_elements.show_chests = menu.checkbox(true, "enemyesp_show_chests")
    menu_elements.show_fishing = menu.checkbox(true, "enemyesp_show_fishing")
    menu_elements.herb_color = menu.colorpicker(color.new(0, 190, 255, 255), "enemyesp_herb_color")
    menu_elements.mining_color = menu.colorpicker(color.new(200, 180, 80, 255), "enemyesp_mining_color")
    menu_elements.chest_color = menu.colorpicker(color.new(255, 215, 0, 255), "enemyesp_chest_color")
    menu_elements.fishing_color = menu.colorpicker(color.new(80, 170, 255, 255), "enemyesp_fishing_color")
    menu_elements.gathering_radius = menu.slider_float(1.0, 40.0, 1.62, "enemyesp_gathering_radius")
    menu_elements.gathering_thickness = menu.slider_float(1.0, 8.0, 5.82, "enemyesp_gathering_thickness")
    menu_elements.show_attack_range = menu.checkbox(false, TAG .. "show_attack_range")
    menu_elements.use_spell_range = menu.checkbox(true, TAG .. "use_spell_range")
    menu_elements.min_range = menu.slider_float(0.0, 10.0, 0.0, TAG .. "min_range")
    menu_elements.max_range = menu.slider_float(5.0, 50.0, 40.0, TAG .. "max_range")
    menu_elements.attack_range_color = menu.colorpicker(color.new(0, 255, 0, 200), TAG .. "attack_range_color")
    menu_elements.dead_zone_color = menu.colorpicker(color.new(255, 0, 0, 200), TAG .. "dead_zone_color")
    menu_elements.attack_range_thickness = menu.slider_float(1.0, 10.0, 2.0, TAG .. "attack_range_thickness")
    menu_elements.show_radar = menu.checkbox(false, TAG .. "show_radar")
    menu_elements.radar_size = menu.slider_float(150.0, 500.0, 250.0, TAG .. "radar_size")
    -- Radar-Position (wird über Menü-Slider eingestellt, persistent)
    menu_elements.radar_pos_x = menu.slider_float(0.0, 3840.0, 100.0, TAG .. "radar_pos_x")
    menu_elements.radar_pos_y = menu.slider_float(0.0, 1500.0, 100.0, TAG .. "radar_pos_y")
    menu_elements.radar_range = menu.slider_float(20.0, 200.0, 50.0, TAG .. "radar_range")
    menu_elements.radar_background_color = menu.colorpicker(color.new(20, 20, 30, 220), TAG .. "radar_bg_color")
    menu_elements.radar_border_color = menu.colorpicker(color.new(100, 100, 120, 255), TAG .. "radar_border_color")
    menu_elements.radar_player_color = menu.colorpicker(color.new(0, 150, 255, 255), TAG .. "radar_player_color")
    menu_elements.radar_enemy_color = menu.colorpicker(color.new(255, 0, 0, 255), TAG .. "radar_enemy_color")
    menu_elements.radar_quest_color = menu.colorpicker(color.new(255, 215, 0, 255), TAG .. "radar_quest_color")
    menu_elements.radar_quest_item_color = menu.colorpicker(color.new(255, 215, 0, 255), TAG .. "radar_quest_item_color")
    menu_elements.radar_gathering_color = menu.colorpicker(color.new(0, 255, 120, 255), TAG .. "radar_gathering_color")
    menu_elements.radar_fishing_color = menu.colorpicker(color.new(80, 170, 255, 255), TAG .. "radar_fishing_color")
    menu_elements.radar_show_names = menu.checkbox(false, TAG .. "radar_show_names")
    menu_elements.radar_blip_size = menu.slider_float(2.0, 10.0, 4.0, TAG .. "radar_blip_size")
    menu_elements.show_tracelines_all = menu.checkbox(false, TAG .. "show_tracelines_all")
    menu_elements.show_tracelines_gathering = menu.checkbox(false, TAG .. "show_tracelines_gathering")
    menu_elements.gathering_traceline_solid = menu.checkbox(false, TAG .. "gathering_traceline_solid")  -- true = solid, false = dotted
    menu_elements.show_tracelines_questmobs = menu.checkbox(false, TAG .. "show_tracelines_questmobs")
    menu_elements.show_tracelines_questitems = menu.checkbox(false, TAG .. "show_tracelines_questitems")
    menu_elements.show_traceline_labels = menu.checkbox(true, TAG .. "show_traceline_labels")
    menu_elements.show_herb_icon_instead_of_text = menu.checkbox(false, TAG .. "show_herb_icon_instead_of_text")
    menu_elements.show_mining_icon_instead_of_text = menu.checkbox(false, TAG .. "show_mining_icon_instead_of_text")
    menu_elements.show_fish_icon_instead_of_text = menu.checkbox(false, TAG .. "show_fish_icon_instead_of_text")
    menu_elements.show_chest_icon_instead_of_text = menu.checkbox(false, TAG .. "show_chest_icon_instead_of_text")
    menu_elements.show_target_icon_instead_of_arrow = menu.checkbox(false, TAG .. "show_target_icon_instead_of_arrow")
    menu_elements.show_questmob_icon_instead_of_text = menu.checkbox(false, TAG .. "show_questmob_icon_instead_of_text")
    menu_elements.show_questitem_icon_instead_of_text = menu.checkbox(false, TAG .. "show_questitem_icon_instead_of_text")
    menu_elements.enable_distance_fading = menu.checkbox(true, TAG .. "enable_distance_fading")
    menu_elements.radar_show_height = menu.checkbox(true, TAG .. "radar_show_height")
    menu_elements.box_esp_all_enemies = menu.checkbox(false, TAG .. "box_esp_all_enemies")
    menu_elements.fill_box_esp = menu.checkbox(true, TAG .. "fill_box_esp")
    menu_elements.box_esp_thickness = menu.slider_float(1.0, 5.0, 2.0, TAG .. "box_esp_thickness")
    menu_elements.box_esp_visibility = menu.slider_float(10.0, 200.0, 30.0, TAG .. "box_esp_visibility")  -- Distance at which Box ESP starts fading
    menu_elements.hardcore_dark_mode = menu.checkbox(false, TAG .. "hardcore_dark_mode")
    menu_elements.dark_mode_intensity = menu.slider_float(0.0, 1.0, 0.7, TAG .. "dark_mode_intensity")
    menu_elements.enemy_spotlight = menu.checkbox(false, TAG .. "enemy_spotlight")
    menu_elements.spotlight_radius = menu.slider_float(50.0, 500.0, 200.0, TAG .. "spotlight_radius")
    menu_elements.spotlight_intensity = menu.slider_float(0.0, 1.0, 0.5, TAG .. "spotlight_intensity")
    menu_elements.health_resource_overlay = menu.checkbox(false, TAG .. "health_resource_overlay")
    menu_elements.xp_bar_overlay = menu.checkbox(false, TAG .. "xp_bar_overlay")
    menu_elements.show_player_cast_bar = menu.checkbox(true, TAG .. "show_player_cast_bar")
    menu_elements.target_overlay = menu.checkbox(true, TAG .. "target_overlay")
    menu_elements.pet_overlay = menu.checkbox(true, TAG .. "pet_overlay")
    
    -- Position Slider für Health/Resource Bar (als % der Bildschirmgröße, später konvertiert zu Pixel)
    menu_elements.health_bar_pos_x = menu.slider_float(0.0, 100.0, 50.0, TAG .. "health_bar_pos_x")  -- Standard: 50% (zentriert)
    menu_elements.health_bar_pos_y = menu.slider_float(0.0, 100.0, 75.0, TAG .. "health_bar_pos_y")  -- Standard: 75% (unter Charakter)
    
    -- Position Slider für XP Bar (als % der Bildschirmgröße, später konvertiert zu Pixel)
    menu_elements.xp_bar_pos_x = menu.slider_float(0.0, 100.0, 50.0, TAG .. "xp_bar_pos_x")  -- Standard: 50% (zentriert)
    menu_elements.xp_bar_pos_y = menu.slider_float(0.0, 100.0, 2.3, TAG .. "xp_bar_pos_y")  -- Standard: 2.3% (25px bei 1080p)
    
    -- Position Slider für Cast Bar (als % der Bildschirmgröße, später konvertiert zu Pixel)
    menu_elements.cast_bar_pos_x = menu.slider_float(0.0, 100.0, 50.0, TAG .. "cast_bar_pos_x")  -- Standard: 50% (zentriert)
    menu_elements.cast_bar_pos_y = menu.slider_float(0.0, 100.0, 80.0, TAG .. "cast_bar_pos_y")  -- Standard: 80% (unter Health Bar)
    
    -- Position Slider für Target Bar (als % der Bildschirmgröße, später konvertiert zu Pixel)
    menu_elements.target_bar_pos_x = menu.slider_float(0.0, 100.0, 50.0, TAG .. "target_bar_pos_x")  -- Standard: 50% (zentriert)
    menu_elements.target_bar_pos_y = menu.slider_float(0.0, 100.0, 25.0, TAG .. "target_bar_pos_y")  -- Standard: 25% (oben)
    
    -- Position Slider für Pet Bar (als % der Bildschirmgröße, später konvertiert zu Pixel)
    menu_elements.pet_bar_pos_x = menu.slider_float(0.0, 100.0, 50.0, TAG .. "pet_bar_pos_x")  -- Standard: 50% (zentriert)
    menu_elements.pet_bar_pos_y = menu.slider_float(0.0, 100.0, 85.0, TAG .. "pet_bar_pos_y")  -- Standard: 85% (unter Player Bar)
    
    -- UI Scale Slider für einzelne UI-Elemente
    menu_elements.health_resource_overlay_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "health_resource_overlay_scale")
    menu_elements.target_overlay_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "target_overlay_scale")
    menu_elements.pet_overlay_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "pet_overlay_scale")
    menu_elements.xp_bar_overlay_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "xp_bar_overlay_scale")
    menu_elements.enemy_cast_bar_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "enemy_cast_bar_scale")
    menu_elements.player_cast_bar_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "player_cast_bar_scale")
    menu_elements.enemy_hp_bar_scale = menu.slider_float(50.0, 200.0, 100.0, TAG .. "enemy_hp_bar_scale")
    
    menu_elements.level_difference_warning = menu.checkbox(false, TAG .. "level_difference_warning")
    -- Level Warning Window Position (wird über Menü-Slider eingestellt, persistent)
    menu_elements.level_warning_pos_x = menu.slider_float(0.0, 3840.0, 100.0, TAG .. "level_warning_pos_x")
    menu_elements.level_warning_pos_y = menu.slider_float(0.0, 1500.0, 150.0, TAG .. "level_warning_pos_y")
    menu_elements.behind_warning = menu.checkbox(false, TAG .. "behind_warning")
    menu_elements.behind_warning_distance = menu.slider_float(5.0, 40.0, 20.0, TAG .. "behind_warning_distance")
    -- Behind Warning Window Position (wird über Menü-Slider eingestellt, persistent)
    menu_elements.behind_warning_pos_x = menu.slider_float(0.0, 3840.0, 100.0, TAG .. "behind_warning_pos_x")
    menu_elements.behind_warning_pos_y = menu.slider_float(0.0, 1500.0, 270.0, TAG .. "behind_warning_pos_y")
    menu_elements.patrol_warning = menu.checkbox(false, TAG .. "patrol_warning")
    menu_elements.patrol_warning_distance = menu.slider_float(10.0, 60.0, 30.0, TAG .. "patrol_warning_distance")
    -- Patrol Warning Window Position (wird über Menü-Slider eingestellt, persistent)
    menu_elements.patrol_warning_pos_x = menu.slider_float(0.0, 3840.0, 100.0, TAG .. "patrol_warning_pos_x")
    menu_elements.patrol_warning_pos_y = menu.slider_float(0.0, 1500.0, 380.0, TAG .. "patrol_warning_pos_y")
    menu_elements.safe_zone_indicator = menu.checkbox(false, TAG .. "safe_zone_indicator")
    menu_elements.safe_zone_transparency = menu.slider_int(0, 100, 60, TAG .. "safe_zone_transparency")
    menu_elements.death_risk_calculator = menu.checkbox(false, TAG .. "death_risk_calculator")
    menu_elements.combat_prediction = menu.checkbox(false, TAG .. "combat_prediction")
    menu_elements.radar_show_enemy_arrows = menu.checkbox(true, TAG .. "radar_show_enemy_arrows")
    menu_elements.radar_show_quest_arrows = menu.checkbox(true, TAG .. "radar_show_quest_arrows")
    
    -- Custom Nameplates
    menu_elements.custom_nameplates = menu.checkbox(false, TAG .. "custom_nameplates")
    menu_elements.nameplate_width = menu.slider_float(80.0, 200.0, 120.0, TAG .. "nameplate_width")
    menu_elements.nameplate_scale = menu.slider_float(50.0, 150.0, 100.0, TAG .. "nameplate_scale")
    menu_elements.nameplate_show_cast = menu.checkbox(true, TAG .. "nameplate_show_cast")
    menu_elements.nameplate_show_name = menu.checkbox(true, TAG .. "nameplate_show_name")
    menu_elements.nameplate_show_level = menu.checkbox(true, TAG .. "nameplate_show_level")
    menu_elements.nameplate_show_health_text = menu.checkbox(true, TAG .. "nameplate_show_health_text")
    menu_elements.nameplate_max_distance = menu.slider_float(10.0, 100.0, 40.0, TAG .. "nameplate_max_distance")
    menu_elements.nameplate_y_offset = menu.slider_float(-2.0, 5.0, 2.2, TAG .. "nameplate_y_offset")
    menu_elements.nameplate_hp_color = menu.colorpicker(color.new(50, 205, 50, 255), TAG .. "nameplate_hp_color")
    menu_elements.nameplate_cast_color = menu.colorpicker(color.new(255, 200, 50, 255), TAG .. "nameplate_cast_color")
    menu_elements.nameplate_bg_color = menu.colorpicker(color.new(20, 20, 25, 220), TAG .. "nameplate_bg_color")
    menu_elements.nameplate_border_color = menu.colorpicker(color.new(60, 60, 70, 255), TAG .. "nameplate_border_color")
    menu_elements.nameplate_targeting_glow = menu.checkbox(true, TAG .. "nameplate_targeting_glow")
    menu_elements.nameplate_stacking = menu.checkbox(true, TAG .. "nameplate_stacking")
    
    -- Cave Mode (mit Keybind wie Dungeon Mode)
    menu_elements.cave_mode_key = menu.keybind(0x00, true, TAG .. "cave_mode_key")  -- Toggle Keybind
    menu_elements.cave_mode_height_enabled = menu.checkbox(true, TAG .. "cave_mode_height_enabled")
    menu_elements.cave_mode_height = menu.slider_float(3.0, 20.0, 8.0, TAG .. "cave_mode_height")
    menu_elements.cave_mode_cone_enabled = menu.checkbox(false, TAG .. "cave_mode_cone_enabled")
    menu_elements.cave_mode_cone_angle = menu.slider_float(60.0, 180.0, 120.0, TAG .. "cave_mode_cone_angle")
    
    -- Gathering Mode (nur Gathering ESP, mit Filter für Ores/Herbs/Chests)
    menu_elements.gathering_mode_key = menu.keybind(0x00, true, TAG .. "gathering_mode_key")  -- Toggle Keybind
    menu_elements.gathering_mode_ores = menu.checkbox(true, TAG .. "gathering_mode_ores")
    menu_elements.gathering_mode_herbs = menu.checkbox(true, TAG .. "gathering_mode_herbs")
    menu_elements.gathering_mode_chests = menu.checkbox(true, TAG .. "gathering_mode_chests")
    menu_elements.gathering_mode_fish = menu.checkbox(true, TAG .. "gathering_mode_fish")
end
init_menu_elements()

-- PvP-Modul initialisieren
if pvp_module and pvp_module.init then
    pvp_module.init(menu, TAG .. "pvp_")
end

-- Helper: Get readable key name from key code
local KEY_NAMES = {
    [0] = "None", [1] = "LMB", [2] = "RMB", [4] = "MMB", [5] = "Mouse4", [6] = "Mouse5",
    [8] = "Back", [9] = "Tab", [13] = "Enter", [16] = "Shift", [17] = "Ctrl", [18] = "Alt",
    [19] = "Pause", [20] = "CapsLock", [27] = "Esc", [32] = "Space",
    [33] = "PgUp", [34] = "PgDn", [35] = "End", [36] = "Home",
    [37] = "Left", [38] = "Up", [39] = "Right", [40] = "Down",
    [45] = "Ins", [46] = "Del",
    [96] = "Num0", [97] = "Num1", [98] = "Num2", [99] = "Num3", [100] = "Num4",
    [101] = "Num5", [102] = "Num6", [103] = "Num7", [104] = "Num8", [105] = "Num9",
    [106] = "Num*", [107] = "Num+", [109] = "Num-", [110] = "Num.", [111] = "Num/",
    [112] = "F1", [113] = "F2", [114] = "F3", [115] = "F4", [116] = "F5", [117] = "F6",
    [118] = "F7", [119] = "F8", [120] = "F9", [121] = "F10", [122] = "F11", [123] = "F12",
    [160] = "LShift", [161] = "RShift", [162] = "LCtrl", [163] = "RCtrl",
    [164] = "LAlt", [165] = "RAlt", [186] = ";", [187] = "=", [188] = ",",
    [189] = "-", [190] = ".", [191] = "/", [192] = "`", [219] = "[", [220] = "\\",
    [221] = "]", [222] = "'", [999] = "None"
}

local function get_key_name(key_code)
    if not key_code or key_code == 0 or key_code == 999 then
        return "None"
    end
    if KEY_NAMES[key_code] then
        return KEY_NAMES[key_code]
    end
    -- Letters A-Z (65-90)
    if key_code >= 65 and key_code <= 90 then
        return string.char(key_code)
    end
    -- Numbers 0-9 (48-57)
    if key_code >= 48 and key_code <= 57 then
        return string.char(key_code)
    end
    return "Key" .. key_code
end

local function get_keybind_key_name(keybind_element)
    if not keybind_element then return "None" end
    local key_code = 999  -- Default to "None"
    
    -- Versuche get_key_code() (korrekte Methode laut Dokumentation)
    if keybind_element.get_key_code then
        local ok, val = pcall(keybind_element.get_key_code, keybind_element)
        if ok and val and type(val) == "number" then
            key_code = val
        end
    end
    
    return get_key_name(key_code)
end

local function on_render_control_panel()
    if not control_panel_helper then
        return {}
    end
    local enabled = true
    if menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok and val ~= nil then
            enabled = val
        end
    end
    if not enabled then
        return {}
    end
    local cp = {}
    if menu_elements.toggle_key then
        local key_name = get_keybind_key_name(menu_elements.toggle_key)
        control_panel_helper:insert_toggle_(cp, "[ESP] (" .. key_name .. ")", menu_elements.toggle_key, false, false)
    end
    if menu_elements.dungeon_mode_key then
        local key_name = get_keybind_key_name(menu_elements.dungeon_mode_key)
        control_panel_helper:insert_toggle_(cp, "[Dungeon] (" .. key_name .. ")", menu_elements.dungeon_mode_key, false, false)
    end
    if menu_elements.cave_mode_key then
        local key_name = get_keybind_key_name(menu_elements.cave_mode_key)
        control_panel_helper:insert_toggle_(cp, "[Cave] (" .. key_name .. ")", menu_elements.cave_mode_key, false, false)
    end
    if menu_elements.gathering_mode_key then
        local key_name = get_keybind_key_name(menu_elements.gathering_mode_key)
        control_panel_helper:insert_toggle_(cp, "[Gathering] (" .. key_name .. ")", menu_elements.gathering_mode_key, false, false)
    end
    return cp
end
-- ============================================================================
-- Initialize Tabs (New UI Format)
-- ============================================================================
if settings_menu then
    -- Tab 1: General
    settings_menu:add_tab({ id = "general", label = "General" }, function(t)
        t:section_header("Enemy Circles")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_in_combat_with, label = "Show In Combat With" }
            }
        })
        t:colorpicker_list({
            label = "Circle Colors",
            elements = {
                { element = menu_elements.enemy_color, label = "Enemy Color" },
                { element = menu_elements.stealth_color, label = "Stealth Color" },
                { element = menu_elements.elite_color, label = "Elite Color" },
                { element = menu_elements.rare_color, label = "Rare Color" },
                { element = menu_elements.boss_color, label = "Boss Color" }
            }
        })
        
        t:separator()
        t:section_header("Targeting")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_targeting_indicator, label = "Show Targeting Indicator" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.line_thickness, label = "Line Thickness", suffix = "px" }
            }
        })
        t:colorpicker_list({
            elements = {
                { element = menu_elements.targeting_color, label = "Targeting Color" }
            }
        })
        
        t:separator()
        t:section_header("Target Arrow")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_target_arrow, label = "Show Target Arrow" }
            }
        })
        t:colorpicker_list({
            elements = {
                { element = menu_elements.target_arrow_color, label = "Arrow Color" }
            }
        })
        
        t:separator()
        t:section_header("Danger Zones")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_danger_zones, label = "Show Danger Zones" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.danger_zone_radius, label = "Danger Zone Radius", suffix = " yds" },
                { element = menu_elements.danger_zone_scale, label = "Danger Zone Scale", suffix = "x" }
            }
        })
        t:colorpicker_list({
            elements = {
                { element = menu_elements.danger_zone_color, label = "Danger Zone Color" }
            }
        })
    end)

    -- Tab 2: Quest
    settings_menu:add_tab({ id = "quest", label = "Quest" }, function(t)
        t:section_header("Quest Settings")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_quest_mobs, label = "Highlight Quest Mobs" },
                { element = menu_elements.show_quest_symbol, label = "Show Quest Symbol (☠)" },
                { element = menu_elements.show_tracelines_questmobs, label = "Tracelines (Quest Mobs)" },
                { element = menu_elements.show_tracelines_questitems, label = "Tracelines (Quest Items)" },
                { element = menu_elements.radar_show_quest_arrows, label = "Quest Arrows (Radar)" }
            }
        })
        -- Optional elements
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_movement_status, label = "Movement Status" },
                { element = menu_elements.show_facing_indicator, label = "Facing Indicator" }
            }
        })
        t:colorpicker_list({
            label = "Quest Colors",
            elements = {
                { element = menu_elements.quest_color, label = "Quest Mob Color" },
                { element = menu_elements.quest_item_color, label = "Quest Item Color" }
            }
        })
        
        t:separator()
        t:section_header("Questie Status")
        t:custom_render({
            render_func = function(window, ui)
            if questie_available() then
                Components.status_indicator(window, true, "Questie hook active")
                local count_ids = 0
                if questie and questie.get_list_ids then
                    local ok, ids = pcall(questie.get_list_ids, questie)
                    if ok and type(ids) == "table" then
                        count_ids = #ids
                    end
                end
                Components.key_value(window, "Quest IDs cached", count_ids, 150)
            else
                Components.status_indicator(window, false, "Questie not hooked/loaded")
            end
                return 2
            end
        })
    end)

    -- Tab 3: ESP
    settings_menu:add_tab({ id = "esp", label = "ESP" }, function(t)
        t:section_header("Tracelines")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_tracelines_all, label = "Tracelines (All Enemies)" },
                { element = menu_elements.show_tracelines_gathering, label = "Tracelines (Gathering)" },
                { element = menu_elements.gathering_traceline_solid, label = "Solid Lines (Gathering)" },
                { element = menu_elements.show_tracelines_questmobs, label = "Tracelines (Quest Mobs)" },
                { element = menu_elements.show_tracelines_questitems, label = "Tracelines (Quest Items)" },
                { element = menu_elements.show_traceline_labels, label = "Show Traceline Labels" }
            }
        })
        
        t:separator()
        t:section_header("Icons")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_herb_icon_instead_of_text, label = "Icon (Herbs)" },
                { element = menu_elements.show_mining_icon_instead_of_text, label = "Icon (Mining)" },
                { element = menu_elements.show_chest_icon_instead_of_text, label = "Icon (Chests)" },
                { element = menu_elements.show_fish_icon_instead_of_text, label = "Icon (Fishing)" },
                { element = menu_elements.show_target_icon_instead_of_arrow, label = "Icon (Target)" },
                { element = menu_elements.show_questmob_icon_instead_of_text, label = "Icon (Quest Mobs)" },
                { element = menu_elements.show_questitem_icon_instead_of_text, label = "Icon (Quest Items)" }
            }
        })
        
        t:separator()
        t:section_header("Visual Effects")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.enable_distance_fading, label = "Distance Fading" }
            }
        })
        
        t:separator()
        t:section_header("Box ESP")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.box_esp_all_enemies, label = "Box ESP All Enemies" },
                { element = menu_elements.fill_box_esp, label = "Fill Box ESP" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.box_esp_thickness, label = "Box Thickness", suffix = "px" },
                { element = menu_elements.box_esp_visibility, label = "Visibility Distance", suffix = " yds" }
            }
        })
        
        t:separator()
        t:section_header("Attack Range")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_attack_range, label = "Show Attack Range" },
                { element = menu_elements.use_spell_range, label = "Use IZI Spell Range" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.min_range, label = "Min Range (Dead Zone)", suffix = " yds" },
                { element = menu_elements.max_range, label = "Max Range", suffix = " yds" },
                { element = menu_elements.attack_range_thickness, label = "Range Thickness", suffix = "px" }
            }
        })
        t:colorpicker_list({
            label = "Range Colors",
            elements = {
                { element = menu_elements.attack_range_color, label = "Attack Range Color" },
                { element = menu_elements.dead_zone_color, label = "Dead Zone Color" }
            }
        })
    end)
    
    -- Tab 4: Nameplates
    settings_menu:add_tab({ id = "nameplates", label = "Nameplates" }, function(t)
        t:section_header("Custom Nameplates")
        t:checkbox_grid({
            columns = 1,
            elements = {
                { element = menu_elements.custom_nameplates, label = "Enable Custom Nameplates" }
            }
        })
        
        t:separator()
        t:section_header("Display Options")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.nameplate_show_name, label = "Show Name" },
                { element = menu_elements.nameplate_show_level, label = "Show Level" },
                { element = menu_elements.nameplate_show_health_text, label = "Show Health %" },
                { element = menu_elements.nameplate_show_cast, label = "Show Cast Bar" },
                { element = menu_elements.nameplate_targeting_glow, label = "Targeting Glow" },
                { element = menu_elements.nameplate_stacking, label = "Nameplate Stacking" }
            }
        })
        
        t:separator()
        t:section_header("Size & Position")
        t:slider_list({
            elements = {
                { element = menu_elements.nameplate_width, label = "Nameplate Width", suffix = "px" },
                { element = menu_elements.nameplate_scale, label = "Nameplate Scale", suffix = "%" },
                { element = menu_elements.nameplate_y_offset, label = "Vertical Offset", suffix = "" },
                { element = menu_elements.nameplate_max_distance, label = "Max Distance", suffix = " yds" }
            }
        })
        
        t:separator()
        t:section_header("Colors")
        t:colorpicker_list({
            label = "Colors",
            elements = {
                { element = menu_elements.nameplate_hp_color, label = "Health Bar Color" },
                { element = menu_elements.nameplate_cast_color, label = "Cast Bar Color" },
                { element = menu_elements.nameplate_bg_color, label = "Background Color" },
                { element = menu_elements.nameplate_border_color, label = "Border Color" }
            }
        })
    end)
    
    -- Tab 5: Gathering
    settings_menu:add_tab({ id = "gathering", label = "Gathering" }, function(t)
        t:section_header("Gathering Nodes")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_herbs, label = "Show Herbs" },
                { element = menu_elements.show_mining, label = "Show Mining Nodes" },
                { element = menu_elements.show_chests, label = "Show Chests" },
                { element = menu_elements.show_fishing, label = "Show Fishing Ponds" },
                { element = menu_elements.show_tracelines_gathering, label = "Tracelines (Gathering)" },
                { element = menu_elements.gathering_traceline_solid, label = "Solid Lines (Gathering)" }
            }
        })
        
        t:separator()
        t:section_header("Gathering Display")
        t:slider_list({
            elements = {
                { element = menu_elements.gathering_radius, label = "Gathering Radius", suffix = "" },
                { element = menu_elements.gathering_thickness, label = "Gathering Thickness", suffix = "px" }
            }
        })
        t:colorpicker_list({
            label = "Gathering Colors",
            elements = {
                { element = menu_elements.herb_color, label = "Herb Color" },
                { element = menu_elements.mining_color, label = "Mining Color" },
                { element = menu_elements.chest_color, label = "Chest Color" },
                { element = menu_elements.fishing_color, label = "Fishing Pond Color" }
            }
        })
    end)

    -- Tab 6: Radar
    settings_menu:add_tab({ id = "radar", label = "Radar" }, function(t)
        t:section_header("Radar Display")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_radar, label = "Show Radar" },
                { element = menu_elements.radar_show_names, label = "Show Names" },
                { element = menu_elements.radar_show_height, label = "Show Height Indicators" },
                { element = menu_elements.radar_show_enemy_arrows, label = "Show Enemy Arrows" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.radar_size, label = "Radar Size", suffix = "px" },
                { element = menu_elements.radar_range, label = "Radar Range", suffix = " yds" },
                { element = menu_elements.radar_pos_x, label = "Position X", suffix = "" },
                { element = menu_elements.radar_pos_y, label = "Position Y", suffix = "" },
                { element = menu_elements.radar_blip_size, label = "Blip Size", suffix = "px" }
            }
        })
        
        t:separator()
        t:section_header("Radar Colors")
        t:colorpicker_list({
            label = "Radar Colors",
            elements = {
                { element = menu_elements.radar_background_color, label = "Background Color" },
                { element = menu_elements.radar_border_color, label = "Border Color" },
                { element = menu_elements.radar_player_color, label = "Player Color" },
                { element = menu_elements.radar_enemy_color, label = "Enemy Color" },
                { element = menu_elements.radar_quest_color, label = "Quest Mob Color" },
                { element = menu_elements.radar_quest_item_color, label = "Quest Item Color" },
                { element = menu_elements.radar_gathering_color, label = "Gathering Color" },
                { element = menu_elements.radar_fishing_color, label = "Fishing Pond Color" }
            }
        })
    end)

    -- Tab 7: PvP
    local pvp_menu = pvp_module and pvp_module.get_menu_elements and pvp_module.get_menu_elements() or {}
    settings_menu:add_tab({ id = "pvp", label = "PvP" }, function(t)
        t:section_header("Enemy Player ESP")
        if pvp_menu.use_only_enemy_esp or pvp_menu.show_player_class_spec then
            t:checkbox_grid({
                columns = 1,
                elements = {
                    { element = pvp_menu.use_only_enemy_esp, label = "Use only Enemy ESP" },
                    { element = pvp_menu.show_player_class_spec, label = "Show Player Class" }
                }
            })
        end
    end)
    
    -- Tab 8: Modes
    settings_menu:add_tab({ id = "dungeon", label = "Modes" }, function(t)
        t:section_header("Dungeon Mode")
        t:keybind_grid({
            elements = { menu_elements.dungeon_mode_key },
            labels = { "Dungeon Mode Hotkey" }
        })
        
        t:separator()
        t:section_header("Cave Mode")
        t:keybind_grid({
            elements = { menu_elements.cave_mode_key },
            labels = { "Cave Mode Hotkey" }
        })
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.cave_mode_height_enabled, label = "Height Filter" },
                { element = menu_elements.cave_mode_cone_enabled, label = "Cone Filter" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.cave_mode_height, label = "Max Height Diff", suffix = " yds" },
                { element = menu_elements.cave_mode_cone_angle, label = "Cone Angle", suffix = "°" }
            }
        })
        
        t:separator()
        t:section_header("Gathering Mode")
        t:keybind_grid({
            elements = { menu_elements.gathering_mode_key },
            labels = { "Gathering Mode Hotkey" }
        })
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.gathering_mode_herbs, label = "Show Herbs" },
                { element = menu_elements.gathering_mode_ores, label = "Show Ores" },
                { element = menu_elements.gathering_mode_chests, label = "Show Chests" },
                { element = menu_elements.gathering_mode_fish, label = "Show Fish Pools" }
            }
        })
        t:separator()
        t:section_header("Gathering Tracelines")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.show_tracelines_gathering, label = "Tracelines (Gathering)" },
                { element = menu_elements.gathering_traceline_solid, label = "Solid Lines (Gathering)" }
            }
        })
    end)
    
    -- Tab 9: Hardcore
    settings_menu:add_tab({ id = "hardcore", label = "Hardcore" }, function(t)
        t:section_header("Hardcore Mode Overlay")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.hardcore_dark_mode, label = "Dark Mode Overlay" },
                { element = menu_elements.enemy_spotlight, label = "Enemy Spotlights" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.dark_mode_intensity, label = "Darkness Intensity", suffix = "" },
                { element = menu_elements.spotlight_radius, label = "Spotlight Radius", suffix = "px" },
                { element = menu_elements.spotlight_intensity, label = "Spotlight Intensity", suffix = "" }
            }
        })
        
        t:separator()
        t:section_header("Safe Zone & Risk")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.safe_zone_indicator, label = "Safe Zone Indicator" },
                { element = menu_elements.death_risk_calculator, label = "Death Risk Calculator" },
                { element = menu_elements.combat_prediction, label = "Combat Prediction" }
            }
        })
        t:slider_list({
            elements = {
                { element = menu_elements.safe_zone_transparency, label = "Safe Zone Alpha", suffix = "%", min = 0, max = 100 }
            }
        })
    end)

    -- Tab 10: UI
    settings_menu:add_tab({ id = "ui", label = "UI" }, function(t)
        t:section_header("Health & Resource Monitor")
        t:checkbox_grid({
            columns = 2,
            elements = {
                { element = menu_elements.health_resource_overlay, label = "Health & Resource Overlay" },
                { element = menu_elements.pet_overlay, label = "Show Pet Overlay" },
                { element = menu_elements.xp_bar_overlay, label = "XP Bar Overlay" }
            }
        })
        
        t:separator()
        t:section_header("Cast Bars & Overlays")
        t:checkbox_grid({
            columns = 1,
            elements = {
                { element = menu_elements.show_cast_bar, label = "Show Enemy Cast Bar" },
                { element = menu_elements.target_overlay, label = "Show Target Overlay" },
                { element = menu_elements.show_player_cast_bar, label = "Show Player Cast Bar" }
            }
        })
        
        t:separator()
        t:section_header("Edit Mode")
        
        -- Edit Mode Buttons (ESP-styled mit korrekter Position)
        t:custom_render({
            render_func = function(window, ui)
                -- Hole den aktuellen Kontext-Offset
                local offset = window:get_current_context_dynamic_drawing_offset() or vec2.new(0, 0)
                local ox, oy = offset.x or 0, offset.y or 0
                
                -- Theme Farben
                local btn_bg = color.new(35, 38, 45, 220)
                local btn_bg_hover = color.new(45, 50, 60, 240)
                local btn_bg_active = color.new(0, 180, 200, 255)
                local btn_border = color.new(0, 150, 170, 180)
                local btn_border_hover = color.new(0, 200, 220, 255)
                local text_color = color.new(220, 225, 230, 255)
                local text_dark = color.new(28, 30, 35, 255)
                
                local btn_height = 26
                local btn_spacing = 6
                local btn_width = 180
                
                -- Edit Mode Status
                local is_active = false
                if edit_mode_module and edit_mode_module.get_state then
                    is_active = edit_mode_module.get_state()
                end
                
                -- Toggle Button
                local toggle_start = vec2.new(ox, oy)
                local toggle_end = vec2.new(ox + btn_width, oy + btn_height)
                local toggle_hovered = window:is_mouse_hovering_rect(toggle_start, toggle_end)
                
                local toggle_bg = is_active and btn_bg_active or (toggle_hovered and btn_bg_hover or btn_bg)
                local toggle_border = toggle_hovered and btn_border_hover or btn_border
                local toggle_text_color = is_active and text_dark or text_color
                
                window:render_rect_filled(toggle_start, toggle_end, toggle_bg, 3.0)
                window:render_rect(toggle_start, toggle_end, toggle_border, 3.0, 1.0)
                
                local toggle_label = is_active and "Edit Mode: ON" or "Edit Mode: OFF"
                local text_size = window:get_text_size(toggle_label)
                local text_x = ox + (btn_width - text_size.x) / 2
                local text_y = oy + (btn_height - text_size.y) / 2
                window:render_text(1, vec2.new(text_x, text_y), toggle_text_color, toggle_label)
                
                if window:is_rect_clicked(toggle_start, toggle_end) then
                    if edit_mode_module and edit_mode_module.toggle then
                        edit_mode_module.toggle()
                    end
                end
                
                -- Status rechts
                local status_x = ox + btn_width + 12
                local status_text = is_active and "ACTIVE" or "INACTIVE"
                local status_color = is_active and color.new(0, 255, 100, 255) or color.new(100, 105, 110, 255)
                window:render_text(1, vec2.new(status_x, oy + (btn_height - text_size.y) / 2), status_color, status_text)
                
                -- Reset Button
                local row2_y = oy + btn_height + btn_spacing
                local reset_start = vec2.new(ox, row2_y)
                local reset_end = vec2.new(ox + btn_width, row2_y + btn_height)
                local reset_hovered = window:is_mouse_hovering_rect(reset_start, reset_end)
                
                window:render_rect_filled(reset_start, reset_end, reset_hovered and btn_bg_hover or btn_bg, 3.0)
                window:render_rect(reset_start, reset_end, reset_hovered and btn_border_hover or btn_border, 3.0, 1.0)
                
                local reset_label = "Reset All Positions"
                local reset_size = window:get_text_size(reset_label)
                window:render_text(1, vec2.new(ox + (btn_width - reset_size.x) / 2, row2_y + (btn_height - reset_size.y) / 2), text_color, reset_label)
                
                if window:is_rect_clicked(reset_start, reset_end) then
                    if edit_mode_module and edit_mode_module.reset_all_positions then
                        edit_mode_module.reset_all_positions()
                    end
                end
                
                return 2
            end
        })
        
        t:spacing(5)
        t:section_header("Edit Mode Keybinds")
        
        -- Keybinds (native - passen zum Stil)
        t:custom_render({
            render_func = function(window, ui)
                if edit_mode_module and edit_mode_module.get_menu_elements then
                    local edit_mode_menu = edit_mode_module.get_menu_elements()
                    if edit_mode_menu then
                        if edit_mode_menu.edit_mode_key then
                            edit_mode_menu.edit_mode_key:render("Toggle Key", "")
                        end
                        if edit_mode_menu.drag_key then
                            edit_mode_menu.drag_key:render("Select Key", "")
                        end
                        if edit_mode_menu.scale_up_key then
                            edit_mode_menu.scale_up_key:render("Scale Up", "")
                        end
                        if edit_mode_menu.scale_down_key then
                            edit_mode_menu.scale_down_key:render("Scale Down", "")
                        end
                    end
                end
                return 4
            end
        })
    end)

end

-- ============================================================================
-- Module Export (for AIO integration)
-- ============================================================================

local x_esp_new = {}

function x_esp_new.on_render()
    on_render()
end

function x_esp_new.on_render_menu()
    on_render_menu()
end

function x_esp_new.on_render_control_panel()
    return on_render_control_panel()
end

function x_esp_new.on_render_window()
    if settings_menu then
        settings_menu:render()
    end
    -- Level Warning Popup
    render_level_warning_popup()
    -- Behind You Warning Popup
    render_behind_warning_popup()
    -- Patrol Warning Popup
    render_patrol_warning_popup()
    
    -- Render Edit Mode Window (für Maus-Interaktionen)
    if edit_mode_module and edit_mode_module.render_window then
        edit_mode_module.render_window()
    end
    
    -- Arrows for warnings
    render_level_warning_arrow()
    render_behind_warning_arrow()
end

function x_esp_new.is_enabled()
    if menu_elements and menu_elements.enabled and menu_elements.enabled.get_state then
        local ok, val = pcall(menu_elements.enabled.get_state, menu_elements.enabled)
        if ok then return val end
    end
    return true
end

function x_esp_new.toggle_settings_window()
    if settings_menu then
        settings_menu:toggle()
    end
end

function x_esp_new.show_settings_window()
    if settings_menu then
        settings_menu:set_visible(true)
    end
end

function x_esp_new.is_settings_visible()
    if settings_menu then
        return settings_menu:is_visible()
    end
    return false
end

-- Restore Callbacks (ensure engine manages rendering)
if core then
    -- 1. Render Window (Settings menu, Popups)
    if core.register_on_render_window_callback then
        core.register_on_render_window_callback(__object_safety.callback(function()
            if x_esp_new.on_render_window then
                x_esp_new.on_render_window()
            end
        end,"shared/x_esp_new/main.lua:11757"))
    end

    -- 2. Render World (ESP Lines)
    if core.register_on_render_callback then
        core.register_on_render_callback(__object_safety.callback(on_render,"shared/x_esp_new/main.lua:11766"))
    end

    -- 3. Render Menu Tree (Options) - Essential for menu element state!
    if core.register_on_render_menu_callback then
        core.register_on_render_menu_callback(__object_safety.callback(on_render_menu,"shared/x_esp_new/main.lua:11771"))
    end

    -- 4. Render Control Panel
    if core.register_on_render_control_panel_callback then
        core.register_on_render_control_panel_callback(__object_safety.callback(on_render_control_panel,"shared/x_esp_new/main.lua:11776",{}))
    end
end

return x_esp_new

