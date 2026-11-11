# Changelog for MishkaCms 0.0.2

### Features:
- The visual editor is a package of its own. The host installs `mishka_cms_builder` 0.0.1-alpha.4 and `mishka_cms_core` 0.0.4 from Hex, imports the admin and editor hooks from their packages, and starts the runtime through the core's supervision API
- A reader is told when the open page changed because its layout or a component it draws was rebuilt
- The release workflow publishes a demo image to GHCR and a GitHub release for a tag, and the demo image is `ghcr.io/mishka-group/mishka_cms-demo:0.0.2`
- A page rewritten by a redirect rule is served at the address asked for, a gone (410 or 404) rule draws the site's error page with its status, and when a page's record is missing the next page the address matches is tried before the 404 (needs the next `mishka_cms_core` and `mishka_blog` releases)
- Every extension's API routes (`extension_routes(:api)`) are mounted before the page catch-all through the `:extension_api` pipeline: the site its host names, the install and offline gates, no CSRF check and no sign-in. The Blog's RSS, Atom and JSON feeds are served there (`/feed`, `/feed/atom`, `/feed.json`), and a site with the Blog switched off answers them 404 (needs the next `mishka_cms_core` and `mishka_blog` releases)

### Bug fixes:
- The editor's canvas follows its rebuilt CSS, registers the site's runtime hooks on the admin's socket, and shows a page's preview framed and typeset as the published page is
- The editor's strict checks raise in the host's development and test runs
- A page with no layout is drawn bare, exactly the markup its author wrote, on the published page and in the preview as on the editor's canvas, like a full-width canvas template: `RuntimeLive.default_layout/1` adds the flash group and no padded `max-w-4xl` frame, and the author sets a width by wrapping the content in a section, for example `max-w-4xl mx-auto`
- The new-tab draft preview opens at once under a "Building preview…" overlay and builds its stylesheet on every open, from the draft as it is, its own Custom CSS included (with mishka_cms_core 0.0.5). `/_preview/:resource/:token/css` compiles for each request, still only under a token a preview was opened with, and the page links it in the body after the overlay; the stylesheet's last rule hides the overlay, and one that cannot be built says so on it. No script does it, so the preview's Content-Security-Policy stays strict: no `'unsafe-inline'` for scripts or style elements, and its only inline `<style>` carries the response's nonce. With core 0.0.4 the stylesheet is compiled again through `refresh_css/2`
- Security: `phoenix_html` 4.4.0, `bandit` 1.14.1 (EEF-CVE-2026-116078) and `jose` 1.11.13 (8 advisories)

### Refactors:
- The release runs on Erlang 29.1.2 and Elixir 1.20.5 with the temporary OTP 29.0.5 pin removed, and the Docker image builds on Elixir 1.20.5 and lets the libraries download their own NIFs
- `igniter_js` is 0.5.2 and `tailwind` is 0.5.2 or later, and every dependency is at its latest release
- Every Mishka package is at its latest release: `mishka_blog`, `mishka_document` and the four sign-in providers 0.0.2, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN` where they never write, Dependabot runs weekly, and the Credo and Sobelow findings are fixed or listed with their reasons

# Changelog for MishkaCms 0.0.1

Initial release.
