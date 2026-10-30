# Changelog for MishkaCms 0.0.2

### Features:
- The visual editor is a package of its own. The host installs `mishka_cms_builder` and `mishka_cms_core` 0.0.3 from Hex, imports the admin and editor hooks from their packages, and starts the runtime through the core's supervision API
- A reader is told when the open page changed because its layout or a component it draws was rebuilt
- The release workflow publishes a demo image to GHCR and a GitHub release for a tag, and the demo image is `ghcr.io/mishka-group/mishka_cms-demo:0.0.2`

### Bug fixes:
- The editor's canvas follows its rebuilt CSS, registers the site's runtime hooks on the admin's socket, and shows a page's preview framed and typeset as the published page is
- The editor's strict checks raise in the host's development and test runs
- Security: `phoenix_html` 4.4.0, `bandit` 1.14.1 (EEF-CVE-2026-116078) and `jose` 1.11.13 (8 advisories)

### Refactors:
- The release runs on Erlang 29.1.2 and Elixir 1.20.5 with the temporary OTP 29.0.5 pin removed, and the Docker image builds on Elixir 1.20.5 and lets the libraries download their own NIFs
- `igniter_js` is 0.5.2 and `tailwind` is 0.5.2 or later, and every dependency is at its latest release
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN` where they never write, Dependabot runs weekly, and the Credo and Sobelow findings are fixed or listed with their reasons

# Changelog for MishkaCms 0.0.1

Initial release.
