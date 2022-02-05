import polymorph

## 'ecs_tcp.nim' provides low level TCP components using the Windows
## IO completion port API.
## 
## Operation summary:
## 
##    TCP operations are asynchronously initiated when buffer components
##    such as `TcpSend` and `TcpRecv` are first combined with
##    `TcpConnection` on an entity.
## 
##    The "tcpEvents" system processes socket completions in the queue
##    with a simple state machine, and adds completion components such
##    as `TcpConnected`, `TcpSendComplete`, and `TcpRecvComplete` to
##    entities as appropriate.
## 
##    Systems can hook these completion components and perform further
##    network operations using existing or new buffer components. Once
##    a completion component is 'claimed' by a system, it is removed to
##    allow retriggering.
## 
##    When connection entities are finished with, they can be deleted.
##
## To listen for connections on a port, add the `TcpListen` component.
## This will spawn a new entity with `TcpConnection` and `TcpRecv` when
## an incoming connection is established, and optionally with your own
## components to allow distinguishing connections for different systems.
## 
## To work with connected `TcpSend`/`TcpRecv` components, use the `send`
## and `read` procedures.
## 
## Below is the code for a simple server and client.
##
##    import polymorph, polymers, random
##
##    # Passing 'tllEvents' outputs a log of network activity.
##    defineTcpNetworking(fixedSizeComponents(100), defaultSystemOptions, tllEvents)
##
##    # When TcpRecvComplete is added the receive operation has completed.
##    makeSystem("serverRead", [TcpRecv, TcpRecvComplete]):
##      added:
##        # Work with TcpRecv data.
##        echo "Server received message: ", item.tcpRecv.data
##        quit()
##
##    makeEcs()
##    commitSystems("poll")
##
##    let
##      port = 1234.Port
##
##      # This entity will await incoming connections on the port and creates
##      # new entities with TcpRecv for successful connection.
##      server =
##        newEntityWith(
##          TcpListen(
##            port: port,
##          )
##        )
##
##      # Connect and send some data to the server.
##      client =
##        newEntityWith(
##          TcpConnection(
##            remoteAddress: "127.0.0.1",
##            remotePort: port),
##          TcpSend(data: "Hello"),
##        )
##
##    while true:
##      poll()


type TcpLoggingLevel* = enum tllNone, tllEvents, tllEventsData, tllEventsLineNo

template defineTcpNetworking*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions, logging: static[TcpLoggingLevel]): untyped {.dirty.} =
  ## Registers components and systems to asynchronously send and receive
  ## data over TCPIP.

  when not defined(windows):
    error "These components currently only support Windows"
  
  import nativesockets, os, winlean, strformat, sequtils

  from options import isSome, unsafeGet
  from net import SocketFlag, toOSFlags
  from strutils import align, alignLeft
  
  # These symbols need to be in scope for makeEcs() and commitSystems().
  export raiseOSError, osLastError, recvFrom, wsaGetLastError, AddrInfo, WSAEWOULDBLOCK
  export isSome, unsafeGet, SocketFlag, toOSFlags, INADDR_ANY

  proc initPointer(s: SocketHandle, fun: var pointer, guid: var GUID): bool =
    # Fetch pointer to function.
    var bytesRet: DWORD
    fun = nil
    result = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, addr guid,
                      sizeof(GUID).DWORD, addr fun, sizeof(pointer).DWORD,
                      addr bytesRet, nil, nil) == 0

  # IO Selection setup.
  var acceptEx: WSAPROC_ACCEPTEX
  var connectEx: WSAPROC_CONNECTEX
  var getAcceptExSockAddrs: WSAPROC_GETACCEPTEXSOCKADDRS

  proc winsockInitialized: bool =
    let s = createNativeSocket(Domain.AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if s == INVALID_SOCKET:
      false
    else:
      discard closesocket(s)
      true

  proc init =
    if not winsockInitialized():
      var wsaData: WSAData
      let startupResult = wsaStartup(0x0101'i16, addr wsaData)
      if startupResult != 0:
        raiseOSError(osLastError())
    
    # Fetch function calls.
    let dummySock = createNativeSocket()
    if dummySock == INVALID_SOCKET:
      raiseOSError(osLastError())
    var fun: pointer = nil
    if not initPointer(dummySock, fun, WSAID_CONNECTEX):
      raiseOSError(osLastError())
    connectEx = cast[WSAPROC_CONNECTEX](fun)
    if not initPointer(dummySock, fun, WSAID_ACCEPTEX):
      raiseOSError(osLastError())
    acceptEx = cast[WSAPROC_ACCEPTEX](fun)
    if not initPointer(dummySock, fun, WSAID_GETACCEPTEXSOCKADDRS):
      raiseOSError(osLastError())
    getAcceptExSockAddrs = cast[WSAPROC_GETACCEPTEXSOCKADDRS](fun)
    close(dummySock)

  init()
  
  #-----

  const
    tcpShutdown_Recv* = 0.cint
    tcpShutdown_Send* = 1.cint
    tcpShutdown_Both* = 2.cint
    defaultReadBufferSize* = 4096

  type
    CompletionPortHandle = distinct Handle
    CompletionKey = ULONG_PTR
    ConnectionType* = enum ctTcpOperation = 1.CompletionKey
    ConnectionState* = enum csInvalid, csAccept, csRead, csConnecting, csSendInProgress
    DataBuf = UncheckedArray[char]
    
    ## Simple manual string heap buffer.
    DataString* = object
      buf*: ptr DataBuf
      len*: int
      cap*: int

    OverlappedInfo* = object
      # Info for interpreting a completion.
      ioPort*: CompletionPortHandle
      entity*: EntityRef
      state*: ConnectionState
      socket*: SocketHandle     # Either recv socket or send socket.
      connection*: ComponentRef
      compRef*: ComponentRef

  const `dynMem` = compOpts.componentStorageFormat in [cisSeq]

  when not `dynMem`:
    type
      OverlappedHeader* = object of OVERLAPPED
        info*: OverlappedInfo

      OverlappedRead* = object of OverlappedHeader
        listenSocket*: SocketHandle
        bytesReceived*: DWORD
        recvBuffer*: TWSABuf
        addressBuffer*: array[256, byte] # Sockaddr_storage for server and client
        singleRead*: bool

      OverlappedSend* = object of OverlappedHeader
        addrInfo*: ptr AddrInfo
        sendBuffer*: TWSABuf
        bytesSent*: DWORD

  else:
    {.fatal: "Dynamic memory is not currently supported".}

    type
      OverlappedHeader* = ref object of OVERLAPPED
        info*: OverlappedInfo

      OverlappedRead* = ref object of OverlappedHeader
        listenSocket*: SocketHandle
        bytesReceived*: DWORD
        recvBuffer*: TWSABuf
        addressBuffer*: array[256, byte] # Sockaddr_storage for server and client
        singleRead*: bool

      OverlappedSend* = ref object of OverlappedHeader
        addrInfo*: ptr AddrInfo
        sendBuffer*: TWSABuf
        bytesSent*: DWORD

  registerComponents(compOpts):
    type
      TcpConnection* = object
        ioPort*: CompletionPortHandle
        socket*: SocketHandle
        localAddress*: DataString
        remoteAddress*: DataString
        localPort*: Port
        remotePort*: Port
      
      TcpConnected* = object
      
      ## Receive incoming packet data.
      ## Adding this component begins an async socket read.
      ## After data has been received, accept is initiated again.
      TcpRecv* = object
        listenSocket*: SocketHandle
        data*: DataString
        overlappedRead*: OverlappedRead
        bufferSize*: Natural
        # Enforce a maximum read length at which TcpRecvComplete is added.
        maxReadLength*: Natural

      TcpRecvComplete* = object

      ## Sends to remoteAddress
      TcpSend* = object
        data*: DataString
        overlappedSend*: OverlappedSend

      ## Automatically added when `TcpSend` has completed.
      TcpSendComplete* = object
      
      ## This component waits for incoming connections and
      ## spawns a new entity when an accept is completed.
      TcpListen* = object
        port*: Port
        socket*: SocketHandle           ## The listen socket, set up automatically when added to the entity.
        overlappedRead*: OverlappedRead ## Internal data about the read state.
        onAccept*: ComponentList        ## Components in `onAccept` are added to the connection entity upon accepting a new connection.
        singleRead*: bool               ## Initiates a new read immediately after a read operation has completed.
  
      TcpErrors* = object
        messages: seq[string]

  proc `singleRead=`*(tcpRecv: var TcpRecv, value: bool) =
    tcpRecv.overlappedRead.singleRead = value
  proc singleRead*(tcpRecv: TcpRecv): bool =
    tcpRecv.overlappedRead.singleRead
  

  # Forward declare systems.

  defineSystem("tcpEvents", [TcpConnection], sysOpts):
    ioPort {.public.}: CompletionPortHandle
    # By default all events in the queue are drained per system run.
    # Setting eventLimit to a non-zero value constrains the system
    # to process a maximum number of queued operations.
    eventLimit {.public.}: Natural
  defineSystem("readTcp", [TcpConnection, TcpRecv])
  defineSystem("sendTcp", [TcpConnection, TcpSend], sysOpts)


  # ----------------
  # Data string type
  # ----------------


  # IOCP requires passing buffers to the operating system for update
  # which must be managed manually.
  #
  # `DataString` is a simple wrapper around a heap buffer that can be
  # used in a string-like way.
  #
  # Note that converting to and from a native `string` requires a copy.

  proc `$`*(ds: DataString): string =
    result = newString(ds.len)
    if ds.len > 0:
      copyMem(result[0].addr, ds.buf, ds.len)
  
  proc dispose*(ds: var DataString) {.inline.} =
    if ds.buf != nil:
      ds.buf.deAlloc
      ds.buf = nil
    ds.len = 0
    ds.cap = 0

  proc setCapacity*(ds: var DataString, newCapacity: int, copy = true) {.inline.} =
    # Capacity includes an extra byte for the terminating zero.
    if ds.cap == newCapacity: return
    if ds.len == 0:
      ds.buf = cast[ptr DataBuf](alloc0(newCapacity + 1))
      ds.cap = newCapacity
    else:
      let newLen = min(ds.len, newCapacity)
      if newCapacity > ds.cap:
        let curBuf = ds.buf
        ds.buf = cast[ptr DataBuf](alloc0(newCapacity + 1))
        if copy: copyMem ds.buf, curBuf, newLen
        curBuf.deAlloc
        ds.cap = newCapacity
      
      ds.len = newLen

  proc assign*(ds: var DataString, value: string) {.inline.} =
    ds.setCapacity value.len, copy = false
    ds.len = value.len
    if value.len > 0:
      copyMem(ds.buf, value[0].unsafeAddr, ds.len)

  proc transfer*(dsSource, dsDest: var DataString) {.inline.} =
    ## Transfer buffer pointer from `dsSource` to `dsDest`.
    ## Properties are transferred to `dsDest` and `dsSource` is reset
    ## to an empty state.
    assert dsSource.len > 0,
      "Expected non-zero length when transferring DataString"
    
    if dsDest.len > 0: dsDest.dispose

    dsDest.len = dsSource.len
    dsDest.cap = dsSource.cap
    dsDest.buf = dsSource.buf
    dsSource.buf = nil
    dsSource.len = 0
    dsSource.cap = 0

  proc `[]`*(ds: DataString, index: int): var char {.inline.} = ds.buf[][index]
  proc `[]=`*(ds: var DataString, index: int, value: char) {.inline.} = ds.buf[][index] = value

  converter toDataString*(input: string): DataString =
    result.assign input
  
  converter fromDataString*(input: DataString): string =
    result = $input
  
  proc setLen*(ds: var DataString, newLength: int) {.inline.} =
    ds.setCapacity newLength
    ds.len = newLength
  
  iterator lines*(input: DataString, startPos = 0): (int, string) =
    ## Iterates `input` into strings separated by "/c/L" and the
    ## next character index.
    ## Note: character indexes will == `input`.len for the last
    ## iteration.
    assert startPos < input.len
    var
      p = startPos
      cr: bool
      current = newStringOfCap(20)
    while p < input.len:
      let c = input[p]
      if cr and c == '\L':
        yield (p + 1, current)
        current.setLen 0
      elif c == '\c':
        cr = true
      else:
        current &= c
      p.inc
    yield (p, current)

  func overwrite*(ds: var DataString, start: Natural, value: string): int =
    ## Write a substring into `ds` and returns the new index.
    let
      finish = start + value.len
      dsLen = ds.len
    assert finish <= dsLen,
      "Overwriting beyond DataString length of " & $dsLen &
        " with string \"" & value & "\" of length " & $value.len & " (" &
        $(finish - dsLen) & " extra character(s) required)"

    var newIndex: int
    if dsLen > 0:
      if value.len > 0:
        let
          dsLast = dsLen - 1
          dsStart = min(start, dsLast)
        newIndex = min(finish, dsLast)
        let count = newIndex - dsStart

        copyMem(ds[dsStart].addr, unsafeAddr(value[0]), count)
      else:
        newIndex = min(start, dsLen - 1)

    newIndex


  # ----------------
  # Component events
  # ----------------


  proc disconnect*(connection: var TcpConnection) =
    let listenSocket = connection.socket
    discard listenSocket.shutdown(tcpShutdown_Both)
    listenSocket.close
    connection.localAddress.dispose
    connection.remoteAddress.dispose
    connection.socket = 0.SocketHandle

  TcpConnection.onRemove:
    curComponent.disconnect

  TcpRecv.onAdd:
    if curComponent.bufferSize == 0:
      curComponent.bufferSize = defaultReadBufferSize

  TcpRecv.onRemove:
    let readSocket = curComponent.overlappedRead.info.socket
    discard readSocket.shutdown(tcpShutdown_Recv)
    curComponent.data.dispose
    if curComponent.overlappedRead.recvBuffer.len > 0:
      curComponent.overlappedRead.recvBuffer.buf.deAlloc
      curComponent.overlappedRead.recvBuffer.buf = nil
    curComponent.overlappedRead.info.socket.close

  TcpSend.onRemove:
    let sendSocket = curComponent.overlappedSend.info.socket
    discard sendSocket.shutdown(tcpShutdown_Send)
    curComponent.data.dispose

    template olSend: untyped = curComponent.overlappedSend

    if olSend.info.socket.int != 0:
      olSend.info.socket.close()
      olSend.info.socket = 0.SocketHandle
    
    # Free resources.
    if olSend.addrInfo != nil:
      olSend.addrInfo.freeAddrInfo
    olSend.sendBuffer.buf.deAlloc
    olSend.sendBuffer.buf = nil


  # ------------
  # System utils
  # ------------


  type NetworkLogEntry* = tuple[text: string, width: int]
  const defaultWidth = 30

  template networkLogCore(columns: openarray[string], getStr, getWidth: untyped) =
    ## Negative widths are right aligned.
    when logging in [tllEvents, tllEventsData, tllEventsLineNo]:
      var finalStr: string
      for column {.inject.} in columns:
        if getWidth >= 0:
          finalStr &= alignLeft(getStr, getWidth) & " "
        else:
          finalStr &= align(getStr, abs(getWidth)) & " "

      when logging == tllEventsLineNo:
        let info = instantiationInfo()
        echo currentSourcePath() & "(" & $info.line & "): " & finalStr
      else:
        echo finalStr

  template networkLog*(colSize: int, columns: openarray[string]) =
    networkLogCore(columns, column, colSize)
  
  template networkLog*(columns: openarray[string]) =
    networkLogCore(columns, column, defaultWidth)

  template tcpErrorMsg(err: OSErrorCode, duringStr: string): string =
    "Error during '" & duringStr & "' (OS: " & $err & "): " & osErrorMsg(err)

  template onOsError(okValues: openarray[SomeInteger], actions: untyped) =
    block:
      let
        osErr {.inject.} = osLastError()
        errInt = osErr.int32
      if errInt != 0 and errInt notin okValues:
        actions

  template reportError(during: string, okValues: openarray[SomeInteger]): bool =
    var res: bool
    onOsError(okValues):
      when defined(debug):
        writeStackTrace()
        quit("Debug terminate due to an unhandled error: " &
          tcpErrorMsg(osErr, during))
      else:
        res = true
    res

  template reportError(during: string): bool = reportError(during, [ERROR_IO_PENDING])

  # Debugging
  proc `$`(sh: SocketHandle): string = "(Socket: " & $sh.int & ")"
  proc `$`(ioh: CompletionPortHandle): string = "(IOPort: " & $ioh.int & ")"
  proc `$`(port: Port): string = "(Port: " & $port.int & ")"
  template entityIdStr(ent: EntityRef): string = "[Entity " & $ent.entityId.int & "]"  

  proc bindSock(handle: SocketHandle, domain: Domain, addrInfo: ptr AddrInfo): bool =
    let sockStr = " " & handle.repr
    #echo sockStr, ": Binding socket handle "
    if handle.bindAddr(addrInfo.ai_addr, addrInfo.ai_addrLen.SockLen) < 0:
      echo sockStr & ": Bind Error"
      reportError("Binding socket", [0])
    else:
      true

  proc bindSocket*(handle: SocketHandle, domain: Domain, address = "", port: Port = Port(0)): bool =
    var addrInfo: ptr AddrInfo
    try:
      let address =
        if address != "": address
        else:
          case domain
          of Domain.AF_INET6: "::"
          of Domain.AF_INET: "0.0.0.0"      
          else:
            echo "Unknown domain ", domain
            ""
      addrInfo = getAddrInfo(address, port, domain)
      bindSock(handle, domain, addrInfo)
    finally:
      if addrInfo != nil: addrInfo.freeAddrInfo

  template doBeginAccept(olAccept: ptr OverlappedRead, clearMem, useEntity: static[bool]): bool =
    ## Begin accept process and adjust state accordingly.
    ## Returns the result of the call to acceptEx.
    when clearMem:
      # Clear the system part of the overlapped structure.
      zeroMem(olAccept, OVERLAPPED.sizeOf)
    
    olAccept.info.state = csAccept

    const
      domain = Domain.AF_INET
      protocol = IPPROTO_TCP
      socketType = SOCK_STREAM

    let
      ioPort = olAccept.info.ioPort
    var
      socket = olAccept.info.socket

    if olAccept.info.socket.int == 0: 
      
      olAccept.info.socket = createNativeSocket(domain, socketType, protocol)
      socket = olAccept.info.socket
      
      when useEntity:
        discard entity.reportError("Creating new socket")
      else:
        discard reportError("Creating new socket")

      let addSocketToPortRes {.used.} = createIoCompletionPort(
        socket.Handle,
        ioPort.Handle,
        CompletionKey(ctTcpOperation),
        0)

      when useEntity:
        discard entity.reportError("Attaching new socket to IO port")
      else:
        discard reportError("Attaching new socket to IO port")

    let
      receiveLength: DWORD = 0  # Only return address info.
      localAddressLen = DWORD(sizeof(Sockaddr_storage) + 16)
      remoteAddressLen = DWORD(sizeof(Sockaddr_in6) + 16)

    let
      # Initiate an async accept on the recv socket.
      acceptRes = acceptEx(
        olAccept.listenSocket,
        socket,
        olAccept.addressBuffer[0].addr,
        receiveLength,
        localAddressLen,
        remoteAddressLen,
        olAccept.bytesReceived.addr,
        olAccept
      )
    when useEntity:
      discard entity.reportError("Accept", [ERROR_IO_PENDING])
    else:
      discard reportError("Accept", [ERROR_IO_PENDING])

    acceptRes

  proc beginAccept(olAccept: ptr OverlappedRead, clearMem: static[bool]): bool =
    doBeginAccept(olAccept, clearMem, false)

  proc beginRecv(olRecvPtr: ptr OverlappedRead, bufferSize = defaultReadBufferSize, okValues: openarray[SomeInteger] = [ERROR_IO_PENDING]): cint =
    ## After accept has completed, this starts the data receiving process.
    ## Returns the result of WSARecv.
    assert olRecvPtr.info.state != csRead,
      "Cannot initiate read when another read is pending for this connection"

    olRecvPtr.info.state = csRead

    if olRecvPtr.recvBuffer.len == 0:
      olRecvPtr.recvBuffer.buf = cast[cstring](alloc0(bufferSize))
      olRecvPtr.recvBuffer.len = bufferSize.ULONG

    var flags = {SocketFlag.SafeDisconn}.toOSFlags().DWORD

    assert olRecvPtr.recvBuffer.buf != nil, "Could not allocate read buffer"

    template info: untyped = olRecvPtr.info

    networkLog defaultWidth,
      ["<... >", entityIdStr(info.entity), $info.socket, "Awaiting recv"]

    let res =
      WSARecv(
        # recvSocket is returned from accept.
        olRecvPtr.info.socket,
        olRecvPtr.recvBuffer.addr,
        1,
        olRecvPtr.bytesReceived.addr,
        flags.addr,
        olRecvPtr,
        nil
      )
    discard reportError("Read", okValues)
    res

  proc createListenSocket(localPort: Port, ioPort: CompletionPortHandle): SocketHandle =
    ## Create a new listening socket using TcpConnection.
    const
      domain = Domain.AF_INET
      protocol = IPPROTO_TCP
      socketType = SOCK_STREAM
    
    result = createNativeSocket(domain, socketType, protocol)
    if result == osInvalidSocket:
      raiseOSError(osLastError())
    result.setBlocking(false)

    assert localPort.int != 0, "TcpConnection.localPort is not initialised"

    let bindRes = bindSocket(result, domain, port = localPort)

    if bindRes and not reportError("Bind for read"):
      let listenRes = result.listen()
      if listenRes == 0 and not reportError("Listening"):
        # Associate listen socket with the system completion port.
        let
          portHandle = ioPort.Handle
          r = createIoCompletionPort(result.Handle, portHandle, CompletionKey(ctTcpOperation), 0)
        assert r == portHandle, "createIoCompletionPort did not return the expected port value of " & $ioPort & ", instead " & $r
  
  proc awaitConnection*(tcpListen: var TcpListen) =
    let ol = tcpListen.overlappedRead.addr
    # Initialise receive buffer.
    let acceptRes {.used.} = beginAccept(ol, clearMem = false)
    let res {.used.} = reportError("Accept")

  proc awaitConnection*(tcpRecv: var TcpRecv) =
    let ol = tcpRecv.overlappedRead.addr
    # Initialise receive buffer.
    let acceptRes {.used.} = beginAccept(ol, clearMem = false)
    let res {.used.} = reportError("Accept")

  proc connect*(connection: var TcpConnection, tcpSend: var TcpSend) =
    ## Implements `connectEx` with `tcpSend`.
    ## Address resolution and 
    assert connection.socket.int == 0, "Cannot create socket as TcpConnection is already initialised"
    assert connection.remoteAddress.len > 0, "Empty address given to TcpConnection"
    assert connection.remotePort.int != 0, "Zero port given to TcpConnection"

    let
      olSend = tcpSend.overlappedSend.addr
      info = olSend.info.addr
      connectSock = createNativeSocket(Domain.AF_INET, SOCK_STREAM, IPPROTO_TCP)

    assert olSend.info.connection.valid, "Connection reference is not initialised"

    info.socket = connectSock
    connection.socket = connectSock

    let r {.used.} = createIoCompletionPort(info.socket.Handle, connection.ioPort.Handle, CompletionKey(ctTcpOperation), 0)

    info.state  = csConnecting

    let hostDetails = getHostByName(connection.remoteAddress)
    assert hostDetails.addrList.len > 0, "Cannot resolve IP address of host '" &
      connection.remoteAddress & "'"
    
    let ip = hostDetails.addrList[0]

    # Get address
    olSend.addrInfo = getAddrInfo(
      ip,
      connection.remotePort,
      Domain.AF_INET, SOCK_STREAM, IPPROTO_TCP
      )
    
    var domain: Domain
    template ai: untyped = olSend.addrInfo
    while ai != nil:
      let domainOpt = ai.ai_family.toKnownDomain()
      if domainOpt.isSome:
        domain = domainOpt.unsafeGet()
        break
      olSend.addrInfo = ai.ai_next

    template log(strs: varargs[string]) =
      networkLog defaultWidth, @[strs[0], $entityIdStr(info.entity), $connection.socket] & @strs[1..^1]
    template logSetup(strs: varargs[string]) =
      log @["  <> "] & @strs
    template logConnect(strs: varargs[string]) =
      log @["<    > "] & @strs

    if bindSocket(info.socket, domain, ""):
      logSetup "Bound for connect"
    else:
      logSetup "Error binding"

    if olSend.addrInfo == nil:
      discard reportError("Finding known host domain", [ERROR_IO_PENDING, 0])
    
    logSetup "Domain Found", $domain, ip

    logConnect "Connecting",
      "Remote port: " & $connection.remotePort,
      "IP: " & ip, "Address: \"" & $connection.remoteAddress & "\""

    # Connect and send.
    var
      bytesSent: DWORD
      fail: bool
    let
      connectResult =
        # https://docs.microsoft.com/en-us/windows/win32/api/mswsock/nc-mswsock-lpfn_connectex
        #[
          TODO: If the error code returned is WSAECONNREFUSED, WSAENETUNREACH, or WSAETIMEDOUT,
          the application can call ConnectEx, WSAConnect, or connect again on the same socket.
        ]#
        connectEx(
          connectSock,
          olSend.addrInfo.ai_addr,
          olSend.addrInfo.ai_addrlen.cint,
          nil, 0,
          bytesSent.addr,
          olSend
          )

    if not(connectResult):
      let osErr = osLastError()
      if osErr.int32 != ERROR_IO_PENDING:
        fail = true
        log "Connect error!", $connectSock, $osErr
        writeStackTrace()
      #else:
      #  log "Awaiting connect", $connectSock
    else:
      log "Connected immediately", $connectSock

    if fail:
      olSend.addrInfo.freeAddrInfo
      olSend.addrInfo = nil
      info.socket.close()
      info.socket = 0.SocketHandle

  proc send*(connection: var TcpConnection, tcpSend: var TcpSend, okValues: openarray[SomeInteger]) =
    ## Initiate a send operation for `TcpSend`.
    ## 
    ## If `TcpConnection` is not initialised, a connect is attempted
    ## using `remoteAddress` and `remotePort`.
    ## 
    ## Otherwise, a send is initiated immediately.
    ## 
    ## Non-zero sockets in `connection` are presumed initialised.
    template info: untyped = tcpSend.overlappedSend.info

    assert connection.ioPort.int != 0,
      "IO port is not initialised, TcpConnection() might need to be added before TcpSend()"
    assert connection.remotePort.int != 0, "TcpConnection.port is not set up"
    assert tcpSend.overlappedSend.info.state != csSendInProgress,
      "A send message is already in transit"
    
    info.ioPort = connection.ioPort
    info.socket = connection.socket
    info.state = csSendInProgress

    let
      olSend = tcpSend.overlappedSend.addr
      dataLength = (tcpSend.data.len + 1).ULONG # Include trailing zero.
    
    if tcpSend.data.len != dataLength:
      if olSend.sendBuffer.buf != nil:
        olSend.sendBuffer.buf.deAlloc
      olSend.sendBuffer.buf = cast[cstring](alloc0(dataLength))
      olSend.sendBuffer.len = dataLength

    # Populate send buffer.
    copyMem(
      olSend.sendBuffer.buf[0].addr,
      tcpSend.data[0].addr,
      tcpSend.data.len)

    if connection.socket.int == 0:
      # This connection is not yet established, begin connectEx.
      connect(connection, tcpSend)
    else:
      template log(entries: varargs[string, `$`]) =
        networkLog defaultWidth, @["==>--> ", entityIdStr(info.entity),
          $info.socket, "Send"] & @entries
      
      log "Address: " & connection.remoteAddress, $connection.remotePort
      when logging in [tllEventsData, tllEventsLineNo]:
        log "Message: \"" & olSend.sendBuffer.buf.repr & "\""

      let
        flags = {SocketFlag.SafeDisconn}.toOSFlags().DWORD
        ret {.used.} = WSASend(
          info.socket,
          olSend.sendBuffer.addr,
          1,
          olSend.bytesSent.addr,
          flags,
          tcpSend.overlappedSend.addr,
          nil)

      discard reportError("Send", okValues)

  template send*(connection: TcpConnectionInstance, tcpSend: TcpSend) =
    send(connection.access, tcpSend.access, [ERROR_IO_PENDING])

  template send*(connection: TcpConnectionInstance, tcpSend: TcpSendInstance, okValues: openarray[SomeInteger]) =
    send(connection.access, tcpSend.access, okValues)

  template send*(connection: TcpConnectionInstance, tcpSend: TcpSendInstance) =
    send(connection.access, tcpSend.access, [ERROR_IO_PENDING])

  proc initIoPort*(sys: var TcpEventsSystem) =
    ## Create an IO port for the system on first run.
    ## 
    ## This is automatically performed when "tcpEvents" is first run,
    ## but if you want to start using networking components before
    ## running systems you can call this proc early manually.
    if sys.ioPort.int == 0:
      const threads = 1
      sys.ioPort = createIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, threads).CompletionPortHandle
      echo " Created IOCP port. Id = ", sys.ioPort


  # ------------------------------------------
  # Post-makeEsc extended networking utilities
  # ------------------------------------------


  onEcsBuilt:
    # Ensure io port is initialised as soon as the ECS is available.
    initIoPort(sysTcpEvents)

    proc `singleRead=`*(tcpRecv: TcpRecvInstance, value: bool) =
      tcpRecv.overlappedRead.singleRead = value
    proc singleRead*(tcpRecv: TcpRecvInstance): bool =
      tcpRecv.overlappedRead.singleRead

    # Utility functions that report errors through entities with the
    # TcpErrors component.

    template reportError(entity: EntityRef, during: string, okValues: openarray[SomeInteger]): bool =
      var res: bool
      onOsError(okValues):
        res = true

        when defined(debug):
          writeStackTrace()
          quit("Debug terminate due to an unhandled error: " & tcpErrorMsg(osErr, during))
        else:
          let
            sendFailed = entity.fetch TcpErrors

          if sendFailed.valid:
            sendFailed.messages.add tcpErrorMsg(osErr, during)
          else:
            entity.add TcpErrors(messages: @[tcpErrorMsg(osErr, during)])
      res

    template reportError(entity: EntityRef, during: string): bool =
      reportError(entity, during, [ERROR_IO_PENDING])

    proc beginAccept(entity: EntityRef, olAccept: ptr OverlappedRead, clearMem: static[bool]): bool =
      doBeginAccept(olAccept, clearMem, true)

    proc awaitConnection*(entity: EntityRef, tcpListen: var TcpListen) =
      let ol = tcpListen.overlappedRead.addr
      # Initialise receive buffer.
      let acceptRes {.used.} = entity.beginAccept(ol, clearMem = false)
      let res {.used.} = entity.reportError("Accept")

    proc awaitConnection*(entity: EntityRef, tcpRecv: var TcpRecv) =
      let ol = tcpRecv.overlappedRead.addr
      # Initialise receive buffer.
      let acceptRes {.used.} = entity.beginAccept(ol, clearMem = false)
      let res {.used.} = entity.reportError("Accept")


  # -------
  # Systems
  # -------


  makeSystem "tcpEvents", [TcpConnection]:
    #
    # This system polls available completions and acts on the state info.
    #
    init:
      sys.initIoPort
    
    added:
      # Assign the system's completion port to this component for later reference.
      assert sys.ioPort.int != 0,
        "System completion port is not yet initialised, run this " &
        "system's initialisation to perform initialisation (eg; `do" &
        sys.name & "()`)"
      item.tcpConnection.ioPort = sys.ioPort

    var
      bytesReceived: DWORD
      completionKey: ULONG_PTR
      overlappedAddr: POVERLAPPED
      processedCompletions: Natural

    # Process completion queue.

    while getQueuedCompletionStatus(
      sys.ioPort.Handle, bytesReceived.addr, completionKey.addr, overlappedAddr.addr, 0).bool:
      # There is an event to dequeue.
      let
        info = cast[ptr OverlappedHeader](overlappedAddr).info
        key = completionKey.ConnectionType
        entity = info.entity
        compRef = info.compRef
        connection = info.connection.index.TcpConnectionInstance

        state = info.state
        statePrefix = case state
          of csAccept: "<--<=="
          of csRead: "<===--"
          of csConnecting: "<---->"
          of csSendInProgress: "--===>"
          else: "Unknown: " & $state

      assert compRef.valid,
        "Invalid component reference passed to tcpEvents: " & $compRef & " for " & $state

      template log(strs: varargs[string, `$`]) =
        networkLog(defaultWidth,
          @[statePrefix, entity.entityIdStr, $info.socket] &
            @["Event: " & strs[0]] & @strs[1..^1])

      assert entity.alive, "The completion for event " & $info.state &
        " contained a dead entity:\n" & $entity.entityId & "\n"
      
      if likely(key == ctTcpOperation):
        case state

        of csInvalid:
          log "Invalid state in overlapped. Source entity:\n", entity
          discard reportError("Invalid state")

        of csAccept:
          # Complete an incoming connection.
          log "Accept completed"
          let
            olAccept = cast[ptr OverlappedRead](overlappedAddr)

            setOptRet = setSockOpt(
              info.socket,
              SOL_SOCKET,
              SO_UPDATE_ACCEPT_CONTEXT,
              olAccept.listenSocket.addr,
              sizeof(olAccept.listenSocket).SockLen)

          if setOptRet != 0:
            discard reportError("Completing accept")

          assert compRef.typeId == TcpListen.typeId, "Unknown type in compRef '" & $compRef & "' when accepting connection"

          let
            receiveLength: DWORD = 0  # Only return address info.
            localAddressLen = DWORD(sizeof(Sockaddr_storage) + 16)
            remoteAddressLen = DWORD(sizeof(Sockaddr_in6) + 16)
          var
            localLen, remoteLen: int32
            local, remote: ptr SockAddr

          getAcceptExSockAddrs(
            olAccept.addressBuffer[0].addr, receiveLength,
            localAddressLen, remoteAddressLen,
            local.addr, localLen.addr,
            remote.addr, remoteLen.addr
          )

          assert info.compRef.typeId == TcpListen.typeId, "Expected a TcpListen to have initiated the accept operation"
          # Spawns a new connection entity to handle the read.
          let
            tcpListen = info.compRef.index.TcpListenInstance

            # TcpRecv and TcpConnection added together will initiate
            # a receive operation.
            channelEnt = newEntityWith(
              TcpConnection(
                socket: olAccept.info.socket,
                localPort: tcpListen.port,
                localAddress: getAddrString(local),
                remoteAddress: getAddrString(remote)
              ),
              TcpRecv(
                listenSocket: olAccept.listenSocket,
                overlappedRead: OverlappedRead(
                  singleRead: tcpListen.singleRead
                  )
                ),
              TcpConnected(),
              )

          # Add user components for this channel.
          if tcpListen.onAccept.len > 0:
            channelEnt.add tcpListen.onAccept

          let con = channelEnt.fetch TcpConnection
          try:
            (con.localAddress, con.localPort) =
              olAccept.info.socket.getLocalAddr(Domain.AF_INET)
            (con.remoteAddress, con.remotePort) =
              olAccept.info.socket.getPeerAddr(Domain.AF_INET)
          except:
            olAccept.info.socket.close()
            raise getCurrentException()

          log "Create channel",
            "Address: " & con.remoteAddress, con.remotePort,
            channelEnt.entityIdStr

          # Reset socket to request new one.
          olAccept.info.socket = 0.SocketHandle
          # Continue to listen.
          channelEnt.awaitConnection(tcpListen.access)

        of csRead:
          # Read has completed.

          assert info.compRef.typeId == TcpRecv.typeId,
            "Expected TcpRead to complete read event but got " & $compRef.typeId
          let
            olRead = cast[ptr OverlappedRead](overlappedAddr)
            tcpRecv = info.compRef.index.TcpRecvInstance

          var totalBytes: DWORD
          let
            sizeSuccess {.used.} = getOverlappedResult(
              olRead.info.socket.Handle,
              overlappedAddr,
              totalBytes,
              false.WINBOOL
            )
            readSocket = olRead.info.socket
            completed = overlappedAddr.hasOverlappedIoCompleted
          
          template completeRecv(ol: untyped) =
            ol.info.state = csInvalid
            
            if completed or ol.singleRead:
              entity.add TcpRecvComplete()
            else:
              # Restart recv for this socket.
              # By default sockets are read until a zero length message
              # is sent.
              read(connection, tcpRecv)

          if totalBytes == 0:
            # Empty read signifies graceful connection shutdown.
            discard reportError("Reading", [ERROR_IO_PENDING])
            assert completed, "Expected overlapped read to have completed"
            
            log "Read completed", $readSocket,
              "Address: " & connection.remoteAddress,
              $connection.remotePort,
              $totalBytes & " bytes (connection closed)"

            entity.add TcpRecvComplete()
          else:
            # Process arrived data.
            assert connection.valid,
              "Invalid connection passed to tcpEvents: " & $connection & " for " & $state
            let incomingData = TcpRecvInstance(compRef.index)
            # Get local and remote addresses populated by acceptEx.

            log "Data received",
              "Address: " & connection.remoteAddress,
              $connection.remotePort,
              $totalBytes & " bytes "
            when logging in [tllEventsData, tllEventsLineNo]:
              log "Message: \"" & ($olRead.recvBuffer.buf) & "\""
            
            # Extend buffer and extract data.
            let
              curBufLen = incomingData.data.len
              totalData = curBufLen + totalBytes

            incomingData.data.setLen totalData

            copyMem(
              incomingData.data[curBufLen].addr,
              olRead.recvBuffer.buf[0].addr,
              totalBytes)

            let maxReadLength = tcpRecv.maxReadLength

            if maxReadLength > 0:
              # There is a known number of bytes expected.
              if totalData >= maxReadLength:
                log "Hit maximum read length", "Max read Length: " & $maxReadLength, "Bytes so far: " & $ totalBytes
                # This doesn't use completeRecv as exceeding maxReadLength
                # precludes restarting the read process.
                olRead.info.state = csInvalid
                entity.add TcpRecvComplete()
              else:
                olRead.info.state = csInvalid
                read(connection, tcpRecv)
            else:
              completeRecv olRead

        of csConnecting:
          assert info.compRef.typeId == TcpSend.typeId,
            "Expected a TcpSend to have initiated connect"
          assert connection.valid,
            "Invalid connection passed to tcpEvents: " & $connection & " for " & $state

          log "Connected", "Address: " & $connection.remoteAddress, $connection.remotePort
          
          entity.addIfMissing TcpConnected()

          let tcpSend = info.compRef.index.TcpSendInstance
          send(connection, tcpSend)

        of csSendInProgress:
          # A transport has completed a send operation.
          assert info.compRef.typeId == TcpSend.typeId,
            "Expected TcpSend to complete send event but got " & $compRef.typeId            
          let
            olSend = cast[ptr OverlappedSend](overlappedAddr)
            sendSocket = info.socket

          olSend.info.state = csInvalid

          log "Send completed", sendSocket,
            "Address: " & connection.remoteAddress,
            $connection.remotePort,
            $olSend.bytesSent & " bytes"
          when logging in [tllEventsData, tllEventsLineNo]:
            log "Message sent: \"" & $olSend.sendBuffer.buf.repr & "\""

          entity.add TcpSendComplete()

      processedCompletions += 1
      if sys.eventLimit > 0 and processedCompletions >= sys.eventLimit:
        break
    
    discard reportError("Poll completion port", [ERROR_IO_PENDING, WAIT_TIMEOUT])

    when logging in [tllEventsLineNo]:
      if processedCompletions > 0:
        networkLog defaultWidth, @["Events processed", $processedCompletions]

  proc read*[T: TcpRecv or TcpRecvInstance](connection: var TcpConnection, tcpRecv: var T, okValues: openarray[SomeInteger]) =
    discard beginRecv(tcpRecv.overlappedRead.addr, tcpRecv.bufferSize, okValues)

  template read*[T: TcpRecv or TcpRecvInstance](connection: TcpConnectionInstance, recv: T) =
    connection.access.read(recv.access, [ERROR_IO_PENDING])

  makeSystem("tcpListen", [TcpListen]):
    addedCallback:
      let ioPort = sysTcpEvents.ioPort
      item.tcpListen.socket = createListenSocket(item.tcpListen.port, ioPort)

      template olRead: untyped = item.tcpListen.overlappedRead
      olRead.listenSocket = item.tcpListen.socket
      olRead.info.ioPort = ioPort
      olRead.info.compRef = item.tcpListen.toRef
      olRead.info.entity = item.entity

      networkLog defaultWidth,
        ["<...  ", entityIdStr(item.entity), $olRead.listenSocket, "Listening on", $item.tcpListen.port]

      item.entity.awaitConnection(item.tcpListen.access)

  makeSystem("readTcp", [TcpConnection, TcpRecv]):
    addedCallback:
      # Adding a TcpRecv with TcpConnection immediately starts the
      # async receive operation.
      # This assumes that the socket in TcpConnection is connected.

      assert item.tcpConnection.ioPort.int != 0,
        "IOPort is not initialised. Ensure TcpConnection is added before adding TcpRecv"
      assert item.tcpConnection.socket.int != 0, "TcpConnection socket is not initialised"

      # Initialise the overlapped info.
      template info: untyped = item.tcpRecv.overlappedRead.info
      info.socket = item.tcpConnection.socket
      info.entity = item.entity
      info.connection = item.tcpConnection.toRef
      info.compRef = item.tcpRecv.toRef
      
      # Initiate the read operation.
      item.tcpConnection.read(item.tcpRecv)

  makeSystem("sendTcp", [TcpConnection, TcpSend]):
    addedCallback:
      # Immediately initiates a send operation through TcpConnection.
      template info: untyped = item.tcpSend.overlappedSend.info

      assert item.tcpConnection.ioPort.int != 0,
        "IOPort is not initialised. Ensure TcpConnection is added before adding TcpSend"
      assert item.tcpConnection.remotePort.int != 0, "TcpConnection.port must be supplied"

      # Initialise the overlapped info.
      info.connection = item.tcpConnection.toRef
      info.compRef = item.tcpSend.toRef
      info.entity = item.entity
      
      # Initiate the send operation.

      send(item.tcpConnection, item.tcpSend)

template defineTcpNetworking*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions): untyped {.dirty.} =
  defineTcpNetworking(compOpts, sysOpts, tllNone)



when isMainModule:

  # Tests some simple ping pong messages through localhost.
  #
  # The systems for client and server are distinguished with the Client
  # and Server components.

  # Each entity can act as a socket, allowing `maxEntities` concurrent
  # socket operations.

  const maxEntities = 100

  defineTcpNetworking(fixedSizeComponents(maxEntities), defaultSystemOptions, tllEvents)
  
  registerComponents(defaultComponentOptions):
    type
      Client = object
        replies, replyCount: int
      Server = object
      Exit = object

  makeSystem("serverReadEstablished", [Server, TcpConnection, TcpRecv, TcpSend, TcpRecvComplete]):
    # The server system reports incoming messages and replies with a message.
    all:
      echo "Server received message: ", item.tcpRecv.data

      item.tcpSend.data = item.tcpRecv.data & ", Pong"
      send(item.tcpConnection, item.tcpSend)

      item.tcpRecv.data.setLen 0
      read(item.tcpConnection, item.tcpRecv)

    finish:
      sys.remove TcpRecvComplete, TcpSendComplete

  makeSystem("serverReadInit", [Server, TcpConnection, TcpRecv, TcpRecvComplete]):
    # If TcpSend isn't already on the entity, we set it up here.
    all:
      echo "Server received message: ", item.tcpRecv.data
      item.entity.add TcpSend(data: item.tcpRecv.data & ", Pong")

      item.tcpRecv.data.setLen 0
      read(item.tcpConnection, item.tcpRecv)

    finish:
      sys.remove TcpRecvComplete

  makeSystem("clientRead", [Client, TcpSendComplete]):
    added:
      # Listen to replies after a message is sent.
      item.entity.addIfMissing TcpRecv()
    finish:
      sys.remove TcpSendComplete

  makeSystem("clientReply", [Client, TcpConnection, TcpSend, TcpRecv, TcpRecvComplete]):
    all:
      # We've received a reply to our message. Send another response.
      echo "Client received reply: ", item.tcpRecv.data
      item.client.replies += 1
      if item.client.replies <= item.client.replyCount:
        item.tcpSend.data = item.tcpRecv.data & ", Ping"
        item.tcpConnection.send item.tcpSend

        item.tcpRecv.data.setLen 0
        item.tcpConnection.read item.tcpRecv
      else:
        entity.add Exit()
    finish:
      sys.remove TcpRecvComplete

  # Record entity component changes to a log.
  var entityLog: array[maxEntities, string]
  onEntityChange:
    let
      logString = "Entity " & $entity.entityId.int &
        ": " & $state &
        ": " & $types
    entityLog[entity.entityId.int] &= "\n" & logString

  makeEcs()
  commitSystems("poll")

  let
    port = 1234.Port
    server {.used.} =
      newEntityWith(
        # This entity is a listen socket for a port.
        # When a connection is accepted, a new entity with TcpConnection
        # and TcpRecv are created.
        #
        # You can include your own components with the `onAccept` field.
        # Here it's used to distinguish connections for the server
        # systems defined above for this demo.
        TcpListen(
          port: port,
          onAccept: cl(Server()), # Entities will work with the Server systems.
        )
      )
    client =
      newEntityWith(
        # This entity will asynchronously connect to a remote host and
        # send some data.
        # As it uses the Client component, it uses a different set of
        # systems.
        # In this case, a response is then awaited for and then a further
        # response is sent.
        Client(replyCount: 3),    # Entity will work with Client systems.
        TcpConnection(            # Holds info about a potential or active connection.
          remoteAddress: "127.0.0.1",
          remotePort: port),
        TcpSend(data: "Ping"),   # Initiates a send operation using TcpConnection.
        # When a send has completed, the TcpSendComplete component is
        # added to the entity.
      )

  while not client.has(Exit):
    poll()
  
  # Display current state of all entities.
  echo "\nCurrent entity states:\n"
  forAllEntities:
    echo `$`(entity, false)
  
  # Display a log of component changes for entities.
  echo "\nEntity component history:"
  for log in entityLog:
    if log.len > 0:
      echo log

  flushGenlog()
