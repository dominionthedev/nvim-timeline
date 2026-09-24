-- sidebar.lua
--
-- The persistent Timeline sidebar: a nui.Split (not a popup -- this
-- stays open and tracks whatever file you're editing, the way VSCode's
-- own Timeline panel does) holding a nui.Tree: branches as top-level
-- nodes, commits nested underneath, newest first.
--
-- Split into pure "what to show" functions (testable without mounting
-- anything) and the nui mounting/keymap glue, same pattern as the rest
-- of this plugin.

local Split = require("nui.split")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

local history = require("timeline.history")
local index = require("timeline.index")
local tl = require("timeline")

local M = {}

-- Only one sidebar at a time.
local state = nil

--- Build a plain-table branch/commit tree from a timeline's entry and
--- commit log -- no nui dependency, so this is directly unit testable.
--- A commit shared by more than one branch (an ancestor both descend
--- from) legitimately appears once under each such branch -- that's not
--- a bug, it's the same thing `git log <branch>` shows per branch.
---@param entry TimelineEntry
---@param commits Commit[]
---@return table[] branch_nodes
function M._build_tree_data(entry, commits)
  local branch_names = {}
  for name in pairs(entry.branches) do
    table.insert(branch_names, name)
  end
  table.sort(branch_names)

  local current_branch = index.current_branch(entry)
  local branch_nodes = {}

  for _, name in ipairs(branch_names) do
    local tip = entry.branches[name]
    local chain = history.chain(commits, tip.seq)

    local commit_nodes = {}
    for i, commit in ipairs(chain) do
      local parent = chain[i + 1]
      table.insert(commit_nodes, {
        id = ("commit:%s:%d"):format(name, commit.seq),
        kind = "commit",
        commit = commit,
        branch = name,
        parent_hash = parent and parent.hash or nil,
      })
    end

    table.insert(branch_nodes, {
      id = "branch:" .. name,
      kind = "branch",
      name = name,
      is_current = name == current_branch,
      children = commit_nodes,
    })
  end

  return branch_nodes
end

--- Convert the plain tree-data above into real NuiTree.Node objects.
--- Separate from _build_tree_data so the data shape stays testable
--- without nui.tree loaded at all.
local function to_nui_nodes(data_nodes)
  local out = {}
  for _, d in ipairs(data_nodes) do
    local children = d.children
    local copy = vim.tbl_extend("force", {}, d)
    copy.children = nil
    table.insert(out, NuiTree.Node(copy, children and to_nui_nodes(children) or nil))
  end
  return out
end

local function get_node_id(node)
  return node.id
end

local function prepare_node(node)
  local line = NuiLine()
  line:append(string.rep("  ", node:get_depth() - 1))

  if node.kind == "info" then
    line:append(node.text, "Comment")
    return line
  end

  if node.kind == "branch" then
    local marker = not node:has_children() and "  " or (node:is_expanded() and " " or " ")
    line:append(marker, "Special")
    line:append(node.name, node.is_current and "Title" or "Directory")
    if node.is_current then
      line:append("  (current)", "Comment")
    end
    return line
  end

  local c = node.commit
  line:append(("#%-4d "):format(c.seq), "Number")
  line:append(os.date("%Y-%m-%d %H:%M  ", c.timestamp), "Comment")
  line:append(c.hash:sub(1, 8), "Identifier")
  return line
end

--- Is this buffer something the sidebar should track as "the current
--- file"? Excludes the sidebar's own buffer, timeline:// viewer buffers,
--- and anything without a real file backing it.
local function is_real_file_buf(bufnr)
  if state and bufnr == state.split.bufnr then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^timeline://") then
    return false
  end
  return true
end

local function render()
  if not state then
    return
  end

  local bufnr = state.tracked_bufnr
  local file_path = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or nil
  local timeline = file_path and file_path ~= "" and tl.current_timeline(file_path) or nil

  if not timeline then
    state.tree:set_nodes({ NuiTree.Node({ id = "info", kind = "info", text = "(no history for this file yet)" }) })
    state.tree:render()
    return
  end

  local data = M._build_tree_data(timeline.entry, timeline.commits)
  state.tree:set_nodes(to_nui_nodes(data))

  for _, node in pairs(state.tree.nodes.by_id) do
    if node.kind == "branch" then
      if node.is_current then
        node:expand()
      else
        node:collapse()
      end
    end
  end

  state.tree:render()
end

--- Rebuild the sidebar for whatever file it's currently tracking.
--- Exposed for commands and keymap handlers to call after an action
--- (checkout, branch creation) that changes what should be displayed.
function M.refresh()
  render()
end

--- Run `fn` with focus moved to the tracked file's window (opening it
--- in a split first if it isn't currently visible anywhere), since
--- checkout/view resolve against the *current* buffer and keyboard
--- focus is in the sidebar's own window when a sidebar keymap fires.
local function with_tracked_focus(fn, restore_sidebar_focus)
  if not state then
    return
  end
  local bufnr = state.tracked_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("timeline.nvim: no tracked file buffer", vim.log.levels.WARN)
    return
  end

  local sidebar_winid = state.split.winid
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    vim.cmd("topleft vsplit")
    vim.api.nvim_set_current_buf(bufnr)
    winid = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(winid)
  end

  fn()

  if restore_sidebar_focus and vim.api.nvim_win_is_valid(sidebar_winid) then
    vim.api.nvim_set_current_win(sidebar_winid)
  end
end

--- <CR> on a commit: view it (safe, non-destructive). <CR> on a branch:
--- toggle expand/collapse, same as any tree.
local function on_confirm()
  local node = state.tree:get_node()
  if not node then
    return
  end

  if node.kind == "branch" then
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    state.tree:render()
    return
  end

  if node.kind ~= "commit" then
    return
  end

  with_tracked_focus(function()
    tl.view(tostring(node.commit.seq))
  end)
end

--- c: checkout the highlighted commit into the tracked buffer. This is
--- the destructive one -- loads content into your actual working
--- buffer, subject to the same unsaved-changes guard as
--- :TimelineCheckout. A refusal here surfaces the same stash-and-force
--- choice rather than just failing silently.
local function on_checkout()
  local node = state.tree:get_node()
  if not node or node.kind ~= "commit" then
    return
  end

  with_tracked_focus(function()
    local ref = tostring(node.commit.seq)
    local ok = tl.checkout(ref, false)
    if ok then
      M.refresh()
      return
    end

    -- tl.checkout already reported *why* it refused (unsaved changes,
    -- missing history, bad ref); only unsaved changes is recoverable
    -- here, so re-check that specific condition before offering to force.
    if not vim.bo[vim.api.nvim_get_current_buf()].modified then
      return
    end

    vim.ui.select({ "Stash unsaved changes and check out", "Cancel" }, {
      prompt = "timeline.nvim: buffer has unsaved changes",
    }, function(choice)
      if choice and choice:match("^Stash") then
        tl.checkout(ref, true)
        M.refresh()
      end
    end)
  end)
end

--- b: branch off the highlighted commit, whether or not it's a tip.
local function on_branch()
  local node = state.tree:get_node()
  if not node or node.kind ~= "commit" then
    return
  end

  vim.ui.input({ prompt = ("timeline.nvim: branch name at #%d: "):format(node.commit.seq) }, function(name)
    if not name or name == "" then
      return
    end
    with_tracked_focus(function()
      local ok, err = tl.branch_from_commit(node.commit, name)
      if not ok then
        vim.notify("timeline.nvim: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(("timeline.nvim: created branch %q at #%d"):format(name, node.commit.seq))
      M.refresh()
    end, true)
  end)
end

--- Close the sidebar.
function M.close()
  if not state then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.au_group)
  state.split:unmount()
  state = nil
end

--- Open the sidebar, tracking whatever buffer is current when it opens.
function M.open()
  if state then
    vim.api.nvim_set_current_win(state.split.winid)
    return
  end

  local tracked_bufnr = vim.api.nvim_get_current_buf()

  local split = Split({
    relative = "editor",
    position = "right",
    size = 42,
    buf_options = { modifiable = false, filetype = "timeline-sidebar", swapfile = false, buflisted = false },
    win_options = { number = false, relativenumber = false, wrap = false, signcolumn = "no", cursorline = true },
  })
  split:mount()

  local tree = NuiTree({
    bufnr = split.bufnr,
    nodes = {},
    prepare_node = prepare_node,
    get_node_id = get_node_id,
  })

  local group = vim.api.nvim_create_augroup("TimelineSidebar", { clear = true })

  state = { split = split, tree = tree, tracked_bufnr = tracked_bufnr, au_group = group }

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if is_real_file_buf(args.buf) then
        state.tracked_bufnr = args.buf
        render()
      end
    end,
  })

  split:map("n", "q", M.close, { noremap = true })
  split:map("n", "<Esc>", M.close, { noremap = true })
  split:map("n", "<CR>", on_confirm, { noremap = true })
  split:map("n", "c", on_checkout, { noremap = true })
  split:map("n", "b", on_branch, { noremap = true })

  render()
end

--- :TimelineView -- open if closed, close if open.
function M.toggle()
  if state then
    M.close()
  else
    M.open()
  end
end

-- Exposed for tests only.
M._state = function()
  return state
end

return M
