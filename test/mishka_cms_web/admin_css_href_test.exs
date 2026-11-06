# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.AdminCssHrefTest do
  @moduledoc """
  The admin stylesheet link carries a version, so a browser fetches the file again after
  `mix admin_css` rebuilds it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsWeb.Layouts

  test "the link names the stylesheet and carries a version" do
    assert %URI{path: path, query: query} = URI.parse(Layouts.admin_css_href())
    assert path =~ ~r{^/assets/css/admin(-[0-9a-f]+)?\.css$}
    assert is_binary(query) and query != ""
  end
end
