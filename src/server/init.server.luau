-- Server entry point. Sibling files in src/server land as children of this script.
local WorldService = require(script.WorldService)
local CarService = require(script.CarService)
local PlayerDataService = require(script.PlayerDataService)
local BarnService = require(script.BarnService)
local MonetizationService = require(script.MonetizationService)
local TradingService = require(script.TradingService)

-- Generate world biomes, highways, obstacles, and tagged structures before services bind to them
WorldService.start()
CarService.start()
PlayerDataService.start()
BarnService.start()
-- After PlayerDataService: these look up the GameRemotes folder that one makes.
MonetizationService.start()
TradingService.start()

