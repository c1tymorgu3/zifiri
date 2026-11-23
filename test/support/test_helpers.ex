defmodule Zifiri.TestHelpers do
  @moduledoc """
  Fixtures shared by the HTTP-surface suites.

  Every helper builds real bytes through the real interfaces — the envelope is
  padded by `Zifiri.Envelope`, the hash comes from `Zifiri.Owner` — so a test
  failure means the pipeline changed, not that a fixture drifted.
  """

  alias Zifiri.{Envelope, Owner}
  alias Zifiri.Chat.Store
  alias Zifiri.Listings.Listing
  alias Zifiri.Mailbox.Envelope, as: MailboxEnvelope
  alias Zifiri.Pow.Challenge
  alias Zifiri.Repo

  @doc "Fresh 32-byte owner token; the only secret a write carries."
  def owner_token, do: :crypto.strong_rand_bytes(32)

  def owner_hash(token), do: Owner.hash(token)

  @doc "Pads a body through the envelope and returns `{bytes, bucket}`."
  def envelope(text) do
    {:ok, envelope, bucket} = Envelope.encode(text)
    {envelope, bucket}
  end

  @doc """
  Per-test isolation: no spent or outstanding challenge, no room state, no rows
  from another suite.

  Challenges and the room store are RAM state, so a leftover from another test
  would make an "outstanding" assertion mean something else. The SQLite file is
  shared between runs and other suites write rows outside this test's
  transaction; a page assertion must see this test's rows only. Inside the
  sandbox these deletes are rolled back with the test.
  """

  def isolate do
    Challenge.clear()
    Store.reset()
    Repo.delete_all(Listing)
    Repo.delete_all(MailboxEnvelope)
    :ok
  end
end
