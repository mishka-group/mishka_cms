defmodule MishkaCmsWeb.InterpolatedClassTest do
  @moduledoc """
  No Tailwind class may be assembled by interpolation, anywhere the build-time scanner has to find it.

  Tailwind reads SOURCE TEXT. `"grid-cols-[repeat(auto-fill,minmax(min(100%,\#{width}),1fr))]"` is a
  string with a hole in it, so no rule is generated for any width the hole can take — the utility
  simply never applies. Nothing raises, nothing logs, and the page renders with one property quietly
  missing. Both grid instances found this way collapsed a card layout to a single column, and one of
  them also emitted a junk rule whose selector contained the literal text `\#{floor`.

  The class of bug was invisible until recently because the admin and the marketing pages were styled
  by the in-browser Tailwind JIT, which reads classes off the rendered DOM and cannot tell how they
  were built. They are served compiled stylesheets now (`mix admin_css`), so the rule is real, and
  this test is the only thing that will catch the next one — a suite that asserts on markup never
  will, because the markup is correct. It is the CSS that is missing.

  ## What is examined

  Strings that REACH a class attribute. Two seeds, then the calls are followed to a fixed point:

    * the `class=` / `class:` value itself, and every local function it calls;
    * every function whose name ends in `_class` or `_classes`, the convention this codebase already
      uses for one — `grid_classes/1`, `col_span_class/1`, `track_class/1`, `gallery_classes/1`.

  Both seeds are needed. Looking only at the attribute missed the very bug that prompted this test:
  the attribute said `class={grid_classes(@static)}`, `grid_classes/1` called `track_class/1`, and
  the interpolation was in there — two hops down. The name seed additionally reaches a builder whose
  only caller is in ANOTHER module, which a single-file walk can never follow.

  Going the other way — scanning every string literal in the tree — also finds them, and was tried.
  It cannot be kept: a kebab-case DOM id is shape-identical to a utility (an activity key
  `pt-<source>-<action>` against the padding `pt-<n>`), so it reported an endless tail of ids, slugs
  and PubSub topics that had to be silenced with a growing allowlist. Following what actually reaches
  a class needs no vocabulary and no allowlist, because an id-building helper is never called from a
  class attribute and is never named `*_class`.

  A token that is ENTIRELY an interpolation is fine: `class={"\#{@extra}"}` passes a whole class name
  through, and whatever it holds was written as a literal somewhere the scanner can reach.

  ## When a class genuinely cannot be a literal

  It usually can — pattern-matched function clauses returning whole class strings, one per case,
  which is how the grid instances were fixed. When the value set is genuinely open (an icon named by
  a database row), declare the possibilities with `@source inline(...)` in `Mix.Tasks.AdminCss` and
  list the file in `@allowed` below with the reason. The second test keeps that list honest.

  See `MishkaCmsWeb.CssAudienceTest` for which sheet each surface gets.
  """
  use ExUnit.Case, async: true

  # Everything whose classes end up in `admin.css` or `public.css`. A site's OWN templates live in
  # the database and are compiled per site at runtime, so they are not scanned here. Each project's
  # `lib` only: walking an extension's `_build` and `deps` read hundreds of megabytes to discard them.
  @roots ["lib", "__extensions/*/lib"]

  # path => why interpolation is allowed there. Every entry needs a matching `@source inline(...)`
  # in `Mix.Tasks.AdminCss`, and the second test fails if the file stops interpolating.
  @allowed %{}

  # Files whose class strings become a DATABASE TEMPLATE rather than rendered markup. The
  # interpolation runs in Elixir when the row is written, so what lands in the database is already a
  # literal, and it is `MishkaCmsCore.Runtime.Compilers.TailwindCompiler` — scanning those stored
  # templates per site — that has to find it, not `mix admin_css`.
  @runtime_templates %{
    "__extensions/mishka_cms_core/lib/mishka_cms_core/dev/generator.ex" =>
      "writes seeded error-page templates into the database"
  }

  # A whitespace-delimited token that GLUES an interpolation to anything else. The excluded backslash
  # keeps `\#{` out — inside an `~S` sigil that is a literal `#{`, which is how the compilers' doc
  # examples show a template to write.
  @glued ~r/(?:[^\s"{\\]#\{|#\{[^}]*\}[^\s"])/

  # BYTE offsets throughout. `Regex.scan(return: :index)` returns byte offsets while `String.slice/3`
  # and `String.at/2` count graphemes, and this repo's sources are full of `—`, `·` and `✦`. Mixing
  # the two drifted every region a few characters to the left, so the balancer started mid-token and
  # ran on into the next attribute — which is how an earlier version of this test "found" a `style`
  # and an `id`.
  test "no Tailwind class is assembled by interpolation" do
    offenders =
      @roots
      |> Enum.flat_map(&source_files/1)
      |> Enum.reject(&exempt?/1)
      |> Enum.flat_map(&scan/1)

    assert offenders == [], """
    A Tailwind class is built by interpolation, so its rule will not exist:

    #{Enum.map_join(offenders, "\n", fn {file, line, text} -> "  #{file}:#{line}\n      #{text}" end)}

    Write the whole class name out, one function clause per case:

        defp track_class(2), do: "grid-cols-[repeat(auto-fill,minmax(min(100%,380px),1fr))]"
        defp track_class(_), do: "grid-cols-[repeat(auto-fill,minmax(min(100%,290px),1fr))]"

    If the value set is genuinely open, declare it with `@source inline(...)` in `Mix.Tasks.AdminCss`
    and add the file to `@allowed` in this test with the reason.
    """
  end

  test "every allowed file still exists and still interpolates" do
    for {path, reason} <- Map.merge(@allowed, @runtime_templates) do
      assert File.exists?(path), "@allowed lists #{path}, which no longer exists — drop the entry"

      assert scan(path) != [],
             "@allowed lists #{path} (#{reason}), but it no longer interpolates a class — drop the entry"
    end
  end

  defp source_files(root) do
    root |> Path.join("**/*.{ex,heex,eex}") |> Path.wildcard()
  end

  # `_build` and `deps` hold copies of the same sources, and a test tree's fixtures are not rendered.
  defp exempt?(path) do
    String.contains?(path, ["/_build/", "/deps/"]) or path =~ ~r{(^|/)test/} or
      Map.has_key?(@allowed, path) or Map.has_key?(@runtime_templates, path)
  end

  defp scan(path) do
    source = File.read!(path)
    regions = class_values(source)

    seeds =
      regions
      |> Enum.flat_map(fn {_at, value} -> called(value) end)
      |> Enum.concat(class_named(source))
      |> Enum.uniq()

    (regions ++ Enum.flat_map(reachable(source, seeds), &bodies_of(source, &1)))
    |> Enum.flat_map(fn {at, value} ->
      value
      |> string_literals()
      |> Enum.filter(fn {_offset, literal} -> Regex.match?(@glued, literal) end)
      |> Enum.map(fn {offset, literal} -> {path, line_of(source, at + offset), literal} end)
    end)
    |> Enum.reject(fn {_path, line, _literal} -> commented?(source, line) end)
    |> Enum.map(fn {path, line, literal} -> {path, line, String.trim(literal)} end)
    |> Enum.uniq()
  end

  # A comment EXPLAINING the bug is not the bug. The fixed sites carry the interpolated form in prose
  # so the next reader knows what was wrong, and a guard that flags its own documentation gets
  # deleted.
  defp commented?(source, line) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> String.trim_leading()
    |> String.starts_with?(["#", "<%!--", "*"])
  end

  # Every `class` binding's VALUE, as `{byte_offset, source_text}`. Delimiters are balanced rather
  # than matched to the first closer, because a class list routinely contains a nested `{…}` or `[…]`.
  defp class_values(source) do
    ~r/\bclass(?:es)?\s*[=:]\s*/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, length} | _rest] ->
      at = start + length
      {at, value_at(binary_part(source, at, byte_size(source) - at))}
    end)
  end

  # Local functions a class value calls. Module-qualified calls are skipped: the walk stays inside one
  # file, and following them would need the other file's source.
  defp called(value) do
    ~r/(?<![.\w])([a-z_][a-zA-Z0-9_]*)\(/ |> Regex.scan(value) |> Enum.map(&List.last/1)
  end

  # The naming convention: a function that returns classes says so. This is what reaches a builder
  # whose only caller lives in another module.
  defp class_named(source) do
    ~r/\n  defp?\s+([a-z_][a-zA-Z0-9_]*_(?:class|classes))[\s(]/
    |> Regex.scan(source)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  # TO A FIXED POINT. One hop is not enough: the class attribute calls `grid_classes/1`, which calls
  # `track_class/1`, and the interpolation was in the second. Stopping at the first hop made this
  # test pass while all three known instances of the bug sat in the tree.
  defp reachable(source, seeds), do: reachable(source, seeds, MapSet.new())

  defp reachable(_source, [], seen), do: MapSet.to_list(seen)

  defp reachable(source, [name | rest], seen) do
    case MapSet.member?(seen, name) do
      true ->
        reachable(source, rest, seen)

      false ->
        next = source |> bodies_of(name) |> Enum.flat_map(fn {_at, body} -> called(body) end)
        reachable(source, next ++ rest, MapSet.put(seen, name))
    end
  end

  # Every clause of a local function, as `{byte_offset, source_text}` — from its `def`/`defp` to the
  # next one at the same indentation, which is where a clause reliably ends in this codebase.
  defp bodies_of(source, name) do
    ~r/\n  defp?\s+#{Regex.escape(name)}[\s(]/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{at, _length} | _rest] ->
      rest = binary_part(source, at + 1, byte_size(source) - at - 1)

      body =
        case Regex.run(~r/\n  defp?\s/, rest, return: :index, offset: 1) do
          [{stop, _length} | _] -> binary_part(rest, 0, stop)
          nil -> rest
        end

      {at + 1, body}
    end)
  end

  defp string_literals(value) do
    ~r/"(?:[^"\\]|\\.)*"/
    |> Regex.scan(value, return: :index)
    |> Enum.map(fn [{at, length} | _rest] -> {at, binary_part(value, at, length)} end)
  end

  defp value_at("{" <> _rest = source), do: balanced(source, "{", "}")
  defp value_at("[" <> _rest = source), do: balanced(source, "[", "]")
  defp value_at("\"" <> _rest = source), do: quoted(source)
  # `id: some_var` — a bare expression holds no string literal to skip over.
  defp value_at(_source), do: ""

  defp balanced(source, open, close), do: balanced(source, open, close, 0, false, [])

  defp balanced(<<>>, _open, _close, _depth, _in_string, acc), do: collect(acc)

  # An escaped quote inside a string must not end it.
  defp balanced(<<"\\", char::binary-size(1), rest::binary>>, open, close, depth, true, acc),
    do: balanced(rest, open, close, depth, true, [char, "\\" | acc])

  defp balanced(<<"\"", rest::binary>>, open, close, depth, in_string, acc),
    do: balanced(rest, open, close, depth, !in_string, ["\"" | acc])

  defp balanced(<<char::binary-size(1), rest::binary>>, open, close, depth, true, acc),
    do: balanced(rest, open, close, depth, true, [char | acc])

  defp balanced(<<char::binary-size(1), rest::binary>>, open, close, depth, false, acc) do
    cond do
      char == open -> balanced(rest, open, close, depth + 1, false, [char | acc])
      char == close and depth == 1 -> collect([char | acc])
      char == close -> balanced(rest, open, close, depth - 1, false, [char | acc])
      true -> balanced(rest, open, close, depth, false, [char | acc])
    end
  end

  defp collect(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp quoted(source) do
    case Regex.run(~r/^"(?:[^"\\]|\\.)*"/, source) do
      [literal] -> literal
      nil -> ""
    end
  end

  defp line_of(source, offset) do
    source |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end
end
