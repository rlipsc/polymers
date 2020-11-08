import polymorph

template defineMouseButtons*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  import terminal

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
      # Finds the active entity in RenderChar.states matching the mouse pos.
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
      # Extend MouseButtonPress to invoke a callback when over the button.
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

