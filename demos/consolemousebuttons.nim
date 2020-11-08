#[
  In this demo we show the mouse button components, how they might be
  extended, and usage of events.

  We create an AnimateChar component that we would like to animate
  just part of the button; background, border or text.

  To do this, we use a setup component that we add to buttons we want
  to animate, which triggers a system to apply the animate component
  to a MouseButton's characters before removal of the setup component.

  This allows us to `hook` a button's creation and apply our own components
  to the character entities.
]#

import times, polymorph, polymers

const
  entOpts = dynamicSizeEntities()
  compOpts = dynamicSizeComponents()
  sysOpts = dynamicSizeSystem()

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
    # Respond to escape.
    if 1 in item.keyDown.codes:
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

##### ECS is now defined #####

addRenderCharSystems()
addConsoleEventSystems()

commitSystems("run")

##### Systems are now built #####

let mouseCursor {.used.} = newEntityWith(KeyChange(), MouseMoving(), DrawMouse(), WindowChange())

proc updateButton(entity: EntityRef, button: MouseButtonInstance) =
  if button.forceFocus:
    button.text = "On"
  else:
    button.text = "Off"

let
  animation = AnimateChar(duration: 1.0, charType: bctBackground, chars: @['a', 'b', 'c'])

# Build an entity template for a button.
var buttonTemplate: ComponentList
buttonTemplate.add ConsoleInput() # This subscribes the entity to all console input events.
buttonTemplate.add ApplyAnimateChar(animation: animation)
buttonTemplate.add MouseButton(
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

from math import cos, sin, TAU

# A circle of buttons from the above template.
let
  buttons = 6
  angleInc = TAU / buttons.float
var angle: float
for i in 0 ..< buttons:
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
discard newEntity()

eraseScreen()
setCursorPos 0, 0

while not terminate:
  run()