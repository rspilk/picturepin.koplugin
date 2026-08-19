local Device = require("device")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

--[[--
Small persistent icon shown once an image is pinned. Painted via
ReaderView:registerViewModule() (so it appears on every page without any
changes to core reader files) rather than inserted directly into
ReaderView's own child list like ReaderDogear -- that direct-insertion
approach is reserved for modules readerview.lua itself owns.

Structurally modeled on frontend/apps/reader/modules/readerdogear.lua
(IconWidget in a corner container), but fixed-position (top-left,
opposite the reading-progress dogear) rather than draggable, and without
dogear's page-margin-avoidance logic -- accepted MVP simplification (see
plugins/picturepin.koplugin/SPEC.md).
]]--
local PicturePinIcon = WidgetContainer:extend{
    visible = false,
}

function PicturePinIcon:init()
    -- Deliberately bigger than the read-only dogear bookmark icon (1/32):
    -- this one is an active tap target, not just a status indicator, so
    -- it needs a comfortably tappable size.
    self.icon_size = math.ceil(math.min(Screen:getWidth(), Screen:getHeight()) * (1/16))
    self.icon = IconWidget:new{
        icon = "appbar.pageview",
        width = self.icon_size,
        height = self.icon_size,
        alpha = true,
    }
    self[1] = LeftContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = self.icon_size },
        self.icon,
    }
end

function PicturePinIcon:resetLayout()
    self[1].dimen.w = Screen:getWidth()
end

function PicturePinIcon:paintTo(bb, x, y)
    if self.visible then
        WidgetContainer.paintTo(self, bb, x, y)
    end
end

return PicturePinIcon
