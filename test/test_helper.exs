# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.SandboxDisconnectLogFilter do
  @moduledoc """
  Silences the harmless `client <pid> exited` DBConnection disconnect that the Ecto
  sandbox emits during test teardown.

  Views under test spawn async DB loaders — the gervaz table `load_async` (behind every
  admin table) and the dashboard `start_async` widgets — that borrow the test's sandbox
  connection to run their `Ash` query. When a test finishes, ExUnit terminates the
  LiveView and its in-flight async Task; if that Task is killed mid-query, the pool
  process logs a disconnect at `:error` (`db_connection` connection.ex). The query is
  rolled back by the sandbox, so there is no data effect and no test failure — it is
  pure teardown noise. The pool process logs it outside any test's `capture_log` scope,
  so it cannot be captured per-test; this `:logger` primary filter drops it before any
  handler runs.

  Only this exact line is dropped. A real disconnect (DB down, `econnrefused`) carries a
  different message and still surfaces.
  """

  def filter(%{level: :error, msg: {:string, chardata}}, _opts) do
    text = IO.chardata_to_string(chardata)

    if String.contains?(text, "disconnected:") and String.contains?(text, "client") and
         String.contains?(text, "exited"),
       do: :stop,
       else: :ignore
  end

  def filter(_event, _opts), do: :ignore
end

:logger.add_primary_filter(
  :mishka_sandbox_disconnect,
  {&MishkaCms.SandboxDisconnectLogFilter.filter/2, []}
)

# `render_async/1` WAITS THIS LONG, and 100ms is not a number anybody here chose. LiveView's
# default is `Application.fetch_env!(:ex_unit, :assert_receive_timeout)`, and every `render_async`
# in these suites is waiting on a real database load — the editor's `start_async` record fetch,
# most of them. On a machine running another suite beside this one that load takes longer than
# 100ms, and the test fails with "expected async processes to finish within 100ms" from a line that
# was asserting something else entirely.
#
# Raising it here rather than at 156 call sites: it is the knob LiveView itself reads, it covers
# every future `render_async` without anyone remembering, and it costs nothing on a passing run —
# a longer timeout only delays FAILURES, never successes.
ExUnit.configure(assert_receive_timeout: 1_000)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MishkaCms.Repo, :manual)
