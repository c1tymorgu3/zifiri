defmodule Zifiri.LogFilter do
  @moduledoc """
  A primary `:logger` filter: it runs before *any* handler, so every sink in
  the system sees the scrubbed record, including the error file.

  Three things happen here, and they are the whole of plan §5.1's Phoenix and
  Ecto rows in code:

    1. Debug and info records are dropped outright. A request line, a query
       plan, a "handled in 3ms" note are all info; none of them may exist.
    2. The metadata map is reduced to an allowlist. Everything a plug or an
       adapter might attach — the conn, params, a request id, a peer, a body
       fragment — is a key that is not on the list, so it is gone before a
       formatter can see it.
    3. Report-shaped messages (crash reports, `Logger.error(%{...})`) are
       rewritten into `%{zifiri: :redacted, class: ...}`. A crash report's
       payload is an arbitrary term and often contains the conn that blew up.

  String messages are left alone: they are written by this code base, and this
  code base never writes one containing request data (there is no such value
  to write — see `Zifiri.Transport`).
  """

  @filter_id :zifiri_scrub

  # Only keys whose values cannot carry request data.
  @keep_meta [
    :time,
    :mfa,
    :line,
    :file,
    :gl,
    :domain,
    :application,
    :module,
    :function
  ]

  @doc """
  Installs (or re-installs) the filter. Called once at boot.
  """
  @spec install() :: :ok
  def install do
    _ = :logger.remove_primary_filter(@filter_id)
    :ok = :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, @filter_id})
  end

  @doc """
  The `:logger` primary filter callback.

  A filter returns the (possibly rewritten) event, `:stop` to drop it, or
  `:ignore` to pass it through untouched. Returning `{:ok, event}` here is a
  crash — `:logger` treats an unrecognised value as a failing filter and lets
  the original event through, which is the opposite of what this module is for.
  """
  @spec filter(:logger.log_event(), term()) :: :stop | :logger.log_event()
  def filter(%{level: level}, _extra) when level in [:debug, :info], do: :stop

  def filter(%{meta: meta, msg: msg} = event, _extra) when is_map(meta) do
    %{event | meta: Map.take(meta, @keep_meta), msg: scrub(msg)}
  end

  # A record we cannot reason about is a record we drop.
  def filter(_event, _extra), do: :stop

  defp scrub({:report, report}) when is_map(report) do
    {:report, %{zifiri: :redacted, class: class_of(report)}}
  end

  defp scrub({:report, _other}), do: {:report, %{zifiri: :redacted, class: :unknown}}
  defp scrub({:format, _args}), do: {:report, %{zifiri: :redacted, class: :format}}
  defp scrub({:string, _chardata} = msg), do: msg
  defp scrub(_msg), do: {:report, %{zifiri: :redacted, class: :unknown}}

  defp class_of(%{class: class}) when is_atom(class) and not is_nil(class), do: class
  defp class_of(%{reason: reason}), do: reason_class(reason)
  defp class_of(_report), do: :unknown

  # An exception is reported by module name only. Its message field is user
  # data, so it is never carried forward.
  defp reason_class(%{__exception__: true} = exception), do: exception.__struct__

  defp reason_class({reason, stacktrace}) when is_list(stacktrace), do: reason_class(reason)
  defp reason_class(reason), do: type_of(reason)

  defp type_of(term) do
    cond do
      is_atom(term) -> :atom
      is_binary(term) -> :binary
      is_integer(term) -> :integer
      is_float(term) -> :float
      is_list(term) -> :list
      is_tuple(term) -> :tuple
      is_map(term) -> :map
      is_pid(term) -> :pid
      true -> :unknown
    end
  end
end
