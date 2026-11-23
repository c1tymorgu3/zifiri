defmodule Zifiri.LogFormatter do
  @moduledoc """
  Formatter for the single production sink. It prints exactly one shape:

      <iso8601 utc> <level> <class> <module>:<function>/<arity>

  and nothing else. No message text, no metadata values, no request fields.
  That is plan §5.1's "error records reduced to {exception class, module,
  line}" taken literally: the formatter is the last place where a leak could
  happen, so it is written as an allowlist rather than a template.

  Every field is sanitised to `[A-Za-z0-9_.:/]` and truncated, so a term that
  somehow reached the formatter still cannot carry a payload out.
  """

  @max_field 64

  @doc """
  `:logger` formatter callback.
  """
  @spec format(:logger.log_event(), term()) :: iodata()
  def format(%{level: level, msg: msg, meta: meta}, _config) do
    [
      timestamp(meta),
      ?\s,
      level(level),
      ?\s,
      classify(msg),
      ?\s,
      mfa(meta),
      ?\n
    ]
  end

  defp timestamp(%{time: micros}) when is_integer(micros) do
    case DateTime.from_unix(micros, :microsecond) do
      {:ok, dt} -> dt |> DateTime.to_iso8601() |> sanitize()
      _ -> "-"
    end
  end

  defp timestamp(_meta), do: "-"

  defp level(level) when is_atom(level), do: level |> Atom.to_string() |> sanitize()
  defp level(_level), do: "-"

  defp classify({:report, %{class: class}}), do: field(class)
  defp classify({:report, %{error: %{class: class}}}), do: field(class)
  defp classify({:report, %{reason: reason}}), do: classify_reason(reason)
  defp classify(_msg), do: "-"

  defp classify_reason(%{__exception__: true, __struct__: module}), do: field(module)
  defp classify_reason({reason, stack}) when is_list(stack), do: classify_reason(reason)
  defp classify_reason(_reason), do: "-"

  defp mfa(%{mfa: {module, fun, arity}})
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    sanitize("#{inspect(module)}.#{fun}/#{arity}")
  end

  defp mfa(_meta), do: "-"

  defp field(value) when is_atom(value), do: value |> Atom.to_string() |> sanitize()
  defp field(value) when is_binary(value), do: sanitize(value)
  defp field(_value), do: "-"

  defp sanitize(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_.:\/-]/, "_")
    |> String.slice(0, @max_field)
  end
end
