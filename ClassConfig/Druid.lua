-- EventHorizon Infall, Druid
if select(2, UnitClass("player")) ~= "DRUID" then return end

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
    [88481] = {190984, 194153},     -- Eclipse bar shows Wrath + Starfire casts
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
    -- Moonfire
    [88334] = {
        {
            buffCooldownIDs = {93500},
            unit = "target",
            color = {0.9, 0.5, 0.3, 0.7}
        }
    },

    -- Eclipse (cooldownID stable across Solar/Lunar transforms)
    [88481] = {
        {
            buffCooldownIDs = {76},  -- Lunar Eclipse
            unit = "player",
            color = {135/255, 194/255, 255/255, 0.6}
        },
        {
            buffCooldownIDs = {78},  -- Solar Eclipse
            unit = "player",
            color = {0.9, 0.5, 0.3, 0.3}
        }
    },

    -- Wrath
    [99] = {
        {
            buffCooldownIDs = {78},  -- Solar Eclipse
            unit = "player",
            color = {0.9, 0.5, 0.3, 0.3}
        }
    },

    -- Starfire
    [100] = {
        {
            buffCooldownIDs = {76},  -- Lunar Eclipse
            unit = "player",
            color = {135/255, 194/255, 255/255, 0.6}
        }
    },
}

-- ============================================================================
-- STACK MAPPINGS
-- Format: [abilityCooldownID] = {buffCooldownID = N, unit = "player"/"target"}
-- ============================================================================

CONFIG.stackMappings = {
    -- Starlord stacks on Eclipse bar (also reflects Gathering Starstuff empowerment)
    [88481] = {buffCooldownID = 117, unit = "player"},
}

-- ============================================================================
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
