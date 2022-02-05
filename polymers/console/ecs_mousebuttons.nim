import polymorph

template defineMouseButtons*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  import terminal

  assert declared(RenderChar), "These components require RenderChar to be defined"
  assert declared(MouseMoved), "These components require console events to be defined"

  type
    ButtonCharStyle* = object
      character*: char
      colour*: BackgroundColor
    ButtonTextAlignment* = enum btaCentre, btaLeft
    ButtonCharType* = enum bctBackground, bctBorder, bctCorner, bctText
    ButtonStyles* = object
      background*: tuple[focused, unfocused: ButtonCharStyle]
      borders*: array[2, tuple[visible: bool, focused, unfocused: ButtonCharStyle]]
      corners*: array[4, tuple[visible: bool, focused, unfocused: ButtonCharStyle]]
      text*: tuple[focused, unfocused: ButtonCharStyle]

  registerComponents(compOpts):
    type
      MouseButton* = object
        x*, y*: float
        size*: tuple[x, y: int]
        text*: string
        textAlign*: ButtonTextAlignment
        forceFocus*: bool
        toggle*: bool

        ## Entities used for this button.
        characters*: seq[tuple[entity: EntityRef, rc: RenderCharInstance, bc: ButtonCharInstance]]
        styles*: ButtonStyles
        
        mouseOver*: bool
        clicked*: bool
        
        handler*: proc(entity: EntityRef, button: MouseButtonInstance)

      MouseButtonMouseOver* = object
      MouseButtonClicked* = object
      
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
      for c in curComponent.characters:
        c.entity.delete

  makeSystemOpts("initButtonState", [MouseButton], sysOpts):
    all:
      item.mouseButton.clicked = false
      item.mouseButton.mouseOver = false

  makeSystemOpts("drawMouse", [DrawMouse, MouseMoved], sysOpts):
    all:
      if not item.drawMouse.charEnt.alive:
        item.drawMouse.charEnt = newEntityWith(RenderChar(character: 'X', colour: fgRed, backgroundColour: bgYellow))
        item.drawMouse.charRef = item.drawMouse.charEnt.fetch RenderChar
      let
        pos = item.mouseMoved.position
        charPos = normaliseCharCoords(min(pos.x.int, sysRenderChar.width - 1), min(pos.y.int, sysRenderChar.height - 1))

      item.drawMouse.charRef.x = charPos.x
      item.drawMouse.charRef.y = charPos.y

  makeSystemOpts("removeMouseOver", [MouseButtonMouseOver], sysOpts):
    finish:
      sys.remove MouseButtonMouseOver

  makeSystemOpts("mouseOverChar", [MouseMoved], sysOpts):
    all:
      # Finds the active entity in RenderChar.states matching the mouse pos.
      let
        pos = item.mouseMoved.position
        charIdx = charPosIndex(pos.x.int, pos.y.int)
      if charIdx.validCharIdx:

        let charEnt = sysRenderChar.states[charIdx].entity
        if charEnt.alive:

          let buttonChar = charEnt.fetch ButtonChar
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

      entity.addOrUpdate MouseButtonClicked()

    finish:
      sys.remove MouseButtonPress

  makeSystemOpts("drawButtons", [MouseButton], sysOpts):
    let
      cw = sysRenderChar.charWidth
      ch = sysRenderChar.charHeight
      hcw = cw * 0.5
      hch = ch * 0.5

    all:
      # Updates MouseButton.characters according to the button's state.
      template chars: untyped = item.mouseButton.characters
      template mb: untyped = item.mouseButton
      let
        size = mb.size
        expectedLen = size.x * size.y

      # Handle resizing.
      if expectedLen < chars.len:
        for i in expectedLen ..< chars.len:
          sys.deleteList.add chars[i].entity
        chars.setLen expectedLen

      elif expectedLen > chars.len:
        let prevLen = chars.len
        chars.setLen expectedLen
        for i in prevLen ..< expectedLen:
          if not chars[i].entity.alive:
            chars[i].entity = newEntityWith(
              RenderChar(),
              ButtonChar(button: mb, buttonEnt: item.entity),
              MouseMoving())
            chars[i].rc = chars[i].entity.fetch RenderChar
            chars[i].bc = chars[i].entity.fetch ButtonChar

      # Update all characters for this button according to the button's state.
      type ButtonCharItem = tuple[entity: EntityRef, rc: RenderCharInstance, bc: ButtonCharInstance]

      template applyStyle(bci: ButtonCharItem, xPos, yPos: int, style: ButtonCharStyle, ct: ButtonCharType) =
        bci.rc.x = mb.x + xPos.float * cw + hcw
        bci.rc.y = mb.y + yPos.float * ch + hch
        bci.rc.character = style.character
        bci.rc.backgroundColour = style.colour
        bci.bc.charType = ct

        #echo "p: ", bci.rc.x, ", ", bci.rc.y, " : ", xPos, ", ", yPos

      let extent = (x: size.x - 1, y: size.y - 1)

      if chars.len > 0:

        let
          inFocus = mb.mouseOver or mb.forceFocus

        template pos(charPosition: tuple[x: int, y: int]): int = charPosition.y * size.x + charPosition.x

        if mb.styles.borders[0].visible or mb.styles.borders[1].visible:

          # Apply corners
          let cornerPos = [
            (x: 0, y: 0),
            (x: extent.x, y: 0),
            (x: 0, y: extent.y),
            (x: extent.x, y: extent.y)]

          for i, corner in cornerPos:
            let
              cornerStyle =
                if inFocus: mb.styles.corners[i].focused
                else: mb.styles.corners[i].unfocused

            chars[pos(corner)].applyStyle(corner.x, corner.y, cornerStyle, bctCorner)

          let
            xBorderStyle =
              if inFocus: mb.styles.borders[0].focused
              else: mb.styles.borders[0].unfocused

          # Horizontal borders
          for y in [0, extent.y]:
            for x in 1 .. extent.x - 1:
              let p = y * size.x + x
              chars[p].applyStyle(x, y, xBorderStyle, bctBorder)

          let
            yBorderStyle =
              if inFocus: mb.styles.borders[1].focused
              else: mb.styles.borders[1].unfocused

          # Vertical borders
          for x in [0, extent.x]:
            for y in 1 .. extent.y - 1:
              let p = y * size.x + x
              chars[p].applyStyle(x, y, yBorderStyle, bctBorder)

        template styleRow(yPos: int, xRange: Slice[int], charStyle: ButtonCharStyle, charType: ButtonCharType) =
          for x in xRange:
            let charIdx = size.x * yPos + x
            chars[charIdx].applyStyle(x, yPos, charStyle, bctBackground)
        
        template writeText(yPos: int, xRange: Slice[int], textValue: string): int =
          let
            yRow = size.x * yPos
          var
            textStyle = 
              if inFocus: mb.styles.text.focused
              else: mb.styles.text.unfocused
            textIdx: int

          for x in xRange:
            let charIdx = yRow + x
            textStyle.character = textValue[textIdx]
            chars[charIdx].applyStyle(x, yPos, textStyle, bctText)
            textIdx += 1
            if textIdx > textValue.high: break
          textIdx

        let
          xArea =
            if mb.styles.borders[0].visible:
              (x1: 1, x2: extent.x - 1)
            else:
              (x1: 0, x2: extent.x)
          yArea =
            if mb.styles.borders[1].visible:
              (y1: 1, y2: extent.y - 1)
            else:
              (y1: 0, y2: extent.y)
          midY = size.y div 2
          textStart = 
            case mb.textAlign
            of btaLeft:
              1
            of btaCentre:
              max(1, (size.x div 2) - (mb.text.len div 2))

        let
          backgroundStyle =
            if inFocus: mb.styles.background.focused
            else: mb.styles.background.unfocused

        # Background above text.
        for y in yArea.y1 ..< midY:
          styleRow(y, xArea.x1 .. xArea.x2, backgroundStyle, bctBackground)
        
        # Text.
        styleRow(midY, xArea.x1 ..< textStart, backgroundStyle, bctBackground)
        let textEnd = writeText(midY, textStart .. xArea.x2, mb.text)
        styleRow(midY, textStart + textEnd .. xArea.x2, backgroundStyle, bctBackground)

        # Background below text.
        for y in midY + 1 .. yArea.y2:
          styleRow(y, xArea.x1 .. xArea.x2, backgroundStyle, bctBackground)

when isMainModule:
  import polymers
  defineRenderChar(defaultComponentOptions)
  defineRenderCharSystems(defaultSystemOptions)
  defineConsoleEvents(defaultComponentOptions, defaultSystemOptions)
  defineMouseButtons(defaultComponentOptions, defaultSystemOptions)


