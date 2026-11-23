defmodule Zifiri.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail closed before anything else comes up. A missing, unreadable, or
    # short pepper must stop the boot here, not degrade every `owner_hash` to
    # the development constant the build ships with (F-02, plan §4.3).
    :ok = Zifiri.Owner.validate!()

    # Order matters: the log filter is installed before anything that could
    # emit a record, and before the error sink is attached.
    :ok = Zifiri.LogFilter.install()
    :ok = Zifiri.ErrorLog.install()

    children = [
      {Phoenix.PubSub, name: Zifiri.PubSub},
      Zifiri.Telemetry,
      Zifiri.Repo,
      # PoW challenges are RAM-only and single-use (review F-03). The table has
      # to exist before the first request asks for a challenge, and it dies
      # with this process, which is the lifetime a challenge should have.
      Zifiri.Pow.Challenge,
      # The v5 write buffer: a write is a bucket entry until its turn comes, so
      # the table has to exist before the first write is accepted. RAM only —
      # a buffered write that does not survive a restart is the point.
      Zifiri.Bucket,
      # RAM-only planes. Chat's buffer must exist before the endpoint accepts a
      # socket, and the decoy writer fills the same rooms so a real message is
      # not the only thing in a bucket. The mailbox sweeper is what makes the
      # 72 h TTL true on disk.
      Zifiri.Chat.Store,
      # Presence is the one signal a room may show about itself (a count, never
      # a name); its sweeper is an internal timer, so one child covers both.
      Zifiri.Presence,
      {Zifiri.Mailbox.Sweeper, []},
      # Deletion reaches the disk (plan §6.1): the delete path asks for the
      # wipe itself, and this child is the retry — a compaction that lost a
      # race keeps the bytes on a free page until something runs it again.
      Zifiri.Application.VanishSweeper,
      Zifiri.Endpoint
    ]

    # The moderation plane is being rebuilt against v5 tables. It is appended
    # only when it is a supervised process: the current module is a writer with
    # no `start_link/1`, and putting it in the tree would fail the boot for a
    # plane that has nothing to run.
    children = children ++ mod_children()

    opts = [strategy: :one_for_one, name: Zifiri.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp mod_children do
    if Code.ensure_loaded?(Zifiri.Mod) and function_exported?(Zifiri.Mod, :start_link, 1),
      do: [Zifiri.Mod],
      else: []
  end
end

defmodule Zifiri.Application.VanishSweeper do
  @moduledoc """
  The daily "yok ol" pass: `Zifiri.Vanish.purge/0` on a timer.

  A delete compacts the file before it answers, but compaction is the step
  that can legitimately fail while another reader holds a snapshot — the row
  is gone and the bytes are still on a free page. `Zifiri.Vanish` is
  stateless, so it has nothing of its own to supervise; what needs a home in
  the tree is the second chance, because a wipe that only ever happens when a
  request happens to succeed is a best-effort promise. This process is that
  home.

  It runs once `@first_delay_ms` after boot — not in `init/1`: a compaction
  that has to wait for a reader holds the one connection this pool has, and
  boot is not the moment to spend it — and then every `@interval_ms`. A failed
  sweep is not an error worth reporting: `{:error, :busy}` means try again
  tomorrow, the failure is a reader rather than a fault, and logging a user's
  delete is exactly what this module refuses to do.
  """

  use GenServer

  alias Zifiri.Vanish

  @interval_ms :timer.hours(24)
  @first_delay_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :sweep, @first_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = Vanish.purge()
    Process.send_after(self(), :sweep, @interval_ms)
    {:noreply, state}
  end
end
