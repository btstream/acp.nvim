-- Regression tests for the line background painter (phase 0 of the render
-- upgrade). Code blocks and tool cards both draw through this path.
return function(t)
  local config = require("acp.config")
  local state = require("acp.session.state")
  local Chat = require("acp.ui.chat")
  local blocks = require("acp.ui.blocks")

  local ns_bg = vim.api.nvim_create_namespace("acp_chat_bg")

  local function cfg()
    return config.validate(config.merge(config.defaults, {}))
  end

  ---A block whose rendered lines carry explicit backgrounds.
  ---@param id string
  ---@param patterns string[] one entry per rendered line, "x" means bg
  local function bg_block(id, patterns)
    return {
      id = id,
      kind = "system",
      text = "",
      _test_patterns = patterns,
    }
  end

  t.describe("line backgrounds", function()
    t.it("collects contiguous runs of the same group", function()
      local runs = Chat._background_runs({
        { bg = "A" },
        { bg = "A" },
        { bg = nil },
        { bg = "B" },
      })
      t.eq(2, #runs)
      t.eq({ s = 0, e = 2, group = "A" }, runs[1])
      t.eq({ s = 3, e = 4, group = "B" }, runs[2])
    end)

    t.it("does not merge adjacent runs with different groups", function()
      local runs = Chat._background_runs({
        { bg = "A" },
        { bg = "B" },
      })
      t.eq(2, #runs)
      t.eq("A", runs[1].group)
      t.eq("B", runs[2].group)
    end)

    t.it("produces no runs when nothing has a background", function()
      t.eq(0, #Chat._background_runs({ { bg = nil }, {} }))
    end)

    t.it("treats runs with the same layout as equal", function()
      local a = { { s = 0, e = 2, group = "A" } }
      t.truthy(Chat._runs_equal(a, { { s = 0, e = 2, group = "A" } }))
      t.falsy(Chat._runs_equal(a, { { s = 0, e = 3, group = "A" } }))
      t.falsy(Chat._runs_equal(a, { { s = 0, e = 2, group = "B" } }))
      t.falsy(Chat._runs_equal(a, { { s = 1, e = 2, group = "A" } }))
      t.falsy(Chat._runs_equal(a, {}))
      t.falsy(Chat._runs_equal(nil, a))
    end)
  end)

  t.describe("background painting", function()
    ---Render a synthetic session whose blocks declare their own line list.
    local function render_with(chat, session_block_lines)
      -- Bypass blocks.render_block by pre-seeding the cache with the lines we
      -- want, keyed by block id and matching the signature.
      local s = state.new("s", "/tmp")
      for _, spec in ipairs(session_block_lines) do
        s:append({ id = spec.id, kind = "system", text = spec.text or "" })
      end
      -- A system block renders one line per text line; build text so the
      -- rendered line count matches, then override the bg flags in meta.
      chat.session = s
      chat.cache = {}
      chat.lines_cache = {}
      chat.bg_runs = nil
      chat.full_rewrite = true
      chat:render(true)
      return s
    end

    t.it("paints one extmark per run", function()
      local chat = Chat.new({ config = cfg() })
      -- Patch the renderer output for this view only.
      local original = blocks.render_block
      blocks.render_block = function(block)
        if block.id == "card" then
          return {
            { text = "padding", bg = "AcpCardBg" },
            { text = "content", bg = "AcpCardBg" },
            { text = "padding", bg = "AcpCardBg" },
          }
        end
        return {
          { text = "before" },
          { text = "after" },
        }
      end
      local ok, err = pcall(function()
        local s = state.new("s", "/tmp")
        s:append({ id = "card", kind = "system", text = "card" })
        s:append({ id = "plain", kind = "system", text = "plain" })
        chat:set_session(s)
        chat:render(true)

        local marks = vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, { details = true })
        t.eq(1, #marks, "the three card lines should share one extmark")
        t.eq(0, marks[1][2], "background starts at the first card line")
        t.eq(3, marks[1][4].end_row, "background covers exactly the card lines")
        t.eq("AcpCardBg", marks[1][4].hl_group)
        t.truthy(marks[1][4].hl_eol, "background must reach the window edge")
        -- A lower priority than the inline segments (100) is what lets text
        -- colours show through; `hl_mode` itself is not reported by
        -- nvim_buf_get_extmarks.
        t.eq(50, marks[1][4].priority, "background must sit below inline highlights")
      end)
      blocks.render_block = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("does not paint anything without a bg", function()
      local chat = Chat.new({ config = cfg() })
      local s = state.new("s", "/tmp")
      s:append({ id = "plain", kind = "system", text = "hello" })
      chat:set_session(s)
      chat:render(true)
      t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}))
    end)

    t.it("repaints when the layout shifts", function()
      local chat = Chat.new({ config = cfg() })
      local original = blocks.render_block
      local with_bg = false
      blocks.render_block = function(block)
        if block.id == "target" then
          return {
            { text = "line one", bg = with_bg and "AcpCardBg" or nil },
            { text = "line two", bg = with_bg and "AcpCardBg" or nil },
          }
        end
        return { { text = "plain" } }
      end
      local ok, err = pcall(function()
        local s = state.new("s", "/tmp")
        s:append({ id = "target", kind = "system", text = "target" })
        chat:set_session(s)
        chat:render(true)
        t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}), "no background yet")

        with_bg = true
        -- Force a re-render of the block, mirroring what a config/state change does.
        chat:render(true)
        t.eq(1, #vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}), "background missing after change")

        with_bg = false
        chat:render(true)
        t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}), "stale background left behind")
      end)
      blocks.render_block = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("clears backgrounds when the session is dropped", function()
      local chat = Chat.new({ config = cfg() })
      local original = blocks.render_block
      blocks.render_block = function()
        return { { text = "card", bg = "AcpCardBg" } }
      end
      local ok, err = pcall(function()
        local s = state.new("s", "/tmp")
        s:append({ id = "card", kind = "system", text = "card" })
        chat:set_session(s)
        chat:render(true)
        t.truthy(#vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}) > 0)

        chat:set_session(nil)
        chat:render(true)
        t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, ns_bg, 0, -1, {}), "background outlived the session")
      end)
      blocks.render_block = original
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.describe("transcript copying", function()
    t.it("strips trailing padding", function()
      local chat = Chat.new({ config = cfg() })
      chat.lines_cache = { "content      ", "  padded   ", "plain" }
      t.eq("content\n  padded\nplain", chat:transcript())
    end)

    t.it("keeps leading indentation", function()
      local chat = Chat.new({ config = cfg() })
      chat.lines_cache = { "    indented" }
      t.eq("    indented", chat:transcript())
    end)
  end)

  t.describe("indentation", function()
    t.it("carries the background through indentation", function()
      local lines = blocks.indent_lines({ { text = "x", bg = "AcpCardBg", segments = {} } }, "  ")
      t.eq("AcpCardBg", lines[1].bg)
      t.eq("  x", lines[1].text)
    end)

    t.it("leaves a missing background alone", function()
      local lines = blocks.indent_lines({ { text = "x", segments = {} } }, "  ")
      t.eq(nil, lines[1].bg)
    end)
  end)
end
