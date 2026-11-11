-- Platform clipboard image reader.
--
-- The terminal never hands image bytes to Neovim: bracket-paste mode only
-- carries text. OSC 5522 needs terminal-specific negotiation and changes the
-- editor's paste handling, so this implementation deliberately does not use it. The
-- composer reads the clipboard itself, exactly like the terminal UIs do.
--
-- Results are three-state on purpose:
--   bytes ~= nil                  an image was read
--   bytes == nil, err == nil      the clipboard is reachable but holds no image
--   bytes == nil, err ~= nil      this backend is unavailable or failed
-- Falling through on "no image" would resurrect a stale X11 selection when the
-- Wayland clipboard is merely empty.
local M = {}

local TIMEOUT = 2000
local MAX_BYTES = 16 * 1024 * 1024

local image = require("acp.context.image")

---Preferred order of image MIME types, most specific first.
M.PREFERRED = { "image/png", "image/jpeg", "image/webp", "image/gif" }

---@param name string
---@return boolean
local function has(name)
  return vim.fn.executable(name) == 1
end

---Backends in preference order for the current environment.
---`types` lists the advertised formats; `read` returns the argv that streams
---one format to stdout.
---@return {name: string, types: string[], read: fun(mime: string): string[]}[]
function M.backends()
  local out = {}
  local env = vim.env
  if (env.WAYLAND_DISPLAY or "") ~= "" and has("wl-paste") then
    out[#out + 1] = {
      name = "wl-paste",
      types = { "wl-paste", "--list-types" },
      read = function(mime)
        return { "wl-paste", "--type", mime, "--no-newline" }
      end,
    }
  end
  if (env.DISPLAY or "") ~= "" then
    if has("xclip") then
      out[#out + 1] = {
        name = "xclip",
        types = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
        read = function(mime)
          return { "xclip", "-selection", "clipboard", "-t", mime, "-o" }
        end,
      }
    end
  end
  if has("pngpaste") then
    out[#out + 1] = {
      name = "pngpaste",
      types = {},
      read = function()
        return { "pngpaste", "-" }
      end,
    }
  end
  if has("powershell.exe") then
    out[#out + 1] = {
      name = "powershell.exe",
      types = {},
      -- Windows hands back a device-independent bitmap, not a PNG; the script
      -- re-encodes it so the bytes match the MIME type we advertise.
      read = function()
        return {
          "powershell.exe",
          "-NoProfile",
          "-Command",
          table.concat({
            "Add-Type -AssemblyName System.Windows.Forms",
            "Add-Type -AssemblyName System.Drawing",
            "$img = [System.Windows.Forms.Clipboard]::GetImage()",
            "if ($img) { $ms = New-Object System.IO.MemoryStream",
            "$img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)",
            "[Console]::OpenStandardOutput().Write($ms.ToArray(), 0, $ms.Length) }",
          }, "; "),
        }
      end,
    }
  end
  return out
end

---The backend that would be used, for diagnostics.
---@return string|nil
function M.tool()
  local backend = M.backends()[1]
  return backend and backend.name or nil
end

---Run one command asynchronously and collect raw stdout.
---`cwd` is the filesystem root and stdin is closed: clipboard tools sometimes
---daemonize, and they must not keep the project directory or our input pipe.
---@param argv string[]
---@param callback fun(ok: boolean, stdout: string, stderr: string)
local function run(argv, callback, limit)
  local chunks, size, overflow = {}, 0, false
  local errors, error_size = {}, 0
  limit = limit or MAX_BYTES
  local proc
  local function stop()
    if proc then
      pcall(proc.kill, proc, 9)
    end
  end
  local ok, result_proc = pcall(vim.system, argv, {
    cwd = "/",
    stdin = false,
    detach = false,
    text = false,
    timeout = TIMEOUT,
    stderr = function(_, data)
      if data and error_size < 4096 then
        local part = data:sub(1, 4096 - error_size)
        errors[#errors + 1] = part
        error_size = error_size + #part
      end
    end,
    stdout = function(_, data)
      if data and not overflow then
        size = size + #data
        if size > limit then
          overflow = true
          chunks = {}
          stop()
          return
        end
        chunks[#chunks + 1] = data
      end
    end,
  }, function(result)
    local stdout = table.concat(chunks)
    vim.schedule(function()
      callback(
        not overflow and result.code == 0,
        stdout,
        overflow and "clipboard output exceeds context.images.max_bytes" or table.concat(errors)
      )
    end)
  end)
  if not ok then
    -- vim.system throws when the executable is missing.
    vim.schedule(function()
      callback(false, "", tostring(result_proc))
    end)
    return
  end
  proc = result_proc
  if overflow then
    stop()
  end
  return proc
end

---Pick the best advertised image type.
---@param text string newline-separated MIME list
---@return string|nil
function M.pick(text)
  local seen = {}
  for line in text:gmatch("[^\r\n]+") do
    local base = vim.trim(line):lower():gsub(";.*$", "")
    seen[base] = true
  end
  for _, mime in ipairs(M.PREFERRED) do
    if seen[mime] then
      return mime
    end
  end
  for base in pairs(seen) do
    if base:sub(1, 6) == "image/" then
      return base
    end
  end
  return nil
end

---Validate size and container before returning bytes to the caller.
---@param bytes string
---@param expected string|nil
---@param limit integer|nil
---@return string|nil mime
---@return string|nil err
local function accept(bytes, expected, limit)
  if bytes == "" then
    return nil, nil
  end
  if limit and #bytes > limit then
    return nil, "clipboard image exceeds context.images.max_bytes"
  end
  local mime = image.sniff(bytes)
  if not mime then
    return nil, "clipboard does not contain a supported image"
  end
  if expected and expected ~= mime and not (expected == "image/jpg" and mime == "image/jpeg") then
    -- A tool that advertises image/png but streams something else would make
    -- the agent reject the block after the user already pressed send.
    return nil, "clipboard reported " .. expected .. " but the data is " .. mime
  end
  return mime
end

---Read an image from the clipboard.
---
---`opts.command` replaces the platform chain with one argv whose stdout is the
---image, which is also how a user plugs in an existing screenshot helper.
---@param opts {command?: string[]|false, max_bytes?: integer}
---@param callback fun(bytes: string|nil, mime: string|nil, err: string|nil)
function M.read(opts, callback)
  opts = opts or {}
  local limit = opts.max_bytes or MAX_BYTES
  local function finish(bytes, mime, err)
    vim.schedule(function()
      callback(bytes, mime, err)
    end)
  end

  if opts.command and opts.command ~= false then
    run(opts.command, function(ok, stdout, stderr)
      if not ok then
        finish(nil, nil, "clipboard command failed: " .. vim.trim(stderr):sub(1, 200))
        return
      end
      local mime, err = accept(stdout, nil, limit)
      if err then
        finish(nil, nil, err)
        return
      end
      finish(mime and stdout or nil, mime, nil)
    end, limit)
    return
  end

  local backends = M.backends()
  if #backends == 0 then
    finish(nil, nil, "no clipboard tool found; install wl-clipboard, xclip or pngpaste")
    return
  end

  local index = 1
  local last_error

  local function attempt()
    local backend = backends[index]
    if not backend then
      finish(nil, nil, last_error or "no clipboard tool could read an image")
      return
    end
    index = index + 1

    local function read_mime(mime)
      run(backend.read(mime), function(ok, stdout, stderr)
        if not ok then
          last_error = backend.name .. ": " .. vim.trim(stderr):sub(1, 200)
          attempt()
          return
        end
        local actual, err = accept(stdout, mime, limit)
        if err then
          finish(nil, nil, err)
          return
        end
        if not actual then
          -- Reachable, but the image vanished between listing and reading.
          finish(nil, nil, nil)
          return
        end
        finish(stdout, actual, nil)
      end, limit)
    end

    if #backend.types == 0 then
      -- The tool streams whatever format the selection holds, so there is no
      -- advertised type to compare against: trust the sniffed container.
      read_mime(nil)
      return
    end
    run(backend.types, function(ok, stdout)
      if not ok then
        last_error = backend.name .. " could not list clipboard types"
        attempt()
        return
      end
      local mime = M.pick(stdout)
      if not mime then
        -- This backend owns the selection and it holds no image. Do not fall
        -- through: an empty Wayland clipboard must not read a stale X11 one.
        finish(nil, nil, nil)
        return
      end
      read_mime(mime)
    end, 64 * 1024)
  end

  attempt()
end

return M
