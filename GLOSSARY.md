# Glossary

- **Site**: one tenant, served on its own host.
- **Master user**: a user with no `site_id`; reaches every site, limited by its permissions.
- **Site user**: a user of one site; sees only that site.
- **Global record**: a row with no `site_id`, seen by every site, written only by a master.
- **Extension**: a package the host installs (Blog, Document, the builder, sign-in).
- **Installer part**: one choice a plugin declares on `installer:seed`: `required` (locked), `default` (ticked at start) and `envs` (`:dev`, `:prod` or both).
- **Production seeds**: the parts the normal install form runs (`/install`): permissions, the master, the first site, its starter pages and each chosen extension's pages. No sample data.
- **Dev seeds**: the parts "Or load sample data for development" runs, in a dev build only: three sites, their users and each extension's sample data. A production build refuses them.
- **Error page**: a site's entries per status (404, 500, offline, default), drawn inside one boundary.
- **Wave**: one step of the release cycle (`.claude/skills/mishka-release`).
- **Friction**: a guess or a missing tool, logged in `FRICTION.md`.
