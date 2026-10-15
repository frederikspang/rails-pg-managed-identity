# frozen_string_literal: true

require "test_helper"
require "pp"

module RailsPg
  module ManagedIdentity
    class TestCredentials < Minitest::Test
      include EnvHelper

      RESOURCE = "https://ossrdbms-aad.database.windows.net"

      def setup
        @service = MockTokenService.new
        @tmpdir = Dir.mktmpdir
      end

      def teardown
        @service.stop
        FileUtils.rm_rf(@tmpdir)
      end

      # Managed identity: App Service, Functions, Container Apps

      def test_managed_identity_on_app_service
        token = with_env(app_service_env) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }

        request = @service.requests.sole
        assert_equal "/msi/token", request.path
        assert_equal MockTokenService::IDENTITY_HEADER, request.headers["x-identity-header"]
        assert_equal({ "api-version" => "2019-08-01", "resource" => RESOURCE }, request.params)
        assert_equal @service.issued.sole.token, token.token
        assert_equal @service.issued.sole.expires_on, token.expires_on
      end

      def test_user_assigned_managed_identity_by_client_id
        with_env(app_service_env) do
          ManagedIdentityCredential.new(client_id: "uami-client-id").get_token(DEFAULT_SCOPE)
        end
        with_env(app_service_env("AZURE_CLIENT_ID" => "env-client-id")) do
          ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE)
        end

        assert_equal(%w[uami-client-id env-client-id], @service.requests.map { |request| request.params["client_id"] })
      end

      def test_managed_identity_endpoint_rejecting_the_request
        error = with_env(app_service_env("IDENTITY_HEADER" => "wrong")) do
          assert_raises(AuthenticationError) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }
        end
        assert_match(/HTTP 401/, error.message)
      end

      # Managed identity: Azure Instance Metadata Service (VMs, scale sets, AKS nodes)

      def test_managed_identity_from_imds
        token = with_env(imds_env) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }

        request = @service.requests.sole
        assert_equal "/metadata/identity/oauth2/token", request.path
        assert_equal "true", request.headers["metadata"]
        assert_equal({ "api-version" => "2018-02-01", "resource" => RESOURCE }, request.params)
        assert_equal @service.issued.sole.token, token.token
      end

      def test_imds_retries_transient_errors
        @service.fail_next(500, times: 2)
        token = with_env(imds_env) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }

        assert_equal 3, @service.requests.size
        assert_equal @service.issued.sole.token, token.token
      end

      def test_imds_gives_up_after_retries
        @service.fail_next(503, times: 3)

        with_env(imds_env) do
          assert_raises(AuthenticationError) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }
        end
      end

      def test_imds_without_an_assigned_identity_is_unavailable
        @service.fail_next(400, error: "invalid_request", description: "Identity not found")

        error = with_env(imds_env) do
          assert_raises(CredentialUnavailableError) do
            ManagedIdentityCredential.new(client_id: "nope").get_token(DEFAULT_SCOPE)
          end
        end
        assert_match(/requested identity has been assigned.*Identity not found/, error.message)
      end

      def test_unreachable_imds_is_unavailable
        with_env("AZURE_POD_IDENTITY_AUTHORITY_HOST" => "http://127.0.0.1:#{closed_port}") do
          assert_raises(CredentialUnavailableError) { ManagedIdentityCredential.new.get_token(DEFAULT_SCOPE) }
        end
      end

      # Workload identity (AKS) and service principal

      def test_workload_identity_exchanges_the_federated_token
        token_file = federated_token_file("kubernetes-token-1\n")

        with_env(workload_identity_env(token_file)) do
          credential = WorkloadIdentityCredential.new
          credential.get_token(DEFAULT_SCOPE)
          File.write(token_file, "kubernetes-token-2\n") # rotated by the kubelet
          credential.get_token(DEFAULT_SCOPE)
        end

        first, second = @service.requests
        assert_equal "POST", first.verb
        assert_equal "/my-tenant/oauth2/v2.0/token", first.path
        assert_equal({ "grant_type" => "client_credentials", "client_id" => "wi-client-id", "scope" => DEFAULT_SCOPE,
                       "client_assertion_type" => WorkloadIdentityCredential::JWT_BEARER,
                       "client_assertion" => "kubernetes-token-1" }, first.params)
        assert_equal "kubernetes-token-2", second.params["client_assertion"]
      end

      def test_blank_client_id_falls_back_to_azure_client_id
        token_file = federated_token_file("kubernetes-token")
        with_env(workload_identity_env(token_file)) do
          WorkloadIdentityCredential.new(client_id: "").get_token(DEFAULT_SCOPE)
        end

        assert_equal "wi-client-id", @service.requests.sole.params["client_id"]
      end

      def test_workload_identity_needs_its_environment
        error = with_env do
          assert_raises(CredentialUnavailableError) do
            WorkloadIdentityCredential.new.get_token(DEFAULT_SCOPE)
          end
        end
        assert_match(/AZURE_FEDERATED_TOKEN_FILE/, error.message)
      end

      def test_service_principal_from_environment
        with_env(entra_env("AZURE_CLIENT_ID" => "sp-client-id", "AZURE_CLIENT_SECRET" => "sp-secret")) do
          EnvironmentCredential.new.get_token(DEFAULT_SCOPE)
        end

        assert_equal "sp-secret", @service.requests.sole.params["client_secret"]
      end

      def test_entra_id_errors_are_reported
        @service.fail_next(401, error: "invalid_client", description: "AADSTS700016: Application not found")

        error = with_env(entra_env("AZURE_CLIENT_ID" => "sp", "AZURE_CLIENT_SECRET" => "secret")) do
          assert_raises(AuthenticationError) { EnvironmentCredential.new.get_token(DEFAULT_SCOPE) }
        end
        assert_match(/HTTP 401: AADSTS700016/, error.message)
      end

      # Azure CLI (local development)

      def test_azure_cli
        fake_az(<<~SH)
          printf '%s ' "$@" > "${0%/*}/args"
          printf '{"accessToken": "cli-token", "expiresOn": "2030-01-01 00:00:00.000000", "expires_on": 1893456000}'
        SH
        token = with_env("PATH" => @tmpdir) { AzureCliCredential.new.get_token(DEFAULT_SCOPE) }

        assert_equal "account get-access-token --output json --scope #{DEFAULT_SCOPE} ",
                     File.read(File.join(@tmpdir, "args"))
        assert_equal "cli-token", token.token
        assert_equal 1_893_456_000, token.expires_on
      end

      def test_azure_cli_not_signed_in_is_unavailable
        fake_az("echo \"ERROR: Please run 'az login' to setup account.\" >&2; exit 1")

        with_env("PATH" => @tmpdir) do
          assert_raises(CredentialUnavailableError) do
            AzureCliCredential.new.get_token(DEFAULT_SCOPE)
          end
        end
      end

      def test_azure_cli_timeout_kills_the_whole_process_group
        fake_az(<<~SH)
          /bin/sleep 30 &
          echo $! > "${0%/*}/sleep.pid"
          wait
        SH

        _, stderr = capture_io do
          with_env("PATH" => @tmpdir) do
            assert_raises(AuthenticationError) { AzureCliCredential.new(process_timeout: 0.5).get_token(DEFAULT_SCOPE) }
          end
        end

        sleep_pid = Integer(File.read(File.join(@tmpdir, "sleep.pid")))
        assert(50.times.any? { !process_alive?(sleep_pid) || sleep(0.05).nil? }, "az's child process survived")
        refute_match(/terminated with exception/, stderr)
      end

      def test_azure_cli_not_installed_is_unavailable
        with_env("PATH" => @tmpdir) do
          assert_raises(CredentialUnavailableError) do
            AzureCliCredential.new.get_token(DEFAULT_SCOPE)
          end
        end
      end

      # DefaultAzureCredential

      def test_default_credential_prefers_workload_identity
        token_file = federated_token_file("kubernetes-token")

        with_env(workload_identity_env(token_file).merge(app_service_env)) do
          DefaultAzureCredential.new.get_token(DEFAULT_SCOPE)
        end

        assert_equal "/my-tenant/oauth2/v2.0/token", @service.requests.sole.path
      end

      def test_default_credential_falls_back_to_managed_identity_and_sticks_with_it
        credential = DefaultAzureCredential.new
        with_env(app_service_env("PATH" => @tmpdir)) do
          2.times { credential.get_token(DEFAULT_SCOPE) }
        end

        assert_equal ["/msi/token"] * 2, @service.requests.map(&:path)
        assert_instance_of ManagedIdentityCredential, credential.instance_variable_get(:@selected)
      end

      def test_default_credential_reports_every_attempt_when_nothing_is_available
        env = { "AZURE_POD_IDENTITY_AUTHORITY_HOST" => "http://127.0.0.1:#{closed_port}", "PATH" => @tmpdir }
        error = with_env(env) do
          assert_raises(CredentialUnavailableError) do
            DefaultAzureCredential.new.get_token(DEFAULT_SCOPE)
          end
        end

        %w[EnvironmentCredential WorkloadIdentityCredential ManagedIdentityCredential AzureCliCredential].each do |name|
          assert_match(/#{name}: /, error.message)
        end
      end

      def test_default_credential_stops_at_a_credential_that_fails
        @service.fail_next(401, error: "invalid_client", description: "AADSTS700213: No matching federated identity")
        token_file = federated_token_file("kubernetes-token")

        error = with_env(workload_identity_env(token_file).merge(app_service_env)) do
          assert_raises(AuthenticationError) { DefaultAzureCredential.new.get_token(DEFAULT_SCOPE) }
        end
        assert_match(/WorkloadIdentityCredential: .*AADSTS700213/, error.message)
        assert_equal 1, @service.requests.size # managed identity wasn't tried
      end

      def test_access_token_never_shows_the_token
        token = AccessToken.new(token: "secret-token", expires_on: 1_893_456_000)

        refute_includes token.inspect, "secret-token"
        refute_includes token.to_s, "secret-token"
        refute_includes token.pretty_inspect, "secret-token" # IRB and `rails console` print this way
      end

      private

      def app_service_env(extra = {})
        { "IDENTITY_ENDPOINT" => @service.url("/msi/token"), "IDENTITY_HEADER" => MockTokenService::IDENTITY_HEADER }
          .merge(extra)
      end

      def imds_env
        { "AZURE_POD_IDENTITY_AUTHORITY_HOST" => @service.url }
      end

      def entra_env(extra = {})
        { "AZURE_TENANT_ID" => "my-tenant", "AZURE_AUTHORITY_HOST" => @service.url }.merge(extra)
      end

      def workload_identity_env(token_file)
        entra_env("AZURE_CLIENT_ID" => "wi-client-id", "AZURE_FEDERATED_TOKEN_FILE" => token_file)
      end

      def fake_az(script)
        path = File.join(@tmpdir, "az")
        File.write(path, "#!/bin/sh\n#{script}\n")
        File.chmod(0o755, path)
      end

      def federated_token_file(content)
        File.join(@tmpdir, "azure-identity-token").tap { |path| File.write(path, content) }
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def closed_port
        TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      end
    end
  end
end
