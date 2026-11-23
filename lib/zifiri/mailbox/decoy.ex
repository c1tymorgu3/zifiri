defmodule Zifiri.Mailbox.Decoy do
  @moduledoc """
  A 1:1 bucket filler indistinguishable from a real envelope.

  The observer of a mailbox write must not be able to tell a real envelope from
  the ones that complete the bucket to 120. A decoy therefore has the same
  shape as a real row, byte for byte:

    * `mailbox_id` is 16 fresh random bytes — a label nobody holds a key for;
    * `envelope` is a real frame: `Zifiri.Envelope.encode/2` over a random
      payload, so it is exactly `Zifiri.Mailbox.envelope_bytes/0` bytes with a
      valid 32-bit length prefix, the payload, and a zero tail. Raw noise would
      not be an envelope at all — `Envelope.decode/1` would answer
      `:bad_length` on most of it — and the prefix is the first thing a
      classifier would look at. Here `decode/1` answers `{:ok, payload, 4096}`
      for a decoy exactly as it does for a real frame;
    * `ttl` is the same lifetime the real envelopes in the batch carry.

  The payload is random and its length varies the way a real message's does
  (1 … bucket − 4), so neither the body nor the visible length prefix separates
  the two. AEAD opening still fails for every recipient: the ciphertext under
  the payload was never sealed to a key anyone holds.

  There is no marker, no flag and no column that says "decoy": the table stores
  the same five columns for both. This is 1:1 cover only — a plaintext room
  publishes no decoys (`docs/claims.md` C-50).

  `:rand` is injectable (`(byte_count) -> binary`) so a test can seed it; the
  production default is `:crypto.strong_rand_bytes/1`.
  """

  alias Zifiri.Mailbox

  @id_bytes 16

  @typedoc "A random mailbox id, a full-size sealed envelope, and a lifetime."
  @type t :: %{
          mailbox_id: <<_::128>>,
          envelope: binary(),
          ttl: non_neg_integer()
        }

  @doc """
  Builds one decoy.

  Options:

    * `:ttl_ms` — lifetime, default `Zifiri.Mailbox.ttl_ms/0`;
    * `:rand` — `(n) -> binary`, default `:crypto.strong_rand_bytes/1`.
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    rand = Keyword.get(opts, :rand, &:crypto.strong_rand_bytes/1)

    %{
      mailbox_id: random_id(rand),
      envelope: random_envelope(rand),
      ttl: Keyword.get(opts, :ttl_ms, Mailbox.ttl_ms())
    }
  end

  # The envelope is the same frame a real row carries — 32-bit length, payload,
  # zero tail — built by the encoder the server uses, never by hand. A payload
  # of 1..bucket-4 bytes matches the spread of real messages, and the two bytes
  # used to pick it come from the same `:rand` seam so a seeded test stays
  # deterministic.
  defp random_envelope(rand) do
    bucket = Mailbox.envelope_bytes()
    payload_bytes = rem(:binary.decode_unsigned(rand.(2)), bucket - 4) + 1
    {:ok, envelope, ^bucket} = Zifiri.Envelope.encode(rand.(payload_bytes), bucket)

    envelope
  end

  # The all-zero id is refused by `Mailbox.decode_id/1`, so a decoy must never
  # carry it; the chance is 2⁻¹²⁸, but looping costs nothing and keeps the
  # invariant true for any `:rand` a test injects.
  defp random_id(rand) do
    case rand.(@id_bytes) do
      <<0::128>> -> random_id(rand)
      id -> id
    end
  end
end
