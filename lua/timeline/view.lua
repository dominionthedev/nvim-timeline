-- view.lua
--
-- The picker UI, built directly on nui.nvim (Menu + Layout), not a
-- wrapper around someone else's picker. Two panes: a Menu listing
-- commits for the current branch, and a plain Popup showing a live
-- diff-against-parent for whichever commit is highlighted.
--
-- Split deliberately into pure "what to show" functions (testable
-- without mounting anything) and the nui mounting/keymap glue (which
-- can only really be exercised by actually opening it). If the picker
-- ever looks wrong, the bug is almost certainly in the pure half, and
-- that half has tests.

local Menu = require("nui.menu")
local Popup = require("nui.popup")
local Layout = require("nui.layout")

local history = require("timeline.history")
local diff = require("timeline.diff")
local store = require("timeline.store")
local index = require("timeline.index")
local tl = require("timeline")

local M = {}

-- Only one view open at a time -- module-level state is fine and keeps
-- the keymap closures simple.
local state = nil

--- Which branch's chain to display, and the ordered (newest-first)
--- commit list for it. Pure: takes already-loaded data, no I/O.
---@param entry TimelineEntry
---@param commits Commit[]
---@param branch string
---@return Commit[] chain newest-first
function M._chain_for(entry, commits, branch)
  local tip = index.branch_head(entry, branch)
  return history.chain(commits, tip and tip.seq or nil)
end

--- Build the menu item list for a chain. Each item carries its commit
--- and its parent's hash (for diffing) as data, and a one-line label.
--- A commit that happens to be some *other* branch's tip gets that
--- branch's name shown inline, since it's easy to miss otherwise.
---@param chain Commit[] newest-first
---@param entry TimelineEntry
---@return table[] items  suitable for Menu.item(label, data)
function M._build_items(chain, entry)
  local tip_names_by_seq = {}
  for name, tip in pairs(entry.branches) do
    tip_names_by_seq[tip.seq] = tip_names_by_seq[tip.seq] or {}
    table.insert(tip_names_by_seq[tip.seq], name)
  end

  local items = {}
  for i, commit in ipairs(chain) do
    local parent = chain[i + 1]
    local tags = tip_names_by_seq[commit.seq]
    local tag_str = tags and (" [" .. table.concat(tags, ",") .. "]") or ""
    local label = ("#%-4d %s  %s%s"):format(
      commit.seq,
      os.date("%Y-%m-%d %H:%M", commit.timestamp),
      commit.hash:sub(1, 8),
      tag_str
    )
    table.insert(items, Menu.item(label, { commit = commit, parent_hash = parent and parent.hash or nil }))
  end
  return items
end

--- The diff text to show for a given item's data. Pure aside from the
--- store reads, which are unavoidable -- the content itself isn't kept
--- in memory anywhere.
---@param root string
---@param item_node table  a Menu.item node -- has .commit and .parent_hash directly (Menu.item's data table becomes the node itself via its metatable, not a nested .data field)
---@return string
function M._preview_text(root, item_node)
  local new_content = store.get(root, item_node.commit.hash) or "(content missing from store)"
  local old_content = item_node.parent_hash and store.get(root, item_node.parent_hash) or nil
  return diff.unified(old_content, new_content)
end

local function set_preview(text)
  local buf = state.preview.bufnr
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[buf].modifiable = false
end

local function close()
  if not state then
    return
  end
  state.layout:unmount()
  state = nil
end

--- Rebuild and mount the whole layout for a given branch. Called on
--- first open and again on <Tab> (branch cycling), since nui's Menu
--- doesn't support swapping its item list in place -- remounting a
--- small popup is cheap and simpler than fighting that.
---@param timeline table  from timeline.current_timeline()
---@param branch string
local function mount(timeline, branch)
  local chain = M._chain_for(timeline.entry, timeline.commits, branch)
  local items = M._build_items(chain, timeline.entry)

  if #items == 0 then
    vim.notify(("timeline.nvim: branch %q has no commits"):format(branch), vim.log.levels.WARN)
    return
  end

  local branch_names = {}
  for name in pairs(timeline.entry.branches) do
    table.insert(branch_names, name)
  end
  table.sort(branch_names)

  local list = Menu({
    border = {
      style = "rounded",
      text = { top = (" %s (%d/%d) "):format(branch, 1, #items), top_align = "left" },
    },
    position = 0,
    size = { width = 40, height = "60%" },
  }, {
    lines = items,
    max_width = 40,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close = { "q", "<Esc>", "<C-c>" },
      submit = { "<CR>" },
    },
    on_change = function(node)
      set_preview(M._preview_text(timeline.root, node))
    end,
    on_submit = function(node)
      close()
      tl.checkout(tostring(node.commit.seq))
    end,
    on_close = close,
  })

  local preview = Popup({
    border = { style = "rounded", text = { top = " diff vs parent ", top_align = "left" } },
    focusable = false,
    buf_options = { modifiable = false, readonly = false, filetype = "diff" },
  })

  local layout = Layout(
    { position = "50%", size = { width = "80%", height = "70%" } },
    Layout.Box({
      Layout.Box(list, { size = "35%" }),
      Layout.Box(preview, { size = "65%" }),
    }, { dir = "row" })
  )

  state = { layout = layout, list = list, preview = preview, timeline = timeline, branch = branch, branch_names = branch_names }

  layout:mount()
  set_preview(M._preview_text(timeline.root, items[1]))

  list:map("n", "<Tab>", function()
    local idx = 1
    for i, name in ipairs(branch_names) do
      if name == branch then
        idx = i
        break
      end
    end
    local next_branch = branch_names[(idx % #branch_names) + 1]
    close()
    mount(timeline, next_branch)
  end, { noremap = true })

  list:map("n", "b", function()
    local node = list.tree:get_node()
    if not node then
      return
    end
    vim.ui.input({ prompt = ("timeline.nvim: branch name at #%d: "):format(node.commit.seq) }, function(name)
      if not name or name == "" then
        return
      end
      local ok, err = tl.branch_from_commit(node.commit, name)
      if not ok then
        vim.notify("timeline.nvim: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(("timeline.nvim: created branch %q at #%d"):format(name, node.commit.seq))
      close()
      mount(timeline, name)
    end)
  end, { noremap = true })
end

--- :TimelineView -- open the picker for the current buffer's timeline,
--- starting on its current branch.
function M.open()
  local timeline = tl.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return
  end
  mount(timeline, index.current_branch(timeline.entry))
end

-- Exposed for tests only: lets a headless test confirm mount/unmount
-- doesn't error and inspect the resulting popups without scripting real
-- keypresses through a terminal.
M._state = function()
  return state
end
M._close = close

return M
