## Provides components for reading and responding to console events from the keyboard and mouse, and when windows size changes.


import polymorph

template defineConsoleEvents*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions): untyped {.dirty.} =
  import tables

  from winlean import DWORD, WINBOOL, Handle, getStdHandle, STD_INPUT_HANDLE
  
  type
    ConsoleCoord* = tuple[x, y: uint16]
    
    MouseEvent* = object
      mousePosition*: ConsoleCoord
      buttonState*: DWORD
      controlState*: DWORD
      eventFlags*: DWORD

    KeyEvent* = object
      keyDown*: WINBOOL
      repeatCount*: int16
      virtualKeyCode*: int16
      virtualScanCode*: int16
      uChar*: int16
      controlKeyState*: DWORD

    ConsoleWindowEvent = object
      size*: ConsoleCoord

    # Mirror of struct for windows to fill.
    InputEventData {.union.} = object
      keyEvent: KeyEvent
      mouseEvent: MouseEvent
      windowEvent: ConsoleWindowEvent

    EventType* {.size: sizeOf(DWORD).} = enum etKey = 0x1, etMouse = 0x2, etWindow = 0x4
    
    InputEvent* = object
      eventType*: EventType
      data*: InputEventData
    
  registerComponents(compOpts):
    type

      #----------------------------------------------------------------------
      # Add the following components to entities to receive event components.
      #----------------------------------------------------------------------

      ## Tag an entity to receive all console input components when they occur.
      ConsoleInput* = object

      ## Tag an entity to receive KeyEvents, KeyDown and KeyUp.
      KeyInput* = object

      ## Tag an entity to receive KeyDown and KeyUp.
      KeyChange* = object

      ## Tag an entity to receive MouseEvents.
      MouseInput* = object

      ## Tag an entity to receive MouseMoved.
      MouseMoving* = object

      ## Tag an entity to receive MouseButtonPress
      MouseButtons* = object

      ## Tag an entity to receive changes to the console window size.
      WindowChange* = object
      
      #----------------------------------------------------------------
      # These components are added to entities when their events occur.
      # Access them by using them in systems or add them manually to
      # trigger events.
      #----------------------------------------------------------------

      ## All key events that occurred.
      KeyEvents* = object
        events*: seq[KeyEvent]
      
      ## Just the key down key events.
      KeyDown* = object
        # Contains keys as characters, virtual scan codes, and virtual key codes.
        chars*, codes*, keys*: seq[int]
      
      ## Just the key up key events.
      KeyUp* = object
        # Contains keys as characters, virtual scan codes, and virtual key codes.
        chars*, codes*, keys*: seq[int]
      
      ## All mouse events.
      MouseEvents* = object
        events*: seq[MouseEvent]
      
      ## The mouse has moved.
      MouseMoved* = object
        lastPosition*: ConsoleCoord
        position*: ConsoleCoord
      
      ## A mouse button as been pressed.
      MouseButtonPress* = object
        button*: int
      
      WindowEvent* = object
        size*: ConsoleCoord


  proc consumeKey*(keyComp: KeyDownInstance | KeyUpInstance, i: int): bool =
    ## Remove a key, if no keys left, returns true, indicating the component can be removed.
    ## Otherwise returns false.
    keyComp.codes.del i
    keyComp.chars.del i
    keyComp.access.keys.del i
    if keyComp.codes.len == 0:
      true
    else:
      false

  template processKeys*(keyComponent: KeyDownInstance | KeyUpInstance, actions: untyped): untyped =
    ## Iterate keys allowing for length changes by consume.
    var i = keyComponent.codes.high
    while i >= 0:
      let
        code {.inject.} = keyComponent.codes[i]
        keyIndex {.inject.} = i
      actions
      i.dec

  defineSystem("consoleEvents", [ConsoleInput], sysOpts):
    stdInHandle: Handle
    lastConsoleState: DWORD
    kEvents: KeyEvents
    mEvents: MouseEvents
    keyUp: KeyUp
    keyDown: KeyDown
    windowEvent: tuple[has: bool, event: WindowEvent]
    mouseMoved: tuple[has: bool, event: MouseMoved]
    mouseClicked: tuple[has: bool, event: MouseButtonPress]
  
  defineSystem("sendKeyInput", [KeyInput], sysOpts)

  defineSystem("sendKeyChange", [KeyChange], sysOpts)

  defineSystem("sendMouseInput", [MouseEvents], sysOpts)

  defineSystem("sendMouseMove", [MouseMoving], sysOpts)
  
  defineSystem("sendMouseClicked", [MouseButtons], sysOpts)

  defineSystem("sendWindowEvents", [WindowChange], sysOpts)


  onEcsBuilt:

    proc getNumberOfConsoleInputEvents*(hConsoleInput: Handle,
        lpNumberOfEvents: ptr int): WINBOOL{.
        stdcall, dynlib: "kernel32", importc: "GetNumberOfConsoleInputEvents".}
    proc peekConsoleInput*(hConsoleInput: Handle,
        lpBuffer: ptr InputEvent, nLength: DWORD, lpNumberOfEventsRead: ptr int): WINBOOL{.
        stdcall, dynlib: "kernel32", importc: "PeekConsoleInputA".}
    proc flushConsoleInputBuffer*(hConsoleInput: Handle): WINBOOL{.
        stdcall, dynlib: "kernel32", importc: "FlushConsoleInputBuffer".}  
    proc getConsoleMode(hConsoleHandle: Handle, dwMode: ptr DWORD): WINBOOL{.
        stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}
    proc setConsoleMode(hConsoleHandle: Handle, dwMode: DWORD): WINBOOL{.
        stdcall, dynlib: "kernel32", importc: "SetConsoleMode".}
    
    proc restoreConsoleMode*(sys: ConsoleEventsSystem) =
      doAssert(setConsoleMode(sys.stdInHandle, sys.lastConsoleState) != 0)
    
    template restoreConsoleMode* =
      sysConsoleEvents.restoreConsoleMode

    # This system fetches all console events and stores them for later systems to distribute.
    makeSystemBody("consoleEvents"):
      init:
        sys.stdInHandle = getStdHandle(STD_INPUT_HANDLE)
        doAssert(getConsoleMode(sys.stdInHandle, sys.lastConsoleState.addr) != 0) 

        const
          ENABLE_WINDOW_INPUT   = 0x0008
          ENABLE_MOUSE_INPUT    = 0x0010
          ENABLE_EXTENDED_FLAGS = 0x0080

        # Disable quick-edit mode in Windows 10 otherwise no mouse events.
        # Note: this also means the control-c signal has to be handled manually.
        var mode: DWORD = ENABLE_EXTENDED_FLAGS
        doAssert(setConsoleMode(sys.stdInHandle, mode) != 0) 

        # Enable window and mouse input events.
        mode = ENABLE_WINDOW_INPUT or ENABLE_MOUSE_INPUT 
        doAssert(setConsoleMode(sys.stdInHandle, mode) != 0) 

      sys.keyUp.chars.setLen 0
      sys.keyUp.codes.setLen 0
      sys.keyUp.keys.setLen 0
      sys.keyDown.chars.setLen 0
      sys.keyDown.codes.setLen 0
      sys.keyDown.keys.setLen 0
      sys.kEvents.events.setLen 0
      sys.mEvents.events.setLen 0
      sys.windowEvent.has = false
      sys.mouseMoved.has = false
      sys.mouseClicked.has = false
      
      var
        numRead: int
        events = getNumberOfConsoleInputEvents(sys.stdInHandle, numRead.addr)
        inputEvents = newSeq[InputEvent](events)
        curMousePos: ConsoleCoord

      if events > 0:
        doAssert(peekConsoleInput(sys.stdInHandle, inputEvents[0].addr, events, numRead.addr) != 0)

        if numRead > 0:
          for i, event in inputEvents:
            case event.eventType
            of etKey:
              let newEvent = event.data.keyEvent

              if newEvent.keyDown != 0:
                sys.keyDown.chars.add newEvent.uChar
                sys.keyDown.codes.add newEvent.virtualScanCode
                sys.keyDown.keys.add newEvent.virtualKeyCode
              else:
                sys.keyUp.chars.add newEvent.uChar
                sys.keyUp.codes.add newEvent.virtualScanCode
                sys.keyUp.keys.add newEvent.virtualKeyCode
              sys.kEvents.events.add newEvent

            of etMouse:
              let mouseEvent = event.data.mouseEvent
              curMousePos = mouseEvent.mousePosition

              sys.mEvents.events.add mouseEvent
              if mouseEvent.buttonState != 0:
                sys.mouseClicked.has = true
                sys.mouseClicked.event.button = mouseEvent.buttonState

              if mouseEvent.mousePosition != sys.mouseMoved.event.position:
                sys.mouseMoved.has = true

            of etWindow:
              let winEvent = event.data.windowEvent
              sys.windowEvent = (true, WindowEvent(size: winEvent.size))

          # Finished with these events.
          doAssert(sys.stdInHandle.flushConsoleInputBuffer != 0)
      
        # To avoid lots of branching within an `all:` loop we use our
        # separate loops to deposit the events to subscribers of all
        # events with ConsoleInput.
        if sys.kEvents.events.len > 0:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.kEvents
        if sys.mEvents.events.len > 0:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.mEvents
        if sys.keyDown.codes.len > 0:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.keyDown
        if sys.keyUp.codes.len > 0:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.keyUp
        if sys.windowEvent.has:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.windowEvent.event
        if sys.mouseMoved.has:
          sys.mouseMoved.event.lastPosition = sys.mouseMoved.event.position
          sys.mouseMoved.event.position = curMousePos
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.mouseMoved.event
        if sys.mouseClicked.has:
          for i in 0 .. sys.high:
            sys.groups[i].entity.addOrUpdate sys.mouseClicked.event

    makeSystemBody("sendKeyInput"):
      start:
        sys.paused = sysConsoleEvents.kEvents.events.len == 0
      all:
        item.entity.addOrUpdate sysConsoleEvents.kEvents

    makeSystemBody("sendKeyChange"):
      if sysConsoleEvents.keyUp.codes.len > 0:
        for i in 0 .. sys.high:
          sys.groups[i].entity.addOrUpdate sysConsoleEvents.keyUp
      if sysConsoleEvents.keyDown.codes.len > 0:
        for i in 0 .. sys.high:
          sys.groups[i].entity.addOrUpdate sysConsoleEvents.keyDown

    makeSystemBody("sendMouseInput"):
      start:
        sys.paused = sysConsoleEvents.mEvents.events.len == 0
      all:
        item.entity.addOrUpdate sysConsoleEvents.mEvents

    makeSystemBody("sendMouseMove"):
      start:
        sys.paused = not sysConsoleEvents.mouseMoved.has
      all:
        item.entity.addOrUpdate sysConsoleEvents.mouseMoved.event

    makeSystemBody("sendMouseClicked"):
      start:
        sys.paused = not sysConsoleEvents.mouseClicked.has
      all:
        item.entity.addOrUpdate sysConsoleEvents.mouseClicked.event

    makeSystemBody("sendWindowEvents"):
      start:
        sys.paused = not sysConsoleEvents.windowEvent.has
      all:
        item.entity.addOrUpdate sysConsoleEvents.windowEvent.event


when isMainModule:

  # Display console events.
  defineConsoleEvents(defaultComponentOptions, defaultSystemOptions)

  var terminated: bool

  # A system to use the generated key event component.
  makeSystemOpts("OutputKeys", [KeyEvents], defaultSystemOptions):
    all:
      echo item.keyEvents.events.len, " key event(s) received:\n"
      for ev in item.keyEvents.events:
        echo "Virtual key: ", ev.virtualKeyCode, " \"", ev.virtualKeyCode.chr, "\""
        echo "Scan code: ", ev.virtualScanCode
        echo "uChar: ", ev.uChar
        if ev.virtualKeyCode == 27:
          echo "Escape pressed, terminating..."
          terminated = true
      item.entity.removeComponent KeyEvents

  makeSystemOpts("OutputMouse", [MouseEvents], defaultSystemOptions):
    all:
      echo item.mouseEvents.events.len, " mouse event(s) received:\n"
      for ev in item.mouseEvents.events:
        echo "Coord: ", ev.mousePosition
        echo "Buttons: ", ev.buttonState
      item.entity.removeComponent MouseEvents

  makeSystemOpts("OutputWindowChange", [WindowEvent], defaultSystemOptions):
    all:
      echo "New window size: ", item.windowEvent.size
      item.entity.removeComponent WindowEvent

  makeEcs(defaultEntityOptions)

  commitSystems("run")

  discard newEntityWith(ConsoleInput())
  
  echo "Press any key, or escape to quit."
  while not terminated:
    run()
  restoreConsoleMode()
  echo "Finished."
