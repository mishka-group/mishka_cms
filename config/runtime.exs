import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mishka_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mishka_cms, MishkaCmsWeb.Endpoint, server: true
end

# AN HMAC OVER EVERY STORED SNIPPET, so Elixir that did not come through this application does not
# run. Off unless a key is set, which is what lets it be turned on for an existing database.
#
# Read in every environment rather than in the prod block below, because the case it exists for —
# a database restored from somewhere else — is one that happens to a developer's machine and to
# staging far more often than to production. A dump carries the signatures of the environment that
# made it, so on the next boot every handler and every live component's `handle_event/3` in it
# compiles to a clause that does nothing. `MishkaCmsCore.Runtime.PageBuilder.CodeAudit` counts them
# at boot and `mix mishka.resign_code` is the fix.
#
# See `MishkaCmsCore.Runtime.PageBuilder.CodeSignature`.
config :mishka_cms_core, code_signing_key: System.get_env("CODE_SIGNING_KEY")

if config_env() == :prod do
end
