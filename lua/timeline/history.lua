-- history.lua
--
-- Walks a timeline's commit graph. Pure and UI-free so it can be unit
-- tested directly, and so the eventual picker/view code only ever
-- consumes an already-correct ordered list instead of re-implementing
-- graph walking itself.

local M = {}

--- Build the linear chain for a branch, from its tip back to the root,
--- walking `parent` seq pointers. Newest first.
---
--- Keyed by seq, not hash, deliberately: a relink commit has the same
--- hash as its own parent (that's what made it match), so hash-based
--- walking can't tell "found the parent" from "found myself" and would
--- truncate history right there. seq is strictly decreasing walking
--- backward, so it can't loop and can't collide.
---@param commits Commit[] every commit in the timeline (all branches)
---@param tip_seq integer|nil
---@return Commit[] chain newest-first; empty if tip_seq is nil
function M.chain(commits, tip_seq)
  if not tip_seq then
    return {}
  end

  local by_seq = {}
  for _, c in ipairs(commits) do
    by_seq[c.seq] = c
  end

  local chain = {}
  local seq = tip_seq
  while seq and by_seq[seq] do
    table.insert(chain, by_seq[seq])
    seq = by_seq[seq].parent
  end
  return chain
end

return M
