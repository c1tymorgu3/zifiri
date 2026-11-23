defmodule Zifiri.DataCase do
  @moduledoc """
  Shared setup for tests that touch SQLite.

  Sandbox mode keeps every test in its own transaction, so a test that deletes
  rows cannot change what the next test sees. Nothing here prints or asserts on
  database contents beyond what the test itself asked for.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Zifiri.Repo
      import Ecto.Query
      import Zifiri.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Zifiri.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
