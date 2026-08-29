-- EventHorizon Infall: Icons settings tab.
-- Same shape as the Bars tab; pairing writes the same CONFIG.buffMappings.

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG

local PANEL_BG = { 0.05, 0.05, 0.08, 0.5 }
local PANEL_EDGE = { 0.3, 0.3, 0.3, 0.5 }

local GROW_FOR_ANCHOR = {
    TOP    = { { "LEFT", "Left" }, { "CENTRE", "Centre" }, { "RIGHT", "Right" } },
    BOTTOM = { { "LEFT", "Left" }, { "CENTRE", "Centre" }, { "RIGHT", "Right" } },
    LEFT   = { { "UP", "Up" }, { "CENTRE", "Centre" }, { "DOWN", "Down" } },
    RIGHT  = { { "UP", "Up" }, { "CENTRE", "Centre" }, { "DOWN", "Down" } },
}

local ANCHORS = { { "TOP", "Top" }, { "BOTTOM", "Bottom" }, { "LEFT", "Left" }, { "RIGHT", "Right" } }
local SIDE_SHORT = { TOP = "Top", BOTTOM = "Bot", LEFT = "Left", RIGHT = "Right" }
local SIDE_NEXT = { TOP = "RIGHT", RIGHT = "BOTTOM", BOTTOM = "LEFT", LEFT = "TOP" }

-- Ordered worst to best news, which is the order they matter in.
local STATE_ROWS = {
    { key = "cooldown", label = "On cooldown", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
        { "sweep", "Sweep", "cd", "none" }, { "timer", "Count" },
    } },
    { key = "buff", label = "Buff running", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
        { "sweep", "Wedge", "buff", "none" }, { "timer", "Count" },
        { "buffIcon", "Buff art" },
    } },
    { key = "recharging", label = "Recharging", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
        { "sweep", "Sweep", "cd", "none" }, { "timer", "Count" },
    } },
    { key = "proc", label = "Highlighted", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
    } },
    { key = "unusable", label = "Not usable", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
    } },
    { key = "ready", label = "Ready", opts = {
        { "show", "Show" }, { "desaturate", "Grey" },
    } },
}

local STATE_HELP = {
    cooldown = "The ability is recharging.",
    buff = "A paired buff is running. Beats the cooldown, so a buff that runs while the ability recharges reads as the buff.",
    recharging = "A charge is coming back but the ability can still be cast, so it is not greyed out by default. Only abilities with charges ever reach this.",
    proc = "The game is highlighting the ability, the way it lights up an action bar button. Beats Ready, so a proc can look different from merely being off cooldown.",
    unusable = "Out of range, out of resource, or otherwise blocked right now.",
    ready = "Off cooldown with nothing else to say about it.",
}

local OPT_HELP = {
    show = "Draw the icon at all in this state. Off means the icon gives up its place on the strip.",
    desaturate = "Drain the colour out of the art.",
    sweep = "Darken the icon in a clockwise wipe as the cooldown runs down.",
    timer = "Draw the remaining time on the icon.",
    buffIcon = "Swap the art to the running buff's own icon instead of the ability's, so an icon paired to several buffs shows which one is up.",
}

local function StyleAsPanel(f)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(PANEL_BG))
    f:SetBackdropBorderColor(unpack(PANEL_EDGE))
    return f
end

local function PanelTitle(f, text)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOPLEFT", 12, -14)
    t:SetText(text)
    return t
end

-- Percent in the UI, 0 to 1 in the profile.
local function CreatePercentBox(parent, get, set)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(38, 18)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetJustifyH("CENTER")

    local function Show_()
        box:SetText(tostring(math.floor((get() or 0) * 100 + 0.5)))
    end
    box:SetScript("OnEnterPressed", function(self)
        local n = tonumber(self:GetText())
        if n then set(math.max(0, math.min(100, n)) / 100) end
        Show_()
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", Show_)
    box:SetScript("OnEscapePressed", function(self) Show_() self:ClearFocus() end)
    box.Reload = Show_
    return box
end

function ns.BuildIconsTab(contentArea, tabFrames, helpers)
    local CreateCheckbox = helpers.CreateCheckbox
    local CreateSlider = helpers.CreateSlider
    local CreateSectionHeader = helpers.CreateSectionHeader
    local CreateScrollableContent = helpers.CreateScrollableContent
    local CreateDropdown = helpers.CreateDropdown
    local CreateColorSwatch = helpers.CreateColorSwatch
    local GetFontOptions = helpers.GetFontOptions
    local FONT_FLAG_OPTIONS = helpers.FONT_FLAG_OPTIONS
    local ANCHOR_POINTS = helpers.ANCHOR_POINTS

    local tab = CreateFrame("Frame", nil, contentArea)
    tab:SetAllPoints()
    tab:Hide()
    tabFrames[7] = tab

    local refreshAll
    local SelectSub

    -- Config access. The engine takes a list of containers; this tab manages one.

    local DEFAULTS = ns.Icons.CONTAINER_DEFAULTS
    local side = "TOP"

    -- Migrating here too: the layout pass is gated on the feature being enabled.
    local function Container(which)
        which = which or side
        ns.Icons.MigrateContainers()
        for _, c in ipairs(CONFIG.iconContainers or {}) do
            if c.key == which then
                for k, v in pairs(DEFAULTS) do
                    if c[k] == nil then c[k] = v end
                end
                c.anchor = which
                return c
            end
        end
        return DEFAULTS
    end

    -- Materializes on first write, so a side nobody touched stays out of the
    -- profile and out of the layout pass.
    local function WritableContainer(which)
        which = which or side
        CONFIG.iconContainers = CONFIG.iconContainers or {}
        for _, c in ipairs(CONFIG.iconContainers) do
            if c.key == which then return c end
        end
        local c = { key = which }
        for k, v in pairs(DEFAULTS) do c[k] = v end
        c.anchor = which
        CONFIG.iconContainers[#CONFIG.iconContainers + 1] = c
        return c
    end

    local refreshing = false

    -- Every refresher goes through here: setting a widget fires its handler, and
    -- handlers save. Nested, and restored through a pcall, or a throw strands the flag.
    local function Repopulate(fn)
        local was = refreshing
        refreshing = true
        local ok, err = pcall(fn)
        refreshing = was
        if not ok then
            print("|cff00ff00[Infall]|r The icon settings could not be refreshed. Reload if it looks wrong: " .. tostring(err))
        end
    end

    local function Apply()
        if refreshing then return end
        if ns.Icons then ns.Icons.Relayout() end
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
    end

    local function SetContainer(field, value)
        if refreshing then return end
        WritableContainer()[field] = value
        Apply()
    end

    -- Reads fall through entry, then general, then the engine default. nil in an
    -- entry means inherit, so a refresher must never write a value it read.
    local function StateValue(key, field, entry)
        if entry and entry.states and entry.states[key]
            and entry.states[key][field] ~= nil then
            return entry.states[key][field]
        end
        local g = CONFIG.iconStates and CONFIG.iconStates[key]
        if g and g[field] ~= nil then return g[field] end
        return ns.Icons.STATE_DEFAULTS[key][field]
    end

    local function SetStateValue(key, field, value, entry)
        if refreshing then return end
        if entry then
            entry.states = entry.states or {}
            entry.states[key] = entry.states[key] or {}
            entry.states[key][field] = value
        else
            CONFIG.iconStates = CONFIG.iconStates or {}
            CONFIG.iconStates[key] = CONFIG.iconStates[key] or {}
            CONFIG.iconStates[key][field] = value
        end
        Apply()
    end

    local function TextValue(key, field, entry)
        local e = entry and entry.states and entry.states[key]
        if e and e.text and e.text[field] ~= nil then return e.text[field] end
        local g = CONFIG.iconStates and CONFIG.iconStates[key]
        if g and g.text and g.text[field] ~= nil then return g.text[field] end
        return ns.Icons.TEXT_DEFAULTS[field]
    end

    local function SetTextValue(key, field, value, entry)
        if refreshing then return end
        local t
        if entry then
            entry.states = entry.states or {}
            entry.states[key] = entry.states[key] or {}
            entry.states[key].text = entry.states[key].text or {}
            t = entry.states[key].text
        else
            CONFIG.iconStates = CONFIG.iconStates or {}
            CONFIG.iconStates[key] = CONFIG.iconStates[key] or {}
            CONFIG.iconStates[key].text = CONFIG.iconStates[key].text or {}
            t = CONFIG.iconStates[key].text
        end
        t[field] = value
        Apply()
    end

    local function ColorValue(key, field, entry)
        local e = entry and entry.states and entry.states[key]
        if e and type(e[field]) == "table" then return e[field] end
        local g = CONFIG.iconStates and CONFIG.iconStates[key]
        if g and type(g[field]) == "table" then return g[field] end
        return ns.Icons.COLOR_DEFAULTS[field]
    end

    local function GcdValue(entry)
        if entry and entry.ignoreGCD ~= nil then return entry.ignoreGCD end
        return CONFIG.iconIgnoreGCD ~= false
    end

    local function GlowValue(entry)
        if entry and entry.glow ~= nil then return entry.glow end
        return CONFIG.iconGlow ~= false
    end

        -- One builder for the general panel and every accordion. scopeFn returns nil for
        -- the general settings, or the entry being overridden.
    local function BuildStateGroup(parent, startY, scopeFn, width)
        local checks, sliders, y = {}, {}, startY

        for _, row in ipairs(STATE_ROWS) do
            local f = CreateFrame("Frame", nil, parent)
            f:SetSize(width, 24)
            f:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
            y = y + 24

            local labelBtn = CreateFrame("Frame", nil, f)
            labelBtn:SetSize(104, 24)
            labelBtn:SetPoint("LEFT", 0, 0)
            local label = labelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetAllPoints()
            label:SetJustifyH("LEFT")
            label:SetJustifyV("MIDDLE")
            label:SetText(row.label)
            local help = STATE_HELP[row.key]
            if help then
                labelBtn:EnableMouse(true)
                labelBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(row.label)
                    GameTooltip:AddLine(help, 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                labelBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            label = labelBtn

            local last
            for _, opt in ipairs(row.opts) do
                local field, text, onValue, offValue = opt[1], opt[2], opt[3], opt[4]
                local holder = CreateFrame("Frame", nil, f)
                holder:SetSize(24, 24)
                if last then holder:SetPoint("LEFT", last, "RIGHT", 10, 0)
                else holder:SetPoint("LEFT", label, "RIGHT", 6, 0) end

                local cb = CreateFrame("CheckButton", nil, holder, "UICheckButtonTemplate")
                cb:SetSize(24, 24)
                cb:SetPoint("LEFT", 0, 0)
                local cbText = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cbText:SetPoint("LEFT", cb, "RIGHT", 2, 0)
                cbText:SetText(text)
                holder:SetWidth(24 + cbText:GetStringWidth() + 2)

                cb:SetScript("OnClick", function(self)
                    local checked = self:GetChecked() and true or false
                    if onValue then
                        SetStateValue(row.key, field, checked and onValue or offValue, scopeFn())
                    else
                        SetStateValue(row.key, field, checked, scopeFn())
                    end
                end)
                if OPT_HELP[field] then
                    cb:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(text)
                        GameTooltip:AddLine(OPT_HELP[field], 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                checks[#checks + 1] = { cb = cb, key = row.key, field = field, onValue = onValue }
                last = holder
            end

            local key = row.key
            local sl = CreateSlider(parent, "Opacity", 0, 100, 5, 100, function(v)
                SetStateValue(key, "opacity", v / 100, scopeFn())
            end)
            sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, -y)
            y = y + 48
            sliders[#sliders + 1] = { sl = sl, key = key }
        end

        local function ReloadInner()
            for _, e in ipairs(checks) do
                local v = StateValue(e.key, e.field, scopeFn())
                if e.onValue then
                    e.cb:SetChecked(v == e.onValue)
                else
                    e.cb:SetChecked(v and true or false)
                end
            end
            for _, e in ipairs(sliders) do
                e.sl:SetValue(math.floor((StateValue(e.key, "opacity", scopeFn()) or 1) * 100 + 0.5))
            end
        end

        local function Reload() Repopulate(ReloadInner) end

        return y, Reload
    end

    -- Font, size, outline, colour and placement for one state's countdown.
    local function BuildTextGroup(parent, startY, scopeFn, stateFn, width)
        local y = startY
        local widgets = {}

        local function Add(w, h)
            w:SetParent(parent)
            w:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
            w:Show()
            y = y + (h or (w:GetHeight() or 30)) + 4
            return w
        end

        local fontDD = Add(CreateDropdown(parent, "Font", GetFontOptions(), nil, function(v)
            SetTextValue(stateFn(), "font", v, scopeFn())
        end, true, true), 44)
        widgets.font = fontDD

        local sizeSl = Add(CreateSlider(parent, "Font Size", 6, 24, 1, 12, function(v)
            SetTextValue(stateFn(), "size", v, scopeFn())
        end), 46)
        widgets.size = sizeSl

        local flagsDD = Add(CreateDropdown(parent, "Outline", FONT_FLAG_OPTIONS, nil, function(v)
            SetTextValue(stateFn(), "flags", v, scopeFn())
        end), 44)
        widgets.flags = flagsDD

        local colSw = Add(CreateColorSwatch(parent, "Colour", { 1, 1, 1, 1 }, function(c)
            SetTextValue(stateFn(), "color", { c[1], c[2], c[3], c[4] or 1 }, scopeFn())
        end), 30)
        widgets.color = colSw

        local anchorDD = Add(CreateDropdown(parent, "Anchor", ANCHOR_POINTS, nil, function(v)
            SetTextValue(stateFn(), "anchor", v, scopeFn())
            SetTextValue(stateFn(), "relPoint", v, scopeFn())
        end), 44)
        widgets.anchor = anchorDD

        local offX = Add(CreateSlider(parent, "Offset X", -40, 40, 1, 0, function(v)
            SetTextValue(stateFn(), "offsetX", v, scopeFn())
        end), 46)
        widgets.offX = offX

        local offY = Add(CreateSlider(parent, "Offset Y", -40, 40, 1, 0, function(v)
            SetTextValue(stateFn(), "offsetY", v, scopeFn())
        end), 46)
        widgets.offY = offY

        local function ReloadInner()
            local k, e = stateFn(), scopeFn()
            widgets.font:SetValue(TextValue(k, "font", e))
            -- Unset means inherit Blizzard's font object, which has no number to
            -- show, so the slider parks on its size until the user moves it.
            widgets.size:SetValue(TextValue(k, "size", e) or 12)
            widgets.flags:SetValue(TextValue(k, "flags", e))
            local c = TextValue(k, "color", e)
            widgets.color:SetColor({ c[1], c[2], c[3], c[4] or 1 })
            widgets.anchor:SetValue(TextValue(k, "anchor", e))
            widgets.offX:SetValue(TextValue(k, "offsetX", e))
            widgets.offY:SetValue(TextValue(k, "offsetY", e))
        end

        local function Reload() Repopulate(ReloadInner) end

        return y, Reload
    end

    -- States, Text and Colours behind one strip, identical in the general panel and in
    -- every accordion. A state that draws a sweep and a countdown owns both, so its
    -- colour sits with its text.
    local function BuildLookPages(parent, startY, scopeFn, width)
        local strip = CreateFrame("Frame", nil, parent)
        strip:SetSize(width, 24)
        strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -startY)

        -- The panel top runs UNDER the tabs, not below them. Overlapping is what makes it
        -- read as one piece of card, and it is what the main tab bar does.
        local box = StyleAsPanel(CreateFrame("Frame", nil, parent, "BackdropTemplate"))
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -(startY + 21))
        box:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        strip:SetFrameLevel(box:GetFrameLevel() + 2)

        local PAGES = {
            { "states", "States" },
            { "cooldown", "Cooldown" },
            { "buff", "Buff" },
            { "count", "Count" },
        }

        local pages, buttons, reloads = {}, {}, {}
        local maxY = 0

        for i, def in ipairs(PAGES) do
            local b = CreateFrame("Button", nil, strip, "PanelTabButtonTemplate")
            b:SetText(def[2])
            PanelTemplates_TabResize(b, 8)
            b:SetID(i)
            if i == 1 then b:SetPoint("BOTTOMLEFT", 0, 0)
            else b:SetPoint("LEFT", buttons[i - 1], "RIGHT", -8, 0) end
            buttons[i] = b
            buttons[def[1]] = b

            local f = CreateFrame("Frame", nil, box)
            f:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            f:SetPoint("RIGHT", box, "RIGHT", 0, 0)
            f:SetHeight(10)
            f:Hide()
            pages[def[1]] = f
        end

        local topRule = parent:CreateTexture(nil, "ARTWORK")
        topRule:SetColorTexture(0.6, 0.6, 0.6, 0.35)
        topRule:SetHeight(1)
        topRule:SetPoint("BOTTOMLEFT", buttons[1], "TOPLEFT", -2, 1)
        topRule:SetPoint("RIGHT", box, "RIGHT", 0, 0)

        local sEnd, sReload = BuildStateGroup(pages.states, 12, scopeFn, width - 40)
        sEnd = sEnd + 10
        pages.states:SetHeight(sEnd)
        reloads.states = sReload
        maxY = math.max(maxY, sEnd)

        -- One page per timed state: what colours it, then what its number says.
        local TIMED = {
            { key = "cooldown", field = "sweepColor", label = "Sweep colour",
              hint = "The wipe that drains across the icon while the cooldown runs." },
            { key = "buff", field = "wedgeColor", label = "Wedge colour",
              hint = "Marks the time REMAINING, so it is a highlight rather than a mask. Inverting it would need arithmetic on a secret." },
        }

        for _, def in ipairs(TIMED) do
            local page, key, field = pages[def.key], def.key, def.field
            local y = 12

            local sw = CreateColorSwatch(page, def.label,
                ns.Icons.COLOR_DEFAULTS[field], function(c)
                    SetStateValue(key, field, { c[1], c[2], c[3], c[4] or 1 }, scopeFn())
                end)
            sw:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -y)
            y = y + 30

            local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hint:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -y)
            hint:SetWidth(width - 44)
            hint:SetJustifyH("LEFT")
            hint:SetSpacing(2)
            hint:SetText(def.hint)
            y = y + hint:GetStringHeight() + 10

            local rule = page:CreateTexture(nil, "ARTWORK")
            rule:SetColorTexture(0.4, 0.4, 0.4, 0.35)
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -y)
            rule:SetPoint("TOPRIGHT", page, "TOPRIGHT", -14, -y)
            y = y + 12

            local tEnd, tReload = BuildTextGroup(page, y, scopeFn,
                function() return key end, width - 40)
            tEnd = tEnd + 10
            page:SetHeight(tEnd)
            reloads[key] = function()
                local c = ColorValue(key, field, scopeFn())
                sw:SetColor({ c[1], c[2], c[3], c[4] or 1 })
                tReload()
            end
            maxY = math.max(maxY, tEnd)
        end

        do
            local page = pages.count
            local y = 12

            local showCB = CreateCheckbox(page, "Show the count", nil,
                true, function(v)
                    SetStateValue("count", "show", v, scopeFn())
                end,
                "Charges for an ability that has them, otherwise the stack count of a running paired buff.")
            showCB:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -y)
            y = y + (showCB:GetHeight() or 36) + 6

            local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hint:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -y)
            hint:SetWidth(width - 44)
            hint:SetJustifyH("LEFT")
            hint:SetSpacing(2)
            hint:SetText("Charges show on abilities that have more than one. Buff stacks show only when the aura has more than one and the count is readable, which it is not in instanced content.")
            y = y + hint:GetStringHeight() + 10

            local rule = page:CreateTexture(nil, "ARTWORK")
            rule:SetColorTexture(0.4, 0.4, 0.4, 0.35)
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -y)
            rule:SetPoint("TOPRIGHT", page, "TOPRIGHT", -14, -y)
            y = y + 12

            local cEnd, cReload = BuildTextGroup(page, y, scopeFn,
                function() return "count" end, width - 40)
            cEnd = cEnd + 10
            page:SetHeight(cEnd)
            reloads.count = function()
                showCB:SetChecked(StateValue("count", "show", scopeFn()) ~= false)
                cReload()
            end
            maxY = math.max(maxY, cEnd)
        end

        local current = "states"

        local function Refresh()
            for key, f in pairs(pages) do
                f:SetShown(key == current)
                if key == current then
                    PanelTemplates_SelectTab(buttons[key])
                else
                    PanelTemplates_DeselectTab(buttons[key])
                end
            end
            reloads[current]()
        end

        for _, def in ipairs(PAGES) do
            local key = def[1]
            buttons[key]:SetScript("OnClick", function()
                current = key
                Refresh()
                if parent.OwnerModal and parent.OwnerModal.ApplyPreview then
                    parent.OwnerModal.ApplyPreview()
                end
            end)
        end

        -- Which state the open page is about, so the preview can show it.
        local function PreviewState()
            if current == "states" then return nil end
            return current
        end

        box:SetHeight(maxY)
        return startY + 21 + maxY, Refresh, PreviewState
    end


    -- On this strip, not merely somewhere. The same cooldown can sit on two
    -- strips, so a global check would grey out an icon still addable here.
    local function EntryID(e) return e.cooldownID or e.key end

    local function IsTracked(cdID)
        for _, e in ipairs(CONFIG.iconList or {}) do
            if e.cooldownID == cdID and (e.container or "TOP") == side then return true end
        end
        return false
    end

    -- Sub tabs, the same primitive the pools and the main tab bar use

    local SUBS = { { "icons", "Icons" }, { "strip", "Strip" }, { "look", "General" } }
    local subFrames, subButtons = {}, {}

    local instrBlock = CreateFrame("Frame", nil, tab, "BackdropTemplate")
    instrBlock:SetPoint("TOPLEFT", 0, 0)
    instrBlock:SetPoint("TOPRIGHT", 0, 0)
    instrBlock:SetHeight(96)
    instrBlock:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    instrBlock:SetBackdropColor(0.14, 0.14, 0.18, 0.6)
    instrBlock:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.4)

    local instrText = instrBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instrText:SetPoint("TOPLEFT", 12, -10)
    instrText:SetPoint("TOPRIGHT", -12, -10)
    instrText:SetJustifyH("LEFT")
    instrText:SetTextColor(0.82, 0.82, 0.82)
    instrText:SetSpacing(2)
    instrText:SetText("A row of icons beside the timeline, for cooldowns you would rather see as icons than bars.")

    local enableCB = CreateCheckbox(instrBlock, "Enable Icon Strip", nil,
        CONFIG.iconsEnabled or false, function(v)
            CONFIG.iconsEnabled = v
            if ns.RefreshIcons then ns.RefreshIcons() end
            if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        end)
    enableCB:SetPoint("TOPLEFT", 8, -34)

    local sideButtons = {}

    local cdmBtn = CreateFrame("Button", nil, instrBlock, "UIPanelButtonTemplate")
    cdmBtn:SetSize(180, 22)
    -- Centred on the checkbox itself, which is 26px inside its 36px container,
    -- so the two read as one row rather than one sitting higher than the other.
    cdmBtn:SetPoint("LEFT", enableCB.checkbox, "RIGHT", 150, 0)
    cdmBtn:SetText("Open Cooldown Manager")
    cdmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Cooldown Manager")
        GameTooltip:AddLine("Anything not tracked there cannot go on the strip. Add it there first. Opens in front of this window and can be dragged aside.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cdmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cdmBtn:SetScript("OnClick", function()
        if ns.OpenCooldownManager then ns.OpenCooldownManager() end
    end)

    local sideLabel = instrBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sideLabel:SetPoint("TOPLEFT", 12, -68)
    sideLabel:SetText("Active strip:")

    for i, def in ipairs(ANCHORS) do
        local value = def[1]
        local btn = CreateFrame("Button", nil, instrBlock, "UIPanelButtonTemplate")
        btn:SetSize(74, 22)
        if i == 1 then btn:SetPoint("TOPLEFT", sideLabel, "TOPRIGHT", 10, 5)
        else btn:SetPoint("LEFT", sideButtons[i - 1], "RIGHT", 3, 0) end
        btn:SetScript("OnClick", function()
            side = value
            refreshAll()
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(def[2] .. " strip")
            GameTooltip:AddLine("All three tabs below edit this strip: its icons, its placement, its look.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sideButtons[i] = btn
        sideButtons[value] = btn
    end

    for i, def in ipairs(SUBS) do
        local key, label = def[1], def[2]
        local b = CreateFrame("Button", nil, tab, "PanelTabButtonTemplate")
        b:SetText(label)
        PanelTemplates_TabResize(b, 8)
        b:SetID(i)
        if i == 1 then
            b:SetPoint("TOPLEFT", instrBlock, "BOTTOMLEFT", 6, -2)
        else
            b:SetPoint("LEFT", subButtons[i - 1], "RIGHT", -8, 0)
        end
        b:SetScript("OnClick", function() SelectSub(key) end)
        subButtons[i] = b

        local f = CreateFrame("Frame", nil, tab)
        f:SetPoint("TOPLEFT", instrBlock, "BOTTOMLEFT", 0, -30)
        f:SetPoint("BOTTOMRIGHT", 0, 0)
        f:Hide()
        subFrames[key] = f
    end

    SelectSub = function(key)
        if ns.CloseAllMenus then ns.CloseAllMenus() end
        for i, def in ipairs(SUBS) do
            subFrames[def[1]]:SetShown(def[1] == key)
            if def[1] == key then
                PanelTemplates_SelectTab(subButtons[i])
            else
                PanelTemplates_DeselectTab(subButtons[i])
            end
        end
        if refreshAll then refreshAll() end
    end

    -- Icons: rows on top, pools below, exactly like Bars

    local iconsTab = subFrames.icons

    local listPanel = StyleAsPanel(CreateFrame("Frame", nil, iconsTab, "BackdropTemplate"))
    listPanel:SetPoint("TOPLEFT", 0, 0)
    listPanel:SetPoint("RIGHT", 0, 0)
    -- Chosen so the pool below starts at the same height as the Bars tab's, plus the
    -- 20px the strip selector under the title costs. The pool below gives it up.
    listPanel:SetHeight(220)
    PanelTitle(listPanel, "On The Strip")

    local LIST_INSET = 12
    local COL = {
        show = 6, remove = 34, icon = 62, ability = 92, strip = 220,
        buff1 = 274, buff2 = 324, buff3 = 374, order = 436, settings = 488,
    }
    for _, def in ipairs({
        { "Show", COL.show }, { "Ability", COL.ability }, { "Strip", COL.strip },
        { "Buff 1", COL.buff1 }, { "Buff 2", COL.buff2 }, { "Buff 3", COL.buff3 },
        { "Order", COL.order }, { "Settings", COL.settings },
    }) do
        local h = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        h:SetPoint("TOPLEFT", LIST_INSET + def[2], -40)
        h:SetText(def[1])
    end

    local addCustomBtn = CreateFrame("Button", nil, listPanel, "UIPanelButtonTemplate")
    addCustomBtn:SetSize(140, 22)
    addCustomBtn:SetPoint("TOPRIGHT", -12, -10)
    addCustomBtn:SetText("+ Add Custom Icon")
    addCustomBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add Custom Icon")
        GameTooltip:AddLine("An icon with no cooldown behind it. Pick its art, then pair Buff 1, 2 and 3 like any other row. Type a spell ID in the search box to use art you do not know.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    addCustomBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    addCustomBtn:SetScript("OnClick", function(self)
        if not ns.OpenSpellPicker then return end
        ns.OpenSpellPicker({
            title = "Pick Icon For Custom Icon",
            anchor = self,
            onSelect = function(pickedID, pickedName, pickedIcon)
                CONFIG.iconList = CONFIG.iconList or {}
                WritableContainer(side)
                CONFIG.iconList[#CONFIG.iconList + 1] = {
                    -- Unique across the timeline's custom rows too: both lists
                    -- index the same shared tables.
                    key = ns.NextCustomKey(),
                    iconSpellID = pickedID,
                    iconTexture = pickedIcon,
                    label = pickedName,
                    container = side,
                    enabled = true,
                }
                refreshAll() Apply()
            end,
        })
    end)

    local listScroll, listBody = CreateScrollableContent(listPanel)
    listScroll:SetPoint("TOPLEFT", 12, -58)
    listScroll:SetPoint("BOTTOMRIGHT", -28, 10)

    local emptyLabel = listBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyLabel:SetPoint("TOPLEFT", 6, -6)
    emptyLabel:SetText("Nothing on this strip yet. Click a cooldown in the pool below to add it.")

    local poolPanel = StyleAsPanel(CreateFrame("Frame", nil, iconsTab, "BackdropTemplate"))
    poolPanel:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -6)
    poolPanel:SetPoint("BOTTOMRIGHT", 0, 0)

    local statusText = poolPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPRIGHT", -8, -8)
    statusText:SetJustifyH("RIGHT")

    local poolTabs, poolNames = {}, { "Cooldowns", "Buffs" }
    local activePool = 1
    local selectedBuff

    local poolHint = poolPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    poolHint:SetPoint("TOPLEFT", 14, -42)
    poolHint:SetJustifyH("LEFT")

    local poolScroll, poolBody = CreateScrollableContent(poolPanel)
    poolScroll:SetPoint("TOPLEFT", 12, -62)
    poolScroll:SetPoint("BOTTOMRIGHT", -28, 10)

    for i, name in ipairs(poolNames) do
        local t = CreateFrame("Button", nil, poolPanel, "PanelTabButtonTemplate")
        t:SetText(name)
        PanelTemplates_TabResize(t, 8)
        t:SetID(i)
        if i == 1 then
            t:SetPoint("TOPLEFT", 4, -2)
        else
            t:SetPoint("LEFT", poolTabs[i - 1], "RIGHT", -8, 0)
        end
        t:SetScript("OnClick", function()
            activePool = i
            if i == 1 then selectedBuff = nil statusText:SetText("") end
            refreshAll()
        end)
        poolTabs[i] = t
    end

    -- Pairing, on the row

    local function MappingsFor(cooldownID)
        return CONFIG.buffMappings and CONFIG.buffMappings[cooldownID] or nil
    end

    local function ClearSlot(cooldownID, idx)
        local m = MappingsFor(cooldownID)
        if m and m[idx] then
            table.remove(m, idx)
            refreshAll()
            Apply()
        end
    end

    local function AssignSlot(cooldownID, idx)
        if not selectedBuff then
            statusText:SetText("|cff88bbffPick a buff from the Buffs pool first.|r")
            return
        end
        CONFIG.buffMappings = CONFIG.buffMappings or {}
        local m = CONFIG.buffMappings[cooldownID]
        if not m then m = {} CONFIG.buffMappings[cooldownID] = m end
        -- Slots fill in order, matching how the Bars tab treats its lanes.
        m[math.min(idx, #m + 1)] = { buffCooldownIDs = { selectedBuff } }
        statusText:SetText("")
        refreshAll()
        Apply()
    end

    local function NewSlot(row, index)
        local slot = CreateFrame("Button", nil, row, "BackdropTemplate")
        slot:SetSize(24, 24)
        slot:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        slot:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
        slot:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)
        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetPoint("TOPLEFT", 1, -1)
        slot.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot.icon:Hide()
        slot.glow = slot:CreateTexture(nil, "OVERLAY")
        slot.glow:SetPoint("TOPLEFT", -2, 2)
        slot.glow:SetPoint("BOTTOMRIGHT", 2, -2)
        slot.glow:SetColorTexture(0.2, 1, 0.2, 0.35)
        slot.glow:Hide()
        slot:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.pairName or ("Buff " .. index))
            if self.pairName then
                GameTooltip:AddLine("Right click to clear", 0.5, 0.8, 0.5)
            elseif selectedBuff then
                GameTooltip:AddLine("Click to pair the picked buff", 0.5, 0.8, 0.5)
            else
                GameTooltip:AddLine("Pick a buff from the Buffs pool", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return slot
    end

    local rowCache, rowCount = {}, 0
    local modals = {}
    local modalCount = 0

    -- Still in the list, wherever it has been moved to.
    local function EntryStillLive(entry)
        for _, e in ipairs(CONFIG.iconList or {}) do
            if e == entry then return e end
        end
        -- Repoint by identity: ApplyProfile DeepCopies iconList, so an open entry goes stale.
        local id = entry.cooldownID or entry.key
        if id == nil then return nil end
        for _, e in ipairs(CONFIG.iconList or {}) do
            if (e.cooldownID or e.key) == id
                and (e.container or "TOP") == (entry.container or "TOP") then
                return e
            end
        end
        return nil
    end

    -- One movable window per icon, several at once. Keyed by the entry table, not by
    -- cooldownID or row index: the same ability can sit on more than one strip, and
    -- reordering must not repoint an open window.
    local function OpenIconModal(entry)
        if not entry then return nil end
        local cdID = entry.cooldownID or entry.key
        local m = modals[entry]
        if m then
            m:Show()
            m:Raise()
            m.Reload()
            return m
        end


        modalCount = modalCount + 1
        m = CreateFrame("Frame", "EHInfallIconSettings" .. modalCount, UIParent,
            "BasicFrameTemplateWithInset")
        m:SetFrameStrata("DIALOG")
        m:SetWidth(560)
        m:SetMovable(true)
        m:EnableMouse(true)
        m:SetClampedToScreen(true)
        m:RegisterForDrag("LeftButton")
        m:SetScript("OnDragStart", m.StartMoving)
        m:SetScript("OnDragStop", m.StopMovingOrSizing)
        tinsert(UISpecialFrames, m:GetName())

        -- Alpha on the art, not the frame: dropping the frame alpha would take
        -- the labels and swatches down with it.
        if m.Bg then m.Bg:SetAlpha(0.88) end
        if m.InsetBg then m.InsetBg:SetAlpha(0.88) end
        if m.TitleBg then m.TitleBg:SetAlpha(0.9) end

        -- The template's inset is art, not a frame, so content hangs off a body
        -- anchored inside its bounds.
        local body = CreateFrame("Frame", nil, m)
        body:SetPoint("TOPLEFT", 10, -30)
        body:SetPoint("BOTTOMRIGHT", -12, 10)

        modalCount = modalCount + 1
        local step = ((modalCount - 1) % 6) * 26
        m:SetPoint("CENTER", UIParent, "CENTER", 140 + step, 120 - step)

        local nm, ic
        if entry.cooldownID then
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
            nm, ic = ns.ResolveCooldownDisplay(cdID, ok and info or nil)
        else
            nm = entry.label
            ic = entry.iconTexture
                or (entry.iconSpellID and C_Spell.GetSpellTexture(entry.iconSpellID))
        end

        local titleIcon = m:CreateTexture(nil, "ARTWORK")
        titleIcon:SetSize(20, 20)
        titleIcon:SetPoint("TOPLEFT", 8, -3)
        titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        titleIcon:SetTexture(ic or 134400)

        if m.TitleText then
            m.TitleText:ClearAllPoints()
            m.TitleText:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
            m.TitleText:SetText((nm or ("ID:" .. tostring(cdID)))
                .. "  |cff9d9d9d" .. (SIDE_SHORT[entry.container or "TOP"] or "") .. "|r")
        else
            local t = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            t:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
            t:SetText((nm or ("ID:" .. tostring(cdID)))
                .. "  |cff9d9d9d" .. (SIDE_SHORT[entry.container or "TOP"] or "") .. "|r")
        end

        local scope = function() return EntryStillLive(entry) end

        local reset = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
        reset:SetSize(110, 22)
        reset:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -6)
        reset:SetText("Reset")

        local hint = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 12, -10)
        hint:SetPoint("RIGHT", reset, "LEFT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText("Customize this icon, or reset it back to the general settings.")

        local gcd = CreateCheckbox(body, "Ignore the global cooldown", nil,
            GcdValue(entry), function(v)
                local e = scope()
                if e then e.ignoreGCD = v end
                Apply()
            end)
        gcd:SetPoint("TOPLEFT", 12, -34)

        local glow = CreateCheckbox(body, "Show proc glow", nil,
            GlowValue(entry), function(v)
                local e = scope()
                if e then e.glow = v end
                Apply()
            end,
            "Draws the game's own proc art around this icon when it lights up. The Highlighted state decides whether it shows at all, and how strongly.")
        glow:SetPoint("TOPLEFT", 268, -34)

        local endY, RefreshPages, PreviewState = BuildLookPages(body, 72, scope, 536)

        local function ApplyPreview()
            if not m:IsShown() then return end
            ns.Icons.preview = { entry = scope(), state = PreviewState() }
            if ns.Icons.Relayout then ns.Icons.Relayout() end
        end
        m.ApplyPreview = ApplyPreview

        m:SetScript("OnHide", function()
            if ns.Icons.preview and ns.Icons.preview.entry == entry then
                ns.Icons.preview = nil
                if ns.Icons.Relayout then ns.Icons.Relayout() end
            end
        end)

        reset:SetScript("OnClick", function()
            local e = scope()
            if e then
                e.states = nil
                e.ignoreGCD = nil
                e.glow = nil
            end
            gcd:SetChecked(GcdValue(e))
            glow:SetChecked(GlowValue(e))
            RefreshPages()
            refreshAll()
            Apply()
        end)

        m:SetHeight(endY + 52)
        m.Reload = function()
            local e = scope()
            if not e then m:Hide() return end
            gcd:SetChecked(GcdValue(e))
            glow:SetChecked(GlowValue(e))
            RefreshPages()
            ApplyPreview()
        end

        body.OwnerModal = m
        modals[entry] = m
        m.Reload()
        m:Show()
        m:Raise()
        return m
    end

    local function CloseAllModals()
        for _, m in pairs(modals) do m:Hide() end
        ns.Icons.preview = nil
        if ns.Icons.Relayout then ns.Icons.Relayout() end
    end

    local function RefreshList()
        for i = 1, rowCount do
            if rowCache[i] then rowCache[i]:Hide() end
        end

        local all = CONFIG.iconList or {}
        local list = {}
        for realIdx, e in ipairs(all) do
            if (e.container or "TOP") == side then
                list[#list + 1] = { entry = e, idx = realIdx }
            end
        end
        emptyLabel:SetShown(#list == 0)

        local rowH = 30
        for i, item in ipairs(list) do
            local entry, realIdx = item.entry, item.idx
            local row = rowCache[i]
            if not row then
                row = CreateFrame("Frame", nil, listBody)
                row:SetSize(520, rowH)

                row.show = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                row.show:SetSize(24, 24)
                row.show:SetPoint("TOPLEFT", COL.show, -2)
                row.show:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Show")
                    GameTooltip:AddLine("Take it off the strip without losing its settings.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                row.show:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(24, 24)
                row.icon:SetPoint("TOPLEFT", COL.icon, -2)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.name:SetPoint("TOPLEFT", COL.ability, -8)
                row.name:SetWidth(120)
                row.name:SetJustifyH("LEFT")
                row.name:SetWordWrap(false)

                row.strip = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.strip:SetSize(48, 22)
                row.strip:SetPoint("TOPLEFT", COL.strip, -3)
                row.strip:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Strip")
                    GameTooltip:AddLine("Which side this icon sits on. Moving it takes it off this list.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                row.strip:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row.slots = {}
                for k, x in ipairs({ COL.buff1, COL.buff2, COL.buff3 }) do
                    local slot = NewSlot(row, k)
                    slot:SetPoint("TOPLEFT", x, -2)
                    row.slots[k] = slot
                end

                row.up = CreateFrame("Button", nil, row)
                row.up:SetSize(18, 16)
                row.up:SetPoint("TOPLEFT", COL.order, -6)
                row.up:SetNormalAtlas("UI-ScrollBar-ScrollUpButton-Up")
                row.up:SetPushedAtlas("UI-ScrollBar-ScrollUpButton-Down")
                row.up:SetHighlightAtlas("UI-ScrollBar-ScrollUpButton-Highlight")
                row.up:SetDisabledAtlas("UI-ScrollBar-ScrollUpButton-Disabled")

                row.down = CreateFrame("Button", nil, row)
                row.down:SetSize(18, 16)
                row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
                row.down:SetNormalAtlas("UI-ScrollBar-ScrollDownButton-Up")
                row.down:SetPushedAtlas("UI-ScrollBar-ScrollDownButton-Down")
                row.down:SetHighlightAtlas("UI-ScrollBar-ScrollDownButton-Highlight")
                row.down:SetDisabledAtlas("UI-ScrollBar-ScrollDownButton-Disabled")

                row.cog = CreateFrame("Button", nil, row)
                row.cog:SetSize(20, 20)
                row.cog:SetPoint("TOPLEFT", COL.settings, -4)
                row.cog:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
                row.cog:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton", "ADD")
                row.cog:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Appearance for this icon")
                    GameTooltip:AddLine("Colours, text and states, for this one icon.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                row.cog:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row.del = ns.CreateRemoveButton(row, "Remove", nil, 22)
                row.del:SetPoint("TOPLEFT", COL.remove, -3)

                row.overridden = row:CreateTexture(nil, "OVERLAY")
                row.overridden:SetSize(6, 6)
                row.overridden:SetPoint("TOPLEFT", row.cog, "TOPLEFT", -2, 2)
                row.overridden:SetColorTexture(1, 0.82, 0, 1)

                rowCache[i] = row
                rowCount = math.max(rowCount, i)
            end

            local rName, rIcon
            if entry.cooldownID then
                local cdInfoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, entry.cooldownID)
                rName, rIcon = ns.ResolveCooldownDisplay(entry.cooldownID, cdInfoOk and cdInfo or nil)
            else
                rName = entry.label
                rIcon = entry.iconTexture
                    or (entry.iconSpellID and C_Spell.GetSpellTexture(entry.iconSpellID))
            end
            row.icon:SetTexture(rIcon or 134400)
            row.name:SetText(rName or ("ID:" .. tostring(EntryID(entry))))

            local cdID = EntryID(entry)
            local m = MappingsFor(cdID)
            for k, slot in ipairs(row.slots) do
                local mapData = m and m[k]
                local bcd = mapData and mapData.buffCooldownIDs and mapData.buffCooldownIDs[1]
                if bcd then
                    local bOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, bcd)
                    local bName, bIcon = ns.ResolveCooldownDisplay(bcd, bOk and bInfo or nil)
                    slot.icon:SetTexture(bIcon or 134400)
                    slot.icon:Show()
                    slot.pairName = bName
                else
                    slot.icon:Hide()
                    slot.pairName = nil
                end
                slot.glow:SetShown(selectedBuff ~= nil and not bcd)
                slot:SetScript("OnClick", function(_, button)
                    if button == "RightButton" then ClearSlot(cdID, k) else AssignSlot(cdID, k) end
                end)
            end

            row.overridden:SetShown((entry.states ~= nil and next(entry.states) ~= nil)
                or entry.ignoreGCD ~= nil or entry.glow ~= nil)

            row.entry = entry
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", listBody, "TOPLEFT", 0, -(i - 1) * rowH)
            row:Show()

            local mySide = entry.container or "TOP"
            row.strip:SetText(SIDE_SHORT[mySide] or "Top")
            row.strip:SetScript("OnClick", function(self)
                if MenuUtil and MenuUtil.CreateContextMenu then
                    MenuUtil.CreateContextMenu(self, function(_, root)
                        root:CreateTitle("Move to strip")
                        for _, def in ipairs(ANCHORS) do
                            local value, text = def[1], def[2]
                            local b = root:CreateButton(text, function()
                                entry.container = value
                                WritableContainer(value)
                                refreshAll() Apply()
                            end)
                            if b and b.SetEnabled then b:SetEnabled(value ~= mySide) end
                        end
                    end)
                else
                    -- No menu API: cycling is worse but beats no way to move it.
                    entry.container = SIDE_NEXT[mySide] or "TOP"
                    WritableContainer(entry.container)
                    refreshAll() Apply()
                end
            end)

            row.show:SetChecked(entry.enabled ~= false)
            row.show:SetScript("OnClick", function(self)
                entry.enabled = self:GetChecked() and true or false
                Apply()
            end)

            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(i < #list)
            -- Swap against the previous or next entry ON THIS STRIP, which is
            -- not the neighbouring position in the full list.
            local prevIdx = list[i - 1] and list[i - 1].idx
            local nextIdx = list[i + 1] and list[i + 1].idx
            row.up:SetScript("OnClick", function()
                if not prevIdx then return end
                local l = CONFIG.iconList
                l[realIdx], l[prevIdx] = l[prevIdx], l[realIdx]
                refreshAll() Apply()
            end)
            row.down:SetScript("OnClick", function()
                if not nextIdx then return end
                local l = CONFIG.iconList
                l[realIdx], l[nextIdx] = l[nextIdx], l[realIdx]
                refreshAll() Apply()
            end)
            row.del:SetScript("OnClick", function()
                local m = modals[entry]
                if m then m:Hide() end
                table.remove(CONFIG.iconList, realIdx)
                refreshAll() Apply()
            end)
            row.cog:SetScript("OnClick", function()
                local m = modals[entry]
                if m and m:IsShown() then m:Hide() else OpenIconModal(entry) end
            end)
        end

        listBody:SetHeight(math.max(20, #list * rowH))
    end

    -- Pools

    local gridCache, gridCount = {}, 0

    -- The data provider reflects where the player actually put things.
    local function CategoryIDs(cat, allowUnknown)
        local shown = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(cat, allowUnknown)
        if type(shown) == "table" then return shown end
        local ok, set = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, cat,
            allowUnknown and true or false)
        return (ok and set) or {}
    end

    local function PoolIDs()
        local seen, ids = {}, {}
        local isBuffPool = activePool ~= 1
        local cats = isBuffPool and { 2, 3 } or { 0, 1 }
        for _, cat in ipairs(cats) do
            for _, id in ipairs(CategoryIDs(cat, isBuffPool)) do
                if not seen[id] then seen[id] = true ids[#ids + 1] = id end
            end
        end
        if activePool == 2 then
            -- Entries whose buff is themselves, which is most movement cooldowns.
            for _, cat in ipairs({ 0, 1 }) do
                for _, id in ipairs(CategoryIDs(cat)) do
                    if not seen[id] then
                        local iOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                        if iOk and info and info.hasAura then
                            seen[id] = true ids[#ids + 1] = id
                        end
                    end
                end
            end
        end
        return ids
    end

    local function RefreshGrid()
        for i = 1, gridCount do
            if gridCache[i] then gridCache[i]:Hide() end
        end

        local ids = PoolIDs()
        local iconSz, gap = 30, 4
        local avail = (poolBody:GetWidth() or 0) - 12
        if avail < iconSz then avail = 520 end
        local cols = math.max(1, math.floor((avail + gap) / (iconSz + gap)))

        for i, cdID in ipairs(ids) do
            local btn = gridCache[i]
            if not btn then
                btn = CreateFrame("Button", nil, poolBody)
                btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                btn.iconTex = btn:CreateTexture(nil, "ARTWORK")
                btn.iconTex:SetAllPoints()
                btn.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                btn.mark = btn:CreateTexture(nil, "OVERLAY")
                btn.mark:SetPoint("TOPLEFT", -2, 2)
                btn.mark:SetPoint("BOTTOMRIGHT", 2, -2)
                gridCache[i] = btn
                gridCount = math.max(gridCount, i)
            end

            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
            local nm, ic = ns.ResolveCooldownDisplay(cdID, ok and info or nil)
            btn:SetSize(iconSz, iconSz)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", 4 + ((i - 1) % cols) * (iconSz + gap),
                -4 - math.floor((i - 1) / cols) * (iconSz + gap))
            btn.iconTex:SetTexture(ic or 134400)
            btn.entryName = nm or ("ID:" .. cdID)

            if activePool == 1 then
                btn.mark:SetColorTexture(0, 0.8, 0, 0.5)
                btn.mark:SetShown(IsTracked(cdID))
            else
                btn.mark:SetColorTexture(1, 0.82, 0, 0.6)
                btn.mark:SetShown(selectedBuff == cdID)
            end
            btn:Show()

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.entryName, 1, 1, 1)
                if activePool == 1 then
                    GameTooltip:AddLine(IsTracked(cdID)
                        and "On this strip, right click to remove" or "Click to add to this strip",
                        0.5, 0.8, 0.5)
                else
                    GameTooltip:AddLine("Click to pick, then click a slot on a row", 0.5, 0.8, 0.5)
                end
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(_, button)
                if activePool == 1 then
                    CONFIG.iconList = CONFIG.iconList or {}
                    if button == "RightButton" then
                        for k = #CONFIG.iconList, 1, -1 do
                            local e = CONFIG.iconList[k]
                            if e.cooldownID == cdID and (e.container or "TOP") == side then
                                table.remove(CONFIG.iconList, k)
                            end
                        end
                    elseif not IsTracked(cdID) then
                        WritableContainer()
                        CONFIG.iconList[#CONFIG.iconList + 1] =
                            { cooldownID = cdID, container = side, enabled = true }
                    else
                        return
                    end
                    refreshAll() Apply()
                else
                    selectedBuff = (selectedBuff == cdID) and nil or cdID
                    statusText:SetText(selectedBuff
                        and ("|cff88bbffPicked " .. (nm or cdID) .. ", now click a slot.|r") or "")
                    refreshAll()
                end
            end)
        end

        poolBody:SetHeight(math.max(20, math.ceil(#ids / cols) * (iconSz + gap) + 8))
    end

    -- Strip: placement and visibility

    local stripTab = subFrames.strip
    local stripPanel = StyleAsPanel(CreateFrame("Frame", nil, stripTab, "BackdropTemplate"))
    stripPanel:SetAllPoints()
    PanelTitle(stripPanel, "Strip")

    local _, stripBody = CreateScrollableContent(stripPanel)
    local sy = 34

    local function StripWidget(w, gap)
        w:SetParent(stripBody)
        w:SetPoint("TOPLEFT", stripBody, "TOPLEFT", 10, -sy)
        w:Show()
        sy = sy + (w:GetHeight() or 30) + (gap or 6)
    end

    local function StripHeader(text)
        local h = CreateSectionHeader(stripBody, text)
        h:SetPoint("TOPLEFT", stripBody, "TOPLEFT", 10, -sy)
        sy = sy + 24
    end

    local function StripDesc(text)
        local d = stripBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        d:SetPoint("TOPLEFT", stripBody, "TOPLEFT", 10, -sy)
        d:SetWidth(520)
        d:SetJustifyH("LEFT")
        d:SetSpacing(2)
        d:SetText(text)
        sy = sy + d:GetStringHeight() + 8
    end

    StripHeader("Placement")

    local growButtons, UpdateGrowButtons = {}, nil

    local prev
    local growFrame = CreateFrame("Frame", nil, stripBody)
    growFrame:SetSize(520, 26)
    local growLabel = growFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    growLabel:SetPoint("LEFT", 0, 0)
    growLabel:SetWidth(70)
    growLabel:SetJustifyH("LEFT")
    growLabel:SetText("Grows")

    prev = nil
    for i = 1, 3 do
        local btn = CreateFrame("Button", nil, growFrame, "UIPanelButtonTemplate")
        btn:SetSize(64, 22)
        if prev then btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else btn:SetPoint("LEFT", growLabel, "RIGHT", 10, 0) end
        btn:SetScript("OnClick", function(self)
            WritableContainer().grow = self.value
            UpdateGrowButtons() Apply()
        end)
        growButtons[i] = btn
        prev = btn
    end

    UpdateGrowButtons = function()
        local c = Container()
        local options = GROW_FOR_ANCHOR[side] or GROW_FOR_ANCHOR.TOP
        -- Growth is on the strip's own axis, so a value from the other axis is
        -- meaningless here and would leave every button enabled.
        local valid = false
        for _, g in ipairs(options) do
            if g[1] == c.grow then valid = true end
        end
        if not valid and c ~= DEFAULTS then c.grow = "CENTRE" end
        for i, btn in ipairs(growButtons) do
            local opt = options[i]
            btn.value = opt[1]
            btn:SetText(opt[2])
            btn:SetEnabled(c.grow ~= opt[1])
        end
    end
    StripWidget(growFrame)

    local widthSlider = CreateSlider(stripBody, "Icon Width (px)", 12, 80, 1, Container().width,
        function(v) SetContainer("width", v) end)
    StripWidget(widthSlider)

    local heightSlider = CreateSlider(stripBody, "Icon Height (px)", 12, 80, 1, Container().height,
        function(v) SetContainer("height", v) end)
    StripWidget(heightSlider)
    StripDesc("Width and height are independent. The spell art is cropped to the shape rather than squashed.")

    local spacingSlider = CreateSlider(stripBody, "Spacing (px)", 0, 20, 1, Container().spacing,
        function(v) SetContainer("spacing", v) end)
    StripWidget(spacingSlider)

    local gapSlider = CreateSlider(stripBody, "Gap From Frame (px)", 0, 60, 1, Container().gap,
        function(v) SetContainer("gap", v) end)
    StripWidget(gapSlider)

    local perLineSlider = CreateSlider(stripBody, "Icons Per Row", 1, 24, 1, Container().perLine,
        function(v) SetContainer("perLine", v) end)
    StripWidget(perLineSlider)

    local orderCtl
    if ns.CreateEdgeOrderControl then
        orderCtl = ns.CreateEdgeOrderControl(stripBody,
            function() return Container().anchor end,
            function()
                local c = Container()
                if c.anchor ~= "TOP" and c.anchor ~= "BOTTOM" then return nil end
                return { kind = "strip", key = c.key }
            end,
            function()
                refreshAll()
                Apply()
            end)
        StripWidget(orderCtl)
        StripDesc("Left and right strips have this edge to themselves, so the list is only worth reading on the top and bottom.")
    end

    local holdCB = CreateCheckbox(stripBody, "Hold empty slots",
        "Keeps a hidden icon's place instead of closing the gap, so icons never move.",
        Container().mode == "fixed", function(v)
            WritableContainer().mode = v and "fixed" or "compact"
            Apply()
        end)
    StripWidget(holdCB)

    StripHeader("Visibility")
    StripDesc("How present the strip is, by situation. Zero hides it. Idle at 0 gives the same result as Redshift, so the strip can fade where the bars vanish instead.")

    local contextBoxes = {}
    local visRow = CreateFrame("Frame", nil, stripBody)
    visRow:SetSize(520, 26)
    local lastBox
    for _, entry in ipairs({
        { "alphaCombat", "In combat" }, { "alphaTarget", "Target" }, { "alphaIdle", "Idle" },
    }) do
        local field, text = entry[1], entry[2]
        local label = visRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        if lastBox then label:SetPoint("LEFT", lastBox, "RIGHT", 18, 0)
        else label:SetPoint("LEFT", 0, 0) end
        label:SetText(text)
        local box = CreatePercentBox(visRow,
            function() return Container()[field] or 0 end,
            function(v) SetContainer(field, v) end)
        box:SetPoint("LEFT", label, "RIGHT", 6, 0)
        contextBoxes[#contextBoxes + 1] = box
        lastBox = box
    end
    StripWidget(visRow)
    stripBody:SetHeight(sy + 20)

    -- Appearance: general settings, or one icon's overrides

    local lookTab = subFrames.look
    local lookPanel = StyleAsPanel(CreateFrame("Frame", nil, lookTab, "BackdropTemplate"))
    lookPanel:SetAllPoints()
    PanelTitle(lookPanel, "Appearance")

    local _, lookBody = CreateScrollableContent(lookPanel)
    local ly = 34

    local lookDesc = lookBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lookDesc:SetPoint("TOPLEFT", 12, -ly)
    lookDesc:SetWidth(500)
    lookDesc:SetJustifyH("LEFT")
    lookDesc:SetSpacing(2)
    lookDesc:SetText("Every icon on the strip. The cog on a row opens the same settings for that one icon.")
    ly = ly + lookDesc:GetStringHeight() + 14

    local gcdCB = CreateCheckbox(lookBody, "Ignore the global cooldown",
        "Without this every cast sweeps and greys every icon for the length of the GCD.",
        CONFIG.iconIgnoreGCD ~= false, function(v)
            CONFIG.iconIgnoreGCD = v
            Apply()
        end)
    gcdCB:SetPoint("TOPLEFT", lookBody, "TOPLEFT", 12, -ly)
    -- Measured, not assumed: this checkbox carries a description here and none in
    -- the modal, so a fixed advance put the tab rule through its second line.
    ly = ly + (gcdCB:GetHeight() or 36) + 14

    local glowCB = CreateCheckbox(lookBody, "Show proc glow", nil,
        CONFIG.iconGlow ~= false, function(v)
            CONFIG.iconGlow = v
            Apply()
        end,
        "Draws the game's own proc art around an icon when it lights up an ability. The Highlighted state below decides whether that icon shows at all, and how strongly.")
    glowCB:SetPoint("TOPLEFT", lookBody, "TOPLEFT", 12, -ly)
    ly = ly + (glowCB:GetHeight() or 36) + 14

    local ReloadGeneralStates
    ly, ReloadGeneralStates = BuildLookPages(lookBody, ly, function() return nil end, 500)
    lookBody:SetHeight(ly + 20)

    -- Refresh

    local function RefreshAllInner()
        local c = Container()

        enableCB:SetChecked(CONFIG.iconsEnabled or false)
        for _, def in ipairs(ANCHORS) do
            local value = def[1]
            local n = 0
            for _, e in ipairs(CONFIG.iconList or {}) do
                if (e.container or "TOP") == value then n = n + 1 end
            end
            sideButtons[value]:SetText(n > 0 and (def[2] .. " (" .. n .. ")") or def[2])
            sideButtons[value]:SetEnabled(side ~= value)
        end
        UpdateGrowButtons()
        widthSlider:SetValue(c.width)
        heightSlider:SetValue(c.height)
        spacingSlider:SetValue(c.spacing)
        gapSlider:SetValue(c.gap)
        perLineSlider:SetValue(c.perLine)
        holdCB:SetChecked(c.mode == "fixed")
        if orderCtl then orderCtl.Refresh() end
        for _, box in ipairs(contextBoxes) do box:Reload() end

        ReloadGeneralStates()
        gcdCB:SetChecked(CONFIG.iconIgnoreGCD ~= false)
        glowCB:SetChecked(CONFIG.iconGlow ~= false)

        for i, t in ipairs(poolTabs) do
            if i == activePool then PanelTemplates_SelectTab(t) else PanelTemplates_DeselectTab(t) end
        end
        poolHint:SetText(activePool == 1
            and "Click a cooldown to put it on the strip. Right click one already on it to remove it."
            or "Click a buff to pick it, then click a Buff slot on a row above. Right click a paired slot to clear it.")

        RefreshList()
        RefreshGrid()
        for _, m in pairs(modals) do
            if m:IsShown() then m.Reload() end
        end
    end

    refreshAll = function() Repopulate(RefreshAllInner) end

    SelectSub("icons")
    tab:SetScript("OnShow", refreshAll)
    tab:SetScript("OnHide", CloseAllModals)
    ns.RefreshIconsTab = refreshAll
end
