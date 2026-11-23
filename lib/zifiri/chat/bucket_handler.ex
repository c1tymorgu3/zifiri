defmodule Zifiri.Chat.BucketHandler do
  @moduledoc """
  The `:chat` plane's writer: turns a drained bucket into one closed room batch.

  A secret send does not touch `Zifiri.Chat.Store` at accept time. The channel
  verifies the frame and queues `{:chat, room, message}` in `Zifiri.Bucket`;
  when the ten-minute bucket closes, the publisher hands the type's items here.

  The batch is exactly the messages written in the bucket, shuffled — no decoys
  are appended. A room is plaintext, so an observer reads every line whatever
  the batch size is; padding the batch to 120 would invent 120 candidate authors
  where `k` writers exist and would make the k-candidate claim false
  (`docs/claims.md` C-50). What the bucket hides on this plane is *when* a line
  was written: the whole batch is one drain at one clock instant, and the
  shuffle decides which position each writer's frame lands in. It hides nothing
  about what was written (C-51).

  The shuffle permutes senders, not a sender's own stream — the store reads a
  lower counter from a known key as a replay, so one member's frames keep their
  counter order inside the batch (`shuffled_in_replay_order/1`).

  A batch larger than the target is not truncated; an empty bucket never reaches
  this module because the publisher only dispatches a non-empty type group.
  """

  @behaviour Zifiri.Bucket.Publisher.Handler

  alias Zifiri.Chat.Store

  @impl true
  def handle_batch([], _ctx), do: :ok

  def handle_batch(items, _ctx) do
    room = items |> hd() |> elem(1)

    items
    |> Enum.map(fn {:chat, _room, message} -> message end)
    |> shuffled_in_replay_order()
    |> Enum.each(fn message -> Store.submit(room, message) end)

    :ok
  end

  # The store treats a lower counter from a known key as a replay, so arrival
  # order within one sender is part of the contract. Shuffling the batch must
  # therefore permute senders, not a sender's own stream: a member who queued
  # ctr 1, 2, 3 in one bucket still lands 1, 2, 3.
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
end
