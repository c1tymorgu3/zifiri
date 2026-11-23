defmodule Zifiri.Chat.Body do
  @moduledoc """
  Chat payloads travel in the write path's envelope, restricted to the two
  smallest buckets (`plan §7.1`, `§4.1`).

  `Zifiri.Envelope` owns the frame: a 32-bit big-endian length, the body, zero
  padding, exactly one bucket long. Chat uses 256 B and 1 KB and nothing else —
  a chat line has no business claiming a 4 KB or 16 KB slot, and a room that
  accepted one would let a single message stand out by size.

  Four kilobytes is the absolute ceiling, not a size chat offers: `Store` refuses
  any padded body larger than 4096 B even if it arrives pre-padded, so the limit
  survives a future bucket being added here. Fifty lines per `join` at 4 KB is
  the worst case the read path can ever be asked to produce (`§7.1`).

  `pad/1` is idempotent: a client that already ran the body through the envelope
  sends the same bytes a client that did not would produce, which matters
  because the signature covers the padded form (§7.3).

  The server does not decode the envelope after the signature check. It never
  needs the plaintext back; the only party that does is a client rendering a
  message, and it already knows how.
  """

  alias Zifiri.Envelope

  @buckets [256, 1024]

  @type bucket :: 256 | 1024

  @doc "Pads a raw body into the smallest chat bucket that holds it."
  @spec pad(binary()) :: {:ok, binary()} | {:error, :too_large}
  def pad(body) when is_binary(body) do
    case Envelope.decode(body) do
      # Already an envelope: accept it only if it took a bucket chat uses, so a
      # 4 KB frame cannot smuggle itself in by arriving pre-padded.
      {:ok, _payload, bucket} when bucket in @buckets -> {:ok, body}
      {:ok, _payload, _bucket} -> {:error, :too_large}
      {:error, _reason} -> encode(body)
    end
  end

  @doc "Strips a chat frame back to its body. For clients and tests."
  @spec unpad(binary()) :: {:ok, binary()} | {:error, :bad_frame}
  def unpad(frame) when is_binary(frame) do
    case Envelope.decode(frame) do
      {:ok, payload, bucket} when bucket in @buckets -> {:ok, payload}
      _other -> {:error, :bad_frame}
    end
  end

  @doc "The frame's bucket, or `nil` if the binary is not a chat frame."
  @spec bucket(binary()) :: bucket() | nil
  def bucket(frame) when is_binary(frame) do
    case Envelope.decode(frame) do
      {:ok, _payload, bucket} when bucket in @buckets -> bucket
      _other -> nil
    end
  end

  @doc "The two sizes chat accepts, smallest first."
  @spec buckets() :: [bucket()]
  def buckets, do: @buckets

  defp encode(body) do
    case Envelope.encode(body) do
      {:ok, padded, bucket} when bucket in @buckets -> {:ok, padded}
      {:ok, _padded, _bucket} -> {:error, :too_large}
      {:error, :too_large} -> {:error, :too_large}
    end
  end
end
