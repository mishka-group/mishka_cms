defmodule MishkaCmsWeb.ErrorHTMLTest do
  use MishkaCmsWeb.ConnCase
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog, only: [capture_log: 1]
  import MishkaCms.Test.Factory
  alias MishkaCms.Test.EventCannotRun
  alias MishkaCmsWeb.ErrorHTML
  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, WebRunTimeMetaDataState}
  @moduletag :unit
  @moduletag :capture_log

  describe "render custom error pages" do
    setup do
      # Create a site for testing
      site = create_site!(name: "test-site", host: "test.example.com")

      # Create custom error pages for this site
      {:ok, _error_page} =
        Ash.create(
          MishkaCmsCore.Runtime.ErrorPage,
          %{
            name: "Default Error Pages",
            path: "/mishka-cms/errors/#{site.name}",
            root_layout_template: nil,
            format: :heex,
            priority: 0,
            extra: %{
              "theme" => "modern",
              "show_navigation" => false,
              "custom_css" => "/* Custom error page styles */",
              "analytics_tracking" => true
            },
            error_pages: [
              %{
                "status" => 404,
                "template" => """
                <div class="text-center max-w-md mx-auto">
                  <div class="mb-8">
                    <h1 class="text-9xl font-bold text-blue-600 mb-4">404</h1>
                    <h2 class="text-3xl font-semibold text-gray-800 mb-4">Page Not Found</h2>
                    <p class="text-lg text-gray-600 mb-8">Sorry, the page you are looking for does not exist.</p>
                  </div>
                  <div class="space-y-4">
                    <a href="/" class="inline-block px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors duration-200">
                      Go Home
                    </a>
                    <button onclick="history.back()" class="block w-full px-6 py-3 bg-gray-100 hover:bg-gray-200 text-gray-800 font-medium rounded-lg border border-gray-300 transition-colors duration-200">
                      Go Back
                    </button>
                  </div>
                </div>
                """,
                "layout" => nil
              },
              %{
                "status" => 500,
                "template" => """
                <div class="text-center max-w-md mx-auto">
                  <div class="mb-8">
                    <h1 class="text-9xl font-bold text-red-600 mb-4">500</h1>
                    <h2 class="text-3xl font-semibold text-gray-800 mb-4">Internal Server Error</h2>
                    <p class="text-lg text-gray-600 mb-8">Something went wrong on our end. Please try again later.</p>
                  </div>
                  <div class="space-y-4">
                    <a href="/" class="inline-block px-6 py-3 bg-red-600 hover:bg-red-700 text-white font-medium rounded-lg transition-colors duration-200">
                      Go Home
                    </a>
                    <button onclick="history.back()" class="block w-full px-6 py-3 bg-gray-100 hover:bg-gray-200 text-gray-800 font-medium rounded-lg border border-gray-300 transition-colors duration-200">
                      Go Back
                    </button>
                  </div>
                </div>
                """,
                "layout" => nil
              },
              %{
                "status" => 403,
                "template" => """
                <div class="text-center max-w-md mx-auto">
                  <div class="mb-8">
                    <h1 class="text-9xl font-bold text-yellow-600 mb-4">403</h1>
                    <h2 class="text-3xl font-semibold text-gray-800 mb-4">Forbidden</h2>
                    <p class="text-lg text-gray-600 mb-8">You don't have permission to access this resource.</p>
                  </div>
                  <div class="space-y-4">
                    <a href="/" class="inline-block px-6 py-3 bg-yellow-600 hover:bg-yellow-700 text-white font-medium rounded-lg transition-colors duration-200">
                      Go Home
                    </a>
                    <button onclick="history.back()" class="block w-full px-6 py-3 bg-gray-100 hover:bg-gray-200 text-gray-800 font-medium rounded-lg border border-gray-300 transition-colors duration-200">
                      Go Back
                    </button>
                  </div>
                </div>
                """,
                "layout" => nil
              }
            ],
            helpers: [],
            active: true,
            precompile: false
          },
          tenant: site.id,
          authorize?: false
        )

      # Add the error page to the WebRunTimeMetaDataState
      error_pages =
        ErrorPage
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      # Initialize the state with the error page
      Enum.each(error_pages, fn error_page ->
        WebRunTimeMetaDataState.save(%{
          id: error_page.id,
          path: error_page.path,
          site: site.name,
          title: "Error Page - #{error_page.name}",
          created_at: error_page.inserted_at,
          section: "ErrorPage",
          priority: error_page.priority || 0
        })
      end)

      # Build a test connection with the site in assigns
      conn =
        build_conn()
        |> Plug.Conn.put_private(:phoenix_endpoint, MishkaCmsWeb.Endpoint)
        |> Plug.Conn.assign(:current_site, site)

      {:ok, conn: conn, site: site}
    end

    test "renders custom 404 error page", %{conn: conn} do
      # Render the 404 error page
      result = ErrorHTML.render("404.html", %{conn: conn})

      # Convert rendered template to string for testing
      html_content =
        case result do
          %Phoenix.LiveView.Rendered{} = rendered ->
            # Convert LiveView rendered to HTML string
            rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

          string when is_binary(string) ->
            string
        end

      # Should return custom content from the ErrorPage
      assert html_content =~ "404"
      assert html_content =~ "Page Not Found"
      assert html_content =~ "Sorry, the page you are looking for does not exist"
      assert html_content =~ "Go Home"
      assert html_content =~ "Go Back"
    end

    test "renders custom 500 error page", %{conn: conn} do
      # Render the 500 error page
      result = ErrorHTML.render("500.html", %{conn: conn})

      # Convert rendered template to string for testing
      html_content =
        case result do
          %Phoenix.LiveView.Rendered{} = rendered ->
            # Convert LiveView rendered to HTML string
            rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

          string when is_binary(string) ->
            string
        end

      # Should return custom content for 500 error
      assert html_content =~ "500"
      assert html_content =~ "Internal Server Error"
      assert html_content =~ "Something went wrong on our end"
      assert html_content =~ "Go Home"
    end

    test "renders custom 403 error page", %{conn: conn} do
      # Render the 403 error page
      result = ErrorHTML.render("403.html", %{conn: conn})

      # Convert rendered template to string for testing
      html_content =
        case result do
          %Phoenix.LiveView.Rendered{} = rendered ->
            # Convert LiveView rendered to HTML string
            rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

          string when is_binary(string) ->
            string
        end

      # Should return custom content for 403 error
      assert html_content =~ "403"
      assert html_content =~ "Forbidden"
      assert html_content =~ "You don't have permission to access this resource"
      assert html_content =~ "Go Home"
    end

    test "falls back to Phoenix default for unconfigured status codes", %{conn: conn} do
      # Try to render 401 error (not configured in our ErrorPage)
      result = ErrorHTML.render("401.html", %{conn: conn})

      # Should return default Phoenix message since 401 is not configured
      assert result == "Unauthorized"
    end

    test "falls back to Phoenix default when no error page exists", %{conn: conn, site: _site} do
      # Clear the state to simulate no error page
      # Since delete_by_site doesn't exist, we'll clear all data
      WebRunTimeMetaDataState.clear()

      # Should return default Phoenix error message
      result = ErrorHTML.render("404.html", %{conn: conn})
      assert result == "Not Found"
    end

    test "falls back to Phoenix default for a page that does not compile while ErrorHTML.Render.CompileError cannot run",
         %{conn: conn, site: site} do
      EventCannotRun.stub!("ErrorHTML.Render.CompileError")
      WebRunTimeMetaDataState.delete_by_site(site.name)
      on_exit(fn -> WebRunTimeMetaDataState.delete_by_site(site.name) end)

      [error_page] = ErrorPage |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)

      :ok =
        WebRunTimeMetaDataState.save(%{
          id: error_page.id,
          path: error_page.path,
          site: site.name,
          title: error_page.name,
          created_at: error_page.inserted_at,
          section: "ErrorPage",
          priority: 0
        })

      module = Helpers.module_name(error_page.id, site.name, "ErrorPage")
      :ok = ModuleCompiler.unload(module)
      :ok = CompileFailureState.record(module, :compilation_error)
      on_exit(fn -> CompileFailureState.clear(module) end)

      log =
        capture_log(fn ->
          assert ErrorHTML.render("404.html", %{conn: conn}) == "Not Found"
        end)

      refute log =~ "failed to render error page"
    end

    test "falls back to Phoenix default when no error page exists while ErrorHTML.Render.CompileError cannot run",
         %{conn: conn} do
      EventCannotRun.stub!("ErrorHTML.Render.CompileError")
      WebRunTimeMetaDataState.clear()

      assert ErrorHTML.render("404.html", %{conn: conn}) == "Not Found"
    end
  end

  describe "fallback behavior" do
    test "handles templates without conn in assigns" do
      # Test the fallback render function for templates without conn
      result = ErrorHTML.render("404.html", %{})
      assert result == "Not Found"
    end

    test "handles invalid template formats" do
      # Test with invalid template format (not starting with 3-digit status code)
      result = ErrorHTML.render("invalid", %{})
      assert result == "Internal Server Error"
    end
  end

  describe "telemetry events" do
    setup do
      site = create_site!(name: "telemetry-site", host: "telemetry.example.com")

      conn =
        build_conn()
        |> Plug.Conn.put_private(:phoenix_endpoint, MishkaCmsWeb.Endpoint)
        |> Plug.Conn.assign(:current_site, site)

      {:ok, conn: conn, site: site}
    end

    test "emits telemetry events when rendering error pages", %{conn: conn, site: site} do
      site_name = site.name

      # Attach telemetry handler
      :telemetry.attach(
        "test-error-render",
        [:mishka_cms, :error_page, :render],
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      # Render an error page
      _result = ErrorHTML.render("404.html", %{conn: conn})

      # Check that telemetry event was emitted
      assert_receive {:telemetry_event, %{count: 1}, %{status_code: "404", site: ^site_name}}

      # Clean up
      :telemetry.detach("test-error-render")
    end
  end
end
