# rails-pg-managed-identity

> [!WARNING]
> Not yet published. Not yet tested in real life world.


Passwordless connections from Rails (7.2+, Ruby 3.3+) to **Azure Database for PostgreSQL flexible server** using
Microsoft Entra access tokens: the app's managed identity, AKS workload identity, a service principal, or
your `az login` during development.

The token *is* the PostgreSQL password, but tokens expire (5–60 minutes for user tokens, longer for
managed identities), so a value fixed in `database.yml` at boot doesn't work. With this gem the password
is resolved **each time a connection is opened**: a cached token is reused until 5 minutes before it
expires, then a new one is requested, the way `DefaultAzureCredential` does it in Microsoft's SDKs.
It's the Ruby counterpart of Microsoft's
[`azure-postgresql-auth`](https://learn.microsoft.com/python/api/overview/azure/postgresql-auth-readme)
for Python, for the `pg` gem and Active Record. There is no maintained Azure Identity SDK for Ruby, so the
token endpoints are called directly (stdlib `Net::HTTP`, no other dependencies).

## Installation

```ruby
# Gemfile
gem "rails-pg-managed-identity"
```

## Usage

Add `azure_managed_identity` to the database configuration and leave out the password:

```yaml
# config/database.yml
production:
  adapter: postgresql
  host: my-server.postgres.database.azure.com
  database: my_app
  username: my-app-identity   # the identity's PostgreSQL role, see "Azure setup"
  sslmode: require
  azure_managed_identity: true
```

That's it. Booting the app requests nothing; the first query opens a connection, which fetches a token.
Every connection in every pool shares the cached token.

Options, instead of `true`:

```yaml
  azure_managed_identity:
    client_id: <%= ENV["AZURE_CLIENT_ID"] %>  # user-assigned managed identity (default: AZURE_CLIENT_ID)
    credential: managed_identity              # use only this credential (default: "default", the chain below)
    scope: https://ossrdbms-aad.database.usgovcloudapi.net/.default  # other clouds
```

`DATABASE_URL` works too: `postgres://my-app-identity@my-server.postgres.database.azure.com/my_app?sslmode=require&azure_managed_identity=true`.

### Where tokens come from

`credential: default` tries these in order, like azure-identity's `DefaultAzureCredential`, and sticks
with the first one that works:

| `credential:` | Where | Configured by |
| --- | --- | --- |
| `environment` | Service principal with a secret, anywhere | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` |
| `workload_identity` | AKS with Microsoft Entra Workload ID | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_FEDERATED_TOKEN_FILE` (injected by the webhook) |
| `managed_identity` | App Service, Functions, Container Apps | `IDENTITY_ENDPOINT`, `IDENTITY_HEADER` (set by the platform) |
| `managed_identity` | VMs, scale sets, AKS nodes | Instance Metadata Service at `169.254.169.254` |
| `azure_cli` | Your machine | `az login` |

Azure Arc and Service Fabric managed identities aren't supported.

### Azure setup

1. Enable Microsoft Entra authentication on the server and add yourself as Microsoft Entra administrator.
2. Give the app an identity (system- or user-assigned managed identity, or workload identity).
3. As the Entra administrator, connected to the `postgres` database, create a role for the identity, named after it:

   ```sql
   select * from pgaadauth_create_principal('my-app-identity', false, false);
   ```

4. Grant that role what the app needs, and use its name as `username` in `database.yml`.

For local development against Azure, `az login` and use your own user principal name (or an Entra group
you're a member of) as `username`.

### Token lifecycle

- Tokens are fetched lazily, when a connection is opened, and reused until 5 minutes before expiry
  (`RailsPg::ManagedIdentity.refresh_offset = 300`).
- While the cached token is still valid, a new one is requested at most every 30 seconds. If that
  request fails, the cached token is used and the failure is logged. A token is never handed out with
  less than 10 seconds left.
- PostgreSQL only checks the password when a session starts, so open connections outlive their token.
  New connections, reconnects included, always get a current one. (Reconnects open a fresh connection
  instead of `PG::Connection#reset`, which would reuse the original, possibly expired, password.)
- Failures raise `RailsPg::ManagedIdentity::AuthenticationError` or `CredentialUnavailableError`,
  both `ActiveRecord::ConnectionNotEstablished`s, so Active Record's connection retries apply.
- Tokens never appear in logs, `inspect` or `pp` output. Logging goes to `ActiveRecord::Base.logger`,
  or set `RailsPg::ManagedIdentity.logger`.

`bin/rails dbconsole`, and `db:schema:dump`/`db:schema:load` with `structure.sql` (`pg_dump`/`psql`),
get the token through `PGPASSWORD`. The database tasks are only hooked when rake tasks are loaded, so
app and job processes don't load that code.

## Development

```bash
bin/setup
bundle exec rake   # tests and RuboCop

# Against another supported Rails version (CI runs Ruby 3.3, 3.4 and 4.0 with Rails 7.2, 8.0 and 8.1):
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rake test
```

The tests need PostgreSQL's server binaries (`initdb`, `pg_ctl`); they're found through `pg_config`, or
set `PG_BINDIR`. No running server or Azure account is needed:

- `test/support/mock_token_service.rb` imitates the managed identity endpoints (App Service and IMDS) and
  Microsoft Entra ID's token endpoint, validating requests the way they do and issuing long random tokens.
- `test/support/postgres_cluster.rb` starts a throwaway cluster in which every login needs a password.
  Each token the mock issues becomes the app role's password, valid until the token expires, so a
  connection only succeeds with the current token.
- `test/dummy` is a minimal Rails app whose `database.yml` has `azure_managed_identity: true` and no
  password. The integration tests boot it with `IDENTITY_ENDPOINT` pointing at the mock, as on App Service.

## Contributing

Bug reports and pull requests are welcome. This project is intended to be a safe, welcoming space for
collaboration, and contributors are expected to adhere to the [code of conduct](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
