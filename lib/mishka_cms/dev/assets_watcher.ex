# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Dev.AssetsWatcher do
  @moduledoc """
  A Phoenix-compatible watcher for MishkaCms Tailwind CSS and JavaScript compilation.
  Uses FileSystem for efficient file watching instead of polling.
  This module follows the same pattern as Tailwind.install_and_run/2 but provides
  custom compilation logic for runtime CSS and JavaScript generation.
  Now integrated with AssetsState for site-specific CSS and JS management.
  """

  use GenServer
  require Logger
  alias MishkaCmsCore.Runtime.Compilers.{TailwindCompiler, JavaScriptCompiler}

  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################
  @doc """
  Alternative entry point for manual control.
  Starts a GenServer-based watcher for more sophisticated control.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Main entry point for Phoenix watchers.
  This function mimics the behavior of Tailwind.install_and_run/2 by:
  1. Starting a long-running process
  2. Performing initial compilation
  3. Watching files and recompiling when they change

  Usage in config/dev.exs:
  ```elixir
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:mishka_cms, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:mishka_cms, ~w(--watch)]},
    mishka_cms_assets:
      {MishkaCms.Dev.AssetsWatcher, :install_and_run, [[site_names: ["example", "another_site"]]]}
  ]
  ```
  """
  def install_and_run(opts \\ []) do
    site_names = Keyword.get(opts, :site_names, ["example"])
    debounce_ms = Keyword.get(opts, :debounce_ms, 100)
    watch_paths = Keyword.get(opts, :watch_paths, default_watch_paths())

    Logger.debug(
      "🎨 Starting MishkaCms Assets Watcher with FileSystem for sites: #{inspect(site_names)}..."
    )

    perform_initial_compilation(site_names)

    start_file_watcher(site_names, watch_paths, debounce_ms)

    0
  end

  ####################################################################################
  ########################### (▰˘◡˘▰) Server API (▰˘◡˘▰) #############################
  ####################################################################################
  @impl true
  def init(opts) do
    site_names = Keyword.get(opts, :site_names, ["example"])
    debounce_ms = Keyword.get(opts, :debounce_ms, 100)
    watch_paths = Keyword.get(opts, :watch_paths, default_watch_paths())

    Logger.debug(
      "🎨 Initializing MishkaCms Assets Watcher GenServer with FileSystem for sites: #{inspect(site_names)}..."
    )

    perform_initial_compilation(site_names)

    case start_file_system_watcher(watch_paths) do
      {:ok, watcher_pid} ->
        state = %{
          site_names: site_names,
          debounce_ms: debounce_ms,
          watcher_pid: watcher_pid,
          debounce_timer: nil,
          watch_paths: watch_paths
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("‼️ Failed to start FileSystem watcher: #{inspect(reason)}")
        {:stop, {:error, reason}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    Logger.debug("📁 File event detected: #{path} -> #{inspect(events)}")

    # Check if this is a file we care about
    if should_recompile_for_path?(path) do
      Logger.debug("🔄 Scheduling recompilation due to file change...")

      # Cancel previous debounce timer if exists
      if state.debounce_timer do
        Process.cancel_timer(state.debounce_timer)
      end

      # Start new debounce timer
      timer_ref = Process.send_after(self(), :compile, state.debounce_ms)

      {:noreply, %{state | debounce_timer: timer_ref}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("⚠️ File watcher stopped")
    {:noreply, state}
  end

  @impl true
  def handle_info(:compile, state) do
    Logger.debug("⚡ Recompiling assets due to file changes...")

    # Invalidate the shared-base CSS cache so newly-typed classes from
    # host-app .ex/.heex files (which feed the shared base via
    # `host_app_web_sources/0` and `tailwind_classes.template`) actually
    # land in the next compile. Without this, `compile/1` reuses the
    # cached `__shared_base__` and your edits never appear in the CSS.
    TailwindCompiler.delete_shared_base_css()

    results =
      Enum.map(state.site_names, fn site_name ->
        # Compile Tailwind CSS
        tailwind_result = TailwindCompiler.compile_and_store(site_name)

        # Compile JavaScript
        js_result = JavaScriptCompiler.compile_and_store(site_name)

        case {tailwind_result, js_result} do
          {{:ok, _css}, {:ok, _js}} ->
            Logger.debug("✅ Assets recompiled successfully for site: #{site_name}")
            {:ok, site_name}

          {{:error, reason}, _} ->
            Logger.warning("⚠️ Tailwind CSS recompilation failed for site #{site_name}: #{reason}")
            {:error, site_name, reason}

          {_, {:error, reason}} ->
            Logger.warning("⚠️ JavaScript recompilation failed for site #{site_name}: #{reason}")
            {:error, site_name, reason}
        end
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.count(results, &match?({:error, _, _}, &1))

    Logger.debug("🏁 Recompilation completed: #{successes} successes, #{failures} failures")

    trigger_browser_reload()

    {:noreply, %{state | debounce_timer: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # FileSystem process will terminate automatically when this GenServer terminates
    # since it's linked to this process via start_link
    :ok
  end

  ####################################################################################
  ##################### (▰˘◡˘▰) Maintenance functions (▰˘◡˘▰) ########################
  ####################################################################################
  @doc """
  Check if the watcher is running (GenServer version).
  """
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Get current watch paths and debug information.
  """
  def debug_paths do
    paths = default_watch_paths()

    IO.puts("🔍 Debug Watch Paths:")
    IO.puts("Current working directory: #{File.cwd!()}")
    IO.puts("Watch paths: #{inspect(paths)}")

    Enum.each(paths, fn path ->
      exists = File.exists?(path)
      IO.puts("  #{path} -> #{if exists, do: "✅ EXISTS", else: "❌ NOT FOUND"}")
    end)

    paths
  end

  @doc """
  Get current watch paths.
  """
  def watch_paths do
    default_watch_paths()
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  defp default_watch_paths do
    # Start with absolute paths to avoid issues
    base_paths = [
      # Watch Phoenix templates and views
      "lib/mishka_cms_web",

      # Watch every git-submoduled extension's source tree — they ship
      # LiveViews/components whose Tailwind classes must invalidate the
      # shared-base CSS just like host-app files.
      "__extensions",

      # Watch any custom CSS files
      "assets/css",

      # Watch JavaScript files that might contain Tailwind classes
      "assets/js",
      "assets/vendor"
    ]

    # Convert to absolute paths and filter existing ones
    absolute_paths = Enum.map(base_paths, &Path.expand/1)
    existing_paths = Enum.filter(absolute_paths, &File.exists?/1)

    Logger.debug("📂 Checking paths: #{inspect(base_paths)}")
    Logger.debug("📂 Absolute paths: #{inspect(absolute_paths)}")
    Logger.debug("📂 Existing paths: #{inspect(existing_paths)}")

    # If no paths exist, fall back to current directory
    case existing_paths do
      [] ->
        Logger.warning("⚠️ No watch paths found, using current directory")
        [File.cwd!()]

      paths ->
        paths
    end
  end

  defp perform_initial_compilation(site_names) do
    Logger.debug("🚀 Performing initial asset compilation for sites: #{inspect(site_names)}")
    # No class extraction in dev: TailwindCompiler.host_app_web_sources/0 scans
    # the live source tree (lib/**, __extensions/**) directly, so Tailwind's
    # own scanner finds every class. The precompiled static_base.css is a
    # release-only artifact (see `mix compile_static_css`).
    MishkaCms.Dev.JsAssetsCopier.run()

    Enum.each(site_names, fn site_name ->
      # Compile Tailwind CSS
      case TailwindCompiler.compile_and_store(site_name) do
        {:ok, _css} ->
          Logger.debug("✅ Initial Tailwind CSS compilation completed for site: #{site_name}")

        {:error, reason} ->
          Logger.error(
            "❌ Initial Tailwind CSS compilation failed for site #{site_name}: #{reason}"
          )
      end

      # Compile JavaScript
      case JavaScriptCompiler.compile_and_store(site_name) do
        {:ok, _js} ->
          Logger.debug("✅ Initial JavaScript compilation completed for site: #{site_name}")

        {:error, reason} ->
          Logger.error("❌ Initial JavaScript compilation failed for site #{site_name}: #{reason}")
      end
    end)
  end

  defp start_file_watcher(site_names, watch_paths, debounce_ms) do
    # Spawn a process that starts the file watcher
    spawn(fn ->
      Logger.debug("👀 Starting FileSystem watcher for paths: #{inspect(watch_paths)}")

      case start_file_system_watcher(watch_paths) do
        {:ok, watcher_pid} ->
          Logger.debug("✅ FileSystem watcher started successfully")
          file_watcher_loop(site_names, watcher_pid, debounce_ms, nil)

        {:error, reason} ->
          Logger.error("❌ Failed to start FileSystem watcher: #{inspect(reason)}")
          # Fallback to interval-based watching
          Logger.debug("🔄 Falling back to interval-based watching...")
          interval_fallback_loop(site_names, 3000)
      end
    end)
  end

  defp start_file_system_watcher(watch_paths) do
    # Convert to absolute paths to be sure
    absolute_paths = Enum.map(watch_paths, &Path.absname/1)

    # Filter out non-existent paths
    existing_paths = Enum.filter(absolute_paths, &File.exists?/1)

    Logger.debug("📂 Trying to watch absolute paths: #{inspect(absolute_paths)}")
    Logger.debug("📂 Existing absolute paths: #{inspect(existing_paths)}")

    if Enum.empty?(existing_paths) do
      Logger.warning("⚠️ No valid watch paths found, using current directory")
      current_dir = File.cwd!()
      Logger.debug("📂 Falling back to current directory: #{current_dir}")

      case FileSystem.start_link(dirs: [current_dir]) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          {:ok, pid}

        error ->
          error
      end
    else
      Logger.debug("📂 Starting FileSystem watcher for: #{inspect(existing_paths)}")

      case FileSystem.start_link(dirs: existing_paths) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          {:ok, pid}

        error ->
          error
      end
    end
  end

  defp file_watcher_loop(site_names, watcher_pid, debounce_ms, debounce_timer) do
    receive do
      {:file_event, ^watcher_pid, {path, events}} ->
        Logger.debug("📁 File event: #{path} -> #{inspect(events)}")

        if should_recompile_for_path?(path) do
          # Cancel previous timer if exists
          if debounce_timer, do: Process.cancel_timer(debounce_timer)

          # Start new debounce timer
          timer_ref = Process.send_after(self(), :compile_now, debounce_ms)
          file_watcher_loop(site_names, watcher_pid, debounce_ms, timer_ref)
        else
          file_watcher_loop(site_names, watcher_pid, debounce_ms, debounce_timer)
        end

      {:file_event, ^watcher_pid, :stop} ->
        Logger.warning("⚠️ FileSystem watcher stopped")
        # Restart or fallback to interval
        interval_fallback_loop(site_names, 3000)

      :compile_now ->
        Logger.debug("⚡ Recompiling assets due to file changes...")

        # Invalidate shared-base CSS cache — see :compile handler comment.
        TailwindCompiler.delete_shared_base_css()

        # Compile for all sites
        Enum.each(site_names, fn site_name ->
          # Compile Tailwind CSS
          tailwind_result = TailwindCompiler.compile_and_store(site_name)

          # Compile JavaScript
          js_result = JavaScriptCompiler.compile_and_store(site_name)

          case {tailwind_result, js_result} do
            {{:ok, _css}, {:ok, _js}} ->
              Logger.debug("✅ Assets recompiled successfully for site: #{site_name}")

            {{:error, reason}, _} ->
              Logger.warning(
                "⚠️ Tailwind CSS recompilation failed for site #{site_name}: #{reason}"
              )

            {_, {:error, reason}} ->
              Logger.warning("⚠️ JavaScript recompilation failed for site #{site_name}: #{reason}")
          end
        end)

        trigger_browser_reload()

        file_watcher_loop(site_names, watcher_pid, debounce_ms, nil)

      other ->
        Logger.debug("Received unexpected message in file watcher: #{inspect(other)}")
        file_watcher_loop(site_names, watcher_pid, debounce_ms, debounce_timer)
    end
  end

  defp interval_fallback_loop(site_names, interval) do
    Logger.debug("🔄 Using interval fallback with #{interval}ms")
    :timer.sleep(interval)

    Enum.each(site_names, fn site_name ->
      # Compile Tailwind CSS
      case TailwindCompiler.compile_and_store(site_name) do
        {:ok, _css} ->
          Logger.debug("✅ Tailwind CSS recompiled successfully (fallback) for site: #{site_name}")

        {:error, reason} ->
          Logger.warning(
            "⚠️ Tailwind CSS recompilation failed (fallback) for site #{site_name}: #{reason}"
          )
      end

      # Compile JavaScript
      case JavaScriptCompiler.compile_and_store(site_name) do
        {:ok, _js} ->
          Logger.debug("✅ JavaScript recompiled successfully (fallback) for site: #{site_name}")

        {:error, reason} ->
          Logger.warning(
            "⚠️ JavaScript recompilation failed (fallback) for site #{site_name}: #{reason}"
          )
      end
    end)

    interval_fallback_loop(site_names, interval)
  end

  defp should_recompile_for_path?(path) do
    # Check if the changed file should trigger recompilation
    path_string = to_string(path)

    # Include relevant file extensions
    relevant_extensions = [
      ".ex",
      ".exs",
      ".heex",
      ".eex",
      ".css",
      ".scss",
      ".sass",
      ".js",
      ".ts",
      ".jsx",
      ".tsx"
    ]

    # Exclude certain directories/files
    excluded_patterns = ["_build/", "deps/", ".git/", "node_modules/", ".DS_Store", "~"]

    has_relevant_extension = Enum.any?(relevant_extensions, &String.ends_with?(path_string, &1))
    not_excluded = !Enum.any?(excluded_patterns, &String.contains?(path_string, &1))

    # Special attention to CSS files - always trigger for these
    is_css_file = String.ends_with?(path_string, [".css", ".scss", ".sass"])

    # Special attention to JS files - always trigger for these
    is_js_file = String.ends_with?(path_string, [".js", ".ts", ".jsx", ".tsx"])

    result = (has_relevant_extension and not_excluded) or is_css_file or is_js_file

    if result do
      # No class extraction: the shared-base cache is invalidated by the
      # caller (delete_shared_base_css/0) and the next compile re-scans the
      # live source tree via host_app_web_sources/0. Tailwind sees the change.

      # Copy JS assets for JavaScript-related changes
      if is_js_file, do: MishkaCms.Dev.JsAssetsCopier.run()

      Logger.debug("✅ File change triggers recompilation: #{path_string}")
    else
      Logger.debug("⏭️ File change ignored: #{path_string}")
    end

    result
  end

  ####################################################################################
  #################### (▰˘◡˘▰) Maintenance functions (▰˘◡˘▰) #########################
  ####################################################################################

  @doc """
  Manually trigger a recompilation.
  Useful for development or external triggers.
  """
  def recompile_now(site_names \\ ["example"]) do
    Logger.debug("🔄 Manual recompilation triggered for sites: #{inspect(site_names)}")

    Enum.map(site_names, fn site_name ->
      tailwind_result = TailwindCompiler.compile_and_store(site_name)
      js_result = JavaScriptCompiler.compile_and_store(site_name)
      {site_name, %{tailwind: tailwind_result, javascript: js_result}}
    end)
  end

  @doc """
  Get the current compiled CSS for a specific site.
  """
  def get_css(site_name) do
    TailwindCompiler.get_compiled_css(site_name)
  end

  @doc """
  Get the current compiled JavaScript for a specific site.
  """
  def get_js(site_name) do
    JavaScriptCompiler.get_compiled_js(site_name)
  end

  @doc """
  Get asset status for all configured sites.
  """
  def get_all_assets_status(site_names) do
    Enum.map(site_names, fn site_name ->
      {site_name,
       %{
         css: TailwindCompiler.get_css_status(site_name),
         js: JavaScriptCompiler.js_exists?(site_name)
       }}
    end)
  end

  @doc """
  Check if CSS exists for a specific site.
  """
  def css_exists?(site_name) do
    TailwindCompiler.css_exists?(site_name)
  end

  @doc """
  Check if JavaScript exists for a specific site.
  """
  def js_exists?(site_name) do
    JavaScriptCompiler.js_exists?(site_name)
  end

  @doc """
  Delete compiled CSS for a specific site.
  """
  def delete_css(site_name) do
    TailwindCompiler.delete_compiled_css(site_name)
  end

  @doc """
  Delete compiled JavaScript for a specific site.
  """
  def delete_js(site_name) do
    JavaScriptCompiler.delete_compiled_js(site_name)
  end

  @doc """
  Delete all compiled assets for a specific site.
  """
  def delete_all_assets(site_name) do
    css_result = delete_css(site_name)
    js_result = delete_js(site_name)
    {css_result, js_result}
  end

  @doc """
  Refresh CSS for a specific site.
  """
  def refresh_site_css(site_name) do
    TailwindCompiler.refresh_css(site_name)
  end

  @doc """
  Refresh JavaScript for a specific site.
  """
  def refresh_site_js(site_name) do
    JavaScriptCompiler.refresh_js(site_name)
  end

  @doc """
  Refresh all assets for a specific site.
  """
  def refresh_site_assets(site_name) do
    css_result = refresh_site_css(site_name)
    js_result = refresh_site_js(site_name)
    {css_result, js_result}
  end

  @doc """
  Get detailed information about the watcher state.
  """
  def watcher_info do
    case Process.whereis(__MODULE__) do
      nil ->
        %{running: false, message: "Watcher is not running"}

      pid ->
        %{
          running: true,
          pid: pid,
          process_info: Process.info(pid),
          message: "Watcher is running"
        }
    end
  end

  @doc """
  Stop the watcher GenServer.
  """
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.stop(__MODULE__)
    end
  end

  @doc """
  Restart the watcher with new options.
  """
  def restart(opts \\ []) do
    stop()
    :timer.sleep(100)
    start_link(opts)
  end

  # Runtime CSS/JS live in AssetsState (in-memory), so phoenix_live_reload has
  # no output file to watch and instead reloads the browser the instant a
  # source `.ex/.heex` changes — BEFORE this watcher finishes rebuilding the
  # CSS. We write a sentinel file under `priv/static/assets` (matched by the
  # live_reload `*.css` pattern, outside the excluded `temp/`) AFTER the
  # rebuild, so the browser reloads once more with the fresh CSS in place.
  # The path isn't watched by this watcher, so it can't loop.
  defp trigger_browser_reload do
    path = Path.join(["priv", "static", "assets", "__runtime_reload__.css"])
    _ = File.mkdir_p(Path.dirname(path))
    File.write(path, "/* runtime asset reload trigger: #{System.system_time(:millisecond)} */\n")
  end
end
