# Changelog

## Unreleased

- **Renamed nvim-timeline -> timeline.nvim** (module `require("timeline")`,
  help tag `timeline.nvim`). Commands are unaffected (they were always
  bare `:Timeline*`, no `Nvim` prefix).
- **Replaced the popup picker with a persistent sidebar** (`Split` +
  `Tree`, not `Menu` + `Layout`), similar in spirit to VSCode's Timeline
  panel: branches as top-level tree nodes, commits nested underneath,
  updates live as you switch buffers. The popup picker was the wrong UI
  paradigm for what was actually wanted -- this isn't a tweak of the old
  `view.lua`, it's a replacement (`view.lua` and its tests are removed).
- **Split "view" from "checkout" into two distinct, differently-risky
  actions.** `:TimelineShow` / `<CR>` in the sidebar opens a read-only
  `timeline://` buffer diffed against your current buffer (real Neovim
  diff mode) and never touches your working buffer. `:TimelineCheckout`
  / `c` in the sidebar is the destructive-into-your-buffer operation.
  Conflating these was a real design gap in the picker version.
- **Checkout safety**: checkout now refuses to run when the current
  buffer has unsaved changes, unless forced (`:TimelineCheckout!` or
  confirming the sidebar's prompt) -- forcing stashes the dirty content
  into the store first rather than silently discarding it.
  `:TimelineStashes` / `:TimelineStashShow` list and recover stashes the
  same way any other historical version is viewed. Automatic
  stash-reapplication is a deliberate, named v2+ feature, not built here
  -- a plausible-but-wrong automatic merge is worse than a manual one.
- **Storage moved from a per-project `.nvim-timeline/` directory to a
  single location under `stdpath("state")/timeline/`**, one subdirectory
  per project, disambiguated by a `meta.json` mapping each project's
  real (symlink-resolved) path to its directory name -- two different
  projects sharing a basename no longer collide, and the same project
  opened via a symlink no longer gets a second store. New module:
  `paths.lua`.
- Fixed a real bug found while wiring the sidebar's branch-from-commit
  action through: `branch_from_commit` was passing the same table as
  both the `paths` and `timelines` arguments to `index.save`, which
  would have corrupted `index.json`'s path map the first time anyone
  used that action with a real save. No test exercised it end-to-end
  before now. `current_timeline()` now returns `paths` so this can't
  recur, and a regression test in `smoke_sidebar_integration.lua`
  exercises the real save path.
- Fixed a second real bug in the same area: the sidebar's `b` (branch
  off a commit) keymap resolved against the *current* buffer, which is
  the sidebar's own nameless buffer when the keymap fires, not the
  tracked file -- caught immediately by actually running the integration
  test, not by inspection.
- Fixed a `W10: readonly` warning in the `timeline://` viewer: content
  was re-written after re-enabling `modifiable` but without also
  clearing `readonly`, which is a separate option Neovim checks
  independently.
- Added a full `:help timeline.nvim` reference (`doc/timeline.txt`),
  checked programmatically (every `|link|` verified to actually resolve
  via `:help`, not just eyeballed) rather than assumed correct.
- Rewrote README.md for the new architecture (sidebar, storage location,
  view/checkout split, safety, stashes).

## Unreleased (earlier)

- **The picker**: `:TimelineView`, built directly on nui.nvim (`Menu` +
  `Layout`), not wrapped around another picker plugin. Commit list with
  live diff-vs-parent preview, branch cycling (`<Tab>`), checkout
  (`<CR>`), and branch-from-any-commit (`b`). nui.nvim is now a real
  dependency (see README install snippet).
- Added `diff.lua`, a thin wrapper around `vim.diff` (unified diffs, no
  external dependency).
- **Fixed a latent graph-identity bug**, found while designing the
  picker rather than by accident: parent pointers were keyed by content
  hash, which breaks the moment a commit's content matches its own
  parent's -- which a relink commit always does by definition (that's
  what made it match). Walking history by hash couldn't tell "found the
  parent" from "found myself." Every commit now carries a strictly
  increasing `seq`, which becomes the real graph identity; `hash` is
  content-only from here on. `index.lua`'s branch tips are now
  `{hash, seq}` pairs instead of bare hash strings.
- Added `history.lua`: a pure, UI-free function that walks a branch's
  commit chain by `seq`, with a regression test reproducing the exact
  repeated-hash scenario that broke the old hash-based approach.
- `log.find` (used by `:TimelineCheckout`) now also accepts a bare
  `seq` number, not just a hash prefix.

## Unreleased (earlier)

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
