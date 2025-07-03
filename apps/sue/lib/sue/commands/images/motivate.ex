defmodule Sue.Commands.Images.Motivate do
  alias Sue.Utils
  require Logger

  @type image() :: Vix.Vips.Image.t()

  @spec top_text(bitstring()) :: image()
  defp top_text(text) do
    {:ok, {img, _}} =
      Vix.Vips.Operation.text(
        ~s(<span foreground="white">#{text}</span>),
        rgba: true,
        wrap: :VIPS_TEXT_WRAP_WORD_CHAR,
        font: "serif 56",
        width: 600,
        align: :VIPS_ALIGN_CENTRE
      )

    img
  end

  @spec middle_spacing(integer()) :: image()
  defp middle_spacing(height \\ 10) when is_integer(height) do
    Image.new!(600, height)
  end

  @spec bot_text(bitstring()) :: image()
  defp bot_text(text) do
    {:ok, {img, _}} =
      Vix.Vips.Operation.text(
        ~s(<span foreground="white">#{text}</span>),
        rgba: true,
        wrap: :VIPS_TEXT_WRAP_WORD_CHAR,
        font: "serif 28",
        width: 600,
        align: :VIPS_ALIGN_CENTRE
      )

    img
  end

  @spec rescale(image(), integer()) :: image()
  defp rescale(img, max_size) do
    {orig_w, orig_h, _bands} = Image.shape(img)
    scale = max_size / max(orig_w, orig_h)
    Image.resize!(img, scale, vertical_scale: scale)
  end

  @spec border(image(), atom(), integer()) :: image()
  defp border(img, color, thickness) do
    {w, h, _bands} = Image.shape(img)

    Image.embed!(
      img,
      w + 2 * thickness,
      h + 2 * thickness,
      background_color: color
    )
  end

  @spec borders(image()) :: image()
  defp borders(center_img) do
    part1 =
      center_img
      |> rescale(500)
      |> border(:black, 5)
      |> border(:white, 3)
      |> border(:black, 50)

    {w, h, _bands} = Image.shape(part1)
    Image.crop!(part1, 0, 0, w, h - 50)
  end

  def manual_join(img1, img2) do
    # get dimensions
    {w1, h1, _} = Image.shape(img1)
    {w2, h2, _} = Image.shape(img2)

    width = max(w1, w2)
    height = h1 + h2

    # embed the first image into a blank canvas
    canvas1 = Image.embed!(img1, width, height, x: :center, y: 0)

    # overlay the second image at y = h1, centered horizontally
    Image.compose!(canvas1, img2, x: :center, y: h1)
  end

  def pad(img, t, b) do
    {w, h, _} = Image.shape(img)

    Image.embed!(
      img,
      w,
      h + t + b,
      x: 0,
      y: t,
      background_color: :black
    )
  end

  @spec alphatize(image()) :: image()
  defp alphatize(img) do
    {w, h, _bands} = Image.shape(img)
    alpha = Image.new!(w, h, bands: 1, color: 255)
    Image.add_alpha!(img, alpha)
  end

  defp escape_html_text(string) do
    string =
      string
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    {:ok, string}
  end

  def motivate(imagepath, ttext, btext) do
    {:ok, ttext} = escape_html_text(ttext)
    {:ok, btext} = escape_html_text(btext)

    center_img =
      Image.open!(imagepath)
      |> Image.flatten!()
      |> borders()

    caption_img =
      case btext do
        "" ->
          pad(top_text(ttext), 15, 20)

        _ ->
          manual_join(
            pad(top_text(ttext), 15, 20),
            pad(bot_text(btext), 0, 20)
          )
      end

    out_path = Path.join(System.tmp_dir!(), Utils.tmp_file_name("out.png"))

    manual_join(center_img, caption_img)
    |> Image.flatten!()
    |> Image.write!(out_path)

    out_path
  end
end
