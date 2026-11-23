defmodule Zifiri.MailboxBucketTest.Collector do
  @moduledoc false
  @behaviour Zifiri.Bucket.Publisher.Handler

  @impl true
  def handle_batch(items, ctx) do
    :persistent_term.put({__MODULE__, :last}, {items, ctx})
    :ok
  end
end

defmodule Zifiri.MailboxBucketTest do
  @moduledoc """
  C-14: a 1:1 write goes through the bucket, and the bucket closes to 120.

  `Mailbox.deliver/3` queues `{:mailbox, tag, envelope, ttl}`; a publisher tick
  drains it and the mailbox handler writes the real envelopes plus enough
  decoys to reach exactly `Zifiri.Bucket.target/0` (120) in one transaction.
  These tests pin the numbers, not the prose:

    * three real envelopes + one drain -> 120 rows, all 4096 bytes;
    * the three real tags survive; every other tag is a fresh 16 random bytes;
    * every decoy is a decodable frame (`Envelope.decode/1` answers
      `{:ok, payload, 4096}`) with a random, variable-length body — the same
      frame a real row carries, never raw noise (C-04);
    * an empty bucket writes nothing (no 120-decoy phantom batch);
    * `fetch/3` sees only the tag it asked for, never a decoy;
    * every row, decoy included, carries the same 72 h lifetime.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Bucket
  alias Zifiri.Bucket.Publisher
  alias Zifiri.Mailbox
  alias Zifiri.Mailbox.Decoy
  alias Zifiri.Mailbox.Envelope
  alias Zifiri.Repo

  @target 120
  @ttl_ms 72 * 60 * 60 * 1000

  setup do
    :ok = Bucket.reset()
    :rand.seed(:exsss, {101, 202, 303})
    :ok
  end

  test "three real envelopes drain to exactly 120 rows, all of envelope_bytes/0" do
    start = now()
    _reals = queue_reals(3, start)

    assert Bucket.size() == 3
    assert rows() == 0, "no direct write path: nothing is on disk before the drain"

    assert :ok = publish(start)

    assert rows() == @target

    sizes = Repo.all(from e in Envelope, select: e.envelope) |> Enum.map(&byte_size/1)
    assert Enum.uniq(sizes) == [Mailbox.envelope_bytes()]
    assert Mailbox.envelope_bytes() == 4096
  end

  test "the real tags survive and every decoy tag is fresh 16 random bytes" do
    start = now()
    reals = queue_reals(3, start)
    real_tags = Enum.map(reals, &elem(&1, 1))

    assert :ok = publish(start)

    stored = Repo.all(from e in Envelope, select: e.mailbox_id)

    for tag <- real_tags do
      assert Enum.count(stored, &(&1 == tag)) == 1
    end

    decoy_tags = stored -- real_tags

    assert length(decoy_tags) == @target - length(reals)
    assert Enum.uniq(decoy_tags) == decoy_tags, "two decoys shared a tag"
    assert Enum.all?(decoy_tags, &(byte_size(&1) == 16))
    refute Enum.any?(decoy_tags, &(&1 in real_tags))

    # The recipient does not know a decoy tag; the wire only returns what the
    # caller can address, and a tag that was never queued addresses nothing.
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(Mailbox.new_id())
  end

  test "the real envelopes keep their own bytes; decoys are random and distinct" do
    start = now()
    reals = queue_reals(3, start)

    assert :ok = publish(start)

    for {:mailbox, tag, envelope, _ttl} <- reals do
      assert {:ok, %{envelopes: [row]}} = Mailbox.fetch(tag)
      assert row.envelope == envelope
    end

    real_envelopes = Enum.map(reals, &elem(&1, 2))

    decoy_envelopes =
      Repo.all(
        from e in Envelope,
          where: e.mailbox_id not in ^Enum.map(reals, &elem(&1, 1)),
          select: e.envelope
      )

    assert length(decoy_envelopes) == @target - 3
    assert Enum.uniq(decoy_envelopes) == decoy_envelopes, "two decoys were byte-identical"
    refute Enum.any?(decoy_envelopes, &(&1 in real_envelopes))
  end

  test "every decoy envelope is a real frame with a random, variable body" do
    start = now()
    reals = queue_reals(3, start)
    real_tags = Enum.map(reals, &elem(&1, 1))

    assert :ok = publish(start)

    decoys =
      Repo.all(
        from e in Envelope,
          where: e.mailbox_id not in ^real_tags,
          select: e.envelope
      )

    assert length(decoys) == @target - 3

    payloads =
      for envelope <- decoys do
        assert byte_size(envelope) == Mailbox.envelope_bytes()
        # The frame a real row carries: a valid 32-bit length prefix, a body, a
        # zero tail. `decode/1` is the reader both classes meet, and it answers
        # the same thing for both.
        assert {:ok, payload, 4096} = Zifiri.Envelope.decode(envelope)
        payload
      end

    ratios = Enum.map(payloads, &printable_ratio/1)
    mean = Enum.sum(ratios) / length(ratios)

    # Random bytes are ~37% printable ASCII; text is ~100%. A decoy that
    # carried a sentence would drag this mean up — that is the tell C-04
    # forbids.
    assert mean < 0.5, "decoy bodies average #{Float.round(mean, 2)} printable"

    # Variable length, like a real message: a fixed payload length would put
    # the same four bytes at the head of every decoy.
    lengths = payloads |> Enum.map(&byte_size/1) |> Enum.uniq()
    assert length(lengths) > 20
    assert Enum.all?(payloads, &(byte_size(&1) in 1..(Mailbox.envelope_bytes() - 4)))
  end

  test "an empty bucket publishes nothing — no phantom 120-decoy batch" do
    assert Bucket.size() == 0
    assert :ok = publish()
    assert rows() == 0

    # And it stays empty after a second tick: the guard is the empty drain, not
    # a one-shot flag.
    assert :ok = publish()
    assert rows() == 0
  end

  test "fetch sees only the tag it asked for, with decoys filling the table" do
    start = now()
    reals = queue_reals(3, start)

    assert :ok = publish(start)

    for {:mailbox, tag, envelope, _ttl} <- reals do
      assert {:ok, %{envelopes: [row], more: false}} = Mailbox.fetch(tag)
      assert row.envelope == envelope
    end

    # A tag the recipient never learned does not resolve, even though 117 other
    # rows sit in the same table.
    assert {:ok, %{envelopes: []}} = Mailbox.fetch(Mailbox.new_id())
  end

  test "real and decoy rows carry the same 72 h lifetime" do
    start = now()
    reals = queue_reals(3, start)

    assert :ok = publish(start)

    spans = Repo.all(from e in Envelope, select: {e.created_ms, e.expires_ms})

    assert length(spans) == @target
    assert Enum.all?(spans, fn {created, _expires} -> created == start end)
    assert Enum.all?(spans, fn {created, expires} -> expires - created == @ttl_ms end)

    # The API default and the row agree.
    assert Mailbox.ttl_ms() == @ttl_ms
    assert [{:mailbox, _, _, ttl} | _] = reals
    assert ttl == @ttl_ms
  end

  test "a batch larger than the target is not padded and not truncated" do
    start = now()

    for _ <- 1..130 do
      tag = Mailbox.new_id()
      assert {:ok, :queued} = Mailbox.deliver(tag, :binary.copy(<<0xEE>>, 4096), now_ms: start)
    end

    assert :ok = publish(start)
    assert rows() == 130
  end

  test "one invalid member rolls the whole batch back" do
    start = now()
    queue_reals(2, start)

    # Bypass `deliver/3` to put a bad row in the queue: `insert_all` inside the
    # transaction must fail the whole batch, not write the two good rows.
    :ok = Bucket.add({:mailbox, Mailbox.new_id(), :binary.copy(<<0>>, 100), @ttl_ms}, start)

    assert {:error, _reason} = publish(start)
    assert rows() == 0
  end

  test "the publisher dispatches by item type, not by a mailbox-only path" do
    {:ok, raw} = Mailbox.decode_id(Mailbox.new_id())
    :ok = Bucket.add({:mailbox, raw, :binary.copy(<<0xAB>>, 4096), @ttl_ms}, 1)

    on_exit(fn -> :persistent_term.erase({Zifiri.MailboxBucketTest.Collector, :last}) end)

    assert :ok =
             Publisher.tick(
               now_ms: 1,
               rand: &:rand.bytes/1,
               handlers: %{mailbox: Zifiri.MailboxBucketTest.Collector}
             )

    assert {[{:mailbox, ^raw, _envelope, @ttl_ms}], %{now: 1, bucket: 0}} =
             :persistent_term.get({Zifiri.MailboxBucketTest.Collector, :last})

    # The mailbox writer was not invoked: the handler table decides the writer.
    assert rows() == 0
  end

  test "a decoy built on its own is the same shape as one the handler writes" do
    decoy = Decoy.build(ttl_ms: @ttl_ms, rand: &:rand.bytes/1)

    assert byte_size(decoy.mailbox_id) == 16
    assert byte_size(decoy.envelope) == Mailbox.envelope_bytes()
    assert decoy.ttl == @ttl_ms
    refute decoy.mailbox_id == <<0::128>>
    assert {:ok, _} = Mailbox.decode_id(decoy.mailbox_id)
    assert {:ok, payload, 4096} = Zifiri.Envelope.decode(decoy.envelope)
    assert byte_size(payload) in 1..(Mailbox.envelope_bytes() - 4)
  end

  # -- helpers ----------------------------------------------------------------

  # Share of bytes that are printable ASCII. Random bytes land near 0.37; a
  # body of text lands near 1.0. Used instead of a UTF-8 check so a short
  # payload of legitimate random bytes cannot fail the test by accident.
  defp printable_ratio(payload) do
    n = byte_size(payload)
    printable = payload |> :binary.bin_to_list() |> Enum.count(&(&1 in 0x20..0x7E))
    if n == 0, do: 0.0, else: printable / n
  end

  defp queue_reals(n, start) do
    for byte <- 1..n do
      tag = Mailbox.new_id()
      envelope = :binary.copy(<<byte::8>>, Mailbox.envelope_bytes())

      assert {:ok, :queued} = Mailbox.deliver(tag, envelope, now_ms: start)

      {:mailbox, tag, envelope, @ttl_ms}
    end
  end

  defp publish(now \\ nil) do
    opts = if now == nil, do: [rand: &:rand.bytes/1], else: [now_ms: now, rand: &:rand.bytes/1]
    Publisher.tick(opts)
  end

  defp rows, do: Repo.aggregate(Envelope, :count, :id)

  defp now, do: System.system_time(:millisecond)
end
