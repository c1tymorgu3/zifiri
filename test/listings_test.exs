defmodule Zifiri.ListingsTest do
  @moduledoc """
  The listing plane's contract: what a write costs, what a read reveals, and
  what the schema refuses to carry.

  Every fixture is built through the real pipeline — `Zifiri.Envelope` pads the
  body, `Zifiri.Pow.Challenge` issues and `Challenge.solve` grinds the proof,
  `Zifiri.Owner` derives the hash — so a failure here means the pipeline
  changed, not that a fixture drifted.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Envelope
  alias Zifiri.Listings
  alias Zifiri.Listings.Listing
  alias Zifiri.Owner
  alias Zifiri.Pow.Challenge

  @bits 4

  setup do
    Challenge.clear()
    Repo.delete_all(Listing)
    :ok
  end

  ## Fixtures

  defp token, do: :crypto.strong_rand_bytes(32)

  defp envelope(text) do
    {:ok, body, bucket} = Envelope.encode(text)
    {body, bucket}
  end

  defp proof(owner_hash, payload_hash) do
    {:ok, challenge} = Challenge.issue(owner_hash, payload_hash, bits: @bits)

    %{
      challenge_id: challenge.id,
      bits: challenge.bits,
      nonce: Challenge.solve(challenge, payload_hash)
    }
  end

  defp attrs(token, text, opts \\ []) do
    {body, _bucket} = envelope(text)
    owner_hash = Owner.hash(token)
    payload_hash = :crypto.hash(:sha256, body)

    base = %{
      owner_token: token,
      body: body,
      title: "Red Bicycle",
      price_cents: 12_500,
      currency: "TRY",
      category: "sport"
    }

    base
    |> Map.merge(Map.new(opts))
    |> Map.merge(proof(owner_hash, payload_hash))
  end

  defp create!(token, text, opts \\ []) do
    {:ok, listing} = Listings.create(attrs(token, text, opts))
    listing
  end

  defp raw(id), do: Repo.get(Listing, id)

  ## Create, get, list

  test "create stores a padded envelope, plaintext metadata and a day, not a second" do
    token = token()

    {:ok, listing} =
      Listings.create(attrs(token, "Selling a red bicycle, 54cm frame.", price_cents: 12_500))

    assert listing.id > 0
    assert listing.title == "Red Bicycle"
    assert listing.price_cents == 12_500
    assert listing.currency == "TRY"
    assert listing.category == "sport"
    assert listing.status == "open"
    assert %Date{} = listing.created_day
    assert listing.created_day == Date.utc_today()
    assert listing.owner_hash == Owner.hash(token)

    # The read path serves the description, never the padding.
    assert listing.body == "Selling a red bicycle, 54cm frame."

    # The stored bytes are a bucket: the plaintext rides inside it, but the
    # row's length says nothing about how long the description is.
    stored = raw(listing.id)
    assert byte_size(stored.body) in Envelope.buckets()
    assert byte_size(stored.body) > byte_size(listing.body)
    assert {:ok, "Selling a red bicycle, 54cm frame."} = Envelope.payload(stored.body)
  end

  test "the table carries no sub-day timestamp and no identity column" do
    fields = Listing.__schema__(:fields)

    refute :inserted_at in fields
    refute :updated_at in fields
    assert :created_day in fields
    assert :owner_hash in fields
  end

  test "get returns the listing by ref and nil for anything else" do
    listing = create!(token(), "Desk lamp, works.")

    assert %Listing{id: id, title: "Red Bicycle"} = Listings.get(listing.id)
    assert id == listing.id
    assert %Listing{} = Listings.get(Integer.to_string(listing.id))
    assert Listings.get(listing.id + 999) == nil
    assert Listings.get("not-a-ref") == nil
    assert Listings.get(nil) == nil
  end

  test "list serves open listings newest first" do
    a = create!(token(), "first")
    b = create!(token(), "second")
    c = create!(token(), "third")

    ids = Enum.map(Listings.list(), & &1.id)

    assert ids == [c.id, b.id, a.id]
  end

  ## Envelope and encoding

  test "create refuses a body that is not a padded envelope" do
    token = token()
    body = "not padded at all"
    owner_hash = Owner.hash(token)

    attrs =
      attrs(token, "placeholder")
      |> Map.put(:body, body)
      |> Map.merge(proof(owner_hash, :crypto.hash(:sha256, body)))

    assert Listings.create(attrs) == {:error, :bad_envelope}
  end

  test "create refuses a body whose padding was tampered with" do
    token = token()
    {body, _bucket} = envelope("tamper me")
    flipped = binary_part(body, 0, byte_size(body) - 1) <> <<1>>
    owner_hash = Owner.hash(token)

    attrs =
      attrs(token, "placeholder")
      |> Map.put(:body, flipped)
      |> Map.merge(proof(owner_hash, :crypto.hash(:sha256, flipped)))

    assert Listings.create(attrs) == {:error, :bad_envelope}
  end

  test "create refuses a body that is not valid UTF-8" do
    token = token()
    {body, _bucket} = envelope(<<0xFF, 0xFE, 0xFD>>)
    owner_hash = Owner.hash(token)

    attrs =
      attrs(token, "placeholder")
      |> Map.put(:body, body)
      |> Map.merge(proof(owner_hash, :crypto.hash(:sha256, body)))

    assert Listings.create(attrs) == {:error, :bad_utf8}
    assert Repo.aggregate(Listing, :count) == 0
  end

  ## Proof of work

  test "create without a proof is refused" do
    attrs =
      attrs(token(), "no proof")
      |> Map.drop([:challenge_id, :nonce, :bits])

    assert Listings.create(attrs) == {:error, :bad_pow}
    assert Repo.aggregate(Listing, :count) == 0
  end

  test "a proof solved for another payload does not open this listing" do
    token = token()
    owner_hash = Owner.hash(token)
    {other_body, _} = envelope("some other body")

    attrs =
      attrs(token, "the body being written")
      |> Map.merge(proof(owner_hash, :crypto.hash(:sha256, other_body)))

    assert Listings.create(attrs) == {:error, :bad_pow}
  end

  test "a proof is single-use" do
    token = token()
    {body, _} = envelope("same bytes twice")
    owner_hash = Owner.hash(token)
    proof = proof(owner_hash, :crypto.hash(:sha256, body))

    attrs =
      %{
        owner_token: token,
        body: body,
        title: "One",
        currency: "TRY",
        category: "sport"
      }
      |> Map.merge(proof)

    assert {:ok, _} = Listings.create(attrs)
    assert Listings.create(attrs) == {:error, :bad_pow}
  end

  test "invalid metadata is refused before the proof is spent" do
    token = token()
    {body, _bucket} = envelope("body")
    owner_hash = Owner.hash(token)

    base =
      %{owner_token: token, body: body, currency: "TRY", category: "sport"}
      |> Map.merge(proof(owner_hash, :crypto.hash(:sha256, body)))

    # One challenge, spent once: the bad request does not burn it.
    assert Listings.create(Map.put(base, :title, String.duplicate("a", 121))) ==
             {:error, :bad_title}

    assert {:ok, %Listing{title: "Fine"}} = Listings.create(Map.put(base, :title, "Fine"))
  end

  ## Metadata rules

  test "title must be one to 120 characters" do
    token = token()

    assert {:ok, _} = Listings.create(attrs(token, "ok", title: String.duplicate("a", 120)))

    assert Listings.create(attrs(token, "ok", title: String.duplicate("a", 121))) ==
             {:error, :bad_title}

    assert Listings.create(attrs(token, "ok", title: "   ")) == {:error, :bad_title}
    assert Listings.create(attrs(token, "ok", title: nil)) == {:error, :bad_title}
  end

  test "price is optional but never negative" do
    token = token()

    assert {:ok, listing} = Listings.create(attrs(token, "free", price_cents: nil))
    assert listing.price_cents == nil

    assert {:ok, zero} = Listings.create(attrs(token, "zero", price_cents: 0))
    assert zero.price_cents == 0

    assert Listings.create(attrs(token, "negative", price_cents: -1)) == {:error, :bad_price}
    assert Listings.create(attrs(token, "string", price_cents: "100")) == {:error, :bad_price}
  end

  test "currency is a three-letter code, normalised to upper case" do
    token = token()

    assert {:ok, listing} = Listings.create(attrs(token, "body", currency: "try"))
    assert listing.currency == "TRY"

    assert Listings.create(attrs(token, "body", currency: "TR")) == {:error, :bad_currency}
    assert Listings.create(attrs(token, "body", currency: "TRYY")) == {:error, :bad_currency}
    assert Listings.create(attrs(token, "body", currency: "12A")) == {:error, :bad_currency}
  end

  test "category is required and at most 32 characters" do
    token = token()

    assert {:ok, _} = Listings.create(attrs(token, "body", category: String.duplicate("c", 32)))

    assert Listings.create(attrs(token, "body", category: String.duplicate("c", 33))) ==
             {:error, :bad_category}

    assert Listings.create(attrs(token, "body", category: "")) == {:error, :bad_category}
  end

  ## Feed

  test "list filters by category" do
    sport = create!(token(), "a", category: "sport")
    _music = create!(token(), "b", category: "music")

    assert [%Listing{id: id}] = Listings.list(category: "sport")
    assert id == sport.id
    assert Listings.list(category: "nothing") == []
  end

  test "list searches the title case-insensitively" do
    bicycle = create!(token(), "a", title: "Red Bicycle")
    _helmet = create!(token(), "b", title: "Blue Helmet")

    assert [%Listing{id: id}] = Listings.list(search: "bicycle")
    assert id == bicycle.id
    assert [%Listing{id: ^id}] = Listings.list(search: "RED BIC")
    assert Listings.list(search: "zzz") == []
  end

  test "search wildcards are text, not pattern syntax" do
    create!(token(), "a", title: "Red Bicycle")
    create!(token(), "b", title: "Blue Helmet")

    # `%` is stripped, so "Red%" is the search for "Red", not "everything".
    assert [%Listing{title: "Red Bicycle"}] = Listings.list(search: "Red%")
    assert Listings.list(search: "%") == []
    assert Listings.list(search: "_") == []
  end

  test "list pages with a cursor and never repeats a row" do
    listings = for i <- 1..35, do: create!(token(), "body #{i}", title: "Listing #{i}")

    first = Listings.list()
    assert length(first) == 30
    assert hd(first).id == List.last(listings).id

    second = Listings.list(before: List.last(first).id)
    assert length(second) == 5

    first_ids = MapSet.new(first, & &1.id)
    second_ids = MapSet.new(second, & &1.id)

    assert MapSet.disjoint?(first_ids, second_ids)
    assert MapSet.size(MapSet.union(first_ids, second_ids)) == 35

    assert Listings.list(before: List.last(second).id) == []
  end

  test "list honours a smaller limit and clamps a larger one" do
    for i <- 1..31, do: create!(token(), "body #{i}", title: "Listing #{i}")

    assert length(Listings.list(limit: 2)) == 2
    assert length(Listings.list(limit: 500)) == 30
    assert length(Listings.list(limit: 0)) == 30
  end

  test "a cursor naming no listing yields an empty page" do
    create!(token(), "only one")

    assert Listings.list(before: 999_999) == []
    assert Listings.list(before: "garbage") == []
  end

  ## Update

  test "the owner updates the body and the metadata" do
    token = token()
    listing = create!(token, "original body")
    day = listing.created_day

    {:ok, updated} =
      Listings.update(listing.id, token, attrs(token, "replacement body", title: "Green Bicycle"))

    assert updated.id == listing.id
    assert updated.title == "Green Bicycle"
    assert updated.created_day == day
    assert updated.status == "open"
    assert updated.owner_hash == listing.owner_hash

    assert Listings.get(listing.id).body == "replacement body"
  end

  test "update refuses a stranger's token" do
    listing = create!(token(), "mine")
    stranger = token()

    assert Listings.update(listing.id, stranger, attrs(stranger, "theirs")) ==
             {:error, :forbidden}

    assert Listings.get(listing.id).body == "mine"
  end

  test "update refuses an unknown ref and an invalid body" do
    token = token()

    assert Listings.update(999_999, token, attrs(token, "body")) == {:error, :not_found}

    listing = create!(token, "still here")
    attrs = attrs(token, "still here") |> Map.put(:body, "unpadded")

    assert Listings.update(listing.id, token, attrs) == {:error, :bad_envelope}
    assert Listings.get(listing.id).body == "still here"
  end

  ## Close and erase

  test "close hides the listing from the feed but keeps it readable" do
    token = token()
    listing = create!(token, "closing soon")

    {:ok, closed} =
      Listings.close(
        listing.id,
        token,
        proof(Owner.hash(token), Listings.close_subject(listing.id))
      )

    assert closed.status == "closed"
    assert Listings.list() == []
    assert %Listing{status: "closed"} = Listings.get(listing.id)
  end

  test "close requires a proof, and closing twice is not an error" do
    token = token()
    listing = create!(token, "closing soon")

    assert Listings.close(listing.id, token) == {:error, :bad_pow}

    proof = proof(Owner.hash(token), Listings.close_subject(listing.id))
    assert {:ok, %Listing{status: "closed"}} = Listings.close(listing.id, token, proof)
    assert {:ok, %Listing{status: "closed"}} = Listings.close(listing.id, token)
  end

  test "close refuses a stranger's token" do
    listing = create!(token(), "mine")
    stranger = token()

    assert Listings.close(listing.id, stranger) == {:error, :forbidden}

    assert Listings.close(
             listing.id,
             stranger,
             proof(Owner.hash(stranger), Listings.close_subject(listing.id))
           ) ==
             {:error, :forbidden}
  end

  test "a closed listing cannot be updated" do
    token = token()
    listing = create!(token, "closing soon")
    proof = proof(Owner.hash(token), Listings.close_subject(listing.id))
    {:ok, _} = Listings.close(listing.id, token, proof)

    assert Listings.update(listing.id, token, attrs(token, "reopen")) == {:error, :closed}
  end

  test "erase removes every listing of one owner and nothing else" do
    mine = token()
    other = token()

    a = create!(mine, "one")
    b = create!(mine, "two")
    theirs = create!(other, "three")

    proof = proof(Owner.hash(mine), Listings.erase_subject(Owner.hash(mine)))

    assert {:ok, 2} = Listings.erase(mine, proof)
    assert Listings.get(a.id) == nil
    assert Listings.get(b.id) == nil
    assert %Listing{id: id} = Listings.get(theirs.id)
    assert id == theirs.id
  end

  test "erase without a proof deletes nothing" do
    token = token()
    listing = create!(token, "still here")

    assert Listings.erase(token) == {:error, :bad_pow}
    assert %Listing{} = Listings.get(listing.id)
  end

  test "erase refuses a proof bound to another owner" do
    mine = token()
    other = token()
    listing = create!(mine, "mine")

    proof = proof(Owner.hash(other), Listings.erase_subject(Owner.hash(mine)))

    assert Listings.erase(mine, proof) == {:error, :bad_pow}
    assert %Listing{} = Listings.get(listing.id)
  end

  ## Schema

  test "the table carries the two indexes the plan asks for and no unique owner index" do
    %{rows: rows} =
      Repo.query!(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'listings'"
      )

    statements = Enum.map(rows, fn [_name, sql] -> sql || "" end)

    assert Enum.any?(
             statements,
             &(String.contains?(&1, "category") and String.contains?(&1, "created_day"))
           )

    assert Enum.any?(statements, &String.contains?(&1, "owner_hash"))

    # A unique index on `owner_hash` would make a second listing by the same
    # owner impossible — or, worse, a signal that the first one exists.
    refute Enum.any?(statements, &String.contains?(String.upcase(&1), "UNIQUE"))
  end

  ## One owner, many listings

  test "one owner may run several listings; owner_hash is not unique" do
    token = token()

    {:ok, first} = Listings.create(attrs(token, "first item", title: "First"))
    {:ok, second} = Listings.create(attrs(token, "second item", title: "Second"))

    assert first.id != second.id
    assert first.owner_hash == second.owner_hash

    assert Repo.aggregate(from(l in Listing, where: l.owner_hash == ^first.owner_hash), :count) ==
             2

    assert length(Listings.list()) == 2
  end
end
