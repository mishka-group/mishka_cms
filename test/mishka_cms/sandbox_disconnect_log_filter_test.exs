# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCms.SandboxDisconnectLogFilterTest do
  @moduledoc """
  Pins the `:logger` primary filter installed in `test_helper.exs`: the Ecto-sandbox
  `client <pid> exited` teardown disconnect is dropped, while a genuine disconnect
  (e.g. `econnrefused`) still surfaces.

  Each probe carries a unique marker so a stray log from any other process leaking into
  `capture_log` (which captures globally) cannot make these assertions flaky.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  test "drops the sandbox client-exited disconnect noise" do
    marker = "MISHKA-DROP-#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        Logger.error(
          "#{marker} Postgrex.Protocol (#PID<0.4401.0>) disconnected: ** (DBConnection.ConnectionError) client #PID<0.23330.0> exited"
        )

        Logger.flush()
      end)

    refute log =~ marker
  end

  test "keeps a real disconnect that is not a client-exit" do
    marker = "MISHKA-KEEP-#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        Logger.error(
          "#{marker} Postgrex.Protocol disconnected: ** (DBConnection.ConnectionError) tcp connect: :econnrefused"
        )

        Logger.flush()
      end)

    assert log =~ marker
  end
end
