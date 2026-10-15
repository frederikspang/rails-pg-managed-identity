# frozen_string_literal: true

require "test_helper"

module RailsPg
  module ManagedIdentity
    # Boots test/dummy, whose database.yml has `azure_managed_identity: true` and no password, against
    # a PostgreSQL cluster that only accepts the token most recently issued by the mock token service.
    class TestRailsIntegration < Minitest::Test
      include ActiveSupport::Testing::TimeHelpers
      include EnvHelper

      def setup
        skip "PostgreSQL server binaries not found (initdb, pg_ctl); set PG_BINDIR" unless PostgresCluster.available?

        IntegrationEnvironment.setup!
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ManagedIdentity.reset!
        token_service.reset!
        IntegrationEnvironment.cluster.exec("TRUNCATE widgets", dbname: IntegrationEnvironment::DATABASE)
      end

      def teardown
        ActiveRecord::Base.connection_handler.clear_all_connections!
      end

      def test_booting_the_app_does_not_fetch_a_token_or_load_database_tasks
        assert_equal 0, IntegrationEnvironment.token_requests_during_boot
        assert_nil ActiveRecord::Base.connection_db_config.configuration_hash[:password]
        assert_empty IntegrationEnvironment.tasks_loaded_during_boot
      end

      def test_connects_with_a_token_from_the_managed_identity_endpoint
        Widget.create!(name: "sprocket")

        assert_equal ["sprocket"], Widget.pluck(:name)
        assert_equal(IntegrationEnvironment::ROLE, pool.with_connection { |c| c.select_value("SELECT current_user") })
        request = token_service.requests.sole
        assert_equal "/msi/token", request.path
        assert_equal MockTokenService::IDENTITY_HEADER, request.headers["x-identity-header"]
        assert_equal "https://ossrdbms-aad.database.windows.net", request.params["resource"]
      end

      def test_connections_share_the_cached_token
        connections = Array.new(4) { pool.checkout }
        backend_pids = connections.map { |connection| connection.select_value("SELECT pg_backend_pid()") }

        assert_equal 4, backend_pids.uniq.size
        assert_equal 1, token_service.issued.size
      ensure
        connections&.each { |connection| pool.checkin(connection) }
      end

      def test_new_connections_use_a_fresh_token_once_the_old_one_expires
        old_connection = pool.checkout
        old_pid = old_connection.select_value("SELECT pg_backend_pid()")
        first_token = token_service.issued.sole.token

        travel 1.hour
        new_connection = pool.checkout

        assert_equal 1, new_connection.select_value("SELECT 1")
        assert_equal 2, token_service.issued.size
        assert_raises(PG::ConnectionBad, "the database must no longer accept the first token") do
          IntegrationEnvironment.cluster.connect(user: IntegrationEnvironment::ROLE, password: first_token,
                                                 dbname: IntegrationEnvironment::DATABASE)
        end
        # Sessions are only authenticated once; an established connection outlives its token.
        assert_equal old_pid, old_connection.select_value("SELECT pg_backend_pid()")
      ensure
        [old_connection, new_connection].compact.each { |connection| pool.checkin(connection) }
      end

      def test_reconnect_opens_a_new_connection_with_the_current_token
        connection = pool.checkout
        old_pid = connection.select_value("SELECT pg_backend_pid()")
        connection.raw_connection.define_singleton_method(:reset) do
          raise "PG::Connection#reset would authenticate with the expired token"
        end

        travel 1.hour
        connection.reconnect!

        refute_equal old_pid, connection.select_value("SELECT pg_backend_pid()")
        assert_equal 2, token_service.issued.size
      ensure
        pool.checkin(connection) if connection
      end

      def test_overrides_a_static_password
        config = db_config.configuration_hash.merge(password: "static-password")

        assert_raises(ActiveRecord::ConnectionNotEstablished) do
          ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(config.merge(azure_managed_identity: false)).connect!
        end
        connection = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(config).connect!
        assert_equal 1, connection.select_value("SELECT 1")
      ensure
        connection&.disconnect!
      end

      def test_reports_token_failures_as_connection_errors
        token_service.fail_next(503, times: Float::INFINITY) # the token service is down

        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { Widget.count }
        assert_kind_of AuthenticationError, error
        assert_match(/HTTP 503/, error.message)
        assert_same pool, error.connection_pool
      end

      def test_structure_dump_passes_the_token_to_pg_dump
        load_rake_tasks
        ActiveRecord::Tasks::DatabaseTasks.structure_dump_flags = ["--no-password"] # fail instead of prompting
        Dir.mktmpdir do |dir|
          ActiveRecord::Tasks::DatabaseTasks.structure_dump(db_config, File.join(dir, "structure.sql"))

          assert_match(/CREATE TABLE public\.widgets/, File.read(File.join(dir, "structure.sql")))
        end
        assert_equal 1, token_service.issued.size
      ensure
        ActiveRecord::Tasks::DatabaseTasks.structure_dump_flags = nil
      end

      def test_dbconsole_gets_the_token
        adapter = Class.new(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) do
          def self.find_cmd_and_exec(*) = ENV.fetch("PGPASSWORD")
        end
        env = %w[PGUSER PGHOST PGPORT PGPASSWORD PGSSLMODE].to_h { |name| [name, nil] }
                                                           .merge(ENV.slice("IDENTITY_ENDPOINT", "IDENTITY_HEADER"))

        password = with_env(env) { adapter.dbconsole(db_config) }

        assert_equal token_service.issued.sole.token, password
      end

      private

      def token_service
        IntegrationEnvironment.token_service
      end

      def pool
        ActiveRecord::Base.connection_pool
      end

      def db_config
        ActiveRecord::Base.connection_db_config
      end

      def load_rake_tasks
        @@rake_tasks_loaded ||= Rails.application.load_tasks # rubocop:disable Style/ClassVars
      end
    end
  end
end
