-- Server entry point. Sibling files in src/server land as children of this script.
local CarService = require(script.CarService)
local PlayerDataService = require(script.PlayerDataService)
local BarnService = require(script.BarnService)

CarService.start()
PlayerDataService.start()
BarnService.start()
