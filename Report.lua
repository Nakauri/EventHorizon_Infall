-- EventHorizon Infall, Report
-- Our errors and blocked actions raise one chat link per session; the window copies
-- a plain text report. Nothing runs per frame; no secret is ever written.

local ns = EventHorizon_Infall
local ADDON = ns.ADDON_NAME

local GITHUB_URL = "https://github.com/Nakauri/EventHorizon_Infall/issues"
local DISCORD_URL = "https://discord.gg/mR8xUUK"
local LOG_SMALL, LOG_DETAILED = 300, 3000
local WINDOW_LINES = 1000
local MAX_ERRORS, MAX_BLOCKED, MAX_FLASHES = 25, 30, 50
local SECRET_ERR = "Secret values are only allowed during untainted execution"

local R = {}
ns.Report = R

-- InfallDB exists from Core.lua's file load, but SavedVariables replace it at ADDON_LOADED;
-- anything written before then is thrown away, so nothing is written until then.
local svReady = false

local function DB()
    if not svReady or not InfallDB then return nil end
    local d = InfallDB.report
    if type(d) ~= "table" then
        d = {}
        InfallDB.report = d
    end
    if type(d.log) ~= "table" then d.log, d.head = {}, 0 end
    if type(d.errors) ~= "table" then d.errors = {} end
    if type(d.blocked) ~= "table" then d.blocked = {} end
    if type(d.head) ~= "number" then d.head = 0 end
    return d
end

local function Readable(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    if canaccessvalue and not canaccessvalue(v) then return "<secret>" end
    return tostring(v)
end

-- One clock: wall time anchored once, advanced by GetTime, so lines never run backwards.
local clockBase
local function Stamp()
    local now = GetTime()
    clockBase = clockBase or (time() - now)
    local t = clockBase + now
    return date("%H:%M:%S", math.floor(t)) .. string.format(".%02d", math.floor((t % 1) * 100))
end

local function SpellLabel(id)
    local ok, name = pcall(C_Spell.GetSpellName, id)
    name = ok and name and Readable(name) or "?"
    return name .. " (" .. Readable(id) .. ")"
end

-- The change log, icon flashes and history run only with debug logging on: always in
-- alpha and beta builds, otherwise only when the player ticks it. Players on a public
-- release record nothing but Infall's own errors and blocked actions.
local logOn, preRelease = false, false

local function UpdateLogOn()
    local d = DB()
    local v = C_AddOns.GetAddOnMetadata(ADDON, "Version") or ""
    preRelease = (v:find("alpha", 1, true) or v:find("beta", 1, true)) and true or false
    logOn = (d and d.detailed or preRelease) and true or false
end

function R.Log(text)
    if not logOn then return end
    local d = DB()
    if not d then return end
    local cap = LOG_DETAILED
    d.head = (d.head % cap) + 1
    d.log[d.head] = Stamp() .. " " .. text
    d.cap = cap
end

-- One line per row whenever its charge state changes. Feeds run 10 to 20 times a
-- second in combat, so repeats carry no information and are never written.
function ns.RecCharge(row, recharging, cdShown, timed)
    if not logOn then return end
    -- Combat is not in the signature: the combat start and end lines already mark it.
    local sig = (recharging and 1 or 0) + (cdShown and 2 or 0) + (timed and 4 or 0)
    if row._recSig == sig and row._recSpell == row.spellID then return end
    row._recSig, row._recSpell = sig, row.spellID
    R.Log(string.format("charge %s recharging=%d cd=%d timed=%d combat=%d",
        SpellLabel(row.spellID), sig % 2, math.floor(sig / 2) % 2,
        math.floor(sig / 4) % 2, InCombatLockdown() and 1 or 0))
end

-- One line when a charge row builds its past tracks for a new spell or lane count.
function ns.RecChargePast(row, lanes, ringN)
    if not logOn then return end
    if row._recCpSpell == row.spellID and row._recCpLanes == lanes then return end
    row._recCpSpell, row._recCpLanes = row.spellID, lanes
    R.Log(string.format("chargepast %s lanes=%d ringN=%d", SpellLabel(row.spellID), lanes, ringN or 0))
end

-- One line per buff lane whenever its route or its Blizzard frame changes. Runs every
-- update tick, so the unchanged case is two table reads and two compares.
local function Field(frame, key)
    local ok, v = pcall(function() return frame[key] end)
    if not ok then return "err" end
    return Readable(v)
end

-- One line per Blizzard buff frame whenever the KIND of stack count it gives changes
-- (secret, number or none), never the count itself. Feeds the stack gate decision.
-- Runs on every stack read in test builds: no closure, no string until it logs.
local stackKind = {}
local function RawField(t, k) return t[k] end
function ns.RecStack(frame, source, value)
    if not logOn then return end
    local secret = issecretvalue and issecretvalue(value)
    local kind = value == nil and "none" or secret and "secret" or type(value)
    local okC, cdm = pcall(RawField, frame, "cooldownID")
    local key = (okC and cdm ~= nil and not (issecretvalue and issecretvalue(cdm))) and cdm or frame
    local okA, aura = pcall(RawField, frame, "auraInstanceID")
    local live = (okA and aura ~= nil) and 1 or 0
    -- A plain count is logged so a change is visible; a secret one only as its kind.
    local num = (kind == "number") and value or nil
    local st = stackKind[key]
    if st and st.source == source and st.kind == kind and st.live == live and st.num == num then return end
    if not st then
        st = {}
        stackKind[key] = st
    end
    st.source, st.kind, st.live, st.num = source, kind, live, num
    local n = num and tostring(num) or "-"
    local ac = ns.AuraCompat
    local restricted = ac and ac.AurasRestricted and ac.AurasRestricted()
    R.Log(string.format("stack cdm=%s aura=%d source=%s kind=%s n=%s restricted=%s combat=%d",
        Readable(cdm), live, source, kind, n, Readable(restricted), InCombatLockdown() and 1 or 0))
end

-- The first named ancestor of a Cooldown Manager frame, which is the viewer that owns
-- it. Shared: AuraCompat records it for the Settings tooltip.
function ns.ViewerName(frame)
    local f = frame
    for _ = 1, 4 do
        local ok, p = pcall(function() return f:GetParent() end)
        if not ok or not p then return "?" end
        local okN, name = pcall(function() return p:GetName() end)
        if okN and type(name) == "string" then return name end
        f = p
    end
    return "?"
end

-- One line per cooldown entry whenever the estimate branch sees its frame's aura
-- instance change between readable, secret and none.
local estimateGate = {}
-- Runs on every estimated lane pass in test builds: no closure, no string until it logs.
local estimateGateVia = {}
local function ReadIID(f) return f.auraInstanceID end
-- DoT tick marks: which aura a row ticks, from where, and why nothing drew. Once per change;
-- runs every update from DotTicks, so the unchanged case is four compares.
function ns.RecTicks(row, spellID, fromCast, period, why)
    if not logOn then return end
    if row._tickLogSpell == spellID and row._tickLogWhy == why
        and row._tickLogUnit == row._tickUnit and row._tickLogCast == fromCast then return end
    row._tickLogSpell, row._tickLogWhy = spellID, why
    row._tickLogUnit, row._tickLogCast = row._tickUnit, fromCast
    R.Log(string.format("ticks %s spell=%s unit=%s fromCast=%s period=%.2f %s", Readable(row.spellName),
        Readable(spellID), Readable(row._tickUnit or "player"), Readable(fromCast), period or 0, why))
end

function ns.RecEstimateGate(frame, cdID, via)
    if not logOn or cdID == nil then return end
    local okA, iid = pcall(ReadIID, frame)
    local state = not okA and "err" or iid == nil and "none"
        or (issecretvalue and issecretvalue(iid)) and "secret" or "readable"
    if estimateGate[cdID] == state and estimateGateVia[cdID] == via then return end
    estimateGate[cdID], estimateGateVia[cdID] = state, via
    local ac = ns.AuraCompat
    local restricted = ac and ac.AurasRestricted and ac.AurasRestricted()
    R.Log(string.format("estimategate cdm=%s iid=%s via=%s viewer=%s restricted=%s combat=%d",
        Readable(cdID), state, Readable(via), ns.ViewerName(frame), Readable(restricted),
        InCombatLockdown() and 1 or 0))
end

-- Count and id sum of each static category set, with the spec id, logged when it
-- changes per stage. The spec id only: the profile key carries the character name.
local SET_CATS = { "Essential", "Utility", "TrackedBuff", "TrackedBar" }
local SET_CAT_FALLBACK = { Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3 }
local lastPrint = {}
function ns.RecSetFingerprint(stage)
    if not logOn then return end
    local get = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
    if not get then return end
    local enum = Enum and Enum.CooldownViewerCategory
    local parts = {}
    for _, name in ipairs(SET_CATS) do
        local cat = enum and enum[name]
        if cat == nil then cat = SET_CAT_FALLBACK[name] end
        local ok, set = pcall(get, cat, true)
        local n, sum, hidden = 0, 0, 0
        if ok and type(set) == "table" then
            for _, id in ipairs(set) do
                n = n + 1
                if type(id) == "number" and not (issecretvalue and issecretvalue(id)) then
                    sum = sum + id
                else
                    hidden = hidden + 1
                end
            end
            parts[#parts + 1] = string.format("%s=%d/%d%s", name, n, sum,
                hidden > 0 and ("/s" .. hidden) or "")
        else
            parts[#parts + 1] = name .. "=err"
        end
    end
    local specID = ns.SpecIDFor and ns.SpecIndex and ns.SpecIDFor(ns.SpecIndex())
    local sig = Readable(specID) .. " " .. table.concat(parts, " ")
    if lastPrint[stage] == sig then return end
    lastPrint[stage] = sig
    R.Log(string.format("setprint stage=%s spec=%s combat=%d", Readable(stage), sig,
        InCombatLockdown() and 1 or 0))
end

function ns.RecLane(row, lane, route, frame)
    if not logOn then return end
    local routes, frames = row._recLaneRoute, row._recLaneFrame
    if not routes or row._recLaneSpell ~= row.spellID then
        routes, frames = {}, {}
        row._recLaneRoute, row._recLaneFrame, row._recLaneSpell = routes, frames, row.spellID
    end
    local key = frame or false
    local via = frame and ns.AuraCompat and ns.AuraCompat.FillVia and ns.AuraCompat.FillVia(frame)
    if via then route = route .. "/" .. via end
    if routes[lane] == route and frames[lane] == key then return end
    routes[lane], frames[lane] = route, key
    local detail = ""
    if frame then
        local okA, aura = pcall(function() return frame.auraInstanceID end)
        local okT, totem = pcall(function() return frame.totemData end)
        local okB, bar = pcall(function() return frame.Bar end)
        detail = string.format(" cdm=%s active=%s aura=%d totem=%d bar=%d viewer=%s", Field(frame, "cooldownID"),
            Field(frame, "isActive"), (okA and aura ~= nil) and 1 or 0, (okT and totem ~= nil) and 1 or 0,
            (okB and bar ~= nil) and 1 or 0, ns.ViewerName(frame))
    end
    R.Log(string.format("lane %s %s %s%s combat=%d target=%d", Readable(row.spellName), lane, route,
        detail, InCombatLockdown() and 1 or 0, ns.HasTarget() and 1 or 0))
end

-- One line per icon state change, with how long the previous state lasted, so a flash
-- reads as a short-lived state. Runs on every paint; the unchanged case is one compare.
function ns.RecIcon(ic, entry, spellID, state)
    if not logOn then return end
    if ic._recEntry ~= entry then
        ic._recEntry, ic._recState, ic._recSince = entry, nil, nil
    end
    if ic._recState == state then return end
    local now = GetTime()
    local was = ic._recState
    local held = ic._recSince and (now - ic._recSince) or nil
    ic._recState, ic._recSince = state, now
    local label = spellID and SpellLabel(spellID) or "item"
    R.Log(string.format("icon %s %s%s combat=%d", label, state,
        was and string.format(", after %s for %.2fs", was, held) or "", InCombatLockdown() and 1 or 0))
    -- A state that lived under a second is a flash. Kept apart from the ring so a long
    -- session cannot scroll it away.
    local d = DB()
    if d and was and held and held < 1 then
        d.flashes = type(d.flashes) == "table" and d.flashes or {}
        if #d.flashes >= MAX_FLASHES then table.remove(d.flashes, 1) end
        d.flashes[#d.flashes + 1] = string.format("%s %s %s for %.2fs, then %s%s", date("%H:%M:%S"),
            label, was, held, state, InCombatLockdown() and ", in combat" or "")
    end
end

-- Which addon wrote a tainted field. issecurevariable returns false plus the writer.
local function Writer(t, key)
    if not issecurevariable then return nil end
    local ok, secure, by = pcall(issecurevariable, t, key)
    if ok and secure == false then return by or "unknown" end
    return nil
end

local function FindCulprits()
    local found = {}
    local function check(label, t, key)
        local by = Writer(t, key)
        if by then found[#found + 1] = label .. " tainted by " .. by end
    end
    for _, g in ipairs({ "ActionButton_UpdateCooldown", "ActionButton_ApplyCooldown", "pairs" }) do
        check(g, _G, g)
    end
    local fields = { "action", "spellID", "cooldown" }
    local buttons = ActionBarButtonEventsFrame and ActionBarButtonEventsFrame.frames
    if type(buttons) == "table" then
        for i = 1, #buttons do
            local b = buttons[i]
            local n = (b and b.GetName and b:GetName()) or ("button " .. i)
            check("button list slot " .. i, buttons, i)
            if type(b) == "table" then
                for _, k in ipairs(fields) do check(n .. "." .. k, b, k) end
            end
        end
    end
    return found
end

local prompted = false
local function Prompt()
    if prompted then return end
    prompted = true
    print("|cff00ff00[Infall]|r Something went wrong in Infall. "
        .. "|cff71d5ff|Haddon:" .. ADDON .. ":report|h[Copy report]|h|r")
end

local function IsOurs(msg, stack)
    return (msg and msg:find(ADDON, 1, true)) or (stack and stack:find(ADDON, 1, true))
end

-- Errors raised while later files load arrive before SavedVariables; hold a few until then.
-- A file that fails to load (the 200-local bug) errors exactly here.
local pending = {}

local function Capture(msg, stack, locals)
    local d = DB()
    if not d then
        if #pending < 10 then pending[#pending + 1] = { msg, stack, locals } end
        return
    end
    msg = Readable(msg):sub(1, 500)
    stack = stack and Readable(stack):sub(1, 3000) or ""
    local ours = IsOurs(msg, stack) and true or false
    local isTaint = msg:find(SECRET_ERR, 1, true) or msg:find("Lua Taint", 1, true)
    if not ours and not isTaint then return end
    if ours then
        locals = locals and Readable(locals):sub(1, 2000) or nil
    else
        -- Another addon's error: its locals hold that addon's data, so keep only where it broke.
        locals = nil
        stack = stack:match("^([^\n]*\n?[^\n]*)") or ""
    end
    for _, e in ipairs(d.errors) do
        if e.msg == msg then
            e.count = e.count + 1
            if ours then Prompt() end
            return
        end
    end
    if #d.errors >= MAX_ERRORS then table.remove(d.errors, 1) end
    d.errors[#d.errors + 1] = {
        msg = msg, stack = stack, locals = locals,
        count = 1, ours = ours, when = date("%Y-%m-%d %H:%M"),
        culprits = isTaint and FindCulprits() or nil,
    }
    R.Log((ours and "error " or "taint error ") .. msg:sub(1, 120))
    if ours then Prompt() end
end

-- Runs at file load so load-time errors are caught, and again at login in case BugGrabber
-- loaded after us and replaced the handler.
local hookedBugGrabber, chained = false, false
local function InstallErrorHook()
    local bg = BugGrabber
    if bg and bg.RegisterCallback then
        if hookedBugGrabber then return end
        local ok = pcall(bg.RegisterCallback, R, "BugGrabber_BugGrabbed", function(_, err)
            if type(err) == "table" then pcall(Capture, err.message, err.stack, err.locals) end
        end)
        if ok then hookedBugGrabber = true return end
    end
    if chained then return end
    chained = true
    local prev = geterrorhandler()
    seterrorhandler(function(msg, ...)
        pcall(Capture, msg, debugstack(2))
        if prev then return prev(msg, ...) end
    end)
end

local function OnBlocked(event, who, func)
    local d = DB()
    if not d then return end
    who, func = Readable(who), Readable(func)
    if #d.blocked >= MAX_BLOCKED then table.remove(d.blocked, 1) end
    local _, zone = IsInInstance()
    if not func:find("%)$") then func = func .. "()" end
    d.blocked[#d.blocked + 1] = string.format("%s %s %s by %s, %s, %s",
        date("%H:%M:%S"), event == "ADDON_ACTION_FORBIDDEN" and "forbidden" or "blocked",
        func, who, (zone and zone ~= "none") and zone or "open world",
        InCombatLockdown() and "in combat" or "out of combat")
    if who == ADDON then Prompt() end
end

-- The report -----------------------------------------------------------------

local function AddonList()
    local out = {}
    local get = C_AddOns and C_AddOns.GetNumAddOns
    if not get then return out end
    for i = 1, C_AddOns.GetNumAddOns() do
        if C_AddOns.IsAddOnLoaded(i) then
            local name = C_AddOns.GetAddOnInfo(i)
            local v = C_AddOns.GetAddOnMetadata(i, "Version")
            out[#out + 1] = name .. (v and (" " .. v) or "")
        end
    end
    table.sort(out)
    return out
end

-- The report is pasted in public, so the character's name and realm, and every name and
-- realm in the saved profile keys, become placeholders. Built only when the window opens.
local WORD = "\128-\255%w"
local function PlainString(v)
    if type(v) ~= "string" or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local function IdentityWords()
    local words, seen = {}, {}
    local function addWord(s, placeholder)
        s = PlainString(s)
        if not s or #s < 2 or s == "Unknown" or seen[s] then return end
        seen[s] = true
        words[#words + 1] = { s, placeholder }
    end
    addWord(UnitName("player"), "<player>")
    if GetRealmName then addWord(GetRealmName(), "<realm>") end
    if GetNormalizedRealmName then addWord(GetNormalizedRealmName(), "<realm>") end
    local profiles = InfallDB and InfallDB.profiles
    if type(profiles) == "table" then
        for key in pairs(profiles) do
            local who = type(key) == "string" and key:match("^(.+)%-%d+$")
            local name = who and who:match("^[^%-]+")
            if name then
                addWord(name, "<player>")
                addWord(who:sub(#name + 2), "<realm>")
            end
        end
    end
    -- Longest first, so a realm that contains a name is replaced whole.
    table.sort(words, function(a, b) return #a[1] > #b[1] end)
    for _, w in ipairs(words) do
        w[1] = "%f[" .. WORD .. "]" .. w[1]:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "%f[^" .. WORD .. "]"
    end
    return words
end

local function Scrub(text, words)
    for _, w in ipairs(words) do text = string.gsub(text, w[1], w[2]) end
    return text
end

function R.Build()
    local d = DB() or { log = {}, errors = {}, blocked = {}, head = 0 }
    local lines, scrubbed = {}, {}
    local function add(s) lines[#lines + 1] = s end
    local words = IdentityWords()
    local build, buildNum = GetBuildInfo()
    local className = UnitClass("player")
    local specName
    if ns.SpecIndex and ns.SpecInfo then
        local _, name = ns.SpecInfo(ns.SpecIndex())
        specName = name
    end
    local _, instType = IsInInstance()
    add("EventHorizon Infall report")
    add("Infall " .. Readable(C_AddOns.GetAddOnMetadata(ADDON, "Version")) .. ", WoW " .. build .. "." .. buildNum)
    add(Readable(specName) .. " " .. Readable(className) .. ", "
        .. ((instType and instType ~= "none") and instType or "open world")
        .. ", debug logging " .. (logOn and "on" or "off") .. (preRelease and " (test build)" or ""))
    add("")
    add("Errors (" .. #d.errors .. "):")
    for _, e in ipairs(d.errors) do
        add(string.format("[%s] x%d %s%s", e.when or "?", e.count or 1, e.ours and "" or "(not Infall) ", e.msg))
        if e.culprits and #e.culprits > 0 then
            for _, c in ipairs(e.culprits) do add("  culprit: " .. c) end
        elseif e.culprits then
            add("  culprit: none found in the action bar checks")
        end
        if e.stack and e.stack ~= "" then add("  " .. e.stack:gsub("\n", "\n  ")) end
        -- Scrubbed before the cut, so a name split by it cannot survive in part.
        if type(e.locals) == "string" then
            add("  locals: " .. Scrub(e.locals, words):sub(1, 600):gsub("\n", "\n  "))
            scrubbed[#lines] = true
        end
    end
    add("")
    add("Blocked actions (" .. #d.blocked .. "):")
    for _, b in ipairs(d.blocked) do add("  " .. b) end
    add("")
    local flashes = type(d.flashes) == "table" and d.flashes or {}
    add("Icon flashes, states under a second (" .. #flashes .. "):")
    for _, f in ipairs(flashes) do add("  " .. f) end
    add("")
    local cap = d.cap or LOG_SMALL
    local ring = {}
    for i = 1, cap do
        local line = d.log[((d.head + i - 1) % cap) + 1]
        if line then ring[#ring + 1] = line end
    end
    local n = #ring
    local first = math.max(1, n - WINDOW_LINES + 1)
    add("Change log (" .. n .. " lines" .. (first > 1 and (", newest " .. WINDOW_LINES .. " shown") or "")
        .. ", oldest first):")
    for i = first, n do add("  " .. ring[i]) end
    add("")
    local bars = ns.cooldownBars or {}
    local maps = ns.CONFIG and ns.CONFIG.buffMappings or {}
    add("Bars (" .. #bars .. "):")
    for _, row in ipairs(bars) do
        local paired = maps[row.cooldownID]
        local n = type(paired) == "table" and #paired or 0
        -- Item rows (potions, healthstones) carry no spellID, only the row's own name.
        local label = row.spellID and SpellLabel(row.spellID)
            or (Readable(row.spellName or "unnamed") .. " (item)")
        add(string.format("  %s, cooldown %s%s, %d buff%s paired%s", label,
            Readable(row.cooldownID), row.isChargeSpell and (", " .. Readable(row.maxCharges) .. " charges") or "",
            n, n == 1 and "" or "s", row:IsShown() and "" or ", hidden"))
    end
    add("")
    local key = ns.currentSpecKey
    local profile = key and InfallDB and InfallDB.profiles and InfallDB.profiles[key]
    local ok, str = pcall(function() return profile and ns.ExportProfile and ns.ExportProfile(profile, true) end)
    add("Profile (import this to see their setup):")
    -- The export is encoded; a replacement inside it would break the import.
    add((ok and type(str) == "string" and str) or "  unavailable")
    scrubbed[#lines] = true
    add("")
    add("Loaded addons: " .. table.concat(AddonList(), ", "))
    for i = 1, #lines do
        if not scrubbed[i] then lines[i] = Scrub(lines[i], words) end
    end
    return table.concat(lines, "\n"), #d.errors, #d.blocked, n
end

function R.Clear()
    local d = DB()
    if not d then return end
    d.log, d.head, d.errors, d.blocked, d.flashes = {}, 0, {}, {}, {}
end

-- A new Infall version starts a fresh report: older errors describe code that is gone.
local function ClearOnNewVersion()
    local d = DB()
    if not d then return end
    local v = C_AddOns.GetAddOnMetadata(ADDON, "Version")
    if d.version ~= v then
        d.log, d.head, d.errors, d.blocked, d.flashes, d.version = {}, 0, {}, {}, {}, v
    end
end

-- The window -----------------------------------------------------------------

local win

local function CopyBox(parent, label, url, anchor)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)
    fs:SetWidth(64)
    fs:SetJustifyH("LEFT")
    fs:SetText(label)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetAutoFocus(false)
    eb:SetHeight(24)
    eb:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    eb:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
    eb:SetText(url)
    eb:SetCursorPosition(0)
    eb:SetScript("OnTextChanged", function(self, user) if user then self:SetText(url) self:HighlightText() end end)
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:SetScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return fs
end

local function Refresh()
    local text, errs, blocked, lines = R.Build()
    win.text = text
    win.edit:SetText(text)
    win.edit:SetCursorPosition(0)
    win.status:SetText(string.format("%d %s, %d blocked %s, %d %s logged",
        errs, errs == 1 and "error" or "errors", blocked, blocked == 1 and "action" or "actions",
        lines, lines == 1 and "change" or "changes"))
    win.detail:SetChecked(logOn)
    if preRelease then
        win.detail:Disable()
        win.sub:SetText("Always on in test builds.")
    else
        win.detail:Enable()
        win.sub:SetText("Records what Infall is doing, so a bug can be traced. Off unless you turn it on.")
    end
    win.hint:SetText("")
end

local function CreateWindow()
    win = CreateFrame("Frame", "InfallReportFrame", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(620, 500)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "InfallReportFrame")
    win.TitleText:SetText("Infall report")

    local intro = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    intro:SetPoint("TOPLEFT", 20, -36)
    intro:SetPoint("RIGHT", win, "RIGHT", -20, 0)
    intro:SetJustifyH("LEFT")
    intro:SetText("Found a bug? Send us this report on GitHub or Discord.")

    local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("RIGHT", win, "RIGHT", -40, 0)
    scroll:SetHeight(220)
    local bg = scroll:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", -4, 4)
    bg:SetPoint("BOTTOMRIGHT", 4, -4)
    bg:SetColorTexture(0, 0, 0, 0.45)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontSmall")
    edit:SetWidth(540)
    edit:SetScript("OnTextChanged", function(self, user) if user then self:SetText(win.text or "") self:HighlightText() end end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    win.edit = edit

    local copy = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    copy:SetSize(160, 32)
    copy:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -16)
    -- CopyToClipboard is forbidden to addons, so the player copies with Ctrl+C.
    copy:SetText("Select all")
    copy:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
        win.hint:SetText("Now press Ctrl+C, then paste it into Discord or GitHub.")
    end)

    win.hint = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.hint:SetPoint("LEFT", copy, "RIGHT", 12, 0)
    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.status:SetPoint("TOPLEFT", copy, "BOTTOMLEFT", 0, -8)

    local gh = CopyBox(win, "GitHub", GITHUB_URL, win.status)
    local dc = CopyBox(win, "Discord", DISCORD_URL, gh)

    local detail = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    detail:SetPoint("TOPLEFT", dc, "BOTTOMLEFT", -4, -14)
    detail.text = detail.text or detail.Text
    if detail.text then detail.text:SetText("Debug logging") end
    detail:SetScript("OnClick", function(self)
        local d = DB()
        if d then
            d.detailed = self:GetChecked() and true or nil
            UpdateLogOn()
            if not logOn then d.log, d.head, d.flashes = {}, 0, {} end
            R.Log("debug logging on")
        end
        Refresh()
    end)
    win.detail = detail
    local sub = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("LEFT", detail.text or detail, "RIGHT", 8, 0)
    win.sub = sub

    local clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clear:SetSize(80, 24)
    clear:SetPoint("BOTTOMRIGHT", -20, 16)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function() R.Clear() Refresh() end)
    clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear the report")
        GameTooltip:AddLine("Removes errors, blocked actions and the change log. Bars and profile stay.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    clear:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function R.Open()
    if not win then CreateWindow() end
    Refresh()
    win:Show()
end

-- Settings header button, beside the version text. Called by Settings.lua; adds no local there.
function ns.AddReportButton(parent, after)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(72, 22)
    b:SetPoint("LEFT", after, "RIGHT", 12, 0)
    b:SetText("Report")
    b:SetScript("OnClick", R.Open)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Report a problem")
        GameTooltip:AddLine("Errors and recent events, ready to send to us.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Wiring ---------------------------------------------------------------------

pcall(InstallErrorHook)

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_ACTION_BLOCKED")
ev:RegisterEvent("ADDON_ACTION_FORBIDDEN")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        pcall(OnBlocked, event, a1, a2)
    elseif event == "ADDON_LOADED" and a1 == ADDON then
        svReady = true
        pcall(ClearOnNewVersion)
        pcall(UpdateLogOn)
        for _, p in ipairs(pending) do pcall(Capture, p[1], p[2], p[3]) end
        pending = {}
    elseif event == "PLAYER_LOGIN" then
        pcall(InstallErrorHook)
        EventRegistry:RegisterCallback("SetItemRef", function(_, link)
            if type(link) == "string" and link == "addon:" .. ADDON .. ":report" then
                C_Timer.After(0, R.Open)
            end
        end, R)
        R.Log("login")
    elseif event == "PLAYER_REGEN_DISABLED" then
        R.Log("combat start")
    elseif event == "PLAYER_REGEN_ENABLED" then
        R.Log("combat end")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        local _, t = IsInInstance()
        R.Log("zone " .. Readable(GetRealZoneText()) .. " (" .. (t or "none") .. ")")
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" and a1 == "player" then
        -- Each swap logs its own first reading at every stage.
        wipe(lastPrint)
        R.Log("spec change")
    end
end)
