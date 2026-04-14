-- EventHorizon Infall, Mage
if select(2, UnitClass("player")) ~= "MAGE" then return end

local CONFIG = EventHorizon_Infall.CONFIG
-- ============================================================================
-- VISUAL OVERRIDES (optional, uncomment to override Core.lua for this class)
-- ============================================================================

-- CONFIG.width = 352
-- CONFIG.height = 20
-- CONFIG.iconSize = 30
-- CONFIG.future = 16
-- CONFIG.past = 2.5

-- CONFIG.cooldownColor = {171/255, 191/255, 181/255, 0.5}
-- CONFIG.castColor = {0.2, 0.8, 0.2, 0.7}
-- CONFIG.buffColor = {0.4, 0.4, 0.9, 0.6}
-- CONFIG.debuffColor = {0.9, 0.3, 0.3, 0.6}

-- ============================================================================
-- EXTRA CASTS
-- Key: cooldownID of the bar to show casts on
-- Value: {castSpellID, ...}, spellIDs of casts to display
-- ============================================================================

CONFIG.extraCasts = {
    -- [cooldownID] = {spellID},
}

-- ============================================================================
-- CAST COLOURS (optional, omit to use CONFIG.castColor for everything)
-- Key: spellID of the cast
-- ============================================================================

-- CONFIG.castColors = {
--     [spellID] = {r, g, b, a},
-- }

-- ============================================================================
-- BUFF MAPPINGS
-- Format: [abilityCooldownID] = { {buffCooldownIDs = {...}, unit = "...", color = {r,g,b,a}}, ... }
-- ============================================================================

CONFIG.buffMappings = {
    -- Pyroblast: Heating Up / Hot Streak (variants auto-detected from CDM)
    [35691] = {
        {
            buffCooldownIDs = {161645},
            unit = "player",
            color = {0.9, 0.4, 0.1, 0.6},
        },
    },
}

-- ============================================================================
-- STACK MAPPINGS
-- Format: [abilityCooldownID] = {buffCooldownID = N, unit = "player"/"target"}
-- ============================================================================

CONFIG.stackMappings = {
    -- [cooldownID] = {buffCooldownID = N, unit = "player"},
}

-- ============================================================================
-- SPELL GENERATION (resource bar predictive power)
-- Arcane: Arcane Charge generation from cast time spells
-- ============================================================================

CONFIG.spellGeneration = {
    [30451] = {  -- Arcane Blast
        base = 1,
        talents = {
            {spellID = 383676, bonus = 1},  -- Impetus
        },
    },
}

-- ============================================================================
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
