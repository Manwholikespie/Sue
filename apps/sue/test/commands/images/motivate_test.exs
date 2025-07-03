defmodule Sue.Commands.Images.MotivateTest do
  use ExUnit.Case
  alias Sue.Commands.Images.Motivate

  @media_path Path.join(:code.priv_dir(:sue), "media/")

  describe "motivate/3" do
    test "generates a demotivational with top and bottom text" do
      image_path = Path.join(@media_path, "korone.JPG")
      top_text = "I just lost my dawg"
      bottom_text = "my brother taught me how to chase the bag"

      result_path = Motivate.motivate(image_path, top_text, bottom_text)

      assert is_binary(result_path)
      assert File.exists?(result_path)
      assert String.ends_with?(result_path, ".png")

      # Clean up the generated file
      File.rm!(result_path)
    end

    test "generates a demotivational with only top text" do
      image_path = Path.join(@media_path, "korone.JPG")
      top_text = "salsa y picante"
      bottom_text = ""

      result_path = Motivate.motivate(image_path, top_text, bottom_text)

      assert is_binary(result_path)
      assert File.exists?(result_path)
      assert String.ends_with?(result_path, ".png")

      # Clean up the generated file
      File.rm!(result_path)
    end

    test "escapes HTML in text inputs" do
      image_path = Path.join(@media_path, "korone.JPG")
      top_text = "<script>alert('xss')</script>"
      bottom_text = "Test & More"

      result_path = Motivate.motivate(image_path, top_text, bottom_text)

      assert is_binary(result_path)
      assert File.exists?(result_path)
      assert String.ends_with?(result_path, ".png")

      # Clean up the generated file
      File.rm!(result_path)
    end
  end
end
