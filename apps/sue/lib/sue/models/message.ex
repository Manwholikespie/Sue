defmodule Sue.Models.Message do
  require Logger

  alias __MODULE__
  alias Sue.Models.{Account, Attachment, Chat, Platform, PlatformAccount}
  alias Sue.DB

  @enforce_keys [
    :platform,
    :id,
    #
    :paccount,
    :chat,
    :account,
    #
    :body,
    :command,
    :args,
    :time,
    #
    :is_from_sue,
    :is_ignorable
  ]
  defstruct [
    :platform,
    :id,
    #
    :paccount,
    :chat,
    :account,
    #
    :body,
    :command,
    :args,
    :attachments,
    :time,
    #
    :is_from_sue,
    :is_ignorable,
    :has_attachments,
    metadata: %{}
  ]

  @type t() :: %__MODULE__{
          # the name of the chat platform (imessage, telegram)
          platform: Platform.t(),
          id: bitstring() | integer(),
          ###
          paccount: PlatformAccount.t(),
          chat: Chat.t(),
          account: Account.t() | nil,
          ###
          body: String.t(),
          command: String.t(),
          args: String.t(),
          attachments: [Attachment.t()] | nil,
          time: DateTime.t(),
          ###
          is_from_sue: boolean(),
          is_ignorable: boolean(),
          has_attachments: boolean() | nil,
          metadata: map()
        }

  @spec from_imessage(Keyword.t()) :: t
  def from_imessage(kw) do
    [
      id: handle_id,
      person_centric_id: _handle_person_centric_id,
      cache_has_attachments: has_attachments,
      text: text,
      ROWID: message_id,
      cache_roomnames: chat_id,
      is_from_me: from_me,
      utc_date: utc_date
    ] = kw

    from_me = from_me == 1

    paccount =
      %PlatformAccount{platform_id: {:imessage, handle_id}}
      |> PlatformAccount.resolve()

    chat =
      %Chat{
        platform_id: {:imessage, chat_id || "direct;#{handle_id}"},
        is_direct: chat_id == nil
      }
      |> Chat.resolve()

    account = Account.from_paccount(paccount)

    {command, args, body} = command_args_from_body(:imessage, text)

    %Message{
      platform: :imessage,
      id: message_id,
      #
      paccount: paccount,
      chat: chat,
      account: account,
      #
      body: body,
      command: command,
      args: args,
      time: DateTime.from_unix!(utc_date),
      #
      is_from_sue: from_me,
      is_ignorable: is_ignorable?(:imessage, from_me, body) or account.is_ignored or chat.is_ignored,
      has_attachments: has_attachments == 1
    }
    |> add_account_and_chat_to_graph()
  end

  @spec from_telegram(Map.t()) :: t
  def from_telegram(%{msg: msg, context: context} = update) do
    {command, args, body} =
      case Map.get(update, :command) do
        nil -> command_args_from_body(:telegram, Map.get(msg, :caption, ""))
        c -> {c, msg.text, context.update.message.text}
      end

    command =
      parse_command_potentially_with_botname_suffix(
        command,
        "@" <> context.bot_info.username
      )

    paccount =
      %PlatformAccount{platform_id: {:telegram, msg.from.id}}
      |> PlatformAccount.resolve()

    chat =
      %Chat{
        platform_id: {:telegram, msg.chat.id},
        is_direct: msg.chat.type == "private"
      }
      |> Chat.resolve()

    account = Account.from_paccount(paccount)

    %Message{
      platform: :telegram,
      id: msg.chat.id,
      #
      paccount: paccount,
      chat: chat,
      account: account,
      #
      body: body |> better_trim(),
      time: DateTime.from_unix!(msg.date),
      #
      is_from_sue: false,
      is_ignorable: command == "" or account.is_ignored or chat.is_ignored,

      # either in the message sent, or the message referenced in a reply
      has_attachments:
        Map.get(msg, :photo) != nil or
          Map.get(msg, :document) != nil or
          Map.get(msg, :reply_to_message, %{})[:photo] != nil or
          Map.get(msg, :reply_to_message, %{})[:document] != nil,
      command: command,
      args: args
    }
    |> construct_attachments(msg)
    |> add_account_and_chat_to_graph()
  end

  def from_discord(msg) do
    paccount =
      %PlatformAccount{platform_id: {:discord, msg.author.id}}
      |> PlatformAccount.resolve()

    chat =
      %Chat{
        platform_id: {:discord, msg.guild_id || msg.author.id},
        is_direct: is_nil(msg.guild_id)
      }
      |> Chat.resolve()

    account = Account.from_paccount(paccount)

    {command, args, body} = command_args_from_body(:discord, msg.content)

    from_sue = msg.author.bot != nil

    %Message{
      platform: :discord,
      id: msg.id,
      #
      paccount: paccount,
      chat: chat,
      account: account,
      #
      body: body,
      command: command,
      args: args,
      time: msg.timestamp,
      #
      is_from_sue: from_sue,
      is_ignorable: from_sue or command == "" or account.is_ignored or chat.is_ignored,
      has_attachments: length(msg.attachments) > 0,
      metadata: %{channel_id: msg.channel_id}
    }
    |> add_account_and_chat_to_graph()
    |> construct_attachments(msg.attachments)
  end

  def from_debug(text) do
    paccount =
      %PlatformAccount{platform_id: {:debug, 0}}
      |> PlatformAccount.resolve()

    chat =
      %Chat{platform_id: {:debug, 0}, is_direct: true}
      |> Chat.resolve()

    account = Account.from_paccount(paccount)

    {command, args, body} = command_args_from_body(:debug, text)

    %Message{
      platform: :debug,
      id: Sue.Utils.random_string(),
      #
      paccount: paccount,
      chat: chat,
      account: account,
      #
      body: body,
      command: command,
      args: args,
      time: DateTime.utc_now(),
      #
      is_from_sue: false,
      is_ignorable: is_ignorable?(:debug, false, text) or account.is_ignored or chat.is_ignored,
      has_attachments: false
    }
    |> add_account_and_chat_to_graph()
  end

  # TODO: Move this inside the Attachments module. No clue why it's here.
  def construct_attachments(%Message{has_attachments: false} = msg, _), do: msg

  def construct_attachments(%Message{platform: :telegram} = msg, data) do
    list_of_atts =
      Map.get(data, :photo) ||
        Map.get(data, :document) ||
        Map.get(data, :reply_to_message, %{})[:photo] ||
        Map.get(data, :reply_to_message, %{})[:document]

    list_of_atts =
      if is_map(list_of_atts) do
        [list_of_atts]
      else
        list_of_atts
      end
      |> Enum.sort_by(fn a -> a.file_size end, :desc)

    %Message{
      msg
      | attachments:
          list_of_atts
          |> Enum.map(fn a -> Attachment.new(a, :telegram) end)
    }
  end

  def construct_attachments(%Message{platform: :discord} = msg, attachments) do
    %Message{
      msg
      | attachments:
          for a <- attachments do
            %Attachment{
              id: a.id,
              filename: a.filename,
              mime_type: MIME.from_path(a.filename),
              fsize: a.size,
              metadata: %{url: a.url, height: a.height, width: a.width},
              resolved: false
            }
          end
    }
  end

  @spec add_account_and_chat_to_graph(t()) :: t
  def add_account_and_chat_to_graph(%Message{account: a, chat: c} = msg) do
    {:ok, _dbid} = DB.add_user_chat_edge(a, c)
    msg
  end

  # TODO: Replace all of this with regular expressions.

  # returns {command, args, body}
  @spec command_args_from_body(Platform.t(), String.t()) ::
          {String.t(), String.t(), String.t()}
  defp command_args_from_body(platform, body) do
    if has_command?(platform, body) do
      trimmed_body = body |> better_trim()
      [command | args] = String.split(String.slice(trimmed_body, 1..-1), " ", parts: 2)
      {command, Enum.at(args, 0) || "", trimmed_body}
    else
      {"", "", body |> better_trim()}
    end
  end

  defp parse_command_potentially_with_botname_suffix(command, botname_suffix) do
    cond do
      String.ends_with?(command, botname_suffix) ->
        String.slice(command, 0, String.length(command) - String.length(botname_suffix))

      true ->
        command
    end
  end

  # character 65532 (OBJECT REPLACEMENT CHARACTER) is used in iMessage when you
  #   also have an image, like a fancy carriage return. trim_leading doesn't
  #   currently find this.
  defp better_trim_leading(text) when is_bitstring(text) do
    text
    |> String.replace_leading(List.to_string([65532]), "")
    |> String.trim_leading()
  end

  defp better_trim(text) do
    text
    |> better_trim_leading()
    |> String.trim_trailing()
  end

  # This binary classifier will grow in complexity over time.
  defp is_ignorable?(platform, from_sue, body)
  defp is_ignorable?(_platform, true, _body), do: true

  defp is_ignorable?(_platform, _from_me, ""), do: true

  defp is_ignorable?(platform, _from_me, body) do
    not has_command?(platform, body)
  end

  defp has_command?(:telegram, body) do
    Regex.match?(~r/^\/(?! )./u, body |> String.trim_leading())
  end

  defp has_command?(_platform, body) do
    Regex.match?(~r/^!(?! )./u, better_trim_leading(body))
  end

  # to_string override
  defimpl String.Chars, for: Message do
    def to_string(%Message{
          platform: platform,
          chat: %Chat{id: cid},
          account: %Account{id: aid}
        }) do
      "#Message<#{platform},#{cid},#{aid}>"
    end
  end

  def helper_is_direct?({:telegram, plid}, {_, plid}), do: true
  def helper_is_direct?(_, {:imessage, "direct;" <> _}), do: true
  def helper_is_direct?(_, _), do: false
end
