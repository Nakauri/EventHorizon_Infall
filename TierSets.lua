-- EventHorizon Infall: tier set bonus auras.

local ns = EventHorizon_Infall

-- [bonusSpellID] = { spec, pieces, auras = { spellID, ... } }
ns.TIER_SET_AURAS = {
    [1296569] = { spec = 265, pieces = 4, auras = { 1305774 } },  -- 1305774 Unstable Empowerment
    [1296572] = { spec = 267, pieces = 4, auras = { 1305711 } },  -- 1305711 Dark Titan's Mark
    [1296575] = { spec = 257, pieces = 2, auras = { 1306118 } },  -- 1306118 Renewed Vigor
    [1296578] = { spec = 256, pieces = 4, auras = { 1307795 } },  -- 1307795 Dark Transference
    [1296582] = { spec = 62, pieces = 4, auras = { 1296930 } },  -- 1296930 Cumulative Power
    [1296586] = { spec = 64, pieces = 4, auras = { 1310248 } },  -- 1310248 Rapid Refreezing
    [1296604] = { spec = 102, pieces = 4, auras = { 1301768 } },  -- 1301768 Akil'zon's Clarity
    [1296605] = { spec = 103, pieces = 2, auras = { 1301600 } },  -- 1301600 Halazzi's Fury
    [1296607] = { spec = 104, pieces = 2, auras = { 1301286 } },  -- 1301286 Gorestained Claws
    [1296609] = { spec = 105, pieces = 2, auras = { 1302255 } },  -- 1302255 Genesis
    [1296618] = { spec = 268, pieces = 4, auras = { 1301410 } },  -- 1301410 Scorched
    [1296620] = { spec = 270, pieces = 4, auras = { 1296687 } },  -- 1296687 Rising Sun Kick
    [1296626] = { spec = 262, pieces = 4, auras = { 1300219, 1300222 } },  -- 1300219 Flowing Elements / 1300222 Overcharge!
    [1296627] = { spec = 263, pieces = 2, auras = { 1299975 } },  -- 1299975 Burning Core
    [1296628] = { spec = 263, pieces = 4, auras = { 1299991 } },  -- 1299991 Short Circuit
    [1296630] = { spec = 264, pieces = 4, auras = { 1300642 } },  -- 1300642 Condensation
    [1296632] = { spec = 253, pieces = 4, auras = { 1299389 } },  -- 1299389 Cobra Fang
    [1296638] = { spec = 1473, pieces = 4, auras = { 1297728 } },  -- 1297728 Magnified Fate
    [1296644] = { spec = 71, pieces = 4, auras = { 1300670 } },  -- 1300670 Winding Up
    [1296647] = { spec = 73, pieces = 2, auras = { 1300681 } },  -- 1300681 Vengeful Shield
    [1296648] = { spec = 73, pieces = 4, auras = { 1300690 } },  -- 1300690 Bloody Rebuke
    [1296650] = { spec = 250, pieces = 2, auras = { 1300369, 1310372 } },  -- 1300369 Relentless Rider's Strength / 1310372 Blood Debt
    [1296652] = { spec = 251, pieces = 2, auras = { 1297365 } },  -- 1297365 Freezing Tempest
    [1296660] = { spec = 70, pieces = 2, auras = { 1305230 } },  -- 1305230 Divine Power
}

ns.TIER_ID_BASE = 90000000

function ns.TierCooldownIDForSpell(spellID)
    return ns.TIER_ID_BASE + spellID
end

function ns.TierSpellIDForCooldown(cdID)
    if type(cdID) == "number" and cdID >= ns.TIER_ID_BASE then
        return cdID - ns.TIER_ID_BASE
    end
    return nil
end

local issecret = issecretvalue or function() return false end

local TIER_SLOTS = { 1, 3, 5, 7, 10 }

local activeAuras = {}
local activeInfo = {}
local scanned = false

function ns.TierSetAuras()
    return activeAuras
end

function ns.TierSetAuraPieces(auraID)
    return activeInfo[auraID]
end

local function Scan()
    wipe(activeAuras)
    wipe(activeInfo)
    scanned = true
    if InCombatLockdown() then return end
    if not C_Item or not C_Item.GetSetBonusesForSpecializationByItemID then return end

    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex or not GetSpecializationInfo then return end
    local specOk, specID = pcall(GetSpecializationInfo, specIndex)
    if not specOk or not specID or issecret(specID) then return end

    local seen = {}
    pcall(function()
        for _, slot in ipairs(TIER_SLOTS) do
            local itemID = GetInventoryItemID("player", slot)
            if itemID and not issecret(itemID) then
                local ok, bonusIDs = pcall(C_Item.GetSetBonusesForSpecializationByItemID,
                    specID, itemID)
                if ok and type(bonusIDs) == "table" then
                    for _, bonusID in ipairs(bonusIDs) do
                        local entry = not issecret(bonusID) and ns.TIER_SET_AURAS[bonusID]
                        if entry and entry.spec == specID then
                            for _, auraID in ipairs(entry.auras) do
                                if not seen[auraID] then
                                    seen[auraID] = true
                                    activeAuras[#activeAuras + 1] = auraID
                                    activeInfo[auraID] = entry.pieces
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
end

ns.ScanTierSets = Scan

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and scanned and #activeAuras > 0 then return end
    C_Timer.After(0, Scan)
end)
