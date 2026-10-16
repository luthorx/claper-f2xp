defmodule Claper.Quizzes.QuizParticipation do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer(),
          attendee_identifier: String.t() | nil,
          name: String.t() | nil,
          answered_count: integer(),
          score: integer() | nil,
          completed_at: DateTime.t() | nil,
          quiz: Claper.Quizzes.Quiz.t() | nil,
          user: Claper.Accounts.User.t() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "quiz_participations" do
    field :attendee_identifier, :string
    field :name, :string
    field :answered_count, :integer, default: 0
    field :score, :integer
    field :completed_at, :utc_datetime

    belongs_to :quiz, Claper.Quizzes.Quiz
    belongs_to :user, Claper.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(participation, attrs) do
    participation
    |> cast(attrs, [
      :quiz_id,
      :user_id,
      :attendee_identifier,
      :name,
      :answered_count,
      :score,
      :completed_at
    ])
    |> validate_required([:quiz_id, :answered_count])
  end
end
