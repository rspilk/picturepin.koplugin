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

-- Shared tap-target size for the two corner drag handles (Close stays
-- smaller -- it's a single tap, not something you have to land a drag
-- start on).
local HANDLE_ICON_SIZE = Screen:scaleBySize(36)

-- ges.relative is cumulative since gesture start, so ges.pos - ges.relative
-- is that gesture's origin point -- constant across every tick of a Pan,
-- unlike ges.pos itself. Needed because "pan" (unlike "hold") fires under
-- the same event name on every tick, including the first -- see
-- MoveHandle's own comment for the full explanation.
local function gestureOrigin(ges)
    return Geom:new{
        x = ges.pos.x - ges.relative.x,
        y = ges.pos.y - ges.relative.y,
        w = 0, h = 0,
    }
end

-- Small always-visible resize handle, bottom-right corner (via
-- overlap_offset, since OverlapGroup's overlap_align only directly
-- supports horizontal left/right/center). Claims Pan/PanRelease, the
-- same raw gesture type PannableImage wants for image panning when
-- zoomed in -- since children are tried before their container
-- (confirmed empirically while fixing the panel's own drag earlier),
-- and PannableImage is tried before this handle (array order in
-- _buildMovableAt), PannableImage would otherwise win any pan
-- originating here. It explicitly declines over this handle's own area
-- (via exclude_widgets, set in _buildMovableAt, checked against the
-- gesture's origin -- see gestureOrigin above).
--
-- Continuation state ("am I mid-resize") lives on `self.panel` (a
-- required field, the owning PinnedImagePanel), NOT on this widget
-- instance -- unlike MoveHandle's self._moving. _onResize rebuilds the
-- *entire* subtree (PannableImage/CloseButton/ResizeHandle/MoveHandle/
-- OverlapGroup/MovableContainer, see _buildMovableAt) on every live
-- resize tick, to get the image re-rendered at the new size -- which
-- means THIS VERY INSTANCE gets discarded and replaced partway through
-- a single drag. A brand-new instance starting from self._resizing =
-- false would re-run the origin-bounds check against its own (now
-- moved, since the panel just resized) dimen and almost always fail,
-- silently dropping the gesture after one tick. panel._resizing/
-- panel._resize_last_x/y survive the rebuild because the panel itself
-- is never recreated, only its children.
local ResizeHandle = InputContainer:extend{
    panel = nil, -- required
    callback = nil, -- called with (dw, dh) on every live drag tick
}

function ResizeHandle:init()
    self.icon_size = HANDLE_ICON_SIZE
    self.icon = IconWidget:new{
        icon = "control.expand",
        width = self.icon_size,
        height = self.icon_size,
    }
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        -- A fast/straight-enough release can get classified as a swipe
        -- instead of pan_release -- see onSwipe below for why we need to
        -- catch that too.
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

function ResizeHandle:getSize()
    return Geom:new{ w = self.icon_size, h = self.icon_size }
end

function ResizeHandle:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.icon_size, h = self.icon_size }
    self.icon:paintTo(bb, x, y)
end

function ResizeHandle:onPan(_, ges)
    local panel = self.panel
    if not panel._resizing then
        if not (self.dimen and gestureOrigin(ges):intersectWith(self.dimen)) then
            return false
        end
        panel._resizing = true
        panel._resize_last_x, panel._resize_last_y = ges.pos.x, ges.pos.y
        return true
    end
    -- Applied immediately on every tick, not accumulated for onPanRelease,
    -- so the resize tracks the finger/cursor live during the drag.
    local dx = ges.pos.x - panel._resize_last_x
    local dy = ges.pos.y - panel._resize_last_y
    if (dx ~= 0 or dy ~= 0) and self.callback then
        self.callback(dx, dy)
        panel._resize_last_x, panel._resize_last_y = ges.pos.x, ges.pos.y
    end
    return true
end

function ResizeHandle:onPanRelease()
    local panel = self.panel
    if not panel._resizing then
        return false
    end
    panel._resizing = false
    panel._resize_last_x, panel._resize_last_y = nil, nil
    return true
end

-- A quick, fairly straight-line release (letting go while still moving)
-- gets classified by the gesture detector as a "swipe" instead of firing
-- "pan_release" at all -- confirmed via emulator log during testing.
-- Without this, panel._resizing would get stuck true forever, since
-- nothing else would ever clear it, and the *next* unrelated touch
-- landing on ResizeHandle would skip straight to the "continuation"
-- branch of onPan using stale coordinates. Swipe's own pos field is the
-- gesture's *start* point, not something useful for one final resize
-- step, so just treat it as an implicit release rather than trying to
-- apply it.
function ResizeHandle:onSwipe()
    local panel = self.panel
    if not panel._resizing then
        return false
    end
    panel._resizing = false
    panel._resize_last_x, panel._resize_last_y = nil, nil
    return true
end

-- Small always-visible move handle, top-left corner (OverlapGroup's
-- default alignment -- no overlap_offset needed, unlike the other two
-- corners). Dedicated hit target for repositioning the whole panel,
-- replacing an earlier Hold-vs-quick-Pan gesture split between
-- PannableImage and MovableContainer: almost any real drag (mouse or
-- finger) has enough dwell to register as Hold rather than a bare Pan,
-- so "hold anywhere on the image and drag" never reliably meant "move
-- the panel" in the first place. Now that moving and resizing each have
-- their own dedicated corner, all three (this, ResizeHandle,
-- PannableImage) claim plain Pan/PanRelease instead, so there's no
-- dwell delay before a drag takes effect -- see pannableimage.lua's own
-- comment for why Pan needs the origin-based (not live-position-based)
-- ownership check below, unlike Hold. MovableContainer's own
-- gesture-based move is disabled entirely (ignore_events, set in
-- _buildMovableAt) -- this handle drives its position directly instead,
-- live on every drag tick (see onPan/_onMove), not just once on release.
--
-- Unlike ResizeHandle, self._moving/self._last_x/y are safe to keep on
-- this instance: _onMove only mutates the existing MovableContainer's
-- offset in place (see PinnedImagePanel:_onMove), it never rebuilds the
-- subtree, so this widget is never discarded mid-drag the way
-- ResizeHandle's is.
local MoveHandle = InputContainer:extend{
    icon_file = nil, -- required: absolute path to the bundled move icon
    callback = nil, -- called with (dx, dy) on every live drag tick
}

function MoveHandle:init()
    self.icon_size = HANDLE_ICON_SIZE
    self.icon = IconWidget:new{
        file = self.icon_file,
        width = self.icon_size,
        height = self.icon_size,
    }
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        -- See ResizeHandle:onSwipe -- same fast-release-classified-as-
        -- swipe gap applies here.
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

function MoveHandle:getSize()
    return Geom:new{ w = self.icon_size, h = self.icon_size }
end

function MoveHandle:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.icon_size, h = self.icon_size }
    self.icon:paintTo(bb, x, y)
end

function MoveHandle:onPan(_, ges)
    if not self._moving then
        if not (self.dimen and gestureOrigin(ges):intersectWith(self.dimen)) then
            return false
        end
        self._moving = true
        self._last_x, self._last_y = ges.pos.x, ges.pos.y
        return true
    end
    local dx = ges.pos.x - self._last_x
    local dy = ges.pos.y - self._last_y
    if (dx ~= 0 or dy ~= 0) and self.callback then
        self.callback(dx, dy)
        self._last_x, self._last_y = ges.pos.x, ges.pos.y
    end
    return true
end

-- See ResizeHandle:onSwipe for why this is needed -- without it,
-- self._moving could get stuck true (this instance persists across many
-- gestures, unlike ResizeHandle's), corrupting the next drag anywhere on
-- this handle.
function MoveHandle:onSwipe()
    if not self._moving then
        return false
    end
    self._moving = false
    self._last_x, self._last_y = nil, nil
    return true
end

function MoveHandle:onPanRelease()
    if not self._moving then
        return false
    end
    self._moving = false
    self._last_x, self._last_y = nil, nil
    return true
end

--[[--
Movable, zoomable, resizable overlay for the pinned image. Wraps a
PannableImage (our own lightweight zoom/pan widget -- see
pannableimage.lua for why this doesn't reuse ImageViewer) plus small
always-visible Close (top-right) and resize-handle (bottom-right)
buttons plus a Move handle (top-left), stacked via OverlapGroup, inside
a MovableContainer, so the whole thing can be dragged around on top of
the current page without navigating away from the reading position.

Panning the image (PannableImage, once zoomed in) and moving the panel
(MoveHandle) are deliberately separate hit targets, not a gesture-type
split on the same area -- see MoveHandle's own comment for why an
earlier Hold-vs-quick-Pan split between PannableImage and
MovableContainer didn't hold up. MovableContainer's own gesture-based
move is disabled (ignore_events, set in _buildMovableAt); MoveHandle
drives its position directly instead.

MovableContainer assumes its content doesn't change size while active
(its own doc comment), so resizing rebuilds the content (PannableImage
+ OverlapGroup + MovableContainer) at the new size on every resize-drag
tick (live, not just once on release), rather than resizing anything in
place -- see _buildMovableAt() and _onResize(). Rebuilding on every tick
re-decodes/rescales the image each time, so a live resize is more work
per frame than a live move or pan; worth watching for lag on slower
hardware.
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
    -- Centered starting position; from there it's user-draggable via
    -- MoveHandle (top-left corner).
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
        on_change = function(shrinking)
            -- PannableImage's zoom-driven re-render swaps in a new inner
            -- widget, which needs an explicit repaint -- unlike panning,
            -- which schedules its own via ImageWidget's own
            -- setDirty("all", ...).
            if shrinking then
                -- Zooming out shrinks the image inside this same fixed-
                -- size panel box, so "all" is needed here (not just
                -- setDirty(panel, ...)): dirtying only the panel repaints
                -- *it*, but not the reader page underneath, leaving the
                -- newly-exposed gap around the smaller image as a stale,
                -- unrefreshed ghost of whatever was there before -- same
                -- class of bug as the resize ghost fixed in _onResize,
                -- just inside the panel's bounds instead of at its edge.
                UIManager:setDirty("all", function()
                    return "ui", panel.movable.dimen
                end)
            else
                -- Growing never exposes a gap (the image only ever fills
                -- more of the same fixed box), so the cheaper
                -- panel-only repaint is enough here -- important for
                -- keeping a live pinch responsive, since this fires on
                -- every single gesture tick and "all" forces a full
                -- reader-page repaint underneath on top of our own,
                -- repeatedly, which a fast real pinch can easily
                -- outrun (ticks pile up and only resolve once released).
                UIManager:setDirty(panel, "ui")
            end
        end,
    }

    self.close_button = CloseButton:new{
        callback = function()
            UIManager:close(panel)
        end,
    }

    self.resize_handle = ResizeHandle:new{
        panel = panel,
        overlap_offset = { panel_w - HANDLE_ICON_SIZE, panel_h - HANDLE_ICON_SIZE },
        callback = function(dw, dh)
            panel:_onResize(dw, dh)
        end,
    }

    self.move_handle = MoveHandle:new{
        icon_file = self.plugin_path .. "/icons/move.svg",
        callback = function(dx, dy)
            panel:_onMove(dx, dy)
        end,
    }

    self.overlap = OverlapGroup:new{
        dimen = Geom:new{ w = panel_w, h = panel_h },
        self.pannable_image,
        self.close_button,
        self.resize_handle,
        self.move_handle,
    }

    -- Let PannableImage decline Pan gestures originating on these corner
    -- icons -- it's tried first in dispatch order (array index 1 above)
    -- but doesn't know its siblings' bounds on its own.
    self.pannable_image.exclude_widgets = { self.close_button, self.resize_handle, self.move_handle }

    self.movable = MovableContainer:new{
        -- Movement is driven entirely by MoveHandle now (see its own
        -- comment) -- disable MovableContainer's own gesture-based move
        -- so it can't compete with PannableImage's Pan-based image
        -- panning over the rest of the panel.
        ignore_events = { "touch", "hold", "hold_pan", "hold_release", "pan", "pan_release", "swipe" },
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
    -- Capture the pre-resize footprint. When shrinking, the vacated strip
    -- (old footprint minus new footprint) needs to be told to repaint too,
    -- or it's left as a stale, unrefreshed ghost -- mirroring
    -- MovableContainer's own _moveBy, which does the same for drag moves.
    local orig_dimen = self.movable.dimen and self.movable.dimen:copy()

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

    -- "all" so the page content underneath also redraws (not just this
    -- panel), scoped to the combined old+new region rather than a full-
    -- screen flash. The region is computed lazily so it picks up the new
    -- movable's dimen only after it's actually been painted.
    local panel = self
    UIManager:setDirty("all", function()
        local update_region = panel.movable.dimen
        if orig_dimen then
            update_region = orig_dimen:combine(update_region)
        end
        return "ui", update_region
    end)
end

-- Applied immediately on every drag tick (see MoveHandle:onPan),
-- not accumulated for a single call on release, so the panel tracks the
-- finger/cursor live -- same idea as PannableImage's live image panning.
-- Mutates the *existing* MovableContainer's offset directly (unlike
-- _onResize, which rebuilds one at a new size) since moving doesn't
-- change content size, just position.
function PinnedImagePanel:_onMove(dx, dy)
    local orig_dimen = self.movable.dimen and self.movable.dimen:copy()
    local offset = self.movable:getMovedOffset()
    self.movable:setMovedOffset{ x = offset.x + dx, y = offset.y + dy }

    -- Same "all" + combined old/new region approach as _onResize, so the
    -- vacated strip the panel is moving away from gets repainted too.
    local panel = self
    UIManager:setDirty("all", function()
        local update_region = panel.movable.dimen
        if orig_dimen then
            update_region = orig_dimen:combine(update_region)
        end
        return "ui", update_region
    end)
end

return PinnedImagePanel
