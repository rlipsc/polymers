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

  defineSystem("runQuery", [DatabaseConnection, Query], sysOpts)
  defineSystem("connectToDb", [ConnectToDb], sysOpts)

template addDatabaseSystems*: untyped =

  makeSystem("connectToDb", [ConnectToDb]):
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
      entity.removeComponent ConnectToDb

  makeSystem("runQuery", [DatabaseConnection, Query]):
    all:
      template db: untyped = item.databaseConnection
      if item.query.query != nil:
        discard entity.addOrUpdate QueryResult(
          title: item.query.title,
          data: item.query.query.executeFetch)
      else:
        var query = newQuery(db.connection)
        try:
          query.statement = item.query.statement
          discard entity.addOrUpdate QueryResult(
            title: item.query.title,
            data: query.executeFetch)
        finally:
          query.freeQuery

when isMainModule:
  const
    eo = defaultEntityOptions
    co = defaultComponentOptions
    so = defaultSystemOptions
  defineDatabaseComponents(co, so)
  addDatabaseSystems()

  makeEcs(eo)
  commitSystems("run")

  let ctdb = ConnectToDb(
    host: r"localhost\SQLEXPRESS",
    driver: "SQL Server Native Client 11.0",
    database: "test",
    userName: "",
    password: "",
    integratedSecurity: true,
    reportingLevel: rlErrorsAndInfo,
    reportDest: {rdStore, rdEcho}
  )

  let e = newEntityWith( ctdb, Query(statement: "SELECT 1 + 1") )
  run()

  let res = e.fetchComponent QueryResult
  assert res.valid
  echo "Result:\n", res.data

