-- PvP Module für Bungees Ultimate ESP 2.0
-- Verwaltet PvP-spezifische ESP-Einstellungen

local pvp_module = {}

-- Klassen-Namen (WoW Class IDs)
local CLASS_NAMES = {
    [1] = "Warrior",
    [2] = "Paladin",
    [3] = "Hunter",
    [4] = "Rogue",
    [5] = "Priest",
    [6] = "Death Knight",
    [7] = "Shaman",
    [8] = "Mage",
    [9] = "Warlock",
    [10] = "Monk",
    [11] = "Druid",
    [12] = "Demon Hunter",
    [13] = "Evoker"
}

-- Spezialisierungen pro Klasse (Index 1-4 innerhalb der Klasse)
local SPEC_NAMES = {
    [1] = {"Arms", "Fury", "Protection"},           -- Warrior
    [2] = {"Holy", "Protection", "Retribution"},    -- Paladin
    [3] = {"Beast Mastery", "Marksmanship", "Survival"}, -- Hunter
    [4] = {"Assassination", "Outlaw", "Subtlety"},  -- Rogue
    [5] = {"Discipline", "Holy", "Shadow"},         -- Priest
    [6] = {"Blood", "Frost", "Unholy"},             -- Death Knight
    [7] = {"Elemental", "Enhancement", "Restoration"}, -- Shaman
    [8] = {"Arcane", "Fire", "Frost"},              -- Mage
    [9] = {"Affliction", "Demonology", "Destruction"}, -- Warlock
    [10] = {"Brewmaster", "Mistweaver", "Windwalker"}, -- Monk
    [11] = {"Balance", "Feral", "Guardian", "Restoration"}, -- Druid
    [12] = {"Havoc", "Vengeance"},                  -- Demon Hunter
    [13] = {"Devastation", "Preservation", "Augmentation"} -- Evoker
}

-- Klassen-Farben (WoW Class Colors)
local CLASS_COLORS = {
    [1] = {199, 156, 110},  -- Warrior (tan)
    [2] = {245, 140, 186},  -- Paladin (pink)
    [3] = {171, 212, 115},  -- Hunter (green)
    [4] = {255, 245, 105},  -- Rogue (yellow)
    [5] = {255, 255, 255},  -- Priest (white)
    [6] = {196, 31, 59},    -- Death Knight (red)
    [7] = {0, 112, 222},    -- Shaman (blue)
    [8] = {105, 204, 240},  -- Mage (light blue)
    [9] = {148, 130, 201},  -- Warlock (purple)
    [10] = {0, 255, 150},   -- Monk (jade)
    [11] = {255, 125, 10},  -- Druid (orange)
    [12] = {163, 48, 201},  -- Demon Hunter (dark purple)
    [13] = {51, 147, 127}   -- Evoker (teal)
}

-- Menu-Elemente
local menu_elements_pvp = {
    use_only_enemy_esp = nil,
    show_player_class_spec = nil
}

-- Initialisierung
function pvp_module.init(menu_ref, tag_prefix)
    if not menu_ref then
        return
    end
    
    local tag = tag_prefix or "pvp_"
    menu_elements_pvp.use_only_enemy_esp = menu_ref.checkbox(false, tag .. "use_only_enemy_esp")
    menu_elements_pvp.show_player_class_spec = menu_ref.checkbox(false, tag .. "show_player_class_spec")
    
    return menu_elements_pvp
end

-- Prüft ob "Use only Enemy ESP" aktiviert ist
function pvp_module.should_show_only_enemy_players()
    if not menu_elements_pvp.use_only_enemy_esp then
        return false
    end
    
    local ok, val = pcall(menu_elements_pvp.use_only_enemy_esp.get_state, menu_elements_pvp.use_only_enemy_esp)
    if ok and val ~= nil then
        return val
    end
    
    return false
end

-- Prüft ob "Show Player Class & Spec" aktiviert ist
function pvp_module.should_show_class_spec()
    if not menu_elements_pvp.show_player_class_spec then
        return false
    end
    
    local ok, val = pcall(menu_elements_pvp.show_player_class_spec.get_state, menu_elements_pvp.show_player_class_spec)
    if ok and val ~= nil then
        return val
    end
    
    return false
end

-- Gibt den Klassen-Namen für eine Class ID zurück
function pvp_module.get_class_name(class_id)
    if class_id and CLASS_NAMES[class_id] then
        return CLASS_NAMES[class_id]
    end
    return nil
end

-- Gibt den Spec-Namen für eine Class ID und Spec Index zurück
function pvp_module.get_spec_name(class_id, spec_index)
    if class_id and spec_index and SPEC_NAMES[class_id] then
        local specs = SPEC_NAMES[class_id]
        if specs[spec_index] then
            return specs[spec_index]
        end
    end
    return nil
end

-- Gibt die Klassen-Farbe für eine Class ID zurück (r, g, b)
function pvp_module.get_class_color(class_id)
    if class_id and CLASS_COLORS[class_id] then
        return CLASS_COLORS[class_id][1], CLASS_COLORS[class_id][2], CLASS_COLORS[class_id][3]
    end
    return 255, 255, 255  -- Default: Weiß
end

-- Holt Klasse und Spec-ID von einem Unit
function pvp_module.get_player_class_info(obj)
    if not obj then
        return nil, nil
    end
    
    local class_id = nil
    local spec_id = nil
    
    -- Klasse holen
    if obj.get_class then
        local ok, cid = pcall(obj.get_class, obj)
        if ok and cid and type(cid) == "number" and cid > 0 and cid < 14 then
            class_id = cid
        end
    end
    
    -- Spec holen (falls verfügbar)
    if obj.get_specialization then
        local ok, sid = pcall(obj.get_specialization, obj)
        if ok and sid and type(sid) == "number" then
            spec_id = sid
        end
    elseif obj.get_spec_id then
        local ok, sid = pcall(obj.get_spec_id, obj)
        if ok and sid and type(sid) == "number" then
            spec_id = sid
        end
    end
    
    return class_id, spec_id
end

-- Formatiert Klasse und Spec als String
function pvp_module.format_class_spec_string(class_id, spec_id)
    local class_name = pvp_module.get_class_name(class_id)
    if not class_name then
        return nil
    end
    
    -- Wenn Spec verfügbar, zeige "Spec Class" (z.B. "Arms Warrior")
    if spec_id then
        local spec_name = pvp_module.get_spec_name(class_id, spec_id)
        if spec_name then
            return spec_name .. " " .. class_name
        end
    end
    
    -- Fallback: Nur Klassen-Name
    return class_name
end

-- Prüft ob ein Objekt ein feindlicher Spieler ist (für ESP-Filterung)
function pvp_module.is_enemy_player(obj, local_player, is_player_unit_func, is_player_pet_func)
    if not obj or not local_player then
        return false
    end
    
    -- Prüfe ob es ein Spieler ist
    if not is_player_unit_func or not is_player_unit_func(obj) then
        return false
    end
    
    -- Prüfe ob es kein Pet ist
    if is_player_pet_func and is_player_pet_func(obj) then
        return false
    end
    
    -- Prüfe ob es ein Feind ist
    local is_enemy = false
    if obj.is_enemy_with then
        local ok, result = pcall(obj.is_enemy_with, obj, local_player)
        if ok and result then
            is_enemy = result
        end
    end
    
    return is_enemy
end

-- Rendert das PvP-Menü
function pvp_module.render_menu(window, menu_ref)
    if not window or not menu_ref then
        return
    end
    
    -- Hole TabMenu Components falls verfügbar
    local TabMenu = nil
    local Components = nil
    if core and core.menu then
        local ok_tab, tab_mod = pcall(require, "shared/x_esp_new/core/tab_menu")
        if ok_tab and tab_mod then
            TabMenu = tab_mod
        end
        local ok_comp, comp_mod = pcall(require, "shared/x_esp_new/core/components")
        if ok_comp and comp_mod then
            Components = comp_mod
        end
    end
    
    if TabMenu and Components then
        TabMenu.create_settings_panel(window, function(render)
            Components.spacing(window, 20)
            Components.title(window, "PvP Settings")
            Components.spacing(window, 30)
            
            Components.section_header(window, "Enemy Player ESP", 450)
            Components.spacing(window, 10)
            
            if menu_elements_pvp.use_only_enemy_esp then
                menu_elements_pvp.use_only_enemy_esp:render("Use only Enemy ESP", 
                    "When enabled, only shows ESP boxes for enemy players. When disabled, shows all ESP as normal.")
            end
            
            Components.spacing(window, 15)
            
            if menu_elements_pvp.show_player_class_spec then
                menu_elements_pvp.show_player_class_spec:render("Show Player Class", 
                    "Display the class of enemy players above their ESP box in class colors.")
            end
            
            Components.spacing(window, 20)
        end)
    else
        -- Fallback: Einfaches Rendering ohne Components
        if menu_elements_pvp.use_only_enemy_esp then
            menu_elements_pvp.use_only_enemy_esp:render("Use only Enemy ESP", 
                "When enabled, only shows ESP boxes for enemy players. When disabled, shows all ESP as normal.")
        end
        if menu_elements_pvp.show_player_class_spec then
            menu_elements_pvp.show_player_class_spec:render("Show Player Class", 
                "Display the class of enemy players above their ESP box in class colors.")
        end
    end
end

-- Gibt Menu-Elemente zurück (für Zugriff von außen)
function pvp_module.get_menu_elements()
    return menu_elements_pvp
end

return pvp_module

