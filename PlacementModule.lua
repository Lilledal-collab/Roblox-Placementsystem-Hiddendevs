-- discord:  @lilledal_ , roblox: @Hasaaawuw72
--!strict

--[[
	Building / Placement System

	A simple grid-based building system for placing,
	rotating, previewing and removing objects.

	Features:
	• Grid snapping
	• Object preview
	• Object rotation
	• Placement validation
	• Delete mode
	• Multiple building blocks
	
	made by Leonel Lilledal
]]

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

--// Folders / modules
local Blocks = ReplicatedStorage:WaitForChild("Blocks")
local Trove = require(ReplicatedStorage:WaitForChild("Trove"))

--// Player
local player = Players.LocalPlayer

--// Building settings
local GRID_SIZES = {1, 2, 4, 8}
local BUILD_RANGE = 70
local LERP_SPEED = 20


--[[
	Gets whatever the mouse is pointing at.

	I use a ray from the camera instead of the old
	Mouse.Hit system because Raycast gives more control.
]]
local function GetMouseHit(
	camera: Camera?,
	params: RaycastParams
): RaycastResult?

	if not camera then
		return nil
	end

	-- Get the mouse position on the screen
	local mousePosition = UserInputService:GetMouseLocation()

	-- Create a ray from the camera through the mouse
	local ray = camera:ViewportPointToRay(
		mousePosition.X,
		mousePosition.Y
	)

	-- Shoot the ray into the world
	return workspace:Raycast(
		ray.Origin,
		ray.Direction * BUILD_RANGE,
		params
	)
end


--[[
	Snaps a position to the selected grid size.

	For example:
	Grid size 4:
	12.1 -> 12
	13.9 -> 12
	14.1 -> 16

	When you're placing against a wall, you don't
	snap that axis because the position needs to
	follow the wall.
]]
local function SnapPosToGrid(
	position: Vector3,
	gridSize: number,
	normal: Vector3
): Vector3

	local x = if math.abs(normal.X) > 0.5
		then position.X
		else math.round(position.X / gridSize) * gridSize

	local y = if math.abs(normal.Y) > 0.5
		then position.Y
		else math.round(position.Y / gridSize) * gridSize

	local z = if math.abs(normal.Z) > 0.5
		then position.Z
		else math.round(position.Z / gridSize) * gridSize

	return Vector3.new(x, y, z)
end


--[[
	Turns a normal model into a transparent preview.

	The preview cannot collide or interfere with
	the raycast.
]]
local function MakePreview(model: Model)
	for _, object in model:GetDescendants() do
		if not object:IsA("BasePart") then
			continue
		end

		object.Anchored = true
		object.CanCollide = false
		object.CanQuery = false
		object.Transparency = 0.5
	end
end


--// Controller
local PlacementController = {}
PlacementController.__index = PlacementController


--[[
	This describes the data stored inside the controller.

	Keeping this typed makes the code easier to work with
	when using --!strict.
]]
type ControllerData = {
	_gridIndex: number,
	_rotation: number,
	_rotationCFrame: CFrame,
	_blockIndex: number,

	_selectedBlock: Model?,
	_preview: Model?,
	_deleteHighlight: Highlight?,

	_placing: boolean,
	_canPlace: boolean,
	_deleting: boolean,

	_lastTargetCFrame: CFrame?,
	_lastValidPlacement: boolean?,

	_blockSize: Vector3?,
	_blockPivotOffset: CFrame?,

	_currentCFrame: CFrame?,
	_targetCFrame: CFrame?,

	_trove: any,
	_previewTrove: any,

	_raycastParams: RaycastParams,
	_overlapParams: OverlapParams,
}

type PlacementControllerType = typeof(setmetatable(
	{} :: ControllerData,
	PlacementController
	))


--[[
	Creates a new placement controller.
]]
function PlacementController.new(): PlacementControllerType

	local self = setmetatable({
		-- Start with the first grid size
		_gridIndex = 1,

		-- Start with no rotation
		_rotation = 0,
		_rotationCFrame = CFrame.new(),

		-- 0 means that no block has been selected yet
		_blockIndex = 0,

		-- Current selected objects
		_selectedBlock = nil,
		_preview = nil,
		_deleteHighlight = nil,

		-- Current modes
		_placing = false,
		_canPlace = false,
		_deleting = false,

		-- Cached values
		_lastTargetCFrame = nil,
		_lastValidPlacement = nil,

		_blockSize = nil,
		_blockPivotOffset = nil,

		_currentCFrame = nil,
		_targetCFrame = nil,

		-- Trove handles cleanup for us
		_trove = Trove.new(),
		_previewTrove = nil,

		-- Raycast settings
		_raycastParams = RaycastParams.new(),

		-- Collision checking settings
		_overlapParams = OverlapParams.new(),

	}, PlacementController) :: any


	-- PreviewTrove is connected to the main Trove.
	-- This lets us clean only the current preview.
	self._previewTrove = self._trove:Extend()


	--// Raycast setup
	self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude


	--// Collision checking setup
	self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude


	--[[
		This highlight is used when deleting blocks.

		I create it once and simply enable/disable it
		instead of creating a new Highlight every frame.
	]]
	local highlight = self._trove:Add(
		Instance.new("Highlight")
	)

	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = workspace

	self._deleteHighlight = highlight


	-- Start listening for input and updates
	self:Start()

	return self
end


--[[
	Starts the controller.

	Heartbeat updates the preview every frame.
	InputBegan handles keyboard and mouse input.
]]
function PlacementController.Start(
	self: PlacementControllerType
)

	-- Update the building system every frame
	self._trove:Add(
		RunService.Heartbeat:Connect(function(deltaTime)
			self:Update(deltaTime)
		end)
	)


	-- Listen for keyboard / mouse input
	self._trove:Add(
		UserInputService.InputBegan:Connect(function(
			input,
			gameProcessed
		)

			-- Don't handle input that another UI already used
			if gameProcessed then
				return
			end

			self:ProcessInput(input)
		end)
	)


	-- Update filters when the character respawns
	self._trove:Add(
		player.CharacterAdded:Connect(function()
			self:UpdateFilters()
		end)
	)


	-- Update them once when starting
	self:UpdateFilters()
end


--[[
	Handles all controls.
]]
function PlacementController.ProcessInput(
	self: PlacementControllerType,
	input: InputObject
)

	-- Left mouse button
	if input.UserInputType == Enum.UserInputType.MouseButton1 then

		if self._deleting then
			self:Delete()
		else
			self:Place()
		end
	end


	-- F = next block
	if input.KeyCode == Enum.KeyCode.F then

		if self._placing then
			self:CycleBlock()
		end
	end


	-- R = rotate
	if input.KeyCode == Enum.KeyCode.R then

		if self._placing then
			self:Rotate()
		end
	end


	-- G = change grid
	if input.KeyCode == Enum.KeyCode.G then

		if self._placing then
			self:CycleGridSize()
		end
	end


	-- X = delete mode
	if input.KeyCode == Enum.KeyCode.X then
		self:ToggleDeleteMode()
	end


	-- Q = enter / leave building mode
	if input.KeyCode == Enum.KeyCode.Q then

		if self._placing then
			self:Cancel()
		else
			self:EquipLastBlock()
		end
	end
end


--[[
	Enters building mode.

	If no block has been selected yet,
	the first block is selected.
]]
function PlacementController.EquipLastBlock(
	self: PlacementControllerType
)

	local blocks = Blocks:GetChildren()

	assert(
		#blocks > 0,
		"No blocks were found inside ReplicatedStorage.Blocks"
	)


	-- Make sure the index is valid
	if self._blockIndex == 0
		or self._blockIndex > #blocks then

		self._blockIndex = 1
	end


	local block = blocks[self._blockIndex]


	-- Only Models can be placed
	if block:IsA("Model") then
		self:SelectBlock(block)
	end
end


--[[
	Cycles to the next block in the Blocks folder.
]]
function PlacementController.CycleBlock(
	self: PlacementControllerType
)

	local blocks = Blocks:GetChildren()

	assert(
		#blocks > 0,
		"No blocks were found inside ReplicatedStorage.Blocks"
	)


	-- Move to the next index.
	-- % makes it loop back to the beginning.
	self._blockIndex =
		(self._blockIndex % #blocks) + 1


	local nextBlock = blocks[self._blockIndex]


	if nextBlock:IsA("Model") then
		self:SelectBlock(nextBlock)
	end
end


--[[
	Selects a block and creates its preview.
]]
function PlacementController.SelectBlock(
	self: PlacementControllerType,
	blockTemplate: Model
)

	-- Remove the old preview
	self:Cancel()


	self._placing = true
	self._selectedBlock = blockTemplate


	-- Get the size and center of the model
	local blockCFrame, blockSize =
		blockTemplate:GetBoundingBox()


	-- Cache these values so we don't calculate
	-- them every frame.
	self._blockSize = blockSize

	self._blockPivotOffset =
		blockCFrame:ToObjectSpace(
			blockTemplate:GetPivot()
		)


	-- Create the new preview
	self:CreatePreview(blockTemplate)
end


--[[
	Cycles through the available grid sizes.

	1 -> 2 -> 4 -> 8 -> 1
]]
function PlacementController.CycleGridSize(
	self: PlacementControllerType
)

	self._gridIndex =
		(self._gridIndex % #GRID_SIZES) + 1
end


--[[
	Toggles delete mode.
]]
function PlacementController.ToggleDeleteMode(
	self: PlacementControllerType
)

	-- Remember the new state before Cancel()
	-- resets the modes.
	local newDeleteState = not self._deleting

	self:Cancel()

	self._deleting = newDeleteState
end


--[[
	Creates the transparent block that follows
	the mouse.
]]
function PlacementController.CreatePreview(
	self: PlacementControllerType,
	blockTemplate: Model
)

	-- Remove the previous preview
	self._previewTrove:Clean()


	-- Clone the original block
	local preview = blockTemplate:Clone()

	self._preview = preview


	-- Make it transparent and non-collidable
	MakePreview(preview)


	-- Trove will destroy the preview when cleaned
	self._previewTrove:Add(preview)


	-- Reset rotation
	self._rotation = 0
	self._rotationCFrame = CFrame.new()

	self._placing = true


	-- Make sure the preview is ignored by raycasts
	self:UpdateFilters()
end


--[[
	Updates the objects ignored by our raycasts.

	I don't want to raycast into:
	- The player's character
	- The building preview
]]
function PlacementController.UpdateFilters(
	self: PlacementControllerType
)

	local filterObjects: {Instance} = {}


	if self._preview then
		table.insert(
			filterObjects,
			self._preview
		)
	end


	if player.Character then
		table.insert(
			filterObjects,
			player.Character
		)
	end


	self._raycastParams.FilterDescendantsInstances =
		filterObjects

	self._overlapParams.FilterDescendantsInstances =
		filterObjects
end


--[[
	Rotates the block 90 degrees.

	0 -> 90 -> 180 -> 270 -> 0
]]
function PlacementController.Rotate(
	self: PlacementControllerType
)

	self._rotation =
		(self._rotation + 90) % 360


	self._rotationCFrame =
		CFrame.Angles(
			0,
			math.rad(self._rotation),
			0
		)
end


--[[
	Changes the preview color.

	Green = valid
	Red = blocked
]]
function PlacementController.UpdatePreviewColor(
	self: PlacementControllerType,
	isValidPlacement: boolean
)

	-- Don't do anything if the state hasn't changed
	if not self._preview then
		return
	end

	if self._lastValidPlacement == isValidPlacement then
		return
	end


	self._lastValidPlacement =
		isValidPlacement


	local targetColor = if isValidPlacement
		then Color3.fromRGB(0, 255, 0)
		else Color3.fromRGB(255, 0, 0)


	-- Change every part in the preview
	for _, object in self._preview:GetDescendants() do

		if not object:IsA("BasePart") then
			continue
		end

		object.Color = targetColor
	end
end


--[[
	Checks if there is something blocking
	the location where the block wants to go.
]]
function PlacementController.CheckCollisions(
	self: PlacementControllerType,
	cframe: CFrame,
	size: Vector3
): boolean

	-- Make the box slightly smaller.
	-- This allows blocks to touch each other.
	local checkSize =
		size - Vector3.new(
			0.01,
			0.01,
			0.01
		)


	local parts =
		workspace:GetPartBoundsInBox(
			cframe,
			checkSize,
			self._overlapParams
		)


	for _, part in parts do

		-- Only collidable objects should block placement
		if part.CanCollide then
			return false
		end
	end


	-- Nothing was blocking the location
	return true
end


--[[
	Checks whether all required data exists
	before attempting to place a block.
]]
function PlacementController.CanPlace(
	self: PlacementControllerType
): boolean

	if not self._placing then
		return false
	end

	if not self._preview then
		return false
	end

	if not self._selectedBlock then
		return false
	end

	if not self._blockSize then
		return false
	end

	return true
end


--[[
	Main update loop.

	This is where:
	- Mouse raycasting
	- Grid snapping
	- Rotation
	- movement
	- Collision checking

	all happen.
]]
function PlacementController.Update(
	self: PlacementControllerType,
	deltaTime: number
)

	--// DELETE MODE

	if self._deleting and self._deleteHighlight then

		local result =
			GetMouseHit(
				workspace.CurrentCamera,
				self._raycastParams
			)


		if result and result.Instance then

			-- Find the Model that owns the part
			local targetModel =
				result.Instance:FindFirstAncestorOfClass(
					"Model"
				)


			if targetModel then

				-- Only update the highlight when
				-- the hovered model changes.
				if self._deleteHighlight.Adornee
					~= targetModel then

					self._deleteHighlight.Adornee =
						targetModel

					self._deleteHighlight.Enabled =
						true
				end


				return
			end
		end


		-- Nothing is being hovered
		self._deleteHighlight.Enabled = false
		self._deleteHighlight.Adornee = nil

		return
	end


	--// PLACEMENT MODE

	if not self:CanPlace() then
		return
	end


	local result =
		GetMouseHit(
			workspace.CurrentCamera,
			self._raycastParams
		)


	-- Show the preview only when
	-- the mouse hits something.
	if self._preview then
		self._preview.Parent =
			if result then workspace else nil
	end


	if not result then
		self._canPlace = false
		return
	end


	local blockSize = self._blockSize

	if not blockSize then
		return
	end


	-- Calculate the size after rotation
	local rotatedSize =
		self._rotationCFrame * blockSize


	-- Size can become negative after rotation,
	-- so use absolute values.
	local absoluteSize = Vector3.new(
		math.abs(rotatedSize.X),
		math.abs(rotatedSize.Y),
		math.abs(rotatedSize.Z)
	)


	-- Move the block away from the surface
	-- so it sits directly against it.
	local newPosition =
		result.Position
		+ result.Normal * (absoluteSize / 2)


	-- Snap the position to the selected grid
	local gridSize =
		GRID_SIZES[self._gridIndex]


	local gridPosition =
		SnapPosToGrid(
			newPosition,
			gridSize,
			result.Normal
		)


	-- Create the final target CFrame
	local targetCFrame =
		CFrame.new(gridPosition)
		* self._rotationCFrame


	self._targetCFrame =
		targetCFrame


	--// SMOOTH MOVEMENT

	if self._currentCFrame then

		self._currentCFrame =
			self._currentCFrame:Lerp(
				targetCFrame,
				math.min(
					deltaTime * LERP_SPEED,
					1
				)
			)

	else

		self._currentCFrame =
			targetCFrame
	end


	local currentCFrame =
		self._currentCFrame


	if not currentCFrame then
		return
	end


	-- Move the preview
	if self._preview then

		local pivotOffset =
			self._blockPivotOffset
			or CFrame.new()


		self._preview:PivotTo(
			currentCFrame * pivotOffset
		)
	end


	-- Check if the target position is free
	self._canPlace =
		self:CheckCollisions(
			targetCFrame,
			blockSize
		)


	-- Change preview between green/red
	self:UpdatePreviewColor(
		self._canPlace
	)


	-- Save the last target
	self._lastTargetCFrame =
		targetCFrame
end


--[[
	Places the actual block into Workspace.
]]
function PlacementController.Place(
	self: PlacementControllerType
)

	if not self:CanPlace() then
		return
	end


	-- Never allow placement if the location
	-- is blocked.
	if not self._canPlace then
		return
	end


	local selectedBlock =
		self._selectedBlock


	local targetCFrame =
		self._targetCFrame


	local pivotOffset =
		self._blockPivotOffset


	if not selectedBlock
		or not targetCFrame
		or not pivotOffset then

		return
	end


	-- Clone the original template
	local placedModel =
		selectedBlock:Clone()


	-- Put it at the target position
	placedModel:PivotTo(
		targetCFrame * pivotOffset
	)


	-- Finally put it into Workspace
	placedModel.Parent = workspace
end


--[[
	Deletes the model under the mouse.
]]
function PlacementController.Delete(
	self: PlacementControllerType
)

	if not self._deleting then
		return
	end


	local result =
		GetMouseHit(
			workspace.CurrentCamera,
			self._raycastParams
		)


	if not result then
		return
	end


	-- Find the Model that owns the part
	local targetModel =
		result.Instance:FindFirstAncestorOfClass(
			"Model"
		)


	if targetModel then
		targetModel:Destroy()
	end
end


--[[
	Cancels building mode and cleans the preview.
]]
function PlacementController.Cancel(
	self: PlacementControllerType
)

	self._placing = false
	self._deleting = false
	self._canPlace = false

	self._selectedBlock = nil
	self._preview = nil

	self._lastTargetCFrame = nil
	self._lastValidPlacement = nil

	self._currentCFrame = nil
	self._targetCFrame = nil

	-- Destroy the current preview
	self._previewTrove:Clean()


	-- Hide delete highlight
	if self._deleteHighlight then

		self._deleteHighlight.Enabled = false
		self._deleteHighlight.Adornee = nil
	end
end


--[[
	Fully destroys the controller.

	Useful when the entire building system
	needs to be removed.
]]
function PlacementController.Destroy(
	self: PlacementControllerType
)

	self._trove:Destroy()
end


-- Create and return the controller
return PlacementController.new()
