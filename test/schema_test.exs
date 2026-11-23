defmodule Zifiri.SchemaTest do
  @moduledoc """
  Enforces plan §3.1 and §4.3 at the storage layer: there is no identity
  column anywhere in the database, and each v5 table has exactly the columns
  the plan lists.

  The test is written as an allowlist, not a denylist, because a denylist only
  catches the names someone thought of. If P2 adds `seed_fingerprint` to a
  table, this fails whether or not anyone remembered to add it to a ban list.

  Two claims get a test of their own because they are the product, not a
  schema detail: the forum row is gone (scope v5 has three planes and no
  forum), and a listing or a mailbox envelope cannot grow a `sender`.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Listings.Listing
  alias Zifiri.Mailbox.Envelope, as: MailboxEnvelope
  alias Zifiri.Repo

  # The whole database, table by table. Adding a table means editing this map,
  # which is the review checkpoint the plan asks for.
  @allowed_tables %{
    # The moderation audit chain (§8.2): one row per link, chained by `prev`.
    # No identity column and no sub-day timestamp — `day` is the only time
    # value, for the same reason no v5 row has an `inserted_at`. The plane is
    # not routed until it is ported off the forum row, but its chain is still
    # the only place a moderation action is recorded.
    "mod_audit" => ~w(n e prev action reason day target role),
    # The listing plane (scope v5): plaintext metadata by design, envelope
    # body, and `created_day` instead of a timestamp. `owner_hash` is not
    # unique — one owner may run several listings.
    "listings" => ~w(id title body price_cents currency category owner_hash status created_day),

    # The 1:1 envelope store (scope v5 §1:1). Five columns: 16 random bytes the
    # recipient's device chose, a 4 KB sealed blob the server cannot open, and
    # two millisecond timestamps. No sender, no conversation, no recipient key
    # — the absence of a sender column *is* the product claim, so this map is
    # where it is enforced.
    "mailbox_envelopes" => ~w(id mailbox_id envelope created_ms expires_ms),

    # Created by Ecto itself; not application data.
    "schema_migrations" => ~w(version inserted_at)
  }

  # Substrings that would mean the server can identify a writer. `owner_hash`
  # is deliberately not in this list: it is a per-write HMAC, not an identity
  # (§3.3). `pubkey`/`public_key` are here because a stored key would let the
  # server link two rows by the same seed; `sender` because a sealed-sender
  # store that records one is not sealed.
  @forbidden ~r/(^|_)(user_?id|ip|addr|address|email|mail|sender|pubkey|public_?key|author|author_?id|session|session_?id|fingerprint|token|agent|device|account)(_|$)/

  # The names a reviewer looks for first, spelled out so a failure says which
  # claim broke rather than "a regex matched".
  @identity_columns ~w(sender sender_id ip email user_id)

  test "the database contains only the tables and columns the plan allows" do
    tables = table_names()

    assert Enum.sort(tables) == Enum.sort(Map.keys(@allowed_tables)),
           """
           unexpected table set. Allowed: #{inspect(Map.keys(@allowed_tables))}
           found: #{inspect(tables)}
           """

    for table <- tables do
      columns = column_names(table)
      allowed = Map.fetch!(@allowed_tables, table)

      assert Enum.sort(columns) == Enum.sort(allowed),
             "table #{table} has columns #{inspect(columns)}, expected exactly #{inspect(allowed)}"
    end
  end

  test "no table or column name looks like an identity" do
    offenders =
      for table <- table_names(),
          name <- [table | column_names(table)],
          Regex.match?(@forbidden, name) do
        "#{table}.#{name}"
      end

    assert offenders == [], "identity-bearing column(s) found: #{Enum.join(offenders, ", ")}"
  end

  test "a listing or a mailbox envelope cannot grow a sender" do
    for table <- ~w(listings mailbox_envelopes) do
      columns = column_names(table)

      for name <- @identity_columns do
        refute name in columns, "#{table} must not carry #{name}: its absence is the claim"
      end
    end
  end

  test "the forum row is gone" do
    refute "posts" in table_names(),
           "scope v5 has three planes and no forum; `posts` is dropped by a migration"
  end

  test "the listing row carries no sub-day timestamp" do
    columns = column_names("listings")

    refute "inserted_at" in columns
    refute "updated_at" in columns
    refute "created_at" in columns
    refute Enum.any?(columns, &String.ends_with?(&1, "_at"))

    assert "created_day" in columns, "the only time value on a listing is a UTC day (§4.3)"
  end

  test "owner_hash is not unique on a listing" do
    unique_on_owner =
      Enum.any?(indexes("listings"), fn [name, sql] ->
        String.contains?(String.downcase(name), "owner_hash") and
          String.contains?(String.upcase(to_string(sql)), "UNIQUE")
      end)

    refute unique_on_owner,
           "one owner may run several listings; a UNIQUE owner_hash would turn that into a signal"
  end

  test "the mailbox row is addressed by a client-chosen id, not by a key" do
    columns = column_names("mailbox_envelopes")

    assert "mailbox_id" in columns

    refute "recipient_pk" in columns,
           "the address is what the server may know; the key stays with the client"

    refute "recipient_tag" in columns,
           "a server-derived tag meant the server was given the key to derive it"

    refute "conversation_id" in columns

    assert Enum.any?(indexes("mailbox_envelopes"), fn [name, _sql] ->
             String.contains?(name, "mailbox_id")
           end),
           "the read path is one range scan per mailbox and needs the id index"
  end

  test "the Ecto schemas expose no more fields than the tables" do
    assert_schema_matches(Listing, "listings")
    assert_schema_matches(MailboxEnvelope, "mailbox_envelopes")
  end

  defp assert_schema_matches(schema, table) do
    fields = schema.__schema__(:fields) |> Enum.map(&Atom.to_string/1)
    allowed = Map.fetch!(@allowed_tables, table)

    assert Enum.sort(fields) == Enum.sort(allowed),
           "#{inspect(schema)} exposes #{inspect(fields)}, expected #{inspect(allowed)}"
  end

  defp indexes(table) do
    Repo.query!(
      "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [table]
    ).rows
  end

  defp table_names do
    Repo.query!(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).rows
    |> Enum.map(fn [name] -> name end)
  end

  defp column_names(table) do
    Repo.query!("PRAGMA table_info(#{quote_identifier(table)})").rows
    |> Enum.map(fn [_cid, name | _rest] -> name end)
  end

  defp quote_identifier(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
