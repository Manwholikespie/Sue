defmodule Sue.Commands.Images do
  alias __MODULE__
  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"

  require Logger
  alias Sue.Models.{Attachment, Response, Message}

  @media_path Path.join(:code.priv_dir(:sue), "media/")

  @doc """
  Shows a picture of a cute doog.
  Usage: !doog
  """
  def c_doog(_msg) do
    %Attachment{filepath: Path.join(@media_path, "korone.JPG")}
  end

  @doc """
  Literally 1984
  Usage: !1984
  """
  def c_1984(_msg) do
    %Attachment{filepath: Path.join(@media_path, "1984.jpg")}
  end

  @doc """
  Snap!
  """
  def c_cringe(_msg), do: random_image_from_dir("cringe/")

  @doc """
  Sends a cute photo drawn by mhug.
  """
  def c_qt(_msg), do: random_image_from_dir("qt/")

  @doc """
  Create a motivational poster.
  Usage: !motivate <image> <top text>, <bottom text>
  (bottom text is optional)
  """
  def c_motivate(%Message{has_attachments: false}) do
    %Response{body: "Please include an image with your message. See !help motivate"}
  end

  # TODO: verify this even works for discord
  def c_motivate(%Message{has_attachments: true, attachments: [att | _]} = msg) do
    # only process the first attachment.
    with {:ok, att} <- Attachment.resolve(msg, att) do
      path = resolve_filepath(att.filepath)

      {top_text, bot_text} =
        case String.split(msg.args, ~r{,}, parts: 2, trim: true) |> Enum.map(&String.trim/1) do
          [] -> {nil, nil}
          [top] -> {top, ""}
          [top, bot] -> {top, bot}
        end

      motivate_helper(path, top_text, bot_text)
    else
      {:error, :not_image} ->
        %Response{body: "!motivate only supports images right now, sorry :("}

      {:error, :too_big} ->
        %Response{body: "Media is too large. Please try again with a smaller file."}
    end
  end

  defp motivate_helper(_path, nil, nil) do
    %Response{
      body:
        "Please provide a caption in the form of: !motivate top text, bottom text. The bottom text is optional."
    }
  end

  defp motivate_helper(path, top_text, bot_text) do
    outpath = Images.Motivate.run(path, top_text, bot_text)
    %Attachment{filepath: outpath}
  end

  @spec random_image_from_dir(bitstring()) :: Attachment.t()
  defp random_image_from_dir(dir) do
    path = Path.join(@media_path, dir)

    path
    |> File.ls!()
    |> Enum.random()
    |> (fn image ->
          %Attachment{filepath: Path.join(path, image)}
        end).()
  end

  defp resolve_filepath(maybe_path) do
    if String.starts_with?(maybe_path, "~") do
      Path.expand(maybe_path)
    else
      Path.absname(maybe_path)
    end
  end
end
