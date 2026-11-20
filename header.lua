local plugin = {}

plugin["name"] = "Bungee x Astro AIO"
plugin["version"] = "0.12"
plugin["author"] = "Bungee x Astro"
plugin["load"] = true

-- check if local player exists before loading the script
local local_player = core.object_manager.get_local_player()
if not local_player then
    plugin["load"] = false
    return plugin
end

return plugin
