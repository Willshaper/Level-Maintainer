local settings = {}

-- Press S in the maintainer to edit this file. A setting that is left out uses its default.

settings.sleep = 10          -- seconds between cycles (each cycle checks every entry once)
settings.retryDelay = 60     -- seconds before a failed craft is tried again
settings.cpuName = nil       -- crafting CPU to use, as named in AE2, e.g. "Maintainer" (nil = any)
settings.utcOffset = 0       -- hours added to UTC for timestamps (1 = CET, 2 = CEST, -5 = EST)
settings.screen = "fit"      -- "fit" = largest text that fits, "columns" = side-by-side tables,
                             -- "log" = scrolling log
settings.showRecent = true   -- show the Recent log below the table
settings.log = "changes"     -- Recent log: "changes" = when an entry's status changes,
                             -- "all" = everything, every cycle, "problems" = only requests and failures
settings.cpuDisplay = "free" -- header: "free" = "CPUs free: 9/11", "busy" = "CPUs busy: 2/11"

-- Table columns, left to right. Use any of these words, in any order:
--   Name    = the entry's label (always shown)
--   Stock   = amount in the ME system (gray when it wasn't read this cycle)
--   Want    = the threshold to keep in stock
--   Batch   = how many are requested at once
--   Status  = what the entry is doing: stocked, crafting, failed, ...
--   Percent = stock as a percentage of Want ("112%"), narrower than Stock + Want
--   Symbol  = a one-character status instead of the Status word
-- Fewer columns = narrower rows = larger text with screen = "fit".
-- Example for a narrow screen: settings.columns = "Name Percent Symbol"
settings.columns = "Name Stock Want Batch Status"
settings.legend = true        -- without Status: a line under the table explains the colors ("stocked  failed")
settings.shortNumbers = false -- true = 3-digit numbers (112M, 12.5k) instead of 4 (112.5M, 12.50k)

-- Advanced
settings.requireFreeCpu = true -- only start a craft when a crafting CPU (or cpuName) is idle
settings.cacheDuration = 600   -- seconds before a newly added pattern is noticed
settings.pollInterval = 1      -- seconds between checks while AE2 calculates a craft
settings.reloadCheck = 0       -- seconds between checks for files saved outside the game (0 = off)

return settings
