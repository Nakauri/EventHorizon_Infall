-- EventHorizon Infall: Profile Serializer
-- Uses Blizzard C_EncodingUtil (CBOR + Deflate + Base64)

local ns = EventHorizon_Infall

local HEADER = "!EHI2!"
-- Honest exports are a few KB; Deflate can inflate a 4 KB string to megabytes.
local MAX_CBOR = 256 * 1024
-- Checked before decoding. The largest honest Import All measured under 7 KB.
local MAX_ENCODED = 64 * 1024

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do
        copy[k] = DeepCopy(val)
    end
    return copy
end

-- Which client wrote a string. Cooldown Manager ids mean different spells on each.
local function ClientTag()
    return ns.IS_FOREVER and "forever" or "retail"
end

-- Tables keyed by, or listing, Cooldown Manager ids.
local CLIENT_ID_TABLES = {
    "pairings", "pairingCleared", "extraCasts", "stackMappings", "cooldownColors",
    "hiddenCooldownIDs", "chargesDisabled", "customIcons", "iconList", "stackIndicatorList",
}

-- The keyed ones, where a custom row's string key sits beside the numeric ids.
local KEYED_ID_TABLES = {
    "pairings", "pairingCleared", "extraCasts", "stackMappings", "cooldownColors",
    "hiddenCooldownIDs", "chargesDisabled", "customIcons",
}

local function CustomKeys(list, rowsOnly)
    local keys = {}
    if type(list) ~= "table" then return keys end
    for _, e in pairs(list) do
        if type(e) == "table" and type(e.key) == "string" and (not rowsOnly or e.type == "custom") then
            keys[e.key] = true
        end
    end
    return keys
end

-- The importer's saved profile for one spec, or for the spec they are on.
local function OwnProfile(specID)
    local profiles = InfallDB and InfallDB.profiles
    if type(profiles) ~= "table" then return nil end
    local key
    if specID ~= nil then
        local id = tonumber(specID)
        local ok, prefix = pcall(ns.CharPrefix)
        if not id or not ok or type(prefix) ~= "string" then return nil end
        key = prefix .. id
    else
        key = ns.currentSpecKey
    end
    local own = key and profiles[key]
    return type(own) == "table" and own or nil
end

-- A custom row's entry from the other client, minus what names a Cooldown Manager id.
local function CrossEntry(field, v)
    if field == "pairings" then
        if type(v) ~= "table" then return nil end
        local kept, any = {}, false
        for i, slot in ipairs(v) do
            if type(slot) == "table" and slot.buffCooldownIDs == nil then
                kept[i], any = DeepCopy(slot), true
            else
                kept[i] = {}
            end
        end
        return any and kept or nil
    end
    if field == "stackMappings" and type(v) == "table" and v.buffCooldownID ~= nil then return nil end
    return DeepCopy(v)
end

-- A string from the other client: its id tables are replaced by the importer's own, and
-- its custom rows keep their settings. An own custom icon sharing a key with an incoming
-- custom row moves to a free key; an own custom row is replaced, so its entries go.
local function KeepOwnIDs(profile, own)
    local rows = CustomKeys(profile.extras, true)
    local ownIcons = CustomKeys(own and own.iconList, false)
    local ownRows = CustomKeys(own and own.extras, true)
    local merged = {}
    for _, field in ipairs(CLIENT_ID_TABLES) do
        merged[field] = own and own[field] ~= nil and DeepCopy(own[field]) or nil
    end
    local taken = {}
    for k in pairs(rows) do taken[k] = true end
    for k in pairs(ownIcons) do taken[k] = true end
    for k in pairs(ownRows) do taken[k] = true end
    for _, field in ipairs(KEYED_ID_TABLES) do
        for k in pairs(type(merged[field]) == "table" and merged[field] or {}) do
            if type(k) == "string" then taken[k] = true end
        end
    end
    if type(merged.iconList) == "table" then
        for _, e in pairs(merged.iconList) do
            if type(e) == "table" and type(e.key) == "string" and rows[e.key] then
                local n = 1
                while taken["custom_" .. n] do n = n + 1 end
                local newKey = "custom_" .. n
                taken[newKey] = true
                for _, field in ipairs(KEYED_ID_TABLES) do
                    local t = merged[field]
                    if type(t) == "table" and t[e.key] ~= nil then
                        t[newKey], t[e.key] = t[e.key], nil
                    end
                end
                e.key = newKey
            end
        end
    end
    for _, field in ipairs(KEYED_ID_TABLES) do
        local t = merged[field]
        if type(t) == "table" then
            for k in pairs(ownRows) do
                if not ownIcons[k] then t[k] = nil end
            end
            for k in pairs(rows) do t[k] = nil end
        end
        local theirs = profile[field]
        if type(theirs) == "table" then
            for k in pairs(rows) do
                local v = theirs[k] ~= nil and CrossEntry(field, theirs[k]) or nil
                if v ~= nil then
                    t = type(t) == "table" and t or {}
                    t[k] = v
                end
            end
        end
        merged[field] = t
    end
    for _, field in ipairs(CLIENT_ID_TABLES) do profile[field] = merged[field] end
end

-- omitSource leaves the character name out, for the bug report a player pastes in public.
function ns.ExportProfile(profile, omitSource)
    if not profile then return nil end

    local export = DeepCopy(profile)
    export._version = 2
    export._client = ClientTag()
    if not omitSource then
        local name = UnitName("player") or "Unknown"
        local specName = ""
        local specIndex = ns.SpecIndex()
        if specIndex then
            local _, sName = ns.SpecInfo(specIndex)
            specName = sName or ""
        end
        export._source = name .. " (" .. specName .. ")"
    end

    local ok1, cbor = pcall(C_EncodingUtil.SerializeCBOR, export)
    if not ok1 or not cbor then return nil end

    local ok2, compressed = pcall(C_EncodingUtil.CompressString, cbor)
    if not ok2 or not compressed then return nil end

    local ok3, encoded = pcall(C_EncodingUtil.EncodeBase64, compressed)
    if not ok3 or not encoded then return nil end

    return HEADER .. encoded
end

function ns.ImportProfile(str)
    if not str or str == "" then
        return nil, "No string provided."
    end
    str = str:match("^%s*(.-)%s*$")
    if str:sub(1, #HEADER) ~= HEADER then
        return nil, "Invalid format. String must start with " .. HEADER
    end
    local encoded = str:sub(#HEADER + 1)
    if encoded == "" then
        return nil, "Empty profile data."
    end
    if #encoded > MAX_ENCODED then
        return nil, "This profile string is too large to be a real profile. Nothing was changed."
    end

    local ok1, compressed = pcall(C_EncodingUtil.DecodeBase64, encoded)
    if not ok1 or not compressed then
        return nil, "Failed to decode profile data."
    end

    local ok2, cbor = pcall(C_EncodingUtil.DecompressString, compressed)
    if not ok2 or not cbor then
        return nil, "Failed to decompress profile data."
    end
    if #cbor > MAX_CBOR then
        return nil, "This profile string is too large to be a real profile. Nothing was changed."
    end

    local ok3, profile = pcall(C_EncodingUtil.DeserializeCBOR, cbor)
    if not ok3 or type(profile) ~= "table" then
        return nil, "Failed to parse profile data."
    end

    profile._version = nil
    profile._source = nil
    local function Problem()
        if profile._multi then return ns.MultiProfileProblem(profile) end
        return ns.ProfileProblem(profile)
    end
    -- A string from the other client keeps its settings; its ids would pair the wrong spells.
    -- Strings with no tag predate it and import as they always did.
    local client = profile._client
    profile._client = nil
    local note
    local bad = Problem()
    if not bad and type(client) == "string" and client ~= ClientTag() then
        if profile._multi then
            for specID, p in pairs(profile.specs) do KeepOwnIDs(p, OwnProfile(specID)) end
        else
            KeepOwnIDs(profile, OwnProfile(nil))
        end
        note = "This string came from the other game client, so its settings and custom rows were kept,"
            .. " and your own cooldown pairings, icons and hidden rows were left as they were."
        bad = Problem()
    end
    if bad then
        return nil, "This profile string is damaged (" .. bad .. "). Nothing was changed."
    end
    return profile, nil, note
end

-- Every field ApplyProfile reads as a table. A wrong type throws partway through an
-- import, after earlier specs were already saved.
local TABLE_FIELDS = {
    "toggles", "display", "colors", "pairings", "pairingCleared", "extraCasts",
    "stackMappings", "hiddenCooldownIDs", "chargesDisabled", "castColors", "cooldownColors",
    "stackIndicatorSettings", "stackIndicatorList", "resourceBar", "extras", "customIcons",
    "iconContainers", "iconList", "iconStates", "position",
}

-- Each default's type, read before any profile is applied. Keys whose default is nil
-- (font, lines) have no entry and are checked only by the generic walk.
local DEFAULT_TYPES = { font = "string", lines = "table" }
for k, v in pairs(ns.CONFIG or {}) do DEFAULT_TYPES[k] = type(v) end

local ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Spell and cooldown IDs pass a million, so the generic bound is wide; display values
-- (width, scale, offsets) get the tight one in KeyTypeProblem.
local function Finite(v, limit)
    limit = limit or 1e9
    return v == v and v < limit and v > -limit
end

-- Bounds every value in the blob: finite numbers, short strings, a node and depth cap.
-- A crafted string otherwise inflates to millions of tables or carries NaN into SetPoint.
local function WalkProblem(v, depth, budget)
    local t = type(v)
    if t == "number" then return (not Finite(v)) and "number" or nil end
    if t == "string" then return #v > 2000 and "string" or nil end
    if t ~= "table" then return nil end
    if depth > 12 then return "nesting" end
    for k, val in pairs(v) do
        budget.n = budget.n + 1
        if budget.n > 50000 then return "size" end
        local bad = WalkProblem(k, depth + 1, budget) or WalkProblem(val, depth + 1, budget)
        if bad then return bad end
    end
    return nil
end

local function WholeIn(v, lo, hi)
    if type(v) ~= "number" or not Finite(v) then return false end
    return v == math.floor(v) and v >= lo and v <= hi
end

-- A list keyed 1..n with no gaps and at most max entries.
local function ListProblem(t, max)
    local n = 0
    for k in pairs(t) do
        if not WholeIn(k, 1, max) then return true end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return true end
    end
    return false
end

-- A bound on time line entries; the settings box and /infall lines have no cap of their own.
local MAX_LINES = 1000

-- A known key must keep its default's type. Display values may be false, meaning unset.
local function KeyTypeProblem(section, allowFalse)
    for key, val in pairs(section) do
        local want = DEFAULT_TYPES[key]
        -- lines may be one marker as a plain number; CreateTimeLines wraps it in a table.
        local got = type(val)
        local oneLine = key == "lines" and got == "number"
        if want and got ~= want and not (allowFalse and val == false) and not oneLine then
            return key
        end
        if want == "number" and val ~= false and not Finite(val, 1e5) then return key end
        if want == "table" and type(val) == "table" then
            if ListProblem(val, MAX_LINES) then return key end
            for _, c in ipairs(val) do
                if type(c) ~= "number" then return key end
            end
        end
        if type(key) == "string" and (key:match("Anchor$") or key:match("RelPoint$"))
            and val ~= false and not ANCHORS[val] then
            return key
        end
    end
    return nil
end

-- Every colour must unpack to three or four numbers. linesColor may be a list of them.
local function ColourProblem(colors)
    for key, val in pairs(colors) do
        if key == "linesColor" and type(val) == "table" and type(val[1]) == "table" then
            if ListProblem(val, MAX_LINES) then return key end
            for _, c in pairs(val) do
                if not ns.ValidColour(c) then return key end
            end
        elseif not ns.ValidColour(val) then
            return key
        end
    end
    return nil
end

-- Per id colour maps and custom row colours, each value unpacked as a colour.
local COLOUR_MAPS = { "castColors", "cooldownColors" }
local function ColourMapsProblem(p)
    for _, field in ipairs(COLOUR_MAPS) do
        for _, c in pairs(p[field] or {}) do
            if not ns.ValidColour(c) then return field end
        end
    end
    for _, e in pairs(p.extras or {}) do
        if type(e) == "table" and e.cdColor ~= nil and not ns.ValidColour(e.cdColor) then
            return "extras"
        end
    end
    return nil
end

local function BandsProblem(bands)
    if type(bands) ~= "table" or ListProblem(bands, 3) then return true end
    for _, b in pairs(bands) do
        if type(b) ~= "table" or not WholeIn(b.threshold, 2, 99) then return true end
        if not ns.ValidColour(b.color) then return true end
    end
    return false
end

local function SlotProblem(mapData)
    if type(mapData) ~= "table" then return true end
    if mapData.color ~= nil and not ns.ValidColour(mapData.color) then return true end
    local ids = mapData.buffCooldownIDs
    if ids ~= nil then
        if type(ids) ~= "table" or ListProblem(ids, 50) then return true end
        for _, id in pairs(ids) do
            if not WholeIn(id, 1, 1e8) then return true end
        end
    end
    if mapData.stackGate ~= nil and not WholeIn(mapData.stackGate, 2, 99) then return true end
    local below = mapData.stackGateBelow
    if below ~= nil and below ~= "hide" and below ~= "dim" then return true end
    if mapData.stackGateDim ~= nil and not WholeIn(mapData.stackGateDim, 0, 100) then return true end
    return false
end

-- Pairing slots and stack mappings, every entry walked with pairs.
local function StackFieldsProblem(p)
    for _, mappings in pairs(p.pairings or {}) do
        if type(mappings) ~= "table" or ListProblem(mappings, 3) then return "pairings" end
        for _, mapData in pairs(mappings) do
            if SlotProblem(mapData) then return "pairings" end
        end
    end
    for _, sm in pairs(p.stackMappings or {}) do
        if type(sm) ~= "table" then return "stackMappings" end
        if sm.color ~= nil and not ns.ValidColour(sm.color) then return "stackMappings" end
        if sm.colorBands ~= nil and BandsProblem(sm.colorBands) then return "stackMappings" end
    end
    return nil
end

-- An Import All blob: spec keys whole numbers 1 to 99999, unique once normalised,
-- at most 40, every spec a safe profile. Returns the problem or nil.
local MAX_SPECS = 40
function ns.MultiProfileProblem(profile)
    if type(profile) ~= "table" or type(profile.specs) ~= "table" then return "specs" end
    local seen, n = {}, 0
    for specID, spec in pairs(profile.specs) do
        local id = tonumber(specID)
        if not WholeIn(id, 1, 99999) then return "spec key" end
        if seen[id] then return "duplicate spec " .. id end
        seen[id] = true
        n = n + 1
        if n > MAX_SPECS then return "too many specs" end
        local bad = ns.ProfileProblem(spec)
        if bad then return "spec " .. id .. ": " .. bad end
    end
    return nil
end

-- Returns the name of the first malformed field, or nil when the profile is safe to apply.
function ns.ProfileProblem(p)
    if type(p) ~= "table" then return "not a table" end
    local walked = WalkProblem(p, 0, { n = 0 })
    if walked then return walked end
    for _, key in ipairs(TABLE_FIELDS) do
        if p[key] ~= nil and type(p[key]) ~= "table" then return key end
    end
    local bad = (p.toggles and KeyTypeProblem(p.toggles, false))
        or (p.display and KeyTypeProblem(p.display, true))
        or (p.colors and ColourProblem(p.colors))
        or ColourMapsProblem(p)
    if bad then return bad end
    bad = StackFieldsProblem(p)
    if bad then return bad end
    local pos = p.position
    if pos and (not ANCHORS[pos.point] or not ANCHORS[pos.relPoint]
        or type(pos.x) ~= "number" or type(pos.y) ~= "number") then
        return "position"
    end
    return nil
end
