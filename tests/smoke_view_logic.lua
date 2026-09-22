vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local view = require("nvim-timeline.view")

local entry = {
  head_branch = "main",
  branches = {
    main = { hash = "H3", seq = 3 },
    experiment = { hash = "H2b", seq = 4 },
  },
}

local commits = {
  { seq = 1, hash = "H1", parent = nil, path = "/f.txt", branch = "main", timestamp = 1000 },
  { seq = 2, hash = "H2", parent = 1, path = "/f.txt", branch = "main", timestamp = 1001 },
  { seq = 3, hash = "H3", parent = 2, path = "/f.txt", branch = "main", timestamp = 1002 },
  { seq = 4, hash = "H2b", parent = 1, path = "/f.txt", branch = "experiment", timestamp = 1003 },
}

local main_chain = view._chain_for(entry, commits, "main")
h.assert_eq(#main_chain, 3, "main's chain walks its own 3 commits")
h.assert_eq(main_chain[1].seq, 3, "main's chain is newest-first")

local exp_chain = view._chain_for(entry, commits, "experiment")
h.assert_eq(#exp_chain, 2, "experiment's chain includes the shared root commit plus its own")
h.assert_eq(exp_chain[1].seq, 4, "experiment's tip is its own commit, not main's")
h.assert_eq(exp_chain[2].seq, 1, "experiment's chain reaches back to the shared root")

local items = view._build_items(main_chain, entry)
h.assert_eq(#items, 3, "one menu item per commit in the chain")
h.assert_eq(items[1].commit.seq, 3, "items follow the chain's order")
h.assert_eq(items[1].parent_hash, "H2", "each item carries its parent's hash for diffing")
h.assert_true(items[1].text:find("%[main%]") ~= nil, "the commit at main's tip is tagged with the branch name")
h.assert_eq(items[3].parent_hash, nil, "the root commit has no parent hash to diff against")

h.finish()
