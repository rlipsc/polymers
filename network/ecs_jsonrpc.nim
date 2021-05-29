import polymorph

template defineJsonRpc*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions, logging: static[bool]) {.dirty.} =
  ## Processes TcpRecv.data from JSON RPC format to user component types.
  ## JSON RPC format:
  ##   {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
  ##
  import json, strutils
  import times  

  static:
    if not (declared(TcpRecv) and declared(HttpRequest)):
      error "JSON RPC serving requires components and systems defined in " &
        "'defineTcpNetworking' from 'ecs_tcp.nim' and 'defineHttp' from " &
        "'ecs_http.nim' in the Polymers library"

  type JsonRpcResponseKind* = enum rpcResult, rpcError

  registerComponents(compOpts):
    type
      JsonRpcServer* = object
        id*: string

      JsonRpc* = object
        id*: string
        name*: string
        params*: JsonNode
      
      JsonRpcResponse* = object
        case kind: JsonRpcResponseKind
        of rpcResult:
          value*: JsonNode
        of rpcError:
          code*: int
          message*: string
          data: JsonNode
      
      JsonRpcTransit* = object

      JsonRpcResponseSent* = object

      RpcLog* = object
        entries*: seq[string]
  
  type
    RpcField* = enum
      rpcJsonRpc = "jsonrpc", rpcMethod = "method",
      rpcParams = "params", rpcId = "id"
    
    JsonState* = enum
      jsNoMethod = "missing method field"
      jsNoJsonRpc = "missing jsonrpc field"
      jsNoId = "missing id field"
      jsNotObject = "expected root type to be object"
      jsWrongVersion = "expected version 2.0"

  template appendLog*(entity: EntityRef, msg: string) =
    ## Add or update an RpcLog component with a message.
    when logging:
      echo "New log message ", msg
      var log = entity.fetchComponent RpcLog
      let timeStr = getDateStr() & " " & getClockStr()
      if log.valid:
        log.entries.add timeStr & ": " & msg
      else:
        discard entity.addOrUpdate RpcLog(entries: @[timeStr & ": " & msg])

  makeSystemOpts("processJsonRpc", [JsonRpcServer, HttpRequest], sysOpts):
    all:
      # See: https://www.jsonrpc.org/specification#request_object
      var
        parsed: bool
        node: JsonNode
      try:
        node = parseJson(item.httpRequest.body)
        if not node.hasKey($rpcParams):
          node.add($rpcParams, newJArray())
        parsed = true
      except Exception as e:
        appendLog(item.entity,
          "Cannot process input string: '" &
          item.httpRequest.body & "' " &
          "Error: " & e.msg)

      var jsIssues: seq[JsonState]

      if parsed:
        let versionNode = %"2.0"

        if node.kind != JObject: jsIssues.add jsNotObject
        if not node.hasKey($rpcMethod): jsIssues.add jsNoMethod
        if not node.hasKey($rpcJsonRpc): jsIssues.add jsNoJsonRpc
        if not node.hasKey($rpcId): jsIssues.add jsNoId
    
        let version = node[$rpcJsonRpc]
        if version == nil or version.kind != JString or
            version != versionNode:
          jsIssues.add jsWrongVersion

        if jsIssues.len == 0:
          # Valid json rpc object.
          let
            methodStr = node[$rpcMethod].str
            params = node[$rpcParams]
            id = node[$rpcId]
          
          item.jsonRpcServer.id = id.getStr

          let rpcTask = item.entity.add(
            JsonRpc(
              id: id.str,
              name: methodStr.toLowerAscii,
              params: params
            )
          )
        else:
          when logging:
            let reasons = jsIssues.join ", "
            appendLog(item.entity, "Invalid JSON RPC format: " &
              reasons)
          
          # This connection is now finished with.
          sys.deleteList.add item.entity
          #item.entity.removeComponent TcpRecvComplete
      else:
        echo "Failed to parse: ", item.httpRequest.body
    finish:
      sys.remove HttpRequest
  
  # makeSystemOpts("clearRequest", [HttpRequest], sysOpts):
  #   finish:
  #     sys.remove HttpRequest

  makeSystemOpts("processJsonRpcResponse", [JsonRpcServer, JsonRpcResponse], sysOpts):
    all:
      # See: https://www.jsonrpc.org/specification#response_object
      entity.remove TcpSendComplete

      case item.jsonRpcResponse.kind
      of rpcResult:
        discard entity.add(
          HttpResponse(
            code: Http200,
            body: $(%*
              {
                "jsonrpc": "2.0",
                "id": item.jsonRpcServer.id,
                "result": item.jsonRpcResponse.value
              })
            ))
        entity.addOrUpdate JsonRpcTransit()
      of rpcError:
        discard entity.add(
          HttpResponse(
            code: Http200,
            body:
              $(%*{
                "jsonrpc": "2.0",
                "id": item.jsonRpcServer.id,
                "error": {
                    "code": item.jsonRpcResponse.code,
                    "message": item.jsonRpcResponse.message,
                    "data":
                      if item.jsonRpcResponse.data != nil:
                        item.jsonRpcResponse.data                          
                      else: newJNull()
                  }
                }
              )
          ))
        entity.addOrUpdate JsonRpcTransit()
    finish:
      sys.remove JsonRpcResponse

  makeSystemOpts("cleanUpJsonRpc", [JsonRpcTransit, HttpResponseSent], sysOpts):
    all:
      echo "Response sent"
      entity.remove HttpResponseSent
      entity.remove JsonRpcTransit
      entity.add JsonRpcResponseSent()

template defineJsonRpc*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  defineJsonRpc(compOpts, sysOpts, true)

when isMainModule:
  import polymers

  const
    compOpts = fixedSizeComponents(100)
    entOpts = dynamicSizeEntities()
    sysOpts = dynamicSizeSystem()
  
  defineTcpNetworking(compOpts, sysOpts) #, tllEvents)
  defineHttp(compOpts, sysOpts)
  defineJsonRpc(compOpts, sysOpts)

  # JsonRpc and JsonRpcResponse are automatically removed from
  # the entity when the response is sent.

  makeSystemOpts("dispatchRpcs", [JsonRpc], sysOpts):
    all:
      case item.jsonRpc.name
      of "hello":
        item.entity.add JsonRpcResponse(
          kind: rpcResult,
          value: %* {"time": $now()}
        )
      else:
        item.entity.add JsonRpcResponse(
          kind: rpcError,
          message: "Unknown method " & item.jsonRpc.name
        )

  makeEcs(entOpts)
  commitSystems("run")
  
  run()

  let server =
    newEntityWith(
      TcpListen(
        port: 8080.Port,
        onAccept: cl(
          JsonRpcServer(),
          ProcessHttp(
            cors: initCorsOptions(
              allowOrigin = "*",
              allowMethods = "POST, DELETE, HEAD, GET, OPTIONS",
              allowHeaders = "*",
              contentType = "application/json; charset=utf-8"
            )
          )
        )
      )
    )
  let x = server.fetch TcpListen
  echo "Listening..."

  while entityCount() > 0:
    run()
  
  flushGenLog()