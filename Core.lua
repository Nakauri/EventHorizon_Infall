-- EventHorizon Infall, Core

local ADDON_NAME = "EventHorizon_Infall"

EventHorizon_Infall = {}
local ns = EventHorizon_Infall

ns.ADDON_NAME = ADDON_NAME

-- Forever, the Classic era client on the current engine, reports a 1.x interface number.
do
    local iface = select(4, GetBuildInfo()) or 0
    ns.IS_FOREVER = iface >= 16000 and iface < 20000
end

-- The global cooldown's reference spell. Forever answers nothing on 61304.
ns.GCD_SPELL = ns.IS_FOREVER and 29515 or 61304

-- Forever can answer UnitExists with a secret in combat; a secret counts as a target.
function ns.HasTarget()
    local v = UnitExists("target")
    if issecretvalue and issecretvalue(v) then return true end
    return v and true or false
end

-- Forever's Gamepad interface style blocks opening a Blizzard panel from addon code.
-- Read live; false on retail.
function ns.GamepadStyle()
    if not ns.IS_FOREVER then return false end
    local style, types = C_InputInterfaceStyle, Enum and Enum.InputDeviceInterfaceType
    if not style or not style.GetCurrentStyle or not types or types.Gamepad == nil then return false end
    local ok, cur = pcall(style.GetCurrentStyle)
    return ok and cur == types.Gamepad
end

-- True, with one line to chat, when a panel cannot open for that reason.
function ns.GamepadBlocks()
    if not ns.GamepadStyle() then return false end
    print("|cff00ff00[Infall]|r The Gamepad interface style blocks opening this. Switch to the Keyboard and Mouse style first.")
    return true
end

-- Start of every profile key. Forever's realm name changes as you zone or group,
-- so the key there is the name alone.
function ns.CharPrefix()
    local name = UnitName("player") or "?"
    if ns.IS_FOREVER then return name .. "-" end
    return name .. "-" .. (GetRealmName() or "?") .. "-"
end

-- Forever: a profile saved under the old Name-Realm-spec key is copied once to the
-- realm free key when that key has none. Never overwrites, never deletes; the current
-- realm wins, else a single other realm's. Tried once per key per session.
local realmKeyTried = {}
local function CopyTable(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = CopyTable(x) end
    return o
end
function ns.MigrateRealmKey(key, name, specID)
    local profiles = InfallDB and InfallDB.profiles
    if type(profiles) ~= "table" or next(profiles) == nil then return false end
    if profiles[key] ~= nil or realmKeyTried[key] then return false end
    realmKeyTried[key] = true
    local realm = GetRealmName and GetRealmName()
    local src = realm and profiles[name .. "-" .. realm .. "-" .. specID]
    if type(src) ~= "table" then
        local head, tail, found = name .. "-", "-" .. specID, nil
        for k, v in pairs(profiles) do
            if type(k) == "string" and type(v) == "table" and k ~= key
                and k:sub(1, #head) == head and k:sub(-#tail) == tail and #k > #head + #tail then
                if found then return false end
                found = v
            end
        end
        src = found
    end
    if type(src) ~= "table" then return false end
    profiles[key] = CopyTable(src)
    return true
end

-- The spell a Forever player actually casts: the CDM keys every rank on one id and
-- names the highest known rank in displaySpellID. Elsewhere the key itself.
function ns.RankID(info, key)
    if ns.IS_FOREVER and info then
        local d = info.displaySpellID
        if type(d) == "number" and not (issecretvalue and issecretvalue(d)) and d > 0 then
            return d
        end
    end
    return key
end

-- Forever casts carry the rank's own spell id while rows hold the shared key, and
-- every rank shares one name. Never true on retail.
local rankNames = {}
local function PlainName(id)
    local name = rankNames[id]
    if name == nil then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and type(n) == "string" and not (issecretvalue and issecretvalue(n)) then
            rankNames[id] = n
            return n
        end
        return false
    end
    return name
end
-- A row's spell to read on Forever: the highest known rank of its key. Elsewhere the key.
function ns.RowRankID(cooldownID, key)
    if not ns.IS_FOREVER or not cooldownID then return key end
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then return key end
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
    return ns.RankID(ok and info or nil, key)
end

-- A colour table: keys 1 to 4 only, 1 to 3 required, every value a number from 0 to 1.
function ns.ValidColour(c)
    if type(c) ~= "table" then return false end
    for k, x in pairs(c) do
        if type(k) ~= "number" or (k ~= 1 and k ~= 2 and k ~= 3 and k ~= 4) then return false end
        if issecretvalue and issecretvalue(x) == true then return false end
        if type(x) ~= "number" or x ~= x or x < 0 or x > 1 then return false end
    end
    return c[1] ~= nil and c[2] ~= nil and c[3] ~= nil
end

-- A stack count as text, empty at zero, secret counts included. Nil when the client lacks the API.
function ns.TruncateZero(n)
    local f = C_StringUtil and C_StringUtil.TruncateWhenZero
    if not f or n == nil then return nil end
    local ok, s = pcall(f, n)
    if ok and s ~= nil then return s end
    return nil
end

function ns.SameSpellByName(a, b)
    if not ns.IS_FOREVER or a == nil or b == nil then return false end
    if (issecretvalue and (issecretvalue(a) or issecretvalue(b))) then return false end
    if a == b then return true end
    local na = PlainName(a)
    return na and na == PlainName(b) or false
end

-- 12.1 moved both of these under C_SpecializationInfo. Blizzard's own UI calls the
-- bare globals zero times; every spec read in this addon goes through here.
function ns.SpecIndex()
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        return C_SpecializationInfo.GetSpecialization()
    end
    return GetSpecialization and GetSpecialization()
end

-- Full return list, matching Blizzard's. SpecIDFor is the id only.
function ns.SpecInfo(index)
    if not index then return nil end
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        return C_SpecializationInfo.GetSpecializationInfo(index)
    end
    if GetSpecializationInfo then return GetSpecializationInfo(index) end
    return nil
end

function ns.SpecIDFor(index)
    return (ns.SpecInfo(index))
end

-- The CDM carries no timing for an equipped item, only its slot, so the cooldown
-- comes from the slot. Returns durObj, readable; nil+true means genuinely ready.
function ns.ItemCooldownDurObj(equipSlot)
    if not equipSlot or not C_DurationUtil or not GetInventoryItemCooldown then
        return nil, false
    end
    local ok, start, dur, enable = pcall(GetInventoryItemCooldown, "player", equipSlot)
    if not ok or start == nil or dur == nil then return nil, false end
    if issecretvalue and (issecretvalue(start) or issecretvalue(dur) or issecretvalue(enable)) then
        return nil, false
    end
    -- 1.5 filters the GCD sized cooldown the slot reports right after any use.
    -- enable arrives as 1/0 or true/false.
    if not enable or enable == 0 or dur <= 1.5 or start <= 0 then return nil, true end
    local d = C_DurationUtil.CreateDuration()
    d:SetTimeFromStart(start, dur)
    return d, true
end

ns.CONFIG = {
    width = 352,
    height = 20,  -- SINGLE ROW HEIGHT CONTROL
    spacing = 0.5,
    
    paddingTop = 5,
    paddingBottom = 5,
    paddingLeft = 5,
    paddingRight = 5,
    
    past = 2.5,       -- seconds left of now line
    chargePastSmoothness = 3,  -- 1 to 4; middle charge lane past columns, 4 is 1px
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
    pressSparkColor = {0.34, 1, 0.35, 0.65},
    pressLateColor = {1, 0.35, 0.35, 0.9},
    pressSparkCastOnly = false,
    iconQueued = true,
    iconQueuedColor = {1, 1, 1, 0.22},

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

-- Combat potion entries carry the combat potion category with no spell and no slot.
ns.SPELL_CATEGORY_COMBAT_POTION = 4
function ns.IsCombatPotionEntry(spellID, equipSlot, categoryID)
    return not spellID and not equipSlot and categoryID == ns.SPELL_CATEGORY_COMBAT_POTION
end

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
-- Forever: a newly trained rank is a new spell id for the same entry.
if ns.IS_FOREVER then cooldownCacheWatcher:RegisterEvent("SPELLS_CHANGED") end
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

-- Cooldown Manager ids from a sibling spec. CDMSpecs.lua names the spec that owns every
-- id; a profile copied between specs of one class carries the other spec's ids, and those
-- match nothing here. Translation is by the same spell in the same group, in memory only.
do
    local index, indexClass

    local function BuildIndex(classID)
        local all = ns.IS_FOREVER and ns.CDM_SPECS_FOREVER or ns.CDM_SPECS
        local own, bySpec, spells = {}, {}, {}
        for cdID, row in pairs(all or {}) do
            if row[2] == classID then
                own[cdID] = row
                local spec, spell = row[1], row[3]
                local s = bySpec[spec]
                if not s then
                    s = { cd = {}, aura = {} }
                    bySpec[spec] = s
                    spells[spec] = {}
                end
                local g = s[row[4]]
                if g then
                    -- Two ids for one spell in one group: ambiguous, never a target.
                    if g[spell] == nil then g[spell] = cdID else g[spell] = false end
                end
                spells[spec][spell] = true
            end
        end
        index, indexClass = { own = own, bySpec = bySpec, spells = spells }, classID
    end

    -- True when the id belongs to another spec of this class.
    function ns.SiblingSpecCdID(id, specID, classID)
        if type(id) ~= "number" or not specID or not classID then return false end
        if indexClass ~= classID then BuildIndex(classID) end
        local row = index.own[id]
        return row ~= nil and row[1] ~= specID
    end

    -- The current spec's id for a sibling spec's id, and the spell both track. Nil for an
    -- id of this spec, of spec 0, of another class, an unknown id, an id that is also one
    -- of this spec's spellIDs (a spellID key), or no single match.
    function ns.LocalCdID(id, specID, classID)
        if not ns.SiblingSpecCdID(id, specID, classID) then return nil end
        local row, mine = index.own[id], index.bySpec[specID]
        if not mine or index.spells[specID][id] then return nil end
        local target = mine[row[4]][row[3]]
        if not target then return nil end
        return target, row[3]
    end
end

local function SameValue(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not SameValue(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- What automatic pairing writes: one mapping, buff ids and unit only. Never colour,
-- a custom timer, a glow source or a stack gate; every manual writer sets a colour.
local AUTO_FIELDS = { buffCooldownIDs = true, unit = true }
function ns.PairingAutoShaped(maps)
    if type(maps) ~= "table" then return false end
    local n = 0
    for k in pairs(maps) do
        n = n + 1
        if k ~= 1 then return false end
    end
    local m = maps[1]
    if n ~= 1 or type(m) ~= "table" or type(m.buffCooldownIDs) ~= "table" then return false end
    for k in pairs(m) do
        if not AUTO_FIELDS[k] then return false end
    end
    return true
end

local LOCALIZE_KEYED = { "extraCasts", "stackMappings", "hiddenCooldownIDs",
                         "chargesDisabled", "cooldownColors", "customIcons" }

local function Filled(v)
    return type(v) == "table" and next(v) ~= nil
end

-- Pick who moves onto one target. Exactly one user value wins; only interchangeable
-- values: one on the icon strip first, then the lowest id; two or more user values:
-- nobody, all stay.
local function Winner(xs, userTest, icons)
    table.sort(xs, function(a, b)
        local ia, ib = icons[a] ~= nil, icons[b] ~= nil
        if ia ~= ib then return ia end
        return a < b
    end)
    local users = {}
    for _, x in ipairs(xs) do
        if userTest(x) then users[#users + 1] = x end
    end
    if #users == 1 then return users[1] end
    if #users == 0 then return xs[1] end
    return nil
end

local function Decide(groups, isTaken, userTest, plan, why, icons)
    for y, xs in pairs(groups) do
        if isTaken(y) then
            for _, x in ipairs(xs) do why[x] = "occupied" end
        else
            local win = Winner(xs, userTest, icons)
            for _, x in ipairs(xs) do
                if x == win then plan[x] = y else why[x] = win and "lost" or "several" end
            end
        end
    end
end

-- Pairings and their clear marks decide together, so a clear is never undone and an
-- automatic pairing on the target yields to the copied one.
local function PlanPairings(cfg, T, veto, defaults, icons)
    local bm, cl = cfg.buffMappings or {}, cfg.pairingCleared or {}
    local dbm = defaults and defaults.pairings or {}
    local groups, plan, why, spellOf = {}, {}, {}, {}
    local function consider(x)
        local y, spell = T(x)
        if not y then return end
        local cleared = cl[x] ~= nil
        if not cleared and not Filled(bm[x]) then return end
        if veto[x] then why[x] = veto[x] return end
        if not cleared and SameValue(bm[x], dbm[x]) then why[x] = "default" return end
        groups[y] = groups[y] or {}
        table.insert(groups[y], x)
        spellOf[y] = spell
    end
    for x in pairs(bm) do consider(x) end
    for x in pairs(cl) do
        if bm[x] == nil then consider(x) end
    end
    -- A target holding its class default yields like an automatic one.
    local function occupied(y)
        local s = spellOf[y]
        if cl[y] ~= nil or cl[s] ~= nil or Filled(bm[s]) then return true end
        return Filled(bm[y]) and not ns.PairingAutoShaped(bm[y]) and not SameValue(bm[y], dbm[y])
    end
    local function isUser(x)
        return cl[x] ~= nil or not ns.PairingAutoShaped(bm[x])
    end
    -- An automatic pairing never replaces another automatic one. One on the icon strip
    -- folds into its target only when the target ends with a filled pairing, so its icon
    -- can follow; otherwise it stays, and its icon with it.
    local merge = {}
    for y, xs in pairs(groups) do
        if occupied(y) then
            for _, x in ipairs(xs) do why[x] = "occupied" end
        else
            local yAuto, users = Filled(bm[y]), {}
            for _, x in ipairs(xs) do
                if isUser(x) then users[#users + 1] = x end
            end
            local win
            if #users == 1 then
                win = users[1]
            elseif #users == 0 and not yAuto then
                win = Winner(xs, isUser, icons)
            end
            local filled
            if win then filled = cl[win] == nil and Filled(bm[win]) else filled = yAuto end
            for _, x in ipairs(xs) do
                if x == win then
                    plan[x] = y
                elseif not isUser(x) and icons[x] and filled then
                    plan[x], merge[x] = y, true
                elseif not isUser(x) and icons[x] and win then
                    why[x] = "no-fold"
                else
                    why[x] = (#users > 1 and "several") or ((yAuto and #users == 0) and "occupied") or "lost"
                end
            end
        end
    end
    return plan, why, merge
end

local function PlanKeyed(t, d, T, veto, icons)
    local groups, plan, why, spellOf = {}, {}, {}, {}
    for x, v in pairs(t) do
        local y, spell = T(x)
        if y then
            if veto[x] then
                why[x] = veto[x]
            elseif d and SameValue(v, d[x]) then
                why[x] = "default"
            else
                groups[y] = groups[y] or {}
                table.insert(groups[y], x)
                spellOf[y] = spell
            end
        end
    end
    local function taken(y)
        if t[spellOf[y]] ~= nil then return true end
        return t[y] ~= nil and not (d and d[y] ~= nil and SameValue(t[y], d[y]))
    end
    -- Values that all match are interchangeable; any difference is a user choice each.
    local first = {}
    for y, xs in pairs(groups) do first[y] = t[xs[1]] end
    local function userValue(x)
        local y = T(x)
        for _, other in ipairs(groups[y]) do
            if not SameValue(t[other], first[y]) then return true end
        end
        return false
    end
    Decide(groups, taken, userValue, plan, why, icons)
    return plan, why
end

-- An icon or stack pip whose target is already on the same side never moves, and of two
-- that would land on one target only one does. A refused one stays foreign everywhere.
local function ListVetoes(list, sideOf, T, veto, rank)
    local native, groups = {}, {}
    for _, e in ipairs(list or {}) do
        local id = e.cooldownID
        if id ~= nil then
            local side, y = sideOf(e), T(id)
            if y then
                local key = side .. ":" .. y
                groups[key] = groups[key] or { y = y, side = side, xs = {}, n = {} }
                local g = groups[key]
                if not g.n[id] then table.insert(g.xs, id) end
                g.n[id] = (g.n[id] or 0) + 1
            else
                native[side .. ":" .. tostring(id)] = true
            end
        end
    end
    for key, g in pairs(groups) do
        local live = {}
        for _, x in ipairs(g.xs) do
            if not veto[x] then live[#live + 1] = x end
        end
        table.sort(live, function(a, b)
            local pa, pb = rank(a), rank(b)
            if pa ~= pb then return pa end
            return a < b
        end)
        for i, x in ipairs(live) do
            if native[key] then
                veto[x] = "icon-taken"
            elseif i > 1 or g.n[x] > 1 then
                veto[x] = "icon-twice"
            end
        end
    end
end

local function IconSide(e) return e.container or "TOP" end
local function OneSide() return "LIST" end

-- Plans every table, vetoing until nothing changes: an icon never splits from its
-- pairing or its custom icon, so an icon whose pairing stays keeps its id too.
local function PlanAll(cfg, T, defaults)
    local veto, plans, whys, icons = {}, {}, {}, {}
    for _, e in ipairs(cfg.iconList or {}) do
        if e.cooldownID ~= nil then icons[e.cooldownID] = true end
    end
    for _ = 1, 20 do
        local before = 0
        for _ in pairs(veto) do before = before + 1 end
        plans.pairings, whys.pairings, plans.merge = PlanPairings(cfg, T, veto, defaults, icons)
        for _, name in ipairs(LOCALIZE_KEYED) do
            plans[name], whys[name] = PlanKeyed(cfg[name] or {}, defaults and defaults[name], T, veto, icons)
        end
        local function prefer(x) return plans.pairings[x] ~= nil end
        ListVetoes(cfg.iconList, IconSide, T, veto, prefer)
        ListVetoes(cfg.stackIndicatorList, OneSide, T, veto, prefer)
        local bm, cl = cfg.buffMappings or {}, cfg.pairingCleared or {}
        local dbm = defaults and defaults.pairings or {}
        for _, e in ipairs(cfg.iconList or {}) do
            local x = e.cooldownID
            if T(x) and not veto[x] then
                -- A class default pairing exists in every spec, so it never holds an icon back.
                local paired = (Filled(bm[x]) and not SameValue(bm[x], dbm[x])) or cl[x] ~= nil
                if (paired and not plans.pairings[x])
                    or (cfg.customIcons and cfg.customIcons[x] ~= nil and not plans.customIcons[x]) then
                    veto[x] = "icon-pairing"
                end
            end
        end
        local after = 0
        for _ in pairs(veto) do after = after + 1 end
        if after == before then break end
    end
    return plans, whys, veto
end

-- One more move, and the id it moved, so the report can count ids once.
local function Moved(res, x)
    res.moved = res.moved + 1
    res.ids[x] = true
end

local function MoveKeys(t, plan, res)
    for x, y in pairs(plan) do
        t[y], t[x] = t[x], nil
        Moved(res, x)
    end
end

local function LocalizeValues(cfg, T, veto, defaults, res)
    local dbm = defaults and defaults.pairings or {}
    for k, maps in pairs(cfg.buffMappings or {}) do
        if type(maps) == "table" and not T(k) and not SameValue(maps, dbm[k]) then
            for _, m in pairs(maps) do
                local list = type(m) == "table" and m.buffCooldownIDs
                if type(list) == "table" then
                    for i, v in ipairs(list) do
                        local y = T(v)
                        if y and not veto[v] then
                            local dup = false
                            for _, w in ipairs(list) do
                                if w == y then dup = true break end
                            end
                            if dup then
                                res.kept = res.kept + 1
                                res.reasons["in-list"] = (res.reasons["in-list"] or 0) + 1
                            else
                                list[i] = y
                                Moved(res, v)
                            end
                        end
                    end
                end
            end
        end
    end
    local dsm = defaults and defaults.stackMappings or {}
    for k, sm in pairs(cfg.stackMappings or {}) do
        if type(sm) == "table" and not T(k) and not SameValue(sm, dsm[k]) then
            local y = T(sm.buffCooldownID)
            local x = sm.buffCooldownID
            if y and not veto[x] then
                sm.buffCooldownID = y
                Moved(res, x)
            end
        end
    end
end

-- Rewrites a sibling spec's ids in a CONFIG shaped table to this spec's, in place. Never
-- touches a value equal to its class default, and never deletes a setting: an id that
-- cannot move stays exactly as it was. Running it twice changes nothing.
function ns.LocalizeProfileIDs(cfg, specID, classID, defaults)
    local res = { moved = 0, kept = 0, reasons = {}, ids = {}, idCount = 0, keptIDs = 0 }
    if ns.IS_FOREVER or type(cfg) ~= "table" or not specID or not classID then return res end
    local function Target(id) return ns.LocalCdID(id, specID, classID) end
    local plans, whys, veto = PlanAll(cfg, Target, defaults)

    local bm, cl = cfg.buffMappings or {}, cfg.pairingCleared or {}
    for x, y in pairs(plans.pairings) do
        if plans.merge[x] then
            bm[x] = nil
        else
            local v = bm[x]
            if v == nil and cl[x] ~= nil then v = {} end
            bm[y], bm[x] = v, nil
            if cl[x] ~= nil then cl[y], cl[x] = cl[x], nil end
        end
        Moved(res, x)
    end
    cfg.buffMappings, cfg.pairingCleared = bm, cl
    for _, name in ipairs(LOCALIZE_KEYED) do
        if cfg[name] then MoveKeys(cfg[name], plans[name], res) end
    end
    for _, list in ipairs({ cfg.iconList or {}, cfg.stackIndicatorList or {} }) do
        for _, e in ipairs(list) do
            local x = e.cooldownID
            local y = Target(x)
            if y and not veto[x] then
                e.cooldownID = y
                Moved(res, x)
            elseif y then
                whys.list = whys.list or {}
                whys.list[x] = veto[x]
            end
        end
    end
    LocalizeValues(cfg, Target, veto, defaults, res)

    res.detail = {}
    local keptIDs = {}
    for name, why in pairs(whys) do
        for x, reason in pairs(why) do
            res.kept = res.kept + 1
            res.reasons[reason] = (res.reasons[reason] or 0) + 1
            res.detail[name .. " " .. tostring(x)] = reason
            keptIDs[x] = true
        end
    end
    for _ in pairs(res.ids) do res.idCount = res.idCount + 1 end
    for _ in pairs(keptIDs) do res.keptIDs = res.keptIDs + 1 end
    return res
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

-- The one slot highlight, slot.selectionGlow: the action bar flash pulsing on its
-- alpha, or a flat green box where that atlas is missing. Callers only Show and Hide it.
local function NewSlotHighlight(slot, size, A)
    local flash = A and A("UI-HUD-ActionBar-IconFrame-Flash")
    if not flash then
        local glow = slot:CreateTexture(nil, "OVERLAY")
        glow:SetPoint("TOPLEFT", -2, 2)
        glow:SetPoint("BOTTOMRIGHT", 2, -2)
        glow:SetColorTexture(0.2, 1, 0.2, 0.35)
        glow:Hide()
        return glow
    end
    local holder = CreateFrame("Frame", nil, slot)
    holder:SetAllPoints()
    local tex = holder:CreateTexture(nil, "OVERLAY")
    tex:SetAtlas("UI-HUD-ActionBar-IconFrame-Flash", false)
    -- Blizzard's flash is red ("cannot use"); a free slot reads as an invitation, so green.
    tex:SetDesaturated(true)
    tex:SetVertexColor(0.45, 1, 0.45)
    -- Desaturated, the art is a dim grey; added to the slot it glows instead of darkening.
    tex:SetBlendMode("ADD")
    local k = size / 45
    tex:SetSize(flash.width * k, flash.height * k)
    tex:SetPoint("TOPLEFT")
    local anim = holder:CreateAnimationGroup()
    anim:SetLooping("BOUNCE")
    local pulse = anim:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.45)
    pulse:SetToAlpha(1)
    pulse:SetDuration(0.7)
    pulse:SetSmoothing("IN_OUT")
    holder:SetScript("OnShow", function() anim:Play() end)
    holder:SetScript("OnHide", function() anim:Stop() end)
    holder:Hide()
    return holder
end

-- A pairing slot (Bars and Icons tabs), drawn as an empty action bar slot; the old
-- flat box where the action bar art is missing. The icon is slot.icon, hidden.
function ns.NewPairingSlot(parent, size)
    local A = C_Texture and C_Texture.GetAtlasInfo
    local hasArt = A and A("UI-HUD-ActionBar-IconFrame-Background") ~= nil
        and A("UI-HUD-ActionBar-IconFrame") ~= nil
    local slot = CreateFrame("Button", nil, parent, not hasArt and "BackdropTemplate" or nil)
    slot:SetSize(size, size)

    local icon = slot:CreateTexture(nil, "ARTWORK")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:Hide()
    slot.icon = icon
    slot.selectionGlow = NewSlotHighlight(slot, size, A)

    if not hasArt then
        slot:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        slot:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
        slot:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        return slot
    end

    local fill = slot:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(0.03, 0.03, 0.04, 0.6)

    local bg = slot:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAllPoints()
    bg:SetAtlas("UI-HUD-ActionBar-IconFrame-Background")
    bg:SetAlpha(0.7)

    if A("ui-hud-actionbar-iconframe-slot") then
        local art = slot:CreateTexture(nil, "BACKGROUND", nil, 2)
        art:SetAllPoints()
        art:SetAtlas("ui-hud-actionbar-iconframe-slot")
        art:SetAlpha(0.7)
    end

    -- Blizzard centres the mask at its atlas size on a 45 unit button; stretched to
    -- the slot it cuts the icon down inside the frame.
    icon:SetAllPoints()
    local maskInfo = A("UI-HUD-ActionBar-IconFrame-Mask")
    if maskInfo then
        local mask = slot:CreateMaskTexture()
        mask:SetAtlas("UI-HUD-ActionBar-IconFrame-Mask", false)
        local k = size / 45
        mask:SetSize(maskInfo.width * k, maskInfo.height * k)
        mask:SetPoint("CENTER")
        fill:AddMaskTexture(mask)
        icon:AddMaskTexture(mask)
    end

    local border = slot:CreateTexture(nil, "OVERLAY")
    border:SetAtlas("UI-HUD-ActionBar-IconFrame")
    border:SetAllPoints()
    if A("UI-HUD-ActionBar-IconFrame-Mouseover") then
        slot:SetHighlightAtlas("UI-HUD-ActionBar-IconFrame-Mouseover", "ADD")
    end
    return slot
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

-- A spell learned or unlearned outside a talent event: the cache only, called first
-- from Bars.lua's SPELLS_CHANGED handler.
function ns.ClearTalentCache() wipe(talentKnown) end

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
