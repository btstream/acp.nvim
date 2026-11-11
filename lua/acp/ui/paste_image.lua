-- Turn pasted image paths into attachments.
--
-- A terminal can only forward text when the user drops a file or pastes a path,
-- so this is the one paste path that carries something a screenshot cannot:
-- the image file itself. Everything that is not a single existing image path is
-- handed straight back to Neovim's own handler.
local M = {}

local image = require("acp.context.image")

---Bracketed-paste content arrives as one string may be wrapped in the paste
---markers by callers that synthesise it; strip them before inspecting.
---@param lines string[]
---@return string
local function join(lines)
  local text = table.concat(lines, "\n")
  text = text:gsub("^\27%[200~", ""):gsub("\27%[201~$", "")
  return text
end

---Normalise a pasted location into a filesystem path.
---
---Terminals and file managers send `file://` URIs, quoted paths, and Windows
---paths with escapes. Only the shapes that can name a local file are accepted.
---@param text string
---@return string|nil
function M.path_of(text)
  local value = vim.trim(text):gsub("^['\"]", ""):gsub("['\"]$", "")
  if value == "" or value:find("\n", 1, true) then
    return nil
  end
  if value:find("^file://") then
    local ok, decoded = pcall(vim.uri_to_fname, value)
    if not ok then
      return nil
    end
    value = decoded
  elseif value:find("^https?://") then
    -- A web URL is text the user wanted to paste, not a local image.
    return nil
  end
  -- Unescape the backslash form some terminals use for spaces in paths.
  if not value:match("^%a:[/\\]") and vim.fn.filereadable(value) ~= 1 then
    value = value:gsub("\\ ", " ")
  end
  if value:sub(1, 1) ~= "/" and not value:match("^%a:[/\\]") and not value:match("^~") then
    return nil
  end
  return vim.fn.fnamemodify(value, ":p")
end

---Whether `path` is a supported image file within the size budget.
---@param path string
---@param limit integer
---@return boolean
function M.is_image(path, limit)
  return image.is_file(path, limit)
end

---Install the handler for one composer buffer.
---
---The override is process-wide because `vim.paste` is, but it delegates unless
---the cursor is in `buf` and the pasted text is exactly one image path.
---@param buf integer
---@param opts {config: fun(): table, on_image: fun(path: string): boolean, is_active: fun(): boolean}
function M.attach(buf, opts)
  if M.installed then
    M.followers[buf] = opts
    return
  end
  M.followers = { [buf] = opts }
  local followers = M.followers -- This installation's owners, even if wrapped by another plugin.
  M.installed = true
  local original = vim.paste
  M.original = original

  M.paste = function(lines, phase)
    -- Neovim may stream a large paste across several phases. Only the final
    -- phase carries the whole text, so everything else is forwarded untouched.
    local owner = followers[vim.api.nvim_get_current_buf()]
    if not owner or not owner.is_active() then
      return original(lines, phase)
    end
    -- A single-line clipboard path arrives as one complete paste; a streaming
    -- phase or a multi-line paste is ordinary text and must be inserted as-is.
    if phase ~= -1 or #lines ~= 1 then
      return original(lines, phase)
    end
    local text = join(lines)
    local path = M.path_of(text)
    if not path then
      return original(lines, phase)
    end
    local images = owner.config().context.images
    if images.enabled == false or not M.is_image(path, images.max_bytes) then
      return original(lines, phase)
    end
    if not owner.on_image(path) then
      return original(lines, phase)
    end
    return true
  end
  vim.paste = M.paste
end

---Stop handling pastes for `buf`.
---@param buf integer
function M.detach(buf)
  if M.followers then
    M.followers[buf] = nil
  end
  if M.installed and next(M.followers or {}) == nil then
    M.installed = false
    M.followers = nil
    -- Only restore our own wrapper: another plugin may have wrapped `vim.paste`
    -- after us, and clobbering it would silently disable that handler.
    if M.original and vim.paste == M.paste then
      vim.paste = M.original
    end
  end
end

return M
