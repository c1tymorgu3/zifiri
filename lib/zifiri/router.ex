defmodule Zifiri.Router do
  @moduledoc """
  HTTP surface for scope v5: listings, the sealed-sender mailbox, rooms, proof
  of work, and "yok ol".

  The forum routes (`/api/posts`, `/api/feed`, `/api/post/:ref`) and the modules
  behind them are gone: scope v5 has three planes and no forum, and the `posts`
  table is dropped by a migration. `/api/report` and `/mod/*` stay declared but
  are bound only when `Zifiri.Mod` is loaded — the moderation plane was written
  against the forum row (`parent_id`, `mod_state`), so it has no target until it
  is ported to a v5 table. When the module is absent the routes answer the same
  constant 404 as any unknown path.

  ## What every API response shares

    * **One size.** Every `/api` answer is padded with trailing spaces to
      16 384 bytes. A `201`, a `403` and an empty page are the same number of
      bytes on the wire, so a response cannot be measured to learn whether a
      write landed or what it contained (§4.1, §4.2).
    * **`cache-control: no-store`.** A cached listing page or mailbox page is a
      record of what someone read and when.
    * **Constant error text.** A refusal is `{"error":"refused"}`; a missing
      row is `{"error":"not_found"}`. No field of the request is echoed.
    * **Paged reads stop at the bucket.** A page is whole items only: a
      truncated envelope is not an envelope, so the page ends and the client
      pages with the cursor it already has.

  ## Where an owner token may travel

  A token is the capability to rewrite or erase what it owns. It is read from
  exactly two places: the `owner_token` field of the JSON body, or the
  `x-zifiri-owner` request header (base64, 32 bytes) for a bodyless request
  such as `DELETE /api/listings/:ref`.

  It is **never** read from the query string. A query string ends up in an
  access log, a proxy trace, a browser history and a `Referer`; a token there
  is a token on disk somewhere. The one thing a query string may carry is a
  cursor (`before`, `since`) or a public hash (`payload_hash`).

  ## Bodies are bytes

  A listing description leaves as `body_b64`; a mailbox envelope leaves as
  `envelope_b64` (the full 4096-byte frame, so size still says nothing); a room
  message leaves in the shape `Zifiri.Chat.Message.to_json/1` already defines.
  Raw bytes never enter the JSON plane.
  """

  use Plug.Router

  alias Zifiri.{JSON, Listings, Mailbox, Owner, Vanish}
  alias Zifiri.Chat.{Body, Message, Store}
  alias Zifiri.Listings.Listing
  alias Zifiri.Pow
  alias Zifiri.Pow.Challenge
  alias Zifiri.Repo

  import Ecto.Query

  plug :refuse_bad_body
  plug :match
  plug :dispatch

  defp refuse_bad_body(conn, _opts) do
    if conn.assigns[:zifiri_bad_body] do
      conn |> reply(400, ~s({"error":"refused"})) |> halt()
    else
      conn
    end
  end

  @response_bytes 16_384
  # Room for the surrounding object and the closing bracket; an item that does
  # not fit under this is left for the next page.
  @page_budget @response_bytes - 96

  @refused ~s({"error":"refused"})
  @not_found ~s({"error":"not_found"})
  @accepted ~s({"status":"accepted"})
  @updated ~s({"status":"updated"})
  @deleted ~s({"status":"deleted"})
  @acked ~s({"status":"acked"})
  @erased ~s({"status":"erased"})
  @erased_pending ~s({"status":"erased","scrub":"pending"})

  @owner_header "x-zifiri-owner"
  @pow_bits 12
  @max_ctr 18_446_744_073_709_551_616

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, ~s({"status":"ok"}))
  end

  # -- listings --------------------------------------------------------------

  get "/api/listings" do
    params = query(conn)

    listings =
      Listings.list(
        category: params["category"],
        search: params["q"],
        before: integer(params["before"])
      )

    reply(conn, 200, encode_page("listings", listings, &listing_json/1))
  end

  get "/api/listings/:ref" do
    with {:ok, id} <- ref_id(ref),
         %Listing{status: "open"} = listing <- Listings.get(id) do
      reply(conn, 200, JSON.encode(%{"listing" => listing_json(listing)}))
    else
      _ -> reply(conn, 404, @not_found)
    end
  end

  post "/api/listings" do
    params = body(conn)

    attrs = %{
      owner_token: owner_token(conn),
      body: decode64(params["envelope"]),
      title: params["title"],
      price_cents: params["price_cents"],
      currency: params["currency"],
      category: params["category"],
      challenge_id: params["challenge_id"],
      nonce: params["nonce"],
      bits: params["bits"]
    }

    case Listings.create(attrs) do
      {:ok, %Listing{id: id}} ->
        reply(conn, 201, JSON.encode(%{"status" => "created", "ref" => id}))

      {:error, :bad_pow} ->
        reply(conn, 403, @refused)

      {:error, :bad_owner} ->
        reply(conn, 403, @refused)

      {:error, :bad_envelope} ->
        reply(conn, 400, @refused)

      {:error, :bad_utf8} ->
        reply(conn, 422, @refused)

      {:error, :bad_title} ->
        reply(conn, 400, @refused)

      {:error, :bad_price} ->
        reply(conn, 400, @refused)

      {:error, :bad_currency} ->
        reply(conn, 400, @refused)

      {:error, :bad_category} ->
        reply(conn, 400, @refused)

      {:error, :invalid} ->
        reply(conn, 400, @refused)
    end
  end

  patch "/api/listings/:ref" do
    params = body(conn)

    attrs = %{
      body: decode64(params["envelope"]),
      title: params["title"],
      price_cents: params["price_cents"],
      currency: params["currency"],
      category: params["category"],
      challenge_id: params["challenge_id"],
      nonce: params["nonce"],
      bits: params["bits"]
    }

    with {:ok, id} <- ref_id(ref),
         %Listing{} = current <- Listings.get(id) do
      attrs = %{
        attrs
        | title: attrs.title || current.title,
          price_cents: attrs.price_cents || current.price_cents,
          currency: attrs.currency || current.currency,
          category: attrs.category || current.category
      }

      case Listings.update(id, owner_token(conn), attrs) do
        {:ok, _listing} -> reply(conn, 200, @updated)
        {:error, :not_found} -> reply(conn, 404, @not_found)
        {:error, :forbidden} -> reply(conn, 403, @refused)
        {:error, :bad_pow} -> reply(conn, 403, @refused)
        {:error, :bad_owner} -> reply(conn, 403, @refused)
        {:error, :closed} -> reply(conn, 409, @refused)
        {:error, :bad_utf8} -> reply(conn, 422, @refused)
        {:error, _other} -> reply(conn, 400, @refused)
      end
    else
      _ -> reply(conn, 404, @not_found)
    end
  end

  # Deleting a listing is an owner operation, not a write that needs a fresh
  # challenge: the token in the header is already the capability, and the old
  # forum delete route made the same trade. A proof is not required, so a
  # client can close a listing with one bodyless request.
  delete "/api/listings/:ref" do
    token = owner_token(conn)

    with {:ok, id} <- ref_id(ref),
         {:ok, owner_hash} <- owner_hash_for(token),
         %Listing{owner_hash: ^owner_hash} <- Listings.get(id) do
      {_count, _} = Repo.delete_all(from l in Listing, where: l.id == ^id)
      reply(conn, 200, @deleted)
    else
      # No token, a token that is not one, and a listing that is not there are
      # the same answer: a bodyless DELETE that carries no capability must not
      # be able to tell an existing ref from a missing one.
      _ -> reply(conn, 404, @not_found)
    end
  end

  # -- mailbox ---------------------------------------------------------------

  # `ack` must be matched before `:tag`, or "ack" becomes a mailbox address.
  post "/api/mailbox/ack" do
    params = body(conn)

    with {:ok, ids} <- ids(params["ids"]),
         {:ok, _deleted} <- Mailbox.ack(params["mailbox_id"] || params["recipient_pk"], ids) do
      reply(conn, 200, @acked)
    else
      _ -> reply(conn, 400, @refused)
    end
  end

  post "/api/mailbox/:tag" do
    params = body(conn)

    case Mailbox.deliver(tag, decode64(params["envelope"])) do
      {:ok, _id} -> reply(conn, 202, @accepted)
      {:error, _reason} -> reply(conn, 400, @refused)
    end
  end

  get "/api/mailbox/:tag" do
    since = integer(query(conn)["since"]) || 0

    case Mailbox.fetch(tag, since) do
      {:ok, page} -> reply(conn, 200, mailbox_page(page, since))
      {:error, _reason} -> reply(conn, 400, @refused)
    end
  end

  # -- rooms -----------------------------------------------------------------

  get "/api/rooms/:room" do
    with {:ok, room} <- room_id(room) do
      since = integer(query(conn)["since"]) || 0

      messages =
        Store.recent(room, 50)
        |> Enum.filter(&(&1.id > since))
        |> Enum.reverse()

      last_ctr =
        Store.last_ctrs(room)
        |> Map.new(fn {pubkey, ctr} -> {Message.encode64(pubkey), ctr} end)

      epoch = Message.encode64(Store.epoch(room))
      reply(conn, 200, room_page(messages, epoch, last_ctr))
    else
      :error -> reply(conn, 404, @not_found)
    end
  end

  post "/api/rooms/:room" do
    params = body(conn)

    with {:ok, room} <- room_id(room),
         {:ok, raw} <- decode64!(params["body"]),
         {:ok, padded} <- Body.pad(raw),
         {:ok, pubkey} <- decode64!(params["pubkey"]),
         {:ok, sig} <- decode64!(params["sig"]),
         true <- byte_size(pubkey) == 32,
         true <- byte_size(sig) == 64,
         {:ok, ctr} <- ctr(params["ctr"]),
         epoch = Store.epoch(room),
         signing_input = Message.signing_input(room, epoch, ctr, padded),
         true <- Pow.verify(Message.pow_hash(signing_input), params["nonce"], @pow_bits),
         true <- Message.verify(pubkey, sig, signing_input) do
      message = %{pubkey: pubkey, sig: sig, ctr: ctr, padded: padded, bucket: byte_size(padded)}

      case Store.submit(room, message) do
        {:ok, stored} ->
          reply(
            conn,
            202,
            JSON.encode(%{
              "status" => "accepted",
              "ref" => stored.id,
              "epoch" => Message.encode64(epoch)
            })
          )

        {:error, :rate_limited} ->
          reply(conn, 429, @refused)

        {:error, :replay} ->
          reply(conn, 409, @refused)

        {:error, :too_large} ->
          reply(conn, 400, @refused)
      end
    else
      {:error, :too_large} -> reply(conn, 400, @refused)
      false -> reply(conn, 403, @refused)
      _ -> reply(conn, 400, @refused)
    end
  end

  # -- proof of work ---------------------------------------------------------

  # GET is the form `docs/spec.md` sets: the owner token is a header, the payload hash is
  # public and may be a query parameter. POST stays for clients that already
  # send the token in a body.
  get "/api/pow" do
    params = query(conn)

    with {:ok, owner_hash} <- owner_hash(conn),
         {:ok, payload_hash} <- payload_hash(params) do
      issue_challenge(conn, owner_hash, payload_hash)
    else
      _ -> reply(conn, 400, @refused)
    end
  end

  post "/api/pow" do
    with {:ok, owner_hash} <- owner_hash(conn),
         {:ok, payload_hash} <- payload_hash(body(conn)) do
      issue_challenge(conn, owner_hash, payload_hash)
    else
      _ -> reply(conn, 400, @refused)
    end
  end

  # -- "yok ol" --------------------------------------------------------------

  # Identity-level erase: every listing owned by any of the tokens, plus the
  # bucket entries still waiting for those owners and the disk pages the rows
  # came from (`Zifiri.Vanish`). The tokens are the only input; a token that
  # names an owner is the capability to erase it.
  post "/api/erase" do
    with {:ok, tokens} <- erase_tokens(conn),
         {:ok, hashes} <- erase_hashes(tokens) do
      # Rows first, so the answer cannot be "erased" while the row is still
      # readable; the purge after it is the disk half.
      wipe_listings(tokens)

      case Vanish.erase_many(hashes) do
        {:ok, _count} -> reply(conn, 200, @erased)
        {:error, _reason} -> reply(conn, 200, @erased_pending)
      end
    else
      :error -> reply(conn, 400, @refused)
    end
  end

  # -- moderation ------------------------------------------------------------

  # The moderation plane was written against the forum row (`parent_id`,
  # `mod_state`), and v5 drops that table. The routes stay declared so the
  # surface is complete, but they are bound at request time: with no
  # `Zifiri.Mod` loaded they answer the same constant 404 as any unknown path,
  # and a port of the plane lights them up without touching this module.
  post "/api/report" do
    mod_route(:report, conn)
  end

  get "/mod/queue" do
    mod_route(:queue, conn)
  end

  post "/mod/resolve" do
    mod_route(:resolve, conn)
  end

  get "/mod/audit" do
    mod_route(:audit, conn)
  end

  # A constant body: a 404 must not reflect the path, a query string, or a
  # header value back to the caller.
  match _ do
    reply(conn, 404, @not_found)
  end

  # -- responses -------------------------------------------------------------

  @doc """
  Sends one padded JSON answer.

  A body that does not fit the fixed response size is `429` in the same
  constant bytes: `200` plus `{"error":"refused"}` would be a success code
  attached to a refusal.
  """
  def reply(conn, status, json) do
    {status, json} =
      if byte_size(json) > @response_bytes do
        {429, @refused}
      else
        {status, json}
      end

    body = [json, :binary.copy(" ", @response_bytes - byte_size(json))]

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
  end

  defp encode_page(key, items, fun) do
    {chunks, _size} =
      Enum.reduce_while(items, {[], 0}, fn item, {acc, size} ->
        chunk = JSON.encode(fun.(item))

        if size + byte_size(chunk) + 1 > @page_budget do
          {:halt, {acc, size}}
        else
          {:cont, {[chunk | acc], size + byte_size(chunk) + 1}}
        end
      end)

    inner = chunks |> Enum.reverse() |> Enum.join(",")
    ~s({"#{key}":[#{inner}]})
  end

  defp mailbox_page(page, since) do
    {chunks, ids, _size} =
      Enum.reduce_while(page.envelopes, {[], [], 0}, fn envelope, {acc, ids, size} ->
        chunk =
          JSON.encode(%{
            "id" => envelope.id,
            "envelope_b64" => Base.encode64(envelope.envelope)
          })

        if size + byte_size(chunk) + 1 > @page_budget do
          {:halt, {acc, ids, size}}
        else
          {:cont, {[chunk | acc], [envelope.id | ids], size + byte_size(chunk) + 1}}
        end
      end)

    ids = Enum.reverse(ids)
    cursor = List.last(ids) || since
    more = page.more or length(ids) < length(page.envelopes)
    inner = chunks |> Enum.reverse() |> Enum.join(",")

    ~s({"messages":[#{inner}],"cursor":#{cursor},"more":#{more}})
  end

  defp room_page(messages, epoch, last_ctr) do
    {chunks, _size} =
      Enum.reduce_while(messages, {[], 0}, fn message, {acc, size} ->
        chunk = JSON.encode(Message.to_json(message))

        if size + byte_size(chunk) + 1 > @page_budget do
          {:halt, {acc, size}}
        else
          {:cont, {[chunk | acc], size + byte_size(chunk) + 1}}
        end
      end)

    inner = chunks |> Enum.reverse() |> Enum.join(",")

    ~s({"epoch":#{JSON.encode(epoch)},"last_ctr":#{JSON.encode(last_ctr)},"messages":[#{inner}]})
  end

  defp listing_json(%Listing{} = listing) do
    %{
      "ref" => listing.id,
      "title" => listing.title,
      "price_cents" => listing.price_cents,
      "currency" => listing.currency,
      "category" => listing.category,
      "day" => listing.created_day && Date.to_iso8601(listing.created_day),
      "body_b64" => Base.encode64(listing.body)
    }
  end

  # -- erase inputs ----------------------------------------------------------

  defp erase_tokens(conn) do
    case body(conn)["owner_tokens"] do
      tokens when is_list(tokens) and tokens != [] ->
        {:ok, tokens}

      nil ->
        case owner_token(conn) do
          nil -> :error
          token -> {:ok, [token]}
        end

      _other ->
        :error
    end
  end

  defp wipe_listings(tokens) do
    Enum.each(tokens, fn token ->
      with {:ok, hash} <- owner_hash_for(token) do
        Repo.delete_all(from l in Listing, where: l.owner_hash == ^hash)
      end
    end)
  end

  # Every token has to name an owner before anything is deleted: a list with one
  # bad entry must not half-erase. The order the hashes come out in does not
  # matter — a delete by hash is a delete by hash.
  defp erase_hashes(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, hashes} ->
      case owner_hash_for(token) do
        {:ok, hash} -> {:cont, {:ok, [hash | hashes]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  # -- moderation ------------------------------------------------------------

  # `apply/3` on purpose: a direct `Zifiri.Mod.route/2` call is a compile-time
  # dependency on a module that may not exist, and the router has to compile
  # with or without the moderation plane.
  defp mod_route(kind, conn) do
    if Code.ensure_loaded?(Zifiri.Mod) and function_exported?(Zifiri.Mod, :route, 2) do
      params = conn |> body() |> Map.put("authorization", header_value(conn, "authorization"))
      {status, payload} = apply(Zifiri.Mod, :route, [kind, params])
      reply(conn, status, JSON.encode(payload))
    else
      reply(conn, 404, @not_found)
    end
  end

  # -- challenge inputs ------------------------------------------------------

  defp issue_challenge(conn, owner_hash, payload_hash) do
    if Code.ensure_loaded?(Challenge) and function_exported?(Challenge, :issue, 2) do
      case Challenge.issue(owner_hash, payload_hash) do
        {:ok, challenge} when is_map(challenge) ->
          reply(conn, 200, JSON.encode(challenge_json(challenge)))

        _other ->
          reply(conn, 429, @refused)
      end
    else
      reply(conn, 404, @not_found)
    end
  end

  defp challenge_json(challenge) do
    %{
      "id" => Map.get(challenge, :id) || Map.get(challenge, "id"),
      "bits" => Map.get(challenge, :bits) || Map.get(challenge, "bits")
    }
  end

  defp owner_hash(conn) do
    case owner_token(conn) do
      nil -> :error
      token -> owner_hash_for(token)
    end
  end

  # A token arrives as 32 raw bytes from an internal caller, or as base64 from
  # the wire; both end up as the same owner hash. Anything else is refused, not
  # guessed at.
  defp owner_hash_for(<<_::256>> = token), do: {:ok, Owner.hash(token)}

  defp owner_hash_for(token) when is_binary(token) do
    case decode64!(token) do
      {:ok, <<_::256>> = raw} -> {:ok, Owner.hash(raw)}
      _ -> {:error, :bad_pow}
    end
  end

  defp owner_hash_for(_token), do: {:error, :bad_pow}

  defp payload_hash(params) do
    case params["payload_hash"] do
      nil -> payload_from(params["payload"])
      value when is_binary(value) -> decode_hash(value)
      _other -> :error
    end
  end

  defp payload_from(payload) when is_binary(payload), do: {:ok, :crypto.hash(:sha256, payload)}
  defp payload_from(_payload), do: :error

  defp decode_hash(value) do
    cond do
      byte_size(value) == 32 -> {:ok, value}
      byte_size(value) == 64 -> from_hex(value)
      true -> from_base64(value)
    end
  end

  defp from_hex(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, hash} when byte_size(hash) == 32 -> {:ok, hash}
      _other -> :error
    end
  end

  defp from_base64(value) do
    # A standard-base64 hash in a query string can arrive with `+` already
    # turned into a space by form decoding. A space is never valid base64, so
    # putting it back is unambiguous and keeps `?payload_hash=` usable without
    # forcing every client to URL-encode.
    value = String.replace(value, " ", "+")

    decoders = [
      &Base.decode64/1,
      &Base.decode64(&1, padding: false),
      &Base.url_decode64/1,
      &Base.url_decode64(&1, padding: false)
    ]

    Enum.find_value(decoders, :error, fn decode ->
      case decode.(value) do
        {:ok, hash} when byte_size(hash) == 32 -> {:ok, hash}
        _other -> nil
      end
    end)
  end

  # -- request inputs --------------------------------------------------------

  # The token, and nothing else: `owner_token` in the parsed body, or the
  # `x-zifiri-owner` header. There is deliberately no query-string branch.
  defp owner_token(conn) do
    case body(conn)["owner_token"] do
      nil -> header_token(conn)
      token -> token
    end
  end

  defp header_token(conn), do: header_value(conn, @owner_header)

  defp header_value(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp query(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}} = conn) do
    conn = fetch_query_params(conn)
    conn.query_params
  end

  defp query(%Plug.Conn{query_params: params}) when is_map(params), do: params
  defp query(_conn), do: %{}

  defp body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp body(_conn), do: %{}

  defp decode64(nil), do: nil
  defp decode64(value) when is_binary(value), do: decode64!(value) |> elem_or_nil()

  defp decode64!(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, binary} ->
        {:ok, binary}

      :error ->
        case Base.url_decode64(value, padding: false) do
          {:ok, binary} -> {:ok, binary}
          :error -> :error
        end
    end
  end

  defp decode64!(_value), do: :error

  defp elem_or_nil({:ok, binary}), do: binary
  defp elem_or_nil(:error), do: nil

  defp ids(list) when is_list(list) do
    if Enum.all?(list, &(is_integer(&1) and &1 > 0)), do: {:ok, list}, else: :error
  end

  defp ids(id) when is_integer(id) and id > 0, do: {:ok, [id]}
  defp ids(_other), do: :error

  defp ctr(value) when is_integer(value) and value >= 0 and value < @max_ctr, do: {:ok, value}
  defp ctr(_value), do: :error

  defp ref_id(ref) do
    case integer(ref) do
      nil -> :error
      id -> {:ok, id}
    end
  end

  defp room_id(room) when is_binary(room) do
    rooms = Zifiri.Chat.rooms()
    candidate = if String.starts_with?(room, "chat:"), do: room, else: "chat:" <> room

    if candidate in rooms, do: {:ok, candidate}, else: :error
  end

  defp room_id(_room), do: :error

  defp integer(nil), do: nil
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp integer(_value), do: nil
end
