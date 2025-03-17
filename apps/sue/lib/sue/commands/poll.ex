defmodule Sue.Commands.Poll do
  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"

  alias Sue.Models.{Message, Response, Poll}
  alias Sue.DB

  @doc """
  Create a poll for people to !vote on.
  Usage: !poll which movie?
  grand budapest
  tron
  bee movie
  """
  def c_poll(%Message{args: ""}) do
    %Response{body: "Please specify a poll topic with options."}
  end

  def c_poll(msg) do
    poll_args = Sue.Utils.tokenize(msg.args)
    create_poll(msg, poll_args)
  end

  @doc """
  Vote on an ongoing poll
  Usage: !vote a
  """
  def c_vote(msg) do
    # Before voting on a poll, first confirm one exists for the current chat.

    case DB.find_poll(msg.chat) do
      {:ok, %Poll{interface: :platform}} ->
        %Response{body: "Please use this messenger's custom polling interface."}

      {:ok, %Poll{}} ->
        vote(msg)

      {:ok, :dne} ->
        %Response{body: "A poll does not exist for this chat."}
    end
  end

  def vote(msg) do
    args = String.downcase(msg.args)

    if String.match?(args, ~r/^[a-z]$/) do
      case DB.add_poll_vote(msg.chat, msg.account, alpha_to_idx(args)) do
        {:ok, newpoll} -> poll_to_response(newpoll, msg)
      end
    else
      %Response{body: "Not an option in this poll. See: !help vote"}
    end
  end

  defp create_poll(_msg, [_]) do
    %Response{body: "Please specify options for the poll. See !help poll"}
  end

  defp create_poll(msg, [topic | choices])
       when is_list(choices) and length(choices) <= 26 do
    cond do
      # Telegram's custom polling interface requires 10 options or less.
      msg.platform == :telegram and length(choices) <= 10 ->
        {:ok, p} =
          Poll.new(msg.chat, topic, choices, :platform)
          |> DB.add_poll(msg.chat.id)

        poll_to_response(p, msg)

      true ->
        {:ok, p} =
          Poll.new(msg.chat, topic, choices, :standard)
          |> DB.add_poll(msg.chat.id)

        poll_to_response(p, msg)
    end
  end

  defp create_poll(_msg, _) do
    %Response{body: "Please limit to 26 options or less."}
  end

  defp poll_to_response(poll, %Message{platform: :telegram, chat: chat}) do
    if length(poll.options) > 10 do
      # Resort to typical poll interface
      %Response{body: poll_text(poll)}
    else
      # Use Telegram's custom interface.
      Telegex.send_poll(chat.id, poll.topic, poll.options, is_anonymous: false)
      %Response{}
    end
  end

  @spec poll_to_response(Poll.t(), Message.t()) :: Response.t()
  defp poll_to_response(poll, _msg), do: %Response{body: poll_text(poll)}

  defp poll_text(%Poll{votes: votes} = poll) when map_size(votes) == 0 do
    ([poll.topic] ++
       (Enum.with_index(poll.options)
        |> Enum.map(fn {option, idx} ->
          "#{idx_to_alpha(idx)}. #{option}"
        end)))
    |> Enum.join("\n")
  end

  defp poll_text(poll) do
    votes_vk =
      poll.votes
      |> Map.to_list()
      |> Enum.group_by(fn {_k, v} -> v end, fn {k, _v} -> k end)

    ([poll.topic] ++
       (Enum.with_index(poll.options)
        |> Enum.map(fn {option, idx} ->
          choice_votes = Map.get(votes_vk, idx, []) |> length()
          "(#{choice_votes}) #{idx_to_alpha(idx)}. #{option}"
        end)))
    |> Enum.join("\n")
  end

  defp idx_to_alpha(idx) when is_integer(idx) and idx >= 0 and idx <= 26 do
    <<97 + idx>>
  end

  defp alpha_to_idx(alpha) when is_bitstring(alpha) do
    <<idx>> = alpha
    idx - 97
  end
end
