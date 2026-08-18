--[[
    Crawl - game structure dumper / live traffic watcher
    ====================================================
    A diagnostic tool, not a cheat. It answers "what does this game actually
    look like, and what happens at the moment I'm supposed to act?" so a
    module can be written against real structure instead of guesses.

    Three things it produces:

      1. Snapshot   - the instance tree (classes, names, values, attributes,
                      GUI text), every remote, LocalPlayer attributes, and any
                      Lua table in memory that looks game-related.
      2. Watch      - records remote traffic, attribute changes and GUI text
                      changes for N seconds, so a round can be captured as it
                      happens.
      3. Report     - both of the above written to a file (and clipboard),
                      ready to be handed over.

    Everything is bounded (node caps, string caps, depth caps) and every
    property read is pcall'd, because plenty of instances error on access.
]]

local M = {}

local MAX_STRING = 300
local MAX_ATTRS  = 24

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer

    local settings = {
        maxNodes = 8000,
        maxDepth = 8,
        watchFor = 30,
    }

    local report = {}
    local watching = false
    local watchLog = {}

    local function out(fmt, ...)
        local ok, text = pcall(string.format, fmt, ...)
        report[#report + 1] = ok and text or tostring(fmt)
    end

    local function safe(fn, fallback)
        local ok, value = pcall(fn)
        if ok then return value end
        return fallback
    end

    local function trim(value)
        local text = tostring(value)
        if #text > MAX_STRING then
            return text:sub(1, MAX_STRING) .. ("...<%d bytes>"):format(#text)
        end
        return text
    end

    ---------------------------------------------------------------- snapshot
    local INTERESTING_CLASS = {
        RemoteEvent = true, RemoteFunction = true, BindableEvent = true,
        BindableFunction = true, UnreliableRemoteEvent = true,
        StringValue = true, IntValue = true, NumberValue = true, BoolValue = true,
        ObjectValue = true, TextLabel = true, TextButton = true, TextBox = true,
    }

    local function describe(instance)
        local class = safe(function() return instance.ClassName end, "?")
        local name  = safe(function() return instance.Name end, "?")
        local extra = {}

        if class:find("Value$") then
            extra[#extra + 1] = "Value=" .. trim(safe(function() return instance.Value end, "?"))
        end
        if class == "TextLabel" or class == "TextButton" or class == "TextBox" then
            local text = safe(function() return instance.Text end, "")
            if text ~= "" then extra[#extra + 1] = "Text=" .. trim(text) end
            local visible = safe(function() return instance.Visible end, nil)
            if visible ~= nil then extra[#extra + 1] = "Visible=" .. tostring(visible) end
        end

        local attrs = safe(function() return instance:GetAttributes() end, nil)
        if type(attrs) == "table" then
            local parts, n = {}, 0
            for key, value in pairs(attrs) do
                n = n + 1
                if n > MAX_ATTRS then parts[#parts + 1] = "..." break end
                parts[#parts + 1] = tostring(key) .. "=" .. trim(value)
            end
            if #parts > 0 then
                table.sort(parts)
                extra[#extra + 1] = "@{" .. table.concat(parts, ", ") .. "}"
            end
        end

        return ("%s %q%s"):format(class, name,
            #extra > 0 and ("  " .. table.concat(extra, "  ")) or "")
    end

    local remotes = {}

    local function walk(instance, depth, budget)
        if budget.count >= settings.maxNodes then return end
        budget.count = budget.count + 1

        local class = safe(function() return instance.ClassName end, "?")
        if class:find("Remote") or class:find("Bindable") then
            remotes[#remotes + 1] = safe(function() return instance:GetFullName() end, "?")
        end

        out("%s%s", string.rep("  ", depth), describe(instance))

        if depth >= settings.maxDepth then
            out("%s  ...", string.rep("  ", depth))
            return
        end

        local children = safe(function() return instance:GetChildren() end, nil)
        if type(children) ~= "table" then return end
        for _, child in ipairs(children) do
            walk(child, depth + 1, budget)
        end
    end

    local function snapshotTree()
        local roots = {
            "ReplicatedStorage", "ReplicatedFirst", "Workspace", "Lighting",
            "StarterGui", "StarterPlayer", "Teams", "SoundService",
        }

        for _, serviceName in ipairs(roots) do
            local service = safe(function() return game:GetService(serviceName) end, nil)
            if service then
                out("")
                out("---- %s ----", serviceName)
                walk(service, 0, { count = 0 })
            end
        end

        local gui = safe(function() return LocalPlayer:FindFirstChild("PlayerGui") end, nil)
        if gui then
            out("")
            out("---- PlayerGui ----")
            walk(gui, 0, { count = 0 })
        end

        local scripts = safe(function() return LocalPlayer:FindFirstChild("PlayerScripts") end, nil)
        if scripts then
            out("")
            out("---- PlayerScripts ----")
            walk(scripts, 0, { count = 0 })
        end
    end

    local function snapshotPlayer()
        out("")
        out("---- LocalPlayer ----")
        out("Name: %s  UserId: %s", safe(function() return LocalPlayer.Name end, "?"),
            tostring(safe(function() return LocalPlayer.UserId end, "?")))

        local attrs = safe(function() return LocalPlayer:GetAttributes() end, nil)
        if type(attrs) == "table" then
            for key, value in pairs(attrs) do
                out("  attribute %s = %s", tostring(key), trim(value))
            end
        end

        local character = safe(function() return LocalPlayer.Character end, nil)
        if character then
            local charAttrs = safe(function() return character:GetAttributes() end, nil)
            if type(charAttrs) == "table" then
                for key, value in pairs(charAttrs) do
                    out("  character attribute %s = %s", tostring(key), trim(value))
                end
            end
        end
    end

    -- Anything in memory that smells like round/word state.
    local KEY_HINTS = {
        "question", "word", "letter", "turn", "answer", "choice", "prompt",
        "round", "player", "timer", "remote", "fire", "ping", "state", "game",
    }

    local function looksInteresting(key)
        local lowered = tostring(key):lower()
        for _, hint in ipairs(KEY_HINTS) do
            if lowered:find(hint, 1, true) then return true end
        end
        return false
    end

    local function snapshotMemory()
        out("")
        out("---- tables in memory that look game-related ----")
        if not getgc then
            out("(no getgc in this executor)")
            return
        end

        local shown = 0
        local objects = safe(function() return getgc(true) end, {})
        for _, object in ipairs(objects) do
            if shown >= 120 then break end
            if type(object) == "table" then
                local keys, hits = {}, 0
                local ok = pcall(function()
                    for key, value in pairs(object) do
                        if #keys < 30 then
                            keys[#keys + 1] = tostring(key) ..
                                (type(value) == "function" and "()" or
                                 type(value) == "table" and "{}" or
                                 ("=" .. trim(value)))
                        end
                        if looksInteresting(key) then hits = hits + 1 end
                    end
                end)
                if ok and hits >= 2 and #keys > 0 then
                    shown = shown + 1
                    table.sort(keys)
                    out("  table: %s", table.concat(keys, ", "))
                end
            end
        end
        if shown == 0 then out("(nothing matched)") end

        -- strings big enough to be a word list
        out("")
        out("---- long strings in memory (possible word lists) ----")
        local strings = 0
        for _, object in ipairs(objects) do
            if strings >= 20 then break end
            if type(object) == "string" and #object > 2000 then
                strings = strings + 1
                out("  %d bytes: %s", #object, trim(object:sub(1, 200)))
            end
        end
        if strings == 0 then out("(none)") end
    end

    local function snapshotRemotes()
        out("")
        out("---- remotes found (%d) ----", #remotes)
        table.sort(remotes)
        for _, path in ipairs(remotes) do out("  %s", path) end
    end

    local function snapshotModules()
        if not getloadedmodules then return end
        out("")
        out("---- loaded module scripts ----")
        local modules = safe(function() return getloadedmodules() end, {})
        local shown = 0
        for _, module in ipairs(modules) do
            if shown >= 200 then break end
            shown = shown + 1
            out("  %s", safe(function() return module:GetFullName() end, "?"))
        end
    end

    local function crawl()
        report = {}
        remotes = {}
        out("==== namdevHub crawl ====")
        out("game: %s", tostring(ctx.GameInfo.Name))
        out("PlaceId: %d   GameId: %d   JobId: %s",
            ctx.GameInfo.PlaceId, ctx.GameInfo.GameId, tostring(ctx.GameInfo.JobId))
        out("executor: %s", tostring(ctx.Hub.Executor))
        out("clock: %s", tostring(os.time()))

        snapshotPlayer()
        snapshotTree()
        snapshotRemotes()
        snapshotMemory()
        snapshotModules()
        return table.concat(report, "\n")
    end

    ------------------------------------------------------------------ watch
    -- Records what the game does while you play a round. Remote traffic is
    -- captured through __namecall when the executor allows it; the hook is
    -- always restored, and it is also restored on unload.
    local restoreHook

    local function startRemoteHook()
        if restoreHook then return true end
        if not (getrawmetatable and setreadonly and hookmetamethod) then return false end

        local ok = pcall(function()
            local original
            original = hookmetamethod(game, "__namecall", function(self, ...)
                if watching then
                    local method = getnamecallmethod and getnamecallmethod() or "?"
                    if method == "FireServer" or method == "InvokeServer" then
                        local args = {}
                        for i = 1, select("#", ...) do
                            args[i] = trim((select(i, ...)))
                        end
                        watchLog[#watchLog + 1] = ("%.2f  %s:%s(%s)"):format(
                            os.clock(), safe(function() return self:GetFullName() end, "?"),
                            method, table.concat(args, ", "))
                    end
                end
                return original(self, ...)
            end)
            restoreHook = function()
                pcall(function() hookmetamethod(game, "__namecall", original) end)
            end
        end)
        return ok
    end

    -- Fallback / addition: wrap the fire functions on any game table that has
    -- them, so we see internal calls that never touch a RemoteEvent directly.
    local wrapped = {}

    local function wrapNetworkTables()
        if not getgc then return 0 end
        local count = 0
        for _, object in ipairs(safe(function() return getgc(true) end, {})) do
            if type(object) == "table" and not wrapped[object] then
                local ok = pcall(function()
                    for _, key in ipairs({ "fire", "remoteFire", "invoke", "remoteInvoke" }) do
                        local fn = rawget(object, key)
                        if type(fn) == "function" then
                            wrapped[object] = wrapped[object] or {}
                            wrapped[object][key] = fn
                            rawset(object, key, function(...)
                                if watching then
                                    local args = {}
                                    for i = 1, select("#", ...) do
                                        args[i] = trim((select(i, ...)))
                                    end
                                    watchLog[#watchLog + 1] = ("%.2f  net.%s(%s)"):format(
                                        os.clock(), key, table.concat(args, ", "))
                                end
                                return fn(...)
                            end)
                            count = count + 1
                        end
                    end
                end)
                if not ok then wrapped[object] = nil end
            end
        end
        return count
    end

    local function unwrapNetworkTables()
        for object, keys in pairs(wrapped) do
            for key, fn in pairs(keys) do
                pcall(function() rawset(object, key, fn) end)
            end
        end
        wrapped = {}
    end

    local function watch(seconds)
        if watching then
            ctx.Notify("already watching", 3, "Crawl")
            return
        end

        watchLog = {}
        watching = true

        local hooked = startRemoteHook()
        local wrappedCount = wrapNetworkTables()
        watchLog[#watchLog + 1] = ("watch started: namecall hook=%s, wrapped fns=%d")
            :format(tostring(hooked), wrappedCount)

        ctx.Notify(("watching for %ds - play a round now"):format(seconds), 5, "Crawl")

        -- attribute + GUI text polling
        local lastAttrs, lastText = {}, {}

        local function pollAttributes(instance, label)
            local attrs = safe(function() return instance:GetAttributes() end, nil)
            if type(attrs) ~= "table" then return end
            for key, value in pairs(attrs) do
                local id = label .. "." .. tostring(key)
                local text = trim(value)
                if lastAttrs[id] ~= text then
                    if lastAttrs[id] ~= nil then
                        watchLog[#watchLog + 1] = ("%.2f  attribute %s: %s -> %s")
                            :format(os.clock(), id, lastAttrs[id], text)
                    end
                    lastAttrs[id] = text
                end
            end
        end

        local deadline = os.clock() + seconds
        while os.clock() < deadline and ctx.IsAlive() do
            pollAttributes(LocalPlayer, "LocalPlayer")
            local character = safe(function() return LocalPlayer.Character end, nil)
            if character then pollAttributes(character, "Character") end

            local gui = safe(function() return LocalPlayer:FindFirstChild("PlayerGui") end, nil)
            if gui then
                local descendants = safe(function() return gui:GetDescendants() end, nil)
                if type(descendants) == "table" then
                    for _, item in ipairs(descendants) do
                        local class = safe(function() return item.ClassName end, "")
                        if class == "TextLabel" or class == "TextButton" or class == "TextBox" then
                            local path = safe(function() return item:GetFullName() end, "?")
                            local text = trim(safe(function() return item.Text end, ""))
                            if lastText[path] ~= text then
                                if lastText[path] ~= nil then
                                    watchLog[#watchLog + 1] = ("%.2f  text %s: %q -> %q")
                                        :format(os.clock(), path, lastText[path], text)
                                end
                                lastText[path] = text
                            end
                        end
                    end
                end
            end

            task.wait(0.1)
        end

        watching = false
        unwrapNetworkTables()
        if restoreHook then
            restoreHook()
            restoreHook = nil
        end

        ctx.Notify(("watch finished - %d events"):format(#watchLog), 5, "Crawl")
    end

    ----------------------------------------------------------------- output
    local function fullText()
        local parts = { table.concat(report, "\n") }
        if #watchLog > 0 then
            parts[#parts + 1] = "\n\n==== watch log (" .. #watchLog .. " events) ====\n"
                .. table.concat(watchLog, "\n")
        end
        return table.concat(parts, "")
    end

    local function save()
        local text = fullText()
        if #text == 0 then
            ctx.Notify("nothing to save - run Crawl game first", 4, "Crawl")
            return
        end

        local path = ("namdevHub/crawl-%d-%d.txt"):format(ctx.GameInfo.PlaceId, os.time())
        if writefile then
            local ok = pcall(function()
                if makefolder and not (isfolder and isfolder("namdevHub")) then
                    pcall(makefolder, "namdevHub")
                end
                writefile(path, text)
            end)
            if ok then
                ctx.Notify(("saved %d KB to %s"):format(math.floor(#text / 1024), path), 8, "Crawl")
                return path
            end
        end
        ctx.Notify("this executor has no writefile - use Copy to clipboard", 6, "Crawl")
        return nil
    end

    -------------------------------------------------------------------- UI
    ctx.Tab:AddParagraph({
        Title   = "Crawl",
        Content = "Dumps what this game actually looks like so a script can be written "
               .. "against it. Run 'Crawl game', then 'Watch a round' and play one turn, "
               .. "then 'Save report' and send the file.",
    })

    ctx.Tab:AddSlider("Crawl_MaxNodes", {
        Title = "Max instances per service", Default = 8000, Min = 500, Max = 40000, Rounding = 0,
    }):OnChanged(function(value) settings.maxNodes = value end)

    ctx.Tab:AddSlider("Crawl_MaxDepth", {
        Title = "Max tree depth", Default = 8, Min = 2, Max = 20, Rounding = 0,
    }):OnChanged(function(value) settings.maxDepth = value end)

    ctx.Tab:AddSlider("Crawl_WatchFor", {
        Title = "Watch duration (seconds)", Default = 30, Min = 5, Max = 180, Rounding = 0,
    }):OnChanged(function(value) settings.watchFor = value end)

    local summary

    ctx.Tab:AddButton({
        Title       = "Crawl game",
        Description = "Snapshot instances, remotes, attributes and memory",
        Callback    = function()
            ctx.Spawn(function()
                ctx.Notify("crawling...", 3, "Crawl")
                local ok, text = pcall(crawl)
                if not ok then
                    ctx.Notify("crawl failed: " .. tostring(text), 8, "Crawl")
                    return
                end
                ctx.Notify(("crawl done - %d lines, %d KB"):format(#report,
                    math.floor(#text / 1024)), 6, "Crawl")
                if summary then
                    pcall(function()
                        summary:SetDesc(("%d lines, %d remotes, %d KB - Save report next")
                            :format(#report, #remotes, math.floor(#text / 1024)))
                    end)
                end
            end)
        end,
    })

    -- Targeted check of everything the Finish The Word module depends on, so a
    -- failure points at one line instead of "it doesn't work".
    ctx.Tab:AddButton({
        Title       = "Probe Finish The Word",
        Description = "Checks each thing the FTW module needs and reports which is missing",
        Callback    = function()
            ctx.Spawn(function()
                report = {}
                out("==== Finish The Word probe ====")
                out("PlaceId: %d   GameId: %d", ctx.GameInfo.PlaceId, ctx.GameInfo.GameId)
                out("getgc: %s   getloadedmodules: %s   hookmetamethod: %s",
                    tostring(getgc ~= nil), tostring(getloadedmodules ~= nil),
                    tostring(hookmetamethod ~= nil))

                local attrs = safe(function() return LocalPlayer:GetAttributes() end, nil)
                out("")
                out("LocalPlayer attributes:")
                if type(attrs) == "table" and next(attrs) then
                    for key, value in pairs(attrs) do
                        out("  %s = %s", tostring(key), trim(value))
                    end
                else
                    out("  (none - so IsTurn is NOT an attribute on the player here)")
                end

                if not getgc then
                    out("")
                    out("no getgc: this executor cannot find the game's tables at all")
                else
                    local objects = safe(function() return getgc(true) end, {})
                    out("")
                    out("gc objects: %d", #objects)

                    local net, question, wordString = nil, nil, nil
                    local fireLike, questionLike = {}, {}

                    for _, object in ipairs(objects) do
                        if type(object) == "table" then
                            pcall(function()
                                if rawget(object, "remoteFire") and rawget(object, "remoteConnect")
                                    and rawget(object, "fire") and rawget(object, "ping") then
                                    net = object
                                elseif rawget(object, "fire") or rawget(object, "remoteFire") then
                                    if #fireLike < 10 then fireLike[#fireLike + 1] = object end
                                end

                                if rawget(object, "QuestionLabel")
                                    and (rawget(object, "RequiredLetter") or rawget(object, "Choices")) then
                                    question = object
                                elseif rawget(object, "RequiredLetter") or rawget(object, "QuestionLabel")
                                    or rawget(object, "Choices") then
                                    if #questionLike < 10 then questionLike[#questionLike + 1] = object end
                                end
                            end)
                        elseif type(object) == "string" and not wordString
                            and object:find("whitelistedFtwWords", 1, true) then
                            wordString = object
                        end
                    end

                    local function dumpKeys(label, object)
                        local keys = {}
                        pcall(function()
                            for key, value in pairs(object) do
                                if #keys < 40 then
                                    keys[#keys + 1] = tostring(key) ..
                                        (type(value) == "function" and "()" or "")
                                end
                            end
                        end)
                        table.sort(keys)
                        out("  %s: %s", label, table.concat(keys, ", "))
                    end

                    out("")
                    out("network table (needs remoteFire+remoteConnect+fire+ping): %s",
                        net and "FOUND" or "NOT FOUND")
                    if net then dumpKeys("keys", net) end
                    if #fireLike > 0 then
                        out("  near-misses with a fire/remoteFire key: %d", #fireLike)
                        for i, object in ipairs(fireLike) do dumpKeys("candidate " .. i, object) end
                    end

                    out("")
                    out("question table (needs QuestionLabel + RequiredLetter/Choices): %s",
                        question and "FOUND" or "NOT FOUND")
                    if question then dumpKeys("keys", question) end
                    if #questionLike > 0 then
                        out("  near-misses: %d", #questionLike)
                        for i, object in ipairs(questionLike) do dumpKeys("candidate " .. i, object) end
                    end

                    out("")
                    out("word list string containing 'whitelistedFtwWords': %s",
                        wordString and ("FOUND, " .. #wordString .. " bytes") or "NOT FOUND")
                end

                local text = table.concat(report, "\n")
                ctx.Notify("probe done - Save report or Copy to clipboard", 6, "Crawl")
                if summary then
                    pcall(function() summary:SetDesc(("probe: %d lines"):format(#report)) end)
                end
                return text
            end)
        end,
    })

    -- The match UI only exists while a round is running, so it misses the
    -- full crawl done in the lobby. This grabs just that, on demand.
    ctx.Tab:AddButton({
        Title       = "Dump match UI now",
        Description = "PlayerGui + your table, mid-round - run this while playing",
        Callback    = function()
            ctx.Spawn(function()
                report = {}
                out("==== match UI dump ====")
                out("clock: %s   IsTurn: %s", tostring(os.time()),
                    tostring(safe(function() return LocalPlayer:GetAttribute("IsTurn") end, nil)))

                local gui = safe(function() return LocalPlayer:FindFirstChild("PlayerGui") end, nil)
                if gui then
                    out("")
                    out("---- PlayerGui ----")
                    walk(gui, 0, { count = 0 })
                end

                -- the table you are sitting at
                local character = safe(function() return LocalPlayer.Character end, nil)
                local humanoid = character and safe(function()
                    return character:FindFirstChildOfClass("Humanoid")
                end, nil)
                local seat = humanoid and safe(function() return humanoid.SeatPart end, nil)

                out("")
                out("---- your seat ----")
                out("SeatPart: %s", seat and safe(function() return seat:GetFullName() end, "?") or "not seated")

                if seat then
                    local node = seat
                    while node and node ~= workspace do
                        local display = safe(function() return node:FindFirstChild("Table") end, nil)
                        if display then
                            out("")
                            out("---- your table ----")
                            walk(node, 0, { count = 0 })
                            break
                        end
                        node = safe(function() return node.Parent end, nil)
                    end
                end

                ctx.Notify("match UI dumped - Save report or Copy to clipboard", 6, "Crawl")
                if summary then
                    pcall(function() summary:SetDesc(("match dump: %d lines"):format(#report)) end)
                end
            end)
        end,
    })

    -- Any other executor script draws its menu into CoreGui (or PlayerGui on
    -- executors without gethui). The toggle and button labels in that menu are
    -- that script's feature list, stated by the script itself - which is far
    -- cheaper to read than decompiling it.
    ctx.Tab:AddButton({
        Title       = "Dump script menus",
        Description = "Lists every GUI another script has drawn, with its labels",
        Callback    = function()
            ctx.Spawn(function()
                report = {}
                out("==== script menu dump ====")
                out("executor: %s", safe(function()
                    return identifyexecutor and identifyexecutor() or "?" end, "?"))

                local roots = {}
                local hidden = safe(function() return gethui and gethui() end, nil)
                if hidden then roots[#roots + 1] = { "gethui()", hidden } end
                local core = safe(function() return game:GetService("CoreGui") end, nil)
                if core then roots[#roots + 1] = { "CoreGui", core } end
                local playerGui = safe(function()
                    return LocalPlayer:FindFirstChild("PlayerGui") end, nil)
                if playerGui then roots[#roots + 1] = { "PlayerGui", playerGui } end

                -- text-bearing descendants only; a full tree dump of a UI
                -- library is mostly layout objects and drowns the labels
                local function dumpTexts(container, indent, state)
                    for _, child in ipairs(safe(function()
                        return container:GetChildren() end, {}) or {}) do
                        state.count = state.count + 1
                        if state.count > 4000 then return end
                        local class = safe(function() return child.ClassName end, "?")
                        local text = safe(function() return child.Text end, nil)
                        if type(text) == "string" and #text > 0 then
                            out("%s%s %q", string.rep("  ", indent), class, text)
                        end
                        dumpTexts(child, indent + 1, state)
                    end
                end

                local total = 0
                for _, entry in ipairs(roots) do
                    local label, root = entry[1], entry[2]
                    for _, gui in ipairs(safe(function()
                        return root:GetChildren() end, {}) or {}) do
                        local name = safe(function() return gui.Name end, "?")
                        local class = safe(function() return gui.ClassName end, "?")
                        -- skip the hub's own window so the output is only
                        -- other scripts
                        if name ~= (ctx.HubName or "namdevHub") then
                            total = total + 1
                            out("")
                            out("---- %s / %s %q ----", label, class, name)
                            dumpTexts(gui, 1, { count = 0 })
                        end
                    end
                end

                out("")
                out("GUIs dumped: %d", total)
                ctx.Notify(("dumped %d GUIs - Copy report to clipboard"):format(total),
                    6, "Crawl")
                if summary then
                    pcall(function()
                        summary:SetDesc(("menu dump: %d GUIs, %d lines"):format(total, #report))
                    end)
                end
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Watch a round",
        Description = "Record remotes, attributes and GUI text while you play",
        Callback    = function()
            ctx.Spawn(function() watch(settings.watchFor) end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Save report",
        Description = "Writes crawl + watch log to a file",
        Callback    = function() ctx.Spawn(save) end,
    })

    ctx.Tab:AddButton({
        Title       = "Copy report to clipboard",
        Description = "For executors without writefile (may be truncated)",
        Callback    = function()
            local text = fullText()
            if #text == 0 then
                ctx.Notify("nothing to copy - run Crawl game first", 4, "Crawl")
            elseif setclipboard then
                setclipboard(text)
                ctx.Notify(("copied %d KB"):format(math.floor(#text / 1024)), 5, "Crawl")
            else
                ctx.Notify("no setclipboard in this executor", 5, "Crawl")
            end
        end,
    })

    summary = ctx.Tab:AddParagraph({ Title = "Last crawl", Content = "-" })

    ctx.OnUnload(function()
        watching = false
        unwrapNetworkTables()
        if restoreHook then
            restoreHook()
            restoreHook = nil
        end
    end)
end

return M
