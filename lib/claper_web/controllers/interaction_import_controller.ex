defmodule ClaperWeb.InteractionImportController do
  use ClaperWeb, :controller

  alias Claper.Interactions.Spreadsheet

  @doc """
  Downloads the spreadsheet template used to import quizzes and polls.
  """
  def template(conn, _params) do
    send_download(conn, {:binary, Spreadsheet.template()},
      filename: "f2xp-import-template.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end
end
