--[[
    Blade Ball - auto parry
    =======================
    Written from first principles rather than from the obfuscated script that
    was handed over, for two reasons:

      * That script is Luraph-obfuscated (it names itself in its own error
        text) and runs a bytecode VM. Its startup alone spins long enough to
        stop the client responding - which is the freeze you saw. Whatever it
        does, shipping it inside the hub would ship that freeze too.
      * Parry timing is just kinematics. The ball's position and velocity are
        replicated to you, so time-to-impact is computable directly, and a
        prediction you can see and tune beats a black box.

    Nothing here is guessed silently. The ball instance is discovered at
    runtime, and what was found - name, full path, speed, distance, predicted
    impact - is printed in Status every tick. If the discovery picks the wrong
    object, "List ball candidates" shows everything it considered so the
    Ball name filter can be corrected without touching the code.

    Parrying is a real keystroke through VirtualInputManager, the same
    mechanism the Finish The Word module uses, so the Roblox window has to be
    focused for it to land.
]]

local M = {}

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")
    local LocalPlayer = Players.LocalPlayer

    ------------------------------------------------------------------ state
    local settings = {
        autoParry   = false,
        mode        = "Time to impact",
        impactTime  = 0.16,     -- seconds before arrival to press
        distance    = 18,       -- studs, for the simple distance mode
        pingComp    = true,
        extraDelay  = 0.0,      -- manual nudge, negative = earlier
        cooldown    = 0.12,
        ballName    = "ball",
        parryKey    = "F",
        onlyToward  = true,     -- ignore a ball that is moving away
    }

    local lastParry = -math.huge
    local parries = 0
    local statusBox, candidateBox
    local currentBall, ballSource = nil, "none"

    ---------------------------------------------------------------- helpers
    local function root()
        local character = LocalPlayer.Character
        return character and character:FindFirstChild("HumanoidRootPart") or nil
    end

    local function alive()
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        return humanoid ~= nil and humanoid.Health > 0
    end

    local function pingSeconds()
        if not settings.pingComp then return 0 end
        local ok, value = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
        end)
        if ok and type(value) == "number" then return value end
        return 0
    end

    local function pathOf(instance)
        local ok, full = pcall(function() return instance:GetFullName() end)
        return ok and full or tostring(instance)
    end

    ------------------------------------------------------- ball discovery
    -- Every BasePart whose name contains the filter, plus anything sitting in
    -- a folder that looks like a ball container. Returned with the numbers
    -- that decide which one is the live ball.
    local function ballCandidates()
        local filter = settings.ballName:lower()
        local origin = root()
        local out = {}

        local ok = pcall(function()
            for _, descendant in ipairs(workspace:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    local name = descendant.Name:lower()
                    local parent = descendant.Parent
                    local parentName = parent and parent.Name:lower() or ""
                    if name:find(filter, 1, true)
                        or parentName:find(filter, 1, true) then
                        local velocity = descendant.AssemblyLinearVelocity
                        out[#out + 1] = {
                            part     = descendant,
                            speed    = velocity.Magnitude,
                            distance = origin
                                and (descendant.Position - origin.Position).Magnitude
                                or math.huge,
                            path     = pathOf(descendant),
                        }
                    end
                end
            end
        end)
        if not ok then return {} end
        return out
    end

    -- The live ball is the fastest-moving candidate; a stationary decoration
    -- called "Ball" never wins over the one actually flying at you.
    local function findBall()
        local best, bestSpeed
        for _, candidate in ipairs(ballCandidates()) do
            if candidate.speed > 1 and (not bestSpeed or candidate.speed > bestSpeed) then
                best, bestSpeed = candidate, candidate.speed
            end
        end
        if best then return best.part, "moving candidate" end

        -- nothing is moving: fall back to the nearest one so Status still
        -- shows something useful between rounds
        local nearest, nearestDistance
        for _, candidate in ipairs(ballCandidates()) do
            if not nearestDistance or candidate.distance < nearestDistance then
                nearest, nearestDistance = candidate, candidate.distance
            end
        end
        if nearest then return nearest.part, "nearest (idle)" end
        return nil, "no candidate"
    end

    ------------------------------------------------------------- prediction
    -- Closing speed is the component of the ball's velocity along the line to
    -- us, so a ball flying past sideways does not count as incoming.
    local function solve(ball)
        local origin = root()
        if not (ball and origin) then return nil end

        local offset = origin.Position - ball.Position
        local distance = offset.Magnitude
        if distance <= 0 then return nil end

        local velocity = ball.AssemblyLinearVelocity
        local closing = velocity:Dot(offset.Unit)   -- >0 means coming at us

        local impact
        if closing > 0 then impact = distance / closing end
        return distance, closing, impact
    end

    ------------------------------------------------------------------ input
    local virtualInput
    do
        local ok, service = pcall(function()
            return Instance.new("VirtualInputManager")
        end)
        if ok then virtualInput = service end
        if not virtualInput then
            ok, service = pcall(function()
                return game:GetService("VirtualInputManager")
            end)
            if ok then virtualInput = service end
        end
    end

    local function parryKeyCode()
        local ok, code = pcall(function()
            return Enum.KeyCode[settings.parryKey:upper()]
        end)
        return ok and code or Enum.KeyCode.F
    end

    local function pressParry()
        if not virtualInput then return false end
        local code = parryKeyCode()
        local ok = pcall(function()
            virtualInput:SendKeyEvent(true, code, false, game)
        end)
        -- released on a timer rather than after task.wait, because this runs
        -- inside a Heartbeat handler and must not yield there
        task.delay(0.01, function()
            pcall(function()
                virtualInput:SendKeyEvent(false, code, false, game)
            end)
        end)
        if ok then
            parries = parries + 1
            lastParry = os.clock()
        end
        return ok
    end

    ------------------------------------------------------------------- UI
    ctx.Tab:AddParagraph({
        Title   = "Blade Ball",
        Content = "Predicts when the ball reaches you and parries. Keep the Roblox "
               .. "window focused - keystrokes go nowhere if it is not. Check Status "
               .. "to confirm it locked on to the real ball before trusting it.",
    })

    ctx.Tab:AddToggle("BB_AutoParry", { Title = "Auto parry", Default = false })
        :OnChanged(function(value) settings.autoParry = value end)

    ctx.Tab:AddDropdown("BB_Mode", {
        Title = "Trigger on",
        Description = "Time to impact is the accurate one; Distance is a blunt fallback",
        Values = { "Time to impact", "Distance" }, Default = 1,
    }):OnChanged(function(value) settings.mode = tostring(value) end)

    ctx.Tab:AddSlider("BB_ImpactTime", {
        Title = "Parry at (seconds to impact)",
        Default = 0.16, Min = 0.02, Max = 0.6, Rounding = 2,
    }):OnChanged(function(value) settings.impactTime = value end)

    ctx.Tab:AddSlider("BB_Distance", {
        Title = "Parry at (studs)", Default = 18, Min = 3, Max = 60, Rounding = 0,
    }):OnChanged(function(value) settings.distance = value end)

    ctx.Tab:AddToggle("BB_PingComp", {
        Title = "Compensate for ping",
        Description = "Presses earlier by your current ping",
        Default = true,
    }):OnChanged(function(value) settings.pingComp = value end)

    ctx.Tab:AddSlider("BB_ExtraDelay", {
        Title = "Manual nudge (seconds)",
        Description = "Negative parries earlier, positive later",
        Default = 0, Min = -0.2, Max = 0.2, Rounding = 3,
    }):OnChanged(function(value) settings.extraDelay = value end)

    ctx.Tab:AddSlider("BB_Cooldown", {
        Title = "Minimum gap between parries",
        Default = 0.12, Min = 0, Max = 1, Rounding = 2,
    }):OnChanged(function(value) settings.cooldown = value end)

    ctx.Tab:AddToggle("BB_OnlyToward", {
        Title = "Only when incoming",
        Description = "Ignores a ball that is moving away from you",
        Default = true,
    }):OnChanged(function(value) settings.onlyToward = value end)

    ctx.Tab:AddInput("BB_BallName", {
        Title = "Ball name filter", Default = "ball", Placeholder = "ball",
    }):OnChanged(function(value)
        if type(value) == "string" and #value > 0 then settings.ballName = value:lower() end
    end)

    ctx.Tab:AddInput("BB_ParryKey", {
        Title = "Parry key", Default = "F", Placeholder = "F",
    }):OnChanged(function(value)
        if type(value) == "string" and #value > 0 then settings.parryKey = value end
    end)

    ctx.Tab:AddButton({
        Title       = "Parry now",
        Description = "Fires one keystroke, to check the key is right",
        Callback    = function() ctx.Spawn(function() pressParry() end) end,
    })

    ctx.Tab:AddButton({
        Title       = "List ball candidates",
        Description = "Everything the name filter matches, with speed and distance",
        Callback    = function()
            ctx.Spawn(function()
                local list = ballCandidates()
                table.sort(list, function(a, b) return a.speed > b.speed end)
                local lines = {}
                for i = 1, math.min(#list, 12) do
                    local c = list[i]
                    lines[#lines + 1] = ("%.0f studs  %.0f speed  %s")
                        :format(c.distance, c.speed, c.path)
                end
                if #lines == 0 then
                    lines[1] = ('nothing in workspace matches "%s"'):format(settings.ballName)
                end
                local text = table.concat(lines, "\n")
                pcall(function() candidateBox:SetDesc(text) end)
                if setclipboard then pcall(setclipboard, text) end
                ctx.Notify(("%d candidates (copied)"):format(#list), 4, "Blade Ball")
            end)
        end,
    })

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "-" })
    candidateBox = ctx.Tab:AddParagraph({ Title = "Ball candidates", Content = "-" })

    -- Read the controls off the UI each tick, so values restored from a saved
    -- config or set with SetValue are picked up too, not only OnChanged.
    local OPTION_MAP = {
        BB_AutoParry  = "autoParry",
        BB_Mode       = "mode",
        BB_ImpactTime = "impactTime",
        BB_Distance   = "distance",
        BB_PingComp   = "pingComp",
        BB_ExtraDelay = "extraDelay",
        BB_Cooldown   = "cooldown",
        BB_OnlyToward = "onlyToward",
        BB_BallName   = "ballName",
        BB_ParryKey   = "parryKey",
    }

    local function syncOptions()
        local options = ctx.Options
        if not options then return end
        for id, key in pairs(OPTION_MAP) do
            local option = options[id]
            if option ~= nil then
                local ok, value = pcall(function() return option.Value end)
                if ok and value ~= nil then
                    if key == "mode" or key == "parryKey" then
                        settings[key] = tostring(value)
                    elseif key == "ballName" then
                        if type(value) == "string" and #value > 0 then
                            settings[key] = value:lower()
                        end
                    else
                        settings[key] = value
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------- run
    if not virtualInput then
        ctx.Tab:AddParagraph({
            Title   = "Parrying unavailable",
            Content = "This executor would not give a VirtualInputManager, so keystrokes "
                   .. "cannot be sent. The prediction still runs and Status still reports "
                   .. "the timing, so it is usable as a readout.",
        })
    end

    -- Rediscovering the ball means walking every descendant of workspace, so
    -- it happens twice a second, not every frame. The tracking below reads the
    -- cached part, which is cheap.
    ctx.Spawn(function()
        while ctx.IsAlive() do
            syncOptions()
            local found, source = findBall()
            currentBall, ballSource = found, source
            task.wait(0.5)
        end
    end)

    ctx.Connect(RunService.Heartbeat, function()
        if not currentBall or not currentBall.Parent then return end
        if not alive() then return end

        local distance, closing, impact = solve(currentBall)
        if not distance then return end

        if settings.autoParry and virtualInput
            and (os.clock() - lastParry) >= settings.cooldown then

            local fire = false
            if settings.mode == "Distance" then
                fire = distance <= settings.distance
                    and (not settings.onlyToward or closing > 0)
            else
                if impact then
                    local threshold = settings.impactTime + pingSeconds() + settings.extraDelay
                    fire = impact <= threshold
                end
            end

            if fire then pressParry() end
        end
    end)

    ctx.Spawn(function()
        while ctx.IsAlive() do
            local distance, closing, impact = solve(currentBall)
            pcall(function()
                statusBox:SetDesc(table.concat({
                    ("key %s   input %s   parries %d"):format(
                        settings.parryKey:upper(),
                        virtualInput and "ready" or "NO VirtualInputManager",
                        parries),
                    ("ball: %s (%s)"):format(
                        currentBall and currentBall.Name or "not found", ballSource),
                    currentBall and ("path: %s"):format(pathOf(currentBall)) or "path: -",
                    distance and ("distance %.1f   closing %.1f/s   impact %s")
                        :format(distance, closing or 0,
                                impact and ("%.3fs"):format(impact) or "not incoming")
                        or "distance -",
                    ("ping %.0f ms   threshold %.3fs"):format(
                        pingSeconds() * 1000,
                        settings.impactTime + pingSeconds() + settings.extraDelay),
                }, "\n"))
            end)
            task.wait(0.2)
        end
    end)
end

return M
