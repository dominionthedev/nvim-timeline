-- diff.lua
--
-- Wraps Neovim's built-in vim.diff (libxdiff under the hood) so the UI
-- module doesn't need to know how a diff gets computed, and so the
-- formatting logic can be tested without touching nui or any window.

local M = {}

--- Unified diff between two versions of a file's content. Handles the
--- root-commit case (no parent) by treating it as a diff against empty
--- content, so the whole file shows as additions -- consistent with how
--- `git show` renders a repo's first commit.
---@param old_content string|nil  nil for the root commit (no parent)
---@param new_content string
---@return string unified_diff
function M.unified(old_content, new_content)
  local result = vim.text.diff(old_content or "", new_content, {
    result_type = "unified",
    ctxlen = 3,
  })
  -- vim.diff returns "" when the inputs are identical -- surface that
  -- explicitly rather than showing a blank preview pane that looks broken.
  if result == "" then
    return "(no changes)"
  end
  return result
end

return M
