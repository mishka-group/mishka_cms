defmodule MishkaCmsWeb.RuntimeEventsCannotRunTest do
  @moduledoc """
  A database page while an event `RuntimeLive` or the root layout fires cannot run — one of its
  plugins is not loaded, so `MishkaInstaller.Event.Hook.call/3` runs none of them — is served with
  core's own answer, as if the event had no plugins: the first paint, the connected mount, a page
  event and a message each go on. An access check on the compiled page (`AclAfterCompile`) refuses
  it instead, through its `cannot_run:` answer.

  Each event is stubbed alone, so a test names the one it covers.

  `async: false` — `SiteState`, the routing table, the install flag and the compiled events are
  process-global.
  """
  use MishkaCmsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCms.Test.Factory

  alias MishkaCms.Test.EventCannotRun
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  @moduletag :integration

  @template ~S"""
  <div id="page-body">
    <span data-role="count">{@count}</span>
    <button id="inc" phx-click="inc">+</button>
  </div>
  """

  @page_load_events [
    "RuntimeLive.OnMount.BeforePathTransform",
    "RuntimeLive.OnMount.AfterCompile",
    "RuntimeLive.OnMount.Return",
    "RuntimeLive.HandleParams.BeforePathTransform",
    "RuntimeLive.HandleParams.AfterCompile",
    "RuntimeLive.OnRender.BeforeRender",
    "RuntimeLive.OnRender.AfterCompile",
    "RuntimeLive.RuntimeLayout.AfterCompile"
  ]

  @page_event_events [
    "RuntimeLive.HandleEvent.BeforeEvent",
    "RuntimeLive.HandleEvent.AfterCallEvent",
    "RuntimeLive.HandleEvent.ReturnCallEvent"
  ]

  @message_events [
    "RuntimeLive.HandleInfo.BeforeInfo",
    "RuntimeLive.HandleInfo.AfterCallInfo",
    "RuntimeLive.HandleInfo.ReturnCallInfo"
  ]

  @root_layout_events [
    "RootHtml.MetaTags",
    "RootHtml.InlineScript",
    "RootHtml.ExternalAssets"
  ]

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

    layout =
      create_layout!(
        site_id: site.id,
        path: "/layouts/cannot-run-#{System.unique_integer([:positive])}",
        template: ~S(<div id="site-layout">{@inner_content}</div>)
      )

    :ok = WebRunTimeMetaDataState.save(route(layout, site, "Layout"))

    page =
      create_page!(
        site_id: site.id,
        path: "/cannot-run-#{System.unique_integer([:positive])}",
        template: @template,
        layout_id: layout.id,
        state: [%{name: "count", code: "0"}],
        events: [
          %{name: "inc", code: "{:noreply, assign(socket, :count, socket.assigns.count + 1)}"}
        ],
        infos: [
          %{name: ":bump", code: "{:noreply, assign(socket, :count, socket.assigns.count + 10)}"}
        ]
      )

    :ok = WebRunTimeMetaDataState.save(route(page, site, "Page"))

    %{page: page}
  end

  describe "loading the page" do
    for event <- @page_load_events do
      @event event

      test "renders inside its layout, first paint and connected, while #{event} cannot run", %{
        page: page
      } do
        EventCannotRun.stub!(@event)

        conn = get(on_site(), page.path)
        first_paint = html_response(conn, 200)

        assert read(first_paint, "count") == "0"
        assert first_paint =~ ~s(id="site-layout")

        {:ok, view, _html} = live(conn)

        assert read(view, "count") == "0"
        assert has_element?(view, "#site-layout #page-body")
      end
    end
  end

  describe "an access check" do
    for event <- [
          "RuntimeLive.OnMount.AclAfterCompile",
          "RuntimeLive.HandleParams.AclAfterCompile"
        ] do
      @event event

      test "refuses the page while #{event} cannot run", %{page: page} do
        EventCannotRun.stub!(@event)

        assert_error_sent 500, fn -> get(on_site(), page.path) end
      end
    end
  end

  describe "a page event" do
    for event <- @page_event_events do
      @event event

      test "runs its handler while #{event} cannot run", %{page: page} do
        EventCannotRun.stub!(@event)
        {:ok, view, _html} = live(on_site(), page.path)

        view |> element("#inc") |> render_click()

        assert read(view, "count") == "1"
      end
    end
  end

  describe "a message" do
    for event <- @message_events do
      @event event

      test "runs its handler while #{event} cannot run", %{page: page} do
        EventCannotRun.stub!(@event)
        {:ok, view, _html} = live(on_site(), page.path)

        send(view.pid, :bump)

        assert read(view, "count") == "10"
      end
    end
  end

  describe "the root layout" do
    for event <- @root_layout_events do
      @event event

      test "draws the document's head while #{event} cannot run", %{page: page} do
        EventCannotRun.stub!(@event)

        doc = on_site() |> get(page.path) |> html_response(200) |> LazyHTML.from_document()

        assert LazyHTML.attribute(LazyHTML.query(doc, ~s(meta[name="csrf-token"])), "content") !=
                 []

        assert doc |> LazyHTML.query("body #page-body") |> Enum.count() == 1
      end
    end
  end

  defp route(record, site, section) do
    %{
      id: record.id,
      site: site.name,
      path: record.path,
      title: record.name,
      created_at: DateTime.utc_now(),
      section: section,
      priority: 0
    }
  end

  defp read(html_or_view, role) do
    html = if is_binary(html_or_view), do: html_or_view, else: render(html_or_view)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="#{role}"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    |> List.first()
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end
end
