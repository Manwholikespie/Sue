defmodule Sue.Mailbox.IMessage do
  use GenServer

  require Logger

  alias Sue.Models.{Attachment, Chat, Message, Response}
  alias Sue.Mailbox.IMessageSqlite

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

  # TODO: This would only work for iMessage groups, not SMS. Which for me personally
  #   is how I'd want it to be, but others may not. Changing it now would affect
  #   group IDs though, most likely.
  defp send_response_text(%Message{chat: %Chat{is_direct: false}} = msg, rsp) do
    {_platform, "chat" <> _ = chat_id} = msg.chat.platform_id

    Imessaged.send_message_to_chat(rsp.body, "iMessage;+;" <> chat_id)
  end

  defp send_response_attachments(_msg, []), do: :ok

  defp send_response_attachments(%Message{chat: %Chat{is_direct: true}} = msg, [att | atts]) do
    {_platform, account_id} = msg.paccount.platform_id

    {:ok, %Attachment{filepath: filepath}} = Attachment.download(att)
    :ok = Imessaged.send_file_to_buddy(filepath, account_id)

    send_response_attachments(msg, atts)
  end

  defp send_response_attachments(%Message{chat: %Chat{is_direct: false}} = msg, [att | atts]) do
    {_platform, "chat" <> _ = chat_id} = msg.chat.platform_id

    {:ok, %Attachment{filepath: filepath}} = Attachment.download(att)
    :ok = Imessaged.send_file_to_chat(filepath, "iMessage;+;" <> chat_id)

    send_response_attachments(msg, atts)
  end

  # === UTILS ===
  defp process_messages([]), do: :ok

  defp process_messages(msgs) do
    new_messages =
      msgs
      |> Enum.sort_by(fn m -> Keyword.get(m, :utc_date) end)
      |> Enum.map(fn m -> Message.from_imessage(m) end)
      |> add_attachments()
      |> set_new_max_rowid()

    Logger.debug("Found new messages to process: #{new_messages |> inspect(pretty: true)}")

    Sue.process_messages(new_messages)
  end

  defp add_attachments(msgs) do
    msgs_with_attachments = Enum.filter(msgs, fn m -> m.has_attachments end)

    # %{message_id1 => [attachment1, attachment2, ...], message_id2 => [attachment3, ...]}
    attachments =
      case msgs_with_attachments do
        [] ->
          %{}

        _ ->
          (msgs_with_attachments
           |> Enum.min_by(fn m -> m.id end)).id
          |> query_attachments_since()
          |> Enum.map(fn a -> Attachment.new(a, :imessage) end)
          |> Enum.filter(fn a -> a.mime_type != nil end)
          |> Enum.group_by(fn a -> a.metadata.message_id end)
      end

    msgs
    |> Enum.map(fn m ->
      if m.has_attachments do
        %Message{m | attachments: Map.get(attachments, m.id)}
      else
        %Message{m | attachments: []}
      end
    end)
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
        # Haven't seen it before, use the max of ROWID.
        [[rowid]] = IMessageSqlite.query("SELECT MAX(message.ROWID) AS ROWID FROM message;")
        Subaru.Cache.put(@cache_table, "imsg_max_rowid", rowid)
        rowid

      res ->
        res
    end
  end

  defp query_messages_since(rowid) do
    q = """
    SELECT handle.id, handle.person_centric_id, message.cache_has_attachments, message.text, message.ROWID, message.cache_roomnames, message.is_from_me, message.date/1000000000 + 978307200 AS utc_date FROM message INNER JOIN handle ON message.handle_id = handle.ROWID WHERE message.ROWID > #{rowid};
    """

    case IMessageSqlite.query(q) do
      [] -> []
      messages -> Enum.map(messages, fn m -> message_row_to_keyword_list(m) end)
    end
  end

  defp query_attachments_since(rowid) do
    Logger.debug("Querying attachments since rowid #{rowid}...?")

    q = """
    SELECT attachment.ROWID AS a_id, message_attachment_join.message_id AS m_id, attachment.filename, attachment.mime_type, attachment.total_bytes FROM attachment INNER JOIN message_attachment_join ON attachment.ROWID == message_attachment_join.attachment_id WHERE message_attachment_join.message_id >= #{rowid};
    """

    case IMessageSqlite.query(q) do
      [] -> []
      attachments -> Enum.map(attachments, fn a -> attachment_row_to_keyword_list(a) end)
    end
  end

  defp message_row_to_keyword_list([
         id,
         person_centric_id,
         cache_has_attachments,
         text,
         rowid,
         cache_roomnames,
         is_from_me,
         utc_date
       ]) do
    [
      id: id,
      person_centric_id: person_centric_id,
      cache_has_attachments: cache_has_attachments,
      text: text,
      ROWID: rowid,
      cache_roomnames: cache_roomnames,
      is_from_me: is_from_me,
      utc_date: utc_date
    ]
  end

  defp attachment_row_to_keyword_list([a_id, m_id, filename, mime_type, total_bytes]) do
    [a_id: a_id, m_id: m_id, filename: filename, mime_type: mime_type, total_bytes: total_bytes]
  end
end
