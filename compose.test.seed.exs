# Evento di test per l'ambiente locale (compose.test.yml):
# quiz con domande, sondaggio e domande del pubblico.
#
#   docker compose -f compose.test.yml cp compose.test.seed.exs app:/tmp/test_event.exs
#   docker compose -f compose.test.yml exec app /app/bin/claper rpc 'Code.eval_file("/tmp/test_event.exs")'
#
# Usa le funzioni dei context (come la UI), quindi valida i dati e notifica le pagine aperte.
# Rieseguibile: se l'evento con lo stesso codice esiste già non crea nulla.

alias Claper.{Accounts, Events, Polls, Posts, Quizzes}

code = "f2xptest"
owner_email = "admin@claper.co"

ok! = fn
  {:ok, value}, _what -> value
  {:ok, value, _}, _what -> value
  {:error, reason}, what -> raise "Creazione #{what} fallita: #{inspect(reason)}"
  other, _what -> other
end

owner =
  Accounts.get_user_by_email(owner_email) ||
    raise "Utente #{owner_email} non trovato: il seed iniziale è stato eseguito?"

case Events.get_event_with_code(code) do
  %Events.Event{} = event ->
    IO.puts("Evento con codice #{code} già presente (id #{event.id}): nessuna modifica")

  nil ->
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    event =
      Events.create_event(%{
        "name" => "Evento di test F2XP",
        "code" => code,
        "user_id" => owner.id,
        "started_at" => now,
        "expired_at" => NaiveDateTime.add(now, 30 * 24 * 3600, :second),
        # evento senza slide, come quando si crea dalla UI senza caricare un file
        "presentation_file" => %{"status" => "done", "length" => 0, "presentation_state" => %{}}
      })
      |> ok!.("evento")

    event = Events.get_event!(event.uuid, [:presentation_file])
    presentation_file_id = event.presentation_file.id

    opts = fn answers ->
      Enum.map(answers, fn {content, correct} ->
        %{"content" => content, "is_correct" => correct}
      end)
    end

    Quizzes.create_quiz(%{
      "title" => "Quiz di prova",
      "position" => 0,
      "presentation_file_id" => presentation_file_id,
      "enabled" => false,
      "show_results" => true,
      "allow_anonymous" => true,
      "quiz_questions" => [
        %{
          "content" => "Qual è la capitale d'Italia?",
          "type" => "qcm",
          "quiz_question_opts" =>
            opts.([{"Roma", true}, {"Milano", false}, {"Napoli", false}, {"Torino", false}])
        },
        %{
          "content" => "Quanti giorni ha una settimana?",
          "type" => "qcm",
          "quiz_question_opts" => opts.([{"5", false}, {"6", false}, {"7", true}, {"8", false}])
        },
        %{
          "content" => "Quali di questi sono linguaggi di programmazione?",
          "type" => "qcm",
          "quiz_question_opts" =>
            opts.([{"Elixir", true}, {"Python", true}, {"Photoshop", false}, {"Excel", false}])
        }
      ]
    })
    |> ok!.("quiz")

    Polls.create_poll(%{
      "title" => "Come valuti questa presentazione di prova?",
      "position" => 0,
      "presentation_file_id" => presentation_file_id,
      "enabled" => false,
      "multiple" => false,
      "show_results" => true,
      "poll_opts" =>
        Enum.map(["Ottima", "Buona", "Sufficiente", "Da migliorare"], fn content ->
          %{"content" => content, "vote_count" => 0}
        end)
    })
    |> ok!.("sondaggio")

    [
      {"Marco", "Si possono caricare le slide in PowerPoint o solo in PDF?", false},
      {"Giulia", "Le risposte al quiz restano anonime?", true},
      {nil, "È possibile esportare i risultati dei sondaggi in Excel?", false},
      {"Luca", "Quante persone possono partecipare contemporaneamente?", false}
    ]
    |> Enum.each(fn {name, body, pinned} ->
      Posts.create_post(event, %{
        "body" => body,
        "name" => name,
        "attendee_identifier" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "position" => 0,
        "pinned" => pinned
      })
      |> ok!.("domanda del pubblico")
    end)

    IO.puts("""
    Creato "#{event.name}" (codice #{code}) per #{owner_email}:
      - quiz con 3 domande, sondaggio con 4 opzioni, 4 domande del pubblico (1 in evidenza)
      Partecipanti: http://localhost:4000/e/#{code}
      Gestione:     http://localhost:4000/events
    """)
end
