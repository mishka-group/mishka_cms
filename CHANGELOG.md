# Changelog for MishkaCms 0.0.2

### Features:
- The visual editor is a package of its own. The host installs `mishka_cms_builder` 0.0.1-alpha.4 and `mishka_cms_core` 0.0.4 from Hex, imports the admin and editor hooks from their packages, and starts the runtime through the core's supervision API
- A reader is told when the open page changed because its layout or a component it draws was rebuilt
- The release workflow publishes a demo image to GHCR and a GitHub release for a tag, and the demo image is `ghcr.io/mishka-group/mishka_cms-demo:0.0.2`

### Bug fixes:
- The editor's canvas follows its rebuilt CSS, registers the site's runtime hooks on the admin's socket, and shows a page's preview framed and typeset as the published page is
- The editor's strict checks raise in the host's development and test runs
- The editor's canvas draws a page with no layout in the frame the published page and the preview draw it in, `RuntimeLive.default_layout/1`, named by `config :mishka_cms_builder, default_layout:` (read by the builder release after 0.0.1-alpha.4)
- Security: `phoenix_html` 4.4.0, `bandit` 1.14.1 (EEF-CVE-2026-116078) and `jose` 1.11.13 (8 advisories)

### Refactors:
- The release runs on Erlang 29.1.2 and Elixir 1.20.5 with the temporary OTP 29.0.5 pin removed, and the Docker image builds on Elixir 1.20.5 and lets the libraries download their own NIFs
- `igniter_js` is 0.5.2 and `tailwind` is 0.5.2 or later, and every dependency is at its latest release
- Every Mishka package is at its latest release: `mishka_blog`, `mishka_document` and the four sign-in providers 0.0.2, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN` where they never write, Dependabot runs weekly, and the Credo and Sobelow findings are fixed or listed with their reasons

# Changelog for MishkaCms 0.0.1

Initial release.
