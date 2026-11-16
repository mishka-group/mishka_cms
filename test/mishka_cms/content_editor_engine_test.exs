# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.ContentEditorEngineTest do
  @moduledoc """
  The admin's content editor runs Mishka Chelekom's headless `editor` engine, the one the core's
  `chelekom_headless` kit installs on a site as the global JS hook `chelekom-headless-editor`. The
  admin cannot load a site's bundle, so `assets/vendor/editor.js` is a copy of that hook's
  `content`, and `assets/package.json` installs every package the hook lists.

  The kit is read from `test/fixtures/chelekom_headless.json`, a copy of Chelekom's release file.
  Nothing ships the bundle (a server downloads it), so the one in a mishka_cms_core checkout's
  `priv/cms_ui_kits/` is not in the Hex package, and CI has no checkout to read it from.

  TipTap is not held at the kit's version: Dependabot moves every `@tiptap/*` package together in
  one group, and these tests only ask that all of them resolve to one version, since two TipTap
  versions in one bundle load two editor cores that do not know each other.

  These fail the day the kit moves and the vendored copy does not. To refresh it: put the new
  `chelekom_headless.json` over `test/fixtures/chelekom_headless.json`, write the hook's `content`
  into `assets/vendor/editor.js` unchanged, add any package the hook's `npm` list names that
  `assets/bun.lock` lacks, run `bun install` in `assets/`, and rebuild with `mix esbuild mishka_cms`.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../../assets", __DIR__)
  @kit Path.expand("../fixtures/chelekom_headless.json", __DIR__)
  @refresh "Refresh the copy as this module's doc says: the kit's `chelekom-headless-editor` hook " <>
             "is the source of truth for the engine and its packages."
  @locked ~r/^\s*"(@tiptap\/[^"]+)": \["@tiptap\/[^@"]+@([^"]+)"/m

  defp hook do
    @kit
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("js_hooks")
    |> Enum.find(&(&1["name"] == "chelekom-headless-editor"))
  end

  defp package, do: @assets |> Path.join("package.json") |> File.read!() |> Jason.decode!()

  defp lock, do: @assets |> Path.join("bun.lock") |> File.read!()

  defp locked_tiptap,
    do: @locked |> Regex.scan(lock()) |> Map.new(fn [_, name, v] -> {name, v} end)

  test "the kit still ships the engine as the hook every editor mounts" do
    assert %{"content" => content, "extra" => %{"module" => "Editor"}} = hook()
    assert content =~ "import userConfig from \"./editor_extensions.js\""
  end

  test "the vendored engine is the kit's, byte for byte" do
    vendored = @assets |> Path.join("vendor/editor.js") |> File.read!()

    assert vendored == hook()["content"],
           "assets/vendor/editor.js differs from the kit. " <> @refresh
  end

  test "every package the kit's engine needs is installed" do
    lock = lock()

    for %{"name" => name} <- hook()["npm"] do
      assert lock =~ ~s("#{name}": ["#{name}@),
             "bun.lock does not install #{name}, which the kit's engine needs. " <> @refresh
    end
  end

  test "every TipTap package resolves to one version, the one package.json asks for" do
    locked = locked_tiptap()

    assert [version] = locked |> Map.values() |> Enum.uniq(),
           "bun.lock holds more than one TipTap version: #{inspect(locked)}. Move every " <>
             "@tiptap/* package in assets/package.json to one version and run `bun install`."

    for {name, wanted} <- package()["dependencies"], String.starts_with?(name, "@tiptap/") do
      assert wanted == version,
             "package.json asks for #{name} #{wanted}, bun.lock holds TipTap #{version}. " <>
               "Pin every @tiptap/* package to one exact version."
    end
  end
end
