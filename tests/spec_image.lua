return function(t)
  local Config = require("acp.config")
  local context = require("acp.context")
  local image = require("acp.context.image")
  local clipboard = require("acp.context.clipboard")
  local paste = require("acp.ui.paste_image")

  local counter = 0
  local PNG = "\137PNG\r\n\26\n"
  local JPEG = "\255\216\255\224"

  local function cfg(over)
    return Config.validate(Config.merge(Config.defaults, over or {}))
  end

  local function tempdir()
    counter = counter + 1
    local dir = "/tmp/opencode/acp-image-" .. vim.uv.hrtime() .. "-" .. counter
    vim.fn.mkdir(dir, "p")
    return dir
  end

  local function write_in(dir, name, bytes)
    local path = dir .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(bytes)
    fh:close()
    return path
  end

  local function tempfile(bytes, name)
    local dir = tempdir()
    return write_in(dir, name or "shot.png", bytes), dir
  end

  local function png(extra)
    return PNG .. string.rep("\0\1\2\3", 300) .. (extra or "")
  end

  -- Never let store/prune tests touch the user's real screenshot cache.
  local suite = t
  t = setmetatable({
    it = function(name, fn)
      suite.it(name, function()
        local original = image.dir
        local dir = tempdir() .. "/acp/images"
        image.dir = function()
          return dir
        end
        local ok, err = xpcall(fn, debug.traceback)
        image.dir = original
        vim.fn.delete(vim.fs.dirname(vim.fs.dirname(dir)), "rf")
        if not ok then
          error(err, 0)
        end
      end)
    end,
  }, { __index = suite })

  t.describe("image attachments", function()
    t.it("recognises a WebP file using its full twelve-byte header", function()
      local path, dir = tempfile("RIFF\0\0\0\0WEBPbody", "shot.webp")
      t.truthy(image.is_file(path, 1024))
      vim.fn.delete(dir, "rf")
    end)

    t.it("tracks image positions through edits, draft switches and removal", function()
      local input = require("acp.ui.input").new({ config = cfg() })
      input:switch_session("first")
      input:restore("hello world")
      local att = { kind = "image", label = "shot.png", path = "/shot.png" }
      input:add_attachment(att, { 0, 5 })
      local ns = vim.api.nvim_get_namespaces()["acp.input.images"]
      local function marks()
        return vim.api.nvim_buf_get_extmarks(input.buf, ns, 0, -1, { details = true })
      end
      t.eq(5, marks()[1][3])
      vim.api.nvim_buf_set_text(input.buf, 0, 0, 0, 0, { "new " })
      input:switch_session("second")
      t.eq(0, #marks())
      input:switch_session("first")
      t.eq("new hello world", input:text())
      t.eq(9, marks()[1][3])
      input:remove_attachment(1)
      t.eq(0, #marks())
      input:add_attachment(att, { 0, 3 })
      input:clear()
      t.eq(0, #marks())
      input:destroy()
    end)

    t.it("renders editable numbered image tokens and preserves remaining identifiers", function()
      local input = require("acp.ui.input").new({ config = cfg() })
      input:add_attachment({ kind = "file", label = "main.lua", path = "/main.lua" })
      input:add_attachment({ kind = "image", label = "long-screenshot-name.png", path = "/one.png" })
      input:add_attachment({ kind = "image", label = "other.png", path = "/two.png" })
      local ns = vim.api.nvim_get_namespaces()["acp.input.images"]
      local function labels()
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(input.buf, ns, 0, -1, { details = true })) do
          local d = mark[4]
          local label = vim.api.nvim_buf_get_text(input.buf, mark[2], mark[3], d.end_row, d.end_col, {})[1]
          result[#result + 1] = { label, d.hl_group }
        end
        table.sort(result, function(a, b)
          return a[1] < b[1]
        end)
        return result
      end
      t.eq({ { "[Image 1]", "AcpInputImage" }, { "[Image 2]", "AcpInputImage" } }, labels())
      input:remove_attachment(2)
      t.eq({ { "[Image 2]", "AcpInputImage" } }, labels())
      t.eq("", input:text())
      input:destroy()
    end)

    t.it("removes edited image tokens from attachments without stripping literal lookalikes", function()
      local input = require("acp.ui.input").new({ config = cfg() })
      local prefix = "literal [Image 1]: "
      input:restore(prefix)
      input:add_attachment({ kind = "image", path = "/one.png" }, { 0, #prefix })
      t.eq("literal [Image 1]: ", input:text())
      local raw = vim.api.nvim_buf_get_lines(input.buf, 0, -1, false)[1]
      t.eq("literal [Image 1]: [Image 1]", raw)
      vim.api.nvim_buf_set_text(input.buf, 0, #prefix, 0, #raw, { "" })
      t.eq("literal [Image 1]: ", input:text())
      t.eq(0, #input.attachments)
      input:destroy()
    end)

    t.it("keeps images out of the composer winbar even when the toolbar is disabled", function()
      local c = cfg()
      local input = require("acp.ui.input").new({ config = c })
      local win = vim.api.nvim_get_current_win()
      local chrome = require("acp.ui.chrome").new({
        config = function()
          return c
        end,
        current = function()
          return nil
        end,
        input = function()
          return input
        end,
        waiting = function()
          return false
        end,
      })
      input:add_attachment({ kind = "image", label = "cursor-only.png", path = "/shot.png" })
      t.falsy(chrome:composer_bar(win):find("cursor-only.png", 1, true))
      c.ui.toolbar.placement = "off"
      t.eq("", chrome:composer_bar(win))
      t.eq(1, #vim.api.nvim_buf_get_extmarks(input.buf, vim.api.nvim_get_namespaces()["acp.input.images"], 0, -1, {}))
      input:destroy()
    end)

    t.it("anchors pending clipboard reads to their original draft and edit position", function()
      local input = require("acp.ui.input").new({ config = cfg() })
      input:switch_session("first")
      input:restore("hello")
      local anchor = input:image_anchor()
      vim.api.nvim_buf_set_text(input.buf, 0, 0, 0, 0, { "x" })
      t.eq({ 0, 1 }, input:take_image_anchor(anchor))
      local stale = input:image_anchor()
      input:clear()
      t.eq(nil, input:take_image_anchor(stale))
      input:destroy()
    end)

    t.it("sniffs PNG, JPEG, GIF and WebP and rejects other bytes", function()
      t.eq("image/png", image.sniff(PNG .. "body"))
      t.eq("image/jpeg", image.sniff(JPEG .. "body"))
      t.eq("image/gif", image.sniff("GIF89a" .. "body"))
      t.eq("image/webp", image.sniff("RIFF" .. "\0\0\0\0" .. "WEBP" .. "body"))
      t.eq(nil, image.sniff("hello world, not an image"))
      t.eq(nil, image.sniff(""))
      t.eq(nil, image.sniff(nil))
      -- SVG is text; it is a resource, not a raster the agent can decode.
      t.eq(nil, image.sniff('<svg xmlns="http://www.w3.org/2000/svg"></svg>'))
    end)

    t.it("builds a link block by default and honours inline mode", function()
      local path, dir = tempfile(png())
      local c = cfg()
      local att, err = context.image(path, c)
      t.eq(nil, err)
      t.eq("image", att.kind)
      t.eq("image/png", att.mime)
      t.eq(false, att.inline)
      t.eq(nil, att.block)
      local blocks = context.to_prompt("hi", { att }, c)
      t.eq("text", blocks[1].type)
      t.eq("resource_link", blocks[2].type)
      t.eq("image/png", blocks[2].mimeType)

      c.context.images.path_mode = "inline"
      local inline = context.image(path, c)
      t.eq(true, inline.inline)
      local encoded = context.to_prompt("hi", { inline }, c)
      t.eq("image", encoded[2].type)
      t.eq(vim.base64.encode(png()), encoded[2].data)
      vim.fn.delete(dir, "rf")
    end)

    t.it("rejects oversized, unreadable and non-image files", function()
      local dir = tempdir()
      local big = write_in(dir, "big.png", png(string.rep("z", 4096)))
      local small = cfg({ context = { images = { max_bytes = 2048 } } })
      local _, err = context.image(big, small)
      t.match("too large", err)
      _, err = context.image(dir .. "/missing.png", small)
      t.match("not a readable image", err)
      local text = write_in(dir, "note.png", "this is not an image at all")
      _, err = context.image(text, cfg())
      t.match("not a supported image", err)
      vim.fn.delete(dir, "rf")
    end)

    t.it("stores clipboard bytes by digest and reuses the same file", function()
      local c = cfg()
      local first, err = context.image_bytes(png(), "image/png", c)
      t.eq(nil, err)
      t.truthy(first.path:find("/acp/images/", 1, true))
      t.truthy(first.path:find(vim.fn.sha256(png()), 1, true))
      local second = context.image_bytes(png(), "image/png", c)
      t.eq(first.path, second.path)
      -- Clipboard images are always embedded: the agent cannot read our cache.
      t.eq(true, first.inline)
      local blocks = context.to_prompt("", { first }, c)
      t.eq("image", blocks[1].type)
      local _, bad = context.image_bytes(png(), "image/svg+xml", c)
      t.match("unsupported image format", bad)
      pcall(os.remove, first.path)
    end)

    t.it("prunes the cache by age and by total size", function()
      local dir = image.dir()
      vim.fn.mkdir(dir, "p")
      local old = dir .. "/prune-old-" .. tostring(vim.uv.hrtime()) .. ".png"
      local keep = dir .. "/prune-keep-" .. tostring(vim.uv.hrtime()) .. ".png"
      for _, path in ipairs({ old, keep }) do
        local fh = assert(io.open(path, "wb"))
        fh:write(string.rep("x", 1024))
        fh:close()
      end
      t.truthy(vim.uv.fs_utime(old, os.time() - 48 * 3600, os.time() - 48 * 3600))
      image.prune(24, 0)
      t.eq(0, vim.fn.filereadable(old))
      vim.fn.delete(keep)
      -- A size budget removes the oldest entries until the directory fits.
      local a = dir .. "/prune-a-" .. tostring(vim.uv.hrtime()) .. ".png"
      local b = dir .. "/prune-b-" .. tostring(vim.uv.hrtime()) .. ".png"
      for _, path in ipairs({ a, b }) do
        local fh = assert(io.open(path, "wb"))
        fh:write(string.rep("y", 2048))
        fh:close()
      end
      vim.uv.fs_utime(a, os.time() - 100, os.time() - 100)
      image.prune(0, 3000)
      t.eq(0, vim.fn.filereadable(a))
      t.eq(1, vim.fn.filereadable(b))
      vim.fn.delete(b)
    end)

    t.it("protects referenced cache files even past the TTL and size budget", function()
      local path = assert(image.store(png(), "image/png"))
      vim.uv.fs_utime(path, os.time() - 48 * 3600, os.time() - 48 * 3600)
      image.prune(24, 1, { [path] = true })
      t.eq(1, vim.fn.filereadable(path))
      image.prune(24, 1)
      t.eq(0, vim.fn.filereadable(path))
    end)

    t.it("reports rename failure and rejects corrupted cache entries", function()
      local rename = vim.uv.fs_rename
      vim.uv.fs_rename = function()
        return nil, "simulated failure"
      end
      local ok, path, err = pcall(image.store, png(), "image/png")
      vim.uv.fs_rename = rename
      t.truthy(ok)
      t.eq(nil, path)
      t.match("commit", err)
      path = assert(image.store(png(), "image/png"))
      local fh = assert(io.open(path, "wb"))
      fh:write("corrupt")
      fh:close()
      local bad, problem = image.store(png(), "image/png")
      t.eq(nil, bad)
      t.match("invalid", problem)
    end)

    t.it("keeps a stored image usable when only the path is kept", function()
      -- The draft file deliberately drops `text` and `block`; a path and a size
      -- must still be enough to rebuild the block at send time.
      local c = cfg({ context = { images = { path_mode = "inline" } } })
      local att = context.image_bytes(png(), "image/png", c)
      local bare = {
        kind = att.kind,
        label = att.label,
        path = att.path,
        uri = att.uri,
        mime = att.mime,
        bytes = att.bytes,
        sha = att.sha,
        inline = att.inline,
      }
      local blocks, err = context.to_prompt("", { bare }, c)
      t.eq(nil, err)
      t.eq("image", blocks[1].type)
      -- Removing the file is reported instead of silently dropping the image.
      pcall(os.remove, att.path)
      local missing, problem = context.to_prompt("", { bare }, c)
      t.eq(nil, missing and missing[1])
      t.match("no longer readable", problem)
    end)
  end)

  t.describe("clipboard images", function()
    t.it("picks the most specific advertised type and ignores parameters", function()
      t.eq("image/png", clipboard.pick("text/plain\nimage/png\n"))
      t.eq("image/jpeg", clipboard.pick("image/pngy\nimage/jpeg"))
      t.eq("image/webp", clipboard.pick("text/html\nimage/webp;charset=binary"))
      t.eq("image/x-custom", clipboard.pick("text/plain\nimage/x-custom"))
      t.eq(nil, clipboard.pick("text/plain\ntext/html"))
      t.eq(nil, clipboard.pick(""))
    end)

    t.it("reports an empty clipboard without falling through to another backend", function()
      -- An empty Wayland selection must not resurrect a stale X11 screenshot.
      local called, seen = false, {}
      clipboard.read({ command = { "sh", "-c", "true" }, max_bytes = 1024 }, function(bytes, mime, err)
        called = true
        seen = { bytes = bytes, mime = mime, err = err }
      end)
      t.truthy(vim.wait(3000, function()
        return called
      end, 5))
      t.eq(nil, seen.bytes)
      -- `sh -c true` writes nothing, which is a valid "no image" answer.
      t.eq(nil, seen.err)
    end)

    t.it("reads an image through a configured command and sniffs its type", function()
      local script = "printf '\\211PNG\\r\\n\\032\\n'; printf 'body'"
      local result
      clipboard.read({ command = { "sh", "-c", script }, max_bytes = 1024 }, function(bytes, mime, err)
        result = { bytes = bytes, mime = mime, err = err }
      end)
      t.truthy(vim.wait(3000, function()
        return result ~= nil
      end, 5))
      t.eq(nil, result.err)
      t.eq("image/png", result.mime)
      t.truthy(result.bytes:find("body", 1, true))
    end)

    t.it("rejects data that contradicts the advertised type or exceeds the budget", function()
      local cases = {
        { script = "printf 'not an image'", pattern = "supported image" },
        { script = "printf '\\211PNG\\r\\n\\032\\n'; head -c 4096 /dev/zero", pattern = "max_bytes" },
      }
      for _, case in ipairs(cases) do
        local result
        clipboard.read({ command = { "sh", "-c", case.script }, max_bytes = 512 }, function(bytes, _, err)
          result = { bytes = bytes, err = err }
        end)
        t.truthy(vim.wait(3000, function()
          return result ~= nil
        end, 5))
        t.eq(nil, result.bytes)
        t.match(case.pattern, result.err)
      end
    end)

    t.it("surfaces a failing command instead of pretending the clipboard is empty", function()
      local result
      clipboard.read({ command = { "sh", "-c", "echo boom >&2; exit 3" }, max_bytes = 1024 }, function(bytes, _, err)
        result = { bytes = bytes, err = err }
      end)
      t.truthy(vim.wait(3000, function()
        return result ~= nil
      end, 5))
      t.eq(nil, result.bytes)
      t.match("clipboard command failed", result.err)
    end)

    t.it("trusts the container when a backend cannot advertise types", function()
      -- pngpaste/xsel/powershell stream whatever the selection holds, so there
      -- is no advertised type to compare against.
      local real = clipboard.backends
      clipboard.backends = function()
        return {
          {
            name = "no-types",
            types = {},
            read = function()
              return { "sh", "-c", "printf '\\211PNG\\r\\n\\032\\nBODY'" }
            end,
          },
        }
      end
      local result
      local ok, problem = pcall(function()
        clipboard.read({ max_bytes = 1024 }, function(bytes, mime, err)
          result = { bytes = bytes, mime = mime, err = err }
        end)
        vim.wait(3000, function()
          return result ~= nil
        end, 5)
      end)
      clipboard.backends = real
      t.truthy(ok, tostring(problem))
      t.eq(nil, result.err)
      t.eq("image/png", result.mime)
    end)

    t.it("does not hang when the helper never exits", function()
      local started = vim.uv.hrtime()
      local result
      clipboard.read({ command = { "sh", "-c", "sleep 30" }, max_bytes = 1024 }, function(bytes, _, err)
        result = { bytes = bytes, err = err }
      end)
      -- vim.system applies its own timeout; the visible symptom is an error,
      -- not a wedged editor.
      t.truthy(vim.wait(6000, function()
        return result ~= nil
      end, 10))
      t.eq(nil, result.bytes)
      t.truthy(result.err ~= nil)
      t.truthy((vim.uv.hrtime() - started) / 1e6 < 6000)
    end)

    t.it("keeps image bytes out of protocol logs", function()
      local Log = require("acp.log")
      local payload = vim.json.encode({
        params = {
          prompt = { { type = "image", mimeType = "image/png", data = vim.base64.encode(string.rep("pixel!", 200)) } },
        },
      })
      local redacted = Log.redact(payload, 8000)
      t.falsy(redacted:find("pixel", 1, true))
      t.match("<base64 %d+ bytes>", redacted)
      -- Even a very small image payload must not leak into protocol logs.
      t.falsy(Log.redact([[{"data":"abc123"}]], 400):find("abc123", 1, true))
    end)
  end)

  t.describe("pasted image paths", function()
    t.it("recognises plain, quoted and file:// image paths", function()
      local path, dir = tempfile(png())
      t.eq(path, paste.path_of(path))
      t.eq(path, paste.path_of('"' .. path .. '"'))
      t.eq(path, paste.path_of("file://" .. path))
      t.eq(nil, paste.path_of("hello world"))
      t.eq(nil, paste.path_of("https://example.com/cat.png"))
      t.eq(nil, paste.path_of(""))
      t.eq(nil, paste.path_of(path .. "\n" .. path))
      vim.fn.delete(dir, "rf")
    end)

    t.it("escapes terminal backslash quoting for paths with spaces", function()
      local dir = "/tmp/opencode/acp-image space-" .. tostring(vim.uv.hrtime())
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/my shot.png"
      local fh = assert(io.open(path, "wb"))
      fh:write(png())
      fh:close()
      local escaped = path:gsub(" ", "\\ ")
      t.eq(path, paste.path_of(escaped))
      t.truthy(paste.is_image(path, 1024 * 1024))
      vim.fn.delete(dir, "rf")
    end)

    t.it("accepts images inside the budget and rejects other files", function()
      local path, dir = tempfile(png())
      t.truthy(paste.is_image(path, 1024 * 1024))
      t.falsy(paste.is_image(path, 16))
      t.falsy(paste.is_image(dir, 1024 * 1024))
      local textfile = write_in(dir, "note.txt", "plain text")
      t.falsy(paste.is_image(textfile, 1024 * 1024))
      vim.fn.delete(dir, "rf")
    end)

    t.it("delegates every other paste to Neovim's own handler", function()
      local path, dir = tempfile(png())
      local c = cfg()
      local received = {}
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "acp_input"
      local original = vim.paste
      vim.paste = function(lines, phase)
        received[#received + 1] = { lines = lines, phase = phase }
        return true
      end
      paste.attach(buf, {
        config = function()
          return c
        end,
        is_active = function()
          return true
        end,
        on_image = function()
          return false
        end,
      })
      vim.api.nvim_set_current_buf(buf)
      vim.paste({ "hello" }, -1)
      vim.paste({ path }, -1)
      paste.detach(buf)
      vim.paste = original
      t.eq(2, #received)
      t.eq({ "hello" }, received[1].lines)
      t.eq({ path }, received[2].lines)
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("leaves another plugin's wrapper in place when it detaches", function()
      local path, dir = tempfile(png())
      local c = cfg()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "acp_input"
      local base = function()
        return true
      end
      local saved = vim.paste
      vim.paste = base
      paste.attach(buf, {
        config = function()
          return c
        end,
        is_active = function()
          return true
        end,
        on_image = function()
          return false
        end,
      })
      -- Simulate a plugin that wraps the handler after us.
      local wrapper_calls = 0
      local previous = vim.paste
      local wrapper = function(lines, phase)
        wrapper_calls = wrapper_calls + 1
        return previous(lines, phase)
      end
      vim.paste = wrapper
      paste.detach(buf)
      t.eq(wrapper, vim.paste, "another plugin's wrapper was clobbered")
      t.eq(true, vim.paste({ "plain text after detach" }, -1))
      t.eq(1, wrapper_calls)
      vim.paste = saved
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("does not claim a multi-line or streamed paste", function()
      local path, dir = tempfile(png())
      local c = cfg()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "acp_input"
      local original = vim.paste
      local forwarded = {}
      vim.paste = function(lines, phase)
        forwarded[#forwarded + 1] = { lines = lines, phase = phase }
        return true
      end
      local claimed = 0
      paste.attach(buf, {
        config = function()
          return c
        end,
        is_active = function()
          return true
        end,
        on_image = function()
          claimed = claimed + 1
          return true
        end,
      })
      vim.api.nvim_set_current_buf(buf)
      vim.paste({ path, path }, -1)
      vim.paste({ path }, 1)
      t.eq(0, claimed)
      t.eq(2, #forwarded)
      paste.detach(buf)
      vim.paste = original
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("claims an image paste only when the attachment was accepted", function()
      local path, dir = tempfile(png())
      local c = cfg()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "acp_input"
      local original = vim.paste
      local passthrough = 0
      vim.paste = function()
        passthrough = passthrough + 1
        return true
      end
      local accepted
      paste.attach(buf, {
        config = function()
          return c
        end,
        is_active = function()
          return true
        end,
        on_image = function(got)
          accepted = got
          return true
        end,
      })
      vim.api.nvim_set_current_buf(buf)
      t.eq(true, vim.paste({ path }, -1))
      t.eq(path, accepted)
      paste.detach(buf)
      vim.paste = original
      t.eq(0, passthrough)
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("image prompt encoding", function()
    t.it("preserves the input's image positions across Unicode, newlines and adjacent tokens", function()
      local c = cfg()
      local input = require("acp.ui.input").new({ config = c })
      input:switch_session("positioned")
      input:restore("前\n中后")
      local function add(name, position)
        input:add_attachment({ kind = "image", path = "/" .. name, block = { type = "image", data = name } }, position)
      end
      add("one", { 1, #"中" })
      add("two", { 0, 0 })
      add("three", { 0, 0 })
      local text = input:text()
      t.eq("前\n中后", text)
      local expected = {
        { type = "image", data = "three" },
        { type = "image", data = "two" },
        { type = "text", text = "前\n中" },
        { type = "image", data = "one" },
        { type = "text", text = "后" },
      }
      t.eq(expected, context.to_prompt(text, input.attachments, c))
      local raw = table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n")
      t.eq(raw, context.display_text(text, input.attachments))
      input:switch_session("other")
      input:switch_session("positioned")
      t.eq(expected, context.to_prompt(input:text(), input.attachments, c))
      input:destroy()
    end)

    t.it("supports images in the middle and at the end while appending unpositioned context", function()
      local a = { kind = "image", prompt_offset = 1, block = { type = "image", data = "a" } }
      local b = { kind = "image", prompt_offset = 2, block = { type = "image", data = "b" } }
      local file = { block = { type = "resource_link", uri = "file:///context" } }
      t.eq({
        { type = "text", text = "ab" },
        file.block,
      }, context.to_prompt("ab", { file }, cfg()))
      t.eq({
        { type = "text", text = "a" },
        a.block,
        { type = "text", text = "b" },
        b.block,
        file.block,
      }, context.to_prompt("ab", { file, b, a }, cfg()))
    end)

    t.it("snapshots positioned attachments before queueing", function()
      local c = cfg()
      local captured
      local session = { id = "queued", cwd = "/tmp", status = "running" }
      local prompts = require("acp.app.prompts").new({
        config = function()
          return c
        end,
        client = function()
          return {
            supports_prompt = function()
              return true
            end,
          }
        end,
        connection = function()
          return "ready"
        end,
        runtime = function()
          return {
            replays = {},
            enqueue = function(_, _, text, attachments)
              captured = { text = text, attachments = attachments }
              return true
            end,
          }
        end,
        on_changed = function() end,
        notify = function(message)
          error(message)
        end,
      })
      local att = { kind = "image", inline = true, prompt_offset = 1, input_token = "[Image 1]" }
      t.truthy(prompts:send(session, "ab", { att }))
      att.prompt_offset = 0
      t.eq(1, captured.attachments[1].prompt_offset)
      t.eq("a[Image 1]b", context.display_text(captured.text, captured.attachments))
    end)

    t.it("degrades an image to a resource link when the agent lacks image support", function()
      local Prompts = require("acp.app.prompts")
      local state = require("acp.session.state")
      local c = cfg()
      local session = state.new("s", "/tmp")
      local blocks
      local paths = {}
      local prompts = Prompts.new({
        config = function()
          return c
        end,
        runtime = function()
          return {
            replays = {},
            begin_turn = function()
              return 1
            end,
            enqueue = function()
              return true
            end,
            finish_turn = function() end,
          }
        end,
        client = function()
          return {
            is_ready = function()
              return true
            end,
            supports_prompt = function()
              return false
            end,
          }
        end,
        connection = function()
          return "ready"
        end,
        run = function(_, _, _, fn)
          local task = {
            check = function() end,
            status = "running",
            call = function(_, _, _, prompt_blocks)
              blocks = prompt_blocks
              return true, { stopReason = "end_turn" }
            end,
          }
          fn(task)
          return task
        end,
        selected = function()
          return true
        end,
        on_turn_start = function() end,
        on_turn_end = function() end,
        on_changed = function() end,
        on_render = function() end,
        add_block = function() end,
        prune = function() end,
        dispatch_queued = function() end,
        refresh_title = function() end,
        notify = function() end,
      })
      -- The agent advertised no image support, so the block must become a link
      -- rather than failing the whole message.
      local ok = prompts:send(session, "look", {
        { kind = "image", inline = false, label = "a.png", uri = "file:///tmp/a.png" },
      })
      t.truthy(ok)
      t.truthy(blocks, "the prompt was not sent")
      local image
      for _, block in ipairs(blocks) do
        if block.type == "resource_link" then
          image = block
        end
      end
      t.truthy(image, "the image was not degraded to a link: " .. vim.inspect(blocks))
      t.eq("file:///tmp/a.png", image.uri)
    end)

    t.it("still refuses too many images for one message", function()
      local Prompts = require("acp.app.prompts")
      local state = require("acp.session.state")
      local c = cfg()
      local notified
      local session = state.new("s", "/tmp")
      local prompts = Prompts.new({
        config = function()
          return c
        end,
        runtime = function()
          return { replays = {} }
        end,
        client = function()
          return {
            is_ready = function()
              return true
            end,
            supports_prompt = function()
              return true
            end,
          }
        end,
        connection = function()
          return "ready"
        end,
        run = function()
          error("must not run")
        end,
        selected = function()
          return true
        end,
        on_turn_start = function() end,
        on_turn_end = function() end,
        on_changed = function() end,
        on_render = function() end,
        add_block = function() end,
        prune = function() end,
        dispatch_queued = function() end,
        refresh_title = function() end,
        notify = function(message)
          notified = message
        end,
      })
      c.context.images.max_per_message = 1
      t.eq(
        false,
        prompts:send(session, "too many", {
          { kind = "image", inline = false },
          { kind = "image", inline = false },
        })
      )
      t.match("max_per_message", notified)
    end)

    t.it("sends a resource_link when the image is not embedded", function()
      local Prompts = require("acp.app.prompts")
      local state = require("acp.session.state")
      local c = cfg()
      local session = state.new("s", "/tmp")
      local blocks
      local prompts = Prompts.new({
        config = function()
          return c
        end,
        runtime = function()
          return {
            replays = {},
            begin_turn = function()
              return 1
            end,
          }
        end,
        client = function()
          return {
            is_ready = function()
              return true
            end,
            supports_prompt = function()
              return false
            end,
          }
        end,
        connection = function()
          return "ready"
        end,
        run = function(_, _, _, fn)
          fn({
            call = function(_, _, _, list)
              blocks = list
              return true, {}
            end,
          })
          return { status = "running" }
        end,
        selected = function()
          return true
        end,
        on_turn_start = function() end,
        on_turn_end = function() end,
        on_changed = function() end,
        on_render = function() end,
        add_block = function() end,
        prune = function() end,
        dispatch_queued = function() end,
        refresh_title = function() end,
        notify = function() end,
      })
      local ok = prompts:send(session, "look", {
        { kind = "image", inline = false, label = "a.png", uri = "file:///tmp/a.png", mime = "image/png", bytes = 10 },
      })
      t.eq(true, ok)
      t.eq("resource_link", blocks[2].type)
    end)
  end)

  t.describe("image configuration", function()
    t.it("validates the image budgets and clipboard setting", function()
      local bad = {
        { images = { enabled = "yes" } },
        { images = { path_mode = "embed" } },
        { images = { max_bytes = 0 } },
        { images = { max_per_message = 0 } },
        { images = { max_per_message = 1.5 } },
        { images = { clipboard = "wl-paste" } },
        { images = { clipboard = {} } },
        { images = { clipboard = { "" } } },
        { images = { ttl_hours = -1 } },
        { images = { max_cache_bytes = -1 } },
      }
      for _, over in ipairs(bad) do
        t.falsy(pcall(function()
          Config.validate(Config.merge(Config.defaults, { context = over }))
        end))
      end
      t.truthy(pcall(function()
        Config.validate(Config.merge(Config.defaults, {
          context = { images = { clipboard = false, max_per_message = 2 } },
        }))
      end))
    end)

    t.it("rejects an image budget that cannot fit one transport line", function()
      local ok, err = pcall(function()
        Config.validate(Config.merge(Config.defaults, {
          context = { images = { max_bytes = 8 * 1024 * 1024 } },
          transport = { max_line_bytes = 1024 * 1024 },
        }))
      end)
      t.falsy(ok)
      t.match("max_line_bytes", err)
    end)

    t.it("describes a link-mode image mention with its image MIME type", function()
      -- Without this, a mentioned `shot.png` would be attached as text/plain
      -- and the agent would treat the bytes as source code.
      local path, dir = tempfile(png())
      local c = cfg()
      t.eq("link", c.context.images.path_mode)
      local atts = context.mentions("see @" .. path, c, "/tmp")
      t.eq(1, #atts)
      t.eq("image", atts[1].kind)
      t.eq("image/png", atts[1].mime)
      t.eq(false, atts[1].inline)
      vim.fn.delete(dir, "rf")
    end)

    t.it("routes an image through M.file as an image, not as text", function()
      -- `:Acp file` and the drag-and-drop path both go through `M.file`; a PNG
      -- there must not be read as a 500 KiB "text" file with binary content.
      local path, dir = tempfile(png())
      local c = cfg()
      local att, err = context.file(path, c)
      t.eq(nil, err)
      t.eq("image", att.kind)
      t.eq("image/png", att.mime)
      t.eq(nil, att.text)
      local blocks = context.to_prompt("", { att }, c)
      t.eq("resource_link", blocks[1].type)
      t.eq("image/png", blocks[1].mimeType)
      vim.fn.delete(dir, "rf")
    end)

    t.it("falls back to a resource attachment when image support is off", function()
      local path, dir = tempfile(png())
      local c = cfg({ context = { images = { enabled = false } } })
      local atts = context.mentions("see @" .. path, c, "/tmp")
      t.eq(1, #atts)
      t.eq("file", atts[1].kind)
      local blocks = context.to_prompt("", atts, c)
      t.eq("resource_link", blocks[1].type)
      vim.fn.delete(dir, "rf")
    end)

    t.it("drops a restored draft chip whose cache file was pruned", function()
      -- Drafts store the path only, so a pruned file must degrade to a warning
      -- instead of sending a block that points at nothing.
      local c = cfg()
      local att = context.image_bytes(png(), "image/png", c)
      local Input = require("acp.ui.input")
      local input = Input.new({ config = c })
      input:add_attachment({
        kind = att.kind,
        label = att.label,
        path = att.path,
        uri = att.uri,
        mime = att.mime,
        bytes = att.bytes,
        sha = att.sha,
        inline = att.inline,
      })
      t.eq(1, #input.attachments)
      local restored = {
        kind = att.kind,
        label = att.label,
        path = "/tmp/opencode/definitely-gone.png",
        uri = "file:///tmp/opencode/definitely-gone.png",
        mime = "image/png",
        bytes = 10,
        inline = true,
      }
      input:clear_attachments()
      input:add_attachment(restored)
      local blocks, err = context.to_prompt("hi", input.attachments, c)
      t.eq("text", blocks[1].type)
      t.match("no longer readable", err)
      input:destroy()
    end)

    t.it("reports the clipboard reader and cache in health output", function()
      local lines = {}
      local h = vim.health
      local saved = { start = h.start, ok = h.ok, warn = h.warn, error = h.error, info = h.info }
      local function capture(kind)
        return function(message)
          lines[#lines + 1] = kind .. ": " .. tostring(message)
        end
      end
      h.start, h.ok, h.warn, h.error, h.info =
        capture("START"), capture("OK"), capture("WARN"), capture("ERROR"), capture("INFO")
      local ok, problem = pcall(require("acp.health").check)
      h.start, h.ok, h.warn, h.error, h.info = saved.start, saved.ok, saved.warn, saved.error, saved.info
      t.truthy(ok, tostring(problem))
      local joined = table.concat(lines, "\n")
      t.match("image cache:", joined)
      -- Either a reader is reported or the user is told what to install; a
      -- silent health section would hide a broken clipboard setup.
      t.truthy(joined:find("clipboard image", 1, true) ~= nil)
    end)
  end)
end
