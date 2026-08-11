-- EventHorizon Infall: icon strip.
-- Containers on an edge of the EH frame, holding icons for Cooldown Manager
-- entries. Membership is a toggle on the same entries the timeline uses.

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
-- `show` decides whether the icon takes a slot, `opacity` how strongly it draws.
-- Glow is not a state field: a proc can run under a buff and still needs to draw.
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

-- Editing a buff's look with no buff up is editing blind, so a modal can force
-- one icon to render a state. Values are stand-ins; everything else is the real
-- paint path, so what is on screen is what will happen.
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

local function RulesFor(entry, state)
    local def = STATE_DEFAULTS[state]
    local global = CONFIG.iconStates and CONFIG.iconStates[state]
    local per = entry.states and entry.states[state]
    if not global and not per then return def end

    for k, v in pairs(def) do ruleScratch[k] = v end
    if global then for k, v in pairs(global) do ruleScratch[k] = v end end
    if per then for k, v in pairs(per) do ruleScratch[k] = v end end

    -- text is a table, so a plain overwrite would drop every field the per icon
    -- copy does not set and silently lose the general font behind one colour.
    if global and global.text or per and per.text then
        wipe(textScratch)
        if global and global.text then
            for k, v in pairs(global.text) do textScratch[k] = v end
        end
        if per and per.text then
            for k, v in pairs(per.text) do textScratch[k] = v end
        end
        ruleScratch.text = textScratch
    end

    return ruleScratch
end

-- Pixel grid
--
-- Satellites are never scaled. Derive the pixel, size in multiples of it.

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
-- Exported: the tab reads containers on profiles Layout never touched.
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

-- A strip is keyed by the side it lives on, so there is nothing to name and an
-- entry's container reads as its position. The single "main" container from
-- before becomes whichever side it was already anchored to, and its icons go
-- with it.
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
    if not live and info.spellCategoryID and C_Spell.GetLastCategoryCooldownSource then
        local sOk, sID = pcall(C_Spell.GetLastCategoryCooldownSource, info.spellCategoryID)
        if sOk and sID then live = sID end
    end
    return info, live, base
end

-- Presence is a nil check on auraInstanceID, never a comparison. Keyed on the
-- BASE spell: the live one can be secret and a secret table key throws.
-- Prefers a mapped buff that can be timed. A present frame with no .Bar carries
-- no duration, and taking it strands the icon when a second buff takes over.
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
    ic.cd.wantsFont = true

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

    -- Buff remaining, copied from Blizzard's own string, never read.
    -- Above the wedge, which is a frame in its own right and would otherwise
    -- draw over the number it is timing.
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
    -- Only when we can PROVE it is worth showing. A non-stacking aura reports 0
    -- and would print a 0 on every icon. Under restriction the count is secret
    -- and cannot be compared, so no aura stacks there; charges still work,
    -- because maxCharges is NeverSecret.
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

-- True on an event-driven pass. Duration objects get a fresh pointer per call,
-- so feeding every frame would restart the swipe; event passes re-feed for CDR.
local refeedCooldowns = true

-- Returns shown, live. `live` means something moves with no event behind it.
local function PaintIcon(ic, entry, cfg)
    local info, spellID, baseSpellID
    if entry.cooldownID then
        info, spellID, baseSpellID = ResolveEntry(entry.cooldownID)
    end

    -- Feed the cooldown first: the state test reads this frame's IsShown().
    if spellID and (refeedCooldowns or not ic.cd:IsShown()) then
        -- ignoreGCD returns the real cooldown and a zero span during a pure GCD,
        -- so the strip does not flicker a sweep on every cast. Per entry, falling
        -- back to the general setting.
        local ignoreGCD = entry.ignoreGCD
        if ignoreGCD == nil then ignoreGCD = CONFIG.iconIgnoreGCD ~= false end

        -- A charge spell's own cooldown is zero while a charge is spare, so
        -- reading it leaves the icon blank while the Cooldown Manager is still
        -- counting the recharge down. The charge duration is what that entry
        -- shows, and it is zero-span at full charges, which clearIfZero handles.
        -- maxCharges is NeverSecret, so the test is safe.
        local durObj
        if C_Spell.GetSpellChargeDuration then
            local okC, info = pcall(C_Spell.GetSpellCharges, spellID)
            if okC and info and info.maxCharges ~= nil
                and not issecretvalue(info.maxCharges) and info.maxCharges > 1 then
                local okD, d = pcall(C_Spell.GetSpellChargeDuration, spellID)
                if okD then durObj = d end
            end
        end
        if durObj == nil then
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, spellID, ignoreGCD)
            if ok then durObj = d end
        end

        if durObj then
            pcall(ic.cd.SetCooldownFromDurationObject, ic.cd, durObj, true)
        else
            ic.cd:SetCooldown(0, 0)
        end
    elseif not spellID then
        ic.cd:SetCooldown(0, 0)
    end

    -- No info means the entry is not in the Cooldown Manager any more, usually
    -- because the ability was talented away. Custom icons carry their own art
    -- and are unaffected. Without this the slot keeps drawing the fallback
    -- question mark until a reload.
    if entry.cooldownID and not info
        and not (CONFIG.customIcons and CONFIG.customIcons[entry.cooldownID]) then
        SetGlow(ic, false)
        ic:Hide()
        return false, false
    end

    local buffFrame, buffCdID = ActiveBuffFrame(ICON.EntryID(entry), baseSpellID)
    local glowing = IsGlowing(spellID)
    -- Matched on the entry itself, never its cooldownID: the same ability can
    -- sit on several strips as separate entries, and previewing one must not
    -- force the others.
    local pv = ICON.preview
    local forced = pv and pv.entry == entry and pv.state or nil
    -- Resolved before the chain, because a running sweep means two different
    -- things depending on it. Whole test inside the pcall: the comparison throws,
    -- not the call. Never a charge count test; currentCharges is secret.
    local unusable = false
    pcall(function()
        local u = C_Spell.IsSpellUsable(spellID)
        if u ~= nil and not issecretvalue(u) and u == false then unusable = true end
    end)

    local state
    if buffFrame then
        state = "buff"
    elseif ic.cd:IsShown() then
        -- The sweep is running. If the spell is still castable it is a charge
        -- recharging with one to spare, which the game itself does not grey out.
        state = unusable and "cooldown" or "recharging"
    elseif glowing then
        state = "proc"
    else
        state = unusable and "unusable" or "ready"
    end

    if forced then
        state = forced
        -- Tuning the proc state with nothing procced would show no art at all.
        if forced == "proc" then glowing = true end
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
    if ic.cd.wantsFont and ic.cd.SetCountdownFont then
        pcall(ic.cd.SetCountdownFont, ic.cd, CountdownFont(cfg))
    end
    ic.cd:SetDrawSwipe(rules.sweep == "cd")
    pcall(ic.cd.SetSwipeColor, ic.cd, unpack(ColorOf(rules, "sweepColor", SWEEP_COLOR_DEFAULT)))
    ic.radialTex:SetColorTexture(unpack(ColorOf(rules, "wedgeColor", WEDGE_COLOR_DEFAULT)))

    -- Font settings follow the addon's own picker, falling back to the frame
    -- font so an unset profile still draws.
    ApplyTextStyle(ic.durText, TextCfg(rules), ic)
    ic.cd:SetHideCountdownNumbers(buffSweep or not rules.timer)

    local live = false
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

-- Layout
--
-- Compaction is one filtered list. Growth is which edge stays pinned.

local HORIZONTAL = { TOP = true, BOTTOM = true }

-- Pips and the resource bar share one container per side. Outside means anchor
-- beyond it; inside means anchor to the frame and let it move out of the way,
-- which is why only one of the two ever offsets for the other.
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

    -- Geometry only changes with the visible set or a size setting.
    -- Occupancy belongs in the signature or turning pips on re-anchors nothing.
    -- Height does not: the strip anchors to the frame and tracks it.
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

    refeedCooldowns = false
end

-- Force geometry on the next pass. Sliders call this directly, not debounced.
function ICON.Relayout()
    wipe(lastSignature)
    refeedCooldowns = true
    ICON.Layout()
end

-- Enable / disable
--
-- Disabled costs nothing per frame: no events, no OnUpdate, no frames.

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

function ICON.Refresh()
    local on = CONFIG.iconsEnabled and CONFIG.iconContainers and #CONFIG.iconContainers > 0
    if not on then
        for key in pairs(containerFrames) do HideContainer(key) end
        wipe(lastSignature)
        if eventFrame then
            eventFrame:UnregisterAllEvents()
            eventFrame:SetScript("OnUpdate", nil)
        end
        return
    end

    if not eventFrame then
        -- PLAYER_REGEN_ENABLED lives on the event frame, so bailing here would
        -- leave a strip enabled mid fight with nothing to wake it. Retry until
        -- combat drops; only ever runs in this one transient case.
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
        eventFrame:SetScript("OnEvent", function(_, event)
            -- Sizes are multiples of a physical pixel, so a resolution or scale
            -- change invalidates geometry that no other event would touch.
            if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED"
                or event == "PLAYER_REGEN_ENABLED" then
                ICON.Relayout()
            else
                refeedCooldowns = true
                ICON.Layout()
            end
            StartTickIfNeeded()
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
