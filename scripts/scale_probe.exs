# 4 KB frames are the real unit (69 MB/day = 144 buckets x 120 x 4 KB).
# 1M messages therefore ~= 4.1 GB on disk. Measure per-row cost and VACUUM at ~1 GB.
defmodule Scale do
  def run do
    path = Path.join(System.tmp_dir!(), "zifiri_scale.db")
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)

    {:ok, w} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA synchronous=NORMAL")
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA secure_delete=ON")
    :ok = Exqlite.Sqlite3.execute(w, "CREATE TABLE posts (id INTEGER PRIMARY KEY, body BLOB NOT NULL, at INTEGER)")

    body4 = :crypto.strong_rand_bytes(4096)

    # per-row cost at 4 KB, 120-row turn transaction, 10 repeats
    times =
      for _ <- 1..10 do
        t = System.monotonic_time(:microsecond)
        :ok = Exqlite.Sqlite3.execute(w, "BEGIN")
        {:ok, st} = Exqlite.Sqlite3.prepare(w, "INSERT INTO posts (body,at) VALUES (?,?)")

        for i <- 1..120 do
          :ok = Exqlite.Sqlite3.bind(st, [body4, i])
          :done = Exqlite.Sqlite3.step(w, st)
          :ok = Exqlite.Sqlite3.reset(st)
        end

        :ok = Exqlite.Sqlite3.release(w, st)
        :ok = Exqlite.Sqlite3.execute(w, "COMMIT")
        System.monotonic_time(:microsecond) - t
      end

    times = Enum.sort(times)
    IO.puts("SCALE turn_120x4kb_ms min=#{Float.round(hd(times) / 1000, 1)} median=#{Float.round(Enum.at(times, 5) / 1000, 1)} max=#{Float.round(List.last(times) / 1000, 1)}")

    # grow to ~1 GB
    body16 = :crypto.strong_rand_bytes(16_384)
    t = System.monotonic_time(:millisecond)

    Enum.chunk_every(1..60_000, 1000)
    |> Enum.each(fn chunk ->
      :ok = Exqlite.Sqlite3.execute(w, "BEGIN")
      {:ok, st} = Exqlite.Sqlite3.prepare(w, "INSERT INTO posts (body,at) VALUES (?,?)")

      for i <- chunk do
        :ok = Exqlite.Sqlite3.bind(st, [body16, i])
        :done = Exqlite.Sqlite3.step(w, st)
        :ok = Exqlite.Sqlite3.reset(st)
      end

      :ok = Exqlite.Sqlite3.release(w, st)
      :ok = Exqlite.Sqlite3.execute(w, "COMMIT")
    end)

    fill = System.monotonic_time(:millisecond) - t
    mb = Float.round(File.stat(path) |> elem(1) |> Map.get(:size) |> Kernel./(1_048_576), 0)
    IO.puts("SCALE fill_to_#{mb}MB ms=#{fill} rows=60600")

    step = fn label, f ->
      t0 = System.monotonic_time(:millisecond)
      r = f.()
      IO.puts("SCALE #{label} ms=#{System.monotonic_time(:millisecond) - t0} result=#{inspect(r)}")
    end

    step.("checkpoint", fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)
    step.("delete_10pct", fn -> Exqlite.Sqlite3.execute(w, "DELETE FROM posts WHERE at <= 6000") end)
    step.("vacuum", fn -> Exqlite.Sqlite3.execute(w, "VACUUM") end)
    IO.puts("SCALE db_MB_after=#{Float.round(File.stat(path) |> elem(1) |> Map.get(:size) |> Kernel./(1_048_576), 0)}")

    Exqlite.Sqlite3.close(w)
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)
  end
end

Scale.run()
