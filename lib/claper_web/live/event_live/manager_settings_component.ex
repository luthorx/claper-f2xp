defmodule ClaperWeb.EventLive.ManagerSettingsComponent do
  use ClaperWeb, :live_component

  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:show_shortcut, fn -> true end)
      |> assign_new(:quiz_participations, fn -> [] end)

    ~H"""
    <div class="flex flex-col gap-4 p-4">
      <ClaperWeb.EventLive.ManageInteractionOptionsComponent.render
        id={"#{@id}-interaction-options"}
        current_interaction={@current_interaction}
        quiz_participations={@quiz_participations}
        state={@state}
        create={@create}
        show_shortcut={@show_shortcut}
      />
      <ClaperWeb.EventLive.ManagePresentationOptionsComponent.render
        state={@state}
        create={@create}
        show_shortcut={@show_shortcut}
      />
      <ClaperWeb.EventLive.ManageAttendeesOptionsComponent.render
        state={@state}
        create={@create}
        show_shortcut={@show_shortcut}
      />
    </div>
    """
  end
end
