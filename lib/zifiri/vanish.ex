defmodule Zifiri.Vanish do
  @moduledoc """
  Deletion that reaches the disk, in two levels (plan §6.1, `docs/scope-v5.md`).

  ## The two levels

  | level | what runs | what it buys |
  | --- | --- | --- |
  | 1 — `erase/1` | one physical `DELETE` of the rows owned by a token | the body is gone from every query and every response |
  | 2 — `erase_many/1`, `purge/0` | `DELETE` → checkpoint → `VACUUM` → checkpoint | the body is gone from the file and from the `-wal` |

  Level 1 is a plain physical `DELETE`. There is no tombstone, no
  `deleted_at`, no shadow table: a tombstone is a record of who deleted what
  and when, which is precisely the link the rest of the design refuses to keep
  (§3.1). "Nothing left to say it was here" is the requirement, not a
  limitation.

  ## Which tables are in scope

  Three tables, two of them deletable:

  | table | addressed by | why |
  | --- | --- | --- |
  | `posts` | `owner_hash` | transitional. The v4 forum row, dropped by `20261122220000_drop_posts.exs`. It stays in the list because the list is checked against the live schema: a database that has not run that migration yet — a rolling deploy, a restored backup — still holds published bodies, and a wipe that only knew about `listings` would leave them there. On a migrated database the entry costs one `PRAGMA table_info` that finds nothing. |
  | `listings` | `owner_hash` | the v5 public row. One owner may hold several listings, so the delete is not keyed on a unique column; every listing of every given hash goes. |
  | `mailbox_envelopes` | — | covered by the wipe, never by a delete. See below. |

  The list is not trusted as written: each table is checked against the live
  schema first and skipped unless it exists *and* has an `owner_hash` column.
  That is not defensive coding, it is the boundary — a table with no owner
  column cannot be addressed by an owner, so nothing this module lists can
  turn into a delete of somebody else's rows. It also means the module keeps
  working while a migration is half-landed: `posts` present and `listings`
  absent deletes from `posts`, and the other way round.

  ## `mailbox_envelopes`: in the wipe, not in the delete

  A mailbox envelope is not owned by the token that wrote it. The row is
  `mailbox_id`, the sealed 4 KB envelope and two timestamps; the sender exists
  only inside the ciphertext, and the row is addressed by `mailbox_id` — 16
  random bytes the *recipient's* device chose
  (`20261122230000_address_mailbox_by_mailbox_id.exs`). It is the address of a
  mailbox, not an identifier of the caller.

  So `erase_many/1` does not delete envelopes, and specifically does not delete
  by `mailbox_id`. Three reasons, and they are the design rather than an
  omission:

    * **The id is a bearer capability.** Whoever holds `mailbox_id` can deliver
      to it and read it — there is no account behind it to check, which is the
      point. A delete keyed on it would turn the same string into "empty this
      mailbox", handing a remote wipe of someone else's mail to anyone who has
      seen a single delivery or read request.
    * **It is a link.** A call that says "delete the envelopes at mailbox X"
      tells the operator that this caller knows mailbox X, at a wall-clock
      instant, and which rows that was — the association the rest of the design
      refuses to store (§3.1, §4.4). A read is at least a read; a delete is a
      write that proves the id was held.
    * **There is nothing to key on.** There is no sender column to match, and
      adding one would be a record of who wrote to whom. A user therefore
      cannot delete their own envelopes through this module — only their own
      listings (and, while a database still has the table, their own `posts`).
      Envelopes leave by their TTL (`expires_ms`, 72 h) and by bucket rotation,
      both of which delete by age, never by caller.

  The envelopes are still in the *wipe* scope: they live in the same file, so
  the checkpoint → `VACUUM` → checkpoint below scrubs the pages they occupied
  exactly like any other deleted row's. `wipe_tables/0` reports all three
  tables for that reason; `delete_tables/0` reports the two that a caller can
  address. The tests assert both halves, because a doc claim about a boundary
  nobody checks is a comment.

  ## Pending work: the bucket

  A message still waiting to be written has no row, so no `DELETE` can reach
  it — and a wipe that only deletes rows is followed by the body appearing in
  a later turn, after the caller was told "yok ol" (F-18). Level 2 therefore
  drops the pending entries of every hash it is given before it touches the
  disk: `Zifiri.Bucket.drop_owner/1`. The call goes through
  `Code.ensure_loaded?/1` + `function_exported?/3`, so the module compiles and
  runs whether or not the bucket has landed yet, and it is not required for
  the erase to succeed.

  A bucket process that is not running is not a failure: its state lived in
  that process, so the pending entry is already gone. The call is caught on
  `:exit` and the row delete and disk wipe go ahead — those are the part with
  the security claim, and a dead bucket is no reason to skip them.

  ## Why the order is checkpoint → VACUUM → checkpoint

  A committed `DELETE` in WAL mode only appends new pages to the `-wal`; the
  main file still holds the old page with the body in it, and the `-wal` holds
  the new image until it is truncated.

    * The **first checkpoint** (`wal_checkpoint(TRUNCATE)`) pushes the committed
      pages into the main file and truncates the log, so the state after the
      `DELETE` is the state on disk.
    * **`VACUUM`** rebuilds the database into a fresh file: the pages the body
      occupied are given back to the filesystem, `PRAGMA freelist_count` goes to
      zero, and the file stops carrying the shape of what used to be in it — a
      file that stays the size of the post someone deleted has not forgotten it.
    * The **final checkpoint** truncates the log again, because `VACUUM` itself
      wrote its rebuild through the WAL.

  To be exact about which step does what, since the tests are what make this
  claim honest: with `PRAGMA secure_delete=ON` (set per connection in
  `Zifiri.Repo`) SQLite zeroes deleted cell content in place, so the first
  checkpoint has usually already removed the body from the bytes — the test
  that erases, runs only a checkpoint and then scans the file finds nothing,
  while the file is still exactly the size it was. That is what makes `VACUUM`
  non-optional rather than decorative: it is the step that returns the space,
  empties the freelist and stops the file from carrying the shape of what used
  to be in it. A wipe that stopped at the checkpoint would pass a byte scan and
  still hand back a file whose size records how much was deleted.

  ## Retry policy

  `wal_checkpoint(TRUNCATE)` fails with `busy` when another connection still
  holds a read snapshot, and `VACUUM` fails the same way for the same reason.
  Both are normal, transient conditions (a reader is mid-query), so both are
  retried on the same schedule: **three attempts**, waiting 50 ms before the
  second and 150 ms before the third. If every attempt is busy the result is
  `{:error, :busy}`; a wipe that did not happen never answers `{:ok, :done}`.
  A failure that retrying cannot fix (a malformed statement, a read-only file)
  is not retried at all — it comes back as `{:error, :checkpoint | :vacuum}`
  on the first attempt.

  Three attempts is a policy, not a measurement: it rides out a reader that is
  finishing a query and still answers while the request is worth answering.
  The `VanishSweeper` is the second chance for the case where it is not enough
  — the rows are already committed by then, so `{:error, :busy}` means
  "deleted, not yet scrubbed", never "still there".

  ## Locking

  Every statement of the wipe runs inside its own `Repo.checkout/1`, with the
  lowered `busy_timeout` applied first and restored after. SQLite's busy
  handler is a property of a *connection*, not of the database, so the pragma
  and the statement it is meant to govern have to reach the same connection;
  issuing the pragma through the pool and then the statement through the pool
  would put them on whichever connections the pool happened to hand out, and
  the restore on a third.

  The checkout covers one statement, not the whole purge: the waits between
  retries happen with the connection released, so a wipe that is waiting out a
  busy database does not also starve every other caller of the pool for the
  length of its backoff.

  ## Why the `DELETE` is written with a hex literal

  `owner_hash` is a `BLOB`. Binding an Elixir binary through `?` does not store
  a BLOB: exqlite binds a binary as *text*, SQLite accepts it into a non-strict
  column, and a 32-byte hash of random bytes is not valid UTF-8 — the stored
  value comes back shorter than it went in and a later `x'…'` comparison no
  longer matches it. The rows would then look deleted (zero rows matched) while
  staying in the table. So every hash is written as `x'<hex>'`: a real BLOB
  literal, byte-exact on the way in and on the way out, and built only from
  `Base.encode16/2` output of a server-side hash, so there is no text to
  escape. This is also why the module needs no Ecto schema per table.
  """

  alias Zifiri.Repo

  # Tables a caller can address by owner. Order matters only for readability:
  # the deletes run in one transaction, so a failure in the second table rolls
  # the first one back rather than leaving a half-erase.
  @delete_tables [:posts, :listings]

  # Everything the disk wipe is responsible for, including the table no caller
  # can address. Reported by `wipe_tables/0` and asserted in the tests.
  @wipe_tables [:posts, :listings, :mailbox_envelopes]

  # SQLite's default host-parameter limit is 999; 400 leaves room for the
  # statement to grow and keeps each DELETE well inside it. Hashes go in as
  # literals rather than parameters (see "Why the DELETE is written with a hex
  # literal"), so this is a statement-length budget, not a parameter count.
  @chunk_size 400

  # Three attempts per statement, waits growing between them: enough to ride
  # out a reader finishing a query, short enough that the caller still gets an
  # answer worth having.
  @wipe_attempts 3
  @wipe_backoff_ms [50, 150]

  # The two numbers describe one policy, so they are checked against each other
  # at compile time: a schedule with the wrong number of waits would silently
  # mean four attempts or two while the docs and `wipe_attempts/0` say three.
  if length(@wipe_backoff_ms) + 1 != @wipe_attempts do
    raise "the retry schedule has #{length(@wipe_backoff_ms)} waits, which is not " <>
            "#{@wipe_attempts} attempts"
  end

  # A wipe attempt is allowed to wait this long before it is called busy and
  # retried, instead of parking on the pool's full five-second handler.
  @wipe_busy_timeout_ms 200
  # What exqlite connects with when `:busy_timeout` is not configured.
  @default_busy_timeout_ms 2_000

  # Called only for hashes a caller asked to erase. Optional: the bucket is the
  # v5 home for pending silent-mode messages, and a boot without it still
  # erases rows.
  @pending_owner_calls [{Zifiri.Bucket, :drop_owner}]

  @type owner_hash :: binary()

  @doc """
  Every table the disk wipe is responsible for.

  `:mailbox_envelopes` is here and not in `delete_tables/0`: its pages are
  scrubbed by the same checkpoint and `VACUUM`, but no caller can delete a row
  from it (see the module doc).
  """
  @spec wipe_tables() :: [atom()]
  def wipe_tables, do: @wipe_tables

  @doc """
  Every table a caller can delete rows from, by `owner_hash`.

  `:mailbox_envelopes` is deliberately absent: a user cannot delete their own
  envelopes, only their own listings and posts.
  """
  @spec delete_tables() :: [atom()]
  def delete_tables, do: @delete_tables

  @doc """
  Level 1: physically `DELETE` the rows owned by one token hash.

  Returns `{:ok, count}`, where `count` is the number of rows that existed —
  so a second call with the same hash returns `{:ok, 0}` rather than an error.
  The row is not marked, moved, or copied anywhere first.

  This does not compact the file. Callers that need the bytes gone from disk
  use `erase_many/1` or follow with `purge/0`.

  `{:error, :delete}` means SQLite refused the statement itself (a missing
  table, a malformed statement). `{:error, :busy}` means it was locked past
  the connection's timeout. In both cases nothing was deleted and the call can
  be retried.
  """
  @spec erase(owner_hash()) :: {:ok, non_neg_integer()} | {:error, :delete | :busy}
  def erase(owner_hash) when is_binary(owner_hash), do: delete_rows([owner_hash])

  @doc """
  Level 2: `DELETE` every row for every given hash — from every table a caller
  can address — drop the hashes' pending bucket/queue entries, then wipe the
  disk.

  `{:ok, count}` on success, where `count` is the number of rows deleted across
  `posts` and `listings`; `{:error, :busy}` if another connection kept a read
  snapshot open through all checkpoint/VACUUM attempts; `{:error, :checkpoint |
  :vacuum}` if SQLite refused an operation for a reason retrying will not fix;
  `{:error, :delete}` if the `DELETE` itself was refused.

  The rows are committed before the wipe starts, so `{:error, :busy}` means
  "deleted, not yet scrubbed" — not "still there". The purge is never described
  as a success it did not have.

  The purge runs even when `count` is zero — the call means "make sure these
  are not on disk", and a previous attempt may have deleted the rows and then
  failed to compact. An empty list is the one case with nothing to do.
  """
  @spec erase_many([owner_hash()]) ::
          {:ok, non_neg_integer()} | {:error, :busy | :checkpoint | :vacuum | :delete}
  def erase_many([]), do: {:ok, 0}

  def erase_many(owner_hashes) when is_list(owner_hashes) do
    # F-18: rows are only half of "these are gone" — an entry still in a bucket
    # is a message that has not been written yet, and it would be published
    # minutes after the caller was told they were erased.
    with {:ok, deleted} <- delete_rows(owner_hashes),
         :ok <- drop_pending(owner_hashes),
         {:ok, :done} <- purge() do
      {:ok, deleted}
    end
  end

  @doc """
  The disk half of level 2: checkpoint → `VACUUM` → checkpoint.

  Safe to call on its own; that is what the daily maintenance pass does. Returns
  `{:ok, :done}` only when all three steps ran.
  """
  @spec purge() :: {:ok, :done} | {:error, :busy | :checkpoint | :vacuum}
  def purge do
    with :ok <- checkpoint(),
         :ok <- vacuum(),
         :ok <- checkpoint() do
      {:ok, :done}
    end
  rescue
    # Not getting a connection at all is the same condition the checkpoint and
    # the VACUUM report: something else is holding the database.
    DBConnection.ConnectionError -> {:error, :busy}
  end

  # One statement, one checked-out connection: the lowered timeout is written on
  # the connection the statement is about to run on, and restored on the same
  # one. The checkout covers the statement only — see "Locking".
  defp on_wipe_conn(statement) do
    Repo.checkout(fn ->
      previous_busy_timeout = configured_busy_timeout()
      set_busy_timeout(@wipe_busy_timeout_ms)

      try do
        statement.()
      after
        set_busy_timeout(previous_busy_timeout)
      end
    end)
  end

  ## Rows

  defp delete_rows(owner_hashes) do
    hashes = Enum.uniq(owner_hashes)

    unless Enum.all?(hashes, &is_binary/1) do
      raise ArgumentError, "owner hashes must be binaries"
    end

    case deletable_tables() do
      # Nothing to delete from: not an error, and not a reason to skip the
      # purge. `{:ok, 0}` is the same answer a second erase gives.
      [] ->
        {:ok, 0}

      tables ->
        tables
        |> delete_all_tables(hashes)
        |> case do
          {:ok, count} -> {:ok, count}
          {:error, reason} -> if busy?(reason), do: {:error, :busy}, else: {:error, :delete}
        end
    end
  rescue
    # A locked file is a normal condition here; the caller retries it. Anything
    # else is a bug in this module and is left to raise.
    DBConnection.ConnectionError -> {:error, :busy}
  end

  # One transaction across all tables: a delete that fails on the second table
  # must not leave the first one's rows gone and the caller told "error".
  defp delete_all_tables(tables, hashes) do
    Repo.transaction(fn ->
      Enum.reduce(tables, 0, fn table, total ->
        case delete_table(table, hashes) do
          {:ok, count} -> total + count
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  defp delete_table(table, hashes) do
    hashes
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, total} ->
      case Repo.query(delete_sql(table, chunk)) do
        {:ok, %{num_rows: count}} -> {:cont, {:ok, total + count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Identifiers come from the closed list above, so interpolating them is not a
  # string built from input. The hashes are hex, so neither are they.
  defp delete_sql(table, chunk) do
    "DELETE FROM \"#{table}\" WHERE owner_hash IN (#{blob_literals(chunk)})"
  end

  defp blob_literals(hashes) do
    Enum.map_join(hashes, ", ", fn hash -> "x'" <> Base.encode16(hash, case: :lower) <> "'" end)
  end

  # The list above, filtered by the live schema: a table that is not there yet
  # (a half-landed migration) or that has no owner column (mailbox_envelopes)
  # cannot be addressed by an owner, so it is not deleted from.
  defp deletable_tables do
    Enum.filter(@delete_tables, &owned_table?/1)
  end

  defp owned_table?(table) do
    case Repo.query("PRAGMA table_info(\"#{table}\")") do
      {:ok, %{rows: []}} ->
        false

      {:ok, %{rows: rows}} ->
        Enum.any?(rows, fn [_cid, name | _rest] -> name == "owner_hash" end)

      {:error, _reason} ->
        false
    end
  end

  ## Pending work

  @doc false
  # Split out so the conditional call can be exercised without a bucket process
  # existing: the test passes its own module list. `modules` is
  # `[{module, function}]`, and only entries that are loaded and export the
  # function at arity 1 are called.
  @spec drop_pending([owner_hash()], [{module(), atom()}]) :: :ok
  def drop_pending(owner_hashes, modules) when is_list(owner_hashes) and is_list(modules) do
    calls =
      Enum.filter(modules, fn {module, function} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, 1)
      end)

    for hash <- Enum.uniq(owner_hashes), {module, function} <- calls do
      drop(module, function, hash)
    end

    :ok
  end

  defp drop_pending(owner_hashes), do: drop_pending(owner_hashes, @pending_owner_calls)

  defp drop(module, function, hash) do
    apply(module, function, [hash])
  catch
    # A bucket process that is not running holds nothing: its state died with
    # it, so the pending entry is already gone. The row delete and the disk
    # wipe must not be skipped because of that.
    :exit, _reason -> :ok
  end

  ## Disk

  defp checkpoint do
    retry_busy(fn -> on_wipe_conn(&truncate_checkpoint/0) end)
  end

  # A TRUNCATE checkpoint reports its own failure in the result row rather than
  # as an error: [busy, log_frames, checkpointed_frames]. busy = 0 is success.
  defp truncate_checkpoint do
    case Repo.query("PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, %{rows: [[0, _log, _checkpointed] | _]}} -> :ok
      {:ok, %{rows: [[_busy | _] | _]}} -> {:error, :busy}
      # No row: the database is not in WAL mode, so there is no log to truncate.
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :checkpoint}
    end
  end

  defp vacuum do
    retry_busy(fn -> on_wipe_conn(&run_vacuum/0) end)
  end

  defp run_vacuum do
    case Repo.query("VACUUM") do
      {:ok, _result} -> :ok
      {:error, reason} -> if busy?(reason), do: {:error, :busy}, else: {:error, :vacuum}
    end
  end

  @doc false
  # The retry policy, split out so it can be exercised without a database: a
  # lock that blocks `VACUUM` blocks the checkpoint in front of it, so a locked
  # file cannot reach this path from the outside. `statement` returns `:ok`,
  # `{:error, :busy}` or a reason that retrying will not fix. `backoff_ms` is
  # the wait before each retry, so its length plus one is the attempt count.
  @spec retry_busy((-> :ok | {:error, term()}), [non_neg_integer()]) :: :ok | {:error, term()}
  def retry_busy(statement, backoff_ms \\ @wipe_backoff_ms) do
    case statement.() do
      :ok ->
        :ok

      {:error, :busy} when backoff_ms != [] ->
        # Outside the checkout: waiting here holds no connection.
        [wait_ms | rest] = backoff_ms
        Process.sleep(wait_ms)
        retry_busy(statement, rest)

      # Out of retries: the database stayed locked. Reporting this as `:vacuum`
      # would read like a malformed statement; it is a busy database, and the
      # caller retries it exactly like a busy checkpoint.
      {:error, :busy} ->
        {:error, :busy}

      # Refused for a reason retrying cannot fix: do not burn the schedule on it.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The backoff schedule and attempt count, so a test can assert the policy the
  # docs promise.
  @spec wipe_backoff_ms() :: [pos_integer()]
  def wipe_backoff_ms, do: @wipe_backoff_ms

  @doc false
  @spec wipe_attempts() :: pos_integer()
  def wipe_attempts, do: @wipe_attempts

  # exqlite surfaces SQLITE_BUSY as an ordinary query error carrying a message
  # and no error code, so the message is the whole signal available.
  defp busy?(%{message: message}) when is_binary(message) do
    String.contains?(String.downcase(message), ["busy", "locked"])
  end

  defp busy?(_reason), do: false

  # Reads the *configured* value, not `PRAGMA busy_timeout`. exqlite installs
  # its timeout through a NIF busy handler (`Exqlite.Sqlite3.set_busy_timeout/2`)
  # precisely so a pragma cannot clobber it, which also means the pragma reads 0
  # while a five-second handler is mounted. Writing the pragma replaces that
  # handler with SQLite's own; restoring the same number is what keeps the
  # connection's waiting behaviour where it was.
  defp configured_busy_timeout do
    Keyword.get(Repo.config(), :busy_timeout, @default_busy_timeout_ms)
  end

  defp set_busy_timeout(timeout) when is_integer(timeout) do
    Repo.query!("PRAGMA busy_timeout=#{timeout}")
    :ok
  end
end
