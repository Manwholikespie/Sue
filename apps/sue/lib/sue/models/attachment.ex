defmodule Sue.Models.Attachment do
  alias __MODULE__

  defstruct [
    :id,
    # Primary representation - URL to the attachment
    :url,
    # Optional - only populated when file is downloaded
    :filepath,
    # Keep for more granular type information
    :mime_type,
    :fsize,
    downloaded: false,
    errors: [],
    metadata: %{}
  ]

  @type t() :: %Attachment{
          id: bitstring() | integer(),
          url: bitstring() | nil,
          filepath: bitstring() | nil,
          mime_type: any(),
          fsize: integer() | nil,
          downloaded: boolean(),
          errors: any(),
          metadata: map()
        }

  # 20MiB
  @max_attachment_size_bytes 20 * 1024 * 1024
  @tmp_path System.tmp_dir!()
  @default_mime "application/octet-stream"

  # Constructor for iMessage attachments
  def new(
        [a_id: aid, m_id: mid, filename: filename, mime_type: mime_type, total_bytes: fsize],
        :imessage
      ) do
    filepath = Sue.Utils.resolve_filepath(filename)

    %Attachment{
      id: aid,
      filepath: filepath,
      mime_type: mime_type,
      fsize: fsize,
      # iMessage attachments are already local
      downloaded: true,
      errors: check_size_for_errors(fsize),
      metadata: %{message_id: mid}
    }
  end

  # Constructor for Telegram attachments
  def new(%{file_id: file_id, file_size: fsize, file_unique_id: file_unique_id} = data, :telegram) do
    %Attachment{
      id: file_unique_id,
      filepath: nil,
      mime_type: Map.get(data, :mime_type, "image/jpeg"),
      fsize: fsize,
      downloaded: false,
      errors: check_size_for_errors(fsize),
      metadata: %{file_id: file_id}
    }
  end

  # Create from URL directly
  @spec from_url(bitstring()) :: %__MODULE__{}
  def from_url(url) do
    %Attachment{
      url: url,
      downloaded: false
    }
  end

  # Only download the file when explicitly requested
  @spec download(t()) :: {:ok, t()} | {:error, t() | atom()}
  def download(%Attachment{downloaded: true} = att), do: {:ok, att}
  def download(%Attachment{errors: [_ | _]} = att), do: {:error, att}

  def download(%Attachment{url: "http" <> _ = url} = att) do
    case download_url(url) do
      {:ok, filepath, fsize, mime_type} ->
        {:ok,
         %Attachment{
           att
           | downloaded: true,
             filepath: filepath,
             fsize: fsize,
             mime_type: mime_type,
             errors: check_size_for_errors(fsize)
         }}

      {:error, reason} ->
        {:error, %Attachment{att | errors: [{:download_error, reason}]}}
    end
  end

  def download(_), do: {:error, :invalid_attachment}

  # Helper functions for checking if it's an image
  @spec is_image?(t()) :: boolean()
  def is_image?(%Attachment{mime_type: mime_type}) when is_bitstring(mime_type) do
    mime_type |> String.starts_with?("image/") and not (mime_type |> String.ends_with?("gif"))
  end

  def is_image?(_), do: false

  # Helper for checking if it's a valid file
  @spec valid?(t()) :: boolean()
  def valid?(%Attachment{downloaded: true, errors: []}), do: true
  def valid?(_), do: false

  # Helper function to check if a string is a URL
  @spec has_url?(t()) :: boolean()
  def has_url?(%Attachment{url: "http" <> _}), do: true
  def has_url?(_), do: false

  # Download URL to local path
  defp download_url(url) do
    filename = Sue.Utils.unique_string()
    filepath = Path.join(@tmp_path, filename <> Path.extname(url))

    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{body: body, headers: headers}} ->
        File.write!(filepath, body)
        fsize = byte_size(body)
        mime_type = extract_mime_from_headers(headers) || @default_mime
        {:ok, filepath, fsize, mime_type}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp extract_mime_from_headers(headers) do
    Enum.find_value(headers, fn
      {"Content-Type", value} -> value |> String.split(";") |> List.first()
      _ -> nil
    end)
  end

  defp check_size_for_errors(nil), do: []
  defp check_size_for_errors(fsize) when fsize <= @max_attachment_size_bytes, do: []

  defp check_size_for_errors(fsize),
    do: [
      {:size,
       "File size exceeds maximum allowed size by #{fsize - @max_attachment_size_bytes} bytes"}
    ]
end
