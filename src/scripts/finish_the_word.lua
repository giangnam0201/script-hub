--[[
    Finish The Word - word solver / auto answer
    ===========================================
    Recovered from "finishtheword.lua.txt" (Luau VM obfuscator, two nested
    stages) and rewritten against the hub module contract.

    How the original talks to the game -- all of this is reproduced below:

      * it scans the garbage collector for the game's networking table, which
        is the one carrying `remoteFire` / `remoteConnect` / `fire` / `ping`,
        and drives the round with:
              net.fire("tryKeystroke", "A")   -- one letter at a time
              net.fire("tryAnswer")           -- submit
      * a turn is live when LocalPlayer:GetAttribute("IsTurn") is true;
        the question itself is another gc table carrying `QuestionLabel` and
        either `RequiredLetter` (a prefix to extend) or `Choices` (pick one)
      * words come from the game's own list: a gc string containing
        "whitelistedFtwWords", newline separated, `^[a-z]+$` only

    Deliberately NOT reproduced: the original also downloaded its UI library,
    a save manager and a version file from a third-party domain
    (ancestrychanged.com) and executed them with loadstring, and it ran an
    extra remote payload on some executors. The hub supplies the UI instead,
    so none of that remote code is fetched. See README.
]]

local M = {}

local KEYBOARD = {
    -- x = column, y = row, h = hand; used for the humanised typing delays
    q = { x = 0, y = 0, h = 1 }, w = { x = 1, y = 0, h = 1 }, e = { x = 2, y = 0, h = 1 },
    r = { x = 3, y = 0, h = 1 }, t = { x = 4, y = 0, h = 1 }, y = { x = 5, y = 0, h = 2 },
    u = { x = 6, y = 0, h = 2 }, i = { x = 7, y = 0, h = 2 }, o = { x = 8, y = 0, h = 2 },
    p = { x = 9, y = 0, h = 2 },
    a = { x = 0, y = 1, h = 1 }, s = { x = 1, y = 1, h = 1 }, d = { x = 2, y = 1, h = 1 },
    f = { x = 3, y = 1, h = 1 }, g = { x = 4, y = 1, h = 1 }, h = { x = 5, y = 1, h = 2 },
    j = { x = 6, y = 1, h = 2 }, k = { x = 7, y = 1, h = 2 }, l = { x = 8, y = 1, h = 2 },
    z = { x = 0, y = 2, h = 1 }, x = { x = 1, y = 2, h = 1 }, c = { x = 2, y = 2, h = 1 },
    v = { x = 3, y = 2, h = 1 }, b = { x = 4, y = 2, h = 1 }, n = { x = 5, y = 2, h = 2 },
    m = { x = 6, y = 2, h = 2 },
}

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer

    ------------------------------------------------------------------ state
    local settings = {
        autoAnswer   = false,
        autoChoose   = false,
        autoLearn    = true,
        humanType    = true,
        instant      = false,
        removeUsed   = true,
        showWhite    = true,
        endsWith     = "",
        suggestCount = 30,
        suggestSort  = "Shortest",
        answerDelay  = 0.8,
        typeDelay    = 0.12,
    }

    local words       = {}   -- [firstLetter] = { word, ... } sorted by length asc
    local known       = {}   -- [word] = true
    local rank        = {}   -- [word] = position in the source list ("most common")
    local used        = {}   -- [word] = true, cleared per round
    local blacklist   = {}
    local whitelist   = {}
    local wordCount   = 0
    local turnToken   = 0    -- bumped whenever the turn changes; cancels typing

    ------------------------------------------------------------- word store
    local function addWord(word)
        if known[word] then return end
        local bucket = words[word:sub(1, 1)]
        if not bucket then
            bucket = {}
            words[word:sub(1, 1)] = bucket
        end
        -- keep each bucket sorted by length, shortest first
        local pos = #bucket + 1
        for i, existing in ipairs(bucket) do
            if #existing > #word then
                pos = i
                break
            end
        end
        table.insert(bucket, pos, word)
        known[word] = true
        wordCount = wordCount + 1
    end

    -- `ranked` lists are in frequency order, so their line number doubles as
    -- the "most common" rank. Alphabetical lists must not set it.
    local function ingest(text, ranked)
        local added = 0
        local index = 0
        for line in tostring(text):gmatch("[^\r\n]+") do
            index = index + 1
            line = line:lower():match("^%s*(%a+)%s*$") or ""
            if #line > 0 then
                if ranked and rank[line] == nil then rank[line] = index end
                if not known[line] then
                    addWord(line)
                    added = added + 1
                end
            end
        end
        return added
    end

    -- The game keeps its own dictionary in memory; find it the way the
    -- original did, by looking for a string that mentions whitelistedFtwWords.
    local function loadGameWords()
        if not getgc then return 0 end
        local added = 0
        for _, object in ipairs(getgc(true)) do
            if type(object) == "string" and object:find("whitelistedFtwWords", 1, true) then
                added = added + ingest(object)
            end
        end
        return added
    end

    ------------------------------------------------------- online dictionary
    -- Fetched when the game's own list cannot be found in memory. The first
    -- list is frequency ordered, so it also supplies the "Most common" ranking.
    local WORD_SOURCES = {
        { name = "common 10k",
          ranked = true,
          url = "https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-usa.txt" },
        { name = "popular 25k",
          url = "https://raw.githubusercontent.com/dolph/dictionary/master/popular.txt" },
    }

    local FULL_DICTIONARY = {
        name = "full dictionary (~4MB)",
        url = "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt",
    }

    local function httpGet(url)
        -- `request` keeps a status code, so try it first; HttpGet is the fallback
        local requester = (syn and syn.request) or http_request or request
        if requester then
            local ok, response = pcall(requester, { Url = url, Method = "GET" })
            if ok and type(response) == "table" and response.Body
                and (response.StatusCode == 200 or response.StatusCode == nil) then
                return response.Body
            end
        end
        local ok, body = pcall(function() return game:HttpGet(url) end)
        if ok and type(body) == "string" and #body > 0 then return body end
        return nil
    end

    local function downloadList(source)
        local body = httpGet(source.url)
        if not body then
            ctx.Notify("could not download " .. source.name, 5, "Finish The Word")
            return 0
        end
        return ingest(body, source.ranked)
    end

    local function downloadDictionary(includeFull)
        local added = 0
        for _, source in ipairs(WORD_SOURCES) do
            added = added + downloadList(source)
        end
        if includeFull then
            added = added + downloadList(FULL_DICTIONARY)
        end
        return added
    end

    ------------------------------------------------------------ game lookup
    local network
    local function findNetwork()
        if network then return network end
        if not getgc then return nil end
        for _, object in ipairs(getgc(true)) do
            if type(object) == "table"
                and rawget(object, "remoteFire") and rawget(object, "remoteConnect")
                and rawget(object, "fire") and rawget(object, "ping") then
                network = object
                return network
            end
        end
        return nil
    end

    local function findQuestion()
        if not getgc then return nil end
        for _, object in ipairs(getgc(true)) do
            if type(object) == "table" and rawget(object, "QuestionLabel")
                and (rawget(object, "RequiredLetter") or rawget(object, "Choices")) then
                return object
            end
        end
        return nil
    end

    -- Some builds of the game do not set this attribute at all; when it is
    -- absent we fall back to "a prompt is on screen" as the trigger.
    local turnAttributeMissing = false

    local function isMyTurn()
        local ok, value = pcall(function()
            return LocalPlayer:GetAttribute("IsTurn")
        end)
        if not ok or value == nil then
            turnAttributeMissing = true
            return false
        end
        turnAttributeMissing = false
        return value == true
    end

    ------------------------------------------------------------- searching
    local function candidates(prefix, limit, includeUsed, includeBlacklisted)
        local out = {}
        local bucket = words[prefix:sub(1, 1)]
        if not bucket then return out end
        for _, word in ipairs(bucket) do
            if #word >= #prefix and word:sub(1, #prefix) == prefix
                and (includeBlacklisted or not blacklist[word])
                and (includeUsed or not used[word]) then
                out[#out + 1] = word
                if limit and #out >= limit then break end
            end
        end
        return out
    end

    local function comparator()
        local mode = settings.suggestSort
        if mode == "Shortest" then
            return function(a, b)
                if #a ~= #b then return #a < #b end
                return a < b
            end
        elseif mode == "Longest" then
            return function(a, b)
                if #a ~= #b then return #a > #b end
                return a < b
            end
        elseif mode == "a-Z" then
            return function(a, b) return a < b end
        elseif mode == "Z-a" then
            return function(a, b) return a > b end
        elseif mode == "Most common" then
            return function(a, b)
                local ra, rb = rank[a] or math.huge, rank[b] or math.huge
                if ra ~= rb then return ra < rb end
                return a < b
            end
        end
        return nil
    end

    -- returns { { word = "...", check = true|nil }, ... }
    local function suggestions(prefix, includeUsed, includeBlacklisted)
        local list = candidates(prefix, nil, includeUsed, includeBlacklisted)

        local suffix = settings.endsWith:lower()
        if #suffix > 0 then
            local filtered = {}
            for _, word in ipairs(list) do
                if #word >= #suffix and word:sub(-#suffix) == suffix then
                    filtered[#filtered + 1] = word
                end
            end
            list = filtered
        end

        local cmp = comparator()
        local out = {}
        if settings.showWhite then
            local white, rest = {}, {}
            for _, word in ipairs(list) do
                if whitelist[word] then white[#white + 1] = word else rest[#rest + 1] = word end
            end
            if cmp then
                table.sort(white, cmp)
                table.sort(rest, cmp)
            end
            for _, word in ipairs(white) do out[#out + 1] = { word = word, check = true } end
            for _, word in ipairs(rest) do out[#out + 1] = { word = word } end
        else
            if cmp then table.sort(list, cmp) end
            for _, word in ipairs(list) do out[#out + 1] = { word = word } end
        end
        return out
    end

    local function bestWord(prefix)
        local list = suggestions(prefix, false, false)
        if #list == 0 and #settings.endsWith > 0 then
            -- the suffix filter starved the search: drop it and retry, as the
            -- original does
            settings.endsWith = ""
            list = suggestions(prefix, false, false)
        end
        return list[1] and list[1].word or nil
    end

    ------------------------------------------------------- humanised typing
    -- Per-key delays weighted by keyboard travel, normalised so the whole word
    -- takes about (#keys * TypeDelay) seconds.
    local function typingDelays(word, from)
        local weights, total = {}, 0
        local previous = word:sub(from - 1, from - 1)

        for i = from, #word do
            local char = word:sub(i, i)
            local weight = 1.2
            local a, b = KEYBOARD[char], KEYBOARD[previous]
            if a and b then
                if char == previous then
                    weight = 0.2
                elseif a.h ~= b.h then
                    weight = 0.5
                else
                    weight = 0.8 + math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) * 0.3
                end
            end
            weight = weight * math.random(90, 110) / 100
            weights[#weights + 1] = weight
            total = total + weight
            previous = char
        end

        local target = #weights * settings.typeDelay
        if #weights < 6 then
            target = math.clamp(target, 0.1, 0.7)
        else
            target = math.clamp(target, 0.28, 2.5)
        end
        for i, weight in ipairs(weights) do
            weights[i] = weight / total * target
        end
        return weights
    end

    ----------------------------------------------------------------- answer
    local currentPrefix = ""

    local function answerWith(word, prefix)
        local net = findNetwork()
        if not net then
            ctx.Notify("Could not find the game's network module", 6, "Finish The Word")
            return
        end

        turnToken = turnToken + 1
        local token = turnToken
        used[word] = true

        local delays
        if settings.humanType and not settings.instant then
            delays = typingDelays(word, #prefix + 1)
        end

        for i = #prefix + 1, #word do
            if token ~= turnToken or not ctx.IsAlive() then return end
            net.fire("tryKeystroke", word:sub(i, i):upper())
            if not settings.instant then
                task.wait(delays and delays[i - #prefix] or settings.typeDelay)
            end
        end

        if token ~= turnToken or not ctx.IsAlive() then return end
        if not settings.instant then
            task.wait(settings.answerDelay)
        end
        if token ~= turnToken or not ctx.IsAlive() then return end

        net.fire("tryAnswer")
        if settings.autoLearn then addWord(word) end
    end

    ------------------------------------------------------------ suggestions UI
    local suggestionBox
    local statusBox

    -- Read the toggles/sliders straight off the UI every tick. Relying only on
    -- OnChanged misses values restored by a saved config or set with SetValue,
    -- which is the usual reason "auto answer" looks switched on but does nothing.
    local OPTION_MAP = {
        FTW_AutoAnswer      = "autoAnswer",
        FTW_AutoChoose      = "autoChoose",
        FTW_InstantAnswer   = "instant",
        FTW_HumanType       = "humanType",
        FTW_AutoLearn       = "autoLearn",
        FTW_RemoveUsed      = "removeUsed",
        FTW_ShowWhitelisted = "showWhite",
        FTW_AnswerDelay     = "answerDelay",
        FTW_TypeDelay       = "typeDelay",
        FTW_SuggestCount    = "suggestCount",
        FTW_SuggestSort     = "suggestSort",
        FTW_EndsWith        = "endsWith",
        FTW_WordEntry       = "wordEntry",
    }

    local function syncOptions()
        local options = ctx.Options
        if not options then return end
        for id, key in pairs(OPTION_MAP) do
            local option = options[id]
            if option ~= nil then
                local ok, value = pcall(function() return option.Value end)
                if ok and value ~= nil then
                    if key == "endsWith" or key == "wordEntry" or key == "suggestSort" then
                        settings[key] = tostring(value)
                    else
                        settings[key] = value
                    end
                end
            end
        end
    end

    local function updateStatus(question, turn)
        if not statusBox then return end
        local net = findNetwork()
        local prompt = "-"
        if question then
            prompt = question.Choices and "choices" or tostring(question.RequiredLetter)
        end
        pcall(function()
            statusBox:SetDesc(("words: %d   network: %s   prompt: %s   IsTurn: %s%s")
                :format(wordCount,
                        net and "found" or "NOT FOUND",
                        prompt,
                        turn and "true" or "false",
                        turnAttributeMissing and " (attribute missing - answering on prompt)" or ""))
        end)
    end

    local function showSuggestions(lines)
        if not suggestionBox then return end
        pcall(function()
            suggestionBox:SetDesc(#lines > 0 and table.concat(lines, "\n") or "-")
        end)
    end

    local function refresh(question)
        if wordCount == 0 then
            showSuggestions({ "words still downloading..." })
            return
        end

        if question.Choices then
            local lines = {}
            for _, choice in ipairs(question.Choices) do
                local letter = tostring(choice):lower()
                lines[#lines + 1] = ("%s: %d words"):format(tostring(choice):upper(),
                    #candidates(letter, nil, true, false))
            end
            showSuggestions(lines)
            return
        end

        if not question.RequiredLetter then return end
        local prefix = tostring(question.RequiredLetter):lower()
        currentPrefix = prefix

        local list = suggestions(prefix, not settings.removeUsed, false)
        local lines = {}
        for _, entry in ipairs(list) do
            if #lines >= settings.suggestCount then break end
            lines[#lines + 1] = (entry.check and "* " or "") .. entry.word
        end

        if #lines > 0 then
            showSuggestions(lines)
        elseif #settings.endsWith > 0 then
            showSuggestions({ ('no words ending in "%s"'):format(settings.endsWith:lower()) })
        else
            showSuggestions({ ('no words for "%s"'):format(prefix) })
        end
    end

    ------------------------------------------------------------------ turn
    local answering = false
    local answeredPrompt = nil   -- the prompt we already acted on

    local function handleTurn(question)
        if question.Choices then
            if not settings.autoChoose then return end
            -- pick the choice letter with the most available words
            local best, bestCount = nil, -1
            for _, choice in ipairs(question.Choices) do
                local letter = tostring(choice):lower()
                local count = #candidates(letter, nil, true, false)
                if count > bestCount then
                    best, bestCount = choice, count
                end
            end
            if best then
                local net = findNetwork()
                if net then net.fire("tryKeystroke", tostring(best):upper()) end
            end
            return
        end

        if not settings.autoAnswer then return end
        if not question.RequiredLetter then return end

        local prefix = tostring(question.RequiredLetter):lower()
        local word = bestWord(prefix)
        if not word then
            ctx.Notify(('no words left for "%s"'):format(prefix), 4, "Finish The Word")
            return
        end
        answerWith(word, prefix)
    end

    -- One prompt = one answer. The turn attribute is not reliable on its own
    -- (it can flip after the prompt appears, or not exist at all on some
    -- versions), so the prompt text itself is what gates a new answer.
    local function promptKey(question)
        if question.Choices then
            local parts = {}
            for _, choice in ipairs(question.Choices) do parts[#parts + 1] = tostring(choice) end
            return "choices:" .. table.concat(parts, ",")
        end
        return "prefix:" .. tostring(question.RequiredLetter)
    end

    ------------------------------------------------------------------- UI
    ctx.Tab:AddParagraph({
        Title   = "Finish The Word",
        Content = "Reads the game's own word list out of memory and finishes the prompt. "
               .. "Auto answer types the word key by key, so Typing delay / Humanized "
               .. "typing decide how fast it looks.",
    })

    ctx.Tab:AddToggle("FTW_AutoAnswer", { Title = "Auto answer", Default = false })
        :OnChanged(function(value) settings.autoAnswer = value end)

    ctx.Tab:AddToggle("FTW_AutoChoose", { Title = "Auto pick choice letter", Default = false })
        :OnChanged(function(value) settings.autoChoose = value end)

    ctx.Tab:AddToggle("FTW_InstantAnswer", { Title = "Instant (no typing delays)", Default = false })
        :OnChanged(function(value) settings.instant = value end)

    ctx.Tab:AddToggle("FTW_HumanType", { Title = "Humanized typing", Default = true })
        :OnChanged(function(value) settings.humanType = value end)

    ctx.Tab:AddToggle("FTW_AutoLearn", { Title = "Auto-learn words", Default = true })
        :OnChanged(function(value) settings.autoLearn = value end)

    ctx.Tab:AddSlider("FTW_AnswerDelay", {
        Title = "Delay before submitting", Default = 0.8, Min = 0, Max = 5, Rounding = 1,
    }):OnChanged(function(value) settings.answerDelay = value end)

    ctx.Tab:AddSlider("FTW_TypeDelay", {
        Title = "Typing delay", Default = 0.12, Min = 0.05, Max = 0.5, Rounding = 2,
    }):OnChanged(function(value) settings.typeDelay = value end)

    ctx.Tab:AddToggle("FTW_RemoveUsed", { Title = "Remove used words", Default = true })
        :OnChanged(function(value) settings.removeUsed = value end)

    ctx.Tab:AddToggle("FTW_ShowWhitelisted", { Title = "Show whitelisted words", Default = true })
        :OnChanged(function(value) settings.showWhite = value end)

    ctx.Tab:AddSlider("FTW_SuggestCount", {
        Title = "Suggestion count", Default = 30, Min = 1, Max = 100, Rounding = 0,
    }):OnChanged(function(value) settings.suggestCount = value end)

    ctx.Tab:AddDropdown("FTW_SuggestSort", {
        Title = "Sort suggestions",
        Values = { "Shortest", "Longest", "a-Z", "Z-a", "Most common" },
        Default = 1,
    }):OnChanged(function(value) settings.suggestSort = tostring(value) end)

    ctx.Tab:AddInput("FTW_EndsWith", {
        Title = "Word ends with", Default = "", Placeholder = "suffix",
    }):OnChanged(function(value) settings.endsWith = tostring(value or "") end)

    ctx.Tab:AddInput("FTW_WordEntry", {
        Title = "Word", Default = "", Placeholder = "type a word",
    }):OnChanged(function(value) settings.wordEntry = tostring(value or ""):lower() end)

    local function entry()
        local word = tostring(settings.wordEntry or ""):lower():match("^[a-z]+$")
        if not word then
            ctx.Notify("Type a word (a-z only) in the Word box first", 4, "Finish The Word")
        end
        return word
    end

    ctx.Tab:AddButton({
        Title = "Add to whitelist",
        Callback = function()
            local word = entry()
            if word then
                whitelist[word] = true
                addWord(word)
                ctx.Notify("whitelisted " .. word, 3, "Finish The Word")
            end
        end,
    })

    ctx.Tab:AddButton({
        Title = "Remove from whitelist",
        Callback = function()
            local word = entry()
            if word then
                whitelist[word] = nil
                ctx.Notify("un-whitelisted " .. word, 3, "Finish The Word")
            end
        end,
    })

    ctx.Tab:AddButton({
        Title = "Add to blacklist",
        Callback = function()
            local word = entry()
            if word then
                blacklist[word] = true
                ctx.Notify("blacklisted " .. word, 3, "Finish The Word")
            end
        end,
    })

    ctx.Tab:AddButton({
        Title = "Remove from blacklist",
        Callback = function()
            local word = entry()
            if word then
                blacklist[word] = nil
                ctx.Notify("un-blacklisted " .. word, 3, "Finish The Word")
            end
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Answer now",
        Description = "Solve the current prompt once, ignoring Auto answer",
        Callback    = function()
            ctx.Spawn(function()
                local question = findQuestion()
                if not question or not question.RequiredLetter then
                    ctx.Notify("No prompt on screen right now", 4, "Finish The Word")
                    return
                end
                local prefix = tostring(question.RequiredLetter):lower()
                local word = bestWord(prefix)
                if not word then
                    ctx.Notify(('no words left for "%s"'):format(prefix), 4, "Finish The Word")
                    return
                end
                answerWith(word, prefix)
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Reload word list",
        Description = "Re-read the game's dictionary out of memory",
        Callback    = function()
            local added = loadGameWords()
            ctx.Notify(("loaded %d words (%d total)"):format(added, wordCount), 4, "Finish The Word")
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Download dictionary",
        Description = "~35k words incl. a frequency list (for 'Most common')",
        Callback    = function()
            ctx.Spawn(function()
                ctx.Notify("downloading word lists...", 3, "Finish The Word")
                local added = downloadDictionary(false)
                ctx.Notify(("downloaded %d words (%d total)"):format(added, wordCount), 5,
                    "Finish The Word")
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Download full dictionary",
        Description = "~370k words, a few MB - slower, much better coverage",
        Callback    = function()
            ctx.Spawn(function()
                ctx.Notify("downloading full dictionary, this takes a moment...", 5,
                    "Finish The Word")
                local added = downloadDictionary(true)
                ctx.Notify(("downloaded %d words (%d total)"):format(added, wordCount), 5,
                    "Finish The Word")
            end)
        end,
    })

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "-" })
    suggestionBox = ctx.Tab:AddParagraph({ Title = "Suggestions", Content = "-" })

    ------------------------------------------------------------------ run
    if not getgc then
        ctx.Tab:AddParagraph({
            Title   = "Executor too limited",
            Content = "This script needs getgc to read the game's word list and network module.",
        })
        return
    end

    ctx.Spawn(function()
        local added = loadGameWords()
        if added > 0 then
            ctx.Notify(("loaded %d words from the game"):format(added), 5, "Finish The Word")
        else
            -- nothing in memory (round not started, or a build that keeps the
            -- list server-side): fall back to the online lists
            ctx.Notify("no word list in memory - downloading one...", 4, "Finish The Word")
            added = downloadDictionary(false)
            ctx.Notify(added > 0 and ("downloaded %d words"):format(added)
                or "could not load any word list - check your executor's HTTP support",
                5, "Finish The Word")
        end
    end)

    -- Main loop: watch for a prompt, answer it once, keep the panel current.
    ctx.Spawn(function()
        local wasTurn = false

        while ctx.IsAlive() do
            syncOptions()

            local turn = isMyTurn()
            if turn ~= wasTurn then
                if turn then used = {} end   -- new turn: used words reset
                answeredPrompt = nil
                wasTurn = turn
            end

            local question = findQuestion()
            if question then
                pcall(refresh, question)

                local key = promptKey(question)
                if key ~= answeredPrompt and not answering
                    and (turn or turnAttributeMissing) then
                    answeredPrompt = key
                    answering = true
                    local ok, err = pcall(handleTurn, question)
                    answering = false
                    if not ok then
                        ctx.Notify("error: " .. tostring(err), 6, "Finish The Word")
                    end
                end
            end

            updateStatus(question, turn)
            task.wait(0.2)
        end
    end)
end

return M
