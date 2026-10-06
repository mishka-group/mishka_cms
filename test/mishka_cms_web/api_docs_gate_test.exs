defmodule MishkaCmsWeb.ApiDocsGateTest do
  @moduledoc """
  The OpenAPI spec and the SwaggerUI/GraphiQL shells are schema introspection, not the API: between
  them they publish every route, filter and field of every resource in the CMS. They are open to any
  API admin — a bearer holding anything under `admin:api` — while `/api/json/*` itself stays open to
  any bearer token, because the resource policies are what authorize each call. A dashboard admin's
  token is refused: the dashboard's names do not count on the API.

  The spec DOCUMENT is what these tests are really about. Gating only the SwaggerUI page looked like
  a fix and was not — SwaggerUI is a client-side shell that fetches `/api/json/open_api` from the
  browser, so anyone could still `curl` the document. The route is mounted in the host router rather
  than left to `MishkaCmsWeb.AshJsonApiRouter`, which answers under the `:api` pipeline alone.

  Every request here carries a resolvable Host: the `:api` pipeline's tenant lookup answers 404
  before any permission plug runs, and a 404 would pass a "not 200" assertion while proving nothing
  about the gate.
  """
  use MishkaCmsWeb.ConnCase

  import MishkaCms.Test.Factory

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

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

    %{site: site}
  end

  defp on_site do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp request(path, token \\ nil) do
    on_site()
    |> as_browser(path)
    |> bearer(token)
    |> get(path)
  end

  # As a browser asks: GraphiQL answers a request that does not accept HTML as a GraphQL query.
  defp as_browser(conn, "/gql" <> _rest), do: put_req_header(conn, "accept", "text/html")
  defp as_browser(conn, _path), do: conn

  defp bearer(conn, nil), do: conn
  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  # A bearer token from the JSON:API sign-in, for a user of the site holding `names`.
  defp token!(site, names) do
    user = create_user!(site_id: site.id)

    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(names, &permission!(&1).id)},
      authorize?: false,
      tenant: site.id
    )
    |> Ash.update!()

    body = %{
      data: %{type: "user", attributes: %{email: to_string(user.email), password: @password}}
    }

    conn =
      on_site()
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> post("/api/json/v1/auth/user/sign-in", Jason.encode!(body))

    assert conn.status == 201, "sign-in answered #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["meta"]["token"]
  end

  test "the spec document is refused to an anonymous caller, not just the browser for it" do
    conn = request("/api/json/open_api")

    assert conn.status == 403, "/api/json/open_api answered #{conn.status} anonymously"
  end

  test "the refusal is JSON, not a crash — the :api pipeline never fetches a flash" do
    conn = request("/api/json/open_api")

    assert conn.status == 403
    assert [%{"code" => "forbidden"}] = Jason.decode!(conn.resp_body)["errors"]
  end

  test "the SwaggerUI shell is refused too" do
    conn = request("/api/json/swaggerui")

    assert conn.status == 403
  end

  test "the ungated catch-all never gets to answer the spec route" do
    # `/api/json/*` forwards to AshJsonApiRouter under `:api` alone, and that router serves
    # `/open_api` itself. If the gated route were removed or reordered after the forward, this would
    # come back 200.
    refute request("/api/json/open_api").status == 200
  end

  test "GraphiQL is refused to an anonymous caller" do
    assert request("/gql/playground").status == 403
  end

  # ANY AREA WILL DO, not one in particular: two admins of different areas, and a full API admin.
  test "an API admin of any one area reads the spec and opens both browsers", %{site: site} do
    for names <- [["admin:api:runtime:page"], ["admin:api:user"], ["admin:api:*"]],
        token = token!(site, names),
        path <- ["/api/json/open_api", "/api/json/swaggerui", "/gql/playground"] do
      conn = request(path, token)

      assert conn.status == 200, "#{path} answered #{conn.status} to #{inspect(names)}"
    end
  end

  test "a dashboard admin's token is refused all three", %{site: site} do
    token = token!(site, ["admin:dashboard:*"])

    for path <- ["/api/json/open_api", "/api/json/swaggerui", "/gql/playground"] do
      conn = request(path, token)

      assert conn.status == 403, "#{path} answered #{conn.status} to a dashboard admin"
    end
  end
end
