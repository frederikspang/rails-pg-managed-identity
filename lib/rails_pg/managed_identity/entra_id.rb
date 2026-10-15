# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # OAuth 2.0 client credentials requests against Microsoft Entra ID's v2.0 token endpoint.
    module EntraID
      DEFAULT_AUTHORITY_HOST = "https://login.microsoftonline.com"

      # params authenticate the client: client_secret, or client_assertion and client_assertion_type.
      def self.client_credentials_token(tenant_id:, client_id:, scope:, **params)
        uri = URI("#{authority_host}/#{tenant_id}/oauth2/v2.0/token")
        form = { grant_type: "client_credentials", client_id:, scope:, **params }
        AccessToken.from_response(HTTP.post_form(uri, form), "Microsoft Entra ID")
      end

      # AZURE_AUTHORITY_HOST selects a sovereign cloud; the AKS workload identity webhook sets it too.
      def self.authority_host
        host = ENV["AZURE_AUTHORITY_HOST"].to_s.strip.presence || DEFAULT_AUTHORITY_HOST
        host = "https://#{host}" unless host.include?("://")
        host.chomp("/")
      end
    end
  end
end
