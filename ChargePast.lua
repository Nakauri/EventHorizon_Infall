-- EventHorizon Infall: charge past columns.

-- A column per past moment, each fed the charge count from that moment.
-- See docs/past-bar-audit.md and docs/charge-past-bar-port-plan.md.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local COLS = 50           -- target columns across the whole past window
local RING = 600
local TEX = "Interface\\AddOns\\EventHorizon_Infall\\Smooth"

-- Whole pixel columns that tile exactly. Overlapping them doubles the alpha and
-- makes the lane brighter than the others with a bright line at every seam.
local function Geometry()
    local nowPx = ns.GetNowPixelOffset and ns.GetNowPixelOffset() or 0
    if nowPx <= 0 then return 0, 0, 0 end
    local onePx = ns.OnePxForFrame and ns.OnePxForFrame(ns.EH_Parent) or 1
    if onePx <= 0 then onePx = 1 end
    local colW = math.floor((nowPx / COLS) / onePx + 0.5) * onePx
    if colW < onePx then colW = onePx end
    -- One spare column so the sub pixel scroll never uncovers the left edge.
    local cols = math.ceil(nowPx / colW) + 1
    return colW, cols, (CONFIG.past or 2.5) / (nowPx / colW)
end

-- Same guard SpawnPastSlide uses, so the columns disappear with every other past bar.
local function Enabled()
    return CONFIG.showPastBars and (CONFIG.past or 0) > 0
end

-- A secret is legal as a table VALUE. Never a key, never compared.
function ns.ChargePast_Push(row, cc)
    if not Enabled() or cc == nil then return end
    if not row.maxCharges or row.maxCharges <= 2 then return end
    local ring = row._cpRing
    if not ring then
        ring = {}
        row._cpRing = ring
        row._cpRingN = 0
    end
    local n = (row._cpRingN or 0) + 1
    row._cpRingN = n
    ring[n] = ring[n] or {}
    ring[n].t = GetTime()
    ring[n].v = cc
    for i = 1, n - RING do ring[i] = nil end
end

local function ValueAt(row, when)
    local ring, n = row._cpRing, row._cpRingN or 0
    if not ring then return nil end
    for i = n, math.max(1, n - RING), -1 do
        local e = ring[i]
        if e and e.t and e.t <= when then return e.v end
    end
    return nil
end

-- Built like the real lane: an indicator's texture drives a clip wrapper.
-- A plain StatusBar fill comes out inverted here.
function ns.ChargePast_Build(row, maxC, laneH)
    if not Enabled() then
        if row._cpTrack then
            for _, track in pairs(row._cpTrack) do track:Hide() end
        end
        row._cpSig = nil
        return
    end
    if not maxC or maxC <= 2 or not row.pastCdClip then return end
    local colW, cols = Geometry()
    if cols <= 0 then return end
    local nowPx = ns.GetNowPixelOffset and ns.GetNowPixelOffset() or 0

    -- Ellesmere's pattern: a scalar signature so a layout pass that changed nothing
    -- does no work at all. Rebuilding 150 widgets per lane on every pass is waste.
    local sig = colW * 100000 + cols * 100 + (laneH or 0)
    if row._cpSig == sig and row._cpMax == maxC then return end
    row._cpSig, row._cpMax = sig, maxC

    -- One container per lane, scrolled as a whole so the block edge moves smoothly
    -- between value steps instead of jumping a column at a time.
    row._cpCols = row._cpCols or {}
    row._cpTrack = row._cpTrack or {}

    for j = 1, maxC - 2 do
        local track = row._cpTrack[j]
        if not track then
            track = CreateFrame("Frame", nil, row.pastCdClip)
            row._cpTrack[j] = track
        end
        -- Below the slide textures on the clip, so it never draws over a real bar.
        track:SetFrameLevel(math.max(0, row.pastCdClip:GetFrameLevel() - 1))
        track:SetSize(nowPx + colW, laneH)
        track._cpY = j * (ns.ChargeLanePitch and ns.ChargeLanePitch(row, laneH) or (laneH + 1))
        track:ClearAllPoints()
        track:SetPoint("TOPRIGHT", row.pastCdClip, "TOPRIGHT", 0, -track._cpY)
        track:Show()

        local set = row._cpCols[j]
        if not set then
            set = {}
            row._cpCols[j] = set
        end
        local lo, hi = maxC - j - 1, maxC - j
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
            col.ind:SetPoint("TOPRIGHT", track, "TOPRIGHT", -(i - 1) * colW, 0)
            col.ind:SetMinMaxValues(lo, hi)
            col.ind:SetValue(hi)
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
end

function ns.ChargePast_Update(row, colour)
    if not Enabled() or not row._cpCols then return end
    local maxC = row.maxCharges
    if not maxC or maxC <= 2 then return end
    local now = GetTime()
    local colW, cols, step = Geometry()
    if cols <= 0 or step <= 0 then return end

    -- Scroll the whole track by the sub-step remainder every frame. One SetPoint
    -- per lane, and the values below only need refreshing on a step boundary.
    local frac = (now % step) / step
    for j = 1, maxC - 2 do
        local track = row._cpTrack and row._cpTrack[j]
        if track then
            track:ClearAllPoints()
            track:SetPoint("TOPRIGHT", row.pastCdClip, "TOPRIGHT",
                -frac * colW, -(track._cpY or 0))
        end
    end

    if row._cpNext and now < row._cpNext then return end
    row._cpNext = now + step

    local r, g, b, a = 1, 1, 1, 0.7
    if colour then r, g, b, a = colour[1], colour[2], colour[3], colour[4] or 0.7 end
    local recolour = row._cpR ~= r or row._cpG ~= g or row._cpB ~= b or row._cpA ~= a
    row._cpR, row._cpG, row._cpB, row._cpA = r, g, b, a
    for j = 1, maxC - 2 do
        local set = row._cpCols[j]
        if set then
            for i = 1, #set do
                local col = set[i]
                if col and col.ind:IsShown() then
                    local v = ValueAt(row, now - (i - 0.5) * step)
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
