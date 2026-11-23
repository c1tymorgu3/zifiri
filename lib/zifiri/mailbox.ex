defmodule Zifiri.Mailbox do
  @moduledoc """
  The sealed-sender envelope store for 1:1 messages (plan §P0-2, scope v5 §1:1).

  A sender drops a 4096-byte sealed blob addressed to a mailbox. The address is
  a `mailbox_id`: **16 random bytes the recipient's device generated** with
  `crypto.getRandomValues` and put into its identity row. The server learns
  that label and nothing else. It cannot read the blob (the key comes from an
  ephemeral ECDH exchange, derived client-side), it cannot say who wrote it,
  and there is no column in which a sender could be recorded:
  `test/mailbox_test.exs` reads `PRAGMA table_info` and fails on any column
  that is not one of the five.

  ## Why a random id and not `HMAC(pepper, pk)`

  The previous scheme derived the address as
  `HMAC-SHA256(pepper, "zifiri/mailbox/v1" <> recipient_pk)[0..15]`. The client
  does not hold the pepper, so the only way it could obtain that address was to
  send its public key to the API and read the tag back — which handed the
  server the exact key the tag was supposed to hide, and made any two rows with
  the same tag provably one key (review v5 R5-06).

  A random 128-bit label has none of those properties:

    * the server never sees, receives, derives or stores a public key — no
      function here takes one, and there is no code path that could;
    * two ids are unrelated by construction, so a collision is a birthday
      accident (about n²/2¹²⁹), not a consequence of two users sharing a key.
      At ten thousand mailboxes the chance is around 3·10⁻³¹; the ceiling is
      the number of mailboxes, not the id;
    * nothing about the id is guessable from a key, a seed, or another id.

  The id is stored **raw** (16 bytes, unhashed, untruncated). Hashing a value
  that is already uniform random buys nothing, and storing exactly what the
  client chose means the client can verify its own mailbox without trusting a
  derivation it cannot see.

  ## Pepper

  Nothing in this module touches the pepper. `Zifiri.Owner.pepper/0` remains
  for `owner_hash` (posts, listings) and for nothing else.

  Tag derivation is gone, so **pepper rotation no longer applies to this
  store**: there is no derived address that a new pepper would move, no
  versioned tag to keep, and no re-encryption window to hold open. Envelopes
  addressed before a rotation stay readable after it, because their address was
  chosen by the recipient, not computed from a server secret. Rotating the
  pepper re-keys `owner_hash` and leaves `mailbox_envelopes` untouched.

  ## The cursor is an id, not a millisecond

  `fetch/3` pages by `id > since`, ascending. A timestamp cursor would be
  wrong here: several envelopes routinely land in the same millisecond, so a
  client paging by `created_ms` would either re-read them or skip the ones it
  did not see. Ids are `AUTOINCREMENT` (see the migration) precisely so they
  are monotonic and never reused after a delete.

  ## TTL

  72 hours. Expired envelopes are invisible to `fetch/3` immediately and are
  deleted by `Zifiri.Mailbox.Sweeper` within five minutes. The sweeper deletes
  by `expires_ms` alone, so it never needs to know whose row it is.
  """

  import Ecto.Query

  alias Zifiri.Bucket
  alias Zifiri.Mailbox.Envelope
  alias Zifiri.Repo

  @envelope_bytes 4096
  @id_bytes 16
  @ttl_ms 72 * 60 * 60 * 1000
  @page_max 200
  @zero_id <<0::128>>

  @typedoc "One page of a mailbox: the envelopes and the cursor for the next one."
  @type page :: %{
          envelopes: [
            %{
              id: pos_integer(),
              envelope: binary(),
              created_ms: integer(),
              expires_ms: integer()
            }
          ],
          cursor: non_neg_integer(),
          more: boolean()
        }

  @typedoc "16 random bytes, chosen by the recipient."
  @type mailbox_id :: <<_::128>>

  @doc """
  Queues one envelope for `mailbox_id`.

  `mailbox_id` is the recipient's 16 random bytes. The wire forms are accepted
  too — 32 hex characters, or base64 (padded or not, standard or URL-safe) — so
  an HTTP layer can pass a URL segment straight through without its own
  decoding rules. `envelope` must be exactly 4096 bytes; anything else is
  refused before it reaches the queue, and the table's trigger refuses it again
  if a handler ever writes an off-size blob.

  Delivery does **not** write the row. The envelope goes into
  `Zifiri.Bucket` as `{:mailbox, tag, envelope, ttl}` and
  `Zifiri.Bucket.Publisher` writes it when the bucket closes, completing the
  batch to `Zifiri.Bucket.target/0` with decoys. There is no direct write path:
  a row that was written without a bucket would be a row with an arrival clock
  of its own. The caller therefore gets `{:ok, :queued}`, not a row id; the
  cursor id is assigned at publish time and is only visible through `fetch/3`.

  Options:

    * `:ttl_ms` — lifetime, default 72 h;
    * `:now_ms` — clock override, for tests.

  Returns `{:ok, :queued}`.
  """
  @spec deliver(binary(), binary(), keyword()) ::
          {:ok, :queued}
          | {:error, :bad_mailbox_id | :bad_envelope | :bad_ttl}
  def deliver(mailbox_id, envelope, opts \\ []) do
    with {:ok, id} <- decode_id(mailbox_id),
         :ok <- check_envelope(envelope),
         {:ok, ttl} <- check_ttl(Keyword.get(opts, :ttl_ms, @ttl_ms)) do
      now = Keyword.get(opts, :now_ms, now_ms())

      :ok = Bucket.add({:mailbox, id, envelope, ttl}, now)
      {:ok, :queued}
    end
  end

  @doc """
  Reads one page of `mailbox_id`'s mailbox.

  At most 200 envelopes, oldest first, skipping expired ones. `since` is the
  `cursor` from the previous page (0 for the first); the result carries the
  next `cursor` and `more`, which says whether the client should ask again
  immediately.

  A mailbox id that holds no mail gets an empty page, not an error and not a
  different shape: the response must not distinguish "no mail" from "not
  yours". Every 16-byte value is a mailbox, so there is no such thing as a
  mailbox that does not exist — only one that is empty.
  """
  @spec fetch(binary(), non_neg_integer(), keyword()) ::
          {:ok, page()} | {:error, :bad_mailbox_id | :bad_cursor}
  def fetch(mailbox_id, since \\ 0, opts \\ []) do
    with {:ok, id} <- decode_id(mailbox_id),
         {:ok, since} <- check_cursor(since) do
      now = Keyword.get(opts, :now_ms, now_ms())
      limit = page_limit(Keyword.get(opts, :limit, @page_max))

      # One row over the limit: its presence is how we know there is another
      # page without a second count query.
      rows =
        Repo.all(
          from e in Envelope,
            where: e.mailbox_id == ^id and e.id > ^since and e.expires_ms > ^now,
            order_by: [asc: e.id],
            limit: ^(limit + 1),
            select: map(e, [:id, :envelope, :created_ms, :expires_ms])
        )

      more = length(rows) > limit
      page = Enum.take(rows, limit)

      cursor =
        case List.last(page) do
          nil -> since
          %{id: id} -> id
        end

      {:ok, %{envelopes: page, cursor: cursor, more: more}}
    end
  end

  @doc """
  Deletes the envelopes the caller has read.

  Scoped by `mailbox_id`, which is not optional on purpose. Ids are sequential
  integers, so a bare `ack(ids)` would let any caller delete another mailbox's
  mail — a silent denial of service — and read the returned count as an oracle
  for how much mail sits in an id range. A random address does not change that
  arithmetic, so the scope stays: `ack` is a statement about a mailbox the
  caller can already read.

  Returns `{:ok, deleted_count}`.
  """
  @spec ack(binary(), [pos_integer()] | pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :bad_mailbox_id | :bad_cursor}
  def ack(mailbox_id, ids) do
    with {:ok, id} <- decode_id(mailbox_id),
         {:ok, ids} <- check_ids(ids) do
      {deleted, _} =
        Repo.delete_all(
          from e in Envelope,
            where: e.mailbox_id == ^id and e.id in ^ids
        )

      {:ok, deleted}
    end
  end

  @doc """
  Deletes every envelope whose `expires_ms` has passed. Returns the count.

  Called by `Zifiri.Mailbox.Sweeper` every five minutes; callable directly by
  tests and by an operator draining a backlog.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ now_ms()) do
    {deleted, _} = Repo.delete_all(from e in Envelope, where: e.expires_ms <= ^now)
    deleted
  end

  @doc """
  Normalises a mailbox id to its 16 raw bytes.

  Accepts the raw bytes, 32 hex characters (either case), or base64 — standard
  or URL-safe, padded or not. Clients differ, and the cost of accepting all of
  them is one `or`; what the store writes is always the same 16 bytes.

  The all-zero id is refused. It is not weaker than any other value, but it is
  what a caller produces when it forgot to fill the field in, and a shared
  constant address would put every such caller in one mailbox.
  """
  @spec decode_id(term()) :: {:ok, mailbox_id()} | {:error, :bad_mailbox_id}
  def decode_id(id) when is_binary(id) and byte_size(id) == @id_bytes,
    do: check_id(id)

  def decode_id(id) when is_binary(id) and byte_size(id) == 2 * @id_bytes do
    case Base.decode16(id, case: :mixed) do
      {:ok, raw} -> check_id(raw)
      :error -> decode_b64_id(id)
    end
  end

  def decode_id(id) when is_binary(id), do: decode_b64_id(id)
  def decode_id(_), do: {:error, :bad_mailbox_id}

  @doc """
  The wire form of a mailbox id: URL-safe base64 without padding.

  This is the form an HTTP layer should put in a path segment or a JSON body;
  `decode_id/1` accepts it back, along with the raw bytes and hex.
  """
  @spec encode_id(mailbox_id()) :: binary()
  def encode_id(<<_::128>> = id), do: Base.url_encode64(id, padding: false)

  @doc """
  A fresh 128-bit mailbox id from the platform CSPRNG.

  The **client** generates the id that matters — it must exist before the
  server ever sees it, and the server must never be able to derive it. This is
  for tests, the dev console, and any caller without a CSPRNG of its own.
  """
  @spec new_id() :: mailbox_id()
  def new_id do
    case :crypto.strong_rand_bytes(@id_bytes) do
      @zero_id -> new_id()
      id -> id
    end
  end

  @doc "The length of a mailbox id, in bytes."
  @spec id_bytes() :: 16
  def id_bytes, do: @id_bytes

  @doc "The bucket size a stored envelope must have, in bytes."
  @spec envelope_bytes() :: 4096
  def envelope_bytes, do: @envelope_bytes

  @doc "The default lifetime of a stored envelope, in milliseconds."
  @spec ttl_ms() :: 259_200_000
  def ttl_ms, do: @ttl_ms

  @doc "The largest page `fetch/3` will return, whatever `:limit` asks for."
  @spec page_max() :: 200
  def page_max, do: @page_max

  # -- internals --------------------------------------------------------------

  defp check_id(raw)
       when is_binary(raw) and byte_size(raw) == @id_bytes and raw != @zero_id,
       do: {:ok, raw}

  defp check_id(_), do: {:error, :bad_mailbox_id}

  defp check_envelope(envelope)
       when is_binary(envelope) and byte_size(envelope) == @envelope_bytes,
       do: :ok

  defp check_envelope(_), do: {:error, :bad_envelope}

  defp check_ttl(ttl) when is_integer(ttl) and ttl > 0, do: {:ok, ttl}
  defp check_ttl(_), do: {:error, :bad_ttl}

  defp check_cursor(nil), do: {:ok, 0}
  defp check_cursor(since) when is_integer(since) and since >= 0, do: {:ok, since}
  defp check_cursor(_), do: {:error, :bad_cursor}

  defp check_ids(nil), do: {:ok, []}

  defp check_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :bad_cursor}
  end

  defp check_ids(id) when is_integer(id) and id > 0, do: {:ok, [id]}
  defp check_ids(_), do: {:error, :bad_cursor}

  defp page_limit(nil), do: @page_max
  defp page_limit(n) when is_integer(n) and n > 0, do: min(n, @page_max)
  defp page_limit(_), do: @page_max

  # Clients send padded standard base64, unpadded standard, URL-safe padded and
  # URL-safe unpadded depending on the library. Accepting all four costs one
  # `or` and avoids a class of "works in the browser, 400 from the app" bugs.
  defp decode_b64_id(text) do
    with :error <- Base.decode64(text),
         :error <- Base.decode64(text, padding: false),
         :error <- Base.url_decode64(text, padding: false),
         :error <- Base.url_decode64(text) do
      {:error, :bad_mailbox_id}
    else
      {:ok, raw} -> check_id(raw)
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
