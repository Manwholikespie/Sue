defmodule Sue.Mailbox.Telegram do
  use Telegex.Polling.GenHandler

  require Logger

  alias Sue.Models.{Message, Response, Attachment}

  @telegram_max_length 4096

  @impl true
  def on_boot() do
    # delete any potential webhook
    {:ok, true} = Telegex.delete_webhook()

    # create configuration (can be empty, because there are default values)
    # allowed_updates = ["message"]
    %Telegex.Polling.Config{allowed_updates: []}
  end

  @impl true
  def on_update(update) do
    # consume the update
    Logger.debug(update |> inspect(pretty: true, limit: :infinity))
    message = Message.from_telegram2(update.message)
    Sue.process_messages([message])

    :ok
  end

  def send_response(_msg, %Response{body: nil, attachments: []}) do
    # Likely already sent custom response (ex: polls)
    :ok
  end

  def send_response(msg, %Response{attachments: []} = rsp) do
    # No attachments
    send_response_text(msg, rsp)
  end

  def send_response(msg, %Response{body: nil, attachments: atts}) do
    # No text
    send_response_attachments(msg, atts)
  end

  def send_response(%Message{} = msg, %Response{attachments: atts} = rsp) do
    send_response_text(msg, rsp)
    send_response_attachments(msg, atts)
  end

  # TODO: REPLACE
  @spec send_response_text(Message.t(), Response.t()) :: :ok
  def send_response_text(msg, rsp) do
    {_platform, id} = msg.chat.platform_id

    rsp.body
    |> split_message()
    |> Enum.each(fn chunk ->
      Telegex.send_message(id, chunk)
    end)

    :ok
  end

  def send_response_attachments(_msg, []), do: :ok

  # TODO: REPLACE
  def send_response_attachments(msg, [att | atts]) do
    {_platform, id} = msg.chat.platform_id

    if Attachment.has_url?(att) do
      Telegex.send_photo(id, att.url)
    else
      url = "https://api.telegram.org/bot#{Telegex.Global.token()}/sendPhoto"

      form = [
        {"chat_id", to_string(id)},
        {:file, att.filepath,
         {"form-data", [{"name", "photo"}, {"filename", Path.basename(att.filepath)}]}, []}
      ]

      # Make the request
      with {:ok, _response} <- HTTPoison.post(url, {:multipart, form}) do
        :ok
      end
    end

    send_response_attachments(msg, atts)
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
            <<chunk::binary-size(split_at), rest::binary>> = text
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
        <<chunk::binary-size(last_delim_pos), _delim::binary-size(byte_size(delimiter)),
          rest::binary>> = text

        {:ok, chunk, rest}

      remaining == 0 ->
        # No delimiter found in the entire searchable range
        :too_large

      current_pos >= @telegram_max_length ->
        # Exceeded limit, use last known delimiter position
        if last_delim_pos > 0 do
          <<chunk::binary-size(last_delim_pos), _delim::binary-size(byte_size(delimiter)),
            rest::binary>> = text

          {:ok, chunk, rest}
        else
          :too_large
        end

      true ->
        # Check if we have a delimiter at current position
        delim_size = byte_size(delimiter)

        case text do
          <<_::binary-size(current_pos), ^delimiter::binary-size(delim_size), _::binary>> ->
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
        <<chunk::binary-size(pos), _ws::binary-size(len), rest::binary>> = text
        {:ok, chunk, rest}

      _ ->
        :too_large
    end
  end
end
