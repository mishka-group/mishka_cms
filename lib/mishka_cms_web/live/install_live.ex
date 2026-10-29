# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.InstallLive do
  @moduledoc """
  First-run setup wizard: a `:config` screen (master admin + the first site's domain), a `:ui_kit`
  screen to pick which Chelekom components to install, a `:settings` screen for a few essential
  settings (site title, outgoing email) and the site's languages, then the commit through
  `MishkaCmsCore.Install.Bootstrap.run/1` and a `:done` success screen that hands off to the master
  sign-in.

  Because the installer runs before any site exists, the per-site runtime CSS/JS bundles don't exist
  yet — so it sets `standalone_assets: true`, which makes the root layout load only the prebuilt
  static LiveView client (`app.js`) for interactivity. The page carries its own styling: `shell/1`
  emits a `<style>` block of plain CSS (semantic `inst-*` classes, no utility-framework dependency,
  no external CDN), laid out as a gradient sidebar (brand, step rail, mobile progress bar) next to
  the step panel. That block is the page's ONLY dependable styling surface, and the one thing here a
  CSP nonce can be attached to — an attribute can take none, and a Tailwind class would bind the
  wizard to a build artefact a fresh deploy has no site for. So a colour that varies with state is
  expressed in the block too: the password meter marks its lit bars and its caption with `data-lvl`
  (1–4), and the block holds the four colours those levels mean.

  The sidebar rail navigates back to already-completed steps (`rail_nav`); the
  Install step is only ever entered by submitting the settings form. The page renders no flash
  messages — errors surface inline (field errors, banners). Buttons whose content includes an
  element (the arrow `<svg>`) must not use `phx-disable-with` — LiveView swaps and restores the
  button via `textContent`, which destroys element children and re-inserts raw whitespace. Their
  in-flight feedback comes from LiveView's CSS loading classes instead: wrap the label in
  `<span class="lbl">` and set `data-loading="…"` — while `phx-submit-loading`/`phx-click-loading`
  is present the CSS hides the label, shows a spinner plus the `data-loading` text, and blocks
  further clicks (buttons in a submitting form are auto-disabled as well).

  The `:settings` step is driven by the same registry the settings page uses
  (`MishkaCmsCore.Settings.definitions/0`) — it renders only the curated `@install_setting_keys` (a
  subset of the full registry) and hands them to the bootstrap, which writes them through
  `MishkaCmsCore.Settings`. The non-curated settings keep their registered defaults and are edited
  later on the settings page.

  The `:settings` step also holds the site's languages. The list starts as
  `MishkaCmsCore.Runtime.Languages.default/0`, and its FIRST code is the site's primary language.
  A search box in a form of its own (`search_languages`) narrows the codes of `Languages.known/0`
  not chosen yet, by name or code, to a list of buttons that add one (`add_language`); Enter in the
  box adds the only match when exactly one is left (`pick_language`). Every other chosen language
  can be moved to the front (`make_primary`) or removed (`remove_language`); the primary cannot be
  removed, so the list never empties. A code the list does not offer is refused. The list goes to
  the bootstrap as `:languages`, which saves it in this order to the new site's `site.languages`.
  Below it, a choice of how the site's addresses name a language (`language_urls`): no prefix for
  the primary one, the default, or a prefix for every one — see
  `MishkaCmsCore.Runtime.Languages.url_mode/1`. It goes to the bootstrap as `:language_urls`, which
  saves it to the new site's `site.language_urls`. The section sits outside the settings form, so
  the Install button submits that form through its `form` attribute.

  It is reachable only while the CMS is uninstalled: `MishkaCms.Plugs.InstallGate`
  responds `404` for this route once `MishkaCmsCore.Install.installed?/0` is true.

  See `MishkaCmsCore.Install`, `MishkaCmsCore.Install.Bootstrap` and `MishkaCmsCore.Install.UiKitCatalog`.
  """
  use MishkaCmsWeb, :live_view

  alias MishkaCmsCore.Install.{Bootstrap, Extensions, UiKitCatalog}
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Settings

  @install_setting_keys ["site.title", "mailer.from"]

  @kit_channels %{"stable" => :stable, "prerelease" => :prerelease, "master" => :master}

  # Where an operator is sent when no UI-kit package can be found anywhere.
  @support_url "https://github.com/mishka-group"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Install — Mishka CMS"),
       step: :config,
       site: nil,
       seeded?: false
     )
     # The root layout reads it.
     # credo:disable-for-next-line Jump.CredoChecks.UnusedLiveViewAssign
     |> assign(standalone_assets: true)
     |> assign(config: %{}, submitted?: false)
     |> assign(
       bundle_status: nil,
       bundle_error: nil,
       bundle_failures: [],
       bundle_sources: [],
       bundle_progress: %{},
       bundle_release: nil,
       fetch_kits: [],
       kit_channel: :stable,
       support_url: @support_url,
       kits_configured?: false,
       custom_url: "",
       custom_error: nil,
       catalog: nil,
       kits: []
     )
     |> assign(selected: MapSet.new(), required: MapSet.new(), query: "")
     |> assign(kits: [], kit_filter: nil)
     |> assign(picker_open: false, config_axes: %{}, open_config: nil)
     |> assign(
       extensions: Extensions.offered(),
       extensions_chosen: MapSet.new(),
       open_extension: nil
     )
     |> assign(settings_form: to_form(%{}, as: :settings), settings_submitted?: false)
     |> assign(languages: Languages.default(), language_error: nil, language_query: "")
     |> assign(language_urls: hd(Languages.url_modes()))
     |> assign(install_steps: init_steps(), install_error: nil, install_done: false)
     |> assign(install_total: 0, compiled_count: 0, install_origin: :settings)
     |> assign(
       dev_seeds: dev_seeds_allowed?(),
       seed_categories: dev_seed_categories(),
       seed_selected: default_seed_selected()
     )
     |> assign_form(%{})}
  end

  @impl true
  def handle_event("validate", %{"install" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("next", %{"install" => params}, socket) do
    socket = assign(socket, submitted?: true)

    case errors(params) do
      [] -> {:noreply, start_ui_kit(socket, params)}
      _ -> {:noreply, assign_form(socket, params)}
    end
  end

  def handle_event("retry_bundle", _params, socket) do
    {:noreply, load_bundle(socket)}
  end

  # A version cannot change under a download still running.
  def handle_event("kit_channel", _params, %{assigns: %{bundle_status: :loading}} = socket),
    do: {:noreply, socket}

  # Matched against the three names rather than turned into an atom: the value is the client's.
  def handle_event("kit_channel", %{"channel" => channel}, socket) do
    case Map.fetch(@kit_channels, channel) do
      {:ok, channel} -> {:noreply, socket |> assign(kit_channel: channel) |> load_bundle()}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("custom_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, custom_url: url, custom_error: nil)}
  end

  # The fetch runs in the LiveView process rather than `start_async`, because the whole picker has to
  # be rebuilt from the merged catalogue afterwards and a half-added kit is not a state worth
  # modelling. It is bounded by the download's own size limit and one retry.
  # THE SUBMITTED VALUE, not the assign. A submit carries its own params, and depending on a change
  # event having fired first is fragile — a paste-and-Enter, or an autofill, can reach here with the
  # assign still empty and the field visibly full.
  def handle_event("add_custom_kit", params, socket) do
    url = Map.get(params, "url") || socket.assigns.custom_url

    case UiKitHandler.add_custom_kit(url) do
      {:ok, _bundle} ->
        {:noreply,
         socket
         |> assign(custom_url: "", custom_error: nil)
         |> load_bundle()}

      {:error, reason} ->
        {:noreply, assign(socket, custom_url: url, custom_error: reason)}
    end
  end

  # Only meaningful with more than one kit installed, which is exactly when the chips are drawn.
  def handle_event("filter_kit", %{"kit" => kit}, socket) do
    {:noreply, assign(socket, :kit_filter, blank_kit(kit))}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, query: query)}
  end

  def handle_event("toggle", %{"name" => name}, socket) do
    if locked?(name, socket.assigns.selected, socket.assigns.required) do
      {:noreply, socket}
    else
      {:noreply, recompute(socket, toggle(socket.assigns.selected, name))}
    end
  end

  def handle_event("select_all_group", %{"group" => key}, socket) do
    {:noreply, recompute(socket, MapSet.union(socket.assigns.selected, group_names(socket, key)))}
  end

  def handle_event("unselect_all_group", %{"group" => key}, socket) do
    {:noreply,
     recompute(socket, MapSet.difference(socket.assigns.selected, group_names(socket, key)))}
  end

  def handle_event("select_all", _params, socket) do
    {:noreply, recompute(socket, MapSet.new(socket.assigns.catalog.names))}
  end

  def handle_event("clear_all", _params, socket) do
    {:noreply, recompute(socket, MapSet.new())}
  end

  def handle_event("toggle_picker", _params, socket) do
    {:noreply, assign(socket, picker_open: !socket.assigns.picker_open)}
  end

  def handle_event("toggle_config", %{"name" => name}, socket) do
    {:noreply,
     assign(socket, open_config: if(socket.assigns.open_config == name, do: nil, else: name))}
  end

  def handle_event("toggle_axis", %{"name" => name, "axis" => axis, "opt" => value}, socket) do
    {:noreply,
     assign(socket, config_axes: toggle_axis(socket.assigns.config_axes, name, axis, value))}
  end

  def handle_event("reset_config", %{"name" => name}, socket) do
    {:noreply, assign(socket, config_axes: Map.delete(socket.assigns.config_axes, name))}
  end

  def handle_event(
        "rail_nav",
        _params,
        %{assigns: %{step: :ui_kit, bundle_status: :loading}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("rail_nav", %{"index" => index}, %{assigns: %{step: step}} = socket)
      when step in [:config, :ui_kit, :settings] do
    {:noreply, rail_nav(socket, index)}
  end

  def handle_event("rail_nav", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_extension", %{"key" => key}, socket) do
    {:noreply, assign(socket, extensions_chosen: toggle(socket.assigns.extensions_chosen, key))}
  end

  # AN EXTENSION THAT WANTS NOTHING ASKED HAS NOTHING TO OPEN. Only one is open at a time, the way
  # the component configuration above behaves, so a long list stays readable.
  def handle_event("toggle_extension_fields", %{"key" => key}, socket) do
    {:noreply,
     assign(socket, open_extension: if(socket.assigns.open_extension == key, do: nil, else: key))}
  end

  def handle_event("to_settings", _params, socket) do
    {:noreply, to_settings_step(socket)}
  end

  def handle_event("back", _params, %{assigns: %{step: :settings}} = socket) do
    {:noreply, assign(socket, step: :ui_kit)}
  end

  def handle_event("back", _params, %{assigns: %{step: :installing}} = socket) do
    {:noreply, assign(socket, step: socket.assigns.install_origin)}
  end

  def handle_event("finish", _params, socket) do
    {:noreply, assign(socket, step: :done)}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :config)}
  end

  def handle_event("validate_settings", %{"settings" => params}, socket) do
    {:noreply, assign_settings_form(socket, params)}
  end

  def handle_event("search_languages", %{"language_query" => query}, socket) do
    {:noreply, assign(socket, language_query: query)}
  end

  def handle_event("pick_language", %{"language_query" => query}, socket) do
    {:noreply, pick_language(socket, query)}
  end

  def handle_event("add_language", %{"language" => code}, socket) do
    {:noreply, add_language(socket, code)}
  end

  def handle_event("make_primary", %{"code" => code}, socket) do
    {:noreply, make_primary(socket, code)}
  end

  def handle_event("remove_language", %{"code" => code}, socket) do
    {:noreply, remove_language(socket, code)}
  end

  def handle_event("language_urls", %{"language_urls" => mode}, socket) do
    if mode in Languages.url_modes(),
      do: {:noreply, assign(socket, language_urls: mode)},
      else: {:noreply, socket}
  end

  def handle_event("install", %{"settings" => params}, socket) do
    socket = assign(socket, settings_submitted?: true)

    case settings_errors(params) do
      [] -> {:noreply, commit(socket, params)}
      _ -> {:noreply, assign_settings_form(socket, params)}
    end
  end

  def handle_event("dev_seeds", _params, socket) do
    if dev_seeds_allowed?(),
      do: {:noreply, assign(socket, step: :seeds)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_seed", %{"key" => key}, socket) do
    {:noreply, assign(socket, seed_selected: toggle(socket.assigns.seed_selected, key))}
  end

  def handle_event("run_seeds", _params, socket) do
    if dev_seeds_allowed?() do
      selected = Enum.map(socket.assigns.seed_selected, &String.to_existing_atom/1)
      lv = self()

      if connected?(socket),
        do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "runtime:bulk_compile")

      {:noreply,
       socket
       |> assign(step: :installing, install_origin: :seeds, install_steps: seed_steps(selected))
       |> assign(install_error: nil, install_done: false, install_total: 0, compiled_count: 0)
       |> MishkaGervaz.Messages.start_async(:seeds, fn ->
         MishkaCmsCore.Dev.Seeds.run(selected, fn message ->
           send(lv, {:install_progress, message})
         end)
       end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  # One catalogue over every kit found on disk. With only Chelekom present this is the single-kit
  # catalogue it always was; drop the generator's headless bundle beside it and its components join
  # the same picker, labelled by their own kit and installed separately.
  def handle_async(
        :bundle,
        {:ok, %{bundles: bundles, sources: sources, failures: failures} = result},
        socket
      ) do
    catalog = UiKitCatalog.merge(List.wrap(bundles))

    {:noreply,
     socket
     |> assign(
       bundle_status: if(bundles == [], do: :missing, else: :ready),
       catalog: catalog,
       kits: kit_names(bundles),
       bundle_sources: sources,
       bundle_failures: failures,
       bundle_release: Map.get(result, :release)
     )
     |> recompute(MapSet.new())}
  end

  def handle_async(:bundle, {:exit, reason}, socket) do
    {:noreply, assign(socket, bundle_status: :error, bundle_error: inspect(reason))}
  end

  def handle_async(:install, {:ok, {:ok, %{site: site}}}, socket) do
    {:noreply,
     socket
     |> assign(site: site, install_done: true)
     |> assign(install_steps: all_done(socket.assigns.install_steps))}
  end

  def handle_async(:install, {:ok, {:error, error}}, socket) do
    {:noreply, assign(socket, install_error: error_message(error))}
  end

  def handle_async(:install, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(install_steps: fail_running_step(socket.assigns.install_steps))
     |> assign(install_error: exit_message(reason))}
  end

  def handle_async(:seeds, {:ok, core}, socket) do
    MishkaCmsCore.Install.mark_installed!()
    site = Enum.find(core.sites, &(&1.host == "localhost")) || hd(core.sites)

    {:noreply,
     socket
     |> assign(site: site, seeded?: true, install_done: true)
     |> assign(install_steps: all_done(socket.assigns.install_steps))}
  end

  def handle_async(:seeds, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(install_steps: fail_running_step(socket.assigns.install_steps))
     |> assign(install_error: exit_message(reason))}
  end

  @impl true
  def handle_info({:install_progress, {id, status, detail}}, socket) do
    {:noreply,
     assign(socket, install_steps: update_step(socket.assigns.install_steps, id, status, detail))}
  end

  def handle_info({:bulk_compile, %{name: name}}, socket) do
    count = socket.assigns.compiled_count + 1
    total = socket.assigns.install_total
    label = UiKitCatalog.label(name)
    line = if total > 0, do: "#{count}/#{total} · #{label}", else: label

    {:noreply,
     socket
     |> assign(compiled_count: count)
     |> assign(install_steps: log_running_step(socket.assigns.install_steps, line))}
  end

  # How far each official kit's download has got, for its bar on the loading screen.
  def handle_info({:kit_progress, key, sizes}, socket),
    do: {:noreply, update(socket, :bundle_progress, &Map.put(&1, key, sizes))}

  def handle_info(_message, socket), do: {:noreply, socket}

  @rail_steps [
    gettext_noop("Configuration"),
    gettext_noop("Components"),
    gettext_noop("Settings"),
    gettext_noop("Install")
  ]

  @impl true
  # Every value these translations take goes through `strong/1` or `inline_code/1`, which escape it,
  # so only the translator's own markup is raw.
  # sobelow_skip ["XSS.Raw"]
  def render(%{step: :done} = assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      title={gettext("Installation complete")}
      tight
    >
      <div id="install-done" class="inst-done-wrap">
        <div class="inst-done-badge">
          <svg
            width="46"
            height="46"
            viewBox="0 0 24 24"
            fill="none"
            stroke="var(--green)"
            stroke-width="2.2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="10" />
            <polyline points="16 9 11 14 8.5 11.5" />
          </svg>
        </div>
        <p>
          {raw(
            gettext("Your site %{host} is ready — sign in as the master admin to continue.",
              host: strong(@site.host)
            )
          )}
        </p>
        <p :if={@seeded?} class="inst-seed-note">
          {raw(
            gettext("Sample data loaded — master login %{email} / %{password}",
              email: strong("master@example.com"),
              password: strong("Password123!")
            )
          )}
        </p>
        <div class="inst-db">
          {gettext("Admin dashboard:")} <code phx-no-curly-interpolation>/admin/dashboard</code>
        </div>
        <.link
          id="install-go-login"
          navigate={master_sign_in(@site)}
          class={[btn_primary(), "inst-btn-block"]}
        >
          {gettext("Go to login")} <.svg_arrow />
        </.link>
      </div>
    </.shell>
    """
  end

  def render(%{step: :installing} = assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      title={
        if @install_origin == :seeds,
          do: gettext("Loading sample data"),
          else: gettext("Installation")
      }
      subtitle={gettext("Setting up everything your CMS needs — sit tight.")}
    >
      <ul id="install-progress" class="inst-steps-list">
        <li
          :for={step <- @install_steps}
          id={"step-#{step.id}"}
          class={["inst-istep", istep_class(step.status)]}
        >
          <div class="txt">
            <div class="nm">{step.label}</div>
            <div :for={log <- if(step.status == :running, do: step.logs, else: [])} class="sub">
              <span class="lt">{log.text}</span>
              <span class="tm">{log.at}</span>
            </div>
          </div>
          <div class="ic"><.step_icon status={step.status} /></div>
        </li>
      </ul>

      <div :if={@install_error} id="install-error" class="inst-banner is-red">
        <b>{gettext("Installation failed")}</b>
        <p>{@install_error}</p>
      </div>

      <div :if={@install_error} class="inst-actions">
        <button id="install-error-back" type="button" phx-click="back" class={btn_ghost()}>
          <.svg_back />
          {if @install_origin == :seeds,
            do: gettext("Back to sample data"),
            else: gettext("Back to settings")}
        </button>
      </div>

      <div :if={@install_done} id="install-complete" class="inst-banner">
        <b>{gettext("Installation complete")}</b>
        <p>{gettext("Every step finished. Continue to sign in as the master admin.")}</p>
      </div>

      <div :if={@install_done} class="inst-actions is-end">
        <button id="install-finish" type="button" phx-click="finish" class={btn_primary()}>
          {gettext("Continue")} <.svg_arrow />
        </button>
      </div>
    </.shell>
    """
  end

  def render(%{step: :settings} = assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      title={gettext("Essential settings")}
      subtitle={gettext("A couple of basics to finish setup — you can change them any time later.")}
    >
      <div id="installer-settings">
        <.form
          for={@settings_form}
          id="install-settings-form"
          phx-change="validate_settings"
          phx-submit="install"
        >
          <h3 class="inst-sec-h"><.svg_gear /> {gettext("Basics")}</h3>
          <.field
            :for={definition <- install_settings()}
            field={@settings_form[definition.key]}
            id={"install-set-#{String.replace(definition.key, ".", "-")}"}
            label={Settings.text(definition.label) || definition.key}
            hint={Settings.text(definition.description)}
          />

          <%!-- NOT A CHOICE: every page of the site, an extension's included, is drawn in the starter's
                header and footer (`MishkaCmsCore.Runtime.SiteLayout`). Ticked and disabled, so it
                says what the install does and submits nothing: `MishkaCmsCore.Install.Bootstrap`
                writes it whatever arrives. --%>
          <label id="install-starter-content" class="inst-smp-row is-fixed">
            <input type="checkbox" checked disabled aria-disabled="true" class="inst-cbox" />
            <span class="nm">
              {gettext("Add a starter home page")}
              <span class="ex">
                {gettext("always added, with the header and footer every page is drawn in")}
              </span>
            </span>
          </label>
        </.form>

        <div class="inst-divider"></div>

        <.language_picker
          languages={@languages}
          error={@language_error}
          query={@language_query}
          language_urls={@language_urls}
        />

        <div class="inst-actions">
          <button id="settings-back" type="button" phx-click="back" class={btn_ghost()}>
            <.svg_back /> {gettext("Back")}
          </button>
          <button
            id="install-settings-submit"
            type="submit"
            form="install-settings-form"
            data-loading={gettext("Installing…")}
            class={btn_primary()}
          >
            <span class="lbl">{gettext("Install")} <.svg_arrow /></span>
          </button>
        </div>
      </div>
    </.shell>
    """
  end

  # Every value these translations take goes through `strong/1` or `inline_code/1`, which escape it,
  # so only the translator's own markup is raw.
  # sobelow_skip ["XSS.Raw"]
  def render(%{step: :ui_kit} = assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      wide={@picker_open}
      busy={@bundle_status == :loading}
      title={gettext("Choose what to install")}
      subtitle={
        gettext(
          "Ready-made pieces for building your pages, and the features your site runs on. What every site needs is selected already — carry straight on, or open a section to add more."
        )
      }
    >
      <div id="installer-uikit">
        <%!-- WHICH CHELEKOM. The newest stable release, then the newest pre-release, then the files
              on master: the first that has the kits is fetched as soon as this step opens, and the
              chip lit is the one it came from. The chips stay on the page while it downloads, but
              cannot be changed until it has finished. A host that names its kits in config gets
              those, and no choice. --%>
        <div :if={not @kits_configured?} id="uikit-channel" class="inst-channel">
          <span class="gl" id="uikit-channel-label">{gettext("Kit version")}</span>
          <div class="inst-chips" role="radiogroup" aria-labelledby="uikit-channel-label">
            <button
              :for={{channel, label} <- kit_channel_options()}
              type="button"
              id={"uikit-channel-#{channel}"}
              role="radio"
              aria-checked={to_string(shown_channel(@kit_channel, @bundle_release) == channel)}
              disabled={@bundle_status == :loading}
              phx-click="kit_channel"
              phx-value-channel={channel}
              class={[
                "inst-chip",
                shown_channel(@kit_channel, @bundle_release) == channel && "on"
              ]}
            >
              {label}
            </button>
          </div>
          <p
            :if={@bundle_status == :ready and !match?(%{fallback?: true}, @bundle_release)}
            class="inst-hint"
            id="uikit-channel-note"
          >
            {channel_note(@bundle_release)}
          </p>
        </div>

        <%= cond do %>
          <% @bundle_status == :loading -> %>
            <div id="uikit-loading" class="inst-fetch is-inline" role="status" aria-live="polite">
              <div class="inst-fetch-head">
                <div class="inst-ring is-run"></div>
                {gettext("Fetching %{kits}…", kits: official_kit_summary())}
              </div>
              <%!-- One row per package, because a 12 MB kit and a 1.6 MB one finish minutes apart
                    on a slow line, and a single spinner said nothing about which was still coming. --%>
              <ul :if={@fetch_kits != []} class="inst-fetch-list">
                <li
                  :for={kit <- @fetch_kits}
                  id={"uikit-fetch-#{kit.key}"}
                  class="inst-fetch-row"
                >
                  <div class="inst-fetch-top">
                    <span class="inst-fetch-name">{Settings.text(kit.label)}</span>
                    <span :if={kit[:tag]} class="inst-kit-ver">{kit.tag}</span>
                    <span class="inst-fetch-size">{fetch_size(@bundle_progress[kit.key])}</span>
                  </div>
                  <progress
                    class="inst-fetch-bar"
                    aria-label={Settings.text(kit.label)}
                    {fetch_value(@bundle_progress[kit.key])}
                  ></progress>
                </li>
              </ul>
            </div>
          <% @bundle_status == :error -> %>
            <div id="uikit-error" class="inst-banner is-amber">
              <b>{gettext("No UI-kit bundle could be loaded.")}</b>
              <p>{@bundle_error}</p>
              <%!-- It used to say "place chelekom.json in priv/cms_ui_kits/", which is advice a
                    reader cannot act on when the download is what failed and they have no copy to
                    place. Name the packages and the versions instead, so they can check the tag or
                    reach for their own bundle. --%>
              <p :for={kit <- @fetch_kits}>
                <code>{Settings.text(kit.label)}</code>{kit[:tag] && " · #{kit.tag}"}
              </p>
              <p>
                {raw(
                  gettext("Retry, or drop a bundle into %{path} and reload.",
                    path: inline_code("priv/cms_ui_kits/")
                  )
                )}
              </p>
              <button
                id="uikit-retry"
                type="button"
                phx-click="retry_bundle"
                class={[btn_ghost(), "inst-mt"]}
              >
                {gettext("Retry download")}
              </button>
            </div>
          <% @bundle_status == :missing -> %>
            <%!-- NOTHING ANYWHERE: no release attaches the kits and master does not hold them either.
                  The site still installs without them; the operator needs to know whom to tell. --%>
            <div id="uikit-missing" class="inst-banner is-amber">
              <b>{gettext("The UI-kit packages could not be found.")}</b>
              <p>{missing_reason(@bundle_failures)}</p>
              <p>
                {gettext(
                  "Please contact Mishka CMS support. You can retry, or carry on and add the components later from the admin."
                )}
              </p>
              <div class="inst-banner-acts">
                <a
                  id="uikit-support"
                  href={@support_url}
                  target="_blank"
                  rel="noopener"
                  class={btn_ghost()}
                >
                  {gettext("Contact Mishka CMS support")}
                </a>
                <button id="uikit-retry" type="button" phx-click="retry_bundle" class={btn_ghost()}>
                  {gettext("Retry download")}
                </button>
              </div>
            </div>
          <% match?(%{fallback?: true}, @bundle_release) -> %>
            <div id="uikit-channel-fallback" class="inst-banner is-amber is-inline">
              <%= if @bundle_release.channel == :master do %>
                <b>{gettext("No release has the UI kits yet.")}</b>
                <p>
                  {gettext(
                    "Using the files on Chelekom's master branch, which may change at any time."
                  )}
                </p>
              <% else %>
                <b>{gettext("No stable release has the UI kits yet.")}</b>
                <p>
                  {gettext("Using pre-release %{tag}, the newest release that has them.",
                    tag: @bundle_release.tag
                  )}
                </p>
              <% end %>
            </div>
          <% true -> %>
        <% end %>

        <%!-- Everything below waits for the download: on the page, but not clickable. --%>
        <div
          id="uikit-sections"
          class={["inst-sections", @bundle_status == :loading && "is-busy"]}
          inert={@bundle_status == :loading}
        >
          <%!-- ONE package failing is not an error state: the step still installs everything it
                  did reach. But it has to say what is missing, or an operator wonders later why
                  half a kit is absent and has nothing to search for. --%>
          <div
            :if={@bundle_status == :ready and @bundle_failures != []}
            id="uikit-partial"
            class="inst-banner is-amber is-inline"
          >
            <div class="inst-banner-head">
              <b>
                {gettext("%{count} package(s) could not be fetched.",
                  count: length(@bundle_failures)
                )}
              </b>
              <button
                id="uikit-partial-retry"
                type="button"
                phx-click="retry_bundle"
                class={btn_ghost()}
              >
                {gettext("Retry")}
              </button>
            </div>
            <%!-- The URL is the longest thing here and the least often read — printed whole it
                    wrapped to three lines and pushed the module card off the fold. Elided to host +
                    filename, with the rest on `title` and one click away on the clipboard. --%>
            <div :for={failure <- @bundle_failures} class="inst-fail">
              <span>{Settings.text(failure.label)} · {failure.tag} — {failure.reason}</span>
              <%!-- Hover or focus for the whole URL, click to copy it. No `title` attribute: the
                      native tooltip waits a second, cannot be styled, and would sit on top of this
                      one. --%>
              <span class="inst-tip-wrap">
                <button
                  id={"uikit-fail-url-#{failure.key}"}
                  type="button"
                  phx-hook="CopyToClipboard"
                  data-copy={failure.url}
                  aria-label={
                    gettext("Copy the URL for %{label}", label: Settings.text(failure.label))
                  }
                  class="inst-copy"
                >
                  {short_source(failure.url)}
                </button>
                <span class="inst-tip" role="tooltip">{failure.url}</span>
              </span>
            </div>
            <p>
              {gettext("Everything below is what did load — install the rest later from the admin.")}
            </p>
          </div>
          <%!-- ADD A PACKAGE WE DO NOT SHIP. The only route to a third-party kit at install time
                  was placing a file on disk, which an operator running a released image cannot do.
                  The disclaimer is shown BEFORE anything is fetched, not after it succeeds — by
                  then the components are already in their admin. --%>
          <details class="inst-custom" id="uikit-custom">
            <summary>{gettext("Add a package by URL")}</summary>
            <div class="inst-custom-body">
              <%!-- RED, where the fetch-failure banner above is amber. They can be on screen
                      together, and two identical-looking alerts read as one message split in half.
                      The colours also rank correctly: a package that did not download is a nuisance,
                      someone else's code running in your admin is a risk. --%>
              <div class="inst-banner is-red is-inline" id="uikit-custom-warning">
                <b>{gettext("Packages from outside the official channels are not ours.")}</b>
                <p>
                  {gettext(
                    "Mishka takes no responsibility for them: their components run inside your admin and render on your visitors' pages. Install only from a source you trust."
                  )}
                </p>
              </div>
              <form
                id="uikit-custom-form"
                phx-change="custom_url"
                phx-submit="add_custom_kit"
                class="inst-custom-row"
              >
                <input
                  type="url"
                  name="url"
                  id="uikit-custom-url"
                  value={@custom_url}
                  placeholder="https://example.com/my-kit.json"
                  class={["inst-inp", @custom_error && "has-error"]}
                  autocomplete="off"
                />
                <button
                  type="submit"
                  id="uikit-custom-add"
                  disabled={@custom_url == ""}
                  class={btn_ghost()}
                  data-loading={gettext("Fetching…")}
                >
                  {gettext("Fetch")}
                </button>
              </form>
              <p :if={@custom_error} class="inst-error" id="uikit-custom-error">{@custom_error}</p>
              <p :if={is_nil(@custom_error)} class="inst-hint">
                {raw(
                  gettext(
                    "A %{schema} JSON. It is checked and cached beside the official packages before anything is installed.",
                    schema: inline_code("mishka.ui_kit.bundle.v3")
                  )
                )}
              </p>
            </div>
          </details>
          <%!-- Until the first download lands there is nothing to list yet. --%>
          <div :if={is_nil(@catalog)} id="uikit-waiting" class="inst-mod">
            <div class="inst-mod-head">
              <div class="inst-mod-ico"><.svg_grid /></div>
              <div>
                <div class="t">{gettext("Page building blocks")}</div>
                <div class="s">{gettext("They appear here once the UI kits are downloaded.")}</div>
              </div>
            </div>
          </div>
          <div :if={@catalog && MapSet.size(@catalog.names) > 0} class="inst-mod">
            <div class="inst-mod-head">
              <div class="inst-mod-ico"><.svg_grid /></div>
              <div>
                <%!-- The card named one kit even with two on disk. It says what is actually
                        there, which is also the first place someone notices a second kit at all. --%>
                <div class="t">{kit_card_title(@kits)}</div>
                <div class="s" id="uikit-count">
                  <%!-- "base variant by default" describes the narrowing this install performs,
                          in the vocabulary of the person who built it. What a reader needs to know
                          is that the plain style is installed and the rest is optional. --%>
                  {gettext("%{selected} of %{total} chosen · plain style, extras optional",
                    selected: MapSet.size(MapSet.union(@selected, @required)),
                    total: MapSet.size(@catalog.names)
                  )}
                </div>
                <%!-- WHICH VERSION IS BEING INSTALLED. The card said what and how many but never
                        which — and pinning the packages is worth nothing to an operator who cannot
                        see the pin. The `sources` come from the resolver rather than being joined
                        back to config by filename, which would be a guess. --%>
                <div :if={@bundle_sources != []} class="inst-kit-vers" id="uikit-versions">
                  <span :for={source <- @bundle_sources} class="inst-kit-ver">
                    {source.name} {version_label(source)}
                  </span>
                </div>
              </div>
              <button
                type="button"
                id="uikit-toggle"
                phx-click="toggle_picker"
                class={["inst-mod-cust", @picker_open && "open"]}
              >
                {if @picker_open, do: gettext("Hide"), else: gettext("Customize")}
                <span class="ch"><.svg_chev /></span>
              </button>
            </div>

            <div :if={@picker_open} id="uikit-body" class="inst-mod-body">
              <div class="inst-comp-tools">
                <form id="install-search-form" phx-change="search" class="inst-search">
                  <.svg_search />
                  <input
                    type="text"
                    name="query"
                    value={@query}
                    placeholder={gettext("Search components…")}
                    phx-debounce="150"
                  />
                </form>
                <button
                  id="uikit-select-all"
                  type="button"
                  phx-click="select_all"
                  class="inst-mini-btn"
                >
                  {gettext("Select all")}
                </button>
                <button
                  id="uikit-clear-all"
                  type="button"
                  phx-click="clear_all"
                  class="inst-mini-btn"
                >
                  {gettext("Clear")}
                </button>
              </div>

              <%!-- Two kits on disk means two vocabularies in one picker — a styled Chelekom button
                      and a headless one sit side by side under "Forms" and read identically. The
                      chips and the badges are drawn only when there IS a second kit, so a stock
                      install looks exactly as it always did. --%>
              <div :if={length(@kits) > 1} class="inst-kits">
                <button
                  type="button"
                  id="kit-all"
                  phx-click="filter_kit"
                  phx-value-kit="all"
                  class={["inst-kit-chip", is_nil(@kit_filter) && "on"]}
                >
                  {gettext("All kits")}
                </button>
                <button
                  :for={kit <- @kits}
                  type="button"
                  id={"kit-#{kit}"}
                  phx-click="filter_kit"
                  phx-value-kit={kit}
                  class={["inst-kit-chip", @kit_filter == kit && "on"]}
                >
                  {UiKitCatalog.kit_label(kit)}
                </button>
              </div>

              <section
                :for={group <- visible_groups(@catalog, @query, @kit_filter)}
                id={"group-#{group.key}"}
                class="inst-cat"
              >
                <div class="inst-cat-h">
                  <b>{group.label}</b>
                  <span class="c">
                    ({group_selected_count(group, @selected, @required)}/{length(group.entries)})
                  </span>
                  <span class="an">
                    <button type="button" phx-click="select_all_group" phx-value-group={group.key}>
                      {gettext("All")}
                    </button>
                    <button
                      type="button"
                      phx-click="unselect_all_group"
                      phx-value-group={group.key}
                    >
                      {gettext("None")}
                    </button>
                  </span>
                </div>
                <ul class={["inst-cat-grid", length(@kits) > 1 && "kits"]}>
                  <%= for entry <- group.entries do %>
                    <li
                      id={"comp-#{entry.name}"}
                      class={["inst-citem", checked?(entry.name, @selected, @required) && "on"]}
                    >
                      <input
                        type="checkbox"
                        id={"toggle-#{entry.name}"}
                        checked={checked?(entry.name, @selected, @required)}
                        disabled={locked?(entry.name, @selected, @required)}
                        phx-click="toggle"
                        phx-value-name={entry.name}
                        class="inst-cbox"
                      />
                      <label for={"toggle-#{entry.name}"} class="nm">{entry.label}</label>
                      <span :if={length(@kits) > 1 and entry[:kit]} class="inst-kit-tag">
                        {UiKitCatalog.kit_label(entry.kit)}
                      </span>
                      <span
                        :if={locked?(entry.name, @selected, @required)}
                        title={
                          gettext("Required by %{names}",
                            names:
                              Enum.join(
                                UiKitCatalog.required_by(@catalog, @selected, entry.name),
                                ", "
                              )
                          )
                        }
                        class="inst-required"
                      >
                        <.svg_lock /> {gettext("required")}
                      </span>
                      <button
                        :if={configurable?(entry, @selected, @required)}
                        type="button"
                        id={"config-#{entry.name}"}
                        phx-click="toggle_config"
                        phx-value-name={entry.name}
                        title={gettext("Configure options")}
                        class={[
                          "inst-cfg-btn",
                          (@open_config == entry.name or Map.has_key?(@config_axes, entry.name)) &&
                            "act"
                        ]}
                      >
                        <.svg_sliders />
                      </button>
                    </li>
                    <li
                      :if={@open_config == entry.name}
                      id={"config-panel-#{entry.name}"}
                      class="inst-optpanel"
                    >
                      <div class="oh">
                        <.svg_sliders />
                        <span>{entry.label}</span>
                        <button
                          type="button"
                          class="rst"
                          phx-click="reset_config"
                          phx-value-name={entry.name}
                        >
                          {gettext("Reset defaults")}
                        </button>
                      </div>
                      <div :for={{axis, cfg} <- ordered_config(entry)} class="inst-ogroup">
                        <div class="gl">{axis}</div>
                        <div class="inst-chips">
                          <label
                            :for={value <- cfg.values}
                            class={[
                              "inst-chip",
                              axis_checked?(@config_axes, entry.name, axis, value, cfg.default) &&
                                "on",
                              value == cfg.default && "def"
                            ]}
                          >
                            <input
                              type="checkbox"
                              checked={
                                axis_checked?(@config_axes, entry.name, axis, value, cfg.default)
                              }
                              disabled={value == cfg.default}
                              phx-click="toggle_axis"
                              phx-value-name={entry.name}
                              phx-value-axis={axis}
                              phx-value-opt={value}
                            />
                            {if value == cfg.default,
                              do: gettext("%{value} · default", value: value),
                              else: value}
                          </label>
                        </div>
                      </div>
                    </li>
                  <% end %>
                </ul>
              </section>

              <p :if={visible_groups(@catalog, @query, @kit_filter) == []} class="inst-empty">
                {gettext("No components match “%{query}”.", query: @query)}
              </p>
            </div>
          </div>

          <%!-- EVERY EXTENSION THAT REGISTERED ITSELF, and nothing written down here. The list is
                  `MishkaInstaller`'s own registry of plugins on `installer:extension:install`, so an
                  extension that is installed offers itself and one that is not cannot appear. --%>
          <div :if={@extensions != []} class="inst-mod">
            <div class="inst-mod-head">
              <div class="inst-mod-ico"><.svg_box /></div>
              <div>
                <div class="t">{gettext("Extensions")}</div>
                <div class="s">
                  {gettext(
                    "Tick what this site should start with. Everything here can also be set up later, from its own menu."
                  )}
                </div>
              </div>
            </div>

            <div class="inst-mod-body">
              <ul id="install-extensions" class="inst-ext-list">
                <li
                  :for={extension <- @extensions}
                  id={"extension-#{extension.key}"}
                  class={["inst-ext", MapSet.member?(@extensions_chosen, extension.key) && "on"]}
                >
                  <label class="inst-ext-row">
                    <input
                      type="checkbox"
                      id={"toggle-extension-#{extension.key}"}
                      checked={MapSet.member?(@extensions_chosen, extension.key)}
                      phx-click="toggle_extension"
                      phx-value-key={extension.key}
                      class="inst-cbox"
                    />
                    <span class="nm">
                      <span class="t">{Settings.text(extension.label)}</span>
                      <span :if={extension.summary != ""} class="s">
                        {Settings.text(extension.summary)}
                      </span>
                    </span>
                  </label>

                  <%!-- ASKED ONLY WHEN IT IS WANTED. An extension declaring no fields has nothing
                          to open, and one that does is asked only once it has been ticked. --%>
                  <button
                    :if={extension.fields != [] and MapSet.member?(@extensions_chosen, extension.key)}
                    type="button"
                    phx-click="toggle_extension_fields"
                    phx-value-key={extension.key}
                    class={["inst-mod-cust", @open_extension == extension.key && "open"]}
                  >
                    {gettext("Settings")} <span class="ch"><.svg_chev /></span>
                  </button>

                  <div
                    :if={
                      @open_extension == extension.key and
                        MapSet.member?(@extensions_chosen, extension.key)
                    }
                    id={"extension-fields-#{extension.key}"}
                    class="inst-ext-fields"
                  >
                    <div :for={field <- extension.fields} class="inst-field">
                      <label for={"extension-#{extension.key}-#{field_name(field)}"}>
                        {field_label(field)}
                      </label>
                      <input
                        type="text"
                        id={"extension-#{extension.key}-#{field_name(field)}"}
                        name={"settings[extensions][#{extension.key}][#{field_name(field)}]"}
                        class="inst-inp"
                      />
                      <p :if={field_hint(field) != ""} class="inst-hint">{field_hint(field)}</p>
                    </div>
                  </div>
                </li>
              </ul>
            </div>
          </div>

          <div class="inst-actions">
            <button id="uikit-back" type="button" phx-click="back" class={btn_ghost()}>
              <.svg_back /> {gettext("Back")}
            </button>
            <button
              id="uikit-next"
              type="button"
              phx-click="to_settings"
              disabled={@bundle_status == :loading}
              class={btn_primary()}
            >
              {gettext("Next: settings")} <.svg_arrow />
            </button>
          </div>
        </div>
      </div>
    </.shell>
    """
  end

  # Every value these translations take goes through `strong/1` or `inline_code/1`, which escape it,
  # so only the translator's own markup is raw.
  # sobelow_skip ["XSS.Raw"]
  def render(%{step: :seeds} = assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      title={gettext("Load sample data")}
      subtitle={gettext("For local development only — sample master, sites, users and content.")}
    >
      <div id="installer-seeds">
        <div class="inst-smp">
          <label
            :for={category <- @seed_categories}
            id={"seed-#{category.key}"}
            class="inst-smp-row"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@seed_selected, to_string(category.key))}
              phx-click="toggle_seed"
              phx-value-key={category.key}
              class="inst-cbox"
            />
            <span class="nm">{category.label}</span>
          </label>
          <p class="inst-smp-note">
            {raw(
              gettext(
                "Core data (sites, users, permissions) and every UI-kit component are %{included}.",
                included: strong(gettext("always included"))
              )
            )}<br />
            {raw(
              gettext("Master login will be %{email} / %{password}",
                email: strong("master@example.com"),
                password: strong("Password123!")
              )
            )}
          </p>
        </div>

        <div class="inst-actions">
          <button id="seeds-back" type="button" phx-click="back" class={btn_ghost()}>
            <.svg_back /> {gettext("Back")}
          </button>
          <button
            id="seeds-run"
            type="button"
            phx-click="run_seeds"
            data-loading={gettext("Seeding…")}
            class={btn_primary()}
          >
            <span class="lbl">{gettext("Load sample data")} <.svg_arrow /></span>
          </button>
        </div>
      </div>
    </.shell>
    """
  end

  # Every value these translations take goes through `strong/1` or `inline_code/1`, which escape it,
  # so only the translator's own markup is raw.
  # sobelow_skip ["XSS.Raw"]
  def render(assigns) do
    ~H"""
    <.shell
      step={@step}
      config={@config}
      catalog={@catalog}
      title={gettext("Configuration")}
      subtitle={gettext("Set up your master admin and your first site.")}
    >
      <.form for={@form} id="install-form" phx-change="validate" phx-submit="next" novalidate>
        <h3 class="inst-sec-h"><.svg_user /> {gettext("Master Admin")}</h3>
        <.field
          field={@form[:email]}
          label={gettext("Email")}
          type="email"
          placeholder="admin@example.com"
          autocomplete="email"
        />
        <.field
          field={@form[:password]}
          label={gettext("Password")}
          type="password"
          placeholder={gettext("At least 8 characters")}
          autocomplete="new-password"
        >
          <:extra><.strength_meter password={@form[:password].value} /></:extra>
        </.field>
        <.field
          field={@form[:password_confirmation]}
          label={gettext("Confirm password")}
          type="password"
          placeholder={gettext("Re-enter password")}
          autocomplete="new-password"
        />

        <div class="inst-divider"></div>

        <h3 class="inst-sec-h"><.svg_globe /> {gettext("Website")}</h3>
        <.field
          field={@form[:site_name]}
          label={gettext("Site name")}
          placeholder={gettext("My CMS")}
        />
        <.field field={@form[:host]} label={gettext("Domain")} placeholder="example.com">
          <:extra>
            <p class="inst-hint">
              {raw(
                gettext("For local development you can use %{host}.", host: inline_code("localhost"))
              )}
            </p>
          </:extra>
        </.field>

        <button
          id="install-next"
          type="submit"
          data-loading={gettext("Checking…")}
          class={[btn_primary(), "inst-btn-block"]}
        >
          <span class="lbl">{gettext("Next: choose components")} <.svg_arrow /></span>
        </button>
      </.form>

      <button
        :if={@dev_seeds}
        id="install-dev-seeds"
        type="button"
        phx-click="dev_seeds"
        class="inst-link-sub"
      >
        {gettext("⚡ Or load sample data for development")}
      </button>
    </.shell>
    """
  end

  attr :step, :atom, required: true
  attr :config, :map, default: %{}
  attr :catalog, :any, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :wide, :boolean, default: false
  attr :tight, :boolean, default: false
  attr :busy, :boolean, default: false
  slot :inner_block, required: true

  defp shell(assigns) do
    index = rail_index(assigns.step)

    assigns =
      assigns
      |> assign(rail_index: index, rail_steps: Enum.map(@rail_steps, &translate_step/1))
      |> assign(can_nav: Map.new(0..3, &{&1, rail_can?(&1, index, assigns)}))

    ~H"""
    <style phx-no-curly-interpolation nonce={assigns[:csp_nonce]}>
      :root{
        --blue:#2563eb; --blue-d:#1d4ed8; --blue-l:#eff4ff;
        --ink:#0f172a; --ink-2:#334155; --dim:#64748b; --faint:#94a3b8;
        --line:#e6e9ef; --line-2:#eef1f6; --bg:#ffffff; --bg-2:#f8fafc;
        --green:#16a34a; --green-l:#f0fdf4; --amber:#f59e0b;
        --side-1:#0b1830; --side-2:#123a6b; --side-3:#155e63;
        --r:12px;
      }
      *{box-sizing:border-box}
      html,body{margin:0;padding:0}
      body{font-family:'Inter',ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
        color:var(--ink);background:var(--bg-2);-webkit-font-smoothing:antialiased;
        font-size:15px;line-height:1.55}
      button{font-family:inherit}
      ::selection{background:#bcd4ff}

      .inst-shell{display:flex;min-height:100vh}

      /* sidebar */
      .inst-aside{width:340px;flex-shrink:0;position:sticky;top:0;height:100vh;
        background:linear-gradient(160deg,var(--side-1) 0%,var(--side-2) 52%,var(--side-3) 100%);
        color:#fff;display:flex;flex-direction:column;padding:40px 36px;overflow:hidden}
      .inst-aside::before{content:"";position:absolute;inset:0;background:
        radial-gradient(600px 340px at 80% 6%,rgba(255,255,255,.10),transparent 60%),
        radial-gradient(520px 380px at 6% 96%,rgba(20,220,180,.12),transparent 60%);
        pointer-events:none}
      .inst-brand{display:flex;align-items:center;gap:14px;position:relative;z-index:1}
      .inst-logo-tile{width:52px;height:52px;border-radius:14px;background:linear-gradient(150deg,#ffd54a,#fbbf24);
        display:grid;place-items:center;box-shadow:0 10px 24px -8px rgba(251,191,36,.6),inset 0 1px 0 rgba(255,255,255,.5);flex-shrink:0}
      .inst-logo-tile img{width:32px;height:32px;display:block}
      .inst-brand h1{font-size:22px;font-weight:800;margin:0;letter-spacing:-.02em}
      .inst-brand-v{font-size:11px;font-weight:600;color:rgba(255,255,255,.55);
        font-family:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:2px}
      .inst-tagline{margin-top:22px;font-size:14.5px;line-height:1.6;color:rgba(255,255,255,.72);
        position:relative;z-index:1;max-width:230px}

      /* step rail */
      .inst-rail{margin-top:44px;position:relative;z-index:1;display:flex;flex-direction:column;gap:2px}
      .inst-rstep{display:flex;align-items:center;gap:14px;padding:11px 0;position:relative}
      .inst-rdot{width:30px;height:30px;border-radius:50%;flex-shrink:0;display:grid;place-items:center;
        font-size:12.5px;font-weight:700;border:1.5px solid rgba(255,255,255,.28);
        color:rgba(255,255,255,.6);transition:all .3s;background:rgba(255,255,255,.04)}
      .inst-rstep.done .inst-rdot{background:#fff;border-color:#fff;color:var(--side-2)}
      .inst-rstep.active .inst-rdot{background:#ffd54a;border-color:#ffd54a;color:#3a2c00;
        box-shadow:0 0 0 5px rgba(255,213,74,.18)}
      .inst-rlabel{font-size:14px;font-weight:500;color:rgba(255,255,255,.55);transition:color .3s}
      .inst-rstep.active .inst-rlabel{color:#fff;font-weight:600}
      .inst-rstep.done .inst-rlabel{color:rgba(255,255,255,.85)}
      .inst-rline{position:absolute;left:14.5px;top:41px;width:1.5px;height:14px;background:rgba(255,255,255,.18)}
      .inst-rstep.done .inst-rline{background:rgba(255,255,255,.55)}
      .inst-rstep.can{cursor:pointer;border-radius:8px;transition:background .15s}
      .inst-rstep.can:hover{background:rgba(255,255,255,.06)}
      .inst-rstep.can:hover .inst-rlabel{color:#fff}

      .inst-side-foot{margin-top:auto;position:relative;z-index:1;display:flex;gap:22px;padding-top:30px}
      .inst-side-foot a{color:rgba(255,255,255,.6);font-size:13px;text-decoration:none;
        display:inline-flex;align-items:center;gap:6px;transition:color .2s}
      .inst-side-foot a:hover{color:#fff}

      /* content */
      .inst-main{flex:1;display:flex;flex-direction:column;align-items:center;padding:64px 32px 80px;overflow-y:auto}
      .inst-panel{width:100%;max-width:560px;animation:inst-rise .4s ease}
      .inst-panel.is-wide{max-width:820px}
      @keyframes inst-rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
      .inst-phead{text-align:center;margin-bottom:38px}
      .inst-phead.is-tight{margin-bottom:0}
      .inst-phead h2{font-size:30px;font-weight:800;letter-spacing:-.025em;margin:0 0 8px}
      .inst-phead p{color:var(--dim);font-size:15px;margin:0;line-height:1.55}

      .inst-sec-h{display:flex;align-items:center;gap:10px;font-size:16px;font-weight:700;margin:0 0 18px}
      .inst-sec-h svg{color:var(--blue)}

      .inst-field{margin-bottom:18px}
      .inst-field label{display:block;font-size:13px;font-weight:600;color:var(--ink-2);margin-bottom:7px}
      .inst-inp{width:100%;padding:12px 14px;border:1.5px solid var(--line);border-radius:10px;
        font-size:14.5px;font-family:inherit;color:var(--ink);background:#fff;
        transition:border-color .15s,box-shadow .15s;outline:none}
      .inst-inp::placeholder{color:var(--faint)}
      .inst-inp:focus{border-color:var(--blue);box-shadow:0 0 0 4px var(--blue-l)}
      .inst-inp.has-error{border-color:#fca5a5}
      .inst-inp.has-error:focus{border-color:#ef4444;box-shadow:0 0 0 4px rgba(239,68,68,.12)}
      .inst-hint{font-size:12.5px;color:var(--faint);margin:6px 0 0}
      .inst-hint code{background:var(--bg-2);border:1px solid var(--line);border-radius:5px;padding:1px 6px;font-size:11.5px}
      .inst-error{font-size:12.5px;color:#dc2626;margin:6px 0 0}

      .inst-divider{height:1px;background:var(--line-2);margin:30px 0}

      /* languages */
      .inst-lang-list{display:flex;flex-wrap:wrap;gap:8px;list-style:none;margin:0 0 16px;padding:0}
      .inst-lang{display:inline-flex;flex-wrap:wrap;align-items:center;gap:6px 8px;max-width:100%;
        padding:6px 8px 6px 13px;border:1.5px solid var(--line);border-radius:99px;background:#fff;
        font-size:13.5px}
      .inst-lang.is-primary{border-color:var(--blue);background:var(--blue-l);padding-right:10px}
      .inst-lang .nm,.inst-lang-opt .nm{font-weight:600;color:var(--ink)}
      .inst-lang .cd,.inst-lang-opt .cd{font-family:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
        font-size:11px;color:var(--faint)}
      .inst-lang-dir{font-size:10.5px;font-weight:600;color:var(--dim);background:#f1f5f9;
        border-radius:99px;padding:2px 8px;white-space:nowrap}
      .inst-lang-badge{font-size:10.5px;font-weight:600;color:#fff;background:var(--blue);
        border-radius:99px;padding:2px 8px;white-space:nowrap}
      .inst-lang-mk{border:none;background:none;border-radius:99px;padding:3px 8px;cursor:pointer;
        font-size:11.5px;font-weight:600;color:var(--blue);outline:none;transition:background .12s;
        white-space:nowrap}
      .inst-lang-mk:hover,.inst-lang-mk:focus-visible{background:var(--blue-l)}
      .inst-lang-mk:focus-visible{box-shadow:0 0 0 2px var(--blue)}
      .inst-lang-rm{width:24px;height:24px;border-radius:50%;border:none;background:none;
        color:var(--faint);cursor:pointer;display:grid;place-items:center;padding:0;outline:none}
      .inst-lang-rm:hover,.inst-lang-rm:focus-visible{background:#fef2f2;color:#dc2626}
      .inst-lang-rm:focus-visible{box-shadow:0 0 0 2px #fca5a5}
      .inst-lang-find{position:relative}
      .inst-lang-find svg{position:absolute;left:14px;top:50%;transform:translateY(-50%);
        color:var(--faint);pointer-events:none}
      .inst-lang-find .inst-inp{padding:12px 14px 12px 40px}
      .inst-lang-opts{display:flex;flex-direction:column;gap:2px;margin-top:8px;padding:4px;
        max-height:264px;overflow-y:auto;overscroll-behavior:contain;
        border:1.5px solid var(--line);border-radius:10px;background:#fff}
      .inst-lang-opt{display:flex;align-items:center;gap:8px;width:100%;flex-shrink:0;
        padding:8px 10px;border:none;border-radius:7px;background:none;cursor:pointer;
        font-size:13.5px;text-align:start;color:var(--ink-2);outline:none;transition:background .12s}
      .inst-lang-opt:hover{background:var(--bg-2)}
      .inst-lang-opt:focus-visible{background:var(--blue-l);box-shadow:inset 0 0 0 1.5px var(--blue)}
      .inst-lang-opt .add{margin-left:auto;display:grid;place-items:center;color:var(--faint);
        transition:color .12s}
      .inst-lang-opt:hover .add,.inst-lang-opt:focus-visible .add{color:var(--blue)}
      .inst-lang-none{margin:8px 0 0;padding:16px;text-align:center;font-size:13.5px;color:var(--faint);
        border:1.5px dashed var(--line);border-radius:10px}
      .inst-lang-opts~.inst-hint,.inst-lang-opts~.inst-error,
      .inst-lang-none~.inst-hint,.inst-lang-none~.inst-error{margin-top:10px}
      .inst-urls{border:none;margin:0;padding:0;min-width:0}
      .inst-urls legend{display:block;font-size:13px;font-weight:600;color:var(--ink-2);
        margin-bottom:7px;padding:0}
      .inst-urls .inst-smp-row{padding:10px 12px;flex-wrap:wrap}
      .inst-urls .ex{display:inline-flex;flex-wrap:wrap;gap:6px;margin-left:6px}
      .inst-urls code{background:var(--bg-2);border:1px solid var(--line);border-radius:5px;
        padding:1px 6px;font-size:11.5px;font-weight:500;color:var(--dim)}
      .inst-radio{width:18px;height:18px;margin:0;accent-color:var(--blue);cursor:pointer;flex-shrink:0}

      /* password strength */
      .inst-meter{display:flex;gap:5px;margin-top:9px}
      .inst-meter i{height:4px;flex:1;border-radius:99px;background:var(--line);transition:background .25s}
      .inst-mtxt{font-size:12px;color:var(--faint);margin-top:6px}
      .inst-meter i[data-lvl="1"]{background:#ef4444}
      .inst-meter i[data-lvl="2"]{background:#f59e0b}
      .inst-meter i[data-lvl="3"]{background:#3b82f6}
      .inst-meter i[data-lvl="4"]{background:#16a34a}
      .inst-mtxt[data-lvl="1"]{color:#ef4444}
      .inst-mtxt[data-lvl="2"]{color:#f59e0b}
      .inst-mtxt[data-lvl="3"]{color:#3b82f6}
      .inst-mtxt[data-lvl="4"]{color:#16a34a}

      /* buttons */
      .inst-actions{display:flex;align-items:center;justify-content:space-between;margin-top:34px;gap:12px}
      .inst-actions.is-end{justify-content:flex-end}
      .inst-btn{border:none;cursor:pointer;font-weight:600;font-size:14px;border-radius:10px;
        padding:12px 20px;display:inline-flex;align-items:center;gap:8px;transition:all .18s;
        white-space:nowrap;text-decoration:none}
      .inst-btn-primary{background:var(--blue);color:#fff;box-shadow:0 8px 20px -8px rgba(37,99,235,.6)}
      .inst-btn-primary:hover{background:var(--blue-d);transform:translateY(-1px);box-shadow:0 12px 24px -8px rgba(37,99,235,.7)}
      .inst-btn-primary:disabled{background:#c7d2e8;box-shadow:none;cursor:not-allowed;transform:none}
      .inst-btn-ghost{background:#fff;color:var(--ink-2);border:1.5px solid var(--line)}
      .inst-btn-ghost:hover{border-color:#cdd5e3;background:var(--bg-2)}
      .inst-btn-block{width:100%;justify-content:center;padding:14px}
      .inst-btn .lbl{display:inline-flex;align-items:center;gap:8px}
      .inst-btn.phx-submit-loading,.inst-btn.phx-click-loading{pointer-events:none}
      .inst-btn-primary.phx-submit-loading,.inst-btn-primary.phx-click-loading{
        background:var(--blue);opacity:.85;box-shadow:none;transform:none}
      .inst-btn[data-loading].phx-submit-loading .lbl,
      .inst-btn[data-loading].phx-click-loading .lbl{display:none}
      .inst-btn[data-loading].phx-submit-loading::before,
      .inst-btn[data-loading].phx-click-loading::before{content:"";width:14px;height:14px;
        flex-shrink:0;border-radius:50%;border:2px solid rgba(255,255,255,.35);
        border-top-color:#fff;animation:inst-spin .7s linear infinite}
      .inst-btn[data-loading].phx-submit-loading::after,
      .inst-btn[data-loading].phx-click-loading::after{content:attr(data-loading)}
      .inst-link-sub{display:block;text-align:center;margin-top:18px;background:none;border:none;
        color:var(--blue);font-size:13.5px;font-weight:600;cursor:pointer;width:100%}
      .inst-link-sub:hover{text-decoration:underline}
      .inst-mt{margin-top:12px}

      /* module rows (collapsed installable units) */
      .inst-mod{border:1.5px solid var(--line);border-radius:14px;background:#fff;overflow:hidden;margin-bottom:12px}
      .inst-mod.is-soon{opacity:.85}
      .inst-mod-head{display:flex;align-items:center;gap:14px;padding:16px 18px}
      .inst-mod-ico{width:40px;height:40px;border-radius:10px;background:var(--blue-l);color:var(--blue);
        display:grid;place-items:center;flex-shrink:0}
      .inst-mod-ico.soon{background:#f1f5f9;color:var(--faint)}
      .inst-mod-head .t{font-weight:700;font-size:15px}
      .inst-mod-head .s{font-size:12.5px;color:var(--dim);margin-top:2px}
      .inst-mod-cust{margin-left:auto;color:var(--blue);font-weight:600;font-size:13.5px;
        display:inline-flex;align-items:center;gap:5px;background:none;border:none;cursor:pointer;
        padding:8px 10px;border-radius:8px}
      .inst-mod-cust:hover{background:var(--blue-l)}
      .inst-mod-cust .ch{transition:transform .25s;display:inline-flex}
      .inst-mod-cust.open .ch{transform:rotate(180deg)}
      .inst-soon-tag{margin-left:auto;font-size:11px;font-weight:700;letter-spacing:.04em;color:var(--amber);
        background:#fffbeb;border:1px solid #fde68a;padding:4px 10px;border-radius:99px}
      .inst-mod-body{border-top:1px solid var(--line-2);padding:16px 18px 18px;animation:inst-rise .3s}

      /* extensions */
      .inst-ext-list{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:10px}
      .inst-ext{border:1.5px solid var(--line);border-radius:12px;padding:12px 14px;background:#fff}
      .inst-ext.on{border-color:var(--blue);background:var(--blue-l)}
      .inst-ext-row{display:flex;align-items:flex-start;gap:12px;cursor:pointer}
      .inst-ext-row .nm{display:flex;flex-direction:column;gap:2px}
      .inst-ext-row .t{font-weight:700;font-size:14px}
      .inst-ext-row .s{font-size:12.5px;color:var(--dim)}
      .inst-ext-fields{margin-top:12px;padding-top:12px;border-top:1px solid var(--line-2)}
      .inst-ext-fields .inst-field:last-child{margin-bottom:0}

      /* component picker */
      .inst-comp-tools{display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap}
      .inst-kits{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:12px}
      .inst-kit-chip{padding:5px 12px;border:1.5px solid var(--line);border-radius:999px;
        background:#fff;font-size:11.5px;font-weight:700;color:var(--faint);cursor:pointer}
      .inst-kit-chip.on{border-color:#17161a;background:#17161a;color:#fff}
      .inst-custom{margin-bottom:18px;border:1.5px solid var(--line);border-radius:12px;background:#fff}
      .inst-custom>summary{cursor:pointer;padding:13px 16px;font-size:13px;font-weight:700;
        color:var(--ink-2);list-style:none}
      .inst-custom>summary::-webkit-details-marker{display:none}
      /* A trailing space inside `content` collapses, so the marker sat against the label. */
      .inst-custom>summary::before{content:"+";color:var(--faint);margin-right:7px}
      .inst-custom[open]>summary::before{content:"\2212"}
      .inst-custom>summary:hover{color:var(--ink)}
      /* THE CONTAINER OWNS THE SPACING. This was `padding:0 …` plus a `margin-top` on the banner —
         same specificity as `.inst-banner.is-inline`'s `margin:0 …` and earlier in the file, so the
         later rule silently won and the banner sat welded to the divider. Padding cannot be
         cancelled by a sibling's margin shorthand. */
      .inst-custom-body{padding:16px;border-top:1px solid var(--line-2)}
      .inst-custom-row{display:flex;gap:8px;align-items:center;margin-top:16px}
      .inst-custom-row .inst-inp{flex:1;min-width:0}
      .inst-custom-body .inst-hint,
      .inst-custom-body .inst-error{margin-top:10px}
      .inst-kit-vers{display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}
      .inst-kit-ver{padding:1px 6px;border-radius:5px;background:#f2f1ec;font-size:9.5px;
        font-weight:700;color:var(--faint);white-space:nowrap}
      .inst-kit-tag{margin-left:auto;padding:1px 6px;border-radius:5px;background:#f2f1ec;
        font-size:9.5px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;
        color:var(--faint);flex:none;white-space:nowrap}
      /* A kit badge on every row costs the name its width, and "combobox" became "comb…". With
         badges on, the columns are wide enough for both. */
      .inst-cat-grid.kits{grid-template-columns:repeat(auto-fill,minmax(230px,1fr))}
      .inst-search{flex:1;min-width:160px;position:relative}
      .inst-search svg{position:absolute;left:12px;top:50%;transform:translateY(-50%);color:var(--faint)}
      .inst-search input{width:100%;padding:9px 12px 9px 34px;border:1.5px solid var(--line);
        border-radius:9px;font-size:13.5px;outline:none;font-family:inherit;background:#fff;color:var(--ink)}
      .inst-search input::placeholder{color:var(--faint)}
      .inst-search input:focus{border-color:var(--blue);box-shadow:0 0 0 3px var(--blue-l)}
      .inst-mini-btn{padding:9px 14px;border:1.5px solid var(--line);background:#fff;border-radius:9px;
        font-size:13px;font-weight:600;color:var(--ink-2);cursor:pointer}
      .inst-mini-btn:hover{background:var(--bg-2)}
      .inst-cat{margin-top:14px}
      .inst-cat-h{display:flex;align-items:center;gap:8px;margin-bottom:8px}
      .inst-cat-h b{font-size:14px}
      .inst-cat-h .c{font-size:12px;color:var(--faint);font-weight:500}
      .inst-cat-h .an{margin-left:auto;display:flex;gap:8px}
      .inst-cat-h .an button{background:none;border:none;color:var(--blue);font-size:12.5px;font-weight:600;cursor:pointer}
      .inst-cat-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));
        gap:2px 10px;list-style:none;margin:0;padding:0}
      .inst-citem{display:flex;align-items:center;gap:9px;padding:6px 8px;border-radius:8px;
        cursor:pointer;font-size:13.5px;transition:background .12s;position:relative}
      .inst-citem:hover{background:var(--bg-2)}
      .inst-citem .nm{color:var(--ink-2);cursor:pointer;overflow:hidden;text-overflow:ellipsis;
        white-space:nowrap;min-width:0}
      .inst-citem.on .nm{color:var(--ink)}
      .inst-cbox{appearance:none;-webkit-appearance:none;width:18px;height:18px;border-radius:5px;
        border:1.5px solid #cbd5e1;flex-shrink:0;background:#fff center/12px no-repeat;
        margin:0;cursor:pointer;transition:all .15s}
      .inst-cbox:checked{background-color:var(--blue);border-color:var(--blue);
        background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23fff' stroke-width='3.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpolyline points='20 6 9 17 4 12'/%3E%3C/svg%3E")}
      .inst-cbox:disabled{opacity:.5;cursor:not-allowed}
      .inst-required{display:inline-flex;align-items:center;gap:4px;border-radius:99px;
        background:#f1f5f9;color:var(--faint);padding:2px 8px;font-size:10.5px;font-weight:600;flex-shrink:0}
      .inst-cfg-btn{margin-left:auto;color:var(--faint);background:none;border:none;cursor:pointer;
        padding:3px;border-radius:6px;display:grid;place-items:center;opacity:.6;transition:all .15s}
      .inst-cfg-btn:hover{color:var(--blue);background:var(--blue-l);opacity:1}
      .inst-cfg-btn.act{color:var(--blue);opacity:1}
      .inst-empty{padding:20px 0;text-align:center;color:var(--faint);font-size:13.5px;margin:0}

      /* per-component option panel */
      .inst-optpanel{grid-column:1/-1;border:1.5px solid var(--line);border-radius:11px;
        background:var(--bg-2);padding:14px 16px;margin:6px 0 10px;animation:inst-rise .25s}
      .inst-optpanel .oh{font-weight:700;font-size:13.5px;margin-bottom:12px;display:flex;align-items:center;gap:8px}
      .inst-optpanel .oh svg{color:var(--blue)}
      .inst-optpanel .oh .rst{margin-left:auto;font-size:12px;font-weight:600;color:var(--blue);
        background:none;border:none;cursor:pointer}
      .inst-ogroup{margin-bottom:12px}
      .inst-ogroup:last-child{margin-bottom:0}
      .inst-ogroup .gl{font-size:10.5px;font-weight:700;letter-spacing:.06em;color:var(--faint);
        margin-bottom:7px;text-transform:uppercase}
      .inst-chips{display:flex;flex-wrap:wrap;gap:6px}
      .inst-chip{font-size:12px;padding:5px 11px;border:1.5px solid var(--line);border-radius:99px;
        background:#fff;color:var(--ink-2);cursor:pointer;transition:all .12s;font-weight:500;
        display:inline-flex;align-items:center;position:relative}
      .inst-chip:hover{border-color:#cbd5e1}
      .inst-chip.on{background:var(--blue);border-color:var(--blue);color:#fff}
      .inst-chip.def{border-style:dashed}
      .inst-chip input{position:absolute;opacity:0;width:1px;height:1px;margin:0}

      /* sample data list */
      .inst-smp{border:1.5px solid var(--line);border-radius:14px;background:#fff;padding:8px 6px}
      .inst-smp-row{display:flex;align-items:center;gap:12px;padding:13px 16px;cursor:pointer;border-radius:10px}
      .inst-smp-row:hover{background:var(--bg-2)}
      .inst-smp-row.is-fixed{cursor:default}
      .inst-smp-row.is-fixed:hover{background:none}
      .inst-smp-row .nm{font-weight:600;font-size:14.5px}
      .inst-smp-row .ex{font-size:12.5px;color:var(--faint);margin-left:2px;font-weight:400}
      .inst-smp-note{border-top:1px solid var(--line-2);margin:6px 0 0;padding:14px 16px 8px;
        font-size:12.5px;color:var(--dim);line-height:1.55}
      .inst-smp-note strong{color:var(--ink-2)}

      /* install progress */
      .inst-steps-list{display:flex;flex-direction:column;list-style:none;margin:0;padding:0}
      .inst-istep{display:flex;align-items:center;gap:14px;padding:16px 4px;border-bottom:1px solid var(--line-2)}
      .inst-istep:last-child{border-bottom:none}
      .inst-istep .txt{flex:1;min-width:0}
      .inst-istep .nm{font-size:15px;font-weight:600;color:var(--faint);transition:color .3s}
      .inst-istep .sub{display:none;font-size:12.5px;color:var(--faint);margin-top:3px;
        align-items:center;justify-content:space-between;gap:10px}
      .inst-istep.run .nm,.inst-istep.done .nm{color:var(--ink)}
      .inst-istep.run .nm{color:var(--blue)}
      .inst-istep.run .sub{display:flex;color:var(--dim)}
      .inst-istep.error .nm{color:#dc2626}
      .inst-istep .sub .lt{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .inst-istep .sub .tm{flex-shrink:0;font-family:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
        font-size:10px;font-variant-numeric:tabular-nums;color:var(--faint)}
      .inst-istep .ic{width:26px;height:26px;flex-shrink:0;display:grid;place-items:center}
      .inst-ring{width:22px;height:22px;border-radius:50%;border:2px solid var(--line)}
      .inst-ring.is-run{border-color:var(--blue);border-top-color:transparent;animation:inst-spin .7s linear infinite}
      @keyframes inst-spin{to{transform:rotate(360deg)}}
      .inst-loading{display:flex;align-items:center;justify-content:center;gap:12px;
        padding:64px 0;color:var(--blue);font-weight:600;font-size:14.5px}
      /* The UI-kit download: a row per package, its bar drawn by `<progress>` itself, since this
         page's CSP admits no inline `style` to size a div with. */
      .inst-fetch{padding:44px 0 34px;animation:inst-rise .4s}
      /* Which Chelekom: the release channel, as the step's own chips. */
      .inst-channel{display:flex;flex-wrap:wrap;align-items:center;gap:8px 12px;margin:0 0 18px}
      .inst-channel .gl{font-size:10.5px;font-weight:700;letter-spacing:.06em;color:var(--faint);
        text-transform:uppercase}
      .inst-channel .inst-hint{flex-basis:100%;margin:0}
      .inst-chip:disabled{opacity:.55;cursor:not-allowed}
      /* The download box sits under the chips; what follows waits, visibly, until it is done. */
      .inst-fetch.is-inline{padding:4px 0 22px}
      .inst-fetch.is-inline .inst-fetch-head{justify-content:flex-start}
      .inst-fetch.is-inline .inst-fetch-list{margin:14px 0 0;max-width:none}
      .inst-sections.is-busy{opacity:.5;transition:opacity .2s}
      .inst-banner-acts{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
      .inst-fetch-head{display:flex;align-items:center;justify-content:center;gap:12px;
        color:var(--blue);font-weight:600;font-size:14.5px}
      .inst-fetch-list{list-style:none;margin:26px auto 0;padding:0;max-width:460px;display:grid;
        grid-template-columns:minmax(0,1fr);gap:10px}
      .inst-fetch-row{min-width:0;background:var(--bg);border:1px solid var(--line);
        border-radius:var(--r);padding:12px 14px 13px}
      /* On a narrow screen the size drops under the name rather than pushing the row wider. */
      .inst-fetch-top{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;margin-bottom:9px}
      .inst-fetch-name{flex:0 1 auto;min-width:0;font-size:13px;font-weight:600;color:var(--ink-2);
        overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .inst-fetch-top .inst-kit-ver{flex:none}
      .inst-fetch-size{margin-left:auto;flex-shrink:0;font-size:11px;color:var(--dim);
        font-family:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
        font-variant-numeric:tabular-nums}
      .inst-fetch-bar{display:block;width:100%;height:6px;border:0;border-radius:99px;overflow:hidden;
        background:var(--line-2);-webkit-appearance:none;appearance:none}
      .inst-fetch-bar::-webkit-progress-bar{background:var(--line-2);border-radius:99px}
      .inst-fetch-bar::-webkit-progress-value{background:var(--blue);border-radius:99px;transition:width .25s}
      .inst-fetch-bar::-moz-progress-bar{background:var(--blue);border-radius:99px}
      .inst-fetch-bar:indeterminate{background:linear-gradient(90deg,var(--line-2) 0%,var(--blue-l) 35%,
        #bcd4ff 50%,var(--blue-l) 65%,var(--line-2) 100%) 0 0/200% 100%;animation:inst-shimmer 1.3s linear infinite}
      .inst-fetch-bar:indeterminate::-webkit-progress-bar{background:transparent}
      .inst-fetch-bar:indeterminate::-moz-progress-bar{background:transparent}
      @keyframes inst-shimmer{to{background-position:-200% 0}}
      @media(prefers-reduced-motion:reduce){.inst-fetch-bar:indeterminate{animation:none}}

      .inst-banner{margin-top:26px;border:1.5px solid #bbf7d0;background:var(--green-l);
        border-radius:12px;padding:16px 18px;animation:inst-rise .4s}
      .inst-banner b{color:#166534;font-size:14.5px}
      .inst-banner p{margin:4px 0 0;font-size:13px;color:#15803d}
      .inst-banner.is-red{border-color:#fecaca;background:#fef2f2}
      .inst-banner.is-red b{color:#991b1b}
      .inst-banner.is-red p{color:#b91c1c}
      .inst-banner.is-amber{border-color:#fde68a;background:#fffbeb}
      .inst-banner.is-amber b{color:#92400e}
      .inst-banner.is-amber p{color:#b45309}
      .inst-banner code{background:#fff;border:1px solid var(--line);border-radius:5px;padding:1px 6px;font-size:11.5px}
      /* Sits ABOVE the module card rather than below the step, so it carries its own bottom gap —
         `.inst-banner`'s margin-top alone left it glued to the card underneath. */
      .inst-banner.is-inline{margin:0 0 18px;padding:13px 16px}
      .inst-banner-head{display:flex;align-items:center;gap:12px}
      .inst-banner-head b{flex:1;min-width:0}
      .inst-fail{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:9px;
        font-size:12.5px;color:#b45309}
      .inst-copy{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
        font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11.5px;
        background:#fff;border:1px solid #fde68a;border-radius:5px;padding:2px 7px;
        color:#92400e;cursor:pointer}
      .inst-copy:hover{border-color:#d97706;background:#fffdf7}
      /* The admin's popover treatment, rebuilt in this page's own stylesheet: the installer runs
         before any site exists and loads no Tailwind, so the shared component cannot come with it. */
      .inst-tip-wrap{position:relative;display:inline-flex;max-width:100%}
      .inst-tip{position:absolute;bottom:calc(100% + 7px);left:0;z-index:5;display:none;
        width:max-content;max-width:min(430px,78vw);background:#1c1b22;color:#fff;
        border-radius:10px;padding:8px 11px;font-size:11px;line-height:1.55;word-break:break-all;
        font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
        box-shadow:0 10px 30px -8px rgba(0,0,0,.5);pointer-events:none}
      .inst-tip-wrap:hover .inst-tip,
      .inst-tip-wrap:focus-within .inst-tip{display:block}

      /* done */
      .inst-done-wrap{text-align:center;margin-top:34px}
      .inst-done-badge{width:88px;height:88px;border-radius:50%;background:var(--green-l);
        display:grid;place-items:center;margin:0 auto 24px;animation:inst-pop .5s cubic-bezier(.34,1.56,.64,1)}
      @keyframes inst-pop{from{transform:scale(0)}to{transform:scale(1)}}
      .inst-done-wrap p{color:var(--ink-2);font-size:15.5px;line-height:1.6;margin:0 0 8px}
      .inst-done-wrap .inst-db{font-size:13px;color:var(--dim);margin-bottom:28px}
      .inst-done-wrap .inst-db code{background:var(--bg-2);border:1px solid var(--line);
        border-radius:6px;padding:2px 8px;font-size:12px}
      .inst-seed-note{display:inline-block;margin:6px auto 14px;background:#fffbeb;
        border:1.5px solid #fde68a;border-radius:10px;padding:10px 16px;font-size:13px;color:#92400e}

      /* mobile */
      .inst-mtop{display:none}
      @media(max-width:860px){
        .inst-shell{flex-direction:column}
        .inst-aside{width:100%;height:auto;position:static;padding:22px 22px 20px;
          flex-direction:row;align-items:center;gap:16px}
        .inst-aside::before{background:radial-gradient(400px 200px at 90% 0,rgba(255,255,255,.1),transparent 60%)}
        .inst-tagline,.inst-rail,.inst-side-foot{display:none}
        .inst-brand{flex:1}
        .inst-logo-tile{width:44px;height:44px;border-radius:12px}
        .inst-logo-tile img{width:27px;height:27px}
        .inst-brand h1{font-size:19px}
        .inst-mtop{display:block;margin-left:auto;position:relative;z-index:1;text-align:right}
        .inst-mtop .st{font-size:11px;font-weight:600;color:rgba(255,255,255,.55);
          font-family:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace}
        .inst-mtop .lb{font-size:13.5px;font-weight:600;color:#fff;margin-top:2px}
        .inst-mtop .mbar{display:flex;gap:5px;margin-top:8px;justify-content:flex-end}
        .inst-mtop .mbar i{width:22px;height:4px;border-radius:99px;background:rgba(255,255,255,.25)}
        .inst-mtop .mbar i.on{background:#ffd54a}
        .inst-main{padding:38px 20px 60px}
        .inst-phead h2{font-size:25px}
        .inst-actions{flex-direction:row}
      }
      @media(max-width:520px){
        .inst-cat-grid{grid-template-columns:1fr 1fr}
        .inst-actions .inst-btn{padding:12px 16px;font-size:13.5px}
      }
    </style>
    <div class="inst-shell">
      <aside class="inst-aside">
        <div class="inst-brand">
          <div class="inst-logo-tile"><img src="/images/mishka-logo.svg" alt="Mishka" /></div>
          <div>
            <h1>Mishka CMS</h1>
            <div class="inst-brand-v">
              {gettext("SETUP WIZARD · v%{version}", version: MishkaCmsCore.Helpers.host_version())}
            </div>
          </div>
        </div>
        <div class="inst-mtop">
          <div class="st">{gettext("STEP %{step} / 4", step: min(@rail_index + 1, 4))}</div>
          <div class="lb">{Enum.at(@rail_steps, min(@rail_index, 3))}</div>
          <div class="mbar">
            <i :for={i <- 0..3} class={i <= @rail_index && "on"}></i>
          </div>
        </div>
        <p class="inst-tagline">
          {gettext("A modular, multi-tenant content platform built with Elixir, Phoenix & Ash.")}
        </p>
        <nav class="inst-rail">
          <div
            :for={{label, i} <- Enum.with_index(@rail_steps)}
            id={"rail-step-#{i}"}
            class={["inst-rstep", rail_state(i, @rail_index), @can_nav[i] && "can"]}
            phx-click={@can_nav[i] && "rail_nav"}
            phx-value-index={i}
          >
            <div class="inst-rdot">
              <.svg_check :if={i < @rail_index} />
              <span :if={i >= @rail_index}>{i + 1}</span>
            </div>
            <div class="inst-rlabel">{label}</div>
            <span :if={i < length(@rail_steps) - 1} class="inst-rline"></span>
          </div>
        </nav>
        <div class="inst-side-foot">
          <a href="https://github.com/mishka-group" target="_blank" rel="noopener">
            <.svg_github /> GitHub
          </a>
          <a href="https://elixirforum.com" target="_blank" rel="noopener">
            {gettext("Need help?")}
          </a>
        </div>
      </aside>

      <main class="inst-main">
        <div class={["inst-panel", @wide && "is-wide"]}>
          <div :if={@title} class={["inst-phead", @tight && "is-tight"]}>
            <h2>{@title}</h2>
            <p :if={@subtitle}>{@subtitle}</p>
          </div>
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  defp rail_index(:config), do: 0
  defp rail_index(:ui_kit), do: 1
  defp rail_index(:settings), do: 2
  defp rail_index(:installing), do: 3
  defp rail_index(:done), do: 4
  defp rail_index(:seeds), do: 10

  defp rail_state(i, index) when i < index, do: "done"
  defp rail_state(i, index) when i == index, do: "active"
  defp rail_state(_i, _index), do: nil

  # While the kits download, the step they belong to is the only place to be.
  defp rail_can?(_i, _index, %{busy: true}), do: false

  defp rail_can?(i, index, %{step: step} = assigns),
    do: step in [:config, :ui_kit, :settings] and i != index and rail_open?(i, assigns)

  defp rail_open?(0, _assigns), do: true
  defp rail_open?(1, %{config: config}), do: config != %{}
  defp rail_open?(2, %{config: config, catalog: catalog}), do: config != %{} and catalog != nil
  defp rail_open?(_i, _assigns), do: false

  defp rail_nav(socket, "0"), do: assign(socket, step: :config)

  defp rail_nav(%{assigns: %{config: config}} = socket, "1") when map_size(config) > 0,
    do: start_ui_kit(socket, config)

  defp rail_nav(%{assigns: %{config: config, catalog: catalog}} = socket, "2")
       when map_size(config) > 0 and not is_nil(catalog),
       do: to_settings_step(socket)

  defp rail_nav(socket, _index), do: socket

  attr :id, :string, default: nil
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil
  attr :rest, :global, include: ~w(autocomplete)
  slot :extra

  defp field(assigns) do
    ~H"""
    <div class="inst-field">
      <label for={@id || @field.id}>{@label}</label>
      <input
        type={@type}
        id={@id || @field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        placeholder={@placeholder}
        class={["inst-inp", @field.errors != [] && "has-error"]}
        {@rest}
      />
      {render_slot(@extra)}
      <p :if={@hint} class="inst-hint">{@hint}</p>
      <p :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="inst-error">
        {msg}
      </p>
    </div>
    """
  end

  attr :languages, :list, required: true
  attr :error, :string, default: nil
  attr :query, :string, default: ""
  attr :language_urls, :string, required: true

  defp language_picker(assigns) do
    assigns =
      assign(assigns,
        primary: List.first(assigns.languages),
        needle: String.trim(assigns.query),
        matches: matching_languages(assigns.languages, assigns.query)
      )

    ~H"""
    <section id="install-languages">
      <h3 class="inst-sec-h"><.svg_globe /> {gettext("Languages")}</h3>
      <ul id="install-language-list" class="inst-lang-list">
        <li
          :for={code <- @languages}
          id={"install-language-#{code}"}
          class={["inst-lang", code == @primary && "is-primary"]}
        >
          <span class="nm">{Languages.name(code)}</span>
          <span class="cd">{code}</span>
          <span :if={Languages.direction(code) == "rtl"} class="inst-lang-dir">
            {gettext("right to left")}
          </span>
          <span :if={code == @primary} class="inst-lang-badge">{gettext("primary")}</span>
          <button
            :if={code != @primary}
            id={"install-language-primary-#{code}"}
            type="button"
            phx-click="make_primary"
            phx-value-code={code}
            aria-label={
              gettext("Make %{language} the primary language", language: Languages.name(code))
            }
            class="inst-lang-mk"
          >
            {gettext("Make primary")}
          </button>
          <button
            :if={code != @primary}
            id={"install-language-remove-#{code}"}
            type="button"
            phx-click="remove_language"
            phx-value-code={code}
            aria-label={gettext("Remove %{language}", language: Languages.name(code))}
            class="inst-lang-rm"
          >
            <.svg_x />
          </button>
        </li>
      </ul>
      <div class="inst-field">
        <form
          id="install-language-search-form"
          phx-change="search_languages"
          phx-submit="pick_language"
        >
          <label for="install-language-search">{gettext("Add a language")}</label>
          <div class="inst-lang-find">
            <.svg_search />
            <input
              id="install-language-search"
              type="text"
              name="language_query"
              value={@query}
              placeholder={gettext("Search by name or code…")}
              autocomplete="off"
              spellcheck="false"
              role="combobox"
              aria-autocomplete="list"
              aria-expanded={to_string(@matches != [])}
              aria-controls="install-language-options"
              phx-debounce="150"
              class="inst-inp"
            />
          </div>
        </form>
        <div
          :if={@matches != []}
          id="install-language-options"
          role="listbox"
          aria-label={gettext("Languages to add")}
          class="inst-lang-opts"
        >
          <button
            :for={code <- @matches}
            id={"install-language-option-#{code}"}
            type="button"
            role="option"
            aria-selected="false"
            phx-click="add_language"
            phx-value-language={code}
            class="inst-lang-opt"
          >
            <span class="nm">{Languages.name(code)}</span>
            <span class="cd">{code}</span>
            <span :if={Languages.direction(code) == "rtl"} class="inst-lang-dir">
              {gettext("right to left")}
            </span>
            <span class="add"><.svg_plus /></span>
          </button>
        </div>
        <p :if={@matches == [] and @needle != ""} id="install-language-none" class="inst-lang-none">
          {gettext("No language matches “%{query}”.", query: @needle)}
        </p>
        <p :if={@matches == [] and @needle == ""} id="install-language-all" class="inst-lang-none">
          {gettext("Every language this install offers is on the list.")}
        </p>
        <p :if={@error} id="install-language-error" class="inst-error">{@error}</p>
        <p :if={is_nil(@error)} class="inst-hint">
          {gettext(
            "A visitor whose address names no language is answered in the primary one. Every page this install writes answers each language here; the settings page changes the list later."
          )}
        </p>
      </div>
      <form id="install-language-urls-form" phx-change="language_urls" class="inst-field">
        <fieldset class="inst-urls">
          <legend>{gettext("Language in addresses")}</legend>
          <label
            :for={{mode, title, examples} <- url_choices(@languages)}
            id={"install-language-urls-#{mode}"}
            class="inst-smp-row"
          >
            <input
              type="radio"
              name="language_urls"
              value={mode}
              checked={mode == @language_urls}
              class="inst-radio"
            />
            <span class="nm">
              {title}
              <span class="ex">
                <code :for={example <- examples} dir="ltr">{example}</code>
              </span>
            </span>
          </label>
        </fieldset>
        <p class="inst-hint">
          {gettext("Pages keep their paths either way; the settings page changes this later.")}
        </p>
      </form>
    </section>
    """
  end

  attr :password, :any, default: nil

  defp strength_meter(assigns) do
    password = to_string(assigns.password || "")
    assigns = assign(assigns, score: password_score(password), show: password != "")

    ~H"""
    <div :if={@show}>
      <div class="inst-meter">
        <i :for={i <- 1..4} data-lvl={i <= @score && @score}></i>
      </div>
      <div :if={@score >= 1} class="inst-mtxt" data-lvl={@score}>
        {gettext("Password strength: %{strength}", strength: strength_label(@score))}
      </div>
    </div>
    """
  end

  defp password_score(password) do
    Enum.count(
      [
        String.length(password) >= 8,
        String.match?(password, ~r/[A-Z]/) and String.match?(password, ~r/[a-z]/),
        String.match?(password, ~r/\d/),
        String.match?(password, ~r/[^A-Za-z0-9]/)
      ],
      & &1
    )
  end

  defp strength_label(1), do: gettext("Weak")
  defp strength_label(2), do: gettext("Fair")
  defp strength_label(3), do: gettext("Good")
  defp strength_label(4), do: gettext("Strong")
  defp strength_label(_score), do: ""

  defp translate_step(step), do: Gettext.gettext(MishkaCmsWeb.Gettext, step)

  defp strong(text), do: "<strong>#{Plug.HTML.html_escape(to_string(text))}</strong>"

  defp inline_code(text), do: "<code>#{Plug.HTML.html_escape(to_string(text))}</code>"

  defp btn_primary, do: "inst-btn inst-btn-primary"

  defp btn_ghost, do: "inst-btn inst-btn-ghost"

  defp istep_class(:done), do: "done"
  defp istep_class(:running), do: "run"
  defp istep_class(:error), do: "error"
  defp istep_class(_status), do: nil

  attr :status, :atom, required: true

  defp step_icon(%{status: :done} = assigns) do
    ~H"""
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="none"
      stroke="var(--green)"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <polyline points="16 9 11 14 8.5 11.5" />
    </svg>
    """
  end

  defp step_icon(%{status: :running} = assigns) do
    ~H"""
    <div class="inst-ring is-run"></div>
    """
  end

  defp step_icon(%{status: :error} = assigns) do
    ~H"""
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="none"
      stroke="#ef4444"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="m15 9-6 6M9 9l6 6" />
    </svg>
    """
  end

  defp step_icon(assigns) do
    ~H"""
    <div class="inst-ring"></div>
    """
  end

  defp svg_user(assigns) do
    ~H"""
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
      <circle cx="12" cy="7" r="4" />
    </svg>
    """
  end

  defp svg_globe(assigns) do
    ~H"""
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0 20" />
    </svg>
    """
  end

  defp svg_grid(assigns) do
    ~H"""
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <rect x="3" y="3" width="7" height="7" rx="1" />
      <rect x="14" y="3" width="7" height="7" rx="1" />
      <rect x="3" y="14" width="7" height="7" rx="1" />
      <rect x="14" y="14" width="7" height="7" rx="1" />
    </svg>
    """
  end

  defp svg_gear(assigns) do
    ~H"""
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
    """
  end

  defp svg_check(assigns) do
    ~H"""
    <svg
      width="12"
      height="12"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="3.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <polyline points="20 6 9 17 4 12" />
    </svg>
    """
  end

  defp svg_arrow(assigns) do
    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <line x1="5" y1="12" x2="19" y2="12" />
      <polyline points="12 5 19 12 12 19" />
    </svg>
    """
  end

  defp svg_back(assigns) do
    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <line x1="19" y1="12" x2="5" y2="12" />
      <polyline points="12 19 5 12 12 5" />
    </svg>
    """
  end

  defp svg_search(assigns) do
    ~H"""
    <svg
      width="15"
      height="15"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <circle cx="11" cy="11" r="7" />
      <line x1="21" y1="21" x2="16.65" y2="16.65" />
    </svg>
    """
  end

  defp svg_sliders(assigns) do
    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <line x1="4" y1="21" x2="4" y2="14" />
      <line x1="4" y1="10" x2="4" y2="3" />
      <line x1="12" y1="21" x2="12" y2="12" />
      <line x1="12" y1="8" x2="12" y2="3" />
      <line x1="20" y1="21" x2="20" y2="16" />
      <line x1="20" y1="12" x2="20" y2="3" />
      <line x1="1" y1="14" x2="7" y2="14" />
      <line x1="9" y1="8" x2="15" y2="8" />
      <line x1="17" y1="16" x2="23" y2="16" />
    </svg>
    """
  end

  defp svg_chev(assigns) do
    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <polyline points="6 9 12 15 18 9" />
    </svg>
    """
  end

  defp svg_box(assigns) do
    ~H"""
    <svg
      width="17"
      height="17"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
      <polyline points="3.27 6.96 12 12.01 20.73 6.96" />
      <line x1="12" y1="22.08" x2="12" y2="12" />
    </svg>
    """
  end

  defp svg_lock(assigns) do
    ~H"""
    <svg
      width="12"
      height="12"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      aria-hidden="true"
    >
      <rect x="3" y="11" width="18" height="11" rx="2" />
      <path d="M7 11V7a5 5 0 0 1 10 0v4" />
    </svg>
    """
  end

  defp svg_x(assigns) do
    ~H"""
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
    """
  end

  defp svg_plus(assigns) do
    ~H"""
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </svg>
    """
  end

  defp svg_github(assigns) do
    ~H"""
    <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .3a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.6-1.4-1.3-1.8-1.3-1.8-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.7-1.6-2.7-.3-5.5-1.3-5.5-6 0-1.3.5-2.4 1.2-3.2 0-.4-.5-1.6.2-3.2 0 0 1-.3 3.3 1.2a11 11 0 0 1 6 0C17 4.6 18 5 18 5c.7 1.6.2 2.8.1 3.2.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.5 5.9.5.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6A12 12 0 0 0 12 .3" />
    </svg>
    """
  end

  defp start_ui_kit(socket, config) do
    socket = assign(socket, step: :ui_kit, config: config)

    if socket.assigns.catalog, do: socket, else: load_bundle(socket)
  end

  # "UI components" is the industry's word for these, not a reader's. Someone installing this CMS to
  # write a blog knows what a button and a card are; they do not necessarily know that the trade
  # calls them components. The kit's own name still leads, because that is what they chose.
  defp kit_card_title([]), do: gettext("Page building blocks")

  defp kit_card_title(kits) do
    names =
      kits
      |> Enum.map(&UiKitCatalog.kit_label/1)
      |> Enum.sort()
      |> Enum.join(" + ")

    gettext("%{kits} building blocks", kits: names)
  end

  defp blank_kit(""), do: nil
  defp blank_kit("all"), do: nil
  defp blank_kit(kit), do: kit

  # THE TAG when we fetched it, the bundle's OWN version otherwise. A bundle a developer dropped into
  # the kits directory has no tag — nothing fetched it — and claiming one would be a lie.
  defp version_label(%{tag: tag}) when is_binary(tag), do: tag
  defp version_label(%{version: version}) when is_binary(version), do: version
  defp version_label(_source), do: gettext("unversioned")

  # REPO@REF/FILE, because "wrong tag?" is the question someone actually asks when a package will not
  # fetch. A raw GitHub URL is ~100 characters of path nobody reads, and printing it whole wrapped
  # the banner to three lines; `raw.githubusercontent.com/…/chelekom_headless.json` was shorter but
  # dropped the two segments that answer it.
  #
  # The shape is raw.githubusercontent.com's own layout (`/owner/repo/ref/…/file`), not anything to
  # do with a kit — a URL that does not match it falls back to host and filename, which is all that
  # can honestly be said about an arbitrary one.
  defp short_source(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(path) ->
        label(String.split(path, "/", trim: true), host, Path.basename(path))

      _unparseable ->
        url
    end
  end

  defp short_source(_url), do: ""

  # A release's attached file (`/owner/repo/releases/download/tag/file`) names its tag two segments
  # further in than a raw path does.
  defp label([_owner, repo, "releases", "download", tag | _rest], _host, file),
    do: "#{repo}@#{tag}/#{file}"

  defp label([_owner, repo, ref | _rest], _host, file), do: "#{repo}@#{ref}/#{file}"
  defp label(_segments, host, file), do: "#{host}/…/#{file}"

  # "the Chelekom bundle" named one package when there are now two, and would have gone stale again
  # the moment a host edits `:official_ui_kits`. Read the list instead.
  defp official_kit_summary do
    case UiKitHandler.packages() do
      [] ->
        gettext("the UI-kit bundles on disk")

      [one] ->
        String.trim("#{Settings.text(one.label)} #{one[:tag]}")

      kits ->
        ngettext("%{count} UI-kit package", "%{count} UI-kit packages", length(kits))
    end
  end

  defp kit_names(bundles) do
    bundles
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.reject(&is_nil/1)
  end

  # `resolve_kits/1` rather than `ensure_bundles!/1`: with more than one official package, one of them
  # failing is an ordinary state this step has to RENDER — a headless bundle that 404s must not take
  # the styled one, or a third-party bundle already on disk, down with it.
  defp load_bundle(socket) do
    lv = self()
    channel = socket.assigns.kit_channel

    socket
    |> assign(
      bundle_status: :loading,
      bundle_error: nil,
      bundle_failures: [],
      bundle_sources: [],
      bundle_progress: %{},
      bundle_release: nil,
      fetch_kits: UiKitHandler.packages(),
      kits_configured?: UiKitHandler.configured?()
    )
    |> MishkaGervaz.Messages.start_async(:bundle, fn ->
      UiKitHandler.resolve_kits(
        channel: channel,
        progress: fn key, sizes -> send(lv, {:kit_progress, key, sizes}) end
      )
    end)
  end

  defp kit_channel_options do
    [
      {:stable, gettext("Stable")},
      {:prerelease, gettext("Pre-release")},
      {:master, gettext("Master")}
    ]
  end

  # The channel the kits CAME FROM once they are here — a stable lookup that found only a pre-release
  # lights Pre-release — and the one being tried while they download.
  defp shown_channel(_picked, %{channel: :stable, fallback?: true}), do: :prerelease
  defp shown_channel(_picked, %{channel: channel}), do: channel
  defp shown_channel(picked, _release), do: picked

  defp channel_note(%{channel: :stable, tag: tag}),
    do: gettext("The newest stable release, %{tag}.", tag: tag)

  defp channel_note(%{channel: :prerelease, tag: tag}),
    do: gettext("The newest release, pre-releases included: %{tag}.", tag: tag)

  defp channel_note(%{channel: :master}),
    do:
      gettext("Unreleased: the files on Chelekom's master branch, which may change at any time.")

  defp channel_note(nil),
    do: gettext("The kits already on this server. Pick a version to fetch one.")

  # WHY THERE IS NOTHING: GitHub could not be asked at all, or it was asked and nothing has the kits.
  defp missing_reason(failures) do
    case Enum.find(failures, &(&1.key == :release)) do
      %{reason: reason} ->
        gettext("Chelekom's releases could not be looked up: %{reason}.", reason: reason)

      nil ->
        gettext("No release of Chelekom has them, and its master branch does not either.")
    end
  end

  # Nothing heard yet is a kit being read from disk or a download that has not started — the bar
  # moves without a value until bytes arrive. A server that sends no length gets the count alone.
  defp fetch_size(nil), do: gettext("Checking…")
  defp fetch_size({received, nil}), do: "#{megabytes(received)} MB"
  defp fetch_size({received, total}), do: "#{megabytes(received)} / #{megabytes(total)} MB"

  defp fetch_value({received, total}) when is_integer(total), do: [value: received, max: total]
  defp fetch_value(_unknown), do: []

  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)

  defp commit(socket, settings) do
    selection =
      UiKitCatalog.install_selection_by_kit(
        socket.assigns.catalog,
        socket.assigns.selected,
        socket.assigns.config_axes
      )

    {answers, settings} = Map.pop(settings, "extensions", %{})

    params =
      socket.assigns.config
      |> bootstrap_params(selection, settings)
      |> Map.put(:extensions, MapSet.to_list(socket.assigns.extensions_chosen))
      |> Map.put(:extension_answers, extension_answers(answers))
      |> Map.put(:languages, socket.assigns.languages)
      |> Map.put(:language_urls, socket.assigns.language_urls)

    lv = self()

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "runtime:bulk_compile")

    socket
    |> assign(step: :installing, install_origin: :settings, install_steps: init_steps())
    |> assign(install_error: nil, install_done: false)
    |> assign(install_total: length(Map.get(selection, :components, [])), compiled_count: 0)
    |> MishkaGervaz.Messages.start_async(:install, fn ->
      Bootstrap.run(params, fn message -> send(lv, {:install_progress, message}) end)
    end)
  end

  defp bootstrap_params(config, selection, settings) do
    %{
      email: config["email"],
      password: config["password"],
      site_name: config["site_name"],
      host: config["host"],
      component_selection: selection,
      settings: settings
    }
  end

  defp init_steps do
    Enum.map(Bootstrap.steps(), fn {id, label} ->
      %{id: id, label: label, status: :pending, logs: []}
    end)
  end

  defp update_step(steps, id, :log, line) do
    Enum.map(steps, fn step ->
      if step.id == id, do: %{step | logs: add_log(step.logs, line)}, else: step
    end)
  end

  defp update_step(steps, id, status, detail) do
    Enum.map(steps, fn step ->
      if step.id == id,
        do: %{step | status: status, logs: with_detail(step.logs, detail)},
        else: step
    end)
  end

  defp with_detail(logs, detail) when detail in [nil, false], do: logs
  defp with_detail(logs, detail), do: add_log(logs, detail)

  defp log_running_step(steps, line) do
    Enum.map(steps, fn step ->
      if step.status == :running, do: %{step | logs: add_log(step.logs, line)}, else: step
    end)
  end

  defp add_log(logs, line), do: Enum.take(logs ++ [%{text: line, at: clock_now()}], -3)

  defp clock_now do
    {_date, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()
  end

  defp all_done(steps), do: Enum.map(steps, &%{&1 | status: :done})

  defp fail_running_step(steps) do
    Enum.map(steps, fn step ->
      if step.status == :running, do: %{step | status: :error}, else: step
    end)
  end

  defp exit_message({error, _stacktrace}) when is_exception(error), do: Exception.message(error)
  defp exit_message(reason), do: inspect(reason)

  defp recompute(socket, selected) do
    required = UiKitCatalog.required_closure(socket.assigns.catalog, selected)
    assign(socket, selected: selected, required: required)
  end

  # A FIELD IS AN EXTENSION'S OWN SHAPE, read for either kind of key: it was written in a plugin's
  # `initial:` and has been through Mnesia and a struct builder on the way here.
  defp field_name(field), do: field |> field_key(:name) |> to_string()
  defp field_label(field), do: Settings.text(field_key(field, :label)) || field_name(field)
  defp field_hint(field), do: Settings.text(field_key(field, :hint)) || ""

  defp field_key(field, key) when is_map(field),
    do: Map.get(field, key) || Map.get(field, to_string(key))

  defp field_key(_field, _key), do: nil

  # WHAT THE TICKED EXTENSIONS WERE TOLD, keyed the way `Bootstrap` hands it to each of them. The
  # form nests them under the extension's key, so an answer cannot reach the wrong one.
  defp extension_answers(answers) when is_map(answers), do: answers
  defp extension_answers(_absent), do: %{}

  defp toggle(selected, name) do
    if MapSet.member?(selected, name),
      do: MapSet.delete(selected, name),
      else: MapSet.put(selected, name)
  end

  defp group_names(socket, key) do
    socket.assigns.catalog.groups
    |> Enum.find(%{entries: []}, &(&1.key == key))
    |> Map.fetch!(:entries)
    |> MapSet.new(& &1.name)
  end

  defp checked?(name, selected, required),
    do: MapSet.member?(selected, name) or MapSet.member?(required, name)

  defp locked?(name, selected, required),
    do: MapSet.member?(required, name) and !MapSet.member?(selected, name)

  defp group_selected_count(group, selected, required) do
    Enum.count(group.entries, &checked?(&1.name, selected, required))
  end

  defp configurable?(entry, selected, required),
    do: entry_config(entry) != %{} and checked?(entry.name, selected, required)

  # A SECOND COPY of Chelekom's seven axis names used to live here, and it did the filtering as well
  # as the ordering — so a kit whose knobs are `tone`/`density` had a config the catalogue built and
  # this step then dropped on the floor. The catalogue owns the order now; everything it offers is
  # shown, in that order, with anything it has never heard of after.
  defp ordered_config(entry) do
    entry
    |> entry_config()
    |> UiKitCatalog.sort_axes()
  end

  defp entry_config(entry), do: Map.get(entry, :config, %{})

  defp axis_checked?(config_axes, name, axis, value, default) do
    value == default or
      config_axes |> Map.get(name, %{}) |> Map.get(axis, MapSet.new()) |> MapSet.member?(value)
  end

  defp toggle_axis(config_axes, name, axis, value) do
    axes = Map.get(config_axes, name, %{})
    values = axes |> Map.get(axis, MapSet.new()) |> toggle_member(value)

    axes =
      if MapSet.size(values) == 0, do: Map.delete(axes, axis), else: Map.put(axes, axis, values)

    if map_size(axes) == 0,
      do: Map.delete(config_axes, name),
      else: Map.put(config_axes, name, axes)
  end

  defp toggle_member(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  # Two filters over one list: the search box and, once a second kit is on disk, the kit chips. They
  # compose, because "the headless inputs" is a question someone asks with both.
  defp visible_groups(catalog, query, kit) do
    needle = query |> String.trim() |> String.downcase()

    catalog.groups
    |> Enum.map(fn group ->
      %{group | entries: Enum.filter(group.entries, &shown?(&1, needle, kit))}
    end)
    |> Enum.reject(&(&1.entries == []))
  end

  defp shown?(entry, needle, kit) do
    (needle == "" or String.contains?(String.downcase(entry.label), needle)) and
      (is_nil(kit) or Map.get(entry, :kit) == kit)
  end

  defp to_settings_step(socket) do
    values =
      Map.new(install_settings(), fn definition ->
        {definition.key, install_default(definition, socket.assigns.config)}
      end)

    socket
    |> assign(step: :settings, settings_submitted?: false)
    |> assign(settings_form: to_form(values, as: :settings))
  end

  # ONLY A CODE THE LIST OFFERS, so an event naming anything else stores nothing.
  defp add_language(socket, code) do
    if code in addable_languages(socket.assigns.languages) do
      assign(socket,
        languages: socket.assigns.languages ++ [code],
        language_error: nil,
        language_query: ""
      )
    else
      assign(socket, language_error: gettext("Choose a language from the list."))
    end
  end

  # Enter in the search box: the submitted query, not the assign, which a debounce may not have
  # reached yet. Adds the language only when the query leaves exactly one.
  defp pick_language(socket, query) do
    case matching_languages(socket.assigns.languages, query) do
      [code] -> add_language(socket, code)
      _none_or_several -> assign(socket, language_query: query)
    end
  end

  # The first code is the primary; a code not on the list is left alone.
  defp make_primary(%{assigns: %{languages: languages}} = socket, code) do
    if code in languages,
      do: assign(socket, languages: [code | List.delete(languages, code)], language_error: nil),
      else: socket
  end

  # The primary stays, so the list always keeps one language.
  defp remove_language(%{assigns: %{languages: [primary | rest]}} = socket, code)
       when code != primary do
    assign(socket, languages: [primary | List.delete(rest, code)], language_error: nil)
  end

  defp remove_language(socket, _code), do: socket

  # The codes with a name, not chosen yet and allowed by the master, by their names.
  # The new site's sign-in page for its masters, in its first language and its URL mode.
  defp master_sign_in(%{id: site_id}),
    do: SiteLookupPlug.auth_address(nil, site_id) <> "?master_user=true"

  defp master_sign_in(_no_site), do: "/auth?master_user=true"

  # Each way an address can name its language, with how this site's own would read.
  defp url_choices([primary | others]) do
    other = List.first(others, primary)

    [
      {"prefix_others", gettext("No prefix for the primary language"),
       Enum.uniq(["/blog", "/#{other}/blog"]) -- ["/#{primary}/blog"]},
      {"prefix_all", gettext("A prefix for every language"),
       Enum.uniq(["/#{primary}/blog", "/#{other}/blog"])}
    ]
  end

  defp addable_languages(chosen) do
    Languages.known()
    |> Enum.reject(&(&1 in chosen))
    |> Enum.filter(&Languages.valid?([&1]))
    |> Enum.sort_by(&Languages.name/1)
  end

  # The addable codes whose name or code holds the query, trimmed and in any case; every one of them
  # for a blank query.
  defp matching_languages(chosen, query) do
    needle = query |> String.trim() |> String.downcase()
    Enum.filter(addable_languages(chosen), &language_matches?(&1, needle))
  end

  defp language_matches?(_code, ""), do: true

  defp language_matches?(code, needle) do
    String.contains?(code, needle) or
      String.contains?(String.downcase(Languages.name(code)), needle)
  end

  defp install_settings do
    by_key = Map.new(Settings.definitions(), &{&1.key, &1})
    Enum.flat_map(@install_setting_keys, &List.wrap(Map.get(by_key, &1)))
  end

  defp install_default(%{key: "site.title"}, config), do: config["site_name"] || "MishkaCMS"

  # OFFERED THROUGH THE SAME CHECK IT IS SUBMITTED THROUGH, or the step refuses its own default: a
  # dotless host such as `localhost` makes `noreply@localhost`, which has no dot to pass. Such a
  # host gets `.test`, as the dev seeds' accounts do; a host that still fails gets the registry's.
  defp install_default(%{key: "mailer.from"} = definition, config) do
    host = trimmed(config["host"])

    Enum.find(
      ["noreply@#{host}", "noreply@#{host}.test"],
      definition.default,
      &valid_email?/1
    )
  end

  defp install_default(definition, _config), do: definition.default

  defp assign_settings_form(socket, params) do
    errors = if socket.assigns.settings_submitted?, do: settings_errors(params), else: []
    assign(socket, settings_form: to_form(params, as: :settings, errors: errors))
  end

  defp settings_errors(params) do
    title = trimmed(params["site.title"])
    from = trimmed(params["mailer.from"])

    []
    |> error_if(is_nil(title), "site.title", dgettext_noop("errors", "is required"))
    |> error_if(is_nil(from), "mailer.from", dgettext_noop("errors", "is required"))
    |> error_if(
      from && !valid_email?(from),
      "mailer.from",
      dgettext_noop("errors", "must be a valid email")
    )
  end

  defp assign_form(socket, params) do
    errors = if socket.assigns.submitted?, do: errors(params), else: []
    assign(socket, form: to_form(params, as: :install, errors: errors))
  end

  defp errors(params) do
    email = trimmed(params["email"])
    password = params["password"] || ""
    confirmation = params["password_confirmation"] || ""
    site_name = trimmed(params["site_name"])
    host = trimmed(params["host"])

    []
    |> error_if(is_nil(email), :email, dgettext_noop("errors", "is required"))
    |> error_if(
      email && !valid_email?(email),
      :email,
      dgettext_noop("errors", "must be a valid email")
    )
    |> error_if(password == "", :password, dgettext_noop("errors", "is required"))
    |> error_if(
      password != "" and String.length(password) < 8,
      :password,
      dgettext_noop("errors", "must be at least 8 characters")
    )
    |> error_if(
      password != "" and confirmation != password,
      :password_confirmation,
      dgettext_noop("errors", "does not match")
    )
    |> error_if(is_nil(site_name), :site_name, dgettext_noop("errors", "is required"))
    |> error_if(
      site_name && String.length(site_name) not in 3..70,
      :site_name,
      dgettext_noop("errors", "must be 3–70 characters")
    )
    |> error_if(is_nil(host), :host, dgettext_noop("errors", "is required"))
    |> error_if(
      host && !valid_host?(host),
      :host,
      dgettext_noop("errors", "must be a bare domain (no http://)")
    )
  end

  defp error_if(errors, true, field, msg), do: errors ++ [{field, {msg, []}}]
  defp error_if(errors, _condition, _field, _msg), do: errors

  defp trimmed(nil), do: nil

  defp trimmed(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp valid_email?(email), do: String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)

  defp valid_host?(host), do: String.match?(host, ~r/^[a-zA-Z0-9.-]+$/)

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp dev_seeds_allowed?, do: Application.get_env(:mishka_cms_core, :env_dev?, false)

  defp dev_seed_categories do
    if dev_seeds_allowed?(), do: MishkaCmsCore.Dev.Seeds.categories(), else: []
  end

  defp default_seed_selected do
    MapSet.new(dev_seed_categories(), &to_string(&1.key))
  end

  defp seed_steps(selected) do
    Enum.map(MishkaCmsCore.Dev.Seeds.steps(selected), fn {id, label} ->
      %{id: id, label: Settings.text(label), status: :pending, logs: []}
    end)
  end
end
