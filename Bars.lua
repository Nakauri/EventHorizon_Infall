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

local function GetEmpowerStageColor(stage)
    if stage == 1 then return CONFIG.empowerStage1Color
    elseif stage == 2 then return CONFIG.empowerStage2Color
    elseif stage == 3 then return CONFIG.empowerStage3Color
    elseif stage == 4 then return CONFIG.empowerStage4Color
    end
    return CONFIG.empowerStage4Color
end

local function HideEmpowerStageTex(row)
    if row and row.empowerStageTex then
        for _, tex in ipairs(row.empowerStageTex) do
            tex:Hide()
        end
    end
end

-- Offscreen because OnCooldownDone does not fire on zero alpha frames.
local hiddenCDParent = CreateFrame("Frame", nil, UIParent)
hiddenCDParent:SetSize(1, 1)
hiddenCDParent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
hiddenCDParent:Show()

-- GCD hidden Cooldown frame.
-- OnCooldownDone fires when GCD ends.
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

-- InvertedAlphaCurve: opposite of AlphaCurve.
-- Visible when timer is NOT active, invisible when active.
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

local CreateHiddenCooldown
local FeedHiddenCooldown
local UpdateChargeState

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

-- Try GetSpellCharges on spellID; if nil, retry with override spell.
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

-- Scans all CDM spells on login and caches charge info to SavedVariables.
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
                if isEmpowered then
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
            if activeCast then
                if activeCast.pastSlide then
                    DetachPastSlide(activeCast.pastSlide)
                end
                if activeCast.row and activeCast.row ~= targetRow then
                    activeCast.row.castTex:Hide()
                    HideEmpowerStageTex(activeCast.row)
                end
            end

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
                -- Non-empowered: show castTex, hide any leftover stage textures
                HideEmpowerStageTex(targetRow)
                targetRow.castTex:SetVertexColor(unpack(color))
                targetRow.castTex:Show()
            end
        else
            -- Casting an untracked spell, clean up any previous tracked cast
            if activeCast then
                if activeCast.pastSlide then
                    DetachPastSlide(activeCast.pastSlide)
                end
                if activeCast.row then
                    activeCast.row.castTex:Hide()
                    HideEmpowerStageTex(activeCast.row)
                end
            end
            activeCast = nil
        end
    else
        if activeCast then
            if activeCast.pastSlide then
                DetachPastSlide(activeCast.pastSlide)
            end
            if activeCast.row then
                activeCast.row.castTex:Hide()
                HideEmpowerStageTex(activeCast.row)
            end
        end
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
            -- Non-empowered: single castTex from now to remaining
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
    else
        -- Cast completed, detach past slide
        if activeCast.pastSlide then
            DetachPastSlide(activeCast.pastSlide)
        end
        activeCast.row.castTex:Hide()
        HideEmpowerStageTex(activeCast.row)
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
                        -- ATTACHED: right edge pinned at now line, width grows
                        local age = now - slide.startTime
                        local w = math.min(age * pxPerSec, pastWidth)
                        w = math.max(1, w)
                        slide.tex:SetWidth(w)
                        slide.tex:SetHeight(slide.height)
                    else
                        -- DETACHED: whole block slides left, width frozen
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
        if row.innerGlowAnim then row.innerGlowAnim:Play() end
        if row.glowAnim then row.glowAnim:Play() end
        if row.iconGlow then row.iconGlow:Show() end
    else
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
    row.chargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    if row.chargeHelperBar then row.chargeHelperBar:SetVertexColor(unpack(CONFIG.cooldownColor)) end
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
        row.chargeBar:SetFrameLevel(baseLevel + 1)
        row.buffBar:SetFrameLevel(baseLevel + 3)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 4)
        row.castBar:SetFrameLevel(baseLevel + 5)
        row.gcdBar:SetFrameLevel(baseLevel + 6)
    else
        -- Buff below cooldown
        row.buffBar:SetFrameLevel(baseLevel + 1)
        row.buffBarOverlay:SetFrameLevel(baseLevel + 2)
        row.cdBar:SetFrameLevel(baseLevel + 3)
        row.chargeBar:SetFrameLevel(baseLevel + 3)
        row.castBar:SetFrameLevel(baseLevel + 5)
        row.gcdBar:SetFrameLevel(baseLevel + 6)
    end
    -- Past clip frames mirror their future counterparts' frame levels
    if row.pastCdClip then
        row.pastCdClip:SetFrameLevel(row.cdBar:GetFrameLevel())
    end
    if row.pastBuffClip then
        row.pastBuffClip:SetFrameLevel(row.buffBar:GetFrameLevel())
    end
    if row.pastOverlayClip then
        row.pastOverlayClip:SetFrameLevel(row.buffBarOverlay:GetFrameLevel())
    end
    if row.pastCastClip then
        row.pastCastClip:SetFrameLevel(row.castBar:GetFrameLevel())
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
        if row.chargeBar then row.chargeBar:SetMinMaxValues(0, CONFIG.future) end
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
    
    -- Inner glow for procs
    row.innerGlow = row.iconContainer:CreateTexture(nil, "OVERLAY")
    row.innerGlow:SetAllPoints(row.iconContainer)
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
    row.iconGlow:SetAllPoints(row.iconContainer)
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
    
    row.cdBar = CreateFrame("StatusBar", nil, row)
    row.cdBar:SetSize(futureWidth, CONFIG.height)
    row.cdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.cdBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.cdBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    row.cdBar:SetMinMaxValues(0, CONFIG.future)
    row.cdBar:SetOrientation("HORIZONTAL")
    row.cdBar:GetStatusBarTexture():SetHorizTile(false)
    row.cdBar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(row.cdBar)
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
    
    row.pastCdClip = CreatePastClip(baseLevel + 1)       -- matches cdBar/chargeBar initial level
    row.pastBuffClip = CreatePastClip(baseLevel + 3)      -- matches buffBar initial level
    row.pastOverlayClip = CreatePastClip(baseLevel + 4)   -- matches buffBarOverlay initial level
    row.pastCastClip = CreatePastClip(baseLevel + 5)      -- matches castBar initial level
    
    -- Sliding past markers
    row.pastSlides = {}

    -- Hidden Cooldown frames. Fire OnCooldownDone when their timer reaches zero.
    CreateHiddenCooldown = CreateHiddenCooldown or function(rowRef, timerType)
        local cd = CreateFrame("Cooldown", nil, hiddenCDParent, "CooldownFrameTemplate")
        cd:SetAllPoints(hiddenCDParent)
        cd:SetDrawSwipe(false)
        cd:SetDrawBling(false)
        cd:SetDrawEdge(false)
        cd:SetHideCountdownNumbers(true)
        cd:Show()
        cd.timerType = timerType
        cd.rowSpellID = rowRef.spellID

        cd:SetScript("OnCooldownDone", function(self)
            if timerType == "cd" then
                if rowRef.isChargeSpell then
                    if rowRef.activeDepletedSlide then
                        DetachPastSlide(rowRef.activeDepletedSlide)
                        rowRef.activeDepletedSlide = nil
                    end
                    if UpdateChargeState then UpdateChargeState(rowRef) end
                    if UpdateDesaturation then UpdateDesaturation(rowRef) end
                else
                    if rowRef.activeCdSlide then
                        DetachPastSlide(rowRef.activeCdSlide)
                        rowRef.activeCdSlide = nil
                    end
                    rowRef.activeCooldown = nil
                    rowRef.cdBar:Hide()
                    if rowRef.cooldownFrame then rowRef.cooldownFrame:Hide() end
                    if UpdateDesaturation then UpdateDesaturation(rowRef) end
                end
            elseif timerType == "charge" then
                if rowRef.activeChargeSlide then
                    DetachPastSlide(rowRef.activeChargeSlide)
                    rowRef.activeChargeSlide = nil
                end
                rowRef.chargesAvailable = math.min((rowRef.chargesAvailable or 0) + 1, rowRef.maxCharges or 2)
                if UpdateChargeState then UpdateChargeState(rowRef) end
                if UpdateDesaturation then UpdateDesaturation(rowRef) end
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

    local hiddenKeys = {
        cd    = { frame = "hidden_cd",      ptr = "lastPtr_cd" },
        charge = { frame = "hidden_charge", ptr = "lastPtr_charge" },
        buff  = { frame = "hidden_buff",    ptr = "lastPtr_buff" },
        overlay = { frame = "hidden_overlay", ptr = "lastPtr_overlay" },
    }

    FeedHiddenCooldown = FeedHiddenCooldown or function(rowRef, timerType, durObj)
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

    row.hidden_cd = CreateHiddenCooldown(row, "cd")
    row.hidden_charge = CreateHiddenCooldown(row, "charge")
    row.hidden_buff = CreateHiddenCooldown(row, "buff")
    row.hidden_overlay = CreateHiddenCooldown(row, "overlay")

    row.lastPtr_cd = nil
    row.lastPtr_charge = nil
    row.lastPtr_buff = nil
    row.lastPtr_overlay = nil
    
    -- Charge bar (bottom half), anchored to row directly.
    row.chargeBar = CreateFrame("StatusBar", nil, row)
    row.chargeBar:SetSize(futureWidth, (CONFIG.height / 2) - 0.5)
    row.chargeBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, -((CONFIG.height / 2) - 0.5 + 1))
    row.chargeBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.chargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    row.chargeBar:SetMinMaxValues(0, CONFIG.future)
    row.chargeBar:SetOrientation("HORIZONTAL")
    row.chargeBar:GetStatusBarTexture():SetHorizTile(false)
    row.chargeBar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(row.chargeBar)
    row.chargeBar:SetFrameLevel(row:GetFrameLevel() + 1)
    
    row.chargeBar:Hide()
    
    -- Charge helper bar (static block representing one queued recharge at 0 charges).
    row.chargeHelperBar = row.cdBar:CreateTexture(nil, "ARTWORK")
    row.chargeHelperBar:SetSize(1, (CONFIG.height / 2) - 0.5)
    row.chargeHelperBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, -((CONFIG.height / 2) - 0.5 + 1))
    row.chargeHelperBar:SetTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.chargeHelperBar:SetVertexColor(unpack(CONFIG.cooldownColor))
    row.chargeHelperBar:Hide()
    
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
    
    -- castBar alias for ApplyBuffLayer frame level management. Not a StatusBar.
    row.castBar = row.castFrame
    
    -- Buff bar (primary)
    row.buffBar = CreateFrame("StatusBar", nil, row)
    row.buffBar:SetSize(futureWidth, CONFIG.height)
    row.buffBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.buffBar:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBar:SetMinMaxValues(0, CONFIG.future)
    row.buffBar:SetOrientation("HORIZONTAL")
    row.buffBar:GetStatusBarTexture():SetHorizTile(false)
    row.buffBar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(row.buffBar)
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
    row.buffBarOverlay = CreateFrame("StatusBar", nil, row)
    row.buffBarOverlay:SetSize(futureWidth, CONFIG.height)
    row.buffBarOverlay:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.buffBarOverlay:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.buffBarOverlay:SetStatusBarColor(unpack(CONFIG.buffColor))
    row.buffBarOverlay:SetMinMaxValues(0, CONFIG.future)
    row.buffBarOverlay:SetOrientation("HORIZONTAL")
    row.buffBarOverlay:GetStatusBarTexture():SetHorizTile(false)
    row.buffBarOverlay:GetStatusBarTexture():SetVertTile(false)
    CrispBar(row.buffBarOverlay)
    row.buffBarOverlay:SetFrameLevel(row:GetFrameLevel() + 4)
    row.buffBarOverlay:Hide()
    
    -- Cooldown swirl frame. Uses plain "Cooldown" (not CooldownFrameTemplate
    -- which is a secure template that causes taint).
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
    row.gcdBar = CreateFrame("StatusBar", nil, row)
    row.gcdBar:SetSize(futureWidth, CONFIG.height)
    row.gcdBar:SetPoint("TOPLEFT", row, "TOPLEFT", nowOffset, 0)
    row.gcdBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
    row.gcdBar:SetStatusBarColor(unpack(CONFIG.gcdColor))
    row.gcdBar:SetMinMaxValues(0, CONFIG.future)
    row.gcdBar:SetOrientation("HORIZONTAL")
    row.gcdBar:GetStatusBarTexture():SetHorizTile(false)
    row.gcdBar:GetStatusBarTexture():SetVertTile(false)
    CrispBar(row.gcdBar)
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
    
    if useStatic then
        EH_Parent:SetHeight(CONFIG.staticHeight)
        local availableHeight = CONFIG.staticHeight - CONFIG.paddingTop - CONFIG.paddingBottom
        local dynamicBarHeight = (availableHeight - (CONFIG.spacing * (numBars - 1))) / numBars
        dynamicBarHeight = math.max(dynamicBarHeight, 4) -- floor so bars don't vanish
        
        for i, row in ipairs(cooldownBars) do
            row:SetHeight(dynamicBarHeight)
            row.cdBar.fullHeight = dynamicBarHeight
            local maxC = row.maxCharges or 2
            row.cdBar.laneHeight = (dynamicBarHeight - (maxC - 1)) / maxC
            row.chargeBar:SetHeight(row.cdBar.laneHeight)
            if row.chargeHelperBar then
                row.chargeHelperBar:SetHeight(row.cdBar.laneHeight)
            end

            if row.isChargeSpell then
                local lH = row.cdBar.laneHeight
                local bottomY = -(dynamicBarHeight - lH)
                row.cdBar:SetHeight(lH)
                -- Resize wrappers and reposition bars within them
                if row.depletedWrapper then
                    row.depletedWrapper:SetHeight(dynamicBarHeight)
                    row.notDepletedWrapper:SetHeight(dynamicBarHeight)
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
                row.cdBar:SetHeight(dynamicBarHeight)
            end
            row.castFrame:SetHeight(dynamicBarHeight)
            row.buffBar:SetHeight(dynamicBarHeight)
            row.buffBarOverlay:SetHeight(dynamicBarHeight)
            row.gcdBar:SetHeight(dynamicBarHeight)
            row.gcdSpark:SetHeight(dynamicBarHeight)
            if row.nowLine then
                row.nowLine:SetHeight(dynamicBarHeight)
            end
            for _, clip in ipairs({row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastCastClip}) do
                if clip then clip:SetHeight(dynamicBarHeight) end
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((i - 1) * (dynamicBarHeight + CONFIG.spacing)))
        end
    else
        -- Normal mode: restore standard bar heights and positions
        for i, row in ipairs(cooldownBars) do
            row:SetHeight(CONFIG.height)
            row.cdBar.fullHeight = CONFIG.height
            local maxC = row.maxCharges or 2
            row.cdBar.laneHeight = (CONFIG.height - (maxC - 1)) / maxC
            row.chargeBar:SetHeight(row.cdBar.laneHeight)
            if row.chargeHelperBar then
                row.chargeHelperBar:SetHeight(row.cdBar.laneHeight)
            end

            if row.isChargeSpell then
                local lH = row.cdBar.laneHeight
                local bottomY = -(CONFIG.height - lH)
                row.cdBar:SetHeight(lH)
                if row.depletedWrapper then
                    row.depletedWrapper:SetHeight(CONFIG.height)
                    row.notDepletedWrapper:SetHeight(CONFIG.height)
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
                row.cdBar:SetHeight(CONFIG.height)
            end
            row.castFrame:SetHeight(CONFIG.height)
            row.buffBar:SetHeight(CONFIG.height)
            row.buffBarOverlay:SetHeight(CONFIG.height)
            row.gcdBar:SetHeight(CONFIG.height)
            row.gcdSpark:SetHeight(CONFIG.height)
            if row.nowLine then
                row.nowLine:SetHeight(CONFIG.height)
            end
            for _, clip in ipairs({row.pastCdClip, row.pastBuffClip, row.pastOverlayClip, row.pastCastClip}) do
                if clip then clip:SetHeight(CONFIG.height) end
            end
            
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", EH_Parent, "TOPLEFT", CONFIG.paddingLeft, -CONFIG.paddingTop - ((i - 1) * (CONFIG.height + CONFIG.spacing)))
        end
        
        local contentHeight = (numBars * CONFIG.height) + ((numBars - 1) * CONFIG.spacing)
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
                if frame.cooldownID then
                    cachedCooldownViewerFrames[frame.cooldownID] = frame
                end
            end
        end
    end

    for _, viewerName in ipairs(buffViewerNames) do
        local iter, pool, first = ScanViewer(viewerName)
        if iter then
            for frame in iter, pool, first do
                if frame.cooldownID then
                    cachedBuffViewerFrames[frame.cooldownID] = frame
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
        end
    end
    
    -- Mirror ECM icon texture
    if not CONFIG.hideIcons and ecmFrame.Icon then
        local texOk, tex = pcall(ecmFrame.Icon.GetTexture, ecmFrame.Icon)
        if texOk and tex then
            row.icon:SetTexture(tex)
        end
    end
    
    -- Charge text (secret passthrough via SetText)
    if row.hasCharges then
        local chargeOk, chargeCount = pcall(function() return ecmFrame.cooldownChargesCount end)
        if chargeOk and chargeCount ~= nil then
            row.chargeText:SetText(chargeCount)
            row.chargeText:Show()
        else
            row.chargeText:SetText("")
            row.chargeText:Hide()
        end
    else
        row.chargeText:SetText("")
        row.chargeText:Hide()
    end
end

local function UpdateRowCooldown(row)
    if row.isChargeSpell then return end
    
    local successCD, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID)
    
    -- isOnGCD is NeverSecret. When true, only the GCD is active.
    local cdInfoSuccess, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
    local isOnGCD = cdInfoSuccess and cdInfo and cdInfo.isOnGCD
    
    if successCD and cdDurObj and not isOnGCD then
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
    end
end

-- Bar display is curve-driven in OnUpdate via wrapper frame alpha.
UpdateChargeState = function(row)
    if not row.isChargeSpell then
        row.chargeBar:Hide()
        if row.chargeHelperBar then
            row.chargeHelperBar:Hide()

        end
        return
    end

    -- Clear so the OnUpdate fill code does not animate hidden bars.
    row.activeCooldown = nil

    -- Icon cooldown swirl
    local cdOk, cdDurObj = pcall(C_Spell.GetSpellCooldownDuration, row.spellID)
    local chargeOk, chargeDurObj = pcall(C_Spell.GetSpellChargeDuration, row.spellID)

    local cdInfoOk, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
    local isOnGCD = cdInfoOk and cdInfo and cdInfo.isOnGCD

    -- Cache DurObjs for OnUpdate (avoids re-fetching the same APIs per frame)
    row._cachedCdDurObj = cdDurObj
    row._cachedChargeDurObj = chargeDurObj

    -- Feed hidden frames for past slide edge detection (event-driven, not per-frame)
    -- Don't GCD-filter when a charge is recharging (the CD is real, not just GCD)
    local hiddenCdObj = cdDurObj
    if isOnGCD and not chargeDurObj then hiddenCdObj = nil end
    FeedHiddenCooldown(row, "cd", hiddenCdObj)
    FeedHiddenCooldown(row, "charge", chargeDurObj)

    -- GCD filter for icon swirl only
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
                                local aOk, aData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unitHint, buffFrame.auraInstanceID)
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
                            if mapIdx == 1 and not primaryBuff then
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
        local durSuccess, durObj = pcall(C_UnitAuras.GetAuraDuration, primaryBuff.unit, primaryBuff.frame.auraInstanceID)
        -- Retry on target if player lookup failed (debuffs paired as "player")
        if (not durSuccess or not durObj) and primaryBuff.unit ~= "target" then
            local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, "target", primaryBuff.frame.auraInstanceID)
            if rOk and rDur then
                durSuccess, durObj = rOk, rDur
                primaryBuff.unit = "target"
            end
        end

        if durSuccess and durObj then
            row.activeBuffDuration = durObj
            
            if primaryBuff.unit == "target" and CONFIG.pandemicPulse then
                local pandemicIcon = primaryBuff.frame.PandemicIcon
                if pandemicIcon then
                    row.cachedPandemicIcon = pandemicIcon
                end
            end
            
            if primaryBuff.hasCustomColor then
                row.buffBar:SetStatusBarColor(unpack(primaryBuff.color))
                row.resolvedBuffColor = primaryBuff.color
            elseif primaryBuff.unit == "target" then
                row.buffBar:SetStatusBarColor(unpack(CONFIG.debuffColor))
                row.resolvedBuffColor = CONFIG.debuffColor
            elseif primaryBuff.unit == "pet" then
                row.buffBar:SetStatusBarColor(unpack(CONFIG.petBuffColor))
                row.resolvedBuffColor = CONFIG.petBuffColor
            else
                row.buffBar:SetStatusBarColor(unpack(primaryBuff.color))
                row.resolvedBuffColor = primaryBuff.color
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
    end

    -- Overlay lane → buffBarOverlay
    if overlayBuff and row.buffBarOverlay then
        local durSuccess2, durObj2 = pcall(C_UnitAuras.GetAuraDuration, overlayBuff.unit, overlayBuff.frame.auraInstanceID)
        if (not durSuccess2 or not durObj2) and overlayBuff.unit ~= "target" then
            local rOk, rDur = pcall(C_UnitAuras.GetAuraDuration, "target", overlayBuff.frame.auraInstanceID)
            if rOk and rDur then
                durSuccess2, durObj2 = rOk, rDur
                overlayBuff.unit = "target"
            end
        end

        if durSuccess2 and durObj2 then
            row.activeBuffOverlayDuration = durObj2

            local resolvedOverlayColor
            if overlayBuff.hasCustomColor then
                resolvedOverlayColor = overlayBuff.color
            elseif overlayBuff.unit == "target" then
                resolvedOverlayColor = CONFIG.debuffColor
            elseif overlayBuff.unit == "pet" then
                resolvedOverlayColor = CONFIG.petBuffColor
            else
                resolvedOverlayColor = overlayBuff.color or CONFIG.buffColor
            end
            row.resolvedOverlayColor = resolvedOverlayColor
            row.buffBarOverlay:SetStatusBarColor(unpack(resolvedOverlayColor))

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

    local stackMapping = CONFIG.stackMappings and CONFIG.stackMappings[row.cooldownID]
    if not stackMapping then
        row.stackText:Hide()
        return
    end
    
    local buffFrame = buffViewerFrames[stackMapping.buffCooldownID]
    if buffFrame and buffFrame.auraInstanceID ~= nil then
        local unit = stackMapping.unit or buffFrame.auraDataUnit or "player"

        local ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, buffFrame.auraInstanceID)
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
            row.icon:SetDesaturation(1)
        end
    else
        row.icon:SetDesaturation(0)
    end
end

local lastUpdateBarsTime = 0

local function UpdateBars()
    local now = GetTime()
    if now - lastUpdateBarsTime < 0.016 then return end
    lastUpdateBarsTime = now

    local cooldownViewerFrames, buffViewerFrames = ScanViewerFrames()

    for _, row in ipairs(cooldownBars) do
        MirrorECMState(row, cooldownViewerFrames)
        UpdateRowCooldown(row)
        UpdateChargeState(row)
        UpdateBuffState(row, buffViewerFrames)
        UpdateStackText(row, buffViewerFrames)
        UpdateDesaturation(row)
    end
end

-- OnUpdate helpers (defined once to avoid per-frame closure allocation)
local function EvalDualAlpha(durObj, curve, invertedCurve)
    return durObj:EvaluateRemainingDuration(curve), durObj:EvaluateRemainingDuration(invertedCurve)
end

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
EH_Parent:SetScript("OnUpdate", function(self, elapsed)
    updateTimer = updateTimer + elapsed

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

            -- Buff bar fill
            if row.activeBuffDuration then
                local ok, remaining = pcall(row.activeBuffDuration.GetRemainingDuration, row.activeBuffDuration)
                if ok then
                    row.buffBar:SetValue(remaining, interp)
                else
                    row.buffBar:Hide()
                end
            end

            -- Buff overlay bar fill
            if row.activeBuffOverlayDuration and row.buffBarOverlay then
                local ok, remaining = pcall(row.activeBuffOverlayDuration.GetRemainingDuration, row.activeBuffOverlayDuration)
                if ok then
                    row.buffBarOverlay:SetValue(remaining, interp)
                else
                    row.buffBarOverlay:Hide()
                end
            end

            -- Curve-driven charge bar display via wrapper frame alpha.
            if row.isChargeSpell and row.depletedWrapper then
                -- DurObjs cached from UpdateChargeState (event-driven)
                local cdDurObj = row._cachedCdDurObj
                local chargeDurObj = row._cachedChargeDurObj

                -- GCD filter: only when no charge is recharging (CD would be just GCD)
                if not chargeDurObj and gcdActive then
                    local cdInfoOk, cdInfo = pcall(C_Spell.GetSpellCooldown, row.spellID)
                    local isOnGCD = cdInfoOk and cdInfo and cdInfo.isOnGCD
                    if isOnGCD then cdDurObj = nil end
                end

                -- Wrapper alpha: depleted vs not-depleted
                if cdDurObj and AlphaCurve and InvertedAlphaCurve then
                    local ok, a1, a2 = pcall(EvalDualAlpha, cdDurObj, AlphaCurve, InvertedAlphaCurve)
                    if ok then
                        row.depletedWrapper:SetAlpha(a1)
                        row.notDepletedWrapper:SetAlpha(a2)
                    end
                else
                    row.depletedWrapper:SetAlpha(0)
                    row.notDepletedWrapper:SetAlpha(1)
                end

                -- Child bar alpha: visible when a charge is recharging
                if chargeDurObj and AlphaCurve then
                    local ok, chargeAlpha = pcall(chargeDurObj.EvaluateRemainingDuration, chargeDurObj, AlphaCurve)
                    if ok then
                        row.depletedChargeBar:SetAlpha(chargeAlpha)
                        row.normalChargeBar:SetAlpha(chargeAlpha)
                        row.depletedHelperBar:SetAlpha(chargeAlpha)
                        -- 3+ charge per-lane alpha (parented to bar, not wrapper)
                        if row.maxCharges and row.maxCharges > 2 then
                            local current = row.chargesAvailable or row.maxCharges
                            -- Bottom lane helper in notDepletedWrapper
                            if row.notDepletedHelperBar then
                                if current < row.maxCharges - 1 then
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
                                        if current < row.maxCharges - j then
                                            ml.depletedChargeBar:SetAlpha(chargeAlpha)
                                        else
                                            ml.depletedChargeBar:SetAlpha(0)
                                        end
                                        if current < row.maxCharges - j - 1 then
                                            ml.depletedHelperBar:SetAlpha(chargeAlpha)
                                        else
                                            ml.depletedHelperBar:SetAlpha(0)
                                        end
                                    end
                                end
                            end
                        end
                    end
                else
                    row.depletedChargeBar:SetAlpha(0)
                    row.normalChargeBar:SetAlpha(0)
                    row.depletedHelperBar:SetAlpha(0)
                    if row.notDepletedHelperBar then row.notDepletedHelperBar:SetAlpha(0) end
                    if row.middleLanes then
                        for j = 1, #row.middleLanes do
                            local ml = row.middleLanes[j]
                            ml.depletedChargeBar:SetAlpha(0)
                            ml.depletedHelperBar:SetAlpha(0)
                        end
                    end
                end

                -- Fill animation
                if chargeDurObj then
                    local ok, remaining = pcall(chargeDurObj.GetRemainingDuration, chargeDurObj)
                    if ok then
                        row.depletedChargeBar:SetValue(remaining, interp)
                        row.normalChargeBar:SetValue(remaining, interp)
                        if row.middleLanes then
                            for j = 1, #row.middleLanes do
                                row.middleLanes[j].depletedChargeBar:SetValue(remaining, interp)
                            end
                        end
                    end
                end
                if cdDurObj then
                    local ok, remaining = pcall(cdDurObj.GetRemainingDuration, cdDurObj)
                    if ok then row.depletedCdBar:SetValue(remaining, interp) end
                end

                -- Charge past slides (depleted + recharge lanes)
                local laneH = row.cdBar.laneHeight or ((CONFIG.height / 2) - 0.5)

                local cdActive = row.hidden_cd and row.hidden_cd:IsShown()
                if cdActive and not row.activeDepletedSlide then
                    row.activeDepletedSlide = SpawnPastSlide(row, row.pastCdClip, CONFIG.cooldownColor, laneH, 0)
                elseif not cdActive and row.activeDepletedSlide then
                    DetachPastSlide(row.activeDepletedSlide)
                    row.activeDepletedSlide = nil
                end

                local chargeActive = row.hidden_charge and row.hidden_charge:IsShown()
                if chargeActive and not row.activeChargeSlide then
                    local barH = row.cdBar.fullHeight or CONFIG.height
                    row.activeChargeSlide = SpawnPastSlide(row, row.pastCdClip, CONFIG.cooldownColor, laneH, barH - laneH)
                elseif not chargeActive and row.activeChargeSlide then
                    DetachPastSlide(row.activeChargeSlide)
                    row.activeChargeSlide = nil
                end

                -- Middle lanes at 10Hz (API calls are expensive)
                row._chargeRefeedTimer = (row._chargeRefeedTimer or 0) + updateTimer
                if row._chargeRefeedTimer >= 0.1 then
                    row._chargeRefeedTimer = 0

                    -- Middle lanes (3+ charges): update visibility and past slides
                    if row.middleLanes and row.maxCharges and row.maxCharges > 2 then
                        -- chargesAvailable from API (backup to CDM path in MirrorECMState)
                        local cInfo = GetChargesWithOverride(row.spellID, row.baseSpellID)
                        if cInfo and cInfo.currentCharges then
                            if issecretvalue and not issecretvalue(cInfo.currentCharges) then
                                row.chargesAvailable = cInfo.currentCharges
                            end
                        end
                        local current = row.chargesAvailable or row.maxCharges
                        local slotPx = row._chargeSlotPx or 0

                        -- Middle lane charge bar repositioning: offset 0 when helper hidden
                        for j = 1, row.maxCharges - 2 do
                            local ml = row.middleLanes[j]
                            if ml then
                                local helperVisible = current < row.maxCharges - j - 1
                                local newOffset = helperVisible and (j * slotPx) or 0
                                if ml._lastChargeOffset ~= newOffset then
                                    local laneY = -(j * (laneH + 1))
                                    ml.depletedChargeBar:ClearAllPoints()
                                    ml.depletedChargeBar:SetPoint("TOPLEFT", row.depletedWrapper, "TOPLEFT", newOffset, laneY)
                                    ml._lastChargeOffset = newOffset
                                end

                                -- Middle lane past slide
                                local mlActive = current < row.maxCharges - j
                                if mlActive and not ml.activeSlide then
                                    local laneYOffset = j * (laneH + 1)
                                    ml.activeSlide = SpawnPastSlide(row, row.pastCdClip, CONFIG.cooldownColor, laneH, laneYOffset)
                                elseif not mlActive and ml.activeSlide then
                                    DetachPastSlide(ml.activeSlide)
                                    ml.activeSlide = nil
                                end
                            end
                        end

                        -- Bottom lane notDepletedHelperBar: dynamic width + normalChargeBar offset
                        if row.notDepletedHelperBar then
                            local ndHelperCount = math.max(0, row.maxCharges - 1 - current)
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
            end

            -- Buff past slide
            local buffActive = row.hidden_buff and row.hidden_buff:IsShown() or false
            if buffActive and not row.activeBuffSlide then
                row.activeBuffSlide = SpawnPastSlide(row, row.pastBuffClip, row.resolvedBuffColor or CONFIG.buffColor, row.cdBar.fullHeight or CONFIG.height, 0)
            elseif not buffActive and row.activeBuffSlide then
                DetachPastSlide(row.activeBuffSlide)
                row.activeBuffSlide = nil
            end
            if row.activeBuffSlide and not row.activeBuffSlide.detachTime and row.resolvedBuffColor then
                row.activeBuffSlide.color = row.resolvedBuffColor
                row.activeBuffSlide.tex:SetVertexColor(row.resolvedBuffColor[1], row.resolvedBuffColor[2], row.resolvedBuffColor[3], row.resolvedBuffColor[4] or 0.7)
            end

            -- Overlay past slide
            local overlayActive = row.hidden_overlay and row.hidden_overlay:IsShown() or false
            if overlayActive and not row.activeOverlaySlide then
                row.activeOverlaySlide = SpawnPastSlide(row, row.pastOverlayClip, row.resolvedOverlayColor or CONFIG.buffColor, row.cdBar.fullHeight or CONFIG.height, 0)
            elseif not overlayActive and row.activeOverlaySlide then
                DetachPastSlide(row.activeOverlaySlide)
                row.activeOverlaySlide = nil
            end
            if row.activeOverlaySlide and not row.activeOverlaySlide.detachTime and row.resolvedOverlayColor then
                row.activeOverlaySlide.color = row.resolvedOverlayColor
                row.activeOverlaySlide.tex:SetVertexColor(row.resolvedOverlayColor[1], row.resolvedOverlayColor[2], row.resolvedOverlayColor[3], row.resolvedOverlayColor[4] or 0.7)
            end

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

    bar.lastChargeDurObj = nil
    bar.lastCdDurObj = nil
    
    bar.lastPtr_cd = nil
    bar.lastPtr_charge = nil
    bar.lastPtr_buff = nil
    bar.lastPtr_overlay = nil
    bar._cachedCdDurObj = nil
    bar._cachedChargeDurObj = nil

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
    
    bar.icon:SetDesaturation(0)
    bar.cdBar:Hide()
    bar.chargeBar:Hide()
    bar.buffBar:Hide()
    if bar.buffBarOverlay then bar.buffBarOverlay:Hide() end
    if bar.chargeHelperBar then bar.chargeHelperBar:Hide() end
    if bar.cooldownFrame then bar.cooldownFrame:Hide() end
    if bar.castTex then bar.castTex:Hide() end
    HideEmpowerStageTex(bar)
    if bar.depletedWrapper then bar.depletedWrapper:Hide() end
    if bar.notDepletedWrapper then bar.notDepletedWrapper:Hide() end
    if bar.middleLanes then
        for _, ml in ipairs(bar.middleLanes) do
            ml.depletedChargeBar:SetAlpha(0)
            ml.depletedHelperBar:SetAlpha(0)
            ml._lastChargeOffset = nil
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
    if bar.middleLanes then
        for _, ml in ipairs(bar.middleLanes) do
            ml.activeSlide = nil
        end
    end
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

    if bar.buffPandemicAnim and bar.buffPandemicAnim:IsPlaying() then
        bar.buffPandemicAnim:Stop()
        bar.buffBar:SetAlpha(1.0)
    end
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
        if chargeInfo and chargeInfo.currentCharges then
            -- Arithmetic test to detect secret values
            local cOk, cVal = pcall(function() return chargeInfo.currentCharges + 0 end)
            if cOk and type(cVal) == "number" then
                currentC = cVal
            end
        end
        bar.maxCharges = maxC
        bar.chargesAvailable = currentC
    else
        bar.maxCharges = 1
        bar.chargesAvailable = 1
    end
    
    if isChargeSpell and chargeInfo then
        local ok, val = pcall(function() return chargeInfo.cooldownDuration > 0 end)
        if ok and val then
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
    bar.chargeBar:SetStatusBarColor(unpack(CONFIG.cooldownColor))
    
    if isChargeSpell then
        bar.cdBar:SetHeight(bar.cdBar.laneHeight)
    else
        bar.cdBar:SetHeight(bar.cdBar.fullHeight)
    end

    -- Children inherit parent alpha for compound visibility
    if isChargeSpell then
        local futureWidth = GetFutureWidth()
        local nowOffset = GetBarOffset() + GetNowPixelOffset()
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

        -- Create wrapper frames lazily
        if not bar.depletedWrapper then
            -- depletedWrapper: visible when all charges spent
            bar.depletedWrapper = CreateFrame("Frame", nil, bar)
            bar.depletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)

            bar.depletedCdBar = CreateFrame("StatusBar", nil, bar.depletedWrapper)
            bar.depletedCdBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
            bar.depletedCdBar:SetMinMaxValues(0, CONFIG.future)
            bar.depletedCdBar:SetOrientation("HORIZONTAL")
            bar.depletedCdBar:GetStatusBarTexture():SetHorizTile(false)
            bar.depletedCdBar:GetStatusBarTexture():SetVertTile(false)
            CrispBar(bar.depletedCdBar)
            bar.depletedCdBar:Show()

            bar.depletedHelperBar = CreateFrame("StatusBar", nil, bar.depletedWrapper)
            bar.depletedHelperBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
            bar.depletedHelperBar:SetMinMaxValues(0, 1)
            bar.depletedHelperBar:SetValue(1)  -- always full (solid block)
            bar.depletedHelperBar:SetOrientation("HORIZONTAL")
            bar.depletedHelperBar:GetStatusBarTexture():SetHorizTile(false)
            bar.depletedHelperBar:GetStatusBarTexture():SetVertTile(false)
            CrispBar(bar.depletedHelperBar)
            bar.depletedHelperBar:Show()

            bar.depletedChargeBar = CreateFrame("StatusBar", nil, bar.depletedWrapper)
            bar.depletedChargeBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
            bar.depletedChargeBar:SetMinMaxValues(0, CONFIG.future)
            bar.depletedChargeBar:SetOrientation("HORIZONTAL")
            bar.depletedChargeBar:GetStatusBarTexture():SetHorizTile(false)
            bar.depletedChargeBar:GetStatusBarTexture():SetVertTile(false)
            CrispBar(bar.depletedChargeBar)
            bar.depletedChargeBar:Show()

            -- notDepletedWrapper: visible when charges available (NOT depleted)
            bar.notDepletedWrapper = CreateFrame("Frame", nil, bar)
            bar.notDepletedWrapper:SetFrameLevel(bar:GetFrameLevel() + 1)

            bar.normalChargeBar = CreateFrame("StatusBar", nil, bar.notDepletedWrapper)
            bar.normalChargeBar:SetStatusBarTexture("Interface\\AddOns\\EventHorizon_Infall\\Smooth")
            bar.normalChargeBar:SetMinMaxValues(0, CONFIG.future)
            bar.normalChargeBar:SetOrientation("HORIZONTAL")
            bar.normalChargeBar:GetStatusBarTexture():SetHorizTile(false)
            bar.normalChargeBar:GetStatusBarTexture():SetVertTile(false)
            CrispBar(bar.normalChargeBar)
            bar.normalChargeBar:Show()
        end

        bar.depletedWrapper:ClearAllPoints()
        bar.depletedWrapper:SetSize(futureWidth, CONFIG.height)
        bar.depletedWrapper:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.depletedWrapper:SetAlpha(0)  -- curve-driven in OnUpdate
        bar.depletedWrapper:Show()

        bar.notDepletedWrapper:ClearAllPoints()
        bar.notDepletedWrapper:SetSize(futureWidth, CONFIG.height)
        bar.notDepletedWrapper:SetPoint("TOPLEFT", bar, "TOPLEFT", nowOffset, 0)
        bar.notDepletedWrapper:SetAlpha(1)  -- default: not depleted
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
        -- Alpha driven per-lane by chargesAvailable in the OnUpdate charge alpha section.
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
            end
        end

        -- wrappers take over
        bar.cdBar:Hide()
        bar.chargeBar:Hide()
        bar.chargeHelperBar:Hide()
    
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
        -- Only show setup hint once per session to avoid spamming on repeated scans
        if not shownSetupHint then
            shownSetupHint = true
            print("|cff00ff00[Infall]|r No abilities found in the Cooldown Manager.")
            print("|cff00ff00[Infall]|r   Type |cffffff00/infall setup|r to open the Cooldown Manager settings,")
            print("|cff00ff00[Infall]|r   add your abilities, then |cffffff00/infall reload|r or |cffffff00/reload|r")
        end
        return
    end
    
    -- Filter out hidden cooldowns (user wants them in CDM for other addons but not as Infall bars).
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

    ApplyLayoutToAllBars()

    C_Timer.After(0.5, UpdateBars)
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

    for _, name in ipairs(ecmFrameNames) do
        local frame = _G[name]
        if frame then
            hooksecurefunc(frame, "SetAlpha", function(self, alpha)
                if CONFIG.hideBlizzECM and alpha > 0 then
                    self:SetAlpha(0)
                    pcall(function()
                        for itemFrame in self.itemFramePool:EnumerateActive() do
                            itemFrame:SetMouseMotionEnabled(false)
                        end
                    end)
                end
            end)
        end
    end

    -- Hook CDM buff item frames for instant aura updates on target switch
    local hookedBuffFrames = {}
    local buffHookPending = false
    local function OnBuffFrameAuraSet()
        if buffHookPending then return end
        buffHookPending = true
        C_Timer.After(0, function()
            buffHookPending = false
            if #cooldownBars > 0 then
                UpdateBars()
            end
        end)
    end

    local function HookBuffViewerFrames()
        for _, name in ipairs(buffViewerNames) do
            local viewer = _G[name]
            if viewer and viewer.itemFramePool then
                pcall(function()
                    for frame in viewer.itemFramePool:EnumerateActive() do
                        if not hookedBuffFrames[frame] then
                            hookedBuffFrames[frame] = true
                            hooksecurefunc(frame, "SetAuraInstanceInfo", OnBuffFrameAuraSet)
                        end
                    end
                end)
            end
        end
    end

    HookBuffViewerFrames()
    for _, name in ipairs(buffViewerNames) do
        local viewer = _G[name]
        if viewer then
            hooksecurefunc(viewer, "RefreshLayout", HookBuffViewerFrames)
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
        C_Timer.After(0.2, function()
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
        -- viewers may recreate after zone transitions
        if ns.ApplyECMVisibility then
            C_Timer.After(2.5, ns.ApplyECMVisibility)
        end
        
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
        if event == "SPELL_UPDATE_CHARGES" then
            C_Timer.After(0.05, UpdateBars)
        end
        
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...

        for _, row in ipairs(cooldownBars) do
            local isMatch = (row.spellID == spellID or row.baseSpellID == spellID)
            if not isMatch and CONFIG.extraCasts then
                local extras = CONFIG.extraCasts[row.cooldownID] or CONFIG.extraCasts[row.baseSpellID]
                if extras then
                    for _, extraID in ipairs(extras) do
                        if extraID == spellID then isMatch = true; break end
                    end
                end
            end

            if isMatch then
                if row.isChargeSpell then
                    row.chargesAvailable = math.max((row.chargesAvailable or 0) - 1, 0)
                    UpdateBars()
                    C_Timer.After(0, UpdateBars)
                end
                break
            end
        end
        
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        C_Timer.After(1, function()
            local specKey = ns.GetSpecKey and ns.GetSpecKey()
            if specKey and specKey ~= ns.currentSpecKey then
                ns.currentSpecKey = specKey
                if InfallDB.profiles[specKey] and ns.ApplyProfile then
                    ns.ApplyProfile(InfallDB.profiles[specKey])
                elseif ns.SeedProfileFromClassConfig then
                    ns.SeedProfileFromClassConfig(specKey)
                end
            end
            LoadEssentialCooldowns()
        end)

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
        -- Proc glow often means a cooldown reset, so refresh immediately.
        UpdateBars()
        C_Timer.After(0, UpdateBars)
        
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
                activeCast.row.castTex:Hide()
                HideEmpowerStageTex(activeCast.row)
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
            C_Timer.After(0, UpdateBars)
            if unit == "target" then
                C_Timer.After(0.05, UpdateBars)
                C_Timer.After(0.1, UpdateBars)
            end
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()
        
        if event == "PLAYER_REGEN_ENABLED" then
            for _, row in ipairs(cooldownBars) do
                row.cachedPandemicIcon = nil
                if row.pastSlides then
                    for _, slide in ipairs(row.pastSlides) do
                        slide.tex:Hide()
                        slide.active = false
                    end
                end
                row.activeCdSlide = nil
                row.activeBuffSlide = nil
                row.activeOverlaySlide = nil
                row.activeDepletedSlide = nil
                row.activeChargeSlide = nil
                if row.middleLanes then
                    for _, ml in ipairs(row.middleLanes) do
                        ml.activeSlide = nil
                    end
                end
                row.lastPtr_cd = nil
                row.lastPtr_charge = nil
                row.lastPtr_buff = nil
                row.lastPtr_overlay = nil
                row._cachedCdDurObj = nil
                row._cachedChargeDurObj = nil

                -- readable out of combat
                if row.isChargeSpell then
                    local cInfo = GetChargesWithOverride(row.spellID, row.baseSpellID)
                    if cInfo and cInfo.currentCharges then
                        local readOk, val = pcall(function() return cInfo.currentCharges + 0 end)
                        if readOk and type(val) == "number" then
                            row.chargesAvailable = val
                        else
                            row.chargesAvailable = row.maxCharges or 2
                        end
                        local mOk, mVal = pcall(function() return cInfo.maxCharges + 0 end)
                        if mOk and type(mVal) == "number" then
                            row.maxCharges = mVal
                            local bH = row.cdBar.fullHeight or CONFIG.height
                            row.cdBar.laneHeight = (bH - (mVal - 1)) / mVal
                        end
                    else
                        row.chargesAvailable = row.maxCharges or 2
                    end
                end

    
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
        C_Timer.After(0.05, UpdateBars)
        C_Timer.After(0.1, UpdateBars)
        C_Timer.After(0.2, UpdateBars)
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