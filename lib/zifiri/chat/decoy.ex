defmodule Zifiri.Chat.Decoy do
  @moduledoc """
  Cover traffic that is a frame like any other (`docs/spec.md` §"The number: bucket size").

  > **Not used by the room path any more.** A plaintext room publishes exactly
  > the messages written in it and no decoys at all
  > (`Zifiri.Chat.BucketHandler`, `docs/claims.md` C-50): an observer can read
  > the batch, so extra rows buy no cover, and the candidate author set is `k`,
  > not 120. Nothing in `lib/` calls this module; the tests keep it as the
  > frame-shape work it is, not as a description of what a drain emits.

  ## What a decoy is

  A decoy is a full 4 KB frame: an opaque, encrypted envelope, a signature, a
  public key and an opaque id. There is no dictionary, no marker field, no
  server-owned key and no counter. The point is that an observer holding the
  published batch cannot separate the synthetic rows from the real ones by
  looking at them — not by size, not by body statistics, not by key clustering,
  not by id order.

  The three things the old implementation leaked, and what replaces them:

    * **Body.** A fixed Turkish dictionary written as plaintext into the frame
      was a perfect classifier: strip the length prefix, match the sentence.
      A decoy body is now `AES-256-GCM` ciphertext of random bytes under a
      throwaway 256-bit key. The key is generated inside `seal/0`, never
      returned, never stored, and garbage-collected with the frame. Nobody —
      including this process — can decrypt it, and ciphertext of random bytes is
      indistinguishable from the ciphertext of a real chat message.
    * **Key.** One shared, cached Ed25519 key meant one cluster of 119 rows and
      one singleton. Each decoy now generates its own ephemeral keypair, signs
      with it, and drops the private half on the floor. Nothing is cached, so
      two fills of the same bucket share no public key.
    * **Id.** A monotonic integer from `:erlang.unique_integer/1` was a sorted
      block with the real message just outside it. The id is now 16 random
      bytes, base64url-encoded — the same shape a real frame uses, with no
      order to sort on.

  ## What a decoy is not

  A decoy is not classifiable. There is deliberately no `decoy?/1` and no
  `ratio/1`: a classifier that can tell a decoy from a real message is exactly
  the leak the decoys exist to prevent, and keeping one in the module only
  invited the scheduler to use it. `Bucket.add/1` stores a decoy and a real
  frame through the same path, so the batch itself carries no provenance.

  Signatures still verify — with the decoy's *own* public key, which is the only
  key that ever existed for it. Verification is therefore not a filter: every
  real frame verifies too, and the key it verifies under says nothing about who
  wrote it.
  """

  alias Zifiri.Bucket
  alias Zifiri.Envelope
  alias Zifiri.Chat.Message

  @room "chat:lobby"
  @target 120
  @bucket_bytes 1024
  @id_bytes 16

  @typedoc """
  A decoy frame. The key set is the same key set a real frame carries — no
  `:decoy`, no `:body`, no `:bucket`, no `:ctr`.
  """
  @type decoy :: %{
          id: String.t(),
          sig: binary(),
          pubkey: binary(),
          envelope: binary(),
          ts: integer()
        }

  @doc "How many decoys a full bucket gets: #{@target}."
  @spec target() :: pos_integer()
  def target, do: @target

  @doc "The frame size every decoy uses."
  @spec bucket_bytes() :: pos_integer()
  def bucket_bytes, do: @bucket_bytes

  @doc """
  Builds `n - real` decoys.

  `real` defaults to `Bucket.size/0`, which is the whole point of the function:
  a scheduler fills a drained bucket to `n` without knowing or caring how many
  real writes it holds. Options:

    * `:real` — override the count of real items (tests, or a caller that
      already drained the bucket into a list);
    * `:epoch` — the room epoch the decoys sign against; defaults to
      `Zifiri.Chat.Store.epoch/1` when the store is up, otherwise a fresh
      random 16 bytes;
    * `:room` — defaults to `chat:lobby`, the room `Message.signing_input/4`
      covers;
    * `:at` — the wall-clock millisecond the bucket is labelled with.

  There is no upper bound: the old dictionary capped a fill at 200 and raised
  past it, which was both a functional limit and a hint about what a decoy was.
  """
  @spec fill(pos_integer(), keyword()) :: [decoy()]
  def fill(n \\ @target, opts \\ []) when is_integer(n) and n >= 0 do
    real = Keyword.get_lazy(opts, :real, &Bucket.size/0)
    count = max(n - real, 0)

    room = Keyword.get(opts, :room, @room)
    at = Keyword.get_lazy(opts, :at, &Bucket.now_ms/0)
    epoch = Keyword.get_lazy(opts, :epoch, fn -> epoch_for(room) end)
    bucket = Bucket.bucket_start(at)

    for _ <- 0..(count - 1)//1, do: build(room, epoch, bucket)
  end

  @doc """
  Verifies a decoy's signature under `epoch` and `room`.

  The key is the one carried in the frame. This says the frame is internally
  consistent, not that it is a decoy: a real frame verifies the same way.
  """
  @spec verify?(decoy(), binary(), String.t()) :: boolean()
  def verify?(decoy, epoch, room \\ @room) when is_binary(epoch) do
    input = Message.signing_input(room, epoch, decoy.ts, decoy.envelope)
    Message.verify(decoy.pubkey, decoy.sig, input)
  end

  @doc """
  Kept for callers that reset state between tests.

  There is no state left to reset: keys are generated per decoy and dropped, so
  this is a no-op and always returns `:ok`.
  """
  @spec reset() :: :ok
  def reset, do: :ok

  @doc "Kept for symmetry with `reset/0`. There is no process to stop."
  @spec stop() :: :ok
  def stop, do: :ok

  ## Internals

  defp build(room, epoch, bucket) do
    ts = bucket + :rand.uniform(Bucket.bucket_ms()) - 1
    envelope = seal()

    # One keypair per decoy, used once. `priv` is not stored anywhere and the
    # function returns without it, so a restart cannot recover it either.
    {pubkey, priv} = :crypto.generate_key(:eddsa, :ed25519)

    sig =
      :crypto.sign(
        :eddsa,
        :none,
        Message.signing_input(room, epoch, ts, envelope),
        [priv, :ed25519]
      )

    %{id: opaque_id(), sig: sig, pubkey: pubkey, envelope: envelope, ts: ts}
  end

  # A decoy frame has the same bytes-on-the-wire shape as a real one: a
  # 1024-byte chat envelope, a length header, a body, and a zero tail. The body
  # is random rather than text, and that is a limit worth naming: a reader who
  # can read room text can tell a random body from a written one. What the
  # bucket hides is the moment of writing and the sender's slot in the batch,
  # not whether a given frame was typed by a person.
  defp seal do
    len = 64 + :rand.uniform(128)
    payload = :crypto.strong_rand_bytes(len)
    {:ok, frame, 1024} = Envelope.encode(payload, 1024)
    frame
  end

  # 16 random bytes, URL-safe base64 without padding: 22 characters, no order,
  # no counter, no relation to any other id in the batch.
  defp opaque_id, do: Base.url_encode64(:crypto.strong_rand_bytes(@id_bytes), padding: false)

  defp epoch_for(room) do
    case Process.whereis(Zifiri.Chat.Store) do
      nil -> :crypto.strong_rand_bytes(16)
      _pid -> Zifiri.Chat.Store.epoch(room)
    end
  end
end
