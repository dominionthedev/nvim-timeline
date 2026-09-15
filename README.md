# nvim-timeline

Git-like history for individual files in Neovim — the part vim's
`undofile` can't do: a file's history survives being deleted and
recreated, because identity is tracked independently of path.

## Status: v1 core, no UI yet

This is the data layer, proven against real edit sequences (see
`tests/`), plus one deliberately bare command (`:TimelineLog`) to
inspect it. There is no picker, no diff view, no branch-switching
command yet — those are next, once the log format has been lived with
for a while. See `tests/` for exactly what's covered.

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
  config = function()
    require("nvim-timeline").setup({})
  end,
}
```

## Usage

- Just edit and save files normally.
- `:TimelineLog` — print the current file's commit history.

## What's deliberately not here yet

- Branch creation/switching (the log schema already has a `branch`
  field; only `"main"` is ever written to right now)
- Any picker/viewer beyond `:TimelineLog`
- Checkout / time-travel to a prior commit
- A filesystem watcher for live-witnessed deletions (explicitly out of
  scope — see "How it works" above)

## Testing

```sh
for f in tests/smoke_*.lua; do nvim --headless -u NONE -c "luafile $f"; done
```

Each test asserts real behavior — including a regression test for a
genuine `:saveas` quirk (it creates a shadow buffer for the old
filename, which fires a second rename event that looks like a
reverse-rename if handled naively) found while building this.
