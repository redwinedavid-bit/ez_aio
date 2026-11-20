local __object_safety=require("shared/object_safety")

-- By Lemons @ Project Sylvanas 
-- Aurora Systems: Main

-- Import the systems
local AuroraSystem = require("aurora_system")

-- Initialize the systems
AuroraSystem:init_menu()

-- Register callbacks
core.register_on_render_callback(__object_safety.callback(function()
    AuroraSystem:render()
end,"shared/x_esp_new/aurora/main.lua:12"))

core.register_on_render_menu_callback(__object_safety.callback(function()
    AuroraSystem:render_menu()
end,"shared/x_esp_new/aurora/main.lua:16"))

core.log("Enhanced Player Aurora loaded successfully!")