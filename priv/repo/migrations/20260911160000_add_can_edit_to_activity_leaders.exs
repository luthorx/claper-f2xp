defmodule Claper.Repo.Migrations.AddCanEditToActivityLeaders do
  use Ecto.Migration

  def up do
    alter table(:activity_leaders) do
      # Lets a facilitator edit the event details, not only run it
      add :can_edit, :boolean, default: false, null: false
    end

    flush()

    # Facilitator addresses are now stored lowercase: keep a single row per event
    # and address before normalizing them
    execute """
    DELETE FROM activity_leaders a
    USING activity_leaders b
    WHERE a.event_id = b.event_id
      AND lower(trim(a.email)) = lower(trim(b.email))
      AND a.id > b.id
    """

    execute "UPDATE activity_leaders SET email = lower(trim(email))"
  end

  def down do
    alter table(:activity_leaders) do
      remove :can_edit
    end
  end
end
