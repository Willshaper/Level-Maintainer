local shell = require("shell")
local filesystem = require("filesystem")
local component = require("component")
local scripts = {"src/AE2.lua", "src/Display.lua", "src/Utility.lua", "Maintainer.lua"}

local repo = "https://raw.githubusercontent.com/Willshaper/Level-Maintainer/";
local api = "https://api.github.com/repos/Willshaper/Level-Maintainer/commits/";
local branch = "master"
local dir = shell.getWorkingDirectory()

-- GitHub caches each file on a branch for up to 5 minutes, so right after an update
-- some downloads could be old and others new. Downloading from the latest commit's
-- id instead always gives one matching set. Returns nil if it can't be looked up.
local function latestCommit()
    local ok, sha = pcall(function()
        local internet = require("internet")
        local body = ""
        for chunk in internet.request(api .. branch, nil, {["User-Agent"] = "Level-Maintainer installer"}) do
            body = body .. chunk
            if #body > 2048 then
                break -- the commit id is at the start of the response
            end
        end
        return body:match('"sha"%s*:%s*"(%x+)"')
    end)
    return ok and sha or nil
end

local ref = latestCommit()
if ref then
    print("Installing version " .. ref:sub(1, 7))
else
    ref = branch
    print("Could not look up the latest version; downloading from " .. branch .. " (may be a few minutes behind).")
end

local function path(filename)
    return dir .. "/" .. filename
end

-- Files are downloaded to a temporary name first, and only put in place once every
-- download worked: a failed download (no internet card, GitHub down) leaves the
-- existing install untouched instead of a mix of old and new scripts.
-- (wget leaves an empty file behind when a download fails.)
local function temp(filename)
    return path(filename .. ".download")
end

local function download(filename)
    filesystem.remove(temp(filename))
    shell.execute(string.format("wget -f %s%s/%s %s", repo, ref, filename, temp(filename)))
    return filesystem.exists(temp(filename)) and filesystem.size(temp(filename)) > 0
end

local function readFile(filePath)
    local file = io.open(filePath, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

-- An existing settings.lua. The current one is downloaded as well, so the user can be
-- offered to switch when theirs is older (missing settings that were added since).
local oldSettings = readFile(path("settings.lua"))

if not filesystem.exists(path("src")) then
    filesystem.makeDirectory(path("src"))
end

local wanted = {}
for _, file in ipairs(scripts) do
    table.insert(wanted, file)
end
-- config.lua and settings.lua are yours; only fetched when missing
for _, file in ipairs({"config.lua", "settings.lua"}) do
    if not filesystem.exists(path(file)) then
        table.insert(wanted, file)
    end
end

local downloads = {}
for _, file in ipairs(wanted) do
    table.insert(downloads, file)
end
if oldSettings then
    table.insert(downloads, "settings.lua")
end

local failed = {}
for _, file in ipairs(downloads) do
    if not download(file) then
        table.insert(failed, file)
    end
end

if #failed > 0 then
    for _, file in ipairs(downloads) do
        filesystem.remove(temp(file))
    end
    print()
    print("Could not download: " .. table.concat(failed, ", "))
    print("Nothing was changed. Check that the computer has an internet card and")
    print("try again. Not rebooting.")
    return
end

for _, file in ipairs(wanted) do
    filesystem.remove(path(file))
    filesystem.rename(temp(file), path(file))
end

local function ask(question)
    io.write(question .. " [y/N] ")
    local answer = io.read()
    return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

-- The values set in the old settings.lua, under their new names
local function oldSettingValues()
    local chunk, err = load(oldSettings, "=settings.lua", "t", {})
    if not chunk then
        error(err, 0)
    end
    local old = chunk()
    if type(old) ~= "table" then
        error("it does not return the settings", 0)
    end
    local values = {}
    for key, value in pairs(old) do
        values[key] = value
    end
    if old.screen == nil then
        if old.display == "log" then
            values.screen = "log"
        elseif old.layout ~= nil then
            values.screen = old.layout
        end
    end
    if old.log == nil then
        if old.logRepeats then
            values.log = "all"
        elseif old.logSkips == false then
            values.log = "problems"
        end
    end
    return values
end

local function serialize(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

-- The new settings.lua with the old file's values filled in. Returns the text and the
-- names of the settings whose values were carried over.
local function mergedSettings()
    local values = oldSettingValues()
    local carried = {}
    local text = readFile(temp("settings.lua")):gsub("[^\r\n]+", function(line)
        local key, value, comment = line:match("^settings%.([%w_]+)%s*=%s*(.-)%s*(%-%-.*)$")
        if not key then
            key, value = line:match("^settings%.([%w_]+)%s*=%s*(.-)%s*$")
        end
        if not key or values[key] == nil or serialize(values[key]) == value then
            return line
        end
        table.insert(carried, key)
        local assignment = "settings." .. key .. " = " .. serialize(values[key])
        if not comment then
            return assignment
        end
        -- keep the comment where it was, so the comments stay lined up
        local column = #line - #comment
        return assignment .. string.rep(" ", math.max(1, column - #assignment)) .. comment
    end)
    return text, carried
end

-- Settings in the new settings.lua that the user's file doesn't have
local function missingSettings()
    local missing = {}
    for key in ("\n" .. readFile(temp("settings.lua"))):gmatch("\nsettings%.([%w_]+)%s*=") do
        if not oldSettings:find("settings%." .. key .. "%s*=") then
            table.insert(missing, key)
        end
    end
    return missing
end

local function sameText(a, b)
    return (a:gsub("\r\n", "\n")) == (b:gsub("\r\n", "\n"))
end

-- Offer the current settings.lua whenever it differs from the user's file with their
-- values filled in: new settings, or updated explanations
if oldSettings then
    local ok, merged, carried = pcall(mergedSettings)
    if not ok then
        print()
        print("Could not read your settings.lua (" .. tostring(merged) .. "), so it can't be updated; it was left as it is.")
    elseif not sameText(merged, oldSettings) then
        print()
        local missing = missingSettings()
        if not oldSettings:find("settings%.screen") then
            print("Your settings.lua is the older, longer version; the new one has fewer, simpler settings.")
        elseif #missing > 0 then
            print("Your settings.lua doesn't have these newer settings: " .. table.concat(missing, ", "))
        else
            print("There is a newer settings.lua with updated explanations.")
        end
        if ask("Replace it with the new one? Your values are kept, and the old file is saved as settings.lua.old.") then
            filesystem.remove(path("settings.lua.old"))
            filesystem.rename(path("settings.lua"), path("settings.lua.old"))
            local file = io.open(path("settings.lua"), "w")
            file:write(merged)
            file:close()
            if #carried > 0 then
                print("New settings.lua written. Kept your values for: " .. table.concat(carried, ", "))
            else
                print("New settings.lua written (you had only default values).")
            end
        else
            print("Kept your settings.lua; it still works (missing settings use their defaults).")
        end
    end
end
filesystem.remove(temp("settings.lua"))

-- Auto-start: OpenOS runs every line of /home/.shrc when the shell starts
local shrc = (os.getenv("HOME") or "/home") .. "/.shrc"
local function autostartEnabled()
    local file = io.open(shrc, "r")
    if not file then
        return false
    end
    local content = file:read("*a")
    file:close()
    return content:find("Maintainer", 1, true) ~= nil
end

print()
if autostartEnabled() then
    print("Auto-start is already on (" .. shrc .. "). Delete the Maintainer line there to turn it off.")
elseif ask("Start Maintainer automatically when the computer boots?") then
    local file = io.open(shrc, "a")
    file:write(string.format('cd "%s" && Maintainer\n', shell.getWorkingDirectory()))
    file:close()
    print("Auto-start on. Delete the Maintainer line in " .. shrc .. " to turn it off.")
end

-- Wake-on-redstone: with a redstone card, a rising redstone signal turns the computer on
-- (a running computer ignores it), so a slow redstone clock restarts it after a power loss
if component.isAvailable("redstone") then
    local redstone = component.redstone
    if redstone.getWakeThreshold() > 0 then
        print("Wake-on-redstone is already on (threshold " .. redstone.getWakeThreshold() .. ").")
    elseif ask("Turn the computer on when it receives a redstone signal (for a watchdog clock)?") then
        redstone.setWakeThreshold(1)
        print("Wake-on-redstone on. A redstone pulse into the computer now starts it if it is off.")
        print("Keep the signal away from the screen: a redstone pulse turns an OC screen on or off.")
    end
end

print("Rebooting...")
os.sleep(2)
shell.execute("reboot");