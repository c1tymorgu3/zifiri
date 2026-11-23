defmodule Zifiri.Mailbox.Sweeper do
  @moduledoc """
  Deletes expired 1:1 envelopes every five minutes.

  `fetch/3` already hides expired envelopes, so this process is not what makes
  the TTL true — it is what makes it *true on disk*. Without it an envelope
  past its 72 hours would sit in the file forever, readable by anyone with the
  database, which would make the TTL a UI promise instead of a storage one.

  It deletes by `expires_ms` only. It never sees a tag, an id, or a key, and
  it logs nothing: a line saying "deleted 12 envelopes" every five minutes is
  a traffic meter, and the log policy (§5.1) does not allow one.

  ## Wiring

  Deliberately **not** in the supervision tree yet — `lib/zifiri/application.ex`
  belongs to another change. To start it, add to the children list:

      {Zifiri.Mailbox.Sweeper, []}

  Until then it can be driven by hand: `Zifiri.Mailbox.Sweeper.sweep_now/0`
  performs one pass synchronously and returns the count, which is also how the
  test exercises it without waiting five minutes.
  """

  use GenServer

  require Logger

  alias Zifiri.Mailbox

  @default_interval_ms 5 * 60 * 1000

  @doc """
  Starts the sweeper.

  Options: `:interval_ms` (default five minutes) and `:name` (default
  `__MODULE__`, so a second copy cannot be started by accident in one node).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs one sweep in the caller's process. Returns the number of rows deleted."
  @spec sweep_now(integer()) :: non_neg_integer()
  def sweep_now(now \\ System.system_time(:millisecond)), do: Mailbox.sweep(now)

  @doc """
  Asks a running sweeper to sweep now and returns the count.

  Useful when a node has been down past a TTL and the operator does not want
  to wait for the next tick.
  """
  @spec sweep_now!(GenServer.server(), integer()) :: non_neg_integer()
  def sweep_now!(server \\ __MODULE__, now \\ System.system_time(:millisecond)) do
    GenServer.call(server, {:sweep, now})
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if not is_integer(interval) or interval <= 0 do
      raise ArgumentError, "sweep interval must be a positive integer, got: #{inspect(interval)}"
    end

    # First pass on a timer, not inline: boot should not block on the database
    # and a crash here would take the supervision tree down with it.
    schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, %{interval_ms: interval} = state) do
    Mailbox.sweep()

    # No log line, not even a count. A "removed 12 envelopes" line every five
    # minutes is a traffic meter for the whole node, and §5.1 does not allow
    # one; `Zifiri.ArchitectureTest` fails the build on debug-level logging in
    # `lib/` for exactly this reason.
    schedule(interval)
    {:noreply, state}
  rescue
    # A sweep that fails must not kill the process: the next tick retries, and
    # expired envelopes are already unreadable through `Mailbox.fetch/3`.
    # Only the exception class is logged — the message can carry SQL and bound
    # parameters, and a bound parameter in this table is a timestamp plus a
    # blob the server cannot read.
    error ->
      Logger.error(fn -> "[zifiri: :redacted, class: #{inspect(error.__struct__)}]" end)
      schedule(interval)
      {:noreply, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_call({:sweep, now}, _from, state) do
    {:reply, Mailbox.sweep(now), state}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
