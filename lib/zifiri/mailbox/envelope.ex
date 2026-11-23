defmodule Zifiri.Mailbox.Envelope do
  @moduledoc """
  One stored 1:1 envelope — the five columns of `mailbox_envelopes`, no more.

  The row is the whole of what the server knows:

    * `mailbox_id` — 16 random bytes the recipient's device chose. Not derived
      from a key, not a hash of one, not reversible to one. It is the only link
      between two envelopes in the same mailbox, and the only thing that says
      who a row is for.
    * `envelope` — 4096 opaque bytes, the client's sealed blob, unreadable by
      the server.
    * `created_ms` / `expires_ms` — when it landed and when it stops being
      readable (72 h later).

  There is no sender field, no conversation id, no account id, no session, no
  address, and no public key. `test/mailbox_test.exs` asserts the column set by
  reading `PRAGMA table_info`, so adding one here is a failing test rather than
  a review note nobody reads.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "mailbox_envelopes" do
    field :mailbox_id, :binary
    field :envelope, :binary
    field :created_ms, :integer
    field :expires_ms, :integer
  end
end
