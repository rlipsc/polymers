packageName   = "polymers"
version       = "0.3.1"
author        = "Ryan Lipscombe"
description   = "A library of components and systems for the Polymorph ECS"
license       = "Apache License 2.0"

requires "nim >= 1.4.0", "https://github.com/rlipsc/polymorph#head"

task test, "Test compiling Polymers":
  when defined(windows):
    exec "nim c polymers/console/ecs_consoleevents.nim"
    exec "nim c polymers/console/ecs_editstring.nim"
    exec "nim c polymers/console/ecs_mousebuttons.nim"
    exec "nim c polymers/console/ecs_renderchar.nim"

    exec "nim c polymers/network/ecs_tcp.nim"
    exec "nim c polymers/network/ecs_http.nim"
    exec "nim c polymers/network/ecs_jsonrpc.nim"
    exec "nim c polymers/network/ecs_udp.nim"

    exec "nim c polymers/demos/consolemousebuttons.nim"
    exec "nim c polymers/demos/sdl2_opengl/particledemo.nim"
    exec "nim c polymers/demos/sdl2_opengl/particleevolve.nim"
    exec "nim c polymers/demos/sdl2_opengl/spaceshooter.nim"
    exec "nim c polymers/demos/sdl2_opengl/modelsandtextures.nim"
    exec "nim c polymers/demos/dbbrowser.nim"
    exec "nim c --threads:on polymers/demos/dbbrowserthreads.nim"
    exec "nim c polymers/demos/web/netspeedtest.nim"
    exec "nim c polymers/demos/web/simplewebsite.nim"

  exec "nim c polymers/db/ecs_db.nim"
  exec "nim c polymers/graphics/ecs_opengl.nim"
  exec "nim c polymers/misc/ecs_killing.nim"
  exec "nim c polymers/misc/ecs_spawnafter.nim"
  exec "nim c polymers/physics/ecs_chipmunk2D.nim"
  exec "nim c polymers/spatial/ecs_gridmap.nim"
