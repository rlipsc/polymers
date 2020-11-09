import polymorph, polymers, glbits/modelrenderer, opengl, sdl2, random
from math import TAU, PI, degToRad, radToDeg, cos, sin, arctan2, sqrt

#[
  Inspired by the particle system described here:
    https://www.youtube.com/watch?v=makaJpLvbow
    More info: https://www.nature.com/articles/srep37969
  Press space to set a random turn factor for all particles,
  press R to randomise positions.
  Best run with -d:danger.
]#

randomize()

const maxEnts = 30000
const
  compOpts = fixedSizeComponents(maxEnts)
  sysOpts = fixedSizeSystem(maxEnts)
  entOpts = fixedSizeEntities(maxEnts)
  dt = 1.0 / 60.0

defineOpenGlRenders(compOpts, sysOpts)
defineGridMap(0.02, Position, compOpts, sysOpts)

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

func normalise(vec: array[2, SomeFloat], minLen = 0.01): array[2, float32] =
  let length: float32 = max(minLen, sqrt(vec[0] * vec[0] + vec[1] * vec[1]))
  [vec[0].float32 / length, vec[1].float / length]

makeSystemOpts("rotate", [Velocity, Rotate], sysOpts):
  all:
    let
      rSpeed = item.rotate.rotateSpeed
      rAngle = item.rotate.angle
      vSpeed = item.velocity.speed
    item.velocity.x = vSpeed * cos rAngle
    item.velocity.y = vSpeed * sin rAngle
    item.rotate.angle += rSpeed

makeSystemOpts("rotateTowards", [Position, Velocity, Rotate, Cluster, GridMap, Model], sysOpts):
  all:
    # Sum nearby positions and move towards them.
    var
      pos = [item.position.x, item.position.y]
      count: int
    
    # Build averages of other particles in the projected area.
    for entPos in queryGridPrecise(pos[0], pos[1], item.cluster.radius):
      pos[0] += entPos.position.x
      pos[1] += entPos.position.y
      count += 1

    if count > 0:
      let
        dx = item.position.x - pos[0]
        dy = item.position.y - pos[1]
        angleToAvgPos = arcTan2(dy, dx)
      if angleToAvgPos < item.rotate.angle:
        item.rotate.angle -= item.cluster.turnAmount * count.float32
      else:
        item.rotate.angle += item.cluster.turnAmount * count.float32
      item.model.col = mix(
        vec4(0.0, 0.0, 1.0, 1.0), vec4(1.0, 0.0, 0.0, 1.0),
        min(1.0, count.float / 40.0))

makeSystemOptFields("setTurnAmount", [Cluster], sysOpts) do:
  turnAmount: float
do:
  # Changes Cluster then deactivates.
  init: sys.paused = true
  all: item.cluster.turnAmount = sys.turnAmount
  finish: sys.paused = true

makeSystemOpts("randomisePositions", [Position], sysOpts):
  # Changes Position then deactivates.
  init: sys.paused = true
  all:
    item.position.x = rand -1.0 .. 1.0
    item.position.y = rand -1.0 .. 1.0
  finish: sys.paused = true

makeEcs(entOpts)
addGridmapIterators(Position)
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
  squareModel = shaderProg.makeCircleModel(6, vec4(1.0, 1.0, 1.0, 1.0), vec4(dark, dark, dark, 0.4))
  maxSquares = maxEnts

squareModel.setMaxInstanceCount(maxSquares)

import strutils, os

const showFps = defined(showFps)
let turnAmount =
  if paramCount() > 0:
    # Pass turnAround in command line.
    parseFloat(paramStr(0))
  else:
    rand PI
echo "TurnAround: ", turnAmount, " (", turnAmount.radToDeg, ")"
echo "Particles: ", maxEnts

# Create some entities with our models.
for i in 0 ..< maxEnts:
  let
    # Speed = 0.004, radius = 0.03, turnAmount  = 17 degrees
    # turnAmount = 9.66 gives some great bacteria.
    speed = 0.005
    scale = 0.007
    colRange = 0.1 .. 1.0
  discard newEntityWith(
    Model(modelId: squareModel, scale: vec3(scale), angle: rand(TAU), col: vec4(rand colRange, rand colRange, rand colRange, 1.0)),
    Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0),
    Velocity(speed: speed),
    #Direction(),
    Cluster(radius: 0.03, turnAmount: turnAmount),
    Rotate(angle: rand TAU, rotateSpeed: PI),
    GridMap()
  )

import times, strformat

when showFps:
  var
    t1 = cpuTime()
    fc: int

type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
proc pressed(keyStates: KeyCodes, sc: Scancode): bool = result = keyStates[sc.int] > 0'u8

proc main =
  echo "Keys: R = Randomise positions, Space = Randomise turn amount."
  # Render loop.
  while running:
    while pollEvent(evt):
      if evt.kind == QuitEvent:
        running = false
        break

      var keyStates: KeyCodes = getKeyboardState()
      if keyStates.pressed(SDL_SCANCODE_SPACE):
        # Reformat particles to a new turnAround value.
        let ta = rand -25.0.degToRad..25.0.degToRad
        sysSetTurnAmount.turnAmount = ta
        sysSetTurnAmount.paused = false
        echo &"Set turn amount to {ta} ({ta.radToDeg:>4.4f} degrees)"

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
        echo "FPS: ", fc
        t1 = cpuTime()
        fc = 0

    window.glSwapWindow()

main()
