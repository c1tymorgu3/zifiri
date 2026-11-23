defmodule Zifiri.ModTest do
  use ExUnit.Case, async: false

  alias Zifiri.JSON
  alias Zifiri.Mod
  alias Zifiri.Mod.Audit

  # Every test writes its own file. The chain is the subject, so a shared log
  # would let one test's leftovers be another test's evidence.
  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "zifiri-mod-#{System.unique_integer([:positive, :monotonic])}.jsonl"
      )

    previous = Application.get_env(:zifiri, :moderation_log_path)
    Application.put_env(:zifiri, :moderation_log_path, path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zifiri, :moderation_log_path, previous),
        else: Application.delete_env(:zifiri, :moderation_log_path)

      File.rm(path)
    end)

    {:ok, path: path}
  end

  # -- reading the file as a third party would ---------------------------------

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.reject(&(&1 == ""))

  defp records(path), do: path |> lines() |> Enum.map(&elem(JSON.decode(&1), 1))

  defp rewrite(path, fun) do
    contents = path |> lines() |> Enum.map_join("\n", fun)
    File.write!(path, contents <> "\n")
  end

  # -- the shape of a record ---------------------------------------------------

  test "a missing file verifies as an empty chain", %{path: path} do
    refute File.exists?(path)
    assert {:ok, 0} = Audit.verify_chain()
  end

  test "a record carries threshold 1 and an empty signature" do
    assert {:ok, record} = Mod.record(:hide, "listing:abc", reason: "spam")

    assert record["threshold"] == 1
    assert record["signature"] == nil
    assert record["v"] == 2
    assert record["seq"] == 1
    assert record["actor"] == "operator"
    assert record["action"] == "hide"
    assert record["reason"] == "spam"

    # The first line links to the zero hash, not to nothing.
    assert record["prev"] == String.duplicate("0", 64)
    assert record["hash"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Mod.threshold() == 1
    assert Mod.moderator() == "operator"
  end

  test "the record on disk is the record that was returned", %{path: path} do
    {:ok, record} = Mod.record(:restore, "listing:abc", reason: "appeal upheld")

    assert [on_disk] = records(path)
    assert on_disk == record
    assert Mod.history() == [record]
  end

  # -- the chain ---------------------------------------------------------------

  test "three decisions link to each other and verify" do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    {:ok, _} = Mod.record(:hide, "listing:b", reason: "spam")
    {:ok, _} = Mod.record(:restore, "listing:a", reason: "appeal upheld")

    assert [first, second, third] = Mod.history()
    assert Enum.map([first, second, third], & &1["seq"]) == [1, 2, 3]

    assert second["prev"] == first["hash"]
    assert third["prev"] == second["hash"]
    refute first["hash"] == second["hash"]

    assert {:ok, 3} = Audit.verify_chain()
    assert {:ok, 3} = Mod.verify()
  end

  test "concurrent writers produce a chain with no gaps", %{path: path} do
    # Two writers that both verify and both append `seq: n + 1` would write a
    # broken chain while working perfectly. The single writer is what stops it.
    results =
      1..25
      |> Enum.map(fn i ->
        Task.async(fn -> Mod.record(:hide, "listing:#{i}", reason: "spam") end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, 25} = Audit.verify_chain()
    assert Enum.map(Mod.history(), & &1["seq"]) == Enum.to_list(1..25)
    assert length(lines(path)) == 25
  end

  test "the hash is recomputable from the file alone", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")

    [record] = records(path)
    assert Audit.hash(Map.delete(record, "hash")) == record["hash"]
    assert Audit.canonical(record) =~ "zifiri/mod-audit/v2\n"
  end

  # -- tampering ---------------------------------------------------------------

  test "editing a decision in place is detected at that line", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    {:ok, _} = Mod.record(:hide, "listing:b", reason: "spam")

    # The operator's favourite move: keep the shape, change the verdict.
    rewrite(path, fn line ->
      if line =~ "listing:a",
        do: String.replace(line, ~s("reason":"spam"), ~s("reason":"no reason given")),
        else: line
    end)

    assert {:error, {1, :hash_mismatch}} = Audit.verify_chain()
  end

  test "flipping the action of the last line is detected", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    {:ok, _} = Mod.record(:restore, "listing:a", reason: "appeal upheld")

    rewrite(path, fn line ->
      String.replace(line, ~s("action":"restore"), ~s("action":"hide"))
    end)

    assert {:error, {2, :hash_mismatch}} = Audit.verify_chain()
  end

  test "deleting a decision leaves the sequence and the link broken", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    {:ok, _} = Mod.record(:hide, "listing:b", reason: "spam")
    {:ok, _} = Mod.record(:hide, "listing:c", reason: "spam")

    [first, _second, third] = lines(path)
    File.write!(path, Enum.join([first, third], "\n") <> "\n")

    # Line 2 is now the old line 3: its seq says 3, its position says 2.
    assert {:error, {2, {:seq_mismatch, 3}}} = Audit.verify_chain()
  end

  test "reordering decisions breaks the link", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    {:ok, _} = Mod.record(:hide, "listing:b", reason: "spam")

    [first, second] = lines(path)
    File.write!(path, Enum.join([second, first], "\n") <> "\n")

    assert {:error, {1, {:seq_mismatch, 2}}} = Audit.verify_chain()
  end

  test "a malformed line is named, not skipped", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")
    File.write!(path, "not json at all\n", [:append])

    assert {:error, {2, :malformed}} = Audit.verify_chain()
  end

  test "appending refuses to extend a broken chain", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")

    rewrite(path, fn line -> String.replace(line, ~s("spam"), ~s("spam ")) end)
    before = File.read!(path)

    assert {:error, {1, :hash_mismatch}} = Mod.record(:hide, "listing:b", reason: "spam")
    assert File.read!(path) == before
  end

  # -- threshold and signature are inside the hash ------------------------------

  test "changing threshold alone breaks the hash", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")

    rewrite(path, fn line -> String.replace(line, ~s("threshold":1), ~s("threshold":2)) end)

    assert {:error, {1, :hash_mismatch}} = Audit.verify_chain()
  end

  test "threshold and signature are part of the hashed payload" do
    {:ok, one} = Mod.record(:hide, "listing:a", reason: "spam", threshold: 1)
    {:ok, two} = Mod.record(:hide, "listing:a", reason: "spam", threshold: 2)
    {:ok, three} = Mod.record(:hide, "listing:a", reason: "spam", signature: "sig")

    refute one["hash"] == two["hash"]
    refute two["hash"] == three["hash"]
    assert three["signature"] == "sig"

    # Same fields, same canonical bytes, same hash — the digest is not salted
    # by position or by time.
    assert Audit.canonical(Map.put(one, "hash", "ignored")) ==
             Audit.canonical(Map.put(one, "hash", "other"))

    assert {:ok, 3} = Audit.verify_chain()
  end

  test "a record that could not verify is refused before it is written", %{path: path} do
    assert {:error, {:bad_threshold, 0}} =
             Mod.record(:hide, "listing:a", reason: "spam", threshold: 0)

    assert {:error, {:bad_signature, :not_a_binary}} =
             Mod.record(:hide, "listing:a", reason: "spam", signature: :not_a_binary)

    refute File.exists?(path)
  end

  test "a non-integer threshold is refused", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")

    rewrite(path, fn line -> String.replace(line, ~s("threshold":1), ~s("threshold":"1")) end)

    assert {:error, {1, {:bad_threshold, "1"}}} = Audit.verify_chain()
  end

  # -- old records stay valid ---------------------------------------------------

  test "a record written before threshold existed still verifies" do
    # v1 is the format the log used before `threshold`/`signature` existed. It
    # is written here on purpose: the promise is that those lines stay valid
    # after the fields were added, and a promise without a test is a comment.
    assert {:ok, legacy} =
             Audit.append(
               %{
                 "actor" => "operator",
                 "action" => "hide",
                 "target" => "listing:a",
                 "reason" => "spam"
               },
               version: 1,
               at: "2026-01-01T00:00:00Z"
             )

    assert legacy["v"] == 1
    refute Map.has_key?(legacy, "threshold")
    refute Map.has_key?(legacy, "signature")
    assert legacy["prev"] == String.duplicate("0", 64)

    # A v2 record appended after it links to the v1 hash.
    {:ok, current} = Mod.record(:hide, "listing:b", reason: "spam")
    assert current["prev"] == legacy["hash"]
    assert current["threshold"] == 1

    assert {:ok, 2} = Audit.verify_chain()
  end

  test "a v2 record cannot be downgraded to v1 to drop fields out of the hash", %{path: path} do
    {:ok, _} = Mod.record(:hide, "listing:a", reason: "spam")

    rewrite(path, fn line ->
      line |> String.replace(~s("v":2), ~s("v":1)) |> String.replace(~s("threshold":1,), "")
    end)

    assert {:error, {1, :hash_mismatch}} = Audit.verify_chain()
  end
end
