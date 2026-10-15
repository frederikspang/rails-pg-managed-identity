# frozen_string_literal: true

# Runs a block with a controlled environment: every variable the credentials read is cleared
# unless given, and everything is restored afterwards.
module EnvHelper
  CREDENTIAL_VARIABLES = %w[
    AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_FEDERATED_TOKEN_FILE AZURE_AUTHORITY_HOST
    AZURE_POD_IDENTITY_AUTHORITY_HOST IDENTITY_ENDPOINT IDENTITY_HEADER
  ].freeze

  def with_env(variables = {})
    names = CREDENTIAL_VARIABLES | variables.keys
    saved = names.to_h { |name| [name, ENV.fetch(name, nil)] }
    names.each { |name| ENV.delete(name) }
    variables.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
