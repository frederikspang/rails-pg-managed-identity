## [Unreleased]

## [0.1.0] - 2026-10-15

- Initial release. Supports Rails 7.2, 8.0 and 8.1 on Ruby 3.3+.
- `azure_managed_identity` option in `config/database.yml` for the PostgreSQL adapter: the password is a
  Microsoft Entra access token fetched when a connection is opened, cached, and refreshed 5 minutes before
  it expires.
- Credentials: managed identity (App Service, Functions, Container Apps, IMDS on VMs, scale sets, AKS
  nodes), AKS workload identity, service principal with a client secret, and the Azure CLI, chained like
  azure-identity's `DefaultAzureCredential`.
- Reconnects open a new connection with the current token instead of `PG::Connection#reset`.
- `db:schema:dump`/`db:schema:load` with `structure.sql` and `bin/rails dbconsole` get the token too.
- Tokens never show up in logs, `inspect` or `pp`/IRB output.
