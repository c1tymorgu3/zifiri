defmodule Zifiri.Mod.Audit do
  @moduledoc """
  The moderation record: append-only, hash-chained, and honest about its limits.

  Every moderation decision is one JSON object on one line of a file
  (`config :zifiri, :moderation_log_path`). Each line carries the hash of the
  line before it, so a decision cannot be edited, reordered or removed after
  the fact without breaking every line that follows:

      {"v":2,"seq":3,"at":"…","actor":"operator","action":"hide",
       "target":"listing:…","reason":"spam","threshold":1,
       "signature":null,"prev":"<hash of line 2>","hash":"<hash of this line>"}

  `verify_chain/0` recomputes the whole chain and returns the number of lines
  that checked out, or the first line that did not and why.

  ## What this proves, and what it does not

  It proves **the record was not altered after it was written**. It does *not*
  prove **who wrote it**: there is no key here, `actor` is a string the writer
  chose, and whoever controls the file can rewrite the entire chain from the
  first line and produce a chain that verifies. Detecting that requires a copy
  of the head hash held somewhere the operator does not control. `threshold`
  and `signature` exist so that the day a threshold signature is available the
  claim can become "no single operator could have written this" — today they
  are `1` and `null`, and the chain proves no such thing.

  See `docs/spec.md` §Moderation.

  ## Versions

  `v` is the format version and it is part of the hash prefix, so a record
  cannot be downgraded to drop fields out of the hash:

    * `v: 2` — the current format, hashes `threshold` and `signature` too.
    * `v: 1` — the pre-threshold format, hashes the same fields minus those
      two. Nothing writes it; `append/2` accepts it so the promise "records
      written before the threshold fields existed still verify" is a test and
      not a comment.

  ## Appending

  `append/2` verifies the existing chain before it extends it. A broken file is
  not silently appended to: the next write fails instead, and the break stays
  where it is. This is O(n) per write, which is the right trade for a log that
  receives a handful of lines a day and must never lie about its own tail.
  """

  alias Zifiri.JSON

  @zeros String.duplicate("0", 64)

  @v1_fields ~w(seq at actor action target reason prev)
  @v2_fields ~w(seq at actor action target reason threshold signature prev)

  @default_path "/var/lib/zifiri/moderation.jsonl"
  @default_dev_path "moderation.jsonl"

  @type t :: %{required(binary()) => JSON.json()}
  @type verify_error :: {pos_integer(), atom() | tuple()}

  @doc """
  The path of the record file.

  `config :zifiri, :moderation_log_path` wins; otherwise `/var/lib/zifiri/`
  in production and a relative file elsewhere, so a workstation run cannot
  write to a root-owned directory by accident.
  """
  @spec path() :: binary()
  def path do
    case Application.get_env(:zifiri, :moderation_log_path) do
      nil -> if production?(), do: @default_path, else: @default_dev_path
      path when is_binary(path) -> path
    end
  end

  @doc """
  Appends one decision and returns the record exactly as it was written.

  Options:

    * `:version` — `2` (default) or `1`. See the module doc; `1` exists to keep
      old lines verifiable, not as a way to write new ones.
    * `:threshold` — defaults to `1`.
    * `:signature` — a binary, or `nil` (default).
    * `:at` — an ISO 8601 timestamp; defaults to now, truncated to the second.

  Returns `{:error, {line, reason}}` when the existing chain does not verify —
  the same shape as `verify_chain/0` — `{:error, {:write, reason}}` when the
  file cannot be written, and `{:error, {:bad_threshold, t}}` /
  `{:error, {:bad_signature, s}}` when the line itself would not verify. A
  record is never written that `verify_chain/0` would reject on the next read.
  """
  @spec append(map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def append(entry, opts \\ []) do
    base = normalize(entry)
    version = Keyword.get(opts, :version, 2)
    threshold = Keyword.get(opts, :threshold, Map.get(base, "threshold", 1))
    signature = Keyword.get(opts, :signature, Map.get(base, "signature"))

    with :ok <- validate(threshold, signature),
         :ok <- ensure_dir(),
         {:ok, count} <- verify_chain(),
         {:ok, prev} <- last_hash(count) do
      record =
        base
        |> Map.merge(%{
          "v" => version,
          "seq" => count + 1,
          "at" => Keyword.get_lazy(opts, :at, &now/0),
          "threshold" => threshold,
          "signature" => signature,
          "prev" => prev
        })
        # A v1 line carries no threshold or signature: writing them without
        # hashing them would be a field that looks meaningful and is not.
        |> then(&if(version == 1, do: Map.drop(&1, ["threshold", "signature"]), else: &1))
        |> then(&Map.put(&1, "hash", hash(&1)))

      case write(record) do
        :ok -> {:ok, record}
        {:error, reason} -> {:error, {:write, reason}}
      end
    end
  end

  @doc """
  All records, in file order, as JSON objects with string keys.

  This is the file, decoded — not a summary of it. A record that does not
  parse raises, because a caller that cannot see a line must not be told the
  log is fine.
  """
  @spec entries() :: [t()]
  def entries do
    path()
    |> read_lines()
    |> Enum.map(fn {_line, raw} ->
      case JSON.decode(raw) do
        {:ok, %{} = record} -> record
        _ -> raise ArgumentError, "moderation record is not a JSON object"
      end
    end)
  end

  @doc """
  Recomputes the chain from the first line to the last.

  Returns `{:ok, count}` — `{:ok, 0}` for a file that does not exist or is
  empty — or `{:error, {line, reason}}` for the first line that fails:

    * `:malformed` — not a JSON object;
    * `{:seq_mismatch, got}` — `seq` is not this line's position;
    * `{:unknown_version, v}` — `v` is neither 1 nor 2;
    * `{:broken_link, got}` — `prev` is not the previous line's `hash`;
    * `:bad_hash` — `hash` is missing or not 64 lowercase hex characters;
    * `{:bad_threshold, got}` — `threshold` is not a positive integer;
    * `:hash_mismatch` — the fields do not hash to the recorded `hash`.

  Every reason names the line, so a tampered record is a position in a file
  and not a verdict about the whole log.
  """
  @spec verify_chain() :: {:ok, non_neg_integer()} | {:error, verify_error()}
  def verify_chain do
    path()
    |> read_lines()
    |> Enum.reduce_while({:ok, @zeros, 0}, fn {line, raw}, {:ok, prev, count} ->
      case check(line, raw, prev, count + 1) do
        {:ok, hash} -> {:cont, {:ok, hash, count + 1}}
        {:error, reason} -> {:halt, {:error, {line, reason}}}
      end
    end)
    |> case do
      {:ok, _prev, count} -> {:ok, count}
      {:error, _} = error -> error
    end
  end

  @doc """
  The canonical bytes a record hashes over.

  Fixed field order, every value length-prefixed and type-tagged, version in
  the header. A third party can recompute a `hash` from the file with this
  function alone — which is the point of publishing an audit format.
  """
  @spec canonical(t()) :: binary()
  def canonical(record) do
    version = version(record)

    fields =
      case version do
        1 -> @v1_fields
        2 -> @v2_fields
      end

    body =
      Enum.map(fields, fn field ->
        value = scalar(Map.get(record, field))
        [field, ?:, Integer.to_string(byte_size(value)), ?:, value, ?\n]
      end)

    IO.iodata_to_binary(["zifiri/mod-audit/v", Integer.to_string(version), ?\n, body])
  end

  @doc """
  `sha256(canonical/1)` as 64 lowercase hex characters.
  """
  @spec hash(t()) :: binary()
  def hash(record) do
    record
    |> canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The format version of a record: `v` when present, `1` when absent.
  """
  @spec version(t()) :: 1 | 2
  def version(%{"v" => 1}), do: 1
  def version(%{"v" => 2}), do: 2
  def version(%{"v" => _other}), do: 2
  def version(%{}), do: 1

  # -- checks -----------------------------------------------------------------

  defp check(_line, raw, expected_prev, expected_seq) do
    with {:ok, record} <- decode(raw),
         :ok <- check_seq(record, expected_seq),
         :ok <- check_version(record),
         :ok <- check_link(record, expected_prev),
         :ok <- check_hash_shape(record),
         :ok <- check_threshold(record),
         :ok <- check_hash(record) do
      {:ok, record["hash"]}
    end
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = record} -> {:ok, record}
      _ -> {:error, :malformed}
    end
  end

  defp check_seq(%{"seq" => seq}, expected) when seq == expected, do: :ok
  defp check_seq(%{"seq" => seq}, _expected), do: {:error, {:seq_mismatch, seq}}
  defp check_seq(_record, _expected), do: {:error, {:seq_mismatch, nil}}

  defp check_version(%{"v" => v}) when v in [1, 2], do: :ok
  defp check_version(%{"v" => v}), do: {:error, {:unknown_version, v}}
  defp check_version(_record), do: :ok

  defp check_link(%{"prev" => prev}, expected) when prev == expected, do: :ok
  defp check_link(%{"prev" => prev}, _expected), do: {:error, {:broken_link, prev}}
  defp check_link(_record, _expected), do: {:error, :broken_link}

  defp check_hash_shape(%{"hash" => hash}) when is_binary(hash) and byte_size(hash) == 64 do
    if hash =~ ~r/\A[0-9a-f]{64}\z/, do: :ok, else: {:error, :bad_hash}
  end

  defp check_hash_shape(_record), do: {:error, :bad_hash}

  defp check_threshold(%{"v" => 2} = record) do
    case Map.get(record, "threshold") do
      n when is_integer(n) and n > 0 -> :ok
      other -> {:error, {:bad_threshold, other}}
    end
  end

  defp check_threshold(_record), do: :ok

  defp check_hash(record) do
    expected = hash(Map.delete(record, "hash"))
    if record["hash"] == expected, do: :ok, else: {:error, :hash_mismatch}
  end

  # -- file -------------------------------------------------------------------

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim_trailing(&1, "\r"))
        |> Enum.reject(&(&1 == ""))
        |> Enum.with_index(1)
        |> Enum.map(fn {raw, line} -> {line, raw} end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp last_hash(0), do: {:ok, @zeros}

  defp last_hash(_count) do
    case path() |> read_lines() |> List.last() do
      {_line, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"hash" => hash}} when is_binary(hash) -> {:ok, hash}
          _ -> {:error, :unreadable_tail}
        end

      nil ->
        {:ok, @zeros}
    end
  end

  defp write(record) do
    line = JSON.encode(record) <> "\n"

    case File.open(path(), [:append, :binary]) do
      {:ok, device} ->
        result = IO.binwrite(device, line)
        File.close(device)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_dir do
    case File.mkdir_p(Path.dirname(path())) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Refuse to write a line that verify_chain/0 would reject: a record that
  # cannot be verified the moment it is written is a record that says nothing.
  defp validate(threshold, signature) do
    cond do
      not (is_integer(threshold) and threshold > 0) -> {:error, {:bad_threshold, threshold}}
      not (is_nil(signature) or is_binary(signature)) -> {:error, {:bad_signature, signature}}
      true -> :ok
    end
  end

  defp normalize(entry) when is_list(entry), do: entry |> Map.new() |> normalize()

  defp normalize(entry) when is_map(entry) do
    Map.new(entry, fn {key, value} -> {to_string(key), value} end)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # nil, integers and binaries must not collide: a nil reason and an empty
  # reason are different decisions, so each gets its own tag before the length
  # prefix.
  defp scalar(nil), do: "n"
  defp scalar(value) when is_integer(value), do: "i" <> Integer.to_string(value)
  defp scalar(value) when is_binary(value), do: "s" <> value
  defp scalar(value) when is_atom(value), do: "s" <> Atom.to_string(value)

  defp production? do
    Application.get_env(:zifiri, :env) == :prod
  end
end
