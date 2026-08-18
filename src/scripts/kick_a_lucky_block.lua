--[[
    Kick A Lucky Block - farming
    ============================
    Rebuilt from a full decode of KickALuckyBlock.lua. What that decode showed:

      * The file handed over is only a LOADER. It draws a "FourHub Loader"
        splash, then does
            loadstring(game:HttpGet("https://fourhub13.vercel.app/KALB.lua"))()
        The real script is that download, and it pulls its UI library from
        fourhub13.vercel.app/fhui.lua as well. Both are fetched fresh at run
        time, so what that script does can change without the file changing.
        This module is native, so nothing is fetched and nothing can change
        under you.

      * Its own UI names the feature set, and its flags are:
            auto_collect   Auto Collect Money
            auto_kick      Auto Kick (Timing Bypass)
            auto_train     Auto Train + Bonus Click     train_delay 0.05..2
            auto_upgrade   Auto Upgrade All Slots       upgrade_delay 0.05..2
            auto_replace   Auto Replace Weakest Slot
            auto_rebirth   Auto Rebirth
        plus rarity/mutation filters for kick, upgrade and replace.

      * Confirmed mechanics, seen in the trace:
            rebirth  ReplicatedStorage.Shared.Packages.Network
                       :WaitForChild("rev_RebirthRequest"):FireServer()
            upgrade  clicks buttons under PlayerGui.KickUpgrades
            kick     walks workspace.Plots to find your plot and its slots
            replace  same plot slots
            train    reads tools out of Backpack

    The game names its remotes rev_<Thing>Request, which is how the rebirth one
    resolves. The other features look their remote up by keyword in the same
    folder rather than assuming a name, and Status reports exactly which remote
    each one bound to - so a wrong guess is visible instead of silent.

    "List network remotes" dumps the folder if anything fails to resolve.
]]

local M = {}

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local LocalPlayer = Players.LocalPlayer

    ------------------------------------------------------------------ state
    local settings = {
        autoCollect  = false,
        autoKick     = false,
        autoTrain    = false,
        autoUpgrade  = false,
        autoReplace  = false,
        autoRebirth  = false,
        trainDelay   = 0.5,
        upgradeDelay = 0.1,
        collectDelay = 0.1,
        kickDelay    = 0.2,
        rebirthDelay = 3,
    }

    local counters = { collect = 0, kick = 0, train = 0,
                       upgrade = 0, replace = 0, rebirth = 0 }
    local statusBox, remoteBox

    ---------------------------------------------------------------- helpers
    local function safe(fn, fallback)
        local ok, value = pcall(fn)
        if ok then return value end
        return fallback
    end

    local function pathOf(instance)
        return safe(function() return instance:GetFullName() end, tostring(instance))
    end

    -- ReplicatedStorage.Shared.Packages.Network, as seen in the trace
    local function networkFolder()
        local node = ReplicatedStorage
        for _, name in ipairs({ "Shared", "Packages", "Network" }) do
            node = node and safe(function() return node:FindFirstChild(name) end, nil)
            if not node then return nil end
        end
        return node
    end

    local function networkChildren()
        local folder = networkFolder()
        if not folder then return {} end
        return safe(function() return folder:GetChildren() end, {}) or {}
    end

    -- Resolve by keyword rather than assuming a name. Exact matches win.
    local function findRemote(keywords, exact)
        local folder = networkFolder()
        if not folder then return nil, "no Network folder" end

        if exact then
            local direct = safe(function() return folder:FindFirstChild(exact) end, nil)
            if direct then return direct, exact end
        end

        for _, child in ipairs(networkChildren()) do
            local name = child.Name:lower()
            for _, word in ipairs(keywords) do
                if name:find(word, 1, true) then return child, child.Name end
            end
        end
        return nil, "no match"
    end

    -- args are captured first: `...` cannot be referenced inside the nested
    -- pcall closure, which is not itself a vararg function
    local unpackArgs = table.unpack or unpack

    local function fire(remote, ...)
        if not remote then return false end
        local args, count = { ... }, select("#", ...)
        local ok = pcall(function() remote:FireServer(unpackArgs(args, 1, count)) end)
        if not ok then
            ok = pcall(function() remote:InvokeServer(unpackArgs(args, 1, count)) end)
        end
        return ok
    end

    ------------------------------------------------------------- plot / GUI
    -- workspace.Plots holds every plot; yours is the one tagged with your name
    -- or user id. Falls back to the nearest one.
    local function myPlot()
        local plots = safe(function() return workspace:FindFirstChild("Plots") end, nil)
        if not plots then return nil, "no workspace.Plots" end

        local name = LocalPlayer.Name
        for _, plot in ipairs(safe(function() return plots:GetChildren() end, {}) or {}) do
            if plot.Name == name
                or safe(function() return plot:GetAttribute("Owner") end, nil) == name
                or safe(function() return plot:FindFirstChild(name) end, nil) then
                return plot, "owner match"
            end
            local owner = safe(function() return plot:FindFirstChild("Owner") end, nil)
            if owner and safe(function() return owner.Value end, nil) == LocalPlayer then
                return plot, "Owner value"
            end
        end

        local character = LocalPlayer.Character
        local root = character and safe(function()
            return character:FindFirstChild("HumanoidRootPart") end, nil)
        if root then
            local best, bestDistance
            for _, plot in ipairs(safe(function() return plots:GetChildren() end, {}) or {}) do
                local pivot = safe(function() return plot:GetPivot().Position end, nil)
                if pivot then
                    local distance = (pivot - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best, bestDistance = plot, distance
                    end
                end
            end
            if best then return best, ("nearest (%.0f studs)"):format(bestDistance) end
        end
        return nil, "not found"
    end

    -- PlayerGui.KickUpgrades, whose children the script clicks
    local function upgradeButtons()
        local gui = safe(function() return LocalPlayer:FindFirstChild("PlayerGui") end, nil)
        local panel = gui and safe(function() return gui:FindFirstChild("KickUpgrades") end, nil)
        if not panel then return {} end

        local out = {}
        for _, d in ipairs(safe(function() return panel:GetDescendants() end, {}) or {}) do
            if safe(function() return d:IsA("GuiButton") end, false) then
                out[#out + 1] = d
            end
        end
        return out
    end

    -- Clicking a GUI button from a script means firing its own connections;
    -- there is no synthetic mouse event that a LocalScript can send to it.
    local function clickButton(button)
        local fired = false
        if getconnections then
            for _, signal in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down" }) do
                local event = safe(function() return button[signal] end, nil)
                if event then
                    local ok, conns = pcall(getconnections, event)
                    if ok and conns then
                        for _, connection in ipairs(conns) do
                            if pcall(function() connection:Fire() end) then fired = true end
                        end
                    end
                end
            end
        end
        if not fired and firesignal then
            local event = safe(function() return button.Activated end, nil)
            if event then fired = pcall(firesignal, event) end
        end
        return fired
    end

    ------------------------------------------------------------------- loops
    -- Each feature runs its own loop and reports what it bound to, so a
    -- feature that cannot resolve its remote says so instead of doing nothing
    -- quietly.
    local bindings = {}

    local function loop(key, flag, delayKey, body)
        ctx.Spawn(function()
            while ctx.IsAlive() do
                if settings[flag] then
                    local ok, err = pcall(body)
                    if not ok then
                        bindings[key] = "error: " .. tostring(err)
                    end
                end
                task.wait(settings[delayKey] or 0.2)
            end
        end)
    end

    loop("rebirth", "autoRebirth", "rebirthDelay", function()
        local remote, name = findRemote({ "rebirth" }, "rev_RebirthRequest")
        bindings.rebirth = remote and name or "not found"
        if remote and fire(remote) then
            counters.rebirth = counters.rebirth + 1
        end
    end)

    loop("train", "autoTrain", "trainDelay", function()
        local remote, name = findRemote({ "train" })
        bindings.train = remote and name or "not found"
        if remote and fire(remote) then
            counters.train = counters.train + 1
        end
    end)

    loop("collect", "autoCollect", "collectDelay", function()
        local remote, name = findRemote({ "collect", "money", "cash" })
        bindings.collect = remote and name or "not found"
        if remote and fire(remote) then
            counters.collect = counters.collect + 1
        end
    end)

    loop("kick", "autoKick", "kickDelay", function()
        local remote, name = findRemote({ "kick" })
        local plot, source = myPlot()
        bindings.kick = ("%s / plot %s"):format(remote and name or "no remote", source)
        if remote and fire(remote) then
            counters.kick = counters.kick + 1
        end
    end)

    loop("upgrade", "autoUpgrade", "upgradeDelay", function()
        local buttons = upgradeButtons()
        bindings.upgrade = ("%d button(s)"):format(#buttons)
        for _, button in ipairs(buttons) do
            if not ctx.IsAlive() or not settings.autoUpgrade then return end
            if clickButton(button) then
                counters.upgrade = counters.upgrade + 1
            end
            task.wait(settings.upgradeDelay)
        end
    end)

    loop("replace", "autoReplace", "kickDelay", function()
        local remote, name = findRemote({ "replace", "equip", "slot" })
        local plot, source = myPlot()
        bindings.replace = ("%s / plot %s"):format(remote and name or "no remote", source)
        if remote and fire(remote) then
            counters.replace = counters.replace + 1
        end
    end)

    --------------------------------------------------------------------- UI
    ctx.Tab:AddParagraph({
        Title   = "Kick A Lucky Block",
        Content = "Rebuilt natively from the FourHub loader, which only downloaded its "
               .. "real script at run time. Turn a feature on and check Status - it "
               .. "names the remote each one bound to.",
    })

    local TOGGLES = {
        { "KALB_Collect", "Auto Collect Money",       "autoCollect" },
        { "KALB_Kick",    "Auto Kick",                "autoKick" },
        { "KALB_Train",   "Auto Train",               "autoTrain" },
        { "KALB_Upgrade", "Auto Upgrade All Slots",   "autoUpgrade" },
        { "KALB_Replace", "Auto Replace Weakest Slot","autoReplace" },
        { "KALB_Rebirth", "Auto Rebirth",             "autoRebirth" },
    }
    for _, entry in ipairs(TOGGLES) do
        ctx.Tab:AddToggle(entry[1], { Title = entry[2], Default = false })
            :OnChanged(function(value) settings[entry[3]] = value end)
    end

    local SLIDERS = {
        { "KALB_TrainDelay",   "Train delay",   "trainDelay",   0.5,  0.05, 2,  2 },
        { "KALB_UpgradeDelay", "Upgrade delay", "upgradeDelay", 0.1,  0.05, 2,  2 },
        { "KALB_CollectDelay", "Collect delay", "collectDelay", 0.1,  0.05, 2,  2 },
        { "KALB_KickDelay",    "Kick delay",    "kickDelay",    0.2,  0.05, 2,  2 },
        { "KALB_RebirthDelay", "Rebirth delay", "rebirthDelay", 3,    1,    30, 0 },
    }
    for _, entry in ipairs(SLIDERS) do
        ctx.Tab:AddSlider(entry[1], {
            Title = entry[2], Default = entry[4],
            Min = entry[5], Max = entry[6], Rounding = entry[7],
        }):OnChanged(function(value) settings[entry[3]] = value end)
    end

    ctx.Tab:AddButton({
        Title       = "List network remotes",
        Description = "Dumps the Network folder and your plot - send me this to wire the rest",
        Callback    = function()
            ctx.Spawn(function()
                local lines = {}
                local folder = networkFolder()
                lines[#lines + 1] = "Network: " ..
                    (folder and pathOf(folder) or "NOT FOUND")
                for _, child in ipairs(networkChildren()) do
                    lines[#lines + 1] = ("  %s  %s"):format(child.ClassName, child.Name)
                end

                local plot, source = myPlot()
                lines[#lines + 1] = ""
                lines[#lines + 1] = ("Plot: %s (%s)"):format(
                    plot and pathOf(plot) or "NOT FOUND", source)
                if plot then
                    for _, child in ipairs(safe(function()
                        return plot:GetChildren() end, {}) or {}) do
                        lines[#lines + 1] = ("  %s  %s"):format(child.ClassName, child.Name)
                    end
                end

                local buttons = upgradeButtons()
                lines[#lines + 1] = ""
                lines[#lines + 1] = ("KickUpgrades buttons: %d"):format(#buttons)
                for i = 1, math.min(#buttons, 20) do
                    lines[#lines + 1] = ("  %s"):format(pathOf(buttons[i]))
                end

                local backpack = safe(function()
                    return LocalPlayer:FindFirstChild("Backpack") end, nil)
                lines[#lines + 1] = ""
                lines[#lines + 1] = "Backpack:"
                for _, tool in ipairs(backpack and safe(function()
                    return backpack:GetChildren() end, {}) or {}) do
                    lines[#lines + 1] = ("  %s  %s"):format(tool.ClassName, tool.Name)
                end

                local text = table.concat(lines, "\n")
                pcall(function() remoteBox:SetDesc(text) end)
                if setclipboard then pcall(setclipboard, text) end
                ctx.Notify(("dumped %d lines (copied)"):format(#lines), 6, "Kick A Lucky Block")
            end)
        end,
    })

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "-" })
    remoteBox = ctx.Tab:AddParagraph({ Title = "Network dump", Content = "-" })

    -- Read the controls off the UI each tick, so config-restored and SetValue
    -- changes are picked up too, not only OnChanged.
    local OPTION_MAP = {
        KALB_Collect = "autoCollect", KALB_Kick = "autoKick",
        KALB_Train = "autoTrain", KALB_Upgrade = "autoUpgrade",
        KALB_Replace = "autoReplace", KALB_Rebirth = "autoRebirth",
        KALB_TrainDelay = "trainDelay", KALB_UpgradeDelay = "upgradeDelay",
        KALB_CollectDelay = "collectDelay", KALB_KickDelay = "kickDelay",
        KALB_RebirthDelay = "rebirthDelay",
    }

    ctx.Spawn(function()
        while ctx.IsAlive() do
            local options = ctx.Options
            if options then
                for id, key in pairs(OPTION_MAP) do
                    local option = options[id]
                    if option ~= nil then
                        local ok, value = pcall(function() return option.Value end)
                        if ok and value ~= nil then settings[key] = value end
                    end
                end
            end

            local plot, plotSource = myPlot()
            pcall(function()
                statusBox:SetDesc(table.concat({
                    ("network: %s"):format(networkFolder()
                        and "found" or "NOT FOUND - is this the right game?"),
                    ("plot: %s"):format(plot and plotSource or "not found"),
                    ("rebirth %s | train %s"):format(
                        bindings.rebirth or "-", bindings.train or "-"),
                    ("collect %s | kick %s"):format(
                        bindings.collect or "-", bindings.kick or "-"),
                    ("upgrade %s | replace %s"):format(
                        bindings.upgrade or "-", bindings.replace or "-"),
                    ("fired: collect %d  kick %d  train %d  upgrade %d  rebirth %d"):format(
                        counters.collect, counters.kick, counters.train,
                        counters.upgrade, counters.rebirth),
                }, "\n"))
            end)
            task.wait(0.5)
        end
    end)
end

return M
