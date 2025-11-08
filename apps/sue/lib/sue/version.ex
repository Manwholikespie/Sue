defmodule Sue.Version do
  @moduledoc """
  Provides version and git information for Sue, captured at compile time.
  """

  @external_resource ".git/HEAD"
  @external_resource ".git/refs/heads/master"

  @git_sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
              {sha, 0} -> String.trim(sha)
              _ -> "unknown"
            end)

  @git_branch (case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
                      stderr_to_stdout: true
                    ) do
                 {branch, 0} -> String.trim(branch)
                 _ -> "unknown"
               end)

  @umbrella_version (case File.read("../../mix.exs") do
                       {:ok, content} ->
                         case Regex.run(~r/version:\s*"([^"]+)"/, content) do
                           [_, version] -> version
                           _ -> "unknown"
                         end

                       _ ->
                         "unknown"
                     end)

  @sue_version Mix.Project.config()[:version]

  @doc """
  Returns the Sue application version.
  """
  def version, do: @sue_version

  @doc """
  Returns the umbrella project version.
  """
  def umbrella_version, do: @umbrella_version

  @doc """
  Returns the git commit SHA (short format).
  """
  def git_sha, do: @git_sha

  @doc """
  Returns the current git branch.
  """
  def git_branch, do: @git_branch

  @doc """
  Returns a formatted string with all version information.
  """
  def full_version do
    "Sue v#{umbrella_version()} (sue: v#{version()})\nGit: #{git_sha()} on #{git_branch()}"
  end
end
