```lua
-- Connected Discord-GitHub | Discord: @lilledal_ | Roblox: @Hasaaawuw72
--!strict

--[[
    BUILDING / PLACEMENT CONTROLLER

    Client-side building controller for the demo.
    Handles block selection, grid snapping, rotation, placement,
    collision checks, preview movement, and deletion.

    The controller uses CFrame math for positioning, spatial queries
    for collision detection, CollectionService for ownership metadata,
    and Trove for cleaning up connections and temporary instances.

    Open-source dependency:
    Trove by Stephen Leitnick (Sleitnick), from RbxUtil.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Stores block templates and shared dependencies.
local RunService = game:GetService("RunService") -- Updates the visual preview every rendered frame.
local UserInputService = game:GetService("UserInputService") -- Reads keyboard and mouse input.
local GuiService = game:GetService("GuiService") -- Provides the screen inset needed for accurate mouse rays.
local CollectionService = game:GetService("CollectionService") -- Tags placed models so they can be identified later.
local Players = game:GetService("Players") -- Provides access to the local player.

-- Dependencies
local Blocks = ReplicatedStorage:WaitForChild("Blocks") -- Folder containing the models players can place.
local Trove = require(ReplicatedStorage:WaitForChild("Trove")) -- Handles cleanup of connections and temporary objects.
local player = Players.LocalPlayer -- This controller runs on the client, so we use the local player.

-- Configuration
local GRID_SIZES = {1, 2, 4, 8} -- Available snapping sizes, from precise to larger building increments.
local BUILD_RANGE = 70 -- Maximum distance from the camera that the player can build.
local PREVIEW_LERP_SPEED = 20 -- Controls how quickly the visual preview follows the target.
local PREVIEW_TRANSPARENCY = 0.5 -- Makes the preview visually different from the real block.
local COLLISION_EPSILON = 0.02 -- Slightly shrinks collision checks to avoid floating-point edge cases.
local MIN_CHECK_AXIS = 0.05 -- Prevents an overlap box axis from becoming too small.
local PLACED_FOLDER_NAME = "ClientPlacedBlocks" -- Keeps placed demo blocks organized in Workspace.
local PLACED_BLOCK_TAG = "DemoPlacedBlock" -- Identifies models created by this building system.

type TroveType = typeof(Trove.new()) -- Infers the type returned by Trove.new().

type ControllerData = { -- Defines the internal state used by the controller.
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

local PlacementController = {} -- Class table containing all controller methods.
PlacementController.__index = PlacementController -- Metatable lookup lets instances use the methods above.

type PlacementControllerType = typeof(setmetatable( -- Gives Luau a useful type for controller instances.
    {} :: ControllerData,
    PlacementController
))

local function GetPlacedFolder(): Folder -- Returns the shared folder used for placed demo models.
    local existing = workspace:FindFirstChild(PLACED_FOLDER_NAME) -- Reuse the folder if it already exists.

    if existing then
        assert(existing:IsA("Folder"), `Workspace.{PLACED_FOLDER_NAME} must be a Folder`) -- Fail early if the hierarchy is incorrect.
        return existing -- Avoid creating duplicate folders.
    end

    local folder = Instance.new("Folder") -- Create the container when the demo starts for the first time.
    folder.Name = PLACED_FOLDER_NAME -- Give the folder a predictable name.
    folder.Parent = workspace -- Put placed models into Workspace so they are visible.

    return folder -- Return the folder to the controller.
end

local function GetBlockTemplates(): {Model} -- Builds a sorted list of available building templates.
    local templates: {Model} = {} -- Explicitly typed list keeps strict Luau happy.

    for _, child in Blocks:GetChildren() do -- Only inspect direct children of the Blocks folder.
        if child:IsA("Model") then -- Ignore values, folders, and other unrelated instances.
            table.insert(templates, child) -- Add valid model templates to the list.
        end
    end

    table.sort(templates, function(a, b) -- Sort alphabetically for predictable cycling.
        return a.Name:lower() < b.Name:lower() -- Case-insensitive comparison avoids inconsistent ordering.
    end)

    return templates -- Return the current template list.
end

local function GetMouseHit( -- Converts the mouse position into a 3D raycast result.
    camera: Camera?,
    params: RaycastParams
): RaycastResult?
    if not camera then -- CurrentCamera can temporarily be unavailable during loading.
        return nil -- Without a camera there is no valid ray to cast.
    end

    local mousePosition = UserInputService:GetMouseLocation() -- Get the mouse position in screen coordinates.
    local inset = GuiService:GetGuiInset() -- Roblox UI occupies a small top-left screen inset.

    local viewportX = mousePosition.X - inset.X -- Convert screen X into viewport X.
    local viewportY = mousePosition.Y - inset.Y -- Convert screen Y into viewport Y.

    local ray = camera:ViewportPointToRay(viewportX, viewportY) -- Convert the 2D mouse position into a 3D camera ray.

    return workspace:Raycast( -- Cast the ray into the world using our filtering rules.
        ray.Origin,
        ray.Direction * BUILD_RANGE,
        params
    )
end

local function GetDominantNormalAxis( -- Determines which world axis the surface is mainly facing.
    normal: Vector3
): "X" | "Y" | "Z"
    local x = math.abs(normal.X) -- Ignore direction and only compare the strength of each component.
    local y = math.abs(normal.Y)
    local z = math.abs(normal.Z)

    if x >= y and x >= z then -- X is the strongest surface-normal component.
        return "X"
    end

    if y >= z then -- Y is stronger than Z after X has already been rejected.
        return "Y"
    end

    return "Z" -- Z is the remaining dominant axis.
end

local function SnapPositionToGrid( -- Snaps free coordinates while preserving the surface coordinate.
    position: Vector3,
    gridSize: number,
    normal: Vector3
): Vector3
    local axis = GetDominantNormalAxis(normal) -- Find the axis that represents the surface.

    local x = if axis == "X" -- Do not snap X when building directly against an X-facing surface.
        then position.X
        else math.round(position.X / gridSize) * gridSize -- Snap other coordinates to the selected grid.

    local y = if axis == "Y" -- Preserve Y when the surface is horizontal.
        then position.Y
        else math.round(position.Y / gridSize) * gridSize

    local z = if axis == "Z" -- Preserve Z for Z-facing surfaces.
        then position.Z
        else math.round(position.Z / gridSize) * gridSize

    return Vector3.new(x, y, z) -- Reconstruct the final snapped position.
end

local function GetSurfaceOffset( -- Calculates how far the model center must sit away from the surface.
    normal: Vector3,
    worldSize: Vector3
): number
    local halfSize = worldSize / 2 -- Surface contact is based on the model's half-extents.

    return math.abs(normal.X) * halfSize.X -- Project the X extent onto the surface normal.
        + math.abs(normal.Y) * halfSize.Y -- Add the Y contribution.
        + math.abs(normal.Z) * halfSize.Z -- Add the Z contribution.
end

local function GetRotatedWorldSize( -- Gets the axis-aligned size after applying a rotation.
    size: Vector3,
    rotation: CFrame
): Vector3
    local rotatedSize = rotation * size -- CFrame multiplication rotates the Vector3 by the rotation.

    return Vector3.new( -- Use absolute values because bounding extents cannot be negative.
        math.abs(rotatedSize.X),
        math.abs(rotatedSize.Y),
        math.abs(rotatedSize.Z)
    )
end

local function PreparePreview(model: Model) -- Converts a cloned template into a visual-only preview.
    for _, object in model:GetDescendants() do -- Process every part/script inside the model.
        if object:IsA("BaseScript") or object:IsA("ModuleScript") then -- Preview copies should not execute game logic.
            object:Destroy() -- Remove scripts so the preview cannot accidentally run duplicated logic.
            continue
        end

        if not object:IsA("BasePart") then -- Attachments and other instances do not need physical settings.
            continue
        end

        object.Anchored = true -- Prevent physics from moving the preview.
        object.CanCollide = false -- The preview must not physically block the player.
        object.CanTouch = false -- Avoid unnecessary touch events from the preview.
        object.CanQuery = false -- Prevent the preview from appearing in our own spatial queries.
        object.Massless = true -- Removes unnecessary physics mass even though it is anchored.
        object.Transparency = PREVIEW_TRANSPARENCY -- Make it visually clear that this is not placed yet.
    end
end

local function SetPreviewColor( -- Changes the preview color based on placement validity.
    model: Model?,
    isValid: boolean
)
    if not model then -- Nothing to recolor when no preview exists.
        return
    end

    local color = if isValid -- Green represents a valid position, red represents an invalid one.
        then Color3.fromRGB(70, 255, 120)
        else Color3.fromRGB(255, 80, 80)

    for _, object in model:GetDescendants() do -- Update all visible parts in the model.
        if object:IsA("BasePart") then
            object.Color = color -- Only BaseParts have a Color property.
        end
    end
end

local function FindPlacedModel( -- Finds the placed model belonging to the current player.
    instance: Instance?,
    expectedOwnerId: number
): Model?
    local current = instance -- Start with the part hit by the mouse.

    while current and current ~= workspace do -- Walk toward the root until the model is found.
        if current:IsA("Model") -- It must be a model...
            and CollectionService:HasTag(current, PLACED_BLOCK_TAG) -- ...created by this building system...
            and current:GetAttribute("PlacedByUserId") == expectedOwnerId -- ...and owned by this player.
        then
            return current -- The correct placed model has been found.
        end

        current = current.Parent -- Move one level upward in the instance hierarchy.
    end

    return nil -- The clicked object was not one of the player's placed models.
end

function PlacementController.new(): PlacementControllerType -- Creates and initializes the controller.
    local self = setmetatable({
        _gridIndex = 1, -- Start with the first grid size.
        _rotation = 0, -- Models begin at zero degrees rotation.
        _rotationCFrame = CFrame.new(), -- Identity rotation means no rotation.
        _blockIndex = 0, -- No block has been selected initially.
        _selectedBlock = nil, -- Stores the original template currently being used.
        _preview = nil, -- Stores the temporary visual preview.
        _deleteHighlight = nil, -- Stores the Highlight used in delete mode.
        _placedFolder = GetPlacedFolder(), -- Create or reuse the placed-model container.
        _placing = false, -- Building mode starts disabled.
        _canPlace = false, -- No valid target exists yet.
        _deleting = false, -- Delete mode starts disabled.
        _lastValidPlacement = nil, -- Used to avoid repeated preview color updates.
        _blockSize = nil, -- Filled when a template is selected.
        _blockPivotOffset = nil, -- Preserves the template's original pivot relationship.
        _visualPosition = nil, -- Smoothed preview position.
        _visualRotation = nil, -- Smoothed preview rotation.
        _targetCFrame = nil, -- Exact CFrame used for collision checks and placement.
        _trove = Trove.new(), -- Main cleanup container for the controller.
        _previewTrove = nil, -- Separate cleanup container for preview objects.
        _raycastParams = RaycastParams.new(), -- Controls what the mouse ray can hit.
        _overlapParams = OverlapParams.new(), -- Controls collision overlap queries.
    }, PlacementController) :: any

    self._previewTrove = self._trove:Extend() -- Child Trove allows preview cleanup without destroying the controller.

    self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude -- Listed objects will be ignored by the ray.
    self._raycastParams.IgnoreWater = true -- Water is not useful as a building target.

    self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude -- Use the same exclusion concept for collision checks.
    self._overlapParams.MaxParts = 32 -- Bound the query so one placement cannot scan unlimited parts.
    self._overlapParams.RespectCanCollide = true -- Only physically relevant parts should block placement.

    local highlight = self._trove:Add(Instance.new("Highlight")) -- Create the delete-mode visual once.
    highlight.FillTransparency = 1 -- Only show the outline.
    highlight.OutlineColor = Color3.fromRGB(255, 65, 65) -- Red indicates deletion.
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- Respect walls and normal depth.
    highlight.Enabled = false -- Enable it only when a valid target is under the mouse.
    highlight.Parent = workspace -- Highlight must exist in the data model to render.

    self._deleteHighlight = highlight -- Store it so other methods can update it.

    self:Start() -- Connect input and frame-update events.

    return self -- Return the fully initialized controller instance.
end

function PlacementController.UpdateFilters(self: PlacementControllerType) -- Refreshes ignored instances.
    local filterObjects: {Instance} = {} -- New list prevents stale references.

    if self._preview then -- The preview should never be detected by its own raycast.
        table.insert(filterObjects, self._preview)
    end

    if player.Character then -- The local character should not block building rays.
        table.insert(filterObjects, player.Character)
    end

    self._raycastParams.FilterDescendantsInstances = filterObjects -- Apply the exclusions to raycasts.
    self._overlapParams.FilterDescendantsInstances = filterObjects -- Apply them to collision queries too.
end

function PlacementController.Start(self: PlacementControllerType) -- Connects the controller to Roblox events.
    self._trove:Add(
        RunService.RenderStepped:Connect(function(deltaTime) -- RenderStepped keeps visual movement smooth.
            self:Update(deltaTime) -- Recalculate the current preview or delete target.
        end)
    )

    self._trove:Add(
        UserInputService.InputBegan:Connect(function( -- Listen for keyboard and mouse input.
            input: InputObject,
            gameProcessed: boolean
        )
            if gameProcessed then -- Ignore inputs already consumed by Roblox UI.
                return
            end

            if UserInputService:GetFocusedTextBox() then -- Do not trigger build controls while typing.
                return
            end

            self:ProcessInput(input) -- Forward valid input to the central input handler.
        end)
    )

    self._trove:Add(
        player.CharacterAdded:Connect(function() -- Character references become invalid after respawning.
            self:UpdateFilters() -- Refresh the ignored instances after the new character exists.
        end)
    )

    self:UpdateFilters() -- Apply the initial raycast/overlap filters immediately.
end

function PlacementController.ProcessInput( -- Centralizes every building control.
    self: PlacementControllerType,
    input: InputObject
)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then -- Left click confirms an action.
        if self._deleting then
            self:Delete() -- Delete when delete mode is active.
        else
            self:Place() -- Otherwise attempt normal placement.
        end
    end

    if input.KeyCode == Enum.KeyCode.F then -- F cycles through available blocks.
        if self._placing then
            self:CycleBlock()
        end
    end

    if input.KeyCode == Enum.KeyCode.R then -- R rotates the selected block.
        if self._placing then
            self:Rotate()
        end
    end

    if input.KeyCode == Enum.KeyCode.G then -- G cycles grid sizes.
        if self._placing then
            self:CycleGridSize()
        end
    end

    if input.KeyCode == Enum.KeyCode.X then -- X toggles delete mode.
        self:ToggleDeleteMode()
    end

    if input.KeyCode == Enum.KeyCode.Q then -- Q cancels building or selects the last block.
        if self._placing then
            self:Cancel()
        else
            self:EquipLastBlock()
        end
    end
end

function PlacementController.EquipLastBlock(self: PlacementControllerType) -- Re-equips the current block selection.
    local blocks = GetBlockTemplates() -- Read the available templates.

    assert(#blocks > 0, "No Model templates were found inside ReplicatedStorage.Blocks") -- Stop with a useful error if setup is missing.

    if self._blockIndex < 1 or self._blockIndex > #blocks then
        self._blockIndex = 1 -- Recover from an invalid selection index.
    end

    self:SelectBlock(blocks[self._blockIndex]) -- Start previewing the selected template.
end

function PlacementController.CycleBlock(self: PlacementControllerType) -- Moves to the next available block.
    local blocks = GetBlockTemplates() -- Get the current template list.

    assert(#blocks > 0, "No Model templates were found inside ReplicatedStorage.Blocks") -- Building requires at least one template.

    self._blockIndex = (self._blockIndex % #blocks) + 1 -- Modulo wraps the index back to one.
    self:SelectBlock(blocks[self._blockIndex]) -- Replace the current preview.
end

function PlacementController.SelectBlock( -- Stores all information needed to place a model correctly.
    self: PlacementControllerType,
    blockTemplate: Model
)
    self:Cancel() -- Remove any previous preview/mode before selecting another block.

    self._selectedBlock = blockTemplate -- Keep the original model as the placement source.
    self._placing = true -- Enter building mode.

    local blockCFrame, blockSize = blockTemplate:GetBoundingBox() -- BoundingBox gives physical dimensions independent of pivot.

    self._blockSize = blockSize -- Save the size for collision and surface calculations.
    self._blockPivotOffset = blockCFrame:ToObjectSpace( -- Convert the bounding box CFrame into model-local pivot space.
        blockTemplate:GetPivot()
    )

    self:CreatePreview(blockTemplate) -- Create the visual representation used while aiming.
end

function PlacementController.CycleGridSize(self: PlacementControllerType) -- Selects the next grid resolution.
    self._gridIndex = (self._gridIndex % #GRID_SIZES) + 1 -- Wraps around after the largest grid.
end

function PlacementController.ToggleDeleteMode(self: PlacementControllerType) -- Switches between building and deletion.
    local newDeleteState = not self._deleting -- Calculate the requested new state.

    self:Cancel() -- Clear any active building preview before changing modes.
    self._deleting = newDeleteState -- Apply the new delete state.
end

function PlacementController.CreatePreview( -- Creates a temporary clone of the selected template.
    self: PlacementControllerType,
    blockTemplate: Model
)
    self._previewTrove:Clean() -- Destroy the previous preview without touching permanent connections.

    local preview = blockTemplate:Clone() -- Clone instead of modifying the original template.

    PreparePreview(preview) -- Make the clone visual-only.

    self._preview = preview -- Store it for future updates.
    self._previewTrove:Add(preview) -- Trove will destroy it automatically when replaced/cancelled.

    self._rotation = 0 -- Every newly selected block starts without extra rotation.
    self._rotationCFrame = CFrame.new() -- Reset the rotation transform.
    self._visualPosition = nil -- Force the visual position to initialize from the target.
    self._visualRotation = nil -- Force the visual rotation to initialize from the target.
    self._targetCFrame = nil -- No placement target exists until the next raycast.
    self._canPlace = false -- Prevent placement before the first valid update.
    self._lastValidPlacement = nil -- Force the preview color to update.
    self._placing = true -- Keep building mode active.

    self:UpdateFilters() -- Make the new preview invisible to future queries.
end

function PlacementController.Rotate(self: PlacementControllerType) -- Rotates the selected block by 90 degrees.
    self._rotation = (self._rotation + 90) % 360 -- Four rotations return to the original orientation.

    self._rotationCFrame = CFrame.Angles( -- Store rotation as a CFrame for direct transform composition.
        0,
        math.rad(self._rotation),
        0
    )
end

function PlacementController.CanPlace(self: PlacementControllerType): boolean -- Checks whether the controller has enough state to calculate placement.
    return self._placing
        and self._preview ~= nil
        and self._selectedBlock ~= nil
        and self._blockSize ~= nil
end

function PlacementController.CheckCollisions( -- Tests the exact intended placement area.
    self: PlacementControllerType,
    cframe: CFrame,
    size: Vector3
): boolean
    local checkSize = Vector3.new( -- Slightly shrink the box to avoid false positives on touching edges.
        math.max(size.X - COLLISION_EPSILON, MIN_CHECK_AXIS),
        math.max(size.Y - COLLISION_EPSILON, MIN_CHECK_AXIS),
        math.max(size.Z - COLLISION_EPSILON, MIN_CHECK_AXIS)
    )

    local parts = workspace:GetPartBoundsInBox( -- Spatial query is cheaper and more suitable than cloning physics.
        cframe,
        checkSize,
        self._overlapParams
    )

    for _, part in parts do -- Inspect every nearby part returned by the bounded query.
        if part.CanCollide then -- Non-collidable decoration should not block building.
            return false -- One blocking part is enough to reject the placement.
        end
    end

    return true -- No collidable part overlaps the requested space.
end

function PlacementController.ComputeTargetCFrame( -- Converts a surface hit into an exact building transform.
    self: PlacementControllerType,
    result: RaycastResult
): (CFrame, Vector3)
    local blockSize = assert( -- Strictly require dimensions before doing placement math.
        self._blockSize,
        "Block size is required before computing placement"
    )

    local worldSize = GetRotatedWorldSize( -- Rotation changes the axis-aligned extents.
        blockSize,
        self._rotationCFrame
    )

    local surfaceOffset = GetSurfaceOffset( -- Find the distance from the hit surface to the model center.
        result.Normal,
        worldSize
    )

    local surfacePosition = -- Move the model away from the surface by its projected half-size.
        result.Position
        + result.Normal * surfaceOffset

    local gridSize = GRID_SIZES[self._gridIndex] -- Convert the selected index into an actual grid size.

    local snappedPosition = SnapPositionToGrid( -- Apply snapping without breaking surface attachment.
        surfacePosition,
        gridSize,
        result.Normal
    )

    local targetCFrame = -- Combine the snapped position with the selected rotation.
        CFrame.new(snappedPosition)
        * self._rotationCFrame

    return targetCFrame, worldSize -- Return both transform and size for later collision checking.
end

function PlacementController.UpdatePreviewTransform( -- Smoothly moves only the visual preview.
    self: PlacementControllerType,
    targetCFrame: CFrame,
    deltaTime: number
)
    local alpha = 1 - math.exp( -- Exponential interpolation is frame-rate independent.
        -PREVIEW_LERP_SPEED * deltaTime
    )

    local targetPosition = targetCFrame.Position -- Extract translation from the exact target.
    local targetRotation = self._rotationCFrame -- Rotation comes directly from the current selection.

    if self._visualPosition then
        self._visualPosition = self._visualPosition:Lerp( -- Smoothly approach the target position.
            targetPosition,
            alpha
        )
    else
        self._visualPosition = targetPosition -- Initialize immediately on the first frame.
    end

    if self._visualRotation then
        self._visualRotation = self._visualRotation:Lerp( -- Smoothly approach the new rotation.
            targetRotation,
            alpha
        )
    else
        self._visualRotation = targetRotation -- Initialize rotation immediately.
    end

    local preview = self._preview -- Cache the model reference locally.

    if not preview then
        return -- The preview may have been cancelled between frames.
    end

    local visualPosition = self._visualPosition
    local visualRotation = self._visualRotation

    if not visualPosition or not visualRotation then
        return -- Defensive check for strict optional state.
    end

    local pivotOffset = self._blockPivotOffset or CFrame.new() -- Preserve the original model pivot.

    preview:PivotTo( -- Apply the smoothed transform while keeping the template's pivot relationship.
        CFrame.new(visualPosition)
        * visualRotation
        * pivotOffset
    )
end

function PlacementController.UpdateDeleteMode(self: PlacementControllerType) -- Finds and highlights the model under the mouse.
    local highlight = self._deleteHighlight -- Cache the highlight reference.

    if not self._deleting or not highlight then
        return -- Delete mode must be active to perform this work.
    end

    local result = GetMouseHit( -- Raycast from the mouse into the world.
        workspace.CurrentCamera,
        self._raycastParams
    )

    local targetModel = if result -- Convert the hit part into an owned placed model.
        then FindPlacedModel(
            result.Instance,
            player.UserId
        )
        else nil

    if highlight.Adornee ~= targetModel then -- Only update when the target actually changes.
        highlight.Adornee = targetModel -- Show the highlight on the selected model.
        highlight.Enabled = targetModel ~= nil -- Hide it when nothing valid is targeted.
    end
end

function PlacementController.Update( -- Main per-frame update for the controller.
    self: PlacementControllerType,
    deltaTime: number
)
    if self._deleting then -- Delete mode has a different update path.
        self:UpdateDeleteMode()
        return
    end

    if not self:CanPlace() then -- Avoid raycasts and calculations when no block is selected.
        return
    end

    local result = GetMouseHit( -- Find the surface currently under the mouse.
        workspace.CurrentCamera,
        self._raycastParams
    )

    local preview = self._preview -- Cache the preview reference.

    if not result then -- Nothing is inside building range.
        self._canPlace = false -- Placement must be rejected.

        if preview then
            preview.Parent = nil -- Hide the preview instead of destroying/recreating it.
        end

        if self._lastValidPlacement ~= false then -- Only recolor when the state changed.
            self._lastValidPlacement = false
            SetPreviewColor(preview, false)
        end

        return
    end

    if preview and preview.Parent ~= workspace then -- Re-show the preview once a valid target exists.
        preview.Parent = workspace
    end

    local targetCFrame, worldSize = -- Calculate exact position and rotated dimensions.
        self:ComputeTargetCFrame(result)

    self._targetCFrame = targetCFrame -- Save the exact transform used when placing.

    self:UpdatePreviewTransform( -- Smooth only the visual representation.
        targetCFrame,
        deltaTime
    )

    self._canPlace = self:CheckCollisions( -- Test the exact target rather than the interpolated preview.
        targetCFrame,
        worldSize
    )

    if self._lastValidPlacement ~= self._canPlace then -- Avoid repeating the expensive color loop every frame.
        self._lastValidPlacement = self._canPlace
        SetPreviewColor(preview, self._canPlace)
    end
end

function PlacementController.Place(self: PlacementControllerType) -- Creates the permanent placed model.
    if not self:CanPlace() or not self._canPlace then -- Never place without a valid calculated target.
        return
    end

    local selectedBlock = self._selectedBlock -- Cache the template.
    local targetCFrame = self._targetCFrame -- Cache the exact placement transform.
    local pivotOffset = self._blockPivotOffset -- Cache the original pivot offset.
    local placedFolder = self._placedFolder -- Cache the destination folder.

    if not selectedBlock
        or not targetCFrame
        or not pivotOffset
        or not placedFolder
    then
        return -- Defensive validation prevents partially initialized placement.
    end

    local placedModel = selectedBlock:Clone() -- Clone the original, not the modified preview.

    placedModel:PivotTo( -- Apply the exact transform calculated by the placement system.
        targetCFrame * pivotOffset
    )

    placedModel:SetAttribute( -- Store the player ID as lightweight ownership metadata.
        "PlacedByUserId",
        player.UserId
    )

    placedModel:SetAttribute( -- Remember which template produced the placed object.
        "PlacedFromTemplate",
        selectedBlock.Name
    )

    CollectionService:AddTag( -- Tag the model so deletion can quickly identify valid targets.
        placedModel,
        PLACED_BLOCK_TAG
    )

    placedModel.Parent = placedFolder -- Parenting last keeps the object out of the world during setup.
end

function PlacementController.Delete(self: PlacementControllerType) -- Removes an owned placed block.
    if not self._deleting then -- Deletion is only allowed in delete mode.
        return
    end

    local result = GetMouseHit( -- Find what the mouse is pointing at.
        workspace.CurrentCamera,
        self._raycastParams
    )

    if not result then
        return -- Nothing was hit.
    end

    local targetModel = FindPlacedModel( -- Verify both tag and player ownership.
        result.Instance,
        player.UserId
    )

    if targetModel then -- Only destroy verified models.
        targetModel:Destroy() -- Remove the placed block.

        local highlight = self._deleteHighlight -- Clear the old delete target.

        if highlight then
            highlight.Adornee = nil
            highlight.Enabled = false
        end
    end
end

function PlacementController.Cancel(self: PlacementControllerType) -- Clears temporary placement state.
    self._placing = false -- Leave building mode.
    self._canPlace = false -- Prevent stale placement.
    self._deleting = false -- Leave delete mode.

    self._selectedBlock = nil -- Remove the current template reference.
    self._preview = nil -- Clear the preview reference.
    self._lastValidPlacement = nil -- Reset validity tracking.

    self._blockSize = nil -- Remove old dimensions.
    self._blockPivotOffset = nil -- Remove old pivot data.

    self._visualPosition = nil -- Reset interpolation state.
    self._visualRotation = nil
    self._targetCFrame = nil -- Prevent stale placement after cancelling.

    self._previewTrove:Clean() -- Destroy the temporary preview.
    self:UpdateFilters() -- Remove the destroyed preview from query filters.

    if self._deleteHighlight then -- Reset delete visuals.
        self._deleteHighlight.Enabled = false
        self._deleteHighlight.Adornee = nil
    end
end

function PlacementController.Destroy(self: PlacementControllerType) -- Permanently shuts down the controller.
    self:Cancel() -- Clean temporary state first.
    self._trove:Destroy() -- Disconnect every registered event and destroy tracked objects.
end

local controller = PlacementController.new() -- Create the controller and start the building system.

return controller -- Return the instance so the script can be required by another client script.
