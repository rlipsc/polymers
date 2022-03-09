# Simple game using opengl.
# This expects SDL2.dll to be in the current directory,
# available from here: https://www.libsdl.org/download-2.0.php
# and the Nim SDL2 wrapper: https://github.com/nim-lang/sdl2

import opengl, sdl2, sdl2/ttf, random, math, times, os, strformat
import polymorph, polymers, glbits, glbits/[modelrenderer, fonts, glrig]

randomize()

# Create window and OpenGL context.

initSdlOpenGl(800, 600)

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
var
  bulletModel = shaderProg.newModel(vTriangle, vCols)
  shipModels: array[10, ModelId]

bulletModel.setMaxInstanceCount(200_000)

for i in 0 ..< shipModels.len:
  let modelData = genModel(10)
  shipModels[i] = newModel(shaderProg, modelData.model, modelData.cols)
  shipModels[i].setMaxInstanceCount(200_000)

# Models are rendered in the order they're defined.
var
  circleModel = shaderProg.makeCircleModel(triangles = 8, vec4(1.0), vec4(0.0))

circleModel.setMaxInstanceCount(200_000)


# Misc definitions.

type
  MButtons = tuple[left, right: bool]
  DamageKind = enum dkPhysical = "Physical", dkFire = "Fire"

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
      dust: int
    Orbit = object
      pos: PositionInstance
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
      specialCount: int
      specialBullet: ComponentList
      specialSpread: float
      specialFireRate: float
    Health = object
      amount: float
      full: float
    Heal = object
      amount: float
    Flames = object
      lastPuff: float
    Player = object
    Enemy = object
    Damage = object
      kind: DamageKind
      amount: float
      radius: float
      quality: Slice[float]
    DamageOverTime = object
      damage: Damage
      startTime: float
      lastTick: float
      frequency: float
      duration: float
      source: EntityRef
    CollisionDamage = object
      damage: Damage
    ExplodeOnDeath = object
      damage: Damage
      col: GLvectorf4
    Seek = object
      speed: float
    ShrinkAway = object
      startScale: GLvectorf3
      normTime: float
      startCol: GLvectorf4
    Particle = object
    Trail = object
      particles: int
      col: GLvectorf4
      sizes: Slice[float]
      speeds: Slice[float]
      duration: float32
    DeathTimer = object
      start, duration: float
    ReadControls = object
    Bullet = object
    Score = object
      value: int
    ChildOf = object  # Added to entities spawned from weapons.
      parent: EntityRef

Health.onInit:
  # Automatically fill to starting amount if not already set.
  if curComponent.full == 0.0:
    if curComponent.amount > 0:
      curComponent.full = curComponent.amount
    else:
      curComponent.full = 1.0

Trail.onInit:
  if curComponent.sizes == 0.0 .. 0.0:
    curComponent.sizes = 0.01..0.04
  if curComponent.speeds == 0.0 .. 0.0:
    curComponent.speeds = 0.008..0.012
  if curComponent.duration == 0.0:
    curComponent.duration = 1.0


defineOpenGLComponents(compOpts, Position)
defineKilling(compOpts)
defineFontText(compOpts, sysOpts)

DamageOverTime.onInit:
  curComponent.startTime = epochTime()

proc initDamage(amount: float, kind: DamageKind = dkPhysical, radius = 0.0, quality = 0.8 .. 1.2): Damage =
  Damage(kind: kind, amount: amount, radius: radius, quality: quality)

# Create separate grids for broad phase collision detection, accessed
# with 'queryGridPrecise<Name>'.
defineGridMap(0.08, Position, "PlayerGrid", "Player", compOpts, sysOpts)
defineGridMap(0.08, Position, "EnemyGrid", "Enemy", compOpts, sysOpts)

func colRange(a, b: SomeFloat): auto = a.float32 .. b.float32
func colRange(a: SomeFloat): auto = 0.float32 .. a.float32
func colRanges(v: GLvectorf4): auto = [v.r.colRange, v.g.colRange, v.b.colRange]

let
  # Download this font from here: https://www.1001fonts.com/orbitron-font.html
  font = staticLoadFont(currentSourcePath.splitFile.dir.joinPath r"Orbitron Bold.ttf")
  particleZ = -0.5
  fontZ = -0.6

# Utility functions to be added after makeEcs().
onEcsBuilt:

  proc getVec(p: PositionInstance): GLvectorf2 =
    vec2(p.x, p.y)

  proc particles(position: GLvectorf2, angle, spread: float, model: ModelInstance | Model, scale: float, particleCount: int,
      speed: Slice[float], duration = 0.5, col = [colRange(0.8, 1.0), colRange(0.2, 0.4), colRange(0.0, 0.0)]) =
    
    when model is ModelInstance:
      var
        modelCopy = model.access
    elif model is Model:
      var
        modelCopy = model
    
    # Resize model according to scale.
    if modelCopy.scale != vec3(0.0):
      modelCopy.scale = modelCopy.scale * scale
    else:
      modelCopy.scale = vec3(scale)

    for i in 0 .. particleCount:
      let
        particleSpeed = rand speed.a * dt .. speed.b * dt
        fireAngle = rand angle - spread .. angle + spread
        r = rand col[0]
        g = rand col[1]
        b = rand col[2]
        light = 1.0 - abs(fireAngle - angle) / spread

      modelCopy.angle = rand TAU
      modelCopy.col = vec4(r * light, g * light, b * light, 0.4)

      discard newEntityWith(
        Position(x: position[0], y: position[1], z: particleZ),
        Velocity(x: particleSpeed * cos fireAngle, y: particleSpeed * sin fireAngle),
        Bounce(dust: 0),
        modelCopy,
        KillAfter(duration: duration),
        Particle(),
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

  proc applyScore(target, ent: EntityRef) =
    # Applies a score in 'target' to 'ent'.
    const defaultKillScore = 1
    let childOf = ent.fetch ChildOf

    if childOf.valid and childOf.parent.alive:
      let parentScore = childOf.parent.fetch Score
      if parentScore.valid:
        let targetScore = target.fetch Score
        if targetScore.valid: parentScore.value += targetScore.value
        else: parentScore.value += defaultKillScore
    else:
      let score = ent.fetch Score
      if score.valid:
        let targetScore = target.fetch Score
        if targetScore.valid: score.value += targetScore.value
        else: score.value += defaultKillScore

  proc applyDamage(health: HealthInstance, damage: Damage): float =

    result = damage.amount * rand(damage.quality)
    health.amount -= result

  proc applyDamage(entity: EntityRef, health: HealthInstance, damage: Damage, sourceEntity: EntityRef): float =

    result = health.applyDamage damage
    health.amount -= result
    case damage.kind
      of dkPhysical: discard 
      of dkFire:
        assert sourceEntity.alive
        let childOf = sourceEntity.fetch ChildOf
        var parent: EntityRef
        if childOf.valid and childOf.parent.alive:
          parent = childOf.parent
        else:
          parent = sourceEntity
        entity.addIfMissing Flames()
        entity.addOrUpdate DamageOverTime(
          damage: damage, startTime: epochTime(), frequency: 1.0, duration: 5.0,
          source: parent
        )

  proc createText(value: string, pos: GLvectorf2, col: GLvectorf4, duration = 1.5, vel = vec2(0.0), size = vec2(0.05)): EntityRef {.discardable.} =
    result = newEntityWith(
      fontText(font, value, vec3(pos[0], pos[1], fontZ), col, size),
      ShrinkAway(),
      KillAfter(duration: duration),
    )

    if vel != vec2(0.0):
      # Shoot text in a direction.
      discard result.add(
        Position(x: pos.x, y: pos.y),
        Velocity(x: vel.x, y: vel.y)
      )

  proc collisionDamageText(ent: EntityRef, pos: GLvectorf2, createText: string) =
    if not ent.has Bullet:
      # No damage text for bullets.
      let
        textEnt = createText(createText, vec2(pos.x, pos.y), vec4(1.0, 0.0, 0.0, 0.9))
    
      if ent.has Player:
        discard textEnt.add(
          ent.fetch(Position).access,
          Orbit(
            pos: ent.fetch Position,
            w: 0.1, h: 0.1,
            s: TAU
          )
        )

  proc killText(entity: EntityRef, posVec: GLvectorf2) =
    if not entity.hasAny(Killed, Bullet):
      createText("KILL", posVec,
        vec4(1.0, 1.0, 0.0, 1.0),
        duration = 1.0, vel = vec2(0.00, 0.005)
      )

  template applyCollision(collider: EntityRef, health: HealthInstance, pos: PositionInstance, vel: VelocityInstance, struck: EntityRef) {.dirty.} =
    # This is a template so we get static checking.
    # It's dirty so we don't mangle symbol names and the '&' formatting macro works.
    if struck != collider and struck.alive:
      let
        colDamage = collider.fetch CollisionDamage
      
      if colDamage.valid:
        let
          posVec = vec2(pos.x, pos.y)
          struckHealth = struck.fetch Health

        if health.valid:
          let
            finalDamageSelf = collider.applyDamage(health, colDamage.damage, collider)

          collisionDamageText(collider, posVec, &"{finalDamageSelf:3.1f}")

          if health.amount <= 0:
            if struckHealth.valid and struckHealth.amount > 0.0:
              struck.applyScore collider

        if struckHealth.valid:
          let
            finalDamageStruck = struck.applyDamage(struckHealth, colDamage.damage, collider)
          
          collisionDamageText(collider, posVec, &"{finalDamageStruck:3.1f}")

          if struckHealth.amount <= 0.0:
            if health.valid and health.amount > 0:
              collider.applyScore struck

makeSystemOpts("movement", [Position, Velocity], sysOpts):
  # This system handles momentum and drag.
  all:
    item.position.x += item.velocity.x
    item.position.y += item.velocity.y
    item.velocity.x *= 0.99
    item.velocity.y *= 0.99

makeSystemOpts("descendParticles", [Position, Particle], sysOpts):
  # Makes particles gradually move to the background.
  let
    zDescent = 0.0001 * dt
  all: item.position.z += zDescent

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

makeSystemOpts("collidePlayer", [Position, Velocity, Health, PlayerGrid], sysOpts):
  all:
    for colEntPos in queryGridPreciseEnemy(item.position.x, item.position.y, 0.05):
      entity.applyCollision(item.health, item.position, item.velocity, colEntPos.entity)

makeSystemOpts("collideEnemy", [Position, Velocity, Health, EnemyGrid], sysOpts):
  all:
    for colEntPos in queryGridPrecisePlayer(item.position.x, item.position.y, 0.05):
      entity.applyCollision(item.health, item.position, item.velocity, colEntPos.entity)

makeSystemOpts("orbit", [Orbit], sysOpts):
  all:
    item.orbit.a = (item.orbit.a + item.orbit.s * dt) mod TAU

makeSystemOpts("orbitPos", [Position, Orbit], sysOpts):
  all:
    item.position.x = item.orbit.pos.x + item.orbit.w * cos(item.orbit.a)
    item.position.y = item.orbit.pos.y + item.orbit.h * sin(item.orbit.a)

makeSystemOpts("fontWithPos", [FontText, Position], sysOpts):
  all:
    item.fontText.position = vec2(item.position.x, item.position.y)

makeSystemOpts("playerKilled", [Killed, Player, Position, Model, not DeathTimer], sysOpts):
  fields:
    deathDuration = 5.0
  all:
    createText("You died!", vec2(0.0), vec4(1.0, 0.0, 0.0, 0.9),
      duration = sys.deathDuration * 2.0, size = vec2(0.2, 0.1))
    
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

    item.model.col.a = 0.0
  
    # Disable player input.
    entity.remove ReadControls
    entity.add DeathTimer(start: epochTime(), duration: sys.deathDuration)

makeSystemOpts("controls", [ReadControls, Position, Velocity, Model, Weapon], sysOpts):
  # Handle player input.
  fields:
    mousePos: GLvectorf2
    lastKeyTime: float
  
  type KeyCodes = ptr array[0 .. SDL_NUM_SCANCODES.int, uint8]
  const keyClear: uint8 = 0

  var
    keyStates: KeyCodes = getKeyboardState()

  proc pressed(keyStates: KeyCodes, sc: Scancode): bool =
    result = keyStates[sc.int] > keyClear
  
  all:
    let
      dx = sys.mousePos[0] - item.position.x
      dy = sys.mousePos[1] - item.position.y
      angle = arctan2(dy, dx)

      # Thruster position.
      tAngle = angle + PI
      tx = item.position.x + item.model.scale[0] * cos(tAngle)
      ty = item.position.y + item.model.scale[1] * sin(tAngle)

      model = item.model

    # Point the model towards the mouse coordinates.
    model.angle = angle

    # Movement

    let
      thrustSpeed = 0.03 * dt
      strafeSpeed = 0.01 * dt
      strafeAngle = angle + 90.0.degToRad
      bigThrust = (scale: 0.8, speed: 0.2..0.4)
      smallThrust = (scale: bigThrust.scale * 0.5, speed: 0.05..0.1)

    if keyStates.pressed(SDL_SCANCODE_W):
      item.velocity.x += thrustSpeed * cos(angle)
      item.velocity.y += thrustSpeed * sin(angle)
      particles(vec2(tx, ty), angle + PI, 30.0.degToRad, model, bigThrust.scale, 5, bigThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_A):
      item.velocity.x += strafeSpeed * cos(strafeAngle)
      item.velocity.y += strafeSpeed * sin(strafeAngle)
      particles(vec2(tx, ty), strafeAngle + PI, 60.0.degToRad, model, smallThrust.scale, 2, smallThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_D):
      item.velocity.x -= strafeSpeed * cos(strafeAngle)
      item.velocity.y -= strafeSpeed * sin(strafeAngle)
      particles(vec2(tx, ty), strafeAngle, 60.0.degToRad, model, smallThrust.scale, 2, smallThrust.speed)

    if keyStates.pressed(SDL_SCANCODE_S):
      item.velocity.x -= thrustSpeed * cos(angle)
      item.velocity.y -= thrustSpeed * sin(angle)
      particles(vec2(tx, ty), angle, 30.0.degToRad, model, smallThrust.scale, 5, smallThrust.speed)

    let curTime = epochTime()
    if keyStates.pressed(SDL_SCANCODE_H) and curTime - sys.lastKeyTime > 1.0:
      sys.lastKeyTime = curTime
      let health = entity.fetch Health
      health.amount = health.full
    if keyStates.pressed(SDL_SCANCODE_L) and curTime - sys.lastKeyTime > 1.0:
      sys.lastKeyTime = curTime
      sysKillEnemies.paused = false


makeSystemOpts("controlWeapon", [ReadControls, Weapon], sysOpts):
  fields:
    mouseButtons: MButtons
  
  all:
    if sys.mouseButtons.left:
      item.weapon.active = true
    else:
      item.weapon.active = false
    
    if sys.mouseButtons.right:
      item.weapon.special = true
    else:
      item.weapon.special = false

makeSystemOpts("fireWeapon", [Weapon, Position, Model, not Killed], sysOpts):
  # Handles constructing bullets from Weapon.
  let
    curTime = epochTime()

  all:
    if item.weapon.active and curTime - item.weapon.lastFired >= item.weapon.fireRate:
      # Fire!
      item.weapon.lastFired = curTime

      let
        bullet = item.weapon.bullet.construct # Build bullet entity.
        bulletSpeed = item.weapon.fireSpeed * dt
        angle = item.model.angle
      
      bullet.add ChildOf(parent: entity)

      bullet.updatePhysics(
        item.position.x,
        item.position.y,
        vec2(bulletSpeed * cos(angle), bulletSpeed * sin(angle))
      )

    if item.weapon.special and curTime - item.weapon.lastSpecialFired >= item.weapon.specialFireRate:
      # Fire bullets at a random angle from the weapon.
      item.weapon.lastSpecialFired = curTime
      
      let
        curAngle = item.model.angle

      for i in 0 ..< item.weapon.specialCount:
        let
          bullet = item.weapon.specialBullet.construct
          spread = item.weapon.specialSpread
          angle = curAngle + rand(-spread .. spread)
          bulletSpeed = (item.weapon.fireSpeed * rand(0.8 .. 1.2)) * dt

        bullet.add ChildOf(parent: entity)

        bullet.updatePhysics(
          item.position.x,
          item.position.y,
          vec2(bulletSpeed * cos(angle), bulletSpeed * sin(angle))
        )

makeSystemOpts("trails", [Position, Trail], sysOpts):
  stream 10:
    particles(
      position = vec2(item.position.x, item.position.y),
      angle = 0.0,
      spread = TAU,
      model = Model(modelId: circleModel),
      scale = rand item.trail.sizes,
      particleCount = item.trail.particles,
      speed = item.trail.speeds,
      col = item.trail.col.colRanges,
      duration = item.trail.duration
    )

makeSystemOpts("flames", [Flames, Position, Health, not Killed], sysOpts):
  
  # Create flame and smoke particles.
  let
    curTime = epochTime()
    puffEvery = 0.25
    fireDur   = 1.0
    smokeDur  = 2.0
  
  all:
    if curTime - item.flames.lastPuff >= puffEvery:
      
      item.flames.lastPuff = curTime

      template doParticles(pc: int, particleSpeed, dur, r, g, b, pScale: untyped): untyped =
        particles(
          position = vec2(item.position.x, item.position.y),
          angle = 0.0,
          spread = TAU,
          model = Model(modelId: circleModel),
          scale = pScale,
          particleCount = pc,
          speed = particleSpeed,
          col = [r,g,b],
          duration = dur
        )

      let
        healthRatio = clamp(item.health.amount / item.health.full, 0.0, 1.0)
        damage = 1.0 - healthRatio
        smokeParticles = int(8.float * damage)
        fireParticles = int(4.float * damage)

      if healthRatio < 1.0:
        
        let
          baseScale = 0.01
        
        doParticles(fireParticles,
          0.08..0.13,
          fireDur,
          r = colRange(0.8, 1.0),
          g = colRange(0.0),
          b = colRange(0.0),
          pScale = baseScale + damage * baseScale
        )

        doParticles(smokeParticles,
          0.1..0.2,
          smokeDur,
          r = colRange(0.2, 0.3),
          g = colRange(0.2, 0.3),
          b = colRange(0.0),
          pScale = baseScale + damage * baseScale
        )
        
      else:
        entity.remove Flames

makeSystemOpts("heal", [Position, Heal, Health, not Killed, not Flames], sysOpts):
  all:
    if item.health.amount < item.health.full:
      item.health.amount = clamp(
        item.health.amount + item.heal.amount * dt,
        0.0,
        item.health.full
      )
      
      if item.health.amount >= item.health.full:
        # Splash for healed.
        particles(
          position = vec2(item.position.x, item.position.y),
          angle = 0.0,
          spread = TAU,
          model = Model(modelId: circleModel),
          scale = 0.1,
          particleCount = 40,
          speed = 0.3 .. 0.7,
          col = [colRange(0.1), colRange(1.0), colRange(0.1)],
          duration = 2.0
        )

makeSystemOpts("wallPhysics", [Position, Velocity, Model, Bounce, not Killed], sysOpts):
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
      dustCount = item.bounce.dust
    
    template dust(vec: GLvectorf2): untyped =
      if dustCount > 0:
        particles(
          vec2(item.position.x, item.position.y),
          arctan2(vec[1], vec[0]),
          30.0.degToRad,
          item.model,
          dustScale,
          particleCount = dustCount,
          speed = 0.1..0.2,
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
  let
    curTime = epochTime()
  
  all:
    item.shrinkAway.normTime = 1.0 - clamp(
      (curTime - item.killAfter.startTime) / item.killAfter.duration
    , 0.0, 1.0)

makeSystemOpts("shrinkAwayModel", [ShrinkAway, Position, KillAfter, Model, not Killed], sysOpts):
  added:
    item.shrinkAway.startScale = item.model.scale
    item.shrinkAway.startCol = item.model.col
  all:
    let newScale = item.shrinkAway.startScale.xy * item.shrinkAway.normTime
    item.model.scale = vec3(newScale[0], newScale[1], item.model.scale[2])
    item.model.col = item.shrinkAway.startCol * item.shrinkAway.normTime

makeSystemOpts("shrinkAwayFont", [ShrinkAway, KillAfter, FontText], sysOpts):
  added:
    item.shrinkAway.startScale = vec3(item.fontText.scale[0], item.fontText.scale[1], 1.0)
    item.shrinkAway.startCol = item.fontText.col
  all:
    item.fontText.scale = item.shrinkAway.startScale.xy * item.shrinkAway.normTime
    item.fontText.col = item.shrinkAway.startCol * item.shrinkAway.normTime

makeSystemOpts("killEnemies", [Enemy], sysOpts):
  # This system stores a record of enemy entities and when unpaused will
  # delete them.
  init: sys.paused = true
  sys.clear
  sys.paused = true

makeSystemOpts("damageOverTime", [Position, DamageOverTime, Health, not Killed], sysOpts):
  let
    curTime = epochTime()
    speed = 0.1 * dt

  all:
    let dot = item.damageOverTime
    
    if curTime - dot.lastTick > dot.frequency:
      dot.lastTick = curTime
      let
        finalDamage = applyDamage(item.health, dot.damage)
        dCol = vec4(1.0, 0.5, 0.0, 1.0)
        pos = vec2(item.position.x, item.position.y)
        angle = rand TAU
        dir = vec2(cos(angle), sin(angle))
        textEnt = createText(
          &"{dot.damage.kind} {finalDamage:3.1f}",
          pos,
          dCol,
          duration = 1.0,
          vel = vec2(dir[0] * speed, dir[1] * speed),
          size = vec2(0.06, 0.03)
        )
      if item.health.amount <= 0:
        item.damageOverTime.source.applyScore entity

    if curTime - dot.startTime >= dot.duration:
      entity.remove DamageOverTime

makeSystemOpts("dead", [Position, Health, not Killed], sysOpts):
  all:
    if item.health.amount <= 0.0:
      let
        posVec = item.position.getVec
      
      entity.killText(posVec)
      particles(posVec, 0.0, TAU, Model(modelId: circleModel), scale = 0.03, particleCount = 20, speed = 0.2..0.4)
      entity.add Killed()

makeSystemOpts("explosionFx", [Killed, Position, Model], sysOpts):
  all:
    particles(
      vec2(item.position.x, item.position.y),
      0.0,
      TAU,
      Model(modelId: circleModel),
      scale = 0.04,
      particleCount = 50,
      speed = 0.2..0.4,
      col = item.model.col.colRanges
    )

template doBoom(gridProc: untyped) {.dirty.} =
  # Applies 'ExplodeOnDeath' damage within an area. 
  # Dirty to let us use '&' formatting.
  let
    damage = item.explodeOnDeath.damage
    (x, y) = (item.position.x, item.position.y)

  if damage.amount > 0:
    let
      expCol = item.explodeOnDeath.col
      expCols = expCol.colRanges
      particleModel = Model(modelId: circleModel)
      dRadius = damage.radius
      posVec = vec2(item.position.x, item.position.y)

    # Explosion particles for damage area.
    for i in 0 ..< 10:
      let pPos = posVec + vec2(rand -dRadius .. dRadius, rand -dRadius .. dRadius)
      particles(pPos , 0.0, TAU, particleModel, scale = 0.08, particleCount = 10, speed = 0.3..0.5, duration = 1.0,
        col = expCols)

    for entPos in gridProc(x, y, damage.radius):
      let
        hitEnt = entPos.entity
        health = hitEnt.fetch Health
      
      if health.valid:
        let
          finalDamage = hitEnt.applyDamage(health, damage, entity)
          speed = -0.01 .. 0.01
          textEnt = createText(
            &"{finalDamage:3.1f}",
            posVec,
            vec4(1.0, 0.0, 0.0, 1.0),
            duration = 1.0,
            vel = vec2(rand speed, rand speed)
          )
        if health.amount <= 0:
          entity.applyScore hitEnt

makeSystemOpts("boomPlayer", [Killed, ExplodeOnDeath, Position, PlayerGrid], sysOpts):
  # Cause area of affect damage to enemies around the entity.
  all: doBoom(queryGridPreciseEnemy)

makeSystemOpts("boomEnemy", [Killed, ExplodeOnDeath, Position, EnemyGrid], sysOpts):
  # Cause area of affect damage to players around the entity.
  all: doBoom(queryGridPrecisePlayer)

makeSystem("restartGame", [Killed, DeathTimer, Position, Model, Health]):
  all:
    if epochTime() - item.deathTimer.start > 5.0:
      level = 0

      # Delete enemies.
      sysKillEnemies.paused = false

      # Reset player state.
      item.model.col.a = 1.0
      item.health.amount = item.health.full
      item.position.x = 0.0
      item.position.y = 0.0

      let score = entity.fetch Score
      if score.valid:
        score.value = 0
      entity.add ReadControls()
      entity.remove Killed, DeathTimer, DamageOverTime

makeSystemOpts("killAfter", [KillAfter], sysOpts):
  let
    curTime = epochTime()

  all:
    if curTime - item.killAfter.startTime >= item.killAfter.duration:
      item.entity.addIfMissing Killed()

makeSystemOpts("deleteKilled", [Killed, not Player], sysOpts):
  finish: sys.clear

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
    planetBrightness = 0.1 .. 0.5
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

  texture.clearTexture
  texture.paintStars(stars)

# Set up game elements.

proc newPlayer(playerScale: GLvectorf3): EntityRef =
  let
    playerCol = vec4(1.0, 0.0, 0.0, 1.0)

    baseBullet = cl(
      Position(),
      Velocity(),
      PlayerGrid(),
      Health(amount: 0.00001),
      Bullet(),
      Bounce(dust: 1),
      ShrinkAway()
    )

  newEntityWith(
    Model(modelId: shipModels[0], scale: playerScale, col: playerCol),
    Position(),
    Velocity(),
    Health(amount: 10.0),
    Heal(amount: 0.01),
    Player(),
    PlayerGrid(),
    Bounce(dust: 10),
    ReadControls(),
    Score(),
    CollisionDamage(damage: initDamage(1.0)),
    Weapon(
      fireRate: 0.2,
      fireSpeed: 1.0,
      bullet: baseBullet & cl(
        Model(
          modelId: bulletModel,
          scale: vec3(0.02),
          col: vec4(1.0, 1.0, 0.0, 1.0)
        ),
        CollisionDamage(damage: initDamage(1.2)),
        KillAfter(duration: 1.5),
      ),
      specialFireRate: 1.0,
      specialSpread: 25.0.degToRad,
      specialCount: 8,
      specialBullet: baseBullet & cl(
        Model(
          modelId: circleModel,
          scale: vec3(0.03),
          col: vec4(0.4, 1.0, 1.0, 1.0) 
        ),
        Trail(particles: 3, col: vec4(0.4, 1.0, 1.0, 1.0)),
        CollisionDamage(damage: initDamage(1.25)),
        ExplodeOnDeath(damage: initDamage(1.1, dkFire, 0.2), col: playerCol),
        KillAfter(duration: 3.5),
      )
    )
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
      score = 1

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
        Health(amount: 10.0 / levelModifier),
        CollisionDamage(
          damage: initDamage(0.1)
        ),
        Seek(speed: rand 0.01 .. 0.03),
        ExplodeOnDeath(),
      )

    if level > 1 and rand(1.0) < 0.1:

      score += 2

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
          Bounce(dust: 0),
          Health(amount: 0.01),
          CollisionDamage(damage: initDamage(0.1)),
          KillAfter(duration: 1.5),
        )
      
      if level > 3 and rand(1.0) > level.float / 15.0:
        # Bullets seek the player at higher levels.
        bullet.add Seek(speed: 0.2)
        score += 2

      if level > 3 and rand(1.0) > level.float / 15.0:
        # Bullets seek the player at higher levels.
        bullet.add ExplodeOnDeath(damage: initDamage(0.1, dkFire, 0.1), col: enemyCol)
        score += 2

      let
        fRate = rand(1.0 .. 2.0) * levelModifier

      # This enemy fires bullets in its general direction.
      enemy.add Weapon(
        active: true,
        fireRate: fRate,
        fireSpeed: 1.0,
        lastFired: epochTime(),
        bullet: bullet
      )

      if level > 8 and rand(1.0) < 0.1 + (level.float / 50.0):
        enemy.add Heal(amount: 0.01)
    
    enemy.add Score(value: score)


# Run game.

let
  playerScale = vec3(0.035)
  player = newPlayer(playerScale)

var
  planetTex: seq[tuple[tex: GLTexture, id: TextureId]]
  planetTextures = 5
  planetRadius = sdlDisplay.res.y
  middle = sdlDisplay.res.y div 2

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
      planetOrbitEnt = newEntityWith(
        Position(
          x: rand -0.4..0.4,
          y: rand -0.4..0.4
        )
      )
    
    planets.add planetOrbitEnt

    planets.add newEntityWith(
      Position(),
      Texture(
        textureId: planetTex[rand planetTex.high].id,
        scale: vec2(scale, scale),
        col: vec4(1.0, 1.0, 1.0, 1.0)
      ),
      Orbit(
        pos: planetOrbitEnt.fetch Position,
        w: rand 0.4 .. 0.8,
        h: rand 0.4 .. 0.8,
        s: rand speed
      )
    )

sysSeekPlayer.player = player

proc main() =

  let
    (score, health) = player.fetch(Score, Health)
  var
    planets: Entities
    
    backgroundTex = newTextureId(max = 1)
    backgroundImage: GLTexture
    mouseButtons: MButtons
    frameCount: int
    lastFPSUpdate: float
    lastFrame: float

  proc redrawBackground(bg: EntityRef) =
    backgroundImage.initTexture(sdlDisplay.res.x, sdlDisplay.res.y)
    backgroundImage.paintBackground
    backgroundTex.update(backgroundImage)
    bg.fetch(Texture).scale[0] = sdlDisplay.aspect

  let
    textScale = vec2(0.1, 0.025)
    textYPad = 0.02
    textLeft = -0.85
  var
    textY = 0.95 - textScale.y

  let scoreDisplay = newEntityWith(fontText(font, $score.value, vec3(textLeft, textY, fontZ), vec4(1.0, 1.0, 0.0, 0.5), textScale))
  textY -= textScale.y + textYPad
  let levelDisplay = newEntityWith(fontText(font, "Level 1", vec3(textLeft, textY, fontZ), vec4(1.0, 1.0, 0.0, 0.5), textScale))
  textY -= textScale.y + textYPad
  let healthDisplay = newEntityWith(fontText(font, "Health", vec3(textLeft, textY, fontZ), vec4(1.0, 1.0, 0.0, 0.5), textScale))
  textY -= textScale.y + textYPad
  let fpsDisplay = newEntityWith(fontText(font, "FPS", vec3(textLeft, textY, fontZ), vec4(1.0, 1.0, 0.0, 0.5), textScale))
  textY -= textScale.y + textYPad
  let entDisplay = newEntityWith(fontText(font, "Entities", vec3(textLeft, textY, fontZ), vec4(1.0, 1.0, 0.0, 0.5), textScale))

  let
    scoreText = scoreDisplay.fetch FontText
    levelText = levelDisplay.fetch FontText
    healthText = healthDisplay.fetch FontText
    fpsText = fpsDisplay.fetch FontText
    entText = entDisplay.fetch FontText
    
    background {.used.} = newEntityWith(
      Position(z: 0.6),
      Texture(
        textureId: backgroundTex,
        scale: vec2(1.0, 1.0),
        col: vec4(1.0, 1.0, 1.0, 1.0)
      )
    )

  planets.genPlanets()

  # Game loop.
  pollEvents:
    # Handle other events.
    
    if event.kind == MouseButtonDown:
      var mb = evMouseButton(event)
      if mb.button == BUTTON_LEFT: mouseButtons.left = true
      if mb.button == BUTTON_RIGHT: mouseButtons.right = true
    elif event.kind == MouseButtonUp:
      var mb = evMouseButton(event)
      if mb.button == BUTTON_LEFT: mouseButtons.left = false
      if mb.button == BUTTON_RIGHT: mouseButtons.right = false

  do:
    # Main loop.

    if sdlDisplay.changed:
      # Display has been resized.
      redrawBackground(background)
      setTextureAspectRatios(sdlDisplay.aspect)

    if sysKillEnemies.count == 0:
      # All enemies have been killed, create a new level.

      level += 1
      levelText.text = "Level " & $level
      
      let
        pos = player.fetch Position

      createLevel(level, vec2(pos.x, pos.y), 0.4)

      redrawBackground(background)
      planets.genPlanets()

    sysControls.mousePos = mouseInfo.gl
    sysControlWeapon.mouseButtons = mouseButtons

    scoreText.text = &"Score: {score.value}"

    let
      frameTime = epochTime()
    
    if frameTime - lastFrame >= dt:
      lastFrame = frameTime
      run()

    doubleBuffer:
      
      frameCount += 1

      if frameTime - lastFPSUpdate >= 1.0:
        lastFPSUpdate = frameTime

        let
          healthRatio = clamp(health.amount / health.full, 0.0, 1.0)
        
        healthText.col = mix(vec4(1.0, 0.0, 0.0, 0.8), vec4(0.0, 1.0, 0.0, 0.8), healthRatio)
        healthText.text = &"Health: {healthRatio * 100.0:3.1f}%"
        entText.text = "Entities: " & $entityCount()
        fpsText.text = "FPS: " & $frameCount
        frameCount = 0

      renderActiveTextures()
      renderActiveModels()
      renderFonts()


main()
flushGenLog()