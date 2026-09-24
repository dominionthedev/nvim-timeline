-- init.lua
--
-- Wires the pieces together:
--   BufFilePre/BufFilePost  -> unambiguous rename, no hash-scan needed
--   BufWritePost            -> correlation judgment + branch-aware commit
--   BufReadCmd (timeline://) -> read-only historical version, diffed
--
-- Design decisions this encodes (see project notes for the full reasoning):
--   * identity correlation is lazy, at write-time -- no filesystem watcher
--   * one commit per BufWritePost
--   * content-addressed storage, one store per project under
--     stdpath("state")/timeline (see timeline.paths for how a project's
--     store directory is resolved and disambiguated)
--   * branching = named tips, no merges (single-writer history)
--   * commit graph identity is a seq number, not content hash -- a
--     relink commit legitimately shares its parent's hash, so hash can't
--     double as graph identity (see history.lua)
--   * viewing a historical version (timeline://) never touches your
--     working buffer -- it opens a separate read-only split, diffed.
--     Checkout is the separate, riskier operation that loads a version
--     into your actual buffer.
--   * checkout never writes to disk on its own -- it only loads content
--     into the buffer; landing on a branch tip is a persisted decision,
--     landing on an interior commit is a transient "detached" state that
--     only becomes real history if you save, at which point you're
--     prompted to name a branch -- same "don't guess" principle as the
--     same-basename correlation prompt
--   * checkout refuses to clobber unsaved changes; forcing it stashes
--     the dirty content into the store first, never discards it silently
--   * hashing via vim.fn.sha256, no native dependency
--   * a deletion is discovered on the next related write, never witnessed

local store = require("timeline.store")
local index = require("timeline.index")
local correlate = require("timeline.correlate")
local log = require("timeline.log")
local paths = require("timeline.paths")

local M = {}

M.config = {}

-- Tracks in-flight renames: bufnr -> old absolute path, set on BufFilePre
-- and consumed on BufFilePost. Renames are resolved directly through this,
-- never through the hash-based correlation path, because Neovim hands us
-- the old and new names with zero ambiguity.
local pending_renames = {}

-- Tracks buffers currently viewing a non-tip commit via checkout().
-- bufnr -> { timeline_id, root, hash, seq }. Deliberately in-memory only
-- -- being "detached" is never persisted to index.json; it either
-- resolves into a real new branch on the next save, or is abandoned by
-- closing/editing the buffer away, in which case nothing was recorded.
local detached = {}

-- Pairs a timeline:// viewer window to the original window it was
-- diffed against, purely so closing the viewer can turn diff mode back
-- off on the original instead of leaving it stuck in diff view.
local diff_pairs = {}

local function resolve_root(file_path)
  return paths.store_dir(paths.project_root(file_path))
end
M.resolve_root = resolve_root

local function read_buffer_content(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

local function set_buffer_content(bufnr, content)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n"))
end

--- Look up the timeline_id tracking a path, if any.
---@param root string
---@param file_path string
---@return string|nil id
---@return table<string,string>|nil paths
---@return table<string,TimelineEntry>|nil timelines
local function lookup_current(root, file_path)
  local file_paths, timelines = index.load(root)
  local id = index.lookup(file_paths, file_path)
  if not id then
    return nil, file_paths, timelines
  end
  return id, file_paths, timelines
end

--- Resolve a file down to {root, id, paths, timelines, entry, commits},
--- or nil if untracked. Defaults to the current buffer, but accepts an
--- explicit path -- sidebar.lua needs this because it resolves the
--- *tracked* file's timeline while keyboard focus is in the sidebar's
--- own window, where "the current buffer" would be the sidebar itself.
---@param file_path string|nil
---@return table|nil
function M.current_timeline(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    return nil
  end
  local root = resolve_root(file_path)
  local id, file_paths, timelines = lookup_current(root, file_path)
  if not id then
    return nil
  end
  return {
    root = root,
    id = id,
    paths = file_paths,
    timelines = timelines,
    entry = timelines[id],
    commits = log.read(root, id),
  }
end

--- The one place a commit actually gets written, regardless of how the
--- caller arrived at `id` (already-tracked path, exact-hash relink, or a
--- freshly created timeline).
---@param root string
---@param timelines table<string, TimelineEntry>
---@param id string
---@param file_path string
---@param content string
---@param hash string
---@param is_relink boolean|nil  -- true for the recreation event itself
---   (exact-hash-match or a chosen "Link"): the tip hash is unchanged by
---   definition (that's why it matched), but the path is not, so this
---   must still be recorded even though content didn't move.
local function commit_to_timeline(root, timelines, id, file_path, content, hash, is_relink)
  local entry = timelines[id]
  local branch = index.current_branch(entry)
  local tip = index.branch_head(entry, branch)

  if not is_relink and tip and tip.hash == hash then
    -- True no-op save: same path, same content as the current tip.
    return
  end

  local seq = index.next_seq(entry)
  store.put(root, content)
  log.append(root, id, {
    seq = seq,
    hash = hash,
    path = file_path,
    branch = branch,
    parent = tip and tip.seq or nil,
    timestamp = os.time(),
  })
  index.set_branch_head(entry, branch, hash, seq)
  entry.last_hash = hash
end

--- Resolve a detached checkout into real history: prompt for a branch
--- name, create it at the detached commit, then commit the buffer's
--- current content on top of it.
local function commit_detached(bufnr, file_path, content, hash)
  local d = detached[bufnr]
  vim.ui.input({
    prompt = ("timeline.nvim: you're editing from an old commit (%s). Name a new branch to save this as: ")
      :format(d.hash:sub(1, 10)),
  }, function(name)
    if not name or name == "" then
      vim.notify("timeline.nvim: save cancelled -- no branch name given", vim.log.levels.WARN)
      return
    end

    local file_paths, timelines = index.load(d.root)
    local entry = timelines[d.timeline_id]
    index.create_branch(entry, name, d.hash, d.seq)

    if hash == d.hash then
      index.save(d.root, file_paths, timelines)
    else
      local seq = index.next_seq(entry)
      store.put(d.root, content)
      log.append(d.root, d.timeline_id, {
        seq = seq,
        hash = hash,
        path = file_path,
        branch = name,
        parent = d.seq,
        timestamp = os.time(),
      })
      index.set_branch_head(entry, name, hash, seq)
      entry.last_hash = hash
      index.save(d.root, file_paths, timelines)
    end

    detached[bufnr] = nil
    vim.notify(("timeline.nvim: saved to new branch %q"):format(name))
  end)
end

--- Handle a save: the core write-hook described in the design.
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

  local file_paths, timelines = index.load(root)
  local id = index.lookup(file_paths, file_path)

  if id then
    commit_to_timeline(root, timelines, id, file_path, content, hash)
    index.save(root, file_paths, timelines)
    return
  end

  local decision = correlate.decide(timelines, file_path, hash)

  if decision.kind == "exact_match" then
    index.relink(file_paths, timelines, decision.timeline_id, file_path, hash)
    commit_to_timeline(root, timelines, decision.timeline_id, file_path, content, hash, true)
    index.save(root, file_paths, timelines)
    return
  end

  if decision.kind == "candidate" then
    local old_path = timelines[decision.timeline_id].last_known_path
    vim.ui.select({ "Link", "Start new" }, {
      prompt = ("timeline.nvim: %s looks like it might continue %s (deleted earlier). Link them?")
        :format(vim.fn.fnamemodify(file_path, ":t"), old_path),
    }, function(choice)
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

  local new_id = index.create(file_paths, timelines, file_path, hash)
  commit_to_timeline(root, timelines, new_id, file_path, content, hash)
  index.save(root, file_paths, timelines)
end

--- Handle an unambiguous rename: Neovim tells us the old and new name
--- directly, so this bypasses correlate.lua entirely.
local function on_rename(bufnr, old_path)
  local new_path = vim.api.nvim_buf_get_name(bufnr)
  if old_path == "" or new_path == "" or old_path == new_path then
    return
  end

  local root = resolve_root(old_path)
  local file_paths, timelines = index.load(root)
  local id = index.lookup(file_paths, old_path)
  if not id then
    return
  end

  index.relink(file_paths, timelines, id, new_path, timelines[id].last_hash)
  index.save(root, file_paths, timelines)
end

--- Resolve a ref (branch name, seq, or hash prefix) against a timeline.
---@return Commit|nil commit
---@return string|nil err
---@return string|nil branch_name  set if ref was resolved as a branch name
local function resolve_ref(root, id, entry, ref)
  local tip = index.branch_head(entry, ref)
  if tip then
    local commit = log.find(root, id, tostring(tip.seq))
    return commit, nil, ref
  end

  local commit, err = log.find(root, id, ref)
  if err then
    return nil, err, nil
  end
  if not commit then
    return nil, ("no branch or commit matching %q"):format(ref), nil
  end
  return commit, nil, nil
end

--- :TimelineCheckout {branch-name|commit-ref}. Also called by
--- sidebar.lua for its checkout action.
---@param ref string
---@param force boolean|nil  bypass the unsaved-changes guard, stashing first
---@return boolean ok
function M.checkout(ref, force)
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    vim.notify("timeline.nvim: buffer has no file", vim.log.levels.WARN)
    return false
  end

  local root = resolve_root(file_path)
  local id, file_paths, timelines = lookup_current(root, file_path)
  if not id then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return false
  end
  local entry = timelines[id]

  local commit, err, branch_name = resolve_ref(root, id, entry, ref)
  if err then
    vim.notify("timeline.nvim: " .. err, vim.log.levels.ERROR)
    return false
  end

  -- Safety guard: never silently clobber unsaved edits. This is checked
  -- here, after resolving the ref (so a bad ref fails before we even ask
  -- about unsaved changes) but before anything about the buffer changes.
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    if not force then
      vim.notify(
        "timeline.nvim: buffer has unsaved changes -- save first, or force checkout (stashes your changes instead of losing them)",
        vim.log.levels.WARN
      )
      return false
    end

    local dirty_content = read_buffer_content(bufnr)
    local dirty_hash = store.hash(dirty_content)
    store.put(root, dirty_content)
    local based_on = detached[bufnr] and detached[bufnr].seq or (index.branch_head(entry, index.current_branch(entry)) or {}).seq
    index.add_stash(entry, dirty_hash, based_on, file_path)
    index.save(root, file_paths, timelines)
    vim.notify("timeline.nvim: stashed unsaved changes (see :TimelineStashes) before checkout", vim.log.levels.WARN)
  end

  if branch_name then
    local content = store.get(root, commit.hash)
    if not content then
      vim.notify("timeline.nvim: branch tip content missing from store (corrupt store?)", vim.log.levels.ERROR)
      return false
    end
    index.switch_branch(entry, branch_name)
    index.save(root, file_paths, timelines)
    detached[bufnr] = nil
    set_buffer_content(bufnr, content)
    vim.bo[bufnr].modified = false
    vim.notify(("timeline.nvim: switched to branch %q"):format(branch_name))
    return true
  end

  -- Does this commit happen to be some branch's tip, just addressed by
  -- seq/hash instead of by name? Then it's really a branch checkout.
  for name, branch_tip in pairs(entry.branches) do
    if branch_tip.seq == commit.seq then
      return M.checkout(name, force)
    end
  end

  local content = store.get(root, commit.hash)
  if not content then
    vim.notify("timeline.nvim: commit content missing from store (corrupt store?)", vim.log.levels.ERROR)
    return false
  end

  detached[bufnr] = { timeline_id = id, root = root, hash = commit.hash, seq = commit.seq }
  set_buffer_content(bufnr, content)
  vim.bo[bufnr].modified = false
  vim.notify(
    ("timeline.nvim: viewing commit #%d %s (not a branch tip) -- saving will prompt for a new branch name"):format(
      commit.seq,
      commit.hash:sub(1, 10)
    )
  )
  return true
end

local function build_timeline_url(root, id, seq)
  return ("timeline://%s/%s/%d"):format(root, id, seq)
end

local function build_stash_url(root, id, n)
  return ("timeline://%s/%s/stash/%d"):format(root, id, n)
end

local function parse_timeline_url(name)
  local root, id, n = name:match("^timeline://(.+)/([^/]+)/stash/(%d+)$")
  if root then
    return root, id, nil, tonumber(n)
  end
  local seq
  root, id, seq = name:match("^timeline://(.+)/([^/]+)/(%d+)$")
  if root then
    return root, id, tonumber(seq), nil
  end
  return nil
end

--- Open a read-only, diffed view of historical content in a split. Used
--- both for viewing a commit (content resolved via log.find) and for
--- recovering a stash (content resolved directly by hash) -- the window
--- mechanics are identical either way.
local function open_diff_split(url, content, filetype_hint)
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd("belowright vsplit " .. vim.fn.fnameescape(url))
  local new_win = vim.api.nvim_get_current_win()
  local new_buf = vim.api.nvim_get_current_buf()

  vim.bo[new_buf].modifiable = true
  vim.bo[new_buf].readonly = false
  set_buffer_content(new_buf, content)
  vim.bo[new_buf].buftype = "nofile"
  vim.bo[new_buf].swapfile = false
  vim.bo[new_buf].modifiable = false
  vim.bo[new_buf].readonly = true
  if filetype_hint then
    vim.bo[new_buf].filetype = filetype_hint
  end

  vim.wo[original_win].diff = true
  vim.wo[new_win].diff = true
  diff_pairs[new_win] = original_win

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(new_win),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(original_win) then
        vim.wo[original_win].diff = false
      end
      diff_pairs[new_win] = nil
    end,
  })
end

--- :TimelineShow {ref} -- open a read-only diffed view of a commit or
--- branch tip WITHOUT touching the current buffer. This is the safe
--- counterpart to checkout(): looking vs. loading.
---@param ref string
function M.view(ref)
  local timeline = M.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return
  end

  local commit, err = resolve_ref(timeline.root, timeline.id, timeline.entry, ref)
  if err then
    vim.notify("timeline.nvim: " .. err, vim.log.levels.ERROR)
    return
  end

  local content = store.get(timeline.root, commit.hash)
  if not content then
    vim.notify("timeline.nvim: commit content missing from store (corrupt store?)", vim.log.levels.ERROR)
    return
  end

  local url = build_timeline_url(timeline.root, timeline.id, commit.seq)
  local ft = vim.filetype.match({ filename = commit.path })
  open_diff_split(url, content, ft)
end

--- View a stash entry (1-based index, newest-first as listed by
--- :TimelineStashes) as a read-only diff, the same way a commit is
--- viewed -- recovering from a stash should be exactly as easy as
--- looking at any other historical version.
---@param n integer
function M.view_stash(n)
  local timeline = M.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return
  end
  local stashes = index.list_stashes(timeline.entry)
  local stash = stashes[n]
  if not stash then
    vim.notify(("timeline.nvim: no stash #%d"):format(n), vim.log.levels.WARN)
    return
  end
  local content = store.get(timeline.root, stash.hash)
  if not content then
    vim.notify("timeline.nvim: stash content missing from store (corrupt store?)", vim.log.levels.ERROR)
    return
  end
  local url = build_stash_url(timeline.root, timeline.id, n)
  local ft = vim.filetype.match({ filename = stash.path })
  open_diff_split(url, content, ft)
end

--- Create a branch pointing at a specific commit.
local function do_create_branch(root, file_paths, timelines, entry, name, hash, seq)
  index.create_branch(entry, name, hash, seq)
  index.save(root, file_paths, timelines)
end

--- :TimelineBranch {name} -- create a branch at the current tip and
--- switch to it.
---@param name string
function M.create_branch(name)
  local timeline = M.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet -- save it first", vim.log.levels.INFO)
    return
  end

  local tip = index.branch_head(timeline.entry, index.current_branch(timeline.entry))
  if not tip then
    vim.notify("timeline.nvim: current branch has no commits yet -- save first", vim.log.levels.WARN)
    return
  end

  do_create_branch(timeline.root, timeline.paths, timeline.timelines, timeline.entry, name, tip.hash, tip.seq)
  vim.notify(("timeline.nvim: created and switched to branch %q"):format(name))
end

--- Branch off an arbitrary commit (not necessarily the current tip).
--- What the sidebar's "branch from here" action calls.
---@param commit Commit
---@param name string
---@return boolean ok
---@return string|nil err
function M.branch_from_commit(commit, name)
  local timeline = M.current_timeline()
  if not timeline then
    return false, "no history for this file yet"
  end
  do_create_branch(timeline.root, timeline.paths, timeline.timelines, timeline.entry, name, commit.hash, commit.seq)
  return true
end

--- :TimelineBranches -- list branches for the current file's timeline.
function M.list_branches()
  local timeline = M.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return
  end

  local current = index.current_branch(timeline.entry)
  local lines = {}
  for name, tip in pairs(timeline.entry.branches) do
    table.insert(lines, ("  %s %s  #%d %s"):format(name == current and "*" or " ", name, tip.seq, tip.hash:sub(1, 10)))
  end
  table.sort(lines)
  vim.notify(table.concat(lines, "\n"))
end

--- :TimelineStashes -- list stashed unsaved-change snapshots created by
--- forced checkouts (see the safety guard in checkout() above).
function M.list_stashes()
  local timeline = M.current_timeline()
  if not timeline then
    vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
    return
  end
  local stashes = index.list_stashes(timeline.entry)
  if #stashes == 0 then
    vim.notify("timeline.nvim: no stashes for this file")
    return
  end
  local lines = {}
  for i, stash in ipairs(stashes) do
    table.insert(
      lines,
      ("  #%d  %s  %s  (based on #%s)"):format(
        i,
        os.date("%Y-%m-%d %H:%M:%S", stash.timestamp),
        stash.hash:sub(1, 10),
        stash.based_on and tostring(stash.based_on) or "?"
      )
    )
  end
  vim.notify(table.concat(lines, "\n"))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local group = vim.api.nvim_create_augroup("Timeline", { clear = true })

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
      -- if handled naively. Only the buffer that is actually current
      -- performed a rename a person asked for.
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

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "timeline://*",
    callback = function(args)
      local root, id, seq, stash_n = parse_timeline_url(args.match)
      if not root then
        vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { "timeline.nvim: malformed timeline:// url" })
        return
      end

      local content, filetype_hint
      if stash_n then
        local _, timelines = index.load(root)
        local entry = timelines[id]
        local stash = entry and index.list_stashes(entry)[stash_n]
        content = stash and store.get(root, stash.hash)
        filetype_hint = stash and vim.filetype.match({ filename = stash.path })
      else
        local commit = log.find(root, id, tostring(seq))
        content = commit and store.get(root, commit.hash)
        filetype_hint = commit and vim.filetype.match({ filename = commit.path })
      end

      vim.bo[args.buf].modifiable = true
      vim.bo[args.buf].readonly = false
      if content then
        set_buffer_content(args.buf, content)
      else
        set_buffer_content(args.buf, "timeline.nvim: content not found (corrupt store?)")
      end
      vim.bo[args.buf].buftype = "nofile"
      vim.bo[args.buf].swapfile = false
      vim.bo[args.buf].modifiable = false
      vim.bo[args.buf].readonly = true
      if filetype_hint then
        vim.bo[args.buf].filetype = filetype_hint
      end
    end,
  })

  vim.api.nvim_create_user_command("TimelineLog", function()
    local timeline = M.current_timeline()
    if not timeline then
      vim.notify("timeline.nvim: no history for this file yet", vim.log.levels.INFO)
      return
    end

    local lines = { ("timeline: %s (%d commits)"):format(timeline.id, #timeline.commits) }
    for _, commit in ipairs(timeline.commits) do
      table.insert(
        lines,
        ("  #%d %s  %s  [%s]"):format(
          commit.seq,
          os.date("%Y-%m-%d %H:%M:%S", commit.timestamp),
          commit.hash:sub(1, 10),
          commit.branch
        )
      )
    end
    vim.notify(table.concat(lines, "\n"))
  end, {})

  vim.api.nvim_create_user_command("TimelineCheckout", function(cmd_opts)
    M.checkout(cmd_opts.args, cmd_opts.bang)
  end, { nargs = 1, bang = true })

  vim.api.nvim_create_user_command("TimelineShow", function(cmd_opts)
    M.view(cmd_opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("TimelineBranch", function(cmd_opts)
    M.create_branch(cmd_opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("TimelineBranches", function()
    M.list_branches()
  end, {})

  vim.api.nvim_create_user_command("TimelineStashes", function()
    M.list_stashes()
  end, {})

  vim.api.nvim_create_user_command("TimelineStashShow", function(cmd_opts)
    M.view_stash(tonumber(cmd_opts.args))
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("TimelineView", function()
    require("timeline.view").open()
  end, {})
end

return M
