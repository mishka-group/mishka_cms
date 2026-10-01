defmodule MishkaCms.LanguageFieldHintTest do
  @moduledoc """
  Every form that asks an author for a language says where the language has to be declared.

  A row's `language` and the site's `site.languages` are two different settings, and only the second
  one decides whether a URL answers: `MishkaCmsCore.Runtime.Languages.admits?/3` holds a path's
  `:lang` capture to that list. So a post written in Arabic on a site publishing English and Persian
  is a correct, published row that no reader can reach — `/ar/blog/<slug>` is a 404, and nothing in
  the form said so. The chip row on the post now draws such an edition as a word rather than a dead
  link, which is honest but silent about the fix.

  This lives here rather than in each extension because the rule is one rule across all of them, and
  only this project has every extension compiled at once.
  """
  use ExUnit.Case, async: true

  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  # Every resource whose form asks for a language. A new one is added here when it is written; the
  # test below is what makes forgetting visible.
  @resources [
    MishkaBlog.BlogPost,
    MishkaBlog.Collection,
    MishkaBlog.Tag,
    MishkaCmsCore.Runtime.Page,
    MishkaCmsCore.Runtime.Translation,
    MishkaDocument.Section,
    MishkaDocument.SectionDraft,
    MishkaDocument.Tag,
    MishkaDocument.Workspace
  ]

  test "a language field points the author at the site setting that makes it reachable" do
    for resource <- @resources do
      field = FormInfo.field(resource, :language)

      assert field, "#{inspect(resource)} has no :language form field"

      help = resolved(field)

      assert help =~ "Settings",
             "#{inspect(resource)}'s language field says nothing about the site setting: " <>
               inspect(help)

      assert help =~ "404",
             "#{inspect(resource)}'s language field does not say what happens without it: " <>
               inspect(help)
    end
  end

  # THE RESOURCES ARE FOUND, NOT LISTED, so a ninth one written next month fails this rather than
  # slipping through: the list above is the claim, and this is the check on it.
  test "and no other resource asks for a language without one" do
    asking =
      for {app, _desc, _vsn} <- Application.loaded_applications(),
          String.starts_with?(to_string(app), "mishka_"),
          {:ok, modules} = :application.get_key(app, :modules),
          module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :spark_dsl_config, 0),
          field = safe_field(module),
          field != nil,
          do: module

    assert Enum.sort(asking) == Enum.sort(@resources)
  end

  defp safe_field(module) do
    FormInfo.field(module, :language)
  rescue
    _not_a_form_resource -> nil
  end

  # `label`, `placeholder` and `description` all take a string or a zero-arity function, so that a
  # translated form does not leave its help text in English.
  defp resolved(field) do
    case field.ui && field.ui.description do
      text when is_binary(text) -> text
      fun when is_function(fun, 0) -> fun.()
      nil -> ""
    end
  end
end
