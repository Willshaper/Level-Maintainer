-- Full-screen status view: a table with one row per maintained entry, a panel with
-- the most recent log lines and a line listing the keys. Used when settings.display
-- is "table"; otherwise the maintainer prints a scrolling log.
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
local TABLE_GAP = " | "

-- Column sizes. status: the row field shown in the Status column; statusGap: spaces
-- before it; minScreen: narrowest resolution "fit" / "tall" picks
local WIDE = {
    status = "status", statusWidth = 15, statusGap = 2, -- fits "waiting for CPU"
    minName = 16, minScreen = 50, -- the short key help and a compact header fit
    numbers = {{title = "Stock", key = "stock", width = 8}, {title = "Want", key = "want", width = 8},
        {title = "Batch", key = "batch", width = 7}},
}
local NARROW = {
    status = "shortStatus", statusWidth = 10, statusGap = 1, -- fits "no pattern"
    minName = 12, minScreen = 30,
    numbers = {{title = "Stock", key = "stock", width = 6}, {title = "Want", key = "want", width = 6},
        {title = "Batch", key = "batch", width = 6}},
}

-- Width of everything in a row except the name
local function fixedWidth(style)
    local used = style.statusWidth + style.statusGap
    for _, column in ipairs(style.numbers) do
        used = used + column.width + 1
    end
    return used
end

local MIN_TABLE_WIDTH = 20 + fixedWidth(WIDE) -- narrowest side-by-side table ("columns")

local function currentStyle()
    if layoutMode == "tall" or (layoutMode == "fit" and portrait) then
        return NARROW
    end
    return WIDE
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

-- Screen areas for a resolution: line 1 header, line 2 column titles, then the table
-- rows, a separator, the recent log lines, and the key help on the last line. Without
-- the recent panel the table rows go down to the key help line.
-- Returns the number of log lines, the separator line (or nil) and the table rows.
local function areas(height)
    if not showRecent then
        return 0, nil, math.max(1, height - 3)
    end
    local logLines = math.max(3, math.floor(height * 0.3))
    if layoutMode ~= "columns" then
        -- Table lines no row needs go to the recent panel
        logLines = logLines + math.max(0, height - 4 - logLines - #rows)
    end
    local separatorY = height - 1 - logLines
    return logLines, separatorY, math.max(1, separatorY - 3)
end

local function layout()
    local width, height = gpu.getResolution()
    local logLines, separatorY, tableRows = areas(height)
    return width, height, logLines, separatorY, tableRows
end

-- Number of side-by-side tables for a screen width
local function tableCount(width)
    if layoutMode ~= "columns" then
        return 1
    end
    local count = math.floor((width + #TABLE_GAP) / (MIN_TABLE_WIDTH + #TABLE_GAP))
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

-- Number columns that fit next to a readable name. On narrow tables Batch is
-- dropped first, then Want, then Stock. Returns the name width and the columns.
local function columnsFor(width, style)
    local columns = {}
    for _, column in ipairs(style.numbers) do
        table.insert(columns, column)
    end
    while true do
        local used = style.statusWidth + style.statusGap
        for _, column in ipairs(columns) do
            used = used + column.width + 1
        end
        if width - used >= style.minName or #columns == 0 then
            return math.max(8, math.min(MAX_NAME_WIDTH, width - used)), columns
        end
        table.remove(columns)
    end
end

local function formatRow(nameWidth, columns, row, style)
    local line = fit(row.name, nameWidth)
    for _, column in ipairs(columns) do
        line = line .. " " .. fitRight(row[column.key], column.width)
    end
    return line .. string.rep(" ", style.statusGap) .. tostring(row[style.status] or row.status or "")
end

-- The resolution for layouts "fit" and "tall": the smallest one (so the largest text)
-- that shows every row, in the shape of the screen so the text fills it edge to edge.
-- Wide columns make room for the whole name; narrow ones only for a short one and give the name
-- whatever width the screen's shape leaves over.
local function fitResolution()
    local maxWidth, maxHeight = gpu.maxResolution()
    local ratio = screenRatio or (maxWidth / maxHeight)
    local style = currentStyle()
    local nameWidth = style.minName
    if style == WIDE then
        for _, row in ipairs(rows) do
            nameWidth = math.max(nameWidth, math.min(unicode.len(row.name), MAX_NAME_WIDTH))
        end
    end
    local needWidth = math.min(maxWidth, math.max(style.minScreen, nameWidth + fixedWidth(style)))
    for height = 5, maxHeight do
        local _, _, tableRows = areas(height)
        local width = math.min(maxWidth, math.floor(height * ratio))
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

-- Column where the Stock value starts in a table row, or nil if Stock isn't shown
local function stockColumn(nameWidth, columns)
    local position = nameWidth
    for _, column in ipairs(columns) do
        position = position + 1
        if column.key == "stock" then
            return position, column.width
        end
        position = position + column.width
    end
    return nil
end

-- Draws one table of rows starting at column x
local function drawSubTable(x, tableWidth, tableRows, pageRows, setColor, colors)
    local style = currentStyle()
    local nameWidth, columns = columnsFor(tableWidth, style)
    local stockOffset, stockWidth = stockColumn(nameWidth, columns)
    local titles = {name = "Name", [style.status] = "Status"}
    for _, column in ipairs(columns) do
        titles[column.key] = column.title
    end
    setColor("gray")
    gpu.set(x, 2, fit(formatRow(nameWidth, columns, titles, style), tableWidth))
    for i = 1, tableRows do
        local row = pageRows[i]
        if row then
            setColor(row.color)
            gpu.set(x, 2 + i, fit(formatRow(nameWidth, columns, row, style), tableWidth))
            -- A stock value that wasn't read this cycle is redrawn in gray
            if row.stockFrozen and colors and stockOffset and stockOffset + stockWidth <= tableWidth then
                setColor("gray")
                gpu.set(x + stockOffset, 2 + i, fitRight(row.stock, stockWidth))
            end
        else
            gpu.fill(x, 2 + i, tableWidth, 1, " ")
        end
    end
end

local function drawTable()
    local width, _, _, separatorY, tableRows = layout()
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

    if separatorY then
        setColor("gray")
        gpu.set(1, separatorY, fit("-- Recent " .. string.rep("-", math.max(0, width - 10)), width))
    end
end

local function drawLog()
    local width, height, logLines, separatorY, tableRows = layout()
    local setColor = colorSetter()
    local first = math.max(1, #Display.history - logLines + 1)
    for i = 0, logLines - 1 do
        local line = Display.history[first + i]
        local y = separatorY + 1 + i
        if line then
            if line:find("ERROR", 1, true) then
                setColor("red")
            elseif line:find("WARNING", 1, true) then
                setColor("orange")
            else
                setColor("white")
            end
            gpu.set(1, y, fit(line, width))
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
