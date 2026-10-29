# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.PageUpdatedBannerTest do
  @moduledoc """
  A reader with a database page open is told when it changed, once the change can be seen.

  A save only queues the page's recompile, so `MishkaCmsWeb.RuntimeLive` waits for that compile job
  to finish — `MishkaCmsCore.Activity.Sources.Oban` announces every job of the site's pages on
  `oban_activity:site:<id>:res:MishkaCmsCore.Runtime.Page` — and then pushes
  `mishka:page-updated`, which shows the banner a rebuilt JS bundle shows (`assets/js/update_banner.js`).

  `async: false` — the install flag, `SiteState`, the routing table and `:env_test?` are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false
  use Oban.Testing, repo: MishkaCms.Repo

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  setup do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)
    MishkaCmsCore.Settings.put("cms.offline", false)

    %{site: site, page: published!(site), other: published!(site)}
  end

  defp job(site, page, event, action \\ "update") do
    topic = "oban_activity:site:#{site.id}:res:MishkaCmsCore.Runtime.Page"

    Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "oban_activity",
      payload: %{
        __oban__: true,
        event: event,
        job: %Oban.Job{args: %{"action" => action, "data" => %{"id" => page.id}}}
      }
    })
  end

  test "shows the banner once the page's update job has finished", %{site: site, page: page} do
    {:ok, view, _html} = live(on_site(), page.path)

    job(site, page, :stop)

    assert_push_event(view, "mishka:page-updated", %{})
    assert has_element?(view, "#page-body"), "the reader's page was thrown away"
  end

  test "says nothing while the job runs, or when it failed", %{site: site, page: page} do
    {:ok, view, _html} = live(on_site(), page.path)

    job(site, page, :start)
    job(site, page, :exception)

    refute_push_event(view, "mishka:page-updated", %{}, 50)
  end

  test "another page's rebuild is not this reader's news", %{site: site, page: page, other: other} do
    {:ok, view, _html} = live(on_site(), page.path)

    job(site, other, :stop)

    refute_push_event(view, "mishka:page-updated", %{}, 50)
    assert has_element?(view, "#page-body")
  end

  # THE WHOLE PATH: a save queues the page's job, the job rebuilds the module, Oban's telemetry is
  # announced on the site's topic, and the open page pushes the banner.
  test "a saved page tells its reader after the real rebuild", %{page: page} do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    {:ok, view, _html} = live(on_site(), page.path)

    page
    |> Ash.Changeset.for_update(:update, %{content: %{"seats_left" => 2}},
      authorize?: false,
      tenant: page.site_id,
      context: %{page_code: :package}
    )
    |> Ash.update!()

    [args] =
      for %{args: %{"resource" => "MishkaCmsCore.Runtime.Page", "data" => %{"id" => id}} = args} <-
            all_enqueued(worker: RuntimeCompilerWorker),
          id == page.id,
          do: args

    refute_push_event(view, "mishka:page-updated", %{}, 50)

    assert :ok = perform_job(RuntimeCompilerWorker, args)

    assert_push_event(view, "mishka:page-updated", %{})
  end

  defp published!(site) do
    page =
      create_page!(
        site_id: site.id,
        path: "/banner-#{System.unique_integer([:positive])}",
        template: ~S(<div id="page-body" data-page={@page.path}>page</div>)
      )

    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page.id,
        site: site.name,
        path: page.path,
        title: page.name,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0
      })

    page
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
