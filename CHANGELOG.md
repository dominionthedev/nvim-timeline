# Changelog

## Unreleased

- Branching and checkout: `:TimelineBranch`, `:TimelineBranches`,
  `:TimelineCheckout`. Checkout never writes to disk on its own —
  landing on a branch tip is a persisted switch, landing on an older
  non-tip commit is a transient "detached" state that only becomes a
  real commit if you save, at which point you're prompted to name a
  new branch.
- Refactored the four separate commit call-sites (known path,
  exact-hash relink, candidate-link, brand new) into one
  `commit_to_timeline` function, now that branches made the earlier
  duplication a real correctness risk, not just repetition.
- Fixed a regression introduced by that same refactor: the no-op-save
  skip check needs to require the path be unchanged too, not just the
  content hash — a relink-after-recreation event has the same hash by
  definition (that's why it matched) but is not a no-op, since it
  records that the file reappeared at a new path.
- Added `tests/smoke_branching.lua` covering detached checkout,
  save-prompts-for-branch-name, branch switching, and explicit branch
  creation.
- Fixed `tests/helpers.lua`: disabled swapfiles (a killed test run
  could leave a stale swapfile that hangs the next run on an
  interactive prompt) and force-quit on `finish()` (checkout
  deliberately leaves buffers unsaved, which a plain `:qa` blocks on).
- CI: wrapped each test in `timeout 30` so a future hang fails the
  build instead of stalling the runner indefinitely.

## Unreleased (earlier)

- Initial v1 core: content-addressed store, identity index, lazy
  write-time correlation (exact-hash auto-link, same-basename prompt),
  direct rename handling via `BufFilePre`/`BufFilePost`, append-only
  commit log, `:TimelineLog` inspection command.
