defmodule MishkaCms.PermissionNamesTest do
  @moduledoc """
  Every permission-looking string literal in `lib/` and in the core, blog and document extensions'
  `lib/` follows the grammar: `*`, `admin:*`, or `admin:<dashboard|api>:<area>[:<sub>]` in lower
  snake_case, with `*` only as the whole last segment. `admin:dashboard` and `admin:api` are the
  prefixes `{:under, prefix}` takes.

  A literal is permission-looking when it is colon-separated words with no space and starts with
  `admin:` or ends in `:*`, or is `page:code:write`. Each word of a `~w` sigil is a literal, each
  piece of an interpolated string is one, and so is each quoted value of a template. The product
  page `/mish-cms` is left out: its demo lists names as copy, and its content stays as written.

  Every name the code asks for is one the install creates, and a list asks only for the leaf names
  it means: a held wildcard already covers every name below it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @root Path.expand("../..", __DIR__)
  @globs [
    "lib/**/*.{ex,exs,heex}",
    "__extensions/{mishka_cms_core,mishka_blog,mishka_document}/lib/**/*.{ex,exs,heex}"
  ]
  @copy ~w(lib/mishka_cms_web/live/mishka_cms_live.ex lib/mishka_cms_web/live/mishka_cms_live.html.heex)

  @looking ~r/^(admin:[a-z0-9_:*]*|[a-z0-9_:]+:\*|page:code:write)$/
  @grammar ~r/^(\*|admin:\*|admin:(dashboard|api)(:[a-z][a-z0-9_]*)*(:\*)?)$/
  @prefixes ~w(admin:dashboard admin:api)

  test "every permission name in the code follows the grammar" do
    wrong =
      for glob <- @globs,
          path <- Path.wildcard(Path.join(@root, glob)),
          file = Path.relative_to(path, @root),
          file not in @copy,
          name <- names(Path.extname(file), File.read!(path)),
          not Regex.match?(@grammar, name),
          uniq: true,
          do: "#{file}: #{inspect(name)}"

    assert wrong == [], "not a permission name:\n" <> Enum.join(wrong, "\n")
  end

  # A NAME THE CODE ASKS FOR IS ONE A SITE CAN GRANT: the core install creates the core's names and
  # installing an extension creates its own, so a name on neither list is held by nobody but `*` and
  # the wildcards above it. `admin:dashboard` and `admin:api` are the prefixes `{:under, prefix}`
  # takes, not names.
  test "every permission name the code asks for is created by the install or an extension's" do
    listed =
      Enum.map(
        MishkaCmsCore.Install.Bootstrap.permissions() ++
          MishkaBlog.Provision.manifest().permissions ++
          MishkaDocument.Provision.manifest().permissions,
        &elem(&1, 0)
      )

    missing =
      for glob <- @globs,
          path <- Path.wildcard(Path.join(@root, glob)),
          file = Path.relative_to(path, @root),
          file not in @copy,
          name <- names(Path.extname(file), File.read!(path)),
          Regex.match?(@grammar, name),
          name not in listed,
          name not in @prefixes,
          uniq: true,
          do: "#{file}: #{inspect(name)}"

    assert missing == [], "not created by the install:\n" <> Enum.join(missing, "\n")
  end

  # A HELD WILDCARD COVERS EVERY NAME BELOW IT (`AccessPermissions.covers?/2`), so a wildcard listed
  # beside a name it covers asks for nothing more.
  test "no list asks for a wildcard beside a name it covers" do
    redundant =
      for glob <- @globs,
          path <- Path.wildcard(Path.join(@root, glob)),
          file = Path.relative_to(path, @root),
          file not in @copy,
          Path.extname(file) != ".heex",
          {wide, narrow} <- redundant(File.read!(path)),
          uniq: true,
          do: "#{file}: #{inspect(wide)} beside #{inspect(narrow)}"

    assert redundant == [], "a wildcard beside a name it covers:\n" <> Enum.join(redundant, "\n")
  end

  test "the scan finds typos, old names and names assembled from pieces" do
    source = ~S'''
    x = ["admin:dashbord:page", "admin:site:*", "media:*", "blog:post:*", "page:code:write"]
    y = ~w(admin:blog:* admin:api:runtime:page)
    z = "admin:dashboard:#{area}" <> ~H(<.x permission={"admin:users:*"} />)
    ok = ["admin:dashboard:runtime:page", "admin:api:*", "admin:*", "*", "blog:post:published", "a b:*"]
    '''

    assert ".ex" |> names(source) |> Enum.reject(&Regex.match?(@grammar, &1)) |> Enum.sort() ==
             Enum.sort([
               "admin:dashbord:page",
               "admin:site:*",
               "media:*",
               "blog:post:*",
               "page:code:write",
               "admin:blog:*",
               "admin:dashboard:",
               "admin:users:*"
             ])

    assert names(".heex", ~s(<.x permission={"admin:dashbord:page"} class="a b" />)) ==
             ["admin:dashbord:page"]
  end

  test "the scan finds a wildcard beside a name it covers, within one list" do
    source = ~S'''
    x = [permissions: ["admin:dashboard:runtime:*", "admin:dashboard:runtime:page", "not a name"]]
    y = ~w(admin:api:* admin:api:code)
    ok = [["admin:dashboard:*"], ["admin:dashboard:runtime:page", "admin:api:runtime:page"]]
    '''

    assert source |> redundant() |> Enum.sort() == [
             {"admin:api:*", "admin:api:code"},
             {"admin:dashboard:runtime:*", "admin:dashboard:runtime:page"}
           ]
  end

  defp names(extname, source), do: extname |> literals(source) |> Enum.filter(&looking?/1)

  defp looking?(text), do: Regex.match?(@looking, text)

  defp redundant(source) do
    for list <- lists(source),
        wide <- list,
        narrow <- list,
        wide != narrow and AccessPermissions.covers?(wide, narrow),
        do: {wide, narrow}
  end

  defp lists(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:sigil_w, _meta, [{:<<>>, _, [words]}, _mods]} = node, found when is_binary(words) ->
          {node, [Enum.filter(String.split(words), &looking?/1) | found]}

        list, found when is_list(list) ->
          {list, [Enum.filter(list, &(is_binary(&1) and looking?(&1))) | found]}

        node, found ->
          {node, found}
      end)

    found
  end

  defp literals(".heex", source),
    do: ~r/"([^"\s]*)"/ |> Regex.scan(source, capture: :all_but_first) |> List.flatten()

  defp literals(_elixir, source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:sigil_w, _meta, [{:<<>>, _, [words]}, _mods]}, found when is_binary(words) ->
          {nil, String.split(words) ++ found}

        {:sigil_H, _meta, [{:<<>>, _, [template]}, _mods]}, found when is_binary(template) ->
          {nil, literals(".heex", template) ++ found}

        text, found when is_binary(text) ->
          {text, [text | found]}

        node, found ->
          {node, found}
      end)

    found
  end
end
