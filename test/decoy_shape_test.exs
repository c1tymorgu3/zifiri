defmodule Zifiri.DecoyShapeTest do
  @moduledoc """
  C-04 shape proof for the 1:1 decoy: 70 decoys and 50 real rows, side by side.

  C-04 is deliberately narrow now that the room path publishes no decoys
  (`docs/claims.md` C-50): a decoy is the same *frame* as a real 1:1 envelope —
  4096 bytes, a valid length prefix, a zero tail, a random body — and it exists
  on the 1:1 plane only. This file builds mailbox rows and nothing else.

  The test does not ask the module which rows are decoys — it built both sets
  itself, so it knows. It then measures the published frames:

    * all 120 envelopes are exactly `Zifiri.Mailbox.envelope_bytes/0` bytes and
      every one of them is a valid frame: `Zifiri.Envelope.decode/1` answers
      `{:ok, payload, 4096}` for a decoy exactly as it does for a real row (a
      decoy built from raw noise would fail `:bad_length` almost always);
    * decoy payloads are random bytes and vary in length the way real messages
      do, while the real payload is an ordinary sentence;
    * ids are 16 random bytes with a uniform successive-difference
      distribution (a counter scores ~1785 on the same chi-square; random ids
      score ~15);
    * `Map.keys/1` is identical on both sets, and both carry the same lifetime.

  What this does **not** claim: that the length prefix hides anything. It is
  plaintext by design (`Zifiri.Envelope`), so the byte count of a body is
  visible to whoever holds the frame. C-04 names that limit.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Envelope
  alias Zifiri.Mailbox
  alias Zifiri.Mailbox.Decoy

  @decoys 70
  @real 50
  @frame_bytes 4096

  # 2^128: ids are 16 random bytes interpreted as one unsigned integer.
  @id_space 340_282_366_920_938_463_463_374_607_431_768_211_456

  setup do
    :rand.seed(:exsss, {61, 62, 63})
    ttl = Mailbox.ttl_ms()

    decoys = for _ <- 1..@decoys, do: Decoy.build(ttl_ms: ttl, rand: &:rand.bytes/1)
    reals = for i <- 1..@real, do: real_row(ttl, i)

    %{decoys: decoys, reals: reals}
  end

  test "(a) every frame, decoy and real, is envelope_bytes/0", %{decoys: decoys, reals: reals} do
    assert length(decoys) == @decoys
    assert length(reals) == @real
    assert @frame_bytes == Mailbox.envelope_bytes()

    for row <- decoys ++ reals do
      assert byte_size(row.envelope) == @frame_bytes
    end
  end

  test "(b) every decoy is a real frame: it decodes, with a random body", %{
    decoys: decoys,
    reals: reals
  } do
    for row <- decoys ++ reals do
      assert byte_size(row.envelope) == @frame_bytes
      assert {:ok, _payload, 4096} = Envelope.decode(row.envelope)
    end

    payloads =
      Enum.map(decoys, fn row ->
        {:ok, payload, 4096} = Envelope.decode(row.envelope)
        payload
      end)

    assert Enum.uniq(payloads) == payloads, "two decoys carried the same body"

    ratios = Enum.map(payloads, &printable_ratio/1)
    mean = Enum.sum(ratios) / length(ratios)
    # Random bytes are ~37% printable ASCII; a body of text is ~100%. A
    # sentence inside a decoy would drag the mean up — the tell C-04 forbids.
    assert mean < 0.5, "decoy bodies average #{Float.round(mean, 2)} printable"

    # Variable length, like a real message. A fixed payload length would put
    # the same four bytes at the head of every decoy.
    lengths = payloads |> Enum.map(&byte_size/1) |> Enum.uniq()
    assert length(lengths) > 20
    assert Enum.all?(lengths, &(&1 in 1..(@frame_bytes - 4)))
  end

  test "(b') a real body reads as text, a decoy body does not", %{
    decoys: decoys,
    reals: reals
  } do
    real = hd(reals)

    assert {:ok, text, 4096} = Envelope.decode(real.envelope)
    assert String.valid?(text)
    assert text =~ "Shall we meet tomorrow at nine"

    # The longest decoy body is the best case for a decoy reading as text; it
    # still does not. Random bytes are not a sentence — the limit C-04 names.
    junk =
      decoys
      |> Enum.map(fn row ->
        {:ok, payload, 4096} = Envelope.decode(row.envelope)
        payload
      end)
      |> Enum.max_by(&byte_size/1)

    assert byte_size(junk) > 100
    assert printable_ratio(junk) < 0.9
  end

  test "(c) ids are 16 random bytes with no ordered pattern", %{decoys: decoys, reals: reals} do
    all = decoys ++ reals
    ids = Enum.map(all, & &1.mailbox_id)

    assert length(Enum.uniq(ids)) == 120
    assert Enum.all?(ids, &(byte_size(&1) == 16))

    ints = Enum.map(ids, &id_int/1)
    assert length(Enum.uniq(ints)) == 120
    refute ints == Enum.sort(ints)

    # Successive differences modulo 2^128 are uniform for independent random
    # ids. A counter has one constant difference and lands in a single bin.
    diffs = successive_diffs(ints)
    chi2 = chi_square(diffs, 16)
    non_empty = diffs |> Enum.map(&rem(&1, 16)) |> Enum.uniq() |> length()

    assert non_empty >= 10
    assert chi2 < 60.0

    # Self-check: the same statistic on a counter is enormous, so the bound
    # above is not vacuous.
    counter_diffs = successive_diffs(Enum.map(1..120, &(&1 * 1000)))
    assert chi_square(counter_diffs, 16) > 1000.0

    IO.puts(
      "[shape] id chi-square: random=#{Float.round(chi2, 2)} " <>
        "counter=#{Float.round(chi_square(counter_diffs, 16), 2)} bins=#{non_empty}/16"
    )

    # Sorting the batch does not group the classes into blocks.
    decoy_ids = MapSet.new(decoys, & &1.mailbox_id)
    first_half = all |> Enum.sort_by(&id_int(&1.mailbox_id)) |> Enum.take(60)

    assert Enum.any?(first_half, &MapSet.member?(decoy_ids, &1.mailbox_id))
    assert Enum.any?(first_half, &(not MapSet.member?(decoy_ids, &1.mailbox_id)))
  end

  test "(d) the structural field set is identical", %{decoys: decoys, reals: reals} do
    expected = [:envelope, :mailbox_id, :ttl]

    for row <- decoys ++ reals do
      assert row |> Map.keys() |> Enum.sort() == expected
    end

    decoy_keys = decoys |> hd() |> Map.keys() |> Enum.sort()
    real_keys = reals |> hd() |> Map.keys() |> Enum.sort()
    assert decoy_keys == real_keys

    # And no row carries a provenance marker of any spelling.
    for row <- decoys ++ reals,
        field <- [:decoy, :real, :synthetic, :pubkey, :sig, :ctr, :at, :id] do
      refute Map.has_key?(row, field)
    end
  end

  test "(e) both classes carry the same lifetime", %{decoys: decoys, reals: reals} do
    ttls = Enum.map(decoys ++ reals, & &1.ttl)

    assert Enum.uniq(ttls) == [Mailbox.ttl_ms()]
  end

  # --- real fixture ----------------------------------------------------------

  # A real 1:1 row: a sentence in a 4 KB frame, addressed to 16 random bytes the
  # recipient chose. The frame — not the seal — is what C-04 compares.
  defp real_row(ttl, i) do
    text = "Shall we meet tomorrow at nine? I'll get the coffee, you bring the cake. (#{i})"
    {:ok, envelope, 4096} = Envelope.encode(text, @frame_bytes)

    %{
      mailbox_id: :crypto.strong_rand_bytes(16),
      envelope: envelope,
      ttl: ttl
    }
  end

  # --- measurement -----------------------------------------------------------

  # Share of bytes that are printable ASCII. Random bytes land near 0.37; a
  # body of text lands near 1.0.
  defp printable_ratio(payload) do
    n = byte_size(payload)
    printable = payload |> :binary.bin_to_list() |> Enum.count(&(&1 in 0x20..0x7E))
    if n == 0, do: 0.0, else: printable / n
  end

  defp id_int(id) do
    16 = byte_size(id)
    :binary.decode_unsigned(id)
  end

  defp successive_diffs(ints) do
    ints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> Integer.mod(b - a, @id_space) end)
  end

  defp chi_square(values, bins) do
    n = length(values)
    expected = n / bins
    frequencies = Enum.frequencies_by(values, &rem(&1, bins))

    Enum.reduce(0..(bins - 1), 0.0, fn bin, acc ->
      observed = Map.get(frequencies, bin, 0)
      acc + :math.pow(observed - expected, 2) / expected
    end)
  end
end
