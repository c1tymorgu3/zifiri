# The identity line: how many characters a user actually reads.
#
# The line is `Zifiri.Identity`'s: `"zifiri1"` followed by 64 uppercase base32
# characters, which is 40 bytes (seed 32 ‖ generation 1 ‖ counter 3 ‖ checksum
# 4) with no padding. 7 + 64 = 71. The prefix is 7 characters, so a length taken
# from `String.slice(line, 0, 6)` is a character short — this script prints the
# length the encoder produces, not the one a document remembers.
#
#   MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs
#   MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs --help

Code.require_file("measure_support.exs", __DIR__)

defmodule IdentityLine do
  @moduledoc false

  @help """
  identity_line.exs — the shipped identity line, character by character.

  Usage:
    MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs [options]

  Options:
    --samples N   how many lines to generate (default 3)
    --help, -h    print this text and exit

  Prints, per sample, the line `Zifiri.Identity.encode_line/3` produces, its
  length, the prefix the code uses, the base32 part, and what the same line
  would measure with the older 6-character `zifir1` prefix. The grouped length
  is this script's own 4-character
  grouping — the encoder has no display formatter — so it is reported as
  measured here, not as a claim from the docs.
  """

  def main(argv) do
    if MeasureSupport.help?(argv), do: MeasureSupport.print_help(@help)

    samples = MeasureSupport.int_arg(argv, "samples", 3)
    samples = if is_integer(samples) and samples > 0, do: samples, else: 3

    IO.puts("identity_line: #{samples} samples\n")

    for _ <- 1..samples do
      seed = :crypto.strong_rand_bytes(32)
      line = Zifiri.Identity.encode_line(seed, 1, 7)
      {prefix, base32} = String.split_at(line, 7)

      grouped =
        line |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join(" ", &Enum.join/1)

      IO.puts(line)
      IO.puts("  length           #{String.length(line)}")
      IO.puts("  prefix           #{inspect(prefix)} (#{String.length(prefix)} chars)")
      IO.puts("  base32 part      #{String.length(base32)} chars")
      IO.puts("  grouped          #{String.length(grouped)} chars (4-character groups)")
      IO.puts("  with \"zifir1\"    #{String.length("zifir1" <> base32)} chars\n")
    end

    IO.puts("prefix is \"zifiri1\" (7), base32 is 64, so the line is 71 characters.")
  end
end

IdentityLine.main(System.argv())
