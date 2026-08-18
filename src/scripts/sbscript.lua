--[[
    ScriptBlox catalog entry
    ========================
    Runs the script a catalog entry carries.

    Every entry in the catalog came from the scriptblox public API, filtered to
    free, unpatched, keyless scripts, one per game, newest bump first. The
    fields in the registry - game name, script, view count, update date - are
    all straight from that API. None of it is written by hand.

    These scripts are almost always a single loadstring pointing at the
    author's own host, so the entry holds a reference rather than a copy: the
    author keeps their code, and you get whatever version they currently
    publish rather than a snapshot that goes stale. That is also what makes
    "as latest as possible" true here.

    It does mean the tab is running someone else's code with full executor
    permissions, and that the code behind the url can change without the
    catalog changing. So nothing runs on its own - a script only executes when
    Load is pressed.
]]

local M = {}

function M.Setup(ctx)
    local entry = ctx.Entry or {}
    local body = entry.Script
    local running, busy = false, false
    local statusBox

    local function setStatus(text)
        if statusBox then pcall(function() statusBox:SetDesc(text) end) end
    end

    local function run()
        if busy then return end
        if running then
            ctx.Notify(tostring(entry.Name) .. " already loaded", 4, "Hub")
            return
        end
        if type(body) ~= "string" or #body == 0 then
            setStatus("this entry has no script")
            return
        end

        busy = true
        setStatus("compiling...")
        local chunk, compileError = loadstring(body, "@" .. tostring(entry.Name))
        if not chunk then
            busy = false
            setStatus("did not compile: " .. tostring(compileError))
            ctx.Notify("compile error", 6, "Hub")
            return
        end

        setStatus("running...")
        local ok, runError = pcall(chunk)
        busy = false
        if ok then
            running = true
            setStatus("loaded at " .. os.date("%H:%M:%S"))
            ctx.Notify(tostring(entry.Name) .. " loaded", 5, "Hub")
        else
            setStatus("errored: " .. tostring(runError))
            ctx.Notify(tostring(entry.Name) .. " errored", 8, "Hub")
        end
    end

    ctx.Tab:AddParagraph({
        Title   = entry.Name or "Script",
        Content = ("Script: %s\nBy: %s\nUpdated: %s\nViews: %s\n\n%s")
            :format(tostring(entry.ScriptTitle or "?"),
                    tostring(entry.Credit or "unknown"),
                    tostring(entry.Updated or "?"),
                    tostring(entry.Views or "?"),
                    "From scriptblox. Fetched from the author's host when it runs, so "
                    .. "it is their current version. Nothing runs until you press Load."),
    })

    ctx.Tab:AddButton({
        Title       = "Load script",
        Description = "Runs it once",
        Callback    = function() ctx.Spawn(run) end,
    })

    ctx.Tab:AddButton({
        Title       = "Copy script",
        Description = "Puts the loader line on your clipboard",
        Callback    = function()
            if setclipboard and body then
                setclipboard(body)
                ctx.Notify("copied", 4, "Hub")
            else
                ctx.Notify("no setclipboard in this executor", 6, "Hub")
            end
        end,
    })

    if entry.Page then
        ctx.Tab:AddButton({
            Title       = "Copy scriptblox page",
            Callback    = function()
                if setclipboard then
                    setclipboard("https://scriptblox.com/script/" .. tostring(entry.Page))
                    ctx.Notify("page url copied", 4, "Hub")
                end
            end,
        })
    end

    statusBox = ctx.Tab:AddParagraph({ Title = "Status", Content = "not loaded" })
end

return M
