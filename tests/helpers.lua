local M = {}

vim.opt.swapfile = false

-- Only the view tests actually need nui.nvim; everything else (identity,
-- rename, candidate, history, diff, branching) has zero UI dependency.
-- Adding it here if present is harmless and saves every UI test from
-- repeating the same rtp setup.
local nui_path = os.getenv("TIMELINE_NVIM_NUI_PATH") or (vim.fn.getcwd() .. "/.deps/nui.nvim")
if vim.loop.fs_stat(nui_path) then
  vim.opt.rtp:prepend(nui_path)
end

-- Isolate stdpath("state") for every test run so timeline.paths never
-- touches (or gets confused by) a real Neovim state directory.
local FAKE_STATE = "/tmp/timeline-tests-state"
vim.fn.stdpath = (function(original)
  return function(kind)
    if kind == "state" then
      return FAKE_STATE
    end
    return original(kind)
  end
end)(vim.fn.stdpath)
M.FAKE_STATE = FAKE_STATE

--- Where a project's store lives under the isolated fake state dir --
--- mirrors timeline.paths so tests don't hardcode the on-disk layout.
---@param project_dir string
---@return string
function M.store_dir(project_dir)
  local paths = require("timeline.paths")
  return paths.store_dir(paths.project_root(project_dir .. "/x"))
end

local failures = 0

function M.assert_eq(actual, expected, msg)
  if actual ~= expected then
    failures = failures + 1
    print(("FAIL: %s\n  expected: %s\n  actual:   %s"):format(msg or "", vim.inspect(expected), vim.inspect(actual)))
  else
    print(("PASS: %s"):format(msg or ""))
  end
end

function M.assert_true(cond, msg)
  M.assert_eq(cond and true or false, true, msg)
end

function M.write_file(path, content)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
  vim.api.nvim_set_current_buf(buf)
  vim.cmd("write")
end

function M.fresh_project(dir)
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "init", "-q", dir })
  -- The store now lives outside the project dir (under stdpath("state")),
  -- so deleting the project dir alone leaves a stale store behind from
  -- any previous run of this same test file -- wipe it too. The
  -- real-path -> dirname mapping in meta.json is fine to keep (it's
  -- meant to be stable); only the store's contents need a clean slate.
  local paths = require("timeline.paths")
  local ok, root = pcall(paths.project_root, dir .. "/x")
  if ok then
    vim.fn.delete(paths.store_dir(root), "rf")
  end
end

function M.read_json(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content)
end

function M.finish()
  if failures > 0 then
    print(("\n%d assertion(s) failed"):format(failures))
    vim.cmd("cquit! 1")
  else
    print("\nall assertions passed")
    vim.cmd("qa!")
  end
end

return M
