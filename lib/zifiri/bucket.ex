defmodule Zifiri.Bucket do
  @moduledoc """
  The ten-minute bucket: the unit of time in the silent mode (`docs/scope-v5.md`).

  A write is not published when it happens. It is dropped into the bucket that
  covers the current wall-clock ten minutes; when the bucket closes, everything
  in it is shuffled and published as one batch. A passive observer sees `n`
  frames leave together and can pick the real one out of them with probability
  `1/n` — that is the whole anonymity claim, and it is why the batch size is
  fixed at #{120} rather than "however many arrived" (`§scope-v5`, table).

  ## Fixed cadence, not a full-bucket flush

  The bucket drains on the clock, never on a count. Draining early when the
  #{120}th message lands would hand the observer a timestamp for the *last*
  arrival and a batch that is exactly as big as it happens to be; a bucket that
  is always the same size and always closes at the same minute of the hour leaks
  neither. So `add/2` never drains, `size/0` may sit at #{120} or 300, and the
  only thing that empties the table is an explicit `drain/1`.

  ## Wall clock, not monotonic

  Bucket boundaries are derived from `System.system_time/1`, so every node,
  client and observer agrees on where a bucket starts. A monotonic clock would
  be immune to NTP steps but would also put each process in a bucket of its own,
  which is the opposite of what a bucket is for. The cost is accepted: an NTP
  step moves an item to a neighbouring bucket, it never loses one, because
  `drain/1` takes whatever is in the table and carries anything left over.

  ## Storage

  One named ETS table, `:zifiri_bucket`, public, owned by this process. Nothing
  is written to disk and the table dies with the process — a restart is a wipe,
  which is the same promise chat history makes (`plan §7.1`).

  `add/2` writes straight to the table (no message to the owner), `drain/1`
  reads it and then deletes the keys it read. An `add/2` that lands between the
  read and the delete is not returned by that drain; it stays in the table and
  goes out with the next bucket. Items are never lost and never delivered
  twice.
  """

  use GenServer

  @table :zifiri_bucket

  # Ten minutes, the cadence `docs/scope-v5.md` prices at 69 MB/day for 120.
  @bucket_ms 600_000

  # The batch size the anonymity number is computed from: 1/120 ≈ 0.83% of
  # picking the real write, i.e. "~99%". Exposed for `Decoy.fill/2` and tests.
  @target 120

  @typedoc "Anything the caller wants batched — a message map, an envelope, a term."
  @type item :: term()

  @typedoc """
  The frame shape a real message and a decoy both use.

  The batch stores items verbatim, so this type is a contract, not a runtime
  conversion: a decoy must arrive with exactly these five keys, because any
  extra key (`:decoy`, `:body`, `:bucket`, `:ctr`, …) would be the field an
  observer groups by. There is deliberately no marker for synthetic rows.
  """
  @type frame :: %{
          id: String.t(),
          sig: binary(),
          pubkey: binary(),
          envelope: binary(),
          ts: integer()
        }

  @doc "Starts the owner of the bucket table. The table lives as long as this process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Bucket width in milliseconds."
  @spec bucket_ms() :: pos_integer()
  def bucket_ms, do: @bucket_ms

  @doc "The batch size a bucket is filled to: #{@target}."
  @spec target() :: pos_integer()
  def target, do: @target

  @doc "Wall-clock milliseconds. The clock every bucket boundary is derived from."
  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  @doc """
  Start of the bucket that contains `now`, in milliseconds since the epoch.

  Pure arithmetic on the wall clock, so it is the same answer in every process
  and every test: `bucket_start(9:59)` is 9:50, `bucket_start(10:01)` is 10:00,
  and `10:00:00.000` itself belongs to the bucket that starts at 10:00.
  """
  @spec bucket_start(integer()) :: integer()
  def bucket_start(now \\ now_ms()) when is_integer(now),
    do: Integer.floor_div(now, @bucket_ms) * @bucket_ms

  @doc """
  Exclusive end of a bucket: the instant the next bucket starts.

  Takes a bucket start, not an arbitrary timestamp — `bucket_end(bucket_start(t))`
  is the deadline for everything added at `t`.
  """
  @spec bucket_end(integer()) :: integer()
  def bucket_end(start) when is_integer(start), do: start + @bucket_ms

  @doc """
  Adds one item to the table. Never drains, never refuses.

  A decoy and a real frame go through this same function and are stored as the
  same `t:frame/0` — the table has no column that says which is which.

  `now` is injectable so a test can place an item in a bucket without sleeping
  ten minutes; production callers use `add/1`.
  """
  @spec add(item(), integer()) :: :ok
  def add(item, now \\ now_ms()) when is_integer(now) do
    ensure_started()
    # Monotonic and unique, so two identical items in the same millisecond are
    # two rows and neither overwrites the other. `ordered_set` keeps the scan
    # in insertion order, which is only a convenience — `drain/1` shuffles.
    key = :erlang.unique_integer([:monotonic, :positive])
    true = :ets.insert(@table, {key, now, item})
    :ok
  end

  @doc "How many items are waiting. Zero when nothing has ever been added."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.whereis(@table) do
      :undefined -> 0
      _tid -> :ets.info(@table, :size)
    end
  end

  @doc """
  Empties the table and returns what was in it, shuffled.

  Returns `%{bucket: bucket_start(now), items: [...], size: n}`. `bucket` is the
  bucket the drain happened in — the batch is published under that label. Items
  added before the last boundary but never drained (a slow scheduler, an NTP
  step) are carried into this batch rather than dropped: a lost write is a
  worse failure than a batch that is one item larger.

  An empty bucket drains to `%{items: [], size: 0}`; there is no error case.
  """
  @spec drain(integer()) :: %{bucket: integer(), items: [item()], size: non_neg_integer()}
  def drain(now \\ now_ms()) when is_integer(now) do
    entries =
      case :ets.whereis(@table) do
        :undefined -> []
        _tid -> :ets.tab2list(@table)
      end

    # Delete only the keys that were read. Anything inserted after `tab2list/1`
    # survives for the next bucket instead of being silently swallowed.
    Enum.each(entries, fn {key, _at, _item} -> :ets.delete(@table, key) end)

    items = entries |> Enum.map(fn {_key, _at, item} -> item end) |> :rand.shuffle()

    %{bucket: bucket_start(now), items: items, size: length(items)}
  end

  @doc """
  Empties the table without publishing — a test hook, and the reset a restart
  would perform anyway.
  """
  @spec reset() :: :ok
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Stops the owner process, which takes the table with it."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(_request, _from, state), do: {:reply, :ok, state}

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :ordered_set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _tid ->
        :ok
    end
  end

  # Self-starting: the app supervises `start_link/1` when it is in the tree, and
  # a test or a script that only calls `add/1` gets an owner on first use. The
  # owner is deliberately unlinked from the caller — a table that died with the
  # first process to touch it would be a bucket of one.
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, []) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _other -> :ok
        end

      _pid ->
        :ok
    end
  end
end
