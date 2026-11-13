-- Collect editor context into ACP prompt content blocks.
local log = require("acp.log")
local image = require("acp.context.image")

local M = {}

---@param path string
---@return string
local function to_uri(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  -- Encode characters that are invalid in a file URI path segment.
  local encoded = abs:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return "file://" .. encoded
end

M.to_uri = to_uri

---@param bufnr integer
---@return string|nil
local function buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function read_file(path, max_bytes)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text
  if max_bytes then
    -- Read at most one byte more than the limit so an oversized file can be
    -- detected without loading all of it.
    text = fh:read(max_bytes + 1)
  else
    text = fh:read("*a")
  end
  fh:close()
  if text and max_bytes and #text > max_bytes then
    return nil, "too_large"
  end
  return text
end

---Build an attachment for a file path.
---@param path string
---@param config table
---@return table|nil attachment
---@return string|nil err
function M.file(path, config)
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "not a readable file: " .. path
  end
  -- An image is not text: `read_file` would hand the agent raw bytes labelled
  -- text/plain. Describe it as an image instead.
  local images = config.context and config.context.images or {}
  if images.enabled ~= false and image.is_file(abs, images.max_bytes) then
    return M.image(abs, config)
  end
  local limit = config.context.max_file_bytes or 512 * 1024
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.size > limit then
    return nil, "file is too large to attach"
  end

  local bufnr = vim.fn.bufnr(abs)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
    -- Prefer the unsaved buffer contents so the agent sees what the user sees.
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    -- An unsaved buffer can be arbitrarily large; the disk size check above
    -- does not apply to it. Oversized attachments would exceed
    -- `transport.max_line_bytes` and kill the agent connection.
    if #text > limit then
      return nil, "buffer is too large to attach"
    end
    -- `block` is built at send time: whether the text can be embedded depends
    -- on the agent's `embeddedContext`, which is only known then.
    return {
      kind = "file",
      label = vim.fn.fnamemodify(abs, ":t"),
      path = abs,
      uri = to_uri(abs),
      text = text,
      unsaved = true,
    }
  end

  -- Bound the read so a file that grew after `fs_stat` (TOCTOU) still cannot
  -- blow past the limit.
  local text, err = read_file(abs, limit)
  if not text then
    if err == "too_large" then
      return nil, "file is too large to attach"
    end
    return nil, "unable to read file: " .. path
  end
  return {
    kind = "file",
    label = vim.fn.fnamemodify(abs, ":t"),
    path = abs,
    uri = to_uri(abs),
  }
end

---Build an attachment for the last visual selection.
---
---With `include_current_line` and no selection the cursor's line is used
---instead. The block itself is built at send time by `M.block`, because only
---then is it known whether the agent accepts an embedded resource.
---@param config table
---@param opts {bufnr?: integer, include_current_line?: boolean}|nil
---@return table|nil attachment
---@return string|nil err
function M.selection(config, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = buffer_path(bufnr)
  if not path then
    return nil, "current buffer has no file"
  end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, start_col = start_pos[2], start_pos[3]
  local end_line, end_col = end_pos[2], end_pos[3]
  if start_line == 0 or end_line == 0 then
    if not opts.include_current_line then
      return nil, "no visual selection"
    end
    local line = opts.line
    if not line and vim.api.nvim_get_current_buf() == bufnr then
      line = vim.api.nvim_win_get_cursor(0)[1]
    end
    if not line then
      return nil, "no visual selection"
    end
    start_line, end_line = line, line
    start_col, end_col = 1, #(vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or "")
  end
  if start_line > end_line then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil, "empty selection"
  end
  if #lines > (config.context.max_selection_lines or 2000) then
    return nil, "selection is too large to attach"
  end
  lines[1] = lines[1]:sub(start_col)
  lines[#lines] = lines[#lines]:sub(1, end_col)
  local text = table.concat(lines, "\n")
  -- Line count alone does not bound the payload: a few very long lines can
  -- still exceed the transport limit and kill the connection.
  local limit = config.context.max_file_bytes or 512 * 1024
  if #text > limit then
    return nil, "selection is too large to attach"
  end
  local fragment = string.format("#L%d:%d", start_line, end_line)
  local uri = to_uri(path) .. fragment
  local label = string.format("%s:%d-%d", vim.fn.fnamemodify(path, ":t"), start_line, end_line)
  -- `block` is left to `M.block` at send time: an embedded resource is only
  -- valid if the agent advertised `embeddedContext`, and a link alone loses the
  -- selection text on agents that cannot read the file themselves.
  return {
    kind = "selection",
    label = label,
    path = path,
    uri = uri,
    text = text,
    mime = "text/plain",
    range = { start_line = start_line, end_line = end_line },
  }
end

---Build an attachment for the current diagnostic line.
---@param config table
---@return table|nil attachment
function M.diagnostics(config)
  local bufnr = vim.api.nvim_get_current_buf()
  local path = buffer_path(bufnr)
  if not path then
    return nil, "current buffer has no file"
  end
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return nil, "no diagnostics in this buffer"
  end
  local lines = {}
  local limit = config.context.max_file_bytes or 512 * 1024
  local bytes = 0
  local total = 0
  for _, diag in ipairs(diagnostics) do
    local line = string.format(
      "%s:%d:%d %s %s",
      path,
      diag.lnum + 1,
      diag.col + 1,
      ({ "ERROR", "WARN", "INFO", "HINT" })[diag.severity] or "INFO",
      diag.message
    )
    bytes = bytes + #line + 1
    if bytes > limit then
      -- Truncate instead of dropping everything: the first diagnostics are
      -- usually the ones that matter, and an unbounded list would exceed the
      -- transport limit.
      lines[#lines + 1] = string.format("... (%d more diagnostics omitted)", #diagnostics - total)
      break
    end
    lines[#lines + 1] = line
    total = total + 1
  end
  local text = table.concat(lines, "\n")
  return {
    kind = "diagnostics",
    label = string.format("diagnostics (%d)", total),
    path = path,
    text = text,
    block = {
      type = "text",
      text = "Diagnostics:\n" .. text,
      annotations = { audience = { "assistant" } },
    },
  }
end

---Build an attachment for an image file.
---
---The bytes stay on disk; only metadata enters the composer. `inline` decides
---whether the prompt embeds them now or links the file, which is what keeps a
---screenshot from silently tripling every later queue entry.
---@param path string
---@param config table
---@param opts {inline?: boolean}|nil
---@return table|nil attachment
---@return string|nil err
function M.image(path, config, opts)
  local images = config.context.images or {}
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "not a readable image: " .. path
  end
  local limit = images.max_bytes or 3 * 1024 * 1024
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.size > limit then
    return nil, "image is too large to attach"
  end
  local bytes, read_err = image.read(abs, limit)
  if not bytes then
    return nil, read_err or "unable to read image"
  end
  local mime = image.sniff(bytes)
  if not mime then
    return nil, "not a supported image: " .. path
  end
  local name = vim.fn.fnamemodify(abs, ":t")
  local inline = opts and opts.inline
  if inline == nil then
    inline = images.path_mode == "inline"
  end
  -- `block` is deliberately left nil: `M.block` builds it at send time so the
  -- bytes are read once, when they are actually needed.
  return {
    kind = "image",
    label = name,
    path = abs,
    uri = to_uri(abs),
    mime = mime,
    bytes = #bytes,
    sha = vim.fn.sha256(bytes),
    inline = inline,
  }
end

---Attach raw image bytes that came from the clipboard.
---@param bytes string
---@param mime string
---@param config table
---@return table|nil attachment
---@return string|nil err
function M.image_bytes(bytes, mime, config)
  local images = config.context.images
  if images.enabled == false then
    return nil, "image attachments are disabled"
  end
  if #bytes > images.max_bytes then
    return nil, "image is too large to attach"
  end
  if not image.extension(mime) or image.sniff(bytes) ~= mime then
    return nil, "unsupported image format or mismatched MIME type"
  end
  local path, err = image.store(bytes, mime)
  if not path then
    return nil, err
  end
  return M.image(path, config, { inline = true })
end

---Extract `@path` mentions from a message and turn readable files into attachments.
---Image paths use the image attachment so their MIME type and (optionally)
---their bytes reach the agent as an image rather than as text.
---The mention text is left in the message so the agent keeps the reference.
---@param text string
---@param config table
---@param cwd string|nil
---@return table[] attachments
function M.mentions(text, config, cwd)
  local attachments = {}
  local seen = {}
  for _, token in ipairs(require("acp.completion.mentions").tokens(text)) do
    local path = token.path
    if not seen[path] then
      local absolute = path
      if path:sub(1, 1) ~= "/" and cwd then
        absolute = cwd .. "/" .. path
      end
      absolute = vim.fn.fnamemodify(absolute, ":p")
      if not seen[absolute] and vim.fn.filereadable(absolute) == 1 then
        local attachment = M.file(absolute, config)
        if attachment then
          seen[absolute] = true
          attachments[#attachments + 1] = attachment
        end
      end
    end
  end
  return attachments
end

---Build the prompt block for an attachment.
---
---Image bytes are read here rather than at attach time: the composer, the
---draft file and the local queue only ever hold the path, so a 3 MiB
---screenshot does not become 4 MiB of base64 in three places.
---
---Text attachments (an unsaved buffer, a Visual selection) also resolve here.
---Their text can only be sent as an embedded `resource` when the agent
---advertised `promptCapabilities.embeddedContext`; otherwise they go out as a
---`resource_link` plus a text block carrying the same bytes, so the agent still
---sees what the user sees instead of having to read a file that may not match.
---@param att table
---@param config table|nil
---@param opts {supports?: fun(name: string): boolean}|nil capability probe
---@return table|table[]|nil block one block, or several to insert in order
---@return string|nil err
function M.block(att, config, opts)
  local supports = opts and opts.supports or nil
  -- Embedding a `resource` is only valid when the agent advertised
  -- `embeddedContext`. An unknown capability takes the universally safe form:
  -- a link (baseline) plus the text itself.
  local function embeds()
    return supports ~= nil and supports("embeddedContext")
  end

  if att.block then
    return att.block
  end

  if att.kind == "selection" or (att.kind == "file" and att.text) then
    -- The text travels with the message either way; only the envelope changes.
    if embeds() then
      return {
        type = "resource",
        resource = { uri = att.uri, mimeType = att.mime or "text/plain", text = att.text },
        annotations = { audience = { "assistant" } },
      }
    end
    return {
      {
        type = "resource_link",
        uri = att.uri,
        name = att.label,
        mimeType = att.mime or "text/plain",
        size = #att.text,
      },
      { type = "text", text = att.text },
    }
  end

  if att.kind == "file" then
    local name = att.label or vim.fn.fnamemodify(att.path or "", ":t")
    return { type = "resource_link", uri = att.uri, name = name }
  end

  if att.kind ~= "image" then
    return att.block
  end

  local images = (config and config.context and config.context.images) or {}
  -- `att.inline` is an explicit decision made when the attachment was created:
  -- clipboard bytes must be embedded (the agent cannot read our cache), while
  -- a mentioned file follows `path_mode`.
  local inline = att.inline
  if inline == nil then
    inline = (images.path_mode or "link") == "inline"
  end
  if not inline then
    return { type = "resource_link", uri = att.uri, name = att.label, mimeType = att.mime, size = att.bytes }
  end
  if not att.path or vim.fn.filereadable(att.path) ~= 1 then
    -- The cache was pruned between composing and sending; say so instead of
    -- dropping the image silently.
    return nil, (att.label or "image") .. " is no longer readable"
  end
  local limit = images.max_bytes or 3 * 1024 * 1024
  local bytes, err = image.read(att.path, limit)
  if not bytes then
    return nil, err or ("image is no longer readable: " .. tostring(att.label))
  end
  -- The bytes are checked again here: the file may have been replaced between
  -- attaching and sending, and the agent would reject a stale MIME type.
  local mime = image.sniff(bytes)
  if not mime then
    return nil, "not a supported image: " .. tostring(att.label)
  end
  return { type = "image", mimeType = mime, uri = att.uri, data = vim.base64.encode(bytes) }
end

---Order text and positioned image attachments without reading image bytes.
---Offsets refer to UTF-8 bytes in the token-free text, never character counts.
---Unpositioned attachments retain the legacy append-at-end behaviour.
function M.sequence(text, attachments)
  text = text or ""
  local positioned, tail = {}, {}
  for index, att in ipairs(attachments or {}) do
    local offset = att.prompt_offset
    local valid = type(offset) == "number" and offset >= 0 and offset <= #text and offset % 1 == 0
    local next_byte = valid and offset < #text and text:byte(offset + 1) or nil
    if
      (att.kind == "image" or att.kind == "selection")
      and valid
      and (not next_byte or next_byte < 128 or next_byte >= 192)
    then
      positioned[#positioned + 1] = { attachment = att, offset = offset, index = index }
    else
      tail[#tail + 1] = { attachment = att }
    end
  end
  table.sort(positioned, function(a, b)
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    local ao = type(a.attachment.prompt_order) == "number" and a.attachment.prompt_order or a.index
    local bo = type(b.attachment.prompt_order) == "number" and b.attachment.prompt_order or b.index
    if ao ~= bo then
      return ao < bo
    end
    return a.index < b.index
  end)
  local parts, cursor = {}, 0
  for _, entry in ipairs(positioned) do
    if entry.offset > cursor then
      parts[#parts + 1] = { text = text:sub(cursor + 1, entry.offset) }
    end
    parts[#parts + 1] = { attachment = entry.attachment, positioned = true }
    cursor = entry.offset
  end
  if cursor < #text then
    parts[#parts + 1] = { text = text:sub(cursor + 1) }
  end
  vim.list_extend(parts, tail)
  return parts
end

---Reconstruct the composer's visible image positions for the local transcript.
function M.display_text(text, attachments)
  local parts, placed = {}, {}
  for _, part in ipairs(M.sequence(text, attachments)) do
    if part.text then
      parts[#parts + 1] = part.text
    elseif part.positioned then
      local att = part.attachment
      parts[#parts + 1] = att.input_token or "[Image]"
      placed[att] = true
    end
  end
  return table.concat(parts), placed
end

---Convert attachments plus a text message into ordered ACP content blocks.
---
---`opts.supports` reports what the agent accepts. When it says images are
---unsupported, an image attachment becomes a `resource_link` instead of an
---`image` block, so the rest of the message is still delivered.
---@param text string
---@param attachments table[]
---@param config table|nil
---@param opts {supports?: fun(name: string): boolean}|nil capability probe
---@return table[] blocks
---@return string|nil problem first attachment that could not be encoded
function M.to_prompt(text, attachments, config, opts)
  local supports = opts and opts.supports or nil
  local blocks = {}
  local problem
  for _, part in ipairs(M.sequence(text, attachments)) do
    if part.text then
      blocks[#blocks + 1] = { type = "text", text = part.text }
    else
      local att = part.attachment
      local unsupported_image = att.kind == "image" and supports ~= nil and not supports("image")
      if unsupported_image and att.uri then
        -- An agent without `promptCapabilities.image` rejects an `image` block
        -- outright. Degrade to a link before reading the bytes: encoding a 3 MiB
        -- screenshot only to throw it away would be pure waste.
        blocks[#blocks + 1] = {
          type = "resource_link",
          uri = att.uri,
          name = att.label,
          mimeType = att.mime,
          size = att.bytes,
        }
      else
        local block, err = M.block(att, config, { supports = supports })
        if block then
          -- `block` may be several blocks: a text attachment that cannot be
          -- embedded goes out as a link plus the text itself.
          for _, one in ipairs(block.type and { block } or block) do
            blocks[#blocks + 1] = one
          end
        elseif err and not problem then
          problem = err
        end
      end
    end
  end
  return blocks, problem
end

return M
