import polymorph

template defineGridMap*(gridRes: static[float], positionType: typedesc, compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  ## Define a grid based spatial mapping component and associated system.
  ## Assumes coordinates are in the range -1.0 .. 1.0, and that items only occupy
  ## a single grid square.
  ## `positionType` can be any type that includes `x` and `y` fields of `SomeFloat`.
  from strutils import toLowerAscii
  from math import sqrt

  registerComponents(compOpts):
    type
      GridMap* = object
        gridIndex*: int

  # Initialise this component so (0, 0) gets updated.
  GridMap.onAdd: curComponent.gridIndex = -1

  const gridResolution = int(2.0 / gridRes)

  template toGridPos(x, y: SomeFloat): int =
    let
      normX = x * 0.5 + 0.5
      normY = y * 0.5 + 0.5
      gridPos = [normX * gridResolution.float, normY * gridResolution.float]
    gridPos[1].int * gridResolution + gridPos[0].int

  # The system is wrapped in a macro so we can incorporate the provided `positionType`.
  macro genSystem: untyped =
    let
      posIdent = ident ($positionType).toLowerAscii
      posIdentInst = ident $positionType & "Instance"
      # These idents (instead of genSym) just make the query parameters
      # easier to read.
      x = ident "x"
      y = ident "y"
      r = ident "radius"

    # The position type and instance is injected into the gridMap systems.
    quote do:
      makeSystemOpts("gridMap", [GridMap, positionType], sysOpts):
        fields:
          # The grid has an extra row at the higher extent to handle y coordinates of 1.0.
          grid: array[0 .. gridResolution * gridResolution + gridResolution, seq[EntityRef]]
        all:
          # Stores entities with `GridMap` at a grid slot according to `Position`. 
          let
            gridIdx = toGridPos(item.`posIdent`.x, item.`posIdent`.y)
            lastIdx = item.gridMap.gridIndex

          if gridIdx != lastIdx:
            if lastIdx in 0 ..< sys.grid.len:
              # Remove from last grid square.
              let existingIdx = sys.grid[lastIdx].find(item.entity)
              if existingIdx > -1: sys.grid[lastIdx].del(existingIdx)
            if gridIdx in 0 ..< sys.grid.len:
              # Update grid square.
              sys.grid[gridIdx].add item.entity
              item.gridMap.gridIndex = gridIdx

      GridMap.onSystemRemoveFrom "gridMap":
        # Handle removal from grid.
        let gridIdx = curComponent.gridIndex
        if gridIdx in 0 ..< curSystem.grid.len:
          let existingIdx = curSystem.grid[gridIdx].find(curEntity)
          if existingIdx > -1: curSystem.grid[gridIdx].del(existingIdx)
      
      onEcsBuilt:
        # These iterators expect a fully defined ECS and must be placed
        # after makeEcs().

        iterator itemsAt*[T](gm: GridMap | GridMapInstance): EntityRef =
          if gm.gridIndex >= 0:
            for entity in sysGridMap.grid[gm.gridIndex]:
              yield entity
        
        iterator queryGrid*(`x`, `y`, `r`: SomeFloat): EntityRef =
          ## Queries the grid for entities.
          ## This is accurate to the grid's resolution.
          let
            blockRadius = max(1, int(`r` * gridResolution.float))
            sBlockRadius = blockRadius * blockRadius
            # Normalise coordinates to grid space.
            nX = `x` * 0.5 + 0.5
            nY = `y` * 0.5 + 0.5
            gridPos = [int(nX * gridResolution.float), int(nY * gridResolution.float)]

          for by in max(0, gridPos[1] - blockRadius) .. min(gridPos[1] + blockRadius, gridResolution):
            for bx in max(0, gridPos[0] - blockRadius) .. min(gridPos[0] + blockRadius, gridResolution):
              let
                diffX = gridPos[0] - bx
                diffY = gridPos[1] - by
                sDist = diffX * diffX + diffY * diffY
              if sDist <= sBlockRadius:
                let index = by * gridResolution + bx
                for entity in sysGridMap.grid[index]:
                  yield entity

        iterator queryGridPrecise*(`x`, `y`, `r`: SomeFloat): tuple[entity: EntityRef, position: `posIdentInst`, dist: float] =
          ## Queries the grid for entities.
          ## This is accurate to exactly `radius`.
          let sRadius = `r` * `r`
          for entity in queryGrid(`x`, `y`, `r`):
            let pos = entity.fetch positionType
            assert pos.valid
            let
              diffX = pos.access.x - `x`
              diffY = pos.access.y - `y`
              sDist = diffX * diffX + diffY * diffY
            if sDist <= sRadius:
              yield (entity, pos, sqrt(sDist))
  
  genSystem()
