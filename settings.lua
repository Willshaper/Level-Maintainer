local settings = {}

-- Maintainer behaviour. The list of maintained items lives in config.lua.
-- While the maintainer runs, press E to edit config.lua or S to edit this file.
-- Changes take effect the next time Maintainer starts (no reboot needed), or
-- while it runs if live reload (reloadCheck, at the bottom) is on.

-- Seconds to wait between cycles. Each cycle checks every configured entry once.
settings.sleep = 10

-- After a crafting request fails (missing ingredients, no suitable CPU, ...),
-- wait this many seconds before calculating that entry again.
-- Other entries are unaffected. 0 = retry every cycle.
-- Also the pause before the maintainer restarts itself after an unexpected
-- error (at least 5 seconds).
settings.retryDelay = 60

-- Only start a calculation when a crafting CPU is idle (or the CPU named in
-- cpuName, if set). AE2 otherwise calculates the whole craft and then fails
-- to submit it.
settings.requireFreeCpu = true

-- Name of the crafting CPU to use for all requests, as named in AE2,
-- e.g. "Maintainer". nil = let AE2 pick any CPU.
settings.cpuName = nil

-- How long craftable lookups are cached, in seconds. An entry that is not
-- craftable yet is picked up after at most this long once its pattern is
-- added in AE2 (or straight away when the maintainer is restarted).
settings.cacheDuration = 600

-- How often to check whether AE2 has finished calculating a request, in seconds.
settings.pollInterval = 1

-- Log entries that are skipped because they are already crafting, above
-- their threshold, waiting to retry, or waiting for a free CPU.
settings.logSkips = true

-- Show everything that happens, every cycle, in the Recent panel of the status
-- table (stocked, crafting, waiting for a CPU, retry waits, ...). false = each
-- entry's status is logged once and again only when it changes. The scrolling
-- log (display = "log") always logs each status once.
settings.logRepeats = false

-- Hours to add to UTC for log timestamps, e.g. 1 for CET, 2 for CEST,
-- -5 for EST. Change it when daylight saving time starts or ends.
settings.utcOffset = 0

-- What the screen shows: "table" = a status table with one row per entry and the
-- most recent log lines below it; "log" = a scrolling log.
settings.display = "table"

-- Show the most recent log lines below the status table. false = the table
-- uses the whole screen (statuses, failures and errors still show in the table).
settings.showRecent = true

-- How the status table uses the screen:
--   "fit"     - changes the screen resolution so the rows fill the screen with the
--               largest text that fits (matched to the screen's shape, e.g. 2x2 or
--               3x2 blocks). The old resolution comes back when the maintainer stops.
--               On a screen taller than wide it uses the narrow columns of "tall".
--   "columns" - keeps the resolution and puts the rows in side-by-side tables when
--               the screen is wide enough.
--   "fixed"   - keeps the resolution, one table.
--   "tall"    - like "fit", but always with narrow number columns and short status
--               words ("no CPU", "no pattern"). Long names are cut to fit.
settings.layout = "fit"

-- How the header counts crafting CPUs: "free" = idle CPUs ("CPUs free: 9/11"),
-- "busy" = CPUs running a job ("CPUs busy: 2/11").
settings.cpuDisplay = "free"

-- Live reload: how often, in seconds, to check whether config.lua or settings.lua
-- was saved while the maintainer runs, and reload them. Only useful if you can
-- edit the files outside the game (singleplayer, or a server on your own PC),
-- since the maintainer has to be stopped to use edit in game. e.g. 30.
-- 0 = off. The files are read fresh every time the maintainer starts either way.
settings.reloadCheck = 0

return settings
