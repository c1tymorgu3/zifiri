defmodule Zifiri.Repo.Migrations.AddressMailboxByMailboxId do
  @moduledoc """
  Replaces `recipient_tag` with `mailbox_id` (review v5 R5-06, R5-11).

  ## What changed and why

  `recipient_tag` was `HMAC-SHA256(pepper, "zifiri/mailbox/v1" <> recipient_pk)
  [0..15]`. The client could not compute it — it does not hold the pepper — so
  the flow was: send the recipient's public key to the API, get the tag back,
  seal to the tag. The server therefore learned the exact key it was supposed
  to be hiding, and two rows sharing a tag were provably one key. Rotating the
  pepper also silently orphaned every stored envelope, because the address of
  each row changed under it.

  `mailbox_id` is 16 random bytes chosen by the recipient's device
  (`crypto.getRandomValues`) and never derived from anything the server knows.
  The server sees a 128-bit label and nothing else: no public key, no tag
  derivation, no pepper. It is stored raw — not hashed, not truncated, not
  re-encoded — because hashing a uniformly random 128-bit value buys nothing
  and would only make the stored column a value the client cannot verify.

  ## Why the old rows are dropped

  A row written under the old scheme is addressed by a value that no longer
  exists anywhere in the code, so it cannot be fetched by anyone after this
  migration. Keeping it would leave a column of unreadable 4 KB blobs. The
  store is a 72-hour buffer by design, so the cost is bounded by the TTL.

  SQLite cannot add a `NOT NULL` column without a default and cannot drop an
  indexed column in place, so the table is recreated rather than altered. The
  column set stays five: `id`, `mailbox_id`, `envelope`, `created_ms`,
  `expires_ms`.

  `id` stays `AUTOINCREMENT` for the reason it was chosen the first time:
  without it SQLite reuses the rowid of the largest deleted row, and a client
  holding that id as its `since` cursor would silently skip the next delivery.
  """

  use Ecto.Migration

  def up do
    execute("DROP TABLE IF EXISTS mailbox_envelopes")

    create table(:mailbox_envelopes, primary_key: false) do
      # :serial renders as INTEGER PRIMARY KEY AUTOINCREMENT on SQLite — the
      # monotonic, never-reused cursor value.
      add(:id, :serial, primary_key: true)

      # Exactly 16 random bytes. Indexed with `id` so a read is one range scan
      # over one mailbox and never touches another mailbox's rows.
      add(:mailbox_id, :binary, null: false)

      # Exactly 4096 bytes — the bucket size. The trigger below enforces it.
      add(:envelope, :binary, null: false)

      add(:created_ms, :integer, null: false)
      add(:expires_ms, :integer, null: false)
    end

    create(index(:mailbox_envelopes, [:mailbox_id, :id]))
    create(index(:mailbox_envelopes, [:expires_ms]))

    size_guard_up()
  end

  # Irreversible on purpose. A rollback would have to restore a tag column that
  # no client can compute any more (the pepper-derived address is gone from the
  # client too), so it would produce a table nobody can read from. Rolling
  # forward is a redeploy; rolling back is a restore.
  def down do
    raise Ecto.MigrationError,
          "mailbox_envelopes is addressed by mailbox_id: rolling back would restore " <>
            "a tag column no client can compute. Redeploy the previous release and " <>
            "restore the table from a backup instead."
  end

  # The bucket is the anonymity set: a 4 KB envelope and a 300-byte envelope in
  # the same table would be a size signature even with the sender column
  # absent. The check lives in the table, not only in `Zifiri.Mailbox`, because
  # every future writer (sweeper, import, console) shares this file.
  defp size_guard_up do
    execute("""
    CREATE TRIGGER mailbox_envelopes_size_guard
    BEFORE INSERT ON mailbox_envelopes
    WHEN length(NEW.envelope) != 4096
    BEGIN
      SELECT RAISE(ABORT, 'mailbox envelope must be exactly 4096 bytes');
    END
    """)
  end
end
