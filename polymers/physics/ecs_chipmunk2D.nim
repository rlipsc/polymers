
## Polymorph ECS component for the Chipmunk physics engine.
##   Chipmunk Physics:
##     https://chipmunk-physics.net/
##     https://github.com/slembcke/Chipmunk2D
##     Documentation:
##     https://chipmunk-physics.net/release/ChipmunkLatest-Docs/
##   Nim wrapper: https://github.com/oprypin/nim-chipmunk  

import polymorph

template defineECSChipmunk2D*(compOpts: ECSCompOptions) {.dirty.} =
  ## Defines components for managing Chipmunk2D physics bodies and shapes.
  ## No systems are defined.
  import chipmunk
  when not declared(cos) or not declared(sin):
    {.fatal: "ecs_chipmunk2D requires the stdlib math module to be imported".}

  export chipmunk

  type
    ShapeKind* = enum skCircle, skSquare, skPoly, skSegment
    ShapeDataObj* = object
      entity*: EntityRef
      kind*: ShapeKind
      offset*: Vect
      offsetAngle*: float
      offsetDist*: float
    ShapeData* = ptr ShapeDataObj
    BodyDataObj* = object
      entity*: EntityRef
    BodyData* = ptr BodyDataObj
    ShapeItem* = object
      shape*: Shape
      position*: Vect

  registerComponents(compOpts):
    type
      PhysicsBody* = object
        body*: Body
      PhysicsShape* = object
        parent*: EntityRef  # TODO
        shapes*: seq[ShapeItem]

      ## When constructed this component gets replaced by a PhysicsBody.
      BodyTemplate* = object
        radius*: float
        mass*, angle*: float
        bodyType*: BodyType
        moment*: float
      ## When constructed this component gets replaced by a PhysicsShape.
      ShapeTemplate* = object
        parent*: EntityRef  # TODO
        filter*: chipmunk.ShapeFilter
        collisionType*: CollisionType
        radius*: float
        friction*: float
        case kind*: ShapeKind
        of skCircle, skSquare:
          discard
        of skPoly:
          polyVerts*: seq[Vect]
          transform: Transform
        of skSegment:
          a*, b*: Vect
        offset*: Vect
        elasticity*: float

  # Set up Chipmunk space.
  var physicsSpace* = newSpace()

  # Shape
  template getData*(shape: Shape): ShapeData = cast[ShapeData](shape.userData)
  template getEntity*(shape: Shape): EntityRef = shape.getData.entity
  template getKind*(shape: Shape): ShapeKind = shape.getData.kind
  template getOffset*(shape: Shape): Vect = shape.getData.offset

  proc calcOffset*(shape: Shape): Vect =
    let
      offset = shape.getData.offset
      bodyPos = shape.body.position
      bodyAngle = shape.body.angle
      c = cos bodyAngle
      s = sin bodyAngle
      newX = c * offset.x - s * offset.y
      rotOffset = v(newX, c * offset.y + s * offset.x)
    v(bodyPos.x + rotOffset.x, bodyPos.y + rotOffset.y)

  proc setEntity*(shape: var Shape, entityRef: EntityRef) =
    let curData = cast[ShapeData](shape.userData)
    if curData == nil:
      var data = cast[ShapeData](alloc0(ShapeDataObj.sizeOf))
      data.entity = entityRef
      shape.userData = cast[DataPointer](data)
    else:
      curData.entity = entityRef

  proc setData*(shape: var Shape, entityRef: EntityRef, shapeKind: ShapeKind, offset: Vect)  =
    let curData = cast[ShapeData](shape.userData)
    if curData == nil:
      var data = cast[ShapeData](alloc0(ShapeDataObj.sizeOf))
      data.entity = entityRef
      data.kind = shapeKind
      data.offset = offset
      #echo "Setting offset to ", offset
      data.offsetAngle = offset.vToAngle
      data.offsetDist = offset.vLength
      shape.userData = cast[DataPointer](data)
    else:
      #echo "Updating offset to ", offset
      curData.entity = entityRef
      curData.kind = shapeKind
      curData.offset = offset

  proc getOffsetCM*(shape: Shape, kind: ShapeKind): Vect =
    ## Retrieve the offset from Chipmunk.
    case kind
    of skCircle: result = cast[CircleShape](shape).offset
    of skSquare, skPoly, skSegment: raise newException(ValueError, "Cannot get offset for PolyShapes")

  proc finaliseShape*(shape: Shape) =
    var shapeData = shape.getData()
    if shapeData != nil:
      shapeData.dealloc
      physicsSpace.removeShape(shape)
      shape.destroy()

  PhysicsShape.onAdd:
    for shapeItem in curComponent.shapes.mitems:
      let data = shapeItem.shape.getData
      if data == nil:
        debugEcho "Setting shape entity but no offset or kind info"
        shapeItem.shape.setEntity curEntity
      elif data.entity == NO_ENTITY_REF:
        data.entity = curEntity

  PhysicsShape.onRemoveCallback:
    ## Free shape data.
    for shapeItem in curComponent.shapes:
      shapeItem.shape.finaliseShape
    curComponent.shapes.setLen 0


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
    curComponent.body.setEntity curEntity

  PhysicsBody.onRemoveCallback:
    # Note: this makes it unwise to share physics bodies between entities.
    finaliseBody(curComponent.body)

  proc newBody*(bodyType: BodyType, mass, radius: float, moment: float): Body =
    var body: Body
    case bodyType
    of BODY_TYPE_DYNAMIC:
      body = newBody(mass, moment)
    of BODY_TYPE_KINEMATIC:
      body = newKinematicBody()
    of BODY_TYPE_STATIC:
      body = newStaticBody()
    body

  proc momentForPoly*(mass: float, vertices: openarray[Vect], offset = v(0.0, 0.0), radius = 0.0): float =
    ## Convenience wrapper for momentForPoly.
    momentForPoly(mass, vertices.len.cint, vertices[0].unsafeAddr, offset, radius)

  proc momentForCircle*(mass: float, radius: float, offset = v(0.0, 0.0)): float =
    ## Convenience wrapper for momentForCircle that assumes a filled circle.
    momentForCircle(mass, 0.0, radius, offset)

  proc makeSimpleShape*(body: Body, entity: EntityRef, radius: float, shapeKind: ShapeKind, offset: Vect = vzero): Shape =
    ## Create a simple physics body.
    ## If `entity` is `NO_ENTITY_REF` the entity will be updated in the onAdd hook.
    var newShape: Shape
    case shapeKind
    of skCircle: newShape = physicsSpace.addShape(newCircleShape(body, radius, offset))
    of skSquare: newShape = physicsSpace.addShape(newBoxShape(body, radius, radius, 0.0))
    of skPoly, skSegment: raise newException(ValueError, $shapeKind & " is not a simple shape")
    newShape.setData entity, shapeKind, offset
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

  proc radius*(shape: Shape): float =
    assert shape != nil
    let sk = shape.getKind
    case sk
    of skCircle:
      result = cast[CircleShape](shape).radius
    of skSquare, skPoly:
      result = cast[PolyShape](shape).radius
    of skSegment:
      discard

  template makeSegmentShape*(body: Body, entity: EntityRef, a, b: Vect, radius: float): Shape =
    var newShape = physicsSpace.addShape(newSegmentShape(body, a, b, radius))
    newShape.setData entity, skSegment, v(0.0, 0.0)
    newShape

  template makePolyShape*(body: Body, entity: EntityRef, verts: seq[Vect], radius: float, transform = default(Transform)): Shape =
    ## When 'transform' is set a convex hull will be calculated from the vertices.
    ## If 'transform' is not supplied vertices must be provided with a counter-clockwise winding.
    ## 
    ## Radius increases the size of the shape.
    var newShape: Shape
    if transform == default(Transform):
      newShape = physicsSpace.addShape(newPolyShape(body, verts.len.cint, verts[0].unsafeAddr, radius))
    else:
      newShape = physicsSpace.addShape(newPolyShape(body, verts.len.cint, verts[0].unsafeAddr, transform, radius))
    newShape.setData entity, skPoly, v(0.0, 0.0)
    newShape

  proc makePhysicsBody*(bt: BodyTemplate, position = v(0, 0), velocity = v(0, 0)): PhysicsBody =
    ## Initialise a Chipmunk Body object from BodyTemplate and return it in a PhysicsBody.
    assert bt.mass != 0.0, "Mass must be non-zero"
    let moment =
      if bt.moment == 0.0: momentForCircle(bt.mass, 0.0, bt.radius, v(0.0, 0.0))
      else: bt.moment
    let body = physicsSpace.addBody(newBody(bt.bodyType, bt.mass, bt.radius, moment))
    body.position = position
    body.velocity = velocity
    body.angle = bt.angle
    PhysicsBody(body: body)

  proc makePhysicsShape*(st: ShapeTemplate, entity: EntityRef, body: Body): PhysicsShape =
    ## Initialise a Chipmunk Shape object from ShapeTemplate and return it in a PhysicsShape.
    ## 
    ## Requires an initialised Body object to attach the shape to.
    assert body.mass != 0.0, "Mass must be non-zero"
    let shape =
      case st.kind
      of skCircle, skSquare:
        let r = st.radius
        makeSimpleShape(body, entity, r, st.kind, st.offset)
      of skPoly:
        makePolyShape(body, entity, st.polyVerts, st.radius)
      of skSegment:
        makeSegmentShape(body, entity, st.a, st.b, st.radius)
    
    shape.filter = st.filter
    shape.collisionType = st.collisionType
    shape.elasticity = st.elasticity
    shape.friction = st.friction

    PhysicsShape(shapes: @[ShapeItem(shape: shape)])

  # Include constructor registration as soon as makeEcs() has completed.
  onEcsBuilt:
    registerConstructor BodyTemplate, proc(entity: EntityRef, component: Component, context: EntityRef): seq[Component] =
      # Replaces BodyTemplate with PhysicsBody during construction.
      let bt = BodyTemplateRef(component).value
      result.add bt.makePhysicsBody.makeContainer

    registerConstructor ShapeTemplate, proc(entity: EntityRef, component: Component, context: EntityRef): seq[Component] =
      # Replaces ShapeTemplate with PhysicsShape during construction.
      let
        st = ShapeTemplateRef(component).value
        contextBody = context.fetch PhysicsBody

      assert contextBody.valid, "Constructor for ShapeTemplate expects " &
        "context/first entity to have a PhysicsBody"

      let body = contextBody.body

      result.add st.makePhysicsShape(entity, body)
