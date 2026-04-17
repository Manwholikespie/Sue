defmodule Sue.Mailbox.TelegramTest do
  use ExUnit.Case, async: true

  alias Sue.Mailbox.Telegram

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
      # Create a message that's 4100 characters with spaces
      part1 = String.duplicate("a", 4090)
      part2 = String.duplicate("b", 10)
      text = part1 <> " " <> part2

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)
      # Verify original text can be reconstructed (minus the space)
      assert Enum.join(chunks, " ") == text
    end

    test "splits message at paragraph boundary when possible" do
      # Create paragraphs where split should happen at \n\n
      para1 = String.duplicate("First paragraph. ", 200)
      para2 = String.duplicate("Second paragraph. ", 200)
      text = para1 <> "\n\n" <> para2

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)
      # First chunk should end at paragraph boundary
      assert hd(chunks) == para1
    end

    test "splits very long word with hyphen" do
      # Create a "word" that's too long (no spaces)
      text = String.duplicate("A", 5000)

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2

      # First chunk should be 4095 chars + hyphen = 4096
      first_chunk = hd(chunks)
      assert String.length(first_chunk) == 4096
      assert String.ends_with?(first_chunk, "-")

      # Second chunk should be the rest (5000 - 4095 = 905)
      second_chunk = List.last(chunks)
      assert String.length(second_chunk) == 905
    end

    test "splits multiple times for very long messages" do
      # Create a message that needs multiple splits
      # Creates ~10000 char message
      text = String.duplicate("word ", 2000)

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 3
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)

      # Verify we can roughly reconstruct the message
      reconstructed = Enum.join(chunks, " ")
      # Should be similar length (might differ by spaces at boundaries)
      assert abs(byte_size(reconstructed) - byte_size(text)) < 10
    end

    test "handles newlines in text" do
      # Create text with newlines that should split at newline boundary
      lines = for i <- 1..300, do: "Line #{i} with some content here.\n"
      text = Enum.join(lines, "")

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)
    end

    test "handles mixed paragraph and word boundaries" do
      # Create a complex message with paragraphs and long words
      para1 = String.duplicate("Short para. ", 100)
      long_word = String.duplicate("x", 3000)
      para2 = String.duplicate("Another para. ", 100)

      text = para1 <> "\n\n" <> long_word <> "\n\n" <> para2

      chunks = Telegram.split_message(text)
      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)
    end

    test "handles empty string" do
      assert Telegram.split_message("") == [""]
    end

    test "handles unicode characters correctly" do
      # Unicode emoji are multi-byte, so 4096 emoji would exceed byte limit
      # Create a message with unicode that needs splitting
      # ~8400 bytes (emoji is 4 bytes)
      emoji_text = String.duplicate("🎉 ", 2100)

      chunks = Telegram.split_message(emoji_text)
      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)
    end

    test "edge case: message with only one word slightly over limit" do
      # Single word that's 4100 chars (no spaces to split on)
      text = String.duplicate("B", 4100)

      chunks = Telegram.split_message(text)
      assert length(chunks) == 2

      # First chunk: 4095 + hyphen
      assert String.length(hd(chunks)) == 4096
      assert String.ends_with?(hd(chunks), "-")

      # Second chunk: remaining 5 chars
      assert String.length(List.last(chunks)) == 5
    end

    test "preserves spacing when splitting at word boundaries" do
      # Create message where split should happen between words
      words = for i <- 1..1000, do: "word#{i}"
      text = Enum.join(words, " ")

      chunks = Telegram.split_message(text)

      # All chunks should be under limit
      assert Enum.all?(chunks, fn chunk -> String.length(chunk) <= 4096 end)

      # Verify no chunk starts or ends with space (splits consume the delimiter)
      Enum.each(chunks, fn chunk ->
        refute String.starts_with?(chunk, " ")
      end)
    end
  end
end
