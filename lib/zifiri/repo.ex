defmodule Zifiri.Repo do
  @moduledoc """
  The single SQLite file (plan §11.2).

  `log: false` is set in `config/config.exs` for every environment, not only
  production: Ecto's query logger prints bound parameters, and the parameters
  are post bodies. `telemetry_prefix` is `[:zifiri, :repo]` so query events go
  to `Zifiri.Telemetry`, which counts them and throws the metadata away.

  Three pragmas are applied to **every** connection as it opens, because all
  three are per-connection state in SQLite and none of them can be stored in
  the file once and for all:

  * `secure_delete=ON` — freed content is zeroed instead of left readable in
    the freelist. This is the pragma that makes a `DELETE` followed by a
    `VACUUM` actually remove a body rather than merely unlink it (plan §6.1).
  * `journal_mode=WAL` — readers do not block the writer, and the checkpoint
    sequence in `Zifiri.Vanish` has a `-wal` file to truncate.
  * `synchronous=NORMAL` — durable on commit without an fsync per transaction.
    `FULL` buys nothing here: a lost tail is a lost post, not a corrupt file.

  `pool_size` is 1 in every environment, so a pragma set at open time is the
  only way this per-connection state can drift, and it cannot drift silently:
  `test/vanish_test.exs` reads all three values back.
  """

  use Ecto.Repo,
    otp_app: :zifiri,
    adapter: Ecto.Adapters.SQLite3

  @pragmas [
    "PRAGMA secure_delete=ON",
    "PRAGMA journal_mode=WAL",
    "PRAGMA synchronous=NORMAL"
  ]

  @impl Ecto.Repo
  def init(_type, config) do
    {:ok, Keyword.put(config, :after_connect, {__MODULE__, :configure, []})}
  end

  @doc """
  Runs on every new connection, before the pool hands it out.

  Raises on failure: a connection without `secure_delete` would go on leaving
  deleted bodies in free pages, and that is not a condition worth limping
  through.
  """
  @spec configure(DBConnection.t()) :: :ok
  def configure(conn) do
    Enum.each(@pragmas, fn sql ->
      query = Exqlite.Query.build(statement: sql)
      DBConnection.execute!(conn, query, [], [])
    end)
  end
end
