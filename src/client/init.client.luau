-- Client entry point. Sibling files in src/client land as children of this script.
local CarController = require(script.CarController)
local CarVisuals = require(script.CarVisuals)
local Speedometer = require(script.Speedometer)
local GameUI = require(script.GameUI)

-- First, because CarController.start waits on the server's input remote.
CarVisuals.start()
Speedometer.start()
CarController.start()
GameUI.start()

