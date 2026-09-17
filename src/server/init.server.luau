-- Server entry point. Sibling files in src/server land as children of this script.
local CarService = require(script.CarService)
local PlayerDataService = require(script.PlayerDataService)

CarService.start()
PlayerDataService.start()

