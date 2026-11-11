-- Which review policy applies to a finished inline request.
--
-- Policy is data, resolved per buffer: an exact filetype, then the first
-- component of a compound filetype (`markdown.pandoc` -> `markdown`), then `*`,
-- then the configured default. A buffer marked "always accept" from the diff
-- UI wins over every configuration entry.
local M = {}

-- Buffers whose diff UI chose "accept everything from now on". Deliberately
-- session-only: a restart should not silently keep writing changes straight
-- into files.
local always_accept = {}

---@param bufnr integer
function M.always_accept(bufnr)
  if always_accept[bufnr] then
    return
  end
  always_accept[bufnr] = true
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        always_accept[bufnr] = nil
      end,
    })
  end
end

---@param bufnr integer
function M.reset(bufnr)
  always_accept[bufnr] = nil
end

---@param bufnr integer
---@return boolean
function M.is_always_accepted(bufnr)
  return always_accept[bufnr] == true
end

---The configured value for one pattern, accepting the `{ mode = ... }` form.
---@param value string|table|nil
---@return string|nil
local function mode_of(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    return type(value.mode) == "string" and value.mode or nil
  end
  return nil
end

---Resolve the effective mode.
---
---Returns `mode, source` so callers can say *why* a change was written without
---review. `filetype` is passed explicitly because the buffer may have been
---closed by the time a result arrives.
---@param filetype string|nil
---@param config table
---@param bufnr integer|nil
---@return "diff"|"write" mode
---@return string source
function M.resolve(filetype, config, bufnr)
  local inline = (config and config.inline) or {}
  local review = inline.review or {}
  local default = mode_of(review.mode) or "diff"
  if bufnr and always_accept[bufnr] then
    return "write", "always"
  end
  filetype = type(filetype) == "string" and filetype or ""
  if filetype ~= "" then
    local overrides = type(review.by_filetype) == "table" and review.by_filetype or {}
    local exact = mode_of(overrides[filetype])
    if exact then
      return exact, filetype
    end
    local head = filetype:match("^[^.]+")
    if head and head ~= filetype then
      local compound = mode_of(overrides[head])
      if compound then
        return compound, head
      end
    end
  end
  local overrides = type(review.by_filetype) == "table" and review.by_filetype or {}
  local wildcard = mode_of(overrides["*"])
  if wildcard then
    return wildcard, "*"
  end
  return default, "default"
end

return M
