-- Connected Discord-GitHub | Discord: @lilledal_ | Roblox: @Hasaaawuw72
--!strict

--[[
    BUILDING / PLACEMENT CONTROLLER

    Client-side building controller for the demo.
    Handles block selection, grid snapping, rotation, placement,
    collision checks, preview movement, and deletion.

    The controller uses CFrame math for positioning and rotation,
    spatial queries for collision detection, CollectionService for
    ownership/tagging, and Trove for connection cleanup.

    Open-source dependency:
    Trove by Stephen Leitnick (Sleitnick), from RbxUtil.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- Folders and dependencies
local Blocks = ReplicatedStorage:WaitForChild("Blocks")
local Trove = require(ReplicatedStorage:WaitForChild("Trove"))
local player = Players.LocalPlayer

-- Configuration
local GRID_SIZES = {1, 2, 4, 8}
local BUILD_RANGE = 70
local PREVIEW_LERP_SPEED = 20
local PREVIEW_TRANSPARENCY = 0.5
local COLLISION_EPSILON = 0.02
local MIN_CHECK_AXIS = 0.05
local PLACED_FOLDER_NAME = "ClientPlacedBlocks"
local PLACED_BLOCK_TAG = "DemoPlacedBlock"

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
    _visualPosition: Vector3?,
    _visualRotation: CFrame?,
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

-- Creates the folder used for locally placed demo blocks.
-- Keeping placed objects together makes cleanup, filtering, and inspection easier.
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

-- Reads block templates once per selection/cycle operation.
-- Sorting gives players a predictable order instead of depending on hierarchy order.
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

-- Converts the mouse position into a camera ray.
-- GetMouseLocation includes the top-left GUI inset, so the inset is removed
-- before ViewportPointToRay is called.
local function GetMouseHit(
    camera: Camera?,
    params: RaycastParams
): RaycastResult?
    if not camera then
        return nil
    end

    local mousePosition = UserInputService:GetMouseLocation()
    local inset = GuiService:GetGuiInset()

    local viewportX = mousePosition.X - inset.X
    local viewportY = mousePosition.Y - inset.Y

    local ray = camera:ViewportPointToRay(viewportX, viewportY)

    return workspace:Raycast(
        ray.Origin,
        ray.Direction * BUILD_RANGE,
        params
    )
end

-- Finds the world axis most closely represented by a surface normal.
-- This is useful because grid snapping should not modify the coordinate
-- belonging to the surface being attached to.
local function GetDominantNormalAxis(
    normal: Vector3
): "X" | "Y" | "Z"
    local x = math.abs(normal.X)
    local y = math.abs(normal.Y)
    local z = math.abs(normal.Z)

    if x >= y and x >= z then
        return "X"
    end

    if y >= z then
        return "Y"
    end

    return "Z"
end

-- Snaps the two free axes to the selected grid size.
-- The surface axis stays untouched so the block can sit directly against
-- the face that the player is pointing at.
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

-- Calculates how far the block's center must be moved along a surface normal.
-- The absolute normal components project the rotated half-extents onto that normal.
local function GetSurfaceOffset(
    normal: Vector3,
    worldSize: Vector3
): number
    local halfSize = worldSize / 2

    return math.abs(normal.X) * halfSize.X
        + math.abs(normal.Y) * halfSize.Y
        + math.abs(normal.Z) * halfSize.Z
end

-- Rotating a rectangular model changes its axis-aligned bounding size.
-- Multiplying the size by the rotation gives the correct extents needed
-- for the overlap query.
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

-- Removes scripts from the preview and disables all physical interaction.
-- The preview is visual only, so it should never affect the real world.
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

-- Only changes the preview's color when its validity state changes.
-- This avoids recoloring every part every RenderStepped frame.
local function SetPreviewColor(
    model: Model?,
    isValid: boolean
)
    if not model then
        return
    end

    local color = if isValid
        then Color3.fromRGB(70, 255, 120)
        else Color3.fromRGB(255, 80, 80)

    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            object.Color = color
        end
    end
end

-- Walks upward from a raycast result until the owned placed model is found.
-- Ownership is checked before deletion so the demo cannot remove another
-- player's placed model.
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
        _visualPosition = nil,
        _visualRotation = nil,
        _targetCFrame = nil,
        _trove = Trove.new(),
        _previewTrove = nil,
        _raycastParams = RaycastParams.new(),
        _overlapParams = OverlapParams.new(),
    }, PlacementController) :: any

    -- A child Trove lets preview-specific objects be cleaned without
    -- destroying the controller's permanent connections.
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

-- Keeps the raycast and overlap filters synchronized with objects that should
-- never count as build targets, mainly the preview and the local character.
function PlacementController.UpdateFilters(self: PlacementControllerType)
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

function PlacementController.Start(self: PlacementControllerType)
    -- RenderStepped is used because preview movement is a client-side visual
    -- effect and should update in sync with rendered frames.
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

            -- Prevent building keys from firing while typing in a TextBox.
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

-- Central input dispatcher. Keeping input handling in one place makes the
-- controls easier to change without spreading key checks throughout the system.
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

function PlacementController.EquipLastBlock(self: PlacementControllerType)
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

function PlacementController.CycleBlock(self: PlacementControllerType)
    local blocks = GetBlockTemplates()

    assert(
        #blocks > 0,
        "No Model templates were found inside ReplicatedStorage.Blocks"
    )

    self._blockIndex = (self._blockIndex % #blocks) + 1
    self:SelectBlock(blocks[self._blockIndex])
end

-- Stores the template's bounding information separately from its pivot.
-- GetBoundingBox describes the physical bounds, while the pivot offset lets
-- us preserve the original model pivot when placing it.
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

function PlacementController.CycleGridSize(self: PlacementControllerType)
    self._gridIndex = (self._gridIndex % #GRID_SIZES) + 1
end

function PlacementController.ToggleDeleteMode(self: PlacementControllerType)
    local newDeleteState = not self._deleting

    self:Cancel()
    self._deleting = newDeleteState
end

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
    self._visualPosition = nil
    self._visualRotation = nil
    self._targetCFrame = nil
    self._canPlace = false
    self._lastValidPlacement = nil
    self._placing = true

    self:UpdateFilters()
end

function PlacementController.Rotate(self: PlacementControllerType)
    self._rotation = (self._rotation + 90) % 360

    -- Rotation is stored as a CFrame so it can be composed directly with
    -- the target position instead of repeatedly converting angles later.
    self._rotationCFrame = CFrame.Angles(
        0,
        math.rad(self._rotation),
        0
    )
end

function PlacementController.CanPlace(self: PlacementControllerType): boolean
    return self._placing
        and self._preview ~= nil
        and self._selectedBlock ~= nil
        and self._blockSize ~= nil
end

-- Performs a bounded spatial overlap query around the calculated placement.
-- The epsilon prevents tiny floating-point boundary intersections from
-- incorrectly blocking adjacent blocks.
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

-- Converts the raycast hit into the actual placement CFrame.
-- The order matters: calculate rotated bounds first, offset from the surface,
-- then snap the position, and finally apply the requested rotation.
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

    local targetCFrame =
        CFrame.new(snappedPosition)
        * self._rotationCFrame

    return targetCFrame, worldSize
end

-- Smooths only the visual preview. The real placement always uses the exact
-- target CFrame, preventing interpolation from affecting collision accuracy.
function PlacementController.UpdatePreviewTransform(
    self: PlacementControllerType,
    targetCFrame: CFrame,
    deltaTime: number
)
    -- Exponential smoothing gives similar behavior across different frame rates.
    local alpha = 1 - math.exp(
        -PREVIEW_LERP_SPEED * deltaTime
    )

    local targetPosition = targetCFrame.Position
    local targetRotation = self._rotationCFrame

    if self._visualPosition then
        self._visualPosition = self._visualPosition:Lerp(
            targetPosition,
            alpha
        )
    else
        self._visualPosition = targetPosition
    end

    if self._visualRotation then
        self._visualRotation = self._visualRotation:Lerp(
            targetRotation,
            alpha
        )
    else
        self._visualRotation = targetRotation
    end

    local preview = self._preview

    if not preview then
        return
    end

    local visualPosition = self._visualPosition
    local visualRotation = self._visualRotation

    if not visualPosition or not visualRotation then
        return
    end

    local pivotOffset = self._blockPivotOffset or CFrame.new()

    preview:PivotTo(
        CFrame.new(visualPosition)
        * visualRotation
        * pivotOffset
    )
end

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

    -- Updating only when the target changes avoids unnecessary property writes.
    if highlight.Adornee ~= targetModel then
        highlight.Adornee = targetModel
        highlight.Enabled = targetModel ~= nil
    end
end

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

-- Clones the original template rather than the preview.
-- This guarantees that preview-only properties such as transparency,
-- collision settings, and modified colors never become permanent.
function PlacementController.Place(self: PlacementControllerType)
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

    -- Attributes and CollectionService tags provide lightweight metadata
    -- that can be inspected by other systems without another data structure.
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

function PlacementController.Delete(self: PlacementControllerType)
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

-- Resets temporary state while keeping the controller and its permanent
-- connections alive. This is used when changing block, mode, or cancelling.
function PlacementController.Cancel(self: PlacementControllerType)
    self._placing = false
    self._canPlace = false
    self._deleting = false

    self._selectedBlock = nil
    self._preview = nil
    self._lastValidPlacement = nil

    self._blockSize = nil
    self._blockPivotOffset = nil

    self._visualPosition = nil
    self._visualRotation = nil
    self._targetCFrame = nil

    self._previewTrove:Clean()
    self:UpdateFilters()

    if self._deleteHighlight then
        self._deleteHighlight.Enabled = false
        self._deleteHighlight.Adornee = nil
    end
end

-- Completely destroys the controller and every connection/temporary object
-- registered with its Trove. This prevents RenderStepped/InputBegan leaks.
function PlacementController.Destroy(self: PlacementControllerType)
    self:Cancel()
    self._trove:Destroy()
end

local controller = PlacementController.new()

return controller
