--[[
    Script finder
    =============
    Searches scriptblox for the game you are actually in, right now, and runs
    what it finds. No catalog to go stale, and it covers every game rather
    than a list of fifty.

    What the API gives back, and how it is used:

      * game.gameId is the Roblox PlaceId (2753915549 came back for Blox
        Fruits), so a result can be tied to this exact game instead of a
        fuzzy name match. Those rank far above everything else.
      * isUniversal / gameId == -1 are the multi-game hubs. They are kept as
        a fallback, below the exact matches.
      * key == true means a key system, which cannot be automated, so those
        are filtered out unless you ask for them.
      * isPatched == true is always dropped.

    The API ignores mode=free and strict=true - all three return identical
    results - so every filter here runs on the response.

    A script that turns out to be broken is normal, which is what Next script
    is for: it steps to the following candidate and runs that instead.
]]

local M = {}

function M.Setup(ctx)
    local HttpService = game:GetService("HttpService")

    ------------------------------------------------------------------ state
    local settings = {
        autoLoad     = true,
        allowKey     = false,
        universalToo = true,
        query        = "",
    }

    local results, index = {}, 0
    local searching, loadedIndex = false, nil
    local lastError
    local statusBox, resultBox

    ---------------------------------------------------------------- helpers
    local function safe(fn, fallback)
        local ok, value = pcall(fn)
        if ok then return value end
        return fallback
    end

    local function httpGet(url)
        local requester = (syn and syn.request) or http_request or request
        if requester then
            local ok, response = pcall(requester, {
                Url = url, Method = "GET",
                Headers = { ["User-Agent"] = "Mozilla/5.0" },
            })
            if ok and type(response) == "table" and response.Body
                and (response.StatusCode == 200 or response.StatusCode == nil) then
                return response.Body
            end
        end
        local ok, body = pcall(function() return game:HttpGet(url) end)
        if ok and type(body) == "string" and #body > 0 then return body end
        return nil
    end

    local function encode(text)
        local ok, out = pcall(function() return HttpService:UrlEncode(text) end)
        if ok and out then return out end
        return (tostring(text):gsub("[^%w%-%._~]", function(c)
            return ("%%%02X"):format(string.byte(c))
        end))
    end

    local function setStatus(text)
        if statusBox then pcall(function() statusBox:SetDesc(text) end) end
    end

    ------------------------------------------------------------------ rank
    -- Exact PlaceId dominates; a keyless script beats a key one; verified and
    -- well-liked break the remaining ties.
    local function score(entry)
        local placeId = ctx.GameInfo and ctx.GameInfo.PlaceId or 0
        local gameId = tonumber(entry.game and entry.game.gameId or -1) or -1
        local value = 0

        if gameId == placeId and placeId ~= 0 then
            value = value + 1000000
        elseif entry.isUniversal or gameId == -1 then
            value = value + 1000
        end

        if not entry.key then value = value + 20000 end
        if entry.verified then value = value + 5000 end

        local likes = tonumber(entry.likeCount or 0) or 0
        local dislikes = tonumber(entry.dislikeCount or 0) or 0
        value = value + likes * 10 - dislikes * 20

        local views = tonumber(entry.views or 0) or 0
        value = value + math.min(views / 100, 2000)

        -- a bumped-this-month script is worth more than a stale one
        local bump = tostring(entry.lastBump or entry.createdAt or "")
        local y, m = bump:match("^(%d+)-(%d+)")
        if y and m then value = value + (tonumber(y) * 12 + tonumber(m)) * 3 end

        return value
    end

    local function usable(entry)
        if entry.isPatched then return false end
        if entry.key and not settings.allowKey then return false end
        if type(entry.script) ~= "string" or #entry.script == 0 then return false end

        local placeId = ctx.GameInfo and ctx.GameInfo.PlaceId or 0
        local gameId = tonumber(entry.game and entry.game.gameId or -1) or -1
        local exact = (gameId == placeId and placeId ~= 0)
        local universal = (entry.isUniversal or gameId == -1)

        if not exact and not universal then
            -- a result for some other game entirely
            return false
        end
        if universal and not exact and not settings.universalToo then return false end
        return true
    end

    ----------------------------------------------------------------- search
    local function search()
        if searching then return end
        searching = true
        results, index, loadedIndex, lastError = {}, 0, nil, nil

        local term = settings.query
        if term == "" then term = (ctx.GameInfo and ctx.GameInfo.Name) or "" end
        if term == "" then
            searching = false
            setStatus("no game name to search for")
            return
        end

        setStatus(('searching scriptblox for "%s"...'):format(term))

        local collected = {}
        for page = 1, 3 do
            local url = ("https://scriptblox.com/api/script/search?q=%s&max=20&page=%d")
                :format(encode(term), page)
            local body = httpGet(url)
            if not body then
                lastError = "http request failed - does this executor allow HttpGet?"
                break
            end

            local ok, decoded = pcall(function() return HttpService:JSONDecode(body) end)
            if not ok or type(decoded) ~= "table" then
                lastError = "could not parse the api response"
                break
            end

            local batch = decoded.result and decoded.result.scripts
            if type(batch) ~= "table" or #batch == 0 then break end
            for _, entry in ipairs(batch) do collected[#collected + 1] = entry end
            if not decoded.result.nextPage then break end
        end

        for _, entry in ipairs(collected) do
            if usable(entry) then
                entry._score = score(entry)
                results[#results + 1] = entry
            end
        end
        table.sort(results, function(a, b) return a._score > b._score end)

        searching = false
        if #results == 0 then
            setStatus(("no usable script found for %s%s"):format(
                term, lastError and (" - " .. lastError) or
                      " (all results were patched, key-locked, or for other games)"))
            return
        end

        index = 1
        setStatus(("found %d candidate(s) for %s"):format(#results, term))
    end

    ------------------------------------------------------------------- run
    local function describe(entry)
        if not entry then return "-" end
        local gameName = entry.game and entry.game.name or "?"
        local gameId = tonumber(entry.game and entry.game.gameId or -1) or -1
        local placeId = ctx.GameInfo and ctx.GameInfo.PlaceId or 0
        return table.concat({
            ("%d/%d  %s"):format(index, #results, tostring(entry.title or "?")),
            ("game: %s%s"):format(gameName,
                (gameId == placeId and placeId ~= 0) and "  (exact PlaceId match)"
                    or "  (universal hub)"),
            ("views %s   likes %s   updated %s"):format(
                tostring(entry.views or "?"), tostring(entry.likeCount or 0),
                tostring(entry.lastBump or entry.createdAt or "?"):sub(1, 10)),
            ("verified %s   key system %s"):format(
                entry.verified and "yes" or "no", entry.key and "YES" or "no"),
        }, "\n")
    end

    local function refreshResultBox()
        if resultBox then
            pcall(function() resultBox:SetDesc(describe(results[index])) end)
        end
    end

    local function runCurrent()
        local entry = results[index]
        if not entry then
            setStatus("nothing to run - press Search first")
            return
        end
        if loadedIndex == index then
            ctx.Notify("that one is already running", 4, "Finder")
            return
        end

        setStatus(("running %s..."):format(tostring(entry.title or "?")))
        local chunk, compileError = loadstring(entry.script, "@" .. tostring(entry.title))
        if not chunk then
            setStatus("did not compile: " .. tostring(compileError)
                   .. "\nPress Next script to try the following one.")
            return
        end

        local ok, runError = pcall(chunk)
        if ok then
            loadedIndex = index
            setStatus(("running: %s\nloaded at %s\n\nIf it does not work, press Next script.")
                :format(tostring(entry.title or "?"), os.date("%H:%M:%S")))
            ctx.Notify("loaded " .. tostring(entry.title or "?"), 5, "Finder")
        else
            setStatus(("errored: %s\n\nPress Next script to try the following one.")
                :format(tostring(runError)))
            ctx.Notify("that script errored", 6, "Finder")
        end
    end

    local function step(delta)
        if #results == 0 then
            setStatus("no results - press Search first")
            return
        end
        index = index + delta
        if index < 1 then index = #results end
        if index > #results then index = 1 end
        refreshResultBox()
        setStatus(("selected %d of %d - press Load to run it"):format(index, #results))
    end

    --------------------------------------------------------------------- UI
    ctx.Tab:AddParagraph({
        Title   = "Script finder",
        Content = "Searches scriptblox for this exact game on join and runs the best "
               .. "result. Results tied to this PlaceId rank above universal hubs, "
               .. "patched and key-system scripts are filtered out.\n\n"
               .. "Auto load runs someone else's script as soon as you join. Turn it "
               .. "off if you would rather look at what it picked first.",
    })

    ctx.Tab:AddToggle("Find_Auto", {
        Title = "Auto load on join",
        Description = "Runs the top result automatically",
        Default = true,
    }):OnChanged(function(v) settings.autoLoad = v end)

    ctx.Tab:AddToggle("Find_Universal", {
        Title = "Allow universal hubs",
        Description = "Multi-game hubs, when nothing targets this game exactly",
        Default = true,
    }):OnChanged(function(v) settings.universalToo = v end)

    ctx.Tab:AddToggle("Find_Key", {
        Title = "Allow key-system scripts",
        Description = "Off by default - a key system cannot be automated",
        Default = false,
    }):OnChanged(function(v) settings.allowKey = v end)

    ctx.Tab:AddInput("Find_Query", {
        Title = "Search term",
        Default = "",
        Placeholder = "blank = this game's name",
    }):OnChanged(function(v) settings.query = tostring(v or "") end)

    ctx.Tab:AddButton({
        Title       = "Search",
        Description = "Re-runs the search for this game",
        Callback    = function()
            ctx.Spawn(function()
                search()
                refreshResultBox()
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Load selected",
        Description = "Runs the script shown below",
        Callback    = function() ctx.Spawn(runCurrent) end,
    })

    ctx.Tab:AddButton({
        Title       = "Next script",
        Description = "The one you have is broken? Step to the next candidate",
        Callback    = function()
            ctx.Spawn(function()
                step(1)
                runCurrent()
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Previous script",
        Callback    = function() ctx.Spawn(function() step(-1) end) end,
    })

    ctx.Tab:AddButton({
        Title       = "Copy this script",
        Callback    = function()
            local entry = results[index]
            if entry and setclipboard then
                setclipboard(entry.script)
                ctx.Notify("copied", 4, "Finder")
            else
                ctx.Notify("nothing selected, or no setclipboard", 5, "Finder")
            end
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Copy all results",
        Description = "Every candidate found, for picking through by hand",
        Callback    = function()
            if #results == 0 then
                ctx.Notify("no results yet", 4, "Finder")
                return
            end
            local lines = {}
            for i, entry in ipairs(results) do
                lines[#lines + 1] = ("%d. %s  [views %s, updated %s]\n%s")
                    :format(i, tostring(entry.title or "?"), tostring(entry.views or "?"),
                            tostring(entry.lastBump or ""):sub(1, 10), entry.script)
            end
            local text = table.concat(lines, "\n\n")
            if setclipboard then
                setclipboard(text)
                ctx.Notify(("copied %d scripts"):format(#results), 5, "Finder")
            end
        end,
    })

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "idle" })
    resultBox = ctx.Tab:AddParagraph({ Title = "Selected", Content = "-" })

    local OPTION_MAP = {
        Find_Auto = "autoLoad", Find_Universal = "universalToo",
        Find_Key = "allowKey", Find_Query = "query",
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
            task.wait(0.5)
        end
    end)

    ---------------------------------------------------------------- on join
    ctx.Spawn(function()
        task.wait(1)
        search()
        refreshResultBox()
        if settings.autoLoad and #results > 0 then
            runCurrent()
        end
    end)
end

return M
