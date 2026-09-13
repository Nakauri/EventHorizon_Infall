-- EventHorizon Infall: keypress marks.

-- READ docs/press-marks.md before editing this file.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local IN_DEFAULT = {0.4, 0.7, 1, 0.9}
local LATE_DEFAULT = {1, 0.35, 0.35, 0.9}

-- Two axes, deliberately independent:
--   colour     WHEN it landed. Something still running = in time. Nothing = late.
--   brightness WHETHER it took. Only the press that actually dispatched is full.
local MAX = 96            -- a wheel fires ~75 presses across a 2.5s window
local FADE_FROM = 0.12    -- full strength only right at the now line
local POW_WON = 1.0       -- the locked-in mark decays gently; it is the signal
local POW_MISS = 2.4      -- a mash decays hard, so a dense burst thins out fast
local MISS_DIM = 0.3      -- a press that did not take

local ring, ringN, tex = {}, 0, {}

local function Enabled()
    return CONFIG.pressSpark and (CONFIG.past or 0) > 0
end

function ns.PressMarks_Push(late)
    if not Enabled() then return end
    ringN = ringN + 1
    local i = (ringN - 1) % MAX + 1
    ring[i] = ring[i] or {}
    ring[i].t = GetTime()
    ring[i].late = late and true or false
    ring[i].won = false
end

-- SENT fires INSIDE UseAction, before the press it belongs to is pushed. Remembering the
-- count at dispatch binds the flag to that press instead of to the next mash.
local winPending, winAt = false, 0
function ns.PressMarks_MarkWinner()
    winPending, winAt = true, ringN
end

local function ResolveWinner()
    if not winPending then return end
    winPending = false
    if ringN == 0 then return end
    local n = (ringN > winAt) and (winAt + 1) or ringN
    local cur = ring[(n - 1) % MAX + 1]
    if cur and cur.t then cur.won = true end
end

local function Mark(i)
    local t = tex[i]
    if not t then
        local overlay = ns.linesOverlay
        if not overlay then return nil end
        t = overlay:CreateTexture(nil, "OVERLAY", nil, 5)
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
        tex[i] = t
    end
    return t
end

local function HideAll()
    for i = 1, MAX do
        if tex[i] then tex[i]:Hide() end
    end
end

-- Position is recomputed from the timestamp every frame and never cached. A mark that
-- keeps a stale x while the rest of the bar moves is the jarring failure this avoids.
function ns.PressMarks_Update()
    if not Enabled() then
        HideAll()
        return
    end
    local overlay = ns.linesOverlay
    if not overlay then return end
    ResolveWinner()
    if ringN == 0 then return end

    local now = GetTime()
    local past = CONFIG.past or 2.5
    local onePx = ns.OnePxForFrame(overlay)
    if not onePx or onePx <= 0 then onePx = 1 end
    local w = (CONFIG.pressSparkWidth or 2) * onePx
    local inC = CONFIG.pressSparkColor or IN_DEFAULT
    local lateC = CONFIG.pressLateColor or LATE_DEFAULT
    local barOffset = ns.GetBarOffset()
    local overlayLeft = overlay:GetLeft()
    -- Dispatch sets won a beat after the press, so a kept mark appears a frame late.
    local castOnly = CONFIG.pressSparkCastOnly

    for i = 1, MAX do
        local slot = ring[i]
        if not slot or not slot.t then
            if tex[i] then tex[i]:Hide() end
        else
            local age = now - slot.t
            if age < 0 or age >= past then
                slot.t = nil
                if tex[i] then tex[i]:Hide() end
            elseif castOnly and not slot.won then
                if tex[i] then tex[i]:Hide() end
            else
                -- Distance from the now line drives the falloff, and a mash falls off
                -- much harder than the mark that actually landed.
                local frac = age / past
                local fade = 1
                if frac > FADE_FROM then
                    local k = (frac - FADE_FROM) / (1 - FADE_FROM)
                    fade = (1 - k) ^ (slot.won and POW_WON or POW_MISS)
                end
                local t = Mark(i)
                if t then
                    local x = barOffset + ns.TimeToPixel(-age)
                    if overlayLeft then
                        x = math.floor((overlayLeft + x) / onePx + 0.5) * onePx - overlayLeft
                    end
                    local c = slot.late and lateC or inC
                    local dim = slot.won and 1 or MISS_DIM
                    t:SetColorTexture(c[1], c[2], c[3], (c[4] or 0.9) * fade * dim)
                    t:ClearAllPoints()
                    -- Opposite corners, so both horizontal edges are pinned.
                    t:SetPoint("TOPLEFT", overlay, "TOPLEFT", x, 0)
                    t:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMLEFT", x + w, 0)
                    t:Show()
                end
            end
        end
    end
end

function ns.PressMarks_Reset()
    ring, ringN = {}, 0
    HideAll()
end
