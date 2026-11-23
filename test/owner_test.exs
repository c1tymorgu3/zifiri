defmodule Zifiri.OwnerTest do
  use ExUnit.Case, async: false

  alias Zifiri.Owner

  # The development pepper this module falls back to outside production. Written
  # here so the test pins the fallback to "dev/test only" rather than to a
  # comment (F-02).
  @dev_seed "zifiri-dev-pepper"

  setup do
    previous = Application.get_env(:zifiri, :owner_pepper)
    previous_path = Application.get_env(:zifiri, :pepper_path)
    previous_env = Application.get_env(:zifiri, :env)

    on_exit(fn ->
      Application.put_env(:zifiri, :owner_pepper, previous)
      Application.put_env(:zifiri, :pepper_path, previous_path)
      Application.put_env(:zifiri, :env, previous_env)
    end)

    :ok
  end

  test "hash/1 is 32 bytes and deterministic" do
    token = :crypto.strong_rand_bytes(32)
    assert byte_size(Owner.hash(token)) == 32
    assert Owner.hash(token) == Owner.hash(token)
  end

  test "distinct tokens never collide in a sample of 10_000" do
    hashes =
      for _ <- 1..10_000 do
        Owner.hash(:crypto.strong_rand_bytes(32))
      end

    assert length(Enum.uniq(hashes)) == 10_000
  end

  test "the hash is keyed: a different pepper yields a different hash" do
    token = :crypto.strong_rand_bytes(32)
    Application.put_env(:zifiri, :owner_pepper, :crypto.strong_rand_bytes(32))
    first = Owner.hash(token)
    Application.put_env(:zifiri, :owner_pepper, :crypto.strong_rand_bytes(32))
    refute Owner.hash(token) == first
  end

  test "a short pepper is refused rather than silently truncated" do
    Application.put_env(:zifiri, :owner_pepper, "short")

    assert_raise RuntimeError, ~r/at least 32 bytes/, fn ->
      Owner.hash(:crypto.strong_rand_bytes(32))
    end
  end

  test "valid?/1 only accepts 32-byte binaries" do
    assert Owner.valid?(:crypto.strong_rand_bytes(32))
    refute Owner.valid?(:crypto.strong_rand_bytes(31))
    refute Owner.valid?("a")
    refute Owner.valid?(nil)
    refute Owner.valid?(123)
  end

  # -- F-02: the pepper comes from the file, and production fails closed ------

  describe "production" do
    setup do
      # Production reads the file only; the override is refused outright.
      Application.put_env(:zifiri, :env, :prod)
      Application.delete_env(:zifiri, :owner_pepper)
      :ok
    end

    test "a missing pepper file stops the boot instead of falling back" do
      Application.put_env(:zifiri, :pepper_path, missing_pepper_path())

      assert_raise RuntimeError, ~r/unreadable/, fn -> Owner.validate!() end
      assert_raise RuntimeError, ~r/unreadable/, fn -> Owner.hash(random_token()) end
    end

    test "31 bytes is refused" do
      Application.put_env(:zifiri, :pepper_path, pepper_file(:crypto.strong_rand_bytes(31)))

      assert_raise RuntimeError, ~r/at least 32 bytes, got 31/, fn -> Owner.validate!() end
    end

    test "32 bytes is accepted and is exactly the key that is used" do
      pepper = :crypto.strong_rand_bytes(32)
      Application.put_env(:zifiri, :pepper_path, pepper_file(pepper))

      token = random_token()

      assert :ok = Owner.validate!()
      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, pepper, token)
    end

    test "the file's bytes are the key, not a digest of them" do
      pepper = "0123456789abcdef0123456789abcdef"
      Application.put_env(:zifiri, :pepper_path, pepper_file(pepper))

      token = random_token()
      digest = :crypto.hash(:sha256, pepper)

      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, pepper, token)
      refute Owner.hash(token) == :crypto.mac(:hmac, :sha256, digest, token)
    end

    test "the file's bytes are the key, newline included" do
      pepper = ("0123456789abcdef" |> String.duplicate(2)) <> "\n"
      Application.put_env(:zifiri, :pepper_path, pepper_file(pepper))

      token = random_token()

      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, pepper, token)
    end

    test "a 32-byte pepper that happens to end in a newline byte is used verbatim" do
      # One pepper in 256 ends in 0x0A; stripping it would silently weaken the
      # key to 31 bytes. The newline is only removed when 32 bytes remain.
      pepper = "0123456789abcdef0123456789abcde" <> <<0x0A>>
      Application.put_env(:zifiri, :pepper_path, pepper_file(pepper))

      token = random_token()

      assert byte_size(pepper) == 32
      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, pepper, token)
    end

    test ":owner_pepper is refused even when the file is valid" do
      Application.put_env(:zifiri, :pepper_path, pepper_file(:crypto.strong_rand_bytes(32)))
      Application.put_env(:zifiri, :owner_pepper, :crypto.strong_rand_bytes(32))

      assert_raise RuntimeError, ~r/owner_pepper must not be set in production/, fn ->
        Owner.validate!()
      end
    end

    test "the development pepper is refused even if it is the file's content" do
      dev = :crypto.hash(:sha256, @dev_seed)
      Application.put_env(:zifiri, :pepper_path, pepper_file(dev))

      assert_raise RuntimeError, ~r/development pepper is in use in production/, fn ->
        Owner.validate!()
      end
    end

    test "Application.start/2 refuses to boot before any child starts" do
      Application.put_env(:zifiri, :pepper_path, missing_pepper_path())

      # The gate runs before `Supervisor.start_link/2`, so this raises without
      # colliding with the supervisor the test run already started: nothing has
      # been started when the raise happens.
      assert_raise RuntimeError, ~r/unreadable/, fn ->
        Zifiri.Application.start(:normal, [])
      end
    end
  end

  describe "outside production" do
    setup do
      Application.put_env(:zifiri, :env, :test)
      Application.delete_env(:zifiri, :owner_pepper)
      :ok
    end

    test "the pepper file is used when it exists" do
      pepper = :crypto.strong_rand_bytes(32)
      Application.put_env(:zifiri, :pepper_path, pepper_file(pepper))
      token = random_token()

      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, pepper, token)
    end

    test "a short file still raises instead of falling through to the constant" do
      Application.put_env(:zifiri, :pepper_path, pepper_file("1234567890"))

      assert_raise RuntimeError, ~r/at least 32 bytes/, fn -> Owner.hash(random_token()) end
    end

    test ":owner_pepper still overrides the file" do
      file_pepper = :crypto.strong_rand_bytes(32)
      Application.put_env(:zifiri, :pepper_path, pepper_file(file_pepper))
      override = :crypto.strong_rand_bytes(32)
      Application.put_env(:zifiri, :owner_pepper, override)

      token = random_token()

      assert Owner.hash(token) == :crypto.mac(:hmac, :sha256, override, token)
      refute Owner.hash(token) == :crypto.mac(:hmac, :sha256, file_pepper, token)
    end

    test "with no override and no file it raises, even outside production" do
      Application.put_env(:zifiri, :pepper_path, missing_pepper_path())

      assert_raise RuntimeError, ~r/unreadable/, fn -> Owner.hash(random_token()) end
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp random_token, do: :crypto.strong_rand_bytes(32)

  defp pepper_file(content) do
    dir = Path.join(System.tmp_dir!(), "zifiri-pepper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pepper")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  defp missing_pepper_path do
    Path.join(System.tmp_dir!(), "zifiri-pepper-absent-#{System.unique_integer([:positive])}")
  end
end
