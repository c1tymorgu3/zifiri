defmodule Zifiri.IdentityTest do
  use ExUnit.Case, async: true

  alias Zifiri.Identity

  # 0x00 0x01 ... 0x1f — a seed with no repeated bytes, so a swapped field or an
  # off-by-one in the layout shows up as a wrong value rather than as a
  # coincidence.
  @seed_a :binary.list_to_bin(Enum.to_list(0..31))
  @seed_b :binary.copy(<<0xA5>>, 32)
  @prefix "zifiri1"
  # What earlier builds wrote; still importable, never written.
  @legacy_prefix "zifir1"

  # Produced by an independent implementation (Python: hashlib.blake2b with
  # digest_size=32 for the checksum, hmac-based HKDF-SHA256 with a zero salt and
  # info = "zifiri/mailbox/v1/3", then base32 upper-case without padding). If
  # this line ever changes, the format changed — not just the code.
  @golden_line "zifiri1AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQGAAAA7LLVKBQ"

  describe "encode_line/3" do
    test "is exactly 64 base32 characters after the prefix, 71 in all" do
      line = Identity.encode_line(@seed_a, 0, 0)

      assert String.length(line) == 71
      assert String.starts_with?(line, @prefix)
      assert String.length(line) - String.length(@prefix) == 64
    end

    test "body is uppercase base32 with no padding" do
      body = @golden_line |> String.replace_prefix(@prefix, "")

      assert body == String.upcase(body)
      refute String.contains?(body, "=")
      assert body =~ ~r/\A[A-Z2-7]{64}\z/
    end

    test "40 bytes never needs padding, so every line has the same length" do
      for {gen, next_i} <- [{0, 0}, {1, 1}, {7, 255}, {255, 0xFF_FFFF}] do
        assert String.length(Identity.encode_line(@seed_a, gen, next_i)) == 71
      end
    end

    test "is deterministic" do
      assert Identity.encode_line(@seed_a, 3, 7) == Identity.encode_line(@seed_a, 3, 7)
      assert Identity.encode_line(@seed_a, 3, 7) == @golden_line
    end

    test "changes when the generation changes" do
      refute Identity.encode_line(@seed_a, 3, 7) == Identity.encode_line(@seed_a, 4, 7)
    end

    test "changes when the index changes" do
      refute Identity.encode_line(@seed_a, 3, 7) == Identity.encode_line(@seed_a, 3, 8)
    end
  end

  describe "line_bytes/3" do
    test "is 40 bytes: seed, generation, three-byte counter, four-byte checksum" do
      bytes = Identity.line_bytes(@seed_a, 3, 7)

      assert byte_size(bytes) == 40
      assert <<seed::binary-size(32), 3::8, 7::24, checksum::binary-size(4)>> = bytes
      assert seed == @seed_a
      assert checksum == Identity.checksum(binary_part(bytes, 0, 36))
    end

    test "the counter is big-endian across all three bytes" do
      assert <<_::binary-size(33), 0x01, 0x02, 0x03, _::binary-size(4)>> =
               Identity.line_bytes(@seed_a, 0, 0x010203)
    end

    test "checksum is the first four bytes of BLAKE2b-256 of the first 36 bytes" do
      # BLAKE2b-256(<<0, 1, ..., 35>>) = c1b7eb8d130d705c5fa9ee8061076a31...
      assert Identity.checksum(:binary.list_to_bin(Enum.to_list(0..35))) ==
               <<0xC1, 0xB7, 0xEB, 0x8D>>

      assert byte_size(Identity.checksum(<<>>)) == 4
    end
  end

  describe "decode_line/1" do
    test "round-trips seed, generation and index" do
      for {gen, next_i} <- [{0, 0}, {1, 1}, {9, 1234}, {255, 0xFF_FFFF}] do
        assert {:ok, decoded} = Identity.decode_line(Identity.encode_line(@seed_a, gen, next_i))
        assert decoded == %{seed: @seed_a, generation: gen, next_i: next_i}
        assert Map.keys(decoded) |> Enum.sort() == [:generation, :next_i, :seed]
      end
    end

    test "accepts a lowercase line" do
      lowercase = String.downcase(@golden_line)

      assert {:ok, %{seed: @seed_a, generation: 3, next_i: 7}} = Identity.decode_line(lowercase)
    end

    test "accepts the old zifir1 prefix" do
      body = binary_part(@golden_line, String.length(@prefix), 64)

      assert {:ok, decoded} = Identity.decode_line(@legacy_prefix <> body)
      assert decoded == %{seed: @seed_a, generation: 3, next_i: 7}
      assert String.length(@legacy_prefix <> body) == 70

      # The same identity re-encodes with the current prefix and one more byte.
      assert Identity.encode_line(@seed_a, 3, 7) == @golden_line
    end

    test "is case-insensitive on the prefix as well as the body" do
      body = binary_part(@golden_line, String.length(@prefix), 64)

      assert {:ok, %{seed: @seed_a, generation: 3, next_i: 7}} =
               Identity.decode_line("ZIFIRI1" <> body)

      assert {:ok, %{seed: @seed_a, generation: 3, next_i: 7}} =
               Identity.decode_line("Zifiri1" <> body)

      assert {:ok, %{seed: @seed_a, generation: 3, next_i: 7}} =
               Identity.decode_line("ZIFIR1" <> body)
    end

    test "refuses a wrong prefix" do
      body = binary_part(@golden_line, String.length(@prefix), 64)

      assert Identity.decode_line("zifir2" <> body) == {:error, :bad_prefix}
      assert Identity.decode_line("zifir" <> body) == {:error, :bad_prefix}
      assert Identity.decode_line("zifiri2" <> body) == {:error, :bad_prefix}
      assert Identity.decode_line("") == {:error, :bad_prefix}
      assert Identity.decode_line(body) == {:error, :bad_prefix}
    end

    test "refuses a body that is too short" do
      short = binary_part(@golden_line, 0, 70)

      assert Identity.decode_line(short) == {:error, :bad_length}
      assert Identity.decode_line(@prefix) == {:error, :bad_length}

      assert Identity.decode_line(@prefix <> binary_part(@golden_line, String.length(@prefix), 8)) ==
               {:error, :bad_length}
    end

    test "refuses a body that is too long" do
      assert Identity.decode_line(@golden_line <> "A") == {:error, :bad_length}

      assert Identity.decode_line(@golden_line <> String.duplicate("A", 8)) ==
               {:error, :bad_length}
    end

    test "refuses a character outside the base32 alphabet" do
      assert Identity.decode_line(@prefix <> String.duplicate("A", 63) <> "1") ==
               {:error, :bad_length}

      assert Identity.decode_line(@prefix <> String.duplicate("A", 63) <> "!") ==
               {:error, :bad_length}
    end

    test "refuses a line whose seed was altered" do
      assert {:error, :bad_checksum} = Identity.decode_line(reencode(@golden_line, 0, 0xFF))
    end

    test "refuses a line whose generation byte was altered" do
      assert {:error, :bad_checksum} = Identity.decode_line(reencode(@golden_line, 32, 0x04))
    end

    test "refuses a line whose checksum was altered" do
      assert {:error, :bad_checksum} = Identity.decode_line(reencode(@golden_line, 39, 0x00))
    end

    test "refuses a single flipped base32 character" do
      body = binary_part(@golden_line, String.length(@prefix), 64)

      for index <- [0, 10, 30, 63] do
        <<before::binary-size(^index), char::binary-size(1), rest::binary>> = body
        flipped = if char == "A", do: "B", else: "A"

        assert Identity.decode_line(@prefix <> before <> flipped <> rest) ==
                 {:error, :bad_checksum},
               "flipping body character #{index} was not caught"
      end
    end
  end

  describe "derive_mailbox_id/2" do
    test "is 16 bytes" do
      assert byte_size(Identity.derive_mailbox_id(@seed_a, 0)) == 16
    end

    test "is deterministic for the same seed and generation" do
      # A sub-binary of a larger one must derive the same id as a plain copy:
      # nothing here may depend on how the seed binary is stored.
      sub_binary = binary_part(<<0>> <> @seed_a <> <<0>>, 1, 32)

      assert Identity.derive_mailbox_id(@seed_a, 4) == Identity.derive_mailbox_id(@seed_a, 4)
      assert Identity.derive_mailbox_id(sub_binary, 4) == Identity.derive_mailbox_id(@seed_a, 4)
    end

    test "matches the independent reference values" do
      # Python: HKDF-SHA256(seed, info=b"zifiri/mailbox/v1/<gen>", salt=None)[:16]
      assert Base.encode16(Identity.derive_mailbox_id(@seed_a, 0)) ==
               "76A0C7C98CD50E5CAD1BDB1D7C15D78C"

      assert Base.encode16(Identity.derive_mailbox_id(@seed_a, 5)) ==
               "9600094E4A091869F47D8638EAC69D61"
    end

    test "differs when the generation changes" do
      refute Identity.derive_mailbox_id(@seed_a, 0) == Identity.derive_mailbox_id(@seed_a, 1)
      refute Identity.derive_mailbox_id(@seed_a, 9) == Identity.derive_mailbox_id(@seed_a, 10)
    end

    test "differs when the seed changes" do
      refute Identity.derive_mailbox_id(@seed_a, 0) == Identity.derive_mailbox_id(@seed_b, 0)
    end
  end

  describe "bounds" do
    test "the counter holds 16 777 216 values and refuses the next one" do
      assert {:ok, %{next_i: 0xFF_FFFF}} =
               Identity.decode_line(Identity.encode_line(@seed_a, 0, 0xFF_FFFF))

      assert_raise ArgumentError, ~r/next_i must be an integer in 0\.\.16777215/, fn ->
        Identity.encode_line(@seed_a, 0, 0x100_0000)
      end

      assert_raise ArgumentError, fn -> Identity.encode_line(@seed_a, 0, -1) end
    end

    test "the generation is one byte" do
      assert {:ok, %{generation: 255}} =
               Identity.decode_line(Identity.encode_line(@seed_a, 255, 0))

      assert_raise ArgumentError, ~r/generation must be an integer in 0\.\.255/, fn ->
        Identity.derive_mailbox_id(@seed_a, 256)
      end

      assert_raise ArgumentError, fn -> Identity.encode_line(@seed_a, -1, 0) end
    end

    test "the seed is exactly 32 bytes" do
      assert_raise ArgumentError, ~r/seed must be 32 bytes/, fn ->
        Identity.encode_line(<<0::248>>, 0, 0)
      end

      assert_raise ArgumentError, fn -> Identity.derive_mailbox_id(<<0::264>>, 0) end
      assert_raise ArgumentError, fn -> Identity.encode_line("not a binary", 0, 0) end
    end
  end

  # Flip one byte of a line's decoded payload and re-encode it, leaving the
  # checksum as it was: exactly the "someone edited this line" case.
  defp reencode(line, index, value) do
    body = binary_part(line, String.length(@prefix), 64)
    {:ok, bytes} = Base.decode32(body, case: :upper, padding: false)
    <<head::binary-size(^index), _old::8, tail::binary>> = bytes
    @prefix <> Base.encode32(head <> <<value>> <> tail, case: :upper, padding: false)
  end
end
