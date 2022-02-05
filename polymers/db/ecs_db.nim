import polymorph

template defineDatabaseComponents*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions) {.dirty.} =
  import odbc
  registerComponents(compOpts):
    type
      ConnectToDb* = object
        connectionString*: string
        host*: string
        driver*: string
        database*: string
        username*: string
        password*: string
        integratedSecurity*: bool
        reportingLevel*: ODBCReportLevel
        reportDest*: set[ODBCReportDestination]
      
      DatabaseConnection* = object
        connectionString*: string
        host*: string
        database*: string
        connection*: ODBCConnection

      Query* = object
        title*: string
        statement*: string
        query*: SQLQuery

      QueryResult* = object
        title*: string
        data*: SQLResults

  DatabaseConnection.onRemove:
    curComponent.connection.close
  
  Query.onRemove:
    if curComponent.query != nil:
      curComponent.query.freeQuery()

template defineDatabaseSystems*(sysOpts: EcsSysOptions): untyped {.dirty.} =
  ## Perform the database queries.

  makeSystemOpts("connectToDb", [ConnectToDb], sysOpts):
    all:
      let existingCon = entity.fetchComponent DatabaseConnection
      if existingCon.valid:
        existingCon.connection.freeConnection
      var con = newODBCConnection()
      con.host = item.connectToDb.host
      con.driver = item.connectToDb.driver
      con.database = item.connectToDb.database
      con.userName = item.connectToDb.username
      con.password = item.connectToDb.password
      con.integratedSecurity = item.connectToDb.integratedSecurity
      con.reporting.level = item.connectToDb.reportingLevel
      con.reporting.destinations = item.connectToDb.reportDest

      let conStr = con.getConnectionString()
      if not con.connect:
        raise newODBCException("Could not connect to \"" & con.database & "\"")

      let
        newConnection = DatabaseConnection(
          connectionString: conStr,
          connection: con,
          host: con.host,
          database: con.database
        )
      if existingCon.valid: existingCon.update newConnection
      else: entity.addComponent newConnection
    finish:
      sys.remove ConnectToDb

  makeSystemOpts("runQuery", [DatabaseConnection, Query], sysOpts):
    all:
      template db: untyped = item.databaseConnection
      if item.query.query != nil:
        discard entity.addOrUpdate QueryResult(
          title: item.query.title,
          data: item.query.query.executeFetch)
      else:
        item.query.query = newQuery(db.connection)
        item.query.query.statement = item.query.statement
        discard entity.addOrUpdate QueryResult(
          title: item.query.title,
          data: item.query.query.executeFetch)

when isMainModule:
  const
    eo = defaultEntityOptions
    co = defaultComponentOptions
    so = defaultSystemOptions
  defineDatabaseComponents(co, so)
  defineDatabaseSystems(so)

  makeEcs(eo)
  commitSystems("run")

  let
    e = newEntityWith(
      ConnectToDb(
        host: r"localhost\SQLEXPRESS",
        driver: "SQL Server Native Client 11.0",
        database: "",
        userName: "",
        password: "",
        integratedSecurity: true,
        reportingLevel: rlErrorsAndInfo,
        reportDest: {rdStore, rdEcho}
      ),
      Query(statement: "SELECT 1 + 1")
    )

  run()

  let res = e.fetchComponent QueryResult
  assert res.valid
  echo "Result:\n", res.data

