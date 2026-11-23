defmodule Zifiri.Chat.RoomChannel do
  @moduledoc """
  `chat:lobby` — the one room, open to everyone, anonymous by construction.

  Client pushes `"msg"` with

      %{"body" => raw, "pubkey" => pk_b64, "sig" => sig_b64, "ctr" => n,
        "nonce" => n, "mode" => "fast" | "secret"}

  `"mode"` is optional and defaults to `"fast"`. The two modes differ only in
  where a verified message is written:

    * **fast** — `Zifiri.Chat.Store.submit/2` immediately and `broadcast!` to
      the room, exactly as before. Latency is the socket round trip.
    * **secret** — the same verified, padded frame is queued in
      `Zifiri.Bucket` as `{:chat, "chat:lobby", message}`. Nothing is visible
      until the ten-minute bucket closes, when `Zifiri.Chat.BucketHandler`
      completes the batch to 120 with decoys, shuffles it and submits it. The
      reply is `%{status: "queued", mode: "secret"}`; latency is up to one
      bucket.

  The server pads the body to a fixed bucket, checks the proof of work over
  `Zifiri.Chat.Message.pow_hash/1` (12 bits, §7.4), verifies the Ed25519
  signature over `Zifiri.Chat.Message.signing_input/4`, and only then takes the
  fast or the secret path. Nothing is written to disk at any point (`plan §7.1`).

  The proof of work comes before the signature on purpose: a signature costs a
  curve verification, a hash costs a hash, so garbage is refused at the cheap
  gate. Twelve bits is one frame of work per message — enough to make a flood
  cost the sender more than it costs the room, small enough that an honest
  client pays it once per line.

  `join` answers with three things and no more:

    * `"epoch"` — the room's current epoch, which the client signs against;
    * `"last_ctr"` — `%{pubkey_b64 => highest_ctr_accepted}`, so a reconnecting
      client resumes its counter where the server stopped instead of guessing
      and being refused as a replay (§7.3). One integer per key: the summary is
      the whole replay state, so nothing can have been evicted from it;
    * `"messages"` — at most the newest 50 lines, newest first (§7.1). A full
      500-message buffer on every join is a megabyte per client, and the point
      of the cap is that the cost of joining does not grow with uptime.

  Rejections carry a constant reason and never echo the payload: an error that
  reflects the request is an error that ends up in a log (`§5.1`).

  Replies to a rejected message are `{"error": reason}` with one of
  `bad_request`, `too_large`, `bad_pow`, `bad_signature`, `replay`,
  `rate_limited`, `unknown_event`.
  """

  use Phoenix.Channel

  alias Zifiri.Bucket
  alias Zifiri.Chat.{Body, Message, Store}
  alias Zifiri.Pow

  @room "chat:lobby"
  @max_ctr 18_446_744_073_709_551_616

  # One message, one solved nonce. 12 bits ≈ 4096 hashes: a few milliseconds in
  # a browser worker, and 4096× the cost of a free message for a flood.
  @pow_bits 12

  # `join` is a read of the room's *recent* history, not a download of it.
  @join_messages 50

  @impl true
  def join("chat:lobby", _params, socket) do
    reply = %{
      "epoch" => Message.encode64(Store.epoch(@room)),
      "messages" =>
        Store.recent(@room, @join_messages)
        |> Enum.map(&Message.to_json/1),
      "last_ctr" =>
        Store.last_ctrs(@room)
        |> Map.new(fn {pubkey, ctr} -> {Message.encode64(pubkey), ctr} end)
    }

    {:ok, reply, socket}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_room"}}

  @impl true
  def handle_in("msg", payload, socket) when is_map(payload) do
    with {:ok, mode} <- mode(payload),
         {:ok, incoming} <- parse(payload),
         {:ok, padded} <- Body.pad(incoming.body) do
      authenticate(socket, incoming, padded, mode)
    else
      {:error, :too_large} -> reject(socket, "too_large")
      {:error, reason} -> reject(socket, reason)
    end
  end

  def handle_in("msg", _payload, socket), do: reject(socket, "bad_request")

  def handle_in(_event, _payload, socket), do: reject(socket, "unknown_event")

  defp authenticate(socket, incoming, padded, mode) do
    epoch = Store.epoch(@room)
    signing_input = Message.signing_input(@room, epoch, incoming.ctr, padded)

    cond do
      not Pow.verify(Message.pow_hash(signing_input), incoming.nonce, @pow_bits) ->
        reject(socket, "bad_pow")

      not Message.verify(incoming.pubkey, incoming.sig, signing_input) ->
        reject(socket, "bad_signature")

      true ->
        append(socket, incoming, padded, mode)
    end
  end

  # Fast: the frame is in the buffer when this returns, and the room is told.
  defp append(socket, incoming, padded, :fast) do
    message = %{
      pubkey: incoming.pubkey,
      sig: incoming.sig,
      ctr: incoming.ctr,
      padded: padded,
      bucket: byte_size(padded)
    }

    case Store.submit(@room, message) do
      {:ok, stored} ->
        broadcast!(socket, "msg", Message.to_json(stored))
        {:noreply, socket}

      {:error, :rate_limited} ->
        reject(socket, "rate_limited")

      {:error, :replay} ->
        reject(socket, "replay")

      {:error, :too_large} ->
        reject(socket, "too_large")
    end
  end

  # Secret: the same verified frame survives untouched as a bucket entry. The
  # store is not written and the room is not told; that happens at the bucket's
  # close, mixed with 120 - n decoys (`Zifiri.Chat.BucketHandler`).
  defp append(socket, incoming, padded, :secret) do
    message = %{
      pubkey: incoming.pubkey,
      sig: incoming.sig,
      ctr: incoming.ctr,
      padded: padded,
      bucket: byte_size(padded)
    }

    :ok = Bucket.add({:chat, @room, message})

    {:reply, %{status: "queued", mode: "secret"}, socket}
  end

  # Absent means the default, which is fast (`docs/spec.md` §"Two modes"). An
  # unknown or non-string value is refused before any cryptographic work, and
  # the reason never echoes the payload.
  defp mode(payload) do
    case Map.get(payload, "mode", "fast") do
      "fast" -> {:ok, :fast}
      "secret" -> {:ok, :secret}
      _other -> {:error, "bad_mode"}
    end
  end

  defp reject(socket, reason), do: {:reply, {:error, %{reason: reason}}, socket}

  # `nonce` is deliberately optional at parse time and required by the work
  # check: a payload without one is a `bad_pow`, which tells a client what is
  # missing without pretending the frame was malformed.
  defp parse(payload) do
    with %{"body" => body, "pubkey" => pubkey, "sig" => sig, "ctr" => ctr} <- payload,
         true <- is_binary(body),
         {:ok, pubkey_bin} <- Message.decode64(pubkey),
         {:ok, sig_bin} <- Message.decode64(sig),
         true <- byte_size(pubkey_bin) == 32,
         true <- byte_size(sig_bin) == 64,
         true <- valid_ctr?(ctr) do
      {:ok,
       %{body: body, pubkey: pubkey_bin, sig: sig_bin, ctr: ctr, nonce: Map.get(payload, "nonce")}}
    else
      _other -> {:error, "bad_request"}
    end
  end

  defp valid_ctr?(ctr), do: is_integer(ctr) and ctr >= 0 and ctr < @max_ctr
end
