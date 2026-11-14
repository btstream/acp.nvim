-- The composer window: editable buffer, winbar toolbar, per-session drafts.
local log = require("acp.log")
local memory = require("acp.session.memory")
local image_ns = vim.api.nvim_create_namespace("acp.input.images")
local anchor_ns = vim.api.nvim_create_namespace("acp.input.image_anchor")

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
    image_marks = {},
    draft_epoch = 0,
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
  self.augroup = group
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:apply_winbar()
      if vim.api.nvim_get_current_buf() == self.buf then
        vim.cmd("startinsert")
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      vim.cmd("stopinsert")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = self.buf,
    callback = function()
      self.win = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:sync_images()
    end,
  })
  -- At either edge, erase the complete attachment token with one key. Normal
  -- cursor motions and selections work because the token is real buffer text.
  for key, backward in pairs({ ["<BS>"] = true, ["<Del>"] = false }) do
    vim.keymap.set("i", key, function()
      local p = self:cursor_position()
      for att, id in pairs(self.image_marks) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, { details = true })
        if #mark > 0 then
          local d = mark[3]
          local edge = backward and d.end_col or mark[2]
          if p[1] == mark[1] and p[2] == edge and self:token_matches(att, mark) then
            return vim.keycode("<C-g>u") .. string.rep(vim.keycode(key), #att.input_token)
          end
        end
      end
      return vim.keycode(key)
    end, { buffer = self.buf, expr = true, replace_keycodes = false, desc = "Delete image token or character" })
  end

  return self
end

---Tear down the composer: drop its buffer and autocmd group.
function Input:destroy()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
  self.win = nil
end

---@return boolean ok
---@return string|nil err observable by the chrome owner; focus events may ignore it
function Input:apply_winbar()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false, "composer window is not visible"
  end
  local placement = self.config.ui.toolbar.placement
  if placement == "off" then
    return pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
  end
  -- Set once: the expression re-renders on every redraw with the real window
  -- width, so resizes and layout managers can never leave a stale bar behind.
  if vim.api.nvim_get_option_value("winbar", { win = win }) ~= "%{%v:lua.AcpComposerBar()%}" then
    return pcall(vim.api.nvim_set_option_value, "winbar", "%{%v:lua.AcpComposerBar()%}", { win = win })
  end
  return true
end

---@param parts string[]
function Input:set_toolbar(parts)
  self.toolbar = table.concat(parts, "  ")
  self:apply_winbar()
end

---Save the visible buffer into the current draft slot.
function Input:save_draft()
  self:sync_images()
  self:save_image_positions()
  if not self.session_key then
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local empty = #lines == 0 or (#lines == 1 and lines[1] == "")
  local draft = { text = empty and nil or table.concat(lines, "\n"), attachments = self.attachments }
  memory.bound_block(draft, self.config.memory.max_block_bytes)
  draft.used = vim.uv.hrtime()
  self.drafts[self.draft_slot or self.session_key] = draft
  local keys = vim.tbl_keys(self.drafts)
  if #keys > self.config.memory.max_drafts then
    table.sort(keys, function(a, b)
      return self.drafts[a].used < self.drafts[b].used
    end)
    for i = 1, #keys - self.config.memory.max_drafts do
      self.drafts[keys[i]] = nil
    end
  end
  if self.on_draft then
    self.on_draft(self.session_key, empty and "" or table.concat(lines, "\n"), self.attachments, self.draft_owner)
  end
end

---Switch drafts when the active session changes.
---@param key string|nil
---@param restored {text: string, attachments: table[]}|nil
function Input:switch_session(key, restored, owner)
  local slot = owner and (owner.cwd .. "\0" .. tostring(key)) or key
  if self.session_key == key and self.draft_slot == slot then
    return
  end
  self:save_draft()
  self.draft_epoch = self.draft_epoch + 1
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, anchor_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  end
  self.image_marks = {}
  self.session_key = key
  self.draft_slot = slot
  self.draft_owner = owner and { id = owner.id or key, cwd = owner.cwd } or nil
  -- Prefer the live draft: the persisted copy is trimmed for size, so using it
  -- while the full attachments are still in memory would send clipped text.
  local draft = (slot and self.drafts[slot]) or restored
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
  self:render_images()
end

---@return string
function Input:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  self:sync_images()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local starts, length = {}, 0
  for row, line in ipairs(lines) do
    starts[row] = length
    length = length + #line + 1
  end
  local raw = table.concat(lines, "\n")
  local parts, cursor, removed, order = {}, 0, 0, 0
  local marks = vim.api.nvim_buf_get_extmarks(self.buf, image_ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    for att, id in pairs(self.image_marks) do
      if id == mark[1] and self:token_matches(att, { mark[2], mark[3], mark[4] }) then
        local start = starts[mark[2] + 1] + mark[3]
        local finish = starts[mark[2] + 1] + mark[4].end_col
        parts[#parts + 1] = raw:sub(cursor + 1, start)
        order = order + 1
        att.prompt_offset = start - removed -- byte offset in the token-free text
        att.prompt_order = order -- adjacent images have the same text offset
        removed = removed + finish - start
        cursor = finish
      end
    end
  end
  parts[#parts + 1] = raw:sub(cursor + 1)
  return table.concat(parts)
end

function Input:clear()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "" })
  self.attachments = {}
  vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  self.image_marks = {}
  self.draft_epoch = self.draft_epoch + 1
  vim.api.nvim_buf_clear_namespace(self.buf, anchor_ns, 0, -1)
  self:render_images()
  if self.session_key then
    self.drafts[self.draft_slot or self.session_key] = nil
    if self.on_draft then
      self.on_draft(self.session_key, "", {}, self.draft_owner)
    end
  end
end

---Clear the originating draft without touching a newly selected composer.
function Input:discard_draft(owner)
  self.drafts[owner.cwd .. "\0" .. owner.id] = nil
  self.drafts[owner.id] = nil -- compatibility for callers without explicit owners
  if self.on_draft then
    self.on_draft(owner.id, "", {}, owner)
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
function Input:add_attachment(attachment, position)
  self:sync_images()
  if attachment.kind == "image" or attachment.kind == "selection" then
    attachment.input_position = position or self:cursor_position()
  end
  if attachment.kind == "selection" and not attachment.input_token then
    attachment.input_token = "[" .. (attachment.label or "selection") .. "]"
  end
  for i, existing in ipairs(self.attachments) do
    if existing.kind == attachment.kind and existing.path == attachment.path and existing.uri == attachment.uri then
      if existing.kind == "image" or existing.kind == "selection" then
        return false -- Keeping the existing token avoids an orphan.
      end
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
  local att = self.attachments[index]
  local id = att and self.image_marks[att]
  if id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, { details = true })
    self.image_marks[att] = nil
    vim.api.nvim_buf_del_extmark(self.buf, image_ns, id)
    if self:token_matches(att, mark) then
      vim.api.nvim_buf_set_text(self.buf, mark[1], mark[2], mark[3].end_row, mark[3].end_col, { "" })
    end
  end
  table.remove(self.attachments, index)
  self:refresh()
end

function Input:clear_attachments()
  for i = #self.attachments, 1, -1 do
    self:remove_attachment(i)
  end
  vim.api.nvim_buf_clear_namespace(self.buf, image_ns, 0, -1)
  self.image_marks = {}
  self.attachments = {}
  self:refresh()
end

function Input:refresh()
  self:render_images()
  if self.on_refresh then
    self.on_refresh()
  end
end

-- Highlighted buffer tokens are editable; only tracked tokens are stripped
-- from prompt text. Identical text typed by the user stays ordinary text.
function Input:cursor_position()
  if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf then
    local p = vim.api.nvim_win_get_cursor(self.win)
    return { p[1] - 1, p[2] }
  end
  return { 0, 0 }
end

function Input:image_anchor()
  local p = self:cursor_position()
  return vim.api.nvim_buf_set_extmark(self.buf, anchor_ns, p[1], p[2], {})
end

function Input:take_image_anchor(id)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local p = vim.api.nvim_buf_get_extmark_by_id(self.buf, anchor_ns, id, {})
  vim.api.nvim_buf_del_extmark(self.buf, anchor_ns, id)
  return #p == 2 and p or nil
end

function Input:save_image_positions()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  for attachment, id in pairs(self.image_marks) do
    local p = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, {})
    if #p == 2 then
      attachment.input_position = p
    end
  end
end

function Input:token_matches(att, mark)
  if not att.input_token or #mark == 0 then
    return false
  end
  local d = mark[3]
  if not d or d.invalid or d.end_row ~= mark[1] then
    return false
  end
  local text = vim.api.nvim_buf_get_text(self.buf, mark[1], mark[2], d.end_row, d.end_col, {})
  return table.concat(text, "\n") == att.input_token
end

function Input:sync_images()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local attachments, images = {}, {}
  for _, att in ipairs(self.attachments) do
    if (att.kind ~= "image" and att.kind ~= "selection") or not self.image_marks[att] then
      attachments[#attachments + 1] = att
    end
  end
  for att, id in pairs(self.image_marks) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(self.buf, image_ns, id, { details = true })
    if self:token_matches(att, mark) then
      images[#images + 1] = { att = att, id = id }
    end
  end
  table.sort(images, function(a, b)
    return a.id < b.id
  end)
  for _, entry in ipairs(images) do
    attachments[#attachments + 1] = entry.att
  end
  self.attachments = attachments
end

function Input:render_images()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self:save_image_positions()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local function coordinate(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge and math.max(0, math.floor(value))
      or 0
  end
  local image_index = 0
  for att in pairs(self.image_marks) do
    if att.kind == "image" then
      image_index = math.max(image_index, tonumber((att.input_token or ""):match("%d+")) or 0)
    end
  end
  for _, att in ipairs(self.attachments) do
    if (att.kind == "image" or att.kind == "selection") and not self.image_marks[att] then
      local p = type(att.input_position) == "table" and att.input_position or {}
      local row = math.min(coordinate(p[1]), #lines - 1)
      local col = math.min(coordinate(p[2]), #lines[row + 1])
      while
        col > 0
        and col < #lines[row + 1]
        and lines[row + 1]:byte(col + 1) >= 128
        and lines[row + 1]:byte(col + 1) < 192
      do
        col = col - 1 -- clamp restored positions to a UTF-8 boundary
      end
      if att.kind == "image" then
        image_index = image_index + 1
      end
      local label = att.input_token or string.format("[Image %d]", image_index)
      local current = vim.api.nvim_buf_get_text(self.buf, row, col, row, math.min(col + #label, #lines[row + 1]), {})[1]
      if not att.input_token or current ~= label then
        vim.api.nvim_buf_set_text(self.buf, row, col, row, col, { label })
        if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_get_current_win() == self.win then
          local cursor = vim.api.nvim_win_get_cursor(self.win)
          if cursor[1] == row + 1 and cursor[2] == col then
            vim.api.nvim_win_set_cursor(self.win, { row + 1, col + #label })
          end
        end
        lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
      end
      att.input_token = label
      self.image_marks[att] = vim.api.nvim_buf_set_extmark(self.buf, image_ns, row, col, {
        end_row = row,
        end_col = col + #label,
        hl_group = "AcpInputImage",
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
      })
    end
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
