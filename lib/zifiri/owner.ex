defmodule Zifiri.Owner do
  @moduledoc """
  Ownership without identity.

  A post is owned by whoever holds its token. The server only ever stores
  `HMAC-SHA256(pepper, token)`, so a database dump cannot be replayed to
  delete somebody else's post and the operator cannot derive the token.

  The pepper is read from `config :zifiri, :pepper_path` (default
  `/run/zifiri/pepper`): a file the operator places in tmpfs at boot and never
  writes to disk (plan §4.3, §11.4). Reading is **fail-closed**:

    * the file missing, unreadable, or shorter than 32 bytes → raise;
    * `config :zifiri, :owner_pepper` set in production → raise, because an
      in-memory override in production can only be the development constant
      this module must never ship with;
    * the development constant itself → raise in production.

  There is no built-in pepper in the code and no silent fallback in any
  environment: if the file is missing, the boot fails. `dev` and `test` get a
  key from `config :zifiri, :owner_pepper` in their own config file — an
  explicit, environment-local choice — and production refuses that key outright
  so it can never be mistaken for a deployment secret.

  The file is read as raw bytes and never trimmed: a trailing newline is part
  of the key. Trimming would shorten a pepper whose last byte happens to be
  `0x0A` (one in 256) and make the same file mean two different keys. Write it
  with `openssl rand -out /run/zifiri/pepper 32`, not `echo`.

  Unlike every other secret in this system, losing the pepper is harmless:
  hashes computed before the loss simply stop matching, and the wipe drill
  (§6) is the only operation that needs them to match.

  The file is read on every `hash/1` rather than cached, so the value in use is
  always the value in tmpfs; a rotation is a restart, never a hidden copy.
  """

  @min_pepper_bytes 32
  @dev_seed "zifiri-dev-pepper"
  @default_pepper_path "/run/zifiri/pepper"

  @spec hash(binary()) :: <<_::256>>
  def hash(token) when is_binary(token) and byte_size(token) == 32 do
    :crypto.mac(:hmac, :sha256, pepper(), token)
  end

  @spec valid?(term()) :: boolean()
  def valid?(token), do: is_binary(token) and byte_size(token) == 32

  @doc """
  Returns the pepper, or raises.

  In production the only accepted source is the pepper file. Elsewhere an
  explicit `:owner_pepper` wins, then the file, then a raise — there is no
  third option.
  """
  @spec pepper() :: binary()
  def pepper do
    if production?(), do: production_pepper(), else: development_pepper()
  end

  @doc """
  Boot gate: reads the pepper once, eagerly, so a misconfigured deployment
  fails in `Zifiri.Application.start/2` instead of on the first write.
  """
  @spec validate!() :: :ok
  def validate! do
    _ = pepper()
    :ok
  end

  defp production_pepper do
    case Application.get_env(:zifiri, :owner_pepper) do
      nil ->
        :ok

      _ ->
        raise "config :zifiri, :owner_pepper must not be set in production; " <>
                "place the pepper file at #{pepper_path()} instead"
    end

    pepper = read_pepper_file!()

    if pepper == dev_pepper() do
      raise "the development pepper is in use in production; " <>
              "replace #{pepper_path()} with a real secret"
    end

    pepper
  end

  defp development_pepper do
    case Application.get_env(:zifiri, :owner_pepper) do
      nil -> read_pepper_file!()
      pepper -> assert_length!(pepper, ":owner_pepper")
    end
  end

  defp read_pepper_file! do
    path = pepper_path()

    case File.read(path) do
      {:ok, pepper} ->
        assert_length!(pepper, path)

      {:error, reason} ->
        raise "ownership pepper is unreadable at #{path} (#{:file.format_error(reason)}); " <>
                "refusing to start"
    end
  end

  # Raw bytes, never trimmed. A newline added by `echo` is part of the key: it
  # only makes the key longer, while trimming would silently shorten a pepper
  # whose last byte happens to be 0x0A (one in 256) — the same 32-byte file
  # would then mean different keys on different runs.
  defp assert_length!(pepper, _source)
       when is_binary(pepper) and byte_size(pepper) >= @min_pepper_bytes,
       do: pepper

  defp assert_length!(pepper, source) when is_binary(pepper) do
    raise "ownership pepper from #{source} must be at least #{@min_pepper_bytes} bytes, " <>
            "got #{byte_size(pepper)}"
  end

  defp assert_length!(pepper, source) do
    raise "ownership pepper from #{source} must be a binary, got: #{inspect(pepper)}"
  end

  defp pepper_path, do: Application.get_env(:zifiri, :pepper_path, @default_pepper_path)

  defp production?, do: Application.get_env(:zifiri, :env, :dev) == :prod

  defp dev_pepper, do: :crypto.hash(:sha256, @dev_seed)
end
