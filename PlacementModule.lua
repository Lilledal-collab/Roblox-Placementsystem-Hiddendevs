-- discord: @lilledal_ , roblox: @Hasaaawuw72
--!strict
--[[
	Building / Placement System
	This is the client-side controller for my building system.
	The main idea is that the player gets a transparent copy of
	the block they're trying to place, and that copy follows the
	mouse until the player either places it or cancels.
	I keep the placement logic inside one controller so rotation,
	grid snapping, collision checks, delete mode and the preview
	all share the same state instead of each part of the system
	having to manage its own variables.
	made by Leonel Lilledal
]]
--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
--// Folders / modules
-- Blocks contains the actual models that can be selected and placed.
-- Trove is mainly used here so temporary connections and previews
-- don't stay around after they're no longer needed.
local Blocks = ReplicatedStorage:WaitForChild("Blocks")
local Trove = require(ReplicatedStorage:WaitForChild("Trove"))
--// Player
local player = Players.LocalPlayer
--// Building settings
-- I use a small list instead of one fixed grid value because I want
-- the player to be able to quickly switch between coarse and precise
-- placement without changing the actual placement code.
local GRID_SIZES = {1, 2, 4, 8}
-- The raycast is deliberately limited so the building system can't
-- place or interact with something far away from the player.
local BUILD_RANGE = 70
-- This only affects the visual movement of the preview. The actual
-- placement position still comes from the calculated target CFrame.
local LERP_SPEED = 20
--[[
	Gets whatever the mouse is pointing at.
	I use a camera ray instead of Mouse.Hit because I need the
	RaycastResult itself. That gives me both the hit position and
	the surface normal, which are important for putting a block
	against walls/floors and for deciding which axes should snap.
	The camera is optional here because CurrentCamera isn't
	guaranteed to exist at every possible point in the client's
	lifetime.
]]
local function GetMouseHit(
	camera: Camera?,
	params: RaycastParams
): RaycastResult?
	if not camera then
		return nil
	end
	-- Get the mouse position in screen space and turn it into
	-- a world-space ray starting from the current camera.
	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(
		mousePosition.X,
		mousePosition.Y
	)
	-- The same raycast parameters are passed in from the controller
	-- so the caller decides what the ray should ignore.
	return workspace:Raycast(
		ray.Origin,
		ray.Direction * BUILD_RANGE,
		params
	)
end
--[[
	Snaps a position to the selected grid size.
	The important part here is that I don't blindly snap all three
	axes. If the player is pointing at a vertical wall, for example,
	the wall's normal tells me which axis represents the surface.
	That axis is kept as-is while the other axes are snapped. This
	prevents the block from being pulled away from the surface just
	because the grid rounding changed its position.
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
	Turns a normal model into the visual preview used while building.
	The preview is anchored and non-collidable because it should only
	show the player where the block would go. If it could collide or
	be queried by raycasts, the preview itself could interfere with
	the placement calculations.
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
	This is the state that belongs to one placement controller.
	Most of these values are cached because Update() runs every
	Heartbeat. For example, the block's size and pivot offset don't
	need to be recalculated every frame when the selected block hasn't
	changed.
	The controller also keeps placement and delete mode separate so
	they can't accidentally process the same mouse click.
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
	Creates the controller and gives it its initial state.
	I keep the selected block, preview, rotation and placement state
	on the controller instead of using separate global variables.
	This makes it much easier to reset everything when the player
	cancels building or changes block.
	The two Troves are intentional: the main one owns the lifetime
	of the controller, while previewTrove can clean only the current
	preview when the player switches blocks.
]]
function PlacementController.new(): PlacementControllerType
	local self = setmetatable({
		_gridIndex = 1,
		_rotation = 0,
		_rotationCFrame = CFrame.new(),
		-- 0 means that there isn't a selected block yet.
		_blockIndex = 0,
		_selectedBlock = nil,
		_preview = nil,
		_deleteHighlight = nil,
		_placing = false,
		_canPlace = false,
		_deleting = false,
		_lastTargetCFrame = nil,
		_lastValidPlacement = nil,
		_blockSize = nil,
		_blockPivotOffset = nil,
		_currentCFrame = nil,
		_targetCFrame = nil,
		_trove = Trove.new(),
		_previewTrove = nil,
		_raycastParams = RaycastParams.new(),
		_overlapParams = OverlapParams.new(),
	}, PlacementController) :: any
	-- previewTrove is an extension of the main Trove.
	-- That means destroying the controller destroys everything,
	-- but switching blocks can clean just the old preview.
	self._previewTrove = self._trove:Extend()
	-- Both queries use exclusion filters because the player and
	-- the temporary preview should never count as a build target.
	self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	-- The delete highlight is created once instead of every frame.
	-- During delete mode I only change its Adornee, which avoids
	-- constantly creating and destroying Highlight instances.
	local highlight = self._trove:Add(
		Instance.new("Highlight")
	)
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = workspace
	self._deleteHighlight = highlight
	-- Everything is ready, so start listening for input and
	-- updating the placement state.
	self:Start()
	return self
end
--[[
	Starts the two things that keep the system alive:
	1. Heartbeat updates the preview and checks placement every frame.
	2. InputBegan handles keyboard/mouse controls.
	I also refresh the raycast filters when the character respawns,
	because the Character instance changes after respawning.
]]
function PlacementController.Start(
	self: PlacementControllerType
)
	self._trove:Add(
		RunService.Heartbeat:Connect(function(deltaTime)
			self:Update(deltaTime)
		end)
	)
	self._trove:Add(
		UserInputService.InputBegan:Connect(function(
			input,
			gameProcessed
		)
			-- UI/gameplay systems get first priority over building input.
			if gameProcessed then
				return
			end
			self:ProcessInput(input)
		end)
	)
	self._trove:Add(
		player.CharacterAdded:Connect(function()
			self:UpdateFilters()
		end)
	)
	self:UpdateFilters()
end
--[[
	Converts the raw keyboard/mouse input into controller actions.
	I keep the actual actions in separate functions instead of doing
	all of the building logic here. This function is basically the
	"input layer" of the system, while functions like Rotate(),
	Place() and Delete() contain the actual behaviour.
]]
function PlacementController.ProcessInput(
	self: PlacementControllerType,
	input: InputObject
)
	-- Left click has different behaviour depending on the current mode.
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if self._deleting then
			self:Delete()
		else
			self:Place()
		end
	end
	-- F cycles through the models in ReplicatedStorage.Blocks.
	if input.KeyCode == Enum.KeyCode.F then
		if self._placing then
			self:CycleBlock()
		end
	end
	-- R only rotates while there is an active placement.
	if input.KeyCode == Enum.KeyCode.R then
		if self._placing then
			self:Rotate()
		end
	end
	-- G changes the amount of grid snapping.
	if input.KeyCode == Enum.KeyCode.G then
		if self._placing then
			self:CycleGridSize()
		end
	end
	-- X switches between normal placement and delete mode.
	if input.KeyCode == Enum.KeyCode.X then
		self:ToggleDeleteMode()
	end
	-- Q acts as the main enter/exit button for building mode.
	if input.KeyCode == Enum.KeyCode.Q then
		if self._placing then
			self:Cancel()
		else
			self:EquipLastBlock()
		end
	end
end
--[[
	Enters building mode using the last selected block.
	The block index is kept even after cancelling, so pressing Q again
	doesn't unexpectedly choose a completely different block. If
	there has never been a valid selection, it starts at the first one.
]]
function PlacementController.EquipLastBlock(
	self: PlacementControllerType
)
	local blocks = Blocks:GetChildren()
	assert(
		#blocks > 0,
		"No blocks were found inside ReplicatedStorage.Blocks"
	)
	if self._blockIndex == 0
		or self._blockIndex > #blocks then
		self._blockIndex = 1
	end
	local block = blocks[self._blockIndex]
	-- The folder may technically contain other instance types,
	-- so I don't try to create a preview unless it is actually a Model.
	if block:IsA("Model") then
		self:SelectBlock(block)
	end
end
--[[
	Moves the selection to the next available block.
	The modulo calculation is what makes the selection wrap around,
	so pressing F on the last block goes back to the first one.
]]
function PlacementController.CycleBlock(
	self: PlacementControllerType
)
	local blocks = Blocks:GetChildren()
	assert(
		#blocks > 0,
		"No blocks were found inside ReplicatedStorage.Blocks"
	)
	self._blockIndex =
		(self._blockIndex % #blocks) + 1
	local nextBlock = blocks[self._blockIndex]
	if nextBlock:IsA("Model") then
		self:SelectBlock(nextBlock)
	end
end
--[[
	Sets a new block as the current placement target.
	Before doing that I call Cancel() so the previous preview and
	placement state are cleared. I then cache the bounding box and
	the pivot relationship of the model.
	The pivot offset matters because the model's pivot doesn't
	necessarily sit exactly at the centre of its bounding box.
	Keeping that offset means the preview and the final placed
	model use the same positioning.
]]
function PlacementController.SelectBlock(
	self: PlacementControllerType,
	blockTemplate: Model
)
	self:Cancel()
	self._placing = true
	self._selectedBlock = blockTemplate
	local blockCFrame, blockSize =
		blockTemplate:GetBoundingBox()
	self._blockSize = blockSize
	self._blockPivotOffset =
		blockCFrame:ToObjectSpace(
			blockTemplate:GetPivot()
		)
	self:CreatePreview(blockTemplate)
end
--[[
	Cycles through the grid sizes instead of changing the value
	directly. This keeps the actual snapping code independent from
	how the user chooses the grid size.
]]
function PlacementController.CycleGridSize(
	self: PlacementControllerType
)
	self._gridIndex =
		(self._gridIndex % #GRID_SIZES) + 1
end
--[[
	Switches delete mode on/off.
	Cancel() normally resets both placement and delete state, so I
	save the desired delete state first. Without doing that, calling
	Cancel() here would immediately turn delete mode back off.
]]
function PlacementController.ToggleDeleteMode(
	self: PlacementControllerType
)
	local newDeleteState = not self._deleting
	self:Cancel()
	self._deleting = newDeleteState
end
--[[
	Creates the temporary model shown under the mouse.
	The original template is cloned so the actual block in
	ReplicatedStorage is never modified. The clone is then converted
	into a non-collidable preview and given to previewTrove so it is
	automatically removed when another preview is created.
]]
function PlacementController.CreatePreview(
	self: PlacementControllerType,
	blockTemplate: Model
)
	self._previewTrove:Clean()
	local preview = blockTemplate:Clone()
	self._preview = preview
	MakePreview(preview)
	self._previewTrove:Add(preview)
	-- A new block starts with no rotation from the previous selection.
	self._rotation = 0
	self._rotationCFrame = CFrame.new()
	self._placing = true
	-- The new preview must be excluded from the raycast immediately.
	self:UpdateFilters()
end
--[[
	Keeps the raycast and overlap checks from interacting with
	temporary/client-only objects.
	The preview is especially important here: without excluding it,
	the mouse ray could hit the transparent preview instead of the
	actual surface underneath it.
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
	Adds another 90 degrees to the current rotation.
	Keeping the rotation as a number makes cycling simple, while
	_rotationCFrame gives the rest of the placement code a CFrame
	it can directly multiply with the target position.
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
	Updates the visual state of the preview.
	I only recolor the model when the valid/invalid state actually
	changes. Since Update() runs every frame, avoiding unnecessary
	property writes here is useful, especially for models with many
	parts.
	Green means the collision test passed, red means something is
	blocking the intended placement.
]]
function PlacementController.UpdatePreviewColor(
	self: PlacementControllerType,
	isValidPlacement: boolean
)
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
	for _, object in self._preview:GetDescendants() do
		if not object:IsA("BasePart") then
			continue
		end
		object.Color = targetColor
	end
end
--[[
	Checks whether the space occupied by the block is already taken.
	I shrink the test box by a tiny amount so two blocks can touch
	without being treated as overlapping. This is important for a
	building system because otherwise perfectly adjacent blocks could
	be rejected due to their bounding boxes touching.
	The overlap query can return non-collidable parts too, so I only
	treat parts with CanCollide enabled as actual blockers.
]]
function PlacementController.CheckCollisions(
	self: PlacementControllerType,
	cframe: CFrame,
	size: Vector3
): boolean
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
		if part.CanCollide then
			return false
		end
	end
	return true
end
--[[
	This is a small guard used before placement calculations.
	Most of Update() depends on the preview, selected block and
	cached block size existing. Instead of repeating those checks
	everywhere, I keep them in one function.
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
	This is the main part of the system.
	Every frame I first decide whether the controller is in delete
	mode or placement mode. In placement mode the mouse ray gives me
	the surface, the surface normal is used to calculate where the
	block should sit, then grid snapping and rotation are applied.
	The preview is moved smoothly toward that calculated position,
	but collision checking still uses the actual target CFrame. This
	keeps the visual interpolation from affecting whether placement
	is considered valid.
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
			-- A ray normally hits a Part, so I walk up to its
			-- containing Model before showing the delete target.
			local targetModel =
				result.Instance:FindFirstAncestorOfClass(
					"Model"
				)
			if targetModel then
				-- The highlight is reused. Changing the Adornee only
				-- when the model changes avoids unnecessary updates.
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
	-- I don't keep the preview visible when the mouse isn't
	-- pointing at a valid world surface.
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
	-- Rotating a rectangular size swaps its X/Z dimensions.
	-- Taking the absolute values gives us a usable world-space
	-- bounding size regardless of the current 90-degree rotation.
	local rotatedSize =
		self._rotationCFrame * blockSize
	local absoluteSize = Vector3.new(
		math.abs(rotatedSize.X),
		math.abs(rotatedSize.Y),
		math.abs(rotatedSize.Z)
	)
	-- Move the centre of the block away from the surface by half
	-- of its size. The normal tells us which direction the surface
	-- faces, so the block ends up sitting against it instead of
	-- being centred inside the surface.
	local newPosition =
		result.Position
		+ result.Normal * (absoluteSize / 2)
	-- Apply the currently selected grid.
	local gridSize =
		GRID_SIZES[self._gridIndex]
	local gridPosition =
		SnapPosToGrid(
			newPosition,
			gridSize,
			result.Normal
		)
	-- Position and rotation are combined into the CFrame that
	-- represents where the block would actually be placed.
	local targetCFrame =
		CFrame.new(gridPosition)
		* self._rotationCFrame
	self._targetCFrame =
		targetCFrame
	--// SMOOTH MOVEMENT
	-- The preview is intentionally interpolated instead of snapping
	-- instantly to every tiny mouse movement. This makes the preview
	-- easier to follow visually without changing the actual target.
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
	-- Apply the cached pivot offset so models whose pivot isn't
	-- centred still appear exactly where their bounding box expects.
	if self._preview then
		local pivotOffset =
			self._blockPivotOffset
			or CFrame.new()
		self._preview:PivotTo(
			currentCFrame * pivotOffset
		)
	end
	-- Collision checking is done against the target position rather
	-- than the interpolated preview position. This prevents the
	-- visual smoothing from causing a placement delay or inaccurate
	-- collision result.
	self._canPlace =
		self:CheckCollisions(
			targetCFrame,
			blockSize
		)
	self:UpdatePreviewColor(
		self._canPlace
	)
	self._lastTargetCFrame =
		targetCFrame
end
--[[
	Clones the selected template into the actual Workspace.
	I don't move the preview itself into Workspace as the final object.
	Instead I clone the original template again, which keeps the
	preview purely visual and means the placed object starts with the
	original properties of the template.
]]
function PlacementController.Place(
	self: PlacementControllerType
)
	if not self:CanPlace() then
		return
	end
	-- The preview can exist even when its current location is blocked,
	-- so this check is what actually prevents invalid placement.
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
	local placedModel =
		selectedBlock:Clone()
	placedModel:PivotTo(
		targetCFrame * pivotOffset
	)
	placedModel.Parent = workspace
end
--[[
	Deletes the model currently underneath the mouse.
	The same raycast/filtering used by the highlight is used here,
	so the object shown as the delete target is normally the object
	that gets removed when the player clicks.
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
	local targetModel =
		result.Instance:FindFirstAncestorOfClass(
			"Model"
		)
	if targetModel then
		targetModel:Destroy()
	end
end
--[[
	Resets the temporary state of the controller.
	This is used when the player leaves building mode, changes block,
	or switches into delete mode. I reset the preview-related values
	here so an old CFrame, selection or validity result can't leak
	into the next placement.
	The selected block index itself isn't reset, which is why the
	system can remember the last block when Q is pressed again.
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
	self._previewTrove:Clean()
	if self._deleteHighlight then
		self._deleteHighlight.Enabled = false
		self._deleteHighlight.Adornee = nil
	end
end
--[[
	Completely removes the controller.
	Unlike Cancel(), which only resets the current building state,
	Destroy() is meant for when the entire system is no longer needed.
	Trove then takes care of the Heartbeat connection, input
	connection, respawn connection, highlight and any other objects
	registered with it.
]]
function PlacementController.Destroy(
	self: PlacementControllerType
)
	self._trove:Destroy()
end
-- The module creates its controller immediately, so requiring this
-- module gives the caller a ready-to-use building system.
return PlacementController.new()
