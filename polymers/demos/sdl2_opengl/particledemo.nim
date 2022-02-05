## This is a demo of an ECS that models user interactable particles.
##
## Each foreground particle has two colours, an 'original' and a colour it is mixed
## toward when the mouse is within its radius. These particles gradually mix back towards their
## original colour over time, and each particle has a different mix speed.
## 
## To register when a particle is near the mouse, the CheckRadius component is used.
## Several systems piggy back on the results stored in this component to perform colouring and
## movement. This version uses a bool to indicate the source point (mouse) is inside its radius.
## The same effect can be achieved by adding a separate component when satisfied and write 
## systems to use that, similar to the grabbing mechanism below.
##
## Colour blending requires the data from the ColourBlend component, but is only activated
## when BlendModel is also present. This lets us control whether this work is performed without
## needed to remove the data that governs it.
##
## When particles are given the Grabbed component, the BlendModel component is removed to prevent
## unnecessary work as Grabbed has its own colouring system. There is a performance cost to
## changing state by adding/removing components too, but this is paid once per change rather than
## once per tick.
##
## This demo shows:
##   * Isolated systems focused on single tasks.
##   * Combining multiple behaviours together.
##   * Changing behaviour by adding/removing components.
##   * Adding custom fields to system definitions.
##   * Passing parameters to specific systems by updating system fields.
##   * Manually triggering systems for some effect.
##   * Systems pausing themselves after completion.
##
## Expects SDL2.dll to be in the current directory, available from here: https://www.libsdl.org/download-2.0.php
## Uses sdl2 wrapper, obtained with `nimble install sdl2` or from here: https://github.com/nim-lang/sdl2
## Uses glbits to draw the models, found here: https://github.com/rlipsc/glbits

import polymorph, polymers, glbits/modelrenderer, opengl, sdl2, random
from math import TAU, PI, degToRad, cos, sin, `mod`, sqrt, exp, floor
from times import cpuTime

when defined(debug):
  const
    # Reduce number of particles when debugging.
    maxEnts = 80_000
    particleScale = 0.008
else:
  const
    maxEnts = 400_000
    particleScale = 0.007
const
  compOpts = fixedSizeComponents(maxEnts)
  sysOpts = fixedSizeSystem(maxEnts)
  entOpts = fixedSizeEntities(maxEnts)
  dt = 1.0 / 60.0
defineOpenGlRenders(compOpts, sysOpts)

registerComponents(compOpts):
  type
    Velocity = object
      x, y: float32
    Spin = float
    ColourBlend = object
      mix, mixSpeed, brightening: GLfloat
      original, blendTo, value: GLvectorf4
    BlendModel = object
    AvoidMouse = object
      speed: float
    AttractToMouse = object
      speed: float
    CheckRadius = object
      radius: float32
      vector: GLvectorf2
      inside: bool
      insideDist: float32
    Grabbable = object
    Grabbed = object
      force: float
      startGrab: float

# Basic physics.

template bounce(variable: untyped) =
  if item.position.variable < -1.0:
    item.position.variable = -1.0
    item.velocity.variable *= -1.0
  elif item.position.variable > 1.0:
    item.position.variable = 1.0
    item.velocity.variable *= -1.0

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  all:
    # Simple movement and responding to edges.
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y
    bounce(x)
    bounce(y) 

makeSystemOpts("spin", [Model, Spin], sysOpts):
  all:
    # Continually advance model.angle.
    # Note: `access` changes the spin instance into a value lookup.
    item.model.angle = (item.model.angle + item.spin.access) mod TAU

# Check for entities near the mouse.
defineGridMap(0.02, Position, compOpts, sysOpts)

makeSystemOpts("resetCR", [CheckRadius], sysOpts):
  all: item.checkRadius.inside = false

makeSystemOpts("checkRadius", [Position, CheckRadius], sysOpts):
  fields:
    # Add a field for the mouse position to the system type definition.
    mousePos: GLvectorf2
  all:
    # Calculates vector to mousePos when within checkRadius.radius.
    let
      dx = sys.mousePos[0] - item.position.x
      dy = sys.mousePos[1] - item.position.y
      sqDist = dx * dx + dy * dy
      r = item.checkRadius.radius
      sExtent = r * r

    if sqDist <= sExtent:
      let length = sqDist.sqrt
      item.checkRadius.vector = vec2(dx / length, dy / length)
      item.checkRadius.inside = true
      item.checkRadius.insideDist = length
    else:
      item.checkRadius.inside = false

# Respond to being near the mouse.

template reactToPoint(checkRadius, velocity: untyped, speed: float, sign: untyped): untyped =
  ## Move toward or away from point.
  if checkRadius.inside:
    velocity.x = `sign`(speed) * checkRadius.vector[0]
    velocity.y = `sign`(speed) * checkRadius.vector[1]

makeSystemOpts("attractMouse", [CheckRadius, Velocity, AttractToMouse], sysOpts):
  all: reactToPoint(item.checkRadius, item.velocity, item.attractToMouse.speed, `+`)

makeSystemOpts("avoidMouse", [CheckRadius, Velocity, AvoidMouse], sysOpts):
  all: reactToPoint(item.checkRadius, item.velocity, item.avoidMouse.speed, `-`)

# Colour blends.

makeSystemOpts("colourBlend", [BlendModel, ColourBlend, Model, not Grabbed], sysOpts):
  all:
    # Perform colour calculation.
    template blend: untyped = item.colourBlend
    blend.value = mix(blend.original, blend.blendTo, blend.mix)

makeSystemOpts("colourBlendProgress", [ColourBlend], sysOpts):
  all:
    # Move blend mix towards the original colour over time.
    template blend: untyped = item.colourBlend
    item.colourBlend.mix = clamp(blend.mix - blend.mixSpeed * dt, 0.0, 1.0)

makeSystemOpts("changeBlendInRadius", [CheckRadius, ColourBlend], sysOpts):
  all:
    if item.checkRadius.inside:
      # Move the mix according to distance from mouse, from original to blendTo.
      # To avoid premature dampening, this is performed after "colourBlendProgress".
      let
        normDist = item.checkRadius.insideDist / item.checkRadius.radius
        brightening = item.colourBlend.brightening
        # Linear colour drop off from mouse.
        mixShift = dt * brightening * (1.0 - normDist)
        # Alternative curved colour drop off from mouse.
        #value = 1.0 / (exp(5.0 * (normDist * normDist)))
        #mixShift = dt * brightening * value
      item.colourBlend.mix = clamp(item.colourBlend.mix + mixShift, 0.0, 1.0)

makeSystemOpts("updateModelWithBlend", [BlendModel, ColourBlend, Model], sysOpts):
  all:
    item.model.col = item.colourBlend.value

# Grabbing entities with the mouse button.

makeSystemOpts("grab", [Grabbable, CheckRadius], sysOpts):
  # This system is paused by default and is manually controlled.
  fields:
    grabForce: float
  init:
    sys.paused = true
  all:
    if item.checkRadius.inside:
      entity.addIfMissing Grabbed(force: sys.grabForce, startGrab: cpuTime())

makeSystemOpts("colourGrabbed", [Grabbed, Model, ColourBlend], sysOpts):
  var timeWiggle = cpuTime() * 5.0
  timeWiggle = 0.7 + sin(timeWiggle) * 0.2

  all:
    item.model.col = mix(item.colourBlend.original, item.colourBlend.blendTo, timeWiggle)

makeSystemOpts("gatherGrabbed", [Grabbed, CheckRadius, Position, Velocity], sysOpts):
  # Moves grabbed entities towards mousePos.
  fields:
    mousePos: GLvectorf2
  all:
    let
      force = item.grabbed.force
      dx = sys.mousePos[0] - item.position.x
      dy = sys.mousePos[1] - item.position.y
      sqDist = dx * dx + dy * dy
      length = sqrt(sqDist)
      vector = vec2(dx / length, dy / length)
    
    item.velocity.x = vector[0] * force
    item.velocity.y = vector[1] * force

makeSystemOpts("releaseGrabbed", [Grabbed, Velocity], sysOpts):
  # Fire and forget system to remove the Grabbed tag.
  init:
    sys.paused = true
  all:
    # Replace tag to blend the model.
    entity.addIfMissing BlendModel()
    # Add a bit of randomness.
    const maxJiggle = 0.01
    item.velocity.x += rand -maxJiggle..maxJiggle
    item.velocity.y += rand -maxJiggle..maxJiggle
    # Removing Grabbed makes the current item undefined.
    entity.removeComponent Grabbed
  finish:
    # Deactivate system.
    sys.paused = true

# Seal ECS

makeEcs(entOpts)
commitSystems("run")

# Create window and OpenGL context.
discard sdl2.init(INIT_EVERYTHING)

var
  screenWidth: cint = 1024
  screenHeight: cint = 768
  xOffset: cint = 50
  yOffset: cint = 50

var window = createWindow("SDL/OpenGL Skeleton", xOffset, yOffset, screenWidth, screenHeight, SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
var context {.used.} = window.glCreateContext()

# Initialize OpenGL
loadExtensions()
# Set background color to black and opaque.
glClearColor(0.0, 0.0, 0.0, 1.0)
# Set background depth to farthest.
glClearDepth(1.0)
# Enable alpha blending.
glEnable(GL_BLEND)
glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

var
  evt = sdl2.defaultEvent
  running = true

# Create some models to use.
let
  shaderProg = newModelRenderer()
  dark = 0.001
  attractorModel = shaderProg.makeCircleModel(60, vec4(1.0, 1.0, 1.0, 1.0), vec4(dark, dark, dark, 0.1), roughness = 2.0)
  particleModel = shaderProg.makeCircleModel(6, vec4(1.0, 1.0, 1.0, 1.0), vec4(dark, dark, dark, 0.95))
  maxCircles = maxEnts
  maxSquares = maxEnts

attractorModel.setMaxInstanceCount(maxCircles)
particleModel.setMaxInstanceCount(maxSquares)

# Create some entities to model the particles.

let
  foreground = floor(maxEnts * 0.9).int

for i in 0 ..< maxEnts - foreground:
  
  # Background particle.
  let
    scale = rand 0.007..0.02
    speed = rand 0.001..0.008
    modelCol = vec4(rand 0.01..1.0, rand 0.01..0.5, rand 0.01..1.0, 0.1)

  discard newEntityWith(
    Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0),
    Model(modelId: attractorModel, scale: vec3(scale), angle: rand(TAU), col: modelCol),
    Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
    Spin(rand(-6.0..6.0).degToRad),
    AttractToMouse(speed: speed * 0.3),
    CheckRadius(radius: rand 0.2..0.4),
  )

for i in 0 ..< foreground:
    # Foreground particle.
    let
      speed = rand 0.003..0.008
      reactCol = vec4(rand 0.1..1.0, rand 0.1..1.0, rand 0.1..1.0, 1.0)
      modelCol = vec4(rand 0.1..1.0, 0.0, 0.0, 0.8)
    discard newEntityWith(
      Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0),
      Model(modelId: particleModel, scale: vec3(particleScale), angle: rand(TAU), col: modelCol),
      Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
      AvoidMouse(speed: speed),
      CheckRadius(radius: rand 0.3..0.4),
      ColourBlend(original: modelCol, blendTo: reactCol, mixSpeed: rand 0.1 .. 0.2, brightening: rand 1.5 .. 5.0),
      BlendModel(),
      Grabbable(),
    )
    
var mousePos: GLvectorf2

when defined(showFPS):
  import times
  var
    t1 = cpuTime()
    fc: int


import strutils

proc main =
  echo "Using ", maxEnts, " entities."

  # Render loop.
  type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
  proc pressed(keyStates: KeyCodes, sc: Scancode): bool = result = keyStates[sc.int] > 0'u8
  while running:
    while pollEvent(evt):
      if evt.kind == QuitEvent:
        running = false
        break
      if evt.kind == MouseMotion:
        let
          mm = evMouseMotion(evt)
          normX = mm.x.float / screenWidth.float
          normY = 1.0 - (mm.y.float / screenHeight.float)
        mousePos[0] = (normX * 2.0) - 1.0
        mousePos[1] = (normY * 2.0) - 1.0
        # Update system with the new mouse position
        sysCheckRadius.mousePos = mousePos
        sysGatherGrabbed.mousePos = mousePos

      # Handle grabbing.  
      if evt.kind == MouseButtonDown:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          sysGrab.grabForce = 0.005
          # Active system to start tagging entities as Grabbed within CheckRadius.
          sysGrab.paused = false
      if evt.kind == MouseButtonUp:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          sysGrab.paused = true
          # Active system to remove Grabbed from all entities that have it.
          # Deactivates itself when completed.
          sysReleaseGrabbed.paused = false

      if evt.kind == WindowEvent:
        var windowEvent = cast[WindowEventPtr](addr(evt))
        if windowEvent.event == WindowEvent_Resized:
          screenWidth = windowEvent.data1
          screenHeight = windowEvent.data2
          glViewport(0, 0, screenWidth, screenHeight)

      var keyStates: KeyCodes = getKeyboardState()

      if keyStates.pressed(SDL_SCANCODE_SPACE):
        # Output simple fragmentation info for all systems.
        echo "\nSystem fragmentation:\n"
        forAllSystems:
          let accessDetails = analyseSystem(sys)
          echo accessDetails.summary

      if keyStates.pressed(SDL_SCANCODE_F):
        # Output full fragmentation info for all systems.
        forAllSystems:
          let accessDetails = analyseSystem(sys)
          for c in accessDetails.components:
            if c.fragmentation > 0.2:
              echo accessDetails

    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    run()
    renderModels()

    when defined(showFPS):
      fc += 1

      let t2 = cpuTime()
      if t2 - t1 > 1.0:
        echo "FPS: ", fc
        t1 = cpuTime()
        fc = 0

    window.glSwapWindow()

main()