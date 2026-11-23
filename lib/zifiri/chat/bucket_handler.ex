defmodule Zifiri.Chat.BucketHandler do
  @moduledoc """
  The `:chat` plane's writer: turns a drained bucket into one closed room batch.

  A secret send does not touch `Zifiri.Chat.Store` at accept time. The channel
  verifies the frame and queues `{:chat, room, message}` in `Zifiri.Bucket`;
  when the ten-minute bucket closes, the publisher hands the type's items here.

  The batch is completed the way `docs/spec.md` §"The number: bucket size"
  describes: `n` real messages plus `120 - n` decoys from `Zifiri.Chat.Decoy`,
  all shuffled together, then submitted through the same `Store.submit/2` a
  fast message uses. After the drain the store cannot say which row arrived
  from a socket and which was minted at close time — the decoys carry the same
  frame shape, an Ed25519 signature under their own ephemeral key and an
  AES-256-GCM sealed 4096-byte envelope (`Zifiri.Chat.Decoy.fill/2` builds
  them; nothing here invents a body).

  The shuffle permutes senders, not a sender's own stream — the store reads a
  lower counter from a known key as a replay, so one member's frames keep their
  counter order inside the batch (`shuffled_in_replay_order/1`).

  A batch larger than the target is not padded and not truncated; an empty
  bucket never reaches this module because the publisher only dispatches a
  non-empty type group.
  """

  @behaviour Zifiri.Bucket.Publisher.Handler

  alias Zifiri.Bucket
  alias Zifiri.Chat.Decoy
  alias Zifiri.Chat.Store

  @impl true
  def handle_batch([], _ctx), do: :ok

  def handle_batch(items, ctx) do
    room = items |> hd() |> elem(1)
    real = Enum.map(items, fn {:chat, _room, message} -> message end)
    at = ctx.now

    # The decoys are signed against the epoch the real frames were signed
    # against, so the batch verifies as one batch. `real:` is explicit: the
    # bucket has already been drained, so `Decoy.fill/2`'s `Bucket.size/0`
    # default would read zero and pad a batch that is not empty.
    decoys =
      Decoy.fill(Bucket.target(),
        real: length(real),
        room: room,
        epoch: Store.epoch(room),
        at: at
      )
      |> Enum.map(&frame_to_message/1)

    (real ++ decoys)
    |> shuffled_in_replay_order()
    |> Enum.each(fn message -> Store.submit(room, message) end)

    :ok
  end

  # The store treats a lower counter from a known key as a replay, so arrival
  # order within one sender is part of the contract. Shuffling the batch must
  # therefore permute senders, not a sender's own stream: a member who queued
  # ctr 1, 2, 3 in one bucket still lands 1, 2, 3. Decoys each carry a fresh
  # key, so they are unaffected; the interspersed positions are what makes the
  # stored order differ from the queue order.
  defp shuffled_in_replay_order(messages) do
    shuffled = Enum.shuffle(messages)

    queues =
      shuffled
      |> Enum.group_by(& &1.pubkey)
      |> Map.new(fn {pubkey, own} -> {pubkey, Enum.sort_by(own, & &1.ctr)} end)

    {ordered, _queues} =
      Enum.map_reduce(shuffled, queues, fn message, queues ->
        [next | rest] = Map.fetch!(queues, message.pubkey)
        {next, Map.put(queues, message.pubkey, rest)}
      end)

    ordered
  end

  # A decoy entering the store looks like a message entering the store: the
  # sealed envelope is the body, its size is the bucket, and the counter is a
  # constant — every decoy brings its own public key, so no two share a replay
  # stream and the value is never compared against a real sender's.
  defp frame_to_message(frame) do
    %{
      pubkey: frame.pubkey,
      sig: frame.sig,
      ctr: 0,
      padded: frame.envelope,
      bucket: byte_size(frame.envelope)
    }
  end
end
