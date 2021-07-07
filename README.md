# Polymers

`Polymers` is a library of components and systems for [Polymorph](https://github.com/rlipsc/polymorph). Polymorph generates entity component systems that are statically optimised for the components and systems used.

The `Polymers` library provides components for common tasks to support developing software in a data orientated style. Components can freely be combined at run-time to invoke their systems, and built on through user made components and systems.

## Using

Each set of components includes registration templates that allow passing code generation options and gives control over the order systems are instantiated.

`import polymers` will give access to all the define templates, but doesn't define anything or generate any code unless these templates are invoked.

To use components in your ECS, use the relevant define template to register components/systems before the ECS is sealed with `makeEcs`.

Some components supply separate templates to add their system bodies, for example if the order of their execution is important within a larger work flow. Order is defined by the sequence that `makeSystem` and/or `makeSystemBody` are encountered before `commitSystems`.

Order only affects the generated wrapper proc made by `commitSystems`. Systems can be run in any order by calling individual system update procedures.

Many component modules include a demonstration of how they can be used when run as the main module, and the `demos` folder contains various more complex examples of using components together.

## Included Components

### Graphics

*Module ecs_opengl*

Uses [glbits](https://github.com/rlipsc/glbits) to render models and textures with OpenGL.

Pass in your own position component or use the default `Position`.

**Model**: Displays a 3D model at the coordinates in the position component. The model is rendered with vertex buffer/array objects and instanced rendering, so is performant even with hundreds of thousands of instances.

**Texture**: Displays a texture billboard instance at the coordinates in the position component.

Running `ecs_opengl.nim` directly will execute the demo. This creates 400,000 entities to interact with the mouse, rendered as models or textures.

https://user-images.githubusercontent.com/36367371/124194457-88e1af80-dac0-11eb-8077-16477add4eae.mp4

### Physics

*Module ecs_chipmunk2d*

Uses [chipmunk2d](https://chipmunk-physics.net/) to simulate physics.

**PhysicsBody**: A wrapper for the `chipmunk.body` object.

**PhysicsShape**: A wrapper for `chipmunk.shape` objects.

**BodyTemplate**: Substituted on construction with `PhysicsBody`.

**ShapeTemplate**: Substituted on construction with `PhysicsShape`.

Physics is combined with rendering using `ecs_opengl` in `demos/chipmunkballpit`:

https://user-images.githubusercontent.com/36367371/124198657-04475f00-dac9-11eb-9000-fda888b270ff.mp4

### Console

*Module ecs_renderchar*

**RenderChar**: This component efficiently outputs a single character to the console, controllable with x and y coordinates normalised to `-1.0 .. 1.0`. This allows easy creation of text driven interfaces or outputs that more closely resemble rendering with graphics.

**RenderString**: A string of entities with `RenderChar` components, managed so you can set the `text` property and a normalised (x, y) coordinate. The constituent entities and components are accessible to edit, and handles clipping to the desired width/borders.

**DensityChar**: This component updates the character displayed in a `RenderChar` according to the number of `RenderChar` entities present in a particular character position. This gives a simple way to display multiple entities that are close together.

*Module ecs_consoleevents*

**ConsoleInput**: Receive console input event components.

**KeyInput**, **KeyChange**: Receive key press events.

**MouseInput**: Receive all mouse event components.

**MouseMoving**, **MouseButtons**: Receive specific mouse events. 

**WindowChange**: Receive events for the console window changing size. 

*Module ecs_mousebuttons*

This module uses `ecs_renderchar` and `ecs_consoleevents` to create mouse driven textual UI 'buttons'.

**MouseButton**: Allows defining a size, text alignment, background and border options. Full access to the **RenderChar** entities is given so they may be edited. Generates event components such as **MouseButtonClicked** and **MouseButtonMouseOver** for systems to respond to.

**DrawMouse**: Tag an entity with this component so that it's character is drawn at the mouse location.

### Database

There are two version of the database components, `ecs_db_threads` for threaded queries and `ecs_db` for non-threaded.

Note that these use the `odbc` library found [here](https://github.com/coffeepots/odbc).

**ConnectToDb**: Initiates a connection to the database with it's contained parameters. Once connection is established, it is removed and a **DatabaseConnection** component is added to the entity.

**Query**: Performs a query when a **DatabaseConnection** is present. When a result is obtained, it is placed within a **QueryResult** component and added to the entity.

### Networking

*Module ecs_udp*

**UDPRead**: Tag an entity with this component to subscribe to incoming `UDPData` packets delivered within `UDPIncoming` components.

**UDPSend**: Adding this component causes a UDP message to be sent to the parameter host and port.

### Miscellaneous

*Module ecs_spawnafter*

**SpawnAfter**: Generates a `construction` (a template of entities) after a given time frame. Useful for performing some task after some delay without blocking.

*Module ecs_killing*

**Killed**: This tag component can be used to handle clean up operations within a frame of execution. Create systems that use `Killed` along with other components to handle things like freeing resources owned by a component at the correct stage of system execution, rather than calling `delete` directly. Invoke `addKillingSystem` at the appropriate time to actually `delete` entities after any clean up work has been finished. 

**KillAfter**: Add `Killed` to an entity after a set duration. Useful for temporary entities that might have resources that need appropriate finalisation, or just 'fire and forget' temporary entities.

## Demos

- `dbbrowser`: a simple console program that uses a combination of components to read and display table field info and data within a database.
- `netspeedtest`: measures the speed of sending/receiving UDP packets on localhost by counting how many arrive within a set time frame.
- `particlelife`: an implementation of the "Primordial Particle System" described [here](https://www.nature.com/articles/srep37969)

https://user-images.githubusercontent.com/36367371/124841111-6d751980-df84-11eb-85c0-90280f2dca1f.mp4
