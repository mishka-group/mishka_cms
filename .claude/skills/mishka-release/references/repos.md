# Per-repo release state

Update a row as soon as the owner finishes a step; this table is the only place this state is kept. Check live values with:

```bash
gh api repos/mishka-group/<repo>/environments --jq '[.environments[].name]'
gh api repos/mishka-group/<repo>/branches/master --jq .protected
curl -s https://hex.pm/api/packages/<package> | python3 -c "import sys,json;print(json.load(sys.stdin)['latest_version'])"
```

Hex workload identity and staged publishing can't be read from here; they are marked from the owner's word.

| Repo (package) | Hex latest (2026-11-14) | `release` env | Hex identity + staged | Branch rules | Still to do before a CI release |
|---|---|---|---|---|---|
| mishka_cms_core | 0.0.5-alpha.18 (first CI release) | yes | yes | none | nothing |
| mishka_slug | 0.0.2 | yes | yes | none | nothing |
| mishka_blog | 0.0.3-alpha.9 | yes | yes | none | nothing |
| mishka_document | 0.0.3-alpha.4 | yes | yes | none | nothing |
| mishka_cms_builder | 0.0.1-alpha.8 | yes | yes | none | nothing |
| mishka_cms_migration | 0.0.4-alpha.1 | yes | yes | none | nothing |
| mishka_cms_auth_slack | 0.0.3-alpha.2 | yes | yes | none | nothing |
| mishka_cms_auth_google | 0.0.3-alpha.2 | yes | yes | none | nothing |
| mishka_cms_auth_github | 0.0.3-alpha.2 | yes | yes | none | nothing |
| mishka_cms_auth_discord | 0.0.3-alpha.2 | yes | yes | none | nothing |
| mishka_gervaz | 0.0.10 | yes | yes | none | nothing |
| guarded_struct | 0.1.7 | yes | yes | none | nothing |
| mishka_installer | 0.1.16 | yes | yes | none | nothing |
| mishka_developer_tools | 0.1.10 | yes | yes | none | nothing |
| mishka_chelekom | 0.0.11-alpha.4 | yes | yes | protected + ruleset `main` (review required); it matters only for the Release button (its version commit), not for a tag push | nothing |
| kati | not on Hex | yes | after its first publish | none | the owner's first `mix hex.publish` by hand (Hex can't create a package from CI); then ready |
| mishka_cms (host) | not a Hex package | — | n/a | none | its `v*` tag builds the demo image `ghcr.io/mishka-group/mishka_cms-demo`; no Hex steps |
