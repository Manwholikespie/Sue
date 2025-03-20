defmodule Sue.AI do
  use GenServer

  require Logger

  alias Sue.Models.{Chat, Account}

  @prompt """
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

  @allowed_models [:gpt4o, :gpt4omini]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, []}
  end

  @spec chat_completion(bitstring(), Chat.t(), Account.t(), :gpt4o | :gpt4omini) :: bitstring()
  def chat_completion(text, chat, account, model_version \\ :gpt4omini) do
    maxlen = if account.is_premium, do: 4_000, else: 1_000

    prompt_user_count =
      if chat.is_direct do
        "in a chat with a user"
      else
        "in a groupchat with 2+ users"
      end

    messages =
      [
        %{
          role: "system",
          content: String.replace(@prompt, "#REPLACEME", prompt_user_count)
        }
      ] ++
        recent_messages_for_context(chat.id, chat.is_direct, text, maxlen) ++
        [
          %{
            role: "user",
            content: "#{Account.friendly_name(account)}: #{text}"
          }
        ]

    Logger.debug(messages |> inspect(pretty: true))
    raw_chat_completion_messages(messages, model_version)
  end

  @doc """
  Similar to chat_completion, but doesn't care about prior chat context or our default prompt.
  """
  def raw_chat_completion_messages(messages, model_version \\ :gpt4omini)
      when model_version in @allowed_models do
    model =
      case model_version do
        :gpt4o -> "gpt-4o"
        :gpt4omini -> "gpt-4o-mini"
      end

    Logger.debug("Running chat_completion with #{model}")

    with {:ok, response} <-
           OpenAI.chat_completion(
             model: model,
             messages: messages
           ) do
      [%{"message" => %{"content" => content}}] = response.choices
      Logger.debug("GPT response: " <> content)
      content
    else
      {:error, :timeout} ->
        "Sorry, I timed out. Please try later, maybe additionally asking I keep my response short."

      {:error, %{"status" => status_message}} ->
        Logger.error("[Sue.AI.chat_completion()] #{status_message}")
        status_message

      {:error, %{"message" => status_message}} ->
        Logger.error("[Sue.AI.chat_completion()] #{status_message}")
        status_message
    end
  end

  def raw_chat_completion_text(text, model_version \\ :gpt4omini) do
    messages = [
      %{role: "developer", content: "You are a helpful assistant."},
      %{role: "user", content: text}
    ]

    raw_chat_completion_messages(messages, model_version)
  end

  @spec recent_messages_for_context(Subaru.dbid(), boolean(), bitstring(), integer()) :: [map()]
  defp recent_messages_for_context(chat_id, _is_direct, text, maxlen) do
    Sue.DB.RecentMessages.get_tail(chat_id)
    |> reduce_recent_messages(String.length(text), maxlen)
    |> Enum.map(fn %{is_from_gpt: is_from_gpt, is_from_sue: is_from_sue} = m ->
      role = if is_from_gpt, do: "assistant", else: "user"

      name =
        cond do
          is_from_gpt ->
            "ChatGPT"

          is_from_sue ->
            "SueBot"

          true ->
            format_user_id(m.name)
        end

      content = if is_from_gpt, do: m.body, else: "#{name}: #{m.body}"
      %{role: role, content: content}
    end)
  end

  defp format_user_id("sue_users/" <> user_id) do
    "User" <> user_id
  end

  defp format_user_id(otherwise), do: otherwise

  @spec reduce_recent_messages([map()], integer(), integer()) :: {integer(), [map()]}
  defp reduce_recent_messages(recent_messages, promptlen, maxlen) do
    {_chars_used, messages} =
      Enum.reduce_while(recent_messages, {promptlen, []}, fn m, acc ->
        {len, msgs} = acc
        newlen = len + String.length(m.body)

        if newlen <= maxlen do
          {:cont, {newlen, msgs ++ [m]}}
        else
          {:halt, acc}
        end
      end)

    messages
  end

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
