# How long does the erase sequence hold the single SQLite connection at
# production-like file sizes? 69 MB/day of 16 KB frames => ~480 MB is a week.
defmodule BigVac do
  def run do
    path = Path.join(System.tmp_dir!(), "zifiri_bigvac_#{System.get_env("SD", "ON")}.db")
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)

    {:ok, w} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA synchronous=NORMAL")
    :ok = Exqlite.Sqlite3.execute(w, System.get_env("SD", "ON") |> then(&"PRAGMA secure_delete=#{&1}"))
    :ok = Exqlite.Sqlite3.execute(w, "CREATE TABLE posts (id INTEGER PRIMARY KEY, body BLOB NOT NULL, at INTEGER)")

    body = :crypto.strong_rand_bytes(16_384)
    rows = 30_000

    t0 = System.monotonic_time(:millisecond)

    Enum.chunk_every(1..rows, 500)
    |> Enum.each(fn chunk ->
      :ok = Exqlite.Sqlite3.execute(w, "BEGIN")
      {:ok, st} = Exqlite.Sqlite3.prepare(w, "INSERT INTO posts (body,at) VALUES (?,?)")

      for i <- chunk do
        :ok = Exqlite.Sqlite3.bind(st, [body, i])
        :done = Exqlite.Sqlite3.step(w, st)
        :ok = Exqlite.Sqlite3.reset(st)
      end

      :ok = Exqlite.Sqlite3.release(w, st)
      :ok = Exqlite.Sqlite3.execute(w, "COMMIT")
    end)

    fill_ms = System.monotonic_time(:millisecond) - t0
    size = File.stat(path) |> elem(1) |> Map.get(:size)
    IO.puts("BIG fill_ms=#{fill_ms} rows=#{rows} db_MB=#{Float.round(size / 1_048_576, 1)}")

    step = fn label, f ->
      t = System.monotonic_time(:millisecond)
      res = f.()
      IO.puts("BIG #{label} ms=#{System.monotonic_time(:millisecond) - t} result=#{inspect(res)}")
    end

    step.("checkpoint_before", fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)
    step.("delete_half", fn -> Exqlite.Sqlite3.execute(w, "DELETE FROM posts WHERE at <= 15000") end)
    step.("checkpoint_mid", fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)
    step.("vacuum", fn -> Exqlite.Sqlite3.execute(w, "VACUUM") end)
    step.("checkpoint_after", fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)

    after_size = File.stat(path) |> elem(1) |> Map.get(:size)
    IO.puts("BIG db_MB_after=#{Float.round(after_size / 1_048_576, 1)}")

    Exqlite.Sqlite3.close(w)
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)
  end
end

BigVac.run()
