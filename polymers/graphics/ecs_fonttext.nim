import polymorph

template defineFontTextComponents*(compOpts: ECSCompOptions) {.dirty.} =
  const req {.used.} = "FontText requires importing "
  when not declared(opengl): {.fatal: req & "opengl".}
  when not declared(glbits): {.fatal:  req & "glbits".}
  when not declared(ttfInit):
    import sdl2/ttf
  when not declared(TextCache):
    import glbits/fonts
  
  ecsImport glbits/fonts

  ttfInit()

  registerComponents(compOpts):
    type
      FontText* = object
        tc*: TextCache
        hidden*: bool

  FontText.onRemove:
    curComponent.tc.freeTexture

  proc text*(fontText: FontText): string = fontText.tc.text

  proc `text=`*(fontText: var FontText, text: string) =
    fontText.tc.text = text

  proc position*(fontText: FontText): GLvectorf3 =
    fontText.tc.position

  proc `position=`*(fontText: var FontText, pos: GLvectorf3) =
    fontText.tc.position = pos

  proc `position=`*(fontText: var FontText, pos: GLvectorf2) =
    fontText.tc.position = pos

  proc fixedScale*(fontText: FontText): GLvectorf2 = fontText.tc.fixedScale

  proc setFixedScale*(fontText: var FontText, scale: GLvectorf2) =
    fontText.tc.setFixedScale scale
  
  onEcsBuilt:
    proc setFixedScale*(fontText: FontTextInstance, scale: GLvectorf2) =
      fontText.tc.setFixedScale scale

  proc renderedScale*(fontText: FontText): GLvectorf2 =
    fontText.tc.renderedScale

  proc col*(fontText: FontText): GLvectorf4 = fontText.tc.col

  proc `col=`*(fontText: var FontText, col: GLvectorf4) =
    fontText.tc.col = col

  proc angle*(fontText: var FontText): float =
    fontText.tc.fontAngle

  proc `angle=`*(fontText: var FontText, angle: float) =
    fontText.tc.fontAngle = angle

  proc setTransform*(fontText: var FontText, matrix: GLmatrixf4) =
    fontText.tc.setTransform matrix

template defineFontTextUpdateSystem*(sysOpts: EcsSysOptions): untyped {.dirty.} =
  ## Outputs a system to render the font text to the internal texture
  ## separately from drawing the resultant texture to the display.
  ## 
  ## Separating rendering of the font text to texture from the rendering
  ## of this texture to the display can be useful if you need to get the
  ## dimensions of the font text or perform further processing.
  ## 
  ## The font text texture is cached until the text is changed, and
  ## therefore does not repeat work when rendered to the display by the
  ## "drawFontText" system.
  ## 
  ## Note:
  ## 
  ## This system is output inline and is part of the general
  ## system flow (unless it is manually assigned ti a group), whereas
  ## display rendering is assigned to the "renderFonts" group and must
  ## be called directly.
  ## 
  ## It is therefore possible to use `defineFontText` then
  ## use `defineFontTextUpdateSystem` at the desired order in your
  ## system flow to render the font text texture.
  makeSystemOpts("updateFontText", [FontText], sysOpts):
    all:
      if likely(not item.fontText.hidden):
        renderText(item.fontText.tc)


template defineFontTextSystems*(sysOpts: EcsSysOptions): untyped {.dirty.} =
  ## Outputs the `renderFonts` proc to render fonts to texture.

  defineToGroup "renderFonts":
    makeSystemOpts("drawFontText", [FontText], sysOpts):
      fields:
        lastRes: GLvectorf2
        resolution {.public.} = vec2(-1)
      
      if sys.lastRes != sys.resolution:
        sys.lastRes = sys.resolution
        all: fontText.tc.resolution = sys.resolution

      all:
        if likely(not item.fontText.hidden):
          render(item.fontText.tc)
  
  ecsImport sdl2/ttf

  onEcsBuilt:

    commitGroup "renderFonts", "renderFonts"

    proc setFontTransform*(matrix: GLmatrixf4) =
      for row in sysDrawFontText.groups:
        row.fontText.access.setTransform matrix

    proc setFontScreenScale*(x, y: cint) =
      ## Helper to simplify changing the resolution used to map point
      ## size to render dimensions.
      sysDrawFontText.resolution = vec2(x.float32, y.float32)
      doDrawFontText()

    proc fontText*(font: FontPtr, text: string, col = vec4(1.0, 1.0, 1.0, 1.0), pos = vec3(0.0), fixedScale = vec2(0.0)): FontText =
      ## Create a `FontText` component.
      ## The scale is defined by the font's point size. To provide a fixed scale, set `fixedScale` to a non-zero `GLvectorf2`.
      result = FontText(tc: initTextCache())
      result.tc.resolution = sysDrawFontText.resolution
      result.tc.font = font
      result.tc.text = text
      result.tc.position = pos
      result.tc.setFixedScale fixedScale
      result.tc.col = col


template defineFontText*(compOpts: ECSCompOptions, sysOpts: EcsSysOptions) {.dirty.} =
  defineFontTextComponents(compOpts)
  defineFontTextUpdateSystem(sysOpts)
  defineFontTextSystems(sysOpts)


when isMainModule:
  # Requires access to SDL2.dll, SDL2_ttf.dll and the tff font file
  # from the current directory.

  import sdl2, opengl, glbits/glrig, os, glbits, sdl2/ttf, glbits/[glrig, fonts], random
  from math import degToRad, TAU, `mod`

  initSdlOpenGl()
  
  const
    cOpts = defaultCompOpts
    sOpts = defaultSysOpts

  defineFontText(cOpts, sOpts)

  registerComponents cOpts:
    type
      Velocity = object
        value: GLvectorf2
      Spin = object
        speed: float

  makeSystemOpts("spin", [FontText, Spin], sOpts):
    all:
      let
        a = item.fontText.angle
        b = (a + item.spin.speed) mod TAU
      item.fontText.angle = b

  makeSystemOpts("bounce", [FontText, Velocity], sOpts):
    all:
      var p = fontText.position
      p.xy = p.xy + velocity.value
      if p.x <= -1.0:
        p.x = -1.0
        velocity.value[0] = abs(velocity.value[0])
      if p.x >= 1.0:
        p.x = 1.0
        velocity.value[0] = -abs(velocity.value[0])
      if p.y <= -1.0:
        p.y = -1.0
        velocity.value[1] = abs(velocity.value[0])
      if p.y >= 1.0:
        p.y = 1.0
        velocity.value[1] = -abs(velocity.value[0])
      fontText.position = p

  makeEcs()
  commitSystems("run")

  setFontScreenScale sdlDisplay.w, sdlDisplay.h

  let
    font = staticLoadFont(currentSourcePath.splitFile.dir.joinPath r"Orbitron Bold.ttf", 21)
    ents = 100
    speed = -0.002..0.002
  for i in 0 ..< ents:
    discard newEntityWith(
      fontText(
        font,
        "abcdef ABCDEF",
        col = vec4(rand 1.0, rand 1.0, rand 1.0, 0.5),
        pos = vec3(rand -1.0..1.0, rand -1.0..1.0, 0.0)
      ),
      Velocity(value: vec2(rand speed, rand speed)),
      Spin(speed: (rand -0.2..0.2).degToRad + rand(-0.01..0.01))
    )

  assert not font.isNil
  pollEvents:
    
    doubleBuffer:
      run()
      renderFonts()
