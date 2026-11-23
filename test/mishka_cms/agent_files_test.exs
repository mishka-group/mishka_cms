# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.AgentFilesTest do
  @moduledoc """
  The files an agent reads stay true: every pointer leads to `AGENTS.md`, every link in the agent
  pages names a file that exists, and every row of `FRICTION.md` says what catches it now.

  Links into `deps/` are left out: they exist only after `mix deps.get`, and `mix usage_rules.sync`
  writes them.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @caught_by ["check:", "skill rule", "helper:", "decided", "open"]

  test "CLAUDE.md and the Copilot instructions send an agent to AGENTS.md" do
    for pointer <- ["CLAUDE.md", ".github/copilot-instructions.md"] do
      assert read(pointer) =~ "AGENTS.md", "#{pointer} does not name AGENTS.md"
    end
  end

  test "every link in the agent pages names a file that exists" do
    broken =
      for page <- pages(),
          [_all, target] <- Regex.scan(~r/\]\(([^)#\s]+)(?:#[^)]*)?\)/, read(page)),
          not String.contains?(target, "://"),
          not String.starts_with?(target, "deps/"),
          path = Path.expand(target, Path.dirname(Path.join(@root, page))),
          not File.exists?(path),
          do: "#{page} → #{target}"

    assert broken == [], "links to missing files:\n" <> Enum.join(broken, "\n")
  end

  test "every FRICTION.md row says what catches it now" do
    rows =
      for line <- String.split(read("FRICTION.md"), "\n"),
          String.starts_with?(line, "| 20"),
          do: line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    assert rows != [], "FRICTION.md has no dated rows"

    for [_date, _what, _where, caught] = row <- rows do
      assert String.starts_with?(caught, @caught_by),
             "#{inspect(row)} does not start its last column with one of #{inspect(@caught_by)}"
    end
  end

  defp pages do
    docs =
      @root
      |> Path.join("docs/**/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @root))

    ["AGENTS.md", "FRICTION.md", "GLOSSARY.md" | docs]
  end

  defp read(path), do: File.read!(Path.join(@root, path))
end
