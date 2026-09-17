-- Client entry point. Sibling files in src/client land as children of this script.
local CarController = require(script.CarController)
local Speedometer = require(script.Speedometer)

-- First, because CarController.start waits on the server's input remote.
Speedometer.start()
CarController.start()
