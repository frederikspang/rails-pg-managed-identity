# frozen_string_literal: true

require "test_helper"

module RailsPg
  module ManagedIdentity
    class TestTokenProvider < Minitest::Test
      include ActiveSupport::Testing::TimeHelpers

      class FakeCredential
        attr_accessor :error, :delay, :lifetime

        def initialize
          @calls = 0
          @lifetime = 3600
          @mutex = Mutex.new
        end

        def calls
          @mutex.synchronize { @calls }
        end

        def get_token(_scope)
          sleep(delay) if delay
          call = @mutex.synchronize { @calls += 1 }
          raise error if error

          AccessToken.new(token: "token-#{call}", expires_on: Time.now.to_i + lifetime)
        end
      end

      def setup
        @credential = FakeCredential.new
        @provider = TokenProvider.new(@credential, scope: DEFAULT_SCOPE)
        @log = StringIO.new
        ManagedIdentity.logger = Logger.new(@log)
      end

      def teardown
        ManagedIdentity.logger = nil
      end

      def test_reuses_the_token_until_the_refresh_window
        assert_equal "token-1", @provider.token
        travel 3600 - ManagedIdentity.refresh_offset - 1

        assert_equal "token-1", @provider.token
        assert_equal 1, @credential.calls
      end

      def test_replaces_the_token_shortly_before_it_expires
        assert_equal "token-1", @provider.token
        travel 3600 - ManagedIdentity.refresh_offset + 1

        assert_equal "token-2", @provider.token
      end

      def test_keeps_using_a_valid_token_when_refreshing_fails
        @provider.token
        travel 3600 - 60
        @credential.error = AuthenticationError.new("token service down")

        assert_equal "token-1", @provider.token
        assert_match(/Couldn't refresh access token.*token service down/, @log.string)
        refute_includes @log.string, "token-1"

        # Doesn't ask again on every connect while the token service is down...
        assert_equal "token-1", @provider.token
        assert_equal 2, @credential.calls

        # ...but does after a while, and picks up a new token once it's back.
        travel TokenProvider::REFRESH_RETRY_DELAY
        @credential.error = nil
        assert_equal "token-3", @provider.token
      end

      def test_raises_when_refreshing_fails_and_the_token_has_expired
        @provider.token
        travel 3600
        @credential.error = AuthenticationError.new("token service down")

        assert_raises(AuthenticationError) { @provider.token }
      end

      def test_raises_on_the_first_fetch_failure
        @credential.error = AuthenticationError.new("token service down")

        error = assert_raises(AuthenticationError) { @provider.token }
        assert_kind_of ActiveRecord::ConnectionNotEstablished, error
      end

      def test_unexpected_errors_count_as_failed_requests
        @credential.error = Net::HTTPBadResponse.new("wrong status line")

        error = assert_raises(AuthenticationError) { @provider.token }
        assert_match(/Net::HTTPBadResponse: wrong status line/, error.message)
        assert_instance_of Net::HTTPBadResponse, error.cause

        @credential.error = nil
        @provider.token
        travel 3600 - 60
        @credential.error = Net::HTTPBadResponse.new("wrong status line")
        assert_equal "token-2", @provider.token # the cached one
      end

      def test_asks_at_most_every_retry_delay_when_tokens_arrive_inside_the_refresh_window
        @credential.lifetime = ManagedIdentity.refresh_offset - 100 # e.g. an endpoint handing out its cached token

        assert_equal "token-1", @provider.token
        assert_equal "token-1", @provider.token
        travel TokenProvider::REFRESH_RETRY_DELAY
        assert_equal "token-2", @provider.token
      end

      def test_never_hands_out_a_token_about_to_expire
        ManagedIdentity.refresh_offset = 0
        @provider.token
        travel 3600 - TokenProvider::MINIMUM_VALIDITY

        assert_equal "token-2", @provider.token
      ensure
        ManagedIdentity.refresh_offset = 300
      end

      def test_concurrent_callers_share_one_fetch
        @credential.delay = 0.05
        tokens = Array.new(10) { Thread.new { @provider.token } }.map(&:value)

        assert_equal ["token-1"], tokens.uniq
        assert_equal 1, @credential.calls
      end
    end
  end
end
