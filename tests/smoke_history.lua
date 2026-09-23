vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local history = require("timeline.history")

-- Mirrors the real scenario from smoke_identity.lua: create, edit, then
-- a relink whose hash is *identical to its own parent's* (that's what
-- makes it an exact-hash-match in the first place). A hash-keyed walk
-- can't tell "found the parent" from "found myself" here and would
-- truncate after 2 commits instead of walking all 3. A seq-keyed walk
-- can't be fooled, because seq strictly decreases and never repeats.
local commits = {
  { seq = 1, hash = "HASH_A", parent = nil, path = "/a.txt" },
  { seq = 2, hash = "HASH_B", parent = 1, path = "/a.txt" },
  { seq = 3, hash = "HASH_B", parent = 2, path = "/a_recreated.txt" }, -- relink, same hash as parent
}

local chain = history.chain(commits, 3)

h.assert_eq(#chain, 3, "all 3 commits are walked despite the relink sharing its parent's hash")
h.assert_eq(chain[1].seq, 3, "newest first: the relink commit")
h.assert_eq(chain[2].seq, 2, "then the edit")
h.assert_eq(chain[3].seq, 1, "then the original create")

-- A longer chain where the repeated-hash commit sits in the *middle*,
-- with real history continuing past it -- the case that would most
-- obviously break a naive hash-based walk (it would stop the moment it
-- first sees HASH_B, never reaching seq 4).
local longer = {
  { seq = 1, hash = "HASH_A", parent = nil },
  { seq = 2, hash = "HASH_B", parent = 1 },
  { seq = 3, hash = "HASH_B", parent = 2 }, -- relink, same hash as parent
  { seq = 4, hash = "HASH_C", parent = 3 }, -- real edit after the relink
}
local longer_chain = history.chain(longer, 4)
h.assert_eq(#longer_chain, 4, "walking continues past a repeated-hash commit to the true root")

-- No tip yet (freshly created timeline, first commit not appended).
h.assert_eq(#history.chain(commits, nil), 0, "nil tip yields an empty chain, not an error")

h.finish()
