local component = require("component")
local computer = require("computer")

-- Discord webhook messages when entries start failing, work again, or keep failing,
-- and when the maintainer starts. Requests go straight to the internet card and are
-- never waited for: each one is checked on later cycles, so a slow or unreachable
-- Discord can't hold up the maintainer. Nothing here may stop the maintainer, so every
-- public function catches its own errors.
local Discord = {}

local FLAP_COOLDOWN = 1800 -- seconds before an entry is reported failing again after its last report
local REQUEST_TIMEOUT = 30 -- seconds before a request without an answer is given up
local MAX_OPEN = 2 -- requests open at once (an internet card allows 4 connections)
local MAX_QUEUE = 20 -- messages waiting to be sent; the oldest are dropped beyond this
local MAX_ATTEMPTS = 3 -- tries per message for errors other than rate limits
local MAX_RATE_LIMITED = 5 -- tries per message when Discord answers "too many requests"
local RETRY_WAIT = 60 -- seconds before a message that failed to send is tried again
local LIST_LIMIT = 1800 -- characters per embed list (Discord allows 4096 per embed, 6000 per message)
local LINE_LIMIT = 300 -- characters per line in a list
local RED, GREEN, GRAY = 0xE74C3C, 0x2ECC71, 0x95A5A6
local HEADERS = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "DiscordBot (https://github.com/Willshaper/Level-Maintainer, 1)",
}

-- Statuses that count as working again for an entry that was failing
local WORKING = {requested = true, crafting = true, stocked = true}

-- From settings.lua, via Discord.configure()
local url, name, mention, reminder = "", "", "", 0
local whitelist = false -- settings.discordList: true = only entries marked Discord, false = all but them

local cardChecked = false -- whether the internet card was checked since settings.lua was loaded
local cardOk = false
local disabled = false -- Discord rejected the webhook; off until settings.lua is reloaded
local warned = {} -- warnings already logged, so each shows once

local failures = {} -- name -> {amount, reason} of the entry's last failed request
local failing = {} -- name -> {since, reported, lastSent} for entries failing now
local lastReport = {} -- name -> uptime of its last "failing" message (kept after it recovers)
local startedEntries = nil -- entry count for the "started" message, sent with the first cycle

local queue = {} -- messages waiting to be sent: {body, attempts, limited, notBefore}
local open = {} -- requests sent and not answered yet: {handle, item, started}
local waitUntil = 0 -- uptime before which nothing is sent (Discord's rate limit)

-- Hides the webhook URL (and any other web address) in text that is logged:
-- anyone who has it can post to the channel
local function hideUrls(text)
    text = tostring(text)
    if url:find("^https?://") then -- a short typo like "x" would hide every x
        local start, stop = text:find(url, 1, true)
        while start do
            text = text:sub(1, start - 1) .. "<webhook URL>" .. text:sub(stop + 1)
            start, stop = text:find(url, start + 13, true)
        end
    end
    return (text:gsub("https?://[^%s\"'<>]+", "<URL>"))
end

Discord.hideUrls = hideUrls

local function warn(key, message)
    if not warned[key] then
        warned[key] = true
        logInfo("WARNING: " .. message)
    end
end

-- JSON ------------------------------------------------------------------------------

local ARRAY = {} -- metatable that marks a table as a JSON array, so an empty one is []
local function array(list)
    return setmetatable(list, ARRAY)
end

local ESCAPES = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}

-- A JSON string of plain ASCII. OpenComputers sends the body in the server's default
-- charset, so everything else is written as \uXXXX, decoded from UTF-8 by hand (no
-- utf8 library in Lua 5.2). A byte that isn't valid UTF-8 becomes U+FFFD.
local function encodeString(text)
    if not text:find("[%c\"\\\128-\255]") then
        return '"' .. text .. '"'
    end
    local out = {'"'}
    local i, size = 1, #text
    while i <= size do
        local byte = text:byte(i)
        if byte < 0x80 then
            local char = string.char(byte)
            if ESCAPES[char] then
                table.insert(out, ESCAPES[char])
            elseif byte < 0x20 or byte == 0x7F then
                table.insert(out, string.format("\\u%04x", byte))
            else
                table.insert(out, char)
            end
            i = i + 1
        else
            local length, code
            if byte >= 0xC2 and byte <= 0xDF then
                length, code = 2, byte - 0xC0
            elseif byte >= 0xE0 and byte <= 0xEF then
                length, code = 3, byte - 0xE0
            elseif byte >= 0xF0 and byte <= 0xF4 then
                length, code = 4, byte - 0xF0
            end
            for k = 1, (length or 1) - 1 do
                local follow = text:byte(i + k)
                if not follow or follow < 0x80 or follow > 0xBF then
                    length = nil
                    break
                end
                code = code * 64 + (follow - 0x80)
            end
            -- Overlong forms, surrogates and anything above U+10FFFF aren't valid either
            if length == 3 and (code < 0x800 or (code >= 0xD800 and code <= 0xDFFF)) then
                length = nil
            elseif length == 4 and (code < 0x10000 or code > 0x10FFFF) then
                length = nil
            end
            if not length then
                table.insert(out, "\\ufffd")
                i = i + 1
            elseif code >= 0x10000 then
                -- Above U+FFFF JSON needs a surrogate pair
                code = code - 0x10000
                table.insert(out, string.format("\\u%04x\\u%04x", 0xD800 + math.floor(code / 0x400), 0xDC00 + code % 0x400))
                i = i + length
            else
                table.insert(out, string.format("\\u%04x", code))
                i = i + length
            end
        end
    end
    table.insert(out, '"')
    return table.concat(out)
end

local function encode(value)
    local kind = type(value)
    if kind == "string" then
        return encodeString(value)
    elseif kind == "number" then
        if value == math.floor(value) and math.abs(value) < 2^53 then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local parts = {}
        if getmetatable(value) == ARRAY or value[1] ~= nil then
            for _, item in ipairs(value) do
                table.insert(parts, encode(item))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do
            table.insert(keys, key)
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            table.insert(parts, encodeString(key) .. ":" .. encode(value[key]))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

Discord.encode = encode -- for testing

-- Message text ------------------------------------------------------------------------

-- Cuts text to at most `limit` bytes without splitting a UTF-8 character
local function cut(text, limit)
    if #text <= limit then
        return text
    end
    local stop = limit
    while stop > 0 and text:byte(stop + 1) >= 0x80 and text:byte(stop + 1) < 0xC0 do
        stop = stop - 1
    end
    return text:sub(1, stop)
end

-- Stops Discord from reading * _ ~ ` | \ in names as formatting
local function plain(text)
    return (text:gsub("[\\%*_~`|]", "\\%0"))
end

-- "request failed (missing resources?)" -> "missing resources"
local function shortReason(reason)
    reason = tostring(reason or "request failed")
    return reason:match("^request failed %((.-)%??%)$") or reason
end

-- 7500 -> "2h 5m"
local function duration(seconds)
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return minutes .. "m"
    end
    return math.floor(minutes / 60) .. "h " .. (minutes % 60) .. "m"
end

-- "Tantalum Dust x2048: missing resources"
local function failureLine(entryName)
    local info = failures[entryName] or {}
    local line = plain(entryName)
    if info.amount then
        line = line .. " x" .. info.amount
    end
    return line .. ": " .. plain(shortReason(info.reason))
end

-- Lines joined, cut with "and N more" so the embed stays within Discord's limits
local function listText(lines)
    local text = ""
    for i, line in ipairs(lines) do
        line = cut(line, LINE_LIMIT)
        if i > 1 and #text + #line + 1 > LIST_LIMIT then
            return text .. "\nand " .. (#lines - i + 1) .. " more"
        end
        text = text .. (i > 1 and "\n" or "") .. line
    end
    return text
end

-- Current time for the embeds, e.g. "2026-10-29T14:02:11Z" (nil without a real clock)
local function isoTime()
    local now = realTime()
    if not now then
        return nil
    end
    local t = os.date("*t", math.floor(now))
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function embed(title, description, color, time)
    local label = "Level Maintainer"
    if name ~= "" then
        label = cut(label .. " - " .. name, 200)
    end
    return {title = title, description = description, color = color, author = {name = label}, timestamp = time}
end

-- The content and allowed_mentions for settings.discordMention. Only the users and
-- roles in it are pinged, never someone whose name happens to be in an entry.
local function mentionParts()
    local text = mention
    if text:match("^%s*%d+%s*$") then
        text = "<@" .. text:match("%d+") .. ">" -- a bare user id
    end
    local users, roles, parse = array({}), array({}), array({})
    for id in text:gmatch("<@!?(%d+)>") do
        table.insert(users, id)
    end
    for id in text:gmatch("<@&(%d+)>") do
        table.insert(roles, id)
    end
    if text:find("@everyone", 1, true) or text:find("@here", 1, true) then
        table.insert(parse, "everyone")
    end
    return cut(text, 1000), {parse = parse, users = users, roles = roles}
end

-- Sending ---------------------------------------------------------------------------

local function closeOpen()
    for _, request in ipairs(open) do
        pcall(request.handle.close)
    end
    open = {}
end

-- Whether this computer can reach Discord at all (logs why not, once)
local function checkCard()
    if not url:find("^https?://") then
        warn("discordUrl", "settings.discordWebhook is not a web address (it should start with https://); Discord messages are off.")
        return false
    end
    if not component.isAvailable("internet") then
        warn("discordCard", "settings.discordWebhook is set, but this computer has no internet card; Discord messages are off.")
        return false
    end
    local ok, enabled = pcall(component.internet.isHttpEnabled)
    if ok and enabled == false then
        warn("discordHttp", "HTTP is disabled in this server's OpenComputers config; Discord messages are off.")
        return false
    end
    return true
end

local function active()
    if url == "" or disabled then
        return false
    end
    if not cardChecked then
        cardChecked = true
        cardOk = checkCard()
    end
    return cardOk
end

local function enqueue(body)
    table.insert(queue, {body = body, attempts = 0, limited = 0, notBefore = 0})
    while #queue > MAX_QUEUE do
        table.remove(queue, 1)
    end
end

-- The HTTP status from a failed connection. Java reports 4xx/5xx answers as an error
-- ("Server returned HTTP response code: 429 for URL: ..."), and a 404 as just the URL.
local function codeFromError(problem)
    local code = tonumber(problem:match("response code: (%d%d%d)"))
    if not code and (problem:find("FileNotFound", 1, true) or problem:match("^%s*<webhook URL>%s*$")) then
        code = 404
    end
    return code
end

-- Seconds from a Retry-After header (header names are matched in any case)
local function retryAfter(headers)
    if type(headers) ~= "table" then
        return nil
    end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == "retry-after" then
            if type(value) == "table" then
                value = value[1]
            end
            local seconds = tonumber(value)
            if seconds then
                return math.min(math.max(seconds, 1), 600)
            end
        end
    end
    return nil
end

-- What happened to a sent message: done, retried later, or dropped
local function handleResult(item, code, problem, headers, now)
    if disabled then
        return
    end
    if code and code >= 200 and code < 300 then
        warned.discordSend = nil -- a later failure is worth a warning again
        return
    end
    if code == 401 or code == 403 or code == 404 then
        disabled = true
        queue = {}
        logInfo("WARNING: Discord webhook was rejected (HTTP " .. code .. "); check settings.discordWebhook. No more Discord messages until settings.lua is reloaded.")
        return
    end
    if code == 429 then
        waitUntil = now + (retryAfter(headers) or 5)
        item.limited = item.limited + 1
        if item.limited < MAX_RATE_LIMITED then
            table.insert(queue, 1, item)
        end
        return
    end
    item.attempts = item.attempts + 1
    warn("discordSend", "could not send a Discord message (" .. (code and ("HTTP " .. code) or hideUrls(problem))
        .. "); it is tried again later, a few times at most.")
    if item.attempts < MAX_ATTEMPTS then
        item.notBefore = now + RETRY_WAIT * item.attempts
        table.insert(queue, 1, item)
    end
end

-- Checks the open requests and closes the ones that are answered or took too long
local function poll(now)
    local still = {}
    local done = {}
    for _, request in ipairs(open) do
        local finished, code, problem, headers = false, nil, nil, nil
        local ok, connected = pcall(request.handle.finishConnect)
        if not ok then
            finished = true
            problem = hideUrls(connected)
            code = codeFromError(problem)
        elseif connected then
            local answered, status, _, responseHeaders = pcall(request.handle.response)
            if answered and status then
                finished, code, headers = true, tonumber(status), responseHeaders
            end
        end
        if not finished and now - request.started >= REQUEST_TIMEOUT then
            finished, problem = true, "no answer after " .. REQUEST_TIMEOUT .. "s"
        end
        if finished then
            pcall(request.handle.close)
            table.insert(done, {request.item, code, problem, headers})
        else
            table.insert(still, request)
        end
    end
    open = still
    -- Handled in reverse, so retried messages go back to the front of the queue in order
    for i = #done, 1, -1 do
        handleResult(done[i][1], done[i][2], done[i][3], done[i][4], now)
    end
end

local function send(now)
    while #open < MAX_OPEN and queue[1] and now >= waitUntil and now >= queue[1].notBefore do
        if not component.isAvailable("internet") then
            cardChecked = false -- the card was removed; warns once and stops
            if not active() then
                queue = {}
            end
            return
        end
        local item = table.remove(queue, 1)
        local ok, handle, reason = pcall(component.internet.request, url, item.body, HEADERS)
        if ok and handle then
            table.insert(open, {handle = handle, item = item, started = now})
        else
            handleResult(item, nil, ok and (reason or "request refused") or handle, nil, now)
            return
        end
    end
end

-- Public -------------------------------------------------------------------------------

-- Wraps a public function so an error in it is logged once instead of reaching the
-- maintainer. "interrupted" (Ctrl+Alt+C, Q) still stops the script.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            if err == "interrupted" then
                error(err, 0)
            end
            warn("discordBug", "Discord messages: " .. hideUrls(err))
        end
    end
end

-- Takes the discord* values from the settings
Discord.configure = guarded(function(settings)
    local newUrl = type(settings.discordWebhook) == "string" and settings.discordWebhook:match("^%s*(.-)%s*$") or ""
    if newUrl ~= url then
        cardChecked = false
    end
    url = newUrl
    name = type(settings.discordName) == "string" and settings.discordName or ""
    mention = type(settings.discordMention) == "string" and settings.discordMention or ""
    reminder = tonumber(settings.discordReminder) or 0
    local list = type(settings.discordList) == "string" and settings.discordList:lower() or "blacklist"
    if list ~= "blacklist" and list ~= "whitelist" then
        if url ~= "" then
            warn("discordList", 'settings.discordList should be "blacklist" or "whitelist"; using "blacklist".')
        end
        list = "blacklist"
    end
    whitelist = list == "whitelist"
    if url == "" then
        queue, failing, startedEntries = {}, {}, nil
    end
end)

-- settings.lua was loaded again: a rejected webhook is tried again and warnings show again
Discord.reset = guarded(function()
    disabled = false
    cardChecked = false
    warned = {}
    waitUntil = 0
end)

-- The maintainer started with this many entries; sent with the first cycle's message
Discord.started = guarded(function(entryCount)
    startedEntries = entryCount
end)

-- A request for an entry failed. amount: what was requested ("2048", "1000 mB");
-- reason: AE2's reason. Only remembered here; the message is sent by Discord.cycle.
Discord.failed = guarded(function(entryName, amount, reason)
    failures[entryName] = {amount = amount, reason = reason}
end)

-- Called at the end of every cycle with the entries and their statuses. Sends one
-- message with everything that changed, and checks earlier requests.
Discord.cycle = guarded(function(entries, statuses)
    local now = computer.uptime()
    poll(now)
    if not active() then
        -- Nothing was sent, so once it works again every failing entry is reported
        failing, lastReport, startedEntries = {}, {}, nil
        return
    end

    local newFailures, reminders, recovered = {}, {}, {}
    local listed = {}
    local anyMarked = false
    for _, entry in ipairs(entries) do
        local entryName = entry.name
        local status = statuses[entryName]
        local state = failing[entryName]
        listed[entryName] = true
        anyMarked = anyMarked or entry.discord == true
        -- settings.discordList: whitelist = only entries marked Discord, blacklist = all but them
        if (entry.discord == true) ~= whitelist then
            failing[entryName] = nil -- reported as new if it is switched back on while failing
        elseif status == "retry" then
            if not state then
                state = {since = now, reported = false}
                failing[entryName] = state
            end
            if not state.reported then
                -- An entry that keeps switching between failing and working is reported
                -- once per FLAP_COOLDOWN; until then it is checked again every cycle
                if not lastReport[entryName] or now - lastReport[entryName] >= FLAP_COOLDOWN then
                    state.reported, state.lastSent = true, now
                    lastReport[entryName] = now
                    table.insert(newFailures, failureLine(entryName))
                end
            elseif reminder > 0 and now - state.lastSent >= reminder * 3600 then
                state.lastSent = now
                table.insert(reminders, failureLine(entryName) .. " (for " .. duration(now - state.since) .. ")")
            end
        elseif state and WORKING[status] then
            if state.reported then
                table.insert(recovered, plain(entryName) .. ": " .. status)
            end
            failing[entryName] = nil
        end
    end
    if whitelist and not anyMarked and #entries > 0 then
        warn("discordNoneMarked", 'settings.discordList is "whitelist", but no entry in config.lua is marked Discord; only "Maintainer started" is sent.')
    end
    -- Entries removed from config.lua are forgotten
    for entryName in pairs(failing) do
        if not listed[entryName] then
            failing[entryName] = nil
        end
    end
    for entryName in pairs(failures) do
        if not listed[entryName] then
            failures[entryName] = nil
            lastReport[entryName] = nil
        end
    end

    if not startedEntries and #newFailures == 0 and #reminders == 0 and #recovered == 0 then
        send(now)
        return
    end
    local embeds = {}
    local time = isoTime() -- only now: reading the clock writes a file
    if startedEntries then
        local count = startedEntries == 1 and "1 entry" or (startedEntries .. " entries")
        table.insert(embeds, embed("Maintainer started", "Maintaining " .. count .. ".", GRAY, time))
        startedEntries = nil
    end
    if #newFailures > 0 then
        table.insert(embeds, embed("Crafts failing", listText(newFailures), RED, time))
    end
    if #reminders > 0 then
        table.insert(embeds, embed("Still failing", listText(reminders), RED, time))
    end
    if #recovered > 0 then
        table.insert(embeds, embed("Back to normal", listText(recovered), GREEN, time))
    end
    local body = {embeds = embeds, allowed_mentions = {parse = array({})}}
    if (#newFailures > 0 or #reminders > 0) and mention ~= "" then
        body.content, body.allowed_mentions = mentionParts()
    end
    enqueue(encode(body))
    send(now)
end)

-- Closes open requests when the maintainer stops
Discord.stop = guarded(function()
    closeOpen()
    queue = {}
end)

return Discord
