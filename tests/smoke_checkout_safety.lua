vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("timeline")
tl.setup({})
local index = require("timeline.index")

local dir = "/tmp/timeline-test-checkout-safety"
h.fresh_project(dir)
local store = h.store_dir(dir)

h.write_file(dir .. "/f.txt", "version one")
h.write_file(dir .. "/f.txt", "version two")

local idx = h.read_json(store .. "/index.json")
local id = idx.paths[dir .. "/f.txt"]

-- Make the buffer dirty without saving.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "version two, unsaved edit" })
h.assert_true(vim.bo[0].modified, "buffer is now dirty")

-- Refused without force -- and nothing should be lost or changed on disk.
local ok = tl.checkout("1", false)
h.assert_true(not ok, "checkout refuses when the buffer has unsaved changes and isn't forced")
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
  "version two, unsaved edit",
  "the unsaved edit is untouched by a refused checkout"
)

idx = h.read_json(store .. "/index.json")
h.assert_true(
  idx.timelines[id].stashes == nil,
  "no stash is created by a refused (non-forced) checkout"
)

-- Forced: the dirty content is stashed, THEN the checkout proceeds.
ok = tl.checkout("1", true)
h.assert_true(ok, "forced checkout proceeds despite unsaved changes")
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
  "version one",
  "the buffer now shows the checked-out commit's content"
)
h.assert_true(not vim.bo[0].modified, "the buffer is no longer marked modified after checkout")

idx = h.read_json(store .. "/index.json")
local stashes = idx.timelines[id].stashes
h.assert_eq(#stashes, 1, "the dirty content was stashed exactly once")

-- The stash is actually recoverable, not just recorded.
local stash_hash = stashes[1].hash
local blob_path = store .. "/objects/" .. stash_hash:sub(1, 2) .. "/" .. stash_hash
local f = assert(io.open(blob_path, "r"))
h.assert_eq(
  f:read("*a"),
  "version two, unsaved edit",
  "the stashed content is actually retrievable from the store"
)
f:close()

h.finish()
