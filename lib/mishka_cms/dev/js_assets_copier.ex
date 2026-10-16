# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Dev.JsAssetsCopier do
  @moduledoc false
  require Logger

  # npm packages the per-site bundles import by bare name. The runtime JS compiler bundles from
  # the staged temp dir, not assets/, so each listed package is copied from assets/node_modules
  # into the staged node_modules — at dev boot and at release build time (`mix copy_js_assets`),
  # where assets/node_modules still exists; the staged copy then ships inside priv/.
  @npm_packages ["sortablejs"]

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################
  def run() do
    source_assets_dir = "assets"

    target_dir =
      case :code.priv_dir(:mishka_cms) do
        {:error, _} -> Path.join(["priv", "static", "temp", "js_assets"])
        priv_dir -> Path.join([priv_dir, "static", "temp", "js_assets"])
      end

    Logger.debug("Copying JS assets from #{source_assets_dir} to #{target_dir}")

    # Ensure all parent directories exist
    ensure_directories_exist(target_dir)

    copy_js_directory(source_assets_dir, target_dir)
    copy_vendor_directory(source_assets_dir, target_dir)
    copy_package_files(source_assets_dir, target_dir)
    copy_phoenix_files(target_dir)
    copy_npm_packages(source_assets_dir, target_dir)
    # NEW: Copy colocated hooks
    copy_phoenix_colocated_hooks(target_dir)
    # Copy heroicons for Tailwind v4
    copy_heroicons(target_dir)

    Logger.debug("JS assets copied successfully!")
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  defp ensure_directories_exist(target_dir) do
    _ = File.mkdir_p!(target_dir)

    for subdir <- ["js", "vendor", "node_modules", "node_modules/phoenix-colocated"] do
      path = Path.join(target_dir, subdir)
      File.mkdir_p!(path)
      Logger.debug("Ensured directory exists: #{path}")
    end

    Path.dirname(target_dir) |> File.mkdir_p!()
  end

  defp copy_phoenix_files(target_dir) do
    target_node_modules = Path.join(target_dir, "node_modules")

    _ = File.mkdir_p!(target_node_modules)

    # Try using the CJS versions which might work better
    phoenix_deps = [
      {"phoenix", :phoenix, "phoenix.cjs.js"},
      {"phoenix_html", :phoenix_html, "phoenix_html.js"},
      {"phoenix_live_view", :phoenix_live_view, "phoenix_live_view.cjs.js"}
    ]

    Enum.each(phoenix_deps, fn {name, app, filename} ->
      target_package_dir = Path.join(target_node_modules, name)
      _ = File.mkdir_p!(target_package_dir)

      source_js = Path.join(:code.priv_dir(app), "static/#{filename}")
      target_js = Path.join(target_package_dir, "index.js")

      if File.exists?(source_js) do
        _ = File.copy!(source_js, target_js)

        Jason.encode!(%{"name" => name, "main" => "index.js", "version" => "1.0.0"})
        |> then(&File.write!(Path.join(target_package_dir, "package.json"), &1))

        Logger.debug("Copied Phoenix module: #{name} (#{filename})")
      else
        Logger.warning("Phoenix file not found: #{source_js}")
      end
    end)
  end

  defp copy_npm_packages(source_assets_dir, target_dir) do
    target_node_modules = Path.join(target_dir, "node_modules")

    Enum.each(@npm_packages, fn name ->
      source = Path.join([source_assets_dir, "node_modules", name])
      target = Path.join(target_node_modules, name)

      if File.exists?(source) do
        _ = File.mkdir_p!(target)
        _ = File.cp_r!(source, target)
        Logger.debug("Copied npm package: #{name}")
      else
        Logger.warning(
          "npm package #{name} not found at #{source} — run `bun install` in assets/ first"
        )
      end
    end)
  end

  defp copy_phoenix_colocated_hooks(target_dir) do
    target_colocated_dir = Path.join([target_dir, "node_modules", "phoenix-colocated"])
    _ = File.mkdir_p!(target_colocated_dir)

    # Check if colocated hooks exist in priv/static
    priv_dir =
      case :code.priv_dir(:mishka_cms) do
        {:error, _} -> "priv"
        priv_dir -> priv_dir
      end

    # Phoenix typically generates colocated hooks in priv/static/colocated
    source_colocated = Path.join([priv_dir, "static", "colocated"])

    if File.exists?(source_colocated) do
      # Copy all colocated files
      File.cp_r!(source_colocated, target_colocated_dir)
      Logger.debug("Copied Phoenix colocated hooks from #{source_colocated}")
    else
      # If colocated hooks don't exist, create a stub file to prevent build errors
      create_colocated_stub(target_colocated_dir)
    end

    # Create package.json for phoenix-colocated
    package_json =
      Jason.encode!(%{
        "name" => "phoenix-colocated",
        "main" => "mishka_cms.js",
        "version" => "1.0.0"
      })

    File.write!(Path.join(target_colocated_dir, "package.json"), package_json)
  end

  defp create_colocated_stub(target_colocated_dir) do
    stub_content = """
    // Auto-generated stub for phoenix-colocated hooks
    // This file is created when no colocated hooks are found
    export const hooks = {};
    """

    File.write!(Path.join(target_colocated_dir, "mishka_cms.js"), stub_content)
    Logger.debug("Created stub for phoenix-colocated/mishka_cms (no colocated hooks found)")
  end

  defp copy_js_directory(source_assets_dir, target_dir) do
    source_js_dir = Path.join(source_assets_dir, "js")

    if File.exists?(source_js_dir) do
      target_js_dir = Path.join(target_dir, "js")
      _ = File.mkdir_p!(target_js_dir)
      copy_directory(source_js_dir, target_js_dir)
    else
      # Create empty js directory if source doesn't exist
      target_js_dir = Path.join(target_dir, "js")
      File.mkdir_p!(target_js_dir)
      Logger.warning("No js directory found at #{source_js_dir}, created empty directory")
    end
  end

  defp copy_vendor_directory(source_assets_dir, target_dir) do
    source_vendor = Path.join(source_assets_dir, "vendor")
    target_vendor = Path.join(target_dir, "vendor")

    if File.exists?(source_vendor) do
      _ = File.mkdir_p!(target_vendor)
      copy_directory(source_vendor, target_vendor)
    else
      # Create empty vendor directory
      File.mkdir_p!(target_vendor)
      Logger.warning("No vendor directory found, created empty directory")
    end
  end

  defp copy_package_files(source_assets_dir, target_dir) do
    for file <- ["package.json", "package-lock.json"] do
      source = Path.join(source_assets_dir, file)
      target = Path.join(target_dir, file)

      if File.exists?(source) do
        File.copy!(source, target)
        Logger.debug("Copied #{file}")
      else
        Logger.debug("#{file} not found at #{source}, skipping")
      end
    end
  end

  defp copy_directory(source, target) do
    _ = File.mkdir_p!(target)

    copied_files =
      File.cp_r!(source, target,
        on_conflict: fn source_file, target_file ->
          Logger.debug("Copying: #{source_file} -> #{target_file}")
          true
        end
      )

    Logger.debug("Copied directory: #{source} -> #{target} (#{length(copied_files)} files)")
    :ok
  end

  defp copy_heroicons(target_dir) do
    # The heroicons plugin expects them relative to vendor/heroicons.js location
    # So we need to place them at priv/static/temp/deps/heroicons/optimized
    temp_base = Path.dirname(target_dir)
    target_deps_dir = Path.join(temp_base, "deps")
    target_heroicons_dir = Path.join([target_deps_dir, "heroicons", "optimized"])

    # Source is the optimized folder from heroicons deps
    source_heroicons_optimized = Path.join(["deps", "heroicons", "optimized"])

    if File.exists?(source_heroicons_optimized) do
      _ = File.mkdir_p!(Path.dirname(target_heroicons_dir))

      # Copy only the optimized directory (contains SVG files)
      File.cp_r!(source_heroicons_optimized, target_heroicons_dir)

      Logger.debug(
        "Copied heroicons from #{source_heroicons_optimized} to #{target_heroicons_dir}"
      )
    else
      Logger.warning(
        "Heroicons optimized folder not found at #{source_heroicons_optimized}, icons may not work properly"
      )
    end
  end
end
