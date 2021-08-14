# v0.3.1 2021-8-14

## Changed

- Restructure folders for Nimble.

## Fixed

- ecs_http: no longer emits the HoleEnumConv warning.
- Fewer compiler warning messages.

# v0.3.0 2021-8-7

## Added

- Networking components
  - ecs_tcp: components for sending/receiving data over sockets with windows IOCP.
  - ecs_http: components for using the HTTP protocol with ecs_tcp.
  - ecs_jsonrpc: components for serving remote procedure calls with JSON over ecs_http.
  - ecs_gridmap: a grid based spatial mapping component.

- Demos
  - chipmunkballpit: uses Chipmunk2D to simulate the physics of 5,000 entities.
  - jsonrpc_ecsinfo: reports entities and their components via HTTP JSON RPC.
  - particledemo: simulate 250K particles interacting with the mouse.
  - particlelife: animates particles with a simple rule to create organic looking structures.
  - spaceshooter: a simple top down 2D shooter with ecs_opengl and SDL2.
  - simplewebsite: a web server built from the networking components.

# v0.2.0 2020-5-6

- Rename to Polymers.

# v0.1.1 2020-4-7

- Fix: dependency on odbc when not actively used.
- More consistent filenames.
- Components:
  - OpenGL instanced rendering.

# v0.1.0 2020-2-16

- Initial release.
- Components:
  - Console events,
  - ODBC database queries,
  - Delayed spawning and removal management,
  - UDP messages.

