import polymorph

template defineOpenGlRenders*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  import opengl, glbits/modelrenderer

  registerComponents(compOpts):
    type
      Model* = object
        modelId*: ModelId
        scale*: GLvectorf3
        angle*: GLfloat
        col*: GLvectorf4

      Position = object
        x*, y*, z*: float

  defineSystem("updateModelData", [Model, Position], sysOpts)

  makeSystemBody("updateModelData"):
    start:
      var curPositions = newSeq[int](modelCount())
    all:
      # Fill the buffers for this model.
      let
        mId = item.model.modelId
        curPos = curPositions[mId.int]

      mId.positionVBOArray[curPos] = vec3(item.position.x, item.position.y, item.position.z)
      mId.scaleVBOArray[curPos] = item.model.scale
      mId.rotationVBOArray[curPos] = [item.model.angle]
      mId.colVBOArray[curPos] = item.model.col
      curPositions[mId.int] = curPos + 1



when isMainModule:
  # Demo of model rendering ECS.
  # This expects SDL2.dll to be in the current directory,
  # available from here: https://www.libsdl.org/download-2.0.php

  import opengl, sdl2, random
  from math import TAU, PI, degToRad, cos, sin, arctan2

  when defined(debug):
    const maxEnts = 80_000
  else:
    const maxEnts = 300_000
  const
    compOpts = fixedSizeComponents(maxEnts)
    sysOpts = fixedSizeSystem(maxEnts)
    entOpts = fixedSizeEntities(maxEnts)
  defineOpenGlRenders(compOpts, sysOpts)

  registerComponents(compOpts):
    type
      Velocity = object
        x, y: float32
      Spin = float
      AvoidMouse = object
        dist: float
        speed: float
      AttractToMouse = object
        dist: float
        speed: float

  template bounce(variable: untyped) =
    if item.position.variable < -1.0:
      item.position.variable = -1.0
      item.velocity.variable *= -1.0
    if item.position.variable > 1.0:
      item.position.variable = 1.0
      item.velocity.variable *= -1.0

  # Add a movement system
  makeSystemOpts("movement", [Position, Velocity], sysOpts):
    all:
      item.position.x += item.velocity.x
      item.position.y += item.velocity.y
      bounce(x)
      bounce(y)

  makeSystemOpts("spin", [Model, Spin], sysOpts):
    all:
      item.model.angle = item.model.angle + item.spin.access

  template reactToPoint(offset, dist, speed: float): untyped =
    ## Move toward or away from point, based on multiplier.
    let
      dx = sys.mousePos[0] - item.position.x
      dy = sys.mousePos[1] - item.position.y
      sDist = dx * dx + dy * dy
      sExtent = dist * dist
    if sDist <= sExtent:
      let
        angle = arcTan2(dy, dx)
        reactAngle = angle + offset
        reactSpeed = speed
      item.velocity.x = reactSpeed * cos(reactAngle)
      item.velocity.y = reactSpeed * sin(reactAngle)


  makeSystemOptFields("attractMouse", [Position, Velocity, AttractToMouse], sysOpts) do:
    mousePos: GLvectorf2
  do:
    all: reactToPoint(0.0, item.attractToMouse.dist, item.attractToMouse.speed)

  makeSystemOptFields("avoidMouse", [Position, Velocity, AvoidMouse], sysOpts) do:
    mousePos: GLvectorf2
  do:
    all: reactToPoint(PI, item.avoidMouse.dist, item.avoidMouse.speed)

  makeEcs(entOpts)
  commitSystems("run")

  # Create window and OpenGL context.
  discard sdl2.init(INIT_EVERYTHING)

  var
    screenWidth: cint = 640
    screenHeight: cint = 480
    xOffset: cint = 50
    yOffset: cint = 50

  var window = createWindow("SDL/OpenGL Skeleton", xOffset, yOffset, screenWidth, screenHeight, SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
  var context = window.glCreateContext()

  # Initialize OpenGL
  loadExtensions()
  glClearColor(0.0, 0.0, 0.0, 1.0)                  # Set background color to black and opaque
  glClearDepth(1.0)                                 # Set background depth to farthest

  var
    evt = sdl2.defaultEvent
    running = true
  let shaderProg = newModelRenderer()

  proc makeCircleModel(triangles: int, insideCol, outsideCol: GLvectorf4): ModelId =
    ## Create a coloured model with `triangles` sides.
    let angleInc = TAU / triangles.float
    const radius = 1.0
    var
      model = newSeq[GLvectorf3](triangles * 3)
      colours = newSeq[GLvectorf4](triangles * 3)
      curAngle = 0.0
      vertex = 0
    for i in 0 ..< triangles:
      model[vertex] = vec3(0.0, 0.0, 0.0)
      colours[vertex] = insideCol
      model[vertex + 1] = vec3(radius * cos(curAngle), radius * sin(curAngle), 0.0)
      colours[vertex + 1] = outsideCol
      curAngle += angleInc
      model[vertex + 2] = vec3(radius * cos(curAngle), radius * sin(curAngle), 0.0)
      colours[vertex + 2] = outsideCol
      vertex += 3
    newModel(shaderProg, model, colours)

  let
    circleModel = makeCircleModel(10, vec4(1.0, 0.0, 0.0, 1.0), vec4(0.5, 0.0, 0.5, 1.0))
    squareModel = makeCircleModel(4, vec4(0.0, 1.0, 0.0, 1.0), vec4(0.5, 0.5, 0.0, 1.0))
    
    maxCircles = maxEnts
    maxSquares = maxEnts

  circleModel.setMaxInstanceCount(maxCircles)
  squareModel.setMaxInstanceCount(maxSquares)

  # Create some entities with our models.
  var ents: seq[EntityRef]
  for i in 0 ..< maxEnts:
    let
      pos = Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0)
      speed = rand 0.005..0.01
    if rand(1.0) < 0.1:
      let scale = 0.007
      ents.add newEntityWith(
        Model(modelId: circleModel, scale: vec3(scale, scale, scale), angle: rand(TAU), col: vec4(rand 1.0, 1.0, 1.0, 1.0)),
        pos,
        Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
        Spin(rand(-1.0..1.0).degToRad),
        AttractToMouse(dist: 0.4, speed: speed * 0.3))
    else:
      let scale = 0.004
      ents.add newEntityWith(
        Model(modelId: squareModel, scale: vec3(scale, scale, scale), angle: rand(TAU), col: vec4(rand 1.0, 1.0, 0.0, 1.0)),
        pos,
        Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
        Spin(rand(-1.0..1.0).degToRad),
        AvoidMouse(dist: 0.4, speed: speed))

  var mousePos: GLvectorf2

  # Render loop.
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
        # Update systems with mouse position
        sysAttractMouse.mousePos = mousePos
        sysAvoidMouse.mousePos = mousePos

    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    run()
    renderModels()

    glFlush()
    window.glSwapWindow() # Swap the front and back frame buffers (double buffering)

