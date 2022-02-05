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
    HttpResponseCode* = enum
      Http100 = "100 Continue",
      Http101 = "101 Switching Protocols",
      Http102 = "102 Processing",
      Http103 = "103 Early Hints",
      Http200 = "200 OK",
      Http201 = "201 Created",
      Http202 = "202 Accepted",
      Http203 = "203 Non-Authoritative Information",
      Http204 = "204 No Content",
      Http205 = "205 Reset Content",
      Http206 = "206 Partial Content",
      Http207 = "207 Multi-Status",
      Http208 = "208 Already Reported",
      Http226 = "226 IM Used",
      Http300 = "300 Multiple Choices",
      Http301 = "301 Moved Permanently",
      Http302 = "302 Found",
      Http303 = "303 See Other",
      Http304 = "304 Not Modified",
      Http305 = "305 Use Proxy",
      Http307 = "307 Temporary Redirect",
      Http308 = "308 Permanent Redirect",
      Http400 = "400 Bad Request",
      Http401 = "401 Unauthorized",
      Http402 = "402 Payment Required",
      Http403 = "403 Forbidden",
      Http404 = "404 Not Found",
      Http405 = "405 Method Not Allowed",
      Http406 = "406 Not Acceptable",
      Http407 = "407 Proxy Authentication Required",
      Http408 = "408 Request Timeout",
      Http409 = "409 Conflict",
      Http410 = "410 Gone",
      Http411 = "411 Length Required",
      Http412 = "412 Precondition Failed",
      Http413 = "413 Request Entity Too Large",
      Http414 = "414 Request-URI Too Long",
      Http415 = "415 Unsupported Media Type",
      Http416 = "416 Requested Range Not Satisfiable",
      Http417 = "417 Expectation Failed",
      Http418 = "418 I'm a teapot",
      Http421 = "421 Misdirected Request",
      Http422 = "422 Unprocessable Entity",
      Http423 = "423 Locked",
      Http424 = "424 Failed Dependency",
      Http425 = "425 Too Early",
      Http426 = "426 Upgrade Required",
      Http428 = "428 Precondition Required",
      Http429 = "429 Too Many Requests",
      Http431 = "431 Request Header Fields Too Large",
      Http451 = "451 Unavailable For Legal Reasons",
      Http500 = "500 Internal Server Error",
      Http501 = "501 Not Implemented",
      Http502 = "502 Bad Gateway",
      Http503 = "503 Service Unavailable",
      Http504 = "504 Gateway Timeout",
      Http505 = "505 HTTP Version Not Supported",
      Http506 = "506 Variant Also Negotiates",
      Http507 = "507 Insufficient Storage",
      Http508 = "508 Loop Detected",
      Http510 = "510 Not Extended",
      Http511 = "511 Network Authentication Required"

    HttpRequestMethod* = enum
      HttpUnknown,
      HttpHead,
      HttpGet,
      HttpPost,
      HttpPut,
      HttpDelete,
      HttpTrace,
      HttpOptions,
      HttpConnect,
      HttpPatch

    HttpReqHeader* = Table[string, seq[string]]
    HttpResHeader* = Table[string, string]
    HttpCors = enum
      corsAllowOrigin = "Access-Control-Allow-Origin"
      corsAllowMethods = "Access-Control-Allow-Methods"
      corsAllowHeaders = "Access-Control-Allow-Headers"
      corsContentType = "Content-Type"

    CorsOptions = array[HttpCors, string]

    HttpRedirectionState* = enum hrsOkay, hrsErrorCyclic, hrsEmpty

  const
    unknownHttpStatus = (code: 500, status: Http500)


  func toHttpStatus*(text: string): tuple[code: int, status: HttpResponseCode] =
    case text
      of "http100" : (100, Http101)                         
      of "http101" : (101, Http101)
      of "http102" : (102, Http102)
      of "http103" : (103, Http103)
      of "http200" : (200, Http200)
      of "http201" : (201, Http201)
      of "http202" : (202, Http202)
      of "http203" : (203, Http203)
      of "http204" : (204, Http204)
      of "http205" : (205, Http205)
      of "http206" : (206, Http206)
      of "http207" : (207, Http207)
      of "http208" : (208, Http208)
      of "http226" : (226, Http226)
      of "http300" : (300, Http300)
      of "http301" : (301, Http301)
      of "http302" : (302, Http302)
      of "http303" : (303, Http303)
      of "http304" : (304, Http304)
      of "http305" : (305, Http305)
      of "http307" : (307, Http307)
      of "http308" : (308, Http308)
      of "http400" : (400, Http400)
      of "http401" : (401, Http401)
      of "http402" : (402, Http402)
      of "http403" : (403, Http403)
      of "http404" : (404, Http404)
      of "http405" : (405, Http405)
      of "http406" : (406, Http406)
      of "http407" : (407, Http407)
      of "http408" : (408, Http408)
      of "http409" : (409, Http409)
      of "http410" : (410, Http410)
      of "http411" : (411, Http411)
      of "http412" : (412, Http412)
      of "http413" : (413, Http413)
      of "http414" : (414, Http414)
      of "http415" : (415, Http415)
      of "http416" : (416, Http416)
      of "http417" : (417, Http417)
      of "http418" : (418, Http418)
      of "http421" : (421, Http421)
      of "http422" : (422, Http422)
      of "http423" : (423, Http423)
      of "http424" : (424, Http424)
      of "http425" : (425, Http425)
      of "http426" : (426, Http426)
      of "http428" : (428, Http428)
      of "http429" : (429, Http429)
      of "http431" : (431, Http431)
      of "http451" : (451, Http451)
      of "http500" : (500, Http500)
      of "http501" : (501, Http501)
      of "http502" : (502, Http502)
      of "http503" : (503, Http503)
      of "http504" : (504, Http504)
      of "http505" : (505, Http505)
      of "http506" : (506, Http506)
      of "http507" : (507, Http507)
      of "http508" : (508, Http508)
      of "http510" : (510, Http510)
      of "http511" : (511, Http511)
      else: unknownHttpStatus


  func toRequestMethod*(value: string): HttpRequestMethod =
    case value
      of "HEAD": HttpHead
      of "GET": HttpGet 
      of "POST": HttpPost
      of "PUT": HttpPut
      of "DELETE": HttpDelete
      of "TRACE": HttpTrace 
      of "OPTIONS": HttpOptions
      of "CONNECT": HttpConnect
      of "PATCH": HttpPatch
      else: HttpUnknown


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
        status*: HttpResponseCode
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

    msgLen += httpVer.len + len($response.status) + termLen
    
    for k, v in response.headers.pairs:
      msgLen += k.len + 2 + v.len + termLen

    buf.setLen msgLen +
      termLen +
      response.body.len +
      termLen
    
    # Copy httpResponse data to message buffer.

    var p: int
    p = buf.overwrite(p, httpVer & $response.status & term)
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
    var curLine: int

    for i, line in ds.lines:
      if curLine == 0:
        let
          uriPos = line.find('/')
          verPos = line.find(' ', uriPos)
        assert uriPos > -1 and verPos > -1,
          "Expected '<HTTP method> <URL> <HTTP version>' in request type header"

        req.httpMethod = strip(line[0 ..< uriPos]).toLowerAscii.toRequestMethod
        # URL includes the '/' separator.
        req.url = strip(line[uriPos ..< verPos])
        req.httpVersion = strip(line[verPos + 1 .. ^1])

      elif line.len == 0:
        req.body = ds[i .. ^1]
        break
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
        
        response.status = strip(line[charPos .. ^1]).toLowerAscii.toHttpStatus.status

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

          let resp = entity.add HttpResponse(status: Http204)

          for access, value in item.processHttp.cors:
            if value.len > 0:
              resp.headers[$access] = value

          # We expect another response from the client if CORS validates.
          item.tcpRecv.data.setLen 0
        else:
          item.tcpRecv.data.setLen 0
          entity.addComponent request

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

        item.tcpConnection.send(tcpSend, [ERROR_IO_PENDING, WSAECONNRESET])
      else:
        discard item.entity.add TCPSend(data: buf)


  makeSystemOpts("markSent", [ProcessHttp, HttpResponse, TcpSendComplete], sysOpts):
    all:
      entity.addOrUpdate HttpResponseSent()
    sys.remove HttpResponse, TcpSendComplete


  makeSystemOpts("handleRedirects", [HttpRedirecting, HttpRequest, HttpResponse], sysOpts):
    addedCallback:
      const prefix = "HTTP redirection"
      # HTTP responses from requests that return a redirection are tagged here.
      # The user may specify components to be added with 'httpRedirection.onRedirect'.
      # The 'HttpRedirection' is always added.
      if item.httpResponse.status == Http301:
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
            status: Http404
          )
      else:
        networkLog ["  >-", entityIdStr(item.entity), "Route accepted", item.httpRequest.url]


when isMainModule:
  import polymers
  const
    compOpts = fixedSizeComponents(100)
    sysOpts = defaultSysOpts
  defineTcpNetworking(compOpts, sysOpts)
  defineHttp(compOpts, sysOpts)

  makeEcs()
  commitSystems "poll"
