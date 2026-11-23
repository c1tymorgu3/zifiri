defmodule Zifiri.VanishTest do
  @moduledoc """
  Plan §6.1 and `docs/scope-v5.md`: a level-1 delete removes the row, a level-2
  delete removes the bytes. The second half of that sentence is not taken on
  faith here — the database file and its `-wal` are opened as plain binaries and
  searched for the body the user asked to disappear. There is no mocking of
  SQLite and no assertion that "the function was called"; the assertion is that
  the string is not in the file.

  ## What is covered

    * the three tables of scope v5: `listings` and the transitional `posts` are
      deletable by `owner_hash`, `mailbox_envelopes` is not deletable at all —
      and the tests assert both halves of that, including that no statement
      naming the envelope table is ever issued;
    * the disk sequence: `DELETE` → `wal_checkpoint(TRUNCATE)` → `VACUUM` →
      `wal_checkpoint(TRUNCATE)`, the truncated log, and the file actually
      getting smaller with an empty freelist;
    * the retry policy: three attempts, growing waits, `{:error, :busy}` when
      they run out, and no retry for a failure retrying cannot fix;
    * pending work: the conditional bucket/queue call is made for every hash
      being erased, and a missing module or a dead process does not stop the
      erase.

  ## Why these tests do not use `Zifiri.DataCase`

  `VACUUM` cannot run inside a transaction, and `Zifiri.DataCase` puts every
  test inside one. A wipe test that runs in a transaction would still "pass"
  while testing nothing about the file. So this module flips the sandbox to
  `:auto` for the duration (`setup`), which gives the test the pool's own
  connection with no wrapping transaction, and puts it back to `:manual` on
  exit so the `DataCase` modules are unaffected. Without a wrapping transaction
  there is nothing to roll back, so `setup` also truncates the tables before
  each test, and every canary is freshly random per test so a stale page from
  an earlier run can never make the scan pass or fail by accident.

  ## Why assertions are scoped to one `owner_hash`

  `listings` and `mailbox_envelopes` are written by other test modules too, and
  on a shared test database a `SELECT count(*) FROM listings` says more about
  whoever else ran a test in the same second than about this one. Every row
  count here is therefore scoped to the hash the test minted. The delete counts
  coming back from `Vanish` are scoped by construction: the module deletes by
  hash, so the number it returns is this test's rows.

  ## Why this module creates tables

  `listings` and `mailbox_envelopes` are owned by other changes; when this file
  runs before those migrations have landed, the fallback DDL below creates them
  (mirroring the real columns) so the three-table scope is actually exercised
  rather than skipped. `posts` is the opposite case: the migration that removes
  the v4 forum has already landed, so `insert_post/2` creates the table for the
  length of the test that needs it — a database that has not run that migration
  yet is exactly the state the transitional entry in `Vanish.delete_tables/0`
  exists for, and there is no other way to test it.

  Every table this module created is dropped again on exit, so a later migration
  still finds a database it can create them in. When the migrations are already
  there, `CREATE TABLE IF NOT EXISTS` is a no-op and the real schema is the one
  under test — the insert helper builds its statement from `PRAGMA table_info`,
  so it fills whatever columns the real table has.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Listings.Listing
  alias Zifiri.Owner
  alias Zifiri.Repo
  alias Zifiri.Vanish

  @moduletag :wipe

  # The stubs come first: a nested module is not reachable by its short name
  # without the alias below, and the tests reference it by the short name.

  defmodule DropRecorder do
    @moduledoc false
    # Stands in for `Zifiri.Bucket`: exports `drop_owner/1` and records who was
    # dropped, so the conditional call can be asserted without a bucket process.
    @table :vanish_drop_recorder

    def reset do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def drop_owner(hash), do: :ets.insert(@table, {hash, true})

    def dropped?(hash), do: :ets.member(@table, hash)

    def count, do: :ets.info(@table, :size)
  end

  defmodule NoDropOwner do
    @moduledoc false
    # Exists and is loaded, but does not export `drop_owner/1`:
    # `function_exported?/3` has to skip it rather than raise.
    def name, do: :no_drop_owner
  end

  defmodule DeadBucket do
    @moduledoc false
    # Exports the function, but the process it calls is not running: the call
    # exits, and `Vanish` has to catch that and carry on.
    def drop_owner(_hash), do: GenServer.call(:vanish_bucket_that_never_started, :drop)
  end

  alias __MODULE__.DeadBucket
  alias __MODULE__.DropRecorder
  alias __MODULE__.NoDropOwner

  # Fallbacks, used only when the migration that owns these tables is not in
  # place yet. The columns mirror the real migrations so the same fixtures work
  # against either.
  @listings_ddl """
  CREATE TABLE IF NOT EXISTS listings (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    body BLOB NOT NULL,
    price_cents INTEGER,
    currency TEXT NOT NULL,
    category TEXT NOT NULL,
    owner_hash BLOB NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    created_day DATE NOT NULL
  )
  """

  @envelopes_ddl """
  CREATE TABLE IF NOT EXISTS mailbox_envelopes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mailbox_id BLOB NOT NULL,
    envelope BLOB NOT NULL,
    created_ms INTEGER NOT NULL,
    expires_ms INTEGER NOT NULL
  )
  """

  # The v4 forum row, as `20261122120000_create_posts.exs` created it. Only a
  # fixture now: the drop migration removed the table, and the transitional
  # entry in `Vanish.delete_tables/0` is for databases that have not run it.
  @posts_ddl """
  CREATE TABLE IF NOT EXISTS posts (
    id INTEGER PRIMARY KEY,
    parent_id INTEGER,
    bucket INTEGER NOT NULL,
    body BLOB NOT NULL,
    day DATE NOT NULL,
    owner_hash BLOB NOT NULL,
    mod_state TEXT NOT NULL DEFAULT 'ok'
  )
  """

  # The envelope bucket: the real table refuses anything but 4096 bytes, and
  # that is the point (a smaller envelope in the same table is a size
  # signature), so the fixture pads instead of asking for an exemption.
  @envelope_bytes 4096

  setup do
    # Outside the sandbox transaction: VACUUM is refused inside one.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    created =
      ensure_table(:listings, @listings_ddl) ++ ensure_table(:mailbox_envelopes, @envelopes_ddl)

    for table <- [:posts, :listings, :mailbox_envelopes], table_exists?(table) do
      Repo.query!("DELETE FROM \"#{table}\"")
    end

    on_exit(fn ->
      # Truncate on the way out as well: this module runs outside the sandbox,
      # so whatever a test left behind is committed and visible to the next
      # module's transaction. A leftover envelope row is exactly the kind of
      # thing that makes an unrelated `Mailbox` count assertion fail.
      for table <- [:posts, :listings, :mailbox_envelopes], table_exists?(table) do
        Repo.query!("DELETE FROM \"#{table}\"")
      end

      # Only what this module created: dropping a table the migration owns would
      # be a test breaking the application it is testing.
      for table <- created, do: Repo.query!("DROP TABLE IF EXISTS \"#{table}\"")
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  describe "level 1 — erase/1" do
    test "removes a listing and reports one row deleted" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase(hash)
      assert listings_for(hash) == 0
    end

    test "removes every listing of one owner, not just the first" do
      # One owner may hold several listings, so the delete is not keyed on a
      # unique column and a `LIMIT 1`-shaped implementation would leave rows.
      hash = token_hash()
      for _ <- 1..3, do: insert_listing(canary_body(), hash)

      assert {:ok, 3} = Vanish.erase(hash)
      assert listings_for(hash) == 0
    end

    test "still removes the transitional posts row" do
      # The v4 table is deleted from until the surface is dropped with it: a
      # wipe that skipped it would leave the old bodies on disk afterwards.
      hash = token_hash()
      insert_post(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase(hash)
      assert posts_for(hash) == 0
    end

    test "leaves rows owned by other tokens alone" do
      hash = token_hash()
      other = token_hash()
      insert_listing(canary_body(), hash)
      insert_listing(canary_body(), other)
      insert_post(canary_body(), other)

      assert {:ok, 1} = Vanish.erase(hash)
      assert listings_for(hash) == 0
      assert listings_for(other) == 1
      assert posts_for(other) == 1
    end

    test "is idempotent: the second call reports zero" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase(hash)
      assert {:ok, 0} = Vanish.erase(hash)
    end

    test "writes no tombstone: the row is gone, not marked" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase(hash)

      assert listings_for(hash) == 0

      refute "deleted_at" in column_names(:listings),
             "a soft delete column is a record of who deleted what and when"
    end

    test "does not touch the file: level 1 is not a wipe" do
      # Deliberate: this is the difference between the levels. A `DELETE` in WAL
      # mode appends new pages to the log; the body is still in the main file
      # until something checkpoints and rebuilds it.
      hash = token_hash()
      body = canary_body()
      insert_listing(body, hash)
      assert {:ok, :done} = Vanish.purge()
      assert found_on_disk?(body), "precondition: the body must be in the file"

      assert {:ok, 1} = Vanish.erase(hash)

      assert found_on_disk?(body),
             "level 1 left no trace on disk, so the level-2 test below would pass trivially"
    end
  end

  describe "level 2 — erase_many/1" do
    test "deletes across listings and the transitional posts table in one call" do
      hash = token_hash()
      insert_listing(canary_body(), hash)
      insert_listing(canary_body(), hash)
      insert_post(canary_body(), hash)

      assert {:ok, 3} = Vanish.erase_many([hash])
      assert listings_for(hash) == 0
      assert posts_for(hash) == 0
    end

    test "works on a database where the transitional table is already gone" do
      # The drop migration has run on a real deployment, so the entry in
      # `delete_tables/0` has to be checked against the schema rather than
      # assumed: it must cost one empty lookup, not a failed erase.
      hash = token_hash()
      insert_listing(canary_body(), hash)
      Repo.query!("DROP TABLE IF EXISTS posts")

      assert {:ok, 1} = Vanish.erase_many([hash])
      assert listings_for(hash) == 0
    end

    test "counts a repeated token once" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase_many([hash, hash, hash])
    end

    test "the real pending list tolerates a bucket with no drop_owner/1" do
      # The bucket does not export `drop_owner/1` yet and a module that was
      # never written is in the list too; the conditional call has to skip both
      # and leave the caller's erase intact rather than raise.
      assert :ok =
               Vanish.drop_pending([token_hash()], [
                 {Zifiri.Bucket, :drop_owner},
                 {Zifiri.NeverWritten, :drop_owner}
               ])
    end

    test "does nothing for an empty list" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 0} = Vanish.erase_many([])
      assert listings_for(hash) == 1
    end

    test "a second erase_many is {:ok, 0} and still purges" do
      hash = token_hash()
      insert_listing(canary_body(), hash)

      assert {:ok, 1} = Vanish.erase_many([hash])
      assert {:ok, 0} = Vanish.erase_many([hash])
      assert listings_for(hash) == 0
    end

    test "still purges when the rows were already gone" do
      # The caller says "these are not on disk"; a previous attempt may have
      # deleted the rows and died before compacting.
      body = canary_body()
      hash = token_hash()
      insert_listing(body, hash)
      assert {:ok, :done} = Vanish.purge()
      assert found_on_disk?(body)
      assert {:ok, 1} = Vanish.erase(hash)
      assert found_on_disk?(body)

      assert {:ok, 0} = Vanish.erase_many([hash])
      refute found_on_disk?(body)
    end

    test "leaves no plaintext body in the database file" do
      body = canary_body()
      hash = token_hash()
      insert_listing(body, hash)

      # Precondition, and the control for the scanner: the same search does
      # find the body while the row is live.
      assert {:ok, :done} = Vanish.purge()
      assert found_on_disk?(body), "the scan cannot see the body at all"

      assert {:ok, 1} = Vanish.erase_many([hash])

      refute found_in_file?(body),
             "the body is still readable in #{db_path()} after a level-2 erase"
    end

    test "truncates the log: nothing in the -wal either" do
      body = canary_body()
      hash = token_hash()
      insert_listing(body, hash)

      assert {:ok, 1} = Vanish.erase_many([hash])

      assert File.stat!(wal_path()).size == 0, "the -wal was not truncated"
      refute found_in_wal?(body)
    end

    test "a body that was not erased is still findable by the same scan" do
      kept_body = canary_body()
      gone_body = canary_body()
      keep_hash = token_hash()
      gone_hash = token_hash()
      insert_listing(kept_body, keep_hash)
      insert_listing(gone_body, gone_hash)

      assert {:ok, 1} = Vanish.erase_many([gone_hash])

      assert listings_for(keep_hash) == 1
      refute found_on_disk?(gone_body)
      assert found_on_disk?(kept_body), "the scan reports clean for a body that is still there"
    end

    test "gives the pages back: a smaller file and an empty freelist" do
      # `insert_all/2` rather than the raw-SQL helper: the count is asserted at
      # insert time, so a fixture that failed to land shows up as a fixture
      # failure instead of as an erase that "only deleted 112 of 200".
      rows =
        for _ <- 1..200 do
          %{
            owner_hash: token_hash(),
            body: canary_body(),
            title: "page fixture",
            price_cents: 100,
            currency: "TRY",
            category: "goods",
            status: "open",
            created_day: ~D[2026-01-01]
          }
        end

      assert {200, nil} = Repo.insert_all(Listing, rows)
      hashes = Enum.map(rows, & &1.owner_hash)

      assert {:ok, :done} = Vanish.purge()
      size_before = File.stat!(db_path()).size

      assert {:ok, 200} = Vanish.erase_many(hashes)

      size_after = File.stat!(db_path()).size

      assert size_after < size_before,
             "VACUUM did not return the pages: #{size_before} -> #{size_after} bytes"

      assert pragma("freelist_count") == 0,
             "the pages the deleted rows lived on are still in the file"
    end
  end

  describe "the third table: mailbox_envelopes" do
    test "is in the wipe scope and out of the delete scope" do
      assert :mailbox_envelopes in Vanish.wipe_tables(),
             "the wipe is responsible for the whole file, envelopes included"

      refute :mailbox_envelopes in Vanish.delete_tables(),
             "a caller must not be able to delete envelope rows"

      assert Vanish.delete_tables() == [:posts, :listings]
    end

    test "erase_many never deletes an envelope, and never names the table" do
      # The whole point of the boundary: `mailbox_id` is an address, not an
      # owner, so there is no delete that could be addressed at it. This asserts
      # the absence of the statement, not just the absence of the effect.
      hash = token_hash()
      body = canary_body()
      insert_listing(canary_body(), hash)
      insert_envelope(hash, body)

      queries =
        capture_queries(fn ->
          assert {:ok, 1} = Vanish.erase_many([hash])
        end)

      assert envelopes_for(hash) == 1,
             "the envelope was deleted by a call that only named an owner hash"

      refute Enum.any?(queries, &String.contains?(&1, "mailbox_envelopes")),
             "an erase issued a statement against the envelope table"

      # And the file-level half: the envelope's own bytes are still there, which
      # is what "in the wipe scope, not in the delete scope" means in practice.
      # A 4 KB row is stored as an overflow chain split at page boundaries, so
      # the needle has to be a slice that fits inside one page — scanning for
      # the whole body would fail no matter what the erase did.
      assert found_on_disk?(binary_part(body, 0, 32)),
             "the envelope's bytes were removed from the file by a delete"
    end
  end

  describe "purge/0" do
    test "runs the deletes, then checkpoint, VACUUM, checkpoint in that order" do
      hash = token_hash()
      insert_listing(canary_body(), hash)
      insert_post(canary_body(), hash)

      queries =
        capture_queries(fn ->
          assert {:ok, 2} = Vanish.erase_many([hash])
        end)

      [first_delete, second_delete, before_vacuum, vacuum, after_vacuum] =
        Enum.filter(queries, fn sql ->
          String.starts_with?(sql, "DELETE FROM") or
            String.starts_with?(sql, "PRAGMA wal_checkpoint") or sql == "VACUUM"
        end)

      deletes = [first_delete, second_delete]

      assert Enum.all?(deletes, &(&1 =~ "owner_hash")),
             "the deletes must be the ones that remove the rows"

      assert Enum.any?(deletes, &(&1 =~ ~s("listings")))
      assert Enum.any?(deletes, &(&1 =~ ~s("posts")))

      assert before_vacuum == "PRAGMA wal_checkpoint(TRUNCATE)"
      assert vacuum == "VACUUM"

      assert after_vacuum == "PRAGMA wal_checkpoint(TRUNCATE)",
             "VACUUM writes through the WAL too; the log has to be truncated again"
    end

    test "is idempotent" do
      assert {:ok, :done} = Vanish.purge()
      assert {:ok, :done} = Vanish.purge()
    end

    test "the checkpoint alone clears the bytes; VACUUM is what returns the space" do
      # Which step does what, measured rather than assumed: `secure_delete`
      # zeroes the deleted cell in place, so a checkpoint without a VACUUM
      # already leaves nothing for a byte scan to find — and the file is still
      # the size it was. VACUUM is the step that gives the space back, which is
      # why `purge/0` does not stop at the checkpoint.
      body = canary_body()
      hash = token_hash()
      insert_listing(body, hash)
      assert {:ok, :done} = Vanish.purge()
      assert found_on_disk?(body)
      size_before = File.stat!(db_path()).size

      assert {:ok, 1} = Vanish.erase(hash)

      assert %{rows: [[0, _frames, _checkpointed] | _]} =
               Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")

      # The log is truncated here, so either file failing to hold the body is
      # the same claim: the bytes are gone.
      refute found_on_disk?(body)
      assert File.stat!(db_path()).size >= size_before
    end
  end

  describe "a locked database" do
    test "erase_many/1 reports {:error, :busy} instead of claiming a wipe" do
      body = canary_body()
      hash = token_hash()
      insert_listing(body, hash)

      assert {:ok, :done} = Vanish.purge()
      assert found_on_disk?(body), "precondition: the body is in the file"

      # Another connection holding a read snapshot is what makes a TRUNCATE
      # checkpoint impossible: it needs every reader out of the log.
      assert {:error, :busy} = with_reader(fn -> Vanish.erase_many([hash]) end)

      # Deleted, not scrubbed — the row is committed and the bytes are still
      # there. Reporting `{:ok, :done}` here would be the lie this test exists
      # to prevent.
      assert listings_for(hash) == 0
      assert found_on_disk?(body)
    end

    test "a purge leaves the connection's busy timeout at the configured value" do
      # exqlite mounts its timeout as a NIF busy handler, so the pragma reads 0
      # while a 5 s handler is in place; a purge lowers the pragma to fail fast
      # and must put the configured number back instead of zeroing it. The
      # assertion runs inside the same checkout the purge used, so it reads the
      # connection whose pragma was written.
      configured = Repo.config()[:busy_timeout]
      assert is_integer(configured)

      with_reader(fn ->
        Repo.checkout(fn ->
          assert {:error, :busy} = Vanish.purge()
          assert pragma("busy_timeout") == configured
        end)
      end)
    end
  end

  describe "the retry policy" do
    test "is three attempts with growing waits, then {:error, :busy}" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      statement = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, :busy}
      end

      {elapsed_us, result} = :timer.tc(fn -> Vanish.retry_busy(statement) end)

      assert result == {:error, :busy}
      assert Agent.get(counter, & &1) == 3, "the docs promise three attempts"
      assert Vanish.wipe_attempts() == 3

      [first, second] = Vanish.wipe_backoff_ms()
      assert Vanish.wipe_backoff_ms() == [50, 150], "the waits must be the documented ones"
      assert second > first, "the waits must grow"

      # The waits are really slept, not just declared: 50 + 150 ms.
      assert elapsed_us >= 190_000
    end

    test "a statement that succeeds on a retry is not reported as busy" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      statement = fn ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
          {:error, :busy}
        else
          :ok
        end
      end

      assert :ok = Vanish.retry_busy(statement, [1, 1])
      assert Agent.get(counter, & &1) == 2
    end

    test "a failure retrying cannot fix is not retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      statement = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, :vacuum}
      end

      assert {:error, :vacuum} = Vanish.retry_busy(statement, [1, 1, 1])
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "pending work" do
    test "calls every module that exports drop_owner/1 and skips one that does not" do
      DropRecorder.reset()
      hash = token_hash()

      assert :ok =
               Vanish.drop_pending([hash], [
                 {DropRecorder, :drop_owner},
                 {NoDropOwner, :drop_owner},
                 {Zifiri.VanishTest.NotDefinedAnywhere, :drop_owner}
               ])

      assert DropRecorder.dropped?(hash),
             "a bucket that exists must be told about the erase"

      # Precondition and count together: the skip must be a skip, not a call
      # that happened to be harmless, and a hash listed once must be dropped
      # once rather than per module.
      refute function_exported?(NoDropOwner, :drop_owner, 1)
      assert DropRecorder.count() == 1
    end

    test "drops each hash once, however many times it was listed" do
      DropRecorder.reset()
      hash = token_hash()

      assert :ok = Vanish.drop_pending([hash, hash, hash], [{DropRecorder, :drop_owner}])
      assert DropRecorder.count() == 1
    end

    test "survives a bucket process that is not running" do
      # A process that is not running holds nothing, so its pending entries are
      # already gone. The exit must not stop the row delete and the disk wipe.
      assert :ok = Vanish.drop_pending([token_hash()], [{DeadBucket, :drop_owner}])
    end
  end

  describe "connection pragmas" do
    test "secure_delete is on" do
      assert [[1]] = rows(Repo.query!("PRAGMA secure_delete"))
    end

    test "the log is on and synchronous is NORMAL" do
      assert [["wal"]] = rows(Repo.query!("PRAGMA journal_mode"))
      assert [[1]] = rows(Repo.query!("PRAGMA synchronous"))
    end
  end

  ## Fixtures

  defp token_hash, do: Owner.hash(:crypto.strong_rand_bytes(32))

  defp canary,
    do: "ZIFIRI-VANISH-" <> Base.encode16(:crypto.strong_rand_bytes(9), case: :lower)

  # Long enough to land in the middle of a page rather than in a record
  # overflow chain, so a stale page really does keep it.
  defp canary_body, do: String.duplicate(canary(), 40)

  defp insert_listing(body, owner_hash) do
    insert_row(:listings, %{
      "owner_hash" => blob_literal(owner_hash),
      "body" => blob_literal(body),
      "title" => "'zifiri test listing'",
      "currency" => "'TRY'",
      "category" => "'test'",
      "created_day" => "'2026-01-01'"
    })
  end

  defp insert_post(body, owner_hash) do
    # The v4 table is gone from a migrated database, so it is created for the
    # duration of a test that needs it and dropped again on exit. Creating it in
    # `setup` would leave a table the schema test forbids in place for the whole
    # file — and visible to anything else running against this database.
    ensure_posts_table()

    insert_row(:posts, %{
      "owner_hash" => blob_literal(owner_hash),
      "body" => blob_literal(body),
      "bucket" => "1",
      "day" => "'2026-01-01'"
    })
  end

  defp ensure_posts_table do
    if table_exists?(:posts) do
      :ok
    else
      Repo.query!(@posts_ddl)
      on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS posts") end)
      :ok
    end
  end

  defp insert_envelope(mailbox_id, body) do
    now = System.system_time(:millisecond)

    insert_row(:mailbox_envelopes, %{
      "mailbox_id" => blob_literal(mailbox_id),
      "envelope" => blob_literal(pad_to_envelope(body)),
      "created_ms" => Integer.to_string(now),
      "expires_ms" => Integer.to_string(now + :timer.hours(72))
    })
  end

  defp pad_to_envelope(body) do
    body <> :binary.copy(<<0>>, @envelope_bytes - byte_size(body))
  end

  # Built from `PRAGMA table_info`, so the same helper works against the
  # fallback DDL above and against the real migration: the columns that exist
  # are filled from `values`, and a NOT NULL column nobody named gets a literal
  # of its own type instead of failing the insert.
  defp insert_row(table, values) do
    {names, literals} =
      Enum.reduce(columns(table), {[], []}, fn column, {names, literals} ->
        cond do
          Map.has_key?(values, column.name) ->
            {[column.name | names], [Map.fetch!(values, column.name) | literals]}

          column.pk == 1 ->
            {names, literals}

          column.notnull == 0 or column.default != nil ->
            {names, literals}

          true ->
            {[column.name | names], [type_literal(column.type) | literals]}
        end
      end)

    quoted = Enum.map_join(names, ", ", fn name -> "\"" <> name <> "\"" end)

    Repo.query!("INSERT INTO \"#{table}\" (#{quoted}) VALUES (#{Enum.join(literals, ", ")})")

    :ok
  end

  defp type_literal(type) do
    type = String.downcase(type || "")

    cond do
      String.contains?(type, "int") -> "0"
      String.contains?(type, "real") -> "0.0"
      String.contains?(type, "floa") -> "0.0"
      String.contains?(type, "doub") -> "0.0"
      String.contains?(type, "date") -> "'2026-01-01'"
      String.contains?(type, "blob") -> "x'00'"
      true -> "'z'"
    end
  end

  # A BLOB literal, not a bound parameter: a binary bound through `?` lands as
  # text, and a 32-byte hash of random bytes is not valid UTF-8.
  defp blob_literal(binary), do: "x'" <> Base.encode16(binary, case: :lower) <> "'"

  ## Schema

  defp ensure_table(table, ddl) do
    if table_exists?(table) do
      []
    else
      Repo.query!(ddl)
      [table]
    end
  end

  defp table_exists?(table) do
    %{rows: rows} = Repo.query!("PRAGMA table_info(\"#{table}\")")
    rows != []
  end

  defp columns(table) do
    %{rows: rows} = Repo.query!("PRAGMA table_info(\"#{table}\")")

    Enum.map(rows, fn [cid, name, type, notnull, default, pk] ->
      %{cid: cid, name: name, type: type, notnull: notnull, default: default, pk: pk}
    end)
  end

  defp column_names(table), do: Enum.map(columns(table), & &1.name)

  defp rows_for(table, owner_hash) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM \"#{table}\" WHERE owner_hash = #{blob_literal(owner_hash)}"
      )

    count
  end

  defp listings_for(owner_hash), do: rows_for(:listings, owner_hash)

  defp posts_for(owner_hash), do: rows_for(:posts, owner_hash)

  defp envelopes_for(mailbox_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM mailbox_envelopes WHERE mailbox_id = #{blob_literal(mailbox_id)}"
      )

    count
  end

  ## Disk

  defp db_path, do: Repo.config()[:database]
  defp wal_path, do: db_path() <> "-wal"

  # Byte search, not `String.contains?/2`: the file is not text.
  defp found_in_file?(needle), do: present?(bytes(db_path()), needle)

  defp found_in_wal?(needle), do: present?(bytes(wal_path()), needle)

  # A row written since the last checkpoint lives in the `-wal`, not in the main
  # file, so "the bytes are still there" has to mean "in either of the database's
  # files". Asserting on the main file alone makes the test depend on when
  # SQLite happened to checkpoint.
  defp found_on_disk?(needle), do: found_in_file?(needle) or found_in_wal?(needle)

  defp present?(binary, needle), do: :binary.match(binary, needle) != :nomatch

  defp bytes(path) do
    case File.read(path) do
      {:ok, binary} -> binary
      # A truncated log is deleted on some platforms and zero-length on others.
      {:error, :enoent} -> ""
    end
  end

  # A second connection, outside the pool, holding a read snapshot: the state
  # `wal_checkpoint(TRUNCATE)` reports busy for.
  defp with_reader(fun) do
    {:ok, reader} = Exqlite.Sqlite3.open(db_path())
    :ok = Exqlite.Sqlite3.execute(reader, "BEGIN")
    {:ok, statement} = Exqlite.Sqlite3.prepare(reader, "SELECT count(*) FROM sqlite_master")
    {:row, _} = Exqlite.Sqlite3.step(reader, statement)

    try do
      fun.()
    after
      Exqlite.Sqlite3.release(reader, statement)
      Exqlite.Sqlite3.execute(reader, "ROLLBACK")
      Exqlite.Sqlite3.close(reader)
    end
  end

  ## Queries

  defp rows(%{rows: rows}), do: rows

  defp pragma(name) do
    case Repo.query!("PRAGMA #{name}") do
      %{rows: [[value] | _]} -> value
      %{rows: []} -> nil
    end
  end

  defp capture_queries(fun) do
    handler = "vanish-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:zifiri, :repo, :query],
      fn _event, _measurements, metadata, _config -> send(parent, {:query, metadata.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_queries()
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:query, sql} -> collect_queries([sql | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
