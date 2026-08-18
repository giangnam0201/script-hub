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
        cooldown    = 0.30,
        minClosing  = 40,       -- studs/s below which it is not a real throw
        alignment   = 0.75,     -- how directly the ball must be aimed at us
        oneShot     = true,     -- one parry per throw, never a stream
        ballName    = "ball",
        parryKey    = "F",
        onlyToward  = true,     -- ignore a ball that is moving away
    }

    local lastParry = -math.huge
    local parries = 0
    -- Latch: goes false after a parry and only re-arms once the ball stops
    -- threatening. Without it, impact stays under the threshold on every frame
    -- of the approach and the parry key is pressed over and over.
    local armed = true
    local lastBallSeen = nil
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

    ---------------------------------------------------------------- geometry
    -- Closing speed is the ball's velocity projected onto the line to us, so a
    -- ball flying past sideways does not count as incoming.
    local function predict(part, origin)
        if not (part and origin) then return nil end
        local offset = origin.Position - part.Position
        local distance = offset.Magnitude
        if distance <= 0 then return nil end

        local velocity = part.AssemblyLinearVelocity
        local closing = velocity:Dot(offset.Unit)

        local impact
        if closing > 0 then impact = distance / closing end
        return distance, closing, impact
    end

    local function solve(ball) return predict(ball, root()) end

    ------------------------------------------------------- ball discovery
    -- A live dump from the game showed why a plain name filter is not enough:
    -- a player called "bladeball_promax" put seven character parts into the
    -- candidate list, all moving at 30 while the real ball moved at 15, so
    -- "fastest match wins" locked onto that player instead of the ball.
    -- Character parts are therefore excluded structurally.
    local function isCharacterPart(part)
        local node = part
        while node and node ~= workspace do
            if node:IsA("Model") then
                if node:FindFirstChildOfClass("Humanoid") then return true end
                if Players:GetPlayerFromCharacter(node) then return true end
            end
            node = node.Parent
        end
        return false
    end

    -- The same dump showed balls live in workspace.Balls and are named by
    -- number ("859"), not "Ball", so the folder is the primary source and the
    -- name filter is only a fallback for other maps/modes.
    local function ballCandidates()
        local filter = settings.ballName:lower()
        local origin = root()
        local out, seen = {}, {}

        local function consider(part, source)
            if type(part) ~= "userdata" and not part.IsA then return end
            local ok = pcall(function() return part:IsA("BasePart") end)
            if not ok or not part:IsA("BasePart") then return end
            if seen[part] then return end
            if isCharacterPart(part) then return end
            seen[part] = true

            local distance, closing, impact = predict(part, origin)
            out[#out + 1] = {
                part     = part,
                source   = source,
                speed    = part.AssemblyLinearVelocity.Magnitude,
                distance = distance or math.huge,
                closing  = closing or 0,
                impact   = impact,
                path     = pathOf(part),
            }
        end

        pcall(function()
            local folder = workspace:FindFirstChild("Balls")
            if folder then
                for _, d in ipairs(folder:GetDescendants()) do
                    consider(d, "Balls folder")
                end
            end

            for _, d in ipairs(workspace:GetDescendants()) do
                local name = d.Name:lower()
                local parent = d.Parent
                local parentName = parent and parent.Name:lower() or ""
                if name:find(filter, 1, true) or parentName:find(filter, 1, true) then
                    consider(d, "name match")
                end
            end
        end)

        return out
    end

    -- Pick the most imminent threat, not the fastest object: with several
    -- balls in play the one arriving soonest is the one to parry.
    local function findBall()
        local list = ballCandidates()

        local best, bestImpact
        for _, c in ipairs(list) do
            if c.speed > 1 and c.impact and c.impact < (bestImpact or math.huge) then
                best, bestImpact = c, c.impact
            end
        end
        if best then
            return best.part, ("incoming, %.2fs (%s)"):format(bestImpact, best.source)
        end

        local fastest, fastestSpeed
        for _, c in ipairs(list) do
            if c.speed > 1 and (not fastestSpeed or c.speed > fastestSpeed) then
                fastest, fastestSpeed = c, c.speed
            end
        end
        if fastest then
            return fastest.part, ("moving, not incoming (%s)"):format(fastest.source)
        end

        local nearest, nearestDistance
        for _, c in ipairs(list) do
            if not nearestDistance or c.distance < nearestDistance then
                nearest, nearestDistance = c, c.distance
            end
        end
        if nearest then return nearest.part, ("idle (%s)"):format(nearest.source) end
        return nil, "no candidate"
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
        Default = 0.30, Min = 0, Max = 1, Rounding = 2,
    }):OnChanged(function(value) settings.cooldown = value end)

    ctx.Tab:AddToggle("BB_OneShot", {
        Title = "One parry per throw",
        Description = "Stops the key being held down through the whole approach",
        Default = true,
    }):OnChanged(function(value) settings.oneShot = value end)

    ctx.Tab:AddSlider("BB_MinClosing", {
        Title = "Ignore below closing speed",
        Description = "A hovering ball drifts slowly; a throw does not",
        Default = 40, Min = 0, Max = 200, Rounding = 0,
    }):OnChanged(function(value) settings.minClosing = value end)

    ctx.Tab:AddSlider("BB_Alignment", {
        Title = "Aim tolerance",
        Description = "1.00 = only a ball aimed straight at you, 0.50 = loose",
        Default = 0.75, Min = 0, Max = 1, Rounding = 2,
    }):OnChanged(function(value) settings.alignment = value end)

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
                    lines[#lines + 1] = ("%.0f studs  %.0f speed  %s  %s")
                        :format(c.distance, c.speed,
                                c.impact and ("%.2fs"):format(c.impact) or "away",
                                c.path)
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
        BB_OneShot    = "oneShot",
        BB_MinClosing = "minClosing",
        BB_Alignment  = "alignment",
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

    -- How directly the ball is travelling at us: 1 means straight at us, 0
    -- means sideways. A ball hovering or orbiting nearby drifts towards us for
    -- the odd frame and would otherwise read as an incoming throw.
    local function aimFactor(ball, closing)
        local speed = ball.AssemblyLinearVelocity.Magnitude
        if speed <= 1 then return 0 end
        return closing / speed
    end

    ctx.Connect(RunService.Heartbeat, function()
        if not currentBall or not currentBall.Parent then return end
        if not alive() then return end

        -- a different ball is a different throw
        if currentBall ~= lastBallSeen then
            lastBallSeen = currentBall
            armed = true
        end

        local distance, closing, impact = solve(currentBall)
        if not distance then return end

        local aim = aimFactor(currentBall, closing or 0)

        -- re-arm as soon as this ball is no longer a threat, which is what
        -- makes the next throw parryable
        if not impact or (closing or 0) < settings.minClosing
            or aim < settings.alignment then
            armed = true
        end

        if settings.autoParry and virtualInput
            and (os.clock() - lastParry) >= settings.cooldown
            and (armed or not settings.oneShot) then

            local fire = false
            if settings.mode == "Distance" then
                fire = distance <= settings.distance
                    and (not settings.onlyToward or (closing or 0) > 0)
            elseif impact then
                local threshold = settings.impactTime + pingSeconds() + settings.extraDelay
                fire = impact <= threshold
                    and (closing or 0) >= settings.minClosing
                    and aim >= settings.alignment
            end

            if fire then
                pressParry()
                armed = false
            end
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
                    ("armed %s   aim %.2f (need %.2f)   min closing %d"):format(
                        armed and "yes" or "no (fired)",
                        currentBall and aimFactor(currentBall, closing or 0) or 0,
                        settings.alignment, settings.minClosing),
                }, "\n"))
            end)
            task.wait(0.2)
        end
    end)
end

return M
