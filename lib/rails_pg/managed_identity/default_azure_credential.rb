# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Tries credentials in the same order as azure-identity's DefaultAzureCredential (minus the
    # ones that need a desktop or an IDE): environment, workload identity, managed identity,
    # Azure CLI. The first credential that returns a token is used from then on.
    class DefaultAzureCredential
      def initialize(client_id: nil)
        @credentials = [
          EnvironmentCredential.new,
          WorkloadIdentityCredential.new(client_id:),
          ManagedIdentityCredential.new(client_id:),
          AzureCliCredential.new
        ]
        @selected = nil
      end

      def get_token(scope)
        return @selected.get_token(scope) if @selected

        attempts = []
        @credentials.each do |credential|
          token = credential.get_token(scope)
          @selected = credential
          ManagedIdentity.logger&.info { "[#{self.class.name}] Using #{credential.class.name.demodulize}" }
          return token
        rescue Error => e
          attempts << "#{credential.class.name.demodulize}: #{e.message}"
          # Unavailable means not applicable here, so try the next one; any other failure stops the
          # chain, like azure-identity does.
          raise AuthenticationError, failure_message(attempts) unless e.is_a?(CredentialUnavailableError)
        end
        raise CredentialUnavailableError, failure_message(attempts)
      end

      private

      def failure_message(attempts)
        "DefaultAzureCredential failed to get an access token:\n  #{attempts.join("\n  ")}"
      end
    end
  end
end
