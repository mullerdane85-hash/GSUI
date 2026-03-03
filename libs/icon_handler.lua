local images = require('images')
local icon_extractor = require('libs/icon_extractor')

local icon_handler = {}

local cache_path = windower.addon_path .. 'cache/'
local icon_images = {}

function icon_handler.init(game_path)
    if not windower.dir_exists(cache_path) then
        windower.create_dir(cache_path)
    end
    if game_path then
        icon_extractor.ffxi_path(game_path)
    end
end

function icon_handler.get_icon_path(item_id)
    if not item_id or item_id == 0 then return nil end
    return cache_path .. item_id .. '.bmp'
end

function icon_handler.ensure_icon(item_id)
    if not item_id or item_id == 0 then return false end
    local path = icon_handler.get_icon_path(item_id)
    if not windower.file_exists(path) then
        local ok, err = pcall(icon_extractor.item_by_id, item_id, path)
        if not ok then
            return false
        end
    end
    return windower.file_exists(path)
end

function icon_handler.create_image(settings_override)
    local defaults = {
        color = { alpha = 0, red = 20, green = 20, blue = 50 },
        texture = { fit = false },
        size = { width = 32, height = 32 },
        draggable = false,
    }
    if settings_override then
        for k, v in pairs(settings_override) do
            defaults[k] = v
        end
    end
    return images.new(defaults)
end

function icon_handler.load_icon(image, item_id)
    if not image then return false end
    if not item_id or item_id == 0 then
        image:alpha(0)
        image:hide()
        return false
    end
    if icon_handler.ensure_icon(item_id) then
        local path = icon_handler.get_icon_path(item_id)
        local ok = pcall(function()
            image:alpha(0)
            image:path(path)
            image:update()
            image:color(255, 255, 255)
            image:alpha(230)
            image:show()
        end)
        if ok then return true end
        -- BMP exists but failed to display — delete and re-extract
        pcall(os.remove, path)
        if icon_handler.ensure_icon(item_id) then
            pcall(function()
                image:alpha(0)
                image:path(path)
                image:update()
                image:color(255, 255, 255)
                image:alpha(230)
                image:show()
            end)
            return true
        end
    end
    image:alpha(0)
    image:hide()
    return false
end

function icon_handler.cleanup()
    for _, img in pairs(icon_images) do
        if img then img:destroy() end
    end
    icon_images = {}
end

return icon_handler
