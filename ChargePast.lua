-- EventHorizon Infall: charge past columns.

-- A column per past moment, each fed the charge count from that moment.
-- READ docs/charge-past-delay-line.md before editing this file.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

-- Device pixels per column, held CONSTANT so a longer past window looks identical
-- instead of stair stepping. A fixed column COUNT made colW grow with the window.
-- The smoothness setting picks it: 4 is 1px, 3 is 2px, 2 is 3px, 1 is 4px.
local COL_BUDGET = 440

local function ColPx()
    local s = tonumber(CONFIG.chargePastSmoothness) or 3
    s = math.max(1, math.min(4, math.floor(s + 0.5)))
    return 5 - s
end
-- About 90 pushes a second at most, so 1200 slots hold the 10 second past maximum.
local RING = 1200
local BURST = 0.015
local TEX = "Interface\\AddOns\\EventHorizon_Infall\\Smooth"
local issecret = issecretvalue or function() return false end

-- Whole pixel columns that tile exactly. Overlapping them doubles the alpha and
-- makes the lane brighter than the others with a bright line at every seam.
local function Geometry()
    local nowPx = ns.GetNowPixelOffset and ns.GetNowPixelOffset() or 0
    if nowPx <= 0 then return 0, 0, 0 end
    local onePx = ns.OnePxForFrame and ns.OnePxForFrame(ns.EH_Parent) or 1
    if onePx <= 0 then onePx = 1 end
    local colPx = ColPx()
    local maxCols = math.floor(COL_BUDGET / colPx)
    local colW = colPx * onePx
    local cols = math.ceil(nowPx / colW) + 1
    if cols > maxCols then
        colW = math.ceil((nowPx / maxCols) / onePx) * onePx
        if colW < onePx then colW = onePx end
    end
    -- One spare column at the left edge, and one straddling the now line so the
    -- sub pixel scroll never uncovers either end.
    cols = math.ceil(nowPx / colW) + 2
    return colW, cols, (CONFIG.past or 2.5) / (nowPx / colW)
end

-- Same guard SpawnPastSlide uses, so the columns disappear with every other past bar.
local function Enabled()
    return CONFIG.showPastBars and (CONFIG.past or 0) > 0
end

-- The charge lanes above the bottom one, shared with the future layout so the past
-- and the future cannot sit at different heights. [1] is the top lane, [1 + j] middle
-- lane j. y is the downward offset; a lane draws while the count is at or below lo.
local laneScratch = setmetatable({}, { __mode = "k" })
function ns.ChargeLanes(row, maxC, laneH)
    local lanes = laneScratch[row]
    if not lanes then
        lanes = {}
        laneScratch[row] = lanes
    end
    maxC = maxC or 2
    local pitch = ns.ChargeLanePitch and ns.ChargeLanePitch(row, laneH) or ((laneH or 0) + 1)
    local n = math.max(0, maxC - 1)
    for k = 1, n do
        local l = lanes[k]
        if not l then
            l = {}
            lanes[k] = l
        end
        local j = k - 1
        l.y = j * pitch
        l.lo = (j == 0) and 0 or (maxC - j - 1)
        l.hi = l.lo + 1
    end
    for k = #lanes, n + 1, -1 do lanes[k] = nil end
    return lanes, n
end

-- A secret is legal as a table VALUE. Never a key, never compared.
-- A push within BURST of the last is an event burst and is dropped unless a readable
-- count changed. The 30Hz samples are further apart, so none of them is ever dropped.
function ns.ChargePast_Push(row, cc)
    if not Enabled() or cc == nil then return end
    if not row.maxCharges or row.maxCharges < 2 then return end
    local now = GetTime()
    local lastT = row._cpLastT
    if lastT and (now - lastT) < BURST then
        local last = row._cpLastV
        if issecret(cc) or last == nil or issecret(last) or cc == last then return end
    end
    local ring = row._cpRing
    if not ring then
        ring = {}
        row._cpRing = ring
        row._cpRingN = 0
    end
    local n = (row._cpRingN or 0) + 1
    row._cpRingN = n
    -- Fixed slots, overwritten in turn.
    local slot = (n - 1) % RING + 1
    local e = ring[slot]
    if not e then
        e = {}
        ring[slot] = e
    end
    e.t = now
    e.v = cc
    row._cpLastT, row._cpLastV = now, cc
end

-- Column times only move backwards, so one walk down the ring serves every column.
-- Fills out[i] with the value at boundary - (i - 1.5) * step, nil where history runs
-- out. Column 1 straddles the now line and carries the newest value.
local function ValuesBack(row, boundary, step, cols, out)
    local ring, n = row._cpRing, row._cpRingN or 0
    local k, floor = n, math.max(1, n - RING + 1)
    for i = 1, cols do
        local when = boundary - (i - 1.5) * step
        local v
        while ring and k >= floor do
            local e = ring[(k - 1) % RING + 1]
            if e and e.t and e.t <= when then
                v = e.v
                break
            end
            k = k - 1
        end
        out[i] = v
    end
end

local function HideTrack(row, k)
    local track = row._cpTrack and row._cpTrack[k]
    if track then track:Hide() end
    local set = row._cpCols and row._cpCols[k]
    if set then
        for i = 1, #set do
            if set[i] then
                set[i].ind:Hide()
                set[i].wrap:Hide()
            end
        end
    end
end

local function HideAll(row)
    if row._cpTrack then
        for _, track in pairs(row._cpTrack) do track:Hide() end
    end
    row._cpSig = nil
end

-- Past bars off, or a charge length the timeline cannot draw: no tracks, and the ring
-- starts clean when they come back.
local function Off(row)
    return not Enabled() or row._chargeDurUnknown
end

-- Built like the real lane: an indicator's texture drives a clip wrapper.
-- A plain StatusBar fill comes out inverted here.
function ns.ChargePast_Build(row, maxC, laneH)
    row._cpWantMax, row._cpWantH = maxC, laneH
    if Off(row) then
        HideAll(row)
        return
    end
    if not maxC or maxC < 2 or not row.pastCdClip then return end
    local colW, cols = Geometry()
    if cols <= 0 then return end
    local nowPx = ns.GetNowPixelOffset and ns.GetNowPixelOffset() or 0

    -- A scalar signature so a layout pass that changed nothing does no work at all. Rebuilding 150 widgets per lane on every pass is waste.
    local sig = colW * 100000 + cols
    if row._cpSig == sig and row._cpMax == maxC and row._cpLaneH == laneH then return end
    row._cpSig, row._cpMax, row._cpLaneH = sig, maxC, laneH
    row._cpNext = nil

    -- One container per lane, scrolled as a whole so the block edge moves smoothly
    -- between value steps instead of jumping a column at a time.
    row._cpCols = row._cpCols or {}
    row._cpTrack = row._cpTrack or {}

    local lanes, nLanes = ns.ChargeLanes(row, maxC, laneH)
    for k = 1, nLanes do
        local lane = lanes[k]
        local track = row._cpTrack[k]
        if not track then
            track = CreateFrame("Frame", nil, row.pastCdClip)
            row._cpTrack[k] = track
        end
        -- Below the slide textures on the clip, so it never draws over a real bar.
        track:SetFrameLevel(math.max(0, row.pastCdClip:GetFrameLevel() - 1))
        track:SetSize(nowPx + colW * 2, laneH)
        track._cpY = lane.y
        track:ClearAllPoints()
        track:SetPoint("TOPRIGHT", row.pastCdClip, "TOPRIGHT", 0, -track._cpY)
        track:Show()

        local set = row._cpCols[k]
        if not set then
            set = {}
            row._cpCols[k] = set
        end
        for i = 1, cols do
            local col = set[i]
            if not col then
                col = {}
                col.ind = CreateFrame("StatusBar", nil, track)
                col.ind:SetStatusBarTexture(TEX)
                col.ind:GetStatusBarTexture():SetAlpha(0)
                col.ind:SetOrientation("VERTICAL")
                col.wrap = CreateFrame("Frame", nil, track)
                col.wrap:SetClipsChildren(true)
                col.fill = col.wrap:CreateTexture(nil, "ARTWORK")
                col.fill:SetTexture(TEX)
                col.fill:SetAllPoints()
                col.fill:SetSnapToPixelGrid(false)
                col.fill:SetTexelSnappingBias(0)
                set[i] = col
            end
            col.ind:SetSize(colW, laneH)
            col.ind:ClearAllPoints()
            -- Column 1 sits one column right of the track edge, across the now line.
            col.ind:SetPoint("TOPRIGHT", track, "TOPRIGHT", -(i - 2) * colW, 0)
            col.ind:SetMinMaxValues(lane.lo, lane.hi)
            -- hi draws BLANK here: the fill is clipped between the bar texture's top
            -- and the lane top, and the bar's own texture is alpha zero.
            col.ind:SetValue(lane.hi)
            col.wrap:ClearAllPoints()
            col.wrap:SetPoint("TOPRIGHT", col.ind, "TOPRIGHT")
            col.wrap:SetPoint("BOTTOMLEFT", col.ind:GetStatusBarTexture(), "TOPLEFT")
            col.wrap:Show()
            col.ind:Show()
        end
        for i = cols + 1, #set do
            if set[i] then
                set[i].ind:Hide()
                set[i].wrap:Hide()
            end
        end
    end
    for k = nLanes + 1, #row._cpTrack do HideTrack(row, k) end
    row._cpLanes = nLanes
    -- Repaint and refill on the next update.
    row._cpR = nil
    if ns.RecChargePast then ns.RecChargePast(row, nLanes, row._cpRingN or 0) end
end

-- Tracks sit one level under the past clip, re-applied whenever the clip moves.
function ns.ChargePast_Levels(row)
    if not row._cpTrack or not row.pastCdClip then return end
    local lv = math.max(0, row.pastCdClip:GetFrameLevel() - 1)
    for _, track in pairs(row._cpTrack) do track:SetFrameLevel(lv) end
end

function ns.ChargePast_Update(row, colour)
    if Off(row) then
        if not row._cpOff then
            row._cpOff = true
            HideAll(row)
            row._cpRing, row._cpRingN, row._cpLastT, row._cpLastV = nil, 0, nil, nil
        end
        return
    end
    if row._cpOff then
        row._cpOff = nil
        ns.ChargePast_Build(row, row._cpWantMax, row._cpWantH)
    end
    if not row._cpCols then return end
    local nLanes = row._cpLanes or 0
    if nLanes <= 0 then return end
    local now = GetTime()
    local colW, cols, step = Geometry()
    if cols <= 0 or step <= 0 then return end

    -- Scroll the whole track by the sub-step remainder every 30Hz tick. One SetPoint
    -- per lane, and the values below only need refreshing on a step boundary.
    local frac = (now % step) / step
    for k = 1, nLanes do
        local track = row._cpTrack and row._cpTrack[k]
        if track then
            track:ClearAllPoints()
            track:SetPoint("TOPRIGHT", row.pastCdClip, "TOPRIGHT",
                -frac * colW, -(track._cpY or 0))
        end
    end

    -- Values refresh on step boundaries, the same clock the scroll fraction uses.
    if row._cpNext and now < row._cpNext then return end
    local boundary = math.floor(now / step) * step
    row._cpNext = boundary + step

    local r, g, b, a = 1, 1, 1, 0.7
    if colour then r, g, b, a = colour[1], colour[2], colour[3], colour[4] or 0.7 end
    local recolour = row._cpR ~= r or row._cpG ~= g or row._cpB ~= b or row._cpA ~= a
    row._cpR, row._cpG, row._cpB, row._cpA = r, g, b, a
    local vals = row._cpVals
    if not vals then
        vals = {}
        row._cpVals = vals
    end
    ValuesBack(row, boundary, step, cols, vals)
    for k = 1, nLanes do
        local set = row._cpCols[k]
        if set then
            for i = 1, math.min(cols, #set) do
                local col = set[i]
                if col and col.ind:IsShown() then
                    local v = vals[i]
                    if v ~= nil then pcall(col.ind.SetValue, col.ind, v) end
                    if recolour then col.fill:SetVertexColor(r, g, b, a) end
                end
            end
        end
    end
end

function ns.ChargePast_Reset(row)
    row._cpSig = nil
    row._cpRing = nil
    row._cpR, row._cpG, row._cpB, row._cpA = nil, nil, nil, nil
    row._cpRingN = 0
    row._cpNext = nil
    row._cpLastT, row._cpLastV = nil, nil
    row._cpLanes = 0
    row._cpOff, row._cpLaneH = nil, nil
    if row._cpTrack then
        for _, track in pairs(row._cpTrack) do track:Hide() end
    end
    if not row._cpCols then return end
    for _, set in pairs(row._cpCols) do
        for i = 1, #set do
            if set[i] then
                set[i].ind:Hide()
                set[i].wrap:Hide()
            end
        end
    end
end
