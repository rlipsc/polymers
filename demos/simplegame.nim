# Simple game using opengl.
# This expects SDL2.dll to be in the current directory,
# available from here: https://www.libsdl.org/download-2.0.php
# and the Nim SDL2 wrapper: https://github.com/nim-lang/sdl2

import polymorph, polymers, glbits, glbits/modelrenderer, opengl, sdl2, random, math

func dot(v1, v2: GLvectorf2): float = v1[0] * v2[0] + v1[1] * v2[1]

func reflect(incident, normal: GLvectorf2): GLvectorf2 =
  let d = 2.0 * dot(normal, incident)
  result = vec2(incident[0] - d * normal[0], incident[1] - d * normal[1])

const
  compOpts = dynamicSizeComponents()
  sysOpts = dynamicSizeSystem()
  entOpts = dynamicSizeEntities()
  # Fixed time step.
  dt = 1.0 / 60.0

defineOpenGlRenders(compOpts, sysOpts)
defineKilling(compOpts)
defineGridMap(0.08, Position, compOpts, sysOpts)

registerComponents(compOpts):
  type
    Velocity = object
      x, y: GLfloat
    Weapon = object
      lastFired: float
      fireRate: float
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
    FireBullet = object
      lastFired: float
      fireRate: float
    PlayerKillable = object
    ExplodeOnDeath = object
    ShrinkAway = object
      startScale: float

# Forward declaration for this proc as it needs things defined after sealing.
proc particles(position: GLvectorf2, angle, spread: float, model: ModelInstance, scale: float, particleCount: int, speed: Slice[float], duration = 1.0)

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  # This system handles momentum and drag.
  all:
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y
    item.velocity.x *= 0.99
    item.velocity.y *= 0.99

makeSystemOpts("seekPlayer", [Seek, Enemy, Position, Velocity, Model], sysOpts):
  # Move towards player.
  fields:
    player: EntityRef
  start:
    # Don't seek the player when they're dead.
    if sys.player.hasComponent PlayerKilled: sys.paused = true 
    else: sys.paused = false

    let playerPos = sys.player.fetchComponent Position
  all:
    let
      dx = playerPos.x - item.position.x
      dy = playerPos.y - item.position.y
      angle = arcTan2(dy, dx)
      speed = item.seek.speed * dt
    item.velocity.x = speed * cos(angle)
    item.velocity.y = speed * sin(angle)
    item.model.angle = angle

makeSystemOpts("bounce", [Position, Velocity, Model], sysOpts):
  # This system handles bouncing off edges.
  all:
    const
      left = vec2(1.0, 0.0)
      right = vec2(-1.0, 0.0)
      top = vec2(0.0, 1.0)
      bottom = vec2(0.0, -1.0)

    let curVel = vec2(item.velocity.x, item.velocity.y)

    if item.position.x < -1.0:
      let r = reflect(curVel, left)
      item.position.x = -1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])

    if item.position.x > 1.0:
      let r = reflect(curVel, right)
      item.position.x = 1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])

    if item.position.y < -1.0:
      let r = reflect(curVel, top)
      item.position.y = -1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])

    if item.position.y > 1.0:
      let r = reflect(curVel, bottom)
      item.position.y = 1.0
      item.velocity.x = r[0]
      item.velocity.y = r[1]
      item.model.angle = arctan2(r[1], r[0])

template performDamage(damageType: typedesc): untyped =
  # Both enemies and players use similar code for damage,
  # only the fetch type for damage differs.
  #let curPos = item.gridMap.lastGridIdx
  let
    curX = item.position.x
    curY = item.position.y
  var r: bool
  for entPos in queryGridPrecise(curX, curY, 0.05):
    let ent = entPos.entity
    if ent != entity and not(ent.hasComponent Killed):
      let k = ent.fetchComponent Killed
      assert not k.valid
      # A collision has occurred.
      let damage = ent.fetchComponent damageType
      if damage.valid:
        item.health.amount -= damage.amount
        if item.health.amount <= 0:
          r = true
        # Kill damaging entity
        ent.addIfMissing Killed()
        break
  r

makeSystemOpts("takeDamageEnemy", [PlayerKillable, Health, GridMap, Position], sysOpts):
  all:
    if performDamage(DamageEnemy):
      item.entity.addIfMissing Killed()

makeSystemOpts("takeDamagePlayer", [Player, Health, GridMap, Position], sysOpts):
  all:
    if performDamage(PlayerDamage):
      if item.entity.hasComponent Player:
        item.entity.addIfMissing PlayerKilled()

makeSystemOpts("explosion", [ExplodeOnDeath, Killed, Position, Model], sysOpts):
  all:
    # Create some particles based on the model that's being killed.
    particles(
      vec2(item.position.x, item.position.y),
      0.0,
      TAU,
      item.model,
      scale = 0.5,
      particleCount = 50,
      speed = 0.2..0.3)

makeSystemOpts("countEnemies", [Enemy], sysOpts):
  # This system does nothing but its group still maintains a list of entities,
  # so we can read the `count` of items to determine how many entities exist
  # with the `Enemy` component.
  # We could also use `killEnemies` for this if we were being efficient.
  init: discard

makeSystemOpts("killEnemies", [Enemy], sysOpts):
  # This system nukes all the enemies, then pauses itself.
  # Used to reset the game.
  init:
    sys.paused = true
  all:
    entity.addIfMissing Killed()
  finish:
    sys.paused = true

# Delete entities with the `Killed` component.
addKillingSystems(sysOpts)

makeSystemOpts("fireBullet", [FireBullet, Position, Model], sysOpts):
  fields:
    player: EntityRef
  start:
    sys.paused = sys.player.hasComponent PlayerKilled
    let curTime = cpuTime()
  all:
    let
      bulletSpeed = 0.3 * dt
      bulletSize = 0.015
    if curTime - item.fireBullet.lastFired >= item.fireBullet.fireRate:
      item.fireBullet.lastFired = curTime
      let
        pos = item.position.access
        angle = item.model.angle
      var model = item.model.access
      model.scale = vec3(bulletSize)
      discard newEntityWith(
        model,
        pos,
        Velocity(x: bulletSpeed * cos(angle), y: bulletSpeed * sin(angle)),
        PlayerDamage(amount: 0.1),
        GridMap(),
        KillAfter(duration: 1.0),
        Health(amount: 0.01),
        PlayerKillable()
        )

makeSystemOpts("shrinkAway", [ShrinkAway, Model, KillAfter], sysOpts):
  added:
    item.shrinkAway.startScale = item.model.scale[0]
  start:
    let curTime = cpuTime()
  all:
    let normTime = 1.0 - ((curTime - item.killAfter.startTime) / item.killAfter.duration)
    item.model.scale = vec3(item.shrinkAway.startScale * normTime)

# Seal ECS.
makeEcs(entOpts)
commitSystems("run")

#-------------------

proc particles(position: GLvectorf2, angle, spread: float, model: ModelInstance, scale: float, particleCount: int, speed: Slice[float], duration = 1.0) =
  ## Create some particles.
  # Copy model object so we can edit it.
  var pModel = model.access
  # Resize model according to scale.
  pModel.scale = vec3(pModel.scale[0] * scale)
  
  # TODO: Add scale down over time.

  for i in 0 .. particleCount:
    let
      particleSpeed = rand speed.a * dt .. speed.b * dt
      fireAngle = rand angle - spread .. angle + spread
    pModel.angle = rand TAU

    discard newEntityWith(
      Position(x: position[0], y: position[1]),
      pModel,
      Velocity(x: particleSpeed * cos fireAngle, y: particleSpeed * sin fireAngle),
      KillAfter(duration: duration),
      ShrinkAway()
      )

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

const
  # Triangle vertices.
  vTriangle = [vec3(-1.0, -1.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(-1.0, 1.0, 0.0)]
  # Shade the vertices so the back end fades out.
  vCols = [vec4(0.5, 0.5, 0.5, 0.5), vec4(1.0, 1.0, 1.0, 1.0), vec4(0.5, 0.5, 0.5, 0.5)]
let
  shaderProg = newModelRenderer()
  shipModel = newModel(shaderProg, vTriangle, vCols)

# Allocate space on the GPU (and local memory) for the model and instance data.
shipModel.setMaxInstanceCount(200_000)

proc newPlayer(playerScale: GLvectorf3): EntityRef =
  newEntityWith(
    Model(modelId: shipModel, scale: playerScale, col: vec4(1.0, 0.0, 0.0, 1.0)),
    Position(),
    Velocity(),
    Weapon(fireRate: 0.2),
    Health(amount: 1.0),
    Player(),
    GridMap()
  )

proc createLevel(level: int, playerPos: GLvectorf2, clearArea: float) =
  ## Generate enemies according to level.
  for i in 0 ..< level * 10:
    let
      enemySize = 0.03
      extent = 0.95
    var pos = Position(x: rand(-extent..extent), y: rand(-extent..extent), z: 0.0)

    # Make sure nothing spawns on the player.
    if pos.x in playerPos[0] - clearArea .. playerPos[0] + clearArea and
      pos.y in playerPos[1] - clearArea .. playerPos[1] + clearArea:
        if playerPos[0] > -1.0 + clearArea:
          pos.x = playerPos[0] - clearArea
        else:
          pos.x = playerPos[0] + clearArea
        if playerPos[1] > -1.0 + clearArea:
          pos.y = playerPos[1] + clearArea
        else:
          pos.y = playerPos[1] + clearArea

    let enemy = newEntityWith(
      Model(modelId: shipModel, scale: vec3(enemySize), angle: rand(TAU), col: vec4(rand 1.0, rand 1.0, rand 1.0, 1.0)),
      pos,
      Velocity(),
      Enemy(),
      Health(amount: 1.0),
      GridMap(),
      PlayerDamage(amount: 1.0),
      Seek(speed: 0.01),
      PlayerKillable(),
      ExplodeOnDeath()
    )
    if level > 0 and rand(1.0) < 0.1:
      enemy.addComponent FireBullet(fireRate: rand 1.0 .. 2.0)

type MButtons = tuple[left: bool, right: bool]

proc controls(player: EntityRef, mousePos: GLvectorf2, mouseButtons: MButtons) =
  type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
  const keyClear: uint8 = 0
  proc pressed(keyStates: KeyCodes, sc: Scancode): bool = result = keyStates[sc.int] > keyClear
  var keyStates: KeyCodes = getKeyboardState()
  let
    playerModel =   player.fetchComponent Model
    playerPos =     player.fetchComponent Position
    playerVel =     player.fetchComponent Velocity
    playerWeapon =  player.fetchComponent Weapon

    dx = mousePos[0] - playerPos.x
    dy = mousePos[1] - playerPos.y
    angle = arctan2(dy, dx)

  playerModel.angle = angle

  # Movement

  let
    thrustSpeed = 0.005 * dt
    strafeSpeed = 0.001 * dt
    strafeAngle = angle + 90.0.degToRad
    bigThrust = (scale: 0.2, speed: 0.2..0.3)
    smallThrust = (scale: bigThrust.scale * 0.5, speed: 0.02..0.06)

  if keyStates.pressed(SDL_SCANCODE_W):
    playerVel.x += thrustSpeed * cos(angle)
    playerVel.y += thrustSpeed * sin(angle)
    particles(vec2(playerPos.x, playerPos.y), angle + PI, 30.0.degToRad, playerModel, bigThrust.scale, 50, bigThrust.speed)

  if keyStates.pressed(SDL_SCANCODE_A):
    playerVel.x += strafeSpeed * cos(strafeAngle)
    playerVel.y += strafeSpeed * sin(strafeAngle)
    particles(vec2(playerPos.x, playerPos.y), strafeAngle + PI, 60.0.degToRad, playerModel, smallThrust.scale, 20, smallThrust.speed)

  if keyStates.pressed(SDL_SCANCODE_D):
    playerVel.x -= strafeSpeed * cos(strafeAngle)
    playerVel.y -= strafeSpeed * sin(strafeAngle)
    particles(vec2(playerPos.x, playerPos.y), strafeAngle, 60.0.degToRad, playerModel, smallThrust.scale, 20, smallThrust.speed)

  if keyStates.pressed(SDL_SCANCODE_S):
    playerVel.x -= thrustSpeed * cos(angle)
    playerVel.y -= thrustSpeed * sin(angle)
    particles(vec2(playerPos.x, playerPos.y), angle, 30.0.degToRad, playerModel, smallThrust.scale, 50, smallThrust.speed)

  # Fire!
  let
    bulletSpeed = 1.0 * dt
    bulletSize = 0.02
    curTime = cpuTime()
  if mouseButtons.left and curTime - playerWeapon.lastFired >= playerWeapon.fireRate:
    playerWeapon.lastFired = curTime
    discard newEntityWith(
      Model(modelId: shipModel, scale: vec3(bulletSize), angle: angle, col: vec4(1.0, 1.0, 0.0, 1.0)),
      Position(x: playerPos.x, y: playerPos.y),
      Velocity(x: bulletSpeed * cos(angle), y: bulletSpeed * sin(angle)),
      DamageEnemy(amount: 1.0),
      GridMap(),
      KillAfter(duration: 1.0),
      ExplodeOnDeath()
      )


var
  mousePos: GLvectorf2
  mouseButtons: MButtons

  level = 0
  evt = sdl2.defaultEvent
  running = true
  resetGame: bool
  resetStart: float

let
  playerScale = vec3(0.035)
  player = newPlayer(playerScale)

sysSeekPlayer.player = player
sysFireBullet.player = player

# Game loop.
while running:

  # Capture events.
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
    if evt.kind == MouseButtonDown:
      var mb = evMouseButton(evt)
      if mb.button == BUTTON_LEFT: mouseButtons.left = true
      if mb.button == BUTTON_RIGHT: mouseButtons.right = true
    if evt.kind == MouseButtonUp:
      var mb = evMouseButton(evt)
      if mb.button == BUTTON_LEFT: mouseButtons.left = false
      if mb.button == BUTTON_RIGHT: mouseButtons.right = false

  if sysCountEnemies.count == 0:
    level += 1
    if level > 1:
      echo "You have reached level ", level, "!"
    else: echo "Entering level 1"
    let pos = player.fetchComponent Position
    createLevel(level, vec2(pos.x, pos.y), 0.4)

  run()

  if not player.hasComponent PlayerKilled:
    controls(player, mousePos, mouseButtons)
  else:
    if not resetGame:
      resetGame = true
      echo "You died!"
      let
        pos = player.fetchComponent Position
        model = player.fetchComponent Model
      # Explode.
      particles(vec2(pos.x, pos.y), 0.0, TAU, model, scale = 0.35, particleCount = 5_000, speed = 0.0..1.6, duration = 4.5)
      # We don't want to actually delete the player entity,
      # so we "hide" the ship by scaling to zero.
      model.scale = vec3(0.0)
      resetStart = cpuTime()

    # Allow some time for the game to display the dead ship before resetting.
    if resetGame and cpuTime() - resetStart > 5.0:
      resetGame = false
      let
        pos = player.fetchComponent Position
        model = player.fetchComponent Model
        health = player.fetchComponent Health
      player.removeComponent PlayerKilled
      pos.x = 0.0
      pos.y = 0.0
      model.scale = playerScale
      health.amount = 1.0
      level = 0
      sysKillEnemies.paused = false

  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderActiveModels()
  
  # Double buffer.
  window.glSwapWindow()
