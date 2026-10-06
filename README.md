## Direct Dev usage

```bash
mix deps.get
mix deps.compile
mix compile
mix ecto.drop # if you have before
mix ecto.create
# Delete everything inside the `priv/resource_snapshots/repo`
# Delete everything inside the `priv/repo/migrations` except `.formatter.exs`
mix oban.install
mix ash.codegen cms_with_extensions
mix ash.migrate
mix run priv/repo/dev_seeds.exs

# Note it would be better to run `mix tailwind.install` and `mix esbuild.install` one time!, before starting server
iex -S mix phx.server
```

### Import all components from Mishka Chelekom
```elixir
cd ../mishka_chelekom
# → writes priv/components/chelekom.json
mix mishka.ui.export priv/components --cms --name chelekom --yes

# Copy from Mishka Chelekom to Mishka CMS
cp priv/components/chelekom.json \
../__extensions/mishka_cms_core/priv/cms_ui_kits/chelekom.json

# After it, we can install with this function in iex
MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_chelekom!(cleanup: true)
```

## Docker Dev

```bash
docker compose -f dev-docker-compose.yml up -d
docker compose -f dev-docker-compose.yml down
docker exec -it elixir_dev bash
````

## Docker Dev Database

```bash
<!-- You need it one time, or make data fresh -->
mix ecto.drop; mix ash.setup; mix run priv/repo/entry_dev_test_seeds.exs ; iex -S mix phx.server
```


```
npx openapi-typescript http://localhost:4000/api/json/open_api -o api-types.ts
```

## Permission names

Every admin permission is a plain string, `admin:<surface>:<area>[:<sub_area>]`, written in full
where it is used and never built from pieces. `test/mishka_cms/permission_names_test.exs` fails the
build on a name that does not follow the grammar (a typo or an old name), on one neither the core
install nor an extension's install creates, and on a list that names a wildcard beside a name it
covers.

- **Surface**: `dashboard` is the admin screens and the data they read and write. `api` is the admin
  JSON:API, GraphQL and the `/ws/gql` socket. A request on the API runs with
  `shared: %{admin_surface: :api}` in its Ash context (`MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug`).
  A policy lists both surfaces' names, and `MishkaCmsCore.Accounts.Checks.AccessPermissions` counts
  an `admin:dashboard:` name only on the dashboard and an `admin:api:` name only on the API.
- **Area**: a singular, lower snake_case noun. The runtime sections are `runtime:site`,
  `runtime:page`, `runtime:layout`, `runtime:component`, `runtime:error_page`,
  `runtime:stylesheet`, `runtime:js_hook`, `runtime:media`, `runtime:translation` and
  `runtime:activity`; the others are `setting`, `user` and `permission`. An extension's area is its
  name and its section: `blog:post`, `blog:comment`, `document:workspace`, `document:section`.
- **Code**: `code` (both surfaces) writes every code-bearing runtime type, and
  `admin:dashboard:code` opens every builder. There is no builder name.
- **Wildcards**, only as the whole last segment: `*` (everything within the holder's own site, both
  surfaces), `admin:*` (both surfaces), `admin:dashboard:*` (the whole dashboard and nothing on the
  API), `admin:api:*` (the whole API and nothing on the dashboard), `admin:<surface>:runtime:*`
  (every runtime section), `admin:<surface>:<extension>:*`. A held wildcard covers every name under
  it, so a gate lists only the leaf names it means.
- **Any admin of a surface** is not a name. It is the entry `{:under, "admin:dashboard"}` (or
  `{:under, "admin:api"}`), held by anyone holding anything under that prefix. The dashboard door,
  Home, Notifications and Settings ask it.
- A master is a user with no site. No permission makes one.

### Runtime rules

The code-bearing types are pages, layouts, components, error pages, stylesheets and JS hooks.

- **Reading** them (lists, records, drafts, versions) is open to any admin of the surface.
- **Writing** a code-bearing type T (create, update, delete, restore, its code included) takes
  `runtime:T` or `code`:
  `permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page", "admin:dashboard:code", "admin:api:code"]`.
  `runtime:T` alone writes T's code; `code` alone writes all six types.
- **The builder** is a dashboard screen. On a page, layout, component or error page it opens for
  that type's `admin:dashboard:runtime:` name or `admin:dashboard:code`:
  `admin:dashboard:runtime:page` alone opens the page builder and no other. The
  builder's own rows for that type (history, snapshots, review notes, snippets, builder events)
  follow the same rule. What every builder shares (element CSS, reusable classes, design tokens,
  the studio and preset settings, the Builder sidebar entries) takes any of the four types' names
  or `code`.
- **A site's `page_code` switch** set to off stops Elixir and typed HEEx for everyone.
- **Sites, media, translations and activity** take `runtime:<section>` for every write, for reading
  activity, and for every read of sites but `read_any` and `get_any`. Media and translations are
  read by any admin. Code plays no part.

### Adding an area

1. Add its names, with a description each, to the list its install creates: the core's in
   `MishkaCmsCore.Install.Bootstrap` (`permissions/0`), created by the install and the dev seeds; an
   extension's in the `permissions:` of its provision manifest, created when the extension is installed
   on a site (Set up, or the install wizard's extensions step), as its components and pages are.
2. Enforce it on the data, one name per surface:
   `authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}`.
3. Gate the screen with the dashboard name: the sidebar item's `permissions:`
   (`["admin:dashboard:blog:post"]`), which `MishkaCmsCore.Sidebar.PageGuard` also reads. Widgets
   and settings take the same list.
4. Test it as a limited admin holding only that area (allowed), as a holder of another area
   (refused), and through the API with `admin:api:<area>` (allowed) against
   `admin:dashboard:<area>` (refused).

Stored names are never renamed: a name that is no longer checked grants nothing.

### Dev seed accounts

`mix run priv/repo/dev_seeds.exs` gives every dev site (`localhost`, `site-a`, `site-b`) these
accounts, all with the seeds' development password:

| Account | Holds |
| --- | --- |
| `admin@<site>.test` | `*` |
| `viewer@<site>.test` | nothing |
| `builder@<site>.test` | `admin:dashboard:runtime:page` (pages with their code, and the page builder) |
| `developer@<site>.test` | `admin:dashboard:code` (every code-bearing type, and every builder) |
| `writer@<site>.test` | `admin:dashboard:blog:post` |
| `moderator@<site>.test` | `admin:dashboard:blog:comment` |
| `editor@<site>.test` | `admin:dashboard:document:section` |
| `accounts@<site>.test` | `admin:dashboard:user`, `admin:dashboard:permission` |
| `api@<site>.test` | `admin:api:*` (no dashboard) |

`<site>` is the site's name: `admin@site-a.test`. `master@example.com` and `master1..3@example.com`
are masters holding `*`; `none@example.com` (localhost) holds nothing.
