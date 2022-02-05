import polymorph, polymers, random

# Passing 'tllEvents' outputs a log of network activity.
defineTcpNetworking(fixedSizeComponents(100), defaultSystemOptions, tllEvents)

# When TcpRecvComplete is added the receive operation has completed.
makeSystem("serverRead", [TcpRecv, TcpRecvComplete]):
  added:
    # Work with TcpRecv data.
    echo "Server received message: ", item.tcpRecv.data
    quit()

makeEcs()
commitSystems("poll")

let
  port = 1234.Port

  # This entity will await incoming connections on the port and creates
  # new entities with TcpRecv for successful connection.
  server =
    newEntityWith(
      TcpListen(
        port: port,
      )
    )

  # Connect and send some data to the server.
  client =
    newEntityWith(
      TcpConnection(
        remoteAddress: "127.0.0.1",
        remotePort: port),
      TcpSend(data: "Hello"),
    )

while true:
  poll()