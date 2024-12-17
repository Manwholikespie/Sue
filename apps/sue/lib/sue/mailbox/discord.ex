defmodule Sue.Mailbox.Discord do
  use Nostrum.Consumer

  require Logger

  alias Sue.Models.{Message, Response}
  alias Nostrum.Api

  def start_link() do
    Consumer.start_link(__MODULE__)
  end

  def handle_event({:MESSAGE_CREATE, dmsg, _ws_state}) do
    msg = Message.from_discord(dmsg)
    Sue.process_messages([msg])
  end

  def handle_event(_event) do
    :noop
  end

  def send_response(_msg, %Response{body: nil, attachments: []}) do
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

  def send_response_text(msg, rsp) do
    with {:ok, _} <- Api.create_message(msg.metadata.channel_id, rsp.body) do
      :ok
    else
      error -> Logger.error(error |> inspect())
    end
  end

  def send_response_attachments(_, []), do: :ok

  def send_response_attachments(msg, [att | atts]) do
    Api.create_message(msg.metadata.channel_id, file: att.filepath)
    send_response_attachments(msg, atts)
  end
end
