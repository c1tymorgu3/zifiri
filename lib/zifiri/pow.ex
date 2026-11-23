defmodule Zifiri.Pow do
  @moduledoc """
  Proof of work, the only write gate (§4.4).

  There is no IP-based limiter anywhere in this service, so the cost of
  writing must live in the request itself. Difficulty is expressed in
  leading zero bits of `SHA-256(payload_hash || nonce)`; 20 bits is roughly
  a quarter second in a browser worker.

  Difficulty scales with the queue depth: an attacker who floods the queue
  raises the price of their own next write.
  """

  # 17 bits, not 20: measured. 20 bits took 1 839 ms median in a browser
  # (scripts/measure/pow_browser.js), five times the 250 ms the design assumed.
  # 17 bits is ~143 000 hashes, which lands at the documented quarter second on
  # this machine and about a second on a phone throttled to a quarter speed.
  @default_difficulty 17
  @max_difficulty 24

  @spec difficulty() :: non_neg_integer()
  def difficulty, do: Application.get_env(:zifiri, :pow_difficulty, @default_difficulty)

  @doc "Difficulty for the next write, given how full the queue is."
  @spec difficulty(pos_integer()) :: non_neg_integer()
  def difficulty(queued) when is_integer(queued) and queued >= 0 do
    extra = min(div(queued, 50), @max_difficulty - @default_difficulty)
    @default_difficulty + extra
  end

  @spec verify(binary(), non_neg_integer(), non_neg_integer()) :: boolean()
  def verify(payload_hash, nonce, difficulty)
      when is_binary(payload_hash) and is_integer(nonce) and nonce >= 0 and
             is_integer(difficulty) and difficulty >= 0 do
    leading_zero_bits(hash(payload_hash, nonce)) >= difficulty
  end

  def verify(_, _, _), do: false

  @doc """
  The exact message a solution covers: the challenge id and the payload hash.

  Checking a proof against `subject(id, payload_hash)` instead of against the
  payload alone is what makes a proof single-use in practice — the same nonce
  is simply a different message for any other request or any other challenge
  (see `Zifiri.Pow.Challenge`, review F-03).
  """
  @spec subject(binary(), binary()) :: binary()
  def subject(challenge_id, payload_hash)
      when is_binary(challenge_id) and is_binary(payload_hash),
      do: challenge_id <> payload_hash

  @spec solve(binary(), non_neg_integer()) :: non_neg_integer() | nil
  def solve(payload_hash, difficulty, limit \\ 50_000_000) do
    Enum.find(0..limit, fn nonce -> verify(payload_hash, nonce, difficulty) end)
  end

  defp hash(payload_hash, nonce),
    do: :crypto.hash(:sha256, <<payload_hash::binary, nonce::unsigned-64>>)

  defp leading_zero_bits(<<0::1, rest::bitstring>>), do: 1 + leading_zero_bits(rest)
  defp leading_zero_bits(_), do: 0
end
