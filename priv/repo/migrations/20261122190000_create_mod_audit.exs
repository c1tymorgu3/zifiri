defmodule Zifiri.Repo.Migrations.CreateModAudit do
  @moduledoc """
  The moderation audit chain, persisted (`plan §8.2`).

  One row per link: `e` is the link hash, `prev` the hash it chains to, and the
  rest is what the link was computed over. `n` is the link number and the
  primary key, so the chain has one order and a second writer cannot fork it.

  There is no `inserted_at`: a timestamp finer than the moderation `day` would
  be exactly the correlation channel `§8.1` spends the whole plane removing, and
  it would be written into the file that outlives the post. Ordering is `n`.
  """

  use Ecto.Migration

  def change do
    create table(:mod_audit, primary_key: false) do
      add :n, :integer, primary_key: true
      add :e, :binary, null: false
      add :prev, :binary, null: false
      add :action, :string, null: false
      add :reason, :string, null: false
      add :day, :string, null: false
      add :target, :binary, null: false
      add :role, :string, null: false
    end

    # Daily head publication (§8.2) reads the newest link; every verification
    # reads the whole chain in `n` order, which the primary key already gives.
    create index(:mod_audit, [:day])
  end
end
