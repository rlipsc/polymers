## The module lets you create grid mapping components and associated systems.
## 
## Entities with a grid map and position component can be queried within a radius.
## 
## Example:
## 
##    import polymorph, polymers
## 
##    const
##      compOpts = defaultCompOpts
##      sysOpts = defaultSysOpts
##
##    # Create a position component for the grid maps to use.
##    registerComponents(compOpts):
##      type
##        Position* = object
##          x, y: float
##
##    # Use the default "GridMap" component name with no operator postfix.
##    defineGridMap(0.04, Position, compOpts, sysOpts)
##    # Create an "OtherGrid` component. Query operators are postfixed with "other".
##    defineGridMap(0.04, Position, "OtherGrid", "other", compOpts, sysOpts)
##
##    makeEcs()
##    commitSystems("run")
##
##    # Create entities to be added to the grids.
##    let
##      e1 = newEntityWith(
##        Position(x: 0.1, y: 0.6),
##        GridMap()
##      )
##      e2 = newEntityWith(
##        Position(x: -0.8, y: 0.3),
##        OtherGrid()
##      )
##
##    # Grids are only update when their systems are run.
##    run()
##
##    # Query the "GridMap" map.
##    for found in queryGrid(0.2, 0.5, 0.2):
##      assert found == e1
##
##    # Query the "OtherGrid" map.
##    for found in queryGridOther(-0.7, 0.2, 0.2):
##      assert found == e2

import polymorph

template defineGridMap*(gridRes: static[float], positionType: typedesc, gridCompName, opPostfix: static[string], compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  ## Define a grid based spatial mapping component and associated system.
  ## The component and system names are provided with `gridCompName`.
  ## `opPostFix` is added to the end of utilities for this component.
  ## 
  ## This allows multiple grid map components to be defined, each with separate system and query operations.
  ## You can create multiple 
  ## 
  ## Assumes coordinates are in the range -1.0 .. 1.0, and that items only occupy
  ## a single grid square.
  ## `positionType` can be any type that includes `x` and `y` fields of `SomeFloat`.
  from strutils import toLowerAscii
  from math import sqrt

  # The system is wrapped in a macro so we can incorporate the provided `positionType`.
  macro `genSystem opPostfix`: untyped =
    let
      posIdent = ident ($positionType).toLowerAscii
      posIdentInst = ident $positionType & "Instance"
      dist = ident "dist"
      entity = ident "entity"
      gridComp = ident gridCompName
      lcGridComp = gridCompName.toLowerAscii
      gridCompIdent = ident lcGridComp
      gridCompInstance = ident $gridCompName & "Instance"

      gridResolution = ident "gridResolution" & opPostfix

      itemsAt = ident "itemsAt"
      queryGrid = ident "queryGrid" & opPostfix
      queryGridPrecise = ident "queryGridPrecise" & opPostfix
      toGridPos = ident "toGridPos" & opPostFix
      
      gridMapSysName = newLit lcGridComp
      gridMapSysIdent = ident "sys" & lcGridComp

      # These idents (instead of genSym) just make the query parameters
      # easier to read.
      x = ident "x"
      y = ident "y"
      r = ident "radius"

    # The position type and instance is injected into the gridMap systems.
    result = quote do:
      registerComponents(compOpts):
        type
          `gridComp`* = object
            gridIndex*: int

      # Initialise this component so (0, 0) gets updated.
      `gridComp`.onAdd: curComponent.gridIndex = -1

      const
        `gridResolution`* = int(2.0 / `gridRes`)
        
      template `toGridPos`*(x, y: SomeFloat): int =
        let
          normX = x * 0.5 + 0.5
          normY = y * 0.5 + 0.5
          gridPos = [normX * `gridResolution`.float, normY * `gridResolution`.float]
        gridPos[1].int * `gridResolution` + gridPos[0].int

      makeSystemOpts(`gridMapSysName`, [`gridComp`, positionType], sysOpts):
        # Update the mapping.

        fields:
          # The grid has an extra row at the higher extent to handle y coordinates of 1.0.
          grid: array[0 .. `gridResolution` * `gridResolution` + `gridResolution`, seq[EntityRef]]

        all:
          # Stores entities with `gridComp` at a grid slot according to `Position`. 
          let
            gridIdx = `toGridPos`(item.`posIdent`.x, item.`posIdent`.y)
            lastIdx = item.`gridCompIdent`.gridIndex

          if gridIdx != lastIdx:
            if lastIdx in 0 ..< sys.grid.len:
              # Remove from last grid square.
              let existingIdx = sys.grid[lastIdx].find(item.entity)
              if existingIdx > -1: sys.grid[lastIdx].del(existingIdx)
            if gridIdx in 0 ..< sys.grid.len:
              # Update grid square.
              sys.grid[gridIdx].add item.entity
              item.`gridCompIdent`.gridIndex = gridIdx

      `gridComp`.onSystemRemoveFrom `gridMapSysName`:
        # Handle removal from grid.
        let gridIdx = curComponent.gridIndex
        if gridIdx in 0 ..< curSystem.grid.len:
          let existingIdx = curSystem.grid[gridIdx].find(curEntity)
          if existingIdx > -1: curSystem.grid[gridIdx].del(existingIdx)
      
      onEcsBuilt:
        # These iterators expect a fully defined ECS and must be placed
        # after makeEcs().

        iterator `itemsAt`*[T](gm: `gridComp` | `gridCompInstance`): EntityRef =
          if gm.gridIndex >= 0:
            for entity in `gridMapSysName`.grid[gm.gridIndex]:
              yield entity
        
        iterator `queryGrid`*(`x`, `y`, `r`: SomeFloat): EntityRef =
          ## Queries the grid for entities.
          ## This is accurate to the grid's resolution.
          let
            blockRadius = max(1, int(`r` * `gridResolution`.float))
            sBlockRadius = blockRadius * blockRadius
            # Normalise coordinates to grid space.
            nX = `x` * 0.5 + 0.5
            nY = `y` * 0.5 + 0.5
            gridPos = [int(nX * `gridResolution`.float), int(nY * `gridResolution`.float)]

          for by in max(0, gridPos[1] - blockRadius) .. min(gridPos[1] + blockRadius, `gridResolution`):
            for bx in max(0, gridPos[0] - blockRadius) .. min(gridPos[0] + blockRadius, `gridResolution`):
              let
                diffX = gridPos[0] - bx
                diffY = gridPos[1] - by
                sDist = diffX * diffX + diffY * diffY
              if sDist <= sBlockRadius:
                let index = by * `gridResolution` + bx
                for entity in `gridMapSysIdent`.grid[index]:
                  yield entity

        iterator `queryGridPrecise`*(`x`, `y`, `r`: SomeFloat): tuple[`entity`: EntityRef, `posIdent`: `posIdentInst`, `dist`: float] =
          ## Queries the grid for entities.
          ## This is accurate to exactly `radius`.
          let sRadius = `r` * `r`
          for entity in `queryGrid`(`x`, `y`, `r`):
            let pos = entity.fetch positionType
            assert pos.valid
            let
              diffX = pos.access.x - `x`
              diffY = pos.access.y - `y`
              sDist = diffX * diffX + diffY * diffY
            if sDist <= sRadius:
              yield (entity, pos, sqrt(sDist))
  
  `genSystem opPostfix`()

template defineGridMap*(gridRes: static[float], positionType: typedesc, compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  ## Define a `GridMap` component and associated system.
  ## Entities with `GridMap` and `positionType` can be queried by position and radius.
  ## Assumes coordinates are in the range -1.0 .. 1.0, and that items only occupy
  ## a single grid square.
  ## `positionType` can be any type that includes `x` and `y` fields of `SomeFloat`.
  defineGridMap(0.04, positionType, "GridMap", "", compOpts, sysOpts)  


when isMainModule:
  import unittest, random
  
  const
    compOpts = defaultCompOpts
    sysOpts = defaultSysOpts

  registerComponents(compOpts):
    type
      Position* = object
        x, y: float

  defineGridMap(0.04, Position, compOpts, sysOpts)
  defineGridMap(0.04, Position, "GridMap1", "1", compOpts, sysOpts)
  defineGridMap(0.04, Position, "GridMap2", "2", compOpts, sysOpts)

  makeEcs()
  commitSystems("run")

  suite "Grid mapping":
    var
      e, e1, e2: Entities
      p, p1, p2: seq[Position]
    test "Add entities to grids":
      let
        entityTests = 3

      for i in 0 ..< entityTests:
        template randPos: Position =
          Position(
            x: rand -0.99 .. 0.99,
            y: rand -0.99 .. 0.99
          )
        
        p.add randPos()
        e.add newEntityWith(
          p[^1],
          GridMap()
        )

        p1.add randPos()
        e1.add newEntityWith(
          p1[^1],
          GridMap1()
        )

        p2.add randPos()
        e2.add newEntityWith(
          p2[^1],
          GridMap2()
        )

    # Update system grids.
    run()

    test "Check positions":
      const tolerance = 0.01

      template testPositions(posList, entList, queryIter: untyped, tolerance: float) =
        for i, p in posList:
          var found: bool
          for ePos in queryIter(p.x, p.y, tolerance):
            if ePos.position.access == p and ePos.entity in entList:
              found = true
              break
          check found
      
      testPositions(p, e, queryGridPrecise, tolerance)
      testPositions(p1, e1, queryGridPrecise1, tolerance)
      testPositions(p2, e2, queryGridPrecise2, tolerance)

    echo "Finish."
