-- EventHorizon Infall: stack gates.

-- A StatusBar ranged (X - 1, X) and fed the stack count is empty below X and full at
-- X or more. Clips anchored to its fill edge show or hide what they hold.
-- READ docs/stack-gate-plan.md before editing this file.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local TEX = "Interface\\AddOns\\EventHorizon_Infall\\Smooth"
local IND_TEX = "Interface\\Buttons\\WHITE8X8"
local MAX_BANDS = 3
local issecret = issecretvalue or function() return false end

-- Settings bump this on any gate or band edit, so rows rebuild without a reload.
ns.StackGate_Version = 0
function ns.StackGate_Bump()
    ns.StackGate_Version = (ns.StackGate_Version or 0) + 1
end

-- Whole numbers from 2 to 99, or nil for off.
function ns.StackGate_Threshold(v)
    if type(v) ~= "number" or v ~= v then return nil end
    v = math.floor(v + 0.5)
    if v < 2 then v = 2 elseif v > 99 then v = 99 end
    return v
end
local Threshold = ns.StackGate_Threshold

local ValidColour = ns.ValidColour

-- Sorted by threshold, duplicates dropped, at most three. Nil when none survive.
function ns.StackGate_Bands(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i = 1, math.min(#list, MAX_BANDS) do
        local b = list[i]
        local t = type(b) == "table" and Threshold(b.threshold) or nil
        if t and ValidColour(b.color) then
            out[#out + 1] = { threshold = t, color = b.color, order = i }
        end
    end
    table.sort(out, function(a, b)
        if a.threshold ~= b.threshold then return a.threshold < b.threshold end
        return a.order < b.order
    end)
    local n = 0
    for i = 1, #out do
        if n == 0 or out[i].threshold ~= out[n].threshold then
            n = n + 1
            out[n] = out[i]
        end
    end
    for i = #out, n + 1, -1 do out[i] = nil end
    return n > 0 and out or nil
end

-- Gate dim percent, 0 to 100, default 30.
function ns.StackGate_DimPercent(v)
    if type(v) ~= "number" or v ~= v then return 30 end
    v = math.floor(v + 0.5)
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    return v
end

local function Crisp(tex)
    if tex then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end

-- Rendered, never under an alpha zero parent: frame alpha 1, fill texture alpha 0.
local function NewIndicator(parent)
    local ind = CreateFrame("StatusBar", nil, parent)
    ind:SetStatusBarTexture(IND_TEX)
    ind:GetStatusBarTexture():SetAlpha(0)
    ind:SetOrientation("VERTICAL")
    ind:SetMinMaxValues(0, 1)
    ind:SetValue(0)
    ind:SetAlpha(1)
    Crisp(ind:GetStatusBarTexture())
    return ind
end

local function NewClip(parent)
    local clip = CreateFrame("Frame", nil, parent)
    clip:SetClipsChildren(true)
    return clip
end

-- Full height at X or more stacks, nothing below.
local function AnchorAtOrAbove(clip, ind)
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", ind:GetStatusBarTexture(), "TOPLEFT")
    clip:SetPoint("BOTTOMRIGHT", ind, "BOTTOMRIGHT")
end

-- Full height below X stacks, nothing at X or more.
local function AnchorBelow(clip, ind)
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", ind, "TOPLEFT")
    clip:SetPoint("BOTTOMRIGHT", ind:GetStatusBarTexture(), "TOPRIGHT")
end

local function SetRange(ind, x)
    ind:SetMinMaxValues(x - 1, x)
end

local function Feed(ind, count)
    if count == nil then count = 0 end
    ind:SetValue(count)
end

-- One indicator driving two clips. The region is what the indicator covers;
-- callers put the real widget in .above and any dim copy in .below.
local function NewPair(parent, region)
    local p = {}
    p.ind = NewIndicator(parent)
    p.ind:SetAllPoints(region)
    p.above = NewClip(parent)
    p.below = NewClip(parent)
    p.region = region
    p.parent = parent
    return p
end

-- Ungated: the above clip spans its parent and clips nothing.
local function PairOpen(p)
    p.ind:SetValue(0)
    p.ind:Hide()
    p.above:SetClipsChildren(false)
    p.above:ClearAllPoints()
    p.above:SetAllPoints(p.parent)
    p.above:Show()
    p.below:Hide()
    p.x = nil
end

local function PairGate(p, x, useBelow)
    if p.x ~= x then
        SetRange(p.ind, x)
        p.x = x
    end
    p.ind:Show()
    p.above:SetClipsChildren(true)
    AnchorAtOrAbove(p.above, p.ind)
    p.above:Show()
    if useBelow then
        AnchorBelow(p.below, p.ind)
        p.below:Show()
    else
        p.below:Hide()
    end
end

-- Past segments are hidden, never zeroed. Everything else returns to ungated.
function ns.StackGate_Reset(row)
    local lanes = row._sgLane
    if lanes then
        for l = 1, 3 do
            local s = lanes[l]
            if s then
                if s.pair then PairOpen(s.pair) end
                if s.dim then s.dim:Hide() end
                s.gated, s.x, s.mode, s.dimP, s.dimOn = false, nil, nil, nil, false
                s.count, s.cdID, s.mark, s.plain, s.cut = 0, nil, nil, nil, false
                s.open, s.live = nil, 0
                if s.segs then
                    for i = 1, #s.segs do
                        local seg = s.segs[i]
                        seg.active = false
                        seg.above:Hide()
                        seg.below:Hide()
                        seg.ind:Hide()
                    end
                end
            end
        end
    end
    local t = row._sgText
    if t then
        t.on, t.ver, t.shown = false, nil, false
        for i = 1, #t.inds do
            t.inds[i]:SetValue(0)
        end
        for i = 1, #t.fs do t.fs[i]:Hide() end
    end
end

-- Stack text colour bands. fs[1] shows below the first band, fs[i + 1] in band i.
-- Band i clips between indicator i's fill top and indicator i + 1's, so only one shows.

local function BuildText(row, bands)
    local t = row._sgText
    if not t then
        t = { inds = {}, clips = {}, fs = {} }
        t.box = CreateFrame("Frame", nil, row.textOverlay)
        row._sgText = t
    end
    for i = 1, MAX_BANDS do
        if not t.inds[i] then
            t.inds[i] = NewIndicator(t.box)
            t.inds[i]:SetAllPoints(t.box)
        end
    end
    for i = 1, MAX_BANDS + 1 do
        if not t.clips[i] then
            t.clips[i] = NewClip(t.box)
            t.fs[i] = t.clips[i]:CreateFontString(nil, "OVERLAY")
            t.fs[i]:Hide()
        end
    end
    local k = #bands
    for i = 1, MAX_BANDS do
        if i <= k then
            SetRange(t.inds[i], bands[i].threshold)
            t.inds[i]:SetValue(0)
            t.inds[i]:Show()
        else
            t.inds[i]:Hide()
        end
    end
    AnchorBelow(t.clips[1], t.inds[1])
    t.clips[1]:Show()
    for i = 1, k do
        local c = t.clips[i + 1]
        if i < k then
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", t.inds[i]:GetStatusBarTexture(), "TOPLEFT")
            c:SetPoint("BOTTOMRIGHT", t.inds[i + 1]:GetStatusBarTexture(), "TOPRIGHT")
        else
            AnchorAtOrAbove(c, t.inds[i])
        end
        c:Show()
    end
    for i = k + 2, MAX_BANDS + 1 do
        t.clips[i]:Hide()
        t.fs[i]:Hide()
    end
    t.bands, t.k, t.shown = bands, k, false
    t.box:Show()
end

-- Font, shadow and anchor copied from the plain stack text. The box is a fixed size:
-- secret text cannot be measured, so it covers the font, outline, shadow and offsets.
function ns.StackGate_TextLayout(row, home)
    local t = row._sgText
    local st = row.stackText
    if not t or not st then return end
    home = home or t.home or (CONFIG.hideIcons and row.barTextOverlay) or row.textOverlay
    t.home = home
    local face, size, flags = st:GetFont()
    size = size or CONFIG.fontSize or 12
    local sx, sy = st:GetShadowOffset()
    sx, sy = sx or 0, sy or 0
    local sr, sg, sb, sa = st:GetShadowColor()
    local a = CONFIG.stackTextAnchor or "CENTER"
    local rel = CONFIG.stackTextRelPoint or a
    local ox, oy = CONFIG.stackTextOffsetX or 0, CONFIG.stackTextOffsetY or 0
    for i = 1, #t.fs do
        local fs = t.fs[i]
        if face then fs:SetFont(face, size, flags) end
        fs:SetShadowOffset(sx, sy)
        if sr then fs:SetShadowColor(sr, sg, sb, sa or 1) end
        fs:SetJustifyH(st:GetJustifyH() or "CENTER")
        fs:ClearAllPoints()
        fs:SetPoint(a, home, rel, ox, oy)
    end
    local pad = math.max(4, math.ceil(size * 0.3)) + math.max(math.abs(sx), math.abs(sy))
    local dx = a:find("LEFT") and -pad or (a:find("RIGHT") and pad or 0)
    local dy = a:find("TOP") and pad or (a:find("BOTTOM") and -pad or 0)
    t.box:ClearAllPoints()
    t.box:SetSize(size * 3 + pad * 2, size * 1.5 + pad * 2)
    t.box:SetPoint(a, home, rel, ox + dx, oy + dy)
end

function ns.StackGate_HideText(row)
    local t = row._sgText
    if not t or not t.shown then return end
    for i = 1, #t.fs do t.fs[i]:Hide() end
    t.shown = false
end

-- True when the bands drew the count; false means the caller shows the plain text.
function ns.StackGate_Text(row, mapping, appVal)
    if not mapping or mapping.colorBands == nil then
        ns.StackGate_HideText(row)
        return false
    end
    local ver = ns.StackGate_Version
    local t = row._sgText
    if not (t and t.ver == ver and t.map == mapping) then
        local bands = ns.StackGate_Bands(mapping.colorBands)
        if bands then
            BuildText(row, bands)
            t = row._sgText
            ns.StackGate_TextLayout(row, nil)
            t.on = true
        elseif t then
            t.on = false
        end
        if t then t.ver, t.map = ver, mapping end
    end
    if not t or not t.on then
        ns.StackGate_HideText(row)
        return false
    end
    local base = mapping.color or CONFIG.stackTextColor
    for i = 1, t.k do t.inds[i]:SetValue(appVal) end
    local text = ns.TruncateZero and ns.TruncateZero(appVal) or appVal
    for i = 1, t.k + 1 do
        local fs = t.fs[i]
        local c = (i == 1) and base or t.bands[i - 1].color
        fs:SetText(text)
        fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
        fs:Show()
    end
    t.shown = true
    return true
end

-- A plain number needs no clips: the band colour is picked directly.
function ns.StackGate_TierColor(mapping, apps)
    local list = mapping and mapping.colorBands
    if type(list) ~= "table" or apps == nil or issecret(apps) then return nil end
    if type(apps) ~= "number" then return nil end
    local best, bestT
    for i = 1, math.min(#list, MAX_BANDS) do
        local b = list[i]
        local th = type(b) == "table" and Threshold(b.threshold) or nil
        if th and th <= apps and ValidColour(b.color) and (not bestT or th > bestT) then
            best, bestT = b.color, th
        end
    end
    return best
end

-- Buff lane gates. Each lane bar sits for good inside its pair's above clip, parented
-- to the row; a dim copy in the below clip draws under X when the slot asks for it.

local AC = ns.AuraCompat
local LANE_BARS = { "buffBar", "buffBarOverlay", "buffBarThird" }
local PAST_CLIPS = { "pastBuffClip", "pastOverlayClip", "pastThirdClip" }

-- cdID to a count only the SetAuraInstanceInfo hook moves. Never secret.
local auraSetMark = {}
function ns.StackGate_NoteAuraSet(cdID)
    if cdID == nil or issecret(cdID) then return end
    auraSetMark[cdID] = (auraSetMark[cdID] or 0) + 1
end

local function ApplyDimColour(s)
    if not s.cr then return end
    s.dim:SetStatusBarColor(s.cr, s.cg, s.cb, (s.ca or 1) * (s.dimP or 30) / 100)
end

-- The one place the dim copy follows its lane bar: every feed, colour and visibility.
local function InstallMirror(s, bar)
    local dim = s.dim
    hooksecurefunc(bar, "SetValue", function(_, v, interp) dim:SetValue(v, interp) end)
    hooksecurefunc(bar, "SetMinMaxValues", function(_, lo, hi) dim:SetMinMaxValues(lo, hi) end)
    hooksecurefunc(bar, "SetStatusBarColor", function(_, r, g, b, a)
        s.cr, s.cg, s.cb, s.ca = r, g, b, a
        ApplyDimColour(s)
    end)
    hooksecurefunc(bar, "Show", function() if s.dimOn then dim:Show() end end)
    hooksecurefunc(bar, "Hide", function() dim:Hide() end)
    hooksecurefunc(bar, "SetShown", function(_, v) dim:SetShown((v and s.dimOn) and true or false) end)
end

local function BarValue(bar) return bar:GetValue() end

local function EnsureLane(row, l)
    local lanes = row._sgLane
    local s = lanes and lanes[l]
    if s then return s end
    local bar = row[LANE_BARS[l]]
    if not bar then return nil end
    if not lanes then
        lanes = {}
        row._sgLane = lanes
    end
    s = { segs = {}, count = 0, gated = false, bar = bar, lane = l }
    s.pair = NewPair(row, bar)
    s.dim = CreateFrame("StatusBar", nil, s.pair.below)
    s.dim:SetStatusBarTexture(TEX)
    s.dim:SetOrientation("HORIZONTAL")
    local dt = s.dim:GetStatusBarTexture()
    dt:SetHorizTile(false)
    dt:SetVertTile(false)
    Crisp(dt)
    s.dim:SetAllPoints(bar)
    s.dim:SetMinMaxValues(bar:GetMinMaxValues())
    local okV, v = pcall(BarValue, bar)
    if okV and v ~= nil then s.dim:SetValue(v) end
    s.cr, s.cg, s.cb, s.ca = bar:GetStatusBarColor()
    s.dim:Hide()
    PairOpen(s.pair)
    bar:SetParent(s.pair.above)
    InstallMirror(s, bar)
    lanes[l] = s
    if ns.ApplyBuffLayer then ns.ApplyBuffLayer(row) end
    return s
end

-- Threshold, mode and dim percent for a pairing slot, or nil when the slot is ungated.
local function LaneConfig(mapData, row)
    if type(mapData) ~= "table" or mapData.customDuration or mapData.glowSource then return nil end
    if row and ns.IsCombatPotionEntry(row.spellID, row._equipSlot, row._spellCategoryID) then return nil end
    local x = Threshold(mapData.stackGate)
    if not x then return nil end
    local mode = (mapData.stackGateBelow == "dim") and "dim" or "hide"
    return x, mode, ns.StackGate_DimPercent(mapData.stackGateDim)
end
ns.StackGate_LaneConfig = LaneConfig

local function UngateLane(s)
    if not s.gated then return end
    PairOpen(s.pair)
    s.dimOn = false
    s.dim:Hide()
    s.gated, s.x, s.mode, s.dimP = false, nil, nil, nil
end

local function GateLane(s, x, mode, p)
    if s.gated and s.x == x and s.mode == mode and s.dimP == p then return end
    s.gated, s.x, s.mode, s.dimP = true, x, mode, p
    s.dimOn = mode == "dim"
    PairGate(s.pair, x, s.dimOn)
    ApplyDimColour(s)
    s.dim:SetShown(s.dimOn and s.bar:IsShown() or false)
end

local function TotemFields(f) return f.auraInstanceID, f.totemData end

-- Lanes with no stack count to read: totems, user timers, tier set timers, glow slots.
local function RouteUngated(e)
    if not e then return false end
    if e.timerDurObj or e.glowLane then return true end
    local f = e.frame
    if not f then return true end
    local ok, iid, td = pcall(TotemFields, f)
    return ok and iid == nil and td ~= nil
end

local function FrameCdID(f) return f.cooldownID end

local function FeedLane(s, e)
    local f = e and e.frame
    local count = 0
    if f then
        local c = AC.ReadApplications(f)
        if c ~= nil then count = c end
    end
    Feed(s.pair.ind, count)
    s.count = count
    local cdID
    if f then
        local ok, id = pcall(FrameCdID, f)
        if ok and id ~= nil and not issecret(id) then cdID = id end
    end
    local mark = cdID and auraSetMark[cdID] or 0
    if cdID ~= s.cdID or mark ~= s.mark then
        s.cut = true
        s.cdID, s.mark = cdID, mark
    end
    if issecret(count) then
        s.plain = nil
    elseif count ~= s.plain then
        s.cut = true
        s.plain = count
    end
end

-- Called from ConfigureBarForSpell: lanes are created here, never per frame.
function ns.StackGate_Configure(row, mappings, stackMapping)
    for l = 1, 3 do
        local x, mode, p = LaneConfig(mappings and mappings[l], row)
        local s = row._sgLane and row._sgLane[l]
        if x then
            s = s or EnsureLane(row, l)
            if s then GateLane(s, x, mode, p) end
        elseif s then
            UngateLane(s)
        end
    end
    if stackMapping and stackMapping.colorBands ~= nil and row.stackText then
        ns.StackGate_Text(row, stackMapping, 0)
        ns.StackGate_HideText(row)
    end
end

-- Fed from UpdateBuffState, after every lane has been decided.
function ns.StackGate_FeedLanes(row, mappings, e1, e2, e3, potion)
    local lanes = row._sgLane
    if not lanes and not mappings then return end
    for l = 1, 3 do
        local x, mode, p = LaneConfig(mappings and mappings[l], row)
        local s = lanes and lanes[l]
        if x then
            if not s then
                s = EnsureLane(row, l)
                lanes = row._sgLane
            end
            local e = (l == 1 and e1) or (l == 2 and e2) or (l == 3 and e3) or nil
            if s and ((l == 1 and potion) or RouteUngated(e)) then
                UngateLane(s)
            elseif s then
                GateLane(s, x, mode, p)
                FeedLane(s, e)
            end
        elseif s then
            UngateLane(s)
        end
    end
end

-- Clips sit one level under their bar, set before the bar so the bar keeps its level.
function ns.StackGate_Levels(row)
    local lanes = row._sgLane
    if not lanes then return end
    for l = 1, 3 do
        local s = lanes[l]
        if s then
            local lv = s.bar:GetFrameLevel()
            local under = math.max(0, lv - 1)
            s.pair.above:SetFrameLevel(under)
            s.pair.below:SetFrameLevel(under)
            s.bar:SetFrameLevel(lv)
            s.dim:SetFrameLevel(lv)
            s.pair.ind:SetFrameLevel(lv)
            local clip = row[PAST_CLIPS[l]]
            if clip then
                local pl = clip:GetFrameLevel()
                for i = 1, #s.segs do
                    s.segs[i].above:SetFrameLevel(pl)
                    s.segs[i].below:SetFrameLevel(pl)
                end
            end
        end
    end
end

-- The past of a gated lane, cut into segments. A segment's indicator is fed once, at
-- spawn, so its verdict is frozen; edges come from absolute times so neighbours meet.

local SEG_CAP = 32

local function PastOn()
    return CONFIG.showPastBars and (CONFIG.past or 0) > 0
end

local function Snap(v, onePx)
    return math.floor(v / onePx + 0.5) * onePx
end

local function NewSegment(clip)
    local seg = { clip = clip }
    seg.ind = NewIndicator(clip)
    seg.above = NewClip(clip)
    seg.below = NewClip(clip)
    seg.tex = seg.above:CreateTexture(nil, "ARTWORK")
    seg.dimTex = seg.below:CreateTexture(nil, "ARTWORK")
    for _, tex in ipairs({ seg.tex, seg.dimTex }) do
        tex:SetTexture(TEX)
        Crisp(tex)
        tex:SetAllPoints(seg.ind)
    end
    AnchorAtOrAbove(seg.above, seg.ind)
    AnchorBelow(seg.below, seg.ind)
    seg.above:Hide()
    seg.below:Hide()
    return seg
end

local function Paint(seg, colour, dimP)
    local a = colour[4] or 0.7
    seg.tex:SetVertexColor(colour[1], colour[2], colour[3], a)
    seg.dimTex:SetVertexColor(colour[1], colour[2], colour[3], a * (dimP or 30) / 100)
    seg.colour = colour
end

local function Retire(s, seg)
    seg.active = false
    seg.above:Hide()
    seg.below:Hide()
    seg.ind:Hide()
    s.live = math.max(0, (s.live or 1) - 1)
    if s.open == seg then s.open = nil end
end

local function Spawn(row, s, clip, colour, now)
    local seg, oldest
    for i = 1, #s.segs do
        local c = s.segs[i]
        if c.active then
            if not oldest or c.startT < oldest.startT then oldest = c end
        elseif not seg then
            seg = c
        end
    end
    if not seg then
        if #s.segs < SEG_CAP then
            seg = NewSegment(clip)
            s.segs[#s.segs + 1] = seg
        else
            seg = oldest
            Retire(s, seg)
        end
    end
    seg.active = true
    s.live = (s.live or 0) + 1
    seg.startT, seg.endT = now, nil
    seg.lastW, seg.lastRight, seg.vis = nil, nil, nil
    seg.h = (row.cdBar and row.cdBar.fullHeight) or CONFIG.height
    seg.dimOn = s.dimOn
    SetRange(seg.ind, s.x)
    Feed(seg.ind, s.count)
    Paint(seg, colour, s.dimP)
    local pl = clip:GetFrameLevel()
    seg.above:SetFrameLevel(pl)
    seg.below:SetFrameLevel(pl)
    seg.ind:Show()
    s.open = seg
end

local function Place(s, clip, now)
    local pastW = ns.GetNowPixelOffset and ns.GetNowPixelOffset() or 0
    local past = CONFIG.past or 0
    local onePx = ns.OnePxForFrame and ns.OnePxForFrame(ns.EH_Parent) or 1
    if not onePx or onePx <= 0 then onePx = 1 end
    for i = 1, #s.segs do
        local seg = s.segs[i]
        if seg.active then
            if pastW <= 0 or past <= 0 then
                Retire(s, seg)
            else
                local pps = pastW / past
                local left = Snap((now - seg.startT) * pps, onePx)
                local right = seg.endT and Snap((now - seg.endT) * pps, onePx) or 0
                if right >= pastW then
                    Retire(s, seg)
                else
                    local cap = Snap(pastW, onePx) + onePx
                    if left > cap then left = cap end
                    local w = left - right
                    if w ~= seg.lastW or right ~= seg.lastRight then
                        seg.ind:ClearAllPoints()
                        seg.ind:SetPoint("TOPRIGHT", clip, "TOPRIGHT", -right, 0)
                        seg.ind:SetSize(math.max(w, onePx), seg.h)
                        seg.lastW, seg.lastRight = w, right
                    end
                    local vis = w > 0
                    if vis ~= seg.vis then
                        seg.above:SetShown(vis)
                        seg.below:SetShown(vis and seg.dimOn or false)
                        seg.vis = vis
                    end
                end
            end
        end
    end
end

-- 30Hz, per lane. True when segments own this lane's past and the slide path is off.
function ns.StackGate_PastUpdate(row, l, isActive, colour)
    local s = row._sgLane and row._sgLane[l]
    if not s then return false end
    local clip = row[PAST_CLIPS[l]]
    if not clip then return false end
    local now = GetTime()
    if s.gated and isActive and PastOn() then
        if s.open and s.cut then
            s.open.endT = now
            s.open = nil
        end
        if not s.open and colour then Spawn(row, s, clip, colour, now) end
        if s.open and colour and s.open.colour ~= colour then Paint(s.open, colour, s.dimP) end
    elseif s.open then
        s.open.endT = now
        s.open = nil
    end
    s.cut = false
    if (s.live or 0) > 0 then Place(s, clip, now) end
    return s.gated
end
