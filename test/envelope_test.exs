defmodule Zifiri.EnvelopeTest do
  @moduledoc """
  The size claim in §4.1 has to hold byte for byte: a body travels in exactly
  one of four sizes, and two payloads of the same length leave the server as the
  same number of bytes. These tests pin the format (u32 length, zero padding),
  the refusals (unpadded, off-bucket, non-zero padding, oversized), the property
  that padding depends on length and never on content, and — deliberately — the
  limits of the claim: the length prefix is plaintext, so the exact length is
  readable by anyone holding the envelope, and nothing here is encrypted.
  """

  use ExUnit.Case, async: true

  alias Zifiri.Envelope

  @buckets [256, 1024, 4096, 16_384]
  @header 4
  @max_body 16_384 - 4

  defp body(len), do: :binary.copy("a", len)

  # An envelope built by hand at a chosen bucket: the decoder has to accept a
  # padded body in all four sizes, while `encode/1` only ever emits the
  # smallest one that fits.
  defp envelope_at(payload, bucket) do
    padding = bucket - @header - byte_size(payload)

    <<byte_size(payload)::unsigned-big-32, payload::binary, 0::size(padding)-unit(8)>>
  end

  test "buckets/0 lists the four envelope sizes, smallest first" do
    assert Envelope.buckets() == @buckets
  end

  test "an empty body round-trips in every bucket" do
    for bucket <- @buckets do
      envelope = envelope_at("", bucket)

      assert byte_size(envelope) == bucket
      assert Envelope.decode(envelope) == {:ok, "", bucket}
    end

    assert {:ok, envelope, 256} = Envelope.encode("")
    assert envelope == envelope_at("", 256)
  end

  test "a one-byte body round-trips in every bucket" do
    for bucket <- @buckets do
      envelope = envelope_at("x", bucket)

      assert byte_size(envelope) == bucket
      assert Envelope.decode(envelope) == {:ok, "x", bucket}
    end

    assert {:ok, envelope, 256} = Envelope.encode("x")
    assert envelope == envelope_at("x", 256)
  end

  test "a body of exactly bucket - 4 bytes fits with no padding" do
    for bucket <- @buckets do
      payload = body(bucket - @header)

      assert {:ok, envelope, ^bucket} = Envelope.encode(payload)
      assert byte_size(envelope) == bucket
      assert Envelope.decode(envelope) == {:ok, payload, bucket}
    end
  end

  test "the envelope is a big-endian length, the body, then all-zero padding" do
    payload = "zifiri"

    assert {:ok, envelope, 256} = Envelope.encode(payload)
    assert byte_size(envelope) == 256
    assert <<len::unsigned-big-32, rest::binary>> = envelope
    assert len == byte_size(payload)
    assert <<^payload::binary, padding::binary>> = rest
    assert padding == :binary.copy(<<0>>, 256 - @header - byte_size(payload))
  end

  test "the smallest bucket that fits is chosen" do
    assert {:ok, _, 256} = Envelope.encode(body(252))
    assert {:ok, _, 1024} = Envelope.encode(body(253))
    assert {:ok, _, 1024} = Envelope.encode(body(1020))
    assert {:ok, _, 4096} = Envelope.encode(body(1021))
    assert {:ok, _, 4096} = Envelope.encode(body(4092))
    assert {:ok, _, 16_384} = Envelope.encode(body(4093))
    assert {:ok, _, 16_384} = Envelope.encode(body(@max_body))
  end

  test "a body that does not fit the last bucket is refused" do
    assert Envelope.encode(body(@max_body + 1)) == {:error, :too_large}
    assert Envelope.encode(body(@max_body + 1_000)) == {:error, :too_large}
  end

  test "a non-zero padding byte is refused" do
    assert {:ok, envelope, 256} = Envelope.encode("hi")

    tampered =
      :binary.part(envelope, 0, byte_size(envelope) - 1) <> <<1>>

    assert byte_size(tampered) == 256
    assert Envelope.decode(tampered) == {:error, :bad_padding}
  end

  test "padding must be zero even when the length prefix is zero" do
    envelope = <<0::unsigned-big-32, 0::size(251)-unit(8), 1>>

    assert byte_size(envelope) == 256
    assert Envelope.decode(envelope) == {:error, :bad_padding}
  end

  test "a length prefix that runs past the bucket is refused" do
    over_by_one = <<253::unsigned-big-32, 0::size(252)-unit(8)>>
    absurd = <<0xFFFFFFFF::unsigned-big-32, 0::size(252)-unit(8)>>

    assert byte_size(over_by_one) == 256
    assert Envelope.decode(over_by_one) == {:error, :bad_length}
    assert Envelope.decode(absurd) == {:error, :bad_length}
  end

  test "a size that is not a bucket is refused" do
    for size <- [0, 1, 255, 257, 512, 1023, 1025, 16_385, 65_536] do
      assert Envelope.decode(:binary.copy(<<0>>, size)) == {:error, :bad_bucket},
             "size #{size} should not be a bucket"
    end
  end

  test "decode(encode(body)) == body for 200 random bodies" do
    :rand.seed(:exsss, {20, 4, 1})

    for _ <- 1..200 do
      len = :rand.uniform(@max_body + 1) - 1
      payload = random_body(len)

      assert {:ok, envelope, bucket} = Envelope.encode(payload)
      assert byte_size(envelope) == bucket
      assert Envelope.decode(envelope) == {:ok, payload, bucket}
    end
  end

  # Why this direction is right: the guarantee is about *length*, not content —
  # padding is a function of `byte_size(payload)` alone, so two payloads of equal
  # length are indistinguishable by envelope size, and two of different length
  # inside one bucket are not distinguishable from the bucket label either. A
  # test asserting that content does not change the envelope's *bytes* would be
  # asserting the opposite of what the format does: unequal content is unequal
  # bytes (checked below for `len > 0`).
  test "the same length produces the same envelope size, whatever the content" do
    for {len, bucket} <- [
          {0, 256},
          {10, 256},
          {252, 256},
          {1000, 1024},
          {4000, 4096},
          {@max_body, 16_384}
        ] do
      left = :binary.copy("a", len)
      right = :binary.copy("b", len)

      assert {:ok, left_envelope, ^bucket} = Envelope.encode(left)
      assert {:ok, right_envelope, ^bucket} = Envelope.encode(right)
      assert byte_size(left_envelope) == byte_size(right_envelope)
      # Two empty bodies are the same bytes; only their size claim matters.
      if len > 0, do: assert(left_envelope != right_envelope)
      assert Envelope.decode(left_envelope) == {:ok, left, bucket}
      assert Envelope.decode(right_envelope) == {:ok, right, bucket}
    end
  end

  test "a body holding every byte value survives the round trip" do
    payload = :binary.list_to_bin(Enum.to_list(0..255) ++ Enum.to_list(0..255))
    assert byte_size(payload) == 512

    assert {:ok, envelope, 1024} = Envelope.encode(payload)
    assert Envelope.decode(envelope) == {:ok, payload, 1024}
  end

  # Why this direction is right: the accepted design (§4.1, F-23) is "the bucket
  # is public, the exact length inside it is not secret". This asserts the honest
  # direction — the u32 prefix carries the payload length in the clear — because
  # the claim it replaces ("nothing about the body can be read off the wire") is
  # one the format does not make and padding cannot support.
  test "the length prefix is readable: an envelope does not hide its exact length" do
    payload = body(1000)

    assert {:ok, envelope, 1024} = Envelope.encode(payload)
    assert <<len::unsigned-big-32, _rest::binary>> = envelope
    assert len == byte_size(payload)
    assert byte_size(envelope) == 1024
  end

  # Why this direction is right: the decoder has to treat every padding offset
  # alike. A comparison that stops at the first difference is fast on early
  # offsets and slow on late ones; asserting that *each* position is refused
  # keeps the behaviour the constant-time comparison exists to preserve. Timing
  # itself is not assertable from ExUnit — the equivalence class is.
  test "a non-zero padding byte is refused wherever it sits" do
    assert {:ok, envelope, 256} = Envelope.encode("hi")

    for pos <- [6, 7, 128, 254, 255] do
      tampered =
        :binary.part(envelope, 0, pos) <>
          <<1>> <> :binary.part(envelope, pos + 1, 255 - pos)

      assert byte_size(tampered) == 256
      assert Envelope.decode(tampered) == {:error, :bad_padding}, "offset #{pos} was accepted"
    end
  end

  describe "payload/1" do
    test "returns the payload of a valid envelope" do
      assert {:ok, envelope, 256} = Envelope.encode("merhaba")
      assert Envelope.payload(envelope) == {:ok, "merhaba"}
    end

    # Why this direction is right: F-25 — an undecodable body was previously
    # handed back raw, so a corrupt row was served under a 200 with its padding
    # intact. "I cannot read this" must not be spelled the same way as "here is
    # what was stored".
    test "refuses a body it cannot decode instead of returning it raw" do
      for bad <- [
            "not an envelope",
            :binary.copy(<<0>>, 300),
            <<5::unsigned-big-32, "ab">>,
            <<2::unsigned-big-32, "hi", 1, 0::size(249)-unit(8)>>
          ] do
        assert Envelope.payload(bad) == {:error, :bad_envelope}
      end
    end
  end

  describe "response bodies" do
    test "an error body is padded into the 256 B bucket" do
      json = ~s({"error":"not_found"})

      assert {:ok, body, 256} = Envelope.encode_error(json)
      assert byte_size(body) == 256
      assert String.starts_with?(body, json)
      assert String.trim_trailing(body) == json
    end

    test "a feed page is padded into the 4 KB bucket" do
      json = ~s({"posts":[]})

      assert {:ok, body, 4096} = Envelope.encode_feed(json)
      assert byte_size(body) == 4096
      assert String.trim_trailing(body) == json
    end

    test "a document that does not fit its bucket is refused" do
      assert Envelope.encode_error(body(257)) == {:error, :too_large}
      assert Envelope.encode_feed(body(4097)) == {:error, :too_large}
      assert {:ok, _, 256} = Envelope.encode_error(body(256))
      assert {:ok, _, 4096} = Envelope.encode_feed(body(4096))
    end

    # Why this direction is right: F-20 — every response used to be 16 KB, so a
    # 404 cost ~270x the request that asked for it. The error bucket must stay an
    # order of magnitude under the largest envelope, not equal to it.
    test "the error bucket is 1/64 of the largest envelope, not merely smaller" do
      assert {:ok, body, 256} = Envelope.encode_error(~s({"error":"not_found"}))
      assert byte_size(body) == 256

      # The ratio is the point: a 404 used to cost the same 16 KB as a full
      # post. `* 8 <= 16_384` would have passed at 2 KB too, so measure the
      # ratio against the bucket that actually holds a payload.
      {:ok, full, 16_384} = Envelope.encode(:binary.copy("x", 16_000))
      assert div(byte_size(full), byte_size(body)) == 64
    end
  end

  defp random_body(0), do: ""

  defp random_body(len) do
    for(_ <- 1..len, into: <<>>, do: <<:rand.uniform(256) - 1>>)
  end
end
