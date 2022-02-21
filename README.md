# Overview

`Polymers` is a library of components and systems for the [Polymorph](https://github.com/rlipsc/polymorph) entity-component-system generator.

The library provides components for common tasks to support developing software in a data orientated style. These components can freely be combined and built upon with user made components and systems.

The components primarily support Windows but some will also run on other platforms if there's a backend available.

## Using

Importing the library will give access to all the define templates, but doesn't define anything or generate any code unless these templates are used.

Using the define templates will register their components with the current ECS. Some components supply separate templates to register their systems so that the order of execution can be controlled.

For example, you may wish to register graphics components for your ECS, then run the GPU update systems at a specific point in your execution.

For more information on using Polymorph, see the [manual](https://github.com/rlipsc/polymorph/blob/master/README.md).

Below is an example of the TCP/IP components sending and receiving data:

```nim
import polymorph, polymers

defineTcpNetworking(fixedSizeComponents(100), defaultSysOpts, tllEvents)

makeSystem("serverRead", [TcpRecv, TcpRecvComplete]):
  fields:
    gotMessage: bool
  all:
    echo "Server received message: ", item.tcpRecv.data
    sys.gotMessage = true

makeEcs()
commitSystems "poll"

let
  port = 1234.Port
  server = newEntityWith(TcpListen(port: port))
  client = newEntityWith(
    TcpConnection(
      remoteAddress: "127.0.0.1",
      remotePort: port),
    TcpSend(data: "Hello"))

while not sysServerRead.gotMessage:
  poll()
```

The `tllEvents` parameter creates a log of packet activity:

![polymerstcplog](https://user-images.githubusercontent.com/36367371/128614555-c138dd59-6614-480c-9508-774527e39299.png)

# Demos

Many component modules include a demonstration of how they can be used when run as the main module. The `demos` folder contains various more complex examples of using the components together.

The graphics demos use SDL2 to set up the rendering window.

- `modelsandtextures`: uses the OpenGL components to render a million particles that react to the mouse.

https://user-images.githubusercontent.com/36367371/155025607-7dfd735b-be17-4b4c-8a4e-592de6037289.mp4

- `dbbrowser` (and `dbbrowserthreads`): uses the console and database components to create a command line database table browser.

- `consolemousebuttons`: uses the console components to create a text based button UI that can be interacted with using the mouse.

- `netspeedtest`: measures the speed of sending/receiving UDP packets on localhost by counting how many arrive within a set time frame.

- `jsonrpc_ecsinfo`: uses the networking components to serve a JSON RPC over HTTP for listing the current entities.

- `simplewebsite`: uses the networking components to serve a webpage with a default page that displays view count and a `/time` URL that displays the current time.

- `spaceshooter2d`: a 2D space shooter game using the OpenGL components.

https://user-images.githubusercontent.com/36367371/128614604-3d3c4e2e-97a4-4c29-98e9-7554a68a20f8.mp4

- `particlelife`: an implementation of the "Primordial Particle System" described [here](https://www.nature.com/articles/srep37969)

https://user-images.githubusercontent.com/36367371/124841111-6d751980-df84-11eb-85c0-90280f2dca1f.mp4

- `chipmunkballpit`: uses the Chipmunk2D and OpenGL components to simulate balls in a box. Use the mouse to move them about.

https://user-images.githubusercontent.com/36367371/124198657-04475f00-dac9-11eb-9000-fda888b270ff.mp4

# Included Components

## Graphics

### Module ecs_opengl

Uses [glbits](https://github.com/rlipsc/glbits) to render models and textures with OpenGL.

Pass in your own position component or use the default `Position`.

- **Model**: displays a 3D model at the coordinates in the position component. The model is rendered with vertex buffer/array objects and instanced rendering, so is performant even with hundreds of thousands of instances.

- **Texture**: displays a texture billboard instance at the coordinates in the position component.

## Physics

### Module ecs_chipmunk2d

Uses [chipmunk2d](https://chipmunk-physics.net/) to simulate physics.

- **PhysicsBody**: a wrapper for the `chipmunk.body` object.

- **PhysicsShape**: a wrapper for `chipmunk.shape` objects.

- **BodyTemplate**: substituted on construction with `PhysicsBody`.

- **ShapeTemplate**: substituted on construction with `PhysicsShape`.

## Database

There are two version of the database components, `ecs_db_threads` for threaded queries and `ecs_db` for non-threaded queries.

These use the `odbc` library found [here](https://github.com/coffeepots/odbc).

- **ConnectToDb**: initiates a connection to the database with its contained parameters. Once connection is established, it is removed and a **DatabaseConnection** component is added to the entity.

- **Query**: performs a query when a **DatabaseConnection** is present. When a result is obtained, it is placed within a **QueryResult** component and added to the entity.

## Networking

### Module ecs_tcp

Uses Windows IO completion ports for high speed networking.

- **TcpConnection**: used to connect to an address.

- **TcpConnected**: indicates connection has completed.

- **TcpRecv**: reads data from an accepted connection.

- **TcpRecvComplete**: indicates data has finished being received.

- **TcpSend**: send some data to a `TcpConnection`.

- **TcpSendComplete**: indicates a send operation has completed.

- **TcpListen**: waits for an incoming connection and spawns a `ComponentList` when a connection is accepted.

- **TcpErrors**: records TCP errors.

### Module ecs_udp

- **UDPRead**: tag an entity with this component to subscribe to incoming `UDPData` packets delivered within `UDPIncoming` components.

- **UDPSend**: adding this component causes a UDP message to be sent to the parameter host and port.

## Console

### Module ecs_renderchar

- **RenderChar**: this component efficiently outputs a single character to the console, controllable with x and y coordinates normalised to `-1.0 .. 1.0`. This allows easy creation of text driven interfaces or outputs that more closely resemble rendering with graphics.

- **RenderString**: a string of entities with `RenderChar` components, managed so you can set the `text` property and a normalised (x, y) coordinate. The constituent entities and components are accessible to edit, and handles clipping to the desired width/borders.

- **DensityChar**: this component updates the character displayed in a `RenderChar` according to the number of `RenderChar` entities present in a particular character position. This gives a simple way to display multiple entities that are close together.

### Module ecs_consoleevents

- **ConsoleInput**: receive console input event components.

- **KeyInput**, **KeyChange**: receive key press events.

- **MouseInput**: receive all mouse event components.

- **MouseMoving**, **MouseButtons**: receive specific mouse events. 

- **WindowChange**: receive events for the console window changing size. 

### Module ecs_mousebuttons

This module uses `ecs_renderchar` and `ecs_consoleevents` to create mouse driven textual UI 'buttons'.

- **MouseButton**: allows defining a size, text alignment, background and border options. Full access to the **RenderChar** entities is given so they may be edited. Generates event components such as **MouseButtonClicked** and **MouseButtonMouseOver** for systems to respond to.

- **DrawMouse**: tag an entity with this component so that its character is drawn at the mouse location.

### Module ecs_editstring

- **EditString**: editable string for reading input from the user in the console.

- **InputFinished**: indicates the `EditString` has received a return or escape input.

## Miscellaneous

### Module ecs_spawnafter

- **SpawnAfter**: generates a `construction` (a template of entities) after a given time frame. Useful for performing some task after some delay without blocking.

### Module ecs_killing

- **Killed**: this tag component can be used to handle clean up operations within a frame of execution. Create systems that use `Killed` along with other components to handle things like freeing resources owned by a component at the correct stage of system execution, rather than calling `delete` directly. Invoke `addKillingSystem` at the appropriate time to actually `delete` entities after any clean up work has been finished. 

- **KillAfter**: add `Killed` to an entity after a set duration. Useful for temporary entities that might have resources that need appropriate finalisation, or just 'fire and forget' temporary entities.

