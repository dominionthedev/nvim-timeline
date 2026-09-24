vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local paths = require("timeline.paths")

vim.fn.delete(h.FAKE_STATE, "rf")

vim.fn.mkdir("/tmp/timeline-test-proj-a", "p")
vim.fn.mkdir("/tmp/timeline-test-proj-b", "p")
-- Same basename, different real projects -- must not collide.
vim.fn.mkdir("/tmp/timeline-test-same-name/one/api", "p")
vim.fn.mkdir("/tmp/timeline-test-same-name/two/api", "p")

local root_a = paths.project_root("/tmp/timeline-test-proj-a/f.txt")
local root_b = paths.project_root("/tmp/timeline-test-proj-b/f.txt")
h.assert_true(root_a ~= root_b, "two unrelated projects resolve to different roots")

local dir_a1 = paths.store_dir(root_a)
local dir_a2 = paths.store_dir(root_a)
h.assert_eq(dir_a1, dir_a2, "resolving the same project root twice returns the same store dir")

local root_one = paths.project_root("/tmp/timeline-test-same-name/one/api/f.txt")
local root_two = paths.project_root("/tmp/timeline-test-same-name/two/api/f.txt")
local dir_one = paths.store_dir(root_one)
local dir_two = paths.store_dir(root_two)
h.assert_true(dir_one ~= dir_two, "same basename, different real projects get different store dirs")
h.assert_true(dir_one:find("api") ~= nil, "the first claimant of a basename keeps the plain name")
h.assert_true(
  dir_two:find("api%-") ~= nil,
  "the second claimant of the same basename gets disambiguated"
)

-- Symlink to project A should resolve to the SAME store as A itself.
vim.loop.fs_symlink("/tmp/timeline-test-proj-a", "/tmp/timeline-test-proj-a-link")
local root_via_link = paths.project_root("/tmp/timeline-test-proj-a-link/f.txt")
h.assert_eq(
  root_via_link,
  root_a,
  "a symlinked path to the same project resolves to the same real root"
)
h.assert_eq(
  paths.store_dir(root_via_link),
  dir_a1,
  "...and therefore the same store dir, not a second one"
)

-- meta.json actually persisted and is readable back.
local meta = h.read_json(h.FAKE_STATE .. "/timeline/meta.json")
h.assert_eq(
  meta[root_a],
  "timeline-test-proj-a",
  "meta.json records project A's real root -> dirname"
)
h.assert_eq(meta[root_one], "api", "meta.json gives the first api/ claimant the plain name")

h.finish()
