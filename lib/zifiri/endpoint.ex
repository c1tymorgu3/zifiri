defmodule Zifiri.Endpoint do
  @moduledoc """
  The HTTP entry point, and the place where the log policy is decided.

  What is *not* here is the point:

    * no request logger plug. `Plug.Logger` writes the method, the path, the
      status and the duration of every request; `Plug.Telemetry` writes a
      `[info]` line per request through its default handler. Neither is
      plugged, and `Zifiri.LogFilter` drops debug/info records anyway.
    * no `Plug.RequestId`. A per-request identifier is a value that can be
      correlated across two sinks; there are no two sinks, and there is
      nothing worth correlating.
    * no session, no cookies, no `Plug.Session`. There is nothing to keep.

  ## Where a body is parsed

  Only under `/api`, and only then. The API carries a padded envelope as
  base64 inside a small JSON document, so it needs a parser; everything else
  — every path outside `/api` — still receives its body untouched, exactly as
  before, because a parsed body is a structure some later `inspect/1` could
  print. `Zifiri.JSON` is the decoder: no `jason` dependency, and its
  parse errors never quote the input.

  ## The socket

  The chat socket is mounted only if its module is loadable. `Zifiri.Chat` is a
  separate plane with its own lifecycle; the endpoint must not refuse to boot
  because that module was compiled out, and a compile-time check means a
  missing socket is a silently absent route rather than a warning that
  `--warnings-as-errors` turns into a build failure.

  Telemetry is attached in `Zifiri.Telemetry` and is counter-only: the event
  metadata (which carries the conn) is discarded by the handler, never logged.
  """

  use Phoenix.Endpoint, otp_app: :zifiri

  @api_length 32_768
  # The one response size. Same number as `Zifiri.Router`; the fault path here
  # has to answer in the same length as every other answer.
  @response_bytes 16_384

  # Every response carries the same headers, including the static shell: a
  # policy that only covers the API leaves the page that runs the client
  # unprotected (plan §10.1).
  plug :security_headers
  plug :serve_index

  # The client is a static bundle with no server-side rendering; serving it
  # from the same origin is the whole point (no third-party request, plan
  # §10.1). Missing files fall through to the router, which answers 404.
  plug Plug.Static,
    at: "/",
    from: "priv/static",
    gzip: false,
    only: ~w(assets fonts index.html logo.png favicon-32.png apple-touch-icon.png robots.txt)

  plug Plug.Telemetry, event_prefix: [:zifiri, :endpoint]
  plug :api_json_body

  # `ensure_compiled/1` rather than `ensure_loaded/1`: during a full build the
  # chat socket may not be compiled yet when this file is, and only the former
  # waits for it. If the module is genuinely absent, the branch is skipped
  # instead of emitting an undefined-module warning.
  if match?({:module, _}, Code.ensure_compiled(Zifiri.Chat.Socket)) do
    socket "/socket", Zifiri.Chat.Socket, websocket: true
  end

  plug :dispatch

  # A fault inside the router must not become a Phoenix error page: that page
  # is HTML, it names the exception and its stack, and it is a different length
  # from every other answer — three things §5.1 and the fixed-size rule forbid.
  # Whatever was raised, the caller gets the same padded refusal with a 500 and
  # nothing else; the reason stays in this process.
  defp dispatch(conn, opts) do
    try do
      Zifiri.Router.call(conn, opts)
    rescue
      _ -> fault(conn)
    catch
      :exit, _ -> fault(conn)
      :throw, _ -> fault(conn)
    end
  end

  defp fault(%Plug.Conn{state: :sent} = conn), do: conn

  defp fault(conn) do
    body = ~s({"error":"refused"})
    padded = body <> String.duplicate(" ", @response_bytes - byte_size(body))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(500, padded)
  end

  defp api_json_body(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    conn =
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: Zifiri.JSON,
          length: @api_length
        )
      )

    # A POST with no usable body (missing content type, empty body, a parser
    # that chose not to run) leaves `body_params` unfetched. A read is allowed
    # to have no body; a write is not, and its refusal is the constant 400.
    case conn.body_params do
      %Plug.Conn.Unfetched{} when conn.method in ["POST", "PATCH", "PUT"] ->
        Plug.Conn.assign(conn, :zifiri_bad_body, true)

      _other ->
        conn
    end
  rescue
    # Malformed JSON is not an error page: the body simply carries no fields,
    # the gate refuses it, and the client gets the same constant refusal it
    # would get for any other unusable write. The exception message is dropped
    # with the body it would have quoted.
    Plug.Parsers.ParseError -> conn
    Plug.Parsers.BadEncodingError -> conn
    Plug.Parsers.UnsupportedMediaTypeError -> conn
    # Over `@api_length`. The refusal is the same constant 400 the router gives
    # an unusable write — a 413 page would be a different length and would say
    # how large the body was allowed to be.
    Plug.Parsers.RequestTooLargeError -> Plug.Conn.assign(conn, :zifiri_bad_body, true)
  end

  defp api_json_body(conn, _opts), do: conn

  # Plug.Static serves `/index.html`; a browser asks for `/`. Rewriting the one
  # empty path is the whole SPA "router".
  defp serve_index(%Plug.Conn{path_info: []} = conn, _opts),
    do: %{conn | path_info: ["index.html"]}

  defp serve_index(conn, _opts), do: conn

  @csp "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " <>
         "font-src 'self'; connect-src 'self' wss:; manifest-src 'self'; " <>
         "base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'; " <>
         "require-trusted-types-for 'script'"

  defp security_headers(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("content-security-policy", @csp)
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
    |> Plug.Conn.put_resp_header("permissions-policy", "geolocation=(), microphone=(), camera=()")
  end
end
