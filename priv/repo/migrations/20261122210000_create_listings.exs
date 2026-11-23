defmodule Zifiri.Repo.Migrations.CreateListings do
  @moduledoc """
  The listing plane: a public, durable post that carries plaintext metadata.

  A listing is not a forum post with extra fields. Its title, price, currency
  and category are stored in the clear on purpose — they are what a search
  reads — and only the body is an envelope, padded to a bucket exactly like a
  chat message so the size of a description says nothing.

  The columns are the plan's list and nothing else:

    * `created_day`, not `inserted_at`: the row carries a UTC day, never a
      second, so the table cannot be read as a timeline of one seller's posts.
    * `owner_hash` is a per-write HMAC from `Zifiri.Owner.hash/1`, not an
      identity: it is deliberately **not** unique, because one owner may run
      several listings and a unique index would turn that into a signal
      (a second `create` would be refused, or worse, silently merged).
    * `status` is `open` or `closed`. Closing is the delete a seller sees;
      `Zifiri.Listings.erase/2` is the physical one.

  Indexes follow the two read paths that exist: the feed pages by
  `(category, created_day)`, and an erase looks rows up by `owner_hash`.
  """
  use Ecto.Migration

  def change do
    create table(:listings) do
      add(:title, :string, null: false, size: 120)
      add(:body, :binary, null: false)
      add(:price_cents, :integer)
      add(:currency, :string, null: false, size: 3)
      add(:category, :string, null: false, size: 32)
      add(:owner_hash, :binary, null: false, size: 32)
      add(:status, :string, null: false, size: 8, default: "open")
      add(:created_day, :date, null: false)
    end

    create(index(:listings, [:category, :created_day]))
    create(index(:listings, [:owner_hash]))
  end
end
