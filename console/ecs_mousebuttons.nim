import polymorph, polyshards

template defineMouseButtons*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  from math import floor

  type
    ButtonBackground* = object
      character*: char
      colour*: BackgroundColor
    ButtonTextAlignment* = enum btaCentre, btaLeft
    ButtonCharType* = enum bctBackground, bctBorder, bctText

  registerComponents(compOpts):
    type
      MouseButton* = object
        x*, y*: float
        size*: tuple[x, y: int]
        text*: string
        textAlign*: ButtonTextAlignment
        forceFocus*: bool
        toggle*: bool

        ## RenderChars for this button.
        characters*: seq[tuple[entity: EntityRef, rc: RenderCharInstance, bc: ButtonCharInstance]]
        
        background*: tuple[focused, unFocused: ButtonBackground]
        border*: tuple[visible: bool, focused, unFocused: ButtonBackground]
        
        mouseOver*: bool
        clicked*: bool
        
        handler*: proc(entity: EntityRef, button: MouseButtonInstance)

      MouseButtonMouseOver* = object
      MouseButtonClicked* = object
        mouseButton*: int
      
      ## Tag an entity to draw a character at the mouse cursor's position.
      DrawMouse* = object
        character*: char
        charEnt: EntityRef
        charRef: RenderCharInstance
      
      ## Tagged to a button's RenderChar entities
      ButtonChar* = object
        button*: MouseButtonInstance
        buttonEnt*: EntityRef
        charType*: ButtonCharType

    DrawMouse.onRemoveCallback:
      curComponent.charEnt.delete
    MouseButton.onRemoveCallback:
      for item in curComponent.characters:
        item.entity.delete

  makeSystemOpts("initButtonState", [MouseButton], sysOpts):
    all:
      item.mouseButton.clicked = false
      item.mouseButton.mouseOver = false

  makeSystemOpts("drawMouse", [DrawMouse, MouseMoved], sysOpts):
    all:
      if not item.drawMouse.charEnt.alive:
        item.drawMouse.charEnt = newEntityWith(RenderChar(character: 'X', colour: fgRed, backgroundColour: bgYellow))
        item.drawMouse.charRef = item.drawMouse.charEnt.fetchComponent RenderChar
      let
        pos = item.mouseMoved.position
        charPos = normaliseCharCoords(min(pos.x.int, sysRenderChar.width - 1), min(pos.y.int, sysRenderChar.height - 1))

      item.drawMouse.charRef.x = charPos.x
      item.drawMouse.charRef.y = charPos.y

  makeSystemOpts("mouseOverChar", [MouseMoved], sysOpts):
    all:
      # Checks mouse position against the entity in RenderChar.states.
      let
        pos = item.mouseMoved.position
        charIdx = charPosIndex(pos.x.int, pos.y.int)
      if charIdx.validCharIdx:
        let charEnt = sysRenderChar.states[charIdx].entity
        if charEnt.alive:
          let buttonChar = charEnt.fetchComponent ButtonChar
          if buttonChar.valid:
            # Signal button entity.
            buttonChar.button.mouseOver = true
            buttonChar.buttonEnt.addOrUpdate MouseButtonMouseOver()

  makeSystemOpts("clickedButton", [MouseButton, MouseButtonPress], sysOpts):
    all:
      # React to a button being clicked on.
      template mb: untyped = item.mouseButton
      if mb.mouseOver:
        
        mb.clicked = true
        if mb.toggle:
          mb.forceFocus = not mb.forceFocus
        if mb.handler != nil:
          mb.access.handler(item.entity, mb)
      item.entity.removeComponent MouseButtonPress

  makeSystemOpts("drawButtons", [MouseButton], sysOpts):
    start:
      let
        cw = sysRenderChar.charWidth
        ch = sysRenderChar.charHeight
    all:
      # Updates MouseButton.characters according to the button's state.
      template chars: untyped = item.mouseButton.characters
      template mb: untyped = item.mouseButton
      let
        size = mb.size
        expectedLen = size.x * size.y
        (background, border) =
          if mb.mouseOver or mb.forceFocus:
            (mb.background.focused, mb.border.focused)
          else:
            (mb.background.unFocused, mb.border.unFocused)

      if expectedLen < chars.len:
        for i in expectedLen ..< chars.len: chars[i].entity.delete
        chars.setLen expectedLen
      
      elif expectedLen > chars.len:
        let prevLen = chars.len
        chars.setLen expectedLen
        for i in prevLen ..< expectedLen:
          if not chars[i].entity.alive:
            chars[i].entity = newEntityWith(
              RenderChar(character: background.character, backgroundColour: background.colour),
              ButtonChar(button: mb, buttonEnt: item.entity),
              MouseMoving())
            chars[i].rc = chars[i].entity.fetchComponent RenderChar
            chars[i].bc = chars[i].entity.fetchComponent ButtonChar

      let
        midY = size.y div 2
        textStart = 
          case mb.textAlign
          of btaLeft:
            1
          of btaCentre:
            max(1, (size.x div 2) - mb.text.len div 2)
      
      # Update all characters for this button according to the button's state.
      # TODO: Dirty flag to avoid this when not necessary (can use runEvery in meantime)
      var textIdx: int
      let leftCorner = (x: mb.x - size.x.float * cw, y: mb.y - size.y.float * ch)
      for y in 0 ..< size.y:
        for x in 0 ..< size.x:
          let character = chars[(size.x * y) + x]
                    
          character.rc.x = mb.x + leftCorner.x + x.float * cw
          character.rc.y = mb.y + leftCorner.y + y.float * ch
          character.rc.backgroundColour = background.colour
          
          if mb.border.visible and (x == 0 or x == size.x - 1 or y == 0 or y == size.y - 1):
            # Border
            character.rc.character = border.character
            character.rc.backgroundColour = border.colour
            character.bc.charType = bctBorder
          elif x > 0 and y == midY and x >= textStart and x < size.x - 1 and textIdx < mb.text.len:
            # Button's text.
            character.rc.character = mb.text[textIdx]
            textIdx += 1
            character.bc.charType = bctText
          else:
            character.rc.character = background.character
            character.bc.charType = bctBackground

when isMainModule:

  #[
    In this demo we show the mouse button in action, but also
    how it might be extended. We create an AnimateChar component
    that we would like to animate just part of the button; background,
    border or text.

    To do this, we use a setup component that we add to buttons we want
    to animate, which triggers a system to apply the animate component
    to a MouseButton's characters before remove the setup component.

    This allows us to `hook` a button's creation and apply our own components
    to it's character entities/
  ]#
  
  import times

  const
    maxEnts = 20_000
    entOpts = ECSEntityOptions(maxEntities: maxEnts)
    compOpts = ECSCompOptions(maxComponents: maxEnts)
    sysOpts = ECSSysOptions(maxEntities: maxEnts)

  var terminate: bool

  defineRenderChar(compOpts, sysOpts)
  defineConsoleEvents(compOpts, sysOpts)
  defineMouseButtons(compOpts, sysOpts)

  registerComponents(compOpts):
    type
      AnimateChar = object
        charType: ButtonCharType
        chars: seq[char]
        frameIndex: int
        duration: float
        lastUpdate: float
      ApplyAnimateChar = object
        animation: AnimateChar

  makeSystem("quit", [KeyDown]):
    all:
      if 27 in item.keyDown.codes:
        terminate = true

  makeSystem("resize", [WindowEvent]):
    all:
      let pos = item.windowEvent.size
      if pos.x.int > 0 and pos.y.int > 0:
        sysRenderChar.setDimensions pos.x, pos.y
        sysRenderString.setDimensions pos.x, pos.y
      item.entity.removeComponent WindowEvent

  makeSystemOpts("animateButtons", [ApplyAnimateChar, MouseButton], sysOpts):
    all:
      # We need a way to apply AnimateChar to MouseButton automatically but
      # without constantly doing it. This system performs the setup from a button
      # then removes it's activating component.
      if item.mouseButton.characters.len > 0:
        # Monitor until the button has been set up.
        for b in item.mouseButton.characters:
          if item.applyAnimateChar.animation.charType == b.bc.charType:
            b.entity.addComponent item.applyAnimateChar.animation
        item.entity.removeComponent ApplyAnimateChar

  # We want the animate system to run after MouseButton system has updated it's RenderChars,
  # but before they're actually rendered.
  makeSystemOpts("animate", [AnimateChar, ButtonChar, RenderChar], sysOpts):
    start:
      let curTime = epochTime()
    all:
      # Change button characters over time.
      item.renderChar.character = item.animateChar.chars[item.animateChar.frameIndex]
      if curTime - item.animateChar.lastUpdate > item.animateChar.duration:
        item.animateChar.lastUpdate = curTime
        item.animateChar.frameIndex = (item.animateChar.frameIndex + 1) mod item.animateChar.chars.len
  
  makeEcs(entOpts)
  
  ##### ECS defined #####

  addRenderCharSystems()
  addConsoleEventSystems()

  commitSystems("run")
  
  ##### Systems built #####

  let mouseCursor = newEntityWith(KeyChange(), MouseMoving(), DrawMouse(), WindowChange())
  
  proc updateButton(entity: EntityRef, button: MouseButtonInstance) =
    if button.forceFocus:
      button.text = "On"
      
    else:
      button.text = "Off"

  let
    mb = MouseButton(
      text: "Click me",
      toggle: true,
      background: (
        focused: ButtonBackground(character: '.', colour: bgRed),
        unFocused: ButtonBackground(character: '.', colour: bgBlue)),
      border: (
        visible: true,
        focused: ButtonBackground(character: '*', colour: bgYellow),
        unFocused: ButtonBackground(character: '/', colour: bgBlue)),
      size: (10, 5), x: 0.0, y: 0.0,
      handler: updateButton
      )
    animation = AnimateChar(duration: 1.0, charType: bctBackground, chars: @['a', 'b', 'c'])
  var buttonTemplate: ComponentList
  
  buttonTemplate.add ApplyAnimateChar(animation: animation)
  buttonTemplate.add ConsoleInput()
  buttonTemplate.add mb

  
  from math import cos, sin, TAU
  
  # A circle of buttons from the above template.
  let
    buttons = 6
    angleInc = TAU / buttons.float
  var angle: float
  for i in 0..<buttons:
    let
      radius = 0.25
      x = radius * cos angle
      y = radius * sin angle
      # Create the button.
      button = buttonTemplate.construct
      b = button.fetchComponent MouseButton
    b.x = x
    b.y = y
    angle += angleInc

  eraseScreen()
  setCursorPos 0, 0
  while not terminate:
    run()

