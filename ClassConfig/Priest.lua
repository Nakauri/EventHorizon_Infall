-- EventHorizon Infall, Priest
if select(2, UnitClass("player")) ~= "PRIEST" then return end

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
    -- [cooldownID] = {
    --     {buffCooldownIDs = {N}, unit = "player", color = {r, g, b, a}},
    -- },
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
-- Shadow: Insanity generation from cast time / channeled spells
-- ============================================================================

CONFIG.spellGeneration = {
    [8092]   = {base = 6},   -- Mind Blast (has cast time at lower levels)
    [15407]  = {base = 18},  -- Mind Flay (channeled, total over full channel)
    [391403] = {base = 12},  -- Mind Flay: Insanity (channeled, shorter duration)
    [34914]  = {base = 4},   -- Vampiric Touch
    [263165] = {base = 24},  -- Void Torrent (channeled, total over full channel)
}

-- ============================================================================
-- CHARGE OVERFLOW
-- For spells where a proc temporarily bumps maxCharges beyond the base value
-- (granting a bonus charge). Locks the addon's lane count to trueMax so the
-- bar never builds a 3rd lane in past or future regions.
-- ============================================================================
CONFIG.chargeOverflow = {
    [8092] = { trueMax = 2 },  -- Mind Blast / Shadowy Insight
}

-- ============================================================================
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
