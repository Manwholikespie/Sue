defmodule Sue.Mailbox.TelegramTest do
  use ExUnit.Case, async: true

  alias Sue.Mailbox.Telegram

  # UTF-16 code unit count — the metric Telegram actually enforces.
  defp utf16_length(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
    |> byte_size()
    |> div(2)
  end

  defp all_within_limit?(chunks), do: Enum.all?(chunks, &(utf16_length(&1) <= 4096))

  describe "split_message/1" do
    test "returns single chunk for short messages" do
      text = "Hello, world!"
      assert Telegram.split_message(text) == [text]
    end

    test "returns single chunk for message exactly at limit" do
      text = String.duplicate("a", 4096)
      assert Telegram.split_message(text) == [text]
    end

    test "splits message just over limit at word boundary" do
      part1 = String.duplicate("a", 4090)
      part2 = String.duplicate("b", 10)
      text = part1 <> " " <> part2

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2
      assert all_within_limit?(chunks)
      # Verify original text can be reconstructed (minus the space)
      assert Enum.join(chunks, " ") == text
    end

    test "splits message at paragraph boundary when possible" do
      para1 = String.duplicate("First paragraph. ", 200)
      para2 = String.duplicate("Second paragraph. ", 200)
      text = para1 <> "\n\n" <> para2

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2
      assert all_within_limit?(chunks)
      assert hd(chunks) == para1
    end

    test "splits very long word with hyphen" do
      text = String.duplicate("A", 5000)

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2
      assert all_within_limit?(chunks)

      # ASCII-only, so utf16_length == char count. First chunk: 4095 + "-".
      first_chunk = hd(chunks)
      assert utf16_length(first_chunk) == 4096
      assert String.ends_with?(first_chunk, "-")

      second_chunk = List.last(chunks)
      assert utf16_length(second_chunk) == 905
    end

    test "splits multiple times for very long messages" do
      text = String.duplicate("word ", 2000)

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 3
      assert all_within_limit?(chunks)

      reconstructed = Enum.join(chunks, " ")
      assert abs(byte_size(reconstructed) - byte_size(text)) < 10
    end

    test "handles newlines in text" do
      lines = for i <- 1..300, do: "Line #{i} with some content here.\n"
      text = Enum.join(lines, "")

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 2
      assert all_within_limit?(chunks)
    end

    test "handles mixed paragraph and word boundaries" do
      para1 = String.duplicate("Short para. ", 100)
      long_word = String.duplicate("x", 3000)
      para2 = String.duplicate("Another para. ", 100)

      text = para1 <> "\n\n" <> long_word <> "\n\n" <> para2

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 2
      assert all_within_limit?(chunks)
    end

    test "handles empty string" do
      assert Telegram.split_message("") == [""]
    end

    test "handles supplementary-plane emoji within the UTF-16 limit" do
      # 🎉 is one grapheme and 2 UTF-16 code units. 2100 "🎉 " groups = 6300
      # code units, forcing at least two chunks.
      emoji_text = String.duplicate("🎉 ", 2100)

      chunks = Telegram.split_message(emoji_text)
      assert length(chunks) >= 2
      assert all_within_limit?(chunks)
    end

    test "flag emoji (4 UTF-16 code units per grapheme) stay within the limit" do
      # Regression: 🇺🇸 is one grapheme but four UTF-16 code units. Under a
      # grapheme-based limit, 4096 flags would be ~16k code units — Telegram
      # would reject every chunk. The splitter must count code units.
      text = String.duplicate("🇺🇸", 4096)

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 4
      assert all_within_limit?(chunks)
    end

    test "pathological: single grapheme larger than the limit is split" do
      # A base character plus thousands of combining marks is one grapheme
      # cluster. At 5000+ code units it's bigger than Telegram accepts; the
      # splitter must break inside the grapheme rather than emit it whole.
      text = "a" <> String.duplicate("\u0301", 5000)

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 2
      assert all_within_limit?(chunks)
    end

    test "edge case: message with only one word slightly over limit" do
      text = String.duplicate("B", 4100)

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2

      assert utf16_length(hd(chunks)) == 4096
      assert String.ends_with?(hd(chunks), "-")

      assert utf16_length(List.last(chunks)) == 5
    end

    test "preserves spacing when splitting at word boundaries" do
      words = for i <- 1..1000, do: "word#{i}"
      text = Enum.join(words, " ")

      chunks = Telegram.split_message(text)
      assert all_within_limit?(chunks)

      Enum.each(chunks, fn chunk ->
        refute String.starts_with?(chunk, " ")
      end)
    end
  end
end
