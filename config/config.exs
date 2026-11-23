import Config

config :zifiri, ecto_repos: [Zifiri.Repo]

# Which config file built this app. `Zifiri.Owner` refuses to run without the
# pepper file when this is `:prod`; there is no runtime way to spoof it.
config :zifiri, :env, config_env()

# The pepper is a file in tmpfs, written by the operator at boot and never
# committed or logged (plan §4.3). `Zifiri.Owner` fails closed if it is
# missing or shorter than 32 bytes, so this path must exist in production.
config :zifiri, :pepper_path, "/run/zifiri/pepper"

# Phoenix.request logging is a leak: the access log prints method, path and
# status, and paths carry room names and post ids (plan §5.1, F-27). This must
# be `false` in every environment, not just production: `Zifiri.LogFilter` is a
# second line of defence, never the only one. With logging off, Phoenix does not
# attach its `[:phoenix, :endpoint, :start/:stop]` handler at boot, so there is
# nothing to suppress.
config :phoenix, :logger, false

# `log: false` in every environment. Ecto's query logger prints the statement
# *and* its parameters, and the parameters are post bodies. There is no env in
# which that is acceptable (plan §5.1).
config :zifiri, Zifiri.Repo,
  pool_size: 1,
  log: false,
  stacktrace: false,
  telemetry_prefix: [:zifiri, :repo],
  journal_mode: :wal,
  busy_timeout: 5_000,
  show_sensitive_data_on_connection_error: false

config :zifiri, Zifiri.Endpoint,
  url: [host: "localhost"],
  pubsub_server: Zifiri.PubSub,
  server: false,
  # Phoenix defaults to the Cowboy adapter; cowboy is not a dependency here.
  # Bandit is the server (plan §4.1), so the adapter must say so explicitly.
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: "zifiri_dev_only_secret_key_base_0123456789abcdef0123456789abcdef"

if config_env() == :dev do
  config :zifiri, Zifiri.Repo, database: Path.expand("../zifiri_dev.db", __DIR__)

  # `mix phx.server` on a workstation has no tmpfs pepper file. This is an
  # explicit dev-only key, not a code fallback: the module itself raises when
  # the file is missing, and production refuses `:owner_pepper` outright (F-02).
  config :zifiri, :owner_pepper, :crypto.hash(:sha256, "zifiri-dev-pepper")

  # `server: false` is the release default; on a workstation the point of
  # `mix phx.server` is a socket you can curl.
  config :zifiri, Zifiri.Endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 4000]
end

if config_env() == :test do
  # The database lives under _build so that `mix clean` is the only cleanup
  # step needed and no test artifact can ever be committed.
  # Two connections, not one: `test_helper.exs` runs migrations outside the
  # sandbox, and a single connection is held by whichever it is doing first.
  config :zifiri, Zifiri.Repo,
    database: Path.expand("../_build/test/zifiri_test.db", __DIR__),
    pool_size: 2,
    pool: Ecto.Adapters.SQL.Sandbox

  # Publication is driven by hand in tests. A wall-clock timer would publish a
  # queue in the middle of an assertion, which is exactly the kind of hidden
  # scheduling the worker is supposed to make explicit.
  config :zifiri, :publish_tick_ms, :manual

  # Tests set the pepper explicitly instead of leaning on the development
  # constant, so a change to the fallback cannot silently change every stored
  # `owner_hash` (F-02). Individual tests override or delete this key.
  config :zifiri, :owner_pepper, :crypto.hash(:sha256, "zifiri-test-pepper")
end
