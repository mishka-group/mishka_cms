defmodule MishkaCms.FormPictureFieldsTest do
  @moduledoc """
  Every picture a core, blog or document form asks for is filled from the site's media library.

  A field whose name says it holds a picture — `featured_image_url`, `avatar_url`,
  `cover_image_url`, a logo, a banner… — carries `ui do extra %{media: :images} end`, which
  `MishkaCmsCoreWeb.UIAdapters.Admin` draws as the picture field: an upload, a pick from the library,
  or a typed address. So every form holding one is drawn by that adapter; on another the field is a
  plain address again.
  """
  use ExUnit.Case, async: true

  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  @apps [:mishka_cms_core, :mishka_blog, :mishka_document]
  @picture ~r/(^|_)(image|avatar|cover|logo|thumbnail|banner|photo|picture)(_url)?$/

  defp forms do
    for app <- @apps,
        {:ok, modules} = :application.get_key(app, :modules),
        module <- modules,
        Ash.Resource.Info.resource?(module),
        FormInfo.fields(module) != [],
        do: module
  end

  defp media(field), do: get_in(field, [:ui, :extra, :media])

  test "every picture field is filled from the media library" do
    pictures =
      for resource <- forms(),
          field <- FormInfo.fields(resource),
          field.type == :text,
          Regex.match?(@picture, to_string(field.name)),
          do: {resource, field}

    assert pictures != []

    plain = for {resource, field} <- pictures, media(field) == nil, do: {resource, field.name}

    assert plain == [],
           "these picture fields are a plain address, not one from the media library: " <>
             inspect(plain)
  end

  test "every form with a picture field is drawn by the adapter that draws it" do
    adapters =
      for resource <- forms(),
          Enum.any?(FormInfo.fields(resource), &media/1),
          do: {resource, FormInfo.config(resource).presentation.ui_adapter}

    assert adapters != []

    other =
      for {resource, adapter} <- adapters,
          adapter != MishkaCmsCoreWeb.UIAdapters.Admin,
          do: {resource, adapter}

    assert other == [],
           "these forms draw their picture fields as plain addresses: " <> inspect(other)
  end
end
