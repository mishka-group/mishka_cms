defmodule MishkaCmsWeb.DraftPreviewLive do
  @moduledoc """
  Serves a runtime preview at the shareable `/_preview/:resource/:token` URL as a *real LiveView*,
  so it is a full page lifecycle: the per-site JS bundle boots the LiveSocket and registers the
  site's `phx-hook`s, so client-side interactivity (copy-email, menus, dropdowns) works exactly
  like a published page — unlike a static server-render, where no hooks ever mount.

  The draft is looked up by its unguessable `preview_token` (the token is the capability — no
  login). Its template is rendered inline; the layout (`MishkaCmsWeb.Layouts`, `:preview`) links the
  draft's own temporary CSS (`/_preview/:resource/:token/css`, compiled per-draft, never the live
  site bundle) and the per-site JS bundle.

  A page or a layout is drawn by its compiled module, built by the compiler its site uses
  (`MishkaCmsCore.Runtime.DraftPreviewAssets.ensure_module/2`), with the assigns
  `MishkaCmsWeb.RuntimeLive` gives a page, so its own helpers and the live components it nests
  render. A page is drawn inside its layout, and a layout around its `example` or a placeholder. The
  module is unloaded when the preview closes. Its handlers never run: every event is ignored here,
  and `assets/js/preview.js` stops every form submit, so a preview signs nobody in. An error page
  still renders its templates — see `MishkaCmsCore.Runtime.RuntimePreview`, and
  `MishkaCmsWeb.DraftPreviewController` for the CSS endpoint.

  State kept in the URL IS wired: the template is rendered in `handle_params/3`, against this
  preview's own path and query string, so a pager's `<.link patch={@page.path <> "?page=2"}>` stays
  on this route and draws page two here — see `MishkaCmsCore.Runtime.RuntimePreview.inner_html/6`.
  A link to any OTHER address opens the published page in a new tab, so this one stays the preview —
  see `assets/js/preview.js`, which the `:preview` layout loads and no other layout does.

  Only a DRAFT shows the temporary-preview banner; the live original needs no explanation. That
  banner is dressed by a `<style>` element rather than a `style` attribute, which no CSP nonce can
  cover — and this page is served the PUBLIC policy, which is enforced. A Tailwind class is not an
  option here either: the `:preview` root layout links ONLY the per-draft bundle — never
  `public.css`, never the site bundle — and `MishkaCmsCore.Runtime.DraftPreviewAssets` compiles that
  bundle by scanning the draft's own template, so a class written in THIS module is seen by no
  Tailwind build and would resolve against nothing. The element takes `@csp_nonce`, which every
  LiveView here carries — see `MishkaCmsCore.Runtime.CspNonce`.

  The same element carries `MishkaCmsCore.Runtime.RuntimePreview.chrome_css/0`, for the same reason
  and for every preview rather than only a draft: `inner_html/4` degrades to a note, a layout
  placeholder or a short hint written in `mishka-preview-*` classes, and this page is the only place
  those rules can land with a nonce on them. The banner rule rides along on an original's preview,
  where it matches nothing.

  A degraded fragment repeats those rules in a `<style>` of its own — it can also be embedded
  somewhere this page's element does not reach — so the nonce is handed to `inner_html/4` as well,
  and that block is nonced too rather than refused.
  """
  use MishkaCmsWeb, :live_view

  alias MishkaCmsCore.Runtime.{
    Page,
    PageDraft,
    Layout,
    LayoutDraft,
    ErrorPage,
    ErrorPageDraft,
    Languages,
    RuntimePreview,
    DraftPreviewAssets
  }

  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError

  # The same `/_preview/:resource/:token` URL serves a DRAFT or the live ORIGINAL — both carry a
  # `preview_token`. We try the draft first, then the original.
  #
  # THE TOKEN IS WHAT RESOLVES THE TENANT, not the Host header, which is why this route works on any
  # host the admin is reachable at. That matters more than it sounds: a site's own domain may point
  # at an entirely different machine from the one being edited, so previewing a record at its site's
  # URL can show a stranger's server rather than the draft in front of you.
  #
  # AND THE RECORD'S SITE DECIDES WHO SEES IT, not the host's: an inactive site's record is a master's
  # to preview, an offline one's its admins' and the masters' — refused like an unknown token, and
  # closed if its site goes down while it is open. A plugin on `web:live:preview_unavailable` hears
  # each refusal, with `%{site_id: site_id, state: state, resource: resource}`.
  @drafts %{"page" => PageDraft, "layout" => LayoutDraft, "error_page" => ErrorPageDraft}
  @compiled [Page, PageDraft, Layout, LayoutDraft]
  @originals %{"page" => Page, "layout" => Layout, "error_page" => ErrorPage}

  def mount(%{"resource" => resource, "token" => token}, session, socket) do
    with {:ok, record, module} <- load_record(resource, token),
         {:ok, socket} <- follow(socket, record, resource, session) do
      # A global layout (or its draft) has no site of its own — fall back to the site of the host
      # the admin is viewing from (`SiteLookupPlug` resolved it into the session), so the preview
      # borrows that domain's JS bundle (hooks run) and compiles its CSS against that site's base.
      asset_site = Map.get(record, :site) || Map.get(session, "current_site")
      _ = DraftPreviewAssets.ensure_css(record, asset_site)
      :ok = DraftPreviewAssets.remember_site(record, asset_site)
      language = Map.get(record, :language) || site_language(asset_site)
      :ok = speaking(language, asset_site)

      {:ok,
       socket
       |> assign(:page_title, gettext("%{name} · preview", name: Map.get(record, :name)))
       |> assign(record: record, module: module, asset_site: asset_site)
       |> assign(:preview_css, "/_preview/#{resource}/#{token}/css")
       |> assign(:preview_js, site_js(asset_site, token))
       |> assign(:draft?, module in [PageDraft, LayoutDraft, ErrorPageDraft])
       |> assign(
         :original_changed?,
         MishkaCmsCore.Runtime.PageBuilder.Drafts.original_changed?(record)
       )
       |> assign(:language, language), layout: false}
    else
      _not_found_or_refused -> raise NotFoundError, message: "Preview not found"
    end
  end

  defp follow(socket, record, resource, session) do
    case SiteAvailability.follow(socket, Map.get(record, :site_id), session) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, site_id, state} ->
        MishkaInstaller.Event.Hook.call(
          "web:live:preview_unavailable",
          %{site_id: site_id, state: state, resource: resource},
          return: false
        )

        :refused
    end
  end

  # Mirrors `MishkaCmsWeb.RuntimeLive`, which assigns `@query_params` in `handle_params/3` for the
  # same reason: a `<.link patch>` runs this again and nothing else, so the page is drawn here.
  def handle_params(params, uri, socket) do
    %{record: record, module: module, asset_site: asset_site} = socket.assigns
    path = URI.parse(uri).path
    query_params = Map.drop(params, ["resource", "token"])

    case module in @compiled && DraftPreviewAssets.ensure_module(record, asset_site) do
      {:ok, preview_module} ->
        {:noreply, compiled(socket, preview_module, path, query_params)}

      {:error, message} ->
        {:noreply,
         assign(socket,
           preview_module: nil,
           body_html: RuntimePreview.note_body(message, socket.assigns[:csp_nonce])
         )}

      false ->
        {:noreply, rendered(socket, params, path, query_params)}
    end
  end

  # WHAT `MishkaCmsWeb.RuntimeLive` HANDS A PAGE, with this preview's own address as the page's path
  # and nobody signed in. A layout is handed the same, about itself.
  defp compiled(socket, preview_module, path, query_params) do
    %{record: record, asset_site: asset_site, language: language} = socket.assigns

    info =
      if function_exported?(preview_module, :__page_information__, 0),
        do: preview_module.__page_information__(),
        else: layout_information(preview_module, record, language)

    socket
    # A page that declares an upload draws `@uploads`, which only an allowed upload puts there.
    |> MishkaCmsCore.Runtime.PageUpload.allow(preview_module)
    # A page reads the assigns it declares in `state` from its first render.
    |> MishkaCmsCore.Runtime.PageState.assign_initial(preview_module)
    |> assign(
      preview_module: preview_module,
      layout_module: layout_module(record, asset_site),
      page: Map.put(info.page, :path, path),
      private: info.private,
      acl: info.acl,
      extra: info.extra,
      query_params: query_params,
      current_site: asset_site,
      current_tenant: site_id(asset_site),
      current_user: nil,
      client_request: %{remote_ip: nil},
      page_languages: []
    )
  end

  # A PAGE IS PREVIEWED INSIDE ITS LAYOUT, as a visitor gets it: the draft's own choice for a draft,
  # compiled the same way the page is. A layout that does not compile leaves the page alone.
  defp layout_module(%{layout: %Layout{} = layout}, site), do: compiled_layout(layout, site)

  defp layout_module(%{loaded_layout: %Layout{} = layout}, site),
    do: compiled_layout(layout, site)

  defp layout_module(_record, _site), do: nil

  defp compiled_layout(layout, site) do
    case DraftPreviewAssets.ensure_module(layout, site) do
      {:ok, module} -> module
      {:error, _message} -> nil
    end
  end

  defp layout_information(preview_module, record, language) do
    info = preview_module.__layout_information__()

    %{
      page: %{title: record.name, language: language},
      private: info.private,
      acl: info.acl,
      extra: info.extra
    }
  end

  defp rendered(socket, params, path, query_params) do
    %{record: record, module: module, asset_site: asset_site} = socket.assigns

    assign(socket,
      preview_module: nil,
      body_html:
        RuntimePreview.inner_html(
          record,
          module,
          parse_status(params["status"]),
          socket.assigns[:csp_nonce],
          # THE SITE THE HOOKS MUST RESOLVE AGAINST. A template naming another site's hook works
          # on a published page only where that site is — correctly — but a preview exists to show
          # whether the page WORKS, so here the name is pointed at this site's own hook of the
          # same base. See `MishkaCmsCore.Runtime.PreviewHooks`.
          asset_site,
          path: path,
          query_params: query_params
        )
    )
  end

  # THE PREVIEW IS THE ONE SCREEN A TRANSLATION IS CHECKED ON, so it answers in the language the page
  # is written in — the live page has since `3beb2e1e`, this had `lang="en"` nailed into the layout,
  # and a Persian page therefore previewed left to right in an English locale, which is precisely
  # where an rtl mistake hides. A layout or a component carries no language of its own, so it takes
  # the site's first, the same one its pages default to.
  defp site_language(site), do: Languages.primary(site_id(site))

  # AND `t/1` ANSWERS IN IT, from this site's words — what `MishkaCmsWeb.RuntimeLive` sets for a
  # visitor. Both live in the PROCESS rendering the page, and this LiveView is its own, so left unset
  # a preview read only the global rows, in the admin's locale, and a site's translation checked here
  # showed the key.
  defp speaking(language, site) do
    Gettext.put_locale(language)
    MishkaCmsCore.Runtime.Translations.put_site(site_id(site))
  end

  defp site_id(%{id: id}), do: id
  defp site_id(_site), do: nil

  # ErrorPage holds many status codes; `?status=404` selects which to render (nil → first).
  defp parse_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_status(_status), do: nil

  def render(assigns) do
    ~H"""
    <style phx-no-curly-interpolation nonce={assigns[:csp_nonce]}>
      <%= raw(RuntimePreview.chrome_css()) %>
      #mishka-draft-banner{position:sticky;top:0;z-index:2147483647;background:#fef3c7;color:#92400e;font:500 12px/1.45 ui-sans-serif,system-ui,sans-serif;padding:6px 12px;border-bottom:1px solid #fde68a;text-align:center}
    </style>
    <div :if={@draft?} id="mishka-draft-banner">
      {gettext(
        "Draft preview — temporary CSS rebuilt just for this draft, discarded when it's published or deleted."
      )}
      {gettext("Links to other pages open the published site in a new tab.")}
      <strong :if={@original_changed?} id="mishka-draft-original-changed">
        {gettext("The original was changed after this draft was made.")}
      </strong>
    </div>
    <%= if @preview_module do %>
      {preview(assigns)}
    <% else %>
      {raw(@body_html)}
    <% end %>
    """
  end

  defp preview(%{preview_module: preview_module} = assigns) do
    cond do
      function_exported?(preview_module, :__layout_information__, 0) ->
        preview_module.render(assigns, RuntimePreview.layout_inner_content(assigns.record))

      assigns.layout_module ->
        assigns.layout_module.render(assigns, preview_module.render(assigns))

      true ->
        preview_module.render(assigns)
    end
  end

  # THE MODULE GOES WITH THE PREVIEW, so a draft looked at once holds no code after it is closed. A
  # second preview of the same record still open compiles it again at its next address.
  def terminate(_reason, socket) do
    DraftPreviewAssets.unload_module(socket.assigns[:record])
  end

  # The page's server-side handlers never run in a preview, so the events its template emits are
  # ignored rather than crash the socket.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_record(resource, token) do
    cond do
      record = fetch_draft(resource, token) -> {:ok, record, Map.fetch!(@drafts, resource)}
      record = fetch_original(resource, token) -> {:ok, record, Map.fetch!(@originals, resource)}
      true -> :error
    end
  end

  defp fetch_draft(resource, token) do
    case Map.get(@drafts, resource) do
      PageDraft ->
        unwrap(
          MishkaCmsCore.Runtime.get_page_draft_by_token(token,
            load: [:site, layout: [:site]],
            authorize?: false
          )
        )

      LayoutDraft ->
        unwrap(
          MishkaCmsCore.Runtime.get_layout_draft_by_token(token, load: [:site], authorize?: false)
        )

      ErrorPageDraft ->
        unwrap(
          MishkaCmsCore.Runtime.get_error_page_draft_by_token(token,
            load: [:site],
            authorize?: false
          )
        )

      _ ->
        nil
    end
  end

  defp fetch_original(resource, token) do
    case Map.get(@originals, resource) do
      Page ->
        unwrap(
          MishkaCmsCore.Runtime.get_page_by_token(token,
            load: [:site, :loaded_layout],
            authorize?: false
          )
        )

      Layout ->
        unwrap(MishkaCmsCore.Runtime.get_layout_by_token(token, load: [:site], authorize?: false))

      ErrorPage ->
        unwrap(
          MishkaCmsCore.Runtime.get_error_page_by_token(token, load: [:site], authorize?: false)
        )

      _ ->
        nil
    end
  end

  defp unwrap({:ok, %{} = record}), do: record
  defp unwrap(_other), do: nil

  # With the token, so the bundle is handed to whoever holds this link, on whatever address they
  # opened it — see `MishkaCmsCoreWeb.AssetsController`.
  defp site_js(%{name: name}, token) do
    if AssetsState.exists?(name, "js"),
      do: "/assets/js/#{name}/#{AssetsState.get!(name, "js")[:hash]}.js?preview=#{token}"
  end

  defp site_js(_record, _token), do: nil
end
