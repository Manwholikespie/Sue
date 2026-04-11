defmodule Sue.Mailbox.Telegram do
  @moduledoc false

  alias ExGram.Model.InputPollOption
  require Logger

  alias Sue.Models.{Attachment, Message, Response}

  @telegram_max_length 4096
  @bot_name :sue_bot
  @tmp_path System.tmp_dir!()
  @default_mime "application/octet-stream"

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
         filepath <- Path.join(@tmp_path, filename <> Path.extname(file_path)),
         {:ok, body, headers} <- http_get(url),
         :ok <- File.write(filepath, body) do
      mime_type = original_mime_type || extract_mime_from_headers(headers) || @default_mime
      {:ok, filepath, file_size, mime_type}
    else
      {:error, error} -> {:error, error}
    end
  end

  # Split a message into chunks that fit within Telegram's character limit
  # Tries to split at paragraph boundaries, then word boundaries, then character boundaries
  @doc false
  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) when byte_size(text) <= @telegram_max_length do
    [text]
  end

  def split_message(text) do
    split_message_recursive(text, [])
  end

  defp split_message_recursive("", acc), do: Enum.reverse(acc)

  defp split_message_recursive(text, acc) do
    if byte_size(text) <= @telegram_max_length do
      Enum.reverse([text | acc])
    else
      {chunk, rest} = extract_chunk(text)
      split_message_recursive(rest, [chunk | acc])
    end
  end

  # Extract a chunk that fits within the limit
  defp extract_chunk(text) do
    # Try to split at paragraph boundary (double newline)
    case find_split_point(text, "\n\n") do
      {:ok, chunk, rest} ->
        {chunk, rest}

      :too_large ->
        # Try to split at any newline or space (word boundary)
        case find_split_point(text, ~r/[\s\n]/) do
          {:ok, chunk, rest} ->
            {chunk, rest}

          :too_large ->
            # Last resort: split at character boundary with hyphen
            # Take max_length - 1 to leave room for hyphen
            split_at = @telegram_max_length - 1
            <<chunk::binary-size(^split_at), rest::binary>> = text
            {chunk <> "-", rest}
        end
    end
  end

  # Find a split point using a delimiter, ensuring the chunk fits within the limit
  defp find_split_point(text, delimiter) when is_binary(delimiter) do
    find_split_point_binary(text, delimiter, 0, 0)
  end

  defp find_split_point(text, %Regex{} = regex) do
    find_split_point_regex(text, regex)
  end

  defp find_split_point_binary(text, delimiter, last_delim_pos, current_pos) do
    remaining = byte_size(text) - current_pos

    cond do
      remaining == 0 and last_delim_pos > 0 ->
        # Reached end of text, use last delimiter position
        delim_size = byte_size(delimiter)

        <<chunk::binary-size(^last_delim_pos), _delim::binary-size(^delim_size), rest::binary>> =
          text

        {:ok, chunk, rest}

      remaining == 0 ->
        # No delimiter found in the entire searchable range
        :too_large

      current_pos >= @telegram_max_length ->
        # Exceeded limit, use last known delimiter position
        if last_delim_pos > 0 do
          delim_size = byte_size(delimiter)

          <<chunk::binary-size(^last_delim_pos), _delim::binary-size(^delim_size), rest::binary>> =
            text

          {:ok, chunk, rest}
        else
          :too_large
        end

      true ->
        # Check if we have a delimiter at current position
        delim_size = byte_size(delimiter)

        case text do
          <<_::binary-size(^current_pos), ^delimiter::binary-size(^delim_size), _::binary>> ->
            # Found delimiter, update last known position and continue
            find_split_point_binary(text, delimiter, current_pos, current_pos + delim_size)

          _ ->
            # No delimiter here, move to next character
            find_split_point_binary(text, delimiter, last_delim_pos, current_pos + 1)
        end
    end
  end

  defp find_split_point_regex(text, regex) do
    # Find all matches within the limit
    searchable = binary_part(text, 0, min(byte_size(text), @telegram_max_length))
    matches = Regex.scan(regex, searchable, return: :index)

    case List.last(matches) do
      nil ->
        :too_large

      [{pos, len}] ->
        # Split at the last whitespace found
        <<chunk::binary-size(^pos), _ws::binary-size(^len), rest::binary>> = text
        {:ok, chunk, rest}

      _ ->
        :too_large
    end
  end

  defp chat_id(%Message{chat: %{platform_id: {_platform, id}}}), do: id

  defp http_get(url) do
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: status, body: body, headers: headers}}
      when status in 200..299 ->
        {:ok, body, headers}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp extract_mime_from_headers(headers) do
    Enum.find_value(headers, fn
      {name, [value | _rest]} ->
        header_mime(name, value)

      {name, value} ->
        header_mime(name, value)

      _ ->
        nil
    end)
  end

  defp header_mime(name, value) when is_binary(name) and is_binary(value) do
    if String.downcase(name) == "content-type" do
      value
      |> String.split(";")
      |> List.first()
    end
  end

  defp header_mime(_name, _value), do: nil

  defp log_transport_error(action, error) do
    Logger.error("[Telegram] #{action} failed: #{inspect(error)}")
  end
end
