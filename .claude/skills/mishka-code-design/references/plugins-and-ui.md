# Plugins, events and UI

## mishka_installer

Repo: [mishka_installer](https://github.com/mishka-group/mishka_installer), or a local checkout or `deps/mishka_installer` if you have one. Key files: `lib/event/hook.ex`, `lib/event/event.ex`, `lib/event/module_state_compiler.ex`.

- **A plugin:**
  ```elixir
  use MishkaInstaller.Event.Hook, event: "area:thing:verb", initial: %{priority: 50}
  @impl true
  def call(state), do: {:reply, state}
  ```
  Every plugin has the same `call/1`. That is the pattern to copy for any family of modules.
- **Firing an event:** `MishkaInstaller.Event.Hook.call(event, payload, cannot_run: …, meta: %{actor: actor, site_id: site_id})`. Pass `cannot_run:` so an event whose plugins can't run is handled on purpose. Today a plugin that raises is rescued and logged, and the input comes back unchanged. Design payloads so that doesn't silently let something through, and see mishka_cms_migration#18 for the proposed `raised:` option.
- **Who is installed:** `MishkaInstaller.Event.Event.get(:event, "area:things")` returns the registered plugins with `name`, `priority`, `status` and `extension`. Filter for running status, sort by priority, and match by the plugin's own id. Don't build a parallel registry, and don't discover plugins by calling them.
- **Supervision:** an extension supervises its plugins in its `Application` (`plugins/0`), as `MishkaBlog.Application` does. Every plugin has a `child_spec`. Stopping a plugin in the installer is the on/off switch.
- **Extension points for other extensions are events.** Define the event names in one place, for example `Events.before_import_event/0`, and use those functions everywhere, including in the `use` macros.

## mishka_gervaz (admin)

Repo: [mishka_gervaz](https://github.com/mishka-group/mishka_gervaz), or a local checkout or `deps/mishka_gervaz` if you have one.

- Admin forms and tables are gervaz DSL resources: fields, types, filters, actions and error display. Never hand-write form markup or validation display for the admin.
- Before writing a helper, check gervaz for a field type or template helper. Example: `MishkaGervaz.Form.Types.Field.Json.parse_params/2` for JSON fields.
- Errors reach the user through gervaz's error handling (`MishkaGervaz.Errors.translate_error/2`) as short sentences.
- Comments in gervaz: sentence case, saying what the code does for a caller, with no ALL-CAPS lead phrase and no history.

## LiveView

- **Behaviour in the markup:** `Phoenix.LiveView.JS` (`show`, `hide`, `toggle`, `add_class`, `remove_class`, `toggle_class`, `set_attribute`, `remove_attribute`, `toggle_attribute`, `focus`, `dispatch`, `push`, `exec`, `transition`), plus bindings like `phx-mounted`, `phx-click-away`, `phx-window-keydown` and `phx-remove`. `to:` takes any CSS selector, `html` and `body` included. Write a hook or JS file only when `JS` can't do it, and say what was missing.
- **Security:** authorise in `mount` and in every `handle_event`. Never trust params; check the resource's policy through Ash, as described in LiveView's security model.

## CSS, JS and HTML

- **Parse CSS with `igniter_css` and JS with `igniter_js`.** Never use regex or hand-written walkers. If a parser lacks something, add it to that library's Rust side as a path dependency while you work.
- **Tailwind decides which classes exist.** Use its compiler or scanner output, never a hand-written class extractor. Never ship project source files in `priv` or a release.
- **HTML content rules follow the WHATWG spec.** For example, a `<p>`, a heading, `<button>` and `<label>` hold phrasing content only, so a block `<div>` inside one becomes a `<span>`.

## Mishka Chelekom

- Headless components carry no Tailwind classes; styling lives only in the styled components.
- After changing component templates, regenerate the CMS bundles with the repo's export task. Don't edit `priv/cms_ui_kits/*.json` by hand.
