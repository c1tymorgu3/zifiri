defmodule Zifiri.Transport do
  @moduledoc """
  The one module allowed to look at transport metadata — and it looks at none.

  Plan §5.1 forbids application code from reading the peer address,
  `x-forwarded-for`, `forwarded`, or `user_agent`. The CI job
  (`.github/workflows/ci.yml`) greps `lib/` and `test/` for those tokens and
  fails the build if they appear anywhere outside this file. Keeping a single,
  empty boundary means the exemption is exactly one file wide and reviewable
  instead of scattered across handlers.

  Why the functions return constants rather than reading and discarding:

    * nginx already blanks the forwarding headers (`proxy_set_header ... ""`)
      and connects over a unix socket, so a peer address would be `:unknown`
      even if it were read. Reading it would only create a value that could be
      logged later.
    * A read that is discarded today is a read that gets used tomorrow. The
      function that cannot return an address cannot leak one.

  So `peer/1` returning `:unknown` is the contract, not a TODO. Anything that
  later needs to tell callers apart has to do it without identifying them —
  proof of work, queue depth, a global breaker (§4.4) — and those are numbers,
  not identities. If a future phase adds a counter here, it must be an
  aggregate: never per-caller state, never a cache keyed by anything the
  caller sent.
  """

  @typedoc """
  Everything the server is allowed to know about who is calling.
  """
  @type peer :: :unknown

  @doc """
  Returns `:unknown`. The conn is accepted so that call sites look natural and
  so that a future reviewer can see, in one place, that nothing is extracted.
  """
  @spec peer(Plug.Conn.t()) :: peer()
  def peer(%Plug.Conn{}), do: :unknown

  @doc """
  The transport view of a request, as a map. Always the same map.
  """
  @spec metadata(Plug.Conn.t()) :: %{peer: peer()}
  def metadata(%Plug.Conn{}), do: %{peer: :unknown}
end
