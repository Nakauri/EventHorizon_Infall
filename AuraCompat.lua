-- EventHorizon Infall: aura timing sources.
-- Bar-configured auras mirror the CDM's bar value; icon-configured auras use a
-- DurationObject built from a recorded start and a learned duration.

local ns = EventHorizon_Infall
local AC = {}
ns.AuraCompat = AC

local issecret = issecretvalue or function() return false end

-- Restriction state

local restrictedStamp = -1

-- True while aura queries raise an error for addons. The probe is the call itself:
-- C_Secrets.ShouldAurasBeSecret reports whether values are secret, not whether the
-- call is refused, so it is trusted to answer YES and never NO.
function AC.AurasRestricted()
    local now = GetTime()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        restrictedStamp = now
        return true
    end
    if now == restrictedStamp then return true end
    if pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL") then
        return false
    end
    restrictedStamp = now
    return true
end

-- Learned aura data, keyed by spell id

local learnedDuration = {}
local learnedPermanent = {}

function AC.LoadDB()
    InfallDB = InfallDB or {}
    InfallDB.auraDurations = InfallDB.auraDurations or {}
    InfallDB.auraPermanent = InfallDB.auraPermanent or {}
    InfallDB.auraEstimateOff = InfallDB.auraEstimateOff or {}
    -- Rekeyed from spellID to cooldownID; the old contents cannot be matched across.
    if InfallDB.auraEstimateUsedVer ~= 2 then
        InfallDB.auraEstimateUsed, InfallDB.auraEstimateUsedVer = {}, 2
    end
    InfallDB.auraEstimateUsed = InfallDB.auraEstimateUsed or {}
    learnedDuration = InfallDB.auraDurations
    learnedPermanent = InfallDB.auraPermanent
end

-- The cooldown ENTRY a frame belongs to. One spell can hold a fed Tracked Bars
-- entry and an unfed Essential one, so the estimate flag cannot be per spell.
local function FrameCdID(frame)
    if not frame then return nil end
    local ok, cdID = pcall(function() return frame.cooldownID end)
    if not ok then return nil end
    return cdID
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

    -- Item entries carry no spellID, so learning and permanence would key off nothing
    -- and the aura falls through to a mirror that renders permanent buffs empty. The
    -- cooldownID is the CDM's own identity; namespace it against spellIDs.
    if info.equipSlot or info.spellCategoryID then
        return "cd:" .. tostring(cdID)
    end
    return nil
end

-- True while an estimate is what currently drives this ENTRY's bar. Most bars are
-- fed by the game and their measurement is never used, so this is what separates
-- the entries worth marking in the UI from the rest.
function AC.IsEstimateUsed(cdID)
    return cdID ~= nil and InfallDB and InfallDB.auraEstimateUsed
        and InfallDB.auraEstimateUsed[cdID] == true or false
end

-- Both write only on a change: ResolveFill runs from the buff poll, not once.
local function NoteEstimateUsed(cdID)
    if cdID == nil then return end
    InfallDB = InfallDB or {}
    InfallDB.auraEstimateUsed = InfallDB.auraEstimateUsed or {}
    if InfallDB.auraEstimateUsed[cdID] ~= true then
        InfallDB.auraEstimateUsed[cdID] = true
    end
end

-- Real timing arriving is what retires the notice. Without this the flag latches
-- for the life of the profile and the tooltip keeps claiming the bar is unfed.
local function ClearEstimateUsed(cdID)
    if cdID == nil then return end
    local t = InfallDB and InfallDB.auraEstimateUsed
    if t and t[cdID] ~= nil then t[cdID] = nil end
end

-- Absence means allowed, so a profile written before this existed is unchanged.
function AC.IsEstimateAllowed(spellID)
    if spellID == nil then return true end
    return not (InfallDB and InfallDB.auraEstimateOff
        and InfallDB.auraEstimateOff[spellID])
end

function AC.SetEstimateAllowed(spellID, allowed)
    if spellID == nil then return end
    AC.LoadDB()
    InfallDB.auraEstimateOff[spellID] = (not allowed) and true or nil
end

function AC.LearnedPermanent(spellID)
    if not spellID then return false end
    return learnedPermanent[spellID] == true
end

-- Drops learned aura state. It lives in SavedVariables, so a reinstall does not clear it.
function AC.ForgetLearned()
    AC.LoadDB()
    local n = 0
    for k in pairs(InfallDB.auraPermanent) do
        InfallDB.auraPermanent[k] = nil
        n = n + 1
    end
    for k in pairs(InfallDB.auraDurations) do
        InfallDB.auraDurations[k] = nil
        n = n + 1
    end
    learnedPermanent = InfallDB.auraPermanent
    learnedDuration = InfallDB.auraDurations
    return n
end

function AC.GetLearnedDuration(spellID)
    if not spellID then return nil end
    return learnedDuration[spellID]
end

-- Returns state, detail for display:
--   "permanent" | "learned" (detail = seconds) | "unlearned"
function AC.GetLearnState(spellID)
    if not spellID then return "unlearned" end
    if AC.LearnedPermanent(spellID) then return "permanent" end
    local dur = learnedDuration[spellID]
    if dur then return "learned", dur end
    return "unlearned"
end

-- Learn state for a cooldown ENTRY, matched across every id it can present.
function AC.GetLearnStateForFrame(frame)
    if not frame then return "unlearned", nil, nil end
    local fOk, cdID = pcall(function() return frame.cooldownID end)
    if not fOk or not cdID then return "unlearned", nil, nil end
    return AC.GetLearnStateForCooldown(cdID)
end

function AC.GetLearnStateForCooldown(cdID)
    local ids = AC.IdentityIDsForCooldown(cdID)
    if not ids then return "unlearned", nil, nil end
    for i = 1, #ids do
        local state, detail = AC.GetLearnState(ids[i])
        if state ~= "unlearned" then return state, detail, ids[i] end
    end
    return "unlearned", nil, ids[1]
end

-- The one duration rule for permanence. A positive duration is tested first so a
-- transitional read cannot be mistaken for a no-expiry aura. Returns nil when unreadable.
local function PermanentFromDuration(dur)
    if type(dur) ~= "number" then return nil end
    if dur > 0 then return false end
    if dur == 0 then return true end
    return nil
end

-- Caches duration and permanence. No-op while auras are restricted.
function AC.Learn(frame)
    if AC.AurasRestricted() then return end
    local spellID = AC.GetConfigSpellID(frame)
    if not spellID then return end

    local ok, ad = pcall(function() return frame.auraDataCached end)
    if not ok or not ad then return end

    local okD, dur = pcall(function() return ad.duration end)
    if not okD or issecret(dur) then return end

    local perm = PermanentFromDuration(dur)
    if perm == false then
        learnedPermanent[spellID] = nil
        learnedDuration[spellID] = dur
    elseif perm == true then
        learnedPermanent[spellID] = true
        learnedDuration[spellID] = nil
    end
end

-- Sweeps every viewer, not just ones drawn on a row. The cooldown viewers are
-- included because an ability whose buff entry is never fed still reports its
-- aura on its own Essential or Utility frame.
local VIEWERS = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}

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

-- Aura start times

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

-- Spell identity

-- Every spell id one CDM entry can present. linkedSpellIDs is the only field
-- that names an untalented variant, because it is absent from the spellbook.
-- Keyed by cooldownID, never by frame: frames are recycled.
local identityCache = {}

function AC.ClearIdentityCache()
    wipe(identityCache)
end

local function AddID(set, list, id)
    if type(id) ~= "number" or id <= 0 or set[id] then return end
    set[id] = true
    list[#list + 1] = id
end

local function AddDerived(set, list, fn, id)
    if type(fn) ~= "function" then return end
    local ok, res = pcall(fn, id)
    if ok then AddID(set, list, res) end
end

-- Ordered by the Cooldown Manager's own precedence: linked spells, then the
-- tooltip override, then the override, then the base.
function AC.IdentityIDsForCooldown(cdID)
    if not cdID then return nil end

    local cached = identityCache[cdID]
    if cached ~= nil then return cached or nil end

    local tierSpell = ns.TierSpellIDForCooldown and ns.TierSpellIDForCooldown(cdID)
    if tierSpell then
        local tierList = { tierSpell }
        identityCache[cdID] = tierList
        return tierList
    end

    local iOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if not iOk or not info then return nil end

    local set, list = {}, {}
    if type(info.linkedSpellIDs) == "table" then
        for _, id in ipairs(info.linkedSpellIDs) do AddID(set, list, id) end
    end
    AddID(set, list, info.overrideTooltipSpellID)
    AddID(set, list, info.overrideSpellID)
    AddID(set, list, info.spellID)

    -- Both directions: an entry can name either end of a transform.
    local seeded = #list
    for i = 1, seeded do
        AddDerived(set, list, C_Spell and C_Spell.GetOverrideSpell, list[i])
        AddDerived(set, list, C_Spell and C_Spell.GetBaseSpell, list[i])
    end

    -- No ids at all is an answer, not unknown. Item entries carry no spellID.
    -- Cached as false so the two tables above are not rebuilt on every call.
    if #list == 0 then
        identityCache[cdID] = false
        return nil
    end
    identityCache[cdID] = list
    return list
end

function AC.IdentityIDs(frame)
    if not frame then return nil end
    local fOk, cdID = pcall(function() return frame.cooldownID end)
    if not fOk or not cdID then return nil end
    return AC.IdentityIDsForCooldown(cdID)
end

-- Aura read by spell id

-- A spell the client flags secret answers exactly like one that is not there,
-- so the flag is read first rather than inferred from an empty result.
local function AuraReadable(id)
    if not C_Secrets or not C_Secrets.ShouldSpellAuraBeSecret then return true end
    local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
    if not ok then return false end
    return not secret
end

-- The only two aura reads a tainted caller may make while auras are secret.
local function ReadAura(unit, id)
    if unit == nil or unit == "player" then
        if not C_UnitAuras.GetPlayerAuraBySpellID then return nil end
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        return ok and aura or nil
    end
    if not C_UnitAuras.GetUnitAuraBySpellID then return nil end
    local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, id)
    return ok and aura or nil
end

-- One DurationObject per frame, rebuilt only when the aura's own timing moves.
-- The hidden Cooldown skips a re-feed by comparing pointers, so a fresh object
-- every tick would re-feed it forever and its OnCooldownDone would never fire.
local fillCache = setmetatable({}, { __mode = "k" })

-- Returns kind, payload for the first identity whose aura is live and reads
-- non-secret. Every DurationObject setter refuses secret arguments from a
-- tainted caller, so a secret duration is skipped, not half read.
local function AuraInstanceOf(aura)
    if not aura then return nil end
    local ok, iid = pcall(function() return aura.auraInstanceID end)
    if not ok or iid == nil or issecret(iid) then return nil end
    return iid
end

function AC.AuraFill(frame, unit)
    local ids = AC.IdentityIDs(frame)
    if not ids then return nil end

    for i = 1, #ids do
        local id = ids[i]
        if AuraReadable(id) then
            local aura = ReadAura(unit, id)
            if aura then
                local okD, dur = pcall(function() return aura.duration end)
                local okE, exp = pcall(function() return aura.expirationTime end)
                if okD and okE and not issecret(dur) and not issecret(exp)
                    and type(dur) == "number" and type(exp) == "number" then
                    if AC.IsAuraPermanent(unit, AuraInstanceOf(aura), dur) then
                        fillCache[frame] = nil
                        return "permanent", nil
                    end
                    local c = fillCache[frame]
                    if c and c.id == id and c.exp == exp and c.dur == dur then
                        return "durobj", c.durObj
                    end
                    local durObj = C_DurationUtil.CreateDuration()
                    durObj:SetTimeFromStart(exp - dur, dur)
                    fillCache[frame] = { id = id, exp = exp, dur = dur, durObj = durObj }
                    return "durobj", durObj
                end
            end
        end
    end
    fillCache[frame] = nil
    return nil
end

-- Stack count by spell id, nil when the buff is down or secret.
function AC.ApplicationsBySpellID(spellID)
    if not spellID or not AuraReadable(spellID) then return nil end
    local aura = ReadAura(nil, spellID)
    if not aura then return nil end
    local ok, apps = pcall(function() return aura.applications end)
    if not ok or apps == nil or issecret(apps) then return nil end
    return apps
end

-- True while that aura is on the player.
function AC.HasAuraBySpellID(spellID)
    if not spellID or not AuraReadable(spellID) then return false end
    return ReadAura(nil, spellID) ~= nil
end

-- true permanent, false expires, nil unknown or secret.
local function GameSaysPermanent(unit, iid)
    if not (C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime) then return nil end
    if not unit or not iid then return nil end
    local ok, hasExp = pcall(C_UnitAuras.DoesAuraHaveExpirationTime, unit, iid)
    if not ok or hasExp == nil or issecret(hasExp) then return nil end
    return hasExp == false
end

-- The single question. The game's answer wins; the duration read is the fallback for
-- when it will not answer. Every fill path asks through here.
function AC.IsAuraPermanent(unit, iid, dur)
    if iid ~= nil then
        local live = GameSaysPermanent(unit, iid)
        if live ~= nil then return live end
    end
    return PermanentFromDuration(dur)
end

-- Fill resolution

-- Returns kind, payload, resolvedUnit: "mirror" widget, "durobj" object, "permanent", or nil.

local function ResolveFillInner(frame, unit)
    local spellID = AC.GetConfigSpellID(frame)

    -- Matched across every id the entry can present, never on one field.
    local learnState, learnDur, learnKey = AC.GetLearnStateForFrame(frame)

    local restricted = AC.AurasRestricted()
    local iOk, iid = pcall(function() return frame.auraInstanceID end)
    -- select(2, pcall(...)) hands back the error string on failure, which then
    -- travels as a unit token. Nil is the only honest answer.
    local uOk, cdmUnit = pcall(function() return frame.auraDataUnit end)
    if not uOk then cdmUnit = nil end

    -- The game's own answer wins. The learned flag is only the fallback for when it
    -- cannot be read, which is auras on a restricted map.
    local live
    if not restricted and iOk and iid then
        live = AC.IsAuraPermanent(unit, iid, nil)
        if live == nil and cdmUnit and cdmUnit ~= unit then
            live = AC.IsAuraPermanent(cdmUnit, iid, nil)
        end
    end
    if live == true then return "permanent", nil end
    if live == nil and learnState == "permanent" then return "permanent", nil end

    if not restricted and iOk and iid then
        local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, iid)
        if ok and durObj then return "durobj", durObj, unit end
        if cdmUnit and cdmUnit ~= unit then
            local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, cdmUnit, iid)
            if rOk and rDur then return "durobj", rDur, cdmUnit end
        end
    end

    -- No aura instance means nothing feeds the bar; the spell id read below covers it.
    local okIID, iid = pcall(function() return frame.auraInstanceID end)
    local okBar, bar = pcall(function() return frame.Bar end)
    local canMirror = (okBar and bar and bar.GetValue) and true or false

    if canMirror and okIID and iid ~= nil then
        return "mirror", bar
    end

    local kind, payload = AC.AuraFill(frame, unit)
    if kind then return kind, payload, unit end

    if canMirror then
        return "mirror", bar
    end

    -- Last resort, and the only estimated one: a measured length replayed from
    -- when the aura appeared. Needs one unrestricted sighting to learn, and it
    -- cannot follow a refresh, so the player can switch it off per spell.
    local start = AC.GetAuraStart(frame)
    local dur = learnDur or AC.GetLearnedDuration(spellID)
    local key = learnKey or spellID
    if dur and start then
        -- Flagged estimated either way: switched off still means the game is not
        -- feeding it, which is what the tooltip and the right click affordance say.
        if AC.IsEstimateAllowed(key) then
            local durObj = C_DurationUtil.CreateDuration()
            durObj:SetTimeFromStart(start, dur)
            return "durobj", durObj, nil, true
        end
        return nil, nil, nil, true
    end

    return nil
end

function AC.ResolveFill(frame, unit)
    if not frame then return nil end
    local kind, payload, resolved, estimated = ResolveFillInner(frame, unit)
    -- Runs per lane per row at 30Hz, and FrameCdID builds a closure for its pcall.
    -- Nothing to clear on an empty table, which is the normal case.
    local used = InfallDB and InfallDB.auraEstimateUsed
    if estimated then
        NoteEstimateUsed(FrameCdID(frame))
    elseif kind and used and next(used) ~= nil then
        ClearEstimateUsed(FrameCdID(frame))
    end
    return kind, payload, resolved
end

-- Frame field reads

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

local spellFillCache = {}

function AC.AuraFillBySpellID(spellID, unit)
    if not spellID or not AuraReadable(spellID) then
        spellFillCache[spellID or 0] = nil
        return nil
    end
    local aura = ReadAura(unit, spellID)
    if not aura then
        spellFillCache[spellID] = nil
        return nil
    end
    local okD, dur = pcall(function() return aura.duration end)
    local okE, exp = pcall(function() return aura.expirationTime end)
    if not okD or not okE or issecret(dur) or issecret(exp)
        or type(dur) ~= "number" or type(exp) ~= "number" then
        spellFillCache[spellID] = nil
        return nil
    end
    if AC.IsAuraPermanent(unit, AuraInstanceOf(aura), dur) then
        spellFillCache[spellID] = nil
        return "permanent", nil
    end
    local c = spellFillCache[spellID]
    if c and c.exp == exp and c.dur == dur and c.unit == unit then
        return "durobj", c.durObj
    end
    local durObj = C_DurationUtil.CreateDuration()
    durObj:SetTimeFromStart(exp - dur, dur)
    spellFillCache[spellID] = { exp = exp, dur = dur, durObj = durObj, unit = unit }
    return "durobj", durObj
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

-- Learning ticker

local learnTicker = CreateFrame("Frame")
learnTicker:RegisterEvent("PLAYER_LOGIN")
learnTicker:SetScript("OnEvent", function()
    C_Timer.NewTicker(2, AC.LearnVisible)
end)
