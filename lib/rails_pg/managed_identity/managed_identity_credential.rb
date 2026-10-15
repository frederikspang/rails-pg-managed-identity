# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # The managed identity of the Azure resource the app runs on: system-assigned by default, or
    # the user-assigned identity with the given client ID (default: AZURE_CLIENT_ID).
    #
    # App Service, Azure Functions and Container Apps expose a local token endpoint through
    # IDENTITY_ENDPOINT and IDENTITY_HEADER. Everywhere else (VMs, scale sets, AKS nodes) tokens
    # come from the Azure Instance Metadata Service (IMDS).
    class ManagedIdentityCredential
      IMDS_HOST = "http://169.254.169.254"
      IMDS_PATH = "/metadata/identity/oauth2/token"
      # Microsoft documents 404 and 410 as transient for managed identity endpoints, too.
      RETRY_STATUSES = (HTTP::RETRY_STATUSES + [404, 410]).freeze

      def initialize(client_id: nil)
        @client_id = client_id
      end

      def get_token(scope)
        resource = scope.delete_suffix("/.default")
        if ENV["IDENTITY_ENDPOINT"].blank? || ENV["IDENTITY_HEADER"].blank?
          imds_token(resource)
        else
          app_service_token(resource)
        end
      end

      private

      def client_id
        @client_id.presence || ENV.fetch("AZURE_CLIENT_ID", nil).presence
      end

      def token_uri(base, api_version, resource)
        uri = URI(base)
        uri.query = URI.encode_www_form({ "api-version" => api_version, "resource" => resource,
                                          "client_id" => client_id }.compact)
        uri
      end

      def app_service_token(resource)
        uri = token_uri(ENV.fetch("IDENTITY_ENDPOINT"), "2019-08-01", resource)
        response = HTTP.get(uri, headers: { "X-IDENTITY-HEADER" => ENV.fetch("IDENTITY_HEADER") },
                                 retry_statuses: RETRY_STATUSES, proxy: false)
        AccessToken.from_response(response, "Managed identity endpoint (IDENTITY_ENDPOINT)")
      end

      def imds_token(resource)
        uri = token_uri("#{imds_host}#{IMDS_PATH}", "2018-02-01", resource)
        # A short connect timeout: off Azure, IMDS is simply absent and the chain should move on.
        response = HTTP.get(uri, headers: { "Metadata" => "true" }, open_timeout: 1,
                                 retry_statuses: RETRY_STATUSES, proxy: false)
        if response.status == 400
          raise CredentialUnavailableError, "#{client_id ? "The requested identity has" : "No identity has"} " \
                                            "been assigned to this resource (IMDS: #{response.error_message})"
        end
        AccessToken.from_response(response, "Azure Instance Metadata Service")
      rescue HTTP::UnreachableError => e
        raise CredentialUnavailableError, "No managed identity endpoint found (IMDS at #{e.message})"
      end

      # Same override as azure-identity, which is handy for tests.
      def imds_host
        (ENV["AZURE_POD_IDENTITY_AUTHORITY_HOST"].presence || IMDS_HOST).chomp("/")
      end
    end
  end
end
