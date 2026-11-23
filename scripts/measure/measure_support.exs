# Shared helpers for the `scripts/measure/*` scripts.
#
# These scripts exist to produce the numbers in `docs/measurements.md`. They
# are deliberately small: the HTTP client, the statistics, and the test-database
# boot already live in `scripts/load/load_support.exs`, and a second copy of
# that code would be a second definition of what "publish latency" means.
#
# Only the measurement-specific parts live here: argument parsing (so every
# script answers `--help`), the on-disk byte scan used by the erase proof, and
# the JSON report writer.
defmodule MeasureSupport do
  @moduledoc false

  @doc "True when the caller asked for `--help` / `-h`."
  @spec help?([String.t()]) :: boolean()
  def help?(argv), do: Enum.any?(argv, &(&1 in ["--help", "-h"]))

  @doc """
  Reads `--name value` or `--name=value` from argv; `nil` when absent.

  Returns the value as a string. Scripts cast with `int_arg/3` or use it raw.
  """
  @spec arg([String.t()], String.t()) :: String.t() | nil
  def arg(argv, name) do
    flag = "--" <> name

    case Enum.find_index(argv, &(&1 == flag or String.starts_with?(&1, flag <> "="))) do
      nil ->
        nil

      index ->
        token = Enum.at(argv, index)

        if String.contains?(token, "=") do
          token |> String.split("=", parts: 2) |> List.last()
        else
          Enum.at(argv, index + 1)
        end
    end
  end

  @doc "Integer argument with a default; a malformed value keeps the default."
  @spec int_arg([String.t()], String.t(), integer()) :: integer()
  def int_arg(argv, name, default) do
    case arg(argv, name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> default
        end
    end
  end

  @doc "Prints `text` and exits 0 — the shape every `--help` in this folder uses."
  @spec print_help(String.t()) :: no_return()
  def print_help(text) do
    IO.puts(text)
    System.halt(0)
  end

  @doc """
  Counts non-overlapping occurrences of `needle` in the file at `path`.

  A missing file counts as 0: after a truncating checkpoint SQLite deletes the
  `-wal`, and "the WAL does not contain the canary" has to be true when the WAL
  is not there at all. Reading the whole file is fine — the measurement
  database is a few megabytes.
  """
  @spec count_in_file(Path.t(), binary()) :: non_neg_integer()
  def count_in_file(path, needle) when is_binary(needle) and byte_size(needle) > 0 do
    case File.read(path) do
      {:ok, bytes} -> length(:binary.matches(bytes, needle))
      {:error, _reason} -> 0
    end
  end

  @doc """
  Counts non-overlapping occurrences of `needle` in an already-read binary.

  The scan in `erase_latency.exs` reads the database and the `-wal` once per
  pass and then searches all canaries in those two buffers; reading a 5 MB file
  fifty times would make the scanner, not the erase, the thing being measured.
  """
  @spec count_in_binary(binary(), binary()) :: non_neg_integer()
  def count_in_binary(bytes, needle)
      when is_binary(bytes) and is_binary(needle) and
             byte_size(needle) > 0 do
    length(:binary.matches(bytes, needle))
  end

  @doc "File size in bytes; 0 when the file does not exist."
  @spec file_size(Path.t()) :: non_neg_integer()
  def file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  @doc """
  Writes `report` as JSON under `scripts/measure/results/` and returns the path.

  Kept separate from `LoadSupport.write_report/1` so a measurement run never
  leaves an artifact in `scripts/load/results/` — the two folders answer
  different questions.
  """
  @spec write_report(map()) :: Path.t()
  def write_report(report) do
    dir = Path.expand("results", __DIR__)
    File.mkdir_p!(dir)

    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9T]/, "")

    path = Path.join(dir, "#{report["kind"]}-#{stamp}.json")
    File.write!(path, IO.iodata_to_binary(:json.encode(report)) <> "\n")
    path
  end

  @doc "Wall clock in milliseconds — the unit every latency in these scripts uses."
  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  @doc "A canary that is unique per call and cannot occur by chance in a page."
  @spec canary() :: String.t()
  def canary, do: "CANARY-" <> Base.encode16(:crypto.strong_rand_bytes(12))

  @doc "Prints the verdict line and returns the boolean."
  @spec verdict(String.t(), boolean()) :: boolean()
  def verdict(label, passed?) do
    IO.puts("\n#{label}: #{if passed?, do: "GEÇTİ (PASS)", else: "KALDI (FAIL)"}")
    passed?
  end
end
