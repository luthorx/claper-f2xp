defmodule ClaperWeb.InteractionImportControllerTest do
  use ClaperWeb.ConnCase, async: true

  setup :register_and_log_in_user

  test "downloads the import template", %{conn: conn} do
    conn = get(conn, ~p"/import/template")

    assert <<"PK", _rest::binary>> = response(conn, 200)
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "spreadsheetml.sheet"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "f2xp-import-template.xlsx"
  end
end
