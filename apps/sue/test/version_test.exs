defmodule Sue.VersionTest do
  use ExUnit.Case

  test "version returns a string" do
    assert is_binary(Sue.Version.version())
  end

  test "umbrella_version returns a string" do
    assert is_binary(Sue.Version.umbrella_version())
  end

  test "git_sha returns a string" do
    sha = Sue.Version.git_sha()
    assert is_binary(sha)
    # Should be either a valid short SHA (7 chars) or "unknown"
    assert sha == "unknown" or String.length(sha) == 7
  end

  test "git_branch returns a string" do
    branch = Sue.Version.git_branch()
    assert is_binary(branch)
    # Should be either a valid branch name or "unknown"
    assert is_binary(branch)
  end

  test "full_version contains expected components" do
    full = Sue.Version.full_version()
    assert is_binary(full)
    assert String.contains?(full, "Sue v")
    assert String.contains?(full, "Git:")
  end
end
