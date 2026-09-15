-- store.lua
--
-- Content-addressed blob storage. Every distinct piece of file content is
-- written exactly once, keyed by its sha256 hash, mirroring the
-- content-addressed design already used in Odd. This is what makes the
-- write-time hash correlation in index.lua possible: comparing hashes is
-- cheap, and identical content across timelines/commits never duplicates
-- storage.
--
-- Layout on disk (relative to the store root, e.g. `.nvim-timeline/`):
--   objects/<hash[1:2]>/<hash>   -- raw content, one file per unique hash

local M = {}

--- Hash content using Neovim's built-in sha256 (no native/bundled dep).
---@param content string
---@return string hash hex-encoded sha256 digest
function M.hash(content)
  return vim.fn.sha256(content)
end

--- Compute the on-disk path for a given hash under a store root.
---@param root string absolute path to the store root (e.g. ".../.nvim-timeline")
---@param hash string
---@return string path
local function object_path(root, hash)
  local prefix = hash:sub(1, 2)
  return root .. "/objects/" .. prefix .. "/" .. hash
end

--- Return true if an object with this hash is already stored.
---@param root string
---@param hash string
---@return boolean
function M.has(root, hash)
  return vim.loop.fs_stat(object_path(root, hash)) ~= nil
end

--- Write content to the store under its hash, if not already present.
--- Idempotent and safe to call even when the object already exists.
---@param root string
---@param content string
---@return string hash the content's sha256 hash
function M.put(root, content)
  local hash = M.hash(content)
  local path = object_path(root, hash)

  if M.has(root, hash) then
    return hash
  end

  local dir = root .. "/objects/" .. hash:sub(1, 2)
  vim.fn.mkdir(dir, "p")

  local fd = assert(vim.loop.fs_open(path, "w", 420)) -- 0644
  vim.loop.fs_write(fd, content, 0)
  vim.loop.fs_close(fd)

  return hash
end

--- Read content back out of the store by hash.
---@param root string
---@param hash string
---@return string|nil content nil if the hash isn't in the store
function M.get(root, hash)
  local path = object_path(root, hash)
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return nil
  end

  local fd = assert(vim.loop.fs_open(path, "r", 438))
  local data = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  return data
end

return M
