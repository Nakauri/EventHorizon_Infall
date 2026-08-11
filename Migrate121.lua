-- EventHorizon Infall: 12.1 aura timing notice. Shown once, then reachable from
-- the 12.1 Note button in settings. Does not modify the Cooldown Manager.

local ns = EventHorizon_Infall
local M = {}
ns.Migrate121 = M

local PAD = 24          -- 8px grid
local GAP = 16
local WIDTH = 540

local win
local SetActionsEnabled   -- defined in the combat section below

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Infall]|r " .. msg)
end

-- Detection

-- Reads the live viewer, not GetCooldownViewerCategorySet, which returns
-- static categories and includes entries the player has since hidden.
function M.FindAffected()
    local out = {}
    local viewer = _G.BuffIconCooldownViewer
    local pool = viewer and viewer.itemFramePool
    if not pool then return out end

    local seen = {}
    local ok = pcall(function()
        for frame in pool:EnumerateActive() do
            local cdID = frame.cooldownID
            if cdID and not seen[cdID] then
                seen[cdID] = true
                local name
                local iOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                if iOk and info then
                    local sid = info.overrideSpellID or info.spellID
                    if sid then name = C_Spell.GetSpellName(sid) end
                end
                out[#out + 1] = { cooldownID = cdID, name = name or ("Cooldown " .. tostring(cdID)) }
            end
        end
    end)
    if not ok then return {} end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Names up to four, otherwise a count.
function M.AffectedNames(list)
    local n = #list
    if n == 0 then return "" end
    if n <= 4 then
        local names = {}
        for _, e in ipairs(list) do names[#names + 1] = e.name end
        return table.concat(names, ", ")
    end
    return string.format("%d buffs, including %s, %s and %s",
        n, list[1].name, list[2].name, list[3].name)
end

-- Window

local function OpenCooldownManager()
    if InCombatLockdown() then
        Say("The Cooldown Manager cannot be opened in combat.")
        return
    end
    if SettingsPanel and SettingsPanel:IsShown() then
        HideUIPanel(SettingsPanel)
    end
    if CooldownViewerSettings and CooldownViewerSettings.TogglePanel then
        pcall(function() CooldownViewerSettings:TogglePanel() end)
    end
end

local function MakeButton(parent, text)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetText(text)
    b:SetHeight(24)
    b:SetWidth(math.max(96, b:GetFontString():GetStringWidth() + 32))
    return b
end

local function BuildWindow()
    local f = CreateFrame("Frame", "InfallMigrationFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetWidth(WIDTH)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    if f.SetTitle then f:SetTitle("EventHorizon Infall")
    elseif f.TitleText then f.TitleText:SetText("EventHorizon Infall") end

    -- Template seats the title against the top edge.
    local title = (f.TitleContainer and f.TitleContainer.TitleText) or f.TitleText
    if title then
        pcall(function()
            title:ClearAllPoints()
            title:SetPoint("TOP", f, "TOP", 0, -8)
        end)
    end

    f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.heading:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -40)
    f.heading:SetJustifyH("LEFT")

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -GAP)
    f.body:SetWidth(WIDTH - PAD * 2)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(4)

    f.list = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.list:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -GAP)
    f.list:SetWidth(WIDTH - PAD * 2)
    f.list:SetJustifyH("LEFT")
    f.list:SetJustifyV("TOP")
    f.list:SetSpacing(4)
    f.list:SetTextColor(1, 0.82, 0)

    f.btnPrimary = MakeButton(f, "Open Cooldown Manager")
    f.btnPrimary.combatLocked = true
    f.btnSecondary = MakeButton(f, "Close")

    f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.note:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD - 2)
    f.note:SetJustifyH("LEFT")
    f.note:SetText("Available after combat.")
    f.note:Hide()

    f.btnPrimary:SetScript("OnClick", OpenCooldownManager)
    f.btnSecondary:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    return f
end

local function Layout(f)
    local contentBottom = 40 + f.heading:GetStringHeight() + GAP
        + f.body:GetStringHeight() + GAP + f.list:GetStringHeight()

    f.btnSecondary:ClearAllPoints()
    f.btnSecondary:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD - 8)
    f.btnPrimary:ClearAllPoints()
    f.btnPrimary:SetPoint("RIGHT", f.btnSecondary, "LEFT", -8, 0)

    f:SetHeight(contentBottom + GAP + 24 + PAD)
end

function M.ShowNote()
    win = win or BuildWindow()
    local list = M.FindAffected()

    win.heading:SetText("Aura timing changed in 12.1")
    win.body:SetText(
        "Blizzard changed how addons read buff timers in 12.1.\n\n"
        .. "Buffs in the Cooldown Manager's Tracked Bars section still show exact timing.\n\n"
        .. "Buffs left in Tracked Buffs are estimated. EventHorizon has to see the buff "
        .. "once outside combat to learn how long it lasts, then reuses that length. "
        .. "The bar will not follow refreshes, and will not adjust for haste.\n\n"
        .. "Moving them to Tracked Bars avoids all of that. Open the Cooldown Manager "
        .. "below, pick the Buffs tab on the right, then drag your buffs from "
        .. "Tracked Buffs into Tracked Bars."
    )
    win.list:SetText(#list > 0 and ("Currently estimated:\n" .. M.AffectedNames(list)) or "")

    Layout(win)
    SetActionsEnabled(not InCombatLockdown())
    win:Show()
end

-- Combat. The window stays up; only opening Blizzard's panel is restricted.

local queuedPrompt = false

SetActionsEnabled = function(enabled)
    if not win then return end
    if win.btnPrimary.combatLocked then
        if enabled then win.btnPrimary:Enable() else win.btnPrimary:Disable() end
    end
    if win.note then win.note:SetShown(not enabled) end
end

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        SetActionsEnabled(false)
    else
        SetActionsEnabled(true)
        if queuedPrompt then
            queuedPrompt = false
            C_Timer.After(1, function() M.CheckOnLogin() end)
        end
    end
end)

-- Login

function M.CheckOnLogin()
    if InfallDB and InfallDB.seen121Note then return end
    -- Deferred until combat ends.
    if InCombatLockdown() then
        queuedPrompt = true
        return
    end
    if #M.FindAffected() == 0 then return end

    InfallDB = InfallDB or {}
    InfallDB.seen121Note = true
    M.ShowNote()
end

