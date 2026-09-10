defmodule ClaperWeb.EventLive.ManageImportComponent do
  @moduledoc """
  Imports interactions into the managed event, from another event or from a
  spreadsheet, on the current slide.
  """
  use ClaperWeb, :live_component

  alias Claper.Interactions.{Import, Spreadsheet}

  @max_file_size 2_000_000
  @shown_errors 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       tab: "event",
       search: "",
       source: nil,
       source_interactions: [],
       selected: MapSet.new(),
       keep_positions: false,
       file_items: nil,
       file_errors: [],
       import_error: nil
     )
     |> allow_upload(:spreadsheet,
       accept: ~w(.xlsx .csv),
       max_entries: 1,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:source_events, fn ->
       Import.list_source_events(assigns.current_user, assigns.event)
     end)}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["event", "file"] do
    {:noreply, assign(socket, tab: tab, import_error: nil)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, :search, search)}
  end

  def handle_event("select-event", %{"uuid" => uuid}, socket) do
    case Import.get_source(socket.assigns.current_user, uuid) do
      {:ok, source, interactions} ->
        {:noreply,
         assign(socket,
           source: source,
           source_interactions: interactions,
           selected: MapSet.new(),
           import_error: nil
         )}

      {:error, :not_found} ->
        {:noreply, assign(socket, :import_error, gettext("Event doesn't exist"))}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply,
     assign(socket,
       source: nil,
       source_interactions: [],
       selected: MapSet.new(),
       import_error: nil
     )}
  end

  def handle_event("change-selection", params, socket) do
    selected =
      params
      |> Map.get("keys", [])
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    {:noreply,
     assign(socket, selected: selected, keep_positions: params["keep_positions"] == "true")}
  end

  def handle_event("toggle-all", _params, socket) do
    all = MapSet.new(socket.assigns.source_interactions, &Import.interaction_key/1)
    selected = if MapSet.equal?(socket.assigns.selected, all), do: MapSet.new(), else: all

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("import-event", _params, %{assigns: assigns} = socket) do
    assigns.current_user
    |> Import.import_from_event(
      assigns.source.uuid,
      assigns.event,
      MapSet.to_list(assigns.selected),
      position: assigns.position,
      keep_positions: assigns.keep_positions
    )
    |> imported(socket)
  end

  def handle_event("validate-file", _params, socket) do
    {:noreply, assign(socket, :file_errors, [])}
  end

  def handle_event("cancel-file", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :spreadsheet, ref)}
  end

  def handle_event("check-file", _params, socket) do
    results =
      consume_uploaded_entries(socket, :spreadsheet, fn %{path: path}, entry ->
        {:ok, read_items(path, entry.client_name)}
      end)

    case results do
      [{:ok, items}] ->
        {:noreply, assign(socket, file_items: items, file_errors: [])}

      [{:error, errors}] ->
        {:noreply, assign(socket, file_items: nil, file_errors: errors)}

      [] ->
        {:noreply, assign(socket, :file_errors, [gettext("Choose a file to import.")])}
    end
  end

  def handle_event("import-file", _params, %{assigns: assigns} = socket) do
    assigns.event
    |> Import.import_items(assigns.file_items || [], assigns.position)
    |> imported(socket)
  end

  def handle_event("reset-file", _params, socket) do
    {:noreply, assign(socket, file_items: nil, file_errors: [], import_error: nil)}
  end

  defp read_items(path, filename) do
    case Spreadsheet.read_rows(path, filename) do
      {:ok, rows} -> Spreadsheet.to_items(rows)
      {:error, message} -> {:error, [message]}
    end
  end

  defp imported({:ok, interactions}, socket) do
    send(self(), {:import_completed, length(interactions)})
    {:noreply, socket}
  end

  defp imported({:error, :nothing_selected}, socket) do
    {:noreply,
     assign(socket, :import_error, gettext("Select at least one interaction to import."))}
  end

  defp imported({:error, _reason}, socket) do
    {:noreply, assign(socket, :import_error, gettext("The interactions could not be imported."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="scroll-py-3 overflow-y-auto p-6">
      <p class="text-base font-bold text-secondary mb-1">{gettext("Import interactions")}</p>
      <p class="text-sm text-gray-500 mb-5">
        {if @tab == "event" and @keep_positions,
          do:
            gettext(
              "Interactions keep the slides of the original event and stay disabled until you activate them."
            ),
          else:
            gettext(
              "Interactions are added to slide %{number} and stay disabled until you activate them.",
              number: @position + 1
            )}
      </p>

      <div role="tablist" class="flex gap-1 rounded-xl bg-gray-100 p-1 mb-5">
        <button
          :for={
            {tab, label} <- [{"event", gettext("From an event")}, {"file", gettext("From a file")}]
          }
          type="button"
          role="tab"
          aria-selected={to_string(@tab == tab)}
          phx-click="tab"
          phx-value-tab={tab}
          phx-target={@myself}
          class={[
            "flex-1 rounded-lg px-3 py-2 text-sm font-bold transition-colors",
            if(@tab == tab,
              do: "bg-white text-secondary shadow-sm",
              else: "text-gray-500 hover:text-gray-700"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <p :if={@import_error} class="mb-4 rounded-xl bg-red-50 p-3 text-sm text-red-700">
        {@import_error}
      </p>

      <div :if={@tab == "event"}>
        <%= cond do %>
          <% @source -> %>
            <button
              type="button"
              phx-click="back"
              phx-target={@myself}
              class="mb-2 text-sm font-bold text-primary-500 hover:text-primary-600"
            >
              &larr; {gettext("Other events")}
            </button>
            <p class="font-bold text-gray-800 mb-3 truncate">{@source.name}</p>

            <p :if={@source_interactions == []} class="text-sm text-gray-500">
              {gettext("This event has no interactions.")}
            </p>

            <form
              :if={@source_interactions != []}
              id="import-event-form"
              phx-change="change-selection"
              phx-submit="import-event"
              phx-target={@myself}
            >
              <input type="hidden" name="keys[]" value="" />
              <div class="flex items-center justify-between mb-2">
                <span class="text-xs text-gray-500">
                  {gettext("%{selected} of %{total} selected",
                    selected: MapSet.size(@selected),
                    total: length(@source_interactions)
                  )}
                </span>
                <button
                  type="button"
                  phx-click="toggle-all"
                  phx-target={@myself}
                  class="text-xs font-bold text-primary-500 hover:text-primary-600"
                >
                  {if MapSet.size(@selected) == length(@source_interactions),
                    do: gettext("Deselect all"),
                    else: gettext("Select all")}
                </button>
              </div>

              <div class="flex flex-col gap-3 max-h-80 overflow-y-auto pr-1">
                <div :for={{position, interactions} <- group_by_slide(@source_interactions)}>
                  <p class="text-xs font-bold uppercase text-gray-400 mb-1">
                    {gettext("Slide %{number}", number: position + 1)}
                  </p>
                  <label
                    :for={interaction <- interactions}
                    class="flex items-center gap-3 rounded-xl border border-gray-200 px-3 py-2 mb-1 cursor-pointer hover:bg-gray-50"
                  >
                    <input
                      type="checkbox"
                      name="keys[]"
                      value={Import.interaction_key(interaction)}
                      checked={MapSet.member?(@selected, Import.interaction_key(interaction))}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="min-w-0">
                      <span class="block font-bold text-sm text-gray-800 truncate">
                        {interaction.title}
                      </span>
                      <span class="block text-xs text-gray-500">{describe(interaction)}</span>
                    </span>
                  </label>
                </div>
              </div>

              <label
                :if={@event.presentation_file.length > 1}
                class="flex items-center gap-2 mt-4 text-sm text-gray-700 cursor-pointer"
              >
                <input
                  type="checkbox"
                  name="keep_positions"
                  value="true"
                  checked={@keep_positions}
                  class="checkbox checkbox-sm"
                />
                {gettext("Keep the slides of the original event")}
              </label>

              <button
                type="submit"
                disabled={MapSet.size(@selected) == 0}
                class="btn btn-primary w-full mt-5"
              >
                {gettext("Import selected interactions")}
              </button>
            </form>
          <% @source_events == [] -> %>
            <p class="text-sm text-gray-500">
              {gettext("You have no other events to import from.")}
            </p>
          <% true -> %>
            <form phx-change="search" phx-submit="search" phx-target={@myself} class="mb-3">
              <input
                type="search"
                name="search"
                value={@search}
                placeholder={gettext("Search an event")}
                phx-debounce="200"
                autocomplete="off"
                class="input input-bordered w-full"
              />
            </form>
            <ul id="import-source-events" class="flex flex-col gap-2 max-h-80 overflow-y-auto">
              <li :for={source <- filter_events(@source_events, @search)}>
                <button
                  type="button"
                  phx-click="select-event"
                  phx-value-uuid={source.uuid}
                  phx-target={@myself}
                  class="w-full flex items-center justify-between gap-3 rounded-xl border border-gray-200 px-3 py-2 text-left hover:bg-primary-50"
                >
                  <span class="min-w-0">
                    <span class="block font-bold text-sm text-gray-800 truncate">
                      {source.name}
                    </span>
                    <span class="block text-xs text-gray-500 uppercase">#{source.code}</span>
                  </span>
                  <span :if={source.expired_at} class="badge badge-sm badge-ghost shrink-0">
                    {gettext("Finished")}
                  </span>
                </button>
              </li>
            </ul>
        <% end %>
      </div>

      <div :if={@tab == "file"}>
        <p class="text-sm text-gray-600 mb-3">
          {gettext(
            "Import quizzes and polls from an Excel (.xlsx) or CSV file, one row for each quiz question or poll."
          )}
        </p>
        <a href={~p"/import/template"} download class="btn btn-sm btn-outline mb-5">
          {gettext("Download the template")}
        </a>

        <%= if @file_items do %>
          <p class="text-sm font-bold text-gray-800 mb-2">{gettext("Ready to import:")}</p>
          <ul id="import-file-items" class="flex flex-col gap-1 max-h-72 overflow-y-auto mb-5">
            <li :for={item <- @file_items} class="rounded-xl border border-gray-200 px-3 py-2">
              <span class="block font-bold text-sm text-gray-800 truncate">{item.title}</span>
              <span class="block text-xs text-gray-500">{describe(item)}</span>
            </li>
          </ul>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="reset-file"
              phx-target={@myself}
              class="btn btn-ghost flex-1"
            >
              {gettext("Choose another file")}
            </button>
            <button
              type="button"
              phx-click="import-file"
              phx-target={@myself}
              class="btn btn-primary flex-1"
            >
              {gettext("Import")}
            </button>
          </div>
        <% else %>
          <form
            id="import-file-form"
            phx-change="validate-file"
            phx-submit="check-file"
            phx-target={@myself}
          >
            <label
              phx-drop-target={@uploads.spreadsheet.ref}
              class="flex flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-gray-300 px-4 py-6 text-center cursor-pointer hover:bg-gray-50"
            >
              <.live_file_input upload={@uploads.spreadsheet} class="sr-only" />
              <span class="text-sm font-bold text-gray-700">
                {gettext("Choose a file or drop it here")}
              </span>
              <span class="text-xs text-gray-500">.xlsx, .csv · max 2 MB</span>
            </label>

            <div :for={entry <- @uploads.spreadsheet.entries} class="mt-3">
              <div class="flex items-center justify-between gap-2 text-sm">
                <span class="truncate">{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel-file"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  aria-label={gettext("Remove")}
                  class="btn btn-ghost btn-xs"
                >
                  &times;
                </button>
              </div>
              <p
                :for={error <- upload_errors(@uploads.spreadsheet, entry)}
                class="text-xs text-red-700"
              >
                {upload_error_message(error)}
              </p>
            </div>

            <ul
              :if={@file_errors != []}
              id="import-file-errors"
              class="mt-4 flex flex-col gap-1 rounded-xl bg-red-50 p-3 text-sm text-red-700"
            >
              <li :for={error <- Enum.take(@file_errors, shown_errors())}>{error}</li>
              <li :if={length(@file_errors) > shown_errors()}>
                {gettext("…and %{count} more", count: length(@file_errors) - shown_errors())}
              </li>
            </ul>

            <button
              type="submit"
              disabled={@uploads.spreadsheet.entries == []}
              class="btn btn-primary w-full mt-5"
            >
              {gettext("Check the file")}
            </button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  defp shown_errors, do: @shown_errors

  defp group_by_slide(interactions) do
    interactions
    |> Enum.chunk_by(& &1.position)
    |> Enum.map(fn [first | _] = group -> {first.position, group} end)
  end

  defp filter_events(events, search) do
    case search |> String.trim() |> String.downcase() do
      "" ->
        events

      search ->
        Enum.filter(events, fn event ->
          String.contains?(String.downcase(event.name), search) or
            String.contains?(String.downcase(event.code), search)
        end)
    end
  end

  defp describe(%Claper.Polls.Poll{poll_opts: options}), do: describe_poll(length(options))

  defp describe(%Claper.Quizzes.Quiz{quiz_questions: questions}),
    do: describe_quiz(length(questions))

  defp describe(%Claper.Forms.Form{}), do: gettext("Form")
  defp describe(%Claper.Embeds.Embed{}), do: gettext("Web content")
  defp describe(%{type: :poll, options: options}), do: describe_poll(length(options))
  defp describe(%{type: :quiz, questions: questions}), do: describe_quiz(length(questions))

  defp describe_poll(count),
    do: "#{gettext("Poll")} · #{gettext("Options: %{count}", count: count)}"

  defp describe_quiz(count),
    do: "#{gettext("Quiz")} · #{gettext("Questions: %{count}", count: count)}"

  defp upload_error_message(:too_large), do: gettext("The file is too large (max 2 MB).")

  defp upload_error_message(:not_accepted),
    do: gettext("Unsupported file: use an .xlsx or .csv file.")

  defp upload_error_message(_error), do: gettext("The file could not be uploaded.")
end
