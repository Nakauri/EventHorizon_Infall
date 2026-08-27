-- EventHorizon Infall: icon strip.
-- Containers on an edge of the EH frame holding Cooldown Manager entries.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local ICON = {}
ns.Icons = ICON

-- Settings

local CONTAINER_DEFAULTS = {
    anchor  = "TOP",       -- TOP BOTTOM LEFT RIGHT, relative to the EH frame
    grow    = "RIGHT",     -- LEFT RIGHT CENTRE on TOP/BOTTOM; UP DOWN CENTRE on LEFT/RIGHT
    mode    = "compact",   -- compact | fixed
    width   = 32,
    height  = 32,
    spacing = 2,
    perLine = 12,
    gap     = 4,           -- distance from the EH frame edge
    zoom    = 0.08,        -- border trim, applied on the short axis and cropped

    -- Whole-container alpha by situation, multiplying with each icon's state
    -- alpha. Idle at 0 is redshift. Defaults reproduce the old behaviour.
    alphaCombat = 1,
    alphaTarget = 1,
    alphaIdle   = 0,

    -- Which side of the stack pips and the resource bar the strip sits on.
    -- outside keeps it furthest from the frame, inside puts it between them.
    edgeOrder = "outside",
}

-- Precedence buff > cooldown > recharging > proc > unusable > ready.
-- `show` takes a slot, `opacity` draws. Glow is not a state: a proc can run under a buff.
local STATE_DEFAULTS = {
    ready    = { show = true, opacity = 1,    desaturate = false, sweep = "none", timer = false },
    buff     = { show = true, opacity = 1,    desaturate = false, sweep = "buff", timer = true,
                 buffIcon = false },
    cooldown = { show = true, opacity = 1,    desaturate = true,  sweep = "cd",   timer = true  },

    -- A charge spell with a spare charge: recharging AND castable. Not greyed by
    -- default, because grey reads as unavailable and it is not.
    recharging = { show = true, opacity = 1, desaturate = false, sweep = "cd", timer = true },
    proc     = { show = true, opacity = 1,    desaturate = false, sweep = "none", timer = false },
    unusable = { show = true, opacity = 0.4,  desaturate = true,  sweep = "none", timer = false },

    -- Charge or stack count. Corner placement by default, the way the game's own
    -- icons read.
    count    = { show = true, text = { anchor = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT",
                                       offsetX = -3, offsetY = 3, color = { 1, 1, 1, 1 } } },
}

-- Colour and text live per state too, so the same icon can read one way on
-- cooldown and another under a buff without a second mechanism.
local SWEEP_COLOR_DEFAULT = { 0, 0, 0, 0.55 }
local WEDGE_COLOR_DEFAULT = { 1, 0.92, 0.6, 0.28 }

local TEXT_DEFAULT = {
    color = { 1, 1, 1, 1 },
    anchor = "CENTER",
    relPoint = "CENTER",
    offsetX = 0,
    offsetY = 0,
}

-- Blizzard scales the countdown font to the icon. Theirs are 50px Essential and
-- 30px Utility, so the changeover sits between the two.
local function CountdownFont(cfg)
    return math.min(cfg.width or 32, cfg.height or 32) >= 40
        and "GameFontHighlightHugeOutline" or "GameFontHighlightOutline"
end

-- A modal can force one icon to render a state, so a buff's look can be edited
-- with no buff up. Values are stand-ins; the paint path is the real one.
ICON.preview = nil

local function ColorOf(rules, field, fallback)
    local c = rules and rules[field]
    if type(c) == "table" and c[1] then return c end
    return fallback
end

local function TextCfg(rules)
    local t = rules and rules.text
    if type(t) ~= "table" then return TEXT_DEFAULT end
    return t
end

local function TextField(t, key)
    if t[key] ~= nil then return t[key] end
    return TEXT_DEFAULT[key]
end

-- Only leaves Blizzard's font object once the profile asks for a change.
local function ApplyTextStyle(fs, tcfg, anchorTo)
    local fontPath = TextField(tcfg, "font")
    local fontSize = TextField(tcfg, "size")
    local fontFlags = TextField(tcfg, "flags")
    if fontPath or fontSize or fontFlags then
        local baseF, baseS, baseFl = fs:GetFont()
        pcall(fs.SetFont, fs, fontPath or CONFIG.font or baseF,
            fontSize or baseS, fontFlags or baseFl)
    end
    fs:SetTextColor(unpack(TextField(tcfg, "color")))
    fs:ClearAllPoints()
    fs:SetPoint(TextField(tcfg, "anchor"), anchorTo, TextField(tcfg, "relPoint"),
        TextField(tcfg, "offsetX"), TextField(tcfg, "offsetY"))
end

-- The engine draws the countdown, so its face comes from a named font object and
-- never from a FontString. One object per icon, created on first restyle.
local countdownFonts = 0

local function StyleCountdown(ic, tcfg, cfg)
    if not ic.cd.SetCountdownFont then return end

    local base   = CountdownFont(cfg)
    local path   = TextField(tcfg, "font")
    local size   = TextField(tcfg, "size")
    local flags  = TextField(tcfg, "flags")
    local color  = TextField(tcfg, "color")
    local anchor = TextField(tcfg, "anchor")
    local rel    = TextField(tcfg, "relPoint")
    local offX   = TextField(tcfg, "offsetX")
    local offY   = TextField(tcfg, "offsetY")

    -- Only the face is guarded: swapping a font object relayouts the string, and
    -- a new cooldown reasserts Blizzard's own placement, so colour and points are
    -- reapplied every pass the way the other two strings already are.
    local sig = base .. "|" .. tostring(path) .. "|" .. tostring(size) .. "|" .. tostring(flags)
    if ic.cdFaceSig ~= sig then
        ic.cdFaceSig = sig
        if not path and not size and not flags then
            pcall(ic.cd.SetCountdownFont, ic.cd, base)
        else
            if not ic.cdFontName then
                countdownFonts = countdownFonts + 1
                ic.cdFontName = "EHInfallIconCountdown" .. countdownFonts
                CreateFont(ic.cdFontName)
            end
            local fo, baseObj = _G[ic.cdFontName], _G[base]
            local bF, bS, bFl = "Fonts\\FRIZQT__.TTF", 12, "OUTLINE"
            if baseObj and baseObj.GetFont then
                local gF, gS, gFl = baseObj:GetFont()
                bF, bS, bFl = gF or bF, gS or bS, gFl or bFl
            end
            if fo then
                -- SetFont reports a bad path by returning false rather than
                -- erroring, and leaves the object with no face at all.
                local okSet, took = pcall(fo.SetFont, fo, path or CONFIG.font or bF,
                    size or bS, flags or bFl)
                if okSet and took == false then
                    pcall(fo.SetFont, fo, bF, size or bS, flags or bFl)
                end
                pcall(ic.cd.SetCountdownFont, ic.cd, ic.cdFontName)
            end
        end
    end

    -- The font object is inherited, so the engine can re-derive from it on any
    -- update. Setting the string itself wins and is what the other two use.
    if not ic.cd.GetCountdownFontString then return end
    local ok, fs = pcall(ic.cd.GetCountdownFontString, ic.cd)
    if not ok or not fs then return end
    if path or size or flags then
        local cF, cS, cFl = fs:GetFont()
        local wantF = path or CONFIG.font or cF
        local wantS = size or cS
        local wantFl = flags or cFl
        -- Never gate this on GetFont alone. SetCountdownFont above makes the
        -- string INHERIT the font object, so GetFont reports the wanted values
        -- straight back while the engine still draws its own derived size, and
        -- the raw call that would have won never runs. Driven off our own
        -- intent instead, and repeated whenever the engine disagrees.
        if ic.cdFSSig ~= sig or cF ~= wantF or cS ~= wantS or cFl ~= wantFl then
            ic.cdFSSig = sig
            local okSet, took = pcall(fs.SetFont, fs, wantF, wantS, wantFl)
            if okSet and took == false and wantF ~= cF then
                pcall(fs.SetFont, fs, cF, wantS, wantFl)
            end
        end
    else
        -- A raw SetFont on the string is permanent. SetCountdownFont above only
        -- swaps the object it INHERITS from, so a state carrying no text of its
        -- own would keep wearing whatever the last styled state left behind.
        local bObj = _G[base]
        if bObj and bObj.GetFont then
            local bF, bS, bFl = bObj:GetFont()
            local cF, cS, cFl = fs:GetFont()
            if bF and (cF ~= bF or cS ~= bS or cFl ~= bFl) then
                pcall(fs.SetFont, fs, bF, bS, bFl)
            end
        end
    end
    fs:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    fs:ClearAllPoints()
    -- Anchored to the Cooldown widget, never to the icon. Anchor it anywhere else
    -- and the engine re-centres it and re-derives its size from the host frame,
    -- which silently discards both the offsets and the font.
    fs:SetPoint(anchor, ic.cd, rel, offX, offY)
end

-- How much room the strip takes on an edge before the pips start, which is
-- nothing unless it is set to sit inside them.
function ICON.GetEdgeHeight(position)
    if not CONFIG.iconsEnabled then return 0 end
    for _, cfg in ipairs(CONFIG.iconContainers or {}) do
        if cfg.anchor == position and cfg.edgeOrder == "inside" then
            local f = ICON.GetContainerFrame and ICON.GetContainerFrame(cfg.key)
            if f and f:IsShown() then
                return (f:GetHeight() or 0) + (cfg.gap or 0)
            end
        end
    end
    return 0
end

ICON.CONTAINER_DEFAULTS = CONTAINER_DEFAULTS
ICON.STATE_DEFAULTS = STATE_DEFAULTS
ICON.TEXT_DEFAULTS = TEXT_DEFAULT
ICON.COLOR_DEFAULTS = { sweepColor = SWEEP_COLOR_DEFAULT, wedgeColor = WEDGE_COLOR_DEFAULT }

-- Merged on read so a profile written before a key existed still works.
local function Merged(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

-- Default, then global, then per-entry. Layered into scratch, never merged into
-- the saved tables: writing a default back would freeze it. Consumed at once.
local ruleScratch = {}
local textScratch = {}

-- Text only, never the rest of a state. A charge recharging draws the same
-- number as a cooldown does, so it follows the Cooldown page unless it has been
-- given text of its own. Desaturation and opacity stay independent, which is the
-- whole reason the two states are separate.
local TEXT_INHERIT = { recharging = "cooldown" }

local function RulesFor(entry, state)
    local def = STATE_DEFAULTS[state]
    local global = CONFIG.iconStates and CONFIG.iconStates[state]
    local per = entry.states and entry.states[state]

    local gText = global and global.text
    local pText = per and per.text
    local src = TEXT_INHERIT[state]
    if src and not gText and not pText then
        local g2 = CONFIG.iconStates and CONFIG.iconStates[src]
        local p2 = entry.states and entry.states[src]
        gText = g2 and g2.text
        pText = p2 and p2.text
    end

    if not global and not per and not gText and not pText then return def end

    for k, v in pairs(def) do ruleScratch[k] = v end
    if global then for k, v in pairs(global) do ruleScratch[k] = v end end
    if per then for k, v in pairs(per) do ruleScratch[k] = v end end

    -- Only count carries a default text table, so any other state with no text of
    -- its own kept whatever the previous lookup left here. count is the last
    -- lookup of every paint, which is how its font reached every other state.
    ruleScratch.text = def.text

    -- text is a table, so a plain overwrite would drop every field the per icon
    -- copy does not set and silently lose the general font behind one colour.
    if gText or pText then
        wipe(textScratch)
        if gText then for k, v in pairs(gText) do textScratch[k] = v end end
        if pText then for k, v in pairs(pText) do textScratch[k] = v end end
        ruleScratch.text = textScratch
    end

    return ruleScratch
end

-- Pixel grid. Satellites are never scaled: derive the pixel, size in multiples.

local OnePx  = ns.OnePxForFrame
local SnapPx = ns.SnapPx

-- Crops the square art to the icon's shape instead of stretching it.
local function IconTexCoord(w, h, zoom)
    local hx = 0.5 - (zoom or 0)
    local hy = hx
    if w > h then
        hy = hy * h / w
    elseif h > w then
        hx = hx * w / h
    end
    return 0.5 - hx, 0.5 + hx, 0.5 - hy, 0.5 + hy
end

-- `size` became width and height; oocOpacity and followRedshift became the three
-- context alphas. Old keys are cleared so a profile has one source of truth.
local function MigrateContainer(cfg)
    if cfg.size then
        cfg.width = cfg.width or cfg.size
        cfg.height = cfg.height or cfg.size
        cfg.size = nil
    end

    if cfg.oocOpacity ~= nil or cfg.followRedshift ~= nil then
        local ooc = cfg.oocOpacity or 1
        if cfg.alphaCombat == nil then cfg.alphaCombat = 1 end
        if cfg.alphaTarget == nil then cfg.alphaTarget = ooc end
        if cfg.alphaIdle == nil then
            cfg.alphaIdle = (cfg.followRedshift ~= false) and 0 or ooc
        end
        cfg.oocOpacity = nil
        cfg.followRedshift = nil
    end
end
ICON.MigrateContainer = MigrateContainer

-- A strip is keyed by the side it lives on. The single "main" container from
-- before becomes whichever side it was anchored to, and its icons go with it.
local function MigrateContainers()
    local list = CONFIG.iconContainers
    if not list then return end
    for _, cfg in ipairs(list) do
        MigrateContainer(cfg)
        if cfg.key == "main" then
            local side = cfg.anchor or "TOP"
            for _, e in ipairs(CONFIG.iconList or {}) do
                if (e.container or "main") == "main" then e.container = side end
            end
            cfg.key = side
        end
        cfg.anchor = cfg.key
    end
end
ICON.MigrateContainers = MigrateContainers

-- Any target, matching what redshift keys on.
local function ContextAlpha(cfg)
    if InCombatLockdown() then return cfg.alphaCombat or 1 end
    if UnitExists("target") then return cfg.alphaTarget or 1 end
    return cfg.alphaIdle or 0
end

-- Entry state

-- Buff pairing, modals and tracking all key off this. A Cooldown Manager entry
-- is its cooldownID; a custom icon has no cooldown and carries its own key.
function ICON.EntryID(entry)
    return entry.cooldownID or entry.key
end

-- Returns info, the spell to read a cooldown from, and the base spell. Item
-- entries have no spellID; the category's return is secret and only passed on.
local function ResolveEntry(cooldownID)
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    if not ok or not info then return nil, nil, nil end

    local base = info.spellID
    local live = info.overrideTooltipSpellID or info.overrideSpellID or base
    -- A bag item has no spellID; the category reports whichever item last
    -- started a cooldown there. That id is secret in any combat. It still drives
    -- a sweep, but can never key a table or be compared.
    if not live and info.spellCategoryID and C_Spell.GetLastCategoryCooldownSource then
        local sOk, sID = pcall(C_Spell.GetLastCategoryCooldownSource, info.spellCategoryID)
        if sOk and sID ~= nil then live = sID end
    end
    if live ~= nil and issecretvalue(live) then return info, nil, base, live end
    return info, live, base, live
end

-- Presence is a nil check on auraInstanceID, never a comparison. Keyed on the
-- BASE spell: the live one can be secret and a secret table key throws.
-- Prefers a mapped buff that can be timed; a frame with no .Bar carries no duration.
local function ActiveBuffFrame(cooldownID, baseSpellID)
    if not ns.GetPersistentBuffFrame then return nil end
    local maps = CONFIG.buffMappings
        and (CONFIG.buffMappings[cooldownID]
             or (baseSpellID and CONFIG.buffMappings[baseSpellID]))
    if not maps then return nil end

    local fallback, fallbackID
    for _, mapData in ipairs(maps) do
        for _, bcd in ipairs(mapData.buffCooldownIDs or {}) do
            local f = ns.GetPersistentBuffFrame(bcd)
            if f then
                local ok, aid = pcall(function() return f.auraInstanceID end)
                if ok and aid ~= nil then
                    if f.Bar then return f, bcd end
                    if not fallback then fallback, fallbackID = f, bcd end
                end
            end
        end
    end
    return fallback, fallbackID
end

-- Frames

local containerFrames = {}   -- [key] = frame
local iconPool = {}          -- [key] = { icon frames }
local lastSignature = {}     -- [key] = string, so geometry only runs on a change
local eventFrame
local deferFrame              -- one shot, armed by Show, disarms itself on run
local deferRelayout = false
local deferRefeed = false

-- Only these can change a cooldown's DURATION, so only these justify re-feeding
-- the Cooldown frame. Every other registered event still repaints, because state
-- can change, but a re-feed on them restarts the swipe for nothing.
--
-- A cooldown STARTING is not missed by this: the feed also runs whenever the frame
-- is not already showing, which is exactly the start case.
local REFEED_EVENTS = {
    SPELL_UPDATE_COOLDOWN = true,
    SPELL_UPDATE_CHARGES = true,
    COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED = true,
    COOLDOWN_VIEWER_DATA_LOADED = true,
    TRAIT_CONFIG_UPDATED = true,
    PLAYER_ENTERING_WORLD = true,
}
local refreshRetryQueued = false
local animating = false

-- UIParent, never EH_Parent: that clips children. Every satellite does this.
function ICON.GetContainerFrame(key)
    return containerFrames[key]
end

local function GetContainer(key)
    local f = containerFrames[key]
    if f then return f end
    if InCombatLockdown() then return nil end

    f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("MEDIUM")
    containerFrames[key] = f
    iconPool[key] = iconPool[key] or {}
    return f
end

local function GetIcon(key, index)
    local pool = iconPool[key]
    if not pool then return nil end
    if pool[index] then return pool[index] end
    if InCombatLockdown() then return nil end

    local parent = containerFrames[key]
    if not parent then return nil end

    local ic = CreateFrame("Frame", nil, parent)
    ic.tex = ic:CreateTexture(nil, "ARTWORK")
    ic.tex:SetAllPoints()

    -- The engine draws the countdown, so the time never passes through Lua.
    ic.cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
    ic.cd:SetAllPoints()
    ic.cd:SetDrawEdge(false)
    ic.cd:SetDrawBling(false)
    -- Blizzard suppresses the number on short cooldowns, which is most of what a
    -- rotational strip shows.
    if ic.cd.SetMinimumCountdownDuration then
        ic.cd:SetMinimumCountdownDuration(0)
    end

    -- Radial StatusBar fed the CDM bar's values straight through. Marks the
    -- REMAINING arc: inverting it would mean subtracting from a secret.
    ic.radial = CreateFrame("StatusBar", nil, ic)
    ic.radial:SetFrameLevel(ic.cd:GetFrameLevel() + 1)
    ic.radial:SetAllPoints()
    local rt = ic.radial:CreateTexture(nil, "ARTWORK")
    rt:SetAllPoints()
    rt:SetColorTexture(unpack(WEDGE_COLOR_DEFAULT))
    ic.radial:SetStatusBarTexture(rt)
    ic.radialTex = rt
    if ic.radial.SetRenderMode and Enum.StatusBarRenderMode then
        pcall(ic.radial.SetRenderMode, ic.radial, Enum.StatusBarRenderMode.Radial)
        -- Top, clockwise, so it reads like a cooldown swipe.
        pcall(rt.SetRadialProgressBarStartOffset, rt, 0.5)
        pcall(rt.SetRadialProgressBarReverse, rt, true)
    end
    ic.radial:Hide()

    -- Buff remaining, copied from Blizzard's own string, never read. Above the
    -- wedge, which would otherwise draw over the number it is timing.
    ic.textLayer = CreateFrame("Frame", nil, ic)
    ic.textLayer:SetAllPoints()
    ic.textLayer:SetFrameLevel(ic.radial:GetFrameLevel() + 1)

    ic.durText = ic.textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlightOutline")
    ic.durText:Hide()

    -- Charges or aura stacks, drawn in a corner rather than over the countdown.
    ic.countText = ic.textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    ic.countText:Hide()

    pool[index] = ic
    return ic
end

-- Proc glow: Blizzard's own alert art. Overflows the icon by 40 percent, which
-- the strip can afford because its containers parent to UIParent and never clip.

local function GlowManager()
    local m = ActionButtonSpellAlertManager
    if m and m.ShowAlert and m.HideAlert then return m end
    return nil
end

-- The alert reads the frame size once, at creation, so a resized icon keeps the
-- old glow until this runs again.
local function SizeGlow(ic)
    local alert = ic.SpellActivationAlert
    if not alert then return end
    local w, h = ic:GetSize()
    alert:SetSize(w * 1.4, h * 1.4)
    alert:ClearAllPoints()
    alert:SetPoint("CENTER", ic, "CENTER", 0, 0)
end

local function SetGlow(ic, on)
    local m = GlowManager()
    if not m then return end
    if on then
        if not ic.glowOn then
            pcall(m.ShowAlert, m, ic)
            ic.glowOn = true
            SizeGlow(ic)
        end
    elseif ic.glowOn then
        pcall(m.HideAlert, m, ic)
        ic.glowOn = false
    end
end

-- Always through here, never a bare Hide: the glow is registered against the
-- frame in Blizzard's alert table and survives hiding.
local function HideIcon(ic)
    SetGlow(ic, false)
    ic:Hide()
end

-- Same for a whole container: its icons keep their registrations.
local function HideContainer(key)
    local f = containerFrames[key]
    if f then f:Hide() end
    for _, ic in ipairs(iconPool[key] or {}) do
        SetGlow(ic, false)
    end
end

local function CountValue(spellID, buffFrame)
    if spellID then
        local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
        if ok and info and info.maxCharges ~= nil
            and not issecretvalue(info.maxCharges) and info.maxCharges > 1 then
            return info.currentCharges
        end
    end
    -- A non-stacking aura reports 0 and would print a 0 on every icon. Under
    -- restriction the count is secret; charges still work, maxCharges is NeverSecret.
    local AC = ns.AuraCompat
    if buffFrame and AC and AC.ReadApplications then
        local n = AC.ReadApplications(buffFrame)
        if n ~= nil and not issecretvalue(n) and n > 1 then return n end
    end
    return nil
end

local function IsGlowing(spellID)
    if not spellID then return false end
    local api = C_SpellActivationOverlay
    if not api or not api.IsSpellOverlayed then return false end
    local ok, overlayed = pcall(api.IsSpellOverlayed, spellID)
    return (ok and overlayed and not issecretvalue(overlayed)) and true or false
end

-- Paint

-- INSTRUMENTATION, remove before release. A flash is a one frame swap between a
-- state that draws greyed and one that does not. Both directions are recorded,
-- because which way it goes is part of what this is meant to establish.
--
-- `fed` is the discriminator: "cd-err" or "cd-nil" means a failed read cleared a
-- running cooldown, "cd" with shown=false means clearIfZero fired on a zero span,
-- and buffed=true means a pooled buff frame reported an aura.
local DESATURATED = { cooldown = true, unusable = true }
-- Rolling, not first-N. A capped log that keeps the EARLIEST rows fills with the
-- first minute and then silently drops the event actually worth seeing. Rows carry
-- `t` and `serial`, so wrap order costs nothing: sort them on the way out.
local flashLogCap = 300
local flashLogNext = 0
local sampleCap = 60
local sampleNext = 0

-- Every row carries the paint pass it happened in. Rows sharing a serial flipped
-- in the SAME frame, which separates a global cause, an event pass or a layout
-- rebuild hitting every icon at once, from a defect specific to one spell.
local paintSerial = 0
local flashThisPass = 0
local lastBurstAt = 0
local logsCleared = false

-- Which events drove this pass. The deferral means the paint happens a frame
-- after the event, so the names are carried rather than read at paint time.
local pendingEvents = {}
local passEvents = "?"

-- A re-feed on a cooldown that was ALREADY running restarts the swipe without any
-- state change, which is the only per-pass write not derived from `state`. Counted
-- per driving event, because the fix is to stop re-feeding for events that cannot
-- have changed a cooldown.
-- Counters live in plain locals: incrementing a saved table once per icon per
-- paint is 20Hz times the strip size for no benefit. Flushed once per pass by
-- FlushCounters below. Run two produced no flashLog2 at all, which proved a
-- condition never held but not which one, hence counting all four separately.
local cPaints, cRefed, cShown, cUnchanged, cHits = 0, 0, 0, 0, 0
local hitsThisPass = 0
local pendingSample

local function NotePaint(entry, wasShown, unchanged, refed)
    cPaints = cPaints + 1
    if refed then cRefed = cRefed + 1 end
    if wasShown then cShown = cShown + 1 end
    if unchanged then cUnchanged = cUnchanged + 1 end
    if not (wasShown and unchanged and refed) then return end
    cHits = cHits + 1
    hitsThisPass = hitsThisPass + 1
    if not pendingSample then pendingSample = entry.cooldownID or true end
end

local function FlushCounters()
    if cPaints == 0 then return end
    local db = InfallDB.flashLog2
    if not db then
        db = { events = {}, samples = {}, counts = {} }
        InfallDB.flashLog2 = db
    end
    local c = db.counts
    c.paints, c.refed, c.wasShown, c.unchanged, c.hits =
        cPaints, cRefed, cShown, cUnchanged, cHits
    if pendingSample then
        db.events[passEvents] = (db.events[passEvents] or 0) + 1
        sampleNext = sampleNext + 1
        if sampleNext > sampleCap then sampleNext = 1 end
        do
            db.samples[sampleNext] = { t = GetTime(), serial = paintSerial,
                cooldownID = pendingSample ~= true and pendingSample or nil,
                events = passEvents,
                combat = InCombatLockdown() and true or false }
        end
        pendingSample = nil
    end
end

local function RecordFlash(ic, entry, state, fed, unusable, hasCharges, buffed, glowing)
    local prev = ic._ehPrevState
    ic._ehPrevState = state
    if not prev or prev == state then return end
    if DESATURATED[prev] == DESATURATED[state] then return end

    flashThisPass = flashThisPass + 1
    InfallDB.flashLog = InfallDB.flashLog or {}
    local log = InfallDB.flashLog
    flashLogNext = flashLogNext + 1
    if flashLogNext > flashLogCap then flashLogNext = 1 end
    log[flashLogNext] = {
        t          = GetTime(),
        serial     = paintSerial,
        cooldownID = entry.cooldownID,
        from       = prev,
        to         = state,
        fed        = fed,
        shown      = ic.cd:IsShown() and true or false,
        spellCd    = spellOnCd and true or false,
        unusable   = unusable and true or false,
        hasCharges = hasCharges and true or false,
        buffed     = buffed and true or false,
        glowing    = glowing and true or false,
        combat     = InCombatLockdown() and true or false,
    }
end

-- True on an event-driven pass. Duration objects get a fresh pointer per call,
-- so feeding every frame would restart the swipe; event passes re-feed for CDR.
local refeedCooldowns = true

-- Longest a running cooldown can show a stale duration after cooldown reduction.
-- Cheap to lower if CDR ever looks laggy on the strip.
local REFEED_THROTTLE = 0.4

-- How long IsSpellUsable must keep saying "no" before the icon is dimmed. The
-- artefact it filters lasts 0.02 to 0.07s measured, so this has room either way.
local UNUSABLE_HOLD = 0.15

-- isOnGCD carries "do not trust this field unless responding to a
-- SPELL_UPDATE_COOLDOWN event", so it is sampled INSIDE that event and cached,
-- never read from the deferred paint. Reading it late produced a documented
-- isActive/isOnGCD race: 67 one frame flickers in 24 minutes, seven icons at a
-- time. Sampling at the event is also 3.6x CHEAPER, because a paint happens far
-- more often than a cooldown event.
--
-- Expiry does NOT need an event. The cached flag answers "is this a real cooldown
-- rather than the GCD"; ic.cd:IsShown() answers "is it still running", live and
-- free. Neither question is asked of the wrong source.
local trackedSpells = {}   -- [spellID] = true, every spell the strip is drawing
local cdState = {}         -- [spellID] = true when a real, non-GCD cooldown runs
local chargeState = {}     -- [spellID] = isActive, or nil when not a charge spell

local function SampleSpell(sid)
    local ok, cd = pcall(C_Spell.GetSpellCooldown, sid)
    cdState[sid] = (ok and cd and cd.isActive and not cd.isOnGCD) and true or nil

    chargeState[sid] = nil
    if C_Spell.GetSpellCharges then
        local okC, ci = pcall(C_Spell.GetSpellCharges, sid)
        if okC and ci and ci.maxCharges ~= nil
            and not issecretvalue(ci.maxCharges) and ci.maxCharges > 1 then
            chargeState[sid] = ci.isActive and true or false
        end
    end
end

-- Called from the event handler, before the paint is deferred.
local function SampleTrackedSpells()
    for sid in pairs(trackedSpells) do SampleSpell(sid) end
end

-- Returns shown, live. `live` means something moves with no event behind it.
local function PaintIcon(ic, entry, cfg)
    -- spellID keys tables and drives comparisons, so it is nil for an item entry
    -- in combat. feedID is the same id without that guarantee: sweeps and usable
    -- reads take it, because those APIs accept secret arguments.
    local info, spellID, baseSpellID, feedID
    if entry.cooldownID then
        info, spellID, baseSpellID, feedID = ResolveEntry(entry.cooldownID)
    end

    -- One live read of the charge mechanic, shared by the feed below and the state
    -- chain. maxCharges is static and non-secret, so this is safe in an instance.
    -- Both used to answer this question from different sources, the feed live and
    -- the state from InfallDB.chargeSpells, and whenever the two disagreed the
    -- icon was fed a charge sweep while being painted as a plain cooldown.
    -- First sight of a spell samples it immediately, so an icon is never drawn from
    -- an empty cache; after that the event handler keeps it current.
    if spellID and not trackedSpells[spellID] then
        trackedSpells[spellID] = true
        SampleSpell(spellID)
    end

    -- chargeActive answers "is a recharge in flight", which is NOT the same question
    -- as the spell's own cooldown: at 1 of 2 a charge is recharging while the spell
    -- itself is castable and has no cooldown at all.
    local hasCharges = spellID ~= nil and chargeState[spellID] ~= nil
    local chargeActive = hasCharges and chargeState[spellID] == true

    -- Feed the cooldown first: the state test reads this frame's IsShown().
    -- `fed` is instrumentation: it separates "the API said no cooldown" from "the
    -- API did not answer", which this branch currently treats identically.
    local fed = "skip"
    -- INSTRUMENTATION: captured before the feed, because the feed is what changes it.
    local wasShown = ic.cd:IsShown()
    -- One reading for the whole paint: the throttle and both holds must agree on
    -- when "now" is, and three separate GetTime calls invite an off by a frame bug.
    local now = GetTime()

    -- A cooldown that is NOT running is always fed: that is how one starts, and it
    -- must never be delayed. A cooldown that IS running only gets re-fed on a
    -- throttle, because the sole reason to re-feed it is to pick up cooldown
    -- reduction, and SPELL_UPDATE_COOLDOWN fires on every GCD with no payload
    -- saying which spell moved. Re-feeding restarts the swipe, so the unthrottled
    -- version paid a restart per icon per event to catch a rare CDR proc.
    local refeedNow = refeedCooldowns
    if refeedNow and wasShown then
        if (ic._ehNextRefeed or 0) > now then
            refeedNow = false
        else
            ic._ehNextRefeed = now + REFEED_THROTTLE
        end
    end

    if feedID and (refeedNow or not wasShown) then
        -- ignoreGCD returns the real cooldown and a zero span during a pure GCD.
        -- Per entry, falling back to the general setting.
        local ignoreGCD = entry.ignoreGCD
        if ignoreGCD == nil then ignoreGCD = CONFIG.iconIgnoreGCD ~= false end

        -- A charge spell's own cooldown is zero while a charge is spare, so the charge
        -- duration is what the entry shows. Zero-span at full charges, which clearIfZero handles.
        local durObj
        if hasCharges and C_Spell.GetSpellChargeDuration then
            local okD, d = pcall(C_Spell.GetSpellChargeDuration, feedID)
            if okD then durObj = d end
        end
        if durObj then
            fed = "charge"
        else
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, feedID, ignoreGCD)
            if ok then durObj = d end
            fed = ok and (d and "cd" or "cd-nil") or "cd-err"
        end

        if durObj then
            pcall(ic.cd.SetCooldownFromDurationObject, ic.cd, durObj, true)
        else
            ic.cd:SetCooldown(0, 0)
        end
    elseif not feedID then
        fed = "nospell"
        ic.cd:SetCooldown(0, 0)
    end

    -- No info means the entry left the Cooldown Manager, usually talented away.
    -- Without this the slot keeps drawing the fallback question mark until a reload.
    if entry.cooldownID and not info
        and not (CONFIG.customIcons and CONFIG.customIcons[entry.cooldownID]) then
        SetGlow(ic, false)
        ic:Hide()
        return false, false
    end

    local buffFrame, buffCdID = ActiveBuffFrame(ICON.EntryID(entry), baseSpellID)
    local glowing = IsGlowing(spellID)
    -- Matched on the entry, never its cooldownID: the same ability can sit on
    -- several strips as separate entries, and previewing one must not force the others.
    local pv = ICON.preview
    local forced = pv and pv.entry == entry and pv.state or nil
    -- Resolved before the chain: a running sweep means two different things.
    -- Whole test inside the pcall, the comparison throws and not the call.
    -- Never a charge count test; currentCharges is secret.
    local unusable = false
    pcall(function()
        local u = C_Spell.IsSpellUsable(feedID)
        if u ~= nil and not issecretvalue(u) and u == false then unusable = true end
    end)

    -- MEASURED 2026-08-23 over 23 minutes of dungeon: IsSpellUsable reports every
    -- utility spell unusable simultaneously for two frames at a time, then takes it
    -- back. Thirteen icons at once, 0.02 to 0.07s apart, about nine times. Painting
    -- that verbatim is the flicker, because `unusable` is the only state that drops
    -- opacity, so the whole strip dims and returns.
    --
    -- So a spell must STAY unusable before it is drawn that way. A real one holds
    -- for as long as the reason holds; the artefact never survives the window.
    -- Returning live keeps the tick alive so the pending decision resolves even if
    -- no further event arrives.
    local unusablePending = false
    if unusable then
        ic._unusableSince = ic._unusableSince or now
        if now - ic._unusableSince < UNUSABLE_HOLD then
            unusable = false
            unusablePending = true
        end
    else
        ic._unusableSince = nil
    end

    -- Exclude the global cooldown EXPLICITLY, never by asking the API to do it.
    -- GetSpellCooldownDuration's ignoreGCD returned GCD length sweeps anyway:
    -- measured over a raid, six utility icons went ready -> cooldown -> ready
    -- together 27 times, 0.02 to 0.83s, while the shortest real cooldown in the
    -- same log was 8.6s. A time based filter cannot separate those without
    -- delaying every real cooldown by a second, which is worse than the flash.
    --
    -- isActive and isOnGCD both carry NeverSecret in Blizzard's own annotations,
    -- so this is safe bare under restriction. Only startTime, duration and modRate
    -- on that structure are secret; do not touch them here.
    --
    -- spellID, not baseSpellID: ResolveEntry already resolved the override, and a
    -- transform's real cooldown ticks on the override id while the base id reports
    -- isOnGCD for that whole duration and would suppress the sweep throughout.
    -- Cached flag says it is a real cooldown and not the GCD; IsShown says it is
    -- still running. Both are needed: the flag alone goes stale when a cooldown
    -- expires with no event, and IsShown alone cannot tell a GCD from a cooldown.
    -- An item entry has no cdState sample, because sampling keys a table and its
    -- id is secret. Its sweep is fed with ignoreGCD, so IsShown is already free
    -- of the GCD and answers the question on its own.
    local cdKnown = (spellID ~= nil and cdState[spellID] == true)
        or (spellID == nil and feedID ~= nil)
    local spellOnCd = cdKnown and ic.cd:IsShown()

    -- Two different questions, and conflating them is what put charge spells in the
    -- wrong state twice already. A charge spell shows a sweep whenever a recharge is
    -- in flight, INCLUDING at 1 of 2 where the spell itself has no cooldown. Its own
    -- cooldown running means every charge is spent, which is the greyed case.
    local onCooldown = hasCharges and chargeActive or spellOnCd
    local spent = hasCharges and spellOnCd


    local state
    if buffFrame then
        state = "buff"
    elseif onCooldown then
        -- The sweep is running. Recharging is the CHARGE case only: a spell with a
        -- spare charge, which the game itself does not grey out.
        --
        -- The charge test is not optional. Without it a single charge spell flips
        -- to recharging for one frame every time IsSpellUsable turns true, and
        -- since recharging is the one state that is NOT desaturated, that reads as
        -- a full saturation flash on an icon that should have stayed greyed.
        -- SPELL_UPDATE_USABLE repaints immediately, so target dependent utilities
        -- did it constantly. hasCharges is the live read taken above, never a
        -- cached table: the cache only ever held Essential entries, so every
        -- charge spell outside that category painted as a plain cooldown.
        --
        -- `spent` means the spell's own cooldown is running, so every charge is
        -- gone. 0 of 2 is not castable and greys like any other cooldown; only
        -- 1 of 2, a recharge with one still in hand, stays bright.
        state = (unusable or not hasCharges or spent) and "cooldown" or "recharging"
    elseif glowing then
        state = "proc"
    else
        state = unusable and "unusable" or "ready"
    end

    if forced then
        state = forced
        -- Tuning the proc state with nothing procced would show no art at all.
        if forced == "proc" then glowing = true end
    else
        -- INSTRUMENTATION, remove before release. Never on a preview pass: a
        -- forced state is the settings panel talking, not the game.
        local prevState = ic._ehPrevState
        RecordFlash(ic, entry, state, fed, unusable, hasCharges,
            buffFrame ~= nil, glowing)
        -- refeedNow, not refeedCooldowns: the throttle is part of the decision, and
        -- reporting the pre-throttle value would credit re-feeds that never ran.
        NotePaint(entry, wasShown, prevState == state, refeedNow)
    end

    local rules = RulesFor(entry, state)
    if forced then
        -- A previewed icon always draws, or tuning a hidden state shows nothing.
        ic:Show()
    elseif not rules.show then
        SetGlow(ic, false)
        ic:Hide()
        return false, false
    end

    local wantGlow = entry.glow
    if wantGlow == nil then wantGlow = CONFIG.iconGlow ~= false end
    SetGlow(ic, glowing and wantGlow and true or false)

    -- Config data, never a secret.
    local _, tex
    if state == "buff" and rules.buffIcon and buffCdID then
        _, tex = ns.ResolveCooldownDisplay(buffCdID, nil)
    elseif entry.cooldownID then
        _, tex = ns.ResolveCooldownDisplay(entry.cooldownID, info)
    else
        -- Custom icon: its art is whatever was picked for it.
        tex = entry.iconTexture
            or (entry.iconSpellID and C_Spell.GetSpellTexture(entry.iconSpellID))
    end
    local customID = entry.cooldownID and CONFIG.customIcons
        and CONFIG.customIcons[entry.cooldownID]
    ic.tex:SetTexture((customID and C_Spell.GetSpellTexture(customID)) or tex or 134400)
    ic.tex:SetTexCoord(IconTexCoord(cfg.width, cfg.height, cfg.zoom))
    ic.tex:SetDesaturated(rules.desaturate and true or false)
    ic:SetAlpha(rules.opacity or 1)

    -- Cooldown numbers come from the engine, buff numbers from the mirror.
    local buffSweep = rules.sweep == "buff"
    local tcfg = TextCfg(rules)
    -- Before StyleCountdown: the countdown FontString does not exist while the
    -- numbers are hidden, so styling first has nothing to take.
    ic.cd:SetHideCountdownNumbers(buffSweep or not rules.timer)
    StyleCountdown(ic, tcfg, cfg)
    ic.cd:SetDrawSwipe(rules.sweep == "cd")
    pcall(ic.cd.SetSwipeColor, ic.cd, unpack(ColorOf(rules, "sweepColor", SWEEP_COLOR_DEFAULT)))
    ic.radialTex:SetColorTexture(unpack(ColorOf(rules, "wedgeColor", WEDGE_COLOR_DEFAULT)))

    -- Font settings follow the addon's own picker, falling back to the frame
    -- font so an unset profile still draws.
    ApplyTextStyle(ic.durText, tcfg, ic)

    -- A held unusable counts as live: without it the strip could sit on the
    -- suppressed value until some unrelated event happened to repaint.
    local live = unusablePending
    local bar = buffSweep and buffFrame and buffFrame.Bar or nil

    if forced and buffSweep and not bar then
        pcall(ic.radial.SetMinMaxValues, ic.radial, 0, 1)
        pcall(ic.radial.SetValue, ic.radial, 0.62)
        ic.radial:Show()
    elseif bar then
        local okMM, mn, mx = pcall(bar.GetMinMaxValues, bar)
        local okV, val = pcall(bar.GetValue, bar)
        if okMM and okV then
            pcall(ic.radial.SetMinMaxValues, ic.radial, mn, mx)
            pcall(ic.radial.SetValue, ic.radial, val)
            ic.radial:Show()
            live = true
        else
            ic.radial:Hide()
        end
    else
        ic.radial:Hide()
    end

    -- Blizzard only writes that string while its own timer display is on.
    local src = bar and bar.Duration
    if forced and rules.timer then
        ic.durText:SetText("12")
        ic.durText:Show()
    elseif rules.timer and buffSweep and src then
        local okShown, shown = pcall(src.IsShown, src)
        if okShown and shown then
            local okText, text = pcall(src.GetText, src)
            if okText then
                pcall(ic.durText.SetText, ic.durText, text)
                ic.durText:Show()
            else
                ic.durText:Hide()
            end
        else
            ic.durText:Hide()
        end
    else
        ic.durText:Hide()
    end

    -- Last: RulesFor returns a shared scratch table, so asking it for another
    -- key here would overwrite the state rules used above.
    local countRules = RulesFor(entry, "count")
    if countRules.show then
        local n = CountValue(spellID, buffFrame)
        if n ~= nil then
            ApplyTextStyle(ic.countText, TextCfg(countRules), ic)
            pcall(ic.countText.SetText, ic.countText, n)
            ic.countText:Show()
        else
            ic.countText:Hide()
        end
    else
        ic.countText:Hide()
    end

    ic:Show()
    return true, live
end

-- Layout. Compaction is one filtered list. Growth is which edge stays pinned.

local HORIZONTAL = { TOP = true, BOTTOM = true }

-- Pips and the resource bar share one container per side. Outside anchors beyond
-- it, inside anchors to the frame, so only one of the two ever offsets.
local function EdgeAnchor(cfg, parent)
    if not HORIZONTAL[cfg.anchor] or not ns.GetStackEdgeFrame then return parent end
    if cfg.edgeOrder == "inside" then return parent end
    return ns.GetStackEdgeFrame(cfg.anchor) or parent
end

local function AnchorContainer(f, cfg, parent, gapPx)
    f:ClearAllPoints()
    local grow = cfg.grow
    -- Spans the frame's full width, so every growth mode below is unchanged.
    parent = EdgeAnchor(cfg, parent)
    if cfg.anchor == "TOP" then
        if grow == "LEFT" then f:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", 0, gapPx)
        elseif grow == "CENTRE" then f:SetPoint("BOTTOM", parent, "TOP", 0, gapPx)
        else f:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 0, gapPx) end
    elseif cfg.anchor == "BOTTOM" then
        if grow == "LEFT" then f:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", 0, -gapPx)
        elseif grow == "CENTRE" then f:SetPoint("TOP", parent, "BOTTOM", 0, -gapPx)
        else f:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 0, -gapPx) end
    elseif cfg.anchor == "LEFT" then
        if grow == "UP" then f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", -gapPx, 0)
        elseif grow == "CENTRE" then f:SetPoint("RIGHT", parent, "LEFT", -gapPx, 0)
        else f:SetPoint("TOPRIGHT", parent, "TOPLEFT", -gapPx, 0) end
    else
        if grow == "UP" then f:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", gapPx, 0)
        elseif grow == "CENTRE" then f:SetPoint("LEFT", parent, "RIGHT", gapPx, 0)
        else f:SetPoint("TOPLEFT", parent, "TOPRIGHT", gapPx, 0) end
    end
end

local function PlaceSlots(f, cfg, slots, parent)
    local onePx   = OnePx(f)
    local wPx     = SnapPx(cfg.width, onePx)
    local hPx     = SnapPx(cfg.height, onePx)
    local spacePx = SnapPx(cfg.spacing, onePx)
    local horiz   = HORIZONTAL[cfg.anchor]
    local perLine = math.max(1, math.floor(cfg.perLine))
    local n       = #slots

    -- Main is the axis icons run along; which of w/h that is flips with the edge.
    local mainSize  = horiz and wPx or hPx
    local crossSize = horiz and hPx or wPx

    local rows     = math.ceil(n / perLine)
    local perRow   = math.min(n, perLine)
    local mainLen  = perRow * mainSize + math.max(0, perRow - 1) * spacePx
    local crossLen = rows * crossSize + math.max(0, rows - 1) * spacePx

    f:SetSize(horiz and mainLen or crossLen, horiz and crossLen or mainLen)
    AnchorContainer(f, cfg, parent, SnapPx(cfg.gap, onePx))

    for i, ic in ipairs(slots) do
        local rowIdx    = math.floor((i - 1) / perLine)
        local idxInRow  = (i - 1) % perLine
        local inThisRow = math.min(perLine, n - rowIdx * perLine)
        local rowLen    = inThisRow * mainSize + math.max(0, inThisRow - 1) * spacePx
        -- A short last row stays centred, not hugging the growth edge.
        local mainPos   = SnapPx((mainLen - rowLen) / 2, onePx) + idxInRow * (mainSize + spacePx)
        local crossPos  = rowIdx * (crossSize + spacePx)

        ic:SetSize(wPx, hPx)
        SizeGlow(ic)
        ic:ClearAllPoints()
        if horiz then
            ic:SetPoint("TOPLEFT", f, "TOPLEFT", mainPos, -crossPos)
        else
            ic:SetPoint("TOPLEFT", f, "TOPLEFT", crossPos, -mainPos)
        end
    end
end

local function UpdateContainer(cfg, parent)
    local f = GetContainer(cfg.key)
    if not f then return false end

    local slots, sig, used = {}, {}, 0
    local live = false

    for _, entry in ipairs(CONFIG.iconList or {}) do
        if entry.enabled ~= false and ICON.EntryID(entry)
            and (entry.container or "TOP") == cfg.key then
            used = used + 1
            local ic = GetIcon(cfg.key, used)
            if not ic then break end
            local shown, isLive = PaintIcon(ic, entry, cfg)
            live = live or isLive
            if shown or cfg.mode == "fixed" then
                slots[#slots + 1] = ic
                sig[#sig + 1] = used
            else
                HideIcon(ic)
            end
        end
    end

    local pool = iconPool[cfg.key]
    for i = used + 1, #pool do
        HideIcon(pool[i])
    end

    if #slots == 0 then
        f:Hide()
        lastSignature[cfg.key] = nil
        return live
    end

    -- Geometry only changes with the visible set or a size setting. Occupancy belongs
    -- in the signature; height does not, the strip anchors to the frame and tracks it.
    local edged = (HORIZONTAL[cfg.anchor] and ns.GetStackEdgeFrame
        and ns.GetStackEdgeFrame(cfg.anchor)) and "s" or "-"

    local key = table.concat(sig, ",") .. "|" .. cfg.anchor .. cfg.grow .. cfg.mode
        .. cfg.width .. "x" .. cfg.height .. "," .. cfg.spacing .. ","
        .. cfg.perLine .. "," .. cfg.gap .. edged
    if lastSignature[cfg.key] ~= key then
        lastSignature[cfg.key] = key
        PlaceSlots(f, cfg, slots, parent)
    end

    -- Frame alpha multiplies with each icon's, so the two compose.
    f:SetAlpha(ContextAlpha(cfg))
    f:Show()
    return live
end

function ICON.Layout()
    -- Layout has its own callers, which would otherwise render a disabled strip.
    if not CONFIG.iconsEnabled then return end

    local parent = ns.EH_Parent
    if not parent then return end

    -- INSTRUMENTATION, remove before release. Cleared once per session, so each
    -- run is one dungeon rather than the previous run's rows filling the cap. The
    -- disk copy written at reload is untouched by this; only the fresh session is.
    if not logsCleared then
        logsCleared = true
        InfallDB.flashLog = nil
        InfallDB.flashLog2 = nil
    end
    paintSerial = paintSerial + 1
    flashThisPass = 0

    -- Visibility comes from the context alphas, not the frame's shown state.
    -- Zero hides outright, so an invisible strip costs no paint pass.
    MigrateContainers()

    local seen = {}
    animating = false
    for _, cfg in ipairs(CONFIG.iconContainers or {}) do
        if cfg.key then
            MigrateContainer(cfg)
            Merged(cfg, CONTAINER_DEFAULTS)
            seen[cfg.key] = true
            if ContextAlpha(cfg) <= 0 then
                HideContainer(cfg.key)
                lastSignature[cfg.key] = nil
            elseif UpdateContainer(cfg, parent) then
                animating = true
            end
        end
    end

    -- A removed container leaves its frames behind.
    for key, f in pairs(containerFrames) do
        if not seen[key] then
            f:Hide()
            lastSignature[key] = nil
        end
    end

    -- INSTRUMENTATION, remove before release. Three or more icons swapping
    -- saturation in one pass is the shape worth seeing live, and the throttle
    -- keeps a repeating cause from filling chat during a pull.
    FlushCounters()   -- INSTRUMENTATION, once per pass rather than per icon
    -- Reports the DEFECT, not state changes. A pull ending flips a dozen icons to
    -- ready at once and that is legitimate, so counting those told you nothing.
    -- This counts pointless re-feeds, which the event gate should have stopped.
    if hitsThisPass >= 3 and GetTime() - lastBurstAt > 10 then
        lastBurstAt = GetTime()
        print(string.format("|cff00ff00[Infall]|r wasted re-feed: %d icons, pass %d, from %s",
            hitsThisPass, paintSerial, passEvents))
    end
    hitsThisPass = 0

    refeedCooldowns = false
end

-- Force geometry on the next pass. Sliders call this directly, not debounced.
function ICON.Relayout()
    -- The drawn set can change here, so stale ids stop being sampled every event.
    -- Each surviving icon re-registers on its next paint.
    wipe(trackedSpells)
    wipe(lastSignature)
    refeedCooldowns = true
    ICON.Layout()
end

-- Enable / disable. Disabled costs nothing per frame: no events, no OnUpdate, no frames.

local function OnTick(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.05 then return end
    self.acc = 0
    ICON.Layout()
    -- Only a mirrored wedge moves without an event; otherwise go event driven.
    if not animating then self:SetScript("OnUpdate", nil) end
end

local function StartTickIfNeeded()
    if not eventFrame then return end
    if animating and not eventFrame:GetScript("OnUpdate") then
        eventFrame.acc = 0
        eventFrame:SetScript("OnUpdate", OnTick)
    end
end

-- Cooldown, charge and aura events fire while the engine is still reconciling, so
-- a value read inside the handler can disagree with what the game settles on one
-- frame later. Painting straight from the event renders that disagreement for a
-- frame. Reading on the next frame instead gets the settled answer, and several
-- events arriving together collapse into a single pass.
--
-- Only the event path is deferred. Sliders and ICON.Refresh call Layout/Relayout
-- directly and stay synchronous, so nothing in the settings panel gains lag.
local function RunDeferredPaint(self)
    self:Hide()
    -- INSTRUMENTATION: name the events that drove this pass, sorted so the same
    -- combination always produces the same key.
    local seen = {}
    for k in pairs(pendingEvents) do seen[#seen + 1] = k end
    table.sort(seen)
    passEvents = #seen > 0 and table.concat(seen, "+") or "?"
    wipe(pendingEvents)
    if deferRelayout then
        deferRelayout = false
        deferRefeed = false
        ICON.Relayout()
    else
        refeedCooldowns = deferRefeed
        deferRefeed = false
        ICON.Layout()
    end
    StartTickIfNeeded()
end

-- Showing an already shown frame is a no-op, which is what coalesces the pass.
local function QueuePaint(relayout)
    if relayout then deferRelayout = true end
    if deferFrame then deferFrame:Show() end
end

function ICON.Refresh()
    local on = CONFIG.iconsEnabled and CONFIG.iconContainers and #CONFIG.iconContainers > 0
    if not on then
        for key in pairs(containerFrames) do HideContainer(key) end
        wipe(lastSignature)
        if eventFrame then
            eventFrame:UnregisterAllEvents()
            eventFrame:SetScript("OnUpdate", nil)
        end
        -- A queued pass would otherwise paint the strip back after it was disabled.
        if deferFrame then
            deferFrame:Hide()
            deferRelayout = false
        end
        return
    end

    if not eventFrame then
        -- PLAYER_REGEN_ENABLED lives on the event frame, so bailing here would leave a
        -- strip enabled mid fight with nothing to wake it. Retry until combat drops.
        if InCombatLockdown() then
            if not refreshRetryQueued then
                refreshRetryQueued = true
                C_Timer.After(1, function()
                    refreshRetryQueued = false
                    ICON.Refresh()
                end)
            end
            return
        end
        eventFrame = CreateFrame("Frame")
        -- Created here, beside the event frame, so neither is ever built in combat.
        deferFrame = CreateFrame("Frame")
        deferFrame:Hide()
        deferFrame:SetScript("OnUpdate", RunDeferredPaint)
        eventFrame:SetScript("OnEvent", function(_, event)
            pendingEvents[event] = true   -- INSTRUMENTATION
            if REFEED_EVENTS[event] then
                deferRefeed = true
                -- Sampled HERE, synchronously inside the event, because isOnGCD is
                -- only trustworthy while responding to it. The paint is a frame
                -- later and must never read it itself.
                SampleTrackedSpells()
            end
            -- Sizes are multiples of a physical pixel, so a resolution or scale
            -- change invalidates geometry that no other event would touch.
            QueuePaint(event == "UI_SCALE_CHANGED"
                or event == "DISPLAY_SIZE_CHANGED"
                or event == "PLAYER_REGEN_ENABLED")
        end)
    end

    -- NOT behind the combat guard; only CreateFrame is. Gating it costs a
    -- /reload in combat every cooldown event for the rest of the session.
    eventFrame:UnregisterAllEvents()
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
    eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
    -- Filtered to the player: unfiltered, this fires for every unit in a raid.
    eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
    eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    -- A talent swap adds and removes Cooldown Manager entries, so the strip has
    -- to re-resolve. Bars get this through the same two events.
    eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
    eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
    eventFrame:RegisterEvent("UI_SCALE_CHANGED")
    eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- Combat and target transitions come from UpdateVisibility, not from
    -- registering the same events: two frames on one event have no order.

    ICON.Relayout()
    StartTickIfNeeded()
end

ns.RefreshIcons = ICON.Refresh
