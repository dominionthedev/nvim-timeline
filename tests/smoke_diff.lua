vim.opt.rtp:prepend(vim.fn.getcwd())
local h = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")

local diff = require("timeline.diff")

local d = diff.unified("line one\nline two", "line one\nline two changed")
h.assert_true(d:find("line two changed") ~= nil, "unified diff contains the new content")
h.assert_true(d:find("@@") ~= nil, "unified diff has a hunk header")

local same = diff.unified("same", "same")
h.assert_eq(same, "(no changes)", "identical content is reported plainly instead of an empty string")

local root = diff.unified(nil, "brand new content")
h.assert_true(root:find("brand new content") ~= nil, "a nil old_content (root commit) diffs against empty, showing the whole file as additions")

h.finish()
