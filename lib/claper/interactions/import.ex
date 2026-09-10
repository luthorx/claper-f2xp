defmodule Claper.Interactions.Import do
  @moduledoc """
  Imports interactions into an event, copied from another event the user can
  manage or built from a spreadsheet (see `Claper.Interactions.Spreadsheet`).

  Imported interactions always start disabled, so nothing goes live by
  surprise, and never bring along votes, answers or submissions.
  """

  alias Claper.{Events, Repo}
  alias Claper.Accounts.User
  alias Claper.Embeds.Embed
  alias Claper.Events.Event
  alias Claper.Forms.Form
  alias Claper.Polls.Poll
  alias Claper.Quizzes.Quiz

  @source_preload [
    presentation_file: [
      polls: [:poll_opts],
      quizzes: [quiz_questions: [:quiz_question_opts]],
      forms: [],
      embeds: []
    ]
  ]

  @doc """
  Lists the events, owned or co-led by the user, that interactions can be
  imported from into `target`.
  """
  def list_source_events(%User{} = user, %Event{} = target) do
    (Events.list_events(user.id) ++ Events.list_managed_events_by(user.email))
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id == target.id))
    |> Enum.sort_by(& &1.id, :desc)
  end

  @doc """
  Gets an event the user can manage along with its interactions, ordered by slide.

  Returns `{:ok, event, interactions}` or `{:error, :not_found}`.
  """
  def get_source(%User{} = user, event_uuid) do
    event = Events.get_managed_event!(user, event_uuid, @source_preload)
    {:ok, event, interactions(event)}
  rescue
    _error in [Ecto.NoResultsError, Ecto.Query.CastError] -> {:error, :not_found}
  end

  @doc """
  Identifies an interaction among those of an event, whatever its type.
  """
  def interaction_key(%Poll{id: id}), do: "poll-#{id}"
  def interaction_key(%Quiz{id: id}), do: "quiz-#{id}"
  def interaction_key(%Form{id: id}), do: "form-#{id}"
  def interaction_key(%Embed{id: id}), do: "embed-#{id}"

  @doc """
  Copies the interactions of another event whose `interaction_key/1` is in `keys`.

  ## Options

    * `:position` - the slide of `target` to add them to (required)
    * `:keep_positions` - keep the slides they have in the source event instead

  Returns `{:ok, interactions}` or `{:error, reason}`.
  """
  def import_from_event(%User{} = user, event_uuid, %Event{} = target, keys, opts) do
    keys = MapSet.new(keys)

    with {:ok, _source, interactions} <- get_source(user, event_uuid) do
      interactions
      |> Enum.filter(&MapSet.member?(keys, interaction_key(&1)))
      |> Enum.map(fn interaction ->
        position =
          if opts[:keep_positions],
            do: interaction.position,
            else: Keyword.fetch!(opts, :position)

        copy(interaction, slide_position(target, position))
      end)
      |> insert_all(target)
    end
  end

  @doc """
  Creates the quizzes and polls read from a spreadsheet on the given slide.

  Returns `{:ok, interactions}` or `{:error, reason}`.
  """
  def import_items(%Event{} = target, items, position) do
    position = slide_position(target, position)

    items
    |> Enum.map(&from_item(&1, position))
    |> insert_all(target)
  end

  defp interactions(%Event{presentation_file: %{} = presentation_file}) do
    (presentation_file.polls ++
       presentation_file.quizzes ++ presentation_file.forms ++ presentation_file.embeds)
    |> Enum.sort_by(&{&1.position, NaiveDateTime.to_iso8601(&1.inserted_at)})
  end

  defp interactions(_event), do: []

  # The target presentation can have fewer slides than the source one
  defp slide_position(%Event{presentation_file: presentation_file}, position) do
    last = max((presentation_file.length || 0) - 1, 0)
    position |> max(0) |> min(last)
  end

  defp copy(%Poll{} = poll, position) do
    {Poll,
     %{
       title: poll.title,
       multiple: poll.multiple,
       show_results: poll.show_results,
       position: position,
       enabled: false,
       poll_opts: Enum.map(poll.poll_opts, &%{content: &1.content, vote_count: 0})
     }}
  end

  defp copy(%Quiz{} = quiz, position) do
    {Quiz,
     %{
       title: quiz.title,
       show_results: quiz.show_results,
       allow_anonymous: quiz.allow_anonymous,
       time_limit: quiz.time_limit,
       position: position,
       enabled: false,
       quiz_questions:
         Enum.map(quiz.quiz_questions, fn question ->
           %{
             content: question.content,
             type: question.type,
             allow_multiple: question.allow_multiple,
             quiz_question_opts:
               Enum.map(
                 question.quiz_question_opts,
                 &%{content: &1.content, is_correct: &1.is_correct}
               )
           }
         end)
     }}
  end

  defp copy(%Form{} = form, position) do
    {Form,
     %{
       title: form.title,
       position: position,
       enabled: false,
       fields: Enum.map(form.fields, &%{name: &1.name, type: &1.type, required: &1.required})
     }}
  end

  defp copy(%Embed{} = embed, position) do
    {Embed,
     %{
       title: embed.title,
       content: embed.content,
       provider: embed.provider,
       attendee_visibility: embed.attendee_visibility,
       position: position,
       enabled: false
     }}
  end

  defp from_item(%{type: :poll} = poll, position) do
    {Poll,
     %{
       title: poll.title,
       multiple: poll.multiple,
       show_results: true,
       position: position,
       enabled: false,
       poll_opts: Enum.map(poll.options, &%{content: &1, vote_count: 0})
     }}
  end

  defp from_item(%{type: :quiz} = quiz, position) do
    {Quiz,
     %{
       title: quiz.title,
       position: position,
       enabled: false,
       quiz_questions:
         Enum.map(quiz.questions, fn question ->
           %{
             content: question.content,
             type: "qcm",
             allow_multiple: question.allow_multiple,
             quiz_question_opts: question.options
           }
         end)
     }}
  end

  defp insert_all([], _target), do: {:error, :nothing_selected}

  defp insert_all(entries, %Event{} = target) do
    Repo.transaction(fn ->
      Enum.map(entries, fn {schema, attrs} ->
        attrs = Map.put(attrs, :presentation_file_id, target.presentation_file.id)

        case schema |> struct() |> schema.changeset(attrs) |> Repo.insert() do
          {:ok, interaction} -> interaction
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
    |> case do
      {:ok, interactions} ->
        # Lets the managers of the event refresh their interaction list;
        # attendees are not affected since imported interactions are disabled
        Phoenix.PubSub.broadcast(
          Claper.PubSub,
          "event:#{target.uuid}",
          {:interactions_imported, interactions}
        )

        {:ok, interactions}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
