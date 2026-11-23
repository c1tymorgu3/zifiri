defmodule Zifiri.Chat.Store do
  @moduledoc """
  All of chat history: one ring buffer per room, in this process, in RAM.

  Nothing here is written anywhere — no row, no file, no ETS table, no log line
  (`plan §5.1`, `§7.1`). Restarting this process is a wipe, which is the point:
  the buffer is gone *and* every room gets a fresh epoch, so every signature
  minted against the old epoch stops verifying and a captured frame cannot be
  replayed into a fresh server (`§7.3`).

  Three guards live behind the same call as the append, because they are only
  sound if they are atomic with it:

    * **rate** — 20 accepted messages per session key per minute (`§7.4`),
      counted here rather than in the channel so a reconnect does not reset it;
    * **counter** — strictly increasing per key (`§7.3`). One integer,
      `last_ctr`, is remembered per key: `ctr <= last_ctr` is refused, anything
      above it is accepted. `join` hands that same integer back per key
      (`last_ctrs/1`), so a client resumes exactly where its key stopped;
    * **size** — one message is at most the 4 KB envelope bucket, in addition to
      the channel's own padding. A room whose lines could be 16 KB lets a single
      line stand out by size alone (`§4.1`, `§7.1`).

  Why strict monotonicity and not "the last 64 counters seen": a fixed window is
  evictable. Push 65 counters through a key and the oldest one falls out, so the
  same frame is accepted twice — the window hands an attacker 64 cheap replays
  per key and hands honest clients nothing, because a key's own counter only
  moves forward. §7.3 asks for a strictly increasing counter; this is that rule
  with nothing of its own left to evict.

  Per-key state expires on a TTL (`:key_ttl_ms`, ten minutes by default). That
  is the whole cost of a bounded map: a key quiet for longer than a message
  lives is forgotten and its next counter starts a new run. Nothing else is
  evicted — there is no `@max_tracked_keys` sweep that could drop a live key and
  silently reopen its replay window.
  """

  use GenServer

  @name __MODULE__
  @default_capacity 500
  @default_ttl_ms 15 * 60 * 1000
  @default_key_ttl_ms 10 * 60 * 1000
  @default_rate 20
  @default_max_body 4096

  @type message :: %{
          id: pos_integer(),
          pubkey: binary(),
          sig: binary(),
          body: binary(),
          bucket: pos_integer(),
          ctr: non_neg_integer(),
          at: integer()
        }

  defstruct capacity: @default_capacity,
            ttl_ms: @default_ttl_ms,
            key_ttl_ms: @default_key_ttl_ms,
            rate: @default_rate,
            max_body: @default_max_body,
            rooms: %{}

  @doc "Starts the buffer. `opts` exist so tests can shrink the TTLs."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The room's current epoch, rotating it into existence on first use."
  @spec epoch(String.t()) :: binary()
  def epoch(room), do: GenServer.call(@name, {:epoch, room})

  @doc "The room's buffer, newest first, expired messages already dropped."
  @spec messages(String.t()) :: [message()]
  def messages(room), do: GenServer.call(@name, {:messages, room, :all})

  @doc """
  At most `limit` of the newest messages — what `join` answers with. A full
  500-message buffer is a megabyte of frames for every client that joins
  (`§7.1`).
  """
  @spec recent(String.t(), pos_integer()) :: [message()]
  def recent(room, limit) when is_integer(limit) and limit > 0,
    do: GenServer.call(@name, {:messages, room, limit})

  @doc """
  The highest counter accepted from each known key, as `%{pubkey => ctr}`.

  This is the entire replay state: one integer per key, not 64 slots per key.
  `join` hands it to a client so a reconnect knows where to resume, and the
  summary is the same monotonic rule the server enforces — nothing is hidden
  behind a bounded window a client could not observe.
  """
  @spec last_ctrs(String.t()) :: %{binary() => non_neg_integer()}
  def last_ctrs(room), do: GenServer.call(@name, {:last_ctrs, room})

  @doc """
  Rate-checks, counter-checks, size-checks and appends in one step.

  Returns `{:ok, message}` or
  `{:error, :rate_limited | :replay | :too_large}`. The caller has already
  verified the signature and the proof of work; this process never sees a
  private key and never trusts a counter.
  """
  @spec submit(String.t(), map()) ::
          {:ok, message()} | {:error, :rate_limited | :replay | :too_large}
  def submit(room, message), do: GenServer.call(@name, {:submit, room, message})

  @doc """
  Restart-equivalent reset: every buffer emptied, every epoch rotated, every
  counter and key forgotten. Same observable state as killing and restarting the
  process, which is exactly what a server restart does to chat.
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []), do: GenServer.call(@name, {:reset, opts})

  @impl true
  def init(opts), do: {:ok, new_state(opts)}

  @impl true
  def handle_call({:reset, opts}, _from, _state) do
    {:reply, :ok, new_state(opts)}
  end

  def handle_call({:epoch, room_id}, _from, state) do
    room = fetch_room(state, room_id, now())
    {:reply, room.epoch, put_room(state, room_id, room)}
  end

  def handle_call({:messages, room_id, limit}, _from, state) do
    room = fetch_room(state, room_id, now())
    {:reply, take(room.messages, limit), put_room(state, room_id, room)}
  end

  def handle_call({:last_ctrs, room_id}, _from, state) do
    room = fetch_room(state, room_id, now())
    ctrs = Map.new(room.keys, fn {pubkey, {last_ctr, _at}} -> {pubkey, last_ctr} end)
    {:reply, ctrs, put_room(state, room_id, room)}
  end

  def handle_call({:submit, room_id, incoming}, _from, state) do
    at = now()
    room = fetch_room(state, room_id, at)

    {reply, room} =
      cond do
        byte_size(incoming.padded) > state.max_body ->
          {{:error, :too_large}, room}

        over_rate?(room, incoming.pubkey, at, state.rate) ->
          {{:error, :rate_limited}, room}

        replay?(room, incoming.pubkey, incoming.ctr) ->
          {{:error, :replay}, room}

        true ->
          accept(room, incoming, at, state)
      end

    {:reply, reply, put_room(state, room_id, room)}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :bad_call}, state}

  defp new_state(opts) do
    %__MODULE__{
      capacity: Keyword.get(opts, :capacity, @default_capacity),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      key_ttl_ms: Keyword.get(opts, :key_ttl_ms, @default_key_ttl_ms),
      rate: Keyword.get(opts, :rate, @default_rate),
      max_body: Keyword.get(opts, :max_body, @default_max_body),
      rooms: %{}
    }
  end

  defp new_room do
    %{
      epoch: :crypto.strong_rand_bytes(16),
      seq: 0,
      messages: [],
      keys: %{},
      rates: %{}
    }
  end

  defp fetch_room(state, room_id, at) do
    state.rooms
    |> Map.get(room_id, new_room())
    |> expire(state, at)
  end

  defp put_room(state, room_id, room) do
    %{state | rooms: Map.put(state.rooms, room_id, room)}
  end

  defp take(messages, :all), do: messages
  defp take(messages, limit), do: Enum.take(messages, limit)

  # Newest-first, so expired messages are a suffix and the scan stops at the
  # first live one. Rate counters and per-key replay state are trimmed in the
  # same pass, so memory is bounded by what happened in the last fifteen minutes
  # — and by nothing else: there is no count-based eviction anywhere here.
  defp expire(room, state, at) do
    messages = Enum.take_while(room.messages, &(at - &1.at < state.ttl_ms))
    minute = div(at, 60_000)

    keys =
      Map.filter(room.keys, fn {_key, {_last_ctr, seen_at}} ->
        at - seen_at < state.key_ttl_ms
      end)

    %{room | messages: messages, keys: keys, rates: trim_rates(room.rates, minute)}
  end

  defp trim_rates(rates, minute) do
    Map.filter(rates, fn {_key, {window, _count}} -> window == minute end)
  end

  defp over_rate?(room, pubkey, at, limit) do
    case Map.get(room.rates, pubkey) do
      {window, count} -> window == div(at, 60_000) and count >= limit
      nil -> false
    end
  end

  defp replay?(room, pubkey, ctr) do
    case Map.get(room.keys, pubkey) do
      nil -> false
      {last_ctr, _at} -> ctr <= last_ctr
    end
  end

  defp accept(room, incoming, at, state) do
    id = room.seq + 1

    message = %{
      id: id,
      pubkey: incoming.pubkey,
      sig: incoming.sig,
      body: incoming.padded,
      bucket: incoming.bucket,
      ctr: incoming.ctr,
      at: at
    }

    room = %{
      room
      | seq: id,
        messages: Enum.take([message | room.messages], state.capacity),
        keys: Map.put(room.keys, incoming.pubkey, {incoming.ctr, at}),
        rates: bump_rate(room.rates, incoming.pubkey, at)
    }

    {{:ok, message}, room}
  end

  defp bump_rate(rates, pubkey, at) do
    minute = div(at, 60_000)

    count =
      case Map.get(rates, pubkey) do
        {^minute, previous} -> previous + 1
        _other -> 1
      end

    Map.put(rates, pubkey, {minute, count})
  end

  # Monotonic, because wall-clock jumps (NTP, DST, a laptop resuming) must not
  # make a message expire early or a rate window last an hour.
  defp now, do: System.monotonic_time(:millisecond)
end
