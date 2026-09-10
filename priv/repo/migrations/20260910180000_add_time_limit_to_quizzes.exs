defmodule Claper.Repo.Migrations.AddTimeLimitToQuizzes do
  use Ecto.Migration

  def change do
    alter table(:quizzes) do
      # Seconds attendees have to answer, counted from the activation of the quiz
      add :time_limit, :integer
      add :started_at, :utc_datetime
    end
  end
end
