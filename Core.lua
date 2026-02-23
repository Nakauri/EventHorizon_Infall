-- EventHorizon Infall, Core

local ADDON_NAME = "EventHorizon_Infall"

EventHorizon_Infall = {}
local ns = EventHorizon_Infall

ns.ADDON_NAME = ADDON_NAME

ns.CONFIG = {
    width = 352,
    height = 20,  -- SINGLE ROW HEIGHT CONTROL
    spacing = 0.5,
    
    paddingTop = 5,
    paddingBottom = 5,
    paddingLeft = 5,
    paddingRight = 5,
    
    past = 2.5,       -- seconds left of now line
    future = 16,
    iconSize = 30,
    iconGap = 10,     -- px between icon and bar (0 = flush)
    
    nowLineColor = {1, 1, 1, 0.7},
    nowLineWidth = 2,
    
    gcdColor = {1, 1, 1, 0.1},
    gcdSparkColor = {1, 1, 1, 0.6},
    gcdSparkWidth = 3,
    
    cooldownColor = {171/255, 191/255, 181/255, 0.5},
    castColor = {0.2, 0.8, 0.2, 0.7},
    buffColor = {0.4, 0.4, 0.9, 0.6},
    debuffColor = {0.9, 0.3, 0.3, 0.6},
    petBuffColor = {0.3, 0.6, 0.9, 0.7},
    bgcolor = {0, 0, 0, 0.5},
    bordercolor = {0, 0, 0, 1},
    
    empowerStage1Color = {0.65, 0.15, 0.15, 0.7},
    empowerStage2Color = {0.90, 0.45, 0.10, 0.7},
    empowerStage3Color = {1.00, 0.75, 0.00, 0.7},
    empowerStage4Color = {1.00, 0.95, 0.45, 0.7},

    iconUsableColor = {1.0, 1.0, 1.0, 1.0},
    iconNotEnoughManaColor = {0.5, 0.5, 1.0, 1.0},
    iconNotUsableColor = {0.4, 0.4, 0.4, 1.0},
    iconNotInRangeColor = {0.64, 0.15, 0.15, 1.0},
    
    -- font: .ttf path or nil for default. fontFlags: "OUTLINE", "THICKOUTLINE", "MONOCHROME"
    font = nil,
    fontSize = 14,
    fontFlags = "OUTLINE",
    
    chargeTextColor = {1, 1, 1, 1},
    chargeTextAnchor = "BOTTOMRIGHT",
    chargeTextRelPoint = "BOTTOMRIGHT",
    chargeTextOffsetX = -2,
    chargeTextOffsetY = 2,
    
    stackTextColor = {1, 0.85, 0.3, 1},
    stackTextAnchor = "BOTTOMLEFT",
    stackTextRelPoint = "BOTTOMLEFT",
    stackTextOffsetX = 2,
    stackTextOffsetY = 2,

    showVariantNames = false,
    variantTextColor = {1, 0.85, 0.3, 1},
    variantTextSize = 12,
    variantTextAnchor = "LEFT",
    variantTextRelPoint = "LEFT",
    variantTextOffsetX = 5,
    variantTextOffsetY = 0,
    
    scale = 1.0,
    
    -- nil = frame grows with bar count, number = fixed px height; bars shrink to fit
    staticHeight = nil,
    staticFrames = 0,     -- min bar count before static mode kicks in
    
    -- nil = off, number = single line, table = multiple (IE {1, 3, 7})
    lines = nil,
    linesColor = {1, 1, 1, 0.3},
    
    -- defaults; overridden by SavedVariables at ADDON_LOADED
    reactiveIcons = true,
    desaturateOnCooldown = true,
    redshift = true,
    pandemicPulse = true,
    hideBlizzCastBar = true,
    hideBlizzECM = false,
    locked = false,
    buffLayerAbove = false,
    hideIcons = false,
    clickthrough = false,
    smoothBars = false,
    showPastBars = true,
}

InfallDB = InfallDB or {}

local EH_Parent = CreateFrame("Frame", "EH_MidnightContainer", UIParent, "BackdropTemplate")
-- Width: paddingLeft + icon + gap + bar + paddingRight
EH_Parent:SetSize(ns.CONFIG.paddingLeft + ns.CONFIG.iconSize + (ns.CONFIG.iconGap or 10) + ns.CONFIG.width + ns.CONFIG.paddingRight, 100)
EH_Parent:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
EH_Parent:SetClipsChildren(true)
EH_Parent:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile = false,
    tileSize = 0,
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
EH_Parent:SetBackdropColor(unpack(ns.CONFIG.bgcolor))
EH_Parent:SetBackdropBorderColor(unpack(ns.CONFIG.bordercolor))

ns.EH_Parent = EH_Parent
EH_Parent:SetScale(ns.CONFIG.scale)

function ns.ApplyBackdrop()
    EH_Parent:SetBackdropColor(unpack(ns.CONFIG.bgcolor))
    EH_Parent:SetBackdropBorderColor(unpack(ns.CONFIG.bordercolor))
end

ns.cooldownBars = {}
ns.barPool = {}