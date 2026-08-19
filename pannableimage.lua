local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = require("device").screen

--[[--
Lightweight zoomable/pannable image widget, sized and positioned as a
plain fixed-footprint widget from the start -- unlike
ui/widget/imageviewer.lua, which assumes it's shown fullscreen/near-
fullscreen and centers itself against the screen unconditionally.
Written for use inside a floating panel (e.g. wrapped in a
MovableContainer), where the parent decides size and position.

The zoom/pan math below is adapted from imageviewer.lua's onSpread/
onPinch/onPan/onPanRelease/_applyNewScaleFactor (credit to that
implementation) -- the one real adaptation is centerRatioForGesturePos,
which computes the zoom-center relative to *this widget's own* current
on-screen position, since imageviewer.lua's version assumes it's
always centered on the full screen.

Actual image decoding/scaling/panning is delegated to ImageWidget
(ui/widget/imagewidget.lua), a generic widget with no fullscreen
assumptions of its own -- reused here as-is, not reimplemented.
Notably, ImageWidget:panBy() already schedules its own repaint via
UIManager:setDirty("all", ...), which (unlike setDirty(self, ...))
works correctly regardless of nesting depth -- so panning needs no
extra repaint handling here. Changing zoom level, however, requires
swapping in a whole new ImageWidget instance, which does need an
explicit repaint afterwards: set `on_change` (a no-arg function) to
have the owning panel handle that using whatever widget is actually on
UIManager's window stack.
]]--
local PannableImage = InputContainer:extend{
    image = nil,
    width = nil,  -- fixed footprint size; our parent positions us
    height = nil,
    scale_factor = 0, -- 0 = fit to footprint
    on_change = nil, -- optional: called after a zoom-driven re-render
}

function PannableImage:init()
    self._center_x_ratio = 0.5
    self._center_y_ratio = 0.5
    self:_buildImageWidget()

    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Spread = { GestureRange:new{ ges = "spread", range = range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
    }
end

function PannableImage:_buildImageWidget()
    if self._image_wg then
        self._image_wg:free()
    end
    self._image_wg = ImageWidget:new{
        image = self.image,
        image_disposable = false, -- caller owns and reuses this bitmap
        width = self.width,
        height = self.height,
        scale_factor = self.scale_factor,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self._image_wg,
    }
end

function PannableImage:_refreshScaleFactor()
    if self.scale_factor == 0 then
        self.scale_factor = self._image_wg:getScaleFactor()
    end
end

function PannableImage:_applyNewScaleFactor(new_factor)
    self:_refreshScaleFactor()
    if not self._min_scale_factor or not self._max_scale_factor then
        self._min_scale_factor, self._max_scale_factor = self._image_wg:getScaleFactorExtrema()
    end
    new_factor = math.min(new_factor, self._max_scale_factor)
    new_factor = math.max(new_factor, self._min_scale_factor)
    if new_factor ~= self.scale_factor then
        self.scale_factor = new_factor
        self:_buildImageWidget()
        if self.on_change then
            self.on_change()
        end
    end
end

-- Gesture position (absolute screen coords) -> the center ratio we'd
-- get by panning there, relative to *this widget's own* current
-- position -- not the full screen, since we aren't necessarily
-- screen-centered (imageviewer.lua's version assumes it always is).
function PannableImage:_centerRatioForGesturePos(pos)
    if not self.dimen then
        return self._center_x_ratio, self._center_y_ratio
    end
    local center_x = self.dimen.x + self.dimen.w / 2
    local center_y = self.dimen.y + self.dimen.h / 2
    return self._image_wg:getPanByCenterRatio(pos.x - center_x, pos.y - center_y)
end

function PannableImage:onSpread(_, ges)
    if not self._image_wg then return false end
    self._center_x_ratio, self._center_y_ratio = self:_centerRatioForGesturePos(ges.pos)
    local img_d = self._image_wg:getCurrentDiagonal()
    local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
    self:_refreshScaleFactor()
    self:_applyNewScaleFactor(self.scale_factor * (1 + ges.distance / math.min(screen_d, img_d)))
    return true
end

function PannableImage:onPinch(_, ges)
    if not self._image_wg then return false end
    local img_d = self._image_wg:getCurrentDiagonal()
    local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
    self:_refreshScaleFactor()
    self:_applyNewScaleFactor(self.scale_factor * (1 - ges.distance / math.min(screen_d, img_d)))
    return true
end

function PannableImage:onPan(_, ges)
    self._panning = true
    self._pan_relative_x = ges.relative.x
    self._pan_relative_y = ges.relative.y
    return true
end

function PannableImage:onPanRelease()
    if self._panning and self._image_wg then
        self._panning = false
        self._image_wg:panBy(-self._pan_relative_x, -self._pan_relative_y)
    end
    return true
end

function PannableImage:paintTo(bb, x, y)
    if not self.dimen then
        self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    else
        self.dimen.x = x
        self.dimen.y = y
    end
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
end

function PannableImage:onCloseWidget()
    if self._image_wg then
        self._image_wg:free()
    end
end

return PannableImage
