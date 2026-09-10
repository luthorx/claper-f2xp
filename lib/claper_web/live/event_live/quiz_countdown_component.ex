defmodule ClaperWeb.EventLive.QuizCountdownComponent do
  @moduledoc """
  Shows the time left to answer a quiz. The deadline is decided by the server;
  the QuizCountdown hook only ticks the display between renders.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :deadline, DateTime, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def countdown(assigns) do
    ~H"""
    <%!-- The deadline is part of the id so a restarted quiz mounts a fresh countdown --%>
    <span
      id={"#{@id}-#{DateTime.to_unix(@deadline)}"}
      phx-hook="QuizCountdown"
      phx-update="ignore"
      data-deadline={DateTime.to_unix(@deadline, :millisecond)}
      data-now={System.system_time(:millisecond)}
      class={["tabular-nums", @class]}
      {@rest}
    >
      <span data-countdown-label>{remaining(@deadline)}</span>
    </span>
    """
  end

  defp remaining(deadline) do
    seconds = max(ceil(DateTime.diff(deadline, DateTime.utc_now(), :millisecond) / 1000), 0)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
