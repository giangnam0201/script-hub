--[[
    Script Hub - core framework
    ===========================
    Responsibilities:
      * work out which game the player is in,
      * pick the matching entry out of src/registry.lua,
      * build the Fluent window and the shared "Hub" tab,
      * hand each game module a context object and run it,
      * track everything the module creates so Unload really unloads.

    A game module never creates its own window. It gets ctx.Tab and uses
    ctx.Connect / ctx.Spawn / ctx.OnUnload so the hub can clean up after it.
]]

local Core = {}

local FLUENT_URL    = "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"
local SAVEMGR_URL   = "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"
local INTERFACE_URL = "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"

local Players           = game:GetService("Players")
local TeleportService   = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService       = game:GetService("HttpService")

local genv = (getgenv and getgenv()) or _G

--=========================================================================
-- Environment / game detection
--=========================================================================
local function getExecutorName()
    local ok, name = pcall(function()
        return identifyexecutor and identifyexecutor() or nil
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return "Unknown"
end

local function getGameInfo()
    local info = {
        PlaceId = game.PlaceId,
        GameId  = game.GameId,
        JobId   = game.JobId,
        Name    = "Unknown game",
    }

    local ok, product = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)
    if ok and type(product) == "table" and product.Name then
        info.Name = product.Name
    end

    return info
end

--=========================================================================
-- Registry matching
--
-- Priority: PlaceIds (exact) -> GameIds (universe) -> NameMatch (substring
-- of the marketplace name, lowercased). NameMatch means a new game works
-- before you have had a chance to write the id down.
--=========================================================================
local function matchesEntry(entry, info)
    if entry.Universal then return false end

    if entry.PlaceIds then
        for _, id in ipairs(entry.PlaceIds) do
            if tonumber(id) == info.PlaceId then return true, "PlaceId" end
        end
    end

    if entry.GameIds then
        for _, id in ipairs(entry.GameIds) do
            if tonumber(id) == info.GameId then return true, "GameId" end
        end
    end

    if entry.NameMatch and info.Name then
        local needle = tostring(entry.NameMatch):lower()
        if needle ~= "" and string.find(info.Name:lower(), needle, 1, true) then
            return true, "Name"
        end
    end

    return false
end

local function resolve(registry, info)
    local matched, universal = {}, {}
    for _, entry in ipairs(registry) do
        if entry.Universal then
            universal[#universal + 1] = entry
        else
            local hit, how = matchesEntry(entry, info)
            if hit then
                entry._matchedBy = how
                matched[#matched + 1] = entry
            end
        end
    end
    return matched, universal
end

--=========================================================================
-- Start
--=========================================================================
function Core.Start(config)
    local hub = {
        Config    = config,
        GameInfo  = getGameInfo(),
        Executor  = getExecutorName(),
        Unloaded  = false,
        _cleanup  = {},
        _threads  = {},
        _conns    = {},
        _loaded   = {},
    }

    ----------------------------------------------------------------- cleanup
    function hub.OnUnload(fn)
        hub._cleanup[#hub._cleanup + 1] = fn
    end

    function hub.Connect(signal, fn)
        local conn = signal:Connect(fn)
        hub._conns[#hub._conns + 1] = conn
        return conn
    end

    function hub.Spawn(fn, ...)
        local thread = task.spawn(fn, ...)
        hub._threads[#hub._threads + 1] = thread
        return thread
    end

    ----------------------------------------------------------------- UI boot
    local Fluent = loadstring(game:HttpGet(FLUENT_URL))()

    local SaveManager, InterfaceManager
    pcall(function() SaveManager      = loadstring(game:HttpGet(SAVEMGR_URL))() end)
    pcall(function() InterfaceManager = loadstring(game:HttpGet(INTERFACE_URL))() end)

    hub.Fluent = Fluent

    function hub.Notify(content, duration, title)
        Fluent:Notify({
            Title    = title or config.Name,
            Content  = tostring(content),
            Duration = duration or 4,
        })
    end

    local Window = Fluent:CreateWindow({
        Title       = config.Name .. " " .. (config.Version or ""),
        SubTitle    = hub.GameInfo.Name,
        TabWidth    = 160,
        Size        = UDim2.fromOffset(580, 460),
        Acrylic     = true,
        Theme       = "Dark",
        MinimizeKey = Enum.KeyCode.LeftControl,
    })
    hub.Window  = Window
    hub.Options = Fluent.Options
    hub.Tabs    = {}

    function hub.AddTab(title, icon)
        local tab = Window:AddTab({ Title = title, Icon = icon or "box" })
        hub.Tabs[title] = tab
        return tab
    end

    ----------------------------------------------------------------- unload
    function hub.Unload()
        if hub.Unloaded then return end
        hub.Unloaded = true

        for _, fn in ipairs(hub._cleanup) do pcall(fn) end
        for _, conn in ipairs(hub._conns) do pcall(function() conn:Disconnect() end) end
        for _, thread in ipairs(hub._threads) do pcall(task.cancel, thread) end

        pcall(function() Fluent:Destroy() end)
        genv.__ScriptHub = nil
    end

    genv.__ScriptHub = hub

    ----------------------------------------------------------------- modules
    local registry = HUB_REQUIRE("src/registry")
    local matched, universal = resolve(registry, hub.GameInfo)

    local function runEntry(entry)
        local tabTitle = entry.Name or "Script"
        local ctx = {
            Hub      = hub,
            Fluent   = Fluent,
            Window   = Window,
            Options  = Fluent.Options,
            GameInfo = hub.GameInfo,
            Entry    = entry,
            Tab      = hub.AddTab(tabTitle, entry.Icon or "play"),
            Notify   = hub.Notify,
            Connect  = hub.Connect,
            Spawn    = hub.Spawn,
            OnUnload = hub.OnUnload,
        }
        function ctx.IsAlive() return not hub.Unloaded end

        local ok, mod = pcall(HUB_REQUIRE, entry.Module)
        if not ok then
            ctx.Tab:AddParagraph({ Title = "Failed to download", Content = tostring(mod) })
            hub.Notify("Could not load " .. tabTitle, 6)
            return false
        end

        local ranOk, err = pcall(mod.Setup, ctx)
        if not ranOk then
            ctx.Tab:AddParagraph({ Title = "Script error", Content = tostring(err) })
            hub.Notify(tabTitle .. " errored: " .. tostring(err), 8)
            return false
        end

        hub._loaded[#hub._loaded + 1] = entry
        return true
    end

    for _, entry in ipairs(matched) do runEntry(entry) end
    for _, entry in ipairs(universal) do runEntry(entry) end

    ----------------------------------------------------------------- hub tab
    local HubTab = hub.AddTab("Hub", "settings")

    if #matched == 0 then
        HubTab:AddParagraph({
            Title   = "No script for this game (yet)",
            Content = ("%s\nPlaceId: %d\nGameId: %d\n\nSend the PlaceId over and it can be added to the registry.")
                :format(hub.GameInfo.Name, hub.GameInfo.PlaceId, hub.GameInfo.GameId),
        })
    else
        local names = {}
        for _, entry in ipairs(matched) do
            names[#names + 1] = ("%s  (matched by %s)"):format(entry.Name, entry._matchedBy or "?")
        end
        HubTab:AddParagraph({
            Title   = "Loaded for this game",
            Content = table.concat(names, "\n"),
        })
    end

    HubTab:AddParagraph({
        Title   = "Environment",
        Content = ("Game: %s\nPlaceId: %d\nGameId: %d\nExecutor: %s\nHub: %s %s")
            :format(hub.GameInfo.Name, hub.GameInfo.PlaceId, hub.GameInfo.GameId,
                    hub.Executor, config.Name, config.Version or ""),
    })

    HubTab:AddButton({
        Title       = "Copy PlaceId",
        Description = "Puts this game's PlaceId on your clipboard",
        Callback    = function()
            if setclipboard then
                setclipboard(tostring(hub.GameInfo.PlaceId))
                hub.Notify("PlaceId copied: " .. hub.GameInfo.PlaceId)
            else
                hub.Notify("This executor has no setclipboard - PlaceId is " .. hub.GameInfo.PlaceId, 8)
            end
        end,
    })

    HubTab:AddButton({
        Title       = "Rejoin",
        Description = "Teleport back into this place",
        Callback    = function()
            pcall(function()
                TeleportService:Teleport(game.PlaceId, Players.LocalPlayer)
            end)
        end,
    })

    HubTab:AddButton({
        Title       = "Unload hub",
        Description = "Closes the UI and stops every loaded script",
        Callback    = function() hub.Unload() end,
    })

    -- Fluent's own config/interface panels, if the addons downloaded.
    pcall(function()
        InterfaceManager:SetLibrary(Fluent)
        SaveManager:SetLibrary(Fluent)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({})
        InterfaceManager:SetFolder(config.Name)
        SaveManager:SetFolder(config.Name .. "/" .. tostring(hub.GameInfo.PlaceId))
        InterfaceManager:BuildInterfaceSection(HubTab)
        SaveManager:BuildConfigSection(HubTab)
        SaveManager:LoadAutoloadConfig()
    end)

    Window:SelectTab(1)

    if #matched == 0 then
        hub.Notify("No script for " .. hub.GameInfo.Name .. " yet", 6)
    else
        hub.Notify(("Loaded %d script%s for %s"):format(
            #hub._loaded, #hub._loaded == 1 and "" or "s", hub.GameInfo.Name), 5)
    end

    return hub
end

return Core
