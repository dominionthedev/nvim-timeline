vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local prompted = false
vim.ui.select = function(_, opts, on_choice)
  prompted = true
  h.assert_true(opts.prompt:match("a%.txt") ~= nil, "prompt mentions the ambiguous file")
  on_choice("Link")
end

local tl = require("timeline")
tl.setup({})

local dir = "/tmp/timeline-test-candidate"
h.fresh_project(dir)
vim.fn.mkdir(dir .. "/sub", "p")

h.write_file(dir .. "/a.txt", "version one")
os.remove(dir .. "/a.txt")
h.write_file(dir .. "/sub/a.txt", "version one edited") -- same basename, different hash

h.assert_true(prompted, "same-basename-different-hash triggers a link prompt instead of auto-linking")

local idx = h.read_json(dir .. "/.nvim-timeline/index.json")
local ids = {}
for id in pairs(idx.timelines) do
  table.insert(ids, id)
end

h.assert_eq(#ids, 1, "choosing Link merges into the existing timeline")
h.assert_eq(vim.tbl_count(idx.paths), 1, "old path is cleared once linked")

h.finish()
