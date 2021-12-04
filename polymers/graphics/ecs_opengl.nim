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
      ## Iterate models that have a non-zero count and been processed by
      ## the updateModelData system.
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
      ## Code in `setup` will be run before each model is rendered.
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

