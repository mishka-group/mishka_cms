# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.CompileStaticCss do
  @shortdoc "Precompile the static Tailwind base CSS for release builds"

  @moduledoc """
  Precompiles the RUNTIME SHELL's CSS for releases, into `priv/static/temp/static_base.css`.

  The shell is the host code that renders AROUND a database page: the layouts module, its templates
  and `RuntimeLive`. In development the compiler scans those files live (see
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.host_app_web_sources/0`), so an edit to a layout
  styles itself immediately. A release ships no `.ex` files, so this artifact is the only copy there
  and is prepended to every site's stylesheet.

  ## What it deliberately does NOT contain

  It used to scan `lib/**` and every extension, which meant the dashboard, the Gervaz table library
  and the host's marketing pages were all prepended to every SITE's stylesheet — 514 KB that a
  visitor to a database page downloads and can never render. Those audiences have their own sheets,
  both built by `mix admin_css`:

    * `admin.css` — the dashboard, the page builder shell, `/auth`
    * `public.css` — the host's own marketing pages

  Narrowing this to the shell took the artifact from 514,224 to 65,223 bytes.

  Run it in the release build AFTER `mix compile`, `mix copy_js_assets` and `mix assets.deploy` — it
  needs the compiled app, the JS assets on disk and the installed Tailwind binary. The task self-runs
  `compile` defensively.
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:tailwind)

    {:ok, path} = TailwindCompiler.compile_static_base()
    Mix.shell().info("✅ Static base CSS compiled → #{path}")
  rescue
    error ->
      Mix.raise("Static base CSS compilation failed: #{Exception.message(error)}")
  end
end
