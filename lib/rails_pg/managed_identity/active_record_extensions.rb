# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Prepended to ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.
    module PostgreSQLAdapterExtension
      private

      # Every physical connection, first or re-established, is opened here, so this is where
      # the password is resolved.
      def connect
        if (provider = ManagedIdentity.token_provider_for(@config))
          @connection_parameters = @connection_parameters.merge(password: provider.token)
        end
        super
      rescue Error => e
        raise e.set_pool(@pool)
      end

      # The stock implementation tries PG::Connection#reset first, which re-authenticates with the
      # password the connection was first opened with, possibly an expired token by now. Without a
      # raw connection it goes straight to #connect.
      def reconnect
        if ManagedIdentity.token_provider_for(@config)
          begin
            @raw_connection&.close
          rescue ::PG::Error
            nil
          end
          @raw_connection = nil
        end
        super
      end
    end

    # Extends PostgreSQLAdapter's class methods.
    module PostgreSQLAdapterClassExtension
      # `bin/rails dbconsole`: psql can't prompt for a password as long as an access token, so it
      # always gets the token through PGPASSWORD.
      def dbconsole(config, options = {})
        if (provider = ManagedIdentity.token_provider_for(config.configuration_hash))
          ENV["PGPASSWORD"] = provider.token
        end
        super
      end
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend RailsPg::ManagedIdentity::PostgreSQLAdapterExtension
  singleton_class.prepend RailsPg::ManagedIdentity::PostgreSQLAdapterClassExtension
end
