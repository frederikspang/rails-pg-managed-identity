# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module RailsPg
  module ManagedIdentity
    # Minimal JSON-over-HTTP client for the token endpoints, with retries for transient failures.
    module HTTP
      NETWORK_ERRORS = [SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError].freeze
      # The endpoint couldn't be reached at all.
      class UnreachableError < AuthenticationError; end
      RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
      MAX_RETRIES = 2

      Response = Data.define(:status, :json, :body) do
        def error_message
          json["error_description"] || json["message"] || json["error"] || body.to_s[0, 200]
        end
      end

      @retry_delay = 0.5

      class << self
        # Base delay in seconds before retrying; doubled for every further attempt.
        attr_accessor :retry_delay

        # Pass proxy: false for managed identity endpoints: they're local to the host, and Microsoft
        # doesn't support reaching IMDS through a proxy.
        def get(uri, headers: {}, open_timeout: 5, retry_statuses: RETRY_STATUSES, proxy: true)
          request(Net::HTTP::Get.new(uri, headers), open_timeout:, retry_statuses:, proxy:)
        end

        def post_form(uri, form)
          post = Net::HTTP::Post.new(uri)
          post.set_form_data(form)
          request(post, open_timeout: 5, retry_statuses: RETRY_STATUSES, proxy: true)
        end

        private

        def request(request, open_timeout:, retry_statuses:, proxy:)
          attempt = 0
          loop do
            response = send_request(request, open_timeout:, proxy:)
            status = response.code.to_i
            if retry_statuses.include?(status) && attempt < MAX_RETRIES
              sleep(retry_delay * (2**attempt))
              attempt += 1
              next
            end
            return Response.new(status:, json: parse(response.body), body: response.body)
          end
        end

        def send_request(request, open_timeout:, proxy:)
          uri = request.uri
          options = { use_ssl: uri.scheme == "https", open_timeout:, read_timeout: 10 }
          Net::HTTP.start(uri.host, uri.port, (proxy ? :ENV : nil), options) { |http| http.request(request) }
        rescue *NETWORK_ERRORS => e
          raise UnreachableError, "#{uri.host}:#{uri.port} unreachable (#{e.class}: #{e.message})"
        end

        def parse(body)
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
