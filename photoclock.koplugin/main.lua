--[[
Photo clock for KOReader.

Shows a full-screen image that changes every IMAGE_INTERVAL_MIN minutes, with
the time and date (updated every minute) in a box on top of it. Optionally
lists upcoming meetings read from meetings.txt.

Open:  Tools menu (wrench icon) -> Photo clock
Tap:   skip to the next image
Hold:  close
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- ---------------------------------------------------------------- settings
local IMAGE_INTERVAL_MIN = 10     -- change image when minute % this == 0
local FULL_REFRESH_EVERY = 1      -- flash the screen every N image changes to clear ghosting
local SHUFFLE = true              -- random order instead of alphabetical
local BOX_TOP = 40                -- gap between screen top and the clock box
local MAX_MEETINGS = 4
local USE_12H = true

-- On Kindle this is the USB-visible root, so the folder shows up as
-- "photoclock" when you plug the Kindle into a computer.
local BASE_DIR = Device:isKindle() and "/mnt/us/photoclock"
    or DataStorage:getDataDir() .. "/photoclock"
local IMAGE_DIR = BASE_DIR .. "/images"
local MEETINGS_FILE = BASE_DIR .. "/meetings.txt"

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, bmp = true }

-- ----------------------------------------------------------------- helpers
local function listImages()
    local files = {}
    if lfs.attributes(IMAGE_DIR, "mode") ~= "directory" then
        return files
    end
    for name in lfs.dir(IMAGE_DIR) do
        local ext = name:match("%.([^.]+)$")
        if ext and IMAGE_EXTS[ext:lower()] and not name:match("^%.") then
            table.insert(files, IMAGE_DIR .. "/" .. name)
        end
    end
    table.sort(files)
    return files
end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function formatTime(t)
    if USE_12H then
        local h = t.hour % 12
        if h == 0 then h = 12 end
        return string.format("%d:%02d", h, t.min)
    end
    return string.format("%02d:%02d", t.hour, t.min)
end

-- Reads meetings.txt. Lines starting with HH:MM (24h) are hidden once that
-- time has passed; any other non-empty line is always shown. "#" = comment.
local function readMeetings(now)
    local f = io.open(MEETINGS_FILE, "r")
    if not f then return {} end
    local now_min = now.hour * 60 + now.min
    local out = {}
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            local h, m = line:match("^(%d%d?):(%d%d)")
            if not h or tonumber(h) * 60 + tonumber(m) >= now_min then
                table.insert(out, line)
            end
        end
    end
    f:close()
    return out
end

local function freeWidget(w)
    -- Not every widget has free() (e.g. VerticalSpan).
    if w and w.free then w:free() end
end

-- ------------------------------------------------------------ clock screen
local ClockScreen = InputContainer:extend{
    covers_fullscreen = true,
}

function ClockScreen:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    if Device:isTouchDevice() then
        self.ges_events = {
            TapNext = { GestureRange:new{ ges = "tap", range = self.dimen } },
            HoldClose = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end

    self.time_face = Font:getFace("tfont", 72)
    self.date_face = Font:getFace("cfont", 22)
    self.meet_face = Font:getFace("cfont", 18)

    self.queue = {}
    self.image_changes = 0
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalSpan:new{ width = 0 },
    }
    -- Image underneath, clock box on top (children paint in order).
    self.layers = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self.image_container,
        VerticalSpan:new{ width = 0 },
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.layers,
    }

    self.tick_fn = function() self:onTick() end

    -- Keep the Kindle's own power manager from sleeping/showing its screensaver.
    -- KOReader normally does this already; this is belt and braces.
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1")
    end

    self:buildClockBox()
    self:loadNextImage()
    self:scheduleTick()
end

-- Rebuilds the clock box and returns the screen area that needs repainting
-- (old and new box together, since the box can change size).
function ClockScreen:buildClockBox()
    local now = os.date("*t")
    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = formatTime(now), face = self.time_face },
        TextWidget:new{ text = os.date("%A, %B ") .. now.day, face = self.date_face },
    }
    local meetings = readMeetings(now)
    if #meetings > 0 then
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(group, TextWidget:new{ text = _("Upcoming meetings:"), face = self.meet_face, bold = true })
        for i = 1, math.min(#meetings, MAX_MEETINGS) do
            table.insert(group, TextWidget:new{
                text = meetings[i],
                face = self.meet_face,
                max_width = self.width - Screen:scaleBySize(80),
            })
        end
    end

    local box = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(12),
        padding = Screen:scaleBySize(8),
        padding_left = Screen:scaleBySize(24),
        padding_right = Screen:scaleBySize(24),
        group,
    }
    local size = box:getSize()
    local rect = Geom:new{
        x = math.floor((self.width - size.w) / 2),
        y = Screen:scaleBySize(BOX_TOP),
        w = size.w,
        h = size.h,
    }
    box.overlap_offset = { rect.x, rect.y }

    freeWidget(self.layers[2])
    self.layers[2] = box

    local dirty = self.box_rect and rect:combine(self.box_rect) or rect
    self.box_rect = rect
    return dirty
end

function ClockScreen:loadNextImage()
    if #self.queue == 0 then
        -- Rescan each cycle so newly copied images are picked up.
        self.queue = listImages()
        if SHUFFLE then shuffle(self.queue) end
    end
    local path = table.remove(self.queue, 1)

    local old = self.image_container[1]
    if path then
        self.image_container[1] = ImageWidget:new{
            file = path,
            file_do_cache = false,
            width = self.width,
            height = self.height,
            scale_factor = 0, -- fit inside width/height, keep aspect ratio
        }
    else
        self.image_container[1] = TextWidget:new{
            text = _("No images in ") .. IMAGE_DIR,
            face = self.meet_face,
        }
    end
    freeWidget(old)
    self.image_changes = self.image_changes + 1
    logger.dbg("photoclock: showing", path)
end

-- Repaint after an image change: flash every FULL_REFRESH_EVERY changes to
-- clear e-ink ghosting, otherwise a non-flashing refresh.
function ClockScreen:refreshImage()
    if self.image_changes % FULL_REFRESH_EVERY == 0 then
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(self, "partial")
    end
end

function ClockScreen:scheduleTick()
    UIManager:unschedule(self.tick_fn)
    -- Fire right after the next minute boundary.
    UIManager:scheduleIn(60 - os.date("*t").sec, self.tick_fn)
end

function ClockScreen:onTick()
    local dirty = self:buildClockBox()
    if os.date("*t").min % IMAGE_INTERVAL_MIN == 0 then
        self:loadNextImage()
        self:refreshImage()
    else
        -- Only the clock box changed: refresh just that area, no flash.
        UIManager:setDirty(self, function() return "ui", dirty end)
    end
    self:scheduleTick()
end

function ClockScreen:onShow()
    UIManager:setDirty(self, "full")
end

-- After the device wakes up, the clock is stale and the timer may have drifted.
function ClockScreen:onResume()
    self:buildClockBox()
    UIManager:setDirty(self, "full")
    self:scheduleTick()
end

function ClockScreen:onSuspend()
    UIManager:unschedule(self.tick_fn)
end

function ClockScreen:onTapNext()
    self:buildClockBox()
    self:loadNextImage()
    self:refreshImage()
    return true
end

function ClockScreen:onHoldClose()
    UIManager:close(self)
    return true
end
ClockScreen.onClose = ClockScreen.onHoldClose

function ClockScreen:onCloseWidget()
    UIManager:unschedule(self.tick_fn)
    UIManager:setDirty(nil, "full")
end

-- ------------------------------------------------------------------ plugin
local PhotoClock = WidgetContainer:extend{
    name = "photoclock",
    is_doc_only = false,
}

function PhotoClock:init()
    math.randomseed(os.time())
    self.ui.menu:registerToMainMenu(self)
end

function PhotoClock:addToMainMenu(menu_items)
    menu_items.photoclock = {
        text = _("Photo clock"),
        sorting_hint = "tools",
        callback = function()
            UIManager:show(ClockScreen:new{})
        end,
    }
end

return PhotoClock
