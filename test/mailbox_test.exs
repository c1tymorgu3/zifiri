defmodule Zifiri.MailboxTest do
  @moduledoc """
  The sealed-sender store, addressed by a random `mailbox_id`
  (plan §P0-2, scope v5 §1:1, review v5 R5-06 / R5-11).

  The important tests here are not the round trip. They are:

    * the address is random — 10 000 ids, zero collisions, and the collision
      arithmetic written down rather than assumed;
    * the server never receives a public key — a source scan plus the exported
      function list, so \"no pk parameter\" is a failing test and not a promise;
    * the column set — `PRAGMA table_info` says five columns, none of which can
      name a sender, and `recipient_tag` is gone;
    * the cursor — ids that are never reused, because SQLite's default rowid
      is, and a reused id is a silently skipped message;
    * the write path — `deliver/3` queues into `Zifiri.Bucket`; only the
      publisher's tick writes rows, and it completes the batch to 120. A test
      that wants to read calls `publish/1`, which runs that same tick.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Bucket
  alias Zifiri.Bucket.Publisher
  alias Zifiri.Mailbox
  alias Zifiri.Mailbox.Envelope
  alias Zifiri.Mailbox.Sweeper
  alias Zifiri.Repo

  @ttl_ms 72 * 60 * 60 * 1000
  @bucket 4096
  @id_bytes 16

  setup do
    :ok = Bucket.reset()
    :rand.seed(:exsss, {7, 11, 13})
    :ok
  end

  # A stand-in for a device's mailbox address: 16 random-ish bytes. Not derived
  # from a key — there is no key in this module any more — so the helper takes a
  # label only to make failures readable.
  defp mailbox(label),
    do: :crypto.hash(:sha256, "mailbox:" <> label) |> binary_part(0, @id_bytes)

  defp mailbox_b64(label), do: Base.encode64(mailbox(label))
  defp envelope(byte \\ 0), do: :binary.copy(<<byte::8>>, @bucket)

  defp now, do: System.system_time(:millisecond)

  # Total rows, decoys included.
  defp rows, do: Repo.aggregate(Envelope, :count, :id)

  # Rows a named mailbox owns. This is the only count a delivery assertion may
  # use: the rest of the bucket belongs to nobody.
  defp rows(mailbox) do
    Repo.aggregate(from(e in Envelope, where: e.mailbox_id == ^raw_id(mailbox)), :count, :id)
  end

  defp ids(mailbox) do
    Repo.all(
      from e in Envelope,
        where: e.mailbox_id == ^raw_id(mailbox),
        order_by: [asc: e.id],
        select: e.id
    )
  end

  defp raw_id(mailbox) do
    {:ok, raw} = Mailbox.decode_id(mailbox)
    raw
  end

  # Closes the bucket: the same synchronous tick the publisher's timer runs.
  defp publish(now \\ nil) do
    opts = if now == nil, do: [], else: [now_ms: now]
    :ok = Publisher.tick(opts)
    :ok
  end

  # -- delivery and reading ---------------------------------------------------

  test "a delivered envelope comes back to the recipient unchanged" do
    alice = mailbox_b64("alice")
    blob = envelope(0xA5)

    assert {:ok, :queued} = Mailbox.deliver(alice, blob)
    # No direct write path: nothing is on disk until the bucket closes.
    assert rows() == 0

    assert :ok = publish()

    assert {:ok, %{envelopes: [row], cursor: cursor, more: false}} = Mailbox.fetch(alice)
    assert row.envelope == blob
    assert byte_size(row.envelope) == @bucket
    assert cursor == row.id
    assert row.expires_ms > row.created_ms
  end

  test "two deliveries to the same mailbox are two rows, oldest first" do
    alice = mailbox_b64("alice")

    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(1))
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(2))
    assert :ok = publish()

    assert [first, second] = ids(alice)
    assert second > first

    assert {:ok, %{envelopes: [a, b]}} = Mailbox.fetch(alice)
    assert {a.id, b.id} == {first, second}
    assert a.envelope == envelope(1)
    assert b.envelope == envelope(2)
  end

  test "a mailbox id that does not own the mail gets an empty page, not an error" do
    assert {:ok, :queued} = Mailbox.deliver(mailbox_b64("alice"), envelope())
    assert :ok = publish()

    assert {:ok, %{envelopes: [], cursor: 0, more: false}} =
             Mailbox.fetch(mailbox_b64("mallory"))
  end

  test "the row is addressed by exactly the 16 bytes the client chose" do
    raw = mailbox("alice")
    assert {:ok, :queued} = Mailbox.deliver(raw, envelope())
    assert :ok = publish()

    assert [%{mailbox_id: stored}] =
             Repo.all(
               from e in Envelope,
                 where: e.mailbox_id == ^raw,
                 select: map(e, [:mailbox_id])
             )

    assert stored == raw
    assert byte_size(stored) == @id_bytes

    # Raw, not hashed, not truncated, not re-encoded: what the client picked is
    # what the column holds, so the client can verify its own mailbox.
    refute stored == :crypto.hash(:sha256, raw)
    refute stored == binary_part(:crypto.hash(:sha256, raw), 0, @id_bytes)
  end

  test "the same id addresses the same mailbox and a different id does not" do
    assert {:ok, :queued} = Mailbox.deliver(mailbox_b64("alice"), envelope(1))
    assert :ok = publish()

    assert {:ok, %{envelopes: [_]}} = Mailbox.fetch(mailbox_b64("alice"))
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(mailbox_b64("alice2"))
  end

  test "raw bytes, hex, padded, unpadded and URL-safe base64 all address one mailbox" do
    raw = mailbox("alice")

    forms = [
      raw,
      Base.encode16(raw, case: :lower),
      Base.encode16(raw, case: :upper),
      Base.encode64(raw),
      Base.encode64(raw, padding: false),
      Base.url_encode64(raw, padding: false)
    ]

    for form <- forms do
      assert {:ok, decoded} = Mailbox.decode_id(form)
      assert decoded == raw, "form #{inspect(form)} did not normalise to the same 16 bytes"
    end

    # And they are one mailbox, not six.
    assert {:ok, :queued} = Mailbox.deliver(hd(forms), envelope())
    assert :ok = publish()

    for form <- forms do
      assert {:ok, %{envelopes: [_]}} = Mailbox.fetch(form)
    end

    assert rows(raw) == 1
  end

  test "the wire form round-trips through encode_id" do
    raw = mailbox("alice")

    assert raw |> Mailbox.encode_id() |> Mailbox.decode_id() == {:ok, raw}
    refute String.contains?(Mailbox.encode_id(raw), "=")
    refute String.contains?(Mailbox.encode_id(raw), "/")
    refute String.contains?(Mailbox.encode_id(raw), "+")
  end

  # -- the collision claim, measured ------------------------------------------

  test "10 000 random mailbox ids do not collide" do
    # 16 bytes = 128 bits. For n ids the probability that any two collide is
    # ~n(n-1)/2 / 2^128, so the analytic number is written down next to the
    # measurement and the next reader does not have to recompute it:
    #
    #   n = 10_000   -> ~2.9e-31   (this test)
    #   n = 1e6      -> ~1.5e-27
    #   n = 1e9      -> ~1.5e-21
    #   n = 2^32     -> ~0.5       (4.3 billion: the first size that matters)
    #
    # The ceiling is the number of mailboxes, not the id.
    n = 10_000

    ids = for _ <- 1..n, do: Mailbox.new_id()

    assert length(ids) == n
    assert Enum.all?(ids, &(byte_size(&1) == @id_bytes))

    distinct = ids |> MapSet.new() |> MapSet.size()
    assert distinct == n, "collision(s) found: #{n - distinct} in #{n} ids"

    # A random id must not be a function of anything: the same call twice gives
    # different values, which is exactly what HMAC(pepper, pk) could not do.
    refute Mailbox.new_id() == Mailbox.new_id()

    pairs = n * (n - 1) / 2
    assert pairs / :math.pow(2, 128) < 1.0e-25
  end

  # -- no public key reaches this module -------------------------------------

  test "the mailbox code takes no public key, and derives no tag" do
    # The review finding was that `recipient_tag = HMAC(pepper, pk)` forced the
    # client to hand its public key to the server to learn its own address.
    # This is the regression test for that: each token below would be a way to
    # reintroduce it, and none of them may appear in the store's *code* (the
    # moduledocs explain the history, so they are stripped before scanning).
    forbidden = [
      "recipient_pk",
      "recipient_tag",
      "decode_pk",
      "tag_for",
      ":crypto.mac",
      "Owner.pepper",
      "public_key",
      "pubkey"
    ]

    sources =
      [
        "lib/zifiri/mailbox.ex",
        "lib/zifiri/mailbox/envelope.ex",
        "lib/zifiri/mailbox/sweeper.ex",
        "lib/zifiri/mailbox/bucket_handler.ex",
        "lib/zifiri/mailbox/decoy.ex",
        "priv/repo/migrations/20261122230000_address_mailbox_by_mailbox_id.exs"
      ]
      |> Enum.map(fn path -> {path, code_only(File.read!(Path.join(File.cwd!(), path)))} end)

    for {path, source} <- sources, token <- forbidden do
      refute String.contains?(source, token),
             "#{path} still mentions #{token}: the server must not handle a key here"
    end

    # And the exported surface has no tag function at all.
    exported = Mailbox.__info__(:functions) ++ Mailbox.__info__(:macros)

    for {name, _arity} <- exported do
      refute name in [:tag, :tag_for, :tag_of],
             "Mailbox exports #{name}: tag derivation is what R5-06 removed"
    end

    # The functions that could take a key take a mailbox id instead.
    assert {:deliver, 3} in exported
    assert {:fetch, 3} in exported
    assert {:ack, 2} in exported
    assert {:decode_id, 1} in exported
  end

  test "the module documents that pepper rotation no longer applies here" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Mailbox)

    assert doc =~ "owner_hash"
    assert doc =~ "rotation"
    assert doc =~ "mailbox_id"
  end

  # -- TTL --------------------------------------------------------------------

  test "the default lifetime is 72 hours" do
    assert Mailbox.ttl_ms() == @ttl_ms

    alice = mailbox_b64("alice")
    start = now()
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(), now_ms: start)
    assert :ok = publish(start)

    assert [%{created_ms: created, expires_ms: expires}] =
             Repo.all(
               from e in Envelope,
                 where: e.mailbox_id == ^raw_id(alice),
                 select: map(e, [:created_ms, :expires_ms])
             )

    assert created == start
    assert expires - created == @ttl_ms
  end

  test "an envelope past its TTL is not returned, but is still on disk until the sweep" do
    alice = mailbox_b64("alice")
    start = now()

    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(), now_ms: start)
    assert :ok = publish(start)

    assert {:ok, %{envelopes: [_]}} = Mailbox.fetch(alice, 0, now_ms: start + @ttl_ms - 1)
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(alice, 0, now_ms: start + @ttl_ms)
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(alice, 0, now_ms: start + @ttl_ms + 1)

    assert rows(alice) == 1, "expiry hides the row; only the sweeper removes it"
  end

  test "the sweeper deletes expired rows and leaves live ones" do
    start = now()
    old = mailbox_b64("old")
    fresh = mailbox_b64("fresh")

    assert {:ok, :queued} = Mailbox.deliver(old, envelope(), now_ms: start)
    assert :ok = publish(start)

    assert {:ok, :queued} =
             Mailbox.deliver(fresh, envelope(), now_ms: start, ttl_ms: 2 * @ttl_ms)

    assert :ok = publish(start)

    # Decoys carry the batch's lifetime too, so the sweeper's return value is
    # the whole bucket; what a mailbox owns is what this test measures.
    assert Sweeper.sweep_now(start + @ttl_ms) > 0
    assert rows(old) == 0
    assert rows(fresh) == 1

    assert Sweeper.sweep_now(start + @ttl_ms) == 0

    assert {:ok, %{envelopes: []}} =
             Mailbox.fetch(mailbox_b64("old"), 0, now_ms: start + @ttl_ms)

    assert {:ok, %{envelopes: [_]}} =
             Mailbox.fetch(mailbox_b64("fresh"), 0, now_ms: start + @ttl_ms)
  end

  test "the sweeper process runs a pass on demand" do
    start = now()
    assert {:ok, :queued} = Mailbox.deliver(mailbox_b64("alice"), envelope(), now_ms: start)
    assert :ok = publish(start)

    {:ok, pid} =
      Sweeper.start_link(
        interval_ms: 60_000,
        name: :"sweeper_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Sweeper.sweep_now!(pid, start + @ttl_ms + 1) > 0
    assert rows() == 0
  end

  # -- size -------------------------------------------------------------------

  test "an envelope that is not exactly 4096 bytes is refused" do
    alice = mailbox_b64("alice")

    assert {:error, :bad_envelope} = Mailbox.deliver(alice, :binary.copy(<<0>>, 4095))
    assert {:error, :bad_envelope} = Mailbox.deliver(alice, :binary.copy(<<0>>, 4097))
    assert {:error, :bad_envelope} = Mailbox.deliver(alice, <<>>)
    assert {:error, :bad_envelope} = Mailbox.deliver(alice, "a string, not a blob")
    assert {:error, :bad_envelope} = Mailbox.deliver(alice, nil)

    assert rows() == 0

    assert {:ok, :queued} = Mailbox.deliver(alice, :binary.copy(<<0>>, 4096))
    assert :ok = publish()
    assert rows(alice) == 1
  end

  test "the table itself refuses an off-size envelope, not only the module" do
    id = mailbox("alice")

    assert_raise Exqlite.Error, ~r/4096/, fn ->
      Repo.insert_all(Envelope, [
        %{
          mailbox_id: id,
          envelope: :binary.copy(<<0>>, 100),
          created_ms: now(),
          expires_ms: now() + @ttl_ms
        }
      ])
    end
  end

  # -- the schema -------------------------------------------------------------

  test "the table has five columns, no sender column, and no recipient_tag" do
    columns = column_names("mailbox_envelopes")

    assert Enum.sort(columns) ==
             Enum.sort(~w(id mailbox_id envelope created_ms expires_ms))

    refute "recipient_tag" in columns, "the HMAC tag column must be gone (R5-06)"
    refute "pk" in columns
    refute "sender" in columns
    refute "sender_tag" in columns
    refute "from" in columns
    refute "author" in columns
    refute "author_id" in columns
    refute "conversation_id" in columns
    refute "thread_id" in columns
    refute "inserted_at" in columns
    refute "updated_at" in columns

    # Nothing that could be read as "who wrote this".
    refute Enum.any?(columns, &Regex.match?(~r/(sender|author|from|origin|account|user)/, &1)),
           "a column that could name a sender exists: #{inspect(columns)}"
  end

  test "the table has no column whose name is an identity" do
    forbidden =
      ~r/(^|_)(user_?id|ip|addr|address|email|mail|pubkey|public_?key|session|session_?id|fingerprint|token|agent|device)(_|$)/

    offenders =
      for column <- column_names("mailbox_envelopes"),
          Regex.match?(forbidden, column),
          do: column

    assert offenders == [], "identity-bearing column(s) found: #{inspect(offenders)}"
  end

  test "mailbox_id is indexed with id, so a read never scans another mailbox" do
    indexes =
      Repo.query!("PRAGMA index_list(mailbox_envelopes)").rows
      |> Enum.map(fn [_seq, name, unique, origin, partial] -> {name, unique, origin, partial} end)

    covering =
      Enum.filter(indexes, fn {name, _u, _o, _p} ->
        columns =
          Repo.query!("PRAGMA index_info(#{name})").rows
          |> Enum.map(fn [_seqno, _cid, col] -> col end)

        columns == ["mailbox_id", "id"]
      end)

    assert covering != [], "no (mailbox_id, id) index: #{inspect(indexes)}"
  end

  # -- the cursor -------------------------------------------------------------

  test "a fetch returns at most 200 envelopes and says there is more" do
    alice = mailbox_b64("alice")

    for i <- 1..205, do: assert({:ok, :queued} = Mailbox.deliver(alice, envelope(i)))
    assert :ok = publish()

    ids = ids(alice)
    assert length(ids) == 205

    assert {:ok, %{envelopes: page, cursor: cursor, more: true}} = Mailbox.fetch(alice)
    assert length(page) == 200
    assert Enum.map(page, & &1.id) == Enum.take(ids, 200)
    assert cursor == Enum.at(ids, 199)

    assert {:ok, %{envelopes: rest, cursor: last, more: false}} = Mailbox.fetch(alice, cursor)
    assert Enum.map(rest, & &1.id) == Enum.drop(ids, 200)
    assert last == List.last(ids)
  end

  test "a limit above the ceiling is clamped to 200" do
    alice = mailbox_b64("alice")

    for i <- 1..201, do: assert({:ok, :queued} = Mailbox.deliver(alice, envelope(i)))
    assert :ok = publish()

    assert {:ok, %{envelopes: page, more: true}} = Mailbox.fetch(alice, 0, limit: 10_000)
    assert length(page) == 200
  end

  test "the since cursor neither repeats nor skips an envelope" do
    alice = mailbox_b64("alice")

    for i <- 1..7, do: assert({:ok, :queued} = Mailbox.deliver(alice, envelope(i)))
    assert :ok = publish()

    ids = ids(alice)

    assert drain(alice, 0, 2) == ids
    assert drain(alice, 0, 2) == Enum.uniq(drain(alice, 0, 2))
  end

  test "the cursor returns nothing when there is nothing new" do
    alice = mailbox_b64("alice")
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope())
    assert :ok = publish()

    assert [id] = ids(alice)
    assert {:ok, %{envelopes: [], cursor: ^id, more: false}} = Mailbox.fetch(alice, id)
  end

  test "an id is never reused, so an ack cannot hide the next delivery" do
    alice = mailbox_b64("alice")

    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(1))
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(2))
    assert :ok = publish()

    assert [first, second] = ids(alice)

    # Ack the newest row: with a plain SQLite rowid the next insert would take
    # `second` again and a client holding that cursor would never see it.
    assert {:ok, 1} = Mailbox.ack(alice, [second])

    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(3))
    assert :ok = publish()

    assert [^first, third] = ids(alice)
    assert third > second

    assert {:ok, %{envelopes: [row], cursor: ^third}} = Mailbox.fetch(alice, first)
    assert row.envelope == envelope(3)
  end

  # -- ack --------------------------------------------------------------------

  test "ack deletes what the caller read" do
    alice = mailbox_b64("alice")
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(1))
    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(2))
    assert :ok = publish()

    assert [one, two] = ids(alice)

    assert {:ok, 1} = Mailbox.ack(alice, [one])
    assert rows(alice) == 1

    assert {:ok, %{envelopes: [%{id: ^two}]}} = Mailbox.fetch(alice)

    assert {:ok, 1} = Mailbox.ack(alice, two)
    assert rows(alice) == 0
  end

  test "ack does not delete another mailbox's envelopes" do
    alice = mailbox_b64("alice")
    bob = mailbox_b64("bob")

    assert {:ok, :queued} = Mailbox.deliver(alice, envelope(1))
    assert {:ok, :queued} = Mailbox.deliver(bob, envelope(2))
    assert :ok = publish()

    assert [alice_id] = ids(alice)
    assert [bob_id] = ids(bob)

    assert {:ok, 0} = Mailbox.ack(alice, [bob_id])
    assert rows(bob) == 1

    assert {:ok, %{envelopes: [%{id: ^bob_id}]}} = Mailbox.fetch(bob)
    assert {:ok, 1} = Mailbox.ack(alice, [alice_id])
    assert rows(alice) == 0
  end

  test "ack with an empty list deletes nothing" do
    assert {:ok, :queued} = Mailbox.deliver(mailbox_b64("alice"), envelope())
    assert :ok = publish()

    assert {:ok, 0} = Mailbox.ack(mailbox_b64("alice"), [])
    assert rows(mailbox_b64("alice")) == 1
  end

  # -- bad input --------------------------------------------------------------

  test "a mailbox id that is not 16 bytes is refused everywhere" do
    bad = [
      mailbox("alice") |> binary_part(0, 15),
      mailbox("alice") <> <<0>>,
      Base.encode64(mailbox("alice")) |> binary_part(0, 21),
      "",
      "not base64 at all!!",
      nil,
      123,
      <<0::128>>,
      mailbox("alice") |> :binary.copy(2)
    ]

    for id <- bad do
      assert {:error, :bad_mailbox_id} = Mailbox.deliver(id, envelope()),
             "deliver accepted #{inspect(id)}"

      assert {:error, :bad_mailbox_id} = Mailbox.fetch(id),
             "fetch accepted #{inspect(id)}"

      assert {:error, :bad_mailbox_id} = Mailbox.ack(id, [1]),
             "ack accepted #{inspect(id)}"
    end

    assert rows() == 0
  end

  test "the all-zero id is refused, so a forgotten field is not a shared mailbox" do
    assert {:error, :bad_mailbox_id} = Mailbox.decode_id(<<0::128>>)
    assert {:error, :bad_mailbox_id} = Mailbox.decode_id(Base.encode64(<<0::128>>))
    assert {:error, :bad_mailbox_id} = Mailbox.decode_id(String.duplicate("0", 32))
  end

  test "a cursor that is not a non-negative integer is refused" do
    alice = mailbox_b64("alice")

    assert {:error, :bad_cursor} = Mailbox.fetch(alice, -1)
    assert {:error, :bad_cursor} = Mailbox.fetch(alice, "12")
    assert {:error, :bad_cursor} = Mailbox.ack(alice, ["one"])
  end

  # -- helpers ----------------------------------------------------------------

  # Pages a mailbox to the end with a small limit, in order, and returns the ids
  # it saw. A duplicated or skipped id shows up as a mismatch against `ids`.
  defp drain(mailbox, cursor, limit) do
    case Mailbox.fetch(mailbox, cursor, limit: limit) do
      {:ok, %{envelopes: [], cursor: _}} ->
        []

      {:ok, %{envelopes: page, cursor: next}} ->
        Enum.map(page, & &1.id) ++ drain(mailbox, next, limit)
    end
  end

  defp column_names(table) do
    Repo.query!("PRAGMA table_info(#{table})").rows
    |> Enum.map(fn [_cid, name | _] -> name end)
  end

  # The source with heredocs and whole-line comments removed: the docs explain
  # the history (`recipient_tag`, the pepper) on purpose, the code must not
  # contain it.
  defp code_only(source) do
    source
    |> String.split("\"\"\"")
    |> Enum.take_every(2)
    |> Enum.join("\n")
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end
end
