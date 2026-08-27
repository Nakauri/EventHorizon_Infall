-- EventHorizon Infall: Settings UI

local ns = EventHorizon_Infall
local CONFIG = ns.CONFIG
local EH_Parent = ns.EH_Parent

InfallDB = InfallDB or {}
InfallDB.profiles = InfallDB.profiles or {}
InfallDB.namedProfiles = InfallDB.namedProfiles or {}

-- PROFILE HELPERS

local TOGGLE_KEYS = {
    "reactiveIcons", "desaturateOnCooldown", "redshift",
    "pandemicPulse", "locked", "hideBlizzCastBar",
    "hideEssentialCD", "hideUtilityCD", "hideBuffIconCD", "hideBuffBarCD",
    "buffLayerAbove", "hideIcons", "clickthrough",
    "showVariantNames", "smoothBars", "showPastBars",
    "forceViewersAlways", "autoPairBuffs", "stackIndicators",
    "showCooldownDuration", "estimateRuneCooldowns",
    "iconsEnabled", "iconIgnoreGCD", "iconGlow", "castSpark", "castSparkMatchCast",
}

local DISPLAY_KEYS = {
    "width", "height", "spacing", "paddingTop", "paddingBottom",
    "paddingLeft", "paddingRight", "future", "past", "iconSize",
    "iconGap", "hiddenIconWidth", "nowLineWidth", "gcdSparkWidth", "castSparkWidth", "scale",
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
    "cooldownColor", "castColor", "buffColor", "debuffColor", "potionBuffColor",
    "bgcolor", "bordercolor", "nowLineColor", "gcdColor", "gcdSparkColor", "castSparkColor", "linesColor",
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


-- Search order is load bearing. Only a Tracked Bars entry (3) carries a .Bar,
-- and a .Bar is the only thing an icon wedge can mirror. Tracked Buffs (2) has
-- none, and a self mapping resolves to the ability's own cooldown frame, which
-- has none either. Reorder this and every wedge silently stops drawing.
-- Utility is deliberately absent: it would match every entry against itself.
local BUFF_SEARCH_CATEGORIES = { 3, 2 }

-- nil from OrderedCooldownIDs means the layout could not be read, which is not
-- the same as an empty category. Static defaults still answer, but they miss
-- anything the player dragged, so the caller is told the read is not trustworthy.
local function CategoryEntryIDs(category, allowUnknown)
    local ids = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(category, allowUnknown)
    if type(ids) == "table" then return ids, true end
    local ok, set = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category,
        allowUnknown and true or false)
    return (ok and set) or {}, false
end

-- Indexed by every spell id the entry can present, not just its base. A buff
-- whose entry names a variant the player has not talented is still the buff
-- the ability applies, and the base alone never matches it. Unlearned entries
-- are included for the same reason: that is where those variants sit.
-- Maps a spell id to EVERY entry that can present it, in category order. Only
-- one of them is ever fed, and which one is not knowable from config, so lane
-- resolution walks the list and takes the first with a live aura.
local function BuffEntryBySpell(categories)
    local bySpell, trusted = {}, true
    for _, cat in ipairs(categories) do
        local ids, ok = CategoryEntryIDs(cat, true)
        if not ok then trusted = false end
        for _, bcdID in ipairs(ids) do
            local identity = ns.AuraCompat and ns.AuraCompat.IdentityIDsForCooldown(bcdID)
            if identity then
                for _, sid in ipairs(identity) do
                    local list = bySpell[sid]
                    if not list then
                        bySpell[sid] = { bcdID }
                    else
                        local seen = false
                        for _, existing in ipairs(list) do
                            if existing == bcdID then seen = true break end
                        end
                        if not seen then list[#list + 1] = bcdID end
                    end
                end
            end
        end
    end
    return bySpell, trusted
end

-- Every entry id that could carry this cooldown's aura, in category order.
local function BuffEntriesFor(bySpell, cooldownID)
    local identity = ns.AuraCompat and ns.AuraCompat.IdentityIDsForCooldown(cooldownID)
    if not identity then return nil end
    local out, seen = {}, {}
    for _, sid in ipairs(identity) do
        local list = bySpell[sid]
        if list then
            for _, bcdID in ipairs(list) do
                if not seen[bcdID] then
                    seen[bcdID] = true
                    out[#out + 1] = bcdID
                end
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Which unit carries the aura, asked of the BUFF and not the ability: a harmful
-- ability can grant a buff that sits on the player. Falls back to the ability
-- only when the buff entry cannot be read.
local function MappingUnitFor(buffCooldownID, abilitySpellID)
    local sid
    if buffCooldownID then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCooldownID)
        if ok and info then
            sid = info.overrideTooltipSpellID or info.overrideSpellID or info.spellID
        end
    end
    sid = sid or abilitySpellID
    if sid and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(sid) then
        return "target"
    end
    return nil
end

-- A row cleared by hand stays cleared. Clearing the last slot leaves an empty
-- table, auto pairing reads empty as never paired, and the unpair handler's own
-- LoadEssentialCooldowns refilled it before the panel redrew, so the clear could
-- never stick while the toggle was on. Pairing a row again drops the mark, and
-- turning the toggle on wipes them all, which is the explicit "fill these in".
-- Only ever holds true or nil, so presence is the answer.
local function PairingCleared(cooldownID)
    local marks = CONFIG.pairingCleared
    return cooldownID ~= nil and marks ~= nil and marks[cooldownID] ~= nil
end

local function SetPairingCleared(cooldownID, cleared)
    if not cooldownID then return end
    CONFIG.pairingCleared = CONFIG.pairingCleared or {}
    CONFIG.pairingCleared[cooldownID] = cleared and true or nil
end

-- Custom timers: a length the player enters, started by casting the row's own
-- ability, for a buff the Cooldown Manager cannot time for us.

local customBuffApplied

StaticPopupDialogs["EVENTHORIZON_CUSTOM_BUFF_SECONDS"] = {
    text = "How many seconds does it last?",
    button1 = OKAY,
    button2 = CANCEL,
    hasEditBox = 1,
    editBoxWidth = 120,
    maxLetters = 12,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    -- dialog:GetEditBox(), never dialog.editBox. The field is not there on this
    -- client, so the old form handed back nil and the entered value was lost
    -- with no error anywhere.
    OnShow = function(dialog, data)
        local eb = dialog:GetEditBox()
        if eb then
            eb:SetText((data and data.prefill) and tostring(data.prefill) or "")
            eb:HighlightText()
            eb:SetFocus()
        end
    end,
    OnAccept = function(dialog, data)
        local eb = dialog:GetEditBox()
        if ns.ApplyCustomBuffSeconds then
            ns.ApplyCustomBuffSeconds(data, eb and eb:GetText())
        end
    end,
    EditBoxOnEnterPressed = function(editBox, data)
        if ns.ApplyCustomBuffSeconds then
            ns.ApplyCustomBuffSeconds(data, editBox:GetText())
        end
        editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox) editBox:GetParent():Hide() end,
}

-- data travels as StaticPopup_Show's fourth argument, prefill included, so the
-- popup can seed itself in OnShow without us reaching into a pooled frame.
local function PromptSeconds(ctx, prefill)
    ctx.prefill = prefill
    StaticPopup_Show("EVENTHORIZON_CUSTOM_BUFF_SECONDS", nil, nil, ctx)
end

function ns.ApplyCustomBuffSeconds(ctx, text)
    if type(ctx) ~= "table" or not ctx.cooldownID then return end
    local seconds = tonumber(tostring(text or ""):match("^%s*([%d%.]+)%s*$"))
    if not seconds or seconds <= 0 then return end

    CONFIG.buffMappings = CONFIG.buffMappings or {}
    local m = CONFIG.buffMappings[ctx.cooldownID] or {}
    -- Never leave a hole. Every reader walks these with ipairs, which stops at
    -- the first gap, so writing slot 2 into an empty list would store an entry
    -- that nothing ever sees.
    local slotIndex = math.min(ctx.slotIndex or 1, #m + 1)
    local existing = m[slotIndex]
    m[slotIndex] = {
        customDuration = seconds,
        color = existing and existing.color or nil,
        unit = existing and existing.unit or nil,
    }
    CONFIG.buffMappings[ctx.cooldownID] = m
    SetPairingCleared(ctx.cooldownID, false)
    ns.SaveCurrentProfile()
    if customBuffApplied then customBuffApplied() end
end

function ns.RemoveCustomBuff(cooldownID, slotIndex)
    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
    if not m or not m[slotIndex] then return end
    table.remove(m, slotIndex)
    if next(m) == nil then SetPairingCleared(cooldownID, true) end
    ns.SaveCurrentProfile()
    if customBuffApplied then customBuffApplied() end
end

-- Right click on an empty buff slot. Same context menu shape the icon strip uses
-- for its own per row choices, rather than a third pattern.
function ns.OpenCustomBuffMenu(anchor, cooldownID, slotIndex, onApplied)
    customBuffApplied = onApplied
    local function setTimer(prefill)
        PromptSeconds({ cooldownID = cooldownID, slotIndex = slotIndex }, prefill)
    end

    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
    local existing = m and m[slotIndex]
    local isCustom = existing and existing.customDuration ~= nil

    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchor, function(_, root)
            root:CreateTitle("Buff " .. slotIndex)
            if isCustom then
                root:CreateButton("Change length...", function()
                    setTimer(existing.customDuration)
                end)
                root:CreateButton("Remove", function()
                    ns.RemoveCustomBuff(cooldownID, slotIndex)
                end)
            else
                root:CreateButton("Custom timer...", function() setTimer() end)
            end
        end)
    else
        setTimer(existing and existing.customDuration)
    end
end

function ns.AutoPopulateSelfBuffMappings()
    if InCombatLockdown() then return end
    -- Opt-in. A nil is a profile written before the toggle existed, and those
    -- must stay unpaired too, so this is never `~= false`.
    if not CONFIG.autoPairBuffs then return end
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return end
    if not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end

    -- Essential AND Utility. The icon strip takes both, and a Utility spell whose
    -- buff is itself, like a movement cooldown, has no other route to a mapping.
    local cooldownIDs = {}
    local seenID = {}
    for _, cat in ipairs({ 0, 1 }) do
        for _, id in ipairs(CategoryEntryIDs(cat)) do
            if not seenID[id] then
                seenID[id] = true
                cooldownIDs[#cooldownIDs + 1] = id
            end
        end
    end

    CONFIG.buffMappings = CONFIG.buffMappings or {}
    local buffCdBySpell = BuffEntryBySpell(BUFF_SEARCH_CATEGORIES)
    local created = false

    for _, cooldownID in ipairs(cooldownIDs) do
        local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
        local info = infoOk and cdInfo or nil
        local existing = CONFIG.buffMappings[cooldownID]

        -- Clearing the last slot leaves an empty table, not nil. Treating that as
        -- mapped is how a row you cleared by hand became permanently unpairable.
        if type(existing) == "table" and next(existing) == nil then existing = nil end

        if existing == nil and not PairingCleared(cooldownID) then
            -- The row's own entry goes last, never first: it is the fallback for
            -- a spell with no separate buff entry, and a self mapping resolves to
            -- a frame with no Bar, so it can never drive a wedge.
            local buffCdIDs = BuffEntriesFor(buffCdBySpell, cooldownID)
            if info and info.hasAura then
                buffCdIDs = buffCdIDs or {}
                local seen = false
                for _, id in ipairs(buffCdIDs) do
                    if id == cooldownID then seen = true break end
                end
                if not seen then buffCdIDs[#buffCdIDs + 1] = cooldownID end
            end
            if buffCdIDs and #buffCdIDs > 0 then
                CONFIG.buffMappings[cooldownID] = {
                    { buffCooldownIDs = buffCdIDs,
                      unit = MappingUnitFor(buffCdIDs[1], info and info.spellID) },
                }
                created = true
            end
        elseif type(existing) == "table" then
            -- Patch existing self-mappings missing unit field
            for _, mapData in ipairs(existing) do
                if mapData.unit == nil and mapData.buffCooldownIDs then
                    for _, bcdID in ipairs(mapData.buffCooldownIDs) do
                        if bcdID == cooldownID then
                            local u = MappingUnitFor(bcdID, info and info.spellID)
                            if u then
                                mapData.unit = u
                                created = true
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    if created then
        ns.SaveCurrentProfile()
    end
end

-- A self mapping cannot drive a wedge. Swap it for the Tracked Bars entry when
-- one exists, keeping the colour and unit already on the mapping.
function ns.RepairSelfBuffPairings(announce)
    if InCombatLockdown() then return 0 end
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return 0 end
    if not CONFIG.buffMappings then return 0 end

    local barBySpell, trusted = BuffEntryBySpell({ 3 })
    local fixed = 0

    for cooldownID, maps in pairs(CONFIG.buffMappings) do
        if type(cooldownID) == "number" and type(maps) == "table" then
            local barIDs = BuffEntriesFor(barBySpell, cooldownID)
            local barID = barIDs and barIDs[1] or nil
            if barID and barID ~= cooldownID then
                for _, mapData in ipairs(maps) do
                    local list = mapData.buffCooldownIDs
                    if type(list) == "table" and #list == 1 and list[1] == cooldownID then
                        -- The whole list. Writing one id can pin the mapping to
                        -- an unlearned entry the game never feeds.
                        for i = 1, #barIDs do list[i] = barIDs[i] end
                        fixed = fixed + 1
                    end
                end
            end
        end
    end

    if fixed > 0 then
        ns.SaveCurrentProfile()
        if ns.ApplyLayoutToAllBars then ns.ApplyLayoutToAllBars() end
        if ns.RefreshIcons then ns.RefreshIcons() end
    end
    if announce then
        print("|cff00ff00[Infall]|r Buff pairings repaired: " .. fixed)
    end
    return fixed, trusted
end

-- Once per spec profile. A self mapping is not evidence of a choice, it is what
-- every earlier build wrote for any ability with an aura.
function ns.RepairSelfBuffPairingsOnce()
    -- Automatic only while the player has asked for automatic pairing. Repointing
    -- a pairing someone made by hand is the same unrequested write as creating
    -- one. `/infall repair` still runs it on demand.
    if not CONFIG.autoPairBuffs then return end
    local key = ns.GetSpecKey and ns.GetSpecKey()
    if not key then return end
    InfallDB.pairingRepair = InfallDB.pairingRepair or {}
    if InfallDB.pairingRepair[key] then return end

    -- Never burn the stamp on a layout that could not be read, or the one run
    -- this profile gets is the run that had no data.
    local fixed, trusted = ns.RepairSelfBuffPairings(false)
    if not trusted then return end
    InfallDB.pairingRepair[key] = true
    if fixed > 0 then
        print("|cff00ff00[Infall]|r Repaired " .. fixed .. " buff pairings that could not draw a wedge.")
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

-- Everything the icon strip owns. Buff pairings are deliberately absent: they are
-- shared with the timeline, so carrying them would rewrite the target spec's bars.
local ICON_COPY_KEYS = { "iconList", "iconStates", "iconContainers", "customIcons" }
local ICON_COPY_TOGGLES = { "iconsEnabled", "iconGlow", "iconIgnoreGCD", "hideIcons" }

-- Spec profiles are keyed `Name-Realm-specID`, and InfallDB is account wide, so
-- every character's profiles are visible here.
--
-- Another CLASS is still not offered: the rows are cooldownIDs and a mage's mean
-- nothing to a hunter. Another character of the SAME class is, because the same
-- spec on an alt has the identical cooldownIDs. The class comes from the spec id
-- itself, sixth return of GetSpecializationInfoByID, so a profile belonging to a
-- character who is not logged in is still classified correctly.
function ns.IconCopySources()
    local out = {}
    local mine = ns.GetSpecKey and ns.GetSpecKey()
    if not mine or not InfallDB.profiles then return out end
    local prefix = mine:match("^(.*)%-%d+$")
    if not prefix then return out end
    local _, myClass = UnitClass("player")

    for key, profile in pairs(InfallDB.profiles) do
        if key ~= mine and type(profile) == "table" then
            local specID = tonumber(key:match("%-(%d+)$"))
            local rows = profile.iconList and #profile.iconList or 0
            if specID and specID > 0 and rows > 0 then
                local ok, specName, specClass = pcall(function()
                    local _, n, _, _, _, c = GetSpecializationInfoByID(specID)
                    return n, c
                end)
                local sameChar = key:find(prefix, 1, true) == 1
                local sameClass = specClass and myClass and specClass == myClass
                if ok and (sameChar or sameClass) then
                    local label
                    if sameChar then
                        label = string.format("%s (%d icons)",
                            specName or ("spec " .. specID), rows)
                    else
                        label = string.format("%s, %s (%d icons)",
                            key:match("^([^%-]+)") or "?",
                            specName or ("spec " .. specID), rows)
                    end
                    out[#out + 1] = { key = key, rows = rows, label = label }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- Replaces the current spec's icons outright. Callers confirm first.
function ns.CopyIconsFromProfile(srcKey)
    if InCombatLockdown() then return false, "combat" end
    local src = InfallDB.profiles and InfallDB.profiles[srcKey]
    if type(src) ~= "table" then return false, "missing" end

    for _, key in ipairs(ICON_COPY_KEYS) do
        CONFIG[key] = src[key] and DeepCopy(src[key]) or {}
    end
    if src.toggles then
        for _, key in ipairs(ICON_COPY_TOGGLES) do
            if src.toggles[key] ~= nil then CONFIG[key] = src.toggles[key] end
        end
    end

    -- Pairings for the rows that just arrived, and only those. The table is shared
    -- with the timeline, so copying it whole would rewrite this spec's bars. An
    -- existing pairing is never overwritten, and an emptied one is a cleared
    -- pairing, not an absent one, so it is left cleared.
    local paired = 0
    if type(src.pairings) == "table" then
        CONFIG.buffMappings = CONFIG.buffMappings or {}
        for _, entry in ipairs(CONFIG.iconList or {}) do
            local id = entry.cooldownID or entry.key
            local incoming = id and src.pairings[id]
            if type(incoming) == "table" and next(incoming) ~= nil
                and CONFIG.buffMappings[id] == nil then
                CONFIG.buffMappings[id] = DeepCopy(incoming)
                paired = paired + 1
            end
        end
    end

    -- Custom row keys index the shared keyspace, so an incoming row can land on a
    -- key a bar row already holds.
    if ns.MigrateCustomKeyCollisions then ns.MigrateCustomKeyCollisions() end

    ns.SaveCurrentProfile()
    if ns.ApplyLayoutToAllBars then ns.ApplyLayoutToAllBars() end
    if ns.Icons and ns.Icons.Relayout then ns.Icons.Relayout() end
    if ns.RefreshIcons then ns.RefreshIcons() end
    return true, #(CONFIG.iconList or {}), paired
end

-- No pet handling: the Cooldown Manager scans player and target only, so an aura
-- EH can see is never on the pet.
local function PairingDefaultColor(buffCdID, isDebuff)
    if isDebuff then return DeepCopy(CONFIG.debuffColor), "target" end
    return DeepCopy(CONFIG.buffColor), nil
end

-- Icon for a CDM entry. Item entries carry no spellID, so GetSpellTexture returns
-- nil for them and ns.ResolveCooldownDisplay must be used instead.
local function CooldownIcon(cooldownID, cdInfo)
    local sid = cdInfo and (cdInfo.overrideTooltipSpellID or cdInfo.overrideSpellID or cdInfo.spellID)
    if sid then
        local tex = C_Spell.GetSpellTexture(sid)
        if tex then return tex end
    end
    local _, rIcon = ns.ResolveCooldownDisplay(cooldownID, cdInfo)
    return rIcon or 134400
end

function ns.SeedProfileFromClassConfig(specKey)
    local profile = {
        toggles = {},
        display = {},
        colors = {},
        pairings = {},
        pairingCleared = {},
        extraCasts = {},
        stackMappings = {},
        hiddenCooldownIDs = {},
        chargesDisabled = {},
        castColors = {},
        cooldownColors = {},
        stackIndicatorSettings = {},
        stackIndicatorList = {},
        customIcons = {},
        iconContainers = {},
        iconList = {},
        iconStates = {},
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
    if CONFIG.customIcons then
        profile.customIcons = DeepCopy(CONFIG.customIcons)
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
    CONFIG.pairingCleared = profile.pairingCleared and DeepCopy(profile.pairingCleared) or {}

    -- Merge class config defaults for cooldownIDs the profile doesn't cover. A row
    -- the player cleared is covered, even though it holds nothing.
    if ns.classConfigDefaults and ns.classConfigDefaults.pairings then
        for cdID, defaultMappings in pairs(ns.classConfigDefaults.pairings) do
            if not CONFIG.buffMappings[cdID] and not PairingCleared(cdID) then
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
    CONFIG.iconContainers = profile.iconContainers and DeepCopy(profile.iconContainers) or {}
    CONFIG.iconList = profile.iconList and DeepCopy(profile.iconList) or {}
    CONFIG.iconStates = profile.iconStates and DeepCopy(profile.iconStates) or {}

    -- Both custom lists are in place now, so collisions carried in from a
    -- profile written before the keyspace was shared can be separated.
    if ns.MigrateCustomKeyCollisions then
        local n = ns.MigrateCustomKeyCollisions()
        if n > 0 then
            print("|cff00ff00[Infall]|r Separated " .. n
                .. " custom icon(s) that shared a key with a custom timeline row.")
        end
    end

    -- Scale BEFORE position: a SetPoint offset is in the frame's own units, so
    -- scaling afterwards multiplies the saved offset and slides the frame.
    if EH_Parent then
        EH_Parent:SetScale(CONFIG.scale or 1.0)
    end

    -- Restore per-profile frame position
    if profile.position and EH_Parent then
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint(profile.position.point, UIParent, profile.position.relPoint, profile.position.x, profile.position.y)
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
    if ns.RefreshIcons then
        ns.RefreshIcons()
    end
    if ns.RefreshStacksTab then
        ns.RefreshStacksTab()
    end
    if ns.RefreshResourceTab then
        ns.RefreshResourceTab()
    end
    if ns.RefreshIconsTab then
        ns.RefreshIconsTab()
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
    profile.pairingCleared = DeepCopy(CONFIG.pairingCleared or {})
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
    profile.iconContainers = DeepCopy(CONFIG.iconContainers or {})
    profile.iconList = DeepCopy(CONFIG.iconList or {})
    profile.iconStates = DeepCopy(CONFIG.iconStates or {})

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
    iconContainers = DeepCopy(CONFIG.iconContainers or {}),
    iconList = DeepCopy(CONFIG.iconList or {}),
    iconStates = DeepCopy(CONFIG.iconStates or {}),
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

-- SETTINGS FRAME

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

    -- Shipped with the addon, so they are offered whether or not LibSharedMedia is
    -- present. The dedupe below stops a second copy appearing when it is.
    for _, f in ipairs(ns.BUNDLED_FONTS or {}) do
        fonts[#fonts + 1] = {text = f.name, value = f.path}
    end

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

-- WIDGET FACTORY

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

-- `description` prints under the box; `tooltip` waits for hover. Long text in
-- a description runs out of its panel.
local function CreateCheckbox(parent, label, description, default, onChange, tooltip)
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

    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tooltip, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

local openMenus = {}

-- A menu whose page is hidden keeps its shown flag and returns with the page.
function ns.CloseAllMenus()
    for _, close in ipairs(openMenus) do close() end
    if ns.CloseSpellPicker then ns.CloseSpellPicker() end
    if Menu and Menu.GetManager then
        local mgr = Menu.GetManager()
        if mgr and mgr.CloseMenus then pcall(mgr.CloseMenus, mgr) end
    end
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

    function container:Close()
        menuFrame:Hide()
    end
    openMenus[#openMenus + 1] = function() menuFrame:Hide() end

    return container
end

-- One control, three tabs. Everything on an edge in draw order, nearest the
-- frame first. `itemFn` returns the descriptor to move, or nil if not on it.
function ns.CreateEdgeOrderControl(parent, positionFn, itemFn, onChange)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(360, 96)

    local title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("Order On This Edge")

    local list = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    list:SetPoint("TOPLEFT", 0, -18)
    list:SetWidth(240)
    list:SetJustifyH("LEFT")
    list:SetSpacing(2)

    local closer = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    closer:SetSize(110, 22)
    closer:SetPoint("TOPRIGHT", 0, -16)
    closer:SetText("Toward frame")

    local further = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    further:SetSize(110, 22)
    further:SetPoint("TOPRIGHT", closer, "BOTTOMRIGHT", 0, -4)
    further:SetText("Away")

    local function Refresh()
        local pos = positionFn()
        local me = itemFn()
        local items = (ns.EdgeOrder and ns.EdgeOrder.Items(pos)) or {}
        local lines = {}
        for i, it in ipairs(items) do
            local mine = me and it.kind == me.kind
                and (me.kind ~= "pip" or it.listIndex == me.listIndex)
                and (me.kind ~= "strip" or it.key == me.key)
            lines[#lines + 1] = (mine and "|cffffd100" or "|cff9d9d9d")
                .. i .. ". " .. it.label .. "|r"
        end
        if #lines == 0 then
            list:SetText("|cff9d9d9dNothing on this edge yet.|r")
        else
            list:SetText(table.concat(lines, "\n"))
        end
        c:SetHeight(math.max(96, 22 + math.max(list:GetStringHeight() or 0, 48) + 12))

        local canIn = me and ns.EdgeOrder and ns.EdgeOrder.CanMove(pos, me, -1)
        local canOut = me and ns.EdgeOrder and ns.EdgeOrder.CanMove(pos, me, 1)
        closer:SetEnabled(canIn and true or false)
        further:SetEnabled(canOut and true or false)
    end
    c.Refresh = Refresh

    local function Move(delta)
        local me = itemFn()
        if not me then return end
        if ns.EdgeOrder then ns.EdgeOrder.Move(positionFn(), me, delta) end
        Refresh()
        if onChange then onChange() end
    end
    closer:SetScript("OnClick", function() Move(-1) end)
    further:SetScript("OnClick", function() Move(1) end)

    -- The model lives in Bars.lua, which loads after both tabs that build this.
    -- Repainting on show also covers a change made from one of the other tabs.
    c:SetScript("OnShow", Refresh)
    Refresh()
    return c
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

-- The one remove control, for every list row in every tab. NoScripts is the base
-- deliberately: plain UIPanelCloseButton carries an OnClick that hides its parent.
function ns.CreateRemoveButton(parent, tooltip, onClick, size, tooltipBody)
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButtonNoScripts")
    size = size or 22
    btn:SetSize(size, size)
    btn:SetScript("OnClick", onClick)
    if tooltip then
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip)
            if tooltipBody then
                GameTooltip:AddLine(tooltipBody, 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return btn
end

local function CreateSectionHeader(parent, text)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0, 1)
    return header
end

-- TAB SYSTEM

-- Index order is load bearing: tabFrames slots are assigned by number from three
-- files. Insert a name without moving those and two tabs share a slot.
local TAB_NAMES = {"Bars", "Display", "Colours", "Toggles", "Stacks", "Resource", "Icons", "Profiles"}
local tabFrames = {}
local tabButtons = {}
local currentTab = 1
-- The Cooldown Manager is not a managed UI panel: ShowUIPanel finds no area
-- attribute and falls through to a plain Show. It opens BEHIND the options
-- window, so raise it and let the player drag it clear.
function ns.OpenCooldownManager()
    if InCombatLockdown() then
        print("|cff00ff00[Infall]|r Cannot open the Cooldown Manager in combat.")
        return
    end
    local cdm = CooldownViewerSettings
    if not cdm then
        print("|cff00ff00[Infall]|r Cooldown Manager not available.")
        return
    end

    -- Not a managed panel, so it lands under the options window with no way to
    -- move it. Nothing here is protected.
    if not cdm.infallDraggable then
        cdm.infallDraggable = true
        pcall(function()
            cdm:SetMovable(true)
            cdm:EnableMouse(true)
            cdm:RegisterForDrag("LeftButton")
            cdm:SetScript("OnDragStart", cdm.StartMoving)
            cdm:SetScript("OnDragStop", cdm.StopMovingOrSizing)
        end)
    end

    -- Raised, never moved: it keeps Blizzard's own top left anchor, and it is
    -- draggable now if it lands somewhere awkward.
    local collides = SettingsPanel and SettingsPanel:IsShown()
    if collides then
        pcall(cdm.SetFrameStrata, cdm, "FULLSCREEN_DIALOG")
        pcall(cdm.SetToplevel, cdm, true)
    end

    C_Timer.After(0, function()
        -- Plain Show. Not a managed panel, so ShowUIPanel resolves to this
        -- anyway, minus its protected gamepad call, which throws first.
        if not cdm:IsShown() then pcall(cdm.Show, cdm) end
        -- Blizzard's own slash command route, if a plain Show is not enough.
        if not cdm:IsShown() and cdm.TogglePanel then
            pcall(cdm.TogglePanel, cdm)
        end
        if not cdm:IsShown() then pcall(ShowUIPanel, cdm) end
        if collides then pcall(cdm.Raise, cdm) end
        if not cdm:IsShown() then
            print("|cff00ff00[Infall]|r The Cooldown Manager would not open. Try Esc, Options, Edit Mode, Cooldown Manager and tell me if that works.")
        end
    end)
end

-- A category move fires no game event; the layout manager's notification is the
-- only signal. Both guards are load bearing: this also fires at login setup.
do
    local owner = {}
    local pending = false

    local function ProviderHasEntries()
        if not CooldownViewerSettings or not CooldownViewerSettings.GetDataProvider then
            return false
        end
        local dp = CooldownViewerSettings:GetDataProvider()
        if not dp then return false end
        local ids = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(0)
        return ids and #ids > 0 or false
    end

    local function Apply()
        pending = false
        if InCombatLockdown() then return end
        if not ProviderHasEntries() then return end
        if ns.LoadEssentialCooldowns then ns.LoadEssentialCooldowns() end
        if ns.RefreshCooldownRows then ns.RefreshCooldownRows() end
        if ns.RefreshBuffPool then ns.RefreshBuffPool() end
        if ns.RefreshIconsTab then ns.RefreshIconsTab() end
        if ns.RefreshIcons then ns.RefreshIcons() end
    end

    local function OnDataChanged()
        if not (CooldownViewerSettings and CooldownViewerSettings:IsShown()) then return end
        -- Dragging an entry fires this repeatedly; one rebuild covers the burst.
        if pending then return end
        pending = true
        C_Timer.After(0.1, Apply)
    end

    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", OnDataChanged, owner)
    end
end

local function SelectTab(index)
    currentTab = index
    GameTooltip:Hide()
    if ns.CloseAllMenus then ns.CloseAllMenus() end
    -- Indexed, not ipairs: a tab assigned from another file leaves a nil hole if that
    -- file fails to load, and ipairs stops at the hole.
    for i = 1, #TAB_NAMES do
        local frame = tabFrames[i]
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

-- SCROLL FRAME HELPER

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

-- INLINE COLOUR PICKER (for per-slot buff colours)

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

-- SHARED SPELL PICKER. Searchable popup of the player's learned spells, passives
-- included. Used by the Stacks tab and the custom icon override in the Bars tab.

local spellPickerFrame
local spellPickerCache
local spellPickerCacheDirty = true
local spellPickerCurrentOpts

-- Separate list for `source = "talents"`. The spellbook list is everything the
-- player knows, which is the wrong set for a condition: it omits the talents
-- they are not currently running, and those are exactly the ones worth gating on.
local talentPickerCache
local talentPickerCacheDirty = true

-- Common consumables / class buffs not always in the player's spellbook.
-- Used so name search in the picker can find things like Healthstone or Phial of Tepid Versatility.
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

-- Every talent in the active spec's trees, taken or not. Entries, never nodes:
-- a choice node offers several and only one of them is the talent you mean.
local function BuildTalentPickerCache()
    local list = {}
    local seen = {}

    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
        and C_ClassTalents.GetActiveConfigID()
    local cfgOk, cfg = false, nil
    if configID and C_Traits and C_Traits.GetConfigInfo then
        cfgOk, cfg = pcall(C_Traits.GetConfigInfo, configID)
    end

    if cfgOk and cfg and cfg.treeIDs then
        for _, treeID in ipairs(cfg.treeIDs) do
            local nOk, nodes = pcall(C_Traits.GetTreeNodes, treeID)
            if nOk and nodes then
                for _, nodeID in ipairs(nodes) do
                    local iOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                    if iOk and node and node.entryIDs then
                        for _, entryID in ipairs(node.entryIDs) do
                            local eOk, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
                            local defID = eOk and entry and entry.definitionID
                            local dOk, def = false, nil
                            if defID then dOk, def = pcall(C_Traits.GetDefinitionInfo, defID) end
                            local spellID = dOk and def and (def.spellID or def.overriddenSpellID)
                            if spellID and not seen[spellID] then
                                local name = C_Spell.GetSpellName(spellID)
                                if name and name ~= "" then
                                    seen[spellID] = true
                                    list[#list + 1] = {
                                        spellID = spellID,
                                        name = name,
                                        nameLower = name:lower(),
                                        icon = C_Spell.GetSpellTexture(spellID) or 134400,
                                        tab = "Talent",
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    talentPickerCache = list
    talentPickerCacheDirty = false
end

local spellPickerInvalidator
local function EnsureSpellPickerInvalidator()
    if spellPickerInvalidator then return end
    spellPickerInvalidator = CreateFrame("Frame")
    spellPickerInvalidator:RegisterEvent("SPELLS_CHANGED")
    spellPickerInvalidator:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
    spellPickerInvalidator:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    spellPickerInvalidator:RegisterEvent("TRAIT_CONFIG_UPDATED")
    spellPickerInvalidator:RegisterEvent("PLAYER_TALENT_UPDATE")
    spellPickerInvalidator:SetScript("OnEvent", function()
        spellPickerCacheDirty = true
        talentPickerCacheDirty = true
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

        local useTalents = spellPickerCurrentOpts
            and spellPickerCurrentOpts.source == "talents"
        if useTalents then
            if talentPickerCacheDirty or not talentPickerCache then
                BuildTalentPickerCache()
            end
        elseif spellPickerCacheDirty or not spellPickerCache then
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

        for _, e in ipairs((useTalents and talentPickerCache) or spellPickerCache) do
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

    -- The anchor button is excluded so its own click does not immediately
    -- reclose the frame it just opened.
    f:SetScript("OnShow", function(self)
        self:SetScript("OnUpdate", function(self2)
            if IsMouseButtonDown("LeftButton") and not self2:IsMouseOver() then
                local a = spellPickerCurrentOpts and spellPickerCurrentOpts.anchor
                if not (a and a.IsMouseOver and a:IsMouseOver()) then
                    self2:Hide()
                end
            end
        end)
    end)

    f:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
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

function ns.CloseSpellPicker()
    if spellPickerFrame then spellPickerFrame:Hide() end
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

-- TAB BUILDERS

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

    -- Potion aura bars use a fixed window, not a mirrored CDM bar.
    AddColourDescription("Potion colours are temporarily controlled here, until Blizzard fixes their 12.1 potion bars.")

    local potionColourSwatch = CreateColorSwatch(colourContent, "Potion Buff", DeepCopy(CONFIG.potionBuffColor), function(c)
        CONFIG.potionBuffColor = c
        DebouncedApplyAndSave()
    end)
    AddColourWidget(potionColourSwatch)

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
    AddColourDescription("Colour for the clip window at the tail of a channel, marking the final tick where it is safe to clip. Drawn on Disintegrate and Rapid Fire.")

    -- Label only. The saved key stays disintegrateChainColor so no profile moves.
    local disintChainSwatch = CreateColorSwatch(colourContent, "Channel Clip Window", DeepCopy(CONFIG.disintegrateChainColor), function(c)
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
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeAnchorDropdown)

    local chargeOffXSlider = CreateSlider(colourContent, "Charge Offset X", -20, 20, 1, CONFIG.chargeTextOffsetX, function(v)
        CONFIG.chargeTextOffsetX = v
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeOffXSlider)

    local chargeOffYSlider = CreateSlider(colourContent, "Charge Offset Y", -20, 20, 1, CONFIG.chargeTextOffsetY, function(v)
        CONFIG.chargeTextOffsetY = v
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddColourWidget(chargeOffYSlider)


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
        if CONFIG.potionBuffColor then potionColourSwatch:SetColor(DeepCopy(CONFIG.potionBuffColor)) end
        if CONFIG.debuffColor then debuffColourSwatch:SetColor(DeepCopy(CONFIG.debuffColor)) end
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

-- TAB F: STACKS

-- Shared: the edge order list in Bars.lua names power pips from this.
ns.POWER_TYPE_INFO = {
    [4]  = {name = "Combo Points",   max = 5, color = {1.0, 0.96, 0.41, 1}},
    [5]  = {name = "Runes",          max = 6, color = {0.77, 0.12, 0.23, 1}},
    [7]  = {name = "Soul Shards",    max = 5, color = {0.58, 0.51, 0.79, 1}},
    [9]  = {name = "Holy Power",     max = 5, color = {0.96, 0.84, 0.09, 1}},
    [12] = {name = "Chi",            max = 5, color = {0.71, 1.0, 0.92, 1}},
    [16] = {name = "Arcane Charges", max = 4, color = {0.1, 0.5, 0.8, 1}},
    [19] = {name = "Essence",        max = 5, color = {0.0, 0.8, 0.4, 1}},
}
local POWER_TYPE_INFO = ns.POWER_TYPE_INFO

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

    -- The count on the bar, not the pips. Only its colour stays in Colours.
    AddStacksHeader("Stack Count Text")
    AddStacksDescription("Where the stack number sits on each bar. Nothing to do with the pip indicators below; this shows whether or not those are enabled. With icons hidden it is positioned across the bar itself.")

    local stackAnchorDropdown = CreateDropdown(stacksContent, "Anchor Point", ANCHOR_POINTS, CONFIG.stackTextAnchor, function(v)
        CONFIG.stackTextAnchor = v
        CONFIG.stackTextRelPoint = v
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(stackAnchorDropdown)

    local stackOffXSlider = CreateSlider(stacksContent, "Stack Offset X", -20, 20, 1, CONFIG.stackTextOffsetX, function(v)
        CONFIG.stackTextOffsetX = v
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(stackOffXSlider)

    local stackOffYSlider = CreateSlider(stacksContent, "Stack Offset Y", -20, 20, 1, CONFIG.stackTextOffsetY, function(v)
        CONFIG.stackTextOffsetY = v
        if ns.RefreshTextAnchors then ns.RefreshTextAnchors() end
        ns.SaveCurrentProfile()
    end)
    AddStacksWidget(stackOffYSlider)

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

            local delBtn = ns.CreateRemoveButton(rf, "Remove", function()
                table.remove(CONFIG.stackIndicatorList, idx)
                if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
                if RefreshStacksGrid then RefreshStacksGrid() end
                if RefreshPowerTypeGrid then RefreshPowerTypeGrid() end
            end)
            delBtn:SetPoint("TOPRIGHT", rf, "TOPRIGHT", -6, -10)

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

            -- Shared edge model. Toward and away read the same on both edges; list order
            -- does not, because the top edge lays out in reverse.
            local me = { kind = "pip", listIndex = idx }
            local function EdgeMove(delta)
                if not (ns.EdgeOrder and ns.EdgeOrder.Move(resolvedPos, me, delta)) then return end
                ns.SaveCurrentProfile()
                RebuildSIListUI()
            end
            local function EdgeCan(delta)
                return ns.EdgeOrder and ns.EdgeOrder.CanMove(resolvedPos, me, delta)
            end

            local downBtn = CreateFrame("Button", nil, rf)
            downBtn:SetSize(18, 16)
            downBtn:SetPoint("RIGHT", posBtn, "LEFT", -6, 0)
            downBtn:SetNormalAtlas("UI-ScrollBar-ScrollDownButton-Up")
            downBtn:SetPushedAtlas("UI-ScrollBar-ScrollDownButton-Down")
            downBtn:SetHighlightAtlas("UI-ScrollBar-ScrollDownButton-Highlight")
            downBtn:SetDisabledAtlas("UI-ScrollBar-ScrollDownButton-Disabled")
            if not EdgeCan(1) then downBtn:Disable() end
            downBtn:SetScript("OnClick", function() EdgeMove(1) end)
            downBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Move Away From The Bars")
                GameTooltip:AddLine("Steps past whatever is next on this edge, including the resource bar and the icon strip.", 0.7, 0.7, 0.7, true)
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
            if not EdgeCan(-1) then upBtn:Disable() end
            upBtn:SetScript("OnClick", function() EdgeMove(-1) end)
            upBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Move Toward The Bars")
                GameTooltip:AddLine("Steps past whatever is next on this edge, including the resource bar and the icon strip.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            upBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Optional talent gate. Sits on this row because the card height is a
            -- fixed 100 with a hardcoded advance below; a fourth row would move
            -- geometry that nothing here measures.
            local talentBtn = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
            talentBtn:SetSize(118, 20)
            talentBtn:SetPoint("RIGHT", upBtn, "LEFT", -8, 0)

            -- Long talent names are common, so the label is pinned to both edges
            -- and left unwrapped, which truncates rather than spilling past the
            -- button. The full name lives in the tooltip.
            local talentFS = talentBtn:GetFontString()
            talentFS:SetWordWrap(false)
            talentFS:ClearAllPoints()
            talentFS:SetPoint("LEFT", talentBtn, "LEFT", 6, 0)
            talentFS:SetPoint("RIGHT", talentBtn, "RIGHT", -6, 0)
            talentFS:SetJustifyH("CENTER")

            local gateID = entry.requireTalent
            local gateName = gateID and C_Spell.GetSpellName(gateID)
            local gateKnown = gateID and ns.IsTalentKnown and ns.IsTalentKnown(gateID)
            if gateID then
                talentBtn:SetText(gateName or ("ID " .. gateID))
                -- Three states worth telling apart: no condition, condition met,
                -- condition failing. The last one is why a row is not drawing, so
                -- it gets its own colour rather than sharing grey with "unset".
                if gateKnown then
                    talentFS:SetTextColor(1, 0.82, 0)
                else
                    talentFS:SetTextColor(0.8, 0.45, 0.45)
                end
            else
                talentBtn:SetText("Always shown")
                talentFS:SetTextColor(0.5, 0.5, 0.5)
            end

            talentBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            talentBtn:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    entry.requireTalent = nil
                    ns.SaveCurrentProfile()
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    RebuildSIListUI()
                    return
                end
                if not ns.OpenSpellPicker then return end
                ns.OpenSpellPicker({
                    title = "Show Only If Talent Known",
                    anchor = self,
                    source = "talents",
                    onSelect = function(pickedID)
                        entry.requireTalent = pickedID
                        ns.SaveCurrentProfile()
                        if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                        RebuildSIListUI()
                    end,
                })
            end)
            talentBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if gateID then
                    GameTooltip:SetText(gateName or ("Spell " .. gateID))
                    GameTooltip:AddLine(gateKnown
                        and "Talented, so this row is drawing."
                        or "Not talented, so this row is hidden.", 0.7, 0.7, 0.7, true)
                    GameTooltip:AddLine("Click to change it, right click to clear.", 0.7, 0.7, 0.7, true)
                else
                    GameTooltip:SetText("Always shown")
                    GameTooltip:AddLine("This row draws on every build. Click to tie it to a talent instead, and it will only draw while that talent is taken.", 0.7, 0.7, 0.7, true)
                end
                GameTooltip:Show()
            end)
            talentBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

                local clearZonesBtn = ns.CreateRemoveButton(rf, "Remove Zones", function()
                    entry.color = DeepCopy(entry.colorZones[1] and entry.colorZones[1].color or entry.color or {0.8, 0.2, 0.1, 1})
                    entry.colorZones = nil
                    if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                    ns.SaveCurrentProfile()
                    RebuildSIListUI()
                end, 18, "Revert to a single pip colour.")
                clearZonesBtn:SetPoint("LEFT", zonesLabel, "RIGHT", 4, 0)

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
                        local zDel = ns.CreateRemoveButton(rf, "Remove Zone", function()
                            table.remove(entry.colorZones, zoneIdx)
                            if ns.RebuildStackIndicators then ns.RebuildStackIndicators() end
                            ns.SaveCurrentProfile()
                            RebuildSIListUI()
                        end, 18)
                        zDel:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", zoneXOff, 11)
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

        -- Through CategoryEntryIDs, so an entry dragged into a buff section from
        -- somewhere else is offered. The raw accessor reports static defaults and
        -- could only ever list an entry under the section Blizzard shipped it in.
        for _, cat in ipairs({ 2, 3 }) do
            for _, id in ipairs(CategoryEntryIDs(cat)) do
                if not seen[id] then
                    seen[id] = true
                    buffIDs[#buffIDs + 1] = id
                end
            end
        end

        -- Essential is included only for entries that carry an aura of their own.
        for _, id in ipairs(CategoryEntryIDs(0)) do
            if not seen[id] then
                local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                if infoOk and cdInfo and cdInfo.hasAura then
                    seen[id] = true
                    buffIDs[#buffIDs + 1] = id
                end
            end
        end

        -- Every CDM buff aura. The tooltip word "stack" is an unreliable filter, some
        -- stacking auras never say it. A non-stacking pick just shows 0 or 1 pip.
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
        stackAnchorDropdown:SetValue(CONFIG.stackTextAnchor)
        stackOffXSlider:SetValue(CONFIG.stackTextOffsetX)
        stackOffYSlider:SetValue(CONFIG.stackTextOffsetY)
        RebuildSIListUI()
        RefreshStacksGrid()
        RefreshPowerTypeGrid()
    end

    stacksTab:SetScript("OnShow", RefreshStacksTab)
    ns.RefreshStacksTab = RefreshStacksTab
end

-- BUILD THE SETTINGS PANEL (deferred)

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
    versionText:SetText("v1.3.9")

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

    -- TAB A: BARS
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
        GameTooltip:AddLine("Opens it in front of this window, and makes it draggable so you can put the two side by side.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cdmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cdmBtn:SetScript("OnClick", ns.OpenCooldownManager)

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

    -- Wires the Buff 1/2/3, Cast 1/2 and Stack slot widgets on a row. Reads and writes
    -- CONFIG.buffMappings, CONFIG.extraCasts and CONFIG.stackMappings by cooldownID.
    local function WireSlots(row, cooldownID)
        local buff1Slot, buff1ColorBtn = row.buff1Slot, row.buff1ColorBtn
        local buff2Slot, buff2ColorBtn = row.buff2Slot, row.buff2ColorBtn
        local buff3Slot, buff3ColorBtn = row.buff3Slot, row.buff3ColorBtn
        local cast1Slot, cast1ColorBtn = row.cast1Slot, row.cast1ColorBtn
        local cast2Slot, cast2ColorBtn = row.cast2Slot, row.cast2ColorBtn
        local stackSlot, stackColorBtn = row.stackSlot, row.stackColorBtn

        buff1Slot.icon:Hide(); buff1Slot.pairedCooldownID = nil; buff1Slot.customEntry = nil; buff1Slot.pairedColor = nil; buff1ColorBtn:Hide()
        buff2Slot.icon:Hide(); buff2Slot.pairedCooldownID = nil; buff2Slot.customEntry = nil; buff2Slot.pairedColor = nil; buff2ColorBtn:Hide()
        buff3Slot.icon:Hide(); buff3Slot.pairedCooldownID = nil; buff3Slot.customEntry = nil; buff3Slot.pairedColor = nil; buff3ColorBtn:Hide()
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
            -- A custom entry has no buffCooldownIDs to look art up from, so it
            -- carries its own. Without this branch the slot rendered empty and
            -- there was no colour control, which read as nothing having been set.
            if m and m.customDuration then
                slot.icon:SetTexture(136243)
                slot.icon:Show()
                slot.pairedCooldownID = nil
                slot.customEntry = m
                slot.pairedColor = m.color
                local cc = m.color or (m.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
                colorBtn.tex:SetColorTexture(cc[1], cc[2], cc[3], cc[4] or 1)
                colorBtn:Show()
                colorBtn.procDot:SetShown(false)
                return
            end
            if not (m and m.buffCooldownIDs and m.buffCooldownIDs[1]) then return end
            local bID = m.buffCooldownIDs[1]
            local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, bID)
            local sID = infoOk and info and (info.overrideTooltipSpellID or info.overrideSpellID or info.spellID)
            local icon = sID and C_Spell.GetSpellTexture(sID) or 134400
            slot.icon:SetTexture(icon)
            slot.icon:Show()
            slot.pairedCooldownID = bID
            slot.pairedColor = m.color
            local c = m.color or (m.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
            local sIcon = CooldownIcon(stackMapping.buffCooldownID, sInfoOk and sInfo or nil)
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
            local ce = self.customEntry
            if ce then
                GameTooltip:SetText(slotName .. ": custom timer", 1, 1, 1)
                GameTooltip:AddLine(ce.customDuration
                    .. "s, started by casting this ability", 0.7, 0.7, 0.7, true)
                GameTooltip:AddLine("Right click: change or remove", 0.5, 0.8, 0.5)
                GameTooltip:Show()
                return
            end
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
                    GameTooltip:AddLine("Or right click for a custom buff", 0.5, 0.8, 0.5)
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
                    self.pairedCooldownID = nil; self.customEntry = nil; self.pairedColor = nil
                    slot.icon:Hide(); colorBtn:Hide(); colorBtn.procDot:Hide()
                    local m = CONFIG.buffMappings and CONFIG.buffMappings[cooldownID]
                    if m then
                        if slotIndex == 1 then table.remove(m, 1)
                        elseif slotIndex == 2 and #m >= 2 then table.remove(m, 2)
                        elseif slotIndex == 3 and #m >= 3 then table.remove(m, 3) end
                        if next(m) == nil then SetPairingCleared(cooldownID, true) end
                    end
                    ns.SaveCurrentProfile(); LoadEssentialCooldowns(); RefreshCooldownRows()
                    return
                end
                if button == "RightButton" then
                    ns.OpenCustomBuffMenu(self, cooldownID, slotIndex, function()
                        LoadEssentialCooldowns(); RefreshCooldownRows()
                        statusText:SetText("|cff00ff00Custom buff set.|r")
                    end)
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
                local bIcon = CooldownIcon(buffCdID, bOk and bInfo or nil)
                slot.icon:SetTexture(bIcon); slot.icon:Show()
                self.pairedCooldownID = buffCdID
                local isDebuff = bSID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(bSID)
                local defaultColor, pairUnit = PairingDefaultColor(buffCdID, isDebuff)
                if slotIndex >= 2 then defaultColor[4] = 0.3 end
                self.pairedColor = defaultColor
                colorBtn.tex:SetColorTexture(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4] or 1)
                colorBtn:Show()
                CONFIG.buffMappings = CONFIG.buffMappings or {}
                CONFIG.buffMappings[cooldownID] = CONFIG.buffMappings[cooldownID] or {}
                local mapping = { buffCooldownIDs = {buffCdID}, color = defaultColor }
                if pairUnit then mapping.unit = pairUnit end
                CONFIG.buffMappings[cooldownID][slotIndex] = mapping
                SetPairingCleared(cooldownID, false)
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
                local defaultColor = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
                self.pairedCooldownID = nil; self.customEntry = nil; self.pairedColor = nil
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
            local sIcon = CooldownIcon(buffCdID, sOk and sInfo or nil)
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
    -- Reads the upvalue at call time, so placement here is safe.
    function ns.RefreshCooldownRows()
        if RefreshCooldownRows then RefreshCooldownRows() end
    end

    function ns.RefreshBuffPool()
        if RefreshBuffPool then RefreshBuffPool() end
    end

    RefreshCooldownRows = function()
        -- Frame recycling
        for i = 1, cooldownRowCacheCount do
            if cooldownRowCache[i] then cooldownRowCache[i]:Hide() end
        end
        wipe(allSlotFrames)

        local cooldownIDs = {}
        -- Use data provider if available, fall back to category set
        local foundSource = false
        do
            -- An empty table is an ANSWER, the category is genuinely empty. Only nil
            -- means the layout could not be read. Testing #displayed > 0 here treated
            -- empty as unknown, so emptying a category fell through to static
            -- defaults and the list repopulated with what the player just removed.
            local displayed = ns.OrderedCooldownIDs and ns.OrderedCooldownIDs(0)
            if displayed then
                cooldownIDs = displayed
                foundSource = true
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
                row.buff1Slot.customEntry = nil
                row.buff1Slot.pairedColor = nil
                row.buff1ColorBtn:Hide()
                row.buff2Slot.icon:Hide()
                row.buff2Slot.pairedCooldownID = nil
                row.buff2Slot.customEntry = nil
                row.buff2Slot.pairedColor = nil
                row.buff2ColorBtn:Hide()
                row.buff3Slot.icon:Hide()
                row.buff3Slot.pairedCooldownID = nil
                row.buff3Slot.customEntry = nil
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
                        if self.customEntry then
                            local ce = self.customEntry
                            GameTooltip:SetText("Buff 1: custom timer (" .. ce.customDuration .. "s)", 1, 1, 1)
                            GameTooltip:AddLine("Right click: change or remove", 0.5, 0.8, 0.5)
                            GameTooltip:Show()
                            return
                        end
                        GameTooltip:SetText("Buff 1 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Or right click for a custom buff", 0.5, 0.8, 0.5)
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
                        if self.customEntry then
                            local ce = self.customEntry
                            GameTooltip:SetText("Buff 2: custom timer (" .. ce.customDuration .. "s)", 1, 1, 1)
                            GameTooltip:AddLine("Right click: change or remove", 0.5, 0.8, 0.5)
                            GameTooltip:Show()
                            return
                        end
                        GameTooltip:SetText("Buff 2 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Or right click for a custom buff", 0.5, 0.8, 0.5)
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
                        if self.customEntry then
                            local ce = self.customEntry
                            GameTooltip:SetText("Buff 3: custom timer (" .. ce.customDuration .. "s)", 1, 1, 1)
                            GameTooltip:AddLine("Right click: change or remove", 0.5, 0.8, 0.5)
                            GameTooltip:Show()
                            return
                        end
                        GameTooltip:SetText("Buff 3 Slot (empty)", 0.6, 0.6, 0.6)
                        if selectedBuff then
                            GameTooltip:AddLine("Click to pair selected buff here", 0.5, 1, 0.5)
                        else
                            GameTooltip:AddLine("Select a buff from the Buffs pool first", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Or right click for a custom buff", 0.5, 0.8, 0.5)
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
                -- Custom entries carry their own art and have no buffCooldownIDs
                -- to resolve it from, so they are drawn before the paired paths.
                local function ApplyCustomSlot(slot, colorBtn, m)
                    if not (m and m.customDuration) then return false end
                    slot.icon:SetTexture(136243)
                    slot.icon:Show()
                    slot.pairedCooldownID = nil
                    slot.customEntry = m
                    slot.pairedColor = m.color
                    local cc = m.color or (m.unit == "target" and CONFIG.debuffColor)
                        or CONFIG.buffColor
                    colorBtn.tex:SetColorTexture(cc[1], cc[2], cc[3], cc[4] or 1)
                    colorBtn:Show()
                    colorBtn.procDot:SetShown(false)
                    return true
                end
                if mappings then
                    ApplyCustomSlot(buff1Slot, buff1ColorBtn, mappings[1])
                    ApplyCustomSlot(buff2Slot, buff2ColorBtn, mappings[2])
                    ApplyCustomSlot(buff3Slot, buff3ColorBtn, mappings[3])
                end
                if mappings then
                    -- First mapping -> Buff 1 slot
                    if mappings[1] and mappings[1].buffCooldownIDs and mappings[1].buffCooldownIDs[1] then
                        local buffCdID = mappings[1].buffCooldownIDs[1]
                        local bInfoOk, bInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buffCdID)
                        local bSpellID = bInfoOk and bInfo and (bInfo.overrideTooltipSpellID or bInfo.overrideSpellID or bInfo.spellID)
                        local bIcon = CooldownIcon(buffCdID, bInfoOk and bInfo or nil)
                        buff1Slot.icon:SetTexture(bIcon)
                        buff1Slot.icon:Show()
                        buff1Slot.pairedCooldownID = buffCdID
                        buff1Slot.pairedColor = mappings[1].color

                        local bc = mappings[1].color or (mappings[1].unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
                        buff1ColorBtn.tex:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1)
                        buff1ColorBtn:Show()
                        buff1ColorBtn.procDot:SetShown(mappings[1].requireGlow == true)
                    end
                    -- Second mapping -> Buff 2 slot
                    if mappings[2] and mappings[2].buffCooldownIDs and mappings[2].buffCooldownIDs[1] then
                        local buff2CdID = mappings[2].buffCooldownIDs[1]
                        local oInfoOk, oInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buff2CdID)
                        local oSpellID = oInfoOk and oInfo and (oInfo.overrideTooltipSpellID or oInfo.overrideSpellID or oInfo.spellID)
                        local oIcon = CooldownIcon(buff2CdID, oInfoOk and oInfo or nil)
                        buff2Slot.icon:SetTexture(oIcon)
                        buff2Slot.icon:Show()
                        buff2Slot.pairedCooldownID = buff2CdID
                        buff2Slot.pairedColor = mappings[2].color

                        local oc = mappings[2].color or (mappings[2].unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
                        buff2ColorBtn.tex:SetColorTexture(oc[1], oc[2], oc[3], oc[4] or 1)
                        buff2ColorBtn:Show()
                        buff2ColorBtn.procDot:SetShown(mappings[2].requireGlow == true)
                    end
                    -- Third mapping -> Buff 3 slot
                    if mappings[3] and mappings[3].buffCooldownIDs and mappings[3].buffCooldownIDs[1] then
                        local buff3CdID = mappings[3].buffCooldownIDs[1]
                        local tInfoOk, tInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, buff3CdID)
                        local tSpellID = tInfoOk and tInfo and (tInfo.overrideTooltipSpellID or tInfo.overrideSpellID or tInfo.spellID)
                        local tIcon = CooldownIcon(buff3CdID, tInfoOk and tInfo or nil)
                        buff3Slot.icon:SetTexture(tIcon)
                        buff3Slot.icon:Show()
                        buff3Slot.pairedCooldownID = buff3CdID
                        buff3Slot.pairedColor = mappings[3].color

                        local tc = mappings[3].color or (mappings[3].unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
                            self.customEntry = nil
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
                                if next(m) == nil then SetPairingCleared(cooldownID, true) end
                            end
                            ns.SaveCurrentProfile()
                            LoadEssentialCooldowns()
                            RefreshCooldownRows()
                            return
                        end
                        -- Right click: declare a custom timer for this slot.
                        if button == "RightButton" then
                            ns.OpenCustomBuffMenu(self, cooldownID, slotIndex, function()
                                LoadEssentialCooldowns()
                                RefreshCooldownRows()
                            end)
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
                            local bIcon = CooldownIcon(buffCdID, bInfoOk and bInfo or nil)
                            slot.icon:SetTexture(bIcon)
                            slot.icon:Show()
                            self.pairedCooldownID = buffCdID

                            local isDebuff = bSpellID and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(bSpellID)
                            local defaultColor, pairUnit = PairingDefaultColor(buffCdID, isDebuff)
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
                            if pairUnit then mapping.unit = pairUnit end
                            CONFIG.buffMappings[cooldownID][slotIndex] = mapping
                            SetPairingCleared(cooldownID, false)
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
                    local defaultColor = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
                    local defaultColor2 = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
                    local defaultColor3 = (mapData and mapData.unit == "target" and CONFIG.debuffColor) or CONFIG.buffColor
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
                    local sIcon = CooldownIcon(stackMapping.buffCooldownID, sInfoOk and sInfo or nil)
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
                    local sIcon = CooldownIcon(buffCdID, sInfoOk and sInfo or nil)
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

        -- Extras section (user added Custom Rows)
        for i = 1, customRowCacheCount do
            if customRowCache[i] then customRowCache[i]:Hide() end
        end
        if extrasHeaderFrame then extrasHeaderFrame:Hide() end

        if CONFIG.extras then
            yOffset = yOffset + 6

            if not extrasHeaderFrame then
                extrasHeaderFrame = CreateFrame("Frame", nil, topContent)
                extrasHeaderFrame:SetSize(topContent:GetWidth() or 700, 86)
                extrasHeaderFrame.text = extrasHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                extrasHeaderFrame.text:SetPoint("TOPLEFT", 6, 0)
                extrasHeaderFrame.text:SetText("Extras")
                extrasHeaderFrame.note = extrasHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                extrasHeaderFrame.note:SetPoint("TOPLEFT", extrasHeaderFrame.text, "BOTTOMLEFT", 0, -2)
                    extrasHeaderFrame.note:SetText("Racials now come from the Cooldown Manager. Add them there for exact timing.")
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
                            table.insert(CONFIG.extras, {
                                -- Unique across the strip's custom icons too:
                                -- both lists index the same shared tables.
                                key = ns.NextCustomKey(),
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

            for extIdx, extra in ipairs(CONFIG.extras) do
                if extra.type == "custom" then
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
                        -- 22, not 4: a cooldown row is cb +2 swatch(16) +4 icon, and a custom row has no
                        -- cooldown swatch. Matching the total keeps the slot columns below aligned.
                        cRow.abilIcon:SetPoint("LEFT", cRow.cb, "RIGHT", 22, 0)
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
                        end
                        ns.SaveCurrentProfile()
                        LoadEssentialCooldowns()
                        RefreshCooldownRows()
                    end)

                    yOffset = yOffset + 30
                end
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
        local sections = {
            { cat = 2, label = "Tracked Buffs (estimated timing)" },
            { cat = 3, label = "Tracked Bars (exact timing)" },
        }
        local catLabel = {}
        local seen = {}
        local totalCount = 0

        -- The DataProvider reports the player's real layout; GetCooldownViewerCategorySet
        -- reports the static default category. An empty section is valid and means
        -- everything was moved out of it, so only an unreadable one falls back.
        -- Unlearned entries are included on purpose. A multi variant spell parks
        -- its entry under the variant that is not talented, so the Cooldown
        -- Manager greys it out even though the player has the ability and the
        -- aura. Excluding it here is what made those buffs impossible to pair.
        local dpIds = {}
        if ns.OrderedCooldownIDs then
            for _, sec in ipairs(sections) do
                local dpResult = ns.OrderedCooldownIDs(sec.cat, true)
                if type(dpResult) == "table" then dpIds[sec.cat] = dpResult end
            end
        end

        for _, sec in ipairs(sections) do
            sec.ids = {}
            catLabel[sec.cat] = sec.label
            local catIds = dpIds[sec.cat]
            if not catIds then
                local catOk, catResult = pcall(function()
                    return C_CooldownViewer.GetCooldownViewerCategorySet(sec.cat, true)
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
                        -- Shown only on a spell whose bar would be estimated, so the
                        -- mark means "this one is measured", not "this one is broken".
                        btn.estimateDot = btn:CreateTexture(nil, "OVERLAY", nil, 2)
                        btn.estimateDot:SetSize(8, 8)
                        btn.estimateDot:SetPoint("BOTTOMRIGHT", 1, -1)
                        btn.estimateDot:Hide()
                        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                        buffPoolCache[btnIdx] = btn
                        buffPoolCacheCount = math.max(buffPoolCacheCount, btnIdx)
                    end

                    -- Matched on the entry, not on one spell id field: the aura is
                    -- often measured on a different entry than the one being paired.
                    local learnState, learnDur, learnKey = "unlearned", nil, nil
                    if ns.AuraCompat then
                        learnState, learnDur, learnKey =
                            ns.AuraCompat.GetLearnStateForCooldown(buffCdID)
                    end
                    -- Marked only once the fallback has actually had to run for this
                    -- spell. A measured duration the game never makes us use is not
                    -- something the player needs to decide about.
                    local estimatable = (learnState == "learned") and learnKey ~= nil
                        and ns.AuraCompat.IsEstimateUsed(learnKey)
                    local function RefreshEstimateDot()
                        if not estimatable then btn.estimateDot:Hide() return end
                        local on = ns.AuraCompat.IsEstimateAllowed(learnKey)
                        btn.estimateDot:SetColorTexture(
                            on and 0.2 or 0.6, on and 0.9 or 0.6, on and 0.3 or 0.6, 1)
                        btn.estimateDot:Show()
                    end
                    btn.RefreshEstimateDot = RefreshEstimateDot
                    RefreshEstimateDot()

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
                        if ns.AuraCompat then
                            local state, dur = learnState, learnDur
                            if secCat == 2 then
                                -- Icons never carry timing, so the estimate is the whole story.
                                if state == "permanent" then
                                    GameTooltip:AddLine("Permanent buff, drawn as a full bar.", 0.5, 0.9, 0.5, true)
                                elseif state == "learned" then
                                    GameTooltip:AddLine(string.format("Estimated at %.1fs. Will not follow refreshes or haste.", dur), 1, 0.82, 0, true)
                                else
                                    GameTooltip:AddLine("Length not measured. It can only be measured while the buff is up outside combat and outside instances, which is not possible for every buff.", 1, 0.5, 0.5, true)
                                end
                            elseif secCat == 3 and estimatable then
                                -- Only entries the game has actually left empty. The rest
                                -- carry real timing and need no notice at all.
                                GameTooltip:AddLine(string.format("The game does not feed this bar, so it is estimated at %.1fs.", dur), 1, 0.82, 0, true)
                            end
                        end
                        if estimatable then
                            if ns.AuraCompat.IsEstimateAllowed(learnKey) then
                                GameTooltip:AddLine("Estimated bar: ON. Right click to switch it off for this buff.", 0.5, 0.9, 0.5, true)
                            else
                                GameTooltip:AddLine("Estimated bar: OFF. This buff draws nothing unless the game supplies real timing. Right click to switch it on.", 0.6, 0.6, 0.6, true)
                            end
                        end
                        GameTooltip:AddLine("Click to select, then click a Buff or Stack slot above.", 0.5, 0.8, 0.5, true)
                        GameTooltip:Show()
                    end)
                    btn:SetScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)

                    btn:SetScript("OnClick", function(self, button)
                        if button == "RightButton" then
                            if not estimatable then return end
                            ns.AuraCompat.SetEstimateAllowed(learnKey,
                                not ns.AuraCompat.IsEstimateAllowed(learnKey))
                            RefreshEstimateDot()
                            self:GetScript("OnEnter")(self)
                            return
                        end
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

    -- TAB B: DISPLAY
    local displayTab = CreateFrame("Frame", nil, contentArea)
    displayTab:SetAllPoints()
    displayTab:Hide()
    tabFrames[2] = displayTab

    local dispScroll, dispContent = CreateScrollableContent(displayTab)
    -- A slider's SetValue fires its own OnValueChanged, so every handler below must
    -- honour this. Extras Bar Height is the damaging one: nil means follow bar height.
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
        if dispRefreshing then return end
        CONFIG.past = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(pastSlider)

    -- Bar Layout
    AddDispHeader("Bar Layout")
    AddDispDescription("Controls the size of each bar row. Width and height set the dimensions in pixels. Spacing is the gap between rows. Scale multiplies the entire frame.")

    local widthSlider = CreateSlider(dispContent, "Bar Width", 100, 600, 1, CONFIG.width, function(v)
        if dispRefreshing then return end
        CONFIG.width = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(widthSlider)

    local heightSlider = CreateSlider(dispContent, "Bar Height", 8, 40, 1, CONFIG.height, function(v)
        if dispRefreshing then return end
        CONFIG.height = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(heightSlider)

    local extrasHeightSlider = CreateSlider(dispContent, "Extras Bar Height", 8, 40, 1, CONFIG.extrasHeight or CONFIG.height, function(v)
        if dispRefreshing then return end
        CONFIG.extrasHeight = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(extrasHeightSlider)

    local spacingSlider = CreateSlider(dispContent, "Spacing", 0, 5, 0.5, CONFIG.spacing, function(v)
        if dispRefreshing then return end
        CONFIG.spacing = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(spacingSlider)

    local scaleSlider = CreateSlider(dispContent, "Scale", 0.5, 3.0, 0.05, CONFIG.scale, function(v)
        if dispRefreshing then return end
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
        if dispRefreshing then return end
        CONFIG.paddingTop = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(padTopSlider)

    local padBotSlider = CreateSlider(dispContent, "Padding Bottom", 0, 20, 1, CONFIG.paddingBottom, function(v)
        if dispRefreshing then return end
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

    local hiddenIconSlider = CreateSlider(dispContent, "Space Left Of Bars When Icons Off", 0, 40, 1,
        CONFIG.hiddenIconWidth or 0, function(v)
        CONFIG.hiddenIconWidth = v
        ApplyLayoutToAllBars()
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(hiddenIconSlider)
    AddDispDescription("At 0 the bars sit flush against the left padding, which is usually the point of hiding icons. Raise it to keep a column for the charge and stack text; at 0 that text moves onto the bars and is positioned with the anchors in Colours.")

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

    -- Toggle, width and colour together, not split across tabs.
    AddDispHeader("Cast Spark")
    AddDispDescription("Draws a line at the end of a cast, crossing every lane and travelling toward the now line, so you can read where the cast lands against everything else on the timeline.")

    local castSparkCheck = CreateCheckbox(dispContent, "Enable Cast Spark",
        "Off by default. Channels and empowered casts use it too.", CONFIG.castSpark, function(v)
        CONFIG.castSpark = v
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(castSparkCheck)

    local castSparkWidthSlider = CreateSlider(dispContent, "Cast Spark Width", 1, 6, 1, CONFIG.castSparkWidth, function(v)
        CONFIG.castSparkWidth = v
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(castSparkWidthSlider)

    local castSparkMatchCheck = CreateCheckbox(dispContent, "Match The Cast Bar Colour",
        "Uses the colour of the spell being cast, including any per spell cast colour. Untick to always use the colour below.",
        CONFIG.castSparkMatchCast, function(v)
        CONFIG.castSparkMatchCast = v
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(castSparkMatchCheck)

    local castSparkSwatch = CreateColorSwatch(dispContent, "Cast Spark Colour", DeepCopy(CONFIG.castSparkColor), function(c)
        CONFIG.castSparkColor = c
        ns.SaveCurrentProfile()
    end)
    AddDispWidget(castSparkSwatch)

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

    -- Body split out so the flag can be restored through a pcall: a throw in
    -- here would otherwise leave the whole Display tab read only.
    local function RefreshDisplayTab()
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
        hiddenIconSlider:SetValue(CONFIG.hiddenIconWidth or 0)
        nowLineSlider:SetValue(CONFIG.nowLineWidth or 2)
        gcdSparkSlider:SetValue(CONFIG.gcdSparkWidth or 3)
        castSparkCheck:SetChecked(CONFIG.castSpark or false)
        castSparkWidthSlider:SetValue(CONFIG.castSparkWidth or 1)
        castSparkMatchCheck:SetChecked(CONFIG.castSparkMatchCast ~= false)
        if CONFIG.castSparkColor then castSparkSwatch:SetColor(DeepCopy(CONFIG.castSparkColor)) end
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
    end

    displayTab:SetScript("OnShow", function()
        local was = dispRefreshing
        dispRefreshing = true
        local ok, err = pcall(RefreshDisplayTab)
        dispRefreshing = was
        if not ok then
            print("|cff00ff00[Infall]|r The display settings could not be refreshed. Reload if it looks wrong: " .. tostring(err))
        end
    end)

    -- TAB C: COLOURS
    BuildColoursTab(contentArea, tabFrames)

    -- TAB D: TOGGLES
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

    local autoPairCheck = CreateCheckbox(togContent, "Pair Buffs Automatically",
        "Off by default. Pair rows by hand on the Bars and Icons tabs. Turn this on to have empty pairings filled in from the Cooldown Manager instead, preferring a Tracked Bars entry, which is a guess and can light a row on the wrong aura.",
        CONFIG.autoPairBuffs == true, function(v)
            CONFIG.autoPairBuffs = v
            if v and not InCombatLockdown() then
                -- Switching it on is the explicit "fill my empty rows", so it
                -- forgets which rows were cleared by hand. Nothing else does.
                CONFIG.pairingCleared = {}
                if ns.AutoPopulateSelfBuffMappings then ns.AutoPopulateSelfBuffMappings() end
            end
            ns.SaveCurrentProfile()
        end)
    AddTogWidget(autoPairCheck)

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

    -- Rune abilities. Only built when the class declares base cooldowns. Declared
    -- outside the branch so the OnShow restore can reach it.
    local runeCdCheck
    if CONFIG.runeBaseCooldowns then
        AddTogHeader("Rune Abilities")

        runeCdCheck = CreateCheckbox(togContent, "Estimate Rune Cooldowns",
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
        autoPairCheck:SetChecked(CONFIG.autoPairBuffs == true)
        hideEssentialCheck:SetChecked(CONFIG.hideEssentialCD)
        hideUtilityCheck:SetChecked(CONFIG.hideUtilityCD)
        hideBuffIconCheck:SetChecked(CONFIG.hideBuffIconCD)
        hideBuffBarCheck:SetChecked(CONFIG.hideBuffBarCD)
        showCdDurationCheck:SetChecked(CONFIG.showCooldownDuration)
        cdMinDurSlider:SetValue(CONFIG.cdTextMinDuration or 30)
        if runeCdCheck then runeCdCheck:SetChecked(CONFIG.estimateRuneCooldowns) end
        RefreshCDMStatus()
    end)

    -- TAB E: PROFILES
    local profilesTab = CreateFrame("Frame", nil, contentArea)
    profilesTab:SetAllPoints()
    profilesTab:Hide()
    tabFrames[8] = profilesTab

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
    local copyHeader = CreateSectionHeader(profContent, "Copy Icons From Another Spec")
    copyHeader:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    profY = profY + 22

    local copyHint = profContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    copyHint:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    copyHint:SetWidth(460)
    copyHint:SetJustifyH("LEFT")
    copyHint:SetSpacing(2)
    copyHint:SetText("Replaces this spec's icons with another spec's, buff pairings included. Rows this spec cannot use hide themselves.")
    profY = profY + copyHint:GetStringHeight() + 8

    local copySelectBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    copySelectBtn:SetSize(240, 24)
    copySelectBtn:SetPoint("TOPLEFT", profContent, "TOPLEFT", 10, -profY)
    copySelectBtn:SetText("Select a source...")
    copySelectBtn.selectedValue = nil

    local copyMenuFrame = CreateFrame("Frame", nil, copySelectBtn, "BackdropTemplate")
    copyMenuFrame:SetPoint("TOPLEFT", copySelectBtn, "BOTTOMLEFT", 0, -2)
    copyMenuFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    copyMenuFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    copyMenuFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    copyMenuFrame:SetFrameStrata("DIALOG")
    copyMenuFrame:Hide()

    local copyBtnCache = {}
    local copyIconsBtn

    local function RefreshCopyDropdown()
        for _, b in ipairs(copyBtnCache) do b:Hide() end

        local sources = ns.IconCopySources and ns.IconCopySources() or {}
        local menuHeight = 4
        for i, src in ipairs(sources) do
            local optBtn = copyBtnCache[i]
            if not optBtn then
                optBtn = CreateFrame("Button", nil, copyMenuFrame)
                optBtn:SetSize(236, 20)
                optBtn:SetNormalFontObject("GameFontHighlightSmall")
                optBtn:SetHighlightFontObject("GameFontNormalSmall")
                local hl = optBtn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(0.3, 0.3, 0.5, 0.4)
                copyBtnCache[i] = optBtn
            end

            optBtn:Show()
            optBtn:ClearAllPoints()
            optBtn:SetPoint("TOPLEFT", 2, -(2 + (i - 1) * 20))
            optBtn:SetText(src.label)
            optBtn:GetFontString():SetJustifyH("LEFT")
            optBtn:GetFontString():SetPoint("LEFT", 4, 0)
            optBtn:SetScript("OnClick", function()
                copySelectBtn:SetText(src.label)
                copySelectBtn.selectedValue = src.key
                copyMenuFrame:Hide()
                if copyIconsBtn then
                    copyIconsBtn:SetText("Copy")
                    copyIconsBtn.armed = nil
                end
            end)

            menuHeight = menuHeight + 20
        end

        if #sources == 0 then menuHeight = 24 end
        copyMenuFrame:SetSize(240, menuHeight)
    end

    copySelectBtn:SetScript("OnClick", function()
        if copyMenuFrame:IsShown() then
            copyMenuFrame:Hide()
        else
            RefreshCopyDropdown()
            copyMenuFrame:Show()
        end
    end)

    copyMenuFrame:SetScript("OnShow", function()
        copyMenuFrame:SetScript("OnUpdate", function()
            if not copyMenuFrame:IsMouseOver() and not copySelectBtn:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") then
                    copyMenuFrame:Hide()
                end
            end
        end)
    end)
    copyMenuFrame:SetScript("OnHide", function()
        copyMenuFrame:SetScript("OnUpdate", nil)
    end)

    copyIconsBtn = CreateFrame("Button", nil, profContent, "UIPanelButtonTemplate")
    copyIconsBtn:SetSize(110, 24)
    copyIconsBtn:SetText("Copy")
    copyIconsBtn:SetPoint("LEFT", copySelectBtn, "RIGHT", 8, 0)
    copyIconsBtn:SetScript("OnClick", function(self)
        local key = copySelectBtn.selectedValue
        if not key then
            print("|cff00ff00[Infall]|r Pick a source to copy from first.")
            return
        end
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Not in combat.")
            return
        end

        -- Second click confirms. This replaces what is already here, and there is
        -- no undo short of a saved named profile.
        local existing = #(CONFIG.iconList or {})
        if existing > 0 and not self.armed then
            self.armed = true
            self:SetText("Replace " .. existing .. "?")
            return
        end

        local ok, result, paired = ns.CopyIconsFromProfile(key)
        self.armed = nil
        self:SetText("Copy")
        if not ok then
            print("|cff00ff00[Infall]|r Could not copy icons: " .. tostring(result))
            return
        end
        if refreshSettingsUI then refreshSettingsUI() end
        print("|cff00ff00[Infall]|r Copied " .. tostring(result) .. " icons and "
            .. tostring(paired) .. " buff pairings. Rows this spec cannot use are hidden, delete them on the Icons tab.")
    end)
    copyIconsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Copy Icons")
        GameTooltip:AddLine("Click twice to confirm. Other characters of the same class are listed too. A pairing this spec already has is never replaced.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    copyIconsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    profY = profY + 34

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

    -- IMPORT / EXPORT

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

    -- A scroll child is only as tall as its content, so an empty box is one clickable
    -- line. Hand focus over instead. Do not force a height: that clips a long export string.
    local function FocusIE()
        ieEditBox:SetFocus()
    end
    ieBoxFrame:EnableMouse(true)
    ieBoxFrame:SetScript("OnMouseDown", FocusIE)
    ieScroll:EnableMouse(true)
    ieScroll:SetScript("OnMouseDown", FocusIE)

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

    -- TAB F: STACKS
    BuildStacksTab(contentArea, tabFrames)

    -- TAB G: RESOURCE BAR
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

    -- TAB H: ICONS
    if ns.BuildIconsTab then
        ns.BuildIconsTab(contentArea, tabFrames, {
            CreateCheckbox = CreateCheckbox,
            CreateSlider = CreateSlider,
            CreateSectionHeader = CreateSectionHeader,
            CreateScrollableContent = CreateScrollableContent,
            CreateDropdown = CreateDropdown,
            CreateColorSwatch = CreateColorSwatch,
            GetFontOptions = GetFontOptions,
            FONT_FLAG_OPTIONS = FONT_FLAG_OPTIONS,
            ANCHOR_POINTS = ANCHOR_POINTS,
        })
    end

    -- REGISTRATION

    local category = Settings.RegisterCanvasLayoutCategory(settingsFrame, "EventHorizon Infall")
    Settings.RegisterAddOnCategory(category)
    ns.settingsCategoryID = category:GetID()

    -- Make settings panel movable. StopMovingOrSizing is protected on this frame,
    -- so calling it in combat is refused and leaves the panel on the cursor. The
    -- stop is deferred to combat end instead of being made and blocked.
    local panel = SettingsPanel
    if panel then
        panel:SetMovable(true)
        panel:SetClampedToScreen(true)
        panel:RegisterForDrag("LeftButton")

        local function StopPanelMove()
            if not panel.infallMoving then return end
            if InCombatLockdown() then return end
            panel.infallMoving = nil
            panel:StopMovingOrSizing()
        end

        panel:HookScript("OnDragStart", function(self)
            if InCombatLockdown() then return end
            self.infallMoving = true
            self:StartMoving()
        end)
        panel:HookScript("OnDragStop", StopPanelMove)
        panel:HookScript("OnHide", StopPanelMove)

        local combatWatch = CreateFrame("Frame")
        combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
        combatWatch:SetScript("OnEvent", StopPanelMove)
    end

    SelectTab(1)
end

-- SETTINGS API

-- Called at PLAYER_LOGIN to register the panel in the ESC menu
ns.InitSettings = BuildSettings

function ns.OpenSettings()
    BuildSettings()
    Settings.OpenToCategory(ns.settingsCategoryID)
end
