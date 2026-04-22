defmodule Sue.AI do
  @moduledoc """
  Claude-backed chat completion for Sue, via Bream.

  Each call spins up an ephemeral Bream session, sends one user turn, streams
  the assistant's text back, and closes the session. Conversation context
  lives in Sue's `RecentMessages` cache and is flattened into the prompt —
  Bream sessions themselves are short-lived and don't carry history across
  calls.

  Image generation still uses Replicate; unchanged from the pre-Bream
  implementation.
  """

  require Logger

  alias Sue.Models.{Account, Chat}

  @model "claude-sonnet-4-6"
  @timeout 40_000
  @fallback_error_message "Sorry, I timed out. Please try later, and consider asking me to keep it short."

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
  """

  @doc """
  Chat completion with recent-chat context. Returns the assistant's reply
  as a string.
  """
  @spec chat_completion(bitstring(), Chat.t(), Account.t()) :: bitstring()
  def chat_completion(text, %Chat{} = chat, %Account{} = account) do
    maxlen = if account.is_premium, do: 4_000, else: 1_000

    situation =
      if chat.is_direct, do: "in a chat with a user", else: "in a groupchat with 2+ users"

    system = String.replace(@system_prompt, "#REPLACEME", situation)

    prompt = build_prompt_with_context(text, chat, account, maxlen)
    ask_claude(system, prompt)
  end

  @doc """
  One-shot text completion with no chat context. Used by prompt-type
  definitions (`!define prompt`).
  """
  @spec raw_chat_completion_text(bitstring()) :: bitstring()
  def raw_chat_completion_text(text) when is_binary(text) do
    ask_claude("You are a helpful assistant.", text)
  end

  # --- Bream glue ---

  defp ask_claude(system_prompt, prompt) do
    case Bream.start_session(
           system_prompt: system_prompt,
           model: @model,
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

  # --- Prompt building ---

  defp build_prompt_with_context(text, chat, account, maxlen) do
    history =
      chat.id
      |> Sue.DB.RecentMessages.get_tail()
      |> cap_by_length(String.length(text), maxlen)
      |> Enum.map_join("\n", &format_history_line/1)

    current_line = "#{Account.friendly_name(account)}: #{text}"

    if history == "",
      do: current_line,
      else: "Recent chat:\n#{history}\n\n#{current_line}"
  end

  defp format_history_line(%{is_from_gpt: true, body: body}), do: "Sue: #{body}"
  defp format_history_line(%{is_from_sue: true, body: body}), do: "Sue: #{body}"
  defp format_history_line(%{name: name, body: body}), do: "#{name}: #{body}"

  defp cap_by_length(messages, base_length, maxlen) do
    {_len, kept} =
      Enum.reduce_while(messages, {base_length, []}, fn m, {len, acc} ->
        new_len = len + String.length(m.body)

        if new_len <= maxlen,
          do: {:cont, {new_len, acc ++ [m]}},
          else: {:halt, {len, acc}}
      end)

    kept
  end

  # --- Image generation (Replicate, unchanged) ---

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
