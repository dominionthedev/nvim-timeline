vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("nvim-timeline")
tl.setup({})

local dir = "/tmp/nvim-timeline-test-rename"
h.fresh_project(dir)

h.write_file(dir .. "/orig.txt", "line one")
vim.cmd("saveas " .. dir .. "/renamed.txt")

local idx = h.read_json(dir .. "/.nvim-timeline/index.json")

local ids = {}
for id in pairs(idx.timelines) do
  table.insert(ids, id)
end

-- Regression: :saveas creates a shadow buffer for the old name, which
-- used to fire a spurious second BufFilePost that looked like a
-- reverse-rename and split this into two timelines instead of one.
h.assert_eq(#ids, 1, ":saveas relinks the existing timeline instead of creating a second one")
h.assert_eq(vim.tbl_count(idx.paths), 1, "only the new path remains mapped after rename")
h.assert_true(idx.paths[dir .. "/renamed.txt"] ~= nil, "new path is mapped to the timeline")
h.assert_true(idx.paths[dir .. "/orig.txt"] == nil, "old path is no longer mapped after rename")

h.finish()
