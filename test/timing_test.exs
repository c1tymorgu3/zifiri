defmodule Zifiri.TimingTest do
  @moduledoc """
  `docs/spec.md` §Two modes, silent mode: the drain shuffles the batch, and the
  order must not say which one is the real message.

  This measures the shuffle itself, on a synthetic 120-entry bucket filled by
  hand (1 real + 119 `Zifiri.Chat.Decoy` frames). The room path publishes no
  decoys and its batch is `k`, the number of writers (`docs/claims.md` C-50);
  nothing here claims the room produces a 120-entry batch — what is measured is
  the drain's order, given n entries.

  Two things are measured:

    1. **Is the order random** — the same 120 messages are put into the bucket in
       the same order and drained 10 times; most of the 10 drains must be
       different permutations, and the real message's position must not stay in
       the same place every time.
    2. **Is the position uniform** — 1 real + 119 decoys, drained 1000 times; the
       real message's 0-based position must be uniform over 0..119. A uniform
       distribution has mean 59.5 and standard deviation `sqrt((n²-1)/12) = 34.64`.

  ## Thresholds and why

  | measure | expected | threshold | why |
  |---|---|---|---|
  | distinct permutations (10) | ~10 | ≥ 9 | with 120! permutations two collisions are not expected |
  | mean position | 59.5 | \\|x̄−59.5\\| < 6 | SE = 34.64/√1000 ≈ 1.10; 6 ≈ 5.4 SE |
  | standard deviation | 34.64 | 31 ≤ s ≤ 38 | the SE of s ≈ 0.77; range ±4 SE |
  | chi-square (12 bins, df=11) | 11 | < 31.26 | χ²(11, p=0.001) critical value |
  | emptiest bin | 83.3 | > 40 | the SD of a bin count ≈ 8.7; 40 ≈ 5σ below |

  The example threshold in the task was `|mean−60| < 12`; 12 is 11 SE and would
  let even a clearly biased shuffler through, so it was pulled in to 6. The seed
  is fixed, so this test is deterministic: same run, same numbers; the thresholds
  still sit above the measurement with a comfortable margin.

  ## Determinism and isolation

  `:rand` is process-local; `setup` seeds in every test process. Because
  `Zifiri.Bucket` and `Zifiri.Chat.Decoy` share a single cross-process ETS table,
  this module is `async: false`.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Bucket
  alias Zifiri.Chat.{Decoy, Message}

  @seed {20_261_122, 59, 120}
  @room "chat:lobby"
  @epoch :binary.copy(<<0xC3>>, 16)
  @total 120
  @trials 1000
  @bucket_ms 600_000
  @at 1_766_000_000_000 + div(@bucket_ms, 2)

  @expected_mean 59.5
  @expected_sd :math.sqrt((@total * @total - 1) / 12)

  setup do
    :rand.seed(:exsss, @seed)
    Bucket.reset()
    on_exit(fn -> Bucket.reset() end)

    real = real_message()
    decoys = Decoy.fill(@total, real: 1, epoch: @epoch, room: @room, at: @at)
    batch = [real | decoys]

    assert length(batch) == @total
    assert Enum.uniq_by(batch, & &1.id) |> length() == @total

    %{batch: batch}
  end

  test "the order changes when the same input is drained 10 times", %{batch: batch} do
    ids = Enum.map(batch, & &1.id)

    orders =
      for _ <- 1..10 do
        fill(batch)
        %{items: items, size: size} = Bucket.drain()
        assert size == @total
        Enum.map(items, & &1.id)
      end

    # Every drain carries the whole input, lossless and without duplicates.
    for order <- orders do
      assert Enum.sort(order) == Enum.sort(ids)
    end

    distinct_orders = orders |> Enum.uniq() |> length()
    positions = Enum.map(orders, fn order -> Enum.find_index(order, &(&1 == :real)) end)
    distinct_positions = positions |> Enum.uniq() |> length()

    IO.puts(
      "[timing] 10 drains: #{distinct_orders} distinct permutations, " <>
        "#{distinct_positions} distinct real-positions #{inspect(positions)}"
    )

    assert distinct_orders >= 9,
           "only #{distinct_orders} distinct permutations in 10 drains"

    assert distinct_positions >= 7,
           "the real message was in only #{distinct_positions} distinct positions in 10 drains"

    # None of them is the input order: the shuffle really works, it is not an
    # `Enum.reverse/1` that has been named "shuffle".
    refute Enum.any?(orders, &(&1 == ids))
  end

  test "the real message's position is uniform over 0..119 (1000 samples)", %{batch: batch} do
    positions =
      for _ <- 1..@trials do
        fill(batch)
        %{items: items, size: @total} = Bucket.drain()
        Enum.find_index(items, &(&1.id == :real))
      end

    assert length(positions) == @trials
    assert Enum.all?(positions, &(&1 >= 0 and &1 < @total))

    mean = Enum.sum(positions) / @trials
    sd = :math.sqrt(Enum.sum(Enum.map(positions, fn p -> (p - mean) ** 2 end)) / @trials)

    # 12 bins × 10 positions; each bin is a tenth of the 0..119 range.
    bins = Enum.frequencies_by(positions, &div(&1, 10))
    counts = for index <- 0..11, do: Map.get(bins, index, 0)
    expected = @trials / 12

    chi2 =
      counts
      |> Enum.map(fn count -> (count - expected) ** 2 / expected end)
      |> Enum.sum()

    critical = chi2_critical(11, 3.0902)

    IO.puts(
      "[timing] 1000 samples: mean=#{Float.round(mean, 2)} " <>
        "(expected #{@expected_mean}), sd=#{Float.round(sd, 2)} " <>
        "(expected #{Float.round(@expected_sd, 2)})"
    )

    IO.puts(
      "[timing] chi-square(12 bins, df=11)=#{Float.round(chi2, 2)}, " <>
        "critical(p=0.001)=#{Float.round(critical, 2)}, bin counts=[#{Enum.join(counts, ", ")}]"
    )

    assert abs(mean - @expected_mean) < 6.0,
           "mean #{Float.round(mean, 2)}; expected #{@expected_mean} ± 6"

    assert sd > 31.0 and sd < 38.0,
           "standard deviation #{Float.round(sd, 2)}; expected #{Float.round(@expected_sd, 2)} (31..38)"

    assert chi2 < critical,
           "chi-square #{Float.round(chi2, 2)} > critical #{Float.round(critical, 2)}"

    assert Enum.min(counts) > 40,
           "emptiest bin #{Enum.min(counts)}; expected ≈ #{Float.round(expected, 1)}"
  end

  test "an empty bucket drains empty, with no loss and no duplicate" do
    %{items: [], size: 0} = Bucket.drain()
    assert Bucket.size() == 0
  end

  ## Helpers

  defp fill(batch) do
    Bucket.reset()
    Enum.each(batch, &Bucket.add/1)
    assert Bucket.size() == @total
  end

  # The single real message: the 4 KB frame the real client signs. Its id is
  # `:real`; the decoys' ids are integers. This label is for the test's own
  # measurement only — it never appears on the wire (`Message.to_json/1` carries
  # `id`, but id is a server sequence number and the decoys carry the same field).
  defp real_message do
    {pubkey, priv} = :crypto.generate_key(:eddsa, :ed25519)
    payload = "Shall we meet tomorrow at nine, and grab a coffee."
    padding = 4096 - 4 - byte_size(payload)
    body = <<byte_size(payload)::unsigned-big-32, payload::binary, 0::size(padding)-unit(8)>>
    ctr = 1

    sig =
      :crypto.sign(
        :eddsa,
        :none,
        Message.signing_input(@room, @epoch, ctr, body),
        [priv, :ed25519]
      )

    %{id: :real, pubkey: pubkey, sig: sig, body: body, bucket: 4096, ctr: ctr, at: @at}
  end

  defp chi2_critical(df, z) do
    df * :math.pow(1 - 2 / (9 * df) + z * :math.sqrt(2 / (9 * df)), 3)
  end
end
