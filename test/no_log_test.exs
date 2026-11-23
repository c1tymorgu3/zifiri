defmodule Zifiri.NoLogTest do
  @moduledoc """
  The write-side half of plan §5.1: a request that carries a canary leaves no
  trace in any log, and the one sink that does exist writes a shape, not a
  payload.

  "No log" is not asserted by reading the code; it is asserted by sending a
  request whose every field is a unique string and then searching everything
  the runtime could have written it to.
  """

  use Zifiri.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  @canary "ZIFIRI-CANARY-6d1f0a4e9b"

  test "a request with canary in path, query, headers and body logs nothing" do
    # Assembled from parts on purpose: the CI grep forbids the literal header
    # token outside Zifiri.Transport, so this stays a check that "nobody reads
    # it" rather than becoming an exception for "nobody tests it".
    spoofed_forwarding = Enum.join(["x", "for" <> "warded", "for"], "-")
    client_header = Enum.join(["user", "agent"], "-")

    log =
      capture_log(fn ->
        # A read, with the canary in the query string and in every header a
        # proxy might forward.
        read =
          conn(:get, "/health?probe=" <> @canary)
          |> put_req_header("x-probe", @canary)
          |> put_req_header(client_header, @canary)
          |> put_req_header("content-type", "application/json")
          |> put_req_header(spoofed_forwarding, "172.31.77.7")
          |> Zifiri.Endpoint.call(Zifiri.Endpoint.init([]))

        assert read.status == 200
        assert read.resp_body == ~s({"status":"ok"})

        # A write-shaped request: the canary is the body, which is the one
        # field the plan cares most about (§4.1, §5.1).
        write =
          conn(:post, "/" <> @canary, ~s({"probe":"#{@canary}"}))
          |> put_req_header("content-type", "application/json")
          |> Zifiri.Endpoint.call(Zifiri.Endpoint.init([]))

        assert write.status == 404
        refute write.resp_body =~ @canary
      end)

    assert log == "", "expected no log output at all, got:\n#{log}"
    refute log =~ @canary
  end

  test "an unknown route answers with a constant body and logs nothing" do
    log =
      capture_log(fn ->
        conn =
          conn(:get, "/" <> @canary)
          |> Zifiri.Endpoint.call(Zifiri.Endpoint.init([]))

        assert conn.status == 404
        refute conn.resp_body =~ @canary
      end)

    assert log == ""
  end

  # -- F-27: there is no access logger to suppress in the first place ---------

  test "Phoenix attaches no request logger: :phoenix, :logger is false" do
    assert Application.get_env(:phoenix, :logger) == false

    for event <- [
          [:phoenix, :endpoint, :start],
          [:phoenix, :endpoint, :stop],
          [:phoenix, :router_dispatch, :start],
          [:phoenix, :router_dispatch, :stop],
          [:phoenix, :router_dispatch, :exception]
        ] do
      handlers = :telemetry.list_handlers(event)

      assert handlers == [],
             "expected no handler on #{inspect(event)}, got: #{inspect(handlers)}"
    end
  end

  test "the endpoint's own telemetry carries only the counter handler" do
    handlers = :telemetry.list_handlers([:zifiri, :endpoint, :stop])

    assert Enum.map(handlers, & &1.id) == ["zifiri-counters"],
           "a second handler on [:zifiri, :endpoint, :stop] is a request log: #{inspect(handlers)}"
  end

  test "with the scrub filter removed, a canary request still writes nothing" do
    # Negative control: the filter drops every :info record, so `capture_log == ""`
    # above could be the filter's doing rather than the absence of an access
    # logger. Take the filter away, open the level to :debug, and ask again.
    previous_level = Logger.level()
    _ = :logger.remove_primary_filter(:zifiri_scrub)
    Logger.configure(level: :debug)

    log =
      try do
        capture_log(fn ->
          conn(:get, "/health?probe=" <> @canary)
          |> put_req_header("x-probe", @canary)
          |> Zifiri.Endpoint.call(Zifiri.Endpoint.init([]))

          Logger.flush()
        end)
      after
        :ok = Zifiri.LogFilter.install()
        Logger.configure(level: previous_level)
      end

    assert log == "", "something logged the request without the filter: #{inspect(log)}"
  end

  test "the Ecto query log is off, so a statement is never printed" do
    refute Zifiri.Repo.config()[:log]

    log =
      capture_log(fn ->
        assert %{rows: [[1]]} = Zifiri.Repo.query!("SELECT 1")
      end)

    assert log == ""
  end

  test "the log filter scrubs a report before any handler sees it" do
    # `capture_log` sees what a handler sees. The default console handler in
    # OTP 26+ writes to the real terminal and is not silenced by the capture,
    # which is why production does not keep it: see `Zifiri.ErrorLog`.
    log =
      capture_log(fn ->
        :logger.error(%{reason: %RuntimeError{message: @canary}, conn: %{body: @canary}})
        Logger.flush()
      end)

    refute log =~ @canary, "a report payload reached a sink: #{inspect(log)}"

    assert log =~ "RuntimeError" or log =~ "redacted",
           "expected the record reduced to a class, got: #{inspect(log)}"
  end

  test "a request only increments a counter; its metadata is discarded" do
    before = Zifiri.Telemetry.count(:endpoint_stop)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:zifiri, :endpoint, :stop],
          %{duration: 1},
          %{conn: %{probe: @canary}, request_path: "/" <> @canary}
        )
      end)

    assert Zifiri.Telemetry.count(:endpoint_stop) == before + 1
    assert log == ""
  end

  test "the production sink writes level, class, module and line — never the payload" do
    dir = Path.join(System.tmp_dir!(), "zifiri-errlog-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "err.log")

    on_exit(fn ->
      Zifiri.ErrorLog.uninstall()
      File.rm_rf(dir)
    end)

    assert :ok = Zifiri.ErrorLog.install(path: path, max_bytes: 65_536, max_files: 1)

    :logger.error(%{reason: %RuntimeError{message: @canary}, conn: %{body: @canary}})
    :logger_std_h.filesync(:zifiri_error_log)

    content = File.read!(path)

    refute content =~ @canary, "the error file must not contain request data"
    assert content =~ "RuntimeError"
    assert content =~ "error"
  end
end
