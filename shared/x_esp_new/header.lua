local plugin = {}

plugin["name"] = "Bungee Enemy ESP for WoW Classic"
plugin["version"] = "1.0.0"
plugin["author"] = "Bungee"
plugin["description"] = "ESP for enemies with danger zones and targeting indicators for World of Warcraft Classic. Features customizable colors, dynamic aggro radius, and targeting indicators."
plugin["load"] = true
plugin["dependencies"] = {
    "common/color",
    "common/utility/control_panel_helper",
}

return plugin
