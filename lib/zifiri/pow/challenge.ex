defmodule Zifiri.Pow.Challenge do
  @moduledoc """
  A one-shot proof-of-work challenge (plan §4.4, review F-03).

  A bare proof is a *reusable* proof: once a nonce solves
  `SHA-256(payload_hash || nonce)` at some difficulty, it keeps verifying for
  that payload forever, and a payload that repeats (the same short post, the
  same repost) makes the same proof valid again. The cost of writing then
  decays to zero for anyone who solved once.

  So the proof is not checked against the payload. It is checked against a
  *challenge* the server issued, and the challenge is consumed by the check:

      issue(owner_hash, payload_hash) -> {:ok, %{id: id, bits: bits}}
      redeem(owner_hash, payload_hash, id, nonce, bits) -> :ok | {:error, reason}

  The message a solution must cover is `id <> payload_hash` (`Pow.subject/2`),
  so a nonce solved for one request is a different message for any other
  request, and a nonce solved for one challenge is a different message for any
  other challenge.

  ## Binding

  A challenge is issued to one owner and one payload. Redeeming it with a
  different owner hash or a different payload hash finds no challenge at all —
  the mismatch is reported as `:unknown_challenge` rather than as a wrong
  proof, because a stranger holding a leaked id should learn nothing about it.

  ## Lifetime

  Each challenge is valid for `:pow_challenge_ttl_ms` (ten minutes). A redeemed
  challenge is deleted from the live table and remembered in a small
  tombstone table for the same window, so a replay is `:already_used` and not
  a mystery. Both tables are swept on a timer; nothing here grows without a
  bound.

  Everything is RAM-only and dies with the process, exactly like the publish
  queue: a challenge that outlives the server means nothing.
  """

  use GenServer

  alias Zifiri.Pow

  @table :zifiri_pow_challenges
  @used_table :zifiri_pow_challenges_used
  @ttl_ms 10 * 60 * 1000
  @sweep_ms 60_000
  @id_bytes 16

  @type id :: binary()
  @type bits :: non_neg_integer()
  @type error :: :bad_pow | :unknown_challenge | :already_used

  # -- lifecycle --------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    create(@table, [:set, :named_table, :public, read_concurrency: true])
    create(@used_table, [:set, :named_table, :public, read_concurrency: true])

    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- API --------------------------------------------------------------------

  @doc """
  Issues a challenge bound to this owner and this payload.

  `bits` is the difficulty the solution must reach. It defaults to the current
  adaptive difficulty (`Pow.difficulty/1`), so a full queue makes the next
  challenge more expensive; a caller may pin it with the `:bits` option.

  Options: `:bits`, `:ttl_ms` (tests use both).
  """
  @spec issue(binary(), binary(), keyword()) ::
          {:ok, %{id: id(), bits: bits()}} | {:error, :bad_challenge}
  def issue(owner_hash, payload_hash, opts \\ [])

  def issue(owner_hash, payload_hash, opts)
      when is_binary(owner_hash) and byte_size(owner_hash) > 0 and is_binary(payload_hash) do
    id = new_id()
    bits = Keyword.get(opts, :bits) || Pow.difficulty(Zifiri.Bucket.size())
    expires_at = now_ms() + Keyword.get(opts, :ttl_ms, ttl_ms())

    true = :ets.insert(@table, {id, owner_hash, payload_hash, bits, expires_at})

    {:ok, %{id: id, bits: bits}}
  end

  def issue(_owner_hash, _payload_hash, _opts), do: {:error, :bad_challenge}

  @doc """
  Spends a challenge.

  `:ok` only when the nonce covers `Pow.subject(id, payload_hash)` at the
  difficulty the challenge was issued with, the challenge belongs to this owner
  and payload, it has not expired, and it has not been spent before.

  A wrong nonce leaves the challenge in place — a browser can retry a bad
  submission without asking for a new one. A successful redemption consumes it:
  the same challenge id can never be redeemed twice.
  """
  @spec redeem(binary(), binary(), id(), non_neg_integer(), bits()) :: :ok | {:error, error()}
  def redeem(owner_hash, payload_hash, challenge_id, nonce, bits) do
    GenServer.call(
      __MODULE__,
      {:redeem, owner_hash, payload_hash, challenge_id, nonce, bits},
      :infinity
    )
  end

  @doc """
  The nonce that redeems `challenge` for `payload_hash`, or `nil` if the search
  limit is hit. This is what a client does; tests and the browser worker share
  it so there is only one definition of "solved".
  """
  @spec solve(%{id: id(), bits: bits()}, binary()) :: non_neg_integer() | nil
  def solve(%{id: id, bits: bits}, payload_hash) when is_binary(payload_hash) do
    Pow.solve(Pow.subject(id, payload_hash), bits)
  end

  @doc "Number of live (unredeemed) challenges. Tests and operators only."
  @spec outstanding() :: non_neg_integer()
  def outstanding, do: table_size(@table)

  @doc "Forgets every live and spent challenge. Only a test or a wipe uses this."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # -- server ----------------------------------------------------------------

  @impl true
  def handle_call({:redeem, owner_hash, payload_hash, id, nonce, bits}, _from, state) do
    {:reply, check(owner_hash, payload_hash, id, nonce, bits), state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@used_table)
    {:reply, :ok, state}
  end

  defp check(owner_hash, payload_hash, id, nonce, bits) do
    case :ets.lookup(@table, id) do
      [{^id, ^owner_hash, ^payload_hash, issued_bits, expires_at}] ->
        cond do
          expired?(expires_at) ->
            :ets.delete(@table, id)
            {:error, :unknown_challenge}

          not is_integer(bits) or bits < issued_bits ->
            {:error, :bad_pow}

          not Pow.verify(Pow.subject(id, payload_hash), nonce, issued_bits) ->
            {:error, :bad_pow}

          true ->
            :ets.delete(@table, id)
            :ets.insert(@used_table, {id, now_ms() + ttl_ms()})
            :ok
        end

      [] ->
        if :ets.member(@used_table, id),
          do: {:error, :already_used},
          else: {:error, :unknown_challenge}

      # A challenge with this id exists but not for this owner and payload.
      [_someone_elses] ->
        {:error, :unknown_challenge}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp new_id, do: :crypto.strong_rand_bytes(@id_bytes) |> Base.url_encode64(padding: false)

  defp expired?(expires_at), do: now_ms() >= expires_at

  defp sweep do
    now = now_ms()

    :ets.select_delete(@table, [
      {{:_, :_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])

    :ets.select_delete(@used_table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ok
  end

  defp create(table, opts) do
    case :ets.info(table, :size) do
      :undefined -> :ets.new(table, opts)
      _ -> table
    end
  end

  defp table_size(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  defp ttl_ms, do: Application.get_env(:zifiri, :pow_challenge_ttl_ms, @ttl_ms)

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)

  @doc false
  def now_ms, do: System.system_time(:millisecond)
end
