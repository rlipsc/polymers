import polymorph

template defineUDPNetworking*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions): untyped {.dirty.} =
  import nativesockets
  from os import raiseOSError, osLastError
  from winlean import recvFrom, wsaGetLastError, AddrInfo, bindSocket, WSAEWOULDBLOCK

  type
    UDPData* = object
      port*: Port
      address*: string
      data*: string

  registerComponents(compOpts):
    type
      ## Subscribe to receive UDPData.
      UDPRead* = object

      UDPIncoming* = object
        items*: seq[UDPData]
      
      ## Sends UDPData.
      UDPSend* = object
        port*: Port
        address*: string
        data*: string
        failed*: bool

  defineSystem("readUDP", [UDPRead], sysOpts):
    socket {.public.}: SocketHandle
    domain {.public.} -> Domain = AF_INET
    socketType -> SockType = SOCK_DGRAM
    hostname {.public.}: string
    port {.public.}: Port

  defineSystem("sendUDP", [UDPSend], sysOpts):
    socket {.public.}: SocketHandle
    domain {.public.} -> Domain = AF_INET
    socketType -> SockType = SOCK_DGRAM

  makeSystemBody("readUDP"):
    init:
      sys.socket = createNativeSocket(sys.domain, sys.socketType, IPPROTO_UDP)
      if sys.socket == osInvalidSocket: raiseOsError(osLastError())

      let data = getAddrInfo(sys.hostname, sys.port, AF_UNSPEC, SOCK_DGRAM, IPPROTO_UDP)
      var
        dataAddr: ptr SockAddr
        dataAddrLen: cSize_t
      var curData = data
      while curData.ai_family != AF_INET.cint and curData.ai_next != nil:
        curData = curData.ai_next
      doAssert curData != nil, "Cannot find IP4 address"
      dataAddr = curData.ai_addr
      dataAddrLen = curData.ai_addrLen

      let res = sys.socket.bindSocket(dataAddr, dataAddrLen.SockLen)
      if res == -1:
        quit "Error binding socket"
      data.freeAddrInfo
      sys.socket.setBlocking false

    start:
      var
        buffer = newString(1472)
        sockAddr: SockAddr
        fromLen: SockLen = SockAddr.sizeOf.SockLen

      var
        # Messages outside of buffer size will be discarded.
        bytesRead = sys.socket.recvFrom(buffer.cstring, buffer.len.cint,
            0, sockAddr.addr, fromLen.addr)

      if bytesRead < 0:
        let err = wsaGetLastError()
        if err != WSAEWOULDBLOCK:
          echo "Network error: ", err
          raiseOSError(osLastError())
      
      sys.paused = bytesRead <= 0

    let
      address = sockAddr.addr.getAddrString
    
    all:
      let
        currentData = entity.fetchComponent UDPIncoming
      if currentData.valid:
        currentData.items.add UDPData(address: address, data: buffer[0 ..< bytesRead])
      else:
        entity.addComponent UDPIncoming(items: @[UDPData(address: address, data: buffer[0 ..< bytesRead])])

  makeSystemBody("sendUDP"):
    init:
      sys.socket = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      if sys.socket == osInvalidSocket: raiseOsError(osLastError())
    all:
      try:
        var toAddress = getAddrInfo(
          item.udpSend.address,
          item.udpSend.port,
          sys.domain, sys.socketType, IPPROTO_UDP)

        discard sys.socket.sendTo(
          item.udpSend.data[0].addr,
          item.udpSend.data.len.cint,
          0,
          toAddress.ai_addr, toAddress.ai_addrLen.SockLen)

        toAddress.freeAddrInfo
      except:
        item.udpSend.failed = true
      if not item.udpSend.failed:
        entity.remove UDPSend

when isMainModule:
  const
    # Maximum number of subscribers.
    maxEnts = 100
    entOpts = ECSEntityOptions(maxEntities: maxEnts)
    compOpts = ECSCompOptions(maxComponents: maxEnts)
    sysOpts = ECSSysOptions(maxEntities: maxEnts)

  import random, times

  defineUDPNetworking(compOpts, sysOpts)

  # Hook incoming
  makeSystemOpts("messageArrived", [UDPIncoming], sysOpts):
    all:
      echo "New message arrived: ", item.udpIncoming.items
      entity.removeComponent UDPIncoming

  makeEcs(entOpts)
  commitSystems("poll")

  let e = newEntityWith(
    UDPRead(),
    UDPSend(address: "127.0.0.1", port: Port(9999), data: "Initial message")
    )

  sysReadUDP.hostName = "127.0.0.1"
  sysReadUDP.port = Port(9999)
  while true:
    poll()
    if rand(1.0) < 0.000001:
      echo "Sending message..."
      e.addIfMissing UDPSend(address: "127.0.0.1", port: Port(9999), data: "Hey, sent at time " & $now())
