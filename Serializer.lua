-- EventHorizon Infall: Profile Serializer
-- Uses Blizzard C_EncodingUtil (CBOR + Deflate + Base64)

local ns = EventHorizon_Infall

local HEADER = "!EHI2!"

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do
        copy[k] = DeepCopy(val)
    end
    return copy
end

function ns.ExportProfile(profile)
    if not profile then return nil end

    local export = DeepCopy(profile)
    export._version = 2
    local name = UnitName("player") or "Unknown"
    local specName = ""
    local specIndex = GetSpecialization()
    if specIndex then
        local _, sName = GetSpecializationInfo(specIndex)
        specName = sName or ""
    end
    export._source = name .. " (" .. specName .. ")"

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

    local ok1, compressed = pcall(C_EncodingUtil.DecodeBase64, encoded)
    if not ok1 or not compressed then
        return nil, "Failed to decode profile data."
    end

    local ok2, cbor = pcall(C_EncodingUtil.DecompressString, compressed)
    if not ok2 or not cbor then
        return nil, "Failed to decompress profile data."
    end

    local ok3, profile = pcall(C_EncodingUtil.DeserializeCBOR, cbor)
    if not ok3 or type(profile) ~= "table" then
        return nil, "Failed to parse profile data."
    end

    profile._version = nil
    profile._source = nil
    return profile
end
