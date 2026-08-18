--[[
    Script Hub - registry
    =====================
    The only file you edit when adding a game.

    Entry fields
    ------------
    Name        required  tab title + display name
    Module      required  path passed to HUB_REQUIRE, no .lua extension
    PlaceIds    list of place ids this script is for (most specific match)
    GameIds     list of universe ids - catches every place in a universe
                (lobby + maps), use when a game teleports players around
    NameMatch   lowercase substring of the marketplace name; a safety net so
                a script still loads before you have written the id down
    Universal   true = always load, in every game
    Icon        lucide icon name for the tab
    Author      credit shown in the Hub tab
    Description free text

    Matching order is PlaceIds -> GameIds -> NameMatch. Several entries may
    match at once; each one gets its own tab.
]]

return {
    {
        Name        = "Spelling Race",
        Module      = "src/scripts/spelling_race",
        -- TODO: paste the real id here (Hub tab -> Copy PlaceId while in game)
        PlaceIds    = {},
        GameIds     = {},
        NameMatch   = "spelling race",
        Icon        = "book-a",
        Author      = "light2light (deobfuscated)",
        Description = "Decodes the round's word from the hidden attribute and auto-submits it.",
    },

    {
        Name        = "Universal",
        Module      = "src/scripts/universal",
        Universal   = true,
        Icon        = "globe",
        Author      = "hub",
        Description = "Server tools that work anywhere.",
    },

    --[[  template - copy this block for each new script

    {
        Name        = "Game Name",
        Module      = "src/scripts/game_name",
        PlaceIds    = { 1234567890 },
        GameIds     = {},
        NameMatch   = "game name",
        Icon        = "play",
        Author      = "original author",
        Description = "what it does",
    },

    ]]
}
