defmodule Sue.Mailbox.Telegram do
  @moduledoc false

  alias ExGram.Model.InputPollOption
  require Logger

  alias Sue.Models.{Attachment, Message, Response}

  # Telegram's message limit is 4096 UTF-16 code units. Counting graphemes is
  # conservative: grapheme count <= code unit count, so we'll never exceed
  # Telegram's limit, though we may split slightly earlier on grapheme-heavy text.
  @telegram_max_length 4096
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

  # Split a message into chunks that fit within Telegram's character limit.
  # Prefers paragraph boundaries, then whitespace, then a hard split with a
  # trailing hyphen. Operates on graphemes (not bytes) so multi-byte UTF-8
  # characters are never split in half.
  @doc false
  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) when is_binary(text) do
    if String.length(text) <= @telegram_max_length do
      [text]
    else
      split_chunks(text, [])
    end
  end

  defp split_chunks("", acc), do: Enum.reverse(acc)

  defp split_chunks(text, acc) do
    if String.length(text) <= @telegram_max_length do
      Enum.reverse([text | acc])
    else
      {chunk, rest} = take_chunk(text)
      split_chunks(rest, [chunk | acc])
    end
  end

  # Peel off a chunk of at most @telegram_max_length graphemes. String.split_at/2
  # respects grapheme boundaries, so `window` is always valid UTF-8. Inside the
  # window we can safely use :binary.matches/2 with ASCII delimiters because
  # ASCII bytes never appear as UTF-8 continuation bytes.
  defp take_chunk(text) do
    {window, tail} = String.split_at(text, @telegram_max_length)

    cond do
      match = last_ascii_match(window, "\n\n") ->
        split_window(window, match, tail)

      match = last_ascii_match(window, [" ", "\t", "\n", "\r"]) ->
        split_window(window, match, tail)

      true ->
        # Fallback: take max_length - 1 graphemes and append a hyphen so the
        # total chunk length is exactly @telegram_max_length characters.
        {chunk, rest} = String.split_at(window, @telegram_max_length - 1)
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
