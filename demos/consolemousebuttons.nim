## In this demo we show the mouse button components, how they might be
## extended, and usage of events.
##
## We create an AnimateChar component that we would like to animate
## just part of the button; background, border or text.
##
## To do this, we use a setup component that we add to buttons we want
## to animate, which triggers a system to apply the animate component
## to a MouseButton's characters before removal of the setup component.
##
## This allows us to `hook` a button's creation and apply our own components
## to the character entities.


import times, polymorph, polymers

const
  entOpts = dynamicSizeEntities()
  compOpts = dynamicSizeComponents()
  sysOpts = dynamicSizeSystem()

var terminate: bool

defineRenderChar(compOpts)
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

defineRenderCharUpdate(sysOpts)

makeSystem("quit", [KeyDown]):
  all:
    # Respond to escape.
    if 1 in item.keyDown.codes:
      terminate = true

makeSystem("resize", [WindowEvent]):
  all:
    let pos = item.windowEvent.size
    if pos.x.int > 0 and pos.y.int > 0:
      sysRenderChar.setDimensions pos.x, pos.y
      sysRenderString.setDimensions pos.x, pos.y
    item.entity.remove WindowEvent

makeSystemOpts("animateButtons", [ApplyAnimateChar, MouseButton], sysOpts):
  all:
    # Apply AnimateChar for all matching entities that make up the button.
    # After completion ApplyAnimateChar is removed.
    for b in item.mouseButton.characters:
      if item.applyAnimateChar.animation.charType == b.bc.charType:
        b.entity.addOrUpdate item.applyAnimateChar.animation
  finish:
    sys.remove ApplyAnimateChar

# We want the animate system to run after MouseButton system has updated its RenderChars,
# but before they're actually rendered.
makeSystemOpts("animate", [AnimateChar, ButtonChar, RenderChar], sysOpts):
  let
    curTime = epochTime()
  all:
    # Change button characters over time.
    item.renderChar.character = item.animateChar.chars[item.animateChar.frameIndex]
    if curTime - item.animateChar.lastUpdate > item.animateChar.duration:
      item.animateChar.lastUpdate = curTime
      item.animateChar.frameIndex = (item.animateChar.frameIndex + 1) mod item.animateChar.chars.len

defineRenderCharOutput(sysOpts)

makeEcs(entOpts)

# ------------------
# ECS is now defined
# ------------------

# Add our systems defined above and create a run proc.
commitSystems("run")

# -------------------------
# Systems are now available
# -------------------------

let
  mouseCursor {.used.} = newEntityWith(KeyChange(), MouseMoving(), DrawMouse(), WindowChange())

proc updateButton(entity: EntityRef, button: MouseButtonInstance) =
  # Callback triggered when a character is clicked.
  if button.forceFocus:
    button.text = "On"
  else:
    button.text = "Off"

# Build an entity template for a button.
let
  buttonTemplate = cl(
    ConsoleInput(), # Subscribes the entity to all console input events.
    MouseButton(
      text: "Click me",
      toggle: true,
      styles: ButtonStyles(
        background: (
          focused: ButtonCharStyle(character: '*', colour: bgRed),
          unFocused: ButtonCharStyle(character: '.', colour: bgBlue)),
        borders: [
          (visible: true,
          focused: ButtonCharStyle(character: '=', colour: bgRed),
          unFocused: ButtonCharStyle(character: '-', colour: bgBlue)),
          (visible: true,
          focused: ButtonCharStyle(character: '#', colour: bgYellow),
          unFocused: ButtonCharStyle(character: '|', colour: bgBlue)),
        ],
        corners: [
          (visible: true,
          focused: ButtonCharStyle(character: 'A', colour: bgYellow),
          unFocused: ButtonCharStyle(character: 'a', colour: bgBlue)),
          (visible: true,
          focused: ButtonCharStyle(character: 'B', colour: bgYellow),
          unFocused: ButtonCharStyle(character: 'b', colour: bgBlue)),
          (visible: true,
          focused: ButtonCharStyle(character: 'C', colour: bgYellow),
          unFocused: ButtonCharStyle(character: 'c', colour: bgBlue)),
          (visible: true,
          focused: ButtonCharStyle(character: 'D', colour: bgYellow),
          unFocused: ButtonCharStyle(character: 'd', colour: bgBlue)),
        ],
        text: (
          focused: ButtonCharStyle(colour: bgRed),
          unFocused: ButtonCharStyle(colour: bgBlue),
        )
      ),
      size: (10, 5), x: 0.0, y: 0.0,
      handler: updateButton
    ),
    ApplyAnimateChar( # Applies AnimateChar to entities matching charType in a MouseButton.
      animation: AnimateChar(
        duration: 1.0,
        charType: bctBackground,
        chars: @['.', 'o']
      )
    )
  )

from math import cos, sin, TAU

# A circle of buttons from the above template.
let
  buttons = 6
  angleInc = TAU / buttons.float
  charDims = (w: sysRenderChar.charWidth, h: sysRenderChar.charHeight)
  # Offset buttons to center.
  offset = (x: -5.float * charDims.w, y: -2.float * charDims.h)
var angle: float
for i in 0 ..< buttons:
  let
    radius = 0.6
    x = offset.x + radius * cos angle
    y = offset.y + radius * sin angle
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
