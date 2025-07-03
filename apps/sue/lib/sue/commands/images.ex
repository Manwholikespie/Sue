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

  def c_motivate(%Message{has_attachments: true, attachments: [att | _]} = msg) do
    with {:ok, att} <- Attachment.download(att),
         :ok <- validate_image(att),
         {:ok, caption} <- parse_caption(msg.args) do
      motivate_helper(att.filepath, elem(caption, 0), elem(caption, 1))
    else
      {:error, :not_image} ->
        %Response{body: "!motivate only supports images right now, sorry :("}

      {:error, :too_big} ->
        %Response{body: "Media is too large. Please try again with a smaller file."}

      {:error, :missing_caption} ->
        %Response{
          body:
            "Please provide a caption in the form of: !motivate top text, bottom text. The bottom text is optional."
        }

      {:error, %Attachment{} = att} ->
        %Response{body: "There was an issue with the attachment: #{inspect(att.errors)}"}

      {:error, :invalid_attachment} ->
        %Response{body: "Unable to download the attachment. Please try again."}
    end
  end

  defp validate_image(%Attachment{errors: []} = att) do
    if Attachment.is_image?(att), do: :ok, else: {:error, :not_image}
  end

  defp validate_image(%Attachment{errors: [{:size, _} | _]}), do: {:error, :too_big}
  defp validate_image(_), do: {:error, :not_image}

  defp parse_caption(""), do: {:error, :missing_caption}

  defp parse_caption(args) do
    case String.split(args, ~r{,}, parts: 2, trim: true) |> Enum.map(&String.trim/1) do
      [] -> {:error, :missing_caption}
      [top] -> {:ok, {top, ""}}
      [top, bot] -> {:ok, {top, bot}}
    end
  end

  defp motivate_helper(path, top_text, bot_text) do
    outpath = Images.Motivate.motivate(path, top_text, bot_text)
    %Attachment{filepath: outpath}
  end

  @spec random_image_from_dir(bitstring()) :: %Attachment{}
  defp random_image_from_dir(dir) do
    path = Path.join(@media_path, dir)

    path
    |> File.ls!()
    |> Enum.random()
    |> (fn image ->
          %Attachment{filepath: Path.join(path, image)}
        end).()
  end
end
