# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.ConnCase do
  @moduledoc """
  For tests that need a connection: imports `Plug.Conn`, `Phoenix.ConnTest` and the verified routes,
  sets `@endpoint`, and hands each test a `conn` over the sandbox `MishkaCms.DataCase.setup_sandbox/1`
  checks out, shared with the processes it starts unless the test is `async`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MishkaCmsWeb.Endpoint

      use MishkaCmsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MishkaCmsWeb.ConnCase
    end
  end

  setup tags do
    MishkaCms.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  One run of a module per URL mode, each with its `url_mode` in the context — for a module whose
  addresses follow `site.language_urls`:

      use MishkaCmsWeb.ConnCase, async: false, parameterize: MishkaCmsWeb.ConnCase.url_modes()
  """
  def url_modes, do: Enum.map(MishkaCmsCore.Runtime.Languages.url_modes(), &%{url_mode: &1})

  @doc """
  The site bundle a draft preview links in its `<head>` (`layouts/preview.html.heex`), beside the
  preview's own `preview.js`; `nil` when it links none.
  """
  def preview_site_js(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("head script[src]")
    |> LazyHTML.attribute("src")
    |> Enum.reject(&(&1 == "/assets/js/preview.js"))
    |> List.first()
  end

  @doc """
  Where `language` puts `path` in `url_mode` on a site whose first language is English: English
  under no prefix in `"prefix_others"`, every other language — and English in `"prefix_all"` —
  under its own.

      language_path("prefix_others", "en", "/blog") #=> "/blog"
      language_path("prefix_others", "fa", "/blog") #=> "/fa/blog"
      language_path("prefix_all", "en", "/")        #=> "/en"
  """
  def language_path("prefix_others", "en", path), do: path
  def language_path(_url_mode, language, "/"), do: "/" <> language
  def language_path(_url_mode, language, path), do: "/" <> language <> path

  @doc "`language_path/3` in English."
  def english(url_mode, path), do: language_path(url_mode, "en", path)
end
