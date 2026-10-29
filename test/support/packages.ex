# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Test.Packages do
  @moduledoc """
  Where a Mishka package's files are, whichever way Mix got the package.

  `mix.exs` takes each one from its checkout under `__extensions/<name>` when there is one, and from
  Hex otherwise (`deps/<name>`). A test that reads a package's source must not name either folder:
  it asks Mix, which knows, and so the same test runs on a developer's machine and in CI, where
  there is no `__extensions/`.

  A Hex package ships `lib/` and some of `priv/`, never `test/`. A test that needs a fixture keeps
  its own under this project's `test/fixtures/`.

  Every function here fails the test when it finds nothing. A scan over a glob that matched no file
  would pass without having looked at anything, and nobody would see that.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @all [
    :mishka_cms_core,
    :mishka_cms_builder,
    :mishka_blog,
    :mishka_document,
    :mishka_gervaz,
    :mishka_cms_auth_google,
    :mishka_cms_auth_github,
    :mishka_cms_auth_slack,
    :mishka_cms_auth_discord
  ]

  @doc """
  Every Mishka package this project loads: the engine, the visual page builder, the blog and
  documentation extensions, Mishka Gervaz and the four sign-in providers.
  """
  def all, do: @all

  @doc """
  The directory of `app`: `__extensions/<app>` for a local checkout, `deps/<app>` for a Hex package,
  and this project's own directory for `:mishka_cms`.
  """
  def path(app) when is_atom(app) do
    cond do
      app == Mix.Project.config()[:app] ->
        Path.dirname(Mix.Project.project_file())

      path = Mix.Project.deps_paths()[app] ->
        path

      true ->
        flunk("#{inspect(app)} is not a dependency of this project, so it has no directory")
    end
  end

  @doc """
  The path of `relative` inside `app`, which must be there. A package says what it ships, and an
  older release may ship less than the checkout does.
  """
  def file!(app, relative) when is_atom(app) and is_binary(relative) do
    file = Path.join(path(app), relative)

    if File.exists?(file) do
      file
    else
      flunk(
        "#{inspect(app)} has no #{relative} (looked in #{path(app)}); this version of the package does not ship it"
      )
    end
  end

  @doc """
  The files `glob` matches inside `app`, as `{label, absolute_path}` pairs, sorted. At least one.

  The label is the path inside the package, with the package's name in front of it for a dependency
  (`mishka_cms_core/lib/mishka_cms_core/gettext.ex`) and none for this project (`lib/mishka_cms/repo.ex`).
  Show the label and read the path: the folder holding a package differs between a local checkout and
  Hex, and a test that matches on it (`/deps/`, `/test/`) matches on where Mix put the package.
  """
  def sources(app, glob) when is_atom(app) and is_binary(glob) do
    root = path(app)
    prefix = if app == Mix.Project.config()[:app], do: "", else: "#{app}/"

    case root |> Path.join(glob) |> Path.wildcard() |> Enum.sort() do
      [] ->
        flunk("#{glob} matched no file in #{inspect(app)} (looked in #{root})")

      files ->
        Enum.map(files, &{prefix <> Path.relative_to(&1, root), &1})
    end
  end
end
