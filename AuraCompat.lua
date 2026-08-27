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
--
-- Only the restricted answer is cached, and only for the frame it was taken on.
-- Caching a clear answer sends callers into a call that is refused for the rest of
-- that frame; caching a restricted one costs at most one frame of display. The
-- refused probe is also the expensive one, since it builds a real Lua error.
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
    InfallDB.auraPermanentUser = InfallDB.auraPermanentUser or {}
    InfallDB.auraEstimateOff = InfallDB.auraEstimateOff or {}
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

    -- Item entries carry no spellID, so learning and permanence would key off nothing
    -- and the aura falls through to a mirror that renders permanent buffs empty. The
    -- cooldownID is the CDM's own identity; namespace it against spellIDs.
    if info.equipSlot or info.spellCategoryID then
        return "cd:" .. tostring(cdID)
    end
    return nil
end

-- True once an estimate has actually driven this spell's bar. Most bars are fed
-- by the game and their measurement is never used, so this is what separates the
-- entries worth marking in the UI from the rest.
function AC.IsEstimateUsed(spellID)
    return spellID ~= nil and InfallDB and InfallDB.auraEstimateUsed
        and InfallDB.auraEstimateUsed[spellID] == true or false
end

local function NoteEstimateUsed(spellID)
    if spellID == nil then return end
    InfallDB = InfallDB or {}
    InfallDB.auraEstimateUsed = InfallDB.auraEstimateUsed or {}
    InfallDB.auraEstimateUsed[spellID] = true
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

-- Learn state for a cooldown ENTRY, matched across every id it can present.
-- Returns state, detail, and the id the state is stored under; per spell
-- settings must key on that id. A single field never matches, because the entry
-- paired and the frame measured are often different entries.
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
    if cached then return cached end

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

    if #list == 0 then return nil end
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
                    if dur == 0 or exp == 0 then
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

-- Fill resolution

-- Returns kind, payload, resolvedUnit:
--   "mirror",    StatusBar   read this widget's value each frame
--   "durobj",    DurObj      feed the DurationObject path
--   "permanent", nil         draw a full bar
--   nil                      no usable timing

function AC.ResolveFill(frame, unit)
    if not frame then return nil end

    local spellID = AC.GetConfigSpellID(frame)

    -- Matched across every id the entry can present, never on one field. A
    -- transform changes which id the aura was measured under, so a lookup fixed
    -- to the live override loses the measurement the moment talents move. The
    -- config id is always in that set, so this covers IsPermanent too.
    local learnState, learnDur, learnKey = AC.GetLearnStateForFrame(frame)

    if learnState == "permanent" then
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

    -- A frame with no aura instance has nothing feeding its bar, so a mirror
    -- would read an empty widget. The spell id read below covers that case, but
    -- only where a frame exists at all: an entry the player has not learned is
    -- given no frame, and nothing here can reach it.
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
        NoteEstimateUsed(key)
        if AC.IsEstimateAllowed(key) then
            local durObj = C_DurationUtil.CreateDuration()
            durObj:SetTimeFromStart(start, dur)
            return "durobj", durObj
        end
    end

    return nil
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
