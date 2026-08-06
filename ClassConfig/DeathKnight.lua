-- EventHorizon Infall, DeathKnight
if select(2, UnitClass("player")) ~= "DEATHKNIGHT" then return end

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
-- RUNE ABILITY BASE COOLDOWNS
-- The client reports "when can I next cast this", which for a rune ability is
-- the later of its real cooldown and the wait for runes. No API separates them,
-- so a spell with no cooldown of its own draws a bar made entirely of rune wait.
--
-- These are real cooldowns in seconds, used only while the player has estimated
-- rune cooldowns enabled. Static: DK ability cooldowns do not scale with haste.
-- A cooldown reduction proc makes the estimate run long.
-- 0 means the spell has no cooldown of its own.
-- ============================================================================

-- ONLY spells that cost runes belong here. A spell with no rune cost cannot
-- carry a rune wait, so declaring one replaces exact API data with an estimate.

CONFIG.runeBaseCooldowns = {
    [43265]  = 30,   -- Death and Decay
    [196770] = 20,   -- Remorseless Winter

    [49020]  = 0,    -- Obliterate
    [49184]  = 0,    -- Howling Blast
    [207230] = 0,    -- Frostscythe
    [85948]  = 0,    -- Festering Strike
    [55090]  = 0,    -- Scourge Strike
    [206930] = 0,    -- Heart Strike
}

-- ============================================================================
-- HIDDEN COOLDOWNS
-- Bars you want in the Blizzard Cooldown Manager but not shown in Infall
-- ============================================================================

-- CONFIG.hiddenCooldownIDs = CONFIG.hiddenCooldownIDs or {}
-- CONFIG.hiddenCooldownIDs[12345] = true
