-- EventHorizon Infall: DoT tick marks.

-- Periods come from TickPeriods.lua, which is generated. This file is not.

local ns = EventHorizon_Infall
local issecret = issecretvalue or function() return false end

-- Haste from the GCD, which is spell 61304 and never secret. Floors at 0.75s,
-- so this saturates near 2.0.
local lastHaste = 1
function ns.HasteMultiplier()
    if not C_Spell or not C_Spell.GetSpellCooldownDuration then return lastHaste end
    local ok, obj = pcall(C_Spell.GetSpellCooldownDuration, 61304)
    if not ok or not obj or not obj.GetTotalDuration then return lastHaste end
    local tOk, total = pcall(obj.GetTotalDuration, obj)
    if issecretvalue and issecretvalue(total) then return lastHaste end
    if tOk and type(total) == "number" and total > 0 then
        local mult = 1.5 / total
        if mult >= 1 and mult < 3 then lastHaste = mult end
    end
    return lastHaste
end


local CONFIG = ns.CONFIG
local MAX_MARKS = 20

-- A secret id cannot be a table key, and the lookup errors rather than missing.
local function Period(id)
    if id == nil or issecret(id) then return nil end
    return ns.TICK_PERIODS[id]
end

-- The paired buff's spell id, if any id it can present has a known period.
local function TickSpell(row)
    if row._tickSpellResolved then return row._tickSpellID, row._tickFromCast end
    row._tickSpellResolved = true
    row._tickSpellID = nil
    local maps = row.cooldownID and CONFIG.buffMappings
        and (CONFIG.buffMappings[row.cooldownID]
            or CONFIG.buffMappings[row.baseSpellID]
            or CONFIG.buffMappings[row.spellID])
    local first = maps and maps[1]
    local AC = ns.AuraCompat
    -- A paired aura first: its real start and end beat anything reconstructed.
    if first and first.buffCooldownIDs then
        for _, cdID in ipairs(first.buffCooldownIDs) do
            local ids = AC and AC.IdentityIDsForCooldown and AC.IdentityIDsForCooldown(cdID)
            if ids then
                for i = 1, #ids do
                    if Period(ids[i]) then
                        row._tickSpellID = ids[i]
                        row._tickUnit = first.unit
                        return row._tickSpellID, false
                    end
                end
            end
        end
    end
    -- Otherwise the row's own spell, timed from when it was cast. This is what
    -- reaches a DoT the Cooldown Manager has no entry for.
    local own = row.spellID
    if Period(own) then
        row._tickSpellID, row._tickFromCast = own, true
        return own, true
    end
    own = row.baseSpellID
    if Period(own) then
        row._tickSpellID, row._tickFromCast = own, true
        return own, true
    end
    return nil
end

local function Mark(row, index)
    row.tickMarks = row.tickMarks or {}
    local m = row.tickMarks[index]
    if not m then
        -- On the same overlay as the now line, so nothing draws over them.
        m = (ns.linesOverlay or row):CreateTexture(nil, "OVERLAY", nil, 6)
        m:SetSnapToPixelGrid(false)
        m:SetTexelSnappingBias(0)
        row.tickMarks[index] = m
    end
    return m
end

local function HideFrom(row, index)
    local marks = row.tickMarks
    if type(marks) ~= "table" then return end
    for i = index, #marks do
        if marks[i] then marks[i]:Hide() end
    end
end

local function ReadOn(spellID, unit)
    local AC = ns.AuraCompat
    if not AC or not AC.AuraFillBySpellID then return nil end
    local kind, durObj = AC.AuraFillBySpellID(spellID, unit)
    if kind ~= "durobj" or not durObj then return nil end
    local sOk, s1 = pcall(durObj.GetStartTime, durObj)
    local eOk, e1 = pcall(durObj.GetEndTime, durObj)
    if not sOk or not eOk or issecret(s1) or issecret(e1)
        or type(s1) ~= "number" or type(e1) ~= "number" then
        return nil
    end
    return s1, e1
end

-- Read on whichever unit carries it, then LATCHED: a target swap or a momentary
-- unreadable frame must not blank marks that are still running.
function ns.TickWindow(row, spellID, fromCast, haste)
    local startT, endT = ReadOn(spellID, row._tickUnit or "player")
    if not startT and not row._tickUnit then
        startT, endT = ReadOn(spellID, "target")
    end
    if startT then
        row._tickStart, row._tickEnd = startT, endT
        return startT, endT
    end
    local now = GetTime()
    if row._tickEnd and now <= row._tickEnd then
        return row._tickStart, row._tickEnd
    end
    if fromCast and row._tickCastAt then
        local duration, dHasted = ns.TickDurationFor(spellID)
        if duration then
            if dHasted then duration = duration / haste end
            return row._tickCastAt, row._tickCastAt + duration
        end
    end
    return nil
end

function ns.UpdateDotTicks(row)
    if not CONFIG.dotTicks then
        HideFrom(row, 1)
        return
    end
    local spellID, fromCast = TickSpell(row)
    if not spellID then
        HideFrom(row, 1)
        return
    end
    local period, pHasted = ns.TickPeriodFor(spellID)
    if not period then
        HideFrom(row, 1)
        return
    end
    local haste = ns.HasteMultiplier()
    if pHasted then period = period / haste end
    if period <= 0.05 then
        HideFrom(row, 1)
        return
    end

    local startT, endT = ns.TickWindow(row, spellID, fromCast, haste)
    if not startT or not endT or GetTime() > endT then
        HideFrom(row, 1)
        return
    end

    local now = GetTime()
    local barOffset = ns.GetBarOffset()
    local height = row:GetHeight()
    -- Notches along the top edge, not full-height rules: the bar under them is
    -- the thing being read.
    local notchH = math.max(2, height * 0.35)
    local width = CONFIG.dotTickWidth or 1
    local colour = CONFIG.dotTickColor or {1, 1, 1, 0.45}
    local anchor = ns.linesOverlay or row
    local overlayLeft = anchor:GetLeft()
    local onePx = ns.OnePxForFrame(anchor)
    local shown = 0

    for k = 1, MAX_MARKS do
        local at = startT + k * period
        if at > endT + 0.01 then break end
        local offset = at - now
        if offset > -CONFIG.past and offset < CONFIG.future then
            shown = shown + 1
            local x = barOffset + ns.TimeToPixel(offset)
            if overlayLeft and onePx and onePx > 0 then
                x = math.floor((overlayLeft + x) / onePx + 0.5) * onePx - overlayLeft
            end
            local m = Mark(row, shown)
            m:SetColorTexture(colour[1], colour[2], colour[3], colour[4] or 1)
            m:ClearAllPoints()
            m:SetSize(width, notchH)
            m:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
            m:Show()
        end
    end
    HideFrom(row, shown + 1)
end
