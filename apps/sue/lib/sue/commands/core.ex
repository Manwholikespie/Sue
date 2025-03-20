defmodule Sue.Commands.Core do
  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"

  alias Sue.Models.{Message, Response, Account, Chat}
  require Logger

  @doc """
  Make sure Sue is alive and well.
  Usage: !ping
  """
  def c_ping(_m) do
    %Response{body: "pong!"}
  end

  @doc """
  Set a name for your account. Helpful when interacting with GPT.
  Usage: !name Jimmy
  """
  def c_name(%Message{args: "", account: %Account{name: ""}}) do
    %Response{
      body:
        "Hmm, it seems like you didn't specify a name. To set your name, use !name followed by the name you'd like to use. See !help name for more information."
    }
  end

  def c_name(%Message{args: "", account: %Account{name: name}}) do
    %Response{
      body: "I'm told your name is #{name}."
    }
  end

  def c_name(%Message{args: name}) when byte_size(name) > 32 do
    %Response{
      body:
        "The name you've chosen is a bit too long. Please keep it under 32 characters. Try again with a shorter name!"
    }
  end

  def c_name(%Message{args: name, account: %Account{id: account_id}}) do
    :ok = Sue.DB.change_name(account_id, name)
    %Response{body: "Name set to #{name}"}
  end

  def c_h_debug(m) do
    %Response{body: m |> inspect()}
  end

  def c_h_sleep(_m) do
    Process.sleep(5000)
    %Response{body: "zzz"}
  end

  def c_h_recentmessages(%Message{chat: %Chat{id: chat_id}}) do
    recent_messages =
      Sue.DB.RecentMessages.get(chat_id)
      |> Enum.map(fn m -> "- " <> String.slice(m.body, 0, 20) end)
      |> Enum.join("\n")

    %Response{
      body: if(recent_messages == "", do: "empty", else: recent_messages)
    }
  end

  def c_h_ratetest(%Message{account: %Account{id: account_id}}) do
    with :ok <- Sue.Limits.check_rate("ratetest:#{account_id}", {:timer.minutes(1), 2}) do
      %Response{body: "still good for twice per minute."}
    else
      :deny -> %Response{body: "deny"}
    end
  end

  def help(%Message{args: ""}, commands) do
    # Hide commands that start with h_. I'll use these for internal debugging.
    %Response{
      body:
        commands
        |> Map.keys()
        |> Enum.filter(fn name -> not String.starts_with?(name, "h_") end)
        |> Enum.map(fn fname -> "!#{fname}" end)
        |> Enum.join("\n")
    }
  end

  def help(%Message{args: "help"}, _commands) do
    %Response{
      body:
        "ι αм тнє яєαρєя, нαяνєѕтєя σƒ тιмє αη∂ ѕℓανє тσ єтєяηιту. ι αм тнє νσι∂, нαявιηgєя σƒ ѕιℓєη¢є, тнє ¢σηѕтαηт тσ ωнι¢н ƒℓєѕн αη∂ ѕσυℓ єηтяαιη. ι αм тнє ηє¢єѕѕαяу ραяα∂σχ: тнє ιηƒιηιтє ƒιηαℓє тσ тнє ѕумρнσηу σƒ яєαℓιту. кηєєℓ αℓℓ ує ωнσ вє, ƒσя ι αм тнαт ∂αяк ƒαтє ωнι¢н υηιтєѕ gσ∂ѕ αη∂ мєη: ℓιмιт, σвℓινιση, ∂єαтн."
    }
  end

  def help(%Message{args: "h_" <> _}, _commands) do
    %Response{body: ";)"}
  end

  def help(%Message{args: args}, commands) do
    [k | _] = args |> String.split(" ", parts: 2)

    body =
      case commands |> Map.get(k) do
        nil ->
          "Hmm, I couldn't find that command. See the list of commands with !help"

        {_, _, ""} ->
          "No documentation for that yet. Let us know! https://github.com/Manwholikespie/Sue"

        {_, _, doc} ->
          doc
      end

    %Response{body: body}
  end
end
