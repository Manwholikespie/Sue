defmodule Sue.Mailbox.IMessage do
  use GenServer

  require Logger

  alias Sue.Models.{Attachment, Chat, Message, Response}

  @update_interval 1_000
  @cache_table :suestate_cache

  def start_link(args) do
    Logger.info("Starting IMessage genserver...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    # https://blog.appsignal.com/2019/05/14/elixir-alchemy-background-processing.html
    Process.send_after(self(), :get_updates, @update_interval)
    {:ok, nil}
  end

  @impl true
  def handle_info(:get_updates, _last_run_at) do
    get_updates()
    Process.send_after(self(), :get_updates, @update_interval)
    {:noreply, :calendar.local_time()}
  end

  # === INBOX ===
  @spec get_updates :: :ok
  def get_updates() do
    get_current_max_rowid()
    |> query_messages_since()
    |> process_messages()
  end

  def send_response(_msg, %Response{body: nil, attachments: []}), do: :ok

  def send_response(msg, %Response{attachments: []} = rsp) do
    send_response_text(msg, rsp)
  end

  def send_response(msg, %Response{body: nil, attachments: atts}) do
    send_response_attachments(msg, atts)
  end

  def send_response(msg, %Response{attachments: atts} = rsp) do
    send_response_text(msg, rsp)
    send_response_attachments(msg, atts)
  end

  # === OUTBOX ===
  defp send_response_text(%Message{chat: %Chat{is_direct: true}} = msg, rsp) do
    {_platform, account_id} = msg.paccount.platform_id

    Imessaged.send_message_to_buddy(rsp.body, account_id)
  end

  defp send_response_text(%Message{chat: %Chat{is_direct: false}} = msg, rsp) do
    {_platform, chat_identifier} = msg.chat.platform_id
    service = Map.get(msg.metadata, :service, "iMessage")

    Imessaged.send_message_to_chat(rsp.body, "#{service};+;#{chat_identifier}")
  end

  defp send_response_attachments(_msg, []), do: :ok

  defp send_response_attachments(%Message{chat: %Chat{is_direct: true}} = msg, [att | atts]) do
    {_platform, account_id} = msg.paccount.platform_id

    {:ok, %Attachment{filepath: filepath}} = Attachment.download(att)
    :ok = Imessaged.send_file_to_buddy(filepath, account_id)

    send_response_attachments(msg, atts)
  end

  defp send_response_attachments(%Message{chat: %Chat{is_direct: false}} = msg, [att | atts]) do
    {_platform, chat_identifier} = msg.chat.platform_id
    service = Map.get(msg.metadata, :service, "iMessage")

    {:ok, %Attachment{filepath: filepath}} = Attachment.download(att)
    :ok = Imessaged.send_file_to_chat(filepath, "#{service};+;#{chat_identifier}")

    send_response_attachments(msg, atts)
  end

  # === UTILS ===
  defp process_messages([]), do: :ok

  defp process_messages(msgs) do
    new_messages =
      msgs
      |> Enum.map(&process_attachments_in_message/1)
      |> Enum.map(fn m -> Message.from_imessage(m) end)
      |> set_new_max_rowid()

    Logger.debug("Found new messages to process: #{new_messages |> inspect(pretty: true)}")

    Sue.process_messages(new_messages)
  end

  defp process_attachments_in_message(msg) do
    # Convert attachment maps from imessaged into Attachment structs
    attachments =
      case msg["attachments"] do
        list when is_list(list) ->
          Enum.map(list, fn a -> Attachment.new(a, :imessage) end)

        _ ->
          []
      end

    Map.put(msg, "attachments", attachments)
  end

  @spec set_new_max_rowid([Message.t(), ...]) :: [Message.t(), ...]
  defp set_new_max_rowid(msgs) do
    rowid = Enum.max_by(msgs, fn m -> m.id end).id
    Subaru.Cache.put(@cache_table, "imsg_max_rowid", rowid)
    # DB.set(:state, "imsg_max_rowid", rowid)
    msgs
  end

  @doc """
  If you delete a bugged chat.db, your message ID counter will reset to 0, but
    Sue will still think that you're at the old, higher ID. This clears the
    cache so that it will just pick up from the next message.

  TODO: A better approach for this is to keep track of the last message ID we
    replied to, and then make some checks on startup to see if this message is
    even still present in the DB.
  """
  def clear_max_rowid() do
    Subaru.Cache.del!(@cache_table, "imsg_max_rowid")
    # DB.del!(:state, "imsg_max_rowid")
  end

  defp get_current_max_rowid() do
    # Check to see if we have one stored.
    case Subaru.Cache.get!(@cache_table, "imsg_max_rowid") do
      nil ->
        # Haven't seen it before, use the current max ROWID so we only process new messages
        case Imessaged.DB.connect() do
          {:ok, conn} ->
            result =
              case Imessaged.DB.query(conn, "SELECT MAX(ROWID) FROM message;", []) do
                {:ok, [[rowid]]} when is_integer(rowid) ->
                  Subaru.Cache.put(@cache_table, "imsg_max_rowid", rowid)
                  Logger.info("Starting iMessage polling from ROWID #{rowid}")
                  rowid

                _ ->
                  Logger.warning("Could not get max ROWID from iMessage DB, starting from 0")
                  0
              end

            Imessaged.DB.disconnect(conn)
            result

          {:error, _} ->
            Logger.warning("Could not connect to iMessage DB, starting from 0")
            0
        end

      rowid ->
        rowid
    end
  end

  defp query_messages_since(rowid) do
    case Imessaged.Messages.get_messages_since(rowid, limit: 100) do
      {:ok, messages} ->
        # Filter out messages from Sue
        Enum.filter(messages, fn msg -> msg["from_me"] == 0 end)

      {:error, reason} ->
        Logger.error("Failed to query messages: #{inspect(reason)}")
        []
    end
  end

end
