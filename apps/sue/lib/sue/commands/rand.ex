defmodule Sue.Commands.Rand do
  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"
  alias Sue.Models.{Message, Response}

  @doc """
  Flip a coin. Will return heads or tails.
  Usage: !flip
  """
  def c_flip(_msg) do
    %Response{body: ["heads", "tails"] |> Enum.random()}
  end

  @doc """
  Returns a random object in your space-delimited argument.
  Usage: !choose up down left right
  """
  def c_choose(%Message{args: ""}) do
    %Response{body: "Please provide a list of things to select. See !help choose"}
  end

  def c_choose(%Message{args: args}) do
    %Response{
      body:
        args
        |> String.split(" ")
        |> Enum.random()
    }
  end

  @doc """
  Returns a random number between two positive integers.
  Usage: !random 1 10

  Return a random letter between two letters
  Usage: !random a z

  Return a random floating point number between 0 and 1 (0.47655569922929364)
  Usage: !random
  """
  def c_random(%Message{args: args}) do
    res =
      cond do
        args == "" ->
          :rand.uniform() |> to_string()

        String.match?(args, ~r/^[0-9]+ [0-9]+$/u) ->
          args
          |> String.split(" ")
          |> Enum.map(&String.to_integer/1)
          |> Enum.sort()
          |> rand_range()
          |> to_string

        String.match?(args |> String.downcase(), ~r/^[a-z] [a-z]$/) ->
          with <<l, 32, r>> <- args |> String.downcase() do
            [l, r]
            |> Enum.sort()
            |> rand_range()
            |> (fn i -> <<i>> end).()
          end

        true ->
          "I couldn't figure out what you were asking. See !help random"
      end

    %Response{body: res}
  end

  @doc """
  Ask it a question and it shall answer.
  Usage: !8ball will I die?
  """
  def c_8ball(_msg) do
    [
      "As I see it, yes",
      "It is certain",
      "It is decidedly so",
      "Most likely",
      "Outlook good",
      "Signs point to yes",
      "Without a doubt",
      "Yes",
      "Yes - definitely",
      "You may rely on it",
      "Reply hazy, try again",
      "Ask again later",
      "Better not tell you now",
      "Cannot predict now",
      "Concentrate and ask again",
      "Don't count on it",
      "My reply is no",
      "My sources say no",
      "Outlook not so good",
      "Very doubtful"
    ]
    |> Enum.random()
    |> (fn body -> %Response{body: body} end).()
  end

  defp rand_range([l, h]) do
    ((:rand.uniform() * (h - l)) |> trunc()) + l
  end
end
