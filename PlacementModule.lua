-- Connected Discord-GitHub | Discord: @lilledal_ | Roblox: @Hasaaawuw72
--!strict

--[[
	BUILDING / PLACEMENT CONTROLLER

	Client-side controller for the building system used in this demo.
	It handles player input, raycasting, grid snapping, rotation,
	collision checking, preview movement, placement, and deletion.

	The preview is kept separate from the actual placed model. Placement
	is calculated from a target CFrame which is also used for collision
	checking, while the preview is smoothly moved toward that target
	only for visual feedback.

	Open-source dependency:
	Trove by Stephen Leitnick (Sleitnick), from RbxUtil.
	Used for managing connections and temporary instances.
	https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove
]]


--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

--// Dependencies / folders
-- Blocks is treated as data: templates are never moved into Workspace.
-- The placed folder is created once so delete mode can distinguish objects
-- created by this controller from arbitrary map Models.
local Blocks = ReplicatedStorage:WaitForChild("Blocks")
local Trove = require(ReplicatedStorage:WaitForChild("Trove"))

--// Player
local player = Players.LocalPlayer

--// Configuration
local GRID_SIZES = {1, 2, 4, 8}
local BUILD_RANGE = 70
local PREVIEW_LERP_SPEED = 20
local PREVIEW_TRANSPARENCY = 0.5
local COLLISION_EPSILON = 0.02
local MIN_CHECK_AXIS = 0.05
local PLACED_FOLDER_NAME = "ClientPlacedBlocks"
local PLACED_BLOCK_TAG = "DemoPlacedBlock"

--// Types
type TroveType = typeof(Trove.new())
type ControllerData = {
	_gridIndex: number,
	_rotation: number,
	_rotationCFrame: CFrame,
	_blockIndex: number,
	_selectedBlock: Model?,
	_preview: Model?,
	_deleteHighlight: Highlight?,
	_placedFolder: Folder?,
	_placing: boolean,
	_canPlace: boolean,
	_deleting: boolean,
	_lastValidPlacement: boolean?,
	_blockSize: Vector3?,
	_blockPivotOffset: CFrame?,
	_currentCFrame: CFrame?,
	_targetCFrame: CFrame?,
	_trove: TroveType,
	_previewTrove: TroveType,
	_raycastParams: RaycastParams,
	_overlapParams: OverlapParams,
}

local PlacementController = {}
PlacementController.__index = PlacementController
type PlacementControllerType = typeof(setmetatable(
	{} :: ControllerData,
	PlacementController
	))

--[[
	Returns a dedicated Workspace folder for this demo controller.
	The folder is deliberately separate from the map. Delete mode later uses
	the folder together with a CollectionService tag and owner attribute, so
	a click cannot accidentally destroy an NPC, building prop, or terrain Model.
]]
local function GetPlacedFolder(): Folder
	local existing = workspace:FindFirstChild(PLACED_FOLDER_NAME)
	if existing then
		assert(
			existing:IsA("Folder"),
			`Workspace.{PLACED_FOLDER_NAME} must be a Folder`
		)
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = PLACED_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

--[[
	Gets only Model templates from ReplicatedStorage.Blocks and sorts them
	by name. Filtering here prevents a non-Model child from consuming a
	selection index, while sorting makes F-cycling deterministic between runs.
]]
local function GetBlockTemplates(): {Model}
	local templates: {Model} = {}
	for _, child in Blocks:GetChildren() do
		if child:IsA("Model") then
			table.insert(templates, child)
		end
	end
	table.sort(templates, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return templates
end

--[[
	Builds a camera ray from the actual mouse position.
	GetMouseLocation() includes the top-left GUI inset on Roblox clients,
	while ViewportPointToRay() expects viewport-relative coordinates. Removing
	the inset keeps the ray aligned with the cursor instead of being vertically
	offset by the CoreGui/top-bar region.
]]
local function GetMouseHit(
	camera: Camera?,
	params: RaycastParams
): RaycastResult?
	if not camera then
		return nil
	end
	local mousePosition = UserInputService:GetMouseLocation()
	local topLeftInset = GuiService:GetGuiInset()
	local viewportX = mousePosition.X - topLeftInset.X
	local viewportY = mousePosition.Y - topLeftInset.Y
	local ray = camera:ViewportPointToRay(viewportX, viewportY)
	return workspace:Raycast(
		ray.Origin,
		ray.Direction * BUILD_RANGE,
		params
	)
end

--[[
	Chooses the dominant axis of a surface normal.
	Grid snapping should preserve the coordinate that represents the surface
	depth. On a flat floor this is Y; on a vertical wall it is X or Z. Picking
	the dominant component also behaves predictably on sloped surfaces instead
	of requiring the normal to be almost perfectly axis-aligned.
]]
local function GetDominantNormalAxis(
	normal: Vector3
): "X" | "Y" | "Z"
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)
	if absX >= absY and absX >= absZ then
		return "X"
	end
	if absY >= absZ then
		return "Y"
	end
	return "Z"
end

--[[
	Snaps world-space coordinates while preserving the dominant surface axis.
	The untouched axis is intentional: if X represents wall depth, rounding X
	would move the preview away from the exact raycast surface. The other two
	axes are quantized to the selected build grid.
]]
local function SnapPositionToGrid(
	position: Vector3,
	gridSize: number,
	normal: Vector3
): Vector3
	local axis = GetDominantNormalAxis(normal)
	local x = if axis == "X"
		then position.X
		else math.round(position.X / gridSize) * gridSize
	local y = if axis == "Y"
		then position.Y
		else math.round(position.Y / gridSize) * gridSize
	local z = if axis == "Z"
		then position.Z
		else math.round(position.Z / gridSize) * gridSize
	return Vector3.new(x, y, z)
end

--[[
	Returns the distance an axis-aligned bounding box extends along a normal.
	This is the support value of the box: |nx|*hx + |ny|*hy + |nz|*hz.
	It is more robust than multiplying the normal by a Vector3 because
	Vector3-vector multiplication is not the scalar offset needed here.
	For floors the result becomes half-height; for walls it becomes the
	relevant half-width, and diagonal normals remain mathematically valid.
]]
local function GetSurfaceOffset(
	normal: Vector3,
	worldSize: Vector3
): number
	local halfSize = worldSize / 2
	return (
		math.abs(normal.X) * halfSize.X
			+ math.abs(normal.Y) * halfSize.Y
			+ math.abs(normal.Z) * halfSize.Z
	)
end

--[[
	Rotating a Vector3 by a CFrame produces the rotated dimensions around
	the selected Y axis. Taking absolute values converts signed extents into
	a world-space bounding size suitable for overlap queries.
]]
local function GetRotatedWorldSize(
	size: Vector3,
	rotation: CFrame
): Vector3
	local rotatedSize = rotation * size
	return Vector3.new(
		math.abs(rotatedSize.X),
		math.abs(rotatedSize.Y),
		math.abs(rotatedSize.Z)
	)
end

--[[
	Prepares a cloned Model to become a purely visual preview.
	Script descendants are removed so a template containing executable
	content cannot accidentally create a second runtime controller when
	cloned locally. Physics interaction is disabled because the preview is
	feedback, not a physical object, and query exclusion prevents it from
	intercepting the controller's own raycast/overlap checks.
]]
local function PreparePreview(model: Model)
	for _, object in model:GetDescendants() do
		if object:IsA("BaseScript") or object:IsA("ModuleScript") then
			object:Destroy()
			continue
		end
		if not object:IsA("BasePart") then
			continue
		end
		object.Anchored = true
		object.CanCollide = false
		object.CanTouch = false
		object.CanQuery = false
		object.Massless = true
		object.Transparency = PREVIEW_TRANSPARENCY
	end
end

--[[
	Updates the preview colour only when its validity state changes.
	Update() executes every render frame, so skipping identical property writes
	reduces replicated/client property churn for models containing many parts.
	The colours communicate state to the player without changing placement data.
]]
local function SetPreviewColor(
	model: Model?,
	isValid: boolean
)
	if not model then
		return
	end
	local targetColor = if isValid
		then Color3.fromRGB(70, 255, 120)
		else Color3.fromRGB(255, 80, 80)
	for _, object in model:GetDescendants() do
		if object:IsA("BasePart") then
			object.Color = targetColor
		end
	end
end

--[[
	Searches upward for the actual model this controller placed.
	This is intentionally tag-based instead of trusting the first Model
	ancestor. A map can contain nested Models, while the placement demo can
	safely restrict deletion to objects carrying the controller's tag.
]]
local function FindPlacedModel(
	instance: Instance?,
	expectedOwnerId: number
): Model?
	local current = instance
	while current and current ~= workspace do
		if current:IsA("Model")
			and CollectionService:HasTag(current, PLACED_BLOCK_TAG)
			and current:GetAttribute("PlacedByUserId") == expectedOwnerId
		then
			return current
		end
		current = current.Parent
	end
	return nil
end

--[[
	Creates a controller with explicit state rather than relying on globals.
	The separate preview Trove is a lifecycle boundary: changing the selected
	block should destroy only the temporary clone, while the main Trove still
	owns input connections, render updates and the reusable delete Highlight.
]]

function PlacementController.new(): PlacementControllerType
	local self = setmetatable({
		_gridIndex = 1,
		_rotation = 0,
		_rotationCFrame = CFrame.new(),
		_blockIndex = 0,
		_selectedBlock = nil,
		_preview = nil,
		_deleteHighlight = nil,
		_placedFolder = GetPlacedFolder(),
		_placing = false,
		_canPlace = false,
		_deleting = false,
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
	self._previewTrove = self._trove:Extend()
	self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self._raycastParams.IgnoreWater = true
	self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	self._overlapParams.MaxParts = 32
	self._overlapParams.RespectCanCollide = true
	local highlight = self._trove:Add(Instance.new("Highlight"))
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 65, 65)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = workspace
	self._deleteHighlight = highlight
	self:Start()
	return self
end

--[[
	Builds a single exclusion list shared by the raycast and overlap query.
	The Character must be ignored so clicking one's own body cannot become a
	build surface. The preview must also be ignored or the transparent clone
	could intercept the cursor ray before the real map surface is reached.
]]

function PlacementController.UpdateFilters(
	self: PlacementControllerType
)
	local filterObjects: {Instance} = {}
	if self._preview then
		table.insert(filterObjects, self._preview)
	end
	if player.Character then
		table.insert(filterObjects, player.Character)
	end
	self._raycastParams.FilterDescendantsInstances = filterObjects
	self._overlapParams.FilterDescendantsInstances = filterObjects
end

--[[
	Starts the runtime loop and input layer.
	RenderStepped is used for this controller because the preview is purely
	client-side visual feedback. Updating immediately before rendering avoids
	a one-frame visual delay compared with a general simulation heartbeat.
]]

function PlacementController.Start(
	self: PlacementControllerType
)
	self._trove:Add(
		RunService.RenderStepped:Connect(function(deltaTime)
			self:Update(deltaTime)
		end)
	)
	self._trove:Add(
		UserInputService.InputBegan:Connect(function(
			input: InputObject,
			gameProcessed: boolean
		)
			if gameProcessed then
				return
			end
			if UserInputService:GetFocusedTextBox() then
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
	Translates raw input into state-machine commands.
	The input function deliberately contains no placement math. This separation
	means adding a new control does not require touching collision, raycasting,
	or preview logic, which keeps the controller easier to reason about.
]]

function PlacementController.ProcessInput(
	self: PlacementControllerType,
	input: InputObject
)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if self._deleting then
			self:Delete()
		else
			self:Place()
		end
	end
	if input.KeyCode == Enum.KeyCode.F then
		if self._placing then
			self:CycleBlock()
		end
	end
	if input.KeyCode == Enum.KeyCode.R then
		if self._placing then
			self:Rotate()
		end
	end
	if input.KeyCode == Enum.KeyCode.G then
		if self._placing then
			self:CycleGridSize()
		end
	end
	if input.KeyCode == Enum.KeyCode.X then
		self:ToggleDeleteMode()
	end
	if input.KeyCode == Enum.KeyCode.Q then
		if self._placing then
			self:Cancel()
		else
			self:EquipLastBlock()
		end
	end
end

--[[
	Enters placement with the last valid block selection.
	The index is retained across Q-cancel cycles so the controller remembers
	the user's last tool choice. An invalid or out-of-range index falls back
	to the first available Model template.
]]

function PlacementController.EquipLastBlock(
	self: PlacementControllerType
)
	local blocks = GetBlockTemplates()
	assert(
		#blocks > 0,
		"No Model templates were found inside ReplicatedStorage.Blocks"
	)
	if self._blockIndex < 1 or self._blockIndex > #blocks then
		self._blockIndex = 1
	end
	self:SelectBlock(blocks[self._blockIndex])
end

--[[
	Moves to the next sorted template using modulo arithmetic.
	Keeping the index inside [1, #blocks] avoids the common off-by-one case
	where pressing F on the last item produces index #blocks + 1.
]]

function PlacementController.CycleBlock(
	self: PlacementControllerType
)
	local blocks = GetBlockTemplates()
	assert(
		#blocks > 0,
		"No Model templates were found inside ReplicatedStorage.Blocks"
	)
	self._blockIndex = (self._blockIndex % #blocks) + 1
	self:SelectBlock(blocks[self._blockIndex])
end

--[[
	Switches the active Model and caches geometry that never needs to be
	recomputed every frame.
	GetBoundingBox supplies the template's oriented bounds, while ToObjectSpace
	stores the relationship between the bounding-box CFrame and the model pivot.
	That pivot offset is reapplied when both preview and final models move.
]]

function PlacementController.SelectBlock(
	self: PlacementControllerType,
	blockTemplate: Model
)
	self:Cancel()
	self._selectedBlock = blockTemplate
	self._placing = true
	local blockCFrame, blockSize = blockTemplate:GetBoundingBox()
	self._blockSize = blockSize
	self._blockPivotOffset = blockCFrame:ToObjectSpace(
		blockTemplate:GetPivot()
	)
	self:CreatePreview(blockTemplate)
end

--[[
	Cycles between a small set of intentional grid sizes.
	The placement algorithm reads only the current grid value, so the control
	scheme can change later without coupling input handling to snapping math.
]]

function PlacementController.CycleGridSize(
	self: PlacementControllerType
)
	self._gridIndex = (self._gridIndex % #GRID_SIZES) + 1
end

--[[
	Toggles between placement and delete state.
	Cancel() clears all transient placement data, so the desired delete state is
	saved first and restored afterward. This guarantees the old preview cannot
	remain interactive when the user switches modes.
]]

function PlacementController.ToggleDeleteMode(
	self: PlacementControllerType
)
	local newDeleteState = not self._deleting
	self:Cancel()
	self._deleting = newDeleteState
end

--[[
	Creates a visual clone without mutating the source template.
	The preview Trove owns the clone, making block switching O(1) in controller
	state: clean the old preview, create the new clone, then rebuild filters.
]]

function PlacementController.CreatePreview(
	self: PlacementControllerType,
	blockTemplate: Model
)
	self._previewTrove:Clean()
	local preview = blockTemplate:Clone()
	PreparePreview(preview)
	self._preview = preview
	self._previewTrove:Add(preview)
	self._rotation = 0
	self._rotationCFrame = CFrame.new()
	self._currentCFrame = nil
	self._targetCFrame = nil
	self._canPlace = false
	self._lastValidPlacement = nil
	self._placing = true
	self:UpdateFilters()
end

--[[
	Applies one 90-degree Y rotation to the placement basis.
	Keeping rotation as an integer degree value gives the UI a simple cyclic
	state, while the cached CFrame lets placement math use matrix operations
	instead of reconstructing angles at every calculation.
]]

function PlacementController.Rotate(
	self: PlacementControllerType
)
	self._rotation = (self._rotation + 90) % 360
	self._rotationCFrame = CFrame.Angles(
		0,
		math.rad(self._rotation),
		0
	)
end

--[[
	Validates that the controller has enough cached state to calculate a target.
	This guard centralizes the preconditions shared by Update and Place, so
	neither function needs to duplicate a chain of nil checks.
]]

function PlacementController.CanPlace(
	self: PlacementControllerType
): boolean
	return (
		self._placing
			and self._preview ~= nil
			and self._selectedBlock ~= nil
			and self._blockSize ~= nil
	)
end

--[[
	Checks whether the target bounding box is free.
	The query box is contracted by a tiny epsilon, allowing two blocks to touch
	at exactly the same face without floating-point contact being interpreted as
	an overlap. RespectCanCollide filters the query toward actual physical
	blockers instead of decorative, non-collidable parts.
]]

function PlacementController.CheckCollisions(
	self: PlacementControllerType,
	cframe: CFrame,
	size: Vector3
): boolean
	local checkSize = Vector3.new(
		math.max(size.X - COLLISION_EPSILON, MIN_CHECK_AXIS),
		math.max(size.Y - COLLISION_EPSILON, MIN_CHECK_AXIS),
		math.max(size.Z - COLLISION_EPSILON, MIN_CHECK_AXIS)
	)
	local parts = workspace:GetPartBoundsInBox(
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
	Calculates the exact target CFrame from one raycast result.
	The steps are deliberately ordered:
	1. rotate the cached size to get world extents,
	2. push the box out of the surface using its support distance,
	3. snap the non-depth axes to the selected grid,
	4. compose position and 90-degree rotation into one CFrame.
	That single CFrame becomes the source of truth for preview placement,
	collision validation and the final cloned model.
]]

function PlacementController.ComputeTargetCFrame(
	self: PlacementControllerType,
	result: RaycastResult
): (CFrame, Vector3)
	local blockSize = assert(
		self._blockSize,
		"Block size is required before computing placement"
	)
	local worldSize = GetRotatedWorldSize(
		blockSize,
		self._rotationCFrame
	)
	local surfaceOffset = GetSurfaceOffset(
		result.Normal,
		worldSize
	)
	local surfacePosition =
		result.Position
		+ result.Normal * surfaceOffset
	local gridSize = GRID_SIZES[self._gridIndex]
	local snappedPosition = SnapPositionToGrid(
		surfacePosition,
		gridSize,
		result.Normal
	)
	local targetCFrame = CFrame.new(snappedPosition)
		* self._rotationCFrame
	return targetCFrame, worldSize
end

--[[
	Moves the preview using frame-rate-independent visual interpolation.
	The interpolation alpha is clamped to 1 so a large frame time can never
	produce an invalid Lerp fraction. Importantly, only the preview is smoothed:
	the authoritative target remains the exact CFrame returned by the math above.
]]

function PlacementController.UpdatePreviewTransform(
	self: PlacementControllerType,
	targetCFrame: CFrame,
	deltaTime: number
)
	if self._currentCFrame then
		local alpha = math.min(
			deltaTime * PREVIEW_LERP_SPEED,
			1
		)
		self._currentCFrame = self._currentCFrame:Lerp(
			targetCFrame,
			alpha
		)
	else
		self._currentCFrame = targetCFrame
	end
	local currentCFrame = self._currentCFrame
	local preview = self._preview
	if not currentCFrame or not preview then
		return
	end
	local pivotOffset = self._blockPivotOffset or CFrame.new()
	preview:PivotTo(
		currentCFrame * pivotOffset
	)
end

--[[
	Handles delete-mode targeting.
	The same camera ray used by placement is used here, but the result is passed
	through FindPlacedModel(). That extra ownership check is the safety boundary
	that stops X + click from deleting unrelated map content.
]]

function PlacementController.UpdateDeleteMode(
	self: PlacementControllerType
)
	local highlight = self._deleteHighlight
	if not self._deleting or not highlight then
		return
	end
	local result = GetMouseHit(
		workspace.CurrentCamera,
		self._raycastParams
	)
	local targetModel = if result
		then FindPlacedModel(
			result.Instance,
			player.UserId
		)
		else nil
	if highlight.Adornee ~= targetModel then
		highlight.Adornee = targetModel
		highlight.Enabled = targetModel ~= nil
	end
end

--[[
	Updates the entire placement state once per render frame.
	Placement and delete mode are exclusive branches. This keeps the two input
	interpretations isolated and means collision work is skipped completely
	while the user is browsing delete targets.
]]

function PlacementController.Update(
	self: PlacementControllerType,
	deltaTime: number
)
	if self._deleting then
		self:UpdateDeleteMode()
		return
	end
	if not self:CanPlace() then
		return
	end
	local result = GetMouseHit(
		workspace.CurrentCamera,
		self._raycastParams
	)
	local preview = self._preview
	if not result then
		self._canPlace = false
		if preview then
			preview.Parent = nil
		end
		if self._lastValidPlacement ~= false then
			self._lastValidPlacement = false
			SetPreviewColor(preview, false)
		end
		return
	end
	if preview and preview.Parent ~= workspace then
		preview.Parent = workspace
	end
	local targetCFrame, worldSize =
		self:ComputeTargetCFrame(result)
	self._targetCFrame = targetCFrame
	self:UpdatePreviewTransform(
		targetCFrame,
		deltaTime
	)
	self._canPlace = self:CheckCollisions(
		targetCFrame,
		worldSize
	)
	if self._lastValidPlacement ~= self._canPlace then
		self._lastValidPlacement = self._canPlace
		SetPreviewColor(preview, self._canPlace)
	end
end

--[[
	Commits a placement as a new Model instance.
	The preview is never promoted into the real object. Cloning the original
	template guarantees that temporary preview properties such as transparency,
	Anchored, CanQuery and colour do not leak into the final block.

	This demo intentionally performs the commit locally. In a production
	multiplayer system, Place() should instead request a server-side commit and
	the server should recalculate and validate the CFrame before cloning.
]]

function PlacementController.Place(
	self: PlacementControllerType
)
	if not self:CanPlace() or not self._canPlace then
		return
	end
	local selectedBlock = self._selectedBlock
	local targetCFrame = self._targetCFrame
	local pivotOffset = self._blockPivotOffset
	local placedFolder = self._placedFolder
	if not selectedBlock
		or not targetCFrame
		or not pivotOffset
		or not placedFolder
	then
		return
	end
	local placedModel = selectedBlock:Clone()
	placedModel:PivotTo(
		targetCFrame * pivotOffset
	)
	placedModel:SetAttribute(
		"PlacedByUserId",
		player.UserId
	)
	placedModel:SetAttribute(
		"PlacedFromTemplate",
		selectedBlock.Name
	)
	CollectionService:AddTag(
		placedModel,
		PLACED_BLOCK_TAG
	)
	placedModel.Parent = placedFolder
end

--[[
	Deletes only a model produced by this controller for the current player.
	The owner attribute and CollectionService tag form two independent checks:
	the tag describes the object category, while the attribute describes who
	created it. This is intentionally stricter than deleting any Model hit by
	the mouse ray.
]]

function PlacementController.Delete(
	self: PlacementControllerType
)
	if not self._deleting then
		return
	end
	local result = GetMouseHit(
		workspace.CurrentCamera,
		self._raycastParams
	)
	if not result then
		return
	end
	local targetModel = FindPlacedModel(
		result.Instance,
		player.UserId
	)
	if targetModel then
		targetModel:Destroy()
		local highlight = self._deleteHighlight
		if highlight then
			highlight.Adornee = nil
			highlight.Enabled = false
		end
	end
end

--[[
	Cancels only the transient placement state.
	The selected template index survives the cancel so Q can reopen the last
	block, while preview geometry, collision status and delete highlighting
	are fully cleared. Filters are rebuilt after the preview is destroyed so
	no stale Instance reference remains in either query object.
]]

function PlacementController.Cancel(
	self: PlacementControllerType
)
	self._placing = false
	self._canPlace = false
	self._deleting = false
	self._selectedBlock = nil
	self._preview = nil
	self._lastValidPlacement = nil
	self._blockSize = nil
	self._blockPivotOffset = nil
	self._currentCFrame = nil
	self._targetCFrame = nil
	self._previewTrove:Clean()
	self:UpdateFilters()
	if self._deleteHighlight then
		self._deleteHighlight.Enabled = false
		self._deleteHighlight.Adornee = nil
	end
end

--[[
	Releases the controller's entire lifetime graph.
	Trove disconnects input/render connections, destroys the reusable Highlight,
	and cleans the preview sub-Trove. Cancel() is called first so the controller
	never leaves a visible preview behind while its connections are removed.
]]

function PlacementController.Destroy(
	self: PlacementControllerType
)
	self:Cancel()
	self._trove:Destroy()
end

--[[
	The module creates its controller when required, so the demo only needs
	this submitted ModuleScript plus the credited open-source Trove dependency.
	The LocalScript only needs to require this module.
]]

local controller = PlacementController.new()

return controller
