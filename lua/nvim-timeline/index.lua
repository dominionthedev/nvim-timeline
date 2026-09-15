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

---@class TimelineEntry
---@field last_known_path string
---@field last_hash string
---@field created_at integer  -- os.time() at first write

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
  }
  return id
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
