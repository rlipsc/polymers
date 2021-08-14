## This ECS plugin adds the RenderChar component to allow ascii graphics on terminals.
## The x and y components are translated from -1.0 .. 1.0 to scale between 
## zero and width/ height.
##
## Each square keeps track of which render instances invoked its character, and
## only the first entity to render to a clear cell will be shown.

import polymorph

template defineRenderChar*(componentOptions: static[ECSCompOptions]): untyped {.dirty.} =
  import terminal
  export terminal
  from winlean import Handle
  
  const
    defaultRCWidth* = 80
    defaultRCHeight* = 20
  
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

  RenderString.onRemoveCallback:
    # Remove stored entities.
    for characterEnt in curComponent.characters:
      let charComp = characterEnt.fetchComponent RenderChar
      assert charComp.valid
      # Triggers RenderChar's onRemove.
      characterEnt.delete

  template charPos*(x, y: float, hWidth, hHeight: int): tuple[x, y: int] =
    ## Returns cell coordinates of render.
    (int(hWidth.float + x * hWidth.float),
    int(hHeight.float + y * hHeight.float))

template defineRenderCharUpdate*(systemOptions: static[ECSSysOptions]): untyped {.dirty.} =
  ## Insert systems for updating the state of `RenderChar` and
  ## `RenderString` without rendering.
  ## This can be useful if you need to use the char's `index` or
  ## `density` fields, to ensure `RenderString`'s `character` is
  ## updated to its `text` field, or want to manipulate them
  ## before rendering.

  defineSystem("updateState", [RenderChar], systemOptions)
  defineSystem("calcDensity", [RenderChar], systemOptions)
  defineSystem("densityChar", [RenderChar, DensityChar], systemOptions)
  defineSystem("renderString", [RenderString], systemOptions):
    charWidth {.pub.}       -> float = 2.0 / defaultRCWidth.float
    charHeight {.pub.}      -> float = 2.0 / defaultRCHeight.float

  proc setDimensions*(sys: var RenderStringSystem, width, height: Natural) =
    sys.charWidth = 2.0 / width.float
    sys.charHeight = 2.0 / height.float

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

  makeSystemBody("renderString"):
    all:
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

template defineRenderCharOutput*(systemOptions: static[ECSSysOptions]): untyped {.dirty.} =
  ## Implement the system for outputting the RenderChars.
  from winlean import getStdHandle, STD_OUTPUT_HANDLE, WINBOOL
  
  proc writeConsoleOutput*(hConsoleOutput: Handle, lpBuffer: ptr CharInfo, dwBufferSize, dwBufferCoord: CharCoord, lpWriteRegion: ptr SmallRect
    ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "WriteConsoleOutputW".}

  makeSystemOpts("renderChar", [RenderChar], systemOptions):
    fields:
      width {.pub.}           -> int = defaultRCWidth
      height {.pub.}          -> int = defaultRCHeight
      foregroundCol {.pub.}   -> ForegroundColor = fgWhite
      backgroundCol {.pub.}   -> BackgroundColor = bgBlack
      states {.pub.}          -> seq[CharCellState] = newSeq[CharCellState](sys.width * sys.height)
      maxDensity {.pub.}      : Natural # Populated in the update systems.
      hWidth {.pub.}          -> int = defaultRCWidth div 2
      hHeight {.pub.}         -> int = defaultRCHeight div 2
      charWidth {.pub.}       -> float = 2.0 / defaultRCWidth.float
      charHeight {.pub.}      -> float = 2.0 / defaultRCHeight.float
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
        if curState.state == csCharacter and curState.render.valid and curState.render.alive:
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

  RenderChar.onRemove:
    # Mark this display char as clear when a RenderChar is removed from an entity
    # or the entity is deleted.
    curComponent.clear

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
    sys.clear(renderInst.index)

  template setChar*(sys: var RenderCharSystem, renderInst: RenderCharInstance): untyped =
    ## Forces a particular character to the display.
    if renderInst.index.validCharIdx:
      sys.states[renderInst.index].render = renderInst
      sys.states[renderInst.index].state = csCharacter
      # Update the state's item count.
      sys.states[renderInst.index].count += 1

  template setChar*(renderInst: RenderCharInstance): untyped = sysRenderChar.setChar(renderInst)

  template charPos*(sys: RenderCharSystem, render: RenderCharInstance): tuple[x, y: int] =
    ## Returns cell coordinates of render component.
    charPos(render.x, render.y, sys.hWidth, sys.hHeight)
    
  template validCharIdx*(sys: RenderCharSystem, index: int): bool = index in 0 ..< sys.states.len

  template clearLastPos*(sys: var RenderCharSystem, renderInst: RenderCharInstance): untyped =
    ## Clears last calculated position if this render instance is currently being displayed.
    if renderInst.lastIndex.validCharIdx and sys.states[renderInst.lastIndex].render == renderInst:
      sys.clear(renderInst.lastIndex)
  template clear*(index: int): untyped = sysRenderChar.clear(index)
  template clear*(renderInst: RenderCharInstance): untyped = sysRenderChar.clear(renderInst)
  template clearLastPos*(renderInst: RenderCharInstance): untyped = sysRenderChar.clearLastPos(renderInst)

  template charPosIndex*(sys: RenderCharSystem, x, y: int): int = y * sys.width + x
  proc charPosIndex*(sys: RenderCharSystem, pos: tuple[x, y: int]): int {.inline.} = sys.charPosIndex(pos.x, pos.y)
  template charPosIndex*(sys: RenderCharSystem, x, y: float): int = charPos(x, y, sys.hWidth, sys.hHeight).charPosIndex
  template charPos*(x, y: float): tuple[x, y: int] = charPos(x, y, sysRenderChar.hWidth, sysRenderChar.hHeight)
  template charPos*(render: RenderCharInstance): tuple[x, y: int] = sysRenderChar.charPos(render)
  template validCharIdx*(index: int): bool = sysRenderChar.validCharIdx(index)
  template charPosIndex*(x, y: int): int = y * sysRenderChar.width + x
  template charPosIndex*(x, y: float): int = charPos(x, y, sysRenderChar.hWidth, sysRenderChar.hHeight).charPosIndex
  proc charPosIndex*(pos: tuple[x, y: int]): int = sysRenderChar.charPosIndex(pos.x, pos.y)

  template charIndexCoord*(sys: RenderCharSystem, index: int): tuple[x, y: float] =
    let
      nx = (index mod sys.width).float / sys.width.float 
      ny = (index div sys.width).float / sys.height.float
      sx = (nx * 2.0) - 1.0
      sy = (ny * 2.0) - 1.0
    (x: sx, y: sy)

  template charIndexCoord*(index: int): untyped = sysRenderChar.charIndexCoord(index)

  proc updateIndex*(render: RenderCharInstance | var RenderChar) =
    ## Updates the index in `render` according to its x and y.
    render.index = sysRenderChar.charPosIndex(render.x, render.y)

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

template defineRenderCharSystems*(systemOptions: static[ECSSysOptions]): untyped =
  ## Update then render, for when you have no need to work with
  ## state before rendering.
  defineRenderCharUpdate(systemOptions)
  defineRenderCharOutput(systemOptions)

