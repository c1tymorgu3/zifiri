# Publish-path load measurement (plan §16: "yayın gecikmesi p95").
#
#   MIX_ENV=test mix run --no-start scripts/load/publish_load.exs
#
# Every write is a real one: a padded envelope from `Zifiri.Envelope`, a
# challenge issued by the real `Zifiri.Pow.Challenge` store and bound to that
# owner and those exact bytes, a nonce solved by `Zifiri.Pow` at `LOAD_BITS`
# (default 8), and a real `POST /api/listings` through the real endpoint, router,
# validation, proof redemption and insert. Nothing is stubbed.
#
# The one shortcut is where the challenge is *issued*: in-process, at eight bits,
# instead of `POST /api/pow`. That endpoint issues at the production difficulty
# (`Pow.difficulty/1`: 20 bits plus queue pressure), which would turn 500 writes
# into ~500 million hashes and hours of wall clock. Challenge issuance is not
# part of the latency being measured; `Challenge.redeem/5` — the server side of
# the proof — is exercised in full either way. `test/support/forum_helpers.ex`
# pins four bits for exactly this reason.
#
# Two numbers, because the write path has two:
#
#   * write (ms)    — POST start to `201 created`: envelope decode, metadata
#                     validation, proof redemption, INSERT, padded reply
#   * visible (ms)  — POST completion until `GET /api/listings/:ref` answers
#                     200, sampled over 30 refs. A write that is not readable is
#                     not published, and this is the only honest way to say so.
#
# Results land in scripts/load/results/*.json and on stdout as a table.

Code.require_file("load_support.exs", __DIR__)

defmodule PublishLoad do
  @moduledoc false

  alias Zifiri.{Envelope, Owner}
  alias Zifiri.Pow.Challenge

  @visible_every 10

  def run(opts) do
    db = LoadSupport.boot(opts.port)
    LoadSupport.start_http()

    IO.puts("zifiri write load — #{opts.writes} concurrent POST /api/listings, " <>
              "pow bits #{opts.bits}")

    IO.puts("database: #{db}\n")

    plan = plan(opts.writes)
    warmup(opts)
    memory_before = :erlang.memory(:total)

    wall_started = System.monotonic_time(:microsecond)

    results =
      plan
      |> Task.async_stream(&write(&1, opts),
        max_concurrency: opts.concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{status: nil, micros: 0, ref: nil, error: inspect({:exit, reason})}
      end)

    wall_ms = div(System.monotonic_time(:microsecond) - wall_started, 1000)
    memory_after = :erlang.memory(:total)

    report = build_report(opts, db, results, wall_ms, memory_before, memory_after)
    print(report)

    path = LoadSupport.write_report(report)
    IO.puts("\nJSON: #{path}")

    LoadSupport.cleanup(db)
    IO.puts("load database deleted: #{db}")
  end

  # -- writes ---------------------------------------------------------------

  defp plan(n) do
    for i <- 1..n do
      bucket = target_bucket(i)
      {:ok, envelope, ^bucket} = Envelope.encode(payload(i, bucket))

      %{
        index: i,
        token: :crypto.strong_rand_bytes(32),
        envelope: envelope,
        bucket: bucket,
        title: "yük testi #{i}",
        price: i * 100
      }
    end
  end

  # 70% 256 B, 20% 1 KB, 10% 4 KB — the three description buckets a real listing
  # uses.
  defp target_bucket(i) do
    case rem(i, 10) do
      0 -> 4096
      n when n in 1..2 -> 1024
      _ -> 256
    end
  end

  defp payload(i, bucket) do
    prefix = "yük testi açıklaması #{i} "
    filler = max(bucket - 4 - byte_size(prefix) - 1, 1)
    prefix <> String.duplicate("x", filler)
  end

  defp warmup(opts) do
    plan(10)
    |> Enum.map(&write(&1, opts))
    |> Enum.each(fn %{status: status} -> if status != 201, do: IO.puts("warm-up status #{status}") end)

    # The warm-up must not inflate the row count or the latency samples.
    deleted = LoadSupport.clear_listings()
    LoadSupport.reset_samples()
    IO.puts("warm-up: 10 writes, #{deleted} rows created and deleted\n")
    :ok
  end

  defp write(item, opts) do
    payload_hash = :crypto.hash(:sha256, item.envelope)
    {:ok, challenge} = Challenge.issue(Owner.hash(item.token), payload_hash, bits: opts.bits)
    nonce = Challenge.solve(challenge, payload_hash)

    body =
      LoadSupport.encode(%{
        "envelope" => Base.encode64(item.envelope),
        "title" => item.title,
        "price_cents" => item.price,
        "currency" => "USD",
        "category" => "test",
        "challenge_id" => challenge.id,
        "nonce" => nonce,
        "bits" => challenge.bits,
        "owner_token" => Base.encode64(item.token)
      })

    case LoadSupport.post_json(opts.port, "/api/listings", body) do
      {:ok, status, response, micros} ->
        ref = ref_of(response)
        visible_us = read_back(item, ref, status, opts.port)

        %{
          status: status,
          micros: micros,
          ref: ref,
          visible_us: visible_us,
          error: nil,
          bytes: byte_size(response)
        }

      {:error, reason, micros} ->
        %{status: nil, micros: micros, ref: nil, visible_us: nil, error: inspect(reason), bytes: 0}
    end
  end

  # A write that cannot be read back was not published. One in ten writes is
  # followed immediately by `GET /api/listings/:ref`, in the same process, so
  # the number is the row's own latency and not the sampling loop's.
  defp read_back(%{index: index}, _ref, _status, _port) when rem(index, @visible_every) != 0,
    do: nil

  defp read_back(_item, nil, _status, _port), do: :timeout

  defp read_back(_item, ref, 201, port) do
    started = System.monotonic_time(:microsecond)
    poll(ref, port, started, started + 5_000_000)
  end

  defp read_back(_item, _ref, _status, _port), do: :timeout

  defp poll(ref, port, started, deadline) do
    case LoadSupport.get_json(port, "/api/listings/#{ref}") do
      {:ok, 200, _body, _micros} ->
        System.monotonic_time(:microsecond) - started

      _ ->
        if System.monotonic_time(:microsecond) >= deadline do
          :timeout
        else
          Process.sleep(2)
          poll(ref, port, started, deadline)
        end
    end
  end

  defp ref_of(response) do
    case Regex.run(~r/"ref":(\d+)/, response) do
      [_, ref] -> String.to_integer(ref)
      _ -> nil
    end
  end

  # -- report ---------------------------------------------------------------

  defp build_report(opts, db, results, wall_ms, memory_before, memory_after) do
    created = Enum.filter(results, &(&1.status == 201))

    refused =
      results
      |> Enum.reject(&(&1.status in [201, nil]))
      |> Enum.frequencies_by(&to_string(&1.status))
      |> Map.new()

    write_ms = results |> Enum.map(fn r -> Float.round(r.micros / 1000, 2) end)

    sampled = results |> Enum.map(& &1.visible_us) |> Enum.reject(&is_nil/1)

    visible_ms =
      sampled
      |> Enum.reject(&(&1 == :timeout))
      |> Enum.map(fn us -> Float.round(us / 1000, 2) end)

    sizes = results |> Enum.map(& &1.bytes) |> Enum.frequencies() |> Enum.sort()

    %{
      "kind" => "publish",
      "measured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "host" => hostname(),
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "endpoint" => "POST /api/listings",
      "config" => %{
        "writes" => opts.writes,
        "concurrency" => opts.concurrency,
        "pow_bits" => opts.bits,
        "database" => db
      },
      "created" => length(created),
      "refused" => refused,
      "transport_errors" => Enum.count(results, & &1.error),
      "rows" => LoadSupport.listing_count(),
      "write_ms" => LoadSupport.stats(write_ms),
      "visible_ms" => LoadSupport.stats(visible_ms),
      "visible" => %{
        "sampled" => length(sampled),
        "answered" => length(visible_ms),
        "timed_out" => Enum.count(sampled, &(&1 == :timeout))
      },
      "response_bytes" => %{
        "distinct" => Map.new(sizes, fn {size, count} -> {to_string(size), count} end),
        "uniform" => length(sizes) == 1
      },
      "throughput_per_s" => Float.round(length(created) / max(wall_ms / 1000, 0.001), 1),
      "wall_ms" => wall_ms,
      "memory" => %{
        "before_bytes" => memory_before,
        "after_writes_bytes" => memory_after,
        "end_bytes" => :erlang.memory(:total)
      }
    }
  end

  defp print(report) do
    IO.puts("created (201): #{report["created"]}  refused: #{inspect(report["refused"])}  " <>
              "transport errors: #{report["transport_errors"]}")

    IO.puts("rows in listings: #{report["rows"]}  wall: #{report["wall_ms"]} ms  " <>
              "throughput: #{report["throughput_per_s"]} writes/s")

    IO.puts("read-back: #{report["visible"]["answered"]}/#{report["visible"]["sampled"]} answered, " <>
              "#{report["visible"]["timed_out"]} timed out\n")

    IO.puts(LoadSupport.header())
    IO.puts(LoadSupport.row("write", report["write_ms"], " ms"))
    IO.puts(LoadSupport.row("visible", report["visible_ms"], " ms"))

    bytes = report["response_bytes"]
    IO.puts("\nresponse size: #{inspect(bytes["distinct"])}  uniform: #{bytes["uniform"]}")

    mem = report["memory"]

    IO.puts("memory: before #{mib(mem["before_bytes"])} MiB, after writes " <>
              "#{mib(mem["after_writes_bytes"])} MiB, end #{mib(mem["end_bytes"])} MiB")
  end

  defp mib(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end
end

opts = LoadSupport.opts()
PublishLoad.run(opts)
System.halt(0)
