local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local PannableImage = require("pannableimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

-- Small always-visible close affordance, positioned in the panel's
-- top-right corner via OverlapGroup. Registers its own "tap" ges_events
-- (full-screen range, like other leaf widgets do), but only acts if the
-- tap actually lands within its own current on-screen area (self.dimen,
-- updated on every paintTo) -- needed since the whole panel can be
-- dragged elsewhere.
local CloseButton = InputContainer:extend{
    callback = nil,
}

function CloseButton:init()
    self.icon_size = Screen:scaleBySize(24)
    self.icon = IconWidget:new{
        icon = "close",
        width = self.icon_size,
        height = self.icon_size,
    }
    self.overlap_align = "right"
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
    }
end

function CloseButton:getSize()
    return Geom:new{ w = self.icon_size, h = self.icon_size }
end

function CloseButton:onTap(_, ges)
    if self.dimen and ges.pos:intersectWith(self.dimen) then
        if self.callback then
            self.callback()
        end
        return true
    end
    return false
end

function CloseButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.icon_size, h = self.icon_size }
    self.icon:paintTo(bb, x, y)
end

-- Small always-visible resize handle, bottom-right corner (via
-- overlap_offset, since OverlapGroup's overlap_align only directly
-- supports horizontal left/right/center). Claims the same raw Hold/
-- HoldPan/HoldRelease gesture types MovableContainer wants for its own
-- drag-to-reposition -- since children are tried before their container
-- (confirmed empirically while fixing the panel's own drag earlier),
-- this would win that tie for *any* hold on the panel, not just on the
-- handle itself, unless it explicitly declines: onHold checks its own
-- on-screen area and returns false if the hold didn't start there,
-- exactly mirroring MovableContainer's own "did this sequence start
-- inside me" tracking (self._resizing plays the role of its
-- self._moving).
local ResizeHandle = InputContainer:extend{
    callback = nil, -- called with (dw, dh) once the resize gesture completes
}

function ResizeHandle:init()
    self.icon_size = Screen:scaleBySize(28)
    self.icon = IconWidget:new{
        icon = "control.expand",
        width = self.icon_size,
        height = self.icon_size,
    }
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
    }
end

function ResizeHandle:getSize()
    return Geom:new{ w = self.icon_size, h = self.icon_size }
end

function ResizeHandle:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.icon_size, h = self.icon_size }
    self.icon:paintTo(bb, x, y)
end

function ResizeHandle:onHold(_, ges)
    if self.dimen and ges.pos:intersectWith(self.dimen) then
        self._resizing = true
        self._start_x, self._start_y = ges.pos.x, ges.pos.y
        self._last_x, self._last_y = ges.pos.x, ges.pos.y
        return true
    end
    return false
end

function ResizeHandle:onHoldPan(_, ges)
    if not self._resizing then
        return false
    end
    self._last_x, self._last_y = ges.pos.x, ges.pos.y
    return true
end

function ResizeHandle:onHoldRelease()
    if not self._resizing then
        return false
    end
    self._resizing = false
    if self.callback and self._last_x then
        self.callback(self._last_x - self._start_x, self._last_y - self._start_y)
    end
    self._start_x, self._start_y, self._last_x, self._last_y = nil, nil, nil, nil
    return true
end

--[[--
Movable, zoomable, resizable overlay for the pinned image. Wraps a
PannableImage (our own lightweight zoom/pan widget -- see
pannableimage.lua for why this doesn't reuse ImageViewer) plus small
always-visible Close (top-right) and resize-handle (bottom-right)
buttons, stacked via OverlapGroup, inside a MovableContainer, so the
whole thing can be dragged around on top of the current page without
navigating away from the reading position.

MovableContainer assumes its content doesn't change size while active
(its own doc comment), so resizing rebuilds the content (PannableImage
+ OverlapGroup + MovableContainer) at the new size on each resize-handle
release, rather than resizing anything in place -- see _buildMovableAt()
and _onResize().
Aspect ratio is preserved (matching the initial image-fit sizing done
in init()), and the panel's on-screen top-left corner is kept fixed
across a resize (it grows/shrinks toward the bottom-right, where the
handle is), by directly computing the new MovableContainer's
_moved_offset_x/y rather than relying on its own anchor mechanism
(which is designed for "pop up near this other widget", not "keep this
exact pixel position").
]]--
local PinnedImagePanel = WidgetContainer:extend{}

local MIN_PANEL_W = Screen:scaleBySize(150)
local MIN_PANEL_H = Screen:scaleBySize(150)

function PinnedImagePanel:init()
    -- Fit the panel to the image's own aspect ratio within an 80%x80%
    -- screen bounding box, instead of always using a fixed box regardless
    -- of shape -- otherwise a wide (or tall) image gets letterboxed with
    -- visible dead space inside the panel's own border.
    local max_w = math.floor(Screen:getWidth() * 0.8)
    local max_h = math.floor(Screen:getHeight() * 0.8)
    local panel_w, panel_h = max_w, max_h
    if self.image then
        -- self.image may not support getWidth/getHeight (e.g. a scalable
        -- SVG accessor function) -- pcall rather than guess its exact type.
        local ok, img_w, img_h = pcall(function()
            return self.image:getWidth(), self.image:getHeight()
        end)
        if ok and img_w and img_h and img_w > 0 and img_h > 0 then
            local scale = math.min(max_w / img_w, max_h / img_h)
            panel_w = math.floor(img_w * scale)
            panel_h = math.floor(img_h * scale)
        end
    end
    self._aspect_ratio = panel_w / panel_h

    local movable = self:_buildMovableAt(panel_w, panel_h)
    -- Centered starting position; from there it's user-draggable (hold + pan).
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        movable,
    }
end

-- Builds a fresh PannableImage + Close/Resize buttons + MovableContainer
-- at the given size. If moved_offset is given, the new MovableContainer
-- is positioned so its top-left lands at that exact absolute (x, y)
-- rather than wherever CenterContainer would otherwise center it.
function PinnedImagePanel:_buildMovableAt(panel_w, panel_h, moved_offset)
    local panel = self

    self.pannable_image = PannableImage:new{
        image = self.image,
        width = panel_w,
        height = panel_h,
        on_change = function()
            -- PannableImage's zoom-driven re-render swaps in a new inner
            -- widget, which needs an explicit repaint -- unlike panning,
            -- which schedules its own via ImageWidget's own
            -- setDirty("all", ...). Use the widget actually on
            -- UIManager's window stack (this panel), not the nested one.
            UIManager:setDirty(panel, "ui")
        end,
    }

    self.close_button = CloseButton:new{
        callback = function()
            UIManager:close(panel)
        end,
    }

    self.resize_handle = ResizeHandle:new{
        overlap_offset = { panel_w - Screen:scaleBySize(28), panel_h - Screen:scaleBySize(28) },
        callback = function(dw, dh)
            panel:_onResize(dw, dh)
        end,
    }

    self.overlap = OverlapGroup:new{
        dimen = Geom:new{ w = panel_w, h = panel_h },
        self.pannable_image,
        self.close_button,
        self.resize_handle,
    }

    self.movable = MovableContainer:new{
        self.overlap,
    }
    if moved_offset then
        self.movable._moved_offset_x = moved_offset.x
        self.movable._moved_offset_y = moved_offset.y
    end

    self._panel_w, self._panel_h = panel_w, panel_h
    return self.movable
end

function PinnedImagePanel:_onResize(dw, dh)
    -- Preserve the current top-left corner; grow/shrink toward the
    -- bottom-right, where the handle lives.
    local old_x = self.movable.dimen and self.movable.dimen.x
    local old_y = self.movable.dimen and self.movable.dimen.y

    local new_w = self._panel_w + dw
    new_w = math.max(MIN_PANEL_W, math.min(new_w, Screen:getWidth()))
    local new_h = math.floor(new_w / self._aspect_ratio)
    if new_h < MIN_PANEL_H then
        new_h = MIN_PANEL_H
        new_w = math.floor(new_h * self._aspect_ratio)
    elseif new_h > Screen:getHeight() then
        new_h = Screen:getHeight()
        new_w = math.floor(new_h * self._aspect_ratio)
    end

    local moved_offset
    if old_x and old_y then
        local new_base_x = math.floor((Screen:getWidth() - new_w) / 2)
        local new_base_y = math.floor((Screen:getHeight() - new_h) / 2)
        moved_offset = { x = old_x - new_base_x, y = old_y - new_base_y }
    end

    self[1][1] = self:_buildMovableAt(new_w, new_h, moved_offset)
    UIManager:setDirty(self, "ui")
end

return PinnedImagePanel
