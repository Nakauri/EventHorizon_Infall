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

-- ============================================================================
-- STACK INDICATORS
-- ============================================================================

-- ============================================================================
-- SPELL GENERATION (resource bar predictive power)
-- base = focus generated on cast, talents = conditional bonuses
-- ============================================================================

-- Values measured from SPELL_ENERGIZE in a combat log, not from tooltips.
CONFIG.spellGeneration = {
    [56641] = {  -- Steady Shot, one energize of 25
        base = 20,
        talents = {
            {spellID = 450379, bonus = 5},  -- Invigorating Pulse
        },
    },

    -- Channeled: base is the total focus over the full channel, not per tick.
    -- 10 shots at 3 focus each.
    -- Bonuses are in FOCUS, not shots, so a shot-count talent contributes
    -- shots * 3. Effects that scale shot count multiplicatively, or that add
    -- targets rather than shots, are not representable here.
    [257044] = {  -- Rapid Fire, 10 shots of 3
        base = 30,
        talents = {
            {spellID = 459794, bonus = 9},   -- Quick Draw, 3 extra shots
            {spellID = 470945, bonus = 30},  -- Aspect of the Hydra, second target energizes too
        },
    },
}

CONFIG.stackIndicatorList = {
    {
        cooldownID = 3664,
        maxStacks = 10,
        overflowMax = 20,
        color = {0.9, 0.5, 0.3, 1},
        overflowColor = {1, 0.82, 0.2, 1},
        position = "TOP",
    },
}
