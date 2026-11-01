# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.DraftPreviewCssTest do
  @moduledoc """
  The new-tab preview opens at once under a "Building preview…" overlay, and its stylesheet, compiled
  from the record on every request, takes the overlay away when it applies — all under a strict
  Content-Security-Policy: the stylesheet comes from this origin, the only inline `<style>` carries
  the response's nonce, and there is no inline script.

  See `MishkaCmsWeb.DraftPreviewLive` and `MishkaCmsWeb.DraftPreviewController`.
  """
  use MishkaCmsWeb.ConnCase, async: false

  # A stylesheet is a real Tailwind pass, and the run's first one installs Tailwind.
  @moduletag timeout: :timer.minutes(3)

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, PageDraft}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsWeb.DraftPreviewLive
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    MishkaCmsCore.Settings.put("cms.offline", false)

    page = create_page!(site_id: site.id, template: ~s(<h1 class="mt-[29px]">Preview</h1>))
    on_exit(fn -> DraftPreviewAssets.purge(page) end)

    %{site: site, page: page}
  end

  defp localhost do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  # The policy as the browser enforces it, read off the response.
  defp enforced!(policy) do
    previous = Application.get_env(:mishka_cms, SecurityHeaders)
    Application.put_env(:mishka_cms, SecurityHeaders, policy)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mishka_cms, SecurityHeaders)
        kept -> Application.put_env(:mishka_cms, SecurityHeaders, kept)
      end
    end)
  end

  # `SecurityHeaders` writes the one with `script-src` in it; Phoenix's own names only two directives.
  defp policy(conn) do
    conn
    |> get_resp_header("content-security-policy")
    |> Enum.find(&String.contains?(&1, "script-src"))
    |> String.split(";", trim: true)
    |> Map.new(fn directive ->
      [name | sources] = directive |> String.trim() |> String.split(" ")
      {name, sources}
    end)
  end

  describe "the preview page" do
    test "opens under the building overlay, with the stylesheet linked after it in the body", %{
      page: page
    } do
      token = page.preview_token
      html = localhost() |> get("/_preview/page/#{token}") |> html_response(200)
      [head, body] = String.split(html, "</head>", parts: 2)

      refute head =~ "/_preview/page/#{token}/css",
             "a stylesheet in the head holds the whole page blank while it compiles"

      assert body =~ ~s(id="mishka-preview-building")
      assert body =~ "Building preview…"

      [before_link, _after] = String.split(body, ~s(id="mishka-preview-css"), parts: 2)
      assert before_link =~ ~s(id="mishka-preview-building"), "the overlay is not drawn first"
      assert body =~ ~s(href="/_preview/page/#{token}/css")
    end

    test "is compiled by nothing until its stylesheet is asked for", %{page: page} do
      {:ok, _view, _html} = live(localhost(), "/_preview/page/#{page.preview_token}")

      refute MishkaCmsCore.Runtime.States.AssetsState.exists?(page.preview_token, "css")
    end
  end

  describe "the stylesheet" do
    test "is compiled from the record and ends with the rule that takes the overlay away", %{
      page: page
    } do
      token = page.preview_token
      {:ok, _view, _html} = live(localhost(), "/_preview/page/#{token}")

      conn = localhost() |> get("/_preview/page/#{token}/css")
      css = response(conn, 200)

      assert ["text/css" <> _charset] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert css =~ ~S(.mt-\[29px\])
      assert String.ends_with?(css, DraftPreviewLive.ready_css())
    end

    @tag :draft_css
    test "carries the Custom CSS the draft holds", %{site: site, page: page} do
      draft =
        PageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: page.name,
            title: page.title,
            path: page.path,
            template: ~s(<h1 class="pb-1a2b3c4d">Preview</h1>),
            source_page_id: page.id,
            element_css: %{"pb-1a2b3c4d" => "color: crimson;"}
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      on_exit(fn -> DraftPreviewAssets.purge(draft) end)

      {:ok, _view, _html} = live(localhost(), "/_preview/page/#{draft.preview_token}")
      css = localhost() |> get("/_preview/page/#{draft.preview_token}/css") |> response(200)

      # Tailwind writes `crimson` as its hex.
      assert css =~ ".pb-1a2b3c4d{color:#dc143c}"
    end
  end

  describe "the Content-Security-Policy" do
    test "lets in no inline script or inline style element on the preview page", %{page: page} do
      enforced!(csp: :enforce)

      conn = localhost() |> get("/_preview/page/#{page.preview_token}")
      html = html_response(conn, 200)
      policy = policy(conn)
      [nonce_source] = Enum.filter(policy["script-src"], &String.starts_with?(&1, "'nonce-"))
      nonce = nonce_source |> String.trim_leading("'nonce-") |> String.trim_trailing("'")

      for directive <- ["script-src", "style-src-elem"] do
        refute "'unsafe-inline'" in policy[directive], "#{directive} lets in inline code"
        refute "'unsafe-eval'" in policy[directive], "#{directive} lets in eval"
        assert "'self'" in policy[directive]
        assert "'nonce-#{nonce}'" in policy[directive]
      end

      # Every `<style>` is the response's own, and every `<script>` is a file of this origin.
      for [tag] <- Regex.scan(~r/<style[^>]*>/, html),
          do: assert(tag =~ ~s(nonce="#{nonce}"), "an un-nonced <style>: #{tag}")

      for [tag] <- Regex.scan(~r/<script[^>]*>/, html),
          do: assert(tag =~ ~r/src="\//, "an inline <script>: #{tag}")

      refute html =~ ~r/\son(load|error|click)=/i, "an inline event handler"
    end

    test "holds no 'unsafe-inline' at all once style attributes are switched off", %{page: page} do
      enforced!(csp: :enforce, inline_style: :forbid)

      conn = localhost() |> get("/_preview/page/#{page.preview_token}")

      refute conn |> get_resp_header("content-security-policy") |> Enum.join(" ") =~
               "unsafe-inline"

      assert policy(conn)["style-src-attr"] == ["'none'"]
    end

    test "is answered on the stylesheet too, which is served as CSS from this origin", %{
      page: page
    } do
      enforced!(csp: :enforce)
      token = page.preview_token
      {:ok, _view, _html} = live(localhost(), "/_preview/page/#{token}")

      conn = localhost() |> get("/_preview/page/#{token}/css")

      assert ["text/css" <> _charset] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      refute "'unsafe-inline'" in policy(conn)["script-src"]
    end
  end
end
