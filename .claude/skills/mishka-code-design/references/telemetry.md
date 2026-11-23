# Telemetry

Every Mishka library emits telemetry the same way, so a host attaches one handler style to all of
them and a test waits on an event instead of on the clock.

## Names

`[:<otp_app>, :<area>, <what>]`, all atoms, lowercase with underscores:

- `<otp_app>` is the library's application name: `:mishka_installer`, `:mishka_pay`. mishka_cms_core
  and its extensions use `:mishka_cms`.
- `<area>` is the part of the library: `:event`, `:mnesia`, `:request`, `:credentials`, `:runtime`.
- `<what>` is either the suffix `:telemetry.span/3` adds (`:start`, `:stop`, `:exception`) for work
  with a duration, or one word for a single moment: past tense for what happened (`:synchronized`,
  `:compiled`, `:queued`, `:redrawn`), or the name of the step about to happen (`:retry`).

Examples: `[:mishka_installer, :event, :compile]`, `[:mishka_cms, :sidebar, :redrawn]`,
`[:mishka_pay, :request, :start]`, `[:mishka_pay, :credentials, :stop]`.

## What goes in it

- Use `:telemetry.span/3` for anything that takes time (a request, a fetch, a compile); add the
  outcome to the `:stop` metadata (`:status`, `:outcome`).
- Measurements are numbers (`:duration` comes from the span, `:wait` in milliseconds, counts).
- Metadata names the subject (`:provider`, `:tenant`, `:site_id`, `:path`) and the cause
  (`:status`, `:reason`, `:attempt`). Never a key, token, password, body or personal data.
- List every event in the moduledoc of the module that emits it, under a "Telemetry" heading or
  bullet, with its measurements and metadata.

## Tests

Attach with `:telemetry_test.attach_event_handlers(self(), events)` and `assert_received` /
`assert_receive` the `{event, ref, measurements, metadata}` message, matching metadata that only
this test's call can carry (its path, tenant or id), since async tests share the handlers. When code
has nothing to wait on, adding the event is the fix.
