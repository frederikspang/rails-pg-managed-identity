# frozen_string_literal: true

require "open3"

module RailsPg
  module ManagedIdentity
    # The account signed in to the Azure CLI (`az login`), for local development.
    class AzureCliCredential
      # `az` is usually a shell script running Python. In its own process group, a timeout can kill both.
      SPAWN_OPTIONS = Gem.win_platform? ? {}.freeze : { pgroup: true }.freeze

      def initialize(process_timeout: 10)
        @process_timeout = process_timeout
      end

      def get_token(scope)
        stdout, stderr, status = run("az", "account", "get-access-token", "--output", "json", "--scope", scope)
        unless status.success?
          raise CredentialUnavailableError, "Azure CLI isn't signed in; run `az login`" if stderr.include?("az login")

          raise AuthenticationError, "Azure CLI failed: #{stderr.strip.lines.first}"
        end

        parse(stdout)
      end

      private

      def run(*command)
        Open3.popen3(*command, **SPAWN_OPTIONS) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          out = reader(stdout)
          err = reader(stderr)
          unless wait_thread.join(@process_timeout)
            kill(wait_thread.pid)
            raise AuthenticationError, "Azure CLI didn't respond within #{@process_timeout} seconds"
          end
          [out.value, err.value, wait_thread.value]
        end
      rescue Errno::ENOENT
        raise CredentialUnavailableError, "Azure CLI (az) not found on PATH"
      end

      # On a timeout the pipes are closed under the reader; that's expected, not worth a report.
      def reader(io)
        Thread.new do
          Thread.current.report_on_exception = false
          io.read
        end
      end

      def kill(pid)
        Process.kill("KILL", SPAWN_OPTIONS[:pgroup] ? -pid : pid)
      rescue Errno::ESRCH
        nil # exited in the meantime
      end

      # Azure CLI 2.54+ sends expires_on (epoch seconds); older versions only expiresOn in local time.
      def parse(stdout)
        json = JSON.parse(stdout)
        expires_on = Integer(json["expires_on"], exception: false) || Time.parse(json.fetch("expiresOn")).to_i
        AccessToken.new(token: json.fetch("accessToken"), expires_on:)
      rescue JSON::ParserError, KeyError, ArgumentError => e
        raise AuthenticationError, "Unexpected output from Azure CLI: #{e.message}"
      end
    end
  end
end
