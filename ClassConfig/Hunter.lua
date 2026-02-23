-- EventHorizon Infall, Hunter
if select(2, UnitClass("player")) ~= "HUNTER" then return end

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
    [19434] = {56641},              -- Aimed Shot bar shows Steady Shot casts
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
    -- Trueshot
    [35882] = {
        {
            buffCooldownIDs = {92807},
            unit = "player",
            color = {0.6, 0.4, 0.9, 0.7}
        }
    },

    -- Bestial Wrath
    [31264] = {
        {
            buffCooldownIDs = {92792},
            unit = "player",
            color = {0.9, 0.3, 0.3, 0.6}
        }
    },

    -- Wild Thrash
    [148127] = {
        {
            buffCooldownIDs = {31396},
            unit = "player",
            color = {0.7, 0.6, 0.5, 0.5}
        }
    },
    
    -- Volley
    [2268] = {
        {
            buffCooldownIDs = {3644},
            unit = "player",
            color = {0.9, 0.5, 0.3, 0.7}
        }
    },

    -- Barbed Shot
    [31159] = {
        {
            buffCooldownIDs = {31397},
            unit = "target",
            color = {0.9, 0.5, 0.3, 0.7}
        }
    },

    -- Aimed Shot
    [19434] = {
        {
            buffCooldownIDs = {35941},
            unit = "player",
            color = {135/255, 194/255, 255/255, 0.6}
        },
        {
            buffCooldownIDs = {3664},
            unit = "player",
            color = {0.9, 0.5, 0.3, 0.3}
        }
    },
}

-- ============================================================================
-- STACK MAPPINGS
-- Format: [abilityCooldownID] = {buffCooldownID = N, unit = "player"/"target"}
-- ============================================================================

CONFIG.stackMappings = {}

-- ============================================================================
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
