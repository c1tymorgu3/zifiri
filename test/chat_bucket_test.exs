defmodule Zifiri.ChatBucketTest do
  @moduledoc """
  The room path through the bucket: `mode=secret` is a live bucket write, not a
  module test of `Zifiri.Bucket`.

  C-01…C-06 describe a ten-minute bucket filled to 120 and shuffled. Until the
  channel queues into it, those numbers only hold for the module. These tests
  drive the real `handle_in("msg", …)` and the real publisher tick, and pin:

    * three secret messages drain to exactly 120 stored messages;
    * the stored order is not the arrival order (seeded, so deterministic);
    * the three real frames survive byte-for-byte and the 117 decoys are
      1024-byte sealed envelopes;
    * `mode=fast` (and no mode) still writes one message immediately;
    * an empty bucket publishes nothing;
    * an unknown mode is refused as `bad_mode`.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Bucket
  alias Zifiri.Bucket.Publisher
  alias Zifiri.Chat.{Body, Message, RoomChannel, Socket, Store}
  alias Zifiri.Pow

  @room "chat:lobby"
  @pow_bits 12
  @target 120
  @body_bytes 1024

  setup do
    :ok = Bucket.reset()
    Store.reset()
    :rand.seed(:exsss, {7, 7, 7})

    on_exit(fn ->
      Bucket.reset()
      Store.reset()
    end)

    :ok
  end

  test "three secret messages drain to exactly 120 stored messages" do
    {pub, priv} = keypair()
    payloads = signed_many(priv, pub, ["bir", "iki", "üç"], "secret") |> Enum.map(&elem(&1, 0))

    for payload <- payloads do
      assert {:reply, %{status: "queued", mode: "secret"}, _socket} =
               RoomChannel.handle_in("msg", payload, socket())
    end

    # Nothing is visible before the bucket closes, and the queue holds the
    # three frames, not a partially written ring buffer.
    assert Store.messages(@room) == []
    assert Bucket.size() == 3

    assert :ok = publish()

    assert Bucket.size() == 0
    assert length(Store.messages(@room)) == @target
  end

  test "the stored order is not the arrival order" do
    # Three senders, so the shuffle is free to move each one's frame anywhere;
    # a single sender's stream stays chronological because the store would read
    # a late lower counter as a replay (see `shuffled_in_replay_order/1`).
    #
    # Whether a *single* batch comes out in a different order depends on the
    # shuffle's seed, so the assertion is over seeds: every run must contain all
    # three bodies, and at least one run must not preserve arrival order. A
    # handler that skipped the shuffle would fail the second half every time.
    orders =
      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, seed + 1, seed + 2})
        Store.reset()

        senders =
          for body <- ["arrival-1", "arrival-2", "arrival-3"] do
            {pub, priv} = keypair()
            {payload, padded} = signed(priv, pub, 1, body, "secret")

            assert {:reply, %{status: "queued"}, _} =
                     RoomChannel.handle_in("msg", payload, socket())

            {body, padded}
          end

        assert :ok = publish()
        by_body = Map.new(senders)

        @room
        |> Store.messages()
        |> Enum.reverse()
        |> Enum.flat_map(fn message ->
          case Enum.find(by_body, fn {_body, padded} -> padded == message.body end) do
            nil -> []
            {body, _padded} -> [body]
          end
        end)
      end

    for order <- orders, do: assert(Enum.sort(order) == ["arrival-1", "arrival-2", "arrival-3"])

    assert Enum.any?(orders, &(&1 != ["arrival-1", "arrival-2", "arrival-3"])),
           "every seed preserved arrival order: #{inspect(orders)}"
  end

  test "the real bodies survive and every decoy is a 1024 B sealed envelope" do
    {pub, priv} = keypair()
    signed = signed_many(priv, pub, ["gerçek-1", "gerçek-2", "gerçek-3"], "secret")
    reals = Enum.map(signed, fn {_payload, padded} -> padded end)

    for {payload, _padded} <- signed do
      assert {:reply, %{status: "queued"}, _} = RoomChannel.handle_in("msg", payload, socket())
    end

    assert :ok = publish()

    stored = Store.messages(@room)
    bodies = Enum.map(stored, & &1.body)

    assert length(stored) == @target

    for padded <- reals do
      assert Enum.count(bodies, &(&1 == padded)) == 1
    end

    decoys = bodies -- reals

    assert length(decoys) == @target - length(reals)
    assert Enum.all?(decoys, &(byte_size(&1) == @body_bytes))
    assert Enum.uniq(decoys) == decoys, "two decoys were byte-identical"

    decoy_messages = Enum.reject(stored, &(&1.body in reals))
    decoy_keys = Enum.map(decoy_messages, & &1.pubkey)
    assert Enum.uniq(decoy_keys) == decoy_keys, "two decoys reused a key"
  end

  test "fast is the default and writes one message immediately" do
    {pub, priv} = keypair()

    # No "mode" key at all: the contract's default.
    {payload, _padded} = signed(priv, pub, 1, "hızlı", nil)
    assert {:noreply, _socket} = RoomChannel.handle_in("msg", payload, socket())

    assert [message] = Store.messages(@room)
    assert is_integer(message.id)
    assert Bucket.size() == 0, "fast mode must not touch the bucket"
  end

  test "an empty bucket publishes nothing" do
    assert Bucket.size() == 0
    assert :ok = publish()
    assert Store.messages(@room) == []

    # A second tick stays empty too: the guard is the empty drain, not a flag.
    assert :ok = publish()
    assert Store.messages(@room) == []
  end

  test "an unknown mode is refused as bad_mode" do
    assert {:reply, {:error, %{reason: "bad_mode"}}, _socket} =
             RoomChannel.handle_in("msg", %{"mode" => "turbo"}, socket())

    assert Bucket.size() == 0
    assert Store.messages(@room) == []
  end

  # -- helpers ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp signed(priv, pub, ctr, body, mode) do
    {:ok, padded} = Body.pad(body)
    epoch = Store.epoch(@room)
    input = Message.signing_input(@room, epoch, ctr, padded)

    payload = %{
      "body" => body,
      "pubkey" => Message.encode64(pub),
      "sig" => Message.encode64(:crypto.sign(:eddsa, :none, input, [priv, :ed25519])),
      "ctr" => ctr,
      "nonce" => Pow.solve(Message.pow_hash(input), @pow_bits)
    }

    payload = if mode, do: Map.put(payload, "mode", mode), else: payload
    {payload, padded}
  end

  defp signed_many(priv, pub, bodies, mode) do
    bodies
    |> Enum.with_index(1)
    |> Enum.map(fn {body, ctr} -> signed(priv, pub, ctr, body, mode) end)
  end

  defp socket do
    %Phoenix.Socket{
      handler: Socket,
      endpoint: Zifiri.Endpoint,
      topic: @room,
      pubsub_server: Zifiri.PubSub,
      joined: true,
      transport_pid: self()
    }
  end

  defp publish do
    now = Bucket.now_ms()
    rand = &:rand.bytes/1
    Publisher.tick(now_ms: now, rand: rand)
  end
end
