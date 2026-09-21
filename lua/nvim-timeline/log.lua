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
---@field hash string       content hash at this commit (see store.lua)
---@field path string       path the file had at commit time
---@field branch string     branch name this commit belongs to
---@field parent string|nil hash of the previous commit on this branch, nil for the first
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
    error("nvim-timeline: could not open log for append: " .. path)
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

--- Convenience: the most recent commit on a timeline, or nil if empty.
---@param root string
---@param id string
---@return Commit|nil
function M.head(root, id)
  local commits = M.read(root, id)
  return commits[#commits]
end

--- Find a commit by full hash or unambiguous prefix.
---@param root string
---@param id string
---@param ref string full hash or a prefix of one
---@return Commit|nil commit
---@return string|nil error set if the prefix matches more than one commit
function M.find(root, id, ref)
  local matches = {}
  for _, commit in ipairs(M.read(root, id)) do
    if commit.hash == ref or commit.hash:sub(1, #ref) == ref then
      table.insert(matches, commit)
    end
  end
  if #matches == 0 then
    return nil, nil
  end
  if #matches > 1 then
    -- Multiple distinct commits can share a prefix; only ambiguous if
    -- they're not all literally the same commit content re-hashed.
    local first_hash = matches[1].hash
    for _, m in ipairs(matches) do
      if m.hash ~= first_hash then
        return nil, ("ambiguous ref %q, be more specific"):format(ref)
      end
    end
  end
  return matches[1], nil
end

return M
