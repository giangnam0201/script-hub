--[[
    Script Hub - loader
    ===================
    This is the file your users execute:

        loadstring(game:HttpGet("https://raw.githubusercontent.com/giangnam0201/script-hub/main/loader.lua"))()

    It does three things and nothing else:
      1. tears down a previous session if the hub is already running,
      2. installs HUB_REQUIRE (the module loader used by every other file),
      3. fetches src/core.lua and starts it.

    Everything else lives in src/ so you can edit a single script without
    touching the loader your users have bookmarked.
]]

local CONFIG = {
    -- Shown in the window title / notifications.
    Name    = "namdevHub",
    Version = "1.0.0",

    -- MUST end with a slash. Point this at the folder that holds loader.lua.
    BaseUrl = "https://raw.githubusercontent.com/giangnam0201/script-hub/main/",

    -- raw.githubusercontent.com caches aggressively; this appends ?v=<time>
    -- so your users always get the newest push. Turn off once you are stable.
    CacheBust = true,

    -- Prints every module fetch to the console.
    Debug = false,
}

--=========================================================================
-- Unload a previous session (re-executing the hub should never stack)
--=========================================================================
local genv = (getgenv and getgenv()) or _G
if genv.__ScriptHub and genv.__ScriptHub.Unload then
    pcall(genv.__ScriptHub.Unload)
end

--=========================================================================
-- Module loader
--=========================================================================
local cache = {}

local function fetch(path)
    local url = CONFIG.BaseUrl .. path .. ".lua"
    if CONFIG.CacheBust then
        url = url .. "?v=" .. tostring(math.floor(tick()))
    end
    if CONFIG.Debug then
        print("[Hub] fetch " .. url)
    end

    local ok, source = pcall(game.HttpGet, game, url)
    if not ok or type(source) ~= "string" or source == "" then
        error("[Hub] could not download " .. path .. " (" .. tostring(source) .. ")", 0)
    end

    local chunk, err = loadstring(source, "@" .. path)
    if not chunk then
        error("[Hub] syntax error in " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

-- Every hub file pulls its dependencies through this.
-- In the bundled single-file build this same global is replaced by a
-- table lookup, so module code is identical in both modes.
function genv.HUB_REQUIRE(path)
    if cache[path] == nil then
        cache[path] = fetch(path)
    end
    return cache[path]
end
HUB_REQUIRE = genv.HUB_REQUIRE

--=========================================================================
-- Go
--=========================================================================
local core = HUB_REQUIRE("src/core")
return core.Start(CONFIG)
