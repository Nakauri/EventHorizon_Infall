-- EventHorizon Infall: CPU measurement.
-- /infall perf         report
-- /infall perf on|off  per-section timers
-- /infall perf reset   clear section totals

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

local METRICS = {
    { "Recent avg", 1 },
    { "Peak", 4 },
    { "Over 1ms", 5 },
    { "Over 5ms", 6 },
}

function P.Report()
    Line("|cffffff00CPU|r")

    if not (C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric) then
        Line("  addon profiler unavailable on this client")
    elseif C_AddOnProfiler.IsEnabled and not C_AddOnProfiler.IsEnabled() then
        Line("  addon profiler is off. Enable with /console scriptProfile 1 then reload")
    else
        for _, m in ipairs(METRICS) do
            local ok, v = pcall(C_AddOnProfiler.GetAddOnMetric, ADDON, m[2])
            if ok and v then
                if m[2] == 1 or m[2] == 4 then
                    Line(string.format("  %-10s %.3f ms", m[1], v))
                else
                    Line(string.format("  %-10s %d ticks", m[1], v))
                end
            end
        end
        local okAll, all = pcall(C_AddOnProfiler.GetOverallMetric, 1)
        local okMine, mine = pcall(C_AddOnProfiler.GetAddOnMetric, ADDON, 1)
        if okAll and okMine and all and mine and all > 0 then
            Line(string.format("  Share      %.1f%% of all addon time", (mine / all) * 100))
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
