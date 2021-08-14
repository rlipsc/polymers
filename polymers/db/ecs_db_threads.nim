import polymorph

template defineThreadedDatabaseComponents*(compOpts: ECSCompOptions) {.dirty.} =
  import odbc, threadpool
  type
    QueryParam = tuple[field: string, value: SQLParam]
    QueryParams = seq[QueryParam]

  registerComponents(compOpts):
    type
      DBConnectionInfo* = object
        connectionString*: string
        host*: string
        driver*: string
        database*: string
        username*: string
        password*: string
        integratedSecurity*: bool
        reportingLevel*: ODBCReportLevel
        reportDest*: set[ODBCReportDestination]
      
      ThreadQuery* = object
        title*: string
        statement*: string
        params*: QueryParams
        dispatched*: bool
        # Don't remove the component after dispatch.
        # When persistent is true, setting dispatched = false
        # will cause the query to be run again.
        persistent*: bool

      QueryRunning* = object
        pending: seq[tuple[title: string, fv: FlowVar[seq[SQLRow]]]]

      QueryResult* = object
        title*: string
        data*: SQLResults
        errors*: seq[string]

template defineThreadedDatabaseSystems*(sysOpts: ECSSysOptions): untyped {.dirty.} =
  ## Perform the database queries.
  proc doExecQuery(connectionInfo: DBConnectionInfo, queryText: string, params: QueryParams): seq[SQLRow] {.gcSafe.} =
    var con = newODBCConnection()
    try:
      con.host = connectionInfo.host
      con.driver = connectionInfo.driver
      con.database = connectionInfo.database
      con.userName = connectionInfo.username
      con.password = connectionInfo.password
      con.integratedSecurity = connectionInfo.integratedSecurity
      con.reporting.level = connectionInfo.reportingLevel
      con.reporting.destinations = connectionInfo.reportDest
      if con.connect:
        var query = con.newQuery(queryText)
        try:
          for param in params:
            #echo param.value
            query.params[param.field] = param.value
          query.open
          var row: SQLRow
          while query.fetchRow(row):
            result.add row
        finally:
          query.freeQuery
    finally:
      con.freeConnection

  makeSystemOpts("runQuery", [DBConnectionInfo, ThreadQuery], sysOpts):
    all:
      if not item.threadQuery.dispatched:
        item.threadQuery.dispatched = true
        let qr = entity.fetchComponent QueryRunning
        if qr.valid:
          qr.pending.add(
            (
              title: item.threadQuery.title,
              fv: spawn doExecQuery(
                item.dbConnectionInfo.access,
                item.threadQuery.statement,
                item.threadQuery.params)
            )
          )
        else:
          entity.addComponent QueryRunning(
            pending: @[(
              title: item.threadQuery.title,
              fv: spawn doExecQuery(
                item.dbConnectionInfo.access,
                item.threadQuery.statement,
                item.threadQuery.params)
              )
            ])
        if not item.threadQuery.persistent:
          entity.removeComponent ThreadQuery

  makeSystemOpts("pendingQueries", [QueryRunning], sysOpts):
    all:
      for i in countDown(item.queryRunning.pending.high, 0):
        template curPending: untyped = item.queryRunning.pending[i]
        if curPending.fv.isReady:
          discard entity.addOrUpdate QueryResult(
            title: curPending.title,
            data: SQLResults(rows: ^curPending.fv))
          
          item.queryRunning.pending.del(i)
      
      if item.queryRunning.pending.len == 0:
        entity.removeComponent QueryRunning

when isMainModule:
  const
    eo = defaultEntityOptions
    co = defaultComponentOptions
    so = defaultSystemOptions
  defineThreadedDatabaseComponents(co)
  defineThreadedDatabaseSystems(so)

  makeEcs(eo)
  commitSystems("run")

  let ctdb = DBConnectionInfo(
    host: r"localhost\SQLEXPRESS",
    driver: "SQL Server Native Client 11.0",
    database: "test",
    userName: "",
    password: "",
    integratedSecurity: true,
    reportingLevel: rlErrorsAndInfo,
    reportDest: {rdEcho}
  )

  let e = newEntityWith( ctdb, ThreadQuery(statement: "SELECT 1 + ?v", params: @[("v", 7.initParam)]) )
  echo "Initial state:\n", e.listComponents(showData = false)
  
  run()

  echo "Post-first tick state:\n", e.listComponents(showData = false)
  echo "Awaiting..."
  var ticker = 0
  while sysPendingQueries.count > 0:
    run()
    ticker.inc
  echo "\nResult arrived, state (ticks: ", ticker, "):\n", e.listComponents(showData = false)

  let res = e.fetchComponent QueryResult
  assert res.valid
  echo "Result:\n", res.data

