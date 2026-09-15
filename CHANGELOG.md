# Changelog

## Unreleased

- Initial v1 core: content-addressed store, identity index, lazy
  write-time correlation (exact-hash auto-link, same-basename prompt),
  direct rename handling via `BufFilePre`/`BufFilePost`, append-only
  commit log, `:TimelineLog` inspection command.
- No branch switching, checkout, or picker UI yet — log schema
  reserves a `branch` field but only `"main"` is written in v1.
