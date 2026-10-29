# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.InstallDoneStepTest do
  @moduledoc """
  The installer's last screen puts the new site's host into translated markup that is rendered raw.
  The Site resource only stores a hostname, so this draws the screen straight from its assigns with a
  host that is markup, to show the host is escaped before it goes into the translation.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MishkaCmsWeb.InstallLive

  test "escapes the site's host in the sentence that names it" do
    html =
      %{
        step: :done,
        config: %{},
        catalog: nil,
        seeded?: false,
        site: %{host: "<script>x()</script>"}
      }
      |> InstallLive.render()
      |> rendered_to_string()

    assert html =~ "<strong>&lt;script&gt;x()&lt;/script&gt;</strong>"
    refute html =~ "<script>x()</script>"
  end
end
