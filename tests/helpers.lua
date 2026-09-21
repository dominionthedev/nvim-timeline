local M = {}

vim.opt.swapfile = false

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
