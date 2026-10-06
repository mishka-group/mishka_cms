defmodule MishkaCms.RecordLabelsGettextTest do
  @moduledoc """
  Every record a refusal names by its `:label` — "That layout is not one this site can use." — can
  be translated.

  `SameSiteReference`, `SameWorkspaceVersion` and the blog's `RestoreVersion` put their `:label` into
  a sentence through the `errors` Gettext domain of `MishkaCmsCore.Gettext`. A label is an option on
  a resource, not a string Gettext can extract, so each one is written into
  `__extensions/mishka_cms_core/priv/gettext/errors.pot` by hand. This finds every label the host's
  resources declare, in every extension, so one added later and not written there fails here.

  This lives here rather than in each extension because only this project has every extension
  compiled at once.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

  @labelled [
    SameSiteReference,
    MishkaDocument.Resources.Validations.SameWorkspaceVersion,
    MishkaBlog.Resources.Changes.RestoreVersion
  ]

  @pot Path.expand("../../__extensions/mishka_cms_core/priv/gettext/errors.pot", __DIR__)

  test "every label a refusal names is a msgid of the core's errors domain" do
    msgids =
      @pot
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> MapSet.new(&IO.iodata_to_binary(&1.msgid))

    labels = declared_labels()

    assert "layout" in labels
    assert "section" in labels
    assert "blogger profile" in labels

    missing = Enum.reject(labels, &MapSet.member?(msgids, &1))

    assert missing == [],
           "labels missing from #{Path.relative_to_cwd(@pot)}: #{inspect(missing)}"
  end

  defp declared_labels do
    MishkaCmsCore.Activity.Discovery.resources()
    |> Enum.flat_map(&declared/1)
    |> Enum.flat_map(fn
      {module, opts} when module in @labelled -> List.wrap(opts[:label])
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp declared(resource) do
    entities =
      Ash.Resource.Info.validations(resource) ++
        Ash.Resource.Info.changes(resource) ++
        Enum.flat_map(Ash.Resource.Info.actions(resource), &Map.get(&1, :changes, []))

    for entity <- entities, pair <- module_opts(entity), do: pair
  end

  defp module_opts(%Ash.Resource.Validation{validation: {module, opts}}), do: [{module, opts}]
  defp module_opts(%Ash.Resource.Change{change: {module, opts}}), do: [{module, opts}]
  defp module_opts(_entity), do: []
end
