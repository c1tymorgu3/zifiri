defmodule Zifiri.Envelope do
  @moduledoc """
  Fixed-size envelopes for every write the server accepts (plan §4.1).

  A body is padded into the smallest bucket that can hold it: 256 B, 1 KB, 4 KB
  or 16 KB. The wire format is a 32-bit big-endian length, the body, and zero
  padding, and the whole thing is exactly one bucket long.

  ## What this hides, and what it does not

  Padding makes every write in a bucket the same size, so an envelope cannot be
  told apart from another envelope of a different payload length in the same
  bucket. That is the whole guarantee, and the limits are worth stating as
  plainly as the guarantee:

    * **The exact length is visible.** The 32-bit prefix is plaintext — it has
      to be, the reader needs it — so anyone who can see the bytes of an
      envelope knows exactly how many bytes of text are inside it. Padding
      hides a length only from someone who sees *which bucket* a post was
      stored in and nothing else; it hides nothing from someone holding the
      envelope. That is accepted by design: the bucket is already public (the
      server labels every post with it), and encrypting the prefix would hide
      the length from nobody who can see padding.
    * **Nothing here is encryption.** The body travels and is stored in the
      clear. The padding is not a cipher, the length prefix is not a MAC, and
      `decode/1` is validation, not authentication — any client can build any
      envelope. Confidentiality belongs to the transport, not to this module.

  Padding is validated, not trusted: the length prefix may not run past the
  bucket and every padding byte must be zero. A body that is not exactly one of
  the four bucket sizes is refused outright, so a client cannot send a size
  that is unique to itself.

  Anonymity is per bucket (§4.1, §4.2): a 250-byte post and a 300-byte post
  both travel in the 256 B bucket and join the same pool. The bucket stays
  visible on the published post, so the bucket — never the body — is the unit
  of cover traffic.
  """

  @header_bytes 4
  @small_max 256
  @medium_max 4096
  @large_max 16_384

  @buckets [@small_max, 1024, @medium_max, @large_max]

  @typedoc "Envelope size, in bytes, as it appears on the wire."
  @type bucket :: 256 | 1024 | 4096 | 16_384

  @doc "The envelope sizes the server accepts, smallest first."
  @spec buckets() :: [bucket()]
  def buckets, do: @buckets

  @doc """
  Pads `payload` into the smallest bucket that can hold it.

  Returns the padded envelope together with its bucket so the caller can label
  the post without measuring the result again. A payload that does not fit the
  largest bucket is refused; there is no fifth size.
  """
  @spec encode(binary()) :: {:ok, binary(), bucket()} | {:error, :too_large}
  def encode(payload) when is_binary(payload) do
    size = byte_size(payload)

    case Enum.find(@buckets, &(size <= &1 - @header_bytes)) do
      nil -> {:error, :too_large}
      bucket -> {:ok, pad(payload, size, bucket), bucket}
    end
  end

  @doc """
  Pads into one named bucket instead of the smallest that fits.

  Chat uses this: a room frame is always 1024 bytes, because a frame whose size
  follows its text tells the reader how long the text was, and because a decoy
  can only be mistaken for a real frame if both are the same size.
  """
  @spec encode(binary(), pos_integer()) :: {:ok, binary(), pos_integer()} | {:error, :too_large}
  def encode(payload, bucket) when is_binary(payload) and bucket in @buckets do
    size = byte_size(payload)

    if size <= bucket - @header_bytes do
      {:ok, pad(payload, size, bucket), bucket}
    else
      {:error, :too_large}
    end
  end

  @doc """
  Reads one envelope back.

  Rejects a size that is not exactly a bucket (`:bad_bucket`), a length prefix
  that runs past the bucket (`:bad_length`) and padding that is not all zero
  (`:bad_padding`). An empty body — length zero, all-zero padding — is valid.
  """
  @spec decode(binary()) ::
          {:ok, binary(), bucket()} | {:error, :bad_bucket | :bad_length | :bad_padding}
  def decode(bin) when is_binary(bin) do
    case bucket_of(byte_size(bin)) do
      :error ->
        {:error, :bad_bucket}

      {:ok, bucket} ->
        case bin do
          <<len::unsigned-big-32, rest::binary>> when len <= bucket - @header_bytes ->
            <<payload::binary-size(^len), padding::binary>> = rest

            if zero?(padding) do
              {:ok, payload, bucket}
            else
              {:error, :bad_padding}
            end

          <<_len::unsigned-big-32, _rest::binary>> ->
            {:error, :bad_length}
        end
    end
  end

  @doc """
  Reads the payload out of a stored body, or refuses.

  `{:ok, payload}` when the body is a valid envelope, `{:error, :bad_envelope}`
  when it is not. There is deliberately no fallback to the raw bytes: a body
  that does not decode was not written by this server, and handing it back
  unchanged would serve the padding-or-garbage exactly as stored, under a 200.
  A reader that cannot decode should answer "not found", not "here it is".
  """
  @spec payload(binary()) :: {:ok, binary()} | {:error, :bad_envelope}
  def payload(body) when is_binary(body) do
    case decode(body) do
      {:ok, payload, _bucket} -> {:ok, payload}
      {:error, _reason} -> {:error, :bad_envelope}
    end
  end

  ## Response bodies

  # A response is padded to a fixed size for the same reason a write is, but the
  # sizes are not the envelope buckets: an error is one short constant string, a
  # feed page is a page of posts. Using the 16 KB envelope bucket for both meant
  # every `{"error":"not_found"}` cost 16 KB on the wire (F-20).
  @error_bucket 256
  @feed_bucket 4096

  @doc """
  Pads an error or ack body into the 256 B response bucket.

  The padded bytes are the JSON followed by spaces — legal JSON whitespace, so
  a client parses the body unchanged. `{:error, :too_large}` means the caller
  built an error document that does not belong in this bucket; the error
  constants in the router are all under thirty bytes.
  """
  @spec encode_error(binary()) :: {:ok, binary(), 256} | {:error, :too_large}
  def encode_error(json) when is_binary(json), do: pad_response(json, @error_bucket)

  @doc """
  Pads a feed page into the 4 KB response bucket.

  A page is built to fit this bucket (whole posts only, see the router); a page
  that does not fit is refused so the caller pages earlier instead of sending a
  response twice the size of every other one.
  """
  @spec encode_feed(binary()) :: {:ok, binary(), 4096} | {:error, :too_large}
  def encode_feed(json) when is_binary(json), do: pad_response(json, @feed_bucket)

  defp pad_response(json, bucket) do
    size = byte_size(json)

    if size <= bucket do
      {:ok, json <> :binary.copy(" ", bucket - size), bucket}
    else
      {:error, :too_large}
    end
  end

  defp pad(payload, size, bucket) do
    padding = bucket - @header_bytes - size
    <<size::unsigned-big-32, payload::binary, 0::size(padding)-unit(8)>>
  end

  defp bucket_of(size) when size in @buckets, do: {:ok, size}
  defp bucket_of(_size), do: :error

  # `==` on binaries walks until it finds a difference, so how long it takes
  # reports the position of the first non-zero padding byte. `:crypto.hash_equals/2`
  # compares two equal-length binaries in time independent of their content.
  # `padding` and the zero block are the same length by construction, so the
  # size check inside `hash_equals/2` is always satisfied.
  defp zero?(padding), do: :crypto.hash_equals(padding, :binary.copy(<<0>>, byte_size(padding)))
end
