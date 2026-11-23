defmodule Zifiri.Bucket.Publisher.Handler do
  @moduledoc """
  A sink for one item type drained from `Zifiri.Bucket`.

  The publisher is generic: it owns the timer and the drain, and dispatches a
  batch to the handler registered for the batch's type. A plane that wants the
  bucket only has to implement this behaviour and add one entry to the
  publisher's handler table — it does not touch the timer, the drain or another
  plane's writer.

  `items` is the drained list with its type tag stripped off, in whatever shape
  that plane queued (for `:mailbox`, `{:mailbox, tag, envelope, ttl}` becomes
  `{:mailbox, ...}` groups and the handler receives the whole tuples — see
  `Zifiri.Bucket.Publisher` for the grouping rule).

  `ctx` carries what the publisher measured once per tick:

    * `:now` — the millisecond clock used for the write;
    * `:bucket` — `Zifiri.Bucket.bucket_start/1` of that clock;
    * `:rand` — an injectable `(n) -> binary` for decoy material.
  """

  @doc "Consumes one type's batch. `:ok` continues the tick; `{:error, reason}` stops it."
  @callback handle_batch(items :: [term()], ctx :: map()) :: :ok | {:error, term()}
end
