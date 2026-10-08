defmodule MishkaCmsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MishkaCmsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
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
