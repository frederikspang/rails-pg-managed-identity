# frozen_string_literal: true

module RailsPg
  module ManagedIdentity
    # Hands out access tokens for one credential and scope. A token is reused until it is
    # ManagedIdentity.refresh_offset seconds from expiry, then replaced. If replacing it fails while it
    # is still valid, the old token keeps being used. Shared by every connection using the same
    # database configuration, so it is thread-safe and fetches at most one token at a time.
    class TokenProvider
      # While the cached token is usable, ask for a new one at most this often, whether the last
      # request succeeded or failed (azure-identity does the same).
      REFRESH_RETRY_DELAY = 30
      # Never hand out a token that's about to expire mid-handshake.
      MINIMUM_VALIDITY = 10

      attr_reader :credential, :scope

      def initialize(credential, scope:)
        @credential = credential
        @scope = scope
        @mutex = Mutex.new
        @access_token = nil
        @requested_at = nil
      end

      def token
        @mutex.synchronize do
          refresh if refresh_due?
          @access_token.token
        end
      end

      private

      def refresh_due?
        return true unless usable?
        return false if @access_token.expires_in > ManagedIdentity.refresh_offset

        Time.now.to_i - @requested_at >= REFRESH_RETRY_DELAY
      end

      def refresh
        @requested_at = Time.now.to_i
        @access_token = credential.get_token(scope)
        ManagedIdentity.logger&.info do
          "[#{self.class.name}] Acquired access token for #{scope}, #{@access_token.inspect}"
        end
      rescue StandardError => e
        # Whatever went wrong (a garbled response, a malformed endpoint URL, a failed `az` spawn),
        # it's a failed token request: fall back to the cached token, or fail the connection attempt.
        error = e.is_a?(Error) ? e : AuthenticationError.new("#{e.class}: #{e.message}")
        raise error unless usable?

        ManagedIdentity.logger&.warn do
          "[#{self.class.name}] Couldn't refresh access token, using the cached one " \
            "(#{@access_token.inspect}): #{error.message}"
        end
      end

      def usable?
        @access_token && @access_token.expires_in > MINIMUM_VALIDITY
      end
    end
  end
end
