import polymorph

template defineJsonRpc*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions, logging: static[bool]) {.dirty.} =
  ## Processes TcpRecv.data from JSON RPC format to user component types.
  ## JSON RPC format:
  ##   {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
  ##
  import json, strutils, times

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
      echo "Log: ", msg
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
          "Cannot process JSON in HTTP body: '" &
          item.httpRequest.body & "' " &
          "Error: " & e.msg & "\n" &
          "Headers: " & $item.httpRequest.headers)

      if parsed:
        let versionNode = %"2.0"
        var jsIssues: set[JsonState]

        if node.kind != JObject: jsIssues.incl jsNotObject
        if not node.hasKey($rpcMethod): jsIssues.incl jsNoMethod
        if not node.hasKey($rpcJsonRpc): jsIssues.incl jsNoJsonRpc
        if not node.hasKey($rpcId): jsIssues.incl jsNoId

        if jsNoJsonRpc notin jsIssues:
          let version = node[$rpcJsonRpc]
          if version == nil or version.kind != JString or
              version != versionNode:
            jsIssues.incl jsWrongVersion

        if jsIssues.len == 0:
          # Valid json rpc object.
          let
            methodStr = node[$rpcMethod].str
            params = node[$rpcParams]
            id = node[$rpcId]
          
          item.jsonRpcServer.id = id.getStr

          discard item.entity.add(
            JsonRpc(
              id: $id,
              name: methodStr.toLowerAscii,
              params: params
            )
          )
        else:
          var reasons: string
          for item in jsIssues:
            if reasons.len > 0: reasons &= ", " & $item
            else: reasons &= $item

          when logging:
            appendLog(item.entity, "Invalid JSON RPC format: " &
              reasons)

          entity.add JsonRpcResponse(
            kind: rpcError,
            code: -32600,
            message: "Invalid request",
            data: newJString(reasons)
          )
      else:
        entity.add JsonRpcResponse(
          kind: rpcError,
          code: -32700,
          message: "Parse error"
        )

    finish:
      sys.remove HttpRequest

  makeSystemOpts("processJsonRpcResponse", [JsonRpcServer, JsonRpcResponse], sysOpts):
    all:
      # See: https://www.jsonrpc.org/specification#response_object
      entity.remove TcpSendComplete

      case item.jsonRpcResponse.kind
      of rpcResult:
        discard entity.add(
          HttpResponse(
            status: Http200,
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
            status: Http200,
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
          ),
          JsonRpcTransit(),
          )
    finish:
      sys.remove JsonRpcResponse

  makeSystemOpts("completeJsonRpcSend", [JsonRpcTransit, HttpResponseSent], sysOpts):
    addedCallback:
      sys.deleteList.add entity

template defineJsonRpc*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  defineJsonRpc(compOpts, sysOpts, true)

when isMainModule:
  import polymers

  const
    compOpts = fixedSizeComponents(100)
    entOpts = dynamicSizeEntities()
    sysOpts = dynamicSizeSystem()
  
  defineTcpNetworking(compOpts, sysOpts, tllEvents)
  defineHttp(compOpts, sysOpts)
  defineJsonRpc(compOpts, sysOpts)

  # JsonRpc and JsonRpcResponse are automatically removed from
  # the entity when the response is sent.

  makeSystemOpts("dispatchRpcs", [JsonRpc], sysOpts):
    addedCallback:
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

  let server {.used.} =
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
  echo "Listening..."

  while entityCount() > 0:
    run()
  
  flushGenLog()