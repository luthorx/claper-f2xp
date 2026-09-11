defmodule Claper.Events.ActivityLeader do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          temp_id: String.t() | nil,
          delete: boolean() | nil,
          user_id: integer() | nil,
          user_email: String.t() | nil,
          email: String.t(),
          can_edit: boolean(),
          event_id: integer(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "activity_leaders" do
    field :temp_id, :string, virtual: true
    field :delete, :boolean, virtual: true

    field :user_id, :integer, virtual: true
    field :user_email, :string, virtual: true

    field :email, :string
    # Besides running the event, the facilitator can edit, terminate and reactivate it
    field :can_edit, :boolean, default: false
    belongs_to :event, Claper.Events.Event

    timestamps()
  end

  @doc false
  def changeset(leader, attrs) do
    leader
    |> Map.put(:temp_id, leader.temp_id || attrs["temp_id"])
    |> cast(attrs, [
      :email,
      :event_id,
      :delete,
      :user_email,
      :can_edit
    ])
    |> normalize_email()
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, min: 6, max: 160)
    |> unique_constraint(:email, name: :activity_leaders_event_id_email_index)
    |> validate_not_current_user_email
    |> unsafe_validate_unique([:event_id, :email], Claper.Repo)
    |> maybe_mark_for_deletion
  end

  # Addresses are matched with accounts regardless of case
  defp normalize_email(changeset) do
    update_change(changeset, :email, fn
      email when is_binary(email) -> email |> String.trim() |> String.downcase()
      email -> email
    end)
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end

  defp validate_not_current_user_email(changeset) do
    email = get_field(changeset, :email)
    user_email = get_change(changeset, :user_email)

    if is_binary(user_email) and email == String.downcase(user_email) do
      add_error(changeset, :email, "cannot be the same as the current user's email")
    else
      changeset
    end
  end
end
