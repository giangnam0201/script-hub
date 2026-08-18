--[[
    Finish The Word! - word solver / auto answer
    ============================================
    Rewritten against a real crawl of the live game (PlaceId 91704854174760),
    not against the assumptions in the obfuscated script that was handed over.

    What the crawl showed, and what this module therefore does:

      * Your turn is `LocalPlayer:GetAttribute("IsTurn")` (this part the old
        script had right - it flips true/false per turn).
      * The prompt is NOT a Lua table in memory. It is UI. The table you are
        sitting at carries a BillboardGui "MatchDisplay" whose "Category"
        TextLabel holds the prompt: a letter fragment like "CE", "IT", "ME",
        or a category word like "Animals", or "Choose a letter" during the
        letter-pick phase.
      * Your seat identifies your table: Humanoid.SeatPart -> ... -> Table.
      * Letters you type appear as MatchDisplay.AnswerInput.Keys.<n>, and the
        HUD mirrors them in PlayerGui.ScreenGui.TopBar.AnswerInput.Keys.<n>.
      * Answering is keyboard input - the game reads real keystrokes - so the
        answer is typed with VirtualInputManager and submitted with Return.
        (The original script grabbed VirtualInputManager and VirtualUser for
        exactly this reason.)
      * getgc on this game/executor exposes nothing useful: no game tables, no
        word list. So the dictionary is downloaded instead.

    The prompt is treated as a SUBSTRING the word must contain, which is what
    "Finish The Word" fragments like "CE" / "IT" / "ME" imply. Switch the
    Match mode dropdown to "Starts with" if a round behaves otherwise.
]]

local M = {}

function M.Setup(ctx)
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer

    ------------------------------------------------------------------ state
    local settings = {
        autoAnswer   = false,
        matchMode    = "Contains",
        pickShortest = true,
        typeDelay    = 0.06,
        answerDelay  = 0.5,
        suggestCount = 15,
    }

    local words, known, rank = {}, {}, {}
    local used = {}
    local wordCount = 0
    local answeredPrompt = nil
    local answering = false

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

    ------------------------------------------------------------ game lookup
    -- Your seat tells us which table you are playing at.
    local function currentTable()
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local seat = humanoid and humanoid.SeatPart
        if not seat then return nil end

        local node = seat
        while node and node ~= workspace do
            local display = node:FindFirstChild("Table")
            if display and display:FindFirstChild("MatchDisplay") then
                return display
            end
            node = node.Parent
        end
        return nil
    end

    -- The prompt text, from the table you are at, falling back to any active
    -- MatchDisplay if the seat lookup fails.
    local function promptLabel()
        local tableModel = currentTable()
        if tableModel then
            local display = tableModel:FindFirstChild("MatchDisplay")
            local category = display and display:FindFirstChild("Category")
            if category then return category end
        end

        local meta = workspace:FindFirstChild("Meta")
        local tables = meta and meta:FindFirstChild("Tables")
        if not tables then return nil end
        for _, model in ipairs(tables:GetChildren()) do
            local display = model:FindFirstChild("Table")
            display = display and display:FindFirstChild("MatchDisplay")
            if display and display:GetAttribute("Active") == true then
                local category = display:FindFirstChild("Category")
                if category then return category end
            end
        end
        return nil
    end

    -- What has already been typed into the answer box, so we only type the rest.
    local function typedSoFar()
        local tableModel = currentTable()
        local display = tableModel and tableModel:FindFirstChild("MatchDisplay")
        local input = display and display:FindFirstChild("AnswerInput")
        local keys = input and input:FindFirstChild("Keys")
        if not keys then return "" end

        local letters = {}
        for _, key in ipairs(keys:GetChildren()) do
            local index = tonumber(key.Name)
            if index then
                local label = key:FindFirstChildWhichIsA("TextLabel", true)
                letters[index] = label and label.Text or ""
            end
        end

        local out = {}
        for i = 1, #letters do out[#out + 1] = letters[i] or "" end
        return table.concat(out):lower()
    end

    local function isMyTurn()
        local ok, value = pcall(function()
            return LocalPlayer:GetAttribute("IsTurn")
        end)
        return ok and value == true
    end

    ------------------------------------------------------------------ input
    -- The game reads real keystrokes, so we send real keystrokes.
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

    local function typeWord(word, alreadyTyped)
        local start = #alreadyTyped + 1
        if word:sub(1, #alreadyTyped) ~= alreadyTyped then
            start = 1   -- what is on screen is not our word; type the whole thing
        end

        for i = start, #word do
            if not ctx.IsAlive() or not isMyTurn() then return false end
            local letter = word:sub(i, i):upper()
            local keyCode = Enum.KeyCode[letter]
            if keyCode then pressKey(keyCode) end
            task.wait(settings.typeDelay)
        end

        task.wait(settings.answerDelay)
        if not ctx.IsAlive() or not isMyTurn() then return false end
        pressKey(Enum.KeyCode.Return)
        return true
    end

    ------------------------------------------------------------- word search
    local function matches(word, fragment)
        if settings.matchMode == "Starts with" then
            return word:sub(1, #fragment) == fragment
        end
        return word:find(fragment, 1, true) ~= nil
    end

    local function candidates(fragment, limit)
        local out = {}
        for _, word in ipairs(words) do
            if not used[word] and matches(word, fragment) then
                out[#out + 1] = word
                if limit and #out >= limit * 6 then break end
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

    ------------------------------------------------------------------- solve
    -- "CE" -> a fragment to solve. "Animals" / "Choose a letter" -> not one.
    local function fragmentFrom(text)
        if not text then return nil end
        local cleaned = text:match("^%s*(.-)%s*$"):lower()
        if #cleaned == 0 or #cleaned > 4 then return nil end
        if not cleaned:match("^%a+$") then return nil end
        return cleaned
    end

    local function solve(fragment)
        local list = candidates(fragment, 1)
        local word = list[1]
        if not word then
            ctx.Notify(('no word contains "%s"'):format(fragment), 4, "Finish The Word")
            return
        end

        used[word] = true
        if typeWord(word, typedSoFar()) then
            ctx.Notify("answered: " .. word, 3, "Finish The Word")
        end
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
            if #lines == 0 then lines = { ('no word contains "%s"'):format(fragment) } end
        end
        pcall(function() suggestionBox:SetDesc(table.concat(lines, "\n")) end)
    end

    local function updateStatus(label, fragment, turn)
        if not statusBox then return end
        pcall(function()
            statusBox:SetDesc(("words: %d   typing: %s   prompt: %s   IsTurn: %s")
                :format(wordCount,
                        virtualInput and "ready" or "NO VirtualInputManager",
                        fragment or (label and ('"%s" (not a letter prompt)'):format(label.Text)) or "none",
                        turn and "true" or "false"))
        end)
    end

    ctx.Tab:AddParagraph({
        Title   = "Finish The Word!",
        Content = "Reads the prompt off your table's Category label and types an answer with "
               .. "real keystrokes. Sit at a table and turn Auto answer on.",
    })

    ctx.Tab:AddToggle("FTW_AutoAnswer", { Title = "Auto answer", Default = false })
        :OnChanged(function(value) settings.autoAnswer = value end)

    ctx.Tab:AddDropdown("FTW_MatchMode", {
        Title = "Match mode", Values = { "Contains", "Starts with" }, Default = 1,
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
        Title = "Delay before submitting", Default = 0.5, Min = 0, Max = 3, Rounding = 1,
    }):OnChanged(function(value) settings.answerDelay = value end)

    ctx.Tab:AddSlider("FTW_SuggestCount", {
        Title = "Suggestion count", Default = 15, Min = 1, Max = 50, Rounding = 0,
    }):OnChanged(function(value) settings.suggestCount = value end)

    ctx.Tab:AddButton({
        Title       = "Answer now",
        Description = "Solve the current prompt once, ignoring Auto answer",
        Callback    = function()
            ctx.Spawn(function()
                local label = promptLabel()
                local fragment = fragmentFrom(label and label.Text)
                if not fragment then
                    ctx.Notify("no letter prompt on your table right now", 4, "Finish The Word")
                    return
                end
                solve(fragment)
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
    -- restored from a saved config or set with SetValue, which is why "Auto
    -- answer" could look enabled while nothing happened.
    local OPTION_MAP = {
        FTW_AutoAnswer  = "autoAnswer",
        FTW_MatchMode   = "matchMode",
        FTW_Shortest    = "pickShortest",
        FTW_TypeDelay   = "typeDelay",
        FTW_AnswerDelay = "answerDelay",
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
            local label = promptLabel()
            local fragment = fragmentFrom(label and label.Text)

            refresh(fragment)
            updateStatus(label, fragment, turn)

            if fragment and turn and settings.autoAnswer and not answering
                and fragment ~= answeredPrompt and wordCount > 0 then
                answeredPrompt = fragment
                answering = true
                local ok, err = pcall(solve, fragment)
                answering = false
                if not ok then ctx.Notify("error: " .. tostring(err), 6, "Finish The Word") end
            end

            if not turn then answeredPrompt = nil end
            task.wait(0.2)
        end
    end)
end

return M
