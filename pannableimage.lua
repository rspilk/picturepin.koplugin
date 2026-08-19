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

Panning claims plain Pan/PanRelease (an earlier version claimed Hold/
HoldPan/HoldRelease instead, to disambiguate from the parent panel's
own drag-to-move -- dropped once the panel got its own dedicated
MoveHandle/ResizeHandle hit targets, making a gesture-type split
unnecessary; see pinnedimagepanel.lua's own comment).

Pan needs more care than Hold did: "hold" only ever fires once, at the
true start of a gesture, so a widget can decide "is this mine?" a
single time and remember the answer. "pan" fires under the *same* event
name on every tick, start included -- so onPan can't just re-check the
*current* gesture position against exclude_widgets/zoom state on every
tick, or a drag that starts over an excluded corner icon and drifts
over the image mid-gesture would get reclaimed by the image partway
through. Instead, the very first time a given gesture is seen
(self._panning still false), the decision is made from the gesture's
*origin* -- computed as ges.pos - ges.relative, which stays constant
across every tick of the same gesture (ges.relative is cumulative since
gesture start) -- and then remembered via self._panning for the rest of
that gesture, exactly as MovableContainer's own _touch_pre_pan_was_inside
does for its own Pan-based move.

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
    -- Sibling widgets (e.g. the panel's Close/Resize/Move corner icons)
    -- that should keep first refusal on Pan gestures *originating* on
    -- them, even though we're tried first in dispatch order (see
    -- pinnedimagepanel.lua).
    exclude_widgets = nil,
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

function PannableImage:_isExcluded(pos)
    if not self.exclude_widgets then
        return false
    end
    for _, w in ipairs(self.exclude_widgets) do
        if w.dimen and pos:intersectWith(w.dimen) then
            return true
        end
    end
    return false
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
        -- Baseline "fit to footprint" factor, kept even as self.scale_factor
        -- changes with zoom -- lets onPan tell "not zoomed, nothing to pan"
        -- apart from "zoomed in, this drag should pan".
        self._fit_scale_factor = self.scale_factor
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

-- ges.relative is cumulative since gesture start, so ges.pos - ges.relative
-- is that gesture's origin point -- constant across every tick, unlike
-- ges.pos itself (see the class comment for why that matters here).
local function gestureOrigin(ges)
    return Geom:new{
        x = ges.pos.x - ges.relative.x,
        y = ges.pos.y - ges.relative.y,
        w = 0, h = 0,
    }
end

function PannableImage:onPan(_, ges)
    if not self._image_wg then return false end
    if not self._panning then
        -- First tick of a new gesture: decide from its origin, not its
        -- (possibly already-drifted) current position -- see class comment.
        if self:_isExcluded(gestureOrigin(ges)) then return false end
        self:_refreshScaleFactor()
        if self.scale_factor <= self._fit_scale_factor then
            -- Not zoomed in -- nothing to pan, so decline.
            return false
        end
        self._panning = true
        self._pan_last_x, self._pan_last_y = ges.pos.x, ges.pos.y
        return true
    end
    -- Applied immediately on every tick, not accumulated for onPanRelease,
    -- so the image tracks the finger/cursor live during the drag.
    local dx = ges.pos.x - self._pan_last_x
    local dy = ges.pos.y - self._pan_last_y
    if dx ~= 0 or dy ~= 0 then
        self._image_wg:panBy(-dx, -dy)
        self._pan_last_x, self._pan_last_y = ges.pos.x, ges.pos.y
    end
    return true
end

function PannableImage:onPanRelease()
    if not self._panning then return false end
    self._panning = false
    self._pan_last_x, self._pan_last_y = nil, nil
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
