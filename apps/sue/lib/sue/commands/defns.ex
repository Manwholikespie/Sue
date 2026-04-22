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

    case DB.find_defn(msg.account.id, msg.chat.is_direct, varname) do
      {:ok, defn} ->
        calldefn_type(msg, defn)

      {:error, :dne} ->
        %Response{body: "Command not found. Add it with !define."}
    end
  end

  def calldefn_type(_msg, %Defn{kind: :text, val: val}), do: %Response{body: val}

  def calldefn_type(%Message{args: ""}, %Defn{kind: :prompt}),
    do: %Response{
      body: "This definition is a prompt, and must be called with args. See !help define"
    }

  def calldefn_type(msg, %Defn{kind: :prompt, val: val}) do
    prompt = String.replace(val, "$args", msg.args)

    case Sue.Limits.check_rate("gpt:#{msg.account.id}", @gpt_rate_limit, msg.account.is_premium) do
      :ok -> %Response{body: Sue.AI.raw_chat_completion_text(prompt)}
      :deny -> %Response{body: "Please slow down your requests. Try again in 24 hours."}
    end
  end

  @spec c_define(Message.t()) :: Response.t()
  @doc """
  Create a quick alias that makes Sue say something or do something.
  Usage: !define [type] <word> <... value ...>

  Supported types:
    - text (default): Creates a simple text response
    - prompt: Creates a template for asking Sue

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
    with {:ok, type, var, val} <- parse_define_args(msg.args),
         :ok <- validate_define_content(type, var, val) do
      normalized = String.downcase(var)

      {:ok, _} =
        Defn.new(normalized, val, type)
        |> DB.add_defn(msg.account.id, msg.chat.id)

      %Response{body: "#{normalized} updated."}
    else
      {:error, body} -> %Response{body: body}
    end
  end

  # Split args into [type, var, val] or infer :text as the default type.
  @spec parse_define_args(String.t()) ::
          {:ok, :text | :prompt, String.t(), String.t()} | {:error, String.t()}
  defp parse_define_args(args) do
    case String.split(args, " ", parts: 3) do
      ["text", var, val] -> {:ok, :text, var, val}
      ["prompt", var, val] -> {:ok, :prompt, var, val}
      [var, val] -> {:ok, :text, var, val}
      [first, second, third] -> {:ok, :text, first, second <> " " <> third}
      [_] -> {:error, "Please supply a word and meaning. See !help define"}
    end
  end

  @spec validate_define_content(:text | :prompt, String.t(), String.t()) ::
          :ok | {:error, String.t()}
  defp validate_define_content(type, var, val) do
    cond do
      String.contains?(var, "@") ->
        {:error, "Please don't put @ symbols in definitions."}

      type == :prompt and not String.contains?(val, "$args") ->
        {:error, "Prompts must have $args where they want args to be injected. See !help define"}

      true ->
        :ok
    end
  end

  @doc """
  Output the variables !define'd by the calling user or in the current chat.
  Usage: !phrases
  """
  def c_phrases(msg) do
    defn_user = DB.get_defns_by_user(msg.account.id)
    defn_user_ids = Enum.map(defn_user, & &1.id)

    defn_user_by_type = group_defns_by_type(defn_user)

    defn_chat =
      DB.get_defns_by_chat(msg.chat.id)
      |> Enum.reject(&(&1.id in defn_user_ids))

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
    |> Enum.group_by(fn d -> d.kind end)
    |> Enum.map(fn {kind, defs} ->
      {kind, Enum.uniq_by(defs, fn d -> d.var end)}
    end)
    |> Enum.into(%{})
  end

  # Helper to format definitions grouped by type
  # Called via apply/3 in Sue.execute_command, so Dialyzer can't detect usage
  @dialyzer {:nowarn_function,
             format_defns_by_type: 2, format_text_section: 1, format_other_sections: 1}
  @spec format_defns_by_type(%{atom() => [Defn.t()]}, String.t()) :: String.t()
  defp format_defns_by_type(defns_by_type, _source) when map_size(defns_by_type) == 0, do: ""

  defp format_defns_by_type(defns_by_type, source) do
    text_section = format_text_section(Map.get(defns_by_type, :text, []))
    other_sections = format_other_sections(defns_by_type)
    separator = if text_section != "" and other_sections != "", do: "\n", else: ""

    "defns by #{source}:\n" <> text_section <> separator <> other_sections
  end

  @spec format_text_section([Defn.t()]) :: String.t()
  defp format_text_section([]), do: ""

  defp format_text_section(text_defns) do
    Enum.map_join(text_defns, "\n", fn d -> "- #{d.var}" end)
  end

  @spec format_other_sections(%{atom() => [Defn.t()]}) :: String.t()
  defp format_other_sections(defns_by_type) do
    defns_by_type
    |> Enum.filter(fn {type, _} -> type != :text end)
    |> Enum.map_join("\n", fn {type, defs} ->
      Enum.map_join(defs, "\n", fn d -> "- #{d.var} (#{type})" end)
    end)
  end
end
