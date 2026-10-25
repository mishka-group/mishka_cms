# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.UiKitCatalogTest do
  @moduledoc """
  Pure tests against the REAL `chelekom.json` (136 components) — the dependency-closure /
  required-lock logic that the picker is built on. No DB, no mocks; loads the actual bundle once,
  from the copy in this project's `test/fixtures/cms_ui_kits/` (nothing ships one: a server
  downloads it).
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Install.UiKitCatalog

  @chelekom Path.expand("../../fixtures/cms_ui_kits/chelekom.json", __DIR__)

  setup_all do
    bundle = @chelekom |> File.read!() |> Jason.decode!()
    {:ok, bundle: bundle, catalog: UiKitCatalog.build(bundle)}
  end

  test "the bundle is a parsed v3 map", %{bundle: bundle} do
    assert bundle["$schema"] == "mishka.ui_kit.bundle.v3"
    assert length(bundle["components"]) == 136
  end

  test "groups all 136 components into the six type groups with the real counts", %{
    catalog: catalog
  } do
    counts = Map.new(catalog.groups, &{&1.key, length(&1.entries)})

    assert counts == %{
             "general" => 76,
             "forms" => 28,
             "navigations" => 14,
             "media" => 7,
             "feedback" => 6,
             "overlays" => 5
           }

    assert map_size(catalog.index) == 136

    assert Enum.map(catalog.groups, & &1.key) ==
             ~w(general forms navigations media feedback overlays)
  end

  test "labels strip the chelekom- prefix", %{catalog: catalog} do
    assert UiKitCatalog.label("chelekom-card") == "card"
    assert catalog.index["chelekom-card"].label == "card"
  end

  describe "required_closure/2" do
    test "picking card pulls in icon (and locks it)", %{catalog: catalog} do
      required = UiKitCatalog.required_closure(catalog, ["chelekom-card"])
      assert MapSet.member?(required, "chelekom-icon")
    end

    test "an explicitly-picked dependency is NOT locked (the user owns it)", %{catalog: catalog} do
      required = UiKitCatalog.required_closure(catalog, ["chelekom-card", "chelekom-icon"])
      refute MapSet.member?(required, "chelekom-icon")
    end

    test "normalizes the chelekom-scroll_area (underscore) dependency to the real component", %{
      catalog: catalog
    } do
      # chelekom-tabs depends on the underscore form; the closure must resolve the hyphen component.
      required = UiKitCatalog.required_closure(catalog, ["chelekom-tabs"])
      assert MapSet.member?(required, "chelekom-scroll-area")
    end

    test "never includes .js hook deps and only contains real component names", %{
      catalog: catalog
    } do
      required = UiKitCatalog.required_closure(catalog, Map.keys(catalog.index))
      refute Enum.any?(required, &String.ends_with?(&1, ".js"))
      assert Enum.all?(required, &MapSet.member?(catalog.names, &1))
    end
  end

  test "icon is depended on by 80 components, and selecting them all forces icon into required",
       %{catalog: catalog} do
    icon_dependents =
      catalog.index
      |> Map.values()
      |> Enum.filter(&("chelekom-icon" in &1.deps))
      |> Enum.map(& &1.name)

    assert length(icon_dependents) == 80

    required = UiKitCatalog.required_closure(catalog, icon_dependents)
    assert MapSet.member?(required, "chelekom-icon")
  end

  test "install_set/2 is the union of picks and their required closure", %{catalog: catalog} do
    set = UiKitCatalog.install_set(catalog, ["chelekom-card"])
    assert MapSet.member?(set, "chelekom-card")
    assert MapSet.member?(set, "chelekom-icon")
  end

  test "required_by/3 names the picks that force a dependency", %{catalog: catalog} do
    assert "card" in UiKitCatalog.required_by(catalog, ["chelekom-card"], "chelekom-icon")
  end

  test "build/1 records the narrowable variant/color axes per component", %{catalog: catalog} do
    button = catalog.index["chelekom-button"]

    assert %{values: variant_values, default: variant_default} = button.config["variant"]
    assert %{values: color_values, default: color_default} = button.config["color"]
    assert variant_default in variant_values
    assert color_default in color_values
    assert length(color_values) > 1
  end

  describe "install_selection/3" do
    test "narrows every installed component to its own default variant/color", %{catalog: catalog} do
      sel = UiKitCatalog.install_selection(catalog, ["chelekom-button"])

      # The picks + their dependency closure are the install list.
      assert "chelekom-button" in sel.components
      assert "chelekom-icon" in sel.components

      # button installs at its default variant/color only (minimal). Axes are keyed by name.
      %{default: variant_default} = catalog.index["chelekom-button"].config["variant"]
      %{default: color_default} = catalog.index["chelekom-button"].config["color"]
      assert sel.per_component["button"]["variant"] == [variant_default]
      assert sel.per_component["button"]["color"] == [color_default]
    end

    test "an extra value widens that component's axis beyond the default", %{catalog: catalog} do
      extras = %{"chelekom-button" => %{"color" => MapSet.new(["danger"])}}
      sel = UiKitCatalog.install_selection(catalog, ["chelekom-button"], extras)

      %{default: color_default} = catalog.index["chelekom-button"].config["color"]
      assert color_default in sel.per_component["button"]["color"]
      assert "danger" in sel.per_component["button"]["color"]
      # variant is untouched → still default-only.
      assert sel.per_component["button"]["variant"] == [
               catalog.index["chelekom-button"].config["variant"].default
             ]
    end
  end
end
