defmodule Sue.Commands.Shell do
  Module.register_attribute(__MODULE__, :is_persisted, persist: true)
  @is_persisted "is persisted"
  alias Sue.Models.{Response, Message, Account}

  @doc """
  A struct that implements Collectable to be akin to redirecting output to /dev/null.
  https://elixirforum.com/t/how-to-use-system-cmd-s-into-option-with-dev-null/37444/2
  """
  defmodule DevNull do
    defstruct []

    defimpl Collectable do
      def into(original) do
        collector_fun = fn
          _dev_null, :halt -> :ok
          dev_null, _ -> dev_null
        end

        {original, collector_fun}
      end
    end
  end

  @doc """
  Show how long Sue's server has been running.
  Usage: !uptime
  """
  def c_uptime(_msg) do
    %Response{body: output_single_cmd("uptime")}
  end

  @doc """
  Tell a random, hopefully interesting adage.
  Usage: !fortune
  """
  def c_fortune(_msg) do
    %Response{body: output_single_cmd("fortune")}
  end

  @spec output_single_cmd(bitstring()) :: bitstring()
  defp output_single_cmd(cmd) do
    {output, 0} = System.cmd(cmd, [])
    output
  end

  @doc """
  Download media from a URL, saving to my server's meme folder.
  Usage: !ydl https://example.com/content.webm
  """
  def c_ydl(%Message{account: %Account{is_admin: true}, args: url}) do
    # assert it's a single, valid url
    if String.match?(url, ~r/^https?:\/\/[^\s]+$/) do
      # Run in background.
      spawn(fn ->
        System.cmd(
          "yt-dlp",
          [
            "--recode-video",
            "mp4",
            "--postprocessor-args",
            "-c:v libx265 -tag:v hvc1 -c:a aac",
            "-P",
            "~/Documents/lol",
            url
          ],
          into: %DevNull{}
        )
      end)

      %Response{body: "Download queued"}
    else
      %Response{body: "Please provide a single URL"}
    end
  end

  def c_ydl(_msg) do
    %Response{body: "This command is only available to administrators."}
  end
end
