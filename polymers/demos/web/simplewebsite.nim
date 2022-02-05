import polymorph, polymers, times

const
  maxEnts   = 10_000  # Effectively the maximum concurrent sockets.
  entOpts   = dynamicSizeEntities()
  compOpts  = fixedSizeComponents(maxEnts)
  sysOpts   = fixedSizeSystem(maxEnts)

# Define networking components.
defineTcpNetworking(compOpts, sysOpts, tllEvents)
defineHttp(compOpts, sysOpts)

# Web page components.
registerComponents(compOpts):
  type
    RootPage* = object
    TimePage* = object

makeSystemOpts("serveRoot", [RootPage], sysOpts):
  fields:
    helloCount: int
  added:
    item.entity.add HttpResponse(
      status: Http200,
      body: "Hello " & $sys.helloCount
    )
    sys.helloCount += 1

makeSystemOpts("serveTime", [TimePage], sysOpts):
  added:
    item.entity.add HttpResponse(
      status: Http200,
      body: "The time is " & getClockStr()
    )

makeSystemOpts("finishServePage", [HttpResponseSent], sysOpts):
  # Clean up after a response.
  added:
    sys.deleteList.add item.entity
    echo "\n"

echo " "

makeEcs(entOpts)
commitSystems("poll")

let
  server =
    newEntityWith(
      TCPListen(
        port: Port(5555),
        onAccept: cl(
          ProcessHttp(),
          HttpRouteEntity(
            patterns: @[
              ("/", cl RootPage()),
              ("/time", cl TimePage())
            ]
          )
        )
      )
    )

while true: poll()
