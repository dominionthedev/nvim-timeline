-- log.lua
--
-- Append-only commit history, one file per timeline_id, one JSON line per
-- commit. One commit per BufWritePost (or per relink event) -- undo
-- already owns the finer-grained between-saves history, so this log
-- deliberately doesn't try to compete with it.
--
-- Layout: log/<timeline_id>.jsonl

local M = {}

---@class Commit
---@field seq integer       unique, strictly-increasing commit identity --
---   see index.next_seq for why this exists separately from hash: content
---   hash can legitimately repeat (a relink has the same hash as its own
---   parent), so it can't double as graph identity.
---@field hash string       content hash at this commit (see store.lua)
---@field path string       path the file had at commit time
---@field branch string     branch name this commit belongs to
---@field parent integer|nil seq of the previous commit on this branch, nil for the first
---@field timestamp integer os.time() at commit

local function log_path(root, id)
  return root .. "/log/" .. id .. ".jsonl"
end

--- Append a new commit to a timeline's log.
---@param root string
---@param id string timeline_id
---@param commit Commit
function M.append(root, id, commit)
  vim.fn.mkdir(root .. "/log", "p")
  local path = log_path(root, id)

  local line = vim.json.encode(commit) .. "\n"

  local fd = vim.loop.fs_open(path, "a", 420)
  if not fd then
    error("timeline.nvim: could not open log for append: " .. path)
  end
  vim.loop.fs_write(fd, line, -1)
  vim.loop.fs_close(fd)
end

--- Read every commit for a timeline, in append order.
---@param root string
---@param id string
---@return Commit[]
function M.read(root, id)
  local path = log_path(root, id)
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return {}
  end

  local fd = assert(vim.loop.fs_open(path, "r", 438))
  local raw = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  local commits = {}
  for line in raw:gmatch("[^\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok then
      table.insert(commits, decoded)
    end
  end
  return commits
end

--- Find a commit by seq (bare integer, e.g. "7"), full hash, or an
--- unambiguous hash prefix.
---@param root string
---@param id string
---@param ref string
---@return Commit|nil commit
---@return string|nil error set if a hash prefix matches more than one distinct commit
function M.find(root, id, ref)
  local commits = M.read(root, id)

  if ref:match("^%d+$") then
    local seq = tonumber(ref)
    for _, commit in ipairs(commits) do
      if commit.seq == seq then
        return commit, nil
      end
    end
    return nil, nil
  end

  local matches = {}
  for _, commit in ipairs(commits) do
    if commit.hash == ref or commit.hash:sub(1, #ref) == ref then
      table.insert(matches, commit)
    end
  end
  if #matches == 0 then
    return nil, nil
  end
  if #matches > 1 then
    -- A hash prefix can match multiple distinct commit *events* (a
    -- relink shares its parent's hash, a revert can match an older
    -- state) -- only truly ambiguous if they aren't the same seq.
    table.sort(matches, function(a, b)
      return a.seq < b.seq
    end)
    return nil,
      ("ambiguous ref %q matches %d commits (seq %d..%d), use a longer hash or the seq number"):format(
        ref,
        #matches,
        matches[1].seq,
        matches[#matches].seq
      )
  end
  return matches[1], nil
end

return M
