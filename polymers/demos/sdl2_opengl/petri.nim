# Simple game using opengl.
# This expects SDL2.dll to be in the current directory,
# available from here: https://www.libsdl.org/download-2.0.php
# and the Nim SDL2 wrapper: https://github.com/nim-lang/sdl2

import opengl, sdl2, sdl2/ttf, random, math, times, os
import polymorph, polymers, glbits, glbits/[modelrenderer, fonts]

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
  vCols = [vec4(0.3, 0.3, 0.3, 1.0), vec4(1.0, 1.0, 1.0, 1.0), vec4(0.3, 0.3, 0.3, 1.0)]

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
  bulletModel = shaderProg.newModel(vTriangle, vCols)
  circleModel = shaderProg.makeCircleModel(triangles = 8, vec4(1.0), vec4(0.0))

bulletModel.setMaxInstanceCount(200_000)
circleModel.setMaxInstanceCount(200_000)

var
  shipModels: array[10, ModelId]

for i in 0 ..< shipModels.len:
  let modelData = genModel(10)
  shipModels[i] = newModel(shaderProg, modelData.model, modelData.cols)
  shipModels[i].setMaxInstanceCount(200_000)


# Misc definitions.

type
  MButtons = tuple[left, right: bool]
  DamageKind = enum dkPhysical, dkFire

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
    Orbit = object
      x, y: float
      w, h: float
      a, s: float
    Weapon = object
      active: bool
      lastFired: float
      fireRate: float
      fireSpeed: float
      bullet: ComponentList
      special: bool
      lastSpecialFired: float
      specialFireRate: float

    Health = object
      amount: float
      full: float
    Heal = object
      amount: float
    Flames = object
    Player = object
    Enemy = object
    Damage = object
      amount: float
      radius: float
      kind: DamageKind
    CollisionDamage = object
      damage: Damage
    ExplodeOnDeath = object
      damage: Damage
    Seek = object
      speed: float
    ShrinkAway = object
      startScale: float
      normTime: float
      startCol: GLvectorf4
    DeathTimer = object
      start, duration: float
    ReadControls = object
    Bullet = object

Health.onInit:
  # Automatically fill to starting amount if not set.
  if curComponent.full == 0.0:
    if curComponent.amount > 0:
      curComponent.full = curComponent.amount
    else:
      curComponent.full = 1.0

defineOpenGLComponents(compOpts, Position)
defineKilling(compOpts)
defineFontText(compOpts, systems)

# Create grids for broad phase collision detection with 'queryGridPrecise<Name>'.
defineGridMap(0.08, Position, "PlayerGrid", "Player", compOpts, sysOpts)
defineGridMap(0.08, Position, "EnemyGrid", "Enemy", compOpts, sysOpts)

func colRange(a, b: SomeFloat): auto = a.float32 .. b.float32
func colRange(a: SomeFloat): auto = 0.float32 .. a.float32

let
  font = staticLoadFont(currentSourcePath.splitFile.dir.joinPath r"xirod.ttf")

# Utility functions to be added after makeEcs().
onEcsBuilt:

  proc particles(position: GLvectorf2, angle, spread: float, model: ModelInstance | Model, scale: float, particleCount: int,
      speed: Slice[float], duration = 1.0, col = [colRange(0.8, 1.0), colRange(0.8), colRange(0.0, 0.0)]) =
    
    when model is ModelInstance:
      var
        modelCopy = model.access
    elif model is Model:
      var
        modelCopy = model
    
    # Resize model according to scale.
    modelCopy.scale = vec3(modelCopy.scale[0] * scale)

    for i in 0 .. particleCount:
      let
        particleSpeed = rand speed.a * dt .. speed.b * dt
        fireAngle = rand angle - spread .. angle + spread
        r = rand col[0]
        g = rand col[1]
        b = rand col[2]
        light = 1.0 - abs(fireAngle - angle) / spread

      modelCopy.angle = rand TAU
      modelCopy.col = vec4(r * light, g * light, b * light, light)

      discard newEntityWith(
        Position(x: position[0], y: position[1]),
        Velocity(x: particleSpeed * cos fireAngle, y: particleSpeed * sin fireAngle),
        Bounce(dust: false),
        modelCopy,
        KillAfter(duration: duration),
        ShrinkAway()
        )

  proc updatePhysics(bullet: EntityRef, x, y: float, v: GLvectorf2) =
    let
      pos = bullet.fetch Position
      vel = bullet.fetch Velocity
      model = bullet.fetch Model

    if pos.valid:
      pos.x = x
      pos.y = y
    
    if vel.valid:
      vel.x = v.x
      vel.y = v.y

    if model.valid:
      model.angle = v.toAngle

  proc applyDamage(entity: EntityRef, damage: Damage | DamageInstance, health: HealthInstance): bool =
    health.amount -= damage.amount

    case damage.kind
      of dkPhysical: discard
      of dkFire: entity.addIfMissing Flames()
    
    if health.amount <= 0:
      true
    else:
      false

  proc applyCollision(collider: EntityRef, health: HealthInstance, pos: PositionInstance, vel: VelocityInstance, struck: EntityRef) =
    ## The collider is applied to all query results even when marked as Killed part way through.
    
    if struck != collider and struck.alive:
      
      # A collision has occurred.
      
      let
        colDamage = struck.fetch CollisionDamage
      
      if colDamage.valid:
        # Apply the collision damage to the iteration entity.

        let
          killed = collider.applyDamage(colDamage.damage, health)
        
        if not collider.has Bullet:
          let e = newEntityWith(
            fontText(
              font,
              $colDamage.damage.amount,
              vec3(pos.x, pos.y, 0.0),
              vec4(1.0, 0.0, 0.0, 1.0),
              vec2(0.1)
            ),
            ShrinkAway(),
            KillAfter(duration: 1.0),
          )
        
        if not killed:
          let
            struckVel = struck.fetch Velocity
          
          if struckVel.valid:
            if vel.valid:
              vel.x += struckVel.x
              vel.y += struckVel.y

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  # This system handles momentum and drag.
  all:
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y
    item.velocity.x *= 0.99
    item.velocity.y *= 0.99

makeSystemOpts("orbit", [Position, Orbit], sysOpts):
  # This system handles momentum and drag.
  all:
    item.position.x = item.orbit.x + item.orbit.w * cos(item.orbit.a)
    item.position.y = item.orbit.y + item.orbit.h * sin(item.orbit.a)
    item.orbit.a = (item.orbit.a + item.orbit.s * dt) mod TAU

makeSystemOpts("seekPlayer", [Seek, Position, Velocity, Model], sysOpts):
  # Move towards player.
  fields:
    player: EntityRef
  start:
    # Don't seek the player when they're dead.
    if sys.player.has Killed: sys.paused = true 
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

makeSystemOpts("collidePlayer", [Position, Health, PlayerGrid], sysOpts):
  all:
    for colEntPos in queryGridPreciseEnemy(item.position.x, item.position.y, 0.05):
      entity.applyCollision(item.health, item.position, entity.fetch Velocity, colEntPos.entity)

    if item.health.amount <= 0:
      entity.addIfMissing Killed()

makeSystemOpts("collideEnemy", [Position, Health, EnemyGrid], sysOpts):
  all:
    for colEntPos in queryGridPrecisePlayer(item.position.x, item.position.y, 0.05):
      entity.applyCollision(item.health, item.position, entity.fetch Velocity, colEntPos.entity)

    if item.health.amount <= 0:
      entity.addIfMissing Killed()

makeSystemOpts("playerKilled", [Killed, Player, ReadControls, Position, Model], sysOpts):
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
      speed = 0.001..1.6,
      duration = 4.5)

    entity.addIfMissing DeathTimer(start: cpuTime(), duration: 5.0)

  finish:
    # Disable player input.
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
        angle = item.model.angle
        bulletSpeed = item.weapon.fireSpeed
      
      bullet.updatePhysics(
        item.position.x,
        item.position.y,
        vec2(bulletSpeed * cos(angle), bulletSpeed * sin(angle))
      )

    if item.weapon.special and curTime - item.weapon.lastSpecialFired >= item.weapon.specialFireRate:
      # Fire!

      item.weapon.lastSpecialFired = curTime

      for i in 0 .. 100:
        let
          bullet = item.weapon.bullet.construct
          angle = rand TAU
          bulletSpeed = item.weapon.fireSpeed
        
        bullet.updatePhysics(
          item.position.x,
          item.position.y,
          vec2(bulletSpeed * cos(angle), bulletSpeed * sin(angle))
        )

makeSystemOpts("explosionFx", [Killed, ExplodeOnDeath, Position, Model], sysOpts):
  # Create some particles using the model that's being killed.
  all:
    particles(
      vec2(item.position.x, item.position.y),
      0.0,
      TAU,
      item.model,
      scale = 0.5,
      particleCount = 50,
      speed = 0.02..0.04,
      col = [
        colRange(item.model.col.r),
        colRange(item.model.col.g),
        colRange(item.model.col.b),
        ])

makeSystemOpts("boom", [Killed, ExplodeOnDeath, Position, PlayerGrid], sysOpts):
  # Cause area of affect damage around the entity.
  all:
    let
      damage = item.explodeOnDeath.damage
      (x, y) = (item.position.x, item.position.y)

    if damage.amount > 0:
      for entPos in queryGridPreciseEnemy(x, y, damage.radius):
        let
          ent = entPos.entity
          health = ent.fetch Health
        
        if health.valid:
          if entPos.entity.applyDamage(damage, health):
            entPos.entity.addIfMissing Killed()

makeSystemOpts("flames", [Flames, Position, Health], sysOpts):
  all:
    template doParticles(pc: int, particleSpeed, dur, r, g, b: untyped): untyped =
      particles(
        position = vec2(item.position.x, item.position.y),
        angle = 0.0,
        spread = TAU,
        model = Model(modelId: circleModel, scale: vec3(1.0)),
        scale = 0.02,
        particleCount = pc,
        speed = particleSpeed,
        col = [r,g,b],
        duration = dur
      )

    let
      healthRatio = item.health.amount / item.health.full
      damage = 1.0 - healthRatio
      smokeParticles = 1 + int(1.0 * damage)
      fireParticles = 1 + int(1.0 * damage)

    if healthRatio < 1.0:
      
      let
        baseSize = 0.02
      
      doParticles(fireParticles,
        0.04..0.1,
        #baseSize + 0.05 * damage .. baseSize + 0.1 * damage,
        0.5,
        r = colRange(0.8, 1.0),
        g = colRange(0.0),
        b = colRange(0.0))

      doParticles(smokeParticles,
        0.04..0.8,
        #baseSize + 0.05 * damage .. baseSize + 0.1 * damage,
        5.0,
        r = colRange(0.2, 0.3),
        g = colRange(0.2, 0.3),
        b = colRange(0.0))
      
    else:
      # Splash for healed.
      doParticles(400,
        0.1..0.12,
        1.0,
        r = colRange(0.1),
        g = colRange(1.0),
        b = colRange(0.1))

      entity.remove Flames

makeSystemOpts("heal", [Heal, Health], sysOpts):
  all:
    if item.health.amount < item.health.full:
      item.health.amount = clamp(
        item.health.amount + item.heal.amount * dt,
        0.0,
        item.health.full
      )

makeSystemOpts("wallPhysics", [Position, Velocity, Model, Bounce], sysOpts):
  # This system handles bouncing off edges.
  all:
    const
      left = vec2(1.0, 0.0)
      right = vec2(-1.0, 0.0)
      top = vec2(0.0, 1.0)
      bottom = vec2(0.0, -1.0)
      dustScale = 0.5
      
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
          duration = 4.0
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

makeSystemOpts("shrinkAway", [ShrinkAway, KillAfter], sysOpts):
  let curTime = cpuTime()
  
  all: item.shrinkAway.normTime = 1.0 - ((curTime - item.killAfter.startTime) / item.killAfter.duration)

makeSystemOpts("shrinkAwayModel", [ShrinkAway, Model], sysOpts):
  added:
    item.shrinkAway.startScale = item.model.scale[0]
    item.shrinkAway.startCol = item.model.col
  all: item.model.scale = vec3(item.shrinkAway.startScale * item.shrinkAway.normTime)

makeSystemOpts("shrinkAwayFont", [ShrinkAway, FontText], sysOpts):
  added:
    item.shrinkAway.startScale = item.fontText.scale[0]
    item.shrinkAway.startCol = item.fontText.col
  all:
    item.fontText.scale = vec2(item.shrinkAway.startScale * item.shrinkAway.normTime)
    item.fontText.col = item.shrinkAway.startCol * item.shrinkAway.normTime

makeSystemOpts("killEnemies", [Enemy], sysOpts):
  # This system stores a record of enemy entities and when unpaused will
  # delete them.
  # Used to reset the game if the player dies.
  # The sys.count for this system is also useful to track the number of
  # Enemy entities.
  # Note: this is placed after effect systems that use Killed such as
  # "explosion", as we don't want to trigger death effects on enemies
  # when resetting the level.
  init:
    sys.paused = true
  all:
    entity.addIfMissing Killed()
  sys.paused = true

makeSystem("restartGame", [Killed, DeathTimer, Position, Model, Health]):
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
      entity.remove Killed, DeathTimer

makeSystemOpts("killAfter", [KillAfter], sysOpts):
  let
    curTime = cpuTime()

  all:
    if curTime - item.killAfter.startTime >= item.killAfter.duration:
      item.entity.addIfMissing Killed()

makeSystemOpts("deleteKilled", [Killed, not Player], sysOpts):
  finish: sys.clear


# Update GPU for rendering.
defineOpenGLUpdateSystems(sysOpts, Position)
defineFontRendering(sysOpts)

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
    Health(amount: 1.0),
    Heal(amount: 0.01),
    Player(),
    PlayerGrid(),
    Bounce(dust: true),
    ReadControls(),
    CollisionDamage(
      damage: Damage(amount: 1.0)
    ),
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
        PlayerGrid(),
        Health(amount: 0.00001),
        CollisionDamage(damage: Damage(amount: 1.0)),
        Bullet(),
        Bounce(dust: true),
        KillAfter(duration: 1.0),
        ExplodeOnDeath(
          damage: Damage(amount: 0.1, kind: dkFire, radius: 0.1)
        ),
      )
    ),
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
          pos.x = rand -0.99 .. max(-0.99, px - clearArea)
        else:
          pos.x = rand px + clearArea .. 0.99
        
        if py > -1.0 + clearArea:
          pos.y = rand -0.99 .. max(-0.99, py + clearArea)
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
        EnemyGrid(),
        Enemy(),
        Bounce(dust: true),
        Health(amount: 1.0 / levelModifier),
        CollisionDamage(
          damage: Damage(amount: 0.1)
        ),
        Seek(speed: rand 0.01 .. 0.03),
        ExplodeOnDeath(),
      )

    if level > 1 and rand(1.0) < 0.1:

      let
        damageKind =
          if level > 5 and rand(1.0) > 0.1: dkFire
        else:
          dkPhysical

      var
        # Create a bullet template to be spawned by Weapon.
        bullet = cl(
          Position(),
          Velocity(),
          Model(
            modelId: bulletModel,
            scale: vec3(0.015),
            col: vec4(0.5, 1.0, 1.0, 1.0)
          ),
          EnemyGrid(),
          Enemy(),
          Bullet(),
          Bounce(dust: true),
          Health(amount: 0.01),
          CollisionDamage(damage: Damage(amount: 0.1)),
          KillAfter(duration: 1.0),
          ExplodeOnDeath(
            damage: Damage(
              amount: 0.1,
              radius: level.float * 0.01,
              kind: damageKind
            )
          )
        )
      
      if level > 3 and rand(1.0) > level.float / 15.0:
        # Bullets seek the player at higher levels.
        bullet.add Seek(speed: 0.2)

      let
        fRate = rand(1.0 .. 2.0) * levelModifier
      
      # This enemy fires bullets in its general direction.
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

var
  planets: Entities
  planetTex: seq[tuple[tex: GLTexture, id: TextureId]]
  planetTextures = 5
  planetRadius = screenWidth
  middle = screenWidth div 2

planetTex.setLen planetTextures 
for i in 0 ..< planetTextures:
  planetTex[i].id = newTextureId(max = 10)
  planetTex[i].tex.initTexture(planetRadius, planetRadius)
  planetTex[i].tex.paintPlanet(middle, middle, planetRadius div 2)
  planetTex[i].id.update(planetTex[i].tex)

proc genPlanets(planets: var Entities, num = 1 .. 3) =
  planets.deleteAll

  for i in num:
    let
      scale = rand 0.1 .. 0.5
      speed = -0.01 .. 0.01
    
    planets.add newEntityWith(
      Position(),
      Texture(
        textureId: planetTex[rand planetTex.high].id,
        scale: vec2(scale, scale),
        col: vec4(1.0, 1.0, 1.0, 1.0)
      ),
      Orbit(
        x: rand -0.4..0.4,
        y: rand -0.4..0.4,
        w: rand 0.4 .. 0.8,
        h: rand 0.4 .. 0.8,
        s: rand speed
      )
    )

sysSeekPlayer.player = player

proc main() =
  var
    planets: Entities
    screenInfo = initScreenInfo(screenWidth, screenHeight)

  planets.genPlanets()

  proc setAspectRatios(extent: array[2, cint]) =
    screenInfo.setExtent extent

    #setModelAspectRatios(screenInfo.aspect)
    setTextureAspectRatios(screenInfo.aspect)

  setAspectRatios screenInfo.extent

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
          setAspectRatios [windowEvent.data1, windowEvent.data2]
          glViewport(0, 0, screenInfo.extent[0], screenInfo.extent[1])
      elif evt.kind == MouseMotion:
        let
          mm = evMouseMotion(evt)
        mousePos = screenInfo.normalise [mm.x, mm.y]
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
      planets.genPlanets()

    sysControls.mousePos = mousePos
    sysControlWeapon.mouseButtons = mouseButtons


    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

    run()

    renderActiveTextures()
    renderActiveModels()
    renderFonts()

    # Double buffer.
    window.glSwapWindow()

main()
flushGenLog()