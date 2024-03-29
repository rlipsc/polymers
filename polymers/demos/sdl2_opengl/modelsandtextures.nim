## Demo of a model and texture rendering ECS.
## See also demos/particledemo.nim for an expanded version.
##
## This expects SDL2.dll to be in the current directory,
## available from here: https://www.libsdl.org/download-2.0.php

import polymorph, polymers, glbits, glbits/glrig, times

when not defined(release):
  const
    maxEnts = 150_000
    sysOpts = fixedSizeSystem(maxEnts)
else:
  const
    maxEnts = 1_000_000
    sysOpts = fixedSizeSystem(maxEnts)
const
  compOpts = fixedSizeComponents(maxEnts)
  entOpts = fixedSizeEntities(maxEnts, 5)
  dt = 1.0 / 60.0

defineOpenGlRenders(compOpts, sysOpts)

import sdl2, random, math

registerComponents compOpts:
  type
    Velocity = object
      vec: GLvectorf2
    VelCol = object
      startCol: GLvectorf4

template calcResponse(pos, source: GLvectorf2, sqrRadius, speed: GLfloat): GLvectorf2 =
  # Return a response vector when 'pos' and 'source' are within the squared difference, 'sqrRadius'.
  let
    diff = source - pos
    sDist = diff.sqrLen
  var r: GLvectorf2
  if sDist <= sqrRadius:
    let
      sourceForce = diff.asLength speed
      force = sourceForce * (1.0 / max(sDist, 0.02))
    r = force * dt
  r

makeSystemOpts "movement", [pos: Position, vel: own Velocity], sysOpts:
  fields:
    drag = 0.004

  all:
    const
      left = vec2(1.0, 0.0)
      right = vec2(-1.0, 0.0)
      top = vec2(0.0, 1.0)
      bottom = vec2(0.0, -1.0)

    var curVec = vel.vec

    pos.x += curVec.x
    pos.y += curVec.y
    vel.vec = curVec - (curVec * sys.drag)

    if pos.x < -1.0:
      pos.x = -1.0
      vel.vec = curVec.reflect(left)
    elif pos.x > 1.0:
      pos.x = 1.0
      vel.vec = curVec.reflect(right)
    elif pos.y < -1.0:
      pos.y = -1.0
      vel.vec = curVec.reflect(top)
    elif pos.y > 1.0:
      pos.y = 1.0
      vel.vec = curVec.reflect(bottom)    

makeSystemOpts "applyForce", [Position, Velocity], sysOpts:
  # Apply a speed to velocity within a distance.
  fields:
    forcePos: GLvectorf2
    lastPos: GLvectorf2
    force -> GLfloat = -0.07 * dt
    radius = 0.4
    sqrRadius -> GLfloat = sys.radius * sys.radius
  start:
    sys.paused = sys.forcePos == sys.lastPos
  
  stream maxEnts div 2:
    item.velocity.vec += calcResponse(
      vec2(item.position.x, item.position.y),
      sys.forcePos,
      sys.sqrRadius,
      sys.force * rand(0.25 .. 2.0)
    )
  sys.lastPos = sys.forcePos

makeSystemOpts "velCol", [VelCol, Velocity, Model], sysOpts:
  # Map Velocity to Model.col.
  init: sys.paused = true # Start paused.
  fields:
    changedModels: bool
    scale = 800.0  # Arbitrary scale for expected velocities.
  added:
    item.velCol.startCol = item.model.col
  start:
    # Reverse changes to Model when paused.
    if sys.paused and sys.changedModels:
      sys.changedModels = false
      for row in sys.groups:
        row.model.col = row.velCol.startCol

  stream maxEnts div 4:
    let
      startCol = item.velCol.startCol
      last = item.velocity.vec
      vel = item.velocity.vec * sys.scale
      delta = vel - last
      colVel = vec4(0.4) * vec4(delta.x, delta.y, 1, 1)
    item.model.col = mix(startCol, colVel, delta.length / sys.scale)

  sys.changedModels = true

makeEcsCommit("run", entOpts)

proc createFlowerTexture(texture: var GLTexture, w, h = 120) =
  # Draws a flower shape on a texture.
  texture.initTexture(w, h)

  proc dist(x1, y1, x2, y2: float): float =
    let
      diffX = x2 - x1
      diffY = y2 - y1
    result = sqrt((diffX * diffX) + (diffY * diffY))

  let
    centre = [texture.width / 2, texture.height / 2]
    maxDist = dist(centre[0], centre[1], texture.width.float, texture.height.float)
    spokes = 5.0

  for y in 0 ..< texture.height:
    for x in 0 ..< texture.width:
      let
        ti = texture.index(x, y)
        diff = [centre[0] - x.float, centre[1] - y.float]
        d = sqrt((diff[0] * diff[0]) + (diff[1] * diff[1]))
        angle = diff[1].arcTan2 diff[0]
        spikeMask = cos(spokes * angle)
        normD = d / maxDist
        edgeDist = smootherStep(1.0, 0.0, normD)
      texture.data[ti] = vec4(edgeDist, edgeDist, edgeDist,
        smootherStep(0.0, spikeMask, edgeDist))

initSdlOpenGl(1024, 768)

let
  shaderProg = newModelRenderer()
  circleModel = shaderProg.makeCircleModel(8, vec4(1.0), vec4(0.3, 0.3, 0.3, 0.7), maxInstances = maxEnts)
  squareModel = shaderProg.makeCircleModel(4, vec4(1.0), vec4(0.3, 0.3, 0.3, 1.0), maxInstances = maxEnts)
  ballTexture = newTextureId(max = maxEnts)

var ballTextureData: GLTexture
ballTextureData.createFlowerTexture()
ballTexture.update(ballTextureData)

echo "Particles: ", maxEnts

let
  posRange = -0.9 .. 0.9
  fEnts = (maxEnts - 1).float
  squares = int(fEnts * 0.05)
  circles = int(fEnts * 0.945)
  flowers = int(fEnts * 0.005)

for i in 0 ..< squares:
  let speed = rand(0.02 .. 0.08) * dt
  discard newEntityWith(
    Position(x: rand(posRange), y: rand(posRange), z: 0.1),
    Velocity(vec: vec2(rand(-speed..speed), rand(-speed..speed))),
    Model(modelId: squareModel, angle: rand(TAU),
      scale: vec3(0.01), col: vec4(rand 0.5..1.0, rand 1.0, 1.0, 1.0)),
  )
for i in 0 ..< circles:
  let
    speed = rand(0.05 .. 0.08) * dt
    pCol = vec4(1.0, 0.85, rand 0.05, rand 0.4 .. 0.6).brighten rand(0.95 .. 1.0)
  discard newEntityWith(
    Position(x: rand(posRange), y: rand(posRange), z: -0.5),
    Velocity(vec: vec2(rand(-speed..speed), rand(-speed..speed))), 
    Model(modelId: circleModel, angle: rand(TAU),
      scale: vec3(0.0038), col: pCol),
    VelCol()
  )
for i in 0 ..< flowers:
  let speed = rand(0.01 .. 0.03) * dt
  discard newEntityWith(
    Position(x: rand(posRange), y: rand(posRange), z: -0.9),
    Velocity(vec: vec2(rand(-speed..speed), rand(-speed..speed))),
    Texture(textureId: ballTexture, angle: rand(TAU),
      scale: vec2(0.02), col: vec4(rand 1.0, rand 1.0, rand 1.0, 1.0)),
  )

func activeStr(isPaused: bool): string =
  if isPaused: "off" else: "on"

proc main =
  when defined(showFps):
    var
      lastFrame = epochTime()
      frameCount: int

  var
    lastKeyPress: float

  echo "Press 1 to toggle mouse repulsion"
  echo "Press 2 to toggle velocity colouring"

  # Render loop.
  pollEvents:

    if mouseInfo.changed:
      # Update systems with mouse position.
      sysApplyForce.forcePos = mouseInfo.gl
    
    let
      curTime = epochTime()

    if curTime - lastKeyPress > 0.5:
      # Let user toggle mouse interaction.

      if keyStates.pressed(SDL_SCANCODE_1):
        lastKeyPress = curTime
        sysApplyForce.disabled = not sysApplyForce.disabled
        echo "React to mouse: ", sysApplyForce.disabled.activeStr

      if keyStates.pressed(SDL_SCANCODE_2):
        lastKeyPress = curTime
        sysVelCol.paused = not sysVelCol.paused
        echo "Velocity colouring: ", sysVelCol.paused.activeStr

    when defined(showFps):
      frameCount += 1

      if curTime - lastFrame >= 1.0:
        lastFrame = curTime
        echo "FPS: ", frameCount
        frameCount = 0

    # Execute systems.
    run()

    # Render.
    doubleBuffer:
      renderActiveModels()
      renderActiveTextures()
  
main()
