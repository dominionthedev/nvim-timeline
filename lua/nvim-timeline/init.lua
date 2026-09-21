-- init.lua
--
-- Wires the pieces together:
--   BufFilePre/BufFilePost  -> unambiguous rename, no hash-scan needed
--   BufWritePost            -> correlation judgment + branch-aware commit
--
-- Design decisions this encodes (see project notes for the full reasoning):
--   * identity correlation is lazy, at write-time -- no filesystem watcher
--   * one commit per BufWritePost
--   * content-addressed storage
--   * branching = named tips, no merges (single-writer history)
--   * checkout never writes to disk on its own -- it only loads content
--     into the buffer; landing on a branch tip is a persisted decision,
--     landing on an interior commit is a transient "detached" state that
--     only becomes real history if you save, at which point you're
--     prompted to name a branch -- same "don't guess" principle as the
--     same-basename correlation prompt
--   * hashing via vim.fn.sha256, no native dependency
--   * a deletion is discovered on the next related write, never witnessed

local store = require("nvim-timeline.store")
local index = require("nvim-timeline.index")
local correlate = require("nvim-timeline.correlate")
local log = require("nvim-timeline.log")

local M = {}

---@class Config
---@field store_dirname string  name of the store directory, resolved per-project

M.config = {
  store_dirname = ".nvim-timeline",
}

-- Tracks in-flight renames: bufnr -> old absolute path, set on BufFilePre
-- and consumed on BufFilePost. Renames are resolved directly through this,
-- never through the hash-based correlation path, because Neovim hands us
-- the old and new names with zero ambiguity.
local pending_renames = {}

-- Tracks buffers currently viewing a non-tip commit via :TimelineCheckout.
-- bufnr -> { timeline_id, root, hash }. Deliberately in-memory only --
-- being "detached" is never persisted to index.json; it either resolves
-- into a real new branch on the next save, or is abandoned by closing/
-- editing the buffer away, in which case nothing was ever recorded.
local detached = {}

--- Resolve the store root for a given file: walks up from the file's
--- directory looking for a `.git`, falling back to the file's own
--- directory if none is found. One store per project keeps commit logs
--- scoped sensibly instead of one global store for every file ever opened.
---@param file_path string absolute path to the file being tracked
---@return string root
local function resolve_root(file_path)
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local git_dir = vim.fs.find(".git", { path = dir, upward = true })[1]
  local project_root = git_dir and vim.fn.fnamemodify(git_dir, ":h") or dir
  return project_root .. "/" .. M.config.store_dirname
end

local function read_buffer_content(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

local function set_buffer_content(bufnr, content)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n"))
end

--- Look up the timeline_id tracking the current buffer's path, if any.
---@param root string
---@param file_path string
---@return string|nil id
---@return table<string,string>|nil paths
---@return table<string,TimelineEntry>|nil timelines
local function lookup_current(root, file_path)
  local paths, timelines = index.load(root)
  local id = index.lookup(paths, file_path)
  if not id then
    return nil, paths, timelines
  end
  return id, paths, timelines
end

--- The one place a commit actually gets written, regardless of how the
--- caller arrived at `id` (already-tracked path, exact-hash relink, or a
--- freshly created timeline). Consolidating this used to be 4 near-copies
--- of the same 10 lines -- once branches entered the picture that
--- duplication stopped being just untidy and became a real risk of one
--- copy forgetting to update the branch tip correctly.
---@param root string
---@param timelines table<string, TimelineEntry>
---@param id string
---@param file_path string
---@param content string
---@param hash string
---@param is_relink boolean|nil  -- true when this call is the recreation
---   event itself (exact-hash-match or a chosen "Link"). The tip hash is
---   unchanged by definition in that case (that's *why* it matched), but
---   the path is not -- this is the recreation event, not a no-change
---   save, and must be recorded even though the content didn't move.
local function commit_to_timeline(root, timelines, id, file_path, content, hash, is_relink)
  local entry = timelines[id]
  local branch = index.current_branch(entry)
  local parent = index.branch_head(entry, branch)

  if not is_relink and parent == hash then
    -- True no-op save: same path, same content as the current tip.
    return
  end

  store.put(root, content)
  log.append(root, id, {
    hash = hash,
    path = file_path,
    branch = branch,
    parent = parent,
    timestamp = os.time(),
  })
  index.set_branch_head(entry, branch, hash)
  entry.last_hash = hash
end

--- Resolve a detached checkout into real history: prompt for a branch
--- name, create it at the detached commit, then commit the buffer's
--- current content on top of it.
---@param bufnr integer
---@param file_path string
---@param content string
---@param hash string
local function commit_detached(bufnr, file_path, content, hash)
  local d = detached[bufnr]
  vim.ui.input({
    prompt = ("nvim-timeline: you're editing from an old commit (%s). Name a new branch to save this as: ")
      :format(d.hash:sub(1, 10)),
  }, function(name)
    if not name or name == "" then
      vim.notify("nvim-timeline: save cancelled -- no branch name given", vim.log.levels.WARN)
      return
    end

    local paths, timelines = index.load(d.root)
    local entry = timelines[d.timeline_id]
    index.create_branch(entry, name, d.hash)

    if hash == d.hash then
      -- Buffer wasn't actually changed since the checkout -- the new
      -- branch just points at the existing commit, nothing to append.
      index.save(d.root, paths, timelines)
    else
      store.put(d.root, content)
      log.append(d.root, d.timeline_id, {
        hash = hash,
        path = file_path,
        branch = name,
        parent = d.hash,
        timestamp = os.time(),
      })
      index.set_branch_head(entry, name, hash)
      entry.last_hash = hash
      index.save(d.root, paths, timelines)
    end

    detached[bufnr] = nil
    vim.notify(("nvim-timeline: saved to new branch %q"):format(name))
  end)
end

--- Handle a save: the core write-hook described in the design.
---@param bufnr integer
local function on_write(bufnr)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    return
  end

  local content = read_buffer_content(bufnr)
  local root = resolve_root(file_path)
  local hash = store.hash(content)

  if detached[bufnr] then
    commit_detached(bufnr, file_path, content, hash)
    return
  end

  local paths, timelines = index.load(root)
  local id = index.lookup(paths, file_path)

  if id then
    -- Known path: trivial case, no identity question at all.
    commit_to_timeline(root, timelines, id, file_path, content, hash)
    index.save(root, paths, timelines)
    return
  end

  -- Unindexed path: the one place correlation judgment is needed.
  local decision = correlate.decide(timelines, file_path, hash)

  if decision.kind == "exact_match" then
    index.relink(paths, timelines, decision.timeline_id, file_path, hash)
    commit_to_timeline(root, timelines, decision.timeline_id, file_path, content, hash, true)
    index.save(root, paths, timelines)
    return
  end

  if decision.kind == "candidate" then
    local old_path = timelines[decision.timeline_id].last_known_path
    vim.ui.select({ "Link", "Start new" }, {
      prompt = ("nvim-timeline: %s looks like it might continue %s (deleted earlier). Link them?")
        :format(vim.fn.fnamemodify(file_path, ":t"), old_path),
    }, function(choice)
      -- Re-load: time may have passed while the prompt was open.
      local p, t = index.load(root)
      if choice == "Link" then
        index.relink(p, t, decision.timeline_id, file_path, hash)
        commit_to_timeline(root, t, decision.timeline_id, file_path, content, hash, true)
      else
        local new_id = index.create(p, t, file_path, hash)
        commit_to_timeline(root, t, new_id, file_path, content, hash)
      end
      index.save(root, p, t)
    end)
    return
  end

  -- decision.kind == "new"
  local new_id = index.create(paths, timelines, file_path, hash)
  commit_to_timeline(root, timelines, new_id, file_path, content, hash)
  index.save(root, paths, timelines)
end

--- Handle an unambiguous rename: Neovim tells us the old and new name
--- directly (via BufFilePre/Post), so this bypasses correlate.lua
--- entirely -- there is no judgment call to make.
---@param bufnr integer
---@param old_path string
local function on_rename(bufnr, old_path)
  local new_path = vim.api.nvim_buf_get_name(bufnr)
  if old_path == "" or new_path == "" or old_path == new_path then
    return
  end

  local root = resolve_root(old_path)
  local paths, timelines = index.load(root)
  local id = index.lookup(paths, old_path)
  if not id then
    -- The old path wasn't tracked (e.g. renaming a file before its first
    -- save) -- nothing to relink yet; on_write will create it fresh.
    return
  end

  -- Content hasn't changed, just the path -- keep the existing hash.
  index.relink(paths, timelines, id, new_path, timelines[id].last_hash)
  index.save(root, paths, timelines)
end

--- :TimelineCheckout {branch-name|commit-ref}
---@param ref string
local function checkout(ref)
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    vim.notify("nvim-timeline: buffer has no file", vim.log.levels.WARN)
    return
  end

  local root = resolve_root(file_path)
  local id, paths, timelines = lookup_current(root, file_path)
  if not id then
    vim.notify("nvim-timeline: no history for this file yet", vim.log.levels.INFO)
    return
  end
  local entry = timelines[id]

  -- Branch name takes priority over treating the ref as a commit hash --
  -- branch names and hashes don't collide in practice, but if they ever
  -- did, landing on a named branch is the safer, more predictable choice.
  local branch_tip = index.branch_head(entry, ref)
  if branch_tip then
    local content = store.get(root, branch_tip)
    if not content then
      vim.notify("nvim-timeline: branch tip content missing from store (corrupt store?)", vim.log.levels.ERROR)
      return
    end
    index.switch_branch(entry, ref)
    index.save(root, paths, timelines)
    detached[vim.api.nvim_get_current_buf()] = nil
    set_buffer_content(0, content)
    vim.notify(("nvim-timeline: switched to branch %q"):format(ref))
    return
  end

  local commit, err = log.find(root, id, ref)
  if err then
    vim.notify("nvim-timeline: " .. err, vim.log.levels.ERROR)
    return
  end
  if not commit then
    vim.notify(("nvim-timeline: no branch or commit matching %q"):format(ref), vim.log.levels.WARN)
    return
  end

  -- Does this commit happen to be some branch's tip? Then it's really a
  -- branch checkout, just addressed by hash instead of by name.
  for name, tip in pairs(entry.branches) do
    if tip == commit.hash then
      checkout(name)
      return
    end
  end

  local content = store.get(root, commit.hash)
  if not content then
    vim.notify("nvim-timeline: commit content missing from store (corrupt store?)", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  detached[bufnr] = { timeline_id = id, root = root, hash = commit.hash }
  set_buffer_content(bufnr, content)
  vim.notify(
    ("nvim-timeline: viewing commit %s (not a branch tip) -- saving will prompt for a new branch name"):format(
      commit.hash:sub(1, 10)
    )
  )
end

--- :TimelineBranch {name} -- create a branch at the current position and
--- switch to it. Distinct from the detached-checkout prompt: this is an
--- explicit, deliberate branch creation while already sitting on a tip.
---@param name string
local function create_branch(name)
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    vim.notify("nvim-timeline: buffer has no file", vim.log.levels.WARN)
    return
  end

  local root = resolve_root(file_path)
  local id, paths, timelines = lookup_current(root, file_path)
  if not id then
    vim.notify("nvim-timeline: no history for this file yet -- save it first", vim.log.levels.INFO)
    return
  end

  local entry = timelines[id]
  local current_tip = index.branch_head(entry, index.current_branch(entry))
  if not current_tip then
    vim.notify("nvim-timeline: current branch has no commits yet -- save first", vim.log.levels.WARN)
    return
  end

  index.create_branch(entry, name, current_tip)
  index.save(root, paths, timelines)
  vim.notify(("nvim-timeline: created and switched to branch %q"):format(name))
end

--- :TimelineBranches -- list branches for the current file's timeline.
local function list_branches()
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    vim.notify("nvim-timeline: buffer has no file", vim.log.levels.WARN)
    return
  end

  local root = resolve_root(file_path)
  local id, _, timelines = lookup_current(root, file_path)
  if not id then
    vim.notify("nvim-timeline: no history for this file yet", vim.log.levels.INFO)
    return
  end

  local entry = timelines[id]
  local current = index.current_branch(entry)
  local lines = {}
  for name, tip in pairs(entry.branches) do
    table.insert(lines, ("  %s %s  %s"):format(name == current and "*" or " ", name, tip:sub(1, 10)))
  end
  table.sort(lines)
  vim.notify(table.concat(lines, "\n"))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local group = vim.api.nvim_create_augroup("NvimTimeline", { clear = true })

  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(args)
      pending_renames[args.buf] = vim.api.nvim_buf_get_name(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      local old_path = pending_renames[args.buf]
      pending_renames[args.buf] = nil

      -- :saveas creates a shadow buffer that retains the *old* name so
      -- it still has a buffer identity after the visible buffer moves
      -- to the new name. That shadow buffer fires its own
      -- BufFilePre/Post pair, which looks like a second, reverse rename
      -- if handled naively -- it would immediately relink the timeline
      -- back to the old path right after the real rename just moved it
      -- forward. Only the buffer that is actually current performed a
      -- rename a person asked for; the shadow buffer did not.
      if old_path and args.buf == vim.api.nvim_get_current_buf() then
        on_rename(args.buf, old_path)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      on_write(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      detached[args.buf] = nil
    end,
  })

  -- Deliberately bare: this exists to validate the log format against
  -- real edit history before any snacks/nui viewer gets built on top of
  -- it. Prints raw commit records for the current buffer's timeline.
  vim.api.nvim_create_user_command("TimelineLog", function()
    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
      vim.notify("nvim-timeline: buffer has no file", vim.log.levels.WARN)
      return
    end

    local root = resolve_root(file_path)
    local id = lookup_current(root, file_path)
    if not id then
      vim.notify("nvim-timeline: no history for this file yet", vim.log.levels.INFO)
      return
    end

    local commits = log.read(root, id)
    local lines = { ("timeline: %s (%d commits)"):format(id, #commits) }
    for i, commit in ipairs(commits) do
      table.insert(
        lines,
        ("  %d. %s  %s  [%s]"):format(
          i,
          os.date("%Y-%m-%d %H:%M:%S", commit.timestamp),
          commit.hash:sub(1, 10),
          commit.branch
        )
      )
    end
    vim.notify(table.concat(lines, "\n"))
  end, {})

  vim.api.nvim_create_user_command("TimelineCheckout", function(cmd_opts)
    checkout(cmd_opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("TimelineBranch", function(cmd_opts)
    create_branch(cmd_opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("TimelineBranches", function()
    list_branches()
  end, {})
end

return M
