# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.FormGroupSpansTest do
  @moduledoc """
  No form of the core, blog or document extension draws a group's fields side by side when the
  group asks for fewer columns.

  A group's fields sit in a CSS grid of its `columns`. A field with a wider `span` makes the grid
  add the columns it is missing, and every field that does not span them is then packed into those
  columns beside its neighbours — the post form's Content, a full editor, was drawn in a third of
  the form beside Subtitle because Featured Image URL said `span 2` in a one-column group. So in
  every group either no field spans more than its columns, or every field spans the same.
  """
  use ExUnit.Case, async: true

  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  @apps [:mishka_cms_core, :mishka_blog, :mishka_document]

  defp forms do
    for app <- @apps,
        {:ok, modules} = :application.get_key(app, :modules),
        module <- modules,
        Ash.Resource.Info.resource?(module),
        FormInfo.fields(module) != [],
        do: module
  end

  defp span(field) do
    case get_in(field, [:ui, :span]) do
      span when is_integer(span) and span > 0 -> span
      _none -> 1
    end
  end

  test "every form group lays its fields out in the columns it asks for" do
    forms = forms()
    assert forms != []

    packed =
      for resource <- forms,
          fields = Map.new(FormInfo.fields(resource), &{&1.name, &1}),
          group <- FormInfo.groups(resource),
          columns = get_in(group, [:ui, :columns]) || 1,
          spans = for(name <- group.fields || [], field = fields[name], do: {name, span(field)}),
          widest = spans |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end),
          widest > columns,
          beside = for({name, span} <- spans, span < widest, do: name),
          beside != [],
          do: {resource, group.name, beside}

    assert packed == [],
           "these fields are packed beside each other by a wider field in their group: " <>
             inspect(packed)
  end
end
