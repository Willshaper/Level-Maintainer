local component = require("component")
local computer = require("computer")

local AE2 = {}

-- Resolved on demand so the script can start (and wait) before the interface is attached
local ME = nil

local function resolveInterface()
    if component.isAvailable("me_interface") then
        ME = component.me_interface
    end
    return ME ~= nil
end

-- Returns true once an ME interface is available
function AE2.connect()
    return resolveInterface()
end

-- Lightweight cache for specific items only.
-- Values: {craftable = userdata, stack = table} (hit), or `false` (negative lookup).
local itemCache = {}
local cacheTimestamp = 0

-- Overridden from settings.lua via AE2.configure()
local cacheDuration = 600
local pollInterval = 1
local cpuName = nil

function AE2.configure(settings)
    cacheDuration = settings.cacheDuration
    pollInterval = settings.pollInterval
    cpuName = settings.cpuName
end

-- Starts a crafting calculation and waits for it to finish.
-- Returns true, or false plus AE2's failure reason.
local function submit(craftable, count)
    local craft
    if cpuName then
        craft = craftable.request(count, true, cpuName)
    else
        craft = craftable.request(count)
    end

    while craft.isComputing() == true do
        os.sleep(pollInterval)
    end
    local failed, reason = craft.hasFailed()
    return not failed, reason
end

-- getStack() of a fluid craftable has "amount" and no "damage"; item stacks always have "damage"
local function isFluidStack(stack)
    return stack ~= nil and stack.damage == nil and stack.amount ~= nil
end

-- Returns the craftable for a label and its output stack (cached), or nil if nothing
-- with that label can be crafted.
local function getCraftableForItem(itemName)
    local currentTime = computer.uptime() -- real seconds; os.time() is in-game time (72x faster)

    local cached = itemCache[itemName]
    if cached ~= nil and currentTime - cacheTimestamp < cacheDuration then
        if cached == false then return nil end
        return cached.craftable, cached.stack
    end

    -- If cache is too old, clear it completely to save memory
    if currentTime - cacheTimestamp >= cacheDuration then
        itemCache = {}
        cacheTimestamp = currentTime
    end

    -- Look for this specific item in craftables
    local craftables = ME.getCraftables({["label"] = itemName})
    if #craftables >= 1 then
        local craftable = craftables[1]
        -- The output stack doesn't change, so it is cached too (saves a call per entry per cycle)
        local stack = (craftable.getStack or craftable.getItemStack)(craftable)
        itemCache[itemName] = {craftable = craftable, stack = stack}
        return craftable, stack
    end

    itemCache[itemName] = false -- Cache the negative lookup so misspelled entries don't re-query every cycle
    return nil
end

-- requestItem and requestFluid return: success, message, result ("requested", "failed",
-- "stocked" or "missing"), and the amount in stock when it was checked (threshold set).
-- A failed request also returns AE2's reason and the unit ("mB" for fluids, nil for items).
function AE2.requestItem(name, threshold, count, fluidName)
    local craftable, item = getCraftableForItem(name)
    local amount = nil

    if craftable then
        -- A fluid listed under cfg.items: check its stock as a fluid, not as an item
        if isFluidStack(item) then
            return AE2.requestFluid(name, threshold, count)
        end
        if threshold ~= nil then
            local itemInSystem = nil

            if fluidName then
                local fluidTag = '{Fluid:' .. fluidName .. '}'
                itemInSystem = ME.getItemInNetwork("ae2fc:fluid_drop", 0, fluidTag)
            else
                if item.name then
                    -- item.tag is gzipped binary NBT, not the SNBT string the 3-arg form expects.
                    -- Newer OC accepts the stack table itself and decodes the tag; older OC
                    -- rejects a table, so fall back to name + damage (ignores NBT).
                    local ok, result = pcall(ME.getItemInNetwork, item)
                    if ok then
                        itemInSystem = result
                    else
                        itemInSystem = ME.getItemInNetwork(item.name, item.damage or 0)
                    end
                end
            end

            amount = itemInSystem and itemInSystem.size or 0 -- not found = none stored
            if itemInSystem ~= nil and amount >= threshold then
                return false, "The amount of " .. (itemInSystem.label or name) .. " (" .. amount .. ") meets or exceeds threshold (" .. threshold .. ")! Aborting request.", "stocked", amount
            end
        end

        if item.label == name then
            local ok, reason = submit(craftable, count)
            if not ok then
                return false, "Failed to request " .. name .. " x " .. count .. " (" .. tostring(reason) .. ")", "failed", amount, reason
            else
                return true, "Requested " .. name .. " x " .. count, "requested", amount
            end
        end
    end
    return false, name .. " is not craftable!", "missing"
end

-- Native fluid maintenance via getFluidInNetwork (GTNH 2.9+).
-- `name` is the fluid craftable label; `fluidName` is the fluid registry name and is
-- auto-detected from the craftable's stack if omitted (pass it only as an override).
function AE2.requestFluid(name, threshold, count, fluidName)
    local craftable, stack = getCraftableForItem(name)
    local amount = nil

    if craftable then
        if threshold ~= nil then
            if not fluidName then
                -- An item listed under cfg.fluids: check its stock as an item
                if not isFluidStack(stack) then
                    return AE2.requestItem(name, threshold, count)
                end
                fluidName = stack.name
            end

            if fluidName and ME.getFluidInNetwork then
                local fluidInSystem = ME.getFluidInNetwork(fluidName)
                amount = fluidInSystem and (fluidInSystem.size or fluidInSystem.amount) or 0 -- not found = none stored
                if fluidInSystem ~= nil and amount >= threshold then
                    return false, "The amount of " .. (fluidInSystem.label or name) .. " (" .. amount .. " mB) meets or exceeds threshold (" .. threshold .. " mB)! Aborting request.", "stocked", amount
                end
            end
        end

        local ok, reason = submit(craftable, count)
        if not ok then
            return false, "Failed to request " .. name .. " x " .. count .. " mB (" .. tostring(reason) .. ")", "failed", amount, reason, "mB"
        else
            return true, "Requested " .. name .. " x " .. count .. " mB", "requested", amount
        end
    end
    return false, name .. " is not craftable!", "missing"
end

-- Returns: set of labels currently being crafted, number of idle CPUs,
-- a name -> busy map of all CPUs, and the total number of CPUs.
function AE2.checkIfCrafting()
    local cpus = ME.getCpus()
    local items = {}
    local freeCpus = 0
    local totalCpus = 0
    local cpuBusy = {}
    for k, v in pairs(cpus) do
        totalCpus = totalCpus + 1
        -- Only a busy CPU has a job to report (saves a call per idle CPU per cycle)
        if v.busy then
            local finaloutput = v.cpu.finalOutput()
            if finaloutput ~= nil then
                items[finaloutput.label] = true
            end
        else
            freeCpus = freeCpus + 1
        end
        -- First CPU with a given name wins, matching how request() picks by name
        if v.name and cpuBusy[v.name] == nil then
            cpuBusy[v.name] = v.busy
        end
    end

    return items, freeCpus, cpuBusy, totalCpus
end

-- Returns true if the ME interface exposes the GTNH 2.9+ native fluid API.
function AE2.hasFluidSupport()
    return ME ~= nil and ME.getFluidInNetwork ~= nil
end

-- Function to manually clear the cache if needed
function AE2.clearCache()
    -- Re-resolve the interface in case the adapter/interface was replaced
    resolveInterface()
    itemCache = {}
    cacheTimestamp = 0
end

return AE2