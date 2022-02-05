import polymorph, polymers, odbc, strutils

const
  entOpts = defaultEntityOptions
  sysOpts = defaultSystemOptions
  compOpts = defaultComponentOptions

defineRenderChar(compOpts)
defineConsoleEvents(compOpts, sysOpts)
defineDatabaseComponents(compOpts, sysOpts)

type DisplayRow = seq[tuple[ent: EntityRef, rs: RenderStringInstance]]

registerComponents(compOpts):
  type
    # For asking questions
    EditString = object
      xPos: int
    InputFinished = object

    # Current data converted to RenderStrings
    DisplayData = object
      x, y: float
      updated: bool
      titles: DisplayRow
      headers: DisplayRow
      rows: seq[DisplayRow]

    # These components act as constrained SQL queries
    FetchTables = object
    FetchTableFields = object
      table: string
    FetchTableData = object
      table: string

    # Tags combined with QueryResult
    Tables = object
    TableFields = object
      tableName: string
    TableData = object
      tableName: string

    # Navigation and selection with DisplayData
    LineCursor = object
      line: int
      lastLine: int

    # Signal to terminate
    Quit = object

DisplayData.onRemoveCallback:
  # Make sure all entities are deleted.
  for item in curComponent.titles:
    item.ent.delete
  curComponent.titles.setLen 0
  for item in curComponent.headers:
    item.ent.delete
  curComponent.headers.setLen 0
  for i, row in curComponent.rows:
    for item in row:
      item.ent.delete
    curComponent.rows[i].setLen 0
  curComponent.rows.setLen 0

defineSystem("resize",              [WindowEvent], sysOpts):
  lastX: uint16
  lastY: uint16
defineSystem("updateCursorPos",     [EditString, RenderString], sysOpts)

defineSystem("fetchTables",         [DatabaseConnection, FetchTables], sysOpts)
defineSystem("fetchTableFields",    [DatabaseConnection, FetchTableFields], sysOpts)
defineSystem("fetchTableData",      [DatabaseConnection, FetchTableData], sysOpts)

defineSystem("updateDisplay",       [QueryResult, DisplayData], sysOpts)
defineSystem("inputString",         [EditString, KeyDown, RenderString], sysOpts):
  numbersOnly: bool

# Update any created/altered RenderChar/RenderStrings
defineRenderCharSystems(sysOpts)
defineDatabaseSystems(sysOpts)

defineSystem("escape",              [EditString, KeyDown], sysOpts):
  escapePressed: bool

defineSystem("controlTables",       [Tables, DisplayData, KeyDown, LineCursor], sysOpts)
defineSystem("controlTableFields",  [TableFields, DisplayData, KeyDown, LineCursor], sysOpts)
defineSystem("controlTableData",    [TableData, DisplayData, KeyDown, LineCursor], sysOpts)

defineSystem("lineCursorNav",       [LineCursor, KeyDown], sysOpts)
defineSystem("dispLineCursor",      [LineCursor, DisplayData], sysOpts)

makeEcs(entOpts)

#---------------

template newEntry(textStr: string, coord: tuple[x, y: float]): tuple[ent: EntityRef, rs: RenderStringInstance] =
  # Create an entity with the given text as RenderString.
  let
    ent = newEntityWith(RenderString(text: textStr, x: coord[0], y: coord[1]))
    rs = ent.fetchComponent RenderString
  (ent, rs)

template clear(list: DisplayRow): untyped =
  for pair in list:
    sys.deleteList.add pair.ent
  list.setLen 0

template clear(displayData: DisplayDataInstance): untyped =
  displayData.titles.clear
  displayData.headers.clear
  for i in 0 ..< displayData.rows.len:
    displayData.rows[i].clear
  displayData.rows.setLen 0
  displayData.updated = false

makeSystem("resize", [WindowEvent]):
  all:
    let pos = item.windowEvent.size
    if pos.x.int > 0 and pos.y.int > 0 and
      (pos.x != sys.lastX or pos.y != sys.lastY):
        sysRenderChar.setDimensions pos.x, pos.y
        sysRenderString.setDimensions pos.x, pos.y
        eraseScreen()
        sys.lastX = pos.x
        sys.lastY = pos.y 
    item.entity.removeComponent WindowEvent

makeSystem("updateCursorPos", [EditString, RenderString]):
  all:
    let pos = charPos(item.renderString.x, item.renderString.y)
    setCursorPos pos.x + item.editString.xPos + 1, pos.y

makeSystem("fetchTables", [DatabaseConnection, FetchTables]):
  all:
    template con: untyped = item.databaseConnection.connection
    entity.addOrUpdate Tables()
    entity.addOrUpdate QueryResult(title: "Available Tables",
      data: con.dbq(
      """
      SELECT TABLE_NAME
      FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_CATALOG=?db
      """, ("db", con.database)
    ))
    entity.removeComponent FetchTables

makeSystem("fetchTableFields", [DatabaseConnection, FetchTableFields]):
  all:
    template con: untyped = item.databaseConnection.connection
    let
      table = item.fetchTableFields.table
      db = con.database
      titleStr = "Fields for Table \"" & table & "\""
    entity.addOrUpdate TableFields(tableName: table)
    entity.addOrUpdate QueryResult(title: titleStr, data: con.dbq(
      """
      SELECT c.*
      FROM INFORMATION_SCHEMA.TABLES t
      INNER JOIN INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME
      WHERE TABLE_TYPE = 'BASE TABLE' AND t.TABLE_CATALOG=?db AND t.TABLE_NAME=?tableName
      """, ("db", db), ("tableName", table)
    ))
    entity.removeComponent FetchTableFields

makeSystem("fetchTableData", [DatabaseConnection, FetchTableData]):
  all:
    template con: untyped = item.databaseConnection.connection
    let
      table = item.fetchTableData.table
      titleStr = "Data for Table \"" & table & "\""
    entity.addOrUpdate TableData(tableName: table)
    entity.addOrUpdate QueryResult(
      title: titleStr,
      # Table should be 'trusted' data from info_schema, otherwise
      # we can get injections since we can't use parameters here.
      data: con.executeFetch "SELECT TOP 2000 * FROM " & table)
    entity.removeComponent FetchTableData

makeSystem("updateDisplay", [QueryResult, DisplayData]):
  all:
    # Output the query as a table.
    template displayData: untyped = item.displayData
    if not displayData.updated:
      displayData.clear
      var
        (xo, yOffset) = centreCharCoord(displayData.x, displayData.y)
        xOffset = xo
      displayData.titles.add newEntry(item.queryResult.title, (xOffset, yOffset))
      displayData.titles[0].rs.colour = fgGreen
      displayData.titles[0].rs.backgroundColour = bgBlue

      let
        ch = sysRenderChar.charHeight
        colWidth = 0.3  # TODO: Dynamic.
        rows = item.queryResult.data.rows.len
        totalFields = item.queryResult.data.fieldCount
      yOffset += ch

      displayData.headers.setLen totalFields       
      for i in 0 ..< totalFields:
        xOffset = xo
        let field = item.queryResult.data.fields(i)
        displayData.headers[i] = newEntry(field.fieldName, (xOffset, yOffset))
        displayData.headers[i].rs.colour = fgGreen
        displayData.headers[i].rs.backgroundColour = bgBlue
      
      yOffset += ch

      displayData.rows.setLen rows
      for curLine, row in item.queryResult.data.rows:
        xOffset = xo
        for col in row:
          displayData.rows[curLine].add newEntry(col.asString, (xOffset, yOffset))
          xOffset += colWidth
        yOffset += ch

      displayData.updated = true

makeSystem("inputString", [EditString, KeyDown, RenderString]):
  # Turn a RenderString into an edit box.
  let validKeys = 
    if sys.numbersOnly: Digits
    else: Letters + Digits

  all:
    template xPos: untyped = item.editString.xPos
    template curLen: int = item.renderString.text.len

    var
      removeKeyDown: bool

    for i in countDown(item.keyDown.codes.high, 0):
      let aChar = chr(item.keyDown.chars[i])
      if aChar in validKeys:
        if xPos < curLen - 1:
          item.renderString.text.insert($aChar, xPos)
        else:
          item.renderString.text &= aChar
        xPos = min(xPos + 1, curLen - 1)
        removeKeyDown = consumeKey(item.keyDown, i)
      else:
        case item.keyDown.codes[i]
        of 14:
          # Delete
          if xPos >= 0 and curLen > 0:
            item.renderString.text.delete(xPos..xPos)
            xPos = max(xPos - 1, 0)
          removeKeyDown = consumeKey(item.keyDown, i)
        of 75:
          # Left
          xPos = max(xPos - 1, 0)
          removeKeyDown = consumeKey(item.keyDown, i)
        of 77:
          # Right
          xPos = min(curLen - 1, xPos + 1)
          removeKeyDown = consumeKey(item.keyDown, i)
        of 28:
          # Return
          entity.addOrUpdate InputFinished()
          removeKeyDown = consumeKey(item.keyDown, i)
        else:
          discard
    if removeKeyDown:
      entity.remove KeyDown

makeSystem("escape", [EditString, KeyDown]):
  all:
    # Handles exiting an EditString.
    item.keyDown.processKeys:
      if code == 1:
        sys.escapePressed = true
        if consumeKey(item.keyDown, keyIndex):
          entity.remove KeyDown
        break

makeSystem("controlTables", [Tables, DisplayData, KeyDown, LineCursor]):
  all:
    var
      removeKeyDown, removeTables: bool
    
    item.keyDown.processKeys:
      case code
      of 1:
        # Escape
        entity.addOrUpdate Quit()
      of 28:
        # Return
        let
          lineNo = item.lineCursor.line
          tableName = item.displayData.rows[lineNo][0].rs.text

        item.displayData.updated = false
        removeKeyDown = consumeKey(item.keyDown, keyIndex)
        entity.addComponent FetchTableData(table: tableName)
        removeTables = true
      of 33:
        # F
        let
          lineNo = item.lineCursor.line
          tableName = item.displayData.rows[lineNo][0].rs.text

        item.displayData.updated = false
        removeKeyDown = consumeKey(item.keyDown, keyIndex)
        entity.addComponent FetchTableFields(table: tableName)
        removeTables = true
      else:
        discard
    
      if removeKeyDown:
        entity.remove KeyDown
      if removeTables:
        entity.remove Tables

makeSystem("controlTableData", [TableData, DisplayData, KeyDown, LineCursor]):
  all:
    item.keyDown.processKeys:
      case code
      of 1:
        # Escape: Move back to table display.
        item.displayData.updated = false
        item.lineCursor.line = 0
        item.lineCursor.lastLine = -1
        entity.addComponent FetchTables()
        if consumeKey(item.keyDown, keyIndex):
          entity.remove KeyDown
        entity.removeComponent TableData
      else: discard

makeSystem("controlTableFields", [TableFields, DisplayData, KeyDown, LineCursor]):
  all:
    item.keyDown.processKeys:
      case code
      of 1:
        # Escape: Move back to table display.
        item.displayData.updated = false
        item.lineCursor.line = 0
        item.lineCursor.lastLine = -1
        entity.addComponent FetchTables()
        if consumeKey(item.keyDown, keyIndex):
          entity.remove KeyDown
        entity.removeComponent TableFields
      else: discard

makeSystem("lineCursorNav", [LineCursor, KeyDown]):
  all:
    let lc = item.lineCursor
    var removeKeyDown: bool
    for i in countDown(item.keyDown.codes.high, 0):
      case item.keyDown.codes[i]
      of 72:
        lc.line -= 1
        removeKeyDown = consumeKey(item.keyDown, i)
      of 80:
        lc.line += 1
        removeKeyDown = consumeKey(item.keyDown, i)
      else: discard
    if removeKeyDown:
      entity.remove KeyDown

makeSystem("dispLineCursor", [LineCursor, DisplayData]):
  all:
    template cursor: untyped = item.lineCursor
    template line(r: int): untyped = item.displayData.access.rows[r]
    template setCol(row: int, fg: ForegroundColor, bg: BackgroundColor, intense = false): untyped =
      if row >= 0 and row < item.displayData.access.rows.len:
        for col in 0 ..< line(row).len:
          let rs = line(row)[col].rs
          rs.colour = fg
          rs.backgroundColour = bg
          rs.forceUpdate = true
      
    let top = item.displayData.rows.high
    if cursor.line < 0: cursor.line = 0
    if cursor.line > top: cursor.line = top

    if cursor.lastLine != cursor.line:
      setCol(cursor.lastLine, fgWhite, bgBlack)

    setCol(cursor.line, fgRed, bgYellow, intense = true)
    cursor.lastLine = cursor.line

commitSystems("run")

proc ask(prompt: string, defaultText = "", x = -1.0, y = -1.0): string =
  let
    inputXOffset = prompt.len.float * sysRenderChar.charWidth
    prmt = newEntityWith(RenderString(text: prompt, x: x, y: y))
    cursorPos =
      if defaultText.len > 0: defaultText.high
      else: 0
    input = newEntityWith(RenderString(text: defaultText, x: x + inputXOffset, y: y), EditString(xPos: cursorPos), KeyChange())
  var done: bool
  while not done:
    run()
    if input.hasComponent InputFinished:
      result = input.fetchComponent(RenderString).text
      done = true
    else: done = sysEscape.escapePressed
  prmt.delete
  input.delete

proc main() =

  eraseScreen()
  setCursorPos 0, 0

  let
    hostName = ask("Enter host: ", r"localhost\SQLEXPRESS", y = -1.0)
    dbName = ask("Enter database: ", "master", y = -1.0 + sysRenderChar.charHeight)

  if hostName.strip == "":
    quit "\nPlease provide a host to connect to"
  
  if dbName.strip == "":
    quit "\nPlease provide a database to connect to"
  
  let dbBrowser =
    newEntityWith(
      ConnectToDb(
        host: hostName,
        driver: "SQL Server Native Client 11.0",
        database: dbName,
        userName: "",
        password: "",
        integratedSecurity: true,
        reportingLevel: rlErrorsAndInfo,
        reportDest: {}
      ),
      FetchTables(),  # Begin with listing the available tables.
      DisplayData(x: -1.0, y: -1.0),
      LineCursor(lastLine: -1),
      KeyChange(),
      WindowChange()
    )
  
  var finished: bool
  while not finished:
    run()

    finished = dbBrowser.hasComponent Quit

  dbBrowser.delete

main()
