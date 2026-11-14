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
| mishka_blog | 0.0.3-alpha.8 | — | — | none | env, hex identity, staged |
| mishka_document | 0.0.3-alpha.4 | — | — | none | env, hex identity, staged |
| mishka_cms_builder | 0.0.1-alpha.8 | — | — | none | env, hex identity, staged |
| mishka_cms_migration | 0.0.4-alpha.1 | — | — | none | env, hex identity, staged |
| mishka_cms_auth_slack | 0.0.3-alpha.2 | — | — | none | env, hex identity, staged |
| mishka_cms_auth_google | 0.0.3-alpha.2 | — | — | none | env, hex identity, staged |
| mishka_cms_auth_github | 0.0.3-alpha.2 | — | — | none | env, hex identity, staged |
| mishka_cms_auth_discord | 0.0.3-alpha.2 | — | — | none | env, hex identity, staged |
| mishka_gervaz | 0.0.10 | — | — | none | env, hex identity, staged |
| guarded_struct | 0.1.7 | — | — | none | env, hex identity, staged |
| mishka_installer | 0.1.16 | — | — | none | env, hex identity, staged |
| mishka_developer_tools | 0.1.10 | — | — | none | env, hex identity, staged |
| mishka_chelekom | 0.0.11-alpha.4 | — | — | protected + ruleset `main` (review required) | env, hex identity, staged, App bypass on the ruleset |
| kati | not on Hex | — | — | none | first publish by hand, then env, hex identity, staged |
| mishka_cms (host) | not a Hex package | — | n/a | none | its `v*` tag builds the demo image `ghcr.io/mishka-group/mishka_cms-demo`; no Hex steps |
