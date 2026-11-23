defmodule Zifiri.Repo.Migrations.CreatePosts do
  @moduledoc """
  The published forum row (plan §4.3).

  Every column here is justified by the plan and nothing else is added:
  `parent_id` for replies, `bucket` because the bucket is public anyway
  (§4.1), `body` as opaque bytes, `day` at UTC-day granularity only,
  `owner_hash` for the two-click delete, `mod_state` for the two-plane
  moderation model (§8.1). No timestamps: `timestamps()` would add a
  second-resolution `inserted_at` and hand back exactly the sub-day timing
  the write path spends §4.2 removing.
  """

  use Ecto.Migration

  def change do
    create table(:posts) do
      add :parent_id, references(:posts, on_delete: :delete_all)
      add :bucket, :integer, null: false
      add :body, :binary, null: false
      add :day, :date, null: false
      add :owner_hash, :binary, null: false
      add :mod_state, :string, null: false, default: "ok"
    end

    # Unique per post: this is what makes a re-sent envelope idempotent
    # (§4.2.3) and what makes "yok ol" a single indexed delete (§6).
    create unique_index(:posts, [:owner_hash])

    create index(:posts, [:day, :id])
    create index(:posts, [:parent_id])
  end
end
