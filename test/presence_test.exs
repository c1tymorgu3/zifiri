defmodule Zifiri.PresenceTest do
  @moduledoc """
  §P0-4, acceptance row 9, and review R5-08: presence is quantised to a
  fifteen-minute bucket with a per-tag jitter, answers with two atoms instead of
  three, is rate-limited to one touch a minute, and is mutual only when both
  sides contributed half of the pair token.

  The disk assertion is a before/after snapshot of every directory this project
  owns, not a grep: a grep can only find the writes someone thought of. The
  source check next to it is the belt to that suspenders — it fails on the
  primitives a future edit would reach for, and on the return of `:recent`.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Presence

  @root Path.expand("..", __DIR__)

  # `client/` is left out on purpose: its node_modules and vitest caches churn
  # on their own schedule, and presence is server-side storage anyway.
  @scan_dirs ~w(priv config lib test docs scripts infra)

  @window_ms 15 * 60 * 1000
  @jitter_ms 3 * 60 * 1000

  setup context do
    # The application does not start presence yet; if it ever does, use that
    # instance rather than fighting it for the registered name.
    case Process.whereis(Presence) do
      nil -> start_supervised!({Presence, Map.get(context, :presence_opts, [])})
      _pid -> :ok
    end

    :ok = Presence.reset()
    :ok
  end

  # -- the product rule ------------------------------------------------------

  test "the window is fifteen minutes and the jitter is three" do
    assert Presence.window_ms() == @window_ms
    assert Presence.jitter_ms() == @jitter_ms
  end

  # -- opt-in ----------------------------------------------------------------

  test "a tag that never opted in has no presence at all" do
    a = tag()
    b = tag()

    refute Presence.enabled?(a)
    assert Presence.touch(a) == {:error, :disabled}
    assert Presence.state(a, b, mutual: true) == :unknown
    assert :ets.lookup(Presence.table(), a) == []
  end

  test "disabling erases the bucket, the marker and both pair halves" do
    base = now()
    {a, b} = linked(base)

    assert Presence.state(a, b, now: base) == :online

    :ok = Presence.disable(a)

    refute Presence.enabled?(a)
    assert :ets.lookup(Presence.table(), a) == []
    assert :ets.lookup(Presence.table(), {:enabled, a}) == []
    # Neither direction of the handshake survives: `a` leaving is not a fact the
    # table keeps about `b`.
    assert :ets.match(Presence.table(), {{:pair, :_, a}, :_}) == []
    refute Presence.mutual?(a, b)
    assert Presence.state(a, b, now: base) == :unknown
  end

  test "a disabled side hides the pair" do
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: now())

    refute Presence.enabled?(b)
    assert Presence.state(a, b) == :unknown
  end

  # -- quantisation ----------------------------------------------------------

  test "the stored row is a bucket index, never the fetch time" do
    base = now()
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base)

    assert [{^a, stored}] = :ets.lookup(Presence.table(), a)
    assert stored == Presence.bucket_index(a, base)
    assert is_integer(stored)
    assert stored != base
    # A bucket index is ~1/900000th of a millisecond epoch; anything near `base`
    # would be a timestamp wearing a different name.
    assert abs(stored - base) > @window_ms
  end

  test "every fetch inside one bucket is the same row" do
    base = now()
    a = tag()
    {first, last} = Presence.bucket_span(a, base)

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: first)
    assert [{^a, stored}] = :ets.lookup(Presence.table(), a)

    # The row is identical for a fetch at the start, the middle and the end of
    # the bucket, so the write time cannot be read back out of it.
    for at <- [first, div(first + last, 2), last] do
      assert Presence.bucket_index(a, at) == stored
    end

    assert last - first + 1 == Presence.window_ms()
  end

  test "the answer cannot change inside the bucket and changes at its edge" do
    base = now()
    {a, b} = linked(base)

    {first_a, last_a} = Presence.bucket_span(a, base)
    {first_b, last_b} = Presence.bucket_span(b, base)

    # The overlap is the span where both are still in the bucket they were
    # touched in, i.e. where `:online` is the only honest answer.
    inside = max(first_a, first_b)
    edge = min(last_a, last_b)

    assert inside <= edge
    assert Presence.state(a, b, now: inside) == :online
    assert Presence.state(a, b, now: edge) == :online

    # One millisecond past the nearer edge, one side has moved on. Quantisation
    # means this boundary is not the touch time: it is a bucket edge shifted by
    # an offset the reader does not know.
    assert Presence.state(a, b, now: edge + 1) == :stale
    assert Presence.state(b, a, now: edge + 1) == :stale
  end

  test "a poller that asks every millisecond learns the same bucket as one that asks once" do
    base = now()
    {a, b} = linked(base)
    {_, last} = Presence.bucket_span(a, base)
    {_, other_last} = Presence.bucket_span(b, base)
    edge = min(last, other_last)

    answers =
      for at <- [base, base + 1, div(base + edge, 2), edge] do
        Presence.state(a, b, now: at)
      end

    assert Enum.uniq(answers) == [:online]
  end

  test "fifteen minutes after a touch the pair is :stale" do
    base = now()
    {a, b} = linked(base)

    assert Presence.state(a, b, now: base + Presence.window_ms()) == :stale
  end

  test "three windows after a touch the pair is :unknown" do
    base = now()
    {a, b} = linked(base)

    assert Presence.state(a, b, now: base + 3 * Presence.window_ms()) == :unknown
  end

  test "one side inside the bucket and one side out of it is :stale, not a per-side answer" do
    base = now()
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.mutual_opt_in(a, b)
    :ok = Presence.mutual_opt_in(b, a)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base - Presence.window_ms())

    # This is the case the old `:recent` named out loud: exactly one side is at
    # the keyboard. The answer must not say which.
    assert Presence.state(a, b, now: base) == :stale
    assert Presence.state(b, a, now: base) == :stale
  end

  # -- jitter ----------------------------------------------------------------

  test "the bucket boundary is shifted off the grid by a per-tag offset" do
    base = now()
    window = Presence.window_ms()
    jitter = Presence.jitter_ms()

    offsets =
      for _ <- 1..16 do
        {first, _} = Presence.bucket_span(tag(), base)
        Integer.mod(first, window)
      end

    # Different tags, different edges: a reader cannot line the answers up
    # against a grid it already knows.
    assert length(Enum.uniq(offsets)) > 1

    for offset <- offsets do
      assert offset == 0 or offset <= jitter or offset >= window - jitter,
             "offset #{offset} is outside the ±#{jitter} ms jitter"
    end
  end

  test "the jitter is a function of the tag, not of the clock" do
    base = now()
    a = tag()

    {first, last} = Presence.bucket_span(a, base)

    assert Presence.bucket_span(a, base) == {first, last}
    assert Presence.bucket_span(a, first) == {first, last}
    assert Presence.bucket_span(a, last) == {first, last}
  end

  # -- mutuality -------------------------------------------------------------

  test "one half of the handshake is :unknown even when both rows are fresh" do
    base = now()
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base)
    :ok = Presence.mutual_opt_in(a, b)

    refute Presence.mutual?(a, b)
    assert Presence.state(a, b, now: base) == :unknown
  end

  test "a caller-supplied mutual flag is not a handshake" do
    base = now()
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base)
    :ok = Presence.mutual_opt_in(a, b)

    # R5-08: the option used to be the caller asserting the property. It is now
    # inert; only the second half of the token can change the answer.
    assert Presence.state(a, b, now: base, mutual: true) == :unknown
    assert Presence.state(a, b, now: base) == :unknown

    :ok = Presence.mutual_opt_in(b, a)

    assert Presence.mutual?(a, b)
    assert Presence.state(a, b, now: base, mutual: true) == :online
  end

  test "both halves make the pair mutual" do
    base = now()
    {a, b} = linked(base)

    assert Presence.mutual?(a, b)
    assert Presence.state(a, b, now: base) == :online
  end

  test "crossed opt-ins are not the same pair" do
    base = now()
    a = tag()
    b = tag()
    c = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.enable(c)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base)
    :ok = Presence.touch(c, at: base)
    :ok = Presence.mutual_opt_in(a, c)
    :ok = Presence.mutual_opt_in(b, a)

    assert Presence.state(a, b, now: base) == :unknown
    refute Presence.mutual?(a, b)
    refute Presence.mutual?(a, c)
  end

  test "an opt-in with a tag that is not present is refused" do
    a = tag()
    absent = tag()

    :ok = Presence.enable(a)

    assert Presence.mutual_opt_in(a, absent) == {:error, :disabled}
    assert Presence.mutual_opt_in(absent, a) == {:error, :disabled}
  end

  test "a tag cannot be mutual with itself" do
    base = now()
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base)

    assert Presence.mutual_opt_in(a, a) == {:error, :invalid}
    assert Presence.state(a, a, now: base) == :unknown
  end

  # -- rate limit ------------------------------------------------------------

  test "a second touch in the same minute is refused and does not move the row" do
    base = now()
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base)
    assert [{^a, stored}] = :ets.lookup(Presence.table(), a)

    assert Presence.touch(a, at: base) == {:error, :rate_limited}
    assert [{^a, ^stored}] = :ets.lookup(Presence.table(), a)

    # The next minute is a new window, not a second chance at a finer answer.
    assert Presence.touch(a, at: base + 60_000) == :ok
  end

  test "the limit is per tag, not global" do
    base = now()
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base)

    assert Presence.touch(a, at: base) == {:error, :rate_limited}
    assert Presence.touch(b, at: base) == {:error, :rate_limited}
  end

  test "re-enabling clears the throttle" do
    base = now()
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base)
    assert Presence.touch(a, at: base) == {:error, :rate_limited}

    :ok = Presence.disable(a)
    :ok = Presence.enable(a)

    assert Presence.touch(a, at: base) == :ok
  end

  test "the throttle is not a row" do
    base = now()
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base)
    assert Presence.touch(a, at: base) == {:error, :rate_limited}

    # Two objects only: the marker and the bucket. A refused touch leaves no
    # third row behind to correlate.
    assert :ets.info(Presence.table(), :size) == 2
  end

  # -- sweeper ---------------------------------------------------------------

  test "sweep/0 drops buckets older than the retention and keeps fresh rows and opt-ins" do
    stale = tag()
    fresh = tag()
    base = now()

    :ok = Presence.enable(stale)
    :ok = Presence.enable(fresh)
    :ok = Presence.touch(stale, at: base - 3 * Presence.window_ms())
    :ok = Presence.touch(fresh, at: base)

    assert Presence.sweep() == 1
    assert :ets.lookup(Presence.table(), stale) == []
    assert [{^fresh, _}] = :ets.lookup(Presence.table(), fresh)
    assert Presence.enabled?(stale)
  end

  test "sweep/0 does not drop a row that is still inside the retention" do
    a = tag()
    base = now()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: base - Presence.window_ms())

    assert Presence.sweep() == 0
    assert [{^a, _}] = :ets.lookup(Presence.table(), a)
  end

  test "the sweeper runs on its timer message, not only when asked" do
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: now() - 3 * Presence.window_ms())
    assert [{^a, _}] = :ets.lookup(Presence.table(), a)

    # The child schedules `:sweep` every fifteen minutes; the handler runs the
    # same pass `sweep/0` runs, so delivering the message exercises the timer
    # path without waiting a quarter of an hour.
    send(Process.whereis(Presence), :sweep)

    assert eventually(fn -> :ets.lookup(Presence.table(), a) == [] end)
  end

  # -- storage ---------------------------------------------------------------

  test "the row is one bucket index in a protected set" do
    a = tag()

    :ok = Presence.enable(a)
    :ok = Presence.touch(a, at: now())

    tab = Presence.table()

    assert :ets.info(tab, :type) == :set
    assert :ets.info(tab, :protection) == :protected
    assert [{^a, index}] = :ets.lookup(tab, a)
    assert is_integer(index)
  end

  test "presence writes nothing outside its ETS table" do
    before = snapshot()

    base = now()
    {a, b} = linked(base)
    assert Presence.state(a, b, now: base) == :online
    :ok = Presence.disable(a)
    _ = Presence.sweep()

    assert snapshot() == before
  end

  test "the module has no disk or log primitive to reach for" do
    source = File.read!(Path.join(@root, "lib/zifiri/presence.ex"))

    for token <- ["File.write", "File.open", ":dets", ":disk_log", "IO.write", "Logger."] do
      refute String.contains?(source, token), "presence must not contain #{token}"
    end

    # R5-08: the third answer was the oracle. It must not come back.
    refute String.contains?(source, "-> :recent"), "presence must not return :recent"
  end

  # -- input -----------------------------------------------------------------

  test "malformed input is refused instead of crashing" do
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)

    assert Presence.enable(nil) == {:error, :invalid}
    assert Presence.disable(42) == {:error, :invalid}
    assert Presence.touch(:not_a_tag) == {:error, :invalid}
    assert Presence.touch(a, at: "yesterday") == {:error, :invalid}
    assert Presence.mutual_opt_in(a, 42) == {:error, :invalid}
    assert Presence.enabled?(nil) == false
    assert Presence.state(nil, a, mutual: true) == :unknown
    assert Presence.state(a, b, now: "later") == :unknown
  end

  test "state/3 never answers outside the three atoms" do
    base = now()
    {a, b} = linked(base)
    other = tag()

    for {x, y, opts} <- [
          {a, b, [now: base]},
          {a, b, [now: base + Presence.window_ms()]},
          {a, b, [now: base + 3 * Presence.window_ms()]},
          {a, b, [now: base, mutual: true]},
          {a, other, [now: base]},
          {a, a, [now: base]},
          {a, b, []}
        ] do
      assert Presence.state(x, y, opts) in [:online, :stale, :unknown]
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp tag, do: :crypto.strong_rand_bytes(16)

  defp now, do: System.system_time(:millisecond)

  # Two tags that are opted in, mutually linked, and touched in the same bucket.
  defp linked(base) do
    a = tag()
    b = tag()

    :ok = Presence.enable(a)
    :ok = Presence.enable(b)
    :ok = Presence.mutual_opt_in(a, b)
    :ok = Presence.mutual_opt_in(b, a)
    :ok = Presence.touch(a, at: base)
    :ok = Presence.touch(b, at: base)

    {a, b}
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp snapshot do
    files =
      Enum.flat_map(@scan_dirs, fn dir ->
        Path.wildcard(Path.join([@root, dir, "**", "*"]), match_dot: true)
      end) ++ Path.wildcard(Path.join(@root, "*"), match_dot: true)

    files
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&database_file?/1)
    |> Enum.map(fn path -> {path, File.stat!(path, time: :posix).mtime} end)
    |> Enum.sort()
  end

  # The SQLite file is a live process's WAL, not presence storage; a checkpoint
  # during the test is noise, not a leak.
  defp database_file?(path), do: String.starts_with?(Path.basename(path), "zifiri_dev.db")
end
