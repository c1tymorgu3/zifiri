defmodule Zifiri.TransportTest do
  @moduledoc """
  The transport boundary returns constants. This is the assertion that keeps
  the exemption in `.github/workflows/ci.yml` from becoming a hole: the one
  module allowed to read peer data reads none.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  test "peer/1 is constant for any connection" do
    plain = conn(:get, "/health")

    loaded =
      plain
      |> Plug.Conn.put_req_header("x-probe", "172.31.77.7")
      |> Map.replace!(:host, "example.test")

    assert Zifiri.Transport.peer(plain) == :unknown
    assert Zifiri.Transport.peer(loaded) == :unknown
  end

  test "metadata/1 carries one key and no values" do
    assert Zifiri.Transport.metadata(conn(:get, "/health")) == %{peer: :unknown}
  end
end
