local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local shell = require("shell")
-- require keeps modules until a reboot; load them fresh so an update or an earlier
-- status table failure doesn't carry over into this run
for _, name in ipairs({"src.AE2", "src.Display", "src.Utility"}) do
    package.loaded[name] = nil
end
local ae2 = require("src.AE2")
local display = require("src.Display")
require("src.Utility") -- defines logInfo, setLogHandler, setTimeOffset and currentTime

-- config.lua and settings.lua are read with loadfile rather than require (which caches
-- until reboot), and reloaded whenever they are saved. Found the same way require would.
local function findFile(module)
    local path = package.searchpath(module, package.path)
    return path and shell.resolve(path) or shell.resolve(module .. ".lua")
end
local CONFIG_PATH = findFile("config")
local SETTINGS_PATH = findFile("settings")
local STARTUP_CHECK = 2 -- seconds between checks while waiting for a broken config.lua to be fixed
local KEY_HELP = "E edit config  S edit settings  R reload  Q quit"
local KEY_HELP_SHORT = "E config  S settings  R reload  Q quit"
local KEY_HELP_TINY = "E/S edit  R reload  Q quit"

-- Runs a Lua file that returns a table. Returns the table, or nil and an error message.
local function loadTable(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, tostring(err)
    end
    local ok, result = pcall(chunk)
    if not ok then
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, path .. " does not end with a return statement"
    end
    return result
end

-- Defaults for anything missing from settings.lua (e.g. an older install without it)
local function buildSettings(userSettings, cfg)
    local s = {
        sleep = (cfg and cfg.sleep) or 10,
        retryDelay = 60,
        requireFreeCpu = true,
        cpuName = nil,
        cacheDuration = 600,
        pollInterval = 1,
        logSkips = true,
        logRepeats = false,
        utcOffset = 0,
        reloadCheck = 0, -- live reload off; most players can't edit the file outside the game
        display = "table",
        showRecent = true,
        layout = "fit",
        cpuDisplay = "free",
    }
    for k, v in pairs(userSettings or {}) do
        s[k] = v
    end
    return s
end

local settings = buildSettings(nil, nil)
local userSettings = nil -- last successfully loaded settings.lua
local entries = {} -- {name, config, request} for every maintained entry, sorted by name
local configTime, settingsTime = nil, nil -- last-modified times of the loaded files

local warnedNoTable = false

-- Switches between the status table and the scrolling log when settings.display changes
local function updateDisplayMode()
    local wantTable = settings.display ~= "log"
    if wantTable and not display.isActive() then
        if not display.start() and not warnedNoTable then
            local reason = display.failure()
            if reason then
                logInfo("WARNING: the status table failed (" .. reason .. "); showing a scrolling log. Press R to try it again.")
            else
                logInfo("WARNING: the status table can't be shown (no graphics card); showing a scrolling log.")
            end
            warnedNoTable = true
        end
    elseif not wantTable and display.isActive() then
        display.stop()
    end
end

local function applySettings(cfg)
    settings = buildSettings(userSettings, cfg)
    ae2.configure(settings)
    setTimeOffset(settings.utcOffset)
    display.setShowRecent(settings.showRecent ~= false)
    display.setLayout(settings.layout)
    updateDisplayMode()
end

local function loadSettings()
    settingsTime = filesystem.lastModified(SETTINGS_PATH)
    local loaded, err = loadTable(SETTINGS_PATH)
    if not loaded then
        return false, err
    end
    userSettings = loaded
    return true
end

-- Runs fn protected so a component error (interface removed, stale craftable, ...)
-- is logged and retried next cycle instead of killing the maintainer.
local function try(fn, ...)
    local ok, success, answer, result, amount = pcall(fn, ...)
    if not ok then
        -- Ctrl+Alt+C raises "interrupted" from inside os.sleep; let it stop the script
        if success == "interrupted" then
            error(success, 0)
        end
        logInfo("ERROR: " .. tostring(success))
        ae2.clearCache()
        return false, nil, "error"
    end
    return success, answer, result, amount
end

local currentStatus = {} -- name -> what the entry is doing now (shown in the status table)
local lastLogged = {} -- name -> the last status message logged for it
local lastAmount = {} -- name -> last known amount in stock (entries with a threshold)
local amountCycle = {} -- name -> the cycle in which lastAmount was read
local cycleNumber = 0

-- logRepeats shows everything that happens, every cycle, in the status table's Recent
-- panel. The scrolling log (display = "log") always stays de-duplicated.
local function showEverything()
    return settings.logRepeats and display.isActive()
end

-- Sets an entry's status and logs the message, unless the last status message logged
-- for that entry was the same. Actions ("Requested ...") are logged separately and don't
-- count, so an entry that takes turns between "requested" and "no free CPU" logs
-- "no free CPU" only once.
local function logStatus(name, status, message)
    currentStatus[name] = status
    if lastLogged[name] == status and not showEverything() then
        return
    end
    lastLogged[name] = status
    logInfo(message)
end

-- Skips (already crafting, stocked, waiting to retry, no CPU) are hidden entirely with
-- logSkips = false (unless logRepeats shows everything)
local function skip(name, status, message)
    if settings.logSkips or showEverything() then
        logStatus(name, status, message)
    else
        currentStatus[name] = status
    end
end

local retryAt = {} -- name -> uptime before which a failed entry is not calculated again
local lastConfig = nil -- config in use, to tell which entries changed on reload
local warnedCpuName = false
local turn = 0 -- which entry goes first this cycle; moves on by one every cycle

-- Refreshed at the start of every cycle
local itemsCrafting, freeCpus, cpuBusy, totalCpus = {}, 0, {}, 0
local useNamedCpu = false

local function cpuAvailable()
    if not settings.requireFreeCpu then
        return true
    end
    if useNamedCpu then
        return not cpuBusy[settings.cpuName]
    end
    return freeCpus > 0
end

local function maintain(name, config, request)
    local now = computer.uptime()
    if itemsCrafting[name] == true then
        skip(name, "crafting", name .. " is already being crafted, skipping...")
    elseif retryAt[name] and now < retryAt[name] then
        skip(name, "retry", name .. " failed recently, retrying in " .. math.ceil(retryAt[name] - now) .. "s")
    elseif not cpuAvailable() then
        skip(name, "nocpu", name .. ": no free crafting CPU, skipping...")
    else
        local success, answer, result, amount = try(request, name, config[1], config[2], config[3])
        if amount ~= nil then
            lastAmount[name] = amount
            amountCycle[name] = cycleNumber
        end
        if result == "stocked" then
            skip(name, "stocked", answer)
        elseif result == "missing" then
            logStatus(name, "missing", answer)
        elseif result == "failed" then
            retryAt[name] = computer.uptime() + settings.retryDelay
            if settings.retryDelay > 0 then
                answer = answer .. ", retrying in " .. settings.retryDelay .. "s"
            end
            -- Logged every time; the retry wait that follows is covered by this message
            logInfo(answer)
            currentStatus[name] = "retry"
            lastLogged[name] = "retry"
        elseif result == "error" then
            currentStatus[name] = "error" -- already logged by try()
            lastLogged[name] = "error"
        else
            logInfo(answer) -- "Requested ...": an action, always logged
            currentStatus[name] = result
        end

        if result ~= "failed" then
            retryAt[name] = nil
        end

        -- The job now occupies a CPU for the rest of this cycle
        if success then
            freeCpus = freeCpus - 1
            if useNamedCpu then
                cpuBusy[settings.cpuName] = true
            end
        end
    end
end

-- 11968656 -> "11.97M"
local function formatAmount(n)
    if type(n) ~= "number" then
        return "-"
    end
    if n < 10000 then
        return tostring(math.floor(n))
    end
    for _, unit in ipairs({{1e12, "T"}, {1e9, "G"}, {1e6, "M"}, {1e3, "k"}}) do
        if n >= unit[1] then
            local value = n / unit[1]
            return string.format(value < 100 and "%.2f" or "%.1f", value) .. unit[2]
        end
    end
end

-- Status text, color and the short text for settings.layout = "tall"
local STATUS_TEXT = {
    crafting = {"crafting", "blue"},
    requested = {"requested", "yellow"},
    stocked = {"stocked", "green"},
    nocpu = {"waiting for CPU", "orange", "no CPU"},
    retry = {"failed", "red"}, -- the retry time is in the log line
    missing = {"not craftable", "red", "no pattern"},
    error = {"error", "red"},
}

-- Shown on top of the table, so they are on the first page
local PROBLEM = {retry = true, missing = true, error = true}

local nextCycleAt = nil -- uptime when the wait for the next cycle ends (nil while a cycle runs)

-- "CPUs free: 9/11", or "CPUs busy: 2/11" with settings.cpuDisplay = "busy"
local function cpuText()
    local free = math.max(freeCpus, 0)
    if settings.cpuDisplay == "busy" then
        return string.format("CPUs busy: %d/%d", math.max(totalCpus - free, 0), totalCpus)
    end
    return string.format("CPUs free: %d/%d", free, totalCpus)
end

-- Header parts; on a narrow screen the ones with the lowest `keep` are left out first
local function headerParts()
    local parts = {
        {text = "Level Maintainer", keep = 10},
        {text = currentTime(), keep = 40},
        {text = cpuText(), keep = 50},
        {text = "Entries: " .. #entries, keep = 30},
    }
    if nextCycleAt then
        table.insert(parts, {text = "Next cycle in " .. math.max(0, math.ceil(nextCycleAt - computer.uptime())) .. "s", keep = 90})
    end
    return parts
end

-- Refreshes the status table (does nothing in log mode)
local function render(title)
    if not display.isActive() then
        return
    end
    local rows = {}
    for _, entry in ipairs(entries) do
        local status = currentStatus[entry.name]
        local look = STATUS_TEXT[status] or {"waiting", "white"}
        table.insert(rows, {
            name = entry.name,
            stock = formatAmount(lastAmount[entry.name]),
            -- Not read this cycle (crafting, waiting to retry or for a CPU): shown in gray
            stockFrozen = lastAmount[entry.name] ~= nil and amountCycle[entry.name] ~= cycleNumber,
            want = formatAmount(entry.config[1]),
            batch = formatAmount(entry.config[2]),
            status = look[1],
            shortStatus = look[3] or look[1],
            color = look[2],
            problem = PROBLEM[status] == true,
        })
    end
    table.sort(rows, function(a, b)
        if a.problem ~= b.problem then
            return a.problem
        end
        return a.name < b.name
    end)
    display.update(rows, title or headerParts(), KEY_HELP, KEY_HELP_SHORT, KEY_HELP_TINY)
end

local function sameEntry(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Returns nil if a config entry is usable, otherwise what is wrong with it
local function entryProblem(name, conf)
    if type(name) ~= "string" then
        return "the name must be text in quotes, like [\"Osmium Dust\"] = {nil, 64}"
    end
    if type(conf) ~= "table" then
        return "the value must look like {threshold, batch_size}"
    end
    if conf[1] ~= nil and type(conf[1]) ~= "number" then
        return "the threshold must be a number or nil"
    end
    if type(conf[2]) ~= "number" or conf[2] < 1 then
        return "the batch size must be a number of at least 1"
    end
    if conf[3] ~= nil and type(conf[3]) ~= "string" then
        return "the third value (fluid name) must be text in quotes"
    end
    return nil
end

-- Returns the usable entries of a config block; broken ones are reported and skipped
local function validEntries(block, blockName)
    if block == nil then
        return nil
    end
    if type(block) ~= "table" then
        logInfo("ERROR: cfg." .. blockName .. " in config.lua must be a table; ignoring it.")
        return {}
    end
    local valid = {}
    for name, conf in pairs(block) do
        local problem = entryProblem(name, conf)
        if problem then
            logInfo("ERROR: config.lua entry " .. tostring(name) .. " in cfg." .. blockName .. ": " .. problem .. ". Skipping it.")
        else
            valid[name] = conf
        end
    end
    return valid
end

-- Counts added, changed and removed entries between two configs, and forgets the
-- logged status and retry wait of every new or changed entry so its status is shown again.
local function describeChanges(old, new)
    local added, changed, removed = 0, 0, 0
    local function scan(oldBlock, newBlock)
        for name, conf in pairs(newBlock or {}) do
            local prev = oldBlock and oldBlock[name]
            if not prev then
                added = added + 1
            elseif not sameEntry(prev, conf) then
                changed = changed + 1
            end
            if not prev or not sameEntry(prev, conf) then
                currentStatus[name] = nil
                lastLogged[name] = nil
                retryAt[name] = nil
            end
        end
        for name in pairs(oldBlock or {}) do
            if not (newBlock and newBlock[name]) then
                removed = removed + 1
            end
        end
    end
    scan(old and old.items, new.items)
    scan(old and old.fluids, new.fluids)
    return added .. " added, " .. changed .. " changed, " .. removed .. " removed"
end

local function applyConfig(cfg)
    local items = validEntries(cfg.items, "items") or {}
    local fluids = validEntries(cfg.fluids, "fluids")
    if fluids and next(fluids) ~= nil and not ae2.hasFluidSupport() then
        logInfo("WARNING: cfg.fluids is configured but the ME interface does not expose getFluidInNetwork (requires GTNH 2.9+). Fluid entries will be skipped.")
        fluids = nil
    end

    entries = {}
    for name, conf in pairs(items) do
        table.insert(entries, {name = name, config = conf, request = ae2.requestItem})
    end
    for name, conf in pairs(fluids or {}) do
        table.insert(entries, {name = name, config = conf, request = ae2.requestFluid})
    end
    table.sort(entries, function(a, b) return a.name < b.name end)

    lastConfig = cfg
    applySettings(cfg) -- an old config.lua may still set cfg.sleep
end

-- Loads config.lua. Returns the table, or nil and the error. Remembers the file's
-- modification time either way, so a broken file is only reported once per save.
local function readConfig()
    configTime = filesystem.lastModified(CONFIG_PATH)
    return loadTable(CONFIG_PATH)
end

-- Reloads config.lua and settings.lua if they were saved since they were last read.
-- A file with a mistake is reported and the previous version stays in use.
-- Returns true if anything was reloaded.
local function reloadIfChanged()
    local reloaded = false
    if filesystem.lastModified(SETTINGS_PATH) ~= settingsTime then
        local ok, err = loadSettings()
        if ok then
            applySettings(lastConfig)
            logInfo("Reloaded settings.lua")
            reloaded = true
        else
            logInfo("ERROR: settings.lua has a mistake, keeping the previous settings: " .. err)
        end
    end
    if filesystem.lastModified(CONFIG_PATH) ~= configTime then
        local cfg, err = readConfig()
        if cfg then
            local summary = describeChanges(lastConfig, cfg)
            applyConfig(cfg)
            logInfo("Reloaded config.lua (" .. summary .. ")")
            reloaded = true
        else
            logInfo("ERROR: config.lua has a mistake, keeping the previous config: " .. err)
        end
    end
    return reloaded
end

local nextReloadCheck = 0 -- uptime of the next check for edited files

-- Checks for edited files if settings.reloadCheck seconds have passed since the last
-- check (0 turns live reload off). Returns true if anything was reloaded.
local function checkForEdits()
    local interval = tonumber(settings.reloadCheck) or 0
    if interval <= 0 or computer.uptime() < nextReloadCheck then
        return false
    end
    nextReloadCheck = computer.uptime() + interval
    return reloadIfChanged()
end

-- Opens a file in the OpenOS editor; the status table is paused while it is open
local function editFile(path)
    display.suspend()
    shell.execute('edit "' .. path .. '"')
    display.resume()
end

-- Key codes (OpenOS keyboard.keys; pageUp is only in its lazily loaded full table)
local KEY_UP, KEY_DOWN, KEY_PAGE_UP, KEY_PAGE_DOWN = 0xC8, 0xD0, 0xC9, 0xD1

-- Waits up to `timeout` seconds while listening for keys:
--   E edits config.lua, S edits settings.lua, R reloads, Q quits,
--   Page Up/Down and the Up/Down arrows page through the status table.
-- Returns "edited" or "reload" when one of those keys was used, otherwise nil.
local function idle(timeout)
    local deadline = computer.uptime() + timeout
    repeat
        local wait = math.max(0, deadline - computer.uptime())
        local countdown = nextCycleAt ~= nil and display.isActive()
        if countdown then
            wait = math.min(wait, 1) -- wake every second to update "Next cycle in"
        end
        local name, _, char, code = event.pull(wait, "key_down")
        if name == "key_down" then
            if code == KEY_PAGE_DOWN or code == KEY_DOWN then
                display.changePage(1)
            elseif code == KEY_PAGE_UP or code == KEY_UP then
                display.changePage(-1)
            elseif char and char > 0 and char < 128 then
                local key = string.char(char):lower()
                if key == "e" then
                    editFile(CONFIG_PATH)
                    return "edited"
                elseif key == "s" then
                    editFile(SETTINGS_PATH)
                    return "edited"
                elseif key == "r" then
                    return "reload"
                elseif key == "q" then
                    error("interrupted", 0) -- stops the same way as Ctrl+Alt+C
                end
            end
        elseif countdown then
            display.setHeader(headerParts())
        end
    until computer.uptime() >= deadline
    return nil
end

-- Waits settings.sleep seconds, listening for keys. An edit or reload, or a live
-- reload check that finds a saved file, ends the wait early so the new config is
-- used right away.
local function waitForNextCycle()
    local deadline = nextCycleAt or (computer.uptime() + settings.sleep)
    repeat
        local wake = deadline
        if (tonumber(settings.reloadCheck) or 0) > 0 then
            wake = math.min(deadline, nextReloadCheck)
        end
        local action = idle(math.max(0, wake - computer.uptime()))
        if action then
            if action == "reload" and display.retry() then
                warnedNoTable = false
                updateDisplayMode()
            end
            if not reloadIfChanged() then
                logInfo("config.lua and settings.lua are unchanged.")
            end
            return
        end
        if checkForEdits() then
            return
        end
    until computer.uptime() >= deadline
end

local function run()
    while true do
        checkForEdits()
        cycleNumber = cycleNumber + 1
        display.beginBatch()

        local ok
        ok, itemsCrafting, freeCpus, cpuBusy, totalCpus = pcall(ae2.checkIfCrafting)
        if not ok then
            -- The network can't be read right now; requests would fail too, so wait for the next cycle
            logInfo("ERROR: " .. tostring(itemsCrafting))
            ae2.clearCache()
            itemsCrafting, freeCpus, cpuBusy, totalCpus = {}, 0, {}, 0
        else
            useNamedCpu = settings.cpuName ~= nil and cpuBusy[settings.cpuName] ~= nil
            if settings.cpuName ~= nil and not useNamedCpu and not warnedCpuName then
                logInfo("WARNING: no crafting CPU named '" .. settings.cpuName .. "' found, AE2 will use any CPU.")
                warnedCpuName = true
            end

            -- Start one entry further along each cycle, so with few free CPUs every
            -- entry gets its turn instead of the same one winning every time
            local count = #entries
            if count > 0 then
                local first = turn % count
                for i = 0, count - 1 do
                    local entry = entries[(first + i) % count + 1]
                    maintain(entry.name, entry.config, entry.request)
                end
                turn = turn + 1
            end
        end

        nextCycleAt = computer.uptime() + settings.sleep
        render()
        display.endBatch()
        waitForNextCycle()
        nextCycleAt = nil
    end
end

-- At boot the computer can start before the adapter/interface is ready, so wait for it
local function waitForInterface()
    if ae2.connect() then
        return
    end
    logInfo("Waiting for an ME interface (adapter touching a full-block ME interface)...")
    render("Level Maintainer   waiting for an ME interface")
    repeat
        idle(5)
    until ae2.connect()
    logInfo("ME interface found.")
end

-- At startup a broken config.lua is reported and the maintainer waits for it to be fixed
local function loadInitialConfig()
    local cfg, err = readConfig()
    if not cfg then
        logInfo("ERROR: config.lua has a mistake: " .. err)
        logInfo("Press E to fix it in the editor (or fix and save it another way); the maintainer starts as soon as it loads.")
        render("Level Maintainer   config.lua has a mistake")
        repeat
            idle(STARTUP_CHECK)
            if filesystem.lastModified(CONFIG_PATH) ~= configTime then
                cfg, err = readConfig()
                if not cfg then
                    logInfo("ERROR: config.lua still has a mistake: " .. err)
                end
            end
        until cfg
        logInfo("config.lua loaded.")
    end
    applyConfig(cfg)
end

local function main()
    local ok, err = loadSettings()
    applySettings(nil)
    if not ok then
        logInfo("WARNING: could not load settings.lua, using defaults (" .. err .. ")")
    end
    if not display.isActive() then
        logInfo("Keys (between cycles): " .. KEY_HELP .. ". Ctrl+Alt+C also stops it.")
    end

    -- src.AE2 stays loaded between runs, so forget lookups from a previous run
    -- (e.g. a pattern added in AE2 since then would still count as not craftable)
    ae2.clearCache()
    waitForInterface()
    loadInitialConfig()

    -- run() only ends by an error. Anything other than Ctrl+Alt+C or Q is logged and the
    -- loop restarts after a pause, so one unexpected error doesn't stop maintenance.
    while true do
        local _, err = pcall(run)
        if err == "interrupted" then
            error(err, 0)
        end
        display.endBatch()
        nextCycleAt = nil
        local delay = math.max(tonumber(settings.retryDelay) or 0, 5)
        logInfo("ERROR: " .. tostring(err))
        logInfo("Restarting in " .. delay .. "s...")
        ae2.clearCache()
        idle(delay)
    end
end

-- Ctrl+Alt+C raises "interrupted" from inside os.sleep (Q raises the same). Exit
-- quietly instead of letting OpenOS print it as an error with a stack trace.
local ok, err = xpcall(main, function(msg)
    if msg == "interrupted" then
        return msg
    end
    return debug.traceback(tostring(msg), 2)
end)
display.stop()
if not ok then
    if err == "interrupted" then
        logInfo("Maintainer stopped.")
    else
        error(err, 0)
    end
end
