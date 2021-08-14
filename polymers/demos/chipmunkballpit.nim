## This demo shows how to use ecs_chipmunk2D to simulate:
## 
##  - Creating entities with physics components from blueprints,
##  - Colliding circles, polygons, and segment shapes,
##  - The use of collision callbacks.
## 
## Press the mouse button to release more balls.
## 
## For more on how to use Chipmunk2D, see the documentation here:
## https://chipmunk-physics.net/release/ChipmunkLatest-Docs/
## 
## Requires the Chipmunk2D redistributable from https://chipmunk-physics.net/
## The Chipmunk2D Nim wrapper: https://github.com/oprypin/nim-chipmunk
## glBits OpenGL utils: https://github.com/rlipsc/glbits


import polymorph, polymers, sdl2, glbits/modelrenderer, random, math, times


# Design and build the ECS.
# -------------------------

const
  maxEnts = 5_000
  entOpts = fixedSizeEntities(maxEnts)
  compOpts = fixedSizeComponents(maxEnts)
  sysOpts = fixedSizeSystem(maxEnts)

# Define components for Chipmunk2D.
defineECSChipmunk2D(compOpts)

registerComponents(compOpts):
  type
    Position = object
      # This component will be used by the model renderer.
      x, y, z: float
    Fizzy = object
      # This component applies a randomised push of 'magnitude' to
      # entities with a physics body.
      magnitude: float
      angle: float
      angleChangedAt: float
    Rotate* = object
      # This component sets the angular velocity of a physics body.
      speed*: float

# Include just the components for drawing instanced models with OpenGl.
# We'll add the GPU update system separately later.
defineOpenGlComponents(compOpts, Position)

makeSystemOpts("fizzy", [PhysicsBody, Fizzy], sysOpts):
  # This system applies randomised forces to the physics body.
  #
  # Chipmunk considers v(0.0, 0.0) as the centre of gravity for
  # applying forces. Using an offset from this causes a rotational
  # effect, according to the mass and force involved.
  #
  # In this case, the body is pushed along from the "front" (the
  # strongly coloured point in the matching model), causing the
  # "back" to align over time.
  #
  # With an offset of v(0.0, 0.0) to apply the force, the body would
  # continue at its current angle until there was a collision.
  const offset = v(0.0, 0.5)

  all:
    let body = item.physicsBody.body

    let
      # Choose a left or right vector randomly.
      dir =
        if rand(1.0) < 0.5:
          v(-1.0, 0.0)
        else:
          v(1.0, 0.0)
      turnForce = dir * item.fizzy.magnitude

    # Apply the turn force in local space, where coordinates are
    # unaffected by the body's rotation.
    body.applyForceAtLocalPoint turnForce * body.mass, offset

    # Apply a "forward" push to the body in local space.
    body.applyForceAtLocalPoint v(0.0, item.fizzy.magnitude * body.mass), offset

    # For more on different ways to apply forces, see:
    # https://chipmunk-physics.net/release/ChipmunkLatest-Docs/#cpBody-Forces

makeSystemOpts("updatePosition", [PhysicsBody, Position, Model], sysOpts):
  all:
    # Syncs component data used for rendering models with the Chipmunk2D
    # physics body.
    let pos = item.physicsBody.body.position
    item.position.x = pos.x
    item.position.y = pos.y
    item.model.angle = item.physicsBody.body.angle

makeSystemOpts("rotate", [PhysicsBody, Rotate], sysOpts):
  all:
    # Apply a constant turn speed.
    item.physicsBody.body.angularVelocity = item.rotate.speed

# The GPU update system should run after any changes to the Position and
# Model components.
defineOpenGLUpdateSystems(sysOpts, Position)

# Build ECS.
makeEcs(entOpts)

# Output the currently defined system body procs.
commitSystems("run")


# Initialise SDL2 and OpenGL.
# ---------------------------

# Create window and OpenGL context.
discard sdl2.init(INIT_EVERYTHING)

var
  screenWidth: cint = 1024
  screenHeight: cint = 768
  xOffset: cint = 50
  yOffset: cint = 50

var window = createWindow("SDL/OpenGL Skeleton", xOffset, yOffset, screenWidth, screenHeight, SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
var context = window.glCreateContext()

# Initialize OpenGL
loadExtensions()
glClearColor(0.0, 0.0, 0.0, 1.0)  # Set background colour to black and opaque
glClearDepth(1.0)                 # Set background depth to farthest


# Create the models.
# ------------------

let shaderProg = newModelRenderer()

# Create the circle model used for the balls.
let
  # These vertex colours are mixed with Model.col when rendered.
  innerCol = vec4(1.0, 1.0, 1.0, 1.0)
  outerCol = vec4(0.1, 0.1, 0.1, 1.0)
  circleModelId = makeCircleModel(shaderProg, 24, innerCol, outerCol, maxInstances = maxEnts)

# Create the triangle model for the mouse and Fizzy entities.
var
  triangleVerts =
    @[
      # These are defined with Chipmunk's Vect type so we can use them
      # for the polygon physics shape as well later on.
      v(0.5, -0.5),
      v(-0.5, -0.5),
      v(0.0, 0.5),
    ]
let
  # Vertex colours.
  triangleCols = @[
    vec4(0.0, 0.0, 1.0, 1.0),
    vec4(0.0, 1.0, 0.0, 1.0),
    vec4(1.0, 0.0, 0.0, 1.0),
  ]
  triangleModelId = makePolyModel(shaderProg, triangleVerts, triangleCols, maxInstances = maxEnts)


# Set up the physics space.
# -------------------------

physicsSpace.gravity = v(0.0, -1.1)
physicsSpace.damping = 0.8

# Create some collision masks.
const
  cBall* =  0b0001.BitMask
  cWall* =  0b0010.BitMask


# Set up physics collisions.
# --------------------------

let
  # Chipmunk allows you to create custom callback handles for pairs of
  # collision types.
  # See: https://chipmunk-physics.net/release/ChipmunkLatest-Docs/#CollisionDetection-HandlerFiltering
  #
  # In this program we're just using a single collision type.
  ctCollide = cast[CollisionType](1)

  circleShapeFilter = chipmunk.ShapeFilter(
    categories: cBall,
    # Collide with other balls and walls.
    mask: cBall or cWall
  )

  wallShapeFilter = chipmunk.ShapeFilter(
    categories: cWall,
    mask: cBall
  )
var
  highestKE: float

proc collisionCallback*(arb: Arbiter; space: Space; data: pointer): bool {.cdecl.} =
  # This proc is applied to every collision in the simulation with
  # `addCollisionHandler` below.
  #
  # All we do here is read the kinetic energy to find the highest value,
  # and the rest is included as an example of accessing other collision
  # information.
  var
    bodyA, bodyB: Body
    shapeA, shapeB: Shape

  # Get bodies involved.
  arb.bodies(addr(bodyA), addr(bodyB))
  # Get shapes involved.
  arb.shapes(addr(shapeA), addr(shapeB))

  # ecs_chipmunk2D sets up `userData` for the Body and Shape objects
  # stored in PhysicsBody and PhysicsShape.
  assert shapeA.userData != nil and shapeB.userData != nil

  let
    e1 = shapeA.getEntity
    e2 = shapeB.getEntity
    energy = arb.totalKe
    contactPoints = arb.contactPointSet
  
  # Record the highest kinetic energy to use later.
  if energy > highestKE:
    highestKE = energy

  # Example of some of the information Chipmunk2D makes available.
  # For more information about arbiters, see:
  # https://chipmunk-physics.net/release/ChipmunkLatest-Docs/#cpArbiter
  when false:
    echo "Entities collided: ", e1.entityId.int, " and ", e2.entityId.int
    echo "Kinetic energy: ", energy
    echo "Masses: ", bodyA.mass, ", ", bodyB.mass

    for i in 0 ..< contactPoints.count:
      echo "Contact points: A: ",
        contactPoints.points[i].pointA, " B: ",
        contactPoints.points[i].pointB,
        " distance: ", contactPoints.points[i].distance    

# Create a collision handler for every collision of ctCollide with itself.
# We could also use wildcard handlers.
var collisionHandler = physicsSpace.addCollisionHandler(ctCollide, ctCollide)

# Hook our collision handler as post-collision. At this stage the collision
# response has been processed and the details are available within the callback.
#
# For other types of collision handler, see:
# https://chipmunk-physics.net/release/ChipmunkLatest-Docs/#CollisionCallbacks-Handlers
collisionHandler.postSolveFunc = cast[CollisionPostSolveFunc](collisionCallback)


# Build the wall segments.
# ------------------------

proc wallShapeTemplate(start, finish: Vect, width: float): ShapeTemplate =
  # Convenience proc for setting up a wall ShapeTemplate.
  ShapeTemplate(
    filter: wallShapeFilter, collisionType: ctCollide, elasticity: 0.9,
    kind: skSegment,
    a: start, b: finish,
    radius: width
  )

let
  wallWidth = 0.5
  wallBodyTemplate = BodyTemplate(mass: 1.0, bodyType: BODY_TYPE_STATIC)

  # Construct the wall entities from ComponentLists, converting
  # BodyTemplate into PhysicsBody and ShapeTemplate into PhysicsShape.

  leftWall = cl(
      wallBodyTemplate,
      wallShapeTemplate(v(-1.0 - wallWidth, 1.0), v(-1.0 - wallWidth, -1.0), wallWidth)
    ).construct

  rightWall = cl(
      wallBodyTemplate,
      wallShapeTemplate(v(1.0 + wallWidth, 1.0), v(1.0 + wallWidth, -1.0), wallWidth)
    ).construct

  topWall = cl(
      wallBodyTemplate,
      wallShapeTemplate(v(-1.0, -1.0 - wallWidth), v(1.0, -1.0 - wallWidth), wallWidth)
    ).construct

  bottomWall = cl(
      wallBodyTemplate,
      wallShapeTemplate(v(-1.0, 1.0 + wallWidth), v(1.0, 1.0 + wallWidth), wallWidth)
    ).construct

func scaleTo[T](list: openarray[T], scale: float): seq[T] =
  # Convenience func for scaling a list of vertices.
  result.setLen list.len
  for i, v in list:
    result[i] = v * scale


# Create entity blueprints.
# -------------------------

# These blueprints are passed to 'construct' to build run time entities.

let
  ballScale = 0.01
  ballMass = 0.03
  # Create a ComponentList blueprint for the balls.
  ballCL = cl(
    Position(), # The (x, y) is updated to the physics body position in "updatePosition".
    Model(
      modelId: circleModelId,
      scale: vec3(ballScale),
      # We'll set the colour individually after construction.
    ),
    BodyTemplate(
      # This is replaced during construction with an initialised
      # PhysicsBody.
      radius: ballScale,
      mass: ballMass,
      moment: momentForCircle(ballMass, ballScale),
    ),
    ShapeTemplate(
      # This is replaced during construction with an initialised
      # PhysicsShape.
      kind: skCircle,

      radius: ballScale,
      filter: circleShapeFilter,
      collisionType: ctCollide,
      elasticity: 0.98,
    ),
  )

  fizzyScale = 0.04
  fizzyMass = 0.2
  # Create a ComponentList for 'fizzy' triangles that apply forces to
  # themselves per tick.
  fizzyBallCL = cl(
    Position(), # The position is updated from the physics body.
    Model(
      modelId: triangleModelId,
      scale: vec3(fizzyScale),
      col: vec4(0.9, 0.0, 0.9, 1.0) # Use a fixed colour.
    ),
    Fizzy(),  # We'll set the magnitude individually after construction.
    BodyTemplate(
      radius: fizzyScale,
      mass: fizzyMass,
      moment: momentForPoly(fizzyMass, triangleVerts)
    ),
    ShapeTemplate(
      kind: skPoly,
      polyVerts: triangleVerts.scaleTo fizzyScale,
      transform: TransformIdentity,

      radius: 0.0,  # Radius extends the boundaries for polygon shapes.
      filter: circleShapeFilter,
      collisionType: ctCollide,
      elasticity: 0.4,
    ),
  )

  mouseRadius = 0.1
  # This ComponentList blueprint creates an entity with physics body
  # that is positioned at the mouse cursor for mixing up balls.
  #
  # When the left mouse button is pressed and balls are released, this
  # entity is deleted so it doesn't push the balls about. It's then
  # created again when mouse button is released.
  mouseCL = cl(
    Position(),
    Model(
      modelId: triangleModelId,
      scale: vec3(mouseRadius),
      col: vec4(1.0)
    ),
    BodyTemplate(
      radius: mouseRadius,
      mass: 1.0,
      bodyType: BODY_TYPE_KINEMATIC,  # Kinematic bodies are manually updated.
    ),
    ShapeTemplate(
      kind: skPoly,
      polyVerts: triangleVerts.scaleTo mouseRadius,
      transform: TransformIdentity,

      radius: 0.0,
      filter: circleShapeFilter,
      collisionType: ctCollide,
      elasticity: 0.96,
    ),
    Rotate(
      speed: 8.0
    )
  )


# Run simulation.
# ---------------

proc createBallAt(x, y: GLfloat, spread = 0.01): EntityRef =
  # Create a number of "ball" entities (fizzy "balls" are triangles).

  # Reserve entities for the mouse body and the energy display entity.
  if maxEnts - entityCount() < 2: return

  if rand(1.0) < 0.05:
    # Some balls are fizzy.
    result = fizzyBallCL.construct()
    let
      fizzy = result.fetch Fizzy

    # The magnitude is scaled by mass when forces are applied.
    fizzy.magnitude = rand 2.5 .. 3.5

  else:
    result = ballCL.construct()

    let model = result.fetch Model
    model.col = vec4(rand 0.8, rand 1.0, rand 1.0, 1.0)

  # Set the initial position and force of the ball.
  let
    phys = result.fetch PhysicsBody
    newPos = v(x + rand -spread..spread, y + rand -spread .. spread)
    angle = rand TAU
    force = angle.vForAngle * phys.body.mass
    offset = v(0.0, 0.0)

  phys.body.position = newPos
  phys.body.angle = angle
  phys.body.applyForceAtLocalPoint force, offset

proc createBallsAt(x, y: GLfloat, count: int, spread = 0.01) =
  for i in 0 ..< count:
    discard createBallAt(x, y, spread)

template every(time: float, actions: untyped) =
  # Perform 'actions' every 'time' seconds.
  var lastTime {.global.} = epochTime()
  block:
    let t = epochTime()
    if t - lastTime >= time:
      lastTime = t
      actions

proc main =
  # Run simulation.

  const
    fps = 60.0
    physUpdateSpeed = 1.0 / fps
  var
    running = true
    evt = sdl2.defaultEvent

    mX, mY: GLfloat
    lmb: bool

    # Build the initial kinematic body and shape that tracks the mouse.
    # This is destroyed when balls are released by pressing the mouse
    # button and recreated when the button is released.
    mouseBodyEnt = mouseCL.construct

    # When mouseVelocityScale == fps, the body will track the cursor
    # almost per frame, and large forces can be generated by sharp
    # movements of the mouse.
    mouseVelocityScale = 2.0

  let
    energyMeterBaseScale = 0.02
    # Create an entity with a model to display the largest kinetic
    # energy reported in collisions.
    energyMeter =
      newEntityWith(
        Position(x: 0.9, y: 0.9),
        Model(
          modelId: circleModelId,
          scale: vec3(energyMeterBaseScale),
          col: vec4(0.1, 0.5, 0.5, 1.0)
        ),
      )
    energyModel = energyMeter.fetch Model

  # Create some starter balls.
  for i in 0 ..< 2:
    createBallsAt(rand -0.99 .. 0.99, 0.99, count = 5)


  while running:

    # Capture SDL events.
    while pollEvent(evt):
      if evt.kind == QuitEvent:
        running = false
        break

      if evt.kind == MouseMotion:
        # Map SDL mouse position to -1..1 for OpenGL.
        let
          mm = evMouseMotion(evt)
          normX = mm.x.float / screenWidth.float
          normY = 1.0 - (mm.y.float / screenHeight.float)
        mX = (normX * 2.0) - 1.0
        mY = (normY * 2.0) - 1.0

      if evt.kind == MouseButtonDown:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          lmb = true
          mouseBodyEnt.delete

      if evt.kind == MouseButtonUp:
        var mb = evMouseButton(evt)
        if mb.button == BUTTON_LEFT:
          lmb = false
          mouseBodyEnt = mouseCL.construct
          # Update the position to match the mouse.
          let phys = mouseBodyEnt.fetch PhysicsBody
          phys.body.position = v(mX, mY)


    # Randomly drop some balls from the mouse every now and then.
    if (entityCount() < maxEnts and lmb) or rand(1.0) < 0.001:
      createBallsAt(mx, my, count = 5)

    if mouseBodyEnt.alive:
      # Position the mouse body at the last known mouse coordinates.
      let mouseBody = mouseBodyEnt.fetch PhysicsBody
      assert mouseBody.valid

      # Kinematic bodies should be moved by setting velocity.
      # Setting position directly doesn't let Chipmunk factor in forces,
      # and collisions will look "mushy".
      # See: https://chipmunk-physics.net/release/ChipmunkLatest-Docs/#cpBody-Movement
      let curPos = mouseBody.body.position
      mouseBody.body.velocity = v(mX - curPos.x, mY - curPos.y) * mouseVelocityScale

    every(physUpdateSpeed):

      highestKe = 0.0

      # Run systems in the ECS.
      run()

      # Run a simulation step in Chipmunk.
      physicsSpace.step(physUpdateSpeed)

      # keScale is an arbitrary scaling based on an expected range of
      # masses and velocities involved.
      const keScale = 0.4
      let keNorm = clamp(highestKe * keScale, 0.0, 1.0)

      # Update energy meter size and colour.
      energyModel.scale = vec3(energyMeterBaseScale + keNorm * keScale)
      energyModel.col = vec4(keNorm, 1.0 - keNorm, 0.0, 1.0)

    # Clear screen.
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    # Render models in use.
    renderActiveModels()
    
    window.glSwapWindow()

main()
