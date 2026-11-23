defmodule Zifiri.Listings do
  @moduledoc """
  The listing plane: durable, public posts with plaintext metadata.

  A listing is the one place in Zifiri where the server is allowed to *read*
  what a user wrote. Title, price, currency and category are stored in the
  clear because they are what a buyer searches; only the description is an
  envelope, padded to a bucket exactly like a chat message. The trade is made
  once, here, and stated plainly: a listing is public and indexed, a chat
  message is not.

  ## What is deliberately absent

    * No identity. Ownership is `Zifiri.Owner.hash/1` of a 32-byte token — a
      per-write HMAC the server cannot reverse. `owner_hash` is not unique:
      one owner may run several listings, and a unique index would turn the
      second `create/1` into a signal about the first.
    * No sub-day time. `created_day` is a `Date`; there is no `inserted_at`,
      so the table cannot be read as a timeline of one seller's posts.
    * No counter, no view count, no "last seen".

  ## Every write costs a proof

  `create/1`, `update/3`, `close/3` and `erase/2` each redeem a
  `Zifiri.Pow.Challenge`. The challenge is bound to the owner and to the bytes
  being written, so a proof for one listing cannot be replayed for another:

    * `create/1`, `update/3` — payload hash is `sha256(envelope)`, the same
      binding the write path already uses.
    * `close/3` — payload hash is `close_subject/1`, a function of the ref.
    * `erase/2` — payload hash is `erase_subject/1`, a function of the owner
      hash.

  ## Search

  `list/1` filters with SQLite's `LIKE`, which is case-insensitive for ASCII
  and is the adapter's spelling of `ilike` — `ecto_sqlite3` raises on Ecto's
  `ilike/2` outright, so asking for it would be a crash, not a feature. The
  search term's `%` and `_` are stripped before the pattern is built, so a
  caller cannot widen its own query into a full scan of every listing.
  """

  alias Zifiri.Envelope
  alias Zifiri.Listings.Listing
  alias Zifiri.Owner
  alias Zifiri.Pow.Challenge
  alias Zifiri.Repo

  import Ecto.Query

  @title_max 120
  @category_max 32
  @page 30
  @max_page 30
  @currency ~r/^[A-Z]{3}$/

  @typedoc "Why a listing write was refused."
  @type error ::
          :bad_owner
          | :bad_envelope
          | :bad_utf8
          | :bad_pow
          | :bad_title
          | :bad_price
          | :bad_currency
          | :bad_category
          | :not_found
          | :forbidden
          | :closed
          | :invalid

  ## Writes

  @doc """
  Creates a listing.

  `attrs` carries `:owner_token` (32 raw bytes or base64), `:body` (an envelope
  built by `Zifiri.Envelope.encode/1`), `:title`, `:currency`, `:category`,
  optional `:price_cents`, and the proof: `:challenge_id`, `:nonce`, `:bits`.

  Metadata is validated before the proof is redeemed, so a malformed request
  does not burn a challenge the client would have to grind again.
  """
  @spec create(map()) :: {:ok, Listing.t()} | {:error, error()}
  def create(attrs) when is_map(attrs) do
    with {:ok, token} <- token(attrs),
         {:ok, owner_hash} <- owner_hash(token),
         {:ok, envelope} <- envelope(attrs),
         {:ok, _payload} <- payload(envelope),
         {:ok, fields} <- metadata(attrs, %{}),
         :ok <- redeem(owner_hash, :crypto.hash(:sha256, envelope), attrs) do
      row =
        Map.merge(fields, %{
          body: envelope,
          owner_hash: owner_hash,
          status: "open",
          created_day: Date.utc_today()
        })

      insert(row)
    end
  end

  @doc """
  Replaces the body and the metadata of a listing the token owns.

  The proof covers the new envelope, so the write that lands is the write that
  was paid for. `created_day`, `owner_hash` and `status` are not updatable
  fields: an update cannot move a listing to another owner or another day.
  """
  @spec update(term(), binary(), map()) :: {:ok, Listing.t()} | {:error, error()}
  def update(ref, token, attrs) when is_map(attrs) do
    with {:ok, id} <- ref_id(ref),
         %Listing{} = listing <- Repo.get(Listing, id) || {:error, :not_found},
         {:ok, token} <- token(%{owner_token: token}),
         {:ok, owner_hash} <- owner_hash(token),
         :ok <- owns(listing, owner_hash),
         :ok <- open(listing),
         {:ok, envelope} <- envelope(attrs),
         {:ok, _payload} <- payload(envelope),
         {:ok, fields} <- metadata(attrs, listing),
         :ok <- redeem(owner_hash, :crypto.hash(:sha256, envelope), attrs) do
      listing
      |> Listing.changeset(Map.merge(fields, %{body: envelope}))
      |> Repo.update()
      |> result()
    end
  end

  @doc """
  Closes a listing the token owns.

  Closing is the seller-facing delete: the row stays so `get/1` still answers
  the owner, but `list/1` stops serving it. Closing twice is not an error — the
  second call answers `{:ok, listing}` without spending a proof, because there
  is nothing left to write.
  """
  @spec close(term(), binary(), map()) :: {:ok, Listing.t()} | {:error, error()}
  def close(ref, token, proof \\ %{}) when is_map(proof) do
    with {:ok, id} <- ref_id(ref),
         %Listing{} = listing <- Repo.get(Listing, id) || {:error, :not_found},
         {:ok, token} <- token(%{owner_token: token}),
         {:ok, owner_hash} <- owner_hash(token),
         :ok <- owns(listing, owner_hash) do
      case listing.status do
        "closed" ->
          {:ok, decode(listing)}

        _ ->
          with :ok <- redeem(owner_hash, close_subject(id), proof) do
            listing
            |> Listing.changeset(%{status: "closed"})
            |> Repo.update()
            |> result()
          end
      end
    end
  end

  @doc """
  Physically deletes every listing the token owns.

  This is the level-1 wipe: one `DELETE`, no tombstone, no `closed` row left to
  say the listing existed. The proof is bound to `erase_subject/1` so a proof
  harvested from a listing write cannot be reused to wipe an account.
  """
  @spec erase(binary(), map()) :: {:ok, non_neg_integer()} | {:error, error()}
  def erase(token, proof \\ %{}) when is_map(proof) do
    with {:ok, token} <- token(%{owner_token: token}),
         {:ok, owner_hash} <- owner_hash(token),
         :ok <- redeem(owner_hash, erase_subject(owner_hash), proof) do
      {count, _} = Repo.delete_all(from l in Listing, where: l.owner_hash == ^owner_hash)
      {:ok, count}
    end
  end

  @doc "The payload hash a `close/3` proof must cover."
  @spec close_subject(term()) :: binary()
  def close_subject(ref) do
    :crypto.hash(:sha256, "listing:close:" <> to_string(ref))
  end

  @doc "The payload hash an `erase/2` proof must cover."
  @spec erase_subject(binary()) :: binary()
  def erase_subject(owner_hash) when is_binary(owner_hash) do
    :crypto.hash(:sha256, "listing:erase:" <> owner_hash)
  end

  ## Reads

  @doc """
  Reads one listing, open or closed.

  The body is decoded from its envelope: a caller never sees padding, and a
  body that does not decode is not served at all (`nil`), because handing back
  the stored bytes would be serving garbage under a 200.
  """
  @spec get(term()) :: Listing.t() | nil
  def get(ref) do
    with {:ok, id} <- ref_id(ref),
         %Listing{} = listing <- Repo.get(Listing, id) do
      decode(listing)
    else
      _ -> nil
    end
  end

  @doc """
  One page of open listings, newest first.

  Options:

    * `:category` — exact match on the category token.
    * `:search` — case-insensitive substring of the title (ASCII; SQLite's
      `LIKE`).
    * `:before` — a listing ref; the page starts strictly after it, using
      `(created_day, id)` so a page boundary inside one day is exact.
    * `:limit` — 1..30, default 30. A page is never larger than the feed
      bucket can carry.

  A cursor that names no listing yields an empty page: the caller has paged
  past a row that was erased, and the honest answer is "nothing older than
  that", not a page from the top.
  """
  @spec list(keyword()) :: [Listing.t()]
  def list(opts \\ []) do
    opts
    |> base_query()
    |> by_category(Keyword.get(opts, :category))
    |> by_search(Keyword.get(opts, :search))
    |> before_cursor(Keyword.get(opts, :before))
    |> Repo.all()
  end

  defp base_query(opts) do
    limit = page_size(Keyword.get(opts, :limit))

    from l in Listing,
      where: l.status == "open",
      order_by: [desc: l.created_day, desc: l.id],
      limit: ^limit
  end

  defp page_size(nil), do: @page
  defp page_size(n) when is_integer(n) and n > 0, do: min(n, @max_page)
  defp page_size(_), do: @page

  defp by_category(query, nil), do: query
  defp by_category(query, ""), do: query

  defp by_category(query, category) when is_binary(category),
    do: where(query, [l], l.category == ^String.trim(category))

  defp by_category(query, _), do: query

  defp by_search(query, nil), do: query
  defp by_search(query, ""), do: query

  defp by_search(query, term) when is_binary(term) do
    # `%` and `_` are pattern syntax, not text: stripping them keeps a caller
    # from turning a title search into a scan of every listing.
    needle =
      term
      |> String.trim()
      |> String.replace(["%", "_"], "")
      |> String.trim()

    case needle do
      "" -> where(query, [l], false)
      needle -> where(query, [l], like(l.title, ^"%#{needle}%"))
    end
  end

  defp by_search(query, _), do: query

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, ref) do
    with {:ok, id} <- ref_id(ref),
         %Listing{created_day: day, id: id} <- Repo.get(Listing, id) do
      where(query, [l], l.created_day < ^day or (l.created_day == ^day and l.id < ^id))
    else
      _ -> where(query, [l], false)
    end
  end

  ## Pieces

  defp insert(row) do
    %Listing{}
    |> Listing.changeset(row)
    |> Repo.insert()
    |> result()
  end

  defp result({:ok, listing}) do
    case decode(listing) do
      nil -> {:error, :bad_envelope}
      listing -> {:ok, listing}
    end
  end

  defp result({:error, %Ecto.Changeset{}}), do: {:error, :invalid}

  defp decode(%Listing{body: body} = listing) when is_binary(body) do
    case Envelope.payload(body) do
      {:ok, payload} -> %{listing | body: payload}
      {:error, :bad_envelope} -> nil
    end
  end

  defp decode(%Listing{} = listing), do: listing

  defp token(attrs) do
    case fetch(attrs, :owner_token) do
      {:ok, raw} -> token_value(raw)
      :error -> {:error, :bad_owner}
    end
  end

  defp token_value(raw) when is_binary(raw) and byte_size(raw) == 32, do: {:ok, raw}

  defp token_value(raw) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, bin} when byte_size(bin) == 32 -> {:ok, bin}
      _ -> {:error, :bad_owner}
    end
  end

  defp token_value(_), do: {:error, :bad_owner}

  defp owner_hash(token) do
    if Owner.valid?(token), do: {:ok, Owner.hash(token)}, else: {:error, :bad_owner}
  end

  defp owns(%Listing{owner_hash: hash}, hash), do: :ok
  defp owns(%Listing{}, _other), do: {:error, :forbidden}

  defp open(%Listing{status: "open"}), do: :ok
  defp open(%Listing{}), do: {:error, :closed}

  defp envelope(attrs) do
    with {:ok, body} <- fetch(attrs, :body),
         {:ok, _payload, _bucket} <- Envelope.decode(body) do
      {:ok, body}
    else
      _ -> {:error, :bad_envelope}
    end
  end

  defp payload(envelope) do
    case Envelope.payload(envelope) do
      {:ok, payload} -> if String.valid?(payload), do: {:ok, payload}, else: {:error, :bad_utf8}
      {:error, :bad_envelope} -> {:error, :bad_envelope}
    end
  end

  defp metadata(attrs, base) do
    title = pick(attrs, :title, base)
    price = pick(attrs, :price_cents, base)
    currency = pick(attrs, :currency, base)
    category = pick(attrs, :category, base)

    with :ok <- title?(title),
         :ok <- price?(price),
         :ok <- currency?(currency),
         :ok <- category?(category) do
      {:ok,
       %{
         title: String.trim(title),
         price_cents: price,
         currency: String.upcase(currency),
         category: String.trim(category)
       }}
    end
  end

  defp title?(title) when is_binary(title) do
    title = String.trim(title)

    cond do
      not String.valid?(title) -> {:error, :bad_title}
      title == "" -> {:error, :bad_title}
      String.length(title) > @title_max -> {:error, :bad_title}
      true -> :ok
    end
  end

  defp title?(_), do: {:error, :bad_title}

  defp price?(nil), do: :ok
  defp price?(price) when is_integer(price) and price >= 0, do: :ok
  defp price?(_), do: {:error, :bad_price}

  defp currency?(currency) when is_binary(currency) do
    if Regex.match?(@currency, String.upcase(currency)), do: :ok, else: {:error, :bad_currency}
  end

  defp currency?(_), do: {:error, :bad_currency}

  defp category?(category) when is_binary(category) do
    category = String.trim(category)

    cond do
      not String.valid?(category) -> {:error, :bad_category}
      category == "" -> {:error, :bad_category}
      String.length(category) > @category_max -> {:error, :bad_category}
      true -> :ok
    end
  end

  defp category?(_), do: {:error, :bad_category}

  defp redeem(owner_hash, payload_hash, proof) do
    with {:ok, id} <- fetch(proof, :challenge_id),
         {:ok, nonce} <- fetch(proof, :nonce),
         {:ok, bits} <- fetch(proof, :bits),
         :ok <- Challenge.redeem(owner_hash, payload_hash, id, nonce, bits) do
      :ok
    else
      _ -> {:error, :bad_pow}
    end
  end

  defp ref_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp ref_id(ref) when is_binary(ref), do: ref_id(Integer.parse(ref))
  defp ref_id({id, ""}) when is_integer(id) and id > 0, do: {:ok, id}
  defp ref_id(_), do: {:error, :not_found}

  defp fetch(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp fetch(_attrs, _key), do: :error

  defp pick(attrs, key, base) do
    case fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(base, key)
    end
  end
end
