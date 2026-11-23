defmodule Zifiri.Mailbox.BucketHandler do
  @moduledoc """
  Writes a 1:1 bucket batch: the real envelopes, completed to
  `Zifiri.Bucket.target/0` with decoys, in one transaction.

  The handler receives the drained `{:mailbox, tag, envelope, ttl}` tuples. It
  keeps every real tag, builds `target - n` decoys with the same lifetime, and
  inserts real and decoy rows together with `Repo.insert_all/3` inside a single
  `Repo.transaction/1`. The observer of the table sees 120 rows of the same
  size and cannot point at the real one.

  Nothing is written when the batch is empty: the publisher does not call a
  handler for an empty drain, and this clause is the second guard.

  The decoy lifetime is the batch's lifetime (all real envelopes in one bucket
  normally share it). If a caller mixes lifetimes inside one bucket, the first
  real envelope's lifetime is used — a decoy only needs to look like a row, and
  a length that varies would be the leak.
  """

  @behaviour Zifiri.Bucket.Publisher.Handler

  alias Zifiri.Bucket
  alias Zifiri.Mailbox.Decoy
  alias Zifiri.Mailbox.Envelope
  alias Zifiri.Repo

  @impl true
  def handle_batch([], _ctx), do: :ok

  def handle_batch(items, ctx) do
    reals =
      Enum.map(items, fn {:mailbox, tag, envelope, ttl} ->
        %{mailbox_id: tag, envelope: envelope, ttl: ttl}
      end)

    ttl = reals |> hd() |> Map.fetch!(:ttl)
    fill = max(Bucket.target() - length(reals), 0)

    decoys =
      for _ <- 1..fill//1 do
        Decoy.build(ttl_ms: ttl, rand: ctx.rand)
      end

    rows =
      Enum.map(reals ++ decoys, fn row ->
        %{
          mailbox_id: row.mailbox_id,
          envelope: row.envelope,
          created_ms: ctx.now,
          expires_ms: ctx.now + row.ttl
        }
      end)

    case Repo.transaction(fn -> Repo.insert_all(Envelope, rows) end) do
      {:ok, _inserted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Ecto.ConstraintError, Exqlite.Error] -> {:error, error}
  end
end
