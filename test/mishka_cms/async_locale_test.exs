defmodule MishkaCms.AsyncLocaleTest do
  @moduledoc """
  Work a page hands to another process runs in the page's Gettext locale.

  A process started by `Phoenix.LiveView.start_async/3` or `assign_async/3` has no locale of its
  own, so a refusal, an account's name or a language's name it builds reads in the default locale
  whatever language the admin reads the page in. `MishkaGervaz.Messages.start_async/4` and
  `assign_async/4` carry the page's locales into it. This fails on a call to Phoenix's own, in the
  core, the blog, the document extension or this project. It lives here because only this project
  has every extension at hand.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @sources [
    "lib",
    "__extensions/mishka_cms_core/lib",
    "__extensions/mishka_blog/lib",
    "__extensions/mishka_document/lib"
  ]

  @phoenix [:start_async, :assign_async]

  test "no page starts async work through Phoenix's own start_async or assign_async" do
    calls =
      for source <- @sources,
          file <- Path.wildcard(Path.join([@root, source, "**/*.ex"])),
          line <- phoenix_calls(Code.string_to_quoted!(File.read!(file))),
          do: "#{Path.relative_to(file, @root)}:#{line}"

    assert calls == [],
           "use MishkaGervaz.Messages.start_async/4 or assign_async/4 instead:\n" <>
             Enum.join(calls, "\n")
  end

  defp phoenix_calls(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {name, meta, args} = node, lines when name in @phoenix and is_list(args) ->
          {node, [meta[:line] | lines]}

        {{:., meta, [{:__aliases__, _, [:Phoenix, :LiveView]}, name]}, _, _} = node, lines
        when name in @phoenix ->
          {node, [meta[:line] | lines]}

        node, lines ->
          {node, lines}
      end)

    Enum.reverse(lines)
  end
end
