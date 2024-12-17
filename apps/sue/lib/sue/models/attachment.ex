defmodule Sue.Models.Attachment do
  alias __MODULE__

  defstruct [
    # imessage id is integer
    :id,
    :filepath,
    :mime_type,
    :fsize,
    resolved: false,
    errors: [],
    metadata: %{}
  ]

  alias Sue.Models.Message

  @type t() :: %Attachment{}

  # 20MiB
  @max_attachment_size_bytes 20 * 1024 * 1024
  @tmp_path System.tmp_dir!()

  # TODO: This code is crap. Keep filepath and filename separate.
  #       Update the constructors.

  def new(
        [a_id: aid, m_id: mid, filename: filename, mime_type: mime_type, total_bytes: fsize],
        :imessage
      ) do
    %Attachment{
      id: aid,
      # despite being called filename, it's actually a relative path to ~/Library/Messages/...
      filepath: Sue.Utils.resolve_filepath(filename),
      mime_type: mime_type,
      fsize: fsize,
      resolved: true,
      metadata: %{message_id: mid}
    }
  end

  def new(
        %{
          file_id: file_id,
          file_size: fsize,
          file_unique_id: file_unique_id
        } = data,
        :telegram
      ) do
    file_url = ExGram.File.file_url(ExGram.get_file!(file_id))

    %Attachment{
      id: file_unique_id,
      filepath: nil,
      fsize: fsize,
      resolved: false,
      errors: check_size_for_errors(fsize),
      mime_type: Map.get(data, :mime_type, "image/jpeg"),
      metadata: %{url: file_url}
    }
  end

  @spec resolve(Message.t(), t()) ::
          {:ok, t()} | {:error, t() | :too_big | :not_image}
  def resolve(_, %Attachment{resolved: true} = att), do: {:ok, att}
  def resolve(_, %Attachment{errors: [_]} = att), do: {:error, att}

  def resolve(%Message{platform: _}, att) do
    with :ok <- check_img_size(att),
         :ok <- check_is_image(att) do
      filepath = dl_url_to_path(att.metadata.url, "#{att.id}")

      {:ok,
       %Attachment{
         att
         | resolved: true,
           filepath: filepath
       }}
    else
      error -> error
    end
  end

  @spec from_url(bitstring()) :: t()
  def from_url(url) do
    filepath = dl_url_to_path(url)

    %Attachment{
      resolved: true,
      filepath: filepath
    }
  end

  @spec dl_url_to_path(binary, binary) :: bitstring()
  def dl_url_to_path(url, filename \\ Sue.Utils.unique_string()) do
    filepath = Path.join(@tmp_path, filename <> Path.extname(url))
    {:ok, env} = Tesla.get(url)
    :ok = File.write!(filepath, env.body)

    filepath
  end

  defp check_is_image(%Attachment{mime_type: mime_type}) when is_bitstring(mime_type) do
    if mime_type |> String.starts_with?("image/") and not (mime_type |> String.ends_with?("gif")) do
      :ok
    else
      {:error, :not_image}
    end
  end

  # TODO: Have some part of the message processing pipeline that can detect if
  #   we are processing a message with an attachment with an error and warn the
  #   user as soon as we detect this.
  defp check_size_for_errors(fsize) do
    if fsize <= @max_attachment_size_bytes do
      []
    else
      [{:size, "File size is #{@max_attachment_size_bytes - fsize} bytes too big."}]
    end
  end

  defp check_img_size(att) do
    if att.fsize <= @max_attachment_size_bytes do
      :ok
    else
      {:error, :too_big}
    end
  end
end
