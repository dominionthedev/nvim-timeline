vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("timeline")
tl.setup({})

local dir = "/tmp/timeline-test-view-scheme"
h.fresh_project(dir)

h.write_file(dir .. "/f.txt", "version one")
h.write_file(dir .. "/f.txt", "version two")

local original_win = vim.api.nvim_get_current_win()
local win_count_before = #vim.api.nvim_list_wins()

tl.view("1")
vim.wait(30)

h.assert_eq(#vim.api.nvim_list_wins(), win_count_before + 1, "view() opens exactly one new split")
h.assert_true(vim.wo[original_win].diff, "the original window is put into diff mode")

local new_win = vim.api.nvim_get_current_win()
h.assert_true(new_win ~= original_win, "focus moves to the new viewer split")
h.assert_true(vim.wo[new_win].diff, "the viewer window is also in diff mode")

local viewer_buf = vim.api.nvim_get_current_buf()
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(viewer_buf, 0, -1, false), "\n"),
  "version one",
  "the viewer buffer shows the requested commit's content"
)
h.assert_true(not vim.bo[viewer_buf].modifiable, "the viewer buffer is read-only")
h.assert_true(
  vim.api.nvim_buf_get_name(viewer_buf):match("^timeline://") ~= nil,
  "the viewer buffer uses the timeline:// scheme"
)

-- Closing the viewer window should turn diff mode back off on the
-- original window instead of leaving it stuck in diff view.
vim.api.nvim_win_close(new_win, true)
vim.wait(30)
h.assert_true(not vim.wo[original_win].diff, "closing the viewer clears diff mode on the original window")

-- Original working buffer itself must be completely untouched by view()
-- -- this is the whole point of view being the safe, non-destructive
-- counterpart to checkout.
vim.api.nvim_set_current_win(original_win)
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
  "version two",
  "the working buffer still holds its own (current) content after viewing an old commit"
)

-- Stash recovery viewing: force a checkout to create a stash, then view it.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dirty edit to stash" })
tl.checkout("1", true)
tl.view_stash(1)
vim.wait(30)

local stash_buf = vim.api.nvim_get_current_buf()
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(stash_buf, 0, -1, false), "\n"),
  "dirty edit to stash",
  "view_stash shows the actual stashed content"
)

h.finish()
