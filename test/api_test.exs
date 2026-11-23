defmodule Zifiri.ApiTest do
  @moduledoc """
  The HTTP surface of scope v5, exercised through `Zifiri.Endpoint.call/2`: the
  real plug pipeline, the real JSON parser, the real padding.

  The unit suites already pin each module (`Listings`, `Mailbox`, `Pow`,
  `Envelope`). This file pins what only the wire can show:

    * **One size.** A `201`, a `403`, a `404` and a page are the same number of
      bytes, so a response cannot be measured to learn what happened.
    * **Constant text.** A refusal is `{"error":"refused"}` with nothing of the
      request in it — not the title, not the parser's message.
    * **Where a token may travel.** The `owner_token` body field or the
      `x-zifiri-owner` header, and nowhere else: a query string is not read.
    * **A proof is spent once, and only for the write it was issued for.** A
      replay, another owner and another payload are three separate refusals.
    * **The mailbox is opaque.** What goes in as a 4096-byte blob comes out
      byte-identical, and a blob of any other size is refused.

  Proofs here are built with `Zifiri.Pow.Challenge` at four bits: this file is
  about the surface, not about how long a browser grinds, and a four-bit
  challenge goes through the same `redeem/5` a twenty-bit one does.

  The disk half of the erase lives in `Zifiri.ApiVanishTest` below, which has to
  leave the sandbox transaction to be able to look at the file.
  """

  use Zifiri.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test

  alias Zifiri.{Bucket, Envelope, Listings, Mailbox, Owner, Pow}
  alias Zifiri.Bucket.Publisher
  alias Zifiri.Listings.Listing
  alias Zifiri.Mailbox.Envelope, as: MailboxEnvelope
  alias Zifiri.Pow.Challenge
  alias Zifiri.JSON
  alias Zifiri.Repo

  @response_bytes 16_384
  @refused ~s({"error":"refused"})

  setup do
    Challenge.clear()
    :ok = Bucket.reset()
    Repo.delete_all(Listing)
    Repo.delete_all(MailboxEnvelope)
    :rand.seed(:exsss, {5, 8, 13})
    :ok
  end

  # -- listings: writing -----------------------------------------------------

  test "a create answers 201 in the fixed size, and the listing is really there" do
    token = owner_token()
    response = post_json("/api/listings", create_body(token, "hello api"))

    assert response.status == 201
    assert byte_size(response.resp_body) == @response_bytes
    assert ["no-store"] = get_resp_header(response, "cache-control")

    assert %{"status" => "created", "ref" => ref} = json(response)
    assert is_integer(ref)

    stored = Listings.get(ref)
    assert stored.body == "hello api"
    assert stored.owner_hash == Owner.hash(token)
    assert stored.status == "open"
  end

  test "every answer is the same number of bytes, whatever the status" do
    token = owner_token()

    created = post_json("/api/listings", create_body(token, "same size"))
    assert created.status == 201

    refused =
      post_json("/api/listings", %{
        "envelope" => Base.encode64(envelope_bytes("x")),
        "title" => "t",
        "currency" => "TRY",
        "category" => "c",
        "owner_token" => Base.encode64(token),
        "challenge_id" => "no-such-challenge",
        "nonce" => 0,
        "bits" => 4
      })

    missing = request(:get, "/api/listings/999999")

    sizes =
      [created, refused, missing]
      |> Enum.map(&byte_size(&1.resp_body))
      |> Enum.uniq()

    assert sizes == [@response_bytes]
  end

  test "a refusal carries the constant text and none of the request" do
    canary = "ZIFIRI-CANARY-#{System.unique_integer([:positive])}"
    token = owner_token()

    body =
      create_body(token, canary)
      |> Map.put("challenge_id", "never-issued")
      |> Map.put("title", canary)

    response = post_json("/api/listings", body)

    assert response.status == 403
    assert response.resp_body == padded(@refused)
    refute response.resp_body =~ canary
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "a proof is spent once: the identical second create is refused" do
    body = create_body(owner_token(), "one proof, one write")

    assert post_json("/api/listings", body).status == 201
    replay = post_json("/api/listings", body)

    assert replay.status == 403
    assert json(replay) == %{"error" => "refused"}
    assert Repo.aggregate(Listing, :count, :id) == 1
  end

  test "a proof issued to one owner cannot be spent by another" do
    owner = owner_token()
    thief = owner_token()
    {envelope, proof} = envelope_and_proof(owner, "one solve, two owners")

    stolen =
      create_body(thief, "one solve, two owners")
      |> Map.merge(proof)
      |> Map.put("envelope", Base.encode64(envelope))

    assert post_json("/api/listings", stolen).status == 403
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "a proof for one payload cannot be spent on another" do
    token = owner_token()
    {_envelope, proof} = envelope_and_proof(token, "paid for this")

    swapped =
      create_body(token, "not what was paid for")
      |> Map.merge(proof)

    assert post_json("/api/listings", swapped).status == 403
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "a write with no token at all is refused, not attributed to nobody" do
    body =
      create_body(owner_token(), "no owner")
      |> Map.delete("owner_token")

    assert post_json("/api/listings", body).status == 403
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "a non-zero padding byte is refused at the edge, before the proof is spent" do
    token = owner_token()
    {envelope, proof} = envelope_and_proof(token, "tampered")

    response =
      post_json(
        "/api/listings",
        Map.merge(proof, %{
          "envelope" => Base.encode64(tamper_padding(envelope)),
          "title" => "t",
          "currency" => "TRY",
          "category" => "c",
          "owner_token" => Base.encode64(token)
        })
      )

    assert response.status == 400
    assert json(response) == %{"error" => "refused"}
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "a body that is not JSON is refused with the padded refusal, not a 500" do
    response = post_raw("/api/listings", "{not json at all", "application/json")

    # The parser's error is swallowed, the body carries no fields, and the gate
    # refuses the write. Which refusal code it lands on (400 for the empty
    # envelope, 403 for the missing token) is not the claim — the claim is that
    # the answer is a refusal, the same bytes as every other refusal, and that
    # the parser's message never reaches the client.
    assert response.status in [400, 403]
    assert response.resp_body == padded(@refused)
    refute response.resp_body =~ "not json"
  end

  test "a body with no content type at all is refused the same way" do
    response = post_raw("/api/listings", "envelope=x")

    assert response.status == 403
    assert json(response) == %{"error" => "refused"}
  end

  # -- listings: reading -----------------------------------------------------

  test "a page is one padded body, and the cursor pages strictly backwards" do
    ids =
      for index <- 1..30 do
        {:ok, listing} = Listings.create(create_attrs(owner_token(), "listing #{index}"))
        listing.id
      end

    first = request(:get, "/api/listings")
    assert first.status == 200
    assert byte_size(first.resp_body) == @response_bytes

    %{"listings" => page} = json(first)
    assert length(page) == 30

    refs = Enum.map(page, & &1["ref"])
    assert refs == Enum.sort(ids, :desc)

    older = request(:get, "/api/listings?before=#{List.last(refs)}")
    assert %{"listings" => []} = json(older)
  end

  test "a search term's LIKE wildcards are stripped, not honoured" do
    {:ok, _} = Listings.create(create_attrs(owner_token(), "a bicycle"))

    assert %{"listings" => [_one]} = json(request(:get, "/api/listings?q=bicycle"))
    assert %{"listings" => []} = json(request(:get, "/api/listings?q=%25"))
    assert %{"listings" => []} = json(request(:get, "/api/listings?q=_"))
  end

  test "reading a listing that does not exist answers the constant 404" do
    response = request(:get, "/api/listings/424242")

    assert response.status == 404
    assert json(response) == %{"error" => "not_found"}
  end

  test "an update really changes the body, and only for the owner" do
    token = owner_token()
    {:ok, listing} = Listings.create(create_attrs(token, "before"))

    {envelope, proof} = envelope_and_proof(token, "after")

    updated =
      conn(
        :patch,
        "/api/listings/#{listing.id}",
        JSON.encode(
          Map.merge(proof, %{
            "envelope" => Base.encode64(envelope),
            "owner_token" => Base.encode64(token)
          })
        )
      )
      |> put_req_header("content-type", "application/json")
      |> Zifiri.Endpoint.call([])

    assert updated.status == 200
    assert json(updated) == %{"status" => "updated"}
    assert Listings.get(listing.id).body == "after"

    # A stranger cannot rewrite it, and the body is unchanged afterwards.
    {other_envelope, other_proof} = envelope_and_proof(owner_token(), "hijacked")

    stranger =
      conn(
        :patch,
        "/api/listings/#{listing.id}",
        JSON.encode(
          Map.merge(other_proof, %{
            "envelope" => Base.encode64(other_envelope),
            "owner_token" => Base.encode64(owner_token())
          })
        )
      )
      |> put_req_header("content-type", "application/json")
      |> Zifiri.Endpoint.call([])

    assert stranger.status == 403
    assert Listings.get(listing.id).body == "after"
  end

  # -- proof of work ---------------------------------------------------------

  test "GET /api/pow takes the token from the header and reports the difficulty" do
    token = owner_token()
    payload_hash = :crypto.hash(:sha256, envelope_bytes("pow payload"))

    response =
      request(
        :get,
        "/api/pow?payload_hash=#{Base.encode64(payload_hash)}",
        nil,
        [{"x-zifiri-owner", Base.encode64(token)}]
      )

    assert response.status == 200
    assert %{"id" => id, "bits" => bits} = json(response)
    assert is_binary(id) and byte_size(id) > 0
    assert bits == Pow.difficulty(0)
    assert Challenge.outstanding() == 1
  end

  test "GET /api/pow refuses a token in the query string" do
    token = owner_token()
    payload_hash = :crypto.hash(:sha256, envelope_bytes("pow payload"))

    response =
      request(
        :get,
        "/api/pow?owner_token=#{Base.encode64(token)}&payload_hash=#{Base.encode64(payload_hash)}"
      )

    assert response.status == 400
    assert json(response) == %{"error" => "refused"}
    assert Challenge.outstanding() == 0
  end

  # -- mailbox ---------------------------------------------------------------

  test "a 4096-byte envelope goes in and comes out byte-identical" do
    tag = Mailbox.new_id() |> Mailbox.encode_id()
    envelope = :crypto.strong_rand_bytes(4096)

    delivered = post_json("/api/mailbox/#{tag}", %{"envelope" => Base.encode64(envelope)})
    assert delivered.status == 202
    assert json(delivered) == %{"status" => "queued"}

    # The envelope is queued, not stored; the publisher's tick closes the
    # bucket and writes the receipt.
    assert :ok = publish()

    page = request(:get, "/api/mailbox/#{tag}")
    assert page.status == 200
    assert byte_size(page.resp_body) == @response_bytes

    %{"messages" => [message], "cursor" => cursor, "more" => false} = json(page)
    assert Base.decode64!(message["envelope_b64"]) == envelope
    assert cursor == message["id"]
  end

  test "an envelope that is not 4096 bytes is refused" do
    tag = Mailbox.new_id() |> Mailbox.encode_id()

    for size <- [0, 255, 4095, 4097, 8192] do
      response =
        post_json("/api/mailbox/#{tag}", %{"envelope" => Base.encode64(:binary.copy(<<7>>, size))})

      assert response.status == 400, "a #{size}-byte envelope was accepted"
      assert json(response) == %{"error" => "refused"}
    end

    assert {:ok, %{envelopes: []}} = Mailbox.fetch(tag)
  end

  test "an ack deletes the message, and only for the key that owns the mailbox" do
    tag = Mailbox.new_id() |> Mailbox.encode_id()
    envelope = :crypto.strong_rand_bytes(4096)

    delivered = post_json("/api/mailbox/#{tag}", %{"envelope" => Base.encode64(envelope)})
    assert delivered.status == 202
    assert :ok = publish()

    assert {:ok, %{envelopes: [%{id: id}]}} = Mailbox.fetch(tag)

    stranger = Mailbox.new_id() |> Mailbox.encode_id()

    refused = post_json("/api/mailbox/ack", %{"recipient_pk" => stranger, "ids" => [id]})
    assert refused.status == 200
    assert {:ok, %{envelopes: [still_there]}} = Mailbox.fetch(tag)
    assert still_there.id == id

    acked = post_json("/api/mailbox/ack", %{"recipient_pk" => tag, "ids" => [id]})
    assert acked.status == 200
    assert json(acked) == %{"status" => "acked"}
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(tag)
  end

  # -- deleting a listing (A3's owner hashing) -------------------------------

  test "a delete with the owner header removes the row" do
    token = owner_token()
    {:ok, listing} = Listings.create(create_attrs(token, "close me"))

    response =
      request(:delete, "/api/listings/#{listing.id}", nil, [
        {"x-zifiri-owner", Base.encode64(token)}
      ])

    assert response.status == 200
    assert json(response) == %{"status" => "deleted"}
    assert Listings.get(listing.id) == nil
  end

  test "a delete with a stranger's token leaves the row and answers not_found" do
    token = owner_token()
    {:ok, listing} = Listings.create(create_attrs(token, "not yours"))

    response =
      request(:delete, "/api/listings/#{listing.id}", nil, [
        {"x-zifiri-owner", Base.encode64(owner_token())}
      ])

    assert response.status == 404
    assert Listings.get(listing.id) != nil
  end

  test "a token in the query string is not a token" do
    token = owner_token()
    {:ok, listing} = Listings.create(create_attrs(token, "query token"))

    response = request(:delete, "/api/listings/#{listing.id}?owner_token=#{Base.encode64(token)}")

    # 403 (no usable token) or 404 (nothing matched) — what must not happen is a
    # 200, because the token in the query string is not a capability.
    refute response.status == 200
    assert Listings.get(listing.id) != nil
  end

  # -- the property the whole API rests on -----------------------------------

  test "an answer that does not fit is a 429, never a 200 carrying the refusal" do
    oversized = String.duplicate("x", @response_bytes + 1)

    response = Zifiri.Router.reply(conn(:get, "/api/listings"), 200, oversized)

    assert response.status == 429
    assert response.resp_body == padded(@refused)
  end

  test "no route reads an owner token out of the query string" do
    source = File.read!("lib/zifiri/router.ex")

    # Three ways it could creep back in: the merged-params helper, an explicit
    # query lookup, or a query-params field. The behavioural tests above cover
    # the routes that exist; this one covers every route added later.
    refute source =~ "params(conn, :query)"
    refute source =~ ~s(query_params["owner_token"])
    refute source =~ "query(conn)[\"owner_token\"]"
    assert source =~ "x-zifiri-owner"
  end

  # -- helpers ---------------------------------------------------------------

  defp owner_token, do: :crypto.strong_rand_bytes(32)

  defp envelope_bytes(text) do
    {:ok, envelope, _bucket} = Envelope.encode(text)
    envelope
  end

  defp envelope_and_proof(token, text) do
    envelope = envelope_bytes(text)
    payload_hash = :crypto.hash(:sha256, envelope)
    {:ok, challenge} = Challenge.issue(Owner.hash(token), payload_hash, bits: 4)

    {envelope,
     %{
       "challenge_id" => challenge.id,
       "bits" => challenge.bits,
       "nonce" => Challenge.solve(challenge, payload_hash)
     }}
  end

  defp create_body(token, text) do
    {envelope, proof} = envelope_and_proof(token, text)

    Map.merge(proof, %{
      "envelope" => Base.encode64(envelope),
      "title" => "a title",
      "price_cents" => 100,
      "currency" => "TRY",
      "category" => "goods",
      "owner_token" => Base.encode64(token)
    })
  end

  # Attributes for `Listings.create/1` directly, for fixtures that do not need
  # to go through HTTP.
  defp create_attrs(token, text) do
    {envelope, proof} = envelope_and_proof(token, text)

    Map.merge(proof, %{
      body: envelope,
      title: text,
      price_cents: 100,
      currency: "TRY",
      category: "goods",
      owner_token: token
    })
  end

  defp tamper_padding(envelope) do
    size = byte_size(envelope) - 1
    <<head::binary-size(^size), last>> = envelope
    <<head::binary, Bitwise.bxor(last, 1)>>
  end

  defp padded(json), do: json <> :binary.copy(" ", @response_bytes - byte_size(json))

  defp post_json(path, body), do: post_raw(path, JSON.encode(body), "application/json")

  # Closes the bucket with the same tick the publisher's timer runs in
  # production. Decoys are seeded so a page assertion is reproducible.
  defp publish, do: Publisher.tick(now_ms: System.system_time(:millisecond), rand: &:rand.bytes/1)

  defp post_raw(path, body, content_type \\ nil) do
    conn = conn(:post, path, body)
    conn = if content_type, do: put_req_header(conn, "content-type", content_type), else: conn
    Zifiri.Endpoint.call(conn, [])
  end

  defp request(method, path, body \\ nil, headers \\ []) do
    conn = conn(method, path, body)
    conn = Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    Zifiri.Endpoint.call(conn, [])
  end

  defp json(conn) do
    {:ok, decoded} = JSON.decode(String.trim_trailing(conn.resp_body, " "))
    decoded
  end
end

defmodule Zifiri.ApiVanishTest do
  @moduledoc """
  "Yok ol" as the client sees it, checked against the file.

  `Zifiri.ApiTest` runs inside the sandbox transaction, where nothing a test
  writes ever reaches the disk and a wipe assertion would pass without testing
  anything. This module flips the sandbox to `:auto` (no wrapping transaction)
  for the same reason `Zifiri.VanishTest` does, drives the real endpoint, and
  then searches the database file and its `-wal` for the body the client asked
  to disappear.

  The erase route deletes every row owned by the hash and then asks
  `Zifiri.Vanish` for the disk half; this test drives that over HTTP and then
  reads the file.
  """

  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Zifiri.Listings
  alias Zifiri.Listings.Listing
  alias Zifiri.JSON
  alias Zifiri.Repo
  alias Zifiri.Vanish

  @moduletag :wipe

  setup do
    # VACUUM is refused inside a transaction, and this module asserts on the
    # file, so it needs the pool's own connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      # Rows written outside the sandbox are committed: clear them and put the
      # mode back, or the next module's transaction starts on a dirty database.
      Repo.delete_all(Listing)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "yok ol over HTTP leaves neither the row nor the bytes on disk" do
    token = :crypto.strong_rand_bytes(32)
    body = canary_body()
    {:ok, listing} = create_listing(token, body)

    # Precondition: the body really is in the file, so the scan below can see
    # it and a clean result means the erase worked rather than that the fixture
    # never landed.
    assert {:ok, :done} = Vanish.purge()
    assert found_in_file?(body), "precondition: the body must be on disk"

    response =
      conn(:post, "/api/erase", JSON.encode(%{"owner_tokens" => [Base.encode64(token)]}))
      |> put_req_header("content-type", "application/json")
      |> Zifiri.Endpoint.call([])

    assert response.status == 200
    assert %{"status" => "erased"} = JSON.decode!(String.trim_trailing(response.resp_body))

    assert Repo.get(Listing, listing.id) == nil
    refute found_in_file?(body), "the body is still in #{db_path()}"
    refute found_in_wal?(body), "the body is still in the -wal"
  end

  ## Fixtures

  defp canary,
    do: "ZIFIRI-API-VANISH-" <> Base.encode16(:crypto.strong_rand_bytes(9), case: :lower)

  # Five copies, not forty: a body has to fit the 256-byte bucket. A larger one
  # is stored across overflow pages, split at page boundaries, and a scan for a
  # needle that never appears contiguously in the file would pass no matter what
  # the erase did.
  defp canary_body, do: String.duplicate(canary(), 5)

  defp create_listing(token, body) do
    {:ok, envelope, _bucket} = Zifiri.Envelope.encode(body)
    payload_hash = :crypto.hash(:sha256, envelope)
    {:ok, challenge} = Zifiri.Pow.Challenge.issue(Zifiri.Owner.hash(token), payload_hash, bits: 4)

    Listings.create(%{
      owner_token: token,
      body: envelope,
      title: "vanish me",
      currency: "TRY",
      category: "goods",
      challenge_id: challenge.id,
      bits: challenge.bits,
      nonce: Zifiri.Pow.Challenge.solve(challenge, payload_hash)
    })
  end

  ## Disk

  defp db_path, do: Repo.config()[:database]
  defp wal_path, do: db_path() <> "-wal"

  defp found_in_file?(needle), do: present?(bytes(db_path()), needle)
  defp found_in_wal?(needle), do: present?(bytes(wal_path()), needle)

  defp present?(binary, needle), do: :binary.match(binary, needle) != :nomatch

  defp bytes(path) do
    case File.read(path) do
      {:ok, binary} -> binary
      {:error, :enoent} -> ""
    end
  end
end
