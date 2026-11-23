defmodule Zifiri.ArchitectureTest do
  @moduledoc """
  The two CI greps, executed as tests.

  A grep in a workflow file only fails a build after a push, and only if the
  workflow file is the one that ran. The same checks live here so `mix test`
  catches a logging call site or a peer read on the developer's machine, in
  the same commit that introduces it (F-26).

  Two properties matter as much as the checks themselves:

    * this file must not contain the forbidden tokens — not in a string, not in
      a variable name. Every token is assembled from fragments. A checker that
      has to exempt itself is a checker with a hole in it, which is exactly the
      hole `test/no_log_test.exs` had.
    * the checks must be shown to fire. Each test plants a deliberate violation
      in a scratch file and asserts it is found, so a typo in the token list
      cannot turn the check into a no-op.

  The peer-data exemption is exactly `lib/zifiri/transport.ex` by full path: a
  prefix match would exempt `transport_extra.ex`, which is what the old CI
  filter (`^lib/zifiri/transport.ex:`) allowed.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @transport "lib/zifiri/transport.ex"

  # Assembled, never written out: see the moduledoc.
  defp logging_tokens do
    [{"Logger.", "info"}, {"Logger.", "debug"}, {"IO.", "inspect"}, {"dbg", "("}]
    |> Enum.map(fn {head, tail} -> head <> tail end)
  end

  defp peer_tokens do
    fwd = "for" <> "warded"

    [
      "remote" <> "_ip",
      "x-" <> fwd <> "-for",
      "x_" <> fwd <> "_for",
      "x-real" <> "-ip",
      "user" <> "-" <> "agent",
      "user" <> "_agent",
      "peer" <> "_data",
      "sock" <> "name",
      "get_peer" <> "_cert",
      fwd
    ]
  end

  test "lib/ has no Logger.info, Logger.debug, IO.inspect or dbg call" do
    found = hits(lib_files(), logging_tokens())

    assert found == [],
           "request data can reach a sink through these call sites: #{inspect(found)}"
  end

  test "peer data appears only inside the Zifiri.Transport boundary" do
    outside =
      files()
      |> Enum.reject(&(&1 == Path.join(@root, @transport)))
      |> hits(peer_tokens())

    assert outside == [],
           "peer data read outside Zifiri.Transport: #{inspect(outside)}"

    # The exemption is not vacuous: the boundary is the file that names the
    # tokens, in prose, to forbid them everywhere else.
    assert [_ | _] = hits([Path.join(@root, @transport)], peer_tokens())
  end

  test "the exemption is exactly one path, not a prefix" do
    refute exempt?("lib/zifiri/transport_extra.ex")
    refute exempt?("lib/zifiri/transport.ex/db.ex")
    refute exempt?("lib/zifiri/transport.exs")
    assert exempt?(@transport)
  end

  test "the logging grep fires on a planted violation" do
    [logger_info | _] = logging_tokens()
    planted = plant(~s{#{logger_info}("canary")} <> "\n")

    assert [{_, token}] = hits([planted], logging_tokens())
    assert token == logger_info
  end

  test "the peer grep fires on every spelling it claims to cover" do
    [
      remote,
      forward_dash,
      forward_underscore,
      real_ip,
      client_dash,
      client_underscore,
      peer_map_key,
      socket_name,
      peer_cert,
      forward_header
    ] = peer_tokens()

    contents = [
      "conn." <> remote,
      ~s{get_req_header(conn, "#{forward_dash}")},
      ~s{get_req_header(conn, "#{forward_underscore}")},
      ~s{get_req_header(conn, "#{real_ip}")},
      ~s{get_req_header(conn, "#{client_dash}")},
      ~s{conn.assigns[:probe] = conn.#{client_underscore}},
      "Plug.Conn.get_" <> peer_map_key <> "(conn) |> Map.fetch!(:" <> peer_map_key <> ")",
      ":inet." <> socket_name <> "(socket)",
      ":ssl." <> peer_cert <> "(socket)",
      ~s{get_req_header(conn, "#{forward_header}")}
    ]

    for content <- contents do
      planted = plant(content <> "\n")
      assert [_ | _] = hits([planted], peer_tokens()), "missed: #{content}"
    end
  end

  test "ci.yml runs both greps with the same tokens" do
    ci = Path.join(@root, ".github/workflows/ci.yml") |> File.read!()

    # Compare against the unescaped workflow text: grep -E escapes the dots and
    # the parenthesis, the token list does not.
    plain = String.replace(ci, "\\", "")

    for token <- logging_tokens() ++ peer_tokens() do
      assert String.contains?(plain, token),
             "ci.yml no longer greps for #{inspect(token)} — the local check drifted from CI"
    end

    assert String.contains?(plain, "'^" <> @transport <> ":'"),
           "the peer-data exemption is not anchored to the full transport path"
  end

  # -- scanning --------------------------------------------------------------

  defp files do
    Path.wildcard(Path.join(@root, "lib/**/*.ex")) ++
      Path.wildcard(Path.join(@root, "lib/**/*.heex")) ++
      Path.wildcard(Path.join(@root, "test/**/*.ex")) ++
      Path.wildcard(Path.join(@root, "test/**/*.exs"))
  end

  defp lib_files do
    Path.wildcard(Path.join(@root, "lib/**/*.ex")) ++
      Path.wildcard(Path.join(@root, "lib/**/*.heex"))
  end

  defp hits(files, tokens) do
    Enum.flat_map(files, fn file ->
      content = File.read!(file)

      for token <- tokens, String.contains?(content, token) do
        {relative(file), token}
      end
    end)
  end

  defp exempt?(relative_path), do: relative_path == @transport

  defp relative(file), do: file |> Path.relative_to(@root) |> String.replace("\\", "/")

  defp plant(content) do
    dir = Path.join(System.tmp_dir!(), "zifiri-arch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "planted.ex")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end
end
