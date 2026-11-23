# Glossary

- **Site**: one tenant, served on its own host.
- **Master user**: a user with no `site_id`; reaches every site, limited by its permissions.
- **Site user**: a user of one site; sees only that site.
- **Global record**: a row with no `site_id`, seen by every site, written only by a master.
- **Extension**: a package the host installs (Blog, Document, the builder, sign-in).
- **Paid extension**: installed by a site owner; never in this repo's dependencies.
- **Error page**: a site's entries per status (404, 500, offline, default), drawn inside one boundary.
- **Wave**: one step of the release cycle (`.claude/skills/mishka-release`).
- **Friction**: a guess or a missing tool, logged in `FRICTION.md`.
