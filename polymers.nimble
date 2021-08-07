packageName   = "Polymers"
version       = "0.3.0"
author        = "Ryan Lipscombe"
description   = "A library of components for the Polymorph ECS"
license       = "Apache License 2.0"

requires "nim >= 1.4.0", "https://github.com/rlipsc/polymorph#head"

task test, "Test compiling Polymers":
  when defined(windows):
    exec "nim c console/ecs_consoleevents.nim"
    exec "nim c console/ecs_editstring.nim"
    exec "nim c console/ecs_mousebuttons.nim"
    exec "nim c console/ecs_renderchar.nim"

    exec "nim c network/ecs_tcp.nim"
    exec "nim c network/ecs_http.nim"
    exec "nim c network/ecs_jsonrpc.nim"
    exec "nim c network/ecs_udp.nim"

    exec "nim c demos/consolemousebuttons.nim"
    exec "nim c demos/particledemo.nim"
    exec "nim c demos/particlelife.nim"
    exec "nim c demos/spaceshooter.nim"
    exec "nim c demos/dbbrowser.nim"
    exec "nim c --threads:on demos/dbbrowserthreads.nim"
    exec "nim c demos/netspeedtest.nim"
    exec "nim c demos/simplewebsite.nim"

  exec "nim c db/ecs_db.nim"
  exec "nim c graphics/ecs_opengl.nim"
  exec "nim c misc/ecs_killing.nim"
  exec "nim c misc/ecs_spawnafter.nim"
  exec "nim c physics/ecs_chipmunk2D.nim"
  exec "nim c spatial/ecs_gridmap.nim"
