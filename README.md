<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka CMS

**An [open source real-time CMS](https://mishka.tools/cms) for Elixir and Phoenix LiveView. One install runs many websites.**

[Website](https://mishka.tools/cms) · [Documentation](https://mishka.tools/cms/docs) · [Admin preview](https://mishka.tools/cms#demo) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka CMS?

Mishka CMS is an [open source real-time CMS](https://mishka.tools/cms) written in Elixir on Phoenix LiveView and the Ash framework. One install serves many websites. Each site is a tenant with its own domain, languages, pages, layouts, components, media, users and permissions, and master users work across all of them.

Pages, layouts, components, error pages, stylesheets and JavaScript hooks are stored in the database and compiled at runtime. You edit them in the browser with a visual page builder or a code editor, save a draft, and publish. Publishing does not need a redeploy.

This repository is the application that runs the CMS: the Phoenix endpoint, the router, the release scripts and the Dockerfile. The engine and the extensions are separate packages that it loads.

## 🧩 Part of Mishka CMS

This is [Mishka CMS](https://mishka.tools/cms) itself. It loads nine packages: [mishka_cms_core](https://github.com/mishka-group/mishka_cms_core), the engine; [mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder), the visual editor; [mishka_blog](https://github.com/mishka-group/mishka_blog), the [blog extension](https://mishka.tools/cms/extensions/blog); [mishka_document](https://github.com/mishka-group/mishka_document), the [documentation extension](https://mishka.tools/cms/extensions/documentation); [mishka_gervaz](https://github.com/mishka-group/mishka_gervaz), the [Mishka Gervaz](https://mishka.tools/gervaz) toolkit the admin screens are built with; and four sign-in providers, [mishka_cms_auth_google](https://github.com/mishka-group/mishka_cms_auth_google), [mishka_cms_auth_github](https://github.com/mishka-group/mishka_cms_auth_github), [mishka_cms_auth_slack](https://github.com/mishka-group/mishka_cms_auth_slack) and [mishka_cms_auth_discord](https://github.com/mishka-group/mishka_cms_auth_discord). Plugins and events run on [Mishka Installer](https://mishka.tools/installer), and the UI components come from [Mishka Chelekom](https://mishka.tools/chelekom).

## ✨ Features

- Many sites from one install. Master users manage every site, tenant users see only their own, and the data layer keeps tenants apart. See [multi-tenant sites](https://mishka.tools/cms#tenant).
- Live editing. A visual page builder and a code editor write pages in HEEx, EEx or Markdown. Drafts autosave, a draft can be previewed through a shareable link, and every saved version can be restored.
- A stylesheet and a script bundle for each site, built at runtime from that site's own templates, Tailwind CSS v4 styles and JavaScript hooks.
- SEO from the page itself: title, description, canonical address, Open Graph and Twitter tags, JSON-LD, a `sitemap.xml` and `robots.txt` for every site, and a 1200 x 630 share card for a page with no image of its own.
- Several languages per site, translation keys for templates (`t("nav.blog")`), and dates, numbers and language names written the way each language writes them.
- Sign-in controls: password or emailed sign-in link, optional two-step sign-in with an authenticator app and recovery codes, rate limits per IP address and per account, and a captcha from Cloudflare Turnstile, Google reCAPTCHA or hCaptcha, chosen per site.
- Permissions written as plain names such as `admin:dashboard:blog:post`, with wildcards, separate for the dashboard and for the API.
- An admin that updates live over LiveView, with notifications and an activity log.
- A JSON:API under `/api/json`, described by an OpenAPI spec, with Swagger UI for API admins.
- Plugins instead of forks. Every action fires a named event such as `blog:comment:after_create` through Mishka Installer, and plugins hook in by priority.
- A first-run install wizard, and blog and documentation extensions you can install per site.

The website's [features section](https://mishka.tools/cms#platform) walks through the main ones.

## 🚀 Getting started

You need Elixir 1.20 or newer (`.tool-versions` pins Elixir 1.20.5 on Erlang/OTP 29.1.2), PostgreSQL and [bun](https://bun.sh). In development the app connects to PostgreSQL as `postgres` with the password `postgres`; `DB_HOST` and `DB_NAME` change the host and the database name.

```bash
git clone https://github.com/mishka-group/mishka_cms.git
cd mishka_cms

mix deps.get
mix assets.setup

mix ecto.create
mix oban.install --yes
mix ash.codegen cms_with_extensions
mix ash.migrate

mix assets.build
mix phx.server
```

The migrations are generated and not stored in the repository, so `mix ash.codegen` is part of the setup. `mix dev_reset` repeats the database steps from an empty database and drops the existing one.

Open <http://localhost:4000>. Until the CMS is installed, every request goes to `/install`. The wizard creates the master admin and the first site, lets you choose the Chelekom components and the extensions to install, and sets the site title, the sender address and the languages. When it finishes, sign in with the master account.

For a development database filled with sample sites, users, pages, blog posts and documents, run `mix run priv/repo/dev_seeds.exs`.

Without a local Elixir or PostgreSQL, use the development container in `examples/docker`, which has Elixir, bun and a PostgreSQL 18 database, and run the same `mix` commands inside it:

```bash
docker compose -f examples/docker/dev-docker-compose.yml up -d
docker compose -f examples/docker/dev-docker-compose.yml exec app bash
```

## 🧪 Try it

To see Mishka CMS running without installing Elixir, use the demo image. It has the default extensions, and it is for trying only, not for production: its migrations were generated for one release, so a newer demo needs a fresh database.

```bash
docker pull ghcr.io/mishka-group/mishka_cms-demo:0.0.2
```

[`examples/docker/demo-docker-compose.yml`](examples/docker/demo-docker-compose.yml) starts it with PostgreSQL 18. It explains how to make the secrets. One of them, `MISHKA_SETUP_TOKEN`, is the token the installer at `/install` asks for. The image is built for linux/amd64 and linux/arm64, and `gh attestation verify oci://ghcr.io/mishka-group/mishka_cms-demo:0.0.2 --owner mishka-group` checks that this repository's release workflow built it.

## 🚢 Deploy

A real install is your own copy of this repository, built with the `Dockerfile` in its root. The migrations are yours too. They follow the extensions your copy loads (`ash_domains` in `config/config.exs`), so this repository does not keep them, and you generate them once and commit them:

```bash
mix oban.install --yes
mix ash.codegen first_install
git add priv/repo/migrations priv/resource_snapshots
```

`mix ash.codegen` writes the migrations to `priv/repo/migrations` and the snapshots they came from to `priv/resource_snapshots`. Commit both: the next `mix ash.codegen` compares your resources with the snapshots and writes only the difference. The build checks them. It fails when there is no migration, and when your resources have changed since the last `mix ash.codegen`, and its message says what to run.

Run the image with `DATABASE_URL`, `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET` set, and `MISHKA_SETUP_TOKEN` for the first run: `/install` refuses everyone without it, and you open it as `/install?token=...`. Set `SESSION_SIGNING_SALT` too, to replace the default salt of the session cookie. Mount a volume at `MISHKA_DATA_DIR` (`/app/mishka_data` in the image) for Mnesia, uploaded files and caches. Run `/app/bin/migrate` before `/app/bin/server`.

To upgrade, bump the Mishka packages in `mix.exs` and run `mix deps.update` for them, then `mix ash.codegen upgrade_<version>`, commit what it wrote, and deploy. `/app/bin/migrate` runs only the migrations the database has not run yet.

`mix dev_reset` deletes `priv/repo/migrations` and `priv/resource_snapshots` and generates them again, so use it only on a throwaway development database, never on one whose migrations you have deployed.

## 📚 Documentation

- [Mishka CMS documentation](https://mishka.tools/cms/docs), which is still being written
- [Features](https://mishka.tools/cms#platform), [multi-tenant sites](https://mishka.tools/cms#tenant), the [interactive admin preview](https://mishka.tools/cms#demo) and the [extensions](https://mishka.tools/cms#extensions)
- The [Mishka Blog extension](https://mishka.tools/cms/extensions/blog) and the [Mishka Document extension](https://mishka.tools/cms/extensions/documentation)
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- The [Mishka blog](https://mishka.tools/blog), for releases and articles

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom extension, a migration from another CMS or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS is free and open source. You can support its development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
