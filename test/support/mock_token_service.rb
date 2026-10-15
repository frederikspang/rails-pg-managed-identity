# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "uri"

# Stands in for Azure's token endpoints, speaking just enough HTTP/1.1 for Net::HTTP:
#
#   GET  /metadata/identity/oauth2/token  Azure Instance Metadata Service (VMs, scale sets, AKS nodes)
#   GET  /msi/token                        App Service, Functions, Container Apps (IDENTITY_ENDPOINT)
#   POST /:tenant/oauth2/v2.0/token        Microsoft Entra ID (workload identity, client secret)
#
# Requests are validated the way the real endpoints validate them (required headers, api-version,
# grant parameters). Every issued token is passed to the on_issue block, which the integration tests
# use to make PostgreSQL accept exactly that token.
class MockTokenService
  IDENTITY_HEADER = "mock-identity-header"
  JWT_BEARER = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  TOKEN_LIFETIME = 3600

  Request = Data.define(:verb, :path, :params, :headers)
  Issued = Data.define(:token, :expires_on)

  def initialize(&on_issue)
    @on_issue = on_issue
    @mutex = Mutex.new
    @requests = []
    @issued = []
    @failures_left = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port
    @server.addr[1]
  end

  def url(path = "")
    "http://127.0.0.1:#{port}#{path}"
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def issued
    @mutex.synchronize { @issued.dup }
  end

  # The next `times` requests fail with this status, whatever they ask for. Float::INFINITY keeps
  # failing until #reset!.
  def fail_next(status, error: "temporarily_unavailable", description: "Mock failure", times: 1)
    @mutex.synchronize do
      @failure = [status, { error:, error_description: description }]
      @failures_left = times
    end
  end

  def reset!
    @mutex.synchronize do
      @requests.clear
      @issued.clear
      @failures_left = 0
    end
  end

  def stop
    @server.close
    @thread.join
  end

  private

  def serve
    loop { Thread.new(@server.accept) { |socket| handle(socket) } }
  rescue IOError, SystemCallError
    nil # server closed
  end

  def handle(socket)
    request = read_request(socket)
    status, payload = next_failure || route(request)
    body = JSON.generate(payload)
    # Net::HTTP ignores the reason phrase.
    socket.write("HTTP/1.1 #{status} Mock\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    socket.close
  end

  def read_request(socket)
    verb, target = socket.gets("\r\n").split
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i)
    path, query = target.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h.merge(URI.decode_www_form(body.to_s).to_h)
    Request.new(verb:, path:, params:, headers:).tap { |request| @mutex.synchronize { @requests << request } }
  end

  def next_failure
    @mutex.synchronize do
      next unless @failures_left.positive?

      @failures_left -= 1
      @failure
    end
  end

  def route(request)
    case [request.verb, request.path]
    in ["GET", "/metadata/identity/oauth2/token"] then imds(request)
    in ["GET", "/msi/token"] then app_service(request)
    in ["POST", %r{\A/[^/]+/oauth2/v2\.0/token\z}] then entra_id(request)
    else [404, { error: "not_found" }]
    end
  end

  def imds(request)
    unless request.headers["metadata"] == "true"
      return [400, { error: "invalid_request", error_description: "Required metadata header not specified" }]
    end
    return bad_request("api-version") unless request.params["api-version"] == "2018-02-01"
    return bad_request("resource") unless request.params["resource"]

    issued = issue
    [200, { access_token: issued.token, expires_in: TOKEN_LIFETIME.to_s, expires_on: issued.expires_on.to_s,
            resource: request.params["resource"], token_type: "Bearer" }]
  end

  def app_service(request)
    unless request.headers["x-identity-header"] == IDENTITY_HEADER
      return [401, { statusCode: 401, message: "Unauthorized" }]
    end
    return bad_request("api-version") unless request.params["api-version"] == "2019-08-01"
    return bad_request("resource") unless request.params["resource"]

    issued = issue
    [200, { access_token: issued.token, expires_on: issued.expires_on.to_s, resource: request.params["resource"],
            token_type: "Bearer" }]
  end

  def entra_id(request)
    params = request.params
    return bad_request("grant_type") unless params["grant_type"] == "client_credentials"
    return bad_request("scope") unless params["scope"].to_s.end_with?("/.default")

    unless params["client_secret"] || (params["client_assertion_type"] == JWT_BEARER && params["client_assertion"])
      return [401, { error: "invalid_client", error_description: "AADSTS7000216: missing client credentials" }]
    end

    [200, { token_type: "Bearer", expires_in: TOKEN_LIFETIME, access_token: issue.token }]
  end

  def bad_request(parameter)
    [400, { error: "invalid_request", error_description: "Missing or invalid #{parameter}" }]
  end

  # Real access tokens are 1-2 KB; nothing here decodes them, so random characters do.
  def issue
    issued = Issued.new(token: SecureRandom.urlsafe_base64(1024), expires_on: Time.now.to_i + TOKEN_LIFETIME)
    @on_issue&.call(issued)
    @mutex.synchronize { @issued << issued }
    issued
  end
end
