defmodule Zifiri.Bucket.Publisher do
  @moduledoc """
  Drains `Zifiri.Bucket` on a wall clock and dispatches each plane's batch.

  Publishing is not mailbox-specific. The publisher owns only the timer, the
  drain and the dispatch: every drained item carries its plane as the first
  tuple element (`{:mailbox, tag, envelope, ttl}` and `{:chat, room, message}`
  today), and the publisher looks that plane up in a handler table and calls
  the handler's `handle_batch/2`. Adding a plane means adding a handler module
  and one table entry; this module and the other planes' writers stay
  untouched.

  The timer is 15 s (`:interval_ms`) and a tick drains only when
  `Zifiri.Bucket.bucket_start/1` has changed since the previous tick, so one
  ten-minute bucket is published once. In tests the timer is off — `config
  :zifiri, :publish_tick_ms, :manual` — and `tick/1` is called by hand, which
  is the same code path a scheduled tick runs.

  An empty drain writes nothing. The bucket is the only thing that decides
  whether a batch exists: no queue, no row, and in particular no 120 decoys of
  phantom traffic.

  `:now_ms` and `:rand` are injectable so a test can pin the clock and seed the
  decoy material.
  """

  use GenServer

  alias Zifiri.Bucket

  @interval_ms 15_000

  @handlers %{
    mailbox: Zifiri.Mailbox.BucketHandler,
    chat: Zifiri.Chat.BucketHandler
  }

  @doc "The plane-to-handler table. A new plane adds one entry here."
  @spec handlers() :: %{atom() => module()}
  def handlers, do: @handlers

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Drains the bucket and dispatches its items, synchronously.

  This is what the scheduled tick calls; tests call it directly. Returns `:ok`
  when every batch was consumed (including the empty case), or the first
  handler error.
  """
  @spec tick(keyword()) :: :ok | {:error, term()}
  def tick(opts \\ []) do
    now = Keyword.get(opts, :now_ms, Bucket.now_ms())
    rand = Keyword.get(opts, :rand, &:crypto.strong_rand_bytes/1)
    handlers = Keyword.get(opts, :handlers, handlers())

    ctx = %{now: now, bucket: Bucket.bucket_start(now), rand: rand}

    %{items: items} = Bucket.drain(now)

    items
    |> group_by_type()
    |> Enum.reduce_while(:ok, fn {type, batch}, :ok ->
      case Map.fetch(handlers, type) do
        {:ok, handler} ->
          case handler.handle_batch(batch, ctx) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        # A type with no registered handler is left alone rather than guessed
        # at: the plane has not been wired yet, and writing it under another
        # plane's rules would be worse than dropping the batch.
        :error ->
          {:cont, :ok}
      end
    end)
  end

  # Only tuples whose first element is an atom are typed items. The bucket also
  # carried untyped frames before the planes were wired; those have no handler
  # and are skipped by the `:error` branch above.
  defp group_by_type(items) do
    Enum.group_by(items, fn
      item when is_tuple(item) and tuple_size(item) > 1 and is_atom(elem(item, 0)) ->
        elem(item, 0)

      _other ->
        :untyped
    end)
  end

  @impl true
  def init(opts) do
    configured = Application.get_env(:zifiri, :publish_tick_ms, @interval_ms)
    interval = Keyword.get(opts, :interval_ms, configured)

    if is_integer(interval), do: schedule(interval)

    # `nil` and not the current bucket: the first tick after boot publishes
    # whatever was queued before the restart instead of waiting for the next
    # boundary.
    {:ok, %{interval: interval, last_bucket: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = Bucket.now_ms()
    bucket = Bucket.bucket_start(now)

    state =
      if state.last_bucket == bucket do
        state
      else
        # A handler failure must not take the timer down; the batch is gone
        # either way, and the next bucket gets a fresh attempt.
        _ = tick(now_ms: now)
        %{state | last_bucket: bucket}
      end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_manual), do: :ok
end
