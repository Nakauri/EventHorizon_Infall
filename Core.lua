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
    
    -- Space left of the bars when icons are hidden. 0 puts them flush.
    hiddenIconWidth = 0,

    gcdColor = {1, 1, 1, 0.1},
    gcdSparkColor = {1, 1, 1, 0.6},
    gcdSparkWidth = 3,

    -- Marks where the spell queue window opens. Off by default.
    queueSpark = false,
    queueSparkWidth = 2,
    queueSparkColor = {1, 0.82, 0, 0.8},
    queueBarColor = {1, 0.82, 0, 0.12},

    pressSpark = false,
    pressSparkWidth = 2,
    pressSparkColor = {0.4, 0.7, 1, 0.9},

    -- Notches on a buff bar at each of its periodic ticks. Off by default.
    dotTicks = false,
    dotTickWidth = 1,
    dotTickColor = {1, 1, 1, 0.45},

    -- Off by default: it draws over every lane, so it is not something to inflict
    -- on a player who did not ask for it.
    castSpark = false,
    castSparkWidth = 1,
    castSparkColor = {0.2, 0.8, 0.2, 0.9},
    castSparkMatchCast = true,


    cooldownColor = {171/255, 191/255, 181/255, 0.5},
    castColor = {0.2, 0.8, 0.2, 0.7},
    buffColor = {0.4, 0.4, 0.9, 0.6},
    potionBuffColor = {0.4, 0.4, 0.9, 0.6},
    debuffColor = {0.9, 0.3, 0.3, 0.6},
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
    -- Off by default and read as opt-in, never as "on unless disabled". Pairing a
    -- row to the wrong Cooldown Manager entry lights an icon on someone else's
    -- aura, and a wrong guess is worse than an empty pairing the player fills in.
    autoPairBuffs = false,
    stackIndicators = false,
    -- ApplyProfile skips nil keys, so a toggle with no default sticks at its last
    -- value for any profile seeded before it existed.
    estimateRuneCooldowns = false,

    customIcons = {},

    -- Icon strip defaults live HERE, not in Icons.lua: ns.classConfigDefaults is built
    -- at Settings.lua file scope, so a default declared later snapshots as empty.
    iconsEnabled = false,
    iconContainers = {},   -- { key, anchor, grow, mode, size, spacing, perLine, zoom, text = {} }
    iconList = {},         -- { cooldownID, container, enabled, states = {} }
    iconIgnoreGCD = true,
    iconStates = {},       -- ready|buff|cooldown|unusable = { show, desaturate, sweep, timer }
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

-- Generic display for item categories that have no recent source yet. Mirrors the
-- Cooldown Manager's own lookup, so the names and icons match.
ns.SPELL_CATEGORY_DISPLAY = {
    [4]    = { icon = "Interface/ICONS/INV_POTION_114",      name = COOLDOWN_VIEWER_TOOLTIP_POTION_COMBAT_TITLE },
    [30]   = { icon = "Interface/ICONS/INV_POTION_54",       name = COOLDOWN_VIEWER_TOOLTIP_POTION_HEALTH_TITLE },
    [1711] = { icon = "Interface/ICONS/Warlock_ Healthstone", name = COOLDOWN_VIEWER_TOOLTIP_POTION_HEALTHSTONE_TITLE },
    [2566] = { icon = "Interface/ICONS/Warlock_ Bloodstone",  name = COOLDOWN_VIEWER_TOOLTIP_POTION_DEMONIC_HEALTHSTONE_TITLE },
}

-- Display name and icon for a Cooldown Manager entry. Not every entry is a spell:
-- potions carry a spellCategoryID with no spellID, trinkets carry an equipSlot.
-- Order is equipped item, then the most recent source in the category, then the spell.
function ns.ResolveCooldownDisplay(cooldownID, cdInfo)
    if not cooldownID then return nil, nil end

    local tierSpell = ns.TierSpellIDForCooldown and ns.TierSpellIDForCooldown(cooldownID)
    if tierSpell then
        return C_Spell.GetSpellName(tierSpell), C_Spell.GetSpellTexture(tierSpell)
    end

    if not cdInfo then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
        cdInfo = ok and info or nil
    end
    if not cdInfo then return nil, nil end

    -- Equipped item, ie a trinket.
    if cdInfo.equipSlot then
        local iiOk, itemID = pcall(GetInventoryItemID, "player", cdInfo.equipSlot)
        if iiOk and itemID and not issecretvalue(itemID) then
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

    -- Bag item, ie a potion or healthstone. The category reports whatever most recently
    -- started a cooldown in it, so it is unresolved until the player uses one.
    if cdInfo.spellCategoryID then
        -- GetLastCategoryCooldownSource is secret in combat, C_Item rejects secret arguments,
        -- and a secret name cannot be sorted, so anything secret falls through to metadata.
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

-- Cooldown Manager order, read without building it. Its accessors build lazily and
-- a build on our stack is created tainted. IsDirty and GetDisplayData build nothing,
-- so read only when it is already built. Never call an accessor.

local orderCache = {}
local unknownOrderCache = {}

local function CleanProvider()
    local settings = CooldownViewerSettings
    if not settings or not settings.GetDataProvider then return nil end
    local ok, dp = pcall(settings.GetDataProvider, settings)
    if not ok or not dp then return nil end
    if not dp.IsDirty or not dp.GetOrderedCooldownIDsForCategory then return nil end
    local okDirty, dirty = pcall(dp.IsDirty, dp)
    if not okDirty or dirty then return nil end
    return dp
end

function ns.CooldownOrderReady()
    return CleanProvider() ~= nil
end

local CATEGORY_VIEWER = {
    [0] = "EssentialCooldownViewer",
    [1] = "UtilityCooldownViewer",
    [2] = "BuffIconCooldownViewer",
    [3] = "BuffBarCooldownViewer",
}

local function ByLayoutIndex(a, b)
    return a.order < b.order
end

-- nil means unknown, an empty table means the category is empty. A viewer only
-- fills in cooldownIDs while it is shown, and pads to two frames once laid out.
local function ViewerCooldownIDs(category)
    local viewerName = CATEGORY_VIEWER[category]
    local viewer = viewerName and _G[viewerName]
    local pool = viewer and viewer.itemFramePool
    if not pool or not pool.EnumerateActive then return nil end
    local shownOk, shown = pcall(viewer.IsShown, viewer)
    if not shownOk or not shown then return nil end

    local rows, active = {}, 0
    local ok = pcall(function()
        for frame in pool:EnumerateActive() do
            active = active + 1
            local id = frame.cooldownID
            if id then
                rows[#rows + 1] = { id = id, order = frame.layoutIndex or #rows + 1 }
            end
        end
    end)
    if not ok or active == 0 then return nil end

    local sortOk = pcall(table.sort, rows, ByLayoutIndex)
    if not sortOk then return nil end

    local ids = {}
    for i = 1, #rows do ids[i] = rows[i].id end
    return ids
end

-- The player's real order, or nil if neither source can answer.
function ns.OrderedCooldownIDs(category, allowUnknown)
    local cache = allowUnknown and unknownOrderCache or orderCache
    local dp = CleanProvider()
    if dp then
        local ok, ids = pcall(dp.GetOrderedCooldownIDsForCategory, dp, category, allowUnknown)
        if ok and type(ids) == "table" then
            cache[category] = ids
            return ids
        end
    end
    if allowUnknown then return cache[category] end
    local live = ViewerCooldownIDs(category)
    if live then
        cache[category] = live
        return live
    end
    return cache[category]
end

-- Identity sets expire with the build. The order caches are deliberately NOT
-- wiped: they are the last known good answer, and emptying them on the events
-- that leave the provider dirty produced phantom rows on a talent swap.
local cooldownCacheWatcher = CreateFrame("Frame")
cooldownCacheWatcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
cooldownCacheWatcher:RegisterEvent("TRAIT_CONFIG_UPDATED")
cooldownCacheWatcher:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
cooldownCacheWatcher:SetScript("OnEvent", function()
    if ns.AuraCompat and ns.AuraCompat.ClearIdentityCache then
        ns.AuraCompat.ClearIdentityCache()
    end
end)

-- Custom row and custom icon keys share one keyspace: the key indexes buffMappings,
-- extraCasts, stackMappings, cooldownColors and customIcons. Generate across both.

-- Mutated field by field, never replaced, so this reference stays valid.
local CONFIG = ns.CONFIG

local KEY_TABLES = { "buffMappings", "extraCasts", "stackMappings",
                     "cooldownColors", "customIcons" }

-- Settings.lua's DeepCopy is a file local, and a shared reference would leave
-- the two entries linked.
local function CopyDeep(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, sub in pairs(v) do out[k] = CopyDeep(sub) end
    return out
end

local function CollectKeys(into)
    for _, e in ipairs(CONFIG.extras or {}) do
        if e.key then into[e.key] = true end
    end
    for _, e in ipairs(CONFIG.iconList or {}) do
        if e.key then into[e.key] = true end
    end
    return into
end

function ns.NextCustomKey()
    local taken = CollectKeys({})
    local n = 1
    while taken["custom_" .. n] do n = n + 1 end
    return "custom_" .. n
end

-- Settings are copied, not moved: a collided pair is indistinguishable here.
function ns.MigrateCustomKeyCollisions()
    if not CONFIG.extras or not CONFIG.iconList then return 0 end

    local barKeys = {}
    for _, e in ipairs(CONFIG.extras) do
        if e.key then barKeys[e.key] = true end
    end

    local taken = CollectKeys({})
    local fixed = 0

    for _, e in ipairs(CONFIG.iconList) do
        if e.key and barKeys[e.key] then
            local n = 1
            while taken["custom_" .. n] do n = n + 1 end
            local newKey = "custom_" .. n
            taken[newKey] = true

            for _, tName in ipairs(KEY_TABLES) do
                local t = CONFIG[tName]
                if t and t[e.key] ~= nil then
                    t[newKey] = CopyDeep(t[e.key])
                end
            end

            e.key = newKey
            fixed = fixed + 1
        end
    end

    return fixed
end

-- Pixel grid. One physical pixel in a frame's own units, and snapping onto it.
-- GetPhysicalScreenSize can report 0 mid display-mode change, so the last good
-- height stands in.
local lastPhysH = 1080

function ns.OnePx(scale)
    local _, physH = GetPhysicalScreenSize()
    if physH and physH > 0 then lastPhysH = physH end
    if not scale or scale <= 0 then scale = 1 end
    return 768 / lastPhysH / scale
end

function ns.OnePxForFrame(frame)
    return ns.OnePx(frame and frame:GetEffectiveScale() or 1)
end

function ns.SnapPx(value, onePx)
    if value == 0 or not onePx or onePx <= 0 then return value end
    return math.floor(value / onePx + 0.5) * onePx
end

-- Talent tests, cached. Callers sit in per-frame paths and this is a C call, so
-- it resolves once per talent event and reads a table after that. Talents cannot
-- change in combat, so there is no in-combat refresh to miss.
local talentKnown = {}

function ns.IsTalentKnown(talentSpellID)
    if not talentSpellID then return true end
    local cached = talentKnown[talentSpellID]
    if cached ~= nil then return cached end

    local known = false
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, v = pcall(C_SpellBook.IsSpellKnown, talentSpellID)
        if ok and v then known = true end
    end
    if not known and IsPlayerSpell then
        local ok, v = pcall(IsPlayerSpell, talentSpellID)
        if ok and v then known = true end
    end
    talentKnown[talentSpellID] = known
    return known
end

local talentWatcher = CreateFrame("Frame")
talentWatcher:RegisterEvent("PLAYER_LOGIN")
talentWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
talentWatcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
talentWatcher:RegisterEvent("TRAIT_CONFIG_UPDATED")
talentWatcher:RegisterEvent("PLAYER_TALENT_UPDATE")
talentWatcher:SetScript("OnEvent", function()
    wipe(talentKnown)
    if ns.RefreshStackIndicatorGates then ns.RefreshStackIndicatorGates() end
end)

-- Fonts shipped with the addon, listed directly and registered with LibSharedMedia when present.
ns.BUNDLED_FONTS = {
    { name = "Accidental Presidency",
      path = [[Interface\AddOns\EventHorizon_Infall\fonts\Accidental Presidency.ttf]] },
    { name = "Expressway",
      path = [[Interface\AddOns\EventHorizon_Infall\fonts\Expressway.ttf]] },
}

local function RegisterBundledFonts()
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return false end
    for _, f in ipairs(ns.BUNDLED_FONTS) do
        LSM:Register("font", f.name, f.path)
    end
    return true
end

-- LibSharedMedia arrives from whichever addon embeds it and load order is not
-- guaranteed, so try now and again once everything has loaded.
if not RegisterBundledFonts() then
    local fontWatcher = CreateFrame("Frame")
    fontWatcher:RegisterEvent("PLAYER_LOGIN")
    fontWatcher:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        RegisterBundledFonts()
    end)
end

local spellTip

function ns.ShowSpellTooltip(spellID)
    if not spellID or (issecretvalue and issecretvalue(spellID)) then
        if spellTip then spellTip:Hide() end
        return
    end
    if not spellTip then
        spellTip = CreateFrame("GameTooltip", "EventHorizonInfallSpellTooltip",
            UIParent, "GameTooltipTemplate")
    end
    spellTip:SetOwner(UIParent, "ANCHOR_NONE")
    spellTip:ClearAllPoints()
    local right = GameTooltip:GetRight()
    local screen = UIParent:GetRight()
    if right and screen and (right + 300) > screen then
        spellTip:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT", -4, 0)
    else
        spellTip:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 4, 0)
    end
    if not pcall(spellTip.SetSpellByID, spellTip, spellID) then
        spellTip:Hide()
        return
    end
    spellTip:Show()
end

function ns.HideSpellTooltip()
    if spellTip then spellTip:Hide() end
end

function ns.ShowSlotSpellTooltip(slot)
    if not slot or slot.customEntry or not slot.pairedCooldownID then
        ns.HideSpellTooltip()
        return
    end
    local cdID = slot.pairedCooldownID
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    local sid = ok and info
        and (info.overrideTooltipSpellID or info.overrideSpellID or info.spellID)
    if not sid and ns.TierSpellIDForCooldown then
        sid = ns.TierSpellIDForCooldown(cdID)
    end
    ns.ShowSpellTooltip(sid)
end
