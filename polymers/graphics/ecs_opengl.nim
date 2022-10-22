import polymorph
from strutils import toLowerAscii

template defineOpenGlComponents*(compOpts: ECSCompOptions, positionType: typedesc) {.dirty.} =
  ## Define the following components using the 'glbits' library:
  ## 
  ##  - Model: render a 3D model
  ##  - Texture: render a texture billboard
  ## 
  when not declared(opengl):
    import opengl
  when not declared(glbits):
    import glbits
  when not declared(modelrenderer):
    import glbits/modelrenderer
  
  ecsImport opengl, glbits, glbits/modelrenderer

  type
    TextureId* = distinct int

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

      ModelHidden* = object
      
      TextureHidden* = object


template defineOpenGLRenderGroup*(name: string) {.dirty.} =
  ## Pull the GPU update systems into a separate group along with a
  ## system to render them.
  ## 
  ## To output the group, use `commitGroup` with `name`.
  makeSystem "renderModelsTextures":
    renderActiveModels()
    renderActiveTextures()
  defineGroup(name, ["updateModelData", "updateTextureData", "renderModelsTextures"])

template defineOpenGLUpdateSystems*(sysOpts: ECSSysOptions, positionType: typedesc): untyped {.dirty.} =
  ## Add the system to send model and position data to the GPU.

  # Defer imports to where systems are committed.
  ecsImport glbits, glbits/modelrenderer


  makeSystemOpts("updateModelData", [Model, pos: positionType, not ModelHidden], sysOpts):
    # This system populates the instance buffers and keeps track of
    # how many instances need to be rendered per model.

    fields:
      curModelCount {.pub.}: seq[int]

    # Init model info.
    sys.curModelCount.setLen modelCount()

    for i in 0 ..< sys.curModelCount.len:
      sys.curModelCount[i] = 0

    all:
      # Populate instance buffers.
      let mId = item.model.modelId
      assert mId.int in 0 ..< sys.curModelCount.len,
        "ModelId " & $mId.int &
        " is not registered as a model (available: 0 ..< " &
        $sys.curModelCount.len & ")"

      let curPos = sys.curModelCount[mId.int]
      
      mId.positionVBOArray[curPos] = vec3(pos.x, pos.y, pos.z)
      mId.scaleVBOArray[curPos] = model.scale
      mId.rotationVBOArray[curPos] = [model.access.angle]
      mId.colVBOArray[curPos] = model.col

      sys.curModelCount[mId.int].inc


  makeSystemOpts("updateTextureData", [Texture, pos: positionType, not TextureHidden], sysOpts):
    # This system populates billboard instances.
    
    fields:
      billboards {.pub.}: seq[TexBillboard]
      rectangleModel {.pub.} -> array[6, TextureVertex] =
        [
          [-1.0.GLFloat, 1.0, 0.0,    0.0, 1.0],
          [1.0.GLFloat, 1.0, 0.0,     1.0, 1.0],
          [-1.0.GLFloat, -1.0, 0.0,   0.0, 0.0],
          #
          [1.0.GLFloat, -1.0, 0.0,    1.0, 0.0],
          [-1.0.GLFloat, -1.0, 0.0,   0.0, 0.0],
          [1.0.GLFloat, 1.0, 0.0,     1.0, 1.0]
        ]

    # Init texture info.
    for i in 0 ..< sys.billboards.len:
      sys.billboards[i].resetItemPos

    all:
      # Populate instances.
      let
        tId = item.texture.textureId
      
      sys.billboards[tId.int].addItems(1):
        curItem.positionData =  vec4(pos.x, pos.y, pos.z, 1.0)
        curItem.colour =        item.texture.col
        curItem.rotation[0] =   item.texture.angle
        curItem.scale =         item.texture.scale

  onEcsBuilt:

    # Models

    iterator activeModels*: tuple[model: ModelId, count: int] =
      ## Iterate models that have a non-zero count and been processed by
      ## the updateModelData system.
      for modelIndex in 0 ..< modelCount():
        if modelIndex < sysUpdateModelData.curModelCount.len:
          let count = sysUpdateModelData.curModelCount[modelIndex]
          if count > 0:
            yield (modelByIndex(modelIndex), count)


    proc renderActiveModels* {.inject.} =
      ## Render only models that have been processed by `updateModelData`.
      for modelInfo in activeModels():
        renderModel(modelInfo.model, modelInfo.count)


    template renderActiveModelsSetup*(setup: untyped) =
      ## Render only models that have been processed by `updateModelData`.
      ## Code in `setup` will be run before each model is rendered.
      for modelInfo in activeModels():
        renderModelSetup(modelInfo.model, modelInfo.count, setup)


    proc setModelTransform*(matrix: GLmatrixf4) =
      for modelInfo in activeModels():
        modelInfo.model.setTransform matrix

    # Textures

    proc newTextureId*(vertexGLSL = defaultTextureVertexGLSL, fragmentGLSL = defaultTextureFragmentGLSL,
        max = 1, model: openarray[TextureVertex] = sysUpdateTextureData.rectangleModel, modelScale = 1.0, manualTextureBo = false, manualProgram = false): TextureId =
      
      sysUpdateTextureData.billboards.add newTexBillboard(vertexGLSL = vertexGLSL, fragmentGLSL = fragmentGLSL, max = max, model = model,
        modelScale = modelScale, manualTextureBo = manualTextureBo, manualProgram = manualProgram)
      result = sysUpdateTextureData.billboards.high.TextureId
      sysUpdateTextureData.billboards[result.int].rotMat[0] = 1.0
    

    proc update*(textureId: TextureId, texture: GLTexture) =
      sysUpdateTextureData.billboards[textureId.int].updateTexture(texture)


    proc renderActiveTextures* = 
      ## Render only textures that have been processed by `updateTextureData`.
      for i in 0 ..< sysUpdateTextureData.billboards.len:
        sysUpdateTextureData.billboards[i].render


    proc setTextureTransform*(matrix: GLmatrixf4) =
      for i in 0 ..< sysUpdateTextureData.billboards.len:
        sysUpdateTextureData.billboards[i].setTransform matrix


template defineOpenGlRenders*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions, positionType: typedesc) {.dirty.} =
  defineOpenGLComponents(compOpts, positionType)
  defineOpenGLUpdateSystems(sysOpts, positionType)


template defineOpenGlPosition*(compOpts: ECSCompOptions, typeName: untyped) {.dirty.} =
  registerComponents(compOpts):
    type
      typeName* = object
        x*, y*, z*: GLfloat


template defineOpenGlRenders*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  defineOpenGlPosition(compOpts, Position)
  defineOpenGLComponents(compOpts, Position)
  defineOpenGLUpdateSystems(sysOpts, Position)


when isMainModule:
  ## A 3D starfield demo.

  import glbits, sdl2, math, random

  defineOpenGlPosition(defaultCompOpts, Pos)
  defineOpenGlRenders(defaultCompOpts, defaultSysOpts, Pos)
  register defaultCompOpts:
    type
      Vel = GLvectorf3
      Speed = GLfloat
      Col = GLvectorf4

  initSdlOpenGl(800, 600)
  let
    maxEnts = when not defined(release): 50_000 else: 1_000_000
    shaderProg = newModelRenderer()
    circle = shaderProg.makeCircleModel(12, vec4(0.6), vec4(0), maxInstances = maxEnts)

  makeSystem "move", [Pos, Vel, Speed]:
    fields:
      nearZ = 0.0
      farZ = -20.0
      extent -> Slice[GLfloat] = -2'f32 .. 2.0'f32
    all:
      vel.update vel.access * 0.9
      vel.z += speed.access
      pos.x += vel.x
      pos.y += vel.y
      pos.z += vel.z
      if pos.x notin sys.extent: pos.x = rand sys.extent
      if pos.y notin sys.extent: pos.y = rand sys.extent
      if pos.z notin sys.farZ..sys.nearZ: pos.z = sys.nearZ

  makeSystem "col", [Pos, Col, Model]:
    let (n, dist) = (sysMove.nearZ, sysMove.farZ - sysMove.nearZ)
    all:
      let normZ = (pos.z - n) / dist
      model.col = col.access.brighten 1'f32 - normZ

  makeEcsCommit "tick"

  let extent = sysMove.extent
  for i in 0 ..< maxEnts - entityCount():
    discard newEntityWith(
      Pos(x: rand extent, y: rand extent, z: rand sysMove.farZ .. sysMove.nearZ),
      Vel(vec3(0)),
      Speed(rand -0.0028 .. -0.0004),
      Col(vec4(rand 1.0, rand 1.0, rand 1.0, 0.5)),
      Model(modelId: circle, scale: vec3(0.05)),
    )

  let
    fov = 45.0.degToRad
    zNear = 0.1
    zFar = 100.0
  var
    camPos = vec3(0, 0, 4)
    camFocus = vec3(0, 0, 0)
    projection = perspectiveMatrix(fov, aspect = sdlDisplay.aspect, zNear, zFar)
    view = viewMatrix(camPos, camFocus) # Translate from world to view space.

  view.lookAt(camPos, camFocus)
  circle.setTransform projection * view

  pollEvents:
    if sdlDisplay.changed:
      projection = perspectiveMatrix(fov, aspect = sdlDisplay.aspect, zNear, zFar)
      circle.setTransform projection * view

    tick()
    doubleBuffer:
      renderActiveModels()
