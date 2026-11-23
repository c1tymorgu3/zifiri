# Erase latency and the on-disk canary proof.
#
# What this measures: how long `Zifiri.Vanish.erase_many/1` — one `DELETE` per
# table, `wal_checkpoint(TRUNCATE)`, `VACUUM`, `wal_checkpoint(TRUNCATE)` —
# takes for N listings, and whether the body bytes are actually gone from the
# database file and the `-wal` when it returns.
#
# The proof is a canary, not an assumption:
#
#   1. every listing carries a unique random marker in its body (inside the
#      envelope) and a second one in its plaintext title;
#   2. the script scans the database file and the `-wal` *before* the erase and
#      prints how many times each marker is there — a scan that finds nothing
#      before the delete would prove nothing after it;
#   3. it times `erase_many/1`, then scans again, and keeps scanning until the
#      markers are gone or the threshold passes, so the number reported is
#      "time until the bytes are absent", not "time until the call returned".
#
# Threshold (docs/spec.md §Deletion, docs/measurements.md): the bytes are gone within 5 000 ms.
#
#   MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs
#   MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --listings 50 --threshold-ms 5000
#   MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --help
#
# The database is deleted before the script exits, pass or fail.

Code.require_file("measure_support.exs", __DIR__)
Code.require_file(Path.expand("../load/load_support.exs", __DIR__))

defmodule EraseLatency do
  @moduledoc false

  alias Zifiri.{Envelope, Listings, Owner, Repo, Vanish}
  alias Zifiri.Pow.Challenge

  @bits 8
  @port 4012
  @body_bytes 256

  @help """
  erase_latency.exs — erase latency and the on-disk canary proof.

  Usage:
    MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs [options]

  Options:
    --listings N       how many listings to write and erase (default 50)
    --filler N         extra listings (no canary) so the file has real size,
                       because VACUUM cost follows page count (default 0)
    --threshold-ms N   the claim to test (default 5000)
    --trace            print every rescan with its elapsed time
    --help, -h         print this text and exit

  What it does:
    1. writes N listings, each with a unique canary in the body and in the title,
       plus --filler plain listings and a checkpoint, so the erase meets a file
       the size of a real one rather than an empty database;
    2. scans the database file and the -wal for those canaries (must be found);
    3. times Zifiri.Vanish.erase_many/1 over the N owner hashes;
    4. scans again, and keeps scanning until the canaries are gone or the
       threshold passes — that is the "time to absence".

  Output: the erase time, the scan counts before/after, a JSON report in
  scripts/measure/results/, and a GEÇTİ/KALDI verdict against
  "canaries absent within --threshold-ms".
  """

  def main(argv) do
    if MeasureSupport.help?(argv), do: MeasureSupport.print_help(@help)

    count = positive(MeasureSupport.int_arg(argv, "listings", 50), 50)
    filler = non_negative(MeasureSupport.int_arg(argv, "filler", 0))
    threshold_ms = positive(MeasureSupport.int_arg(argv, "threshold-ms", 5_000), 5_000)
    trace? = "--trace" in argv

    IO.puts("erase_latency: #{count} listings, #{filler} filler, threshold #{threshold_ms} ms")

    db = LoadSupport.boot(@port)
    wal = db <> "-wal"

    try do
      {written, write_ms} = write_listings(count)

      # A checkpoint after the filler moves every page into the main file, so
      # the scan before the erase sees the canaries in both places — the file
      # and the WAL — and the erase meets a compacted database, not a WAL.
      if filler > 0 do
        LoadSupport.seed_listings(filler)
        Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      end

      rows_before = LoadSupport.listing_count()

      body_before = scan(db, wal, Enum.map(written, & &1.body_canary))
      title_before = scan(db, wal, Enum.map(written, & &1.title_canary))

      IO.puts("\nwritten        #{rows_before} rows in #{write_ms} ms")
      IO.puts("db file        #{MeasureSupport.file_size(db)} bytes")
      IO.puts("wal file       #{MeasureSupport.file_size(wal)} bytes")
      IO.puts("canary before  body #{inspect(body_before)}  title #{inspect(title_before)}")

      if body_before.total == 0 or title_before.total == 0 do
        IO.puts(
          "\nthe canary was not on disk before the erase — the after-scan would prove nothing."
        )

        System.halt(2)
      end

      hashes = Enum.map(written, & &1.owner_hash)
      started = System.monotonic_time(:microsecond)
      result = Vanish.erase_many(hashes)
      erase_ms = (System.monotonic_time(:microsecond) - started) / 1000

      {absence_ms, post_scan} = wait_for_absence(db, wal, written, started, threshold_ms, trace?)

      rows_after = LoadSupport.listing_count()
      freelist = scalar("PRAGMA freelist_count")
      pages = scalar("PRAGMA page_count")

      IO.puts("\nerase_many     #{result |> inspect()} in #{Float.round(erase_ms, 1)} ms")
      IO.puts("canary after   body #{inspect(post_scan.body)}  title #{inspect(post_scan.title)}")

      IO.puts(
        "time to absent #{fmt_ms(absence_ms)} (from before erase_many to the scan that found nothing)"
      )

      IO.puts("rows after     #{rows_after} (expected #{filler}: the canaried rows are gone)")
      IO.puts("freelist       #{freelist} pages   page_count #{pages}")
      IO.puts("db file        #{MeasureSupport.file_size(db)} bytes")
      IO.puts("wal file       #{MeasureSupport.file_size(wal)} bytes")

      passed? =
        match?({:ok, _}, result) and rows_after == filler and post_scan.body.total == 0 and
          post_scan.title.total == 0 and absence_ms <= threshold_ms

      path =
        MeasureSupport.write_report(%{
          "kind" => "erase-latency",
          "measured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "host" => to_string(:erlang.system_info(:otp_release)),
          "listings" => count,
          "filler" => filler,
          "rows_before" => rows_before,
          "write_ms" => write_ms,
          "erase_result" => inspect(result),
          "erase_ms" => Float.round(erase_ms, 1),
          "absence_ms" => absence_ms,
          "threshold_ms" => threshold_ms,
          "canary_before" => %{
            "body" => body_before,
            "title" => title_before
          },
          "canary_after" => %{
            "body" => post_scan.body,
            "title" => post_scan.title
          },
          "rows_after" => rows_after,
          "freelist_pages" => freelist,
          "page_count" => pages,
          "db_bytes" => MeasureSupport.file_size(db),
          "wal_bytes" => MeasureSupport.file_size(wal),
          "passed" => passed?,
          "database" => db
        })

      IO.puts("report         #{path}")

      MeasureSupport.verdict("canaries absent within #{threshold_ms} ms", passed?)
      |> case do
        true -> :ok
        false -> System.halt(1)
      end
    after
      LoadSupport.cleanup(db)
      IO.puts("database deleted: #{db}")
    end
  end

  # `MeasureSupport.int_arg/3` comes from a required file, so its spec is not
  # visible to the type checker; this narrows the value back to a positive
  # integer where it is used.
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  # -- writing ----------------------------------------------------------------

  defp write_listings(count) do
    started = System.monotonic_time(:microsecond)

    written =
      Enum.map(1..count, fn i ->
        token = :crypto.strong_rand_bytes(32)
        owner_hash = Owner.hash(token)
        body_canary = MeasureSupport.canary()
        title_canary = MeasureSupport.canary()

        # 256 B bucket: the canary, a filler, and the envelope's own framing.
        filler = max(@body_bytes - 4 - byte_size(body_canary) - 1, 1)
        {:ok, envelope, 256} = Envelope.encode(body_canary <> String.duplicate("x", filler))
        payload_hash = :crypto.hash(:sha256, envelope)

        {:ok, challenge} = Challenge.issue(owner_hash, payload_hash, bits: @bits)
        nonce = Challenge.solve(challenge, payload_hash)

        {:ok, listing} =
          Listings.create(%{
            owner_token: token,
            body: envelope,
            title: title_canary,
            price_cents: 100,
            currency: "USD",
            category: "measure",
            challenge_id: challenge.id,
            nonce: nonce,
            bits: @bits
          })

        %{
          ref: listing.id,
          owner_hash: owner_hash,
          body_canary: body_canary,
          title_canary: title_canary,
          index: i
        }
      end)

    {written, div(System.monotonic_time(:microsecond) - started, 1000)}
  end

  # -- scanning ---------------------------------------------------------------

  defp scan(db, wal, canaries) do
    # One read per file, not one per canary: the scan has to be cheaper than
    # the erase it is timing, or the number reported is the scanner's.
    db_bytes = read_or_empty(db)
    wal_bytes = read_or_empty(wal)
    db_counts = Enum.map(canaries, &MeasureSupport.count_in_binary(db_bytes, &1))
    wal_counts = Enum.map(canaries, &MeasureSupport.count_in_binary(wal_bytes, &1))

    %{
      db: Enum.sum(db_counts),
      wal: Enum.sum(wal_counts),
      total: Enum.sum(db_counts) + Enum.sum(wal_counts),
      canaries: length(canaries),
      found_in_db: Enum.count(db_counts, &(&1 > 0)),
      found_in_wal: Enum.count(wal_counts, &(&1 > 0))
    }
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> <<>>
    end
  end

  # The claim is about the bytes being absent, not about the call returning, so
  # the clock that counts is the one that stops when a rescan finds nothing. It
  # starts before `erase_many/1` — the threshold covers the whole operation.
  defp wait_for_absence(db, wal, written, started_us, threshold_ms, trace?) do
    bodies = Enum.map(written, & &1.body_canary)
    titles = Enum.map(written, & &1.title_canary)
    deadline_us = started_us + threshold_ms * 1000

    loop(db, wal, bodies, titles, started_us, deadline_us, trace?)
  end

  defp loop(db, wal, bodies, titles, started_us, deadline_us, trace?) do
    # The clock stops when a scan *starts*, not when it ends: the scan's own
    # cost (a 5 MB file read twice) is the measurement's, not the erase's.
    scan_started_us = System.monotonic_time(:microsecond)
    body = scan(db, wal, bodies)
    title = scan(db, wal, titles)
    scan_ms = div(System.monotonic_time(:microsecond) - scan_started_us, 1000)
    elapsed_ms = div(scan_started_us - started_us, 1000)

    if trace? do
      IO.puts(
        "  trace t=#{elapsed_ms}ms body=#{body.total} title=#{title.total} " <>
          "db=#{body.db} wal=#{body.wal} size=#{MeasureSupport.file_size(db)} scan=#{scan_ms}ms"
      )
    end

    cond do
      body.total == 0 and title.total == 0 ->
        {elapsed_ms, %{body: body, title: title}}

      System.monotonic_time(:microsecond) >= deadline_us ->
        {elapsed_ms, %{body: body, title: title}}

      true ->
        Process.sleep(100)
        loop(db, wal, bodies, titles, started_us, deadline_us, trace?)
    end
  end

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp fmt_ms(ms), do: "#{ms} ms"
end

EraseLatency.main(System.argv())
