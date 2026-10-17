# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.ContentEditorEngineTest do
  @moduledoc """
  The admin's content editor runs Mishka Chelekom's headless `editor` engine, the one the core's
  `chelekom_headless` kit installs on a site as the global JS hook `chelekom-headless-editor`. The
  admin cannot load a site's bundle, so `assets/vendor/editor.js` is a copy of that hook's
  `content`, and `assets/package.json` installs exactly the packages the hook lists.

  These fail the day the kit moves and the copy does not. To refresh it: write the hook's `content`
  from `mishka_cms_core/priv/cms_ui_kits/chelekom_headless.json` into `assets/vendor/editor.js`
  unchanged, set `assets/package.json`'s `overrides` to the hook's `npm` list (and its `@tiptap/*`
  dependencies to the same versions), run `bun install` in `assets/`, and rebuild with
  `mix esbuild mishka_cms`.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../../assets", __DIR__)
  @refresh "Refresh the copy as this module's doc says: the kit's `chelekom-headless-editor` hook " <>
             "is the source of truth for the engine and its packages."

  defp hook do
    :mishka_cms_core
    |> :code.priv_dir()
    |> Path.join("cms_ui_kits/chelekom_headless.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("js_hooks")
    |> Enum.find(&(&1["name"] == "chelekom-headless-editor"))
  end

  defp package, do: @assets |> Path.join("package.json") |> File.read!() |> Jason.decode!()

  defp lock, do: @assets |> Path.join("bun.lock") |> File.read!()

  test "the kit still ships the engine as the hook every editor mounts" do
    assert %{"content" => content, "extra" => %{"module" => "Editor"}} = hook()
    assert content =~ "import userConfig from \"./editor_extensions.js\""
  end

  test "the vendored engine is the kit's, byte for byte" do
    vendored = @assets |> Path.join("vendor/editor.js") |> File.read!()

    assert vendored == hook()["content"],
           "assets/vendor/editor.js differs from the kit. " <> @refresh
  end

  test "every package the kit's engine needs is pinned to the version the kit lists" do
    %{"overrides" => overrides, "dependencies" => dependencies} = package()

    for %{"name" => name, "version" => version} <- hook()["npm"] do
      assert overrides[name] == version,
             "package.json pins #{name} to #{inspect(overrides[name])}, the kit to #{version}. " <>
               @refresh

      assert dependencies[name] in [nil, version],
             "package.json depends on #{name} #{dependencies[name]}, the kit lists #{version}. " <>
               @refresh
    end
  end

  test "and the lockfile installed exactly those, with the kit's integrity" do
    lock = lock()

    for %{"name" => name, "version" => version, "integrity" => integrity} <- hook()["npm"] do
      entry =
        ~r/"#{Regex.escape(name)}": \["#{Regex.escape(name)}@([^"]+)", "[^"]*", (?:\{.*?\}, )?"(sha512-[^"]+)"\]/

      assert [_whole, ^version, ^integrity] = Regex.run(entry, lock),
             "bun.lock does not hold #{name}@#{version} with the kit's integrity. " <> @refresh
    end
  end
end
