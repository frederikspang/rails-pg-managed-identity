# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Runs psql and pg_dump (db:schema:load and db:schema:dump with structure.sql) with the access
    # token as PGPASSWORD. Registered for PostgreSQL databases by the Railtie.
    class PostgreSQLDatabaseTasks < ActiveRecord::Tasks::PostgreSQLDatabaseTasks
      private

      def psql_env
        env = super
        if (provider = ManagedIdentity.token_provider_for(configuration_hash))
          env["PGPASSWORD"] = provider.token
        end
        env
      end
    end
  end
end
