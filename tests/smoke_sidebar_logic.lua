vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local sidebar = require("timeline.sidebar")

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

local tree = sidebar._build_tree_data(entry, commits)

h.assert_eq(#tree, 2, "one top-level node per branch")
h.assert_eq(tree[1].name, "experiment", "branches are sorted alphabetically")
h.assert_eq(tree[2].name, "main", "main sorts after experiment")
h.assert_true(tree[2].is_current, "main is flagged as the current branch")
h.assert_true(not tree[1].is_current, "experiment is not flagged as current")

h.assert_eq(#tree[1].children, 2, "experiment's chain: its own commit plus the shared root")
h.assert_eq(tree[1].children[1].commit.seq, 4, "experiment's own commit comes first (newest-first)")
h.assert_eq(tree[1].children[2].commit.seq, 1, "experiment's chain reaches the shared root commit")

h.assert_eq(#tree[2].children, 3, "main's chain: all 3 of its own commits")
h.assert_eq(tree[2].children[1].commit.seq, 3, "main's tip is newest-first too")

-- The shared root (seq 1) legitimately appears under BOTH branches, with
-- branch-scoped ids so the tree doesn't collide on it.
h.assert_eq(tree[1].children[2].id, "commit:experiment:1", "shared commit's id is scoped to the branch showing it")
h.assert_eq(tree[2].children[3].id, "commit:main:1", "...and scoped differently under the other branch")

-- Empty entry (freshly created timeline, no branches yet) doesn't error.
h.assert_eq(#sidebar._build_tree_data({ head_branch = "main", branches = {} }, {}), 0, "no branches yields an empty tree, not an error")

h.finish()
