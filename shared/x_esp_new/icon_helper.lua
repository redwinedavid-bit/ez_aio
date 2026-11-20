
local icon_helper = {
    cache = {}, -- table<string, icon_helper_icon_entry>
    ZAMIMG_BASE = "https://wow.zamimg.com/images/wow/icons/large/",
    DEFAULT_DISK_CACHE_FOLDER = "cache/wowhead_icons/",
    DEFAULT_HTTP_THROTTLE_SECONDS = 5,
    DEFAULT_PROBE_THROTTLE_SECONDS = 30
}

---@param name string
---@param position vec2|vec3
---@param width number
---@param height number
---@param tint? color
---@param is_for_window? boolean
---@param opts? icon_helper_draw_opts
---@return boolean
function icon_helper:draw_icon(name, position, width, height, tint, is_for_window, opts)
    if not name or name == "" then return false end
    
    local entry = self.cache[name]
    if not entry then
        entry = {
            key = name,
            name = name,
            url_jpg = self.ZAMIMG_BASE .. name .. ".jpg",
            cache_path_jpg = self.DEFAULT_DISK_CACHE_FOLDER .. name .. ".jpg",
            requested = false,
            next_download_time = 0
        }
        self.cache[name] = entry
        if core.log then core.log("[ICON] New entry created: " .. name) end
    end

    -- Handle vec3 to vec2 conversion
    local draw_pos = position
    if position.z and position.z ~= 0 then
        local screen_pos = core.graphics.w2s(position)
        if screen_pos then
            draw_pos = screen_pos
        else
            -- If w2s fails, but we have a z, it might be a world pos off-screen.
            -- To be safe for ESP, we only proceed if screen_pos is valid.
            return false
        end
    elseif position.z == 0 then
        -- Likely a vec2 with z=0 from the API, use as-is
        draw_pos = position
    end

    -- If we have a texture ID, draw it
    if entry.tex_id then
        local ok, err = pcall(function()
            core.graphics.draw_texture(entry.tex_id, draw_pos, width, height, tint, is_for_window or false)
        end)
        if not ok and core.log then
            core.log("[ICON] Draw error for " .. name .. ": " .. tostring(err))
        end
        return ok
    end

    -- If not loaded, try to load or download
    local now = core.time()
    if not entry.requested and now >= entry.next_download_time then
        -- Try reading from disk first
        local bytes = core.read_data_file(entry.cache_path_jpg)
        if bytes and #bytes > 0 then
            if core.log then core.log("[ICON] Loading from disk cache: " .. name) end
            local tex_id, w, h = core.graphics.load_texture(bytes)
            if tex_id then
                entry.tex_id = tex_id
                entry.w = w
                entry.h = h
                if core.log then core.log("[ICON] Loaded successfully from disk: " .. name .. " (ID: " .. tostring(tex_id) .. ")") end
                pcall(function()
                    core.graphics.draw_texture(entry.tex_id, draw_pos, width, height, tint, is_for_window)
                end)
                return true
            else
                if core.log then core.log("[ICON] Failed to load texture from disk bytes: " .. name) end
            end
        end

        -- If not on disk or load failed, download
        if core.log then core.log("[ICON] Requesting download: " .. name .. " from " .. entry.url_jpg) end
        entry.requested = true
        core.create_data_folder(self.DEFAULT_DISK_CACHE_FOLDER)
        
        core.http_get(entry.url_jpg, function(code, content_type, body, headers)
            entry.requested = false
            if code == 200 and body and #body > 0 then
                if core.log then core.log("[ICON] Download success: " .. name .. " (" .. tostring(#body) .. " bytes)") end
                -- Save to disk
                core.create_data_file(entry.cache_path_jpg)
                core.write_data_file(entry.cache_path_jpg, body)
                
                -- Load to GPU
                local tex_id, w, h = core.graphics.load_texture(body)
                if tex_id then
                    entry.tex_id = tex_id
                    entry.w = w
                    entry.h = h
                    if core.log then
                        core.log("[ICON] Texture created successfully for: " .. name .. " (ID: " .. tostring(tex_id) .. ")")
                    end
                else
                    if core.log then core.log("[ICON] Failed to create texture after download: " .. name) end
                end
            else
                entry.next_download_time = now + self.DEFAULT_HTTP_THROTTLE_SECONDS
                if core.log then
                    core.log("[ICON] Download FAILED: " .. name .. " (Code: " .. tostring(code) .. ")")
                end
            end
        end)
    end

    return false
end

function icon_helper:clear_cache()
    self.cache = {}
end

return icon_helper
