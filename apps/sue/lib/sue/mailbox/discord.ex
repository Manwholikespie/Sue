defmodule Sue.Mailbox.Discord do
  # We don't need a start_link, due to the way they've set up their __using__ macro.
  use Nostrum.Consumer

  require Logger

  alias Sue.Models.Attachment
  alias Sue.Models.{Message, Response}
  alias Nostrum.Api

  import Nostrum.Struct.Embed

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

  @spec send_response_attachments(Message.t(), [Attachment.t()]) :: :ok
  def send_response_attachments(_, []), do: :ok

  def send_response_attachments(msg, [att = %Attachment{} | atts]) do
    Logger.debug(att |> inspect())

    filepath =
      if Attachment.has_url?(att) do
        {:ok, %Attachment{filepath: fp}} = Attachment.download(att)
        fp
      else
        att.filepath
      end

    Api.create_message(msg.metadata.channel_id, file: filepath)

    send_response_attachments(msg, atts)
  end

  @spec send_response_embed(Message.t(), bitstring()) :: :ok
  def send_response_embed(msg, url) do
    embed =
      %Nostrum.Struct.Embed{}
      |> put_image(url)

    {:ok, _message} = Api.create_message(msg.metadata.channel_id, embeds: [embed])
    :ok
  end
end
