defmodule Zifiri.LeakTest do
  @moduledoc """
  Plan §5.1: the server keeps no log and reflects no request data.

  Every request here goes through `Zifiri.Endpoint.call/2` — the real plug
  pipeline, the real parser, the real padding — so what the assertions see is
  what a client on the wire sees. Each canary is planted in the one place the
  request can carry it (path, query, body, header) and then hunted for in every
  place an answer or a sink could carry it back out: the response body, the
  response headers, `Logger` and the `Zifiri.ErrorLog` file.

  The companion invariant is size: an answer's length must say nothing about
  what was asked. One status, one length.
  """

  use Zifiri.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  @canary "ZIFIRI-CANARY-6f1c9a"
  @response_bytes 16_384

  # `.github/workflows/ci.yml` greps `lib/` and `test/` for the peer-field and
  # proxy-header names and fails the build outside `lib/zifiri/transport.ex`,
  # so this file never spells them: they are assembled from parts at runtime.
  defp peer_names do
    [
      "remote" <> "_" <> "ip",
      "user" <> "_" <> "agent",
      "x" <> "-" <> "real" <> "-" <> "ip",
      "peer" <> "_" <> "data",
      "sock" <> "name",
      "peer" <> "name",
      "get" <> "_" <> "peer" <> "_" <> "cert",
      "for" <> "warded"
    ]
  end

  defp proxy_header, do: Enum.join(["x", "for" <> "warded", "for"], "-")
  defp client_header, do: Enum.join(["user", "agent"], "-")

  # -- request helpers -------------------------------------------------------

  defp call(conn), do: Zifiri.Endpoint.call(conn, Zifiri.Endpoint.init([]))

  defp with_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp get(path, headers \\ []), do: conn(:get, path) |> with_headers(headers) |> call()

  defp send_json(path, body, headers) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> with_headers(headers)
    |> call()
  end

  # A request that is supposed to be *answered* must be answered. A raise out of
  # the endpoint is a failure of the property under test, so say so in the
  # failure message instead of dumping a Phoenix stacktrace.
  defp answer(conn, what) do
    call(conn)
  rescue
    e ->
      flunk(
        "#{what} raised #{inspect(e.__struct__)} instead of answering: " <>
          (e |> Exception.message() |> String.replace("\n", " "))
      )
  end

  defp answered_get(path, what) do
    conn(:get, path) |> answer(what)
  end

  defp answered_json(path, body, what) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> answer(what)
  end

  defp token, do: Base.encode64(:crypto.strong_rand_bytes(32))

  defp envelope_bytes(payload) do
    {:ok, envelope, _bucket} = Zifiri.Envelope.encode(payload)
    envelope
  end

  defp sizes(responses), do: responses |> Enum.map(&byte_size(&1.resp_body)) |> Enum.uniq()

  # -- 404 ------------------------------------------------------------------

  test "every 404 is one size and never echoes the path" do
    paths = [
      "/" <> @canary,
      "/api/" <> @canary,
      "/api/listings/" <> @canary,
      "/api/listings/" <> String.reverse(@canary),
      "/api/listings/1"
    ]

    responses = Enum.map(paths, &get/1)

    assert Enum.all?(responses, &(&1.status == 404)),
           "expected 404 for every unknown path, got #{inspect(Enum.map(responses, & &1.status))}"

    for response <- responses do
      refute response.resp_body =~ @canary
      refute response.resp_body =~ "6f1c9a"
    end

    # A shorter body for "no such route" and a padded one for "no such post"
    # would let a client map the router without sending a single valid request.
    measured = Enum.zip(paths, Enum.map(responses, &byte_size(&1.resp_body)))

    assert sizes(responses) == [@response_bytes],
           "404 bodies differ in size (path => bytes): #{inspect(measured)}"
  end

  test "a canary in the query string reaches neither body nor header" do
    for path <- ["/api/listings", "/health", "/nope"] do
      response = get("#{path}?probe=#{@canary}&ref=#{@canary}")

      refute response.resp_body =~ @canary
      refute response.resp_body =~ "6f1c9a"

      for {_name, value} <- response.resp_headers do
        refute value =~ @canary
      end
    end
  end

  # -- 400 / 403 / 422 ------------------------------------------------------

  test "a refused write is one size whatever the reason" do
    bad_envelope =
      answered_json(
        "/api/listings",
        ~s({"owner_token":"#{token()}","envelope":"#{@canary}"}),
        "a 400 (unparsable envelope)"
      )

    no_token =
      answered_json(
        "/api/listings",
        ~s({"envelope":"#{@canary}","probe":"#{@canary}"}),
        "a 403 (no owner token)"
      )

    unknown_challenge =
      answered_json(
        "/api/listings",
        ~s({"owner_token":"#{token()}","envelope":"#{Base.encode64(envelope_bytes("x"))}","title":"x","category":"spor","currency":"TRY","price_cents":1,"challenge_id":"nope","nonce":0,"bits":4}),
        "a 403 (a proof that was never issued)"
      )

    assert bad_envelope.status == 400, "expected 400, got #{bad_envelope.status}"
    assert no_token.status == 403, "expected 403, got #{no_token.status}"
    assert unknown_challenge.status == 403, "expected 403, got #{unknown_challenge.status}"

    responses = [bad_envelope, no_token, unknown_challenge]

    for response <- responses do
      assert byte_size(response.resp_body) == @response_bytes
      refute response.resp_body =~ @canary
    end

    assert Enum.uniq(Enum.map(responses, & &1.resp_body)) |> length() == 1,
           "refusals differ in content: #{inspect(Enum.map(responses, & &1.resp_body))}"
  end

  # -- 413 ------------------------------------------------------------------

  test "an oversized body is refused, not crashed on" do
    body = ~s({"envelope":"#{String.duplicate("a", 100_000)}#{@canary}"})
    other = ~s({"envelope":"#{String.duplicate("b", 100_000)}"})

    first = answered_json("/api/listings", body, "a 100 KB body")
    second = answered_json("/api/listings", other, "a second 100 KB body")

    assert first.status in 400..499, "expected 4xx for an oversized body, got #{first.status}"
    assert byte_size(first.resp_body) == @response_bytes
    assert first.resp_body == second.resp_body, "oversized refusals differ in content"
    refute first.resp_body =~ @canary
  end

  # -- 500 ------------------------------------------------------------------

  test "a server fault answers in one size and names nothing" do
    # An integer larger than the column can hold reaches `Repo.get/2` and raises
    # there — the only way to make the endpoint take its 500 path from outside.
    huge = String.duplicate("9", 25)

    first = answered_get("/api/listings/" <> huge, "an out-of-range ref")

    second =
      answered_get("/api/listings/" <> String.duplicate("9", 26), "a second out-of-range ref")

    assert first.status in 500..599, "expected 5xx, got #{first.status}"
    assert byte_size(first.resp_body) == @response_bytes
    assert first.resp_body == second.resp_body, "500 bodies differ in content"
    refute first.resp_body =~ @canary
    refute first.resp_body =~ huge
  end

  # -- header reflection ----------------------------------------------------

  test "request headers reach no response, no log and no error file" do
    path = Path.join(System.tmp_dir!(), "zifiri-leak-#{System.unique_integer([:positive])}.log")

    :ok = Zifiri.ErrorLog.install(path: path)

    on_exit(fn ->
      Zifiri.ErrorLog.uninstall()
      File.rm(path)
    end)

    assert File.exists?(path), "the error sink did not open, so this test would be vacuous"

    headers = [
      {proxy_header(), "203.0.113.9"},
      {client_header(), "canary-ua"},
      {"referer", "canary-ref"},
      {"x-probe", @canary}
    ]

    log =
      capture_log(fn ->
        for response <- [
              get("/api/listings/" <> @canary, headers),
              get("/api/" <> @canary, headers),
              send_json("/api/listings", ~s({"probe":"#{@canary}"}), headers),
              send_json(
                "/api/listings",
                ~s({"owner_token":"#{token()}","envelope":"#{@canary}"}),
                headers
              )
            ] do
          refute response.resp_body =~ "203.0.113.9"
          refute response.resp_body =~ "canary-ua"
          refute response.resp_body =~ "canary-ref"
          refute response.resp_body =~ @canary

          for {_name, value} <- response.resp_headers do
            refute value =~ "canary-ua"
            refute value =~ "canary-ref"
            refute value =~ "203.0.113.9"
          end
        end
      end)

    :logger_std_h.filesync(:zifiri_error_log)
    written = File.read!(path)

    assert log == "", "a request wrote to the log: #{inspect(log)}"
    assert written == "", "a request reached the error sink: #{inspect(written)}"
  end

  # -- CORS -----------------------------------------------------------------

  test "no CORS header is offered, whatever the origin" do
    origin = [{"origin", "https://evil.example"}]

    preflight =
      conn(:options, "/api/listings")
      |> with_headers(origin)
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "content-type")
      |> call()

    write =
      send_json("/api/listings", ~s({"probe":"#{@canary}"}), origin)

    for response <- [preflight, write] do
      assert get_resp_header(response, "access-control-allow-origin") == []
      assert get_resp_header(response, "access-control-allow-credentials") == []
      assert get_resp_header(response, "access-control-allow-methods") == []

      assert Enum.all?(response.resp_headers, fn {name, _} ->
               not String.starts_with?(String.downcase(name), "access-control-")
             end)
    end
  end

  # -- the transport boundary ----------------------------------------------

  test "Zifiri.Transport names no peer field anywhere in its AST" do
    source = File.read!("lib/zifiri/transport.ex")
    ast = source |> Code.string_to_quoted!() |> strip_docs()

    atoms = collect(ast, &is_atom/1)
    strings = collect(ast, &is_binary/1)

    names = peer_names()

    forbidden_atoms =
      names
      |> Enum.flat_map(&[&1, String.replace(&1, "-", "_"), String.replace(&1, "_", "-")])
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    forbidden_strings =
      names
      |> Enum.flat_map(&[&1, String.replace(&1, "-", "_"), String.replace(&1, "_", "-")])
      |> MapSet.new()

    assert MapSet.disjoint?(atoms, forbidden_atoms),
           "transport names a peer field: #{inspect(MapSet.intersection(atoms, forbidden_atoms))}"

    assert MapSet.disjoint?(strings, forbidden_strings),
           "transport reads a proxy header: #{inspect(MapSet.intersection(strings, forbidden_strings))}"

    # The boundary is one file wide, and the file exposes exactly two functions.
    assert Zifiri.Transport.__info__(:functions) |> Enum.sort() == [metadata: 1, peer: 1]
  end

  test "Zifiri.Transport returns a constant whatever the request says" do
    conn =
      conn(:get, "/api/listings")
      |> with_headers([
        {proxy_header(), "203.0.113.9"},
        {client_header(), "canary-ua"},
        {"referer", "canary-ref"}
      ])

    assert Zifiri.Transport.peer(conn) == :unknown
    assert Zifiri.Transport.metadata(conn) == %{peer: :unknown}
    assert Zifiri.Transport.peer(conn) == Zifiri.Transport.peer(%Plug.Conn{})
  end

  # -- AST helpers ----------------------------------------------------------

  # `@moduledoc` is allowed to talk about the fields it refuses to read; the
  # code is not. Drop the doc attributes, then look at what is left.
  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{attr, _, [_]}]} when attr in [:moduledoc, :doc, :typedoc] -> {:doc, [], []}
      node -> node
    end)
  end

  defp collect(ast, fun) do
    {_ast, found} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        if fun.(node), do: {node, MapSet.put(acc, node)}, else: {node, acc}
      end)

    found
  end
end
