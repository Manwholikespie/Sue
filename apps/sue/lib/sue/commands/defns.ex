defmodule Sue.Commands.Defns do
  @moduledoc """
  User-defined commands, currently restricted to echoing whatever value is
    stored for their command key.
  """

  # TODO: re-implement #variable injection
  # TODO: User-defined lambdas

  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"

  alias Sue.Models.{Defn, Message, Response}
  alias Sue.DB

  @gpt_rate_limit Application.compile_env(:sue, :gpt_rate_limit)

  def calldefn(msg) do
    varname = msg.command

    with {:ok, defn} <- DB.find_defn(msg.account.id, msg.chat.is_direct, varname) do
      calldefn_type(msg, defn)
    else
      {:error, :dne} ->
        %Response{body: "Command not found. Add it with !define."}
    end
  end

  def calldefn_type(_msg, %Defn{type: :text, val: val}), do: %Response{body: val}

  def calldefn_type(%Message{args: ""}, %Defn{type: :prompt}),
    do: %Response{
      body: "This definition is a prompt, and must be called with args. See !help define"
    }

  def calldefn_type(msg, %Defn{type: :prompt, val: val}) do
    prompt = String.replace(val, "$args", msg.args)

    with :ok <-
           Sue.Limits.check_rate("gpt:#{msg.account.id}", @gpt_rate_limit, msg.account.is_premium) do
      %Response{body: Sue.AI.raw_chat_completion_text(prompt)}
    else
      :deny -> %Response{body: "Please slow down your requests. Try again in 24 hours."}
    end
  end

  @spec c_define(Message.t()) :: Response.t()
  @doc """
  Create a quick alias that makes Sue say something or do something.
  Usage: !define [type] <word> <... value ...>

  Supported types:
    - text (default): Creates a simple text response
    - prompt: Creates a template for asking ChatGPT

  Examples:
  ---
  You: !define myword this is my definition
  Sue: myword updated.
  You: !myword
  Sue: this is my definition

  You: !define prompt poem Write a poem about $args.
  Sue: poem updated.
  You: !poem bruh
  Sue: Bruh moment-- silence louder than words.
  """
  def c_define(%Message{args: ""}),
    do: %Response{body: "Please supply a word and meaning. See !help define"}

  def c_define(msg) do
    # Split args into up to 3 parts: [type, var, val] or [var, val]
    parts = msg.args |> String.split(" ", parts: 3)

    {type, var, val} =
      case parts do
        # If we have 3 parts, check if the first one is a valid type
        ["text", var, val] ->
          {:text, var, val}

        ["prompt", var, val] ->
          {:prompt, var, val}

        # If the first part is not a valid type, or we only have 2 parts,
        # assume default type (:text)
        [var, val] ->
          {:text, var, val}

        [first, second, third] ->
          {:text, first, second <> " " <> third}

        [_] ->
          {nil, nil, nil}
      end

    cond do
      is_nil(type) ->
        %Response{body: "Please supply a word and meaning. See !help define"}

      String.contains?(var, "@") ->
        %Response{body: "Please don't put @ symbols in definitions."}

      type == :prompt and not String.contains?(val, "$args") ->
        %Response{
          body: "Prompts must have $args where they want args to be injected. See !help define"
        }

      true ->
        var = var |> String.downcase()

        {:ok, _} =
          Defn.new(var, val, type)
          |> DB.add_defn(msg.account.id, msg.chat.id)

        %Response{body: "#{var} updated."}
    end
  end

  @doc """
  Output the variables !define'd by the calling user or in the current chat.
  Usage: !phrases
  """
  def c_phrases(msg) do
    defn_user = DB.get_defns_by_user(msg.account.id)

    defn_user_ids =
      defn_user
      |> Enum.map(fn d -> d.id end)
      |> MapSet.new()

    defn_user_by_type = group_defns_by_type(defn_user)

    defn_chat =
      DB.get_defns_by_chat(msg.chat.id)
      |> Enum.filter(fn d -> not MapSet.member?(defn_user_ids, d.id) end)

    defn_chat_by_type = group_defns_by_type(defn_chat)

    defn_user_list = format_defns_by_type(defn_user_by_type, "user")
    defn_chat_list = format_defns_by_type(defn_chat_by_type, "chat")

    %Response{
      body:
        case (defn_user_list <> "\n\n" <> defn_chat_list) |> String.trim() do
          "" -> "You have not defined anything. See !help define"
          otherwise -> otherwise
        end
    }
  end

  # Helper to group definitions by type
  # Called via apply/3 in Sue.execute_command, so Dialyzer can't detect usage
  @dialyzer {:nowarn_function, group_defns_by_type: 1}
  @spec group_defns_by_type([Defn.t()]) :: %{atom() => [Defn.t()]}
  defp group_defns_by_type(defns) do
    defns
    |> Enum.group_by(fn d -> d.type end)
    |> Enum.map(fn {type, defs} ->
      {type, Enum.uniq_by(defs, fn d -> d.var end)}
    end)
    |> Enum.into(%{})
  end

  # Helper to format definitions grouped by type
  # Called via apply/3 in Sue.execute_command, so Dialyzer can't detect usage
  @dialyzer {:nowarn_function, format_defns_by_type: 2}
  @spec format_defns_by_type(%{atom() => [Defn.t()]}, String.t()) :: String.t()
  defp format_defns_by_type(defns_by_type, source) do
    if Enum.empty?(defns_by_type) do
      ""
    else
      result = "defns by #{source}:\n"

      # First, show text type definitions (the most common)
      text_defns = Map.get(defns_by_type, :text, [])

      text_section =
        if Enum.empty?(text_defns) do
          ""
        else
          text_defns
          |> Enum.map(fn d -> "- #{d.var}" end)
          |> Enum.join("\n")
        end

      # Then show other types with their type annotation
      other_sections =
        defns_by_type
        |> Enum.filter(fn {type, _} -> type != :text end)
        |> Enum.map(fn {type, defs} ->
          defs
          |> Enum.map(fn d -> "- #{d.var} (#{type})" end)
          |> Enum.join("\n")
        end)
        |> Enum.join("\n")

      result <>
        text_section <>
        if(text_section != "" and other_sections != "", do: "\n", else: "") <> other_sections
    end
  end
end
