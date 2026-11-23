defmodule Zifiri.PowTest do
  use ExUnit.Case, async: true

  alias Zifiri.Pow
  alias Zifiri.Pow.Challenge

  @payload :crypto.hash(:sha256, "zifiri")

  describe "verify/3" do
    test "a solved nonce verifies at its difficulty" do
      nonce = Pow.solve(@payload, 10)
      assert is_integer(nonce)
      assert Pow.verify(@payload, nonce, 10)
    end

    test "the same nonce fails at a higher difficulty than it solves" do
      nonce = Pow.solve(@payload, 8)
      assert Pow.verify(@payload, nonce, 8)
      # 18 bits above the solved value: eighths of a percent of the space.
      refute Pow.verify(@payload, nonce, 18)
    end

    test "a wrong payload does not verify a nonce solved for another" do
      nonce = Pow.solve(@payload, 10)
      refute Pow.verify(:crypto.hash(:sha256, "other"), nonce, 10)
    end

    test "difficulty 0 accepts any nonce" do
      assert Pow.verify(@payload, 0, 0)
      assert Pow.verify(@payload, 999_999, 0)
    end

    test "guards reject malformed input instead of raising" do
      refute Pow.verify("not a hash at all", 1, 10)
      refute Pow.verify(@payload, -1, 10)
      refute Pow.verify(@payload, 1, -1)
      refute Pow.verify(nil, nil, nil)
    end
  end

  describe "difficulty/1" do
    test "an empty queue costs the documented baseline, not whatever config says" do
      # 17 bits is the number the docs promise a browser grinds, and it is the
      # number a browser was measured against (docs/measurements.md). Comparing
      # `difficulty(0)` to `difficulty()` would only compare the config to
      # itself and pass even if the baseline drifted to 4 or to 40.
      assert Pow.difficulty(0) == 17
      assert Pow.difficulty(49) == 17, "one short of the first step must not move"
    end

    test "one bit per 50 queued, and the ceiling holds for any depth" do
      assert Pow.difficulty(50) == 18
      assert Pow.difficulty(99) == 18
      assert Pow.difficulty(100) == 19

      # 24 is the ceiling: seven bits above the baseline, reached at depth 350.
      assert Pow.difficulty(350) == 24
      assert Pow.difficulty(10_000) == 24
      assert Pow.difficulty(1_000_000) == 24, "no queue depth may buy a higher price"

      # The cap must not be a subtraction that can go negative.
      assert Pow.difficulty(0) < Pow.difficulty(1_000_000)
    end

    test "difficulty is monotonic, so a flood never makes writing cheaper" do
      depths = [0, 1, 49, 50, 51, 120, 400, 5_000]
      costs = Enum.map(depths, &Pow.difficulty/1)
      assert costs == Enum.sort(costs)
    end
  end

  describe "challenge/1 and redeem/5 (review F-03)" do
    setup do
      {:ok, owner: :crypto.strong_rand_bytes(32), payload: :crypto.hash(:sha256, "a post")}
    end

    test "issue hands out sixteen random bytes and the difficulty to solve", %{
      owner: owner,
      payload: payload
    } do
      assert {:ok, %{id: id, bits: bits}} = Challenge.issue(owner, payload)
      assert is_binary(id)
      assert byte_size(Base.url_decode64!(id, padding: false)) == 16
      assert bits >= Pow.difficulty()

      assert {:ok, %{id: other}} = Challenge.issue(owner, payload)
      assert other != id
    end

    test "a solved challenge redeems exactly once", %{owner: owner, payload: payload} do
      {:ok, challenge} = Challenge.issue(owner, payload, bits: 8)
      nonce = Challenge.solve(challenge, payload)

      assert :ok = Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits)

      assert {:error, :already_used} =
               Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits)
    end

    test "a wrong nonce is refused and does not spend the challenge", %{
      owner: owner,
      payload: payload
    } do
      {:ok, challenge} = Challenge.issue(owner, payload, bits: 8)
      subject = Pow.subject(challenge.id, payload)
      wrong = nonce_failing(subject, challenge.bits)

      assert {:error, :bad_pow} =
               Challenge.redeem(owner, payload, challenge.id, wrong, challenge.bits)

      nonce = Challenge.solve(challenge, payload)
      assert :ok = Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits)
    end

    test "a solution is bound to its payload", %{owner: owner, payload: payload} do
      {:ok, challenge} = Challenge.issue(owner, payload, bits: 8)
      nonce = Challenge.solve(challenge, payload)
      elsewhere = :crypto.hash(:sha256, "a different post")

      assert {:error, _reason} =
               Challenge.redeem(owner, elsewhere, challenge.id, nonce, challenge.bits)

      # The failed attempt did not consume it: the proof was for the right one.
      assert :ok = Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits)
    end

    test "a solution is bound to its challenge", %{owner: owner, payload: payload} do
      {:ok, first} = Challenge.issue(owner, payload, bits: 8)
      nonce = Challenge.solve(first, payload)
      second = challenge_not_solved_by(owner, payload, nonce, first.bits)

      assert {:error, :bad_pow} = Challenge.redeem(owner, payload, second.id, nonce, second.bits)
      assert :ok = Challenge.redeem(owner, payload, first.id, nonce, first.bits)
    end

    test "a challenge belongs to the owner it was issued to", %{owner: owner, payload: payload} do
      {:ok, challenge} = Challenge.issue(owner, payload, bits: 8)
      nonce = Challenge.solve(challenge, payload)
      stranger = :crypto.strong_rand_bytes(32)

      assert {:error, :unknown_challenge} =
               Challenge.redeem(stranger, payload, challenge.id, nonce, challenge.bits)

      assert :ok = Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits)
    end

    test "an unknown challenge id is refused", %{owner: owner, payload: payload} do
      assert {:error, :unknown_challenge} =
               Challenge.redeem(owner, payload, "not-a-challenge", 0, 0)
    end

    test "a challenge dies when its ten minutes run out", %{owner: owner, payload: payload} do
      assert {:ok, %{id: id, bits: bits}} = Challenge.issue(owner, payload, bits: 0, ttl_ms: 5)
      Process.sleep(20)

      assert {:error, :unknown_challenge} = Challenge.redeem(owner, payload, id, 0, bits)
    end

    test "a lower difficulty claim does not lower the bar", %{owner: owner, payload: payload} do
      {:ok, challenge} = Challenge.issue(owner, payload, bits: 10)
      nonce = Challenge.solve(challenge, payload)

      assert {:error, :bad_pow} =
               Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits - 1)

      # Claiming more than was issued is fine: the bar is the issued one.
      assert :ok = Challenge.redeem(owner, payload, challenge.id, nonce, challenge.bits + 2)
    end

    test "the default lifetime is ten minutes", %{owner: owner, payload: payload} do
      {:ok, %{id: id}} = Challenge.issue(owner, payload, bits: 0)
      assert expires_in(id) > 9 * 60 * 1000
      assert expires_in(id) <= 10 * 60 * 1000
    end

    test "outstanding/0 counts what is live and clear/0 forgets it", %{
      owner: owner,
      payload: payload
    } do
      Challenge.clear()
      assert Challenge.outstanding() == 0

      {:ok, challenge} = Challenge.issue(owner, payload, bits: 0)
      assert Challenge.outstanding() == 1

      assert :ok = Challenge.redeem(owner, payload, challenge.id, 1, challenge.bits)
      assert Challenge.outstanding() == 0
    end

    test "issue refuses a binding that is not a binary", %{owner: owner, payload: payload} do
      assert {:error, :bad_challenge} = Challenge.issue(owner, nil)
      assert {:error, :bad_challenge} = Challenge.issue(nil, payload)
    end

    test "the solved message is the challenge id followed by the payload hash" do
      id = "abc"
      payload = :crypto.hash(:sha256, "a post")

      assert Pow.subject(id, payload) == "abc" <> payload
      nonce = Pow.solve(Pow.subject(id, payload), 6)
      assert Pow.verify(Pow.subject(id, payload), nonce, 6)
    end
  end

  # A nonce that provably does not solve this subject, so a refusal test cannot
  # pass by accident on a one-in-256 collision.
  defp nonce_failing(subject, bits) do
    Enum.find(0..255, fn nonce -> not Pow.verify(subject, nonce, bits) end)
  end

  # A fresh challenge for the same payload that this nonce does not solve. The
  # id is random, so almost every challenge qualifies; the loop makes it certain.
  defp challenge_not_solved_by(owner, payload, nonce, bits, tries \\ 20) do
    {:ok, challenge} = Challenge.issue(owner, payload, bits: bits, ttl_ms: 60_000)

    if Pow.verify(Pow.subject(challenge.id, payload), nonce, bits) and tries > 0 do
      challenge_not_solved_by(owner, payload, nonce, bits, tries - 1)
    else
      challenge
    end
  end

  defp expires_in(id) do
    :ets.lookup_element(:zifiri_pow_challenges, id, 5) - System.system_time(:millisecond)
  end

  test "the reported difficulty is the baseline, exactly" do
    # `in 16..24` would accept a challenge four times cheaper than documented.
    assert Pow.difficulty() == 17
  end
end
