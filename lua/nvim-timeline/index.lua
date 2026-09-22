-- index.lua
--
-- The identity index: current_path -> timeline_id, plus per-timeline
-- metadata (last known path, last content hash, creation time). This is
-- the single source of truth that lets a recreated file be recognized as
-- a continuation of a deleted one, instead of a brand new history.
--
-- Deliberately dumb: this module only reads/writes state. Correlation
-- *decisions* (exact-hash link vs. same-basename prompt vs. new timeline)
-- live in correlate.lua, which is the only thing that calls into here
-- with actual judgment calls. Keeping this file pure state I/O makes it
-- trivial to unit test without touching vim.ui or autocmds at all.

local M = {}

local INDEX_FILE = "index.json"
M.DEFAULT_BRANCH = "main"

---@class BranchTip
---@field hash string  content hash at this branch's tip (for store lookups)
---@field seq integer  the tip commit's sequence number (for parent-linking)

---@class TimelineEntry
---@field last_known_path string
---@field last_hash string
---@field created_at integer  -- os.time() at first write
---@field head_branch string  -- which branch new writes append to
---@field branches table<string, BranchTip>  -- branch_name -> tip
---@field commit_count integer  -- total commits ever appended; source of the next seq

--- Load the index from disk. Returns an empty index if none exists yet —
--- this is the expected state for a freshly-initialized store, not an
--- error.
---@param root string store root, e.g. ".nvim-timeline"
---@return table<string, string> paths    current_path -> timeline_id
---@return table<string, TimelineEntry> timelines  timeline_id -> entry
function M.load(root)
  local path = root .. "/" .. INDEX_FILE
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return {}, {}
  end

  local fd = assert(vim.loop.fs_open(path, "r", 438))
  local raw = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    -- Corrupt index is a hard stop, not a silent reset: silently
    -- discarding it would orphan every tracked timeline's path mapping.
    error("nvim-timeline: index.json is corrupt at " .. path)
  end

  return decoded.paths or {}, decoded.timelines or {}
end

--- Persist the index to disk. Whole-file rewrite — the index is small
--- (one entry per tracked file, not per commit), so this is cheap enough
--- to do on every write without a diffing/patching layer.
---@param root string
---@param paths table<string, string>
---@param timelines table<string, TimelineEntry>
function M.save(root, paths, timelines)
  vim.fn.mkdir(root, "p")
  local path = root .. "/" .. INDEX_FILE
  local encoded = vim.json.encode({ paths = paths, timelines = timelines })

  local fd = assert(vim.loop.fs_open(path, "w", 420))
  vim.loop.fs_write(fd, encoded, 0)
  vim.loop.fs_close(fd)
end

--- Look up the timeline_id currently mapped to a path, if any.
---@param paths table<string, string>
---@param file_path string
---@return string|nil
function M.lookup(paths, file_path)
  return paths[file_path]
end

--- Find every timeline whose last_known_path no longer exists on disk.
--- Cheap by construction: this is only ever called on the rare path
--- (a write to a path not already in the index), never on every save,
--- so the fs_stat cost per candidate is fine.
---@param timelines table<string, TimelineEntry>
---@return table<string, TimelineEntry> orphans keyed by timeline_id
function M.find_orphans(timelines)
  local orphans = {}
  for id, entry in pairs(timelines) do
    if vim.loop.fs_stat(entry.last_known_path) == nil then
      orphans[id] = entry
    end
  end
  return orphans
end

--- Register a brand new timeline for a path, with no prior history.
--- Branch state starts empty -- the first commit (appended by the
--- caller right after this) is what actually sets branches[head_branch].
---@param paths table<string, string>
---@param timelines table<string, TimelineEntry>
---@param file_path string
---@param hash string initial content hash
---@return string timeline_id the newly minted id
function M.create(paths, timelines, file_path, hash)
  local id = vim.fn.sha256(file_path .. tostring(os.time()) .. tostring(math.random()))
  paths[file_path] = id
  timelines[id] = {
    last_known_path = file_path,
    last_hash = hash,
    created_at = os.time(),
    head_branch = M.DEFAULT_BRANCH,
    branches = {},
    commit_count = 0,
  }
  return id
end

--- The branch new writes should append to.
---@param entry TimelineEntry
---@return string
function M.current_branch(entry)
  return entry.head_branch or M.DEFAULT_BRANCH
end

--- The tip of a branch, or nil if that branch has no commits yet (only
--- possible for head_branch on a freshly created timeline).
---@param entry TimelineEntry
---@param branch string
---@return BranchTip|nil
function M.branch_head(entry, branch)
  return entry.branches[branch]
end

--- Record a new tip for a branch after a commit lands.
---@param entry TimelineEntry
---@param branch string
---@param hash string
---@param seq integer
function M.set_branch_head(entry, branch, hash, seq)
  entry.branches[branch] = { hash = hash, seq = seq }
end

--- Create a new branch pointing at a given commit and make it current.
--- Used both for explicit :TimelineBranch and for the prompt that fires
--- when committing from a detached (non-tip) checkout.
---@param entry TimelineEntry
---@param name string
---@param from_hash string
---@param from_seq integer
function M.create_branch(entry, name, from_hash, from_seq)
  entry.branches[name] = { hash = from_hash, seq = from_seq }
  entry.head_branch = name
end

--- Switch which branch new writes append to, without creating a commit.
--- Only valid for a branch that already has a tip.
---@param entry TimelineEntry
---@param name string
function M.switch_branch(entry, name)
  entry.head_branch = name
end

--- Reserve the next commit sequence number for a timeline. Sequence
--- numbers are the commit graph's real identity -- unlike content hash,
--- they can never collide or repeat, which matters because a relink
--- commit legitimately has the *same hash as its own parent* (that's
--- what made it an exact match). Walking parent pointers by hash in that
--- case can't distinguish "found the parent" from "found myself"; walking
--- by a strictly-decreasing seq always can.
---@param entry TimelineEntry
---@return integer seq
function M.next_seq(entry)
  entry.commit_count = (entry.commit_count or 0) + 1
  return entry.commit_count
end

--- Point an existing timeline at a new path (rename, or a recreation
--- linked via hash-match/prompt). Updates both maps in place.
---@param paths table<string, string>
---@param timelines table<string, TimelineEntry>
---@param id string
---@param new_path string
---@param hash string
function M.relink(paths, timelines, id, new_path, hash)
  local entry = timelines[id]
  if entry.last_known_path ~= new_path then
    paths[entry.last_known_path] = nil
  end
  paths[new_path] = id
  entry.last_known_path = new_path
  entry.last_hash = hash
end

return M
