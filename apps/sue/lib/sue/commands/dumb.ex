defmodule Sue.Commands.Dumb do
  @moduledoc """
  I suppose I'll just put dumb lil things in here.
  """

  alias Sue.Models.Response

  @doc """
  Checks if it is yet Rubbing Day.
  Caveat: By invoking this command, you believe Elixir is the best programming language.
  Usage: !rub
  """
  def c_rub(_msg) do
    now = Timex.local()
    weekday = Timex.weekday(now)
    dtr = Integer.mod(3 - weekday, 7)
    ms = calc_microseconds(dtr, now)

    relative =
      Timex.Duration.from_microseconds(ms)
      |> Timex.Format.Duration.Formatter.format(:humanized)

    %Response{body: rub_response(ms, relative)}
  end

  def calc_microseconds(0, _now), do: 0

  def calc_microseconds(dtr, now) when dtr <= 6 do
    now
    |> Timex.to_date()
    |> Timex.add(Timex.Duration.from_days(dtr))
    |> Timex.to_datetime(Timex.Timezone.Local.lookup())
    |> Timex.diff(now, :microseconds)
  end

  def rub_response(0, _) do
    "Today is rubbing day!\n" <>
      ([
         "https://www.youtube.com/watch?v=l2fKbktcyIs",
         "https://www.youtube.com/watch?v=GyhLj-YdJW4",
         "https://www.youtube.com/watch?v=k4IJROgvWHc",
         "https://www.youtube.com/watch?v=ShXmOdYGuG8",
         "https://www.youtube.com/watch?v=ET5X4voZsag"
       ]
       |> Enum.random())
  end

  def rub_response(ms, relative) do
    seconds = ms / 1.0e6
    hours = ms / 3.6e9
    days = hours / 24

    ([
       "#{ms} microseconds",
       "#{round(seconds / 1200)} ice hockey periods",
       "#{trunc(960 * hours)} human breaths",
       "#{:erlang.float_to_binary(days / 12, decimals: 2)} Virginian opossum gestation periods",
      "#{:erlang.float_to_binary(hours / 3522.5, decimals: 4)} Martha Stewart incarcerations",
       "#{trunc(seconds / 66.46)} smoker deaths",
       "#{trunc(seconds / 180)} Perilla tea steepings",
       "#{trunc(seconds / 150)} commercial breaks",
       "#{:io_lib.format("~e", [days / 16_425]) |> List.to_string()} Cold Wars"
     ]
     |> Enum.random()) <> " until rubbing day.\n(#{relative})"
  end
end
