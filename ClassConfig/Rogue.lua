-- EventHorizon Infall, Rogue
if select(2, UnitClass("player")) ~= "ROGUE" then return end

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
    -- Roll the Bones: buff cooldownID is always 42743, spellID changes per outcome
    [11860] = {
        {
            buffCooldownIDs = {42743},
            unit = "player",
            color = {0.4, 0.4, 0.9, 0.6},
            spellColorMap = {
                [1214933] = {0.3, 0.8, 0.3, 0.6},  -- One of a Kind
                [1214934] = {0.8, 0.8, 0.2, 0.6},  -- Double Trouble
                [1214935] = {0.9, 0.5, 0.1, 0.6},  -- Triple Threat
                [1214937] = {0.9, 0.2, 0.9, 0.6},  -- Jackpot
            },
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
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
