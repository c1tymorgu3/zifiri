defmodule Zifiri.Repo.Migrations.CreateMailboxEnvelopes do
  @moduledoc """
  The 1:1 envelope store (plan §P0-2, scope v5 §1:1).

  Five columns and no sixth. `recipient_tag` is `HMAC-SHA256(pepper,
  "zifiri/mailbox/v1" <> recipient_pk)[0..15]`: the server can address a
  mailbox without holding the key it addresses, and the tag is the only thing
  that says who a row is for. There is deliberately **no** sender column, no
  conversation id, no account id and no address — a sealed-sender store that
  could record a sender is not a sealed-sender store. `test/mailbox_test.exs`
  reads `PRAGMA table_info` and fails if one appears.

  `id` is `AUTOINCREMENT`, not the SQLite default rowid. Without it SQLite
  reuses the rowid of the largest deleted row, so `ack`-ing the newest
  envelope could hand its id to the next delivery — and a client holding that
  id as its `since` cursor would silently skip the new message. Monotonic ids
  are a correctness requirement of the cursor, not a preference.

  `created_ms` is a millisecond timestamp on purpose, and it is *not* the
  cursor: deliveries inside the same millisecond are indistinguishable by it.
  It exists so the row can be aged out and so a client can show "when" it
  received something, not to order concurrent writes.
  """

  use Ecto.Migration

  def change do
    create table(:mailbox_envelopes, primary_key: false) do
      # :serial renders as INTEGER PRIMARY KEY AUTOINCREMENT on SQLite, which
      # is the monotonic id the `since` cursor depends on.
      add :id, :serial, primary_key: true

      # 16 bytes of HMAC output. Indexed with `id` so the read path is one
      # range scan per mailbox and never touches another mailbox's rows.
      add :recipient_tag, :binary, null: false

      # Exactly 4096 bytes — the bucket size. The trigger below enforces it.
      add :envelope, :binary, null: false

      add :created_ms, :integer, null: false
      add :expires_ms, :integer, null: false
    end

    create index(:mailbox_envelopes, [:recipient_tag, :id])
    create index(:mailbox_envelopes, [:expires_ms])

    # The bucket is the anonymity set: a 4 KB envelope and a 300-byte envelope
    # in the same table would be a size signature even with the sender column
    # absent. The check lives in the table, not only in `Zifiri.Mailbox`,
    # because every future writer (sweeper, import, console) shares this file.
    execute(
      """
      CREATE TRIGGER mailbox_envelopes_size_guard
      BEFORE INSERT ON mailbox_envelopes
      WHEN length(NEW.envelope) != 4096
      BEGIN
        SELECT RAISE(ABORT, 'mailbox envelope must be exactly 4096 bytes');
      END
      """,
      "DROP TRIGGER IF EXISTS mailbox_envelopes_size_guard"
    )
  end
end
