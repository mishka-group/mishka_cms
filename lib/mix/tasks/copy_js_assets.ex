# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.CopyJsAssets do
  @moduledoc """
  Copies JavaScript assets (app.js and vendor files) to priv/static/temp/js_assets
  for runtime compilation in production releases.

  This preserves the directory structure needed for imports to work correctly.

  ## Usage

      mix copy_js_assets
  """

  use Mix.Task

  @shortdoc "Copies JS assets for runtime compilation"

  def run(_args) do
    MishkaCms.Dev.JsAssetsCopier.run()
  end
end
