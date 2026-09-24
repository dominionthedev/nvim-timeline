vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local select_choice = nil
vim.ui.select = function(_, _, on_choice)
  on_choice(select_choice)
end

local input_answer = nil
vim.ui.input = function(_, on_confirm)
  on_confirm(input_answer)
end

local tl = require("timeline")
tl.setup({})

local dir = "/tmp/timeline-test-branch"
h.fresh_project(dir)
local store = h.store_dir(dir)

-- commit A, then commit B on main
h.write_file(dir .. "/f.txt", "content A")
h.write_file(dir .. "/f.txt", "content B")

local idx = h.read_json(store .. "/index.json")
local id = idx.paths[dir .. "/f.txt"]
local entry = idx.timelines[id]
local commit_a_hash = nil
do
  local f = assert(io.open(store .. "/log/" .. id .. ".jsonl", "r"))
  for line in f:lines() do
    local c = vim.json.decode(line)
    if c.path == dir .. "/f.txt" and c.parent == nil then
      commit_a_hash = c.hash
    end
  end
  f:close()
end
h.assert_true(commit_a_hash ~= nil, "found commit A's hash in the log")

vim.cmd("edit " .. dir .. "/f.txt")
vim.cmd("TimelineCheckout " .. commit_a_hash:sub(1, 10))

h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
  "content A",
  "checkout loads old content into the buffer"
)

-- edit while detached, then save -- should prompt for a branch name
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "content A edited" })
input_answer = "experiment"
vim.cmd("write")

idx = h.read_json(store .. "/index.json")
entry = idx.timelines[id]

h.assert_true(
  entry.branches["experiment"] ~= nil,
  "saving from a detached checkout creates the named branch"
)
h.assert_eq(entry.head_branch, "experiment", "the new branch becomes current after the prompt")
h.assert_true(entry.branches["main"] ~= nil, "main branch tip is untouched by the detached save")

-- switch back to main and confirm content reverts
vim.cmd("TimelineCheckout main")
h.assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
  "content B",
  "switching back to main restores its content"
)

idx = h.read_json(store .. "/index.json")
h.assert_eq(
  idx.timelines[id].head_branch,
  "main",
  "checking out a branch by name persists as current"
)

-- explicit branch creation at the current tip
vim.cmd("TimelineBranch stable")
idx = h.read_json(store .. "/index.json")
h.assert_eq(
  idx.timelines[id].branches["stable"].hash,
  idx.timelines[id].branches["main"].hash,
  "explicit branch creation points at the current tip"
)
h.assert_eq(
  idx.timelines[id].branches["stable"].seq,
  idx.timelines[id].branches["main"].seq,
  "explicit branch creation points at the same seq as the tip it branched from"
)
h.assert_eq(
  idx.timelines[id].head_branch,
  "stable",
  "explicit branch creation switches to the new branch"
)

h.finish()
