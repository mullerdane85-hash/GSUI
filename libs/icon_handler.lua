local images = require('images')
local icon_extractor = require('libs/icon_extractor')

local icon_handler = {}

local cache_path = windower.addon_path .. 'cache/'
local icon_images = {}

-- UI visibility flag. Icons can be loaded (texture bound) while the window is
-- hidden so they're ready on first open, but they must NOT be shown. The UI
-- module flips this via icon_handler.set_ui_visible() from ui.show/ui.hide.
local ui_visible = false
function icon_handler.set_ui_visible(v)
    ui_visible = v and true or false
end

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
        -- pcall will catch the yield error (Lua 5.1 can't yield across pcall),
        -- but the BMP is already written and closed before the yield, so
        -- ignore the pcall result and just check if the file exists.
        pcall(icon_extractor.item_by_id, item_id, path)
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

-- Apply texture to an image using EquipViewer's proven call order.
-- Call order matters: path -> color -> alpha -> show -> update.
-- Only calls alpha/show if the UI is currently visible; otherwise just binds
-- the texture so it's ready when the UI is next shown.
local function apply_texture(image, path)
    return pcall(function()
        image:path(path)
        image:color(255, 255, 255)
        if ui_visible then
            image:alpha(230)
            image:show()
        end
        image:update()
    end)
end

function icon_handler.load_icon(image, item_id)
    if not image then return false end
    if not item_id or item_id == 0 then
        image:alpha(0)
        image:hide()
        return false
    end

    local path = icon_handler.get_icon_path(item_id)
    -- Track whether this is a fresh extraction. If so, the pcall-caught
    -- coroutine.yield inside item_by_id can leave the texture unbound on
    -- the first apply; we schedule a follow-up apply to force the bind.
    local was_fresh = not windower.file_exists(path)

    if not icon_handler.ensure_icon(item_id) then
        image:alpha(0)
        image:hide()
        return false
    end

    local ok = apply_texture(image, path)
    if not ok then
        -- BMP exists but failed to display — delete and re-extract once.
        pcall(os.remove, path)
        if icon_handler.ensure_icon(item_id) then
            apply_texture(image, path)
            was_fresh = true
        else
            image:alpha(0)
            image:hide()
            return false
        end
    end

    if was_fresh then
        -- Fresh extractions sometimes fail to bind their texture on the first
        -- apply because item_by_id's coroutine.yield is swallowed by pcall,
        -- leaving the image in an inconsistent state. Retry at several delays
        -- so the texture binds as soon as the file/texture system settles.
        -- Retries only re-bind path + update (NOT color/alpha/show) so any
        -- tints set by callers (e.g. multi-select yellow highlight) survive.
        for _, delay in ipairs({0.05, 0.25, 0.75, 2.0}) do
            coroutine.schedule(function()
                if image then
                    pcall(function()
                        image:path(path)
                        image:update()
                    end)
                end
            end, delay)
        end
    end
    return true
end

function icon_handler.cleanup()
    for _, img in pairs(icon_images) do
        if img then img:destroy() end
    end
    icon_images = {}
end

return icon_handler
