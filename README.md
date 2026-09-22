# nvim-timeline

Git-like history for individual files in Neovim — the part vim's
`undofile` can't do: a file's history survives being deleted and
recreated, because identity is tracked independently of path.

## Status: v1 -- core, branching/checkout, and a real UI

Data layer, identity correlation, branching/checkout, and a nui.nvim
picker with live diff preview are all implemented and covered by real
tests (see `tests/`) -- including one that drives the UI with actual
keypresses, not just checks that it opens without erroring.

## How it works

- Every save (`BufWritePost`) either appends a commit to the current
  file's timeline, or — if the path isn't already tracked — decides
  whether this is a brand new file or the continuation of one that was
  deleted.
- That decision is made lazily, at write-time, by comparing content
  hashes against orphaned timelines (ones whose last known path no
  longer exists). No filesystem watcher, no background daemon.
  - **Exact hash match** → linked automatically. No ambiguity.
  - **Same basename, no hash match** → you're prompted. Guessing here
    risks silently merging two unrelated files' history, which is
    worse than not linking at all.
  - **Neither** → treated as genuinely new.
- Renames done through Neovim itself (`:saveas`, `:file`, or anything
  using `nvim_buf_set_name`) are handled separately and directly —
  Neovim hands over the old and new name with zero ambiguity, so this
  never goes through the hash-guessing path at all.
- A deletion is *discovered* on the next related write, not witnessed
  live. If you want a plugin that timestamps the exact moment of
  deletion, this isn't it — that requires a filesystem watcher, which
  was a deliberate scope cut for v1.

## Storage

```
<project-root>/.nvim-timeline/
  index.json        -- current_path -> timeline_id, plus per-timeline metadata
  objects/<xx>/<hash>  -- content-addressed blobs, deduplicated automatically
  log/<timeline_id>.jsonl  -- append-only commit records
```

One store per project (found by walking up for `.git`, falling back to
the file's own directory). Add `.nvim-timeline/` to your project's
`.gitignore`.

## Install (lazy.nvim)

```lua
{
  "dominionthedev/nvim-timeline",
  dependencies = { "MunifTanjim/nui.nvim" },
  config = function()
    require("nvim-timeline").setup({})
  end,
}
```

The picker (`:TimelineView`) is built directly on nui.nvim's `Menu` and
`Layout` -- not wrapped around telescope or snacks.nvim -- so it's the
one real dependency.

## Usage

- Just edit and save files normally — commits happen on their own.
- `:TimelineLog` — print the current file's commit history.
- `:TimelineBranches` — list branches for the current file, `*` marks
  the current one.
- `:TimelineBranch {name}` — create a branch at the current tip and
  switch to it.
- `:TimelineCheckout {branch-name|commit-ref}` — load that branch's or
  commit's content into the buffer. Accepts a branch name, a seq number
  (e.g. `7`), or a hash prefix. **This never writes to disk by itself.**
  Checking out a branch is a real, persisted switch; checking out an
  older commit that isn't any branch's tip puts the buffer in a
  transient "detached" state — if you save from there, you're prompted
  to name a new branch before anything is committed. Nothing is
  recorded until you choose to save.
- `:TimelineView` — the picker. Left pane lists commits for the current
  branch (newest first), right pane shows a live diff against the
  parent as you move. Keys: `j`/`k` to move, `<CR>` to check out the
  highlighted commit (same detached-state rules as `:TimelineCheckout`
  above), `b` to branch off the highlighted commit (works on any
  commit, not just the tip), `<Tab>` to cycle branches, `q`/`<Esc>` to
  close.

## What's deliberately not here yet

- Branch merging (not planned — this is single-writer history; a
  branch is just a second named tip, not a mergeable line)
- A filesystem watcher for live-witnessed deletions (explicitly out of
  scope — see "How it works" above)
- Fuzzy filtering inside the picker (it's a plain list -- fine at the
  scale of one file's history, revisit if that stops being true)

## Testing

```sh
git clone --depth 1 https://github.com/MunifTanjim/nui.nvim.git .deps/nui.nvim  # once, for the view tests
for f in tests/smoke_*.lua; do nvim --headless -u NONE -c "luafile $f"; done
```

Each test asserts real behavior — including a regression test for a
genuine `:saveas` quirk (it creates a shadow buffer for the old
filename, which fires a second rename event that looks like a
reverse-rename if handled naively) found while building this.
