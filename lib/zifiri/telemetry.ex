defmodule Zifiri.Telemetry do
  @moduledoc """
  Counter-only telemetry (plan §5.1: "counters only in telemetry").

  The handler pattern-matches on the event name and throws away both
  measurements and metadata before doing anything. That is the point: a
  telemetry event's metadata carries the conn, and a handler that forwards
  metadata to a logger or an exporter is a request log with extra steps.

  What is counted: endpoint stops and repo queries. Both are aggregates —
  numbers with no key, no caller and no per-request identity. Per-turn pool
  sizes (§4.2.4) land here in P3 in the same shape.
  """

  use GenServer

  @table :zifiri_counters
  @handler_id "zifiri-counters"

  @events [
    [:zifiri, :endpoint, :stop],
    [:zifiri, :repo, :query]
  ]

  @doc """
  Starts the counter owner and attaches the handlers.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads a counter. Unknown keys are zero.
  """
  @spec count(atom()) :: non_neg_integer()
  def count(key) when is_atom(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  @doc """
  Counts one occurrence of something that is not a telemetry event.

  A counter is an aggregate with no identity, which is the only shape this
  module is allowed to keep (§5.1). `:pool_starved_total` is the first user: a
  bucket that cannot fill its pool is a fact about the service, and the writer
  holds no per-request detail to leak into it (§4.2, review F-04).
  """
  @spec inc(atom()) :: :ok
  def inc(key) when is_atom(key), do: bump(key)

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, %{}}
  end

  @doc """
  `:telemetry` handler. Metadata is `_meta` on purpose.
  """
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:zifiri, :endpoint, :stop], _measurements, _meta, _config),
    do: bump(:endpoint_stop)

  def handle_event([:zifiri, :repo, :query], _measurements, _meta, _config), do: bump(:repo_query)
  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp bump(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  end
end
