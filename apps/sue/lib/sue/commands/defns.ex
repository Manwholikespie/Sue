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

  def calldefn(msg) do
    # meaning = get_defn!(msg) || "Command not found. Add it with !define."
    varname = msg.command

    case DB.find_defn(msg.account.id, msg.chat.is_direct, varname) do
      {:ok, %Defn{val: val}} -> %Response{body: val}
      {:error, :dne} -> %Response{body: "Command not found. Add it with !define."}
    end
  end

  @spec c_define(atom | %{:args => binary, optional(any) => any}) :: Sue.Models.Response.t()
  @doc """
  Create a quick alias that makes Sue say something.
  Usage: !define <word> <... meaning ...>
  ---
  You: !define myword this is my definition
  Sue: myword updated.
  You: !myword
  Sue: this is my definition
  """
  def c_define(%Message{args: ""}),
    do: %Response{body: "Please supply a word and meaning. See !help define"}

  def c_define(msg) do
    case msg.args |> String.split(" ", parts: 2) do
      [_word] ->
        %Response{body: "Please supply a meaning for the word. See !help define"}

      [word, val] ->
        var = word |> String.downcase()

        if String.contains?(var, "@") do
          %Response{body: "Please don't put @ symbols in definitions."}
        else
          {:ok, _} =
            Defn.new(var, val, :text)
            |> DB.add_defn(msg.account.id, msg.chat.id)

          %Response{body: "#{var} updated."}
        end
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

    defn_user_list =
      case defn_user
           |> Enum.uniq_by(fn d -> d.var end)
           |> Enum.map(fn d -> "- #{d.var}" end)
           |> Enum.join("\n") do
        "" -> ""
        otherwise -> "defns by user:\n" <> otherwise
      end

    defn_chat_list =
      case DB.get_defns_by_chat(msg.chat.id)
           |> Enum.filter(fn d -> not MapSet.member?(defn_user_ids, d.id) end)
           |> Enum.uniq_by(fn d -> d.var end)
           |> Enum.map(fn d -> "- #{d.var}" end)
           |> Enum.join("\n") do
        "" -> ""
        otherwise -> "defns by chat:\n" <> otherwise
      end

    %Response{
      body:
        case (defn_user_list <> "\n\n" <> defn_chat_list) |> String.trim() do
          "" -> "You have not defined anything. See !help define"
          otherwise -> otherwise
        end
    }
  end
end
