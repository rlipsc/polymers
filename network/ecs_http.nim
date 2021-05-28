import polymorph

template defineHttp*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions): untyped {.dirty.} =
  ## Define components and systems for HTTP processing.
  ## Requires ecs_tcp.
  
  static:
    if not declared(TcpRecv):
      error "Web serving requires components and systems defined in " &
        "'defineTcpNetworking' from 'ecs_tcp.nim' in the Polymers library"
  
  import tables, strutils
  from winlean import getLastError
  from times import now, format

  type
    HttpRequestMethod* = enum
      HttpHead = "HEAD"
      HttpGet = "GET"
      HttpPos = "POST"
      HttpPut = "PUT"
      HttpDelete = "DELETE"
      HttpTrace = "TRACE"
      HttpOptions = "OPTIONS"
      HttpConnect = "CONNECT"
      HttpPatch = "PATCH"

    HttpResponseCode* = enum
      Http100 = (100, "100 Continue")
      Http101 = (101, "101 Switching Protocols")
      Http102 = (102, "102 Processing")
      Http103 = (103, "103 Early Hints")
      Http200 = (200, "200 OK")
      Http201 = (201, "201 Created")
      Http202 = (202, "202 Accepted")
      Http203 = (203, "203 Non-Authoritative Information")
      Http204 = (204, "204 No Content")
      Http205 = (205, "205 Reset Content")
      Http206 = (206, "206 Partial Content")
      Http207 = (207, "207 Multi-Status")
      Http208 = (208, "208 Already Reported")
      Http226 = (226, "226 IM Used")
      Http300 = (300, "300 Multiple Choices")
      Http301 = (301, "301 Moved Permanently")
      Http302 = (302, "302 Found")
      Http303 = (303, "303 See Other")
      Http304 = (304, "304 Not Modified")
      Http305 = (305, "305 Use Proxy")
      Http307 = (307, "307 Temporary Redirect")
      Http308 = (308, "308 Permanent Redirect")
      Http400 = (400, "400 Bad Request")
      Http401 = (401, "401 Unauthorized")
      Http402 = (402, "402 Payment Required")
      Http403 = (403, "403 Forbidden")
      Http404 = (404, "404 Not Found")
      Http405 = (405, "405 Method Not Allowed")
      Http406 = (406, "406 Not Acceptable")
      Http407 = (407, "407 Proxy Authentication Required")
      Http408 = (408, "408 Request Timeout")
      Http409 = (409, "409 Conflict")
      Http410 = (410, "410 Gone")
      Http411 = (411, "411 Length Required")
      Http412 = (412, "412 Precondition Failed")
      Http413 = (413, "413 Request Entity Too Large")
      Http414 = (414, "414 Request-URI Too Long")
      Http415 = (415, "415 Unsupported Media Type")
      Http416 = (416, "416 Requested Range Not Satisfiable")
      Http417 = (417, "417 Expectation Failed")
      Http418 = (418, "418 I'm a teapot")
      Http421 = (421, "421 Misdirected Request")
      Http422 = (422, "422 Unprocessable Entity")
      Http423 = (423, "423 Locked")
      Http424 = (424, "424 Failed Dependency")
      Http425 = (425, "425 Too Early")
      Http426 = (426, "426 Upgrade Required")
      Http428 = (428, "428 Precondition Required")
      Http429 = (429, "429 Too Many Requests")
      Http431 = (431, "431 Request Header Fields Too Large")
      Http451 = (451, "451 Unavailable For Legal Reasons")
      Http500 = (500, "500 Internal Server Error")
      Http501 = (501, "501 Not Implemented")
      Http502 = (502, "502 Bad Gateway")
      Http503 = (503, "503 Service Unavailable")
      Http504 = (504, "504 Gateway Timeout")
      Http505 = (505, "505 HTTP Version Not Supported")
      Http506 = (506, "506 Variant Also Negotiates")
      Http507 = (507, "507 Insufficient Storage")
      Http508 = (508, "508 Loop Detected")
      Http510 = (510, "510 Not Extended")
      Http511 = (511, "511 Network Authentication Required")

    HttpReqHeader* = Table[string, seq[string]]
    HttpResHeader* = Table[string, string]
    HttpCors = enum
      corsAllowOrigin = "Access-Control-Allow-Origin"
      corsAllowMethods = "Access-Control-Allow-Methods"
      corsAllowHeaders = "Access-Control-Allow-Headers"
      corsContentType = "Content-Type"

    CorsOptions = array[HttpCors, string]

    HttpRedirectionState* = enum hrsOkay, hrsErrorCyclic, hrsEmpty

  proc initCorsOptions*(allowOrigin, allowMethods, allowHeaders, contentType = ""): CorsOptions =
    [allowOrigin, allowMethods, allowHeaders, contentType]

  registerComponents(compOpts):
    type
      ProcessHttp* = object
        cors*: CorsOptions
      HttpRequest* = object
        httpMethod*: HttpRequestMethod
        httpVersion*: string
        url*: string
        headers*: HttpReqHeader
        body*: string
      HttpResponse* = object
        httpVersion*: string
        headers*: HttpResHeader
        code*: HttpResponseCode
        body*: string
      HttpRouteEntity* = object
        patterns*: seq[tuple[path: string, onAccept: ComponentList]]
        otherwise*: ComponentList
      HttpResponseSent* = object
      HttpRedirecting* = object
        accumulated*: seq[string]
        onRedirect*: ComponentList
      HttpRedirection* = object
        url*: string
        state*: HttpRedirectionState

    const
      maxHeaders* = 1024
      maxLineLen* = 1024 * 8

  func apply(cors: CorsOptions, response: var HttpResHeader) =
    for access, value in cors:
      if value.len > 0 and not(response.hasKey($access)):
        response[$access] = value

  template optionsSummary(processHttp: ProcessHttp | ProcessHttpInstance): string =
    var res: string
    for access, value in processHttp.cors:
      if value.len > 0:
        template itemStr: untyped = $access & ": \"" & value & "\""
        if res.len > 0: res &= ", " & itemStr()
        else: res &= itemStr()
    res

  proc checkMinHeaders*(headers: var HttpResHeader, bodyLen: int) =
    if not headers.hasKey "Date":
      headers["Date"] =
        now().format("ddd, dd MMM yyyy HH:mm:ss") & " GMT"

    if not headers.hasKey "Content-Length":
      headers["Content-Length"] =
        $(bodyLen)
    
    if not headers.hasKey "Connection":
      headers["Connection"] = "keep-alive"

    # if not headers.hasKey "Content-type":
    #   headers["Content-type"] =
    #     "text/plain; charset=utf-8"

  proc toDS*(response: HttpResponse, buf: var DataString) =
    const
      term = "\r\L"
      termLen = term.len
      httpVer = "HTTP/1.0 "
    var msgLen: int

    # Calculate message size to avoid resize allocations.

    msgLen += httpVer.len + len($response.code) + termLen
    
    for k, v in response.headers.pairs:
      msgLen += k.len + 2 + v.len + termLen

    buf.setLen msgLen +
      termLen +
      response.body.len +
      termLen
    
    # Copy httpResponse data to message buffer.

    var p: int
    p = buf.overwrite(p, httpVer & $response.code & term)
    for k, v in response.headers.pairs:
      p = buf.overwrite(p, k & ": " & v & term)
    p = buf.overwrite(p, term)
    p = buf.overwrite(p, response.body)
    p = buf.overwrite(p, term)

  proc toDS*(request: HttpRequest, buf: var DataString) =
    const
      term = "\r\L"
      termLen = term.len
    var msgLen: int
    let httpMethod = $request.httpMethod & " "

    # Calculate message size to avoid resize allocations.

    let
      httpVersion =
        if request.httpVersion.len == 0: "HTTP/1.0"
        else: request.httpVersion

    msgLen += httpMethod.len + request.url.len + 1 + httpVersion.len + termLen

    for k, v in request.headers.pairs:
      msgLen += k.len + 2
      for str in v:
        msgLen += str.len + termLen

    buf.setLen msgLen +
      termLen +
      request.body.len +
      termLen
    
    # Copy httpRequest data to message buffer.
  
    var p: int
    p = buf.overwrite(p, httpMethod)
    p = buf.overwrite(p, request.url & " ")
    p = buf.overwrite(p, httpVersion & term)
    for k, v in request.headers.pairs:
      # Items in a request header are added as comma separated values.
      if v.len > 0:
        p = buf.overwrite(p, k & ": ")
        p = buf.overwrite(p, v[0])
        if v.len > 1:
          for str in v[1 .. ^1]:
            p = buf.overwrite(p, ", " & str)
      p = buf.overwrite(p, term)
    p = buf.overwrite(p, term)
    p = buf.overwrite(p, request.body)
    p = buf.overwrite(p, term)

  proc fromDs*(req: var HttpRequest, ds: var DataString) =
    ## Populate an HttpHeader with a DataString.
    var curLine, bodyStart: int
    
    for i, line in ds.lines:
      if curLine == 0:
        let
          uriPos = line.find('/')
          verPos = line.find(' ', uriPos)
        assert uriPos > -1 and verPos > -1,
          "Expected '<HTTP method> <URL> <HTTP version>' in request type header"

        req.httpMethod = parseEnum[HttpRequestMethod](strip(line[0 ..< uriPos]))
        # URL includes the '/' separator.
        req.url = strip(line[uriPos ..< verPos])
        req.httpVersion = strip(line[verPos + 1 .. ^1])

      elif line.len == 0:
        bodyStart = i
      else:
        let sepPos = line.find(':')

        if sepPos > -1:
          # Split comma separated values.
          var s: seq[string]
          for value in line[sepPos + 1 .. ^1].split(','):
            s.add strip(value)
          req.headers[strip(toLowerAscii(line[0 ..< sepPos]))] = s
        else:
          req.headers[strip(toLowerAscii(line))] = @[""]
      curLine.inc
      if bodyStart > 0:
        req.body = ds[bodyStart .. ^1]

  proc fromDs*(response: var HttpResponse, ds: var DataString, populateBody = true): Natural {.discardable.} =
    ## Populate an HttpHeader with a DataString.
    ## Returns the index to the body of the request.
    var
      firstLine = true
      bodyStart: int
    
    for i, line in ds.lines:

      if unlikely(firstLine):
        firstLine = false

        var charPos: Natural
        let firstSpace = line.find(' ')

        if firstSpace > -1:
          response.httpVersion = line[charPos ..< firstSpace]
          charPos = firstSpace + 1
        
        assert charPos < line.len, "Unexpected format in HTTP response: '" & line & "'"
        
        response.code = parseEnum[HttpResponseCode](strip(line[charPos .. ^1]))

      elif line.len == 0:
        bodyStart = i
        break
      else:
        let sepPos = line.find(':')

        if sepPos > -1:
          # Split comma separated values.
          response.headers[strip(toLowerAscii(line[0 ..< sepPos]))] = strip(line[sepPos + 1 .. ^1])
        else:
          response.headers[strip(toLowerAscii(line))] = ""

      if populateBody and bodyStart > 0:
        response.body = ds[bodyStart .. ^1]
    bodyStart

  makeSystemOpts("processHttp", [ProcessHttp, TcpRecv, TcpRecvComplete], sysOpts):
    # This system processes incoming TCP messages to HttpRequest.
    all:
      # See: https://tools.ietf.org/html/rfc2616#section-4.1

      if item.tcpRecv.data.len >= 16: # Minimum HTTP header size.
        # Note: data less than the minimum length is untouched, but
        # TcpRecvComplete is always removed.
        
        var request: HttpRequest
        # TODO: Max line (998), max number of headers and other DDOS hygiene.

        request.fromDs(item.tcpRecv.data)

        if request.httpMethod == HttpOptions:
          # This is a request for permissions, such as a CORS preflight request.

          const width = 20
          networkLog width,
            @["OPTIONS requested",
              "URL: " & request.url,
              "Origin: " & request.headers.getOrDefault("origin").join(", "),
              "Response: " & optionsSummary(item.processHttp)]

          # var corsHeader: HttpResHeader

          # for access, value in item.processHttp.cors:
          #   if value.len > 0:
          #     corsHeader[$access] = value

          let resp = item.entity.add HttpResponse(code: Http204)

          for access, value in item.processHttp.cors:
            if value.len > 0:
              resp.headers[$access] = value

          # We expect another response from the client if CORS validates.
          item.tcpRecv.data.setLen 0
        else:
          item.tcpRecv.data.setLen 0
          item.entity.addComponent request
    finish:
      sys.remove TcpRecvComplete

  makeSystemOpts("processHttpResponse", [ProcessHttp, TcpConnection, TcpRecv, HttpResponse], sysOpts):
    addedCallback:

      item.entity.remove TcpSendComplete

      var
        # Heap memory for `buf` is transferred to `TcpSend.data`.
        # Do not dispose `buf` here!
        buf: DataString

      item.processHttp.cors.apply item.httpResponse.headers
      checkMinHeaders(item.httpResponse.headers, item.httpResponse.body.len)

      item.httpResponse.access.toDS buf

      let tcpSend = item.entity.fetch TcpSend
      if tcpSend.valid:
        assert tcpSend.overlappedSend.info.state == csInvalid,
          "TcpSend is in use. State: " &
          $tcpSend.overlappedSend.info.state &
          "\nTcpSend buffer contents: " &
          $tcpSend.overlappedSend.sendBuffer.buf

        # Transfer management of heap buffer in `buf` to tcpSend.
        buf.transfer tcpSend.data

        item.tcpConnection.send(tcpSend)
      else:
        discard item.entity.add TCPSend(data: buf)
  
  makeSystemOpts("markSent", [ProcessHttp, HttpResponse, TcpSendComplete], sysOpts):
    all:
      entity.remove HttpResponse
      entity.addOrUpdate HttpResponseSent()
      entity.remove TcpSendComplete

  makeSystemOpts("handleRedirects", [HttpRedirecting, HttpRequest, HttpResponse], sysOpts):
    addedCallback:
      const prefix = "HTTP redirection"
      # HTTP responses from requests that return a redirection are tagged here.
      # The user may specify components to be added with 'httpRedirection.onRedirect'.
      # The 'HttpRedirection' is always added.
      if item.httpResponse.code == Http301:
        let location = item.httpResponse.headers.getOrDefault "location"
        var redir = HttpRedirection(url: location)

        if location.len == 0:
          redir.state = hrsEmpty

          networkLog @[prefix, "Redirect without suggested location"]

        else:
          for loc in item.httpRedirecting.accumulated:
            if cmpIgnoreCase(loc, location) == 0:

              redir.state = hrsErrorCyclic
              networkLog @[prefix, "Cyclic redirection", location]
              break

          # Cyclic urls will appear twice in 'accumulated'.
          item.httpRedirecting.accumulated.add location
          
        networkLog @[prefix, "Redirection", $redir.state, location]

        # Include redirection component.
        item.entity.addOrUpdate redir
        
        # Add user components.
        if redir.state == hrsOkay and item.httpRedirecting.onRedirect.len > 0:
          item.entity.addOrUpdate item.httpRedirecting.onRedirect

  makeSystemOpts("routeEntity", [HttpRequest, HttpRouteEntity], sysOpts):
    addedCallback:
      var found: bool
      for route in item.httpRouteEntity.patterns:
        # TODO: Proper patterns.
        if cmpIgnoreCase(item.httpRequest.url, route.path) == 0:
          found = true
          item.entity.add route.onAccept
          break
      if not found:
        networkLog ["", entityIdStr(item.entity), "Route not found", item.httpRequest.url]
        if item.httpRouteEntity.otherwise.len > 0:
          item.entity.add item.httpRouteEntity.otherwise
        else:
          item.entity.add HttpResponse(
            code: Http404
          )
      else:
        networkLog ["", entityIdStr(item.entity), "Route accepted", item.httpRequest.url]


