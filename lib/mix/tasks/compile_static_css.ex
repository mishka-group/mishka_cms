# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.CompileStaticCss do
  @shortdoc "Writes the runtime shell's Tailwind classes for release builds"

  @moduledoc """
  Writes the classes of the RUNTIME SHELL to `priv/static/temp/shell_classes.txt`, one per line,
  for releases.

  The shell is the host code that renders AROUND a database page: the `components/` tree and
  `RuntimeLive` (`MishkaCmsCore.Runtime.Compilers.TailwindCompiler.shell_sources/0`). A site's one
  Tailwind run scans those files where they are on disk. A release ships no `.ex` files, so there
  the run reads this list in their place, and the shell's classes are still ranked with the site's
  own and built from the same `@theme` tokens.

  The list is Tailwind's own: `assets/scripts/shell_classes.mjs` runs `@tailwindcss/oxide`, the
  scanner inside the Tailwind binary, pinned in `assets/package.json` to the binary's version
  (`config :tailwind, version:`), over the same sources. Run it in the release build after
  `mix assets.setup`, which installs the scanner.
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    sources = core(:shell_sources)
    path = core(:shell_classes_path)

    if sources == [], do: Mix.raise("No runtime shell sources under #{File.cwd!()}/lib")

    File.mkdir_p!(Path.dirname(path))

    case System.cmd("bun", ["assets/scripts/shell_classes.mjs", path | sources],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> Mix.shell().info("Wrote the shell's classes to #{path}")
      {output, status} -> Mix.raise("Shell classes failed (exit #{status}): #{output}")
    end
  end

  # The core's list of shell sources and the path it reads the classes from. Through apply/3 while
  # the host builds against mishka_cms_core 0.0.4, which has neither; this task runs in the image
  # build only, after the core release that has them.
  defp core(fun), do: apply(TailwindCompiler, fun, [])
end
