defmodule Zifiri.Chat.Message do
  @moduledoc """
  What is signed, and how a stored message looks on the wire (`plan §7.3`).

  The signing input is

      "zifiri/chat/v1" <> room::len16 <> epoch::len16 <> ctr::64 <> padded_body

  Every variable-length field is length-prefixed and the counter is fixed
  width, so no two distinct `(room, epoch, ctr, body)` tuples can produce the
  same bytes. Without that separator a signature taken from one room verifies
  in another, and a signature taken from the forum write path would verify
  here.

  The server verifies and forgets who signed: it keeps the public key because
  clients re-verify the signature themselves and would otherwise have to trust
  the server not to have swapped the author (`§7.3`).

  Receiving a frame is not free either: every message carries a proof of work
  over `pow_hash/1` (`§7.4`). The hash covers the signed bytes — room, epoch,
  counter, body — so one solved nonce is good for exactly one message and cannot
  be resold to a second sender. The nonce itself is *not* inside the signature:
  it is not part of the message, and a replayed frame is caught by the counter
  before the nonce matters.
  """

  @domain "zifiri/chat/v1"
  @pow_domain "zifiri/chat/pow/v1"
  @max_ctr 18_446_744_073_709_551_616
  @pubkey_size 32
  @sig_size 64

  @doc "Bytes covered by the signature."
  @spec signing_input(binary(), binary(), non_neg_integer(), binary()) :: binary()
  def signing_input(room, epoch, ctr, padded)
      when is_binary(room) and is_binary(epoch) and is_binary(padded) and is_integer(ctr) and
             ctr >= 0 and ctr < @max_ctr do
    <<@domain::binary, byte_size(room)::16, room::binary, byte_size(epoch)::16, epoch::binary,
      ctr::64, padded::binary>>
  end

  @doc """
  The hash a client grinds, for the proof of work one message costs (`§7.4`).

  `Pow.verify(pow_hash(signing_input), nonce, 12)` is the acceptance test. The
  work is bound to the signed bytes, so it cannot be shared between messages and
  a grind done for one room never pays for another.
  """
  @spec pow_hash(binary()) :: binary()
  def pow_hash(signing_input) when is_binary(signing_input),
    do: :crypto.hash(:sha256, <<@pow_domain::binary, signing_input::binary>>)

  @doc """
  Ed25519 verification. Sizes are checked first because `:crypto` raises rather
  than returns false on a malformed key, and a raise here would be an unhandled
  crash reachable from the socket.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(pubkey, signature, msg)
      when is_binary(pubkey) and is_binary(signature) and is_binary(msg) do
    if byte_size(pubkey) == @pubkey_size and byte_size(signature) == @sig_size do
      try do
        :crypto.verify(:eddsa, :none, msg, signature, [pubkey, :ed25519])
      rescue
        _ -> false
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  def verify(_pubkey, _signature, _msg), do: false

  @doc "JSON-safe form of a stored message: binaries become URL-safe base64."
  @spec to_json(map()) :: map()
  def to_json(message) do
    %{
      "id" => message.id,
      "pubkey" => encode64(message.pubkey),
      "sig" => encode64(message.sig),
      "body" => encode64(message.body),
      "bucket" => message.bucket,
      "ctr" => message.ctr
    }
  end

  @doc "URL-safe base64 without padding — the form the client sends."
  @spec encode64(binary()) :: String.t()
  def encode64(binary) when is_binary(binary), do: Base.url_encode64(binary, padding: false)

  @doc """
  Accepts both URL-safe-unpadded and standard-padded base64, because a client
  writing `btoa()` in a hurry produces the second one and rejecting it would be
  a usability trap with no security value.
  """
  @spec decode64(term()) :: {:ok, binary()} | :error
  def decode64(string) when is_binary(string) do
    case Base.url_decode64(string, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> Base.decode64(string)
    end
  end

  def decode64(_other), do: :error
end
