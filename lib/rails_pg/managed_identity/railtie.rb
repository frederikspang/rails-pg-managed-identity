# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Hooks into the database tasks only when rake tasks are loaded, so app and job processes never
    # load the task code. Rails runs schema maintenance through rake too (bin/rails db:test:prepare).
    class Railtie < ::Rails::Railtie
      rake_tasks do
        require_relative "postgresql_database_tasks"
        ActiveRecord::Tasks::DatabaseTasks.register_task(/postgresql/, PostgreSQLDatabaseTasks)
      end
    end
  end
end
