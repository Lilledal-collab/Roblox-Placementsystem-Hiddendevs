-- Connected Discord-GitHub | Discord: @lilledal_ | Roblox: @Hasaaawuw72
--!strict

--[[
    BUILDING / PLACEMENT CONTROLLER

    This controller contains the client-side logic for the building demo.
    The main flow is:

        Input
           select / rotate / change grid
           raycast from the mouse
           calculate a target CFrame
           check the target with a spatial query
           move the preview visually
           place the original template when valid

    The preview is intentionally separate from the real placed model.
    This lets the controller interpolate the visual preview without allowing
    interpolation to affect the exact CFrame used for collision detection
    and placement.

    Roblox systems demonstrated here include:
    CFrame mathematics, RaycastParams, OverlapParams, spatial queries,
    CollectionService, Attributes, Highlight, RenderStepped, UserInputService,
    Model pivots, strict Luau types, metatables, and resource cleanup.

    Open-source dependency:
    Trove by Stephen Leitnick (Sleitnick), from RbxUtil.
]]

-- Services
-- Shared services first: the rest of the controller depends on these Roblox APIs.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Shared storage is used so block templates and the Trove dependency can be accessed without duplicating them.
local RunService = game:GetService("RunService") -- RenderStepped is used because preview interpolation is visual work that should follow the rendered frame rate.
local UserInputService = game:GetService("UserInputService") -- Centralizing input here keeps building controls independent from the visual update loop.
local GuiService = game:GetService("GuiService") -- The GUI inset must be considered when converting screen mouse coordinates into camera viewport coordinates.
local CollectionService = game:GetService("CollectionService") -- Tags provide a lightweight way to distinguish blocks created by this system from unrelated models.
local Players = game:GetService("Players") -- The controller needs the local player's character and UserId for filtering and ownership checks.

-- Dependencies
local Blocks = ReplicatedStorage:WaitForChild("Blocks") -- Waiting here guarantees the building system does not start before its required template folder exists.
local Trove = require(ReplicatedStorage:WaitForChild("Trove")) -- Trove is used so every connection and temporary preview can be cleaned up from one ownership point.
local player = Players.LocalPlayer -- This is a client-side controller, so all input and preview state belongs to the local player.

-- Configuration
-- These are the grid steps the player can cycle through. Example: grid 4 means positions snap in 4-stud steps.
local GRID_SIZES = {1, 2, 4, 8} -- Multiple grid sizes let the same placement algorithm support both detailed and coarse building.
local BUILD_RANGE = 70 -- Limiting the ray prevents players from selecting surfaces that are too far away to reasonably build on.
local PREVIEW_LERP_SPEED = 20 -- Controls visual responsiveness without changing the exact target used by the placement logic.
local PREVIEW_TRANSPARENCY = 0.5 -- Makes the temporary state visually distinguishable from a completed block.
local COLLISION_EPSILON = 0.02 -- A small tolerance prevents floating-point boundary contacts from being treated as unwanted overlaps.
local MIN_CHECK_AXIS = 0.05 -- Keeps the overlap box valid even when an extremely small model or epsilon would otherwise reduce an axis too far.
local PLACED_FOLDER_NAME = "ClientPlacedBlocks" -- A dedicated container keeps the demo's generated instances organized and easy to inspect.
local PLACED_BLOCK_TAG = "DemoPlacedBlock" -- The tag lets deletion identify valid placed models without relying only on hierarchy names.

type TroveType = typeof(Trove.new()) -- Infers the dependency's concrete type so strict Luau can validate Trove usage.

type ControllerData = { -- Explicit state makes the controller easier to reason about because every mutable part of the placement process is defined.
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

local PlacementController = {} -- A table is used as the class prototype so all controller instances can share method implementations.
PlacementController.__index = PlacementController -- __index makes missing instance members resolve to the shared prototype methods.

type PlacementControllerType = typeof(setmetatable( -- This type connects the runtime metatable pattern with strict Luau's static checking.
    {} :: ControllerData,
    PlacementController
))

-- Keep all locally created blocks in one predictable folder. This makes the workspace easier to inspect too.
local function GetPlacedFolder(): Folder -- The folder is resolved through one function so placement code does not need to recreate or search for it repeatedly.
    local existing = workspace:FindFirstChild(PLACED_FOLDER_NAME) -- Reusing an existing folder prevents multiple controller starts from creating duplicate containers.

    if existing then
        assert(existing:IsA("Folder"), `Workspace.{PLACED_FOLDER_NAME} must be a Folder`) -- Failing early makes an incorrect Studio hierarchy obvious instead of causing a later, less useful error.
        return existing -- Returning the existing container keeps all placed objects under one predictable parent.
    end

    local folder = Instance.new("Folder") -- A Folder is sufficient because the system only needs organization, not extra behavior.
    folder.Name = PLACED_FOLDER_NAME -- A constant name lets other parts of the demo inspect the generated objects predictably.
    folder.Parent = workspace -- Parenting makes the placed models visible and physically active in the world.

    return folder -- The controller stores this reference so later placements do not need another hierarchy lookup.
end

-- Read the available block models fresh each time, so adding/removing a template while testing still works.
local function GetBlockTemplates(): {Model} -- Template discovery is isolated here so selection logic only deals with valid Models.
    local templates: {Model} = {} -- Explicit typing keeps the returned collection compatible with strict Luau.

    for _, child in Blocks:GetChildren() do -- Only direct children are considered templates, keeping the folder structure intentional.
        if child:IsA("Model") then -- Models are required because the placement system uses model pivots and bounding boxes.
            table.insert(templates, child) -- Invalid objects are ignored rather than making block cycling depend on the folder containing only Models.
        end
    end

    table.sort(templates, function(a, b) -- Sorting makes selection deterministic even if Studio hierarchy order changes.
        return a.Name:lower() < b.Name:lower() -- Case-insensitive sorting gives players a predictable alphabetical order.
    end)

    return templates -- Returning a fresh list prevents callers from modifying the Blocks folder's actual children.
end

-- This is the bridge from the 2D mouse to the 3D world: screen position -> camera ray -> hit result.
local function GetMouseHit( -- Converts 2D input into the 3D information required by the rest of the placement pipeline.
    camera: Camera?,
    params: RaycastParams
): RaycastResult?
    if not camera then -- CurrentCamera can temporarily be unavailable during loading or camera replacement.
        return nil -- Returning no hit allows the update loop to safely skip placement calculations for that frame.
    end

    local mousePosition = UserInputService:GetMouseLocation() -- Roblox gives the pointer in screen coordinates rather than directly in viewport coordinates.
    local inset = GuiService:GetGuiInset() -- GUI insets offset the coordinate system, so ignoring them would make the ray miss the cursor position.

    local viewportX = mousePosition.X - inset.X -- Convert screen X into the camera's viewport coordinate system.
    local viewportY = mousePosition.Y - inset.Y -- Do the same for Y so the resulting ray originates under the actual pointer.

    local ray = camera:ViewportPointToRay(viewportX, viewportY) -- The camera converts the 2D pointer position into a direction in 3D space.

    return workspace:Raycast( -- Raycasting is preferable here to physical mouse targeting because the controller needs explicit filtering and range control.
        ray.Origin,
        ray.Direction * BUILD_RANGE,
        params
    )
end

local function GetDominantNormalAxis( -- The surface normal determines which coordinate should remain attached to the hit surface during grid snapping.
    normal: Vector3
): "X" | "Y" | "Z"
    local x = math.abs(normal.X) -- Direction is irrelevant when determining the strongest axis, so only magnitude matters.
    local y = math.abs(normal.Y)
    local z = math.abs(normal.Z)

    if x >= y and x >= z then -- If X dominates, the surface is primarily facing along the X axis.
        return "X"
    end

    if y >= z then -- X was not dominant, so Y and Z are compared directly.
        return "Y"
    end

    return "Z" -- Z is the remaining dominant axis.
end

-- Only the axes that are free to move get snapped. The axis touching the surface stays exact so the block does not float away.
local function SnapPositionToGrid( -- Snapping is separated from raycasting so the placement math can change without changing input handling.
    position: Vector3,
    gridSize: number,
    normal: Vector3
): Vector3
    local axis = GetDominantNormalAxis(normal) -- The surface axis must be preserved or the block can drift away from the face being built on.

    local x = if axis == "X" -- X is kept exact when it represents the surface depth.
        then position.X
        else math.round(position.X / gridSize) * gridSize -- Free axes are rounded to the selected grid interval.

    local y = if axis == "Y" -- Y remains exact when building against a horizontal surface.
        then position.Y
        else math.round(position.Y / gridSize) * gridSize

    local z = if axis == "Z" -- Z remains exact for a Z-facing surface.
        then position.Z
        else math.round(position.Z / gridSize) * gridSize

    return Vector3.new(x, y, z) -- Rebuilding the vector keeps the function pure and avoids mutating the input position.
end

-- A ray hits the surface, not the center of the block. This offset pushes the center outward by half the block depth.
local function GetSurfaceOffset( -- Calculates the distance needed to move the model center from the hit surface to its outer face.
    normal: Vector3,
    worldSize: Vector3
): number
    local halfSize = worldSize / 2 -- The surface touches the model's boundary, so the relevant distance is the half-extent.

    return math.abs(normal.X) * halfSize.X -- Projects the X half-extent onto the surface normal.
        + math.abs(normal.Y) * halfSize.Y -- Adds the equivalent Y projection because the normal may not be perfectly axis-aligned.
        + math.abs(normal.Z) * halfSize.Z -- The sum gives the distance from the center to the model's boundary along the normal.
end

-- After rotating a model, its world-aligned bounds can change. Collision checks need those rotated dimensions.
local function GetRotatedWorldSize( -- Collision queries need world-aligned extents after rotation rather than the template's original dimensions.
    size: Vector3,
    rotation: CFrame
): Vector3
    local rotatedSize = rotation * size -- Rotating the size vector gives the dimensions of the rotated rectangular bounds.

    return Vector3.new( -- Absolute values convert signed rotated coordinates into positive bounding extents.
        math.abs(rotatedSize.X),
        math.abs(rotatedSize.Y),
        math.abs(rotatedSize.Z)
    )
end

-- The preview is deliberately harmless: it looks like the real block but should never affect physics or run scripts.
local function PreparePreview(model: Model) -- The preview intentionally becomes a non-physical copy so visual feedback cannot affect gameplay.
    for _, object in model:GetDescendants() do -- Descendants are used because a Model may contain parts nested inside folders or other models.
        if object:IsA("BaseScript") or object:IsA("ModuleScript") then -- Scripts inside a cloned preview would otherwise duplicate behavior from the original template.
            object:Destroy() -- Removing them makes the preview purely visual and prevents unintended duplicate logic.
            continue
        end

        if not object:IsA("BasePart") then -- Only physical parts have the properties needed for preview isolation.
            continue
        end

        object.Anchored = true -- Anchoring removes physics from the interpolation system so the controller owns the preview transform.
        object.CanCollide = false -- The preview must not physically block the player or other objects.
        object.CanTouch = false -- Touch events are unnecessary for a visual object and would create avoidable engine work.
        object.CanQuery = false -- Excluding the preview from spatial queries prevents it from detecting itself.
        object.Massless = true -- This is defensive because the preview should never contribute meaningful physical mass.
        object.Transparency = PREVIEW_TRANSPARENCY -- Transparency communicates that the model has not been committed yet.
    end
end

local function SetPreviewColor( -- Color is feedback for the collision result rather than part of the placement calculation itself.
    model: Model?,
    isValid: boolean
)
    if not model then -- The preview can disappear between frames when the player cancels.
        return
    end

    local color = if isValid -- Green means the current target passed the collision test.
        then Color3.fromRGB(70, 255, 120)
        else Color3.fromRGB(255, 80, 80)

    for _, object in model:GetDescendants() do -- All visible parts need the same state so multi-part templates remain consistent.
        if object:IsA("BasePart") then
            object.Color = color -- Only BaseParts can display the color feedback used by this preview.
        end
    end
end

-- Delete mode starts from a hit part, then walks upward until it finds a tagged block owned by this player.
local function FindPlacedModel( -- Deletion walks from the hit part to its model because the ray usually hits a BasePart, not the Model itself.
    instance: Instance?,
    expectedOwnerId: number
): Model?
    local current = instance -- Start with exactly what the raycast returned.

    while current and current ~= workspace do -- Continue upward until the Workspace boundary is reached.
        if current:IsA("Model") -- The target must be a model...
            and CollectionService:HasTag(current, PLACED_BLOCK_TAG) -- ...created by this building system...
            and current:GetAttribute("PlacedByUserId") == expectedOwnerId -- ...and owned by the player performing the deletion.
        then
            return current -- All conditions match, so this is a safe deletion target for the demo.
        end

        current = current.Parent -- Move toward the root because the original hit may have been deeply nested.
    end

    return nil -- Returning nil prevents unrelated world objects from being treated as placed blocks.
end

-- The constructor sets up all state once, then starts the controller. After that, input and RenderStepped drive everything.
function PlacementController.new(): PlacementControllerType -- Constructor keeps initial state in one place so every instance starts from a known configuration.
    local self = setmetatable({
        _gridIndex = 1, -- The first grid is selected because it provides the most precise default placement.
        _rotation = 0, -- New selections begin at their original orientation.
        _rotationCFrame = CFrame.new(), -- Identity CFrame represents no rotation and composes cleanly with later transforms.
        _blockIndex = 0, -- Zero indicates that no template has been selected yet.
        _selectedBlock = nil, -- The original template is kept separate from the temporary preview.
        _preview = nil, -- No preview exists until a block is equipped.
        _deleteHighlight = nil, -- The Highlight is created once and reused to avoid creating instances every frame.
        _placedFolder = GetPlacedFolder(), -- Resolve the shared destination once during construction.
        _placing = false, -- Building mode is opt-in rather than active immediately.
        _canPlace = false, -- No target can be valid before the first raycast and collision check.
        _deleting = false, -- Delete mode is mutually exclusive with normal placement.
        _lastValidPlacement = nil, -- Used as a change detector so preview colors are not recalculated every frame.
        _blockSize = nil, -- Filled only after a template's bounding box is known.
        _blockPivotOffset = nil, -- Preserves the relationship between the template's pivot and its physical bounds.
        _visualPosition = nil, -- Interpolation state is intentionally separate from the exact target.
        _visualRotation = nil, -- Same separation is used for rotation smoothing.
        _targetCFrame = nil, -- This remains the authoritative transform for placement and collision checking.
        _trove = Trove.new(), -- Owns permanent connections and reusable controller resources.
        _previewTrove = nil, -- A child Trove will own only temporary preview resources.
        _raycastParams = RaycastParams.new(), -- Reusable parameters avoid allocating new filtering objects every frame.
        _overlapParams = OverlapParams.new(), -- Reusable spatial-query parameters serve the same purpose for collision checks.
    }, PlacementController) :: any

    self._previewTrove = self._trove:Extend() -- A child cleanup scope lets previews be replaced without destroying the main controller.

    self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude -- Exclusion is appropriate because only the player and preview need to be ignored.
    self._raycastParams.IgnoreWater = true -- Water is not a meaningful building surface in this demo.

    self._overlapParams.FilterType = Enum.RaycastFilterType.Exclude -- The collision query shares the same basic exclusion strategy as the raycast.
    self._overlapParams.MaxParts = 32 -- Bounding the result prevents a single query from processing an unlimited number of parts.
    self._overlapParams.RespectCanCollide = true -- Decorative non-collidable objects should not make an otherwise valid position invalid.

    local highlight = self._trove:Add(Instance.new("Highlight")) -- The highlight is persistent controller state, so it belongs to the main Trove.
    highlight.FillTransparency = 1 -- An outline is enough to communicate the deletion target without hiding the model.
    highlight.OutlineColor = Color3.fromRGB(255, 65, 65) -- Red is reserved for destructive/delete feedback.
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- The target should still respect normal world visibility.
    highlight.Enabled = false -- It only becomes visible after a valid owned model is found.
    highlight.Parent = workspace -- Highlight instances need to exist in the data model to render.

    self._deleteHighlight = highlight -- Store the reusable instance instead of creating one during every mouse update.

    self:Start() -- Event connections are created only after all controller state and filtering objects are ready.

    return self -- Returning a fully initialized instance keeps construction and usage predictable.
end

-- Raycasts and overlap checks share the same ignore list, so the preview and the player's character cannot interfere.
function PlacementController.UpdateFilters(self: PlacementControllerType) -- Filtering is centralized so raycast and collision rules stay synchronized.
    local filterObjects: {Instance} = {} -- Rebuild the list because the preview and character can change during runtime.

    if self._preview then -- The visual preview should never become its own placement surface.
        table.insert(filterObjects, self._preview)
    end

    if player.Character then -- The player's own character should not block a ray aimed at the world.
        table.insert(filterObjects, player.Character)
    end

    self._raycastParams.FilterDescendantsInstances = filterObjects -- Apply the same current exclusions to mouse targeting.
    self._overlapParams.FilterDescendantsInstances = filterObjects -- Collision checks must ignore the same temporary objects.
end

-- Two loops run the system: RenderStepped updates the preview every frame, while InputBegan handles controls.
function PlacementController.Start(self: PlacementControllerType) -- Starts the controller's two main event-driven systems: input and frame updates.
    self._trove:Add(
        RunService.RenderStepped:Connect(function(deltaTime) -- RenderStepped is appropriate because interpolation is presentation work rather than simulation state.
            self:Update(deltaTime) -- The update method decides whether to calculate placement or deletion feedback.
        end)
    )

    self._trove:Add(
        UserInputService.InputBegan:Connect(function( -- Input is handled independently from RenderStepped so actions do not depend on frame timing.
            input: InputObject,
            gameProcessed: boolean
        )
            if gameProcessed then -- Roblox UI may already consume the input, so building should not steal it.
                return
            end

            if UserInputService:GetFocusedTextBox() then -- Prevent shortcuts from firing while the player is typing.
                return
            end

            self:ProcessInput(input) -- One dispatcher keeps all controls in one predictable place.
        end)
    )

    self._trove:Add(
        player.CharacterAdded:Connect(function() -- Respawning replaces the character instance used by our filters.
            self:UpdateFilters() -- Refreshing here prevents the old character from remaining in the query configuration.
        end)
    )

    self:UpdateFilters() -- The initial filter must be valid before the first RenderStepped callback runs.
end

-- Keep keyboard/mouse handling in one place. The actual work stays in separate methods so this function remains easy to follow.
function PlacementController.ProcessInput( -- Input is converted into state changes here instead of being mixed into placement calculations.
    self: PlacementControllerType,
    input: InputObject
)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then -- Left click is context-sensitive because the active mode determines the action.
        if self._deleting then
            self:Delete() -- Delete mode turns the same mouse action into a removal operation.
        else
            self:Place() -- Normal mode attempts to commit the currently validated target.
        end
    end

    if input.KeyCode == Enum.KeyCode.F then -- F changes the template without changing the placement algorithm.
        if self._placing then
            self:CycleBlock()
        end
    end

    if input.KeyCode == Enum.KeyCode.R then -- Rotation changes only the target transform and therefore reuses the same collision pipeline.
        if self._placing then
            self:Rotate()
        end
    end

    if input.KeyCode == Enum.KeyCode.G then -- Grid size is also input state, so it only needs to invalidate the next calculated target.
        if self._placing then
            self:CycleGridSize()
        end
    end

    if input.KeyCode == Enum.KeyCode.X then -- Delete mode is deliberately a separate state so placement and deletion cannot happen simultaneously.
        self:ToggleDeleteMode()
    end

    if input.KeyCode == Enum.KeyCode.Q then -- Q acts as cancel while building and as a convenient re-equip key otherwise.
        if self._placing then
            self:Cancel()
        else
            self:EquipLastBlock()
        end
    end
end

function PlacementController.EquipLastBlock(self: PlacementControllerType) -- Reuses the stored index so the player can return to their previous template.
    local blocks = GetBlockTemplates() -- The list is refreshed because templates may have been added or removed at runtime.

    assert(#blocks > 0, "No Model templates were found inside ReplicatedStorage.Blocks") -- A clear setup error is better than silently failing to select anything.

    if self._blockIndex < 1 or self._blockIndex > #blocks then
        self._blockIndex = 1 -- Recover safely if the previous selection no longer exists.
    end

    self:SelectBlock(blocks[self._blockIndex]) -- Selection is delegated so all preview setup remains in one path.
end

function PlacementController.CycleBlock(self: PlacementControllerType) -- Advances through templates while keeping selection logic centralized.
    local blocks = GetBlockTemplates() -- Build the current sorted selection list.

    assert(#blocks > 0, "No Model templates were found inside ReplicatedStorage.Blocks") -- Prevent modulo-by-zero and provide a useful developer error.

    self._blockIndex = (self._blockIndex % #blocks) + 1 -- Modulo gives a circular list without a separate boundary branch.
    self:SelectBlock(blocks[self._blockIndex]) -- Replace the current preview with the new template.
end

-- Selecting a block resets the temporary state first, then caches the template's size/pivot information.
function PlacementController.SelectBlock( -- Extracts all physical information needed before preview movement begins.
    self: PlacementControllerType,
    blockTemplate: Model
)
    self:Cancel() -- Selection starts from a clean state so old previews and delete highlights cannot interfere.

    self._selectedBlock = blockTemplate -- The original template remains untouched and is later cloned for permanent placement.
    self._placing = true -- Enabling this before preview creation allows the controller to enter its normal update flow.

    local blockCFrame, blockSize = blockTemplate:GetBoundingBox() -- BoundingBox describes the model's physical extents, which are needed for surface and collision calculations.

    self._blockSize = blockSize -- The dimensions are cached because they are reused every frame while aiming.
    self._blockPivotOffset = blockCFrame:ToObjectSpace( -- Convert from world-space bounding-box placement to a local pivot relationship.
        blockTemplate:GetPivot()
    )

    self:CreatePreview(blockTemplate) -- Preview creation is kept separate so visual setup does not get mixed with selection math.
end

function PlacementController.CycleGridSize(self: PlacementControllerType) -- Changes only the grid state; the next Update will naturally recalculate the target.
    self._gridIndex = (self._gridIndex % #GRID_SIZES) + 1 -- Circular indexing avoids special-case handling at the end of the array.
end

function PlacementController.ToggleDeleteMode(self: PlacementControllerType) -- Switching modes resets placement state so the two systems remain mutually exclusive.
    local newDeleteState = not self._deleting -- Compute the desired state before Cancel resets all temporary modes.

    self:Cancel() -- Cancel first because a building preview should not remain active while deleting.
    self._deleting = newDeleteState -- Restore only the requested delete state after the reset.
end

-- Rebuild the preview from the original template instead of modifying the template itself.
function PlacementController.CreatePreview( -- Creates the temporary object used solely for visual feedback.
    self: PlacementControllerType,
    blockTemplate: Model
)
    self._previewTrove:Clean() -- Only the previous preview is cleaned; permanent controller connections remain alive.

    local preview = blockTemplate:Clone() -- Cloning prevents preview modifications from changing the source template.

    PreparePreview(preview) -- Convert the clone into a non-physical representation before it enters Workspace.

    self._preview = preview -- Store the clone because later frame updates need to move it.
    self._previewTrove:Add(preview) -- The cleanup scope guarantees cancellation cannot leave orphaned preview instances.

    self._rotation = 0 -- Resetting rotation makes switching blocks deterministic.
    self._rotationCFrame = CFrame.new() -- Match the numeric rotation state with its transform representation.
    self._visualPosition = nil -- Reset interpolation so the new preview does not animate from the previous block's position.
    self._visualRotation = nil -- The same reset is required for rotation.
    self._targetCFrame = nil -- No valid target exists until a fresh raycast is processed.
    self._canPlace = false -- Prevent a stale collision result from allowing an immediate placement.
    self._lastValidPlacement = nil -- Force the color state to be recalculated on the next valid update.
    self._placing = true -- Keep the controller in placement mode.

    self:UpdateFilters() -- The new preview must immediately be excluded from future raycasts and overlap queries.
end

function PlacementController.Rotate(self: PlacementControllerType) -- Stores rotation as both an angle and a CFrame so UI state and transform math stay synchronized.
    self._rotation = (self._rotation + 90) % 360 -- Four 90-degree rotations form a complete cycle, making modulo a natural representation.

    self._rotationCFrame = CFrame.Angles( -- CFrame is used because it can be composed directly with the final position transform.
        0,
        math.rad(self._rotation),
        0
    )
end

function PlacementController.CanPlace(self: PlacementControllerType): boolean -- This guard prevents expensive raycasts and calculations when required state is missing.
    return self._placing
        and self._preview ~= nil
        and self._selectedBlock ~= nil
        and self._blockSize ~= nil
end

-- The collision test checks the exact target CFrame, not the smoothed visual preview.
function PlacementController.CheckCollisions( -- Collision validation is separated so the same target calculation can be tested independently of visual movement.
    self: PlacementControllerType,
    cframe: CFrame,
    size: Vector3
): boolean
    local checkSize = Vector3.new( -- The slightly smaller box allows blocks touching at their boundaries to coexist.
        math.max(size.X - COLLISION_EPSILON, MIN_CHECK_AXIS),
        math.max(size.Y - COLLISION_EPSILON, MIN_CHECK_AXIS),
        math.max(size.Z - COLLISION_EPSILON, MIN_CHECK_AXIS)
    )

    local parts = workspace:GetPartBoundsInBox( -- A spatial query checks the intended volume directly without creating temporary physics objects.
        cframe,
        checkSize,
        self._overlapParams
    )

    for _, part in parts do -- The query is bounded, so this loop has a predictable maximum amount of work.
        if part.CanCollide then -- Only physically blocking parts should invalidate the position.
            return false -- One blocking intersection is sufficient to reject the entire placement.
        end
    end

    return true -- No relevant collision means the target is currently valid.
end

-- This is the core placement calculation: rotated size -> surface offset -> grid snap -> final CFrame.
function PlacementController.ComputeTargetCFrame( -- This function is the mathematical center of the placement system.
    self: PlacementControllerType,
    result: RaycastResult
): (CFrame, Vector3)
    local blockSize = assert( -- The calculation cannot be correct without knowing the selected model's dimensions.
        self._blockSize,
        "Block size is required before computing placement"
    )

    local worldSize = GetRotatedWorldSize( -- The model's extents must be recalculated after rotation because collision dimensions are world-aligned.
        blockSize,
        self._rotationCFrame
    )

    local surfaceOffset = GetSurfaceOffset( -- The projected half-extents determine how far the model center must move away from the hit point.
        result.Normal,
        worldSize
    )

    local surfacePosition = -- Starting from the hit position and moving along its normal prevents the block from intersecting the surface.
        result.Position
        + result.Normal * surfaceOffset

    local gridSize = GRID_SIZES[self._gridIndex] -- Convert the player's grid selection into the actual spacing used by the snapping function.

    local snappedPosition = SnapPositionToGrid( -- Snapping happens after surface offset so the block remains aligned with the selected building grid.
        surfacePosition,
        gridSize,
        result.Normal
    )

    local targetCFrame = -- Position and rotation are combined only after all positional calculations are complete.
        CFrame.new(snappedPosition)
        * self._rotationCFrame

    return targetCFrame, worldSize -- Both values are needed by the next stages: visual movement and collision validation.
end

-- The preview can move smoothly for nicer visuals, but this smoothing never changes the real placement target.
function PlacementController.UpdatePreviewTransform( -- Separating visual interpolation from target calculation keeps placement mathematically exact.
    self: PlacementControllerType,
    targetCFrame: CFrame,
    deltaTime: number
)
    local alpha = 1 - math.exp( -- Exponential smoothing approaches the target consistently across different frame rates.
        -PREVIEW_LERP_SPEED * deltaTime
    )

    local targetPosition = targetCFrame.Position -- Only the position is smoothed separately from rotation.
    local targetRotation = self._rotationCFrame -- Rotation comes from the authoritative selection state rather than the interpolated model.

    if self._visualPosition then
        self._visualPosition = self._visualPosition:Lerp( -- Lerp creates a smooth visual transition instead of snapping every frame.
            targetPosition,
            alpha
        )
    else
        self._visualPosition = targetPosition -- The first frame should not animate from an arbitrary origin.
    end

    if self._visualRotation then
        self._visualRotation = self._visualRotation:Lerp( -- Smooth rotation independently so movement and rotation remain visually stable.
            targetRotation,
            alpha
        )
    else
        self._visualRotation = targetRotation -- Initialize directly so the first preview frame is correct.
    end

    local preview = self._preview -- Local caching keeps the remainder of the function simple and handles cancellation safely.

    if not preview then
        return -- The preview may have been cleaned by input between rendered frames.
    end

    local visualPosition = self._visualPosition
    local visualRotation = self._visualRotation

    if not visualPosition or not visualRotation then
        return -- Strict optional checks guarantee valid values before constructing the final visual transform.
    end

    local pivotOffset = self._blockPivotOffset or CFrame.new() -- The fallback keeps the transform valid even during a partial state transition.

    preview:PivotTo( -- The preview uses the smoothed visual state, while placement itself still uses _targetCFrame.
        CFrame.new(visualPosition)
        * visualRotation
        * pivotOffset
    )
end

-- Delete mode reuses the same mouse ray, but converts the hit into a valid owned model and highlights it.
function PlacementController.UpdateDeleteMode(self: PlacementControllerType) -- Delete mode reuses the same raycasting system but changes the result into a selectable target.
    local highlight = self._deleteHighlight -- Reuse the persistent Highlight instead of creating one for every target.

    if not self._deleting or not highlight then
        return -- Avoid all raycast work while deletion is inactive.
    end

    local result = GetMouseHit( -- The same filtered mouse ray keeps targeting behavior consistent between modes.
        workspace.CurrentCamera,
        self._raycastParams
    )

    local targetModel = if result -- A raycast part is converted into a verified model through the ownership helper.
        then FindPlacedModel(
            result.Instance,
            player.UserId
        )
        else nil

    if highlight.Adornee ~= targetModel then -- Only write properties when the selected model actually changes.
        highlight.Adornee = targetModel -- Point the reusable visual indicator at the new target.
        highlight.Enabled = targetModel ~= nil -- No valid target means there is nothing useful to highlight.
    end
end

-- Main per-frame flow: find the surface, calculate the target, move the preview, then validate the target.
function PlacementController.Update( -- This is the main coordinator that connects input state, raycasting, math, collision, and visuals.
    self: PlacementControllerType,
    deltaTime: number
)
    if self._deleting then -- Delete mode has its own lightweight path and does not need building collision calculations.
        self:UpdateDeleteMode()
        return
    end

    if not self:CanPlace() then -- Early return avoids unnecessary engine queries when no block is being previewed.
        return
    end

    local result = GetMouseHit( -- Every placement calculation begins with the current surface under the pointer.
        workspace.CurrentCamera,
        self._raycastParams
    )

    local preview = self._preview -- Cache the preview because several operations below need it.

    if not result then -- A missing hit means the player is outside the buildable ray range or pointing at nothing.
        self._canPlace = false -- Stale validity must never remain active after the target disappears.

        if preview then
            preview.Parent = nil -- Hide rather than destroy so the same preview can be reused when the mouse returns.
        end

        if self._lastValidPlacement ~= false then -- Only update the visual state when validity actually changed.
            self._lastValidPlacement = false
            SetPreviewColor(preview, false)
        end

        return
    end

    if preview and preview.Parent ~= workspace then -- Restore the preview only after a valid raycast exists.
        preview.Parent = workspace
    end

    local targetCFrame, worldSize = -- The target is calculated once and then shared by visual and collision logic.
        self:ComputeTargetCFrame(result)

    self._targetCFrame = targetCFrame -- This is the authoritative transform that Place() will later use.

    self:UpdatePreviewTransform( -- Visual smoothing happens after target calculation but never changes the target itself.
        targetCFrame,
        deltaTime
    )

    self._canPlace = self:CheckCollisions( -- Collision testing uses the exact target rather than the interpolated preview.
        targetCFrame,
        worldSize
    )

    if self._lastValidPlacement ~= self._canPlace then -- Recoloring only on state changes avoids repeatedly iterating every preview part.
        self._lastValidPlacement = self._canPlace
        SetPreviewColor(preview, self._canPlace)
    end
end

-- When the latest target is valid, clone the original template and place it using the exact target transform.
function PlacementController.Place(self: PlacementControllerType) -- Commits the previously calculated target into a real model.
    if not self:CanPlace() or not self._canPlace then -- Placement is gated by both valid controller state and the latest collision result.
        return
    end

    local selectedBlock = self._selectedBlock -- Cache the immutable source template used to create the placed object.
    local targetCFrame = self._targetCFrame -- Use the exact target instead of the visually interpolated preview transform.
    local pivotOffset = self._blockPivotOffset -- Preserve the original relationship between the model pivot and its bounds.
    local placedFolder = self._placedFolder -- Parenting is deferred until all metadata and transforms are ready.

    if not selectedBlock
        or not targetCFrame
        or not pivotOffset
        or not placedFolder
    then
        return -- Defensive validation prevents partially initialized controller state from producing broken models.
    end

    local placedModel = selectedBlock:Clone() -- The source template is cloned so the original remains reusable for future placements.

    placedModel:PivotTo( -- Applying the same transform used for collision validation keeps the preview and final object consistent.
        targetCFrame * pivotOffset
    )

    placedModel:SetAttribute( -- Attributes store ownership directly on the object so the information travels with the model.
        "PlacedByUserId",
        player.UserId
    )

    placedModel:SetAttribute( -- Keeping the source template name makes the generated object easier to inspect and debug.
        "PlacedFromTemplate",
        selectedBlock.Name
    )

    CollectionService:AddTag( -- The tag gives FindPlacedModel a reliable type check without depending on model names.
        placedModel,
        PLACED_BLOCK_TAG
    )

    placedModel.Parent = placedFolder -- Parenting last prevents other systems from observing an incompletely configured object.
end

-- Re-check the raycast at click time so deletion never trusts an old highlight.
function PlacementController.Delete(self: PlacementControllerType) -- Deletes only a model that passed the same ownership rules used for highlighting.
    if not self._deleting then -- This guard prevents other input paths from accidentally deleting during normal building.
        return
    end

    local result = GetMouseHit( -- Recalculate the target at click time so deletion cannot rely on stale highlight state.
        workspace.CurrentCamera,
        self._raycastParams
    )

    if not result then
        return -- No raycast result means there is nothing to delete.
    end

    local targetModel = FindPlacedModel( -- Ownership is checked again instead of trusting the visual highlight.
        result.Instance,
        player.UserId
    )

    if targetModel then -- Only the verified result can reach Destroy().
        targetModel:Destroy() -- Removing the model also removes all of its descendants in one operation.

        local highlight = self._deleteHighlight -- Clear the visual state immediately so it cannot point at a destroyed instance.

        if highlight then
            highlight.Adornee = nil
            highlight.Enabled = false
        end
    end
end

-- Cancel clears temporary building/deleting state but keeps the controller itself alive for later use.
function PlacementController.Cancel(self: PlacementControllerType) -- Resets temporary state without destroying the controller itself.
    self._placing = false -- Stop the building update path.
    self._canPlace = false -- Invalidate any previous collision result.
    self._deleting = false -- Canceling is also used when switching modes.

    self._selectedBlock = nil -- Release the active template reference.
    self._preview = nil -- The actual preview instance is cleaned by the child Trove.
    self._lastValidPlacement = nil -- Remove the cached visual state.

    self._blockSize = nil -- Dimensions belong only to the active selection.
    self._blockPivotOffset = nil -- Pivot information must not leak into a future selection.

    self._visualPosition = nil -- Reset interpolation because the next preview may be a completely different object.
    self._visualRotation = nil
    self._targetCFrame = nil -- Prevent stale placement from being reused after cancellation.

    self._previewTrove:Clean() -- Destroy all temporary preview resources while leaving permanent event connections alive.
    self:UpdateFilters() -- Rebuild filters because the preview reference has now been removed.

    if self._deleteHighlight then -- Cancel must also clear any deletion feedback left on screen.
        self._deleteHighlight.Enabled = false
        self._deleteHighlight.Adornee = nil
    end
end

-- Final cleanup: remove temporary state and disconnect/destroy everything owned by the controller.
function PlacementController.Destroy(self: PlacementControllerType) -- Provides a complete lifecycle endpoint for the controller.
    self:Cancel() -- Temporary state is cleaned before permanent resources are removed.
    self._trove:Destroy() -- Trove disconnects registered events and destroys tracked instances, preventing event/instance leaks.
end

-- Create the controller once when this module/script is loaded.
local controller = PlacementController.new() -- Construction initializes state, creates the highlight, and connects the controller to Roblox events.

return controller -- Returning the instance allows another client script to retain or control the initialized system.
