# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.Dev.AdminCssTest do
  @moduledoc """
  `mix admin_css` builds both stylesheets even while `mix tailwind` is held by someone else.

  The dev server starts one watcher per sheet, together. Whichever asked `mix tailwind` second,
  while the first still held it, used to get nothing, so its sheet was never rebuilt and new admin
  classes rendered unstyled.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # THE BINARY IS THE PROJECT'S, found before the move: Tailwind looks for it under the build path,
  # which follows the working directory, so from the temp directory it would download a fresh one.
  setup %{tmp_dir: tmp_dir} do
    cwd = File.cwd!()
    Application.put_env(:tailwind, :path, Tailwind.bin_path())
    File.cd!(tmp_dir)
    Mix.TasksServer.put({:task, "tailwind", Mix.Project.get()})

    on_exit(fn ->
      File.cd!(cwd)
      Application.delete_env(:tailwind, :path)
      Mix.Task.reenable("tailwind")
    end)

    :ok
  end

  test "writes the admin and the public sheet while mix tailwind is held", %{tmp_dir: tmp_dir} do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> Mix.Tasks.AdminCss.run([]) end)

    for sheet <- ["admin.css", "public.css"] do
      path = Path.join([tmp_dir, "priv/static/assets/css", sheet])
      assert File.exists?(path), "#{sheet} was not built"
      assert File.stat!(path).size > 0
    end
  end
end
