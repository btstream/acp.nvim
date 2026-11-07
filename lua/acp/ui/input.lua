-- The composer window: editable buffer, winbar toolbar, per-session drafts.
local i18n = require("acp.i18n")
local log = require("acp.log")

local M = {}

---@class AcpInputView
---@field buf integer
---@field win integer|nil
---@field attachments table[]
---@field drafts table<string, {text: string[]|nil, attachments: table[]|nil}>
local Input = {}
Input.__index = Input

---@param opts {config: table, on_submit: fun(text: string, attachments: table[]), on_cancel: fun()}
---@return AcpInputView
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    on_submit = opts.on_submit,
    on_cancel = opts.on_cancel,
    buf = nil,
    win = nil,
    attachments = {},
    drafts = {},
    session_key = nil,
    toolbar = "",
    toolbar_running = false,
  }, Input)

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "acp_input"
  vim.bo[self.buf].buflisted = false
  vim.bo[self.buf].undolevels = 1000
  vim.bo[self.buf].textwidth = 0

  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
  vim.bo[self.buf].modified = false

  local group = vim.api.nvim_create_augroup("AcpInput" .. self.buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:apply_winbar()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = self.buf,
    callback = function()
      self.win = nil
    end,
  })

  return self
end

function Input:apply_winbar()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local placement = self.config.ui.toolbar.placement
  if placement == "off" then
    pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
    return
  end
  -- Set once: the expression re-renders on every redraw with the real window
  -- width, so resizes and layout managers can never leave a stale bar behind.
  pcall(vim.api.nvim_set_option_value, "winbar", "%{%v:lua.AcpComposerBar()%}", { win = win })
end

---@param parts string[]
function Input:set_toolbar(parts)
  self.toolbar = table.concat(parts, "  ")
  self:apply_winbar()
end

---Save the visible buffer into the current draft slot.
function Input:save_draft()
  if not self.session_key then
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local empty = #lines == 0 or (#lines == 1 and lines[1] == "")
  self.drafts[self.session_key] = {
    text = empty and nil or lines,
    attachments = #self.attachments > 0 and vim.deepcopy(self.attachments) or nil,
  }
  if self.on_draft then
    self.on_draft(self.session_key, empty and "" or table.concat(lines, "\n"), self.attachments)
  end
end

---Switch drafts when the active session changes.
---@param key string|nil
---@param restored {text: string, attachments: table[]}|nil
function Input:switch_session(key, restored)
  if self.session_key == key then
    return
  end
  self:save_draft()
  self.session_key = key
  local draft = restored or (key and self.drafts[key] or nil)
  self.attachments = draft and draft.attachments or {}
  local lines = draft and draft.text or { "" }
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modified = false
    vim.bo[self.buf].modifiable = true
  end
end

---@return string
function Input:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

function Input:clear()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
  self.attachments = {}
  if self.session_key then
    self.drafts[self.session_key] = nil
  end
end

function Input:restore(text)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

---@param attachment {kind: string, label: string, path?: string, uri?: string, text?: string}
function Input:add_attachment(attachment)
  for i, existing in ipairs(self.attachments) do
    if existing.kind == attachment.kind and existing.path == attachment.path and existing.uri == attachment.uri then
      self.attachments[i] = attachment
      self:refresh()
      return false
    end
  end
  self.attachments[#self.attachments + 1] = attachment
  self:refresh()
  return true
end

---@param index integer
function Input:remove_attachment(index)
  table.remove(self.attachments, index)
  self:refresh()
end

function Input:clear_attachments()
  self.attachments = {}
  self:refresh()
end

function Input:refresh()
  if self.on_refresh then
    self.on_refresh()
  end
end

function Input:submit()
  local text = self:text()
  if text:match("^%s*$") and #self.attachments == 0 then
    return
  end
  if self.on_submit then
    self.on_submit(text, self.attachments)
  end
end

function Input:cancel()
  if self.on_cancel then
    self.on_cancel()
  end
end

---Resize the composer window within configured bounds.
---@param delta integer
function Input:resize(delta)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local height = vim.api.nvim_win_get_height(win)
  local target =
    math.max(self.config.layout.min_input_height, math.min(self.config.layout.max_input_height, height + delta))
  if target == height then
    return
  end
  local ok = pcall(vim.api.nvim_win_set_height, win, target)
  if not ok then
    log.debug("input resize failed")
  end
end

function Input:is_visible()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

return M
