# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rails_pg/managed_identity"

require "minitest/autorun"
require "active_support/core_ext/enumerable"
require "active_support/testing/time_helpers"

require_relative "support/env_helper"
require_relative "support/mock_token_service"
require_relative "support/integration_environment"

RailsPg::ManagedIdentity::HTTP.retry_delay = 0.01
