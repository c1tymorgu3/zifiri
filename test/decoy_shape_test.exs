defmodule Zifiri.Chat.DecoyShapeTest do
  @moduledoc """
  Shape proof for R5-01..04: 70 decoys and 50 real messages, side by side.

  The test does not ask the module which rows are decoys — it built both sets
  itself, so it knows. It then measures the published frames and shows that
  nothing in them separates the two sets:

    * all 120 envelopes are 4096 bytes;
    * every envelope's byte entropy is > 7.9 bits/byte (AES-256-GCM ciphertext,
      including the real messages, whose plaintext is an ordinary sentence);
    * all 70 decoy public keys are distinct and none is the server key;
    * ids are 16 random bytes, with a uniform successive-difference
      distribution (a counter scores ~1785 on the same chi-square; random ids
      score ~15);
    * `Map.keys/1` is identical on both sets.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Chat.{Decoy, Message}

  @decoys 70
  @real 50
  @frame_bytes 4096
  @iv_bytes 12
  @tag_bytes 16
  @plaintext_bytes @frame_bytes - @iv_bytes - @tag_bytes
  @anchor 1_764_000_000_000
  @room "chat:lobby"

  # 2^128: ids are 16 random bytes interpreted as one unsigned integer.
  @id_space 340_282_366_920_938_463_463_374_607_431_768_211_456

  setup do
    epoch = :crypto.strong_rand_bytes(16)
    at = @anchor + 1
    room_key = :crypto.strong_rand_bytes(32)
    {server_pub, _server_priv} = :crypto.generate_key(:eddsa, :ed25519)

    decoys =
      Decoy.fill(@decoys, real: 0, epoch: epoch, room: @room, at: at)

    reals =
      for i <- 1..@real do
        real_frame(epoch, at + i, room_key, i)
      end

    %{
      epoch: epoch,
      room_key: room_key,
      server_pub: server_pub,
      decoys: decoys,
      reals: reals
    }
  end

  test "(a) every frame, decoy and real, is 4096 bytes", %{decoys: decoys, reals: reals} do
    assert length(decoys) == 70
    assert length(reals) == 50

    for frame <- decoys ++ reals do
      assert byte_size(frame.envelope) == @frame_bytes
    end
  end

  test "(b) both bodies are ciphertext: entropy > 7.9 bits/byte", %{
    decoys: decoys,
    reals: reals
  } do
    decoy_entropies = Enum.map(decoys, &entropy(&1.envelope))
    real_entropies = Enum.map(reals, &entropy(&1.envelope))

    assert Enum.min(decoy_entropies) > 7.9
    assert Enum.min(real_entropies) > 7.9

    IO.puts(
      "[shape] entropy min: decoy=#{Float.round(Enum.min(decoy_entropies), 4)} " <>
        "real=#{Float.round(Enum.min(real_entropies), 4)} bits/byte"
    )
  end

  test "(b') the real body is a genuine encrypted sentence, the decoy body is not readable",
       %{decoys: decoys, reals: reals, room_key: room_key} do
    real = hd(reals)
    decoy = hd(decoys)

    # The real frame decrypts with the room key and yields the sentence.
    plaintext = open(room_key, real.envelope)
    assert is_binary(plaintext)
    assert plaintext =~ "Yarın sabah dokuzda buluşalım mı"

    # The decoy does not: its key was thrown away, not the room key.
    assert :error = open(room_key, decoy.envelope)
  end

  test "(c) every decoy has its own pubkey, and none is the server key", %{
    decoys: decoys,
    reals: reals,
    server_pub: server_pub
  } do
    decoy_keys = Enum.map(decoys, & &1.pubkey)
    real_keys = Enum.map(reals, & &1.pubkey)

    assert length(Enum.uniq(decoy_keys)) == 70
    refute server_pub in decoy_keys
    refute server_pub in real_keys

    # The two sets do not share a key either.
    assert MapSet.disjoint?(MapSet.new(decoy_keys), MapSet.new(real_keys))

    # No frame carries a private half.
    for frame <- decoys ++ reals, do: refute(Map.has_key?(frame, :priv))
  end

  test "(d) ids are 16 random bytes with no ordered pattern", %{decoys: decoys, reals: reals} do
    all = decoys ++ reals
    ids = Enum.map(all, & &1.id)

    assert length(Enum.uniq(ids)) == 120

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
    decoy_ids = MapSet.new(decoys, & &1.id)
    first_half = all |> Enum.sort_by(&id_int(&1.id)) |> Enum.take(60)

    assert Enum.any?(first_half, &MapSet.member?(decoy_ids, &1.id))
    assert Enum.any?(first_half, &(not MapSet.member?(decoy_ids, &1.id)))
  end

  test "(e) the structural field set is identical", %{decoys: decoys, reals: reals} do
    expected = [:envelope, :id, :pubkey, :sig, :ts]

    for frame <- decoys ++ reals do
      assert frame |> Map.keys() |> Enum.sort() == expected
    end

    decoy_keys = decoys |> hd() |> Map.keys() |> Enum.sort()
    real_keys = reals |> hd() |> Map.keys() |> Enum.sort()
    assert decoy_keys == real_keys

    # And no frame carries a provenance marker of any spelling.
    for frame <- decoys ++ reals,
        field <- [:decoy, :real, :synthetic, :body, :bucket, :ctr, :at] do
      refute Map.has_key?(frame, field)
    end
  end

  # --- real fixture ----------------------------------------------------------

  # A real write: an ordinary sentence, length-prefixed and zero-padded, then
  # sealed with the room key. The ciphertext is what the observer sees.
  defp real_frame(epoch, ts, room_key, i) do
    text = "Yarın sabah dokuzda buluşalım mı? Kahveyi ben ısmarlarım, sen pastayı getir. (#{i})"
    payload = <<byte_size(text)::unsigned-big-32, text::binary>>
    padding = :binary.copy(<<0>>, @plaintext_bytes - byte_size(payload))
    envelope = seal(room_key, payload <> padding)

    {pubkey, priv} = :crypto.generate_key(:eddsa, :ed25519)

    sig =
      :crypto.sign(
        :eddsa,
        :none,
        Message.signing_input(@room, epoch, ts, envelope),
        [priv, :ed25519]
      )

    %{
      id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      sig: sig,
      pubkey: pubkey,
      envelope: envelope,
      ts: ts
    }
  end

  defp seal(key, plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, @tag_bytes, true)

    <<iv::binary-size(@iv_bytes), ciphertext::binary, tag::binary-size(@tag_bytes)>>
  end

  defp open(key, <<iv::binary-size(@iv_bytes), rest::binary>>) do
    ciphertext_bytes = byte_size(rest) - @tag_bytes
    <<ciphertext::binary-size(^ciphertext_bytes), tag::binary-size(@tag_bytes)>> = rest
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false)
  end

  # --- measurement -----------------------------------------------------------

  defp entropy(bin) do
    n = byte_size(bin)

    bin
    |> :binary.bin_to_list()
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_byte, count}, acc ->
      p = count / n
      acc - p * :math.log2(p)
    end)
  end

  defp id_int(id) do
    {:ok, raw} = Base.url_decode64(id, padding: false)
    16 = byte_size(raw)
    :binary.decode_unsigned(raw)
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
