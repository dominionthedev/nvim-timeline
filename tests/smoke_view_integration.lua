vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("nvim-timeline")
tl.setup({})
local view = require("nvim-timeline.view")

local dir = "/tmp/nvim-timeline-test-view"
h.fresh_project(dir)

h.write_file(dir .. "/f.txt", "version one")
h.write_file(dir .. "/f.txt", "version two")

local file_bufnr = vim.api.nvim_get_current_buf()

view.open()
vim.wait(50)

local state = view._state()
h.assert_true(state ~= nil, "open() mounts a layout")

-- Preview should start on the tip (version two, diffed against version one).
local preview_lines = table.concat(vim.api.nvim_buf_get_lines(state.preview.bufnr, 0, -1, false), "\n")
h.assert_true(preview_lines:find("version two") ~= nil, "preview shows the tip commit's diff on open")

-- Move focus into the list and press j to select the older (root) commit.
vim.api.nvim_set_current_win(state.list.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("j", true, false, true), "x", false)
vim.wait(50)

preview_lines = table.concat(vim.api.nvim_buf_get_lines(state.preview.bufnr, 0, -1, false), "\n")
h.assert_true(preview_lines:find("version one") ~= nil, "moving selection updates the preview to the older commit")

-- <CR> checks it out. The root commit isn't any branch's tip, so this
-- should land the file buffer in the detached state and close the view.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
vim.wait(50)

h.assert_true(view._state() == nil, "submitting a selection closes the view")
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(file_bufnr, 0, -1, false), "\n"),
  "version one",
  "checking out the root commit loads its content into the original file buffer"
)

h.finish()
