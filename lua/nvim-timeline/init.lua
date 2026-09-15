-- init.lua
--
-- Wires the pieces together:
--   BufFilePre/BufFilePost  -> unambiguous rename, no hash-scan needed
--   BufWritePost            -> the one place correlation judgment happens
--
-- Design decisions this encodes (see project notes for the full reasoning):
--   * identity correlation is lazy, at write-time -- no filesystem watcher
--   * one commit per BufWritePost
--   * content-addressed storage
--   * branching = named tips, no merges (v1 always commits to "main";
--     branch creation/switching is a later milestone, not implemented here)
--   * hashing via vim.fn.sha256, no native dependency
--   * a deletion is discovered on the next related write, never witnessed

local store = require("nvim-timeline.store")
local index = require("nvim-timeline.index")
local correlate = require("nvim-timeline.correlate")
local log = require("nvim-timeline.log")

local M = {}

local DEFAULT_BRANCH = "main"

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

  local paths, timelines = index.load(root)
  local id = index.lookup(paths, file_path)

  if id then
    -- Known path: trivial case, no identity question at all.
    local head = log.head(root, id)
    if head and head.hash == hash then
      -- No-op save (e.g. :w with no changes) -- don't create a commit
      -- for content that hasn't moved.
      return
    end
    store.put(root, content)
    log.append(root, id, {
      hash = hash,
      path = file_path,
      branch = DEFAULT_BRANCH,
      parent = head and head.hash or nil,
      timestamp = os.time(),
    })
    timelines[id].last_hash = hash
    index.save(root, paths, timelines)
    return
  end

  -- Unindexed path: the one place correlation judgment is needed.
  local decision = correlate.decide(timelines, file_path, hash)

  if decision.kind == "exact_match" then
    local old_head = log.head(root, decision.timeline_id)
    index.relink(paths, timelines, decision.timeline_id, file_path, hash)
    store.put(root, content)
    log.append(root, decision.timeline_id, {
      hash = hash,
      path = file_path,
      branch = DEFAULT_BRANCH,
      parent = old_head and old_head.hash or nil,
      timestamp = os.time(),
    })
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
        local old_head = log.head(root, decision.timeline_id)
        index.relink(p, t, decision.timeline_id, file_path, hash)
        store.put(root, content)
        log.append(root, decision.timeline_id, {
          hash = hash,
          path = file_path,
          branch = DEFAULT_BRANCH,
          parent = old_head and old_head.hash or nil,
          timestamp = os.time(),
        })
      else
        local new_id = index.create(p, t, file_path, hash)
        store.put(root, content)
        log.append(root, new_id, {
          hash = hash,
          path = file_path,
          branch = DEFAULT_BRANCH,
          parent = nil,
          timestamp = os.time(),
        })
      end
      index.save(root, p, t)
    end)
    return
  end

  -- decision.kind == "new"
  local new_id = index.create(paths, timelines, file_path, hash)
  store.put(root, content)
  log.append(root, new_id, {
    hash = hash,
    path = file_path,
    branch = DEFAULT_BRANCH,
    parent = nil,
    timestamp = os.time(),
  })
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
    local paths = select(1, index.load(root))
    local id = index.lookup(paths, file_path)
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
end

return M
