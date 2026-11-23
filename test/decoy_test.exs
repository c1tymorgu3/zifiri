defmodule Zifiri.Chat.DecoyTest do
  @moduledoc """
  The filler: a decoy must be indistinguishable from a real chat write.

  "Indistinguishable" is checked rather than asserted: every decoy is 4096
  bytes of AES-256-GCM ciphertext (no plaintext frame, no dictionary), carries
  its own ephemeral Ed25519 key, has an opaque 16-byte id, and is stamped
  inside its own bucket. There is no classifier left in the module to leak the
  answer.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Bucket
  alias Zifiri.Chat.Decoy
  alias Zifiri.Envelope

  @anchor 1_764_000_000_000
  @next_bucket @anchor + 600_000
  @frame_bytes 4096

  setup do
    Bucket.reset()
    Decoy.reset()

    on_exit(fn ->
      Bucket.reset()
      Decoy.reset()
    end)

    %{epoch: :crypto.strong_rand_bytes(16)}
  end

  # --- filling ---------------------------------------------------------------

  test "an empty bucket is filled to 120" do
    assert Decoy.target() == 120
    assert Decoy.bucket_bytes() == @frame_bytes
    assert Bucket.size() == 0

    decoys = Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16))

    assert length(decoys) == 120
    assert length(Enum.uniq_by(decoys, & &1.id)) == 120
  end

  test "the real count is subtracted, not ignored" do
    for i <- 1..30, do: Bucket.add({:real, i})

    # Default `:real` is the bucket itself.
    assert length(Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16))) == 90

    # And an explicit count wins, for a caller that already drained.
    assert length(Decoy.fill(120, real: 100, epoch: :crypto.strong_rand_bytes(16))) == 20
    assert Decoy.fill(120, real: 120, epoch: :crypto.strong_rand_bytes(16)) == []
    assert Decoy.fill(120, real: 300, epoch: :crypto.strong_rand_bytes(16)) == []
  end

  test "a bucket with more real writes than the target gets no decoys" do
    for i <- 1..150, do: Bucket.add({:real, i})

    assert Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16)) == []
  end

  test "the dictionary cap is gone: a fill is not limited to 200" do
    assert length(Decoy.fill(500, real: 0, epoch: :crypto.strong_rand_bytes(16))) == 500
  end

  # --- the frame -------------------------------------------------------------

  test "every decoy is 4096 bytes of high-entropy ciphertext" do
    decoys = Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16))

    for decoy <- decoys do
      assert byte_size(decoy.envelope) == @frame_bytes
      assert entropy(decoy.envelope) > 7.9
    end
  end

  test "the envelope is ciphertext, not a decodable plaintext frame" do
    # A real 4 KB envelope decodes: 32-bit length, payload, zero padding. A
    # decoy's bytes are random, so the decoder cannot find a zero-padded frame.
    for decoy <- Decoy.fill(20, epoch: :crypto.strong_rand_bytes(16)) do
      assert {:error, _reason} = Envelope.decode(decoy.envelope)
    end
  end

  test "the dictionary and the classifier API are gone" do
    refute function_exported?(Decoy, :dictionary, 0)
    refute function_exported?(Decoy, :decoy?, 1)
    refute function_exported?(Decoy, :ratio, 1)
    refute function_exported?(Decoy, :start_link, 1)
  end

  test "a decoy has exactly the five public frame fields" do
    [decoy | _] = Decoy.fill(1, epoch: :crypto.strong_rand_bytes(16))

    assert decoy |> Map.keys() |> Enum.sort() == [:envelope, :id, :pubkey, :sig, :ts]

    assert byte_size(decoy.pubkey) == 32
    assert byte_size(decoy.sig) == 64
    assert is_binary(decoy.id)
    assert byte_size(decoy.id) == 22
    assert is_integer(decoy.ts)

    # Neither the old marker-ish fields nor a private key are reachable.
    for field <- [:priv, :decoy, :body, :bucket, :ctr, :at] do
      refute Map.has_key?(decoy, field)
    end
  end

  test "the id is 16 random bytes in unpadded base64url" do
    ids = Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16)) |> Enum.map(& &1.id)

    for id <- ids do
      assert {:ok, raw} = Base.url_decode64(id, padding: false)
      assert byte_size(raw) == 16
    end

    assert length(Enum.uniq(ids)) == 120
    # No order: a monotonic counter would already be sorted.
    refute ids == Enum.sort(ids)
  end

  test "the timestamp falls inside the bucket it is labelled with" do
    decoys = Decoy.fill(120, epoch: :crypto.strong_rand_bytes(16), at: @anchor + 1)

    for decoy <- decoys do
      assert decoy.ts >= @anchor
      assert decoy.ts < @next_bucket
    end

    assert decoys |> Enum.map(& &1.ts) |> Enum.uniq() |> length() > 1
  end

  # --- the signature ---------------------------------------------------------

  test "every decoy verifies under the room epoch and its own key" do
    epoch = :crypto.strong_rand_bytes(16)
    decoys = Decoy.fill(120, epoch: epoch)

    assert Enum.all?(decoys, &Decoy.verify?(&1, epoch))
  end

  test "a decoy does not verify under a different epoch or after tampering" do
    epoch = :crypto.strong_rand_bytes(16)
    [decoy | _] = Decoy.fill(1, epoch: epoch)

    assert Decoy.verify?(decoy, epoch)
    refute Decoy.verify?(decoy, :crypto.strong_rand_bytes(16))

    tampered = %{decoy | envelope: flip(decoy.envelope)}
    refute Decoy.verify?(tampered, epoch)
  end

  test "a custom room is covered by the signature" do
    epoch = :crypto.strong_rand_bytes(16)
    [decoy | _] = Decoy.fill(1, epoch: epoch, room: "chat:other")

    assert Decoy.verify?(decoy, epoch, "chat:other")
    refute Decoy.verify?(decoy, epoch)
  end

  # --- keys ------------------------------------------------------------------

  test "every decoy carries a distinct ephemeral key" do
    {server_pub, _server_priv} = :crypto.generate_key(:eddsa, :ed25519)
    decoys = Decoy.fill(70, epoch: :crypto.strong_rand_bytes(16))

    pubkeys = Enum.map(decoys, & &1.pubkey)

    assert length(Enum.uniq(pubkeys)) == 70
    refute server_pub in pubkeys
  end

  test "two fills of the same bucket share no key" do
    epoch = :crypto.strong_rand_bytes(16)

    a = Decoy.fill(20, epoch: epoch, at: @anchor + 1)
    b = Decoy.fill(20, epoch: epoch, at: @anchor + 2)

    assert MapSet.disjoint?(
             MapSet.new(a, & &1.pubkey),
             MapSet.new(b, & &1.pubkey)
           )
  end

  # --- helpers ---------------------------------------------------------------

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

  defp flip(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 0xFF), rest::binary>>
end
