# Does VACUUM / wal_checkpoint block or fail while a feed reader is live?
defmodule VacProbe do
  def run do
    path = Path.join(System.tmp_dir!(), "zifiri_vac.db")
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)

    {:ok, w} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA synchronous=NORMAL")
    :ok = Exqlite.Sqlite3.execute(w, "PRAGMA secure_delete=ON")

    :ok =
      Exqlite.Sqlite3.execute(
        w,
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, body BLOB NOT NULL, at INTEGER)"
      )

    body = :crypto.strong_rand_bytes(16_384)
    :ok = Exqlite.Sqlite3.execute(w, "BEGIN")

    {:ok, st} = Exqlite.Sqlite3.prepare(w, "INSERT INTO posts (body,at) VALUES (?,?)")

    for i <- 1..2000 do
      :ok = Exqlite.Sqlite3.bind(st, [body, i])
      :done = Exqlite.Sqlite3.step(w, st)
      :ok = Exqlite.Sqlite3.reset(st)
    end

    :ok = Exqlite.Sqlite3.release(w, st)
    :ok = Exqlite.Sqlite3.execute(w, "COMMIT")
    size = File.stat(path) |> elem(1) |> Map.get(:size)
    IO.puts("VAC db_bytes=#{size} rows=2000")

    # A live feed request: open read transaction, read one page, hold it.
    {:ok, r} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(r, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(r, "BEGIN")
    {:ok, rs} = Exqlite.Sqlite3.prepare(r, "SELECT body FROM posts LIMIT 50")
    {:row, row} = Exqlite.Sqlite3.step(r, rs)
    IO.puts("VAC reader_holds_snapshot=true rows_read=#{length(row)}")

    # writer: DELETE (level 2 erase), then checkpoint, then VACUUM, then checkpoint
    t = fn f ->
      t0 = System.monotonic_time(:microsecond)
      res = f.()
      IO.puts("VAC step=#{inspect(res)} ms=#{Float.round((System.monotonic_time(:microsecond) - t0) / 1000, 1)}")
      res
    end

    t.(fn -> Exqlite.Sqlite3.execute(w, "DELETE FROM posts WHERE at <= 1000") end)
    t.(fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)
    t.(fn -> Exqlite.Sqlite3.execute(w, "VACUUM") end)
    t.(fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)

    # is the writer still usable afterwards?
    t.(fn -> Exqlite.Sqlite3.execute(w, "INSERT INTO posts (body,at) VALUES (x'00', 9999)") end)

    Exqlite.Sqlite3.release(r, rs)
    Exqlite.Sqlite3.execute(r, "COMMIT")
    Exqlite.Sqlite3.close(r)

    # same sequence with no reader, for comparison
    t.(fn -> Exqlite.Sqlite3.execute(w, "PRAGMA wal_checkpoint(TRUNCATE)") end)
    t.(fn -> Exqlite.Sqlite3.execute(w, "VACUUM") end)

    Exqlite.Sqlite3.close(w)
    for sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx)
  end
end

VacProbe.run()
