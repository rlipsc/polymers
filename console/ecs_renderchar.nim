#[
  This ECS plugin adds the RenderChar component to allow ascii graphics on terminals.
  The x and y components are translated from -1.0 .. 1.0 to scale between 
  zero and width/ height.

  Each square keeps track of which render instances invoked it's character, and
  only the first entity to render to a clear cell will be shown.
]#

import polymorph, terminal
export terminal

template defineRenderChar*(componentOptions: static[ECSCompOptions], systemOptions: static[ECSSysOptions]): untyped {.dirty.} =
  from winlean import Handle
  
  ## Add types and define systems for rendering x,y positions of characters to the terminal.
  registerComponents(componentOptions):
    type
      RenderChar* = object
        x*, y*: float
        character*: char
        colour*: ForegroundColor
        backgroundColour*: BackgroundColor
        # calculated vars:
        charX*, charY*, index*: int
        lastIndex*: int
        moved*: bool
        hidden*: bool
        foreIntensity*: bool
        backIntensity*: bool
      # This component forces a character to be used based on the current cell's count.
      DensityChar* = object
      RenderString* = object
        # Render a string using a series of character chars.
        x*, y*: float
        text*: string
        colour*: ForegroundColor
        backgroundColour*: BackgroundColor
        # calculated vars:
        lastText*: string
        lastX*, lastY*: float
        lastColour*: ForegroundColor
        characters*: seq[EntityRef]
        forceUpdate*: bool
        maxWidth*: int

  RenderChar.onAdd:
    if curComponent.backGroundColour notin
      BackgroundColor.low .. BackgroundColor.high:
        curComponent.backGroundColour = bgBlack
    if curComponent.colour notin
      ForegroundColor.low .. ForegroundColor.high:
        curComponent.colour = fgWhite

  RenderString.onAdd:
    if curComponent.backGroundColour notin
      BackgroundColor.low .. BackgroundColor.high:
        curComponent.backGroundColour = bgBlack
    if curComponent.colour notin
      ForegroundColor.low .. ForegroundColor.high:
        curComponent.colour = fgWhite

  type  
    CharState* = enum csClear, csDoClear, csCharacter
    CharCellState* = tuple[
      render: RenderCharInstance,
      entity: EntityRef,
      state: CharState,
      character: char,
      count: Natural,
      density: float,
      maxColour: ForegroundColor,
      maxBackgroundColour: BackgroundColor
      ]
    # Console block
    CharInfo = object
      character: uint16
      attributes: uint16
    ConsoleBlock = seq[CharInfo]
    CharCoord = object
      x, y: uint16
    SmallRect = object
      left, top, right, bottom: uint16

  const
    defaultWidth = 80
    defaultHeight = 20
  
  defineSystem("updateState", [RenderChar], systemOptions)
  defineSystem("calcDensity", [RenderChar], systemOptions)
  defineSystem("densityChar", [RenderChar, DensityChar], systemOptions)

  defineSystem("renderString", [RenderString], systemOptions):
    charWidth {.pub.}       -> float = 2.0 / defaultWidth.float
    charHeight {.pub.}      -> float = 2.0 / defaultHeight.float

  defineSystem("renderChar", [RenderChar], systemOptions):
    width {.pub.}           -> int = defaultWidth
    height {.pub.}          -> int = defaultHeight
    foregroundCol {.pub.}   -> ForegroundColor = fgWhite
    backgroundCol {.pub.}   -> BackgroundColor = bgBlack
    states {.pub.}          -> seq[CharCellState] = newSeq[CharCellState](sys.width * sys.height)
    maxDensity {.pub.}      : Natural # Populated in the update systems.
    hWidth {.pub.}          -> int = defaultWidth div 2
    hHeight {.pub.}         -> int = defaultHeight div 2
    charWidth {.pub.}       -> float = 2.0 / defaultWidth.float
    charHeight {.pub.}      -> float = 2.0 / defaultHeight.float
    charSize {.pub.}        -> float = (sys.charWidth + sys.charHeight) / 2.0
    offset {.pub.}          : tuple[x, y: int]
    consoleOut              -> ConsoleBlock = newSeq[CharInfo](sys.states.len)
    stdOutHandle            : Handle
    bufferSize              -> CharCoord = CharCoord(x: sys.width.uint16, y: sys.height.uint16)
    bufferCoord             -> CharCoord = CharCoord(x: sys.offset.x.uint16, y: sys.offset.y.uint16)
    writeRegion             -> SmallRect = SmallRect(
                                left: sys.offset.x.uint16,
                                top: sys.offset.y.uint16,
                                right: sys.width.uint16,
                                bottom: sys.height.uint16)

  # Utility functions
  ###################

  proc setDimensions*(sys: var RenderCharSystem, width, height: Natural) =
    sys.width = width
    sys.height = height
    sys.hWidth = sys.width div 2
    sys.hHeight = sys.height div 2
    sys.charWidth = 2.0 / sys.width.float
    sys.charHeight = 2.0 / sys.height.float
    sys.charSize = (sys.charWidth + sys.charHeight) / 2.0
    sys.bufferSize = CharCoord(x: sys.width.uint16, y: sys.height.uint16)
    sys.bufferCoord = CharCoord(x: sys.offset.x.uint16, y: sys.offset.y.uint16)
    sys.writeRegion = SmallRect(
      left: sys.offset.x.uint16,
      top: sys.offset.y.uint16,
      right: sys.width.uint16,
      bottom: sys.height.uint16)
    sys.states.setLen sys.width * sys.height

  proc setDimensions*(sys: var RenderStringSystem, width, height: Natural) =
    sys.charWidth = 2.0 / width.float
    sys.charHeight = 2.0 / height.float

  template clear*(sys: var RenderCharSystem, index: int): untyped =
    ## Queue an index for clearing.
    ## Note that if the RenderChar for this index isn't actually deleted, it will be re-added in the update system.
    if index.validCharIdx and sys.states[index].state notin [csClear, csDoClear]:
      sys.states[index].state = csDoClear
      # Update the state's item count.
      let count = sys.states[index].count
      sys.states[index].count = max(0, count - 1)

  template clear*(sys: var RenderCharSystem, renderInst: RenderCharInstance): untyped =
    ## Clears current position if this render instance is currently being displayed.
    ## Note that if the RenderChar isn't actually deleted, it will be re-added in the update system.
    if renderInst.index.validCharIdx and sys.states[renderInst.index].render == renderInst:
      sys.clear(renderInst.index)

  template clearLastPos*(sys: var RenderCharSystem, renderInst: RenderCharInstance): untyped =
    ## Clears last calculated position if this render instance is currently being displayed.
    if renderInst.lastIndex.validCharIdx and sys.states[renderInst.lastIndex].render == renderInst:
      sys.clear(renderInst.lastIndex)

  template charPos*(x, y: float, hWidth, hHeight: int): tuple[x, y: int] =
    ## Returns cell coordinates of render.
    (int(hWidth.float + x * hWidth.float),
    int(hHeight.float + y * hHeight.float))
    
  template charPos*(sys: RenderCharSystem, render: RenderCharInstance): tuple[x, y: int] =
    ## Returns cell coordinates of render component.
    charPos(render.x, render.y, sys.hWidth, sys.hHeight)
    
  template validCharIdx*(sys: RenderCharSystem, index: int): bool = index in 0 ..< sys.states.len
  template charPosIndex*(sys: RenderCharSystem, x, y: int): int = y * sys.width + x
  proc charPosIndex*(sys: RenderCharSystem, pos: tuple[x, y: int]): int {.inline.} = sys.charPosIndex(pos.x, pos.y)
  template charPosIndex*(sys: RenderCharSystem, x, y: float): int = 
    sys.charPos(x, y, sys.hWidth, sys.hHeight).charPosIndex

  template charPos*(x, y: float): tuple[x, y: int] = charPos(x, y, sysRenderChar.hWidth, sysRenderChar.hHeight)

  template clear*(index: int): untyped = sysRenderChar.clear(index)
  template clear*(renderInst: RenderCharInstance): untyped = sysRenderChar.clear(renderInst)
  template clearLastPos*(renderInst: RenderCharInstance): untyped = sysRenderChar.clearLastPos(renderInst)

  template charPos*(render: RenderCharInstance): tuple[x, y: int] = sysRenderChar.charPos(render)
  template validCharIdx*(index: int): bool = sysRenderChar.validCharIdx(index)
  template charPosIndex*(x, y: int): int = y * sysRenderChar.width + x
  proc charPosIndex*(pos: tuple[x, y: int]): int = sysRenderChar.charPosIndex(pos.x, pos.y)

  template charIndexCoord*(sys: RenderCharSystem, index: int): tuple[x, y: float] =
    let
      nx = (index mod sys.width).float / sys.width.float 
      ny = (index div sys.width).float / sys.height.float
      sx = (nx * 2.0) - 1.0
      sy = (ny * 2.0) - 1.0
    (x: sx, y: sy)

  template charIndexCoord*(index: int): untyped = sysRenderChar.charIndexCoord(index)

  template normaliseCharCoords*(x, y: int): tuple[x, y: float] =
    ## Converts character coordinates to normalised -1.0 .. 1.0 space.
    charPosIndex(x, y).charIndexCoord()

  template indexCentre*(sys: RenderCharSystem, index: int): untyped =
    let r = sys.charIndexCoord(index)
    (x: r.x + sys.charWidth * 0.5, y: r.y + sys.charHeight * 0.5)

  template indexCentre*(index: int): untyped = sysRenderChar.indexCentre(index)

  template centreCharCoord*(x, y: float): tuple[x, y: float] = charPos(x, y).charPosIndex.indexCentre

  ## Returns the x offset to add to x to center a RenderString.
  template centreX*(value: string): float = -value.len.float * 0.5 * sysRenderChar.charWidth

  # Used in DensityChar.
  proc asChar*(num: float): char =
    ## Min/maxes outside of 0.0 .. 1.0
    if    num < 0.001: '`'
    elif  num < 0.002: '.'
    elif  num < 0.005: ','
    elif  num < 0.01: '\''
    elif  num < 0.02: '-'
    elif  num < 0.05: '='
    elif  num < 0.1:  '+'
    elif  num < 0.2:  '*'
    elif  num < 0.3:  '%'
    elif  num < 0.4:  '8'
    elif  num < 0.5:  'O'
    elif  num < 0.8:  '@'
    else: '#'

  # Initialising/de-initialising
  ##############################

  RenderChar.onRemove:
    # Mark this display char as clear when a RenderChar is removed from an entity
    # or the entity is deleted.
    curComponent.clear
  RenderString.onRemoveCallback:
    # Remove stored entities.
    for characterEnt in curComponent.characters:
      let charComp = characterEnt.fetchComponent RenderChar
      assert charComp.valid
      # Triggers RenderChar's onRemove.
      characterEnt.delete                       # TODO: Should see delete!?

template addRenderCharUpdate*(): untyped =
  ## Insert systems for updating the state of `RenderChar` and
  ## `RenderString` without rendering.
  ## This can be useful if you need to use the char's `index` or
  ## `density` fields, to ensure `RenderString`'s `character` is
  ## updated to it's `text` field, or want to manipulate them
  ## before rendering.
  makeSystemBody("renderString"):
    all:
      # TODO: Currently only updates default instance of sysRenderChar.
      let
        rs = item.renderString
        coordChange = rs.x != rs.lastX or rs.y != rs.lastY
        colourChange = rs.colour != rs.lastColour
        textChange = rs.text != rs.lastText
        forceUpdate = rs.forceUpdate

      if forceUpdate or coordChange or colourChange or textChange:
        # Something's changed and we need to update.
        var curX = rs.x
        let curY = rs.y
        for i in 0 .. min(rs.characters.high, rs.text.high):
          var
            curChar = rs.text[i]
            curRenderEnt = rs.characters[i]
          
          if not curRenderEnt.alive:
            curRenderEnt = newEntityWith(
              RenderChar(x: curX, y: curY, character: curChar,
                colour: rs.colour, backgroundColour: rs.backgroundColour))
            rs.characters[i] = curRenderEnt
          
          let renderChar = curRenderEnt.fetchComponent RenderChar
          assert renderChar.valid
            
          if i > rs.maxWidth: renderChar.hidden = true
          else: renderChar.hidden = false
          
          if forceUpdate or coordChange or curChar != renderChar.character:
            # Update entity's character.        
            renderChar.character = curChar

            if forceUpdate or coordChange:
              renderChar.x = curX
              renderChar.y = curY

            if forceUpdate or colourChange:
              renderChar.colour = rs.colour
            
          curX += sys.charWidth
        
        # Adapt to length changes.
        let diff = rs.text.len - rs.characters.len
        if diff > 0:
          # Extend character array.
          let
            curY = rs.y
            start = rs.characters.len
          var curX = rs.x + start.float * sys.charWidth
          
          rs.characters.setLen rs.text.len

          for cIdx in start ..< rs.text.len:
            let c = rs.text[cIdx]

            if curX < 1.0:
              let newChar = newEntityWith(RenderChar(x: curX, y: curY, character: c, colour: rs.colour))
              rs.characters[cIdx] = newChar
            else:
              # We've gone off the edge of the screen so trim the entity list.
              rs.characters.setLen cIdx
              break
            curX += sys.charWidth
        elif diff < 0:
          # Remove trailing character entities.
          for i in countDown(rs.characters.high, rs.text.len):
            let
              charEnt = rs.characters[i]
              render = charEnt.fetchComponent RenderChar
            assert render.valid

            # Mark this cell as cleared.
            let index = render.index
            if index.validCharIdx:
              sysRenderChar.states[index].state = csDoClear
            
            charEnt.delete
          rs.characters.setLen rs.text.len

        rs.lastText = rs.text
        rs.lastColour = rs.colour
        rs.lastX = rs.x
        rs.lastY = rs.y

  makeSystemBody("updateState"):
    all:
      # Convert x, y into character position and index.
      if not item.renderChar.hidden:
        let (x, y) = sysRenderChar.charPos(item.renderChar)
        if item.renderChar.charX != x or item.renderChar.charY != y:
          item.renderChar.moved = true
          item.renderChar.clearLastPos
          item.renderChar.lastIndex = item.renderChar.index
          item.renderChar.charX = x
          item.renderChar.charY = y
          # Update index.
          item.renderChar.index = charPosIndex(x, y)
        else:
          item.renderChar.moved = false

  makeSystemBody("calcDensity"):
    start:
      sysRenderChar.maxDensity = 0
      for i in 0..<sysRenderChar.states.len:
        sysRenderChar.states[i].count = 0
    all:
      # Update density per character
      if item.renderChar.index.validCharIdx:
        let idx = item.renderChar.index
        template curState: untyped = sysRenderChar.states[idx]
        
        let density = curState.count + 1
        if density > sysRenderChar.maxDensity:
          sysRenderChar.maxDensity = density
        
        curState.count = density

  makeSystemBody("densityChar"):
    all:
      # This system actually affects the next frame's character.
      if item.renderChar.index.validCharIdx:
        let count = sysRenderChar.states[item.renderChar.index].count
        assert count > 0
        # Normalise count to the maximum density seen.
        let
          nCount = count.float / sysRenderChar.maxDensity.float
          selectedChar = nCount.asChar
        # Overwrite current char.
        item.renderChar.character = selectedChar

template addRenderCharOutput*(): untyped =
  ## Implement the system for outputting the RenderChars.
  from winlean import getStdHandle, STD_OUTPUT_HANDLE, WINBOOL
  
  proc writeConsoleOutput*(hConsoleOutput: Handle, lpBuffer: ptr CharInfo, dwBufferSize, dwBufferCoord: CharCoord, lpWriteRegion: ptr SmallRect
    ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "WriteConsoleOutputW".}

  makeSystemBody("renderChar"):
    init:
      sys.stdOutHandle = getStdHandle(STD_OUTPUT_HANDLE)
      if 1 == 0: quit $sys.consoleOut.len
    start:
      sys.consoleOut.setLen sys.states.len
      # Reset colour count per char.
      for i in 0 ..< sys.states.len:
        sys.states[i].maxColour = fgBlack
        sys.states[i].maxBackgroundColour = bgBlack 
    all:
      # Update draw state grid from RenderChar components.
      if item.renderChar.index.validCharIdx and item.renderChar.x in -1.0 .. 1.0:
        let idx = item.renderChar.index
        template curState: untyped = sys.states[idx]
        let
          ownsCell = curState.render == item.renderChar
          curCol = item.renderChar.colour
          curBCol = item.renderChar.backgroundColour
        
        if curCol > curState.maxColour:
          curState.maxColour = curCol
        if curBCol > curState.maxBackgroundColour:
          curState.maxBackgroundColour = curBCol

        if curState.state in [csClear, csDoClear]:
          # Take ownership of this cell.
          curState.render = item.renderChar
          curState.entity = item.entity
          curState.state = csCharacter
          curState.character = item.renderChar.character
        elif ownsCell:
          # Update owned cell state.
          curState.character = item.renderChar.character
    finish:
      const
        FOREGROUND_BLUE = 1
        FOREGROUND_GREEN = 2
        FOREGROUND_RED = 4
        FOREGROUND_INTENSITY = 8
        BACKGROUND_INTENSITY = 128
        BACKGROUND_BLUE = 16
        BACKGROUND_GREEN = 32
        BACKGROUND_RED = 64
        lookupFg: array[ForegroundColor, int] = [
          0,
          (FOREGROUND_RED),
          (FOREGROUND_GREEN),
          (FOREGROUND_RED or FOREGROUND_GREEN),
          (FOREGROUND_BLUE),
          (FOREGROUND_RED or FOREGROUND_BLUE),
          (FOREGROUND_BLUE or FOREGROUND_GREEN),
          (FOREGROUND_BLUE or FOREGROUND_GREEN or FOREGROUND_RED),
          0,
          0]
        lookupBg: array[BackgroundColor, int] = [
          0, # BackgroundColor enum with ordinal 40
          (BACKGROUND_RED),
          (BACKGROUND_GREEN),
          (BACKGROUND_RED or BACKGROUND_GREEN),
          (BACKGROUND_BLUE),
          (BACKGROUND_RED or BACKGROUND_BLUE),
          (BACKGROUND_BLUE or BACKGROUND_GREEN),
          (BACKGROUND_BLUE or BACKGROUND_GREEN or BACKGROUND_RED),
          0,
          0]
      
      for i in 0 ..< sys.states.len:
        template curState: untyped = sys.states[i]
        template curOutputCell: untyped = sys.consoleOut[i]
        if curState.state == csCharacter and curState.render.valid:
          # Update console out block.
          curOutputCell.character = curState.character.ord.uint16
          let
            fi: uint16 = if curState.render.foreIntensity: FOREGROUND_INTENSITY else: 0
            bi: uint16 = if curState.render.backIntensity: BACKGROUND_INTENSITY else: 0
          curOutputCell.attributes = lookupFg[curState.maxColour].uint16 or fi or lookupBg[curState.maxBackgroundColour].uint16 or bi
        else:
          curOutputCell.character = ' '.ord.uint16
          curOutputCell.attributes = lookupFg[sys.foregroundCol].uint16 or lookupBg[sys.backgroundCol].uint16
      doAssert(writeConsoleOutput(
        sys.stdOutHandle,
        sys.consoleOut[0].addr,
        sys.bufferSize,
        sys.bufferCoord,
        sys.writeRegion.addr) != 0)

template addRenderCharSystems*: untyped =
  ## Update then render, for when you have no need to work with
  ## state before rendering.
  addRenderCharUpdate()
  addRenderCharOutput()

when isMainModule:

  # Simple demo of bouncing chars

  import random
  from math import cos, sin, TAU, sqrt, arctan2, degToRad
  
  const
    # Try with a million entities and -d:release -d:danger
    # RenderChar uses the numerically highest colours when drawing. 
    maxEnts = 1000
    entOpts = dynamicSizeEntities()
    compOpts = dynamicSizeComponents()
    sysOpts = dynamicSizeSystem()
    sysEvery = ECSSysOptions(timings: stRunEvery)
  defineRenderChar(compOpts, sysOpts)
  addRenderCharSystems()

  registerComponents(compOpts):
    type Velocity = object
      x, y, maxSpeed: float

  # Some support math
  type Vect = tuple[x, y: float]
  proc dot*(a, b: Vect):float = a[0] * b[0] + a[1] * b[1]
  proc `-`(a: Vect, b: Vect): Vect = (a.x - b.x, a.y - b.y)
  proc `*`(a: float, b: Vect): Vect = (a * b.x, a * b.y)
  proc reflect*(I, N: Vect): Vect = I - 2.0 * dot(N, I) * N

  makeSystemOpts("nBody", [RenderChar, Velocity], sysEvery):
    all:
      if item.renderChar.index.validCharIdx:
        let
          us = item.renderChar
          them = sysRenderChar.states[us.index].render
          gravity = 0.02
        if us != them:
          let theirEnt = sysRenderChar.states[us.index].entity
          if theirEnt.alive:
            let theirVel = theirEnt.fetchComponent Velocity
            if theirVel.valid:
              
              let
                v = item.velocity
                diff = (x: us.x - them.x, y: us.y - them.y)
                #diff = (x: v.x, y: v.y)
                length = max(0.01, sqrt(diff.x * diff.x + diff.y * diff.y))
                normal1 = (x: diff.x / length, y: diff.y / length)
                r1 = reflect((v.x, v.y), normal1)
              
                normal2 = (x: -normal1.x, y: -normal1.y)
                r2 = reflect((diff.x, diff.y), normal2)
              
              const decay = 0.4
              
              v.x = r1.x * decay
              v.y = r1.y * decay
              theirVel.x = r2.x * decay
              theirVel.y = r2.y * decay
            
              let aboveIdx = us.index - sysRenderChar.width
              if aboveIdx.validCharIdx:
                let pos = aboveIdx.indexCentre
                item.renderChar.x = pos.x
                item.renderChar.y = pos.y
                #v.y = v.y * decay
            else:
              # What we hit didn't have a velocity.
              item.velocity.x *= -0.6
              item.velocity.y *= -0.6        

        let
          belowIdx = us.index + sysRenderChar.width
          leftIdx = us.index - 1
          rightIdx = us.index + 1
          lowerLim = -1.0 + sysRenderChar.charWidth
          upperLim =  1.0 - sysRenderChar.charWidth
        if belowIdx.validCharIdx and sysRenderChar.states[belowIdx].state != csCharacter:
            item.renderChar.y += gravity
        elif item.renderChar.index mod 2 == 1:
          if item.renderChar.x > lowerLim and leftIdx.validCharIdx and sysRenderChar.states[leftIdx].state != csCharacter:
            item.renderChar.x -= gravity
        elif item.renderChar.x < upperLim and rightIdx.validCharIdx and sysRenderChar.states[rightIdx].state != csCharacter:
            item.renderChar.x += gravity
        item.renderChar.x += item.velocity.x
        item.renderChar.y += item.velocity.y

  makeSystemOpts("constrainArea", [RenderChar, Velocity], sysEvery):
    all:
      let
        lowCentre = 0.indexCentre
        highCentre = sysRenderChar.states.high.indexCentre
      const
        # Wall normals
        left = (1.0, 0.0)
        right = (-1.0, 0.0)
        top = (0.0, 1.0)
        bottom = (0.0, -1.0)

      template reflect(normal: Vect) =
        let
          r = reflect((item.velocity.x, item.velocity.y), normal)
          decay = rand 0.1..0.199
        item.velocity.x = r.x * decay
        item.velocity.y = r.y * decay
      
      if item.renderChar.x < lowCentre.x:
        item.renderChar.x = lowCentre.x
        reflect(left)
      elif item.renderChar.x > highCentre.x:
        item.renderChar.x = highCentre.x
        reflect(right)
      if item.renderChar.y < lowCentre.y:
        item.renderChar.y = lowCentre.y
        reflect(top)
      elif item.renderChar.y > highCentre.y:
        item.renderChar.y = highCentre.y
        reflect(bottom)
      
  makeEcs(entOpts)
  commitSystems("run")
  ####################

  sysRenderChar.setDimensions(70, 35)
  eraseScreen()
  setCursorYPos 0

  let updateRate = 1.0 / 60.0
  sysNBody.runEvery = updateRate
  sysConstrainArea.runEvery = updateRate
  
  let
    speedJitter = 0.0005
    speedStart = 0.0001
    speedRange = speedStart .. speedStart + speedJitter
    startArea = -0.5..0.5
  for i in 0..<maxEnts:
    let
      angle = rand TAU
      speed = rand speedRange
      fgCol = rand fgRed .. fgWhite
      bgCol = rand bgBlack .. bgCyan
      intense = if rand(0..1) == 1: true else: false
    discard newEntityWith(
      RenderChar(x: rand startArea, y: rand startArea, character: rand 'a'..'z', colour: fgCol, backgroundColour: bgCol, foreIntensity: intense),
      Velocity(x: speed * cos(angle), y: speed * sin(angle), maxSpeed: 0.05)
      )
  while true:
    run()
