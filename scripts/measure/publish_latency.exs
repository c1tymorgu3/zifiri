# Publish latency under 200 simultaneous writes.
#
# What this measures: the wall time of `POST /api/listings` — TCP connect,
# proof check, envelope check, insert, response — for 200 writers that start at
# the same moment, each with its own owner token and its own 8-bit proof.
#
# 8 bits, not 20: this is a server-side latency measurement, not a client-side
# PoW measurement. The real 20-bit cost is what `pow_browser.js` measures.
# Pinning the difficulty keeps the server-side number comparable between runs.
#
# Threshold (README claim / docs/spec.md §Measurable targets): p95 < 2 000 ms.
#
#   MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs
#   MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs --writes 50 --concurrency 50
#   MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs --help
#
# The script writes its own database under `_build/test/`, prints the numbers,
# writes a JSON report to `scripts/measure/results/`, and deletes the database
# before it exits. Exit code is 1 when the threshold is missed.

Code.require_file("measure_support.exs", __DIR__)
Code.require_file(Path.expand("../load/load_support.exs", __DIR__))

defmodule PublishLatency do
  @moduledoc false

  alias Zifiri.{Envelope, Owner}
  alias Zifiri.Pow.Challenge

  @threshold_ms 2_000
  @bits 8
  @port 4011
  @body_bytes 512

  @help """
  publish_latency.exs — publish latency for N simultaneous writes.

  Usage:
    MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs [options]

  Options:
    --writes N        number of listings to publish (default 200)
    --concurrency N   how many run at once (default = --writes)
    --warmup N        warm-up writes, discarded (default 10)
    --help, -h        print this text and exit

  Output: p50/p95/p99 of POST /api/listings in milliseconds, a JSON report in
  scripts/measure/results/, and a PASS/FAIL verdict against p95 < 2 000 ms.
  The measurement database is deleted on exit, pass or fail.
  """

  def main(argv) do
    if MeasureSupport.help?(argv), do: MeasureSupport.print_help(@help)

    writes = positive(MeasureSupport.int_arg(argv, "writes", 200), 200)
    concurrency = positive(MeasureSupport.int_arg(argv, "concurrency", writes), writes)
    warmup = non_negative(MeasureSupport.int_arg(argv, "warmup", 10))

    IO.puts("publish_latency: #{writes} writes, concurrency #{concurrency}, bits #{@bits}")

    db = LoadSupport.boot(@port)

    try do
      LoadSupport.clear_listings()

      if warmup > 0 do
        IO.puts("warm-up: #{warmup} writes (discarded)")
        run(writes: warmup, concurrency: min(warmup, concurrency))
        LoadSupport.clear_listings()
      end

      started = MeasureSupport.now_ms()
      results = run(writes: writes, concurrency: concurrency)
      elapsed = MeasureSupport.now_ms() - started

      report(db, results, elapsed, writes, concurrency)
    after
      LoadSupport.cleanup(db)
      IO.puts("database deleted: #{db}")
    end
  end

  # `MeasureSupport.int_arg/3` comes from a required file, so its spec is not
  # visible to the type checker; these guards narrow the value back to a
  # positive integer where it is used.
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp run(writes: writes, concurrency: concurrency) do
    1..writes
    |> Task.async_stream(
      fn _i -> publish_one() end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: 120_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}, 0, 0}
    end)
  end

  defp publish_one do
    token = :crypto.strong_rand_bytes(32)
    payload = String.duplicate("p", @body_bytes)
    {:ok, envelope, _bucket} = Envelope.encode(payload)
    payload_hash = :crypto.hash(:sha256, envelope)

    {:ok, challenge} = Challenge.issue(Owner.hash(token), payload_hash, bits: @bits)
    nonce = Challenge.solve(challenge, payload_hash)

    body =
      :json.encode(%{
        "envelope" => Base.encode64(envelope),
        "title" => "measure",
        "price_cents" => 100,
        "currency" => "USD",
        "category" => "measure",
        "challenge_id" => challenge.id,
        "nonce" => nonce,
        "bits" => challenge.bits,
        "owner_token" => Base.encode64(token)
      })
      |> IO.iodata_to_binary()

    {micros, result} =
      :timer.tc(fn -> LoadSupport.post_json(@port, "/api/listings", body) end)

    case result do
      {:ok, 201, response, _} -> {:ok, response, micros, byte_size(response)}
      {:ok, status, response, _} -> {:error, {:status, status}, micros, byte_size(response)}
      {:error, reason, _} -> {:error, reason, micros, 0}
    end
  end

  defp report(db, results, elapsed, writes, concurrency) do
    ok = for {:ok, response, micros, bytes} <- results, do: {response, micros, bytes}
    failed = Enum.reject(results, &match?({:ok, _, _, _}, &1))

    latencies = Enum.map(ok, fn {_response, micros, _bytes} -> micros / 1000 end)
    stats = LoadSupport.stats(latencies)
    sizes = ok |> Enum.map(fn {_r, _m, bytes} -> bytes end) |> Enum.uniq() |> Enum.sort()
    rows = LoadSupport.listing_count()

    p95 = if stats, do: stats["p95"], else: nil
    passed? = is_map(stats) and p95 < @threshold_ms and failed == [] and rows == writes

    IO.puts("\n#{LoadSupport.header()} (ms)")

    if stats do
      IO.puts(LoadSupport.row("write_ms", stats, " ms"))
    else
      IO.puts(LoadSupport.row("write_ms", nil, "ms"))
    end

    IO.puts("\ncreated       #{length(ok)}/#{writes} (HTTP 201)")
    IO.puts("failed        #{length(failed)}")
    IO.puts("rows in table #{rows}")
    IO.puts("response size #{inspect(sizes)} bytes (fixed-size check)")
    IO.puts("wall clock    #{elapsed} ms for the whole batch")
    IO.puts("threshold     p95 < #{@threshold_ms} ms")

    if failed != [], do: IO.puts("failures      #{inspect(Enum.take(failed, 3))}")

    path =
      MeasureSupport.write_report(%{
        "kind" => "publish-latency",
        "measured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "host" => System.schedulers_online() |> then(&"#{System.otp_release()}/#{&1} schedulers"),
        "writes" => writes,
        "concurrency" => concurrency,
        "bits" => @bits,
        "body_bytes" => @body_bytes,
        "stats_ms" => stats,
        "created" => length(ok),
        "failed" => length(failed),
        "rows" => rows,
        "response_sizes" => sizes,
        "wall_ms" => elapsed,
        "threshold_ms" => @threshold_ms,
        "passed" => passed?,
        "database" => db
      })

    IO.puts("report        #{path}")

    MeasureSupport.verdict("publish p95 < #{@threshold_ms} ms", passed?)
    |> case do
      true -> :ok
      false -> System.halt(1)
    end
  end
end

PublishLatency.main(System.argv())
