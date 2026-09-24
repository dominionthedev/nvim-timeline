vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local tl = require("timeline")
tl.setup({})
local sidebar = require("timeline.sidebar")

local function goto_line_containing(winid, pattern)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(pattern) then
      vim.api.nvim_win_set_cursor(winid, { i, 0 })
      return true
    end
  end
  return false
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(30)
end

-- ===== Phase 1: view (<CR> on a commit) =====
do
  local dir = "/tmp/timeline-test-sidebar-view"
  h.fresh_project(dir)
  h.write_file(dir .. "/f.txt", "v1")
  h.write_file(dir .. "/f.txt", "v2")
  local file_bufnr = vim.api.nvim_get_current_buf()
  local win_count_before = #vim.api.nvim_list_wins()

  sidebar.open()
  local state = sidebar._state()
  h.assert_true(state ~= nil, "open() mounts the sidebar")

  h.assert_true(goto_line_containing(state.split.winid, "#1"), "the root commit's line is found in the tree")
  vim.api.nvim_set_current_win(state.split.winid)
  feed("<CR>")

  h.assert_eq(#vim.api.nvim_list_wins(), win_count_before + 2, "sidebar + diff viewer are both open")
  h.assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
    "v1",
    "<CR> on a commit opens a read-only view of it, not a destructive checkout"
  )
  h.assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(file_bufnr, 0, -1, false), "\n"),
    "v2",
    "the working buffer is untouched by viewing"
  )

  sidebar.close()
  h.assert_true(sidebar._state() == nil, "close() clears sidebar state")
end

-- ===== Phase 2: branch off an arbitrary (non-tip) commit via 'b' =====
do
  local dir = "/tmp/timeline-test-sidebar-branch"
  h.fresh_project(dir)
  local store = h.store_dir(dir)
  h.write_file(dir .. "/f.txt", "v1")
  h.write_file(dir .. "/f.txt", "v2")

  local input_answer = "feature"
  vim.ui.input = function(_, on_confirm)
    on_confirm(input_answer)
  end

  sidebar.open()
  local state = sidebar._state()
  goto_line_containing(state.split.winid, "#1")
  vim.api.nvim_set_current_win(state.split.winid)
  feed("b")

  local idx = h.read_json(store .. "/index.json")
  local id = next(idx.timelines)
  h.assert_true(idx.timelines[id].branches["feature"] ~= nil, "'b' creates a new branch at the highlighted commit")
  h.assert_eq(idx.timelines[id].branches["feature"].seq, 1, "the new branch points at the commit that was highlighted, not the tip")

  h.assert_true(
    goto_line_containing(state.split.winid, "feature") ~= false,
    "the sidebar refreshes and now shows the new branch"
  )

  sidebar.close()
end

-- ===== Phase 3: checkout ('c') with the unsaved-changes guard =====
do
  local dir = "/tmp/timeline-test-sidebar-checkout"
  h.fresh_project(dir)
  h.write_file(dir .. "/f.txt", "v1")
  h.write_file(dir .. "/f.txt", "v2")
  local file_bufnr = vim.api.nvim_get_current_buf()

  -- Dirty the buffer so the guard actually has something to catch.
  vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, { "v2 unsaved edit" })

  local select_choice = "Stash unsaved changes and check out"
  vim.ui.select = function(_, _, on_choice)
    on_choice(select_choice)
  end

  sidebar.open()
  local state = sidebar._state()
  goto_line_containing(state.split.winid, "#1")
  vim.api.nvim_set_current_win(state.split.winid)
  feed("c")

  h.assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(file_bufnr, 0, -1, false), "\n"),
    "v1",
    "'c' checks out into the working buffer after confirming the stash-and-proceed prompt"
  )
  h.assert_true(not vim.bo[file_bufnr].modified, "the working buffer is clean after the confirmed checkout")

  sidebar.close()
end

-- ===== Phase 4: toggle =====
do
  local dir = "/tmp/timeline-test-sidebar-toggle"
  h.fresh_project(dir)
  h.write_file(dir .. "/f.txt", "v1")

  h.assert_true(sidebar._state() == nil, "sidebar starts closed")
  sidebar.toggle()
  h.assert_true(sidebar._state() ~= nil, "toggle opens it when closed")
  sidebar.toggle()
  h.assert_true(sidebar._state() == nil, "toggle closes it when open")
end

h.finish()
