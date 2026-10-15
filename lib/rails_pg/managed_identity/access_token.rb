# frozen_string_literal: true

require "time"

module RailsPg
  module ManagedIdentity
    # An access token and its expiry in seconds since the epoch.
    AccessToken = Data.define(:token, :expires_on) do
      # Builds a token from a JSON token response. Managed identity endpoints send expires_on,
      # Microsoft Entra ID sends expires_in.
      def self.from_response(response, source)
        unless response.status == 200
          raise AuthenticationError, "#{source} returned HTTP #{response.status}: #{response.error_message}"
        end

        token = response.json["access_token"]
        expires_on = Integer(response.json["expires_on"], exception: false)
        expires_in = Integer(response.json["expires_in"], exception: false)
        expires_on ||= Time.now.to_i + expires_in if expires_in
        raise AuthenticationError, "#{source} returned an incomplete token response" unless token && expires_on

        new(token:, expires_on:)
      end

      def expires_in
        expires_on - Time.now.to_i
      end

      # Never show the token itself in logs, consoles or exception messages.
      def inspect
        "#<#{self.class.name} expires_on=#{Time.at(expires_on).utc.iso8601}>"
      end
      alias_method :to_s, :inspect

      # pp and IRB use this rather than #inspect.
      def pretty_print(printer)
        printer.text(inspect)
      end
    end
  end
end
