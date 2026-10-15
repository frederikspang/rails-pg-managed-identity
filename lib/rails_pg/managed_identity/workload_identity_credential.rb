# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Microsoft Entra Workload ID on Kubernetes (AKS). The workload identity webhook injects
    # AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE; the projected service account
    # token in that file is exchanged for an access token.
    class WorkloadIdentityCredential
      JWT_BEARER = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

      def initialize(client_id: nil)
        @client_id = client_id
      end

      def get_token(scope)
        tenant_id, token_file = ENV.values_at("AZURE_TENANT_ID", "AZURE_FEDERATED_TOKEN_FILE")
        client_id = @client_id.presence || ENV.fetch("AZURE_CLIENT_ID", nil)
        if [tenant_id, client_id, token_file].any?(&:blank?)
          raise CredentialUnavailableError, "WorkloadIdentityCredential requires AZURE_TENANT_ID, " \
                                            "AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE"
        end

        EntraID.client_credentials_token(tenant_id:, client_id:, scope:,
                                         client_assertion_type: JWT_BEARER,
                                         client_assertion: read_assertion(token_file))
      end

      private

      # Kubernetes rotates the projected token in place, so it's read again for every exchange.
      def read_assertion(token_file)
        File.read(token_file).strip
      rescue SystemCallError => e
        raise AuthenticationError, "Can't read the federated token file #{token_file}: #{e.message}"
      end
    end
  end
end
