defmodule ClaperWeb.EventLiveTest do
  use ClaperWeb.ConnCase

  import Phoenix.LiveViewTest
  import Claper.{FormsFixtures, PollsFixtures, PresentationsFixtures, QuizzesFixtures}

  @update_attrs %{name: "some updated name"}

  defp create_event(params) do
    presentation_file = presentation_file_fixture(%{user: params.user}, [:event])
    presentation_state_fixture(%{presentation_file: presentation_file})
    params |> Map.put(:presentation_file, presentation_file)
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_event]

    test "lists all events", %{conn: conn, presentation_file: presentation_file} do
      {:ok, _index_live, html} = live(conn, ~p"/events")

      assert html =~ "events"
      assert html =~ presentation_file.event.name
    end

    test "updates event in listing", %{conn: conn, presentation_file: presentation_file} do
      {:ok, index_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")

      {:ok, conn} =
        index_live
        |> form("#event-form", event: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/events")

      assert html_response(conn, 200) =~ "Updated successfully"
      assert html_response(conn, 200) =~ "some updated name"
    end

    test "edits a finished event", %{conn: conn, presentation_file: presentation_file} do
      {:ok, _event} = Claper.Events.terminate_event(presentation_file.event)

      {:ok, index_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")
      assert has_element?(index_live, "#event-editor-title", "Edit event")

      {:ok, conn} =
        index_live
        |> form("#event-form", event: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/events")

      assert html_response(conn, 200) =~ "Updated successfully"
    end

    test "creates an event without a start date", %{conn: conn} do
      {:ok, new_live, _html} = live(conn, ~p"/events/new")

      refute has_element?(new_live, ~s(#date-picker input[type="datetime-local"][required]))

      {:ok, _conn} =
        new_live
        |> form("#event-form", event: %{name: "No start date", code: "nostart1"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/events")

      event = Claper.Events.get_event_with_code("nostart1")
      assert NaiveDateTime.diff(NaiveDateTime.utc_now(), event.started_at) |> abs() < 60
    end

    test "renders the redesigned create and edit states", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, edit_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")

      assert has_element?(edit_live, "#event-editor-title", "Edit event")
      assert has_element?(edit_live, "#presentation-heading", "Presentation")
      assert has_element?(edit_live, "#event-details-heading", "Event details")
      assert has_element?(edit_live, ~s(#date-picker input[type="datetime-local"]))

      assert has_element?(
               edit_live,
               ~s(#date-picker input[name="event[started_at]"][type="hidden"])
             )

      assert has_element?(edit_live, "#facilitators-section")
      assert has_element?(edit_live, "#event-danger-zone", "Delete event")
      assert has_element?(edit_live, ~s(button[form="event-form"]), "Save changes")

      {:ok, new_live, _html} = live(conn, ~p"/events/new")

      assert has_element?(new_live, "#event-editor-title", "Create event")
      assert has_element?(new_live, "#presentation-heading", "Presentation")
      assert has_element?(new_live, ~s(label[for]), "Choose file")
      refute has_element?(new_live, "#facilitators-section")
      refute has_element?(new_live, "#event-danger-zone")
      assert has_element?(new_live, ~s(button[form="event-form"]), "Create event")
    end

    test "uses the user's locale for the native date picker", %{user: user} do
      {:ok, %{locale: "fr"} = user} =
        Claper.Accounts.update_user_preferences(user, %{locale: "fr"})

      conn = build_conn() |> log_in_user(user)
      {:ok, new_live, _html} = live(conn, ~p"/events/new")

      assert has_element?(new_live, ~s(#date-picker input[type="datetime-local"][lang="fr"]))
    end

    test "adds and removes an unsaved facilitator", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, index_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")

      assert has_element?(index_live, "#facilitators-empty-state")

      index_live
      |> element(~s(button[phx-click="add-leader"]))
      |> render_click()

      refute has_element?(index_live, "#facilitators-empty-state")

      assert has_element?(
               index_live,
               ~S|#facilitators-section input[type="email"]:not([readonly])|
             )

      index_live
      |> element(~s(button[phx-click="remove-leader"]))
      |> render_click()

      assert has_element?(index_live, "#facilitators-empty-state")
    end

    test "disables save when event details are invalid", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, index_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")

      index_live
      |> form("#event-form", event: %{name: ""})
      |> render_change()

      assert has_element?(index_live, ~s(button[form="event-form"][disabled]))
    end

    test "keeps the upload active and disables save while a presentation is starting", %{
      conn: conn
    } do
      {:ok, new_live, _html} = live(conn, ~p"/events/new")

      new_live
      |> form("#event-form", event: %{name: "New event"})
      |> render_change()

      upload =
        file_input(new_live, "#file-form", :presentation_file, [
          %{
            name: "slides.pdf",
            content: "%PDF-" <> String.duplicate("0", 95),
            type: "application/pdf"
          }
        ])

      assert render_upload(upload, "slides.pdf", 1) =~ "Uploading... 1%"
      assert has_element?(new_live, ~s(#file-form input[type="file"]))
      assert has_element?(new_live, ~s(button[form="event-form"][disabled]))

      assert render_upload(upload, "slides.pdf", 99) =~ "New presentation ready"
      assert has_element?(new_live, ~s|button[form="event-form"]:not([disabled])|)
    end

    test "does not create an event while a presentation upload is pending", %{conn: conn} do
      {:ok, new_live, _html} = live(conn, ~p"/events/new")
      event_count = Claper.Repo.aggregate(Claper.Events.Event, :count)

      new_live
      |> form("#event-form", event: %{name: "New event"})
      |> render_change()

      upload =
        file_input(new_live, "#file-form", :presentation_file, [
          %{name: "slides.pdf", content: "%PDF-1.4", type: "application/pdf"}
        ])

      assert {:ok, _metadata} = preflight_upload(upload)

      html =
        new_live
        |> form("#event-form", event: %{name: "New event"})
        |> render_submit()

      assert html =~ "Uploading... 0%"
      assert Claper.Repo.aggregate(Claper.Events.Event, :count) == event_count
    end

    test "deletes event in listing", %{conn: conn, presentation_file: presentation_file} do
      {:ok, index_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/edit")

      {:ok, conn} =
        index_live
        |> element(~s{a[phx-click="delete"][phx-value-id=#{presentation_file.event.uuid}]})
        |> render_click()
        |> follow_redirect(conn, ~p"/events")

      {:ok, index_live, _html} = live(conn, ~p"/events")

      refute has_element?(index_live, "#event-#{presentation_file.event.id}")
    end
  end

  defp set_chat_enabled(presentation_file, enabled) do
    Claper.Presentations.PresentationState
    |> Claper.Repo.get_by!(presentation_file_id: presentation_file.id)
    |> Ecto.Changeset.change(chat_enabled: enabled)
    |> Claper.Repo.update!()
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_event]

    test "displays event", %{conn: conn, presentation_file: presentation_file} do
      {:ok, _show_live, html} =
        live(conn, ~p"/e/#{presentation_file.event.code}")

      assert html =~ "Be the first to ask a question or share a thought."
      assert html =~ presentation_file.event.name
    end

    test "keeps the message area next to the slide when messages are enabled", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")

      assert has_element?(show_live, "#post-form")
      assert has_element?(show_live, ~s(#focus-slot[data-focus-fill="false"]))
      assert has_element?(show_live, "[data-focus-collapse]")
    end

    test "fills the room with the slide when messages are disabled", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      set_chat_enabled(presentation_file, false)

      {:ok, show_live, html} = live(conn, ~p"/e/#{presentation_file.event.code}")

      assert has_element?(show_live, ~s(#focus-slot[data-focus-fill="true"]))
      assert has_element?(show_live, "#chat-feed.hidden")
      refute has_element?(show_live, "#room-composer")
      refute has_element?(show_live, "[data-focus-collapse]")
      refute html =~ "Messages deactivated"
    end

    test "switches layout live when the presenter toggles messages", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")
      assert has_element?(show_live, "#post-form")

      send(show_live.pid, {:state_updated, set_chat_enabled(presentation_file, false)})

      assert has_element?(show_live, ~s(#focus-slot[data-focus-fill="true"]))
      refute has_element?(show_live, "#room-composer")

      send(show_live.pid, {:state_updated, set_chat_enabled(presentation_file, true)})

      assert has_element?(show_live, "#post-form")
      assert has_element?(show_live, ~s(#focus-slot[data-focus-fill="false"]))
    end

    test "a single-answer quiz question keeps only the latest choice", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      quiz = quiz_fixture(%{presentation_file: presentation_file, position: 0, enabled: true})
      [first, second] = List.first(quiz.quiz_questions).quiz_question_opts

      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")
      assert has_element?(show_live, "#quiz-selection-hint", "Select one option")

      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(first.id)})
      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(second.id)})

      assert has_element?(
               show_live,
               ~s(button[phx-value-opt="#{second.id}"][aria-pressed="true"])
             )

      assert has_element?(
               show_live,
               ~s(button[phx-value-opt="#{first.id}"][aria-pressed="false"])
             )
    end

    test "a multiple-answer quiz question keeps every choice", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      quiz =
        quiz_fixture(%{
          presentation_file: presentation_file,
          position: 0,
          enabled: true,
          quiz_questions: [
            %{
              content: "Pick both",
              allow_multiple: true,
              quiz_question_opts: [
                %{content: "A", is_correct: true},
                %{content: "B", is_correct: true}
              ]
            }
          ]
        })

      [first, second] = List.first(quiz.quiz_questions).quiz_question_opts

      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")
      assert has_element?(show_live, "#quiz-selection-hint", "Select one or multiple options")

      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(first.id)})
      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(second.id)})

      assert has_element?(show_live, ~s(button[phx-value-opt="#{first.id}"][aria-pressed="true"]))

      assert has_element?(
               show_live,
               ~s(button[phx-value-opt="#{second.id}"][aria-pressed="true"])
             )
    end
  end

  describe "Timed quiz" do
    setup [:register_and_log_in_user, :create_event]

    defp start_timed_quiz(presentation_file, time_limit) do
      quiz =
        quiz_fixture(%{presentation_file: presentation_file, position: 0, time_limit: time_limit})

      {:ok, started} = Claper.Quizzes.set_enabled(quiz.id)
      {quiz, started}
    end

    test "counts down and sends the chosen answers when time is up", %{
      conn: conn,
      user: user,
      presentation_file: presentation_file
    } do
      {quiz, started} = start_timed_quiz(presentation_file, 60)
      [correct, _wrong] = List.first(quiz.quiz_questions).quiz_question_opts

      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")
      assert has_element?(show_live, ~s([id^="quiz-countdown-#{quiz.id}-"]))

      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(correct.id)})
      send(show_live.pid, {:quiz_time_up, quiz.id, Claper.Quizzes.deadline(started)})
      render(show_live)

      assert [%{quiz_question_opt_id: opt_id}] =
               Claper.Quizzes.get_quiz_responses(user.id, quiz.id)

      assert opt_id == correct.id
    end

    test "locks the quiz when time is up", %{
      conn: conn,
      user: user,
      presentation_file: presentation_file
    } do
      {quiz, started} = start_timed_quiz(presentation_file, 30)
      [opt | _] = List.first(quiz.quiz_questions).quiz_question_opts

      started
      |> Ecto.Changeset.change(started_at: DateTime.add(started.started_at, -120))
      |> Claper.Repo.update!()

      {:ok, show_live, _html} = live(conn, ~p"/e/#{presentation_file.event.code}")
      assert has_element?(show_live, "#quiz-time-up", "Time is up")

      render_click(show_live, "select-quiz-question-opt", %{"opt" => to_string(opt.id)})
      render_click(show_live, "submit-quiz", %{})

      assert Claper.Quizzes.get_quiz_responses(user.id, quiz.id) == []
    end

    test "shows the countdown on the presentation and the manage page", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {quiz, _started} = start_timed_quiz(presentation_file, 90)
      code = presentation_file.event.code

      {:ok, presenter_live, _html} = live(conn, ~p"/e/#{code}/presenter")
      assert has_element?(presenter_live, ~s([id^="presenter-quiz-countdown-#{quiz.id}-"]))

      {:ok, manage_live, _html} = live(conn, ~p"/e/#{code}/manage")

      assert has_element?(
               manage_live,
               ~s([id^="settings-pane-interaction-options-quiz-countdown-"])
             )
    end

    test "the quiz editor sets a time limit", %{conn: conn, presentation_file: presentation_file} do
      {:ok, manage_live, _html} =
        live(conn, ~p"/e/#{presentation_file.event.code}/manage/add/quiz")

      assert has_element?(
               manage_live,
               ~s(select[name="quiz[time_limit]"] option[value="120"]),
               "2 min"
             )

      manage_live
      |> form("#form-quiz",
        quiz: %{
          title: "Timed quiz",
          time_limit: "120",
          quiz_questions: %{
            "0" => %{
              content: "Question",
              quiz_question_opts: %{
                "0" => %{content: "A", is_correct: "true"},
                "1" => %{content: "B", is_correct: "false"}
              }
            }
          }
        }
      )
      |> render_submit()

      assert [%{title: "Timed quiz", time_limit: 120}] =
               Claper.Quizzes.list_quizzes_at_position(presentation_file.id, 0)
    end
  end

  describe "Manage" do
    setup [:register_and_log_in_user, :create_event]

    test "quiz editor keeps a single correct answer when multiple answers are off", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, manage_live, _html} =
        live(conn, ~p"/e/#{presentation_file.event.code}/manage/add/quiz")

      change = fn first_correct, second_correct ->
        manage_live
        |> form("#form-quiz",
          quiz: %{
            title: "Quiz",
            quiz_questions: %{
              "0" => %{
                content: "Question",
                allow_multiple: "false",
                quiz_question_opts: %{
                  "0" => %{content: "A", is_correct: first_correct},
                  "1" => %{content: "B", is_correct: second_correct}
                }
              }
            }
          }
        )
        |> render_change()
      end

      change.("true", "false")
      change.("true", "true")

      correct_input = fn index ->
        ~s(input[type="checkbox"][name="quiz[quiz_questions][0][quiz_question_opts][#{index}][is_correct]"][checked])
      end

      refute has_element?(manage_live, correct_input.(0))
      assert has_element?(manage_live, correct_input.(1))
    end

    test "imports the selected interactions of another event", %{
      conn: conn,
      user: user,
      presentation_file: presentation_file
    } do
      source_file = presentation_file_fixture(%{user: user, name: "Previous event"}, [:event])
      poll = poll_fixture(%{presentation_file_id: source_file.id, title: "Reused poll"})
      quiz_fixture(%{presentation_file: source_file, title: "Not selected"})
      manage_path = ~p"/e/#{presentation_file.event.code}/manage"

      {:ok, manage_live, _html} = live(conn, "#{manage_path}/import")

      manage_live
      |> element(~s(button[phx-value-uuid="#{source_file.event.uuid}"]))
      |> render_click()

      assert render(manage_live) =~ "Reused poll"

      manage_live
      |> form("#import-event-form", %{keys: [Claper.Interactions.Import.interaction_key(poll)]})
      |> render_change()

      manage_live |> form("#import-event-form") |> render_submit()

      flash = assert_redirect(manage_live, manage_path)
      assert flash["info"] == "Interactions imported: 1"

      assert [%{title: "Reused poll", enabled: false}] =
               Claper.Polls.list_polls_at_position(presentation_file.id, 0)

      assert Claper.Quizzes.list_quizzes_at_position(presentation_file.id, 0) == []
    end

    test "imports quizzes and polls from a spreadsheet", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      manage_path = ~p"/e/#{presentation_file.event.code}/manage"
      {:ok, manage_live, _html} = live(conn, "#{manage_path}/import")

      manage_live |> element(~s(button[phx-value-tab="file"])) |> render_click()

      upload = fn content ->
        manage_live
        |> file_input("#import-file-form", :spreadsheet, [
          %{name: "interactions.csv", content: content, type: "text/csv"}
        ])
        |> render_upload("interactions.csv")

        manage_live |> form("#import-file-form") |> render_submit()
      end

      assert upload.("POLL;Only one answer;;;;A\n") =~ "Row 1: at least two answers are required"

      assert upload.("POLL;Coffee or tea?;;;;Coffee;Tea\nQUIZ;Maths;2 + 2?;;1;4;5\n") =~
               "Coffee or tea?"

      manage_live |> element(~s(button[phx-click="import-file"])) |> render_click()

      flash = assert_redirect(manage_live, manage_path)
      assert flash["info"] == "Interactions imported: 2"

      assert [%{title: "Coffee or tea?"}] =
               Claper.Polls.list_polls_at_position(presentation_file.id, 0)

      assert [%{title: "Maths"}] =
               Claper.Quizzes.list_quizzes_at_position(presentation_file.id, 0)
    end

    test "deletes the current slide and keeps the interactions", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      poll_fixture(%{presentation_file_id: presentation_file.id, position: 1, title: "Kept poll"})
      code = presentation_file.event.code
      {:ok, attendee_live, _html} = live(conn, ~p"/e/#{code}")
      {:ok, manage_live, _html} = live(conn, ~p"/e/#{code}/manage")

      html =
        manage_live
        |> element(~s(button[phx-click="delete-slide"][phx-value-position="0"]))
        |> render_click()

      assert html =~ "Slide deleted"
      assert html =~ "Kept poll"
      assert Claper.Presentations.get_presentation_file!(presentation_file.id).length == 41
      # The attendee view reloads its slides without crashing
      assert render(attendee_live) =~ presentation_file.event.name
    end

    test "prompts to regenerate missing thumbnails and starts regeneration", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, manage_live, html} = live(conn, ~p"/e/#{presentation_file.event.code}/manage")

        assert html =~ "No thumbnails are available"
        assert html =~ "Regenerate thumbnails"

        manage_live
        |> element(~s{button[phx-click="regenerate-thumbnails"]})
        |> render_click()

        assert render(manage_live) =~ "Thumbnail regeneration started"
      end)
    end
  end

  describe "Stats" do
    setup [:register_and_log_in_user, :create_event]

    test "hides interaction tabs that have no content", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      {:ok, _stats_live, html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/stats")

      refute html =~ ~s(phx-value-tab="messages")
      refute html =~ ~s(phx-value-tab="polls")
      refute html =~ ~s(phx-value-tab="forms")
      refute html =~ ~s(phx-value-tab="web_content")
      refute html =~ ~s(phx-value-tab="quizzes")
      refute html =~ ~s(phx-value-tab="transcriptions")
    end

    test "displays transcriptions in report", %{conn: conn, presentation_file: presentation_file} do
      {:ok, _transcription} =
        Claper.Transcriptions.create_transcription(%{
          presentation_file_id: presentation_file.id,
          language: "en",
          text: "Welcome to the event"
        })

      {:ok, stats_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/stats")

      html =
        stats_live
        |> element(~s{button[phx-value-tab="transcriptions"]})
        |> render_click()

      assert html =~ "Transcriptions"
      assert html =~ "Welcome to the event"
      assert html =~ "UTC"
    end

    test "loads more transcriptions in report", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      for index <- 1..26 do
        {:ok, _transcription} =
          Claper.Transcriptions.create_transcription(%{
            presentation_file_id: presentation_file.id,
            language: "en",
            text: "Transcript segment #{index}"
          })
      end

      {:ok, stats_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/stats")

      html =
        stats_live
        |> element(~s{button[phx-value-tab="transcriptions"]})
        |> render_click()

      assert html =~ "Transcriptions"
      assert html =~ "Transcript segment 1"
      refute html =~ "Transcript segment 26"
      assert html =~ "Load more"

      html =
        stats_live
        |> element(~s{button[phx-click="load_more_transcriptions"]})
        |> render_click()

      assert html =~ "Transcript segment 1"
      assert html =~ "Transcript segment 26"
      refute html =~ "Load more"
    end

    test "displays emoji avatars for form submissions in report", %{
      conn: conn,
      presentation_file: presentation_file
    } do
      form = form_fixture(%{presentation_file_id: presentation_file.id})

      {:ok, _form_submit} =
        Claper.Forms.create_form_submit(%{
          form_id: form.id,
          attendee_identifier: "attendee-1",
          response: %{"Name" => "Ada"}
        })

      {:ok, stats_live, _html} = live(conn, ~p"/events/#{presentation_file.event.uuid}/stats")

      html =
        stats_live
        |> element(~s{button[phx-value-tab="forms"]})
        |> render_click()

      assert html =~ "Ada"
      assert html =~ "avatar avatar-placeholder"
    end
  end

  describe "Join" do
    test "renders the join page", %{conn: conn} do
      {:ok, join_live, html} = live(conn, ~p"/")

      assert html =~ "Join the event"
      assert html =~ "Enter the code shared by the presenter"
      assert html =~ "Are you a presenter?"
      assert html =~ "Start creating for free"
      refute html =~ "Turn your slides into conversations"

      assert has_element?(join_live, "#form")
      assert has_element?(join_live, "#input[placeholder='ABCD1234']")
    end
  end
end
