# 1. An error page is drawn inside one boundary

## Context

A site's error page is a template its admin writes. It can raise, or fail to compile, while the
request it answers has already failed.

## Decision

`lib/mishka_cms_web/controllers/error_html.ex` draws it inside one boundary. A page that does not
compile is kept in `MishkaCmsCore.Runtime.States.CompileFailureState`, so a request reads that state
instead of compiling again. When the page cannot be drawn, the request gets the plain message with
the status it had, and one short warning is logged. A site with no error page gets Phoenix's page.

## Consequences

One `catch` on that path, with its reason written beside it; no other `rescue` on pages many users
hit. Admin mistakes never turn an error into a crash loop.
