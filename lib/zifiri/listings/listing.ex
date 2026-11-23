defmodule Zifiri.Listings.Listing do
  @moduledoc """
  One row of the listing plane.

  The struct is the table: there is no `inserted_at`, no `updated_at`, no
  `owner_id` and no counter of any kind. `created_day` is a `Date`, so the row
  cannot answer "at what second was this posted" — and two listings by the same
  owner on the same day are indistinguishable from two owners' listings by
  their timestamps alone.

  `body` holds the padded envelope exactly as it was written; the context
  decodes it on the way out, so a caller of `Zifiri.Listings.get/1` sees the
  description and not the padding.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @title_max 120
  @category_max 32
  @statuses ~w(open closed)
  @currency ~r/^[A-Z]{3}$/

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t() | nil,
          body: binary() | nil,
          price_cents: non_neg_integer() | nil,
          currency: String.t() | nil,
          category: String.t() | nil,
          owner_hash: binary() | nil,
          status: String.t() | nil,
          created_day: Date.t() | nil
        }

  schema "listings" do
    field :title, :string
    field :body, :binary
    field :price_cents, :integer
    field :currency, :string
    field :category, :string
    field :owner_hash, :binary
    field :status, :string, default: "open"
    field :created_day, :date
  end

  @doc """
  The storage-level rules, repeated here so a row cannot be written around the
  context. The context validates first and returns a specific error atom; this
  changeset is the second gate, not the message the API speaks.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :title,
      :body,
      :price_cents,
      :currency,
      :category,
      :owner_hash,
      :status,
      :created_day
    ])
    |> validate_required([
      :title,
      :body,
      :currency,
      :category,
      :owner_hash,
      :status,
      :created_day
    ])
    |> validate_length(:title, min: 1, max: @title_max)
    |> validate_length(:category, min: 1, max: @category_max)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_format(:currency, @currency)
    |> validate_inclusion(:status, @statuses)
  end
end
