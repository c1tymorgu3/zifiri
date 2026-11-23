# Feed-path load measurement (plan §16: feed p95 < 300 ms, and §4.1's claim that
# every response is the same number of bytes on the wire).
#
#   MIX_ENV=test mix run --no-start scripts/load/feed_load.exs
#
# Seeds `LOAD_ROWS` listings through the real `Zifiri.Listings.create/1` — a real
# envelope and a real eight-bit proof per row, so the rows are rows the API would
# have accepted — then runs two phases against the real endpoint:
#
#   1. cold — `LOAD_FEED_CONCURRENCY` simultaneous `GET /api/listings`, one fresh
#      TCP connection each. This number includes connect + accept.
#   2. keep-alive — the same number of simultaneous connections, five requests
#      each, so requests 2..5 are pure server time.
#
# Per request it records the response time, the response body byte size (the
# padding claim) and how many listings fit in one padded page.
#
# Results land in scripts/load/results/*.json and on stdout as a table.

Code.require_file("load_support.exs", __DIR__)

defmodule FeedLoad do
  @moduledoc false

  @path "/api/listings?limit=30"
  @per_connection 5

  def run(opts) do
    db = LoadSupport.boot(opts.port)
    LoadSupport.start_http()

    IO.puts("zifiri feed load — #{opts.feed_concurrency} concurrent reads, " <>
              "#{opts.rows} seeded listings")

    IO.puts("database: #{db}\n")

    seeded = LoadSupport.seed_listings(opts.rows)
    IO.puts("seeded #{seeded} listings, envelope sizes #{inspect(LoadSupport.body_sizes())}\n")

    warmup(opts.port)

    {cold, cold_ms} = timed(fn -> fan_out(opts.port, opts.feed_concurrency, 1) end)

    {keepalive, keepalive_ms} =
      timed(fn -> fan_out(opts.port, opts.feed_concurrency, @per_connection) end)

    report = build_report(opts, db, cold, cold_ms, keepalive, keepalive_ms)
    print(report)

    path = LoadSupport.write_report(report)
    IO.puts("\nJSON: #{path}")

    LoadSupport.cleanup(db)
    IO.puts("load database deleted: #{db}")
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, div(System.monotonic_time(:microsecond) - started, 1000)}
  end

  # One connection per worker, `per_connection` requests each.
  defp fan_out(port, connections, per_connection) do
    1..connections
    |> Task.async_stream(
      fn _ -> LoadSupport.keepalive_gets(port, @path, per_connection) end,
      max_concurrency: connections,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, list} -> list
      {:exit, reason} -> List.duplicate({:error, inspect({:exit, reason}), 0}, per_connection)
    end)
  end

  defp warmup(port) do
    for _ <- 1..20, do: LoadSupport.keepalive_gets(port, @path, 1)
    :ok
  end

  # -- report ---------------------------------------------------------------

  defp build_report(opts, db, cold, cold_ms, keepalive, keepalive_ms) do
    %{
      "kind" => "feed",
      "measured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "host" => hostname(),
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "endpoint" => "GET /api/listings",
      "config" => %{
        "concurrency" => opts.feed_concurrency,
        "seeded_rows" => opts.rows,
        "path" => @path,
        "requests_per_connection" => @per_connection,
        "database" => db
      },
      "rows" => LoadSupport.listing_count(),
      "envelope_sizes" => LoadSupport.body_sizes(),
      "cold" => phase(cold, cold_ms),
      "keepalive" => phase(keepalive, keepalive_ms),
      "keepalive_steady" => phase(drop_first_per_connection(keepalive), keepalive_ms),
      "items_per_page" => items_per_page(cold ++ keepalive),
      "memory" => %{"end_bytes" => :erlang.memory(:total)}
    }
  end

  defp phase(results, wall_ms) do
    # Only a `200` is a served page; a `500` is the server failing, and a
    # transport error never got a body at all.
    ok = Enum.filter(results, &match?({:ok, 200, _body, _micros}, &1))
    micros = Enum.map(ok, fn {:ok, _status, _body, micros} -> micros end)
    bodies = Enum.map(ok, fn {:ok, _status, body, _micros} -> body end)
    sizes = bodies |> Enum.map(&byte_size/1) |> Enum.frequencies() |> Enum.sort()

    %{
      "requests" => length(results),
      "ok" => length(ok),
      "failed" => length(results) - length(ok),
      "statuses" =>
        results
        |> Enum.frequencies_by(fn
          {:ok, status, _body, _micros} -> to_string(status)
          {:error, _reason, _micros} -> "error"
        end)
        |> Map.new(),
      "response_ms" => LoadSupport.stats(Enum.map(micros, fn m -> Float.round(m / 1000, 2) end)),
      "bytes" => %{
        "distinct" => Map.new(sizes, fn {size, count} -> {to_string(size), count} end),
        "uniform" => length(sizes) == 1
      },
      "padding" => %{
        "all_padded" => bodies != [] and Enum.all?(bodies, &(&1 != String.trim_trailing(&1))),
        "all_shaped" =>
          bodies != [] and
            Enum.all?(bodies, fn b ->
              String.starts_with?(b, ~s({"listings":[)) and
                String.ends_with?(String.trim_trailing(b), "]}")
            end),
        "checked" => length(bodies)
      },
      "throughput_per_s" => Float.round(length(ok) / max(wall_ms / 1000, 0.001), 1),
      "wall_ms" => wall_ms
    }
  end

  defp drop_first_per_connection(results) do
    results
    |> Enum.chunk_every(@per_connection)
    |> Enum.flat_map(fn
      [_first | rest] -> rest
      [] -> []
    end)
  end

  defp items_per_page(results) do
    items =
      for {:ok, 200, body, _micros} <- results do
        body |> String.split(~s("ref":)) |> length() |> Kernel.-(1)
      end

    %{
      "stats" => LoadSupport.stats(items),
      "distribution" => items |> Enum.frequencies() |> Map.new(fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp print(report) do
    for {label, key} <- [
          {"cold", "cold"},
          {"keep-alive", "keepalive"},
          {"keep-alive steady", "keepalive_steady"}
        ] do
      phase = report[key]

      IO.puts("#{label}: #{phase["ok"]}/#{phase["requests"]} ok, " <>
                "#{phase["throughput_per_s"]} req/s, #{phase["wall_ms"]} ms wall")
    end

    IO.puts("")
    IO.puts(LoadSupport.header())

    IO.puts(LoadSupport.row("cold", report["cold"]["response_ms"], " ms"))
    IO.puts(LoadSupport.row("keep-alive", report["keepalive"]["response_ms"], " ms"))
    IO.puts(LoadSupport.row("steady", report["keepalive_steady"]["response_ms"], " ms"))
    IO.puts(LoadSupport.row("items/page", report["items_per_page"]["stats"], ""))

    cold = report["cold"]
    ka = report["keepalive"]

    IO.puts("\nresponse size (cold): #{inspect(cold["bytes"]["distinct"])}  " <>
              "uniform: #{cold["bytes"]["uniform"]}")

    IO.puts("response size (keep-alive): #{inspect(ka["bytes"]["distinct"])}  " <>
              "uniform: #{ka["bytes"]["uniform"]}")

    IO.puts("padded: #{cold["padding"]["all_padded"]}/#{ka["padding"]["all_padded"]}  " <>
              "well-formed: #{cold["padding"]["all_shaped"]}/#{ka["padding"]["all_shaped"]}  " <>
              "(#{cold["padding"]["checked"] + ka["padding"]["checked"]} bodies checked)")

    IO.puts("items per page: #{inspect(report["items_per_page"]["distribution"])}")
    IO.puts("memory: end #{Float.round(report["memory"]["end_bytes"] / 1_048_576, 1)} MiB")
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end
end

opts = LoadSupport.opts()
FeedLoad.run(opts)
System.halt(0)
