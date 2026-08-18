# namdevHub

A game-aware Roblox script hub: one loader URL, it works out which game the
player is in and loads only the scripts registered for that game, plus a set
of universal tools.

```
scripthub/
├── loader.lua                     what users execute (the one-liner)
├── src/
│   ├── core.lua                   framework: detection, UI, module runner, unload
│   ├── registry.lua               game -> script mapping  (the file you edit)
│   └── scripts/
│       ├── spelling_race.lua      Spelling Race auto-spell (deobfuscated)
│       ├── finish_the_word.lua    Finish The Word solver (deobfuscated)
│       └── universal.lua          loaded in every game
├── tools/
│   └── build.py                   bundles everything into dist/hub.lua
└── dist/
    └── hub.lua                    generated single-file build
```

## Two ways to ship it

**Hosted (recommended).** Push this folder to a public GitHub repo, set
`BaseUrl` in `loader.lua` to your raw URL, and hand out:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/giangnam0201/script-hub/main/loader.lua"))()
```

Only the modules needed for the current game are downloaded, and you can fix
a script by pushing a commit — nobody re-copies anything.

**Single file.** `python tools/build.py` writes `dist/hub.lua` with every
module embedded. Good for releases, pastebin, or executors with flaky HTTP.
Module code is identical in both modes.

## Adding a game

1. Drop the script in `src/scripts/<game_name>.lua` following the contract
   below.
2. Add an entry to `src/registry.lua`.
3. Rebuild if you ship the single-file version.

Registry entry:

```lua
{
    Name        = "Game Name",             -- tab title
    Module      = "src/scripts/game_name", -- no .lua
    PlaceIds    = { 1234567890 },          -- most specific match
    GameIds     = {},                      -- universe id: catches lobby + all maps
    NameMatch   = "game name",             -- substring fallback, lowercase
    Icon        = "play",                  -- lucide icon
    Author      = "original author",
    Description = "what it does",
},
```

Matching runs `PlaceIds` → `GameIds` → `NameMatch`. `NameMatch` means a
script still loads before you have written the id down; `GameIds` is the one
to use for games that teleport you between places (lobby + maps share a
universe id). Several entries can match — each gets its own tab.

Don't know the id? Run the hub in the game and use **Hub → Copy PlaceId**;
the unsupported-game screen prints it too.

## Module contract

A module returns a table with one function:

```lua
local M = {}

function M.Setup(ctx)
    ctx.Tab:AddToggle("MyScript_Farm", { Title = "Auto farm", Default = false })
        :OnChanged(function(on) farming = on end)

    ctx.Connect(someSignal, function() ... end)   -- auto-disconnected on unload
    ctx.Spawn(function()                          -- auto-cancelled on unload
        while ctx.IsAlive() do ... task.wait(1) end
    end)
    ctx.OnUnload(function() ... end)              -- your own teardown
end

return M
```

| field | what it is |
|---|---|
| `ctx.Tab` | your tab, already created and named after the registry entry |
| `ctx.Notify(text, duration, title)` | toast |
| `ctx.Connect(signal, fn)` | `:Connect` that the hub will disconnect |
| `ctx.Spawn(fn, ...)` | `task.spawn` that the hub will cancel |
| `ctx.OnUnload(fn)` | teardown callback |
| `ctx.IsAlive()` | `false` once the hub is unloading — check it in loops |
| `ctx.GameInfo` | `{ PlaceId, GameId, JobId, Name }` |
| `ctx.Fluent`, `ctx.Window`, `ctx.Options` | raw Fluent handles if you need them |

Rules that keep the hub stable:

- **Never create your own window.** Use `ctx.Tab`.
- **Prefix your Fluent option ids** (`SpellingRace_AutoSpell`) — ids are
  global across the hub and collisions silently overwrite each other.
- **Loop on `ctx.IsAlive()`**, never `while true`, or unload leaves your
  thread running.
- **Fail soft.** If the game's instances are missing, add a paragraph saying
  so and `return`; don't error out — `Setup` errors are caught and shown in
  your tab, but a clean message is nicer.

## Unloading

`Hub → Unload hub` (or re-executing the loader) disconnects every tracked
connection, cancels every tracked thread, runs `OnUnload` callbacks and
destroys the UI. `getgenv().__ScriptHub` holds the live hub while it runs.

## Adding an obfuscated script

Hand over the obfuscated file and it gets decoded, rewritten as a readable
module against the contract above, registered, and verified before it lands
in `src/scripts/`. Both game modules here started as obfuscated blobs:
Spelling Race was WeAreDevs-obfuscated, Finish The Word was a two-stage Luau
VM.

**One thing the rewrites drop on purpose.** Obfuscated scripts often pull
extra code from the author's server at runtime and `loadstring` it — the
Finish The Word original fetched its UI library, a save manager and a version
file from `ancestrychanged.com`, and ran a second remote payload on some
executors. Whoever controls that domain can change what those files do at any
time, for everyone running the script. The rewritten modules use the hub's own
UI and fetch nothing from third parties, so what you read in `src/scripts/` is
all that runs.
