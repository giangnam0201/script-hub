--[[
    Universal tools
    ===============
    Loaded in every game (Universal = true in the registry). Keep this file
    for things that never depend on a specific place: server hopping, rejoin,
    FPS/ping readouts, character conveniences.

    It also doubles as the reference implementation of the module contract:
      Setup(ctx) with ctx.Tab / ctx.Notify / ctx.Connect / ctx.Spawn /
      ctx.OnUnload / ctx.IsAlive.
]]

local M = {}

function M.Setup(ctx)
    local Players         = game:GetService("Players")
    local TeleportService = game:GetService("TeleportService")
    local HttpService     = game:GetService("HttpService")
    local RunService      = game:GetService("RunService")
    local StarterGui      = game:GetService("StarterGui")

    local LocalPlayer = Players.LocalPlayer

    ctx.Tab:AddParagraph({
        Title   = "Server",
        Content = "Works in any game.",
    })

    ctx.Tab:AddButton({
        Title       = "Rejoin",
        Description = "Teleport back into this place",
        Callback    = function()
            pcall(function()
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Server hop",
        Description = "Jump to another public server of this game",
        Callback    = function()
            ctx.Spawn(function()
                local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
                    :format(game.PlaceId)

                local ok, body = pcall(function()
                    return game:HttpGet(url)
                end)
                if not ok then
                    ctx.Notify("Server list request failed", 5)
                    return
                end

                local decoded
                ok, decoded = pcall(function() return HttpService:JSONDecode(body) end)
                if not ok or type(decoded) ~= "table" or not decoded.data then
                    ctx.Notify("Could not read the server list", 5)
                    return
                end

                for _, server in ipairs(decoded.data) do
                    if server.playing and server.maxPlayers
                        and server.playing < server.maxPlayers
                        and server.id ~= game.JobId then
                        ctx.Notify("Hopping...", 4)
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
                        return
                    end
                end

                ctx.Notify("No other server with room", 5)
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Copy JobId",
        Description = "This server's instance id",
        Callback    = function()
            if setclipboard then
                setclipboard(game.JobId)
                ctx.Notify("JobId copied")
            else
                ctx.Notify("No setclipboard in this executor", 5)
            end
        end,
    })

    ------------------------------------------------------------------ player
    ctx.Tab:AddParagraph({ Title = "Character", Content = "" })

    ctx.Tab:AddSlider("Universal_WalkSpeed", {
        Title    = "WalkSpeed",
        Default  = 16,
        Min      = 16,
        Max      = 200,
        Rounding = 0,
        Callback = function(value)
            local char = LocalPlayer.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if hum then hum.WalkSpeed = value end
        end,
    })

    ctx.Tab:AddSlider("Universal_JumpPower", {
        Title    = "JumpPower",
        Default  = 50,
        Min      = 50,
        Max      = 300,
        Rounding = 0,
        Callback = function(value)
            local char = LocalPlayer.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.UseJumpPower = true
                hum.JumpPower    = value
            end
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Reset character",
        Description = "Breaks joints on your humanoid",
        Callback    = function()
            local char = LocalPlayer.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if hum then hum.Health = 0 end
        end,
    })

    ------------------------------------------------------------------ stats
    local statsParagraph = ctx.Tab:AddParagraph({
        Title   = "Stats",
        Content = "FPS: -   Ping: -",
    })

    ctx.Spawn(function()
        while ctx.IsAlive() do
            local fps, ping = "-", "-"
            pcall(function()
                local dt = RunService.RenderStepped:Wait()
                if type(dt) == "number" and dt > 0 then
                    fps = tostring(math.floor(1 / dt))
                end
            end)
            pcall(function()
                ping = math.floor(LocalPlayer:GetNetworkPing() * 1000) .. "ms"
            end)
            pcall(function()
                statsParagraph:SetDesc(("FPS: %s   Ping: %s"):format(fps, ping))
            end)
            task.wait(1)
        end
    end)
end

return M
