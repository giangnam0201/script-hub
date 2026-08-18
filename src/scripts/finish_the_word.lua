--[[
    Finish The Word! - word solver / auto answer
    ============================================
    Written against two live crawls of PlaceId 91704854174760: a lobby dump of
    the instance tree, and a watch log of two real rounds. What those proved:

      * Your turn is `LocalPlayer:GetAttribute("IsTurn")`, flipping per turn.
      * The round is STARTS-WITH, not contains. The match HUD literally reads
        "Type a word starting with...". The first build defaulted to Contains,
        so it answered with words that merely contained the fragment and the
        game rejected every one of them.
      * The fragment itself is on your table: the BillboardGui "MatchDisplay"
        under the Table model, its "Category" TextLabel - "CE", "IT", "ME",
        "N", "W". Category also shows "Animals" or "Choose a letter" in the
        phases that are not a letter prompt.
      * The match HUD lives at PlayerGui.ScreenGui and is created when the
        round starts, which is why it was absent from the lobby crawl:
            ScreenGui.TopBar.Question.QuestionLabel     phase text
            ScreenGui.TopBar.AnswerInput.Keys.<n>       letters on screen
            ScreenGui.ChoiceList.<n>.Key                letters to choose from
            ScreenGui.BottomBar.CenterBar.Timer.Timer   countdown
      * AnswerInput.Keys mirrors whoever's turn it is, not only yours, so it is
        only read as "what I have typed" while IsTurn is true.
      * Answering is real keyboard input, so keystrokes go out through
        VirtualInputManager. (The original script pulled VirtualInputManager
        and VirtualUser for exactly this.)
      * getgc exposes nothing on this game/executor - no game tables, no word
        list - so the dictionary is downloaded.

    Table lookup no longer depends on Humanoid.SeatPart alone. The seats carry
    a "ChairWeld", so the game may weld you rather than use Roblox seating, in
    which case SeatPart is nil; the nearest active table is used as a fallback.
]]

local M = {}

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer

    ------------------------------------------------------------------ state
    local settings = {
        autoAnswer   = false,
        matchMode    = "Auto",
        pickLetter   = true,
        pickShortest = true,
        typeDelay    = 0.06,
        answerDelay  = 0.4,
        suggestCount = 15,
    }

    local words, known, rank = {}, {}, {}
    local used = {}
    local wordCount = 0
    local answeredPrompt = nil
    local pickedFor = nil
    local answering = false
    local lastMode = "Starts with"   -- what Auto resolved to most recently

    local statusBox, suggestionBox

    ------------------------------------------------------------- dictionary
    local WORD_SOURCES = {
        { name = "common 10k", ranked = true,
          url = "https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-usa.txt" },
        { name = "popular 25k",
          url = "https://raw.githubusercontent.com/dolph/dictionary/master/popular.txt" },
    }
    local FULL_DICTIONARY = { name = "full dictionary",
        url = "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt" }

    local function addWord(word)
        if known[word] then return end
        known[word] = true
        words[#words + 1] = word
        wordCount = wordCount + 1
    end

    local function ingest(text, ranked)
        local added, index = 0, 0
        for line in tostring(text):gmatch("[^\r\n]+") do
            index = index + 1
            local word = line:lower():match("^%s*(%a+)%s*$")
            if word then
                if ranked and rank[word] == nil then rank[word] = index end
                if not known[word] then
                    addWord(word)
                    added = added + 1
                end
            end
        end
        return added
    end

    local function httpGet(url)
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

    local function downloadDictionary(includeFull)
        local added = 0
        for _, source in ipairs(WORD_SOURCES) do
            local body = httpGet(source.url)
            if body then
                added = added + ingest(body, source.ranked)
            else
                ctx.Notify("could not download " .. source.name, 5, "Finish The Word")
            end
        end
        if includeFull then
            local body = httpGet(FULL_DICTIONARY.url)
            if body then added = added + ingest(body) end
        end
        return added
    end

    ---------------------------------------------------------------- helpers
    local function trim(text)
        return (tostring(text):match("^%s*(.-)%s*$"))
    end

    local function isMyTurn()
        local ok, value = pcall(function()
            return LocalPlayer:GetAttribute("IsTurn")
        end)
        return ok and value == true
    end

    -- Collect the letters out of a Keys/ChoiceList container, in slot order.
    -- Each slot is a numbered Frame holding a TextLabel somewhere below it.
    local function lettersIn(container)
        if not container then return {} end
        local slots = {}
        for _, child in ipairs(container:GetChildren()) do
            local index = tonumber(child.Name)
            if index then
                local label = child:FindFirstChildWhichIsA("TextLabel", true)
                slots[index] = label and trim(label.Text) or ""
            end
        end
        local out = {}
        for i = 1, #slots do out[i] = slots[i] or "" end
        return out
    end

    -------------------------------------------------------------- match HUD
    -- Created when a round starts; absent in the lobby.
    local function matchGui()
        local gui = LocalPlayer:FindFirstChild("PlayerGui")
        return gui and gui:FindFirstChild("ScreenGui") or nil
    end

    local function questionText()
        local gui = matchGui()
        local topBar = gui and gui:FindFirstChild("TopBar")
        local question = topBar and topBar:FindFirstChild("Question")
        local label = question and question:FindFirstChild("QuestionLabel")
        return label and trim(label.Text) or nil
    end

    -- Letters showing in the answer box. Shared across players, so this is
    -- only ours while IsTurn is true.
    local function typedSoFar()
        local gui = matchGui()
        local topBar = gui and gui:FindFirstChild("TopBar")
        local input = topBar and topBar:FindFirstChild("AnswerInput")
        local keys = input and input:FindFirstChild("Keys")
        return table.concat(lettersIn(keys)):lower()
    end

    -- The letters offered during the "pick a letter" phase.
    local function letterChoices()
        local gui = matchGui()
        local list = gui and gui:FindFirstChild("ChoiceList")
        local out = {}
        for _, letter in ipairs(lettersIn(list)) do
            if letter:match("^%a$") then out[#out + 1] = letter:lower() end
        end
        return out
    end

    -- "<name>, pick a letter" only names one player - us or someone else.
    local function myLetterPick()
        local text = questionText()
        if not text or not text:lower():find("pick a letter", 1, true) then return false end
        return text:sub(1, #LocalPlayer.Name) == LocalPlayer.Name
    end

    -------------------------------------------------------------- the table
    local function tableFromModel(model)
        local display = model:FindFirstChild("Table")
        display = display and display:FindFirstChild("MatchDisplay")
        return display
    end

    -- Seat first; the seats carry a ChairWeld, so if the game welds you
    -- instead of seating you, fall back to the nearest active table.
    local function myMatchDisplay()
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local seat = humanoid and humanoid.SeatPart

        if seat then
            local node = seat
            while node and node ~= workspace do
                local display = node:FindFirstChild("Table")
                if display and display:FindFirstChild("MatchDisplay") then
                    return display:FindFirstChild("MatchDisplay"), "seat"
                end
                node = node.Parent
            end
        end

        local root = character and character:FindFirstChild("HumanoidRootPart")
        local meta = workspace:FindFirstChild("Meta")
        local tables = meta and meta:FindFirstChild("Tables")
        if not tables then return nil, "no tables" end

        local best, bestDistance, anyActive
        for _, model in ipairs(tables:GetChildren()) do
            local display = tableFromModel(model)
            if display and display:GetAttribute("Active") == true then
                anyActive = anyActive or display
                local top = model:FindFirstChild("Table")
                top = top and top:FindFirstChild("Top")
                if root and top then
                    local distance = (top.Position - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best, bestDistance = display, distance
                    end
                end
            end
        end

        if best and bestDistance and bestDistance < 60 then
            return best, ("nearest (%.0f studs)"):format(bestDistance)
        end
        if anyActive then return anyActive, "any active table" end
        return nil, "none active"
    end

    local function promptText()
        local display = select(1, myMatchDisplay())
        local category = display and display:FindFirstChild("Category")
        return category and trim(category.Text) or nil
    end

    -- "CE" is a fragment to solve. "Animals" / "Choose a letter" are not.
    local function fragmentFrom(text)
        if not text then return nil end
        local cleaned = text:lower()
        if #cleaned == 0 or #cleaned > 4 then return nil end
        if not cleaned:match("^%a+$") then return nil end
        return cleaned
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

    local function pressKey(keyCode)
        if not virtualInput then return false end
        local ok = pcall(function()
            virtualInput:SendKeyEvent(true, keyCode, false, game)
        end)
        task.wait(0.01)
        pcall(function()
            virtualInput:SendKeyEvent(false, keyCode, false, game)
        end)
        return ok
    end

    local function pressLetter(letter)
        local keyCode = Enum.KeyCode[letter:upper()]
        if keyCode then return pressKey(keyCode) end
        return false
    end

    local function typeWord(word)
        local onScreen = typedSoFar()
        local start = 1

        if #onScreen > 0 then
            if word:sub(1, #onScreen) == onScreen then
                start = #onScreen + 1        -- continue from what is there
            else
                for _ = 1, #onScreen do      -- wrong letters, clear them
                    pressKey(Enum.KeyCode.Backspace)
                    task.wait(0.02)
                end
            end
        end

        for i = start, #word do
            if not ctx.IsAlive() or not isMyTurn() then return false end
            pressLetter(word:sub(i, i))
            task.wait(settings.typeDelay)
        end

        task.wait(settings.answerDelay)
        if not ctx.IsAlive() or not isMyTurn() then return false end
        pressKey(Enum.KeyCode.Return)
        return true
    end

    ------------------------------------------------------------- word search
    -- Auto reads the phase text: the game says "Type a word starting with..."
    -- for a prefix round, and would say "containing" for a substring round.
    local function activeMode()
        if settings.matchMode ~= "Auto" then return settings.matchMode end
        local text = questionText()
        if text then
            local lower = text:lower()
            if lower:find("start", 1, true) then lastMode = "Starts with"
            elseif lower:find("contain", 1, true) or lower:find("with the letters", 1, true) then
                lastMode = "Contains"
            elseif lower:find("end", 1, true) then lastMode = "Ends with" end
        end
        return lastMode
    end

    local function matches(word, fragment, mode)
        if mode == "Contains" then
            return word:find(fragment, 1, true) ~= nil
        elseif mode == "Ends with" then
            return word:sub(-#fragment) == fragment
        end
        return word:sub(1, #fragment) == fragment
    end

    local function candidates(fragment, limit)
        local mode = activeMode()
        local out = {}
        for _, word in ipairs(words) do
            if not used[word] and matches(word, fragment, mode) then
                out[#out + 1] = word
                if limit and #out >= limit * 8 then break end
            end
        end

        table.sort(out, function(a, b)
            if settings.pickShortest then
                if #a ~= #b then return #a < #b end
            else
                local ra, rb = rank[a] or math.huge, rank[b] or math.huge
                if ra ~= rb then return ra < rb end
            end
            return a < b
        end)

        if limit and #out > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = out[i] end
            return trimmed
        end
        return out
    end

    -- How many words a given starting letter still has available; used to
    -- choose the safest letter during the pick phase.
    local function letterScore(letter)
        local count = 0
        for _, word in ipairs(words) do
            if not used[word] and word:sub(1, 1) == letter then count = count + 1 end
        end
        return count
    end

    ------------------------------------------------------------------- solve
    local function solve(fragment)
        local list = candidates(fragment, 1)
        local word = list[1]
        if not word then
            ctx.Notify(('no word %s "%s"'):format(activeMode():lower(), fragment), 4, "Finish The Word")
            return
        end

        used[word] = true
        if typeWord(word) then
            ctx.Notify("answered: " .. word, 3, "Finish The Word")
        end
    end

    local function chooseLetter()
        local choices = letterChoices()
        if #choices == 0 then return end

        local best, bestScore
        for _, letter in ipairs(choices) do
            local score = letterScore(letter)
            if not bestScore or score > bestScore then best, bestScore = letter, score end
        end
        if not best then return end

        pressLetter(best)
        ctx.Notify(("picked letter %s (%d words)"):format(best:upper(), bestScore or 0),
            3, "Finish The Word")
    end

    ------------------------------------------------------------------- UI
    local function refresh(fragment)
        if not suggestionBox then return end
        local lines
        if not fragment then
            lines = { "-" }
        elseif wordCount == 0 then
            lines = { "no dictionary loaded" }
        else
            lines = candidates(fragment, settings.suggestCount)
            if #lines == 0 then
                lines = { ('no word %s "%s"'):format(activeMode():lower(), fragment) }
            end
        end
        pcall(function() suggestionBox:SetDesc(table.concat(lines, "\n")) end)
    end

    local function updateStatus(source, prompt, fragment, turn)
        if not statusBox then return end
        pcall(function()
            statusBox:SetDesc(table.concat({
                ("words %d   typing %s   mode %s"):format(wordCount,
                    virtualInput and "ready" or "NO VirtualInputManager", activeMode()),
                ("table: %s"):format(source or "not found"),
                ("prompt: %s%s"):format(prompt or "none",
                    (prompt and not fragment) and "  (not a letter prompt)" or ""),
                ("IsTurn %s   typed \"%s\""):format(turn and "true" or "false", typedSoFar()),
                ("phase: %s"):format(questionText() or "no match HUD"),
            }, "\n"))
        end)
    end

    ctx.Tab:AddParagraph({
        Title   = "Finish The Word!",
        Content = "Reads the fragment off your table and types an answer with real "
               .. "keystrokes. Sit at a table, turn Auto answer on, and keep the Roblox "
               .. "window focused - keystrokes go nowhere if it is not.",
    })

    ctx.Tab:AddToggle("FTW_AutoAnswer", { Title = "Auto answer", Default = false })
        :OnChanged(function(value) settings.autoAnswer = value end)

    ctx.Tab:AddToggle("FTW_PickLetter", {
        Title = "Auto pick a letter",
        Description = "Chooses the offered letter with the most words behind it",
        Default = true,
    }):OnChanged(function(value) settings.pickLetter = value end)

    ctx.Tab:AddDropdown("FTW_MatchMode", {
        Title = "Match mode",
        Description = "Auto follows the round's own wording",
        Values = { "Auto", "Starts with", "Contains", "Ends with" }, Default = 1,
    }):OnChanged(function(value) settings.matchMode = tostring(value) end)

    ctx.Tab:AddToggle("FTW_Shortest", {
        Title = "Prefer shortest word",
        Description = "Off = prefer the most common word instead",
        Default = true,
    }):OnChanged(function(value) settings.pickShortest = value end)

    ctx.Tab:AddSlider("FTW_TypeDelay", {
        Title = "Typing delay", Default = 0.06, Min = 0.01, Max = 0.4, Rounding = 2,
    }):OnChanged(function(value) settings.typeDelay = value end)

    ctx.Tab:AddSlider("FTW_AnswerDelay", {
        Title = "Delay before submitting", Default = 0.4, Min = 0, Max = 3, Rounding = 1,
    }):OnChanged(function(value) settings.answerDelay = value end)

    ctx.Tab:AddSlider("FTW_SuggestCount", {
        Title = "Suggestion count", Default = 15, Min = 1, Max = 50, Rounding = 0,
    }):OnChanged(function(value) settings.suggestCount = value end)

    ctx.Tab:AddButton({
        Title       = "Answer now",
        Description = "Solve the current prompt once, ignoring Auto answer",
        Callback    = function()
            ctx.Spawn(function()
                local fragment = fragmentFrom(promptText())
                if not fragment then
                    ctx.Notify("no letter prompt on your table right now", 4, "Finish The Word")
                    return
                end
                solve(fragment)
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Test a keystroke",
        Description = "Sends the letter A - if nothing appears, typing is being blocked",
        Callback    = function()
            ctx.Spawn(function()
                pressLetter("a")
                task.wait(0.3)
                ctx.Notify(('answer box now reads "%s"'):format(typedSoFar()), 5, "Finish The Word")
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Download full dictionary",
        Description = "~370k words - better coverage, slower",
        Callback    = function()
            ctx.Spawn(function()
                ctx.Notify("downloading...", 4, "Finish The Word")
                local added = downloadDictionary(true)
                ctx.Notify(("+%d words (%d total)"):format(added, wordCount), 5, "Finish The Word")
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Clear used words",
        Description = "Words already answered this session become available again",
        Callback    = function()
            used = {}
            ctx.Notify("used list cleared", 3, "Finish The Word")
        end,
    })

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "-" })
    suggestionBox = ctx.Tab:AddParagraph({ Title = "Suggestions", Content = "-" })

    -- Read the controls off the UI every tick. OnChanged alone misses values
    -- restored from a saved config or set with SetValue.
    local OPTION_MAP = {
        FTW_AutoAnswer   = "autoAnswer",
        FTW_PickLetter   = "pickLetter",
        FTW_MatchMode    = "matchMode",
        FTW_Shortest     = "pickShortest",
        FTW_TypeDelay    = "typeDelay",
        FTW_AnswerDelay  = "answerDelay",
        FTW_SuggestCount = "suggestCount",
    }

    local function syncOptions()
        local options = ctx.Options
        if not options then return end
        for id, key in pairs(OPTION_MAP) do
            local option = options[id]
            if option ~= nil then
                local ok, value = pcall(function() return option.Value end)
                if ok and value ~= nil then
                    settings[key] = (key == "matchMode") and tostring(value) or value
                end
            end
        end
    end

    ------------------------------------------------------------------- run
    if not virtualInput then
        ctx.Tab:AddParagraph({
            Title   = "Typing unavailable",
            Content = "This executor would not give a VirtualInputManager, so keystrokes "
                   .. "cannot be sent. Suggestions still work - type them yourself.",
        })
    end

    ctx.Spawn(function()
        ctx.Notify("loading dictionary...", 4, "Finish The Word")
        local added = downloadDictionary(false)
        ctx.Notify(added > 0 and ("loaded %d words"):format(added)
            or "could not load a dictionary - check HTTP support", 5, "Finish The Word")
    end)

    ctx.Spawn(function()
        while ctx.IsAlive() do
            syncOptions()

            local turn = isMyTurn()
            local display, source = myMatchDisplay()
            local category = display and display:FindFirstChild("Category")
            local prompt = category and trim(category.Text) or nil
            local fragment = fragmentFrom(prompt)

            refresh(fragment)
            updateStatus(source, prompt, fragment, turn)

            if settings.autoAnswer and not answering and wordCount > 0 then
                if fragment and turn and fragment ~= answeredPrompt then
                    answeredPrompt = fragment
                    answering = true
                    local ok, err = pcall(solve, fragment)
                    answering = false
                    if not ok then ctx.Notify("error: " .. tostring(err), 6, "Finish The Word") end

                elseif settings.pickLetter and myLetterPick() then
                    local key = table.concat(letterChoices())
                    if key ~= "" and key ~= pickedFor then
                        pickedFor = key
                        answering = true
                        pcall(chooseLetter)
                        answering = false
                    end
                end
            end

            if not turn then answeredPrompt = nil end
            if not myLetterPick() then pickedFor = nil end
            task.wait(0.2)
        end
    end)
end

return M
