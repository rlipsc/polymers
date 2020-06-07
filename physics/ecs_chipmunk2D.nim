#[
  Polymorph ECS component for the Chipmunk physics engine.
    Chipmunk Physics: https://chipmunk-physics.net/
    Nim wrapper: https://github.com/oprypin/nim-chipmunk  
]#

import polymorph

template defineECSChipmunk2D*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  import chipmunk
  export chipmunk
  
  type
    ShapeKind* = enum skCircle, skSquare, skPoly, skSegment
    ShapeDataObj* = object
      entity*: EntityRef
      kind*: ShapeKind    
    ShapeData* = ptr ShapeDataObj
    BodyDataObj* = object
      entity*: EntityRef
    BodyData* = ptr BodyDataObj

  registerComponents(compOpts):
    type
      PhysicsBody* = object
        body*: Body
      PhysicsShape* = object
        shapes*: seq[Shape]
      BodyTemplate* = object
        ## This component generates a PhysicsBody when added to an entity.
        x*, y*: float   
        radius*: float
        mass*, angle*: float
        bodyType*: BodyType
      ShapeTemplate* = object
        ## This component generates a PhysicsShape when added to an entity.
        filter*: chipmunk.ShapeFilter
        collisionType*: CollisionType
        radius*: float
        polyVerts*: seq[Vect]
        kind*: ShapeKind

  # Set up Chipmunk space.
  var physicsSpace* = newSpace()

  # Shape
  template getData*(shape: Shape): ShapeData = cast[ShapeData](shape.userData)
  template getEntity*(shape: Shape): EntityRef = shape.getData.entity
  template getKind*(shape: Shape): ShapeKind = shape.getData.kind
  template setEntity*(shape: Shape, entityRef: EntityRef): untyped =
    let curData = cast[ShapeData](shape.userData)
    if curData == nil:
      var data = cast[ShapeData](alloc0(ShapeDataObj.sizeOf))
      data.entity = entityRef
      shape.userData = cast[DataPointer](data)
    else:
      curData.entity = entityRef

  template setData*(shape: Shape, entityRef: EntityRef, shapeKind: ShapeKind): untyped =
    let curData = cast[ShapeData](shape.userData)
    if curData == nil:
      var data = cast[ShapeData](alloc0(ShapeDataObj.sizeOf))
      data.entity = entityRef
      data.kind = shapeKind
      shape.userData = cast[DataPointer](data)
    else:
      curData.entity = entityRef
      curData.kind = shapeKind

  proc getOffset*(shape: Shape, kind: ShapeKind): Vect =
    case kind
    of skCircle: result = cast[CircleShape](shape).offset
    of skSquare, skPoly, skSegment: raise newException(ValueError, "Cannot get offset for PolyShapes")

  proc finaliseShape*(shape: Shape) =
    var shapeData = shape.getData()
    shapeData.dealloc
    physicsSpace.removeShape(shape)
    shape.destroy()
  
  PhysicsShape.onAddCallback:
    for shape in curComponent.shapes:
      shape.setEntity curEntity

  PhysicsShape.onRemoveCallback:
    for shape in curComponent.shapes:
      shape.finaliseShape

  # Body

  template getData*(body: Body): BodyData = cast[BodyData](body.userData)
  template getEntity*(body: Body): EntityRef = body.getData.entity
  proc setEntity*(body: Body, entityRef: EntityRef) =
    if body.userData == nil:
      body.userData = alloc0(BodyDataObj.sizeOf)
    let data = body.getData
    data.entity = entityRef

  proc finaliseBody*(body: Body) =
    if body.userData != nil:
      body.getData.dealloc
    body.space.removeBody(body)
    body.destroy()

  PhysicsBody.onAdd:
    curComponent.setEntity curEntity

  PhysicsBody.onRemoveCallback:
    finaliseBody(curComponent.body)

  proc makeSimpleBody(bodyType: BodyType, mass, radius: float): Body =
    var body: Body
    case bodyType
    of BODY_TYPE_DYNAMIC:
      body = newBody(mass, momentForCircle(mass, 0.0, radius, vzero))
    of BODY_TYPE_KINEMATIC:
      body = newKinematicBody()
    of BODY_TYPE_STATIC:
      body = newStaticBody()
    # finish
    body

  template makeSimpleShape*(body: Body, radius: float, shapeKind: ShapeKind): Shape =
    var newShape: Shape
    case shapeKind
    of skCircle: newShape = physicsSpace.addShape(newCircleShape(body, radius, vzero))
    of skSquare: newShape = physicsSpace.addShape(newBoxShape(body, radius, radius, 0.0))
    of skPoly, skSegment: raise newException(ValueError, $shapeKind & " is not a simple shape")
    newShape

  proc calcBB*(verts: openarray[Vect]): tuple[lowVert, highVert: Vect] =
    for vert in verts:
      if vert.x < result.lowVert.x: result.lowVert.x = vert.x
      if vert.y < result.lowVert.y: result.lowVert.y = vert.y
      if vert.x > result.highVert.x: result.highVert.x = vert.x
      if vert.y > result.highVert.y: result.highVert.y = vert.y

  proc calcRadius*(verts: openarray[Vect]): float =
    let bb = verts.calcBB
    result = (bb.highVert - bb.lowVert).vlength

  template makeSegmentShape*(body: Body, a, b: Vect, radius: float): Shape =
    var newShape = physicsSpace.addShape(newSegmentShape(body, a, b, radius))
    newShape

  proc makePhysicsBody*(mass, radius: float, position = v(0, 0), velocity = v(0, 0)): PhysicsBody =
    let body = makeSimpleBody(BODY_TYPE_DYNAMIC, mass, radius)
    body.position = position
    body.velocity = velocity
    PhysicsBody(body: physicsSpace.addBody body)

template registerPhysConstructor*: untyped {.dirty.} =
  registerConstructor BodyTemplate, proc(entity: EntityRef, component: Component, master: EntityRef): seq[Component] =
    let pt = BodyTemplateRef(component).value
    result.add makePhysicsBody(pt.mass, pt.radius).makeContainer

  registerConstructor ShapeTemplate, proc(entity: EntityRef, component: Component, master: EntityRef): seq[Component] =
      let
        st = ShapeTemplateRef(component).value
        masterBody = master.fetchComponent PhysicsBody
        r = st.radius
      assert masterBody.valid
      var phys = PhysicsShape(shapes: @[makeSimpleShape(masterBody.body, r, st.kind)]) 
      result.add phys.makeContainer

when isMainModule:
  import polymers, sdl2, glbits/[modelrenderer, models], random, math, times
  const
    entOpts = dynamicSizeEntities()
    compOpts = dynamicSizeComponents()
    sysOpts = dynamicSizeSystem()
  defineECSChipmunk2D(compOpts, sysOpts)
  defineOpenGlRenders(compOpts, sysOpts)

  makeSystemOpts("updatePosition", [PhysicsBody, Position], sysOpts):
    all:
      let pos = item.physicsBody.body.position
      item.position.x = pos.x
      item.position.y = pos.y

  makeEcs(entOpts)
  commitSystems("run")
  registerPhysConstructor()

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
  glClearColor(0.0, 0.0, 0.0, 1.0)                  # Set background color to black and opaque
  glClearDepth(1.0)                                 # Set background depth to farthest

  # Set up graphics.
  var
    scale = 0.012
  let
    shaderProg = newModelRenderer()
    circleModelId = makeCircleModel(shaderProg, 12, vec4(1.0, 1.0, 1.0, 1.0), vec4(0.5, 0.5, 0.5, 1.0))
    circleModel = Model(modelId: circleModelId, scale: vec3(scale), col: vec4(1.0))
  circleModelId.setMaxInstanceCount(200_000)

  # Set up physics.
  physicsSpace.gravity = v(0.0, -1.1)
  physicsSpace.damping = 0.5
  var
    wb = makeSimpleBody(BODY_TYPE_STATIC, 1.0, 1.0)

  let
    wallRadius = 0.1
    leftWall = wb.makeSegmentShape(v(-1.0 - wallRadius, 1.0), v(-1.0 - wallRadius, -1.0), 0.1)
    rightWall = wb.makeSegmentShape(v(1.0 + wallRadius, 1.0), v(1.0 + wallRadius, -1.0), 0.1)
    topWall = wb.makeSegmentShape(v(-1.0, -1.0 - wallRadius), v(1.0, -1.0 - wallRadius), 0.1)
    bottomWall = wb.makeSegmentShape(v(-1.0, 1.0 + wallRadius), v(1.0, 1.0 + wallRadius), 0.1)

  var worldBody = physicsSpace.addBody wb

  template every(time: float, actions: untyped) =
    var lastTime {.global.} = cpuTime()
    block:
      let t = cpuTime()
      if t - lastTime >= time:
        lastTime = t
        actions

  var
    running = true
    evt = sdl2.defaultEvent

  let
    ents = 6000

    ball = @[
      tmplPosition(),
      ModelRef(fTypeId: Model.typeId, value: circleModel),
      tmplBodyTemplate(radius = scale, mass = 0.1),
      tmplShapeTemplate(radius = scale, kind = skCircle)]

  for i in 0 ..< ents:
    let
      ent = ball.construct()
      phys = ent.fetchComponent PhysicsBody
      speed = 0.1
    phys.body.position = v(rand -1.0 .. 1.0, rand -1.0 .. 1.0)
    phys.body.velocity = v(rand -speed .. speed, rand -speed .. speed)

  while running:
    # Capture events.
    while pollEvent(evt):
      if evt.kind == QuitEvent:
        running = false
        break

    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    run()
    const physUpdateSpeed = 1.0 / 60.0
    every(physUpdateSpeed): 
      physicsSpace.step(physUpdateSpeed)
    renderModels()
    
    # Double buffer.
    window.glSwapWindow()

