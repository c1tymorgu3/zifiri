defmodule Zifiri.BucketTest do
  @moduledoc """
  The ten-minute bucket: boundaries, fixed cadence, shuffle, and the promise
  that nothing is lost or delivered twice.

  The clock is injected everywhere it can be — `bucket_start/1`, `add/2`,
  `drain/1` — so the boundary tests are arithmetic on a fixed instant instead of
  ten-minute sleeps. `now_ms/0` is exercised once, against the system clock,
  because that is the only thing it does.
  """

  use ExUnit.Case, async: false

  alias Zifiri.Bucket

  # 1_764_000_000_000 ms is a bucket start: 1_764_000_000_000 / 600_000 is a
  # whole number. "09:59" is one minute before it, "10:01" one minute after.
  @anchor 1_764_000_000_000
  @before @anchor - 60_000
  @bucket_after @anchor + 60_000

  setup do
    Bucket.reset()
    on_exit(fn -> Bucket.reset() end)
    :ok
  end

  # --- geometry --------------------------------------------------------------

  test "a bucket is ten minutes and holds 120" do
    assert Bucket.bucket_ms() == 600_000
    assert Bucket.target() == 120
  end

  test "9:59 and 10:01 are in different buckets" do
    refute Bucket.bucket_start(@before) == Bucket.bucket_start(@bucket_after)
    assert Bucket.bucket_start(@before) == @anchor - 600_000
    assert Bucket.bucket_start(@bucket_after) == @anchor
  end

  test "the boundary instant belongs to the bucket it opens" do
    # 10:00:00.000 is the first millisecond of the 10:00 bucket, not the last of
    # 09:50 — the boundary has to fall on exactly one side.
    assert Bucket.bucket_start(@anchor) == @anchor
    assert Bucket.bucket_start(@anchor - 1) == @anchor - 600_000
    assert Bucket.bucket_start(@anchor + 1) == @anchor
  end

  test "bucket_end/1 is the start of the next bucket" do
    assert Bucket.bucket_end(Bucket.bucket_start(@before)) == @anchor
    assert Bucket.bucket_end(@anchor) == @anchor + 600_000
    start = Bucket.bucket_start(@before)
    assert Bucket.bucket_end(start) - start == 600_000
  end

  test "every instant falls inside its own bucket, for a spread of instants" do
    for offset <- [0, 1, 59_999, 60_000, 299_999, 599_999, 600_000, 1_234_567] do
      now = @anchor + offset
      start = Bucket.bucket_start(now)

      assert rem(start, 600_000) == 0
      assert start <= now
      assert now < Bucket.bucket_end(start)
    end
  end

  test "now_ms/0 is the wall clock in milliseconds" do
    now = Bucket.now_ms()

    assert is_integer(now)
    # Same clock as the rest of the node, within a second of it.
    assert abs(now - System.system_time(:millisecond)) < 1_000
  end

  # --- the table -------------------------------------------------------------

  test "add/1 counts and drain/1 empties" do
    assert Bucket.size() == 0

    :ok = Bucket.add(:a)
    :ok = Bucket.add(:b)
    :ok = Bucket.add(:c)

    assert Bucket.size() == 3

    %{items: items, size: size, bucket: bucket} = Bucket.drain()

    assert size == 3
    assert Enum.sort(items) == [:a, :b, :c]
    assert bucket == Bucket.bucket_start(Bucket.now_ms())
    assert Bucket.size() == 0
  end

  test "a full bucket is not drained early" do
    for i <- 1..120, do: Bucket.add({:real, i})

    # 120 in the table and nothing has been published: the flush is on the
    # clock, not on the count. A count-triggered flush would hand the observer
    # the arrival time of the 120th message.
    assert Bucket.size() == 120

    for i <- 121..125, do: Bucket.add({:real, i})

    assert Bucket.size() == 125
    assert %{size: 125} = Bucket.drain()
    assert Bucket.size() == 0
  end

  test "drain/1 returns every item exactly once" do
    items = for i <- 1..50, do: {:item, rem(i, 7)}

    Enum.each(items, &Bucket.add/1)

    %{items: drained, size: size} = Bucket.drain()

    assert size == 50
    assert Enum.sort(drained) == Enum.sort(items)
    assert Bucket.size() == 0
  end

  test "drain/1 of an empty bucket is empty, not an error" do
    assert %{items: [], size: 0} = Bucket.drain()
  end

  test "two identical items are two rows" do
    :ok = Bucket.add(:same)
    :ok = Bucket.add(:same)

    assert Bucket.size() == 2
    assert %{items: [:same, :same]} = Bucket.drain()
  end

  test "an item from a closed bucket is carried, not dropped" do
    # Added at 09:59, drained at 10:01 — the scheduler was late by a boundary.
    # Losing the write would be a worse failure than a batch one item larger.
    :ok = Bucket.add(:late, @before)

    %{items: items, bucket: bucket} = Bucket.drain(@bucket_after)

    assert items == [:late]
    assert bucket == @anchor
  end

  test "drain/1 is a shuffle, not insertion order" do
    # Statistical, not exact: the probability that 120 shuffles all come back
    # in the one insertion order is 1/(120!)^119.
    items = Enum.to_list(1..120)

    orders =
      for _ <- 1..20 do
        Enum.each(items, &Bucket.add/1)
        %{items: drained} = Bucket.drain()
        assert Enum.sort(drained) == items
        drained
      end

    assert length(Enum.uniq(orders)) > 1,
           "drain/1 returned insertion order on every one of 20 runs"
  end

  test "the table survives the process that first touched it" do
    # The owner is started on demand and is not linked to the caller: a bucket
    # that died with the first process to add to it would be a bucket of one.
    parent = self()

    pid =
      spawn(fn ->
        Bucket.add(:from_child)
        send(parent, :added)
      end)

    assert_receive :added, 1_000
    refute Process.alive?(pid)

    assert Bucket.size() == 1
    assert %{items: [:from_child]} = Bucket.drain()
  end
end
