defmodule Claper.Interactions.SpreadsheetTest do
  use ExUnit.Case, async: true

  alias Claper.Interactions.Spreadsheet

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "spreadsheet-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  defp write(tmp_dir, name, content) do
    path = Path.join(tmp_dir, name)
    File.write!(path, content)
    path
  end

  defp items(tmp_dir, name, content) do
    path = write(tmp_dir, name, content)

    with {:ok, rows} <- Spreadsheet.read_rows(path, name) do
      Spreadsheet.to_items(rows)
    end
  end

  test "the template can be imported as it is", %{tmp_dir: tmp_dir} do
    assert {:ok, [quiz, poll]} = items(tmp_dir, "template.xlsx", Spreadsheet.template())

    assert %{type: :quiz, title: "Geography quiz", questions: [single, multiple]} = quiz
    assert single.content == "What is the capital of Italy?"
    refute single.allow_multiple

    assert single.options == [
             %{content: "Milan", is_correct: false},
             %{content: "Rome", is_correct: true},
             %{content: "Naples", is_correct: false}
           ]

    assert multiple.allow_multiple
    assert Enum.map(multiple.options, & &1.is_correct) == [true, false, true]

    assert poll == %{
             type: :poll,
             title: "How would you rate this session?",
             multiple: false,
             options: ["Excellent", "Good", "Could be better"]
           }
  end

  test "the translated templates can be imported too", %{tmp_dir: tmp_dir} do
    for locale <- Gettext.known_locales(ClaperWeb.Gettext) do
      template = Gettext.with_locale(ClaperWeb.Gettext, locale, &Spreadsheet.template/0)

      assert {:ok, [%{type: :quiz, questions: [single, multiple]}, %{type: :poll}]} =
               items(tmp_dir, "template-#{locale}.xlsx", template),
             "the #{locale} template cannot be imported"

      refute single.allow_multiple
      assert multiple.allow_multiple
    end
  end

  test "reads CSV files separated by semicolons and groups the rows of a quiz", %{
    tmp_dir: tmp_dir
  } do
    csv = """
    Type;Title;Question;Multiple answers;Correct answers;Answer 1;Answer 2;Answer 3
    QUIZ;Maths;2 + 2?;;2;3;4;5
    quiz;;Even numbers?;;1, 3;2;3;4
    QUIZ;Maths;10 / 2?;;1;5;;2

    POLL;"Coffee; or tea?";;yes;;Coffee;Tea
    """

    assert {:ok, [quiz, poll]} = items(tmp_dir, "import.csv", csv)

    assert [
             %{content: "2 + 2?", allow_multiple: false},
             %{content: "Even numbers?", allow_multiple: true},
             %{content: "10 / 2?", options: [%{content: "5", is_correct: true}, _]}
           ] = quiz.questions

    assert poll == %{
             type: :poll,
             title: "Coffee; or tea?",
             multiple: true,
             options: ["Coffee", "Tea"]
           }
  end

  test "reads CSV files saved with the Windows encoding", %{tmp_dir: tmp_dir} do
    csv = :unicode.characters_to_binary("POLL,Perché?,,,,Sì,No\n", :unicode, :latin1)

    assert {:ok, [%{title: "Perché?", options: ["Sì", "No"]}]} =
             items(tmp_dir, "latin1.csv", csv)
  end

  test "reads Excel files using shared strings", %{tmp_dir: tmp_dir} do
    files = [
      {~c"xl/workbook.xml",
       ~s(<x:workbook xmlns:x="x" xmlns:r="r"><x:sheets><x:sheet name="Data" sheetId="1" r:id="rId3"/></x:sheets></x:workbook>)},
      {~c"xl/_rels/workbook.xml.rels",
       ~s(<Relationships><Relationship Target="worksheets/data.xml" Id="rId3" Type="worksheet"/></Relationships>)},
      {~c"xl/sharedStrings.xml",
       ~s(<sst><si><t>QUIZ</t></si><si><r><t>Capital</t></r><r><t xml:space="preserve"> quiz</t></r></si><si><t>Rome &amp; Milan?</t></si><si/><si><t>Rome</t></si></sst>)},
      {~c"xl/worksheets/data.xml",
       ~s(<worksheet><sheetData><row r="3"><c r="A3" t="s"><v>0</v></c><c r="B3" t="s"><v>1</v></c><c r="C3" t="s"><v>2</v></c><c r="E3"><v>1.0</v></c><c r="F3" t="s"><v>4</v></c><c r="G3" t="inlineStr"><is><t>Milan</t></is></c></row></sheetData></worksheet>)}
    ]

    {:ok, {_name, xlsx}} = :zip.create(~c"data.xlsx", files, [:memory])
    path = write(tmp_dir, "data.xlsx", xlsx)

    assert {:ok, [{3, ["QUIZ", "Capital quiz", "Rome & Milan?", "", "1", "Rome", "Milan"]}]} =
             Spreadsheet.read_rows(path, "data.xlsx")
  end

  test "reports every invalid row", %{tmp_dir: tmp_dir} do
    csv = """
    Type,Title,Question,Multiple answers,Correct answers,Answer 1,Answer 2
    SURVEY,Title,,,,A,B
    QUIZ,,Question,,1,A,B
    QUIZ,Quiz,Question,,,A,B
    QUIZ,Quiz,Question,NO,1;2,A,B
    QUIZ,Quiz,Question,,3,A,B
    QUIZ,Quiz,Question,maybe,1,A,B
    POLL,Only one answer,,,,A
    """

    assert {:error, errors} = items(tmp_dir, "errors.csv", csv)

    assert errors == [
             ~s(Row 2: unknown type "SURVEY", use QUIZ or POLL),
             "Row 3: the title is missing",
             "Row 4: the correct answers are missing",
             "Row 5: only one correct answer is allowed when multiple answers is NO",
             "Row 6: the correct answers must be answer numbers, e.g. 1 or 1;3",
             "Row 7: multiple answers must be YES or NO",
             "Row 8: at least two answers are required"
           ]
  end

  test "reports a file without interactions", %{tmp_dir: tmp_dir} do
    assert {:error, ["The file contains no quizzes or polls."]} =
             items(tmp_dir, "empty.csv", "Type,Title\n\n")
  end

  test "rejects unsupported, unreadable and oversized files", %{tmp_dir: tmp_dir} do
    assert {:error, "Unsupported file" <> _} =
             Spreadsheet.read_rows(write(tmp_dir, "notes.txt", "hello"), "notes.txt")

    assert {:error, "The file could not be read" <> _} =
             Spreadsheet.read_rows(write(tmp_dir, "broken.xlsx", "not a zip"), "broken.xlsx")

    huge_sheet = "<worksheet>" <> String.duplicate(" ", 21_000_000) <> "</worksheet>"

    {:ok, {_name, xlsx}} =
      :zip.create(
        ~c"huge.xlsx",
        [
          {~c"xl/workbook.xml", "<workbook/>"},
          {~c"xl/_rels/workbook.xml.rels", "<Relationships/>"},
          {~c"xl/worksheets/sheet1.xml", huge_sheet}
        ],
        [:memory]
      )

    assert {:error, "The file could not be read" <> _} =
             Spreadsheet.read_rows(write(tmp_dir, "huge.xlsx", xlsx), "huge.xlsx")
  end
end
