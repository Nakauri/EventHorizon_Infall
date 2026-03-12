-- EventHorizon Infall: bar creation, update loop, event handling, slash commands.

local ns = EventHorizon_Infall

local CONFIG = ns.CONFIG
local EH_Parent = ns.EH_Parent
local cooldownBars = ns.cooldownBars
local barPool = ns.barPool

local ADDON_NAME = ns.ADDON_NAME

CONFIG.extraCasts = CONFIG.extraCasts or {}
CONFIG.buffMappings = CONFIG.buffMappings or {}
CONFIG.stackMappings = CONFIG.stackMappings or {}
CONFIG.castColors = CONFIG.castColors or {}
CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
CONFIG.chargesDisabled = CONFIG.chargesDisabled or {}

local activeCast
local cachedGcdDurObj
local shownSetupHint = false
local permanentBuffCdIDs = {}
local deferredGen = {}
local specChangeToken = 0
local specChangePending = false

local function GetEmpowerStageColor(stage)
    if stage == 1 then return CONFIG.empowerStage1Color
    elseif stage == 2 then return CONFIG.empowerStage2Color
    elseif stage == 3 then return CONFIG.empowerStage3Color
    elseif stage == 4 then return CONFIG.empowerStage4Color
    end
    return CONFIG.empowerStage4Color
end

local function HideCastOverlays(row)
    if not row then return end
    if row.castTex then row.castTex:Hide() end
    if row.empowerStageTex then
        for _, tex in ipairs(row.empowerStageTex) do
            tex:Hide()
        end
    end
    if row.chainWindowTex then
        row.chainWindowTex:Hide()
    end
end

-- Offscreen because OnCooldownDone does not fire on zero alpha frames.
local hiddenCDParent = CreateFrame("Frame", nil, UIParent)
hiddenCDParent:SetSize(1, 1)
hiddenCDParent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
hiddenCDParent:Show()

-- Hidden GCD cooldown; OnCooldownDone fires when GCD ends.
local gcdActive = false

local hiddenGcdCooldown = CreateFrame("Cooldown", nil, hiddenCDParent, "CooldownFrameTemplate")
hiddenGcdCooldown:SetAllPoints(hiddenCDParent)
hiddenGcdCooldown:SetDrawSwipe(false)
hiddenGcdCooldown:SetDrawBling(false)
hiddenGcdCooldown:SetDrawEdge(false)
hiddenGcdCooldown:SetHideCountdownNumbers(true)
hiddenGcdCooldown:Show()

hiddenGcdCooldown:SetScript("OnCooldownDone", function(self)
    gcdActive = false
end)

local lastFedGcdDurObj = nil

-- Curves for secret safe desaturation and alpha.
-- BinaryCurve: 0% remaining = 0, >0% = 1 (for SetDesaturation).
-- AlphaCurve: 0s remaining = 0, >0s = 1 (for SetAlpha).
local BinaryCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if BinaryCurve then
    BinaryCurve:AddPoint(0.0, 0)      -- 0% remaining (ready) → 0
    BinaryCurve:AddPoint(0.001, 1)    -- >0% remaining (on CD) → 1
    BinaryCurve:AddPoint(1.0, 1)
end

local AlphaCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if AlphaCurve then
    AlphaCurve:AddPoint(0.0, 0)       -- 0s remaining → alpha 0 (invisible)
    AlphaCurve:AddPoint(0.001, 1)     -- >0s remaining → alpha 1 (visible)
    AlphaCurve:AddPoint(300, 1)       -- stays visible for any positive duration
end

-- pastSlideAlpha: read inline from CONFIG.cooldownColor[4] so profile changes apply immediately

local detShown = {}

local BuffFillCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if BuffFillCurve then
    BuffFillCurve:AddPoint(0.0, CONFIG.future)
    BuffFillCurve:AddPoint(0.01, 0.01)
    BuffFillCurve:AddPoint(3600, 3600)
end

-- InvertedAlphaCurve: visible when timer is NOT active, invisible when active.
local InvertedAlphaCurve = C_CurveUtil and C_CurveUtil.CreateCurve and C_CurveUtil.CreateCurve()
if InvertedAlphaCurve then
    InvertedAlphaCurve:AddPoint(0.0, 1)       -- 0s remaining → alpha 1 (visible when NOT active)
    InvertedAlphaCurve:AddPoint(0.001, 0)     -- >0s remaining → alpha 0 (invisible when active)
    InvertedAlphaCurve:AddPoint(300, 0)       -- stays invisible for any positive duration
end

local SMOOTH_INTERPOLATION = Enum and Enum.StatusBarInterpolation
    and Enum.StatusBarInterpolation.ExponentialEaseOut or nil
local function GetInterpolation()
    return CONFIG.smoothBars and SMOOTH_INTERPOLATION or nil
end

local UpdateChargeState
local FeedChargeHiddenFrames

-- Apply CONFIG font (or fallback) to a FontString at a given size.
local function ApplyFont(fontString, size)
    if CONFIG.font then
        fontString:SetFont(CONFIG.font, size, CONFIG.fontFlags)
    else
        fontString:SetFontObject(GameFontNormalLarge)
        local fontFace = fontString:GetFont()
        fontString:SetFont(fontFace, size, CONFIG.fontFlags)
    end
end

local function GetChargesWithOverride(spellID, baseSpellID)
    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not ok then info = nil end
    if not (info and info.maxCharges) then
        local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, baseSpellID or spellID)
        if ovOk and ovID and ovID ~= spellID then
            ok, info = pcall(C_Spell.GetSpellCharges, ovID)
            if not ok then info = nil end
        end
    end
    return info
end

local function PreCacheChargeSpells()
    if InCombatLockdown() then return end

    InfallDB.chargeSpells = InfallDB.chargeSpells or {}
    InfallDB.chargeDurations = InfallDB.chargeDurations or {}

    local cooldownIDs = {}
    local success, result = pcall(function()
        return C_CooldownViewer.GetCooldownViewerCategorySet(0, true)
    end)
    if success and result then cooldownIDs = result end

    for _, cooldownID in ipairs(cooldownIDs) do
        local infoOk, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
        local spellID = infoOk and cdInfo and cdInfo.spellID
        if spellID then
            local chargeInfo = GetChargesWithOverride(spellID)
            if chargeInfo and chargeInfo.maxCharges then
                InfallDB.chargeSpells[cooldownID] = {
                    hasChargeMechanic = true,
                    maxCharges = chargeInfo.maxCharges
                }
                if chargeInfo.cooldownDuration and chargeInfo.cooldownDuration > 0 then
                    InfallDB.chargeDurations[cooldownID] = chargeInfo.cooldownDuration
                end
            end
        end
    end
end


local GetBarOffset
local GetContainerWidth
local SpawnPastSlide
local DetachPastSlide
local UpdateBuffState
local UpdateStackText
local UpdateDesaturation
local ScanViewerFrames

-- Bar spans -past..+future; "now" at (past / totalSpan) from left.

local function GetTotalSpan()
    return CONFIG.past + CONFIG.future
end

local function GetNowPixelOffset()
    return (CONFIG.past / GetTotalSpan()) * CONFIG.width
end

local function GetFutureWidth()
    return CONFIG.width - GetNowPixelOffset()
end

local function GetPastWidth()
    return GetNowPixelOffset()
end

local function TimeToPixel(timeOffset)
    local fraction = (timeOffset + CONFIG.past) / GetTotalSpan()
    return fraction * CONFIG.width
end

local function CleanupActiveCast(excludeRow)
    if not activeCast then return end
    if activeCast.pastSlide then
        DetachPastSlide(activeCast.pastSlide)
    end
    if activeCast.row and activeCast.row ~= excludeRow then
        HideCastOverlays(activeCast.row)
    end
end

-- straddles now line

local function UpdateCastBar(event)
    local name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID
    local isChannel = false
    local numStages

    -- Prioritize based on event type to avoid stale data
    if event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
       or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo("player")
        isChannel = true
        if not name then
            name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo("player")
            isChannel = false
        end
    else
        name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo("player")
        if not name then
            name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID, _, numStages = UnitChannelInfo("player")
            isChannel = true
        end
    end

    -- Empowered cast: extended endTime to include hold-at-max time
    local isEmpowered = numStages and numStages > 0
    if isEmpowered and endTimeMS then
        local ok, holdTimeMS = pcall(GetUnitEmpowerHoldAtMaxTime, "player")
        if ok and holdTimeMS then
            endTimeMS = endTimeMS + holdTimeMS
        end
    end
    
    if name and spellID then
        local targetRow = nil
        for _, row in ipairs(cooldownBars) do
            if row.spellID == spellID or row.baseSpellID == spellID then
                targetRow = row
                break
            end
            
            local extraCasts = CONFIG.extraCasts[row.cooldownID] or CONFIG.extraCasts[row.baseSpellID] or CONFIG.extraCasts[row.spellID]
            if extraCasts then
                for _, extraSpellID in ipairs(extraCasts) do
                    if extraSpellID == spellID then
                        targetRow = row
                        break
                    end
                end
            end
            
            if targetRow then break end
        end
        
        if targetRow then
            -- If this is the same cast already tracked, just update timing (channel tick, pushback)
            if activeCast and activeCast.spellID == spellID and activeCast.row == targetRow then
                local startSec = startTimeMS / 1000
                local durSec = (endTimeMS - startTimeMS) / 1000
                activeCast.isChannel = isChannel
                if isEmpowered or activeCast.isDisintegrate then
                    activeCast.startTimeSec = startSec
                end
                if C_DurationUtil and durSec > 0 then
                    local durObj = C_DurationUtil.CreateDuration()
                    durObj:SetTimeFromStart(startSec, durSec, 1)
                    activeCast.durObj = durObj
                else
                    activeCast.endTime = endTimeMS / 1000
                end
                return
            end
            
            -- Clean up previous cast if one was active (queued spell transition)
            CleanupActiveCast(targetRow)

            local startSec = startTimeMS / 1000
            local durSec = (endTimeMS - startTimeMS) / 1000
            activeCast = {
                spellID = spellID,
                row = targetRow,
                isChannel = isChannel
            }
            -- DurObj for countdown; fallback to raw endTime
            if C_DurationUtil and durSec > 0 then
                local durObj = C_DurationUtil.CreateDuration()
                durObj:SetTimeFromStart(startSec, durSec, 1)
                activeCast.durObj = durObj
            else
                activeCast.endTime = endTimeMS / 1000
            end

            -- Empowered: build stage boundary array and create stage textures
            if isEmpowered then
                activeCast.isEmpowered = true
                activeCast.startTimeSec = startSec
                local stagePoints = {}
                local cumMS = 0
                for i = 1, numStages do
                    local sOk, stageDurMS = pcall(GetUnitEmpowerStageDuration, "player", i - 1)
                    if sOk and stageDurMS and stageDurMS > 0 then
                        cumMS = cumMS + stageDurMS
                        stagePoints[i] = cumMS / 1000
                    end
                end
                -- Final boundary: hold-at-max stage
                local hOk, holdMS = pcall(GetUnitEmpowerHoldAtMaxTime, "player")
                if hOk and holdMS and holdMS > 0 then
                    stagePoints[numStages + 1] = (cumMS + holdMS) / 1000
                end
                if #stagePoints > 0 then
                    activeCast.stagePoints = stagePoints
                    activeCast.numStages = #stagePoints

                    -- Create/reuse stage textures on this row
                    if not targetRow.empowerStageTex then
                        targetRow.empowerStageTex = {}
                    end
                    for i = 1, #stagePoints do
                        if not targetRow.empowerStageTex[i] then
                            local tex = targetRow.castFrame:CreateTexture(nil, "ARTWORK")
                            tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                            tex:SetSnapToPixelGrid(false)
                            tex:SetTexelSnappingBias(0)
                            targetRow.empowerStageTex[i] = tex
                        end
                        local c = GetEmpowerStageColor(i)
                        targetRow.empowerStageTex[i]:SetVertexColor(unpack(c))
                        targetRow.empowerStageTex[i]:Show()
                    end
                    -- Hide extras from a previous empowered cast with more stages
                    for i = #stagePoints + 1, #targetRow.empowerStageTex do
                        targetRow.empowerStageTex[i]:Hide()
                    end

                    -- Empowered uses stage textures, hide single castTex
                    targetRow.castTex:Hide()
                end
            end

            -- Per spell cast colour: check castColors mapping, fall back to global
            local castColors = CONFIG.castColors
            local color = castColors and castColors[spellID]
            if not color then
                color = CONFIG.castColor
            end
            activeCast.color = color

            -- Spawn past slide (stage 1 colour for empowered, cast colour otherwise)
            local slideColor = (isEmpowered and GetEmpowerStageColor(1)) or color
            activeCast.pastSlide = SpawnPastSlide(targetRow, targetRow.pastCastClip, slideColor)

            if not isEmpowered then
                -- Non-empowered: show castTex, hide any leftover overlays
                HideCastOverlays(targetRow)
                targetRow.castTex:SetVertexColor(unpack(color))
                targetRow.castTex:Show()

                -- Disintegrate chain window: coloured tail segment
                if spellID == 356995 then
                    activeCast.isDisintegrate = true
                    activeCast.startTimeSec = startSec
                    local maxTicks = C_SpellBook.IsSpellKnown(1219723) and 5 or 4
                    activeCast.chainWindowFraction = 1 / (maxTicks - 1)

                    if not targetRow.chainWindowTex then
                        local tex = targetRow.castFrame:CreateTexture(nil, "ARTWORK", nil, 1)
                        tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                        tex:SetSnapToPixelGrid(false)
                        tex:SetTexelSnappingBias(0)
                        targetRow.chainWindowTex = tex
                    end
                    targetRow.chainWindowTex:SetVertexColor(unpack(CONFIG.disintegrateChainColor))
                    targetRow.chainWindowTex:Show()
                end
            end
        else
            -- Casting an untracked spell, clean up any previous tracked cast
            CleanupActiveCast()
            activeCast = nil
        end
    else
        CleanupActiveCast()
        activeCast = nil
    end
end

local function UpdateActiveCastBar()
    if not activeCast then return end

    local remaining
    if activeCast.durObj then
        remaining = activeCast.durObj:GetRemainingDuration()
    else
        remaining = (activeCast.endTime or 0) - GetTime()
    end

    if remaining > 0 then
        local row = activeCast.row
        local barOffset = GetBarOffset()
        local nowPx = GetNowPixelOffset()
        local rowH = row:GetHeight()

        if activeCast.isEmpowered and activeCast.stagePoints and row.empowerStageTex then
            -- Empowered: position each stage segment individually
            local elapsed = GetTime() - activeCast.startTimeSec
            local currentStage = 1
            for i = 1, activeCast.numStages do
                local tex = row.empowerStageTex[i]
                if not tex then break end

                local stageStart = (i == 1) and 0 or (activeCast.stagePoints[i - 1] or 0)
                local stageEnd = activeCast.stagePoints[i]
                if not stageEnd then break end

                if elapsed >= stageStart then currentStage = i end

                -- Convert to time-from-now (positive = future)
                local segStartFromNow = stageStart - elapsed
                local segEndFromNow = stageEnd - elapsed

                -- Clamp to visible bar range [0, remaining]
                if segStartFromNow < 0 then segStartFromNow = 0 end
                if segEndFromNow > remaining then segEndFromNow = remaining end

                if segEndFromNow <= 0 or segStartFromNow >= remaining or segEndFromNow <= segStartFromNow then
                    tex:Hide()
                else
                    local segLeftPx = TimeToPixel(segStartFromNow)
                    local segRightPx = TimeToPixel(segEndFromNow)
                    local segWidth = segRightPx - segLeftPx
                    if segWidth < 1 then segWidth = 1 end

                    tex:ClearAllPoints()
                    tex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + segLeftPx, 0)
                    tex:SetSize(segWidth, rowH)
                    tex:Show()
                end
            end

            -- Past slide colour follows current stage
            if activeCast.pastSlide and activeCast.pastSlide.tex then
                local c = GetEmpowerStageColor(currentStage)
                activeCast.pastSlide.tex:SetVertexColor(unpack(c))
                activeCast.pastSlide.color = c
            end
        else
            -- Non-empowered cast/channel
            if activeCast.isDisintegrate and row.chainWindowTex then
                -- Disintegrate: split into main segment + chain window tail
                local elapsed = GetTime() - activeCast.startTimeSec
                local totalDur = remaining + elapsed
                local chainStartFromNow = totalDur * (1 - activeCast.chainWindowFraction) - elapsed

                if chainStartFromNow <= 0 then
                    -- Fully inside chain window: only chain colour in the future
                    row.castTex:Hide()
                    local cwRightPx = TimeToPixel(remaining)
                    local cwWidth = cwRightPx - nowPx
                    if cwWidth < 1 then cwWidth = 1 end
                    row.chainWindowTex:ClearAllPoints()
                    row.chainWindowTex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx, 0)
                    row.chainWindowTex:SetSize(cwWidth, rowH)
                    row.chainWindowTex:Show()

                    -- Transition: detach green past slide, spawn teal one
                    if not activeCast.chainWindowPastStarted then
                        activeCast.chainWindowPastStarted = true
                        if activeCast.pastSlide then
                            DetachPastSlide(activeCast.pastSlide)
                        end
                        activeCast.pastSlide = SpawnPastSlide(row, row.pastCastClip, CONFIG.disintegrateChainColor)
                    end
                elseif chainStartFromNow >= remaining then
                    -- Chain window not visible yet, full cast colour
                    row.chainWindowTex:Hide()
                    local rightPx = TimeToPixel(remaining)
                    local texLeft = barOffset + nowPx
                    local texWidth = rightPx - nowPx
                    if texWidth < 1 then texWidth = 1 end
                    row.castTex:ClearAllPoints()
                    row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", texLeft, 0)
                    row.castTex:SetSize(texWidth, rowH)
                    row.castTex:Show()
                else
                    -- Split: main portion + chain window
                    local splitPx = TimeToPixel(chainStartFromNow)

                    -- Main cast portion: now to chain window start
                    local mainLeft = barOffset + nowPx
                    local mainWidth = splitPx - nowPx
                    if mainWidth < 1 then mainWidth = 1 end
                    row.castTex:ClearAllPoints()
                    row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", mainLeft, 0)
                    row.castTex:SetSize(mainWidth, rowH)
                    row.castTex:Show()

                    -- Chain window: chain start to end
                    local cwRightPx = TimeToPixel(remaining)
                    local cwWidth = cwRightPx - splitPx
                    if cwWidth < 1 then cwWidth = 1 end
                    row.chainWindowTex:ClearAllPoints()
                    row.chainWindowTex:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + splitPx, 0)
                    row.chainWindowTex:SetSize(cwWidth, rowH)
                    row.chainWindowTex:Show()
                end
            else
                -- Standard non-empowered: single castTex from now to remaining
                local rightPx = TimeToPixel(remaining)
                local leftPx = nowPx
                local texLeft = barOffset + leftPx
                local texWidth = rightPx - leftPx
                if texWidth < 1 then texWidth = 1 end

                row.castTex:ClearAllPoints()
                row.castTex:SetPoint("TOPLEFT", row, "TOPLEFT", texLeft, 0)
                row.castTex:SetSize(texWidth, rowH)
                row.castTex:Show()
            end
        end
    else
        -- Cast completed, detach past slide
        if activeCast.pastSlide then
            DetachPastSlide(activeCast.pastSlide)
        end
        HideCastOverlays(activeCast.row)
        activeCast = nil
    end
end

-- Spawns at now, grows left, detaches and slides out

SpawnPastSlide = function(row, clip, color, height, yOffset)
    if not clip or CONFIG.past <= 0 or not CONFIG.showPastBars then return nil end
    
    height = height or clip:GetHeight()
    yOffset = yOffset or 0
    
    -- Recycle from the same clip frame only (reparenting breaks clip boundaries).
    local slide = nil
    for _, s in ipairs(row.pastSlides) do
        if not s.active and s.clip == clip then
            slide = s
            slide.active = true
            slide.startTime = GetTime()
            slide.color = color
            slide.detachTime = nil
            slide.detachWidth = nil
            slide.height = height
            slide.yOffset = yOffset
            break
        end
    end
    
    if not slide then
        local tex = clip:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
        slide = {
            tex = tex,
            active = true,
            startTime = GetTime(),
            color = color,
            detachTime = nil,
            detachWidth = nil,
            height = height,
            yOffset = yOffset,
            clip = clip,
        }
        table.insert(row.pastSlides, slide)
    end
    
    slide.tex:SetSize(1, height)
    slide.tex:SetVertexColor(color[1], color[2], color[3], color[4] or 0.7)
    slide.tex:ClearAllPoints()
    slide.tex:SetPoint("TOPRIGHT", clip, "TOPRIGHT", 0, -yOffset)
    slide.tex:Show()
    
    return slide
end

DetachPastSlide = function(slide)
    if not slide or not slide.active or slide.detachTime then return end
    slide.detachTime = GetTime()
    local pastWidth = GetPastWidth()
    if pastWidth <= 0 then
        slide.tex:Hide()
        slide.active = false
        return
    end
    local pxPerSec = pastWidth / CONFIG.past
    local age = slide.detachTime - slide.startTime
    local w = math.min(age * pxPerSec, pastWidth)
    slide.detachWidth = math.max(1, w)
end


local function UpdatePastSlides()
    local now = GetTime()
    local pastWidth = GetPastWidth()
    if pastWidth <= 0 then return end
    
    local pxPerSec = pastWidth / CONFIG.past
    
    for _, row in ipairs(cooldownBars) do
        if row.pastSlides then
            for _, slide in ipairs(row.pastSlides) do
                if slide.active then
                    if not slide.detachTime then
                        local age = now - slide.startTime
                        local w = math.min(age * pxPerSec, pastWidth)
                        w = math.max(1, w)
                        slide.tex:SetWidth(w)
                        slide.tex:SetHeight(slide.height)
                    else
                        local sinceDetach = now - slide.detachTime
                        local slideOffset = sinceDetach * pxPerSec
                        if slideOffset > pastWidth then
                            slide.tex:Hide()
                            slide.active = false
                        else
                            slide.tex:SetWidth(slide.detachWidth)
                            slide.tex:ClearAllPoints()
                            slide.tex:SetPoint("TOPRIGHT", slide.clip, "TOPRIGHT", -slideOffset, -slide.yOffset)
                        end
                    end
                end
            end
        end
    end
end

local function UpdateIconState(row)
    if CONFIG.hideIcons then return end
    if not row.spellID then return end
    if not CONFIG.reactiveIcons then
        row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
        return
    end
    
    local ok = pcall(function()
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(row.spellID)
        local inRange
        if C_Spell.SpellHasRange(row.spellID) then
            inRange = C_Spell.IsSpellInRange(row.spellID, "target")
        end
        
        if inRange == false then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotInRangeColor))
        elseif not isUsable and notEnoughMana then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotEnoughManaColor))
        elseif not isUsable then
            row.icon:SetVertexColor(unpack(CONFIG.iconNotUsableColor))
        else
            row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
        end
    end)
    
    if not ok then
        row.icon:SetVertexColor(unpack(CONFIG.iconUsableColor))
    end
end

local function UpdateAllIconStates()
    for _, row in ipairs(cooldownBars) do
        UpdateIconState(row)
    end
end

local function HandleProcGlow(row, show)
    if not CONFIG.reactiveIcons then return end
    if CONFIG.hideIcons then return end

    if show then
        if row.iconBorder then row.iconBorder:SetColorTexture(1, 0.82, 0, 1) end
        if row.innerGlowAnim then row.innerGlowAnim:Play() end
        if row.glowAnim then row.glowAnim:Play() end
        if row.iconGlow then row.iconGlow:Show() end
    else
        if row.iconBorder then row.iconBorder:SetColorTexture(0, 0, 0, 1) end
        if row.innerGlowAnim then row.innerGlowAnim:Stop() end
        if row.glowAnim then row.glowAnim:Stop() end
        if row.innerGlow then row.innerGlow:SetAlpha(0) end
        if row.iconGlow then row.iconGlow:Hide() end
    end
end

local CreateTimeLines
local ResizeContainer

local ICON_HIDDEN_WIDTH = 20
local ICON_HIDDEN_GAP = 4

GetBarOffset = function()
    if CONFIG.hideIcons then
        return ICON_HIDDEN_WIDTH + ICON_HIDDEN_GAP
    else
        return CONFIG.iconSize + (CONFIG.iconGap or 10)
    end
end

GetContainerWidth = function()
    local barOffset = GetBarOffset()
    return CONFIG.paddingLeft + barOffset + CONFIG.width + CONFIG.paddingRight
end

local function ApplyIconMode(row)
    local barOffset = GetBarOffset()
    local nowPx = GetNowPixelOffset()
    local futureWidth = GetFutureWidth()
    
    if CONFIG.hideIcons then
        row.icon:Hide()
        row.iconBorder:Hide()
        if row.cooldownFrame then row.cooldownFrame:Hide() end
        row.innerGlow:Hide()
        if row.iconGlow then row.iconGlow:Hide() end
        if row.innerGlowAnim and row.innerGlowAnim:IsPlaying() then row.innerGlowAnim:Stop() end
        if row.glowAnim and row.glowAnim:IsPlaying() then row.glowAnim:Stop() end
        
        row.iconContainer:SetSize(ICON_HIDDEN_WIDTH, CONFIG.height)
    else
        row.icon:Show()
        row.iconBorder:Show()
        row.innerGlow:SetAlpha(0)  -- default hidden state, procs will show it
        
        row.iconContainer:SetSize(CONFIG.iconSize, CONFIG.iconSize)
    end
    
    local nowOffset = barOffset + nowPx
    
    row.cdBar:ClearAllPoints()
    row.cdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.cdBar:SetWidth(futureWidth)
    
    row.buffBar:ClearAllPoints()
    row.buffBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBar:SetSize(futureWidth, row:GetHeight())
    
    row.buffBarOverlay:ClearAllPoints()
    row.buffBarOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarOverlay:SetSize(futureWidth, row:GetHeight())
    
    row.gcdBar:ClearAllPoints()
    row.gcdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.gcdBar:SetSize(futureWidth, row:GetHeight())
    
    -- GCD spark
    row.gcdSpark:ClearAllPoints()
    row.gcdSpark:SetPoint("LEFT", row, "LEFT", nowOffset, 0)
    
    -- Now line texture
    if row.nowLine then
        row.nowLine:ClearAllPoints()
        row.nowLine:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx - (CONFIG.nowLineWidth / 2), 0)
        row.nowLine:SetSize(CONFIG.nowLineWidth, row:GetHeight())
        row.nowLine:SetColorTexture(unpack(CONFIG.nowLineColor))
        row.nowLine:Show()
    end
    
    -- Past clip frames
    local pastWidth = GetPastWidth()
    local pastClips = {row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastCastClip}
    for _, clip in ipairs(pastClips) do
        if clip then
            clip:ClearAllPoints()
            clip:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
            clip:SetSize(pastWidth, row:GetHeight())
        end
    end

    row.cdBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    if row.castTex then row.castTex:SetVertexColor(unpack(CONFIG.castColor)) end
    row.gcdBar:SetStatusBarColor(unpack(CONFIG.gcdColor))
    row.gcdSpark:SetColorTexture(unpack(CONFIG.gcdSparkColor))
    row.gcdSpark:SetSize(CONFIG.gcdSparkWidth or 3, row:GetHeight())

    if row.barTextOverlay then
        row.barTextOverlay:ClearAllPoints()
        row.barTextOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
        row.barTextOverlay:SetSize(CONFIG.width, row:GetHeight())
    end
end

local function ApplyBuffLayer(row)
    local baseLevel = row:GetFrameLevel()
    if CONFIG.buffLayerAbove then
        -- Buff above cooldown
        row.cdBar:SetFrameLevel(baseLevel + 1)
        row.buffBar:SetFrameLevel(baseLevel + 3)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 4)
        row.castFrame:SetFrameLevel(baseLevel + 5)
        row.gcdBar:SetFrameLevel(baseLevel + 6)
    else
        -- Buff below cooldown
        row.buffBar:SetFrameLevel(baseLevel + 1)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 2)
        row.cdBar:SetFrameLevel(baseLevel + 3)
        row.castFrame:SetFrameLevel(baseLevel + 5)
        row.gcdBar:SetFrameLevel(baseLevel + 6)
    end
    -- Charge wrappers + indicator match cdBar level
    local cdLevel = row.cdBar:GetFrameLevel()
    if row.depletedIndicator then row.depletedIndicator:SetFrameLevel(cdLevel) end
    if row.depletedWrapper then row.depletedWrapper:SetFrameLevel(cdLevel) end
    if row.notDepletedWrapper then row.notDepletedWrapper:SetFrameLevel(cdLevel) end
    -- Past clip frames mirror their future counterparts' frame levels
    if row.pastCdClip then
        row.pastCdClip:SetFrameLevel(cdLevel)
    end
    if row.pastBuffClip then
        row.pastBuffClip:SetFrameLevel(row.buffBar:GetFrameLevel())
    end
    if row.pastOverlayClip then
        row.pastOverlayClip:SetFrameLevel(row.buffBarOverlay:GetFrameLevel())
    end
    if row.pastCastClip then
        row.pastCastClip:SetFrameLevel(row.castFrame:GetFrameLevel())
    end
    -- Now line always on top
    if row.nowLineFrame then
        row.nowLineFrame:SetFrameLevel(baseLevel + 7)
    end
end
ns.ApplyBuffLayer = ApplyBuffLayer

local function ApplyLayoutToAllBars()
    EH_Parent:SetWidth(GetContainerWidth())
    
    ResizeContainer()
    
    local rowWidth = EH_Parent:GetWidth() - CONFIG.paddingLeft - CONFIG.paddingRight
    for _, row in ipairs(cooldownBars) do
        row:SetWidth(rowWidth)
        ApplyIconMode(row)
        ApplyBuffLayer(row)
    end
    
    if not CONFIG.hideIcons then
        UpdateAllIconStates()
    end
    
    CreateTimeLines()
end

local function UpdateAllMinMax()
    for _, row in ipairs(cooldownBars) do
        if row.cdBar then row.cdBar:SetMinMaxValues(0, CONFIG.future) end
        if row.buffBar then row.buffBar:SetMinMaxValues(0, CONFIG.future) end
        if row.buffBarOverlay then row.buffBarOverlay:SetMinMaxValues(0, CONFIG.future) end
        if row.gcdBar then row.gcdBar:SetMinMaxValues(0, CONFIG.future) end
    end
end
ns.UpdateAllMinMax = UpdateAllMinMax

local function CrispBar(bar)
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end

local function CreateStatusBar(parent, maxVal)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    bar:SetMinMaxValues(0, maxVal or CONFIG.future)
    bar:SetOrientation("HORIZONTAL")
    bar:GetStatusBarTexture():SetHorizTile(false)
    bar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(bar)
    return bar
end

local hiddenKeys = {
    cd      = { frame = "hidden_cd",      ptr = "lastPtr_cd" },
    charge  = { frame = "hidden_charge",  ptr = "lastPtr_charge" },
    buff    = { frame = "hidden_buff",    ptr = "lastPtr_buff" },
    overlay = { frame = "hidden_overlay", ptr = "lastPtr_overlay" },
}

local function CreateHiddenCooldown(rowRef, timerType)
    local cd = CreateFrame("Cooldown", nil, hiddenCDParent, "CooldownFrameTemplate")
    cd:SetAllPoints(hiddenCDParent)
    cd:SetDrawSwipe(false)
    cd:SetDrawBling(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(true)
    cd:Show()

    cd:SetScript("OnCooldownDone", function(self)
        if timerType == "cd" then
            if rowRef.isChargeSpell then
                -- Charge past slides detach via texture checks in the per-frame loop.
                UpdateChargeState(rowRef)
                UpdateDesaturation(rowRef)
            else
                if rowRef.activeCdSlide then
                    DetachPastSlide(rowRef.activeCdSlide)
                    rowRef.activeCdSlide = nil
                end
                rowRef.activeCooldown = nil
                rowRef.cdBar:Hide()
                if rowRef.cooldownFrame then rowRef.cooldownFrame:Hide() end
                UpdateDesaturation(rowRef)
            end
        elseif timerType == "charge" then
            rowRef.chargesAvailable = math.min((rowRef.chargesAvailable or 0) + 1, rowRef.maxCharges or 2)
            UpdateChargeState(rowRef)
            UpdateDesaturation(rowRef)
        elseif timerType == "buff" then
            if rowRef.activeBuffSlide then
                DetachPastSlide(rowRef.activeBuffSlide)
                rowRef.activeBuffSlide = nil
            end
            rowRef.activeBuffDuration = nil
            rowRef.buffBar:Hide()
        elseif timerType == "overlay" then
            if rowRef.activeOverlaySlide then
                DetachPastSlide(rowRef.activeOverlaySlide)
                rowRef.activeOverlaySlide = nil
            end
            rowRef.activeBuffOverlayDuration = nil
            if rowRef.buffBarOverlay then rowRef.buffBarOverlay:Hide() end
        end
    end)

    return cd
end

local function FeedHiddenCooldown(rowRef, timerType, durObj)
    local keys = hiddenKeys[timerType]
    if not keys then return end
    local cd = rowRef[keys.frame]
    if not cd then return end
    local oldPtr = rowRef[keys.ptr]
    if durObj == oldPtr then return end
    rowRef[keys.ptr] = durObj

    if durObj then
        pcall(cd.SetCooldownFromDurationObject, cd, durObj, true)
    else
        cd:SetCooldown(0, 0)
    end
end

-- Event-driven hidden frame feeding for charge spells.
FeedChargeHiddenFrames = function(row)
    if not row.isChargeSpell then return end
    local ok, chargeDurObj = pcall(C_Spell.GetSpellChargeDuration, row.spellID)
    if not ok then chargeDurObj = nil end

    if chargeDurObj then FeedHiddenCooldown(row, "charge", chargeDurObj)
    else FeedHiddenCooldown(row, "charge", nil) end
end

local function CreateCooldownBar(spellID, index)
    local barOffset = GetBarOffset()
    
    local row = CreateFrame("Frame", nil, EH_Parent)
    row:SetSize(EH_Parent:GetWidth() - CONFIG.paddingLeft - CONFIG.paddingRight, CONFIG.height)
    row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((index - 1) * (CONFIG.height + CONFIG.spacing)))
    row:SetClipsChildren(true)
    
    row.iconContainer = CreateFrame("Frame", nil, row)
    if CONFIG.hideIcons then
        row.iconContainer:SetSize(ICON_HIDDEN_WIDTH, CONFIG.height)
    else
        row.iconContainer:SetSize(CONFIG.iconSize, CONFIG.iconSize)
    end
    row.iconContainer:SetPoint("LEFT", row, "LEFT", 0, 0)
    
    row.icon = row.iconContainer:CreateTexture(nil, "OVERLAY")
    row.icon:SetAllPoints(row.iconContainer)
    
    -- Inner glow for procs (anchored to visible icon rectangle)
    row.innerGlow = row.iconContainer:CreateTexture(nil, "OVERLAY")
    row.innerGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.innerGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
    row.innerGlow:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    row.innerGlow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    row.innerGlow:SetBlendMode("ADD")
    row.innerGlow:SetVertexColor(1, 1, 0.5, 0)

    row.innerGlowAnim = row.innerGlow:CreateAnimationGroup()
    row.innerGlowAnim:SetLooping("BOUNCE")

    local fadeIn = row.innerGlowAnim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(0.8)
    fadeIn:SetDuration(0.6)
    fadeIn:SetSmoothing("IN_OUT")

    local fadeOut = row.innerGlowAnim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(0.8)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.6)
    fadeOut:SetSmoothing("IN_OUT")
    fadeOut:SetStartDelay(0.6)
    
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if spellInfo then
        row.icon:SetTexture(spellInfo.iconID)
        row.spellName = spellInfo.name
    else
        row.icon:SetColorTexture(0.5, 0.5, 0.5, 1)
        row.spellName = "Unknown"
    end
    
    row.iconBorder = row.iconContainer:CreateTexture(nil, "BORDER")
    row.iconBorder:SetSize(CONFIG.iconSize + 2, CONFIG.iconSize + 2)
    row.iconBorder:SetPoint("CENTER", row.iconContainer, "CENTER")
    row.iconBorder:SetColorTexture(0, 0, 0, 1)
    
    row.iconGlow = row.iconContainer:CreateTexture(nil, "OVERLAY", nil, 2)
    row.iconGlow:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.iconGlow:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", CONFIG.iconSize, 0)
    row.iconGlow:SetColorTexture(1, 0.95, 0.3, 0.4)
    row.iconGlow:SetBlendMode("ADD")
    row.iconGlow:Hide()
    
    row.glowAnim = row.iconGlow:CreateAnimationGroup()
    row.glowAnim:SetLooping("BOUNCE")
    local pulse = row.glowAnim:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.3)
    pulse:SetToAlpha(0.7)
    pulse:SetDuration(0.6)
    pulse:SetSmoothing("IN_OUT")
    
    -- Parented to EH_Parent so text isn't clipped by row:SetClipsChildren
    row.textOverlay = CreateFrame("Frame", nil, EH_Parent)
    row.textOverlay:SetAllPoints(row.iconContainer)
    row.textOverlay:SetFrameLevel(row.iconContainer:GetFrameLevel() + 10)
    
    row.chargeText = row.textOverlay:CreateFontString(nil, "OVERLAY")
    row.chargeText:SetPoint(CONFIG.chargeTextAnchor, row.textOverlay, CONFIG.chargeTextRelPoint, CONFIG.chargeTextOffsetX, CONFIG.chargeTextOffsetY)
    ApplyFont(row.chargeText, CONFIG.fontSize)
    row.chargeText:SetTextColor(unpack(CONFIG.chargeTextColor))
    row.chargeText:Hide()

    row.stackText = row.textOverlay:CreateFontString(nil, "OVERLAY")
    row.stackText:SetPoint(CONFIG.stackTextAnchor, row.textOverlay, CONFIG.stackTextRelPoint, CONFIG.stackTextOffsetX, CONFIG.stackTextOffsetY)
    ApplyFont(row.stackText, CONFIG.fontSize)
    row.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
    row.stackText:Hide()

    -- Variant name text, shown on the bar area (right of icon, vertically centred)
    row.barTextOverlay = CreateFrame("Frame", nil, EH_Parent)
    row.barTextOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
    row.barTextOverlay:SetSize(CONFIG.width, CONFIG.height)
    row.barTextOverlay:SetFrameLevel(row.iconContainer:GetFrameLevel() + 11)

    row.variantNameText = row.barTextOverlay:CreateFontString(nil, "OVERLAY")
    row.variantNameText:SetPoint(CONFIG.variantTextAnchor, row.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
    ApplyFont(row.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
    row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
    row.variantNameText:Hide()

    -- Cooldown bar (top half for charge spells, full height otherwise).
    local nowPx = GetNowPixelOffset()
    local futureWidth = GetFutureWidth()
    local nowOffset = barOffset + nowPx
    
    row.cdBar = CreateStatusBar(row)
    row.cdBar:SetSize(futureWidth, CONFIG.height)
    row.cdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.cdBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    row.cdBar:SetFrameLevel(row:GetFrameLevel() + 1)
    
    row.cdBar:Hide()
    row.cdBar.fullHeight = CONFIG.height
    row.cdBar.laneHeight = (CONFIG.height - 1) / 2
    
    -- Past clip frames, one per lane, matching future counterpart frame levels.
    local baseLevel = row:GetFrameLevel()
    
    local function CreatePastClip(level)
        local clip = CreateFrame("Frame", nil, row)
        clip:SetClipsChildren(true)
        clip:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset, 0)
        clip:SetSize(nowPx, CONFIG.height)
        clip:SetFrameLevel(level)
        clip:Show()
        return clip
    end
    
    row.pastCdClip = CreatePastClip(baseLevel + 1)       -- matches cdBar initial level
    row.pastBuffClip = CreatePastClip(baseLevel + 3)      -- matches buffBar initial level
    row.pastOverlayClip = CreatePastClip(baseLevel + 4)   -- matches buffBarOverlay initial level
    row.pastCastClip = CreatePastClip(baseLevel + 5)
    
    -- Sliding past markers
    row.pastSlides = {}

    row.hidden_cd = CreateHiddenCooldown(row, "cd")
    row.hidden_charge = CreateHiddenCooldown(row, "charge")
    row.hidden_buff = CreateHiddenCooldown(row, "buff")
    row.hidden_overlay = CreateHiddenCooldown(row, "overlay")

    row.lastPtr_cd = nil
    row.lastPtr_charge = nil
    row.lastPtr_buff = nil
    row.lastPtr_overlay = nil
    row.wasOnGCD = false

    -- Cast bar texture (not StatusBar, so it can straddle the now line).
    row.castFrame = CreateFrame("Frame", nil, row)
    row.castFrame:SetAllPoints(row)
    row.castFrame:SetFrameLevel(row:GetFrameLevel() + 5)
    
    row.castTex = row.castFrame:CreateTexture(nil, "ARTWORK")
    row.castTex:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.castTex:SetVertexColor(unpack(CONFIG.castColor))
    row.castTex:SetSnapToPixelGrid(false)
    row.castTex:SetTexelSnappingBias(0)
    row.castTex:Hide()
    

    
    -- Buff bar (primary)
    row.buffBar = CreateStatusBar(row)
    row.buffBar:SetSize(futureWidth, CONFIG.height)
    row.buffBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBar:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBar:SetFrameLevel(row:GetFrameLevel() + 3)
    row.buffBar:Hide()
    
    -- Pandemic pulse animation
    row.buffPandemicAnim = row.buffBar:CreateAnimationGroup()
    row.buffPandemicAnim:SetLooping("BOUNCE")
    
    local pandemicFade = row.buffPandemicAnim:CreateAnimation("Alpha")
    pandemicFade:SetFromAlpha(1.0)
    pandemicFade:SetToAlpha(0.5)
    pandemicFade:SetDuration(0.5)
    pandemicFade:SetSmoothing("IN_OUT")
    
    -- Buff overlay bar
    row.buffBarOverlay = CreateStatusBar(row)
    row.buffBarOverlay:SetSize(futureWidth, CONFIG.height)
    row.buffBarOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarOverlay:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBarOverlay:SetFrameLevel(row:GetFrameLevel() + 4)
    row.buffBarOverlay:Hide()
    
    -- Cooldown swirl (plain "Cooldown", not CooldownFrameTemplate which taints).
    row.cooldownFrame = CreateFrame("Cooldown", nil, row.iconContainer)
    row.cooldownFrame:SetAllPoints(row.iconContainer)
    row.cooldownFrame:SetDrawEdge(false) 
    row.cooldownFrame:SetDrawSwipe(true)
    row.cooldownFrame:SetSwipeColor(0, 0, 0, 0.6) 
    row.cooldownFrame:SetReverse(false)
    row.cooldownFrame:SetHideCountdownNumbers(true)
    
    if row.cooldownFrame.SetUseCircularEdge then
        row.cooldownFrame:SetUseCircularEdge(true)
    end
    
    row.cooldownFrame:Hide()
    
    -- GCD overlay
    row.gcdBar = CreateStatusBar(row)
    row.gcdBar:SetSize(futureWidth, CONFIG.height)
    row.gcdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.gcdBar:SetStatusBarColor(unpack(CONFIG.gcdColor))
    row.gcdBar:SetFrameLevel(row:GetFrameLevel() + 6)
    row.gcdBar:Hide()
    
    -- GCD spark
    row.gcdSpark = row.gcdBar:CreateTexture(nil, "OVERLAY", nil, 5)
    row.gcdSpark:SetSize(CONFIG.gcdSparkWidth or 3, CONFIG.height)
    row.gcdSpark:SetColorTexture(unpack(CONFIG.gcdSparkColor))
    row.gcdSpark:SetPoint("LEFT", row, "LEFT", nowOffset, 0)
    row.gcdSpark:Hide()
    
    -- Now line, on its own frame so it draws above all bars.
    row.nowLineFrame = CreateFrame("Frame", nil, row)
    row.nowLineFrame:SetFrameLevel(row:GetFrameLevel() + 7)
    row.nowLineFrame:SetAllPoints(row)
    row.nowLine = row.nowLineFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    row.nowLine:SetSize(CONFIG.nowLineWidth, CONFIG.height)
    row.nowLine:SetPoint("TOPLEFT", row, "TOPLEFT", barOffset + nowPx - (CONFIG.nowLineWidth / 2), 0)
    row.nowLine:SetColorTexture(unpack(CONFIG.nowLineColor))
    row.nowLine:Show()
    
    row:Show()
    
    ApplyIconMode(row)
    ApplyBuffLayer(row)
    
    if not CONFIG.hideIcons then
        UpdateIconState(row)
    end
    
    return row
end

ResizeContainer = function()
    local numBars = #cooldownBars
    if numBars == 0 then
        EH_Parent:SetHeight(CONFIG.paddingTop + CONFIG.paddingBottom)
        return
    end

    local useStatic = type(CONFIG.staticHeight) == "number" and numBars >= (CONFIG.staticFrames or 0)
    local barHeight

    if useStatic then
        EH_Parent:SetHeight(CONFIG.staticHeight)
        local availableHeight = CONFIG.staticHeight - CONFIG.paddingTop - CONFIG.paddingBottom
        barHeight = (availableHeight - (CONFIG.spacing * (numBars - 1))) / numBars
        barHeight = math.max(barHeight, 4)
    else
        barHeight = CONFIG.height
    end

    for i, row in ipairs(cooldownBars) do
        row:SetHeight(barHeight)
        row.cdBar.fullHeight = barHeight
        local maxC = row.maxCharges or 2
        row.cdBar.laneHeight = (barHeight - (maxC - 1)) / maxC

        if row.isChargeSpell then
            local lH = row.cdBar.laneHeight
            local bottomY = -(barHeight - lH)
            row.cdBar:SetHeight(lH)
            if row.depletedWrapper then
                row.depletedWrapper:SetHeight(barHeight)
                row.notDepletedWrapper:SetHeight(barHeight)
                row.depletedCdBar:SetHeight(lH)
                row.depletedHelperBar:SetHeight(lH)
                row.depletedHelperBar:ClearAllPoints()
                row.depletedHelperBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", 0, bottomY)
                row.depletedChargeBar:SetHeight(lH)
                row.depletedChargeBar:ClearAllPoints()
                local slotPx = row._chargeSlotPx or 0
                row.depletedChargeBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", (maxC - 1) * slotPx, bottomY)
                row.normalChargeBar:SetHeight(lH)
                row.normalChargeBar:ClearAllPoints()
                row.normalChargeBar:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", 0, bottomY)
                row._lastNdHelperPx = nil
                if row.notDepletedHelperBar then
                    row.notDepletedHelperBar:SetHeight(lH)
                    row.notDepletedHelperBar:ClearAllPoints()
                    row.notDepletedHelperBar:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", 0, bottomY)
                end
            end
            if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
                local slotPx = row._chargeSlotPx or 0
                for j = 1, row.maxCharges - 2 do
                    local ml = row.middleLanes[j]
                    if ml then
                        local laneY = -(j * (lH + 1))
                        ml.depletedHelperBar:SetSize(math.max(1, j * slotPx), lH)
                        ml.depletedHelperBar:ClearAllPoints()
                        ml.depletedHelperBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", 0, laneY)
                        ml.depletedChargeBar:SetHeight(lH)
                        ml.depletedChargeBar:ClearAllPoints()
                        ml.depletedChargeBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", j * slotPx, laneY)
                        ml._lastChargeOffset = nil
                    end
                end
            end
        else
            row.cdBar:SetHeight(barHeight)
        end
        row.castFrame:SetHeight(barHeight)
        row.buffBar:SetHeight(barHeight)
        row.buffBarOverlay:SetHeight(barHeight)
        row.gcdBar:SetHeight(barHeight)
        row.gcdSpark:SetHeight(barHeight)
        if row.nowLine then
            row.nowLine:SetHeight(barHeight)
        end
        for _, clip in ipairs({row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastCastClip}) do
            if clip then clip:SetHeight(barHeight) end
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((i - 1) * (barHeight + CONFIG.spacing)))
    end

    if not useStatic then
        local contentHeight = (numBars * barHeight) + ((numBars - 1) * CONFIG.spacing)
        local totalHeight = CONFIG.paddingTop + contentHeight + CONFIG.paddingBottom
        EH_Parent:SetHeight(totalHeight)
    end
end

local linesOverlay = CreateFrame("Frame", nil, EH_Parent)
linesOverlay:SetAllPoints(EH_Parent)
linesOverlay:SetFrameLevel(EH_Parent:GetFrameLevel() + 50) -- above everything
local frameTimeLines = {}

CreateTimeLines = function()
    local lineDef = CONFIG.lines
    if not lineDef then
        for _, line in ipairs(frameTimeLines) do
            line:Hide()
        end
        return
    end
    
    -- Normalize to table
    if type(lineDef) == "number" then lineDef = {lineDef} end
    if type(lineDef) ~= "table" then return end
    
    local colorDef = CONFIG.linesColor or {1, 1, 1, 0.3}
    local multiColor = type(colorDef[1]) == "table"
    local barOffset = GetBarOffset()
    
    for i, seconds in ipairs(lineDef) do
        if seconds > 0 and seconds <= CONFIG.future then
            local line = frameTimeLines[i]
            if not line then
                line = linesOverlay:CreateTexture(nil, "OVERLAY")
                line:SetWidth(1)
                frameTimeLines[i] = line
            end
            
            local color
            if multiColor then
                color = colorDef[i] or colorDef[#colorDef]
            else
                color = colorDef
            end
            line:SetColorTexture(unpack(color))
            
            -- Use timeline coordinate system: seconds is a future offset
            local xOffset = CONFIG.paddingLeft + barOffset + TimeToPixel(seconds)
            line:ClearAllPoints()
            line:SetPoint("TOP", linesOverlay, "TOPLEFT", xOffset, 0)
            line:SetPoint("BOTTOM", linesOverlay, "BOTTOMLEFT", xOffset, 0)
            line:Show()
        elseif frameTimeLines[i] then
            frameTimeLines[i]:Hide()
        end
    end
    
    for i = (type(lineDef) == "table" and #lineDef or 1) + 1, #frameTimeLines do
        frameTimeLines[i]:Hide()
    end
end

local LoadEssentialCooldowns

local function SmartReorder()
    local newOrderCooldownIDs = {}
    
    if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
        local dataProvider = CooldownViewerSettings:GetDataProvider()
        if dataProvider and dataProvider.GetOrderedCooldownIDsForCategory then
            local displayedCooldownIDs = dataProvider:GetOrderedCooldownIDsForCategory(0)
            if displayedCooldownIDs then
                for _, cdID in ipairs(displayedCooldownIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if infoOk and info and info.spellID then
                        table.insert(newOrderCooldownIDs, cdID)
                    end
                end
            end
        end
    end
    
    if #newOrderCooldownIDs == 0 then return end
    
    local barsByCooldownID = {}
    for _, bar in ipairs(cooldownBars) do
        if bar.cooldownID then
            barsByCooldownID[bar.cooldownID] = bar
        end
    end
    
    -- If any cooldownID has no existing bar, full reload needed
    local needsReload = (#newOrderCooldownIDs ~= #cooldownBars)
    if not needsReload then
        for _, cdID in ipairs(newOrderCooldownIDs) do
            if not barsByCooldownID[cdID] then
                needsReload = true
                break
            end
        end
    end
    
    if needsReload then
        LoadEssentialCooldowns()
        return
    end
    
    -- Pure reorder
    for _, bar in ipairs(cooldownBars) do bar:Hide() end
    wipe(cooldownBars)
    
    for i, cdID in ipairs(newOrderCooldownIDs) do
        local bar = barsByCooldownID[cdID]
        
        if bar then
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((i - 1) * (CONFIG.height + CONFIG.spacing)))
            bar:Show()
            table.insert(cooldownBars, bar)
        end
    end
    
    ResizeContainer()
end

-- Pool enumeration works even if other addons reparent frames
local function ScanViewer(viewerName)
    local viewer = _G[viewerName]
    if not viewer then return nil end
    
    -- Prefer pool enumeration
    if viewer.itemFramePool then
        local ok, iter, pool, first = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
        if ok and iter then
            return iter, pool, first
        end
    end
    
    -- Fallback to GetChildren()
    local success, children = pcall(function() return {viewer:GetChildren()} end)
    if success and children then
        local i = 0
        return function()
            i = i + 1
            return children[i]
        end
    end
    
    return nil
end

-- Cached tables reused by ScanViewerFrames to avoid per-call allocation
local cachedCooldownViewerFrames = {}
local cachedBuffViewerFrames = {}
local cooldownViewerNames = {"EssentialCooldownViewer", "UtilityCooldownViewer"}
local buffViewerNames = {"BuffIconCooldownViewer", "BuffBarCooldownViewer"}

ScanViewerFrames = function()
    wipe(cachedCooldownViewerFrames)
    wipe(cachedBuffViewerFrames)

    for _, viewerName in ipairs(cooldownViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for frame in iter, pool, first do
                local ok, cdID = pcall(function() return frame:GetObjectType() and frame.cooldownID end)
                if ok and cdID then
                    cachedCooldownViewerFrames[cdID] = frame
                    -- Category 0 hasAura: make active auras available for buff tracking
                    local aOk, aID = pcall(function() return frame.auraInstanceID end)
                    if aOk and aID then
                        cachedBuffViewerFrames[cdID] = frame
                    end
                end
            end
        end
    end

    -- Buff viewers scanned second; overwrites Category 0 fallback entries above
    for _, viewerName in ipairs(buffViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for frame in iter, pool, first do
                local ok, cdID = pcall(function() return frame:GetObjectType() and frame.cooldownID end)
                if ok and cdID then
                    cachedBuffViewerFrames[cdID] = frame
                end
            end
        end
    end

    return cachedCooldownViewerFrames, cachedBuffViewerFrames
end

local function MirrorECMState(row, cooldownViewerFrames)
    if not row.cooldownID then
        row.chargeText:Hide()
        return
    end
    
    local ecmFrame = cooldownViewerFrames[row.cooldownID]
    if not ecmFrame then
        row.chargeText:Hide()
        return
    end
    
    -- Resolve current spellID via GetOverrideSpell (never secret).
    if row.baseSpellID then
        local overrideOk, overrideID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
        if overrideOk and overrideID and overrideID ~= row.spellID then
            row.spellID = overrideID
            -- SpellID changed; re-check glow for the new identity
            if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
                local gOk, isOverlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, overrideID)
                if gOk then HandleProcGlow(row, isOverlayed) end
            end
        end
    end

    -- Mirror ECM icon texture
    if not CONFIG.hideIcons then
        local texOk, tex = pcall(function()
            return ecmFrame.Icon and ecmFrame.Icon:GetTexture()
        end)
        if texOk and tex then
            row.icon:SetTexture(tex)
        end
    end
    
    -- Charge text (secret passthrough via SetText)
    if row.hasCharges then
        local chargeOk, chargeCount = pcall(function() return ecmFrame.cooldownChargesCount end)
        if chargeOk and chargeCount then
            row.chargeText:SetText(chargeCount)
            row.chargeText:Show()
        else
            row.chargeText:Hide()
        end
    else
        row.chargeText:Hide()
    end
end

local function UpdateRowCooldown(row)
    if row.isChargeSpell then return end
    
    local successCD, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID)
    
    -- isOnGCD is NeverSecret. When true, only the GCD is active.
    local cdInfoSuccess, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
    local isOnGCD = cdInfoSuccess and cdInfo and cdInfo.isOnGCD

    -- On GCD falling edge, clear hidden frame and skip this feed.
    -- Prevents stale GCD-length DurObj from creating a false past slide.
    local gcdJustEnded = row.wasOnGCD and not isOnGCD
    row.wasOnGCD = isOnGCD or false
    if gcdJustEnded and row.hidden_cd then
        row.hidden_cd:SetCooldown(0, 0)
        row.lastPtr_cd = nil
    end

    if successCD and cdDurObj and not isOnGCD and not gcdJustEnded then
        row.activeCooldown = cdDurObj
        if not row.cdBar:IsShown() then row.cdBar:Show() end

        FeedHiddenCooldown(row, "cd", cdDurObj)

        if CONFIG.reactiveIcons and not CONFIG.hideIcons and row.cooldownFrame and cdDurObj ~= row.lastCdDurObj then
            pcall(row.cooldownFrame.SetCooldownFromDurationObject, row.cooldownFrame, cdDurObj, false)
            row.cooldownFrame:Show()
            row.lastCdDurObj = cdDurObj
        end
    else
        row.activeCooldown = nil
        row.cdBar:Hide()
        row.lastCdDurObj = nil
        if row.cooldownFrame then row.cooldownFrame:Hide() end
        -- Clear stale hidden_cd timer: handles proc resets mid-GCD (IE Black Arrow)
        -- AND spell transforms mid-cooldown (old spell timer would persist as ghost past slide)
        if row.hidden_cd and row.hidden_cd:IsShown() then
            row.hidden_cd:SetCooldown(0, 0)
            row.lastPtr_cd = nil
        end
    end
end

-- Bar display is curve-driven in OnUpdate via wrapper frame alpha.
UpdateChargeState = function(row)
    if not row.isChargeSpell then
        return
    end

    -- Clear so the OnUpdate fill code does not animate hidden bars.
    row.activeCooldown = nil

    -- Icon cooldown swirl
    local cdOk, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID)
    local chargeOk, chargeDurObj = pcall(C_Spell.GetSpellChargeDuration, row.spellID)

    local cdInfoOk, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
    local isOnGCD = cdInfoOk and cdInfo and cdInfo.isOnGCD
    if isOnGCD then cdDurObj = nil end

    local feedDurObj = cdDurObj or chargeDurObj
    if feedDurObj and CONFIG.reactiveIcons and not CONFIG.hideIcons and row.cooldownFrame then
        if feedDurObj ~= row.lastChargeDurObj then
            pcall(row.cooldownFrame.SetCooldownFromDurationObject, row.cooldownFrame, feedDurObj, false)
            row.cooldownFrame:Show()
            row.lastChargeDurObj = feedDurObj
        end
    elseif not feedDurObj and row.cooldownFrame then
        row.cooldownFrame:Hide()
        row.lastChargeDurObj = nil
    end
end

local function DetectPermanentBuff(unit, auraInstanceID, cdID)
    if not auraInstanceID then return false end
    local aOk, aData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
    if aOk and aData then
        if issecretvalue(aData.duration) then
            if cdID and permanentBuffCdIDs[cdID] then return true end
        elseif aData.duration == 0 then
            if cdID then permanentBuffCdIDs[cdID] = true end
            return true
        end
    end
    return false
end

local function ResolveBuffColor(buffEntry)
    if buffEntry.hasCustomColor then
        return buffEntry.color
    elseif buffEntry.unit == "target" then
        return CONFIG.debuffColor
    elseif buffEntry.unit == "pet" then
        return CONFIG.petBuffColor
    else
        return buffEntry.color or CONFIG.buffColor
    end
end

local function GetAuraDurationWithRetry(unit, auraInstanceID, cdmUnit)
    local durSuccess, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, auraInstanceID)
    if not durSuccess or not durObj then
        if cdmUnit and cdmUnit ~= unit then
            local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, cdmUnit, auraInstanceID)
            if rOk and rDur then return true, rDur, cdmUnit end
        end
        local opposite = (unit == "target") and "player" or "target"
        local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, opposite, auraInstanceID)
        if rOk and rDur then return true, rDur, opposite end
        return false, nil, unit
    end
    return durSuccess, durObj, unit
end

UpdateBuffState = function(row, buffViewerFrames)
    -- Each mapping entry owns a fixed lane: [1] = primary, [2] = overlay.
    local primaryBuff = nil
    local overlayBuff = nil
    
    if row.cooldownID then
        -- Self match: buff cooldownID == ability cooldownID
        local selfFrame = buffViewerFrames[row.cooldownID]
        if selfFrame and selfFrame.auraInstanceID then
            primaryBuff = {
                frame = selfFrame,
                color = CONFIG.buffColor,
                hasCustomColor = false,
                unit = selfFrame.auraDataUnit or "player"
            }
        end

        -- Mapping matches: direct lookup by each buffCooldownID
        local mappings = CONFIG.buffMappings and (CONFIG.buffMappings[row.cooldownID] or CONFIG.buffMappings[row.baseSpellID] or CONFIG.buffMappings[row.spellID])
        if mappings then
            for mapIdx, mapData in ipairs(mappings) do
                if mapData.buffCooldownIDs then
                    for _, mappedID in ipairs(mapData.buffCooldownIDs) do
                        local buffFrame = buffViewerFrames[mappedID]
                        if buffFrame and buffFrame.auraInstanceID then
                            local unitHint = mapData.unit or buffFrame.auraDataUnit or "player"
                            local matchedColor = mapData.color or CONFIG.buffColor
                            local hasCustomColor = mapData.color ~= nil
                            local secretAuraSpellId = nil
                            if mapData.spellColorMap and buffFrame.auraInstanceID then
                                local aOk, aData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, buffFrame.auraDataUnit or unitHint, buffFrame.auraInstanceID)
                                if aOk and aData then
                                    secretAuraSpellId = aData.spellId
                                    local sOk, sColor = pcall(function()
                                        if aData.spellId and mapData.spellColorMap[aData.spellId] then
                                            return mapData.spellColorMap[aData.spellId]
                                        end
                                    end)
                                    if sOk and sColor then
                                        matchedColor = sColor
                                        hasCustomColor = true
                                    end
                                end
                            end
                            local entry = {
                                frame = buffFrame,
                                color = matchedColor,
                                hasCustomColor = hasCustomColor,
                                unit = unitHint,
                                secretAuraSpellId = secretAuraSpellId
                            }
                            if mapIdx == 1 then
                                primaryBuff = entry
                            elseif mapIdx == 2 and not overlayBuff then
                                overlayBuff = entry
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    
    -- Primary lane → buffBar
    if primaryBuff then
        local isPermanent = DetectPermanentBuff(primaryBuff.unit, primaryBuff.frame.auraInstanceID, primaryBuff.frame.cooldownID)
        local resolvedColor = ResolveBuffColor(primaryBuff)
        row.resolvedBuffColor = resolvedColor
        row.buffBar:SetStatusBarColor(unpack(resolvedColor))

        if isPermanent then
            -- Permanent buff — show as full bar, no animation
            row.activeBuffDuration = nil
            row.cachedPandemicIcon = nil
            if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                row.buffPandemicAnim:Stop()
                row.buffBar:SetAlpha(1.0)
            end
            row.buffBar:SetValue(CONFIG.future)
            row.buffBar:Show()
            row.trackedBuffAuraInstanceID = primaryBuff.frame.auraInstanceID
            row.secretAuraSpellId = primaryBuff.secretAuraSpellId
            FeedHiddenCooldown(row, "buff", nil)

            -- Spawn past slide on first detection
            if not row.permanentBuffSlide or not row.permanentBuffSlide.active then
                row.permanentBuffSlide = SpawnPastSlide(row, row.pastBuffClip, row.resolvedBuffColor or CONFIG.buffColor)
            end
        else
            local durSuccess, durObj, resolvedUnit = GetAuraDurationWithRetry(primaryBuff.unit, primaryBuff.frame.auraInstanceID, primaryBuff.frame.auraDataUnit)
            if resolvedUnit and resolvedUnit ~= primaryBuff.unit then primaryBuff.unit = resolvedUnit end
            if durSuccess and durObj then
                row.activeBuffDuration = durObj

                if primaryBuff.unit == "target" and CONFIG.pandemicPulse then
                    row.cachedPandemicIcon = primaryBuff.frame.PandemicIcon
                else
                    row.cachedPandemicIcon = nil
                end
                if not row.cachedPandemicIcon and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                    row.buffBar:SetAlpha(1.0)
                end

                row.buffBar:Show()
                FeedHiddenCooldown(row, "buff", durObj)
                row.trackedBuffAuraInstanceID = primaryBuff.frame.auraInstanceID
                row.secretAuraSpellId = primaryBuff.secretAuraSpellId
            else
                row.buffBar:Hide()
                if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                end
                row.activeBuffDuration = nil
                row.resolvedBuffColor = nil
                row.cachedPandemicIcon = nil
                row.trackedBuffAuraInstanceID = nil
                row.secretAuraSpellId = nil
                FeedHiddenCooldown(row, "buff", nil)
            end
        end
    else
        row.buffBar:Hide()
        if row.buffPandemicAnim:IsPlaying() then
            row.buffPandemicAnim:Stop()
        end
        row.activeBuffDuration = nil
        row.resolvedBuffColor = nil
        row.cachedPandemicIcon = nil
        row.trackedBuffAuraInstanceID = nil
        row.secretAuraSpellId = nil
        FeedHiddenCooldown(row, "buff", nil)

        -- Detach permanent buff past slide when buff drops
        if row.permanentBuffSlide and row.permanentBuffSlide.active then
            DetachPastSlide(row.permanentBuffSlide)
            row.permanentBuffSlide = nil
        end
    end

    -- Overlay lane → buffBarOverlay
    if overlayBuff and row.buffBarOverlay then
        local isPermanent2 = DetectPermanentBuff(overlayBuff.unit, overlayBuff.frame.auraInstanceID, overlayBuff.frame.cooldownID)
        local resolvedOverlayColor = ResolveBuffColor(overlayBuff)
        row.resolvedOverlayColor = resolvedOverlayColor
        row.buffBarOverlay:SetStatusBarColor(unpack(resolvedOverlayColor))

        if isPermanent2 then
            row.activeBuffOverlayDuration = nil
            row.buffBarOverlay:SetValue(CONFIG.future)
            row.buffBarOverlay:Show()
            row.trackedOverlayAuraInstanceID = overlayBuff.frame.auraInstanceID
            FeedHiddenCooldown(row, "overlay", nil)
        else
            local durSuccess2, durObj2, resolvedUnit2 = GetAuraDurationWithRetry(overlayBuff.unit, overlayBuff.frame.auraInstanceID, overlayBuff.frame.auraDataUnit)
            if resolvedUnit2 and resolvedUnit2 ~= overlayBuff.unit then overlayBuff.unit = resolvedUnit2 end
            if durSuccess2 and durObj2 then
                row.activeBuffOverlayDuration = durObj2
                FeedHiddenCooldown(row, "overlay", durObj2)
                row.trackedOverlayAuraInstanceID = overlayBuff.frame.auraInstanceID
                row.buffBarOverlay:Show()
            else
                row.buffBarOverlay:Hide()
                row.activeBuffOverlayDuration = nil
                row.resolvedOverlayColor = nil
                row.trackedOverlayAuraInstanceID = nil
                FeedHiddenCooldown(row, "overlay", nil)
            end
        end
    elseif row.buffBarOverlay then
        row.buffBarOverlay:Hide()
        row.activeBuffOverlayDuration = nil
        row.resolvedOverlayColor = nil
        row.trackedOverlayAuraInstanceID = nil
        FeedHiddenCooldown(row, "overlay", nil)
    end
end

UpdateStackText = function(row, buffViewerFrames)
    if not row.stackText then return end

    -- Variant name text (IE Roll the Bones outcome) on the bar area
    local variantShown = false
    if row.variantNameText and CONFIG.showVariantNames then
        local mappings = CONFIG.buffMappings and (CONFIG.buffMappings[row.cooldownID] or CONFIG.buffMappings[row.baseSpellID] or CONFIG.buffMappings[row.spellID])
        local hasVariants = mappings and mappings[1] and mappings[1].spellColorMap
        if hasVariants and row.secretAuraSpellId then
            local name = C_Spell.GetSpellName(row.secretAuraSpellId)
            if name then
                row.variantNameText:SetText(name)
                row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
                row.variantNameText:Show()
                variantShown = true
            end
        end
    end
    if row.variantNameText and not variantShown then
        row.variantNameText:Hide()
    end

    local stackMapping = CONFIG.stackMappings and (CONFIG.stackMappings[row.cooldownID] or CONFIG.stackMappings[row.baseSpellID] or CONFIG.stackMappings[row.spellID])
    if not stackMapping then
        row.stackText:Hide()
        return
    end
    
    local buffFrame = buffViewerFrames[stackMapping.buffCooldownID]
    if buffFrame and buffFrame.auraInstanceID ~= nil then
        local unit = buffFrame.auraDataUnit or stackMapping.unit or "player"

        local ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, buffFrame.auraInstanceID)
        if (not ok or not auraData) and unit ~= "player" then
            ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", buffFrame.auraInstanceID)
        end
        if (not ok or not auraData) and unit ~= "target" then
            ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "target", buffFrame.auraInstanceID)
        end
        if ok and auraData then
            -- applications may be secret, passthrough via SetText
            local appOk, appVal = pcall(function()
                if auraData.applications ~= nil then
                    return auraData.applications
                end
                return nil
            end)
            if appOk and appVal ~= nil then
                row.stackText:SetText(appVal)
                if stackMapping.color then
                    row.stackText:SetTextColor(unpack(stackMapping.color))
                else
                    row.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
                end
                row.stackText:Show()
            else
                row.stackText:Hide()
            end
        else
            row.stackText:Hide()
        end
        return
    end

    row.stackText:Hide()
end

-- SetDesaturation(secretPassthrough)
UpdateDesaturation = function(row)
    if not CONFIG.desaturateOnCooldown then return end
    if CONFIG.hideIcons then return end

    if row.isChargeSpell then
        -- BinaryCurve maps zero-remaining to 0 (not gray), active CD to 1 (gray).
        local ok, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID)
        if ok and cdDurObj and BinaryCurve then
            -- GCD filter
            local infoOk, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
            local isGCD = infoOk and cdInfo and cdInfo.isOnGCD == true
            if isGCD then
                row.icon:SetDesaturation(0)
            else
                local curveOk, result = pcall(cdDurObj.EvaluateRemainingPercent, cdDurObj, BinaryCurve)
                if curveOk and result then
                    row.icon:SetDesaturation(result)
                else
                    row.icon:SetDesaturation(0)
                end
            end
        else
            row.icon:SetDesaturation(0)
        end
        return
    end

    -- Non-charge spells
    if row.activeCooldown and BinaryCurve then
        local ok, result = pcall(row.activeCooldown.EvaluateRemainingPercent, row.activeCooldown, BinaryCurve)
        if ok and result then
            row.icon:SetDesaturation(result)
        else
            row.icon:SetDesaturation(0)
        end
    else
        row.icon:SetDesaturation(0)
    end
end

local lastUpdateBarsTime = 0
local buffViewerWarningShown = false

local function UpdateBars()
    local now = GetTime()
    if now - lastUpdateBarsTime < 0.016 then return end
    lastUpdateBarsTime = now

    local cooldownViewerFrames, buffViewerFrames = ScanViewerFrames()

    -- One-time warning if buff viewers have no frames but mappings exist
    if not buffViewerWarningShown and CONFIG.buffMappings and next(CONFIG.buffMappings) then
        local hasBuff = next(buffViewerFrames) ~= nil
        if not hasBuff and _G["BuffIconCooldownViewer"] then
            buffViewerWarningShown = true
            print("|cff00ff00[Infall]|r Buff tracking requires the Cooldown Manager buff viewer to be visible. Set it to Always in CDM settings, then use /infall ecm to hide it.")
        elseif hasBuff then
            buffViewerWarningShown = true
        end
    end

    for _, row in ipairs(cooldownBars) do
        MirrorECMState(row, cooldownViewerFrames)
        UpdateRowCooldown(row)
        UpdateChargeState(row)
        UpdateBuffState(row, buffViewerFrames)
        UpdateStackText(row, buffViewerFrames)
        UpdateDesaturation(row)
    end
end

local function ScheduleDeferredUpdate(delay)
    deferredGen[delay] = (deferredGen[delay] or 0) + 1
    local myGen = deferredGen[delay]
    C_Timer.After(delay, function()
        if deferredGen[delay] == myGen then
            UpdateBars()
        end
    end)
end

local function UpdateBuffPastSlide(row, hiddenFrame, slideKey, clipKey, colorKey)
    local isActive = hiddenFrame and hiddenFrame:IsShown() or false
    local slide = row[slideKey]
    if isActive and not slide then
        row[slideKey] = SpawnPastSlide(row, row[clipKey], row[colorKey] or CONFIG.buffColor, row.cdBar.fullHeight or CONFIG.height, 0)
    elseif not isActive and slide then
        DetachPastSlide(slide)
        row[slideKey] = nil
    end
    slide = row[slideKey]
    if slide and not slide.detachTime and row[colorKey] then
        local c = row[colorKey]
        slide.color = c
        slide.tex:SetVertexColor(c[1], c[2], c[3], c[4] or 0.7)
    end
end

-- OnUpdate helpers (defined once to avoid per-frame closure allocation)
local function GcdBarAndSpark(durObj, gcdBar, gcdSpark, row, future, interp)
    local remaining = durObj:GetRemainingDuration()
    gcdBar:SetValue(remaining, interp)
    if remaining <= future then
        local sparkPx = TimeToPixel(remaining)
        local sparkXOffset = GetBarOffset() + sparkPx
        gcdSpark:ClearAllPoints()
        gcdSpark:SetPoint("LEFT", row, "LEFT", sparkXOffset, 0)
        gcdSpark:Show()
    else
        gcdSpark:Hide()
    end
end

local updateTimer = 0
local buffPollTimer = 0
EH_Parent:SetScript("OnUpdate", function(self, elapsed)
    updateTimer = updateTimer + elapsed

    -- 10Hz buff data polling: re-reads CDM frames for aura changes (target swap, dot refresh)
    buffPollTimer = buffPollTimer + elapsed
    if buffPollTimer >= 0.1 then
        buffPollTimer = 0
        UpdateBars()
    end

    if updateTimer >= 0.033 then
        local interp = GetInterpolation()

        for _, row in ipairs(cooldownBars) do
            -- Cooldown bar fill
            if row.activeCooldown then
                local ok, remaining = pcall(row.activeCooldown.GetRemainingDuration, row.activeCooldown)
                if ok then
                    row.cdBar:SetValue(remaining, interp)
                elseif not row.isChargeSpell then
                    row.cdBar:Hide()
                end
            end

            -- CD past slide
            if not row.isChargeSpell and row.hidden_cd then
                local cdActive = row.hidden_cd:IsShown()
                if cdActive and not row.activeCdSlide then
                    row.activeCdSlide = SpawnPastSlide(row, row.pastCdClip, CONFIG.cooldownColor, row.cdBar.fullHeight or CONFIG.height, 0)
                elseif not cdActive and row.activeCdSlide then
                    DetachPastSlide(row.activeCdSlide)
                    row.activeCdSlide = nil
                end
            end

            -- Buff bar fill (BuffFillCurve maps 0 remaining to full bar for permanent buffs)
            if row.activeBuffDuration then
                local ok, val
                if BuffFillCurve then
                    ok, val = pcall(row.activeBuffDuration.EvaluateRemainingDuration, row.activeBuffDuration, BuffFillCurve)
                else
                    ok, val = pcall(row.activeBuffDuration.GetRemainingDuration, row.activeBuffDuration)
                end
                if ok then row.buffBar:SetValue(val, interp) else row.buffBar:Hide() end
            end

            -- Buff overlay bar fill
            if row.activeBuffOverlayDuration and row.buffBarOverlay then
                local ok, val
                if BuffFillCurve then
                    ok, val = pcall(row.activeBuffOverlayDuration.EvaluateRemainingDuration, row.activeBuffOverlayDuration, BuffFillCurve)
                else
                    ok, val = pcall(row.activeBuffOverlayDuration.GetRemainingDuration, row.activeBuffOverlayDuration)
                end
                if ok then row.buffBarOverlay:SetValue(val, interp) else row.buffBarOverlay:Hide() end
            end

            -- Charge bar display
            if row.isChargeSpell and row.depletedWrapper then
                -- Resolve current spell transform before API calls
                if row.baseSpellID then
                    local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
                    if ovOk and ovID and ovID ~= 0 then
                        row.spellID = ovID
                    end
                end

                local chargeOk, chargeDurObj = pcall(C_Spell.GetSpellChargeDuration, row.spellID)
                if not chargeOk then chargeDurObj = nil end

                -- Clip boundary indicators
                local chargesOk, chargeInfo = pcall(C_Spell.GetSpellCharges, row.spellID)
                if chargesOk and chargeInfo then
                    row.depletedIndicator:SetValue(chargeInfo.currentCharges)
                    if row.chargeDetectors then
                        for _, det in pairs(row.chargeDetectors) do
                            det:SetValue(chargeInfo.currentCharges)
                        end
                    end
                end

                local isAllCharged = not chargeDurObj
                local indTex = row.depletedIndicator and row.depletedIndicator:GetStatusBarTexture()
                local isDepleted = indTex and not indTex:IsShown()

                -- Charge threshold cache: detShown[T] = true when charges >= T
                wipe(detShown)
                detShown[1] = indTex and indTex:IsShown()
                if row.chargeDetectors then
                    for T, det in pairs(row.chargeDetectors) do
                        local tex = det:GetStatusBarTexture()
                        detShown[T] = tex and tex:IsShown()
                    end
                end

                -- Child bar alpha: visible when a charge is recharging
                if chargeDurObj and AlphaCurve then
                    local ok, chargeAlpha = pcall(chargeDurObj.EvaluateRemainingDuration, chargeDurObj, AlphaCurve)
                    if ok then
                        row.depletedChargeBar:SetAlpha(chargeAlpha)
                        row.normalChargeBar:SetAlpha(chargeAlpha)
                        row.depletedHelperBar:SetAlpha(chargeAlpha)
                        -- 3+ charge per-lane alpha via threshold detectors
                        if row.maxCharges and row.maxCharges > 2 then
                            -- Bottom lane helper visibility
                            if row.notDepletedHelperBar then
                                if not detShown[row.maxCharges - 1] then
                                    row.notDepletedHelperBar:SetAlpha(chargeAlpha)
                                else
                                    row.notDepletedHelperBar:SetAlpha(0)
                                end
                            end
                            -- Middle lanes: charge visible when this lane is depleted,
                            -- helper visible when an EXTRA charge beyond this lane is depleted
                            if row.middleLanes then
                                for j = 1, row.maxCharges - 2 do
                                    local ml = row.middleLanes[j]
                                    if ml then
                                        if not detShown[row.maxCharges - j] then
                                            ml.depletedChargeBar:SetAlpha(chargeAlpha)
                                        else
                                            ml.depletedChargeBar:SetAlpha(0)
                                        end
                                        if not detShown[row.maxCharges - j - 1] then
                                            ml.depletedHelperBar:SetAlpha(chargeAlpha)
                                        else
                                            ml.depletedHelperBar:SetAlpha(0)
                                        end
                                    end
                                end
                            end
                        end
                    end
                elseif isAllCharged then
                    row.depletedChargeBar:SetAlpha(0)
                    row.normalChargeBar:SetAlpha(0)
                    row.depletedHelperBar:SetAlpha(0)
                    if row.notDepletedHelperBar then row.notDepletedHelperBar:SetAlpha(0) end
                    if row.middleLanes then
                        for j = 1, #row.middleLanes do
                            local ml = row.middleLanes[j]
                            if ml then
                                ml.depletedChargeBar:SetAlpha(0)
                                ml.depletedHelperBar:SetAlpha(0)
                            end
                        end
                    end
                end

                -- Fill animation
                if chargeDurObj then
                    local ok, remaining = pcall(chargeDurObj.GetRemainingDuration, chargeDurObj)
                    if ok then
                        row.depletedChargeBar:SetValue(remaining, interp)
                        row.normalChargeBar:SetValue(remaining, interp)
                        if isDepleted then
                            row.depletedCdBar:SetValue(remaining, interp)
                        end
                        if row.middleLanes then
                            for j = 1, #row.middleLanes do
                                local ml = row.middleLanes[j]
                                if ml then
                                    if not detShown[row.maxCharges - j] then
                                        ml.depletedChargeBar:SetValue(remaining, interp)
                                    else
                                        ml.depletedChargeBar:SetValue(0)
                                    end
                                end
                            end
                        end
                    end
                end
                if not isDepleted then
                    row.depletedCdBar:SetValue(0)
                end

                -- Cache future bar texture states
                local topTexShown = row.depletedCdBar
                    and row.depletedCdBar:GetStatusBarTexture()
                    and row.depletedCdBar:GetStatusBarTexture():IsShown()
                local bottomTexShown = row.normalChargeBar
                    and row.normalChargeBar:GetStatusBarTexture()
                    and row.normalChargeBar:GetStatusBarTexture():IsShown()

                -- Charge past slides
                local laneH = row.cdBar.laneHeight or ((CONFIG.height / 2) - 0.5)

                -- Top lane: spawn when depletedCdBar has fill, detach when it doesn't
                if topTexShown and not row.activeDepletedSlide then
                    row.activeDepletedSlide = SpawnPastSlide(row,
                        row.pastCdClip, CONFIG.cooldownColor, laneH, 0)
                    row._depletedSpawnTime = GetTime()
                elseif row.activeDepletedSlide and not row.activeDepletedSlide.detachTime and not topTexShown then
                    row.activeDepletedSlide.tex:SetAlpha(row.activeDepletedSlide.color[4] or CONFIG.cooldownColor[4] or 0.5)
                    DetachPastSlide(row.activeDepletedSlide)
                    row.activeDepletedSlide = nil
                    row._depletedSpawnTime = nil
                end

                -- Bottom lane: spawn when normalChargeBar has fill, detach when it doesn't
                if bottomTexShown and not row.activeChargeSlide then
                    local barH = row.cdBar.fullHeight or CONFIG.height
                    row.activeChargeSlide = SpawnPastSlide(row,
                        row.pastCdClip, CONFIG.cooldownColor,
                        laneH, barH - laneH)
                    row._chargeSpawnTime = GetTime()
                elseif row.activeChargeSlide and not row.activeChargeSlide.detachTime and not bottomTexShown then
                    row.activeChargeSlide.tex:SetAlpha(row.activeChargeSlide.color[4] or CONFIG.cooldownColor[4] or 0.5)
                    DetachPastSlide(row.activeChargeSlide)
                    row.activeChargeSlide = nil
                    row._chargeSpawnTime = nil
                end

                -- Middle lane past slides
                if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
                    for j = 1, row.maxCharges - 2 do
                        local ml = row.middleLanes[j]
                        if ml then
                            local mlTexShown = ml.depletedChargeBar
                                and ml.depletedChargeBar:GetStatusBarTexture()
                                and ml.depletedChargeBar:GetStatusBarTexture():IsShown()
                            if mlTexShown and not ml.activeSlide then
                                ml.activeSlide = SpawnPastSlide(row,
                                    row.pastCdClip, CONFIG.cooldownColor,
                                    laneH, j * (laneH + 1))
                            elseif ml.activeSlide and not ml.activeSlide.detachTime and not mlTexShown then
                                DetachPastSlide(ml.activeSlide)
                                ml.activeSlide = nil
                            end
                        end
                    end
                end

                -- Safety timeout: detach stuck slides
                local maxSlideDur = (row.maxCharges or 2) * (row.chargeDurationConstant or 12) + 2
                if row._depletedSpawnTime and GetTime() - row._depletedSpawnTime > maxSlideDur then
                    if row.activeDepletedSlide then
                        row.activeDepletedSlide.tex:SetAlpha(row.activeDepletedSlide.color[4] or CONFIG.cooldownColor[4] or 0.5)
                    end
                    DetachPastSlide(row.activeDepletedSlide)
                    row.activeDepletedSlide = nil
                    row._depletedSpawnTime = nil
                end
                if row._chargeSpawnTime and GetTime() - row._chargeSpawnTime > maxSlideDur then
                    if row.activeChargeSlide then
                        row.activeChargeSlide.tex:SetAlpha(row.activeChargeSlide.color[4] or CONFIG.cooldownColor[4] or 0.5)
                    end
                    DetachPastSlide(row.activeChargeSlide)
                    row.activeChargeSlide = nil
                    row._chargeSpawnTime = nil
                end

                -- 3+ charge lane repositioning via threshold detectors
                if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
                    local slotPx = row._chargeSlotPx or 0

                    for j = 1, row.maxCharges - 2 do
                        local ml = row.middleLanes[j]
                        if ml then
                            local helperVisible = not detShown[row.maxCharges - j - 1]
                            local newOffset = helperVisible and (j * slotPx) or 0
                            if ml._lastChargeOffset ~= newOffset then
                                local laneY = -(j * (laneH + 1))
                                ml.depletedChargeBar:ClearAllPoints()
                                ml.depletedChargeBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", newOffset, laneY)
                                ml._lastChargeOffset = newOffset
                            end
                        end
                    end

                    if row.notDepletedHelperBar then
                        local ndHelperCount = 0
                        for T = 1, row.maxCharges - 1 do
                            if not detShown[T] then
                                ndHelperCount = ndHelperCount + 1
                            end
                        end
                        local ndHelperPx = ndHelperCount * slotPx
                        if row._lastNdHelperPx ~= ndHelperPx then
                            local barH = row.cdBar.fullHeight or CONFIG.height
                            local bottomY = -(barH - laneH)
                            if ndHelperPx > 0 then
                                row.notDepletedHelperBar:SetSize(ndHelperPx, laneH)
                            else
                                row.notDepletedHelperBar:SetSize(1, laneH)
                            end
                            row.normalChargeBar:ClearAllPoints()
                            row.normalChargeBar:SetPoint("TOPLEFT", row.notDepletedWrapper, "TOPLEFT", ndHelperPx, bottomY)
                            row._lastNdHelperPx = ndHelperPx
                        end
                    end
                end

            end

            -- Buff and overlay past slides
            UpdateBuffPastSlide(row, row.hidden_buff, "activeBuffSlide", "pastBuffClip", "resolvedBuffColor")
            UpdateBuffPastSlide(row, row.hidden_overlay, "activeOverlaySlide", "pastOverlayClip", "resolvedOverlayColor")

            -- Pandemic polling
            if row.cachedPandemicIcon and CONFIG.pandemicPulse then
                local panOk, panShown = pcall(row.cachedPandemicIcon.IsShown, row.cachedPandemicIcon)
                if panOk and panShown then
                    if not row.buffPandemicAnim:IsPlaying() then
                        row.buffPandemicAnim:Play()
                    end
                else
                    if row.buffPandemicAnim:IsPlaying() then
                        row.buffPandemicAnim:Stop()
                        row.buffBar:SetAlpha(1.0)
                    end
                    if not panOk then
                        row.cachedPandemicIcon = nil
                    end
                end
            end

            -- GCD rendering
            if gcdActive and cachedGcdDurObj then
                local gcdOk = pcall(GcdBarAndSpark, cachedGcdDurObj, row.gcdBar, row.gcdSpark, row, CONFIG.future, interp)
                if not gcdOk then row.gcdSpark:Hide() end
                if not row.gcdBar:IsShown() then row.gcdBar:Show() end
            elseif row.gcdBar:IsShown() then
                row.gcdBar:Hide()
                row.gcdSpark:Hide()
            end
        end

        UpdateActiveCastBar()
        UpdatePastSlides()

        if not gcdActive then
            cachedGcdDurObj = nil
            lastFedGcdDurObj = nil
        end

        updateTimer = updateTimer - 0.033
    end
end)

local function ResetBarState(bar)
    bar.activeCooldown = nil
    bar.activeBuffDuration = nil
    bar.activeBuffOverlayDuration = nil
    bar.resolvedBuffColor = nil
    bar.resolvedOverlayColor = nil
    bar.cachedPandemicIcon = nil
    if bar.buffPandemicAnim and bar.buffPandemicAnim:IsPlaying() then
        bar.buffPandemicAnim:Stop()
        bar.buffBar:SetAlpha(1.0)
    end

    bar.lastChargeDurObj = nil
    bar.lastCdDurObj = nil
    
    bar.lastPtr_cd = nil
    bar.lastPtr_charge = nil
    bar.lastPtr_buff = nil
    bar.lastPtr_overlay = nil
    bar.wasOnGCD = false
    if bar.hidden_cd then bar.hidden_cd:SetCooldown(0, 0) end
    if bar.hidden_charge then bar.hidden_charge:SetCooldown(0, 0) end
    if bar.hidden_buff then bar.hidden_buff:SetCooldown(0, 0) end
    if bar.hidden_overlay then bar.hidden_overlay:SetCooldown(0, 0) end

    if bar.isChargeSpell then
        bar.chargesAvailable = bar.maxCharges or 2
    end
    
    bar.trackedBuffAuraInstanceID = nil
    bar.trackedOverlayAuraInstanceID = nil
    bar.secretAuraSpellId = nil
    bar.permanentBuffSlide = nil
    
    bar.icon:SetDesaturation(0)
    bar.cdBar:Hide()
    bar.buffBar:Hide()
    if bar.buffBarOverlay then bar.buffBarOverlay:Hide() end
    if bar.cooldownFrame then bar.cooldownFrame:Hide() end
    HideCastOverlays(bar)
    if bar.depletedWrapper then bar.depletedWrapper:Hide() end
    if bar.notDepletedWrapper then bar.notDepletedWrapper:Hide() end
    if bar.middleLanes then
        for _, ml in ipairs(bar.middleLanes) do
            ml.depletedChargeBar:SetAlpha(0)
            ml.depletedHelperBar:SetAlpha(0)
            ml._lastChargeOffset = nil
            ml.activeSlide = nil
        end
    end
    if bar.notDepletedHelperBar then bar.notDepletedHelperBar:SetAlpha(0) end
    bar._lastNdHelperPx = nil
    if bar.pastSlides then
        for _, slide in ipairs(bar.pastSlides) do
            slide.tex:Hide()
            slide.active = false
        end
    end
    bar.activeCdSlide = nil
    bar.activeBuffSlide = nil
    bar.activeOverlaySlide = nil
    bar.activeDepletedSlide = nil
    bar.activeChargeSlide = nil
    bar.chargeText:Hide()
    bar.stackText:Hide()
    if bar.variantNameText then bar.variantNameText:Hide() end

    -- reused bars need font re-applied
    ApplyFont(bar.chargeText, CONFIG.fontSize)
    ApplyFont(bar.stackText, CONFIG.fontSize)
    if bar.variantNameText then
        ApplyFont(bar.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
        bar.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
        bar.variantNameText:ClearAllPoints()
        bar.variantNameText:SetPoint(CONFIG.variantTextAnchor, bar.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
    end
    bar.chargeText:SetTextColor(unpack(CONFIG.chargeTextColor))
    bar.stackText:SetTextColor(unpack(CONFIG.stackTextColor))
    bar.chargeText:ClearAllPoints()
    bar.chargeText:SetPoint(CONFIG.chargeTextAnchor, bar.textOverlay, CONFIG.chargeTextRelPoint, CONFIG.chargeTextOffsetX, CONFIG.chargeTextOffsetY)
    bar.stackText:ClearAllPoints()
    bar.stackText:SetPoint(CONFIG.stackTextAnchor, bar.textOverlay, CONFIG.stackTextRelPoint, CONFIG.stackTextOffsetX, CONFIG.stackTextOffsetY)
end

local function ConfigureBarForSpell(bar, spellID, cooldownID, index)
    bar.spellID = spellID
    bar.baseSpellID = spellID
    bar.cooldownID = cooldownID

    -- Resolve override spell immediately so cast bar matching works before first UpdateBars
    local ovOk, ovID = pcall(C_Spell.GetOverrideSpell, spellID)
    if ovOk and ovID and ovID ~= spellID then
        bar.spellID = ovID
    end

    local isChargeSpell = false
    local chargeInfo = GetChargesWithOverride(spellID)
    local detectedMaxCharges = nil
    
    if chargeInfo and chargeInfo.maxCharges then
        if issecretvalue and issecretvalue(chargeInfo.maxCharges) then
            -- Secret in combat, fall back to SavedVariables
            local saved = InfallDB.chargeSpells and InfallDB.chargeSpells[cooldownID]
            if saved then
                local savedMax = type(saved) == "table" and saved.maxCharges or (saved == true and 2)
                if savedMax and savedMax > 1 then
                    isChargeSpell = true
                    detectedMaxCharges = savedMax
                end
            end
        else
            if chargeInfo.maxCharges > 1 then
                isChargeSpell = true
                detectedMaxCharges = chargeInfo.maxCharges
            end
            InfallDB.chargeSpells = InfallDB.chargeSpells or {}
            if chargeInfo.maxCharges > 1 then
                InfallDB.chargeSpells[cooldownID] = {
                    hasChargeMechanic = true,
                    maxCharges = chargeInfo.maxCharges
                }
            else
                InfallDB.chargeSpells[cooldownID] = nil
            end
        end
    end
    
    bar.hasCharges = isChargeSpell

    -- User toggle: single bar, but keep charge count text
    if isChargeSpell and CONFIG.chargesDisabled and CONFIG.chargesDisabled[cooldownID] then
        isChargeSpell = false
        detectedMaxCharges = nil
    end

    bar.isChargeSpell = isChargeSpell

    if isChargeSpell then
        local maxC = detectedMaxCharges or 2
        local currentC = maxC  -- default to full
        if chargeInfo and chargeInfo.currentCharges and not issecretvalue(chargeInfo.currentCharges) then
            currentC = chargeInfo.currentCharges
        end
        bar.maxCharges = maxC
        bar.chargesAvailable = currentC
    else
        bar.maxCharges = 1
        bar.chargesAvailable = 1
    end
    
    if isChargeSpell and chargeInfo then
        if not issecretvalue(chargeInfo.cooldownDuration) and chargeInfo.cooldownDuration > 0 then
            bar.chargeDurationConstant = chargeInfo.cooldownDuration
            -- Persist for mid-combat reload recovery
            InfallDB.chargeDurations = InfallDB.chargeDurations or {}
            InfallDB.chargeDurations[cooldownID] = chargeInfo.cooldownDuration
        else
            -- Secret in combat, read from saved variables
            local saved = InfallDB.chargeDurations and InfallDB.chargeDurations[cooldownID]
            if saved then
                bar.chargeDurationConstant = saved
            end
        end
    elseif not isChargeSpell then
        bar.chargeDurationConstant = nil
    end
    
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if spellInfo then
        bar.icon:SetTexture(spellInfo.iconID)
        bar.spellName = spellInfo.name
    end
    
    bar.cdBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))

    if isChargeSpell then
        bar.cdBar:SetHeight(bar.cdBar.laneHeight)
    else
        bar.cdBar:SetHeight(bar.cdBar.fullHeight)
    end

    -- Children inherit parent alpha for compound visibility
    if isChargeSpell then
        local futureWidth = GetFutureWidth()
        local nowPx = GetNowPixelOffset()
        local nowOffset = GetBarOffset() + nowPx
        local maxC = bar.maxCharges or 2
        local barHeight = bar.cdBar.fullHeight or CONFIG.height
        local laneH = (barHeight - (maxC - 1)) / maxC
        bar.cdBar.laneHeight = laneH

        -- slotPx: offset for stagger layout
        local slotPx = 0
        if bar.chargeDurationConstant then
            slotPx = (bar.chargeDurationConstant / CONFIG.future) * futureWidth
            slotPx = math.max(1, math.min(slotPx, futureWidth))
        end
        bar._chargeSlotPx = slotPx

        -- Create depletedIndicator + wrapper frames lazily
        if not bar.depletedIndicator then
            -- depletedIndicator: invisible VERTICAL StatusBar. SetMinMaxValues(0,1)
            -- with SetValue(currentCharges) gives binary: 0=depleted, 1+=not.
            -- Engine clamps above max. Texture TOP edge = clip boundary.
            bar.depletedIndicator = CreateFrame("StatusBar", nil, bar)
            bar.depletedIndicator:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            bar.depletedIndicator:GetStatusBarTexture():SetAlpha(0)
            bar.depletedIndicator:SetOrientation("VERTICAL")
            bar.depletedIndicator:SetMinMaxValues(0, 1)
            CrispBar(bar.depletedIndicator)
        end
        -- Charge threshold detectors for 3+ charge spells.
        -- Hidden StatusBars with SetMinMaxValues(T-1, T).
        -- SetValue(currentCharges) in, GetStatusBarTexture():IsShown() out.
        -- IsShown() = true when charges >= T. Engine-mediated, works with secrets.
        if maxC > 2 then
            bar.chargeDetectors = bar.chargeDetectors or {}
            for T = 2, maxC - 1 do
                if not bar.chargeDetectors[T] then
                    bar.chargeDetectors[T] = CreateFrame("StatusBar", nil, bar)
                    bar.chargeDetectors[T]:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
                    bar.chargeDetectors[T]:GetStatusBarTexture():SetAlpha(0)
                    bar.chargeDetectors[T]:SetMinMaxValues(T - 1, T)
                    bar.chargeDetectors[T]:SetSize(1, 1)
                    bar.chargeDetectors[T]:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
                    bar.chargeDetectors[T]:Show()
                    CrispBar(bar.chargeDetectors[T])
                end
            end
        end
        if not bar.depletedWrapper then
            -- depletedWrapper: clip frame, visible when indicator 0% (depleted)
            bar.depletedWrapper = CreateFrame("Frame", nil, bar)
            bar.depletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)
            bar.depletedWrapper:SetClipsChildren(true)

            bar.depletedCdBar = CreateStatusBar(bar.depletedWrapper)
            bar.depletedCdBar:Show()

            bar.depletedHelperBar = CreateStatusBar(bar.depletedWrapper, 1)
            bar.depletedHelperBar:SetValue(1)
            bar.depletedHelperBar:Show()

            bar.depletedChargeBar = CreateStatusBar(bar.depletedWrapper)
            bar.depletedChargeBar:Show()

            -- notDepletedWrapper: clip frame, visible when indicator 100% (not depleted)
            bar.notDepletedWrapper = CreateFrame("Frame", nil, bar)
            bar.notDepletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)
            bar.notDepletedWrapper:SetClipsChildren(true)

            bar.normalChargeBar = CreateStatusBar(bar.notDepletedWrapper)
            bar.normalChargeBar:Show()
        end

        -- depletedIndicator: overlays the future zone for anchor computation
        bar.depletedIndicator:ClearAllPoints()
        bar.depletedIndicator:SetSize(futureWidth, CONFIG.height)
        bar.depletedIndicator:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.depletedIndicator:SetValue(0)
        bar.depletedIndicator:Show()

        -- depletedWrapper: clip from bar TOP down to indicator texture TOP.
        -- At 0/N (0% fill): texture TOP = indicator BOTTOM → clip = full height.
        -- At 1+/N (100% fill): texture TOP = indicator TOP → clip = 0 height.
        bar.depletedWrapper:ClearAllPoints()
        bar.depletedWrapper:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.depletedWrapper:SetPoint("BOTTOMRIGHT", bar.depletedIndicator:GetStatusBarTexture(), "TOPRIGHT")
        bar.depletedWrapper:SetAlpha(1)
        bar.depletedWrapper:Show()

        -- notDepletedWrapper: clip from indicator texture TOP down to bar BOTTOM.
        -- At 0/N: texture TOP = indicator BOTTOM → clip = 0 height.
        -- At 1+/N: texture TOP = indicator TOP → clip = full height.
        bar.notDepletedWrapper:ClearAllPoints()
        bar.notDepletedWrapper:SetPoint("TOPLEFT", bar.depletedIndicator:GetStatusBarTexture(), "TOPLEFT")
        bar.notDepletedWrapper:SetPoint("BOTTOMRIGHT", bar, "TOPLEFT", nowOffset + futureWidth, -CONFIG.height)
        bar.notDepletedWrapper:SetAlpha(1)
        bar.notDepletedWrapper:Show()

        -- Position bars within depletedWrapper
        local bottomY = -(barHeight - laneH)

        bar.depletedCdBar:ClearAllPoints()
        bar.depletedCdBar:SetSize(futureWidth, laneH)
        bar.depletedCdBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, 0)
        bar.depletedCdBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))

        -- Bottom lane stagger scales with charge count
        local bottomSlotPx = (maxC - 1) * slotPx
        bar.depletedHelperBar:ClearAllPoints()
        bar.depletedHelperBar:SetSize(math.max(1, bottomSlotPx), laneH)
        bar.depletedHelperBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, bottomY)
        bar.depletedHelperBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))

        bar.depletedChargeBar:ClearAllPoints()
        bar.depletedChargeBar:SetSize(futureWidth, laneH)
        bar.depletedChargeBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", bottomSlotPx, bottomY)
        bar.depletedChargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))

        -- Position bars within notDepletedWrapper
        bar.normalChargeBar:ClearAllPoints()
        bar.normalChargeBar:SetSize(futureWidth, laneH)
        bar.normalChargeBar:SetPoint("TOPLEFT", bar.notDepletedWrapper, "TOPLEFT", 0, bottomY)
        bar.normalChargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))

        -- Bottom lane helper in notDepletedWrapper for 3+ charges
        -- Shows stagger for depleted charges when the spell is still usable (1+/N)
        if maxC > 2 then
            if not bar.notDepletedHelperBar then
                bar.notDepletedHelperBar = CreateFrame("StatusBar", nil, bar.notDepletedWrapper)
                bar.notDepletedHelperBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                bar.notDepletedHelperBar:SetMinMaxValues(0, 1)
                bar.notDepletedHelperBar:SetValue(1)
                bar.notDepletedHelperBar:SetOrientation("HORIZONTAL")
                bar.notDepletedHelperBar:GetStatusBarTexture():SetHorizTile(false)
                bar.notDepletedHelperBar:GetStatusBarTexture():SetVertTile(false)
                CrispBar(bar.notDepletedHelperBar)
            end
            bar.notDepletedHelperBar:ClearAllPoints()
            bar.notDepletedHelperBar:SetSize(math.max(1, bottomSlotPx), laneH)
            bar.notDepletedHelperBar:SetPoint("TOPLEFT", bar.notDepletedWrapper, "TOPLEFT", 0, bottomY)
            bar.notDepletedHelperBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
            bar.notDepletedHelperBar:SetAlpha(0)
            bar.notDepletedHelperBar:Show()
        elseif bar.notDepletedHelperBar then
            bar.notDepletedHelperBar:Hide()
        end

        -- Middle lane charge bars for 3+ charge spells
        -- Parented to bar (not depletedWrapper) so wrapper alpha doesn't hide them.
        -- Alpha driven per-lane by charge threshold detectors in the OnUpdate.
        bar.middleLanes = bar.middleLanes or {}
        if maxC > 2 then
            local wrapperLevel = bar:GetFrameLevel() + 1
            for j = 1, maxC - 2 do
                if not bar.middleLanes[j] then
                    local ml = {}
                    ml.depletedChargeBar = CreateFrame("StatusBar", nil, bar)
                    ml.depletedChargeBar:SetFrameLevel(wrapperLevel)
                    ml.depletedChargeBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                    ml.depletedChargeBar:SetMinMaxValues(0, CONFIG.future)
                    ml.depletedChargeBar:SetOrientation("HORIZONTAL")
                    ml.depletedChargeBar:GetStatusBarTexture():SetHorizTile(false)
                    ml.depletedChargeBar:GetStatusBarTexture():SetVertTile(false)
                    CrispBar(ml.depletedChargeBar)

                    ml.depletedHelperBar = CreateFrame("StatusBar", nil, bar)
                    ml.depletedHelperBar:SetFrameLevel(wrapperLevel)
                    ml.depletedHelperBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
                    ml.depletedHelperBar:SetMinMaxValues(0, 1)
                    ml.depletedHelperBar:SetValue(1)
                    ml.depletedHelperBar:SetOrientation("HORIZONTAL")
                    ml.depletedHelperBar:GetStatusBarTexture():SetHorizTile(false)
                    ml.depletedHelperBar:GetStatusBarTexture():SetVertTile(false)
                    CrispBar(ml.depletedHelperBar)

                    bar.middleLanes[j] = ml
                end
                local ml = bar.middleLanes[j]
                local laneY = -(j * (laneH + 1))
                local mlSlotPx = j * slotPx

                -- Anchored to depletedWrapper for position, but parented to bar for alpha
                ml.depletedHelperBar:ClearAllPoints()
                ml.depletedHelperBar:SetSize(math.max(1, mlSlotPx), laneH)
                ml.depletedHelperBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", 0, laneY)
                ml.depletedHelperBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
                ml.depletedHelperBar:SetAlpha(0)
                ml.depletedHelperBar:Show()

                ml.depletedChargeBar:ClearAllPoints()
                ml.depletedChargeBar:SetSize(futureWidth, laneH)
                ml.depletedChargeBar:SetPoint("TOPLEFT", bar.depletedWrapper, "TOPLEFT", mlSlotPx, laneY)
                ml.depletedChargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
                ml.depletedChargeBar:SetAlpha(0)
                ml.depletedChargeBar:Show()
            end
        end
        -- Hide excess middle lanes from previous bar assignment
        for j = (maxC > 2 and maxC - 1 or 1), #bar.middleLanes do
            local ml = bar.middleLanes[j]
            if ml then
                ml.depletedChargeBar:Hide()
                ml.depletedHelperBar:Hide()
                if ml.activeSlide then
                    DetachPastSlide(ml.activeSlide)
                    ml.activeSlide = nil
                end
            end
        end

        -- wrappers take over
        bar.cdBar:Hide()
    
    else
        if bar.depletedWrapper then
            bar.depletedWrapper:Hide()
            bar.notDepletedWrapper:Hide()
        end
        if bar.notDepletedHelperBar then bar.notDepletedHelperBar:Hide() end
        if bar.middleLanes then
            for _, ml in ipairs(bar.middleLanes) do
                ml.depletedChargeBar:Hide()
                ml.depletedHelperBar:Hide()
            end
        end
    end

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((index - 1) * (CONFIG.height + CONFIG.spacing)))
end

LoadEssentialCooldowns = function()
    for _, bar in ipairs(cooldownBars) do bar:Hide() end
    wipe(cooldownBars)
    
    local sortedSpellIDs = {}
    local sortedCooldownIDs = {}
    local foundSource = false
    
    if CooldownViewerSettings and CooldownViewerSettings.GetDataProvider then
        local dataProvider = CooldownViewerSettings:GetDataProvider()
        if dataProvider and dataProvider.GetOrderedCooldownIDsForCategory then
            local displayedCooldownIDs = dataProvider:GetOrderedCooldownIDsForCategory(0)
            if displayedCooldownIDs and #displayedCooldownIDs > 0 then
                for _, cdID in ipairs(displayedCooldownIDs) do
                    local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if infoOk and info and info.spellID then
                        table.insert(sortedSpellIDs, info.spellID)
                        table.insert(sortedCooldownIDs, cdID)
                    end
                end
                foundSource = (#sortedSpellIDs > 0)
            end
        end
    end
    
    if not foundSource then
        if C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable then
            local isAvailable = C_CooldownViewer.IsCooldownViewerAvailable()
            if isAvailable then
                local success, cooldownIDs = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, 0, false)
                if success and cooldownIDs then
                    for _, cooldownID in ipairs(cooldownIDs) do
                        local infoOk, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                        if infoOk and info and info.spellID then
                            table.insert(sortedSpellIDs, info.spellID)
                            table.insert(sortedCooldownIDs, cooldownID)
                        end
                    end
                end
            end
        end
    end
    
    if #sortedSpellIDs == 0 then
        if not shownSetupHint then
            shownSetupHint = true
            print("|cff00ff00[Infall]|r No abilities found in the Cooldown Manager.")
            print("|cff00ff00[Infall]|r   Type |cffffff00/infall setup|r to open the Cooldown Manager settings,")
            print("|cff00ff00[Infall]|r   add your abilities, then |cffffff00/infall reload|r or |cffffff00/reload|r")
        end
        return
    end
    
    -- Filter out hidden cooldowns.
    local hiddenSet = {}
    if CONFIG.hiddenCooldownIDs then
        for id, v in pairs(CONFIG.hiddenCooldownIDs) do
            if v then hiddenSet[id] = true end
        end
    end
    
    if next(hiddenSet) then
        local filteredSpellIDs = {}
        local filteredCooldownIDs = {}
        for i, cdID in ipairs(sortedCooldownIDs) do
            if not hiddenSet[cdID] then
                table.insert(filteredSpellIDs, sortedSpellIDs[i])
                table.insert(filteredCooldownIDs, cdID)
            end
        end
        sortedSpellIDs = filteredSpellIDs
        sortedCooldownIDs = filteredCooldownIDs
    end
    
    if #sortedSpellIDs == 0 then return end
    
    for i, spellID in ipairs(sortedSpellIDs) do
        local bar = barPool[i]
        
        if bar then
            ResetBarState(bar)
            ConfigureBarForSpell(bar, spellID, sortedCooldownIDs[i], i)
        else
            bar = CreateCooldownBar(spellID, i)
            ConfigureBarForSpell(bar, spellID, sortedCooldownIDs[i], i)
            table.insert(barPool, bar)
        end
        
        bar:Show()
        table.insert(cooldownBars, bar)
    end
    
    -- Hide text on unused pooled bars (text frames parented to EH_Parent, not row)
    for i = #cooldownBars + 1, #barPool do
        local bar = barPool[i]
        bar.chargeText:Hide()
        bar.stackText:Hide()
        if bar.variantNameText then bar.variantNameText:Hide() end
    end

    wipe(permanentBuffCdIDs)

    ApplyLayoutToAllBars()

    C_Timer.After(0.5, UpdateBars)
end

local function ProcessSpecChange()
    specChangePending = false
    local myToken = specChangeToken
    local specKey = ns.GetSpecKey and ns.GetSpecKey()
    if not specKey then return end

    if specKey ~= ns.currentSpecKey then
        ns.currentSpecKey = specKey
        if InfallDB.profiles[specKey] and ns.ApplyProfile then
            ns.ApplyProfile(InfallDB.profiles[specKey])
        elseif ns.SeedProfileFromClassConfig then
            ns.SeedProfileFromClassConfig(specKey)
        end
    end

    LoadEssentialCooldowns()

    C_Timer.After(0, function()
        if myToken ~= specChangeToken then return end
        SmartReorder()
    end)

    C_Timer.After(1, function()
        if myToken ~= specChangeToken then return end
        UpdateBars()
    end)
end

local function UpdateVisibility()
    if not CONFIG.redshift then
        EH_Parent:Show()
        return
    end
    
    local inCombat = InCombatLockdown()
    local hasTarget = UnitExists("target")
    
    if inCombat or hasTarget then
        EH_Parent:Show()
    else
        EH_Parent:Hide()
    end
end

-- Events

EH_Parent:RegisterEvent("ADDON_LOADED")
EH_Parent:RegisterEvent("PLAYER_ENTERING_WORLD")
EH_Parent:RegisterEvent("SPELL_UPDATE_COOLDOWN")
EH_Parent:RegisterEvent("SPELL_UPDATE_CHARGES")
EH_Parent:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
EH_Parent:RegisterEvent("SPELLS_CHANGED")
EH_Parent:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")

EH_Parent:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
EH_Parent:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
EH_Parent:RegisterEvent("SPELL_UPDATE_USABLE")
EH_Parent:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")

EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "player")
EH_Parent:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

EH_Parent:RegisterUnitEvent("UNIT_AURA", "player", "target", "pet")

EH_Parent:RegisterEvent("PLAYER_REGEN_DISABLED")
EH_Parent:RegisterEvent("PLAYER_REGEN_ENABLED")
EH_Parent:RegisterEvent("PLAYER_TARGET_CHANGED")

-- ECM visibility
local ecmFrameNames = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local function ApplyECMVisibility()
    if InCombatLockdown() then return end
    for _, name in ipairs(ecmFrameNames) do
        local frame = _G[name]
        if frame then
            if CONFIG.hideBlizzECM then
                pcall(function() frame:SetAlpha(0) end)
                -- Disable mouse on item frames so tooltips don't appear on invisible CDM
                pcall(function()
                    for itemFrame in frame.itemFramePool:EnumerateActive() do
                        itemFrame:SetMouseMotionEnabled(false)
                    end
                end)
            else
                pcall(function() frame:UpdateSystemSettingOpacity() end)
                pcall(function()
                    for itemFrame in frame.itemFramePool:EnumerateActive() do
                        itemFrame:SetMouseMotionEnabled(true)
                    end
                end)
            end
        end
    end
end
ns.ApplyECMVisibility = ApplyECMVisibility

local function ForceViewersAlways()
    local CDM_VIS_SETTING = 6
    local VIS_ALWAYS = 0
    local CDM_HIDE_INACTIVE = 8
    local changed = false
    local mgr = EditModeManagerFrame
    if not mgr or not mgr.OnSystemSettingChange then return false end

    -- Preset layouts (Modern/Classic) don't persist changes
    local isPreset = false
    if mgr.GetActiveLayoutInfo then
        local ok, layoutInfo = pcall(mgr.GetActiveLayoutInfo, mgr)
        if ok and layoutInfo and layoutInfo.layoutType then
            isPreset = (layoutInfo.layoutType == (Enum.EditModeLayoutType and Enum.EditModeLayoutType.Preset))
        end
    end

    for _, name in ipairs(ecmFrameNames) do
        local viewer = _G[name]
        if viewer then
            if viewer.visibleSetting and viewer.visibleSetting ~= VIS_ALWAYS then
                pcall(mgr.OnSystemSettingChange, mgr, viewer, CDM_VIS_SETTING, VIS_ALWAYS)
                changed = true
            end
            -- BuffIcon viewer: force HideWhenInactive off so buff frames stay populated
            if name == "BuffIconCooldownViewer" then
                local hideOk, hideVal = pcall(function()
                    return viewer:GetSettingValue(CDM_HIDE_INACTIVE)
                end)
                if hideOk and hideVal and hideVal ~= 0 then
                    pcall(mgr.OnSystemSettingChange, mgr, viewer, CDM_HIDE_INACTIVE, 0)
                    changed = true
                end
            end
        end
    end
    if changed and mgr.SaveLayouts then
        pcall(mgr.SaveLayouts, mgr)
    end
    if changed and isPreset then
        print("|cff00ff00[Infall]|r Warning: You are using a preset Edit Mode layout. CDM viewer changes may not persist. Create a custom layout for permanent settings.")
    end
    return changed
end

local function ApplyCastBarVisibility()
    if InCombatLockdown() then return end
    local bar = PlayerCastingBarFrame
    if not bar then return end
    if CONFIG.hideBlizzCastBar then
        bar:SetAlpha(0)
        pcall(function() bar:UnregisterAllEvents() end)
    else
        bar:SetAlpha(1)
        pcall(function()
            bar:RegisterEvent("UNIT_SPELLCAST_START")
            bar:RegisterEvent("UNIT_SPELLCAST_STOP")
            bar:RegisterEvent("UNIT_SPELLCAST_FAILED")
            bar:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
            bar:RegisterEvent("UNIT_SPELLCAST_DELAYED")
            bar:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
            bar:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
            bar:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
            bar:RegisterEvent("UNIT_SPELLCAST_EMPOWER_START")
            bar:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
            bar:RegisterEvent("UNIT_SPELLCAST_EMPOWER_UPDATE")
            bar:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            bar:RegisterEvent("PLAYER_ENTERING_WORLD")
        end)
    end
end
ns.ApplyCastBarVisibility = ApplyCastBarVisibility

local loginInitFrame = CreateFrame("Frame")
loginInitFrame:RegisterEvent("PLAYER_LOGIN")
loginInitFrame:SetScript("OnEvent", function()
    -- CDM is required; auto-enable if available but toggled off
    local cdmAvailable = C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable and C_CooldownViewer.IsCooldownViewerAvailable()
    if cdmAvailable and not C_CVar.GetCVarBool("cooldownViewerEnabled") then
        SetCVar("cooldownViewerEnabled", true)
        print("|cff00ff00[Infall]|r Enabled the Cooldown Manager. Infall requires it to function.")
    end

    -- Force all CDM viewers to "Always" visibility so frames are always populated
    if ForceViewersAlways() then
        print("|cff00ff00[Infall]|r Cooldown viewer visibility set to Always. Use |cffffff00/infall ecm|r to toggle visibility.")
    end

    PreCacheChargeSpells()

    EH_Parent:SetMovable(true)
    EH_Parent:EnableMouse(true)
    EH_Parent:RegisterForDrag("LeftButton")
    EH_Parent:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or CONFIG.locked then return end
        self:StartMoving()
    end)
    EH_Parent:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        InfallDB.position = { point = point, relPoint = relPoint, x = x, y = y }
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
    end)
    
    if InfallDB.position then
        local pos = InfallDB.position
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
    
    ApplyECMVisibility()

    local setAlphaGuard = {}
    for _, name in ipairs(ecmFrameNames) do
        local frame = _G[name]
        if frame then
            hooksecurefunc(frame, "SetAlpha", function(self, alpha)
                if InCombatLockdown() then return end
                if setAlphaGuard[self] then return end
                if issecretvalue and issecretvalue(alpha) then return end
                if CONFIG.hideBlizzECM and alpha > 0 then
                    setAlphaGuard[self] = true
                    self:SetAlpha(0)
                    setAlphaGuard[self] = nil
                end
            end)
        end
    end


    EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
        if InCombatLockdown() then return end
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            if #cooldownBars > 0 then
                SmartReorder()
            else
                LoadEssentialCooldowns()
            end
        end)
        
        -- Second pass in case the data provider hasn't committed the new order yet
        C_Timer.After(1.0, function()
            if InCombatLockdown() then return end
            if #cooldownBars > 0 then
                SmartReorder()
            else
                LoadEssentialCooldowns()
            end
        end)
    end, EH_Parent)

    local specKey = ns.GetSpecKey and ns.GetSpecKey()
    if specKey then
        ns.currentSpecKey = specKey
        if InfallDB.profiles[specKey] then
            if ns.ApplyProfile then
                ns.ApplyProfile(InfallDB.profiles[specKey])
            end
        else
            -- first time for this spec
            if ns.SeedProfileFromClassConfig then
                ns.SeedProfileFromClassConfig(specKey)
            end
        end
        if InfallDB.pendingMigration then
            local profile = InfallDB.profiles[specKey]
            if profile and profile.toggles then
                for k, v in pairs(InfallDB.pendingMigration) do
                    profile.toggles[k] = v
                end
            end
            InfallDB.pendingMigration = nil
        end
    end

    -- must be after profile loading sets CONFIG
    ApplyCastBarVisibility()
    if CONFIG.clickthrough then
        EH_Parent:EnableMouse(false)
        CONFIG.locked = true
    end

    -- Register settings panel in the ESC menu at load time
    if ns.InitSettings then ns.InitSettings() end
end)

local lastUnitAuraUpdate = 0
local UNIT_AURA_THROTTLE = 0.1

EH_Parent:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            -- Migrate old flat InfallDB to profile structure
            if InfallDB and not InfallDB.profiles then
                local oldToggles = {}
                for _, key in ipairs({"reactiveIcons", "desaturateOnCooldown", "redshift",
                    "pandemicPulse", "locked", "hideBlizzCastBar", "hideBlizzECM",
                    "buffLayerAbove", "hideIcons", "clickthrough"}) do
                    if InfallDB[key] ~= nil then
                        oldToggles[key] = InfallDB[key]
                        InfallDB[key] = nil
                    end
                end
                -- Migrate autohide -> redshift
                if InfallDB.autohide ~= nil then
                    oldToggles.redshift = InfallDB.autohide
                    InfallDB.autohide = nil
                end
                -- Preserve global fields
                local pos = InfallDB.position
                local cs = InfallDB.chargeSpells
                local cd = InfallDB.chargeDurations
                local hidden = InfallDB.hiddenCooldownIDs

                InfallDB = {
                    profiles = {},
                    position = pos,
                    chargeSpells = cs or {},
                    chargeDurations = cd or {},
                    hiddenCooldownIDs = hidden or {},
                    pendingMigration = oldToggles,
                }
            end
            InfallDB.profiles = InfallDB.profiles or {}
            InfallDB.namedProfiles = InfallDB.namedProfiles or {}
            InfallDB.chargeSpells = InfallDB.chargeSpells or {}
            InfallDB.chargeDurations = InfallDB.chargeDurations or {}

            if ns.ApplyBackdrop then
                ns.ApplyBackdrop()
            end
            
            EH_Parent:SetScale(CONFIG.scale)
            EH_Parent:SetWidth(CONFIG.paddingLeft + CONFIG.iconSize + (CONFIG.iconGap or 10) + CONFIG.width + CONFIG.paddingRight)
            
            print("|cff00ff00[Infall]|r Loaded. Type |cffffff00/infall setup|r for settings or |cffffff00/infall|r for commands.")
        end
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2, function()
            if #cooldownBars == 0 then LoadEssentialCooldowns() end
        end)
        C_Timer.After(2.5, UpdateVisibility)
        -- Viewers may recreate after zone transitions; re-force Always + re-hide
        C_Timer.After(2.5, function()
            if InCombatLockdown() then
                ns._pendingECMReapply = true
                return
            end
            ForceViewersAlways()
            ApplyECMVisibility()
        end)
        
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
        -- If bars haven't been loaded yet (first GCD before 2s timer), load now
        if #cooldownBars == 0 then
            LoadEssentialCooldowns()
            -- Recover any cast already in progress (UNIT_SPELLCAST_START fired before bars existed)
            if #cooldownBars > 0 and not activeCast then
                UpdateCastBar(event)
            end
        end

        local gcdSuccess, gcdObj = pcall(C_Spell.GetSpellCooldownDuration, 61304)
        if gcdSuccess and gcdObj and gcdObj.GetRemainingDuration then
            cachedGcdDurObj = gcdObj
            if gcdObj ~= lastFedGcdDurObj then
                gcdActive = true
                lastFedGcdDurObj = gcdObj
                pcall(hiddenGcdCooldown.SetCooldownFromDurationObject, hiddenGcdCooldown, gcdObj, true)
            end
        end


        UpdateBars()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...

        for _, row in ipairs(cooldownBars) do
            local isMatch = (row.spellID == spellID or row.baseSpellID == spellID)
            if not isMatch then
                local ok, overrideID = pcall(C_Spell.GetOverrideSpell, row.baseSpellID)
                if ok and overrideID and overrideID == spellID then
                    isMatch = true
                end
            end
            if not isMatch and CONFIG.extraCasts then
                local extras = CONFIG.extraCasts[row.cooldownID] or CONFIG.extraCasts[row.baseSpellID] or CONFIG.extraCasts[row.spellID]
                if extras then
                    for _, extraID in ipairs(extras) do
                        if extraID == spellID then isMatch = true; break end
                    end
                end
            end

            if isMatch then
                if row.isChargeSpell then
                    row.chargesAvailable = math.max((row.chargesAvailable or 0) - 1, 0)
                    FeedChargeHiddenFrames(row)
                    UpdateBars()
                    ScheduleDeferredUpdate(0)
                end
                break
            end
        end
        
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        specChangeToken = specChangeToken + 1
        specChangePending = true
        local myToken = specChangeToken
        C_Timer.After(2, function()
            if myToken == specChangeToken and specChangePending then
                ProcessSpecChange()
            end
        end)

    elseif event == "SPELLS_CHANGED" then
        if specChangePending then
            ProcessSpecChange()
        end

    elseif event == "COOLDOWN_VIEWER_DATA_LOADED" then
        if #cooldownBars > 0 then
            C_Timer.After(0, SmartReorder)
        else
            C_Timer.After(0, LoadEssentialCooldowns)
        end
        
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if row.spellID == spellID or row.baseSpellID == spellID then
                HandleProcGlow(row, true)
            end
        end
        UpdateBars()
        ScheduleDeferredUpdate(0)

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if row.spellID == spellID or row.baseSpellID == spellID then
                HandleProcGlow(row, false)
            end
        end
        
    elseif event == "SPELL_UPDATE_USABLE" then
        UpdateAllIconStates()
        
    elseif event == "SPELL_RANGE_CHECK_UPDATE" then
        local spellID = ...
        for _, row in ipairs(cooldownBars) do
            if row.spellID == spellID or row.baseSpellID == spellID then
                UpdateIconState(row)
            end
        end
        
    elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" or event == "UNIT_SPELLCAST_DELAYED"
           or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        if #cooldownBars == 0 then
            LoadEssentialCooldowns()
        end
        UpdateCastBar(event)
        
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or
           event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
           or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        local _, _, spellID = ...
        if activeCast and activeCast.row then
            -- Type guard: cast stops only affect casts, channel stops only affect channels.
            local isCastStop = (event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED")
            local isChannelStop = (event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP")
            
            local typeMatch = true
            if activeCast.isChannel and isCastStop then
                typeMatch = false  -- don't let a cast stop kill an active channel
            elseif not activeCast.isChannel and isChannelStop then
                typeMatch = false  -- don't let a channel stop kill an active cast
            end
            
            if typeMatch and (not spellID or spellID == activeCast.spellID) then
                -- Detach the cast's past slide (successful or not)
                if activeCast.pastSlide then
                    if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
                        DetachPastSlide(activeCast.pastSlide)
                    else
                        -- Failed/interrupted: just kill the slide immediately
                        activeCast.pastSlide.tex:Hide()
                        activeCast.pastSlide.active = false
                    end
                end
                HideCastOverlays(activeCast.row)
                activeCast = nil
            end
        end

    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        
        if updateInfo and updateInfo.removedAuraInstanceIDs then
            for _, removedID in ipairs(updateInfo.removedAuraInstanceIDs) do
                for _, row in ipairs(cooldownBars) do
                    if row.trackedBuffAuraInstanceID == removedID then
                        row.activeBuffDuration = nil
                        row.trackedBuffAuraInstanceID = nil
                        row.buffBar:Hide()
                        if row.permanentBuffSlide and row.permanentBuffSlide.active then
                            DetachPastSlide(row.permanentBuffSlide)
                            row.permanentBuffSlide = nil
                        end
                    end
                    if row.trackedOverlayAuraInstanceID == removedID then
                        row.activeBuffOverlayDuration = nil
                        row.trackedOverlayAuraInstanceID = nil
                        if row.buffBarOverlay then row.buffBarOverlay:Hide() end
                    end
                end
            end
        end
        
        local now = GetTime()
        if now - lastUnitAuraUpdate >= UNIT_AURA_THROTTLE then
            lastUnitAuraUpdate = now
            UpdateBars()
            ScheduleDeferredUpdate(0)
            if unit == "target" then
                ScheduleDeferredUpdate(0.05)
                ScheduleDeferredUpdate(0.1)
            end
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()
        
        if event == "PLAYER_REGEN_ENABLED" then
            for _, row in ipairs(cooldownBars) do
                row.cachedPandemicIcon = nil
                -- Detach active slides so they drift off naturally
                for _, key in ipairs({"activeCdSlide", "activeBuffSlide", "activeOverlaySlide", "activeDepletedSlide", "activeChargeSlide", "permanentBuffSlide"}) do
                    if row[key] then DetachPastSlide(row[key]) end
                    row[key] = nil
                end
                row._depletedSpawnTime = nil
                row._chargeSpawnTime = nil
                if row.middleLanes then
                    for _, ml in ipairs(row.middleLanes) do
                        if ml.activeSlide then DetachPastSlide(ml.activeSlide) end
                        ml.activeSlide = nil
                    end
                end
                for _, key in ipairs({"lastPtr_cd", "lastPtr_charge", "lastPtr_buff", "lastPtr_overlay"}) do
                    row[key] = nil
                end
                for _, key in ipairs({"hidden_cd", "hidden_charge", "hidden_buff", "hidden_overlay"}) do
                    if row[key] then row[key]:SetCooldown(0, 0) end
                end

                -- readable out of combat
                if row.isChargeSpell then
                    local cInfo = GetChargesWithOverride(row.spellID, row.baseSpellID)
                    if cInfo and cInfo.currentCharges then
                        if not issecretvalue(cInfo.currentCharges) then
                            row.chargesAvailable = cInfo.currentCharges
                        else
                            row.chargesAvailable = row.maxCharges or 2
                        end
                        if not issecretvalue(cInfo.maxCharges) then
                            row.maxCharges = cInfo.maxCharges
                            local bH = row.cdBar.fullHeight or CONFIG.height
                            row.cdBar.laneHeight = (bH - (cInfo.maxCharges - 1)) / cInfo.maxCharges
                        end
                    else
                        row.chargesAvailable = row.maxCharges or 2
                    end
                    FeedChargeHiddenFrames(row)
                end


            end

            -- Re-apply ECM visibility if PEW timer was blocked by combat
            if ns._pendingECMReapply then
                ns._pendingECMReapply = nil
                ForceViewersAlways()
                ApplyECMVisibility()
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Clear pandemic icon refs so OnUpdate doesn't poll stale target frames
        for _, row in ipairs(cooldownBars) do
            row.cachedPandemicIcon = nil
        end
        lastUnitAuraUpdate = 0
        UpdateBars()
        UpdateVisibility()
        -- Deferred(0) = next frame, guarantees CDM has processed UNIT_TARGET by then
        ScheduleDeferredUpdate(0)
        ScheduleDeferredUpdate(0.05)
        ScheduleDeferredUpdate(0.1)
        ScheduleDeferredUpdate(0.2)
    end
end)

-- Slash commands

SLASH_INFALL1 = "/infall"
SlashCmdList["INFALL"] = function(msg)
    msg = msg:lower():trim()
    
    if msg == "reload" or msg == "r" then
        LoadEssentialCooldowns()
        print("|cff00ff00[Infall]|r Cooldowns reloaded")
        
    elseif msg == "reactive" then
        CONFIG.reactiveIcons = not CONFIG.reactiveIcons
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.reactiveIcons then
            print("|cff00ff00[Infall]|r Reactive icons: |cff00ff00ENABLED|r (icons change colour)")
        else
            print("|cff00ff00[Infall]|r Reactive icons: |cffff0000DISABLED|r (icons stay coloured)")
            for _, row in ipairs(cooldownBars) do
                if row.cooldownFrame then row.cooldownFrame:Hide() end
                if row.innerGlowAnim then row.innerGlowAnim:Stop() end
                if row.glowAnim then row.glowAnim:Stop() end
                if row.iconGlow then row.iconGlow:Hide() end
                if row.innerGlow then row.innerGlow:SetAlpha(0) end
                if row.iconBorder then row.iconBorder:SetColorTexture(0, 0, 0, 1) end
                row.lastCdDurObj = nil
                row.lastChargeDurObj = nil
            end
        end
        UpdateAllIconStates()
        
    elseif msg == "desat" or msg == "desaturate" then
        CONFIG.desaturateOnCooldown = not CONFIG.desaturateOnCooldown
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.desaturateOnCooldown then
            print("|cff00ff00[Infall]|r Cooldown desaturation: |cff00ff00ENABLED|r (icons grey out on cooldown)")
        else
            print("|cff00ff00[Infall]|r Cooldown desaturation: |cffff0000DISABLED|r (icons stay coloured on cooldown)")
        end
        if not CONFIG.desaturateOnCooldown then
            for _, row in ipairs(cooldownBars) do
                row.icon:SetDesaturation(0)
            end
        end
        UpdateBars()
        
    elseif msg == "redshift" or msg == "rs" then
        CONFIG.redshift = not CONFIG.redshift
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.redshift then
            print("|cff00ff00[Infall]|r Redshift: |cff00ff00ENABLED|r (hides when out of combat with no target)")
        else
            print("|cff00ff00[Infall]|r Redshift: |cffff0000DISABLED|r (always visible)")
        end
        UpdateVisibility()
        
    elseif msg == "pandemic" or msg == "pan" then
        CONFIG.pandemicPulse = not CONFIG.pandemicPulse
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.pandemicPulse then
            print("|cff00ff00[Infall]|r Pandemic pulse: |cff00ff00ENABLED|r (target debuffs pulse in refresh window)")
        else
            print("|cff00ff00[Infall]|r Pandemic pulse: |cffff0000DISABLED|r (no pandemic indicator)")
            for _, row in ipairs(cooldownBars) do
                if row.buffPandemicAnim and row.buffPandemicAnim:IsPlaying() then
                    row.buffPandemicAnim:Stop()
                    row.buffBar:SetAlpha(1.0)
                end
            end
        end
        
    elseif msg == "castbar" or msg == "cast" then
        if InCombatLockdown() then
            print("|cffff0000[Infall]|r Cannot toggle cast bar during combat.")
            return
        end

        CONFIG.hideBlizzCastBar = not CONFIG.hideBlizzCastBar
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        ApplyCastBarVisibility()

        if CONFIG.hideBlizzCastBar then
            print("|cff00ff00[Infall]|r Blizzard cast bar: |cffff0000HIDDEN|r")
        else
            print("|cff00ff00[Infall]|r Blizzard cast bar: |cff00ff00VISIBLE|r")
        end
        
    elseif msg == "ecm" then
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Cannot toggle cooldown viewer in combat. Use /infall ecm after combat.")
            return
        end
        CONFIG.hideBlizzECM = not CONFIG.hideBlizzECM
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end

        if ns.ApplyECMVisibility then
            ns.ApplyECMVisibility()
        end

        if CONFIG.hideBlizzECM then
            print("|cff00ff00[Infall]|r Blizzard cooldown viewer: |cffff0000HIDDEN|r")
        else
            print("|cff00ff00[Infall]|r Blizzard cooldown viewer: |cff00ff00VISIBLE|r")
        end
        
    elseif msg == "setup" then
        if InCombatLockdown() then
            print("|cff00ff00[Infall]|r Cannot open settings in combat.")
            return
        end
        if ns.OpenSettings then
            ns.OpenSettings()
        else
            print("|cff00ff00[Infall]|r Settings not loaded yet.")
        end
        
    elseif msg == "lock" then
        if CONFIG.clickthrough then
            print("|cff00ff00[Infall]|r Cannot unlock while clickthrough is enabled. Use /infall clickthrough first.")
            return
        end

        CONFIG.locked = not CONFIG.locked
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.locked then
            print("|cff00ff00[Infall]|r Frame: |cff00ff00LOCKED|r (cannot drag)")
        else
            print("|cff00ff00[Infall]|r Frame: |cffff0000UNLOCKED|r (drag to reposition)")
        end
        
    elseif msg == "reset" then
        if InCombatLockdown() then
            print("|cffff0000[Infall]|r Cannot reset position during combat.")
            return
        end
        
        EH_Parent:ClearAllPoints()
        EH_Parent:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        InfallDB.position = nil
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        print("|cff00ff00[Infall]|r Position reset to centre")
        
    elseif msg:match("^hide") then
        local val = msg:match("^hide%s+(.+)")
        if val then
            local cdID = tonumber(val)
            if cdID then
                CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
                if CONFIG.hiddenCooldownIDs[cdID] then
                    CONFIG.hiddenCooldownIDs[cdID] = nil
                    print("|cff00ff00[Infall]|r Cooldown ID " .. cdID .. ": |cff00ff00VISIBLE|r (until reload)")
                    print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save visibility to your profile")
                else
                    CONFIG.hiddenCooldownIDs[cdID] = true
                    print("|cff00ff00[Infall]|r Cooldown ID " .. cdID .. ": |cffff0000HIDDEN|r (until reload)")
                    print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save visibility to your profile")
                end
                LoadEssentialCooldowns()
            else
                print("|cff00ff00[Infall]|r Usage: /infall hide <cooldownID>  (toggles visibility)")
            end
        else
            print("|cff00ff00[Infall]|r Current bars (cooldownID → spell):")
            for _, row in ipairs(cooldownBars) do
                print("  " .. (row.cooldownID or "?") .. " → " .. (row.spellName or "Unknown") .. " (spellID " .. (row.spellID or "?") .. ")")
            end
            local hiddenList = CONFIG.hiddenCooldownIDs
            if hiddenList and next(hiddenList) then
                print("|cff00ff00[Infall]|r Hidden cooldown IDs:")
                for id, v in pairs(hiddenList) do
                    if v then print("  " .. id) end
                end
            end
            print("|cff00ff00[Infall]|r Usage: /infall hide <cooldownID> to toggle")
        end
        
    elseif msg:match("^pos") then
        local val = msg:match("^pos%s+(.+)")
        if val then
            if InCombatLockdown() then
                print("|cffff0000[Infall]|r Cannot reposition during combat.")
                return
            end
            local parts = {}
            for num in val:gmatch("[%-]?[%d%.]+") do
                table.insert(parts, tonumber(num))
            end
            if parts[1] and parts[2] then
                EH_Parent:ClearAllPoints()
                EH_Parent:SetPoint("CENTER", UIParent, "CENTER", parts[1], parts[2])
                InfallDB.position = { point = "CENTER", relPoint = "CENTER", x = parts[1], y = parts[2] }
                if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
                print("|cff00ff00[Infall]|r Position set to " .. parts[1] .. ", " .. parts[2])
            else
                print("|cff00ff00[Infall]|r Usage: /infall pos <x> <y>  (offset from centre)")
            end
        else
            local point, _, relPoint, x, y = EH_Parent:GetPoint()
            print("|cff00ff00[Infall]|r Current position: " .. (point or "?") .. " " .. string.format("%.1f", x or 0) .. ", " .. string.format("%.1f", y or 0) .. " (usage: /infall pos 200 -300)")
        end
        
    elseif msg == "clickthrough" or msg == "ct" then
        CONFIG.clickthrough = not CONFIG.clickthrough

        if CONFIG.clickthrough then
            EH_Parent:EnableMouse(false)
            CONFIG.locked = true
            print("|cff00ff00[Infall]|r Clickthrough: |cff00ff00ENABLED|r (frame is click through and locked)")
        else
            EH_Parent:EnableMouse(true)
            print("|cff00ff00[Infall]|r Clickthrough: |cffff0000DISABLED|r (frame is interactive)")
        end
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
    elseif msg:match("^gap") then
        local val = msg:match("^gap%s+(.+)")
        if val then
            local n = tonumber(val)
            if n and n >= 0 and n <= 30 then
                CONFIG.iconGap = n
                ApplyLayoutToAllBars()
                print("|cff00ff00[Infall]|r Icon gap set to " .. n .. "px (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.iconGap = " .. n .. "|r")
            else
                print("|cff00ff00[Infall]|r Gap must be between 0 and 30. Usage: /infall gap 0")
            end
        else
            print("|cff00ff00[Infall]|r Icon gap: " .. (CONFIG.iconGap or 10) .. "px (usage: /infall gap 0)")
        end
        
    elseif msg == "bufflayer" or msg == "bl" then
        CONFIG.buffLayerAbove = not CONFIG.buffLayerAbove
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.buffLayerAbove then
            print("|cff00ff00[Infall]|r Buff bars: drawn |cff00ff00ABOVE|r cooldown bars")
        else
            print("|cff00ff00[Infall]|r Buff bars: drawn |cffff9900BELOW|r cooldown bars")
        end
        
        for _, row in ipairs(cooldownBars) do
            ApplyBuffLayer(row)
        end
        
    elseif msg == "icons" then
        CONFIG.hideIcons = not CONFIG.hideIcons
        if ns.SaveCurrentProfile then ns.SaveCurrentProfile() end
        
        if CONFIG.hideIcons then
            print("|cff00ff00[Infall]|r Icons: |cffff0000HIDDEN|r (text only strip for charges/stacks)")
        else
            print("|cff00ff00[Infall]|r Icons: |cff00ff00VISIBLE|r")
        end
        
        ApplyLayoutToAllBars()
        UpdateBars()
        
    elseif msg:match("^scale") then
        local val = msg:match("^scale%s+(.+)")
        if val then
            local n = tonumber(val)
            if n and n >= 0.5 and n <= 3.0 then
                CONFIG.scale = n
                EH_Parent:SetScale(n)
                print("|cff00ff00[Infall]|r Scale set to " .. n .. " (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.scale = " .. n .. "|r")
            else
                print("|cff00ff00[Infall]|r Scale must be between 0.5 and 3.0")
            end
        else
            print("|cff00ff00[Infall]|r Current scale: " .. CONFIG.scale .. " (usage: /infall scale 1.2)")
        end
        
    elseif msg:match("^lines") then
        local val = msg:match("^lines%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.lines = nil
                CreateTimeLines()
                print("|cff00ff00[Infall]|r Time markers: |cffff0000DISABLED|r (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.lines = nil|r")
            else
                local newLines = {}
                for num in val:gmatch("[%d%.]+") do
                    local n = tonumber(num)
                    if n and n > 0 then
                        table.insert(newLines, n)
                    end
                end
                if #newLines > 0 then
                    CONFIG.lines = newLines
                    CreateTimeLines()
                    local str = table.concat(newLines, ", ")
                    print("|cff00ff00[Infall]|r Time markers at: " .. str .. "s (until reload)")
                    print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                    print("|cffaaaaaa  CONFIG.lines = {" .. str .. "}|r")
                else
                    print("|cff00ff00[Infall]|r Invalid input. Usage: /infall lines 1 3 7")
                end
            end
        else
            if CONFIG.lines then
                local t = type(CONFIG.lines) == "table" and CONFIG.lines or {CONFIG.lines}
                print("|cff00ff00[Infall]|r Time markers at: " .. table.concat(t, ", ") .. "s (usage: /infall lines 1 3 7 or /infall lines off)")
            else
                print("|cff00ff00[Infall]|r Time markers: disabled (usage: /infall lines 1 3 7)")
            end
        end
        
    elseif msg:match("^static") then
        local val = msg:match("^static%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.staticHeight = nil
                ApplyLayoutToAllBars()
                print("|cff00ff00[Infall]|r Static height: |cffff0000DISABLED|r (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.staticHeight = nil|r")
            else
                local parts = {}
                for num in val:gmatch("[%d%.]+") do
                    table.insert(parts, tonumber(num))
                end
                if parts[1] and parts[1] >= 40 then
                    CONFIG.staticHeight = parts[1]
                    if parts[2] then
                        CONFIG.staticFrames = math.floor(parts[2])
                    end
                    ApplyLayoutToAllBars()
                    local msg_out = "|cff00ff00[Infall]|r Static height: |cff00ff00" .. CONFIG.staticHeight .. "px|r"
                    if (CONFIG.staticFrames or 0) > 0 then
                        msg_out = msg_out .. " (min " .. CONFIG.staticFrames .. " bars)"
                    end
                    print(msg_out .. " (until reload)")
                    print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                    print("|cffaaaaaa  CONFIG.staticHeight = " .. CONFIG.staticHeight .. "|r")
                    if parts[2] then
                        print("|cffaaaaaa  CONFIG.staticFrames = " .. CONFIG.staticFrames .. "|r")
                    end
                else
                    print("|cff00ff00[Infall]|r Height must be at least 40. Usage: /infall static 150 or /infall static 150 4")
                end
            end
        else
            if CONFIG.staticHeight then
                print("|cff00ff00[Infall]|r Static height: " .. CONFIG.staticHeight .. "px, min frames: " .. (CONFIG.staticFrames or 0) .. " (usage: /infall static 150 or /infall static off)")
            else
                print("|cff00ff00[Infall]|r Static height: disabled (usage: /infall static 150 or /infall static 150 4)")
            end
        end
        
    elseif msg:match("^past") then
        local val = msg:match("^past%s+(.+)")
        if val then
            if val == "off" or val == "none" or val == "0" then
                CONFIG.past = 0
                ApplyLayoutToAllBars()
                print("|cff00ff00[Infall]|r Past region: |cffff0000DISABLED|r (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.past = 0|r")
            else
                local n = tonumber(val)
                if n and n >= 0 and n <= 10 then
                    CONFIG.past = n
                    ApplyLayoutToAllBars()
                    print("|cff00ff00[Infall]|r Past region: |cff00ff00" .. n .. "s|r (until reload)")
                    print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                    print("|cffaaaaaa  CONFIG.past = " .. n .. "|r")
                else
                    print("|cff00ff00[Infall]|r Past must be between 0 and 10. Usage: /infall past 2.5")
                end
            end
        else
            print("|cff00ff00[Infall]|r Past region: " .. CONFIG.past .. "s (usage: /infall past 2.5 or /infall past off)")
        end
        
    elseif msg:match("^nowline") then
        local val = msg:match("^nowline%s+(.+)")
        if val then
            -- Parse: "nowline 2" (width) or "nowline 2 1 1 1 0.7" (width + r g b a)
            local parts = {}
            for num in val:gmatch("[%d%.]+") do
                table.insert(parts, tonumber(num))
            end
            if parts[1] then
                CONFIG.nowLineWidth = math.max(1, math.min(parts[1], 6))
                if parts[2] and parts[3] and parts[4] then
                    CONFIG.nowLineColor = {parts[2], parts[3], parts[4], parts[5] or 0.7}
                end
                ApplyLayoutToAllBars()
                print("|cff00ff00[Infall]|r Now line: width=" .. CONFIG.nowLineWidth .. "px (until reload)")
                print("|cff00ff00[Infall]|r Use |cffffff00/infall setup|r to save to your profile, or add to ClassConfig:")
                print("|cffaaaaaa  CONFIG.nowLineWidth = " .. CONFIG.nowLineWidth .. "|r")
                if parts[2] and parts[3] and parts[4] then
                    local c = CONFIG.nowLineColor
                    print("|cffaaaaaa  CONFIG.nowLineColor = {" .. c[1] .. ", " .. c[2] .. ", " .. c[3] .. ", " .. c[4] .. "}|r")
                end
            else
                print("|cff00ff00[Infall]|r Usage: /infall nowline 2 or /infall nowline 2 1 1 1 0.7")
            end
        else
            print("|cff00ff00[Infall]|r Now line: width=" .. CONFIG.nowLineWidth .. "px (usage: /infall nowline 2 or /infall nowline 2 r g b a)")
        end
        
    else
        print("|cff00ff00[Infall]|r Commands:")
        print("  |cffffff00/infall setup|r - Open the settings panel (all settings, profiles, buff pairing)")
        print("")
        print("|cff00ff00  Feature toggles|r (saved to your profile):")
        print("  /infall reactive - Toggle reactive icon colouring")
        print("  /infall desat - Toggle cooldown desaturation")
        print("  /infall redshift - Toggle Redshift (hide when out of combat with no target)")
        print("  /infall pandemic - Toggle pandemic pulse (target debuffs pulse in refresh window)")
        print("  /infall castbar - Toggle Blizzard cast bar visibility")
        print("  /infall ecm - Toggle Blizzard cooldown viewer visibility")
        print("  /infall bufflayer - Toggle buff bars above/below cooldown bars")
        print("  /infall icons - Toggle icon visibility (collapse to text only strip)")
        print("  /infall lock - Toggle frame lock (prevents dragging)")
        print("  /infall clickthrough - Toggle click through mode (autolocks frame)")
        print("|cff00ff00  Layout preview|r (session only, use |cffffff00/infall setup|r to save to your profile):")
        print("  /infall scale [0.5-3.0] - Preview frame scale")
        print("  /infall gap [0-30] - Preview icon-to-bar gap")
        print("  /infall lines [s1 s2 ...] - Preview time markers (ie /infall lines 1 3 7)")
        print("  /infall static [height] [minBars] - Preview fixed frame height")
        print("  /infall past [0-10] - Preview past timeline duration")
        print("  /infall nowline [width] [r g b a] - Preview now line appearance")
        print("  /infall hide [cooldownID] - Preview hiding a bar (list bars if no ID)")
        print("|cff00ff00  Position|r (saved per character):")
        print("  /infall pos [x] [y] - Set exact position (offset from centre)")
        print("  /infall reset - Reset position to centre")
        print("  /infall reload - Reload cooldowns")
    end
end

-- Expose for Settings.lua
ns.LoadEssentialCooldowns = LoadEssentialCooldowns
ns.ApplyLayoutToAllBars = ApplyLayoutToAllBars
ns.cooldownBars = cooldownBars

ns.ShowVariantPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.variantNameText and row.barTextOverlay then
            ApplyFont(row.variantNameText, CONFIG.variantTextSize or (CONFIG.fontSize - 2))
            row.variantNameText:SetTextColor(unpack(CONFIG.variantTextColor))
            row.variantNameText:ClearAllPoints()
            row.variantNameText:SetPoint(CONFIG.variantTextAnchor, row.barTextOverlay, CONFIG.variantTextRelPoint, CONFIG.variantTextOffsetX, CONFIG.variantTextOffsetY)
            row.variantNameText:SetText("Variant Name Anchor")
            row.variantNameText:Show()
        end
    end
end

ns.HideVariantPreview = function()
    for _, row in ipairs(cooldownBars) do
        if row.variantNameText then
            row.variantNameText:Hide()
        end
    end
end
