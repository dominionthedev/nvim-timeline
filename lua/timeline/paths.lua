-- paths.lua
--
-- Where a project's store lives on disk. Stores are NOT scattered one
-- per project directory (that was v1's approach) -- they all live under
-- a single Neovim-managed location, one subdirectory per project:
--
--   <stdpath("state")>/timeline/
--     meta.json              real_project_root -> dirname
--     <dirname>/
--       index.json
--       objects/<xx>/<hash>
--       log/<timeline_id>.jsonl
--
-- meta.json exists because two different projects can share a basename
-- ("~/work/api" and "~/side-projects/api" are both just "api") -- the
-- dirname on disk gets disambiguated when that happens, but meta.json
-- always knows which real path a given dirname actually belongs to, so
-- resolution is stable across sessions without ever renaming a dirname
-- once it's chosen.

local M = {}

--- The one place every store lives, regardless of project.
---@return string
function M.base_dir()
  return vim.fn.stdpath("state") .. "/timeline"
end

local function meta_path()
  return M.base_dir() .. "/meta.json"
end

local function load_meta()
  local path = meta_path()
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return {}
  end
  local fd = assert(vim.loop.fs_open(path, "r", 438))
  local raw = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    error("timeline.nvim: meta.json is corrupt at " .. path)
  end
  return decoded
end

local function save_meta(meta)
  vim.fn.mkdir(M.base_dir(), "p")
  local fd = assert(vim.loop.fs_open(meta_path(), "w", 420))
  vim.loop.fs_write(fd, vim.json.encode(meta), 0)
  vim.loop.fs_close(fd)
end

--- Find the project root for a file: walk up looking for `.git`, falling
--- back to the file's own directory. Resolved to its real path
--- (symlinks followed) before use, so the same physical project opened
--- two different ways (direct vs. through a symlink) always maps to one
--- store, not two.
---@param file_path string absolute path to the file being tracked
---@return string real_project_root
function M.project_root(file_path)
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local git_dir = vim.fs.find(".git", { path = dir, upward = true })[1]
  local root = git_dir and vim.fn.fnamemodify(git_dir, ":h") or dir
  return vim.loop.fs_realpath(root) or root
end

--- Resolve (creating if needed) the store directory for a project root,
--- disambiguating against meta.json if another, different project
--- already claimed the same basename.
---@param real_project_root string  must already be resolved via project_root()
---@return string store_dir  absolute path, e.g. ".../timeline/myproject"
function M.store_dir(real_project_root)
  local meta = load_meta()

  -- Already registered -- use its existing dirname even if a same-named
  -- newcomer shows up later; the first claimant keeps the plain name.
  if meta[real_project_root] then
    return M.base_dir() .. "/" .. meta[real_project_root]
  end

  local basename = vim.fn.fnamemodify(real_project_root, ":t")
  local dirname = basename

  -- Does that plain basename already belong to a *different* real path?
  local taken = false
  for registered_root, registered_dirname in pairs(meta) do
    if registered_dirname == basename and registered_root ~= real_project_root then
      taken = true
      break
    end
  end

  if taken then
    -- Short hash of the real path keeps the disambiguated name stable
    -- and deterministic across sessions, without needing meta.json to
    -- already have this project in it.
    dirname = basename .. "-" .. vim.fn.sha256(real_project_root):sub(1, 8)
  end

  meta[real_project_root] = dirname
  save_meta(meta)

  return M.base_dir() .. "/" .. dirname
end

return M
