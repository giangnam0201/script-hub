--[[
    Spelling Race - auto spell
    ==========================
    Deobfuscated from "auto spell keyless.txt" (WeAreDevs obfuscator v1.0.0,
    original by light2light) and adapted to the hub module contract.

    How the game hides the answer, innermost first:
      1. the word is turned into ASCII codes
      2. each code has its DIGITS REVERSED          ("a" = 97 -> "79")
      3. codes are joined with commas
      4. every byte is XOR'd with a repeating key:  "1144" .. PlaceId .. "00552002"
      5. the result lives in the "Color" attribute of the Texture under a
         scenery part in workspace.Floors2
      6. Lighting.Bloom.Sky.StarCount is a per-round offset subtracted from
         every character code

    If the payload is missing or unusable the script falls back to the first
    non-empty AnswerControl.Answer1..4 value, exactly like the original.
]]

local M = {}

local HIDDEN_PART = "Part +R2107+ +R21+ +R21+ +R21+ +R21+ +R21+ +R21+ +R21+ +R21+ +R22+2"

function M.Setup(ctx)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local RoundControl = ReplicatedStorage:WaitForChild("RoundControlFolder", 10)
    local Remotes      = ReplicatedStorage:WaitForChild("Remotes", 10)
    if not (RoundControl and Remotes) then
        ctx.Tab:AddParagraph({
            Title   = "Not in a round yet",
            Content = "RoundControlFolder / Remotes were not found. Rejoin once a match is running and re-execute.",
        })
        return
    end

    local TopicControl  = RoundControl:WaitForChild("TopicControl", 10)
    local AnswerControl = RoundControl:WaitForChild("AnswerControl", 10)
    local SubmitAnswer  = Remotes:WaitForChild("SubmitAnswerRemote", 10)
    local TopicDesc     = TopicControl and TopicControl:WaitForChild("TopicDesc", 10)

    if not (TopicDesc and AnswerControl and SubmitAnswer) then
        ctx.Tab:AddParagraph({
            Title   = "Game layout changed",
            Content = "TopicDesc / AnswerControl / SubmitAnswerRemote missing - the script needs updating.",
        })
        return
    end

    --------------------------------------------------------------- settings
    local settings = {
        autoSpell   = true,
        answerDelay = 2.2,
        randomize   = true,
        notify      = true,
    }

    local function say(text, duration)
        if settings.notify then
            ctx.Notify(text, duration or 3, "Spelling Race")
        end
    end

    --------------------------------------------------------------- decoding
    local function readPayload()
        local floors = workspace:FindFirstChild("Floors2")
        if not floors then return nil end

        local part = floors:FindFirstChild(HIDDEN_PART)
        if not part then return nil end

        local texture = part:FindFirstChildOfClass("Texture")
        if not texture then return nil end

        return texture:GetAttribute("Color")
    end

    local function decodeWord()
        local payload = readPayload()
        if not payload or payload == "" then return nil end

        -- undo the XOR; bytes that come out as letters are corrupt and
        -- collapse into the "," separator so they drop out of the split
        local key   = "1144" .. game.PlaceId .. "00552002"
        local plain = {}
        for i = 1, #payload do
            local b = bit32.bxor(payload:byte(i), key:byte((i - 1) % #key + 1))
            if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
                b = 44
            end
            plain[i] = string.char(b)
        end

        local offset = 0
        pcall(function()
            offset = game.Lighting.Bloom.Sky.StarCount
        end)

        local word = ""
        for _, chunk in ipairs(string.split(table.concat(plain), ",")) do
            local code = tonumber(string.reverse(chunk))
            if code then
                code = code - offset
                if code >= 32 and code <= 126 then
                    word = word .. string.char(code)
                end
            end
        end

        if word ~= "" then return word end
        return nil
    end

    local function fallbackAnswer()
        for i = 1, 4 do
            local answer = AnswerControl:FindFirstChild("Answer" .. i)
            local value  = answer and answer.Value or ""
            if value ~= "" then return value end
        end
        return ""
    end

    --------------------------------------------------------------- submitting
    local function submit(word, elapsed)
        -- the trailing two spaces are part of what the original sends
        local ok, result = pcall(function()
            return SubmitAnswer:InvokeServer(word .. "  ", "keyboard", nil, elapsed)
        end)
        if not ok then
            say("Submit failed: " .. tostring(result), 6)
            return nil
        end

        if result then
            if result.correct then
                say("Correct! +" .. tostring(result.score))
            elseif result.closeAnswer then
                say("Close! +" .. tostring(result.score))
            else
                say("Wrong: " .. tostring(result.correctAnswer or "?"))
            end
        end
        return result
    end

    local function currentWord()
        local word
        for _ = 1, 5 do
            if not ctx.IsAlive() then return nil end
            word = decodeWord()
            if word then return word end
            task.wait(0.5)
        end
        return nil
    end

    local busy = false

    local function solveRound()
        if busy or not ctx.IsAlive() or not settings.autoSpell then return end
        busy = true

        say("Loading word...")
        task.wait(1)

        local word = currentWord() or fallbackAnswer()
        if word == "" or not ctx.IsAlive() then
            busy = false
            return
        end

        say("Word: " .. word)

        local delay = settings.answerDelay
        if settings.randomize then
            delay = delay + (math.random() - 0.5) -- +/- 0.5s jitter
        end
        task.wait(delay)

        if ctx.IsAlive() and settings.autoSpell then
            say("Spelling...")
            submit(word, delay - 0.7)
        end
        busy = false
    end

    --------------------------------------------------------------- interface
    ctx.Tab:AddParagraph({
        Title   = "Spelling Race",
        Content = "Reads the round's word straight out of the game and answers it. "
               .. "Answer Time 2.2 with Randomize on looks the most human.",
    })

    local autoToggle = ctx.Tab:AddToggle("SpellingRace_AutoSpell", {
        Title   = "Auto Spell",
        Default = true,
    })
    autoToggle:OnChanged(function(value)
        settings.autoSpell = value
    end)

    ctx.Tab:AddSlider("SpellingRace_AnswerDelay", {
        Title       = "Answer Time",
        Description = "Delay before answering (seconds)",
        Default     = 2.2,
        Min         = 0.1,
        Max         = 5,
        Rounding    = 1,
        Callback    = function(value)
            settings.answerDelay = value
        end,
    })

    local randomToggle = ctx.Tab:AddToggle("SpellingRace_Randomize", {
        Title       = "Randomize Time",
        Description = "Adds up to +/- 0.5s of jitter",
        Default     = true,
    })
    randomToggle:OnChanged(function(value)
        settings.randomize = value
    end)

    local notifyToggle = ctx.Tab:AddToggle("SpellingRace_Notifications", {
        Title   = "Notifications",
        Default = true,
    })
    notifyToggle:OnChanged(function(value)
        settings.notify = value
    end)

    ctx.Tab:AddButton({
        Title       = "Spell Now",
        Description = "Answer the current word immediately",
        Callback    = function()
            ctx.Spawn(function()
                local word = decodeWord() or fallbackAnswer()
                if word == "" then
                    ctx.Notify("No word available yet", 4, "Spelling Race")
                    return
                end
                ctx.Notify("Spelling now...", 3, "Spelling Race")
                submit(word, 0.1)
            end)
        end,
    })

    ctx.Tab:AddButton({
        Title       = "Show decoded word",
        Description = "Peek at the answer without submitting",
        Callback    = function()
            local word = decodeWord()
            ctx.Notify(word and ("Word: " .. word) or "Payload not readable right now", 5, "Spelling Race")
        end,
    })

    --------------------------------------------------------------- run
    ctx.Connect(TopicDesc:GetPropertyChangedSignal("Value"), function()
        if TopicDesc.Value ~= "" then
            ctx.Spawn(solveRound)
        end
    end)

    if TopicDesc.Value ~= "" then
        ctx.Spawn(solveRound)
    end
end

return M
