# Simple game using opengl.
# This expects SDL2.dll to be in the current directory,
# available from here: https://www.libsdl.org/download-2.0.php
# and the Nim SDL2 wrapper: https://github.com/nim-lang/sdl2

import polymorph, polymers, glbits, glbits/modelrenderer, opengl, sdl2
import random, math, times

randomize()

func dot(v1, v2: GLvectorf2): float = v1[0] * v2[0] + v1[1] * v2[1]

func reflect(incident, normal: GLvectorf2): GLvectorf2 =
  let d = 2.0 * dot(normal, incident)
  result = vec2(incident[0] - d * normal[0], incident[1] - d * normal[1])


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
glEnable(GL_BLEND)                                # Enable alpha channel
glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

# Create models and set up rendering.

const
  # Triangle vertices.
  vTriangle = [vec3(-1.0, -1.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(-1.0, 1.0, 0.0)]
  
  # Shade the vertices so the back end fades out.
  vCols = [vec4(0.5, 0.5, 0.5, 0.5), vec4(1.0, 1.0, 1.0, 1.0), vec4(0.5, 0.5, 0.5, 0.5)]

proc genModel(triangles: int): tuple[model: seq[GLvectorf3], cols: seq[Glvectorf4]] =
  # Create a model using some randomised triangles and mirror across X-axis.
  
  let
    rStart = vTriangle.len * triangles
    verts = rStart * 2
  
  result.model.setLen verts
  result.cols.setLen verts

  for t in 0 ..< triangles:
    let
      triAngle = rand TAU
      tSize = rand 0.1 .. 0.7

      lTri = vTriangle.rotated2d(triAngle)
      rTri = vTriangle.rotated2d(TAU - triAngle)
      xo = rand -0.9 .. 0.9
      yo = rand 0.1 .. 0.6

      lStart = t * vTriangle.len

    for vi, v in lTri:
      let vIdx = lStart + vi
      result.model[vIdx] = vec3(v.x + xo, v.y - yo, v.z) * tSize
    
    result.cols[lStart ..< lStart + 3] = vCols

    for vi, v in rTri:
      let vIdx = rStart + lStart + vi
      result.model[vIdx] = vec3(v.x + xo, v.y + yo, v.z) * tSize
    
    result.cols[rStart + lStart ..< rStart + lStart + 3] = vCols

let
  shaderProg = newModelRenderer()
  bulletModel = newModel(shaderProg, vTriangle, vCols)

bulletModel.setMaxInstanceCount(200_000)

var
  shipModels: array[10, ModelId]

for i in 0 ..< shipModels.len:
  let modelData = genModel(10)
  shipModels[i] = newModel(shaderProg, modelData.model, modelData.cols)
  shipModels[i].setMaxInstanceCount(200_000)


# Misc definitions.

type MButtons = tuple[left, right: bool]

var
  level = 0


# Define ECS.

const
  compOpts = dynamicSizeComponents()
  sysOpts = dynamicSizeSystem()
  entOpts = dynamicSizeEntities()
  # Fixed time step.
  dt = 1.0 / 60.0

registerComponents(compOpts):
  type
    Position = object
      x, y, z: float
    Velocity = object
      x, y: GLfloat
    Bounce = object
      dust: bool
    Weapon = object
      active: bool
      lastFired: float
      fireRate: float
      fireSpeed: float
      bullet: ComponentList
    Health = object
      amount: float
    Player = object
    PlayerDamage = object
      amount: float
    Enemy = object
    DamageEnemy = object
      amount: float
    Seek = object
      speed: float
    PlayerKilled = object
    PlayerKillable = object
    ExplodeOnDeath = object
    ShrinkAway = object
      startScale: float
    DeathTimer = object
      start, duration: float
    ReadControls = object

defineOpenGLComponents(compOpts, Position)
defineKilling(compOpts)
defineGridMap(0.08, Position, compOpts, sysOpts)

func colRange(a, b: SomeFloat): auto = a.float32 .. b.float32
func colRange(a: SomeFloat): auto = 0.float32 .. a.float32

onEcsBuilt:
  proc particles(position: GLvectorf2, angle, spread: float, model: ModelInstance, scale: float, particleCount: int,
      speed: Slice[float], duration = 1.0, col = [colRange(0.8, 1.0), colRange(0.8), colRange(0.0, 0.0)]) =
    
    # Copy model object so we can edit it.
    var
      pModel = model.access
    
    # Resize model according to scale.
    pModel.scale = vec3(pModel.scale[0] * scale)

    for i in 0 .. particleCount:
      let
        particleSpeed = rand speed.a * dt .. speed.b * dt
        fireAngle = rand angle - spread .. angle + spread
        r = rand col[0]
        g = rand col[1]
        b = rand col[2]
        light = 1.0 - abs(fireAngle - angle) / spread
      pModel.angle = rand TAU
      pModel.col = vec4(r * light, g * light, b * light, light)

      discard newEntityWith(
        Position(x: position[0], y: position[1]),
        Velocity(x: particleSpeed * cos fireAngle, y: particleSpeed * sin fireAngle),
        Bounce(dust: false),
        pModel,
        KillAfter(duration: duration),
        ShrinkAway()
        )

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  # This system handles momentum and drag.
  all:
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y
    item.velocity.x *= 0.99
    item.velocity.y *= 0.99

makeSystemOpts("seekPlayer", [Seek, Position, Velocity, Model], sysOpts):
  # Move towards player.
  fields:
    player: EntityRef
  start:
    # Don't seek the player when they're dead.
    if sys.player.has PlayerKilled: sys.paused = true 
    else: sys.paused = false

  let
    playerPos = sys.player.fetch Position

  all:
    let
      dx = playerPos.x - item.position.x
      dy = playerPos.y - item.position.y
      angle = arcTan2(dy, dx)
      speed = item.seek.speed * dt
      desiredVel = (x: speed * cos(angle), y: speed * sin(angle))
    
    item.velocity.x += desiredVel.x - item.velocity.x
    item.velocity.y += desiredVel.y - item.velocity.y
    item.model.angle = angle

template performDamage(damageType: typedesc): untyped =
  # Both enemies and players use similar code for damage,
  # only the fetch type for damage differs.
  # This template uses `entity` and `item` from the calling system.
  let
    curX = item.position.x
    curY = item.position.y
  var r: bool
  for entPos in queryGridPrecise(curX, curY, 0.05):
    let
      ent = entPos.entity
    
    if ent != entity and not(ent.has Killed):
      # A collision has occurred.
      let
        damage = ent.fetch damageType
      
      if damage.valid:
        item.health.amount -= damage.amount
        
        if item.health.amount <= 0:
          r = true
        else:
          # If not dead, apply velocity as a push.
          let
            bulletVel = ent.fetch Velocity
          
          if bulletVel.valid:
            let entVel = entity.fetch Velocity
            if entVel.valid:
              entVel.x += bulletVel.x
              entVel.y += bulletVel.y

        # Explosion as damaging entity (e.g., bullet) is removed.
        particles(
          vec2(curX, curY),
          0.0,
          TAU,
          item.model,
          0.2,
          particleCount = 100,
          speed = 0.2..0.3,
          col = [colRange(0.8, 1.0), colRange(0.2), colRange(0.0)],
          duration = 2.0
        )

        # Kill damaging entity
        ent.addIfMissing Killed()
        break
  r

makeSystemOpts("takeDamageEnemy", [PlayerKillable, Health, GridMap, Position, Model], sysOpts):
  all:
    if performDamage(DamageEnemy):
      item.entity.addIfMissing Killed()

makeSystemOpts("takeDamagePlayer", [Player, Health, GridMap, Position, Model], sysOpts):
  all:
    if performDamage(PlayerDamage):
      item.entity.addIfMissing PlayerKilled()

makeSystemOpts("playerKilled", [PlayerKilled, ReadControls, Position, Model], sysOpts):
  all:
    echo "You died!"
    
    # Explode player.
    particles(
      vec2(item.position.x, item.position.y),
      0.0,
      TAU,
      item.model,
      scale = 0.35,
      particleCount = 5_000,
      speed = 0.0..1.6,
      duration = 4.5)

    # We don't want to actually delete the player entity,
    # so we hide the ship by setting the model to transparent.
    item.model.col[3] = 0.0

    entity.addIfMissing DeathTimer(start: cpuTime(), duration: 5.0)

  finish:
    sys.remove ReadControls

makeSystemOpts("controls", [ReadControls, Position, Velocity, Model, Weapon], sysOpts):
  # Handle player input.
  fields:
    mousePos: GLvectorf2
  
  type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
  const keyClear: uint8 = 0

  proc pressed(keyStates: KeyCodes, sc: Scancode): bool =
    result = keyStates[sc.int] > keyClear
  
  var
    keyStates: KeyCodes = getKeyboardState()
  
  all:
    let
      dx = sys.mousePos[0] - item.position.x
      dy = sys.mousePos[1] - item.position.y
      angle = arctan2(dy, dx)

      # Thruster position.
      tAngle = angle + PI
      tx = item.position.x + item.model.scale[0] * cos(tAngle)
      ty = item.position.y + item.model.scale[0] * sin(tAngle)

      model = item.model

    # Point the model towards the mouse coordinates.
    model.angle = angle

    # Movement

    let
      thrustSpeed = 0.005 * dt
      strafeSpeed = 0.001 * dt
      strafeAngle = angle + 90.0.degToRad
      bigThrust = (scale: 0.2, speed: 0.2..0.3)
      smallThrust = (scale: bigThrust.scale * 0.5, speed: 0.02..0.06)

    if keyStates.pressed(SDL_SCANCODE_W):
      item.velocity.x += thrustSpeed * cos(angle)
      item.velocity.y += thrustSpeed * sin(angle)
      particles(vec2(tx, ty), angle + PI, 30.0.degToRad, model, bigThrust.scale, 50, bigThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_A):
      item.velocity.x += strafeSpeed * cos(strafeAngle)
      item.velocity.y += strafeSpeed * sin(strafeAngle)
      particles(vec2(tx, ty), strafeAngle + PI, 60.0.degToRad, model, smallThrust.scale, 20, smallThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_D):
      item.velocity.x -= strafeSpeed * cos(strafeAngle)
      item.velocity.y -= strafeSpeed * sin(strafeAngle)
      particles(vec2(tx, ty), strafeAngle, 60.0.degToRad, model, smallThrust.scale, 20, smallThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_S):
      item.velocity.x -= thrustSpeed * cos(angle)
      item.velocity.y -= thrustSpeed * sin(angle)
      particles(vec2(tx, ty), angle, 30.0.degToRad, model, smallThrust.scale, 50, smallThrust.speed)

makeSystemOpts("controlWeapon", [ReadControls, Weapon], sysOpts):
  fields:
    mouseButtons: MButtons
  
  let
    curTime = cpuTime()
  
  all:
    if sys.mouseButtons.left and curTime - item.weapon.lastFired >= item.weapon.fireRate:
      item.weapon.active = true
    else:
      item.weapon.active = false

makeSystemOpts("fireWeapon", [Weapon, Position, Model], sysOpts):
  # Handles constructing bullets from Weapon.
  let
    curTime = cpuTime()

  all:
    if item.weapon.active and curTime - item.weapon.lastFired >= item.weapon.fireRate:
      # Fire!

      item.weapon.lastFired = curTime

      let
        bullet = item.weapon.bullet.construct # Build bullet entity.
        pos = bullet.fetch Position
        vel = bullet.fetch Velocity
        model = bullet.fetch Model
        angle = item.model.angle

      if pos.valid:
        pos.x = item.position.x
        pos.y = item.position.y
      
      if vel.valid:
        let
          bulletSpeed = item.weapon.fireSpeed
        
        vel.x = bulletSpeed * cos(angle)
        vel.y = bulletSpeed * sin(angle)
      
      if model.valid:
        model.angle = angle

makeSystemOpts("explosion", [ExplodeOnDeath, Killed, Position, Model], sysOpts):
  # Create some particles using the model that's being killed.
  all:
    particles(
      vec2(item.position.x, item.position.y),
      0.0,
      TAU,
      item.model,
      scale = 0.5,
      particleCount = 50,
      speed = 0.2..0.3,
      col = [
        colRange(item.model.col.r),
        colRange(item.model.col.g),
        colRange(item.model.col.b),
        ])

makeSystemOpts("wallPhysics", [Position, Velocity, Model, Bounce], sysOpts):
  # This system handles bouncing off edges.
  all:
    const
      left = vec2(1.0, 0.0)
      right = vec2(-1.0, 0.0)
      top = vec2(0.0, 1.0)
      bottom = vec2(0.0, -1.0)
      dustScale = 0.3
      
    let
      curVel = vec2(item.velocity.x, item.velocity.y)
      col = item.model.col
      doDust = item.bounce.dust
    
    template dust(vec: GLvectorf2): untyped =
      if doDust:
        particles(
          vec2(item.position.x, item.position.y),
          arctan2(vec[1], vec[0]),
          30.0.degToRad,
          item.model,
          dustScale,
          particleCount = 100,
          speed = 0.2..0.3,
          col = [
            colRange(col[0] * 0.8, col[0]),
            colRange(col[1] * 0.8, col[1]),
            colRange(col[2] * 0.8, col[2])
          ],
          duration = 2.0
        )

    if item.position.x < -1.0:
      let r = reflect(curVel, left)
      item.position.x = -1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])
      dust(left)

    elif item.position.x > 1.0:
      let r = reflect(curVel, right)
      item.position.x = 1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])
      dust(right)

    if item.position.y < -1.0:
      let r = reflect(curVel, top)
      item.position.y = -1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])
      dust(top)

    elif item.position.y > 1.0:
      let r = reflect(curVel, bottom)
      item.position.y = 1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])
      dust(bottom)

makeSystemOpts("shrinkAway", [ShrinkAway, Model, KillAfter], sysOpts):
  added:
    item.shrinkAway.startScale = item.model.scale[0]
  
  let
    curTime = cpuTime()
  
  all:
    let normTime = 1.0 - ((curTime - item.killAfter.startTime) / item.killAfter.duration)
    item.model.scale = vec3(item.shrinkAway.startScale * normTime)

makeSystemOpts("killEnemies", [Enemy], sysOpts):
  # This system nukes all the enemies, then pauses itself.
  # Used to reset the game if the player dies.
  # The sys.count for this system can also be used to track the number
  # of Enemy entities.
  # Note: this is placed after effect systems that use Killed such as
  # "explosion", as we don't want to trigger death effects on enemies
  # when resetting the level.
  init:
    sys.paused = true
  all:
    entity.addIfMissing Killed()
  sys.paused = true

makeSystem("restartGame", [PlayerKilled, DeathTimer, Position, Model, Health]):
  all:
    if cpuTime() - item.deathTimer.start > 5.0:
      level = 0

      # Delete enemies.
      sysKillEnemies.paused = false

      # Reset player state.
      item.model.col[3] = 1.0
      item.health.amount = 1.0
      item.position.x = 0.0
      item.position.y = 0.0

      entity.add ReadControls()
      entity.remove PlayerKilled, DeathTimer

# Delete entities with the `Killed` component.
defineKillingSystems(sysOpts)

# Update GPU for rendering.
defineOpenGLUpdateSystems(sysOpts, Position)

# Generate ECS.
makeEcs(entOpts)
commitSystems("run")

#-------------------


# Set up background texture.

proc paintStars(texture: var GLTexture, stars: int) =
  # Draw stars and planets onto the texture.

  let
    (w, h) = (texture.width, texture.height)
  
  for i in 0 ..< stars:
    let
      ti = texture.index(rand w, rand h)
      brightness = rand 0.001 .. 0.8
      colRange = 0.6 .. 1.0
    texture.data[ti] = vec4(
      rand(colRange) * brightness,
      rand(colRange) * brightness,
      rand(colRange) * brightness,
      1.0)

proc paintPlanet(texture: var GLtexture, cx, cy, radius: int) =
  let
    (w, h) = (texture.width, texture.height)
    rSquared = radius * radius
    planetBrightness = 0.01 .. 0.3
    (r, g, b) = (rand planetBrightness, rand planetBrightness, rand planetBrightness)

  for y in max(0, cy - radius) .. min(h, cy + radius):
    for x in max(0, cx - radius) .. min(w, cx + radius):
      let
        diff = (x: cx - x, y: cy - y)
        sqDist = diff.x * diff.x + diff.y * diff.y

      if sqDist < rSquared:
        let
          ti = texture.index(x, y)
          dist = sqDist.float.sqrt
          normD = dist / radius.float
          roughness = rand(0.2 .. 1.0)
          edgeDist = smootherStep(1.0, 0.0, normD) * roughness

        texture.data[ti] = vec4(
          edgeDist * r,
          edgeDist * g,
          edgeDist * b,
          1.0
        )

proc paintBackground(texture: var GLTexture) =
  let
    stars = 10_000
    planets = 3
    (w, h) = (texture.width, texture.height)

  texture.clearTexture
  texture.paintStars(stars)

  for i in 0 ..< planets:
    let radius = max(2, rand(w.float * 0.01 .. w.float * 0.25)).int
    texture.paintPlanet(rand w, rand h, radius)

let backgroundTex = newTextureId(max = 1)
var backgroundImage: GLTexture

backgroundImage.initTexture(screenWidth, screenHeight)

backgroundImage.paintBackground
backgroundTex.update(backgroundImage)


# Set up game elements.

proc newPlayer(playerScale: GLvectorf3): EntityRef =
  newEntityWith(
    Model(modelId: shipModels[0], scale: playerScale, col: vec4(1.0, 0.0, 0.0, 1.0)),
    Position(),
    Velocity(),
    Bounce(dust: true),
    ReadControls(),
    Weapon(
      fireRate: 0.2,
      fireSpeed: 1.0 * dt,
      bullet: cl(
        Position(),
        Velocity(),
        Model(
          modelId: bulletModel,
          scale: vec3(0.02),
          col: vec4(1.0, 1.0, 0.0, 1.0)
        ),
        Bounce(dust: true),
        DamageEnemy(amount: 1.0),
        GridMap(),
        KillAfter(duration: 1.0),
        ExplodeOnDeath()
      )
    ),
    Health(amount: 1.0),
    Player(),
    GridMap()
  )

proc createLevel(level: int, playerPos: GLvectorf2, clearArea: float) =
  # Generate enemies according to level.
  
  let
    # Every X levels fire delay halves and health doubles.
    levelScaling = 4.0
    levelModifier = levelScaling / level.float

  for i in 0 ..< level * 10:
    let
      enemySize = 0.03
      extent = 0.95
      px = playerPos.x
      py = playerPos.y
    var
      pos = Position(x: rand(-extent..extent), y: rand(-extent..extent), z: 0.0)

    # Make sure nothing spawns on the player.
    if pos.x in px - clearArea .. px + clearArea and
      pos.y in py - clearArea .. py + clearArea:
        if px > -1.0 + clearArea:
          pos.x = rand -0.99 .. px - clearArea
        else:
          pos.x = rand px + clearArea .. 0.99
        
        if py > -1.0 + clearArea:
          pos.y = rand -0.99 .. py + clearArea
        else:
          pos.y = rand py + clearArea .. 0.99

    let
      enemyCol = vec4(rand 1.0, rand 1.0, rand 1.0, 1.0)

      enemy = newEntityWith(
        pos,
        Velocity(),
        Model(
          modelId: shipModels[rand 1 .. shipModels.len - 1],
          scale: vec3(enemySize),
          angle: rand(TAU),
          col: enemyCol
        ),
        Bounce(dust: true),
        Enemy(),
        Health(amount: 1.0 / levelModifier),
        GridMap(),
        PlayerDamage(amount: 1.0),
        Seek(speed: rand 0.01 .. 0.03),
        PlayerKillable(),
        ExplodeOnDeath()
      )

    if level > 1 and rand(1.0) < 0.1:
      var
        bullet = cl(
          Model(
            modelId: bulletModel,
            scale: vec3(0.015),
            col: vec4(0.5, 1.0, 1.0, 1.0)
          ),
          Position(),
          Velocity(),
          Bounce(dust: true),
          PlayerDamage(amount: 0.1),
          GridMap(),
          KillAfter(duration: 1.0),
          Health(amount: 0.01),
          Enemy(),
          PlayerKillable()
        )
      
      if level > 3 and rand(1.0) > level.float / 15.0:
        bullet.add Seek(speed: 0.2)

      let
        fRate = rand(1.0 .. 2.0) * levelModifier
      
      enemy.add Weapon(
        active: true,
        fireRate: fRate,
        fireSpeed: 0.3 * dt,
        lastFired: cpuTime(),
        bullet: bullet
      )


# Run game.

var
  mousePos: GLvectorf2
  mouseButtons: MButtons

  evt = sdl2.defaultEvent
  running = true

let
  playerScale = vec3(0.035)
  player = newPlayer(playerScale)
  background {.used.} = newEntityWith(
    Position(),
    Texture(
      textureId: backgroundTex,
      scale: vec2(1.0, 1.0),
      col: vec4(1.0, 1.0, 1.0, 1.0)
    )
  )

sysSeekPlayer.player = player

# Game loop.
while running:

  # Capture events.
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
    elif evt.kind == MouseButtonDown:
      var mb = evMouseButton(evt)
      if mb.button == BUTTON_LEFT: mouseButtons.left = true
      if mb.button == BUTTON_RIGHT: mouseButtons.right = true
    elif evt.kind == MouseButtonUp:
      var mb = evMouseButton(evt)
      if mb.button == BUTTON_LEFT: mouseButtons.left = false
      if mb.button == BUTTON_RIGHT: mouseButtons.right = false

  if sysKillEnemies.count == 0:
    level += 1

    if level > 1:
      echo "You have reached level ", level, "!"
    else:
      echo "Entering level 1"
    
    let
      pos = player.fetch Position
    createLevel(level, vec2(pos.x, pos.y), 0.4)

    # Update background.
    backgroundImage.paintBackground()
    backgroundTex.update(backgroundImage)

  sysControls.mousePos = mousePos
  sysControlWeapon.mouseButtons = mouseButtons

  run()

  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderActiveTextures()
  renderActiveModels()
  
  # Double buffer.
  window.glSwapWindow()
