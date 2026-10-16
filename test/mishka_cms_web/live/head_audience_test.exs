# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.HeadAudienceTest do
  @moduledoc """
  Which pages may share a document, pinned.

  `root.html.heex` builds `<head>` from the LiveView's own assigns, and it renders once per HTTP
  response. A live navigation produces none: the destination runs inside the document the SOURCE
  built, wearing the source's head. For the admin that is almost always fine, because
  `MishkaCmsCore.Layouts.Nav` switches the same four assigns on for every admin page — one head for
  all of them, whichever one you loaded.

  The page builder is the exception. It is the only admin page that asks for something more: the
  in-browser Tailwind JIT, and above it the shim that stamps the CSP nonce on every `<style>` that
  JIT and CodeMirror create. Reached by `<.link navigate={…}>` from a list page it ran inside the
  LIST's document and got neither, so CodeMirror's stylesheet was refused by `style-src-elem` and
  the code drawer opened onto an unstyled column of text. Nothing raised; a reload fixed it, because
  a reload is a dead render.

  A `live_session` boundary is what settles it: LiveView will not live-navigate across one, so
  arriving is a full page load and so is leaving. The rule this pins is therefore not "the builder
  is special" but the general one — **a page whose head differs from its neighbours' may not share a
  `live_session` with them** — and it is derived from the source rather than listed here, so a new
  LiveView that reaches for the JIT and is routed beside the dashboard fails this test instead of
  losing its styles in a browser nobody is watching.
  """
  use ExUnit.Case, async: true

  # The assign that makes a page's head different from the rest of the admin's. `admin_css`,
  # `admin_fonts`, `code_editor` and `standalone_assets` are not in this list on purpose: `Nav` sets
  # all four for every admin LiveView, so no navigation can arrive without them.
  @head_assign ":live_tailwind"

  # Each project's `lib` only, never an extension's `_build` or `deps`.
  @roots ["lib", "__extensions/*/lib"]

  describe "a live_session is a group of pages that share a head" do
    test "every LiveView that asks for the JIT is routed away from the ones that do not" do
      jit = jit_modules()

      assert jit != [], """
      No module assigns #{@head_assign} any more. If the JIT is gone, delete this test and the
      `:admin_standalone` route list with it; if it was renamed, rename @head_assign.
      """

      sessions = sessions_by_module()

      for module <- jit, session <- Map.get(sessions, module, []) do
        housemates =
          Enum.filter(sessions, fn {_m, s} -> session in s end) |> Enum.map(&elem(&1, 0))

        assert Enum.all?(housemates, &(&1 in jit)), """
        #{inspect(module)} asks for the in-browser Tailwind JIT, so its head is not the admin's
        usual head — but it is routed in live_session #{inspect(session)} alongside pages that do
        not ask for it:

            #{housemates |> Enum.reject(&(&1 in jit)) |> Enum.map_join("\n    ", &inspect/1)}

        LiveView live-navigates freely inside one live_session and never re-renders the root layout,
        so arriving from one of those pages would hand this one their head. Route it through
        `routes(:admin_standalone)` instead — see `MishkaCmsCore.ExtensionRouter`.
        """
      end
    end

    test "and the builder is on the far side of that boundary" do
      sessions = sessions_by_module()

      builder = sessions[MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive]
      canvas = sessions[MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive]
      listing = sessions[MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Page.Index]

      assert builder != nil and canvas != nil and listing != nil

      assert builder == canvas,
             "the chrome and its canvas share a head and should share a session"

      refute Enum.any?(builder, &(&1 in listing)),
             "the builder must not share a live_session with the page list it is opened from"
    end
  end

  # Every module whose source assigns the JIT, found rather than listed.
  defp jit_modules do
    @roots
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    |> Enum.filter(&(File.read!(&1) =~ ~r/assign\(\s*#{@head_assign}\s*,\s*true/))
    |> Enum.map(&module_of/1)
    |> Enum.reject(&is_nil/1)
  end

  defp module_of(path) do
    case Regex.run(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m, File.read!(path)) do
      [_, name] -> Module.concat([name])
      _nothing -> nil
    end
  end

  defp sessions_by_module do
    MishkaCmsWeb.Router.__routes__()
    |> Enum.flat_map(fn route ->
      case route.metadata[:phoenix_live_view] do
        {view, _action, _opts, %{name: session}} -> [{view, session}]
        _not_a_live_route -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {view, sessions} -> {view, Enum.uniq(sessions)} end)
  end
end
