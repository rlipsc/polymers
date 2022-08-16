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

  proc renderedSize*(fontText: FontText): GLvectorf2 =
    fontText.tc.renderedSize

  proc col*(fontText: FontText): GLvectorf4 = fontText.tc.col

  proc `col=`*(fontText: var FontText, col: GLvectorf4) =
    fontText.tc.col = col

  proc angle*(fontText: var FontText): float =
    fontText.tc.fontAngle

  proc `angle=`*(fontText: var FontText, angle: float) =
    fontText.tc.fontAngle = angle

template defineFontTextSystems*(sysOpts: EcsSysOptions): untyped {.dirty.} =
  ## Outputs the `renderFonts` proc to render fonts to texture.

  makeSystemOpts("drawFontText", [FontText], sysOpts):
    fields:
      lastScreenRes: GLvectorf2
      screenRes {.public.} = vec2(-1)
    
    if sys.lastScreenRes != sys.screenRes:
      sys.lastScreenRes = sys.screenRes
      all:
        setScreenRes(fontText.tc, sys.screenRes)

    all:
      if likely(not item.fontText.hidden):
        render(item.fontText.tc)
  
  defineGroup "renderFonts", ["drawFontText"]
  ecsImport sdl2/ttf

  onEcsBuilt:

    commitGroup "renderFonts", "renderFonts"

    proc setFontScreenSize*(x, y: cint) =
      ## Helper to simplify changing the screen resolution.
      sysDrawFontText.screenRes = vec2(x.float32, y.float32)
      doDrawFontText()

    proc fontText*(font: FontPtr, text: string, col = vec4(1.0, 1.0, 1.0, 1.0), pos = vec3(0.0), fixedScale = vec2(0.0)): FontText =
      ## Create a `FontText` component.
      ## The scale is defined by the font's point size. To provide a fixed scale, set `fixedScale` to a non-zero `GLvectorf2`.
      result = FontText(tc: initTextCache())
      result.tc.setScreenRes sysDrawFontText.screenRes
      result.tc.font = font
      result.tc.text = text
      result.tc.position = pos
      result.tc.setFixedScale fixedScale
      result.tc.col = col


template defineFontText*(compOpts: ECSCompOptions, sysOpts: EcsSysOptions) {.dirty.} =
  defineFontTextComponents(compOpts)
  defineFontTextSystems(sysOpts)


when isMainModule:
  # Requires access to SDL2.dll, SDL2_ttf.dll and the tff font file
  # from the current directory.

  import sdl2, opengl, glbits/glrig, os, glbits, sdl2/ttf, glbits/[glrig, fonts]
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
      var p = item.fontText.position
      p.xy = p.xy + item.velocity.value
      if p.x <= -1.0:
        p.x = -1.0
        item.velocity.value[0] *= -1.0
      if p.x >= 1.0:
        p.x = 1.0
        item.velocity.value[0] *= -1.0
      if p.y <= -1.0:
        p.y = -1.0
        item.velocity.value[1] *= -1.0
      if p.y >= 1.0:
        p.y = 1.0
        item.velocity.value[1] *= -1.0
      item.fontText.position = p

  makeEcs()
  commitSystems("run")

  setFontScreenSize sdlDisplay.w, sdlDisplay.h

  let
    font = staticLoadFont(currentSourcePath.splitFile.dir.joinPath r"Orbitron Bold.ttf", 21)
    textEnt =
      newEntityWith(
        fontText(font, "abcdef ABCDEF"),
        Velocity(value: vec2(0.001, 0.002)),
        Spin(speed: 0.2.degToRad)
      )

  pollEvents:
    doubleBuffer:
      run()
      renderFonts()
