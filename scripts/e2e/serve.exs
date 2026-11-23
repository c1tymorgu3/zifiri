# scripts/e2e/serve.exs — start zifiri's endpoint on the port the E2E wants.
#
# `config/config.exs` pins 4000 for `mix phx.server`, which is the right
# default for a workstation but the wrong one for a shared box or a CI job
# where 4000 may already be taken. This file reads `ZIFIRI_E2E_PORT`, writes it
# into the endpoint config *before* the application starts, and then starts the
# app — the same supervision tree `mix phx.server` builds, minus the code
# reloader, which an E2E run does not need.
#
#   ZIFIRI_E2E_PORT=4010 mix run --no-start scripts/e2e/serve.exs
#
# `--no-start` is what makes the ordering work: `mix run` would otherwise boot
# the application before this file could change the port.

port = String.to_integer(System.get_env("ZIFIRI_E2E_PORT") || "4000")

config =
  :zifiri
  |> Application.get_env(Zifiri.Endpoint)
  |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: port)

Application.put_env(:zifiri, Zifiri.Endpoint, config)

{:ok, _started} = Application.ensure_all_started(:zifiri)

IO.puts("zifiri: endpoint listening on http://127.0.0.1:#{port}")

# `mix run` exits when the script returns; the endpoint is a supervised process
# and has to keep its VM alive for the E2E run to have something to talk to.
Process.sleep(:infinity)
