defmodule Sue.Mailbox.Telegram do
  @moduledoc false

  alias ExGram.Model.InputPollOption
  require Logger

  alias Sue.Models.{Attachment, Message, Response}

  # Telegram's message limit is 4096 UTF-16 code units. Not graphemes, not
  # codepoints, not UTF-8 bytes. A single flag emoji like 🇺🇸 is one grapheme
  # but four UTF-16 code units (two surrogate pairs), so a grapheme-based
  # limit can overshoot by up to 4×.
  @telegram_max_u16 4096
  @bot_name :sue_bot
  @default_mime "application/octet-stream"

  # HTTP timeouts for file downloads. Telegram CDN files can be large; the
  # connect timeout is tighter than recv so a dead endpoint fails fast.
  @http_connect_timeout 10_000
  @http_recv_timeout 30_000

  @spec send_response(Message.t(), Response.t()) :: :ok | {:error, term()}
  def send_response(_msg, %Response{body: nil, attachments: []}), do: :ok

  def send_response(msg, %Response{attachments: []} = rsp) do
    send_response_text(msg, rsp)
  end

  def send_response(msg, %Response{body: nil, attachments: atts}) do
    send_response_attachments(msg, atts)
  end

  def send_response(%Message{} = msg, %Response{attachments: atts} = rsp) do
    with :ok <- send_response_text(msg, rsp) do
      send_response_attachments(msg, atts)
    end
  end

  @spec send_response_text(Message.t(), Response.t()) :: :ok | {:error, term()}
  def send_response_text(_msg, %Response{body: nil}), do: :ok
  def send_response_text(_msg, %Response{body: ""}), do: :ok

  def send_response_text(msg, %Response{body: body}) do
    case send_text(chat_id(msg), body) do
      {:ok, _messages} ->
        :ok

      {:error, error} ->
        log_transport_error(:send_message, error)
        {:error, error}
    end
  end

  def send_response_attachments(_msg, []), do: :ok

  @spec send_response_attachments(Message.t(), [Attachment.t()]) :: :ok | {:error, term()}
  def send_response_attachments(msg, attachments) do
    attachments
    |> Enum.reduce_while(:ok, fn att, :ok ->
      case send_photo(chat_id(msg), att) do
        {:ok, _message} ->
          {:cont, :ok}

        {:error, error} ->
          log_transport_error(:send_photo, error)
          {:halt, {:error, error}}
      end
    end)
  end

  @spec send_text(bitstring() | integer(), String.t()) ::
          {:ok, [ExGram.Model.Message.t()]} | {:error, term()}
  def send_text(_chat_id, ""), do: {:ok, []}

  def send_text(chat_id, text) when is_binary(text) do
    text
    |> split_message()
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case ExGram.send_message(chat_id, chunk, bot: @bot_name) do
        {:ok, message} ->
          {:cont, {:ok, [message | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, error} -> {:error, error}
    end
  end

  @spec edit_text(bitstring() | integer(), integer(), String.t(), keyword()) ::
          {:ok, ExGram.Model.Message.t()} | {:error, term()}
  def edit_text(chat_id, message_id, text, opts \\ []) when is_binary(text) do
    opts =
      Keyword.merge(
        [chat_id: chat_id, message_id: message_id, bot: @bot_name],
        opts
      )

    ExGram.edit_message_text(text, opts)
  end

  @spec send_photo(bitstring() | integer(), Attachment.t()) ::
          {:ok, ExGram.Model.Message.t()} | {:error, term()}
  def send_photo(chat_id, %Attachment{} = att) do
    cond do
      Attachment.has_url?(att) ->
        ExGram.send_photo(chat_id, att.url, bot: @bot_name)

      is_binary(att.filepath) ->
        ExGram.send_photo(chat_id, {:file, att.filepath}, bot: @bot_name)

      true ->
        {:error, :invalid_attachment}
    end
  end

  @spec send_poll(bitstring() | integer(), String.t(), [String.t() | InputPollOption.t()]) ::
          {:ok, ExGram.Model.Message.t()} | {:error, term()}
  def send_poll(chat_id, topic, options) when is_list(options) do
    options =
      Enum.map(options, fn
        %InputPollOption{} = option -> option
        option when is_binary(option) -> %InputPollOption{text: option}
      end)

    ExGram.send_poll(chat_id, topic, options, is_anonymous: false, bot: @bot_name)
  end

  @spec get_file(String.t()) :: {:ok, ExGram.Model.File.t()} | {:error, term()}
  def get_file(file_id) do
    ExGram.get_file(file_id, bot: @bot_name)
  end

  @spec download_file(String.t(), String.t() | nil) ::
          {:ok, String.t(), integer() | nil, String.t()} | {:error, term()}
  def download_file(file_id, original_mime_type \\ nil) do
    with {:ok, %ExGram.Model.File{file_path: file_path, file_size: file_size} = file} <-
           get_file(file_id),
         url <- ExGram.File.file_url(file, bot: @bot_name),
         filename <- Sue.Utils.unique_string(),
         filepath <- Path.join(System.tmp_dir!(), filename <> Path.extname(file_path)),
         {:ok, body, headers} <- http_get(url),
         :ok <- File.write(filepath, body) do
      mime_type = original_mime_type || extract_mime_from_headers(headers) || @default_mime
      {:ok, filepath, file_size, mime_type}
    else
      {:error, error} -> {:error, error}
    end
  end

  # Split a message into chunks that fit within Telegram's UTF-16 code unit
  # limit. Prefers paragraph boundaries, then whitespace, then a hard split
  # with a trailing hyphen. Walks graphemes so we never break a glyph in
  # half, while counting UTF-16 code units so we never overshoot the limit.
  @doc false
  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) when is_binary(text) do
    if utf16_length(text) <= @telegram_max_u16 do
      [text]
    else
      split_chunks(text, [])
    end
  end

  defp split_chunks("", acc), do: Enum.reverse(acc)

  defp split_chunks(text, acc) do
    if utf16_length(text) <= @telegram_max_u16 do
      Enum.reverse([text | acc])
    else
      {chunk, rest} = take_chunk(text)
      split_chunks(rest, [chunk | acc])
    end
  end

  # Peel off a chunk of at most @telegram_max_u16 UTF-16 code units. The
  # window is always valid UTF-8 because take_utf16_prefix/2 walks grapheme
  # boundaries. Inside the window we can use :binary.matches/2 with ASCII
  # delimiters because ASCII bytes never appear as UTF-8 continuation bytes.
  defp take_chunk(text) do
    {window, tail} = take_utf16_prefix(text, @telegram_max_u16)

    cond do
      match = last_ascii_match(window, "\n\n") ->
        split_window(window, match, tail)

      match = last_ascii_match(window, [" ", "\t", "\n", "\r"]) ->
        split_window(window, match, tail)

      true ->
        # Fallback: reserve one UTF-16 code unit for the trailing "-".
        {chunk, rest} = take_utf16_prefix(window, @telegram_max_u16 - 1)
        {chunk <> "-", rest <> tail}
    end
  end

  defp split_window(window, {pos, len}, tail) do
    <<chunk::binary-size(^pos), _delim::binary-size(^len), rest::binary>> = window
    {chunk, rest <> tail}
  end

  defp last_ascii_match(text, pattern) do
    case :binary.matches(text, pattern) do
      [] -> nil
      matches -> List.last(matches)
    end
  end

  # Returns {prefix, rest} where prefix contains as many whole graphemes from
  # `text` as fit within `max_u16` UTF-16 code units. If a single grapheme
  # exceeds the limit on its own (e.g. "a" followed by thousands of combining
  # marks), fall back to codepoint-level splitting within that grapheme so
  # we never emit a chunk Telegram will reject. The visible glyph may render
  # partially at the break, which is the least-bad option for pathological
  # input.
  defp take_utf16_prefix(text, max_u16) do
    take_utf16_prefix(text, max_u16, 0, [])
  end

  defp take_utf16_prefix(rest, max_u16, acc_u16, acc) do
    case String.next_grapheme(rest) do
      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), ""}

      {g, tail} ->
        g_u16 = utf16_length(g)

        cond do
          acc_u16 + g_u16 <= max_u16 ->
            take_utf16_prefix(tail, max_u16, acc_u16 + g_u16, [g | acc])

          acc == [] ->
            {cp_prefix, cp_rest} = take_utf16_codepoints(g, max_u16)
            {cp_prefix, cp_rest <> tail}

          true ->
            {IO.iodata_to_binary(Enum.reverse(acc)), rest}
        end
    end
  end

  # Fallback used only when one grapheme is larger than max_u16 on its own.
  # Walks codepoints instead of graphemes so we always make progress.
  defp take_utf16_codepoints(text, max_u16) do
    take_utf16_codepoints(text, max_u16, 0, [])
  end

  defp take_utf16_codepoints(rest, max_u16, acc_u16, acc) do
    case String.next_codepoint(rest) do
      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), ""}

      {cp, tail} ->
        cp_u16 = utf16_length(cp)

        cond do
          acc_u16 + cp_u16 <= max_u16 ->
            take_utf16_codepoints(tail, max_u16, acc_u16 + cp_u16, [cp | acc])

          acc == [] ->
            # Only reachable if max_u16 < cp_u16, i.e. max_u16 == 1 and cp is
            # a supplementary-plane character. Our call sites pass max_u16 of
            # 4095 or 4096, so this branch is defensive, not exercised.
            {cp, tail}

          true ->
            {IO.iodata_to_binary(Enum.reverse(acc)), rest}
        end
    end
  end

  # Count UTF-16 code units in a UTF-8 binary. Each BMP codepoint contributes
  # one code unit; supplementary-plane codepoints (>= U+10000) contribute two.
  defp utf16_length(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
    |> byte_size()
    |> div(2)
  end

  defp chat_id(%Message{chat: %{platform_id: {_platform, id}}}), do: id

  defp http_get(url) do
    opts = [
      connect_options: [timeout: @http_connect_timeout],
      receive_timeout: @http_recv_timeout,
      decode_body: false
    ]

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        {:ok, body, headers}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  # Req returns headers as %{"name" => ["value", ...]} with lowercased names.
  defp extract_mime_from_headers(headers) when is_map(headers) do
    case Map.get(headers, "content-type") do
      [value | _] when is_binary(value) -> value |> String.split(";") |> List.first()
      _ -> nil
    end
  end

  defp log_transport_error(action, error) do
    Logger.error("[Telegram] #{action} failed: #{inspect(error)}")
  end
end
