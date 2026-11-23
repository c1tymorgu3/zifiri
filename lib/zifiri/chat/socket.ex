defmodule Zifiri.Chat.Socket do
  @moduledoc """
  Transport entry point for chat. It accepts every connection and identifies
  none (`plan §7.1`, `§7.2`).

  `connect/3` returns the socket untouched: no query parameter, no header, no
  IP is read, so there is nothing here that could tie a socket to a person or
  to another socket. `id/1` is `nil` on purpose — a socket id is what Phoenix
  uses for presence and for routing a message to "a user's" connections, and
  both would be a link between sessions that chat promises not to have.

  Identity in this plane is the per-room Ed25519 session key carried inside
  each message, not a connection.
  """

  use Phoenix.Socket

  channel "chat:lobby", Zifiri.Chat.RoomChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
