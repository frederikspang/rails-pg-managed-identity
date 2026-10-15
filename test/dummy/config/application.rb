# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "rails-pg-managed-identity"

module Dummy
  # The smallest Rails app that exercises database.yml with azure_managed_identity.
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy"
    config.logger = ActiveSupport::Logger.new(ENV.fetch("DUMMY_LOG", File::NULL))
    config.active_record.schema_format = :sql
  end
end
