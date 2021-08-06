import polymorph
from strutils import toLowerAscii

template defineOpenGlComponents*(compOpts: ECSCompOptions, positionType: typedesc) {.dirty.} =
  import opengl, glbits, glbits/modelrenderer

  type
    TextureId* = distinct int

  const rectangle: array[6, TextureVertex] = [
    [-1.0.GLFloat, 1.0, 0.0,    0.0, 1.0],
    [1.0.GLFloat, 1.0, 0.0,     1.0, 1.0],
    [-1.0.GLFloat, -1.0, 0.0,   0.0, 0.0],
    #
    [1.0.GLFloat, -1.0, 0.0,    1.0, 0.0],
    [-1.0.GLFloat, -1.0, 0.0,   0.0, 0.0],
    [1.0.GLFloat, 1.0, 0.0,     1.0, 1.0]
  ]

  registerComponents(compOpts):
    type
      Model* = object
        modelId*: ModelId
        scale*: GLvectorf3
        angle*: GLfloat
        col*: GLvectorf4
      
      Texture* = object
        textureId*: TextureId
        scale*: GLvectorf2
        angle*: GLfloat
        col*: GLvectorf4

macro defineOpenGLUpdateSystems*(sysOpts: ECSSysOptions, positionType: typedesc): untyped =
  ## Add the system to send model and position data to the GPU.
  
  let posIdent = ident toLowerAscii($positionType)

  result = newStmtList(quote do:
    makeSystemOpts("updateModelData", [Model, `positionType`], `sysOpts`):
      # This system populates the instance buffers and keeps track of
      # how many instances need to be rendered per model.
      fields:
        curModelCount {.pub.}: seq[int]

      # Reset model counters.
      sys.curModelCount.setLen modelCount()
      for i in 0 ..< sys.curModelCount.len:
        sys.curModelCount[i] = 0

      all:
        # Populate instance buffers.
        let
          mId = item.model.modelId
          curPos = sys.curModelCount[mId.int]
        mId.positionVBOArray[curPos] = vec3(item.`posIdent`.x, item.`posIdent`.y, item.`posIdent`.z)
        mId.scaleVBOArray[curPos] = item.model.scale
        mId.rotationVBOArray[curPos] = [item.model.access.angle]
        mId.colVBOArray[curPos] = item.model.col

        sys.curModelCount[mId.int].inc

    makeSystemOpts("updateTextureData", [Texture, `positionType`], `sysOpts`):
      # This system populates billboard instances.
      fields:
        billboards {.pub.}: seq[TexBillboard]

      # Reset texture counters.
      for i in 0 ..< sys.billboards.len:
        sys.billboards[i].resetItemPos

      all:
        # Populate instances.
        let
          tId = item.texture.textureId
        sys.billboards[tId.int].addItems(1):
          curItem.positionData =  vec4(item.`posIdent`.x, item.`posIdent`.y, item.`posIdent`.z, 1.0)
          curItem.colour =        item.texture.col
          curItem.rotation[0] =   item.texture.angle
          curItem.scale =         item.texture.scale

    iterator activeModels*: tuple[model: ModelId, count: int] =
      ## Render only models that have been processed by `updateModelData`.
      for modelIndex in 0 ..< modelCount():
        if modelIndex < sysUpdateModelData.curModelCount.len:
          let count = sysUpdateModelData.curModelCount[modelIndex]
          if count > 0:
            yield (modelByIndex(modelIndex), count)

    proc renderActiveModels* =
      ## Render only models that have been processed by `updateModelData`.
      for modelInfo in activeModels():
        renderModel(modelInfo.model, modelInfo.count)

    template renderActiveModelsSetup*(setup: untyped) =
      ## Render only models that have been processed by `updateModelData`.
      for modelInfo in activeModels():
        renderModelSetup(modelInfo.model, modelInfo.count, setup)
    
    proc renderActiveTextures* = 
      for i in 0 ..< sysUpdateTextureData.billboards.len:
        template bb: untyped = sysUpdateTextureData.billboards[i]
        bb.render

    proc newTextureId*(vertexGLSL = defaultTextureVertexGLSL, fragmentGLSL = defaultTextureFragmentGLSL,
        max = 1, model: openarray[TextureVertex] = rectangle, modelScale = 1.0, manualTextureBo = false, manualProgram = false): TextureId =
      sysUpdateTextureData.billboards.add newTexBillboard(vertexGLSL = vertexGLSL, fragmentGLSL = fragmentGLSL, max = max, model = model,
        modelScale = modelScale, manualTextureBo = manualTextureBo, manualProgram = manualProgram)
      result = sysUpdateTextureData.billboards.high.TextureId
      template bb: untyped = sysUpdateTextureData.billboards[result.int]
      bb.rotMat[0] = 1.0
    
    proc update*(textureId: TextureId, texture: GLTexture) =
      sysUpdateTextureData.billboards[textureId.int].updateTexture(texture)
  )

template defineOpenGlRenders*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions, positionType: typedesc) {.dirty.} =
  defineOpenGLComponents(compOpts, positionType)
  defineOpenGLUpdateSystems(sysOpts, positionType)

template defineOpenGlRenders*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  registerComponents(compOpts):
    type
      Position* = object
        x*, y*, z*: float
  defineOpenGLComponents(compOpts, Position)
  defineOpenGLUpdateSystems(sysOpts, Position)


# ----------------

when isMainModule:
  # Demo of a model and texture rendering ECS.
  # See also demos/particledemo.nim for an expanded version.
  #
  # This expects SDL2.dll to be in the current directory,
  # available from here: https://www.libsdl.org/download-2.0.php

  import opengl, sdl2, random, glbits/modelrenderer
  from math import TAU, PI, degToRad, cos, sin, arctan2, sqrt

  when defined(debug):
    const maxEnts = 150_000
  else:
    const maxEnts = 400_000
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
    all:
      bounce(x)
      bounce(y)

  makeSystemOpts("spinModel", [Model, Spin], sysOpts):
    all:
      item.model.angle = item.model.angle + item.spin.access

  makeSystemOpts("spinTexture", [Texture, Spin], sysOpts):
    all:
      item.texture.angle = item.texture.angle + item.spin.access

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

  makeSystemOpts("attractMouse", [Position, Velocity, AttractToMouse], sysOpts):
    fields:
      mousePos: GLvectorf2
    all: reactToPoint(0.0, item.attractToMouse.dist, item.attractToMouse.speed)

  makeSystemOpts("avoidMouse", [Position, Velocity, AvoidMouse], sysOpts):
    fields:
      mousePos: GLvectorf2
    all: reactToPoint(PI, item.avoidMouse.dist, item.avoidMouse.speed)

  makeEcs(entOpts)
  commitSystems("run")

  proc createBallTexture(texture: var GLTexture, w, h = 120) =
    # Draw on a texture.
    texture.initTexture(w, h)

    proc dist(x1, y1, x2, y2: float): float =
      let
        diffX = x2 - x1
        diffY = y2 - y1
      result = sqrt((diffX * diffX) + (diffY * diffY))

    let
      centre = [texture.width / 2, texture.height / 2]
      maxDist = dist(centre[0], centre[1], texture.width.float, texture.height.float)
      spikes = 5.0

    for y in 0 ..< texture.height:
      for x in 0 ..< texture.width:
        let
          ti = texture.index(x, y)
          diff = [centre[0] - x.float, centre[1] - y.float]
          d = sqrt((diff[0] * diff[0]) + (diff[1] * diff[1]))
          angle = diff[1].arcTan2 diff[0]
          spikeMask = cos(spikes * angle)
          normD = d / maxDist
          edgeDist = smootherStep(1.0, 0.0, normD)
        texture.data[ti] = vec4(edgeDist, edgeDist, edgeDist,
          smootherStep(0.0, spikeMask, edgeDist))

  # Create window and OpenGL context.
  discard sdl2.init(INIT_EVERYTHING)

  var
    screenWidth: cint = 640
    screenHeight: cint = 480
    xOffset: cint = 50
    yOffset: cint = 50

  var window = createWindow("SDL/OpenGL Skeleton", xOffset, yOffset, screenWidth, screenHeight, SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
  var context {.used.} = window.glCreateContext()

  # Initialize OpenGL
  loadExtensions()
  glClearColor(0.0, 0.0, 0.0, 1.0)                  # Set background color to black and opaque
  glClearDepth(1.0)                                 # Set background depth to farthest
  glEnable(GL_DEPTH_TEST)                           # Enable depth testing for z-culling
  glDepthFunc(GL_LEQUAL)                            # Set the type of depth-test
  glEnable(GL_BLEND)                                # Enable alpha channel
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

  var
    evt = sdl2.defaultEvent
    ballTextureData: GLTexture
    running = true
  let shaderProg = newModelRenderer()

  let
    circleModel = shaderProg.makeCircleModel(10, vec4(1.0, 0.0, 0.0, 1.0), vec4(0.5, 0.0, 0.5, 1.0))
    squareModel = shaderProg.makeCircleModel(4, vec4(0.0, 1.0, 0.0, 1.0), vec4(0.5, 0.5, 0.0, 1.0))
    ballTexture = newTextureId(max = maxEnts)
    maxCircles = maxEnts
    maxSquares = maxEnts

  ballTextureData.createBallTexture()
  ballTexture.update(ballTextureData)

  circleModel.setMaxInstanceCount(maxCircles)
  squareModel.setMaxInstanceCount(maxSquares)

  # Create some entities with our models.
  var
    ents: seq[EntityRef]

  while entityCount() < maxEnts:
    let
      pos = Position(x: rand(-1.0..1.0), y: rand(-1.0..1.0), z: 0.0)
      speed = rand 0.005..0.01
      r = rand(1.0)
    if r < 0.1:
      let scale = 0.01
      ents.add newEntityWith(
        Model(modelId: circleModel, scale: vec3(scale, scale, scale), angle: rand(TAU),
          col: vec4(rand 1.0, rand 1.0, 1.0, 1.0)),
        pos,
        Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
        Spin(rand(-1.0..1.0).degToRad),
        AttractToMouse(dist: 0.4, speed: speed * 0.3))
    elif r < 0.995:
      let scale = 0.007
      ents.add newEntityWith(
        Model(modelId: squareModel, scale: vec3(scale, scale, scale), angle: rand(TAU),
          col: vec4(rand 1.0, rand 1.0, rand 1.0, 1.0)),
        pos,
        Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
        Spin(rand(-1.0..1.0).degToRad),
        AvoidMouse(dist: 0.4, speed: speed))
    else:
      let scale = 0.025
      ents.add newEntityWith(
        Texture(textureId: ballTexture, scale: vec2(scale, scale), angle: rand(TAU),
          col: vec4(rand 1.0, rand 1.0, rand 1.0, 1.0)),
        pos,
        Velocity(x: rand(-speed..speed), y: rand(-speed..speed)),
        Spin(rand(-10.0..10.0).degToRad),
      )

  var mousePos: GLvectorf2

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
        # Update systems with mouse position
        sysAttractMouse.mousePos = mousePos
        sysAvoidMouse.mousePos = mousePos

    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    run()
    renderActiveModels()
    renderActiveTextures()
    
    glFlush()
    window.glSwapWindow() # Swap the front and back frame buffers (double buffering)

