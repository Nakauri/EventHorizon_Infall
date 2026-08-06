-- EventHorizon Infall: aura timing sources.
-- Bar-configured auras read the CDM's own bar value. Icon-configured auras use
-- a DurationObject built from a recorded start and a learned duration.

local ns = EventHorizon_Infall
local AC = {}
ns.AuraCompat = AC

local issecret = issecretvalue or function() return false end

AC.IS_121 = (select(4, GetBuildInfo()) or 0) >= 120100

------------------------------------------------------------------------------
-- Restriction state
------------------------------------------------------------------------------

local probeStamp = -1
local probeAnswer = false

-- True while aura queries raise an error for addons. Probes the call itself
-- rather than C_Secrets.ShouldAurasBeSecret, which reports secrecy and is true
-- on 12.0.7 in instances where the queries still work.
-- Memoized per frame: callers run per row per update cycle, and an uncached
-- probe costs a pcall plus an API call every time.
function AC.AurasRestricted()
    if not AC.IS_121 then return false end
    local now = GetTime()
    if now == probeStamp then return probeAnswer end
    probeStamp = now
    probeAnswer = not pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL")
    return probeAnswer
end

------------------------------------------------------------------------------
-- Learned aura data, keyed by spell id
------------------------------------------------------------------------------

local learnedDuration = {}
local learnedPermanent = {}

function AC.LoadDB()
    InfallDB = InfallDB or {}
    InfallDB.auraDurations = InfallDB.auraDurations or {}
    InfallDB.auraPermanent = InfallDB.auraPermanent or {}
    InfallDB.auraPermanentUser = InfallDB.auraPermanentUser or {}
    learnedDuration = InfallDB.auraDurations
    learnedPermanent = InfallDB.auraPermanent
end

-- Non-secret spell id for a CDM frame.
function AC.GetConfigSpellID(frame)
    if not frame then return nil end
    local fOk, cdID = pcall(function() return frame.cooldownID end)
    if not fOk or not cdID then return nil end
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if not ok or not info then return nil end
    local id = info.overrideSpellID or info.spellID
    if id and not issecret(id) then return id end

    -- Item entries (trinket buffs, potions) carry no spellID, so learning and
    -- permanence would never key off anything and the aura falls through to a
    -- mirror that renders permanent buffs empty. The cooldownID is the CDM's
    -- own stable identity; namespace it so it cannot collide with a spellID.
    if info.equipSlot or info.spellCategoryID then
        return "cd:" .. tostring(cdID)
    end
    return nil
end

function AC.IsUserPermanent(spellID)
    return spellID ~= nil and InfallDB and InfallDB.auraPermanentUser
        and InfallDB.auraPermanentUser[spellID] == true
end

function AC.SetUserPermanent(spellID, isPermanent)
    if not spellID then return end
    AC.LoadDB()
    InfallDB.auraPermanentUser[spellID] = isPermanent and true or nil
end

function AC.IsPermanent(spellID)
    if not spellID then return false end
    if AC.IsUserPermanent(spellID) then return true end
    return learnedPermanent[spellID] == true
end

function AC.GetLearnedDuration(spellID)
    if not spellID then return nil end
    return learnedDuration[spellID]
end

-- Returns state, detail for display:
--   "permanent" | "learned" (detail = seconds) | "unlearned"
function AC.GetLearnState(spellID)
    if not spellID then return "unlearned" end
    if AC.IsPermanent(spellID) then return "permanent" end
    local dur = learnedDuration[spellID]
    if dur then return "learned", dur end
    return "unlearned"
end

-- Caches duration and permanence. No-op while auras are restricted.
function AC.Learn(frame)
    if AC.AurasRestricted() then return end
    local spellID = AC.GetConfigSpellID(frame)
    if not spellID then return end

    local ok, ad = pcall(function() return frame.auraDataCached end)
    if not ok or not ad then return end

    local okD, dur = pcall(function() return ad.duration end)
    local okE, exp = pcall(function() return ad.expirationTime end)
    if not okD or issecret(dur) then return end

    if dur == 0 or (okE and not issecret(exp) and exp == 0) then
        learnedPermanent[spellID] = true
        learnedDuration[spellID] = nil
    elseif type(dur) == "number" and dur > 0 then
        learnedPermanent[spellID] = nil
        learnedDuration[spellID] = dur
    end
end

-- Sweeps both buff viewers so any aura the player has up while unrestricted is
-- learned, not just ones currently drawn on a row. Rarely used cooldowns would
-- otherwise stay unlearned for a long time.
local VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

function AC.LearnVisible()
    if AC.AurasRestricted() then return end
    for _, name in ipairs(VIEWERS) do
        local viewer = _G[name]
        local pool = viewer and viewer.itemFramePool
        if pool then
            pcall(function()
                for frame in pool:EnumerateActive() do
                    if frame.auraInstanceID ~= nil then AC.Learn(frame) end
                end
            end)
        end
    end
end

------------------------------------------------------------------------------
-- Aura start times
------------------------------------------------------------------------------

local auraStart = setmetatable({}, { __mode = "k" })

-- Stamped on first assignment only. The hook fires on every RefreshData, and
-- Blizzard calls ClearAuraInstanceInfo when the instance genuinely changes.
function AC.NoteAuraStart(frame)
    if frame and auraStart[frame] == nil then auraStart[frame] = GetTime() end
end

function AC.ClearAuraStart(frame)
    if frame then auraStart[frame] = nil end
end

function AC.GetAuraStart(frame)
    return frame and auraStart[frame] or nil
end

------------------------------------------------------------------------------
-- Fill resolution
------------------------------------------------------------------------------

-- Returns kind, payload, resolvedUnit:
--   "mirror",    StatusBar   read this widget's value each frame
--   "durobj",    DurObj      feed the DurationObject path
--   "permanent", nil         draw a full bar
--   nil                      no usable timing
function AC.ResolveFill(frame, unit)
    if not frame then return nil end

    local spellID = AC.GetConfigSpellID(frame)

    if AC.IsPermanent(spellID) then
        return "permanent", nil
    end

    if not AC.AurasRestricted() then
        local iOk, iid = pcall(function() return frame.auraInstanceID end)
        if iOk and iid then
            local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, iid)
            if ok and durObj then return "durobj", durObj, unit end
            local cdmUnit = select(2, pcall(function() return frame.auraDataUnit end))
            if cdmUnit and cdmUnit ~= unit then
                local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, cdmUnit, iid)
                if rOk and rDur then return "durobj", rDur, cdmUnit end
            end
        end
    end

    local okBar, bar = pcall(function() return frame.Bar end)
    if okBar and bar and bar.GetValue then
        return "mirror", bar
    end

    local dur = AC.GetLearnedDuration(spellID)
    local start = AC.GetAuraStart(frame)
    if dur and start then
        local durObj = C_DurationUtil.CreateDuration()
        durObj:SetTimeFromStart(start, dur)
        return "durobj", durObj
    end

    return nil
end

------------------------------------------------------------------------------
-- Frame field reads
------------------------------------------------------------------------------

-- Application count. May be secret; only pass it to a widget setter.
function AC.ReadApplications(frame)
    if not frame then return nil end
    local ok, ad = pcall(function() return frame.auraDataCached end)
    if ok and ad then
        local okA, apps = pcall(function() return ad.applications end)
        if okA and apps ~= nil then return apps end
    end
    if AC.AurasRestricted() then return nil end
    local uOk, unit = pcall(function() return frame.auraDataUnit end)
    local iOk, iid = pcall(function() return frame.auraInstanceID end)
    if not iOk or not iid then return nil end
    local okD, d = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID,
        (uOk and unit) or "player", iid)
    if okD and d then return d.applications end
    return nil
end

-- Aura spell id for variant naming. May be secret; safe for GetSpellName.
function AC.ReadAuraSpellID(frame)
    if not frame then return nil end
    local ok, ad = pcall(function() return frame.auraDataCached end)
    if ok and ad then
        local okS, sid = pcall(function() return ad.spellId end)
        if okS and sid ~= nil then return sid end
    end
    return nil
end

------------------------------------------------------------------------------
-- Learning ticker
------------------------------------------------------------------------------

local learnTicker = CreateFrame("Frame")
learnTicker:RegisterEvent("PLAYER_LOGIN")
learnTicker:SetScript("OnEvent", function()
    C_Timer.NewTicker(2, AC.LearnVisible)
end)
