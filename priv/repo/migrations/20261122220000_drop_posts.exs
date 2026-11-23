defmodule Zifiri.Repo.Migrations.DropPosts do
  @moduledoc """
  Removes the v4 forum row.

  Scope v5 has three planes — rooms, 1:1 mail, listings — and no forum. The
  `posts` table was the forum's write path; with the forum modules gone there is
  nothing left that can write it, and a table nothing writes is a table that
  only holds what was already published. Dropping it is what makes "yok ol"
  mean the row is gone rather than the row is unreachable.

  `drop_if_exists` because a database created after this migration never had
  the table, and a rollback that re-creates it would need the old schema to
  exist in the history — it does, one migration earlier. Indexes and the
  self-referencing foreign key go with the table.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:posts)
  end

  def down do
    create_if_not_exists table(:posts) do
      add :parent_id, references(:posts, on_delete: :delete_all)
      add :bucket, :integer, null: false
      add :body, :binary, null: false
      add :day, :date, null: false
      add :owner_hash, :binary, null: false
      add :mod_state, :string, null: false, default: "ok"
    end

    create_if_not_exists unique_index(:posts, [:owner_hash])
    create_if_not_exists index(:posts, [:day, :id])
    create_if_not_exists index(:posts, [:parent_id])
  end
end
