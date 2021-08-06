import polymorph, polymers, json, random, times

const
  compOpts = fixedSizeComponents(100)
  entOpts = dynamicSizeEntities()
  sysOpts = dynamicSizeSystem()

defineTcpNetworking(compOpts, sysOpts)
defineHttp(compOpts, sysOpts)
defineJsonRpc(compOpts, sysOpts)

makeSystemOpts("dispatchRpcs", [JsonRpc], sysOpts):
  addedCallback:
    case item.jsonRpc.name
    of "currententities":
      let details =
        item.jsonRpc.params != nil and
        item.jsonRpc.params.kind == JNull and
        item.jsonRpc.params.hasKey "details"
      
      var entityInfo = newJArray()
      
      forAllEntities:
        var jsonComps = newJArray()

        if details:
          for c in entity.components:
            jsonComps.add(%*{$c.typeId: $c})
        else:
          for c in entity.components:
            jsonComps.add %($c.typeId)

        entityInfo.add(%*
          {
            "entityId": entity.entityId.int,
            "components": jsonComps
          }
        )
      item.entity.add JsonRpcResponse(
        kind: rpcResult,
        value: entityInfo
      )
    else:
      echo "Unknown method '" & item.jsonRpc.name & "'"
      item.entity.remove JsonRpc

makeEcs(entOpts)
commitSystems("run")

run()

let server =
  newEntityWith(
    TcpListen(
      port: 8080.Port,
      onAccept:
        cl(
          ProcessHttp(
            cors: initCorsOptions(
              allowOrigin = "*",
              allowMethods = "POST, OPTIONS",
              allowHeaders = "*",
              contentType = "application/json; charset=utf-8"
              )
          ),
          JsonRpcServer()
        )
    )
  )

while entityCount() > 0:
  run()
