defmodule Zifiri.ErrorLog do
  @moduledoc """
  The only log sink production is allowed to have (plan §5.1).

  A `:logger_std_h` handler at `:error` level writing to
  `/var/lib/zifiri/err.log` (override with `ZIFIRI_ERR_LOG`), rotated over a
  1 MiB ring, formatted by `Zifiri.LogFormatter` — level, class, module, line.
  The file answers "something crashed" without answering "who, with what
  body": the write path is identity-blind, and nothing that reached the
  handler carried a request value in the first place (`Zifiri.LogFilter`).

  It is installed only when `config :zifiri, :error_log` is set, which
  `config/runtime.exs` does for `:prod` only. In dev and test there is no sink
  at all beyond the console.
  """

  @handler_id :zifiri_error_log

  @doc """
  Installs the sink when configured; a no-op otherwise.
  """
  @spec install() :: :ok | {:error, term()}
  def install do
    case Application.get_env(:zifiri, :error_log) do
      nil -> :ok
      opts -> install(opts)
    end
  end

  @doc """
  Installs the sink with explicit options. Used by `install/0` and by the test
  that proves the written file cannot contain a request value.
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts) do
    path = Keyword.fetch!(opts, :path)

    with :ok <- mkdir(path),
         :ok <- :logger.add_handler(@handler_id, :logger_std_h, handler_config(path, opts)) do
      :ok
    end
  end

  @doc """
  Detaches the sink. Safe to call when it is not attached.
  """
  @spec uninstall() :: :ok
  def uninstall do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  defp mkdir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, Path.dirname(path), reason}}
    end
  end

  defp handler_config(path, opts) do
    %{
      level: Keyword.get(opts, :level, :error),
      formatter: {Zifiri.LogFormatter, %{}},
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: Keyword.get(opts, :max_bytes, 1_048_576),
        max_no_files: Keyword.get(opts, :max_files, 1),
        file_check: 0
      }
    }
  end
end
