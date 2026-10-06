defmodule MishkaCms.RefusalMessagesTest do
  @moduledoc """
  The fixed messages the core, the blog and the document extension refuse an action with.

  A refusal is a message an action stores on an error: the `message` of a `validate`, an
  `identity` or a `check_constraint`, a `:message` inside an `{:error, …}` a validation returns or
  an error's `exception/1` builds, and a sentence a validation returns or `add_error/2` adds.
  MishkaGervaz shows one as written when it ends a sentence and after its field's name otherwise,
  and translates it in the `errors` Gettext domain of `MishkaCmsCore.Gettext`.

  - A refusal that starts with a capital letter is a sentence, so it ends with sentence-ending
    punctuation. Without it an admin reads "Parent Section Section cannot be its own parent".
  - A sentence refusal is written out, not built with `"\#{…}"`, so a translation can match it: one
    sentence for each case, or a `%{key}` placeholder the error's `vars` fill.
  - A refusal the core writes as a fixed text is a msgid of
    `__extensions/mishka_cms_core/priv/gettext/errors.pot`, so a translator is given it.

  The sources are read, not the compiled resources: most refusals are inside anonymous functions
  and validation modules no introspection reaches. This lives here because only this project has
  every extension at hand.
  """
  use ExUnit.Case, async: true

  @extensions Path.expand("../../__extensions", __DIR__)
  @pot Path.join(@extensions, "mishka_cms_core/priv/gettext/errors.pot")

  @contexts [
    :validate,
    :atomic,
    :exception,
    :add_error,
    :identity,
    :check_constraint,
    :error_tuple
  ]
  @validation_contexts [:validate, :atomic, :add_error]
  @gettext [:dgettext, :dgettext_noop, :dngettext, :dngettext_noop, :dpgettext, :dpgettext_noop]
  @sentence_end ~r/[.!?…؟][\s"'”’»)\]]*\z/u

  test "a refusal that starts with a capital letter ends a sentence" do
    missing =
      for extension <- ["mishka_cms_core", "mishka_blog", "mishka_document"],
          {file, line, text} <- refusals(extension),
          capitalized?(opening(text)),
          not Regex.match?(@sentence_end, ending(text)),
          uniq: true,
          do: "#{file}:#{line} #{inspect(text)}"

    assert missing == [], "refusals written as a sentence with no full stop:\n" <> list(missing)
  end

  test "a sentence refusal is not built with interpolation" do
    built =
      for extension <- ["mishka_cms_core", "mishka_blog", "mishka_document"],
          {file, line, {:interpolated, _first, _last} = text} <- refusals(extension),
          capitalized?(opening(text)),
          uniq: true,
          do: "#{file}:#{line}"

    assert built == [], "sentence refusals built with \"\#{…}\":\n" <> list(built)
  end

  test "every refusal the core writes is a msgid of its errors domain" do
    msgids =
      @pot
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> MapSet.new(&IO.iodata_to_binary(&1.msgid))

    missing =
      for {file, line, text} <- refusals("mishka_cms_core"),
          is_binary(text) and not MapSet.member?(msgids, text),
          uniq: true,
          do: "#{file}:#{line} #{inspect(text)}"

    assert missing == [],
           "refusals missing from #{Path.relative_to_cwd(@pot)}; wrap each in " <>
             "dgettext_noop(\"errors\", …) and run mix gettext.extract --merge:\n" <>
             list(missing)
  end

  defp list(lines), do: Enum.map_join(lines, "\n", &("  " <> &1))

  defp opening({:interpolated, first, _last}), do: first
  defp opening(text), do: text

  defp ending({:interpolated, _first, last}), do: last
  defp ending(text), do: text

  defp capitalized?(text) do
    case String.first(text) do
      nil -> false
      first -> first != String.downcase(first)
    end
  end

  defp refusals(extension) do
    root = Path.join(@extensions, extension)

    for file <- Path.wildcard(Path.join(root, "lib/**/*.ex")),
        source = File.read!(file),
        value <- source |> Code.string_to_quoted!() |> collect() |> Enum.reverse(),
        text <- texts(value) do
      {Path.relative_to(file, @extensions), line_of(source, text), text}
    end
  end

  defp line_of(source, {:interpolated, "", last}), do: line_of(source, last)
  defp line_of(source, {:interpolated, first, _last}), do: line_of(source, first)
  defp line_of(_source, ""), do: "?"

  defp line_of(source, text) do
    case :binary.match(source, text) do
      {at, _length} -> source |> binary_part(0, at) |> String.split("\n") |> length()
      :nomatch -> "?"
    end
  end

  defp texts(text) when is_binary(text), do: [text]
  defp texts({name, _meta, [_domain, msgid | _]}) when name in @gettext, do: texts(msgid)

  defp texts({:<<>>, _meta, parts}) do
    [{:interpolated, literal(List.first(parts)), literal(List.last(parts))}]
  end

  defp texts(_expression), do: []

  defp literal(part) when is_binary(part), do: part
  defp literal(_expression), do: ""

  defp collect(ast) do
    {_ast, {_stack, found}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)
    found
  end

  defp enter(node, {stack, found}) do
    found = found(node, stack) ++ found
    {node, {push(node, stack), found}}
  end

  defp leave(node, {stack, found}) do
    case context(node) do
      nil -> {node, {stack, found}}
      _context -> {node, {tl(stack), found}}
    end
  end

  defp push(node, stack) do
    case context(node) do
      nil -> stack
      context -> [context | stack]
    end
  end

  defp context({kind, _meta, [{name, _, _} | _]}) when kind in [:def, :defp] and is_atom(name),
    do: name

  defp context({:error, value}) when is_list(value), do: :error_tuple
  defp context({{:., _, [_module, name]}, _meta, args}) when is_list(args), do: name
  defp context({name, _meta, args}) when is_atom(name) and is_list(args), do: name
  defp context(_node), do: nil

  defp found({:message, value}, stack) do
    if Enum.any?(stack, &(&1 in @contexts)), do: [value], else: []
  end

  defp found({:message, _meta, [value]}, stack) do
    if :validate in stack, do: [value], else: []
  end

  defp found({:error, value}, stack) when is_binary(value) do
    if Enum.any?(stack, &(&1 in @validation_contexts)), do: [value], else: []
  end

  defp found({:add_error, _meta, [_changeset, value]}, _stack) when is_binary(value),
    do: [value]

  defp found({{:., _meta, [_module, :add_error]}, _, [_changeset, value]}, _stack)
       when is_binary(value),
       do: [value]

  defp found(_node, _stack), do: []
end
