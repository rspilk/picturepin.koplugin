local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local PicturePinIcon = require("pinicon")
local PinnedImagePanel = require("pinnedimagepanel")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

local PicturePin = WidgetContainer:extend{
    name = "picturepin",
    is_doc_only = true,
}

function PicturePin:init()
    self.ui.menu:registerToMainMenu(self)

    self.icon = PicturePinIcon:new{}
    self.ui.view:registerViewModule("picturepin_icon", self.icon)

    self.ui:registerTouchZones({
        {
            id = "picturepin_tap_icon",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = self.icon.icon_size / Screen:getWidth(),
                ratio_h = self.icon.icon_size / Screen:getHeight(),
            },
            overrides = {
                "readerhighlight_tap",
                "tap_top_left_corner",
                "readerfooter_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function() return self:onTapPinIcon() end,
        },
        {
            -- Full-screen, ahead of readerhighlight's own hold zone: if
            -- the hold isn't on an image, we return false and it falls
            -- through to readerhighlight_hold for normal text-selection
            -- handling, unaffected.
            id = "picturepin_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            overrides = { "readerhighlight_hold" },
            handler = function(ges) return self:onHoldImage(ges) end,
        },
    })
end

function PicturePin:addToMainMenu(menu_items)
    menu_items.picturepin = {
        text = _("PicturePin"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = self.pinned_image and _("An image is currently pinned.")
                    or _("No image is currently pinned. Hold an image to pin it."),
            })
        end,
    }
end

function PicturePin:onReaderReady()
    -- Only the reference is restored here (not the bitmap -- that's
    -- re-derived lazily on first tap, see onTapPinIcon/_refetchPinnedImage).
    self.pinned_image = self.ui.doc_settings:readSetting("picturepin_pinned_image")
    self.icon.visible = self.pinned_image ~= nil
end

-- Holding on an image shows it in the stock, unmodified fullscreen
-- ImageViewer (same as vanilla KOReader) -- we don't touch
-- readerhighlight.lua at all; this is our own hold zone, tried before
-- readerhighlight's, falling through (return false) for anything that
-- isn't an image so normal text-selection-by-hold is unaffected.
-- After the preview is closed, offer to pin it via a plain confirm box.
function PicturePin:onHoldImage(ges)
    if not self.ui.rolling then
        return false
    end
    local pos = self.ui.view:screenToPageTransform(ges.pos)
    if not pos then
        return false
    end
    local image = self.ui.document:getImageFromPosition(pos, true, true)
    if not image then
        return false
    end

    local viewer = ImageViewer:new{
        image = image,
        image_disposable = false, -- we decide below whether to keep or free it
        with_title_bar = false,
        fullscreen = true,
    }
    local plugin = self
    local orig_on_close = viewer.onClose
    viewer.onClose = function(viewer_self)
        local ok = orig_on_close(viewer_self)
        plugin:promptToPin(pos, viewer_self.image)
        return ok
    end
    UIManager:show(viewer)
    return true
end

function PicturePin:promptToPin(pos, image)
    UIManager:show(ConfirmBox:new{
        text = _("Pin this image? A small icon will stay on screen while reading this book, to reopen it without losing your place."),
        ok_text = _("Pin"),
        ok_callback = function()
            self:pinImage(pos, image)
        end,
        cancel_callback = function()
            if image and image.free then
                image:free()
            end
        end,
    })
end

function PicturePin:pinImage(pos, image)
    -- Replaces any previously pinned image (single-slot for v1); free it
    -- first if it's a different bitmap than the one we're pinning now.
    if self.pinned_image_bb and self.pinned_image_bb ~= image and self.pinned_image_bb.free then
        self.pinned_image_bb:free()
    end
    self.pinned_image_bb = image

    self.pinned_image = {
        x = pos.x,
        y = pos.y,
        page = pos.page,
        -- Stable anchor, robust to reflow/pagination changes: used to
        -- re-derive the bitmap after an app/book restart, when we no
        -- longer have pinned_image_bb cached. See _refetchPinnedImage.
        xpointer = self.ui.document:getXPointer(),
    }
    self.ui.doc_settings:saveSetting("picturepin_pinned_image", self.pinned_image)
    self.icon.visible = true

    UIManager:show(InfoMessage:new{
        text = _("Image pinned."),
        timeout = 2,
    })
end

function PicturePin:onSaveSettings()
    if self.pinned_image then
        self.ui.doc_settings:saveSetting("picturepin_pinned_image", self.pinned_image)
    end
end

-- Tapping the persistent icon reopens the pinned image over the current
-- page, without navigating there. Within a session this is instant (the
-- bitmap is already cached from pinImage()). After a cold start (app or
-- book just reopened), we don't have that cached bitmap yet -- this is
-- the one case where we briefly jump the document to the pinned
-- position, re-extract the image, and jump straight back, all before
-- ever yielding control back to a screen repaint.
function PicturePin:onTapPinIcon()
    if not self.pinned_image then
        return false
    end
    if not self.pinned_image_bb then
        self.pinned_image_bb = self:_refetchPinnedImage()
    end
    if not self.pinned_image_bb then
        UIManager:show(InfoMessage:new{
            text = _("Could not reopen the pinned image."),
            timeout = 2,
        })
        return true
    end
    UIManager:show(PinnedImagePanel:new{
        image = self.pinned_image_bb,
    })
    return true
end

function PicturePin:_refetchPinnedImage()
    local original_xp = self.ui.document:getXPointer()
    self.ui.rolling:onGotoXPointer(self.pinned_image.xpointer)
    local image = self.ui.document:getImageFromPosition(self.pinned_image, true, true)
    self.ui.rolling:onGotoXPointer(original_xp)
    return image
end

return PicturePin
