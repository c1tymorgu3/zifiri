defmodule Zifiri.ChatTest do
  @moduledoc """
  Chat plane: signature gate, proof of work, ring buffer, TTL, restart
  semantics, replay counter, rate limit, and the size of a `join` reply.
  Nothing here touches the database on purpose — the point of the plane is that
  a chat line never becomes a row.
  """

  use Zifiri.DataCase, async: false

  alias Zifiri.Chat.{Body, Message, RoomChannel, Socket, Store}
  alias Zifiri.Listings.Listing
  alias Zifiri.Pow

  @room "chat:lobby"
  @pow_bits 12

  setup do
    Store.reset()
    on_exit(fn -> Store.reset() end)
    :ok
  end

  # --- helpers ---------------------------------------------------------------

  defp keypair do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  defp signed(priv, pub, ctr, body, epoch \\ nil) do
    {:ok, padded} = Body.pad(body)
    epoch = epoch || Store.epoch(@room)
    input = Message.signing_input(@room, epoch, ctr, padded)
    sig = :crypto.sign(:eddsa, :none, input, [priv, :ed25519])

    %{
      "body" => body,
      "pubkey" => Message.encode64(pub),
      "sig" => Message.encode64(sig),
      "ctr" => ctr,
      "nonce" => Pow.solve(Message.pow_hash(input), @pow_bits)
    }
  end

  # A nonce that provably does not solve the work for this payload: the first
  # one that fails, rather than a guess that fails 4095 times in 4096.
  defp bad_nonce(input) do
    Enum.find(0..1_000, fn nonce -> not Pow.verify(Message.pow_hash(input), nonce, @pow_bits) end)
  end

  defp payload_input(payload) do
    {:ok, padded} = Body.pad(payload["body"])
    Message.signing_input(@room, Store.epoch(@room), payload["ctr"], padded)
  end

  # Re-grinds the work for a payload an attacker has just edited: the point of
  # the signature tests is what happens *after* the work is paid, not that the
  # old nonce no longer matches.
  defp grind(payload) do
    %{payload | "nonce" => Pow.solve(Message.pow_hash(payload_input(payload)), @pow_bits)}
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

  defp stored(pubkey, ctr, padded \\ :binary.copy("x", 16), bucket \\ 256) do
    %{pubkey: pubkey, sig: :binary.copy(<<0>>, 64), ctr: ctr, padded: padded, bucket: bucket}
  end

  # --- socket and room -------------------------------------------------------

  test "the socket exposes exactly one room and no other" do
    assert {RoomChannel, _opts} = Socket.__channel__(@room)
    assert is_nil(Socket.__channel__("chat:private"))
    assert is_nil(Socket.__channel__("room:lobby"))
  end

  test "a socket identifies nobody" do
    socket = %Phoenix.Socket{handler: Socket}

    assert {:ok, %Phoenix.Socket{}} = Socket.connect(%{"token" => "ignored"}, socket, %{})
    assert is_nil(Socket.id(socket))
  end

  test "join is open, returns the epoch, the newest lines and the counter summary" do
    {pub, priv} = keypair()
    assert {:noreply, _} = RoomChannel.handle_in("msg", signed(priv, pub, 1, "ilk"), socket())

    assert {:ok, reply, _socket} = RoomChannel.join(@room, %{}, socket())
    assert {:ok, epoch} = Message.decode64(reply["epoch"])
    assert byte_size(epoch) == 16
    assert [%{"ctr" => 1}] = reply["messages"]
    assert reply["last_ctr"] == %{Message.encode64(pub) => 1}
  end

  test "join on any other topic is refused" do
    assert {:error, %{reason: "unknown_room"}} = RoomChannel.join("chat:other", %{}, socket())
  end

  # --- signature gate --------------------------------------------------------

  test "a message without a signature is refused" do
    {pub, _priv} = keypair()

    payload = %{
      "body" => "unsigned",
      "pubkey" => Message.encode64(pub),
      "ctr" => 1
    }

    assert {:reply, {:error, %{reason: "bad_request"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())
  end

  test "a signature that is not 64 bytes is refused as a bad request" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "kisa imza")

    assert {:reply, {:error, %{reason: "bad_request"}}, _} =
             RoomChannel.handle_in(
               "msg",
               %{payload | "sig" => Message.encode64(<<1, 2, 3>>)},
               socket()
             )
  end

  test "a signature made by another key is refused" do
    {pub, _priv} = keypair()
    {_other_pub, other_priv} = keypair()

    assert {:reply, {:error, %{reason: "bad_signature"}}, _} =
             RoomChannel.handle_in("msg", signed(other_priv, pub, 1, "sahte"), socket())
  end

  test "a signature over a different counter is refused" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 7, "ctr oynatildi") |> Map.put("ctr", 8) |> grind()

    assert {:reply, {:error, %{reason: "bad_signature"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())
  end

  test "a truncated public key is a bad request, not a crash" do
    {_pub, priv} = keypair()
    payload = signed(priv, :binary.copy(<<7>>, 31), 1, "eksik anahtar")

    assert {:reply, {:error, %{reason: "bad_request"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())
  end

  test "a body larger than the 1 KB chat bucket is refused" do
    # Refused at padding time, so the signature is never even looked at.
    {pub, _priv} = keypair()

    payload = %{
      "body" => :binary.copy("a", 1500),
      "pubkey" => Message.encode64(pub),
      "sig" => Message.encode64(:binary.copy(<<1>>, 64)),
      "ctr" => 1
    }

    assert {:reply, {:error, %{reason: "too_large"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())
  end

  test "an unknown event is refused without touching the store" do
    assert {:reply, {:error, %{reason: "unknown_event"}}, _} =
             RoomChannel.handle_in("nope", %{}, socket())

    assert Store.messages(@room) == []
  end

  # --- proof of work ---------------------------------------------------------

  test "a message with no nonce is refused as bad_pow" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "is yok")
    payload = Map.delete(payload, "nonce")

    assert {:reply, {:error, %{reason: "bad_pow"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())

    assert Store.messages(@room) == []
  end

  test "a nonce that does not solve the work is refused" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "yanlis nonce")
    payload = %{payload | "nonce" => bad_nonce(payload_input(payload))}

    assert {:reply, {:error, %{reason: "bad_pow"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())

    assert Store.messages(@room) == []
  end

  test "a non-integer nonce is refused rather than crashing the channel" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "metin nonce")

    assert {:reply, {:error, %{reason: "bad_pow"}}, _} =
             RoomChannel.handle_in("msg", %{payload | "nonce" => "0"}, socket())
  end

  test "the work is bound to the signed bytes, so two messages do not share a nonce" do
    {pub, priv} = keypair()
    first = signed(priv, pub, 1, "bir")
    second = signed(priv, pub, 2, "iki")

    refute Message.pow_hash(payload_input(first)) == Message.pow_hash(payload_input(second))
  end

  # --- acceptance ------------------------------------------------------------

  test "a valid message is broadcast with author, counter and padded body" do
    Phoenix.PubSub.subscribe(Zifiri.PubSub, @room)
    {pub, priv} = keypair()

    assert {:noreply, _socket} =
             RoomChannel.handle_in("msg", signed(priv, pub, 1, "merhaba"), socket())

    assert_receive %Phoenix.Socket.Broadcast{
      topic: @room,
      event: "msg",
      payload: %{"id" => 1, "ctr" => 1, "pubkey" => pubkey, "bucket" => 256} = message
    }

    assert pubkey == Message.encode64(pub)
    assert {:ok, padded} = Message.decode64(message["body"])
    assert byte_size(padded) == 256
    assert {:ok, "merhaba"} = Body.unpad(padded)
  end

  test "a chat message writes nothing to the database" do
    before = Repo.aggregate(Listing, :count)
    {pub, priv} = keypair()

    assert {:noreply, _} =
             RoomChannel.handle_in("msg", signed(priv, pub, 1, "diske yazma"), socket())

    assert Repo.aggregate(Listing, :count) == before
  end

  # --- ring buffer, TTL, restart --------------------------------------------

  test "the buffer keeps the last 500 messages and drops the oldest" do
    for i <- 1..501 do
      key = <<i::256>>
      assert {:ok, message} = Store.submit(@room, stored(key, 1))
      assert message.id == i
    end

    messages = Store.messages(@room)
    assert length(messages) == 500
    assert hd(messages).id == 501
    assert List.last(messages).id == 2
  end

  test "messages expire after the TTL" do
    Store.reset(ttl_ms: 20)
    assert {:ok, _} = Store.submit(@room, stored(<<1::256>>, 1))
    assert [_message] = Store.messages(@room)

    Process.sleep(40)

    assert Store.messages(@room) == []
  end

  test "a restart-equivalent reset empties the buffer and rotates the epoch" do
    epoch = Store.epoch(@room)
    assert {:ok, _} = Store.submit(@room, stored(<<1::256>>, 1))

    :ok = Store.reset()

    assert Store.messages(@room) == []
    refute Store.epoch(@room) == epoch
  end

  test "a signature minted before the restart no longer verifies" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "eski epoch")

    :ok = Store.reset()

    # The work is paid again for the new epoch, so what fails is the signature
    # and nothing else: the bytes it covered were bound to the old epoch.
    assert {:reply, {:error, %{reason: "bad_signature"}}, _} =
             RoomChannel.handle_in("msg", grind(payload), socket())
  end

  # --- the counter -----------------------------------------------------------
  #
  # The replay guard is one integer per key and strictly increasing (§7.3).
  # There is no window to push a message out of: a counter that is not greater
  # than the last accepted one is a replay, however old it is.

  test "a repeated counter is a replay" do
    {pub, priv} = keypair()
    payload = signed(priv, pub, 1, "tek")

    assert {:noreply, _} = RoomChannel.handle_in("msg", payload, socket())

    assert {:reply, {:error, %{reason: "replay"}}, _} =
             RoomChannel.handle_in("msg", payload, socket())

    assert length(Store.messages(@room)) == 1
  end

  test "a lower counter than the last accepted one is a replay, not a late line" do
    {pub, priv} = keypair()

    assert {:noreply, _} = RoomChannel.handle_in("msg", signed(priv, pub, 5, "bes"), socket())

    assert {:reply, {:error, %{reason: "replay"}}, _} =
             RoomChannel.handle_in("msg", signed(priv, pub, 3, "uc"), socket())

    assert Store.messages(@room) |> Enum.map(& &1.ctr) == [5]
  end

  test "a counter below the last one is refused even after a hundred newer messages" do
    # The old window was 64 deep, so pushing 65 counters through a key made the
    # oldest replayable again. Nothing is evictable now: the check is
    # `ctr <= last_ctr`, and `last_ctr` only moves forward.
    Store.reset(rate: 1_000)
    {pub, _priv} = keypair()

    assert {:ok, _} = Store.submit(@room, stored(pub, 1))

    for ctr <- 2..101 do
      assert {:ok, _} = Store.submit(@room, stored(pub, ctr))
    end

    assert {:error, :replay} = Store.submit(@room, stored(pub, 1))
    assert {:error, :replay} = Store.submit(@room, stored(pub, 50))
    assert {:error, :replay} = Store.submit(@room, stored(pub, 101))
    assert {:ok, _} = Store.submit(@room, stored(pub, 102))
  end

  test "a busy room does not evict a live key's counter" do
    # The old design had a cap on tracked keys, so flooding with fresh keys
    # dropped a victim's window and made its last counter replayable again.
    # Per-key state is TTL-only now, so 2 000 other keys change nothing.
    Store.reset(rate: 1_000)
    victim = <<0xAA::256>>
    assert {:ok, _} = Store.submit(@room, stored(victim, 7))

    # 33-byte keys, so no flood key can collide with the victim's 32-byte one.
    for i <- 1..2_000 do
      assert {:ok, _} = Store.submit(@room, stored(<<1::8, i::256>>, 1))
    end

    assert {:error, :replay} = Store.submit(@room, stored(victim, 7))
    assert {:error, :replay} = Store.submit(@room, stored(victim, 6))
    assert {:ok, _} = Store.submit(@room, stored(victim, 8))
  end

  test "per-key counter state expires ten minutes after the key went quiet" do
    # TTL, not eviction by count: the threshold is time, and the default is ten
    # minutes. Shrunk here so the test does not sleep for one.
    Store.reset(key_ttl_ms: 30)
    {pub, _priv} = keypair()

    assert {:ok, _} = Store.submit(@room, stored(pub, 1))
    assert {:error, :replay} = Store.submit(@room, stored(pub, 1))

    Process.sleep(60)

    # Forgetting the key is exactly what the TTL is for: a client that returns
    # after a long absence starts a new run instead of being stuck forever.
    assert {:ok, _} = Store.submit(@room, stored(pub, 1))
  end

  test "the join summary is one integer per key and is the server's own state" do
    {pub_a, _} = keypair()
    {pub_b, _} = keypair()

    assert {:ok, _} = Store.submit(@room, stored(pub_a, 4))
    assert {:ok, _} = Store.submit(@room, stored(pub_a, 9))
    assert {:ok, _} = Store.submit(@room, stored(pub_b, 2))

    assert Store.last_ctrs(@room) == %{pub_a => 9, pub_b => 2}
  end

  # --- join is bounded -------------------------------------------------------

  test "join returns at most fifty messages however full the buffer is" do
    # Sixty messages from three keys: the buffer holds all sixty, the join
    # reply holds the newest fifty. (Twenty per key is the rate limit, so three
    # keys are needed to get to sixty without tripping it.)
    for ctr <- 1..20, key <- [<<1::256>>, <<2::256>>, <<3::256>>] do
      assert {:ok, _} = Store.submit(@room, stored(key, ctr))
    end

    assert length(Store.messages(@room)) == 60

    assert {:ok, reply, _socket} = RoomChannel.join(@room, %{}, socket())
    assert length(reply["messages"]) == 50
    assert hd(reply["messages"])["id"] == 60
    assert List.last(reply["messages"])["id"] == 11
  end

  test "a single message above the 4 KB ceiling is refused at the store" do
    # The channel only offers the 256 B and 1 KB buckets; the 4 KB ceiling is
    # the backstop for anything that arrives pre-padded, and the join ceiling
    # is only meaningful if a line has a maximum size.
    key = <<1::256>>

    assert {:error, :too_large} =
             Store.submit(@room, stored(key, 1, :binary.copy("x", 16_384), 16_384))

    assert {:ok, _} = Store.submit(@room, stored(key, 2, :binary.copy("x", 4096), 4096))

    assert {:error, :too_large} =
             Store.submit(@room, stored(key, 3, :binary.copy("x", 4097), 4097))
  end

  # --- rate limit ------------------------------------------------------------

  test "one key is limited to twenty messages a minute" do
    {pub, priv} = keypair()

    for ctr <- 1..20 do
      assert {:noreply, _} = RoomChannel.handle_in("msg", signed(priv, pub, ctr, "hiz"), socket())
    end

    assert {:reply, {:error, %{reason: "rate_limited"}}, _} =
             RoomChannel.handle_in("msg", signed(priv, pub, 21, "hiz"), socket())

    assert length(Store.messages(@room)) == 20
  end

  test "the limit is per key, not per room" do
    {pub_a, priv_a} = keypair()
    {pub_b, priv_b} = keypair()

    for ctr <- 1..20 do
      assert {:noreply, _} =
               RoomChannel.handle_in("msg", signed(priv_a, pub_a, ctr, "a"), socket())
    end

    assert {:noreply, _} = RoomChannel.handle_in("msg", signed(priv_b, pub_b, 1, "b"), socket())
  end
end
