import polymorph, polymers

const
  # Maximum number of subscribers.
  maxEnts = 100
  entOpts = ECSEntityOptions(maxEntities: maxEnts)
  compOpts = ECSCompOptions(maxComponents: maxEnts)
  sysOpts = ECSSysOptions(maxEntities: maxEnts)

import random
from winlean import getLastError

defineUDPNetworking(compOpts, sysOpts)
makeEcs(entOpts)
commitSystems("poll")

let e = newEntityWith(
  UDPRead(),
  UDPSend(address: "127.0.0.1", port: Port(9999), data: "Initial message")
  )

sysReadUDP.hostName = "127.0.0.1"
sysReadUDP.port = Port(9999)

var frame: int
import times
var
  starttime = epochTime()
  sent: int
let duration = 10.0
echo "Please wait ", duration, " seconds..."
while epochTime() - startTime < duration:
  poll()
  frame.inc
  if rand(1.0) < 0.1:
    e.addIfMissing UDPSend(address: "127.0.0.1", port: Port(9999), data: "Hey, sent from frame " & $frame)
    sent += 1

echo "Pings in time: ", duration, " = ", frame, " = ", frame.float / duration, "/s "

let msgs = e.fetchComponent UDPIncoming
assert msgs.valid

let diff = abs(msgs.items.len - sent)

if diff != 0:
  echo "Warning: received: " & $msgs.items.len & " but expected " & $sent & " difference of " & $diff
else:
  echo "Items received matches expected of ", sent

assert diff < 10, "Warning: received: " & $msgs.items.len & " but expected " & $sent
echo "Finished."  

