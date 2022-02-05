import polymorph, polymers, glbits/modelrenderer, opengl, sdl2, random, math

## Inspired by the particle system described here:
## https://www.youtube.com/watch?v=makaJpLvbow
## More info: https://www.nature.com/articles/srep37969
##
## Press space to set a random turn factor for all particles,
## press R to randomise positions.
##
## **Recommended to run with -d:danger.**
## 
## To pass custom values on the command line:
## `fixedturn=X`: set the fixed turn amount in radians for all particles.
## `turn=X`: set the turn amount in radians for all particles.
## `radius=X`: set the radius each particle considers.
## `randturn=X`: varies the turn amount +/- per particle.
## `randradius=X`: varies the radius +/- per particle.

# Some example parameters:
#
# Original: turn=0.296706 (17 degrees)
#
# Multi-walled cells: turn=0.135
# Giant cells: turn=-0.0381 speed=0.045
# Compartmentalised cells: turn=-0.09899 speed=0.0015
# Healing gel: turn=0.06883678027639761
# Pulsing jelly with replicating raisins: turn=-0.2445473010985458
# More raisins, touch to create: turn=-0.2530594483921344

import strutils, os, strformat

randomize()

# --------------------
# Command line options
# --------------------

type
  Commands = enum
    cmdFixedTurn = "fixedturn",
    cmdTurn = "turn",
    cmdRadius = "radius",
    cmdTVariance = "randturn",
    cmdRVariance = "randradius",
    cmdSpeed = "speed"

var params: array[Commands, tuple[given: bool, value: float]]
let numParams = paramCount()

if numParams >= 1:
  for p in 1..min(numParams, params.len):
    let
      param = paramStr(p).toLowerAscii
      eq = param.find('=')
    if eq > 0:
      let
        command = param[0 ..< eq]
        value = param[eq + 1 .. ^1]
      if value.len == 0:
        quit "Commands must include a value: \"" & param & "\""
      case command
      of $cmdFixedTurn:
        params[cmdFixedTurn] = (true, parseFloat(value))
      of $cmdTurn:
        params[cmdTurn] = (true, parseFloat(value))
      of $cmdRadius:
        params[cmdRadius] = (true, parseFloat(value))
      of $cmdTVariance:
        params[cmdTVariance] = (true, parseFloat(value))
      of $cmdRVariance:
        params[cmdRVariance] = (true, parseFloat(value))
      of $cmdSpeed:
        params[cmdSpeed] = (true, parseFloat(value))
      else:
        quit "Unknown command: \"" & command & "\" in parameter \"" & param & "\""

# The default values mimic the original PPS simulation.
let
  turnAmountVariance = 60.0.degToRad  # Range +/- for randomisation.

  fixedTurn =
    if params[cmdFixedTurn].given: params[cmdFixedTurn].value
    else: 180.0.degToRad
  turnAmount =
    if params[cmdTurn].given: params[cmdTurn].value
    else: rand -turnAmountVariance .. turnAmountVariance
  clusterSize =
    if params[cmdRadius].given: params[cmdRadius].value
    else: 0.035
  turnVariance =
    if params[cmdTVariance].given: params[cmdTVariance].value
    else: 0.0
  clusterVariance = 
    if params[cmdRVariance].given: params[cmdRVariance].value
    else: 0.00
  speed =
    if params[cmdSpeed].given: params[cmdSpeed].value
    else: 0.0047

when defined(debug): echo "Run with -d:danger for a faster framerate."
echo &"FixedTurn {fixedTurn} ({fixedTurn.radToDeg}°) Turn: {turnAmount} ({turnAmount.radToDeg}°), Turn variance: {turnVariance} Speed: {speed}"
echo &"Cluster size: {clusterSize}, Cluster variance: {clusterVariance}"

# ----------
# Define ECS
# ----------

const
  maxEnts = 15000
  maxColDensity = maxEnts * 0.003

  compOpts = fixedSizeComponents(maxEnts)
  sysOpts = fixedSizeSystem(maxEnts)
  entOpts = fixedSizeEntities(maxEnts)

echo &"Particles: {maxEnts}"

defineOpenGlRenders(compOpts, sysOpts)
defineGridMap(0.03, Position, compOpts, sysOpts)

registerComponents(compOpts):
  type
    Velocity = object
      x, y: float32
      speed: float32
    Cluster = object
      radius: float32
      turnAmount: float32
    Rotate = object
      angle: float32
      rotateSpeed: float32

makeSystemOpts("perturb", [Position], sysOpts):
  # Moves particles away from sys.position within sys.radius by
  # sys.force.
  fields:
    position: Position
    radius = 0.12
    force = 0.01

  init:
    sys.paused = true
  
  let
    forceRange =
      if sys.force >= 0: sys.force * 0.1 .. sys.force
      else: sys.force .. sys.force * 0.1

  for entPos in queryGridPrecise(sys.position.x, sys.position.y, sys.radius):
    let
      diffX = entPos.position.x - sys.position.x
      diffY = entPos.position.y - sys.position.y
      angle = arcTan2(diffY, diffX)
      f = rand forceRange
      dir = vec2(cos(angle) * f, sin(angle) * f)
    entPos.position.x += dir.x
    entPos.position.y += dir.y

makeSystemOpts("rotateTowards", [Position, Rotate, Cluster, GridMap, Model], sysOpts):
  all:
    # Alter rotation based on neighbours.

    var
      lCount, rCount: int
    let
      curAngle = item.rotate.angle
      px = item.position.x
      py = item.position.y
    
    for entPos in queryGridPrecise(item.position.x, item.position.y, item.cluster.radius):
      if entPos.entity != entity:
        let
          dx = entPos.position.x - px
          dy = entPos.position.y - py
          angleToPos = arcTan2(dy, dx) mod TAU
          angleDelta = angleDiff(angleToPos, curAngle)

        if angleDelta < 0:
          lCount += 1
        else:
          rCount += 1

    let
      count = lCount + rCount
      angleDelta = item.rotate.rotateSpeed + item.cluster.turnAmount * count.float * sgn(rCount - lCount).float
    item.rotate.angle = (item.rotate.angle + angleDelta) mod TAU

    item.model.col = mix(
      vec4(0.0, 0.0, 1.0, 1.0), vec4(1.0, 0.0, 0.0, 1.0),
      min(1.0, count.float / maxColDensity))

makeSystemOpts("calcVelocity", [Velocity, Rotate], sysOpts):
  all:
    let
      rAngle = item.rotate.angle
      vSpeed = item.velocity.speed
    item.velocity.x = vSpeed * cos rAngle
    item.velocity.y = vSpeed * sin rAngle

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  all:
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y

template wrap(variable: untyped) =
  if item.position.variable < -1.0:
    item.position.variable = 0.99
  elif item.position.variable > 1.0:
    item.position.variable = -0.99

makeSystemOpts("wrapBorders", [Position], sysOpts):
  all:
    wrap(x)
    wrap(y)

# Fire once systems

makeSystemOpts("setTurnAmount", [Cluster], sysOpts):
  # Changes Cluster then deactivates.
  fields: turnAmount: float
  init:
    sys.paused = true

  all:
    item.cluster.turnAmount = sys.turnAmount + rand -turnVariance .. turnVariance
  
  sys.paused = true

makeSystemOpts("randomisePositions", [Position], sysOpts):
  # Changes Position then deactivates.
  init:
    sys.paused = true

  all:
    item.position.x = rand -1.0 .. 1.0
    item.position.y = rand -1.0 .. 1.0
  
  sys.paused = true

# ----
# Seal
# ----

makeEcs(entOpts)
commitSystems("run")

# Create window and OpenGL context.
discard sdl2.init(INIT_EVERYTHING)

var
  screenWidth: cint = 1024 #800 #640
  screenHeight: cint = 768 #600 #480
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
  dark = 0.0001
  circleModel = shaderProg.makeCircleModel(6, vec4(1.0, 1.0, 1.0, 1.0), vec4(dark, dark, dark, 0.4))
  maxSquares = maxEnts

circleModel.setMaxInstanceCount(maxSquares)

# Create some entities with our models.
for i in 0 ..< maxEnts:
  let
    scale = 0.007

  discard newEntityWith(
    Model(modelId: circleModel, scale: vec3(scale), angle: rand(TAU), col: vec4(0.0, 0.0, 1.0, 1.0)),
    Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0),
    Velocity(speed: speed),
    Cluster(
      radius: max(0.001, clusterSize + rand(-clusterVariance .. clusterVariance)),
      turnAmount: turnAmount + rand(-turnVariance .. turnVariance)),
    Rotate(angle: rand TAU, rotateSpeed: fixedTurn),
    GridMap()
  )

const showFps = defined(showFps)

when showFps:
  import times

type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
proc pressed(keyStates: KeyCodes, sc: Scancode): bool = result = keyStates[sc.int] > 0'u8

import algorithm

proc main =
  echo "Keys: R = Randomise positions, Space = Randomise turn amount."

  when showFps:
    var
      t1 = cpuTime()
      fc: int

  var
    keyStates: KeyCodes = getKeyboardState()
    mousePos: array[2, GLfloat]

  # Render loop.
  while running:
    while pollEvent(evt):
      if evt.kind == QuitEvent:
        running = false
        break
      
      elif evt.kind == WindowEvent:
        var windowEvent = cast[WindowEventPtr](addr(evt))
        if windowEvent.event == WindowEvent_Resized:
          screenWidth = windowEvent.data1
          screenHeight = windowEvent.data2
          glViewport(0, 0, screenWidth, screenHeight)
      
      elif evt.kind == MouseMotion:
        let
          mm = evMouseMotion(evt)
          normX = mm.x.float / screenWidth.float
          normY = 1.0 - (mm.y.float / screenHeight.float)
        mousePos[0] = (normX * 2.0) - 1.0
        mousePos[1] = (normY * 2.0) - 1.0

        # Update system with the new mouse position
        sysPerturb.position.x = mousePos[0]
        sysPerturb.position.y = mousePos[1]
      
      elif evt.kind == MouseButtonDown:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          sysPerturb.paused = false
        elif mb.button == BUTTON_RIGHT:
          sysPerturb.force = -abs(sysPerturb.force)
          sysPerturb.paused = false

      elif evt.kind == MouseButtonUp:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          sysPerturb.paused = true
        elif mb.button == BUTTON_RIGHT:
          sysPerturb.force = abs(sysPerturb.force)
          sysPerturb.paused = true

      elif keyStates.pressed(SDL_SCANCODE_SPACE):
        # Reformat particles to a new turnAround value.
        let ta = rand -turnAmountVariance .. turnAmountVariance
        sysSetTurnAmount.turnAmount = ta
        sysSetTurnAmount.paused = false
        echo &"Set turn amount to {ta} ({ta.radToDeg:>4.4f}°), variance {turnVariance}"

      if keyStates.pressed(SDL_SCANCODE_R):
        # Randomise positions of all particles.
        sysRandomisePositions.paused = false

    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    run()
    renderModels()

    when showFps:
      fc += 1
      let t2 = cpuTime()
      if t2 - t1 > 1.0:
        echo &"FPS: {fc}"
        t1 = cpuTime()
        fc = 0

    window.glSwapWindow()

main()
