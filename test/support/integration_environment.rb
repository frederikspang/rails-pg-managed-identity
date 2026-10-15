# frozen_string_literal: true

require_relative "mock_token_service"
require_relative "postgres_cluster"

# Wires the dummy Rails app (test/dummy) to a throwaway PostgreSQL cluster and the mock token
# service, the way Azure wires an App Service app to a flexible server: the app's managed identity
# endpoint issues tokens, and the database accepts the current one as the role's password.
module IntegrationEnvironment
  ROLE = "dummy-app-identity" # PostgreSQL role of the managed identity, as pgaadauth_create_principal makes it
  DATABASE = "dummy_test"

  class << self
    attr_reader :cluster, :token_service, :token_requests_during_boot, :tasks_loaded_during_boot

    def setup!
      return if @cluster

      @cluster = PostgresCluster.new.start
      @token_service = MockTokenService.new { |issued| cluster.accept_token(ROLE, issued.token, issued.expires_on) }
      Minitest.after_run { teardown! }
      create_database

      # What App Service puts in the environment of an app with a managed identity.
      ENV["IDENTITY_ENDPOINT"] = token_service.url("/msi/token")
      ENV["IDENTITY_HEADER"] = MockTokenService::IDENTITY_HEADER
      ENV["DUMMY_DATABASE_PORT"] = cluster.port.to_s
      ENV["RAILS_ENV"] = "test"
      # pg_dump for db:schema:dump with structure.sql, matching the server's version.
      ENV["PATH"] = "#{PostgresCluster.bindir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"

      require_relative "../dummy/config/environment"
      @token_requests_during_boot = token_service.requests.size
      @tasks_loaded_during_boot = $LOADED_FEATURES.grep(/database_tasks/)
    end

    def teardown!
      token_service.stop
      cluster.stop
    end

    private

    def create_database
      cluster.exec("CREATE ROLE #{PG::Connection.quote_ident(ROLE)} LOGIN")
      cluster.exec("CREATE DATABASE #{DATABASE} OWNER #{PG::Connection.quote_ident(ROLE)}")
      cluster.exec(<<~SQL, dbname: DATABASE)
        CREATE TABLE widgets (id bigserial PRIMARY KEY, name text NOT NULL);
        ALTER TABLE widgets OWNER TO #{PG::Connection.quote_ident(ROLE)};
      SQL
    end
  end
end
