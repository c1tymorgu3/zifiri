defmodule Zifiri.Identity do
  @moduledoc """
  The 40-byte identity line, and the mailbox address derived from it
  (cevap.md Soru 6, decision A).

  A browser has no `localStorage` and no background worker, so the identity
  survives a closed tab in exactly one place: the line the user copies out. The
  line therefore carries everything needed to resume — the seed, a mailbox
  generation, and the next ownership index — and nothing else. Every byte that
  does not have to be there costs the user a character to keep, so the format is
  built to be as short as the job allows:

      seed 32 ‖ generation 1 ‖ next_i 3 ‖ checksum 4 = 40 bytes
      40 bytes = 320 bits = 64 base32 characters, no padding
      "zifiri1" + 64 characters = 71 characters on screen

  The old format was 56 bytes (90 base32 characters) because it carried a
  random 16-byte `mailbox_id` and a 4-byte index. Neither survives here:

    * `mailbox_id` is **derived**, not stored:
      `HKDF-SHA256(seed, info = "zifiri/mailbox/v1/" <> generation)[0..15]`.
      Randomness bought one thing — being able to move the address if it leaked
      — and the 1-byte generation counter buys that back for a thirty-second of
      the cost. Everything the random id was chosen for still holds: the server
      sees 16 bytes it cannot invert without the seed, no public key is ever
      sent, and two devices with different seeds share no address. What is lost
      is stated plainly: two mailboxes derived from one seed are *known* to be
      one identity by anyone who sees both ids and guesses they share a seed.
    * the index is 3 bytes, not 4. 16 777 216 ownership tokens is more than one
      device can burn in the lifetime of the service at one write per second
      (~194 days of uninterrupted writes), and the fourth byte was 1.6 base32
      characters of pure overhead. Overflow raises rather than wrapping; see
      `line_bytes/3`.

  ## The checksum is a typo detector, not a MAC

  `checksum/1` is the first four bytes of BLAKE2b-256 over the 36 bytes before
  it. It catches the failure this format actually has: a user retyping a
  character, or a paste that loses a character. Four bytes is 32 bits, so a
  random corruption is accepted with probability 2⁻³², and a *deliberate*
  forgery is not a threat model here at all — anyone who can edit the line can
  edit the seed and produce a consistent line for it. Do not read this as
  integrity against an attacker; read it as "a mangled line is refused instead
  of silently becoming a different identity".

  ## Decoding is total, encoding is not

  `decode_line/1` takes untrusted text and returns `{:ok, map}` or
  `{:error, reason}`. `encode_line/3` and `line_bytes/3` take values this code
  produced and raise `ArgumentError` on a seed of the wrong size, a generation
  outside a byte, or an index past three bytes. A wrong type there is a bug in
  the caller, not input to be reported back to a user.
  """

  import Bitwise

  # The product name plus a format digit. `@legacy_prefix` is what earlier
  # builds wrote; `decode_line/1` still accepts it, `encode_line/3` never emits it.
  @prefix "zifiri1"
  @legacy_prefix "zifir1"
  @seed_bytes 32
  @generation_bytes 1
  @counter_bytes 3
  @checksum_bytes 4
  @line_bytes @seed_bytes + @generation_bytes + @counter_bytes + @checksum_bytes
  @max_generation 0xFF
  @max_counter 0xFF_FFFF
  @mailbox_id_bytes 16
  @mailbox_info "zifiri/mailbox/v1/"

  @typedoc "A decoded line: what a device needs to resume an identity."
  @type line :: %{
          seed: <<_::256>>,
          generation: 0..255,
          next_i: 0..16_777_215
        }

  @typedoc "Why a line was refused."
  @type decode_error :: :bad_prefix | :bad_length | :bad_checksum

  @doc """
  The mailbox address for one seed and one generation, 16 bytes.

  `HKDF-SHA256(seed, info: "zifiri/mailbox/v1/" <> Integer.to_string(generation))`,
  first 16 bytes. The generation is written in decimal ASCII, so generation 0
  and generation 10 have unrelated info strings — a prefix relationship between
  info strings is the one thing HKDF does not protect against.

  Deterministic by construction: the same seed and generation always yield the
  same address, on the server and on the device, with no table and no state.
  """
  @spec derive_mailbox_id(binary(), 0..255) :: <<_::128>>
  def derive_mailbox_id(seed, generation) do
    assert_seed!(seed)
    assert_generation!(generation)

    seed
    |> hkdf_sha256(@mailbox_info <> Integer.to_string(generation), @mailbox_id_bytes)
  end

  @doc """
  The 40 bytes a line encodes.

  Layout, big-endian throughout:

      seed(32) ‖ generation(1) ‖ next_i(3) ‖ checksum(4)

  Raises `ArgumentError` when `next_i` does not fit three bytes (16 777 215 is
  the last valid value). There is no wrapping and no truncation: silently
  reusing an ownership index would let two writes share a token, and the whole
  point of `next_i` is that it never goes backwards.
  """
  @spec line_bytes(binary(), 0..255, 0..16_777_215) :: <<_::320>>
  def line_bytes(seed, generation, next_i) do
    assert_seed!(seed)
    assert_generation!(generation)
    assert_counter!(next_i)

    head = <<seed::binary-size(@seed_bytes), generation::8, next_i::24>>
    head <> checksum(head)
  end

  @doc """
  The printable line: `"zifiri1"` followed by 64 uppercase base32 characters.

  The prefix is lowercase and the body uppercase, and the line is 71 characters
  in all: seven for the prefix, sixty-four for the body.

  Base32 with no padding because 40 bytes is exactly 64 five-bit groups — the
  encoding wastes no character and needs no `=` for a reader to strip. Uppercase
  because the line is meant to be read aloud and retyped; `decode_line/1` still
  accepts lowercase, since the cost of being strict there is a user who cannot
  import a line that is otherwise perfect.
  """
  @spec encode_line(binary(), 0..255, 0..16_777_215) :: String.t()
  def encode_line(seed, generation, next_i) do
    @prefix <> Base.encode32(line_bytes(seed, generation, next_i), case: :upper, padding: false)
  end

  @doc """
  Reads a line back.

  Returns `{:ok, %{seed: seed, generation: g, next_i: i}}` or one of:

    * `:bad_prefix` — the text starts with neither `"zifiri1"` nor the older
      `"zifir1"`. A line from a future version (`zifir2`) lands here; refusing
      it is the point, because the bytes behind a different prefix are not
      these bytes.
    * `:bad_length` — the body is not 64 base32 characters, or those characters
      do not decode to 40 bytes. A character outside the base32 alphabet is
      reported here too: it is not a length the format has, and inventing a
      fourth error for it would not tell a caller anything different.
    * `:bad_checksum` — 40 bytes decoded, but the trailing four do not match the
      BLAKE2b-256 prefix of the first 36. Either the line was mistyped or it was
      edited on purpose; this function cannot tell those apart.

  The old `"zifir1"` prefix is accepted so a line copied out of an earlier
  build still loads; the body must be the 40-byte layout either way. Those
  lines are one character shorter (70), and nothing about them is written back.

  Case is not significant on input — neither on the prefix nor on the body; the
  seed, generation and index are returned exactly as encoded.
  """
  @spec decode_line(binary()) :: {:ok, line()} | {:error, decode_error()}
  def decode_line(line) when is_binary(line) do
    with {:ok, body} <- split_prefix(line) do
      decode_body(body)
    end
  end

  def decode_line(_text), do: {:error, :bad_prefix}

  # Two prefixes, any case: a line is meant to be retyped, and refusing `ZIFIRI1`
  # or `zifir1` would fail a user whose line is otherwise perfect. Only the
  # prefix is matched loosely; the body is upcased once, in `decode_body/1`.
  defp split_prefix(line) do
    folded = String.downcase(line)

    case Enum.find([@prefix, @legacy_prefix], &String.starts_with?(folded, &1)) do
      nil -> {:error, :bad_prefix}
      prefix -> split_body(line, byte_size(prefix))
    end
  end

  defp split_body(line, prefix_bytes) when byte_size(line) > prefix_bytes do
    {:ok, binary_part(line, prefix_bytes, byte_size(line) - prefix_bytes)}
  end

  defp split_body(_line, _prefix_bytes), do: {:error, :bad_length}

  @doc """
  Four-byte checksum of the 36 bytes before it: BLAKE2b-256, first four bytes.

  Exposed so a caller can verify a line it built without encoding it twice, and
  so the definition lives in one place rather than in a test.
  """
  @spec checksum(binary()) :: <<_::32>>
  def checksum(bytes) when is_binary(bytes) do
    binary_part(blake2b(bytes, 32), 0, @checksum_bytes)
  end

  ## Decoding

  defp decode_body(body) do
    # Uppercasing first keeps one decoder: `Base.decode32/2` with `case: :upper`
    # rejects lowercase, and a user who retyped a line in lower case has not
    # made an error worth refusing.
    case Base.decode32(String.upcase(body), case: :upper, padding: false) do
      {:ok,
       <<seed::binary-size(@seed_bytes), generation::8, next_i::24, sum::binary-size(4)>> =
           bytes} ->
        if :crypto.hash_equals(sum, checksum(binary_part(bytes, 0, @line_bytes - 4))) do
          {:ok, %{seed: seed, generation: generation, next_i: next_i}}
        else
          {:error, :bad_checksum}
        end

      {:ok, _other_length} ->
        {:error, :bad_length}

      :error ->
        {:error, :bad_length}
    end
  end

  ## HKDF-SHA256 (RFC 5869), one output block is enough for 16 bytes

  # An absent salt is HashLen zero bytes, and HMAC zero-pads a key shorter than
  # its block size, so `<<>>` and 32 zero bytes are the same key. `<<>>` is the
  # honest spelling of "no salt".
  defp hkdf_sha256(ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, <<>>, ikm)
    expand(prk, info, length, <<>>, <<>>, 1)
  end

  defp expand(_prk, _info, length, okm, _prev, _i) when byte_size(okm) >= length,
    do: binary_part(okm, 0, length)

  defp expand(prk, info, length, okm, prev, i) do
    block = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
    expand(prk, info, length, okm <> block, block, i + 1)
  end

  ## BLAKE2b

  # OTP exposes `:crypto.hash(:blake2b, _)` at its full 64-byte width only; the
  # output length of BLAKE2b is a parameter of the digest, not a truncation, so
  # a 32-byte BLAKE2b is not a prefix of the 64-byte one and has to be computed.
  # Only four bytes of the result are used, but they have to be the right four:
  # the device computes this checksum too, and a line is only importable if both
  # sides agree byte for byte.

  @mask 0xFFFF_FFFF_FFFF_FFFF

  @iv [
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179
  ]

  @sigma [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
  ]

  defp blake2b(data, out_len) do
    # Parameter block: digest_length, key_length 0, fanout 1, depth 1.
    h = List.to_tuple(@iv)
    h = put_elem(h, 0, bxor(elem(h, 0), bxor(0x0101_0000, out_len)) &&& @mask)

    h = absorb(h, data, 0)

    for i <- 0..7, into: <<>> do
      <<elem(h, i)::little-64>>
    end
    |> binary_part(0, out_len)
  end

  defp absorb(h, <<block::binary-size(128), rest::binary>>, t) when byte_size(rest) > 0 do
    absorb(compress(h, block, t + 128, false), rest, t + 128)
  end

  defp absorb(h, <<block::binary-size(128)>>, t) do
    compress(h, block, t + 128, true)
  end

  defp absorb(h, rest, t) do
    compress(h, pad_block(rest), t + byte_size(rest), true)
  end

  defp pad_block(rest) do
    rest <> :binary.copy(<<0>>, 128 - byte_size(rest))
  end

  defp compress(h, block, t, final?) do
    words = for <<w::little-64 <- block>>, into: [], do: w
    words = List.to_tuple(words)

    v = List.to_tuple(Tuple.to_list(h) ++ @iv)
    v = put_elem(v, 12, bxor(elem(v, 12), t &&& @mask))
    v = put_elem(v, 13, bxor(elem(v, 13), bsr(t, 64)))
    v = if final?, do: put_elem(v, 14, bxor(elem(v, 14), @mask)), else: v

    v = rounds(v, words)

    List.to_tuple(
      for i <- 0..7 do
        bxor(elem(h, i), bxor(elem(v, i), elem(v, i + 8))) &&& @mask
      end
    )
  end

  # Twelve rounds over ten sigma permutations: rounds 10 and 11 reuse rows 0
  # and 1, which is what BLAKE2b specifies (BLAKE2s stops at ten).
  defp rounds(v, w) do
    Enum.reduce(0..11, v, fn round, acc ->
      s = Enum.at(@sigma, rem(round, 10))
      m = fn i -> elem(w, Enum.at(s, i)) end

      acc
      |> g(0, 4, 8, 12, m.(0), m.(1))
      |> g(1, 5, 9, 13, m.(2), m.(3))
      |> g(2, 6, 10, 14, m.(4), m.(5))
      |> g(3, 7, 11, 15, m.(6), m.(7))
      |> g(0, 5, 10, 15, m.(8), m.(9))
      |> g(1, 6, 11, 12, m.(10), m.(11))
      |> g(2, 7, 8, 13, m.(12), m.(13))
      |> g(3, 4, 9, 14, m.(14), m.(15))
    end)
  end

  defp g(v, a, b, c, d, x, y) do
    v = put_elem(v, a, elem(v, a) + elem(v, b) + x &&& @mask)
    v = put_elem(v, d, rotr(bxor(elem(v, d), elem(v, a)), 32))
    v = put_elem(v, c, elem(v, c) + elem(v, d) &&& @mask)
    v = put_elem(v, b, rotr(bxor(elem(v, b), elem(v, c)), 24))
    v = put_elem(v, a, elem(v, a) + elem(v, b) + y &&& @mask)
    v = put_elem(v, d, rotr(bxor(elem(v, d), elem(v, a)), 16))
    v = put_elem(v, c, elem(v, c) + elem(v, d) &&& @mask)
    put_elem(v, b, rotr(bxor(elem(v, b), elem(v, c)), 63))
  end

  defp rotr(x, n), do: bor(bsr(x, n), bsl(x, 64 - n)) &&& @mask

  ## Argument checks

  defp assert_seed!(seed) when is_binary(seed) and byte_size(seed) == @seed_bytes, do: :ok

  defp assert_seed!(seed) do
    raise ArgumentError,
          "seed must be #{@seed_bytes} bytes, got: #{inspect(seed)}"
  end

  defp assert_generation!(generation)
       when is_integer(generation) and generation >= 0 and generation <= @max_generation,
       do: :ok

  defp assert_generation!(generation) do
    raise ArgumentError,
          "generation must be an integer in 0..#{@max_generation}, got: #{inspect(generation)}"
  end

  defp assert_counter!(next_i)
       when is_integer(next_i) and next_i >= 0 and next_i <= @max_counter,
       do: :ok

  defp assert_counter!(next_i) do
    raise ArgumentError,
          "next_i must be an integer in 0..#{@max_counter} (three bytes), got: #{inspect(next_i)}"
  end
end
