# frozen_string_literal: true

require "test_helper"
require "active_record/database_configurations"
require "active_support/hash_with_indifferent_access"

module RailsPg
  module ManagedIdentity
    class TestManagedIdentity < Minitest::Test
      def setup
        ManagedIdentity.reset!
      end

      def test_that_it_has_a_version_number
        refute_nil VERSION
      end

      def test_disabled_unless_configured
        assert_nil ManagedIdentity.token_provider_for({ adapter: "postgresql" })
        assert_nil ManagedIdentity.token_provider_for({ azure_managed_identity: false })
        # DATABASE_URL query parameters are strings
        assert_nil ManagedIdentity.token_provider_for({ azure_managed_identity: "false" })
      end

      def test_true_uses_default_azure_credential_for_azure_database_for_postgresql
        provider = ManagedIdentity.token_provider_for({ azure_managed_identity: true })

        assert_instance_of DefaultAzureCredential, provider.credential
        assert_equal "https://ossrdbms-aad.database.windows.net/.default", provider.scope
      end

      def test_enabled_from_database_url
        url = "postgres://my-app-identity@my-server.postgres.database.azure.com/my_app" \
              "?sslmode=require&azure_managed_identity=true"
        config = ActiveRecord::DatabaseConfigurations::UrlConfig.new("production", "primary", url, {})

        provider = ManagedIdentity.token_provider_for(config.configuration_hash)

        assert_instance_of DefaultAzureCredential, provider.credential
      end

      def test_options_from_database_yml
        provider = ManagedIdentity.token_provider_for(
          { azure_managed_identity: { "credential" => "managed_identity", "client_id" => "uami-client-id",
                                      "scope" => "https://ossrdbms-aad.database.usgovcloudapi.net/.default" } }
        )

        assert_instance_of ManagedIdentityCredential, provider.credential
        assert_equal "uami-client-id", provider.credential.send(:client_id)
        assert_equal "https://ossrdbms-aad.database.usgovcloudapi.net/.default", provider.scope
      end

      def test_options_in_a_hash_with_indifferent_access
        options = ActiveSupport::HashWithIndifferentAccess.new(credential: "managed_identity", client_id: "abc")
        provider = ManagedIdentity.token_provider_for({ azure_managed_identity: options })

        assert_equal "abc", provider.credential.send(:client_id)
      end

      def test_blank_options_count_as_not_given
        given = ManagedIdentity.token_provider_for({ azure_managed_identity: { credential: "managed_identity" } })
        blank = ManagedIdentity.token_provider_for(
          { azure_managed_identity: { credential: "managed_identity", client_id: "", scope: nil } }
        )

        assert_same given, blank
      end

      def test_configurations_with_the_same_options_share_a_provider
        primary = ManagedIdentity.token_provider_for({ database: "app", azure_managed_identity: true })
        replica = ManagedIdentity.token_provider_for({ database: "app", host: "replica", azure_managed_identity: true })
        other = ManagedIdentity.token_provider_for({ azure_managed_identity: { client_id: "other" } })

        assert_same primary, replica
        refute_same primary, other
      end

      def test_rejects_unknown_options_and_credentials
        error = assert_raises(ArgumentError) do
          ManagedIdentity.token_provider_for({ azure_managed_identity: { clientid: "x" } })
        end
        assert_match(/clientid/, error.message)

        assert_raises(ArgumentError) do
          ManagedIdentity.token_provider_for({ azure_managed_identity: { credential: "vscode" } })
        end
        assert_raises(ArgumentError) { ManagedIdentity.token_provider_for({ azure_managed_identity: "yes please" }) }
      end
    end
  end
end
