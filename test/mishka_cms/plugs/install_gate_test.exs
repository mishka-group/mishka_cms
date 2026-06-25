defmodule MishkaCms.Plugs.InstallGateTest do
  @moduledoc """
  Real plug tests driving the gate through every install state with concrete conns. The flag
  and env var are process-global, so this runs `async: false` and cleans both up per test.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MishkaCms.Plugs.InstallGate
  alias MishkaCmsCore.Runtime.States.SiteState

  setup do
    reset()
    on_exit(&reset/0)
    :ok
  end

  defp reset do
    :persistent_term.erase(:mishka_installed)
    System.delete_env("MISHKA_SETUP_TOKEN")
    SiteState.clear()
  end

  defp call(path), do: conn(:get, path) |> InstallGate.call(InstallGate.init([]))

  # `:unknown` is not an error state: the flag is computed by `BootHandler`, which is the last child
  # of the supervision tree, so the endpoint serves requests before it lands — and in tests it never
  # lands at all.
  describe "status :unknown (flag unset — test / boot window)" do
    test "is inert for every ordinary request" do
      refute call("/").halted
      refute call("/admin/dashboard").halted
    end

    test "and lets /install through where no token is asked for" do
      refute call("/install").halted
    end

    # The page that mints a master user with `authorize?: false`. Waved through here, it answered
    # ungated on every cold boot of an already-installed CMS, for as long as the flag took to land.
    test "but holds /install to the token, which production requires" do
      Application.put_env(:mishka_cms, :require_setup_token, true)
      on_exit(fn -> Application.delete_env(:mishka_cms, :require_setup_token) end)

      conn = call("/install")

      assert conn.halted
      assert conn.status == 403
    end

    test "and takes the token when one is set" do
      System.put_env("MISHKA_SETUP_TOKEN", "letmein")

      assert call("/install").halted
      refute call("/install?token=letmein").halted
    end
  end

  describe "status :not_installed" do
    setup do: :persistent_term.put(:mishka_installed, false)

    test "redirects a normal request to /install and halts" do
      conn = call("/admin/dashboard")
      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/install"]
    end

    test "lets /install through" do
      refute call("/install").halted
    end
  end

  describe "status :installed" do
    setup do: :persistent_term.put(:mishka_installed, true)

    test "hands /install to the site pipeline (no manual 404) — an unresolved host halts 503" do
      conn = call("/install")
      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body =~ "Service Unavailable"
    end

    test "resolves the site then raises a site-carrying NotFoundError instead of a manual 404" do
      :ok =
        SiteState.save(%{
          id: "install-gate-site",
          name: "Gate Site",
          host: "gate.example.com",
          priority: 100,
          active: true
        })

      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          conn(:get, "/install")
          |> Map.put(:req_headers, [{"host", "gate.example.com"}])
          |> init_test_session(%{})
          |> InstallGate.call(InstallGate.init([]))
        end

      assert %MishkaCmsCore.ErrorsExceptions.NotFoundError{} = error.reason
      assert error.conn.assigns.current_site.name == "Gate Site"
    end

    test "lets normal requests through" do
      refute call("/").halted
    end
  end

  describe "optional setup token (MISHKA_SETUP_TOKEN)" do
    setup do
      :persistent_term.put(:mishka_installed, false)
      System.put_env("MISHKA_SETUP_TOKEN", "s3cr3t")
      :ok
    end

    test "403s /install when no token is supplied" do
      conn = call("/install")
      assert conn.halted
      assert conn.status == 403
    end

    test "403s /install with a wrong token" do
      conn = call("/install?token=nope")
      assert conn.halted
      assert conn.status == 403
    end

    test "lets /install through with the correct token" do
      refute call("/install?token=s3cr3t").halted
    end
  end

  describe "required setup token (production)" do
    setup do
      :persistent_term.put(:mishka_installed, false)
      System.delete_env("MISHKA_SETUP_TOKEN")
      Application.put_env(:mishka_cms, :require_setup_token, true)
      on_exit(fn -> Application.delete_env(:mishka_cms, :require_setup_token) end)
      :ok
    end

    test "refuses everyone when no token is configured — the safe direction for this page" do
      conn = call("/install")

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "MISHKA_SETUP_TOKEN"
    end

    test "a guessed token does not help when none is configured" do
      conn = call("/install?token=anything")

      assert conn.halted
      assert conn.status == 403
    end

    test "with a token configured it behaves exactly as before" do
      System.put_env("MISHKA_SETUP_TOKEN", "s3cr3t")
      on_exit(fn -> System.delete_env("MISHKA_SETUP_TOKEN") end)

      assert call("/install?token=s3cr3t").status != 403
      assert call("/install?token=wrong").status == 403
    end
  end

  describe "the flag itself" do
    test "production requires it; dev and test do not" do
      refute Application.get_env(:mishka_cms, :require_setup_token, false),
             "the test env must keep the optional behaviour, or every install test changes meaning"
    end
  end
end
