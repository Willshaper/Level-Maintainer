-- Full-screen status view: a table with one row per maintained entry, a panel with
-- the most recent log lines and a line listing the keys. With settings.screen = "log"
-- the maintainer prints a scrolling log instead.
local component = require("component")
local term = require("term")
local unicode = require("unicode")

local Display = {}

local HISTORY = 200 -- log lines kept in memory
Display.history = {}

local gpu = nil
local active = false
local suspended = false -- true while another program (edit) uses the screen
local batching = false -- true while a cycle runs; the screen is redrawn once at its end
local rows = {}
local header = {} -- list of {text, keep}; parts with a lower `keep` are dropped first on narrow screens
local footer = ""
local footerShort = "" -- used when the full key help doesn't fit
local footerTiny = "" -- used when the short key help doesn't fit either
local showRecent = true -- false: no recent log panel, the table uses the whole screen
local page = 1 -- which page of the table is shown when it has more rows than fit

-- "fit": set the resolution so the rows fill the screen with text as large as possible
--        (with the narrow columns of "tall" on a screen that is taller than wide)
-- "columns": keep the resolution and put the rows in side-by-side tables when there is room
-- "fixed": keep the resolution, one table
-- "tall": like "fit", always with narrow columns and short status words
local layoutMode = "fit"
local originalResolution = nil -- {width, height} before the maintainer changed it
local screenRatio = nil -- resolution width per line of height that fills the screen exactly
local portrait = false -- the screen is more blocks high than wide

local COLORS = {
    white = 0xFFFFFF,
    gray = 0xAAAAAA,
    green = 0x55FF55,
    yellow = 0xFFFF55,
    orange = 0xFFAA00,
    red = 0xFF5555,
    cyan = 0x55FFFF,
    blue = 0x55AAFF,
}

local MAX_NAME_WIDTH = 50 -- so the numbers stay next to the names on wide screens
local MIN_SCREEN_WIDTH = 26 -- narrowest resolution "fit" picks: the shortest key help fits
local TABLE_GAP = " | "

-- The columns settings.columns can list, besides Name. wide / narrow: width on wide
-- screens and with the narrow columns of "tall"; narrowKey: the row field shown with
-- narrow columns; frozen: drawn gray when the stock wasn't read this cycle.
local COLUMN_TYPES = {
    stock = {title = "Stock", key = "stock", wide = 8, narrow = 6, number = true, right = true, frozen = true},
    want = {title = "Want", key = "want", wide = 8, narrow = 6, number = true, right = true},
    batch = {title = "Batch", key = "batch", wide = 7, narrow = 6, number = true, right = true},
    percent = {title = "%", key = "percent", wide = 5, narrow = 5, right = true, frozen = true}, -- fits ">999%"
    status = {title = "Status", key = "status", narrowKey = "shortStatus", wide = 15, narrow = 10}, -- fits "waiting for CPU" / "no pattern"
    symbol = {title = "", key = "symbol", wide = 1, narrow = 1},
}
local SHORT_NUMBER_WIDTH = 5 -- settings.shortNumbers: "112M", "1.25k"
-- Dropped first, in this order, when a table is too narrow for all its columns
local DROP_ORDER = {"batch", "want", "stock", "percent"}

local columnList = {"name", "stock", "want", "batch", "status"} -- settings.columns, in order
local shortNumbers = false

-- Narrow columns and short status words: layout "tall", or "fit" on a portrait screen
local function narrowColumns()
    return layoutMode == "tall" or (layoutMode == "fit" and portrait)
end

local function minNameWidth()
    return narrowColumns() and 12 or 16
end

-- The columns of settings.columns with their sizes for the current layout. Each has
-- title, key, width, gap (spaces before it) and right (right-aligned); the name column
-- has name = true and no width yet.
local function columnSet()
    local narrow = narrowColumns()
    local columns = {}
    for _, kind in ipairs(columnList) do
        local column
        if kind == "name" then
            column = {kind = kind, name = true, title = "Name", key = "name"}
        else
            local def = COLUMN_TYPES[kind]
            local width = narrow and def.narrow or def.wide
            if def.number and shortNumbers then
                width = SHORT_NUMBER_WIDTH
            end
            column = {kind = kind, title = def.title, key = narrow and def.narrowKey or def.key, width = width,
                right = def.right, frozen = def.frozen}
        end
        -- One space between columns; two before a wide Status column, as it is text
        column.gap = #columns == 0 and 0 or ((kind == "status" and not narrow) and 2 or 1)
        table.insert(columns, column)
    end
    return columns
end

-- Width of everything in a row except the name
local function fixedWidth(columns)
    local used = 0
    for _, column in ipairs(columns) do
        used = used + column.gap + (column.width or 0)
    end
    return used
end

-- The narrowest side-by-side table for layout "columns"
local function minTableWidth()
    return 20 + fixedWidth(columnSet())
end

-- True when the table has no Status column, so a line under it explains the colors
local function showLegend()
    for _, kind in ipairs(columnList) do
        if kind == "status" then
            return false
        end
    end
    return true
end

local function showsSymbols()
    for _, kind in ipairs(columnList) do
        if kind == "symbol" then
            return true
        end
    end
    return false
end

-- Pads or cuts text to exactly `width` characters (cut text ends with "~")
local function fit(text, width)
    text = tostring(text or "")
    local length = unicode.len(text)
    if length > width then
        if width <= 1 then
            return unicode.sub(text, 1, width)
        end
        return unicode.sub(text, 1, width - 1) .. "~"
    end
    return text .. string.rep(" ", width - length)
end

local function fitRight(text, width)
    text = tostring(text or "")
    local length = unicode.len(text)
    if length >= width then
        return fit(text, width)
    end
    return string.rep(" ", width - length) .. text
end

-- The legend under a table without a Status column: the statuses on screen, each in
-- its color (with its symbol when the table has a Symbol column), packed into lines of
-- at most `width` characters. Returns a list of lines, each a list of {text, color, x}.
local function legendLines(width)
    if not showLegend() then
        return {}
    end
    local seen, items = {}, {}
    for _, row in ipairs(rows) do
        local word = row.shortStatus or row.status
        if not seen[word] then
            seen[word] = true
            local text = showsSymbols() and ((row.symbol or "?") .. " " .. word) or word
            table.insert(items, {text = text, color = row.color, rank = row.rank or 0})
        end
    end
    table.sort(items, function(a, b) return a.rank < b.rank end)
    local lines, line, x = {}, nil, 1
    for _, item in ipairs(items) do
        local length = unicode.len(item.text)
        if line and x + 2 + length - 1 > width then
            line = nil
        end
        if not line then
            line, x = {}, 1
            table.insert(lines, line)
        else
            x = x + 2
        end
        table.insert(line, {text = item.text, color = item.color, x = x})
        x = x + length
    end
    return lines
end

-- Screen areas for a resolution: line 1 header, line 2 column titles, then the table
-- rows, the color legend (tables without a Status column), a separator, the recent log
-- lines, and the key help on the last line. Without the recent panel the table and
-- legend go down to the key help line.
-- Returns the number of log lines, the separator line (or nil), the table rows and the
-- first legend line.
local function areas(height, width)
    local legend = #legendLines(width)
    if not showRecent then
        return 0, nil, math.max(1, height - 3 - legend), height - legend
    end
    local logLines = math.max(3, math.floor(height * 0.3))
    if layoutMode ~= "columns" then
        -- Table lines no row needs go to the recent panel
        logLines = logLines + math.max(0, height - 4 - legend - logLines - #rows)
    end
    local separatorY = height - 1 - logLines
    return logLines, separatorY, math.max(1, separatorY - 3 - legend), separatorY - legend
end

local function layout()
    local width, height = gpu.getResolution()
    local logLines, separatorY, tableRows, legendY = areas(height, width)
    return width, height, logLines, separatorY, tableRows, legendY
end

-- Number of side-by-side tables for a screen width
local function tableCount(width)
    if layoutMode ~= "columns" then
        return 1
    end
    local count = math.floor((width + #TABLE_GAP) / (minTableWidth() + #TABLE_GAP))
    return math.max(1, math.min(count, #rows))
end

-- Rows that fit on one page
local function pageSize(width, tableRows)
    return tableRows * tableCount(width)
end

local function pageCount(width, tableRows)
    return math.max(1, math.ceil(#rows / pageSize(width, tableRows)))
end

-- Returns a function that sets the text color (does nothing on a GPU without
-- colors) and whether colors are available
local function colorSetter()
    local colors = gpu.getDepth() > 1
    return function(name)
        if colors then
            gpu.setForeground(COLORS[name] or COLORS.white)
        end
    end, colors
end

-- The columns that fit in a table `width` wide next to a readable name: on narrow
-- tables Batch is dropped first, then Want, Stock and Percent. Fills in the name's
-- width and each column's offset (characters from the table's left edge).
local function columnsFor(width)
    local columns = columnSet()
    local minName = minNameWidth()
    for _, kind in ipairs(DROP_ORDER) do
        if width - fixedWidth(columns) >= minName then
            break
        end
        for i, column in ipairs(columns) do
            if column.kind == kind then
                table.remove(columns, i)
                if i == 1 and columns[1] then
                    columns[1].gap = 0
                end
                break
            end
        end
    end
    local offset = 0
    for _, column in ipairs(columns) do
        if column.name then
            column.width = math.max(8, math.min(MAX_NAME_WIDTH, width - fixedWidth(columns)))
        end
        offset = offset + column.gap
        column.offset = offset
        offset = offset + column.width
    end
    return columns
end

local function formatRow(columns, row)
    local parts = {}
    for _, column in ipairs(columns) do
        local value = row[column.key]
        table.insert(parts, string.rep(" ", column.gap) .. (column.right and fitRight or fit)(value, column.width))
    end
    return table.concat(parts)
end

-- The resolution for layouts "fit" and "tall": the smallest one (so the largest text)
-- that shows every row, in the shape of the screen so the text fills it edge to edge.
-- Wide columns make room for the whole name; narrow ones only for a short one and give
-- the name whatever width the screen's shape leaves over.
local function fitResolution()
    local maxWidth, maxHeight = gpu.maxResolution()
    local ratio = screenRatio or (maxWidth / maxHeight)
    local nameWidth = minNameWidth()
    if not narrowColumns() then
        for _, row in ipairs(rows) do
            nameWidth = math.max(nameWidth, math.min(unicode.len(row.name), MAX_NAME_WIDTH))
        end
    end
    local needWidth = math.min(maxWidth, math.max(MIN_SCREEN_WIDTH, nameWidth + fixedWidth(columnSet())))
    for height = 5, maxHeight do
        local width = math.min(maxWidth, math.floor(height * ratio))
        local _, _, tableRows = areas(height, width)
        if tableRows >= #rows and width >= needWidth then
            return width, height
        end
    end
    -- More rows than fit on one page, or a screen too narrow for the columns: all
    -- lines, as wide as the screen's shape allows but at least wide enough for them
    return math.min(maxWidth, math.max(needWidth, math.floor(maxHeight * ratio))), maxHeight
end

local function setResolution(width, height)
    local currentWidth, currentHeight = gpu.getResolution()
    if width ~= currentWidth or height ~= currentHeight then
        gpu.setResolution(width, height)
    end
end

-- Puts the screen in the resolution the layout wants: fitted for "fit" and "tall",
-- the resolution from before the maintainer started for the others
local function applyResolution()
    if layoutMode == "fit" or layoutMode == "tall" then
        setResolution(fitResolution())
    elseif originalResolution then
        setResolution(originalResolution[1], originalResolution[2])
    end
end

-- Joins the header parts to fit the width: first with smaller gaps, then by dropping
-- the least important parts (the page number is kept longest).
local function headerLine(width, pages)
    local parts = {}
    for _, part in ipairs(header) do
        table.insert(parts, part)
    end
    if pages > 1 then
        table.insert(parts, {text = "Page " .. math.min(page, pages) .. "/" .. pages, keep = 100})
    end
    while true do
        local texts = {}
        for _, part in ipairs(parts) do
            table.insert(texts, part.text)
        end
        for _, gap in ipairs({"   ", "  "}) do
            local line = table.concat(texts, gap)
            if unicode.len(line) <= width or #parts <= 1 then
                return line
            end
        end
        local lowest = 1
        for i, part in ipairs(parts) do
            if part.keep < parts[lowest].keep then
                lowest = i
            end
        end
        table.remove(parts, lowest)
    end
end

local function drawHeader()
    local width, _, _, _, tableRows = layout()
    colorSetter()("cyan")
    gpu.set(1, 1, fit(headerLine(width, pageCount(width, tableRows)), width))
end

-- Draws one table of rows starting at column x
local function drawSubTable(x, tableWidth, tableRows, pageRows, setColor, colors)
    local columns = columnsFor(tableWidth)
    local titles = {}
    for _, column in ipairs(columns) do
        titles[column.key] = column.title
    end
    setColor("gray")
    gpu.set(x, 2, fit(formatRow(columns, titles), tableWidth))
    for i = 1, tableRows do
        local row = pageRows[i]
        if row then
            setColor(row.color)
            gpu.set(x, 2 + i, fit(formatRow(columns, row), tableWidth))
            -- Stock (and Percent) that wasn't read this cycle is redrawn in gray
            if row.stockFrozen and colors then
                for _, column in ipairs(columns) do
                    if column.frozen and column.offset + column.width <= tableWidth then
                        setColor("gray")
                        gpu.set(x + column.offset, 2 + i, fitRight(row[column.key], column.width))
                    end
                end
            end
        else
            gpu.fill(x, 2 + i, tableWidth, 1, " ")
        end
    end
end

-- The color legend under a table without a Status column
local function drawLegend(width, legendY, setColor)
    for i, line in ipairs(legendLines(width)) do
        local y = legendY + i - 1
        gpu.fill(1, y, width, 1, " ")
        for _, item in ipairs(line) do
            setColor(item.color)
            gpu.set(item.x, y, fit(item.text, math.max(0, math.min(unicode.len(item.text), width - item.x + 1))))
        end
    end
end

local function drawTable()
    local width, _, _, separatorY, tableRows, legendY = layout()
    local setColor, colors = colorSetter()
    page = math.min(page, pageCount(width, tableRows))

    drawHeader()

    -- This page's rows, shared evenly between the side-by-side tables
    local tables = tableCount(width)
    local first = (page - 1) * pageSize(width, tableRows)
    local onPage = math.min(#rows - first, pageSize(width, tableRows))
    local perTable = math.max(1, math.ceil(onPage / tables))
    local tableWidth = math.floor((width - (tables - 1) * #TABLE_GAP) / tables)
    for t = 1, tables do
        local pageRows = {}
        for i = 1, perTable do
            local index = (t - 1) * perTable + i
            if index <= onPage then
                pageRows[i] = rows[first + index]
            end
        end
        local x = 1 + (t - 1) * (tableWidth + #TABLE_GAP)
        drawSubTable(x, tableWidth, tableRows, pageRows, setColor, colors)
        if t < tables then
            setColor("gray")
            for y = 2, 2 + tableRows do
                gpu.set(x + tableWidth, y, TABLE_GAP)
            end
        end
    end

    drawLegend(width, legendY, setColor)

    if separatorY then
        setColor("gray")
        gpu.set(1, separatorY, fit("-- Recent " .. string.rep("-", math.max(0, width - 10)), width))
    end
end

-- Splits a log line into pieces of at most `width` characters, breaking at a space
-- where there is one in the second half of the piece. The pieces after the first are
-- indented to start below the text after the timestamp.
local function wrapLine(line, width)
    local stamp = line:match("^%[[%d:]+%] ")
    local indent = (stamp and width - #stamp >= 20) and #stamp or math.min(2, width - 1)
    local pieces = {}
    local rest, room = line, width
    while unicode.len(rest) > room do
        local cut = nil
        for p = room + 1, math.floor(room / 2) + 1, -1 do
            if unicode.sub(rest, p, p) == " " then
                cut = p
                break
            end
        end
        if cut then
            table.insert(pieces, unicode.sub(rest, 1, cut - 1))
            rest = unicode.sub(rest, cut + 1)
        else
            table.insert(pieces, unicode.sub(rest, 1, room))
            rest = unicode.sub(rest, room + 1)
        end
        if #pieces == 1 then
            room = width - indent
        end
    end
    table.insert(pieces, rest)
    for i = 2, #pieces do
        pieces[i] = string.rep(" ", indent) .. pieces[i]
    end
    return pieces
end

local function logColor(line)
    if line:find("ERROR", 1, true) then
        return "red"
    elseif line:find("WARNING", 1, true) then
        return "orange"
    end
    return "white"
end

local function drawLog()
    local width, height, logLines, separatorY, tableRows = layout()
    local setColor = colorSetter()
    -- The newest log lines, each wrapped over as many screen lines as it needs. Like a
    -- terminal, the oldest one may only show its end at the top of the panel.
    local shown = {} -- {text, color}, newest last
    local index = #Display.history
    while index >= 1 and #shown < logLines do
        local line = Display.history[index]
        local pieces = wrapLine(line, width)
        local color = logColor(line)
        local room = logLines - #shown
        local from = 1
        if #pieces > room then
            -- a single line longer than the whole panel shows its start, otherwise the end
            from = #shown == 0 and 1 or #pieces - room + 1
        end
        for i = math.min(#pieces, from + room - 1), from, -1 do
            table.insert(shown, 1, {pieces[i], color})
        end
        index = index - 1
    end
    for i = 1, logLines do
        local y = separatorY + i
        if shown[i] then
            setColor(shown[i][2])
            gpu.set(1, y, fit(shown[i][1], width))
        else
            gpu.fill(1, y, width, 1, " ")
        end
    end
    local keys, keysShort, keysTiny = footer, footerShort, footerTiny
    if pageCount(width, tableRows) > 1 then
        keys = keys .. "  PgUp/PgDn page"
        keysShort = keysShort .. "  PgUp/PgDn"
        keysTiny = keysTiny .. "  PgUp/Dn"
    end
    if unicode.len(keys) > width then
        keys = keysShort
    end
    if unicode.len(keys) > width then
        keys = keysTiny
    end
    setColor("gray")
    gpu.set(1, height, fit(keys, width))
    setColor("white")
end

local failed = false -- the table broke; stay with the scrolling log until Display.retry()
local failReason = nil

local function restoreResolution()
    if gpu and originalResolution then
        setResolution(originalResolution[1], originalResolution[2])
    end
end

-- Runs a drawing function. A problem while drawing must never stop the maintainer,
-- so on an error the table is switched off and the log is printed normally instead.
local function guarded(draw)
    local ok, err = pcall(draw)
    if not ok then
        failed = true
        failReason = tostring(err)
        active = false
        setLogHandler(nil)
        pcall(restoreResolution)
        pcall(term.clear)
        pcall(term.setCursorBlink, true)
        print("WARNING: the status table failed (" .. failReason .. "); showing a scrolling log instead. Press R to try it again.")
    end
end

local function drawAll()
    if not active or suspended then
        return
    end
    guarded(function()
        applyResolution()
        local width, height = gpu.getResolution()
        gpu.fill(1, 1, width, height, " ")
        drawTable()
        drawLog()
    end)
end

-- The shape of the screen, for layout "fit". OC draws text in the screen minus a
-- 4.5/16 block border, with characters twice as tall as wide.
local function measureScreen()
    screenRatio = nil
    portrait = false
    local address = gpu.getScreen()
    if address then
        local ok, blocksWide, blocksHigh = pcall(component.invoke, address, "getAspectRatio")
        if ok and blocksWide and blocksHigh then
            screenRatio = 2 * (blocksWide - 4.5 / 16) / (blocksHigh - 4.5 / 16)
            portrait = blocksHigh > blocksWide
        end
    end
end

-- Takes over the screen. Returns false if there is no graphics card (or the table
-- failed earlier), and the maintainer prints a scrolling log instead.
function Display.start()
    if failed or not component.isAvailable("gpu") then
        return false
    end
    gpu = component.gpu
    active = true
    suspended = false
    originalResolution = {gpu.getResolution()}
    pcall(measureScreen)
    term.setCursorBlink(false)
    setLogHandler(Display.addLog)
    drawAll()
    return active
end

-- Gives the screen back to normal printing, in the resolution it had before
function Display.stop()
    if not active then
        return
    end
    active = false
    setLogHandler(nil)
    pcall(restoreResolution)
    term.clear()
    term.setCursorBlink(true)
end

-- Moves the table `delta` pages forward (1) or back (-1)
function Display.changePage(delta)
    if not active or suspended then
        return
    end
    local width, _, _, _, tableRows = layout()
    local newPage = math.max(1, math.min(pageCount(width, tableRows), page + delta))
    if newPage ~= page then
        page = newPage
        drawAll()
    end
end

-- Header parts: a list of {text = ..., keep = number}, or a single string
local function headerParts(value)
    if type(value) == "string" then
        return {{text = value, keep = 100}}
    end
    return value or {}
end

-- Replaces the header line (e.g. to count down to the next cycle)
function Display.setHeader(parts)
    header = headerParts(parts)
    if active and not suspended and not batching then
        guarded(drawHeader)
    end
end

-- Shows or hides the recent log panel below the table
function Display.setShowRecent(show)
    if show ~= showRecent then
        showRecent = show
        drawAll()
    end
end

-- "fit", "tall", "columns" or "fixed" (anything else counts as "fit")
function Display.setLayout(mode)
    if mode ~= "columns" and mode ~= "fixed" and mode ~= "tall" then
        mode = "fit"
    end
    if mode ~= layoutMode then
        layoutMode = mode
        page = 1
        drawAll()
    end
end

-- settings.columns: column names in any case, separated by spaces or commas, e.g.
-- "Name Percent Batch". Name is always shown. Returns a list of the words that aren't
-- columns (they are left out).
function Display.setColumns(spec, short)
    local list, seen, unknown = {}, {}, {}
    for word in tostring(spec or ""):gmatch("[^%s,;]+") do
        local kind = word:lower()
        if kind == "%" then
            kind = "percent"
        end
        if kind ~= "name" and not COLUMN_TYPES[kind] then
            table.insert(unknown, word)
        elseif not seen[kind] then
            seen[kind] = true
            table.insert(list, kind)
        end
    end
    if not seen.name then
        table.insert(list, 1, "name")
    end
    short = short == true
    if table.concat(list, " ") ~= table.concat(columnList, " ") or short ~= shortNumbers then
        columnList = list
        shortNumbers = short
        drawAll()
    end
    return unknown
end

function Display.isActive()
    return active
end

-- Why the table stopped working, or nil if it didn't
function Display.failure()
    return failReason
end

-- Lets Display.start() try the table again after it failed. Returns true if it had failed.
function Display.retry()
    if not failed then
        return false
    end
    failed = false
    failReason = nil
    return true
end

-- While another program uses the screen (e.g. edit), nothing is drawn and the
-- screen gets its normal resolution back
function Display.suspend()
    suspended = true
    if active then
        pcall(restoreResolution)
    end
end

function Display.resume()
    suspended = false
    if active then
        term.setCursorBlink(false) -- edit turns the blinking cursor back on when it exits
        pcall(measureScreen)
    end
    drawAll()
end

function Display.addLog(line)
    table.insert(Display.history, line)
    if #Display.history > HISTORY then
        table.remove(Display.history, 1)
    end
    if active and not suspended and not batching then
        guarded(drawLog)
    end
end

-- During a cycle log lines are only collected; the screen is redrawn once at the end
function Display.beginBatch()
    batching = true
end

function Display.endBatch()
    batching = false
    drawAll()
end

-- rows: list of {name, stock, want, batch, status, shortStatus, color}; header: see
-- Display.setHeader; footer / footerShort / footerTiny: key help, the shorter ones
-- for narrower screens
function Display.update(newRows, newHeader, newFooter, newFooterShort, newFooterTiny)
    rows = newRows
    header = headerParts(newHeader)
    footer = newFooter or ""
    footerShort = newFooterShort or footer
    footerTiny = newFooterTiny or footerShort
    if not batching then
        drawAll()
    end
end

return Display
