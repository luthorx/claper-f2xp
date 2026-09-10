defmodule Claper.Interactions.ImportTest do
  use Claper.DataCase

  import Claper.{
    AccountsFixtures,
    EmbedsFixtures,
    EventsFixtures,
    FormsFixtures,
    PollsFixtures,
    PresentationsFixtures,
    QuizzesFixtures
  }

  alias Claper.{Embeds, Forms, Polls, Quizzes}
  alias Claper.Interactions.Import

  setup do
    user = user_fixture()
    source_file = presentation_file_fixture(%{user: user}, [:event])
    target_file = presentation_file_fixture(%{user: user, length: 5}, [:event])

    %{
      user: user,
      source: source_file.event,
      target: Claper.Events.get_event!(target_file.event.id, [:presentation_file]),
      poll: poll_fixture(%{presentation_file_id: source_file.id, position: 7}),
      quiz: quiz_fixture(%{presentation_file: source_file, position: 2}),
      form: form_fixture(%{presentation_file_id: source_file.id, position: 1}),
      embed: embed_fixture(%{presentation_file_id: source_file.id, position: 0})
    }
  end

  test "lists the events the user owns or co-leads, except the target one", %{
    user: user,
    source: source,
    target: target
  } do
    other_user = user_fixture()
    led_event = event_fixture(%{user: other_user})
    activity_leader_fixture(%{event: led_event, user: user})
    foreign_event = event_fixture(%{user: other_user})

    ids = user |> Import.list_source_events(target) |> Enum.map(& &1.id)

    assert source.id in ids
    assert led_event.id in ids
    refute target.id in ids
    refute foreign_event.id in ids
  end

  test "lists the interactions of a source event by slide", %{user: user, source: source} = ctx do
    assert {:ok, _source, interactions} = Import.get_source(user, source.uuid)

    assert Enum.map(interactions, &Import.interaction_key/1) ==
             Enum.map([ctx.embed, ctx.form, ctx.quiz, ctx.poll], &Import.interaction_key/1)
  end

  test "copies the selected interactions disabled on the given slide, without results",
       %{user: user, source: source, target: target} = ctx do
    Repo.update_all(Claper.Polls.PollOpt, set: [vote_count: 5])
    keys = Enum.map([ctx.poll, ctx.quiz, ctx.form, ctx.embed], &Import.interaction_key/1)

    assert {:ok, created} = Import.import_from_event(user, source.uuid, target, keys, position: 3)
    assert length(created) == 4
    assert Enum.all?(created, &(&1.position == 3 and &1.enabled == false))

    file_id = target.presentation_file.id

    assert [poll] = Polls.list_polls_at_position(file_id, 3)
    assert poll.title == ctx.poll.title
    assert Enum.map(poll.poll_opts, & &1.vote_count) == [0, 0]

    assert [quiz] = Quizzes.list_quizzes_at_position(file_id, 3)

    assert [
             %{
               content: "some question content",
               quiz_question_opts: [%{is_correct: true}, %{is_correct: false}]
             }
           ] = quiz.quiz_questions

    assert [%{fields: [%{name: "Name"}]}] = Forms.list_forms_at_position(file_id, 3)
    assert [%{content: content}] = Embeds.list_embeds_at_position(file_id, 3)
    assert content == ctx.embed.content
  end

  test "can keep the original slides, within the slides of the target", %{
    user: user,
    source: source,
    target: target,
    poll: poll,
    quiz: quiz
  } do
    keys = [Import.interaction_key(poll), Import.interaction_key(quiz)]

    assert {:ok, created} =
             Import.import_from_event(user, source.uuid, target, keys,
               position: 0,
               keep_positions: true
             )

    assert created |> Enum.map(& &1.position) |> Enum.sort() == [2, 4]
  end

  test "only imports from events the user can manage", %{
    user: user,
    source: source,
    target: target,
    poll: poll
  } do
    keys = [Import.interaction_key(poll)]

    assert {:error, :not_found} =
             Import.import_from_event(user_fixture(), source.uuid, target, keys, position: 0)

    assert {:error, :not_found} =
             Import.import_from_event(user, "not-a-uuid", target, keys, position: 0)

    assert {:error, :nothing_selected} =
             Import.import_from_event(user, source.uuid, target, [], position: 0)
  end

  test "creates the quizzes and polls of a spreadsheet and notifies the managers", %{
    target: target
  } do
    Claper.Events.Event.subscribe(target.uuid)

    items = [
      %{type: :poll, title: "Coffee or tea?", multiple: true, options: ["Coffee", "Tea"]},
      %{
        type: :quiz,
        title: "Maths",
        questions: [
          %{
            content: "2 + 2?",
            allow_multiple: false,
            options: [%{content: "4", is_correct: true}, %{content: "5", is_correct: false}]
          }
        ]
      }
    ]

    assert {:ok, [poll, quiz]} = Import.import_items(target, items, 9)
    assert_receive {:interactions_imported, [_poll, _quiz]}

    assert %{position: 4, multiple: true, enabled: false} = poll
    assert Enum.map(poll.poll_opts, & &1.content) == ["Coffee", "Tea"]

    assert %{position: 4, enabled: false} = quiz

    assert [
             %{
               allow_multiple: false,
               quiz_question_opts: [%{is_correct: true}, %{is_correct: false}]
             }
           ] =
             quiz.quiz_questions
  end

  test "imports nothing when an interaction is invalid", %{target: target} do
    items = [
      %{type: :poll, title: "Valid", multiple: false, options: ["A", "B"]},
      %{
        type: :quiz,
        title: "Invalid",
        questions: [
          %{
            content: "Two correct answers without multiple answers",
            allow_multiple: false,
            options: [%{content: "A", is_correct: true}, %{content: "B", is_correct: true}]
          }
        ]
      }
    ]

    assert {:error, %Ecto.Changeset{}} = Import.import_items(target, items, 0)
    assert Polls.list_polls_at_position(target.presentation_file.id, 0) == []
  end
end
