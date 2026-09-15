vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("nvim-timeline")
tl.setup({})

local dir = "/tmp/nvim-timeline-test-identity"
h.fresh_project(dir)

h.write_file(dir .. "/a.txt", "hello world")
h.write_file(dir .. "/a.txt", "hello world") -- no-op save, must not add a commit
h.write_file(dir .. "/a.txt", "hello world\nsecond line")

os.remove(dir .. "/a.txt")
h.write_file(dir .. "/a_recreated.txt", "hello world\nsecond line") -- exact hash match

local idx = h.read_json(dir .. "/.nvim-timeline/index.json")

local ids = {}
for id in pairs(idx.timelines) do
  table.insert(ids, id)
end

h.assert_eq(#ids, 1, "delete+recreate with identical content links to one timeline, not two")
h.assert_eq(vim.tbl_count(idx.paths), 1, "old path is removed from the index after relink")
h.assert_true(idx.paths[dir .. "/a_recreated.txt"] ~= nil, "new path is mapped in the index")
h.assert_true(idx.paths[dir .. "/a.txt"] == nil, "old deleted path is no longer mapped")

local log_path = dir .. "/.nvim-timeline/log/" .. ids[1] .. ".jsonl"
local f = assert(io.open(log_path, "r"))
local n = 0
for _ in f:lines() do
  n = n + 1
end
f:close()
h.assert_eq(n, 3, "3 real commits: create, edit, relink -- the no-op save added nothing")

local all_entries = vim.fn.globpath(dir .. "/.nvim-timeline/objects", "**/*", false, true)
local objects = vim.tbl_filter(function(p)
  return vim.fn.isdirectory(p) == 0
end, all_entries)
h.assert_eq(#objects, 2, "identical content across the edit and the relink is stored once, not twice")

h.finish()
