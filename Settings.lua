-- EventHorizon Infall: Settings UI

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG
local EH_Parent = ns.EH_Parent

InfallDB = InfallDB or {}
InfallDB.profiles = InfallDB.profiles or {}
InfallDB.namedProfiles = InfallDB.namedProfiles or {}

-- ============================================================================
-- PROFILE HELPERS
-- ============================================================================

local TOGGLE_KEYS = {
    "reactiveIcons", "desaturateOnCooldown", "redshift",
    "pandemicPulse", "locked", "hideBlizzCastBar",
    "hideEssentialCD", "hideUtilityCD", "hideBuffIconCD", "hideBuffBarCD",
    "buffLayerAbove", "hideIcons", "clickthrough",
    "showVariantNames", "smoothBars", "showPastBars",
    "forceViewersAlways", "stackIndicators",
    "showCooldownDuration", "estimateRuneCooldowns",
}

local DISPLAY_KEYS = {
    "width", "height", "spacing", "paddingTop", "paddingBottom",
    "paddingLeft", "paddingRight", "future", "past", "iconSize",
    "iconGap", "nowLineWidth", "gcdSparkWidth", "scale",
    "staticHeight", "staticFrames", "lines",
    "font", "fontSize", "fontFlags",
    "chargeTextAnchor", "chargeTextRelPoint", "chargeTextOffsetX", "chargeTextOffsetY",
    "stackTextAnchor", "stackTextRelPoint", "stackTextOffsetX", "stackTextOffsetY",
    "variantTextSize",
    "variantTextAnchor", "variantTextRelPoint", "variantTextOffsetX", "variantTextOffsetY",
    "cdTextMinDuration",
    "cdDurationTextSize",
    "cdDurationTextAnchor", "cdDurationTextRelPoint", "cdDurationTextOffsetX", "cdDurationTextOffsetY",
    "growDirection", "extrasHeight", "extrasPosition",
}

local COLOR_KEYS = {
    "cooldownColor", "castColor", "buffColor", "debuffColor", "petBuffColor",
    "bgcolor", "bordercolor", "nowLineColor", "gcdColor", "gcdSparkColor", "linesColor",
    "iconUsableColor", "iconNotEnoughManaColor", "iconNotUsableColor", "iconNotInRangeColor",
    "chargeTextColor", "stackTextColor",
    "variantTextColor",
    "cdDurationTextColor",
    "empowerStage1Color", "empowerStage2Color", "empowerStage3Color", "empowerStage4Color",
    "disintegrateChainColor",
}

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do
        copy[k] = DeepCopy(val)
    end
    return copy
end

local debouncedGen = 0
local function DebouncedApplyAndSave(extraFn)
    debouncedGen = debouncedGen + 1
    local myGen = debouncedGen
    C_Timer.After(0.1, function()
        if myGen == debouncedGen then
            if extraFn then extraFn() end
            if ns.ApplyLayoutToAllBars then ns.ApplyLayoutToAllBars() end
            if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        end
    end)
end


function ns.AutoPopulateSelfBuffMappings()
    if InCombatLockdown() then return end
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return end
    if not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end

    local cooldownIDs = {}
    local success, result = pcall(function()
        return C_CooldownViewer.GetCooldownViewerCategorySet(0, false)
    end)
    if success and result then cooldownIDs = result end

    CONFIG.buffMappings = CONFIG.buffMappings or {}
    local created = false

    for _, cooldownID in ipairs(cooldownIDs) do
        if CONFIG.buffMappings[cooldownID] == nil then
            local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
            if infoOk and cdInfo and cdInfo.hasAura then
                local mapping = { buffCooldownIDs = { cooldownID } }
                if cdInfo.spellID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(cdInfo.spellID) then
                    mapping.unit = "target"
                end
                CONFIG.buffMappings[cooldownID] = { mapping }
                created = true
            end
        else
            -- Patch existing self-mappings missing unit field
            local existing = CONFIG.buffMappings[cooldownID]
            if type(existing) == "table" then
                for _, mapData in ipairs(existing) do
                    if mapData.unit == nil and mapData.buffCooldownIDs then
                        for _, bcdID in ipairs(mapData.buffCooldownIDs) do
                            if bcdID == cooldownID then
                                local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                                if infoOk and cdInfo and cdInfo.spellID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(cdInfo.spellID) then
                                    mapData.unit = "target"
                                    created = true
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Cross-category buff pairing: match unmapped Category 0 abilities to
    -- Category 1/2/3 entries with the same spellID
    local buffCdBySpell = {}
    for _, cat in ipairs({2, 3, 1}) do
        local catOk, catIds = pcall(function()
            return C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
        end)
        if catOk and catIds then
            for _, bcdID in ipairs(catIds) do
                local bInfoOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, bcdID)
                if bInfoOk and bInfo and bInfo.spellID and not buffCdBySpell[bInfo.spellID] then
                    buffCdBySpell[bInfo.spellID] = bcdID
                end
            end
        end
    end
    for _, cooldownID in ipairs(cooldownIDs) do
        if CONFIG.buffMappings[cooldownID] == nil then
            local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
            if infoOk and cdInfo and cdInfo.spellID and buffCdBySpell[cdInfo.spellID] then
                local mapping = { buffCooldownIDs = { buffCdBySpell[cdInfo.spellID] } }
                if C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(cdInfo.spellID) then
                    mapping.unit = "target"
                end
                CONFIG.buffMappings[cooldownID] = { mapping }
                created = true
            end
        end
    end

    if created then
        ns.SaveCurrentProfile()
    end
end

function ns.GetSpecKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if not name or not realm then return nil end
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex)
    return name .. "-" .. realm .. "-" .. (specID or 0)
end

function ns.SeedProfileFromClassConfig(specKey)
    local profile = {
        toggles = {},
        display = {},
        colors = {},
        pairings = {},
        extraCasts = {},
        stackMappings = {},
        hiddenCooldownIDs = {},
        chargesDisabled = {},
        castColors = {},
        cooldownColors = {},
        stackIndicatorSettings = {},
        stackIndicatorList = {},
        customIcons = {},
    }

    for _, key in ipairs(TOGGLE_KEYS) do
        profile.toggles[key] = CONFIG[key]
    end
    for _, key in ipairs(DISPLAY_KEYS) do
        local val = CONFIG[key]
        profile.display[key] = val ~= nil and DeepCopy(val) or false
    end
    for _, key in ipairs(COLOR_KEYS) do
        profile.colors[key] = DeepCopy(CONFIG[key])
    end

    if CONFIG.buffMappings then
        profile.pairings = DeepCopy(CONFIG.buffMappings)
    end
    if CONFIG.extraCasts then
        profile.extraCasts = DeepCopy(CONFIG.extraCasts)
    end
    if CONFIG.stackMappings then
        profile.stackMappings = DeepCopy(CONFIG.stackMappings)
    end
    if CONFIG.hiddenCooldownIDs then
        profile.hiddenCooldownIDs = DeepCopy(CONFIG.hiddenCooldownIDs)
    end
    if CONFIG.chargesDisabled then
        profile.chargesDisabled = DeepCopy(CONFIG.chargesDisabled)
    end
    if CONFIG.castColors then
        profile.castColors = DeepCopy(CONFIG.castColors)
    end
    if CONFIG.cooldownColors then
        profile.cooldownColors = DeepCopy(CONFIG.cooldownColors)
    end
    if ns.classConfigDefaults and ns.classConfigDefaults.stackIndicatorSettings then
        profile.stackIndicatorSettings = DeepCopy(ns.classConfigDefaults.stackIndicatorSettings)
    end
    if ns.classConfigDefaults and ns.classConfigDefaults.stackIndicatorList and #ns.classConfigDefaults.stackIndicatorList > 0 then
        profile.stackIndicatorList = DeepCopy(ns.classConfigDefaults.stackIndicatorList)
    end
    if ns.classConfigDefaults and ns.classConfigDefaults.resourceBar then
        profile.resourceBar = DeepCopy(ns.classConfigDefaults.resourceBar)
    end
    if CONFIG.extras then
        profile.extras = DeepCopy(CONFIG.extras)
    end

    -- Capture current frame position (per-character)
    if EH_Parent then
        local point, _, relPoint, x, y = EH_Parent:GetPoint()
        if point then
            profile.position = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end

    InfallDB.profiles[specKey] = profile
    return profile
end

function ns.ApplyProfile(profile)
    if not profile then return end

    if profile.toggles then
        -- Migrate old hideBlizzECM in saved profiles
        if profile.toggles.hideBlizzECM ~= nil then
            local v = profile.toggles.hideBlizzECM and true or false
            for _, k in ipairs({"hideEssentialCD", "hideUtilityCD", "hideBuffIconCD", "hideBuffBarCD"}) do
                if profile.toggles[k] == nil then profile.toggles[k] = v end
            end
            profile.toggles.hideBlizzECM = nil
        end
        for _, key in ipairs(TOGGLE_KEYS) do
            if profile.toggles[key] ~= nil then
                CONFIG[key] = profile.toggles[key]
            end
        end
    end

    if profile.display then
        for _, key in ipairs(DISPLAY_KEYS) do
            if profile.display[key] ~= nil then
                local val = profile.display[key]
                CONFIG[key] = val == false and nil or DeepCopy(val)
            end
        end
    end

    if profile.colors then
        for _, key in ipairs(COLOR_KEYS) do
            if profile.colors[key] ~= nil then
                CONFIG[key] = DeepCopy(profile.colors[key])
            end
        end
    end

    CONFIG.buffMappings = profile.pairings and DeepCopy(profile.pairings) or {}

    -- Merge class config defaults for cooldownIDs the profile doesn't cover
    if ns.classConfigDefaults and ns.classConfigDefaults.pairings then
        for cdID, defaultMappings in pairs(ns.classConfigDefaults.pairings) do
            if not CONFIG.buffMappings[cdID] then
                CONFIG.buffMappings[cdID] = DeepCopy(defaultMappings)
            end
        end
    end

    -- Strip stale spellColorMaps from old profiles
    if CONFIG.buffMappings then
        for _, mappings in pairs(CONFIG.buffMappings) do
            for _, mapData in ipairs(mappings) do
                mapData.spellColorMap = nil
            end
        end
    end

    CONFIG.extraCasts = profile.extraCasts and DeepCopy(profile.extraCasts) or {}
    if ns.classConfigDefaults and ns.classConfigDefaults.extraCasts then
        for cdID, defaultCasts in pairs(ns.classConfigDefaults.extraCasts) do
            if not CONFIG.extraCasts[cdID] then
                CONFIG.extraCasts[cdID] = DeepCopy(defaultCasts)
            end
        end
    end
    CONFIG.stackMappings = profile.stackMappings and DeepCopy(profile.stackMappings) or {}
    if ns.classConfigDefaults and ns.classConfigDefaults.stackMappings then
        for cdID, defaultMapping in pairs(ns.classConfigDefaults.stackMappings) do
            if not CONFIG.stackMappings[cdID] then
                CONFIG.stackMappings[cdID] = DeepCopy(defaultMapping)
            end
        end
    end
    CONFIG.hiddenCooldownIDs = profile.hiddenCooldownIDs and DeepCopy(profile.hiddenCooldownIDs) or {}
    CONFIG.chargesDisabled = profile.chargesDisabled and DeepCopy(profile.chargesDisabled) or {}
    CONFIG.castColors = profile.castColors and DeepCopy(profile.castColors) or {}
    CONFIG.cooldownColors = profile.cooldownColors and DeepCopy(profile.cooldownColors) or {}
    CONFIG.stackIndicatorSettings = profile.stackIndicatorSettings and DeepCopy(profile.stackIndicatorSettings) or {}
    CONFIG.stackIndicatorList = profile.stackIndicatorList and DeepCopy(profile.stackIndicatorList) or {}
    CONFIG.resourceBar = profile.resourceBar and DeepCopy(profile.resourceBar) or {}
    CONFIG.extras = profile.extras and DeepCopy(profile.extras) or {}
    CONFIG.customIcons = profile.customIcons and DeepCopy(profile.customIcons) or {}

    -- Restore per-profile frame position
    if profile.position and EH_Parent then
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint(profile.position.point, UIParent, profile.position.relPoint, profile.position.x, profile.position.y)
    end

    if EH_Parent then
        EH_Parent:SetScale(CONFIG.scale or 1.0)
    end
    if ns.ApplyBackdrop then
        ns.ApplyBackdrop()
    end
    if ns.ApplyLayoutToAllBars then
        ns.ApplyLayoutToAllBars()
    end
    if ns.UpdateAllMinMax then
        ns.UpdateAllMinMax()
    end
    if ns.ApplyCastBarVisibility then
        ns.ApplyCastBarVisibility()
    end
    if ns.ApplyECMVisibility then
        ns.ApplyECMVisibility()
    end
    if ns.RebuildResourceBar then
        ns.RebuildResourceBar()
    end
    if ns.RebuildStackIndicators then
        ns.RebuildStackIndicators()
    end
    if ns.RefreshStacksTab then
        ns.RefreshStacksTab()
    end
    if ns.RefreshResourceTab then
        ns.RefreshResourceTab()
    end
    if ns.UpdateDurationTextSettings then
        ns.UpdateDurationTextSettings()
    end
end

function ns.SaveCurrentProfile()
    local specKey = ns.currentSpecKey
    if not specKey then return end

    local profile = InfallDB.profiles[specKey]
    if not profile then
        profile = ns.SeedProfileFromClassConfig(specKey)
    end

    for _, key in ipairs(TOGGLE_KEYS) do
        profile.toggles[key] = CONFIG[key]
    end
    for _, key in ipairs(DISPLAY_KEYS) do
        local val = CONFIG[key]
        profile.display[key] = val ~= nil and DeepCopy(val) or false
    end
    for _, key in ipairs(COLOR_KEYS) do
        profile.colors[key] = DeepCopy(CONFIG[key])
    end

    profile.pairings = DeepCopy(CONFIG.buffMappings or {})
    profile.extraCasts = DeepCopy(CONFIG.extraCasts or {})
    profile.stackMappings = DeepCopy(CONFIG.stackMappings or {})
    profile.hiddenCooldownIDs = DeepCopy(CONFIG.hiddenCooldownIDs or {})
    profile.chargesDisabled = DeepCopy(CONFIG.chargesDisabled or {})
    profile.castColors = DeepCopy(CONFIG.castColors or {})
    profile.cooldownColors = DeepCopy(CONFIG.cooldownColors or {})
    profile.stackIndicatorSettings = DeepCopy(CONFIG.stackIndicatorSettings or {})
    profile.stackIndicatorList = DeepCopy(CONFIG.stackIndicatorList or {})
    profile.resourceBar = DeepCopy(CONFIG.resourceBar or {})
    profile.extras = DeepCopy(CONFIG.extras or {})
    profile.customIcons = DeepCopy(CONFIG.customIcons or {})

    -- Save current frame position (per-character)
    if EH_Parent then
        local point, _, relPoint, x, y = EH_Parent:GetPoint()
        if point then
            profile.position = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end

    InfallDB.profiles[specKey] = profile
end

-- Snapshot defaults for Reset to Default
ns.classConfigDefaults = {
    toggles = {},
    display = {},
    colors = {},
    pairings = DeepCopy(CONFIG.buffMappings or {}),
    extraCasts = DeepCopy(CONFIG.extraCasts or {}),
    stackMappings = DeepCopy(CONFIG.stackMappings or {}),
    hiddenCooldownIDs = DeepCopy(CONFIG.hiddenCooldownIDs or {}),
    chargesDisabled = DeepCopy(CONFIG.chargesDisabled or {}),
    castColors = DeepCopy(CONFIG.castColors or {}),
    cooldownColors = DeepCopy(CONFIG.cooldownColors or {}),
    stackIndicatorSettings = DeepCopy(CONFIG.stackIndicatorSettings or {}),
    stackIndicatorList = DeepCopy(CONFIG.stackIndicatorList or {}),
    resourceBar = DeepCopy(CONFIG.resourceBar or {}),
    extras = DeepCopy(CONFIG.extras or {}),
    customIcons = DeepCopy(CONFIG.customIcons or {}),
}
for _, key in ipairs(TOGGLE_KEYS) do
    ns.classConfigDefaults.toggles[key] = CONFIG[key]
end
for _, key in ipairs(DISPLAY_KEYS) do
    local val = CONFIG[key]
    ns.classConfigDefaults.display[key] = val ~= nil and DeepCopy(val) or false
end
for _, key in ipairs(COLOR_KEYS) do
    ns.classConfigDefaults.colors[key] = DeepCopy(CONFIG[key])
end

-- ============================================================================
-- SETTINGS FRAME
-- ============================================================================

local settingsBuilt = false
local settingsFrame

-- Anchor point names for dropdowns
local ANCHOR_POINTS = {
    {text = "TOPLEFT", value = "TOPLEFT"},
    {text = "TOP", value = "TOP"},
    {text = "TOPRIGHT", value = "TOPRIGHT"},
    {text = "LEFT", value = "LEFT"},
    {text = "CENTER", value = "CENTER"},
    {text = "RIGHT", value = "RIGHT"},
    {text = "BOTTOMLEFT", value = "BOTTOMLEFT"},
    {text = "BOTTOM", value = "BOTTOM"},
    {text = "BOTTOMRIGHT", value = "BOTTOMRIGHT"},
}

local function GetFontOptions()
    local fonts = {
        {text = "Default (Friz Quadrata)", value = nil},
        {text = "Arial Narrow", value = "Fonts\\ARIALN.TTF"},
        {text = "Morpheus", value = "Fonts\\MORPHEUS.TTF"},
        {text = "Skurri", value = "Fonts\\SKURRI.TTF"},
    }

    -- Try LibSharedMedia-3.0
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local lsmFonts = LSM:List("font")
        if lsmFonts then
            for _, name in ipairs(lsmFonts) do
                local path = LSM:Fetch("font", name)
                if path then
                    -- Skip duplicates of builtins
                    local isDupe = false
                    for _, existing in ipairs(fonts) do
                        if existing.value == path then
                            isDupe = true
                            break
                        end
                    end
                    if not isDupe then
                        fonts[#fonts + 1] = {text = name, value = path}
                    end
                end
            end
        end
    end

    return fonts
end

local FONT_FLAG_OPTIONS = {
    {text = "OUTLINE", value = "OUTLINE"},
    {text = "THICKOUTLINE", value = "THICKOUTLINE"},
    {text = "MONOCHROME", value = "MONOCHROME"},
    {text = "OUTLINE, MONOCHROME", value = "OUTLINE, MONOCHROME"},
    {text = "None", value = ""},
}

-- ============================================================================
-- WIDGET FACTORY
-- ============================================================================

local function CreateSlider(parent, label, minVal, maxVal, step, default, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 50)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)

    local slider = CreateFrame("Slider", nil, container, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, -18)
    slider:SetSize(240, 17)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(default or minVal)

    local sName = slider:GetName()
    local low = slider.Low or (sName and _G[sName .. "Low"])
    local high = slider.High or (sName and _G[sName .. "High"])
    if low then low:SetText("") end
    if high then high:SetText("") end

    local fmtStr = step < 1 and "%.2f" or "%.0f"

    -- Editable value box
    local valueBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    valueBox:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    valueBox:SetSize(52, 18)
    valueBox:SetAutoFocus(false)
    valueBox:SetFontObject("GameFontHighlightSmall")
    valueBox:SetJustifyH("CENTER")
    valueBox:SetText(string.format(fmtStr, default or minVal))

    local currentVal = default or minVal

    valueBox:SetScript("OnEnterPressed", function(self)
        local num = tonumber(self:GetText())
        if num then
            num = math.max(minVal, num)
            num = math.floor(num / step + 0.5) * step
            currentVal = num
            slider:SetValue(math.min(num, maxVal))
            self:SetText(string.format(fmtStr, num))
            if onChange then onChange(num) end
        else
            self:SetText(string.format(fmtStr, currentVal))
        end
        self:ClearFocus()
    end)
    valueBox:SetScript("OnEscapePressed", function(self)
        self:SetText(string.format(fmtStr, currentVal))
        self:ClearFocus()
    end)

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        currentVal = value
        valueBox:SetText(string.format(fmtStr, value))
        if onChange then onChange(value) end
    end)

    container.slider = slider
    container.valueBox = valueBox

    function container:SetValue(v)
        currentVal = v
        slider:SetValue(math.min(v, maxVal))
        valueBox:SetText(string.format(fmtStr, v))
    end

    function container:GetValue()
        return slider:GetValue()
    end

    return container
end

local function CreateCheckbox(parent, label, description, default, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 36)

    local cb = CreateFrame("CheckButton", nil, container, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 0, 0)
    cb:SetSize(26, 26)
    cb:SetChecked(default or false)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    title:SetText(label)

    if description then
        local desc = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 28, -2)
        desc:SetJustifyH("LEFT")
        desc:SetWidth(500)
        desc:SetSpacing(2)
        desc:SetText(description)
        container:SetHeight(36 + desc:GetStringHeight())
    end

    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if onChange then onChange(checked) end
    end)

    container.checkbox = cb

    function container:SetChecked(v)
        cb:SetChecked(v)
    end

    function container:GetChecked()
        return cb:GetChecked()
    end

    return container
end

local function CreateColorSwatch(parent, label, defaultColor, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 26)

    local swatch = CreateFrame("Button", nil, container)
    swatch:SetSize(20, 20)
    swatch:SetPoint("TOPLEFT", 0, -3)

    local swatchBg = swatch:CreateTexture(nil, "BACKGROUND")
    swatchBg:SetAllPoints()
    swatchBg:SetColorTexture(0, 0, 0, 1)

    local swatchTex = swatch:CreateTexture(nil, "OVERLAY")
    swatchTex:SetPoint("TOPLEFT", 1, -1)
    swatchTex:SetPoint("BOTTOMRIGHT", -1, 1)
    local c = defaultColor or {1, 1, 1, 1}
    swatchTex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
    title:SetText(label)

    swatch:SetScript("OnClick", function()
        local prevR, prevG, prevB, prevA = c[1], c[2], c[3], c[4] or 1

        local function SetColor(r, g, b)
            c[1], c[2], c[3] = r, g, b
            swatchTex:SetColorTexture(r, g, b, c[4] or 1)
            if onChange then onChange({r, g, b, c[4] or 1}) end
        end

        local function SetOpacity(opacity)
            c[4] = opacity
            swatchTex:SetColorTexture(c[1], c[2], c[3], c[4])
            if onChange then onChange({c[1], c[2], c[3], c[4]}) end
        end

        local function CancelFunc()
            c[1], c[2], c[3], c[4] = prevR, prevG, prevB, prevA
            swatchTex:SetColorTexture(prevR, prevG, prevB, prevA)
            if onChange then onChange({prevR, prevG, prevB, prevA}) end
        end

        ColorPickerFrame:Hide()

        local info = {
            r = c[1],
            g = c[2],
            b = c[3],
            opacity = c[4] or 1,
            hasOpacity = true,
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                SetColor(r, g, b)
            end,
            opacityFunc = function()
                local opacity = ColorPickerFrame:GetColorAlpha()
                SetOpacity(opacity)
            end,
            cancelFunc = CancelFunc,
        }

        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    container.swatch = swatch
    container.swatchTex = swatchTex
    container.currentColor = c

    function container:SetColor(newColor)
        c = newColor
        container.currentColor = c
        swatchTex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    end

    return container
end

local function CreateDropdown(parent, label, options, default, onChange, forceScroll, searchable)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 44)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)

    local button = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", 0, -16)
    button:SetSize(200, 24)

    local displayText = "Select..."
    for _, opt in ipairs(options) do
        if opt.value == default then
            displayText = opt.text
            break
        end
    end
    button:SetText(displayText)
    button.selectedValue = default

    local menuFrame = CreateFrame("Frame", nil, button, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
    menuFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    menuFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    menuFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:Hide()

    local maxVisible = 15
    local needsScroll = forceScroll or searchable or (#options > maxVisible)
    local searchHeight = searchable and 24 or 0
    local totalContentHeight = #options * 20
    local visibleItems = needsScroll and math.min(maxVisible, #options) or #options
    local menuHeight = visibleItems * 20 + 4 + searchHeight
    local menuWidth = needsScroll and 220 or 200
    local btnWidth = 196

    local searchBox, scrollFrame, scrollChild
    local optButtons = {}

    local contentParent
    if needsScroll then
        if searchable then
            searchBox = CreateFrame("EditBox", nil, menuFrame, "InputBoxTemplate")
            searchBox:SetSize(menuWidth - 28, 18)
            searchBox:SetPoint("TOPLEFT", 6, -4)
            searchBox:SetAutoFocus(false)
            searchBox:SetFontObject("GameFontHighlightSmall")
        end

        scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 2, -(2 + searchHeight))
        scrollFrame:SetPoint("BOTTOMRIGHT", -22, 2)

        scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetWidth(btnWidth)
        scrollChild:SetHeight(totalContentHeight)
        scrollFrame:SetScrollChild(scrollChild)
        contentParent = scrollChild

        menuFrame:EnableMouseWheel(true)
        menuFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = scrollFrame:GetVerticalScroll()
            local maxScroll = math.max(0, scrollChild:GetHeight() - (menuHeight - 4 - searchHeight))
            local newScroll = current - (delta * 40)
            newScroll = math.max(0, math.min(maxScroll, newScroll))
            scrollFrame:SetVerticalScroll(newScroll)
        end)
    else
        contentParent = menuFrame
    end

    for i, opt in ipairs(options) do
        local optBtn = CreateFrame("Button", nil, contentParent)
        optBtn:SetSize(btnWidth, 20)
        if needsScroll then
            optBtn:SetPoint("TOPLEFT", 0, -((i - 1) * 20))
        else
            optBtn:SetPoint("TOPLEFT", 2, -(2 + (i - 1) * 20))
        end
        optBtn:SetNormalFontObject("GameFontHighlightSmall")
        optBtn:SetHighlightFontObject("GameFontNormalSmall")
        optBtn:SetText(opt.text)
        optBtn:GetFontString():SetJustifyH("LEFT")
        optBtn:GetFontString():SetPoint("LEFT", 4, 0)

        local highlight = optBtn:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(0.3, 0.3, 0.5, 0.4)

        optBtn:SetScript("OnClick", function()
            button:SetText(opt.text)
            button.selectedValue = opt.value
            menuFrame:Hide()
            if onChange then onChange(opt.value) end
        end)

        optBtn._optText = opt.text
        optButtons[i] = optBtn
    end
    menuFrame:SetSize(menuWidth, menuHeight)

    if searchBox then
        local function FilterOptions()
            local query = (searchBox:GetText() or ""):lower()
            local yPos = 0
            for _, btn in ipairs(optButtons) do
                if query == "" or btn._optText:lower():find(query, 1, true) then
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", 0, -yPos)
                    btn:Show()
                    yPos = yPos + 20
                else
                    btn:Hide()
                end
            end
            scrollChild:SetHeight(math.max(yPos, 1))
            if scrollFrame then scrollFrame:SetVerticalScroll(0) end
        end
        searchBox:SetScript("OnTextChanged", FilterOptions)
        searchBox:SetScript("OnEscapePressed", function() searchBox:ClearFocus() end)
    end

    button:SetScript("OnClick", function()
        if menuFrame:IsShown() then
            menuFrame:Hide()
        else
            menuFrame:Show()
            if searchBox then
                searchBox:SetText("")
                searchBox:SetFocus()
            end
        end
    end)

    menuFrame:SetScript("OnShow", function()
        menuFrame:SetScript("OnUpdate", function()
            if not menuFrame:IsMouseOver() and not button:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") then
                    menuFrame:Hide()
                end
            end
        end)
    end)
    menuFrame:SetScript("OnHide", function()
        menuFrame:SetScript("OnUpdate", nil)
        if searchBox then searchBox:SetText("") end
    end)

    container.button = button
    container.menuFrame = menuFrame

    function container:SetValue(v)
        button.selectedValue = v
        local found = false
        for _, opt in ipairs(options) do
            if opt.value == v then
                button:SetText(opt.text)
                found = true
                break
            end
        end
        if not found then
            button:SetText("Select...")
        end
    end

    function container:GetValue()
        return button.selectedValue
    end

    return container
end

local function CreateEditBox(parent, label, default, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 44)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)

    local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    editBox:SetPoint("TOPLEFT", 0, -16)
    editBox:SetSize(200, 22)
    editBox:SetAutoFocus(false)
    editBox:SetText(default or "")
    editBox:SetFontObject("ChatFontNormal")

    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onChange then onChange(self:GetText()) end
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    container.editBox = editBox

    function container:SetText(t)
        editBox:SetText(t or "")
    end

    function container:GetText()
        return editBox:GetText()
    end

    return container
end

local function CreateSectionHeader(parent, text)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0, 1)
    return header
end

-- ============================================================================
-- TAB SYSTEM
-- ============================================================================

local TAB_NAMES = {"Bars", "Display", "Colours", "Toggles", "Stacks", "Resource", "Profiles"}
local tabFrames = {}
local tabButtons = {}
local currentTab = 1
local function SelectTab(index)
    currentTab = index
    GameTooltip:Hide()
    for i, frame in ipairs(tabFrames) do
        if frame then frame:Hide() end
        if tabButtons[i] then
            PanelTemplates_DeselectTab(tabButtons[i])
        end
    end
    if tabButtons[index] then
        PanelTemplates_SelectTab(tabButtons[index])
    end
    if tabFrames[index] then
        tabFrames[index]:Show()
    end
end

-- ============================================================================
-- SCROLL FRAME HELPER
-- ============================================================================

local function CreateScrollableContent(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(scrollFrame:GetWidth(), 1)
    scrollFrame:SetScrollChild(content)

    scrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        content:SetWidth(w)
    end)

    return scrollFrame, content
end

-- ============================================================================
-- INLINE COLOUR PICKER (for per-slot buff colours)
-- ============================================================================

local function OpenInlineColorPicker(currentColor, onChange)
    local prevR, prevG, prevB, prevA = currentColor[1], currentColor[2], currentColor[3], currentColor[4] or 1

    ColorPickerFrame:Hide()
    local info = {
        r = currentColor[1],
        g = currentColor[2],
        b = currentColor[3],
        opacity = currentColor[4] or 1,
        hasOpacity = true,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            currentColor[1], currentColor[2], currentColor[3] = r, g, b
            if onChange then onChange(currentColor) end
        end,
        opacityFunc = function()
            local opacity = ColorPickerFrame:GetColorAlpha()
            currentColor[4] = opacity
            if onChange then onChange(currentColor) end
        end,
        cancelFunc = function()
            currentColor[1], currentColor[2], currentColor[3], currentColor[4] = prevR, prevG, prevB, prevA
            if onChange then onChange(currentColor) end
        end,
    }
    ColorPickerFrame:SetupColorPickerAndShow(info)
end

-- ============================================================================
-- SHARED SPELL PICKER
-- Opens a searchable popup listing the player's learned spells (including
-- passives). Used by the Stacks tab and the custom icon override in Bars tab.
-- ============================================================================

local spellPickerFrame
local spellPickerCache
local spellPickerCacheDirty = true
local spellPickerCurrentOpts

-- Common consumables / class buffs not always in the player's spellbook.
-- Used so name search in the picker can find things like Healthstone, Phial of Tepid Versatility, etc.
local PICKER_COMMON_SPELLS = {
    6262,    -- Healthstone
    433889,  -- Algari Healing Potion
    432021,  -- Cavedweller's Delight (Algari mana)
    432128,  -- Tempered Potion (primary stat)
    431932,  -- Slumbering Soul Serum
    432011,  -- Draught of Silent Footfalls
    431893,  -- Phial of Tepid Versatility
    431914,  -- Phial of Glacial Fury
    431932,  -- Phial of Truesight
    431945,  -- Phial of Charged Isolation
    431971,  -- Phial of Tempered Aggression
    432013,  -- Phial of Tepid Versatility
    228600,  -- Bloodlust
    32182,   -- Heroism
    80353,   -- Time Warp
    264667,  -- Primal Rage
    390386,  -- Fury of the Aspects
    23989,   -- Readiness (Hunter racial-like)
    1044,    -- Blessing of Freedom (Paladin)
    6940,    -- Blessing of Sacrifice
    1022,    -- Blessing of Protection
    633,     -- Lay on Hands
    97462,   -- Rallying Cry (Warrior)
    871,     -- Shield Wall
    98008,   -- Spirit Link Totem (Shaman)
    108271,  -- Astral Shift
    207399,  -- Ancestral Protection Totem
    47788,   -- Guardian Spirit
    33206,   -- Pain Suppression
    62618,   -- Power Word: Barrier
    102342,  -- Ironbark (Druid)
    740,     -- Tranquility
    115310,  -- Revival (Monk)
    115203,  -- Fortifying Brew (Monk)
    122470,  -- Touch of Karma
    642,     -- Divine Shield
    498,     -- Divine Protection
    31224,   -- Cloak of Shadows
    1856,    -- Vanish
    5277,    -- Evasion
    104773,  -- Unending Resolve (Warlock)
    108416,  -- Dark Pact
    186265,  -- Aspect of the Turtle (Hunter)
    19263,   -- Deterrence/Disengage related
    198589,  -- Blur (Demon Hunter)
    196555,  -- Netherwalk
    187827,  -- Metamorphosis (DH tank)
    55233,   -- Vampiric Blood (Death Knight)
    48707,   -- Anti-Magic Shell
    48792,   -- Icebound Fortitude
    49028,   -- Dancing Rune Weapon
    363916,  -- Obsidian Scales (Evoker)
    374348,  -- Renewing Blaze
    370960,  -- Emerald Communion
    45438,   -- Ice Block (Mage)
    113862,  -- Greater Invisibility
    342245,  -- Alter Time (newer)
    342246,  -- Alter Time return
    198111,  -- Temporal Shield
}

local function BuildSpellPickerCache()
    local list = {}
    local seen = {}

    local function addEntry(spellID, name, icon, tab)
        if not spellID or seen[spellID] then return end
        name = name or C_Spell.GetSpellName(spellID)
        if not name or name == "" then return end
        icon = icon or C_Spell.GetSpellTexture(spellID) or 134400
        seen[spellID] = true
        list[#list + 1] = {
            spellID = spellID,
            name = name,
            nameLower = name:lower(),
            icon = icon,
            tab = tab,
        }
    end

    local getTabs = C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines
    local getLine = C_SpellBook and C_SpellBook.GetSpellBookSkillLineInfo
    local getItem = C_SpellBook and C_SpellBook.GetSpellBookItemInfo
    if getTabs and getLine and getItem then
        local playerBank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
        local numTabs = getTabs() or 0
        for t = 1, numTabs do
            local info = getLine(t)
            if info and not info.shouldHide then
                local offset = info.itemIndexOffset or 0
                local count = info.numSpellBookItems or 0
                for i = 1, count do
                    local idx = offset + i
                    local ok, data = pcall(getItem, idx, playerBank)
                    if ok and data and data.spellID then
                        local typeOk = (spellType == nil) or (data.itemType == spellType)
                        if typeOk then
                            addEntry(data.spellID, data.name, data.iconID, info.name)
                        end
                    end
                end
            end
        end
    end

    -- CDM cooldownIDs across all categories: surfaces class abilities the player does not have learned
    -- (so the user can pick icons for cross class buffs they want to track).
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        for category = 0, 3 do
            local catOk, catIDs = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, true)
            if catOk and catIDs then
                for _, cdID in ipairs(catIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if infoOk and info then
                        local sID = info.overrideTooltipSpellID or info.overrideSpellID or info.spellID
                        if sID then addEntry(sID, nil, nil, "CDM") end
                    end
                end
            end
        end
    end

    -- Common consumables and cross class buffs by spellID
    for _, sID in ipairs(PICKER_COMMON_SPELLS) do
        addEntry(sID, nil, nil, "Common")
    end

    table.sort(list, function(a, b) return a.nameLower < b.nameLower end)
    spellPickerCache = list
    spellPickerCacheDirty = false
    return list
end

local spellPickerInvalidator
local function EnsureSpellPickerInvalidator()
    if spellPickerInvalidator then return end
    spellPickerInvalidator = CreateFrame("Frame")
    spellPickerInvalidator:RegisterEvent("SPELLS_CHANGED")
    spellPickerInvalidator:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
    spellPickerInvalidator:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    spellPickerInvalidator:SetScript("OnEvent", function()
        spellPickerCacheDirty = true
    end)
end

local function BuildSpellPickerFrame()
    if spellPickerFrame then return spellPickerFrame end

    local f = CreateFrame("Frame", "InfallSpellPicker", UIParent, "BackdropTemplate")
    f:SetSize(300, 380)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    f:SetBackdropColor(0.08, 0.08, 0.08, 0.96)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetTextColor(1, 0.82, 0, 1)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButtonNoScripts")
    closeBtn:SetPoint("TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    searchBox:SetSize(270, 20)
    searchBox:SetPoint("TOPLEFT", 14, -30)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("ChatFontNormal")
    searchBox:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then
            self:SetText("")
        else
            f:Hide()
        end
    end)
    f.searchBox = searchBox

    local searchHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
    searchHint:SetText("Type a spell name...")
    f.searchHint = searchHint

    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 30)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(260, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild

    local emptyText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOP", 0, -20)
    emptyText:SetWidth(240)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetText("No matches. Try part of the spell name.")
    emptyText:Hide()
    f.emptyText = emptyText

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 12, 10)
    footer:SetPoint("BOTTOMRIGHT", -12, 10)
    footer:SetJustifyH("LEFT")
    f.footer = footer

    f.rowCache = {}
    f.rowCacheCount = 0

    local function Refresh()
        local query = (searchBox:GetText() or ""):lower()
        if query == "" then
            searchHint:Show()
        else
            searchHint:Hide()
        end

        if spellPickerCacheDirty or not spellPickerCache then
            BuildSpellPickerCache()
        end

        local results = {}
        local opts = spellPickerCurrentOpts
        local extras = opts and opts.extraSources
        if extras then
            for _, e in ipairs(extras) do
                if query == "" or (e.nameLower or (e.name or ""):lower()):find(query, 1, true) then
                    results[#results + 1] = e
                end
            end
        end

        local seenIDs = {}
        for _, e in ipairs(results) do
            if e.spellID then seenIDs[e.spellID] = true end
        end

        -- If the search box is a number, surface "Use spell ID N" as the top result
        -- so the user can pick icons for spells outside their spellbook.
        local typedID = tonumber(query)
        if typedID and typedID > 0 and not seenIDs[typedID] then
            local nameOk, nameVal = pcall(C_Spell.GetSpellName, typedID)
            local texOk, texVal = pcall(C_Spell.GetSpellTexture, typedID)
            local resolvedName = (nameOk and nameVal) or ("Spell " .. typedID)
            local resolvedIcon = (texOk and texVal) or 134400
            table.insert(results, 1, {
                spellID = typedID,
                name = resolvedName,
                nameLower = resolvedName:lower(),
                icon = resolvedIcon,
                tag = "Use spell ID " .. typedID,
            })
            seenIDs[typedID] = true
        end

        for _, e in ipairs(spellPickerCache) do
            if not seenIDs[e.spellID] and (query == "" or e.nameLower:find(query, 1, true)) then
                results[#results + 1] = e
                seenIDs[e.spellID] = true
                if #results >= 200 then break end
            end
        end

        for i = 1, f.rowCacheCount do
            if f.rowCache[i] then f.rowCache[i]:Hide() end
        end

        local rowH = 24
        local y = 0
        for i, entry in ipairs(results) do
            local row = f.rowCache[i]
            if not row then
                row = CreateFrame("Button", nil, scrollChild)
                row:SetSize(260, rowH)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(18, 18)
                row.icon:SetPoint("LEFT", 4, 0)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.name:SetPoint("RIGHT", -52, 0)
                row.name:SetJustifyH("LEFT")
                row.id = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                row.id:SetPoint("RIGHT", -6, 0)
                row.id:SetJustifyH("RIGHT")
                local hl = row:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(0.3, 0.3, 0.5, 0.4)
                row:SetScript("OnEnter", function(self)
                    if self._tagText then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(self._tagText, 0.7, 0.7, 0.7)
                        GameTooltip:Show()
                    end
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                f.rowCache[i] = row
                f.rowCacheCount = math.max(f.rowCacheCount, i)
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row.icon:SetTexture(entry.icon or 134400)
            row.name:SetText(entry.name)
            row.id:SetText(tostring(entry.spellID or ""))
            row._tagText = entry.tag or entry.tab
            row._spellID = entry.spellID
            row._entry = entry
            row:SetScript("OnClick", function(self)
                if spellPickerCurrentOpts and spellPickerCurrentOpts.onSelect then
                    spellPickerCurrentOpts.onSelect(self._entry.spellID, self._entry.name, self._entry.icon, self._entry)
                end
                f:Hide()
            end)
            row:Show()
            y = y + rowH
        end

        scrollChild:SetHeight(math.max(y, 1))
        scrollFrame:SetVerticalScroll(0)

        if #results == 0 then
            emptyText:Show()
        else
            emptyText:Hide()
        end

        footer:SetText(#results .. " spell" .. (#results == 1 and "" or "s"))
    end
    f.Refresh = Refresh

    searchBox:SetScript("OnTextChanged", Refresh)

    f:SetScript("OnHide", function()
        spellPickerCurrentOpts = nil
        searchBox:SetText("")
    end)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then self:Hide() end
    end)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(false)

    spellPickerFrame = f
    return f
end

local function OpenSpellPicker(opts)
    EnsureSpellPickerInvalidator()
    local f = BuildSpellPickerFrame()
    spellPickerCurrentOpts = opts or {}
    f.title:SetText(opts and opts.title or "Pick a Spell")

    if opts and opts.anchor then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", opts.anchor, "TOPRIGHT", 6, 0)
    else
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    f.searchBox:SetText("")
    f:Show()
    f:Raise()
    f.searchBox:SetFocus()
    f.Refresh()
end

ns.OpenSpellPicker = OpenSpellPicker

-- ============================================================================
-- TAB BUILDERS
-- ============================================================================

local function BuildColoursTab(contentArea, tabFrames)
    local coloursTab = CreateFrame("Frame", nil, contentArea)
    coloursTab:SetAllPoints()
    coloursTab:Hide()
    tabFrames[3] = coloursTab

    local colourScroll, colourContent = CreateScrollableContent(coloursTab)

    local colourY = 0
    local function AddColourWidget(widget)
        widget:SetPoint("TOPLEFT", colourContent, "TOPLEFT", 10, -colourY)
        colourY = colourY + widget:GetHeight() + 6
    end

    local function AddColourHeader(text)
        colourY = colourY + 10
        local h = CreateSectionHeader(colourContent, text)
        h:SetPoint("TOPLEFT", colourContent, "TOPLEFT", 10, -colourY)
        colourY = colourY + 22
    end

    local function AddColourDescription(text)
        local desc = colourContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        desc:SetPoint("TOPLEFT", colourContent, "TOPLEFT", 10, -colourY)
        desc:SetWidth(500)
        desc:SetJustifyH("LEFT")
        desc:SetSpacing(2)
        desc:SetText(text)
        colourY = colourY + desc:GetStringHeight() + 6
    end

    local LoadEssentialCooldowns = ns.LoadEssentialCooldowns

    -- Bar Colours
    AddColourHeader("Bar Colours")
    AddColourDescription("Default colours for bar types. Per-cooldown and per-slot colours set in the Bars tab take priority over these.")

    local cdColourSwatch = CreateColorSwatch(colourContent, "Cooldown", DeepCopy(CONFIG.cooldownColor), function(c)
        CONFIG.cooldownColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(cdColourSwatch)

    local castColourSwatch = CreateColorSwatch(colourContent, "Cast", DeepCopy(CONFIG.castColor), function(c)
        CONFIG.castColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(castColourSwatch)

    local buffColourSwatch = CreateColorSwatch(colourContent, "Buff", DeepCopy(CONFIG.buffColor), function(c)
        CONFIG.buffColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(buffColourSwatch)

    local debuffColourSwatch = CreateColorSwatch(colourContent, "Debuff", DeepCopy(CONFIG.debuffColor), function(c)
        CONFIG.debuffColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(debuffColourSwatch)

    local petBuffColourSwatch = CreateColorSwatch(colourContent, "Pet Buff", DeepCopy(CONFIG.petBuffColor), function(c)
        CONFIG.petBuffColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(petBuffColourSwatch)

    -- Frame Colours
    AddColourHeader("Frame Colours")
    AddColourDescription("Background and border of the main Infall frame. These affect the container around all bars.")

    local bgColourSwatch = CreateColorSwatch(colourContent, "Background", DeepCopy(CONFIG.bgcolor), function(c)
        CONFIG.bgcolor = c
        DebouncedApplyAndSave(function() if ns.ApplyBackdrop then ns.ApplyBackdrop() end end)
    end)
    AddColourWidget(bgColourSwatch)

    local borderColourSwatch = CreateColorSwatch(colourContent, "Border", DeepCopy(CONFIG.bordercolor), function(c)
        CONFIG.bordercolor = c
        DebouncedApplyAndSave(function() if ns.ApplyBackdrop then ns.ApplyBackdrop() end end)
    end)
    AddColourWidget(borderColourSwatch)

    -- Now Line / GCD
    AddColourHeader("Now Line / GCD")
    AddColourDescription("Colours for the now line, GCD bar and spark, and time reference lines.")

    local nowLineColourSwatch = CreateColorSwatch(colourContent, "Now Line", DeepCopy(CONFIG.nowLineColor), function(c)
        CONFIG.nowLineColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(nowLineColourSwatch)

    local gcdColourSwatch = CreateColorSwatch(colourContent, "GCD Bar", DeepCopy(CONFIG.gcdColor), function(c)
        CONFIG.gcdColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(gcdColourSwatch)

    local gcdSparkColourSwatch = CreateColorSwatch(colourContent, "GCD Spark", DeepCopy(CONFIG.gcdSparkColor), function(c)
        CONFIG.gcdSparkColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(gcdSparkColourSwatch)

    local linesColourSwatch = CreateColorSwatch(colourContent, "Time Lines", DeepCopy(CONFIG.linesColor), function(c)
        CONFIG.linesColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(linesColourSwatch)

    -- Icon State Colours
    AddColourHeader("Icon State Colours")
    AddColourDescription("Tint applied to ability icons based on usability. Only visible when Reactive Icons is enabled in the Toggles tab.")

    local iconUsableColourSwatch = CreateColorSwatch(colourContent, "Usable", DeepCopy(CONFIG.iconUsableColor), function(c)
        CONFIG.iconUsableColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(iconUsableColourSwatch)

    local iconManaColourSwatch = CreateColorSwatch(colourContent, "Not Enough Mana", DeepCopy(CONFIG.iconNotEnoughManaColor), function(c)
        CONFIG.iconNotEnoughManaColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(iconManaColourSwatch)

    local iconNotUsableColourSwatch = CreateColorSwatch(colourContent, "Not Usable", DeepCopy(CONFIG.iconNotUsableColor), function(c)
        CONFIG.iconNotUsableColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(iconNotUsableColourSwatch)

    local iconRangeColourSwatch = CreateColorSwatch(colourContent, "Out of Range", DeepCopy(CONFIG.iconNotInRangeColor), function(c)
        CONFIG.iconNotInRangeColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(iconRangeColourSwatch)

    -- Empowered Stage Colours
    AddColourHeader("Empowered Stage Colours")
    AddColourDescription("Colours for each empowered cast stage (IE Evoker abilities). Stages progress left to right as you hold the cast.")

    local empowerStage1Swatch = CreateColorSwatch(colourContent, "Stage 1", DeepCopy(CONFIG.empowerStage1Color), function(c)
        CONFIG.empowerStage1Color = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(empowerStage1Swatch)

    local empowerStage2Swatch = CreateColorSwatch(colourContent, "Stage 2", DeepCopy(CONFIG.empowerStage2Color), function(c)
        CONFIG.empowerStage2Color = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(empowerStage2Swatch)

    local empowerStage3Swatch = CreateColorSwatch(colourContent, "Stage 3", DeepCopy(CONFIG.empowerStage3Color), function(c)
        CONFIG.empowerStage3Color = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(empowerStage3Swatch)

    local empowerStage4Swatch = CreateColorSwatch(colourContent, "Stage 4", DeepCopy(CONFIG.empowerStage4Color), function(c)
        CONFIG.empowerStage4Color = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(empowerStage4Swatch)

    -- Channel Colours
    AddColourHeader("Channel Colours")
    AddColourDescription("Colour for the chain window at the tail of a Disintegrate channel, showing when it's safe to clip and recast.")

    local disintChainSwatch = CreateColorSwatch(colourContent, "Disintegrate Chain Window", DeepCopy(CONFIG.disintegrateChainColor), function(c)
        CONFIG.disintegrateChainColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(disintChainSwatch)

    -- Text Colours
    AddColourHeader("Text Colours")
    AddColourDescription("Default colours for charge and stack text on bars. Per-slot colours set in the Bars tab take priority over these.")

    local chargeTextColourSwatch = CreateColorSwatch(colourContent, "Charge Text", DeepCopy(CONFIG.chargeTextColor), function(c)
        CONFIG.chargeTextColor = c
        DebouncedApplyAndSave(function() LoadEssentialCooldowns() end)
    end)
    AddColourWidget(chargeTextColourSwatch)

    local stackTextColourSwatch = CreateColorSwatch(colourContent, "Stack Text", DeepCopy(CONFIG.stackTextColor), function(c)
        CONFIG.stackTextColor = c
        DebouncedApplyAndSave(function() LoadEssentialCooldowns() end)
    end)
    AddColourWidget(stackTextColourSwatch)

    -- Font Settings
    AddColourHeader("Font Settings")
    AddColourDescription("Font used for charge counts and stack text on bars. Size and flags control readability. To add custom fonts, install LibSharedMedia-3.0 and a SharedMedia font pack (IE SharedMedia_MyMedia). Fonts from those packs will appear in the dropdown automatically.")

    local fontOptions = GetFontOptions()
    local fontDropdown = CreateDropdown(colourContent, "Font", fontOptions, CONFIG.font, function(v)
        CONFIG.font = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end, true, true)
    AddColourWidget(fontDropdown)

    local fontSizeSlider = CreateSlider(colourContent, "Font Size", 8, 24, 1, CONFIG.fontSize, function(v)
        CONFIG.fontSize = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(fontSizeSlider)

    local fontFlagsDropdown = CreateDropdown(colourContent, "Font Flags", FONT_FLAG_OPTIONS, CONFIG.fontFlags, function(v)
        CONFIG.fontFlags = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(fontFlagsDropdown)

    -- Text Anchors
    AddColourHeader("Charge Text Anchor")
    AddColourDescription("Where charge count text is positioned on each bar. Offset sliders fine-tune placement from the anchor point.")

    local chargeAnchorDropdown = CreateDropdown(colourContent, "Anchor Point", ANCHOR_POINTS, CONFIG.chargeTextAnchor, function(v)
        CONFIG.chargeTextAnchor = v
        CONFIG.chargeTextRelPoint = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeAnchorDropdown)

    local chargeOffXSlider = CreateSlider(colourContent, "Charge Offset X", -20, 20, 1, CONFIG.chargeTextOffsetX, function(v)
        CONFIG.chargeTextOffsetX = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeOffXSlider)

    local chargeOffYSlider = CreateSlider(colourContent, "Charge Offset Y", -20, 20, 1, CONFIG.chargeTextOffsetY, function(v)
        CONFIG.chargeTextOffsetY = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeOffYSlider)

    AddColourHeader("Stack Text Anchor")
    AddColourDescription("Where stack count text is positioned on each bar. Works the same way as charge text anchoring.")

    local stackAnchorDropdown = CreateDropdown(colourContent, "Anchor Point", ANCHOR_POINTS, CONFIG.stackTextAnchor, function(v)
        CONFIG.stackTextAnchor = v
        CONFIG.stackTextRelPoint = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(stackAnchorDropdown)

    local stackOffXSlider = CreateSlider(colourContent, "Stack Offset X", -20, 20, 1, CONFIG.stackTextOffsetX, function(v)
        CONFIG.stackTextOffsetX = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(stackOffXSlider)

    local stackOffYSlider = CreateSlider(colourContent, "Stack Offset Y", -20, 20, 1, CONFIG.stackTextOffsetY, function(v)
        CONFIG.stackTextOffsetY = v
        LoadEssentialCooldowns()
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(stackOffYSlider)

    -- Variant Name Text
    AddColourHeader("Variant Name Text")
    AddColourDescription("Colour, size, and position of variant name text on bars (IE Roll the Bones outcome names). Enable this feature in the Toggles tab. Adjusting these settings shows a preview on your bars.")

    local variantTextColourSwatch = CreateColorSwatch(colourContent, "Variant Name Colour", DeepCopy(CONFIG.variantTextColor), function(c)
        CONFIG.variantTextColor = c
        if ns.ShowVariantPreview then ns.ShowVariantPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(variantTextColourSwatch)

    local variantTextSizeSlider = CreateSlider(colourContent, "Variant Name Size", 6, 24, 1, CONFIG.variantTextSize, function(v)
        CONFIG.variantTextSize = v
        if ns.ShowVariantPreview then ns.ShowVariantPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(variantTextSizeSlider)

    local variantAnchorDropdown = CreateDropdown(colourContent, "Anchor Point", ANCHOR_POINTS, CONFIG.variantTextAnchor, function(v)
        CONFIG.variantTextAnchor = v
        CONFIG.variantTextRelPoint = v
        if ns.ShowVariantPreview then ns.ShowVariantPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(variantAnchorDropdown)

    local variantOffXSlider = CreateSlider(colourContent, "Variant Offset X", -50, 50, 1, CONFIG.variantTextOffsetX, function(v)
        CONFIG.variantTextOffsetX = v
        if ns.ShowVariantPreview then ns.ShowVariantPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(variantOffXSlider)

    local variantOffYSlider = CreateSlider(colourContent, "Variant Offset Y", -20, 20, 1, CONFIG.variantTextOffsetY, function(v)
        CONFIG.variantTextOffsetY = v
        if ns.ShowVariantPreview then ns.ShowVariantPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(variantOffYSlider)

    -- Duration Text
    AddColourHeader("Duration Text")
    AddColourDescription("Colour, size, and position of cooldown duration text on bars. Enable this feature in the Toggles tab.")

    local cdDurTextColourSwatch = CreateColorSwatch(colourContent, "Duration Text Colour", DeepCopy(CONFIG.cdDurationTextColor), function(c)
        CONFIG.cdDurationTextColor = c
        if ns.ShowDurationPreview then ns.ShowDurationPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(cdDurTextColourSwatch)

    local cdDurTextSizeSlider = CreateSlider(colourContent, "Duration Text Size", 6, 24, 1, CONFIG.cdDurationTextSize or CONFIG.fontSize, function(v)
        CONFIG.cdDurationTextSize = v
        if ns.ShowDurationPreview then ns.ShowDurationPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(cdDurTextSizeSlider)

    local cdDurAnchorDropdown = CreateDropdown(colourContent, "Anchor Point", ANCHOR_POINTS, CONFIG.cdDurationTextAnchor, function(v)
        CONFIG.cdDurationTextAnchor = v
        CONFIG.cdDurationTextRelPoint = v
        if ns.ShowDurationPreview then ns.ShowDurationPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(cdDurAnchorDropdown)

    local cdDurOffXSlider = CreateSlider(colourContent, "Duration Offset X", -50, 50, 1, CONFIG.cdDurationTextOffsetX, function(v)
        CONFIG.cdDurationTextOffsetX = v
        if ns.ShowDurationPreview then ns.ShowDurationPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(cdDurOffXSlider)

    local cdDurOffYSlider = CreateSlider(colourContent, "Duration Offset Y", -20, 20, 1, CONFIG.cdDurationTextOffsetY, function(v)
        CONFIG.cdDurationTextOffsetY = v
        if ns.ShowDurationPreview then ns.ShowDurationPreview() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(cdDurOffYSlider)

    colourContent:SetHeight(colourY + 20)

    coloursTab:SetScript("OnShow", function()
        if CONFIG.cooldownColor then cdColourSwatch:SetColor(DeepCopy(CONFIG.cooldownColor)) end
        if CONFIG.castColor then castColourSwatch:SetColor(DeepCopy(CONFIG.castColor)) end
        if CONFIG.buffColor then buffColourSwatch:SetColor(DeepCopy(CONFIG.buffColor)) end
        if CONFIG.debuffColor then debuffColourSwatch:SetColor(DeepCopy(CONFIG.debuffColor)) end
        if CONFIG.petBuffColor then petBuffColourSwatch:SetColor(DeepCopy(CONFIG.petBuffColor)) end
        if CONFIG.bgcolor then bgColourSwatch:SetColor(DeepCopy(CONFIG.bgcolor)) end
        if CONFIG.bordercolor then borderColourSwatch:SetColor(DeepCopy(CONFIG.bordercolor)) end
        if CONFIG.nowLineColor then nowLineColourSwatch:SetColor(DeepCopy(CONFIG.nowLineColor)) end
        if CONFIG.gcdColor then gcdColourSwatch:SetColor(DeepCopy(CONFIG.gcdColor)) end
        if CONFIG.gcdSparkColor then gcdSparkColourSwatch:SetColor(DeepCopy(CONFIG.gcdSparkColor)) end
        if CONFIG.linesColor then linesColourSwatch:SetColor(DeepCopy(CONFIG.linesColor)) end
        if CONFIG.iconUsableColor then iconUsableColourSwatch:SetColor(DeepCopy(CONFIG.iconUsableColor)) end
        if CONFIG.iconNotEnoughManaColor then iconManaColourSwatch:SetColor(DeepCopy(CONFIG.iconNotEnoughManaColor)) end
        if CONFIG.iconNotUsableColor then iconNotUsableColourSwatch:SetColor(DeepCopy(CONFIG.iconNotUsableColor)) end
        if CONFIG.iconNotInRangeColor then iconRangeColourSwatch:SetColor(DeepCopy(CONFIG.iconNotInRangeColor)) end
        if CONFIG.empowerStage1Color then empowerStage1Swatch:SetColor(DeepCopy(CONFIG.empowerStage1Color)) end
        if CONFIG.empowerStage2Color then empowerStage2Swatch:SetColor(DeepCopy(CONFIG.empowerStage2Color)) end
        if CONFIG.empowerStage3Color then empowerStage3Swatch:SetColor(DeepCopy(CONFIG.empowerStage3Color)) end
        if CONFIG.empowerStage4Color then empowerStage4Swatch:SetColor(DeepCopy(CONFIG.empowerStage4Color)) end
        if CONFIG.disintegrateChainColor then disintChainSwatch:SetColor(DeepCopy(CONFIG.disintegrateChainColor)) end
        if CONFIG.chargeTextColor then chargeTextColourSwatch:SetColor(DeepCopy(CONFIG.chargeTextColor)) end
        if CONFIG.stackTextColor then stackTextColourSwatch:SetColor(DeepCopy(CONFIG.stackTextColor)) end
        if CONFIG.variantTextColor then variantTextColourSwatch:SetColor(DeepCopy(CONFIG.variantTextColor)) end
        fontDropdown:SetValue(CONFIG.font)
        fontSizeSlider:SetValue(CONFIG.fontSize)
        fontFlagsDropdown:SetValue(CONFIG.fontFlags)
        chargeAnchorDropdown:SetValue(CONFIG.chargeTextAnchor)
        chargeOffXSlider:SetValue(CONFIG.chargeTextOffsetX)
        chargeOffYSlider:SetValue(CONFIG.chargeTextOffsetY)
        stackAnchorDropdown:SetValue(CONFIG.stackTextAnchor)
        stackOffXSlider:SetValue(CONFIG.stackTextOffsetX)
        stackOffYSlider:SetValue(CONFIG.stackTextOffsetY)
        variantTextSizeSlider:SetValue(CONFIG.variantTextSize)
        variantAnchorDropdown:SetValue(CONFIG.variantTextAnchor)
        variantOffXSlider:SetValue(CONFIG.variantTextOffsetX)
        variantOffYSlider:SetValue(CONFIG.variantTextOffsetY)
        if CONFIG.cdDurationTextColor then cdDurTextColourSwatch:SetColor(DeepCopy(CONFIG.cdDurationTextColor)) end
        cdDurTextSizeSlider:SetValue(CONFIG.cdDurationTextSize or CONFIG.fontSize)
        cdDurAnchorDropdown:SetValue(CONFIG.cdDurationTextAnchor)
        cdDurOffXSlider:SetValue(CONFIG.cdDurationTextOffsetX)
        cdDurOffYSlider:SetValue(CONFIG.cdDurationTextOffsetY)
    end)

    coloursTab:SetScript("OnHide", function()
        if ns.HideVariantPreview then ns.HideVariantPreview() end
        if ns.HideDurationPreview then ns.HideDurationPreview() end
    end)
end

-- ============================================================================
-- TAB F: STACKS
-- ============================================================================

local POWER_TYPE_INFO = {
    [4]  = {name = "Combo Points",   max = 5, color = {1.0, 0.96, 0.41, 1}},
    [5]  = {name = "Runes",          max = 6, color = {0.77, 0.12, 0.23, 1}},
    [7]  = {name = "Soul Shards",    max = 5, color = {0.58, 0.51, 0.79, 1}},
    [9]  = {name = "Holy Power",     max = 5, color = {0.96, 0.84, 0.09, 1}},
    [12] = {name = "Chi",            max = 5, color = {0.71, 1.0, 0.92, 1}},
    [16] = {name = "Arcane Charges", max = 4, color = {0.1, 0.5, 0.8, 1}},
    [19] = {name = "Essence",        max = 5, color = {0.0, 0.8, 0.4, 1}},
}

local function BuildStacksTab(contentArea, tabFrames)
    local stacksTab = CreateFrame("Frame", nil, contentArea)
    stacksTab:SetAllPoints()
    stacksTab:Hide()
    tabFrames[5] = stacksTab

    local stacksScroll, stacksContent = CreateScrollableContent(stacksTab)

    local yOff = 0
    local function AddStacksWidget(widget)
        widget:SetPoint("TOPLEFT", stacksContent, "TOPLEFT", 10, -yOff)
        yOff = yOff + widget:GetHeight() + 6
    end

    local function AddStacksHeader(text)
        yOff = yOff + 10
        local h = CreateSectionHeader(stacksContent, text)
        h:SetPoint("TOPLEFT", stacksContent, "TOPLEFT", 10, -yOff)
        yOff = yOff + 22
    end

    local function AddStacksDescription(text)
        local desc = stacksContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        desc:SetPoint("TOPLEFT", stacksContent, "TOPLEFT", 10, -yOff)
        desc:SetWidth(500)
        desc:SetJustifyH("LEFT")
        desc:SetSpacing(2)
        desc:SetText(text)
        yOff = yOff + desc:GetStringHeight() + 6
    end

    -- Section 1: Enable Toggle
    AddStacksHeader("Stack Indicators")
    AddStacksDescription("Segmented pip indicators for aura stacks, shown as a thin strip above or below the bar frame. Each pip fills as stacks increase.")

    local enableCheck = CreateCheckbox(stacksContent, "Enable Stack Indicators",
        "Show segmented pip indicators for aura stacks above or below the bar frame",
        CONFIG.stackIndicators or false, function(v)
        CONFIG.stackIndicators = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(enableCheck)

    -- Section 2: Display Settings
    AddStacksHeader("Display")

    local siPositionDropdown = CreateDropdown(stacksContent, "Default Position",
        {{text = "Top", value = "TOP"}, {text = "Bottom", value = "BOTTOM"}},
        (CONFIG.stackIndicatorSettings or {}).position or "TOP", function(v)
            CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
            CONFIG.stackIndicatorSettings.position = v
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            ns.SaveCurrentProfile()
        end)
    AddStacksWidget(siPositionDropdown)

    local siGapSlider = CreateSlider(stacksContent, "Gap from Frame", 0, 10, 1, (CONFIG.stackIndicatorSettings or {}).gap or 2, function(v)
        CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
        CONFIG.stackIndicatorSettings.gap = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(siGapSlider)

    local siPipHeightSlider = CreateSlider(stacksContent, "Pip Height", 4, 16, 1, (CONFIG.stackIndicatorSettings or {}).pipHeight or 6, function(v)
        CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
        CONFIG.stackIndicatorSettings.pipHeight = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(siPipHeightSlider)

    local siPipSpacingSlider = CreateSlider(stacksContent, "Pip Spacing", 0, 4, 1, (CONFIG.stackIndicatorSettings or {}).pipSpacing or 1, function(v)
        CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
        CONFIG.stackIndicatorSettings.pipSpacing = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(siPipSpacingSlider)

    local siRowSpacingSlider = CreateSlider(stacksContent, "Row Spacing", 0, 4, 1, (CONFIG.stackIndicatorSettings or {}).rowSpacing or 1, function(v)
        CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
        CONFIG.stackIndicatorSettings.rowSpacing = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(siRowSpacingSlider)

    local siBorderSizeSlider = CreateSlider(stacksContent, "Border Size", 0, 3, 1, (CONFIG.stackIndicatorSettings or {}).borderSize or 1, function(v)
        CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
        CONFIG.stackIndicatorSettings.borderSize = v
        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(siBorderSizeSlider)

    local siGlowCheck = CreateCheckbox(stacksContent, "Glow at Max Stacks",
        "Pulse a glow overlay when an indicator reaches its maximum stacks",
        (CONFIG.stackIndicatorSettings or {}).glowAtMax ~= false, function(v)
            CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
            CONFIG.stackIndicatorSettings.glowAtMax = v
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            ns.SaveCurrentProfile()
        end)
    AddStacksWidget(siGlowCheck)

    -- Section 3: Colours
    AddStacksHeader("Colours")

    local siEmptyColourSwatch = CreateColorSwatch(stacksContent, "Empty Pip",
        DeepCopy((CONFIG.stackIndicatorSettings or {}).emptyColor or {0.12, 0.12, 0.12, 0.6}),
        function(c)
            CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
            CONFIG.stackIndicatorSettings.emptyColor = c
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            ns.SaveCurrentProfile()
        end)
    AddStacksWidget(siEmptyColourSwatch)

    local siBorderColourSwatch = CreateColorSwatch(stacksContent, "Pip Border",
        DeepCopy((CONFIG.stackIndicatorSettings or {}).borderColor or CONFIG.bordercolor or {0, 0, 0, 1}),
        function(c)
            CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
            CONFIG.stackIndicatorSettings.borderColor = c
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            ns.SaveCurrentProfile()
        end)
    AddStacksWidget(siBorderColourSwatch)

    local siGlowColourSwatch = CreateColorSwatch(stacksContent, "Max Stack Glow",
        DeepCopy((CONFIG.stackIndicatorSettings or {}).glowColor or {1, 1, 1, 0.6}),
        function(c)
            CONFIG.stackIndicatorSettings = CONFIG.stackIndicatorSettings or {}
            CONFIG.stackIndicatorSettings.glowColor = c
            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
            ns.SaveCurrentProfile()
        end)
    AddStacksWidget(siGlowColourSwatch)

    -- Section 4: Configured Indicators
    AddStacksHeader("Configured Indicators")
    AddStacksDescription("Each tracked aura shows its icon, name, max stacks and position. Use colour zones to assign different colours at different stack counts (IE green at 1, yellow at 2, red at 3). Set an overflow value to layer a second colour for stacks beyond the base max.")

    local siListContainer = CreateFrame("Frame", nil, stacksContent)
    siListContainer:SetSize(520, 1)
    local siListTopY = yOff
    AddStacksWidget(siListContainer)

    local siRowFrames = {}
    local RefreshStacksGrid
    local RefreshPowerTypeGrid
    local gridRetried = false
    local UpdateStacksContentHeight

    local function RebuildSIListUI()
        for _, rf in ipairs(siRowFrames) do
            for _, region in pairs({rf:GetRegions()}) do
                region:Hide()
            end
            for _, child in pairs({rf:GetChildren()}) do
                child:Hide()
                for _, cr in pairs({child:GetRegions()}) do
                    cr:Hide()
                end
            end
            rf:Hide()
            rf:SetParent(nil)
        end
        wipe(siRowFrames)

        local list = CONFIG.stackIndicatorList or {}
        local rowY = 0
        local defaultPos = (CONFIG.stackIndicatorSettings or {}).position or "TOP"
        local topCount, bottomCount = 0, 0
        for _, e in ipairs(list) do
            local p = e.position or defaultPos
            if p == "BOTTOM" then bottomCount = bottomCount + 1 else topCount = topCount + 1 end
        end

        for idx, entry in ipairs(list) do
            local sis = CONFIG.stackIndicatorSettings or {}
            local rf = CreateFrame("Frame", nil, siListContainer, "BackdropTemplate")
            rf:SetSize(510, 100)
            rf:SetPoint("TOPLEFT", siListContainer, "TOPLEFT", 0, -rowY)
            rf:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
                insets = {left = 1, right = 1, top = 1, bottom = 1},
            })
            rf:SetBackdropColor(0.08, 0.08, 0.08, 0.4)
            rf:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.5)

            -- Row 1: Icon + Name + Position Toggle + Delete
            local icon = rf:CreateTexture(nil, "ARTWORK")
            icon:SetSize(32, 32)
            icon:SetPoint("TOPLEFT", rf, "TOPLEFT", 8, -8)

            local resolvedName
            if entry.indicatorType == "power" then
                local pInfo = POWER_TYPE_INFO[entry.powerType]
                local pColor = pInfo and pInfo.color or {0.5, 0.5, 0.5, 1}
                icon:SetColorTexture(pColor[1], pColor[2], pColor[3], pColor[4] or 1)
                resolvedName = pInfo and pInfo.name or ("Power " .. (entry.powerType or "?"))
            else
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local displaySpellID = entry.auraSpellID
                if (not displaySpellID or displaySpellID == 0) and entry.cooldownID then
                    local cdOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, entry.cooldownID)
                    if cdOk and cdInfo then displaySpellID = cdInfo.spellID end
                end
                local spellName = displaySpellID and C_Spell.GetSpellName(displaySpellID)
                local spellIcon = spellName and C_Spell.GetSpellTexture(displaySpellID)
                if spellIcon then
                    icon:SetTexture(spellIcon)
                else
                    icon:SetColorTexture(0.3, 0.3, 0.3, 1)
                end
                resolvedName = spellName or ("ID: " .. (entry.cooldownID or entry.auraSpellID or "?"))
            end

            local nameText = rf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            nameText:SetWidth(200)
            nameText:SetJustifyH("LEFT")
            nameText:SetText(resolvedName)

            local delBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
            delBtn:SetSize(22, 22)
            delBtn:SetPoint("TOPRIGHT", rf, "TOPRIGHT", -6, -10)
            delBtn:SetText("X")
            delBtn:SetScript("OnClick", function()
                table.remove(CONFIG.stackIndicatorList, idx)
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
                if RefreshStacksGrid then RefreshStacksGrid() end
                if RefreshPowerTypeGrid then RefreshPowerTypeGrid() end
            end)
            delBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Remove")
                GameTooltip:Show()
            end)
            delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local posBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
            posBtn:SetSize(56, 20)
            posBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            local resolvedPos = entry.position or sis.position or "TOP"
            posBtn:SetText(resolvedPos == "BOTTOM" and "Bottom" or "Top")
            posBtn:SetScript("OnClick", function()
                local cur = entry.position or sis.position or "TOP"
                local newPos = cur == "TOP" and "BOTTOM" or "TOP"
                entry.position = newPos
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
            end)
            posBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Position")
                GameTooltip:AddLine("Click to toggle between Top and Bottom.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            posBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local myPos = resolvedPos
            local groupCount = (myPos == "BOTTOM") and bottomCount or topCount
            if groupCount > 1 then
                local function FindNeighbor(dir)
                    local l = CONFIG.stackIndicatorList
                    local step = dir == "up" and -1 or 1
                    local k = idx + step
                    while k >= 1 and k <= #l do
                        local p = l[k].position or defaultPos
                        if p == myPos then return k end
                        k = k + step
                    end
                    return nil
                end

                local nextDown = FindNeighbor("down")
                local nextUp = FindNeighbor("up")

                local downBtn = CreateFrame("Button", nil, rf)
                downBtn:SetSize(18, 16)
                downBtn:SetPoint("RIGHT", posBtn, "LEFT", -6, 0)
                downBtn:SetNormalAtlas("UI-ScrollBar-ScrollDownButton-Up")
                downBtn:SetPushedAtlas("UI-ScrollBar-ScrollDownButton-Down")
                downBtn:SetHighlightAtlas("UI-ScrollBar-ScrollDownButton-Highlight")
                downBtn:SetDisabledAtlas("UI-ScrollBar-ScrollDownButton-Disabled")
                if not nextDown then downBtn:Disable() end
                downBtn:SetScript("OnClick", function()
                    local target = FindNeighbor("down")
                    if target then
                        local l = CONFIG.stackIndicatorList
                        l[idx], l[target] = l[target], l[idx]
                        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                        ns.SaveCurrentProfile()
                        RebuildSIListUI()
                    end
                end)
                downBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Move Down")
                    GameTooltip:Show()
                end)
                downBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                local upBtn = CreateFrame("Button", nil, rf)
                upBtn:SetSize(18, 16)
                upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)
                upBtn:SetNormalAtlas("UI-ScrollBar-ScrollUpButton-Up")
                upBtn:SetPushedAtlas("UI-ScrollBar-ScrollUpButton-Down")
                upBtn:SetHighlightAtlas("UI-ScrollBar-ScrollUpButton-Highlight")
                upBtn:SetDisabledAtlas("UI-ScrollBar-ScrollUpButton-Disabled")
                if not nextUp then upBtn:Disable() end
                upBtn:SetScript("OnClick", function()
                    local target = FindNeighbor("up")
                    if target then
                        local l = CONFIG.stackIndicatorList
                        l[idx], l[target] = l[target], l[idx]
                        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                        ns.SaveCurrentProfile()
                        RebuildSIListUI()
                    end
                end)
                upBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Move Up")
                    GameTooltip:Show()
                end)
                upBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end

            -- Row 2: Max Stacks + Overflow + OV Colour
            local maxLabel = rf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            maxLabel:SetPoint("LEFT", rf, "LEFT", 12, -6)
            maxLabel:SetText("Max Stacks:")

            local maxEdit = CreateFrame("EditBox", nil, rf, "InputBoxTemplate")
            maxEdit:SetSize(30, 18)
            maxEdit:SetPoint("LEFT", maxLabel, "RIGHT", 4, 0)
            maxEdit:SetAutoFocus(false)
            maxEdit:SetNumeric(true)
            maxEdit:SetText(tostring(entry.maxStacks or 3))
            local function CommitMaxStacks(self)
                local val = tonumber(self:GetText())
                if val and val >= 1 and val <= 99 then
                    entry.maxStacks = val
                    -- Remove zones with fromStack > new max
                    if entry.colorZones then
                        for k = #entry.colorZones, 1, -1 do
                            if entry.colorZones[k].fromStack > val then
                                table.remove(entry.colorZones, k)
                            end
                        end
                    end
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                else
                    self:SetText(tostring(entry.maxStacks or 3))
                end
            end
            maxEdit:SetScript("OnEnterPressed", function(self)
                CommitMaxStacks(self)
                self:ClearFocus()
            end)
            maxEdit:SetScript("OnEditFocusLost", CommitMaxStacks)
            maxEdit:SetScript("OnEscapePressed", function(self)
                self:SetText(tostring(entry.maxStacks or 3))
                self:ClearFocus()
            end)
            maxEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

            local ovLabel = rf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            ovLabel:SetPoint("LEFT", maxEdit, "RIGHT", 14, 0)
            ovLabel:SetText("Overflow:")

            local ovEdit = CreateFrame("EditBox", nil, rf, "InputBoxTemplate")
            ovEdit:SetSize(30, 18)
            ovEdit:SetPoint("LEFT", ovLabel, "RIGHT", 4, 0)
            ovEdit:SetAutoFocus(false)
            ovEdit:SetNumeric(true)
            ovEdit:SetText(tostring(entry.overflowMax or 0))
            local function CommitOverflow(self)
                local val = tonumber(self:GetText())
                if val and val >= 0 and val <= 99 then
                    entry.overflowMax = val > 0 and val or nil
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                else
                    self:SetText(tostring(entry.overflowMax or 0))
                end
            end
            ovEdit:SetScript("OnEnterPressed", function(self)
                CommitOverflow(self)
                self:ClearFocus()
            end)
            ovEdit:SetScript("OnEditFocusLost", CommitOverflow)
            ovEdit:SetScript("OnEscapePressed", function(self)
                self:SetText(tostring(entry.overflowMax or 0))
                self:ClearFocus()
            end)
            ovEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

            local ovColorBtn = CreateFrame("Button", nil, rf)
            ovColorBtn:SetSize(20, 20)
            ovColorBtn:SetPoint("LEFT", ovEdit, "RIGHT", 6, 0)
            local ovColorBg = ovColorBtn:CreateTexture(nil, "BACKGROUND")
            ovColorBg:SetAllPoints()
            ovColorBg:SetColorTexture(0, 0, 0, 1)
            local ovColorTex = ovColorBtn:CreateTexture(nil, "OVERLAY")
            ovColorTex:SetPoint("TOPLEFT", 1, -1)
            ovColorTex:SetPoint("BOTTOMRIGHT", -1, 1)
            local oc = entry.overflowColor or {1, 0.8, 0.2, 1}
            ovColorTex:SetColorTexture(oc[1], oc[2], oc[3], oc[4] or 1)
            ovColorBtn:SetScript("OnClick", function()
                OpenInlineColorPicker(DeepCopy(oc), function(c)
                    entry.overflowColor = c
                    ovColorTex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                end)
            end)
            ovColorBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Overflow Colour")
                GameTooltip:AddLine("Layered colour for stacks beyond the base max.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            ovColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local hideCheck = CreateFrame("CheckButton", nil, rf, "UICheckButtonTemplate")
            hideCheck:SetSize(20, 20)
            hideCheck:SetPoint("LEFT", ovColorBtn, "RIGHT", 14, 0)
            hideCheck:SetChecked(entry.hideWhenEmpty or false)
            hideCheck:SetScript("OnClick", function(self)
                entry.hideWhenEmpty = self:GetChecked() or nil
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
            end)
            local hideLabel = rf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hideLabel:SetPoint("LEFT", hideCheck, "RIGHT", 2, 0)
            hideLabel:SetText("Hide when empty")

            -- Row 3: Colour Zones or Legacy Pip Colour
            if entry.colorZones and #entry.colorZones > 0 then
                local zonesLabel = rf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                zonesLabel:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", 12, 14)
                zonesLabel:SetText("Zones:")

                local clearZonesBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
                clearZonesBtn:SetSize(18, 18)
                clearZonesBtn:SetPoint("LEFT", zonesLabel, "RIGHT", 4, 0)
                clearZonesBtn:SetText("X")
                clearZonesBtn:SetScript("OnClick", function()
                    entry.color = DeepCopy(entry.colorZones[1] and entry.colorZones[1].color or entry.color or {0.8, 0.2, 0.1, 1})
                    entry.colorZones = nil
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                end)
                clearZonesBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Remove Zones")
                    GameTooltip:AddLine("Revert to a single pip colour.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                clearZonesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                local zones = entry.colorZones
                local zoneXOff = 76
                for zi, zone in ipairs(zones) do
                    local zBtn = CreateFrame("Button", nil, rf)
                    zBtn:SetSize(20, 20)
                    zBtn:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", zoneXOff, 10)
                    local zBg = zBtn:CreateTexture(nil, "BACKGROUND")
                    zBg:SetAllPoints()
                    zBg:SetColorTexture(0, 0, 0, 1)
                    local zTex = zBtn:CreateTexture(nil, "OVERLAY")
                    zTex:SetPoint("TOPLEFT", 1, -1)
                    zTex:SetPoint("BOTTOMRIGHT", -1, 1)
                    local zc = zone.color or {0.8, 0.2, 0.1, 1}
                    zTex:SetColorTexture(zc[1], zc[2], zc[3], zc[4] or 1)

                    local zoneIdx = zi
                    zBtn:SetScript("OnClick", function()
                        OpenInlineColorPicker(DeepCopy(zc), function(c)
                            entry.colorZones[zoneIdx].color = c
                            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                            ns.SaveCurrentProfile()
                            RebuildSIListUI()
                        end)
                    end)
                    zBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Zone " .. zoneIdx .. " Colour")
                        GameTooltip:AddLine("Pips from stack " .. zone.fromStack .. " use this colour.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    zBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    zoneXOff = zoneXOff + 26

                    local zEdit = CreateFrame("EditBox", nil, rf, "InputBoxTemplate")
                    zEdit:SetSize(28, 18)
                    zEdit:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", zoneXOff, 11)
                    zEdit:SetAutoFocus(false)
                    zEdit:SetNumeric(true)
                    zEdit:SetText(tostring(zone.fromStack))
                    if zi == 1 then
                        zEdit:Disable()
                        zEdit:SetTextColor(0.5, 0.5, 0.5)
                    end
                    local function CommitZoneFrom(self)
                        local val = tonumber(self:GetText())
                        local maxS = entry.maxStacks or 3
                        if val and val >= 1 and val <= maxS then
                            entry.colorZones[zoneIdx].fromStack = val
                            table.sort(entry.colorZones, function(a, b) return a.fromStack < b.fromStack end)
                            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                            ns.SaveCurrentProfile()
                            RebuildSIListUI()
                        else
                            self:SetText(tostring(zone.fromStack))
                        end
                    end
                    zEdit:SetScript("OnEnterPressed", function(self)
                        CommitZoneFrom(self)
                        self:ClearFocus()
                    end)
                    zEdit:SetScript("OnEditFocusLost", CommitZoneFrom)
                    zEdit:SetScript("OnEscapePressed", function(self)
                        self:SetText(tostring(zone.fromStack))
                        self:ClearFocus()
                    end)
                    zEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
                    zoneXOff = zoneXOff + 32

                    if zi > 1 then
                        local zDel = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
                        zDel:SetSize(18, 18)
                        zDel:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", zoneXOff, 11)
                        zDel:SetText("X")
                        zDel:SetScript("OnClick", function()
                            table.remove(entry.colorZones, zoneIdx)
                            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                            ns.SaveCurrentProfile()
                            RebuildSIListUI()
                        end)
                        zDel:SetScript("OnEnter", function(self)
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetText("Remove Zone")
                            GameTooltip:Show()
                        end)
                        zDel:SetScript("OnLeave", function() GameTooltip:Hide() end)
                        zoneXOff = zoneXOff + 22
                    end

                    zoneXOff = zoneXOff + 8
                end

                if #zones < 5 then
                    local addZoneBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
                    addZoneBtn:SetSize(28, 20)
                    addZoneBtn:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", zoneXOff, 10)
                    addZoneBtn:SetText("+")
                    addZoneBtn:SetScript("OnClick", function()
                        local maxS = entry.maxStacks or 3
                        local lastZone = entry.colorZones[#entry.colorZones]
                        local nextFrom = math.min((lastZone and lastZone.fromStack or 0) + 1, maxS)
                        entry.colorZones[#entry.colorZones + 1] = {
                            fromStack = nextFrom,
                            color = DeepCopy(lastZone and lastZone.color or {0.8, 0.2, 0.1, 1}),
                        }
                        table.sort(entry.colorZones, function(a, b) return a.fromStack < b.fromStack end)
                        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                        ns.SaveCurrentProfile()
                        RebuildSIListUI()
                    end)
                    addZoneBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Add Zone")
                        GameTooltip:AddLine("Add a new colour zone.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    addZoneBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end

            else
                -- Legacy single pip colour + Add Zones button
                local colorBtn = CreateFrame("Button", nil, rf)
                colorBtn:SetSize(20, 20)
                colorBtn:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", 12, 10)
                local colorBg = colorBtn:CreateTexture(nil, "BACKGROUND")
                colorBg:SetAllPoints()
                colorBg:SetColorTexture(0, 0, 0, 1)
                local colorTex = colorBtn:CreateTexture(nil, "OVERLAY")
                colorTex:SetPoint("TOPLEFT", 1, -1)
                colorTex:SetPoint("BOTTOMRIGHT", -1, 1)
                local ec = entry.color or {0.8, 0.2, 0.1, 1}
                colorTex:SetColorTexture(ec[1], ec[2], ec[3], ec[4] or 1)

                local colorLabel = rf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                colorLabel:SetPoint("LEFT", colorBtn, "RIGHT", 6, 0)
                colorLabel:SetText("Pip Colour")

                colorBtn:SetScript("OnClick", function()
                    OpenInlineColorPicker(DeepCopy(ec), function(c)
                        entry.color = c
                        colorTex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                        ns.SaveCurrentProfile()
                    end)
                end)
                colorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Pip Colour")
                    GameTooltip:AddLine("Click to change the pip fill colour.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                colorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                local addZonesBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
                addZonesBtn:SetSize(84, 20)
                addZonesBtn:SetPoint("LEFT", colorLabel, "RIGHT", 10, 0)
                addZonesBtn:SetText("Add Zones")
                addZonesBtn:SetScript("OnClick", function()
                    local baseColor = DeepCopy(entry.color or {0.8, 0.2, 0.1, 1})
                    local maxS = entry.maxStacks or 3
                    local secondFrom = math.min(2, maxS)
                    entry.colorZones = {
                        {fromStack = 1, color = baseColor},
                        {fromStack = secondFrom, color = DeepCopy(baseColor)},
                    }
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                end)
                addZonesBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Colour Zones")
                    GameTooltip:AddLine("Set different pip colours at different stack counts.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                addZonesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end

            siRowFrames[#siRowFrames + 1] = rf
            rowY = rowY + 104
        end

        siListContainer:SetHeight(math.max(rowY, 1))
        if UpdateStacksContentHeight then UpdateStacksContentHeight() end
    end

    -- Section 5: Available Buffs Grid
    -- Anchored to siListContainer bottom so it moves when the list changes
    local gridHeader = CreateSectionHeader(stacksContent, "Available Buffs")
    gridHeader:SetPoint("TOPLEFT", siListContainer, "BOTTOMLEFT", 0, -16)

    local gridDesc = stacksContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    gridDesc:SetPoint("TOPLEFT", gridHeader, "BOTTOMLEFT", 0, -6)
    gridDesc:SetWidth(500)
    gridDesc:SetJustifyH("LEFT")
    gridDesc:SetSpacing(2)
    gridDesc:SetText("Buff auras from the Cooldown Manager. Click to add as a stack indicator. If a buff isn't here, add it to the Cooldown Manager first.")

    local gridContainer = CreateFrame("Frame", nil, stacksContent)
    gridContainer:SetPoint("TOPLEFT", gridDesc, "BOTTOMLEFT", 0, -8)
    gridContainer:SetSize(520, 1)

    local gridCache = {}
    local gridCacheCount = 0
    local gridEmptyText

    -- Section 6: Power Types
    local powerHeader = CreateSectionHeader(stacksContent, "Power Types")
    powerHeader:SetPoint("TOPLEFT", gridContainer, "BOTTOMLEFT", 0, -16)

    local powerDesc = stacksContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    powerDesc:SetPoint("TOPLEFT", powerHeader, "BOTTOMLEFT", 0, -6)
    powerDesc:SetWidth(500)
    powerDesc:SetJustifyH("LEFT")
    powerDesc:SetSpacing(2)
    powerDesc:SetText("Class resource types like Holy Power, Chi, and Combo Points. Click to add as a pip indicator.")

    local powerContainer = CreateFrame("Frame", nil, stacksContent)
    powerContainer:SetPoint("TOPLEFT", powerDesc, "BOTTOMLEFT", 0, -8)
    powerContainer:SetSize(520, 1)

    local function GetTrackedCooldownIDs()
        local tracked = {}
        local list = CONFIG.stackIndicatorList or {}
        for _, entry in ipairs(list) do
            if entry.cooldownID then
                tracked[entry.cooldownID] = true
            end
        end
        return tracked
    end

    local function GetTrackedPowerTypes()
        local tracked = {}
        local list = CONFIG.stackIndicatorList or {}
        for _, entry in ipairs(list) do
            if entry.indicatorType == "power" and entry.powerType then
                tracked[entry.powerType] = true
            end
        end
        return tracked
    end

    UpdateStacksContentHeight = function()
        local h = siListTopY + siListContainer:GetHeight()
                + 16 + 22 + 6 + gridDesc:GetStringHeight() + 8 + gridContainer:GetHeight()
                + 16 + 22 + 6 + powerDesc:GetStringHeight() + 8 + powerContainer:GetHeight() + 20
        stacksContent:SetHeight(h)
    end

    local function ParseMaxStacks(spellID)
        local ok, desc = pcall(C_Spell.GetSpellDescription, spellID)
        if not ok or not desc then return 3 end
        desc = desc:lower()
        local n = desc:match("up%s+to%s+(%d+)%s+stack")
            or desc:match("stacking%s+up%s+to%s+(%d+)")
            or desc:match("maximum%s+of%s+(%d+)%s+stack")
            or desc:match("max%s+(%d+)%s+stack")
            or desc:match("(%d+)%s+stack")
        if n then
            n = tonumber(n)
            if n and n >= 2 and n <= 99 then return n end
        end
        return 3
    end

    RefreshStacksGrid = function()
        for i = 1, gridCacheCount do
            if gridCache[i] then gridCache[i]:Hide() end
        end

        local seen = {}
        local buffIDs = {}

        local ok2, cat2 = pcall(function()
            return C_CooldownViewer.GetCooldownViewerCategorySet(2, false)
        end)
        if ok2 and cat2 then
            for _, id in ipairs(cat2) do
                if not seen[id] then
                    seen[id] = true
                    buffIDs[#buffIDs + 1] = id
                end
            end
        end

        local ok3, cat3 = pcall(function()
            return C_CooldownViewer.GetCooldownViewerCategorySet(3, false)
        end)
        if ok3 and cat3 then
            for _, id in ipairs(cat3) do
                if not seen[id] then
                    seen[id] = true
                    buffIDs[#buffIDs + 1] = id
                end
            end
        end

        local ok0, cat0 = pcall(function()
            return C_CooldownViewer.GetCooldownViewerCategorySet(0, false)
        end)
        if ok0 and cat0 then
            for _, id in ipairs(cat0) do
                if not seen[id] then
                    local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                    if infoOk and cdInfo and cdInfo.hasAura then
                        seen[id] = true
                        buffIDs[#buffIDs + 1] = id
                    end
                end
            end
        end

        -- Show every CDM buff aura. The tooltip word "stack" is an unreliable
        -- filter , some stacking auras (IE Shadow Techniques) never say it.
        -- Picking a non-stacking buff still works; it just shows 0 or 1 pip.
        local filteredIDs = buffIDs

        local tracked = GetTrackedCooldownIDs()
        local cols = 16
        local iconSz = 30
        local gap = 4
        local gridIdx = 0

        for i, buffCdID in ipairs(filteredIDs) do
            local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
            local spellID = infoOk and cdInfo and (cdInfo.overrideTooltipSpellID or cdInfo.overrideSpellID or cdInfo.spellID)
            local rName, rIcon = ns.ResolveCooldownDisplay(buffCdID, cdInfo)
            local tex = rIcon or 134400
            local spellName = rName or ("ID:" .. buffCdID)

            gridIdx = gridIdx + 1
            local col = (gridIdx - 1) % cols
            local rowIdx = math.floor((gridIdx - 1) / cols)

            local btn = gridCache[gridIdx]
            if not btn then
                btn = CreateFrame("Button", nil, gridContainer)
                btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                btn.iconTex = btn:CreateTexture(nil, "ARTWORK")
                btn.iconTex:SetAllPoints()
                btn.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                btn.trackedBorder = btn:CreateTexture(nil, "OVERLAY")
                btn.trackedBorder:SetPoint("TOPLEFT", -2, 2)
                btn.trackedBorder:SetPoint("BOTTOMRIGHT", 2, -2)
                btn.trackedBorder:SetColorTexture(0, 0.8, 0, 0.5)
                gridCache[gridIdx] = btn
                gridCacheCount = math.max(gridCacheCount, gridIdx)
            end

            btn:Show()
            btn:SetSize(iconSz, iconSz)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", col * (iconSz + gap), -rowIdx * (iconSz + gap))
            btn.iconTex:SetTexture(tex)

            if tracked[buffCdID] then
                btn.trackedBorder:Show()
            else
                btn.trackedBorder:Hide()
            end

            btn.cdID = buffCdID
            btn.spellID = spellID
            btn.spellName = spellName

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.spellName, 1, 1, 1)
                GameTooltip:AddLine("CooldownID: " .. self.cdID, 0.7, 0.7, 0.7)
                if self.spellID then
                    GameTooltip:AddLine("SpellID: " .. self.spellID, 0.7, 0.7, 0.7)
                end
                local currentTracked = GetTrackedCooldownIDs()
                if currentTracked[self.cdID] then
                    GameTooltip:AddLine("Already tracked, right click to remove", 0.5, 0.8, 0.5)
                else
                    GameTooltip:AddLine("Click to add", 0.5, 0.8, 0.5)
                end
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(self, button)
                local currentTracked = GetTrackedCooldownIDs()
                if button == "RightButton" then
                    if not currentTracked[self.cdID] then return end
                    local list = CONFIG.stackIndicatorList or {}
                    for k = #list, 1, -1 do
                        if list[k].cooldownID == self.cdID then
                            table.remove(list, k)
                            break
                        end
                    end
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                    RefreshStacksGrid()
                    return
                end
                if currentTracked[self.cdID] then return end
                CONFIG.stackIndicatorList = CONFIG.stackIndicatorList or {}
                CONFIG.stackIndicatorList[#CONFIG.stackIndicatorList + 1] = {
                    cooldownID = self.cdID,
                    auraSpellID = self.spellID or 0,
                    maxStacks = ParseMaxStacks(self.spellID),
                    color = DeepCopy(CONFIG.cooldownColor or {0.8, 0.2, 0.1, 1}),
                }
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
                RefreshStacksGrid()
            end)
        end

        for i = gridIdx + 1, gridCacheCount do
            if gridCache[i] then gridCache[i]:Hide() end
        end

        local totalRows = math.ceil(gridIdx / cols)
        gridContainer:SetHeight(math.max(totalRows * (iconSz + gap), 1))
        UpdateStacksContentHeight()

        if gridIdx == 0 then
            if not gridEmptyText then
                gridEmptyText = gridContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                gridEmptyText:SetPoint("TOPLEFT", 4, -4)
                gridEmptyText:SetWidth(500)
                gridEmptyText:SetJustifyH("LEFT")
                gridEmptyText:SetText("No buff auras with stacks detected.")
            end
            gridEmptyText:Show()
            gridContainer:SetHeight(30)
            UpdateStacksContentHeight()

            if not gridRetried then
                gridRetried = true
                C_Timer.After(1.5, function()
                    if stacksTab:IsShown() then RefreshStacksGrid() end
                end)
            end
        else
            if gridEmptyText then gridEmptyText:Hide() end
        end
    end

    -- Power Types grid
    local powerGridCache = {}
    local powerGridCacheCount = 0
    local powerEmptyText

    RefreshPowerTypeGrid = function()
        for i = 1, powerGridCacheCount do
            if powerGridCache[i] then powerGridCache[i]:Hide() end
        end

        local available = {}
        for pType, pInfo in pairs(POWER_TYPE_INFO) do
            local ok, maxP = pcall(UnitPowerMax, "player", pType)
            if ok and maxP and not issecretvalue(maxP) and maxP > 0 then
                available[#available + 1] = {powerType = pType, info = pInfo}
            end
        end
        table.sort(available, function(a, b) return a.info.name < b.info.name end)

        local tracked = GetTrackedPowerTypes()
        local gridIdx = 0
        local xOff = 0

        for _, ptEntry in ipairs(available) do
            local pType = ptEntry.powerType
            local pInfo = ptEntry.info

            gridIdx = gridIdx + 1
            local btn = powerGridCache[gridIdx]
            if not btn then
                btn = CreateFrame("Button", nil, powerContainer, "BackdropTemplate")
                btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                btn:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = 1,
                    insets = {left = 1, right = 1, top = 1, bottom = 1},
                })
                btn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
                btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                btn.colorSq = btn:CreateTexture(nil, "ARTWORK")
                btn.colorSq:SetSize(14, 14)
                btn.colorSq:SetPoint("LEFT", btn, "LEFT", 6, 0)
                btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.label:SetPoint("LEFT", btn.colorSq, "RIGHT", 4, 0)
                btn.label:SetJustifyH("LEFT")
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(0.3, 0.3, 0.5, 0.4)
                powerGridCache[gridIdx] = btn
                powerGridCacheCount = math.max(powerGridCacheCount, gridIdx)
            end

            btn:Show()
            btn:SetSize(120, 24)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", xOff, 0)
            xOff = xOff + 124

            btn.colorSq:SetColorTexture(pInfo.color[1], pInfo.color[2], pInfo.color[3], pInfo.color[4] or 1)
            btn.label:SetText(pInfo.name)
            btn.powerType = pType
            btn.powerInfo = pInfo

            if tracked[pType] then
                btn:SetBackdropBorderColor(0, 0.8, 0, 0.8)
            else
                btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            end

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.powerInfo.name, 1, 1, 1)
                GameTooltip:AddLine("Max: " .. self.powerInfo.max, 0.7, 0.7, 0.7)
                local currentTracked = GetTrackedPowerTypes()
                if currentTracked[self.powerType] then
                    GameTooltip:AddLine("Already tracked, right click to remove", 0.5, 0.8, 0.5)
                else
                    GameTooltip:AddLine("Click to add", 0.5, 0.8, 0.5)
                end
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(self, button)
                local currentTracked = GetTrackedPowerTypes()
                if button == "RightButton" then
                    if not currentTracked[self.powerType] then return end
                    local list = CONFIG.stackIndicatorList or {}
                    for k = #list, 1, -1 do
                        if list[k].indicatorType == "power" and list[k].powerType == self.powerType then
                            table.remove(list, k)
                            break
                        end
                    end
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                    RefreshPowerTypeGrid()
                    return
                end
                if currentTracked[self.powerType] then return end
                CONFIG.stackIndicatorList = CONFIG.stackIndicatorList or {}
                local maxP = UnitPowerMax("player", self.powerType)
                if issecretvalue(maxP) or not maxP or maxP <= 0 then maxP = self.powerInfo.max end
                CONFIG.stackIndicatorList[#CONFIG.stackIndicatorList + 1] = {
                    indicatorType = "power",
                    powerType = self.powerType,
                    maxStacks = maxP,
                    color = DeepCopy(self.powerInfo.color),
                }
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
                RefreshPowerTypeGrid()
            end)
        end

        for i = gridIdx + 1, powerGridCacheCount do
            if powerGridCache[i] then powerGridCache[i]:Hide() end
        end

        powerContainer:SetHeight(gridIdx > 0 and 28 or 1)

        if gridIdx == 0 then
            if not powerEmptyText then
                powerEmptyText = powerContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                powerEmptyText:SetPoint("TOPLEFT", 4, -4)
                powerEmptyText:SetWidth(500)
                powerEmptyText:SetJustifyH("LEFT")
                powerEmptyText:SetText("No pip based power types for your class.")
            end
            powerEmptyText:Show()
            powerContainer:SetHeight(24)
        else
            if powerEmptyText then powerEmptyText:Hide() end
        end

        UpdateStacksContentHeight()
    end

    RebuildSIListUI()

    stacksContent:SetHeight(yOff + 20)

    local function RefreshStacksTab()
        enableCheck:SetChecked(CONFIG.stackIndicators or false)
        local sis = CONFIG.stackIndicatorSettings or {}
        siPositionDropdown:SetValue(sis.position or "TOP")
        siGapSlider:SetValue(sis.gap or 2)
        siPipHeightSlider:SetValue(sis.pipHeight or 6)
        siPipSpacingSlider:SetValue(sis.pipSpacing or 1)
        siRowSpacingSlider:SetValue(sis.rowSpacing or 1)
        siBorderSizeSlider:SetValue(sis.borderSize or 1)
        siGlowCheck:SetChecked(sis.glowAtMax ~= false)
        siEmptyColourSwatch:SetColor(DeepCopy(sis.emptyColor or {0.12, 0.12, 0.12, 0.6}))
        siBorderColourSwatch:SetColor(DeepCopy(sis.borderColor or CONFIG.bordercolor or {0, 0, 0, 1}))
        siGlowColourSwatch:SetColor(DeepCopy(sis.glowColor or {1, 1, 1, 0.6}))
        RebuildSIListUI()
        RefreshStacksGrid()
        RefreshPowerTypeGrid()
    end

    stacksTab:SetScript("OnShow", RefreshStacksTab)
    ns.RefreshStacksTab = RefreshStacksTab
end

-- ============================================================================
-- BUILD THE SETTINGS PANEL (deferred)
-- ============================================================================

local function BuildSettings()
    if settingsBuilt then return end
    settingsBuilt = true

    -- Local aliases for Bars.lua functions.
    local LoadEssentialCooldowns = ns.LoadEssentialCooldowns
    local ApplyLayoutToAllBars = ns.ApplyLayoutToAllBars

    local refreshSettingsUI
    local RefreshCooldownRows
    local RefreshBuffPool

    settingsFrame = CreateFrame("Frame", "InfallSettingsFrame", UIParent)
    settingsFrame:SetSize(800, 600)
    settingsFrame:Hide()
    settingsFrame:SetScript("OnHide", function() GameTooltip:Hide() end)

    -- Title
    local titleText = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 16, -16)
    titleText:SetText("EventHorizon Infall")

    local versionText = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
    versionText:SetText("v1.3.6")

    -- Reset to Default button (upper right)
    local resetDefaultBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
    resetDefaultBtn:SetSize(130, 24)
    resetDefaultBtn:SetPoint("TOPRIGHT", -16, -16)
    resetDefaultBtn:SetText("Reset to Default")

    StaticPopupDialogs["INFALL_RESET_DEFAULTS"] = {
        text = "This will remove all your customisations (bar pairings, display settings, colours, toggles) and revert to class config defaults including buff assignments.\n\nAre you sure?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function()
            if ns.classConfigDefaults then
                ns.ApplyProfile(ns.classConfigDefaults)
                ns.SaveCurrentProfile()
                LoadEssentialCooldowns()
                -- Switch to Bars tab after reset.
                C_Timer.After(0, function()
                    SelectTab(1)
                    -- Refresh cooldown rows and buff pool.
                    if RefreshCooldownRows then RefreshCooldownRows() end
                    if RefreshBuffPool then RefreshBuffPool() end
                end)
                print("|cff00ff00[Infall]|r Settings reset to class defaults.")
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    resetDefaultBtn:SetScript("OnClick", function()
        StaticPopup_Show("INFALL_RESET_DEFAULTS")
    end)
    resetDefaultBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Reset to Default")
        GameTooltip:AddLine("Removes all customisations and reverts to class config defaults, including buff assignments.", 1, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    resetDefaultBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local dragHint = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dragHint:SetPoint("RIGHT", resetDefaultBtn, "LEFT", -12, 0)
    dragHint:SetText("Drag to move this window")

    -- Separator between header and tabs
    local headerBorder = settingsFrame:CreateTexture(nil, "ARTWORK")
    headerBorder:SetColorTexture(0.6, 0.6, 0.6, 0.4)
    headerBorder:SetPoint("TOPLEFT", 16, -42)
    headerBorder:SetPoint("TOPRIGHT", -16, -42)
    headerBorder:SetHeight(1)

    -- Tab bar
    for i, name in ipairs(TAB_NAMES) do
        local btn = CreateFrame("Button", "InfallSettingsTab" .. i, settingsFrame, "PanelTabButtonTemplate")
        btn:SetText(name)
        PanelTemplates_TabResize(btn, 8, nil, nil, nil, btn:GetFontString():GetStringWidth() + 40)
        if i == 1 then
            btn:SetPoint("TOPLEFT", 16, -46)
        else
            btn:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", -8, 0)
        end
        btn:SetScript("OnClick", function() SelectTab(i) end)
        tabButtons[i] = btn
    end

    -- Anchored to tab bottom so tabs connect to content
    local contentArea = CreateFrame("Frame", nil, settingsFrame)
    contentArea:SetPoint("TOPLEFT", tabButtons[1], "BOTTOMLEFT", 0, 2)
    contentArea:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", -16, 16)

    -- ========================================================================
    -- TAB A: BARS
    -- ========================================================================
    local barsTab = CreateFrame("Frame", nil, contentArea)
    barsTab:SetAllPoints()
    barsTab:Hide()
    tabFrames[1] = barsTab

    -- State for click-to-select pairing
    local selectedBuff = nil
    local selectedBuffFrame = nil
    local selectedCast = nil       -- spellID of selected cast from cast pool
    local selectedCastFrame = nil
    local selectedType = nil       -- "buff" or "cast"
    local allSlotFrames = {}

    -- Frame caches
    local cooldownRowCache = {}
    local cooldownRowCacheCount = 0
    local buffPoolCache = {}
    local buffPoolCacheCount = 0
    local castPoolCache = {}
    local castPoolCacheCount = 0
    local extrasRowCache = {}
    local extrasRowCacheCount = 0
    local customRowCache = {}
    local customRowCacheCount = 0
    local extrasHeaderFrame
    local profileBtnCache = {}
    local profileBtnCacheCount = 0

    local function CancelSelection()
        if selectedBuffFrame then
            selectedBuffFrame.highlight:Hide()
        end
        if selectedCastFrame then
            selectedCastFrame.highlight:Hide()
        end
        selectedBuff = nil
        selectedBuffFrame = nil
        selectedCast = nil
        selectedCastFrame = nil
        selectedType = nil
        for _, slot in ipairs(allSlotFrames) do
            if slot.selectionGlow then
                slot.selectionGlow:Hide()
            end
        end
    end

    local function HighlightAvailableSlots()
        for _, slot in ipairs(allSlotFrames) do
            if slot.selectionGlow then
                if selectedType == "buff" then
                    -- Buffs can pair to buff slots and stack slots
                    if slot.slotType == "buff" or slot.slotType == "stack" then
                        slot.selectionGlow:Show()
                    else
                        slot.selectionGlow:Hide()
                    end
                elseif selectedType == "cast" then
                    -- Casts can pair to cast slots only
                    if slot.slotType == "cast" then
                        slot.selectionGlow:Show()
                    else
                        slot.selectionGlow:Hide()
                    end
                else
                    slot.selectionGlow:Hide()
                end
            end
        end
    end

    -- Instructions
    local instrBlock = CreateFrame("Frame", nil, barsTab, "BackdropTemplate")
    instrBlock:SetPoint("TOPLEFT", 0, 0)
    instrBlock:SetPoint("TOPRIGHT", 0, 0)
    instrBlock:SetHeight(92)
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
    instrText:SetText("Infall mirrors your Cooldown Manager (CDM). Add abilities there, and they appear as rows below.\nUse the Buffs pool to pair buff or debuff tracking and stack counts. Use the Casts pool to pair filler casts.\nClick an icon in the pool, then click a slot on the row. Right click a paired slot to remove it.")

    local refreshBtn = CreateFrame("Button", nil, instrBlock, "UIPanelButtonTemplate")
    refreshBtn:SetSize(100, 22)
    refreshBtn:SetPoint("BOTTOMLEFT", 12, 10)
    refreshBtn:SetText("Refresh List")
    refreshBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Refresh")
        GameTooltip:AddLine("Re-reads abilities from the Cooldown Manager.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 12.1 Note, right aligned on the Refresh List row.
    local noteBtn = CreateFrame("Button", nil, instrBlock, "UIPanelButtonTemplate")
    noteBtn:SetSize(100, 22)
    noteBtn:SetPoint("BOTTOMRIGHT", -12, 10)
    noteBtn:SetText("12.1 Note")
    noteBtn:SetScript("OnClick", function()
        if ns.Migrate121 then ns.Migrate121.ShowNote() end
    end)
    noteBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("12.1 Note")
        GameTooltip:AddLine("Why buffs in Tracked Buffs are estimated, and which of yours are.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    noteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local cdmBtn = CreateFrame("Button", nil, instrBlock, "UIPanelButtonTemplate")
    cdmBtn:SetSize(180, 22)
    cdmBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 8, 0)
    cdmBtn:SetText("Open Cooldown Manager")
    cdmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Cooldown Manager")
        GameTooltip:AddLine("Opens WoW's Cooldown Manager settings panel.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cdmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cdmBtn:SetScript("OnClick", function()
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Cannot open the Cooldown Manager in combat. Try again out of combat.")
            return
        end
        if CooldownViewerSettings then
            -- Close settings panel so ShowUIPanel can open CDM
            if SettingsPanel then
                pcall(HideUIPanel, SettingsPanel)
            end
            C_Timer.After(0.1, function()
                pcall(ShowUIPanel, CooldownViewerSettings)
            end)
        else
            print("|cff00ff00[Infall]|r CooldownViewerSettings not available.")
        end
    end)

    -- Top panel: Cooldown Rows with visibility checkboxes and buff pairing
    local topPanel = CreateFrame("Frame", nil, barsTab, "BackdropTemplate")
    topPanel:SetPoint("TOPLEFT", 0, -96)
    topPanel:SetPoint("RIGHT", 0, 0)
    topPanel:SetHeight(250)
    topPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    topPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.5)
    topPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

    local topTitle = topPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    topTitle:SetPoint("TOPLEFT", 8, -6)
    topTitle:SetText("Cooldown Rows")

    -- Column headers (aligned with row layout)
    local colHeaders = {"Show", "", "", "Ability", "Buff 1", "Buff 2", "Buff 3", "Cast 1", "Cast 2", "Stack"}
    local colPositions = {6, 30, 48, 76, 190, 240, 290, 346, 396, 450}

    for i, text in ipairs(colHeaders) do
        local hdr = topPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hdr:SetPoint("TOPLEFT", colPositions[i], -20)
        hdr:SetText(text)
    end

    local topScroll, topContent = CreateScrollableContent(topPanel)
    topScroll:ClearAllPoints()
    topScroll:SetPoint("TOPLEFT", 4, -34)
    topScroll:SetPoint("BOTTOMRIGHT", -24, 4)

    -- Bottom panel: Spell Pools (tabbed: Buffs | Casts)
    local bottomPanel = CreateFrame("Frame", nil, barsTab, "BackdropTemplate")
    bottomPanel:SetPoint("TOPLEFT", topPanel, "BOTTOMLEFT", 0, -6)
    bottomPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    bottomPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    bottomPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.5)
    bottomPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

    -- Pool sub-tabs
    local poolTabButtons = {}
    local poolTabNames = {"Buffs", "Casts"}
    for i, name in ipairs(poolTabNames) do
        local tab = CreateFrame("Button", nil, bottomPanel, "PanelTabButtonTemplate")
        tab:SetText(name)
        PanelTemplates_TabResize(tab, 8)
        tab:SetID(i)
        if i == 1 then
            tab:SetPoint("TOPLEFT", 4, -2)
        else
            tab:SetPoint("LEFT", poolTabButtons[i - 1], "RIGHT", -8, 0)
        end
        poolTabButtons[i] = tab
    end

    -- Content frames for each pool tab
    local buffsPoolFrame = CreateFrame("Frame", nil, bottomPanel)
    buffsPoolFrame:SetPoint("TOPLEFT", poolTabButtons[1], "BOTTOMLEFT", 0, 2)
    buffsPoolFrame:SetPoint("BOTTOMRIGHT", 0, 0)

    local castsPoolFrame = CreateFrame("Frame", nil, bottomPanel)
    castsPoolFrame:SetPoint("TOPLEFT", poolTabButtons[1], "BOTTOMLEFT", 0, 2)
    castsPoolFrame:SetPoint("BOTTOMRIGHT", 0, 0)
    castsPoolFrame:Hide()

    -- Forward-declared for pool tab handlers
    local statusText

    local function SelectPoolTab(tabIndex)
        for i, tab in ipairs(poolTabButtons) do
            if i == tabIndex then
                PanelTemplates_SelectTab(tab)
            else
                PanelTemplates_DeselectTab(tab)
            end
        end
        buffsPoolFrame:SetShown(tabIndex == 1)
        castsPoolFrame:SetShown(tabIndex == 2)
        GameTooltip:Hide()
        CancelSelection()
        statusText:SetText("")
    end

    for i, tab in ipairs(poolTabButtons) do
        tab:SetScript("OnClick", function() SelectPoolTab(i) end)
    end
    PanelTemplates_SelectTab(poolTabButtons[1])
    PanelTemplates_DeselectTab(poolTabButtons[2])

    -- Buffs pool content
    local buffsHint = buffsPoolFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    buffsHint:SetPoint("TOPLEFT", 8, -6)
    buffsHint:SetWidth(700)
    buffsHint:SetJustifyH("LEFT")
    buffsHint:SetSpacing(2)
    buffsHint:SetText("Click a buff to select it, then click a Buff, or Stack slot above to pair it.\nBuffs only appear here if they are enabled in the Cooldown Manager. If a buff is missing, add it there first.")

    local buffsScroll, buffsContent = CreateScrollableContent(buffsPoolFrame)
    buffsScroll:ClearAllPoints()
    buffsScroll:SetPoint("TOPLEFT", 8, -32)
    buffsScroll:SetPoint("BOTTOMRIGHT", -24, 24)

    -- Casts pool content
    local castsHint = castsPoolFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    castsHint:SetPoint("TOPLEFT", 8, -6)
    castsHint:SetWidth(550)
    castsHint:SetJustifyH("LEFT")
    castsHint:SetSpacing(2)
    castsHint:SetText("Casts and channels from your spellbook. Click one, then click a Cast slot above.\nEach cast can only show on one bar at a time. Pairing it to a new bar moves it from the old one.")

    local castsScroll, castsContent = CreateScrollableContent(castsPoolFrame)
    castsScroll:ClearAllPoints()
    castsScroll:SetPoint("TOPLEFT", 8, -32)
    castsScroll:SetPoint("BOTTOMRIGHT", -24, 24)

    -- Status text: shows when a spell is selected
    statusText = bottomPanel:CreateFontString(nil, "OVERLAY", "GameFontGreen")
    statusText:SetPoint("BOTTOMRIGHT", -8, 6)
    statusText:SetText("")

    -- Slot frame (buff 1 or buff 2)
    local function CreateSlotFrame(parentRow, anchorFrame, anchorPoint, xOff)
        local slot = CreateFrame("Button", nil, parentRow, "BackdropTemplate")
        slot:SetSize(24, 24)
        slot:SetPoint("LEFT", anchorFrame, anchorPoint, xOff, 0)
        slot:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        slot:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
        slot:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)
        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local icon = slot:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        slot.icon = icon

        -- Selection glow (shown when a buff is selected and this slot is available)
        local glow = slot:CreateTexture(nil, "OVERLAY")
        glow:SetPoint("TOPLEFT", -2, 2)
        glow:SetPoint("BOTTOMRIGHT", 2, -2)
        glow:SetColorTexture(0.2, 1, 0.2, 0.35)
        glow:Hide()
        slot.selectionGlow = glow

        return slot
    end

    -- Inline colour swatch
    local function CreateSlotColorBtn(parentRow, anchorFrame)
        local btn = CreateFrame("Button", nil, parentRow)
        btn:SetSize(16, 16)
        btn:SetPoint("LEFT", anchorFrame, "RIGHT", 4, 0)

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 1)

        local tex = btn:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("TOPLEFT", 1, -1)
        tex:SetPoint("BOTTOMRIGHT", -1, 1)
        tex:SetColorTexture(0.4, 0.4, 0.9, 0.6)
        btn.tex = tex

        local procDot = btn:CreateTexture(nil, "OVERLAY", nil, 2)
        procDot:SetSize(6, 6)
        procDot:SetPoint("TOPRIGHT", -1, -1)
        procDot:SetColorTexture(1, 0.8, 0, 1)
        procDot:Hide()
        btn.procDot = procDot

        btn:Hide()

        return btn
    end

    -- Cached empty-state text (one per pool).
    local emptyRowsText, emptyBuffsText, emptyCastsText

    -- Wires up the Buff 1/2/3, Cast 1/2, and Stack slot widgets on a row.
    -- Used by Custom Rows in the Extras section. Reads + writes CONFIG.buffMappings[cooldownID],
    -- CONFIG.extraCasts[cooldownID], and CONFIG.stackMappings[cooldownID].
    local function WireSlots(row, cooldownID)
        local buff1Slot, buff1ColorBtn = row.buff1Slot, row.buff1ColorBtn
        local buff2Slot, buff2ColorBtn = row.buff2Slot, row.buff2ColorBtn
        local buff3Slot, buff3ColorBtn = row.buff3Slot, row.buff3ColorBtn
        local cast1Slot, cast1ColorBtn = row.cast1Slot, row.cast1ColorBtn
        local cast2Slot, cast2ColorBtn = row.cast2Slot, row.cast2ColorBtn
        local stackSlot, stackColorBtn = row.stackSlot, row.stackColorBtn

        buff1Slot.icon:Hide(); buff1Slot.pairedCooldownID = nil; buff1Slot.pairedColor = nil; buff1ColorBtn:Hide()
        buff2Slot.icon:Hide(); buff2Slot.pairedCooldownID = nil; buff2Slot.pairedColor = nil; buff2ColorBtn:Hide()
        buff3Slot.icon:Hide(); buff3Slot.pairedCooldownID = nil; buff3Slot.pairedColor = nil; buff3ColorBtn:Hide()
        cast1Slot.icon:Hide(); cast1Slot.pairedSpellID = nil; cast1Slot.pairedColor = nil; cast1ColorBtn:Hide()
        cast2Slot.icon:Hide(); cast2Slot.pairedSpellID = nil; cast2Slot.pairedColor = nil; cast2ColorBtn:Hide()
        stackSlot.icon:Hide(); stackSlot.pairedCooldownID = nil; stackSlot.pairedColor = nil; stackColorBtn:Hide()

        buff1Slot.slotType = "buff"; buff2Slot.slotType = "buff"; buff3Slot.slotType = "buff"
        cast1Slot.slotType = "cast"; cast2Slot.slotType = "cast"
        stackSlot.slotType = "stack"
        allSlotFrames[#allSlotFrames + 1] = buff1Slot
        allSlotFrames[#allSlotFrames + 1] = buff2Slot
        allSlotFrames[#allSlotFrames + 1] = buff3Slot
        allSlotFrames[#allSlotFrames + 1] = cast1Slot
        allSlotFrames[#allSlotFrames + 1] = cast2Slot
        allSlotFrames[#allSlotFrames + 1] = stackSlot

        -- Populate buff slots from mappings
        local mappings = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
        local function applyBuffSlot(slot, colorBtn, m)
            if not (m and m.buffCooldownIDs and m.buffCooldownIDs[1]) then return end
            local bID = m.buffCooldownIDs[1]
            local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, bID)
            local sID = infoOk and info and (info.overrideTooltipSpellID or info.overrideSpellID or info.spellID)
            local icon = sID and C_Spell.GetSpellTexture(sID) or 134400
            slot.icon:SetTexture(icon)
            slot.icon:Show()
            slot.pairedCooldownID = bID
            slot.pairedColor = m.color
            local c = m.color or (m.unit == "target" and CONFIG.debuffColor) or (m.unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
            colorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
            colorBtn:Show()
            colorBtn.procDot:SetShown(m.requireGlow == true)
        end
        if mappings then
            applyBuffSlot(buff1Slot, buff1ColorBtn, mappings[1])
            applyBuffSlot(buff2Slot, buff2ColorBtn, mappings[2])
            applyBuffSlot(buff3Slot, buff3ColorBtn, mappings[3])
        end

        -- Populate cast slots from extraCasts
        local extraCasts = CONFIG.extraCasts and CONFIG.extraCasts[cooldownID]
        if extraCasts then
            for slotIdx, slotPair in ipairs({{cast1Slot, cast1ColorBtn}, {cast2Slot, cast2ColorBtn}}) do
                local sID = extraCasts[slotIdx]
                if sID then
                    local icon = C_Spell.GetSpellTexture(sID) or 134400
                    slotPair[1].icon:SetTexture(icon)
                    slotPair[1].icon:Show()
                    slotPair[1].pairedSpellID = sID
                    local cc = CONFIG.castColors and CONFIG.castColors[sID]
                    slotPair[1].pairedColor = cc and DeepCopy(cc) or DeepCopy(CONFIG.castColor)
                    slotPair[2].tex:SetColorTexture(slotPair[1].pairedColor[1], slotPair[1].pairedColor[2], slotPair[1].pairedColor[3], slotPair[1].pairedColor[4] or 1)
                    slotPair[2]:Show()
                end
            end
        end

        -- Populate stack slot
        local stackMapping = CONFIG.stackMappings and CONFIG.stackMappings[cooldownID]
        if stackMapping and stackMapping.buffCooldownID then
            local sInfoOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, stackMapping.buffCooldownID)
            local sSID = sInfoOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
            local sIcon = sSID and C_Spell.GetSpellTexture(sSID) or 134400
            stackSlot.icon:SetTexture(sIcon)
            stackSlot.icon:Show()
            stackSlot.pairedCooldownID = stackMapping.buffCooldownID
            stackSlot.pairedColor = stackMapping.color and DeepCopy(stackMapping.color) or DeepCopy(CONFIG.stackTextColor)
            stackColorBtn.tex:SetColorTexture(stackSlot.pairedColor[1], stackSlot.pairedColor[2], stackSlot.pairedColor[3], stackSlot.pairedColor[4] or 1)
            stackColorBtn:Show()
        end

        -- Slot tooltips
        local function buffSlotTooltip(self, slotName)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.pairedCooldownID then
                local bOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                local bSpellID = bOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                local bName = bSpellID and C_Spell.GetSpellName(bSpellID) or ("ID:" .. tostring(self.pairedCooldownID))
                GameTooltip:SetText(slotName .. ": " .. bName, 1, 1, 1)
                GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
            else
                GameTooltip:SetText(slotName .. " Slot (empty)", 0.6, 0.6, 0.6)
                if selectedBuff then
                    GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                else
                    GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
        end
        buff1Slot:SetScript("OnEnter", function(self) buffSlotTooltip(self, "Buff 1") end)
        buff1Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buff2Slot:SetScript("OnEnter", function(self) buffSlotTooltip(self, "Buff 2") end)
        buff2Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buff3Slot:SetScript("OnEnter", function(self) buffSlotTooltip(self, "Buff 3") end)
        buff3Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local function PairBuff(slot, colorBtn, slotIndex)
            return function(self, button)
                if button == "RightButton" and self.pairedCooldownID then
                    self.pairedCooldownID = nil; self.pairedColor = nil
                    slot.icon:Hide(); colorBtn:Hide(); colorBtn.procDot:Hide()
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    if m then
                        if slotIndex == 1 then table.remove(m, 1)
                        elseif slotIndex == 2 and #m >= 2 then table.remove(m, 2)
                        elseif slotIndex == 3 and #m >= 3 then table.remove(m, 3) end
                    end
                    ns.SaveCurrentProfile(); LoadEssentialCooldowns(); RefreshCooldownRows()
                    return
                end
                if selectedType == "cast" then
                    statusText:SetText("|cffff6666Select a buff from the Buffs pool, not the Casts pool.|r"); return
                end
                if not selectedBuff or selectedType ~= "buff" then
                    SelectPoolTab(1)
                    statusText:SetText("|cff88bbffSelect a buff from the Buffs pool.|r"); return
                end
                -- Enforce slot ordering
                if slotIndex == 2 then
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    local s1 = m and m[1] and m[1].buffCooldownIDs and #m[1].buffCooldownIDs > 0
                    if not s1 then statusText:SetText("|cffff6666Pair Buff 1 first before using Buff 2.|r"); return end
                elseif slotIndex == 3 then
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    local s2 = m and m[2] and m[2].buffCooldownIDs and #m[2].buffCooldownIDs > 0
                    if not s2 then statusText:SetText("|cffff6666Pair Buff 1 and 2 first before using Buff 3.|r"); return end
                end
                local buffCdID = selectedBuff
                local bOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                local bSID = bOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                local bIcon = bSID and C_Spell.GetSpellTexture(bSID) or 134400
                slot.icon:SetTexture(bIcon); slot.icon:Show()
                self.pairedCooldownID = buffCdID
                local isDebuff = bSID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(bSID)
                local defaultColor = isDebuff and DeepCopy(CONFIG.debuffColor) or DeepCopy(CONFIG.buffColor)
                if slotIndex >= 2 then defaultColor[4] = 0.3 end
                self.pairedColor = defaultColor
                colorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                colorBtn:Show()
                CONFIG.buffMappings = CONFIG.buffMappings or {}
                CONFIG.buffMappings[cooldownID] = CONFIG.buffMappings[cooldownID] or {}
                local mapping = { buffCooldownIDs = {buffCdID}, color = defaultColor }
                if isDebuff then mapping.unit = "target" end
                CONFIG.buffMappings[cooldownID][slotIndex] = mapping
                ns.SaveCurrentProfile(); LoadEssentialCooldowns(); CancelSelection()
                statusText:SetText("")
            end
        end
        buff1Slot:SetScript("OnClick", PairBuff(buff1Slot, buff1ColorBtn, 1))
        buff2Slot:SetScript("OnClick", PairBuff(buff2Slot, buff2ColorBtn, 2))
        buff3Slot:SetScript("OnClick", PairBuff(buff3Slot, buff3ColorBtn, 3))

        local function buffColorBtnFor(slot, colorBtn, slotIndex)
            colorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            colorBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                GameTooltip:SetText("Buff " .. slotIndex .. " Colour")
                GameTooltip:AddLine("Click to change this buff's bar colour.", 0.7, 0.7, 0.7, true)
                if m and m[slotIndex] and m[slotIndex].requireGlow then
                    GameTooltip:AddLine("Proc only: ON (bar shows only when glowing)", 1, 0.8, 0, true)
                end
                GameTooltip:AddLine("Right click to toggle proc only mode.", 0.5, 0.8, 0.5, true)
                GameTooltip:Show()
            end)
            colorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            colorBtn:SetScript("OnClick", function(self, button)
                local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                if button == "RightButton" then
                    if m and m[slotIndex] then
                        m[slotIndex].requireGlow = not m[slotIndex].requireGlow
                        self.procDot:SetShown(m[slotIndex].requireGlow == true)
                        ns.SaveCurrentProfile()
                    end
                    return
                end
                local mapData = m and m[slotIndex]
                local defaultColor = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or (mapData and mapData.unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                local currentColor = (mapData and mapData.color) or slot.pairedColor or DeepCopy(defaultColor)
                if slotIndex >= 2 then currentColor[4] = currentColor[4] or 0.3 end
                OpenInlineColorPicker(currentColor, function(c)
                    colorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                    slot.pairedColor = c
                    if mapData then mapData.color = c end
                    ns.SaveCurrentProfile()
                end)
            end)
        end
        buffColorBtnFor(buff1Slot, buff1ColorBtn, 1)
        buffColorBtnFor(buff2Slot, buff2ColorBtn, 2)
        buffColorBtnFor(buff3Slot, buff3ColorBtn, 3)

        -- Cast slot tooltips
        local function castSlotTooltip(self, slotName)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.pairedSpellID then
                local cName = C_Spell.GetSpellName(self.pairedSpellID) or ("ID:" .. self.pairedSpellID)
                GameTooltip:SetText(slotName .. ": " .. cName, 1, 1, 1)
                GameTooltip:AddLine("Left click: replace with selected cast", 0.5, 0.8, 0.5)
                GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
            else
                GameTooltip:SetText(slotName .. " Slot (empty)", 0.6, 0.6, 0.6)
                if selectedType == "cast" then
                    GameTooltip:AddLine("Click to pair selected cast here", 0.5, 1, 0.5)
                else
                    GameTooltip:AddLine("Select a cast from the Casts pool", 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
        end
        cast1Slot:SetScript("OnEnter", function(self) castSlotTooltip(self, "Cast 1") end)
        cast1Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cast2Slot:SetScript("OnEnter", function(self) castSlotTooltip(self, "Cast 2") end)
        cast2Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local function PairCast(slot, colorBtn, castSlotIndex)
            return function(self, button)
                if button == "RightButton" and self.pairedSpellID then
                    local oldSID = self.pairedSpellID
                    self.pairedSpellID = nil; self.pairedColor = nil
                    slot.icon:Hide(); colorBtn:Hide()
                    local ec = CONFIG.extraCasts and CONFIG.extraCasts[cooldownID]
                    if ec then
                        if castSlotIndex == 1 then
                            table.remove(ec, 1)
                            if #ec == 0 then CONFIG.extraCasts[cooldownID] = nil end
                        elseif castSlotIndex == 2 and #ec >= 2 then
                            table.remove(ec, 2)
                        end
                    end
                    if oldSID and CONFIG.castColors then CONFIG.castColors[oldSID] = nil end
                    ns.SaveCurrentProfile(); LoadEssentialCooldowns(); RefreshCooldownRows()
                    return
                end
                if selectedType ~= "cast" or not selectedCast then
                    if selectedType == "buff" then
                        statusText:SetText("|cffff6666Select a cast from the Casts pool, not the Buffs pool.|r")
                    else
                        SelectPoolTab(2)
                        statusText:SetText("|cff88bbffSelect a cast from the Casts pool.|r")
                    end
                    return
                end
                if castSlotIndex == 2 then
                    local ec = CONFIG.extraCasts and CONFIG.extraCasts[cooldownID]
                    if not ec or not ec[1] then
                        statusText:SetText("|cffff6666Pair Cast 1 first before using Cast 2.|r"); return
                    end
                end
                local castSID = selectedCast
                local cIcon = C_Spell.GetSpellTexture(castSID) or 134400
                slot.icon:SetTexture(cIcon); slot.icon:Show()
                self.pairedSpellID = castSID
                local defaultColor = DeepCopy(CONFIG.castColor)
                self.pairedColor = defaultColor
                colorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                colorBtn:Show()
                CONFIG.extraCasts = CONFIG.extraCasts or {}
                CONFIG.extraCasts[cooldownID] = CONFIG.extraCasts[cooldownID] or {}
                CONFIG.extraCasts[cooldownID][castSlotIndex] = castSID
                CONFIG.castColors = CONFIG.castColors or {}
                CONFIG.castColors[castSID] = defaultColor
                ns.SaveCurrentProfile(); LoadEssentialCooldowns(); CancelSelection()
                statusText:SetText("")
            end
        end
        cast1Slot:SetScript("OnClick", PairCast(cast1Slot, cast1ColorBtn, 1))
        cast2Slot:SetScript("OnClick", PairCast(cast2Slot, cast2ColorBtn, 2))

        local function castColorBtnFor(slot, colorBtn, label)
            colorBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(label .. " Colour")
                GameTooltip:AddLine("Click to change this cast's bar colour.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            colorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            colorBtn:SetScript("OnClick", function()
                local currentColor = slot.pairedColor or DeepCopy(CONFIG.castColor)
                OpenInlineColorPicker(currentColor, function(c)
                    colorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                    slot.pairedColor = c
                    if slot.pairedSpellID then
                        CONFIG.castColors = CONFIG.castColors or {}
                        CONFIG.castColors[slot.pairedSpellID] = c
                    end
                    ns.SaveCurrentProfile()
                end)
            end)
        end
        castColorBtnFor(cast1Slot, cast1ColorBtn, "Cast 1")
        castColorBtnFor(cast2Slot, cast2ColorBtn, "Cast 2")

        -- Stack slot
        stackSlot:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.pairedCooldownID then
                local sOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                local sSID = sOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
                local sName = sSID and C_Spell.GetSpellName(sSID) or ("ID:" .. tostring(self.pairedCooldownID))
                GameTooltip:SetText("Stack: " .. sName, 1, 1, 1)
                GameTooltip:AddLine("Shows this buff's stack count on the icon", 0.7, 0.7, 0.7)
                GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
            else
                GameTooltip:SetText("Stack Slot (empty)", 0.6, 0.6, 0.6)
                if selectedType == "buff" then
                    GameTooltip:AddLine("Click to track selected buff's stacks here", 0.5, 1, 0.5)
                else
                    GameTooltip:AddLine("Select a buff from the Buffs pool", 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
        end)
        stackSlot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        stackSlot:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.pairedCooldownID then
                self.pairedCooldownID = nil; self.pairedColor = nil
                stackSlot.icon:Hide(); stackColorBtn:Hide()
                if CONFIG.stackMappings then CONFIG.stackMappings[cooldownID] = nil end
                ns.SaveCurrentProfile(); LoadEssentialCooldowns()
                return
            end
            if selectedType ~= "buff" or not selectedBuff then
                if selectedType == "cast" then
                    statusText:SetText("|cffff6666Select a buff from the Buffs pool, not the Casts pool.|r")
                else
                    SelectPoolTab(1)
                    statusText:SetText("|cff88bbffSelect a buff from the Buffs pool to track stacks.|r")
                end
                return
            end
            local buffCdID = selectedBuff
            local sOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
            local sSID = sOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
            local sIcon = sSID and C_Spell.GetSpellTexture(sSID) or 134400
            stackSlot.icon:SetTexture(sIcon); stackSlot.icon:Show()
            self.pairedCooldownID = buffCdID
            local defaultColor = DeepCopy(CONFIG.stackTextColor)
            self.pairedColor = defaultColor
            stackColorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
            stackColorBtn:Show()
            CONFIG.stackMappings = CONFIG.stackMappings or {}
            CONFIG.stackMappings[cooldownID] = { buffCooldownID = buffCdID, color = defaultColor }
            ns.SaveCurrentProfile(); LoadEssentialCooldowns(); CancelSelection()
            statusText:SetText("")
        end)

        stackColorBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Stack Text Colour")
            GameTooltip:AddLine("Click to change the stack count text colour for this row.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        stackColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        stackColorBtn:SetScript("OnClick", function()
            local currentColor = stackSlot.pairedColor or DeepCopy(CONFIG.stackTextColor)
            OpenInlineColorPicker(currentColor, function(c)
                stackColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                stackSlot.pairedColor = c
                local sm = CONFIG.stackMappings and CONFIG.stackMappings[cooldownID]
                if sm then sm.color = c end
                ns.SaveCurrentProfile()
            end)
        end)
    end

    -- Refresh Cooldown Rows
    RefreshCooldownRows = function()
        -- Frame recycling
        for i = 1, cooldownRowCacheCount do
            if cooldownRowCache[i] then cooldownRowCache[i]:Hide() end
        end
        wipe(allSlotFrames)

        local cooldownIDs = {}
        -- Use data provider if available, fall back to category set
        local foundSource = false
        if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
            local dataProvider = CooldownViewerSettings:GetDataProvider()
            if dataProvider and dataProvider.GetOrderedCooldownIDsForCategory then
                local displayed = dataProvider:GetOrderedCooldownIDsForCategory(0)
                if displayed and #displayed > 0 then
                    cooldownIDs = displayed
                    foundSource = true
                end
            end
        end
        if not foundSource then
            local success, result = pcall(function()
                return C_CooldownViewer.GetCooldownViewerCategorySet(0, false)
            end)
            if success and result then cooldownIDs = result end
        end

        local rowIndex = 0
        local yOffset = 0
        for _, cooldownID in ipairs(cooldownIDs) do
            local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
            if infoOk and cdInfo then
                rowIndex = rowIndex + 1
                local spellID = cdInfo.overrideTooltipSpellID or cdInfo.overrideSpellID or cdInfo.spellID
                local rName, rIcon = ns.ResolveCooldownDisplay(cooldownID, cdInfo)
                local spellName = rName or ("ID:" .. cooldownID)
                local spellIcon = rIcon or 134400
                local isHidden = CONFIG.hiddenCooldownIDs and (CONFIG.hiddenCooldownIDs[cooldownID] or (spellID and spellID ~= cooldownID and CONFIG.hiddenCooldownIDs[spellID]))

                local row = cooldownRowCache[rowIndex]
                if not row then
                    row = CreateFrame("Frame", nil, topContent)
                    row:SetSize(topContent:GetWidth() or 700, 28)
                    row.cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                    row.cb:SetPoint("LEFT", 2, 0)
                    row.cb:SetSize(22, 22)
                    row.cdColorBtn = CreateFrame("Button", nil, row)
                    row.cdColorBtn:SetSize(16, 16)
                    row.cdColorBtn:SetPoint("LEFT", row.cb, "RIGHT", 2, 0)
                    local cdBg = row.cdColorBtn:CreateTexture(nil, "BACKGROUND")
                    cdBg:SetAllPoints()
                    cdBg:SetColorTexture(0, 0, 0, 1)
                    row.cdColorBtn.tex = row.cdColorBtn:CreateTexture(nil, "OVERLAY")
                    row.cdColorBtn.tex:SetPoint("TOPLEFT", 1, -1)
                    row.cdColorBtn.tex:SetPoint("BOTTOMRIGHT", -1, 1)
                    row.abilIcon = row:CreateTexture(nil, "ARTWORK")
                    row.abilIcon:SetSize(24, 24)
                    row.abilIcon:SetPoint("LEFT", row.cdColorBtn, "RIGHT", 4, 0)
                    row.abilIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    row.iconBtn = CreateFrame("Button", nil, row)
                    row.iconBtn:SetAllPoints(row.abilIcon)
                    row.iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    local iconHl = row.iconBtn:CreateTexture(nil, "HIGHLIGHT")
                    iconHl:SetAllPoints()
                    iconHl:SetColorTexture(1, 0.82, 0, 0.18)
                    row.iconOverrideDot = row:CreateTexture(nil, "OVERLAY")
                    row.iconOverrideDot:SetSize(6, 6)
                    row.iconOverrideDot:SetPoint("TOPRIGHT", row.abilIcon, "TOPRIGHT", 1, 1)
                    row.iconOverrideDot:SetColorTexture(0.2, 1, 0.2, 1)
                    row.iconOverrideDot:Hide()
                    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    row.nameText:SetPoint("LEFT", row.abilIcon, "RIGHT", 4, 0)
                    row.nameText:SetWidth(106)
                    row.nameText:SetJustifyH("LEFT")
                    row.nameText:SetWordWrap(false)
                    row.buff1Slot = CreateSlotFrame(row, row.nameText, "RIGHT", 4)
                    row.buff1ColorBtn = CreateSlotColorBtn(row, row.buff1Slot)
                    row.buff2Slot = CreateSlotFrame(row, row.buff1ColorBtn, "RIGHT", 6)
                    row.buff2ColorBtn = CreateSlotColorBtn(row, row.buff2Slot)
                    row.buff3Slot = CreateSlotFrame(row, row.buff2ColorBtn, "RIGHT", 6)
                    row.buff3ColorBtn = CreateSlotColorBtn(row, row.buff3Slot)
                    row.cast1Slot = CreateSlotFrame(row, row.buff3ColorBtn, "RIGHT", 12)
                    row.cast1ColorBtn = CreateSlotColorBtn(row, row.cast1Slot)
                    row.cast2Slot = CreateSlotFrame(row, row.cast1ColorBtn, "RIGHT", 6)
                    row.cast2ColorBtn = CreateSlotColorBtn(row, row.cast2Slot)
                    row.stackSlot = CreateSlotFrame(row, row.cast2ColorBtn, "RIGHT", 12)
                    row.stackColorBtn = CreateSlotColorBtn(row, row.stackSlot)
                    row.chargeCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                    row.chargeCheck:SetPoint("LEFT", row.stackColorBtn, "RIGHT", 20, 0)
                    row.chargeCheck:SetSize(22, 22)
                    row.chargeCheck.text:SetFontObject(GameFontHighlightSmall)
                    row.chargeCheck.text:SetText("Show Charge")
                    row.chargeCheck:Hide()
                    cooldownRowCache[rowIndex] = row
                    cooldownRowCacheCount = math.max(cooldownRowCacheCount, rowIndex)
                end

                row:Show()
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, -yOffset)
                local customIconID = CONFIG.customIcons and CONFIG.customIcons[cooldownID]
                local displayIcon = customIconID and C_Spell.GetSpellTexture(customIconID) or spellIcon
                row.abilIcon:SetTexture(displayIcon)
                row.abilIcon:SetDesaturated(isHidden and true or false)
                if customIconID then
                    row.iconOverrideDot:Show()
                else
                    row.iconOverrideDot:Hide()
                end
                row.nameText:SetText(spellName)
                row.nameText:SetTextColor(isHidden and 0.5 or 1, isHidden and 0.5 or 0.82, isHidden and 0.5 or 0)
                row.cb:SetChecked(not isHidden)

                row.iconBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Bar Icon", 1, 1, 1)
                    local cur = CONFIG.customIcons and CONFIG.customIcons[cooldownID]
                    if cur then
                        local curName = C_Spell.GetSpellName(cur) or ("ID:" .. cur)
                        GameTooltip:AddLine("Custom: " .. curName, 0.4, 1, 0.4, true)
                        GameTooltip:AddLine("Left click to change. Right click to reset to the spell's own icon.", 0.7, 0.7, 0.7, true)
                    else
                        GameTooltip:AddLine("Left click to pick a custom icon. Right click resets to default.", 0.7, 0.7, 0.7, true)
                        GameTooltip:AddLine(" ", 1, 1, 1)
                        GameTooltip:AddLine("Note: a custom icon stays fixed and won't change when the spell transforms (IE Mindbender to Shadowfiend).", 0.6, 0.6, 0.8, true)
                    end
                    GameTooltip:Show()
                end)
                row.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.iconBtn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        if CONFIG.customIcons and CONFIG.customIcons[cooldownID] then
                            CONFIG.customIcons[cooldownID] = nil
                            ns.SaveCurrentProfile()
                            row.abilIcon:SetTexture(spellIcon)
                            row.iconOverrideDot:Hide()
                        end
                        return
                    end
                    OpenSpellPicker({
                        title = "Choose Bar Icon",
                        anchor = self,
                        onSelect = function(pickedID, pickedName, pickedIcon)
                            CONFIG.customIcons = CONFIG.customIcons or {}
                            CONFIG.customIcons[cooldownID] = pickedID
                            ns.SaveCurrentProfile()
                            local tex = pickedIcon or C_Spell.GetSpellTexture(pickedID)
                            if tex then row.abilIcon:SetTexture(tex) end
                            row.iconOverrideDot:Show()
                        end,
                    })
                end)

                local cdOverride = CONFIG.cooldownColors and CONFIG.cooldownColors[cooldownID]
                local cdColor = cdOverride or CONFIG.cooldownColor
                row.cdColorBtn.tex:SetColorTexture(cdColor[1], cdColor[2], cdColor[3], cdColor[4] or 1)
                row.cdColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                row.cdColorBtn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        if CONFIG.cooldownColors then
                            CONFIG.cooldownColors[cooldownID] = nil
                        end
                        self.tex:SetColorTexture(unpack(CONFIG.cooldownColor))
                        ns.SaveCurrentProfile()
                        ApplyLayoutToAllBars()
                        return
                    end
                    local currentColor = (CONFIG.cooldownColors and CONFIG.cooldownColors[cooldownID])
                        or DeepCopy(CONFIG.cooldownColor)
                    OpenInlineColorPicker(currentColor, function(c)
                        self.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        CONFIG.cooldownColors = CONFIG.cooldownColors or {}
                        CONFIG.cooldownColors[cooldownID] = c
                        DebouncedApplyAndSave()
                    end)
                end)
                row.cdColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Cooldown Colour")
                    local isOverridden = CONFIG.cooldownColors and CONFIG.cooldownColors[cooldownID]
                    if isOverridden then
                        GameTooltip:AddLine("Right click to reset to default.", 0.5, 0.8, 0.5, true)
                    else
                        GameTooltip:AddLine("Click to set a custom colour for this cooldown bar.", 0.7, 0.7, 0.7, true)
                    end
                    GameTooltip:Show()
                end)
                row.cdColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row.buff1Slot.icon:Hide()
                row.buff1Slot.pairedCooldownID = nil
                row.buff1Slot.pairedColor = nil
                row.buff1ColorBtn:Hide()
                row.buff2Slot.icon:Hide()
                row.buff2Slot.pairedCooldownID = nil
                row.buff2Slot.pairedColor = nil
                row.buff2ColorBtn:Hide()
                row.buff3Slot.icon:Hide()
                row.buff3Slot.pairedCooldownID = nil
                row.buff3Slot.pairedColor = nil
                row.buff3ColorBtn:Hide()
                row.cast1Slot.icon:Hide()
                row.cast1Slot.pairedSpellID = nil
                row.cast1Slot.pairedColor = nil
                row.cast1ColorBtn:Hide()
                row.cast2Slot.icon:Hide()
                row.cast2Slot.pairedSpellID = nil
                row.cast2Slot.pairedColor = nil
                row.cast2ColorBtn:Hide()
                row.stackSlot.icon:Hide()
                row.stackSlot.pairedCooldownID = nil
                row.stackSlot.pairedColor = nil
                row.stackColorBtn:Hide()

                local buff1Slot = row.buff1Slot
                local buff1ColorBtn = row.buff1ColorBtn
                local buff2Slot = row.buff2Slot
                local buff2ColorBtn = row.buff2ColorBtn
                local buff3Slot = row.buff3Slot
                local buff3ColorBtn = row.buff3ColorBtn
                local cast1Slot = row.cast1Slot
                local cast1ColorBtn = row.cast1ColorBtn
                local cast2Slot = row.cast2Slot
                local cast2ColorBtn = row.cast2ColorBtn
                local stackSlot = row.stackSlot
                local stackColorBtn = row.stackColorBtn
                local cb = row.cb
                local abilIcon = row.abilIcon
                local nameText = row.nameText
                buff1Slot.slotType = "buff"
                buff2Slot.slotType = "buff"
                buff3Slot.slotType = "buff"
                cast1Slot.slotType = "cast"
                cast2Slot.slotType = "cast"
                stackSlot.slotType = "stack"
                allSlotFrames[#allSlotFrames + 1] = buff1Slot
                allSlotFrames[#allSlotFrames + 1] = buff2Slot
                allSlotFrames[#allSlotFrames + 1] = buff3Slot
                allSlotFrames[#allSlotFrames + 1] = cast1Slot
                allSlotFrames[#allSlotFrames + 1] = cast2Slot
                allSlotFrames[#allSlotFrames + 1] = stackSlot

                cb:SetScript("OnClick", function(self)
                    CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
                    if self:GetChecked() then
                        CONFIG.hiddenCooldownIDs[cooldownID] = nil
                        abilIcon:SetDesaturated(false)
                        nameText:SetTextColor(1, 0.82, 0)
                    else
                        CONFIG.hiddenCooldownIDs[cooldownID] = true
                        abilIcon:SetDesaturated(true)
                        nameText:SetTextColor(0.5, 0.5, 0.5)
                    end
                    ns.SaveCurrentProfile()
                    LoadEssentialCooldowns()
                end)

                -- Charge toggle (only for spells with charges)
                local chargeCheck = row.chargeCheck
                local hasCharges = InfallDB.chargeSpells and InfallDB.chargeSpells[cooldownID]
                if hasCharges then
                    local isDisabled = CONFIG.chargesDisabled and CONFIG.chargesDisabled[cooldownID]
                    chargeCheck:SetChecked(not isDisabled)
                    chargeCheck:Show()
                    chargeCheck:SetScript("OnClick", function(self)
                        CONFIG.chargesDisabled = CONFIG.chargesDisabled or {}
                        if self:GetChecked() then
                            CONFIG.chargesDisabled[cooldownID] = nil
                        else
                            CONFIG.chargesDisabled[cooldownID] = true
                        end
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                    end)
                    chargeCheck:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Show Charge Bars", 1, 1, 1)
                        GameTooltip:AddLine("Shows a split bar for each charge. Disable for a single bar.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    chargeCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
                else
                    chargeCheck:SetChecked(false)
                    chargeCheck:Hide()
                end

                -- Tooltips for Buff 1
                buff1Slot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedCooldownID then
                        local bInfoOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                        local bSpellID = bInfoOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                        local bName = bSpellID and C_Spell.GetSpellName(bSpellID) or ("ID:" .. self.pairedCooldownID)
                        GameTooltip:SetText("Buff 1: " .. bName, 1, 1, 1)
                        GameTooltip:AddLine("CooldownID: " .. self.pairedCooldownID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Buff 1 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                buff1Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Tooltips for Buff 2
                buff2Slot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedCooldownID then
                        local oInfoOk, oInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                        local oSpellID = oInfoOk and oInfo and (oInfo.overrideTooltipSpellID or oInfo.overrideSpellID or oInfo.spellID)
                        local oName = oSpellID and C_Spell.GetSpellName(oSpellID) or ("ID:" .. self.pairedCooldownID)
                        GameTooltip:SetText("Buff 2: " .. oName, 1, 1, 1)
                        GameTooltip:AddLine("CooldownID: " .. self.pairedCooldownID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Buff 2 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                buff2Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Tooltips for Buff 3
                buff3Slot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedCooldownID then
                        local tInfoOk, tInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                        local tSpellID = tInfoOk and tInfo and (tInfo.overrideTooltipSpellID or tInfo.overrideSpellID or tInfo.spellID)
                        local tName = tSpellID and C_Spell.GetSpellName(tSpellID) or ("ID:" .. self.pairedCooldownID)
                        GameTooltip:SetText("Buff 3: " .. tName, 1, 1, 1)
                        GameTooltip:AddLine("CooldownID: " .. self.pairedCooldownID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Buff 3 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                buff3Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Look up by CDM cooldownID first, fall back to spellID.
                local mappings = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                if not mappings and spellID and spellID ~= cooldownID and CONFIG.buffMappings then
                    mappings = CONFIG.buffMappings[spellID]
                    if mappings then
                        -- Migrate to CDM cooldownID so future lookups work directly
                        CONFIG.buffMappings[cooldownID] = mappings
                        CONFIG.buffMappings[spellID] = nil
                        ns.SaveCurrentProfile()
                    end
                end
                if mappings then
                    -- First mapping -> Buff 1 slot
                    if mappings[1] and mappings[1].buffCooldownIDs and mappings[1].buffCooldownIDs[1] then
                        local buffCdID = mappings[1].buffCooldownIDs[1]
                        local bInfoOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                        local bSpellID = bInfoOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                        local bIcon = bSpellID and C_Spell.GetSpellTexture(bSpellID) or 134400
                        buff1Slot.icon:SetTexture(bIcon)
                        buff1Slot.icon:Show()
                        buff1Slot.pairedCooldownID = buffCdID
                        buff1Slot.pairedColor = mappings[1].color

                        local bc = mappings[1].color or (mappings[1].unit == "target" and CONFIG.debuffColor) or (mappings[1].unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                        buff1ColorBtn.tex:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1)
                        buff1ColorBtn:Show()
                        buff1ColorBtn.procDot:SetShown(mappings[1].requireGlow == true)
                    end
                    -- Second mapping -> Buff 2 slot
                    if mappings[2] and mappings[2].buffCooldownIDs and mappings[2].buffCooldownIDs[1] then
                        local buff2CdID = mappings[2].buffCooldownIDs[1]
                        local oInfoOk, oInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buff2CdID)
                        local oSpellID = oInfoOk and oInfo and (oInfo.overrideTooltipSpellID or oInfo.overrideSpellID or oInfo.spellID)
                        local oIcon = oSpellID and C_Spell.GetSpellTexture(oSpellID) or 134400
                        buff2Slot.icon:SetTexture(oIcon)
                        buff2Slot.icon:Show()
                        buff2Slot.pairedCooldownID = buff2CdID
                        buff2Slot.pairedColor = mappings[2].color

                        local oc = mappings[2].color or (mappings[2].unit == "target" and CONFIG.debuffColor) or (mappings[2].unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                        buff2ColorBtn.tex:SetColorTexture(oc[1], oc[2], oc[3], oc[4] or 1)
                        buff2ColorBtn:Show()
                        buff2ColorBtn.procDot:SetShown(mappings[2].requireGlow == true)
                    end
                    -- Third mapping -> Buff 3 slot
                    if mappings[3] and mappings[3].buffCooldownIDs and mappings[3].buffCooldownIDs[1] then
                        local buff3CdID = mappings[3].buffCooldownIDs[1]
                        local tInfoOk, tInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buff3CdID)
                        local tSpellID = tInfoOk and tInfo and (tInfo.overrideTooltipSpellID or tInfo.overrideSpellID or tInfo.spellID)
                        local tIcon = tSpellID and C_Spell.GetSpellTexture(tSpellID) or 134400
                        buff3Slot.icon:SetTexture(tIcon)
                        buff3Slot.icon:Show()
                        buff3Slot.pairedCooldownID = buff3CdID
                        buff3Slot.pairedColor = mappings[3].color

                        local tc = mappings[3].color or (mappings[3].unit == "target" and CONFIG.debuffColor) or (mappings[3].unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                        buff3ColorBtn.tex:SetColorTexture(tc[1], tc[2], tc[3], tc[4] or 1)
                        buff3ColorBtn:Show()
                        buff3ColorBtn.procDot:SetShown(mappings[3].requireGlow == true)
                    end
                end

                local function PairToSlot(slot, colorBtn, slotIndex)
                    return function(self, button)
                        if button == "RightButton" and self.pairedCooldownID then
                            -- Unpair
                            self.pairedCooldownID = nil
                            self.pairedColor = nil
                            slot.icon:Hide()
                            colorBtn:Hide()
                            colorBtn.procDot:Hide()
                            local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                            if m then
                                if slotIndex == 1 then
                                    table.remove(m, 1)
                                elseif slotIndex == 2 and #m >= 2 then
                                    table.remove(m, 2)
                                elseif slotIndex == 3 and #m >= 3 then
                                    table.remove(m, 3)
                                end
                            end
                            ns.SaveCurrentProfile()
                            LoadEssentialCooldowns()
                            RefreshCooldownRows()
                            return
                        end
                        if selectedType == "cast" then
                            statusText:SetText("|cffff6666Select a buff from the Buffs pool, not the Casts pool.|r")
                            return
                        end
                        if not selectedBuff or selectedType ~= "buff" then
                            SelectPoolTab(1)
                            statusText:SetText("|cff88bbffSelect a buff from the Buffs pool.|r")
                            return
                        end
                        if selectedBuff then
                            -- Enforce slot ordering
                            if slotIndex == 2 then
                                local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                                local slot1Valid = m and m[1] and m[1].buffCooldownIDs and #m[1].buffCooldownIDs > 0
                                if not slot1Valid then
                                    statusText:SetText("|cffff6666Pair Buff 1 first before using Buff 2.|r")
                                    return
                                end
                            elseif slotIndex == 3 then
                                local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                                local slot2Valid = m and m[2] and m[2].buffCooldownIDs and #m[2].buffCooldownIDs > 0
                                if not slot2Valid then
                                    statusText:SetText("|cffff6666Pair Buff 1 and 2 first before using Buff 3.|r")
                                    return
                                end
                            end

                            local buffCdID = selectedBuff
                            local bInfoOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                            local bSpellID = bInfoOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                            local bIcon = bSpellID and C_Spell.GetSpellTexture(bSpellID) or 134400
                            slot.icon:SetTexture(bIcon)
                            slot.icon:Show()
                            self.pairedCooldownID = buffCdID

                            local isDebuff = bSpellID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(bSpellID)
                            local defaultColor = isDebuff and DeepCopy(CONFIG.debuffColor) or DeepCopy(CONFIG.buffColor)
                            if slotIndex >= 2 then defaultColor[4] = 0.3 end
                            self.pairedColor = defaultColor

                            colorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                            colorBtn:Show()

                            CONFIG.buffMappings = CONFIG.buffMappings or {}
                            CONFIG.buffMappings[cooldownID] = CONFIG.buffMappings[cooldownID] or {}
                            local mapping = {
                                buffCooldownIDs = {buffCdID},
                                color = defaultColor,
                            }
                            if isDebuff then mapping.unit = "target" end
                            CONFIG.buffMappings[cooldownID][slotIndex] = mapping
                            ns.SaveCurrentProfile()
                            LoadEssentialCooldowns()
                            CancelSelection()
                            statusText:SetText("")
                        end
                    end
                end

                buff1Slot:SetScript("OnClick", PairToSlot(buff1Slot, buff1ColorBtn, 1))
                buff2Slot:SetScript("OnClick", PairToSlot(buff2Slot, buff2ColorBtn, 2))
                buff3Slot:SetScript("OnClick", PairToSlot(buff3Slot, buff3ColorBtn, 3))

                -- Colour picker for Buff 1
                buff1ColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                buff1ColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    GameTooltip:SetText("Buff 1 Colour")
                    GameTooltip:AddLine("Click to change this buff's bar colour.", 0.7, 0.7, 0.7, true)
                    if m and m[1] and m[1].requireGlow then
                        GameTooltip:AddLine("Proc only: ON (bar shows only when glowing)", 1, 0.8, 0, true)
                    end
                    GameTooltip:AddLine("Right click to toggle proc only mode.", 0.5, 0.8, 0.5, true)
                    GameTooltip:Show()
                end)
                buff1ColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                buff1ColorBtn:SetScript("OnClick", function(self, button)
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    if button == "RightButton" then
                        if m and m[1] then
                            m[1].requireGlow = not m[1].requireGlow
                            self.procDot:SetShown(m[1].requireGlow == true)
                            ns.SaveCurrentProfile()
                        end
                        return
                    end
                    local mapData = m and m[1]
                    local defaultColor = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or (mapData and mapData.unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                    local currentColor = (mapData and mapData.color) or buff1Slot.pairedColor or DeepCopy(defaultColor)
                    OpenInlineColorPicker(currentColor, function(c)
                        buff1ColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        buff1Slot.pairedColor = c
                        if mapData then mapData.color = c end
                        ns.SaveCurrentProfile()
                    end)
                end)

                -- Colour picker for Buff 2
                buff2ColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                buff2ColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    GameTooltip:SetText("Buff 2 Colour")
                    GameTooltip:AddLine("Click to change this buff's bar colour.", 0.7, 0.7, 0.7, true)
                    if m and m[2] and m[2].requireGlow then
                        GameTooltip:AddLine("Proc only: ON (bar shows only when glowing)", 1, 0.8, 0, true)
                    end
                    GameTooltip:AddLine("Right click to toggle proc only mode.", 0.5, 0.8, 0.5, true)
                    GameTooltip:Show()
                end)
                buff2ColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                buff2ColorBtn:SetScript("OnClick", function(self, button)
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    if button == "RightButton" then
                        if m and m[2] then
                            m[2].requireGlow = not m[2].requireGlow
                            self.procDot:SetShown(m[2].requireGlow == true)
                            ns.SaveCurrentProfile()
                        end
                        return
                    end
                    local mapData = m and m[2]
                    local defaultColor2 = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or (mapData and mapData.unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                    local currentColor = (mapData and mapData.color) or buff2Slot.pairedColor or DeepCopy(defaultColor2)
                    currentColor[4] = currentColor[4] or 0.3
                    OpenInlineColorPicker(currentColor, function(c)
                        buff2ColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        buff2Slot.pairedColor = c
                        if mapData then mapData.color = c end
                        ns.SaveCurrentProfile()
                    end)
                end)

                -- Colour picker for Buff 3
                buff3ColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                buff3ColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    GameTooltip:SetText("Buff 3 Colour")
                    GameTooltip:AddLine("Click to change this buff's bar colour.", 0.7, 0.7, 0.7, true)
                    if m and m[3] and m[3].requireGlow then
                        GameTooltip:AddLine("Proc only: ON (bar shows only when glowing)", 1, 0.8, 0, true)
                    end
                    GameTooltip:AddLine("Right click to toggle proc only mode.", 0.5, 0.8, 0.5, true)
                    GameTooltip:Show()
                end)
                buff3ColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                buff3ColorBtn:SetScript("OnClick", function(self, button)
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    if button == "RightButton" then
                        if m and m[3] then
                            m[3].requireGlow = not m[3].requireGlow
                            self.procDot:SetShown(m[3].requireGlow == true)
                            ns.SaveCurrentProfile()
                        end
                        return
                    end
                    local mapData = m and m[3]
                    local defaultColor3 = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or (mapData and mapData.unit == "pet" and CONFIG.petBuffColor) or CONFIG.buffColor
                    local currentColor = (mapData and mapData.color) or buff3Slot.pairedColor or DeepCopy(defaultColor3)
                    currentColor[4] = currentColor[4] or 0.3
                    OpenInlineColorPicker(currentColor, function(c)
                        buff3ColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        buff3Slot.pairedColor = c
                        if mapData then mapData.color = c end
                        ns.SaveCurrentProfile()
                    end)
                end)

                -- Tooltips for Cast 1
                cast1Slot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedSpellID then
                        local cName = C_Spell.GetSpellName(self.pairedSpellID) or ("ID:" .. self.pairedSpellID)
                        GameTooltip:SetText("Cast 1: " .. cName, 1, 1, 1)
                        GameTooltip:AddLine("SpellID: " .. self.pairedSpellID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected cast", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Cast 1 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedType == "cast" then
                            GameTooltip:AddLine("Click to pair selected cast here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a cast from the Casts pool", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                cast1Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Tooltips for Cast 2
                cast2Slot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedSpellID then
                        local cName = C_Spell.GetSpellName(self.pairedSpellID) or ("ID:" .. self.pairedSpellID)
                        GameTooltip:SetText("Cast 2: " .. cName, 1, 1, 1)
                        GameTooltip:AddLine("SpellID: " .. self.pairedSpellID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected cast", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Cast 2 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedType == "cast" then
                            GameTooltip:AddLine("Click to pair selected cast here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a cast from the Casts pool", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                cast2Slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Tooltips for Stack
                stackSlot:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.pairedCooldownID then
                        local sInfoOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, self.pairedCooldownID)
                        local sSpellID = sInfoOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
                        local sName = sSpellID and C_Spell.GetSpellName(sSpellID) or ("ID:" .. self.pairedCooldownID)
                        GameTooltip:SetText("Stack: " .. sName, 1, 1, 1)
                        GameTooltip:AddLine("CooldownID: " .. self.pairedCooldownID, 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Shows this buff's stack count on the icon", 0.7, 0.7, 0.7)
                        GameTooltip:AddLine("Left click: replace with selected buff", 0.5, 0.8, 0.5)
                        GameTooltip:AddLine("Right click: remove pairing", 1, 0.5, 0.5)
                    else
                        GameTooltip:SetText("Stack Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedType == "buff" then
                            GameTooltip:AddLine("Click to track selected buff's stacks here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool", 0.7, 0.7, 0.7)
                        end
                    end
                    GameTooltip:Show()
                end)
                stackSlot:SetScript("OnLeave", function() GameTooltip:Hide() end)

                local extraCasts = CONFIG.extraCasts and (CONFIG.extraCasts[cooldownID] or (spellID and spellID ~= cooldownID and CONFIG.extraCasts[spellID]))
                if extraCasts and spellID and spellID ~= cooldownID and CONFIG.extraCasts[spellID] and not CONFIG.extraCasts[cooldownID] then
                    -- Migrate to CDM cooldownID
                    CONFIG.extraCasts[cooldownID] = extraCasts
                    CONFIG.extraCasts[spellID] = nil
                    ns.SaveCurrentProfile()
                end
                if extraCasts then
                    if extraCasts[1] then
                        local cIcon = C_Spell.GetSpellTexture(extraCasts[1]) or 134400
                        cast1Slot.icon:SetTexture(cIcon)
                        cast1Slot.icon:Show()
                        cast1Slot.pairedSpellID = extraCasts[1]
                        local cc = CONFIG.castColors and CONFIG.castColors[extraCasts[1]]
                        cast1Slot.pairedColor = cc and DeepCopy(cc) or DeepCopy(CONFIG.castColor)
                        cast1ColorBtn.tex:SetColorTexture(cast1Slot.pairedColor[1], cast1Slot.pairedColor[2], cast1Slot.pairedColor[3], cast1Slot.pairedColor[4] or 1)
                        cast1ColorBtn:Show()
                    end
                    if extraCasts[2] then
                        local cIcon = C_Spell.GetSpellTexture(extraCasts[2]) or 134400
                        cast2Slot.icon:SetTexture(cIcon)
                        cast2Slot.icon:Show()
                        cast2Slot.pairedSpellID = extraCasts[2]
                        local cc = CONFIG.castColors and CONFIG.castColors[extraCasts[2]]
                        cast2Slot.pairedColor = cc and DeepCopy(cc) or DeepCopy(CONFIG.castColor)
                        cast2ColorBtn.tex:SetColorTexture(cast2Slot.pairedColor[1], cast2Slot.pairedColor[2], cast2Slot.pairedColor[3], cast2Slot.pairedColor[4] or 1)
                        cast2ColorBtn:Show()
                    end
                end

                local stackMapping = CONFIG.stackMappings and CONFIG.stackMappings[cooldownID]
                if stackMapping and stackMapping.buffCooldownID then
                    local sInfoOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, stackMapping.buffCooldownID)
                    local sSpellID = sInfoOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
                    local sIcon = sSpellID and C_Spell.GetSpellTexture(sSpellID) or 134400
                    stackSlot.icon:SetTexture(sIcon)
                    stackSlot.icon:Show()
                    stackSlot.pairedCooldownID = stackMapping.buffCooldownID
                    stackSlot.pairedColor = stackMapping.color and DeepCopy(stackMapping.color) or DeepCopy(CONFIG.stackTextColor)
                    stackColorBtn.tex:SetColorTexture(stackSlot.pairedColor[1], stackSlot.pairedColor[2], stackSlot.pairedColor[3], stackSlot.pairedColor[4] or 1)
                    stackColorBtn:Show()
                end

                local function PairToCastSlot(slot, colorBtn, castSlotIndex)
                    return function(self, button)
                        if button == "RightButton" and self.pairedSpellID then
                            -- Unpair cast
                            local oldSpellID = self.pairedSpellID
                            self.pairedSpellID = nil
                            self.pairedColor = nil
                            slot.icon:Hide()
                            colorBtn:Hide()
                            local ec = CONFIG.extraCasts and CONFIG.extraCasts[cooldownID]
                            if ec then
                                if castSlotIndex == 1 then
                                    table.remove(ec, 1)
                                    if #ec == 0 then CONFIG.extraCasts[cooldownID] = nil end
                                elseif castSlotIndex == 2 and #ec >= 2 then
                                    table.remove(ec, 2)
                                end
                            end
                            if oldSpellID and CONFIG.castColors then
                                CONFIG.castColors[oldSpellID] = nil
                            end
                            ns.SaveCurrentProfile()
                            LoadEssentialCooldowns()
                            RefreshCooldownRows()
                            return
                        end
                        if selectedType ~= "cast" or not selectedCast then
                            if selectedType == "buff" then
                                statusText:SetText("|cffff6666Select a cast from the Casts pool, not the Buffs pool.|r")
                            else
                                -- No selection: switch to Casts pool tab as guidance
                                SelectPoolTab(2)
                                statusText:SetText("|cff88bbffSelect a cast from the Casts pool.|r")
                            end
                            return
                        end
                        -- Enforce cast 1 before cast 2
                        if castSlotIndex == 2 then
                            local ec = CONFIG.extraCasts and CONFIG.extraCasts[cooldownID]
                            if not ec or not ec[1] then
                                statusText:SetText("|cffff6666Pair Cast 1 first before using Cast 2.|r")
                                return
                            end
                        end

                        local castSpellID = selectedCast
                        local cIcon = C_Spell.GetSpellTexture(castSpellID) or 134400
                        slot.icon:SetTexture(cIcon)
                        slot.icon:Show()
                        self.pairedSpellID = castSpellID

                        local defaultColor = DeepCopy(CONFIG.castColor)
                        self.pairedColor = defaultColor
                        colorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                        colorBtn:Show()

                        CONFIG.extraCasts = CONFIG.extraCasts or {}
                        CONFIG.extraCasts[cooldownID] = CONFIG.extraCasts[cooldownID] or {}
                        CONFIG.extraCasts[cooldownID][castSlotIndex] = castSpellID
                        CONFIG.castColors = CONFIG.castColors or {}
                        CONFIG.castColors[castSpellID] = defaultColor
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        CancelSelection()
                        statusText:SetText("")
                    end
                end

                cast1Slot:SetScript("OnClick", PairToCastSlot(cast1Slot, cast1ColorBtn, 1))
                cast2Slot:SetScript("OnClick", PairToCastSlot(cast2Slot, cast2ColorBtn, 2))

                stackSlot:SetScript("OnClick", function(self, button)
                    if button == "RightButton" and self.pairedCooldownID then
                        -- Unpair stack
                        self.pairedCooldownID = nil
                        self.pairedColor = nil
                        stackSlot.icon:Hide()
                        stackColorBtn:Hide()
                        if CONFIG.stackMappings then
                            CONFIG.stackMappings[cooldownID] = nil
                        end
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        return
                    end
                    if selectedType ~= "buff" or not selectedBuff then
                        if selectedType == "cast" then
                            statusText:SetText("|cffff6666Select a buff from the Buffs pool, not the Casts pool.|r")
                        else
                            SelectPoolTab(1)
                            statusText:SetText("|cff88bbffSelect a buff from the Buffs pool to track stacks.|r")
                        end
                        return
                    end

                    local buffCdID = selectedBuff
                    local sInfoOk, sInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                    local sSpellID = sInfoOk and sInfo and (sInfo.overrideTooltipSpellID or sInfo.overrideSpellID or sInfo.spellID)
                    local sIcon = sSpellID and C_Spell.GetSpellTexture(sSpellID) or 134400
                    stackSlot.icon:SetTexture(sIcon)
                    stackSlot.icon:Show()
                    self.pairedCooldownID = buffCdID

                    local defaultColor = DeepCopy(CONFIG.stackTextColor)
                    self.pairedColor = defaultColor
                    stackColorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                    stackColorBtn:Show()

                    CONFIG.stackMappings = CONFIG.stackMappings or {}
                    CONFIG.stackMappings[cooldownID] = {
                        buffCooldownID = buffCdID,
                        color = defaultColor,
                    }
                    ns.SaveCurrentProfile()
                    LoadEssentialCooldowns()
                    CancelSelection()
                    statusText:SetText("")
                end)

                -- Colour picker for Cast 1
                cast1ColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Cast 1 Colour")
                    GameTooltip:AddLine("Click to change this cast's bar colour.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                cast1ColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                cast1ColorBtn:SetScript("OnClick", function()
                    local currentColor = cast1Slot.pairedColor or DeepCopy(CONFIG.castColor)
                    OpenInlineColorPicker(currentColor, function(c)
                        cast1ColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        cast1Slot.pairedColor = c
                        if cast1Slot.pairedSpellID then
                            CONFIG.castColors = CONFIG.castColors or {}
                            CONFIG.castColors[cast1Slot.pairedSpellID] = c
                        end
                        ns.SaveCurrentProfile()
                    end)
                end)

                -- Colour picker for Cast 2
                cast2ColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Cast 2 Colour")
                    GameTooltip:AddLine("Click to change this cast's bar colour.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                cast2ColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                cast2ColorBtn:SetScript("OnClick", function()
                    local currentColor = cast2Slot.pairedColor or DeepCopy(CONFIG.castColor)
                    OpenInlineColorPicker(currentColor, function(c)
                        cast2ColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        cast2Slot.pairedColor = c
                        if cast2Slot.pairedSpellID then
                            CONFIG.castColors = CONFIG.castColors or {}
                            CONFIG.castColors[cast2Slot.pairedSpellID] = c
                        end
                        ns.SaveCurrentProfile()
                    end)
                end)

                -- Colour picker for Stack
                stackColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Stack Text Colour")
                    GameTooltip:AddLine("Click to change the stack count text colour for this row.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                stackColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                stackColorBtn:SetScript("OnClick", function()
                    local currentColor = stackSlot.pairedColor or DeepCopy(CONFIG.stackTextColor)
                    OpenInlineColorPicker(currentColor, function(c)
                        stackColorBtn.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        stackSlot.pairedColor = c
                        local sm = CONFIG.stackMappings and CONFIG.stackMappings[cooldownID]
                        if sm then sm.color = c end
                        ns.SaveCurrentProfile()
                    end)
                end)

                yOffset = yOffset + 30
            end
        end

        for i = rowIndex + 1, cooldownRowCacheCount do
            if cooldownRowCache[i] then cooldownRowCache[i]:Hide() end
        end

        -- Extras section (Racials, Potions, Trinkets, and user added Custom Rows)
        for i = 1, extrasRowCacheCount do
            if extrasRowCache[i] then extrasRowCache[i]:Hide() end
        end
        for i = 1, customRowCacheCount do
            if customRowCache[i] then customRowCache[i]:Hide() end
        end
        if extrasHeaderFrame then extrasHeaderFrame:Hide() end

        if CONFIG.extras and #CONFIG.extras > 0 then
            yOffset = yOffset + 6

            if not extrasHeaderFrame then
                extrasHeaderFrame = CreateFrame("Frame", nil, topContent)
                extrasHeaderFrame:SetSize(topContent:GetWidth() or 700, 86)
                extrasHeaderFrame.text = extrasHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                extrasHeaderFrame.text:SetPoint("TOPLEFT", 6, 0)
                extrasHeaderFrame.text:SetText("Extras")
                extrasHeaderFrame.note = extrasHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                extrasHeaderFrame.note:SetPoint("TOPLEFT", extrasHeaderFrame.text, "BOTTOMLEFT", 0, -2)
                if ns.AuraCompat and ns.AuraCompat.IS_121 then
                    extrasHeaderFrame.note:SetText("Racials now come from the Cooldown Manager. Add them there for exact timing.")
                else
                    extrasHeaderFrame.note:SetText("These can only be shown either above or below the cooldown manager bars.")
                end
                extrasHeaderFrame.note:SetTextColor(0.6, 0.6, 0.6)
                -- Position buttons
                extrasHeaderFrame.posLabel = extrasHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                extrasHeaderFrame.posLabel:SetPoint("TOPLEFT", extrasHeaderFrame.note, "BOTTOMLEFT", 0, -8)
                extrasHeaderFrame.posLabel:SetText("Position")
                extrasHeaderFrame.posTop = CreateFrame("Button", nil, extrasHeaderFrame, "UIPanelButtonTemplate")
                extrasHeaderFrame.posTop:SetSize(60, 22)
                extrasHeaderFrame.posTop:SetPoint("LEFT", extrasHeaderFrame.posLabel, "RIGHT", 10, 0)
                extrasHeaderFrame.posTop:SetText("Top")
                extrasHeaderFrame.posBot = CreateFrame("Button", nil, extrasHeaderFrame, "UIPanelButtonTemplate")
                extrasHeaderFrame.posBot:SetSize(60, 22)
                extrasHeaderFrame.posBot:SetPoint("LEFT", extrasHeaderFrame.posTop, "RIGHT", 4, 0)
                extrasHeaderFrame.posBot:SetText("Bottom")
                -- + Add Custom Row button (below position buttons, aligned right with Bottom)
                extrasHeaderFrame.addCustom = CreateFrame("Button", nil, extrasHeaderFrame, "UIPanelButtonTemplate")
                extrasHeaderFrame.addCustom:SetHeight(22)
                extrasHeaderFrame.addCustom:SetPoint("TOPLEFT", extrasHeaderFrame.posLabel, "BOTTOMLEFT", 0, -14)
                extrasHeaderFrame.addCustom:SetPoint("RIGHT", extrasHeaderFrame.posBot, "RIGHT", 0, 0)
                extrasHeaderFrame.addCustom:SetText("+ Add Custom Row")
                extrasHeaderFrame.addCustom:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Add Custom Row")
                    GameTooltip:AddLine("Creates an extra row with no cooldown. Pick an icon, then assign Buff 1, Buff 2, Buff 3, Cast 1, Cast 2, and Stack like any other row. Type a spell ID in the search box to use icons not in your spellbook.", 0.7, 0.7, 0.7, true)
                    GameTooltip:Show()
                end)
                extrasHeaderFrame.addCustom:SetScript("OnLeave", function() GameTooltip:Hide() end)
                extrasHeaderFrame.addCustom:SetScript("OnClick", function(self)
                    OpenSpellPicker({
                        title = "Pick Icon for Custom Row",
                        anchor = self,
                        onSelect = function(pickedID, pickedName, pickedIcon)
                            CONFIG.extras = CONFIG.extras or {}
                            local n = 1
                            local keyTaken = {}
                            for _, e in ipairs(CONFIG.extras) do keyTaken[e.key] = true end
                            while keyTaken["custom_" .. n] do n = n + 1 end
                            table.insert(CONFIG.extras, {
                                key = "custom_" .. n,
                                type = "custom",
                                iconSpellID = pickedID,
                                iconTexture = pickedIcon,
                                label = pickedName,
                                enabled = true,
                            })
                            ns.SaveCurrentProfile()
                            LoadEssentialCooldowns()
                            RefreshCooldownRows()
                        end,
                    })
                end)
            end
            local function UpdateExtrasPosHighlight()
                local pos = CONFIG.extrasPosition or "BOTTOM"
                extrasHeaderFrame.posTop:SetEnabled(pos ~= "TOP")
                extrasHeaderFrame.posBot:SetEnabled(pos ~= "BOTTOM")
            end
            extrasHeaderFrame.posTop:SetScript("OnClick", function()
                CONFIG.extrasPosition = "TOP"
                UpdateExtrasPosHighlight()
                ns.SaveCurrentProfile()
                LoadEssentialCooldowns()
            end)
            extrasHeaderFrame.posBot:SetScript("OnClick", function()
                CONFIG.extrasPosition = "BOTTOM"
                UpdateExtrasPosHighlight()
                ns.SaveCurrentProfile()
                LoadEssentialCooldowns()
            end)
            UpdateExtrasPosHighlight()
            extrasHeaderFrame:Show()
            extrasHeaderFrame:ClearAllPoints()
            extrasHeaderFrame:SetPoint("TOPLEFT", 0, -yOffset)
            yOffset = yOffset + 88

            -- 12.1 hides racials only; they come from the CDM there.
            -- REMOVE WITH 12.0.7 SUPPORT.
            local extrasNativeIn121 = ns.AuraCompat and ns.AuraCompat.IS_121
            for extIdx, extra in ipairs(CONFIG.extras) do
                if extra._unavailable then
                    -- unavailable, skip
                elseif extrasNativeIn121 and extra.type == "racial" then
                    -- superseded by the Cooldown Manager, skip
                elseif extra.type == "custom" then
                    -- Custom row: wider layout with slot widgets (buff 1/2/3, cast 1/2, stack)
                    local cRow = customRowCache[extIdx]
                    if not cRow then
                        cRow = CreateFrame("Frame", nil, topContent)
                        cRow:SetSize(topContent:GetWidth() or 700, 28)
                        cRow.cb = CreateFrame("CheckButton", nil, cRow, "UICheckButtonTemplate")
                        cRow.cb:SetPoint("LEFT", 2, 0)
                        cRow.cb:SetSize(22, 22)
                        cRow.abilIcon = cRow:CreateTexture(nil, "ARTWORK")
                        cRow.abilIcon:SetSize(24, 24)
                        cRow.abilIcon:SetPoint("LEFT", cRow.cb, "RIGHT", 4, 0)
                        cRow.abilIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        cRow.iconBtn = CreateFrame("Button", nil, cRow)
                        cRow.iconBtn:SetAllPoints(cRow.abilIcon)
                        local iconHl = cRow.iconBtn:CreateTexture(nil, "HIGHLIGHT")
                        iconHl:SetAllPoints()
                        iconHl:SetColorTexture(1, 0.82, 0, 0.18)
                        cRow.nameText = cRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        cRow.nameText:SetPoint("LEFT", cRow.abilIcon, "RIGHT", 4, 0)
                        cRow.nameText:SetWidth(106)
                        cRow.nameText:SetJustifyH("LEFT")
                        cRow.nameText:SetWordWrap(false)
                        cRow.buff1Slot = CreateSlotFrame(cRow, cRow.nameText, "RIGHT", 4)
                        cRow.buff1ColorBtn = CreateSlotColorBtn(cRow, cRow.buff1Slot)
                        cRow.buff2Slot = CreateSlotFrame(cRow, cRow.buff1ColorBtn, "RIGHT", 6)
                        cRow.buff2ColorBtn = CreateSlotColorBtn(cRow, cRow.buff2Slot)
                        cRow.buff3Slot = CreateSlotFrame(cRow, cRow.buff2ColorBtn, "RIGHT", 6)
                        cRow.buff3ColorBtn = CreateSlotColorBtn(cRow, cRow.buff3Slot)
                        cRow.cast1Slot = CreateSlotFrame(cRow, cRow.buff3ColorBtn, "RIGHT", 12)
                        cRow.cast1ColorBtn = CreateSlotColorBtn(cRow, cRow.cast1Slot)
                        cRow.cast2Slot = CreateSlotFrame(cRow, cRow.cast1ColorBtn, "RIGHT", 6)
                        cRow.cast2ColorBtn = CreateSlotColorBtn(cRow, cRow.cast2Slot)
                        cRow.stackSlot = CreateSlotFrame(cRow, cRow.cast2ColorBtn, "RIGHT", 12)
                        cRow.stackColorBtn = CreateSlotColorBtn(cRow, cRow.stackSlot)
                        cRow.upBtn = CreateFrame("Button", nil, cRow)
                        cRow.upBtn:SetSize(16, 16)
                        cRow.upBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
                        cRow.upBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Highlight")
                        cRow.upBtn:SetPoint("LEFT", cRow.stackColorBtn, "RIGHT", 18, 0)
                        cRow.downBtn = CreateFrame("Button", nil, cRow)
                        cRow.downBtn:SetSize(16, 16)
                        cRow.downBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
                        cRow.downBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Highlight")
                        cRow.downBtn:SetPoint("LEFT", cRow.upBtn, "RIGHT", 2, 0)
                        cRow.deleteBtn = CreateFrame("Button", nil, cRow, "UIPanelButtonTemplate")
                        cRow.deleteBtn:SetSize(56, 18)
                        cRow.deleteBtn:SetPoint("LEFT", cRow.downBtn, "RIGHT", 8, 0)
                        cRow.deleteBtn:SetText("Delete")
                        customRowCache[extIdx] = cRow
                        customRowCacheCount = math.max(customRowCacheCount, extIdx)
                    end

                    cRow:Show()
                    cRow:ClearAllPoints()
                    cRow:SetPoint("TOPLEFT", 0, -yOffset)

                    local rowIcon = extra.iconTexture or (extra.iconSpellID and C_Spell.GetSpellTexture(extra.iconSpellID)) or 134400
                    cRow.abilIcon:SetTexture(rowIcon)
                    cRow.abilIcon:SetDesaturated(not extra.enabled)
                    cRow.nameText:SetText(extra.label or "Custom Row")
                    cRow.nameText:SetTextColor(extra.enabled and 0.6 or 0.5, extra.enabled and 0.85 or 0.5, extra.enabled and 1 or 0.5)
                    cRow.cb:SetChecked(extra.enabled)

                    local cIdx = extIdx
                    local cKey = extra.key

                    cRow.cb:SetScript("OnClick", function(self)
                        if not CONFIG.extras[cIdx] then return end
                        CONFIG.extras[cIdx].enabled = self:GetChecked() and true or false
                        local on = CONFIG.extras[cIdx].enabled
                        cRow.abilIcon:SetDesaturated(not on)
                        cRow.nameText:SetTextColor(on and 0.6 or 0.5, on and 0.85 or 0.5, on and 1 or 0.5)
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                    end)

                    cRow.iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    cRow.iconBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Custom Row Icon", 1, 1, 1)
                        GameTooltip:AddLine("Left click to change the icon. Type a spell ID in the picker's search box to use icons outside your spellbook.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    cRow.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    cRow.iconBtn:SetScript("OnClick", function(self, button)
                        if button == "RightButton" then return end
                        OpenSpellPicker({
                            title = "Choose Custom Row Icon",
                            anchor = self,
                            onSelect = function(pickedID, pickedName, pickedIcon)
                                local e = CONFIG.extras[cIdx]
                                if not e then return end
                                e.iconSpellID = pickedID
                                e.iconTexture = pickedIcon
                                e.label = pickedName or e.label
                                ns.SaveCurrentProfile()
                                LoadEssentialCooldowns()
                                RefreshCooldownRows()
                            end,
                        })
                    end)

                    WireSlots(cRow, cKey)

                    cRow.upBtn:SetEnabled(cIdx > 1)
                    cRow.downBtn:SetEnabled(cIdx < #CONFIG.extras)
                    cRow.upBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Move Up")
                        GameTooltip:AddLine("Swap this row with the one above it.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    cRow.upBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    cRow.downBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Move Down")
                        GameTooltip:AddLine("Swap this row with the one below it.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    cRow.downBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    cRow.upBtn:SetScript("OnClick", function()
                        if cIdx <= 1 then return end
                        local t = CONFIG.extras
                        t[cIdx], t[cIdx - 1] = t[cIdx - 1], t[cIdx]
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        RefreshCooldownRows()
                    end)
                    cRow.downBtn:SetScript("OnClick", function()
                        if cIdx >= #CONFIG.extras then return end
                        local t = CONFIG.extras
                        t[cIdx], t[cIdx + 1] = t[cIdx + 1], t[cIdx]
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        RefreshCooldownRows()
                    end)
                    cRow.deleteBtn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("Delete Custom Row")
                        GameTooltip:AddLine("Remove this row and its buff, cast, and stack assignments.", 0.7, 0.7, 0.7, true)
                        GameTooltip:Show()
                    end)
                    cRow.deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    cRow.deleteBtn:SetScript("OnClick", function()
                        if not CONFIG.extras[cIdx] then return end
                        local key = CONFIG.extras[cIdx].key
                        table.remove(CONFIG.extras, cIdx)
                        if key then
                            if CONFIG.buffMappings then CONFIG.buffMappings[key] = nil end
                            if CONFIG.extraCasts then CONFIG.extraCasts[key] = nil end
                            if CONFIG.stackMappings then CONFIG.stackMappings[key] = nil end
                            if CONFIG.cooldownColors then CONFIG.cooldownColors[key] = nil end
                            if CONFIG.customIcons then CONFIG.customIcons[key] = nil end
                            if ns._activeExtrasTimers then ns._activeExtrasTimers[key] = nil end
                        end
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        RefreshCooldownRows()
                    end)

                    yOffset = yOffset + 30
                elseif not extra._unavailable and extra.type ~= "custom" then
                local eRow = extrasRowCache[extIdx]
                if not eRow then
                    eRow = CreateFrame("Frame", nil, topContent)
                    eRow:SetSize(topContent:GetWidth() or 700, 28)
                    eRow.cb = CreateFrame("CheckButton", nil, eRow, "UICheckButtonTemplate")
                    eRow.cb:SetPoint("LEFT", 2, 0)
                    eRow.cb:SetSize(22, 22)

                    eRow.cdColorBtn = CreateFrame("Button", nil, eRow)
                    eRow.cdColorBtn:SetSize(16, 16)
                    eRow.cdColorBtn:SetPoint("LEFT", eRow.cb, "RIGHT", 2, 0)
                    local cdBg = eRow.cdColorBtn:CreateTexture(nil, "BACKGROUND")
                    cdBg:SetAllPoints()
                    cdBg:SetColorTexture(0, 0, 0, 1)
                    eRow.cdColorBtn.tex = eRow.cdColorBtn:CreateTexture(nil, "OVERLAY")
                    eRow.cdColorBtn.tex:SetPoint("TOPLEFT", 1, -1)
                    eRow.cdColorBtn.tex:SetPoint("BOTTOMRIGHT", -1, 1)

                    eRow.abilIcon = eRow:CreateTexture(nil, "ARTWORK")
                    eRow.abilIcon:SetSize(24, 24)
                    eRow.abilIcon:SetPoint("LEFT", eRow.cdColorBtn, "RIGHT", 4, 0)
                    eRow.abilIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                    eRow.buffColorBtn = CreateFrame("Button", nil, eRow)
                    eRow.buffColorBtn:SetSize(16, 16)
                    eRow.buffColorBtn:SetPoint("LEFT", eRow.abilIcon, "RIGHT", 4, 0)
                    local buffBg = eRow.buffColorBtn:CreateTexture(nil, "BACKGROUND")
                    buffBg:SetAllPoints()
                    buffBg:SetColorTexture(0, 0, 0, 1)
                    eRow.buffColorBtn.tex = eRow.buffColorBtn:CreateTexture(nil, "OVERLAY")
                    eRow.buffColorBtn.tex:SetPoint("TOPLEFT", 1, -1)
                    eRow.buffColorBtn.tex:SetPoint("BOTTOMRIGHT", -1, 1)

                    eRow.nameText = eRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    eRow.nameText:SetPoint("LEFT", eRow.buffColorBtn, "RIGHT", 4, 0)
                    eRow.nameText:SetWidth(180)
                    eRow.nameText:SetJustifyH("LEFT")
                    eRow.nameText:SetWordWrap(false)

                    eRow.upBtn = CreateFrame("Button", nil, eRow)
                    eRow.upBtn:SetSize(16, 16)
                    eRow.upBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
                    eRow.upBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Highlight")
                    eRow.upBtn:SetPoint("LEFT", eRow.nameText, "RIGHT", 20, 0)

                    eRow.downBtn = CreateFrame("Button", nil, eRow)
                    eRow.downBtn:SetSize(16, 16)
                    eRow.downBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
                    eRow.downBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Highlight")
                    eRow.downBtn:SetPoint("LEFT", eRow.upBtn, "RIGHT", 2, 0)

                    extrasRowCache[extIdx] = eRow
                    extrasRowCacheCount = math.max(extrasRowCacheCount, extIdx)
                end

                eRow:Show()
                eRow:ClearAllPoints()
                eRow:SetPoint("TOPLEFT", 0, -yOffset)

                local spellIcon = C_Spell.GetSpellTexture(extra.spellID) or 134400
                local spellName = C_Spell.GetSpellName(extra.spellID) or extra.key
                local typeLabel = extra.type == "racial" and " (Racial)" or extra.type == "trinket" and " (Trinket)" or " (Potion)"

                eRow.abilIcon:SetTexture(spellIcon)
                eRow.abilIcon:SetDesaturated(not extra.enabled)
                eRow.nameText:SetText(spellName .. typeLabel)
                eRow.nameText:SetTextColor(
                    extra.enabled and 1 or 0.5,
                    extra.enabled and 0.82 or 0.5,
                    extra.enabled and 0 or 0.5)
                eRow.cb:SetChecked(extra.enabled)

                local capturedIdx = extIdx
                eRow.cb:SetScript("OnClick", function(self)
                    CONFIG.extras[capturedIdx].enabled = self:GetChecked() and true or false
                    eRow.abilIcon:SetDesaturated(not CONFIG.extras[capturedIdx].enabled)
                    eRow.nameText:SetTextColor(
                        CONFIG.extras[capturedIdx].enabled and 1 or 0.5,
                        CONFIG.extras[capturedIdx].enabled and 0.82 or 0.5,
                        CONFIG.extras[capturedIdx].enabled and 0 or 0.5)
                    ns.SaveCurrentProfile()
                    LoadEssentialCooldowns()
                end)

                -- CD colour button
                local cdColor = extra.cdColor or DeepCopy(CONFIG.cooldownColor)
                eRow.cdColorBtn.tex:SetColorTexture(cdColor[1], cdColor[2], cdColor[3], cdColor[4] or 1)
                eRow.cdColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                eRow.cdColorBtn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        CONFIG.extras[capturedIdx].cdColor = nil
                        self.tex:SetColorTexture(unpack(CONFIG.cooldownColor))
                        ns.SaveCurrentProfile()
                        ApplyLayoutToAllBars()
                        return
                    end
                    local cur = CONFIG.extras[capturedIdx].cdColor or DeepCopy(CONFIG.cooldownColor)
                    OpenInlineColorPicker(cur, function(c)
                        self.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        CONFIG.extras[capturedIdx].cdColor = c
                        DebouncedApplyAndSave()
                    end)
                end)
                eRow.cdColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Cooldown Colour")
                    if extra.cdColor then
                        GameTooltip:AddLine("Right click to reset to default.", 0.5, 0.8, 0.5, true)
                    else
                        GameTooltip:AddLine("Click to set a custom colour for this cooldown bar.", 0.7, 0.7, 0.7, true)
                    end
                    GameTooltip:Show()
                end)
                eRow.cdColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Buff colour button
                local buffColor = extra.buffColor or DeepCopy(CONFIG.buffColor)
                eRow.buffColorBtn.tex:SetColorTexture(buffColor[1], buffColor[2], buffColor[3], buffColor[4] or 1)
                eRow.buffColorBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                eRow.buffColorBtn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        CONFIG.extras[capturedIdx].buffColor = nil
                        self.tex:SetColorTexture(unpack(CONFIG.buffColor))
                        ns.SaveCurrentProfile()
                        ApplyLayoutToAllBars()
                        return
                    end
                    local cur = CONFIG.extras[capturedIdx].buffColor or DeepCopy(CONFIG.buffColor)
                    OpenInlineColorPicker(cur, function(c)
                        self.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                        CONFIG.extras[capturedIdx].buffColor = c
                        DebouncedApplyAndSave()
                    end)
                end)
                eRow.buffColorBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Buff Colour")
                    if extra.buffColor then
                        GameTooltip:AddLine("Right click to reset to default.", 0.5, 0.8, 0.5, true)
                    else
                        GameTooltip:AddLine("Click to set a custom colour for this buff bar.", 0.7, 0.7, 0.7, true)
                    end
                    GameTooltip:Show()
                end)
                eRow.buffColorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                eRow.upBtn:SetEnabled(extIdx > 1)
                eRow.downBtn:SetEnabled(extIdx < #CONFIG.extras)

                eRow.upBtn:SetScript("OnClick", function()
                    if capturedIdx <= 1 then return end
                    local t = CONFIG.extras
                    t[capturedIdx], t[capturedIdx - 1] = t[capturedIdx - 1], t[capturedIdx]
                    ns.SaveCurrentProfile()
                    LoadEssentialCooldowns()
                    RefreshCooldownRows()
                end)
                eRow.downBtn:SetScript("OnClick", function()
                    if capturedIdx >= #CONFIG.extras then return end
                    local t = CONFIG.extras
                    t[capturedIdx], t[capturedIdx + 1] = t[capturedIdx + 1], t[capturedIdx]
                    ns.SaveCurrentProfile()
                    LoadEssentialCooldowns()
                    RefreshCooldownRows()
                end)

                yOffset = yOffset + 30
                end -- not _unavailable
            end
        end

        if rowIndex == 0 then
            if not emptyRowsText then
                emptyRowsText = topContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                emptyRowsText:SetPoint("TOPLEFT", 8, -8)
                emptyRowsText:SetText("No abilities found. Open the Cooldown Manager to add abilities.")
                emptyRowsText:SetWidth(topContent:GetWidth() - 16)
                emptyRowsText:SetJustifyH("LEFT")
            end
            emptyRowsText:Show()
            yOffset = math.max(yOffset, 30)
        elseif emptyRowsText then
            emptyRowsText:Hide()
        end

        topContent:SetHeight(math.max(yOffset, 1))
        HighlightAvailableSlots()
    end

    -- Refresh Buff Pool
    local buffSectionHeaders = {}
    local buffSectionHeaderCount = 0

    RefreshBuffPool = function()
        for i = 1, buffPoolCacheCount do
            if buffPoolCache[i] then buffPoolCache[i]:Hide() end
        end
        for i = 1, buffSectionHeaderCount do
            if buffSectionHeaders[i] then buffSectionHeaders[i]:Hide() end
        end

        -- Labels only annotated on 12.1; both are exact on earlier builds.
        local is121 = ns.AuraCompat and ns.AuraCompat.IS_121
        local sections = {
            { cat = 2, label = is121 and "Tracked Buffs (estimated timing)" or "Tracked Buffs" },
            { cat = 3, label = is121 and "Tracked Bars (exact timing)" or "Tracked Bars" },
        }
        local catLabel = {}
        local seen = {}
        local totalCount = 0

        -- Use CDM DataProvider if available (matches CDM settings display)
        local dataProvider
        if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
            dataProvider = CooldownViewerSettings:GetDataProvider()
        end

        for _, sec in ipairs(sections) do
            sec.ids = {}
            catLabel[sec.cat] = sec.label
            local catIds
            if dataProvider and dataProvider.GetOrderedCooldownIDsForCategory then
                local dpOk, dpResult = pcall(dataProvider.GetOrderedCooldownIDsForCategory, dataProvider, sec.cat)
                if dpOk and dpResult and #dpResult > 0 then
                    catIds = dpResult
                end
            end
            if not catIds then
                local catOk, catResult = pcall(function()
                    return C_CooldownViewer.GetCooldownViewerCategorySet(sec.cat, false)
                end)
                if catOk and catResult then catIds = catResult end
            end
            if catIds then
                for _, id in ipairs(catIds) do
                    if not seen[id] then
                        seen[id] = true
                        sec.ids[#sec.ids + 1] = id
                        totalCount = totalCount + 1
                    end
                end
            end
        end

        local cols = 16
        local iconSz = 30
        local gap = 4
        local yOff = 0
        local btnIdx = 0
        local headerIdx = 0

        for _, sec in ipairs(sections) do
            if #sec.ids > 0 then
                -- Section header
                headerIdx = headerIdx + 1
                local header = buffSectionHeaders[headerIdx]
                if not header then
                    header = buffsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    header:SetJustifyH("LEFT")
                    buffSectionHeaders[headerIdx] = header
                    buffSectionHeaderCount = math.max(buffSectionHeaderCount, headerIdx)
                end
                header:SetText(sec.label)
                header:ClearAllPoints()
                header:SetPoint("TOPLEFT", buffsContent, "TOPLEFT", 0, -yOff)
                header:Show()
                yOff = yOff + 18

                -- Icons
                for i, buffCdID in ipairs(sec.ids) do
                    btnIdx = btnIdx + 1
                    local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                    local spellID = infoOk and cdInfo and (cdInfo.overrideTooltipSpellID or cdInfo.overrideSpellID or cdInfo.spellID)
                    local rName, rIcon = ns.ResolveCooldownDisplay(buffCdID, cdInfo)
                    local tex = rIcon or 134400
                    local spellName = rName or ("ID:" .. buffCdID)
                    local secLabel = sec.label
                    local secCat = sec.cat

                    local col = (i - 1) % cols
                    local rowIdx = math.floor((i - 1) / cols)

                    local btn = buffPoolCache[btnIdx]
                    if not btn then
                        btn = CreateFrame("Button", nil, buffsContent)
                        btn.iconTex = btn:CreateTexture(nil, "ARTWORK")
                        btn.iconTex:SetAllPoints()
                        btn.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        btn.highlight = btn:CreateTexture(nil, "OVERLAY")
                        btn.highlight:SetPoint("TOPLEFT", -2, 2)
                        btn.highlight:SetPoint("BOTTOMRIGHT", 2, -2)
                        btn.highlight:SetColorTexture(1, 1, 0, 0.6)
                        buffPoolCache[btnIdx] = btn
                        buffPoolCacheCount = math.max(buffPoolCacheCount, btnIdx)
                    end

                    btn:Show()
                    btn:SetSize(iconSz, iconSz)
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", col * (iconSz + gap), -(yOff + rowIdx * (iconSz + gap)))
                    btn.iconTex:SetTexture(tex)
                    btn.highlight:Hide()

                    btn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(spellName, 1, 1, 1)
                        GameTooltip:AddLine(secLabel, 0.5, 0.8, 1.0)
                        GameTooltip:AddLine("CooldownID: " .. buffCdID, 0.7, 0.7, 0.7)
                        if spellID then
                            GameTooltip:AddLine("SpellID: " .. spellID, 0.7, 0.7, 0.7)
                        end
                        -- Estimated section only: show what has been learned.
                        if is121 and secCat == 2 and ns.AuraCompat then
                            local state, dur = ns.AuraCompat.GetLearnState(spellID)
                            if state == "permanent" then
                                GameTooltip:AddLine("Permanent buff, drawn as a full bar.", 0.5, 0.9, 0.5, true)
                            elseif state == "learned" then
                                GameTooltip:AddLine(string.format("Estimated at %.1fs. Will not follow refreshes or haste.", dur), 1, 0.82, 0, true)
                            else
                                GameTooltip:AddLine("Not learned yet. Gain this buff out of combat once, or move it to Tracked Bars for exact timing.", 1, 0.5, 0.5, true)
                            end
                        end
                        GameTooltip:AddLine("Click to select, then click a Buff or Stack slot above.", 0.5, 0.8, 0.5, true)
                        GameTooltip:Show()
                    end)
                    btn:SetScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)

                    btn:SetScript("OnClick", function(self)
                        if selectedBuff == buffCdID then
                            CancelSelection()
                            statusText:SetText("")
                            return
                        end
                        CancelSelection()
                        selectedBuff = buffCdID
                        selectedBuffFrame = self
                        selectedType = "buff"
                        btn.highlight:Show()
                        HighlightAvailableSlots()
                        statusText:SetText("|cff00ff00Selected:|r " .. spellName .. ", click a Buff or Stack slot above")
                    end)
                end

                local secRows = math.ceil(#sec.ids / cols)
                yOff = yOff + secRows * (iconSz + gap) + 6
            end
        end

        for i = btnIdx + 1, buffPoolCacheCount do
            if buffPoolCache[i] then buffPoolCache[i]:Hide() end
        end

        if totalCount == 0 then
            if not emptyBuffsText then
                emptyBuffsText = buffsContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                emptyBuffsText:SetPoint("TOPLEFT", 4, -4)
                emptyBuffsText:SetText("No tracked buffs found. Add buffs in the Cooldown Manager.")
                emptyBuffsText:SetWidth(buffsContent:GetWidth() - 8)
                emptyBuffsText:SetJustifyH("LEFT")
            end
            emptyBuffsText:Show()
            buffsContent:SetHeight(30)
        else
            if emptyBuffsText then emptyBuffsText:Hide() end
            buffsContent:SetHeight(math.max(yOff, 1))
        end
    end

    -- Refresh Cast Pool (auto-populated from spellbook)
    local RefreshCastPool
    RefreshCastPool = function()
        for i = 1, castPoolCacheCount do
            if castPoolCache[i] then castPoolCache[i]:Hide() end
        end

        local castSpells = {}
        local seen = {}

        -- Tooltip scan: detect channeled spells via SPELL_CAST_CHANNELED global string.
        local function IsChanneled(sid)
            local tipOk, data = pcall(C_TooltipInfo.GetSpellByID, sid)
            if tipOk and data and data.lines then
                for _, line in ipairs(data.lines) do
                    if not issecretvalue(line.leftText) and line.leftText == SPELL_CAST_CHANNELED then return true end
                end
            end
            return false
        end

        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
            local numLines = C_SpellBook.GetNumSpellBookSkillLines()
            for skillLineIndex = 1, numLines do
                local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
                if skillLineInfo and skillLineInfo.numSpellBookItems then
                    for i = 1, skillLineInfo.numSpellBookItems do
                        local spellIndex = skillLineInfo.itemIndexOffset + i
                        local itemOk, itemInfo = pcall(C_SpellBook.GetSpellBookItemInfo, spellIndex, Enum.SpellBookSpellBank.Player)
                        if itemOk and itemInfo and not itemInfo.isPassive and not itemInfo.isOffSpec then
                            local itemType = itemInfo.itemType
                            -- Accept Spell type, skip FUTURESPELL/FLYOUT/PET_ACTION
                            if itemType == Enum.SpellBookItemType.Spell or itemType == "SPELL" then
                                local sid = itemInfo.spellID or itemInfo.actionID
                                if sid and not seen[sid] then
                                    local infoOk, spellInfo = pcall(C_Spell.GetSpellInfo, sid)
                                    if infoOk and spellInfo and ((spellInfo.castTime and spellInfo.castTime > 0) or IsChanneled(sid)) then
                                        seen[sid] = true
                                        castSpells[#castSpells + 1] = {
                                            spellID = sid,
                                            name = spellInfo.name or C_Spell.GetSpellName(sid) or ("ID:" .. sid),
                                            icon = spellInfo.iconID or C_Spell.GetSpellTexture(sid) or 134400,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        table.sort(castSpells, function(a, b) return a.name < b.name end)

        -- Render grid
        local cols = 16
        local iconSz = 30
        local gap = 4
        for i, castData in ipairs(castSpells) do
            local col = (i - 1) % cols
            local rowIdx = math.floor((i - 1) / cols)

            local btn = castPoolCache[i]
            if not btn then
                btn = CreateFrame("Button", nil, castsContent)
                btn.iconTex = btn:CreateTexture(nil, "ARTWORK")
                btn.iconTex:SetAllPoints()
                btn.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                btn.highlight = btn:CreateTexture(nil, "OVERLAY")
                btn.highlight:SetPoint("TOPLEFT", -2, 2)
                btn.highlight:SetPoint("BOTTOMRIGHT", 2, -2)
                btn.highlight:SetColorTexture(1, 1, 0, 0.6)
                castPoolCache[i] = btn
                castPoolCacheCount = math.max(castPoolCacheCount, i)
            end

            btn:Show()
            btn:SetSize(iconSz, iconSz)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", col * (iconSz + gap), -rowIdx * (iconSz + gap))
            btn.iconTex:SetTexture(castData.icon)
            btn.highlight:Hide()

            local castName = castData.name
            local castSID = castData.spellID

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(castName, 1, 1, 1)
                GameTooltip:AddLine("SpellID: " .. castSID, 0.7, 0.7, 0.7)
                GameTooltip:AddLine("Click to select, then click a Cast slot above.", 0.5, 0.8, 0.5, true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(self)
                if selectedCast == castSID then
                    CancelSelection()
                    statusText:SetText("")
                    return
                end
                CancelSelection()
                selectedCast = castSID
                selectedCastFrame = self
                selectedType = "cast"
                btn.highlight:Show()
                HighlightAvailableSlots()
                statusText:SetText("|cff00ff00Selected:|r " .. castName .. ", click a Cast slot above")
            end)
        end


        for i = #castSpells + 1, castPoolCacheCount do
            if castPoolCache[i] then castPoolCache[i]:Hide() end
        end

        if #castSpells == 0 then
            if not emptyCastsText then
                emptyCastsText = castsContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                emptyCastsText:SetPoint("TOPLEFT", 4, -4)
                emptyCastsText:SetText("No cast time spells found in your spellbook.")
                emptyCastsText:SetWidth(castsContent:GetWidth() - 8)
                emptyCastsText:SetJustifyH("LEFT")
            end
            emptyCastsText:Show()
            castsContent:SetHeight(30)
        else
            if emptyCastsText then emptyCastsText:Hide() end
            local totalRows = math.ceil(#castSpells / cols)
            castsContent:SetHeight(math.max(totalRows * (iconSz + gap), 1))
        end
    end

    refreshBtn:SetScript("OnClick", function()
        CancelSelection()
        statusText:SetText("")
        RefreshCooldownRows()
        RefreshBuffPool()
        RefreshCastPool()
        statusText:SetText("|cff88ff88Refreshed.|r")
        C_Timer.After(2, function() statusText:SetText("") end)
    end)

    barsTab:SetScript("OnShow", function()
        CancelSelection()
        statusText:SetText("")
        RefreshCooldownRows()
        RefreshBuffPool()
        RefreshCastPool()
        SelectPoolTab(1)
    end)

    -- ========================================================================
    -- TAB B: DISPLAY
    -- ========================================================================
    local displayTab = CreateFrame("Frame", nil, contentArea)
    displayTab:SetAllPoints()
    displayTab:Hide()
    tabFrames[2] = displayTab

    local dispScroll, dispContent = CreateScrollableContent(displayTab)
    local dispRefreshing = false

    local dispY = 0
    local function AddDispWidget(widget)
        widget:SetPoint("TOPLEFT", dispContent, "TOPLEFT", 10, -dispY)
        dispY = dispY + widget:GetHeight() + 6
    end

    local function AddDispHeader(text)
        dispY = dispY + 10
        local h = CreateSectionHeader(dispContent, text)
        h:SetPoint("TOPLEFT", dispContent, "TOPLEFT", 10, -dispY)
        dispY = dispY + 22
    end

    local function AddDispDescription(text)
        local desc = dispContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        desc:SetPoint("TOPLEFT", dispContent, "TOPLEFT", 10, -dispY)
        desc:SetWidth(500)
        desc:SetJustifyH("LEFT")
        desc:SetSpacing(2)
        desc:SetText(text)
        dispY = dispY + desc:GetStringHeight() + 6
    end

    -- Timeline
    AddDispHeader("Timeline")
    AddDispDescription("How far into the future and past the bars display. Future is how many seconds ahead you can see cooldowns and buffs. Past shows recently expired effects sliding off the left edge.")

    local futureSlider = CreateSlider(dispContent, "Future (seconds)", 1, 60, 1, CONFIG.future, nil)
    AddDispWidget(futureSlider)
    -- Future applies on mouse-up only (rebuilds all bar min/max)
    futureSlider.slider:SetScript("OnMouseUp", function()
        CONFIG.future = futureSlider:GetValue()
        if ns.UpdateAllMinMax then ns.UpdateAllMinMax() end
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    futureSlider.slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        futureSlider.valueBox:SetText(string.format("%.0f", value))
    end)
    -- Also apply when typing an exact value into the box
    futureSlider.valueBox:SetScript("OnEnterPressed", function(self)
        local num = tonumber(self:GetText())
        if num then
            num = math.max(1, math.min(60, math.floor(num + 0.5)))
            futureSlider.slider:SetValue(num)
            self:SetText(string.format("%.0f", num))
            CONFIG.future = num
            if ns.UpdateAllMinMax then ns.UpdateAllMinMax() end
            ApplyLayoutToAllBars()
            ns.SaveCurrentProfile()
        else
            self:SetText(string.format("%.0f", futureSlider.slider:GetValue()))
        end
        self:ClearFocus()
    end)

    local pastSlider = CreateSlider(dispContent, "Past (seconds)", 0, 10, 0.5, CONFIG.past, function(v)
        CONFIG.past = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(pastSlider)

    -- Bar Layout
    AddDispHeader("Bar Layout")
    AddDispDescription("Controls the size of each bar row. Width and height set the dimensions in pixels. Spacing is the gap between rows. Scale multiplies the entire frame.")

    local widthSlider = CreateSlider(dispContent, "Bar Width", 100, 600, 1, CONFIG.width, function(v)
        CONFIG.width = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(widthSlider)

    local heightSlider = CreateSlider(dispContent, "Bar Height", 8, 40, 1, CONFIG.height, function(v)
        CONFIG.height = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(heightSlider)

    local extrasHeightSlider = CreateSlider(dispContent, "Extras Bar Height", 8, 40, 1, CONFIG.extrasHeight or CONFIG.height, function(v)
        CONFIG.extrasHeight = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(extrasHeightSlider)

    local spacingSlider = CreateSlider(dispContent, "Spacing", 0, 5, 0.5, CONFIG.spacing, function(v)
        CONFIG.spacing = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(spacingSlider)

    local scaleSlider = CreateSlider(dispContent, "Scale", 0.5, 3.0, 0.05, CONFIG.scale, function(v)
        CONFIG.scale = v
        if EH_Parent then EH_Parent:SetScale(v) end
        if ns.SyncStackContainerLayout then ns.SyncStackContainerLayout() end
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(scaleSlider)

    -- Texture note
    local texNoteBlock = CreateFrame("Frame", nil, dispContent, "BackdropTemplate")
    texNoteBlock:SetSize(500, 40)
    texNoteBlock:SetPoint("TOPLEFT", dispContent, "TOPLEFT", 10, -dispY)
    texNoteBlock:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    texNoteBlock:SetBackdropColor(0.14, 0.14, 0.18, 0.6)
    texNoteBlock:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.4)

    local texNoteText = texNoteBlock:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    texNoteText:SetPoint("TOPLEFT", 10, -8)
    texNoteText:SetPoint("TOPRIGHT", -10, -8)
    texNoteText:SetJustifyH("LEFT")
    texNoteText:SetSpacing(2)
    texNoteText:SetText("Bar texture is not configurable here. The smooth gradient is required for the visual effect of\nbars filling and emptying. To swap textures, replace Smooth.tga in the addon folder.")

    dispY = dispY + 48

    -- Padding
    AddDispHeader("Padding")
    AddDispDescription("Extra space around the bar frame edges. Useful for fine-tuning alignment with other UI elements.")

    local padTopSlider = CreateSlider(dispContent, "Padding Top", 0, 20, 1, CONFIG.paddingTop, function(v)
        CONFIG.paddingTop = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(padTopSlider)

    local padBotSlider = CreateSlider(dispContent, "Padding Bottom", 0, 20, 1, CONFIG.paddingBottom, function(v)
        CONFIG.paddingBottom = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(padBotSlider)

    local padLeftSlider = CreateSlider(dispContent, "Padding Left", 0, 20, 1, CONFIG.paddingLeft, function(v)
        CONFIG.paddingLeft = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(padLeftSlider)

    local padRightSlider = CreateSlider(dispContent, "Padding Right", 0, 20, 1, CONFIG.paddingRight, function(v)
        CONFIG.paddingRight = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(padRightSlider)

    -- Icons
    AddDispHeader("Icons")
    AddDispDescription("Size and spacing of ability icons on the left side of each bar. Icon gap is the space between the icon and the bar.")

    local iconSizeSlider = CreateSlider(dispContent, "Icon Size", 16, 48, 1, CONFIG.iconSize, function(v)
        CONFIG.iconSize = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(iconSizeSlider)

    local iconGapSlider = CreateSlider(dispContent, "Icon Gap", 0, 30, 1, CONFIG.iconGap or 10, function(v)
        CONFIG.iconGap = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(iconGapSlider)

    -- Now Line
    AddDispHeader("Now Line")
    AddDispDescription("The vertical line showing the current moment in time. Wider values make it easier to see.")

    local nowLineSlider = CreateSlider(dispContent, "Now Line Width", 1, 6, 1, CONFIG.nowLineWidth, function(v)
        CONFIG.nowLineWidth = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(nowLineSlider)

    -- GCD
    AddDispHeader("GCD")
    AddDispDescription("The Global Cooldown indicator. The spark is the bright line at the leading edge of the GCD bar.")

    local gcdSparkSlider = CreateSlider(dispContent, "GCD Spark Width", 1, 6, 1, CONFIG.gcdSparkWidth, function(v)
        CONFIG.gcdSparkWidth = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(gcdSparkSlider)

    -- Static Height
    AddDispHeader("Static Height")
    AddDispDescription("Locks the frame to a fixed pixel height instead of growing and shrinking with the number of visible bars. Min bars sets the minimum row count before static height kicks in.")

    local staticCheck = CreateCheckbox(dispContent, "Enable Static Height", "Lock frame to fixed pixel height", CONFIG.staticHeight ~= nil, function(checked)
        if checked then
            CONFIG.staticHeight = CONFIG.staticHeight or 150
        else
            CONFIG.staticHeight = nil
        end
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(staticCheck)

    local staticHeightSlider = CreateSlider(dispContent, "Static Height (px)", 40, 400, 1, CONFIG.staticHeight or 150, function(v)
        if CONFIG.staticHeight then
            CONFIG.staticHeight = v
            ApplyLayoutToAllBars()
            ns.SaveCurrentProfile()
        end
    end)
    AddDispWidget(staticHeightSlider)

    local staticFramesSlider = CreateSlider(dispContent, "Min Bars for Static", 0, 20, 1, CONFIG.staticFrames or 0, function(v)
        CONFIG.staticFrames = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(staticFramesSlider)

    -- Time Lines
    AddDispHeader("Time Lines")
    AddDispDescription("Vertical reference lines at specific second marks. Enter values separated by commas, IE \"1, 3, 5\" to show lines at 1s, 3s and 5s. Leave blank to disable.")

    local linesStr = ""
    if CONFIG.lines then
        if type(CONFIG.lines) == "table" then
            local parts = {}
            for _, v in ipairs(CONFIG.lines) do
                parts[#parts + 1] = tostring(v)
            end
            linesStr = table.concat(parts, ", ")
        elseif type(CONFIG.lines) == "number" then
            linesStr = tostring(CONFIG.lines)
        end
    end

    local linesEdit = CreateEditBox(dispContent, "Time Lines (comma separated, blank=off)", linesStr, function(text)
        if text == "" or text == "off" then
            CONFIG.lines = nil
        else
            local vals = {}
            for num in text:gmatch("[%d%.]+") do
                local n = tonumber(num)
                if n then vals[#vals + 1] = n end
            end
            if #vals == 0 then
                CONFIG.lines = nil
            elseif #vals == 1 then
                CONFIG.lines = vals[1]
            else
                CONFIG.lines = vals
            end
        end
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(linesEdit)

    -- Position
    AddDispHeader("Position")
    AddDispDescription("Offset from the frame's anchor point. Use these sliders or type exact values to precisely position the bar frame.")

    local function GetFramePosition()
        if EH_Parent and EH_Parent:GetPoint(1) then
            local point, _, relPoint, x, y = EH_Parent:GetPoint(1)
            return math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5)
        end
        return 0, 0
    end

    local curX, curY = GetFramePosition()

    local posXSlider = CreateSlider(dispContent, "X Offset", -1000, 1000, 1, curX, function(v)
        if dispRefreshing then return end
        if EH_Parent then
            local point, _, relPoint, _, y = EH_Parent:GetPoint(1)
            point = point or "CENTER"
            relPoint = relPoint or "CENTER"
            EH_Parent:ClearAllPoints()
            EH_Parent:SetPoint(point, UIParent, relPoint, v, y or 0)
            InfallDB.position = { point = point, relPoint = relPoint, x = v, y = y or 0 }
            ns.SaveCurrentProfile()
        end
    end)
    AddDispWidget(posXSlider)

    local posYSlider = CreateSlider(dispContent, "Y Offset", -1000, 1000, 1, curY, function(v)
        if dispRefreshing then return end
        if EH_Parent then
            local point, _, relPoint, x, _ = EH_Parent:GetPoint(1)
            point = point or "CENTER"
            relPoint = relPoint or "CENTER"
            EH_Parent:ClearAllPoints()
            EH_Parent:SetPoint(point, UIParent, relPoint, x or 0, v)
            InfallDB.position = { point = point, relPoint = relPoint, x = x or 0, y = v }
            ns.SaveCurrentProfile()
        end
    end)
    AddDispWidget(posYSlider)

    local smoothCheck = CreateCheckbox(dispContent, "Smooth Bar Animation", "Adds a smooth filling bar animation.", CONFIG.smoothBars or false, function(v)
        CONFIG.smoothBars = v
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(smoothCheck)

    local growUpCheck = CreateCheckbox(dispContent, "Grow Upward", "Frame grows upward when bars are added. Bottom edge stays fixed. Default is downward.", CONFIG.growDirection == "UP", function(v)
        CONFIG.growDirection = v and "UP" or nil
        if ns.NormalizeGrowAnchor then ns.NormalizeGrowAnchor() end
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(growUpCheck)

    dispContent:SetHeight(dispY + 20)

    displayTab:SetScript("OnShow", function()
        dispRefreshing = true
        futureSlider:SetValue(CONFIG.future or 16)
        pastSlider:SetValue(CONFIG.past or 2.5)
        widthSlider:SetValue(CONFIG.width or 352)
        heightSlider:SetValue(CONFIG.height or 20)
        extrasHeightSlider:SetValue(CONFIG.extrasHeight or CONFIG.height or 20)
        spacingSlider:SetValue(CONFIG.spacing or 0.5)
        scaleSlider:SetValue(CONFIG.scale or 1.0)
        padTopSlider:SetValue(CONFIG.paddingTop or 5)
        padBotSlider:SetValue(CONFIG.paddingBottom or 5)
        padLeftSlider:SetValue(CONFIG.paddingLeft or 5)
        padRightSlider:SetValue(CONFIG.paddingRight or 5)
        iconSizeSlider:SetValue(CONFIG.iconSize or 30)
        iconGapSlider:SetValue(CONFIG.iconGap or 10)
        nowLineSlider:SetValue(CONFIG.nowLineWidth or 2)
        gcdSparkSlider:SetValue(CONFIG.gcdSparkWidth or 3)
        staticCheck:SetChecked(CONFIG.staticHeight ~= nil)
        staticHeightSlider:SetValue(CONFIG.staticHeight or 150)
        staticFramesSlider:SetValue(CONFIG.staticFrames or 0)
        local refreshLinesStr = ""
        if CONFIG.lines then
            if type(CONFIG.lines) == "table" then
                local parts = {}
                for _, lv in ipairs(CONFIG.lines) do parts[#parts + 1] = tostring(lv) end
                refreshLinesStr = table.concat(parts, ", ")
            elseif type(CONFIG.lines) == "number" then
                refreshLinesStr = tostring(CONFIG.lines)
            end
        end
        linesEdit.editBox:SetText(refreshLinesStr)
        local px, py = GetFramePosition()
        posXSlider:SetValue(px)
        posYSlider:SetValue(py)
        smoothCheck:SetChecked(CONFIG.smoothBars or false)
        growUpCheck:SetChecked(CONFIG.growDirection == "UP")
        dispRefreshing = false
    end)

    -- ========================================================================
    -- TAB C: COLOURS
    -- ========================================================================
    BuildColoursTab(contentArea, tabFrames)

    -- ========================================================================
    -- TAB D: TOGGLES
    -- ========================================================================
    local togglesTab = CreateFrame("Frame", nil, contentArea)
    togglesTab:SetAllPoints()
    togglesTab:Hide()
    tabFrames[4] = togglesTab

    local togScroll, togContent = CreateScrollableContent(togglesTab)

    local togY = 0
    local function AddTogWidget(widget)
        widget:SetPoint("TOPLEFT", togContent, "TOPLEFT", 10, -togY)
        togY = togY + widget:GetHeight() + 6
    end

    local function AddTogHeader(text)
        togY = togY + 10
        local h = CreateSectionHeader(togContent, text)
        h:SetPoint("TOPLEFT", togContent, "TOPLEFT", 10, -togY)
        togY = togY + 22
    end

    AddTogHeader("Feature Toggles")

    local reactiveCheck = CreateCheckbox(togContent, "Reactive Icons", "Colour icons based on usability (mana, range)", CONFIG.reactiveIcons, function(v)
        CONFIG.reactiveIcons = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(reactiveCheck)

    local desatCheck = CreateCheckbox(togContent, "Desaturate on Cooldown", "Desaturate icons when ability is on cooldown", CONFIG.desaturateOnCooldown, function(v)
        CONFIG.desaturateOnCooldown = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(desatCheck)

    local redshiftCheck = CreateCheckbox(togContent, "Redshift", "Hide bars when out of combat with no hostile target", CONFIG.redshift, function(v)
        CONFIG.redshift = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(redshiftCheck)

    local pandemicCheck = CreateCheckbox(togContent, "Pandemic Pulse", "Pulse target debuff bars when in the refresh window", CONFIG.pandemicPulse, function(v)
        CONFIG.pandemicPulse = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(pandemicCheck)

    local castBarCheck = CreateCheckbox(togContent, "Hide Blizzard Cast Bar", "Hide Blizzard's default cast bar", CONFIG.hideBlizzCastBar, function(v)
        CONFIG.hideBlizzCastBar = v
        if ns.ApplyCastBarVisibility then ns.ApplyCastBarVisibility() end
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(castBarCheck)

    local lockedCheck = CreateCheckbox(togContent, "Locked", "Lock frame position (prevent dragging)", CONFIG.locked, function(v)
        CONFIG.locked = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(lockedCheck)

    local buffLayerCheck = CreateCheckbox(togContent, "Buff Bar On Top", "Draw the buff fill on top of the cooldown fill (same bar).", CONFIG.buffLayerAbove, function(v)
        CONFIG.buffLayerAbove = v
        if ns.ApplyBuffLayer and ns.cooldownBars then
            for _, row in ipairs(ns.cooldownBars) do
                ns.ApplyBuffLayer(row)
            end
        end
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(buffLayerCheck)

    local hideIconsCheck = CreateCheckbox(togContent, "Hide Icons", "Hide icons for a compact text only strip", CONFIG.hideIcons, function(v)
        CONFIG.hideIcons = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(hideIconsCheck)

    local clickthroughCheck = CreateCheckbox(togContent, "Clickthrough", "Make frame click through (also locks)", CONFIG.clickthrough or false, function(v)
        CONFIG.clickthrough = v
        if v then
            CONFIG.locked = true
            lockedCheck:SetChecked(true)
            if EH_Parent then EH_Parent:EnableMouse(false) end
        else
            if EH_Parent then EH_Parent:EnableMouse(true) end
        end
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(clickthroughCheck)

    local pastBarsCheck = CreateCheckbox(togContent, "Show Past Bars", "Show coloured history bars to the left of the now line", CONFIG.showPastBars ~= false, function(v)
        CONFIG.showPastBars = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(pastBarsCheck)

    AddTogHeader("Variant Names")

    local variantNamesCheck = CreateCheckbox(togContent, "Show Variant Names", "Show the name of aura variants on the bar, IE Roll the Bones outcomes. Spell names pass through the combat protection system so this always works in instances.", CONFIG.showVariantNames or false, function(v)
        CONFIG.showVariantNames = v
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(variantNamesCheck)

    -- ---- Cooldown Manager ----
    AddTogHeader("Cooldown Manager")

    local cdmStatusText = togContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cdmStatusText:SetPoint("TOPLEFT", togContent, "TOPLEFT", 14, -togY)
    cdmStatusText:SetJustifyH("LEFT")
    cdmStatusText:SetWidth(500)
    cdmStatusText:SetText("CDM: Checking...")
    togY = togY + 18

    local cdmDetailText = togContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cdmDetailText:SetPoint("TOPLEFT", togContent, "TOPLEFT", 14, -togY)
    cdmDetailText:SetJustifyH("LEFT")
    cdmDetailText:SetWidth(500)
    cdmDetailText:SetSpacing(2)
    cdmDetailText:SetText("")
    togY = togY + 26

    local function RefreshCDMStatus()
        if InCombatLockdown() then return end
        if not ns.GetCDMStatus then
            cdmStatusText:SetText("|cffFF6666CDM: Not loaded|r")
            cdmDetailText:SetText("")
            return
        end
        local cvarOn, allAlways = ns.GetCDMStatus()
        if not cvarOn then
            cdmStatusText:SetText("|cffFF6666CDM: Disabled|r")
            cdmDetailText:SetText("The Cooldown Manager CVar is off. Infall enables it automatically at login.")
        elseif not allAlways then
            cdmStatusText:SetText("|cffFFD100CDM: Not Always Visible|r")
            cdmDetailText:SetText("One or more CDM viewers not set to Always. Open Edit Mode and set each viewer to Always.")
        else
            cdmStatusText:SetText("|cff00FF00CDM: OK|r")
            cdmDetailText:SetText("All viewers set to Always.")
        end
    end

    local forceAlwaysCheck = CreateCheckbox(togContent, "Force Always Visible",
        "Infall requires CDM viewers set to Always so buff and cooldown frames stay populated. Disable only if another addon manages CDM visibility.",
        CONFIG.forceViewersAlways ~= false, function(v)
            CONFIG.forceViewersAlways = v
            if v and not InCombatLockdown() then
                if ns.ForceViewersAlways then ns.ForceViewersAlways() end
            end
            ns.SaveCurrentProfile()
            RefreshCDMStatus()
        end)
    AddTogWidget(forceAlwaysCheck)

    local hideEssentialCheck = CreateCheckbox(togContent, "Hide Essential CDs",
        "Hide Blizzard's Essential Cooldown viewer (rotational abilities).",
        CONFIG.hideEssentialCD, function(v)
            CONFIG.hideEssentialCD = v
            if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(hideEssentialCheck)

    local hideUtilityCheck = CreateCheckbox(togContent, "Hide Utility CDs",
        "Hide Blizzard's Utility Cooldown viewer (defensives, interrupts).",
        CONFIG.hideUtilityCD, function(v)
            CONFIG.hideUtilityCD = v
            if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(hideUtilityCheck)

    local hideBuffIconCheck = CreateCheckbox(togContent, "Hide Buff Icons",
        "Hide Blizzard's Buff Icon Cooldown viewer.",
        CONFIG.hideBuffIconCD, function(v)
            CONFIG.hideBuffIconCD = v
            if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(hideBuffIconCheck)

    local hideBuffBarCheck = CreateCheckbox(togContent, "Hide Buff Bars",
        "Hide Blizzard's Buff Bar Cooldown viewer.",
        CONFIG.hideBuffBarCD, function(v)
            CONFIG.hideBuffBarCD = v
            if ns.ApplyECMVisibility then ns.ApplyECMVisibility() end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(hideBuffBarCheck)

    -- Duration Text
    AddTogHeader("Duration Text")

    local showCdDurationCheck = CreateCheckbox(togContent, "Show Cooldown Duration",
        "Show remaining cooldown time on each bar using the game engine's built in countdown text. Shows m:ss for longer cooldowns and seconds for shorter ones. If a cooldown text addon overrides styling, configure it to ignore these frames.",
        CONFIG.showCooldownDuration, function(v)
            CONFIG.showCooldownDuration = v
            if ns.UpdateDurationTextSettings then ns.UpdateDurationTextSettings() end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(showCdDurationCheck)

    local cdMinDurSlider = CreateSlider(togContent, "Minimum Cooldown (seconds)", 0, 120, 1, CONFIG.cdTextMinDuration or 30, function(v)
        CONFIG.cdTextMinDuration = v
        if ns.UpdateDurationTextSettings then ns.UpdateDurationTextSettings() end
        ns.SaveCurrentProfile()
    end)
    AddTogWidget(cdMinDurSlider)

    -- Rune abilities. Only built when the class declares base cooldowns, so no
    -- other class sees a control that would do nothing.
    if CONFIG.runeBaseCooldowns then
        AddTogHeader("Rune Abilities")

        local runeCdCheck = CreateCheckbox(togContent, "Estimate Rune Cooldowns",
            "The game reports the later of an ability's own cooldown and the wait for runes, and gives addons no way to tell them apart. With this on, bars are rebuilt from the ability's real cooldown instead, so abilities with no cooldown of their own stop drawing a bar. Estimated: a cooldown reduction effect will make a bar run long.",
            CONFIG.estimateRuneCooldowns, function(v)
                CONFIG.estimateRuneCooldowns = v
                ns.SaveCurrentProfile()
                if ns.LoadEssentialCooldowns then ns.LoadEssentialCooldowns() end
            end)
        AddTogWidget(runeCdCheck)
    end

    -- Utility Buttons
    AddTogHeader("Utility")

    local reloadBtn = CreateFrame("Button", nil, togContent, "UIPanelButtonTemplate")
    reloadBtn:SetSize(140, 26)
    reloadBtn:SetText("Reload Bars")
    reloadBtn:SetPoint("TOPLEFT", togContent, "TOPLEFT", 10, -togY)
    reloadBtn:SetScript("OnClick", function()
        LoadEssentialCooldowns()
    end)
    reloadBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reload Bars")
        GameTooltip:AddLine("Force a full rebuild of all Infall bars.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    reloadBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    togY = togY + 34

    local resetPosBtn = CreateFrame("Button", nil, togContent, "UIPanelButtonTemplate")
    resetPosBtn:SetSize(140, 26)
    resetPosBtn:SetText("Reset Position")
    resetPosBtn:SetPoint("TOPLEFT", togContent, "TOPLEFT", 10, -togY)
    resetPosBtn:SetScript("OnClick", function()
        if EH_Parent then
            EH_Parent:ClearAllPoints()
            EH_Parent:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            InfallDB.position = nil
            ns.SaveCurrentProfile()
        end
    end)
    resetPosBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset Position")
        GameTooltip:AddLine("Move the bar frame back to the centre of the screen.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    resetPosBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    togY = togY + 34

    togContent:SetHeight(togY + 20)

    togglesTab:SetScript("OnShow", function()
        reactiveCheck:SetChecked(CONFIG.reactiveIcons)
        desatCheck:SetChecked(CONFIG.desaturateOnCooldown)
        redshiftCheck:SetChecked(CONFIG.redshift)
        pandemicCheck:SetChecked(CONFIG.pandemicPulse)
        castBarCheck:SetChecked(CONFIG.hideBlizzCastBar)
        lockedCheck:SetChecked(CONFIG.locked)
        buffLayerCheck:SetChecked(CONFIG.buffLayerAbove)
        hideIconsCheck:SetChecked(CONFIG.hideIcons)
        clickthroughCheck:SetChecked(CONFIG.clickthrough or false)
        pastBarsCheck:SetChecked(CONFIG.showPastBars ~= false)
        variantNamesCheck:SetChecked(CONFIG.showVariantNames or false)
        forceAlwaysCheck:SetChecked(CONFIG.forceViewersAlways ~= false)
        hideEssentialCheck:SetChecked(CONFIG.hideEssentialCD)
        hideUtilityCheck:SetChecked(CONFIG.hideUtilityCD)
        hideBuffIconCheck:SetChecked(CONFIG.hideBuffIconCD)
        hideBuffBarCheck:SetChecked(CONFIG.hideBuffBarCD)
        RefreshCDMStatus()
    end)

    -- ========================================================================
    -- TAB E: PROFILES
    -- ========================================================================
    local profilesTab = CreateFrame("Frame", nil, contentArea)
    profilesTab:SetAllPoints()
    profilesTab:Hide()
    tabFrames[7] = profilesTab

    local profScroll, profContent = CreateScrollableContent(profilesTab)

    local profY = 0

    local profHeader = CreateSectionHeader(profContent, "Named Profiles")
    profHeader:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profY = profY + 22

    local profileHint = profContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    profileHint:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profileHint:SetWidth(500)
    profileHint:SetJustifyH("LEFT")
    profileHint:SetSpacing(2)
    profileHint:SetText("Infall saves your settings automatically per character and spec. Named profiles let you save a snapshot of your current settings so you can share them between characters or quickly swap between setups.")
    profY = profY + profileHint:GetStringHeight() + 10

    local profileAutoHint = profContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    profileAutoHint:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profileAutoHint:SetWidth(500)
    profileAutoHint:SetJustifyH("LEFT")
    profileAutoHint:SetSpacing(2)
    profileAutoHint:SetText("The \"default\" profile always matches your class config defaults. Loading it reverts all settings to their original values.")
    profY = profY + profileAutoHint:GetStringHeight() + 12

    -- Load Profile section
    local loadHeader = CreateSectionHeader(profContent, "Load Profile")
    loadHeader:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profY = profY + 22

    local profileSelectBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    profileSelectBtn:SetSize(200, 24)
    profileSelectBtn:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profileSelectBtn:SetText("Select...")
    profileSelectBtn.selectedValue = nil

    local profileMenuFrame = CreateFrame("Frame", nil, profileSelectBtn, "BackdropTemplate")
    profileMenuFrame:SetPoint("TOPLEFT", profileSelectBtn, "BOTTOMLEFT", 0, -2)
    profileMenuFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    profileMenuFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    profileMenuFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    profileMenuFrame:SetFrameStrata("DIALOG")
    profileMenuFrame:Hide()

    local function RefreshProfileDropdown()
        for i = 1, profileBtnCacheCount do
            if profileBtnCache[i] then profileBtnCache[i]:Hide() end
        end

        InfallDB.namedProfiles = InfallDB.namedProfiles or {}
        if ns.classConfigDefaults then
            InfallDB.namedProfiles["default"] = DeepCopy(ns.classConfigDefaults)
        end

        local names = {}
        for name, _ in pairs(InfallDB.namedProfiles) do
            names[#names + 1] = name
        end
        table.sort(names)

        local menuHeight = 4
        for i, name in ipairs(names) do
            local optBtn = profileBtnCache[i]
            if not optBtn then
                optBtn = CreateFrame("Button", nil, profileMenuFrame)
                optBtn:SetSize(196, 20)
                optBtn:SetNormalFontObject("GameFontHighlightSmall")
                optBtn:SetHighlightFontObject("GameFontNormalSmall")
                local hl = optBtn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(0.3, 0.3, 0.5, 0.4)
                profileBtnCache[i] = optBtn
                profileBtnCacheCount = math.max(profileBtnCacheCount, i)
            end

            optBtn:Show()
            optBtn:ClearAllPoints()
            optBtn:SetPoint("TOPLEFT", 2, -(2 + (i - 1) * 20))
            optBtn:SetText(name)
            optBtn:GetFontString():SetJustifyH("LEFT")
            optBtn:GetFontString():SetPoint("LEFT", 4, 0)

            optBtn:SetScript("OnClick", function()
                profileSelectBtn:SetText(name)
                profileSelectBtn.selectedValue = name
                profileMenuFrame:Hide()
            end)

            menuHeight = menuHeight + 20
        end

        if #names == 0 then menuHeight = 24 end
        profileMenuFrame:SetSize(200, menuHeight)
    end

    profileSelectBtn:SetScript("OnClick", function()
        if profileMenuFrame:IsShown() then
            profileMenuFrame:Hide()
        else
            RefreshProfileDropdown()
            profileMenuFrame:Show()
        end
    end)

    profileMenuFrame:SetScript("OnShow", function()
        profileMenuFrame:SetScript("OnUpdate", function()
            if not profileMenuFrame:IsMouseOver() and not profileSelectBtn:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") then
                    profileMenuFrame:Hide()
                end
            end
        end)
    end)
    profileMenuFrame:SetScript("OnHide", function()
        profileMenuFrame:SetScript("OnUpdate", nil)
    end)

    local loadProfileBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    loadProfileBtn:SetSize(80, 24)
    loadProfileBtn:SetText("Load")
    loadProfileBtn:SetPoint("LEFT", profileSelectBtn, "RIGHT", 8, 0)
    loadProfileBtn:SetScript("OnClick", function()
        local name = profileSelectBtn.selectedValue
        if not name then
            print("|cff00ff00[Infall]|r Select a profile from the dropdown first.")
            return
        end
        InfallDB.namedProfiles = InfallDB.namedProfiles or {}
        local profile = InfallDB.namedProfiles[name]
        if profile then
            ns.ApplyProfile(profile)
            ns.SaveCurrentProfile()
            LoadEssentialCooldowns()
            if refreshSettingsUI then refreshSettingsUI() end
            print("|cff00ff00[Infall]|r Profile '" .. name .. "' loaded.")
        else
            print("|cff00ff00[Infall]|r Profile '" .. name .. "' not found.")
        end
    end)
    loadProfileBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Load Profile")
        GameTooltip:AddLine("Load the selected profile. Replaces all current settings.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    loadProfileBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local deleteProfileBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    deleteProfileBtn:SetSize(80, 24)
    deleteProfileBtn:SetText("Delete")
    deleteProfileBtn:SetPoint("LEFT", loadProfileBtn, "RIGHT", 8, 0)
    deleteProfileBtn:SetScript("OnClick", function()
        local name = profileSelectBtn.selectedValue
        if not name then
            print("|cff00ff00[Infall]|r Select a profile from the dropdown first.")
            return
        end
        if name == "default" then
            print("|cff00ff00[Infall]|r Cannot delete the default profile.")
            return
        end
        InfallDB.namedProfiles = InfallDB.namedProfiles or {}
        if InfallDB.namedProfiles[name] then
            InfallDB.namedProfiles[name] = nil
            profileSelectBtn:SetText("Select...")
            profileSelectBtn.selectedValue = nil
            print("|cff00ff00[Infall]|r Profile '" .. name .. "' deleted.")
        end
    end)
    deleteProfileBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete Profile")
        GameTooltip:AddLine("Permanently delete the selected profile.", 1, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    deleteProfileBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    profY = profY + 34

    -- Save Profile section
    profY = profY + 10
    local saveHeader = CreateSectionHeader(profContent, "Save Profile")
    saveHeader:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profY = profY + 22

    local saveHint = profContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    saveHint:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    saveHint:SetWidth(500)
    saveHint:SetJustifyH("LEFT")
    saveHint:SetSpacing(2)
    saveHint:SetText("Type a name and click Save to store your current settings as a named profile.")
    profY = profY + saveHint:GetStringHeight() + 8

    local saveNewEditBox = CreateFrame("EditBox", nil, profContent, "InputBoxTemplate")
    saveNewEditBox:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    saveNewEditBox:SetSize(200, 22)
    saveNewEditBox:SetAutoFocus(false)
    saveNewEditBox:SetFontObject("ChatFontNormal")
    saveNewEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    saveNewEditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local saveNewBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    saveNewBtn:SetSize(80, 24)
    saveNewBtn:SetText("Save")
    saveNewBtn:SetPoint("LEFT", saveNewEditBox, "RIGHT", 8, 0)
    saveNewBtn:SetScript("OnClick", function()
        local name = saveNewEditBox:GetText()
        if not name or name == "" or name:match("^%s*$") then
            print("|cff00ff00[Infall]|r Enter a name for the new profile.")
            return
        end
        name = name:match("^%s*(.-)%s*$")
        if name == "default" then
            print("|cff00ff00[Infall]|r Cannot overwrite the default profile.")
            return
        end
        InfallDB.namedProfiles = InfallDB.namedProfiles or {}
        ns.SaveCurrentProfile()
        local specKey = ns.currentSpecKey
        if specKey and InfallDB.profiles[specKey] then
            InfallDB.namedProfiles[name] = DeepCopy(InfallDB.profiles[specKey])
            profileSelectBtn:SetText(name)
            profileSelectBtn.selectedValue = name
            saveNewEditBox:SetText("")
            saveNewEditBox:ClearFocus()
            print("|cff00ff00[Infall]|r Profile '" .. name .. "' saved.")
        end
    end)
    saveNewBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Save Profile")
        GameTooltip:AddLine("Save your current settings under a new name.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    saveNewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    profY = profY + 32

    -- ========================================================================
    -- IMPORT / EXPORT
    -- ========================================================================

    profY = profY + 10
    local ieHeader = CreateSectionHeader(profContent, "Import / Export")
    ieHeader:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profY = profY + 22

    local ieHint = profContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ieHint:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    ieHint:SetWidth(500)
    ieHint:SetJustifyH("LEFT")
    ieHint:SetSpacing(2)
    ieHint:SetText("Share your settings as a string. Export your active spec or all specs at once. Includes colours, buff pairings, toggles, and frame position. Can be imported on any character of the same class.")
    profY = profY + ieHint:GetStringHeight() + 10

    -- Multi-line editbox inside a scroll frame with backdrop
    local ieBoxFrame = CreateFrame("Frame", nil, profContent, "BackdropTemplate")
    ieBoxFrame:SetSize(480, 80)
    ieBoxFrame:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    ieBoxFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    ieBoxFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    ieBoxFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local ieScroll = CreateFrame("ScrollFrame", nil, ieBoxFrame, "UIPanelScrollFrameTemplate")
    ieScroll:SetPoint("TOPLEFT", 4, -4)
    ieScroll:SetPoint("BOTTOMRIGHT", -22, 4)

    local ieEditBox = CreateFrame("EditBox", nil, ieScroll)
    ieEditBox:SetMultiLine(true)
    ieEditBox:SetAutoFocus(false)
    ieEditBox:SetFontObject("ChatFontNormal")
    ieEditBox:SetWidth(450)
    ieEditBox:SetMaxLetters(0)
    ieEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ieScroll:SetScrollChild(ieEditBox)

    profY = profY + 88

    local exportBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 24)
    exportBtn:SetText("Export")
    exportBtn:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    exportBtn:SetScript("OnClick", function()
        if not ns.ExportProfile then
            print("|cff00ff00[Infall]|r Export not available.")
            return
        end
        ns.SaveCurrentProfile()
        local specKey = ns.currentSpecKey
        if not specKey or not InfallDB.profiles[specKey] then
            print("|cff00ff00[Infall]|r No profile to export.")
            return
        end
        local str = ns.ExportProfile(InfallDB.profiles[specKey])
        if str then
            ieEditBox:SetText(str)
            ieEditBox:HighlightText()
            ieEditBox:SetFocus()
            print("|cff00ff00[Infall]|r Profile exported. Copy the string above.")
        else
            print("|cff00ff00[Infall]|r Export failed (serialization error).")
        end
    end)
    exportBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Export Profile")
        GameTooltip:AddLine("Export your active spec as a shareable string.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    exportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local exportAllBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    exportAllBtn:SetSize(120, 24)
    exportAllBtn:SetText("Export All Specs")
    exportAllBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    exportAllBtn:SetScript("OnClick", function()
        if not ns.ExportProfile then
            print("|cff00ff00[Infall]|r Export not available.")
            return
        end
        ns.SaveCurrentProfile()
        local name = UnitName("player")
        local realm = GetRealmName()
        if not name or not realm then
            print("|cff00ff00[Infall]|r Could not determine character.")
            return
        end
        local prefix = name .. "-" .. realm .. "-"
        local specs = {}
        local count = 0
        for key, profile in pairs(InfallDB.profiles) do
            if key:sub(1, #prefix) == prefix then
                local specID = tonumber(key:sub(#prefix + 1))
                if specID and specID > 0 then
                    specs[specID] = profile
                    count = count + 1
                end
            end
        end
        if count == 0 then
            print("|cff00ff00[Infall]|r No profiles found to export.")
            return
        end
        local data = { _multi = true, specs = specs }
        local str = ns.ExportProfile(data)
        if str then
            ieEditBox:SetText(str)
            ieEditBox:HighlightText()
            ieEditBox:SetFocus()
            print("|cff00ff00[Infall]|r Exported " .. count .. " spec(s). Copy the string above.")
        else
            print("|cff00ff00[Infall]|r Export failed (serialization error).")
        end
    end)
    exportAllBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Export All Specs")
        GameTooltip:AddLine("Export all specs for this character in one string.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    exportAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local importBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    importBtn:SetSize(80, 24)
    importBtn:SetText("Import")
    importBtn:SetPoint("LEFT", exportAllBtn, "RIGHT", 8, 0)
    importBtn:SetScript("OnClick", function()
        if not ns.ImportProfile then
            print("|cff00ff00[Infall]|r Import not available.")
            return
        end
        local text = ieEditBox:GetText()
        if not text or text:match("^%s*$") then
            print("|cff00ff00[Infall]|r Paste a profile string into the box first.")
            return
        end
        local data, err = ns.ImportProfile(text)
        if not data then
            print("|cff00ff00[Infall]|r Import failed: " .. (err or "unknown error"))
            return
        end
        if data._multi and data.specs then
            local name = UnitName("player")
            local realm = GetRealmName()
            if not name or not realm then
                print("|cff00ff00[Infall]|r Could not determine character.")
                return
            end
            local specIndex = GetSpecialization()
            local currentSpecID = specIndex and GetSpecializationInfo(specIndex)
            local count = 0
            for specID, profile in pairs(data.specs) do
                local numID = tonumber(specID) or specID
                local specKey = name .. "-" .. realm .. "-" .. numID
                InfallDB.profiles[specKey] = DeepCopy(profile)
                if currentSpecID and numID == currentSpecID then
                    ns.ApplyProfile(profile)
                end
                count = count + 1
            end
            ns.SaveCurrentProfile()
            ieEditBox:SetText("")
            ieEditBox:ClearFocus()
            print("|cff00ff00[Infall]|r Imported " .. count .. " spec(s). /reload to see all changes.")
        else
            ns.ApplyProfile(data)
            ns.SaveCurrentProfile()
            ieEditBox:SetText("")
            ieEditBox:ClearFocus()
            print("|cff00ff00[Infall]|r Profile imported and applied. /reload to see buff and cooldown changes.")
        end
    end)
    importBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Import Profile")
        GameTooltip:AddLine("Apply a profile string. Auto detects single or multi spec. Overwrites current settings.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    importBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    profY = profY + 34

    profContent:SetHeight(profY + 20)

    refreshSettingsUI = function()
        SelectTab(currentTab)
    end

    -- ========================================================================
    -- TAB F: STACKS
    -- ========================================================================
    BuildStacksTab(contentArea, tabFrames)

    -- ========================================================================
    -- TAB G: RESOURCE BAR
    -- ========================================================================
    if ns.BuildResourceBarTab then
        ns.BuildResourceBarTab(contentArea, tabFrames, {
            CreateCheckbox = CreateCheckbox,
            CreateSlider = CreateSlider,
            CreateColorSwatch = CreateColorSwatch,
            CreateSectionHeader = CreateSectionHeader,
            CreateScrollableContent = CreateScrollableContent,
            CreateDropdown = CreateDropdown,
            GetFontOptions = GetFontOptions,
            FONT_FLAG_OPTIONS = FONT_FLAG_OPTIONS,
            ANCHOR_POINTS = ANCHOR_POINTS,
        })
    end

    -- ========================================================================
    -- REGISTRATION
    -- ========================================================================

    local category = Settings.RegisterCanvasLayoutCategory(settingsFrame, "EventHorizon Infall")
    Settings.RegisterAddOnCategory(category)
    ns.settingsCategoryID = category:GetID()

    -- Make settings panel movable
    local panel = SettingsPanel
    if panel then
        panel:SetMovable(true)
        panel:SetClampedToScreen(true)
        panel:RegisterForDrag("LeftButton")
        panel:HookScript("OnDragStart", function(self)
            if InCombatLockdown() then return end
            self:StartMoving()
        end)
        panel:HookScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    end

    SelectTab(1)
end

-- ============================================================================
-- SETTINGS API
-- ============================================================================

-- Called at PLAYER_LOGIN to register the panel in the ESC menu
ns.InitSettings = BuildSettings

function ns.OpenSettings()
    BuildSettings()
    Settings.OpenToCategory(ns.settingsCategoryID)
end
