defmodule Sue.Commands.Gpt do
  alias Sue.Models.{Message, Response, Attachment, Account}

  @gpt_rate_limit Application.compile_env(:sue, :gpt_rate_limit)
  @sd_rate_limit Application.compile_env(:sue, :sd_rate_limit)

  @doc """
  Asks ChatGPT a question.
  Usage: !gpt write a poem about a bot named sue
  """
  def c_gpt(%Message{args: ""}) do
    %Response{body: "Please provide a request to ChatGPT. See !help gpt"}
  end

  def c_gpt(%Message{args: args, account: %Account{id: account_id, is_premium: is_premium}}) do
    # Check rate limit for using gpt command: 50/day
    with :ok <- Sue.Limits.check_rate("gpt:#{account_id}", @gpt_rate_limit, is_premium) do
      %Response{body: Sue.AI.chat_completion(args, :gpt35)}
    else
      :deny -> %Response{body: "Please slow down your requests. Try again in 24 hours."}
    end
  end

  @doc """
  Asks ChatGPT a question, using the newer GPT-4 model. Only available to premium users for now.
  Usage !gpt4 write a poem about a bot named sue
  """
  def c_gpt4(%Message{account: %Account{is_premium: false}}) do
    %Response{
      body:
        "Sorry, this command is only available for premium Sue users. Check back later for more info, or use !gpt instead."
    }
  end

  def c_gpt4(%Message{account: %Account{is_premium: true}, args: args}) do
    %Response{body: Sue.AI.chat_completion(args, :gpt4)}
  end

  @doc """
  Prompt an emoji-finetuned stable diffusion model.
  Usage: !emoji Ryan Gosling
  """
  def c_emoji(%Message{args: ""}) do
    %Response{body: "What is your emoji? Ex: !emoji a grilled cheese"}
  end

  def c_emoji(%Message{args: prompt, account: %Account{id: account_id, is_premium: is_premium}}) do
    with :ok <- Sue.Limits.check_rate("replicate-8s:#{account_id}", @sd_rate_limit, is_premium) do
      with {:ok, url} <- Sue.AI.gen_image_emoji(prompt) do
        %Response{attachments: [Attachment.from_url(url)]}
      else
        {:error, error_msg} -> %Response{body: error_msg}
      end
    else
      :deny -> %Response{body: "Please slow down your requests. Try again in 24 hours."}
    end
  end

  @doc """
  Generate an image using stable diffusion.
  Usage: !sd a cactus shaped snowflake
  """
  def c_sd(%Message{args: ""}) do
    %Response{body: "Please provide a prompt for Stable Diffusion. See !help sd"}
  end

  def c_sd(%Message{args: prompt, account: %Account{id: account_id, is_premium: is_premium}}) do
    with :ok <- Sue.Limits.check_rate("replicate-8s:#{account_id}", @sd_rate_limit, is_premium) do
      with {:ok, url} <- Sue.AI.gen_image_sd(prompt) do
        %Response{attachments: [Attachment.from_url(url)]}
      else
        {:error, error_msg} -> %Response{body: error_msg}
      end
    else
      :deny -> %Response{body: "Please slow down your requests. Try again in 24 hours."}
    end
  end
end
