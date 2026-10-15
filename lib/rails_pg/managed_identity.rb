# frozen_string_literal: true

require "active_record"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"

require_relative "managed_identity/version"

module RailsPg
  # Microsoft Entra authentication (managed identity, workload identity, ...) for Azure
  # Database for PostgreSQL flexible server. Enable it per database in config/database.yml:
  #
  #   production:
  #     adapter: postgresql
  #     host: my-server.postgres.database.azure.com
  #     database: my_app
  #     username: my-app-identity   # the Entra principal's PostgreSQL role
  #     sslmode: require
  #     azure_managed_identity: true
  #
  # The password is then an access token resolved each time a connection is opened, rather than
  # a value fixed when database.yml is loaded. Tokens are cached and replaced shortly before they
  # expire.
  module ManagedIdentity
    # Raised when no access token can be obtained. A ConnectionNotEstablished, so Active Record
    # handles it like any other failed connection attempt.
    class Error < ActiveRecord::ConnectionNotEstablished; end

    # The credential doesn't apply to this environment (e.g. no managed identity endpoint), so
    # DefaultAzureCredential moves on to the next one.
    class CredentialUnavailableError < Error; end

    # The credential applies to this environment, but the token request failed.
    class AuthenticationError < Error; end

    CONFIG_KEY = :azure_managed_identity
    # Azure Database for PostgreSQL's Microsoft Entra resource (public cloud).
    DEFAULT_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
    OPTIONS = %i[client_id credential scope].freeze

    @providers = {}
    @providers_mutex = Mutex.new
    @refresh_offset = 300

    class << self
      attr_writer :logger

      # Seconds before expiry at which a cached token is replaced. azure-identity uses 5 minutes.
      attr_accessor :refresh_offset

      def logger
        @logger || ActiveRecord::Base.logger
      end

      # Returns the TokenProvider for a database configuration hash, or nil when the
      # configuration doesn't enable Microsoft Entra authentication. Configurations with the same
      # options share a provider, and therefore a cached token.
      def token_provider_for(config)
        options = parse_options(config[CONFIG_KEY])
        return unless options

        @providers_mutex.synchronize do
          @providers[options] ||= TokenProvider.new(
            build_credential(options.fetch(:credential, "default"), client_id: options[:client_id]),
            scope: options.fetch(:scope, DEFAULT_SCOPE)
          )
        end
      end

      # Forgets all cached tokens.
      def reset!
        @providers_mutex.synchronize { @providers.clear }
      end

      private

      def parse_options(value)
        case value
        when nil, false, "false", "" then nil
        when true, "true" then {}
        when Hash
          options = value.to_h.transform_keys(&:to_sym).compact_blank
          unknown = options.keys - OPTIONS
          raise ArgumentError, "Unknown #{CONFIG_KEY} option(s): #{unknown.join(", ")}" if unknown.any?

          options
        else
          raise ArgumentError, "#{CONFIG_KEY} must be true, false or a hash of options, got #{value.inspect}"
        end
      end

      def build_credential(name, client_id:)
        case name.to_s
        when "default" then DefaultAzureCredential.new(client_id:)
        when "managed_identity" then ManagedIdentityCredential.new(client_id:)
        when "workload_identity" then WorkloadIdentityCredential.new(client_id:)
        when "environment" then EnvironmentCredential.new
        when "azure_cli" then AzureCliCredential.new
        else
          raise ArgumentError, "Unknown #{CONFIG_KEY} credential #{name.inspect}; expected one of " \
                               "default, managed_identity, workload_identity, environment, azure_cli"
        end
      end
    end
  end
end

require_relative "managed_identity/access_token"
require_relative "managed_identity/http"
require_relative "managed_identity/entra_id"
require_relative "managed_identity/environment_credential"
require_relative "managed_identity/workload_identity_credential"
require_relative "managed_identity/managed_identity_credential"
require_relative "managed_identity/azure_cli_credential"
require_relative "managed_identity/default_azure_credential"
require_relative "managed_identity/token_provider"
require_relative "managed_identity/active_record_extensions"

# Runs when the Rails application class is defined, whether this gem was loaded before or after Rails.
ActiveSupport.on_load(:before_configuration) { require_relative "managed_identity/railtie" }
