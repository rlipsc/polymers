import polymorph

template defineAsk*(compOpts: EcsCompOptions, sysOpts: EcsSysOptions) {.dirty.} =
  ## Requires renderchars and console events.
  
  when not declared(RenderString) or not declared(KeyDown):
    error "ecs_editstring "

  from strutils import Digits, Letters, delete

  registerComponents(compOpts):
    type
      EditString* = object
        xPos*: int
        validKeys*: set[char]

      InputFinished* = object

  defineSystem("inputString",     [EditString, KeyDown, RenderString], sysOpts)
  defineSystem("updateCursorPos", [EditString, RenderString], sysOpts)
  defineSystem("escape",          [EditString, KeyDown], sysOpts):
    escapePressed: bool

  makeSystem("inputString", [EditString, KeyDown, RenderString]):
    # Turn a RenderString into an edit box.
    all:
      template xPos: untyped = item.editString.xPos
      template curLen: int = item.renderString.text.len

      var removeKeyDown: bool

      for i in countDown(item.keyDown.codes.high, 0):

        let aChar = chr(item.keyDown.chars[i])

        if aChar in item.editString.validKeys:

          if xPos < curLen - 1:
            item.renderString.text.insert($aChar, xPos)
          else:
            item.renderString.text &= aChar

          xPos = min(xPos + 1, curLen)
          removeKeyDown = consumeKey(item.keyDown, i)

        else:

          case item.keyDown.codes[i]
          of 14:
            # Delete
            if xPos > 0 and curLen > 0:
              xPos = xPos - 1
              item.renderString.text.delete(xPos..xPos)
            removeKeyDown = consumeKey(item.keyDown, i)
          of 75:
            # Left
            xPos = max(xPos - 1, 0)
            removeKeyDown = consumeKey(item.keyDown, i)
          of 77:
            # Right
            xPos = min(xPos + 1, curLen)
            removeKeyDown = consumeKey(item.keyDown, i)
          of 28:
            # Return
            entity.addOrUpdate InputFinished()
            removeKeyDown = consumeKey(item.keyDown, i)
          of 71:
            # Home
            xPos = 0
            removeKeyDown = consumeKey(item.keyDown, i)
          of 79:
            # End
            xPos = curLen
            removeKeyDown = consumeKey(item.keyDown, i)
          else:
            discard
      if removeKeyDown:
        entity.remove KeyDown

  makeSystem("updateCursorPos", [EditString, RenderString]):
    all:
      let pos = charPos(item.renderString.x, item.renderString.y)
      setCursorPos pos.x + item.editString.xPos, pos.y

  makeSystem("escape", [EditString, KeyDown]):
    all:
      # Handles exiting an EditString.
      item.keyDown.processKeys:
        if code == 1:
          sys.escapePressed = true
          if consumeKey(item.keyDown, keyIndex):
            entity.remove KeyDown
          break

  onEcsBuilt:

    proc promptInput*(prompt: string, runEcs: proc(), defaultText = "",
        validKeys = Letters + Digits, x = -1.0, y = -1.0): string =
      ## Asynchronously edit text at (x, y) whilst running `runEcs`.
      ## 
      ## `runEcs` should include the systems for console events,
      ## renderChar, and `EditString`.
      ## 
      ## After input has completed through detection of return or
      ## escape, the result is returned to the caller.
      let
        inputXOffset = prompt.len.float * sysRenderChar.charWidth
        prmt = newEntityWith(RenderString(text: prompt, x: x, y: y))
        cursorPos =
          if defaultText.len > 0: defaultText.high
          else: 0
        input = newEntityWith(
          RenderString(
            text: defaultText, x: x + inputXOffset, y: y),
          EditString(xPos: cursorPos, validKeys: validKeys),
          KeyChange())

      var done: bool
      while not done:
        runEcs()
        if input.has InputFinished:
          result = input.fetch(RenderString).text
          done = true
        else: done = sysEscape.escapePressed
      prmt.delete
      input.delete    

when isMainModule:
  import polymers

  const
    cOpts = dynamicSizeComponents()
    sOpts = dynamicSizeSystem()
    eOpts = dynamicSizeEntities()
  defineConsoleEvents(cOpts, sOpts)
  defineRenderChar(cOpts)
  defineAsk(cOpts, sOpts)
  defineRenderCharSystems(sOpts)
  
  makeEcs(eOpts)
  commitSystems("run")

  let userInput = promptInput("What is your name? ", run)
  echo "\nUser said: ", userInput

