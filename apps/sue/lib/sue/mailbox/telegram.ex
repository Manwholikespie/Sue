defmodule Sue.Mailbox.Telegram do
  use Telegex.Polling.GenHandler

  require Logger

  alias Sue.Models.{Message, Response, Attachment}

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
    Telegex.send_message(id, rsp.body)
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
end
