<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)
[![Discord](https://img.shields.io/badge/Discord-Mishka_Tools-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/m4zdCJjDJg)

# Mishka CMS

**An [open source real-time CMS](https://mishka.tools/cms) for Elixir and Phoenix LiveView. One install runs many websites.**

[Website](https://mishka.tools/cms) · [Documentation](https://mishka.tools/cms/docs) · [Admin preview](https://mishka.tools/cms#demo) · [Discord](https://discord.gg/m4zdCJjDJg) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka CMS?

Mishka CMS is an [open source real-time CMS](https://mishka.tools/cms) built on Elixir, Phoenix LiveView and the Ash framework. You build pages in the browser, publish them without a redeploy, and run many websites from one install.

This repository is the application that runs it: the Phoenix endpoint, the router, the release scripts and the Dockerfile. The engine and the extensions are packages it loads from Hex.

## ✨ Why Mishka CMS

- 🌐 **[Many websites, one install](https://mishka.tools/cms/docs/sites-and-masters)**: each brand, client or market gets its own site with its own domain, languages, users and content. One master account runs them all.
- 🎨 **[Visual page builder](https://mishka.tools/cms/docs/build-a-page)**: place sections and components on a live canvas, edit text in place and check every screen size. The code behind the page is one click away.
- ⚡ **[Publish without a redeploy](https://mishka.tools/cms/docs/how-pages-reach-visitors)**: pages, layouts and components live in the database and compile while the app runs. Visitors with the page open get the new styles at once.
- 📝 **[Drafts and versions](https://mishka.tools/cms/docs/drafts-and-versions)**: your work saves to a draft, teammates [review it from a link](https://mishka.tools/cms/docs/share-a-draft), and every earlier version can be restored.
- 🔍 **[SEO with no setup](https://mishka.tools/cms/docs/page-seo)**: every page ships with its title, description, canonical link, social preview and structured data, and pages without an image get a share card drawn for them. Each site has its own sitemap and robots.txt.
- 🌍 **[Every language you publish in](https://mishka.tools/cms/docs/languages)**: one site serves several languages, with addresses like `/fa/blog`, [translated pages](https://mishka.tools/cms/docs/translate-a-page) and [interface words](https://mishka.tools/cms/docs/translate-interface), and dates and numbers in each language's own format.
- 🔐 **[Secure sign-in](https://mishka.tools/cms/docs/secure-sign-in)**: passwords or emailed sign-in links, two-step sign-in with an authenticator app, rate limits, and a captcha from Cloudflare Turnstile, Google reCAPTCHA or hCaptcha.
- 🛡️ **[Permissions you can read](https://mishka.tools/cms/docs/permissions)**: names like `admin:dashboard:blog:post`, with wildcards, kept apart for the dashboard and the API. [Lock a page](https://mishka.tools/cms/docs/lock-a-page) or a post to members.
- 🔌 **[Headless, coupled or both](https://mishka.tools/cms/docs/headless-or-coupled)**: a site serves its own pages, a [JSON:API](https://mishka.tools/cms/docs/json-api) for your frontend, or both. The API comes with an OpenAPI spec and Swagger UI.
- 🧩 **[Plugins instead of forks](https://mishka.tools/cms/docs/extensions-and-plugins)**: every action fires a named [event](https://mishka.tools/cms/docs/plugin-events) such as `blog:comment:after_create`, and your plugin hooks in by priority.
- 🧱 **[Components and UI kits](https://mishka.tools/cms/docs/components-and-ui-kits)**: install a kit of ready components, [write your own](https://mishka.tools/cms/docs/custom-code), and reuse [snippets and design tokens](https://mishka.tools/cms/docs/snippets-and-tokens) across a site.
- 🧰 **Everything a site needs**: a [media library](https://mishka.tools/cms/docs/media), [forms](https://mishka.tools/cms/docs/add-a-form), [redirects](https://mishka.tools/cms/docs/redirects), [email delivery](https://mishka.tools/cms/docs/send-email) and an [activity log](https://mishka.tools/cms/docs/activity-log) of every change.
- 🤖 **[Bring your own AI model](https://mishka.tools/cms/docs/connect-an-ai-model)**: connect a model to the editor's Assistant with one Elixir module, and undo its edits like your own.

## 🚀 Get started

Follow **[Install Mishka CMS and sign in](https://mishka.tools/cms/docs/install)**, then [build your first site](https://mishka.tools/cms/docs/first-site) and [start a blog](https://mishka.tools/cms/docs/start-a-blog). In short, with Elixir 1.20 or newer, PostgreSQL and [bun](https://bun.sh):

```bash
git clone https://github.com/mishka-group/mishka_cms.git && cd mishka_cms
mix deps.get && mix assets.setup
mix ecto.create && mix oban.install --yes
mix ash.codegen cms_with_extensions && mix ash.migrate
mix assets.build && mix phx.server
```

Open <http://localhost:4000>, and the install wizard creates the master admin and the first site. `mix run priv/repo/dev_seeds.exs` fills a development database with sample sites and content. Without a local Elixir or PostgreSQL, use the development container in [`examples/docker`](examples/docker/dev-docker-compose.yml).

## 🧪 Try the demo image

```bash
docker pull ghcr.io/mishka-group/mishka_cms-demo:0.0.2
```

[`demo-docker-compose.yml`](examples/docker/demo-docker-compose.yml) starts it with PostgreSQL 18 and explains the secrets. Open `/install?token=...` with your `MISHKA_SETUP_TOKEN`. The demo is for trying only: its migrations belong to one release, so a newer demo needs a fresh database.

## 🚢 Deploy

A real install is your own copy of this repository, built with its `Dockerfile`.

1. Generate the migrations for the extensions you load and commit them: run `mix oban.install --yes` and `mix ash.codegen first_install`, then commit `priv/repo/migrations` and `priv/resource_snapshots`. The build fails without them.
2. Run the image with `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and `SESSION_SIGNING_SALT`, and with `MISHKA_SETUP_TOKEN` for the first run.
3. Mount a volume at `MISHKA_DATA_DIR` (`/app/mishka_data`), and run `/app/bin/migrate` before `/app/bin/server`.

To upgrade, bump the Mishka packages in `mix.exs`, run `mix deps.update` for them and `mix ash.codegen upgrade_<version>`, commit what it wrote and deploy. `mix dev_reset` regenerates every migration, so keep it to throwaway development databases.

## 🧩 The Mishka CMS family

- **[Mishka CMS Core, the Elixir CMS engine](https://mishka.tools/cms/docs)**: sites, pages, permissions, the runtime compiler and the JSON:API.
- **[Mishka CMS Builder, the visual page editor](https://mishka.tools/cms/docs/build-a-page)**: the live canvas, drafts, history and review notes.
- **[Mishka Blog, the blog extension](https://mishka.tools/cms/extensions/blog)**: posts, categories, tags, authors and moderated comments.
- **[Mishka Document, the documentation extension](https://mishka.tools/cms/extensions/documentation)**: versioned docs, proposed changes as drafts, and issue tracking.
- **[Mishka Gervaz, the admin DSL for Ash](https://mishka.tools/gervaz)**: the toolkit the admin screens are built with.
- **[Mishka Installer, plugins and events for Elixir](https://mishka.tools/installer)**: the event system every plugin hooks into.
- **[Mishka Chelekom, Phoenix LiveView components](https://mishka.tools/chelekom)**: the UI kits the install wizard offers.
- **Sign-in providers**: [Google](https://github.com/mishka-group/mishka_cms_auth_google), [GitHub](https://github.com/mishka-group/mishka_cms_auth_github), [Slack](https://github.com/mishka-group/mishka_cms_auth_slack) and [Discord](https://github.com/mishka-group/mishka_cms_auth_discord).

## 📚 Documentation

- [Mishka CMS documentation](https://mishka.tools/cms/docs): tutorials, how-to guides, reference and concepts
- The [Blog extension docs](https://mishka.tools/cms/extensions/blog/docs) and the [Documentation extension docs](https://mishka.tools/cms/extensions/documentation/docs)
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- The [Mishka blog](https://mishka.tools/blog), for releases and articles

## 💬 Community and support

- Chat with the team and other users on [Discord](https://discord.gg/m4zdCJjDJg).
- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms/issues).
- For a custom extension, a migration from another CMS or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS is free and open source. You can support its development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
