defmodule Zifiri.Chat do
  @moduledoc """
  The chat plane: a socket, one public room, and a buffer that only exists
  while the beam is up.

  Nothing in this namespace touches `Zifiri.Repo`. There is no chat table, no
  chat column, no chat file, no chat log line — a message is a struct field in
  `Zifiri.Chat.Store` and dies with the process (`plan §7.1`). Restart is a
  wipe, and that is the feature.

  Pieces:

    * `Zifiri.Chat.Store` — ring buffer (500 messages / 15 min), rate counters,
      one `last_ctr` per key as the whole replay state (10-minute TTL), room
      epochs, and a 4 KB hard ceiling on any single message;
    * `Zifiri.Chat.Socket` — the transport's entry point, no identity;
    * `Zifiri.Chat.RoomChannel` — `chat:lobby`, where a signed message that also
      carries 12 bits of proof of work becomes a broadcast, and where `join`
      answers with the epoch, the newest 50 lines and the per-key counter
      summary rather than the whole buffer;
    * `Zifiri.Chat.Body` — fixed-bucket padding so message length leaves no
      trace;
    * `Zifiri.Chat.Message` — signing input, pow hash, verification, wire form.

  Join is the only read path and it is bounded on purpose (`§7.1`): fifty
  messages, each one already a fixed bucket, and a counter summary whose size is
  one integer per recently active key. Nothing about the reply grows with how
  long the room has been up.
  """

  @doc """
  Rooms that exist. A fixed list, not a namespace: `chat:*` would let a client
  mint a room and with it a fresh 500-message buffer at will (`plan §7.1`).
  """
  @spec rooms() :: [String.t()]
  def rooms, do: ["chat:lobby"]
end
