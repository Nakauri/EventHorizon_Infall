-- EventHorizon Infall: CPU measurement.

local ns = EventHorizon_Infall
local P = {}
ns.Perf = P

local ADDON = "EventHorizon_Infall"

P.enabled = false

local totals = {}
local counts = {}
local peaks = {}

-- Wraps a call and accumulates its cost. One boolean test when disabled.
function P.Time(label, fn, a, b)
    if not P.enabled then return fn(a, b) end
    local t0 = debugprofilestop()
    fn(a, b)
    local dt = debugprofilestop() - t0
    totals[label] = (totals[label] or 0) + dt
    counts[label] = (counts[label] or 0) + 1
    if dt > (peaks[label] or 0) then peaks[label] = dt end
end

function P.Reset()
    wipe(totals)
    wipe(counts)
    wipe(peaks)
end

local function Line(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Infall]|r " .. msg)
end

-- Recent avg is a 60 tick window, ie one second. Encounter avg spans the whole
-- boss fight and is the number that describes raid cost.
local METRICS = {
    { "Recent avg", 1, "ms" },
    { "Encounter avg", 2, "ms" },
    { "Peak", 4, "ms" },
    { "Over 1ms", 5, "ticks" },
    { "Over 5ms", 6, "ticks" },
}

function P.Report()
    Line("|cffffff00CPU|r")

    if not (C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric) then
        Line("  addon profiler unavailable on this client")
    elseif C_AddOnProfiler.IsEnabled and not C_AddOnProfiler.IsEnabled() then
        -- Gated on the addonProfilerEnabled CVar, not scriptProfile, and on for
        -- everyone by default.
        Line("  addon profiler is off. Enable with /console addonProfilerEnabled 1")
    else
        for _, m in ipairs(METRICS) do
            local ok, v = pcall(C_AddOnProfiler.GetAddOnMetric, ADDON, m[2])
            if ok and v then
                if m[3] == "ms" then
                    Line(string.format("  %-14s %.3f ms", m[1], v))
                else
                    Line(string.format("  %-14s %d ticks", m[1], v))
                end
            end
        end
        local okAll, all = pcall(C_AddOnProfiler.GetOverallMetric, 1)
        local okMine, mine = pcall(C_AddOnProfiler.GetAddOnMetric, ADDON, 1)
        if okAll and okMine and all and mine and all > 0 then
            Line(string.format("  %-14s %.1f%% of all addon time", "Share", (mine / all) * 100))
        end
    end

    if not P.enabled and not next(totals) then
        Line("  section timers off. /infall perf on, play for a bit, then /infall perf")
        return
    end

    Line("|cffffff00Sections|r (total ms / calls / avg / peak)")
    local rows = {}
    for label, total in pairs(totals) do
        rows[#rows + 1] = { label = label, total = total, n = counts[label] or 1, peak = peaks[label] or 0 }
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    for _, r in ipairs(rows) do
        Line(string.format("  %-18s %8.1f  %6d  %.4f  %.3f",
            r.label, r.total, r.n, r.total / r.n, r.peak))
    end
    if #rows == 0 then Line("  no samples yet") end
end

function P.SetEnabled(on)
    P.enabled = on and true or false
    if P.enabled then
        P.Reset()
        Line("section timers ON. /infall perf to report.")
    else
        Line("section timers OFF.")
    end
end
