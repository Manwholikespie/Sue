defmodule Sue.AI do
  @moduledoc """
  Claude-backed chat completion for Sue, via Bream.

  Sue keeps one Bream session per chat (`Sue.AI.Sessions`), so Claude
  carries conversation history across `!gpt` invocations and interjections
  within a 12h idle window. On a fresh session we seed Claude with the
  current `RecentMessages` cache so it has lead-in context for the
  triggering message; on subsequent turns we send only what's new (group
  chats batch since the watermark; DMs send the trigger alone).

  Image generation still uses Replicate; unchanged from the pre-Bream
  implementation.
  """

  require Logger

  alias Sue.AI.Sessions
  alias Sue.Models.{Account, Attachment, Chat}

  @timeout 40_000
  @fallback_error_message "Sorry, I timed out. Please try later, and consider asking me to keep it short."

  # Gap larger than this between the watermark and the oldest still-cached
  # message means we lost messages out of the 10-window — emit a marker.
  @gap_marker_floor_seconds 1

  @system_prompt """
  You are a helpful assistant known as Sue #REPLACEME. You can see recent messages and converse, but cannot execute commands directly. These commands are available to users:

  !1984: Shows an image of big brother (Tokino Sora)
  !8ball: Ask it a question and it shall answer. Usage: !8ball will I die?
  !box: Roll a weapon from the mystery box. Usage: !box
  !choose: Returns a random object from your space-delimited argument. Usage: !choose up down left right
  !cringe: Snap! That's going in my cringe compilation.
  !define: Create an alias that makes Sue say something. Usage: !define <word> <... meaning ...>
  !doog: Show an image of a cute dog
  !emoji: Use generative AI to make your own emoji
  !flip: Flip a coin
  !fortune: The fortune command familiar to unix users
  !gpt: Talk to you
  !motivate: Make a motivational image
  !name: Change the name you call them by
  !phrases: Show definitions made by the user
  !ping: Make sure Sue is alive and well.
  !poll: Create a poll for people to !vote on. Usage: !poll which movie? grand budapest tron bee movie
  !qt: Sends a cute photo drawn by mhug.
  !random: Generates a random number between two positive integers, a random letter between two specified letters, or a random floating-point number between 0 and 1. Usage: !random 1 10 / !random a z / !random
  !rub: Checks if it is yet Rubbing Day. Usage: !rub
  !sd: Generate an image using stable diffusion. Usage: !sd a cactus shaped snowflake
  !uptime: Show how long Sue's server has been running. Usage: !uptime
  !vote: Vote on an ongoing poll. Usage: !vote a

  Avoid starting messages with greetings like "Hi [name]". Use names for personalization only when necessary, and if a user has only a numerical ID, opt for a neutral address. Respond in a friendly, conversational manner.

  Each user message you receive is a transcript of recent chat lines, formatted as `[hh:mm] Speaker: text`. A leading `... (Xd Yhr Zmin later) ...` line denotes a gap where chat continued without you being shown every message. Reply once, addressing the most recent line.
  """

  @doc """
  Build the per-chat system prompt used when starting a Bream session.
  Public so `Sue.AI.Sessions` can call it.
  """
  @spec system_prompt(Chat.t()) :: String.t()
  def system_prompt(%Chat{is_direct: true}),
    do: String.replace(@system_prompt, "#REPLACEME", "in a chat with a user")

  def system_prompt(%Chat{}),
    do: String.replace(@system_prompt, "#REPLACEME", "in a groupchat with 2+ users")

  @doc """
  Chat completion for the per-chat session. `text` is the new user input
  (e.g. the args of `!gpt`, or the body of an interjection-triggering
  message). Returns the assistant's reply as a string.
  """
  @spec chat_completion(bitstring(), Chat.t(), Account.t()) :: bitstring()
  @spec chat_completion(bitstring(), Chat.t(), Account.t(), [Attachment.t()]) :: bitstring()
  def chat_completion(text, %Chat{} = chat, %Account{} = account, attachments \\ []) do
    case Sessions.prepare_turn(chat) do
      {:ok, kind, session_id, watermark} ->
        recent = Sue.DB.RecentMessages.get(chat.id)
        {turn_body, latest_ts} = build_turn(kind, watermark, chat, account, text, recent)

        reply = stream_to_session(session_id, turn_body, attachments)
        Sessions.record_turn(chat.id, latest_ts)
        reply

      {:error, _reason} ->
        @fallback_error_message
    end
  end

  @doc """
  One-shot text completion with no chat context. Used by prompt-type
  definitions (`!define prompt`).
  """
  @spec raw_chat_completion_text(bitstring()) :: bitstring()
  def raw_chat_completion_text(text) when is_binary(text) do
    one_shot("You are a helpful assistant.", text)
  end

  ## Turn assembly

  # Returns {user_turn_body, latest_msg_ts}.
  # latest_msg_ts is the timestamp of the most recent message included in
  # the turn — used as the new watermark. nil if we couldn't determine it
  # (e.g. nothing in the cache).
  defp build_turn(:fresh, _watermark, _chat, account, text, recent) do
    # Seed with the current cache (which already includes the trigger
    # message if the caller cached it before invoking us). Drop the last
    # entry — the trigger — and present it separately as the new line so
    # Claude sees the request, not just a transcript.
    {history, current_msg} = pop_trigger(recent)

    history_block =
      case history do
        [] -> ""
        lines -> "Recent chat:\n" <> format_lines(lines) <> "\n\n"
      end

    current_line = format_current_line(current_msg, account, text)
    body = history_block <> current_line
    {body, current_ts(current_msg)}
  end

  defp build_turn(:continuing, _watermark, %Chat{is_direct: true}, account, text, recent) do
    # DMs: don't bother batching the in-betweens — just send the trigger.
    current_msg = List.last(recent)
    {format_current_line(current_msg, account, text), current_ts(current_msg)}
  end

  defp build_turn(:continuing, watermark, %Chat{}, account, text, recent) do
    # Group chats: send all messages newer than the watermark, with a gap
    # marker if any messages aged out of the cache between the watermark
    # and the oldest message we still have.
    {unsent, current_msg} = unsent_since(recent, watermark)

    {marker, batch_lines} =
      case {watermark, unsent} do
        {nil, lines} ->
          {nil, lines}

        {_wm, []} ->
          # Edge case: we have nothing newer to send (shouldn't normally
          # happen in this branch). Send just the trigger as a fallback.
          {nil, []}

        {wm, [oldest | _] = lines} ->
          gap = DateTime.diff(message_time(oldest), wm, :second)

          if gap > @gap_marker_floor_seconds and oldest != List.first(recent) do
            # Some messages slipped out of the window between watermark and oldest cached.
            {format_marker(gap), lines}
          else
            {nil, lines}
          end
      end

    body =
      [
        marker,
        format_lines_or_empty(batch_lines),
        format_current_line(current_msg, account, text)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    {body, current_ts(current_msg)}
  end

  ## Formatting helpers

  defp pop_trigger([]), do: {[], nil}
  defp pop_trigger(list), do: {Enum.drop(list, -1), List.last(list)}

  # All cached entries with timestamp strictly newer than the watermark,
  # excluding the trigger (the last cached entry) which is rendered
  # separately as the current line.
  defp unsent_since(recent, nil) do
    {Enum.drop(recent, -1), List.last(recent)}
  end

  defp unsent_since(recent, %DateTime{} = wm) do
    history = Enum.drop(recent, -1)
    {Enum.filter(history, &(DateTime.compare(message_time(&1), wm) == :gt)), List.last(recent)}
  end

  defp format_lines_or_empty([]), do: ""
  defp format_lines_or_empty(lines), do: format_lines(lines)

  defp format_lines(lines), do: Enum.map_join(lines, "\n", &format_line/1)

  defp format_line(%{} = msg) do
    "[#{format_time(message_time(msg))}] #{speaker_name(msg)}: #{msg.body}"
  end

  defp format_current_line(nil, account, text) do
    "[#{format_time(DateTime.utc_now())}] #{Account.friendly_name(account)}: #{text}"
  end

  defp format_current_line(%{} = msg, account, text) do
    name =
      cond do
        msg[:is_from_sue] or msg[:is_from_gpt] -> "Sue"
        is_binary(msg[:name]) and msg[:name] != "" -> msg.name
        true -> Account.friendly_name(account)
      end

    "[#{format_time(message_time(msg))}] #{name}: #{text}"
  end

  defp speaker_name(%{is_from_gpt: true}), do: "Sue"
  defp speaker_name(%{is_from_sue: true}), do: "Sue"
  defp speaker_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp speaker_name(_), do: "Unknown"

  defp message_time(%{time: %DateTime{} = t}), do: t
  defp message_time(_), do: DateTime.utc_now()

  defp current_ts(nil), do: DateTime.utc_now()
  defp current_ts(%{} = msg), do: message_time(msg)

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 5)
  end

  # "1d 5hr 3min later" / "47min later" / "2hr later"
  defp format_marker(seconds) when is_integer(seconds) and seconds > 0 do
    days = div(seconds, 86_400)
    hrs = div(rem(seconds, 86_400), 3_600)
    mins = div(rem(seconds, 3_600), 60)

    parts =
      [{days, "d"}, {hrs, "hr"}, {mins, "min"}]
      |> Enum.reject(fn {n, _} -> n == 0 end)
      |> Enum.map(fn {n, suffix} -> "#{n}#{suffix}" end)

    label = if parts == [], do: "moments", else: Enum.join(parts, " ")
    "... (#{label} later) ..."
  end

  defp format_marker(_), do: nil

  ## Bream glue

  defp stream_to_session(session_id, prompt, attachments) do
    Bream.stream(session_id, content_for_prompt(prompt, attachments), @timeout)
    |> Enum.join()
  rescue
    e ->
      Logger.error("[Sue.AI] bream stream failed: #{Exception.message(e)}")
      @fallback_error_message
  end

  defp one_shot(system_prompt, prompt) do
    case Bream.start_session(
           system_prompt: system_prompt,
           model: "claude-sonnet-4-6",
           timeout: @timeout
         ) do
      {:ok, session} ->
        try do
          session
          |> Bream.stream(prompt, @timeout)
          |> Enum.join()
        rescue
          e ->
            Logger.error("[Sue.AI] bream stream failed: #{Exception.message(e)}")
            @fallback_error_message
        after
          Bream.close(session)
        end

      {:error, reason} ->
        Logger.error("[Sue.AI] bream start_session failed: #{inspect(reason)}")
        @fallback_error_message
    end
  end

  defp content_for_prompt(prompt, attachments) do
    case image_blocks(attachments) do
      [] -> prompt
      blocks -> [%{type: "text", text: prompt} | blocks]
    end
  end

  defp image_blocks(attachments) when is_list(attachments) do
    Enum.flat_map(attachments, &image_block/1)
  end

  defp image_blocks(_), do: []

  defp image_block(%Attachment{} = attachment) do
    with true <- Attachment.image?(attachment),
         {:ok, %Attachment{} = attachment} <- Attachment.download(attachment),
         true <- Attachment.valid?(attachment),
         {:ok, bytes} <- File.read(attachment.filepath) do
      [
        %{
          type: "image",
          source: %{
            type: "base64",
            media_type: attachment.mime_type || "image/jpeg",
            data: Base.encode64(bytes)
          }
        }
      ]
    else
      _ -> []
    end
  end

  defp image_block(_), do: []

  ## Image generation (Replicate, unchanged)

  @doc """
  Huge thanks to https://github.com/cbh123/emoji for this.
  """
  @spec gen_image_emoji(bitstring()) :: {:ok | :error, bitstring()}
  def gen_image_emoji(prompt) do
    model = Replicate.Models.get!("fofr/sdxl-emoji")

    version =
      Replicate.Models.get_version!(
        model,
        "4d2c2e5e40a5cad182e5729b49a08247c22a5954ae20356592caaada42dc8985"
      )

    {:ok, prediction} =
      Replicate.Predictions.create(version, %{
        prompt: "A TOK emoji of " <> prompt,
        width: 768,
        height: 768,
        num_inference_steps: 30
      })

    Replicate.Predictions.wait(prediction)
    |> process_image_output()
  end

  @spec gen_image_sd(bitstring()) :: {:ok | :error, bitstring()}
  def gen_image_sd(prompt) do
    model = Replicate.Models.get!("lucataco/proteus-v0.2")

    version =
      Replicate.Models.get_version!(
        model,
        "06775cd262843edbde5abab958abdbb65a0a6b58ca301c9fd78fa55c775fc019"
      )

    {:ok, prediction} =
      Replicate.Predictions.create(version, %{
        prompt: prompt,
        negative_prompt: "worst quality, low quality",
        scheduler: "KarrasDPM",
        width: 768,
        height: 768,
        num_inference_steps: 20,
        apply_watermark: false
      })

    Replicate.Predictions.wait(prediction)
    |> process_image_output()
  end

  defp process_image_output({:ok, %Replicate.Predictions.Prediction{error: nil, output: [url]}}) do
    {:ok, url}
  end

  defp process_image_output({:ok, %Replicate.Predictions.Prediction{error: error_msg}}) do
    {:error, error_msg}
  end
end
