defmodule Sue.AI.Interjection do
  @moduledoc """
  Local-model gate for deciding when Sue should invoke the expensive assistant.

  The local model only decides whether to escalate the latest chat turn to the
  Claude-backed `Sue.AI.chat_completion/3` path. It does not answer users.
  """

  require Logger

  alias Sue.Models.{Account, Attachment, Chat, Message, Response}

  defmodule Decision do
    @moduledoc false

    @type t :: %__MODULE__{
            should_interject: boolean(),
            confidence: float(),
            reason: String.t(),
            raw: map() | nil
          }

    defstruct should_interject: false,
              confidence: 0.0,
              reason: "",
              raw: nil
  end

  @default_base_url "http://localhost:11434/v1"
  @default_model "LiquidAI/lfm2.5-1.2b-instruct:q5_k_m"
  @default_timeout 8_000
  @default_threshold 0.7
  @default_invoke_rate_limit {:timer.minutes(5), 20}
  @default_response_format %{"type" => "json_object"}

  @system_prompt """
  You decide whether Sue, a group-chat bot, should interject by asking a smarter AI model.

  You are only a gatekeeper. Do not answer the user. Read the recent transcript and decide if the latest message should be processed by Sue's Claude-backed AI.

  Return only a JSON object with these keys:
  - should_interject: boolean
  - confidence: number from 0.0 to 1.0
  - reason: short string

  Prefer false. Return true only when the latest message clearly invites Sue (addresses her by name, asks the bot/AI for help, asks for interpretation, opinion, or commentary on something just said). Self-notes ("reminding myself to...", "note to self", "TIL...", venting), acknowledgements ("ok", "thanks", "lol"), commands for other bots, status updates, and ordinary conversation between humans should always return false — even in a direct chat with Sue.

  Media markers such as <media:image> mean an attachment was present; you cannot see the pixels. Only return true for media when the surrounding text or chat context makes Sue's response useful.
  """

  @doc """
  Returns true when a message is eligible for automatic interjection.

  Commands, Sue's own messages, ignored chats/users, and banned users are never
  candidates. Plain non-command text and media can be candidates.
  """
  @spec candidate?(Message.t()) :: boolean()
  def candidate?(%Message{is_from_sue: true}), do: false
  def candidate?(%Message{command: command}) when is_binary(command) and command != "", do: false
  def candidate?(%Message{account: %Account{is_ignored: true}}), do: false
  def candidate?(%Message{account: %Account{is_banned: true}}), do: false
  def candidate?(%Message{chat: %Chat{is_ignored: true}}), do: false

  def candidate?(%Message{} = msg) do
    visible_text?(msg) or has_media?(msg)
  end

  @doc """
  Decide whether Sue should escalate the latest message to Claude.
  """
  @spec decide(Message.t(), keyword()) :: {:ok, Decision.t()} | {:error, term()}
  def decide(%Message{} = msg, opts \\ []) do
    opts = opts(opts)

    messages = [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: decision_prompt(msg, recent_messages(msg, opts))}
    ]

    request =
      [
        base_url: Keyword.get(opts, :base_url),
        model: Keyword.get(opts, :model),
        messages: messages,
        temperature: Keyword.get(opts, :temperature, 0),
        max_tokens: Keyword.get(opts, :max_tokens, 220),
        timeout: Keyword.get(opts, :timeout),
        response_format: Keyword.get(opts, :response_format, @default_response_format)
      ]
      |> Keyword.merge(
        Keyword.take(opts, [:api_key, :headers, :provider, :http_client, :extra_body, :think])
      )
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    chat_client = Keyword.get(opts, :chat_client, &complete_with_bream/1)

    case chat_client.(request) do
      {:ok, message} ->
        parse_decision(assistant_text(message))

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_chat_response, other}}
    end
  end

  @doc """
  If the classifier says yes, invoke the Claude-backed Sue response.

  Returns `:ignore` when Sue should stay silent.
  """
  @spec reply(Message.t(), keyword()) :: {:ok, Response.t()} | :ignore
  def reply(%Message{} = msg, opts \\ []) do
    opts = opts(opts)

    cond do
      not Keyword.get(opts, :enabled, true) ->
        :ignore

      not candidate?(msg) ->
        :ignore

      true ->
        maybe_reply(msg, opts)
    end
  end

  @doc false
  @spec format_recent_body(Message.t()) :: String.t()
  def format_recent_body(%Message{} = msg) do
    text = msg.body |> string_value() |> String.trim()
    media = media_markers(msg)

    cond do
      text != "" and media != "" -> text <> " " <> media
      text != "" -> text
      media != "" -> media
      true -> ""
    end
  end

  defp maybe_reply(msg, opts) do
    case decide(msg, opts) do
      {:ok, %Decision{} = decision} ->
        if should_interject?(decision, opts) do
          invoke_sue_ai(msg, decision, opts)
        else
          :ignore
        end

      {:error, reason} ->
        Logger.warning("[Sue.Interjection] classifier failed: #{inspect(reason)}")
        :ignore
    end
  end

  defp should_interject?(%Decision{should_interject: true, confidence: confidence}, opts) do
    confidence >= Keyword.get(opts, :threshold, @default_threshold)
  end

  defp should_interject?(_decision, _opts), do: false

  defp invoke_sue_ai(%Message{} = msg, %Decision{} = _decision, opts) do
    case check_invoke_limits(msg, opts) do
      :ok ->
        completion_fun = Keyword.get(opts, :completion_fun, &Sue.AI.chat_completion/4)

        %Response{
          body: invoke_completion(completion_fun, fallback_prompt(msg), msg),
          is_from_gpt: true
        }
        |> then(&{:ok, &1})

      {:deny, reason} ->
        Logger.info("[Sue.Interjection] suppressed by #{reason} for chat #{msg.chat.id}")

        :ignore
    end
  end

  defp invoke_completion(completion_fun, prompt, %Message{} = msg) do
    case :erlang.fun_info(completion_fun, :arity) do
      {:arity, 4} -> completion_fun.(prompt, msg.chat, msg.account, msg.attachments || [])
      {:arity, 3} -> completion_fun.(prompt, msg.chat, msg.account)
    end
  end

  defp check_invoke_limits(%Message{chat: %Chat{is_direct: true}} = msg, opts) do
    check_gpt_limit(msg, opts)
  end

  defp check_invoke_limits(%Message{} = msg, opts) do
    interjection_rate =
      check_rate(
        "sue-interjection:#{msg.chat.id}",
        Keyword.get(opts, :invoke_rate_limit, @default_invoke_rate_limit),
        false
      )

    case interjection_rate do
      :ok ->
        check_gpt_limit(msg, opts)

      :deny ->
        {:deny, :interjection_rate_limit}
    end
  end

  defp check_gpt_limit(%Message{} = msg, opts) do
    case check_rate(
           "gpt:#{msg.account.id}",
           Keyword.get(opts, :gpt_rate_limit, Application.get_env(:sue, :gpt_rate_limit)),
           msg.account.is_premium
         ) do
      :ok -> :ok
      :deny -> {:deny, :gpt_rate_limit}
    end
  end

  defp check_rate(_id, nil, _can_bypass), do: :ok
  defp check_rate(_id, false, _can_bypass), do: :ok

  defp check_rate(id, rate_limit, can_bypass),
    do: Sue.Limits.check_rate(id, rate_limit, can_bypass)

  defp opts(overrides) do
    :sue
    |> Application.get_env(:interjection, [])
    |> Keyword.merge(overrides)
    |> Keyword.put_new(:base_url, @default_base_url)
    |> Keyword.put_new(:model, @default_model)
    |> Keyword.put_new(:timeout, @default_timeout)
    |> Keyword.put_new(:threshold, @default_threshold)
  end

  defp recent_messages(%Message{} = msg, opts) do
    Keyword.get_lazy(opts, :recent_messages, fn ->
      Sue.DB.RecentMessages.get(msg.chat.id)
    end)
  end

  defp decision_prompt(%Message{} = msg, recent_messages) do
    """
    Chat kind: #{chat_kind(msg)}
    Latest speaker: #{Account.friendly_name(msg.account)}
    Latest message has media: #{has_media?(msg)}

    Recent transcript, oldest to newest. The final line is the latest message:
    #{format_transcript(recent_messages)}

    Should Sue ask the smarter AI to respond to the latest message?
    """
  end

  defp chat_kind(%Message{chat: %Chat{is_direct: true}}), do: "direct chat with Sue"
  defp chat_kind(_), do: "group chat"

  defp format_transcript(messages) do
    messages
    |> Enum.take(-10)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {message, index} ->
      body =
        message
        |> Map.get(:body, "")
        |> string_value()
        |> String.slice(0, 1_000)

      "#{index}. #{speaker(message)}: #{body}"
    end)
  end

  defp speaker(%{is_from_gpt: true}), do: "Sue"
  defp speaker(%{is_from_sue: true}), do: "Sue"
  defp speaker(%{name: name}) when is_binary(name) and name != "", do: name
  defp speaker(_), do: "Unknown"

  defp parse_decision(text) when is_binary(text) do
    case decode_json_object(text) do
      {:ok, decoded} -> {:ok, decision_from_map(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json_object(text) do
    case text |> strip_code_fence() |> decode_map_json() do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> decode_embedded_json_object(text)
    end
  end

  defp decode_embedded_json_object(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> decode_map_json(json)
      _ -> {:error, {:invalid_decision_json, text}}
    end
  end

  defp decode_map_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, {:invalid_decision_json, json}}
    end
  end

  defp decision_from_map(decoded) do
    should_interject =
      boolean_field(decoded, [
        "should_interject",
        "interject",
        "relevant",
        "use_claude",
        "should_process_image"
      ])

    confidence =
      number_field(decoded, ["confidence", "score", "probability"]) ||
        if(should_interject, do: 1.0, else: 0.0)

    %Decision{
      should_interject: should_interject,
      confidence: clamp(confidence),
      reason: string_field(decoded, ["reason", "why"]) || "",
      raw: decoded
    }
  end

  defp strip_code_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  defp boolean_field(map, keys) do
    keys
    |> Enum.map(&Map.get(map, &1))
    |> Enum.find_value(false, &truthy?/1)
  end

  defp truthy?(true), do: true
  defp truthy?(false), do: false

  defp truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["true", "yes", "y", "1", "interject", "respond"]

  defp truthy?(value) when is_number(value), do: value > 0
  defp truthy?(_), do: false

  defp number_field(map, keys) do
    keys
    |> Enum.map(&Map.get(map, &1))
    |> Enum.find_value(&parse_number/1)
  end

  defp parse_number(value) when is_number(value), do: value / 1

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp parse_number(_), do: nil

  defp string_field(map, keys) do
    keys
    |> Enum.map(&Map.get(map, &1))
    |> Enum.find_value(fn
      value when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp clamp(number) when number < 0, do: 0.0
  defp clamp(number) when number > 1, do: 1.0
  defp clamp(number), do: number

  defp fallback_prompt(%Message{} = msg) do
    case format_recent_body(msg) do
      "" -> "Respond to the latest message in the chat."
      body -> body
    end
  end

  defp visible_text?(%Message{body: body}) when is_binary(body), do: String.trim(body) != ""
  defp visible_text?(_), do: false

  defp string_value(nil), do: ""
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value), do: to_string(value)

  defp has_media?(%Message{attachments: attachments}) when is_list(attachments),
    do: attachments != []

  defp has_media?(%Message{has_attachments: true}), do: true
  defp has_media?(_), do: false

  defp media_markers(%Message{attachments: attachments}) when is_list(attachments) do
    attachments
    |> Enum.map(&media_marker/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp media_markers(%Message{has_attachments: true}), do: "<media>"
  defp media_markers(_), do: ""

  defp media_marker(%Attachment{} = attachment) do
    cond do
      Attachment.image?(attachment) -> "<media:image>"
      is_binary(attachment.mime_type) -> "<media:#{attachment.mime_type}>"
      true -> "<media>"
    end
  end

  defp media_marker(_), do: "<media>"

  defp complete_with_bream(request) do
    if Code.ensure_loaded?(Bream.Chat) and function_exported?(Bream.Chat, :complete, 1) do
      apply(Bream.Chat, :complete, [request])
    else
      {:error, :bream_chat_unavailable}
    end
  end

  defp assistant_text(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{text: text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join()
  end

  defp assistant_text(%{content: text}) when is_binary(text), do: text
  defp assistant_text(text) when is_binary(text), do: text
  defp assistant_text(_), do: ""
end
