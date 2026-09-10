defmodule Claper.Interactions.Spreadsheet do
  @moduledoc """
  Reads the spreadsheet used to import quizzes and polls (.xlsx or .csv) and
  builds its downloadable template.

  Each row is a quiz question or a poll, with these columns in order:

    1. Type: `QUIZ` or `POLL`
    2. Title: the quiz title, or the poll question
    3. Question: the quiz question (empty for polls)
    4. Multiple answers: `YES` or `NO`; when empty, a quiz question allows
       multiple answers only if several answers are correct
    5. Correct answers: answer numbers such as `2` or `1;3` (quizzes only)
    6. Answer 1, Answer 2, … (at least two)

  Consecutive quiz rows with the same title, or with an empty title, belong
  to the same quiz. The header row is optional.

  Excel files are read with a small purpose-built parser rather than an XML
  library: xmerl turns tag names into atoms, which untrusted uploads must not
  be able to do, and entries are inflated with a size cap against zip bombs.
  """

  use Gettext, backend: ClaperWeb.Gettext

  @correct_column 5
  @max_columns 50
  @max_rows 1000
  @max_text_length 255
  @max_uncompressed_bytes 20_000_000

  @quiz_types ~w(quiz qcm mcq)
  @poll_types ~w(poll sondaggio sondage encuesta umfrage peiling enkät aptauja szavazás)
  @yes ~w(yes y true 1 x si sì sí oui ja vrai wahr igen jā)
  @no ~w(no n false 0 non nein nee nej nem nē)

  @main_namespace "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  @relationships_namespace "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  @type item ::
          %{type: :poll, title: String.t(), multiple: boolean(), options: [String.t()]}
          | %{
              type: :quiz,
              title: String.t(),
              questions: [
                %{
                  content: String.t(),
                  allow_multiple: boolean(),
                  options: [%{content: String.t(), is_correct: boolean()}]
                }
              ]
            }

  @doc """
  Reads the rows of an uploaded file, choosing the format from its name.

  Returns `{:ok, [{row_number, cells}]}` or `{:error, message}`.
  """
  def read_rows(path, filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".xlsx" -> read_xlsx(path)
      ".csv" -> read_csv(path)
      _ -> {:error, gettext("Unsupported file: use an .xlsx or .csv file.")}
    end
  end

  @doc """
  Turns spreadsheet rows into quizzes and polls ready to be imported.

  Returns `{:ok, items}` or `{:error, messages}` listing every invalid row.
  """
  def to_items(rows) do
    rows =
      rows
      |> Enum.map(fn {number, cells} -> {number, Enum.map(cells, &clean_cell/1)} end)
      |> Enum.reject(fn {_number, cells} -> Enum.all?(cells, &(&1 == "")) end)
      |> drop_header()

    if length(rows) > @max_rows do
      {:error, [gettext("The file has too many rows (maximum %{max}).", max: @max_rows)]}
    else
      rows
      |> Enum.reduce({[], []}, &add_row/2)
      |> items_result()
    end
  end

  defp items_result({_items, [_ | _] = errors}), do: {:error, Enum.reverse(errors)}

  defp items_result({[], []}),
    do: {:error, [gettext("The file contains no quizzes or polls.")]}

  defp items_result({items, []}),
    do: {:ok, items |> Enum.reverse() |> Enum.map(&finalize_item/1)}

  defp clean_cell(cell), do: cell |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The header row is recognised by not starting with a known type
  defp drop_header([{_number, [type | _]} | rest] = rows) do
    if row_type(type), do: rows, else: rest
  end

  defp drop_header(rows), do: rows

  defp add_row({number, cells}, {items, errors}) do
    [type, title, question, multiple, correct | answers] = pad(cells, @correct_column)
    answers = numbered_answers(answers)

    result =
      case row_type(type) do
        :poll -> poll_item(title, multiple, answers)
        :quiz -> quiz_question(title, question, multiple, correct, answers)
        nil -> {:error, gettext("unknown type \"%{type}\", use QUIZ or POLL", type: type)}
      end

    case {result, items} do
      {{:error, message}, _items} ->
        {items, [row_error(number, message) | errors]}

      {{:ok, %{type: :poll} = poll}, _items} ->
        {[poll | items], errors}

      {{:ok, {title, question}}, [%{type: :quiz, title: quiz_title} = quiz | rest]}
      when title == "" or title == quiz_title ->
        {[%{quiz | questions: [question | quiz.questions]} | rest], errors}

      {{:ok, {"", _question}}, _items} ->
        {items, [row_error(number, gettext("the title is missing")) | errors]}

      {{:ok, {title, question}}, _items} ->
        {[%{type: :quiz, title: title, questions: [question]} | items], errors}
    end
  end

  defp finalize_item(%{type: :quiz} = quiz), do: %{quiz | questions: Enum.reverse(quiz.questions)}
  defp finalize_item(item), do: item

  defp row_error(number, message),
    do: gettext("Row %{row}: %{message}", row: number, message: message)

  defp pad(cells, count), do: cells ++ List.duplicate("", max(count - length(cells), 0))

  # Answers keep the number of their column, so "Correct answers" can refer to
  # them even when a column in between is left empty
  defp numbered_answers(answers) do
    answers
    |> Enum.with_index(1)
    |> Enum.reject(fn {answer, _number} -> answer == "" end)
    |> Enum.map(fn {answer, number} -> {number, answer} end)
  end

  defp row_type(type) do
    type = String.downcase(type)

    cond do
      type in @quiz_types -> :quiz
      type in @poll_types -> :poll
      true -> nil
    end
  end

  defp poll_item(title, multiple, answers) do
    with :ok <- validate_text(title, gettext("the title is missing")),
         {:ok, answers} <- validate_answers(answers),
         {:ok, multiple} <- multiple_answers(multiple) do
      {:ok,
       %{
         type: :poll,
         title: title,
         multiple: multiple == :yes,
         options: Enum.map(answers, fn {_number, answer} -> answer end)
       }}
    end
  end

  defp quiz_question(title, question, multiple, correct, answers) do
    with :ok <- validate_length(title),
         :ok <- validate_text(question, gettext("the question is missing")),
         {:ok, answers} <- validate_answers(answers),
         {:ok, multiple} <- multiple_answers(multiple),
         {:ok, correct} <- correct_answers(correct, answers),
         :ok <- validate_single_correct(multiple, correct) do
      options =
        Enum.map(answers, fn {number, answer} ->
          %{content: answer, is_correct: MapSet.member?(correct, number)}
        end)

      {:ok,
       {title,
        %{
          content: question,
          allow_multiple: multiple == :yes or (multiple == :auto and MapSet.size(correct) > 1),
          options: options
        }}}
    end
  end

  defp validate_text("", missing_message), do: {:error, missing_message}
  defp validate_text(text, _missing_message), do: validate_length(text)

  defp validate_length(text) do
    if String.length(text) > @max_text_length,
      do: {:error, too_long_message()},
      else: :ok
  end

  defp too_long_message,
    do: gettext("texts can be at most %{max} characters long", max: @max_text_length)

  defp validate_answers(answers) when length(answers) < 2,
    do: {:error, gettext("at least two answers are required")}

  defp validate_answers(answers) do
    if Enum.any?(answers, fn {_number, answer} -> String.length(answer) > @max_text_length end),
      do: {:error, too_long_message()},
      else: {:ok, answers}
  end

  defp multiple_answers(""), do: {:ok, :auto}

  defp multiple_answers(value) do
    value = String.downcase(value)

    cond do
      value in @yes -> {:ok, :yes}
      value in @no -> {:ok, :no}
      true -> {:error, gettext("multiple answers must be YES or NO")}
    end
  end

  defp correct_answers("", _answers), do: {:error, gettext("the correct answers are missing")}

  defp correct_answers(value, answers) do
    numbers = MapSet.new(answers, fn {number, _answer} -> number end)

    correct =
      value
      |> String.split(~r/[\s,;|\/]+/, trim: true)
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {number, ""} -> number
          _ -> nil
        end
      end)

    if correct != [] and Enum.all?(correct, &MapSet.member?(numbers, &1)) do
      {:ok, MapSet.new(correct)}
    else
      {:error, gettext("the correct answers must be answer numbers, e.g. 1 or 1;3")}
    end
  end

  defp validate_single_correct(:no, correct) do
    if MapSet.size(correct) > 1,
      do: {:error, gettext("only one correct answer is allowed when multiple answers is NO")},
      else: :ok
  end

  defp validate_single_correct(_multiple, _correct), do: :ok

  defp unreadable_file_message,
    do:
      gettext("The file could not be read. Start from the template and save it as .xlsx or .csv.")

  ## CSV

  defp read_csv(path) do
    with {:ok, content} <- File.read(path) do
      content = content |> to_utf8() |> String.replace_prefix("\uFEFF", "")

      content
      |> String.split(~r/(?<=\n)/)
      |> CSV.decode(separator: detect_separator(content))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, cells}, {:ok, rows} -> {:cont, {:ok, [cells | rows]}}
        _error, _rows -> {:halt, :error}
      end)
      |> case do
        {:ok, rows} ->
          {:ok, rows |> Enum.reverse() |> Enum.with_index(1) |> Enum.map(fn {c, n} -> {n, c} end)}

        :error ->
          {:error, unreadable_file_message()}
      end
    else
      _ -> {:error, unreadable_file_message()}
    end
  end

  # Excel often saves CSV files in the legacy Windows encoding
  defp to_utf8(content) do
    if String.valid?(content),
      do: content,
      else: :unicode.characters_to_binary(content, :latin1)
  end

  # Excel uses the list separator of the system locale (";" in most of Europe)
  defp detect_separator(content) do
    first_line = content |> String.split("\n", parts: 2) |> hd()

    Enum.max_by([?,, ?;, ?\t], fn separator ->
      first_line |> :binary.matches(<<separator>>) |> length()
    end)
  end

  ## XLSX

  defp read_xlsx(path) do
    with {:ok, archive} <- File.read(path),
         {:ok, entries} <- zip_entries(archive),
         {:ok, workbook} <- zip_file(archive, entries, "xl/workbook.xml"),
         {:ok, relationships} <- zip_file(archive, entries, "xl/_rels/workbook.xml.rels"),
         {:ok, sheet} <- zip_file(archive, entries, first_sheet_path(workbook, relationships)),
         true <- String.valid?(sheet) do
      shared_strings =
        case zip_file(archive, entries, "xl/sharedStrings.xml") do
          {:ok, xml} -> if String.valid?(xml), do: shared_strings(xml), else: {}
          _missing -> {}
        end

      {:ok, sheet_rows(sheet, shared_strings)}
    else
      _ -> {:error, unreadable_file_message()}
    end
  catch
    _kind, _reason -> {:error, unreadable_file_message()}
  end

  defp zip_entries(archive) do
    tail_size = min(byte_size(archive), 65_557)
    tail = binary_part(archive, byte_size(archive) - tail_size, tail_size)

    with [_ | _] = matches <- :binary.matches(tail, <<0x50, 0x4B, 0x05, 0x06>>),
         {start, _length} = List.last(matches),
         <<_signature::32, _disks::32, _disk_entries::16, count::little-16, size::little-32,
           offset::little-32, _rest::binary>> <- binary_part(tail, start, tail_size - start),
         true <- offset + size <= byte_size(archive) do
      central_directory(binary_part(archive, offset, size), count, %{})
    else
      _ -> :error
    end
  end

  defp central_directory(_data, 0, entries), do: {:ok, entries}

  defp central_directory(
         <<0x50, 0x4B, 0x01, 0x02, _versions::32, _flags::16, method::little-16, _time::16,
           _date::16, _crc::32, compressed::little-32, uncompressed::little-32,
           name_length::little-16, extra_length::little-16, comment_length::little-16, _disk::16,
           _internal::16, _external::32, offset::little-32, name::binary-size(name_length),
           _extra::binary-size(extra_length), _comment::binary-size(comment_length),
           rest::binary>>,
         count,
         entries
       ) do
    entry = {method, compressed, uncompressed, offset}
    central_directory(rest, count - 1, Map.put(entries, name, entry))
  end

  defp central_directory(_data, _count, _entries), do: :error

  defp zip_file(archive, entries, name) do
    with {method, compressed, uncompressed, offset} <- Map.get(entries, name),
         true <- uncompressed <= @max_uncompressed_bytes,
         <<_before::binary-size(offset), 0x50, 0x4B, 0x03, 0x04, _header::binary-size(22),
           name_length::little-16, extra_length::little-16, _name::binary-size(name_length),
           _extra::binary-size(extra_length), data::binary-size(compressed),
           _after::binary>> <- archive do
      decompress(method, data)
    else
      _ -> :error
    end
  end

  defp decompress(0, data) when byte_size(data) <= @max_uncompressed_bytes, do: {:ok, data}
  defp decompress(8, data), do: inflate(data)
  defp decompress(_method, _data), do: :error

  # The sizes declared in the archive can lie, so inflate in chunks and stop
  # as soon as the real output grows past the limit
  defp inflate(data) do
    zlib = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zlib, -15)
      inflate_chunks(zlib, :zlib.safeInflate(zlib, data), [], 0)
    after
      :zlib.close(zlib)
    end
  end

  defp inflate_chunks(zlib, {status, output}, acc, size) do
    size = size + IO.iodata_length(output)

    cond do
      size > @max_uncompressed_bytes -> :error
      status == :finished -> {:ok, IO.iodata_to_binary([acc, output])}
      true -> inflate_chunks(zlib, :zlib.safeInflate(zlib, []), [acc, output], size)
    end
  end

  defp first_sheet_path(workbook, relationships) do
    with [sheet_tag | _] <- Regex.run(~r/<(?:[\w.-]+:)?sheet\s[^>]*>/, workbook),
         %{"id" => id} <- attributes(sheet_tag),
         target when is_binary(target) <- relationship_target(relationships, id) do
      case target do
        "/" <> absolute -> absolute
        relative -> "xl/" <> relative
      end
    else
      _ -> "xl/worksheets/sheet1.xml"
    end
  end

  defp relationship_target(xml, id) do
    ~r/<(?:[\w.-]+:)?Relationship\s[^>]*>/
    |> Regex.scan(xml)
    |> Enum.find_value(fn [tag] ->
      attributes = attributes(tag)
      attributes["Id"] == id && attributes["Target"]
    end)
  end

  defp attributes(tag) do
    ~r/([\w.:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/
    |> Regex.scan(tag)
    |> Map.new(fn
      [_match, name, value] -> {local_name(name), unescape(value)}
      [_match, name, _double_quoted, value] -> {local_name(name), unescape(value)}
    end)
  end

  defp local_name(name), do: name |> String.split(":") |> List.last()

  defp shared_strings(xml) do
    ~r/<(?:[\w.-]+:)?si\b[^>]*?(?:\/>|>(.*?)<\/(?:[\w.-]+:)?si>)/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn content -> content |> List.first("") |> text_runs() end)
    |> List.to_tuple()
  end

  defp sheet_rows(xml, shared_strings) do
    ~r/<(?:[\w.-]+:)?row\b([^>]*?)(?:\/>|>(.*?)<\/(?:[\w.-]+:)?row>)/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map_reduce(0, fn [row_attributes | content], previous ->
      number = row_number(attributes(row_attributes)["r"], previous)
      {{number, row_cells(List.first(content, ""), shared_strings)}, number}
    end)
    |> elem(0)
  end

  defp row_number(value, previous) do
    case Integer.parse(value || "") do
      {number, ""} when number > 0 -> number
      _ -> previous + 1
    end
  end

  defp row_cells(content, shared_strings) do
    cells =
      ~r/<(?:[\w.-]+:)?c\b([^>]*?)(?:\/>|>(.*?)<\/(?:[\w.-]+:)?c>)/s
      |> Regex.scan(content, capture: :all_but_first)
      |> Enum.map_reduce(0, fn [cell_attributes | body], previous ->
        attributes = attributes(cell_attributes)
        column = column_index(attributes["r"]) || previous + 1
        value = cell_value(attributes["t"], List.first(body, ""), shared_strings)
        {{column, value}, column}
      end)
      |> elem(0)
      |> Enum.filter(fn {column, _value} -> column <= @max_columns end)
      |> Map.new()

    case Map.keys(cells) do
      [] -> []
      columns -> Enum.map(1..Enum.max(columns), &Map.get(cells, &1, ""))
    end
  end

  defp column_index(nil), do: nil

  defp column_index(reference) do
    case Regex.run(~r/^([A-Z]+)\d*$/, reference) do
      [_match, letters] ->
        letters |> String.to_charlist() |> Enum.reduce(0, &(&2 * 26 + &1 - ?A + 1))

      _ ->
        nil
    end
  end

  defp cell_value("s", body, shared_strings) do
    with {index, ""} <- body |> raw_value() |> Integer.parse(),
         true <- index < tuple_size(shared_strings) do
      elem(shared_strings, index)
    else
      _ -> ""
    end
  end

  defp cell_value("inlineStr", body, _shared_strings), do: text_runs(body)

  defp cell_value("b", body, _shared_strings) do
    case raw_value(body) do
      "1" -> "TRUE"
      "0" -> "FALSE"
      _ -> ""
    end
  end

  # Numbers typed in Excel can come back as "2.0"
  defp cell_value(_type, body, _shared_strings),
    do: Regex.replace(~r/^(-?\d+)\.0+$/, raw_value(body), "\\1")

  defp raw_value(body) do
    case Regex.run(~r/<(?:[\w.-]+:)?v\b[^>]*>(.*?)<\/(?:[\w.-]+:)?v>/s, body) do
      [_match, value] -> value |> unescape() |> String.trim()
      _ -> ""
    end
  end

  defp text_runs(xml) do
    xml = Regex.replace(~r/<(?:[\w.-]+:)?rPh\b.*?<\/(?:[\w.-]+:)?rPh>/s, xml, "")

    ~r/<(?:[\w.-]+:)?t\b[^>]*?(?:\/>|>(.*?)<\/(?:[\w.-]+:)?t>)/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map_join(fn content -> content |> List.first("") |> unescape() end)
  end

  defp unescape(text) do
    text =
      Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);/, text, fn _match, entity ->
        decode_entity(entity)
      end)

    # Excel escapes control characters as _xHHHH_
    Regex.replace(~r/_x([0-9A-Fa-f]{4})_/, text, fn _match, hex ->
      codepoint(String.to_integer(hex, 16))
    end)
  end

  defp decode_entity("lt"), do: "<"
  defp decode_entity("gt"), do: ">"
  defp decode_entity("amp"), do: "&"
  defp decode_entity("quot"), do: "\""
  defp decode_entity("apos"), do: "'"
  defp decode_entity("#x" <> hex), do: codepoint(String.to_integer(hex, 16))
  defp decode_entity("#" <> decimal), do: codepoint(String.to_integer(decimal))

  defp codepoint(value) do
    <<value::utf8>>
  rescue
    ArgumentError -> ""
  end

  ## Template

  @doc """
  Builds the .xlsx template: an example of each interaction type on the first
  sheet and the instructions on the second one.
  """
  def template do
    answers = Enum.map(1..6, &gettext("Answer %{number}", number: &1))

    headers = [
      gettext("Type"),
      gettext("Title"),
      gettext("Question"),
      gettext("Multiple answers"),
      gettext("Correct answers") | answers
    ]

    examples = [
      [
        "QUIZ",
        gettext("Geography quiz"),
        gettext("What is the capital of Italy?"),
        gettext("NO"),
        "2",
        gettext("Milan"),
        gettext("Rome"),
        gettext("Naples")
      ],
      [
        "QUIZ",
        "",
        gettext("Which of these are rivers?"),
        gettext("YES"),
        "1;3",
        gettext("Po"),
        gettext("Alps"),
        gettext("Tiber")
      ],
      [
        "POLL",
        gettext("How would you rate this session?"),
        "",
        gettext("NO"),
        "",
        gettext("Excellent"),
        gettext("Good"),
        gettext("Could be better")
      ]
    ]

    sheets = [
      {gettext("Interactions"), [headers | examples],
       [10, 30, 36, 18, 18 | List.duplicate(18, 6)]},
      {gettext("Instructions"), Enum.map(instructions(), &[&1]), [140]}
    ]

    worksheets =
      sheets
      |> Enum.with_index(1)
      |> Enum.map(fn {sheet, index} ->
        {"xl/worksheets/sheet#{index}.xml", worksheet(sheet, index == 1)}
      end)

    files =
      [
        {"[Content_Types].xml", content_types(length(sheets))},
        {"_rels/.rels", root_relationships()},
        {"xl/workbook.xml", workbook(sheets)},
        {"xl/_rels/workbook.xml.rels", workbook_relationships(length(sheets))},
        {"xl/styles.xml", styles()}
      ] ++ worksheets

    {:ok, {_name, binary}} =
      :zip.create(
        ~c"template.xlsx",
        Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end),
        [:memory]
      )

    binary
  end

  defp instructions do
    [
      gettext(
        "Write one row for each quiz question or poll, keeping the columns in the order of the \"%{sheet}\" sheet. The header row is optional.",
        sheet: gettext("Interactions")
      ),
      gettext("Type: QUIZ or POLL."),
      gettext(
        "Title: the quiz title or the poll question. Consecutive QUIZ rows with the same title, or with no title, belong to the same quiz."
      ),
      gettext("Question: the quiz question. Leave it empty for polls."),
      gettext(
        "Multiple answers: %{yes} lets attendees choose several answers, %{no} only one. When empty, several answers are allowed only if more than one answer is correct.",
        yes: gettext("YES"),
        no: gettext("NO")
      ),
      gettext(
        "Correct answers: the numbers of the correct answers, separated by a semicolon (for example 1;3). Quizzes only."
      ),
      gettext("Answers: at least two. Add more columns to the right if you need more answers."),
      gettext(
        "Save the file as .xlsx or .csv. Imported interactions are added to the current slide and stay disabled until you activate them."
      )
    ]
  end

  defp worksheet({_name, rows, widths}, table?) do
    columns =
      widths
      |> Enum.with_index(1)
      |> Enum.map_join(fn {width, index} ->
        style = if table? and index == @correct_column, do: ~s( style="1"), else: ""
        ~s(<col min="#{index}" max="#{index}" width="#{width}" customWidth="1"#{style}/>)
      end)

    frozen_header =
      if table?,
        do:
          ~s(<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>),
        else: ""

    data =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join(fn {cells, row} ->
        ~s(<row r="#{row}">#{worksheet_cells(cells, row, table?)}</row>)
      end)

    xml(
      ~s(<worksheet xmlns="#{@main_namespace}">#{frozen_header}<cols>#{columns}</cols><sheetData>#{data}</sheetData></worksheet>)
    )
  end

  # Style 1 is text, so correct answers such as 1;3 are not turned into numbers,
  # style 2 is bold for the header
  defp worksheet_cells(cells, row, table?) do
    cells
    |> Enum.with_index(1)
    |> Enum.reject(fn {value, _column} -> value == "" end)
    |> Enum.map_join(fn {value, column} ->
      style =
        cond do
          table? and row == 1 -> 2
          table? and column == @correct_column -> 1
          true -> 0
        end

      ~s(<c r="#{column_name(column)}#{row}" t="inlineStr" s="#{style}"><is><t xml:space="preserve">#{escape(value)}</t></is></c>)
    end)
  end

  defp column_name(index) when index <= 26, do: <<?A + index - 1>>

  defp column_name(index),
    do: column_name(div(index - 1, 26)) <> column_name(rem(index - 1, 26) + 1)

  defp content_types(sheet_count) do
    sheets =
      Enum.map_join(1..sheet_count, fn index ->
        ~s(<Override PartName="/xl/worksheets/sheet#{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
      end)

    xml(
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
        ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
        ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
        ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
        ~s(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>) <>
        sheets <> "</Types>"
    )
  end

  defp root_relationships do
    xml(
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
        ~s(<Relationship Id="rId1" Type="#{@relationships_namespace}/officeDocument" Target="xl/workbook.xml"/>) <>
        "</Relationships>"
    )
  end

  defp workbook(sheets) do
    entries =
      sheets
      |> Enum.with_index(1)
      |> Enum.map_join(fn {{name, _rows, _widths}, index} ->
        ~s(<sheet name="#{escape(name)}" sheetId="#{index}" r:id="rId#{index}"/>)
      end)

    xml(
      ~s(<workbook xmlns="#{@main_namespace}" xmlns:r="#{@relationships_namespace}"><sheets>#{entries}</sheets></workbook>)
    )
  end

  defp workbook_relationships(sheet_count) do
    sheets =
      Enum.map_join(1..sheet_count, fn index ->
        ~s(<Relationship Id="rId#{index}" Type="#{@relationships_namespace}/worksheet" Target="worksheets/sheet#{index}.xml"/>)
      end)

    xml(
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
        sheets <>
        ~s(<Relationship Id="rId#{sheet_count + 1}" Type="#{@relationships_namespace}/styles" Target="styles.xml"/>) <>
        "</Relationships>"
    )
  end

  defp styles do
    xml(
      ~s(<styleSheet xmlns="#{@main_namespace}">) <>
        ~s(<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>) <>
        ~s(<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>) <>
        ~s(<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>) <>
        ~s(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>) <>
        ~s(<cellXfs count="3">) <>
        ~s(<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>) <>
        ~s(<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>) <>
        ~s(<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>) <>
        "</cellXfs>" <>
        ~s(<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>) <>
        "</styleSheet>"
    )
  end

  defp xml(content), do: ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n) <> content

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
