defmodule Zifiri.Presence do
  @moduledoc """
  Coarse, mutual, off-by-default presence (`§P0-4`, review R5-08).

  One row per mailbox tag: `{tag, bucket_index}`. Nothing else — no history, no
  counter, no per-pair edge. The rows live in a single ETS table owned by this
  process, so a restart is a wipe and there is no file to read afterwards.

  ## Quantised, not rounded

  A timestamp rounded to nothing is still a timestamp. "Fetched at 19:41:07" and
  "fetched inside the last five minutes" differ only in how much of the answer
  the reader has to guess; a poller running once a second sees the transition
  from fresh to stale at `at + window` and therefore knows `at` to the second.
  The fix is not a smaller number, it is a coarser grid:

    * the clock is cut into fifteen-minute buckets and the stored value is the
      bucket index, `div(at + jitter(tag), window)` — never `at`;
    * `jitter(tag)` is ±three minutes, derived from the tag itself, so two tags
      do not share a boundary and a reader cannot line the answers up against a
      known grid;
    * the jitter is not stored. It is a pure function of the tag, recomputed on
      every read, so the table has no second column to correlate.

  The result is that the freshness transition lands somewhere inside a
  twenty-one-minute span that the reader cannot place: the window is fifteen
  minutes, the jitter shifts each tag's boundary by up to three minutes either
  way, and polling faster than the bucket does not buy a finer answer. Inside one
  bucket every fetch is the same integer, so nine hundred touches and one touch
  are indistinguishable — the row is a bucket index, and a bucket index is not a
  time.

  Shorter is *more* information, not less: five minutes plus a one-second poll
  pins the moment the app was opened to the second, which is a behavioural signal
  with no message attached to it. Fifteen minutes plus an unknown jitter gives
  "recently, within a quarter of an hour" and nothing finer. The numbers behind
  that trade are in `docs/spec.md` §Two modes.

  ## Two answers, not three

  `state/3` answers `:online`, `:stale`, or `:unknown`:

    * `:online` — both tags are in *the same bucket as now*, i.e. both were
      touched within this fifteen-minute slice;
    * `:stale` — the pair is mutual and both rows exist, but at least one side's
      bucket is in the past (up to two windows back). This is the only thing the
      answer says: "not both of you right now";
    * `:unknown` — no handshake, an opt-out, no row, or a row older than two
      windows.

  There is no `:recent` (which the previous version returned when exactly one side
  was fresh). That third answer was a per-side oracle: query a tag you know is
  fresh against the target and `:recent` tells you the target is not at the
  keyboard, which is precisely the one-way tracking presence is supposed to make
  impossible. Collapsing "one fresh" and "neither fresh" into `:stale` means the
  answer no longer names *which* side went quiet.

  ## Mutual, by token

  Presence is a handshake between two parties who both asked. `mutual_opt_in/2`
  is each side's half of it: it writes `{{:pair, token, tag}, true}`, where
  `token = SHA-256("zifiri/presence/pair/v1" <> low <> high)` over the two tags
  in sorted order. `state/3` answers only when *both* halves are present for the
  same token.

  The old API took a `mutual: true` option from the caller. That was the caller
  asserting the property it was supposed to prove: a one-sided query with the
  flag set read `:online` whenever both rows happened to be fresh, and the flag
  was not evidence of anything. The option is gone; passing it is inert, and the
  answer is `:unknown` until both tags have opted in to each other.

  ## One touch per minute

  `touch/2` is rate-limited per tag: at most one write per wall-clock minute
  (`div(at, 60_000)`). A second call inside the same minute returns
  `{:error, :rate_limited}` and does **not** move the stored bucket, so polling
  faster than the limit cannot sharpen the answer — the row is the same integer
  either way, and the refusal is visible instead of silently absorbed. The
  throttle is a minute index in this process's state, not a row: it is pruned as
  it ages, it is never queryable, and it disappears on restart. The limit is a
  fixed window, so the worst case is two accepted touches either side of a minute
  boundary; both land in the same bucket index, so the extra write costs no
  information.

  ## Off by default

  `enable/1` is the only way in. A tag that was never enabled has no row, and
  `touch/2` against it returns `{:error, :disabled}` instead of quietly creating
  one. `disable/1` deletes the bucket, the opt-in marker, and every pair half
  that names the tag together: there is no tombstone, so "never enabled" and
  "turned off" are indistinguishable from the outside. A row saying "off" would
  itself be a trace, and a count of opt-outs is a census of the cautious.

  The `{:enabled, tag}` marker is the one permanent row, and it is deliberately
  permanent: it is a boolean with no timestamp, it is what "I consent to
  presence" *is*, and `disable/1` deletes it. There is nothing in it to sweep and
  nothing in it that ages.

  ## Bounded

  Buckets older than two windows are useless and are dropped by a sweeper every
  fifteen minutes; `state/3` already treats them as absent, so the sweep only
  reclaims memory. Nothing is written to disk, logged, or reported anywhere: the
  only sink is the table, and the table dies with this process.
  """

  use GenServer

  @table :zifiri_presence
  @window_ms 15 * 60 * 1000
  @jitter_ms 3 * 60 * 1000
  @retention_buckets 2
  @touch_interval_ms 60_000
  @sweep_interval_ms 15 * 60 * 1000

  @jitter_domain "zifiri/presence/jitter/v1"
  @pair_domain "zifiri/presence/pair/v1"

  @type tag :: binary()
  @type presence :: :online | :stale | :unknown

  @doc "Starts the table and the sweeper. `opts` exist so tests can shrink them."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  The table that holds every presence row.

  Exposed so a test can inspect what is — and is not — stored without guessing
  the name.
  """
  @spec table() :: atom()
  def table, do: @table

  @doc "The quantisation window, in milliseconds. Fifteen minutes, by product rule."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc """
  The per-tag jitter amplitude, in milliseconds. Three minutes either way.

  A tag's own offset lies inside `-jitter_ms() .. jitter_ms()`; the spread is
  what makes two tags' bucket boundaries disagree.
  """
  @spec jitter_ms() :: pos_integer()
  def jitter_ms, do: @jitter_ms

  @doc """
  The bucket index `at` falls into for `tag`: `div(at + jitter(tag), window)`.

  Pure — it reads no state — and public because it is the quantisation the module
  promises: a test can assert the stored row is exactly this integer rather than
  a timestamp.
  """
  @spec bucket_index(tag(), integer()) :: integer()
  def bucket_index(tag, at) when is_binary(tag) and is_integer(at) do
    Integer.floor_div(at + jitter(tag), @window_ms)
  end

  @doc """
  The millisecond span of the bucket `at` falls into: `{first, last}`, inclusive.

  Every fetch inside `first .. last` is the same row, which is the whole point:
  the answer cannot change inside this span, and the span's start is shifted off
  the grid by the tag's own jitter.
  """
  @spec bucket_span(tag(), integer()) :: {integer(), integer()}
  def bucket_span(tag, at) when is_binary(tag) and is_integer(at) do
    first = bucket_index(tag, at) * @window_ms - jitter(tag)
    {first, first + @window_ms - 1}
  end

  @doc """
  Opts a tag in. Until this is called the tag has no presence at all.
  """
  @spec enable(tag()) :: :ok | {:error, :invalid}
  def enable(tag) when is_binary(tag), do: GenServer.call(__MODULE__, {:enable, tag})
  def enable(_), do: {:error, :invalid}

  @doc """
  Opts a tag out and erases what was there: the bucket, the marker, and every
  pair half naming the tag.

  After this call the tag is indistinguishable from one that never opted in — no
  tombstone, no "off" row, and no stale handshake that would let the other side
  keep reading a `:stale` about someone who has left.
  """
  @spec disable(tag()) :: :ok | {:error, :invalid}
  def disable(tag) when is_binary(tag), do: GenServer.call(__MODULE__, {:disable, tag})
  def disable(_), do: {:error, :invalid}

  @doc """
  Records that `tag` consents to presence with `peer`, and nothing else.

  Both sides must call this before `state/2,3` will answer about the pair; one
  half is `:unknown`. Both tags must be opted in (`enable/1`), because a
  handshake with a tag that has no presence to share is a handshake with nobody.
  """
  @spec mutual_opt_in(tag(), tag()) :: :ok | {:error, :disabled | :invalid}
  def mutual_opt_in(tag, peer) when is_binary(tag) and is_binary(peer) do
    if tag == peer, do: {:error, :invalid}, else: GenServer.call(__MODULE__, {:opt_in, tag, peer})
  end

  def mutual_opt_in(_, _), do: {:error, :invalid}

  @doc """
  Whether both halves of the pair token exist. Reads no timestamps.

  The token check on its own, so a caller can decide whether to render a presence
  indicator at all before asking about freshness.
  """
  @spec mutual?(tag(), tag()) :: boolean()
  def mutual?(tag, peer) when is_binary(tag) and is_binary(peer) and tag != peer do
    token = pair_token(tag, peer)
    lookup({:pair, token, tag}) != [] and lookup({:pair, token, peer}) != []
  end

  def mutual?(_, _), do: false

  @doc """
  Records a fetch by `tag` at `at` (default: now), if the tag is opted in.

  The stored value is the bucket index, never `at`. A tag that never opted in or
  has opted out gets `{:error, :disabled}` — a row written for a tag that is not
  present would be presence without consent — and a second touch inside the same
  minute gets `{:error, :rate_limited}` without moving the row.

  `:at` exists for tests; the production caller passes nothing and gets the wall
  clock.
  """
  @spec touch(tag(), keyword()) :: :ok | {:error, :disabled | :invalid | :rate_limited}
  def touch(tag, opts \\ [])

  def touch(tag, opts) when is_binary(tag) do
    at = Keyword.get(opts, :at, System.system_time(:millisecond))

    if is_integer(at) do
      GenServer.call(__MODULE__, {:touch, tag, at})
    else
      {:error, :invalid}
    end
  end

  def touch(_, _), do: {:error, :invalid}

  @doc """
  Whether `tag` has opted in. `false` when the table does not exist yet.
  """
  @spec enabled?(tag()) :: boolean()
  def enabled?(tag) when is_binary(tag) do
    case lookup({:enabled, tag}) do
      [{_, true}] -> true
      _ -> false
    end
  end

  def enabled?(_), do: false

  @doc """
  Quantised presence for the pair `tag_a`/`tag_b`: `:online | :stale | :unknown`.

  Answers only when all of the following hold; otherwise `:unknown`:

    * the two tags differ — a tag cannot be mutual with itself;
    * both tags are opted in — a disabled side hides the pair, so opting out can
      never be inferred from the other side's answer;
    * both halves of the pair token exist — see `mutual_opt_in/2`; there is no
      caller flag to set;
    * both tags have a row no older than two windows.

  `:online` means both buckets are the current one. Anything else still inside
  the retention answers `:stale`, which does not say which side moved.

  `:now` is a clock override for tests. The default is the wall clock.
  """
  @spec state(tag(), tag(), keyword()) :: presence()
  def state(tag_a, tag_b, opts \\ [])

  def state(tag_a, tag_b, opts) when is_binary(tag_a) and is_binary(tag_b) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))

    cond do
      tag_a == tag_b -> :unknown
      not is_integer(now) -> :unknown
      not (enabled?(tag_a) and enabled?(tag_b)) -> :unknown
      not mutual?(tag_a, tag_b) -> :unknown
      true -> pair_state(tag_a, tag_b, now)
    end
  end

  def state(_, _, _), do: :unknown

  @doc """
  Deletes every bucket older than the retention and returns how many went.

  The sweeper calls this on a timer; it is public so a test can run one pass
  without waiting fifteen minutes. Opt-in markers and pair halves are never
  touched — a handshake does not expire because nobody was at the keyboard.
  """
  @spec sweep() :: non_neg_integer()
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @doc """
  Empties the table and the throttle. Same observable state as a process restart,
  which is what a deploy does; tests use it to start from nothing.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # -- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, interval)

    {:ok, %{interval: interval, throttle: %{}}}
  end

  @impl true
  def handle_call({:enable, tag}, _from, state) do
    true = :ets.insert(@table, {{:enabled, tag}, true})
    # Re-enabling clears the throttle: the minute that blocked a touch before the
    # opt-out says nothing about a tag that has just come back.
    {:reply, :ok, %{state | throttle: Map.delete(state.throttle, tag)}}
  end

  def handle_call({:touch, tag, at}, _from, state) do
    minute = Integer.floor_div(at, @touch_interval_ms)

    cond do
      lookup({:enabled, tag}) == [] ->
        {:reply, {:error, :disabled}, state}

      Map.get(state.throttle, tag) == minute ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        true = :ets.insert(@table, {tag, bucket_index(tag, at)})
        throttle = state.throttle |> prune(minute) |> Map.put(tag, minute)
        {:reply, :ok, %{state | throttle: throttle}}
    end
  end

  def handle_call({:disable, tag}, _from, state) do
    true = :ets.delete(@table, {:enabled, tag})
    true = :ets.delete(@table, tag)
    # Every half that names the tag, in either direction: the token is symmetric
    # but the row records which side contributed, so one match spec finds both.
    :ets.match_delete(@table, {{:pair, :_, tag}, :_})
    {:reply, :ok, %{state | throttle: Map.delete(state.throttle, tag)}}
  end

  def handle_call({:opt_in, tag, peer}, _from, state) do
    if enabled?(tag) and enabled?(peer) do
      true = :ets.insert(@table, {{:pair, pair_token(tag, peer), tag}, true})
      {:reply, :ok, state}
    else
      {:reply, {:error, :disabled}, state}
    end
  end

  def handle_call(:sweep, _from, state) do
    {dropped, state} = sweep_now(state)
    {:reply, dropped, state}
  end

  def handle_call(:reset, _from, state) do
    true = :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | throttle: %{}}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :bad_call}, state}

  @impl true
  def handle_info(:sweep, state) do
    {_, state} = sweep_now(state)
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  # -- internals -------------------------------------------------------------

  defp pair_state(tag_a, tag_b, now) do
    with [{^tag_a, bucket_a}] when is_integer(bucket_a) <- lookup(tag_a),
         [{^tag_b, bucket_b}] when is_integer(bucket_b) <- lookup(tag_b) do
      age_a = bucket_index(tag_a, now) - bucket_a
      age_b = bucket_index(tag_b, now) - bucket_b

      cond do
        # A bucket from the future means the clock moved backwards. Refusing is
        # cheaper than guessing whether the row is fresh or corrupt.
        age_a < 0 or age_b < 0 -> :unknown
        age_a == 0 and age_b == 0 -> :online
        age_a <= @retention_buckets and age_b <= @retention_buckets -> :stale
        true -> :unknown
      end
    else
      _ -> :unknown
    end
  end

  # The per-tag offset, derived from the tag and never stored. Changing the
  # domain string would shift every boundary by at most one bucket; it is
  # versioned for exactly that reason.
  defp jitter(tag) do
    <<n::32, _::binary>> = :crypto.hash(:sha256, <<@jitter_domain::binary, tag::binary>>)
    rem(n, 2 * @jitter_ms + 1) - @jitter_ms
  end

  defp pair_token(tag_a, tag_b) do
    [low, high] = Enum.sort([tag_a, tag_b])
    :crypto.hash(:sha256, <<@pair_domain::binary, low::binary, high::binary>>)
  end

  # Reads happen from any process; writes go through the owner. A missing table
  # means "not started yet", which is the same answer as "nothing recorded".
  defp lookup(key) do
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.lookup(@table, key)
  end

  # Bucket rows are the only ones with a binary key and an integer value, so the
  # `{:enabled, tag}` and `{:pair, token, tag}` rows cannot match this pass.
  defp sweep_now(state) do
    now = System.system_time(:millisecond)

    dropped =
      Enum.count(:ets.tab2list(@table), fn
        {tag, bucket} when is_binary(tag) and is_integer(bucket) ->
          if bucket < bucket_index(tag, now) - @retention_buckets do
            true = :ets.delete(@table, tag)
            true
          else
            false
          end

        _ ->
          false
      end)

    minute = Integer.floor_div(now, @touch_interval_ms)
    {dropped, %{state | throttle: prune(state.throttle, minute)}}
  end

  # The previous minute is kept: a touch at 10:00:59 and one at 10:01:00 are both
  # legitimate, and dropping the older entry early would only forget a limit that
  # has already expired.
  defp prune(throttle, minute) do
    Map.filter(throttle, fn {_tag, touched} -> touched >= minute - 1 end)
  end
end
