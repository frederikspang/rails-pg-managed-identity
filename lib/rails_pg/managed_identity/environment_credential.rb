# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # A service principal with a client secret, configured through AZURE_TENANT_ID,
    # AZURE_CLIENT_ID and AZURE_CLIENT_SECRET.
    class EnvironmentCredential
      def get_token(scope)
        tenant_id, client_id, client_secret = ENV.values_at("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET")
        if [tenant_id, client_id, client_secret].any?(&:blank?)
          raise CredentialUnavailableError,
                "EnvironmentCredential requires AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_CLIENT_SECRET"
        end

        EntraID.client_credentials_token(tenant_id:, client_id:, scope:, client_secret:)
      end
    end
  end
end
