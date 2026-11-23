defmodule LoadSupport do
  @moduledoc """
  Shared bootstrap for the load scripts.

  Both scripts run with `MIX_ENV=test mix run --no-start`, so the application
  has not booted yet and this module can point the Repo at a throwaway SQLite
  file and the endpoint at a local port before anything starts. Nothing here
  touches the development database (`zifiri_dev.db`): the load DB lives under
  `_build/test/zifiri_load.db` and is deleted by `cleanup/1`.

  The test environment's Ecto sandbox pool is removed as well — the scripts are
  a plain client of a plain server, not a test case, and a sandbox would hold
  every query on one checked-out connection.
  """

  alias Zifiri.Repo

  @doc """
  JSON for request bodies and reports.

  Deliberately OTP's `:json` and not the application's codec: the load client
  must not break because the app renamed a module mid-refactor, and a client
  that shares a codec with the server is measuring less than it thinks.
  """
  def encode(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  # -- configuration ----------------------------------------------------------

  @doc """
  Knobs, from the environment so `mix run` argument handling never matters.

    * `LOAD_WRITES` (500) — concurrent writes for the publish run
    * `LOAD_CONCURRENCY` (500) — `Task.async_stream` concurrency
    * `LOAD_PORT` (4010) — the endpoint's local port
    * `LOAD_BITS` (8) — PoW difficulty pinned for the run
    * `LOAD_TICK_MS` (200) — publication turn interval
    * `LOAD_ROWS` (2000) — rows seeded before the feed run
    * `LOAD_FEED_CONCURRENCY` (200)
  """
  def opts do
    %{
      writes: int_env("LOAD_WRITES", 500),
      concurrency: int_env("LOAD_CONCURRENCY", 500),
      port: int_env("LOAD_PORT", 4010),
      bits: int_env("LOAD_BITS", 8),
      tick_ms: int_env("LOAD_TICK_MS", 200),
      rows: int_env("LOAD_ROWS", 2000),
      feed_concurrency: int_env("LOAD_FEED_CONCURRENCY", 200)
    }
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end

  # -- boot -------------------------------------------------------------------

  @doc """
  Boots the real application against a fresh load database and returns its path.

  Steps, in order: delete any previous load DB, rewrite the Repo and Endpoint
  config, start the app (which runs `Zifiri.Owner.validate!/0`, the queue, the
  worker, the challenge store and the endpoint), migrate, then wait until the
  port actually accepts a connection.
  """
  def boot(port) do
    dir = Path.expand("../../_build/test", __DIR__)
    File.mkdir_p!(dir)
    db = Path.join(dir, "zifiri_load.db")
    remove_db(db)
    prime_db(db)

    repo =
      :zifiri
      |> Application.get_env(Repo)
      |> Keyword.delete(:pool)
      |> Keyword.merge(database: db, pool_size: 8, log: false, busy_timeout: 15_000)

    Application.put_env(:zifiri, Repo, repo)

    endpoint =
      :zifiri
      |> Application.get_env(Zifiri.Endpoint)
      |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: port])
      |> maybe_debug_errors()

    Application.put_env(:zifiri, Zifiri.Endpoint, endpoint)

    # The scripts drive the turn themselves; the worker must not tick behind
    # the measurement.
    Application.put_env(:zifiri, :publish_tick_ms, :manual)

    {:ok, _} = Application.ensure_all_started(:zifiri)

    Ecto.Migrator.run(Repo, Ecto.Migrator.migrations_path(Repo), :up, all: true)

    wait_port(port, 100)
    tables()
    db
  end

  # `LOAD_DEBUG_ERRORS=1` makes Phoenix render the raised exception into the
  # response instead of failing to render a 500 page. Diagnostic only.
  defp maybe_debug_errors(config) do
    case System.get_env("LOAD_DEBUG_ERRORS") do
      nil -> config
      "" -> config
      _ -> Keyword.put(config, :debug_errors, true)
    end
  end

  defp remove_db(db) do
    Enum.each([db, db <> "-wal", db <> "-shm"], &File.rm/1)
  end

  # Opening eight connections to a brand-new file races on the journal-mode
  # switch: SQLite needs a brief exclusive lock to move the file into WAL, and
  # the losers log "database is locked" and retry. Doing it once, alone, before
  # the pool starts removes the race (WAL mode persists in the file header).
  defp prime_db(db) do
    case Exqlite.Sqlite3.open(db) do
      {:ok, conn} ->
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=15000")
        _ = Exqlite.Sqlite3.close(conn)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_port(_port, 0), do: raise("endpoint never accepted a connection")

  defp wait_port(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        Process.sleep(100)
        wait_port(port, tries - 1)
    end
  end

  defp tables do
    for {name, type} <- [
          {:load_t0, :set},
          {:load_seen, :set},
          {:load_samples, :duplicate_bag}
        ] do
      if :ets.whereis(name) != :undefined, do: :ets.delete(name)
      :ets.new(name, [type, :public, :named_table])
    end
  end

  @doc "Empties the sampler tables so a warm-up cannot leak into the measurement."
  def reset_samples do
    Enum.each([:load_t0, :load_seen, :load_samples], &:ets.delete_all_objects/1)
    :ok
  end

  # -- HTTP client ------------------------------------------------------------

  @doc """
  No-op kept so the scripts read the same either way.

  The client below is a hand-rolled HTTP/1.1 over `:gen_tcp` rather than
  `:httpc`: `mix run` prunes OTP library paths that are not in the project's
  dependency tree, which leaves `:httpc` half-loadable (`:http_util` resolves to
  `:non_existing`), and a raw socket gives an exact per-request connection and
  an exact byte count, which is what the padding check needs.
  """
  def start_http, do: :ok

  @doc """
  One POST. Returns `{:ok, status, byte_size, micros}` or `{:error, reason, micros}`.

  One TCP connection per request (`connection: close`): the number reported
  includes connect + request + response, which is what a client that has just
  opened the app pays.
  """
  def post_json(port, path, body), do: request(:post, port, path, body)

  @doc "One GET, same shape as `post_json/3`."
  def get_json(port, path), do: request(:get, port, path, nil)

  defp request(method, port, path, body) do
    started = System.monotonic_time(:microsecond)
    result = exchange(method, port, path, body)
    micros = System.monotonic_time(:microsecond) - started

    case result do
      {:ok, status, response} -> {:ok, status, response, micros}
      {:error, reason} -> {:error, reason, micros}
    end
  end

  defp exchange(method, port, path, body) do
    case :gen_tcp.connect(~c"127.0.0.1", port, socket_opts(), 10_000) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, request_bytes(method, port, path, body)),
               {:ok, response} <- recv_all(socket, []) do
            parse(response)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp socket_opts, do: [:binary, active: false, packet: :raw, nodelay: true]

  @doc """
  `count` GETs over a single keep-alive connection, the way a browser reads a
  feed. Returns one result per request, in order.

  The first request on the connection pays the connect; the rest are what the
  server actually costs once the connection exists. That split is the whole
  point of measuring both.
  """
  def keepalive_gets(port, path, count) do
    case :gen_tcp.connect(~c"127.0.0.1", port, socket_opts(), 10_000) do
      {:ok, socket} ->
        try do
          for _ <- 1..count, do: get_on(socket, port, path)
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        List.duplicate({:error, reason, 0}, count)
    end
  end

  defp get_on(socket, port, path) do
    request = ["GET #{path} HTTP/1.1\r\n", "host: 127.0.0.1:", Integer.to_string(port), "\r\n\r\n"]
    started = System.monotonic_time(:microsecond)

    with :ok <- :gen_tcp.send(socket, request),
         {:ok, head, rest} <- read_headers(socket, ""),
         {:ok, body} <- read_body(socket, rest, content_length(head)) do
      micros = System.monotonic_time(:microsecond) - started
      {:ok, status_of(head), body, micros}
    else
      {:error, reason} -> {:error, reason, System.monotonic_time(:microsecond) - started}
    end
  end

  defp read_headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 60_000) do
          {:ok, data} -> read_headers(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_body(_socket, acc, want) when byte_size(acc) >= want, do: {:ok, acc}

  defp read_body(socket, acc, want) do
    case :gen_tcp.recv(socket, 0, 60_000) do
      {:ok, data} -> read_body(socket, acc <> data, want)
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(head) do
    head
    |> String.downcase()
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, "content-length:", parts: 2) do
        [_prefix, value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp status_of(head) do
    head |> String.split("\r\n") |> hd() |> String.split(" ") |> Enum.at(1) |> String.to_integer()
  end

  defp request_bytes(method, port, path, body) do
    line =
      case method do
        :post -> "POST #{path} HTTP/1.1\r\n"
        :get -> "GET #{path} HTTP/1.1\r\n"
      end

    headers =
      case method do
        :post ->
          ["content-type: application/json\r\n", "content-length: #{byte_size(body)}\r\n"]

        :get ->
          []
      end

    [line, "host: 127.0.0.1:", Integer.to_string(port), "\r\nconnection: close\r\n", headers,
     "\r\n", body || ""]
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 120_000) do
      {:ok, data} -> recv_all(socket, [acc, data])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(response) do
    with [head, body] <- :binary.split(response, "\r\n\r\n"),
         [status_line | _] <- :binary.split(head, "\r\n"),
         [_http, code | _] <- String.split(status_line, " ") do
      {:ok, String.to_integer(code), body}
    else
      _ -> {:error, :bad_response}
    end
  end

  # -- statistics -------------------------------------------------------------

  @doc "min/p50/p95/p99/max/mean over a list of numbers (microseconds or ms)."
  def stats([]), do: nil

  def stats(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      "count" => n,
      "min" => hd(sorted),
      "p50" => at(sorted, n, 50),
      "p95" => at(sorted, n, 95),
      "p99" => at(sorted, n, 99),
      "max" => List.last(sorted),
      "mean" => Float.round(Enum.sum(sorted) / n, 2)
    }
  end

  defp at(sorted, n, p) do
    index = max(0, min(n - 1, ceil(p / 100 * n) - 1))
    Enum.at(sorted, index)
  end

  @doc "Column header matching `row/3`."
  def header do
    pad("", 18) <>
      Enum.map_join(["min", "p50", "p95", "p99", "max", "mean"], " ", &pad(&1, 9))
  end

  @doc "Formats a stats map as one fixed-width row; `unit` labels the numbers."
  def row(label, nil, unit), do: pad(label, 18) <> "not measured (#{unit})"

  def row(label, stats, unit) do
    pad(label, 18) <>
      Enum.map_join(["min", "p50", "p95", "p99", "max", "mean"], " ", fn key ->
        pad(fmt(stats[key]), 9)
      end) <> unit
  end

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp fmt(nil), do: "-"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp fmt(value), do: to_string(value)

  # -- output -----------------------------------------------------------------

  @doc "Writes the report as JSON under `scripts/load/results/` and returns the path."
  def write_report(report) do
    dir = Path.expand("results", __DIR__)
    File.mkdir_p!(dir)

    stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[^0-9T]/, "")
    path = Path.join(dir, "#{report["kind"]}-#{stamp}.json")

    File.write!(path, encode(report) <> "\n")
    path
  end

  @doc """
  Stops the app and deletes the load database.

  Called at the end of every run so the next one starts from an empty file and
  no artifact survives in `_build`.
  """
  def cleanup(db) do
    _ = Application.stop(:zifiri)
    remove_db(db)
    :ok
  end

  # -- read helpers -----------------------------------------------------------

  @doc "How many listings exist right now."
  def listing_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM listings")
    count
  end

  @doc "How many rows there are per padded envelope size."
  def body_sizes do
    %{rows: rows} = Repo.query!("SELECT length(body), count(*) FROM listings GROUP BY 1")

    Map.new(rows, fn [size, count] -> {to_string(size), count} end)
  end

  @doc "Deletes every listing (used to clear a warm-up); returns how many."
  def clear_listings do
    %{num_rows: deleted} = Repo.query!("DELETE FROM listings")
    deleted
  end

  @doc """
  Inserts `rows` listings straight into the table.

  Seeding is not what the feed measurement is about — the rows only have to be
  rows the read path will serve — so this is one raw transaction instead of
  `rows` proofs. Every envelope is a real `Zifiri.Envelope.encode/1` result, so
  the page sizes are the page sizes real traffic produces.
  """
  def seed_listings(rows) do
    day = Date.utc_today() |> Date.to_iso8601()

    Repo.transaction(fn ->
      Enum.each(1..rows, fn i ->
        {bucket, envelope} = seed_envelope(i)

        Repo.query!(
          "INSERT INTO listings (title, body, price_cents, currency, category, owner_hash, status, created_day) " <>
            "VALUES (?, X'#{Base.encode16(envelope)}', ?, ?, ?, X'#{Base.encode16(:crypto.strong_rand_bytes(32))}', 'open', ?)",
          ["seed #{i}", i * 100, "USD", "test", day]
        )

        bucket
      end)
    end)

    rows
  end

  defp seed_envelope(i) do
    bucket =
      case rem(i, 10) do
        0 -> 4096
        n when n in 1..2 -> 1024
        _ -> 256
      end

    prefix = "feed seed açıklaması #{i} "
    filler = max(bucket - 4 - byte_size(prefix) - 1, 1)
    {:ok, envelope, ^bucket} = Zifiri.Envelope.encode(prefix <> String.duplicate("x", filler))
    {bucket, envelope}
  end

  @doc "System clock in milliseconds — the clock every latency in these scripts uses."
  def now_ms, do: System.system_time(:millisecond)

  @doc "Blocks until `fun` is true or `deadline_ms` passes; returns the last value."
  def wait_until(fun, deadline_ms, every_ms \\ 50) do
    cond do
      fun.() ->
        true

      now_ms() >= deadline_ms ->
        false

      true ->
        Process.sleep(every_ms)
        wait_until(fun, deadline_ms, every_ms)
    end
  end
end
