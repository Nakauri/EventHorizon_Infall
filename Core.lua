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

    disintegrateChainColor = {0.3, 0.9, 0.9, 0.7},

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

    showCooldownDuration = false,
    cdTextMinDuration = 30,
    cdDurationTextColor = {1, 1, 1, 1},
    cdDurationTextSize = 12,
    cdDurationTextAnchor = "RIGHT",
    cdDurationTextRelPoint = "RIGHT",
    cdDurationTextOffsetX = -2,
    cdDurationTextOffsetY = 0,

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
    hideEssentialCD = false,
    hideUtilityCD = false,
    hideBuffIconCD = false,
    hideBuffBarCD = false,
    locked = false,
    buffLayerAbove = false,
    hideIcons = false,
    clickthrough = false,
    smoothBars = false,
    showPastBars = true,
    forceViewersAlways = true,
    stackIndicators = false,

    customIcons = {},
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

-- Generic display for item categories that have no recent source yet. Mirrors
-- the Cooldown Manager's own spellCategoryMetadataLookup, so the names and
-- icons match what the player sees there.
ns.SPELL_CATEGORY_DISPLAY = {
    [4]    = { icon = "Interface/ICONS/INV_POTION_114",      name = COOLDOWN_VIEWER_TOOLTIP_POTION_COMBAT_TITLE },
    [30]   = { icon = "Interface/ICONS/INV_POTION_54",       name = COOLDOWN_VIEWER_TOOLTIP_POTION_HEALTH_TITLE },
    [1711] = { icon = "Interface/ICONS/Warlock_ Healthstone", name = COOLDOWN_VIEWER_TOOLTIP_POTION_HEALTHSTONE_TITLE },
    [2566] = { icon = "Interface/ICONS/Warlock_ Bloodstone",  name = COOLDOWN_VIEWER_TOOLTIP_POTION_DEMONIC_HEALTHSTONE_TITLE },
}

-- Display name and icon for a Cooldown Manager entry.
--
-- Not every entry is a spell. Potions and consumables carry a spellCategoryID
-- with no spellID, and trinkets carry an equipSlot, so a spell lookup returns
-- nothing and the entry renders as a bare cooldown id. Resolution order
-- follows the Cooldown Manager's own: equipped item, then the most recent
-- source in the spell category, then the spell.
function ns.ResolveCooldownDisplay(cooldownID, cdInfo)
    if not cooldownID then return nil, nil end
    if not cdInfo then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
        cdInfo = ok and info or nil
    end
    if not cdInfo then return nil, nil end

    -- Equipped item, ie a trinket.
    if cdInfo.equipSlot then
        local iiOk, itemID = pcall(GetInventoryItemID, "player", cdInfo.equipSlot)
        if iiOk and itemID and not (issecretvalue and issecretvalue(itemID)) then
            local nOk, name = pcall(C_Item.GetItemNameByID, itemID)
            local iOk, icon = pcall(C_Item.GetItemIconByID, itemID)
            name = nOk and name or nil
            icon = iOk and icon or nil
            if name or icon then return name, icon end
        end
        local slotTex = ItemUtil and ItemUtil.GetEquipSlotTexture
            and ItemUtil.GetEquipSlotTexture(cdInfo.equipSlot)
        if slotTex then return nil, slotTex end
    end

    -- Bag item, ie a potion or healthstone. The category reports whatever most
    -- recently started a cooldown in it, so it is unresolved until the player
    -- uses one; the category metadata below covers that case.
    if cdInfo.spellCategoryID then
        -- GetLastCategoryCooldownSource carries SecretWhenCooldownsRestricted,
        -- so both returns are secret in combat. C_Item's lookups reject secret
        -- arguments outright, and a secret name cannot be sorted or compared,
        -- so anything secret falls through to the static metadata below.
        local issecret = issecretvalue or function() return false end
        if C_Spell.GetLastCategoryCooldownSource then
            local ok, spellID, itemID = pcall(C_Spell.GetLastCategoryCooldownSource, cdInfo.spellCategoryID)
            if ok then
                if itemID and not issecret(itemID) then
                    local nOk, name = pcall(C_Item.GetItemNameByID, itemID)
                    local iOk, icon = pcall(C_Item.GetItemIconByID, itemID)
                    name = nOk and name or nil
                    icon = iOk and icon or nil
                    if name or icon then return name, icon end
                end
                if spellID and not issecret(spellID) then
                    return C_Spell.GetSpellName(spellID), C_Spell.GetSpellTexture(spellID)
                end
            end
        end
        local meta = ns.SPELL_CATEGORY_DISPLAY[cdInfo.spellCategoryID]
        if meta then return meta.name, meta.icon end
    end

    local sid = cdInfo.overrideTooltipSpellID or cdInfo.overrideSpellID or cdInfo.spellID
    if sid then
        return C_Spell.GetSpellName(sid), C_Spell.GetSpellTexture(sid)
    end
    return nil, nil
end
