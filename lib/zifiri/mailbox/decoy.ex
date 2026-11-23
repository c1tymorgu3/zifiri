defmodule Zifiri.Mailbox.Decoy do
  @moduledoc """
  A 1:1 bucket filler indistinguishable from a real envelope.

  The observer of a mailbox write must not be able to tell a real envelope from
  the ones that complete the bucket to 120. A decoy therefore has the same
  shape as a real row, byte for byte:

    * `mailbox_id` is 16 fresh random bytes — a label nobody holds a key for;
    * `envelope` is exactly `Zifiri.Mailbox.envelope_bytes/0` random bytes, so
      AEAD opening fails for every recipient (there is no key to try);
    * `ttl` is the same lifetime the real envelopes in the batch carry.

  There is no marker, no flag and no column that says "decoy": the table stores
  the same five columns for both, and `mix test` checks that this module's
  output is the same size as a real envelope.

  `:rand` is injectable (`(byte_count) -> binary`) so a test can seed it; the
  production default is `:crypto.strong_rand_bytes/1`.
  """

  alias Zifiri.Mailbox

  @id_bytes 16

  @typedoc "A random mailbox id, a full-size random envelope, and a lifetime."
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
      envelope: rand.(Mailbox.envelope_bytes()),
      ttl: Keyword.get(opts, :ttl_ms, Mailbox.ttl_ms())
    }
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
