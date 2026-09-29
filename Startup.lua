-- Connected Discord-GitHub

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacementController = require(
	ReplicatedStorage:WaitForChild("PlacementController")
)

-- The module creates and starts the controller when required.
-- Keeping the returned controller reference allows the client
-- to explicitly destroy it later if the building system is removed.

local controller = PlacementController

print("Building system loaded:", controller)
