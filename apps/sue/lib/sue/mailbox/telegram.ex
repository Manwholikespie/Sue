defmodule Sue.Mailbox.Telegram do
  @bot :sue
  @pretty_debug false

  require Logger

  alias Sue.Models.{Message, Response}

  use ExGram.Bot,
    name: @bot

  def bot(), do: @bot

  def handle({:command, command, msg}, context) do
    Logger.debug("=== begin :command handle ===")
    Logger.debug("command: #{command |> inspect(pretty: @pretty_debug)}")
    Logger.debug("msg: #{msg |> inspect(pretty: @pretty_debug)}")
    Logger.debug("context: #{context |> inspect(pretty: @pretty_debug)}")
    Logger.debug("=== end :command handle ===")

    msg = Message.from_telegram(%{msg: msg, command: command, context: context})
    Sue.process_messages([msg])
    context
  end

  def handle({:message, msg}, context) do
    Logger.debug("=== begin :message handle ===")
    Logger.debug("msg: #{msg |> inspect(pretty: @pretty_debug)}")
    Logger.debug("context: #{context |> inspect(pretty: @pretty_debug)}")
    Logger.debug("=== end :message handle ===")
    # Logger.info("msg: #{inspect(msg)}\n\ncontext: #{inspect(context)}")
    msg = Message.from_telegram(%{msg: msg, context: context})
    Sue.process_messages([msg])
    context
  end

  def handle({:text, _text, msg}, context) do
    # Direct text or reply in group
    Logger.debug("=== begin :text handle ===")
    item = %{msg: msg, context: context}
    Logger.debug(item |> inspect())
    Sue.process_messages([Message.from_telegram(item)])
    Logger.debug("=== end :text handle ===")
    :ok
  end

  def handle({:update, _update}, _context) do
    # Poll responses
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

  def send_response_text(msg, rsp) do
    {_platform, id} = msg.chat.platform_id
    case ExGram.send_message(id, rsp.body) do
      {:ok, _} -> :ok
      {:error, error} ->
        Logger.error("Failed to send message: #{inspect(error)}")
        :error
    end
  end

  def send_response_attachments(_msg, []), do: :ok

  def send_response_attachments(msg, [att | atts]) do
    {_platform, id} = msg.chat.platform_id
    ExGram.send_photo(id, {:file, att.filepath})
    send_response_attachments(msg, atts)
  end
end
