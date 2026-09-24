# timeline.nvim

Git-like history for individual files in Neovim, shown in a persistent
sidebar -- the part vim's `undofile` can't do: a file's history survives
being deleted and recreated, because identity is tracked independently
of path.

## Status: v1

Store, identity correlation, branching, checkout, the sidebar, and
checkout safety (stashing instead of silently discarding unsaved
changes) are all implemented and covered by real tests (see `tests/`),
including ones that drive the actual UI with real keypresses.

## The sidebar

`:TimelineView` opens (and re-running it closes) a persistent sidebar,
similar in spirit to VSCode's Timeline panel -- it stays open and
updates to show whatever file you're currently editing, rather than a
one-shot popup you reopen every time.

Branches are the top-level tree nodes; commits nest underneath,
newest first. A commit shared by more than one branch (an ancestor
both descend from) appears once under each such branch -- that's the
same thing `git log <branch>` shows you per branch, not a bug.

Keys (cursor in the sidebar):

```
<CR>   on a commit: open a read-only diff view of it in a split
       (see "Viewing vs. checkout" below) -- never touches your buffer
       on a branch: expand/collapse it
c      check out the highlighted commit into the file you're tracking
       (destructive into that buffer -- see the safety notes below)
b      branch off the highlighted commit, whether or not it's a tip
q      close the sidebar
```

## Viewing vs. checkout -- two different risk levels, two different keys

- **View** (`<CR>` in the sidebar, or `:TimelineShow {ref}`) opens the
  historical content read-only in a `timeline://` buffer, diffed
  against your current buffer (real diff mode: `]c`/`[c`, syntax
  highlighting, the works). **Your working buffer is never touched.**
- **Checkout** (`c` in the sidebar, or `:TimelineCheckout {ref}`) loads
  that version into your actual working buffer, so you can keep
  editing from there. This is the one that can affect your buffer.

Conflating these into one action was a real design mistake in an
earlier pass of this plugin -- they're different-risk operations and
now have different keys/commands on purpose.

## Checkout safety

Checkout refuses to run if your buffer has unsaved changes, unless you
force it (`:TimelineCheckout!`, or confirming the sidebar's prompt).
Forcing never silently discards your edit: the dirty content is
snapshotted into the store as a stash first. List stashes with
`:TimelineStashes`, and recover one exactly like viewing any other
historical version with `:TimelineStashShow {n}` (a read-only diff, not
an automatic re-application -- you decide what to carry over by hand).

Automatically re-applying a stash on top of a different version (the
way `git stash pop` sometimes silently succeeds) is a deliberate v2+
idea, not done here: a plausible-looking but subtly wrong automatic
merge is a worse failure mode than "here's your old content side by
side, go copy what you need."

## How it works

- Every save (`BufWritePost`) either appends a commit to the current
  file's timeline, or — if the path isn't already tracked — decides
  whether this is a brand new file or the continuation of one that was
  deleted. That decision is made lazily, at write-time, by comparing
  content hashes against orphaned timelines (ones whose last known path
  no longer exists). No filesystem watcher, no background daemon.
  - **Exact hash match** → linked automatically. No ambiguity.
  - **Same basename, no hash match** → you're prompted. Guessing here
    risks silently merging two unrelated files' history, which is
    worse than not linking at all.
  - **Neither** → treated as genuinely new.
- Renames done through Neovim itself (`:saveas`, `:file`, or anything
  using `nvim_buf_set_name`) are handled separately and directly —
  Neovim hands over the old and new name with zero ambiguity, so this
  never goes through the hash-guessing path at all.
- A deletion is _discovered_ on the next related write, not witnessed
  live. If you want a plugin that timestamps the exact moment of
  deletion, this isn't it — that requires a filesystem watcher, which
  was a deliberate scope cut for v1.
- Divergence and branching: if you check out an older commit that
  isn't any branch's current tip and then save, the buffer is in a
  transient "detached" state -- you're prompted to name a new branch
  before anything is committed. The branch you diverged _from_ is
  never rewritten or lost; it keeps its own forward history untouched
  while your new branch grows from the point you diverged at.
- Commit graph identity is a strictly increasing sequence number
  (`seq`), not content hash -- a relink commit legitimately has the
  same hash as its own parent (that's what made it match in the first
  place), so hash alone can't be the graph's identity.

## Storage

```
<stdpath("state")>/timeline/
  meta.json                  real_project_root -> dirname
  <dirname>/
    index.json               current_path -> timeline_id, branches, stashes
    objects/<xx>/<hash>      content-addressed blobs, deduplicated
    log/<timeline_id>.jsonl  append-only commit records
```

One store directory per project, all living under Neovim's own state
directory rather than scattered `.timeline/` folders inside your
projects. A project's directory name matches its basename unless
another, genuinely different project already claimed that basename --
`meta.json` is what remembers which real path a given directory
actually belongs to, and a project's real path (symlinks resolved) is
always used as the lookup key, so opening the same project two
different ways never creates two stores.

## Install (lazy.nvim)

```lua
{
  "dominionthedev/timeline.nvim", -- update once the repo itself is renamed
  dependencies = { "MunifTanjim/nui.nvim" },
  config = function()
    require("timeline").setup({})
  end,
}
```

The sidebar is built directly on nui.nvim's `Split` and `Tree` -- not
wrapped around telescope, snacks.nvim, or any other picker/sidebar
plugin -- so it's the one real dependency.

## Commands

- `:TimelineView` — toggle the sidebar.
- `:TimelineShow {ref}` — view a branch or commit read-only, diffed.
  Never touches your buffer.
- `:TimelineCheckout[!] {ref}` — load a branch or commit into the
  current buffer. `{ref}` accepts a branch name, a bare seq number
  (e.g. `7`), or a hash prefix. Refuses on unsaved changes unless `!`
  is given, in which case the dirty content is stashed first.
- `:TimelineBranch {name}` — create a branch at the current tip and
  switch to it.
- `:TimelineBranches` — list branches for the current file.
- `:TimelineStashes` / `:TimelineStashShow {n}` — list and view stashes
  created by forced checkouts.
- `:TimelineLog` — print the raw commit log for the current file
  (mainly a debugging aid; the sidebar is the real way to browse).

Full details: `:help timeline.nvim`.

## What's deliberately not here yet

- Automatic stash re-application (see "Checkout safety" above) --
  planned as a real v2 feature, not a gap left by accident.
- Branch merging (not planned — this is single-writer history; a
  branch is just a second named tip, not a mergeable line).
- A filesystem watcher for live-witnessed deletions (explicitly out of
  scope — see "How it works" above).
- Fuzzy filtering in the sidebar (it's a plain tree -- fine at the
  scale of one file's history, revisit if that stops being true).

## Testing

```sh
git clone --depth 1 https://github.com/MunifTanjim/nui.nvim.git .deps/nui.nvim  # once, for the sidebar tests
for f in tests/smoke_*.lua; do nvim --headless -u NONE -c "luafile $f"; done
```

Tests assert real behavior end to end, including ones that drive the
sidebar with actual keypresses (`smoke_sidebar_integration.lua`) rather
than only checking that it opens without erroring.
