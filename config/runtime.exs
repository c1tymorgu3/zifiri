import Config

if config_env() == :prod do
  # Warnings and above only. `Zifiri.LogFilter` additionally drops debug/info
  # records in every environment, so this is the second belt, not the only one
  # (plan §5.1).
  config :logger, level: :warning

  config :zifiri, Zifiri.Repo,
    database: System.get_env("ZIFIRI_DB_PATH", "/var/lib/zifiri/zifiri.db"),
    pool_size: 1,
    log: false

  # The only sink that survives in production: a 1 MiB ring, error level, fixed
  # shape (level, class, module, line) and no message text. See Zifiri.ErrorLog.
  config :zifiri, :error_log,
    path: System.get_env("ZIFIRI_ERR_LOG", "/var/lib/zifiri/err.log"),
    max_bytes: 1_048_576,
    max_files: 1,
    level: :error

  # nginx talks to Phoenix over a unix socket, never TCP, so no peer address
  # exists for the BEAM to read even by accident (plan §5.1, §11.3).
  config :zifiri, Zifiri.Endpoint,
    server: true,
    http: [ip: {:local, System.get_env("ZIFIRI_SOCKET", "/run/zifiri/http.sock")}],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

  # The ownership pepper is placed in tmpfs by the operator at boot and is
  # never written to disk (plan §4.3, §11.4). `Zifiri.Owner.validate!/0` runs
  # first thing in `Zifiri.Application.start/2` and raises if the file is
  # missing, unreadable, or shorter than 32 bytes — a missing pepper stops the
  # boot instead of quietly falling back to the development constant (F-02).
  # `:owner_pepper` is a dev/test key only; setting it here is refused.
  config :zifiri, :pepper_path, System.get_env("ZIFIRI_PEPPER", "/run/zifiri/pepper")
end
