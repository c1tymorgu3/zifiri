defmodule Zifiri.ApiSurfaceTest do
  @moduledoc """
  The scope-v5 HTTP surface: listings, mailbox, rooms, pow and erase.

  These tests assert on the wire, not on the contexts behind it: status,
  headers, the fixed response size, and the fact that a refusal is the same
  bytes whether the caller guessed wrong or the row does not exist.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.{Envelope, Owner, Pow}
  alias Zifiri.Chat.{Body, Message, Store}
  alias Zifiri.Listings.Listing
  alias Zifiri.Mailbox.Envelope, as: MailboxEnvelope
  alias Zifiri.Pow.Challenge
  alias Zifiri.JSON
  alias Zifiri.Repo

  import Plug.Conn, only: [get_resp_header: 2]
  import Zifiri.TestHelpers

  @response_bytes 16_384
  @pow_bits 12

  setup do
    isolate()
    Repo.delete_all(Listing)
    Repo.delete_all(MailboxEnvelope)
    Store.reset()
    :ok
  end

  # -- listings --------------------------------------------------------------

  test "an empty listings page is one fixed bucket and is not cacheable" do
    conn = request(:get, "/api/listings")

    assert conn.status == 200
    assert json(conn) == %{"listings" => []}
    assert_padded(conn)
  end

  test "creating a listing without a challenge is refused and stores nothing" do
    token = owner_token()
    {envelope, _bucket} = padded_envelope("satilik bisiklet")

    conn =
      request(:post, "/api/listings", %{
        "owner_token" => Base.encode64(token),
        "envelope" => Base.encode64(envelope),
        "title" => "Bisiklet",
        "category" => "spor",
        "currency" => "TRY",
        "price_cents" => 100
      })

    assert conn.status == 403
    assert json(conn) == %{"error" => "refused"}
    assert Repo.aggregate(Listing, :count, :id) == 0
    assert_padded(conn)
  end

  test "a listing created with a challenge and a padded body is readable" do
    token = owner_token()
    {conn, ref} = create_listing(token, "temiz bisiklet", %{"category" => "spor"})

    assert conn.status == 201
    assert %{"status" => "created", "ref" => ^ref} = json(conn)

    show = request(:get, "/api/listings/#{ref}")
    assert show.status == 200
    assert %{"listing" => listing} = json(show)
    assert listing["ref"] == ref
    assert listing["category"] == "spor"
    assert Base.decode64!(listing["body_b64"]) == "temiz bisiklet"
    assert_padded(show)
  end

  test "an unpadded listing body is refused" do
    token = owner_token()
    subject = :crypto.hash(:sha256, "not-an-envelope")
    proof = proof(token, subject)

    conn =
      request(
        :post,
        "/api/listings",
        %{
          "owner_token" => Base.encode64(token),
          "envelope" => Base.encode64("not-an-envelope"),
          "title" => "Bisiklet",
          "category" => "spor",
          "currency" => "TRY"
        }
        |> Map.merge(proof)
      )

    assert conn.status == 400
    assert Repo.aggregate(Listing, :count, :id) == 0
  end

  test "listings filter by category, search the title, and page backwards" do
    token = owner_token()

    {_conn, first} =
      create_listing(token, "bir", %{"title" => "Kirmizi bisiklet", "category" => "spor"})

    {_conn, second} =
      create_listing(token, "iki", %{"title" => "Mavi kask", "category" => "spor"})

    {_conn, _third} = create_listing(token, "uc", %{"title" => "Kahve", "category" => "ev"})

    assert [%{"ref" => ^second}, %{"ref" => ^first}] =
             json(request(:get, "/api/listings?category=spor"))["listings"]

    assert [%{"ref" => ^first}] = json(request(:get, "/api/listings?q=bisiklet"))["listings"]

    assert [%{"ref" => ^first}] =
             json(request(:get, "/api/listings?before=#{second}"))["listings"]
  end

  test "a stranger cannot patch a listing and the owner can" do
    token = owner_token()
    {_conn, ref} = create_listing(token, "eski metin", %{"category" => "spor"})
    {new_envelope, _bucket} = padded_envelope("yeni metin")
    proof = proof(token, :crypto.hash(:sha256, new_envelope))

    stranger =
      request(
        :patch,
        "/api/listings/#{ref}",
        %{
          "owner_token" => Base.encode64(owner_token()),
          "envelope" => Base.encode64(new_envelope)
        }
        |> Map.merge(proof)
      )

    assert stranger.status == 403

    owner =
      request(
        :patch,
        "/api/listings/#{ref}",
        %{
          "owner_token" => Base.encode64(token),
          "envelope" => Base.encode64(new_envelope)
        }
        |> Map.merge(proof)
      )

    assert owner.status == 200
    assert json(owner) == %{"status" => "updated"}

    show = json(request(:get, "/api/listings/#{ref}"))["listing"]
    assert Base.decode64!(show["body_b64"]) == "yeni metin"
  end

  test "the owner header deletes a listing and a query-string token does not" do
    token = owner_token()
    {_conn, ref} = create_listing(token, "silinecek", %{"category" => "spor"})

    # The token in the query string is not read: this request has no header,
    # so it is answered as if the listing were not there and the row stays.
    refused =
      request(
        :delete,
        "/api/listings/#{ref}?owner_token=#{Base.url_encode64(token, padding: false)}"
      )

    assert refused.status == 404
    assert request(:get, "/api/listings/#{ref}").status == 200

    deleted =
      request(:delete, "/api/listings/#{ref}", nil, [{"x-zifiri-owner", Base.encode64(token)}])

    assert deleted.status == 200
    assert json(deleted) == %{"status" => "deleted"}
    assert request(:get, "/api/listings/#{ref}").status == 404
  end

  test "an unknown listing ref is a constant 404" do
    conn = request(:get, "/api/listings/999999")
    assert conn.status == 404
    assert json(conn) == %{"error" => "not_found"}
    assert_padded(conn)
  end

  # -- mailbox ---------------------------------------------------------------

  test "a mailbox envelope is deposited, fetched by cursor, and acknowledged" do
    pk = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, envelope, 4096} = Envelope.encode(:binary.copy("m", 2_000))

    accepted =
      request(:post, "/api/mailbox/#{pk}", %{"envelope" => Base.encode64(envelope)})

    assert accepted.status == 202
    assert json(accepted) == %{"status" => "accepted"}

    page = json(request(:get, "/api/mailbox/#{pk}"))
    assert [%{"id" => id, "envelope_b64" => body}] = page["messages"]
    assert Base.decode64!(body) == envelope
    assert page["cursor"] == id
    assert page["more"] == false

    empty = json(request(:get, "/api/mailbox/#{pk}?since=#{id}"))
    assert empty["messages"] == []

    acked = request(:post, "/api/mailbox/ack", %{"mailbox_id" => pk, "ids" => [id]})
    assert acked.status == 200
    assert json(request(:get, "/api/mailbox/#{pk}"))["messages"] == []
  end

  test "a mailbox envelope that is not one 4096-byte bucket is refused" do
    pk = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, small, 256} = Envelope.encode("small")

    conn = request(:post, "/api/mailbox/#{pk}", %{"envelope" => Base.encode64(small)})

    assert conn.status == 400
    assert json(conn) == %{"error" => "refused"}
    assert Repo.aggregate(MailboxEnvelope, :count, :id) == 0
  end

  test "ack deletes only the ids addressed to that mailbox" do
    pk = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    other = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, envelope, 4096} = Envelope.encode(:binary.copy("a", 2_000))
    {:ok, other_envelope, 4096} = Envelope.encode(:binary.copy("b", 2_000))

    assert request(:post, "/api/mailbox/#{pk}", %{"envelope" => Base.encode64(envelope)}).status ==
             202

    assert request(:post, "/api/mailbox/#{pk}", %{"envelope" => Base.encode64(other_envelope)}).status ==
             202

    assert request(:post, "/api/mailbox/#{other}", %{"envelope" => Base.encode64(envelope)}).status ==
             202

    [%{"id" => first} | _] = json(request(:get, "/api/mailbox/#{pk}"))["messages"]

    assert request(:post, "/api/mailbox/ack", %{"mailbox_id" => pk, "ids" => [first]}).status ==
             200

    remaining = json(request(:get, "/api/mailbox/#{pk}"))["messages"]
    assert length(remaining) == 1
    refute Enum.any?(remaining, &(&1["id"] == first))
    assert length(json(request(:get, "/api/mailbox/#{other}"))["messages"]) == 1
  end

  # -- rooms -----------------------------------------------------------------

  test "a signed room message with proof is accepted and readable since a cursor" do
    {body, payload} = room_message("merhaba oda", 1)

    conn = request(:post, "/api/rooms/lobby", body)

    assert conn.status == 202
    assert %{"status" => "accepted", "ref" => ref} = json(conn)
    assert is_integer(ref)

    page = json(request(:get, "/api/rooms/lobby?since=0"))
    assert [%{"id" => ^ref, "body" => encoded} | _] = page["messages"]
    assert {:ok, ^payload, 256} = Envelope.decode(Base.url_decode64!(encoded, padding: false))
    assert map_size(page["last_ctr"]) == 1

    after_ref = json(request(:get, "/api/rooms/lobby?since=#{ref}"))
    assert after_ref["messages"] == []
  end

  test "a room message with a bad proof is refused and not stored" do
    {body, _payload} = room_message("spam", 1, nonce: 0)

    conn = request(:post, "/api/rooms/lobby", body)

    assert conn.status == 403
    assert json(request(:get, "/api/rooms/lobby"))["messages"] == []
  end

  test "an unknown room is a constant 404" do
    conn = request(:get, "/api/rooms/nope")
    assert conn.status == 404
    assert json(conn) == %{"error" => "not_found"}
    assert_padded(conn)
  end

  # -- pow -------------------------------------------------------------------

  test "GET /api/pow issues a challenge from a header token and a public hash" do
    token = owner_token()
    hash = :crypto.hash(:sha256, "payload")

    conn =
      request(:get, "/api/pow?payload_hash=#{Base.encode16(hash, case: :lower)}", nil, [
        {"x-zifiri-owner", Base.encode64(token)}
      ])

    assert conn.status == 200
    assert %{"id" => id, "bits" => bits} = json(conn)
    assert is_binary(id)
    assert is_integer(bits) and bits >= 0
    assert_padded(conn)

    # A token in the query string is not a token.
    refused =
      request(
        :get,
        "/api/pow?owner_token=#{Base.url_encode64(token, padding: false)}&payload_hash=#{Base.encode16(hash)}"
      )

    assert refused.status == 400
  end

  # -- erase -----------------------------------------------------------------

  test "erase removes every listing owned by the token and leaves the others" do
    token = owner_token()
    other = owner_token()
    {_conn, ref} = create_listing(token, "benim ilanim", %{"category" => "spor"})
    {_conn, other_ref} = create_listing(other, "baskasinin ilani", %{"category" => "spor"})

    conn = request(:post, "/api/erase", %{"owner_tokens" => [Base.encode64(token)]})

    assert conn.status == 200
    assert json(conn)["status"] == "erased"
    assert request(:get, "/api/listings/#{ref}").status == 404
    assert request(:get, "/api/listings/#{other_ref}").status == 200
    assert Repo.aggregate(Listing, :count, :id) == 1
  end

  # -- surface invariants ----------------------------------------------------

  test "every API answer is the same size, uncached, and carries the CSP" do
    conns = [
      request(:get, "/api/listings"),
      request(:get, "/api/listings/999999"),
      request(:get, "/api/does-not-exist"),
      request(:post, "/api/listings", %{}),
      request(:get, "/api/pow")
    ]

    for conn <- conns do
      assert byte_size(conn.resp_body) == @response_bytes
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "an unknown route is a constant 404 that reflects nothing" do
    conn = request(:get, "/api/secret-path?owner_token=leaked")

    assert conn.status == 404
    assert json(conn) == %{"error" => "not_found"}
    refute conn.resp_body =~ "secret-path"
    refute conn.resp_body =~ "leaked"
    assert_padded(conn)
  end

  test "the router has no query-string token branch" do
    source = File.read!("lib/zifiri/router.ex")

    refute source =~ ~S|query(conn)["owner_token"]|
    refute source =~ ~S|query(conn)["owner_tokens"]|
    assert source =~ "@owner_header"
    assert source =~ "x-zifiri-owner"
  end

  # -- helpers ---------------------------------------------------------------

  defp request(method, path, body \\ nil, headers \\ []) do
    conn = Plug.Test.conn(method, path, if(body, do: JSON.encode(body), else: ""))

    conn =
      if body do
        Plug.Conn.put_req_header(conn, "content-type", "application/json")
      else
        conn
      end

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_req_header(conn, key, value)
      end)

    Zifiri.Endpoint.call(conn, Zifiri.Endpoint.init([]))
  end

  defp json(conn) do
    conn.resp_body
    |> String.trim_trailing()
    |> JSON.decode!()
  end

  defp assert_padded(conn) do
    assert byte_size(conn.resp_body) == @response_bytes
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  defp create_listing(token, text, overrides) do
    {envelope, _bucket} = padded_envelope(text)
    proof = proof(token, :crypto.hash(:sha256, envelope))

    body =
      %{
        "owner_token" => Base.encode64(token),
        "envelope" => Base.encode64(envelope),
        "title" => "Ilan",
        "category" => "spor",
        "currency" => "TRY",
        "price_cents" => 100
      }
      |> Map.merge(overrides)
      |> Map.merge(proof)

    conn = request(:post, "/api/listings", body)
    {conn, json(conn)["ref"]}
  end

  defp proof(token, subject) do
    {:ok, challenge} = Challenge.issue(Owner.hash(token), subject, bits: 4)

    %{
      "challenge_id" => challenge.id,
      "nonce" => Challenge.solve(challenge, subject),
      "bits" => challenge.bits
    }
  end

  defp padded_envelope(text) do
    {:ok, padded, bucket} = Envelope.encode(text)
    {padded, bucket}
  end

  defp room_message(text, ctr, opts \\ []) do
    {pubkey, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, padded} = Body.pad(text)
    epoch = Store.epoch("chat:lobby")
    input = Message.signing_input("chat:lobby", epoch, ctr, padded)
    nonce = Keyword.get(opts, :nonce, Pow.solve(Message.pow_hash(input), @pow_bits))
    sig = :crypto.sign(:eddsa, :none, input, [private, :ed25519])

    body = %{
      "body" => Base.encode64(text),
      "pubkey" => Base.url_encode64(pubkey, padding: false),
      "sig" => Base.url_encode64(sig, padding: false),
      "ctr" => ctr,
      "nonce" => nonce
    }

    {body, text}
  end
end
