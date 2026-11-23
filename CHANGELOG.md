# Changelog for MishkaCms 0.0.3

### Features:
- A page rewritten by a redirect rule is served at the address asked for, a gone (410 or 404) rule draws the site's error page with its status, and when a page's record is missing the next page the address matches is tried before the 404. WordPress addresses keep working
- Every extension's API routes (`extension_routes(:api)`) are mounted before the page catch-all: the site its host names, the install and offline gates, no CSRF check and no sign-in. The Blog's RSS, Atom and JSON feeds are served there (`/feed`, `/feed/atom`, `/feed.json`), and a site with the Blog switched off answers them 404
- `GET /_health` answers first, on any host and over plain http, so a deploy can wait on it
- A site's head code (analytics, verification, fonts) is drawn on its public pages with the response's nonce, and follows live navigation. Admin and editor pages never get it
- Scheduled Blog posts go out at their time: the Oban crontab runs the Blog's scheduled-post worker every minute
- A page's preview can show a state only a preview may show (`?preview_state=`, for example a form's Confirmed state), and a record sample in another language draws the preview in that language when the site publishes in it
- The content editor keeps and inserts tables
- An error page that fails to draw for a visitor is kept for its status, until it is drawn again

### Bug fixes:
- A page with no layout is drawn bare, exactly the markup its author wrote, on the published page and in the preview as on the editor's canvas: `RuntimeLive.default_layout/1` adds the flash group and no padded `max-w-4xl` frame, and the author sets a width by wrapping the content in a section, for example `max-w-4xl mx-auto`
- The new-tab draft preview opens at once under a "Building preview…" overlay and builds its stylesheet on every open, from the draft as it is, its own Custom CSS included, with the layout's head tags as the live page has them. The preview's Content-Security-Policy stays strict: no `'unsafe-inline'` for scripts or style elements
- A release's shell padding no longer loses to a site's own `px-4`: the image writes the shell's class list with Tailwind's own scanner
- The live socket hands a page its visitor's user agent, so the Blog leaves a bot's view uncounted
- The search select in the admin's forms answers ArrowDown and Enter as it should, because the admin registers Mishka Gervaz's hooks
- An error raised before the site is known shows the error page of the site its Host header names, only while that site is open and serves pages, in its first language; a site with no error page falls back to Phoenix's page with one short warning
- An error page that raises as it is drawn, or does not compile, answers the plain message with the status the request had and one short warning; an offline page that raises answers the built-in page the same way, and only the error page's own template is drawn inside that boundary
- Only a site with no Error Page is logged as having none, and the warning of an error page that raises an ArgumentError says which argument, on one short line
- A page and the GraphQL socket answer on their site's host in capital letters or with the root's dot
- The duration of an error page is told apart by site, status and outcome
- `/favicon.ico` of a site with no favicon answers the core's bundled Mishka mark (`image/png`, kept an hour) in place of a 404
- Security: the image runs on Debian trixie-20261104 and runs `apt-get upgrade` at build time, so it carries the zlib, glibc and apt fixes published after the base image was cut
- The image uses `wget` instead of `curl` for its health check (Coolify's own check tries curl, then wget), so curl and the libraries it pulls in stay out of the image
- The Phoenix packages copied for the runtime JavaScript build carry their real versions in `package.json`, so an image scanner no longer reports `phoenix_html` 1.0.0
- Security: `phoenix` 1.8.17 and `phoenix_live_view` 1.2.15 (EEF-CVE-2026-128361, EEF-CVE-2026-129344 and EEF-CVE-2026-126334), `bandit` 1.15 and `jose` 1.11.13

### Refactors:
- The host no longer lists `ash_slug` (the CMS slugs with `mishka_slug`)
- The host takes `mishka_cms_core` 0.0.6, `mishka_cms_builder` 0.0.1, `mishka_blog` 0.0.3, `mishka_document` 0.0.3, `mishka_gervaz` 0.0.12, `mishka_installer` 0.1.17, `guarded_struct` 0.1.11 and the four sign-in extensions at 0.0.3
- The image and CI use Bun 1.4.5
- The editor runs TipTap 3.35.0, and every dependency is at its latest release, including `ash` 3.37.7, `ash_postgres` 2.16.0, `ash_authentication` 5.0.0-rc.18, `swoosh` 1.30, `postgrex` 0.23.0, `mishka_gervaz` 0.0.10, `mishka_installer` 0.1.16 and `guarded_struct` 0.1.10
- The CI, release and dependency-update workflows are shared by the Mishka repositories, and a new package release opens one rolling `deps/mishka` pull request here

# Changelog for MishkaCms 0.0.2

### Features:
- The visual editor is a package of its own. The host installs `mishka_cms_builder` 0.0.1-alpha.4 and `mishka_cms_core` 0.0.4 from Hex, imports the admin and editor hooks from their packages, and starts the runtime through the core's supervision API
- A reader is told when the open page changed because its layout or a component it draws was rebuilt
- The release workflow publishes a demo image to GHCR and a GitHub release for a tag, and the demo image is `ghcr.io/mishka-group/mishka_cms-demo:0.0.2`

### Bug fixes:
- The editor's canvas follows its rebuilt CSS, registers the site's runtime hooks on the admin's socket, and shows a page's preview framed and typeset as the published page is
- The editor's strict checks raise in the host's development and test runs
- Security: `phoenix_html` 4.4.0, `bandit` 1.14.1 (EEF-CVE-2026-116078) and `jose` 1.11.13 (8 advisories)

### Refactors:
- The release runs on Erlang 29.1.2 and Elixir 1.20.5 with the temporary OTP 29.0.5 pin removed, and the Docker image builds on Elixir 1.20.5 and lets the libraries download their own NIFs
- `igniter_js` is 0.5.2 and `tailwind` is 0.5.2 or later, and every dependency is at its latest release
- Every Mishka package is at its latest release: `mishka_blog`, `mishka_document` and the four sign-in providers 0.0.2, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN` where they never write, Dependabot runs weekly, and the Credo and Sobelow findings are fixed or listed with their reasons

# Changelog for MishkaCms 0.0.1

Initial release.
