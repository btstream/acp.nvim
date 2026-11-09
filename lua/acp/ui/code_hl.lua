-- Syntax highlighting for fenced code blocks.
--
-- Code blocks are the one place a real parser earns its cost: measuring showed
-- ~2.35 ms for a 60-line Lua block, which is acceptable because it runs once
-- when the fence closes and the result is cached on the block.
--
-- The inline scanner stays hand-rolled (see `acp.ui.markdown`); only blocks use
-- treesitter.
local M = {}

-- Fence languages whose treesitter parser name differs from what people type.
local ALIASES = {
  js = "javascript",
  jsx = "javascript",
  ts = "typescript",
  tsx = "typescript",
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  py = "python",
  rb = "ruby",
  yml = "yaml",
  md = "markdown",
  golang = "go",
  rs = "rust",
  ps1 = "powershell",
  ["c++"] = "cpp",
  ["objective-c"] = "objc",
}

---Resolve a fence language to a treesitter parser name.
---@param lang string
---@return string
function M.resolve_language(lang)
  local lower = lang:lower()
  return ALIASES[lower] or lower
end

---Whether a parser is installed for `lang`.
---@param lang string
---@return boolean
function M.has_parser(lang)
  local resolved = M.resolve_language(lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, "", resolved)
  if not ok or not parser then
    return false
  end
  -- `get_string_parser` can succeed lazily; force a parse to be sure.
  return pcall(function()
    parser:parse()
  end)
end

---Compute highlight ranges for a code block.
---
---Rows are relative to the code content (0-based), columns are byte offsets
---within the row. The caller maps them onto its rendered lines.
---@param code string
---@param lang string
---@return {row: integer, s: integer, e: integer, group: string}[]|nil
---@return boolean ok false when no parser is available
function M.highlight(code, lang)
  if code == "" or lang == "" then
    return nil, false
  end
  local resolved = M.resolve_language(lang)
  local parse_ok, parser = pcall(vim.treesitter.get_string_parser, code, resolved)
  if not parse_ok or not parser then
    return nil, false
  end
  local tree_ok, tree = pcall(function()
    return parser:parse()[1]
  end)
  if not tree_ok or not tree then
    return nil, false
  end
  local query_ok, query = pcall(vim.treesitter.query.get, resolved, "highlights")
  if not query_ok or not query then
    return nil, false
  end

  -- Collect captures with their priority so overlapping ranges resolve the way
  -- the editor itself resolves them.
  local captures = {}
  local iter_ok = pcall(function()
    for id, node, metadata in query:iter_captures(tree:root(), code) do
      local name = query.captures[id]
      local srow, scol, erow, ecol = node:range()
      captures[#captures + 1] = {
        row = srow,
        end_row = erow,
        s = scol,
        e = ecol,
        capture = name,
        priority = (metadata and metadata.priority) or 0,
      }
    end
  end)
  if not iter_ok then
    return nil, false
  end

  -- Stable sort by priority: low priority first, later writes win, matching the
  -- highlighter's own layering.
  table.sort(captures, function(a, b)
    if a.priority == b.priority then
      return a.s < b.s
    end
    return a.priority < b.priority
  end)

  local out = {}
  for _, c in ipairs(captures) do
    -- Multi-row captures (strings, comments) are split per row so the renderer
    -- can apply them line by line.
    if c.row == c.end_row then
      if c.e > c.s then
        out[#out + 1] = { row = c.row, s = c.s, e = c.e, group = M.group_for(c.capture, resolved) }
      end
    else
      for row = c.row, c.end_row do
        local line_start, line_end
        if row == c.row then
          line_start = c.s
        else
          line_start = 0
        end
        if row == c.end_row then
          line_end = c.e
        else
          line_end = nil -- to end of line, resolved by the caller
        end
        out[#out + 1] = {
          row = row,
          s = line_start,
          e = line_end,
          group = M.group_for(c.capture, resolved),
        }
      end
    end
  end
  return out, true
end

---Map a treesitter capture to a highlight group.
---
---Language-specific groups win, mirroring how the editor resolves them.
---`hlexists` cannot be used here: it reports 1 for any `@`-prefixed name,
---including ones that were never defined, so the definition itself is checked.
---@param capture string
---@param lang string
---@return string
function M.group_for(capture, lang)
  local specific = "@" .. capture .. "." .. lang
  local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = specific })
  if ok and type(def) == "table" and next(def) ~= nil then
    return specific
  end
  return "@" .. capture
end

return M
