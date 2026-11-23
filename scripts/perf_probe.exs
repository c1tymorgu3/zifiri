# Performance probes for the architecture debate. Nothing here is guessed.
defmodule Probe do
  def time_ms(fun) do
    t0 = System.monotonic_time(:microsecond)
    r = fun.()
    {System.monotonic_time(:microsecond) - t0, r}
  end

  def fmt(us), do: Float.round(us / 1000, 2)

  def run do
    bucket_probe()
    pow_probe()
    ets_probe()
    sqlite_probe()
    size_probe()
  end

  # --- A. bucket drain, 120 x 4 KB frames -------------------------------
  def bucket_probe do
    Zifiri.Bucket.reset()
    frame = :binary.copy(<<7>>, 4096)

    {add_us, _} =
      time_ms(fn ->
        for i <- 1..120, do: Zifiri.Bucket.add(%{id: i, body: frame})
      end)

    {drain_us, %{size: n}} = time_ms(fn -> Zifiri.Bucket.drain() end)
    mem = :ets.info(:zifiri_bucket, :memory) * 8

    IO.puts("BUCKET add_120_us=#{add_us} drain_120_us=#{drain_us} size=#{n} ets_bytes_after_drain=#{mem}")
  end

  # --- B. PoW ------------------------------------------------------------
  def pow_probe do
    hash = :crypto.hash(:sha256, "probe")

    # verify cost: 200_000 attempts, count how many pass 20 bits
    {us, ok} =
      time_ms(fn ->
        Enum.count(0..199_999, fn nonce -> Zifiri.Pow.verify(hash, nonce, 20) end)
      end)

    per_verify_us = us / 200_000
    IO.puts("POW verify_per_call_us=#{Float.round(per_verify_us, 3)} passes_in_200k=#{ok}")

    # full solve at 20 bits, server-side, measured once
    {solve_us, nonce} = time_ms(fn -> Zifiri.Pow.solve(hash, 20) end)
    IO.puts("POW solve_20bit_ms=#{fmt(solve_us)} nonce=#{nonce}")

    {s24, _} = time_ms(fn -> Zifiri.Pow.solve(:crypto.hash(:sha256, "p2"), 24) end)
    IO.puts("POW solve_24bit_ms=#{fmt(s24)}")
  end

  # --- C. ETS growth -----------------------------------------------------
  def ets_probe do
    t = :ets.new(:probe, [:set, :public, {:write_concurrency, true}])
    frame = :binary.copy(<<7>>, 4096)
    empty = :ets.info(t, :memory)

    # 1M decoy-shaped entries: 4 KB binary *referenced*, not copied
    {us, _} =
      time_ms(fn ->
        Enum.each(1..1_000_000, fn i ->
          :ets.insert(t, {i, %{id: i, pubkey: :crypto.strong_rand_bytes(32), sig: :crypto.strong_rand_bytes(64), body: frame, bucket: 4096, ctr: i, at: 0}})
        end)
      end)

    words = :ets.info(t, :memory)
    IO.puts("ETS 1M_entries_us=#{us} words=#{words} table_bytes=#{words * 8} empty_bytes=#{empty * 8}")
    :ets.delete(t)

    # unique 4 KB binaries: what a real 1M-message table costs
    t2 = :ets.new(:probe2, [:set, :public])

    {us2, _} =
      time_ms(fn ->
        Enum.each(1..200_000, fn i -> :ets.insert(t2, {i, :crypto.strong_rand_bytes(4096)}) end)
      end)

    w = :ets.info(t2, :memory)

    IO.puts(
      "ETS 200k_unique_4kb_us=#{us2} table_bytes=#{w * 8} extrapolated_1M_MB=#{div(w * 8 * 5, 1_000_000)}"
    )

    :ets.delete(t2)
  end


  # --- F. in-memory vs disk, real 16 KB padded body ----------------------
  def size_probe do
    for {label, dsn} <- [{"memory", ":memory:"}, {"disk", nil}] do
      path =
        case dsn do
          nil ->
            p = Path.join(System.tmp_dir!(), "zifiri_size.db")
            for sfx <- ["", "-wal", "-shm"], do: File.rm(p <> sfx)
            p

          _ ->
            dsn
        end

      {:ok, c} = Exqlite.Sqlite3.open(path)
      :ok = Exqlite.Sqlite3.execute(c, "PRAGMA journal_mode=WAL")
      :ok = Exqlite.Sqlite3.execute(c, "PRAGMA synchronous=NORMAL")
      :ok = Exqlite.Sqlite3.execute(c, "PRAGMA secure_delete=ON")
      :ok = Exqlite.Sqlite3.execute(c, "CREATE TABLE posts (id INTEGER PRIMARY KEY, body BLOB NOT NULL, bucket INTEGER, at INTEGER)")

      for bytes <- [1024, 16_384] do
        body = :crypto.strong_rand_bytes(bytes)
        n = 2000

        {us, _} =
          time_ms(fn ->
            :ok = Exqlite.Sqlite3.execute(c, "BEGIN")
            {:ok, st} = Exqlite.Sqlite3.prepare(c, "INSERT INTO posts (body,bucket,at) VALUES (?,?,?)")
            for i <- 1..n do
              :ok = Exqlite.Sqlite3.bind(st, [body, 16_384, i])
              :done = Exqlite.Sqlite3.step(c, st)
              :ok = Exqlite.Sqlite3.reset(st)
            end
            :ok = Exqlite.Sqlite3.release(c, st)
            :ok = Exqlite.Sqlite3.execute(c, "COMMIT")
          end)

        IO.puts("SIZE #{label} body=#{bytes} rows=#{n} total_ms=#{fmt(us)} per_row_us=#{Float.round(us / n, 1)}")
      end

      Exqlite.Sqlite3.close(c)
      if path != ":memory:", do: for(sfx <- ["", "-wal", "-shm"], do: File.rm(path <> sfx))
    end
  end

  # --- D. SQLite write path ---------------------------------------------
  def sqlite_probe do
    path = Path.join(System.tmp_dir!(), "zifiri_probe.db")
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    {:ok, c} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(c, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(c, "PRAGMA synchronous=NORMAL")
    :ok = Exqlite.Sqlite3.execute(c, "PRAGMA secure_delete=ON")

    :ok =
      Exqlite.Sqlite3.execute(
        c,
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, body BLOB NOT NULL, bucket INTEGER, at INTEGER)"
      )

    body = :crypto.strong_rand_bytes(1024)

    # one row per implicit transaction (what Repo.insert does outside a tx)
    {us_one, _} =
      time_ms(fn ->
        for i <- 1..120 do
          :ok = Exqlite.Sqlite3.execute(c, "BEGIN")
          {:ok, st} = Exqlite.Sqlite3.prepare(c, "INSERT INTO posts (body,bucket,at) VALUES (?,?,?)")
          :ok = Exqlite.Sqlite3.bind(st, [body, 1024, i])
          :done = Exqlite.Sqlite3.step(c, st)
          :ok = Exqlite.Sqlite3.release(c, st)
          :ok = Exqlite.Sqlite3.execute(c, "COMMIT")
        end
      end)

    # 120 rows in one transaction (the turn write path)
    {us_tx, _} =
      time_ms(fn ->
        :ok = Exqlite.Sqlite3.execute(c, "BEGIN")
        {:ok, st} = Exqlite.Sqlite3.prepare(c, "INSERT INTO posts (body,bucket,at) VALUES (?,?,?)")
        for i <- 1..120 do
          :ok = Exqlite.Sqlite3.bind(st, [body, 1024, i])
          :done = Exqlite.Sqlite3.step(c, st)
          :ok = Exqlite.Sqlite3.reset(st)
        end
        :ok = Exqlite.Sqlite3.release(c, st)
        :ok = Exqlite.Sqlite3.execute(c, "COMMIT")
      end)

    wal = File.stat(path <> "-wal") |> elem(1) |> Map.get(:size)

    IO.puts(
      "SQLITE 120_rows_120tx_ms=#{fmt(us_one)} 120_rows_1tx_ms=#{fmt(us_tx)} per_row_autocommit_us=#{Float.round(us_one / 120, 1)} wal_bytes=#{wal}"
    )

    # bulk: 5 000 rows in one tx, to see per-row marginal cost
    {us_bulk, _} =
      time_ms(fn ->
        :ok = Exqlite.Sqlite3.execute(c, "BEGIN")
        {:ok, st} = Exqlite.Sqlite3.prepare(c, "INSERT INTO posts (body,bucket,at) VALUES (?,?,?)")
        for i <- 1..5000 do
          :ok = Exqlite.Sqlite3.bind(st, [body, 1024, i])
          :done = Exqlite.Sqlite3.step(c, st)
          :ok = Exqlite.Sqlite3.reset(st)
        end
        :ok = Exqlite.Sqlite3.release(c, st)
        :ok = Exqlite.Sqlite3.execute(c, "COMMIT")
      end)

    IO.puts("SQLITE 5000_rows_1tx_ms=#{fmt(us_bulk)} per_row_us=#{Float.round(us_bulk / 5000, 2)}")

    # --- E. VACUUM while a reader holds a snapshot ---
    {vac_us, _} = time_ms(fn -> Exqlite.Sqlite3.execute(c, "VACUUM") end)

    {:ok, r} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(r, "PRAGMA journal_mode=WAL")
    {:ok, rs} = Exqlite.Sqlite3.prepare(r, "SELECT count(*) FROM posts")
    _ = Exqlite.Sqlite3.step(r, rs)
    

    # reader now holds an open read statement (a live feed request)
    {vac_busy_us, res} =
      time_ms(fn -> Exqlite.Sqlite3.execute(c, "PRAGMA wal_checkpoint(TRUNCATE)") end)

    size_before = File.stat(path) |> elem(1) |> Map.get(:size)
    IO.puts("VACUUM rows=5120 ms=#{fmt(vac_us)} db_bytes=#{size_before} checkpoint_with_open_reader_ms=#{fmt(vac_busy_us)} result=#{inspect(res)}")

    :ok = Exqlite.Sqlite3.release(r, rs)
    Exqlite.Sqlite3.close(r)
    Exqlite.Sqlite3.close(c)
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
  end
end

Probe.run()
