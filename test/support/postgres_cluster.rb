# frozen_string_literal: true

require "fileutils"
require "open3"
require "pg"
require "socket"
require "tmpdir"

# A throwaway PostgreSQL cluster standing in for Azure Database for PostgreSQL flexible server:
# TCP only, and every login, the superuser's included, needs a password (SCRAM).
#
# Azure validates Entra access tokens itself. Here, #accept_token makes a token the role's password,
# valid until the token expires, so only the most recently issued token works. That is stricter than
# Azure, which is the point: a connection only succeeds if it presents the current token.
class PostgresCluster
  SUPERUSER = "postgres"
  SUPERUSER_PASSWORD = "superuser-password"

  def self.bindir
    return @bindir if defined?(@bindir)

    candidates = [ENV.fetch("PG_BINDIR", nil), pg_config_bindir, *Dir["/usr/lib/postgresql/*/bin"].reverse]
    @bindir = candidates.compact.find { |dir| File.executable?(File.join(dir, "initdb")) }
  end

  def self.pg_config_bindir
    output, status = Open3.capture2("pg_config", "--bindir")
    output.strip if status.success?
  rescue SystemCallError
    nil
  end

  def self.available?
    !bindir.nil?
  end

  attr_reader :port

  def initialize
    @mutex = Mutex.new
    @connections = {}
  end

  def start
    @dir = Dir.mktmpdir("rails-pg-managed-identity-")
    File.write(pwfile = File.join(@dir, "pwfile"), SUPERUSER_PASSWORD)
    run "initdb", "-D", data_dir, "-U", SUPERUSER, "--pwfile", pwfile, "--auth", "scram-sha-256",
        "--encoding", "UTF8", "--no-locale"
    @port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    File.write(File.join(data_dir, "postgresql.conf"), <<~CONF, mode: "a")
      port = #{port}
      listen_addresses = '127.0.0.1'
      unix_socket_directories = ''
      fsync = off
      full_page_writes = off
    CONF
    run "pg_ctl", "-D", data_dir, "-l", File.join(@dir, "server.log"), "-w", "start"
    self
  end

  def stop
    @connections.each_value(&:close)
    run "pg_ctl", "-D", data_dir, "-m", "immediate", "-w", "stop"
  ensure
    FileUtils.rm_rf(@dir)
  end

  def connect(user: SUPERUSER, password: SUPERUSER_PASSWORD, dbname: "postgres")
    PG.connect(host: "127.0.0.1", port:, user:, password:, dbname:)
  end

  # Runs SQL as the superuser.
  def exec(sql, dbname: "postgres")
    @mutex.synchronize { superuser_connection(dbname).exec(sql) }
  end

  def accept_token(role, token, expires_on)
    @mutex.synchronize do
      conn = superuser_connection("postgres")
      conn.exec("ALTER ROLE #{conn.quote_ident(role)} PASSWORD #{conn.escape_literal(token)} " \
                "VALID UNTIL #{conn.escape_literal(Time.at(expires_on).utc.iso8601)}")
    end
  end

  private

  def superuser_connection(dbname)
    @connections[dbname] ||= connect(dbname:)
  end

  def data_dir
    File.join(@dir, "data")
  end

  def run(command, *)
    output, status = Open3.capture2e(File.join(self.class.bindir, command), *)
    raise "#{command} failed:\n#{output}" unless status.success?
  end
end
