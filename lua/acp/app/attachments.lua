-- Attachments and location actions: images, files, selections, diagnostics.
--
-- These are the composer-facing "add something to the prompt" commands plus
-- "open the file under the cursor". They used to live in the controller; they
-- only need the shared state, the config and a couple of callbacks, so they are
-- a module now.
local context = require("acp.context")
local drafts = require("acp.storage.drafts")
local layout = require("acp.layout")
local log = require("acp.log")

local M = {}

---@param deps {state: fun(): table, config: fun(): table, notify: fun(message: string, level: integer|nil),
---  refresh_chrome: fun(), focus: fun(which: string)}
---@return table
function M.new(deps)
  local self = { deps = deps }
  setmetatable(self, { __index = M })
  self:reset()
  return self
end

function M:reset()
  -- Attachments captured before the composer existed; `flush` moves them in.
  self.pending = nil
end

function M:state()
  return self.deps.state()
end

function M:cfg()
  return self.deps.config()
end

function M:notify(message, level)
  return self.deps.notify(message, level)
end

---Drop expired clipboard images. Runs when the composer gains an image, so the
---cache is cleaned at the moment it is being used rather than on a timer.
function M:prune_image_cache()
  local images = self:cfg().context.images
  local protected = drafts.image_paths()
  local seen = {}
  local function collect(value)
    if type(value) ~= "table" or seen[value] then
      return
    end
    seen[value] = true
    if value.kind == "image" and value.path then
      protected[value.path] = true
    end
    for _, child in pairs(value) do
      if type(child) == "table" then
        collect(child)
      end
    end
  end
  local S = self:state()
  local input = S.view.input
  if input then
    collect(input.attachments)
    collect(input.drafts)
    for att in pairs(input.image_marks) do
      collect(att)
    end -- undoable deletions
  end
  for _, session in pairs(S.sess.all) do
    collect(session.queue)
    collect(session.blocks)
  end
  local ok, removed = pcall(require("acp.context.image").prune, images.ttl_hours, images.max_cache_bytes, protected)
  if ok and removed and removed > 0 then
    log.debug("pruned %d cached image(s)", removed)
  end
end

---Add an already-built image attachment, enforcing the shared limits.
---@param attachment table
---@param position table|nil
---@return boolean
function M:add_image_attachment(attachment, position)
  local images = self:cfg().context.images
  local S = self:state()
  if images.enabled == false then
    self:notify("Image attachments are disabled (context.images.enabled)", vim.log.levels.WARN)
    return false
  end
  if not S.view.input then
    self:notify("Open the ACP composer before attaching an image", vim.log.levels.WARN)
    return false
  end
  if not S.sess.current then
    self:notify("No active session", vim.log.levels.WARN)
    return false
  end
  local count = 0
  S.view.input:sync_images()
  local duplicate = false
  for _, att in ipairs(S.view.input.attachments) do
    if att.kind == "image" then
      count = count + 1
      if att.path == attachment.path and att.uri == attachment.uri then
        duplicate = true
      end
    end
  end
  if not duplicate and count >= images.max_per_message then
    self:notify(string.format("At most %d images per message", images.max_per_message), vim.log.levels.WARN)
    return false
  end
  S.view.input:add_attachment(attachment, position)
  self.deps.refresh_chrome()
  self:prune_image_cache()
  self:notify(string.format("image: %s (%.1f KB)", attachment.label, attachment.bytes / 1024), vim.log.levels.INFO)
  return true
end

---Attach an image file to the composer.
---@param path string
---@return boolean
function M:add_image(path)
  local attachment, err = context.image(path, self:cfg())
  if not attachment then
    self:notify(err or "unable to attach image", vim.log.levels.WARN)
    return false
  end
  return self:add_image_attachment(attachment)
end

---Read an image from the system clipboard and attach it.
---
---The terminal only forwards image bytes to full-screen TUIs that own the
---clipboard, so this runs a platform helper in the background and never blocks
---the editor while the user waits.
---@param opts {command?: string[]|false}|nil
---@return boolean started
function M:paste_image(opts)
  local images = self:cfg().context.images
  if images.enabled == false then
    self:notify("Image attachments are disabled (context.images.enabled)", vim.log.levels.WARN)
    return false
  end
  local S = self:state()
  if not S.sess.current or not S.view.input then
    self:notify("Open the ACP composer before pasting an image", vim.log.levels.WARN)
    return false
  end
  local command = (opts and opts.command) or (images.clipboard ~= false and images.clipboard or nil)
  if type(command) == "string" then
    -- "auto" selects the platform chain; a user-supplied argv is passed on.
    command = nil
  end
  if not command and images.clipboard == false then
    self:notify("Clipboard image reading is disabled (context.images.clipboard)", vim.log.levels.WARN)
    return false
  end
  local session = S.sess.current
  -- Record where the user was before the asynchronous read. Attaching must not
  -- move the cursor, edit the buffer or yank focus out of another window: the
  -- chip is extra state, not text.
  local input, config = S.view.input, self:cfg()
  local epoch = input.draft_epoch
  local anchor = input:image_anchor()
  local self_ = self
  self:notify("Reading image from clipboard…", vim.log.levels.INFO)
  require("acp.context.clipboard").read({
    command = command,
    max_bytes = images.max_bytes,
  }, function(bytes, mime, err)
    local position = input:take_image_anchor(anchor)
    -- The selection may have changed while the helper was running.
    local current = self_:state()
    if
      current.sess.current ~= session
      or current.view.input ~= input
      or self_:cfg() ~= config
      or input.draft_epoch ~= epoch
      or not position
    then
      return
    end
    if not bytes then
      if err then
        self_:notify(err, vim.log.levels.WARN)
      else
        self_:notify("Clipboard does not contain an image", vim.log.levels.INFO)
      end
      return
    end
    local attachment, store_err = context.image_bytes(bytes, mime, self_:cfg())
    if not attachment then
      self_:notify(store_err or "unable to attach image", vim.log.levels.WARN)
      return
    end
    -- The attachment is already built from bytes we just read; adding it by
    -- path would read the file a second time for nothing.
    self_:add_image_attachment(attachment, position)
  end)
  return true
end

---Attach a file, defaulting to the current buffer.
---@param path string|nil
function M:add_file(path)
  local S = self:state()
  if not S.sess.current then
    self:notify("No active session", vim.log.levels.WARN)
    return
  end
  local target = path
  if not target or target == "" then
    target = vim.api.nvim_buf_get_name(0)
    if target == "" then
      self:notify("current buffer has no file", vim.log.levels.WARN)
      return
    end
  end
  local attachment, err = context.file(target, self:cfg())
  if not attachment then
    self:notify(err or "unable to attach file", vim.log.levels.WARN)
    return
  end
  S.view.input:add_attachment(attachment)
  self.deps.refresh_chrome()
  self:notify("file" .. ": " .. attachment.label, vim.log.levels.INFO)
end

---Attach the last editor selection, or its current line when nothing is marked.
function M:add_selection()
  local S = self:state()
  -- The composer has focus, so the selection lives in the last real editor
  -- window. With no visual marks, take its current line instead.
  local source = layout.saved_focus()
  local bufnr = source and vim.api.nvim_win_is_valid(source) and vim.api.nvim_win_get_buf(source) or nil
  local line = source and vim.api.nvim_win_is_valid(source) and vim.api.nvim_win_get_cursor(source)[1] or nil
  -- Whether the selection is embedded is decided when the message is sent: the
  -- agent's `embeddedContext` capability is only authoritative then, and a
  -- draft can outlive a reconnect or an agent switch.
  local attachment, err = context.selection(self:cfg(), {
    bufnr = bufnr,
    line = line,
    include_current_line = true,
  })
  if not attachment then
    self:notify(err or "unable to attach selection", vim.log.levels.WARN)
    return
  end
  if not S.view.input then
    self.pending = self.pending or {}
    self.pending[#self.pending + 1] = attachment
    return
  end
  S.view.input:add_attachment(attachment)
  self.deps.refresh_chrome()
  self:notify("selection" .. ": " .. attachment.label, vim.log.levels.INFO)
  self.deps.focus("input")
end

---Move selections captured before the composer existed into it.
---@param input table
function M:flush(input)
  for _, selection in ipairs(self.pending or {}) do
    input:add_attachment(selection)
  end
  self.pending = nil
end

function M:add_diagnostics()
  local attachment, err = context.diagnostics(self:cfg())
  if not attachment then
    self:notify(err or "unable to attach diagnostics", vim.log.levels.WARN)
    return
  end
  self:state().view.input:add_attachment(attachment)
  self.deps.refresh_chrome()
end

---Pick a file for `@file` completion.
function M:pick_file(opts)
  local S = self:state()
  if S.view.input and S.view.input:is_visible() then
    return require("acp.completion.picker").open(S.view.input.buf, S.view.input.win, opts)
  end
  self:notify("Open the ACP composer before choosing a file", vim.log.levels.WARN)
end

---Open the file location on the current transcript line.
function M:open_location()
  local S = self:state()
  -- A card waiting for an answer opens its request instead of a file.
  local block = S.view.chat and S.view.chat:block_at_cursor()
  if block and block.awaiting and block.interaction_id then
    S.view.interactions:show(block.interaction_id)
    return
  end
  local loc = S.view.chat and S.view.chat:location_at_cursor()
  if not loc or not loc.path then
    -- Fall back to the block's first location.
    if block and block.locations and #block.locations > 0 then
      loc = block.locations[1]
    end
  end
  if not loc or not loc.path then
    self:notify("No file location under cursor", vim.log.levels.INFO)
    return
  end
  local path = loc.path
  if vim.fn.filereadable(path) ~= 1 then
    self:notify("file does not exist: " .. path, vim.log.levels.WARN)
    return
  end
  -- Reuse the last non-ACP window so the panel keeps its layout.
  local target = layout.saved_focus()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd("wincmd p")
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  if loc.line then
    pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
    vim.cmd("normal! zz")
  end
end

return M
