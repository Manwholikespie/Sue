defmodule Sue.Models.Message do
  @moduledoc false

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
          body: bitstring(),
          command: bitstring(),
          args: bitstring(),
          attachments: [Attachment.t()] | nil,
          time: DateTime.t(),
          ###
          is_from_sue: boolean(),
          is_ignorable: boolean(),
          has_attachments: boolean() | nil,
          metadata: map()
        }

  @spec from_imessage(map()) :: t
  def from_imessage(msg) when is_map(msg) do
    Logger.debug("casting: #{msg |> inspect(pretty: true)}")

    message_id = msg["ROWID"]
    handle_id = msg["sender"]
    has_attachments = msg["has_attachments"]
    text = msg["content"]
    chat_identifier = msg["chat_identifier"]
    is_direct = msg["is_direct"]
    service = msg["service"]
    from_me = msg["from_me"] == 1
    attachments = msg["attachments"] || []

    time = parse_imessage_time(msg["date"])

    paccount =
      %PlatformAccount{platform_id: {:imessage, handle_id}}
      |> PlatformAccount.resolve()

    chat =
      %Chat{
        platform_id: {:imessage, chat_identifier || handle_id},
        is_direct: is_direct
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
      attachments: attachments,
      time: time,
      #
      is_from_sue: from_me,
      is_ignorable: ignorable?(:imessage, from_me, body) or account.is_ignored or chat.is_ignored,
      has_attachments: has_attachments == 1,
      metadata: %{service: service}
    }
    |> add_account_and_chat_to_graph()
  end

  # Parse the date string from iMessage's SQLite format ("2024-01-15 10:30:45")
  # into a UTC DateTime. Falls back to the current time on any parse failure.
  @spec parse_imessage_time(String.t() | nil | any()) :: DateTime.t()
  defp parse_imessage_time(nil), do: DateTime.utc_now()

  defp parse_imessage_time(date_str) when is_binary(date_str) do
    case NaiveDateTime.from_iso8601(String.replace(date_str, " ", "T")) do
      {:ok, naive_dt} -> DateTime.from_naive!(naive_dt, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  defp parse_imessage_time(_), do: DateTime.utc_now()

  def from_telegram(msg) do
    {command, args, body} =
      command_args_from_body(:telegram, telegram_text(msg))

    command = parse_command_potentially_with_botname_suffix(command)

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
      id: "#{msg.chat.id}.#{msg.message_id}",
      #
      paccount: paccount,
      chat: chat,
      account: account,
      #
      body: body,
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
      has_attachments: msg.attachments != [],
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
      is_ignorable: ignorable?(:debug, false, text) or account.is_ignored or chat.is_ignored,
      has_attachments: false
    }
    |> add_account_and_chat_to_graph()
  end

  @spec construct_attachments(t(), any()) :: t()
  defp construct_attachments(%Message{has_attachments: false} = msg, _), do: msg

  # NOTE: Because Telegram does not offer a way to distinguish between a photo
  # and a smaller size of another photo, we only allow sending one photo at a time as
  # a command arg (Process only the largest image).
  defp construct_attachments(%Message{platform: :telegram} = msg, data) do
    list_of_atts =
      data.photo ||
        data.document ||
        if(data.reply_to_message, do: data.reply_to_message.photo, else: nil) ||
        if data.reply_to_message, do: data.reply_to_message.document, else: nil

    list_of_atts =
      if is_map(list_of_atts) do
        [list_of_atts]
      else
        list_of_atts
      end
      |> Enum.sort_by(fn a -> a.file_size end, :desc)
      |> Enum.take(1)

    %Message{
      msg
      | attachments:
          list_of_atts
          |> Enum.map(fn a -> Attachment.new(a, :telegram) end)
    }
  end

  defp construct_attachments(%Message{platform: :discord} = msg, attachments) do
    %Message{
      msg
      | attachments:
          for a <- attachments do
            %Attachment{
              id: a.id,
              url: a.url,
              filepath: a.filename,
              mime_type: MIME.from_path(a.filename),
              fsize: a.size,
              downloaded: false,
              metadata: %{url: a.url, height: a.height, width: a.width}
            }
          end
    }
  end

  @spec add_account_and_chat_to_graph(t()) :: t
  defp add_account_and_chat_to_graph(%Message{account: a, chat: c} = msg) do
    {:ok, _dbid} = DB.add_user_chat_edge(a, c)
    msg
  end

  defp telegram_text(msg) do
    better_trim(msg.text || msg.caption || "")
  end

  # Command prefix per platform. Telegram uses "/" because that's what its
  # native bot UI expects; everyone else uses "!". Add new platforms here.
  @command_prefixes %{
    imessage: "!",
    telegram: "/",
    discord: "!",
    debug: "!"
  }

  @spec command_prefix(Platform.t()) :: String.t()
  defp command_prefix(platform), do: Map.fetch!(@command_prefixes, platform)

  # returns {command, args, body}
  @spec command_args_from_body(Platform.t(), bitstring()) ::
          {bitstring(), bitstring(), bitstring()}
  defp command_args_from_body(platform, body) do
    trimmed_body = better_trim(body)
    prefix = command_prefix(platform)

    case Regex.run(command_regex(prefix), trimmed_body) do
      [_, command, args] -> {String.downcase(command), args, trimmed_body}
      [_, command] -> {String.downcase(command), "", trimmed_body}
      nil -> {"", "", trimmed_body}
    end
  end

  # Matches: <prefix><command>[<whitespace><args>]
  # The prefix must be followed immediately by a non-space character.
  defp command_regex(prefix) do
    ~r/^#{Regex.escape(prefix)}(\S+)(?:\s+(.*))?$/us
  end

  # Previously, I would trim according to a trailing @BotName on the command. Now, I just trim
  # everything after a found @
  defp parse_command_potentially_with_botname_suffix(command) do
    if String.contains?(command, "@") do
      String.split(command, "@", parts: 2) |> hd()
    else
      command
    end
  end

  # character 65532 (OBJECT REPLACEMENT CHARACTER) is used in iMessage when you
  #   also have an image, like a fancy carriage return. trim_leading doesn't
  #   currently find this.
  defp better_trim_leading(nil), do: ""

  defp better_trim_leading(text) when is_bitstring(text) do
    text
    |> String.replace_leading(List.to_string([65_532]), "")
    |> String.trim_leading()
  end

  defp better_trim(text) do
    text
    |> better_trim_leading()
    |> String.trim_trailing()
  end

  # This binary classifier will grow in complexity over time.
  defp ignorable?(platform, from_sue, body)
  defp ignorable?(_platform, true, _body), do: true

  defp ignorable?(_platform, _from_me, ""), do: true

  defp ignorable?(platform, _from_me, body) do
    not has_command?(platform, body)
  end

  defp has_command?(platform, body) do
    prefix = command_prefix(platform)
    Regex.match?(~r/^#{Regex.escape(prefix)}\S/u, better_trim_leading(body))
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
end
