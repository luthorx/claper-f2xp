defmodule Claper.Repo.Migrations.AddAllowMultipleToQuizQuestions do
  use Ecto.Migration

  def up do
    alter table(:quiz_questions) do
      add :allow_multiple, :boolean, default: false, null: false
    end

    flush()

    # Questions that already have several correct answers keep accepting multiple choices
    execute """
    UPDATE quiz_questions
    SET allow_multiple = true
    WHERE (
      SELECT count(*) FROM quiz_question_opts o
      WHERE o.quiz_question_id = quiz_questions.id AND o.is_correct
    ) > 1
    """
  end

  def down do
    alter table(:quiz_questions) do
      remove :allow_multiple
    end
  end
end
