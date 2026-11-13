return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local toolbar = require("acp.ui.toolbar")
  local config = require("acp.config")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  t.describe("narrow toolbar", function()
    local long_model = "commandcode/DeepSeek V4.1 Flash (latest)"

    t.it("keeps model and mode clickable at usable widths", function()
      -- Below ~16 cells only one region fits; that is an acceptable fallback.
      for _, width in ipairs({ 140, 100, 60, 42, 30, 20 }) do
        local bar = toolbar.render({
          model = long_model,
          mode = "Build",
          status = "idle",
          icons = true,
        }, width)
        t.truthy(bar:find("AcpPickModel", 1, true), string.format("model lost its click region at width %d", width))
        t.truthy(bar:find("AcpPickMode", 1, true), string.format("mode lost its click region at width %d", width))
      end
    end)

    t.it("never overflows the window", function()
      for _, width in ipairs({ 140, 100, 60, 42, 30, 20 }) do
        local bar = toolbar.render({
          model = long_model,
          mode = "Build",
          status = "idle",
          icons = true,
        }, width)
        local res = vim.api.nvim_eval_statusline(bar, { maxwidth = width, use_winbar = true })
        t.truthy(res.width <= width, string.format("toolbar overflowed at width %d", width))
      end
    end)
  end)

  t.describe("native layout sizing", function()
    -- The panel geometry depends on the editor's window layout, which other
    -- specs may have altered. Measure it in a clean Neovim instead.
    local root_dir = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

    local function measure(extra_opts)
      local script = string.format(
        [[
        vim.opt.runtimepath:append(%q)
        vim.o.swapfile = false
        local acp = require("acp")
        local controller = require("acp.controller")
        local config = require("acp.config")
        acp.setup({
          agent = "opencode",
          agents = { opencode = { command = "python3", args = { %q } } },
          ui = {},
          layout = %s,
        })
        controller.open()
        local S = controller.state()
        vim.wait(15000, function() return S.sess.current ~= nil end, 20)
        local chat_w = vim.api.nvim_win_get_width(S.view.chat.win)
        local input_w = vim.api.nvim_win_get_width(S.view.input.win)
        local input_h = vim.api.nvim_win_get_height(S.view.input.win)
        local expected = config.panel_width(S.config, vim.o.columns)
        local min_w = S.config.layout.min_width
        local max_w = S.config.layout.max_width
        local ea = tostring(vim.o.equalalways)
        controller.hide()
        io.write(string.format("%%d %%d %%d %%d %%d %%d %%s", chat_w, input_w, input_h,
          expected, min_w, max_w, ea))
        vim.cmd("qa!")
        ]],
        root_dir,
        root_dir .. "tests/mock_agent.py",
        vim.inspect(extra_opts or { backend = "native", width = 0.3, min_width = 42, max_width = 120 })
      )
      local tmp = vim.fn.tempname() .. ".lua"
      vim.fn.writefile(vim.split(script, "\n"), tmp)
      local out = vim.fn.system({ "nvim", "--headless", "-u", "NONE", "-l", tmp })
      vim.fn.delete(tmp)
      local chat_w, input_w, input_h, expected, min_w, max_w, ea =
        out:match("(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%w+)")
      if not chat_w then
        return nil, out
      end
      return {
        chat_w = tonumber(chat_w),
        input_w = tonumber(input_w),
        input_h = tonumber(input_h),
        expected = tonumber(expected),
        min_w = tonumber(min_w),
        max_w = tonumber(max_w),
        equalalways = ea,
      }
    end

    t.it("sizes the panel from the configuration", function()
      local m, out = measure()
      t.truthy(m, "measurement failed: " .. tostring(out))
      t.eq(m.expected, m.chat_w, "the panel width must match the configuration")
      t.eq(m.chat_w, m.input_w, "both views must share a width")
    end)

    t.it("respects min_width", function()
      local m, out = measure()
      t.truthy(m, "measurement failed: " .. tostring(out))
      t.truthy(m.chat_w >= m.min_w, "panel narrower than min_width")
    end)

    t.it("keeps the composer at the configured height", function()
      local m, out = measure()
      t.truthy(m, "measurement failed: " .. tostring(out))
      t.eq(8, m.input_h, "the composer height must not be rebalanced")
    end)

    t.it("restores equalalways", function()
      local m, out = measure()
      t.truthy(m, "measurement failed: " .. tostring(out))
      t.eq("true", m.equalalways)
    end)

    t.it("honours an absolute width", function()
      local m, out = measure({ backend = "native", width = 60, min_width = 42, max_width = 120 })
      t.truthy(m, "measurement failed: " .. tostring(out))
      t.truthy(m.chat_w > 42, "the absolute width was ignored")
      t.truthy(m.chat_w <= 60, "the panel exceeded the requested width")
    end)
  end)

  t.describe("restoring a single view", function()
    -- Reopening the transcript while only the composer is visible must not
    -- create (and immediately abandon) a second composer window.
    local function count_windows(script)
      local tmp = vim.fn.tempname() .. ".lua"
      vim.fn.writefile(vim.split(script, "\n"), tmp)
      local out = vim.fn.system({ "nvim", "--headless", "-u", "NONE", "-l", tmp })
      vim.fn.delete(tmp)
      return out:match("wins=(%d+)")
    end

    t.it("creates exactly one window for the transcript", function()
      local script = string.format(
        [[
        vim.opt.runtimepath:append(%q)
        vim.o.swapfile = false
        local controller = require("acp.controller")
        controller.setup({})
        local layout = require("acp.layout")
        local S = controller.state()
        S.view.input.win = layout.create_input_win(S.view.input.buf, nil)
        S.view.chat.win = layout.create_chat_win(S.view.chat.buf)
        local n = 0
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "acp_chat" then
            n = n + 1
          end
        end
        io.write(string.format("wins=%%d", n))
        vim.cmd("qa!")
        ]],
        root
      )
      local count = count_windows(script)
      t.eq("1", count, "restoring the transcript left a stray window behind")
    end)
  end)
end
