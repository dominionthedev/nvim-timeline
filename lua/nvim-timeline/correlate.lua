-- correlate.lua
--
-- Decision logic for the one case that actually requires judgment: a
-- BufWritePost on a path that isn't in the index yet. Three outcomes:
--
--   1. exact_match   -- an orphaned timeline's last_hash equals this
--                        content's hash. Auto-link, no ambiguity: this
--                        content genuinely continues that timeline.
--   2. candidate      -- no hash match, but an orphan shares this path's
--                        basename. Could be a continuation with edits,
--                        could be an unrelated new file. NOT auto-linked
--                        -- surfaced to the caller to prompt the user.
--                        Guessing here risks a silent wrong merge, which
--                        is worse than just starting fresh.
--   3. new            -- no hash match, no basename candidate. Genuinely
--                        new timeline.
--
-- This module never touches vim.ui or issues prompts itself -- it only
-- returns a decision. Keeping the judgment call pure means the actual
-- prompt UI (in init.lua) can change without this logic needing retesting,
-- and this logic can be unit tested without stubbing vim.ui.select.

local index = require("nvim-timeline.index")

local M = {}

---@class CorrelationDecision
---@field kind "exact_match"|"candidate"|"new"
---@field timeline_id string|nil  -- set for exact_match and candidate

--- Decide what a write to an unindexed path means.
---@param timelines table<string, TimelineEntry>
---@param file_path string
---@param hash string content hash of what was just written
---@return CorrelationDecision
function M.decide(timelines, file_path, hash)
  local orphans = index.find_orphans(timelines)

  for id, entry in pairs(orphans) do
    if entry.last_hash == hash then
      return { kind = "exact_match", timeline_id = id }
    end
  end

  local basename = vim.fn.fnamemodify(file_path, ":t")
  for id, entry in pairs(orphans) do
    if vim.fn.fnamemodify(entry.last_known_path, ":t") == basename then
      return { kind = "candidate", timeline_id = id }
    end
  end

  return { kind = "new" }
end

return M
