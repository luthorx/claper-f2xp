defmodule Claper.Repo.Migrations.CreateQuizParticipations do
  use Ecto.Migration

  def change do
    # Who is answering a quiz and how far they got, for the facilitator
    create table(:quiz_participations) do
      add :quiz_id, references(:quizzes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :attendee_identifier, :string
      add :name, :string
      add :answered_count, :integer, null: false, default: 0
      add :score, :integer
      add :completed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:quiz_participations, [:quiz_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :quiz_participations_quiz_id_user_id_index
           )

    create unique_index(:quiz_participations, [:quiz_id, :attendee_identifier],
             where: "attendee_identifier IS NOT NULL",
             name: :quiz_participations_quiz_id_attendee_identifier_index
           )
  end
end
